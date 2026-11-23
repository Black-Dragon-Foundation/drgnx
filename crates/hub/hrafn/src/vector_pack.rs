//! Vector packs (Hrafn redesign §9): an index's vectors as one file, to be exported on one machine and imported on
//! another (`ratatoskr search export` and `import`; the hub's side is `ratatoskr::search::packs`).
//!
//! - **What is in it.** A SQLite file of two tables: `meta(key, value)`, the header (the format, the fingerprint's
//!   record as JSON, when and by which tool it was made, and optionally the repo's URL and commit, for display only), and
//!   `vec(kind, key, bits, vec, scale)`, one row per chunk or path vector in the form the cache stores it. **No path,
//!   no chunk text, no file list**: a key is a hash, and what it hashes stays with the code.
//! - **Content-addressed.** The rows are written in key order in one transaction, with a fixed page size and no journal, so
//!   the same header and rows are the same bytes; [`write_pack`] returns the file's sha256.
//! - **Strict reading.** [`read_pack`] refuses a format it does not know, a table or a column or a header field it did not
//!   define, and anything that is not a pack, so nothing rides along in a file that looks like one.

use crate::cache::QuantRow;
use crate::store::{CodeStore, KeyKind, StoreError};
use crate::tree::View;
use rusqlite::{Connection, OpenFlags, params};
use sha2::{Digest, Sha256};
use std::io;
use std::path::Path;
use std::sync::Mutex;

/// The format this build writes and the only one it reads.
pub const PACK_FORMAT: u32 = 1;

/// The header's keys in `meta`, and which of them a pack may leave out.
const META_KEYS: [(&str, bool); 6] = [
    ("format", true),
    ("record", true),
    ("created_at", true),
    ("tool_version", true),
    ("repo_url", false),
    ("commit", false),
];

const SCHEMA: &str = "
pragma page_size = 4096;
create table meta(key text primary key, value text not null) without rowid;
create table vec(
  kind integer not null,
  key blob not null,
  bits integer not null,
  vec blob not null,
  scale real not null,
  primary key(kind, key)
) without rowid;
";

/// What a pack says of itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PackHeader {
    pub format: u32,
    /// The fingerprint's record as JSON (`FingerprintRecord::to_json`): the importer derives the fingerprint from it.
    pub record: String,
    /// Seconds since the epoch, as the exporter gave it.
    pub created_at: i64,
    pub tool_version: String,
    /// Where the code is from, for display only.
    pub repo_url: Option<String>,
    pub commit: Option<String>,
}

/// An opened pack: its rows are read on demand.
pub struct PackReader {
    conn: Mutex<Connection>,
}

fn refuse(msg: impl Into<String>) -> StoreError {
    StoreError::Io(io::Error::other(msg.into()))
}

impl PackReader {
    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        saman::lock(&self.conn)
    }

    /// The vectors in it, of both kinds.
    pub fn len(&self) -> u64 {
        self.conn()
            .query_row("select count(*) from vec", [], |r| r.get::<_, i64>(0))
            .map_or(0, |n| u64::try_from(n).unwrap_or(0))
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The keys of KIND's vectors, in key order.
    pub fn keys(&self, kind: KeyKind) -> Result<Vec<[u8; 32]>, StoreError> {
        let c = self.conn();
        let mut st = c.prepare("select key from vec where kind = ?1 order by key")?;
        let rows = st.query_map([kind.as_i64()], |r| r.get::<_, Vec<u8>>(0))?;
        let mut out = Vec::new();
        for k in rows {
            out.push(
                <[u8; 32]>::try_from(k?.as_slice())
                    .map_err(|_| refuse("a key that is not 32 bytes"))?,
            );
        }
        Ok(out)
    }

    /// The rows of those of KEYS the pack has, of KIND, in KEYS' order.
    pub fn rows(&self, kind: KeyKind, keys: &[[u8; 32]]) -> Result<Vec<QuantRow>, StoreError> {
        let c = self.conn();
        let mut st = c.prepare("select bits, vec, scale from vec where kind = ?1 and key = ?2")?;
        let mut out = Vec::new();
        for k in keys {
            let mut rows = st.query(params![kind.as_i64(), k.as_slice()])?;
            if let Some(r) = rows.next()? {
                out.push(QuantRow {
                    key: *k,
                    bits: r.get(0)?,
                    vec: r.get(1)?,
                    scale: r.get(2)?,
                });
            }
        }
        Ok(out)
    }
}

/// Which of a store's keys an export covers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExportScope {
    /// What the view sees: the base's content, a worktree's own files over it.
    View(View),
    /// Every key any tree of the store has.
    AllTrees,
}

/// The keys SCOPE covers: the chunk keys that want vectors, then the path keys (the base's, for every view).
pub async fn export_keys(
    store: &CodeStore,
    scope: ExportScope,
) -> Result<Vec<(KeyKind, [u8; 32])>, StoreError> {
    Ok(store
        .handle()
        .read(move |c| {
            let keys = |sql: &str, p: &[&dyn rusqlite::ToSql]| -> urdr::Result<Vec<[u8; 32]>> {
                let mut st = c.prepare(sql)?;
                let rows = st.query_map(p, |r| r.get::<_, Vec<u8>>(0))?;
                let mut out = Vec::new();
                for k in rows {
                    if let Ok(k) = <[u8; 32]>::try_from(k?.as_slice()) {
                        out.push(k);
                    }
                }
                Ok(out)
            };
            let chunks = match scope {
                ExportScope::AllTrees => {
                    keys("select distinct key from chunk where embed = 1", &[])?
                }
                ExportScope::View(v) => keys(
                    concat!(
                        "select distinct c.key from chunk c cross join ",
                        crate::query::seen_through!("c", "?1"),
                        " where c.embed = 1 and f.blob = c.blob"
                    ),
                    &[&v.tree()],
                )?,
            };
            let paths = keys("select distinct key from path_key", &[])?;
            Ok(chunks
                .into_iter()
                .map(|k| (KeyKind::Chunk, k))
                .chain(paths.into_iter().map(|k| (KeyKind::Path, k)))
                .collect())
        })
        .await?)
}

