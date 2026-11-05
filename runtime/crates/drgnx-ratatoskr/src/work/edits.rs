//! An agent's edited files, with counts and hunks, from snapshots alone (the interim before the edit history).
//!
//! Every number here is a diff between two trees of the worktree's shadow repository: the base tree the hub took when
//! it made the worktree (`worktree_base.base_tree`) and the tree of a step snapshot. The agent's own tree is never
//! asked: step snapshots are written with `add -A`, so a file the agent created (untracked in git's terms) is in the
//! tree and counts as new.

use crate::dispatch::Caller;
use crate::front::Front;
use crate::timeline::snapshot::{self, FileCount};
use norn::read::steps as table;
use runstav::methods::work::{
    EditedFile, EditedFiles, EditedFilesList, FileAt, FileAtParams, Hunks, HunksParams,
};
use runstav::wire::Error;
use std::path::{Path, PathBuf};

/// The files that differ between BASE_TREE and TREE.
pub fn changed_files(
    root: &Path,
    worktree: &Path,
    base_tree: &str,
    tree: &str,
) -> Result<Vec<FileCount>, String> {
    snapshot::numstat(root, worktree, base_tree, tree)
}

/// PATH's bytes in TREE.
pub fn file_blob(root: &Path, worktree: &Path, tree: &str, path: &str) -> Result<Vec<u8>, String> {
    check_path(path)?;
    snapshot::blob(root, worktree, tree, path)
}

