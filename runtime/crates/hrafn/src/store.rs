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
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StoreError::Store(e) => write!(f, "code store: {e}"),
            StoreError::Sqlite(e) => write!(f, "code store: {e}"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<urdr::Error> for StoreError {
    fn from(e: urdr::Error) -> Self {
        StoreError::Store(e)
    }
}

impl From<rusqlite::Error> for StoreError {
    fn from(e: rusqlite::Error) -> Self {
        StoreError::Store(urdr::Error::Sqlite(e))
    }
}

/// One row of `file`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileRow {
    pub path: String,
    pub blob: String,
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
#[derive(Clone, Debug)]
pub struct SymbolIn {
    pub name: String,
    pub kind: String,
    pub start: u32,
    pub end: u32,
    pub chunk: usize,
    pub definer: String,
    pub doc1: Option<String>,
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

/// A file's row, inside the caller's transaction.
pub(crate) fn write_file_row(c: &Connection, f: &FileRow) -> urdr::Result<()> {
    c.execute(
        "insert or replace into file(path, blob, class, lang, generated, size, indexed_at)
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            f.path,
            f.blob,
            f.class,
            f.lang,
            f.generated,
            f.size as i64,
            f.indexed_at
        ],
    )?;
    Ok(())
}

/// `path`'s chunks, FTS rows and symbols in place of what it had, inside the caller's transaction. The new chunk ids,
/// in order.
pub(crate) fn write_chunks(
    c: &Connection,
    path: &str,
    chunks: &[ChunkIn],
    symbols: &[SymbolIn],
) -> urdr::Result<Vec<i64>> {
    c.execute("delete from chunk where path = ?1", [path])?;
    let mut ids = Vec::with_capacity(chunks.len());
    for ch in chunks {
        c.execute(
            "insert into chunk(path, start, end, line_start, line_end, symbol, key, embed, embed_text)
             values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                path,
                ch.start,
                ch.end,
                ch.line_start,
                ch.line_end,
                ch.symbol,
                ch.key.as_slice(),
                ch.embed,
                ch.embed_text
            ],
        )?;
        let id = c.last_insert_rowid();
        c.execute(
            "insert into chunk_fts(rowid, path, symbols, doc, body) values (?1, ?2, ?3, ?4, ?5)",
            params![id, path, encode_symbol(&ch.symbols), ch.doc, ch.body],
        )?;
        ids.push(id);
    }
    for s in symbols {
        let chunk = ids.get(s.chunk).copied().ok_or(urdr::Error::Aborted)?;
        c.execute(
            "insert into symbol(name, kind, path, start, end, chunk, definer, doc1)
             values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                s.name, s.kind, path, s.start, s.end, chunk, s.definer, s.doc1
            ],
        )?;
    }
    Ok(ids)
}

pub struct CodeStore {
    store: Option<Store>,
    handle: Handle,
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
        })
    }

    /// The `urdr` handle, for reads and writes this API does not cover yet (closures run on the store thread).
    pub fn handle(&self) -> &Handle {
        &self.handle
    }

    /// Insert or replace a file's row.
    pub async fn put_file(&self, f: FileRow) -> Result<(), StoreError> {
        Ok(self.handle.write(move |c| write_file_row(c, &f)).await?)
    }

    /// Replace everything stored for `path`'s chunks and symbols in one transaction. Returns the new chunk ids, in
    /// order.
    pub async fn replace_chunks(
        &self,
        path: &str,
        chunks: Vec<ChunkIn>,
        symbols: Vec<SymbolIn>,
    ) -> Result<Vec<i64>, StoreError> {
        let path = path.to_string();
        Ok(self
            .handle
            .write(move |c| write_chunks(c, &path, &chunks, &symbols))
            .await?)
    }

    /// Remove a file with its chunks, FTS rows and symbols.
    pub async fn delete_file(&self, path: &str) -> Result<(), StoreError> {
        let path = path.to_string();
        Ok(self
            .handle
            .write(move |c| {
                c.execute("delete from chunk where path = ?1", [&path])?;
                c.execute("delete from file where path = ?1", [&path])?;
                Ok(())
            })
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
