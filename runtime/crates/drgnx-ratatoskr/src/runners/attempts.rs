//! The attempt state machine (docs/develop/hub.md, "Runners: attempts"; design §6.9): pure, so a test runs it in every
//! order of its inputs (`tests/runners_orders.rs`).
//!
//! Every placement on a runner is an attempt with a nonce the hub made. A frame about an attempt counts only from the
//! runner it was placed on and with its nonce; anything else is ignored with a notice. An attempt with no verdict
//! whose runner's link is down, or whose runner hasn't listed it at its `hello` since the hub restarted, is
//! `detached`: a state, never a verdict. It ends in exactly one way:
//!
//! | event | becomes |
//! |---|---|
//! | the runner's `hello` lists it running or finished | `running`; its log resumes from the hub's offset (a finished one then sends its result) |
//! | the runner's `hello` doesn't list it, or lists it lost | requeued now, if restartable |
//! | the grace ends | requeued, if restartable |
//! | the cloud API says the machine is gone | requeued now |
//! | not restartable, and any of the last three | `lost` |
//!
//! The grace is the runner's ([`super::RunnerCfg::grace`]: 600 s with linger, 0 without); with none, the attempt ends
//! at once. Preemption requeues at once and is never a verdict. Only a `finished` frame gives a verdict (a cancel
//! that can't reach the runner ends the attempt `cancelled`). An attempt that finishes after its job was requeued is
//! late: its result is kept as that attempt's ([`Effect::KeepLate`]), never applied.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sleipnir::proto::{AttemptInfo, JobRef, Nonce};
use std::collections::BTreeMap;

/// Where an attempt is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase", tag = "state")]
pub enum AttemptState {
    /// Offered to its runner; not started yet.
    Offered,
    Running,
    /// No verdict, and its runner can't be heard (`since`, `grace_until`: seconds since the epoch).
    Detached {
        since: u64,
        grace_until: u64,
    },
    /// Its verdict (or its late result) is in.
    Finished,
    /// Ended without a verdict; its job went back to the queue.
    Requeued,
    /// Ended without a verdict, and its job isn't restartable.
    Lost,
}

impl AttemptState {
    /// No verdict yet, and nothing has ended it.
    pub fn open(self) -> bool {
        matches!(
            self,
            AttemptState::Offered | AttemptState::Running | AttemptState::Detached { .. }
        )
    }

    /// The word `rq_attempt.state` keeps.
    pub fn word(self) -> &'static str {
        match self {
            AttemptState::Offered => "offered",
            AttemptState::Running => "running",
            AttemptState::Detached { .. } => "detached",
            AttemptState::Finished => "finished",
            AttemptState::Requeued => "requeued",
            AttemptState::Lost => "lost",
        }
    }
}

/// An attempt as a runner's `hello-ok` lists it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Listed {
    pub r: JobRef,
    pub state: ListedState,
    pub log_offset: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListedState {
    Running,
    Finished,
    Lost,
}

impl From<&AttemptInfo> for Listed {
    fn from(a: &AttemptInfo) -> Listed {
        use sleipnir::proto::AttemptState as S;
        Listed {
            r: a.r.clone(),
            state: match a.state {
                S::Running => ListedState::Running,
                S::Finished => ListedState::Finished,
                S::Lost | S::Unknown => ListedState::Lost,
            },
            log_offset: a.log_offset,
        }
    }
}

/// What the core hears.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// The hub placed attempt ATTEMPT of JOB on RUNNER with NONCE; GRACE_S is the runner's grace.
    Placed {
        job: String,
        attempt: u32,
        nonce: Nonce,
        runner: String,
        grace_s: u64,
        restartable: bool,
    },
    /// RUNNER's `started` frame.
    Started { runner: String, r: JobRef },
    /// RUNNER's `finished` frame: the only source of a verdict.
    Finished {
        runner: String,
        r: JobRef,
        result: Value,
    },
    /// Any other job frame from RUNNER (`log`, `row`, `key-use`, `admit`, `refuse`).
    FrameFrom { runner: String, r: JobRef },
    /// RUNNER's control link is down: no frame for 45 s, its master failed its check, or an EOF without `bye`.
    LinkLost { runner: String },
    /// RUNNER's `hello-ok` with the attempts it holds.
    Hello { runner: String, listed: Vec<Listed> },
    /// The grace of a detached attempt ended.
    GraceEnded { job: String, attempt: u32 },
    /// The cloud API says RUNNER's machine is gone.
    CloudGone { runner: String },
    /// RUNNER's machine is being preempted.
    Preempting { runner: String },
    /// The hub started again with these attempts from its database: every open one is detached.
    HubRestarted,
    /// The user stopped JOB.
    Cancel { job: String },
}

