//! The revert's order in every order of its sources (pattern A, skuld), composed with the session's turn core and the
//! edit history's origin core.
//!
//! The test's world plays the shell: each effect's I/O happens when the core asks for it, and the step's `Done` is
//! one of the shell's events, so the racing events land between them.  Durable are the history record (one per
//! `Record`), the pending record, the files, the conversation (swapped only while it is still the one the pending
//! record names, as the shell compares `asession.acp`), the commit (made only when something is left to commit) and
//! the clear.  After a crash the next start finishes: from the pending record when there is one, else (nothing was
//! recorded) the user applies the preview again; that start's I/O completes at once.

use super::*;
use crate::agents::queue::{Origin as QOrigin, Queued};
use crate::agents::session::turn_core::{TurnCore, TurnEffect, TurnEvent};
use crate::history::origin::{OriginCore, OriginEv, Owner};
use skuld::{Bound, Core, Partial, every_order};
use std::collections::BTreeMap;

#[derive(Clone, Debug)]
enum Ev {
    /// The revert's own chain: the user's apply and each step's end, or a crash of the hub.
    Shell(RevertEvent),
    /// What races with it.
    Other(RevertEvent),
}
skuld::events!(Ev { Shell, Other });

const PATHS: [&str; 2] = ["a.txt", "b.txt"];

fn pending(live: bool) -> Pending {
    Pending {
        op: 7,
        sid: "s1".into(),
        seq: 3,
        level: RestoreLevel::Message,
        message: None,
        paths: PATHS.iter().map(PathBuf::from).collect(),
        acp_before: Some("acp-1".into()),
        live,
    }
}

/// The shell's chain for P: the apply, then each step's end.
fn chain(p: &Pending) -> Vec<Ev> {
    use RevertStep as S;
    let mut v = vec![Ev::Shell(RevertEvent::Begin(p.clone()))];
    for s in [
        S::Quiet,
        S::Rescan,
        S::Record,
        S::Files,
        S::Graph,
        S::Conversation,
        S::Commit,
        S::Clear,
    ] {
        if s != S::Conversation || p.live {
            v.push(Ev::Shell(RevertEvent::Done(s)));
        }
    }
    v
}

/// The index of step S's end in [`chain`].
fn done_at(p: &Pending, s: RevertStep) -> usize {
    chain(p)
        .iter()
        .position(|e| matches!(e, Ev::Shell(RevertEvent::Done(x)) if *x == s))
        .unwrap()
}

struct World {
    core: RevertCore,
    turn: TurnCore,
    origin: OriginCore,
    p: Pending,
    /// After a crash: the next start's I/O, each step's end at once.
    sync: bool,
    pending: Option<Pending>,
    ops: u32,
    files: BTreeMap<String, &'static str>,
    acp: String,
    rewinds: u32,
    committed: bool,
    commits: u32,
    graph: u32,
    cleared: u32,
    not_restored: u32,
    detached: bool,
    ever_detached: bool,
    /// The turn the agent works on, and the turn the detach cut off.
    running: Option<u64>,
    old: Option<u64>,
    /// The prompts that started, with the conversation they started in.
    started: Vec<(String, String)>,
    jobs_stopped: bool,
    job_writes: u32,
    kept: Vec<String>,
    applied: Vec<String>,
    versions: Vec<(String, Owner)>,
    refused: Vec<&'static str>,
    broken: Option<String>,
}

impl World {
    fn new(p: Pending) -> World {
        let mut turn = TurnCore::new();
        turn.ready(false);
        let mut origin = OriginCore::default();
        let mut files = BTreeMap::new();
        for path in PATHS {
            origin.known(path, "agent");
            files.insert(path.to_string(), "agent");
        }
        World {
            core: RevertCore::new(),
            turn,
            origin,
            p,
            sync: false,
            pending: None,
            ops: 0,
            files,
            acp: "acp-1".into(),
            rewinds: 0,
            committed: false,
            commits: 0,
            graph: 0,
            cleared: 0,
            not_restored: 0,
            detached: false,
            ever_detached: false,
            running: None,
            old: None,
            started: Vec::new(),
            jobs_stopped: false,
            job_writes: 0,
            kept: Vec::new(),
            applied: Vec::new(),
            versions: Vec::new(),
            refused: Vec::new(),
            broken: None,
        }
    }

