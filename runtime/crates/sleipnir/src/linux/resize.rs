//! Live resizing: the moves a scheduler makes on a running job that never throttle it. A job near its memory cap
//! grows when the machine has room ([`grow`]); running P4–P5 jobs yield CPU while P1–P2 jobs wait for it
//! ([`weights`]); a long build pauses at the ladder's pressure level on a dedicated machine ([`pause`]).
//!
//! A cap changes through podman and the container's systemd scope (`podman update`, then `set-property --runtime`
//! on the scope, or the other way round for a shrink, so the scope never sits below its container): never by writing
//! cgroup files behind systemd. A shrink below what the container uses now is refused, never forced.

use super::{run, slices};
use forseti::backfill::Reservation as HeadReservation;
use forseti::{Budget, JobId, MachineState, Need, Priority};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

/// A job grows once its container uses more than this share of its cap, in percent.
pub const GROW_AT_PCT: u64 = 85;
/// A grow adds a quarter of the cap, at least this much, never past the job's maximum nor the room there is.
pub const GROW_MIN_STEP_MIB: u64 = 256;
/// The CPU weight of a running P4–P5 job while P1–P2 jobs wait for CPU.
pub const WEIGHT_YIELD: u32 = 20;
/// Every other job's CPU weight: systemd's default.
pub const WEIGHT_NORMAL: u32 = 100;

const MIB: u64 = 1024 * 1024;

/// A running job's memory, as a resize reads it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sized {
    pub job: JobId,
    /// Its container.
    pub container: String,
    /// The machine it runs on.
    pub machine: String,
    pub cap_mib: u64,
    /// The container's `memory.current`.
    pub current_mib: u64,
    /// The most its spec allows (`mem_mib.max`).
    pub max_mib: u64,
}

/// One change of a running job's memory cap.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Resize {
    pub job: JobId,
    pub container: String,
    pub from_mib: u64,
    pub to_mib: u64,
}

impl Resize {
    pub fn grows(&self) -> bool {
        self.to_mib > self.from_mib
    }

    /// What a grow adds (0 for a shrink).
    pub fn delta_mib(&self) -> u64 {
        self.to_mib.saturating_sub(self.from_mib)
    }
}

/// The head's reserved start ([`forseti::backfill`]) as a grow on its machine must leave it: the head's need, and
/// the budget its machine will have at its start.
#[derive(Clone, Debug, PartialEq)]
pub struct Head {
    pub machine: String,
    pub need: Need,
    pub at: Budget,
}

impl Head {
    /// The head of reservation R, which needs NEED, on R's machine M: M's budget now is NOW_BUDGET, and ENDS holds
    /// the running jobs' expected ends.
    pub fn of(
        r: &HeadReservation,
        need: Need,
        m: &MachineState,
        now_budget: &Budget,
        ends: &HashMap<JobId, u64>,
    ) -> Head {
        Head {
            machine: r.machine.clone(),
            need,
            at: forseti::budget_at(m, now_budget, ends, r.at),
        }
    }
}

/// The grow of JOB, when its container uses more than [`GROW_AT_PCT`] of its cap: a quarter of the cap (at least
/// [`GROW_MIN_STEP_MIB`]), never past its maximum, the room in BUDGET (the machine's now) or, on the head's machine,
/// what the head still needs at its start (HEAD: what the grow adds is taken from the budget there). None: no grow.
pub fn grow(job: &Sized, budget: &Budget, head: Option<&Head>) -> Option<Resize> {
    if job.current_mib.saturating_mul(100) <= job.cap_mib.saturating_mul(GROW_AT_PCT) {
        return None;
    }
    let mut room = budget.mem_mib;
    if let Some(h) = head.filter(|h| h.machine == job.machine) {
        room = room.min(h.at.mem_mib - h.need.mem_mib as i64);
    }
    let step = (job.cap_mib / 4)
        .max(GROW_MIN_STEP_MIB)
        .min(job.max_mib.saturating_sub(job.cap_mib))
        .min(room.max(0) as u64);
    (step > 0).then(|| Resize {
        job: job.job.clone(),
        container: job.container.clone(),
        from_mib: job.cap_mib,
        to_mib: job.cap_mib + step,
    })
}

