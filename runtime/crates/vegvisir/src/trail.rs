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

/// How long a step took: `1.5s` or `2m05s`; nothing while it is open.
fn duration(s: &Step) -> Option<String> {
    let d = s.end? - s.start;
    Some(if d < 60.0 {
        format!("{d:.1}s")
    } else {
        let w = d.floor() as u64;
        format!("{}m{:02}s", w / 60, w % 60)
    })
}

/// The trail's rows: each step (oldest first) with the cards of the conclusions stamped on it after it, then the
/// cards of the conclusions on no step shown. A step's row: its kind's icon, its title, the number of each
/// conclusion resting on it, and its time and duration 14 columns from the right edge.
pub fn trail_rows(steps: &[Step], concs: &[Conclusion], env: &Env, zone: Zone) -> Vec<Row> {
    let mut steps: Vec<&Step> = steps.iter().collect();
    steps.sort_by_key(|s| (s.seq, s.id));
    let mut concs: Vec<&Conclusion> = concs.iter().collect();
    concs.sort_by_key(|c| c.n);
    let right = env.width_px.saturating_sub(14 * env.cell.0.max(1));
    let mut out = Vec::new();
    for s in &steps {
        let mut b = RowBuilder::new(format!("step:{}", s.id));
        let k = kind(s);
        b.push(icon(k), Some("drgnx-work-label"))
            .push(&format!(" {}", title(s)), None);
        for c in concs.iter().filter(|c| c.rests_on.contains(&s.id)) {
            b.push(&format!(" [{}]", c.n), Some("drgnx-work-chip"));
        }
        b.stop(right).push(&zone.time(s.start), None);
        if let Some(d) = duration(s) {
            b.push(&format!(" {d}"), None);
        }
        let end = b.pos();
        b.prop(0, end, "drgnx-work-step", Value::from(s.id)).prop(
            0,
            end,
            "drgnx-work-id",
            Value::from(format!("step:{}", s.id)),
        );
        out.push(b.finish());
        for c in concs.iter().filter(|c| c.step == Some(s.id)) {
            out.extend(conclusion_rows(c));
        }
    }
    for c in concs
        .iter()
        .filter(|c| !c.step.is_some_and(|id| steps.iter().any(|s| s.id == id)))
    {
        out.extend(conclusion_rows(c));
    }
    out
}

/// A conclusion's card: its number and text, then what it rests on and its named sources no step matched.
fn conclusion_rows(c: &Conclusion) -> Vec<Row> {
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
    let lines = [
        format!("{} {}  {}", icon(&c.kind), c.n, c.text),
        format!("   based on {based}{unmatched}"),
    ];
    lines
        .iter()
        .enumerate()
        .map(|(i, l)| {
            let mut b = RowBuilder::new(format!("conc:{}:{i}", c.n));
            b.push(l, None);
            let end = b.pos();
            b.face(
                0,
                end,
                if i == 0 {
                    "drgnx-card-top"
                } else {
                    "drgnx-card-bottom"
                },
            )
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