    /// A world whose session runs a turn (`old`) when the revert begins.
    fn running(p: Pending) -> World {
        let mut w = World::new(p);
        w.send("old");
        w.old = w.running;
        assert!(w.old.is_some());
        w
    }

    fn send(&mut self, text: &str) {
        let fx = self.turn.step(TurnEvent::Send {
            item: Queued {
                text: text.into(),
                origin: QOrigin::User,
                steer: false,
                key: None,
            },
            steer_mode: false,
            if_free: false,
        });
        self.turn_fx(fx);
    }

    fn turn_fx(&mut self, fx: Vec<TurnEffect>) {
        for e in fx {
            match e {
                TurnEffect::StartTurn { turn, item } => {
                    if self.detached {
                        self.broken
                            .get_or_insert(format!("{} started while detached", item.text));
                    }
                    let sent = self.turn.step(TurnEvent::Sending { turn });
                    if sent.contains(&TurnEffect::Prompt { turn }) {
                        self.started.push((item.text.clone(), self.acp.clone()));
                        self.running = Some(turn);
                    }
                }
                TurnEffect::EndTurn { turn, .. } if self.running == Some(turn) => {
                    self.running = None;
                }
                _ => {}
            }
        }
    }

    fn revert(&mut self, ev: RevertEvent) -> Vec<Ev> {
        let fx = self.core.step(ev);
        self.apply(fx)
    }

    fn apply(&mut self, fx: Vec<RevertEffect>) -> Vec<Ev> {
        use RevertEffect as E;
        use RevertStep as S;
        let mut again = Vec::new();
        let mut done = |s: S, sync: bool| {
            if sync {
                again.push(Ev::Shell(RevertEvent::Done(s)));
            }
        };
        for e in fx {
            match e {
                E::Refuse(r) => self.refused.push(r),
                E::Detach => {
                    self.detached = true;
                    self.ever_detached = true;
                    let fx = self.turn.step(TurnEvent::Detach);
                    // the cut-off turn is no longer the session's
                    self.running = None;
                    self.turn_fx(fx);
                }
                E::StopJobs => {
                    self.jobs_stopped = true;
                    done(S::Quiet, self.sync);
                }
                E::Rescan => done(S::Rescan, self.sync),
                E::Record => {
                    self.ops += 1;
                    self.pending = Some(self.p.clone());
                    done(S::Record, self.sync);
                }
                E::ExpectWrite(path) => {
                    let path = path.to_string_lossy().into_owned();
                    if let Some(v) = self.origin.step(OriginEv::HubWrite {
                        path: path.clone(),
                        hash: "cp".into(),
                    }) {
                        self.versions.push((path, v.owner));
                    }
                }
                E::WriteFiles => {
                    for p in PATHS {
                        self.files.insert(p.into(), "cp");
                    }
                    done(S::Files, self.sync);
                }
                E::Graph => {
                    self.graph += 1;
                    done(S::Graph, self.sync);
                }
                E::Rewind => {
                    if Some(&self.acp) == self.p.acp_before.as_ref() {
                        self.acp = "acp-2".into();
                        self.rewinds += 1;
                    }
                    done(S::Conversation, self.sync);
                }
                E::Reattach => {
                    self.detached = false;
                    let fx = self.turn.step(TurnEvent::Reattach { told: None });
                    self.turn_fx(fx);
                }
                E::Commit => {
                    if !self.committed {
                        self.committed = true;
                        self.commits += 1;
                    }
                    done(S::Commit, self.sync);
                }
                E::Clear => {
                    self.pending = None;
                    self.cleared += 1;
                    done(S::Clear, self.sync);
                }
                E::Broadcast | E::TellManager => {}
                E::KeepPatch(id) => self.kept.push(id),
                E::NotRestored => self.not_restored += 1,
            }
        }
        again
    }

