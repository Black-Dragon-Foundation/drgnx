//! The trail and the Timeline as rows (`docs/develop/work-space.md`, "The Timeline and the trail"): one agent's steps
//! in order with its conclusions among them, and a lane per agent with its steps as segments over time. Pure: the
//! hub reads the steps and conclusions and hands them in; times are shown in the env's zone ([`Zone`]).
//!
//! Row keys: `step:ID`, `conc:N:LINE` (a conclusion's card, two lines), `axis`, `lane:AGENT`, `none`.

use drgnx_rows::fit::Measure;
use drgnx_rows::{Row, RowBuilder};
use serde_json::Value;

use crate::render::Env;

/// A time zone as the editor's offset from UTC, in seconds (`view/env`'s `tz`: `+HHMM`, as `%z` prints it).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Zone(pub i32);

impl Zone {
    /// `+HHMM` or `-HHMM`; anything else is UTC.
    pub fn parse(tz: &str) -> Zone {
        let (sign, rest) = match tz.as_bytes().first() {
            Some(b'+') => (1, &tz[1..]),
            Some(b'-') => (-1, &tz[1..]),
            _ => return Zone(0),
        };
        if rest.len() != 4 || !rest.bytes().all(|b| b.is_ascii_digit()) {
            return Zone(0);
        }
        let h: i32 = rest[..2].parse().unwrap_or(0);
        let m: i32 = rest[2..].parse().unwrap_or(0);
        Zone(sign * (h * 3600 + m * 60))
    }

    /// SECS (since the epoch) as `HH:MM:SS` in this zone.
    pub fn time(self, secs: f64) -> String {
        let t = (secs.floor() as i64 + i64::from(self.0)).rem_euclid(86_400);
        format!("{:02}:{:02}:{:02}", t / 3600, t / 60 % 60, t % 60)
    }
}

/// What a step recorded it read, searched, fetched or edited.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Detail {
    pub kind: Option<String>,
    pub path: Option<String>,
    pub line_start: Option<u32>,
    pub line_end: Option<u32>,
    pub query: Option<String>,
    pub url: Option<String>,
    pub title: Option<String>,
}

/// One step of a session's timeline.
#[derive(Clone, Debug, PartialEq)]
pub struct Step {
    pub id: i64,
    pub seq: u64,
    /// The step's class (`think`, `user-wait`, `tool`, …).
    pub class: String,
    pub tool: Option<String>,
    pub detail: Detail,
    pub start: f64,
    /// None: still open.
    pub end: Option<f64>,
}

/// One of a session's conclusions.
#[derive(Clone, Debug, PartialEq)]
pub struct Conclusion {
    pub n: u32,
    /// `decision` or `finding`.
    pub kind: String,
    pub text: String,
    /// The step the hub stamped it on.
    pub step: Option<i64>,
    /// The steps it rests on: its named sources, then those since the last conclusion.
    pub rests_on: Vec<i64>,
    /// Its named sources no step matched (a path or a URL).
    pub unmatched: Vec<String>,
}

/// What kind of step it is: from its class and what the hub recorded, never its prose.
pub fn kind(s: &Step) -> &'static str {
    match s.class.as_str() {
        "think" => "thought",
        "user-wait" | "machine-queue" | "paused" | "stalled" => "waiting",
        "job-wait" => "job",
        _ => match s.detail.kind.as_deref() {
            Some("read") => "read",
            Some("search") => "search",
            Some("fetch") => "web",
            Some("edit") => "edit",
            _ => "tool",
        },
    }
}

/// The Lucide icon of a kind of step or conclusion, when it has one.
fn icon_name(kind: &str) -> Option<&'static str> {
    Some(match kind {
        "read" => "file-text",
        "search" => "search",
        "web" => "globe",
        "thought" => "brain",
        "decision" => "flag",
        "finding" => "lightbulb",
        "edit" => "pencil",
        "job" => "layers",
        "waiting" => "clock",
        "resumed" => "play",
        _ => return None,
    })
}

