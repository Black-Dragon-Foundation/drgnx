//! The panel header's background work: the chip's pieces and the pinned list under the chips (GUI rows with
//! Output/Stop, a terminal's characters).  Keys: `bg:head`, `bg:ID` (an item's line), `bg:ID:1` (its last output line
//! and its actions), `bg:more`, `bg:chip` (a terminal's chip line).

use super::*;
use crate::view::bgwork as bg;
use runstav::methods::agents::{BackgroundItem, BackgroundKind};

/// The widest a terminal's row is when the env does not say.
const TTY_COLS: u32 = 80;

/// What the list draws: the running items as the agent lists them, then the ended ones still faded.
fn shown<'a>(s: &'a Snapshot, cx: &Cx) -> Vec<&'a BackgroundItem> {
    let mut out: Vec<&BackgroundItem> = bg::list(s).iter().filter(|i| i.end.is_none()).collect();
    for i in &s.background_ended {
        if cx
            .ended_at
            .get(&i.id)
            .is_some_and(|at| *at > 0.0 && cx.now - *at < bg::FADE_SECS)
            && !out.iter().any(|o| o.id == i.id)
        {
            out.push(i);
        }
    }
    out
}

/// How long an ended item ran, when the panel saw it end.
fn ran(i: &BackgroundItem, cx: &Cx) -> Option<f64> {
    cx.ended_at
        .get(&i.id)
        .filter(|at| **at > 0.0)
        .map(|at| (*at - i.started_ms as f64 / 1000.0).max(0.0))
}

/// The chip of the head row (a graphical panel): its text and whether it warns.
pub(super) fn head_chip(s: &Snapshot, cx: &Cx) -> Option<(String, bool)> {
    if cx.env.display == Display::Gui {
        bg::chip(s)
    } else {
        None
    }
}

/// The rows of the list (and a terminal's chip line); none when the agent reports no list or nothing is in it.
pub(super) fn rows(s: &Snapshot, cx: &Cx, images: &mut Vec<(ImageId, String)>) -> Vec<Row> {
    let items = shown(s, cx);
    if bg::list(s).is_empty() && items.is_empty() {
        return Vec::new();
    }
    match cx.env.display {
        Display::Gui => gui(s, cx, &items, images),
        Display::Tty => tty(s, cx, &items),
    }
}

/// TEXT fitted to PX in FACE (the room is unknown without a width: a fixed cut).
fn cut(cx: &Cx, face: Option<&str>, text: &str, px_room: i64) -> String {
    let line = bg::one_line(text, 200);
    if cx.env.width_px == 0 {
        return bg::one_line(&line, 60);
    }
    if px_room <= 0 {
        return String::new();
    }
    match cx.env.display {
        Display::Gui => fit::fit_in(cx.fonts, face, &line, px_room as f32),
        Display::Tty => line
            .chars()
            .take((px_room as u32 / cx.env.cell.0.max(1)) as usize)
            .collect(),
    }
}