    /// The hub's next start after a crash: the session's turn core is new and attached, the origin core knows the
    /// files as they are, and the revert finishes from the pending record (or the user applies it again when nothing
    /// was recorded; a revert recorded and cleared is done).
    fn restart(&mut self) -> Vec<Ev> {
        let mut turn = TurnCore::new();
        turn.ready(false);
        self.turn = turn;
        self.detached = false;
        self.running = None;
        self.origin = OriginCore::default();
        for (p, h) in &self.files {
            self.origin.known(p, h);
        }
        self.sync = true;
        match (&self.pending, self.ops) {
            (Some(p), _) => vec![Ev::Shell(RevertEvent::Resume(p.clone()))],
            (None, 0) => vec![Ev::Shell(RevertEvent::Begin(self.p.clone()))],
            (None, _) => vec![],
        }
    }
}

impl Core for World {
    type Event = Ev;

    fn step(&mut self, ev: Ev) -> Vec<Ev> {
        let (Ev::Shell(e) | Ev::Other(e)) = ev;
        match e {
            RevertEvent::Crash => {
                self.core.step(RevertEvent::Crash);
                self.restart()
            }
            RevertEvent::UserSend => {
                self.send("hi");
                self.revert(RevertEvent::UserSend)
            }
            RevertEvent::UserStop => {
                let fx = self.turn.step(TurnEvent::Stop { after_tool: false });
                self.turn_fx(fx);
                self.revert(RevertEvent::UserStop)
            }
            RevertEvent::OldTurnDone => {
                if let Some(turn) = self.old {
                    let fx = self.turn.step(TurnEvent::PromptDone {
                        turn,
                        cancelled: true,
                        jobs: false,
                    });
                    self.turn_fx(fx);
                }
                self.revert(RevertEvent::OldTurnDone)
            }
            RevertEvent::JobEnded => {
                // a job still running at its end writes what it made
                if !self.jobs_stopped {
                    self.files.insert("a.txt".into(), "job");
                    self.job_writes += 1;
                }
                self.revert(RevertEvent::JobEnded)
            }
            RevertEvent::RunnerPatch(id) => {
                let fx = self.core.step(RevertEvent::RunnerPatch(id.clone()));
                if fx.iter().any(|e| matches!(e, RevertEffect::KeepPatch(_))) {
                    self.apply(fx)
                } else {
                    self.applied.push(id);
                    self.files.insert("a.txt".into(), "patch");
                    self.apply(fx)
                }
            }
            RevertEvent::OwnWrite(path) => {
                let p = path.to_string_lossy().into_owned();
                let hash = self.files.get(&p).copied().unwrap_or_default();
                if let Some(v) = self.origin.step(OriginEv::Watch {
                    path: p.clone(),
                    hash: hash.into(),
                }) {
                    self.versions.push((p, v.owner));
                }
                self.revert(RevertEvent::OwnWrite(path))
            }
            other => self.revert(other),
        }
    }
}

/// The revert finished once: one history record, the files the checkpoint's, nothing pending, at most one commit.
fn finished_once(w: &World) -> Result<(), String> {
    if let Some(b) = &w.broken {
        return Err(b.clone());
    }
    if w.ops != 1 {
        return Err(format!("{} history records", w.ops));
    }
    if w.files.values().any(|h| *h != "cp") {
        return Err(format!("the files are {:?}", w.files));
    }
    if w.pending.is_some() || w.core.busy() {
        return Err(format!("still pending at {:?}", w.core.at()));
    }
    if w.commits > 1 {
        return Err(format!("{} commits", w.commits));
    }
    if w.graph == 0 || w.cleared == 0 {
        return Err(format!("graph {} cleared {}", w.graph, w.cleared));
    }
    Ok(())
}

fn run(
    p: &Partial<Ev>,
    make: impl FnMut() -> World,
    check: impl FnMut(&World, &[Ev]) -> Result<(), String>,
) -> u64 {
    every_order(p, Bound::default(), make, check).orders
}

#[test]
fn every_order_a_send_during_a_revert_runs_once_after_it() {
    let pd = pending(true);
    let mut p = Partial::new();
    let shell = p.source("shell", chain(&pd));
    let user = p.source("user", vec![Ev::Other(RevertEvent::UserSend)]);
    p.before((shell, 0), (user, 0));
    let n = run(
        &p,
        || World::running(pending(true)),
        |w, _| {
            finished_once(w)?;
            let hi: Vec<&(String, String)> = w.started.iter().filter(|(t, _)| t == "hi").collect();
            if hi.len() != 1 || hi[0].1 != "acp-2" {
                return Err(format!("hi started {hi:?}"));
            }
            if w.rewinds != 1 {
                return Err(format!("{} rewinds", w.rewinds));
            }
            Ok(())
        },
    );
    assert!(n >= 9, "{n} orders");
}