/// A path inside the worktree: relative, no `..`, no NUL.
fn check_path(path: &str) -> Result<(), String> {
    let bad = path.is_empty()
        || path.contains('\0')
        || path.starts_with('/')
        || path.split('/').any(|c| c == ".." || c == ".");
    if bad {
        return Err(format!("{path:?} is not a path inside the worktree"));
    }
    Ok(())
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64, padded.
fn base64(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= c.len() {
                out.push(B64[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

fn fail(message: impl Into<String>) -> Error {
    crate::runner::invalid(message)
}

/// Where a session's snapshots are: the shadow repositories' root, its worktree, its base tree and its snapshots
/// (step `seq`, tree), oldest first.
struct Ground {
    root: PathBuf,
    worktree: PathBuf,
    base: String,
    snaps: Vec<(u64, String)>,
}

async fn ground(f: &Front, session: &str) -> Result<Ground, Error> {
    let worktree = f
        .core
        .agents
        .worktree(session)
        .ok_or_else(|| fail(format!("no session {session}")))?;
    let root = f
        .dirs
        .get()
        .ok_or_else(|| fail("the hub keeps no snapshots here"))?
        .hub
        .join("checkpoints");
    let (wt, sid) = (
        worktree.to_string_lossy().into_owned(),
        format!("session:{session}"),
    );
    let (base, steps) = f
        .writer
        .db
        .read(move |c| {
            Ok((
                norn::read::work::base(c, &wt)?.and_then(|b| b.base_tree),
                table::for_session(c, &sid, 0)?,
            ))
        })
        .await
        .map_err(|e| fail(e.to_string()))?;
    let base = base.ok_or_else(|| fail(format!("session {session} has no base snapshot")))?;
    let snaps = steps
        .into_iter()
        .filter_map(|s| Some((s.seq as u64, s.snapshot?)))
        .collect();
    Ok(Ground {
        root,
        worktree,
        base,
        snaps,
    })
}

/// What the latest step snapshot changed against the base: the base tree, the snapshot's step, and the files. None
/// before the session's first snapshot.
pub struct Changed {
    pub base: String,
    pub seq: u64,
    pub files: Vec<FileCount>,
}

async fn changed_in(g: Ground) -> Result<Option<(Ground, Changed)>, Error> {
    let Some((seq, tree)) = g.snaps.last().cloned() else {
        return Ok(None);
    };
    let (root, wt, base) = (g.root.clone(), g.worktree.clone(), g.base.clone());
    let files = tokio::task::spawn_blocking(move || changed_files(&root, &wt, &base, &tree))
        .await
        .map_err(|e| fail(e.to_string()))?
        .map_err(fail)?;
    let base = g.base.clone();
    Ok(Some((g, Changed { base, seq, files })))
}

/// The session's changed files now, for the map's `Changed` fact.
pub async fn changed(f: &Front, session: &str) -> Result<Option<Changed>, Error> {
    Ok(changed_in(ground(f, session).await?).await?.map(|(_, c)| c))
}

/// `work/files`.
pub async fn files(f: &Front, _: &Caller, p: EditedFiles) -> Result<EditedFilesList, Error> {
    let g = ground(f, p.session.as_str()).await?;
    let files = changed_in(g)
        .await?
        .map(|(_, c)| c.files)
        .unwrap_or_default()
        .into_iter()
        .map(|c| EditedFile {
            path: c.path,
            plus: c.plus,
            minus: c.minus,
            untracked: c.untracked,
            read_at: None,
        })
        .collect();
    Ok(EditedFilesList { files })
}

/// `work/hunks`.
pub async fn hunks(f: &Front, _: &Caller, p: HunksParams) -> Result<Hunks, Error> {
    let path = p.path.into_inner();
    check_path(&path).map_err(fail)?;
    let g = ground(f, p.session.as_str()).await?;
    let Some((_, tree)) = g.snaps.last().cloned() else {
        return Ok(Hunks {
            diff: String::new(),
        });
    };
    let diff = tokio::task::spawn_blocking(move || {
        snapshot::patch(&g.root, &g.worktree, &g.base, &tree, &path)
    })
    .await
    .map_err(|e| fail(e.to_string()))?
    .map_err(fail)?;
    Ok(Hunks { diff })
}

/// `work/file-at`.
pub async fn file_at(f: &Front, _: &Caller, p: FileAtParams) -> Result<FileAt, Error> {
    let path = p.path.into_inner();
    check_path(&path).map_err(fail)?;
    let g = ground(f, p.session.as_str()).await?;
    let Some((seq, tree)) = g.snaps.iter().rev().find(|(s, _)| *s <= p.seq).cloned() else {
        return Err(fail(format!("no snapshot at or before step {}", p.seq)));
    };
    let bytes = tokio::task::spawn_blocking(move || file_blob(&g.root, &g.worktree, &tree, &path))
        .await
        .map_err(|e| fail(e.to_string()))?
        .map_err(fail)?;
    Ok(FileAt {
        bytes: base64(&bytes),
        seq,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline::snapshot::{take, take_base};

    fn dirs() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
        std::fs::create_dir_all(&wt).unwrap();
        (d, root, wt)
    }

    /// Pattern D: counts are the latest step tree against the recorded base, and a file that did not change is not
    /// listed.
    #[test]
    fn counts_against_the_recorded_base() {
        let (_d, root, wt) = dirs();
        std::fs::write(wt.join("a.txt"), "one\ntwo\nthree\n").unwrap();
        std::fs::write(wt.join("same.txt"), "x\n").unwrap();
        let base = take_base(&root, &wt, "job/1-1").unwrap();
        std::fs::write(wt.join("a.txt"), "one\n2\nthree\nfour\n").unwrap();
        let t1 = take(&root, &wt, "s1", 1, &[]).unwrap();
        std::fs::write(wt.join("a.txt"), "one\n2\nthree\nfour\nfive\n").unwrap();
        let t2 = take(&root, &wt, "s1", 2, &[]).unwrap();
        let at = |t: &str| changed_files(&root, &wt, &base, t).unwrap();
        assert_eq!(
            at(&t1)
                .iter()
                .map(|f| (f.plus, f.minus))
                .collect::<Vec<_>>(),
            [(2, 1)]
        );
        let latest = at(&t2);
        assert_eq!(latest.len(), 1);
        assert_eq!(
            (
                latest[0].path.as_str(),
                latest[0].plus,
                latest[0].minus,
                latest[0].untracked
            ),
            ("a.txt", 3, 1, false)
        );
    }

    /// Pattern D: a file the agent created after the base is listed, marked new, and counted by its lines.
    #[test]
    fn untracked_new_file_counts() {
        let (_d, root, wt) = dirs();
        std::fs::write(wt.join("a.txt"), "one\n").unwrap();
        let base = take_base(&root, &wt, "k").unwrap();
        std::fs::create_dir_all(wt.join("sub")).unwrap();
        std::fs::write(wt.join("sub/new.txt"), "a\nb\nc\n").unwrap();
        let t = take(&root, &wt, "s1", 1, &[]).unwrap();
        let got = changed_files(&root, &wt, &base, &t).unwrap();
        assert_eq!(got.len(), 1, "{got:?}");
        assert_eq!(
            (
                got[0].path.as_str(),
                got[0].plus,
                got[0].minus,
                got[0].untracked
            ),
            ("sub/new.txt", 3, 0, true)
        );
    }

    /// Pattern D: the diff of one file is its hunk against the base, and the worktree is not asked.
    #[test]
    fn hunks_of_one_file_against_the_base() {
        let (_d, root, wt) = dirs();
        std::fs::write(wt.join("a.txt"), "one\ntwo\n").unwrap();
        std::fs::write(wt.join("b.txt"), "x\n").unwrap();
        let base = take_base(&root, &wt, "k").unwrap();
        std::fs::write(wt.join("a.txt"), "one\n2\n").unwrap();
        std::fs::write(wt.join("b.txt"), "y\n").unwrap();
        let t = take(&root, &wt, "s1", 1, &[]).unwrap();
        std::fs::remove_dir_all(&wt).unwrap();
        let d = snapshot::patch(&root, &wt, &base, &t, "a.txt").unwrap();
        assert!(d.contains("-two\n+2\n"), "{d}");
        assert!(!d.contains("b.txt"), "{d}");
    }

    /// Pattern D: the encoder pads as the standard does, and the path check refuses what leaves the worktree.
    #[test]
    fn base64_and_paths() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(&[0, 159, 146, 150, 10]), "AJ+Slgo=");
        for bad in ["", "/etc/passwd", "../x", "a/../b", "a/./b"] {
            assert!(check_path(bad).is_err(), "{bad}");
        }
        assert!(check_path("sub/new.txt").is_ok());
    }

    /// Pattern D: a file at a step is the bytes of that step's snapshot, not the worktree's now; a path the tree lacks
    /// is an error.
    #[test]
    fn file_at_a_step_is_the_snapshot_blob() {
        let (_d, root, wt) = dirs();
        std::fs::write(wt.join("a.bin"), [0u8, 159, 146, 150, 10]).unwrap();
        let t1 = take(&root, &wt, "s1", 1, &[]).unwrap();
        std::fs::write(wt.join("a.bin"), "later\n").unwrap();
        let t2 = take(&root, &wt, "s1", 2, &[]).unwrap();
        assert_eq!(
            file_blob(&root, &wt, &t1, "a.bin").unwrap(),
            [0u8, 159, 146, 150, 10]
        );
        assert_eq!(file_blob(&root, &wt, &t2, "a.bin").unwrap(), b"later\n");
        assert!(file_blob(&root, &wt, &t1, "missing.txt").is_err());
    }
}
