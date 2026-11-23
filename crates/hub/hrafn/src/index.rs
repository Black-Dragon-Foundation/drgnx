//! The index: tier 1 (chunks, FTS rows and symbols, rebuilt for the files whose blob changed) and the store side of
//! tier 2 (which content keys a fingerprint's cache still lacks, and the store's live key set, reported to the cache).
//!
//! Vectors are keyed by content ([`crate::chunk_key`]) and live in the machine-wide cache ([`VectorCache`], one file per
//! fingerprint), so a file that comes back to an earlier content, or another repo with the same text, finds its vector
//! there; the store keeps keys only. A path has a vector too ([`crate::path_key`], the cache's `path_vec`): tier 1
//! keeps the base's `path_key` rows with its file rows, so a move embeds the new path's key and no chunk. After a
//! refresh the hub reports the store's live key set to each cache ([`hold`]), which keeps it from the collection.

use crate::cache::VectorCache;
use crate::chunk::{BUDGET, CHUNKER_VERSION, PARSE_VERSION, chunk_file_refs, embed_text_and_key};
use crate::files::Listed;
use crate::memo;
use crate::store::{
    ChunkIn, CodeStore, FileRow, KeyKind, RefIn, StoreError, SymbolIn, content_ids, path_key,
    path_text, remove_file_row, sweep_all, write_version,
};
use crate::tree::{View, transition};
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::{HashMap, HashSet};
use std::io;
use std::time::UNIX_EPOCH;

/// Files rebuilt in one transaction.
const FILE_BATCH: usize = 64;

const META_CHUNKER: &str = "chunker_version";
/// The parse whose symbols (and later references) the stored rows hold ([`PARSE_VERSION`]).
const META_PARSE: &str = "parse_version";
/// The language stamp the stored rows were parsed under ([`crate::chunk::lang_stamp`]): a pack changed or a grammar
/// was built since.
const META_LANGS: &str = "lang_stamp";
/// The commit the index was last built from (the hub writes it).
pub const META_BUILT_FROM: &str = "built_from";
/// Files known changed on disk and not yet rebuilt (the hub writes it).
pub const META_DIRTY: &str = "dirty_files";

/// What one tier-1 pass did. `keys_missing` counts, over the models given, the content keys each still lacks.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Refresh {
    pub files_changed: u32,
    pub chunks_written: u32,
    pub keys_missing: u32,
}

/// How far behind the index is.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Lag {
    pub model: Option<String>,
    /// The chunks that are embedded at all (the live set a model's coverage is judged against).
    pub chunks_total: u32,
    pub chunks_behind: u32,
    pub files_behind: u32,
    pub dirty_files: u32,
    pub built_from: String,
    /// The worktree view's differing files (its rows, tombstones too); none in the base view.
    pub differing_files: Option<u32>,
}

/// Whether each indexed file's chunks in the base were written with no vectors wanted.
fn known_flags(c: &Connection) -> urdr::Result<HashMap<String, bool>> {
    let mut q = c.prepare("select path, generated from file where tree = 0")?;
    let rows = q
        .query_map([], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? != 0)))?
        .collect::<Result<HashMap<String, bool>, _>>()?;
    Ok(rows)
}

/// Each indexed file's blob in the base.
pub(crate) fn known_blobs(c: &Connection) -> urdr::Result<HashMap<String, String>> {
    let mut q = c.prepare("select path, blob from file where tree = 0")?;
    let rows = q
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<HashMap<String, String>, _>>()?;
    Ok(rows)
}

