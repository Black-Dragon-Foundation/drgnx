//! The trail and the Timeline as rows (`docs/develop/work-space.md`, "The Timeline and the trail"): one agent's steps
//! in order with its conclusions among them, and a lane per agent with its steps as segments over time. Pure: the
//! hub reads the steps and conclusions and hands them in; times are shown in the env's zone ([`Zone`]).
//!
//! Row keys: `step:ID`, `conc:N:LINE` (a conclusion's card, two lines), `axis`, `lane:AGENT`, `none`.

use drgnx_rows::fit::Measure;
use drgnx_rows::{Row, RowBuilder};
use serde_json::Value;

use crate::render::Env;
use drgnx_rows::faces::FaceId;

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
            b.push(icon(kind), Some(FaceId::WorkLabel.name()));
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
    let path = |t: String| (t, Some(FaceId::Accent.name()));
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
            vec![plain("web ".into()), (text, Some(FaceId::TextMuted.name()))]
        }
        "thought" => match &d.title {
            Some(t) => vec![(format!("thought: {t}"), Some(FaceId::WorkThought.name()))],
            None => vec![("thinking".into(), Some(FaceId::WorkThought.name()))],
        },
        "edit" => {
            let mut out = vec![plain("edit ".into()), path(title(s))];
            for w in d.title.iter().flat_map(|t| t.split(' ')) {
                out.push(plain(" ".into()));
                let face = if w.starts_with('+') {
                    FaceId::WorkPlus.name()
                } else {
                    FaceId::WorkMinus.name()
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
    build(steps, concs, env, zone, None).0
}

fn build(
    steps: &[Step],
    concs: &[Conclusion],
    env: &Env,
    zone: Zone,
    now: Option<f64>,
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
            Some(c) => b.push(&format!(" {} ", c.n), Some(FaceId::WorkStepNumber.name())),
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
        match (duration(s), now) {
            (Some(d), _) => {
                b.push(&format!(" · {d}"), None);
            }
            (None, Some(now)) if s.end.is_none() && now >= s.start => {
                b.push(&format!(" · {:.0} s…", (now - s.start).floor()), None);
            }
            _ => {}
        }
        let end = b.pos();
        b.face(from, end, FaceId::WorkMeta.name())
            .face(0, end, FaceId::WorkPane.name());
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
            b.face(0, to, FaceId::WorkPane.name());
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
                b.push(&format!(" {name} "), Some(FaceId::WorkTitle.name()))
                    .push(&format!(" {} ", c.n), Some(FaceId::ChipSolid.name()))
                    .push(&format!(" {}", c.text), Some(FaceId::WorkTitle.name()));
                if new {
                    // `new`, plain text at the card's right: a box of its own would break the ring
                    b.stop(env.width_px.saturating_sub((64.0 * env.scale) as u32));
                    b.push(" new ", Some(FaceId::WorkNew.name()));
                }
            } else {
                b.push(
                    &format!("   based on {based}{unmatched} · "),
                    Some(FaceId::TextMuted.name()),
                )
                .push(" l ", Some(FaceId::ChipQuiet.name()))
                .push(" light them · ↵ sources", Some(FaceId::TextMuted.name()));
            }
            // the card runs to the tile's right edge: a stop, in the card's face
            b.stop(env.width_px.saturating_sub((8.0 * env.scale) as u32));
            let end = b.pos();
            b.face(
                0,
                end,
                if i == 0 {
                    FaceId::CardSelTop.name()
                } else {
                    FaceId::CardSelBottom.name()
                },
            )
            .face(0, end, FaceId::WorkPane.name())
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

/// The span of time a Timeline or the Schedule shows, in seconds since the epoch.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Window {
    pub from: f64,
    pub to: f64,
}

impl Window {
    /// Its length in seconds (1 at least).
    pub fn span(&self) -> f64 {
        (self.to - self.from).max(1.0)
    }

    /// The column of a track COLS wide that time T falls in, as a fraction (clamped to the track).
    pub fn at(&self, t: f64, cols: u32) -> f64 {
        ((t - self.from) / self.span() * f64::from(cols)).clamp(0.0, f64::from(cols))
    }

    /// Whether T is inside it.
    pub fn holds(&self, t: f64) -> bool {
        t >= self.from && t <= self.to
    }
}

/// What a Timeline's lanes keep in colour: every step, the edits, or the waits; the rest is greyed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum TrailFilter {
    #[default]
    All,
    Edits,
    Waits,
}