/// What the shell does.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// The attempt's verdict: record it, wake the starter.
    Verdict {
        job: String,
        attempt: u32,
        result: Value,
    },
    /// The job goes back to the queue (a new attempt), for REASON (`infra: runner lost`, `infra: preempted`).
    Requeue { job: String, reason: String },
    /// The job is lost (not restartable); the starter is woken with that.
    Lost { job: String },
    /// A frame that doesn't count: log NOTICE, change nothing.
    Ignore { notice: String },
    /// Send `attach` for the attempt: its log resumes from OFFSET (where the hub's copy ends).
    ResumeLog {
        job: String,
        attempt: u32,
        offset: u64,
    },
    /// A late attempt's result: keep it as that attempt's (log, patch, outputs, rows), never applied.
    KeepLate { job: String, attempt: u32 },
    /// Send `cancel` for R to RUNNER.
    SendCancel { runner: String, r: JobRef },
}

/// One attempt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attempt {
    pub runner: String,
    pub nonce: Nonce,
    pub state: AttemptState,
    pub grace_s: u64,
    /// How many bytes of its log the hub holds.
    pub log_offset: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct JobRow {
    current: u32,
    restartable: bool,
    cancelled: bool,
}

/// The attempts of every job placed on a runner.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Core {
    attempts: BTreeMap<(String, u32), Attempt>,
    jobs: BTreeMap<String, JobRow>,
}

/// The reason a requeue for a lost runner carries.
pub const RUNNER_LOST: &str = "infra: runner lost";
/// The reason a requeue for a preemption carries.
pub const PREEMPTED: &str = "infra: preempted";

/// The result an attempt ends with when it is cancelled and its runner can't say so itself.
fn cancelled() -> Value {
    json!({"verdict": "Cancelled"})
}

