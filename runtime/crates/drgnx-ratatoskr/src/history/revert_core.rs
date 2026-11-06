//! The order of a revert to here, as a pure core (`docs/develop/hub.md`, "Revert to here"): the shell
//! (`history::revert`) does the I/O each effect asks for and tells the core when each step is done.  The core decides
//! what races with a revert may do: a user's message, a Stop, the cancelled turn's answer, a job ending, a runner's
//! returned patch, the watcher's event about the restore's own write, and a crash at any step.
#![cfg_attr(
    not(test),
    allow(
        dead_code,
        reason = "the racing events are the tests' to feed; the shell feeds its own steps"
    )
)]

use runstav::methods::history::RestoreLevel;
use std::path::PathBuf;

/// The revert's steps, in order, after the shell's check (the preview loaded and its frontier compared; a blocked
/// revert is refused before `Begin`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum RevertStep {
    /// The session is detached and its jobs stopped.
    Quiet,
    /// The settler is flushed and the tree rescanned: a new record since the preview is `stale`.
    Rescan,
    /// The revert's history record and the pending record are written: from here the revert is durable.
    Record,
    /// The files are written (by content).
    Files,
    /// The steps after the target are marked undone and the conclusions after it withdrawn.
    Graph,
    /// The conversation is rewound.
    Conversation,
    /// One forward commit, when the head moved since the step.
    Commit,
    /// The pending record is cleared.
    Clear,
}

