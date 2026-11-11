//! The Board as rows and a model (`work/board/subscribe`; docs/develop/hub.md, "The Board"): the tracker's tasks in
//! six columns, a card each. Pure: the cards in, the model and the rows out.
//!
//! The model is the Board's own (not the map's): a `card` node per task with the `board` form's links (left and right
//! to the nearest column that has cards, at the same height or its last card; up and down within the column), the
//! lists `cards` (column by column) and `team` (the cards an agent works on). The rows: a heading per column, then three
//! rows per card height (the title; the state, the agent and the steps done; the progress bar), each card's carrying
//! its id.

use crate::view::model::Doc;
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::view::{Display, ViewEnv};
use serde_json::{Map, Value, json};

/// The columns, left to right: `norn::tracker::Column`'s.
pub(crate) const COLUMNS: [&str; 6] = [
    "queued",
    "running",
    "waiting",
    "needs-you",
    "review",
    "done",
];

const HEADINGS: [&str; 6] = [
    "Queued",
    "Running",
    "Waiting",
    "Needs you",
    "Review",
    "Done",
];

/// One task on the Board.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Card {
    pub id: String,
    pub title: String,
    pub status: String,
    pub plan: Option<String>,
    /// (steps done, steps) of a plan's task.
    pub progress: Option<(u32, u32)>,
    /// The agent working on it: (its map item id, its label).
    pub agent: Option<(String, String)>,
}

/// Puts on each card the agent of AGENTS (the task's id, the agent's map item id, its label) that works on its task:
/// by id, so two tasks of one title never show each other's agent.
pub(crate) fn put_agents(cards: &mut [Card], agents: &[(String, String, String)]) {
    for c in cards {
        c.agent = agents
            .iter()
            .find(|(task, ..)| *task == c.id)
            .map(|(_, id, label)| (id.clone(), label.clone()));
    }
}

/// The column of a task with STATUS, as `norn::tracker::board_column` has it (an unknown status is queued).
pub(crate) fn column(status: &str) -> usize {
    match status {
        "claimed" | "running" => 1,
        "waiting" => 2,
        "needs-input" => 3,
        "in-review" => 4,
        "done" | "dropped" => 5,
        _ => 0,
    }
}

/// CARDS by column, in their order.
fn columns(cards: &[Card]) -> [Vec<&Card>; 6] {
    let mut cols: [Vec<&Card>; 6] = Default::default();
    for c in cards {
        cols[column(&c.status)].push(c);
    }
    cols
}

/// The card sideways from row I of column C in direction STEP (-1, 1): the nearest column that has cards, at the
/// same height or its last card.
fn beside<'a>(cols: &[Vec<&'a Card>; 6], c: usize, i: usize, step: isize) -> Option<&'a Card> {
    let mut j = c as isize + step;
    while (0..6).contains(&j) {
        let col = &cols[j as usize];
        if let Some(last) = col.last() {
            return Some(col.get(i).copied().unwrap_or(last));
        }
        j += step;
    }
    None
}

/// The Board's model.
pub(crate) fn board_doc(cards: &[Card]) -> Doc {
    let mut d = Doc {
        descriptor: json!({
            "scheme": "links",
            "chain_kinds": [],
            "match_fields": ["label"],
            "lists": ["cards", "team"],
            "classes": ["selected", "match", "lit", "dim"],
            "flags": [],
            "forms": [{"name": "board"}],
            "start": "cards",
        }),
        ..Doc::default()
    };
    let cols = columns(cards);
    let (mut all, mut team) = (Vec::new(), Vec::new());
    for (c, col) in cols.iter().enumerate() {
        for (i, card) in col.iter().enumerate() {
            let mut links = Map::new();
            let mut link = |name: &str, to: Option<&Card>| {
                if let Some(to) = to.filter(|t| t.id != card.id) {
                    links.insert(name.into(), json!(to.id));
                }
            };
            link("up", i.checked_sub(1).map(|k| col[k]));
            link("down", col.get(i + 1).copied());
            link("left", beside(&cols, c, i, -1));
            link("right", beside(&cols, c, i, 1));
            let mut fields = vec![
                json!(["label", card.title]),
                json!(["status", card.status]),
                json!(["column", COLUMNS[c]]),
            ];
            if let Some(p) = &card.plan {
                fields.push(json!(["plan", p]));
            }
            if let Some((agent, label)) = &card.agent {
                fields.push(json!(["agent", agent]));
                fields.push(json!(["agent-label", label]));
                team.push(card.id.clone());
            }
            d.nodes.insert(
                card.id.clone(),
                json!({"id": card.id, "kind": "card", "flags": 0, "navs": {"board": Value::Object(links)},
                       "fields": fields}),
            );
            all.push(card.id.clone());
        }
    }
    d.lists.insert("cards".into(), all);
    d.lists.insert("team".into(), team);
    d
}

