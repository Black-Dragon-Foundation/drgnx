//! The `agents-side` view's model and rows (frontend flow plan, Task 12): the Agents side as cards, one per
//! session. Needs you first, then running, then the rest by last activity; "Earlier" holds the five newest past
//! sessions and an `All ›` row. Each card is a few rows keyed by its session, so one session's change patches only
//! its card's rows. The kit draws them (Task 24): a card is the agent's mark, its task, a state line with the plan's
//! progress bar (or, near or at a dollar limit, the budget meter in its place: never two bars) and one button.

use crate::dispatch::Caller;
use crate::front::Front;
use crate::view::{Key, Views};
use drgnx_rows::kit::{
    self, ButtonStyle, Comp, KitEnv, MeterSize, MeterState, MeterUnit, ProgressKind, Size,
};
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::agents_side::{Set, Subscribe, ViewId};
use runstav::methods::past::PastProvider;
use runstav::wire::Error;
use serde_json::json;
use std::collections::BTreeSet;
use std::sync::{Mutex, MutexGuard};
use vegvisir::State;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The Agents side views of every connection.
#[derive(Default)]
pub struct AgentsSides {
    views: Mutex<BTreeSet<(u64, String)>>,
}

impl AgentsSides {
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.views).retain(|(c, _)| *c != conn);
    }
}

/// Every session the side shows: the live ones (the hub's table, in start order: a later one is the more recent), then
/// the past sessions of Claude Code, Gemini CLI and Codex (newest first).
pub fn sessions_now(f: &Front) -> Vec<SessionIn> {
    let live = f.core.agents.live_sessions();
    let n = live.len() as u64;
    let mut out: Vec<SessionIn> = live
        .iter()
        .enumerate()
        .map(|(i, s)| {
            let snap = s.snapshot();
            SessionIn {
                id: snap.id.clone(),
                name: snap.name.clone().unwrap_or_else(|| snap.id.clone()),
                provider: snap.profile.clone().unwrap_or_default(),
                task_title: snap.task.clone().unwrap_or_default(),
                state: crate::work::map::state_of(&snap),
                progress: None,
                last_activity: 1 + i as u64,
                edits_ready: !snap.reviews.is_empty(),
                past: false,
                seq: 1 + i as u64,
                budget: budget_of(f, &snap.id),
            }
        })
        .collect();
    let past = f.core.past.sessions();
    let total = past.len() as u64;
    out.extend(past.into_iter().enumerate().map(|(i, p)| {
        SessionIn {
            id: format!("past:{}", p.id),
            name: p.title.clone(),
            provider: match p.provider {
                PastProvider::Claude => "Claude",
                PastProvider::Gemini => "Gemini",
                PastProvider::Codex => "Codex",
            }
            .to_owned(),
            task_title: p.cwd.clone().unwrap_or_default(),
            state: State::Finished,
            progress: None,
            // newest first in the list: keep that order below the live ones
            last_activity: total - i as u64,
            edits_ready: false,
            past: true,
            seq: n + 1 + i as u64,
            budget: None,
        }
    }));
    out
}

/// The dollar limit that holds session SID (its own, or a scope's above it), as the card's line 3 says it.
fn budget_of(f: &Front, sid: &str) -> Option<Budget> {
    use runstav::methods::matrix::Unit;
    let b = &f.core.budgets;
    match b.binding(&b.holder_of_session(sid)?)? {
        (Unit::Usd | Unit::UsdEst, spent, limit) => Some(Budget { spent, limit }),
        _ => None,
    }
}

impl Views {
    /// The rows of KEY's Agents side for its class; false when the view is none.
    pub(super) fn agents_side_build(&self, f: &Front, key: &Key) -> bool {
        if !lock(&self.agents_sides.views).contains(&(key.0, key.1.clone())) {
            return false;
        }
        let sessions = sessions_now(f);
        self.publish_built(f, key, |env, _| {
            (rows(&sessions, &super::kit_env(env)), Vec::new())
        });
        true
    }

