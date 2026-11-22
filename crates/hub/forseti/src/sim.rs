//! The replay: past arrivals (a time, a job, its expected figures) run through a scheduling policy on a set of machines,
//! without running anything, to see what a policy would have done: when the last job ends, how long jobs waited, and
//! how much a result cache would have saved. Pure and deterministic (job-scheduler design §13).
//!
//! The policies are deliberately plain: [`Policy::FixedSlots`] is what a fixed pool of N slots did (one job per slot,
//! first come first served), and [`Policy::Capacity`] is the budget the scheduler works from (a job starts when a
//! machine has the cores and the memory its expected figures say, still first come first served, so a job never starts
//! before one that arrived earlier). Neither models eviction, drains or the memory ladder.

use crate::history::history_key;
use crate::model::{Expected, JobSpec, Lane};

/// How long a cached pass may be reused (§9.2).
pub const CACHE_MAX_AGE_S: u64 = 24 * 3600;

/// One machine of a replay.
#[derive(Clone, Debug, PartialEq)]
pub struct SimMachine {
    pub name: String,
    pub cores: u32,
    pub mem_mib: u64,
    /// A job takes `expected.minutes / speed` here (1.0: the machine the history was taken on).
    pub speed: f64,
}

/// How the replay admits jobs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Policy {
    /// N slots, one job each; the machines are ignored.
    FixedSlots(u32),
    /// A job starts on the machine where it finishes first among those with room for its cores and memory.
    Capacity,
}

/// What a replay found.
#[derive(Clone, Debug, PartialEq)]
pub struct ReplayReport {
    /// From the first arrival to the last end, in seconds.
    pub makespan_s: u64,
    /// Seconds from arrival to start, over every placed job.
    pub mean_wait_s: f64,
    /// The run time of the jobs a result cache would have answered: the same work arriving within 24 h of an earlier
    /// run of it (a gate, a `fresh` job and a timing run never are). An estimate: the jobs still run in the replay.
    pub cache_saved_s: u64,
    /// Jobs no machine could ever take (more cores or memory than any has): left out of the other figures.
    pub unplaced: u32,
}

fn secs(e: &Expected) -> u64 {
    (e.minutes * 60.0).round().max(0.0) as u64
}

/// ARRIVALS (seconds, job, expected) replayed under POLICY on MACHINES.
pub fn replay(
    arrivals: &[(u64, JobSpec, Expected)],
    machines: &[SimMachine],
    policy: &Policy,
) -> ReplayReport {
    let mut order: Vec<usize> = (0..arrivals.len()).collect();
    order.sort_by_key(|i| (arrivals[*i].0, *i));
    let first = order.first().map(|i| arrivals[*i].0).unwrap_or(0);
    let (mut last_end, mut wait_sum, mut placed, mut unplaced) = (first, 0u64, 0u64, 0u32);
    let mut floor = 0u64;
    match policy {
        Policy::FixedSlots(n) => {
            let mut free = vec![0u64; (*n).max(1) as usize];
            for i in &order {
                let (at, _, e) = &arrivals[*i];
                let s = free
                    .iter()
                    .enumerate()
                    .min_by_key(|(_, f)| **f)
                    .map(|(s, _)| s)
                    .unwrap_or(0);
                let start = (*at).max(free[s]).max(floor);
                let end = start + secs(e);
                free[s] = end;
                floor = start;
                wait_sum += start - at;
                placed += 1;
                last_end = last_end.max(end);
            }
        }
        Policy::Capacity => {
            // (machine, end, cores, mem) of every placed job
            let mut running: Vec<(usize, u64, u32, u64)> = vec![];
            for i in &order {
                let (at, spec, e) = &arrivals[*i];
                let cores = e.cpu.ceil().max(1.0) as u32;
                let mem = e.mem_p95_mib.unwrap_or(spec.mem_mib.max);
                if !machines
                    .iter()
                    .any(|m| m.cores >= cores && m.mem_mib >= mem)
                {
                    unplaced += 1;
                    continue;
                }
                // the times a start could be: the arrival, and each end after it
                let t0 = (*at).max(floor);
                let mut times: Vec<u64> = vec![t0];
                times.extend(running.iter().map(|r| r.1).filter(|t| *t > t0));
                times.sort();
                times.dedup();
                let mut best: Option<(u64, u64, usize)> = None;
                for t in times {
                    for (mi, m) in machines.iter().enumerate() {
                        let (uc, um) = running
                            .iter()
                            .filter(|r| r.0 == mi && r.1 > t)
                            .fold((0, 0), |a, r| (a.0 + r.2, a.1 + r.3));
                        if m.cores >= uc + cores && m.mem_mib >= um + mem {
                            let end = t + (secs(e) as f64 / m.speed.max(0.01)).round() as u64;
                            if best.is_none_or(|b| end < b.1) {
                                best = Some((t, end, mi));
                            }
                        }
                    }
                    if best.is_some() {
                        break;
                    }
                }
                let (start, end, mi) = best.expect("a machine fits it once the others end");
                running.push((mi, end, cores, mem));
                floor = start;
                wait_sum += start - at;
                placed += 1;
                last_end = last_end.max(end);
            }
        }
    }
    ReplayReport {
        makespan_s: last_end - first,
        mean_wait_s: if placed == 0 {
            0.0
        } else {
            wait_sum as f64 / placed as f64
        },
        cache_saved_s: cache_saved(arrivals, &order),
        unplaced,
    }
}

