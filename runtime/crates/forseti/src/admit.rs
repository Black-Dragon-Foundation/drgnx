//! Admission: the machine's budget, the checks a job must pass to start, its grant, and head protection (the head's
//! reservation, [`crate::backfill`]).

use crate::backfill::{Reservation, backfill_ok};
use crate::model::{
    Expected, Grant, Job, JobId, Limits, MachineState, Priority, Range, RunningJob, WaitReason,
};
use crate::reserve::count_others;

/// A job counts its full reservation for its first 300 s, whatever it uses (a container grows after its setup).
pub const YOUNG_S: u64 = 300;
/// The least time between two starts on one machine.
pub const START_GAP_S: u64 = 10;

/// What a machine can still give: memory (may be negative) and CPU (cores).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Budget {
    pub mem_mib: i64,
    pub cpu: f64,
}

/// The memory a running job of ours holds beyond what it already uses (which `MemAvailable` has lost): its whole
/// reservation while young, then `(reserve − current)⁺`.
pub(crate) fn held_beyond_use(rj: &RunningJob, now: u64) -> u64 {
    if now.saturating_sub(rj.started) < YOUNG_S {
        rj.reserve_mib
    } else {
        rj.reserve_mib.saturating_sub(rj.current_mib)
    }
}

/// The CPU a running job counts: its expected mean, or its grant's cores when it has no history.
pub(crate) fn cpu_counted(rj: &RunningJob) -> f64 {
    if rj.expected.known() {
        rj.expected.cpu
    } else {
        f64::from(rj.cores)
    }
}

/// The running jobs use less than half their grants on average.
fn mostly_idle(running: &[RunningJob]) -> bool {
    if running.is_empty() {
        return false;
    }
    let used: f64 = running
        .iter()
        .map(|r| cpu_counted(r) / f64::from(r.cores.max(1)))
        .sum();
    used / (running.len() as f64) < 0.5
}

fn pressure(what: &'static str, value: f64, limit: f64) -> Result<(), WaitReason> {
    if value < limit {
        Ok(())
    } else {
        Err(WaitReason::Pressure { what, value, limit })
    }
}

/// `mem = MemAvailable − floor − reserve_user − Σ ours held beyond use − others`, where others are counted by
/// [`crate::count_others`] on this boot (the probe has already dropped those whose process is gone);
/// `cpu = cores_usable − Σ expected CPU`, an unknown job counting its grant's cores.
pub fn budget(m: &MachineState, limits: &Limits) -> Budget {
    let ours: u64 = m.running.iter().map(|r| held_beyond_use(r, m.now)).sum();
    let others = count_others(&m.others, &m.boot_id, &|_, _| true, "", m.now);
    let mem_mib = m.mem_available_mib as i64
        - limits.floor_mib as i64
        - limits.reserve_user_mib as i64
        - ours as i64
        - others as i64;
    let cpu = f64::from(limits.cores_usable) - m.running.iter().map(cpu_counted).sum::<f64>();
    Budget { mem_mib, cpu }
}

/// Whether `job` may start on `m` now. The checks, in order: the count (fixed slots); power; the gap since the last
/// start; memory (`budget ≥ mem_min`); CPU (`budget ≥` the expected CPU, with overcommit while the running jobs are
/// mostly idle); the PSI limits; the disk after the job's need. `eff` is the job's effective priority; F1's checks
/// don't read it.
pub fn admit(
    job: &Job,
    eff: Priority,
    exp: &Expected,
    m: &MachineState,
    budget: &Budget,
    limits: &Limits,
) -> Result<(), WaitReason> {
    let _ = eff;
    if let Some(n) = limits.fixed_slots {
        return if m.running.len() as u64 >= u64::from(n) {
            Err(WaitReason::Threads)
        } else {
            Ok(())
        };
    }
    if limits.no_jobs_on_battery && !m.on_ac {
        return Err(WaitReason::OnBattery);
    }
    if let Some(last) = m.last_start {
        let since = m.now.saturating_sub(last);
        if since < START_GAP_S {
            return Err(WaitReason::Gap {
                secs: START_GAP_S - since,
            });
        }
    }
    let need_mib = job.spec.mem_mib.min;
    if budget.mem_mib < need_mib as i64 {
        return Err(WaitReason::NoRoom {
            need_mib,
            free_mib: budget.mem_mib,
        });
    }
    let need_cpu = if exp.known() {
        exp.cpu
    } else {
        f64::from(job.spec.cores.min)
    };
    let mut cpu = budget.cpu;
    if limits.overcommit > 1.0 && mostly_idle(&m.running) {
        cpu += (limits.overcommit - 1.0) * f64::from(limits.cores_usable);
    }
    if cpu < need_cpu {
        return Err(WaitReason::Threads);
    }
    pressure("memory", m.psi.mem_some10, limits.psi.mem_some10)?;
    if let (Some(value), Some(limit)) = (m.psi.app_mem_some10, limits.psi.app_mem_some10) {
        pressure("app memory", value, limit)?;
    }
    pressure("cpu", m.psi.cpu_some10, limits.psi.cpu_some10)?;
    pressure("io", m.psi.io_full10, limits.psi.io_full10)?;
    let pct_gb = (m.disk_total_gb * u64::from(limits.disk_guard_pct)).div_ceil(100);
    let guard = limits.disk_guard_gb.max(pct_gb);
    if m.disk_free_gb < guard + u64::from(job.spec.disk_gib) {
        return Err(WaitReason::DiskLow);
    }
    Ok(())
}