fn gui(
    s: &Snapshot,
    cx: &Cx,
    items: &[&BackgroundItem],
    images: &mut Vec<(ImageId, String)>,
) -> Vec<Row> {
    let env = cx.env;
    let (icon_px, p4, p12) = (px(env, 16.0), px(env, 4.0), px(env, 12.0));
    let n = bg::running(s);
    let folded = cx.open.contains(bg::FOLDED);
    let subtle = FaceId::AgentPanelSubtle.name();
    let mut out = Vec::new();

    // the head: chevron, title, count, and "Stop all" at the right while anything can be stopped
    let mut b = RowBuilder::new("bg:head");
    b.push(" ", None);
    let from = b.pos();
    icon(
        &mut b,
        images,
        if folded {
            "chevron-right"
        } else {
            "chevron-down"
        },
        if folded { "▸" } else { "▾" },
        icon_px,
        subtle,
    );
    b.push(" ", None);
    b.push("In background", Some(FaceId::AgentPanelTitle.name()));
    b.push(&format!(" · {n}"), Some(subtle));
    let to = b.pos();
    b.prop(
        from,
        to,
        "drgnx-agent-panel-action",
        json!("background-list"),
    );
    b.prop(from, to, "help-echo", json!("Fold or unfold the list (b)"));
    if items.iter().any(|i| i.end.is_none() && i.can_cancel) {
        let label = "Stop all";
        let w = text_width(cx, Some(subtle), label);
        if env.width_px > 0 {
            b.stop(env.width_px.saturating_sub(w + p12));
        } else {
            b.push(" ", None);
        }
        let from = b.pos();
        b.push(label, Some(subtle));
        let to = b.pos();
        b.prop(
            from,
            to,
            "drgnx-agent-panel-action",
            json!("background-stop-all"),
        );
    }
    out.push(b.finish());
    if folded {
        return out;
    }

    for i in items.iter().take(bg::VISIBLE) {
        let ended = i.end.is_some();
        let (name, alt) = bg::kind_icon(i.kind);
        let face = if ended {
            subtle
        } else if i.kind == BackgroundKind::Terminal {
            FaceId::AgentPanelCode.name()
        } else {
            "default"
        };
        let right = if ended {
            bg::end_word(i)
        } else {
            bg::elapsed(i.started_ms, cx.now)
        };
        let right_w = text_width(cx, Some(FaceId::AgentPanelCode.name()), &right);
        let lead = icon_px + 3 * p4 + p12;
        let room =
            i64::from(env.width_px) - i64::from(lead) - i64::from(right_w) - i64::from(2 * p12);
        let mut b = RowBuilder::new(format!("bg:{}", i.id));
        b.push("  ", None);
        icon(&mut b, images, name, alt, icon_px, subtle);
        b.push(" ", None);
        b.push(
            &cut(cx, Some(face), &i.description, room),
            Some(if ended { subtle } else { face }),
        );
        if env.width_px > 0 {
            b.stop(env.width_px.saturating_sub(right_w + p12));
        } else {
            b.push(" ", None);
        }
        let from = b.pos();
        b.push(&right, Some(FaceId::AgentPanelCode.name()));
        let to = b.pos();
        if !ended {
            b.prop(from, to, "drgnx-bg-elapsed", json!(i.started_ms));
        }
        let end = b.pos();
        if cx.bg_selected == Some(i.id.as_str()) {
            b.face(0, end, FaceId::AgentPanelTagOn.name());
        }
        item_props(&mut b, i, end);
        out.push(b.finish());
        if ended {
            continue;
        }
        let selected = cx.bg_selected == Some(i.id.as_str());
        if selected || i.progress.is_some() {
            out.push(second_row(cx, i, selected));
        }
    }
    if items.len() > bg::VISIBLE {
        let mut b = RowBuilder::new("bg:more");
        let text = format!("    and {} more", items.len() - bg::VISIBLE);
        b.push(&text, Some(subtle));
        let end = b.pos();
        b.prop(0, end, "drgnx-agent-panel-action", json!("background-more"));
        out.push(b.finish());
    }
    out
}

fn item_props(b: &mut RowBuilder, i: &BackgroundItem, end: u32) {
    b.prop(0, end, "drgnx-bg-item", json!(i.id));
    b.prop(0, end, "drgnx-bg-kind", json!(bg::kind_str(i.kind)));
    b.prop(
        0,
        end,
        "drgnx-bg-can-cancel",
        json!(i.can_cancel && i.end.is_none()),
    );
}

/// An item's last output line (the code font, muted) and, on the selected row only, its actions: Output (Open for a
/// subagent), and Stop where the item can be stopped.
fn second_row(cx: &Cx, i: &BackgroundItem, selected: bool) -> Row {
    let env = cx.env;
    let (p12, p4) = (px(env, 12.0), px(env, 4.0));
    let out_face = FaceId::AgentPanelOutput.name();
    let link = FaceId::AgentPanelMdLink.name();
    let open_word = if i.kind == BackgroundKind::Subagent {
        "Open"
    } else {
        "Output"
    };
    let mut acts: Vec<(String, String)> = Vec::new();
    if selected {
        acts.push((open_word.to_owned(), format!("background-output:{}", i.id)));
        if i.can_cancel {
            acts.push(("Stop".to_owned(), format!("background-stop:{}", i.id)));
        }
    }
    let acts_w: u32 = if acts.is_empty() {
        0
    } else {
        acts.iter()
            .map(|(t, _)| text_width(cx, Some(link), t) + 2 * p4)
            .sum::<u32>()
            + p12
    };
    let indent = "      ";
    let room = i64::from(env.width_px)
        - i64::from(acts_w)
        - i64::from(text_width(cx, None, indent))
        - i64::from(2 * p12);
    let mut b = RowBuilder::new(format!("bg:{}:1", i.id));
    b.push(indent, None);
    if let Some(last) = i.progress.as_deref() {
        b.push(&cut(cx, Some(out_face), last, room), Some(out_face));
    }
    if !acts.is_empty() {
        if env.width_px > 0 {
            b.stop(env.width_px.saturating_sub(acts_w));
        } else {
            b.push(" ", None);
        }
        for (n, (text, action)) in acts.iter().enumerate() {
            if n > 0 {
                b.push("  ", None);
            }
            let from = b.pos();
            b.push(text, Some(link));
            let to = b.pos();
            b.prop(from, to, "drgnx-agent-panel-action", json!(action));
        }
    }
    let end = b.pos();
    item_props(&mut b, i, end);
    b.finish()
}

