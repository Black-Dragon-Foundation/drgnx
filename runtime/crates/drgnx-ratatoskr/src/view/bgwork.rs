//! A chat's background work as the panel draws it: the texts of the chip, the list's rows and the lines of the
//! transcript that tell an item ended.  The data is the snapshot's `background` and `background_ended`
//! (`runstav::methods::agents::BackgroundItem`); nothing is shown as done or failed that the agent did not report.

use drgnx_rows::faces::FaceId;
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::agents::{
    BackgroundEndStatus, BackgroundItem, BackgroundKind, BackgroundStatus, Snapshot,
};
use serde_json::json;

/// How long an ended item stays faded in the pinned list (seconds since the panel first saw it end): the moment its
/// line reaches the transcript.
pub const FADE_SECS: f64 = 6.0;
/// The most items the pinned list draws; the rest are "and N more".
pub const VISIBLE: usize = 6;
/// In the panel's open set (the look the editor sends): the pinned list is folded.
pub const FOLDED: &str = "bg-folded";

/// An item that ended, and how long it ran (none: not known yet).
pub struct Ended<'a> {
    pub item: &'a BackgroundItem,
    pub secs: Option<f64>,
}

/// The items the agent reports (none when it reports no list: a v1 agent).
pub fn list(s: &Snapshot) -> &[BackgroundItem] {
    s.background.as_deref().unwrap_or(&[])
}

/// Whether ITEM runs as far as anyone knows: not ended, and the agent said so (`unknown` is never counted).
pub fn is_running(i: &BackgroundItem) -> bool {
    i.end.is_none() && i.status != BackgroundStatus::Unknown
}

pub fn running(s: &Snapshot) -> usize {
    list(s).iter().filter(|i| is_running(i)).count()
}

/// The chip's text and whether it is the warning one: none when nothing is listed or nothing runs.
pub fn chip(s: &Snapshot) -> Option<(String, bool)> {
    let items = list(s);
    let unknown = items
        .iter()
        .filter(|i| i.end.is_none() && i.status == BackgroundStatus::Unknown)
        .count();
    if unknown > 0 {
        return Some((format!("{} · state unknown", items.len()), true));
    }
    match running(s) {
        0 => None,
        n => Some((format!("{n} in background"), false)),
    }
}

/// `m:ss` since STARTED_MS, at NOW seconds (since the epoch).
pub fn elapsed(started_ms: u64, now: f64) -> String {
    elapsed_ms(started_ms, (now * 1000.0).max(0.0) as u64)
}

/// `m:ss` from STARTED_MS to NOW_MS.
pub fn elapsed_ms(started_ms: u64, now_ms: u64) -> String {
    let secs = now_ms.saturating_sub(started_ms) / 1000;
    format!("{}:{:02}", secs / 60, secs % 60)
}

/// A span of SECS as the end lines say it: "30 s", "4 min".
pub fn dur_text(secs: f64) -> String {
    if secs < 60.0 {
        format!("{} s", secs.round() as i64)
    } else {
        format!("{} min", (secs / 60.0).round() as i64)
    }
}

pub fn kind_str(k: BackgroundKind) -> &'static str {
    match k {
        BackgroundKind::Terminal => "terminal",
        BackgroundKind::ToolCall => "tool_call",
        BackgroundKind::Subagent => "subagent",
    }
}

/// The kind's Lucide icon, and its mark where there are no images.
pub fn kind_icon(k: BackgroundKind) -> (&'static str, &'static str) {
    match k {
        BackgroundKind::Terminal => ("terminal", "$"),
        BackgroundKind::ToolCall => ("eye", "◉"),
        BackgroundKind::Subagent => ("bot", "@"),
    }
}

/// The status letter of a terminal row: R running, F failed, D done, S stopped, ? unknown.
pub fn letter(i: &BackgroundItem) -> char {
    match i.end.as_ref().map(|e| e.status) {
        Some(BackgroundEndStatus::Failed) => 'F',
        Some(BackgroundEndStatus::Completed) => 'D',
        Some(BackgroundEndStatus::Stopped) => 'S',
        None if i.status == BackgroundStatus::Unknown => '?',
        None => 'R',
    }
}

