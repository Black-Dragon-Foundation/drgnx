//! The panel header's background work: the chip's pieces and the pinned list under the chips (GUI rows with
//! Output/Stop, a terminal's characters).  Keys: `bg:head`, `bg:ID` (an item's line), `bg:ID:1` (its last output line
//! and its actions), `bg:more`, `bg:chip` (a terminal's chip line).

use super::*;
use crate::view::bgwork as bg;
use drgnx_rows::kit::{self, Comp};
use drgnx_rows::kit_gen;
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

/// Fill the row to the window's right edge less PAD_PX (the card's ring ends where the row's text does: a row that stops
/// short leaves the ring's right edge in the middle of the card).
fn to_edge(b: &mut RowBuilder, cx: &Cx, pad_px: u32) {
    if cx.env.width_px > 0 {
        b.stop(cx.env.width_px.saturating_sub(pad_px));
    }
}

/// A kit face's name, none where the component has none (the surface's own).
fn kit_face(id: kit_gen::CompId, variant: &[&str]) -> Option<&'static str> {
    let f = kit_gen::face(id, variant);
    (f != FaceId::Default).then(|| f.name())
}

/// The width in device px of the head chip with TEXT: its pads, its icon and gap, its label.
pub(super) fn chip_width(cx: &Cx, text: &str, warn: bool) -> u32 {
    let tone = if warn { "warn" } else { "accent" };
    let v = [tone, "soft", cx.env.density.name()];
    let g = kit_gen::geom(kit_gen::CompId::Chip, &v);
    px(cx.env, f32::from(g.pad.0))
        + px(cx.env, f32::from(kit::ICON_PX))
        + px(cx.env, f32::from(g.gap))
        + text_width(cx, kit_face(kit_gen::CompId::Chip, &v), text)
        + px(cx.env, f32::from(g.pad.1))
}

/// The head chip, drawn by the kit as a soft pill with its spinner (a warning triangle while the agent cannot tell):
/// from its start to its end, `drgnx-agent-panel-action` `background-list`.
pub(super) fn draw_chip(
    b: &mut RowBuilder,
    cx: &Cx,
    images: &mut Vec<(ImageId, String)>,
    text: &str,
    warn: bool,
) {
    let found = std::cell::RefCell::new(Vec::new());
    let draw = |name: &str, size: u32| {
        icons::svg(name, size).map(|(id, svg)| {
            found.borrow_mut().push((id, svg));
            id
        })
    };
    let mut kenv = crate::view::kit_env(cx.env);
    kenv.icons = Some(kit::Icons(&draw));
    let from = b.pos();
    kit::expand(
        b,
        &kenv,
        &Comp::Chip {
            label: text.to_owned(),
            tone: if warn {
                kit::Tone::Warn
            } else {
                kit::Tone::Accent
            },
            fill: kit::ChipFill::Soft,
            icon: Some(
                if warn {
                    "circle-alert"
                } else {
                    "loader-circle"
                }
                .to_owned(),
            ),
            state: kit::State::Rest,
            action: None,
        },
    );
    let to = b.pos();
    images.extend(found.into_inner());
    b.prop(
        from,
        to,
        "drgnx-agent-panel-action",
        json!("background-list"),
    );
    b.prop(
        from,
        to,
        "help-echo",
        json!("Background work: fold or unfold the list (b)"),
    );
}

/// The width of a kit button (small, secondary) with LABEL and its key hint KEY, in device px.
fn button_width(cx: &Cx, label: &str, key: &str) -> u32 {
    let d = cx.env.density.name();
    let bv = ["secondary", "sm", d];
    let g = kit_gen::geom(kit_gen::CompId::Button, &bv);
    let kv = ["cap", d];
    let kg = kit_gen::geom(kit_gen::CompId::KeyHint, &kv);
    px(cx.env, f32::from(g.pad.0))
        + text_width(cx, kit_face(kit_gen::CompId::Button, &bv), label)
        + px(cx.env, f32::from(g.gap))
        + px(cx.env, f32::from(kg.pad.0))
        + text_width(cx, kit_face(kit_gen::CompId::KeyHint, &kv), key)
        + px(cx.env, f32::from(kg.pad.1))
        + px(cx.env, f32::from(g.pad.1))
}

/// A kit button LABEL with its key hint KEY, a click target `ACTION` (`drgnx-agent-panel-action`).
fn draw_button(b: &mut RowBuilder, cx: &Cx, label: &str, key: &str, action: &str) {
    let kenv = crate::view::kit_env(cx.env);
    let from = b.pos();
    kit::expand(
        b,
        &kenv,
        &Comp::Button {
            label: label.to_owned(),
            style: kit::ButtonStyle::Secondary,
            size: kit::Size::Sm,
            state: kit::State::Rest,
            key: Some(key.to_owned()),
            action: None,
        },
    );
    let to = b.pos();
    b.prop(from, to, "drgnx-agent-panel-action", json!(action));
}

