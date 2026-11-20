//! The agent panel's header and chips rows, built in the hub (offload step F): the agent's icon and name, what it is
//! doing (cut to the room the lens leaves), the lens of presets and the pin and ⋯ buttons, then the chips the snapshot
//! feeds.  Every clickable part carries `drgnx-agent-panel-action` (`lens:N`, `pin`, `more`) or
//! `drgnx-agent-panel-chip` (the chip's kind); the editor's one click dispatcher reads them.  An icon is a Lucide SVG
//! the hub holds (`icons::svg`), sized for the env's scale.

use super::icons;
use crate::agents::session::rows::STEP_TYPES;
use drgnx_rows::faces::FaceId;
use drgnx_rows::fit::{self, FontSet};
use drgnx_rows::kit::{Comp, Status};
use drgnx_rows::{ImageId, Row, RowBuilder};
use runstav::methods::agents::{SessionStatus, Snapshot};
use runstav::methods::view::{Display, ViewEnv};
use serde_json::{Value, json};
use std::collections::BTreeSet;

/// The keys of the rows (the editor places the rows whose key starts with `p:` above the panel's own).
pub const HEAD: &str = "p:head";
pub const CHIPS: &str = "p:chips";
pub const STRIP: &str = "p:strip";
/// The chain row (spec › plan › task) under the header, and the plan strip (a status dot and its word per item of the
/// agent's plan) between the chips and the step-type strip.
pub const CHAIN: &str = "p:chain";
pub const PLAN: &str = "p:plan";

/// One link of the chain the agent works under: a node of the Work graph (`spec`, `plan` or `task`), its id and its
/// label.  A click selects it in Work (`select:KIND:ID`).
#[derive(Clone, Debug, PartialEq)]
pub struct ChainLink {
    pub kind: String,
    pub id: String,
    pub label: String,
}

/// What the editor chose for the lens: the presets' names and the one in force (1-based), none in force: 0.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Lens {
    pub names: Vec<String>,
    pub on: u32,
}

/// What the rows read besides the snapshot.
pub struct Cx<'a> {
    pub env: &'a ViewEnv,
    pub fonts: &'a FontSet,
    pub lens: &'a Lens,
    /// The step types whose detail is open (the strip's raised pills).
    pub open: &'a BTreeSet<String>,
    /// When the session began running (seconds since the epoch), none when it is not; and now.
    pub busy_since: Option<f64>,
    pub now: f64,
    /// How many files the session edited, and how many of its steps hold a checkpoint, when the hub knows.
    pub files_edited: Option<usize>,
    pub checkpoints: Option<usize>,
    /// The chain the agent works under, outermost first (none: no row).
    pub chain: &'a [ChainLink],
    /// The agent's plan as (status, content) items (none: no plan strip).
    pub plan: &'a [(String, String)],
    /// The spend and the limit of the scope that holds the agent, in dollars (none: no limit; the cost chip is the plain
    /// spend).
    pub budget: Option<(f64, f64)>,
}

/// What the agent is doing, for the header: "Claude · running 6 min", "held by you", "Pair · editing your checkout".
pub fn status_line(s: &Snapshot, busy_since: Option<f64>, now: f64) -> String {
    let who = s.profile.as_deref().unwrap_or("Agent");
    let paired = s.paired == Some(true);
    let paused = s.paused == Some(true);
    let what = if paused {
        "held by you".to_owned()
    } else if paired {
        "Pair · editing your checkout".to_owned()
    } else {
        match s.status {
            Some(SessionStatus::Busy) => busy_since.map_or("running".to_owned(), |t| {
                format!("running {} min", (((now - t) / 60.0).round() as i64).max(1))
            }),
            Some(SessionStatus::Exited) => "ended".to_owned(),
            Some(SessionStatus::Idle) => "idle".to_owned(),
            Some(other) => status_word(&other),
            None => "idle".to_owned(),
        }
    };
    if paired && !paused {
        what
    } else {
        format!("{who} · {what}")
    }
}

