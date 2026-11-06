//! The catalog in memory: the refresh job's `catalog.json`, the user's lock, the wanted file, `packages.eld`'s names
//! and the editor's module table, merged into one list of rows.
//!
//! - [`CatalogFile`] is the file the refresh job writes (docs/develop/extensions.md, "The catalog file"); an unknown key
//!   is ignored, a `version` other than 1 is refused.
//! - [`parse_lock`], [`parse_names`] and [`parse_packages`] read the Lisp files as data with `huginn`, at most
//!   [`Src::max`] bytes each; nothing is evaluated.
//! - [`Cache`] keeps the last good copy of each source and decides, from an injected [`Files`], which to read again: a
//!   source is read when its `(mtime, size)` is not the one last looked at, so a refresh run from the command line is
//!   seen too and an unchanged file costs a stat.  A source that does not read keeps its last good copy and leaves a
//!   note that `extensions/details` shows.
//! - [`build`] merges the sources into an [`Index`]; a search then runs on an `Arc<Index>` that is never changed.

use huginn::read::{Limits, read_all};
use huginn::value::{Datum, Node};
use runstav::methods::extensions as w;
use serde::Deserialize;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::io;
use std::sync::Arc;

/// One archive of the catalog.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Archive {
    pub name: String,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub signed: bool,
}

/// A version an archive has.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Version {
    pub archive: String,
    pub version: String,
    #[serde(default)]
    pub reqs: Vec<(String, String)>,
}

/// What `package.el` would install.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Candidate {
    pub archive: String,
    pub version: String,
}

/// What the update plan takes.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Update {
    pub from: String,
    pub to: String,
}

/// One package of the catalog.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Pkg {
    pub name: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub keywords: Vec<String>,
    #[serde(default)]
    pub maintainer: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub commit: Option<String>,
    #[serde(default)]
    pub revdesc: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub versions: Vec<Version>,
    #[serde(default)]
    pub candidate: Option<Candidate>,
    #[serde(default)]
    pub update: Option<Update>,
    #[serde(default)]
    pub held: bool,
    #[serde(default)]
    pub incompat: bool,
    #[serde(default)]
    pub downloads: Option<u64>,
}

/// A package Emacs ships.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Builtin {
    pub name: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub summary: String,
}

/// An entry the refresh job could not use.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Skipped {
    #[serde(default)]
    pub archive: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub why: String,
}

/// `<cache>/extensions/catalog.json`.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct CatalogFile {
    pub version: u32,
    #[serde(default)]
    pub archives: Vec<Archive>,
    #[serde(default)]
    pub packages: Vec<Pkg>,
    #[serde(default)]
    pub builtins: Vec<Builtin>,
    #[serde(default)]
    pub skipped: Vec<Skipped>,
}

/// The catalog file as bytes, or why not.
pub fn parse_catalog(bytes: &[u8]) -> Result<CatalogFile, String> {
    let file: CatalogFile = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
    if file.version != 1 {
        return Err(format!(
            "its version is {}, this hub reads version 1",
            file.version
        ));
    }
    Ok(file)
}

fn read_forms(bytes: &[u8], src: Src) -> Result<Vec<Node>, String> {
    let limits = Limits {
        max_bytes: src.max(),
        ..Limits::default()
    };
    read_all(bytes, limits).map_err(|r| r.to_string())
}

/// A symbol or string's text.
fn text(n: &Node) -> Option<&str> {
    match &n.datum {
        Datum::Sym(s) | Datum::Str(s) => Some(s),
        _ => None,
    }
}

/// The items of a list; `nil` is the empty list.
fn items(n: &Node) -> Option<&[Node]> {
    match &n.datum {
        Datum::List(v) => Some(v),
        Datum::Sym(s) if s == "nil" => Some(&[]),
        _ => None,
    }
}

/// The value after KEY in a plist's items.
fn plist_get<'a>(items: &'a [Node], key: &str) -> Option<&'a Node> {
    items
        .chunks(2)
        .find(|c| c.len() == 2 && matches!(&c[0].datum, Datum::Sym(s) if s == key))
        .map(|c| &c[1])
}

