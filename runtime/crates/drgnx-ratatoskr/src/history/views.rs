//! The history as views: `history/blame` (who wrote a range of a file's text, in which record and step) and
//! `history/hunks` (what changed on a branch since a record, numbered as `git diff --unified=0` numbers it).  Both read
//! the project's `history.db`; neither writes.  User only.

use super::{Hub, Tree, capture};
use crate::agents::session::{internal, invalid};
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::history as w;
use runstav::wire::Error;
use std::ops::Range;
use std::path::{Path, PathBuf};
use verdandi::OpId;

fn store(e: verdandi::Error) -> Error {
    match e {
        verdandi::Error::Refused(m) => invalid("history", m),
        verdandi::Error::NotFound(m) => invalid("history", format!("not found: {m}")),
        e => internal(e.to_string()),
    }
}

fn n(v: usize) -> i64 {
    i64::try_from(v).unwrap_or(i64::MAX)
}

impl Hub {
    /// Who wrote the characters RANGE of REL's document in TREE's branch, one span per run of one author's text made in
    /// one record.  Text of the base and typing no record holds yet are left out; a range past the text is cut.
    pub fn blame(
        &self,
        tree: &Tree,
        rel: &str,
        range: Range<usize>,
    ) -> verdandi::Result<Vec<w::BlameSpan>> {
        let mut g = self.lock();
        let branch = tree.branch_in(&mut g.h)?;
        let doc = g.h.doc_for(rel)?;
        let len =
            g.h.activate(doc, branch, || {
                Ok(capture::base_text(tree, rel).unwrap_or_default())
            })?
            .text()
            .chars()
            .count();
        let range = range.start.min(len)..range.end.min(len);
        let mut out = Vec::new();
        for b in g.h.blame(doc, branch, range)? {
            let author = g.h.author_of(b.peer)?;
            let rec = g.h.op(b.op)?;
            out.push(w::BlameSpan {
                start: n(b.range.start),
                end: n(b.range.end),
                author,
                record: b.op.0,
                session: rec.cause.session,
                step: rec.cause.step,
            });
        }
        Ok(out)
    }

    /// What changed on the history branch BRANCH since record SINCE; none when this project's history holds no such
    /// branch.
    pub fn hunks_since(
        &self,
        branch: &str,
        since: i64,
    ) -> verdandi::Result<Option<Vec<w::FileHunks>>> {
        let mut g = self.lock();
        let Some(b) = g.h.find_branch(branch)? else {
            return Ok(None);
        };
        let files = g.h.hunks(b, OpId(since))?;
        Ok(Some(
            files
                .into_iter()
                .map(|f| w::FileHunks {
                    path: f.path,
                    hunks: f
                        .hunks
                        .into_iter()
                        .map(|h| w::LineHunk {
                            old_start: n(h.old_start),
                            old_count: n(h.old_count),
                            new_start: n(h.new_start),
                            new_count: n(h.new_count),
                        })
                        .collect(),
                })
                .collect(),
        ))
    }
}

/// One file an agent's worktree changed against its branch's base, with the lines added and removed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditCount {
    pub path: String,
    pub plus: u32,
    pub minus: u32,
    /// The file is not in the base commit at all (the agent made it).
    pub untracked: bool,
}

impl Hub {
    /// The files TREE's branch changed against the branch's base and their line counts, with the base commit; none
    /// while the history holds no such branch.  Text files only: whole-file versions (binary, large, generated, locks)
    /// are not in the document store.
    pub fn edits_against_base(
        &self,
        tree: &Tree,
    ) -> verdandi::Result<Option<(String, Vec<EditCount>)>> {
        let mut g = self.lock();
        let Some(branch) = g.h.find_branch(&tree.branch_name())? else {
            return Ok(None);
        };
        let base = g.h.base_of(branch)?.or_else(|| tree.base.clone());
        let files = g.h.hunks(branch, OpId(0))?;
        let count = |v: i64| u32::try_from(v).unwrap_or(u32::MAX);
        let out = files
            .into_iter()
            .map(|f| EditCount {
                untracked: base.as_deref().is_none_or(|b| {
                    super::blob::text_at(&tree.git_dir, &tree.root, b, &f.path).is_none()
                }),
                plus: f.hunks.iter().map(|h| count(n(h.new_count))).sum(),
                minus: f.hunks.iter().map(|h| count(n(h.old_count))).sum(),
                path: f.path,
            })
            .collect();
        Ok(Some((base.unwrap_or_default(), out)))
    }

    /// TREE's base commit: its history branch's base, else the commit its head names now; none for neither.
    pub fn base_commit(&self, tree: &Tree) -> verdandi::Result<Option<String>> {
        let g = self.lock();
        let base = match g.h.find_branch(&tree.branch_name())? {
            Some(b) => g.h.base_of(b)?,
            None => None,
        };
        Ok(base.or_else(|| tree.base.clone()))
    }

