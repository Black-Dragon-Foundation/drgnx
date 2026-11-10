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

/// The whole-file blames kept, oldest dropped first.
#[derive(Default)]
pub struct BlameCache(std::collections::VecDeque<(Vec<u8>, w::GitBlamed)>);

impl BlameCache {
    const KEPT: usize = 16;

    fn get(&self, key: &[u8]) -> Option<w::GitBlamed> {
        self.0.iter().find(|(k, _)| k == key).map(|(_, b)| b.clone())
    }

    fn put(&mut self, key: Vec<u8>, b: w::GitBlamed) {
        self.0.retain(|(k, _)| *k != key);
        if self.0.len() == Self::KEPT {
            self.0.pop_front();
        }
        self.0.push_back((key, b));
    }
}

const UNCOMMITTED: &str = "0000000000000000000000000000000000000000";

/// `git blame --porcelain`'s answer as the commits it names and, per line, the index of its commit.  Lines git calls
/// not committed yet are one commit of zeros authored by `You`, as the editor words them.
fn parse_blame(out: &[u8]) -> Option<(Vec<w::BlameCommit>, Vec<u32>)> {
    let text = String::from_utf8_lossy(out);
    let mut commits: Vec<w::BlameCommit> = Vec::new();
    let mut index: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
    let mut lines: Vec<u32> = Vec::new();
    let mut current: Option<u32> = None;
    for l in text.split('\n') {
        if l.starts_with('\t') {
            continue;
        }
        let mut f = l.split(' ');
        let (Some(sha), Some(_orig), Some(fin)) = (f.next(), f.next(), f.next()) else {
            // a key line of the commit just named
            if let (Some(i), Some((k, v))) = (current, l.split_once(' ')) {
                let c = &mut commits[i as usize];
                match k {
                    "author" if c.sha != UNCOMMITTED => c.author = v.to_owned(),
                    "author-time" if c.sha != UNCOMMITTED => c.time = v.parse().ok(),
                    "summary" if c.sha != UNCOMMITTED => c.summary = v.to_owned(),
                    _ => {}
                }
            }
            continue;
        };
        if sha.len() == 40 && sha.bytes().all(|b| b.is_ascii_hexdigit()) {
            let fin: usize = fin.parse().ok()?;
            let i = *index.entry(sha.to_owned()).or_insert_with(|| {
                let none = sha == UNCOMMITTED;
                commits.push(w::BlameCommit {
                    sha: sha.to_owned(),
                    author: if none { "You".into() } else { String::new() },
                    time: None,
                    summary: if none {
                        "Uncommitted changes".into()
                    } else {
                        String::new()
                    },
                });
                u32::try_from(commits.len() - 1).unwrap_or(u32::MAX)
            });
            current = Some(i);
            if lines.len() < fin {
                lines.resize(fin, i);
            }
            lines[fin - 1] = i;
        } else if let (Some(i), Some((k, v))) = (current, l.split_once(' ')) {
            let c = &mut commits[i as usize];
            match k {
                "author" if c.sha != UNCOMMITTED => c.author = v.to_owned(),
                "author-time" if c.sha != UNCOMMITTED => c.time = v.parse().ok(),
                "summary" if c.sha != UNCOMMITTED => c.summary = v.to_owned(),
                _ => {}
            }
        }
    }
    Some((commits, lines))
}

/// How many lines TEXT has (a last line without its newline counts).
fn line_count(text: &str) -> usize {
    text.lines().count()
}