/// One entry of the user's lock, the keys the view reads.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LockEntry {
    pub name: String,
    pub version: Option<String>,
    pub archive: Option<String>,
    /// `git` for a package from a repository.
    pub kind: Option<String>,
    pub has_sha256: bool,
    /// `:verified t`: the archive's signature was checked.
    pub verified: bool,
    /// `:wanted user`.
    pub wanted: bool,
    pub requires: Vec<(String, Option<String>)>,
    pub summary: Option<String>,
    pub url: Option<String>,
    pub commit: Option<String>,
}

/// The lock's entries.
pub fn parse_lock(bytes: &[u8]) -> Result<Vec<LockEntry>, String> {
    let forms = read_forms(bytes, Src::Lock)?;
    let root = forms.first().and_then(items).ok_or("it holds no plist")?;
    let list = plist_get(root, ":packages")
        .and_then(items)
        .ok_or("it has no :packages list")?;
    let mut out = Vec::new();
    for e in list {
        let parts = items(e).ok_or("an entry is not a list")?;
        let name = parts
            .first()
            .and_then(text)
            .ok_or("an entry has no name")?
            .to_owned();
        let rest = &parts[1..];
        let get = |k: &str| plist_get(rest, k);
        let string = |k: &str| get(k).and_then(text).map(str::to_owned);
        let requires = get(":requires")
            .and_then(items)
            .unwrap_or(&[])
            .iter()
            .filter_map(|r| {
                let p = items(r)?;
                Some((
                    text(p.first()?)?.to_owned(),
                    p.get(1).and_then(text).map(str::to_owned),
                ))
            })
            .collect();
        out.push(LockEntry {
            name,
            version: string(":version"),
            archive: string(":archive"),
            kind: string(":kind"),
            has_sha256: get(":sha256").is_some_and(|n| text(n).is_some()),
            verified: get(":verified").and_then(text) == Some("t"),
            wanted: get(":wanted").and_then(text) == Some("user"),
            requires,
            summary: string(":summary"),
            url: string(":url"),
            commit: string(":commit"),
        });
    }
    Ok(out)
}

/// The wanted file: a list of package names.
pub fn parse_names(bytes: &[u8]) -> Result<Vec<String>, String> {
    let forms = read_forms(bytes, Src::Wanted)?;
    let Some(first) = forms.first() else {
        return Ok(Vec::new());
    };
    let list = items(first).ok_or("it is not a list of names")?;
    Ok(list.iter().filter_map(text).map(str::to_owned).collect())
}

/// `packages.eld`'s `:packages` and the names of its `:git` entries.
pub fn parse_packages(bytes: &[u8]) -> Result<Vec<String>, String> {
    let forms = read_forms(bytes, Src::Packages)?;
    let Some(root) = forms.first().and_then(items) else {
        return Ok(Vec::new());
    };
    let mut out: Vec<String> = plist_get(root, ":packages")
        .and_then(items)
        .unwrap_or(&[])
        .iter()
        .filter_map(text)
        .map(str::to_owned)
        .collect();
    let git = plist_get(root, ":git").and_then(items).unwrap_or(&[]);
    out.extend(
        git.iter()
            .filter_map(|e| items(e)?.first().and_then(text))
            .map(str::to_owned),
    );
    Ok(out)
}

/// What an entry has besides its row, for `extensions/details`.
#[derive(Clone, Debug, Default)]
pub struct Detail {
    pub requires: Vec<w::Requirement>,
    pub maintainer: Option<String>,
    pub url: Option<String>,
    pub commit: Option<String>,
    pub revdesc: Option<String>,
}

/// A row with what a search needs: lower-cased words, computed once when the index is built.
#[derive(Clone, Debug)]
pub struct Entry {
    pub row: w::Row,
    pub keywords: Vec<String>,
    pub detail: Detail,
    pub(crate) lname: String,
    pub(crate) words: Vec<String>,
    pub(crate) lkeywords: Vec<String>,
    pub(crate) lsummary: String,
}

