//! When tier 1 runs: the settle core over watch events, and the bounded diff of blobs for a project with no watches.
//!
//! [`Settle`] is pure: the shell feeds it what the watcher saw and the time, and it says when a refresh is due. A
//! change under the gitdir (a checkout, a commit, a reset) is due once `index.lock` is gone and the gitdir has been
//! quiet for the period, so a branch switch of 2,000 files is one refresh after git is done, not 2,000. A save is
//! due once that file has been quiet for the debounce.

use crate::index::known_blobs;
use crate::{CodeStore, Listed, StoreError};
use std::collections::{BTreeMap, HashSet};
use std::time::Duration;

/// What the shell feeds the core.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Fresh {
    /// A change under the gitdir: `HEAD`, the index or a ref.
    Git,
    /// A file of the tree was written (its path relative to the root).
    Save(String),
    /// `index.lock` appeared (true) or went (false).
    Lock(bool),
    /// The clock reads this (time since the shell started); it never goes back.
    At(Duration),
}

/// A refresh to run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Due {
    /// Everything: git moved.
    All,
    /// These saved files.
    Files(Vec<String>),
}

#[derive(Clone, Debug)]
pub struct Settle {
    quiet: Duration,
    debounce: Duration,
    now: Duration,
    git: Option<Duration>,
    locked: bool,
    saves: BTreeMap<String, Duration>,
}

impl Settle {
    /// QUIET after the last gitdir change (2 s in the hub), DEBOUNCE after a file's last save (30 s).
    pub fn new(quiet: Duration, debounce: Duration) -> Settle {
        Settle {
            quiet,
            debounce,
            now: Duration::ZERO,
            git: None,
            locked: false,
            saves: BTreeMap::new(),
        }
    }

    /// One event; the refresh it makes due, if any.
    pub fn feed(&mut self, ev: Fresh) -> Option<Due> {
        match ev {
            Fresh::Git => self.git = Some(self.now),
            Fresh::Save(path) => {
                self.saves.insert(path, self.now);
            }
            Fresh::Lock(on) => self.locked = on,
            Fresh::At(t) => self.now = self.now.max(t),
        }
        self.due()
    }

    fn due(&mut self) -> Option<Due> {
        if let Some(at) = self.git {
            if !self.locked && self.now >= at + self.quiet {
                self.git = None;
                self.saves.clear();
                return Some(Due::All);
            }
            return None;
        }
        let ready: Vec<String> = self
            .saves
            .iter()
            .filter(|(_, at)| self.now >= **at + self.debounce)
            .map(|(p, _)| p.clone())
            .collect();
        if ready.is_empty() {
            return None;
        }
        for p in &ready {
            self.saves.remove(p);
        }
        Some(Due::Files(ready))
    }

    /// When a refresh can next fall due, if the shell feeds the time then; none while nothing is pending (or only a
    /// git change under the lock, which waits for the lock's event).
    pub fn deadline(&self) -> Option<Duration> {
        if let Some(at) = self.git {
            return (!self.locked).then_some(at + self.quiet);
        }
        self.saves.values().map(|at| *at + self.debounce).min()
    }
}

/// What differs between the store and a fresh listing.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Diff {
    /// Listed files whose blob is new or changed.
    pub changed: Vec<String>,
    /// Indexed files no longer listed.
    pub gone: Vec<String>,
    /// More than the limit differ: the lists hold the first ones, and the caller refreshes everything.
    pub capped: bool,
}

impl Diff {
    pub fn is_empty(&self) -> bool {
        self.changed.is_empty() && self.gone.is_empty() && !self.capped
    }
}

/// The store's blobs against LISTED, with at most LIMIT differences named: the freshness check of a project that has
/// no watches, run at query time.
pub async fn diff(store: &CodeStore, listed: &[Listed], limit: usize) -> Result<Diff, StoreError> {
    let known = store.handle().read(known_blobs).await?;
    let names: HashSet<&str> = listed.iter().map(|l| l.path.as_str()).collect();
    let mut d = Diff::default();
    let changed: Vec<String> = listed
        .iter()
        .filter(|l| known.get(&l.path) != Some(&l.blob))
        .map(|l| l.path.clone())
        .collect();
    let mut gone: Vec<String> = known
        .into_keys()
        .filter(|p| !names.contains(p.as_str()))
        .collect();
    gone.sort();
    let all = changed
        .into_iter()
        .map(|p| (true, p))
        .chain(gone.into_iter().map(|p| (false, p)));
    for (i, (is_listed, p)) in all.enumerate() {
        if i >= limit {
            d.capped = true;
            break;
        }
        if is_listed {
            d.changed.push(p);
        } else {
            d.gone.push(p);
        }
    }
    Ok(d)
}
