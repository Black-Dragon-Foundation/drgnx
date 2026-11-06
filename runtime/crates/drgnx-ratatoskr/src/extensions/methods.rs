//! The four `extensions/*` methods and the files they read.
//!
//! Every call looks at the four files' `(mtime, size)` in a blocking task ([`Cache::refresh`]) and reads only what
//! changed; the search then runs on the index it was handed, which nothing changes.  The readme of a details page is
//! the one file read per call, at most [`README_MAX`] bytes.

use super::catalog::{Cache, Files, Index, Sig, Src};
use super::rank;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Params;
use runstav::methods::extensions as w;
use runstav::paths::{self, Env};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::io::{self, Read};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::UNIX_EPOCH;

/// The most of a readme a details page carries.
pub const README_MAX: u64 = 256 * 1024;

/// The files of the real hub.
pub struct RealFiles {
    pub catalog: PathBuf,
    pub lock: PathBuf,
    pub wanted: PathBuf,
    pub packages: PathBuf,
    /// `<cache>/extensions/readme/`.
    pub readmes: PathBuf,
}

impl RealFiles {
    /// The files under ENV's folders: the catalog and readmes in the cache, the lock and `packages.eld` in the
    /// config folder, the wanted file in the state folder.
    pub fn new(env: &Env) -> RealFiles {
        let cache = paths::cache_dir(env).join("extensions");
        let config = paths::config_dir(env);
        RealFiles {
            catalog: cache.join("catalog.json"),
            lock: config.join("drgnx.lock.eld"),
            wanted: paths::state_dir(env).join("packages-wanted.eld"),
            packages: config.join("packages.eld"),
            readmes: cache.join("readme"),
        }
    }

    fn path(&self, src: Src) -> &PathBuf {
        match src {
            Src::Catalog => &self.catalog,
            Src::Lock => &self.lock,
            Src::Wanted => &self.wanted,
            Src::Packages => &self.packages,
        }
    }

    /// The cached readme of archive ARCHIVE's package NAME; none when there is none.  A name with a separator or a
    /// leading dot is never looked up.
    fn readme(&self, archive: &str, name: &str) -> Option<String> {
        let plain =
            |s: &str| !s.is_empty() && !s.starts_with('.') && !s.contains(['/', '\\', '\0']);
        if !plain(archive) || !plain(name) {
            return None;
        }
        let file = std::fs::File::open(
            self.readmes
                .join(archive)
                .join(format!("{name}-readme.txt")),
        )
        .ok()?;
        let mut bytes = Vec::new();
        file.take(README_MAX).read_to_end(&mut bytes).ok()?;
        Some(String::from_utf8_lossy(&bytes).into_owned())
    }
}

impl Files for RealFiles {
    fn stat(&self, src: Src) -> Option<Sig> {
        let m = std::fs::metadata(self.path(src)).ok()?;
        let mtime_ns = m
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map_or(0, |d| d.as_nanos());
        Some(Sig {
            mtime_ns,
            size: m.len(),
        })
    }

    fn read(&self, src: Src) -> io::Result<Vec<u8>> {
        let path = self.path(src);
        let size = std::fs::metadata(path)?.len();
        if size > src.max() as u64 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("larger than {} bytes", src.max()),
            ));
        }
        std::fs::read(path)
    }
}

/// The catalog's state in the hub.
#[derive(Default)]
pub struct Hub {
    cache: Arc<Mutex<Cache>>,
    files: OnceLock<Arc<RealFiles>>,
}

fn internal(message: impl ToString) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.to_string(),
        path: None,
    }
}

impl Hub {
    /// Where the files are; the hub calls this once at start.
    pub fn configure(&self, env: &Env) {
        let _ = self.files.set(Arc::new(RealFiles::new(env)));
    }

    fn files(&self) -> Result<Arc<RealFiles>, Error> {
        self.files
            .get()
            .cloned()
            .ok_or_else(|| internal("the extensions catalog has no folders yet"))
    }

    /// The index as the files are now.
    async fn index(&self) -> Result<Arc<Index>, Error> {
        let (cache, files) = (self.cache.clone(), self.files()?);
        crate::clock::blocking(move || {
            cache
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .refresh(&*files)
        })
        .await
        .map_err(internal)
    }

    async fn set_modules(&self, modules: Vec<w::ModuleEntry>) -> Result<(), Error> {
        let cache = self.cache.clone();
        crate::clock::blocking(move || {
            cache
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .set_modules(modules)
        })
        .await
        .map_err(internal)
    }

    async fn search(&self, p: w::SearchParams) -> Result<w::SearchResult, Error> {
        let index = self.index().await?;
        let hits = rank::search(
            &index.entries,
            &p.query,
            &p.filters,
            p.sort.unwrap_or(w::Sort::Relevance),
        );
        let offset = p.offset.unwrap_or(0) as usize;
        let limit = p.limit.unwrap_or(w::LIMIT_DEFAULT).min(w::LIMIT_MAX) as usize;
        Ok(w::SearchResult {
            total: hits.len() as u32,
            rows: hits
                .into_iter()
                .skip(offset)
                .take(limit)
                .map(|i| index.entries[i].row.clone())
                .collect(),
        })
    }

    async fn details(&self, id: &str) -> Result<w::DetailsResult, Error> {
        let index = self.index().await?;
        let files = self.files()?;
        let e = index.entry(id).ok_or_else(|| Error {
            code: ErrorCode::InvalidParams,
            message: format!("no extension {id}"),
            path: Some("id".into()),
        })?;
        let row = e.row.clone();
        let readme = (row.kind == w::Kind::Package).then(|| (row.source.clone(), row.name.clone()));
        let readme = crate::clock::blocking(move || {
            readme.and_then(|(archive, name)| files.readme(&archive, &name))
        })
        .await
        .map_err(internal)?;
        Ok(w::DetailsResult {
            required_by: index.required_by(&row.name),
            requires: e.detail.requires.clone(),
            maintainer: e.detail.maintainer.clone(),
            url: e.detail.url.clone(),
            keywords: e.keywords.clone(),
            commit: e.detail.commit.clone(),
            revdesc: e.detail.revdesc.clone(),
            readme,
            notes: index.notes.clone(),
            row,
        })
    }

    async fn rows(&self, ids: &[String]) -> Result<w::RowsResult, Error> {
        let index = self.index().await?;
        Ok(w::RowsResult {
            rows: ids
                .iter()
                .filter_map(|id| index.entry(id).map(|e| e.row.clone()))
                .collect(),
        })
    }
}

pub async fn serve(
    front: &Front,
    _caller: &Caller,
    p: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    let hub = &front.extensions;
    Ok(match p {
        Params::ExtensionsSearch(q) => hub.search(q).await.map(|r| json!(r)),
        Params::ExtensionsDetails(d) => hub.details(&d.id).await.map(|r| json!(r)),
        Params::ExtensionsRows(r) => hub.rows(&r.ids).await.map(|r| json!(r)),
        Params::ExtensionsModules(m) => hub.set_modules(m.modules).await.map(|()| json!({})),
        other => return Err(Box::new(other)),
    })
}