fn now_secs() -> i64 {
    stund::wall()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

/// The distinct embeddable chunk keys the attached cache (`vc`) has no vector for.
const MISSING_KEYS: &str =
    "select count(distinct c.key) from chunk c where c.embed = 1 and not exists
     (select 1 from vc.chunk_vec v where v.key = c.key)";

/// The base's `path_key` rows made the set its file rows name: each path whose content wants vectors (`generated = 0`,
/// which a `no-embed` rule sets too) and each of its directories (`dir/`). A path's key is made once, when its row
/// comes; the cache learns of it at the next [`hold`].
fn sync_path_keys(c: &Connection) -> urdr::Result<()> {
    let mut want: HashSet<String> = HashSet::new();
    {
        let mut st = c.prepare(
            "select path from file where tree = 0 and blob is not null and generated = 0",
        )?;
        let paths = st.query_map([], |r| r.get::<_, String>(0))?;
        for p in paths {
            let p = p?;
            for (i, _) in p.match_indices('/') {
                want.insert(p[..=i].to_string());
            }
            want.insert(p);
        }
    }
    let have: HashSet<String> = {
        let mut st = c.prepare("select path from path_key")?;
        st.query_map([], |r| r.get::<_, String>(0))?
            .collect::<Result<_, _>>()?
    };
    let mut delete = c.prepare("delete from path_key where path = ?1")?;
    for p in have.difference(&want) {
        delete.execute([p])?;
    }
    let mut insert = c.prepare("insert into path_key(path, key) values (?1, ?2)")?;
    for p in want.difference(&have) {
        insert.execute(params![p, path_key(p).as_slice()])?;
    }
    Ok(())
}

/// One file's rows, chunked off the store thread.
pub(crate) struct Built {
    /// Written over content the pair already has (its embed flag moved with a rule).
    pub(crate) force: bool,
    pub(crate) row: FileRow,
    pub(crate) chunks: Vec<ChunkIn>,
    pub(crate) symbols: Vec<SymbolIn>,
    pub(crate) refs: Vec<RefIn>,
}

/// A listed file's `file` row.
pub(crate) fn row_of(l: &Listed) -> FileRow {
    FileRow {
        path: l.path.clone(),
        blob: Some(l.blob.clone()),
        class: l.class.as_str().into(),
        lang: l.lang.as_str().into(),
        // no vectors wanted (generated, or a `no-embed` rule): one flag, so a rule's change rebuilds the file
        generated: l.generated || !l.embed,
        size: l.size,
        indexed_at: now_secs(),
    }
}

/// A file read for tier 1: its rows chunked, or its row alone when its content is stored already.
enum Pending {
    Built(Built),
    Reuse(FileRow),
}

pub(crate) fn build(l: &Listed, bytes: &[u8]) -> Built {
    let text = String::from_utf8_lossy(bytes);
    let (chunks, symbols, refs) =
        chunk_file_refs(&l.path, l.lang, l.generated || !l.embed, &text, BUDGET);
    Built {
        force: false,
        row: row_of(l),
        refs: refs
            .into_iter()
            .map(|r| RefIn {
                name: r.name,
                n: r.n,
                lines: r.lines,
            })
            .collect(),
        chunks: chunks
            .into_iter()
            .map(|c| {
                // the stored text is the one the key is of, and what tier 2 sends
                let (_, key) = embed_text_and_key(&c);
                ChunkIn {
                    start: c.start,
                    end: c.end,
                    line_start: c.line_start,
                    line_end: c.line_end,
                    symbol: c.symbol,
                    key,
                    embed: c.embed,
                    embed_text: c.embed_text,
                    symbols: c.fts.symbols,
                    doc: c.fts.doc,
                    body: c.fts.body,
                }
            })
            .collect(),
        symbols: symbols
            .into_iter()
            .map(|s| SymbolIn {
                name: s.name,
                kind: s.kind,
                start: s.start,
                end: s.end,
                chunk: s.chunk as usize,
                definer: s.definer,
                doc1: s.doc1,
                line_start: s.line_start,
                line_end: s.line_end,
                sig: s.sig,
            })
            .collect(),
    }
}

/// A listed file's chunks and symbols as tier 1 writes them (what a worktree's overlay writes too).
pub fn built(l: &Listed, bytes: &[u8]) -> (Vec<ChunkIn>, Vec<SymbolIn>) {
    let b = build(l, bytes);
    (b.chunks, b.symbols)
}

/// [`built`] with the file's references.
pub fn built_refs(l: &Listed, bytes: &[u8]) -> (Vec<ChunkIn>, Vec<SymbolIn>, Vec<RefIn>) {
    let b = build(l, bytes);
    (b.chunks, b.symbols, b.refs)
}

/// Tier 1: rows rebuilt only for the files of `listed` whose blob changed (all of them after a chunker change), and
/// dropped for the files no longer listed; one transaction per batch of files. `read` gives a listed file's bytes
/// (the hub's reads go through `eitri`); a file that cannot be read any more is dropped like a gone one. `caches` are
/// those of the fingerprints tier 2 fills, for `keys_missing`.
///
/// Every write is by content: a file's base row is replaced, its `(path, blob)` is chunked only when no row (a
/// worktree's) has its content already, and the pair the row named before is swept only when no worktree still names
/// it. A chunker change clears every worktree's rows first (they re-seed), so all content is written by the new one.
///
/// The writes run with a page cache of [`TIER1_CACHE_KIB`]: a file's references go into the name index all over it, and
/// the default cache (2 MB) made that index most of tier 1's cost of references. The cache size is put back after,
/// and the pages let go, so an idle store holds no more than before.
pub async fn refresh(
    store: &CodeStore,
    listed: &[Listed],
    read: &(dyn Fn(&str) -> io::Result<Vec<u8>> + Sync),
    caches: &[&VectorCache],
) -> Result<Refresh, StoreError> {
    let before: i64 = store
        .handle()
        .read(|c| {
            let v = c.query_row("pragma cache_size", [], |r| r.get(0))?;
            c.execute_batch(&format!("pragma cache_size = -{TIER1_CACHE_KIB}"))?;
            Ok(v)
        })
        .await?;
    let out = refresh_files(store, listed, read, caches).await;
    store
        .handle()
        .read(move |c| {
            c.execute_batch(&format!(
                "pragma cache_size = {before}; pragma shrink_memory"
            ))?;
            Ok(())
        })
        .await?;
    out
}

/// The page cache tier 1 writes with, in KiB.
pub const TIER1_CACHE_KIB: u32 = 64 * 1024;

async fn refresh_files(
    store: &CodeStore,
    listed: &[Listed],
    read: &(dyn Fn(&str) -> io::Result<Vec<u8>> + Sync),
    caches: &[&VectorCache],
) -> Result<Refresh, StoreError> {
    let stamp = crate::chunk::lang_stamp();
    let (known, flags, chunker, parse, langs) = store
        .handle()
        .read(|c| {
            Ok((
                known_blobs(c)?,
                known_flags(c)?,
                urdr::meta(c, META_CHUNKER)?,
                urdr::meta(c, META_PARSE)?,
                urdr::meta(c, META_LANGS)?,
            ))
        })
        .await?;
    // a new parse rebuilds like a new chunker; the chunks' keys stay, so the vectors do too
    let rebuild = chunker.as_deref() != Some(CHUNKER_VERSION.to_string().as_str())
        || parse.as_deref() != Some(PARSE_VERSION.to_string().as_str())
        || langs.as_deref() != Some(stamp.as_str());
    let names: HashSet<&str> = listed.iter().map(|l| l.path.as_str()).collect();
    let mut gone: Vec<String> = known
        .keys()
        .filter(|p| !names.contains(p.as_str()))
        .cloned()
        .collect();
    // a file whose embed flag moved (a `no-embed` rule came or went) is written again, though its blob is the same
    let flipped = |l: &Listed| {
        flags
            .get(&l.path)
            .is_some_and(|g| *g != (l.generated || !l.embed))
    };
    let built = |l: &Listed, bytes: &[u8]| {
        let mut b = build(l, bytes);
        b.force = flipped(l);
        b
    };
    let changed: Vec<&Listed> = listed
        .iter()
        .filter(|l| rebuild || known.get(&l.path) != Some(&l.blob) || flipped(l))
        .collect();
    let mut out = Refresh::default();
    if rebuild {
        store.handle().write(clear_trees).await?;
    }
    // a pair a worktree already stores is neither read nor chunked again (unless the chunker changed)
    let stored: HashSet<String> = if rebuild {
        HashSet::new()
    } else {
        let pairs: Vec<(String, String)> = changed
            .iter()
            .filter(|l| !flipped(l))
            .map(|l| (l.path.clone(), l.blob.clone()))
            .collect();
        store
            .handle()
            .read(move |c| {
                let mut out = HashSet::new();
                for (p, b) in pairs {
                    if !content_ids(c, &p, &b)?.is_empty() {
                        out.insert(p);
                    }
                }
                Ok(out)
            })
            .await?
    };
    for batch in changed.chunks(FILE_BATCH) {
        let mut pending = Vec::with_capacity(batch.len());
        for l in batch {
            if stored.contains(&l.path) {
                pending.push(Pending::Reuse(row_of(l)));
                continue;
            }
            match read(&l.path) {
                Ok(bytes) => pending.push(Pending::Built(built(l, &bytes))),
                Err(_) if known.contains_key(&l.path) => gone.push(l.path.clone()),
                Err(_) => {}
            }
        }
        // a reused pair swept since it was looked up: read and chunked after all
        loop {
            out.files_changed += pending.len() as u32;
            out.chunks_written += pending
                .iter()
                .map(|p| match p {
                    Pending::Built(b) => b.chunks.len() as u32,
                    Pending::Reuse(_) => 0,
                })
                .sum::<u32>();
            let missed = store
                .handle()
                .write(move |c| write_base(c, &pending, rebuild))
                .await?;
            if missed.is_empty() {
                break;
            }
            out.files_changed -= missed.len() as u32;
            pending = Vec::new();
            for l in batch.iter().filter(|l| missed.contains(&l.path)) {
                match read(&l.path) {
                    Ok(bytes) => pending.push(Pending::Built(built(l, &bytes))),
                    Err(_) => gone.push(l.path.clone()),
                }
            }
        }
    }
    if !gone.is_empty() {
        out.files_changed += gone.len() as u32;
        store
            .handle()
            .write(move |c| {
                for p in &gone {
                    transition(c, p, None)?;
                    remove_file_row(c, 0, p)?;
                }
                Ok(())
            })
            .await?;
    }
    if rebuild || out.files_changed > 0 {
        store.handle().write(sync_path_keys).await?;
    }
    if rebuild {
        store
            .meta_set(META_CHUNKER, &CHUNKER_VERSION.to_string())
            .await?;
        store
            .meta_set(META_PARSE, &PARSE_VERSION.to_string())
            .await?;
        store.meta_set(META_LANGS, &stamp).await?;
    }
    for cache in caches {
        let n: i64 = store
            .attach_cache(cache.path(), |c| {
                Ok(c.query_row(MISSING_KEYS, [], |r| r.get(0))?)
            })
            .await?;
        out.keys_missing = out
            .keys_missing
            .saturating_add(u32::try_from(n).unwrap_or(u32::MAX));
    }
    Ok(out)
}

/// Up to `limit` keys CACHE lacks, with the text to embed: [`missing_with`], with directories when
/// [`crate::query::DIR_WEIGHT`] gives them a part in the score.
pub async fn missing(
    store: &CodeStore,
    cache: &VectorCache,
    limit: u32,
) -> Result<Vec<(KeyKind, [u8; 32], String)>, StoreError> {
    missing_with(store, cache, limit, crate::query::DIR_WEIGHT > 0.0).await
}

/// [`missing`], the chunks of the paths in ORDER first (see [`missing_ordered`]).
pub async fn missing_first(
    store: &CodeStore,
    cache: &VectorCache,
    limit: u32,
    order: &[String],
) -> Result<Vec<(KeyKind, [u8; 32], String)>, StoreError> {
    missing_ordered(store, cache, limit, crate::query::DIR_WEIGHT > 0.0, order).await
}

/// STORE's live key set (the distinct keys of its chunks that want vectors, and its `path_key` rows) reported to CACHE
/// as the diff against what the cache last recorded for it, with ROOT its checkout and NOW (milliseconds) the time.
pub async fn hold(
    store: &CodeStore,
    cache: &VectorCache,
    root: &std::path::Path,
    now: i64,
) -> Result<(), StoreError> {
    let id = store.holder_id();
    let held_of = id.clone();
    let sets = store
        .attach_cache(cache.path(), move |c| {
            let keys = |sql: &str, p: &[&dyn rusqlite::ToSql]| -> urdr::Result<HashSet<[u8; 32]>> {
                let mut st = c.prepare(sql)?;
                let rows = st.query_map(p, |r| r.get::<_, Vec<u8>>(0))?;
                let mut out = HashSet::new();
                for k in rows {
                    if let Ok(k) = <[u8; 32]>::try_from(k?.as_slice()) {
                        out.insert(k);
                    }
                }
                Ok(out)
            };
            let held = "select key from vc.held where holder = ?1 and kind = ?2";
            Ok([
                (
                    KeyKind::Chunk,
                    keys("select distinct key from chunk where embed = 1", &[])?,
                    keys(held, &[&held_of, &KeyKind::Chunk.as_i64()])?,
                ),
                (
                    KeyKind::Path,
                    keys("select key from path_key", &[])?,
                    keys(held, &[&held_of, &KeyKind::Path.as_i64()])?,
                ),
            ])
        })
        .await?;
    for (kind, live, held) in sets {
        let added: Vec<[u8; 32]> = live.difference(&held).copied().collect();
        let removed: Vec<[u8; 32]> = held.difference(&live).copied().collect();
        cache.hold(&id, root, kind, &added, &removed, now).await?;
    }
    Ok(())
}

/// Up to `limit` keys CACHE lacks, with the text to embed: the chunk keys in chunk order, each file's path key after its
/// chunks' (and, with DIRS, its directories' keys after it), then the path keys of files whose chunks have vectors.
pub async fn missing_with(
    store: &CodeStore,
    cache: &VectorCache,
    limit: u32,
    dirs: bool,
) -> Result<Vec<(KeyKind, [u8; 32], String)>, StoreError> {
    missing_ordered(store, cache, limit, dirs, &[]).await
}

/// [`missing_with`], the chunks of the paths in ORDER (open and recently edited files first, then by recency) before
/// the rest, which come in chunk order (MP-14).
pub async fn missing_ordered(
    store: &CodeStore,
    cache: &VectorCache,
    limit: u32,
    dirs: bool,
    order: &[String],
) -> Result<Vec<(KeyKind, [u8; 32], String)>, StoreError> {
    let limit = limit as usize;
    let order: Vec<String> = order.to_vec();
    store
        .attach_cache(cache.path(), move |c| {
            type Row = (Vec<u8>, String, String);
            let mut chunks: Vec<Row> = Vec::new();
            if !order.is_empty() {
                let mut by_path = c.prepare(
                    "select c.key, c.embed_text, c.path from chunk c
                     where c.path = ?1
                       and c.id in (select min(id) from chunk where embed = 1 group by key)
                       and not exists (select 1 from vc.chunk_vec v where v.key = c.key)
                     order by c.id",
                )?;
                let mut visited: HashSet<&str> = HashSet::new();
                for p in &order {
                    if chunks.len() >= limit {
                        break;
                    }
                    if !visited.insert(p.as_str()) {
                        continue;
                    }
                    let rows = by_path
                        .query_map(params![p], |r| {
                            Ok((
                                r.get::<_, Vec<u8>>(0)?,
                                r.get::<_, String>(1)?,
                                r.get::<_, String>(2)?,
                            ))
                        })?
                        .collect::<Result<Vec<Row>, _>>()?;
                    chunks.extend(rows);
                }
                chunks.truncate(limit);
            }
            let mut q = c.prepare(
                "select c.key, c.embed_text, c.path from chunk c
                 where c.id in (select min(id) from chunk where embed = 1 group by key)
                   and not exists (select 1 from vc.chunk_vec v where v.key = c.key)
                 order by c.id limit ?1",
            )?;
            let first = chunks.len();
            let rest = q
                .query_map(params![(limit + first) as i64], |r| {
                    Ok((
                        r.get::<_, Vec<u8>>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                    ))
                })?
                .collect::<Result<Vec<Row>, _>>()?;
            let seen: HashSet<Vec<u8>> = chunks.iter().map(|(k, _, _)| k.clone()).collect();
            chunks.extend(rest.into_iter().filter(|(k, _, _)| !seen.contains(k)));
            chunks.truncate(limit);
            let mut lacks = c.prepare(
                "select p.key from path_key p where p.path = ?1
                   and not exists (select 1 from vc.path_vec v where v.key = p.key)",
            )?;
            let mut out: Vec<(KeyKind, [u8; 32], String)> = Vec::new();
            let mut offered: HashSet<String> = HashSet::new();
            // PATH's key, and with DIRS its directories', when the cache lacks them
            let mut path_rows = |path: &str,
                                 out: &mut Vec<(KeyKind, [u8; 32], String)>|
             -> urdr::Result<()> {
                let mut names = vec![path.to_string()];
                if dirs {
                    names.extend(path.match_indices('/').map(|(i, _)| path[..=i].to_string()));
                }
                for p in names {
                    if out.len() >= limit || !offered.insert(p.clone()) {
                        continue;
                    }
                    let key: Option<Vec<u8>> = lacks.query_row([&p], |r| r.get(0)).optional()?;
                    if let Some(k) = key.and_then(|k| <[u8; 32]>::try_from(k.as_slice()).ok()) {
                        let text = path_text(&p);
                        out.push((KeyKind::Path, k, text));
                    }
                }
                Ok(())
            };
            for (i, (k, text, path)) in chunks.iter().enumerate() {
                if out.len() >= limit {
                    break;
                }
                if let Ok(k) = <[u8; 32]>::try_from(k.as_slice()) {
                    out.push((KeyKind::Chunk, k, text.clone()));
                }
                // a file's path key follows its last chunk key here
                if chunks.get(i + 1).is_none_or(|(_, _, next)| next != path) {
                    path_rows(path, &mut out)?;
                }
            }
            if out.len() < limit {
                // the path keys of files whose chunks are embedded (a move, a copy, a file without chunks)
                let mut rest = c.prepare(
                    "select p.path, p.key from path_key p
                     where (?1 or substr(p.path, -1) != '/')
                       and not exists (select 1 from vc.path_vec v where v.key = p.key)
                     order by p.path",
                )?;
                let rows = rest.query_map(params![dirs], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?))
                })?;
                for row in rows {
                    let (p, k) = row?;
                    if out.len() >= limit {
                        break;
                    }
                    if offered.contains(&p) {
                        continue;
                    }
                    if let Ok(k) = <[u8; 32]>::try_from(k.as_slice()) {
                        let text = path_text(&p);
                        out.push((KeyKind::Path, k, text));
                    }
                }
            }
            Ok(out)
        })
        .await
}

