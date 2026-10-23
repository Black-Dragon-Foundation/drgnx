//! The personal-notes deny-list (Task 9; storage §5.6, calls 8 and 19): everything under `HOME/org/` except
//! `HOME/org/board.org`, compared after `canonicalize`. A hard tier no opt-in lifts; a soft tier the user's per-file
//! opt-ins (`<config>/personal-notes-allow.json`) lift. Every door checks every path a record carries ([`paths_of`]).
//! `load` is the only constructor, and nothing sets a list's contents.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 9 removes this line.

use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

use serde_json::Value;

/// The hub's current list, replaced whole by a reload (Task 9b) and read as a snapshot (`Coord::deny`).
pub type SharedDeny = Arc<RwLock<Arc<DenyList>>>;

/// Call 19's hard tier besides `HOME/org/notes.org`: under `HOME/org/` at any depth, a file whose name (case folded)
/// starts with one of these, or a file under a directory so named. Data: an answer to question 5 changes only this.
pub const HARD_PATTERNS: &[&str] = &["notes", "journal", "diary", "personal"];

/// Which tier denied a path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tier {
    /// Never lifted.
    Hard,
    /// Lifted per file by an opt-in.
    Soft,
}

/// A path's verdict.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    Allowed,
    /// Exactly `HOME/org/board.org`.
    Board,
    /// A soft-tier file the user opted in.
    OptedIn,
    Denied {
        why: String,
        tier: Tier,
    },
}

/// A project root's verdict (door 3, the indexers).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RootVerdict {
    Allowed,
    /// The root lies inside the denied root.
    Denied {
        why: String,
    },
    /// The root contains denied paths (e.g. `HOME` itself): the indexer skips them.
    Contains {
        denied: Vec<PathBuf>,
    },
}

/// Where a record came from: put-parsed's typed source, or schema 6's source strings (`"spec /path"`, a path,
/// `"commit"`, `"branch"`, `"recorded"`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    File(PathBuf),
    Spec(PathBuf),
    Commit,
    Branch,
    Recorded,
}

impl Source {
    /// Schema 6's source string; `None` for a form that is none of the known ones (a door denies it: "unknown source
    /// form", never a relative path).
    pub fn parse(s: &str) -> Option<Source> {
        todo!("Task 9")
    }
}

/// The deny-list as loaded; no setter.
#[derive(Debug)]
pub struct DenyList {
    org: PathBuf,
    board: PathBuf,
    opt_ins: Vec<PathBuf>,
    warnings: Vec<String>,
}

impl DenyList {
    /// The list for HOME, with the opt-ins of `CONFIG_DIR/personal-notes-allow.json` (missing: none; unreadable,
    /// malformed or group/other-writable: none, with a warning; an entry that is not a regular file under the
    /// denied root: ignored, with a warning).
    pub fn load(home: &Path, config_dir: &Path) -> DenyList {
        todo!("Task 9")
    }

    /// PATH's verdict, resolved first (`..`, `//`, links); the hard tier before the opt-ins.
    pub fn check(&self, path: &Path) -> Verdict {
        todo!("Task 9")
    }

    /// A project root's verdict.
    pub fn check_root(&self, root: &Path) -> RootVerdict {
        todo!("Task 9")
    }

    /// The opt-ins kept, canonical.
    pub fn opt_ins(&self) -> &[PathBuf] {
        &self.opt_ins
    }

    /// What the doctor shows (ignored entries, an unsafe file).
    pub fn warnings(&self) -> &[String] {
        &self.warnings
    }
}

/// Every path a record carries: SOURCE's path, the path inside a path-form ID (`spec:/…`, `plan:/…`, `task:/…#n`,
/// `step:/…`, `ruling:/…`, `todo:/…`, `file:/…`), and `DATA.path`.
pub fn paths_of(source: &Source, id: &str, data: &Value) -> Vec<PathBuf> {
    todo!("Task 9")
}