impl Entry {
    pub fn new(row: w::Row, keywords: Vec<String>, detail: Detail) -> Entry {
        let lname = row.name.to_lowercase();
        let words = lname
            .split(|c: char| !c.is_alphanumeric())
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect();
        let lkeywords = keywords.iter().map(|k| k.to_lowercase()).collect();
        let lsummary = row.summary.to_lowercase();
        Entry {
            row,
            keywords,
            detail,
            lname,
            words,
            lkeywords,
            lsummary,
        }
    }

    /// An installed package: in the lock, whatever its update state.
    pub fn is_installed(&self) -> bool {
        self.row.kind == w::Kind::Package
            && matches!(
                self.row.state,
                w::State::Installed
                    | w::State::Update
                    | w::State::Dependency
                    | w::State::Held
                    | w::State::Incompat
            )
    }
}

/// The merged rows; never changed once built.
#[derive(Debug, Default)]
pub struct Index {
    pub entries: Vec<Entry>,
    by_id: HashMap<String, usize>,
    /// Installed packages that require each package.
    required_by: HashMap<String, Vec<String>>,
    /// What the sources could not give, in the hub's words.
    pub notes: Vec<String>,
}

impl Index {
    pub fn entry(&self, id: &str) -> Option<&Entry> {
        self.by_id.get(id).map(|&i| &self.entries[i])
    }

    /// Installed packages that require NAME, sorted.
    pub fn required_by(&self, name: &str) -> Vec<String> {
        self.required_by.get(name).cloned().unwrap_or_default()
    }
}

/// Everything [`build`] merges.
#[derive(Default)]
pub struct Inputs<'a> {
    pub catalog: Option<&'a CatalogFile>,
    pub lock: &'a [LockEntry],
    pub wanted: &'a [String],
    pub packages: &'a [String],
    pub modules: &'a [w::ModuleEntry],
    /// The plugins' rows ([`super::plugins::rows`]).
    pub plugins: &'a [w::Row],
    pub notes: Vec<String>,
}

