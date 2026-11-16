//! The `agents-side` view's model and rows (frontend flow plan, Task 12): the Agents side as cards, one per
//! session. Needs you first, then running, then the rest by last activity; "Earlier" holds the five newest past
//! sessions and an `All ›` row. Each card is a few rows keyed by its session, so one session's change patches only
//! its card's rows. Plain `RowBuilder` text until the kit draws the cards (Task 24).

use drgnx_rows::{Row, RowBuilder};
use serde_json::json;
use vegvisir::State;

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
}