    /// REL's change on TREE's branch against the base as a unified diff (`diff --git a/REL b/REL`); empty when it
    /// changed nothing.
    pub fn diff_against_base(&self, tree: &Tree, rel: &str) -> verdandi::Result<String> {
        let mut g = self.lock();
        let (Some(branch), Some(doc)) = (g.h.find_branch(&tree.branch_name())?, g.h.find_doc(rel)?)
        else {
            return Ok(String::new());
        };
        let old = g.h.text_after(doc, branch, OpId(0))?;
        let new = g.h.text(doc, branch)?;
        if old == new {
            return Ok(String::new());
        }
        let (a, b) = (format!("a/{rel}"), format!("b/{rel}"));
        let body = similar::TextDiff::from_lines(&old, &new)
            .unified_diff()
            .header(&a, &b)
            .to_string();
        Ok(format!("diff --git {a} {b}\n{body}"))
    }

    /// REL of TREE as SESSION's agent had it after its newest record at or before step SEQ, with that step (0: before
    /// its first record, the base commit's file).  None when neither the history nor the base holds REL.
    pub fn file_at_step(
        &self,
        tree: &Tree,
        rel: &str,
        session: &str,
        seq: u64,
    ) -> verdandi::Result<Option<(Vec<u8>, u64)>> {
        let mut g = self.lock();
        let branch = g.h.find_branch(&tree.branch_name())?;
        // the newest record of the session at or before the step (steps only grow within a session)
        let mut at = None;
        if let (Some(_), Some(last)) = (branch, g.h.last_op()?) {
            for id in (1..=last.0).rev() {
                let cause = g.h.op(OpId(id))?.cause;
                if cause.session.as_deref() != Some(session) {
                    continue;
                }
                if let Some(step) = cause.step.as_deref().and_then(|s| s.parse::<u64>().ok())
                    && step <= seq
                {
                    at = Some((OpId(id), step));
                    break;
                }
            }
        }
        let base = match branch {
            Some(b) => g.h.base_of(b)?.or_else(|| tree.base.clone()),
            None => tree.base.clone(),
        };
        let from_base = || {
            base.as_deref()
                .and_then(|b| super::blob::text_at(&tree.git_dir, &tree.root, b, rel))
        };
        let step = at.map_or(0, |a| a.1);
        if let (Some(branch), Some(doc), Some((op, _))) = (branch, g.h.find_doc(rel)?, at) {
            let text = g.h.text_after(doc, branch, op)?;
            // a path the base lacks and the agent had not yet made (or removed): nothing there
            let there = !text.is_empty() || from_base().is_some();
            return Ok(there.then(|| (text.into_bytes(), step)));
        }
        Ok(from_base().map(|b| (b, step)))
    }
}

fn hub_dir(f: &Front) -> Result<PathBuf, Error> {
    f.dirs
        .get()
        .map(|d| d.hub.clone())
        .ok_or_else(|| internal("the hub has no state folder"))
}

/// `history/blame`.
pub async fn blame(f: &Front, c: &Caller, p: w::BlameParams) -> Result<w::Blamed, Error> {
    super::revert::user_only(c)?;
    let (Ok(start), Ok(end)) = (usize::try_from(p.start), usize::try_from(p.end)) else {
        return Err(invalid("start", "offsets are not negative"));
    };
    if end < start {
        return Err(invalid("end", "the range ends before it starts"));
    }
    let (hub, tree) = f
        .core
        .history
        .of_tree(&hub_dir(f)?, Path::new(&p.worktree_root))?;
    let spans = crate::clock::blocking(move || hub.blame(&tree, &p.path, start..end))
        .await
        .map_err(|e| internal(e.to_string()))?
        .map_err(store)?;
    Ok(w::Blamed { spans })
}

/// `history/hunks`: in whichever project's history holds the branch.
pub async fn hunks(
    f: &Front,
    c: &Caller,
    p: w::BranchHunksParams,
) -> Result<w::BranchHunks, Error> {
    super::revert::user_only(c)?;
    for hub in f.core.history.all(&hub_dir(f)?) {
        let (branch, since) = (p.branch.clone(), p.since);
        let found = crate::clock::blocking(move || hub.hunks_since(&branch, since))
            .await
            .map_err(|e| internal(e.to_string()))?
            .map_err(store)?;
        if let Some(files) = found {
            return Ok(w::BranchHunks { files });
        }
    }
    Err(invalid(
        "branch",
        format!("no project's history holds {}", p.branch),
    ))
}

#[cfg(test)]
mod tests {
    use crate::history::{Hub, Tree};
    use std::path::Path;
    use verdandi::Cause;

