//! The Schedule (Timeline · Schedule, `docs/develop/work-space.md`) as rows: the List's rows in order, each with a
//! bar over a window of time: what was done, the forecast to its p50 and the tail to its p90, the baseline's tick, a
//! spec's or plan's target and the now-line.  Pure: the hub hands in the rows' facts (spans, forecasts, baselines,
//! targets) and the clock.
//!
//! Row keys: `axis`, `sched:ITEM` (an item of the List), `machine:NAME` (a machine's heading when grouped by machine),
//! `machine:` (the tasks not placed yet), `none`.

use drgnx_rows::faces::FaceId;
use drgnx_rows::fit::Measure;
use drgnx_rows::{Row, RowBuilder};
use serde_json::Value;

use crate::render::Env;
use crate::trail::{TRACK_X, Window, Zone, axis_row, col_px, now_col, now_mark};

/// A schedule bar's state (the timeline spec's §4): the forecast's, and against a spec's or plan's target.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScheduleState {
    /// Running, now before its p50 finish.
    OnTrack,
    /// Now past its p50 finish, before its p90.
    Behind,
    /// Now past its p90 finish.
    Late,
    /// Its agent waits on the user, a machine or a job.
    Waiting,
    /// A spec or plan whose p50 finish is over a quarter of its baseline's wall time later than the baseline's.
    Slipped,
    Done,
    /// Not started: placed at its forecast start.
    Forecast,
    /// Its p90 finish is before the target.
    OnTarget,
    /// Its p50 is before the target, its p90 after.
    AtRisk,
    /// Its p50 finish is after the target, or the target has passed and it is not done.
    LateVsTarget,
}

impl ScheduleState {
    /// The word a row shows (colour is never the only signal); none for on track.
    pub fn word(self) -> &'static str {
        match self {
            ScheduleState::OnTrack => "",
            ScheduleState::Behind => "behind",
            ScheduleState::Late => "late",
            ScheduleState::Waiting => "waiting",
            ScheduleState::Slipped => "slipped",
            ScheduleState::Done => "done",
            ScheduleState::Forecast => "forecast",
            ScheduleState::OnTarget => "on target",
            ScheduleState::AtRisk => "at risk",
            ScheduleState::LateVsTarget => "misses target",
        }
    }

    /// A warning state (its word in the warning face).
    fn warns(self) -> bool {
        matches!(
            self,
            ScheduleState::Behind
                | ScheduleState::Late
                | ScheduleState::Slipped
                | ScheduleState::AtRisk
                | ScheduleState::LateVsTarget
        )
    }
}

/// One row's bar, in seconds since the epoch.  A task not started yet has its forecast start in `started`.
#[derive(Clone, Debug, PartialEq)]
pub struct ScheduleBar {
    pub started: Option<f64>,
    /// The done part's end: the actual end of a finished item, now for a running one.
    pub done_to: Option<f64>,
    pub p50: Option<f64>,
    pub p90: Option<f64>,
    /// The p50 finish the forecast gave at approval.
    pub baseline: Option<f64>,
    /// A spec's or plan's target.
    pub target: Option<f64>,
    pub state: ScheduleState,
    pub machine: Option<String>,
}

/// What a row's bar and state are read from.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct BarFacts {
    /// Its first step's start (none: not started).
    pub started: Option<f64>,
    /// Its last step's end, when it is finished.
    pub ended: Option<f64>,
    pub done: bool,
    /// Its agent waits on the user, a machine or a job.
    pub waiting: bool,
    /// The forecast's start, p50 and p90 finish (what remains, for a running job).
    pub start: Option<f64>,
    pub p50: Option<f64>,
    pub p90: Option<f64>,
    /// The baseline's p50 finish, and its wall time from the run's start (for slipped).
    pub baseline: Option<f64>,
    pub baseline_wall: Option<f64>,
    pub target: Option<f64>,
    /// A spec's or plan's row: target and slipped states apply.
    pub whole: bool,
    pub machine: Option<String>,
}

/// How far past its baseline a spec or plan may finish before it reads slipped, as a share of the baseline's wall time.
pub const SLIP: f64 = 0.25;

