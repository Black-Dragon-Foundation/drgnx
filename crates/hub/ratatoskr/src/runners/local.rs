//! This machine as a runner (docs/develop/hub.md, "Runners: the queue"; design §6.8.1, Calls 6 and 7): in process,
//! with `forseti`'s admission instead of a fixed number of slots.
//!
//! - **Linux** ([`Admission::Live`]): `forseti::admit` over `sleipnir::linux::probe` (memory, pressure, disk, power,
//!   the other schedulers' reservations) under the `workstation` profile, and a reservation of its own per job in the
//!   reservation protocol, as scheduler `drgnx-hub`.
//! - **A macOS hub** ([`Admission::Fixed`]): `Limits::fixed_slots(4)`, admission by count.
//!
//! A probe that can't read the machine falls back to the fixed count, saying so once. The user's servers (no time
//! box) never come here: they start at once and count only in the memory the probe reads.
//!
//! The laptop is a light runner (§4.8, [`local_limits`]): the workstation profile with light jobs only, 2 GiB kept for
//! its user and the app gate; its ladder ([`LocalRunner::ladder`]) evicts our newest job when the machine is in
//! danger, and its disk guard is a runner's ([`LocalRunner::disk_pass`]: the same register, `plan` and `apply`, in
//! process, over the hub's job folder).

use forseti::disk::{DiskReport, DiskRules, Evicted, Pins};
use forseti::{
    Expected, Grant, Job, LastStart, Limits, MachineState, Priority, Profile, Psi, RunningJob,
    WaitReason,
};
use sleipnir::sync::guard;
use sleipnir::sync::register::Register;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// The scheduler name of the hub's own reservations.
pub const SCHEDULER: &str = "drgnx-hub";
/// The slots of a hub that admits by count.
pub const FIXED_SLOTS: u32 = 4;
/// The memory the laptop keeps for its user, MiB.
pub const LOCAL_RESERVE_MIB: u64 = 2048;
/// How long one disk pass here may size items: it runs under the queue's lock.
const MEASURE_BUDGET: std::time::Duration = std::time::Duration::from_millis(200);

/// This machine's limits: the workstation profile's, light jobs only, [`LOCAL_RESERVE_MIB`] for its user.
pub fn local_limits(mem_total_mib: u64, cores: u32) -> Limits {
    Limits {
        light_only: true,
        reserve_user_mib: LOCAL_RESERVE_MIB,
        ..Limits::for_profile(Profile::Workstation, mem_total_mib, cores)
    }
}

/// The ladder on M under LIMITS (the workstation's: no pauses): the ids of our jobs to stop and requeue now.
/// LAST_KILL_AGO is how long ago it last stopped one (none yet: `None`); it does again every 5 s while danger holds.
pub fn ladder_on(m: &MachineState, limits: &Limits, last_kill_ago: Option<u64>) -> Vec<String> {
    let level = forseti::ladder_level(m, limits);
    forseti::ladder_actions(level, Profile::Workstation, &m.running, 0, last_kill_ago)
        .into_iter()
        .filter_map(|a| match a {
            forseti::Action::Kill(id) | forseti::Action::Evict(id) => Some(id.0),
            _ => None,
        })
        .collect()
}

/// One disk pass over REG at NOW: the plan for DF's reading and PINS, carried out with the pins' active items as what
/// is in use (re-checked before each removal), DF re-read for the floor and IO for the pacing. What it did.
pub fn pass_on(
    reg: &mut Register,
    df: &mut dyn FnMut() -> villa::Result<guard::Df>,
    pins: &Pins,
    now: u64,
    io: &mut dyn FnMut() -> f64,
) -> Vec<Evicted> {
    let rules = DiskRules::standard();
    let Ok(first) = df() else {
        return vec![];
    };
    let items = reg.items();
    let ours = items.iter().map(|i| i.bytes).sum();
    let plan = guard::plan(first, ours, &items, pins, &rules, now);
    guard::apply(
        reg,
        &plan,
        &|id| pins.active.contains(id),
        df,
        io,
        &rules,
        &mut |e| match &e.refused {
            None => tracing::info!(
                "runners: the disk guard removed {} ({})",
                e.id,
                e.why.text()
            ),
            Some(why) => tracing::info!("runners: the disk guard kept {}: {why}", e.id),
        },
    )
}

