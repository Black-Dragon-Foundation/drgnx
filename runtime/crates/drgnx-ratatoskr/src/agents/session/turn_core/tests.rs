//! The session's turn core in every order of its sources (skuld), within the declared events.
//!
//! The test's own bookkeeping plays the shell and the agent: the agent works on the turn the core started and answers
//! it once (cancelled when it was told to cancel); a stop's deadline fires for the turn that Stop armed it for; a
//! process the core ends fails its turn's prompt as closed, then exits; a Stop with no turn running ends the session,
//! as `Hub::stop` does.

use super::{KillWhy, QueueEdit, TurnCore, TurnEffect, TurnEvent};
use crate::agents::queue::{Origin, Queued};
use runstav::methods::agents::SessionStatus;
use skuld::{Bound, Core, Mode, Partial, every_order};
use std::collections::BTreeMap;

fn item(text: &str, origin: Origin) -> Queued {
    Queued {
        text: text.into(),
        origin,
        steer: false,
        key: None,
    }
}

fn send(text: &str) -> TurnEvent {
    TurnEvent::Send {
        item: item(text, Origin::User),
        steer_mode: false,
        if_free: false,
    }
}

/// The core under test, and what the shell and the agent saw of it.
struct Shell {
    core: TurnCore,
    /// The turn the agent works on (its prompt is unanswered).
    running: Option<u64>,
    /// The agent was told to cancel the running turn.
    cancel_sent: bool,
    /// The turn the agent is answering now.
    answering: Option<u64>,
    /// The turns started, with their prompt's text.
    started: Vec<(u64, String)>,
    ended: Vec<u64>,
    /// Cancels sent, per turn.
    cancels: BTreeMap<u64, u32>,
    /// The stops' deadlines, in the order they were armed: the turn each is for.
    deadlines: Vec<u64>,
    /// A Stop held the queue and nothing delivered it since.
    held_by_stop: bool,
    /// Texts sent, and texts removed from the queue.
    sent: Vec<String>,
    unqueued: Vec<String>,
    /// Permission requests the matrix asked about, and their replies.
    asked: Vec<u64>,
    replies: BTreeMap<u64, Vec<&'static str>>,
    /// The first broken invariant.
    broken: Option<String>,
}

impl Shell {
    fn new() -> Shell {
        let mut core = TurnCore::new();
        core.ready(false);
        Shell {
            core,
            running: None,
            cancel_sent: false,
            answering: None,
            started: Vec::new(),
            ended: Vec::new(),
            cancels: BTreeMap::new(),
            deadlines: Vec::new(),
            held_by_stop: false,
            sent: Vec::new(),
            unqueued: Vec::new(),
            asked: Vec::new(),
            replies: BTreeMap::new(),
            broken: None,
        }
    }

    fn note(&mut self, what: String) {
        self.broken.get_or_insert(what);
    }

    /// Steps the core and plays the shell's part of each effect, noting the invariants a step can break.
    fn feed(&mut self, ev: TurnEvent) -> Vec<TurnEffect> {
        let fx = self.core.step(ev);
        for e in &fx {
            match e {
                TurnEffect::StartTurn { turn, item } => {
                    // a turn starts only when none runs, and a prompt starts once
                    if let Some(r) = self.running {
                        self.note(format!(
                            "turn {turn} ({}) started while turn {r} runs",
                            item.text
                        ));
                    }
                    if self.started.iter().any(|(_, t)| *t == item.text) {
                        self.note(format!("{} started twice", item.text));
                    }
                    if self.held_by_stop {
                        self.note(format!(
                            "{} started though a Stop held the queue",
                            item.text
                        ));
                    }
                    self.running = Some(*turn);
                    self.cancel_sent = false;
                    self.started.push((*turn, item.text.clone()));
                }
                TurnEffect::EndTurn { turn, .. } => {
                    // a turn ends once, at its agent's answer
                    if self.ended.contains(turn) {
                        self.note(format!("turn {turn} ended twice"));
                    }
                    if self.answering != Some(*turn) {
                        self.note(format!(
                            "turn {turn} ended while the agent answered {:?}",
                            self.answering
                        ));
                    }
                    self.ended.push(*turn);
                }
                TurnEffect::CancelTurn => {
                    let t = self.core.turn();
                    *self.cancels.entry(t).or_default() += 1;
                    self.cancel_sent = true;
                }
                TurnEffect::ArmStopDeadline { turn } => {
                    self.deadlines.push(*turn);
                    self.held_by_stop = true;
                }
                TurnEffect::Answer { request } => self.reply(*request, "answered"),
                TurnEffect::Cancel { request } => self.reply(*request, "cancelled"),
                _ => {}
            }
        }
        if fx.contains(&TurnEffect::NotRunning) {
            // `Hub::stop` on a session with no turn running ends it
            self.feed(TurnEvent::Kill { why: KillWhy::User });
            self.feed(TurnEvent::Exited);
        }
        fx
    }

