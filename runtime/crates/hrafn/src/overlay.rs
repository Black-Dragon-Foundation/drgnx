//! The overlay core (H16 overlay design §2, §5.3): a worktree's `file` rows are exactly the paths where its admitted
//! blob differs from the base's, `overlay(T) = { p ↦ adm_T(p) : adm_T(p) ≠ adm_base(p) }`, over content shared by
//! `(path, blob)` (see [`crate::tree`]).
//!
//! - **Candidates.** A seed or re-diff looks only at the paths that can differ: the symmetric difference of T's HEAD
//!   tree and the base's rows (by blob; no file read), T's stat-dirty and untracked paths through its git door, and
//!   T's current rows (so a path that went back to clean while HEAD stayed drops its row). Any other path is clean in
//!   T at a committed blob equal to the base row's, or absent from both. The symmetric difference covers both the
//!   committed difference from the base's commit and the base's working-tree drift from it (§5.3 steps 2 and 4), and
//!   also a path that was dirty and equal to the base at the last re-diff and is clean again at a committed blob that
//!   differs.
//! - **Admission per view.** A path is admitted in T by the base's rules (`Config`, the deny-list, dot paths, secret
//!   names, nested repositories) and by T's own bytes (a regular file, at most 1 MiB, not binary). A candidate that is
//!   stat-clean at a committed blob equal to the base's is decided with no read.
//! - **Links are never admitted**, in any view and through either door: a committed link (mode 120000) is refused
//!   from its mode, a link on disk by the read (which never follows one), both before any hash. So the CLI's
//!   `hash-object`, which hashes a link's target content, and gix, which hashes the target's name, are never asked
//!   for a link, and the two doors cannot disagree on one.
//! - **Fail safe.** A blob the door marks uncertain (a conversion attribute in a touched tree) always gets its row.
//! - **Writes** go in batches of [`BATCH`] paths, one transaction each; content is chunked only for pairs not stored
//!   yet. A seed marks the tree `seeding` first and `live` in its final transaction, with `head`, `seeded_from` and
//!   `branch`; a seed cut short leaves it `seeding`, and the next seed starts over, keeping the rows (every one is a
//!   candidate again). Every step is idempotent: an equal blob writes nothing.
//!
//! Reading, hashing and chunking run in the caller's task, as tier 1's do; only the batch writes are store jobs.

use crate::door::{Blob, TreeGit};
use crate::files::{Config, Rules, listed, read_admitted};
use crate::index::{Built, META_BUILT_FROM, build, known_blobs, row_of};
use crate::store::{CodeStore, FileRow, StoreError, content_ids, remove_file_row, write_version};
use crate::tree::{TreeId, TreeState};
use rusqlite::params;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::Path;

/// Paths written per transaction.
pub const BATCH: usize = 64;

/// Times a file read for a hash is hashed and read again while it keeps changing under the hash.
const HASH_ROUNDS: usize = 3;

/// A committed link's mode.
const LINK: u32 = 0o120000;

/// One tree's overlay work: its store and id, its root and git door, and the base's rules (`config` and the hub's
/// deny-list check `allow`).
pub struct Cx<'a> {
    pub store: &'a CodeStore,
    pub tree: TreeId,
    pub root: &'a Path,
    pub door: &'a (dyn TreeGit + Sync),
    pub config: &'a Config,
    pub allow: &'a (dyn Fn(&str) -> bool + Sync),
}

/// What one seed, re-diff or re-check did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Seed {
    pub candidates: u32,
    /// Candidates whose bytes were read.
    pub read: u32,
    /// Rows written (new or changed), tombstones among them.
    pub rows: u32,
    pub tombstones: u32,
    /// Rows deleted: the path equals the base again.
    pub dropped: u32,
    /// Pairs chunked (the others' content was stored already).
    pub chunked: u32,
}

/// Seed T against the base: mark it `seeding`, write its rows, then mark it `live`.
pub async fn seed(cx: &Cx<'_>) -> Result<Seed, StoreError> {
    cx.store.tree_mark(cx.tree, TreeState::Seeding).await?;
    diff(cx, None).await
}

/// Re-diff T after a git event, a lost event or a restart: the seed's candidates, without leaving `live` meanwhile. A
/// tree never seeded is seeded.
pub async fn rediff(cx: &Cx<'_>) -> Result<Seed, StoreError> {
    let t = cx.tree;
    let seeded = cx
        .store
        .handle()
        .read(move |c| {
            Ok(c.query_row(
                "select head is not null and state != 'seeding' from tree where id = ?1",
                [t.0],
                |r| r.get::<_, bool>(0),
            )?)
        })
        .await?;
    if !seeded {
        return seed(cx).await;
    }
    diff(cx, None).await
}

