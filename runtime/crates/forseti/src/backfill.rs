//! Backfill: the best job of the highest waiting priority reserves its start on one machine, from the running jobs'
//! expected ends; a smaller job may start there before it only if it is expected to end first (Slurm's backfill). It
//! replaces F1's head protection (jobq §5.6).

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::admit::{Budget, cpu_counted, held_beyond_use};
use crate::model::{Expected, Job, JobId, MachineState, Priority};

/// What a waiting job needs to start, as [`crate::admit`] checks it: its minimum memory, and its expected CPU (its
/// minimum cores with no history).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Need {
    pub mem_mib: u64,
    pub cpu: f64,
}

impl Need {
    pub fn of(job: &Job, exp: &Expected) -> Need {
        Need {
            mem_mib: job.spec.mem_mib.min,
            cpu: if exp.known() {
                exp.cpu
            } else {
                f64::from(job.spec.cores.min)
            },
        }
    }

    fn fits(&self, b: &Budget) -> bool {
        b.mem_mib >= self.mem_mib as i64 && b.cpu >= self.cpu
    }
}

/// The head's reserved start: `job` (of priority `priority`) starts on `machine` at `at`. Not the `Reservation` of
/// two schedulers on one machine ([`crate::reserve::Reservation`]), so it stays in this module.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reservation {
    pub job: JobId,
    pub priority: Priority,
    pub machine: String,
    pub at: u64,
}

/// The budget `m` will have at `t`: `now_budget` (its [`crate::budget`] at `m.now`) plus, for each running job whose
/// end in `running_ends` is at or before `t`, what the budget counts for it now: the memory it uses and what it holds
/// beyond use, and its CPU. A running job with no end there never gives anything back; one whose end has passed
/// gives it back at once. CPU overcommit isn't counted.
pub fn budget_at(
    m: &MachineState,
    now_budget: &Budget,
    running_ends: &HashMap<JobId, u64>,
    t: u64,
) -> Budget {
    let mut b = *now_budget;
    for rj in &m.running {
        if running_ends.get(&rj.id).is_some_and(|&end| end <= t) {
            b.mem_mib += (rj.current_mib + held_beyond_use(rj, m.now)) as i64;
            b.cpu += cpu_counted(rj);
        }
    }
    b
}

/// The earliest time, from `m.now` on, at which `need` fits `m`'s budget: now, or one of the running jobs' ends.
fn start_at(
    need: &Need,
    m: &MachineState,
    now_budget: &Budget,
    running_ends: &HashMap<JobId, u64>,
) -> Option<u64> {
    let mut times: Vec<u64> = m
        .running
        .iter()
        .filter_map(|rj| running_ends.get(&rj.id))
        .map(|&end| end.max(m.now))
        .collect();
    times.push(m.now);
    times.sort_unstable();
    times.dedup();
    times
        .into_iter()
        .find(|&t| need.fits(&budget_at(m, now_budget, running_ends, t)))
}

/// The head's reservation (jobq §5.6, phase 3). The head is the first job in `order` of the highest priority there
/// (`eff`; a job missing there is P5); no other job reserves. `order` holds the waiting jobs that could start but for
/// room (not those waiting on `needs` or a state lock), each with its [`Need`]. `m` holds the machines that may take
/// the head (those that pass its placement filter), each with its budget now; `running_ends` the running jobs'
/// expected ends ([`expected_end`]). The head reserves the machine where it can start soonest, ties going to the name
/// first in order, so the answer doesn't depend on the order of `m`. `None` when the queue is empty or the head fits
/// nowhere even once every running job has ended.
pub fn reservation(
    order: &[(JobId, Need)],
    eff: &HashMap<JobId, Priority>,
    m: &[(&MachineState, Budget)],
    running_ends: &HashMap<JobId, u64>,
) -> Option<Reservation> {
    let prio = |j: &JobId| eff.get(j).copied().unwrap_or(Priority::P5);
    let highest = order.iter().map(|(j, _)| prio(j)).max()?;
    let (head, need) = order.iter().find(|(j, _)| prio(j) == highest)?;
    m.iter()
        .filter_map(|(ms, b)| start_at(need, ms, b, running_ends).map(|at| (at, ms.name.as_str())))
        .min()
        .map(|(at, machine)| Reservation {
            job: head.clone(),
            priority: highest,
            machine: machine.to_string(),
            at,
        })
}