fn gui(
    s: &Snapshot,
    cx: &Cx,
    items: &[&BackgroundItem],
    images: &mut Vec<(ImageId, String)>,
) -> Vec<Row> {
    let env = cx.env;
    let kenv = crate::view::kit_env(env);
    let (icon_px, p4, p8) = (px(env, 16.0), px(env, 4.0), px(env, 8.0));
    let n = bg::running(s);
    let folded = cx.open.contains(bg::FOLDED);
    let subtle = FaceId::AgentPanelSubtle.name();
    let mut out = Vec::new();

    // the head: chevron, title, count, and "Stop all" at the right while anything can be stopped
    let mut b = RowBuilder::new("bg:head");
    b.pad(p8, None);
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
    b.pad(p4, None);
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
            b.stop(env.width_px.saturating_sub(w + p8 + p8));
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
    to_edge(&mut b, cx, p8);
    b.pad(p8, None);
    out.push(b.finish());

    if !folded {
        for i in items.iter().take(bg::VISIBLE) {
            let selected = cx.bg_selected == Some(i.id.as_str());
            out.push(item_row(cx, i, selected, images));
            if i.end.is_none() && (selected || i.progress.is_some()) {
                out.push(second_row(cx, i, selected));
            }
        }
        if items.len() > bg::VISIBLE {
            let mut b = RowBuilder::new("bg:more");
            b.pad(p8, None);
            b.pad(icon_px + p4 + p4, None);
            b.push(
                &format!("and {} more", items.len() - bg::VISIBLE),
                Some(subtle),
            );
            let end = b.pos();
            b.prop(0, end, "drgnx-agent-panel-action", json!("background-more"));
            to_edge(&mut b, cx, p8);
            b.pad(p8, None);
            out.push(b.finish());
        }
    }
    // one card: its ring round every row, open between them
    kit::card_rows(&kenv, kit::CardKind::Plain, out)
}

/// An item's first line: its icon, its description and its elapsed time (or how it ended) at the right edge; the
/// selected one in the selection's tint and the focus ring, inset from the card's edge.
fn item_row(
    cx: &Cx,
    i: &BackgroundItem,
    selected: bool,
    images: &mut Vec<(ImageId, String)>,
) -> Row {
    let env = cx.env;
    let (icon_px, p4, p8) = (px(env, 16.0), px(env, 4.0), px(env, 8.0));
    let subtle = FaceId::AgentPanelSubtle.name();
    let ended = i.end.is_some();
    let (name, alt) = bg::kind_icon(i.kind);
    // no face of its own for a plain description: `default` would carry its own (no) box over the card's ring and cut
    // the ring into pieces at the run's ends
    let face: Option<&str> = if ended {
        Some(subtle)
    } else if i.kind == BackgroundKind::Terminal {
        Some(FaceId::AgentPanelCode.name())
    } else {
        None
    };
    let right = if ended {
        bg::end_word(i)
    } else {
        bg::elapsed(i.started_ms, cx.now)
    };
    let right_w = text_width(cx, Some(FaceId::AgentPanelCode.name()), &right);
    let lead = p8 + p4 + icon_px + p4;
    let room =
        i64::from(env.width_px) - i64::from(lead) - i64::from(right_w) - i64::from(p8 + p4 + p8);
    let mut b = RowBuilder::new(format!("bg:{}", i.id));
    b.pad(p4, None);
    let span = b.pos();
    b.pad(p4, None);
    icon(&mut b, images, name, alt, icon_px, subtle);
    b.pad(p4, None);
    b.push(&cut(cx, face, &i.description, room), face);
    if env.width_px > 0 {
        b.stop(env.width_px.saturating_sub(right_w + p8));
    } else {
        b.push(" ", None);
    }
    let from = b.pos();
    b.push(&right, Some(FaceId::AgentPanelCode.name()));
    let to = b.pos();
    if !ended {
        b.prop(from, to, "drgnx-bg-elapsed", json!(i.started_ms));
    }
    b.pad(p4, None);
    let span_end = b.pos();
    b.pad(p4, None);
    let end = b.pos();
    if selected {
        b.face(span, span_end, FaceId::Selected.name());
    }
    item_props(&mut b, i, end);
    b.finish()
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

/// An item's last output line (the code font, muted) and, on the selected row only, its actions as kit buttons with
/// their keys: Output ↵ (Open for a subagent), and Stop k only where the item can be stopped.
fn second_row(cx: &Cx, i: &BackgroundItem, selected: bool) -> Row {
    let env = cx.env;
    let (icon_px, p4, p8) = (px(env, 16.0), px(env, 4.0), px(env, 8.0));
    let out_face = FaceId::AgentPanelOutput.name();
    let open_word = if i.kind == BackgroundKind::Subagent {
        "Open"
    } else {
        "Output"
    };
    let mut acts: Vec<(&str, &str, String)> = Vec::new();
    if selected {
        acts.push((open_word, "↵", format!("background-output:{}", i.id)));
        if i.can_cancel {
            acts.push(("Stop", "k", format!("background-stop:{}", i.id)));
        }
    }
    let acts_w: u32 = acts
        .iter()
        .map(|(l, k, _)| button_width(cx, l, k))
        .sum::<u32>()
        + p4 * acts.len().saturating_sub(1) as u32;
    let lead = p8 + p4 + icon_px + p4;
    let room =
        i64::from(env.width_px) - i64::from(lead) - i64::from(acts_w) - i64::from(p8 + p4 + p8);
    let mut b = RowBuilder::new(format!("bg:{}:1", i.id));
    b.pad(p4, None);
    let span = b.pos();
    b.pad(p4, None);
    b.pad(icon_px + p4, None);
    if let Some(last) = i.progress.as_deref() {
        b.push(&cut(cx, Some(out_face), last, room), Some(out_face));
    }
    if !acts.is_empty() {
        if env.width_px > 0 {
            b.stop(env.width_px.saturating_sub(acts_w + p8));
        } else {
            b.push(" ", None);
        }
        for (n, (label, key, action)) in acts.iter().enumerate() {
            if n > 0 {
                b.pad(p4, None);
            }
            draw_button(&mut b, cx, label, key, action);
        }
    }
    to_edge(&mut b, cx, p8);
    b.pad(p4, None);
    let span_end = b.pos();
    b.pad(p4, None);
    let end = b.pos();
    if selected {
        b.face(span, span_end, FaceId::Selected.name());
    }
    // the code font under the whole line, pads included: a font change inside the row would end the card's ring segment
    // there (a stray vertical edge after the text)
    b.face(0, end, out_face);
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
