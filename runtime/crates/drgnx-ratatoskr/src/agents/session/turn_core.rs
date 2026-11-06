//! A session's turn, queue, Stop and permission choices, without I/O (docs/develop/hub.md, "A session's turn"): when
//! a prompt starts a turn or waits in the queue, when a turn ends and what follows it, what a Stop, a pause after a
//! tool call or a kill does to the turn, which permission requests the user is asked and when each is answered or
//! cancelled, and when an event pair is sent.  The shell ([`super::Session`]) does the I/O and feeds every event
//! through [`TurnCore::step`]; the entries, steps and transcript stay with `State::apply` and the shell.
//!
//! The edges the shell keeps: a turn's `PromptDone` or `PromptFailed` comes after its `StartTurn`, and after every
//! update the agent sent in that turn (the reader drains them first); a `PermissionAsked` names the turn that was
//! running when the reader received the request; a `Kill` for a stop's deadline names the turn that Stop stopped; a
//! turn's prompt goes to the agent only when its `Sending` step answers `Prompt` (the hub's end, a Stop, the agent's
//! exit or the user's kill may come between the turn's start and its send: the hub's end, the Stop and the exit then
//! put the prompt back at the front of the queue, the user's kill names it with what it discards).

use super::super::queue::{Origin, Queue, Queued};
use runstav::methods::agents::SessionStatus;

/// What happens to a session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum TurnEvent {
    /// A prompt arrives.  STEER_MODE: the profile's mode is `steer` (the prompt goes ahead of the ordinary queued ones
    /// while a turn runs).  IF_FREE: a turn or nothing (`agents/send` with `if_free`).
    Send {
        item: Queued,
        steer_mode: bool,
        if_free: bool,
    },
    /// The agent answered the turn's prompt; CANCELLED: its stop reason is `cancelled`.  JOBS: a job the session
    /// started still runs.
    PromptDone { cancelled: bool, jobs: bool },
    /// The turn's prompt failed; CLOSED: the agent's connection closed.
    PromptFailed { closed: bool, jobs: bool },
    /// The user's Stop (or the refused waits'); AFTER_TOOL: the pause, which cancels once the running tool call
    /// completes (`Hub::cancel_after_tool`).
    Stop { after_tool: bool },
    /// The agent's process is to end.
    Kill { why: KillWhy },
    /// The matrix asks the user about permission request REQUEST, which the agent sent during TURN, through matrix
    /// card CARD when the store made one.
    PermissionAsked {
        request: u64,
        turn: u64,
        card: Option<i64>,
    },
    /// The user answered REQUEST (or settled its matrix card).
    PermissionAnswered { request: u64 },
    /// A tool call completed or failed.
    ToolCompleted,
    /// The event pair's timer fired.
    EmitTick,
    /// The queue was edited (`agents/do`, the freshness gate's notice).
    QueueEdited(QueueEdit),
    /// Something the snapshot shows changed (an update, an entry, a step).
    Changed,
    /// The agent's process exited.
    Exited,
    /// The shell is about to hand turn TURN's prompt to the agent (`Session::turn`).
    Sending { turn: u64 },
}

/// Why the agent's process ends.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum KillWhy {
    /// `agents/kill`, or `agents/stop` with no turn running.
    User,
    /// The hub ends: nothing is held for a Stop, and the queue stays on disk for the next start.
    HubEnding,
    /// A Stop's deadline for TURN: the process ends only if that turn still runs.
    StopDue { turn: u64 },
}

/// An edit of the queue.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum QueueEdit {
    /// The held queue is released and the next prompt sent.
    Deliver,
    /// The Nth waiting prompt is removed.
    Unqueue(usize),
    /// The Nth waiting prompt's text is replaced; an empty text removes it.
    Requeue(usize, String),
    /// TEXT goes ahead of the ordinary queued prompts, without starting a turn (the freshness gate's notice).
    SteerIn(String),
    /// The user gave the wheel back: ITEM goes first, the hold lifts and the next prompt starts.
    Resume(Queued),
}