/// KIND's icon at the row's start: an image (its glyph on a terminal), registered in IMAGES; its glyph as text when it
/// has no Lucide icon.
fn put_icon(
    b: &mut RowBuilder,
    env: &Env,
    kind: &str,
    images: &mut std::collections::BTreeMap<drgnx_rows::ImageId, String>,
) {
    let px = (16.0 * env.scale.max(1.0)).round() as u32;
    let svg = icon_name(kind).and_then(|n| crate::icons::svg(n, env.palette.colour("chip-fg"), px));
    match svg {
        Some(svg) => {
            let id = drgnx_rows::ImageId::of(svg.as_bytes(), env.epoch);
            images.entry(id).or_insert(svg);
            b.image(id, icon(kind));
        }
        None => {
            b.push(icon(kind), Some("drgnx-work-label"));
        }
    }
}

fn icon(kind: &str) -> &'static str {
    match kind {
        "read" => "▤",
        "search" => "⌕",
        "web" => "◍",
        "thought" => "…",
        "decision" => "⚑",
        "finding" => "✦",
        "edit" => "✎",
        "job" => "▦",
        "waiting" => "◷",
        "resumed" => "▷",
        _ => "›",
    }
}

/// A step's title: `path:120–184` for a read, a search's query, a page's host and title, `thinking`, an edit's path.
pub fn title(s: &Step) -> String {
    let d = &s.detail;
    let tool = |or: &str| s.tool.clone().unwrap_or_else(|| or.to_owned());
    match kind(s) {
        "read" => match (&d.path, d.line_start, d.line_end) {
            (None, _, _) => tool("read"),
            (Some(p), Some(a), Some(b)) => format!("{p}:{a}–{b}"),
            (Some(p), Some(a), None) => format!("{p}:{a}"),
            (Some(p), None, _) => p.clone(),
        },
        "search" => d
            .query
            .clone()
            .or_else(|| d.path.clone())
            .unwrap_or_else(|| tool("search")),
        "web" => {
            let host = d.url.as_deref().and_then(|u| {
                let rest = u.split_once("://")?.1;
                let h = rest.split(['/', '?', '#']).next()?;
                (!h.is_empty()).then(|| h.to_owned())
            });
            match (host, &d.title) {
                (Some(h), Some(t)) => format!("{h} · {t}"),
                (Some(h), None) => h,
                (None, _) => d.query.clone().unwrap_or_else(|| tool("page")),
            }
        }
        "thought" => "thinking".into(),
        "edit" => d.path.clone().unwrap_or_else(|| tool("edit")),
        "job" => "waiting on a job".into(),
        "waiting" => match s.class.as_str() {
            "user-wait" => "waiting for you".into(),
            "machine-queue" => "waiting for a machine".into(),
            "paused" => "paused".into(),
            _ => "stalled".into(),
        },
        _ => tool("tool"),
    }
}