/// One batch of base writes in one transaction, each with its transition of every tree first (so the old content a
/// tree now names is not swept). The paths whose content was to be reused but is gone: nothing was written for them.
fn write_base(c: &Connection, pending: &[Pending], rebuild: bool) -> urdr::Result<Vec<String>> {
    let mut missed = Vec::new();
    for p in pending {
        match p {
            Pending::Reuse(row) => {
                let blob = row.blob.as_deref().unwrap_or_default();
                if content_ids(c, &row.path, blob)?.is_empty() {
                    missed.push(row.path.clone());
                    continue;
                }
                transition(c, &row.path, row.blob.as_deref())?;
                write_version(c, 0, row, None, false)?;
            }
            Pending::Built(b) => {
                transition(c, &b.row.path, b.row.blob.as_deref())?;
                write_version(
                    c,
                    0,
                    &b.row,
                    Some((&b.chunks, &b.symbols, &b.refs)),
                    rebuild || b.force,
                )?;
            }
        }
    }
    Ok(missed)
}

/// Every worktree's rows dropped and the content only they named swept; the trees are marked `stale`, so they
/// re-seed on their next use (H16 overlay design §6.4).
fn clear_trees(c: &Connection) -> urdr::Result<()> {
    c.execute("delete from file where tree > 0", [])?;
    sweep_all(c)?;
    c.execute(
        "update tree set state = 'stale' where state != 'seeding'",
        [],
    )?;
    Ok(())
}