/// F's state at NOW (the timeline spec's §4).  A spec or plan with a target and a forecast takes the target's state;
/// a done item is done whatever its target.
pub fn state_of(f: &BarFacts, now: f64) -> ScheduleState {
    if f.done {
        return ScheduleState::Done;
    }
    if f.whole
        && let Some(t) = f.target
    {
        if now > t || f.p50.is_some_and(|p| p > t) {
            return ScheduleState::LateVsTarget;
        }
        match f.p90 {
            Some(p) if p > t => return ScheduleState::AtRisk,
            Some(_) => return ScheduleState::OnTarget,
            None => {}
        }
    }
    if f.started.is_none() {
        return ScheduleState::Forecast;
    }
    if f.waiting {
        return ScheduleState::Waiting;
    }
    if f.whole
        && let (Some(p), Some(base), Some(wall)) = (f.p50, f.baseline, f.baseline_wall)
        && p - base > SLIP * wall
    {
        return ScheduleState::Slipped;
    }
    match (f.p50, f.p90) {
        (_, Some(p90)) if now >= p90 => ScheduleState::Late,
        (Some(p50), _) if now >= p50 => ScheduleState::Behind,
        _ => ScheduleState::OnTrack,
    }
}

/// F's bar at NOW.
pub fn bar(f: &BarFacts, now: f64) -> ScheduleBar {
    let state = state_of(f, now);
    let (started, done_to) = match (f.started, f.done) {
        (Some(s), true) => (Some(s), Some(f.ended.unwrap_or(now).max(s))),
        (Some(s), false) => (Some(s), Some(now.max(s))),
        (None, _) => (f.start, None),
    };
    ScheduleBar {
        started,
        done_to,
        p50: (!f.done).then_some(f.p50).flatten(),
        p90: (!f.done).then_some(f.p90).flatten(),
        baseline: f.baseline,
        target: f.target.filter(|_| f.whole),
        state,
        machine: f.machine.clone(),
    }
}

/// One row of the Schedule: its key's item (or `machine:NAME`), its label, its depth in the List, and its bar (none:
/// a heading).
#[derive(Clone, Debug, PartialEq)]
pub struct SchedRow {
    pub item: String,
    pub label: String,
    pub depth: u8,
    pub bar: Option<ScheduleBar>,
}

/// The tasks of ROWS grouped by the machine they ran or run on, as the Schedule's By machine shows them: a heading per
/// machine of MACHINES (label, slots used, slots) with its tasks under it, in the List's order, then "Not placed yet"
/// with the tasks that have no machine.  Specs and plans are left out: a machine holds tasks.
pub fn by_machine(rows: &[SchedRow], machines: &[(String, u32, u32)]) -> Vec<SchedRow> {
    let tasks: Vec<&SchedRow> = rows.iter().filter(|r| r.depth == 2).collect();
    let mut out = Vec::new();
    let heading = |item: String, label: String| SchedRow {
        item,
        label,
        depth: 0,
        bar: None,
    };
    let under = |r: &SchedRow| SchedRow {
        depth: 1,
        ..r.clone()
    };
    let machine_of = |r: &SchedRow| r.bar.as_ref().and_then(|b| b.machine.clone());
    let mut named: Vec<String> = machines.iter().map(|m| m.0.clone()).collect();
    // a machine a task names that the map no longer lists still heads its tasks
    for r in &tasks {
        if let Some(m) = machine_of(r)
            && !named.contains(&m)
        {
            named.push(m);
        }
    }
    for name in named {
        let label = match machines.iter().find(|m| m.0 == name) {
            Some((_, used, total)) => format!("{name} {used}/{total}"),
            None => name.clone(),
        };
        out.push(heading(format!("machine:{name}"), label));
        out.extend(
            tasks
                .iter()
                .filter(|r| machine_of(r).as_deref() == Some(name.as_str()))
                .map(|r| under(r)),
        );
    }
    let unplaced: Vec<SchedRow> = tasks
        .iter()
        .filter(|r| machine_of(r).is_none())
        .map(|r| under(r))
        .collect();
    if !unplaced.is_empty() {
        out.push(heading("machine:".into(), "Not placed yet".into()));
        out.extend(unplaced);
    }
    out
}