/// A step's row text as pieces and their faces (work-space-dark.html `.trow`): the verb plain, a path in the link
/// colour, a web page's title muted, a thought's text muted and italic, an edit's change in the added and removed
/// colours.
fn segments(s: &Step) -> Vec<(String, Option<&'static str>)> {
    let d = &s.detail;
    let plain = |t: String| (t, None);
    let path = |t: String| (t, Some("drgnx-accent"));
    match kind(s) {
        "read" => {
            let mut out = vec![plain("read ".into())];
            out.push(path(title(s)));
            out
        }
        "web" => {
            let host = d.url.as_deref().and_then(|u| {
                let rest = u.split_once("://")?.1;
                rest.split(['/', '?', '#']).next().map(str::to_owned)
            });
            let text = match (&d.title, host) {
                (Some(t), Some(h)) => format!("{t} — {h}"),
                (Some(t), None) => t.clone(),
                (None, Some(h)) => h,
                (None, None) => title(s),
            };
            vec![plain("web ".into()), (text, Some("drgnx-text-muted"))]
        }
        "thought" => match &d.title {
            Some(t) => vec![(format!("thought: {t}"), Some("drgnx-work-thought"))],
            None => vec![("thinking".into(), Some("drgnx-work-thought"))],
        },
        "edit" => {
            let mut out = vec![plain("edit ".into()), path(title(s))];
            for w in d.title.iter().flat_map(|t| t.split(' ')) {
                out.push(plain(" ".into()));
                let face = if w.starts_with('+') {
                    "drgnx-work-plus"
                } else {
                    "drgnx-work-minus"
                };
                out.push((w.to_owned(), Some(face)));
            }
            out
        }
        "job" => match &d.path {
            Some(p) => {
                let mut out = vec![plain("job ".into()), path(p.clone())];
                out.extend(d.title.iter().map(|t| plain(format!(" · {t}"))));
                out
            }
            None => vec![plain(title(s))],
        },
        _ => vec![plain(title(s))],
    }
}

/// How long a step took: `1.5 s` (`6 s` when whole) or `2m05s`; nothing while it is open.
fn duration(s: &Step) -> Option<String> {
    let d = s.end? - s.start;
    Some(if d < 60.0 {
        if (d - d.round()).abs() < 0.05 {
            format!("{d:.0} s")
        } else {
            format!("{d:.1} s")
        }
    } else {
        let w = d.floor() as u64;
        format!("{}m{:02}s", w / 60, w % 60)
    })
}

/// The trail's rows: each step (oldest first) with the cards of the conclusions stamped on it after it, then the
/// cards of the conclusions on no step shown. A step's row: its kind's icon, its title, the number of each
/// conclusion resting on it, and its time and duration 14 columns from the right edge. A pause that ended is followed
/// by a note row `resumed` at the time it ended.
pub fn trail_rows(steps: &[Step], concs: &[Conclusion], env: &Env, zone: Zone) -> Vec<Row> {
    build(steps, concs, env, zone).0
}

fn build(
    steps: &[Step],
    concs: &[Conclusion],
    env: &Env,
    zone: Zone,
) -> (
    Vec<Row>,
    std::collections::BTreeMap<drgnx_rows::ImageId, String>,
) {
    let mut images = std::collections::BTreeMap::new();
    let mut steps: Vec<&Step> = steps.iter().collect();
    steps.sort_by_key(|s| (s.seq, s.id));
    let mut concs: Vec<&Conclusion> = concs.iter().collect();
    concs.sort_by_key(|c| c.n);
    let right = env.width_px.saturating_sub(14 * env.cell.0.max(1));
    // the newest conclusion is `new` while it is stamped on one of the last three steps
    let last: Vec<i64> = steps.iter().rev().take(3).map(|s| s.id).collect();
    let newest = concs
        .iter()
        .filter(|c| c.step.is_some_and(|id| last.contains(&id)))
        .map(|c| c.n)
        .max();
    let mut out = Vec::new();
    for s in &steps {
        let mut b = RowBuilder::new(format!("step:{}", s.id));
        let k = kind(s);
        // a step a conclusion rests on starts with its number in a circle; the others keep the room
        match concs.iter().find(|c| c.rests_on.contains(&s.id)) {
            Some(c) => b.push(&format!(" {} ", c.n), Some("drgnx-work-step-number")),
            None => b.push("   ", None),
        };
        b.stop((30.0 * env.scale) as u32);
        put_icon(&mut b, env, k, &mut images);
        b.push(" ", None);
        for (text, face) in segments(s) {
            b.push(&text, face);
        }
        let from = b.pos();
        b.stop(right).push(&zone.time(s.start), None);
        if let Some(d) = duration(s) {
            b.push(&format!(" · {d}"), None);
        }
        let end = b.pos();
        b.face(from, end, "drgnx-work-meta")
            .face(0, end, "drgnx-work-pane");
        b.prop(0, end, "drgnx-work-step", Value::from(s.id)).prop(
            0,
            end,
            "drgnx-work-id",
            Value::from(format!("step:{}", s.id)),
        );
        out.push(b.finish());
        for c in concs.iter().filter(|c| c.step == Some(s.id)) {
            out.extend(conclusion_rows(c, env, &mut images, newest == Some(c.n)));
        }
        // a pause that ended: the agent was resumed then (a note, no node)
        if let (true, Some(end)) = (s.class == "paused", s.end) {
            let mut b = RowBuilder::new(format!("resumed:{}", s.id));
            put_icon(&mut b, env, "resumed", &mut images);
            b.push(" resumed", None)
                .stop(right)
                .push(&zone.time(end), None);
            let to = b.pos();
            b.face(0, to, "drgnx-work-pane");
            out.push(b.finish());
        }
    }
    for c in concs
        .iter()
        .filter(|c| !c.step.is_some_and(|id| steps.iter().any(|s| s.id == id)))
    {
        out.extend(conclusion_rows(c, env, &mut images, newest == Some(c.n)));
    }
    (out, images)
}