/// The index of INPUTS.
pub fn build(inputs: Inputs) -> Index {
    let empty = CatalogFile::default();
    let catalog = inputs.catalog.unwrap_or(&empty);
    let archives: HashMap<&str, &Archive> = catalog
        .archives
        .iter()
        .map(|a| (a.name.as_str(), a))
        .collect();
    let lock: HashMap<&str, &LockEntry> =
        inputs.lock.iter().map(|e| (e.name.as_str(), e)).collect();
    let cat: HashMap<&str, &Pkg> = catalog
        .packages
        .iter()
        .map(|p| (p.name.as_str(), p))
        .collect();

    let mut required_by: HashMap<String, BTreeSet<String>> = HashMap::new();
    for e in inputs.lock {
        for (r, _) in &e.requires {
            required_by
                .entry(r.clone())
                .or_default()
                .insert(e.name.clone());
        }
    }
    let wanted: HashSet<&str> = inputs.wanted.iter().map(String::as_str).collect();
    let in_eld: HashSet<&str> = inputs.packages.iter().map(String::as_str).collect();
    let mut module_names: HashMap<&str, Vec<&str>> = HashMap::new();
    for m in inputs.modules {
        for p in &m.packages {
            module_names.entry(p).or_default().push(&m.name);
        }
    }

    // every name some source mentions, once, in a stable order
    let mut names: BTreeSet<&str> = BTreeSet::new();
    names.extend(cat.keys());
    names.extend(lock.keys());
    names.extend(wanted.iter());
    names.extend(in_eld.iter());
    names.extend(module_names.keys());

    let mut entries = Vec::new();
    for name in names {
        let (c, l) = (cat.get(name).copied(), lock.get(name).copied());
        let named =
            wanted.contains(name) || in_eld.contains(name) || module_names.contains_key(name);
        let mut why: Vec<w::Why> = Vec::new();
        for m in module_names.get(name).into_iter().flatten() {
            why.push(w::Why::Module((*m).to_owned()));
        }
        if l.is_some_and(|l| l.wanted) {
            why.push(w::Why::You);
        }
        if in_eld.contains(name) {
            why.push(w::Why::PackagesEld);
        }
        if wanted.contains(name) {
            why.push(w::Why::Ensure);
        }
        let needers: Vec<String> = if l.is_some() {
            required_by
                .get(name)
                .map(|s| s.iter().cloned().collect())
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        if !needers.is_empty() {
            why.push(w::Why::NeededBy(needers));
        }
        let git = l.is_some_and(|l| l.kind.as_deref() == Some("git"));
        if l.is_some_and(|l| !git && !l.has_sha256) {
            why.push(w::Why::ByHand);
        }

        let state = match (l, c) {
            (Some(_), Some(c)) if c.incompat => w::State::Incompat,
            (Some(_), Some(c)) if c.update.is_some() => w::State::Update,
            (Some(_), Some(c)) if c.held => w::State::Held,
            (Some(_), _) if matches!(why.as_slice(), [w::Why::NeededBy(_)]) => w::State::Dependency,
            (Some(_), _) => w::State::Installed,
            (None, _) if named => w::State::Missing,
            (None, _) => w::State::Available,
        };

        let candidate = c.and_then(|c| c.candidate.as_ref());
        let archive = if git {
            "git".to_owned()
        } else {
            l.and_then(|l| l.archive.clone())
                .or_else(|| candidate.map(|k| k.archive.clone()))
                .or_else(|| {
                    c.and_then(|c| c.versions.first())
                        .map(|v| v.archive.clone())
                })
                .unwrap_or_default()
        };
        let info = archives.get(archive.as_str());
        let signed = if l.is_some_and(|l| l.verified) {
            w::Signed::Signed
        } else if git {
            w::Signed::GitCommit
        } else if let Some(a) = info {
            if !a.url.starts_with("http") {
                w::Signed::Local
            } else if !a.signed {
                w::Signed::UnsignedArchive
            } else {
                // from an archive that signs, with no verified lock entry (not installed yet): the sync checks it
                w::Signed::SigningArchive
            }
        } else {
            w::Signed::None
        };

        let latest = match state {
            w::State::Update => c.and_then(|c| c.update.as_ref()).map(|u| u.to.clone()),
            w::State::Available | w::State::Missing => candidate.map(|k| k.version.clone()),
            _ => None,
        };
        let summary = c
            .map(|c| c.summary.clone())
            .filter(|s| !s.is_empty())
            .or_else(|| l.and_then(|l| l.summary.clone()))
            .unwrap_or_default();
        let requires: Vec<w::Requirement> = match (l, c) {
            (Some(l), _) => l
                .requires
                .iter()
                .map(|(n, v)| w::Requirement {
                    name: n.clone(),
                    version: v.clone(),
                })
                .collect(),
            (None, Some(c)) => c
                .versions
                .iter()
                .find(|v| {
                    candidate.is_some_and(|k| k.archive == v.archive && k.version == v.version)
                })
                .or(c.versions.first())
                .map(|v| {
                    v.reqs
                        .iter()
                        .map(|(n, ver)| w::Requirement {
                            name: n.clone(),
                            version: Some(ver.clone()),
                        })
                        .collect()
                })
                .unwrap_or_default(),
            (None, None) => Vec::new(),
        };
        let row = w::Row {
            id: format!("pkg:{name}"),
            kind: w::Kind::Package,
            name: name.to_owned(),
            summary,
            state,
            source: archive,
            signed,
            version: l.and_then(|l| l.version.clone()),
            latest,
            downloads: c.and_then(|c| c.downloads),
            why,
        };
        let detail = Detail {
            requires,
            maintainer: c.and_then(|c| c.maintainer.clone()),
            url: c
                .and_then(|c| c.url.clone())
                .or_else(|| l.and_then(|l| l.url.clone())),
            commit: l
                .and_then(|l| l.commit.clone())
                .or_else(|| c.and_then(|c| c.commit.clone())),
            revdesc: c.and_then(|c| c.revdesc.clone()),
        };
        entries.push(Entry::new(
            row,
            c.map(|c| c.keywords.clone()).unwrap_or_default(),
            detail,
        ));
    }

    for b in &catalog.builtins {
        let row = w::Row {
            id: format!("emacs:{}", b.name),
            kind: w::Kind::Emacs,
            name: b.name.clone(),
            summary: b.summary.clone(),
            state: w::State::BuiltIn,
            source: "emacs".into(),
            signed: w::Signed::None,
            version: Some(b.version.clone()).filter(|v| !v.is_empty()),
            latest: None,
            downloads: None,
            why: Vec::new(),
        };
        entries.push(Entry::new(row, Vec::new(), Detail::default()));
    }

    for m in inputs.modules {
        let row = w::Row {
            id: format!("module:{}", m.name),
            kind: w::Kind::Module,
            name: m.name.clone(),
            summary: m.doc.lines().next().unwrap_or("").to_owned(),
            state: match m.state {
                w::ModuleState::On => w::State::On,
                w::ModuleState::Off => w::State::Off,
                w::ModuleState::NeedsPackage => w::State::NeedsPackage,
                w::ModuleState::Failed => w::State::Failed,
            },
            source: "module".into(),
            signed: w::Signed::None,
            version: None,
            latest: None,
            downloads: None,
            why: Vec::new(),
        };
        let detail = Detail {
            requires: m
                .packages
                .iter()
                .map(|p| w::Requirement {
                    name: p.clone(),
                    version: None,
                })
                .collect(),
            ..Detail::default()
        };
        entries.push(Entry::new(row, m.flags.clone(), detail));
    }

    for row in inputs.plugins {
        entries.push(Entry::new(row.clone(), Vec::new(), Detail::default()));
    }

    let by_id = entries
        .iter()
        .enumerate()
        .map(|(i, e)| (e.row.id.clone(), i))
        .collect();
    let mut notes = inputs.notes;
    if inputs.catalog.is_none() {
        notes.push("there is no catalog yet: the refresh job has not run".into());
    } else if !catalog.skipped.is_empty() {
        notes.push(format!(
            "the refresh skipped {} entries it could not use",
            catalog.skipped.len()
        ));
    }
    Index {
        entries,
        by_id,
        required_by: required_by
            .into_iter()
            .map(|(k, v)| (k, v.into_iter().collect()))
            .collect(),
        notes,
    }
}

/// A file the cache reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Src {
    Catalog,
    Lock,
    Wanted,
    Packages,
}