/// What the shell does about a step.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum TurnEffect {
    /// Refused: the session has exited, or its process is ending for good (the user's kill, a Stop's deadline; the
    /// hub's end is not: a prompt sent then waits on disk for the next start).
    Exited,
    /// Refused: `if_free`, and the session is not free.
    NotFree,
    /// A Stop with no turn running: the hub ends the session.
    NotRunning,
    /// Refused: no such queued prompt.
    NoSuchItem,
    /// Refused: no such permission request waits (answered or cancelled already).
    NoSuchRequest,
    /// Turn TURN starts with ITEM: its prompt is to go to the agent ([`TurnEvent::Sending`] says whether it still
    /// does).
    StartTurn { turn: u64, item: Queued },
    /// Turn TURN's prompt goes to the agent now (with a `Persist`: it leaves the queue on disk).
    Prompt { turn: u64 },
    /// Turn TURN's prompt never reached the agent and is back at the front of the queue (the hub's end, a Stop, or
    /// the agent's exit): what the turn began (its entry, its step) is undone.
    PutBack { turn: u64 },
    /// The user's kill drops these prompts, which never reached the agent (the queue, and a turn not yet sent).
    Discard(Vec<Queued>),
    /// Turn TURN ended.  WAITING: on a job (no model request until the wake); PAUSED: the queue is held.
    EndTurn {
        turn: u64,
        waiting: bool,
        paused: bool,
    },
    /// The agent is told to cancel the turn (`session/cancel`).
    CancelTurn,
    /// The Stop's deadline for TURN: a `Kill` with [`KillWhy::StopDue`] after `STOP_ANSWER`.
    ArmStopDeadline { turn: u64 },
    /// The agent's process group ends.
    KillProcess,
    /// The request waits for the user, in the snapshot.
    Hold { request: u64 },
    /// The user's answer goes to the agent.
    Answer { request: u64 },
    /// The request is answered cancelled.
    Cancel { request: u64 },
    /// Matrix card CARD is withdrawn: every request that waited on it was answered cancelled, so nobody answers it.
    Withdraw { card: i64 },
    /// The queue and the pause are kept on disk ([`TurnCore::kept`]).
    Persist,
    /// The snapshot changed: its change number goes up and an event pair is due.
    Announce,
    /// The event pair's timer starts (`EMIT_EVERY`).
    ArmEmit,
    /// The event pair is sent now.
    Emit,
}

/// See the module.
#[derive(Debug)]
#[cfg_attr(test, derive(Clone))]
pub(crate) struct TurnCore {
    status: SessionStatus,
    /// Prompts waiting for the turn to end (or held).
    queue: Queue,
    /// The queue is held (a Stop, an error, the pause after a tool call) until delivered or something new is sent.
    paused: bool,
    /// Cancel once the running tool call completes.
    hold: bool,
    /// The turn running, counting from 1.
    turn: u64,
    /// The prompt of the turn running while the shell has not handed it to the agent.
    unsent: Option<Queued>,
    /// The agent was told to cancel this turn.
    cancelling: bool,
    /// A Stop armed its deadline for this turn.
    stopped: bool,
    /// The process is being ended (a kill, a Stop's deadline): no turn starts, and unless the hub is ending, no prompt
    /// is taken.
    killed: bool,
    /// The hub is ending: a turn's end holds nothing and starts nothing, and no event pair is armed or sent.
    ending: bool,
    /// The requests the user is asked, oldest first, with the matrix card each waits on.
    held: Vec<(u64, Option<i64>)>,
    /// The event pair's timer runs.
    emit_armed: bool,
    /// The user holds the wheel (`agents::wheel`): no turn starts, whatever is sent or delivered, until the give.
    wheel: bool,
}

impl Default for TurnCore {
    fn default() -> Self {
        TurnCore {
            status: SessionStatus::Starting,
            queue: Queue::default(),
            paused: false,
            hold: false,
            turn: 0,
            unsent: None,
            cancelling: false,
            stopped: false,
            killed: false,
            ending: false,
            held: Vec::new(),
            emit_armed: false,
            wheel: false,
        }
    }
}

impl TurnCore {
    pub(crate) fn new() -> TurnCore {
        TurnCore::default()
    }