impl Core {
    /// Steps the core at NOW (seconds since the epoch).
    pub fn step(&mut self, now: u64, ev: Event) -> Vec<Effect> {
        let mut out = Vec::new();
        match ev {
            Event::Placed {
                job,
                attempt,
                nonce,
                runner,
                grace_s,
                restartable,
            } => {
                self.attempts.insert(
                    (job.clone(), attempt),
                    Attempt {
                        runner,
                        nonce,
                        state: AttemptState::Offered,
                        grace_s,
                        log_offset: 0,
                    },
                );
                let cancelled = self.jobs.get(&job).is_some_and(|j| j.cancelled);
                self.jobs.insert(
                    job,
                    JobRow {
                        current: attempt,
                        restartable,
                        cancelled,
                    },
                );
            }
            Event::Started { runner, r } => match self.frame_ok(&runner, &r) {
                None => out.push(ignore(&runner, &r, "started")),
                Some(_) => {
                    if let Some(a) = self.get_mut(&r)
                        && matches!(a.state, AttemptState::Offered)
                    {
                        a.state = AttemptState::Running;
                    }
                }
            },
            Event::FrameFrom { runner, r } => {
                if self.frame_ok(&runner, &r).is_none() {
                    out.push(ignore(&runner, &r, "a frame"));
                }
            }
            Event::Finished { runner, r, result } => {
                let Some(late) = self.frame_ok(&runner, &r) else {
                    out.push(ignore(&runner, &r, "finished"));
                    return out;
                };
                let a = self.get_mut(&r).expect("frame_ok found it");
                let was = a.state;
                if was == AttemptState::Finished {
                    out.push(ignore(&runner, &r, "a second finished"));
                    return out;
                }
                a.state = AttemptState::Finished;
                if late || !was.open() {
                    out.push(Effect::KeepLate {
                        job: r.job,
                        attempt: r.attempt,
                    });
                } else {
                    out.push(Effect::Verdict {
                        job: r.job,
                        attempt: r.attempt,
                        result,
                    });
                }
            }
            Event::LinkLost { runner } => {
                for key in self.on(&runner, |s| {
                    matches!(s, AttemptState::Offered | AttemptState::Running)
                }) {
                    self.detach(now, &key, &mut out);
                }
            }
            Event::HubRestarted => {
                let keys: Vec<_> = self
                    .attempts
                    .iter()
                    .filter(|(_, a)| {
                        matches!(a.state, AttemptState::Offered | AttemptState::Running)
                    })
                    .map(|(k, _)| k.clone())
                    .collect();
                for key in keys {
                    self.detach(now, &key, &mut out);
                }
            }
            Event::Hello { runner, listed } => self.hello(&runner, &listed, &mut out),
            Event::GraceEnded { job, attempt } => {
                let key = (job, attempt);
                if self
                    .attempts
                    .get(&key)
                    .is_some_and(|a| matches!(a.state, AttemptState::Detached { .. }))
                {
                    self.end(&key, RUNNER_LOST, &mut out);
                }
            }
            Event::CloudGone { runner } => {
                for key in self.on(&runner, AttemptState::open) {
                    self.end(&key, RUNNER_LOST, &mut out);
                }
            }
            Event::Preempting { runner } => {
                for key in self.on(&runner, AttemptState::open) {
                    self.end(&key, PREEMPTED, &mut out);
                }
            }
            Event::Cancel { job } => {
                let Some(row) = self.jobs.get_mut(&job) else {
                    return out;
                };
                row.cancelled = true;
                let key = (job, row.current);
                let Some(a) = self.attempts.get_mut(&key) else {
                    return out;
                };
                let r = JobRef {
                    job: key.0.clone(),
                    attempt: key.1,
                    nonce: a.nonce,
                };
                match a.state {
                    AttemptState::Running => out.push(Effect::SendCancel {
                        runner: a.runner.clone(),
                        r,
                    }),
                    AttemptState::Offered | AttemptState::Detached { .. } => {
                        // its runner may hold it: it is told when it can be, the verdict is ours now
                        if a.state == AttemptState::Offered {
                            out.push(Effect::SendCancel {
                                runner: a.runner.clone(),
                                r,
                            });
                        }
                        a.state = AttemptState::Finished;
                        out.push(Effect::Verdict {
                            job: key.0,
                            attempt: key.1,
                            result: cancelled(),
                        });
                    }
                    _ => {}
                }
            }
        }
        out
    }

    fn get_mut(&mut self, r: &JobRef) -> Option<&mut Attempt> {
        self.attempts.get_mut(&(r.job.clone(), r.attempt))
    }

    /// The attempts on RUNNER whose state passes WHICH.
    fn on(&self, runner: &str, which: impl Fn(AttemptState) -> bool) -> Vec<(String, u32)> {
        self.attempts
            .iter()
            .filter(|(_, a)| a.runner == runner && which(a.state))
            .map(|(k, _)| k.clone())
            .collect()
    }

    /// KEY's runner can't be heard: detached for its grace, or ended now when it has none.
    fn detach(&mut self, now: u64, key: &(String, u32), out: &mut Vec<Effect>) {
        let a = self.attempts.get_mut(key).expect("an attempt");
        if a.grace_s == 0 {
            self.end(key, RUNNER_LOST, out);
            return;
        }
        a.state = AttemptState::Detached {
            since: now,
            grace_until: now + a.grace_s,
        };
    }