#[test]
fn every_order_a_stop_during_a_revert_leaves_no_turn() {
    let pd = pending(true);
    let mut p = Partial::new();
    let shell = p.source("shell", chain(&pd));
    let user = p.source(
        "user",
        vec![
            Ev::Other(RevertEvent::UserSend),
            Ev::Other(RevertEvent::UserStop),
        ],
    );
    p.before((shell, 0), (user, 0));
    p.before((user, 1), (shell, done_at(&pd, RevertStep::Conversation)));
    let n = run(
        &p,
        || World::running(pending(true)),
        |w, _| {
            finished_once(w)?;
            if w.running.is_some() || w.started.iter().any(|(t, _)| t != "old") {
                return Err(format!(
                    "a turn runs: {:?}, started {:?}",
                    w.running, w.started
                ));
            }
            Ok(())
        },
    );
    assert!(n >= 9, "{n} orders");
}

#[test]
fn every_order_a_crash_at_any_step_finishes_once() {
    for live in [true, false] {
        let pd = pending(live);
        let mut p = Partial::new();
        let shell = p.source("shell", chain(&pd));
        let hub = p.source("hub", vec![Ev::Other(RevertEvent::Crash)]);
        p.before((shell, 0), (hub, 0));
        let n = run(
            &p,
            || World::new(pending(live)),
            |w, _| {
                finished_once(w)?;
                let want = u32::from(live);
                if w.rewinds != want {
                    return Err(format!("{} rewinds", w.rewinds));
                }
                if w.commits != 1 {
                    return Err(format!("{} commits", w.commits));
                }
                Ok(())
            },
        );
        // a crash after each event of the chain
        assert_eq!(n, chain(&pd).len() as u64, "live {live}");
    }
}

#[test]
fn every_order_the_cancelled_turns_end_changes_nothing() {
    let pd = pending(true);
    let mut p = Partial::new();
    let shell = p.source("shell", chain(&pd));
    let agent = p.source("agent", vec![Ev::Other(RevertEvent::OldTurnDone)]);
    p.before((shell, 0), (agent, 0));
    let n = run(
        &p,
        || World::running(pending(true)),
        |w, _| {
            finished_once(w)?;
            if w.started != [("old".to_string(), "acp-1".to_string())] || w.running.is_some() {
                return Err(format!("started {:?}, running {:?}", w.started, w.running));
            }
            if w.rewinds != 1 {
                return Err(format!("{} rewinds", w.rewinds));
            }
            Ok(())
        },
    );
    assert!(n >= 9, "{n} orders");
}

#[test]
fn every_order_a_job_ending_during_a_revert_writes_nothing_after_it() {
    let pd = pending(true);
    let mut p = Partial::new();
    let shell = p.source("shell", chain(&pd));
    let job = p.source("job", vec![Ev::Other(RevertEvent::JobEnded)]);
    p.before((shell, 0), (job, 0));
    let n = run(
        &p,
        || World::new(pending(true)),
        |w, _| {
            finished_once(w)?;
            if w.job_writes != 0 {
                return Err(format!("the job wrote {} times", w.job_writes));
            }
            Ok(())
        },
    );
    assert!(n >= 9, "{n} orders");
}

#[test]
fn every_order_a_runners_patch_during_a_revert_is_kept() {
    let pd = pending(true);
    let mut p = Partial::new();
    let shell = p.source("shell", chain(&pd));
    let runner = p.source(
        "runner",
        vec![Ev::Other(RevertEvent::RunnerPatch("r1".into()))],
    );
    p.before((shell, 0), (runner, 0));
    p.before((runner, 0), (shell, done_at(&pd, RevertStep::Clear)));
    let n = run(
        &p,
        || World::new(pending(true)),
        |w, _| {
            finished_once(w)?;
            if w.kept != ["r1"] || !w.applied.is_empty() {
                return Err(format!("kept {:?}, applied {:?}", w.kept, w.applied));
            }
            Ok(())
        },
    );
    assert!(n >= 8, "{n} orders");
}