/// How this machine admits jobs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Admission {
    /// By its live state (Linux).
    Live,
    /// By count: at most this many jobs at once.
    Fixed(u32),
}

impl Default for Admission {
    /// Live on Linux, else four slots.
    fn default() -> Admission {
        if cfg!(target_os = "linux") {
            Admission::Live
        } else {
            Admission::Fixed(FIXED_SLOTS)
        }
    }
}

/// The hub's own machine.
pub struct LocalRunner {
    admission: Admission,
    #[cfg(target_os = "linux")]
    probe: Option<sleipnir::linux::probe::Probe>,
    warned: AtomicBool,
    /// The jobs' folder: its file system is the disk the guard keeps.
    root: PathBuf,
    /// When the ladder last stopped a job (seconds since the epoch; 0: never).
    last_kill: AtomicU64,
}

impl LocalRunner {
    /// This machine, admitting by ADMISSION; its jobs' disk is FOLDER's filesystem.
    pub fn new(admission: Admission, folder: &Path) -> LocalRunner {
        #[cfg(target_os = "linux")]
        let probe = match admission {
            Admission::Live => sleipnir::linux::probe::Probe::system(
                "local",
                SCHEDULER,
                SCHEDULER,
                folder,
                Profile::Workstation,
            )
            .map_err(|e| tracing::warn!("runners: this machine's probe: {e}"))
            .ok(),
            Admission::Fixed(_) => None,
        };
        LocalRunner {
            admission,
            #[cfg(target_os = "linux")]
            probe,
            warned: AtomicBool::new(false),
            root: folder.to_path_buf(),
            last_kill: AtomicU64::new(0),
        }
    }

    /// The ladder here at NOW with RUNNING (the queue's jobs here, the last started at LAST): the jobs to stop and
    /// requeue (`Ticked::evict`). Only a machine admitted live has one; by count there is nothing to read.
    pub fn ladder(&self, running: &[RunningJob], last: LastStart, now: u64) -> Vec<String> {
        #[cfg(target_os = "linux")]
        if let (Admission::Live, Some(p)) = (self.admission, &self.probe) {
            let cores = p.cpus_usable().map(|c| c.len() as u32).unwrap_or(1);
            let Ok(mem) = p.memory() else {
                return vec![];
            };
            let limits = local_limits(mem.total_mib, cores);
            let Ok(mut m) = p.machine(now, &limits) else {
                return vec![];
            };
            m.running = running.to_vec();
            m.last_start = last.at;
            let at = self.last_kill.load(Ordering::Relaxed);
            let ago = (at > 0).then(|| now.saturating_sub(at));
            let out = ladder_on(&m, &limits, ago);
            if !out.is_empty() {
                self.last_kill.store(now.max(1), Ordering::Relaxed);
            }
            return out;
        }
        let _only_when_used_elsewhere = (&running, &last, &now, &self.last_kill);
        vec![]
    }

