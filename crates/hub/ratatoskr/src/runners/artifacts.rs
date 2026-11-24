//! The artifact index (`runtime.db` table `artifacts`, migration 14): which artifacts exist, where, and which job is
//! building one. Pure: the queue holds it under its own lock and persists what [`ArtifactIndex::take_changes`] returns.
//!
//! - **One build per key.** [`ArtifactIndex::want`] runs under the queue's lock and answers from the index: present,
//!   building (the consumer waits through `needs`), or create (the caller makes the job). Two consumers of one key
//!   never make two jobs: the second finds the first's `Building` row. The row is written before the lock is released
//!   (lock, then recheck: the check and the insert are one step).
//! - **Roles.** The role is not in the key. A `gate` consumer matches only `gate` rows, so a build an author's run made
//!   (from a tip pack) never serves a gate; a miss makes a gate build of the same key. An `author` consumer matches
//!   either, preferring the gate's. An artifact job takes its consumer's role, so it builds in that role's folder.
//! - **A failed or cancelled build** clears its `Building` row and fails its consumers as infra
//!   ([`failure_text`]), through `needs` as any failed need does; a restart clears every `Building` row whose job is
//!   gone ([`ArtifactIndex::restore`]).

use std::collections::{BTreeMap, BTreeSet};

use forseti::{ArtifactKey, JobId, JobSpec, ProjectId, Role};

/// What a consumer's lookup found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Want {
    /// The artifact exists on RUNNER, built in ROLE.
    Present { runner: String, role: Role },
    /// A job is building it: the consumer needs that job.
    Building { job: JobId },
    /// None exists and none is building: the caller makes this job, and the consumer needs it.
    Create { job: JobId },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Building,
    Present,
}

impl State {
    pub fn name(self) -> &'static str {
        match self {
            State::Building => "building",
            State::Present => "present",
        }
    }

    pub fn from_name(s: &str) -> Option<State> {
        match s {
            "building" => Some(State::Building),
            "present" => Some(State::Present),
            _ => None,
        }
    }
}

/// One row of the table.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub key: ArtifactKey,
    pub role: Role,
    pub project: ProjectId,
    /// `image` or `command`.
    pub kind: String,
    /// The first use that asked for it: `ro`, `seed`, `image` or `toolchain`.
    pub use_: String,
    /// Always none: the registry route is not built.
    pub route: Option<String>,
    /// The runner that holds it (present) or builds it (building, once started).
    pub runner: Option<String>,
    /// The building job.
    pub job: Option<JobId>,
    pub state: State,
    pub size: u64,
    pub made: u64,
    pub last_used: u64,
    /// Why it may not go: each pin's reason.
    pub pins: BTreeSet<String>,
}

/// What changed, for the queue to write.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Change {
    Put(Row),
    Delete(ArtifactKey, Role),
}

/// The text a consumer of a failed artifact ends with (`infra: …` is added where the verdict is shown).
pub fn failure_text(kind: &str, key: &ArtifactKey, job: &JobId) -> String {
    format!("artifact {kind} {} failed (job {job})", short(key))
}

/// The first 12 digits of a key, as every message shows it.
pub fn short(key: &ArtifactKey) -> &str {
    &key.0[..key.0.len().min(12)]
}

/// The id of the job that builds KEY in ROLE: one per `(key, role)`, so a restart finds it again.
pub fn job_id(key: &ArtifactKey, role: Role) -> JobId {
    JobId(format!("art-{}-{}", short(key), role.name()))
}

/// How many failed builds the index remembers by job, for the text their consumers end with.
const LOST_KEPT: usize = 256;

#[derive(Debug, Default)]
pub struct ArtifactIndex {
    rows: BTreeMap<(ArtifactKey, Role), Row>,
    changes: Vec<Change>,
    /// The builds that failed, by job: `(kind, key)`. A consumer that reaches the queue's tick after its artifact's
    /// row is gone still names what failed.
    lost: BTreeMap<JobId, (String, ArtifactKey)>,
}

impl ArtifactIndex {
    /// The index as the database kept it.
    pub fn load(rows: Vec<Row>) -> ArtifactIndex {
        ArtifactIndex {
            rows: rows
                .into_iter()
                .map(|r| ((r.key.clone(), r.role), r))
                .collect(),
            changes: vec![],
            lost: BTreeMap::new(),
        }
    }

    /// What changed since the last call.
    pub fn take_changes(&mut self) -> Vec<Change> {
        std::mem::take(&mut self.changes)
    }

    pub fn rows(&self) -> impl Iterator<Item = &Row> {
        self.rows.values()
    }