/// Drops every file row and chunk (with their FTS rows, symbols and references), the worktrees' too, so the next [`refresh`]
/// builds everything again and the trees re-seed. The vectors stay: their keys are content, so the new chunks find
/// them.
pub async fn reset(store: &CodeStore) -> Result<(), StoreError> {
    Ok(store
        .handle()
        .write(|c| {
            c.execute("delete from chunk", [])?;
            c.execute("delete from ref", [])?;
            c.execute("delete from file", [])?;
            c.execute("delete from path_key", [])?;
            c.execute(
                "update tree set state = 'stale' where state != 'seeding'",
                [],
            )?;
            c.execute(
                "delete from meta where key in (?1, ?2, ?3, ?4)",
                [META_CHUNKER, META_BUILT_FROM, META_PARSE, META_LANGS],
            )?;
            Ok(())
        })
        .await?)
}

/// The queries `lag` asks on every answer: one pass over the chunks that is a pass over an index (the chunk rows hold
/// their text, so a scan of the table reads the whole store: 100 ms of every query at 50,000 chunks). They count the
/// base's content only (a chunk the base's row of its path names), probing `file` by its key per chunk, and the
/// attached cache's `chunk_vec` by its key.
pub const LAG_TOTAL_SQL: &str = "select count(*) from chunk c where c.embed = 1
     and exists (select 1 from file f where f.tree = 0 and f.path = c.path and f.blob = c.blob)";
