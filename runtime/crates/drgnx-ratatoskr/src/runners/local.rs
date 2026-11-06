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

use forseti::{
    Expected, Grant, Job, Limits, MachineState, Priority, Profile, Psi, RunningJob, WaitReason,
};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

/// The scheduler name of the hub's own reservations.
pub const SCHEDULER: &str = "drgnx-hub";
/// The slots of a hub that admits by count.
pub const FIXED_SLOTS: u32 = 4;

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
        #[cfg(not(target_os = "linux"))]
        let _ = folder;
        LocalRunner {
            admission,
            #[cfg(target_os = "linux")]
            probe,
            warned: AtomicBool::new(false),
        }
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

    /// Whether JOB may start here now (EFF its effective priority, RUNNING the queue's jobs running here, LAST_START
    /// when the last of them started): its grant, or why it waits.
    pub fn admit(
        &self,
        job: &Job,
        eff: Priority,
        running: &[RunningJob],
        last_start: Option<u64>,
        now: u64,
    ) -> Result<Grant, WaitReason> {
        if let Admission::Fixed(n) = self.admission {
            return admit_on(
                job,
                eff,
                &counted(running, last_start, now),
                &Limits::fixed_slots(n),
            );
        }
        #[cfg(target_os = "linux")]
        if let Some(p) = &self.probe {
            match self.live(p, job, eff, running, last_start, now) {
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
            &counted(running, last_start, now),
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
    fn live(
        &self,
        p: &sleipnir::linux::probe::Probe,
        job: &Job,
        eff: Priority,
        running: &[RunningJob],
        last_start: Option<u64>,
        now: u64,
    ) -> std::io::Result<Result<Grant, WaitReason>> {
        let cores = p.cpus_usable().map(|c| c.len() as u32).unwrap_or(1);
        let reservations = p.reservations();
        reservations.with_admit_lock(|| {
            let mem = p.memory()?;
            let limits = Limits::for_profile(Profile::Workstation, mem.total_mib, cores);
            let mut m = p.machine(now, &limits)?;
            m.running = running.to_vec();
            m.last_start = last_start;
            let verdict = admit_on(job, eff, &m, &limits);
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

    /// Job ID ended here: its reservation goes.
    pub fn release(&self, id: &str) {
        #[cfg(target_os = "linux")]
        if let Some(p) = &self.probe
            && let Err(e) = p.reservations().remove(SCHEDULER, id)
        {
            tracing::debug!("runners: job {id}'s reservation: {e}");
        }
        #[cfg(not(target_os = "linux"))]
        let _ = id;
    }
}

/// A machine with nothing read but what runs: the count admission's.
fn counted(running: &[RunningJob], last_start: Option<u64>, now: u64) -> MachineState {
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
        on_ac: true,
        last_start,
        running: running.to_vec(),
        features: vec![],
        reachable: true,
        others: vec![],
    }
}

/// `forseti::admit` of JOB on M under LIMITS, and its grant: `forseti::size`'s, or under a fixed count the job's own
/// minimum cores and its memory range.
pub fn admit_on(
    job: &Job,
    eff: Priority,
    m: &MachineState,
    limits: &Limits,
) -> Result<Grant, WaitReason> {
    let exp = Expected {
        minutes: forseti::history::DEFAULT_MINUTES,
        cpu: f64::from(job.spec.cores.min),
        mem_p95_mib: None,
    };
    let budget = forseti::budget(m, limits);
    forseti::admit(job, eff, &exp, m, &budget, limits)?;
    Ok(if limits.fixed_slots.is_some() {
        Grant {
            cores: job.spec.cores.min,
            mem_cap_mib: job.spec.mem_mib.max,
            reserve_mib: job.spec.mem_mib.min,
        }
    } else {
        forseti::size(job, &exp, &budget, 1)
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
    #[test]
    fn the_local_runner_admits_by_count_or_by_the_machine() {
        let fixed = LocalRunner::new(Admission::Fixed(2), Path::new("/"));
        let one = [running("a")];
        assert!(fixed.admit(&job(), Priority::P3, &one, None, 100).is_ok());
        let two = [running("a"), running("b")];
        assert_eq!(
            fixed.admit(&job(), Priority::P3, &two, None, 100),
            Err(WaitReason::Threads)
        );
        let zero = LocalRunner::new(Admission::Fixed(0), Path::new("/"));
        assert_eq!(
            zero.admit(&job(), Priority::P3, &[], None, 100),
            Err(WaitReason::Threads)
        );
        let limits = Limits::for_profile(Profile::Workstation, 32768, 16);
        let mut m = counted(&[], None, 1000);
        m.mem_total_mib = 32768;
        m.mem_available_mib = 16384;
        m.disk_free_gb = 100;
        m.disk_total_gb = 200;
        m.psi.app_mem_some10 = Some(0.0);
        assert!(admit_on(&job(), Priority::P3, &m, &limits).is_ok());
        let mut b = m.clone();
        b.on_ac = false;
        assert_eq!(
            admit_on(&job(), Priority::P3, &b, &limits),
            Err(WaitReason::OnBattery)
        );
        let mut low = m.clone();
        low.mem_available_mib = 4096;
        assert!(matches!(
            admit_on(&job(), Priority::P3, &low, &limits),
            Err(WaitReason::NoRoom { .. })
        ));
        let mut disk = m.clone();
        disk.disk_free_gb = 10;
        assert_eq!(
            admit_on(&job(), Priority::P3, &disk, &limits),
            Err(WaitReason::DiskLow)
        );
    }
}
