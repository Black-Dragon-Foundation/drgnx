//! The Work map's rows, built in the hub (`docs/develop/work-space.md`, "Rows"): from a [`Layout`], the items and
//! edges it shows, a view's env and a [`Measure`], the rows the editor only inserts (`drgnx-rows`). Card lines with
//! their segments fitted to the card's width, the layer labels, stops at the cards' columns, the rows' heights; on a
//! terminal, or a layout that does not fit, the outline.
//!
//! No I/O and no clock (the job chips' time comes in as [`Scene::now`]): the hub measures with the class's fonts,
//! tests with a fixed advance. What a row holds of the selection (its face, the dimming, the search) is the editor's:
//! each card's text carries `drgnx-work-id`, and the inserter puts the selection over it as its last step.
//!
//! Row keys: `row:LAYER:BLOCK-LINE:SUB:LINE` (one row per text line of a layout row), `band:LAYER:BLOCK-LINE:SUB`
//! (the band above that row), `outline:ID:LINE`, `outline-none` and `notice`.

use std::collections::{BTreeMap, BTreeSet};

use drgnx_rows::fit::{self, Measure};
use drgnx_rows::fit_tty;
use drgnx_rows::svg::Palette;
use drgnx_rows::{ImageId, Row, RowBuilder};
use serde_json::Value;

use crate::layout::{Form, Layout};
use crate::model::{Fields, JobFact, State};
use crate::{Edge, EdgeKind, Item, ItemId, Kind};

/// The layer labels' margin, logical px.
pub const MARGIN: u32 = 84;
/// The six layers' labels, sentence case; the last is short for "Files and machines".
pub const LAYER_NAMES: [&str; 6] = ["You asked", "Specs", "Plans", "Agents", "Branches", "Files"];
/// The font role card text and labels are measured in.
const ROLE: &str = "ui";

/// Whether the map is drawn as an outline: by the layout (a terminal, or a layout that does not fit), or the user's
/// `O` either way.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Outline {
    #[default]
    Auto,
    On,
    Off,
}

/// What a (view, display class) looks like, from its `view/env`.
#[derive(Clone, Debug)]
pub struct Env<'a> {
    /// The editor's env epoch: image ids carry it.
    pub epoch: u64,
    pub scale: f32,
    pub tty: bool,
    /// The character cell, px.
    pub cell: (u32, u32),
    /// The narrowest window's body width, px.
    pub width_px: u32,
    pub palette: &'a Palette,
    pub tty_widths: &'a [(u32, u32, u8)],
    /// A card line's text height in px and the share of it above the baseline, percent (a lane image matches it).
    pub line: (u32, u32),
}

/// What the map shows.
#[derive(Clone, Copy, Debug)]
pub struct Scene<'a> {
    pub items: &'a BTreeMap<ItemId, Item>,
    pub edges: &'a [Edge],
    pub layout: &'a Layout,
    /// Items with a new conclusion (the `new` chip).
    pub new: &'a BTreeSet<ItemId>,
    /// The edges on the selection's chain (drawn in the accent).
    pub chain: &'a [Edge],
    pub outline: Outline,
    /// Seconds since the epoch, for the job chips' elapsed time.
    pub now: u64,
}

/// The rows and the images they name.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Drawn {
    pub rows: Vec<Row>,
    pub images: Vec<(ImageId, String)>,
}

/// A layout's rows in draw order with the items of each, left to right, and the layers' counts: made once per
/// layout (every sort is here), read by each row.
#[derive(Clone, Debug, Default)]
pub struct Index {
    /// Layout row index → its items by their x.
    items: Vec<Vec<ItemId>>,
    /// The keys in y order: (a band?, the layout row's index); each band above its row.
    order: Vec<(bool, usize)>,
    /// Per layer (1–6), its first row's index in draw order.
    first: [Option<usize>; 7],
    /// Per layer, how many items it holds.
    count: [usize; 7],
}