    /// The disk guard here at NOW with PINS: the register over the jobs' folder reconciled and sized, a pass, and the
    /// report the hub's disk register takes, with what the pass did. Only a machine admitted live keeps its disk this
    /// way; none when the folder's register or file system can't be read.
    pub fn disk_pass(&self, pins: &Pins, now: u64) -> Option<(DiskReport, Vec<Evicted>)> {
        if self.admission != Admission::Live {
            return None;
        }
        let mut reg = Register::open(&self.root).ok()?;
        reg.reconcile();
        reg.measure(MEASURE_BUDGET);
        let root = self.root.clone();
        let mut read = || guard::df(&root).map_err(|e| villa::Error::io(format!("statvfs: {e}")));
        let mut io = || self.io_full10(now);
        let done = pass_on(&mut reg, &mut read, pins, now, &mut io);
        let df = read().ok()?;
        let items = reg.items();
        let report = DiskReport {
            free: df.avail,
            total: df.total,
            ours: items.iter().map(|i| i.bytes).sum(),
            quota: None,
            btrfs_unallocated: None,
            classes: forseti::disk::classes(&items, now, pins, &DiskRules::standard()),
            changed: items,
            gone: reg.take_gone(),
        };
        Some((report, done))
    }

    /// IO `full avg10` here now, for the guard's pacing; 0 when it can't be read.
    fn io_full10(&self, now: u64) -> f64 {
        #[cfg(target_os = "linux")]
        if let Some(p) = &self.probe
            && let Ok(m) = p.machine(now, &local_limits(0, 1))
        {
            return m.psi.io_full10;
        }
        let _only_when_used_elsewhere = &now;
        0.0
    }

    pub fn admission(&self) -> Admission {
        self.admission
    }

    /// How many jobs this machine takes at once, as the machines list shows it: the count, or live the workstation
    /// profile's threads (the CPUs usable less the user's four); the fallback count when the probe can't say.
    pub fn slots(&self) -> usize {
        if let Admission::Fixed(n) = self.admission {
            return n as usize;
        }
        #[cfg(target_os = "linux")]
        if let Some(Ok(cpus)) = self.probe.as_ref().map(|p| p.cpus_usable()) {
            return Limits::for_profile(Profile::Workstation, 0, cpus.len() as u32).cores_usable
                as usize;
        }
        FIXED_SLOTS as usize
    }

    /// Whether JOB may start here now (EFF its effective priority, EXP what its history here expects, RUNNING the
    /// queue's jobs running here, LAST their last start): its grant, or why it waits.
    pub fn admit(
        &self,
        job: &Job,
        eff: Priority,
        exp: &Expected,
        running: &[RunningJob],
        last: LastStart,
        now: u64,
    ) -> Result<Grant, WaitReason> {
        if let Admission::Fixed(n) = self.admission {
            return admit_on(
                job,
                eff,
                exp,
                &counted(running, last, now),
                &Limits::fixed_slots(n),
            );
        }
        #[cfg(target_os = "linux")]
        if let Some(p) = &self.probe {
            match self.live(p, job, eff, exp, running, last, now) {
                Ok(r) => return r,
                Err(e) => self.warn(&format!("this machine's probe failed ({e})")),
            }
        }
        if self.probe_missing() {
            self.warn("this machine has no probe");
        }
        admit_on(
            job,
            eff,
            exp,
            &counted(running, last, now),
            &Limits::fixed_slots(FIXED_SLOTS),
        )
    }

    #[cfg(target_os = "linux")]
    fn probe_missing(&self) -> bool {
        self.probe.is_none()
    }

    #[cfg(not(target_os = "linux"))]
    fn probe_missing(&self) -> bool {
        false
    }

    fn warn(&self, what: &str) {
        if !self.warned.swap(true, Ordering::Relaxed) {
            tracing::warn!(
                "runners: {what}: jobs here are admitted by count ({FIXED_SLOTS} at once)"
            );
        }
    }

