//! Take the wheel (docs/develop/coordination.md, "Take the wheel"): the user stops an agent after its step, works in
//! its place, and gives the wheel back with what they changed.
//!
//! - **Take** (`agents/wheel/take`, the user's only): the turn running is paused after its tool call (part 1's
//!   pause), no turn starts while the wheel is held (sent and delivered prompts wait in the queue), and the
//!   snapshot says `paused` and `held_by: "user"` at once.  When that turn has ended (the tool call in flight
//!   completed, the cancel answered) the wheel is **held**: a step snapshot of the worktree is taken, then
//!   `agent-wheel {id, state: held}` goes out.  From then the session's fence refuses every write
//!   ([`super::session::Fence::held`]).
//! - **Give** (`agents/wheel/give`): refused until held.  A session in a worktree of its own (a worker, a manager)
//!   first asks the editor to save its buffers there (`wheel-save`, answered `agents/wheel/saved`); a buffer left
//!   unsaved refuses the give with its file.  A chat saves nothing (its worktree is the user's checkout).  Then the
//!   user's changes since the hold go to the agent as the first prompt ([`give_text`]), the queued ones after it, and
//!   the hold lifts.  Where they are read from is the boundary kept at held ([`HeldAt`]): the edit history's, for
//!   the files the editor tracks (its documents hold the user's unsaved typing), and the step snapshot's for the rest.
//! - The hold survives an editor's disconnect and a hub restart (kept beside the queue on disk).
//!
//! The order logic is here, without I/O: [`take`], [`turn_ended`] and [`give`] step the wheel and the session's turn
//! core together, under the session's lock.

use super::queue::{Origin, Queued};
use super::session::turn_core::{QueueEdit, TurnCore, TurnEffect, TurnEvent};
use runstav::methods::agents::SessionStatus;
use runstav::methods::matrix::Role;

/// Where a session's wheel is.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum Wheel {
    /// The agent drives.
    #[default]
    Free,
    /// The user took it while a turn ran: the turn ends after its tool call.
    Taking,
    /// The turn has ended: nothing of the agent's is written until the give.
    Held,
}

/// What a take did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Taken {
    /// Taken already: nothing changed.
    Already,
    /// A turn runs: held when it ends.
    Taking,
    /// No turn ran: held now.
    Held,
}

/// A give before the turn the take stopped has ended.
pub(crate) const NOT_YET: &str = "the agent has not stopped yet: it stops after its current step";

/// A give of a wheel nobody took.
pub(crate) const NOT_HELD: &str = "you do not hold this agent's wheel";

/// What a write of a held session is refused with.
pub(crate) const HELD: &str = "the user holds the wheel";

/// The label of the give's prompt when the user changed something.
pub(crate) const EDITS_LABEL: &str = "Edits by you while you held the wheel";

/// The give's prompt when the user changed nothing ("resumed by you": its entry's key is `wheel:resumed`).
pub(crate) const CONTINUE: &str = "Continue.";

/// The most lines of the user's diff the give's prompt carries; above it, the files and hunk headers only.
pub(crate) const MAX_DIFF_LINES: usize = 200;

/// Where the give measures the user's changes from, kept when the wheel became held (never at the take: the tool call
/// in flight may still write): the edit history's newest record after the waiting typing was settled (OP), and the
/// step snapshot of the worktree (TREE), for the files the history does not track.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct HeldAt {
    pub tree: Option<String>,
    pub op: Option<i64>,
}

/// How [`HeldAt`] is kept beside the hold: the snapshot's tree, then `\top:N` when there is a record.
const OP_MARK: &str = "\top:";

impl HeldAt {
    /// As kept on disk (none: nothing to keep).
    pub(crate) fn to_store(&self) -> Option<String> {
        match (&self.tree, self.op) {
            (None, None) => None,
            (t, None) => t.clone(),
            (t, Some(op)) => Some(format!("{}{OP_MARK}{op}", t.as_deref().unwrap_or(""))),
        }
    }

    /// As read back; a hold kept before the history's boundary has the tree only.
    pub(crate) fn from_store(s: Option<&str>) -> HeldAt {
        let Some(s) = s else {
            return HeldAt::default();
        };
        let (tree, op) = match s.split_once(OP_MARK) {
            Some((t, n)) => (t, n.parse().ok()),
            None => (s, None),
        };
        HeldAt {
            tree: (!tree.is_empty()).then(|| tree.to_owned()),
            op,
        }
    }
}