/// TEXT cut to CHARS characters, an ellipsis last when cut.
fn fit(text: &str, chars: usize) -> String {
    if text.chars().count() <= chars {
        return text.to_owned();
    }
    let mut s: String = text.chars().take(chars.saturating_sub(1)).collect();
    s.push('…');
    s
}

/// Line LINE (0: the title, 1: the state) of CARD.
fn card_line(card: &Card, line: usize) -> String {
    if line == 0 {
        return format!(
            "● {}",
            if card.title.is_empty() {
                &card.id
            } else {
                &card.title
            }
        );
    }
    let mut parts = vec![if card.status == "needs-you" {
        "needs you".to_owned()
    } else {
        card.status.clone()
    }];
    if let Some((_, label)) = &card.agent {
        parts.push(label.clone());
    }
    if let Some((done, all)) = card.progress {
        parts.push(format!("{done}/{all}"));
    }
    parts.join(" · ")
}

/// The Board's rows for ENV: a column is a sixth of the view's width, at least 120 px.
pub(crate) fn board_rows(cards: &[Card], env: &ViewEnv) -> Vec<Row> {
    let w = ((env.width_px.saturating_sub(12)) / 6).max(120);
    let chars = (w.saturating_sub(18) / env.cell.0.max(1)) as usize;
    let cols = columns(cards);
    let mut head = RowBuilder::new("head");
    for (c, col) in cols.iter().enumerate() {
        head.stop(c as u32 * w).push(
            &format!("{} · {}", HEADINGS[c], col.len()),
            Some("drgnx-work-label"),
        );
    }
    let mut rows = vec![head.finish()];
    let height = cols.iter().map(Vec::len).max().unwrap_or(0);
    if height == 0 {
        let mut b = RowBuilder::new("none");
        b.push("No tasks.", None);
        rows.push(b.finish());
        return rows;
    }
    for i in 0..height {
        for line in 0..3 {
            let mut b = RowBuilder::new(format!("cards:{i}:{line}"));
            for (c, col) in cols.iter().enumerate() {
                let Some(card) = col.get(i) else { continue };
                let left = c as u32 * w;
                if line == 2 {
                    bar(&mut b, card, left, w, chars, env);
                    continue;
                }
                b.stop(left);
                let at = b.pos();
                let face = if line == 0 {
                    "drgnx-card-top"
                } else {
                    "drgnx-card-mid"
                };
                b.push(&fit(&card_line(card, line), chars), Some(face));
                let end = b.pos();
                b.prop(at, end, "drgnx-work-id", json!(card.id));
            }
            rows.push(b.finish());
        }
    }
    rows
}