impl Index {
    pub fn of(s: &Scene) -> Index {
        let l = s.layout;
        let mut items: Vec<Vec<(u32, ItemId)>> = vec![Vec::new(); l.rows.len()];
        let mut count = [0; 7];
        for (id, it) in s.items {
            let layer = it.kind.layer();
            count[usize::from(layer)] += 1;
            let rect = l.at.get(id);
            for (i, r) in l.rows.iter().enumerate() {
                let inside = match rect {
                    Some(rc) => rc.y >= r.y && rc.y < r.y + r.height_units,
                    None => r.collapsed,
                };
                if r.layer == layer && inside {
                    items[i].push((rect.map_or(0, |rc| rc.x), id.clone()));
                }
            }
        }
        let items = items
            .into_iter()
            .map(|mut v| {
                v.sort_by_key(|(x, _)| *x);
                v.into_iter().map(|(_, id)| id).collect()
            })
            .collect();
        let mut by_y: Vec<usize> = (0..l.rows.len()).collect();
        by_y.sort_by_key(|&i| l.rows[i].y);
        let mut order = Vec::new();
        let mut first = [None; 7];
        for i in by_y {
            if l.bands.iter().any(|b| b.row as usize == i) {
                order.push((true, i));
            }
            first[usize::from(l.rows[i].layer)].get_or_insert(i);
            order.push((false, i));
        }
        Index {
            items,
            order,
            first,
            count,
        }
    }
}

/// The map's rows: the cards' (or, on a terminal or a layout that does not fit, the outline's).
pub fn rows(s: &Scene, index: &Index, env: &Env, m: &dyn Measure) -> Drawn {
    let outline = match s.outline {
        Outline::On => true,
        Outline::Off => false,
        Outline::Auto => env.tty || !s.layout.fits,
    };
    if outline {
        return Drawn {
            rows: outline_rows(s, env, m),
            images: Vec::new(),
        };
    }
    let g = Geo::new(env);
    let mut out = Drawn::default();
    for &(band, i) in &index.order {
        if band {
            out.rows.push(band_row(s, i, &g));
        } else {
            out.rows.extend(card_rows(s, index, i, &g, m));
        }
    }
    out
}

/// Units and px at one scale.
struct Geo {
    scale: f32,
    margin: u32,
}

impl Geo {
    fn new(env: &Env) -> Geo {
        let scale = if env.scale > 0.0 { env.scale } else { 1.0 };
        Geo {
            scale,
            margin: (MARGIN as f32 * scale).round() as u32,
        }
    }

    /// UNITS (4 logical px each) in device px.
    fn px(&self, units: u32) -> u32 {
        (units as f32 * 4.0 * self.scale).round() as u32
    }
}

fn row_key(s: &Scene, i: usize) -> String {
    let r = &s.layout.rows[i];
    format!("{}:{}:{}", r.layer, r.block_line, r.sub)
}

/// The band above layout row I: blank, as high as the band (its tiles come with the lanes).
fn band_row(s: &Scene, i: usize, g: &Geo) -> Row {
    let units = s
        .layout
        .bands
        .iter()
        .find(|b| b.row as usize == i)
        .map_or(1, |b| b.height_units);
    let mut b = RowBuilder::new(format!("band:{}", row_key(s, i)));
    b.push(" ", Some("drgnx-work-band"))
        .height(1, g.px(units).saturating_sub(1));
    b.finish()
}

/// How many text lines layout row R holds: five for a rich agent row, two for a compact one, else one.
fn row_lines(r: &crate::layout::Row) -> u32 {
    match (r.layer, r.height_units) {
        (4, h) if h >= 20 => 5,
        (4, _) => 2,
        _ => 1,
    }
}