impl Hub {
    /// Git's blame of REL of TREE, whole file, for the text the editor's tracked buffer of it holds (unsaved typing
    /// included; else the file as it is).  One `git blame` child per distinct (path, HEAD, text): the answer is kept.
    /// A file git does not hold is all uncommitted.  Lines an agent wrote, from the edit history, ride along.
    pub fn git_blame(&self, tree: &Tree, rel: &str) -> verdandi::Result<w::GitBlamed> {
        let mirror = self.mirror_text(tree, rel)?;
        let key = {
            use sha2::{Digest, Sha256};
            let mut h = Sha256::new();
            h.update(tree.root.as_os_str().as_encoded_bytes());
            h.update([0]);
            h.update(rel.as_bytes());
            h.update([0]);
            h.update(tree.base.as_deref().unwrap_or("").as_bytes());
            h.update([0]);
            match &mirror {
                Some(t) => h.update(t.as_bytes()),
                None => {
                    // the file as it is: its size and time stand for its text
                    let m = std::fs::metadata(tree.root.join(rel)).ok();
                    let t = m.as_ref().and_then(|m| m.modified().ok());
                    h.update(format!("{:?}{:?}", m.map(|m| m.len()), t));
                }
            }
            h.finalize().to_vec()
        };
        let cached = self.blame_cache.lock().ok().and_then(|c| c.get(&key));
        if let Some(b) = cached {
            return Ok(b);
        }
        let bytes = mirror.as_ref().map(|t| t.as_bytes().to_vec());
        let blamed = match super::blob::blame_porcelain(&tree.git_dir, &tree.root, rel, bytes.as_deref()) {
            Ok(out) => parse_blame(&out)
                .ok_or_else(|| verdandi::Error::Refused("git blame gave output it could not read".into()))?,
            // git holds no such file (new, untracked): every line is the user's, not committed
            Err(e) if e.contains("no such path") || e.contains("does not exist") => {
                let n = match &mirror {
                    Some(t) => line_count(t),
                    None => std::fs::read_to_string(tree.root.join(rel)).map_or(0, |t| line_count(&t)),
                };
                (
                    vec![w::BlameCommit {
                        sha: UNCOMMITTED.into(),
                        author: "You".into(),
                        time: None,
                        summary: "Uncommitted changes".into(),
                    }],
                    vec![0; n],
                )
            }
            Err(e) => return Err(verdandi::Error::Refused(format!("git blame: {e}"))),
        };
        let agents = match &mirror {
            Some(t) => self.agent_lines(tree, rel, t)?,
            None => Vec::new(),
        };
        let out = w::GitBlamed {
            head: tree.base.clone(),
            commits: blamed.0,
            lines: blamed.1,
            agents,
        };
        if let Ok(mut c) = self.blame_cache.lock() {
            c.put(key, out.clone());
        }
        Ok(out)
    }

    /// The lines of TEXT (REL's document of TREE) that agents wrote, from the history's blame.
    fn agent_lines(&self, tree: &Tree, rel: &str, text: &str) -> verdandi::Result<Vec<w::AgentLines>> {
        let total = text.chars().count();
        let spans = self.blame(tree, rel, 0..total)?;
        // the char offset each line starts at
        let mut starts = vec![0usize];
        for (i, ch) in text.chars().enumerate() {
            if ch == '\n' {
                starts.push(i + 1);
            }
        }
        let line_of = |off: usize| starts.partition_point(|s| *s <= off);
        let mut out: Vec<w::AgentLines> = Vec::new();
        for s in spans {
            let is_agent = s
                .author
                .as_ref()
                .and_then(|a| a.get("kind"))
                .and_then(|k| k.as_str())
                == Some("agent");
            if !is_agent || s.end <= s.start {
                continue;
            }
            let (from, to) = (line_of(usize::try_from(s.start).unwrap_or(0)), line_of(usize::try_from(s.end - 1).unwrap_or(0)));
            out.push(w::AgentLines {
                from: n(from),
                to: n(to),
                session: s.session,
                step: s.step,
            });
        }
        Ok(out)
    }