fn tty(s: &Snapshot, cx: &Cx, items: &[&BackgroundItem]) -> Vec<Row> {
    let cell = cx.env.cell.0.max(1);
    let cols = (if cx.env.width_px == 0 {
        TTY_COLS
    } else {
        // the last column is the terminal's own (the `$` of a cut line)
        (cx.env.width_px / cell).saturating_sub(1).max(8)
    }) as usize;
    let mut out = Vec::new();
    if let Some((text, warn)) = bg::chip(s) {
        let mut b = RowBuilder::new("bg:chip");
        let line: String = format!("⟳ {text} (b list, k stop, RET output)")
            .chars()
            .take(cols)
            .collect();
        b.push(
            &line,
            Some(if warn {
                FaceId::AgentPanelWarn.name()
            } else {
                FaceId::Accent.name()
            }),
        );
        out.push(b.finish());
    }
    for i in items.iter().take(bg::VISIBLE) {
        let ended = i.end.is_some();
        let (_, mark) = bg::kind_icon(i.kind);
        let right = if ended {
            let word = match i.end.as_ref().and_then(|e| e.exit_code) {
                Some(c) if bg::letter(i) == 'F' => format!("exit {c}"),
                _ => bg::end_word(i),
            };
            match ran(i, cx) {
                Some(secs) => format!("{word}  {}", bg::dur_text(secs)),
                None => word,
            }
        } else {
            bg::elapsed(i.started_ms, cx.now)
        };
        let lead = format!("{} {} ", bg::letter(i), mark);
        let room = cols.saturating_sub(lead.chars().count() + right.chars().count() + 1);
        let what: String = bg::one_line(&i.description, 200)
            .chars()
            .take(room)
            .collect();
        let used = lead.chars().count() + what.chars().count() + right.chars().count();
        let pad = " ".repeat(cols.saturating_sub(used).max(1));
        let mut b = RowBuilder::new(format!("bg:{}", i.id));
        b.push(
            &format!("{lead}{what}{pad}{right}"),
            if ended && bg::letter(i) == 'F' {
                Some(FaceId::AgentPanelFail.name())
            } else if ended {
                Some(FaceId::AgentPanelSubtle.name())
            } else {
                None
            },
        );
        let end = b.pos();
        if !ended {
            let at = end - right.chars().count() as u32;
            b.prop(at, end, "drgnx-bg-elapsed", json!(i.started_ms));
        }
        item_props(&mut b, i, end);
        out.push(b.finish());
        if let Some(last) = i.progress.as_deref().filter(|_| !ended) {
            let text: String = format!("    {}", bg::one_line(last, 200))
                .chars()
                .take(cols)
                .collect();
            let mut b = RowBuilder::new(format!("bg:{}:1", i.id));
            b.push(&text, Some(FaceId::AgentPanelSubtle.name()));
            let end = b.pos();
            item_props(&mut b, i, end);
            out.push(b.finish());
        }
    }
    if items.len() > bg::VISIBLE {
        let mut b = RowBuilder::new("bg:more");
        b.push(
            &format!("  and {} more", items.len() - bg::VISIBLE),
            Some(FaceId::AgentPanelSubtle.name()),
        );
        out.push(b.finish());
    }
    out
}