    pub(crate) fn step(&mut self, ev: TurnEvent) -> Vec<TurnEffect> {
        use TurnEffect as E;
        match ev {
            TurnEvent::Send {
                item,
                steer_mode,
                if_free,
            } => {
                // a process ending for good runs nothing more: the sender keeps what it sent (the hub's end keeps the
                // queue on disk instead)
                if self.status == SessionStatus::Exited || (self.killed && !self.ending) {
                    return vec![E::Exited];
                }
                if if_free && !self.is_free() {
                    return vec![E::NotFree];
                }
                let idle = self.idle();
                self.queue
                    .push_keyed(item.text, item.origin, !idle && steer_mode, item.key);
                if idle {
                    self.paused = false;
                }
                let mut fx = vec![E::Persist];
                if idle {
                    fx.extend(self.next());
                }
                fx.push(E::Announce);
                fx
            }
            TurnEvent::PromptDone { cancelled, jobs } => {
                self.finish(cancelled && !self.ending, jobs)
            }
            TurnEvent::PromptFailed { closed, jobs } => self.finish(!closed && !self.ending, jobs),
            TurnEvent::Stop { after_tool: true } => {
                match self.status {
                    SessionStatus::Exited => return vec![E::Exited],
                    SessionStatus::Busy => self.hold = true,
                    _ => self.paused = true,
                }
                vec![E::Persist, E::Announce]
            }
            TurnEvent::Stop { after_tool: false } => {
                if self.status != SessionStatus::Busy {
                    return vec![E::NotRunning];
                }
                if let Some(item) = self.unsent.take() {
                    // the turn's prompt has not reached the agent: Stop wins, the turn never ran (no cancel, no
                    // deadline), and its prompt waits at the front of the held queue
                    self.queue.push_front(item);
                    self.status = SessionStatus::Idle;
                    self.paused = true;
                    self.hold = false;
                    return vec![E::PutBack { turn: self.turn }, E::Persist, E::Announce];
                }
                if self.stopped {
                    // stopped already: the turn ends once, at the agent's answer or the first deadline
                    return Vec::new();
                }
                self.paused = true;
                self.hold = false;
                self.stopped = true;
                let mut fx = self.cancel();
                fx.extend([
                    E::Persist,
                    E::Announce,
                    E::ArmStopDeadline { turn: self.turn },
                ]);
                fx
            }
            TurnEvent::Kill {
                why: KillWhy::StopDue { turn },
            } => {
                if self.status == SessionStatus::Busy && self.turn == turn {
                    // nothing starts on the process that ends now (a queued prompt, a wake)
                    self.killed = true;
                    vec![E::KillProcess]
                } else {
                    Vec::new()
                }
            }
            TurnEvent::Kill { why } => {
                self.killed = true;
                let mut fx = self.cancel_held();
                let unsent = self.unsent.take();
                if why == KillWhy::HubEnding {
                    self.ending = true;
                    // a turn whose prompt has not reached the agent never ran: the prompt waits on disk for the next
                    // start, at the front of the queue, where it was
                    if let Some(item) = unsent {
                        self.queue.push_front(item);
                        self.status = SessionStatus::Idle;
                        fx.extend([E::PutBack { turn: self.turn }, E::Persist]);
                    }
                } else {
                    // the session ends for good: what never reached the agent goes with it
                    let mut dropped: Vec<Queued> = unsent.into_iter().collect();
                    dropped.extend(self.queue.items().cloned());
                    if !dropped.is_empty() {
                        fx.push(E::Discard(dropped));
                    }
                }
                fx
            }
            TurnEvent::Sending { turn } => {
                // the turn is still to send: not put back by the hub's end, not on a process being ended; from now on
                // its prompt is the agent's, and no longer on disk
                if turn == self.turn && !self.killed && self.unsent.take().is_some() {
                    vec![E::Prompt { turn }, E::Persist]
                } else {
                    Vec::new()
                }
            }
            TurnEvent::PermissionAsked {
                request,
                turn,
                card,
            } => {
                let asked = self.status == SessionStatus::Busy
                    && turn == self.turn
                    && !self.cancelling
                    && !self.killed;
                if asked {
                    self.held.push((request, card));
                    vec![E::Hold { request }]
                } else {
                    // its turn is cancelled or over: nobody will answer it, nor its card unless another request waits
                    // on that
                    let mut fx = vec![E::Cancel { request }];
                    if let Some(card) =
                        card.filter(|c| !self.held.iter().any(|(_, h)| *h == Some(*c)))
                    {
                        fx.push(E::Withdraw { card });
                    }
                    fx
                }
            }
            TurnEvent::PermissionAnswered { request } => {
                if self.take_held(request) {
                    vec![E::Answer { request }]
                } else {
                    vec![E::NoSuchRequest]
                }
            }
            TurnEvent::ToolCompleted => {
                if !self.hold {
                    return Vec::new();
                }
                // the pause after a tool call: the turn ends here, the queue waits
                self.hold = false;
                self.paused = true;
                let mut fx = self.cancel();
                fx.push(E::Persist);
                fx
            }
            TurnEvent::EmitTick => {
                self.emit_armed = false;
                // while the hub ends no pair goes out: the snapshot is read at the send and may show the session's own
                // exit, and the editors learn of the end from their connection's end of file
                if self.ending {
                    return Vec::new();
                }
                vec![E::Emit]
            }
            TurnEvent::Changed => {
                if self.emit_armed || self.ending {
                    return Vec::new();
                }
                self.emit_armed = true;
                vec![E::ArmEmit]
            }
            TurnEvent::QueueEdited(edit) => {
                match edit {
                    QueueEdit::Deliver => {
                        self.paused = false;
                        let mut fx = vec![E::Persist];
                        fx.extend(self.next());
                        fx.push(E::Announce);
                        return fx;
                    }
                    QueueEdit::Unqueue(n) => {
                        if self.queue.remove(n).is_none() {
                            return vec![E::NoSuchItem];
                        }
                    }
                    QueueEdit::Requeue(n, text) => {
                        let done = if text.trim().is_empty() {
                            self.queue.remove(n).is_some()
                        } else {
                            self.queue.replace(n, text)
                        };
                        if !done {
                            return vec![E::NoSuchItem];
                        }
                    }
                    QueueEdit::SteerIn(text) => self.queue.push(text, Origin::Hub, true),
                    QueueEdit::Resume(item) => {
                        self.wheel = false;
                        self.paused = false;
                        self.queue.push_front(item);
                        let mut fx = vec![E::Persist];
                        fx.extend(self.next());
                        fx.push(E::Announce);
                        return fx;
                    }
                }
                vec![E::Persist, E::Announce]
            }
            TurnEvent::Exited => {
                self.status = SessionStatus::Exited;
                let mut fx = self.cancel_held();
                // a turn whose prompt never reached the agent never ran: the prompt waits at the front of the queue,
                // on disk too, for the next start or resume
                if let Some(item) = self.unsent.take() {
                    self.queue.push_front(item);
                    fx.extend([E::PutBack { turn: self.turn }, E::Persist]);
                }
                fx
            }
        }
    }