/// What an ended item's row says in place of the elapsed time: "failed · exit 101", "finished", "stopped".
pub fn end_word(i: &BackgroundItem) -> String {
    let Some(e) = &i.end else {
        return String::new();
    };
    let word = match e.status {
        BackgroundEndStatus::Completed => "finished",
        BackgroundEndStatus::Failed => "failed",
        BackgroundEndStatus::Stopped => "stopped",
    };
    match (e.status, e.exit_code) {
        (BackgroundEndStatus::Failed, Some(c)) => format!("{word} · exit {c}"),
        _ => word.to_owned(),
    }
}

/// The first non-empty line of TEXT, cut to WIDTH characters with an ellipsis.
pub fn one_line(text: &str, width: usize) -> String {
    crate::agents::session::rows::one_line(text, width)
}

/// The transcript's line for an ended item, as text: "Background command `CMD` failed (exit 3) · 4 min".
pub fn end_text(i: &BackgroundItem, secs: Option<f64>) -> String {
    let what = one_line(&i.description, 80);
    let (word, exit) = match &i.end {
        Some(e) => (
            match e.status {
                BackgroundEndStatus::Completed => "finished",
                BackgroundEndStatus::Failed => "failed",
                BackgroundEndStatus::Stopped => "stopped",
            },
            e.exit_code,
        ),
        None => ("ended", None),
    };
    let mut t = match i.kind {
        BackgroundKind::Terminal => format!("Background command `{what}` {word}"),
        BackgroundKind::ToolCall => format!("Background task {what} {word}"),
        BackgroundKind::Subagent => format!("Subagent {what} {word}"),
    };
    if let Some(c) = exit {
        t.push_str(&format!(" (exit {c})"));
    }
    if i.kind == BackgroundKind::Subagent
        && let Some(sum) = i.end.as_ref().and_then(|e| e.summary.as_deref())
        && !sum.is_empty()
    {
        t.push_str(&format!(" · {}", one_line(sum, 60)));
    }
    if let Some(s) = secs {
        t.push_str(&format!(" · {}", dur_text(s)));
    }
    t
}

/// What the end line is fitted to: the panel's env and the fonts its faces draw in (none: the plain text row).
pub struct EndFit<'a> {
    pub env: &'a runstav::methods::view::ViewEnv,
    pub fonts: &'a drgnx_rows::fit::FontSet,
}