fn status_word(s: &SessionStatus) -> String {
    serde_json::to_value(s)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default()
}

/// The header and chips rows of S, and the images they hold.
pub fn rows(s: &Snapshot, cx: &Cx) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let mut images = Vec::new();
    let head = header(s, cx, &mut images);
    let mut rows = vec![head];
    rows.extend(chain(cx));
    rows.extend(chips(s, cx));
    rows.extend(plan_strip(cx));
    rows.extend(strip(cx));
    (rows, images)
}

fn px(env: &ViewEnv, v: f32) -> u32 {
    let scale = if env.scale > 0.0 { env.scale } else { 1.0 };
    (f64::from(v) * f64::from(scale) + 0.5 + 1e-9).floor() as u32
}

/// TEXT's width drawn in FACE (none: the panel's default), in the font the editor says FACE draws in.
fn text_width(cx: &Cx, face: Option<&str>, text: &str) -> u32 {
    match cx.env.display {
        Display::Gui => fit::width_in(cx.fonts, face, text).ceil() as u32,
        Display::Tty => text.chars().count() as u32 * cx.env.cell.0.max(1),
    }
}

/// One icon: its image (the SVG goes with the row) or, on a terminal, its alternative.
fn icon(
    b: &mut RowBuilder,
    images: &mut Vec<(ImageId, String)>,
    name: &str,
    alt: &str,
    size: u32,
    face: &str,
) {
    let start = b.pos();
    match icons::svg(name, size) {
        Some((id, svg)) => {
            images.push((id, svg));
            b.image(id, alt);
        }
        None => {
            b.push(alt, None);
        }
    }
    let end = b.pos();
    b.face(start, end, face);
}

