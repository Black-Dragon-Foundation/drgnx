//! The machine-wide vector cache (Hrafn redesign §7.1, MP-6/7/21): one SQLite file per fingerprint,
//! `<state>/vectors/<fingerprint-hex16>.db`, written by one process (the hub) and read by every repo store's connection,
//! which attaches it read-only as `vc` (`store::ensure_vc`).
//!
//! - **Tables.** `chunk_vec` and `path_vec` `(key, bits, vec, scale, last_used)`, one per [`KeyKind`]; `meta` holds the
//!   full fingerprint and its record (a file whose `fingerprint` is another is refused, so two fingerprints with the
//!   same first 16 hex characters never share one); `holder` and `held` say which repo stores hold which keys.
//! - **One writer.** [`VectorCache::open_writer`] takes an exclusive lock on `<db>.writer` (it holds the writer's PID);
//!   a second writer is refused with [`StoreError::Busy`]. Readers ([`VectorCache::open`], and the stores' `vc`) never
//!   block: WAL.
//! - **Collection.** A key is kept while a live holder holds it; of the rest, the most recently used are kept up to a
//!   cap in bytes ([`default_cap`]: twice the held keys' bytes, at least [`MIN_CAP`]). `last_used` is a logical clock,
//!   moved by a write and by a holder's taking or dropping the key.

use crate::store::{KeyKind, StoreError};
use rusqlite::{Connection, OpenFlags, params};
use std::fs::File;
use std::io::{self, Read, Seek, Write};
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::time::Duration;
use urdr::{Handle, Mode, Store, StoreSpec};

/// A vector as the cache stores it: `vec` holds the sign bits (`dims / 8` bytes, rounded up) and then the int8 values
/// (`urdr::graph::search::vec::quantize`), `scale` their scale; `bits` is 8.
#[derive(Clone, Debug, PartialEq)]
pub struct QuantRow {
    pub key: [u8; 32],
    pub bits: u8,
    pub vec: Vec<u8>,
    pub scale: f64,
}

/// The least cap [`default_cap`] gives: 1 GiB.
pub const MIN_CAP: u64 = 1 << 30;

/// MP-7's cap on unheld keys' bytes: twice what live holders hold, and at least [`MIN_CAP`].
pub fn default_cap(live_bytes: u64) -> u64 {
    live_bytes.saturating_mul(2).max(MIN_CAP)
}

/// The cache file's schema. A row's bytes, for the cap, are its key's 32 and its stored vector's.
pub const CACHE_MIGRATIONS: &[(u32, &str)] = &[(
    1,
    "create table chunk_vec(key blob primary key, bits integer not null, vec blob not null, scale real not null,
                            last_used integer not null) without rowid;
     create index chunk_vec_used on chunk_vec(last_used);
     create table path_vec(key blob primary key, bits integer not null, vec blob not null, scale real not null,
                           last_used integer not null) without rowid;
     create index path_vec_used on path_vec(last_used);
     create table holder(id text primary key, root text not null, live integer not null,
                         last_refresh integer not null);
     create table held(holder text not null, kind integer not null, key blob not null,
                       primary key(holder, kind, key)) without rowid;
     create index held_key on held(kind, key);",
)];

/// The table of KIND's vectors.
fn table(kind: KeyKind) -> &'static str {
    match kind {
        KeyKind::Chunk => "chunk_vec",
        KeyKind::Path => "path_vec",
    }
}

/// Whether a live holder holds `v.key` of KIND (SQL over a row `v` of KIND's table).
fn held_sql(kind: KeyKind) -> String {
    format!(
        "exists (select 1 from held h join holder o on o.id = h.holder
                 where h.kind = {} and h.key = v.key and o.live = 1)",
        kind.as_i64()
    )
}

/// The next value of the logical clock `last_used`.
fn next_used(c: &Connection) -> rusqlite::Result<i64> {
    c.query_row(
        "select coalesce(max(m), 0) + 1 from (select max(last_used) m from chunk_vec
                                              union all select max(last_used) from path_vec)",
        [],
        |r| r.get(0),
    )
}

/// One fingerprint's cache file.
pub struct VectorCache {
    // dropped before the lock: the connection's thread is told to stop first
    store: Option<Store>,
    handle: Handle,
    path: PathBuf,
    fp_hex: String,
    _lock: Option<File>,
}

impl VectorCache {
    /// `<dir>/<fp_hex[..16]>.db`.
    pub fn file_of(dir: &Path, fp_hex: &str) -> PathBuf {
        dir.join(format!("{}.db", &fp_hex[..fp_hex.len().min(16)]))
    }