/// Re-check PATHS of T (feed and watcher hints): each is read and compared with the base. The tree's state is left as
/// it is.
pub async fn recheck(cx: &Cx<'_>, paths: &[String]) -> Result<Seed, StoreError> {
    diff(cx, Some(paths)).await
}

/// T's wanted row of one candidate.
enum Want {
    /// T equals the base there.
    None,
    Tombstone,
    Row {
        blob: String,
        bytes: Vec<u8>,
    },
}

/// The seed or re-diff (ONLY none), or the re-check of ONLY.
async fn diff(cx: &Cx<'_>, only: Option<&[String]>) -> Result<Seed, StoreError> {
    let t = cx.tree.0;
    let (base, rows, built_from) = cx
        .store
        .handle()
        .read(move |c| {
            let rows: HashMap<String, Option<String>> = c
                .prepare("select path, blob from file where tree = ?1")?
                .query_map([t], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<Result<_, _>>()?;
            Ok((known_blobs(c)?, rows, urdr::meta(c, META_BUILT_FROM)?))
        })
        .await?;
    let root_fd = eitri::open_path(cx.root, eitri::Kind::Dir)
        .map_err(|e| std::io::Error::other(format!("worktree root: {e}")))?;
    let git = cx.door.as_git();
    let rules = Rules::new(cx.config, &git.nested(cx.root)?);
    let head = cx.door.head(cx.root)?;

    // the candidates, and the committed entries of those that are stat-clean
    let mut clean: HashMap<String, (u32, String)> = HashMap::new();
    let candidates: BTreeSet<String> = match only {
        Some(paths) => paths.iter().cloned().collect(),
        None => {
            let status = cx.door.stat_status(cx.root)?;
            let mut c: BTreeSet<String> = rows.keys().cloned().collect();
            c.extend(status.dirty.iter().cloned());
            c.extend(status.untracked.iter().cloned());
            let unclean: HashSet<&String> = status.dirty.iter().chain(&status.untracked).collect();
            let committed = match &head.id {
                Some(h) => cx.door.ls_tree(cx.root, h)?,
                None => vec![],
            };
            let mut in_head = HashSet::new();
            for e in committed {
                in_head.insert(e.path.clone());
                if base.get(&e.path) != Some(&e.blob) {
                    c.insert(e.path.clone());
                }
                if !unclean.contains(&e.path) {
                    clean.insert(e.path, (e.mode, e.blob));
                }
            }
            c.extend(base.keys().filter(|p| !in_head.contains(*p)).cloned());
            c
        }
    };

    // each candidate's T blob: decided from its committed entry, or read and hashed
    let mut out = Seed {
        candidates: candidates.len() as u32,
        ..Seed::default()
    };
    let mut want: Vec<(String, Want)> = Vec::new();
    let mut to_hash: Vec<(String, Vec<u8>)> = Vec::new();
    for p in candidates {
        let in_base = base.get(&p);
        if !rules.admits(&p, cx.allow) {
            want.push((p.clone(), absent(in_base)));
            continue;
        }
        if let Some((mode, blob)) = clean.get(&p) {
            if *mode == LINK {
                want.push((p.clone(), absent(in_base)));
                continue;
            }
            if in_base == Some(blob) {
                want.push((p, Want::None));
                continue;
            }
            if rows.get(&p) == Some(&Some(blob.clone())) {
                // its row names its committed blob already
                continue;
            }
        }
        out.read += 1;
        match read_admitted(&root_fd, &p) {
            Some(bytes) => to_hash.push((p, bytes)),
            None => want.push((p.clone(), absent(in_base))),
        }
    }
    // the door hashes the file as it is when it runs: a hash is kept only when the file still holds the bytes read, so
    // a row never names a blob over chunks of other bytes; a file that keeps moving is left to the hint its write sends
    let mut hashed: Vec<(String, Vec<u8>, Blob)> = Vec::new();
    for _ in 0..HASH_ROUNDS {
        if to_hash.is_empty() {
            break;
        }
        let paths: Vec<String> = to_hash.iter().map(|h| h.0.clone()).collect();
        let blobs = cx.door.blobs(cx.root, &paths)?;
        let mut again = Vec::new();
        for ((p, bytes), b) in to_hash.into_iter().zip(blobs) {
            match read_admitted(&root_fd, &p) {
                Some(now) if now == bytes => hashed.push((p, bytes, b)),
                Some(now) => again.push((p, now)),
                None => want.push((p.clone(), absent(base.get(&p)))),
            }
        }
        to_hash = again;
    }
    let paths: Vec<String> = hashed.iter().map(|h| h.0.clone()).collect();
    let generated: HashSet<String> = git.generated(cx.root, &paths)?.into_iter().collect();
    let mut facts: HashMap<String, bool> = HashMap::new();
    for (p, bytes, b) in hashed {
        if base.get(&p) == Some(&b.id) && !b.uncertain {
            want.push((p, Want::None));
        } else {
            facts.insert(p.clone(), generated.contains(&p));
            want.push((p, Want::Row { blob: b.id, bytes }));
        }
    }
    // only what changes is written
    want.retain(|(p, w)| {
        let now = rows.get(p);
        match w {
            Want::None => now.is_some(),
            Want::Tombstone => now != Some(&None),
            Want::Row { blob, .. } => now != Some(&Some(blob.clone())),
        }
    });
    want.sort_by(|a, b| a.0.cmp(&b.0));

    let mut batches = want.into_iter().peekable();
    while batches.peek().is_some() {
        let batch: Vec<(String, Want)> = batches.by_ref().take(BATCH).collect();
        let pairs: Vec<(String, String)> = batch
            .iter()
            .filter_map(|(p, w)| match w {
                Want::Row { blob, .. } => Some((p.clone(), blob.clone())),
                _ => None,
            })
            .collect();
        let stored: HashSet<String> = cx
            .store
            .handle()
            .read(move |c| {
                let mut s = HashSet::new();
                for (p, b) in pairs {
                    if !content_ids(c, &p, &b)?.is_empty() {
                        s.insert(p);
                    }
                }
                Ok(s)
            })
            .await?;
        let mut writes: Vec<Write> = Vec::with_capacity(batch.len());
        for (p, w) in batch {
            writes.push(match w {
                Want::None => {
                    out.dropped += 1;
                    Write::Drop(p)
                }
                Want::Tombstone => {
                    out.rows += 1;
                    out.tombstones += 1;
                    Write::Row(FileRow::tombstone(&p), None)
                }
                Want::Row { blob, bytes } => {
                    out.rows += 1;
                    let l = listed(p.clone(), blob, &bytes, facts[&p]);
                    if stored.contains(&p) {
                        Write::Row(row_of(&l), Some(bytes))
                    } else {
                        out.chunked += 1;
                        Write::Built(build(&l, &bytes))
                    }
                }
            });
        }
        // a stored pair swept meanwhile is chunked from the bytes kept for it, and written again
        loop {
            let missed = cx
                .store
                .handle()
                .write(move |c| {
                    let mut missed = Vec::new();
                    for w in writes {
                        match w {
                            Write::Drop(p) => remove_file_row(c, t, &p)?,
                            Write::Built(b) => {
                                write_version(
                                    c,
                                    t,
                                    &b.row,
                                    Some((&b.chunks, &b.symbols, &b.refs)),
                                    false,
                                )?;
                            }
                            Write::Row(row, bytes) => {
                                if write_version(c, t, &row, None, false)?.is_none() {
                                    missed.push((row, bytes));
                                }
                            }
                        }
                    }
                    Ok(missed)
                })
                .await?;
            if missed.is_empty() {
                break;
            }
            writes = missed
                .into_iter()
                .map(|(row, bytes)| {
                    out.chunked += 1;
                    let l = listed(
                        row.path.clone(),
                        row.blob.clone().unwrap_or_default(),
                        bytes.as_deref().unwrap_or_default(),
                        row.generated,
                    );
                    Write::Built(build(&l, bytes.as_deref().unwrap_or_default()))
                })
                .collect();
        }
    }

    if only.is_none() {
        let (h, branch) = (head.id.clone(), head.symref.clone());
        cx.store
            .handle()
            .write(move |c| {
                c.execute(
                    "update tree set head = ?2, branch = ?3, seeded_from = ?4, state = 'live' where id = ?1",
                    params![t, h, branch, built_from],
                )?;
                Ok(())
            })
            .await?;
    }
    Ok(out)
}

/// One write of a batch.
enum Write {
    Drop(String),
    /// A row whose content is stored (or a tombstone, with no bytes); the bytes, in case it was swept meanwhile.
    Row(FileRow, Option<Vec<u8>>),
    Built(Built),
}

/// T's want where it has no admitted content: a tombstone over a base row, else nothing.
fn absent(in_base: Option<&String>) -> Want {
    if in_base.is_some() {
        Want::Tombstone
    } else {
        Want::None
    }
}