/// A conclusion's card: its number and text, then what it rests on and its named sources no step matched.
fn conclusion_rows(
    c: &Conclusion,
    env: &Env,
    images: &mut std::collections::BTreeMap<drgnx_rows::ImageId, String>,
    new: bool,
) -> Vec<Row> {
    let n = c.rests_on.len();
    let based = match n {
        0 => "no steps".to_owned(),
        1 => "1 step".to_owned(),
        n => format!("{n} steps"),
    };
    let unmatched = if c.unmatched.is_empty() {
        String::new()
    } else {
        format!(
            " · named, not read in this session: {}",
            c.unmatched.join(", ")
        )
    };
    // the card is the accent ring (the selected card's faces): its name and text in the heading face, its number in a
    // chip, what it rests on muted
    let name = if c.kind == "decision" {
        "Decision"
    } else {
        "Finding"
    };
    (0..2)
        .map(|i| {
            let mut b = RowBuilder::new(format!("conc:{}:{i}", c.n));
            if i == 0 {
                put_icon(&mut b, env, &c.kind, images);
                b.push(&format!(" {name} "), Some("drgnx-work-title"))
                    .push(&format!(" {} ", c.n), Some("drgnx-chip-solid"))
                    .push(&format!(" {}", c.text), Some("drgnx-work-title"));
                if new {
                    // `new`, plain text at the card's right: a box of its own would break the ring
                    b.stop(env.width_px.saturating_sub((64.0 * env.scale) as u32));
                    b.push(" new ", Some("drgnx-work-new"));
                }
            } else {
                b.push(
                    &format!("   based on {based}{unmatched} · "),
                    Some("drgnx-text-muted"),
                )
                .push(" l ", Some("drgnx-chip-quiet"))
                .push(" light them · ↵ sources", Some("drgnx-text-muted"));
            }
            // the card runs to the tile's right edge: a stop, in the card's face
            b.stop(env.width_px.saturating_sub((8.0 * env.scale) as u32));
            let end = b.pos();
            b.face(
                0,
                end,
                if i == 0 {
                    "drgnx-card-sel-top"
                } else {
                    "drgnx-card-sel-bottom"
                },
            )
            .face(0, end, "drgnx-work-pane")
            .prop(0, end, "drgnx-work-conclusion", Value::from(c.n))
            .prop(
                0,
                end,
                "drgnx-work-id",
                Value::from(format!("conc:{}", c.n)),
            );
            b.finish()
        })
        .collect()
}

/// One lane of the Timeline: the agent's id, its label, and its steps.
#[derive(Clone, Debug, PartialEq)]
pub struct Lane {
    pub id: String,
    pub label: String,
    pub steps: Vec<Step>,
}

