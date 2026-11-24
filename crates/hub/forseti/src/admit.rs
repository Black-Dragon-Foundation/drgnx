//! Admission: the machine's budget, the checks a job must pass to start, its grant, and head protection (the head's
//! reservation, [`crate::backfill`]).

use crate::backfill::{Reservation, backfill_ok};
use crate::disk::disk_fits;
use crate::model::{
    Expected, Grant, Job, JobId, Lane, Limits, MachineState, Priority, Range, RunningJob,
    WaitReason,
};
use crate::reserve::count_others;

/// The least time between two starts on one machine by default ([`Limits::start_gap_s`]).
pub const START_GAP_S: u64 = 10;
/// A job whose history peaks under this is small: two small jobs in a row start with no gap.
pub const SMALL_PEAK_MIB: u64 = 1024;

/// The memory one cargo compile unit is given ([`cargo_jobs`]).
pub const CARGO_UNIT_MIB: u64 = 2560;

/// `CARGO_BUILD_JOBS` for a job of GRANT (design §3 #4): one unit per [`CARGO_UNIT_MIB`] of its cap, never more than
/// its cores, at least one.
pub fn cargo_jobs(grant: &Grant) -> u32 {
    let by_mem = u32::try_from(grant.mem_cap_mib / CARGO_UNIT_MIB).unwrap_or(u32::MAX);
    by_mem.min(grant.cores).max(1)
}

/// Whether EXP's history says the job peaks under [`SMALL_PEAK_MIB`].
pub fn small(exp: &Expected) -> bool {
    exp.mem_p95_mib.is_some_and(|p| p < SMALL_PEAK_MIB)
}

/// What a machine can still give: memory (may be negative) and CPU (cores).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Budget {
    pub mem_mib: i64,
    pub cpu: f64,
}

/// The memory a running job of ours holds beyond what it already uses (which `MemAvailable` has lost):
/// `(reserve − current)⁺` at every age. The reservation is at least the p95 peak × 1.1 ([`size`]), so its unused rest
/// is the room the job may still grow into; counting the whole reservation while young counted the used part twice.
pub(crate) fn held_beyond_use(rj: &RunningJob, _now: u64) -> u64 {
    rj.reserve_mib.saturating_sub(rj.current_mib)
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
    // while a timing job holds the island, work has the other cores; the timing job's own CPU is the island's
    let held = m
        .island
        .as_ref()
        .and_then(|i| i.busy.as_ref().map(|j| (i.cpus, j)));
    let island = held.map_or(0.0, |(cpus, _)| f64::from(cpus));
    let used: f64 = m
        .running
        .iter()
        .filter(|r| held.is_none_or(|(_, j)| r.id != *j))
        .map(cpu_counted)
        .sum();
    let cpu = f64::from(limits.cores_usable) - island - used;
    Budget { mem_mib, cpu }
}

/// The timing lane (design §5.6): an island run needs the machine's island, free; a whole-machine run needs the
/// machine empty (its drain, [`crate::drain`], has emptied it). Work passes.
fn timing(job: &Job, m: &MachineState) -> Result<(), WaitReason> {
    match job.spec.lane {
        Lane::Work => Ok(()),
        Lane::Timing { pinned: Some(_) } => match &m.island {
            None => Err(WaitReason::NoIsland),
            Some(i) if i.busy.is_some() => Err(WaitReason::IslandBusy),
            Some(_) => Ok(()),
        },
        Lane::Timing { pinned: None } if m.running.iter().any(|r| r.id != job.id) => {
            Err(WaitReason::DrainWaits)
        }
        Lane::Timing { pinned: None } => Ok(()),
    }
}