pub const LAG_BEHIND_SQL: &str = "select count(*) from chunk c where c.embed = 1
     and exists (select 1 from file f where f.tree = 0 and f.path = c.path and f.blob = c.blob)
     and not exists (select 1 from vc.chunk_vec v where v.key = c.key)";
pub const LAG_FILES_SQL: &str = "select count(distinct c.path) from chunk c where c.embed = 1
     and exists (select 1 from file f where f.tree = 0 and f.path = c.path and f.blob = c.blob)
     and not exists (select 1 from vc.chunk_vec v where v.key = c.key)";
/// A worktree view's lag as the base's plus a delta over the tree's rows only (?1 the tree; the vectors are the
/// attached cache's): its rows' chunks are added and the base chunks of the paths it shadows taken away. The columns
/// are the delta of the total, of the chunks behind and of the files behind; then the tree's row count.
pub const LAG_TREE_SQL: &str = "select coalesce(sum(n.sign * n.total), 0), coalesce(sum(n.sign * n.behind), 0),
       coalesce(sum(n.sign * (n.behind > 0)), 0),
       (select count(*) from file where tree = ?1)
     from (
       select 1 as sign,
         (select count(*) from chunk c where c.path = t.path and c.blob = t.blob and c.embed = 1) as total,
         (select count(*) from chunk c where c.path = t.path and c.blob = t.blob and c.embed = 1
            and not exists (select 1 from vc.chunk_vec v where v.key = c.key)) as behind
       from file t where t.tree = ?1 and t.blob is not null
       union all
       select -1,
         (select count(*) from chunk c where c.path = b.path and c.blob = b.blob and c.embed = 1),
         (select count(*) from chunk c where c.path = b.path and c.blob = b.blob and c.embed = 1
            and not exists (select 1 from vc.chunk_vec v where v.key = c.key))
       from file t join file b on b.tree = 0 and b.path = t.path where t.tree = ?1) n";

