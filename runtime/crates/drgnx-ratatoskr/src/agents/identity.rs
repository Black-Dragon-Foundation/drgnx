//! Who an agent is on screen (`docs/develop/hub.md`, "Identity"; agents-in-the-editor design §4.2): the hub gives
//! each live session an **ordinal** (1, 2, 3 … in its workspace, the lowest free one at its start, kept for its life)
//! and a **handle** unique there: the model's short name, with a number from the second agent of that model on
//! ("Opus", "Opus 2", "Sonnet"), and a short **monogram** for badges ("O", "O2"). Each display maps the ordinal to a
//! colour and a mark itself (the walk, and reuse past its capacity, are the display's: the hub never hands out a live
//! ordinal twice). A subagent (`agent:SID/TOOLID`) takes its own, freed with its parent.
//!
//! A workspace here is a repository (the git common directory's project id of the session's folder), else the folder:
//! the agents a buffer can show are the ones of its repository.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Mutex, MutexGuard, PoisonError};

/// One live session's identity.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub ordinal: u32,
    pub handle: String,
    pub monogram: String,
}

#[derive(Clone, Debug)]
struct Held {
    workspace: String,
    model: String,
    /// Its number among the workspace's agents of that model (1: no number in the handle).
    n: u32,
    id: Identity,
}

/// The identities held now, by session.
#[derive(Default)]
pub struct Pool {
    held: Mutex<BTreeMap<String, Held>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The lowest number from 1 that USED does not hold.
fn lowest_free(used: impl Iterator<Item = u32>) -> u32 {
    let mut used: Vec<u32> = used.collect();
    used.sort_unstable();
    let mut n = 1;
    for u in used {
        if u == n {
            n += 1;
        } else if u > n {
            break;
        }
    }
    n
}

impl Pool {
    /// SESSION's identity in WORKSPACE as an agent of MODEL_SHORT: the one it holds, else the lowest free ordinal and
    /// the lowest free number of that model.
    pub fn take(&self, workspace: &str, session: &str, model_short: &str) -> Identity {
        let mut held = lock(&self.held);
        if let Some(h) = held.get(session) {
            return h.id.clone();
        }
        let mine = || held.values().filter(|h| h.workspace == workspace);
        let ordinal = lowest_free(mine().map(|h| h.id.ordinal));
        let n = lowest_free(mine().filter(|h| h.model == model_short).map(|h| h.n));
        let initial: String = model_short
            .chars()
            .next()
            .map_or_else(|| "A".to_string(), |c| c.to_uppercase().collect());
        let (handle, monogram) = if n == 1 {
            (model_short.to_string(), initial)
        } else {
            (format!("{model_short} {n}"), format!("{initial}{n}"))
        };
        let id = Identity {
            ordinal,
            handle,
            monogram,
        };
        held.insert(
            session.to_string(),
            Held {
                workspace: workspace.to_string(),
                model: model_short.to_string(),
                n,
                id: id.clone(),
            },
        );
        id
    }

    /// SESSION's identity, if it holds one.
    pub fn get(&self, session: &str) -> Option<Identity> {
        lock(&self.held).get(session).map(|h| h.id.clone())
    }

    /// SESSION ended: its identity is free, and its subagents' (`agent:SESSION/…`).
    pub fn free(&self, session: &str) {
        let kids = format!("agent:{session}/");
        lock(&self.held).retain(|s, _| s != session && !s.starts_with(&kids));
    }
}

/// The workspace a session in DIR counts its identities in: its git checkout's project id (the same for every
/// worktree of one repository), else DIR itself. Reads the `.git` entries only.
pub fn workspace_of(dir: &Path) -> String {
    crate::work::presence::checkout_of(&dir.join(".git"))
        .map_or_else(|| dir.to_string_lossy().into_owned(), |(_, id)| id)
}

/// The short name an agent of MODEL (the profile's `:model`), else of PROVIDER, goes by: Claude's families by their
/// name ("Opus", "Sonnet", "Haiku"), another model by the first word of its name ("deepseek-chat" → "Deepseek"), else
/// the provider ("Claude", "Codex", "Gemini"), else "Agent".
pub fn model_short(model: Option<&str>, provider: Option<&str>) -> String {
    let cap = |w: &str| {
        let mut c = w.chars();
        c.next().map_or_else(String::new, |f| {
            f.to_uppercase()
                .chain(c.flat_map(char::to_lowercase))
                .collect()
        })
    };
    if let Some(m) = model.map(str::trim).filter(|m| !m.is_empty()) {
        let lower = m.to_lowercase();
        for family in ["opus", "sonnet", "haiku"] {
            if lower.contains(family) {
                return cap(family);
            }
        }
        let name = m.rsplit('/').next().unwrap_or(m);
        let word = name.split(['-', '_', ' ', ':', '.']).next().unwrap_or(name);
        if word.chars().any(char::is_alphabetic) {
            return cap(word);
        }
    }
    provider
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map_or_else(|| "Agent".to_string(), cap)
}

#[cfg(test)]
mod tests;