/// The lines of layout row I, one row each.
fn card_rows(s: &Scene, index: &Index, i: usize, g: &Geo, m: &dyn Measure) -> Vec<Row> {
    let r = &s.layout.rows[i];
    let n = row_lines(r);
    let line_px = g.px(r.height_units) / n;
    let label = layer_label(s, index, i);
    let ids = &index.items[i];
    let cards: Vec<(&ItemId, Vec<Line>)> = ids
        .iter()
        .filter_map(|id| s.items.get(id).map(|it| (id, card_lines(s, it))))
        .collect();
    (0..n)
        .map(|line| {
            let mut b = RowBuilder::new(format!("row:{}:{line}", row_key(s, i)));
            if line == 0 && !label.is_empty() {
                let text = fit_px(m, &label, g.margin.saturating_sub(8));
                b.push(&text, Some("drgnx-work-label"));
            }
            for (id, lines) in &cards {
                segment(&mut b, s, id, lines, line as usize, g, m);
            }
            b.height(1, line_px.saturating_sub(1));
            b.finish()
        })
        .collect()
}

/// The label of layout row I's first line: the layer's name on its first row, a collapsed layer's with its count.
fn layer_label(s: &Scene, index: &Index, i: usize) -> String {
    let r = &s.layout.rows[i];
    let name = LAYER_NAMES[usize::from(r.layer.clamp(1, 6)) - 1];
    if r.collapsed {
        format!("{name} · {}", index.count[usize::from(r.layer)])
    } else if index.first[usize::from(r.layer)] == Some(i) {
        name.to_owned()
    } else {
        String::new()
    }
}

/// TEXT cut with an ellipsis to at most PX wide (the editor's `drgnx-view-fit`: no slack of its own).
fn fit_px(m: &dyn Measure, text: &str, px: u32) -> String {
    fit::fit(m, ROLE, text, px as f32 + fit::SLACK)
}

/// One text line of a card: pieces, each in a face or none.
#[derive(Clone, Debug, Default, PartialEq)]
struct Line(Vec<(String, Option<&'static str>)>);

impl Line {
    fn push(&mut self, text: impl Into<String>, face: Option<&'static str>) -> &mut Self {
        self.0.push((text.into(), face));
        self
    }

    fn plain(text: impl Into<String>) -> Line {
        let mut l = Line::default();
        l.push(text, None);
        l
    }

    fn text(&self) -> String {
        self.0.iter().map(|(t, _)| t.as_str()).collect()
    }

    /// Pushed into B cut to the FIT text's first chars (the ellipsis after them has no face).
    fn push_fitted(&self, b: &mut RowBuilder, fitted: &str) {
        let whole = self.text();
        if fitted == whole {
            for (t, f) in &self.0 {
                b.push(t, *f);
            }
            return;
        }
        let mut keep = fitted.chars().count().saturating_sub(1);
        for (t, f) in &self.0 {
            if keep == 0 {
                break;
            }
            let n = t.chars().count();
            if n <= keep {
                b.push(t, *f);
                keep -= n;
            } else {
                let cut: String = t.chars().take(keep).collect();
                b.push(&cut, *f);
                keep = 0;
            }
        }
        b.push(&fit::ELLIPSIS.to_string(), None);
    }
}

/// Line LINE of ID's card at its x, fitted to its width: a stop at its left, its text (the card's face under the
/// text's own), a stop at its right; nothing when the card has fewer lines or no place.
fn segment(
    b: &mut RowBuilder,
    s: &Scene,
    id: &ItemId,
    lines: &[Line],
    line: usize,
    g: &Geo,
    m: &dyn Measure,
) {
    let (Some(rect), Some(l)) = (s.layout.at.get(id), lines.get(line)) else {
        return;
    };
    let left = g.margin + g.px(rect.x);
    let right = g.margin + g.px(rect.x + rect.w);
    let fitted = fit_px(m, &l.text(), (right - left).saturating_sub(10));
    b.stop(left);
    let start = b.pos();
    l.push_fitted(b, &fitted);
    b.stop(right);
    let end = b.pos();
    b.face(start, end, card_face(lines.len(), line));
    b.prop(start, end, "drgnx-work-id", Value::String(id.0.clone()));
}

/// The decoration face of line I of a card of N lines.
fn card_face(n: usize, i: usize) -> &'static str {
    match (n, i) {
        (1, _) => "drgnx-card-single",
        (_, 0) => "drgnx-card-top",
        (n, i) if i + 1 == n => "drgnx-card-bottom",
        _ => "drgnx-card-mid",
    }
}

/// The text lines of IT's card, by its form: five (a rich agent), two (a compact agent or a subagent) or one.
fn card_lines(s: &Scene, it: &Item) -> Vec<Line> {
    match it.kind {
        Kind::Agent if s.layout.form.get(&it.id) == Some(&Form::Rich) => rich_lines(s, it),
        Kind::Agent | Kind::Subagent => compact_lines(s, it),
        _ => vec![chip_line(it)],
    }
}

fn state_name(st: State) -> &'static str {
    match st {
        State::Queued => "queued",
        State::Running => "running",
        State::Waiting => "waiting",
        State::NeedsYou => "needs-you",
        State::Review => "review",
        State::Paused => "paused",
        State::Stalled => "stalled",
        State::Finished => "finished",
    }
}

