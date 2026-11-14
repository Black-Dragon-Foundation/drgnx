//! Eviction limits: who may take a running job's memory, and which jobs go.

use crate::admit::held_beyond_use;
use crate::model::{JobId, MachineState, Priority, RunningJob};

/// A P1 or P2 claimant may evict a running job at least two priorities below it, and only when the victim is
/// restartable, has run less than half its expected time, and was never evicted before.
pub fn may_evict(victim: &RunningJob, claimant: Priority, now: u64) -> bool {
    let ran_s = now.saturating_sub(victim.started) as f64;
    claimant.number() <= 2
        && victim.priority.number() >= claimant.number() + 2
        && victim.restartable
        && ran_s < victim.expected.minutes * 60.0 / 2.0
        && !victim.evicted_once
}

/// The jobs to evict for `claimant`, newest first, until `need_mib` is free: only when the claimant would otherwise
/// miss its 2-minute start goal on every allowed machine, and only if the evictable jobs can free enough (else
/// none).
pub fn preempt_victims(
    claimant: Priority,
    m: &MachineState,
    need_mib: u64,
    now: u64,
    misses_2min_goal: bool,
) -> Vec<JobId> {
    if !misses_2min_goal {
        return vec![];
    }
    let mut candidates: Vec<&RunningJob> = m
        .running
        .iter()
        .filter(|r| may_evict(r, claimant, now))
        .collect();
    candidates.sort_by(|a, b| b.started.cmp(&a.started).then(a.id.cmp(&b.id)));
    let mut freed = 0u64;
    let mut victims = Vec::new();
    for r in candidates {
        if freed >= need_mib {
            break;
        }
        // Evicting frees what it uses (back in MemAvailable) and what the budget held for it beyond that.
        freed += r.current_mib + held_beyond_use(r, now);
        victims.push(r.id.clone());
    }
    if freed >= need_mib { victims } else { vec![] }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Profile;
    use crate::testkit::{machine, running};

    #[test]
    fn eviction_needs_two_priorities_and_half_time_and_once() {
        // [D] pure. The victim is expected to take 10 minutes; half is 300 s.
        let now = 10_000;
        let v = running("v", Priority::P4, now - 100, 1024, 512);
        assert!(may_evict(&v, Priority::P2, now));
        assert!(!may_evict(&v, Priority::P3, now), "only P1 and P2 claim");
        let p3 = running("v", Priority::P3, now - 100, 1024, 512);
        assert!(!may_evict(&p3, Priority::P2, now), "two priorities below");
        assert!(may_evict(&p3, Priority::P1, now));
        let half = running("v", Priority::P4, now - 300, 1024, 512);
        assert!(!may_evict(&half, Priority::P2, now), "half its time run");
        let mut once = v.clone();
        once.evicted_once = true;
        assert!(!may_evict(&once, Priority::P2, now), "evicted once already");
        let mut fixed = v.clone();
        fixed.restartable = false;
        assert!(!may_evict(&fixed, Priority::P2, now), "not restartable");
    }

    #[test]
    fn preempt_takes_the_newest_until_enough() {
        // [D] pure. Old jobs (past 300 s) free what they use plus their unused reserve.
        let mut m = machine(Profile::Dedicated);
        let now = m.now;
        m.running = vec![
            running("oldest", Priority::P5, now - 280, 1000, 1000),
            running("middle", Priority::P5, now - 200, 2000, 1500),
            running("newest", Priority::P5, now - 100, 1000, 800),
            running("p2", Priority::P2, now - 50, 9000, 9000),
        ];
        // All young: newest frees 800 + 1000, middle 1500 + 2000; P2 is too close to the P1 claimant.
        let ids = |v: Vec<JobId>| v.into_iter().map(|j| j.0).collect::<Vec<_>>();
        assert_eq!(
            ids(preempt_victims(Priority::P1, &m, 1500, now, true)),
            ["newest"]
        );
        assert_eq!(
            ids(preempt_victims(Priority::P1, &m, 4000, now, true)),
            ["newest", "middle"]
        );
        assert!(preempt_victims(Priority::P1, &m, 4000, now, false).is_empty());
        assert!(
            preempt_victims(Priority::P1, &m, 100_000, now, true).is_empty(),
            "not enough to free: nothing is evicted"
        );
    }
}