/// The parts of DIFF (a unified diff, `diff --git a/P b/P` per file) about files not in TRACKED: the step snapshot's
/// share of the give, where the edit history's diff covers TRACKED.
pub(crate) fn untracked_only(diff: &str, tracked: &[String]) -> String {
    let mut out = String::new();
    let mut keep = true;
    for line in diff.split_inclusive('\n') {
        if let Some(rest) = line.strip_prefix("diff --git a/") {
            let path = rest.split(" b/").next().unwrap_or("");
            keep = !tracked.iter().any(|t| t == path);
        }
        if keep {
            out.push_str(line);
        }
    }
    out
}

/// The user takes the wheel: the turn running is paused after its tool call (`Stop` with `after_tool`) and no turn
/// starts until the give.  Refused when the session has exited.
pub(crate) fn take(
    w: &mut Wheel,
    core: &mut TurnCore,
) -> Result<(Taken, Vec<TurnEffect>), &'static str> {
    if *w != Wheel::Free {
        return Ok((Taken::Already, Vec::new()));
    }
    let fx = core.step(TurnEvent::Stop { after_tool: true });
    if fx.contains(&TurnEffect::Exited) {
        return Err("the session has exited");
    }
    core.set_wheel(true);
    if core.status() == SessionStatus::Busy {
        *w = Wheel::Taking;
        Ok((Taken::Taking, fx))
    } else {
        *w = Wheel::Held;
        Ok((Taken::Held, fx))
    }
}

/// A turn core step's effects FX: a turn's end while the wheel is being taken makes it held (true, once).
pub(crate) fn turn_ended(w: &mut Wheel, fx: &[TurnEffect]) -> bool {
    if *w == Wheel::Taking && fx.iter().any(|e| matches!(e, TurnEffect::EndTurn { .. })) {
        *w = Wheel::Held;
        true
    } else {
        false
    }
}

/// Whether a give may start now: only once held.
pub(crate) fn can_give(w: Wheel) -> Result<(), &'static str> {
    match w {
        Wheel::Held => Ok(()),
        Wheel::Taking => Err(NOT_YET),
        Wheel::Free => Err(NOT_HELD),
    }
}

/// The user gives the wheel back: ITEM (the give's prompt) goes first, the hold lifts and the next turn starts.
/// Refused until held.
pub(crate) fn give(
    w: &mut Wheel,
    core: &mut TurnCore,
    item: Queued,
) -> Result<Vec<TurnEffect>, &'static str> {
    can_give(*w)?;
    *w = Wheel::Free;
    Ok(core.step(TurnEvent::QueueEdited(QueueEdit::Resume(item))))
}

/// Whether a give asks the editor to save first: a session in a worktree of its own does; a chat works in the user's
/// checkout, where give saves nothing.
pub(crate) fn saves_on_give(role: Role) -> bool {
    role != Role::Chat
}

/// The give's prompt for DIFF, the user's changes since the hold (a unified diff; empty: none), with the key its
/// transcript entry carries as its label (`wheel:edits`, `wheel:resumed`).  Up to [`MAX_DIFF_LINES`] the diff goes
/// whole; above, its files and hunk headers, and the agent is told to read those files again.
pub(crate) fn give_text(diff: &str) -> Queued {
    let (text, key) = if diff.trim().is_empty() {
        (CONTINUE.to_string(), "wheel:resumed")
    } else {
        let n = diff.lines().count();
        let text = if n <= MAX_DIFF_LINES {
            format!("{EDITS_LABEL}:\n\n{diff}")
        } else {
            let heads: Vec<&str> = diff
                .lines()
                .filter(|l| l.starts_with("diff --git ") || l.starts_with("@@"))
                .collect();
            format!(
                "{EDITS_LABEL} ({n} lines of diff, too long to show: its files and hunks below). Read these files \
                 again before you change them.\n\n{}\n",
                heads.join("\n")
            )
        };
        (text, "wheel:edits")
    };
    Queued {
        text,
        origin: Origin::User,
        steer: false,
        key: Some(key.to_string()),
    }
}