/// What a revert needs to finish, kept as the pending record from `Record` on: the history record OP, the target
/// (session SID, step SEQ), the level and the user's MESSAGE, the paths written, the conversation before the rewind
/// (ACP_BEFORE), and whether the session has a row to rewind (LIVE false: a finished worker).
#[derive(Clone, Debug, PartialEq, Eq)]
#[allow(dead_code, reason = "the revert's shell reads what the core does not")]
pub(crate) struct Pending {
    pub op: i64,
    pub sid: String,
    pub seq: i64,
    pub level: RestoreLevel,
    pub message: Option<String>,
    pub paths: Vec<PathBuf>,
    pub acp_before: Option<String>,
    pub live: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum RevertEvent {
    /// The user applied a preview that passed its check.
    Begin(Pending),
    /// At start-up, from the pending record (`finish_pending`): steps 5 to 9 again, each idempotent.
    Resume(Pending),
    /// The shell finished a step.
    Done(RevertStep),
    /// A step failed (the shell keeps and reports the reason).
    Failed(RevertStep),
    /// The hub died: everything not durable is gone.
    Crash,
    /// The user sent the session a message.
    UserSend,
    /// The user stopped the session.
    UserStop,
    /// The turn the detach cancelled answered.
    OldTurnDone,
    /// One of the session's jobs ended.
    JobEnded,
    /// A runner returned job ID's patch.
    RunnerPatch(String),
    /// The watcher saw PATH change.
    OwnWrite(PathBuf),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum RevertEffect {
    /// The revert is refused, or stops, with this reason (`busy`, `stale`, `failed`).
    Refuse(&'static str),
    /// `TurnEvent::Detach` to the session's turn core, and the running tool call cancelled.
    Detach,
    /// The session's jobs stopped: the hub's own, the queue's queued rows and remote attempts.
    StopJobs,
    Rescan,
    Record,
    WriteFiles,
    Graph,
    Rewind,
    /// `TurnEvent::Reattach` to the session's turn core.
    Reattach,
    Commit,
    Clear,
    /// `history/applied` to the editors.
    Broadcast,
    /// A message to the manager of a manager's worker.
    TellManager,
    /// PATH is about to be written by the hub: the origin core records the write as the hub's.
    ExpectWrite(PathBuf),
    /// Job ID's returned patch is kept on its job and listed, never applied.
    KeepPatch(String),
    /// The conversation is not restored: the agent has finished.
    NotRestored,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum State {
    Idle,
    /// Running step AT of P.
    Running {
        p: Pending,
        at: RevertStep,
    },
    /// A step after `Record` failed: the pending record stays for the next start.
    Stuck,
}

/// One revert at a time, per session's worktree.
#[derive(Debug)]
pub(crate) struct RevertCore {
    state: State,
}

impl Default for RevertCore {
    fn default() -> Self {
        RevertCore { state: State::Idle }
    }
}

impl RevertCore {
    pub(crate) fn new() -> RevertCore {
        RevertCore::default()
    }

    /// Whether a revert runs (or waits, stuck, for the next start).
    pub(crate) fn busy(&self) -> bool {
        self.state != State::Idle
    }

    /// The step running now.
    pub(crate) fn at(&self) -> Option<RevertStep> {
        match &self.state {
            State::Running { at, .. } => Some(*at),
            _ => None,
        }
    }

    /// The effects of entering step AT of P.
    fn enter(&mut self, p: Pending, at: RevertStep) -> Vec<RevertEffect> {
        use RevertEffect as E;
        let fx = match at {
            RevertStep::Quiet => {
                if p.live {
                    vec![E::Detach, E::StopJobs]
                } else {
                    vec![E::StopJobs]
                }
            }
            RevertStep::Rescan => vec![E::Rescan],
            RevertStep::Record => vec![E::Record],
            RevertStep::Files => {
                let mut v: Vec<E> = p.paths.iter().cloned().map(E::ExpectWrite).collect();
                v.push(E::WriteFiles);
                v
            }
            RevertStep::Graph => vec![E::Graph],
            RevertStep::Conversation => vec![E::Rewind],
            RevertStep::Commit => vec![E::Commit],
            RevertStep::Clear => vec![E::Clear],
        };
        self.state = State::Running { p, at };
        fx
    }

    /// The step after AT for P, and what is said on the way.
    fn next(p: &Pending, at: RevertStep) -> (Vec<RevertEffect>, Option<RevertStep>) {
        use RevertEffect as E;
        use RevertStep as S;
        match at {
            S::Quiet => (vec![], Some(S::Rescan)),
            S::Rescan => (vec![], Some(S::Record)),
            S::Record => (vec![], Some(S::Files)),
            S::Files => (vec![], Some(S::Graph)),
            // a finished worker has no conversation to restore: said once, and the commit next
            S::Graph if !p.live => (vec![E::NotRestored], Some(S::Commit)),
            S::Graph => (vec![], Some(S::Conversation)),
            S::Conversation => (vec![E::Reattach], Some(S::Commit)),
            S::Commit => (vec![], Some(S::Clear)),
            S::Clear => (vec![E::Broadcast, E::TellManager], None),
        }
    }

    pub(crate) fn step(&mut self, ev: RevertEvent) -> Vec<RevertEffect> {
        use RevertEffect as E;
        use RevertStep as S;
        match ev {
            RevertEvent::Begin(p) => match self.state {
                State::Idle => self.enter(p, S::Quiet),
                _ => vec![E::Refuse("busy")],
            },
            RevertEvent::Resume(p) => match self.state {
                // only the durable steps again: each one is idempotent in the shell
                State::Idle | State::Stuck => self.enter(p, S::Files),
                State::Running { .. } => vec![E::Refuse("busy")],
            },
            RevertEvent::Done(step) => {
                let State::Running { p, at } = &self.state else {
                    return vec![];
                };
                if *at != step {
                    return vec![];
                }
                let p = p.clone();
                let (mut fx, then) = Self::next(&p, step);
                match then {
                    Some(n) => fx.extend(self.enter(p, n)),
                    None => self.state = State::Idle,
                }
                fx
            }
            RevertEvent::Failed(step) => {
                let State::Running { p, at } = &self.state else {
                    return vec![];
                };
                if *at != step {
                    return vec![];
                }
                let p = p.clone();
                match step {
                    // nothing is durable yet: the session goes on as it was
                    S::Quiet | S::Rescan | S::Record => {
                        self.state = State::Idle;
                        let mut fx = Vec::new();
                        if p.live {
                            fx.push(E::Reattach);
                        }
                        fx.push(E::Refuse(if step == S::Rescan {
                            "stale"
                        } else {
                            "failed"
                        }));
                        fx
                    }
                    // the conversation could not be restored: the session goes on in the old one
                    S::Conversation => {
                        let mut fx = vec![E::NotRestored, E::Reattach];
                        fx.extend(self.enter(p, S::Commit));
                        fx
                    }
                    // reported, not fatal: the files stand
                    S::Commit => self.enter(p, S::Clear),
                    S::Files | S::Graph | S::Clear => {
                        self.state = State::Stuck;
                        vec![]
                    }
                }
            }
            RevertEvent::Crash => {
                self.state = State::Idle;
                vec![]
            }
            // queued by the session's turn core while it is detached; started after the reattach
            RevertEvent::UserSend | RevertEvent::UserStop | RevertEvent::OldTurnDone => vec![],
            // a job stopped writes nothing the revert reads
            RevertEvent::JobEnded => vec![],
            RevertEvent::RunnerPatch(id) => match self.state {
                State::Idle => vec![],
                _ => vec![E::KeepPatch(id)],
            },
            // announced as the hub's before the write
            RevertEvent::OwnWrite(_) => vec![],
        }
    }
}

#[cfg(test)]
mod tests;