    /// Admission on the live machine, and the job's reservation once admitted, under the admission lock.
    #[cfg(target_os = "linux")]
    #[allow(clippy::too_many_arguments)]
    fn live(
        &self,
        p: &sleipnir::linux::probe::Probe,
        job: &Job,
        eff: Priority,
        exp: &Expected,
        running: &[RunningJob],
        last: LastStart,
        now: u64,
    ) -> std::io::Result<Result<Grant, WaitReason>> {
        let cores = p.cpus_usable().map(|c| c.len() as u32).unwrap_or(1);
        let reservations = p.reservations();
        reservations.with_admit_lock(|| {
            let mem = p.memory()?;
            let limits = local_limits(mem.total_mib, cores);
            let mut m = p.machine(now, &limits)?;
            m.running = running.to_vec();
            m.last_start = last.at;
            m.last_start_small = last.small;
            let verdict = admit_on(job, eff, exp, &m, &limits);
            if let Ok(g) = &verdict {
                let pid = std::process::id();
                let r = forseti::Reservation {
                    scheduler: SCHEDULER.into(),
                    pid,
                    boot_id: m.boot_id.clone(),
                    start_time: sleipnir::linux::reserve::start_time(pid)?,
                    job: job.id.0.clone(),
                    reserve_mib: g.reserve_mib,
                    current_mib: 0,
                    expires: now + job.spec.timeout_s.max(3600),
                };
                reservations.put(&r)?;
            }
            Ok(verdict)
        })?
    }

    /// This machine now, with RUNNING (the queue's jobs here, the last started at LAST), and its budget, as backfill
    /// reads them; none when it admits by count (there is no budget to reserve) or the probe can't read it.
    pub fn state(
        &self,
        running: &[RunningJob],
        last: LastStart,
        now: u64,
    ) -> Option<(MachineState, forseti::Budget)> {
        #[cfg(target_os = "linux")]
        if let (Admission::Live, Some(p)) = (self.admission, &self.probe) {
            let cores = p.cpus_usable().map(|c| c.len() as u32).unwrap_or(1);
            let limits = local_limits(p.memory().ok()?.total_mib, cores);
            let mut m = p.machine(now, &limits).ok()?;
            m.running = running.to_vec();
            m.last_start = last.at;
            m.last_start_small = last.small;
            let b = forseti::budget(&m, &limits);
            return Some((m, b));
        }
        let _only_when_used_elsewhere = (&running, &last, &now);
        None
    }

    /// Job ID ended here: its reservation goes.
    pub fn release(&self, id: &str) {
        #[cfg(target_os = "linux")]
        if let Some(p) = &self.probe
            && let Err(e) = p.reservations().remove(SCHEDULER, id)
        {
            tracing::debug!("runners: job {id}'s reservation: {e}");
        }
        #[cfg(not(target_os = "linux"))]
        let _only_when_used_elsewhere = &id;
    }
}

/// What a job here uses, in MiB: its SLICE's `memory.current` less its page cache, under the user manager's cgroup
/// MANAGER; none when the slice can't be read (design §0.3 R2).
#[cfg(target_os = "linux")]
pub fn slice_used_mib(manager: &Path, slice: &str) -> Option<u64> {
    let dir = manager.join(sleipnir::linux::probe::slice_path(slice));
    let s = sleipnir::linux::probe::CgroupStat::read(&dir).ok()?;
    Some(s.current.saturating_sub(s.file) >> 20)
}

/// The reader of the hub's own jobs' use the queue counts ([`crate::runners::queue::Queue::read_local_use`]): each
/// job's slice under this process's user manager.
#[cfg(target_os = "linux")]
pub fn local_use() -> crate::runners::queue::LocalUse {
    let manager = own_manager();
    Box::new(move |id| slice_used_mib(&manager, &crate::exec::unit::job_slice_name(id)))
}

/// The cgroup folder of this process's user manager.
#[cfg(target_os = "linux")]
fn own_manager() -> PathBuf {
    let uid = rustix::process::getuid().as_raw();
    let own = crate::fsio::read_to_string("/proc/self/cgroup").unwrap_or_default();
    Path::new("/sys/fs/cgroup").join(sleipnir::linux::probe::manager_cgroup(&own, uid))
}