    fn agents_side_show(&self, f: &Front, conn: u64, view: &str) {
        for class in self.classes(conn, view) {
            self.agents_side_build(f, &(conn, view.to_owned(), class));
        }
    }

    /// A session changed: every Agents side shown reads the sessions again, and only the cards that changed go out.
    pub fn agents_side_changed(&self, f: &Front) {
        let views: Vec<(u64, String)> = lock(&self.agents_sides.views).iter().cloned().collect();
        for (c, v) in views {
            self.agents_side_show(f, c, &v);
        }
    }
}

/// `agents/side/subscribe`.
pub fn subscribe(f: &Front, c: &Caller, p: Subscribe) -> Result<bool, Error> {
    lock(&f.core.views.agents_sides.views).insert((c.conn_id, p.view.clone()));
    f.core.views.agents_side_show(f, c.conn_id, &p.view);
    Ok(true)
}

/// `agents/side/set`: refresh reads the sessions and the past sessions again.
pub fn set(f: &Front, c: &Caller, p: Set) -> Result<bool, Error> {
    if !lock(&f.core.views.agents_sides.views).contains(&(c.conn_id, p.view.clone())) {
        return Err(Error {
            code: runstav::wire::ErrorCode::InvalidParams,
            message: "not an Agents side view (agents/side/subscribe first)".into(),
            path: Some("view".into()),
        });
    }
    if p.refresh {
        f.core.views.agents_side_show(f, c.conn_id, &p.view);
    }
    Ok(true)
}

/// `agents/side/close`.
pub fn close(f: &Front, c: &Caller, p: ViewId) -> Result<bool, Error> {
    Ok(lock(&f.core.views.agents_sides.views).remove(&(c.conn_id, p.view)))
}

/// How many past sessions "Earlier" lists.
pub const EARLIER: usize = 5;

/// What the side knows of one session.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionIn {
    pub id: String,
    pub name: String,
    /// The provider (`Claude`, `Codex`, `Gemini`, …).
    pub provider: String,
    pub task_title: String,
    pub state: State,
    /// Plan steps done of total.
    pub progress: Option<(u32, u32)>,
    /// The hub's minute of its last activity.
    pub last_activity: u64,
    /// Edits wait for review.
    pub edits_ready: bool,
    /// An ended session: it goes to "Earlier".
    pub past: bool,
    /// Start order: the agent's mark (colour and shape) follows it.
    pub seq: u64,
    /// The dollar limit that holds it, when one does.
    pub budget: Option<Budget>,
}

/// A session's spend against the dollar limit that holds it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Budget {
    pub spent: f64,
    pub limit: f64,
}

impl Budget {
    /// Nearing from 80 % of the limit (the budget spec's rule), reached at it.
    pub fn state(&self) -> MeterState {
        if self.limit <= 0.0 || self.spent >= self.limit {
            MeterState::Reached
        } else if self.spent / self.limit >= 0.8 {
            MeterState::Nearing
        } else {
            MeterState::Ok
        }
    }
}

/// The one button a card has.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CardAction {
    /// It needs you: answer.
    Answer,
    /// Its edits are ready: review.
    Review,
    /// Otherwise: open its conversation.
    Open,
}

impl CardAction {
    pub fn word(self) -> &'static str {
        match self {
            CardAction::Answer => "Answer",
            CardAction::Review => "Review",
            CardAction::Open => "Open",
        }
    }
}

/// One card.
#[derive(Clone, Debug, PartialEq)]
pub struct Card {
    pub session: String,
    pub name: String,
    /// The agent's colour slot, 1 to 6.
    pub mark: u8,
    pub task_title: String,
    pub provider: String,
    pub state_line: String,
    pub progress: Option<(u32, u32)>,
    pub action: Option<CardAction>,
    pub budget: Option<Budget>,
}