fn header(s: &Snapshot, cx: &Cx, images: &mut Vec<(ImageId, String)>) -> Row {
    let env = cx.env;
    let gui = env.display == Display::Gui;
    let (icon_px, p4, p6, p8, p2) = (
        px(env, 16.0),
        px(env, 4.0),
        px(env, 6.0),
        px(env, 8.0),
        px(env, 2.0),
    );
    let name = s.name.as_deref().unwrap_or("agent");
    let cell = env.cell.0.max(1);
    let mut b = RowBuilder::new(HEAD);

    // the buttons and the lens, laid from the right edge: their width first, so the status takes what is left
    let mut lens_w = 0;
    for (n, p) in cx.lens.names.iter().enumerate() {
        let face = if cx.lens.on == n as u32 + 1 {
            FaceId::AgentPanelLensOn.name()
        } else {
            FaceId::AgentPanelLens.name()
        };
        let name_w = text_width(cx, Some(face), p);
        lens_w += if gui {
            p8 * 2 + name_w
        } else {
            name_w + 2 * cell
        };
        if n > 0 {
            lens_w += if gui { p2 } else { cell };
        }
    }
    let button_w = if gui { p4 * 2 + icon_px } else { 3 * cell };
    let gap_w = if gui { p6 } else { cell };
    let buttons_w = 2 * (gap_w + button_w);
    let right_w = lens_w + buttons_w;

    // the head: " " icon " " name
    b.push(" ", None);
    icon(&mut b, images, "bot", "@", icon_px, FaceId::Accent.name());
    b.push(" ", None);
    let t = b.pos();
    b.push(name, Some(FaceId::AgentPanelTitle.name()));
    let end = b.pos();
    b.prop(t, end, "drgnx-work-id", json!("p:head"));
    let head_w = text_width(cx, None, " ")
        + text_width(cx, Some(FaceId::AgentPanelTitle.name()), name)
        + if gui { icon_px + p4 } else { 2 * cell };

    // what the agent does, cut to the room: 12 px before the right part, which sits 8 px from the edge
    let status = format!(" · {}", status_line(s, cx.busy_since, cx.now));
    let room =
        i64::from(env.width_px) - i64::from(head_w) - i64::from(right_w) - i64::from(px(env, 20.0));
    let status = if env.width_px == 0 {
        status
    } else if room <= 0 {
        String::new()
    } else {
        match env.display {
            Display::Gui => fit::fit_in(
                cx.fonts,
                Some(FaceId::AgentPanelSubtle.name()),
                &status,
                room as f32,
            ),
            Display::Tty => status.chars().take((room as u32 / cell) as usize).collect(),
        }
    };
    b.push(&status, Some(FaceId::AgentPanelSubtle.name()));

    // the right part starts at its stop
    let stop = env.width_px.saturating_sub(right_w + p8);
    b.stop(stop);
    for (n, p) in cx.lens.names.iter().enumerate() {
        if n > 0 {
            if gui {
                b.space(p2, 1, FaceId::SurfaceGap.name());
            } else {
                b.push(" ", Some(FaceId::SurfaceGap.name()));
            }
        }
        let start = b.pos();
        let face = if cx.lens.on == n as u32 + 1 {
            FaceId::AgentPanelLensOn.name()
        } else {
            FaceId::AgentPanelLens.name()
        };
        if gui {
            b.space(p8, 1, face);
        } else {
            b.push(" ", Some(face));
        }
        b.push(p, Some(face));
        if gui {
            b.space(p8, 1, face);
        } else {
            b.push(" ", Some(face));
        }
        let end = b.pos();
        b.prop(
            start,
            end,
            "drgnx-agent-panel-action",
            json!(format!("lens:{}", n + 1)),
        );
        b.prop(start, end, "help-echo", json!(format!("{}: {p}", n + 1)));
    }
    for (name, alt, action, help) in [
        ("pin", "^", "pin", "Pin the card at point"),
        ("ellipsis", "…", "more", "More actions"),
    ] {
        if gui {
            b.space(p6, 1, "default");
        } else {
            b.push(" ", None);
        }
        let start = b.pos();
        if gui {
            b.space(p4, 1, "default");
        } else {
            b.push(" ", None);
        }
        icon(
            &mut b,
            images,
            name,
            alt,
            icon_px,
            FaceId::AgentPanelSubtle.name(),
        );
        if gui {
            b.space(p4, 1, "default");
        } else {
            b.push(" ", None);
        }
        let end = b.pos();
        b.prop(start, end, "drgnx-agent-panel-action", json!(action));
        b.prop(start, end, "help-echo", json!(help));
    }
    b.finish()
}

