//! The follow feed (docs/develop/hub.md, "The follow feed"): a follow window in the editor shows where one agent is.
//! Keyed by (connection, view), like the Work map; `agent-follow` goes to that connection only.
//!
//! The rules, without I/O, in [`Core`]:
//! - **at most one move per 200 ms** ([`MOVE_EVERY_MS`]): a move inside the window's time is held and the latest one
//!   goes when it ends;
//! - **a read of another file switches only after a 500 ms dwell** ([`DWELL_MS`]): the agent must stay in that file
//!   that long (a move to a third file starts the dwell again; a move back cancels it);
//! - **a search or glob never switches files:** its query (the step's title) goes in the line, the window stays;
//! - **an edit, a write or a pending edit switches at once** (the throttle still holds);
//! - **`changed`** when a completed edit of the shown file changed it on disk: the window refreshes it.
//!
//! The line is the agent's own words, never generated: the `in_progress` plan entry when the agent sends plans, else
//! the tool call's title; `why_source` names which.  [`Follows`] is the shell: the hub's clock, one-shot timers for
//! the deadlines the core asks for, and the events.

use runstav::methods::editor::{AgentFollow, FollowMode, WhySource};
use serde_json::{Map, Value};
use std::collections::{BTreeSet, HashMap};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

/// The least time between two moves sent to one view.
pub const MOVE_EVERY_MS: u64 = 200;

/// How long the agent stays in another file it reads before the window switches to it.
pub const DWELL_MS: u64 = 500;

/// One move of a session: where its latest tool call is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Move {
    pub session: String,
    /// The file (absolute); none for a search with no file of its own.
    pub file: Option<String>,
    /// The session's folder.
    pub worktree: String,
    pub line: Option<u32>,
    pub col: Option<u32>,
    pub mode: FollowMode,
    pub step_title: Option<String>,
    pub plan_entry: Option<String>,
    /// A completed edit: the file changed on disk.
    pub wrote: bool,
}

/// A view: connection and the editor's view id.
pub type ViewKey = (u64, String);

/// What the core is told; NOW is the hub's clock in ms.
#[derive(Clone, Debug)]
pub enum Ev {
    Follow {
        key: ViewKey,
        session: String,
        now: u64,
    },
    Unfollow {
        key: ViewKey,
    },
    Moved {
        m: Move,
        now: u64,
    },
    /// A deadline the core asked for came.
    Tick {
        now: u64,
    },
    /// The connection is gone: its views go.
    Gone {
        conn: u64,
    },
}

/// What the shell does.
#[derive(Clone, Debug, PartialEq)]
pub enum Fx {
    /// `agent-follow` DATA to connection CONN.
    Send { conn: u64, data: AgentFollow },
    /// A [`Ev::Tick`] at AT (ms).
    Arm { at: u64 },
}

#[derive(Debug)]
struct View {
    session: String,
    /// The move last sent, and when.
    shown: Option<Move>,
    sent_at: Option<u64>,
    /// The latest move not sent yet (the throttle holds it).
    due: Option<Move>,
    /// A completed edit changed the shown file since the last send.
    changed: bool,
    /// The read of another file the window may switch to, and since when the agent is in that file.
    dwell: Option<(Move, u64)>,
    /// The deadlines asked for and not come yet (one timer each).
    armed: BTreeSet<u64>,
}

/// The follow feed's rules (see the module).
#[derive(Debug, Default)]
pub struct Core {
    views: HashMap<ViewKey, View>,
    /// Each session's latest move: a view that starts following gets it at once.
    last: HashMap<String, Move>,
}

/// The wire form of M for VIEW.
fn data(view: &str, m: &Move, changed: bool) -> AgentFollow {
    AgentFollow {
        view: view.to_string(),
        session: m.session.clone(),
        file: m.file.clone(),
        worktree: m.worktree.clone(),
        line: m.line,
        col: m.col,
        mode: m.mode,
        step_title: m.step_title.clone(),
        plan_entry: m.plan_entry.clone(),
        why_source: if m.plan_entry.is_some() {
            WhySource::PlanEntry
        } else {
            WhySource::StepTitle
        },
        changed: changed.then_some(true),
    }
}