impl Src {
    pub const ALL: [Src; 4] = [Src::Catalog, Src::Lock, Src::Wanted, Src::Packages];

    /// The most it reads: the user's lock can outgrow huginn's 1 MiB default.
    pub fn max(self) -> usize {
        match self {
            Src::Catalog => 64 << 20,
            Src::Lock => 8 << 20,
            Src::Wanted | Src::Packages => 1 << 20,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Src::Catalog => "the catalog",
            Src::Lock => "the lock",
            Src::Wanted => "the wanted file",
            Src::Packages => "packages.eld",
        }
    }
}

/// When a file last changed and how big it is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Sig {
    pub mtime_ns: u128,
    pub size: u64,
}

/// The files the cache looks at, injected so a test counts the reads.
pub trait Files {
    /// The file's signature; none when it is not there.
    fn stat(&self, src: Src) -> Option<Sig>;
    fn read(&self, src: Src) -> io::Result<Vec<u8>>;
}

/// The last good copy of each source and the index built from them.
#[derive(Default)]
pub struct Cache {
    seen: HashMap<Src, Option<Sig>>,
    catalog: Option<CatalogFile>,
    lock: Vec<LockEntry>,
    wanted: Vec<String>,
    packages: Vec<String>,
    modules: Vec<w::ModuleEntry>,
    plugins: Vec<w::Row>,
    notes: HashMap<Src, String>,
    index: Arc<Index>,
    dirty: bool,
    /// How many times a source was read (a test counts them).
    pub reads: u32,
}

impl Cache {
    /// The editor's module table replaces the last one.
    pub fn set_modules(&mut self, modules: Vec<w::ModuleEntry>) {
        self.modules = modules;
        self.dirty = true;
    }