    fn put(&mut self, row: Row) {
        self.changes.push(Change::Put(row.clone()));
        self.rows.insert((row.key.clone(), row.role), row);
    }

    /// The artifact KEY for a consumer of ROLE in PROJECT, as KIND for USE_ at NOW.
    pub fn want(
        &mut self,
        key: &ArtifactKey,
        project: &ProjectId,
        role: Role,
        kind: &str,
        use_: &str,
        now: u64,
    ) -> Want {
        // the roles whose rows may serve this consumer, best first
        let order: &[Role] = match role {
            Role::Gate => &[Role::Gate],
            Role::Author => &[Role::Gate, Role::Author],
        };
        let at = |r: Role| (key.clone(), r);
        for r in order {
            if let Some(row) = self.rows.get(&at(*r))
                && row.state == State::Present
                && let Some(runner) = row.runner.clone()
            {
                let mut row = row.clone();
                row.last_used = now;
                self.put(row);
                return Want::Present { runner, role: *r };
            }
        }
        for r in order {
            if let Some(row) = self.rows.get(&at(*r))
                && row.state == State::Building
                && let Some(job) = row.job.clone()
            {
                return Want::Building { job };
            }
        }
        // the recheck above and this insert are one step under the queue's lock
        let job = job_id(key, role);
        self.put(Row {
            key: key.clone(),
            role,
            project: project.clone(),
            kind: kind.to_string(),
            use_: use_.to_string(),
            route: None,
            runner: None,
            job: Some(job.clone()),
            state: State::Building,
            size: 0,
            made: 0,
            last_used: now,
            pins: BTreeSet::new(),
        });
        Want::Create { job }
    }

    /// The artifact job JOB started on RUNNER.
    pub fn running_on(&mut self, job: &JobId, runner: &str) {
        let hit = self
            .rows
            .values()
            .find(|r| r.job.as_ref() == Some(job) && r.state == State::Building)
            .cloned();
        if let Some(mut row) = hit {
            row.runner = Some(runner.to_string());
            self.put(row);
        }
    }

    /// KEY was built in ROLE on RUNNER: SIZE bytes, at NOW.
    pub fn built(&mut self, key: &ArtifactKey, role: Role, runner: &str, size: u64, now: u64) {
        if let Some(row) = self.rows.get(&(key.clone(), role)).cloned() {
            self.put(Row {
                runner: Some(runner.to_string()),
                job: None,
                state: State::Present,
                size,
                made: now,
                last_used: now,
                ..row
            });
        }
    }

    /// KEY's build failed or was cancelled: its `Building` rows go (a present row stays).
    pub fn failed(&mut self, key: &ArtifactKey) {
        let gone: Vec<(ArtifactKey, Role)> = self
            .rows
            .iter()
            .filter(|((k, _), r)| k == key && r.state == State::Building)
            .map(|(id, _)| id.clone())
            .collect();
        for id in gone {
            if let Some(row) = self.rows.remove(&id)
                && let Some(job) = row.job
            {
                self.lost.insert(job, (row.kind, row.key));
            }
            self.changes.push(Change::Delete(id.0, id.1));
        }
        while self.lost.len() > LOST_KEPT {
            let Some(first) = self.lost.keys().next().cloned() else {
                break;
            };
            self.lost.remove(&first);
        }
    }

    /// The artifact JOB builds (or built and failed), as `(kind, key)`: what the failure text names.
    pub fn of_job(&self, job: &JobId) -> Option<(String, ArtifactKey)> {
        self.rows
            .values()
            .find(|r| r.job.as_ref() == Some(job))
            .map(|r| (r.kind.clone(), r.key.clone()))
            .or_else(|| self.lost.get(job).cloned())
    }

    /// Artifact job JOB ended: it passed (the artifact is present on the runner it ran on, SIZE bytes) or it did not
    /// (its build row goes). A job that builds no artifact changes nothing.
    pub fn job_ended(&mut self, job: &JobId, passed: bool, size: u64, now: u64) {
        let Some(row) = self
            .rows
            .values()
            .find(|r| r.job.as_ref() == Some(job) && r.state == State::Building)
            .cloned()
        else {
            return;
        };
        match (passed, row.runner.clone()) {
            (true, Some(runner)) => self.built(&row.key, row.role, &runner, size, now),
            _ => self.failed(&row.key),
        }
    }

    /// KEY was read at NOW (the last-used time the guard's ages read).
    pub fn used(&mut self, key: &ArtifactKey, now: u64) {
        let hit: Vec<Row> = self
            .rows
            .values()
            .filter(|r| &r.key == key && r.state == State::Present)
            .cloned()
            .collect();
        for mut row in hit {
            row.last_used = now;
            self.put(row);
        }
    }

