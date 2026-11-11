//! Admission on the runner: an `offer` is judged by `forseti::admit` against the machine as it is now, under the
//! machine's admission lock, and an admitted attempt's reservation is written before the lock is let go, so two
//! schedulers (two hubs, a hub and jobq) never both fit into the same memory. A running job's grow ([`grow`]) is
//! judged and held the same way.

use super::platform::Platform;
use crate::linux::reserve::Reservation;
use crate::linux::resize::{self, Head, Resize, Sized};
use forseti::{
    Expected, Grant, Job, JobId, JobSpec, JobState, Limits, MachineState, Priority, RunningJob,
    WaitReason,
};

/// How long past its timeout an attempt's reservation counts, should nothing remove it.
pub const RESERVATION_SLACK_S: u64 = 600;

/// Why an offer is refused: the text for the hub's log, and `forseti`'s reason when it gave one.
#[derive(Clone, Debug, PartialEq)]
pub struct Refused {
    pub why: String,
    pub reason: Option<WaitReason>,
}

impl Refused {
    fn wait(reason: WaitReason) -> Refused {
        Refused {
            why: format!("{reason:?}"),
            reason: Some(reason),
        }
    }

    pub fn because(why: impl Into<String>) -> Refused {
        Refused {
            why: why.into(),
            reason: None,
        }
    }
}

/// The reservation name of attempt ATTEMPT of job ID.
pub fn reservation_job(id: &str, attempt: u32) -> String {
    format!("{id}-{attempt}")
}

/// An unknown job's expected figures: ten minutes at its grant's cores, no memory history.
pub fn unknown(spec: &JobSpec) -> Expected {
    Expected {
        minutes: 10.0,
        cpu: f64::from(spec.cores.min),
        mem_p95_mib: None,
    }
}

/// What is offered.
pub struct Offer<'a> {
    pub id: &'a str,
    pub attempt: u32,
    pub spec: &'a JobSpec,
    pub priority: Priority,
    pub expected: Option<Expected>,
}

/// Admits OFFER on the machine of PLATFORM at NOW under LIMITS for SCHEDULER, whose running jobs are OURS and whose
/// last start was LAST_START. Under the machine's admission lock it reads the machine (the others' live reservations
/// included), asks `forseti::admit`, sizes the grant and writes the reservation, held by this process (PID with its
/// start time) until the attempt's job-exec takes it over.
pub fn admit(
    probe: &dyn Platform,
    limits: &Limits,
    scheduler: &str,
    ours: &[RunningJob],
    last_start: Option<u64>,
    now: u64,
    offer: &Offer,
) -> Result<Grant, Refused> {
    let rs = probe.reservations();
    rs.with_admit_lock(|| {
        let mut m = probe
            .machine(now, limits)
            .map_err(|e| Refused::because(format!("the machine can't be read: {e}")))?;
        m.running = ours.to_vec();
        m.last_start = last_start;
        let budget = forseti::budget(&m, limits);
        let job = Job {
            id: JobId(offer.id.to_string()),
            spec: offer.spec.clone(),
            own: offer.priority,
            submitted: now,
            state: JobState::Queued,
            attempt: offer.attempt,
            evicted_once: false,
            disturbed: false,
            blocked_caller: false,
        };
        let exp = offer.expected.unwrap_or_else(|| unknown(offer.spec));
        forseti::admit(&job, offer.priority, &exp, &m, &budget, limits).map_err(Refused::wait)?;
        let grant = forseti::size(&job, &exp, &budget, 1);
        let pid = std::process::id();
        let start_time = probe
            .start_time(pid)
            .map_err(|e| Refused::because(format!("this process's start time: {e}")))?;
        rs.put(&Reservation {
            scheduler: scheduler.to_string(),
            pid,
            boot_id: m.boot_id.clone(),
            start_time,
            job: reservation_job(offer.id, offer.attempt),
            reserve_mib: grant.reserve_mib,
            current_mib: 0,
            expires: now + offer.spec.timeout_s + RESERVATION_SLACK_S,
        })
        .map_err(|e| Refused::because(format!("the reservation can't be written: {e}")))?;
        Ok(grant)
    })
    .map_err(|e| Refused::because(format!("the admission lock: {e}")))?
}