/// The words of a state: "needs you", or its name.
fn state_word(f: &Fields) -> String {
    match f.state {
        Some(State::NeedsYou) => "needs you".into(),
        Some(st) => state_name(st).into(),
        None => String::new(),
    }
}

fn activity(f: &Fields) -> String {
    f.activity.clone().unwrap_or_else(|| state_word(f))
}

/// The dot of IT's state in its face; a runner's follows the runner's own state.
fn dot(it: &Item) -> (&'static str, &'static str) {
    if let Some(r) = &it.fields.runner {
        let st = r.state.as_str();
        let face = if st == "ready" {
            if r.jobs > 0 {
                "drgnx-runners-running"
            } else {
                "drgnx-runners-ready"
            }
        } else if st.starts_with("benched") {
            "drgnx-runners-out"
        } else if st.starts_with("needs") || st.starts_with("waits for your") {
            "drgnx-runners-attention"
        } else if st.starts_with("unreachable") {
            "drgnx-runners-error"
        } else if st.starts_with("draining") || st.starts_with("preempting") {
            "drgnx-runners-subtle"
        } else {
            "drgnx-runners-out"
        };
        return ("●", face);
    }
    let face = match it.fields.state {
        Some(State::Running) => "drgnx-work-chain",
        Some(State::NeedsYou) => "drgnx-work-needs-you",
        Some(State::Review | State::Stalled) => "drgnx-work-overlap",
        _ => "drgnx-work-dim",
    };
    ("●", face)
}

/// The agent colour number (1–6) of IT.
pub fn agent_number(it: &Item) -> u8 {
    let order = i64::try_from(it.order.max(1)).unwrap_or(1);
    u8::try_from((order - 1).rem_euclid(6) + 1).unwrap_or(1)
}

const AGENT_FACES: [&str; 6] = [
    "drgnx-work-agent-1",
    "drgnx-work-agent-2",
    "drgnx-work-agent-3",
    "drgnx-work-agent-4",
    "drgnx-work-agent-5",
    "drgnx-work-agent-6",
];

/// The agent badge: the model's initial in the agent's colour.
fn badge(it: &Item) -> (String, &'static str) {
    let initial = it
        .fields
        .model
        .as_deref()
        .and_then(|m| m.chars().next())
        .map_or("?".to_owned(), |c| c.to_uppercase().collect());
    (initial, AGENT_FACES[usize::from(agent_number(it)) - 1])
}