fn state_word(s: State) -> &'static str {
    match s {
        State::Queued => "queued",
        State::Running => "running",
        State::Waiting => "waiting",
        State::NeedsYou => "needs you",
        State::Review => "review",
        State::Paused => "paused",
        State::Stalled => "stalled",
        State::Finished => "finished",
    }
}

/// A session a reached limit holds: it needs you (it sorts first, its button is Answer).
fn held(s: &SessionIn) -> bool {
    !s.past && s.budget.is_some_and(|b| b.state() == MeterState::Reached)
}

fn card(s: &SessionIn) -> Card {
    let action = if s.past {
        Some(CardAction::Open)
    } else if s.state == State::NeedsYou || held(s) {
        Some(CardAction::Answer)
    } else if s.edits_ready || s.state == State::Review {
        Some(CardAction::Review)
    } else {
        Some(CardAction::Open)
    };
    Card {
        session: s.id.clone(),
        name: s.name.clone(),
        mark: u8::try_from(s.seq.saturating_sub(1) % 6 + 1).unwrap_or(1),
        task_title: s.task_title.clone(),
        provider: s.provider.clone(),
        state_line: if held(s) {
            "Paused at its limit".to_owned()
        } else {
            state_word(s.state).to_owned()
        },
        progress: s.progress,
        action,
        budget: s.budget,
    }
}

/// The side's cards, in order, and the "Earlier" cards (the newest past sessions; more than [`EARLIER`] adds the
/// `All ›` row, which the rows add).
pub fn cards(sessions: &[SessionIn]) -> (Vec<Card>, Vec<Card>, bool) {
    let rank = |s: &SessionIn| match s.state {
        _ if held(s) => 0,
        State::NeedsYou => 0,
        State::Running | State::Waiting | State::Queued => 1,
        _ => 2,
    };
    let mut now: Vec<&SessionIn> = sessions.iter().filter(|s| !s.past).collect();
    now.sort_by(|a, b| {
        (rank(a), std::cmp::Reverse(a.last_activity), &a.id).cmp(&(
            rank(b),
            std::cmp::Reverse(b.last_activity),
            &b.id,
        ))
    });
    let mut past: Vec<&SessionIn> = sessions.iter().filter(|s| s.past).collect();
    past.sort_by(|a, b| {
        (std::cmp::Reverse(a.last_activity), &a.id)
            .cmp(&(std::cmp::Reverse(b.last_activity), &b.id))
    });
    let more = past.len() > EARLIER;
    (
        now.into_iter().map(card).collect(),
        past.into_iter().take(EARLIER).map(card).collect(),
        more,
    )
}

/// The sessions working on PATH: ENTRIES are the presence model's (path, session) pairs (sorted, no repeats).
pub fn agents_on(entries: &[(String, String)], path: &str) -> Vec<String> {
    let mut out: Vec<String> = entries
        .iter()
        .filter(|(p, _)| p == path)
        .map(|(_, s)| s.clone())
        .collect();
    out.sort();
    out.dedup();
    out
}

/// Dollars as line 3 says them: "$5" for a whole amount, "$1.20" otherwise.
fn dollars(x: f64) -> String {
    if (x - x.round()).abs() < 0.005 {
        format!("${}", x.round() as i64)
    } else {
        format!("${x:.2}")
    }
}

/// The width of a card's bar (the plan's progress, or the budget meter in its place), logical px.
const CARD_BAR_PX: u16 = 120;