/// The move a tool call makes: ENTRY is its transcript entry (the updates merged), in WORKTREE; PLAN_ENTRY the plan's
/// `in_progress` entry.  Its first location is the place, its kind the mode; a failed call, a command or a fetch makes
/// none.
pub fn of_tool(
    session: &str,
    worktree: &Path,
    entry: &Map<String, Value>,
    plan_entry: Option<&str>,
) -> Option<Move> {
    let s = |k: &str| entry.get(k).and_then(Value::as_str);
    let status = s("status");
    if status == Some("failed") {
        return None;
    }
    let done = status == Some("completed");
    let raw = |k: &str| entry.get("rawInput").and_then(|r| r.get(k)).is_some();
    let whole = raw("content") && !raw("old_string");
    let mode = match s("kind")? {
        "read" => FollowMode::Read,
        "search" => FollowMode::Listed,
        "edit" | "delete" | "move" if !done => FollowMode::Pending,
        "edit" | "delete" | "move" if whole => FollowMode::Write,
        "edit" | "delete" | "move" => FollowMode::Edit,
        _ => return None,
    };
    let loc = entry
        .get("locations")
        .and_then(Value::as_array)
        .and_then(|a| a.first());
    let file = loc
        .and_then(|l| l.get("path"))
        .and_then(Value::as_str)
        .filter(|p| !p.is_empty())
        .map(|p| worktree.join(p).to_string_lossy().into_owned());
    let line = loc
        .and_then(|l| l.get("line"))
        .and_then(Value::as_u64)
        .and_then(|n| u32::try_from(n).ok());
    Some(Move {
        session: session.to_string(),
        file,
        worktree: worktree.to_string_lossy().into_owned(),
        line,
        col: None,
        mode,
        step_title: s("title").map(str::to_string),
        plan_entry: plan_entry.map(str::to_string),
        wrote: done && matches!(mode, FollowMode::Edit | FollowMode::Write),
    })
}

impl View {
    /// A tick at AT, unless one is asked for already.
    fn arm(&mut self, at: u64, fx: &mut Vec<Fx>) {
        if self.armed.insert(at) {
            fx.push(Fx::Arm { at });
        }
    }

    /// M, a move of the followed session: what the window would show now (nothing yet: a dwell runs).
    fn offer(&mut self, m: &Move, now: u64, fx: &mut Vec<Fx>) {
        let shown_file = self
            .due
            .as_ref()
            .or(self.shown.as_ref())
            .and_then(|s| s.file.clone());
        let same = m.file.is_none() || shown_file.is_none() || m.file == shown_file;
        let next = if m.mode == FollowMode::Listed {
            // a search never switches: its query in the line, the window where it is
            match self.due.as_ref().or(self.shown.as_ref()) {
                Some(s) if !same || m.file.is_none() => Some(Move {
                    step_title: m.step_title.clone(),
                    plan_entry: m.plan_entry.clone(),
                    mode: FollowMode::Listed,
                    wrote: false,
                    ..s.clone()
                }),
                _ => Some(m.clone()),
            }
        } else if same {
            self.dwell = None;
            Some(m.clone())
        } else if m.mode == FollowMode::Read {
            // another file read: switch once the agent has stayed in it DWELL_MS
            let since = match &self.dwell {
                Some((d, since)) if d.file == m.file => *since,
                _ => now,
            };
            self.dwell = Some((m.clone(), since));
            if now >= since + DWELL_MS {
                self.dwell = None;
                Some(m.clone())
            } else {
                self.arm(since + DWELL_MS, fx);
                None
            }
        } else {
            // an edit, a write, a pending edit: at once
            self.dwell = None;
            Some(m.clone())
        };
        if m.wrote && m.file.is_some() && next.as_ref().is_some_and(|n| n.file == m.file) {
            self.changed = true;
        }
        if let Some(n) = next {
            self.due = Some(n);
        }
    }