/// The item an overlap edge joins ID to, as "model · label".
fn partner(s: &Scene, id: &ItemId) -> Option<String> {
    let e = s
        .edges
        .iter()
        .find(|e| e.kind == EdgeKind::Overlap && (e.from == *id || e.to == *id))?;
    let other = if e.from == *id { &e.to } else { &e.from };
    let it = s.items.get(other)?;
    Some(match &it.fields.model {
        Some(m) => format!("{m} · {}", it.label),
        None => it.label.clone(),
    })
}

/// The agent card's job chip: "job · NAME · M:SS/Nm" at NOW, or "job · NAME · waiting".
fn job_chip(job: &JobFact, now: u64) -> String {
    if job.state == "waiting" {
        return format!("job · {} · waiting", job.name);
    }
    let secs = now.saturating_sub(job.started);
    let limit = job.limit_min.map_or(String::new(), |l| format!("/{l}m"));
    format!(
        "job · {} · {}:{:02}{limit}",
        job.runner.as_deref().unwrap_or(&job.name),
        secs / 60,
        secs % 60
    )
}

fn new_chip(s: &Scene, it: &Item, l: &mut Line) {
    if s.new.contains(&it.id) {
        l.push(" new ", Some("drgnx-work-new"));
    }
}

/// The five lines of a rich agent card: who, its task, how it is going, its latest conclusion, the flag.
fn rich_lines(s: &Scene, it: &Item) -> Vec<Line> {
    let f = &it.fields;
    let (d, dface) = dot(it);
    let (bdg, bface) = badge(it);
    let mut who = Line::default();
    who.push(d, Some(dface))
        .push(" ", None)
        .push(bdg, Some(bface))
        .push("  ", None);
    if let Some(m) = &f.model {
        who.push(format!("{m} · "), None);
    }
    who.push(it.label.clone(), None);
    new_chip(s, it, &mut who);
    let mut going = vec![activity(f)];
    going.extend(f.minutes.map(|m| format!("{m} min")));
    going.extend(f.spend.clone());
    going.extend(f.progress.map(|(a, b)| format!("{a}/{b}")));
    going.extend(f.context.filter(|c| *c > 80).map(|c| format!("ctx {c} %")));
    going.extend(f.job.as_ref().map(|j| job_chip(j, s.now)));
    let flag = if it.warn {
        let mut l = Line::default();
        let text = match partner(s, &it.id) {
            Some(p) => format!("⚠ shares files with {p}"),
            None => "⚠ overlap".into(),
        };
        l.push(text, Some("drgnx-work-overlap"));
        l
    } else {
        let mut bits = Vec::new();
        bits.extend(f.reads.map(|r| format!("reads {r}")));
        bits.extend(f.edits.map(|(n, p, m)| format!("edits {n} (+{p} −{m})")));
        Line::plain(bits.join(" · "))
    };
    vec![
        who,
        Line::plain(f.task.clone().unwrap_or_default()),
        Line::plain(going.join(" · ")),
        Line::plain(
            f.conclusion
                .as_ref()
                .map_or(String::new(), |c| format!("→ {c}")),
        ),
        flag,
    ]
}

/// The two lines of a compact agent card or a subagent: who, and how it is going (with the overlap mark).
fn compact_lines(s: &Scene, it: &Item) -> Vec<Line> {
    let f = &it.fields;
    let (d, dface) = dot(it);
    let (bdg, bface) = badge(it);
    let mut who = Line::default();
    who.push(d, Some(dface))
        .push(" ", None)
        .push(bdg, Some(bface))
        .push(" ", None);
    if let (Some(m), Kind::Agent) = (&f.model, it.kind) {
        who.push(format!("{m} · "), None);
    }
    who.push(it.label.clone(), None);
    new_chip(s, it, &mut who);
    let mut bits = vec![activity(f)];
    bits.extend(f.minutes.map(|m| format!("{m}m")));
    bits.extend(f.job.as_ref().map(|j| job_chip(j, s.now)));
    let mut going = Line::plain(bits.join(" "));
    if it.warn {
        going.push(" ⚠", Some("drgnx-work-overlap"));
    }
    vec![who, going]
}

