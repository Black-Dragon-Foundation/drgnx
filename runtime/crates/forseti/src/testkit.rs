//! Fixtures for the unit tests: a plain job and its pieces. No machine's real values appear here.

use std::path::PathBuf;

use crate::model::*;

pub(crate) fn spec(name: &str) -> JobSpec {
    JobSpec {
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

pub(crate) fn expected_min(minutes: f64) -> Expected {
    Expected {
        minutes,
        cpu: 1.0,
        mem_p95_mib: Some(1024),
    }
}
