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
/// The first sweep comes this long after the hub opens the history, the next ones every [`SWEEP_EVERY`].
const SWEEP_FIRST: Duration = Duration::from_secs(60);
const SWEEP_EVERY: Duration = Duration::from_secs(6 * 3600);
/// How many of the biggest pins the report names.
const PINS_SHOWN: usize = 8;
/// The file the sweep leaves beside `history.db` for the doctor, which never opens the live database.
pub const REPORT: &str = "size-report.json";

/// What one sweep did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Swept {
    /// Set-aside branches removed (older than 90 days, not pinned).
    pub expired: usize,
    /// The compaction, when the history was over the cap.
    pub compacted: Option<verdandi::Compacted>,
}

fn pin_kind(k: verdandi::PinKind) -> &'static str {
    match k {
        verdandi::PinKind::Pinned => "pinned",
        verdandi::PinKind::Undone => "undone",
        verdandi::PinKind::Frozen => "frozen",
        verdandi::PinKind::Anchors => "anchors",
    }
}

impl Hub {
    /// Expire what is 90 days old at NOW, compact when the history is over CAP, and leave the doctor's report
    /// (`size-report.json`: size, cap, and the biggest things that pin it) beside `history.db`.
    pub fn sweep(&self, now: f64, cap: u64) -> verdandi::Result<Swept> {
        let mut g = self.lock();
        let expired = g.h.expire(now)?.len();
        let compacted = if g.h.size()? > cap {
            let author = g.h.peer(
                &serde_json::json!({"kind": "system", "name": "compaction"}),
                None,
            )?;
            Some(g.h.compact(cap, author, now)?)
        } else {
            None
        };
        let pins: Vec<_> = g
            .h
            .pins()?
            .into_iter()
            .take(PINS_SHOWN)
            .map(
                |p| serde_json::json!({"kind": pin_kind(p.kind), "name": p.name, "bytes": p.bytes}),
            )
            .collect();
        let report = serde_json::json!({"size": g.h.size()?, "cap": cap, "at": now, "pins": pins});
        // a copy of the report that cannot be written is no reason to fail the sweep: the doctor says it is missing
        let tmp = self.dir.join(format!("{REPORT}.tmp"));
        if std::fs::write(&tmp, report.to_string()).is_ok() {
            let _ = std::fs::rename(&tmp, self.dir.join(REPORT));
        }
        Ok(Swept { expired, compacted })
    }

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
        crate::clock::spawn("history:park", {
            let weak = weak.clone();
            async move {
                loop {
                    crate::clock::sleep(PARK_EVERY).await;
                    let Some(hub) = weak.upgrade() else { return };
                    let now = crate::clock::wall_secs();
                    let _ = crate::clock::blocking(move || hub.park_idle(now)).await;
                }
            }
        });
        crate::clock::spawn("history:sweep", async move {
            let mut wait = SWEEP_FIRST;
            loop {
                crate::clock::sleep(wait).await;
                wait = SWEEP_EVERY;
                let Some(hub) = weak.upgrade() else { return };
                let now = crate::clock::wall_secs();
                let _ =
                    crate::clock::blocking(move || hub.sweep(now, verdandi::compact::DEFAULT_CAP))
                        .await;
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

    // pattern: D (now is a parameter)
    #[test]
    fn a_sweep_expires_a_set_aside_branch_after_ninety_days() {
        let (hub, _repo, _hist) = typed();
        let now = crate::clock::wall_secs();
        let fork = hub.with(|h| {
            let b = h
                .branch("fork-aaaa", verdandi::BranchKind::Fork, None)
                .unwrap();
            h.freeze(b, now).unwrap();
            b
        });
        let branches = |hub: &Hub| hub.with(|h| h.count("branch").unwrap());
        assert_eq!(branches(&hub), 2);
        let early = hub
            .sweep(now + 89.0 * 86_400.0, verdandi::compact::DEFAULT_CAP)
            .unwrap();
        assert_eq!((early.expired, branches(&hub)), (0, 2), "{fork:?}");
        let late = hub
            .sweep(now + 91.0 * 86_400.0, verdandi::compact::DEFAULT_CAP)
            .unwrap();
        assert_eq!((late.expired, branches(&hub)), (1, 1));
        assert!(late.compacted.is_none(), "under the cap nothing is cut");
    }

    // pattern: D
    #[test]
    fn a_sweep_over_the_cap_compacts_and_leaves_a_report() {
        let (hub, _repo, hist) = typed();
        let now = crate::clock::wall_secs();
        hub.settle_due(now + 40.0).unwrap();
        let swept = hub.sweep(now + 50.0, 0).unwrap();
        assert!(swept.compacted.is_some(), "{swept:?}");
        let report: serde_json::Value =
            serde_json::from_slice(&std::fs::read(hist.path().join("size-report.json")).unwrap())
                .unwrap();
        assert_eq!(report["cap"], 0);
        assert!(report["size"].as_u64().unwrap() > 0, "{report}");
        assert!(report["pins"].is_array(), "{report}");
    }

    // pattern: B (the hub's clock moved by advance)
    #[test]
    fn the_sweep_runs_on_the_hub_clock() {
        on_virtual(async {
            let (hub, _repo, hist) = typed();
            hub.start_timers();
            advance(Duration::ZERO).await;
            let report = hist.path().join("size-report.json");
            advance(Duration::from_secs(50)).await;
            assert!(!report.exists(), "swept early");
            advance(Duration::from_secs(20)).await;
            skuld::wait_until("the first sweep's report", 30, || {
                report.exists().then_some(())
            });
        });
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