/// The cgroup folder of local job ID's slice (`drgnx-job-<id>.slice`) under this process's user manager.
#[cfg(target_os = "linux")]
pub fn job_slice_dir(id: &str) -> PathBuf {
    own_manager().join(sleipnir::linux::probe::slice_path(
        &crate::exec::unit::job_slice_name(id),
    ))
}

/// A machine with nothing read but what runs: the count admission's.
fn counted(running: &[RunningJob], last: LastStart, now: u64) -> MachineState {
    MachineState {
        name: "local".into(),
        profile: Profile::Workstation,
        now,
        boot_id: String::new(),
        mem_total_mib: 0,
        mem_available_mib: 0,
        psi: Psi::default(),
        disk_free_gb: 0,
        disk_total_gb: 0,
        disk_unused_gib: 0,
        on_ac: true,
        last_start: last.at,
        last_start_small: last.small,
        running: running.to_vec(),
        features: vec![],
        reachable: true,
        others: vec![],
        island: None,
    }
}

/// `forseti::admit` of JOB on M under LIMITS, and its grant: `forseti::size`'s, or under a fixed count the job's own
/// minimum cores and its memory range. EXP is what the job's history expects (unknown without one).
pub fn admit_on(
    job: &Job,
    eff: Priority,
    exp: &Expected,
    m: &MachineState,
    limits: &Limits,
) -> Result<Grant, WaitReason> {
    let budget = forseti::budget(m, limits);
    forseti::admit(job, eff, exp, m, &budget, limits)?;
    Ok(if limits.fixed_slots.is_some() {
        Grant {
            cores: job.spec.cores.min,
            mem_cap_mib: job.spec.mem_mib.max,
            reserve_mib: job.spec.mem_mib.min,
        }
    } else {
        forseti::size(job, exp, &budget, 1)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runners::queue::blank_spec;
    use forseti::{JobId, JobState};

    fn job() -> Job {
        Job {
            id: JobId("x1".into()),
            spec: blank_spec("x1"),
            own: Priority::P3,
            submitted: 0,
            state: JobState::Queued,
            attempt: 0,
            evicted_once: false,
            disturbed: false,
            blocked_caller: false,
        }
    }

    fn running(id: &str) -> RunningJob {
        RunningJob {
            id: JobId(id.into()),
            priority: Priority::P3,
            started: 0,
            reserve_mib: 512,
            current_mib: 0,
            cores: 1,
            expected: Expected {
                minutes: 10.0,
                cpu: 1.0,
                mem_p95_mib: None,
                io_p95_mbps: None,
            },
            restartable: true,
            evicted_once: false,
            long_build: false,
        }
    }

    // [D] pure: by count, the machines list shows the count
    #[test]
    fn the_local_runner_shows_its_slots() {
        assert_eq!(
            LocalRunner::new(Admission::Fixed(3), Path::new("/")).slots(),
            3
        );
    }

    // [D] pure: by count, the slots; live, the machine's own figures under the workstation profile
    fn unknown() -> Expected {
        Expected {
            minutes: 10.0,
            cpu: 0.0,
            mem_p95_mib: None,
            io_p95_mbps: None,
        }
    }

    #[test]
    fn the_local_runner_admits_by_count_or_by_the_machine() {
        let fixed = LocalRunner::new(Admission::Fixed(2), Path::new("/"));
        let none = LastStart::default();
        let one = [running("a")];
        assert!(
            fixed
                .admit(&job(), Priority::P3, &unknown(), &one, none, 100)
                .is_ok()
        );
        let two = [running("a"), running("b")];
        assert_eq!(
            fixed.admit(&job(), Priority::P3, &unknown(), &two, none, 100),
            Err(WaitReason::Threads)
        );
        let zero = LocalRunner::new(Admission::Fixed(0), Path::new("/"));
        assert_eq!(
            zero.admit(&job(), Priority::P3, &unknown(), &[], none, 100),
            Err(WaitReason::Threads)
        );
        let limits = Limits::for_profile(Profile::Workstation, 32768, 16);
        let mut m = counted(&[], none, 1000);
        m.mem_total_mib = 32768;
        m.mem_available_mib = 16384;
        m.disk_free_gb = 100;
        m.disk_total_gb = 200;
        m.psi.app_mem_some10 = Some(0.0);
        assert!(admit_on(&job(), Priority::P3, &unknown(), &m, &limits).is_ok());
        let mut b = m.clone();
        b.on_ac = false;
        assert_eq!(
            admit_on(&job(), Priority::P3, &unknown(), &b, &limits),
            Err(WaitReason::OnBattery)
        );
        let mut low = m.clone();
        low.mem_available_mib = 4096;
        assert!(matches!(
            admit_on(&job(), Priority::P3, &unknown(), &low, &limits),
            Err(WaitReason::NoRoom { .. })
        ));
        let mut disk = m.clone();
        disk.disk_free_gb = 10;
        assert_eq!(
            admit_on(&job(), Priority::P3, &unknown(), &disk, &limits),
            Err(WaitReason::DiskLow)
        );
    }

    // [D] pure (design §5.3 item 3): a small job right after a small one starts here; after a big one it waits
    #[test]
    fn the_local_runner_skips_the_gap_between_small_jobs() {
        let limits = Limits::for_profile(Profile::Workstation, 32768, 16);
        let small = Expected {
            minutes: 1.0,
            cpu: 1.0,
            mem_p95_mib: Some(300),
            io_p95_mbps: None,
        };
        let mut m = counted(
            &[],
            LastStart {
                at: Some(999),
                small: true,
            },
            1000,
        );
        m.mem_total_mib = 32768;
        m.mem_available_mib = 16384;
        m.disk_free_gb = 100;
        m.disk_total_gb = 200;
        m.psi.app_mem_some10 = Some(0.0);
        assert!(admit_on(&job(), Priority::P3, &small, &m, &limits).is_ok());
        m.last_start_small = false;
        assert_eq!(
            admit_on(&job(), Priority::P3, &small, &m, &limits),
            Err(WaitReason::Gap { secs: 9 })
        );
    }

    /// The laptop's machine at NOW with room: 32 GiB, 16 GiB available, 100 GB free, quiet apps.
    fn laptop(now: u64) -> MachineState {
        let mut m = counted(&[], LastStart::default(), now);
        m.mem_total_mib = 32768;
        m.mem_available_mib = 16384;
        m.disk_free_gb = 100;
        m.disk_total_gb = 200;
        m.psi.app_mem_some10 = Some(0.0);
        m
    }

    /// [D] pure (§4.8): the laptop as a runner takes a light job and holds a heavy one (`Mode`).
    #[test]
    fn the_laptop_runner_takes_light_jobs_only() {
        let limits = local_limits(32768, 16);
        assert!(limits.light_only);
        let m = laptop(1000);
        assert!(admit_on(&job(), Priority::P3, &unknown(), &m, &limits).is_ok());
        let mut heavy = job();
        heavy.spec.weight = forseti::Weight::Heavy;
        assert_eq!(
            admit_on(&heavy, Priority::P3, &unknown(), &m, &limits),
            Err(WaitReason::Mode)
        );
    }

    /// [D] pure: the laptop keeps 2 GiB for its user (a job that would take it waits), and the app gate holds every
    /// job while the user's apps are under pressure.
    #[test]
    fn the_laptop_keeps_2_gb_and_holds_on_app_pressure() {
        let limits = local_limits(32768, 16);
        assert_eq!(limits.reserve_user_mib, 2048);
        let mut m = laptop(1000);
        // floor 1536 + the user's 2048 + the job's 512: room at 4200, none at 3900
        m.mem_available_mib = 4200;
        assert!(admit_on(&job(), Priority::P3, &unknown(), &m, &limits).is_ok());
        m.mem_available_mib = 3900;
        assert!(matches!(
            admit_on(&job(), Priority::P3, &unknown(), &m, &limits),
            Err(WaitReason::NoRoom { .. })
        ));
        let mut apps = laptop(1000);
        apps.psi.app_mem_some10 = Some(3.0);
        assert!(matches!(
            admit_on(&job(), Priority::P3, &unknown(), &apps, &limits),
            Err(WaitReason::Pressure { .. })
        ));
    }

    /// [D] pure (old Task 28 L1): tight holds and stops nothing; in danger (below the user's 2 GiB and the floor, or
    /// the apps above 5 %) our newest job is stopped and requeued, again only after 5 s.
    #[test]
    fn the_local_runner_runs_the_ladder() {
        let limits = local_limits(32768, 16);
        let mut m = laptop(1000);
        let mut old = running("old");
        old.started = 10;
        let mut new = running("new");
        new.started = 20;
        m.running = vec![old, new];
        assert!(ladder_on(&m, &limits, None).is_empty(), "normal");
        m.mem_available_mib = 2048 + 1536 + 1000;
        assert!(
            ladder_on(&m, &limits, None).is_empty(),
            "tight stops nothing"
        );
        m.mem_available_mib = 2048 + 1536 - 1;
        assert_eq!(ladder_on(&m, &limits, None), vec!["new".to_string()]);
        assert!(
            ladder_on(&m, &limits, Some(2)).is_empty(),
            "not again within 5 s"
        );
        assert_eq!(ladder_on(&m, &limits, Some(5)), vec!["new".to_string()]);
        let mut apps = laptop(1000);
        apps.running = m.running.clone();
        apps.psi.app_mem_some10 = Some(6.0);
        assert_eq!(ladder_on(&apps, &limits, None), vec!["new".to_string()]);
    }

    /// [D] deletion safety: the laptop's pass below the floor removes an idle build dir past its age and never one in
    /// use, a young one, a folder the register doesn't hold, or anything outside the root.
    #[test]
    fn the_local_disk_pass_never_removes_what_is_in_use() {
        use forseti::disk::{DiskItem, ItemKind};
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("root");
        let outside = t.path().join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        crate::fsio::write(outside.join("keep"), b"x").unwrap();
        let now = 10 * 86_400;
        let mut reg = Register::open(&root).unwrap();
        for (rel, used) in [("idle", 0), ("busy", 0), ("young", now - 60)] {
            let dir = root.join("slots-target").join(rel);
            std::fs::create_dir_all(&dir).unwrap();
            crate::fsio::write(dir.join("f"), b"bytes").unwrap();
            let item = DiskItem {
                id: format!("build:{rel}"),
                kind: ItemKind::BuildDir,
                owner: "p".into(),
                machine: String::new(),
                bytes: guard::GB,
                last_used: used,
                created: used,
                name: None,
                budget_bytes: None,
                trust: forseti::JobTrust::Private,
            };
            reg.add(item, &Path::new("slots-target").join(rel)).unwrap();
        }
        std::fs::create_dir_all(root.join("stray")).unwrap();
        let mut pins = Pins::default();
        pins.active.insert("build:busy".into());
        // below the floor throughout: every past-age item not in use is planned and removed
        let mut df = || {
            Ok(guard::Df {
                total: 1000 * guard::GB,
                avail: 10 * guard::GB,
            })
        };
        let done = pass_on(&mut reg, &mut df, &pins, now, &mut || 0.0);
        let removed: Vec<&str> = done
            .iter()
            .filter(|e| e.refused.is_none())
            .map(|e| e.id.as_str())
            .collect();
        assert_eq!(removed, vec!["build:idle"]);
        assert!(!root.join("slots-target/idle").exists());
        assert!(root.join("slots-target/busy/f").exists());
        assert!(root.join("slots-target/young/f").exists());
        assert!(root.join("stray").exists());
        assert!(outside.join("keep").exists());
    }
}