#[cfg(test)]
mod tests {
    //! The wheel in every order of the user's take and give, the agent's tool call and answer, and a delivery
    //! (skuld), within the declared events; and its pure parts.
    use super::*;
    use skuld::{Bound, Core, Mode, Partial, every_order};

    #[derive(Clone, Debug)]
    enum Ev {
        /// The user sends a prompt.
        Send(&'static str),
        /// The user takes the wheel.
        Take,
        /// The user gives it back.
        Give,
        /// The tool call running in the turn completes (it wrote what it wrote).
        ToolDone,
        /// The agent answers the turn's prompt (cancelled when it was told to cancel).
        Answer,
        /// The editor delivers the held queue.
        Deliver,
    }
    skuld::events!(Ev {
        Send,
        Take,
        Give,
        ToolDone,
        Answer,
        Deliver
    });

    /// The wheel and the turn core under test, and what the shell and the agent saw.
    #[derive(Default)]
    struct Shell {
        core: TurnCore,
        wheel: Wheel,
        /// The agent works on a turn (its prompt unanswered), and was told to cancel it.
        running: bool,
        cancel_sent: bool,
        /// The tool call of the turn running has completed.
        tool_done: bool,
        /// The turns started, by their prompt's text.
        started: Vec<String>,
        /// `agent-wheel held` sent.
        held_sent: u32,
        /// Turns started while the user held (or was taking) the wheel.
        started_while_held: Vec<String>,
        /// The take came and the give answered (refused: its reason).
        took: bool,
        give: Option<Result<(), &'static str>>,
        /// The wheel as it was when the give was asked, and the turns started by then.
        wheel_at_give: Option<Wheel>,
        started_at_give: usize,
        /// A cancel sent before the tool call completed.
        early_cancel: bool,
        /// The wheel became held while the agent still worked on a turn.
        held_while_running: bool,
    }

    impl Shell {
        fn new() -> Shell {
            let mut s = Shell::default();
            s.core.ready(false);
            s
        }

        /// The wheel became held now: announced.
        fn held(&mut self) {
            self.held_sent += 1;
            self.held_while_running |= self.running;
        }

        /// What the shell does with the core's effects, as `Session::perform` does.
        fn perform(&mut self, fx: Vec<TurnEffect>) {
            if turn_ended(&mut self.wheel, &fx) {
                self.held();
            }
            for e in fx {
                match e {
                    TurnEffect::StartTurn { item, .. } => {
                        if self.wheel != Wheel::Free {
                            self.started_while_held.push(item.text.clone());
                        }
                        self.started.push(item.text);
                        // the shell's `Sending` step: the prompt reaches the agent
                        let turn = self.core.turn();
                        let more = self.core.step(TurnEvent::Sending { turn });
                        self.perform(more);
                        self.running = true;
                        self.cancel_sent = false;
                        self.tool_done = false;
                    }
                    TurnEffect::CancelTurn => {
                        if !self.tool_done {
                            self.early_cancel = true;
                        }
                        self.cancel_sent = true;
                    }
                    _ => {}
                }
            }
        }

        fn feed(&mut self, ev: TurnEvent) {
            let fx = self.core.step(ev);
            self.perform(fx);
        }
    }

    impl Core for Shell {
        type Event = Ev;

        fn step(&mut self, ev: Ev) -> Vec<Ev> {
            match ev {
                Ev::Send(t) => self.feed(TurnEvent::Send {
                    item: Queued {
                        text: t.into(),
                        origin: Origin::User,
                        steer: false,
                        key: None,
                    },
                    steer_mode: false,
                    if_free: false,
                }),
                Ev::Take => {
                    self.took = true;
                    let (taken, fx) = take(&mut self.wheel, &mut self.core).unwrap();
                    if taken == Taken::Held {
                        self.held();
                    }
                    self.perform(fx);
                }
                Ev::Give => {
                    self.wheel_at_give = Some(self.wheel);
                    self.started_at_give = self.started.len();
                    match give(&mut self.wheel, &mut self.core, give_text("")) {
                        Ok(fx) => {
                            self.give = Some(Ok(()));
                            self.perform(fx);
                        }
                        Err(m) => self.give = Some(Err(m)),
                    }
                }
                Ev::ToolDone => {
                    if self.running && !self.tool_done {
                        self.tool_done = true;
                        self.feed(TurnEvent::ToolCompleted);
                    }
                }
                Ev::Answer => {
                    if self.running {
                        self.running = false;
                        let cancelled = self.cancel_sent;
                        // one turn runs at a time: the answer is the current turn's
                        let turn = self.core.turn();
                        self.feed(TurnEvent::PromptDone {
                            turn,
                            cancelled,
                            jobs: false,
                        });
                    }
                }
                Ev::Deliver => self.feed(TurnEvent::QueueEdited(QueueEdit::Deliver)),
            }
            Vec::new()
        }
    }

