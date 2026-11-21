//! The agent panel's cards under the chips, built in the hub (offload step F1): the pinned cards, the agent's to-do
//! list and the edits ledger.  A card is rows keyed `p:KIND:N`, each in the card faces (single, top, mid, bottom) to
//! the panel's right edge less 12 px, the card's text in its own face above them.  What is pinned and whether the
//! ledger is open are the editor's (`agents/panel/look`); the plan, the edits and the files come from the session.

use crate::agents::session::rows::one_line;
use drgnx_rows::faces::FaceId;
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::history::{HunkState, OpHunk};
use runstav::methods::view::ViewEnv;
use serde_json::{Value, json};

/// One ledger line of an edited file: its path and the lines added and removed.
#[derive(Clone, Debug, PartialEq)]
pub struct FileEdit {
    pub path: String,
    pub plus: u32,
    pub minus: u32,
}

/// What the cards read.
pub struct In<'a> {
    pub env: &'a ViewEnv,
    /// The pinned cards' texts, oldest first.
    pub pins: &'a [String],
    /// The latest plan's items (status, content), none when there is no plan.
    pub plan: Option<&'a [(String, String)]>,
    /// The files the session edited (a worktree chat).
    pub files: &'a [FileEdit],
    /// A paired chat's hunks (its edits in the user's checkout).
    pub paired: &'a [OpHunk],
    /// The indexes of the finished edits in the transcript, ascending.
    pub edits: &'a [usize],
    pub ledger_open: bool,
    /// The entry index when the ledger was last opened, none: never.
    pub ledger_mark: Option<i64>,
}

/// A card line: its text, the face the text has over the card's.
type Line = (String, Option<&'static str>, Vec<(&'static str, Value)>);

fn px(env: &ViewEnv, v: f32) -> u32 {
    let scale = if env.scale > 0.0 { env.scale } else { 1.0 };
    (f64::from(v) * f64::from(scale) + 0.5 + 1e-9).floor() as u32
}

/// LINES as one card, its rows keyed `p:KIND:0`, `p:KIND:1`, …; ROW_PROPS on each.
fn card(env: &ViewEnv, kind: &str, lines: Vec<Line>) -> Vec<Row> {
    let n = lines.len();
    lines
        .into_iter()
        .enumerate()
        .map(|(i, (text, face, props))| {
            let shape = if n == 1 {
                FaceId::CardSingle.name()
            } else if i == 0 {
                FaceId::CardTop.name()
            } else if i + 1 == n {
                FaceId::CardBottom.name()
            } else {
                FaceId::CardMid.name()
            };
            let mut b = RowBuilder::new(format!("p:{kind}:{i}"));
            b.push(" ", None);
            b.push(&text, face);
            // to the panel's right edge, 12 px in
            b.stop(env.width_px.saturating_sub(px(env, 12.0)));
            let end = b.pos();
            b.face(0, end, shape);
            for (name, value) in props {
                b.prop(0, end, name, value);
            }
            b.finish()
        })
        .collect()
}

/// The note on a paired hunk that was taken back: "", "undone by you" (a user operation reverted it) or "undone".
fn undone_note(h: &OpHunk) -> String {
    let word = match h.state {
        HunkState::Live => return String::new(),
        HunkState::Undone => "undone",
        HunkState::PartlyUndone => "partly undone",
    };
    let by_you = h.undone_by.iter().any(|u| {
        u.author
            .as_ref()
            .is_none_or(|a| a.get("kind").and_then(Value::as_str) == Some("user"))
    });
    if by_you {
        format!("  · {word} by you")
    } else {
        format!("  · {word}")
    }
}

/// The cards: the pins, the to-do list, the ledger, in this order.
pub fn rows(i: &In) -> Vec<Row> {
    let mut out = Vec::new();
    for (n, text) in i.pins.iter().enumerate() {
        out.extend(card(
            i.env,
            &format!("pin{n}"),
            vec![(
                format!("⚑ {}   (P unpin)", one_line(text, 80)),
                Some("bold"),
                vec![("drgnx-agent-panel-pin", json!(n))],
            )],
        ));
    }
    if let Some(items) = i.plan
        && !items.is_empty()
    {
        let done = items.iter().filter(|(s, _)| s == "completed").count();
        let mut lines: Vec<Line> = vec![(
            format!("To do · {done} of {} done", items.len()),
            Some("bold"),
            Vec::new(),
        )];
        for (status, content) in items {
            let mark = match status.as_str() {
                "completed" => "☑",
                "in_progress" => "◐",
                _ => "☐",
            };
            lines.push((
                format!("{mark} {}", one_line(content, 80)),
                None,
                Vec::new(),
            ));
        }
        out.extend(card(i.env, "todo", lines));
    }
    if !(i.files.is_empty() && i.paired.is_empty() && i.edits.is_empty()) {
        let new = i
            .edits
            .iter()
            .filter(|&&e| (e as i64) > i.ledger_mark.unwrap_or(-1))
            .count();
        let mut paths: Vec<&str> = if i.files.is_empty() {
            i.paired.iter().map(|h| h.path.as_str()).collect()
        } else {
            i.files.iter().map(|f| f.path.as_str()).collect()
        };
        paths.dedup();
        let mut seen = std::collections::BTreeSet::new();
        paths.retain(|p| seen.insert(*p));
        let files = paths.len();
        let head = format!(
            "Edits · {files} file{}{}   (L {})",
            if files == 1 { "" } else { "s" },
            if new > 0 {
                format!(" · {new} new since you looked")
            } else {
                String::new()
            },
            if i.ledger_open { "fold" } else { "list" }
        );
        let mut lines: Vec<Line> = vec![(
            head,
            Some(if new > 0 {
                FaceId::StatusAttention.name()
            } else {
                "bold"
            }),
            vec![("drgnx-agent-panel-action", json!("card:ledger"))],
        )];
        if i.ledger_open {
            if !i.paired.is_empty() {
                for h in i.paired {
                    lines.push((
                        format!(
                            "{}  {}–{}{}",
                            one_line(&h.path, 50),
                            h.start_line,
                            h.end_line,
                            undone_note(h)
                        ),
                        None,
                        vec![("drgnx-agent-panel-op-hunk", json!([h.op, h.path, h.index]))],
                    ));
                }
            } else {
                for f in i.files {
                    lines.push((
                        format!("{}  +{} −{}", one_line(&f.path, 60), f.plus, f.minus),
                        None,
                        Vec::new(),
                    ));
                }
            }
        }
        out.extend(card(i.env, "ledger", lines));
    }
    out
}

#[cfg(test)]
#[path = "panel_cards/tests.rs"]
mod tests;