    /// The session is up: idle, or WAITING on a job it started.  Nothing starts here ([`TurnCore::next`] does).
    pub(crate) fn ready(&mut self, waiting: bool) {
        self.status = if waiting {
            SessionStatus::Waiting
        } else {
            SessionStatus::Idle
        };
    }

    /// A session back after a restart, not yet shared: QUEUE and PAUSED as kept on disk, and TOLD (a fresh start's
    /// notice, a manager's brief) at the queue's front, so its agent reads it first and the queue stays as it was.
    pub(crate) fn resume(&mut self, queue: Queue, paused: bool, told: Option<String>) {
        self.queue = queue;
        self.paused = paused;
        if let Some(text) = told {
            self.queue.push_front(Queued {
                text,
                origin: Origin::Hub,
                steer: false,
                key: None,
            });
        }
    }

    #[cfg(test)]
    pub(crate) fn queue_mut(&mut self) -> &mut Queue {
        &mut self.queue
    }

    /// The user holds the wheel (ON) or no longer does: while held no turn starts.
    pub(crate) fn set_wheel(&mut self, on: bool) {
        self.wheel = on;
    }

    /// The next queued prompt starts when the session is idle (or waiting on a job), not held, and not ending.
    pub(crate) fn next(&mut self) -> Vec<TurnEffect> {
        if !self.idle() || self.paused || self.wheel || self.killed || self.ending {
            return Vec::new();
        }
        let Some(item) = self.queue.pop() else {
            return Vec::new();
        };
        self.status = SessionStatus::Busy;
        self.turn += 1;
        self.cancelling = false;
        self.stopped = false;
        self.unsent = Some(item.clone());
        vec![TurnEffect::StartTurn {
            turn: self.turn,
            item,
        }]
    }