    /// KEY ends without a verdict from its runner: cancelled if its job is, else requeued if restartable, else lost.
    /// A late attempt (not its job's current one) ends lost, saying nothing: its job has moved on.
    fn end(&mut self, key: &(String, u32), reason: &str, out: &mut Vec<Effect>) {
        let row = self.jobs.get(&key.0).cloned();
        let a = self.attempts.get_mut(key).expect("an attempt");
        let current = row.as_ref().is_some_and(|j| j.current == key.1);
        match row {
            Some(j) if current && j.cancelled => {
                a.state = AttemptState::Finished;
                out.push(Effect::Verdict {
                    job: key.0.clone(),
                    attempt: key.1,
                    result: cancelled(),
                });
            }
            Some(j) if current && j.restartable => {
                a.state = AttemptState::Requeued;
                out.push(Effect::Requeue {
                    job: key.0.clone(),
                    reason: reason.into(),
                });
            }
            Some(_) if current => {
                a.state = AttemptState::Lost;
                out.push(Effect::Lost { job: key.0.clone() });
            }
            _ => a.state = AttemptState::Lost,
        }
    }

    /// RUNNER's `hello-ok`: each attempt it lists running or finished reattaches (its log resumes); each open one it
    /// doesn't list, or lists lost, ends. A listed attempt the hub never gave it is ignored.
    fn hello(&mut self, runner: &str, listed: &[Listed], out: &mut Vec<Effect>) {
        let mut alive = Vec::new();
        for l in listed {
            if self.frame_ok(runner, &l.r).is_none() {
                out.push(ignore(runner, &l.r, "a listed attempt"));
                continue;
            }
            if l.state != ListedState::Lost {
                alive.push((l.r.job.clone(), l.r.attempt));
            }
        }
        let mine = self.on(runner, |s| {
            s.open() || matches!(s, AttemptState::Requeued | AttemptState::Finished)
        });
        for key in mine {
            let cancelled = self.jobs.get(&key.0).is_some_and(|j| j.cancelled);
            let a = self.attempts.get_mut(&key).expect("an attempt");
            let listed_alive = alive.contains(&key);
            match a.state {
                s if s.open() && listed_alive => {
                    a.state = AttemptState::Running;
                    out.push(Effect::ResumeLog {
                        job: key.0.clone(),
                        attempt: key.1,
                        offset: a.log_offset,
                    });
                    if cancelled {
                        out.push(Effect::SendCancel {
                            runner: runner.into(),
                            r: JobRef {
                                job: key.0.clone(),
                                attempt: key.1,
                                nonce: a.nonce,
                            },
                        });
                    }
                }
                s if s.open() => self.end(&key, RUNNER_LOST, out),
                // a late attempt still running there: its log and result are kept as that attempt's
                AttemptState::Requeued if listed_alive => out.push(Effect::ResumeLog {
                    job: key.0.clone(),
                    attempt: key.1,
                    offset: a.log_offset,
                }),
                AttemptState::Requeued => a.state = AttemptState::Lost,
                // cancelled while its link was down, and it runs on: told now
                AttemptState::Finished if listed_alive && cancelled => {
                    out.push(Effect::SendCancel {
                        runner: runner.into(),
                        r: JobRef {
                            job: key.0.clone(),
                            attempt: key.1,
                            nonce: a.nonce,
                        },
                    })
                }
                _ => {}
            }
        }
    }

    /// Attempt ATTEMPT of JOB.
    pub fn attempt(&self, job: &str, attempt: u32) -> Option<&Attempt> {
        self.attempts.get(&(job.to_string(), attempt))
    }

    /// JOB's current attempt: its number and state.
    pub fn current(&self, job: &str) -> Option<(u32, &Attempt)> {
        let n = self.jobs.get(job)?.current;
        Some((n, self.attempt(job, n)?))
    }

    /// Whether a frame about R from RUNNER counts: `Some(false)` for the job's current attempt, `Some(true)` for a
    /// late one, `None` when the hub never gave RUNNER that attempt with that nonce.
    pub fn frame_ok(&self, runner: &str, r: &JobRef) -> Option<bool> {
        let a = self.attempt(&r.job, r.attempt)?;
        if a.runner != runner || a.nonce != r.nonce {
            return None;
        }
        let current = self
            .jobs
            .get(&r.job)
            .is_some_and(|j| j.current == r.attempt);
        Some(!current)
    }