/// The shrink of JOB to TO_MIB: refused when the container uses more than that now, or when it is no shrink.
pub fn shrink(job: &Sized, to_mib: u64) -> Result<Resize, String> {
    if to_mib >= job.cap_mib {
        return Err(format!(
            "{}: {to_mib} MiB is no shrink of its {} MiB cap",
            job.container, job.cap_mib
        ));
    }
    if to_mib < job.current_mib {
        return Err(below_use(&job.container, job.current_mib, to_mib));
    }
    Ok(Resize {
        job: job.job.clone(),
        container: job.container.clone(),
        from_mib: job.cap_mib,
        to_mib,
    })
}

fn below_use(container: &str, current_mib: u64, to_mib: u64) -> String {
    format!(
        "{container} uses {current_mib} MiB: its cap never comes below its use ({to_mib} MiB asked)"
    )
}

/// The CPU weight of each running job (its slice or unit, its priority): [`WEIGHT_YIELD`] for P4–P5 while P1–P2
/// jobs wait for CPU (WAITING_P12), [`WEIGHT_NORMAL`] otherwise, so a weight comes back once they no longer wait.
pub fn weights(running: &[(String, Priority)], waiting_p12: bool) -> Vec<(String, u32)> {
    running
        .iter()
        .map(|(unit, p)| {
            let yields = waiting_p12 && matches!(p, Priority::P4 | Priority::P5);
            (
                unit.clone(),
                if yields { WEIGHT_YIELD } else { WEIGHT_NORMAL },
            )
        })
        .collect()
}

/// Sets UNIT's CPU weight for this boot.
pub fn set_weight(unit: &str, weight: u32) -> Result<(), String> {
    slices::set(unit, &[("CPUWeight", weight.to_string())])
}

