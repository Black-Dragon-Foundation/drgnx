//! The `agents-side` view's model and rows (frontend flow plan, Task 12): the Agents side as cards, one per
//! session. Needs you first, then running, then the rest by last activity; "Earlier" holds the five newest past
//! sessions and an `All ›` row. Each card is a few rows keyed by its session, so one session's change patches only
//! its card's rows. Plain `RowBuilder` text until the kit draws the cards (Task 24).

use crate::dispatch::Caller;
use crate::front::Front;
use crate::view::{Key, Views};
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
        }
    }));
    out
}

impl Views {
    /// The rows of KEY's Agents side for its class; false when the view is none.
    pub(super) fn agents_side_build(&self, f: &Front, key: &Key) -> bool {
        if !lock(&self.agents_sides.views).contains(&(key.0, key.1.clone())) {
            return false;
        }
        let rows = rows(&sessions_now(f));
        self.publish_built(f, key, |_, _| (rows, Vec::new()));
        true
    }

    fn agents_side_show(&self, f: &Front, conn: u64, view: &str) {
        self.publish_rows(f, conn, view, rows(&sessions_now(f)));
    }

    /// A session changed: every Agents side shown reads the sessions again, and only the cards that changed go out.
    pub fn agents_side_changed(&self, f: &Front) {
        let views: Vec<(u64, String)> = lock(&self.agents_sides.views).iter().cloned().collect();
        if views.is_empty() {
            return;
        }
        let rows = rows(&sessions_now(f));
        for (c, v) in views {
            self.publish_rows(f, c, &v, rows.clone());
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

fn card(s: &SessionIn) -> Card {
    let action = if s.past {
        Some(CardAction::Open)
    } else if s.state == State::NeedsYou {
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
        state_line: state_word(s.state).to_owned(),
        progress: s.progress,
        action,
    }
}

/// The side's cards, in order, and the "Earlier" cards (the newest past sessions; more than [`EARLIER`] adds the
/// `All ›` row, which the rows add).
pub fn cards(sessions: &[SessionIn]) -> (Vec<Card>, Vec<Card>, bool) {
    let rank = |s: &SessionIn| match s.state {
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

/// One card's rows, keyed `card:SESSION:N`: its name and provider, its task, and its state with progress and the
/// one button; the button carries its action as `drgnx-action`.
pub fn card_rows(c: &Card) -> Vec<Row> {
    let mut head = RowBuilder::new(format!("card:{}:0", c.session));
    head.push(&format!("{} · {}", c.name, c.provider), None);
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
    state.push(&c.state_line, None);
    if let Some((d, t)) = c.progress {
        state.push(&format!(" · {d}/{t}"), None);
    }
    if let Some(a) = c.action {
        state.push(&format!("  {}", a.word()), None);
        let end = state.pos();
        state.prop(
            0,
            end,
            "drgnx-action",
            json!([a.word().to_lowercase(), c.session]),
        );
    }
    vec![head.finish(), task.finish(), state.finish()]
}

/// Every row of the side: the cards, then "Earlier" with its cards and the `All ›` row.
pub fn rows(sessions: &[SessionIn]) -> Vec<Row> {
    let (now, earlier, more) = cards(sessions);
    let mut out: Vec<Row> = now.iter().flat_map(card_rows).collect();
    if !earlier.is_empty() {
        let mut h = RowBuilder::new("earlier");
        h.push("Earlier", None);
        out.push(h.finish());
        out.extend(earlier.iter().flat_map(card_rows));
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
            let rows = card_rows(c);
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
        let rows = rows(&sessions);
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
        let (rb, ra) = (rows(&before), rows(&after));
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