/// A running job's grow, as [`grow`] takes it: the job, its reservation's name, and the hub's head reservation on
/// this machine when its `head` frame told one.
pub struct Grow {
    pub job: Sized,
    pub reservation: String,
    pub head: Option<HeadHere>,
}

/// The hub's head reserved on this machine (its `head` frame): what the head needs, and when it is to start.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HeadHere {
    pub need: forseti::Need,
    pub at: u64,
}

impl HeadHere {
    /// The head as a grow on M must leave it: M's budget at the head's start, from BUDGET (M's now) and OURS' expected
    /// ends ([`forseti::budget_at`]).
    pub fn on(&self, m: &MachineState, budget: &forseti::Budget, ours: &[RunningJob]) -> Head {
        let ends = ours
            .iter()
            .map(|rj| {
                let end = forseti::expected_end(rj.started, rj.expected.minutes * 60.0);
                (rj.id.clone(), end)
            })
            .collect();
        Head {
            machine: m.name.clone(),
            need: self.need,
            at: forseti::budget_at(m, budget, &ends, self.at),
        }
    }
}

/// Grows G's job when [`resize::grow`] says so, under the machine's admission lock: the budget is the machine's as
/// it is now (the others' live reservations and OURS counted), APPLY carries the grow out, and the job's reservation
/// (held by SCHEDULER) then holds the share it added, so no scheduler admits into it. None: no grow; a grow APPLY
/// couldn't carry out leaves the reservation as it was.
pub fn grow(
    probe: &dyn Platform,
    limits: &Limits,
    scheduler: &str,
    ours: &[RunningJob],
    now: u64,
    g: &Grow,
    apply: impl FnOnce(&Resize) -> Result<(), String>,
) -> Result<Option<Resize>, Refused> {
    let rs = probe.reservations();
    rs.with_admit_lock(|| {
        let mut m = probe
            .machine(now, limits)
            .map_err(|e| Refused::because(format!("the machine can't be read: {e}")))?;
        m.running = ours.to_vec();
        let budget = forseti::budget(&m, limits);
        let head = g.head.map(|h| h.on(&m, &budget, ours));
        let Some(r) = resize::grow(&g.job, &budget, head.as_ref()) else {
            return Ok(None);
        };
        let mut held = rs
            .read(scheduler, &g.reservation)
            .map_err(|e| Refused::because(format!("the job's reservation: {e}")))?;
        apply(&r).map_err(Refused::because)?;
        held.reserve_mib += r.delta_mib();
        rs.put(&held)
            .map_err(|e| Refused::because(format!("the reservation can't be written: {e}")))?;
        Ok(Some(r))
    })
    .map_err(|e| Refused::because(format!("the admission lock: {e}")))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::linux::probe::Probe;
    use crate::linux::reserve::{self, Reservations};
    use crate::serve::platform::LinuxPlatform;

    /// The Linux platform on the fixture machine P.
    fn lp(p: &Probe) -> LinuxPlatform {
        LinuxPlatform::from_probe(p.clone())
    }
    use forseti::{Expect, JobTrust, Kind, Lane, Profile, PsiLimits, Range, Weight};
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::mpsc;
    use std::time::Duration;

    fn spec(mem_min: u64) -> JobSpec {
        JobSpec {
            name: "t".into(),
            kind: Kind::Test,
            weight: Weight::Light,
            suite: None,
            tree: PathBuf::from("/src/p"),
            cwd: PathBuf::from("."),
            command: vec!["true".into()],
            select: None,
            needs: vec![],
            inputs_extra: vec![],
            inputs_outside: vec![],
            features: vec![],
            cores: Range { min: 1, max: 2 },
            mem_mib: Range {
                min: mem_min,
                max: mem_min * 2,
            },
            disk_gib: 0,
            timeout_s: 600,
            restartable: true,
            writes_tree: false,
            priority: None,
            for_user: None,
            gate: None,
            expect: Expect::default(),
            outputs: vec![],
            state: vec![],
            on: None,
            lane: Lane::Work,
            fresh: false,
            stop_on_red: false,
            project: "p".into(),
            trust: JobTrust::Private,
            keys: vec![],
            local_only: false,
            writes: vec![],
        }
    }

    /// A machine of fixture files under D: 8 GiB available, no pressure, its own boot id; this process's `/proc`
    /// entry is the real one, so the reservation it writes counts as alive.
    fn probe(d: &Path) -> Probe {
        let proc_root = d.join("proc");
        fs::create_dir_all(proc_root.join("pressure")).unwrap();
        fs::create_dir_all(proc_root.join("sys/kernel/random")).unwrap();
        fs::write(
            proc_root.join("meminfo"),
            "MemTotal: 16777216 kB\nMemAvailable: 8388608 kB\n",
        )
        .unwrap();
        for what in ["memory", "cpu", "io"] {
            fs::write(
                proc_root.join("pressure").join(what),
                "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
            )
            .unwrap();
        }
        fs::write(proc_root.join("sys/kernel/random/boot_id"), "b00t\n").unwrap();
        let me = std::process::id();
        std::os::unix::fs::symlink(format!("/proc/{me}"), proc_root.join(me.to_string())).unwrap();
        fs::create_dir_all(d.join("sys")).unwrap();
        fs::create_dir_all(d.join("run")).unwrap();
        Probe {
            name: "runner".into(),
            proc_root,
            sys_root: d.join("sys"),
            manager: d.join("manager"),
            runtime_dir: d.join("run"),
            folder: d.to_path_buf(),
            slice_root: "t".into(),
            scheduler: "drgnx-hubA".into(),
            profile: Profile::Dedicated,
        }
    }

    fn limits() -> Limits {
        Limits {
            floor_mib: 1024,
            reserve_user_mib: 0,
            reserve_user_threads: 0,
            cores_usable: 8,
            psi: PsiLimits {
                mem_some10: 10.0,
                cpu_some10: 40.0,
                io_full10: 10.0,
                app_mem_some10: None,
            },
            disk_guard_gb: 0,
            disk_guard_pct: 0,
            overcommit: 1.0,
            no_jobs_on_battery: false,
            fixed_slots: None,
        }
    }

    /// [B] through the gate: the admission lock is the gate. While another holder has it, an offer's admission waits
    /// and writes nothing; once it is free the offer is admitted and its reservation is on file with the grant's
    /// reserve, so another scheduler's next admission counts it and is refused for room.
    #[test]
    fn admit_runs_under_the_lock_and_reserves() {
        let d = tempfile::tempdir().unwrap();
        let p = probe(d.path());
        let rs = Reservations::at(&p.runtime_dir);
        let (tx, rx) = mpsc::channel();
        let p2 = p.clone();
        let s = spec(4096);
        rs.with_admit_lock(|| {
            let s = s.clone();
            std::thread::spawn(move || {
                let offer = Offer {
                    id: "a1",
                    attempt: 1,
                    spec: &s,
                    priority: Priority::P3,
                    expected: None,
                };
                tx.send(admit(
                    &lp(&p2),
                    &limits(),
                    "drgnx-hubA",
                    &[],
                    None,
                    1000,
                    &offer,
                ))
                .unwrap();
            });
            skuld::window(
                Duration::from_millis(300),
                "the admission returns while the lock is held",
            );
            assert!(rx.try_recv().is_err(), "admitted inside another's lock");
            assert!(
                rs.read_others("nobody").is_empty(),
                "a reservation inside another's lock"
            );
        })
        .unwrap();
        let grant = skuld::wait_until("the admission", 30, || rx.try_recv().ok()).unwrap();
        assert!(grant.reserve_mib >= 4096, "{grant:?}");
        let on_file = rs.read_others("nobody");
        assert_eq!(on_file.len(), 1, "{on_file:?}");
        let r = &on_file[0];
        assert_eq!(
            (r.scheduler.as_str(), r.job.as_str(), r.reserve_mib, r.pid),
            ("drgnx-hubA", "a1-1", grant.reserve_mib, std::process::id())
        );
        // another hub on the same machine counts it: 8 GiB − 1 GiB floor − the 4 GiB held leaves no room for 4 GiB
        let mut other = p.clone();
        other.scheduler = "drgnx-hubB".into();
        let offer = Offer {
            id: "b1",
            attempt: 1,
            spec: &s,
            priority: Priority::P3,
            expected: None,
        };
        let refused = admit(
            &lp(&other),
            &limits(),
            "drgnx-hubB",
            &[],
            None,
            1000,
            &offer,
        )
        .unwrap_err();
        assert!(
            matches!(
                refused.reason,
                Some(WaitReason::NoRoom { need_mib: 4096, .. })
            ),
            "{refused:?}"
        );
        // and a smaller job still fits
        let small = spec(1024);
        let offer = Offer {
            spec: &small,
            ..offer
        };
        assert!(
            admit(
                &lp(&other),
                &limits(),
                "drgnx-hubB",
                &[],
                None,
                1000,
                &offer
            )
            .is_ok()
        );
    }

    /// [D] A grow is judged under the admission lock against the machine as it is, then held: once applied, the job's
    /// reservation carries what it added, so the next admission counts it. A grow its apply can't carry out leaves the
    /// reservation as it was, and with another scheduler holding the room there is no grow.
    #[test]
    fn a_grow_holds_its_share_in_the_reservation() {
        let d = tempfile::tempdir().unwrap();
        let p = probe(d.path());
        let rs = Reservations::at(&p.runtime_dir);
        let s = spec(2048);
        let offer = Offer {
            id: "a1",
            attempt: 1,
            spec: &s,
            priority: Priority::P3,
            expected: None,
        };
        let grant = admit(&lp(&p), &limits(), "drgnx-hubA", &[], None, 1000, &offer).unwrap();
        assert_eq!((grant.mem_cap_mib, grant.reserve_mib), (4096, 2048));
        // long past its start, it uses 3,600 of its 4,096 cap
        let now = 5000;
        let ours = [RunningJob {
            id: JobId("a1".into()),
            priority: Priority::P3,
            started: 1000,
            reserve_mib: 2048,
            current_mib: 3600,
            cores: 1,
            expected: unknown(&s),
            restartable: true,
            evicted_once: false,
            long_build: false,
        }];
        let g = Grow {
            job: Sized {
                job: JobId("a1".into()),
                container: "drgnx-run-a1".into(),
                machine: "runner".into(),
                cap_mib: 4096,
                current_mib: 3600,
                max_mib: 8192,
            },
            reservation: reservation_job("a1", 1),
            head: None,
        };
        let held = || rs.read_others("nobody")[0].reserve_mib;
        let grown = grow(&lp(&p), &limits(), "drgnx-hubA", &ours, now, &g, |_| Ok(())).unwrap();
        assert_eq!(grown.as_ref().map(|r| r.to_mib), Some(5120));
        assert_eq!(held(), 2048 + 1024);
        // an apply that fails holds nothing more
        let failed = grow(&lp(&p), &limits(), "drgnx-hubA", &ours, now, &g, |_| {
            Err("podman update: no".into())
        });
        assert!(failed.unwrap_err().why.contains("podman update"));
        assert_eq!(held(), 3072);
        // another scheduler holds the room: no grow
        rs.put(&Reservation {
            scheduler: "jobq".into(),
            pid: std::process::id(),
            boot_id: "b00t".into(),
            start_time: reserve::start_time(std::process::id()).unwrap(),
            job: "big".into(),
            reserve_mib: 7200,
            current_mib: 0,
            expires: now + 600,
        })
        .unwrap();
        assert_eq!(
            grow(&lp(&p), &limits(), "drgnx-hubA", &ours, now, &g, |_| Ok(())),
            Ok(None)
        );
    }

    /// [D] The hub's head reserved here holds a grow to what the machine will have at the head's start less the head's
    /// need: a head starting before the job's expected end, needing the room, leaves no grow; one starting after it
    /// counts the job's memory back by then, and the job grows.
    #[test]
    fn a_grow_leaves_the_hubs_head_its_room() {
        let d = tempfile::tempdir().unwrap();
        let p = probe(d.path());
        let s = spec(2048);
        let offer = Offer {
            id: "a1",
            attempt: 1,
            spec: &s,
            priority: Priority::P3,
            expected: None,
        };
        admit(&lp(&p), &limits(), "drgnx-hubA", &[], None, 1000, &offer).unwrap();
        // started at 1000, expected to take an hour: it ends at 4600
        let now = 2000;
        let ours = [RunningJob {
            id: JobId("a1".into()),
            priority: Priority::P3,
            started: 1000,
            reserve_mib: 2048,
            current_mib: 3600,
            cores: 1,
            expected: Expected {
                minutes: 60.0,
                ..unknown(&s)
            },
            restartable: true,
            evicted_once: false,
            long_build: false,
        }];
        let grow_with = |head: Option<HeadHere>| {
            let g = Grow {
                job: Sized {
                    job: JobId("a1".into()),
                    container: "drgnx-run-a1".into(),
                    machine: "runner".into(),
                    cap_mib: 4096,
                    current_mib: 3600,
                    max_mib: 8192,
                },
                reservation: reservation_job("a1", 1),
                head,
            };
            grow(&lp(&p), &limits(), "drgnx-hubA", &ours, now, &g, |_| Ok(()))
                .unwrap()
                .map(|r| r.to_mib)
        };
        let head = |at: u64| {
            Some(HeadHere {
                need: forseti::Need {
                    mem_mib: 7500,
                    cpu: 1.0,
                },
                at,
            })
        };
        assert_eq!(grow_with(head(3000)), None);
        assert_eq!(grow_with(head(5000)), Some(5120));
    }

    /// [D] A fake runner shares its host's pressure files and disk, so a test build takes the machine's pressure,
    /// disk and available memory from `test-machine.json` in the runner folder when one is there: a busy, nearly
    /// full host neither refuses nor admits a fleet row's job, and the profile's limits stay as strict as ever.
    #[cfg(feature = "test-hooks")]
    #[test]
    fn a_test_build_takes_the_machine_from_the_facts_file() {
        let d = tempfile::tempdir().unwrap();
        let p = probe(d.path());
        // the host as the desktop was: IO stalled, 44 GB free of 475
        fs::write(
            p.proc_root.join("pressure/io"),
            "some avg10=30.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=28.13 avg60=0.00 avg300=0.00 total=0\n",
        )
        .unwrap();
        let real = Limits::for_profile(Profile::Dedicated, 16384, 8);
        let small = spec(64);
        let offer = |id| Offer {
            id,
            attempt: 1,
            spec: &small,
            priority: Priority::P3,
            expected: None,
        };
        let facts = |json: &str| fs::write(d.path().join("test-machine.json"), json).unwrap();
        let quiet = r#"{"psi": {"mem_some10": 0.0, "cpu_some10": 0.0, "io_full10": 0.0, "app_mem_some10": null},
                        "disk_free_gb": 400, "disk_total_gb": 475, "mem_available_mib": 8192}"#;
        facts(quiet);
        assert_eq!(
            admit(&lp(&p), &real, "drgnx-hubA", &[], None, 1000, &offer("q1")).map(|_| ()),
            Ok(()),
            "the host's pressure or disk reached a test build"
        );
        // the facts are the machine: low disk in them is refused under the profile's floor, as on a real runner
        facts(&quiet.replace("400", "44"));
        assert_eq!(
            admit(&lp(&p), &real, "drgnx-hubA", &[], None, 1000, &offer("q2"))
                .unwrap_err()
                .reason,
            Some(WaitReason::DiskLow)
        );
        // a broken facts file is a loud refusal, never the host's figures
        facts("{");
        let e = admit(&lp(&p), &real, "drgnx-hubA", &[], None, 1000, &offer("q3")).unwrap_err();
        assert!(e.why.contains("test-machine.json"), "{e:?}");
        // and mains power is in them too (the host's `power_supply` may show a battery): a workstation on battery
        // admits nothing
        let ws = Limits::for_profile(Profile::Workstation, 16384, 8);
        // (a workstation reads its user's apps' pressure too)
        let apps = d.path().join("manager/app.slice");
        fs::create_dir_all(&apps).unwrap();
        fs::write(
            apps.join("memory.pressure"),
            "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
        )
        .unwrap();
        let mut wp = p;
        wp.profile = Profile::Workstation;
        facts(&quiet.replace(
            "\"mem_available_mib\": 8192",
            "\"mem_available_mib\": 8192, \"on_ac\": false",
        ));
        let e = admit(&lp(&wp), &ws, "drgnx-hubA", &[], None, 1000, &offer("q4")).unwrap_err();
        assert_eq!(e.reason, Some(WaitReason::OnBattery), "{e:?}");
    }
}
