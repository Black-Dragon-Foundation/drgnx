//! The job model: jobs, machines, verdicts, wait reasons and the machine's limits.
//!
//! Times are `u64` seconds since the epoch, passed in; sizes are MiB unless a name says otherwise.

use std::cmp::Ordering;
use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Deserializer, Serialize};

pub use crate::reserve::Reservation;

/// A job's id, as its scheduler writes it.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct JobId(pub String);

impl fmt::Display for JobId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// A job's priority, 1 to 5. `Ord` puts P1 highest: `Priority::P1 > Priority::P5`, so `max` is the more urgent.
///
/// - 1: a job the user starts or bumps;
/// - 2: fail-fast probes and reruns of fresh reds;
/// - 3: work a blocked agent waits on;
/// - 4: a plan's or gate's bulk;
/// - 5: background work.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Priority {
    P1 = 1,
    P2,
    P3,
    P4,
    P5,
}

impl Priority {
    /// Every priority, highest first.
    pub const ALL: [Priority; 5] = [
        Priority::P1,
        Priority::P2,
        Priority::P3,
        Priority::P4,
        Priority::P5,
    ];

    /// The number, 1 (highest) to 5.
    pub fn number(self) -> u8 {
        self as u8
    }

    /// The priority numbered `n`, clamped into 1–5.
    pub fn from_number(n: u8) -> Priority {
        match n {
            0 | 1 => Priority::P1,
            2 => Priority::P2,
            3 => Priority::P3,
            4 => Priority::P4,
            _ => Priority::P5,
        }
    }
}

impl Ord for Priority {
    fn cmp(&self, other: &Self) -> Ordering {
        other.number().cmp(&self.number())
    }
}

impl PartialOrd for Priority {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// Which lane a job runs in: ordinary work, or a timing run (pinned to `pinned` cores when given).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Lane {
    Work,
    Timing { pinned: Option<u8> },
}

/// Heavy or light. A job is heavy only when it is marked so; [`JobSpec::heavy`] reads it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Weight {
    Heavy,
    Light,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Kind {
    Build,
    Test,
    Check,
    Timing,
    Other,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Build => "build",
            Kind::Test => "test",
            Kind::Check => "check",
            Kind::Timing => "timing",
            Kind::Other => "other",
        }
    }
}

/// An inclusive range a job declares: `[min, max]`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Range<T> {
    pub min: T,
    pub max: T,
}

/// What a test job must show for its result to count: at least `min_ran` rows, at most `max_skipped` skips.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Expect {
    pub min_ran: Option<u32>,
    pub max_skipped: Option<u32>,
}

/// Job trust, computed at submit: `public` (a public project's job whose commit the public origin has), `private`, or
/// `private+keys` (any job that names keys).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum JobTrust {
    Public,
    Private,
    PrivateKeys,
}

/// Runner trust: `mine` gets everything, `my-cloud` private code and only its listed keys, `shared` public code only.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum RunnerTrust {
    Mine,
    MyCloud,
    Shared,
}

/// A machine's profile: `dedicated` (nobody sits at it) or `workstation` (someone's daily machine).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Profile {
    Workstation,
    Dedicated,
}

/// What a job is and what it needs.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct JobSpec {
    pub name: String,
    pub kind: Kind,
    /// Heavy or light: what the send and accept modes and placement read ([`JobSpec::heavy`]).
    pub weight: Weight,
    pub suite: Option<String>,
    pub tree: PathBuf,
    pub cwd: PathBuf,
    pub command: Vec<String>,
    /// The rows a test job selects (an ERT regexp, a cargo filter).
    pub select: Option<String>,
    pub needs: Vec<JobId>,
    pub inputs_extra: Vec<PathBuf>,
    pub inputs_outside: Vec<PathBuf>,
    pub features: Vec<String>,
    pub cores: Range<u32>,
    pub mem_mib: Range<u64>,
    pub disk_gib: u32,
    pub timeout_s: u64,
    pub restartable: bool,
    pub writes_tree: bool,
    /// A priority the starter asked for; the scheduler decides whether it holds.
    pub priority: Option<Priority>,
    /// The user's words when an agent starts a job for the user.
    pub for_user: Option<String>,
    pub gate: Option<String>,
    pub expect: Expect,
    pub outputs: Vec<String>,
    /// Machine-local paths the job holds exclusively (build dirs, cargo targets).
    pub state: Vec<PathBuf>,
    /// The machine the job is pinned to, if any.
    pub on: Option<String>,
    pub lane: Lane,
    pub fresh: bool,
    pub stop_on_red: bool,
    pub project: String,
    pub trust: JobTrust,
    /// The names of the keys the job needs (never values).
    pub keys: Vec<String>,
    /// Pinned to the hub's own machine.
    pub local_only: bool,
    /// The paths the job writes back to the tree.
    pub writes: Vec<String>,
}

