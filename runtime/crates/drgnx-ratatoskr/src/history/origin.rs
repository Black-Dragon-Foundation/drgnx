//! Whose version a change of a file is (pure): the hub's own write, the watcher's event about it and a rescan are one
//! version, the hub's; a change another program made is its own, outside.
//!
//! The hub registers a write before the file is written (`expect_write`), so the watcher's event and a rescan about it
//! find it known.  The core remembers, per path, the hashes the hub wrote since the last outside change: an event
//! naming one of them, or the version already recorded, is that same version.

use std::collections::{BTreeMap, BTreeSet};

/// What the core is told: a content hash of a path from one source.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OriginEv {
    /// The hub is writing PATH with content HASH.
    HubWrite { path: String, hash: String },
    /// The watcher saw PATH change; the content now has HASH.
    Watch { path: String, hash: String },
    /// A step-boundary rescan read PATH with content HASH.
    Rescan { path: String, hash: String },
}

/// Who made a version.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Owner {
    Hub,
    Outside,
}

/// A version to record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Version {
    pub path: String,
    pub hash: String,
    pub owner: Owner,
}

#[derive(Debug, Default)]
pub struct OriginCore {
    /// Per path, the hashes the hub wrote since the last outside change.
    hub: BTreeMap<String, BTreeSet<String>>,
    /// Per path, the hash of the version recorded last.
    last: BTreeMap<String, String>,
}

impl OriginCore {
    /// The paths the core knows a version of.
    pub fn paths(&self) -> impl Iterator<Item = &String> {
        self.last.keys()
    }

    /// The hash of PATH's last recorded version.
    pub fn last(&self, path: &str) -> Option<&str> {
        self.last.get(path).map(String::as_str)
    }

    /// Seed PATH's last version (a document first read from disk): later events about that content are no change.
    pub fn known(&mut self, path: &str, hash: &str) {
        self.last.insert(path.to_owned(), hash.to_owned());
    }

    /// The version EV is, if it is a new one.
    pub fn step(&mut self, ev: OriginEv) -> Option<Version> {
        match ev {
            OriginEv::HubWrite { path, hash } => {
                self.hub
                    .entry(path.clone())
                    .or_default()
                    .insert(hash.clone());
                if self.last.get(&path) == Some(&hash) {
                    return None;
                }
                self.last.insert(path.clone(), hash.clone());
                Some(Version {
                    path,
                    hash,
                    owner: Owner::Hub,
                })
            }
            OriginEv::Watch { path, hash } | OriginEv::Rescan { path, hash } => {
                if self.last.get(&path) == Some(&hash)
                    || self.hub.get(&path).is_some_and(|s| s.contains(&hash))
                {
                    return None;
                }
                self.hub.remove(&path);
                self.last.insert(path.clone(), hash.clone());
                Some(Version {
                    path,
                    hash,
                    owner: Owner::Outside,
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use skuld::{Bound, Partial, every_order};

    skuld::events!(OriginEv {
        HubWrite,
        Watch,
        Rescan
    });

    fn hub(path: &str, hash: &str) -> OriginEv {
        OriginEv::HubWrite {
            path: path.into(),
            hash: hash.into(),
        }
    }
    fn watch(path: &str, hash: &str) -> OriginEv {
        OriginEv::Watch {
            path: path.into(),
            hash: hash.into(),
        }
    }
    fn rescan(path: &str, hash: &str) -> OriginEv {
        OriginEv::Rescan {
            path: path.into(),
            hash: hash.into(),
        }
    }
    fn version(path: &str, hash: &str, owner: Owner) -> Version {
        Version {
            path: path.into(),
            hash: hash.into(),
            owner,
        }
    }

    #[derive(Default)]
    struct Harness {
        core: OriginCore,
        versions: Vec<Version>,
    }

    impl skuld::Core for Harness {
        type Event = OriginEv;
        fn step(&mut self, ev: OriginEv) -> Vec<OriginEv> {
            self.versions.extend(self.core.step(ev));
            Vec::new()
        }
    }

    fn run(p: &Partial<OriginEv>, want: Vec<Version>, at_least: u64) {
        let r = every_order(p, Bound::default(), Harness::default, |h, _| {
            let mut got = h.versions.clone();
            got.sort_by(|a, b| a.hash.cmp(&b.hash));
            if got != want {
                return Err(format!("versions {:?}", h.versions));
            }
            Ok(())
        });
        assert!(r.orders >= at_least, "{} orders", r.orders);
    }

    /// Pattern A. The hub's write is registered before the file is written, so its own watcher event and a rescan,
    /// in either order and after other paths' events, are the same version, and it is the hub's.
    #[test]
    fn every_order_a_hub_write_is_recorded_once() {
        let mut p = Partial::new();
        let hubs = p.source("hub", vec![hub("a", "h1")]);
        let watcher = p.source("watch", vec![watch("a", "h1")]);
        let rescans = p.source("rescan", vec![rescan("a", "h1")]);
        p.source("other", vec![hub("b", "h9"), watch("b", "h9")]);
        p.before((hubs, 0), (watcher, 0));
        p.before((hubs, 0), (rescans, 0));
        run(
            &p,
            vec![
                version("a", "h1", Owner::Hub),
                version("b", "h9", Owner::Hub),
            ],
            6,
        );
    }

    /// Pattern A. A change another program made after the hub's write is its own version, whichever of the
    /// watcher's and the rescan's events about the hub's write arrive around it.
    #[test]
    fn every_order_an_outside_change_after_a_hub_write_is_its_own_version() {
        let mut p = Partial::new();
        let hubs = p.source("hub", vec![hub("a", "h1")]);
        let disk = p.source("disk", vec![watch("a", "h1"), watch("a", "h2")]);
        let rescans = p.source("rescan", vec![rescan("a", "h2")]);
        p.before((hubs, 0), (disk, 0));
        p.before((disk, 1), (rescans, 0));
        run(
            &p,
            vec![
                version("a", "h1", Owner::Hub),
                version("a", "h2", Owner::Outside),
            ],
            1,
        );
    }

    /// Pattern A. With no hub write, the watcher's event and the rescan about one change agree: one version.
    #[test]
    fn every_order_a_rescan_and_a_late_watch_event_agree() {
        let mut p = Partial::new();
        p.source("watch", vec![watch("a", "h1")]);
        p.source("rescan", vec![rescan("a", "h1")]);
        // another path the hub wrote, so every kind of event is in the run
        p.source("hub", vec![hub("z", "hz")]);
        run(
            &p,
            vec![
                version("a", "h1", Owner::Outside),
                version("z", "hz", Owner::Hub),
            ],
            2,
        );
    }
}