/// What a result cache would have saved: for each job that may be cached, the run time of those that repeat the work of
/// an earlier job less than a day before.
fn cache_saved(arrivals: &[(u64, JobSpec, Expected)], order: &[usize]) -> u64 {
    let mut seen: Vec<(String, u64)> = vec![];
    let mut saved = 0;
    for i in order {
        let (at, spec, e) = &arrivals[*i];
        if spec.gate.is_some() || spec.fresh || spec.lane != Lane::Work {
            continue;
        }
        let key = format!("{}\u{1f}{}", history_key(spec), spec.tree.display());
        if seen
            .iter()
            .any(|(k, t)| *k == key && at - t <= CACHE_MAX_AGE_S)
        {
            saved += secs(e);
        }
        seen.push((key, *at));
    }
    saved
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::spec;

    fn exp(minutes: f64) -> Expected {
        Expected {
            minutes,
            cpu: 1.0,
            mem_p95_mib: Some(1024),
        }
    }

    fn at_zero(minutes: &[f64]) -> Vec<(u64, JobSpec, Expected)> {
        minutes
            .iter()
            .enumerate()
            .map(|(i, m)| (0, spec(&format!("job{i}")), exp(*m)))
            .collect()
    }

    // [D] pure: the queues of 4 and of 10 slots, worked out by hand
    #[test]
    fn fixed_slots_4_and_10_reproduce_their_queues() {
        let jobs = at_zero(&[
            10.0, 10.0, 10.0, 10.0, 5.0, 5.0, 5.0, 5.0, 2.0, 2.0, 2.0, 2.0,
        ]);
        // 4 slots: four 10 min jobs at 0, the 5 min jobs at 600, the 2 min jobs at 900 (ends 1020)
        let four = replay(&jobs, &[], &Policy::FixedSlots(4));
        assert_eq!(four.makespan_s, 1020);
        assert_eq!(four.mean_wait_s, 500.0);
        // 10 slots: ten start at 0; the last two 2 min jobs take the slots the first two 2 min jobs free at 120
        let ten = replay(&jobs, &[], &Policy::FixedSlots(10));
        assert_eq!(ten.makespan_s, 600);
        assert_eq!(ten.mean_wait_s, 20.0);
        // arrivals are taken in time order, and a lone job waits for nothing
        let late = vec![(500, spec("b"), exp(1.0)), (100, spec("a"), exp(1.0))];
        let r = replay(&late, &[], &Policy::FixedSlots(1));
        assert_eq!((r.makespan_s, r.mean_wait_s), (460, 0.0));
        assert_eq!(replay(&[], &[], &Policy::FixedSlots(4)).makespan_s, 0);
    }

    // [D] pure
    #[test]
    fn capacity_places_by_cores_and_memory_first_come_first_served() {
        let m = |name: &str, cores, speed| SimMachine {
            name: name.into(),
            cores,
            mem_mib: 4096,
            speed,
        };
        let machines = [m("small", 2, 1.0), m("fast", 2, 2.0)];
        let jobs = at_zero(&[10.0, 10.0, 10.0]);
        let r = replay(&jobs, &machines, &Policy::Capacity);
        // the fast machine takes two at once (5 min each), the small one one (10 min): all start at 0
        assert_eq!((r.makespan_s, r.mean_wait_s, r.unplaced), (600, 0.0, 0));
        // a job no machine could ever hold is left out
        let mut big = at_zero(&[1.0]);
        big[0].2.mem_p95_mib = Some(1 << 20);
        assert_eq!(replay(&big, &machines, &Policy::Capacity).unplaced, 1);
    }

    // [D] pure
    #[test]
    fn the_cache_would_save_repeats_within_a_day_but_never_a_gate_or_a_timing_run() {
        let mut gate = spec("g");
        gate.gate = Some("rel".into());
        let mut timing = spec("t");
        timing.lane = Lane::Timing { pinned: None };
        let jobs = vec![
            (0, spec("same"), exp(10.0)),
            (3_600, spec("same"), exp(10.0)),
            (3_700, gate.clone(), exp(10.0)),
            (3_800, gate, exp(10.0)),
            (4_000, timing.clone(), exp(10.0)),
            (4_100, timing, exp(10.0)),
            (3_600 + CACHE_MAX_AGE_S + 1, spec("same"), exp(10.0)),
        ];
        // one repeat inside a day; the last is more than a day after the second
        let r = replay(&jobs, &[], &Policy::FixedSlots(7));
        assert_eq!(r.cache_saved_s, 600);
    }
}