    /// The hub's plugins as rows replace the last ones; the index is built again only when they differ.
    pub fn set_plugins(&mut self, plugins: Vec<w::Row>) {
        if self.plugins != plugins {
            self.plugins = plugins;
            self.dirty = true;
        }
    }

    /// Looks at every source, reads the ones that changed and returns the index.  A source that is gone is empty; one
    /// that does not read keeps its last good copy and leaves a note.
    pub fn refresh(&mut self, files: &dyn Files) -> Arc<Index> {
        for src in Src::ALL {
            let now = files.stat(src);
            if self.seen.get(&src) == Some(&now) {
                continue;
            }
            self.seen.insert(src, now);
            self.dirty = true;
            if now.is_none() {
                self.notes.remove(&src);
                match src {
                    Src::Catalog => self.catalog = None,
                    Src::Lock => self.lock.clear(),
                    Src::Wanted => self.wanted.clear(),
                    Src::Packages => self.packages.clear(),
                }
                continue;
            }
            self.reads += 1;
            let loaded = files
                .read(src)
                .map_err(|e| e.to_string())
                .and_then(|b| match src {
                    Src::Catalog => parse_catalog(&b).map(|c| self.catalog = Some(c)),
                    Src::Lock => parse_lock(&b).map(|l| self.lock = l),
                    Src::Wanted => parse_names(&b).map(|n| self.wanted = n),
                    Src::Packages => parse_packages(&b).map(|n| self.packages = n),
                });
            match loaded {
                Ok(()) => {
                    self.notes.remove(&src);
                }
                Err(e) => {
                    self.notes.insert(
                        src,
                        format!(
                            "{} was not read ({e}); the last good copy is kept",
                            src.label()
                        ),
                    );
                }
            }
        }
        if self.dirty {
            self.dirty = false;
            let mut notes: Vec<String> = Src::ALL
                .iter()
                .filter_map(|s| self.notes.get(s).cloned())
                .collect();
            notes.sort();
            self.index = Arc::new(build(Inputs {
                catalog: self.catalog.as_ref(),
                lock: &self.lock,
                wanted: &self.wanted,
                packages: &self.packages,
                modules: &self.modules,
                plugins: &self.plugins,
                notes,
            }));
        }
        self.index.clone()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::extensions::rank;
    use skuld::{Bound, Partial, every_order};
    use std::cell::{Cell, RefCell};

    const CATALOG: &str = include_str!("../../../../../test/fixtures/extensions/catalog.json");
    const LOCK: &str = include_str!("../../../../../test/fixtures/extensions/drgnx.lock.eld");
    const WANTED: &str =
        include_str!("../../../../../test/fixtures/extensions/packages-wanted.eld");
    const PACKAGES: &str = include_str!("../../../../../test/fixtures/extensions/packages.eld");

    /// Files held in memory: a write bumps the signature, and every read is counted.
    #[derive(Default)]
    struct Fake {
        files: RefCell<HashMap<Src, (Sig, Vec<u8>)>>,
        reads: Cell<u32>,
        tick: Cell<u128>,
    }

    impl Fake {
        fn put(&self, src: Src, text: &str) {
            self.tick.set(self.tick.get() + 1);
            let sig = Sig {
                mtime_ns: self.tick.get(),
                size: text.len() as u64,
            };
            self.files
                .borrow_mut()
                .insert(src, (sig, text.as_bytes().to_vec()));
        }

        fn fixtures() -> Fake {
            let f = Fake::default();
            f.put(Src::Catalog, CATALOG);
            f.put(Src::Lock, LOCK);
            f.put(Src::Wanted, WANTED);
            f.put(Src::Packages, PACKAGES);
            f
        }
    }

    impl Files for Fake {
        fn stat(&self, src: Src) -> Option<Sig> {
            self.files.borrow().get(&src).map(|(s, _)| *s)
        }
        fn read(&self, src: Src) -> io::Result<Vec<u8>> {
            self.reads.set(self.reads.get() + 1);
            self.files
                .borrow()
                .get(&src)
                .map(|(_, b)| b.clone())
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
        }
    }

    fn module(name: &str, packages: &[&str]) -> w::ModuleEntry {
        w::ModuleEntry {
            name: name.into(),
            doc: format!("The {name} module.\nMore."),
            packages: packages.iter().map(|s| s.to_string()).collect(),
            flags: Vec::new(),
            state: w::ModuleState::On,
        }
    }

    fn fixture_index() -> Arc<Index> {
        let files = Fake::fixtures();
        let mut cache = Cache::default();
        cache.set_modules(vec![module("git", &["magit"])]);
        cache.refresh(&files)
    }

    fn row<'a>(i: &'a Index, id: &str) -> &'a w::Row {
        &i.entry(id).unwrap_or_else(|| panic!("no row {id}")).row
    }

    // pattern D
    #[test]
    fn signed_needs_verified_in_the_lock() {
        let i = fixture_index();
        // a gnu entry with :verified t is signed; the same archive without it is a signing archive, not unsigned
        assert_eq!(row(&i, "pkg:with-editor").signed, w::Signed::Signed);
        assert_eq!(
            serde_json::to_value(row(&i, "pkg:dash").signed).unwrap(),
            "signing-archive"
        );
        // MELPA does not sign, a directory archive is local, a repository is a commit
        assert_eq!(row(&i, "pkg:magit").signed, w::Signed::UnsignedArchive);
        assert_eq!(row(&i, "pkg:in-a-directory").signed, w::Signed::Local);
        assert_eq!(row(&i, "pkg:from-a-repo").signed, w::Signed::GitCommit);
    }

    // pattern D
    #[test]
    fn why_lists_module_you_ensure_and_needed_by() {
        let i = fixture_index();
        assert_eq!(
            row(&i, "pkg:magit").why,
            vec![w::Why::Module("git".into()), w::Why::You, w::Why::Ensure]
        );
        assert_eq!(
            row(&i, "pkg:with-editor").why,
            vec![w::Why::NeededBy(vec!["magit".into()])]
        );
        assert_eq!(row(&i, "pkg:with-editor").state, w::State::Dependency);
        assert_eq!(
            row(&i, "pkg:dash").why,
            vec![w::Why::NeededBy(vec!["magit".into(), "with-editor".into()])]
        );
        assert_eq!(row(&i, "pkg:handmade").why, vec![w::Why::ByHand]);
        assert_eq!(row(&i, "pkg:from-a-repo").why, vec![w::Why::PackagesEld]);
        // named and not in the lock: missing, with the file that names it
        assert_eq!(row(&i, "pkg:forge").state, w::State::Missing);
        assert_eq!(row(&i, "pkg:forge").why, vec![w::Why::Ensure]);
        assert_eq!(row(&i, "pkg:git-link").state, w::State::Missing);
        assert_eq!(row(&i, "pkg:git-link").why, vec![w::Why::PackagesEld]);
        assert_eq!(row(&i, "pkg:magit-todos").state, w::State::Available);
    }

    // pattern D
    #[test]
    fn held_and_update_follow_the_catalog() {
        let i = fixture_index();
        let magit = row(&i, "pkg:magit");
        assert_eq!(magit.state, w::State::Update);
        assert_eq!(magit.version.as_deref(), Some("4.1"));
        assert_eq!(magit.latest.as_deref(), Some("20261104.815"));
        assert_eq!(row(&i, "pkg:dash").state, w::State::Held);
        assert_eq!(row(&i, "pkg:newer-emacs-only").state, w::State::Incompat);
        // available: the version an install would take
        assert_eq!(
            row(&i, "pkg:magit-todos").latest.as_deref(),
            Some("20260901.100")
        );
        assert_eq!(row(&i, "pkg:magit").downloads, Some(4212345));
        assert_eq!(row(&i, "emacs:eglot").state, w::State::BuiltIn);
        assert_eq!(row(&i, "module:git").state, w::State::On);
        assert_eq!(row(&i, "module:git").summary, "The git module.");
    }

    // pattern D
    #[test]
    fn a_changed_file_is_read_again_and_an_unchanged_one_is_not() {
        let files = Fake::fixtures();
        let mut cache = Cache::default();
        let first = cache.refresh(&files);
        assert_eq!(files.reads.get(), 4);
        let second = cache.refresh(&files);
        assert_eq!(files.reads.get(), 4, "nothing changed: a stat, no read");
        assert!(Arc::ptr_eq(&first, &second), "the same index is handed out");
        files.put(Src::Wanted, "(forge)\n");
        let third = cache.refresh(&files);
        assert_eq!(files.reads.get(), 5, "only the changed file is read");
        assert_eq!(
            row(&third, "pkg:magit").why.len(),
            1,
            "no more :ensure for it"
        );
    }

    fn catalog_of(generation: u32) -> String {
        let packages: Vec<_> = (0..=generation)
            .map(|n| {
                serde_json::json!({"name": format!("p{n}"), "summary": format!("gen {generation}")})
            })
            .collect();
        serde_json::json!({"version": 1, "packages": packages}).to_string()
    }

    skuld::events!(Ev { Publish, Call });

    #[derive(Clone, Debug)]
    enum Ev {
        Publish(u32),
        Call,
    }

    /// A catalog written by the refresh job and calls that read it: one cache, one set of files.
    struct Shell {
        files: Fake,
        cache: Cache,
        seen: Vec<(u32, Vec<String>)>,
    }

    impl skuld::Core for Shell {
        type Event = Ev;
        fn step(&mut self, ev: Ev) -> Vec<Ev> {
            match ev {
                Ev::Publish(n) => self.files.put(Src::Catalog, &catalog_of(n)),
                Ev::Call => {
                    let index = self.cache.refresh(&self.files);
                    let hits =
                        rank::search(&index.entries, "", &w::Filters::default(), w::Sort::Name);
                    let summaries = hits
                        .iter()
                        .map(|&i| index.entries[i].row.summary.clone())
                        .collect();
                    self.seen.push((hits.len() as u32, summaries));
                }
            }
            Vec::new()
        }
    }

    // pattern A: the refresh job's write against the calls, in every order
    #[test]
    fn every_order_reload_and_search_see_one_whole_catalog() {
        let mut p = Partial::new();
        p.source("job", vec![Ev::Publish(1), Ev::Publish(2)]);
        p.source("calls", vec![Ev::Call, Ev::Call, Ev::Call]);
        every_order(
            &p,
            Bound::default(),
            || {
                let files = Fake::default();
                files.put(Src::Catalog, &catalog_of(0));
                Shell {
                    files,
                    cache: Cache::default(),
                    seen: Vec::new(),
                }
            },
            |shell, _| {
                let mut last = 0;
                for (count, summaries) in &shell.seen {
                    let generation = count - 1;
                    if summaries.iter().any(|s| *s != format!("gen {generation}")) {
                        return Err(format!("a mixed catalog: {summaries:?}"));
                    }
                    if generation < last {
                        return Err("a call saw an older catalog than the one before".into());
                    }
                    last = generation;
                }
                Ok(())
            },
        );
    }

    // pattern D
    #[test]
    fn a_bad_catalog_keeps_the_last_good_one() {
        let files = Fake::fixtures();
        let mut cache = Cache::default();
        let good = cache.refresh(&files);
        let before = good.entries.len();
        files.put(Src::Catalog, &CATALOG[..CATALOG.len() / 2]);
        let kept = cache.refresh(&files);
        assert_eq!(kept.entries.len(), before, "the previous rows");
        assert!(
            kept.notes.iter().any(|n| n.contains("the catalog")),
            "a status line: {:?}",
            kept.notes
        );
        // and the next good one replaces it, the note gone
        files.put(Src::Catalog, CATALOG);
        let again = cache.refresh(&files);
        assert!(again.notes.iter().all(|n| !n.contains("the catalog")));
    }

    // pattern D
    #[test]
    fn a_catalog_of_another_version_is_refused() {
        let files = Fake::fixtures();
        let mut cache = Cache::default();
        cache.refresh(&files);
        files.put(Src::Catalog, "{\"version\": 2, \"packages\": []}");
        let kept = cache.refresh(&files);
        assert!(row(&kept, "pkg:magit").summary.contains("porcelain"));
        assert!(kept.notes.iter().any(|n| n.contains("version")));
    }
}