    fn git(dir: &Path, args: &[&str]) -> String {
        let out = std::process::Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t"])
            .args(["-c", "commit.gpgsign=false"])
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    struct Fx {
        _repo: tempfile::TempDir,
        _hist: tempfile::TempDir,
        hub: Hub,
        tree: Tree,
    }

    fn fx(text: &str) -> Fx {
        let repo = tempfile::tempdir().unwrap();
        git(repo.path(), &["init", "-q", "-b", "main"]);
        std::fs::write(repo.path().join("a.txt"), text).unwrap();
        git(repo.path(), &["add", "."]);
        git(repo.path(), &["commit", "-q", "-m", "base"]);
        let head = git(repo.path(), &["rev-parse", "HEAD"]);
        let hist = tempfile::tempdir().unwrap();
        let hub = Hub::open(hist.path()).unwrap();
        let tree = Tree::new(repo.path(), &repo.path().join(".git"), Some(&head));
        Fx {
            _repo: repo,
            _hist: hist,
            hub,
            tree,
        }
    }

    fn cause(session: &str, step: &str) -> Cause {
        Cause {
            session: Some(session.into()),
            step: Some(step.into()),
            ..Cause::default()
        }
    }

    // pattern: D
    #[test]
    fn blame_names_the_step_of_each_run() {
        let f = fx("one\ntwo\n");
        f.hub
            .on_agent_write(
                &f.tree,
                "a.txt",
                b"one\nTWO\n",
                "s1",
                cause("s1", "7"),
                10.0,
            )
            .unwrap();
        let second = f
            .hub
            .on_agent_write(
                &f.tree,
                "a.txt",
                b"one\nTWO\nthree\n",
                "s2",
                cause("s2", "9"),
                11.0,
            )
            .unwrap();
        let spans = f.hub.blame(&f.tree, "a.txt", 0..14).unwrap();
        let by = |s: &str| spans.iter().find(|x| x.session.as_deref() == Some(s));
        let (a, b) = (by("s1").expect("s1's run"), by("s2").expect("s2's run"));
        assert_eq!(a.step.as_deref(), Some("7"));
        assert_eq!(b.step.as_deref(), Some("9"));
        assert_eq!((b.start, b.end), (8, 14), "three\\n");
        assert!(a.start >= 4 && a.end <= 8, "{a:?}");
        assert_eq!(b.record, second[0].op);
        assert_eq!(b.author.as_ref().unwrap()["kind"], "agent");
        assert_eq!(b.author.as_ref().unwrap()["session"], "s2");
        // the base's text has no author, and a range is cut to what was asked
        assert!(spans.iter().all(|s| s.start >= 4), "{spans:?}");
        assert!(f.hub.blame(&f.tree, "a.txt", 0..4).unwrap().is_empty());
        assert!(
            f.hub
                .blame(&f.tree, "a.txt", 8..99)
                .unwrap()
                .iter()
                .all(|s| s.end <= 14)
        );
    }

    /// `@@ -a,b +c,d @@` headers of `git diff --unified=0`, the counts defaulting to 1.
    fn git_hunks(old: &str, new: &str) -> Vec<(i64, i64, i64, i64)> {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("old"), old).unwrap();
        std::fs::write(dir.path().join("new"), new).unwrap();
        let out = git(
            dir.path(),
            &["diff", "--no-index", "--unified=0", "old", "new"],
        );
        let num = |s: &str| {
            let (a, b) = s.split_once(',').unwrap_or((s, "1"));
            (a.parse::<i64>().unwrap(), b.parse::<i64>().unwrap())
        };
        out.lines()
            .filter_map(|l| l.strip_prefix("@@ -"))
            .map(|l| {
                let (old, rest) = l.split_once(" +").unwrap();
                let new = rest.split_once(" @@").unwrap().0;
                let (o, n) = (num(old), num(new));
                (o.0, o.1, n.0, n.1)
            })
            .collect()
    }

    // pattern: D
    #[test]
    fn hunks_view_equals_git_diff() {
        let f = fx("a\nb\nc\n");
        let first = f
            .hub
            .on_agent_write(&f.tree, "a.txt", b"a\nB\nc\n", "s1", cause("s1", "1"), 10.0)
            .unwrap();
        f.hub
            .on_agent_write(
                &f.tree,
                "a.txt",
                b"a\nB\nc\nd\n",
                "s1",
                cause("s1", "2"),
                11.0,
            )
            .unwrap();
        let branch = f.tree.branch_name();
        let files = f
            .hub
            .hunks_since(&branch, first[0].op)
            .unwrap()
            .expect("the branch");
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "a.txt");
        let got: Vec<_> = files[0]
            .hunks
            .iter()
            .map(|h| (h.old_start, h.old_count, h.new_start, h.new_count))
            .collect();
        assert_eq!(got, git_hunks("a\nB\nc\n", "a\nB\nc\nd\n"));
        assert_eq!(got, [(3, 0, 4, 1)]);
        // a branch this project's history does not hold
        assert!(f.hub.hunks_since("wt/none", first[0].op).unwrap().is_none());
    }
}