/// A runner's icon by its kind (the default glyphs of `drgnx-face-glyphs`).
fn icon(name: &str) -> &'static str {
    match name {
        "monitor" | "laptop" => "▭",
        "cloud" => "☁",
        _ => "☰",
    }
}

/// The one line of a chip item: ask, spec, plan, branch, file or machine.
fn chip_line(it: &Item) -> Line {
    let f = &it.fields;
    let mut l = Line::default();
    if it.needs_you {
        l.push("⚑ ", Some("drgnx-work-needs-you"));
    }
    let runner = f.runner.as_ref().filter(|_| it.kind == Kind::Machine);
    if let Some(r) = runner {
        let (d, dface) = dot(it);
        l.push(d, Some(dface))
            .push(format!(" {}", icon(&r.icon)), None);
    } else {
        l.push(
            match it.kind {
                Kind::Ask => "❝",
                Kind::Spec => "◫",
                Kind::Plan => "☰",
                Kind::Branch => "⑂",
                Kind::File => "▭",
                Kind::Machine => "▣",
                _ => "·",
            },
            None,
        );
    }
    let extra: Vec<String> = match it.kind {
        Kind::Plan => f
            .progress
            .map(|(a, b)| format!("{a}/{b}"))
            .into_iter()
            .collect(),
        Kind::Branch => f
            .edits
            .map(|e| format!("edits {}", e.0))
            .into_iter()
            .collect(),
        Kind::File => f
            .change
            .map(|(p, m)| format!("+{p} −{m}"))
            .into_iter()
            .collect(),
        Kind::Machine => f
            .slots
            .map(|(u, t)| format!("{u}/{t}"))
            .into_iter()
            .chain(runner.and_then(|r| r.cost.clone()))
            .collect(),
        _ => Vec::new(),
    };
    l.push(format!(" {}", it.label), None);
    if !extra.is_empty() {
        l.push(format!(" · {}", extra.join(" · ")), None);
    }
    if it.warn {
        l.push(" ⚠", Some("drgnx-work-overlap"));
    }
    l
}

// ---- the outline -------------------------------------------------------------------------------------------------

/// The outline's rows: a notice when the layout did not fit, then a block per agent in plan order (or one line when
/// none works), each line at most the view's columns wide.
fn outline_rows(s: &Scene, env: &Env, m: &dyn Measure) -> Vec<Row> {
    let cols = (env.width_px / env.cell.0.max(1)).max(if env.tty { 1 } else { 40 }) as usize;
    let fit = |l: &Line| -> String {
        if env.tty {
            fit_tty::fit(&l.text(), cols, env.tty_widths)
        } else {
            fit_px(
                m,
                &l.text(),
                u32::try_from(cols).unwrap_or(u32::MAX) * env.cell.0.max(1),
            )
        }
    };
    let mut out = Vec::new();
    if !s.layout.fits {
        let mut b = RowBuilder::new("notice");
        b.push(
            "Too many to draw at this width · O back to the map, at a wider tile",
            None,
        );
        out.push(b.finish());
    }
    let ids = outline_ids(s);
    if ids.is_empty() {
        let mut b = RowBuilder::new("outline-none");
        b.push("No agents are working.", None);
        out.push(b.finish());
    }
    for id in ids {
        for (n, l) in outline_block(s, id, cols, env).iter().enumerate() {
            let mut b = RowBuilder::new(format!("outline:{}:{n}", id.0));
            l.push_fitted(&mut b, &fit(l));
            out.push(b.finish());
        }
    }
    out
}