/// When a job started at `now` and expected to take `expected_s` ends, rounded up to the second.
pub fn expected_end(now: u64, expected_s: f64) -> u64 {
    now.saturating_add(expected_s.max(0.0).ceil() as u64)
}

/// Whether `job` (of effective priority `eff`, expected to take `expected_s`) may start on `machine` at `now` while
/// `r` holds: always on another machine, always for the head itself and for a job of higher priority than the
/// head's; otherwise only if it is expected to end by the head's start. So the jobs backfill starts have given back
/// what they took by `r.at`, and the head's start never moves.
pub fn backfill_ok(
    job: &JobId,
    eff: Priority,
    machine: &str,
    expected_s: f64,
    r: &Reservation,
    now: u64,
) -> bool {
    *job == r.job
        || machine != r.machine
        || eff > r.priority
        || expected_end(now, expected_s) <= r.at
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::admit::budget;
    use crate::model::{Limits, Profile};
    use crate::testkit::{machine, running};

    fn need(mem_mib: u64) -> Need {
        Need { mem_mib, cpu: 1.0 }
    }

    fn id(s: &str) -> JobId {
        JobId(s.into())
    }

    #[test]
    fn only_head_of_highest_priority_reserves() {
        // [D] pure. 6,000 MiB available on a dedicated machine (floor 2,048): 3,952 free now; r1 gives back its
        // 4,000 at +600 s, r2 its 2,000 at +1,200 s.
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16);
        let mut m = machine(Profile::Dedicated);
        let now = m.now;
        m.mem_available_mib = 6000;
        m.running = vec![
            running("r1", Priority::P4, now - 1000, 4000, 4000),
            running("r2", Priority::P4, now - 1000, 2000, 2000),
        ];
        let ends: HashMap<JobId, u64> = [(id("r1"), now + 600), (id("r2"), now + 1200)].into();
        let b = budget(&m, &lim);
        assert_eq!(b.mem_mib, 3952);
        let order = vec![
            (id("small"), need(1024)),
            (id("big"), need(7000)),
            (id("bigger"), need(9000)),
        ];
        let mut eff: HashMap<JobId, Priority> = [
            (id("small"), Priority::P4),
            (id("big"), Priority::P3),
            (id("bigger"), Priority::P3),
        ]
        .into();
        // The first P3 job reserves, though a P4 job comes before it, and the next P3 job doesn't.
        let r = reservation(&order, &eff, &[(&m, b)], &ends);
        assert_eq!(
            r,
            Some(Reservation {
                job: id("big"),
                priority: Priority::P3,
                machine: "m".into(),
                at: now + 600,
            })
        );
        assert_eq!(budget_at(&m, &b, &ends, now + 599).mem_mib, 3952);
        assert_eq!(budget_at(&m, &b, &ends, now + 600).mem_mib, 7952);
        assert_eq!(budget_at(&m, &b, &ends, now + 1200).mem_mib, 9952);
        // A second machine where it starts sooner takes the reservation, in either order.
        let mut n = m.clone();
        n.name = "n".into();
        n.running[0].id = id("n1");
        n.running[1].id = id("n2");
        let ends_n: HashMap<JobId, u64> = [(id("n1"), now + 300), (id("n2"), now + 1200)].into();
        let mut all_ends = ends.clone();
        all_ends.extend(ends_n);
        let nb = budget(&n, &lim);
        let two = reservation(&order, &eff, &[(&m, b), (&n, nb)], &all_ends);
        assert_eq!(
            two.as_ref().map(|r| (r.machine.as_str(), r.at)),
            Some(("n", now + 300))
        );
        assert_eq!(
            reservation(&order, &eff, &[(&n, nb), (&m, b)], &all_ends),
            two
        );
        // A P1 job takes the reservation: it fits now, so its start is now.
        let mut with_p1 = order.clone();
        with_p1.push((id("urgent"), need(1024)));
        eff.insert(id("urgent"), Priority::P1);
        let r = reservation(&with_p1, &eff, &[(&m, b)], &ends).unwrap();
        assert_eq!((r.job, r.priority, r.at), (id("urgent"), Priority::P1, now));
        // A head that never fits, even once everything has ended, reserves nothing; nor does an empty queue.
        let huge = vec![(id("huge"), need(100_000))];
        eff.insert(id("huge"), Priority::P2);
        assert_eq!(reservation(&huge, &eff, &[(&m, b)], &ends), None);
        assert_eq!(reservation(&[], &eff, &[(&m, b)], &ends), None);
        // A running job with no expected end never gives its memory back.
        let r2_only: HashMap<JobId, u64> = [(id("r2"), now + 1200)].into();
        assert_eq!(
            reservation(&order, &eff, &[(&m, b)], &r2_only),
            None,
            "r1 keeps its 4,000: 5,952 at most"
        );
        let mid = vec![(id("mid"), need(5000))];
        eff.insert(id("mid"), Priority::P3);
        let r = reservation(&mid, &eff, &[(&m, b)], &r2_only).unwrap();
        assert_eq!(r.at, now + 1200);
        // CPU counts too: 16 cores, the two running use 1 each.
        let cpu_bound = vec![(
            id("wide"),
            Need {
                mem_mib: 1024,
                cpu: 15.0,
            },
        )];
        eff.insert(id("wide"), Priority::P3);
        let r = reservation(&cpu_bound, &eff, &[(&m, b)], &ends).unwrap();
        assert_eq!(r.at, now + 600);
    }

    #[test]
    fn backfill_only_if_ends_first() {
        // [D] pure
        let now = 1_000_000;
        let r = Reservation {
            job: id("big"),
            priority: Priority::P3,
            machine: "m".into(),
            at: now + 600,
        };
        let ok = |j: &str, eff: Priority, machine: &str, secs: f64| {
            backfill_ok(&id(j), eff, machine, secs, &r, now)
        };
        assert!(ok("small", Priority::P4, "m", 500.0));
        assert!(
            ok("small", Priority::P4, "m", 600.0),
            "ending at the start is first enough"
        );
        assert!(
            !ok("small", Priority::P4, "m", 600.5),
            "a part of a second rounds up"
        );
        assert!(!ok("small", Priority::P4, "m", 601.0));
        assert!(
            !ok("peer", Priority::P3, "m", 601.0),
            "the same priority waits too"
        );
        assert!(
            ok("small", Priority::P4, "n", 10_000.0),
            "another machine isn't held"
        );
        assert!(ok("big", Priority::P3, "m", 10_000.0), "the head itself");
        assert!(
            ok("urgent", Priority::P1, "m", 10_000.0),
            "never a higher priority"
        );
        assert_eq!(expected_end(now, 0.2), now + 1);
        assert_eq!(expected_end(now, -5.0), now);
        // Admission's wording: the held job waits for the head.
        use crate::admit::head_protection;
        use crate::model::WaitReason;
        assert_eq!(
            head_protection(&id("small"), Priority::P4, "m", 601.0, Some(&r), now),
            Err(WaitReason::HeadProtection(id("big")))
        );
        assert_eq!(
            head_protection(&id("small"), Priority::P4, "m", 500.0, Some(&r), now),
            Ok(())
        );
        assert_eq!(
            head_protection(&id("small"), Priority::P4, "m", 601.0, None, now),
            Ok(())
        );
    }

    #[test]
    fn need_is_what_admission_checks() {
        // [D] pure
        let j = crate::testkit::job("j", Priority::P3, 0);
        let known = crate::testkit::expected_min(5.0);
        assert_eq!(
            Need::of(&j, &known),
            Need {
                mem_mib: 1024,
                cpu: 1.0
            }
        );
        let unknown = Expected {
            minutes: 10.0,
            cpu: 0.0,
            mem_p95_mib: None,
        };
        let mut j = j;
        j.spec.cores.min = 2;
        assert_eq!(
            Need::of(&j, &unknown),
            Need {
                mem_mib: 1024,
                cpu: 2.0
            }
        );
    }
}
