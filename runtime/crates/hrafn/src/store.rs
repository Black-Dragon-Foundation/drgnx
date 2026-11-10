//! The code store: files, chunks, FTS columns, symbols and content-keyed vectors in one SQLite file, opened through
//! `urdr` (one owning thread, WAL, migrations as data).

use crate::schema::{MIGRATIONS, encode_symbol};
use rusqlite::{Connection, params};
use sha2::{Digest, Sha256};
use std::fmt;
use std::path::Path;
use urdr::{Handle, Mode, Store, StoreSpec};

#[derive(Debug)]
pub enum StoreError {
    Store(urdr::Error),
    Sqlite(rusqlite::Error),
    /// A read of a checkout or its git, for the overlay.
    Io(std::io::Error),
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StoreError::Store(e) => write!(f, "code store: {e}"),
            StoreError::Sqlite(e) => write!(f, "code store: {e}"),
            StoreError::Io(e) => write!(f, "code store: {e}"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<urdr::Error> for StoreError {
    fn from(e: urdr::Error) -> Self {
        StoreError::Store(e)
    }
}

impl From<std::io::Error> for StoreError {
    fn from(e: std::io::Error) -> Self {
        StoreError::Io(e)
    }
}

impl From<rusqlite::Error> for StoreError {
    fn from(e: rusqlite::Error) -> Self {
        StoreError::Store(urdr::Error::Sqlite(e))
    }
}

/// One row of `file` (the tree is the caller's: the base, or a worktree's view). A `blob` of none is a tombstone: the
/// worktree does not have the path (or does not admit it) while the base does; only a worktree's row can be one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileRow {
    pub path: String,
    pub blob: Option<String>,
    pub class: String,
    pub lang: String,
    pub generated: bool,
    pub size: u64,
    pub indexed_at: i64,
}

/// A chunk to write. `symbols` is the raw symbol text: it is encoded (see [`encode_symbol`]) on its way into the FTS
/// column. `key` is [`vec_key`] of the chunker version and `embed_text`.
#[derive(Clone, Debug)]
pub struct ChunkIn {
    pub start: u32,
    pub end: u32,
    pub line_start: u32,
    pub line_end: u32,
    pub symbol: Option<String>,
    pub key: [u8; 32],
    pub embed: bool,
    pub embed_text: String,
    pub symbols: String,
    pub doc: String,
    pub body: String,
}

/// A symbol to write; `chunk` is an index into the chunks of the same `replace_file` call.
#[derive(Clone, Debug, Default)]
pub struct SymbolIn {
    pub name: String,
    pub kind: String,
    pub start: u32,
    pub end: u32,
    pub chunk: usize,
    pub definer: String,
    pub doc1: Option<String>,
    pub line_start: u32,
    pub line_end: u32,
    pub sig: String,
}

/// A name the content uses (`chunk::Ref`): how often, and its first lines (at most 8 are kept).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RefIn {
    pub name: String,
    pub n: u32,
    pub lines: Vec<u32>,
}

/// One row of `vec`: a quantized vector of one model for one content key.
#[derive(Clone, Debug)]
pub struct VecRow {
    pub model: String,
    pub dims: u32,
    pub key: [u8; 32],
    pub bits: u8,
    pub vec: Vec<u8>,
    pub scale: f32,
    pub last_used: i64,
}

/// The key of a chunk's content: sha256 over length-prefixed fields (the chunker version, then the text), so a key
/// plus its row names the model, dims, chunker and text.
pub fn vec_key(chunker: u32, embed_text: &str) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(4u64.to_be_bytes());
    h.update(chunker.to_be_bytes());
    h.update((embed_text.len() as u64).to_be_bytes());
    h.update(embed_text.as_bytes());
    h.finalize().into()
}

/// TREE's blob of PATH: none when TREE has no row, `Some(None)` for a tombstone.
pub(crate) fn row_blob(
    c: &Connection,
    tree: i64,
    path: &str,
) -> urdr::Result<Option<Option<String>>> {
    let mut st = c.prepare("select blob from file where tree = ?1 and path = ?2")?;
    let mut rows = st.query(params![tree, path])?;
    Ok(match rows.next()? {
        Some(r) => Some(r.get(0)?),
        None => None,
    })
}

/// The reference sweep of one pair: `(path, blob)`'s chunks (their FTS rows and symbols go by trigger) and references
/// are deleted when no `file` row names the pair any more. Whether they went.
pub(crate) fn sweep(c: &Connection, path: &str, blob: &str) -> urdr::Result<bool> {
    let named: bool = c
        .prepare("select exists(select 1 from file where path = ?1 and blob = ?2)")?
        .query_row(params![path, blob], |r| r.get(0))?;
    if named {
        return Ok(false);
    }
    c.prepare("delete from chunk where path = ?1 and blob = ?2")?
        .execute(params![path, blob])?;
    c.prepare("delete from ref where path = ?1 and blob = ?2")?
        .execute(params![path, blob])?;
    Ok(true)
}