    /// Keeps KEY for WHY (a task's open evidence, the user's pin): the guard never removes a pinned key.
    pub fn pin(&mut self, key: &ArtifactKey, why: &str) {
        let hit: Vec<Row> = self
            .rows
            .values()
            .filter(|r| &r.key == key)
            .cloned()
            .collect();
        for mut row in hit {
            if row.pins.insert(why.to_string()) {
                self.put(row);
            }
        }
    }

    pub fn unpin(&mut self, key: &ArtifactKey, why: &str) {
        let hit: Vec<Row> = self
            .rows
            .values()
            .filter(|r| &r.key == key)
            .cloned()
            .collect();
        for mut row in hit {
            if row.pins.remove(why) {
                self.put(row);
            }
        }
    }

    /// The keys QUEUED jobs use: the guard never removes one.
    pub fn needed(&self, queued: &[JobSpec]) -> BTreeSet<ArtifactKey> {
        queued
            .iter()
            .flat_map(|s| s.artifacts.iter().map(|a| a.key.clone()))
            .collect()
    }

    /// After a hub restart: a `Building` row whose job is not among LIVE_JOBS (it died with the hub) is cleared.
    pub fn restore(&mut self, live_jobs: &[JobId]) {
        let gone: Vec<(ArtifactKey, Role)> = self
            .rows
            .iter()
            .filter(|(_, r)| {
                r.state == State::Building && !r.job.as_ref().is_some_and(|j| live_jobs.contains(j))
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in gone {
            self.rows.remove(&id);
            self.changes.push(Change::Delete(id.0, id.1));
        }
    }

    /// The runner a present KEY is on, for placement affinity, with its size: the bytes a runner lacks without it.
    pub fn present_on(&self, key: &ArtifactKey) -> Option<(String, u64)> {
        [Role::Gate, Role::Author].iter().find_map(|r| {
            self.rows
                .get(&(key.clone(), *r))
                .filter(|row| row.state == State::Present)
                .and_then(|row| row.runner.clone().map(|n| (n, row.size)))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runners::queue::blank_spec;

    fn key(c: char) -> ArtifactKey {
        ArtifactKey(c.to_string().repeat(64))
    }

    fn pid() -> ProjectId {
        ProjectId::default()
    }

    // [D] pure: the second consumer of a key finds the first's building row and waits for its job
    #[test]
    fn two_submits_of_one_key_make_one_job() {
        let mut ix = ArtifactIndex::default();
        let first = ix.want(&key('a'), &pid(), Role::Author, "command", "ro", 1);
        let Want::Create { job } = first else {
            panic!("{first:?}")
        };
        let second = ix.want(&key('a'), &pid(), Role::Author, "command", "ro", 2);
        assert_eq!(second, Want::Building { job });
        assert_eq!(ix.rows().count(), 1);
    }

    // [D] pure: a present artifact is where its runner is, and the index counts what a runner lacks without it
    #[test]
    fn a_present_artifact_gives_affinity() {
        let mut ix = ArtifactIndex::default();
        let Want::Create { job } = ix.want(&key('a'), &pid(), Role::Author, "image", "image", 1)
        else {
            panic!()
        };
        ix.running_on(&job, "r2");
        ix.job_ended(&job, true, 4096, 10);
        assert_eq!(ix.present_on(&key('a')), Some(("r2".into(), 4096)));
        let w = ix.want(&key('a'), &pid(), Role::Author, "image", "image", 11);
        assert_eq!(
            w,
            Want::Present {
                runner: "r2".into(),
                role: Role::Author
            }
        );
        assert_eq!(ix.present_on(&key('b')), None);
    }

    // [D] pure: a build that fails clears its row, so the next consumer builds again; the consumers wait through needs
    #[test]
    fn a_failed_artifact_fails_its_waiters_as_infra() {
        let mut ix = ArtifactIndex::default();
        let Want::Create { job } = ix.want(&key('a'), &pid(), Role::Author, "command", "ro", 1)
        else {
            panic!()
        };
        assert_eq!(ix.of_job(&job), Some(("command".into(), key('a'))));
        ix.running_on(&job, "r1");
        ix.job_ended(&job, false, 0, 5);
        assert_eq!(ix.rows().count(), 0);
        // the consumers still name what failed after its row is gone
        assert_eq!(ix.of_job(&job), Some(("command".into(), key('a'))));
        assert!(matches!(
            ix.want(&key('a'), &pid(), Role::Author, "command", "ro", 6),
            Want::Create { .. }
        ));
        assert_eq!(
            failure_text("command", &key('a'), &job),
            format!("artifact command aaaaaaaaaaaa failed (job {job})")
        );
    }

    // [D] pure: a cancelled build (the job ended without a pass) is a failed one
    #[test]
    fn a_cancelled_artifact_job_fails_its_waiters_as_infra() {
        let mut ix = ArtifactIndex::default();
        let Want::Create { job } = ix.want(&key('c'), &pid(), Role::Gate, "image", "image", 1)
        else {
            panic!()
        };
        // never started on a runner, then cancelled: no pass without a runner
        ix.job_ended(&job, true, 1, 2);
        assert_eq!(
            ix.rows().count(),
            0,
            "a pass that never ran anywhere is no artifact"
        );
    }

    // [D] pure (Review Focus 1, 2): a hub restart clears the building rows whose job is gone, and keeps the live ones
    #[test]
    fn a_building_row_without_its_job_is_cleared_on_restore() {
        let mut ix = ArtifactIndex::default();
        let Want::Create { job: live } =
            ix.want(&key('a'), &pid(), Role::Author, "command", "ro", 1)
        else {
            panic!()
        };
        let Want::Create { job: dead } =
            ix.want(&key('b'), &pid(), Role::Author, "command", "ro", 1)
        else {
            panic!()
        };
        let mut reloaded = ArtifactIndex::load(ix.rows().cloned().collect());
        reloaded.restore(std::slice::from_ref(&live));
        assert_eq!(
            reloaded.want(&key('a'), &pid(), Role::Author, "command", "ro", 2),
            Want::Building { job: live }
        );
        assert_eq!(reloaded.of_job(&dead), None);
    }

    // [D] pure: an author's build never serves a gate; a gate rebuilds under its own role
    #[test]
    fn a_gate_rebuilds_an_artifact_an_author_run_built() {
        let mut ix = ArtifactIndex::default();
        let Want::Create { job } = ix.want(&key('a'), &pid(), Role::Author, "command", "ro", 1)
        else {
            panic!()
        };
        ix.running_on(&job, "r1");
        ix.job_ended(&job, true, 10, 2);
        let gate = ix.want(&key('a'), &pid(), Role::Gate, "command", "ro", 3);
        let Want::Create { job: gate_job } = gate else {
            panic!("a gate reused an author's build: {gate:?}")
        };
        assert_eq!(gate_job, job_id(&key('a'), Role::Gate));
        assert_ne!(gate_job, job);
    }

    // [D] pure: an author's run takes a gate build, preferring it
    #[test]
    fn an_author_run_reuses_a_gate_build() {
        let mut ix = ArtifactIndex::default();
        let Want::Create { job } = ix.want(&key('a'), &pid(), Role::Gate, "command", "ro", 1)
        else {
            panic!()
        };
        ix.running_on(&job, "r1");
        ix.job_ended(&job, true, 10, 2);
        assert_eq!(
            ix.want(&key('a'), &pid(), Role::Author, "command", "ro", 3),
            Want::Present {
                runner: "r1".into(),
                role: Role::Gate
            }
        );
    }

    // [D] pure: two gate consumers of one key share one gate job
    #[test]
    fn two_gate_consumers_of_one_key_make_one_gate_job() {
        let mut ix = ArtifactIndex::default();
        let a = ix.want(&key('a'), &pid(), Role::Gate, "command", "ro", 1);
        let b = ix.want(&key('a'), &pid(), Role::Gate, "command", "ro", 2);
        let (Want::Create { job }, Want::Building { job: again }) = (a, b) else {
            panic!()
        };
        assert_eq!(job, again);
    }

    // [D] pure: pins keep a key; the keys queued jobs use are needed
    #[test]
    fn pins_and_needed_keys() {
        let mut ix = ArtifactIndex::default();
        let Want::Create { job } = ix.want(&key('a'), &pid(), Role::Author, "command", "ro", 1)
        else {
            panic!()
        };
        ix.running_on(&job, "r1");
        ix.job_ended(&job, true, 10, 2);
        ix.pin(&key('a'), "task t1");
        assert!(ix.rows().next().unwrap().pins.contains("task t1"));
        ix.unpin(&key('a'), "task t1");
        assert!(ix.rows().next().unwrap().pins.is_empty());
        let mut s = blank_spec("j");
        s.artifacts.push(forseti::ArtifactUse {
            name: "build".into(),
            kind: "command".into(),
            use_: "ro".into(),
            key: key('a'),
            route: None,
            build: None,
        });
        assert_eq!(ix.needed(&[s, blank_spec("k")]), BTreeSet::from([key('a')]));
    }
}