    fn reply(&mut self, request: u64, how: &'static str) {
        if !self.asked.contains(&request) {
            self.note(format!("r{request} {how} before it was asked"));
        }
        let r = self.replies.entry(request).or_default();
        r.push(how);
        if r.len() > 1 {
            let all = r.clone();
            self.note(format!("r{request} answered {} times: {all:?}", all.len()));
        }
    }

    fn send(&mut self, text: &str) {
        self.sent.push(text.into());
        // a prompt sent while no turn runs releases what a Stop held
        if self.running.is_none() {
            self.held_by_stop = false;
        }
        self.feed(send(text));
    }

    /// The agent answers the turn it works on, if any.
    fn done(&mut self) {
        let Some(t) = self.running.take() else { return };
        self.answering = Some(t);
        let cancelled = self.cancel_sent;
        self.feed(TurnEvent::PromptDone {
            cancelled,
            jobs: false,
        });
        self.answering = None;
    }

    /// The I-th stop's deadline fires, if that many were armed.
    fn due(&mut self, i: usize) {
        let Some(&t) = self.deadlines.get(i) else {
            return;
        };
        let fx = self.feed(TurnEvent::Kill {
            why: KillWhy::StopDue { turn: t },
        });
        if fx.contains(&TurnEffect::KillProcess) {
            if self.running != Some(t) {
                self.note(format!(
                    "turn {t}'s deadline ended the process while turn {:?} runs",
                    self.running
                ));
            }
            // the process is gone: its prompt fails as closed, then it exits
            if let Some(r) = self.running.take() {
                self.answering = Some(r);
                self.feed(TurnEvent::PromptFailed {
                    closed: true,
                    jobs: false,
                });
                self.answering = None;
            }
            self.feed(TurnEvent::Exited);
        }
    }

    /// The front of the queue is removed (`agents/do unqueue 0`).
    fn unqueue_front(&mut self) {
        let front = self.core.queue().texts().first().cloned();
        let fx = self.feed(TurnEvent::QueueEdited(QueueEdit::Unqueue(0)));
        if let Some(t) = front.filter(|_| !fx.contains(&TurnEffect::NoSuchItem)) {
            self.unqueued.push(t);
        }
    }

    fn deliver(&mut self) {
        self.held_by_stop = false;
        self.feed(TurnEvent::QueueEdited(QueueEdit::Deliver));
    }

    /// Nothing waits that could run: a session idle and not held has an empty queue.
    fn no_stall(&self) -> Result<(), String> {
        let idle = matches!(
            self.core.status(),
            SessionStatus::Idle | SessionStatus::Waiting
        );
        if idle && !self.core.paused() && !self.core.queue().is_empty() {
            return Err(format!(
                "idle and not held, but {:?} wait",
                self.core.queue().texts()
            ));
        }
        Ok(())
    }
}

// ---- a stop ends the turn once ----

/// The user sends two prompts, stops and delivers the held queue; the refused waits stop the turn too; the agent
/// answers what it works on; each stop's deadline fires.
#[derive(Clone, Debug)]
enum StopEv {
    Send(&'static str),
    Stop,
    Deliver,
    Done,
    Due(usize),
}
skuld::events!(StopEv {
    Send,
    Stop,
    Deliver,
    Done,
    Due
});

impl Core for Shell {
    type Event = StopEv;