    /// The hunks of the editor's tracked buffer of REL of TREE against HEAD's text of it (a file HEAD does not hold is
    /// all added); none when no buffer of it is tracked.
    pub fn hunks_head(&self, tree: &Tree, rel: &str) -> verdandi::Result<Option<Vec<w::LineHunk>>> {
        let Some(now) = self.mirror_text(tree, rel)? else {
            return Ok(None);
        };
        let old = super::blob::text_at(&tree.git_dir, &tree.root, "HEAD", rel)
            .map(|b| String::from_utf8_lossy(&b).into_owned())
            .unwrap_or_default();
        Ok(Some(
            verdandi::threeway::diff_hunks(&old, &now)?
                .into_iter()
                .map(|(os, oc, ns, nc)| w::LineHunk {
                    old_start: n(os),
                    old_count: n(oc),
                    new_start: n(ns),
                    new_count: n(nc),
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

/// `git/blame`.
pub async fn git_blame(f: &Front, c: &Caller, p: w::GitBlameParams) -> Result<w::GitBlamed, Error> {
    super::revert::user_only(c)?;
    let (hub, tree) = f
        .core
        .history
        .of_tree(&hub_dir(f)?, Path::new(&p.worktree_root))?;
    crate::clock::blocking(move || hub.git_blame(&tree, &p.path))
        .await
        .map_err(|e| internal(e.to_string()))?
        .map_err(store)
}

/// `history/hunks/head`.
pub async fn hunks_head(
    f: &Front,
    c: &Caller,
    p: w::HeadHunksParams,
) -> Result<w::HeadHunks, Error> {
    super::revert::user_only(c)?;
    let (hub, tree) = f
        .core
        .history
        .of_tree(&hub_dir(f)?, Path::new(&p.worktree_root))?;
    let found = crate::clock::blocking(move || hub.hunks_head(&tree, &p.path))
        .await
        .map_err(|e| internal(e.to_string()))?
        .map_err(store)?;
    Ok(match found {
        Some(hunks) => w::HeadHunks {
            tracked: true,
            hunks,
        },
        None => w::HeadHunks {
            tracked: false,
            hunks: Vec::new(),
        },
    })
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

    /// A tracked buffer of REL holding TEXT as the editor sent it (a batch against the file's committed text).
    fn tracked(f: &Fx, rel: &str, now: &str, origin: &str) {
        let home = tempfile::tempdir().unwrap();
        let deny = norn::deny::DenyList::load(home.path(), home.path());
        f.hub.register(&f.tree, rel, "b1", &deny).unwrap();
        let old = std::fs::read_to_string(f.tree.root.join(rel)).unwrap_or_default();
        let (start, old_len) = (0, old.chars().count());
        let hash = crate::history::methods::hash(now);
        let change = crate::history::methods::BatchChange {
            start,
            old_len,
            inserted: now.into(),
            origin: origin.into(),
        };
        let r = f.hub.batch("b1", &[change], &hash, 1, 5.0).unwrap();
        assert_eq!(r, crate::history::methods::BatchReply::Ok);
    }

    fn commit_file(f: &Fx, rel: &str, text: &str, msg: &str) {
        std::fs::write(f.tree.root.join(rel), text).unwrap();
        git(&f.tree.root, &["add", "."]);
        git(&f.tree.root, &["commit", "-q", "-m", msg]);
    }

    // pattern: D
    #[test]
    fn git_blame_names_the_commit_of_each_line_in_one_answer() {
        let f = fx("one\ntwo\nthree\n");
        commit_file(&f, "a.txt", "one\nTWO\nthree\n", "second");
        let b = f.hub.git_blame(&f.tree, "a.txt").unwrap();
        assert_eq!(b.lines.len(), 3);
        let say = |i: usize| b.commits[b.lines[i] as usize].summary.as_str();
        assert_eq!((say(0), say(1), say(2)), ("base", "second", "base"));
        let c = &b.commits[b.lines[1] as usize];
        assert_eq!(c.author, "t");
        assert!(c.time.is_some());
        assert_eq!(c.sha.len(), 40);
        // the commits are listed once each
        assert_eq!(b.commits.len(), 2);
        assert!(b.agents.is_empty());
    }

    // pattern: D
    #[test]
    fn git_blame_of_a_tracked_buffer_has_its_unsaved_lines_uncommitted() {
        let f = fx("one\ntwo\n");
        tracked(&f, "a.txt", "one\ntyped\ntwo\n", "user");
        let b = f.hub.git_blame(&f.tree, "a.txt").unwrap();
        assert_eq!(b.lines.len(), 3, "the buffer's lines, not the file's");
        let c = |i: usize| &b.commits[b.lines[i] as usize];
        assert_eq!(c(0).summary, "base");
        assert_eq!(c(1).summary, "Uncommitted changes");
        assert_eq!((c(1).author.as_str(), c(1).time), ("You", None));
        assert!(c(1).sha.chars().all(|x| x == '0'));
        assert_eq!(c(2).summary, "base");
        // the same text again is answered from the cache: one entry, the same answer
        assert_eq!(f.hub.git_blame(&f.tree, "a.txt").unwrap(), b);
    }

    // pattern: D
    #[test]
    fn git_blame_of_a_file_git_does_not_hold_is_all_uncommitted() {
        let f = fx("one\n");
        std::fs::write(f.tree.root.join("new.txt"), "x\ny\n").unwrap();
        let b = f.hub.git_blame(&f.tree, "new.txt").unwrap();
        assert_eq!(b.lines, vec![0, 0]);
        assert_eq!(b.commits[0].summary, "Uncommitted changes");
    }

    // pattern: D
    #[test]
    fn git_blame_lines_an_agent_wrote_ride_along() {
        let f = fx("one\ntwo\n");
        tracked(&f, "a.txt", "one\ntwo\n", "user");
        let h = crate::history::methods::hash("one\ntwo\nthree\nfour\n");
        let change = crate::history::methods::BatchChange {
            start: 8,
            old_len: 0,
            inserted: "three\nfour\n".into(),
            origin: "agent:s1#7".into(),
        };
        f.hub.batch("b1", &[change], &h, 2, 6.0).unwrap();
        // typing no record holds yet is left out of the history's blame: let the agent's change settle
        f.hub.settle_due(1_000.0).unwrap();
        let b = f.hub.git_blame(&f.tree, "a.txt").unwrap();
        assert_eq!(b.lines.len(), 4);
        assert_eq!(b.agents.len(), 1, "{:?}", b.agents);
        let a = &b.agents[0];
        assert_eq!((a.from, a.to), (3, 4));
        assert_eq!(a.session.as_deref(), Some("s1"));
        assert_eq!(a.step.as_deref(), Some("7"));
    }

    // pattern: D
    #[test]
    fn hunks_against_head_equal_git_diff() {
        let f = fx("a\nb\nc\nd\n");
        let now = "a\nB\nc\nd\ne\n";
        tracked(&f, "a.txt", now, "user");
        let got = f.hub.hunks_head(&f.tree, "a.txt").unwrap().expect("tracked");
        let got: Vec<_> = got
            .iter()
            .map(|h| (h.old_start, h.old_count, h.new_start, h.new_count))
            .collect();
        assert_eq!(got, git_hunks("a\nb\nc\nd\n", now));
        assert_eq!(got, [(2, 1, 2, 1), (4, 0, 5, 1)]);
        // no buffer of a file: nothing computed
        assert!(f.hub.hunks_head(&f.tree, "other.txt").unwrap().is_none());
    }

    // pattern: D
    #[test]
    fn hunks_against_head_of_a_new_file_are_all_its_lines() {
        let f = fx("one\n");
        std::fs::write(f.tree.root.join("new.txt"), "").unwrap();
        tracked(&f, "new.txt", "x\ny\nz\n", "user");
        let got = f.hub.hunks_head(&f.tree, "new.txt").unwrap().expect("tracked");
        assert_eq!(got.len(), 1);
        assert_eq!(
            (got[0].old_start, got[0].old_count, got[0].new_start, got[0].new_count),
            (0, 0, 1, 3)
        );
    }
}