/// The grant at start (jobq §5.4):
///
/// - `cores = clamp(cpu_budget / waiting_fit, cores_min, cores_max)`;
/// - `mem_cap = clamp(max(p95 × 1.3, mem_min), mem_min, min(mem_max, mem_budget))`;
/// - `reserve = max(p95 × 1.1, mem_min)`, never above the cap.
///
/// With no history (no p95) the cap is `min(mem_max, mem_budget)` and the reserve `mem_min`.
pub fn size(job: &Job, exp: &Expected, budget: &Budget, waiting_fit: u32) -> Grant {
    let cores = job.spec.cores;
    let share = (budget.cpu / f64::from(waiting_fit.max(1))).floor();
    let grant_cores = if share <= f64::from(cores.min) {
        cores.min
    } else {
        (share as u32).min(cores.max).max(cores.min)
    };
    let mem = job.spec.mem_mib;
    let room = budget.mem_mib.max(0) as u64;
    let hi = mem.max.min(room).max(mem.min);
    let (cap, reserve) = match exp.mem_p95_mib {
        Some(p95) => {
            let cap = scale(p95, 13).max(mem.min).clamp(mem.min, hi);
            (cap, scale(p95, 11).max(mem.min).min(cap))
        }
        None => (hi, mem.min.min(hi)),
    };
    Grant {
        cores: grant_cores,
        mem_cap_mib: cap,
        reserve_mib: reserve,
    }
}

/// `mib × tenths / 10`, rounded up.
fn scale(mib: u64, tenths: u64) -> u64 {
    (mib.saturating_mul(tenths)).div_ceil(10)
}

/// The memory range for the one re-run after an `oom` verdict: the minimum × 1.5 (the maximum at least that).
pub fn oom_rerun(mem: &Range<u64>) -> Range<u64> {
    let min = scale(mem.min, 15);
    Range {
        min,
        max: mem.max.max(min),
    }
}