impl JobSpec {
    /// Whether the job is marked heavy.
    pub fn heavy(&self) -> bool {
        self.weight == Weight::Heavy
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum JobState {
    Queued,
    Running {
        machine: String,
        since: u64,
        grant: Grant,
    },
    Done(Verdict),
    Cancelled,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Job {
    pub id: JobId,
    pub spec: JobSpec,
    /// The job's own priority, as the scheduler set it at submit.
    pub own: Priority,
    pub submitted: u64,
    pub state: JobState,
    pub attempt: u32,
    pub evicted_once: bool,
    pub disturbed: bool,
    /// A caller (an agent) is blocked on this job.
    pub blocked_caller: bool,
}

/// What a job gets at start: cores, its memory cap, and the memory admission counts for it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Grant {
    pub cores: u32,
    pub mem_cap_mib: u64,
    pub reserve_mib: u64,
}

/// A job's expected time, mean CPU (cores) and p95 peak memory, from history.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Expected {
    pub minutes: f64,
    pub cpu: f64,
    pub mem_p95_mib: Option<u64>,
}

impl Expected {
    /// Whether history stands behind it: CPU and memory come from the same rows, so a known memory figure means a
    /// known CPU figure. An unknown job's CPU counts as its grant.
    pub fn known(&self) -> bool {
        self.mem_p95_mib.is_some()
    }
}

/// Pressure (PSI `avg10`, in percent): system memory and CPU `some`, IO `full`, and the user's apps' memory `some`
/// where the machine has them apart.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Psi {
    pub mem_some10: f64,
    pub cpu_some10: f64,
    pub io_full10: f64,
    pub app_mem_some10: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RunningJob {
    pub id: JobId,
    pub priority: Priority,
    pub started: u64,
    pub reserve_mib: u64,
    pub current_mib: u64,
    /// The cores of its grant: a job with no history counts these in the CPU budget.
    pub cores: u32,
    pub expected: Expected,
    pub restartable: bool,
    pub evicted_once: bool,
    pub long_build: bool,
}

/// One machine as its probe read it at `now`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MachineState {
    pub name: String,
    pub profile: Profile,
    pub now: u64,
    pub boot_id: String,
    pub mem_total_mib: u64,
    pub mem_available_mib: u64,
    pub psi: Psi,
    pub disk_free_gb: u64,
    pub disk_total_gb: u64,
    pub on_ac: bool,
    pub last_start: Option<u64>,
    pub running: Vec<RunningJob>,
    pub features: Vec<String>,
    pub reachable: bool,
    /// Other schedulers' reservations on this machine (jobq's legacy slot reservations among them). The probe drops
    /// those whose process is gone; the budget counts the rest by [`crate::count_others`].
    pub others: Vec<Reservation>,
}

/// How a job ended.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Verdict {
    Pass,
    Red,
    Crash,
    Timeout,
    Oom,
    Evicted,
    Suspect(String),
    /// Not the job's fault: a named reason without the `infra: ` prefix (`runner lost`, `disk`, `oomd/killed`, …).
    Infra(String),
    Cancelled,
    Cached(JobId),
}