    fn step(&mut self, ev: StopEv) -> Vec<StopEv> {
        match ev {
            StopEv::Send(t) => self.send(t),
            StopEv::Stop => {
                self.feed(TurnEvent::Stop { after_tool: false });
            }
            StopEv::Deliver => self.deliver(),
            StopEv::Done => self.done(),
            StopEv::Due(i) => self.due(i),
        }
        Vec::new()
    }
}

fn check_stop(s: &Shell, _: &[StopEv]) -> Result<(), String> {
    if let Some(b) = &s.broken {
        return Err(b.clone());
    }
    // one cancel and one deadline per stopped turn
    if let Some((t, n)) = s.cancels.iter().find(|(_, n)| **n > 1) {
        return Err(format!("turn {t} was told to cancel {n} times"));
    }
    let mut d = s.deadlines.clone();
    d.dedup();
    if d.len() != s.deadlines.len() {
        return Err(format!("deadlines armed: {:?}", s.deadlines));
    }
    s.no_stall()
}

#[test]
fn every_order_a_stop_ends_the_turn_once() {
    let mut p = Partial::new();
    let user = p.source(
        "user",
        vec![
            StopEv::Send("a"),
            StopEv::Send("b"),
            StopEv::Stop,
            StopEv::Deliver,
        ],
    );
    // the refused waits stop a turn that runs (a wait is refused inside one)
    let refusals = p.source("refusals", vec![StopEv::Stop]);
    let agent = p.source("agent", vec![StopEv::Done, StopEv::Done]);
    let timer = p.source("timer", vec![StopEv::Due(0), StopEv::Due(1)]);
    p.before((user, 0), (refusals, 0));
    p.before((user, 0), (agent, 0));
    p.before((user, 2), (timer, 0));
    let r = every_order(&p, Bound::default(), Shell::new, check_stop);
    assert_eq!(r.mode, Mode::Exhaustive);
    assert!(r.orders > 100, "{} orders", r.orders);
}

// ---- a queued send runs after the turn ----

/// The user sends three prompts and a peer one; the editor removes the front of the queue and delivers it; the agent
/// answers what it works on.
#[derive(Clone, Debug)]
enum QueueEv {
    Send(&'static str),
    Peer(&'static str),
    Unqueue,
    Deliver,
    Done,
}
skuld::events!(QueueEv {
    Send,
    Peer,
    Unqueue,
    Deliver,
    Done
});

struct QueueShell(Shell);

impl Core for QueueShell {
    type Event = QueueEv;

    fn step(&mut self, ev: QueueEv) -> Vec<QueueEv> {
        let s = &mut self.0;
        match ev {
            QueueEv::Send(t) => s.send(t),
            QueueEv::Peer(t) => {
                s.sent.push(t.into());
                s.feed(TurnEvent::Send {
                    item: item(t, Origin::Peer("w".into())),
                    steer_mode: true,
                    if_free: false,
                });
            }
            QueueEv::Unqueue => s.unqueue_front(),
            QueueEv::Deliver => s.deliver(),
            QueueEv::Done => s.done(),
        }
        Vec::new()
    }
}

fn check_queue(q: &QueueShell, _: &[QueueEv]) -> Result<(), String> {
    let s = &q.0;
    if let Some(b) = &s.broken {
        return Err(b.clone());
    }
    // every prompt sent ran, waits or was removed: once, and only one of them
    let mut seen: Vec<String> = s.started.iter().map(|(_, t)| t.clone()).collect();
    seen.extend(s.core.queue().texts());
    seen.extend(s.unqueued.iter().cloned());
    seen.sort();
    let mut sent = s.sent.clone();
    sent.sort();
    if seen != sent {
        return Err(format!(
            "sent {sent:?}; started {:?}, queued {:?}, removed {:?}",
            s.started,
            s.core.queue().texts(),
            s.unqueued
        ));
    }
    // the user's own prompts start in the order sent
    let mine: Vec<&str> = s
        .started
        .iter()
        .map(|(_, t)| t.as_str())
        .filter(|t| t.starts_with('u'))
        .collect();
    if !mine.is_sorted() {
        return Err(format!("the user's prompts started as {mine:?}"));
    }
    s.no_stall()
}

#[test]
fn every_order_a_queued_send_runs_after_the_turn() {
    let mut p = Partial::new();
    p.source(
        "user",
        vec![
            QueueEv::Send("u1"),
            QueueEv::Send("u2"),
            QueueEv::Send("u3"),
        ],
    );
    p.source("peer", vec![QueueEv::Peer("p1")]);
    p.source("editor", vec![QueueEv::Unqueue, QueueEv::Deliver]);
    p.source("agent", vec![QueueEv::Done, QueueEv::Done, QueueEv::Done]);
    let r = every_order(
        &p,
        Bound::default(),
        || QueueShell(Shell::new()),
        check_queue,
    );
    assert_eq!(r.mode, Mode::Exhaustive);
    assert_eq!(r.orders, 5040);
}

// ---- a held permission is answered or cancelled once ----

/// The user sends a prompt, answers both requests and stops; the matrix asks the user about the agent's two requests
/// (its answer comes in a task of its own, so it may come after the turn was cancelled or ended); the agent completes
/// a tool call and answers its turn; the user pauses after the tool call; the cockpit settles the first request's
/// card.
#[derive(Clone, Debug)]
enum PermEv {
    Send,
    Ask(u64),
    Answer(u64),
    Stop,
    Pause,
    ToolCompleted,
    Done,
}
skuld::events!(PermEv {
    Send,
    Ask,
    Answer,
    Stop,
    Pause,
    ToolCompleted,
    Done
});

struct PermShell(Shell);

impl Core for PermShell {
    type Event = PermEv;

    fn step(&mut self, ev: PermEv) -> Vec<PermEv> {
        let s = &mut self.0;
        match ev {
            PermEv::Send => s.send("u1"),
            // the reader received it during turn 1; the matrix's decision may come after the turn's end
            PermEv::Ask(request) => {
                s.asked.push(request);
                s.feed(TurnEvent::PermissionAsked { request, turn: 1 });
            }
            PermEv::Answer(request) => {
                s.feed(TurnEvent::PermissionAnswered { request });
            }
            PermEv::Stop => {
                s.feed(TurnEvent::Stop { after_tool: false });
            }
            PermEv::Pause => {
                s.feed(TurnEvent::Stop { after_tool: true });
            }
            PermEv::ToolCompleted => {
                s.feed(TurnEvent::ToolCompleted);
            }
            PermEv::Done => s.done(),
        }
        Vec::new()
    }
}

fn check_perm(p: &PermShell, _: &[PermEv]) -> Result<(), String> {
    let s = &p.0;
    if let Some(b) = &s.broken {
        return Err(b.clone());
    }
    // once the turn is over or cancelled, every request asked has its one reply; while it runs, the rest wait
    let over = s.ended.contains(&1) || s.cancels.contains_key(&1);
    for r in &s.asked {
        let replied = s.replies.contains_key(r);
        let held = s.core.held().contains(r);
        if replied == held {
            return Err(format!(
                "r{r}: replied {replied}, held {held} (turn 1 over or cancelled: {over})"
            ));
        }
        if over && !replied {
            return Err(format!("r{r} waits, but turn 1 is over or cancelled"));
        }
    }
    Ok(())
}

#[test]
fn every_order_a_held_permission_is_answered_or_cancelled_once() {
    let mut p = Partial::new();
    let user = p.source(
        "user",
        vec![
            PermEv::Send,
            PermEv::Answer(1),
            PermEv::Answer(2),
            PermEv::Stop,
        ],
    );
    let matrix = p.source("matrix", vec![PermEv::Ask(1), PermEv::Ask(2)]);
    let agent = p.source("agent", vec![PermEv::ToolCompleted, PermEv::Done]);
    let pauser = p.source("pauser", vec![PermEv::Pause]);
    p.source("cockpit", vec![PermEv::Answer(1)]);
    // the agent asks and works only in a turn, and the pause is the user's, after the send
    p.before((user, 0), (matrix, 0));
    p.before((user, 0), (agent, 0));
    p.before((user, 0), (pauser, 0));
    let r = every_order(&p, Bound::default(), || PermShell(Shell::new()), check_perm);
    assert_eq!(r.mode, Mode::Exhaustive);
    assert!(r.orders > 100, "{} orders", r.orders);
}

// ---- single cases the shell relies on ----

#[test]
fn only_an_idle_unheld_session_with_nothing_queued_is_free() {
    let mut c = TurnCore::new();
    c.ready(false);
    assert!(c.is_free());
    c.step(send("a"));
    assert!(!c.is_free(), "a turn runs");
    c.step(TurnEvent::PromptDone {
        cancelled: false,
        jobs: true,
    });
    assert!(!c.is_free(), "a job's result is awaited");
    c.ready(false);
    c.step(TurnEvent::Stop { after_tool: true });
    assert!(!c.is_free(), "a pause holds it");
    c.step(TurnEvent::QueueEdited(QueueEdit::Deliver));
    assert!(c.is_free());
    c.queue_mut().push("waiting".into(), Origin::User, false);
    assert!(!c.is_free(), "a message is queued");
}

#[test]
fn a_send_when_not_free_is_nothing() {
    let mut c = TurnCore::new();
    c.ready(false);
    c.step(send("a"));
    let fx = c.step(TurnEvent::Send {
        item: item("b", Origin::User),
        steer_mode: false,
        if_free: true,
    });
    assert_eq!(fx, [TurnEffect::NotFree]);
    assert!(c.queue().is_empty());
}

#[test]
fn the_event_pair_waits_for_its_timer() {
    let mut c = TurnCore::new();
    assert_eq!(c.step(TurnEvent::Changed), [TurnEffect::ArmEmit]);
    assert!(c.step(TurnEvent::Changed).is_empty());
    assert_eq!(c.step(TurnEvent::EmitTick), [TurnEffect::Emit]);
    assert_eq!(c.step(TurnEvent::Changed), [TurnEffect::ArmEmit]);
}

#[test]
fn a_send_while_the_hub_ends_waits_in_the_queue() {
    let mut c = TurnCore::new();
    c.ready(false);
    c.step(TurnEvent::Kill {
        why: KillWhy::HubEnding,
    });
    let fx = c.step(send("a"));
    assert!(
        !fx.iter().any(|e| matches!(e, TurnEffect::StartTurn { .. })),
        "{fx:?}"
    );
    assert_eq!(c.queue().texts(), ["a"]);
}