    /// The turn's end.  PAUSE: its end holds the queue (cancelled, or an error).
    fn finish(&mut self, pause: bool, jobs: bool) -> Vec<TurnEffect> {
        // a pause asked for during the turn (a budget limit) holds the queue though no tool call ended it
        if (self.hold && !self.ending) || pause {
            self.paused = true;
        }
        self.hold = false;
        // the turn is over: nobody answers what it still asked
        let mut fx = self.cancel_held();
        if self.status == SessionStatus::Busy {
            self.status = if jobs {
                SessionStatus::Waiting
            } else {
                SessionStatus::Idle
            };
            fx.push(TurnEffect::EndTurn {
                turn: self.turn,
                waiting: jobs,
                paused: self.paused,
            });
        }
        // a job's result is for the model even after a Stop or the refused waits
        if self.queue.has_hub() {
            self.paused = false;
        }
        if self.ending {
            return fx;
        }
        fx.extend([TurnEffect::Persist, TurnEffect::Announce]);
        fx.extend(self.next());
        fx
    }

    /// The agent is told to cancel the turn; what it asked is answered cancelled first.
    fn cancel(&mut self) -> Vec<TurnEffect> {
        self.cancelling = true;
        let mut fx = self.cancel_held();
        fx.push(TurnEffect::CancelTurn);
        fx
    }

    /// Every held request answered cancelled, then each card they waited on withdrawn (none waits on it now).
    fn cancel_held(&mut self) -> Vec<TurnEffect> {
        let held = std::mem::take(&mut self.held);
        let mut cards: Vec<i64> = held.iter().filter_map(|(_, c)| *c).collect();
        cards.sort_unstable();
        cards.dedup();
        held.into_iter()
            .map(|(request, _)| TurnEffect::Cancel { request })
            .chain(cards.into_iter().map(|card| TurnEffect::Withdraw { card }))
            .collect()
    }

    fn take_held(&mut self, request: u64) -> bool {
        let at = self.held.iter().position(|(r, _)| *r == request);
        at.map(|i| self.held.remove(i)).is_some()
    }

    fn idle(&self) -> bool {
        matches!(self.status, SessionStatus::Idle | SessionStatus::Waiting)
    }

    /// Can a new turn start now without joining anything: idle (not busy, not waiting on a job), not held, nothing
    /// queued, and its process not being ended.
    pub(crate) fn is_free(&self) -> bool {
        self.status == SessionStatus::Idle
            && !self.paused
            && !self.wheel
            && self.queue.is_empty()
            && !self.killed
    }

    pub(crate) fn status(&self) -> SessionStatus {
        self.status
    }

    pub(crate) fn queue(&self) -> &Queue {
        &self.queue
    }

    /// What the queue on disk holds: the waiting prompts, behind the prompt of a turn that has not reached the agent
    /// yet (a hub that dies before the send finds it there at the next start).
    pub(crate) fn kept(&self) -> Queue {
        let mut q = self.queue.clone();
        if let Some(item) = &self.unsent {
            q.push_front(item.clone());
        }
        q
    }

    pub(crate) fn paused(&self) -> bool {
        self.paused
    }

    pub(crate) fn turn(&self) -> u64 {
        self.turn
    }

    pub(crate) fn ending(&self) -> bool {
        self.ending
    }

    #[cfg(test)]
    pub(crate) fn held(&self) -> Vec<u64> {
        self.held.iter().map(|(r, _)| *r).collect()
    }
}

#[cfg(test)]
mod tests;