/// The disclosure strip (agent-panel.html `.disc`): "Expand steps:" and a pill for each step type, the open ones raised, a click
/// flips one (`type:NAME`); "make default" at the right end of the line it fits on (`default`).  The pills go on as many
/// rows as the width needs, the later ones indented under the first pill.
fn strip(cx: &Cx) -> Vec<Row> {
    let env = cx.env;
    let gui = env.display == Display::Gui;
    let cell = env.cell.0.max(1);
    let open = " Expand steps: ";
    let default = "make default";
    let width = |face: &str, t: &str| text_width(cx, Some(face), t);
    let room = i64::from(env.width_px) - i64::from(px(env, 12.0));
    let indent_px = width(FaceId::AgentPanelSubtle.name(), open);
    // the parts, each a (text, face, action)
    let mut parts: Vec<(String, &str, String)> = STEP_TYPES
        .iter()
        .map(|t| {
            (
                format!(" {t} "),
                if cx.open.contains(*t) {
                    FaceId::AgentPanelTagOn.name()
                } else {
                    FaceId::AgentPanelTag.name()
                },
                format!("type:{t}"),
            )
        })
        .collect();
    parts.push((
        default.to_owned(),
        FaceId::Accent.name(),
        "default".to_owned(),
    ));
    let mut lines: Vec<Vec<(String, &str, String)>> = vec![Vec::new()];
    let mut line_w = i64::from(indent_px);
    for part in parts {
        let w = i64::from(width(part.1, &part.0)) + i64::from(text_width(cx, None, " "));
        let first = lines.last().is_some_and(Vec::is_empty);
        if !first && env.width_px > 0 && line_w + w > room {
            lines.push(Vec::new());
            line_w = i64::from(indent_px);
        }
        line_w += w;
        if let Some(l) = lines.last_mut() {
            l.push(part);
        }
    }
    let mut rows = Vec::new();
    for (n, l) in lines.iter().enumerate() {
        let key = if n == 0 {
            STRIP.to_owned()
        } else {
            format!("{STRIP}:{n}")
        };
        let mut b = RowBuilder::new(key);
        if n == 0 {
            b.push(open, Some(FaceId::AgentPanelSubtle.name()));
        } else if gui {
            b.space(indent_px, 1, "default");
        } else {
            b.push(&" ".repeat((indent_px / cell) as usize), None);
        }
        for (i, (text, face, action)) in l.iter().enumerate() {
            if action == "default" {
                // at the right end of the line it fits on
                let stop = env
                    .width_px
                    .saturating_sub(width(face, text) + px(env, 12.0));
                if env.width_px > 0 {
                    b.stop(stop);
                } else {
                    b.push(" ", None);
                }
            } else if i > 0 {
                b.push(" ", None);
            }
            let start = b.pos();
            b.push(text, Some(face));
            let end = b.pos();
            b.prop(start, end, "drgnx-agent-panel-action", json!(action));
            if action == "default" {
                b.prop(
                    start,
                    end,
                    "help-echo",
                    json!("M: what is open now is what new panels open"),
                );
            } else if let Some(t) = action.strip_prefix("type:") {
                b.prop(
                    start,
                    end,
                    "help-echo",
                    json!(format!(
                        "Click to expand or collapse the detail of every {t} step"
                    )),
                );
            }
        }
        rows.push(b.finish());
    }
    rows
}

/// The chips the snapshot feeds (the context the agent has used, what the session cost, its mode), none when it
/// feeds none, in as many rows as the panel's width asks: the first row is `CHIPS`, the next ones `p:chips:1`, ….
/// The chain as one row of chips joined by `›`; each chip selects its node in Work.
fn chain(cx: &Cx) -> Option<Row> {
    if cx.chain.is_empty() {
        return None;
    }
    let mut b = RowBuilder::new(CHAIN);
    b.push(" ", None);
    for (i, link) in cx.chain.iter().enumerate() {
        if i > 0 {
            b.push(" › ", Some(FaceId::AgentPanelSubtle.name()));
        }
        let start = b.pos();
        b.push(
            &format!(" {} ", link.label),
            Some(FaceId::AgentPanelChip.name()),
        );
        let end = b.pos();
        b.prop(
            start,
            end,
            FaceId::AgentPanelChip.name(),
            json!(format!("select:{}:{}", link.kind, link.id)),
        );
    }
    Some(b.finish())
}

/// The plan as one row: a kit status dot and the item's words, for each item of the agent's plan.
fn plan_strip(cx: &Cx) -> Option<Row> {
    if cx.plan.is_empty() {
        return None;
    }
    let kit = super::kit_env(cx.env);
    let mut b = RowBuilder::new(PLAN);
    b.push(" ", None);
    for (i, (status, content)) in cx.plan.iter().enumerate() {
        if i > 0 {
            b.push("  ", None);
        }
        let status = match status.as_str() {
            "completed" => Status::Done,
            "in_progress" => Status::Running,
            _ => Status::Idle,
        };
        drgnx_rows::kit::expand(
            &mut b,
            &kit,
            &Comp::StatusDot {
                status,
                word: false,
            },
        );
        let word: String = content.chars().take(28).collect();
        b.push(&format!(" {word}"), None);
    }
    Some(b.finish())
}

/// A limit in dollars as the chip says it: "$5" for a whole amount, "$5.50" otherwise.
fn dollars(x: f64) -> String {
    if (x - x.round()).abs() < 0.005 {
        format!("${}", x.round() as i64)
    } else {
        format!("${x:.2}")
    }
}

