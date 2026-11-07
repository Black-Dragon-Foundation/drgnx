//! The edit history's hub side (docs/develop/history.md, "The hub"): capture of agent writes, outside changes and git
//! events into `verdandi`'s documents, and the methods the editor tracks its buffers with.
//!
//! - [`origin`]: whose version a change is (pure): the hub's write, the watcher's event about it and a rescan are one.
//! - [`capture`]: reads a file the way an agent's tree must be read (no link followed), routes it to a document or the
//!   snapshot class, diffs it onto the document and records it.
//! - [`backup`]: the nightly copy of each project's `history.db`, beside `work.db`'s.
//! - [`blob`]: git object ids through a git directory the caller names.
//! - [`methods`]: `register`, `batch`, `resync`, `unregister` on the hub, for the editor's buffers.
//! - [`watch`]: Hrafn's watcher events into the hub.
//! - [`tree`]: what may be written into an agent's tree, a commit there inside its sandbox, and a fork's tree.
//! - [`revert`]: revert to here, the `history/revert/*` methods over the pure order in `revert_core`.
//! - [`branches`]: fork from here and the branches it makes: `history/fork`, `history/fork/drop`, `history/compare`,
//!   `history/take`, `history/redo`.
//! - [`merge`]: a task's branch merged into the job's tree, as the union of their documents.
//! - [`views`]: `history/blame` and `history/hunks`: who wrote the text, and what a branch changed since a record.
//! - [`hunk`]: one hunk of an agent's record reverted with later typing kept, and who undid each hunk:
//!   `history/op/hunks`, `history/revert/hunk`.

pub mod backup;
pub mod blob;
pub mod branches;
mod capture;
pub mod hunk;
pub(crate) mod merge;
pub mod methods;
pub mod origin;
pub mod revert;
pub(crate) mod revert_core;
pub mod timers;
pub mod tree;
pub mod views;
pub mod watch;
pub mod wire;

pub use capture::{Attached, HOLD};
pub use methods::{BATCH_MAX, BatchChange, BatchReply, Registered};

use crate::editor::ranges::{AgentRanges, Op};
use origin::Origins;
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};
use verdandi::{BranchId, DocId, History, PeerId, Settler, WorktreeId};

/// One worktree: where it is, the git directory its history is read through, and the commit its branch starts from.
/// For a tree a sandboxed agent worked in, GIT_DIR is the run's trusted store, never the tree's own `.git`.
#[derive(Clone, Debug)]
pub struct Tree {
    pub id: WorktreeId,
    pub root: PathBuf,
    pub git_dir: PathBuf,
    pub base: Option<String>,
}

impl Tree {
    pub fn new(root: &Path, git_dir: &Path, base: Option<&str>) -> Tree {
        Tree {
            id: WorktreeId::of(root, git_dir),
            root: root.to_path_buf(),
            git_dir: git_dir.to_path_buf(),
            base: base.map(str::to_owned),
        }
    }

    /// The branch name of this worktree's documents.
    pub(crate) fn branch_name(&self) -> String {
        format!("wt/{}", self.id.0)
    }

    /// This worktree's branch in H, made on first use, with the folder it is for (a sweep freezes it when the folder
    /// is gone).
    pub(crate) fn branch_in(&self, h: &mut History) -> verdandi::Result<BranchId> {
        let b = h.branch(
            &self.branch_name(),
            verdandi::BranchKind::Worktree,
            self.base.as_deref(),
        )?;
        h.set_root(b, &self.root.to_string_lossy())?;
        Ok(b)
    }
}

/// Where a version's content is kept.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Class {
    /// A document in `history.db`.
    Text,
    /// Whole-file versions in the hub's shadow repository: binary, large, generated, a lock file, a link.
    Snapshot,
}

/// The bus event `history/file-version`: a version of PATH in a worktree, its git blob id (none: the file is gone) and
/// the record that made it.  The shape is frozen for its consumers.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct FileVersion {
    pub worktree: String,
    pub path: String,
    pub blob: Option<String>,
    pub op: i64,
    pub class: Class,
}

/// A buffer the editor tracks.
pub(crate) struct Buffer {
    pub doc: DocId,
    pub branch: BranchId,
    /// The buffer's own text while it differs from the document's because a key was redacted from it: kept in memory
    /// only, so the buffer's hash can still be checked; none while the two are the same.
    pub raw: Option<String>,
    /// The buffer's file.
    pub file: PathBuf,
    /// The buffer's version: what its last batch or resync carried (0 at the register).
    pub version: u64,
}

pub(crate) struct Inner {
    pub h: History,
    pub origin: Origins,
    pub settler: Settler,
    pub peers: HashMap<(BranchId, String), PeerId>,
    pub buffers: HashMap<String, Buffer>,
    /// Who wrote each line of a document on a branch, in step with its operations ([`kept_op`]).
    pub kept: HashMap<(DocId, BranchId), Kept>,
    /// Per tree, the agent sessions working in it ([`Hub::attach_agent`]).
    pub agents: HashMap<String, usize>,
    /// Per tree, the watcher's file events waiting for a step boundary to claim them: path and when it was seen.
    pub held: HashMap<String, Vec<(String, f64)>>,
}

