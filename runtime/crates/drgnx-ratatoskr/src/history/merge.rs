//! Merges (`docs/develop/history.md`, "Merges"): once git has merged a task's branch into the job's tree, the history
//! unions the two worktrees' documents ([`verdandi::History::record_merge`]), so the agent's text keeps its element ids
//! (and the anchors on it) where git agrees with the union, and a file git resolved otherwise gets one correction.
//! The merged texts are read from the merge commit in the target's repository, after git and its hooks ran; nothing
//! runs git in the task's tree.

use super::wire::{Hubs, git_dirs};
use super::{Hub, Tree, blob};
use serde_json::json;
use std::collections::HashMap;
use std::path::Path;
use verdandi::text::{Coding, canonical};
use verdandi::{OpId, Result};

impl Hub {
    /// Git merged SOURCE's branch into TARGET, whose HEAD moved from OLD to NEW: one `merge` record of the union of
    /// their documents, with git's text of every file the merge changed (SOURCE none: its history is not this
    /// project's, and only git's result is recorded).  Then whatever TARGET's files hold beyond the union is the git
    /// event's own `external` record (a file neither branch had a document of, a deletion).  The merge record's id.
    pub fn on_git_merge(
        &self,
        target: &Tree,
        source: Option<&Tree>,
        old: &str,
        new: &str,
        now: f64,
    ) -> Result<Option<OpId>> {
        let paths = blob::changed_paths(&target.git_dir, &target.root, old, new)
            .map_err(verdandi::Error::Refused)?;
        let mut merged = HashMap::new();
        for rel in paths {
            if rel.starts_with(".git/") || super::capture::is_secret(&rel) {
                continue;
            }
            if let Some(b) = blob::text_at(&target.git_dir, &target.root, new, &rel)
                && let Ok(t) = canonical(&b, Coding::detect(&b))
            {
                merged.insert(rel, t);
            }
        }
        let op = match source {
            Some(src) => {
                let mut g = self.lock();
                let (to, from) = (g.branch(target)?, g.branch(src)?);
                let author = g.peer(
                    to,
                    "external:git-merge",
                    &json!({"kind": "external", "source": "git", "reason": "merge"}),
                )?;
                Some(g.h.record_merge(to, from, &merged, author, now)?)
            }
            None => None,
        };
        self.on_git_event(target, old, new, "merge", now)?;
        Ok(op)
    }
}

/// The merge git just made in TARGET (a job's tree) of SOURCE's branch (a task's tree), its HEAD then OLD, recorded in
/// the project's history under the state folder STATE: the union when both trees are one project's, else git's result
/// alone.  Best effort: a failure is logged, never the merge's.
pub(crate) async fn record(
    hubs: &Hubs,
    state: &Path,
    target: &Path,
    source: &Path,
    old: Option<String>,
) {
    let Some(old) = old else { return };
    let (t, s) = (target.to_path_buf(), source.to_path_buf());
    let new = crate::clock::blocking(move || crate::timeline::snapshot::head_of(&t))
        .await
        .ok()
        .flatten();
    let Some(new) = new.filter(|n| *n != old) else {
        return;
    };
    let (hub, to) = match hubs.of_tree(state, target) {
        Ok(x) => x,
        Err(e) => {
            tracing::info!(target = %target.display(), "the merge is not recorded: {}", e.message);
            return;
        }
    };
    let common = |p: &Path| git_dirs(p).map(|(_, c)| c);
    let from = match (common(target), common(&s)) {
        (Some(a), Some(b)) if a == b => hubs.of_tree(state, &s).ok().map(|(_, t)| t),
        _ => None,
    };
    let now = crate::clock::wall_secs();
    let r =
        crate::clock::blocking(move || hub.on_git_merge(&to, from.as_ref(), &old, &new, now)).await;
    match r {
        Ok(Ok(_)) => {}
        Ok(Err(e)) => tracing::warn!(target = %target.display(), "the merge is not recorded: {e}"),
        Err(e) => tracing::warn!(target = %target.display(), "the merge is not recorded: {e}"),
    }
}

#[cfg(test)]
mod tests;