/// The face of a step's segment, by its kind.
fn seg_face(kind: &str) -> &'static str {
    match kind {
        "read" | "search" | "web" => "drgnx-work-seg-read",
        "edit" => "drgnx-work-seg-edit",
        "thought" => "drgnx-work-seg-think",
        "job" => "drgnx-work-seg-job",
        "waiting" => "drgnx-work-seg-wait",
        _ => "drgnx-work-seg-tool",
    }
}

/// The time every lane covers: the earliest start and the latest end of any step (`(0, 1)` with none).
pub fn range(lanes: &[Lane]) -> (f64, f64) {
    let mut r: Option<(f64, f64)> = None;
    for s in lanes.iter().flat_map(|l| l.steps.iter()) {
        let end = s.end.unwrap_or(s.start);
        r = Some(match r {
            None => (s.start, end),
            Some((a, b)) => (a.min(s.start), b.max(end)),
        });
    }
    r.unwrap_or((0.0, 1.0))
}

/// The Timeline's rows: the axis (the range's times), then a lane per agent: its label fitted to 130 px, then each
/// step a segment at its time, 2 px at least, on a track from 140 px to the width less 160 px. A lane's row changes
/// only with its own steps or the range.
pub fn timeline_rows(lanes: &[Lane], env: &Env, m: &dyn Measure, zone: Zone) -> Vec<Row> {
    if lanes.is_empty() {
        let mut b = RowBuilder::new("none");
        b.push("No agents yet.", None);
        return vec![b.finish()];
    }
    let (t0, t1) = range(lanes);
    let width = env.width_px.saturating_sub(160).max(100);
    let k = f64::from(width) / (t1 - t0).max(1.0);
    let mut axis = RowBuilder::new("axis");
    let to = if t1 > t0 {
        format!(" to {}", zone.time(t1))
    } else {
        String::new()
    };
    axis.push(
        &format!("{}{}{to}", " ".repeat(20), zone.time(t0)),
        Some("drgnx-work-label"),
    );
    let mut out = vec![axis.finish()];
    for lane in lanes {
        let mut b = RowBuilder::new(format!("lane:{}", lane.id));
        let label = drgnx_rows::fit::fit(m, "ui", &lane.label, 130.0 + drgnx_rows::fit::SLACK);
        b.push(&label, Some("drgnx-work-label"));
        let end = b.pos();
        b.prop(
            0,
            end,
            "drgnx-work-id",
            Value::from(format!("lane:{}", lane.id)),
        );
        let mut steps: Vec<&Step> = lane.steps.iter().collect();
        steps.sort_by_key(|s| (s.seq, s.id));
        for s in steps {
            let x = ((s.start - t0) * k).round() as u32;
            let w = (((s.end.unwrap_or(t1) - s.start) * k).round() as u32).max(2);
            b.stop(140 + x);
            let at = b.pos();
            // the segment: one char, displayed as the space up to its end
            b.stop(140 + x + w);
            b.face(at, at + 1, seg_face(kind(s)))
                .prop(
                    at,
                    at + 1,
                    "drgnx-work-step",
                    Value::from(vec![Value::from(lane.id.clone()), Value::from(s.seq)]),
                )
                .prop(
                    at,
                    at + 1,
                    "drgnx-work-id",
                    Value::from(format!("step:{}:{}", lane.id, s.seq)),
                );
        }
        out.push(b.finish());
    }
    out
}

/// [`trail_rows`] and the images they name (the Lucide icons of the steps and the conclusions).
pub fn trail_rows_with_images(
    steps: &[Step],
    concs: &[Conclusion],
    env: &Env,
    zone: Zone,
) -> (Vec<Row>, Vec<(drgnx_rows::ImageId, String)>) {
    let (rows, images) = build(steps, concs, env, zone);
    (rows, images.into_iter().collect())
}
