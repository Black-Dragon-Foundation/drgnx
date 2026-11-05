//! The session's turn core in every order of its sources (skuld), within the declared events.
//!
//! The test's own bookkeeping plays the shell and the agent: the agent works on the turn the core started and answers
//! it once (cancelled when it was told to cancel); a stop's deadline fires for the turn that Stop armed it for; a
//! process a deadline ends fails its turn's prompt as closed at the agent's next answer, then exits; a Stop with no
//! turn running ends the session, as `Hub::stop` does; the reader stamps a permission request with the turn running
//! when the agent sent it.
//!
//! After every step it checks what the shell relies on: a turn starts only when none runs, once per prompt, not while
//! the queue is held and not on a process being ended; a turn ends at its agent's answer; a request waits only while
//! the turn it came in runs, and nothing waits once the process is being ended; what is on disk is what the core
//! holds; and a free session starts a turn with the next prompt.  At the end of each order, every turn the agent
//! answered while the session was up has ended, once.

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
    /// The turns the agent answered while the session was up, in order.
    answered: Vec<u64>,
    /// Cancels sent, per turn.
    cancels: BTreeMap<u64, u32>,
    /// The stops' deadlines, in the order they were armed: the turn each is for.
    deadlines: Vec<u64>,
    /// A Stop or a pause held the queue and nothing delivered it since.
    held: bool,
    /// Texts sent, texts removed from the queue, and texts refused (the sender keeps them).
    sent: Vec<String>,
    unqueued: Vec<String>,
    refused: Vec<String>,
    /// The user killed the session: it ends and is forgotten.  The texts taken after that are lost.
    killed_by_user: bool,
    after_kill: Vec<String>,
    /// The process is being ended (a kill, a deadline) or is gone.
    doomed: bool,
    /// A deadline ended the process: the agent's next answer is its prompt failing as closed, then the exit.
    dying: bool,
    /// The queue and the pause as the shell last kept them on disk.
    disk: (Vec<String>, bool),
    /// Permission requests the agent sent, with the turn the reader stamped; those the matrix asked about, and their
    /// replies.
    turn_of: BTreeMap<u64, u64>,
    asked: Vec<u64>,
    replies: BTreeMap<u64, Vec<&'static str>>,
    /// The shell sends a turn's prompt in a step of its own after the turn started (`Session::turn`), not at once.
    gap: bool,
    /// A turn started whose prompt the shell has not sent yet, with its text.
    unsent: Option<(u64, String)>,
    /// The prompts that reached the agent, and those sent to a process the hub's end was ending.
    reached: Vec<String>,
    lost: Vec<String>,
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
            answered: Vec::new(),
            cancels: BTreeMap::new(),
            deadlines: Vec::new(),
            held: false,
            sent: Vec::new(),
            unqueued: Vec::new(),
            refused: Vec::new(),
            killed_by_user: false,
            after_kill: Vec::new(),
            doomed: false,
            dying: false,
            disk: (Vec::new(), false),
            turn_of: BTreeMap::new(),
            asked: Vec::new(),
            replies: BTreeMap::new(),
            gap: false,
            unsent: None,
            reached: Vec::new(),
            lost: Vec::new(),
            broken: None,
        }
    }

    /// A shell whose turn sends its prompt in a step of its own.
    fn with_gap() -> Shell {
        Shell {
            gap: true,
            ..Shell::new()
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
                    if self.held {
                        self.note(format!(
                            "{} started though a Stop or a pause held the queue",
                            item.text
                        ));
                    }
                    if self.doomed {
                        self.note(format!("{} started on a process being ended", item.text));
                    }
                    if let Some((t, text)) = &self.unsent {
                        self.note(format!(
                            "turn {turn} ({}) started while turn {t} ({text}) is not sent",
                            item.text
                        ));
                    }
                    if self.gap {
                        self.unsent = Some((*turn, item.text.clone()));
                    } else {
                        // the shell's turn sends at once
                        let sent = self.core.step(TurnEvent::Sending { turn: *turn });
                        if sent != [TurnEffect::Prompt { turn: *turn }, TurnEffect::Persist] {
                            self.note(format!("turn {turn} started, but its send got {sent:?}"));
                        }
                        self.running = Some(*turn);
                        self.reached.push(item.text.clone());
                    }
                    self.cancel_sent = false;
                    self.started.push((*turn, item.text.clone()));
                }
                TurnEffect::PutBack { turn } => {
                    // the turn never ran: its prompt waits in the queue again
                    if self.unsent.as_ref().map(|u| u.0) != Some(*turn) {
                        self.note(format!(
                            "turn {turn} put back, but {:?} was not sent",
                            self.unsent
                        ));
                    }
                    self.unsent = None;
                    self.started.retain(|(t, _)| t != turn);
                }
                TurnEffect::EndTurn { turn, .. } => {
                    // a turn ends at its agent's answer
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
                    self.held = true;
                }
                TurnEffect::KillProcess => {
                    self.doomed = true;
                    self.dying = true;
                }
                TurnEffect::Answer { request } => self.reply(*request, "answered"),
                TurnEffect::Cancel { request } => self.reply(*request, "cancelled"),
                _ => {}
            }
        }
        // the shell keeps the queue on disk at a Persist, and when a turn starts (`start_turn`)
        if fx
            .iter()
            .any(|e| matches!(e, TurnEffect::Persist | TurnEffect::StartTurn { .. }))
        {
            self.disk = (self.core.kept().texts(), self.core.paused());
        }
        self.after_step();
        if fx.contains(&TurnEffect::NotRunning) {
            // `Hub::stop` on a session with no turn running ends it
            self.kill(KillWhy::User);
            self.exit();
        }
        fx
    }

    /// What holds after every step.
    fn after_step(&mut self) {
        let held: Vec<u64> = self.core.held().to_vec();
        // nobody answers a request of a process being ended
        if self.doomed && !held.is_empty() {
            self.note(format!(
                "{held:?} wait for the user, but the process is being ended"
            ));
        }
        // a request waits only while the turn it came in runs
        for r in held {
            let t = self.turn_of.get(&r).copied();
            if t != self.running {
                self.note(format!(
                    "r{r} of turn {t:?} waits while turn {:?} runs",
                    self.running
                ));
            }
        }
        // a restart finds what the core holds, a prompt not yet sent included (the hub's end keeps the queue as it
        // was; its pause may move)
        let now = (self.core.kept().texts(), self.core.paused());
        if self.disk.0 != now.0 || (!self.core.ending() && self.disk.1 != now.1) {
            self.note(format!(
                "on disk {:?}, but the core holds {now:?}",
                self.disk
            ));
        }
        // free: a delivery now is a new turn
        if self.core.is_free() {
            let mut probe = self.core.clone();
            let fx = probe.step(TurnEvent::Send {
                item: item("probe", Origin::Peer("w".into())),
                steer_mode: false,
                if_free: true,
            });
            if !fx.iter().any(|e| matches!(e, TurnEffect::StartTurn { .. })) {
                self.note(format!("free, but a delivery now gets {fx:?}"));
            }
        }
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

    /// TEXT from ORIGIN: taken, or refused (the sender keeps it).
    fn prompt(&mut self, text: &str, origin: Origin, steer_mode: bool) {
        self.prompt_keyed(text, origin, steer_mode, None);
    }

    /// [`Shell::prompt`] of a prompt the hub knows by KEY.  Whether it was taken.
    fn prompt_keyed(
        &mut self,
        text: &str,
        origin: Origin,
        steer_mode: bool,
        key: Option<&str>,
    ) -> bool {
        self.sent.push(text.into());
        // a prompt sent while no turn runs releases what a Stop or a pause held
        if self.running.is_none() && self.unsent.is_none() {
            self.held = false;
        }
        let fx = self.feed(TurnEvent::Send {
            item: Queued {
                key: key.map(str::to_owned),
                ..item(text, origin)
            },
            steer_mode,
            if_free: false,
        });
        if fx.contains(&TurnEffect::Exited) {
            self.refused.push(text.into());
            return false;
        } else if self.killed_by_user {
            self.after_kill.push(text.into());
        }
        true
    }

    /// The shell's turn sends the prompt of the turn that started, if one waits: the agent works on it from now.  Sent
    /// to a process the hub's end is ending, it is lost (the agent dies with it, and the queue on disk no longer
    /// holds it).
    fn send_prompt(&mut self) {
        let Some((t, text)) = self.unsent.take() else {
            return;
        };
        // the core says whether it still goes (the hub's end may have put it back)
        if !self
            .feed(TurnEvent::Sending { turn: t })
            .contains(&TurnEffect::Prompt { turn: t })
        {
            return;
        }
        // Stop wins over a prompt that has not gone: none goes after its turn was told to cancel
        if self.cancels.contains_key(&t) {
            self.note(format!("turn {t}'s prompt ({text}) went after its cancel"));
        }
        if self.doomed {
            self.lost.push(text);
            return;
        }
        self.running = Some(t);
        self.reached.push(text);
    }

    fn send(&mut self, text: &str) {
        self.prompt(text, Origin::User, false);
    }

    /// The agent answers turn T with EV.
    fn answer(&mut self, t: u64, ev: TurnEvent) {
        self.answering = Some(t);
        if self.core.status() != SessionStatus::Exited {
            self.answered.push(t);
        }
        self.feed(ev);
        self.answering = None;
    }

    /// The process is gone: the prompt of the turn it works on, if any, fails as closed.
    fn close(&mut self) {
        if let Some(t) = self.running.take() {
            self.answer(
                t,
                TurnEvent::PromptFailed {
                    closed: true,
                    jobs: false,
                },
            );
        }
    }

    /// The agent answers the turn it works on, if any.  A process a deadline ended answers with its exit.
    fn done(&mut self) {
        if self.dying {
            self.close();
            self.exit();
            return;
        }
        let Some(t) = self.running.take() else { return };
        let cancelled = self.cancel_sent;
        self.answer(
            t,
            TurnEvent::PromptDone {
                cancelled,
                jobs: false,
            },
        );
    }

    /// The process is to end (`agents/kill`, `agents/stop` with no turn running, the hub's end).
    fn kill(&mut self, why: KillWhy) -> Vec<TurnEffect> {
        self.doomed = true;
        if why == KillWhy::User {
            self.killed_by_user = true;
        }
        self.feed(TurnEvent::Kill { why })
    }

    fn exit(&mut self) {
        self.doomed = true;
        self.dying = false;
        self.feed(TurnEvent::Exited);
    }

    /// The I-th stop's deadline fires, if that many were armed.
    fn due(&mut self, i: usize) {
        let Some(&t) = self.deadlines.get(i) else {
            return;
        };
        let fx = self.feed(TurnEvent::Kill {
            why: KillWhy::StopDue { turn: t },
        });
        if fx.contains(&TurnEffect::KillProcess) && self.running != Some(t) {
            self.note(format!(
                "turn {t}'s deadline ended the process while turn {:?} runs",
                self.running
            ));
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
        self.held = false;
        self.feed(TurnEvent::QueueEdited(QueueEdit::Deliver));
    }

    /// The user pauses after the tool call (with no turn running, the queue is held).
    fn pause(&mut self) {
        if !self
            .feed(TurnEvent::Stop { after_tool: true })
            .contains(&TurnEffect::Exited)
        {
            self.held = true;
        }
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

    /// What every order ends with: no broken step, and each turn the agent answered while the session was up ended,
    /// once.
    fn settled(&self) -> Result<(), String> {
        if let Some(b) = &self.broken {
            return Err(b.clone());
        }
        if self.ended != self.answered {
            return Err(format!(
                "the agent answered turns {:?}, but {:?} ended",
                self.answered, self.ended
            ));
        }
        Ok(())
    }

    /// Every prompt sent ran, waits, was removed or was refused: once, and only one of them.
    fn each_sent_once(&self) -> Result<(), String> {
        let mut seen: Vec<String> = self.started.iter().map(|(_, t)| t.clone()).collect();
        seen.extend(self.core.queue().texts());
        seen.extend(self.unqueued.iter().cloned());
        seen.extend(self.refused.iter().cloned());
        seen.sort();
        let mut sent = self.sent.clone();
        sent.sort();
        if seen != sent {
            return Err(format!(
                "sent {sent:?}; started {:?}, queued {:?}, removed {:?}, refused {:?}",
                self.started,
                self.core.queue().texts(),
                self.unqueued,
                self.refused
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
    s.settled()?;
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
/// answers what it works on; the user pauses after the tool call.
#[derive(Clone, Debug)]
enum QueueEv {
    Send(&'static str),
    Peer(&'static str),
    Unqueue,
    Deliver,
    Done,
    Pause,
}
skuld::events!(QueueEv {
    Send,
    Peer,
    Unqueue,
    Deliver,
    Done,
    Pause
});

struct QueueShell(Shell);

impl Core for QueueShell {
    type Event = QueueEv;

    fn step(&mut self, ev: QueueEv) -> Vec<QueueEv> {
        let s = &mut self.0;
        match ev {
            QueueEv::Send(t) => s.send(t),
            QueueEv::Peer(t) => s.prompt(t, Origin::Peer("w".into()), true),
            QueueEv::Unqueue => s.unqueue_front(),
            QueueEv::Deliver => s.deliver(),
            QueueEv::Done => s.done(),
            QueueEv::Pause => s.pause(),
        }
        Vec::new()
    }
}

fn check_queue(q: &QueueShell, _: &[QueueEv]) -> Result<(), String> {
    let s = &q.0;
    s.settled()?;
    s.each_sent_once()?;
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
    let user = p.source(
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
    // the pause is the user's, after the first send
    let pauser = p.source("pauser", vec![QueueEv::Pause]);
    p.before((user, 0), (pauser, 0));
    let bound = Bound {
        exhaustive_max: 40_000,
        ..Bound::default()
    };
    let r = every_order(&p, bound, || QueueShell(Shell::new()), check_queue);
    assert_eq!(r.mode, Mode::Exhaustive);
    assert_eq!(r.orders, 37_800);
}

// ---- a send during a kill is refused or kept ----

/// The user sends two prompts; the hub's delivery finds the session free and marks a peer's message `sending`, then
/// prompts it (`deliver::pass`: a refusal puts the message back); the editor delivers the queue; the agent answers
/// what it works on; the session is killed (the user's kill, or the hub's end), then its process exits.
#[derive(Clone, Debug)]
enum KillEv {
    Send(&'static str),
    Offer,
    Give,
    Deliver,
    Done,
    Kill(KillWhy),
    Exit,
}
skuld::events!(KillEv {
    Send,
    Offer,
    Give,
    Deliver,
    Done,
    Kill,
    Exit
});

struct KillShell {
    s: Shell,
    /// The peer's message is `sending`.
    offered: bool,
}

impl Core for KillShell {
    type Event = KillEv;

    fn step(&mut self, ev: KillEv) -> Vec<KillEv> {
        let s = &mut self.s;
        match ev {
            KillEv::Send(t) => s.send(t),
            KillEv::Offer => self.offered = s.core.is_free(),
            KillEv::Give => {
                if self.offered {
                    s.prompt("p1", Origin::Peer("w".into()), true);
                }
            }
            KillEv::Deliver => s.deliver(),
            KillEv::Done => s.done(),
            KillEv::Kill(why) => {
                s.kill(why);
            }
            KillEv::Exit => {
                s.close();
                s.exit();
            }
        }
        Vec::new()
    }
}

fn check_kill(k: &KillShell, _: &[KillEv]) -> Result<(), String> {
    let s = &k.s;
    s.settled()?;
    // the user's kill ends the session and the hub forgets it: what it took after the kill nothing runs
    if !s.after_kill.is_empty() {
        return Err(format!(
            "{:?} taken after the user's kill: lost",
            s.after_kill
        ));
    }
    s.each_sent_once()?;
    s.no_stall()
}

fn kill_orders(why: KillWhy) {
    let mut p = Partial::new();
    let user = p.source("user", vec![KillEv::Send("u1"), KillEv::Send("u2")]);
    p.source("delivery", vec![KillEv::Offer, KillEv::Give]);
    p.source("editor", vec![KillEv::Deliver]);
    let agent = p.source("agent", vec![KillEv::Done, KillEv::Done]);
    p.source("killer", vec![KillEv::Kill(why), KillEv::Exit]);
    p.before((user, 0), (agent, 0));
    let r = every_order(
        &p,
        Bound::default(),
        || KillShell {
            s: Shell::new(),
            offered: false,
        },
        check_kill,
    );
    assert_eq!(r.mode, Mode::Exhaustive);
    assert_eq!(r.orders, 11_340);
}

#[test]
fn every_order_a_send_after_the_users_kill_is_refused() {
    kill_orders(KillWhy::User);
}

#[test]
fn every_order_a_send_while_the_hub_ends_is_kept() {
    kill_orders(KillWhy::HubEnding);
}

// ---- the hub's end keeps a prompt that has not reached the agent ----

/// The user sends two prompts; the shell sends each turn's prompt in a step of its own (the turn's task); the agent
/// answers what it works on; the hub ends (its process group goes), then the process exits.
#[derive(Clone, Debug)]
enum SendEv {
    Send(&'static str),
    Prompt,
    Done,
    HubEnds,
    Exit,
}
skuld::events!(SendEv {
    Send,
    Prompt,
    Done,
    HubEnds,
    Exit
});

struct SendShell(Shell);

impl Core for SendShell {
    type Event = SendEv;

    fn step(&mut self, ev: SendEv) -> Vec<SendEv> {
        let s = &mut self.0;
        match ev {
            SendEv::Send(t) => s.send(t),
            SendEv::Prompt => s.send_prompt(),
            SendEv::Done => s.done(),
            SendEv::HubEnds => {
                s.kill(KillWhy::HubEnding);
            }
            SendEv::Exit => {
                s.close();
                s.exit();
            }
        }
        Vec::new()
    }
}

fn check_send(q: &SendShell, _: &[SendEv]) -> Result<(), String> {
    let s = &q.0;
    s.settled()?;
    // the next start finds every prompt that did not reach the agent in the queue on disk (`after_step` holds the
    // disk to the core's queue)
    if !s.lost.is_empty() {
        return Err(format!(
            "{:?} sent to the agent the hub's end was ending: lost",
            s.lost
        ));
    }
    if let Some((t, text)) = &s.unsent {
        return Err(format!(
            "turn {t} ({text}) never reached the agent and is not queued"
        ));
    }
    // (a prompt sent after the exit is refused: its sender keeps it)
    let mut seen = s.reached.clone();
    seen.extend(s.core.queue().texts());
    seen.extend(s.refused.iter().cloned());
    seen.sort();
    let mut sent = s.sent.clone();
    sent.sort();
    if seen != sent {
        return Err(format!(
            "sent {sent:?}; reached the agent {:?}, queued {:?}, refused {:?}",
            s.reached,
            s.core.queue().texts(),
            s.refused
        ));
    }
    Ok(())
}

#[test]
fn every_order_the_hubs_end_keeps_a_prompt_that_has_not_reached_the_agent() {
    let mut p = Partial::new();
    p.source("user", vec![SendEv::Send("u1"), SendEv::Send("u2")]);
    p.source("turn", vec![SendEv::Prompt, SendEv::Prompt]);
    p.source("agent", vec![SendEv::Done, SendEv::Done]);
    p.source("hub", vec![SendEv::HubEnds, SendEv::Exit]);
    let r = every_order(
        &p,
        Bound::default(),
        || SendShell(Shell::with_gap()),
        check_send,
    );
    assert_eq!(r.mode, Mode::Exhaustive);
    assert_eq!(r.orders, 2_520);
}

// ---- the queue on disk keeps a prompt until it reaches the agent ----

/// The user sends two prompts; the turn's task sends each turn's prompt in a step of its own; the agent answers what
/// it works on; the hub dies with no end step (a SIGKILL, a crash), and nothing of it runs after.  The next start
/// runs what the queue on disk holds.
#[derive(Clone, Debug)]
enum DieEv {
    Send(&'static str),
    Prompt,
    Done,
    Dies,
}
skuld::events!(DieEv {
    Send,
    Prompt,
    Done,
    Dies
});

struct DieShell {
    s: Shell,
    dead: bool,
}

impl Core for DieShell {
    type Event = DieEv;

    fn step(&mut self, ev: DieEv) -> Vec<DieEv> {
        if self.dead {
            return Vec::new();
        }
        let s = &mut self.s;
        match ev {
            DieEv::Send(t) => s.send(t),
            DieEv::Prompt => s.send_prompt(),
            DieEv::Done => s.done(),
            DieEv::Dies => self.dead = true,
        }
        Vec::new()
    }
}

fn check_die(d: &DieShell, _: &[DieEv]) -> Result<(), String> {
    let s = &d.s;
    s.settled()?;
    // every prompt sent reached the agent, or the next start finds it on disk
    let mut seen = s.reached.clone();
    seen.extend(s.disk.0.iter().cloned());
    seen.sort();
    let mut sent = s.sent.clone();
    sent.sort();
    if seen != sent {
        return Err(format!(
            "sent {sent:?}; reached the agent {:?}, on disk {:?}: the rest is lost",
            s.reached, s.disk.0
        ));
    }
    Ok(())
}

#[test]
fn every_order_the_queue_on_disk_keeps_a_prompt_until_it_reaches_the_agent() {
    let mut p = Partial::new();
    p.source("user", vec![DieEv::Send("u1"), DieEv::Send("u2")]);
    p.source("turn", vec![DieEv::Prompt, DieEv::Prompt]);
    p.source("agent", vec![DieEv::Done, DieEv::Done]);
    p.source("hub", vec![DieEv::Dies]);
    let r = every_order(
        &p,
        Bound::default(),
        || DieShell {
            s: Shell::with_gap(),
            dead: false,
        },
        check_die,
    );
    assert_eq!(r.mode, Mode::Exhaustive);
    assert_eq!(r.orders, 630);
}

// ---- a Stop before the send wins ----

/// The user sends two prompts, stops and delivers the held queue; the turn's task sends each turn's prompt in a step
/// of its own (a Stop may come between a turn's start and its send); the agent answers what it works on; the stop's
/// deadline fires.
#[derive(Clone, Debug)]
enum GapStopEv {
    Send(&'static str),
    Stop,
    Deliver,
    Prompt,
    Done,
    Due(usize),
}
skuld::events!(GapStopEv {
    Send,
    Stop,
    Deliver,
    Prompt,
    Done,
    Due
});

struct GapStopShell(Shell);

impl Core for GapStopShell {
    type Event = GapStopEv;

    fn step(&mut self, ev: GapStopEv) -> Vec<GapStopEv> {
        let s = &mut self.0;
        match ev {
            GapStopEv::Send(t) => s.send(t),
            GapStopEv::Stop => {
                s.feed(TurnEvent::Stop { after_tool: false });
            }
            GapStopEv::Deliver => s.deliver(),
            GapStopEv::Prompt => s.send_prompt(),
            GapStopEv::Done => s.done(),
            GapStopEv::Due(i) => s.due(i),
        }
        Vec::new()
    }
}

fn check_gap_stop(g: &GapStopShell, _: &[GapStopEv]) -> Result<(), String> {
    let s = &g.0;
    // (no prompt went after its cancel: `send_prompt` notes it)
    s.settled()?;
    if let Some((t, n)) = s.cancels.iter().find(|(_, n)| **n > 1) {
        return Err(format!("turn {t} was told to cancel {n} times"));
    }
    s.no_stall()
}

#[test]
fn every_order_a_stop_before_the_send_keeps_the_prompt_from_the_agent() {
    let mut p = Partial::new();
    let user = p.source(
        "user",
        vec![
            GapStopEv::Send("a"),
            GapStopEv::Send("b"),
            GapStopEv::Stop,
            GapStopEv::Deliver,
        ],
    );
    let turn = p.source("turn", vec![GapStopEv::Prompt, GapStopEv::Prompt]);
    let agent = p.source("agent", vec![GapStopEv::Done, GapStopEv::Done]);
    let timer = p.source("timer", vec![GapStopEv::Due(0)]);
    p.before((user, 0), (turn, 0));
    p.before((user, 0), (agent, 0));
    p.before((user, 2), (timer, 0));
    let r = every_order(
        &p,
        Bound::default(),
        || GapStopShell(Shell::with_gap()),
        check_gap_stop,
    );
    assert_eq!(r.mode, Mode::Exhaustive);
    assert!(r.orders > 100, "{} orders", r.orders);
}

// ---- a delivered peer message a user's kill discards goes back to the store's queue ----

/// The user sends a prompt; the hub's delivery (`deliver::pass`) finds the session free and marks the peer's message
/// `sending`, prompts it (a turn may have started in between: it is queued; a refusal puts it back), then marks it
/// `delivered`; the agent answers what it works on; the user kills the session, then its process exits.
#[derive(Clone, Debug)]
enum DeliverEv {
    Send(&'static str),
    Offer,
    Give,
    Mark,
    Done,
    Kill,
    Exit,
}
skuld::events!(DeliverEv {
    Send,
    Offer,
    Give,
    Mark,
    Done,
    Kill,
    Exit
});

/// The message's state in the store.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Msg {
    Queued,
    Sending,
    Delivered,
}

struct DeliverShell {
    s: Shell,
    msg: Msg,
    /// The session took the message's prompt (`prompt_keyed` answered).
    given: bool,
}

const MESSAGE_KEY: &str = "message:1";

impl Core for DeliverShell {
    type Event = DeliverEv;

    fn step(&mut self, ev: DeliverEv) -> Vec<DeliverEv> {
        match ev {
            DeliverEv::Send(t) => self.s.send(t),
            DeliverEv::Offer => {
                if self.msg == Msg::Queued && self.s.core.is_free() {
                    self.msg = Msg::Sending;
                }
            }
            DeliverEv::Give => {
                if self.msg == Msg::Sending {
                    self.given = self.s.prompt_keyed(
                        "p1",
                        Origin::Peer("w".into()),
                        true,
                        Some(MESSAGE_KEY),
                    );
                    if !self.given {
                        // `messages::unsend`
                        self.msg = Msg::Queued;
                    }
                }
            }
            // `messages::delivered`: only a message still `sending` (a kill may have put it back)
            DeliverEv::Mark => {
                if self.given && self.msg == Msg::Sending {
                    self.msg = Msg::Delivered;
                }
            }
            DeliverEv::Done => self.s.done(),
            DeliverEv::Kill => {
                // what the kill discards that the store gave the session goes back to `queued` (`deliver::put_back`)
                for e in self.s.kill(KillWhy::User) {
                    if let TurnEffect::Discard(items) = e
                        && items.iter().any(|i| i.key.as_deref() == Some(MESSAGE_KEY))
                    {
                        self.msg = Msg::Queued;
                    }
                }
            }
            DeliverEv::Exit => {
                self.s.close();
                self.s.exit();
            }
        }
        Vec::new()
    }
}

fn check_deliver(d: &DeliverShell, _: &[DeliverEv]) -> Result<(), String> {
    let s = &d.s;
    s.settled()?;
    let ran = s.started.iter().any(|(_, t)| t == "p1");
    // delivered: its prompt ran; else the store still has it queued for the next pass (the user's kill discards the
    // session's own queue)
    match d.msg {
        Msg::Delivered if !ran => Err(format!(
            "the message is delivered, but its prompt never ran (queued {:?} when the user killed the session)",
            s.core.queue().texts()
        )),
        Msg::Queued if ran => Err("the message ran and is queued again".into()),
        Msg::Sending => Err("the message is left sending".into()),
        _ => Ok(()),
    }
}

#[test]
fn every_order_a_delivered_message_a_kill_discards_is_queued_again() {
    let mut p = Partial::new();
    let user = p.source("user", vec![DeliverEv::Send("u1")]);
    p.source(
        "delivery",
        vec![DeliverEv::Offer, DeliverEv::Give, DeliverEv::Mark],
    );
    let agent = p.source("agent", vec![DeliverEv::Done, DeliverEv::Done]);
    p.source("killer", vec![DeliverEv::Kill, DeliverEv::Exit]);
    p.before((user, 0), (agent, 0));
    let r = every_order(
        &p,
        Bound::default(),
        || DeliverShell {
            s: Shell::new(),
            msg: Msg::Queued,
            given: false,
        },
        check_deliver,
    );
    assert_eq!(r.mode, Mode::Exhaustive);
    assert_eq!(r.orders, 560);
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
                s.turn_of.insert(request, 1);
                s.feed(TurnEvent::PermissionAsked { request, turn: 1 });
            }
            PermEv::Answer(request) => {
                s.feed(TurnEvent::PermissionAnswered { request });
            }
            PermEv::Stop => {
                s.feed(TurnEvent::Stop { after_tool: false });
            }
            PermEv::Pause => s.pause(),
            PermEv::ToolCompleted => {
                s.feed(TurnEvent::ToolCompleted);
            }
            PermEv::Done => s.done(),
        }
        Vec::new()
    }
}

/// Once turn 1 is over or cancelled, every request asked has its one reply; while it runs, the rest wait.
fn replied_once_over(s: &Shell) -> Result<(), String> {
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

fn check_perm(p: &PermShell, _: &[PermEv]) -> Result<(), String> {
    p.0.settled()?;
    replied_once_over(&p.0)
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

// ---- a kill or an exit cancels what is held ----

/// How the session's process ends.
#[derive(Clone, Copy, Debug)]
enum Ending {
    /// A kill (the user's, or the hub's end), then the exit.
    Kill(KillWhy),
    /// The process exits on its own, before its turn's prompt fails.
    Crash,
}

/// The user sends two prompts and answers the first request; the agent sends a request in the turn it works on,
/// answers it and sends another in the next; the matrix asks the user about each (in a task of its own, so possibly
/// after its turn is over); the process ends.
#[derive(Clone, Debug)]
enum EndEv {
    Send(&'static str),
    Answer(u64),
    Request(u64),
    Done,
    Decide(u64),
    /// The kill (0) or the exit (1).
    End(Ending, u8),
}
skuld::events!(EndEv {
    Send,
    Answer,
    Request,
    Done,
    Decide,
    End
});

struct EndShell(Shell);

impl Core for EndShell {
    type Event = EndEv;

    fn step(&mut self, ev: EndEv) -> Vec<EndEv> {
        let s = &mut self.0;
        match ev {
            EndEv::Send(t) => s.send(t),
            EndEv::Answer(request) => {
                s.feed(TurnEvent::PermissionAnswered { request });
            }
            // the agent asks only while it works on a turn; the reader stamps that turn
            EndEv::Request(request) => {
                if let Some(t) = s.running {
                    s.turn_of.insert(request, t);
                }
            }
            EndEv::Done => s.done(),
            EndEv::Decide(request) => {
                if let Some(&turn) = s.turn_of.get(&request) {
                    s.asked.push(request);
                    s.feed(TurnEvent::PermissionAsked { request, turn });
                }
            }
            EndEv::End(Ending::Kill(why), 0) => {
                s.kill(why);
            }
            EndEv::End(Ending::Kill(_), _) => {
                s.close();
                s.exit();
            }
            EndEv::End(Ending::Crash, _) => {
                s.exit();
                s.close();
            }
        }
        Vec::new()
    }
}

fn check_end(e: &EndShell, _: &[EndEv]) -> Result<(), String> {
    let s = &e.0;
    s.settled()?;
    // the process is gone: every request asked has its one reply
    if let Some(r) = s.asked.iter().find(|r| !s.replies.contains_key(*r)) {
        return Err(format!("r{r} waits after the exit"));
    }
    Ok(())
}

fn end_orders(how: Ending) -> u64 {
    let mut p = Partial::new();
    let user = p.source(
        "user",
        vec![EndEv::Send("u1"), EndEv::Send("u2"), EndEv::Answer(1)],
    );
    let agent = p.source(
        "agent",
        vec![EndEv::Request(1), EndEv::Done, EndEv::Request(2)],
    );
    let matrix = p.source("matrix", vec![EndEv::Decide(1), EndEv::Decide(2)]);
    let end = match how {
        Ending::Kill(_) => vec![EndEv::End(how, 0), EndEv::End(how, 1)],
        Ending::Crash => vec![EndEv::End(how, 1)],
    };
    p.source("end", end);
    // the agent works only once something was sent; the second request is for the second prompt's turn; the matrix
    // decides on what the reader received
    p.before((user, 0), (agent, 0));
    p.before((user, 1), (agent, 2));
    p.before((agent, 0), (matrix, 0));
    p.before((agent, 2), (matrix, 1));
    let r = every_order(&p, Bound::default(), || EndShell(Shell::new()), check_end);
    assert_eq!(r.mode, Mode::Exhaustive);
    r.orders
}

#[test]
fn every_order_the_users_kill_cancels_what_is_held() {
    assert_eq!(end_orders(Ending::Kill(KillWhy::User)), 2_295);
}

#[test]
fn every_order_the_hubs_end_cancels_what_is_held() {
    assert_eq!(end_orders(Ending::Kill(KillWhy::HubEnding)), 2_295);
}

#[test]
fn every_order_an_exit_cancels_what_is_held() {
    assert_eq!(end_orders(Ending::Crash), 459);
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
fn a_send_during_the_users_kill_is_refused_and_the_session_is_not_free() {
    let mut c = TurnCore::new();
    c.ready(false);
    c.step(TurnEvent::Kill { why: KillWhy::User });
    assert!(!c.is_free());
    assert_eq!(c.step(send("a")), [TurnEffect::Exited]);
    assert!(c.queue().is_empty());
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

/// Pure (D): a session started afresh after a restart (or a manager's rotation) keeps the prompts its queue on disk
/// holds and is told first what happened, in a turn of its own.
#[test]
fn a_fresh_start_is_told_first_and_keeps_its_queue() {
    let mut disk = crate::agents::queue::Queue::default();
    disk.push("u1".into(), Origin::User, false);
    disk.push("p1".into(), Origin::Peer("w".into()), false);
    let mut c = TurnCore::new();
    c.resume(disk.clone(), false, Some("told".into()));
    c.ready(false);
    assert_eq!(c.queue().texts(), ["told", "u1", "p1"]);
    let fx = c.next();
    assert!(
        matches!(&fx[..], [TurnEffect::StartTurn { item, .. }] if item.text == "told" && item.origin == Origin::Hub),
        "{fx:?}"
    );
    // a session that resumed its conversation is told nothing, and a held queue stays held
    let mut c = TurnCore::new();
    c.resume(disk, true, None);
    c.ready(false);
    assert_eq!(c.queue().texts(), ["u1", "p1"]);
    assert!(c.next().is_empty() && c.paused());
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