/// Every pair no `file` row names, swept at once (after a bulk delete of rows).
pub(crate) fn sweep_all(c: &Connection) -> urdr::Result<()> {
    c.execute(
        "delete from chunk where not exists
           (select 1 from file f where f.path = chunk.path and f.blob = chunk.blob)",
        [],
    )?;
    c.execute(
        "delete from ref where not exists
           (select 1 from file f where f.path = ref.path and f.blob = ref.blob)",
        [],
    )?;
    Ok(())
}

/// `(path, blob)`'s chunk ids, in order (empty: the pair has no content stored).
pub(crate) fn content_ids(c: &Connection, path: &str, blob: &str) -> urdr::Result<Vec<i64>> {
    let mut st = c.prepare("select id from chunk where path = ?1 and blob = ?2 order by id")?;
    let ids = st
        .query_map(params![path, blob], |r| r.get(0))?
        .collect::<Result<Vec<i64>, _>>()?;
    Ok(ids)
}

/// TREE's row of a file, inside the caller's transaction; the pair the row named before is swept.
pub(crate) fn write_file_row(c: &Connection, tree: i64, f: &FileRow) -> urdr::Result<()> {
    let old = row_blob(c, tree, &f.path)?.flatten();
    c.prepare(
        "insert or replace into file(tree, path, blob, class, lang, generated, size, indexed_at)
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
    )?
    .execute(params![
        tree,
        f.path,
        f.blob,
        f.class,
        f.lang,
        f.generated,
        f.size as i64,
        f.indexed_at
    ])?;
    if let Some(o) = old.filter(|o| Some(o) != f.blob.as_ref()) {
        sweep(c, &f.path, &o)?;
    }
    Ok(())
}

/// TREE's row of PATH removed, inside the caller's transaction, and its pair swept.
pub(crate) fn remove_file_row(c: &Connection, tree: i64, path: &str) -> urdr::Result<()> {
    let old = row_blob(c, tree, path)?.flatten();
    c.prepare("delete from file where tree = ?1 and path = ?2")?
        .execute(params![tree, path])?;
    if let Some(o) = old {
        sweep(c, path, &o)?;
    }
    Ok(())
}

/// `(path, blob)`'s chunks, FTS rows, symbols and references in place of what the pair had, inside the caller's
/// transaction. The new chunk ids, in order.
pub(crate) fn write_chunks(
    c: &Connection,
    path: &str,
    blob: &str,
    chunks: &[ChunkIn],
    symbols: &[SymbolIn],
    refs: &[RefIn],
) -> urdr::Result<Vec<i64>> {
    c.prepare("delete from chunk where path = ?1 and blob = ?2")?
        .execute(params![path, blob])?;
    c.prepare("delete from ref where path = ?1 and blob = ?2")?
        .execute(params![path, blob])?;
    for r in refs {
        let lines: Vec<String> = r.lines.iter().map(u32::to_string).collect();
        c.prepare("insert into ref(path, blob, name, n, lines) values (?1, ?2, ?3, ?4, ?5)")?
            .execute(params![path, blob, r.name, r.n, lines.join(" ")])?;
    }
    let mut ids = Vec::with_capacity(chunks.len());
    for ch in chunks {
        c.prepare(
            "insert into chunk(path, blob, start, end, line_start, line_end, symbol, key, embed, embed_text)
             values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        )?
        .execute(params![
            path,
            blob,
            ch.start,
            ch.end,
            ch.line_start,
            ch.line_end,
            ch.symbol,
            ch.key.as_slice(),
            ch.embed,
            ch.embed_text
        ])?;
        let id = c.last_insert_rowid();
        c.prepare(
            "insert into chunk_fts(rowid, path, symbols, doc, body) values (?1, ?2, ?3, ?4, ?5)",
        )?
        .execute(params![
            id,
            path,
            encode_symbol(&ch.symbols),
            ch.doc,
            ch.body
        ])?;
        ids.push(id);
    }
    for s in symbols {
        let chunk = ids.get(s.chunk).copied().ok_or(urdr::Error::Aborted)?;
        c.prepare(
            "insert into symbol(name, kind, path, blob, start, end, chunk, definer, doc1, line_start, line_end, sig)
             values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        )?
        .execute(params![
            s.name,
            s.kind,
            path,
            blob,
            s.start,
            s.end,
            chunk,
            s.definer,
            s.doc1,
            s.line_start,
            s.line_end,
            s.sig
        ])?;
    }
    Ok(ids)
}

impl FileRow {
    /// A worktree's tombstone of PATH.
    pub fn tombstone(path: &str) -> FileRow {
        FileRow {
            path: path.to_string(),
            blob: None,
            class: String::new(),
            lang: String::new(),
            generated: false,
            size: 0,
            indexed_at: 0,
        }
    }
}