/// How far behind VIEW's index is for CACHE's fingerprint (none: no model fills tier 2, so nothing is behind on
/// vectors). A worktree's view is the base's lag plus the delta of its rows, both read through indexes. The counts are
/// kept until the store or the cache changes (`memo.rs`): a query between two writes counts nothing again.
pub async fn lag(
    store: &CodeStore,
    cache: Option<&VectorCache>,
    view: View,
) -> Result<Lag, StoreError> {
    let model = cache.map(|c| c.fp_hex().to_string());
    let memo = store.memo();
    let (attached, path) = (store.attached(), cache.map(|c| c.path().to_path_buf()));
    Ok(store
        .handle()
        .read(move |c| {
            if let Some(p) = &path {
                crate::store::ensure_vc(c, &attached, p)?;
            }
            let mut m = memo::lock(&memo);
            let m = m.at(c)?;
            let key = (model.clone(), view);
            let n = match m.lag.get(&key) {
                Some(n) => *n,
                None => {
                    let n = lag_counts(c, model.as_deref(), view)?;
                    m.lag.insert(key, n);
                    n
                }
            };
            Ok(Lag {
                chunks_total: n.chunks_total,
                chunks_behind: n.chunks_behind,
                files_behind: n.files_behind,
                dirty_files: urdr::meta(c, META_DIRTY)?
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0),
                built_from: urdr::meta(c, META_BUILT_FROM)?.unwrap_or_default(),
                differing_files: n.differing_files,
                model,
            })
        })
        .await?)
}

