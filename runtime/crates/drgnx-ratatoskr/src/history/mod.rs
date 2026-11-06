//! The edit history's hub side (docs/develop/history.md, "The hub"): capture of agent writes, outside changes and git
//! events into `verdandi`'s documents, and the methods the editor tracks its buffers with.
//!
//! - [`origin`]: whose version a change is (pure): the hub's write, the watcher's event about it and a rescan are one.
//! - [`capture`]: reads a file the way an agent's tree must be read (no link followed), routes it to a document or the
//!   snapshot class, diffs it onto the document and records it.
//! - [`blob`]: git object ids through a git directory the caller names.
//! - [`methods`]: `register`, `batch`, `resync`, `unregister` on the hub, for the editor's buffers.
//! - [`watch`]: Hrafn's watcher events into the hub.

pub mod blob;
mod capture;
pub mod methods;
pub mod origin;
mod timers;
pub mod watch;
pub mod wire;

pub use methods::{BATCH_MAX, BatchChange, BatchReply, Registered};

use origin::OriginCore;
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
}

pub(crate) struct Inner {
    pub h: History,
    pub origin: OriginCore,
    pub settler: Settler,
    pub peers: HashMap<(BranchId, String), PeerId>,
    pub buffers: HashMap<String, Buffer>,
}

/// One project's history: `history.db`, the origin core and the tracked buffers.  Methods are synchronous and may run
/// git: call them from `clock::blocking`.
pub struct Hub {
    pub(crate) inner: Mutex<Inner>,
    events: tokio::sync::broadcast::Sender<FileVersion>,
}

impl Hub {
    /// The history in DIR (`DIR/history.db`).
    pub fn open(dir: &Path) -> verdandi::Result<Hub> {
        Ok(Hub {
            inner: Mutex::new(Inner {
                h: History::open(dir)?,
                origin: OriginCore::default(),
                settler: Settler::default(),
                peers: HashMap::new(),
                buffers: HashMap::new(),
            }),
            events: tokio::sync::broadcast::channel(256).0,
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

    /// TREE's document of REL as text on the tree's branch; none when it was never tracked.
    pub fn text(&self, tree: &Tree, rel: &str) -> verdandi::Result<Option<String>> {
        let mut g = self.lock();
        let branch = g.h.branch(
            &tree.branch_name(),
            verdandi::BranchKind::Worktree,
            tree.base.as_deref(),
        )?;
        let doc = g.h.doc_for(rel)?;
        g.h.activate(doc, branch, || {
            Ok(capture::base_text(tree, rel).unwrap_or_default())
        })
        .map(|d| Some(d.text()))
    }
}