/// A segment's kind (the work-space spec's Activity table), in the table's order: a bin's tie goes to the earlier.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SegKind {
    Read,
    Search,
    Web,
    Edit,
    Tool,
    Think,
    Job,
    /// Waiting on the user.
    WaitYou,
    /// Waiting for a machine's slot.
    WaitMachine,
    Paused,
    Stalled,
}

/// Every kind, in the table's order.
const SEG_KINDS: [SegKind; 11] = [
    SegKind::Read,
    SegKind::Search,
    SegKind::Web,
    SegKind::Edit,
    SegKind::Tool,
    SegKind::Think,
    SegKind::Job,
    SegKind::WaitYou,
    SegKind::WaitMachine,
    SegKind::Paused,
    SegKind::Stalled,
];

impl SegKind {
    /// The step's kind, from its class and what the hub recorded.
    pub fn of(s: &Step) -> SegKind {
        match s.class.as_str() {
            "think" => SegKind::Think,
            "job-wait" => SegKind::Job,
            "user-wait" => SegKind::WaitYou,
            "machine-queue" => SegKind::WaitMachine,
            "paused" => SegKind::Paused,
            "stalled" => SegKind::Stalled,
            _ => match s.detail.kind.as_deref() {
                Some("read") => SegKind::Read,
                Some("search") => SegKind::Search,
                Some("fetch") => SegKind::Web,
                Some("edit") => SegKind::Edit,
                _ => SegKind::Tool,
            },
        }
    }

    /// Its letter (a terminal draws it; a GUI row carries it as `drgnx-work-kind`).
    pub fn letter(self) -> char {
        match self {
            SegKind::Read => 'R',
            SegKind::Search => 'S',
            SegKind::Web => 'W',
            SegKind::Edit => 'E',
            SegKind::Tool => 'T',
            SegKind::Think => '·',
            SegKind::Job => 'J',
            SegKind::WaitYou => 'Y',
            SegKind::WaitMachine => 'M',
            SegKind::Paused => 'P',
            SegKind::Stalled => '!',
        }
    }

    /// A wait: on the user, a machine, a pause or a stall.
    pub fn waits(self) -> bool {
        matches!(
            self,
            SegKind::WaitYou | SegKind::WaitMachine | SegKind::Paused | SegKind::Stalled
        )
    }

    /// Whether FILTER keeps it in colour.
    pub fn kept(self, filter: TrailFilter) -> bool {
        match filter {
            TrailFilter::All => true,
            TrailFilter::Edits => self == SegKind::Edit,
            TrailFilter::Waits => self.waits(),
        }
    }

    /// Its face (today's map faces, until the kit's segment tokens).
    fn face(self) -> &'static str {
        match self {
            SegKind::Read | SegKind::Search | SegKind::Web => FaceId::WorkSegRead.name(),
            SegKind::Edit => FaceId::WorkSegEdit.name(),
            SegKind::Think => FaceId::WorkSegThink.name(),
            SegKind::Job => FaceId::WorkSegJob.name(),
            SegKind::WaitYou | SegKind::WaitMachine | SegKind::Paused | SegKind::Stalled => {
                FaceId::WorkSegWait.name()
            }
            SegKind::Tool => FaceId::WorkSegTool.name(),
        }
    }
}

/// One drawn segment of a lane: columns `[c0, c1)` of the track, its kind, and the step it opens (the one with the
/// most time in its first column of that kind).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Bin {
    pub c0: u32,
    pub c1: u32,
    pub kind: SegKind,
    pub seq: u64,
}