/// Whether `job` may start on `m` now. The checks, in order: the timing lane ([`timing`]); the count (fixed
/// slots); a light-only machine refuses a heavy job (`Mode`); power; the gap since the last start; memory
/// (`budget ≥ mem_min`); CPU (`budget ≥` the expected CPU, with overcommit while the running jobs are mostly idle);
/// the PSI limits (memory, the user's apps, CPU for every job; IO only for an `io_heavy` job); the disk: the stop
/// floor stays free after the job's need ([`disk_fits`]). `_eff` is the job's effective priority; F1's checks don't
/// read it.
pub fn admit(
    job: &Job,
    _eff: Priority,
    exp: &Expected,
    m: &MachineState,
    budget: &Budget,
    limits: &Limits,
) -> Result<(), WaitReason> {
    timing(job, m)?;
    if let Some(n) = limits.fixed_slots {
        return if m.running.len() as u64 >= u64::from(n) {
            Err(WaitReason::Threads)
        } else {
            Ok(())
        };
    }
    if limits.light_only && job.spec.heavy() {
        return Err(WaitReason::Mode);
    }
    if limits.no_jobs_on_battery && !m.on_ac {
        return Err(WaitReason::OnBattery);
    }
    // the gap lets the last start's memory show before this one is judged; two small jobs in a row need none
    let gap = if small(exp) && m.last_start_small {
        0
    } else {
        limits.start_gap_s
    };
    if let Some(last) = m.last_start {
        let since = m.now.saturating_sub(last);
        if since < gap {
            return Err(WaitReason::Gap { secs: gap - since });
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
    if job.spec.derived.io_heavy {
        pressure("io", m.psi.io_full10, limits.psi.io_full10)?;
    }
    // the warm build dir a job would reuse is known once slots are leased by tree key; until then none counts
    if !disk_fits(
        u64::from(job.spec.disk_gib),
        m.disk_free_gb,
        m.disk_unused_gib,
        0,
        &limits.disk,
    ) {
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

    #[test]
    fn cargo_jobs_follow_the_grant() {
        // [D] pure (design §3 #4): a compile unit per 2.5 GiB of the cap, never more than the cores, at least one
        let g = |cores, cap| Grant {
            cores,
            mem_cap_mib: cap,
            reserve_mib: cap,
        };
        assert_eq!(cargo_jobs(&g(12, 6144)), 2);
        assert_eq!(cargo_jobs(&g(2, 65_536)), 2);
        assert_eq!(cargo_jobs(&g(12, 1024)), 1);
        assert_eq!(cargo_jobs(&g(0, 0)), 1);
    }
    use crate::model::Island;
    use crate::testkit::{job, machine, running};

    fn known(cpu: f64, p95: u64) -> Expected {
        Expected {
            minutes: 10.0,
            cpu,
            mem_p95_mib: Some(p95),
        }
    }

    /// Job NAME in the timing lane: on the island (PINNED cores), or the whole machine (none).
    fn timing(name: &str, pinned: Option<u8>) -> Job {
        let mut j = job(name, Priority::P3, 0);
        j.spec.lane = Lane::Timing { pinned };
        j
    }

    #[test]
    fn a_second_timing_job_waits_island_busy() {
        // [D] pure (design §5.6): one timing job holds the island; a second waits for it
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 24);
        let mut m = machine(Profile::Dedicated);
        m.island = Some(Island {
            cpus: 12,
            busy: Some(JobId("t1".into())),
        });
        m.running = vec![running("t1", Priority::P3, m.now - 60, 512, 512)];
        let t2 = timing("t2", Some(4));
        let b = budget(&m, &lim);
        assert_eq!(
            admit(&t2, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Err(WaitReason::IslandBusy)
        );
        // a work job is no timing job: it doesn't wait for the island
        let w = job("w", Priority::P3, 0);
        assert_eq!(
            admit(&w, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Ok(())
        );
        m.island.as_mut().unwrap().busy = None;
        m.running.clear();
        let b = budget(&m, &lim);
        assert_eq!(
            admit(&t2, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Ok(())
        );
    }

    #[test]
    fn work_cpu_budget_shrinks_while_timing_runs() {
        // [D] pure (design §5.6): while a timing job holds the island, work has the other cores only; the timing
        // job's own CPU is the island's, not counted twice
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 24);
        let mut m = machine(Profile::Dedicated);
        m.running = vec![
            running("t1", Priority::P3, m.now - 60, 512, 512),
            running("w1", Priority::P3, m.now - 60, 512, 512),
        ];
        // busy jobs (3 of their 4 cores): no overcommit
        for r in &mut m.running {
            r.expected.cpu = 3.0;
        }
        m.island = Some(Island {
            cpus: 12,
            busy: None,
        });
        assert_eq!(budget(&m, &lim).cpu, 18.0);
        m.island.as_mut().unwrap().busy = Some(JobId("t1".into()));
        assert_eq!(budget(&m, &lim).cpu, 24.0 - 12.0 - 3.0);
        // a work job wanting more than the rest waits for cores (it would fit the whole machine's 18)
        let mut big = job("big", Priority::P3, 0);
        big.spec.cores.min = 10;
        let b = budget(&m, &lim);
        assert_eq!(
            admit(
                &big,
                Priority::P3,
                &Expected {
                    minutes: 10.0,
                    cpu: 10.0,
                    mem_p95_mib: Some(512)
                },
                &m,
                &b,
                &lim
            ),
            Err(WaitReason::Threads)
        );
    }

    #[test]
    fn whole_machine_is_refused_without_the_flag() {
        // [D] pure (design §5.6, memory desktop-perf-island): a timing run asked for the island never silently takes
        // a machine that has none; only a whole-machine run (asked with `whole_machine`) may, once the machine is
        // empty
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 24);
        let mut m = machine(Profile::Dedicated);
        let b = budget(&m, &lim);
        let island_run = timing("t", Some(4));
        assert_eq!(
            admit(&island_run, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Err(WaitReason::NoIsland)
        );
        let whole = timing("t", None);
        assert_eq!(
            admit(&whole, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Ok(())
        );
        m.running = vec![running("w1", Priority::P5, m.now - 60, 512, 512)];
        let b = budget(&m, &lim);
        assert_eq!(
            admit(&whole, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Err(WaitReason::DrainWaits)
        );
    }

    #[test]
    fn a_job_holds_its_unused_reservation_at_every_age() {
        // [D] pure (design §0.3 R1): `MemAvailable` has already lost what a job uses, so it holds only the rest of its
        // reservation, young or old; past its reservation it holds nothing more.
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16);
        let mut m = machine(Profile::Dedicated);
        m.mem_available_mib = 20_000;
        m.running = vec![running("r", Priority::P4, m.now - 100, 4000, 500)];
        assert_eq!(budget(&m, &lim).mem_mib, 20_000 - 2048 - 3500);
        m.running[0].started = m.now - 300;
        assert_eq!(budget(&m, &lim).mem_mib, 20_000 - 2048 - 3500);
        m.running[0].current_mib = 6000;
        assert_eq!(budget(&m, &lim).mem_mib, 20_000 - 2048);
    }

    #[test]
    fn a_young_job_holds_only_what_it_has_not_used() {
        // [D] pure: the slots-v2 double count (failure #3). A job 10 s old using 3 GiB of a 4 GiB reservation holds
        // 1 GiB, not 4.
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16);
        let mut m = machine(Profile::Dedicated);
        m.mem_available_mib = 20_480;
        m.running = vec![running("r", Priority::P4, m.now - 10, 4096, 3072)];
        assert_eq!(held_beyond_use(&m.running[0], m.now), 1024);
        assert_eq!(budget(&m, &lim).mem_mib, 20_480 - 2048 - 1024);
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
        // [D] pure: each reading below its limit, or a Pressure naming it (IO: for an IO-heavy job).
        let mut j = job("j", Priority::P3, 0);
        j.spec.derived.io_heavy = true;
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
            what(check(Profile::Workstation, &|m| m.psi.app_mem_some10 = Some(2.0))),
            Some("app memory")
        );
        assert_eq!(
            check(Profile::Workstation, &|m| m.psi.app_mem_some10 = Some(0.5)),
            Ok(())
        );
    }

    #[test]
    fn admission_reads_the_stop_floor_and_the_running_jobs_unused_need() {
        // [D] pure (§4.8): the stop floor (20 GB) stays free after the job's need and the running jobs' unused need,
        // on a disk of any size (the old 10 % rule is gone)
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16);
        let exp = known(1.0, 512);
        let mut j = job("j", Priority::P3, 0);
        let mut m = machine(Profile::Dedicated);
        let mut at = |total: u64, free: u64, unused: u64, need: u32| {
            m.disk_total_gb = total;
            m.disk_free_gb = free;
            m.disk_unused_gib = unused;
            j.spec.disk_gib = need;
            let b = budget(&m, &lim);
            admit(&j, Priority::P3, &exp, &m, &b, &lim)
        };
        assert_eq!(at(100, 30, 0, 10), Ok(()));
        assert_eq!(at(100, 30, 0, 11), Err(WaitReason::DiskLow));
        assert_eq!(at(4000, 30, 0, 10), Ok(()));
        assert_eq!(at(100, 30, 1, 10), Err(WaitReason::DiskLow));
    }

    #[test]
    fn the_io_gate_holds_only_io_heavy_jobs() {
        // [D] pure: IO pressure past the limit holds a job marked io_heavy and no other
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16);
        let mut m = machine(Profile::Dedicated);
        m.psi.io_full10 = 50.0;
        let b = budget(&m, &lim);
        let light = job("l", Priority::P3, 0);
        assert_eq!(
            admit(&light, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Ok(())
        );
        let mut heavy_io = job("h", Priority::P3, 0);
        heavy_io.spec.derived.io_heavy = true;
        assert!(matches!(
            admit(&heavy_io, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Err(WaitReason::Pressure { what: "io", .. })
        ));
    }

    #[test]
    fn an_io_threshold_setting_reaches_admission() {
        // [D] pure: the runner's `--io-pct 35` (the desktop's) is the limit admission reads
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16)
            .with_io_pct(Some(35.0))
            .unwrap();
        assert_eq!(lim.psi.io_full10, 35.0);
        let mut j = job("h", Priority::P3, 0);
        j.spec.derived.io_heavy = true;
        let mut m = machine(Profile::Dedicated);
        m.psi.io_full10 = 30.0;
        let b = budget(&m, &lim);
        assert_eq!(
            admit(&j, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Ok(())
        );
        m.psi.io_full10 = 35.0;
        assert!(matches!(
            admit(&j, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Err(WaitReason::Pressure { what: "io", limit, .. }) if limit == 35.0
        ));
        let base = Limits::for_profile(Profile::Dedicated, 32768, 16);
        assert_eq!(base.with_io_pct(None).unwrap(), base);
        for bad in [0.0, -1.0, 100.5, f64::NAN] {
            assert!(base.with_io_pct(Some(bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn a_light_only_machine_refuses_a_heavy_job() {
        // [D] pure: the laptop as a runner takes light jobs only
        let mut lim = Limits::for_profile(Profile::Workstation, 32768, 16);
        lim.light_only = true;
        let m = machine(Profile::Workstation);
        let b = budget(&m, &lim);
        let light = job("l", Priority::P3, 0);
        assert_eq!(
            admit(&light, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Ok(())
        );
        let mut heavy = job("h", Priority::P3, 0);
        heavy.spec.weight = crate::model::Weight::Heavy;
        assert_eq!(
            admit(&heavy, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Err(WaitReason::Mode)
        );
        lim.light_only = false;
        assert_eq!(
            admit(&heavy, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Ok(())
        );
    }

    #[test]
    fn app_pressure_holds_every_job_on_a_workstation() {
        // [D] pure: the user's apps' memory pressure at the workstation's 2 % holds light and heavy jobs alike
        let lim = Limits::for_profile(Profile::Workstation, 32768, 16);
        let mut m = machine(Profile::Workstation);
        let mut heavy = job("h", Priority::P1, 0);
        heavy.spec.weight = crate::model::Weight::Heavy;
        let light = job("l", Priority::P1, 0);
        for app in [1.9, 2.0] {
            m.psi.app_mem_some10 = Some(app);
            let b = budget(&m, &lim);
            for j in [&light, &heavy] {
                let r = admit(j, Priority::P1, &known(1.0, 512), &m, &b, &lim);
                if app < 2.0 {
                    assert_eq!(r, Ok(()), "{app}");
                } else {
                    assert!(
                        matches!(
                            r,
                            Err(WaitReason::Pressure {
                                what: "app memory",
                                ..
                            })
                        ),
                        "{app}: {r:?}"
                    );
                }
            }
        }
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
    fn small_jobs_start_back_to_back() {
        // [D] pure (design §5.3 item 3): no gap between two jobs whose history peaks under 1 GiB.
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16);
        let j = job("j", Priority::P3, 0);
        let mut m = machine(Profile::Dedicated);
        m.last_start = Some(m.now - 1);
        m.last_start_small = true;
        let b = budget(&m, &lim);
        assert_eq!(
            admit(&j, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Ok(())
        );
    }

    #[test]
    fn a_job_without_history_keeps_the_gap() {
        // [D] pure
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16);
        assert_eq!(lim.start_gap_s, 10);
        let j = job("j", Priority::P3, 0);
        let mut m = machine(Profile::Dedicated);
        m.last_start = Some(m.now - 1);
        m.last_start_small = true;
        let b = budget(&m, &lim);
        let unknown = Expected {
            minutes: 10.0,
            cpu: 1.0,
            mem_p95_mib: None,
        };
        assert_eq!(
            admit(&j, Priority::P3, &unknown, &m, &b, &lim),
            Err(WaitReason::Gap { secs: 9 })
        );
    }

    #[test]
    fn a_small_job_after_a_big_one_waits() {
        // [D] pure: the gap lets the last start's memory show before the next is judged; only two small ones skip it.
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16);
        let j = job("j", Priority::P3, 0);
        let mut m = machine(Profile::Dedicated);
        m.last_start = Some(m.now - 1);
        m.last_start_small = false;
        let b = budget(&m, &lim);
        assert_eq!(
            admit(&j, Priority::P3, &known(1.0, 512), &m, &b, &lim),
            Err(WaitReason::Gap { secs: 9 })
        );
        // and a big job after a small one waits too
        m.last_start_small = true;
        assert_eq!(
            admit(&j, Priority::P3, &known(1.0, SMALL_PEAK_MIB), &m, &b, &lim),
            Err(WaitReason::Gap { secs: 9 })
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