/// The worktree the agent works in, for its chip: the name under `.claude/worktrees/`, else the folder's own name.
fn worktree_of(cwd: &str) -> Option<String> {
    let parts: Vec<&str> = cwd.split('/').filter(|p| !p.is_empty()).collect();
    match parts.iter().position(|p| *p == "worktrees") {
        Some(i) if i > 0 && parts[i - 1] == ".claude" && parts.get(i + 1).is_some() => {
            Some(parts[i + 1].to_owned())
        }
        _ => parts.last().map(|p| (*p).to_owned()),
    }
}

fn chips(s: &Snapshot, cx: &Cx) -> Vec<Row> {
    // (what a click explains, or none; text)
    let mut list: Vec<(Option<&str>, String)> = Vec::new();
    if let Some(m) = s.model.as_deref().filter(|m| !m.is_empty()) {
        list.push((Some("model"), m.to_owned()));
    }
    if let Some(w) = s.cwd.as_deref().and_then(worktree_of) {
        list.push((None, w));
    }
    if let Some(u) = &s.usage {
        if let (Some(used), Some(size)) = (u.used, u.size)
            && size > 0.0
        {
            let p = (100.0 * used / size).round() as i64;
            let glyph = match p {
                ..=12 => "○",
                13..=37 => "◔",
                38..=62 => "◑",
                63..=87 => "◕",
                _ => "●",
            };
            list.push((Some("context"), format!("{glyph} {p}%")));
        }
        let amount = match &u.cost {
            Some(Value::Number(n)) => n.as_f64(),
            Some(Value::Object(o)) => o.get("amount").and_then(Value::as_f64),
            _ => None,
        };
        match (amount, cx.budget) {
            (_, Some((spent, limit))) => {
                list.push((Some("cost"), format!("${spent:.2} / {}", dollars(limit))));
            }
            (Some(c), None) => list.push((Some("cost"), format!("${c:.2}"))),
            (None, None) => {}
        }
    }
    if let Some(m) = &s.mode {
        let text = serde_json::to_value(m)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default();
        if !text.is_empty() {
            list.push((Some("mode"), text));
        }
    }
    match s.enforced {
        Some(true) => list.push((None, "sandboxed".to_owned())),
        Some(false) => list.push((None, "not enforced".to_owned())),
        None => {}
    }
    if !s.mcp.is_empty() {
        list.push((Some("mcp"), format!("MCP {}", s.mcp.len())));
    }
    if let Some(n) = cx.files_edited.filter(|&n| n > 0) {
        list.push((None, format!("{n} file{}", if n == 1 { "" } else { "s" })));
    }
    if let Some(n) = cx.checkpoints.filter(|&n| n > 0) {
        list.push((
            None,
            format!("{n} checkpoint{}", if n == 1 { "" } else { "s" }),
        ));
    }
    let room = cx.env.width_px.saturating_sub(px(cx.env, 12.0));
    let gap = text_width(cx, None, " ");
    let mut out = Vec::new();
    let mut b = RowBuilder::new(CHIPS);
    b.push(" ", None);
    let mut used = gap;
    for (kind, text) in &list {
        let label = format!(" {text} ");
        let w = text_width(cx, Some(FaceId::AgentPanelChip.name()), &label);
        if used > gap && used + w > room {
            out.push(b.finish());
            b = RowBuilder::new(format!("{CHIPS}:{}", out.len()));
            b.push(" ", None);
            used = gap;
        } else if used > gap {
            b.push(" ", None);
            used += gap;
        }
        let start = b.pos();
        b.push(&label, Some(FaceId::AgentPanelChip.name()));
        let end = b.pos();
        if let Some(kind) = kind {
            b.prop(start, end, FaceId::AgentPanelChip.name(), json!(kind));
        }
        used += w;
    }
    if used > gap {
        out.push(b.finish());
    }
    out
}

#[cfg(test)]
#[path = "panel_top/tests.rs"]
mod tests;