/// STEPS on a track of COLS columns over WIN, an open step running to NOW: each column takes the kind with the most
/// time in it (a tie to the earlier kind of the table) and that kind's longest step there; neighbouring columns of
/// one step and kind are one segment.  So a lane has at most one segment per column, however many steps it has.
pub fn bins(steps: &[Step], win: &Window, cols: u32, now: f64) -> Vec<Bin> {
    let n = cols as usize;
    if n == 0 {
        return Vec::new();
    }
    // per column, per kind: the time, and the step with the most of it
    let mut time = vec![[0.0f64; 11]; n];
    let mut best = vec![[(0.0f64, 0u64); 11]; n];
    let w = win.span() / f64::from(cols);
    for s in steps {
        let a = s.start.max(win.from);
        let b = s.end.unwrap_or(now).max(s.start).min(win.to);
        if a > win.to || b < win.from || s.start > win.to {
            continue;
        }
        let k = SegKind::of(s) as usize;
        let c0 = ((a - win.from) / w).floor().max(0.0) as usize;
        let c1 = (((b - win.from) / w).ceil() as usize).clamp(c0 + 1, n);
        for c in c0.min(n - 1)..c1 {
            let lo = win.from + c as f64 * w;
            // a step of no length still marks its column
            let t = (b.min(lo + w) - a.max(lo)).max(1e-9);
            time[c][k] += t;
            if t > best[c][k].0 {
                best[c][k] = (t, s.seq);
            }
        }
    }
    let mut out: Vec<Bin> = Vec::new();
    for c in 0..n {
        let mut top: Option<usize> = None;
        for k in 0..11 {
            if time[c][k] > 0.0 && top.is_none_or(|t| time[c][k] > time[c][t]) {
                top = Some(k);
            }
        }
        let Some(k) = top else { continue };
        let (kind, seq) = (SEG_KINDS[k], best[c][k].1);
        match out.last_mut() {
            Some(last) if last.c1 == c as u32 && last.kind == kind && last.seq == seq => {
                last.c1 += 1;
            }
            _ => out.push(Bin {
                c0: c as u32,
                c1: c as u32 + 1,
                kind,
                seq,
            }),
        }
    }
    out
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

/// Where a Timeline's or the Schedule's track starts, px.
pub const TRACK_X: u32 = 140;
/// The px a row keeps right of its track (the Schedule's right text).
pub const TRACK_RIGHT: u32 = 160;

/// A column's width: a pixel in a GUI, a cell on a terminal.
pub fn col_px(env: &Env) -> u32 {
    if env.tty { env.cell.0.max(1) } else { 1 }
}

/// The columns of ENV's track: one per pixel (per cell on a terminal), from [`TRACK_X`] to the width less
/// [`TRACK_RIGHT`].
pub fn track_cols(env: &Env) -> u32 {
    env.width_px.saturating_sub(TRACK_X + TRACK_RIGHT).max(100) / col_px(env)
}

/// The now-line's column on a track of COLS over WIN, when NOW is inside it.
pub fn now_col(win: &Window, cols: u32, now: f64) -> Option<u32> {
    win.holds(now)
        .then(|| (win.at(now, cols).floor() as u32).min(cols.saturating_sub(1)))
}

/// The axis row: the window's start, the now-line's "now" with the time (once a second, AXIS_NOW) where it falls, and
/// the window's end right of the track.
pub(crate) fn axis_row(env: &Env, zone: Zone, win: &Window, cols: u32, axis_now: f64) -> Row {
    let cw = col_px(env);
    let mut b = RowBuilder::new("axis");
    b.stop(TRACK_X);
    b.push(&zone.time(win.from), Some(FaceId::WorkLabel.name()));
    // the label's text takes about 70 px: "now" only where it does not run into the ends
    if let Some(c) = now_col(win, cols, axis_now)
        && c * cw > 80
        && c * cw + 120 < cols * cw
    {
        b.stop(TRACK_X + c * cw);
        b.push(
            &format!("now {}", zone.time(axis_now)),
            Some(FaceId::FocusLine.name()),
        );
    }
    b.stop(TRACK_X + cols * cw + 4);
    b.push(&zone.time(win.to), Some(FaceId::WorkLabel.name()));
    b.finish()
}

/// The now-line on B at column C (or after what B holds, when that ends later), when NOW is in the window.
pub(crate) fn now_mark(b: &mut RowBuilder, x: u32) {
    b.stop(x);
    let at = b.pos();
    b.push("│", Some(FaceId::FocusLine.name()));
    b.prop(at, at + 1, "drgnx-work-now", Value::Bool(true));
}

/// The Timeline's rows over WIN: the axis, then a lane per agent: its label fitted to 130 px, then its steps binned on
/// a track of COLS columns from [`TRACK_X`] ([`bins`]), coloured by kind, those FILTER does not keep greyed, and the
/// now-line at NOW_LINE (none: not drawn).  AXIS_NOW is the axis's clock.  A lane's row changes only with its own
/// steps in the window, the window or the now-line.
#[allow(clippy::too_many_arguments)]
pub fn timeline_rows(
    lanes: &[Lane],
    env: &Env,
    m: &dyn Measure,
    zone: Zone,
    win: &Window,
    cols: u32,
    filter: TrailFilter,
    now_line: Option<f64>,
    axis_now: f64,
) -> Vec<Row> {
    if lanes.is_empty() {
        let mut b = RowBuilder::new("none");
        b.push("No agents yet.", None);
        return vec![b.finish()];
    }
    let cw = col_px(env);
    let mut out = vec![axis_row(env, zone, win, cols, axis_now)];
    // an open step runs to the now-line (to the window's end when none is drawn)
    let open_to = now_line.unwrap_or(win.to);
    let now = now_line.and_then(|n| now_col(win, cols, n));
    for lane in lanes {
        let mut b = RowBuilder::new(format!("lane:{}", lane.id));
        let label = drgnx_rows::fit::fit_in(
            m,
            Some(FaceId::WorkLabel.name()),
            &lane.label,
            130.0 + drgnx_rows::fit::SLACK,
        );
        b.push(&label, Some(FaceId::WorkLabel.name()));
        let end = b.pos();
        b.prop(
            0,
            end,
            "drgnx-work-id",
            Value::from(format!("lane:{}", lane.id)),
        );
        let mut last = 0;
        for bin in bins(&lane.steps, win, cols, open_to) {
            b.stop(TRACK_X + bin.c0 * cw);
            let at = b.pos();
            if env.tty {
                // a terminal: the letter in each cell
                let s: String =
                    std::iter::repeat_n(bin.kind.letter(), (bin.c1 - bin.c0) as usize).collect();
                b.push(&s, None);
            } else {
                // the segment: one char, displayed as the space up to its end
                b.stop(TRACK_X + bin.c1 * cw);
            }
            let to = b.pos();
            let face = if bin.kind.kept(filter) {
                bin.kind.face()
            } else {
                FaceId::WorkDim.name()
            };
            b.face(at, to, face)
                .prop(
                    at,
                    to,
                    "drgnx-work-kind",
                    Value::from(bin.kind.letter().to_string()),
                )
                .prop(
                    at,
                    to,
                    "drgnx-work-step",
                    Value::from(vec![Value::from(lane.id.clone()), Value::from(bin.seq)]),
                )
                .prop(
                    at,
                    to,
                    "drgnx-work-id",
                    Value::from(format!("step:{}:{}", lane.id, bin.seq)),
                );
            last = bin.c1;
        }
        if let Some(c) = now {
            now_mark(&mut b, TRACK_X + c.max(last) * cw);
        }
        out.push(b.finish());
    }
    out
}

/// When the now-line is drawn again: at most once every [`NOW_EVERY`] seconds, and only when it moved a column.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct NowLine {
    /// When it was last drawn, and at which column (none: off the track).
    pub drawn: Option<(f64, Option<u32>)>,
}

/// The seconds between two draws of the now-line.
pub const NOW_EVERY: f64 = 5.0;

impl NowLine {
    /// At NOW, the line would sit at column COL: whether to draw again (and it is recorded as drawn).
    pub fn due(&mut self, now: f64, col: Option<u32>) -> bool {
        let due = match self.drawn {
            None => true,
            Some((at, was)) => now - at >= NOW_EVERY && was != col,
        };
        if due {
            self.drawn = Some((now, col));
        }
        due
    }
}

/// [`trail_rows`] and the images they name (the Lucide icons of the steps and the conclusions).
/// As [`trail_rows`], with the images, and NOW (seconds since the epoch): a step still open shows how long it has run
/// (`32 s…`).
pub fn trail_rows_with_images(
    steps: &[Step],
    concs: &[Conclusion],
    env: &Env,
    zone: Zone,
    now: Option<f64>,
) -> (Vec<Row>, Vec<(drgnx_rows::ImageId, String)>) {
    let (rows, images) = build(steps, concs, env, zone, now);
    (rows, images.into_iter().collect())
}