/// ROWS written to OUT as a pack with HEADER (an existing OUT is replaced), mode 0600. The sha256 of the file.
pub fn write_pack(
    out: &Path,
    header: &PackHeader,
    rows: impl Iterator<Item = (KeyKind, QuantRow)>,
) -> Result<[u8; 32], StoreError> {
    let mut rows: Vec<(i64, QuantRow)> = rows.map(|(k, r)| (k.as_i64(), r)).collect();
    rows.sort_by_key(|a| (a.0, a.1.key));
    rows.dedup_by(|a, b| a.0 == b.0 && a.1.key == b.1.key);
    match std::fs::remove_file(out) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }
    if !eitri::create_new(out, 0o600).map_err(|e| StoreError::Io(io::Error::other(e)))? {
        return Err(StoreError::Io(io::ErrorKind::AlreadyExists.into()));
    }
    {
        let mut c = Connection::open(out)?;
        c.query_row("pragma journal_mode = off", [], |_| Ok(()))?;
        c.execute_batch("pragma synchronous = off")?;
        c.execute_batch(SCHEMA)?;
        let tx = c.transaction()?;
        {
            let mut put = tx.prepare("insert into meta(key, value) values (?1, ?2)")?;
            let mut meta = vec![
                ("format", header.format.to_string()),
                ("record", header.record.clone()),
                ("created_at", header.created_at.to_string()),
                ("tool_version", header.tool_version.clone()),
            ];
            if let Some(u) = &header.repo_url {
                meta.push(("repo_url", u.clone()));
            }
            if let Some(h) = &header.commit {
                meta.push(("commit", h.clone()));
            }
            for (k, v) in meta {
                put.execute(params![k, v])?;
            }
            let mut put = tx.prepare(
                "insert into vec(kind, key, bits, vec, scale) values (?1, ?2, ?3, ?4, ?5)",
            )?;
            for (kind, r) in &rows {
                put.execute(params![kind, r.key.as_slice(), r.bits, r.vec, r.scale])?;
            }
        }
        tx.commit()?;
        c.close().map_err(|(_, e)| e)?;
    }
    Ok(Sha256::digest(std::fs::read(out)?).into())
}

/// The table or column names `pragma`/`sqlite_master` give, sorted.
fn names(c: &Connection, sql: &str) -> Result<Vec<String>, StoreError> {
    let mut v: Vec<String> = c
        .prepare(sql)?
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    v.sort();
    Ok(v)
}

/// PATH's header and rows. Refused: a file that is not a pack, a format other than [`PACK_FORMAT`], a table, a column
/// or a header field the format does not define.
pub fn read_pack(path: &Path) -> Result<(PackHeader, PackReader), StoreError> {
    if !path.is_file() {
        return Err(refuse(format!("{}: no such file", path.display())));
    }
    let c = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let not_a_pack = |e: StoreError| refuse(format!("{}: not a vector pack ({e})", path.display()));
    let tables = names(
        &c,
        "select name from sqlite_master where type = 'table' and name not like 'sqlite_%'",
    )
    .map_err(not_a_pack)?;
    if tables != ["meta", "vec"] {
        return Err(refuse(format!(
            "{}: not a vector pack (its tables are {tables:?})",
            path.display()
        )));
    }
    let other = names(
        &c,
        "select name from sqlite_master where type in ('view', 'trigger')",
    )?;
    if !other.is_empty() {
        return Err(refuse(format!(
            "a pack has no views or triggers ({other:?})"
        )));
    }
    for (table, want) in [
        ("meta", &["key", "value"][..]),
        ("vec", &["bits", "key", "kind", "scale", "vec"][..]),
    ] {
        let got = names(
            &c,
            &format!("select name from pragma_table_info('{table}')"),
        )?;
        if got != want {
            return Err(refuse(format!(
                "a pack's table {table} has columns {got:?}"
            )));
        }
    }
    let mut meta: Vec<(String, String)> = c
        .prepare("select key, value from meta")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<_, _>>()?;
    if let Some((k, _)) = meta
        .iter()
        .find(|(k, _)| !META_KEYS.iter().any(|(n, _)| n == k))
    {
        return Err(refuse(format!("a pack has no header field {k:?}")));
    }
    let mut take = |name: &str| -> Option<String> {
        let i = meta.iter().position(|(k, _)| k == name)?;
        Some(meta.swap_remove(i).1)
    };
    let format: u32 = take("format")
        .and_then(|f| f.parse().ok())
        .ok_or_else(|| refuse("a pack without a format"))?;
    if format != PACK_FORMAT {
        return Err(refuse(format!(
            "pack format {format}: this build reads format {PACK_FORMAT}"
        )));
    }
    let mut need = |name: &str| take(name).ok_or_else(|| refuse(format!("a pack without {name}")));
    let record = need("record")?;
    let created_at = need("created_at")?
        .parse()
        .map_err(|_| refuse("a pack's created_at is not a number"))?;
    let tool_version = need("tool_version")?;
    let header = PackHeader {
        format,
        record,
        created_at,
        tool_version,
        repo_url: take("repo_url"),
        commit: take("commit"),
    };
    Ok((
        header,
        PackReader {
            conn: Mutex::new(c),
        },
    ))
}
