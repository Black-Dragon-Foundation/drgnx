//! A run's git scope (Changed, Staged, Branch): its files, found on the search's thread (never on `search/run`'s
//! path), what the run's end says of them, and with "changed lines only" (`±`) each file's added lines, which keep a
//! match.

use crate::search::scope::{self, Added, ScopeError};
use hrafn::grep::Match;
use runstav::methods::search::{ScopeDone, ScopeKind};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Each file's lines that keep a match (`±`).
pub(super) type Keep = HashMap<PathBuf, Added>;

/// A git scope as `search/run` asked for it.
#[derive(Clone, Debug)]
pub(super) struct GitScope {
    pub kind: ScopeKind,
    pub base: Option<String>,
    pub changed_lines: bool,
}

/// A git scope's files under the run's root, what the run's end says of them, and with `±` the lines that keep a
/// match (keyed as the files are).
#[derive(Debug, Default)]
pub(super) struct Scoped {
    pub files: Vec<PathBuf>,
    pub done: ScopeDone,
    pub keep: Option<Keep>,
}

/// ROOT's files in scope G; or what the run's end says when it has none to search, and why.
/// The files outside ROOT (the repository's top level may be above it) are not searched; the paths are ROOT's
/// spelling, as the searchers name the matches.
pub(super) fn find(root: &Path, g: &GitScope) -> Result<Scoped, (ScopeDone, String)> {
    let list = scope::files(root, g.kind, g.base.as_deref()).map_err(|e| {
        let done = ScopeDone {
            needs_base: matches!(e, ScopeError::NeedsBase(_)).then(|| e.to_string()),
            ..ScopeDone::default()
        };
        (done, e.to_string())
    })?;
    let keep = if g.changed_lines {
        Some(scope::added_lines(&list, g.kind).map_err(|e| (ScopeDone::default(), e.to_string()))?)
    } else {
        None
    };
    // git names files under its canonical top level
    let real = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let ours = |f: &Path| f.strip_prefix(&real).ok().map(|rel| root.join(rel));
    let files: Vec<PathBuf> = list.files.iter().filter_map(|f| ours(f)).collect();
    let keep = keep.map(|k| {
        k.into_iter()
            .filter_map(|(f, a)| Some((ours(&f)?, a)))
            .collect()
    });
    let done = ScopeDone {
        files: files.len() as u64,
        submodules: list.submodules as u64,
        deleted: list.deleted as u64,
        why_empty: list.why_empty.or_else(|| {
            files
                .is_empty()
                .then(|| "its changes are outside this folder".to_owned())
        }),
        base: list.base,
        needs_base: None,
    };
    Ok(Scoped { files, done, keep })
}

/// FILE's matches MS that KEEP's lines keep (all of them without `±`).
pub(super) fn kept(keep: Option<&Keep>, file: &str, ms: &mut Vec<Match>) {
    let Some(keep) = keep else { return };
    match keep.get(Path::new(file)) {
        Some(a) => ms.retain(|m| a.keeps(m.line, m.line)),
        None => ms.clear(),
    }
}