    /// What holds after every step of either order test.
    fn settled(s: &Shell) -> Result<(), String> {
        if s.held_sent > 1 {
            return Err(format!("held announced {} times", s.held_sent));
        }
        if s.early_cancel {
            return Err("the turn was cancelled before its tool call completed".into());
        }
        // held only once the turn the take stopped has ended: no turn runs then
        if s.held_while_running {
            return Err("held while a turn runs".into());
        }
        if !s.started_while_held.is_empty() && s.give != Some(Ok(())) {
            return Err(format!(
                "turns started while the wheel was held: {:?}",
                s.started_while_held
            ));
        }
        Ok(())
    }

    fn check_take(s: &Shell, _: &[Ev]) -> Result<(), String> {
        settled(s)?;
        // the give comes after the agent's answer: the wheel is held by then, and no turn started after the first
        if !s.took || s.wheel_at_give != Some(Wheel::Held) || s.give != Some(Ok(())) {
            return Err(format!(
                "the wheel was {:?} at the give ({:?})",
                s.wheel_at_give, s.give
            ));
        }
        if s.started_at_give > 1 {
            return Err(format!("a turn started after the take: {:?}", s.started));
        }
        Ok(())
    }

    /// [A] The user takes the wheel while the turn's tool call runs, before it, or after the turn's end, with a
    /// prompt sent and the queue delivered around it: the turn is cancelled only once its tool call completed, the
    /// wheel is held once that turn has ended (announced once), and no turn starts while it is held; a give once
    /// the agent has answered finds it held.
    #[test]
    fn every_order_take_during_a_tool_call_holds_after_it() {
        let mut p = Partial::new();
        let user = p.source(
            "user",
            vec![Ev::Send("a"), Ev::Take, Ev::Send("b"), Ev::Give],
        );
        let agent = p.source("agent", vec![Ev::ToolDone, Ev::Answer]);
        let editor = p.source("editor", vec![Ev::Deliver]);
        // the agent works on the first prompt's turn; the give comes last
        p.before((user, 0), (agent, 0));
        p.before((agent, 1), (user, 3));
        p.before((editor, 0), (user, 3));
        let r = every_order(&p, Bound::default(), Shell::new, check_take);
        assert_eq!(r.mode, Mode::Exhaustive);
        assert!(r.orders > 20, "{} orders", r.orders);
    }

    fn check_give(s: &Shell, _: &[Ev]) -> Result<(), String> {
        settled(s)?;
        match (s.wheel_at_give, s.give) {
            (Some(Wheel::Held), Some(Ok(()))) => {
                // the give's prompt is the first turn after it, ahead of the queued prompt
                let after: Vec<&str> = s.started.iter().skip(1).map(String::as_str).collect();
                if after.first() != Some(&CONTINUE) {
                    return Err(format!("the turns after the give: {after:?}"));
                }
            }
            (Some(Wheel::Taking), Some(Err(NOT_YET))) | (None, None) => {}
            (w, g) => return Err(format!("a give at {w:?} answered {g:?}")),
        }
        if s.give == Some(Err(NOT_YET)) && !s.running && s.wheel != Wheel::Held {
            return Err(format!("refused give left the wheel {:?}", s.wheel));
        }
        Ok(())
    }

    /// [A] The user gives the wheel back in every order against the turn the take stopped: a give before that turn
    /// has ended is refused ("not stopped yet") and the wheel is still held when it ends; a give once held starts
    /// the give's prompt first, then the queued one.
    #[test]
    fn every_order_give_before_held_is_refused() {
        let mut p = Partial::new();
        let user = p.source(
            "user",
            vec![Ev::Send("a"), Ev::Take, Ev::Send("b"), Ev::Give],
        );
        let agent = p.source("agent", vec![Ev::ToolDone, Ev::Answer]);
        // a delivery of the held queue anywhere: it starts nothing while held
        let _editor = p.source("editor", vec![Ev::Deliver]);
        p.before((user, 0), (agent, 0));
        // the take comes while the turn runs: before the agent answers
        p.before((user, 1), (agent, 1));
        let r = every_order(&p, Bound::default(), Shell::new, check_give);
        assert_eq!(r.mode, Mode::Exhaustive);
        assert!(r.orders > 5, "{} orders", r.orders);
    }

