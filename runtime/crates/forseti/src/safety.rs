//! Memory safety, the pure half: the cap on all our work, the ladder, and the throttle rules from the oomd spike.
//!
//! The shell writes the cap to its top slice every 2 s (`MemoryHigh`, `MemoryMax`), reads the PSI files every
//! second, and carries out the actions.

use serde::{Deserialize, Serialize};

use crate::model::{JobId, Limits, MachineState, Profile, RunningJob};

/// How far `MemoryMax` comes down per 2 s tick (the oomd spike: 1 GiB stands).
pub const STEP_MIB: u64 = 1024;
/// `MemoryMax` sits this far above `MemoryHigh` once it has come down.
pub const MAX_ABOVE_HIGH_MIB: u64 = 512;
/// Our own slice's memory `full avg10` above this, for [`OURS_FULL_FOR_S`], evicts (both profiles).
pub const OURS_FULL_LIMIT: f64 = 50.0;
pub const OURS_FULL_FOR_S: u64 = 10;
/// A job over `MemoryHigh` freezes (no swap) and reaches oomd's 80 % in 18–25 s; it is evicted after this long over,
/// so the throttle is resolved within 20 s of the drop.
pub const OVER_HIGH_FOR_S: u64 = 10;
/// At level 2 a dedicated machine goes to level 3 after this long without relief.
pub const LEVEL2_TO_3_S: u64 = 10;
/// A workstation kills our newest job again every this many seconds while the danger holds.
pub const KILL_EVERY_S: u64 = 5;
/// Jobs expected to take less than this are "short" at level 2 (evicted, not paused).
pub const SHORT_MINUTES: f64 = 5.0;

/// The cap's bound while no scheduler runs: dedicated `MemTotal − 3 GiB`, workstation `MemTotal − 8 GiB` (the user's
/// usual apps and their reserve).
pub fn static_ceiling(profile: Profile, mem_total_mib: u64) -> u64 {
    let keep = match profile {
        Profile::Dedicated => 3072,
        Profile::Workstation => 8192,
    };
    mem_total_mib.saturating_sub(keep)
}

/// `cap = ours_used + MemAvailable − reserve_user − floor`, never above `ceiling` (`ours_used` is our slice's
/// `memory.current` less its file pages).
pub fn cap_target(
    ours_used_mib: u64,
    mem_available_mib: u64,
    reserve_user_mib: u64,
    floor_mib: u64,
    ceiling: u64,
) -> u64 {
    (ours_used_mib + mem_available_mib)
        .saturating_sub(reserve_user_mib + floor_mib)
        .min(ceiling)
}

/// Which of the two writes goes first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CapOrder {
    RaiseMaxFirst,
    LowerHighFirst,
}

/// The values to write to the top slice: `MemoryHigh`, `MemoryMax`, in `order`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapWrite {
    pub high: u64,
    pub max: u64,
    pub order: CapOrder,
}

/// One tick toward `target`. Raising: `MemoryMax` first (to `target + 512`), then `MemoryHigh = target`. Lowering:
/// `MemoryHigh = target` at once, then `MemoryMax` down by at most `step_mib` toward `target + 512`, which gives the
/// ladder time to evict by choice before the kernel kills inside our slice.
pub fn cap_step(cur_high: u64, cur_max: u64, target: u64, step_mib: u64) -> CapWrite {
    let _ = cur_high;
    let want_max = target + MAX_ABOVE_HIGH_MIB;
    if want_max > cur_max {
        CapWrite {
            high: target,
            max: want_max,
            order: CapOrder::RaiseMaxFirst,
        }
    } else {
        CapWrite {
            high: target,
            max: want_max.max(cur_max.saturating_sub(step_mib)),
            order: CapOrder::LowerHighFirst,
        }
    }
}

/// The ladder's levels: normal, tight (stop admitting), pressure, danger.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Level {
    Normal,
    Tight,
    Pressure,
    Danger,
}

