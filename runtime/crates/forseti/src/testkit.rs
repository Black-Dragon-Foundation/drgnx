//! Fixtures for the unit tests: a plain job and its pieces. No machine's real values appear here.

use std::path::PathBuf;

use crate::model::*;

pub(crate) fn spec(name: &str) -> JobSpec {
    JobSpec {
        os: Default::default(),
        name: name.into(),
        kind: Kind::Test,
        weight: Weight::Light,
        suite: None,
        tree: PathBuf::from("/src/project"),
        cwd: PathBuf::from("."),
        command: vec!["make".into(), "check".into()],
        select: None,
        needs: vec![],
        inputs_extra: vec![],
        inputs_outside: vec![],
        features: vec![],
        cores: Range { min: 1, max: 4 },
        mem_mib: Range {
            min: 1024,
            max: 4096,
        },
        disk_gib: 1,
        timeout_s: 1200,
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
        project: "alpha".into(),
        trust: JobTrust::Private,
        keys: vec![],
        local_only: false,
        writes: vec![],
    }
}

pub(crate) fn job(name: &str, own: Priority, submitted: u64) -> Job {
    Job {
        id: JobId(name.into()),
        spec: spec(name),
        own,
        submitted,
        state: JobState::Queued,
        attempt: 1,
        evicted_once: false,
        disturbed: false,
        blocked_caller: false,
    }
}

/// A quiet machine at `now = 1_000_000`: 32 GiB with 24,000 MiB available, no pressure, on AC, 500 of 1,000 GB free.
pub(crate) fn machine(profile: Profile) -> MachineState {
    MachineState {
        name: "m".into(),
        profile,
        now: 1_000_000,
        boot_id: "boot-a".into(),
        mem_total_mib: 32768,
        mem_available_mib: 24_000,
        psi: Psi::default(),
        disk_free_gb: 500,
        disk_total_gb: 1000,
        on_ac: true,
        last_start: None,
        running: vec![],
        features: vec![],
        reachable: true,
        others: vec![],
    }
}

/// A running job granted 4 cores that uses 1 on average and is expected to take 10 minutes.
pub(crate) fn running(
    name: &str,
    priority: Priority,
    started: u64,
    reserve_mib: u64,
    current_mib: u64,
) -> RunningJob {
    RunningJob {
        id: JobId(name.into()),
        priority,
        started,
        reserve_mib,
        current_mib,
        cores: 4,
        expected: expected_min(10.0),
        restartable: true,
        evicted_once: false,
        long_build: false,
    }
}

pub(crate) fn expected_min(minutes: f64) -> Expected {
    Expected {
        minutes,
        cpu: 1.0,
        mem_p95_mib: Some(1024),
    }
}
