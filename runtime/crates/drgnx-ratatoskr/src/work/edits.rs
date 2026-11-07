//! An agent's edited files, with counts and hunks, from the edit history.
//!
//! `work/files`, `work/hunks` and `work/file-at` read the worktree's branch in the project's `history.db` (its
//! documents against the branch's base commit, `history::views`). The agent's folder is never asked. Text files only:
//! whole-file versions (binary, large, generated, locks) are not in the document store, so they are not listed.
//! The buffer view's gutter and the three-way projection still read the step snapshots ([`changed_lines`],
//! [`base_of`]).

use crate::dispatch::Caller;
use crate::front::Front;
use crate::history::{Hub, Tree};
use crate::timeline::snapshot::{self, FileCount};
use norn::read::steps as table;
use runstav::methods::work::{
    EditedFile, EditedFiles, EditedFilesList, FileAt, FileAtParams, Hunks, HunksParams,
};
use runstav::wire::Error;
use std::path::{Path, PathBuf};

/// TREE's files the edit history says the agent changed against the branch's base, with the base commit; none while
/// the history holds no branch for the tree.
pub fn from_history(hub: &Hub, tree: &Tree) -> Result<Option<(String, Vec<FileCount>)>, String> {
    let found = hub.edits_against_base(tree).map_err(|e| e.to_string())?;
    Ok(found.map(|(base, files)| {
        let files = files
            .into_iter()
            .map(|c| FileCount {
                path: c.path,
                plus: c.plus,
                minus: c.minus,
                untracked: c.untracked,
            })
            .collect();
        (base, files)
    }))
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
    /// The hub's time of the latest snapshot's step (its end, else its start).
    last_at: Option<f64>,
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
    let last_at = steps
        .iter()
        .rev()
        .find(|s| s.snapshot.is_some())
        .map(|s| s.end.unwrap_or(s.start));
    let snaps = steps
        .into_iter()
        .filter_map(|s| Some((s.seq as u64, s.snapshot?)))
        .collect();
    Ok(Ground {
        root,
        worktree,
        base,
        snaps,
        last_at,
    })
}

/// What the edit history says the session's agent changed against its branch's base: the base commit and the files.
/// None while the history holds no branch for the session's worktree.
pub struct Changed {
    pub base: String,
    pub files: Vec<FileCount>,
}

/// The history of SESSION's project and its worktree's tree.
fn history_of(f: &Front, session: &str) -> Result<(std::sync::Arc<Hub>, Tree), Error> {
    let worktree = f
        .core
        .agents
        .worktree(session)
        .ok_or_else(|| fail(format!("no session {session}")))?;
    let state = f
        .dirs
        .get()
        .ok_or_else(|| fail("the hub keeps no history here"))?
        .hub
        .clone();
    f.core.history.of_tree(&state, &worktree)
}

/// The session's changed files now, for the map's `Changed` fact.
pub async fn changed(f: &Front, session: &str) -> Result<Option<Changed>, Error> {
    let (hub, tree) = history_of(f, session)?;
    let found = crate::clock::blocking(move || from_history(&hub, &tree))
        .await
        .map_err(|e| fail(e.to_string()))?
        .map_err(fail)?;
    Ok(found.map(|(base, files)| Changed { base, files }))
}

/// `work/files`.
pub async fn files(f: &Front, _: &Caller, p: EditedFiles) -> Result<EditedFilesList, Error> {
    let files = changed(f, p.session.as_str())
        .await?
        .map(|c| c.files)
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
    let (hub, tree) = history_of(f, p.session.as_str())?;
    let diff = crate::clock::blocking(move || hub.diff_against_base(&tree, &path))
        .await
        .map_err(|e| fail(e.to_string()))?
        .map_err(|e| fail(e.to_string()))?;
    Ok(Hunks { diff })
}

/// Where session SESSION's base is: the shadow repositories' root, its worktree and its base tree (read a file of it
/// with [`file_blob`]).
pub async fn base_of(f: &Front, session: &str) -> Result<(PathBuf, PathBuf, String), Error> {
    let g = ground(f, session).await?;
    Ok((g.root, g.worktree, g.base))
}

/// The lines of one file its latest step snapshot changed against the base, on the snapshot's text.
pub struct ChangedLines {
    /// The snapshot's step.
    pub seq: u64,
    /// The hub's time of that step.
    pub at: Option<f64>,
    /// (first, last), 1-based.
    pub ranges: Vec<(u32, u32)>,
}

/// The lines PATH (relative to session SESSION's worktree) changed in its latest step snapshot against the base (the
/// buffer view's gutter, the interim before the edit history); none before the first snapshot, or when it changed
/// nothing there.
pub async fn changed_lines(
    f: &Front,
    session: &str,
    path: &str,
) -> Result<Option<ChangedLines>, Error> {
    check_path(path).map_err(fail)?;
    let g = ground(f, session).await?;
    let Some((seq, tree)) = g.snaps.last().cloned() else {
        return Ok(None);
    };
    let (at, path) = (g.last_at, path.to_string());
    let diff = crate::clock::blocking(move || {
        snapshot::patch(&g.root, &g.worktree, &g.base, &tree, &path)
    })
    .await
    .map_err(|e| fail(e.to_string()))?
    .map_err(fail)?;
    let ranges = crate::editor::buffer_view::changed_ranges(&diff);
    Ok((!ranges.is_empty()).then_some(ChangedLines { seq, at, ranges }))
}