/// Head protection, as the head's reservation ([`crate::backfill`]): a job that [`admit`] lets start on `machine`
/// waits as `HeadProtection(head)` while the reservation holds it there ([`backfill_ok`]). With no reservation, nothing
/// is held.
pub fn head_protection(
    job: &JobId,
    eff: Priority,
    machine: &str,
    expected_s: f64,
    reservation: Option<&Reservation>,
    now: u64,
) -> Result<(), WaitReason> {
    match reservation {
        Some(r) if !backfill_ok(job, eff, machine, expected_s, r, now) => {
            Err(WaitReason::HeadProtection(r.job.clone()))
        }
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Profile;
    use crate::testkit::{job, machine, running};

    fn known(cpu: f64, p95: u64) -> Expected {
        Expected {
            minutes: 10.0,
            cpu,
            mem_p95_mib: Some(p95),
        }
    }

    #[test]
    fn a_job_counts_its_reservation_for_5_minutes() {
        // [D] pure
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16);
        let mut m = machine(Profile::Dedicated);
        m.mem_available_mib = 20_000;
        m.running = vec![running("r", Priority::P4, m.now - 100, 4000, 500)];
        assert_eq!(budget(&m, &lim).mem_mib, 20_000 - 2048 - 4000);
        m.running[0].started = m.now - YOUNG_S;
        assert_eq!(budget(&m, &lim).mem_mib, 20_000 - 2048 - 3500);
        m.running[0].current_mib = 6000;
        assert_eq!(budget(&m, &lim).mem_mib, 20_000 - 2048);
    }

    #[test]
    fn workstation_refuses_on_battery() {
        // [D] pure
        let j = job("j", Priority::P3, 0);
        let mut m = machine(Profile::Workstation);
        m.on_ac = false;
        let ws = Limits::for_profile(Profile::Workstation, 32768, 16);
        let b = budget(&m, &ws);
        assert_eq!(
            admit(&j, Priority::P3, &known(1.0, 512), &m, &b, &ws),
            Err(WaitReason::OnBattery)
        );
        let ded = Limits::for_profile(Profile::Dedicated, 32768, 16);
        let b = budget(&m, &ded);
        assert_eq!(
            admit(&j, Priority::P3, &known(1.0, 512), &m, &b, &ded),
            Ok(())
        );
    }

    #[test]
    fn workstation_never_overcommits() {
        // [D] pure. Three running jobs granted 4 cores each use 1 on average: mostly idle.
        let j = job("j", Priority::P3, 0);
        let mut m = machine(Profile::Workstation);
        m.running = (0..3)
            .map(|i| running(&format!("r{i}"), Priority::P4, m.now - 1000, 512, 512))
            .collect();
        let ws = Limits::for_profile(Profile::Workstation, 32768, 16);
        let b = budget(&m, &ws);
        assert_eq!(b.cpu, 12.0 - 3.0);
        assert_eq!(
            admit(&j, Priority::P3, &known(10.0, 512), &m, &b, &ws),
            Err(WaitReason::Threads)
        );
        let ded = Limits::for_profile(Profile::Dedicated, 32768, 12);
        let b = budget(&m, &ded);
        assert_eq!(
            admit(&j, Priority::P3, &known(10.0, 512), &m, &b, &ded),
            Ok(())
        );
        // Not idle (each uses 3 of its 4): no overcommit on a dedicated machine either.
        for r in &mut m.running {
            r.expected.cpu = 3.0;
        }
        let b = budget(&m, &ded);
        assert_eq!(
            admit(&j, Priority::P3, &known(10.0, 512), &m, &b, &ded),
            Err(WaitReason::Threads)
        );
    }

    #[test]
    fn psi_limits_per_limits() {
        // [D] pure: each reading below its limit, or a Pressure naming it.
        let j = job("j", Priority::P3, 0);
        let exp = known(1.0, 512);
        let check = |profile: Profile, set: &dyn Fn(&mut MachineState)| {
            let lim = Limits::for_profile(profile, 32768, 16);
            let mut m = machine(profile);
            set(&mut m);
            let b = budget(&m, &lim);
            admit(&j, Priority::P3, &exp, &m, &b, &lim)
        };
        let what = |r: Result<(), WaitReason>| match r {
            Err(WaitReason::Pressure { what, .. }) => Some(what),
            _ => None,
        };
        assert_eq!(
            check(Profile::Dedicated, &|m| m.psi.mem_some10 = 9.9),
            Ok(())
        );
        assert_eq!(
            what(check(Profile::Dedicated, &|m| m.psi.mem_some10 = 10.0)),
            Some("memory")
        );
        assert_eq!(
            what(check(Profile::Dedicated, &|m| m.psi.cpu_some10 = 40.0)),
            Some("cpu")
        );
        assert_eq!(
            what(check(Profile::Dedicated, &|m| m.psi.io_full10 = 10.0)),
            Some("io")
        );
        assert_eq!(
            check(Profile::Dedicated, &|m| m.psi.app_mem_some10 = Some(50.0)),
            Ok(())
        );
        assert_eq!(
            what(check(Profile::Workstation, &|m| m.psi.mem_some10 = 2.0)),
            Some("memory")
        );
        assert_eq!(
            what(check(Profile::Workstation, &|m| m.psi.app_mem_some10 = Some(1.5))),
            Some("app memory")
        );
        assert_eq!(
            check(Profile::Workstation, &|m| m.psi.app_mem_some10 = Some(0.5)),
            Ok(())
        );
    }

    #[test]
    fn disk_guard_after_the_jobs_need() {
        // [D] pure: 20 GB and 10 % stay free after the job's declared need.
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16);
        let exp = known(1.0, 512);
        let mut j = job("j", Priority::P3, 0);
        let mut m = machine(Profile::Dedicated);
        let mut at = |total: u64, free: u64, need: u32| {
            m.disk_total_gb = total;
            m.disk_free_gb = free;
            j.spec.disk_gib = need;
            let b = budget(&m, &lim);
            admit(&j, Priority::P3, &exp, &m, &b, &lim)
        };
        assert_eq!(at(100, 25, 5), Ok(()));
        assert_eq!(at(100, 25, 6), Err(WaitReason::DiskLow));
        assert_eq!(at(1000, 105, 5), Ok(()));
        assert_eq!(at(1000, 104, 5), Err(WaitReason::DiskLow));
    }

    #[test]
    fn memory_and_the_gap_between_starts() {
        // [D] pure
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16);
        let exp = known(1.0, 512);
        let j = job("j", Priority::P3, 0);
        let mut m = machine(Profile::Dedicated);
        m.last_start = Some(m.now - 4);
        let b = budget(&m, &lim);
        assert_eq!(
            admit(&j, Priority::P3, &exp, &m, &b, &lim),
            Err(WaitReason::Gap { secs: 6 })
        );
        m.last_start = Some(m.now - START_GAP_S);
        m.mem_available_mib = 2048 + 1000;
        let b = budget(&m, &lim);
        assert_eq!(
            admit(&j, Priority::P3, &exp, &m, &b, &lim),
            Err(WaitReason::NoRoom {
                need_mib: 1024,
                free_mib: 1000
            })
        );
    }

    #[test]
    fn grant_formulas() {
        // [D] pure
        let mut j = job("j", Priority::P3, 0);
        j.spec.cores = Range { min: 1, max: 4 };
        j.spec.mem_mib = Range {
            min: 1024,
            max: 8192,
        };
        let b = Budget {
            mem_mib: 16_000,
            cpu: 8.0,
        };
        let exp = known(1.0, 2000);
        // A quiet machine: the most cores; the cap from p95 × 1.3, the reserve from p95 × 1.1.
        assert_eq!(
            size(&j, &exp, &b, 1),
            Grant {
                cores: 4,
                mem_cap_mib: 2600,
                reserve_mib: 2200
            }
        );
        // A long queue: toward the fewest cores.
        assert_eq!(size(&j, &exp, &b, 8).cores, 1);
        assert_eq!(size(&j, &exp, &b, 3).cores, 2);
        // A tight budget bounds the cap, and the reserve never passes the cap.
        let tight = Budget {
            mem_mib: 2000,
            cpu: 8.0,
        };
        let g = size(&j, &exp, &tight, 1);
        assert_eq!((g.mem_cap_mib, g.reserve_mib), (2000, 2000));
        // No history: the cap is what the budget and the maximum allow, the reserve the minimum.
        let unknown = Expected {
            minutes: 10.0,
            cpu: 0.0,
            mem_p95_mib: None,
        };
        let g = size(&j, &unknown, &b, 1);
        assert_eq!((g.mem_cap_mib, g.reserve_mib), (8192, 1024));
        // A small p95 still gets the minimum.
        let g = size(&j, &known(1.0, 100), &b, 1);
        assert_eq!((g.mem_cap_mib, g.reserve_mib), (1024, 1024));
    }

    #[test]
    fn oom_rerun_at_one_and_a_half() {
        // [D] pure
        assert_eq!(
            oom_rerun(&Range {
                min: 1024,
                max: 4096
            }),
            Range {
                min: 1536,
                max: 4096
            }
        );
        assert_eq!(
            oom_rerun(&Range {
                min: 3000,
                max: 4000
            }),
            Range {
                min: 4500,
                max: 4500
            }
        );
        let mut j = job("j", Priority::P3, 0);
        j.spec.mem_mib = oom_rerun(&j.spec.mem_mib);
        let b = Budget {
            mem_mib: 16_000,
            cpu: 8.0,
        };
        let g = size(&j, &known(1.0, 900), &b, 1);
        assert_eq!((g.mem_cap_mib, g.reserve_mib), (1536, 1536));
    }

    #[test]
    fn fixed_slots_admit_by_count() {
        // [D] pure: no memory, power, PSI or disk reading counts.
        let lim = Limits::fixed_slots(2);
        let j = job("j", Priority::P3, 0);
        let mut m = machine(Profile::Workstation);
        m.mem_available_mib = 0;
        m.on_ac = false;
        m.disk_free_gb = 0;
        m.running = vec![running("a", Priority::P3, m.now - 5, 512, 512)];
        let b = budget(&m, &lim);
        assert_eq!(
            admit(&j, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Ok(())
        );
        m.running
            .push(running("b", Priority::P3, m.now - 5, 512, 512));
        assert_eq!(
            admit(&j, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Err(WaitReason::Threads)
        );
    }
}