    /// [D] Up to 200 lines the give's prompt carries the user's diff whole; above, only its files and hunk headers,
    /// and the agent is told to read those files again.  No change at all is "Continue.", labelled "resumed by you".
    #[test]
    fn give_diff_over_200_lines_sends_headers() {
        let small =
            "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n";
        let q = give_text(small);
        assert!(q.text.starts_with(EDITS_LABEL), "{}", q.text);
        assert!(q.text.contains("+new"), "{}", q.text);
        assert_eq!(q.key.as_deref(), Some("wheel:edits"));
        assert_eq!(q.origin, Origin::User);
        let mut big = String::from(
            "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1,0 +1,250 @@\n",
        );
        for i in 0..250 {
            big.push_str(&format!("+line {i}\n"));
        }
        big.push_str("diff --git a/c.txt b/c.txt\n--- a/c.txt\n+++ b/c.txt\n@@ -3 +3 @@\n-x\n+y\n");
        let q = give_text(&big);
        assert!(
            q.text
                .contains("Read these files again before you change them"),
            "{}",
            q.text
        );
        assert!(
            q.text.contains("diff --git a/b.txt b/b.txt")
                && q.text.contains("diff --git a/c.txt b/c.txt")
        );
        assert!(q.text.contains("@@ -1,0 +1,250 @@") && q.text.contains("@@ -3 +3 @@"));
        assert!(!q.text.contains("+line 7"), "the body went too: {}", q.text);
        assert!(q.text.lines().count() < 20, "{}", q.text);
        let q = give_text("");
        assert_eq!(
            (q.text.as_str(), q.key.as_deref()),
            (CONTINUE, Some("wheel:resumed"))
        );
    }

    /// [D] A held session is no stale agent: the supervisor's rules (silence included) and the plan run's `stale`
    /// rule pass it by, however long it has been quiet and however many writes it had held.
    #[test]
    fn held_is_exempt_from_stale() {
        use crate::runner::clash::{DiffIndex, Rule as ClashRule, RunSession, RunState, scan};
        use crate::supervisor::{Facts, Obs, Thresholds, judge};
        let o = Obs {
            sid: "s1".into(),
            task: Some("t1".into()),
            role: Role::Worker,
            cwd: std::path::PathBuf::from("/w"),
            status: SessionStatus::Busy,
            last_update: 0.0,
            busy_elsewhere: false,
            max_repeat: 99,
            tokens: 0,
            refusals: 0,
            context: Some(0.99),
            jobs: Vec::new(),
            held: true,
        };
        let t = Thresholds::default();
        assert!(judge(&o, &Facts::default(), &t, 1.0e9).is_empty());
        // the same session not held is silent and repeating
        let free = Obs { held: false, ..o };
        assert!(!judge(&free, &Facts::default(), &t, 1.0e9).is_empty());
        let mut r = RunState {
            status: "running".into(),
            ..Default::default()
        };
        r.sessions = vec![RunSession {
            id: "s1".into(),
            task: Some("t1".into()),
            exited: false,
            held: 5,
            held_by_user: true,
        }];
        assert!(
            scan(&r, &[], &DiffIndex::new())
                .iter()
                .all(|c| c.rule != ClashRule::Stale)
        );
        r.sessions[0].held_by_user = false;
        assert!(
            scan(&r, &[], &DiffIndex::new())
                .iter()
                .any(|c| c.rule == ClashRule::Stale)
        );
    }

    /// [D] A chat's give asks the editor to save nothing: its worktree is the user's checkout.  A worker's and a
    /// manager's, in worktrees of their own, do.
    #[test]
    fn give_on_a_chat_sends_no_wheel_save() {
        assert!(!saves_on_give(Role::Chat));
        assert!(saves_on_give(Role::Worker));
        assert!(saves_on_give(Role::Manager));
    }