/// What a column of the track shows: a face and a character (a terminal draws it; a GUI the face's colour).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Paint {
    face: &'static str,
    ch: char,
    part: &'static str,
}

/// A duration as `1h10` or `0h35`.
fn hm(secs: f64) -> String {
    let m = (secs.max(0.0) / 60.0).round() as u64;
    format!("{}h{:02}", m / 60, m % 60)
}

/// The right text of a bar at NOW: its state's word and what it rests on.
fn right_text(b: &ScheduleBar, zone: Zone, now: f64) -> String {
    let mut parts: Vec<String> = Vec::new();
    match b.state {
        ScheduleState::Done => {
            parts.push("done".into());
            if let (Some(s), Some(e)) = (b.started, b.done_to) {
                parts.push(format!("took {}", hm(e - s)));
            }
            if let (Some(t), Some(e)) = (b.target, b.done_to) {
                parts.push(if e <= t {
                    "met target".into()
                } else {
                    format!("missed by {}", hm(e - t))
                });
            }
        }
        ScheduleState::Late => {
            parts.push("late".into());
            if let Some(p) = b.p90 {
                parts.push(format!("past p90 by {}", hm(now - p)));
            }
        }
        ScheduleState::Slipped => {
            parts.push("slipped".into());
            if let Some(base) = b.baseline {
                parts.push(format!("was {}", &zone.time(base)[..5]));
            }
        }
        ScheduleState::LateVsTarget if b.target.is_some_and(|t| now > t) => {
            parts.push("overdue".into())
        }
        ScheduleState::OnTarget | ScheduleState::AtRisk | ScheduleState::LateVsTarget => {
            if let Some(t) = b.target {
                parts.push(format!("target {}", &zone.time(t)[..5]));
            }
            parts.push(b.state.word().into());
        }
        s => {
            if !s.word().is_empty() {
                parts.push(s.word().into());
            }
            if let (Some(p50), Some(p90)) = (b.p50, b.p90) {
                parts.push(format!("{}–{}", &zone.time(p50)[..5], &zone.time(p90)[..5]));
            }
        }
    }
    parts.join(" · ")
}

/// ROW's columns on a track of COLS over WIN, at NOW: the done part, the forecast to p50, the tail to p90, then over
/// them the late cap, the baseline's tick and the target's rule.
fn paint(b: &ScheduleBar, win: &Window, cols: u32, now: f64) -> Vec<Option<Paint>> {
    let mut out: Vec<Option<Paint>> = vec![None; cols as usize];
    let col = |t: f64| win.at(t, cols);
    let mut fill = |a: f64, z: f64, p: Paint| {
        if z < win.from || a > win.to || z < a {
            return;
        }
        let c0 = col(a).floor() as usize;
        let c1 = (col(z).ceil() as usize).max(c0 + 1).min(cols as usize);
        for c in out.iter_mut().take(c1).skip(c0.min(cols as usize)) {
            *c = Some(p);
        }
    };
    let solid = |face: &'static str, part: &'static str| Paint {
        face,
        ch: '█',
        part,
    };
    let forecast_only = b.state == ScheduleState::Forecast;
    if let (Some(s), Some(e)) = (b.started, b.done_to) {
        let face = if b.state == ScheduleState::Done {
            FaceId::WorkDim.name()
        } else {
            FaceId::WorkBar.name()
        };
        fill(s, e, solid(face, "done"));
    }
    let from = match (b.done_to, b.started) {
        (Some(e), _) => e,
        (None, Some(s)) => s,
        (None, None) => now,
    };
    if let Some(p50) = b.p50 {
        let p = if forecast_only {
            Paint {
                face: FaceId::WorkEdge.name(),
                ch: '▒',
                part: "forecast",
            }
        } else {
            Paint {
                face: FaceId::WorkBarRest.name(),
                ch: '▓',
                part: "p50",
            }
        };
        fill(from, p50, p);
        if let Some(p90) = b.p90 {
            fill(
                p50.max(from),
                p90,
                Paint {
                    face: FaceId::WorkEdge.name(),
                    ch: '░',
                    part: "p90",
                },
            );
        }
    }
    let mut mark = |t: f64, p: Paint| {
        if win.holds(t) {
            let c = (col(t).floor() as usize).min(cols as usize - 1);
            out[c] = Some(p);
        }
    };
    if b.state == ScheduleState::Late {
        // the done part's last column: the now-line takes now's own
        mark(
            now - win.span() / f64::from(cols),
            Paint {
                face: FaceId::WorkNeedsYou.name(),
                ch: '▌',
                part: "late",
            },
        );
    }
    if let Some(t) = b.baseline {
        mark(
            t,
            Paint {
                face: FaceId::WorkMeta.name(),
                ch: '▏',
                part: "baseline",
            },
        );
    }
    if let Some(t) = b.target {
        mark(
            t,
            Paint {
                face: FaceId::WorkNeedsYou.name(),
                ch: '┃',
                part: "target",
            },
        );
    }
    out
}