/// One document's line authors on one branch, at the document's version FRONTIER.
pub(crate) struct Kept {
    frontier: verdandi::Frontier,
    ranges: AgentRanges,
}

/// The author key of AUTHOR, a peer's author record: `user`, `agent:<session>`, `external:<source>`, `origin:<name>`.
fn author_key(author: Option<&serde_json::Value>) -> String {
    let field = |k: &str| author.and_then(|a| a.get(k)).and_then(|v| v.as_str());
    match field("kind") {
        Some("user") => "user".to_owned(),
        Some("agent") => format!("agent:{}", field("session").unwrap_or("")),
        Some("external") => format!("external:{}", field("source").unwrap_or("")),
        Some(other) => format!("origin:{}", field("name").unwrap_or(other)),
        None => "origin:".to_owned(),
    }
}

impl Inner {
    /// DOC on BRANCH's line authors, in step with its text: the kept ones, else made again from its blame (after a
    /// restart, or when an operation reached the document by a way that keeps none: a revert, a merge).
    pub(crate) fn kept_ranges(
        &mut self,
        doc: DocId,
        branch: BranchId,
    ) -> verdandi::Result<&AgentRanges> {
        let now = self.h.frontier(doc, branch)?;
        if self
            .kept
            .get(&(doc, branch))
            .is_none_or(|k| k.frontier != now)
        {
            let text = self.h.text(doc, branch)?;
            let n = text.chars().count();
            let mut keys: HashMap<PeerId, String> = self
                .peers
                .iter()
                .filter(|((b, _), _)| *b == branch)
                .map(|((_, k), p)| (*p, k.clone()))
                .collect();
            let mut blame = Vec::new();
            for b in self.h.blame(doc, branch, 0..n)? {
                let key = match keys.get(&b.peer) {
                    Some(k) => k.clone(),
                    None => {
                        let k = author_key(self.h.author_of(b.peer)?.as_ref());
                        keys.insert(b.peer, k.clone());
                        k
                    }
                };
                blame.push((b.range, key));
            }
            self.kept.insert(
                (doc, branch),
                Kept {
                    frontier: now,
                    ranges: AgentRanges::rebuild(&text, &blame),
                },
            );
        }
        Ok(&self.kept[&(doc, branch)].ranges)
    }
}

/// The hook on each operation the history applies: CH by the author KEY took DOC on BRANCH from version BEFORE to
/// AFTER.  The kept line authors follow it when they were at BEFORE; else they are dropped (made again when read).
pub(crate) fn kept_op(
    kept: &mut HashMap<(DocId, BranchId), Kept>,
    at: (DocId, BranchId),
    key: &str,
    ch: &verdandi::Change,
    before: &verdandi::Frontier,
    after: verdandi::Frontier,
) {
    let Some(k) = kept.get_mut(&at) else { return };
    let op = Op {
        author: key,
        start: ch.start,
        old_len: ch.old_len,
        inserted: &ch.inserted,
    };
    if k.frontier == *before && k.ranges.apply_op(op) {
        k.frontier = after;
    } else {
        kept.remove(&at);
    }
}

/// One project's history: `history.db`, the origin core and the tracked buffers.  Methods are synchronous and may run
/// git: call them from `clock::blocking`.
pub struct Hub {
    pub(crate) inner: Mutex<Inner>,
    events: tokio::sync::broadcast::Sender<FileVersion>,
    /// The folder `history.db` is in; the sweep's report is written beside it.
    pub(crate) dir: std::path::PathBuf,
}

impl Hub {
    /// The history in DIR (`DIR/history.db`).
    pub fn open(dir: &Path) -> verdandi::Result<Hub> {
        Ok(Hub {
            inner: Mutex::new(Inner {
                h: History::open(dir)?,
                origin: Origins::default(),
                settler: Settler::default(),
                peers: HashMap::new(),
                buffers: HashMap::new(),
                kept: HashMap::new(),
                agents: HashMap::new(),
                held: HashMap::new(),
            }),
            events: tokio::sync::broadcast::channel(256).0,
            dir: dir.to_path_buf(),
        })
    }

    pub(crate) fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The store, for a reader that needs more than the methods below give.
    pub fn with<R>(&self, f: impl FnOnce(&mut History) -> R) -> R {
        f(&mut self.lock().h)
    }

    /// The `history/file-version` events from now on.
    pub fn subscribe(&self) -> tokio::sync::broadcast::Receiver<FileVersion> {
        self.events.subscribe()
    }

    pub(crate) fn publish(&self, v: &[FileVersion]) {
        for e in v {
            let _ = self.events.send(e.clone());
        }
    }

    /// Store every active document's snapshot and close.
    pub fn close(&self) -> verdandi::Result<()> {
        self.lock().h.close()
    }

