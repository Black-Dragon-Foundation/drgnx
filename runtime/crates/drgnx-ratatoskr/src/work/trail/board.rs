//! The Board as rows and a model (`work/board/subscribe`; docs/develop/hub.md, "The Board"): the tracker's tasks in
//! six columns, a card each. Pure: the cards in, the model and the rows out.
//!
//! The model is the Board's own (not the map's): a `card` node per task with the `board` form's links (left and right
//! to the nearest column that has cards, at the same height or its last card; up and down within the column), the
//! lists `cards` (column by column) and `team` (the cards an agent works on). The rows: a heading per column, then two
//! rows per card height (the title; the state, the agent and the steps done), each card's text carrying its id.

use crate::view::model::Doc;
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::view::ViewEnv;
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
        for line in 0..2 {
            let mut b = RowBuilder::new(format!("cards:{i}:{line}"));
            for (c, col) in cols.iter().enumerate() {
                let Some(card) = col.get(i) else { continue };
                b.stop(c as u32 * w);
                let at = b.pos();
                let face = if line == 0 {
                    "drgnx-card-top"
                } else {
                    "drgnx-card-bottom"
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
            display: runstav::methods::view::Display::Gui,
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
        assert_eq!(keys, ["head", "cards:0:0", "cards:0:1"]);
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
}