impl fmt::Display for Verdict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Verdict::Pass => f.write_str("pass"),
            Verdict::Red => f.write_str("red"),
            Verdict::Crash => f.write_str("crash"),
            Verdict::Timeout => f.write_str("timeout"),
            Verdict::Oom => f.write_str("oom"),
            Verdict::Evicted => f.write_str("evicted"),
            Verdict::Suspect(why) => write!(f, "suspect: {why}"),
            Verdict::Infra(why) => write!(f, "infra: {why}"),
            Verdict::Cancelled => f.write_str("cancelled"),
            Verdict::Cached(from) => write!(f, "cached ({from})"),
        }
    }
}

/// Why a job waits.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum WaitReason {
    Needs(JobId),
    Behind(Priority),
    NoRoom {
        need_mib: u64,
        free_mib: i64,
    },
    HeadProtection(JobId),
    State {
        dir: PathBuf,
        holder: JobId,
    },
    IslandBusy,
    DrainWaits,
    DesktopUnreachable {
        since: u64,
    },
    SpillIn {
        minutes: u32,
    },
    DiskLow,
    OnBattery,
    Pressure {
        #[serde(deserialize_with = "pressure_name")]
        what: PressureName,
        value: f64,
        limit: f64,
    },
    Gap {
        secs: u64,
    },
    Threads,
    /// The trust table forbids every runner that could take it; the text says why.
    Trust(String),
    /// Pinned to a machine that can't take it now.
    Pinned,
    NeedsLogin,
    NeedsKeys,
    CloudCap(String),
    Benched,
    /// The project's send mode or the runner's accept mode keeps it off.
    Mode,
    /// The runner lacks these features.
    Features(Vec<String>),
    /// The starter's `machines` matrix cell keeps it on this machine.
    Matrix,
    /// The runner waits for the user's confirm.
    AwaitingConfirm,
    /// No machine is offered at all.
    NoRunner,
}

/// The pressure names [`WaitReason::Pressure`] carries.
pub const PRESSURE_NAMES: [&str; 4] = ["memory", "cpu", "io", "app memory"];

/// One of [`PRESSURE_NAMES`]. An alias, so serde's derive doesn't borrow the field from its input (which would tie
/// every `WaitReason` read to `'static` input): `pressure_name` maps the text to the static name.
pub type PressureName = &'static str;

fn pressure_name<'de, D: Deserializer<'de>>(d: D) -> Result<PressureName, D::Error> {
    let s = String::deserialize(d)?;
    PRESSURE_NAMES
        .iter()
        .copied()
        .find(|n| *n == s)
        .ok_or_else(|| serde::de::Error::custom(format!("unknown pressure name {s:?}")))
}

/// PSI limits for admission, `avg10` in percent: admission needs each reading below its limit.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct PsiLimits {
    pub mem_some10: f64,
    pub cpu_some10: f64,
    pub io_full10: f64,
    /// The user's apps' memory `some`, on machines that read it apart.
    pub app_mem_some10: Option<f64>,
}

/// A machine's thresholds. [`Limits::for_profile`] gives the design's; jobq fills its own from its configuration.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Limits {
    /// Memory never given out.
    pub floor_mib: u64,
    /// Memory kept for the person at the machine.
    pub reserve_user_mib: u64,
    /// Threads kept for the person at the machine (already taken out of `cores_usable`).
    pub reserve_user_threads: u32,
    pub cores_usable: u32,
    pub psi: PsiLimits,
    /// Disk that stays free: at least `disk_guard_gb` and at least `disk_guard_pct` % of the filesystem.
    pub disk_guard_gb: u64,
    pub disk_guard_pct: u32,
    /// CPU overcommit allowed while the running jobs are mostly idle (1.0: none).
    pub overcommit: f64,
    pub no_jobs_on_battery: bool,
    /// Admission by count only (a hub with no Linux probe): at most this many jobs.
    pub fixed_slots: Option<u32>,
}