fn podman(args: &[&str]) -> Result<String, String> {
    let out = run::limited(Path::new("podman"), args, &[], run::SYSTEMCTL_LIMIT)?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        Err(format!(
            "podman {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

/// The cgroup directory of container NAME, from its process's `/proc/<pid>/cgroup`.
pub fn container_cgroup(name: &str) -> Result<PathBuf, String> {
    let pid = podman(&["inspect", "--format", "{{.State.Pid}}", name])?;
    let pid: u32 = pid
        .parse()
        .ok()
        .filter(|p| *p > 0)
        .ok_or_else(|| format!("{name} is not running"))?;
    let text = fs::read_to_string(format!("/proc/{pid}/cgroup"))
        .map_err(|e| format!("{name}'s cgroup: {e}"))?;
    let rel = text
        .lines()
        .find_map(|l| l.strip_prefix("0::"))
        .ok_or_else(|| format!("{name}'s process has no cgroup v2 line"))?;
    Ok(Path::new("/sys/fs/cgroup").join(rel.trim().trim_start_matches('/')))
}

/// The systemd scope that holds the cgroup CG (CG itself, or its nearest ancestor named `*.scope`).
pub fn scope_of(cg: &Path) -> Option<String> {
    cg.ancestors()
        .filter_map(|p| p.file_name()?.to_str())
        .find(|n| n.ends_with(".scope"))
        .map(str::to_string)
}

/// The `memory.current` of the cgroup CG, in MiB (rounded up).
pub fn current_mib(cg: &Path) -> Result<u64, String> {
    let f = cg.join("memory.current");
    let v = fs::read_to_string(&f).map_err(|e| format!("{}: {e}", f.display()))?;
    v.trim()
        .parse::<u64>()
        .map(|b| b.div_ceil(MIB))
        .map_err(|e| format!("{}: {e}", f.display()))
}

/// Carries R out on its container: a grow raises the scope first, then the container; a shrink lowers the container
/// first, and only while it uses no more than the new cap.
pub fn apply(r: &Resize) -> Result<(), String> {
    let cg = container_cgroup(&r.container)?;
    let scope = scope_of(&cg).ok_or_else(|| {
        format!(
            "{}'s cgroup has no systemd scope: {}",
            r.container,
            cg.display()
        )
    })?;
    if !r.grows() {
        let now = current_mib(&cg)?;
        if r.to_mib < now {
            return Err(below_use(&r.container, now, r.to_mib));
        }
    }
    let m = format!("{}M", r.to_mib);
    let scope_cap = || slices::set(&scope, &[("MemoryMax", m.clone())]);
    let container_cap =
        || podman(&["update", "--memory", &m, "--memory-swap", &m, &r.container]).map(|_| ());
    if r.grows() {
        scope_cap()?;
        container_cap()
    } else {
        container_cap()?;
        scope_cap()
    }
}

/// Pauses container NAME (`podman pause`: the cgroup freezer).
pub fn pause(name: &str) -> Result<(), String> {
    podman(&["pause", name]).map(|_| ())
}

/// Lets container NAME run again.
pub fn unpause(name: &str) -> Result<(), String> {
    podman(&["unpause", name]).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use forseti::{Expected, Profile, Psi, RunningJob};

    fn sized(cap: u64, current: u64, max: u64) -> Sized {
        Sized {
            job: JobId("a3f".into()),
            container: "drgnx-run-a3f".into(),
            machine: "desk".into(),
            cap_mib: cap,
            current_mib: current,
            max_mib: max,
        }
    }

    fn room(mem_mib: i64) -> Budget {
        Budget { mem_mib, cpu: 4.0 }
    }

    fn to(r: Option<Resize>) -> Option<u64> {
        r.map(|r| r.to_mib)
    }

    /// [D] pure. A grow comes only past 85 % of the cap and only into room there is: the step is a quarter of the cap
    /// (at least 256 MiB), cut to the job's maximum, the machine's budget and, on the head's machine, what the head
    /// still needs at its reserved start, which comes from `budget_at` there.
    #[test]
    fn grow_at_85_percent_with_room_only() {
        let lots = room(100_000);
        // at 85 % exactly, nothing; past it, a quarter of the cap
        assert_eq!(grow(&sized(4000, 3400, 8000), &lots, None), None);
        assert_eq!(to(grow(&sized(4000, 3401, 8000), &lots, None)), Some(5000));
        // a small cap steps by 256 MiB
        assert_eq!(to(grow(&sized(512, 500, 8000), &lots, None)), Some(768));
        // never past the job's maximum; at it, no grow
        assert_eq!(to(grow(&sized(4000, 3900, 4500), &lots, None)), Some(4500));
        assert_eq!(grow(&sized(4000, 3900, 4000), &lots, None), None);
        // only into room there is: some room, a smaller grow; none, or less than none, no grow
        assert_eq!(
            to(grow(&sized(4000, 3900, 8000), &room(300), None)),
            Some(4300)
        );
        assert_eq!(grow(&sized(4000, 3900, 8000), &room(0), None), None);
        assert_eq!(grow(&sized(4000, 3900, 8000), &room(-500), None), None);
        let r = grow(&sized(4000, 3900, 8000), &lots, None).unwrap();
        assert_eq!(
            (r.from_mib, r.delta_mib(), r.grows(), r.container.as_str()),
            (4000, 1000, true, "drgnx-run-a3f")
        );
        // the head's reservation: its machine has 7,000 at its start and it needs 6,600, so 400 may go
        let mut m = MachineState {
            name: "desk".into(),
            profile: Profile::Dedicated,
            now: 1_000_000,
            boot_id: "b".into(),
            mem_total_mib: 32768,
            mem_available_mib: 10_000,
            psi: Psi::default(),
            disk_free_gb: 100,
            disk_total_gb: 200,
            on_ac: true,
            last_start: None,
            running: vec![],
            features: vec![],
            reachable: true,
            others: vec![],
        };
        let ending = RunningJob {
            id: JobId("r1".into()),
            priority: Priority::P4,
            started: m.now - 1000,
            reserve_mib: 2000,
            current_mib: 2000,
            cores: 1,
            expected: Expected {
                minutes: 10.0,
                cpu: 1.0,
                mem_p95_mib: Some(2000),
            },
            restartable: true,
            evicted_once: false,
            long_build: false,
        };
        m.running = vec![ending];
        let r = HeadReservation {
            job: JobId("big".into()),
            priority: Priority::P3,
            machine: "desk".into(),
            at: m.now + 600,
        };
        let ends: HashMap<JobId, u64> = [(JobId("r1".into()), m.now + 600)].into();
        let need = |mem_mib| Need { mem_mib, cpu: 1.0 };
        let now_budget = room(5000);
        // r1 gives its 2,000 back by the head's start: 7,000 then
        let head = Head::of(&r, need(6600), &m, &now_budget, &ends);
        assert_eq!(head.at.mem_mib, 7000);
        assert_eq!(
            to(grow(&sized(4000, 3900, 8000), &now_budget, Some(&head))),
            Some(4400)
        );
        // a head that needs all of it leaves nothing to grow into, though there is room now
        let tight = Head::of(&r, need(7000), &m, &now_budget, &ends);
        assert_eq!(
            grow(&sized(4000, 3900, 8000), &now_budget, Some(&tight)),
            None
        );
        // the head on another machine holds nothing here
        let elsewhere = Head {
            machine: "other".into(),
            ..tight.clone()
        };
        assert_eq!(
            to(grow(
                &sized(4000, 3900, 8000),
                &now_budget,
                Some(&elsewhere)
            )),
            Some(5000)
        );
        // a shrink below what the container uses is refused, never forced; to its use or above, it is a shrink
        let job = sized(4000, 3000, 8000);
        assert!(shrink(&job, 2999).is_err());
        assert!(shrink(&job, 4000).is_err(), "no shrink");
        let s = shrink(&job, 3000).unwrap();
        assert_eq!((s.to_mib, s.grows(), s.delta_mib()), (3000, false, 0));
    }

    /// [D] pure. While P1–P2 jobs wait for CPU, the running P4–P5 jobs drop to weight 20 and the others keep 100;
    /// once nothing of P1–P2 waits, every one is back at 100.
    #[test]
    fn weights_drop_while_p12_wait_and_restore() {
        let running: Vec<(String, Priority)> = [
            ("w-a.slice", Priority::P1),
            ("w-b.slice", Priority::P3),
            ("w-c.slice", Priority::P4),
            ("w-d.slice", Priority::P5),
        ]
        .iter()
        .map(|(u, p)| (u.to_string(), *p))
        .collect();
        let w = |waiting| -> Vec<u32> { weights(&running, waiting).iter().map(|x| x.1).collect() };
        assert_eq!(w(true), [100, 100, 20, 20]);
        assert_eq!(w(false), [100, 100, 100, 100]);
        assert_eq!(
            weights(&running, true)
                .iter()
                .map(|x| x.0.as_str())
                .collect::<Vec<_>>(),
            ["w-a.slice", "w-b.slice", "w-c.slice", "w-d.slice"]
        );
        assert!(weights(&[], true).is_empty());
    }

    /// [D] The scope of a container's cgroup: the cgroup itself or the scope above it (crun may add a child).
    #[test]
    fn the_scope_is_found_above_the_container() {
        let base = Path::new("/sys/fs/cgroup/user.slice/t-work-a.slice");
        assert_eq!(
            scope_of(&base.join("libpod-abc.scope")).as_deref(),
            Some("libpod-abc.scope")
        );
        assert_eq!(
            scope_of(&base.join("libpod-abc.scope/container")).as_deref(),
            Some("libpod-abc.scope")
        );
        assert_eq!(scope_of(base), None);
    }
}