    /// The detached attempts whose grace has ended at NOW.
    pub fn graces_due(&self, now: u64) -> Vec<(String, u32)> {
        self.attempts
            .iter()
            .filter(|(_, a)| {
                matches!(a.state, AttemptState::Detached { grace_until, .. } if grace_until <= now)
            })
            .map(|(k, _)| k.clone())
            .collect()
    }

    /// The hub's copy of R's log now ends at UPTO.
    pub fn logged(&mut self, r: &JobRef, upto: u64) {
        if let Some(a) = self.get_mut(r)
            && a.nonce == r.nonce
        {
            a.log_offset = upto;
        }
    }

    /// Puts back an attempt the database kept (a hub restart), before [`Event::HubRestarted`] detaches the open ones.
    pub fn restore(
        &mut self,
        job: &str,
        attempt: u32,
        a: Attempt,
        current: bool,
        restartable: bool,
    ) {
        self.attempts.insert((job.to_string(), attempt), a);
        if current {
            self.jobs.insert(
                job.to_string(),
                JobRow {
                    current: attempt,
                    restartable,
                    cancelled: false,
                },
            );
        }
    }

    /// Forgets JOB once its verdict is recorded and no late attempt is open.
    pub fn forget(&mut self, job: &str) {
        let open = self
            .attempts
            .iter()
            .any(|((j, _), a)| j == job && (a.state.open() || a.state == AttemptState::Requeued));
        if !open {
            self.attempts.retain(|(j, _), _| j != job);
            self.jobs.remove(job);
        }
    }

    /// Every attempt, by job and number.
    pub fn attempts(&self) -> impl Iterator<Item = (&(String, u32), &Attempt)> {
        self.attempts.iter()
    }
}