/// The Schedule's rows over WIN: the axis (its clock AXIS_NOW), then a row per entry of ROWS: its label indented by
/// depth and fitted to 130 px, its bar on a track of COLS columns from [`TRACK_X`] (a stop per run of one paint), the
/// now-line at NOW_LINE (none: not drawn) and the state's words right of the track.
#[allow(clippy::too_many_arguments)]
pub fn schedule_rows(
    rows: &[SchedRow],
    env: &Env,
    m: &dyn Measure,
    zone: Zone,
    win: &Window,
    cols: u32,
    now_line: Option<f64>,
    axis_now: f64,
) -> Vec<Row> {
    if rows.is_empty() {
        let mut b = RowBuilder::new("none");
        b.push("Nothing scheduled yet.", None);
        return vec![b.finish()];
    }
    let cw = col_px(env);
    let now = now_line.unwrap_or(axis_now);
    let now_c = now_line.and_then(|n| now_col(win, cols, n));
    let mut out = vec![axis_row(env, zone, win, cols, axis_now)];
    for r in rows {
        let key = if r.item.starts_with("machine:") {
            r.item.clone()
        } else {
            format!("sched:{}", r.item)
        };
        let mut b = RowBuilder::new(key);
        let text = format!("{}{}", "  ".repeat(usize::from(r.depth)), r.label);
        let face = if r.bar.is_none() {
            FaceId::WorkTitle.name()
        } else {
            FaceId::WorkLabel.name()
        };
        let label = drgnx_rows::fit::fit_in(m, Some(face), &text, 130.0 + drgnx_rows::fit::SLACK);
        b.push(&label, Some(face));
        let end = b.pos();
        b.prop(0, end, "drgnx-work-id", Value::from(r.item.clone()));
        let Some(bar) = &r.bar else {
            if let Some(c) = now_c {
                now_mark(&mut b, TRACK_X + c * cw);
            }
            out.push(b.finish());
            continue;
        };
        let mut cols_of = paint(bar, win, cols, now);
        if let Some(c) = now_c {
            cols_of[(c as usize).min(cols as usize - 1)] = None;
        }
        let mut c = 0usize;
        while c < cols_of.len() {
            if let Some(c2) = now_c.filter(|&n| n as usize == c) {
                now_mark(&mut b, TRACK_X + c2 * cw);
                c += 1;
                continue;
            }
            let Some(p) = cols_of[c] else {
                c += 1;
                continue;
            };
            let mut z = c + 1;
            while z < cols_of.len() && cols_of[z] == Some(p) && now_c != Some(z as u32) {
                z += 1;
            }
            b.stop(TRACK_X + c as u32 * cw);
            let at = b.pos();
            if env.tty {
                let s: String = std::iter::repeat_n(p.ch, z - c).collect();
                b.push(&s, None);
            } else {
                b.stop(TRACK_X + z as u32 * cw);
            }
            let to = b.pos();
            b.face(at, to, p.face)
                .prop(at, to, "drgnx-work-part", Value::from(p.part));
            c = z;
        }
        b.stop(TRACK_X + cols * cw + 4);
        let words = right_text(bar, zone, now);
        let face = if bar.state.warns() {
            Some(FaceId::WorkNeedsYou.name())
        } else {
            Some(FaceId::WorkMeta.name())
        };
        b.push(&words, face);
        out.push(b.finish());
    }
    out
}