    /// The boundary test's events: the wheel's own, and the user's edit while held.
    #[derive(Clone, Debug)]
    enum Bv {
        Send(&'static str),
        Take,
        UserEdit,
        Give,
        ToolDone,
        Answer,
    }
    skuld::events!(Bv {
        Send,
        Take,
        UserEdit,
        Give,
        ToolDone,
        Answer
    });

    /// The wheel's shell with an edit history: each write is a record by its author, and the boundary is the
    /// history's length when the shell hears the wheel is held (where `Session::wheel_held` records it).
    struct Hist {
        s: Shell,
        records: Vec<&'static str>,
        boundary: Option<usize>,
        /// What the give sent: the records after the boundary.
        given: Option<Vec<&'static str>>,
    }

    impl Core for Hist {
        type Event = Bv;

        fn step(&mut self, ev: Bv) -> Vec<Bv> {
            let held_before = self.s.held_sent;
            let ev = match ev {
                Bv::Send(t) => Ev::Send(t),
                Bv::Take => Ev::Take,
                Bv::UserEdit => {
                    self.records.push("user");
                    return Vec::new();
                }
                Bv::Give => {
                    if self.s.wheel == Wheel::Held
                        && let Some(b) = self.boundary
                    {
                        self.given = Some(self.records[b..].to_vec());
                    }
                    Ev::Give
                }
                Bv::ToolDone => {
                    // the tool call in flight writes before it completes
                    if self.s.running && !self.s.tool_done {
                        self.records.push("agent");
                    }
                    Ev::ToolDone
                }
                Bv::Answer => Ev::Answer,
            };
            self.s.step(ev);
            if self.s.held_sent > held_before {
                self.boundary = Some(self.records.len());
            }
            Vec::new()
        }
    }

    /// [A] The user takes the wheel while the agent's tool call runs, before it writes or after; then edits and gives
    /// it back. The boundary is recorded when the wheel is held, not when the take is asked: the give sends exactly
    /// the user's edit, never the write of the tool call that was in flight at the take.
    #[test]
    fn every_order_boundary_is_recorded_when_held_not_when_asked() {
        let mut p = Partial::new();
        let user = p.source(
            "user",
            vec![Bv::Send("a"), Bv::Take, Bv::UserEdit, Bv::Give],
        );
        let agent = p.source("agent", vec![Bv::ToolDone, Bv::Answer]);
        // the turn runs before the take may come; the user edits once the agent has stopped (held)
        p.before((user, 0), (agent, 0));
        p.before((agent, 1), (user, 2));
        let r = every_order(
            &p,
            Bound::default(),
            || Hist {
                s: Shell::new(),
                records: Vec::new(),
                boundary: None,
                given: None,
            },
            |h, _| {
                settled(&h.s)?;
                if h.given.as_deref() != Some(&["user"][..]) {
                    return Err(format!(
                        "the give sent {:?} (records {:?}, boundary {:?})",
                        h.given, h.records, h.boundary
                    ));
                }
                Ok(())
            },
        );
        assert_eq!(r.mode, Mode::Exhaustive);
        assert!(r.orders > 2, "{} orders", r.orders);
    }

    /// [D] The boundary as kept beside the hold, and read back (a hold kept before it: the tree only); the snapshot's
    /// share of a give leaves out the files the history's diff covers.
    #[test]
    fn held_at_is_kept_and_the_snapshot_keeps_untracked_files() {
        for h in [
            HeldAt::default(),
            HeldAt {
                tree: Some("abc".into()),
                op: None,
            },
            HeldAt {
                tree: Some("abc".into()),
                op: Some(42),
            },
            HeldAt {
                tree: None,
                op: Some(7),
            },
        ] {
            assert_eq!(HeldAt::from_store(h.to_store().as_deref()), h);
        }
        assert_eq!(
            HeldAt::from_store(Some("abc")),
            HeldAt {
                tree: Some("abc".into()),
                op: None
            }
        );
        let diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-one\n+two\n\
                    diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-x\n+y\n";
        let kept = untracked_only(diff, &["a.txt".to_string()]);
        assert!(kept.starts_with("diff --git a/b.txt b/b.txt\n"), "{kept}");
        assert!(!kept.contains("a.txt"), "{kept}");
    }
}