    /// A reader of FP_HEX's cache in DIR (the file must exist). A file whose `meta.fingerprint` is not FP_HEX is
    /// refused ([`StoreError::Mismatch`]). (The record is the writer's to keep: a reader takes it only for symmetry.)
    pub fn open(dir: &Path, fp_hex: &str, _record_json: &str) -> Result<VectorCache, StoreError> {
        let path = Self::file_of(dir, fp_hex);
        if !path.exists() {
            return Err(StoreError::Io(io::Error::new(
                io::ErrorKind::NotFound,
                format!("{}: no vector cache", path.display()),
            )));
        }
        check_fingerprint(&path, fp_hex)?;
        let (store, handle) = Store::spawn(StoreSpec {
            path: path.clone(),
            mode: Mode::ReadOnly,
            migrations: CACHE_MIGRATIONS,
        })?;
        Ok(VectorCache {
            store: Some(store),
            handle,
            path,
            fp_hex: fp_hex.to_string(),
            _lock: None,
        })
    }

    /// The writer of FP_HEX's cache in DIR, created (0600, WAL) when there is none. Refused while another holds
    /// `<db>.writer` ([`StoreError::Busy`]), and for a file of another fingerprint.
    pub fn open_writer(
        dir: &Path,
        fp_hex: &str,
        record_json: &str,
    ) -> Result<VectorCache, StoreError> {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
        let path = Self::file_of(dir, fp_hex);
        let lock = writer_lock(&path)?;
        if path.exists() {
            check_fingerprint(&path, fp_hex)?;
        }
        let (store, handle) = Store::spawn(StoreSpec {
            path: path.clone(),
            mode: Mode::ReadWrite {
                file_mode: 0o600,
                synchronous_full: false,
            },
            migrations: CACHE_MIGRATIONS,
        })?;
        let cache = VectorCache {
            store: Some(store),
            handle,
            path,
            fp_hex: fp_hex.to_string(),
            _lock: Some(lock),
        };
        // a new file's identity, from the caller (no runtime needed): a second connection, beside the thread's
        let c = Connection::open_with_flags(
            &cache.path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        c.busy_timeout(Duration::from_secs(5))?;
        c.execute(
            "insert or ignore into meta(key, value) values ('fingerprint', ?1), ('record', ?2)",
            params![fp_hex, record_json],
        )?;
        Ok(cache)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The full fingerprint (64 hex characters) its vectors are of.
    pub fn fp_hex(&self) -> &str {
        &self.fp_hex
    }

    /// Whether each of KEYS has a vector of KIND.
    pub async fn has(&self, kind: KeyKind, keys: &[[u8; 32]]) -> Result<Vec<bool>, StoreError> {
        let keys = keys.to_vec();
        Ok(self
            .handle
            .read(move |c| {
                let mut st = c.prepare(&format!("select 1 from {} where key = ?1", table(kind)))?;
                let mut out = Vec::with_capacity(keys.len());
                for k in &keys {
                    out.push(st.exists([k.as_slice()])?);
                }
                Ok(out)
            })
            .await?)
    }

    /// ROWS quantized and written (a key's vector replaced). A row of other than DIMS values is an error, and nothing
    /// of the batch is written.
    pub async fn put(
        &self,
        kind: KeyKind,
        dims: u32,
        rows: &[([u8; 32], Vec<f32>)],
    ) -> Result<(), StoreError> {
        if let Some((_, v)) = rows.iter().find(|(_, v)| v.len() != dims as usize) {
            return Err(StoreError::Io(io::Error::other(format!(
                "a vector of {} dims, the fingerprint says {dims}",
                v.len()
            ))));
        }
        let rows: Vec<QuantRow> = rows
            .iter()
            .map(|(key, v)| {
                let (bits, ints, scale) = urdr::graph::search::vec::quantize(v);
                let mut vec = bits;
                vec.extend(ints.iter().map(|&i| i as u8));
                QuantRow {
                    key: *key,
                    bits: 8,
                    vec,
                    scale,
                }
            })
            .collect();
        self.put_quantized(kind, &rows).await
    }

    /// Rows already in the stored form written as they are (a vector pack's).
    pub async fn put_quantized(&self, kind: KeyKind, rows: &[QuantRow]) -> Result<(), StoreError> {
        let rows = rows.to_vec();
        Ok(self
            .handle
            .write(move |c| {
                let used = next_used(c)?;
                let mut st = c.prepare(&format!(
                    "insert or replace into {}(key, bits, vec, scale, last_used) values (?1, ?2, ?3, ?4, ?5)",
                    table(kind)
                ))?;
                for r in &rows {
                    st.execute(params![r.key.as_slice(), r.bits, r.vec, r.scale, used])?;
                }
                Ok(())
            })
            .await?)
    }

    /// The stored rows of those of KEYS that have a vector of KIND, in KEYS' order.
    pub async fn get(&self, kind: KeyKind, keys: &[[u8; 32]]) -> Result<Vec<QuantRow>, StoreError> {
        let keys = keys.to_vec();
        Ok(self
            .handle
            .read(move |c| {
                let mut st = c.prepare(&format!(
                    "select bits, vec, scale from {} where key = ?1",
                    table(kind)
                ))?;
                let mut out = Vec::new();
                for k in &keys {
                    let mut rows = st.query([k.as_slice()])?;
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
            })
            .await?)
    }

    /// STORE_ID (a repo store's [`crate::CodeStore::holder_id`]) is a holder, live, if it is not one yet: every store
    /// on disk is, from the hub's start (MP-21).
    pub async fn register(&self, store_id: &str) -> Result<(), StoreError> {
        let id = store_id.to_string();
        Ok(self
            .handle
            .write(move |c| {
                c.execute(
                    "insert or ignore into holder(id, root, live, last_refresh) values (?1, '', 1, 0)",
                    [id],
                )?;
                Ok(())
            })
            .await?)
    }

    /// STORE_ID, a checkout at ROOT, now holds ADDED and no longer REMOVED of KIND: its live key set's diff since its
    /// last report, sent on every refresh. It is live again from NOW (milliseconds). The keys of both lists are marked
    /// used, so a key a holder dropped is the last of the unheld to go.
    pub async fn hold(
        &self,
        store_id: &str,
        root: &Path,
        kind: KeyKind,
        added: &[[u8; 32]],
        removed: &[[u8; 32]],
        now: i64,
    ) -> Result<(), StoreError> {
        let (id, root) = (store_id.to_string(), root.to_string_lossy().into_owned());
        let (added, removed) = (added.to_vec(), removed.to_vec());
        Ok(self
            .handle
            .write(move |c| {
                c.execute(
                    "insert into holder(id, root, live, last_refresh) values (?1, ?2, 1, ?3)
                     on conflict(id) do update set root = excluded.root, live = 1,
                                                   last_refresh = excluded.last_refresh",
                    params![id, root, now],
                )?;
                let used = next_used(c)?;
                let k = kind.as_i64();
                let mut add =
                    c.prepare("insert or ignore into held(holder, kind, key) values (?1, ?2, ?3)")?;
                for key in &added {
                    add.execute(params![id, k, key.as_slice()])?;
                }
                let mut del =
                    c.prepare("delete from held where holder = ?1 and kind = ?2 and key = ?3")?;
                for key in &removed {
                    del.execute(params![id, k, key.as_slice()])?;
                }
                let mut touch = c.prepare(&format!(
                    "update {} set last_used = ?1 where key = ?2",
                    table(kind)
                ))?;
                for key in added.iter().chain(&removed) {
                    touch.execute(params![used, key.as_slice()])?;
                }
                Ok(())
            })
            .await?)
    }

    /// Holders whose checkout is gone (no folder at their root) and that have not refreshed for IDLE by NOW
    /// (milliseconds) stop protecting their keys. How many.
    pub async fn release_gone(&self, now: i64, idle: Duration) -> Result<u32, StoreError> {
        let idle = i64::try_from(idle.as_millis()).unwrap_or(i64::MAX);
        Ok(self
            .handle
            .write(move |c| {
                let due: Vec<(String, String)> = c
                    .prepare(
                        "select id, root from holder
                         where live = 1 and root != '' and ?1 - last_refresh >= ?2",
                    )?
                    .query_map(params![now, idle], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<Result<_, _>>()?;
                let mut n = 0u32;
                for (id, root) in due {
                    if !Path::new(&root).is_dir() {
                        c.execute("update holder set live = 0 where id = ?1", [id])?;
                        n += 1;
                    }
                }
                Ok(n)
            })
            .await?)
    }

    /// STORE_ID is no holder any more (its repo's index was deleted): its rows go, and with them the vectors of the keys
    /// only it held. A key another holder holds keeps its vector. How many vectors went.
    pub async fn drop_holder(&self, store_id: &str) -> Result<u32, StoreError> {
        let id = store_id.to_string();
        Ok(self
            .handle
            .write(move |c| {
                let mut n = 0u32;
                for kind in [KeyKind::Chunk, KeyKind::Path] {
                    n += c.execute(
                        &format!(
                            "delete from {} where key in
                               (select h.key from held h where h.holder = ?1 and h.kind = ?2
                                and not exists (select 1 from held o
                                                where o.kind = h.kind and o.key = h.key and o.holder != ?1))",
                            table(kind)
                        ),
                        params![id, kind.as_i64()],
                    )? as u32;
                }
                c.execute("delete from held where holder = ?1", [&id])?;
                c.execute("delete from holder where id = ?1", [&id])?;
                Ok(n)
            })
            .await?)
    }

    /// Whether a live holder holds each of KEYS.
    pub async fn referenced(
        &self,
        kind: KeyKind,
        keys: &[[u8; 32]],
    ) -> Result<Vec<bool>, StoreError> {
        let keys = keys.to_vec();
        Ok(self
            .handle
            .read(move |c| {
                let mut st = c.prepare(
                    "select 1 from held h join holder o on o.id = h.holder
                     where h.kind = ?1 and h.key = ?2 and o.live = 1",
                )?;
                let mut out = Vec::with_capacity(keys.len());
                for k in &keys {
                    out.push(st.exists(params![kind.as_i64(), k.as_slice()])?);
                }
                Ok(out)
            })
            .await?)
    }

    /// The bytes (key and stored vector) of the keys live holders hold.
    pub async fn live_bytes(&self) -> Result<u64, StoreError> {
        Ok(self
            .handle
            .read(|c| {
                let mut total = 0i64;
                for kind in [KeyKind::Chunk, KeyKind::Path] {
                    total += c.query_row(
                        &format!(
                            "select coalesce(sum(32 + length(v.vec)), 0) from {} v where {}",
                            table(kind),
                            held_sql(kind)
                        ),
                        [],
                        |r| r.get::<_, i64>(0),
                    )?;
                }
                Ok(u64::try_from(total).unwrap_or(0))
            })
            .await?)
    }

    /// Every key a live holder holds is kept; of the rest, the most recently used up to CAP_BYTES. How many went.
    pub async fn collect(&self, cap_bytes: u64) -> Result<u32, StoreError> {
        let cap = i64::try_from(cap_bytes).unwrap_or(i64::MAX);
        Ok(self
            .handle
            .write(move |c| {
                let unheld = |kind: KeyKind| {
                    format!(
                        "select {}, v.key, 32 + length(v.vec), v.last_used from {} v where not {}",
                        kind.as_i64(),
                        table(kind),
                        held_sql(kind)
                    )
                };
                let sql = format!(
                    "{} union all {} order by 4 desc",
                    unheld(KeyKind::Chunk),
                    unheld(KeyKind::Path)
                );
                let rows: Vec<(i64, Vec<u8>, i64)> = c
                    .prepare(&sql)?
                    .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                    .collect::<Result<_, _>>()?;
                let mut kept = 0i64;
                let mut n = 0u32;
                for (kind, key, bytes) in rows {
                    if kept.saturating_add(bytes) <= cap {
                        kept += bytes;
                        continue;
                    }
                    let t = if kind == 0 { "chunk_vec" } else { "path_vec" };
                    n += c.execute(&format!("delete from {t} where key = ?1"), [key])? as u32;
                }
                Ok(n)
            })
            .await?)
    }

    /// Stop the cache's thread and close it (and its writer lock). Blocking: not for an async worker (it is safe in
    /// one, the thread is joined from another).
    pub fn shutdown(mut self) {
        if let Some(store) = self.store.take() {
            match saman::spawn_thread("hrafn-cache-shutdown", move || store.shutdown()) {
                Ok(thread) => {
                    if thread.join().is_err() {
                        tracing::warn!("the cache's shutdown thread panicked");
                    }
                }
                Err(e) => tracing::warn!("the cache could not be shut down: {e}"),
            }
        }
    }
}

/// The lock of PATH's one writer, `<path>.writer`, taken (it then holds this process's PID); a second writer is
/// refused, saying whose PID holds it.
fn writer_lock(path: &Path) -> Result<File, StoreError> {
    let mut name = path.as_os_str().to_owned();
    name.push(".writer");
    let mut f = eitri::open_lock(&PathBuf::from(name), 0o600)
        .map_err(|e| StoreError::Io(std::io::Error::other(e)))?;
    match f.try_lock() {
        Ok(()) => {
            f.set_len(0)?;
            f.rewind()?;
            write!(f, "{}", std::process::id())?;
            Ok(f)
        }
        Err(std::fs::TryLockError::WouldBlock) => {
            let mut pid = String::new();
            // the holder's PID only names who it is; an unreadable lock file names nobody
            f.read_to_string(&mut pid).unwrap_or_default();
            Err(StoreError::Busy(format!(
                "the cache is written by hub PID {} ({})",
                pid.trim(),
                path.display()
            )))
        }
        Err(std::fs::TryLockError::Error(e)) => Err(e.into()),
    }
}

/// PATH's `meta.fingerprint`, read without a write, must be FP_HEX (a file not stamped yet passes).
fn check_fingerprint(path: &Path, fp_hex: &str) -> Result<(), StoreError> {
    let c = urdr::open_readonly(path)?;
    match urdr::meta(&c, "fingerprint")? {
        Some(f) if f != fp_hex => Err(StoreError::Mismatch(format!(
            "{} holds the vectors of fingerprint {f}, not {fp_hex}",
            path.display()
        ))),
        _ => Ok(()),
    }
}