/// One card's rows, keyed `card:SESSION:N`, drawn with the kit: the agent's mark, its name and provider; its task; the
/// state line (its word, the spend against its limit, done of total) with one bar: the plan's progress, or the budget
/// meter when the spend nears or reached its limit; and the one button (primary when it needs you), which carries its
/// action as `drgnx-action`.
pub fn card_rows(c: &Card, env: &KitEnv) -> Vec<Row> {
    let mut head = RowBuilder::new(format!("card:{}:0", c.session));
    kit::expand(
        &mut head,
        env,
        &Comp::AgentMark {
            slot: c.mark,
            handle: c
                .name
                .chars()
                .next()
                .map(|ch| ch.to_uppercase().to_string())
                .unwrap_or_default(),
        },
    );
    head.push(&format!(" {} · {}", c.name, c.provider), None);
    let end = head.pos();
    head.prop(0, end, "drgnx-agent-mark", json!(c.mark));
    head.prop(
        0,
        end,
        "drgnx-work-id",
        json!(format!("agent:{}", c.session)),
    );
    let mut task = RowBuilder::new(format!("card:{}:1", c.session));
    task.push(&c.task_title, None);
    let mut state = RowBuilder::new(format!("card:{}:2", c.session));
    let mut line = c.state_line.clone();
    if let Some(b) = c.budget {
        if b.state() == MeterState::Reached {
            line.push_str(&format!(" · ${:.2} of ${:.2}", b.spent, b.limit));
        } else {
            line.push_str(&format!(" · ${:.2}/{}", b.spent, dollars(b.limit)));
        }
    }
    if let Some((d, t)) = c.progress {
        line.push_str(&format!(" · {d}/{t}"));
    }
    state.push(&line, None);
    state.push(" ", None);
    // one bar: the meter when the spend nears or reached its limit, else the plan's progress
    match c.budget.filter(|b| b.state() != MeterState::Ok) {
        Some(b) => kit::expand(
            &mut state,
            env,
            &Comp::Meter {
                spent: b.spent,
                limit: Some(b.limit),
                unit: MeterUnit::UsdEst,
                forecast: None,
                state: b.state(),
                size: MeterSize::Card,
                width: CARD_BAR_PX,
                text: String::new(),
            },
        ),
        None => {
            if let Some((d, t)) = c.progress.filter(|p| p.1 > 0) {
                kit::expand(
                    &mut state,
                    env,
                    &Comp::Progress {
                        kind: ProgressKind::Bar,
                        value: f64::from(d) / f64::from(t),
                        width: CARD_BAR_PX,
                    },
                );
            }
        }
    }
    if let Some(a) = c.action {
        state.push("  ", None);
        let from = state.pos();
        kit::expand(
            &mut state,
            env,
            &Comp::Button {
                label: a.word().to_owned(),
                style: if a == CardAction::Answer {
                    ButtonStyle::Primary
                } else {
                    ButtonStyle::Secondary
                },
                size: Size::Sm,
                state: kit::State::Rest,
                key: None,
                action: None,
            },
        );
        let to = state.pos();
        state.prop(
            from,
            to,
            "drgnx-action",
            json!([a.word().to_lowercase(), c.session]),
        );
    }
    vec![head.finish(), task.finish(), state.finish()]
}