    /// A dwell that has run its time switches the window.
    fn dwell_done(&mut self, now: u64) {
        if let Some((m, since)) = &self.dwell
            && now >= since + DWELL_MS
        {
            self.due = Some(m.clone());
            self.dwell = None;
        }
    }

    /// The move due, sent when the throttle allows; else a tick when it will.
    fn flush(&mut self, key: &ViewKey, now: u64, fx: &mut Vec<Fx>) {
        if self.due.is_none() {
            return;
        }
        if let Some(at) = self.sent_at
            && now < at + MOVE_EVERY_MS
        {
            self.arm(at + MOVE_EVERY_MS, fx);
            return;
        }
        let m = self.due.take().expect("due");
        fx.push(Fx::Send {
            conn: key.0,
            data: data(&key.1, &m, self.changed),
        });
        self.changed = false;
        self.sent_at = Some(now);
        self.shown = Some(m);
    }
}

impl Core {
    pub fn step(&mut self, ev: Ev) -> Vec<Fx> {
        let mut fx = Vec::new();
        match ev {
            Ev::Follow { key, session, now } => {
                let mut v = View {
                    session: session.clone(),
                    shown: None,
                    sent_at: None,
                    due: self.last.get(&session).cloned(),
                    changed: false,
                    dwell: None,
                    armed: BTreeSet::new(),
                };
                v.flush(&key, now, &mut fx);
                self.views.insert(key, v);
            }
            Ev::Unfollow { key } => {
                self.views.remove(&key);
            }
            Ev::Gone { conn } => self.views.retain(|(c, _), _| *c != conn),
            Ev::Moved { m, now } => {
                for (key, v) in self
                    .views
                    .iter_mut()
                    .filter(|(_, v)| v.session == m.session)
                {
                    v.offer(&m, now, &mut fx);
                    v.flush(key, now, &mut fx);
                }
                self.last.insert(m.session.clone(), m);
            }
            Ev::Tick { now } => {
                for (key, v) in self.views.iter_mut() {
                    v.armed.retain(|at| *at > now);
                    v.dwell_done(now);
                    v.flush(key, now, &mut fx);
                }
            }
        }
        fx
    }

    /// Whether VIEW of connection CONN follows a session.
    pub fn follows(&self, key: &ViewKey) -> bool {
        self.views.contains_key(key)
    }