/// The transcript's line for an ended item: one event row, keyed `bg-end:ID`, with its Output (Open for a subagent)
/// link.  With FIT it is the mockup's event card: a status icon, the text with its command cut in the middle to the
/// room, and the link at the right edge, never dropped; without it, the plain text and the link.
pub fn end_rows(e: &Ended, fit: Option<EndFit>) -> (Vec<Row>, Vec<(drgnx_rows::ImageId, String)>) {
    let i = e.item;
    let link = if i.kind == BackgroundKind::Subagent {
        "Open"
    } else {
        "Output"
    };
    let failed = i
        .end
        .as_ref()
        .is_some_and(|x| x.status == BackgroundEndStatus::Failed);
    let text_face = if failed {
        FaceId::AgentPanelFail.name()
    } else {
        FaceId::AgentPanelSubtle.name()
    };
    let action = json!(format!("background-output:{}", i.id));
    let mut b = RowBuilder::new(format!("bg-end:{}", i.id));
    let mut images = Vec::new();
    let Some(fit) = fit.filter(|f| f.env.display == runstav::methods::view::Display::Gui) else {
        b.push(&end_text(i, e.secs), Some(text_face));
        b.push("  ", None);
        let from = b.pos();
        b.push(link, Some(FaceId::AgentPanelMdLink.name()));
        let to = b.pos();
        b.prop(from, to, "drgnx-agent-panel-action", action);
        b.prop(0, to, "drgnx-bg-item", json!(i.id));
        return (vec![b.finish()], images);
    };
    let env = fit.env;
    let scale = if env.scale > 0.0 { env.scale } else { 1.0 };
    let px = |v: f32| (f64::from(v) * f64::from(scale) + 0.5 + 1e-9).floor() as u32;
    let w = |face: &str, t: &str| drgnx_rows::fit::width_in(fit.fonts, Some(face), t).ceil() as u32;
    let (p4, p8, p12, icon_px) = (px(4.0), px(8.0), px(12.0), px(16.0));
    // the text round the command is fixed; the command takes what is left
    let full = end_text(i, e.secs);
    let what = one_line(&i.description, 80);
    let (mut pre, post) = match full.split_once(&what) {
        Some((a, z)) if i.kind == BackgroundKind::Terminal => (a.to_owned(), z.to_owned()),
        _ => (full.clone(), String::new()),
    };
    let fixed = p8 + p4 + icon_px + p4 + w(FaceId::AgentPanelMdLink.name(), link) + p12 + p8;
    let room_for = |pre: &str| {
        i64::from(env.width_px)
            - i64::from(fixed)
            - i64::from(w(text_face, pre))
            - i64::from(w(text_face, &post))
    };
    // the command keeps a few characters at least: below that the words before it go, never the status or the link
    if !post.is_empty() && room_for(&pre) < i64::from(6 * w(FaceId::AgentPanelCode.name(), "…")) {
        pre = "`".to_owned();
    }
    let room = room_for(&pre);
    let code = FaceId::AgentPanelCode.name();
    b.pad(p8, None);
    let (name, alt) = if failed {
        ("circle-x", "x")
    } else {
        ("circle-check", "ok")
    };
    if let Some((id, svg)) = super::icons::svg(name, icon_px) {
        images.push((id, svg));
        let from = b.pos();
        b.image(id, alt);
        let to = b.pos();
        b.face(from, to, text_face);
    }
    b.pad(p4, None);
    if post.is_empty() && pre == full {
        // not a command: the whole text is fitted
        let room = i64::from(env.width_px) - i64::from(fixed);
        b.push(
            &if env.width_px == 0 || room <= 0 {
                full.clone()
            } else {
                drgnx_rows::fit::fit_in(fit.fonts, Some(text_face), &full, room as f32)
            },
            Some(text_face),
        );
    } else {
        b.push(&pre, Some(text_face));
        let cut = if env.width_px == 0 {
            what.clone()
        } else if room <= 0 {
            String::new()
        } else {
            drgnx_rows::fit::fit_in(fit.fonts, Some(code), &what, room as f32)
        };
        b.push(&cut, Some(code));
        b.push(&post, Some(text_face));
    }
    let lw = w(FaceId::AgentPanelMdLink.name(), link);
    if env.width_px > 0 {
        b.stop(env.width_px.saturating_sub(lw + p8 + p8));
    } else {
        b.push(" ", None);
    }
    let from = b.pos();
    b.push(link, Some(FaceId::AgentPanelMdLink.name()));
    let to = b.pos();
    b.prop(from, to, "drgnx-agent-panel-action", action);
    b.pad(p8, None);
    let end = b.pos();
    b.prop(0, end, "drgnx-bg-item", json!(i.id));
    let mut row = b.finish();
    // a zero-high stretch ends the box run of the card's ring (see `panel_top::background::unstretch`)
    for s in &mut row.spaces {
        if s.2 == 0 {
            s.2 = 1;
        }
    }
    let rows = drgnx_rows::kit::card_rows(
        &super::kit_env(env),
        drgnx_rows::kit::CardKind::Plain,
        vec![row],
    );
    (rows, images)
}