/// `work/file-at`.
pub async fn file_at(f: &Front, _: &Caller, p: FileAtParams) -> Result<FileAt, Error> {
    let path = p.path.into_inner();
    check_path(&path).map_err(fail)?;
    let (hub, tree) = history_of(f, p.session.as_str())?;
    let (session, seq) = (p.session.as_str().to_owned(), p.seq);
    let found = crate::clock::blocking(move || hub.file_at_step(&tree, &path, &session, seq))
        .await
        .map_err(|e| fail(e.to_string()))?
        .map_err(|e| fail(e.to_string()))?;
    let (bytes, seq) = found.ok_or_else(|| fail("no such file at that step"))?;
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

    fn git(dir: &std::path::Path, args: &[&str]) -> String {
        let out = std::process::Command::new("git")
            .args([
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "-c",
                "commit.gpgsign=false",
            ])
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    struct Fx {
        repo: tempfile::TempDir,
        _hist: tempfile::TempDir,
        hub: crate::history::Hub,
        tree: crate::history::Tree,
    }

    fn fx(files: &[(&str, &str)]) -> Fx {
        let repo = tempfile::tempdir().unwrap();
        git(repo.path(), &["init", "-q", "-b", "main"]);
        for (p, t) in files {
            let f = repo.path().join(p);
            std::fs::create_dir_all(f.parent().unwrap()).unwrap();
            std::fs::write(f, t).unwrap();
        }
        git(repo.path(), &["add", "."]);
        git(repo.path(), &["commit", "-q", "-m", "base"]);
        let head = git(repo.path(), &["rev-parse", "HEAD"]);
        let hist = tempfile::tempdir().unwrap();
        let hub = crate::history::Hub::open(hist.path()).unwrap();
        let tree = crate::history::Tree::new(repo.path(), &repo.path().join(".git"), Some(&head));
        Fx {
            repo,
            _hist: hist,
            hub,
            tree,
        }
    }

    /// The agent writes REL: the file on disk and the history's record of it.
    fn write(f: &Fx, rel: &str, text: &str, step: &str, at: f64) {
        let p = f.repo.path().join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
        let cause = verdandi::Cause {
            session: Some("s1".into()),
            step: Some(step.into()),
            ..Default::default()
        };
        f.hub
            .on_agent_write(&f.tree, rel, text.as_bytes(), "s1", cause, at)
            .unwrap();
    }

    fn counts(f: &Fx) -> Vec<(String, u32, u32, bool)> {
        from_history(&f.hub, &f.tree)
            .unwrap()
            .expect("the branch")
            .1
            .into_iter()
            .map(|c| (c.path, c.plus, c.minus, c.untracked))
            .collect()
    }

    /// Pattern D: the history's counts are what git's numstat says of the folder against the base, and a file that
    /// did not change is not listed.
    #[test]
    fn from_history_equals_the_interim_on_the_fixture() {
        let f = fx(&[("a.txt", "one\ntwo\nthree\n"), ("same.txt", "x\n")]);
        write(&f, "a.txt", "one\n2\nthree\nfour\n", "1", 10.0);
        write(&f, "a.txt", "one\n2\nthree\nfour\nfive\n", "2", 11.0);
        assert_eq!(counts(&f), [("a.txt".to_string(), 3, 1, false)]);
        let num = git(f.repo.path(), &["diff", "--numstat", "HEAD"]);
        assert_eq!(num, "3\t1\ta.txt");
        // the diff of one file is its hunk against the base
        let d = f.hub.diff_against_base(&f.tree, "a.txt").unwrap();
        assert!(d.contains("-two\n+2\n"), "{d}");
        assert!(d.contains("+five\n"), "{d}");
        // a file at a step is the text after that step's record
        let at = |seq| f.hub.file_at_step(&f.tree, "a.txt", "s1", seq).unwrap();
        assert_eq!(at(1), Some((b"one\n2\nthree\nfour\n".to_vec(), 1)));
        assert_eq!(at(1000).map(|a| a.1), Some(2));
        // a file nothing touched is the base's, at the newest step
        let kept = f.hub.file_at_step(&f.tree, "same.txt", "s1", 5).unwrap();
        assert_eq!(kept, Some((b"x\n".to_vec(), 2)));
        assert_eq!(
            f.hub.file_at_step(&f.tree, "none.txt", "s1", 5).unwrap(),
            None
        );
    }

    /// Pattern D: a file the agent created after the base is listed, marked new, and counted by its lines.
    #[test]
    fn untracked_counts_from_history() {
        let f = fx(&[("a.txt", "one\n")]);
        write(&f, "sub/new.txt", "a\nb\nc\n", "1", 10.0);
        assert_eq!(counts(&f), [("sub/new.txt".to_string(), 3, 0, true)]);
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