    /// Session SID ended: no view gets more of it, and a new follow starts from nothing.
    pub fn session_gone(&mut self, sid: &str) {
        self.last.remove(sid);
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The shell: the core under a lock, the hub's clock in ms from its start, the events and the deadlines.
pub struct Follows {
    core: Mutex<Core>,
    /// The clock's zero: read at the first use, so a hub on a test clock counts from that clock.
    origin: OnceLock<tokio::time::Instant>,
    editors: Arc<crate::settings::agents::Editors>,
}

impl Follows {
    pub fn new(editors: Arc<crate::settings::agents::Editors>) -> Arc<Follows> {
        Arc::new(Follows {
            core: Mutex::new(Core::default()),
            origin: OnceLock::new(),
            editors,
        })
    }

    fn now_ms(&self) -> u64 {
        let now = crate::clock::now();
        let origin = *self.origin.get_or_init(|| now);
        u64::try_from(now.saturating_duration_since(origin).as_millis()).unwrap_or(u64::MAX)
    }

    fn run(self: &Arc<Self>, ev: Ev) {
        let fx = lock(&self.core).step(ev);
        let now = self.now_ms();
        for f in fx {
            match f {
                Fx::Send { conn, data } => {
                    self.editors
                        .send_to(conn, "agent-follow", serde_json::json!(data));
                }
                Fx::Arm { at } => {
                    let me = self.clone();
                    let wait = Duration::from_millis(at.saturating_sub(now));
                    crate::clock::spawn("follow:tick", async move {
                        crate::clock::sleep(wait).await;
                        let now = me.now_ms().max(at);
                        me.run(Ev::Tick { now });
                    });
                }
            }
        }
    }

    /// Connection CONN's VIEW follows SESSION.
    pub fn follow(self: &Arc<Self>, conn: u64, view: String, session: String) {
        let now = self.now_ms();
        self.run(Ev::Follow {
            key: (conn, view),
            session,
            now,
        });
    }

    /// Connection CONN's VIEW follows nothing; whether it followed a session.
    pub fn unfollow(self: &Arc<Self>, conn: u64, view: String) -> bool {
        let key = (conn, view);
        let had = lock(&self.core).follows(&key);
        self.run(Ev::Unfollow { key });
        had
    }

    /// A move of a session (its latest tool call).
    pub fn moved(self: &Arc<Self>, m: Move) {
        let now = self.now_ms();
        self.run(Ev::Moved { m, now });
    }

    /// Connection CONN is gone.
    pub fn gone(self: &Arc<Self>, conn: u64) {
        self.run(Ev::Gone { conn });
    }

    /// Session SID ended.
    pub fn session_gone(&self, sid: &str) {
        lock(&self.core).session_gone(sid);
    }
}

#[cfg(test)]
mod tests {
    //! The follow core in every order of the agent's moves, the hub's clock and its timers (skuld), within the
    //! declared events; and its pure parts.
    use super::*;
    use skuld::{Bound, Mode, Partial, every_order};

    fn mv(file: Option<&str>, line: u32, mode: FollowMode, title: &str) -> Move {
        Move {
            session: "s1".into(),
            file: file.map(str::to_string),
            worktree: "/w".into(),
            line: Some(line),
            col: None,
            mode,
            step_title: Some(title.into()),
            plan_entry: None,
            wrote: false,
        }
    }

    fn key() -> ViewKey {
        (7, "f1".into())
    }

    /// The core, the shell's clock and its armed deadlines, and what was sent (with the clock then).
    #[derive(Default)]
    struct Shell {
        core: Core,
        now: u64,
        armed: Vec<u64>,
        sent: Vec<(u64, AgentFollow)>,
        /// For each send, how many moves the agent had made then.
        seen: Vec<usize>,
        /// Each move as the agent made it, with the clock then.
        moves: Vec<(u64, Move)>,
    }

    #[derive(Clone, Debug)]
    enum Ev2 {
        /// The agent's move.
        Move(Move),
        /// The hub's clock goes on by N ms.
        Advance(u64),
        /// The earliest armed timer fires (at its deadline, or now if that has passed).
        Fire,
        /// Much later, every timer fired: what the window shows in the end.
        End,
    }
    skuld::events!(Ev2 {
        Move,
        Advance,
        Fire,
        End
    });

    impl Shell {
        fn new() -> Shell {
            let mut s = Shell::default();
            s.feed(Ev::Follow {
                key: key(),
                session: "s1".into(),
                now: 0,
            });
            s
        }

        fn feed(&mut self, ev: Ev) {
            for f in self.core.step(ev) {
                match f {
                    Fx::Send { data, .. } => {
                        self.sent.push((self.now, data));
                        self.seen.push(self.moves.len());
                    }
                    Fx::Arm { at } => self.armed.push(at),
                }
            }
        }

        fn fire(&mut self) {
            self.armed.sort_unstable();
            if self.armed.is_empty() {
                return;
            }
            let at = self.armed.remove(0);
            self.now = self.now.max(at);
            let now = self.now;
            self.feed(Ev::Tick { now });
        }
    }

    impl skuld::Core for Shell {
        type Event = Ev2;

        fn step(&mut self, ev: Ev2) -> Vec<Ev2> {
            match ev {
                Ev2::Move(m) => {
                    self.moves.push((self.now, m.clone()));
                    let now = self.now;
                    self.feed(Ev::Moved { m, now });
                }
                Ev2::Advance(n) => self.now += n,
                Ev2::Fire => self.fire(),
                Ev2::End => {
                    self.now += 10_000;
                    while !self.armed.is_empty() {
                        self.fire();
                    }
                }
            }
            Vec::new()
        }
    }

    /// Two sends are never closer than the throttle, and each sends the latest move there was then.
    fn throttled(s: &Shell) -> Result<(), String> {
        for w in s.sent.windows(2) {
            if w[1].0 < w[0].0 + MOVE_EVERY_MS {
                return Err(format!("moves at {} and {} ms", w[0].0, w[1].0));
            }
        }
        Ok(())
    }

    fn check_throttle(s: &Shell, _: &[Ev2]) -> Result<(), String> {
        throttled(s)?;
        for ((at, d), n) in s.sent.iter().zip(&s.seen) {
            let latest = n.checked_sub(1).map(|i| &s.moves[i].1);
            if latest.and_then(|m| m.line) != d.line {
                return Err(format!(
                    "sent line {:?} at {at} ms; the latest was {latest:?}",
                    d.line
                ));
            }
        }
        // in the end the window shows the agent's last move
        let last = s.moves.last().map(|(_, m)| m.line);
        if s.sent.last().map(|(_, d)| d.line) != last {
            return Err(format!(
                "ends at {:?}, the agent at {last:?}",
                s.sent.last()
            ));
        }
        Ok(())
    }

    /// [A] Five moves in one file, the hub's clock advancing between them and its timers firing in every order: no
    /// two moves reach the view within 200 ms, each one sent is the latest at its time, and the last one arrives.
    #[test]
    fn every_order_moves_are_throttled_to_200_ms() {
        let mut p = Partial::new();
        let agent = p.source(
            "agent",
            (1..=5)
                .map(|n| Ev2::Move(mv(Some("/w/a.rs"), n, FollowMode::Edit, "Edit a.rs")))
                .collect(),
        );
        let clock = p.source(
            "clock",
            vec![Ev2::Advance(120), Ev2::Advance(120), Ev2::End],
        );
        let timer = p.source("timer", vec![Ev2::Fire, Ev2::Fire]);
        p.before((agent, 4), (clock, 2));
        p.before((timer, 1), (clock, 2));
        let r = every_order(&p, Bound::default(), Shell::new, check_throttle);
        assert!(matches!(r.mode, Mode::Exhaustive | Mode::DelayBounded(_)));
        assert!(r.orders > 100, "{} orders", r.orders);
    }

    fn check_dwell(s: &Shell, _: &[Ev2]) -> Result<(), String> {
        throttled(s)?;
        // b.rs is shown only once the agent has been in it for the dwell
        let first_b = s
            .moves
            .iter()
            .find(|(_, m)| m.file.as_deref() == Some("/w/b.rs"))
            .map(|(t, _)| *t);
        for (at, d) in &s.sent {
            if d.file.as_deref() == Some("/w/b.rs") {
                let since = first_b.ok_or("b.rs shown before it was read")?;
                if *at < since + DWELL_MS {
                    return Err(format!("switched at {at} ms, read since {since} ms"));
                }
            }
        }
        match s.sent.last().map(|(_, d)| d.file.as_deref()) {
            Some(Some("/w/b.rs")) => Ok(()),
            other => Err(format!("ends on {other:?}, the agent reads b.rs")),
        }
    }

    /// [A] The agent reads a.rs, then b.rs twice, while the clock advances and timers fire in every order: the view
    /// stays on a.rs until the agent has been in b.rs for 500 ms, then switches, and ends there.
    #[test]
    fn every_order_a_read_switch_waits_for_the_dwell() {
        let mut p = Partial::new();
        let agent = p.source(
            "agent",
            vec![
                Ev2::Move(mv(Some("/w/a.rs"), 1, FollowMode::Read, "Read a.rs")),
                Ev2::Move(mv(Some("/w/b.rs"), 1, FollowMode::Read, "Read b.rs")),
                Ev2::Move(mv(Some("/w/b.rs"), 40, FollowMode::Read, "Read b.rs")),
            ],
        );
        let clock = p.source(
            "clock",
            vec![
                Ev2::Advance(200),
                Ev2::Advance(200),
                Ev2::Advance(200),
                Ev2::End,
            ],
        );
        let timer = p.source("timer", vec![Ev2::Fire, Ev2::Fire]);
        p.before((agent, 2), (clock, 3));
        p.before((timer, 1), (clock, 3));
        let r = every_order(&p, Bound::default(), Shell::new, check_dwell);
        assert!(matches!(r.mode, Mode::Exhaustive | Mode::DelayBounded(_)));
        assert!(r.orders > 100, "{} orders", r.orders);
    }

    /// [D] A search (and a glob) after a read keeps the window on the file read: its query is the line, and no
    /// dwell or time moves it to a file it listed.
    #[test]
    fn a_search_never_switches_files() {
        let mut c = Core::default();
        c.step(Ev::Follow {
            key: key(),
            session: "s1".into(),
            now: 0,
        });
        let fx = c.step(Ev::Moved {
            m: mv(Some("/w/a.rs"), 3, FollowMode::Read, "Read a.rs"),
            now: 0,
        });
        assert!(
            matches!(&fx[..], [Fx::Send { data, .. }] if data.file.as_deref() == Some("/w/a.rs"))
        );
        let mut sent = Vec::new();
        for (now, m) in [
            (300, mv(None, 1, FollowMode::Listed, "grep \"retry\" .")),
            (
                600,
                mv(Some("/w/b.rs"), 9, FollowMode::Listed, "Glob **/*.rs"),
            ),
        ] {
            sent.extend(c.step(Ev::Moved { m, now }));
            sent.extend(c.step(Ev::Tick { now: now + 5000 }));
        }
        let lines: Vec<(Option<String>, Option<u32>, Option<String>)> = sent
            .iter()
            .filter_map(|f| match f {
                Fx::Send { data, .. } => {
                    Some((data.file.clone(), data.line, data.step_title.clone()))
                }
                Fx::Arm { .. } => None,
            })
            .collect();
        assert_eq!(
            lines,
            vec![
                (
                    Some("/w/a.rs".into()),
                    Some(3),
                    Some("grep \"retry\" .".into())
                ),
                (Some("/w/a.rs".into()), Some(3), Some("Glob **/*.rs".into())),
            ]
        );
    }

    /// [D] The line names its source: the agent's in-progress plan entry when it sends plans, else the tool call's
    /// title; nothing else is ever in it.
    #[test]
    fn why_source_names_the_plan_entry_when_sent() {
        let mut c = Core::default();
        c.step(Ev::Follow {
            key: key(),
            session: "s1".into(),
            now: 0,
        });
        let mut m = mv(Some("/w/a.rs"), 3, FollowMode::Edit, "Edit a.rs");
        let fx = c.step(Ev::Moved {
            m: m.clone(),
            now: 0,
        });
        let [Fx::Send { data, .. }] = &fx[..] else {
            panic!("{fx:?}")
        };
        assert_eq!(
            (data.why_source, data.plan_entry.as_deref()),
            (WhySource::StepTitle, None)
        );
        m.plan_entry = Some("Retry a step that timed out".into());
        let fx = c.step(Ev::Moved { m, now: 400 });
        let [Fx::Send { data, .. }] = &fx[..] else {
            panic!("{fx:?}")
        };
        assert_eq!(
            (
                data.why_source,
                data.plan_entry.as_deref(),
                data.step_title.as_deref()
            ),
            (
                WhySource::PlanEntry,
                Some("Retry a step that timed out"),
                Some("Edit a.rs")
            )
        );
    }
}