#[test]
fn every_order_the_restores_own_write_is_not_an_outside_edit() {
    let pd = pending(true);
    let mut p = Partial::new();
    let shell = p.source("shell", chain(&pd));
    let watch = p.source(
        "watch",
        PATHS
            .iter()
            .map(|x| Ev::Other(RevertEvent::OwnWrite(PathBuf::from(x))))
            .collect(),
    );
    p.before((shell, 0), (watch, 0));
    let n = run(
        &p,
        || World::new(pending(true)),
        |w, _| {
            finished_once(w)?;
            let mut v = w.versions.clone();
            v.sort_by(|a, b| a.0.cmp(&b.0));
            let want: Vec<(String, Owner)> =
                PATHS.iter().map(|p| (p.to_string(), Owner::Hub)).collect();
            if v != want {
                return Err(format!("versions {v:?}"));
            }
            Ok(())
        },
    );
    assert!(n >= 30, "{n} orders");
}

#[test]
fn every_order_a_finished_worker_skips_only_the_conversation() {
    let pd = pending(false);
    let mut p = Partial::new();
    let shell = p.source("shell", chain(&pd));
    let job = p.source("job", vec![Ev::Other(RevertEvent::JobEnded)]);
    p.before((shell, 0), (job, 0));
    let n = run(
        &p,
        || World::new(pending(false)),
        |w, _| {
            finished_once(w)?;
            if w.rewinds != 0 || w.not_restored != 1 || w.ever_detached {
                return Err(format!(
                    "rewinds {}, not restored {}, detached {}",
                    w.rewinds, w.not_restored, w.ever_detached
                ));
            }
            if w.commits != 1 || w.graph != 1 {
                return Err(format!("commits {}, graph {}", w.commits, w.graph));
            }
            Ok(())
        },
    );
    assert!(n >= 8, "{n} orders");
}

/// A failed step (pattern D, one order): before the record nothing is durable, so the session reattaches and the
/// revert is refused (`stale` from the rescan); a conversation that cannot be restored is said and the commit follows;
/// a commit that fails is reported and the record cleared; a failed write keeps the pending record for the next start.
#[test]
fn a_failed_step_aborts_before_the_record_and_goes_on_after_it() {
    use RevertEffect as E;
    use RevertStep as S;
    let begin = |c: &mut RevertCore| c.step(RevertEvent::Begin(pending(true)));
    let fail = RevertEvent::Failed;

    let mut c = RevertCore::new();
    begin(&mut c);
    c.step(RevertEvent::Done(S::Quiet));
    assert_eq!(c.step(fail(S::Rescan)), [E::Reattach, E::Refuse("stale")]);
    assert!(!c.busy());

    let mut c = RevertCore::new();
    begin(&mut c);
    assert_eq!(c.step(fail(S::Quiet)), [E::Reattach, E::Refuse("failed")]);
    // a step's end that is not the running step's changes nothing
    assert_eq!(c.step(RevertEvent::Done(S::Rescan)), []);

    let mut c = RevertCore::new();
    begin(&mut c);
    for s in [S::Quiet, S::Rescan, S::Record, S::Files, S::Graph] {
        c.step(RevertEvent::Done(s));
    }
    assert_eq!(c.at(), Some(S::Conversation));
    assert_eq!(
        c.step(fail(S::Conversation)),
        [E::NotRestored, E::Reattach, E::Commit]
    );
    assert_eq!(c.step(fail(S::Commit)), [E::Clear]);
    assert_eq!(
        c.step(RevertEvent::Done(S::Clear)),
        [E::Broadcast, E::TellManager]
    );
    assert!(!c.busy());

    let mut c = RevertCore::new();
    begin(&mut c);
    for s in [S::Quiet, S::Rescan, S::Record] {
        c.step(RevertEvent::Done(s));
    }
    assert_eq!(c.step(fail(S::Files)), []);
    assert!(c.busy() && c.at().is_none());
    assert_eq!(
        c.step(RevertEvent::Begin(pending(true))),
        [E::Refuse("busy")]
    );
    let resumed = c.step(RevertEvent::Resume(pending(true)));
    assert_eq!(resumed.last(), Some(&E::WriteFiles));
}