/// Every row of the side: the cards, then "Earlier" (a kit section header) with its cards and the `All ›` row.
pub fn rows(sessions: &[SessionIn], env: &KitEnv) -> Vec<Row> {
    let (now, earlier, more) = cards(sessions);
    let mut out: Vec<Row> = now.iter().flat_map(|c| card_rows(c, env)).collect();
    if !earlier.is_empty() {
        let mut h = RowBuilder::new("earlier");
        kit::expand(
            &mut h,
            env,
            &Comp::SectionHeader {
                title: "Earlier".into(),
                collapsible: false,
                collapsed: false,
                count: None,
                state: kit::State::Rest,
                action: None,
            },
        );
        out.push(h.finish());
        out.extend(earlier.iter().flat_map(|c| card_rows(c, env)));
        if more {
            let mut a = RowBuilder::new("all");
            a.push("All ›", None);
            let end = a.pos();
            a.prop(0, end, "drgnx-action", json!(["all"]));
            out.push(a.finish());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(id: &str, state: State, last: u64, past: bool) -> SessionIn {
        SessionIn {
            id: id.into(),
            name: id.into(),
            provider: "Claude".into(),
            task_title: format!("task of {id}"),
            state,
            progress: Some((1, 3)),
            last_activity: last,
            edits_ready: false,
            past,
            seq: 1,
            budget: None,
        }
    }

    #[test]
    fn needs_you_cards_come_first() {
        let sessions = vec![
            s("idle", State::Paused, 50, false),
            s("run", State::Running, 40, false),
            s("ask", State::NeedsYou, 1, false),
            s("run2", State::Running, 90, false),
        ];
        let (now, _, _) = cards(&sessions);
        let ids: Vec<&str> = now.iter().map(|c| c.session.as_str()).collect();
        assert_eq!(ids, ["ask", "run2", "run", "idle"]);
    }

    #[test]
    fn a_card_has_one_action() {
        let mut ready = s("ready", State::Running, 5, false);
        ready.edits_ready = true;
        let sessions = vec![
            s("ask", State::NeedsYou, 1, false),
            ready,
            s("plain", State::Running, 2, false),
        ];
        let (now, _, _) = cards(&sessions);
        let by = |id: &str| now.iter().find(|c| c.session == id).unwrap().action;
        assert_eq!(by("ask"), Some(CardAction::Answer));
        assert_eq!(by("ready"), Some(CardAction::Review));
        assert_eq!(by("plain"), Some(CardAction::Open));
        // one action row text per card
        for c in &now {
            let rows = card_rows(c, &kit_env());
            let acts = rows
                .iter()
                .flat_map(|r| &r.props)
                .filter(|p| p.2 == "drgnx-action")
                .count();
            assert_eq!(acts, 1, "{c:?}");
        }
    }

    #[test]
    fn earlier_lists_five_then_all() {
        let mut sessions = vec![s("live", State::Running, 100, false)];
        for i in 0..7 {
            sessions.push(s(&format!("old{i}"), State::Finished, i, true));
        }
        let (_, earlier, more) = cards(&sessions);
        assert_eq!(earlier.len(), EARLIER);
        assert!(more);
        // the newest five
        assert_eq!(earlier[0].session, "old6");
        assert_eq!(earlier[4].session, "old2");
        let rows = rows(&sessions, &kit_env());
        assert_eq!(rows.last().map(|r| r.key.as_str()), Some("all"));
        assert!(rows.iter().any(|r| r.key == "earlier"));
    }

    #[test]
    fn a_session_delta_patches_only_its_card() {
        let before = vec![
            s("a", State::Running, 5, false),
            s("b", State::Running, 4, false),
        ];
        let mut after = before.clone();
        after[1].state = State::NeedsYou;
        after[1].progress = Some((2, 3));
        let (rb, ra) = (rows(&before, &kit_env()), rows(&after, &kit_env()));
        // a needs-you card moves first: compare by key, not by place
        let changed: Vec<&str> = ra
            .iter()
            .filter(|r| rb.iter().find(|o| o.key == r.key) != Some(*r))
            .map(|r| r.key.as_str())
            .collect();
        assert!(!changed.is_empty());
        assert!(
            changed.iter().all(|k| k.starts_with("card:b:")),
            "{changed:?}"
        );
    }

    #[test]
    fn agents_on_lists_the_sessions_in_a_file() {
        let entries = vec![
            ("a.rs".to_owned(), "s2".to_owned()),
            ("a.rs".to_owned(), "s1".to_owned()),
            ("b.rs".to_owned(), "s3".to_owned()),
            ("a.rs".to_owned(), "s1".to_owned()),
        ];
        assert_eq!(agents_on(&entries, "a.rs"), ["s1", "s2"]);
        assert!(agents_on(&entries, "c.rs").is_empty());
    }

    /// Flow Task 24: the side's cards are the kit's pieces: a card is an `AgentMark`, the task title, a state line with
    /// the kit's `Progress`, and one kit `Button` (primary when it needs you); "Earlier" is a kit section header.
    #[test]
    fn cards_are_kit_cards_needs_you_first_with_one_kit_button() {
        let kit = drgnx_rows::kit::KitEnv {
            scale: 1.0,
            tty: false,
            glyphs: &[],
            ascii: false,
            density: Default::default(),
            icons: None,
        };
        let mut ask = s("ask", State::NeedsYou, 1, false);
        ask.progress = Some((2, 4));
        let run = s("run", State::Running, 90, false);
        let old = s("old", State::Finished, 5, true);
        let rows = rows(&[run, ask, old], &kit);
        let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
        assert!(
            keys[0].starts_with("card:ask:"),
            "needs-you first: {keys:?}"
        );
        // the agent's mark rides on the card's head row
        assert!(rows[0].props.iter().any(|p| p.2 == "drgnx-agent-mark"));
        // one button on the card: primary for Answer, with the action the editor runs
        let card: Vec<&Row> = rows
            .iter()
            .filter(|r| r.key.starts_with("card:ask:"))
            .collect();
        let faces: Vec<&str> = card
            .iter()
            .flat_map(|r| r.runs.iter().map(|x| x.2.as_str()))
            .collect();
        assert!(
            faces.contains(&drgnx_rows::faces::FaceId::KitButtonPrimary.name()),
            "{faces:?}"
        );
        assert_eq!(
            card.iter()
                .flat_map(|r| r.props.iter())
                .filter(|p| p.2 == "drgnx-action")
                .count(),
            1
        );
        // the plan's progress is the kit's meter, not words
        assert!(
            card.iter()
                .flat_map(|r| r.runs.iter())
                .any(|x| x.2 == drgnx_rows::faces::FaceId::KitProgress.name())
        );
        // "Earlier" is a kit section header
        let earlier = rows.iter().find(|r| r.key == "earlier").expect("Earlier");
        assert!(
            earlier
                .runs
                .iter()
                .any(|x| x.2 == drgnx_rows::faces::FaceId::KitSectionHeader.name())
        );
    }

    fn kit_env() -> drgnx_rows::kit::KitEnv<'static> {
        drgnx_rows::kit::KitEnv {
            scale: 1.0,
            tty: false,
            glyphs: &[],
            ascii: false,
            density: Default::default(),
            icons: None,
        }
    }

    /// Flow Task 24a: a card whose spend nears its limit swaps the plan's progress for the budget meter, and never
    /// draws two bars.
    #[test]
    fn a_nearing_card_swaps_progress_for_the_meter() {
        let mut near = s("near", State::Running, 9, false);
        near.progress = Some((1, 3));
        near.budget = Some(Budget {
            spent: 4.2,
            limit: 5.0,
        });
        let rows = rows(&[near], &kit_env());
        let faces: Vec<&str> = rows
            .iter()
            .flat_map(|r| r.runs.iter().map(|x| x.2.as_str()))
            .collect();
        assert!(
            faces.contains(&drgnx_rows::faces::FaceId::KitProgressMeterNear.name()),
            "{faces:?}"
        );
        assert!(
            !faces.contains(&drgnx_rows::faces::FaceId::KitProgressFill.name()),
            "never two bars: {faces:?}"
        );
    }

    /// A card whose limit was reached is a needs-you card with the question: Raise or Stop, first in the side.
    #[test]
    fn a_reached_card_is_needs_you_with_the_question() {
        let mut hit = s("hit", State::Paused, 1, false);
        hit.budget = Some(Budget {
            spent: 5.0,
            limit: 5.0,
        });
        let busy = s("busy", State::Running, 99, false);
        let rows = rows(&[busy, hit], &kit_env());
        assert!(
            rows[0].key.starts_with("card:hit:"),
            "needs-you first: {:?}",
            rows[0].key
        );
        let text: String = rows
            .iter()
            .filter(|r| r.key.starts_with("card:hit:"))
            .map(|r| r.text.as_str())
            .collect();
        assert!(text.contains("Paused at its limit"), "{text:?}");
        assert!(text.contains("$5.00 of $5.00"), "{text:?}");
    }
}
