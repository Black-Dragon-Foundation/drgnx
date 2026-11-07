//! Two schedulers on one machine (a hub and jobq, or two hubs): the reservation format, the counting rule, and who
//! acts on the ladder.

use std::collections::BTreeMap;

use crate::model::RunningJob;

use serde::{Deserialize, Serialize};

/// One running job's claim on a machine, written by its scheduler (`sleipnir::linux::reserve` keeps them as files).
/// It counts only while its process lives (pid and start time), on the boot it was written in, and until `expires`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reservation {
    pub scheduler: String,
    pub pid: u32,
    pub boot_id: String,
    /// The process's start time (`/proc/<pid>/stat` field 22), so a reused pid isn't taken for it.
    pub start_time: u64,
    pub job: String,
    pub reserve_mib: u64,
    pub current_mib: u64,
    pub expires: u64,
}

/// The memory other schedulers hold: Σ `max(reserve, current)` over the reservations that are another scheduler's
/// (not `own_scheduler`), on `boot_id`, alive (`alive(pid, start_time)`) and unexpired at `now`. A job written twice
/// counts once, at its larger figure.
pub fn count_others(
    rs: &[Reservation],
    boot_id: &str,
    alive: &dyn Fn(u32, u64) -> bool,
    own_scheduler: &str,
    now: u64,
) -> u64 {
    let mut once: BTreeMap<(&str, &str), u64> = BTreeMap::new();
    for r in rs {
        if r.scheduler == own_scheduler
            || r.boot_id != boot_id
            || r.expires <= now
            || !alive(r.pid, r.start_time)
        {
            continue;
        }
        let held = r.reserve_mib.max(r.current_mib);
        let e = once.entry((&r.scheduler, &r.job)).or_default();
        *e = (*e).max(held);
    }
    once.values().sum()
}

/// At ladder level 2 or higher only one scheduler acts: the one whose slice holds the most memory, ties going to the
/// name first in order. `own` is this scheduler's name, `others` every other scheduler's `(name, slice MiB)`.
pub fn ladder_actor(own: &str, own_slice_mib: u64, others: &[(String, u64)]) -> bool {
    others
        .iter()
        .filter(|(name, _)| name != own)
        .all(|(name, mib)| own_slice_mib > *mib || (own_slice_mib == *mib && own < name.as_str()))
}

/// Whether scheduler OWN, running OURS, is the [`ladder_actor`] beside the live reservations OTHERS: every scheduler
/// counted by the same rule, Σ `max(reserve, current)` with a job written twice counted once, ours included. (Ours
/// counted by use alone lost to any young job of another's, counted by its reservation: two hubs on one runner each
/// stood down for the other, and nobody acted at danger.)
pub fn ladder_acts(own: &str, ours: &[RunningJob], others: &[Reservation]) -> bool {
    let mut once: BTreeMap<(&str, &str), u64> = BTreeMap::new();
    for r in others.iter().filter(|r| r.scheduler != own) {
        let e = once.entry((&r.scheduler, &r.job)).or_default();
        *e = (*e).max(r.reserve_mib.max(r.current_mib));
    }
    let mut by: BTreeMap<String, u64> = BTreeMap::new();
    for ((s, _), mib) in once {
        *by.entry(s.to_string()).or_default() += mib;
    }
    let own_mib = ours.iter().map(|j| j.reserve_mib.max(j.current_mib)).sum();
    ladder_actor(own, own_mib, &by.into_iter().collect::<Vec<_>>())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(scheduler: &str, job: &str, reserve: u64, current: u64) -> Reservation {
        Reservation {
            scheduler: scheduler.into(),
            pid: 4242,
            boot_id: "boot-a".into(),
            start_time: 77,
            job: job.into(),
            reserve_mib: reserve,
            current_mib: current,
            expires: 2000,
        }
    }

    const LIVE: &dyn Fn(u32, u64) -> bool = &|_, _| true;

    #[test]
    fn others_count_max_of_reserve_and_current_once() {
        // [D] pure
        let rs = [
            r("jobq", "a", 1000, 400),
            r("jobq", "b", 500, 900),
            r("jobq", "a", 1000, 600), // written twice: once
            r("hub", "mine", 8000, 8000),
            r("other-hub", "a", 300, 0), // the same job name of another scheduler is another job
        ];
        assert_eq!(
            count_others(&rs, "boot-a", LIVE, "hub", 1000),
            1000 + 900 + 300
        );
        let mut late = r("jobq", "c", 700, 0);
        late.expires = 1000;
        assert_eq!(
            count_others(&[late], "boot-a", LIVE, "hub", 1000),
            0,
            "expired"
        );
    }

    #[test]
    fn a_dead_or_other_boot_reservation_is_ignored() {
        // [D] pure
        let mut other_boot = r("jobq", "a", 1000, 0);
        other_boot.boot_id = "boot-b".into();
        assert_eq!(count_others(&[other_boot], "boot-a", LIVE, "hub", 1000), 0);
        let mut reused = r("jobq", "a", 1000, 0);
        reused.start_time = 99;
        let alive = |pid: u32, start: u64| pid == 4242 && start == 77;
        assert_eq!(count_others(&[reused], "boot-a", &alive, "hub", 1000), 0);
        assert_eq!(
            count_others(&[r("jobq", "a", 1000, 0)], "boot-a", &alive, "hub", 1000),
            1000
        );
    }

    #[test]
    fn only_the_largest_scheduler_acts_at_level_2() {
        // [D] pure
        let o = |n: &str, mib: u64| vec![(n.to_string(), mib)];
        assert!(ladder_actor("hub", 5000, &o("jobq", 3000)));
        assert!(!ladder_actor("hub", 3000, &o("jobq", 5000)));
        assert!(
            ladder_actor("hub", 4000, &o("jobq", 4000)),
            "a tie goes to the first name"
        );
        assert!(!ladder_actor("jobq", 4000, &o("hub", 4000)));
        assert!(ladder_actor("hub", 0, &[]), "alone, it acts");
        let both = [("hub".to_string(), 4000), ("jobq".to_string(), 1000)];
        assert!(!ladder_actor("hub-2", 3999, &both));
    }

    #[test]
    fn two_hubs_with_young_jobs_one_acts() {
        // [D] pure: each hub's job uses little yet and reserves 256 MiB; the other hub sees its reservation
        use crate::Priority;
        use crate::testkit::running;
        let a = [running("xa", Priority::P3, 0, 256, 3)];
        let b = [running("xb", Priority::P3, 0, 300, 2)];
        let ra = [r("drgnx-hub-a", "xa.1", 256, 0)];
        let rb = [r("drgnx-hub-b", "xb.1", 300, 0)];
        assert!(!ladder_acts("drgnx-hub-a", &a, &rb), "b holds more");
        assert!(ladder_acts("drgnx-hub-b", &b, &ra), "one of the two acts");
        // a job written twice counts once; our own reservations among OTHERS are not another's
        let twice = [
            r("jobq", "j", 200, 0),
            r("jobq", "j", 250, 0),
            ra[0].clone(),
        ];
        assert!(ladder_acts("drgnx-hub-a", &a, &twice));
    }
}