/// The count SQL answers, as a `u32`.
fn count(c: &Connection, sql: &str) -> urdr::Result<u32> {
    let n: i64 = c.query_row(sql, [], |r| r.get(0))?;
    Ok(u32::try_from(n).unwrap_or(u32::MAX))
}

/// With MODEL, its cache is attached as `vc`.
fn lag_counts(c: &Connection, model: Option<&str>, view: View) -> urdr::Result<memo::Counts> {
    let (mut chunks_behind, mut files_behind) = match model {
        None => (0, 0),
        Some(_) => {
            let chunks = count(c, LAG_BEHIND_SQL)?;
            // the files are counted only when something is behind
            (
                chunks,
                if chunks == 0 {
                    0
                } else {
                    count(c, LAG_FILES_SQL)?
                },
            )
        }
    };
    let mut chunks_total = count(c, LAG_TOTAL_SQL)?;
    let mut differing_files = None;
    if let View::Tree(t) = view {
        // with no model nothing is behind: the vectors are an empty table (no cache need be attached)
        let sql = match model {
            Some(_) => LAG_TREE_SQL.to_string(),
            None => LAG_TREE_SQL.replace("vc.chunk_vec", "(select x'' as key where 0)"),
        };
        let (dt, db, df, rows): (i64, i64, i64, i64) = c.query_row(&sql, [t.0], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })?;
        let add = |n: u32, d: i64| u32::try_from((i64::from(n) + d).max(0)).unwrap_or(u32::MAX);
        chunks_total = add(chunks_total, dt);
        if model.is_some() {
            chunks_behind = add(chunks_behind, db);
            files_behind = add(files_behind, df);
        }
        differing_files = Some(u32::try_from(rows).unwrap_or(u32::MAX));
    }
    Ok(memo::Counts {
        chunks_total,
        chunks_behind,
        files_behind,
        differing_files,
    })
}
