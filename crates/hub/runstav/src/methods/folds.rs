//! Folds and pins remembered (the minimap and folding design, F7 and X5; docs/develop/hub.md, "Folds remembered"): the
//! editor sends a file's folds and pinned regions on kill, save and an idle 30 s after a fold changes (`folds/save`),
//! and asks for them when the file opens (`folds/load`).  The hub keeps them as Urdr records of kind `anchor`, one a
//! fold or pin, per (worktree, path).  Lines count from 1; the editor matches a record to its text again by kind and
//! the hash of its first line's trimmed text, within ±50 lines.

use super::{invalid, method};
use crate::registry::Method;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// The most anchors one file keeps (the editor's `drgnx-fold-max`).
pub const ANCHORS_MAX: usize = 20_000;
/// The longest worktree or path, in bytes.
pub const PATH_MAX: usize = 4096;
/// The longest hash, name or fold kind, in bytes.
pub const TEXT_MAX: usize = 256;

/// What an anchor is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum AnchorKind {
    /// A folded range, or a manual fold (`fold_kind` "manual").
    Fold,
    /// A pinned region (X5).
    Pin,
}

/// One fold or pin: its kind, its first and last line (from 1), the hash of its first line's trimmed text, its name,
/// and a fold's kind (`function`, `class`, …, or `manual` for a fold made from a selection).  OPEN: a manual fold kept
/// unfolded.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Anchor {
    pub kind: AnchorKind,
    pub start: u32,
    pub end: u32,
    pub hash: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fold_kind: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub open: bool,
}

/// `folds/save`: the folds and pins of PATH (relative) in WORKTREE (absolute) are ANCHORS now (none: forget them).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FoldsSave {
    pub worktree: String,
    pub path: String,
    #[serde(default)]
    pub anchors: Vec<Anchor>,
}

/// `folds/load`: the folds and pins kept for PATH in WORKTREE.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FoldsLoad {
    pub worktree: String,
    pub path: String,
}

/// The answer of `folds/load`, in the order they were saved.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FoldsLoaded {
    pub anchors: Vec<Anchor>,
}

fn check_file(worktree: &str, path: &str) -> Result<(), Error> {
    if worktree.is_empty() || worktree.len() > PATH_MAX || !worktree.starts_with('/') {
        return Err(invalid(
            "worktree",
            "an absolute folder name of at most 4096 bytes",
        ));
    }
    if path.is_empty() || path.len() > PATH_MAX || path.starts_with('/') {
        return Err(invalid(
            "path",
            "a file name relative to worktree, at most 4096 bytes",
        ));
    }
    Ok(())
}

fn check_save(p: &FoldsSave) -> Result<(), Error> {
    check_file(&p.worktree, &p.path)?;
    if p.anchors.len() > ANCHORS_MAX {
        return Err(invalid("anchors", "at most 20000 anchors"));
    }
    for (i, a) in p.anchors.iter().enumerate() {
        let long = |s: &Option<String>| s.as_ref().is_some_and(|s| s.len() > TEXT_MAX);
        if a.start == 0 || a.end < a.start {
            return Err(invalid(
                &format!("anchors.{i}"),
                "lines from 1, the end at or after the start",
            ));
        }
        if a.hash.is_empty() || a.hash.len() > TEXT_MAX || long(&a.name) || long(&a.fold_kind) {
            return Err(invalid(
                &format!("anchors.{i}"),
                "a hash, name and fold kind of at most 256 bytes",
            ));
        }
    }
    Ok(())
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "folds/save", FoldsSave(FoldsSave) -> bool,
            classes: [User], writes: true,
            doc: "Emacs-era, re-decide at B1: a file's folds and pinned regions now (sent on kill, save and an idle 30 s after a fold changes): kept as Urdr anchor records per worktree and path, replacing the file's last ones; true when they changed",
            check: check_save,
        ),
        method!(
            "folds/load", FoldsLoad(FoldsLoad) -> FoldsLoaded,
            classes: [User], writes: false,
            doc: "Emacs-era, re-decide at B1: the folds and pinned regions kept for a file (asked when it opens): the editor matches each to its text by kind and first-line hash within 50 lines",
            check: |p: &FoldsLoad| check_file(&p.worktree, &p.path),
        ),
    ]
}