/// The notice of a frame that doesn't count.
fn ignore(runner: &str, r: &JobRef, what: &str) -> Effect {
    Effect::Ignore {
        notice: format!(
            "runner {runner}: {what} about {} attempt {} ({:?}), which the hub never gave it: ignored",
            r.job, r.attempt, r.nonce
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runners::RunnerCfg;

    const A: &str = "desktop";
    const N1: Nonce = Nonce([1; 16]);

    fn r1() -> JobRef {
        JobRef {
            job: "j1".into(),
            attempt: 1,
            nonce: N1,
        }
    }

    /// j1's attempt 1 running on A with GRACE_S.
    fn running(grace_s: u64, restartable: bool) -> Core {
        let mut c = Core::default();
        c.step(
            100,
            Event::Placed {
                job: "j1".into(),
                attempt: 1,
                nonce: N1,
                runner: A.into(),
                grace_s,
                restartable,
            },
        );
        c.step(
            100,
            Event::Started {
                runner: A.into(),
                r: r1(),
            },
        );
        c.logged(&r1(), 7);
        c
    }

    fn state(c: &Core) -> AttemptState {
        c.attempt("j1", 1).expect("attempt 1").state
    }

    fn hello(c: &mut Core, listed: Vec<Listed>) -> Vec<Effect> {
        c.step(
            200,
            Event::Hello {
                runner: A.into(),
                listed,
            },
        )
    }

    fn listed(state: ListedState) -> Vec<Listed> {
        vec![Listed {
            r: r1(),
            state,
            log_offset: 30,
        }]
    }

    fn requeue() -> Effect {
        Effect::Requeue {
            job: "j1".into(),
            reason: RUNNER_LOST.into(),
        }
    }

    // [D] pure: each way into `detached`, and each row of the design's table out of it
    #[test]
    fn detached_is_exactly_the_designs() {
        // in: the link down, or the hub restarted; neither is a verdict
        let mut c = running(600, true);
        let e = c.step(150, Event::LinkLost { runner: A.into() });
        assert_eq!(e, []);
        assert_eq!(
            state(&c),
            AttemptState::Detached {
                since: 150,
                grace_until: 750
            }
        );
        let mut c = running(600, true);
        assert_eq!(c.step(160, Event::HubRestarted), []);
        assert_eq!(
            state(&c),
            AttemptState::Detached {
                since: 160,
                grace_until: 760
            }
        );
        let detached = || {
            let mut c = running(600, true);
            c.step(150, Event::LinkLost { runner: A.into() });
            c
        };
        // hello lists it running: running, the log resumes from the hub's offset
        let mut c = detached();
        let e = hello(&mut c, listed(ListedState::Running));
        assert_eq!(
            e,
            [Effect::ResumeLog {
                job: "j1".into(),
                attempt: 1,
                offset: 7
            }]
        );
        assert_eq!(state(&c), AttemptState::Running);
        // hello lists it finished: running until its `finished` frame, which is the verdict
        let mut c = detached();
        hello(&mut c, listed(ListedState::Finished));
        assert_eq!(state(&c), AttemptState::Running);
        let result = json!({"verdict": "Pass"});
        let e = c.step(
            210,
            Event::Finished {
                runner: A.into(),
                r: r1(),
                result: result.clone(),
            },
        );
        assert_eq!(
            e,
            [Effect::Verdict {
                job: "j1".into(),
                attempt: 1,
                result
            }]
        );
        assert_eq!(state(&c), AttemptState::Finished);
        // hello doesn't list it, or lists it lost: requeued now
        for l in [vec![], listed(ListedState::Lost)] {
            let mut c = detached();
            assert_eq!(hello(&mut c, l), [requeue()]);
            assert_eq!(state(&c), AttemptState::Requeued);
        }
        // the grace ends: requeued; a grace end for an attempt that reattached changes nothing
        let mut c = detached();
        assert_eq!(c.graces_due(749), []);
        assert_eq!(c.graces_due(750), [("j1".to_string(), 1)]);
        let e = c.step(
            750,
            Event::GraceEnded {
                job: "j1".into(),
                attempt: 1,
            },
        );
        assert_eq!(e, [requeue()]);
        let mut c = detached();
        hello(&mut c, listed(ListedState::Running));
        let e = c.step(
            750,
            Event::GraceEnded {
                job: "j1".into(),
                attempt: 1,
            },
        );
        assert_eq!(e, []);
        assert_eq!(state(&c), AttemptState::Running);
        // the cloud API says the machine is gone: requeued now, detached or not
        for mut c in [detached(), running(600, true)] {
            assert_eq!(
                c.step(300, Event::CloudGone { runner: A.into() }),
                [requeue()]
            );
        }
        // not restartable: the last three end it lost
        let lost = || {
            let mut c = running(600, false);
            c.step(150, Event::LinkLost { runner: A.into() });
            c
        };
        let want = [Effect::Lost { job: "j1".into() }];
        let mut c = lost();
        assert_eq!(hello(&mut c, vec![]), want);
        assert_eq!(state(&c), AttemptState::Lost);
        let mut c = lost();
        let e = c.step(
            750,
            Event::GraceEnded {
                job: "j1".into(),
                attempt: 1,
            },
        );
        assert_eq!(e, want);
        let mut c = lost();
        assert_eq!(c.step(300, Event::CloudGone { runner: A.into() }), want);
        // a requeued attempt that finishes later is late: kept, never a verdict
        let mut c = detached();
        hello(&mut c, vec![]);
        let e = c.step(
            400,
            Event::Finished {
                runner: A.into(),
                r: r1(),
                result: json!({"verdict": "Red"}),
            },
        );
        assert_eq!(
            e,
            [Effect::KeepLate {
                job: "j1".into(),
                attempt: 1
            }]
        );
    }

    // [D] pure: the grace comes from the runner's config; without linger a lost link ends the attempt at once
    #[test]
    fn grace_is_0_without_linger() {
        let mut cfg = crate::runners::tests::ssh_runner("desktop", "desktop");
        cfg.linger = false;
        let grace = |cfg: &RunnerCfg| cfg.grace().as_secs();
        let mut c = running(grace(&cfg), true);
        let e = c.step(150, Event::LinkLost { runner: A.into() });
        assert_eq!(e, [requeue()]);
        assert_eq!(state(&c), AttemptState::Requeued);
        cfg.linger = true;
        let mut c = running(grace(&cfg), true);
        assert_eq!(c.step(150, Event::LinkLost { runner: A.into() }), []);
        assert_eq!(
            state(&c),
            AttemptState::Detached {
                since: 150,
                grace_until: 750
            }
        );
    }
}