/// The tag row before a turn the agent started by itself after an item ended: "after: DESCRIPTION".
pub fn after_rows(c: &runstav::methods::agents::BackgroundCause) -> Vec<Row> {
    let mut b = RowBuilder::new(format!("bg-after:{}", c.entry));
    b.push(
        &format!("after: {}", one_line(&c.description, 80)),
        Some(FaceId::AgentPanelTag.name()),
    );
    vec![b.finish()]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ended(kind: &str, what: &str, end: serde_json::Value) -> BackgroundItem {
        serde_json::from_value(json!({
            "kind": kind, "id": "x1", "description": what, "started_ms": 0, "status": "running",
            "can_cancel": false, "end": end
        }))
        .expect("an item")
    }

    fn text(i: &BackgroundItem, secs: Option<f64>) -> String {
        end_rows(&Ended { item: i, secs }, None)
            .0
            .first()
            .map(|r| r.text.clone())
            .unwrap_or_default()
    }

    #[test]
    fn bg_end_line_texts() {
        let failed = ended(
            "terminal",
            "cargo test -p hermod",
            json!({"status": "failed", "exit_code": 101}),
        );
        assert_eq!(
            text(&failed, Some(240.0)),
            "Background command `cargo test -p hermod` failed (exit 101) · 4 min  Output"
        );
        let done = ended("terminal", "cargo build", json!({"status": "completed"}));
        assert_eq!(
            text(&done, Some(95.0)),
            "Background command `cargo build` finished · 2 min  Output"
        );
        let stopped = ended("terminal", "sleep 600", json!({"status": "stopped"}));
        assert_eq!(
            text(&stopped, Some(30.0)),
            "Background command `sleep 600` stopped · 30 s  Output"
        );
        // no end time yet: no duration
        assert_eq!(
            text(&done, None),
            "Background command `cargo build` finished  Output"
        );
        let sub = ended(
            "subagent",
            "review the v2 diff",
            json!({"status": "completed", "summary": "14 tool uses"}),
        );
        assert_eq!(
            text(&sub, Some(180.0)),
            "Subagent review the v2 diff finished · 14 tool uses · 3 min  Open"
        );
        let subfail = ended("subagent", "review", json!({"status": "failed"}));
        assert_eq!(
            text(&subfail, Some(60.0)),
            "Subagent review failed · 1 min  Open"
        );
        let watch = ended("tool_call", "Watching CI", json!({"status": "completed"}));
        assert_eq!(
            text(&watch, Some(61.0)),
            "Background task Watching CI finished · 1 min  Output"
        );
    }

    #[test]
    fn after_tag_on_caused_turn() {
        let c = runstav::methods::agents::BackgroundCause {
            entry: 12,
            item: "t1".into(),
            description: "cargo test -p hermod".into(),
        };
        let rows = after_rows(&c);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].text, "after: cargo test -p hermod");
        assert_eq!(rows[0].key, "bg-after:12");
    }

    #[test]
    fn bg_end_line_links_to_the_item() {
        let failed = ended(
            "terminal",
            "cargo test",
            json!({"status": "failed", "exit_code": 3}),
        );
        let rows = end_rows(
            &Ended {
                item: &failed,
                secs: Some(10.0),
            },
            None,
        )
        .0;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].key, "bg-end:x1");
        let p = |n: &str| {
            rows[0]
                .props
                .iter()
                .filter(|p| p.2 == n)
                .map(|p| p.3.clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(p("drgnx-bg-item"), [json!("x1")]);
        assert!(p("drgnx-agent-panel-action").contains(&json!("background-output:x1")));
    }

    fn env_of(width: u32) -> runstav::methods::view::ViewEnv {
        use runstav::methods::view::{Display, ViewEnv};
        ViewEnv {
            view: "agent-panel/s1".into(),
            class: "gui-1".into(),
            epoch: 1,
            display: Display::Gui,
            scale: 1.0,
            fonts: vec![],
            cell: (8, 16),
            width_px: width,
            tail: None,
            badge: None,
            palette: vec![],
            tty_widths: vec![],
            tz: String::new(),
            reduced_motion: false,
            hc: false,
            glyphs: Vec::new(),
            ascii: false,
            density: Default::default(),
            attach: false,
            rows_in_sja: false,
            headless: false,
        }
    }

    #[test]
    fn the_end_line_keeps_its_link_at_the_docks_width() {
        let cmd = "cargo test -p hermod --features long-feature-list --release --no-fail-fast";
        let failed = ended(
            "terminal",
            cmd,
            json!({"status": "failed", "exit_code": 101}),
        );
        let mut fonts = drgnx_rows::fit::FontSet::new();
        fonts.set_role("ui", None, 7.0);
        for width in [380u32, 460, 900] {
            let env = env_of(width);
            let (rows, _) = end_rows(
                &Ended {
                    item: &failed,
                    secs: Some(240.0),
                },
                Some(EndFit {
                    env: &env,
                    fonts: &fonts,
                }),
            );
            let r = &rows[0];
            assert!(
                r.text.trim_end().ends_with("Output"),
                "{width}: {:?}",
                r.text
            );
            assert!(
                r.text.contains("failed (exit 101) · 4 min"),
                "{width}: {:?}",
                r.text
            );
            if width >= 900 {
                assert!(
                    r.text.contains("Background command `"),
                    "{width}: {:?}",
                    r.text
                );
            }
            if width < 900 {
                assert!(
                    r.text.contains('…'),
                    "the command is cut, not the rest: {:?}",
                    r.text
                );
            }
            assert!(r.spaces.iter().all(|(_, _, h)| *h >= 1), "{:?}", r.spaces);
            // the link is a click target
            assert!(
                r.props
                    .iter()
                    .any(|p| p.2 == "drgnx-agent-panel-action"
                        && p.3 == json!("background-output:x1"))
            );
        }
    }
}