/// TREE's row of a file and, unless its pair already has content (shared with another row; FORCE rewrites it, after
/// a chunker change), the pair's chunks and symbols from BUILT. The pair's chunk ids; none, with nothing written, when
/// the pair has no content and BUILT is none (the caller reads and chunks it, then writes again). A tombstone writes
/// its row only.
pub(crate) fn write_version(
    c: &Connection,
    tree: i64,
    f: &FileRow,
    built: Option<(&[ChunkIn], &[SymbolIn], &[RefIn])>,
    force: bool,
) -> urdr::Result<Option<Vec<i64>>> {
    let Some(blob) = f.blob.as_deref() else {
        write_file_row(c, tree, f)?;
        return Ok(Some(vec![]));
    };
    let have = content_ids(c, &f.path, blob)?;
    if !have.is_empty() && !force {
        write_file_row(c, tree, f)?;
        return Ok(Some(have));
    }
    let Some((chunks, symbols, refs)) = built else {
        return Ok(None);
    };
    write_file_row(c, tree, f)?;
    write_chunks(c, &f.path, blob, chunks, symbols, refs).map(Some)
}

pub struct CodeStore {
    store: Option<Store>,
    handle: Handle,
    memo: crate::memo::Shared,
}

impl CodeStore {
    /// Open (creating and migrating) the store at `path`, WAL, mode 0600. The binary passes
    /// `<state>/code/<project-id>.db`.
    pub fn open(path: &Path) -> Result<CodeStore, StoreError> {
        let (store, handle) = Store::spawn(StoreSpec {
            path: path.to_path_buf(),
            mode: Mode::ReadWrite {
                file_mode: 0o600,
                synchronous_full: false,
            },
            migrations: MIGRATIONS,
        })?;
        Ok(CodeStore {
            store: Some(store),
            handle,
            memo: Default::default(),
        })
    }

    /// The `urdr` handle, for reads and writes this API does not cover yet (closures run on the store thread).
    pub fn handle(&self) -> &Handle {
        &self.handle
    }

    /// What queries keep between two changes of the store (`memo.rs`).
    pub(crate) fn memo(&self) -> crate::memo::Shared {
        self.memo.clone()
    }

    /// Insert or replace a file's base row (the content the row named before is swept when nothing else names it).
    pub async fn put_file(&self, f: FileRow) -> Result<(), StoreError> {
        Ok(self.handle.write(move |c| write_file_row(c, 0, &f)).await?)
    }

    /// Replace everything stored for `(path, blob)`'s chunks and symbols in one transaction. Returns the new chunk
    /// ids, in order.
    pub async fn replace_chunks(
        &self,
        path: &str,
        blob: &str,
        chunks: Vec<ChunkIn>,
        symbols: Vec<SymbolIn>,
    ) -> Result<Vec<i64>, StoreError> {
        let (path, blob) = (path.to_string(), blob.to_string());
        Ok(self
            .handle
            .write(move |c| write_chunks(c, &path, &blob, &chunks, &symbols, &[]))
            .await?)
    }

    /// Remove a file's base row, with its chunks, FTS rows and symbols unless a worktree's row still names them.
    pub async fn delete_file(&self, path: &str) -> Result<(), StoreError> {
        let path = path.to_string();
        Ok(self
            .handle
            .write(move |c| remove_file_row(c, 0, &path))
            .await?)
    }

    /// Insert or replace a vector.
    pub async fn put_vec(&self, v: VecRow) -> Result<(), StoreError> {
        Ok(self
            .handle
            .write(move |c| {
                c.execute(
                    "insert or replace into vec(model, dims, key, bits, vec, scale, last_used)
                     values (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![
                        v.model,
                        v.dims,
                        v.key.as_slice(),
                        v.bits,
                        v.vec,
                        v.scale,
                        v.last_used
                    ],
                )?;
                Ok(())
            })
            .await?)
    }

    pub async fn meta_get(&self, key: &str) -> Result<Option<String>, StoreError> {
        let key = key.to_string();
        Ok(self.handle.read(move |c| urdr::meta(c, &key)).await?)
    }

    pub async fn meta_set(&self, key: &str, value: &str) -> Result<(), StoreError> {
        let (key, value) = (key.to_string(), value.to_string());
        Ok(self
            .handle
            .write(move |c| {
                c.execute(
                    "insert or replace into meta(key, value) values (?1, ?2)",
                    [&key, &value],
                )?;
                Ok(())
            })
            .await?)
    }

    /// `VACUUM`. Chunk ids are `INTEGER PRIMARY KEY` rowids, so they survive, and so does the FTS rowid link.
    pub async fn vacuum(&self) -> Result<(), StoreError> {
        Ok(self
            .handle
            .read(|c| {
                c.execute_batch("vacuum")?;
                Ok(())
            })
            .await?)
    }

    /// Stop the store thread and close the connection. Blocking: not for an async worker.
    pub fn shutdown(mut self) {
        if let Some(s) = self.store.take() {
            s.shutdown();
        }
    }
}