/// The agents the outline shows: by their plan's rank (no plan last), then start order, then id.
fn outline_ids<'a>(s: &Scene<'a>) -> Vec<&'a ItemId> {
    let rank = |it: &Item| {
        it.block
            .as_ref()
            .map_or(u64::MAX, |b| s.items.get(b).map_or(0, |p| p.order))
    };
    let mut v: Vec<&Item> = s
        .items
        .values()
        .filter(|it| it.kind == Kind::Agent)
        .collect();
    v.sort_by(|a, b| (rank(a), a.order, &a.id).cmp(&(rank(b), b.order, &b.id)));
    v.into_iter().map(|it| &it.id).collect()
}

/// The item ID came from: the first came-from edge into it, by id.
fn parent<'a>(s: &Scene<'a>, id: &ItemId) -> Option<&'a ItemId> {
    s.edges
        .iter()
        .filter(|e| e.kind == EdgeKind::CameFrom && e.to == *id)
        .map(|e| &e.from)
        .min()
}

/// ID's why-chain: you: "ask" › spec › plan › task.
fn why(s: &Scene, id: &ItemId) -> String {
    let mut chain = Vec::new();
    let mut cur = parent(s, id);
    for _ in 0..7 {
        let Some(c) = cur else { break };
        if let Some(it) = s.items.get(c) {
            chain.push(if it.kind == Kind::Ask {
                format!("you: \"{}\"", it.label)
            } else {
                it.label.clone()
            });
        }
        cur = parent(s, c);
    }
    chain.reverse();
    if let Some(t) = s.items.get(id).and_then(|it| it.fields.task.clone()) {
        chain.push(t);
    }
    chain.join(" › ")
}

/// ID's touches: its branch, machine, edits and reads.
fn touches(s: &Scene, id: &ItemId) -> String {
    let mut out = Vec::new();
    for e in s.edges.iter().filter(|e| e.from == *id) {
        let Some(to) = s.items.get(&e.to) else {
            continue;
        };
        match e.kind {
            EdgeKind::CameFrom if to.kind == Kind::Branch => out.push(to.label.clone()),
            EdgeKind::RunsOn => out.push(format!("{} slot", to.label)),
            _ => {}
        }
    }
    if let Some(it) = s.items.get(id) {
        out.extend(
            it.fields
                .edits
                .map(|(n, p, m)| format!("edits {n} (+{p} −{m})")),
        );
        out.extend(it.fields.reads.map(|r| format!("reads {r}")));
    }
    out.join(" · ")
}

/// Agent ID's outline block: its line, why, touches and conclusion.
fn outline_block(s: &Scene, id: &ItemId, cols: usize, env: &Env) -> Vec<Line> {
    let Some(it) = s.items.get(id) else {
        return Vec::new();
    };
    let f = &it.fields;
    let (d, dface) = dot(it);
    let mut head = Line::default();
    head.push(d, Some(dface)).push(" ", None);
    if let Some(m) = &f.model {
        head.push(format!("{m} · "), None);
    }
    let mut bits = vec![activity(f)];
    bits.extend(f.minutes.map(|m| format!("{m}m")));
    bits.extend(f.spend.clone());
    bits.extend(f.progress.map(|(a, b)| format!("{a}/{b}")));
    head.push(format!("{}  {}", it.label, bits.join(" ")), None);
    if it.warn {
        let flag = match partner(s, id) {
            Some(p) => format!("⚠ shares files with {p}"),
            None => "⚠ overlap".into(),
        };
        let hw = fit_tty::width(&head.text(), env.tty_widths);
        let fw = fit_tty::width(&flag, env.tty_widths);
        if hw + 2 + fw <= cols {
            head.push(" ".repeat(cols - hw - fw), None)
                .push(flag, Some("drgnx-work-overlap"));
        }
    }
    let mut lines = vec![
        head,
        Line::plain(format!("   why:      {}", why(s, id))),
        Line::plain(format!("   touches:  {}", touches(s, id))),
    ];
    if let Some(c) = &f.conclusion {
        lines.push(Line::plain(format!("   → {c}")));
    }
    lines
}