impl Limits {
    /// The design's values for a profile (runners design §6.5, jobq §5.4):
    ///
    /// - `dedicated`: floor 2 GiB, no user reserve, every core, PSI limits memory 10 %, CPU 40 %, IO full 10 %,
    ///   overcommit 1.5;
    /// - `workstation`: floor 1.5 GiB, the user's 4 GiB and 4 threads, PSI limits memory 2 %, the user's apps 1 %,
    ///   CPU 20 %, IO full 5 %, no overcommit, no jobs on battery.
    ///
    /// Both keep 20 GB and 10 % of the disk free. `mem_total_mib` isn't read by F1's values.
    pub fn for_profile(profile: Profile, _mem_total_mib: u64, cores: u32) -> Limits {
        match profile {
            Profile::Dedicated => Limits {
                floor_mib: 2048,
                reserve_user_mib: 0,
                reserve_user_threads: 0,
                cores_usable: cores.max(1),
                psi: PsiLimits {
                    mem_some10: 10.0,
                    cpu_some10: 40.0,
                    io_full10: 10.0,
                    app_mem_some10: None,
                },
                disk_guard_gb: 20,
                disk_guard_pct: 10,
                overcommit: 1.5,
                no_jobs_on_battery: false,
                fixed_slots: None,
            },
            Profile::Workstation => Limits {
                floor_mib: 1536,
                reserve_user_mib: 4096,
                reserve_user_threads: 4,
                cores_usable: cores.saturating_sub(4).max(1),
                psi: PsiLimits {
                    mem_some10: 2.0,
                    cpu_some10: 20.0,
                    io_full10: 5.0,
                    app_mem_some10: Some(1.0),
                },
                disk_guard_gb: 20,
                disk_guard_pct: 10,
                overcommit: 1.0,
                no_jobs_on_battery: true,
                fixed_slots: None,
            },
        }
    }

    /// Admission by count: at most `n` jobs at once, with no memory, PSI or disk reading (a macOS hub's own machine).
    pub fn fixed_slots(n: u32) -> Limits {
        Limits {
            floor_mib: 0,
            reserve_user_mib: 0,
            reserve_user_threads: 0,
            cores_usable: n.max(1),
            psi: PsiLimits {
                mem_some10: 100.0,
                cpu_some10: 100.0,
                io_full10: 100.0,
                app_mem_some10: None,
            },
            disk_guard_gb: 0,
            disk_guard_pct: 0,
            overcommit: 1.0,
            no_jobs_on_battery: false,
            fixed_slots: Some(n),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limits_for_profile_match_the_design() {
        // [D] pure
        let d = Limits::for_profile(Profile::Dedicated, 65536, 24);
        assert_eq!(d.floor_mib, 2048);
        assert_eq!(d.reserve_user_mib, 0);
        assert_eq!(d.reserve_user_threads, 0);
        assert_eq!(d.cores_usable, 24);
        assert!(!d.no_jobs_on_battery);
        assert_eq!(d.overcommit, 1.5);
        assert_eq!((d.disk_guard_gb, d.disk_guard_pct), (20, 10));
        assert_eq!(d.fixed_slots, None);

        let w = Limits::for_profile(Profile::Workstation, 32768, 16);
        assert_eq!(w.reserve_user_mib, 4096);
        assert_eq!(w.reserve_user_threads, 4);
        assert_eq!(w.cores_usable, 12);
        assert!(w.no_jobs_on_battery);
        assert_eq!(w.overcommit, 1.0);
        assert_eq!(w.psi.app_mem_some10, Some(1.0));

        let f = Limits::fixed_slots(4);
        assert_eq!(f.fixed_slots, Some(4));
    }

    #[test]
    fn priority_orders_p1_highest() {
        // [D] pure
        assert!(Priority::P1 > Priority::P2);
        assert_eq!(Priority::P3.max(Priority::P5), Priority::P3);
        assert_eq!(Priority::from_number(4).number(), 4);
    }

    #[test]
    fn a_wait_reason_round_trips_through_json() {
        // [D] pure
        let r = WaitReason::Pressure {
            what: "memory",
            value: 12.0,
            limit: 10.0,
        };
        let s = serde_json::to_string(&r).unwrap();
        assert_eq!(serde_json::from_str::<WaitReason>(&s).unwrap(), r);
        let bad = s.replace("memory", "swap");
        assert!(serde_json::from_str::<WaitReason>(&bad).is_err());
    }
}