/// The ladder's level from the machine (system memory PSI `some avg10`, `MemAvailable`; the user's apps' pressure on
/// a workstation).
///
/// - Dedicated: tight below `floor + 2 GiB` or PSI above the admission limit (10 %), pressure below `floor + 1 GiB` or
///   above 20 %, danger below the floor or above 40 %.
/// - Workstation: tight below `reserve_user + floor + 2 GiB`, PSI above its limit (2 %) or the apps above theirs
///   (1 %); danger below `reserve_user + floor` or the apps above 5 %. It has no pressure level.
pub fn ladder_level(m: &MachineState, limits: &Limits) -> Level {
    let avail = m.mem_available_mib;
    let psi = m.psi.mem_some10;
    match m.profile {
        Profile::Dedicated => {
            let floor = limits.floor_mib;
            if avail < floor || psi > 40.0 {
                Level::Danger
            } else if avail < floor + 1024 || psi > 20.0 {
                Level::Pressure
            } else if avail < floor + 2048 || psi > limits.psi.mem_some10 {
                Level::Tight
            } else {
                Level::Normal
            }
        }
        Profile::Workstation => {
            let base = limits.reserve_user_mib + limits.floor_mib;
            let app = m.psi.app_mem_some10.unwrap_or(0.0);
            let app_limit = limits.psi.app_mem_some10.unwrap_or(f64::INFINITY);
            if avail < base || app > 5.0 {
                Level::Danger
            } else if avail < base + 2048 || psi > limits.psi.mem_some10 || app > app_limit {
                Level::Tight
            } else {
                Level::Normal
            }
        }
    }
}

/// The newest of `jobs` (latest start; the larger id on a tie, so the choice never depends on input order).
fn newest<'a>(jobs: impl Iterator<Item = &'a RunningJob>) -> Option<&'a RunningJob> {
    jobs.max_by(|a, b| a.started.cmp(&b.started).then(a.id.cmp(&b.id)))
}

/// The lowest priority among `jobs`.
fn lowest<'a>(jobs: impl Iterator<Item = &'a RunningJob>) -> Option<crate::model::Priority> {
    jobs.map(|r| r.priority).min()
}