    /// TREE's branch and REL's document there, when the history holds both (none is made).
    fn found(g: &Inner, tree: &Tree, rel: &str) -> verdandi::Result<Option<(DocId, BranchId)>> {
        let Some(branch) = g.h.find_branch(&tree.branch_name())? else {
            return Ok(None);
        };
        Ok(g.h.find_doc(rel)?.map(|d| (d, branch)))
    }

    /// The lines each author wrote in REL of TREE (author keys, sorted, and their lines), from the history's
    /// operations; none when the history does not hold REL on the tree's branch.
    pub fn lines_by(
        &self,
        tree: &Tree,
        rel: &str,
    ) -> verdandi::Result<Option<crate::editor::ranges::LinesBy>> {
        let mut g = self.lock();
        let Some((doc, branch)) = Self::found(&g, tree, rel)? else {
            return Ok(None);
        };
        let ranges = match g.kept_ranges(doc, branch) {
            Ok(r) => r,
            Err(verdandi::Error::NotFound(_)) => return Ok(None),
            Err(e) => return Err(e),
        };
        Ok(Some(
            ranges
                .authors()
                .into_iter()
                .map(|a| {
                    let rs = ranges.ranges(&a);
                    (a, rs)
                })
                .collect(),
        ))
    }

    /// The boundary of a hold on an agent's wheel (docs/develop/coordination.md, "Take the wheel"): typing waiting for
    /// its record is settled into one now, and the newest record is where the give's changes start (0 while the
    /// history has none: from each document as first stored).
    pub fn boundary(&self, now: f64) -> verdandi::Result<i64> {
        let mut g = self.lock();
        let g = &mut *g;
        g.settler
            .flush(&mut g.h, verdandi::FlushReason::StepBoundary, now)?;
        Ok(g.h.last_op()?.map_or(0, |o| o.0))
    }

    /// What changed since record SINCE in the files of TREE the editor tracks (a buffer registered: its document is
    /// the truth, unsaved typing included), as a unified diff per file (`diff --git a/REL b/REL`), and those files.
    /// A file no buffer tracks is left to the step snapshot.
    pub fn changes_since(
        &self,
        tree: &Tree,
        since: i64,
    ) -> verdandi::Result<(String, Vec<String>)> {
        let mut g = self.lock();
        let Some(branch) = g.h.find_branch(&tree.branch_name())? else {
            return Ok((String::new(), Vec::new()));
        };
        let mut docs: Vec<DocId> = g
            .buffers
            .values()
            .filter(|b| b.branch == branch)
            .map(|b| b.doc)
            .collect();
        docs.sort();
        docs.dedup();
        let mut diff = String::new();
        let mut tracked = Vec::new();
        for doc in docs {
            let rel = g.h.path_of(doc)?;
            let old = g.h.text_after(doc, branch, verdandi::OpId(since))?;
            let new = g.h.text(doc, branch)?;
            if old != new {
                let (a, b) = (format!("a/{rel}"), format!("b/{rel}"));
                diff.push_str(&format!("diff --git {a} {b}\n"));
                diff.push_str(
                    &similar::TextDiff::from_lines(&old, &new)
                        .unified_diff()
                        .header(&a, &b)
                        .to_string(),
                );
            }
            tracked.push(rel);
        }
        Ok((diff, tracked))
    }

    /// The file of the tracked buffer BUFFER_ID.
    pub fn buffer_file(&self, buffer_id: &str) -> Option<PathBuf> {
        self.lock().buffers.get(buffer_id).map(|b| b.file.clone())
    }

    /// The text of REL of TREE as the editor's tracked buffer of it has it (the mirror: unsaved typing included, a
    /// redacted key as the buffer has it); none when no buffer of it is tracked.
    pub fn mirror_text(&self, tree: &Tree, rel: &str) -> verdandi::Result<Option<String>> {
        let mut g = self.lock();
        let Some(at) = Self::found(&g, tree, rel)? else {
            return Ok(None);
        };
        let raw = match g.buffers.values().find(|b| (b.doc, b.branch) == at) {
            Some(b) => b.raw.clone(),
            None => return Ok(None),
        };
        match raw {
            Some(r) => Ok(Some(r)),
            None => g.h.text(at.0, at.1).map(Some),
        }
    }

    /// The version of the editor's tracked buffer of REL of TREE (its last batch's or resync's); none when no buffer
    /// of it is tracked.
    pub fn mirror_version(&self, tree: &Tree, rel: &str) -> verdandi::Result<Option<u64>> {
        let g = self.lock();
        let Some(at) = Self::found(&g, tree, rel)? else {
            return Ok(None);
        };
        Ok(g.buffers
            .values()
            .find(|b| (b.doc, b.branch) == at)
            .map(|b| b.version))
    }

    /// TREE's document of REL as text on the tree's branch; none when it was never tracked.
    pub fn text(&self, tree: &Tree, rel: &str) -> verdandi::Result<Option<String>> {
        let mut g = self.lock();
        let branch = tree.branch_in(&mut g.h)?;
        let doc = g.h.doc_for(rel)?;
        g.h.activate(doc, branch, || {
            Ok(capture::base_text(tree, rel).unwrap_or_default())
        })
        .map(|d| Some(d.text()))
    }
}
