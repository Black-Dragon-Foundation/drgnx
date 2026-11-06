//! The history's timers, on the hub's clock (`crate::clock`): typing settles into records after 30 s without a change,
//! and a document nobody used for 5 minutes is parked (its snapshot stored, the document dropped from memory).  Under
//! `--test-clock` an advance decides when each fires.

use super::Hub;
use std::sync::Arc;
use std::time::Duration;

/// How often settled typing is looked for.
const SETTLE_EVERY: Duration = Duration::from_secs(5);
/// How often idle documents are looked for.
const PARK_EVERY: Duration = Duration::from_secs(60);
/// A document unused this long is parked.
const IDLE_SECS: f64 = 300.0;

impl Hub {
    /// The records of typing quiet for 30 s at NOW.
    pub fn settle_due(&self, now: f64) -> verdandi::Result<usize> {
        let mut g = self.lock();
        let inner = &mut *g;
        Ok(inner.settler.settle_due(&mut inner.h, now)?.len())
    }

    /// Park the documents unused for 5 minutes at NOW.
    pub fn park_idle(&self, now: f64) -> verdandi::Result<usize> {
        Ok(self.lock().h.park_idle(IDLE_SECS, now)?.len())
    }

    /// Start the settle and idle timers.  They hold the hub weakly and end with it.
    pub fn start_timers(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        crate::clock::spawn("history:settle", {
            let weak = weak.clone();
            async move {
                loop {
                    crate::clock::sleep(SETTLE_EVERY).await;
                    let Some(hub) = weak.upgrade() else { return };
                    // read here: a blocking thread does not carry the virtual clock
                    let now = crate::clock::wall_secs();
                    let _ = crate::clock::blocking(move || hub.settle_due(now)).await;
                }
            }
        });
        crate::clock::spawn("history:park", async move {
            loop {
                crate::clock::sleep(PARK_EVERY).await;
                let Some(hub) = weak.upgrade() else { return };
                let now = crate::clock::wall_secs();
                let _ = crate::clock::blocking(move || hub.park_idle(now)).await;
            }
        });
    }
}

#[cfg(all(test, feature = "test-hooks"))]
mod tests {
    use super::super::{BatchChange, Tree, methods::hash};
    use super::*;
    use crate::clock::{advance, on_virtual};
    use norn::deny::DenyList;

    /// A hub with one tracked buffer `b1` of a.txt in a real repository, and a batch applied to it at the hub's now.
    fn typed() -> (Arc<Hub>, tempfile::TempDir, tempfile::TempDir) {
        let repo = tempfile::tempdir().unwrap();
        let git = |args: &[&str]| {
            assert!(
                std::process::Command::new("git")
                    .args(["-c", "user.name=t", "-c", "user.email=t@t"])
                    .args(args)
                    .current_dir(repo.path())
                    .env("GIT_CONFIG_GLOBAL", "/dev/null")
                    .status()
                    .unwrap()
                    .success()
            )
        };
        git(&["init", "-q", "-b", "main"]);
        std::fs::write(repo.path().join("a.txt"), "one\n").unwrap();
        git(&["add", "."]);
        git(&["commit", "-q", "-m", "base"]);
        let hist = tempfile::tempdir().unwrap();
        let hub = Arc::new(Hub::open(hist.path()).unwrap());
        let tree = Tree::new(repo.path(), &repo.path().join(".git"), None);
        let cfg = repo.path().join(".cfg-none");
        std::fs::create_dir_all(&cfg).unwrap();
        let deny = DenyList::load(&cfg, &cfg);
        hub.register(&tree, "a.txt", "b1", &deny).unwrap();
        let change = BatchChange {
            // the tree has no base commit: the document starts empty
            start: 0,
            old_len: 0,
            inserted: "one\n".into(),
            origin: "user".into(),
        };
        let now = crate::clock::wall_secs();
        let reply = hub.batch("b1", &[change], &hash("one\n"), now).unwrap();
        assert_eq!(reply, crate::history::BatchReply::Ok);
        (hub, repo, hist)
    }

    fn ops(hub: &Hub) -> i64 {
        hub.with(|h| h.count("op").unwrap())
    }

    // pattern: B (the hub's clock moved by advance)
    #[test]
    fn typing_settles_into_a_record_after_thirty_seconds() {
        on_virtual(async {
            let (hub, _repo, _hist) = typed();
            hub.start_timers();
            advance(Duration::ZERO).await;
            advance(Duration::from_secs(29)).await;
            assert_eq!(ops(&hub), 0, "settled early");
            advance(Duration::from_secs(11)).await;
            // the tick writes on a blocking thread: wait for the record it announces
            skuld::wait_until("the settled record", 30, || (ops(&hub) == 1).then_some(()));
            // quiet again: nothing more is written
            advance(Duration::from_secs(60)).await;
            assert_eq!(ops(&hub), 1);
        });
    }

    // pattern: B
    #[test]
    fn a_document_idle_for_five_minutes_is_parked() {
        on_virtual(async {
            let (hub, _repo, _hist) = typed();
            hub.start_timers();
            advance(Duration::ZERO).await;
            advance(Duration::from_secs(240)).await;
            assert_eq!(hub.with(|h| h.active_docs().len()), 1, "parked early");
            advance(Duration::from_secs(180)).await;
            skuld::wait_until("the idle document parked", 30, || {
                hub.with(|h| h.active_docs().is_empty()).then_some(())
            });
        });
    }
}