fn is_short(r: &RunningJob) -> bool {
    !r.long_build && r.expected.minutes < SHORT_MINUTES
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Action {
    StopAdmitting,
    Pause(JobId),
    /// Stop and requeue.
    Evict(JobId),
    /// Stop: our newest job on a workstation in danger.
    Kill(JobId),
}

/// What the ladder does at `level`. `since_level2_s` is how long the machine has been at level 2 or higher;
/// `last_kill` how long ago this scheduler last killed a job (none yet: `None`).
///
/// - Dedicated: tight stops admitting; pressure also pauses the lowest-priority long builds and evicts the
///   lowest-priority short jobs (expected under 5 minutes), and after 10 s without relief acts as danger; danger
///   evicts one job per tick, lowest priority first, newest first, until level 1 holds.
/// - Workstation: tight and pressure stop admitting; danger kills our newest job, again every 5 s while it holds. It
///   never pauses.
///
/// At level 2 or higher only the [`crate::ladder_actor`] acts.
pub fn ladder_actions(
    level: Level,
    profile: Profile,
    running: &[RunningJob],
    since_level2_s: u64,
    last_kill: Option<u64>,
) -> Vec<Action> {
    if level == Level::Normal {
        return vec![];
    }
    let mut acts = vec![Action::StopAdmitting];
    match profile {
        Profile::Workstation => {
            let again = last_kill.is_none_or(|ago| ago >= KILL_EVERY_S);
            if level == Level::Danger
                && again
                && let Some(r) = newest(running.iter())
            {
                acts.push(Action::Kill(r.id.clone()));
            }
        }
        Profile::Dedicated => {
            let danger = level == Level::Danger
                || (level == Level::Pressure && since_level2_s >= LEVEL2_TO_3_S);
            if danger {
                if let Some(p) = lowest(running.iter())
                    && let Some(r) = newest(running.iter().filter(|r| r.priority == p))
                {
                    acts.push(Action::Evict(r.id.clone()));
                }
            } else if level == Level::Pressure {
                let builds = || running.iter().filter(|r| r.long_build);
                if let Some(p) = lowest(builds()) {
                    acts.extend(
                        builds()
                            .filter(|r| r.priority == p)
                            .map(|r| Action::Pause(r.id.clone())),
                    );
                }
                let short = || running.iter().filter(|r| is_short(r));
                if let Some(p) = lowest(short()) {
                    acts.extend(
                        short()
                            .filter(|r| r.priority == p)
                            .map(|r| Action::Evict(r.id.clone())),
                    );
                }
            }
        }
    }
    acts
}

/// The throttle rules (both profiles), from the oomd spike: a job over `MemoryHigh` freezes without swap, and oomd
/// acts on the time spent there. `over_high_s` is how long our slice has used more than its `MemoryHigh`;
/// `ours_full_s` how long our slice's memory `full avg10` has been above [`OURS_FULL_LIMIT`]. Either reaching its
/// limit evicts the newest job over its grant (its reservation), else the newest job.
pub fn throttle_actions(
    over_high_s: Option<u64>,
    ours_full_s: Option<u64>,
    running: &[RunningJob],
) -> Vec<Action> {
    let over_high = over_high_s.is_some_and(|s| s >= OVER_HIGH_FOR_S);
    let full = ours_full_s.is_some_and(|s| s >= OURS_FULL_FOR_S);
    if !(over_high || full) {
        return vec![];
    }
    let victim = newest(running.iter().filter(|r| r.current_mib > r.reserve_mib))
        .or_else(|| newest(running.iter()));
    victim
        .map(|r| vec![Action::Evict(r.id.clone())])
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Priority;
    use crate::testkit::{machine, running};

    #[test]
    fn static_ceilings_per_profile() {
        // [D] pure
        assert_eq!(static_ceiling(Profile::Dedicated, 65536), 65536 - 3072);
        assert_eq!(static_ceiling(Profile::Workstation, 32768), 32768 - 8192);
        assert_eq!(static_ceiling(Profile::Workstation, 4096), 0);
    }

    #[test]
    fn lowering_moves_high_at_once_and_max_by_one_step() {
        // [D] pure
        let w = cap_step(20_000, 20_512, 10_000, STEP_MIB);
        assert_eq!(
            w,
            CapWrite {
                high: 10_000,
                max: 20_512 - 1024,
                order: CapOrder::LowerHighFirst
            }
        );
        // The last step stops at target + 512.
        let w = cap_step(10_000, 11_000, 10_000, STEP_MIB);
        assert_eq!((w.high, w.max), (10_000, 10_512));
    }

    #[test]
    fn raising_moves_max_first() {
        // [D] pure
        let w = cap_step(10_000, 10_512, 14_000, STEP_MIB);
        assert_eq!(
            w,
            CapWrite {
                high: 14_000,
                max: 14_512,
                order: CapOrder::RaiseMaxFirst
            }
        );
    }

    #[test]
    fn cap_target_follows_the_formula() {
        // [D] pure
        assert_eq!(
            cap_target(6000, 10_000, 4096, 1536, 30_000),
            6000 + 10_000 - 4096 - 1536
        );
        assert_eq!(cap_target(6000, 10_000, 0, 2048, 9000), 9000);
        assert_eq!(cap_target(0, 1000, 4096, 1536, 9000), 0);
    }

    #[test]
    fn dedicated_ladder_levels() {
        // [D] pure: each threshold ± 1 (floor 2048).
        let lim = Limits::for_profile(Profile::Dedicated, 32768, 16);
        let at = |avail: u64, psi: f64| {
            let mut m = machine(Profile::Dedicated);
            m.mem_available_mib = avail;
            m.psi.mem_some10 = psi;
            ladder_level(&m, &lim)
        };
        assert_eq!(at(2048 + 2048, 0.0), Level::Normal);
        assert_eq!(at(2048 + 2047, 0.0), Level::Tight);
        assert_eq!(at(2048 + 1024, 0.0), Level::Tight);
        assert_eq!(at(2048 + 1023, 0.0), Level::Pressure);
        assert_eq!(at(2048, 0.0), Level::Pressure);
        assert_eq!(at(2047, 0.0), Level::Danger);
        assert_eq!(at(20_000, 10.0), Level::Normal);
        assert_eq!(at(20_000, 11.0), Level::Tight);
        assert_eq!(at(20_000, 20.0), Level::Tight);
        assert_eq!(at(20_000, 21.0), Level::Pressure);
        assert_eq!(at(20_000, 40.0), Level::Pressure);
        assert_eq!(at(20_000, 41.0), Level::Danger);
    }

    #[test]
    fn workstation_ladder_levels() {
        // [D] pure: reserve 4096 + floor 1536.
        let lim = Limits::for_profile(Profile::Workstation, 32768, 16);
        let at = |avail: u64, psi: f64, app: f64| {
            let mut m = machine(Profile::Workstation);
            m.mem_available_mib = avail;
            m.psi.mem_some10 = psi;
            m.psi.app_mem_some10 = Some(app);
            ladder_level(&m, &lim)
        };
        let base = 4096 + 1536;
        assert_eq!(at(base + 2048, 0.0, 0.0), Level::Normal);
        assert_eq!(at(base + 2047, 0.0, 0.0), Level::Tight);
        assert_eq!(at(base, 0.0, 0.0), Level::Tight);
        assert_eq!(at(base - 1, 0.0, 0.0), Level::Danger);
        assert_eq!(at(20_000, 2.5, 0.0), Level::Tight);
        assert_eq!(at(20_000, 0.0, 1.5), Level::Tight);
        assert_eq!(at(20_000, 0.0, 5.0), Level::Tight);
        assert_eq!(at(20_000, 0.0, 5.1), Level::Danger);
    }

    fn jobs() -> Vec<RunningJob> {
        let mut long = running("long", Priority::P5, 100, 4096, 2000);
        long.long_build = true;
        let mut long4 = running("long4", Priority::P4, 150, 4096, 2000);
        long4.long_build = true;
        let mut short_old = running("short-old", Priority::P5, 200, 512, 512);
        short_old.expected.minutes = 2.0;
        let mut short_new = running("short-new", Priority::P5, 300, 512, 512);
        short_new.expected.minutes = 3.0;
        let mut short4 = running("short4", Priority::P4, 400, 512, 512);
        short4.expected.minutes = 1.0;
        let tests = running("tests", Priority::P5, 500, 512, 512); // 10 minutes: neither
        vec![long, long4, short_old, short_new, short4, tests]
    }

    #[test]
    fn dedicated_ladder_actions() {
        // [D] pure
        let r = jobs();
        let d = Profile::Dedicated;
        assert!(ladder_actions(Level::Normal, d, &r, 0, None).is_empty());
        assert_eq!(
            ladder_actions(Level::Tight, d, &r, 0, None),
            [Action::StopAdmitting]
        );
        let id = |s: &str| JobId(s.into());
        assert_eq!(
            ladder_actions(Level::Pressure, d, &r, 9, None),
            [
                Action::StopAdmitting,
                Action::Pause(id("long")),
                Action::Evict(id("short-old")),
                Action::Evict(id("short-new")),
            ]
        );
        // No relief for 10 s: danger, one eviction a tick, lowest priority and newest first.
        let danger = [Action::StopAdmitting, Action::Evict(id("tests"))];
        assert_eq!(ladder_actions(Level::Pressure, d, &r, 10, None), danger);
        assert_eq!(ladder_actions(Level::Danger, d, &r, 0, None), danger);
    }

    #[test]
    fn workstation_kills_newest_every_5s_and_never_pauses() {
        // [D] pure
        let r = jobs();
        let w = Profile::Workstation;
        let kill = [Action::StopAdmitting, Action::Kill(JobId("tests".into()))];
        assert_eq!(ladder_actions(Level::Danger, w, &r, 0, None), kill);
        assert_eq!(
            ladder_actions(Level::Danger, w, &r, 3, Some(4)),
            [Action::StopAdmitting]
        );
        assert_eq!(ladder_actions(Level::Danger, w, &r, 5, Some(5)), kill);
        for level in [Level::Tight, Level::Pressure] {
            assert_eq!(
                ladder_actions(level, w, &r, 60, None),
                [Action::StopAdmitting]
            );
        }
        for level in [Level::Normal, Level::Tight, Level::Pressure, Level::Danger] {
            let acts = ladder_actions(level, w, &r, 60, None);
            assert!(!acts.iter().any(|a| matches!(a, Action::Pause(_))));
        }
    }

    #[test]
    fn a_throttled_job_is_resolved_within_20s() {
        // [D] pure: over MemoryHigh for 10 s, or our slice's full pressure over 50 % for 10 s, evicts the newest job
        // over its grant.
        let mut r = jobs();
        r[2].current_mib = 900; // short-old, over its 512 reservation
        let id = JobId("short-old".into());
        assert!(throttle_actions(None, None, &r).is_empty());
        assert!(throttle_actions(Some(9), Some(9), &r).is_empty());
        assert_eq!(
            throttle_actions(Some(OVER_HIGH_FOR_S), None, &r),
            [Action::Evict(id.clone())]
        );
        assert_eq!(
            throttle_actions(None, Some(OURS_FULL_FOR_S), &r),
            [Action::Evict(id)]
        );
        r[2].current_mib = 100;
        assert_eq!(
            throttle_actions(None, Some(30), &r),
            [Action::Evict(JobId("tests".into()))],
            "none over its grant: the newest"
        );
        assert!(throttle_actions(Some(60), None, &[]).is_empty());
    }
}