/// CARD's progress bar in its column at LEFT, W px wide: on a GUI two spaces 4 px high from 4 px in, the steps done
/// and the rest, together W less 16 px (sizes in device px: the env's scale's); on a terminal CHARS of `▰` and `▱`.
fn bar(b: &mut RowBuilder, card: &Card, left: u32, w: u32, chars: usize, env: &ViewEnv) {
    let part = |n: u32| match card.progress {
        Some((done, all)) if all > 0 => {
            ((n as f32 * done.min(all) as f32 / all as f32).round() as u32).min(n)
        }
        _ => 0,
    };
    let at;
    match env.display {
        Display::Gui => {
            // half up, as `drgnx-px` rounds
            let px = |v: f32| (f64::from(v) * f64::from(env.scale) + 0.5 + 1e-9).floor() as u32;
            let span = w.saturating_sub(px(16.0));
            let fill = part(span);
            b.stop(left + px(4.0));
            at = b.pos();
            b.space(fill, px(4.0), "drgnx-work-bar").space(
                span - fill,
                px(4.0),
                "drgnx-work-bar-rest",
            );
        }
        Display::Tty => {
            let n = chars as u32;
            let fill = part(n);
            b.stop(left);
            at = b.pos();
            b.push(&"▰".repeat(fill as usize), Some("drgnx-work-bar"))
                .push(
                    &"▱".repeat((n - fill) as usize),
                    Some("drgnx-work-bar-rest"),
                );
        }
    }
    let end = b.pos();
    b.face(at, end, "drgnx-card-bottom")
        .prop(at, end, "drgnx-work-id", json!(card.id));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn card(id: &str, status: &str, agent: Option<&str>) -> Card {
        Card {
            id: id.into(),
            title: format!("T {id}"),
            status: status.into(),
            agent: agent.map(|a| (format!("agent:{a}"), a.to_uppercase())),
            ..Card::default()
        }
    }

    fn link<'a>(d: &'a Doc, id: &str, name: &str) -> Option<&'a str> {
        d.nodes[id]["navs"]["board"][name].as_str()
    }

    /// [D] The Board's model: cards by column; the `board` form's links run within a column and across to the nearest
    /// column with cards (the same height, else its last card); `team` holds the cards with an agent.
    #[test]
    fn board_model_links_columns() {
        let cards = vec![
            card("task:a", "open", Some("s1")),
            card("task:b", "open", None),
            card("task:c", "running", None),
            card("task:d", "done", Some("s2")),
        ];
        let d = board_doc(&cards);
        assert_eq!(d.lists["cards"], ["task:a", "task:b", "task:c", "task:d"]);
        assert_eq!(d.lists["team"], ["task:a", "task:d"]);
        assert_eq!(link(&d, "task:a", "down"), Some("task:b"));
        assert_eq!(link(&d, "task:b", "up"), Some("task:a"));
        assert_eq!(link(&d, "task:a", "up"), None);
        assert_eq!(
            link(&d, "task:b", "right"),
            Some("task:c"),
            "the last card at a lower height"
        );
        assert_eq!(
            link(&d, "task:c", "right"),
            Some("task:d"),
            "past the empty columns"
        );
        assert_eq!(link(&d, "task:d", "right"), None);
        assert_eq!(link(&d, "task:c", "left"), Some("task:a"));
        assert_eq!(d.nodes["task:d"]["fields"][2], json!(["column", "done"]));
        assert_eq!(d.nodes["task:a"]["fields"][3], json!(["agent", "agent:s1"]));
    }

    /// [D] The rows: the headings with counts, then two rows per card height, each card's text holding its id.
    #[test]
    fn board_rows_carry_card_ids() {
        let env = ViewEnv {
            view: "b".into(),
            class: "c".into(),
            epoch: 1,
            display: Display::Gui,
            scale: 1.0,
            fonts: vec![],
            cell: (8, 16),
            width_px: 1212,
            palette: vec![],
            tty_widths: vec![],
            tz: String::new(),
            reduced_motion: false,
            attach: false,
        };
        let mut a = card("task:a", "needs-input", Some("s1"));
        a.progress = Some((1, 3));
        let rows = board_rows(&[a, card("task:b", "open", None)], &env);
        let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
        assert_eq!(keys, ["head", "cards:0:0", "cards:0:1", "cards:0:2"]);
        assert!(rows[0].text.contains("Needs you · 1"), "{}", rows[0].text);
        assert!(
            rows[2].text.contains("needs-input · S1 · 1/3"),
            "{}",
            rows[2].text
        );
        let ids: Vec<&Value> = rows[1]
            .props
            .iter()
            .filter(|p| p.2 == "drgnx-work-id")
            .map(|p| &p.3)
            .collect();
        assert_eq!(ids, [&json!("task:b"), &json!("task:a")]);
        assert_eq!(board_rows(&[], &env)[1].key, "none");
    }

    fn env(display: Display, scale: f32) -> ViewEnv {
        ViewEnv {
            view: "b".into(),
            class: "c".into(),
            epoch: 1,
            display,
            scale,
            fonts: vec![],
            cell: (8, 16),
            width_px: 1212,
            palette: vec![],
            tty_widths: vec![],
            tz: String::new(),
            reduced_motion: false,
            attach: false,
        }
    }

    /// [D] A card's third row is its progress bar: on a GUI two spaces 4 px high (device px: the scale's), the steps
    /// done in `drgnx-work-bar` and the rest in `drgnx-work-bar-rest`, together the card's width less its padding,
    /// starting 4 px in; with no steps all rest.  On a terminal the bar is text, `▰` done and `▱` the rest.
    #[test]
    fn board_cards_end_in_a_progress_bar() {
        let mut a = card("task:a", "running", None);
        a.progress = Some((1, 4));
        let cards = [a, card("task:b", "open", None)];
        for scale in [1.0, 2.0] {
            let rows = board_rows(&cards, &env(Display::Gui, scale));
            let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
            assert_eq!(keys, ["head", "cards:0:0", "cards:0:1", "cards:0:2"]);
            let bar = &rows[3];
            let px = |v: f32| (v * scale).round() as u32;
            let span = 200 - px(16.0); // a sixth of 1212 - 12
            assert_eq!(
                bar.stops,
                vec![(0, px(4.0)), (3, 200 + px(4.0))],
                "scale {scale}"
            );
            let fill = (span as f32 / 4.0).round() as u32;
            assert_eq!(
                bar.spaces,
                vec![
                    (1, 0, px(4.0)),
                    (2, span, px(4.0)),
                    (4, fill, px(4.0)),
                    (5, span - fill, px(4.0))
                ],
                "scale {scale}: task:b (queued, no steps) then task:a"
            );
            let faces: Vec<&str> = bar.runs.iter().map(|r| r.2.as_str()).collect();
            assert!(faces.contains(&"drgnx-work-bar") && faces.contains(&"drgnx-work-bar-rest"));
            assert!(
                bar.props.iter().any(|p| p.3 == json!("task:a")),
                "the bar holds its card's id"
            );
        }
        let tty = board_rows(&cards, &env(Display::Tty, 1.0));
        let bar = &tty[3];
        assert!(bar.spaces.is_empty());
        // the card's text width, 22 columns (182 px of 8), a quarter done
        let want = format!("{}{}", "▰".repeat(6), "▱".repeat(16));
        assert!(bar.text.contains(&want), "{}", bar.text);
        assert!(bar.text.contains(&"▱".repeat(22)), "{}", bar.text);
    }

    /// [D] A card shows the agent whose task id is the card's: of two tasks with one title, only the one the agent works
    /// on (SJA-BOARD-1 (2): a title match put it on both).
    #[test]
    fn an_agent_goes_on_its_task_s_card_only() {
        let mut cards = vec![
            Card {
                title: "Ship it".into(),
                ..card("task:a", "open", None)
            },
            Card {
                title: "Ship it".into(),
                ..card("task:b", "open", None)
            },
        ];
        put_agents(
            &mut cards,
            &[("task:b".into(), "agent:s1".into(), "S1".into())],
        );
        assert_eq!(cards[0].agent, None);
        assert_eq!(cards[1].agent, Some(("agent:s1".into(), "S1".into())));
    }
}
