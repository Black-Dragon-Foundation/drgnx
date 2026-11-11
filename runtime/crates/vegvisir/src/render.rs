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
use drgnx_rows::svg::{Palette, Svg};
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
    /// Each placed item's first row (a port's chip sits in the band above it).
    first_row: BTreeMap<ItemId, usize>,
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
        let mut first_row = BTreeMap::new();
        for (i, v) in items.iter().enumerate() {
            for (_, id) in v {
                first_row.entry(id.clone()).or_insert(i);
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
            first_row,
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
    let e = Edges::new(s, env, &g);
    let mut images = BTreeMap::new();
    let mut rows = Vec::new();
    for &(band, i) in &index.order {
        if band {
            rows.push(band_row(s, index, i, &g, &e, &mut images));
        } else {
            rows.extend(card_rows(s, index, i, &g, m, &e, &mut images));
        }
    }
    Drawn {
        rows,
        images: images.into_iter().collect(),
    }
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

/// The band above layout row I, as high as the band: each tile a curve or a port crosses, an image at its column,
/// else blank.
fn band_row(
    s: &Scene,
    index: &Index,
    i: usize,
    g: &Geo,
    e: &Edges,
    images: &mut BTreeMap<ImageId, String>,
) -> Row {
    let units = s
        .layout
        .bands
        .iter()
        .find(|b| b.row as usize == i)
        .map_or(1, |b| b.height_units);
    let mut b = RowBuilder::new(format!("band:{}", row_key(s, i)));
    let tiles = e.tiles(index, i, g);
    if tiles.is_empty() {
        b.push(" ", Some("drgnx-work-band"));
    }
    for (t, svg, alt) in tiles {
        let id = e.id(&svg);
        images.entry(id).or_insert(svg);
        let start = b.pos();
        b.stop(t * e.tile).image(id, &alt);
        let end = b.pos();
        b.face(start, end, "drgnx-work-band");
    }
    b.height(1, g.px(units).saturating_sub(1));
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

/// The lines of layout row I, one row each: its cards and the lanes that pass through it, by their columns.
fn card_rows(
    s: &Scene,
    index: &Index,
    i: usize,
    g: &Geo,
    m: &dyn Measure,
    e: &Edges,
    images: &mut BTreeMap<ImageId, String>,
) -> Vec<Row> {
    let r = &s.layout.rows[i];
    let n = row_lines(r);
    let line_px = g.px(r.height_units) / n;
    let label = layer_label(s, index, i);
    let ids = &index.items[i];
    let cards: Vec<(&ItemId, Vec<Line>)> = ids
        .iter()
        .filter_map(|id| s.items.get(id).map(|it| (id, card_lines(s, it))))
        .collect();
    let lanes: Vec<(u32, ImageId, String)> = e
        .lanes(i, g)
        .into_iter()
        .map(|(col, svg, alt)| {
            let id = e.id(&svg);
            images.entry(id).or_insert(svg);
            (col, id, alt)
        })
        .collect();
    // the cards then the lanes, by column (a stable sort: a card before a lane at its column)
    let mut parts: Vec<(u32, Part)> = cards
        .iter()
        .enumerate()
        .map(|(k, (id, _))| {
            let x = s.layout.at.get(*id).map_or(0, |r| r.x);
            (g.margin + g.px(x), Part::Card(k))
        })
        .chain(lanes.iter().enumerate().map(|(k, l)| (l.0, Part::Lane(k))))
        .collect();
    parts.sort_by_key(|p| p.0);
    (0..n)
        .map(|line| {
            let mut b = RowBuilder::new(format!("row:{}:{line}", row_key(s, i)));
            if line == 0 && !label.is_empty() {
                let text = fit_px(m, &label, g.margin.saturating_sub(8));
                b.push(&text, Some("drgnx-work-label"));
            }
            for (_, part) in &parts {
                match *part {
                    Part::Card(k) => {
                        let (id, lines) = &cards[k];
                        segment(&mut b, s, id, lines, line as usize, g, m);
                    }
                    Part::Lane(k) => {
                        let (col, id, alt) = &lanes[k];
                        b.stop(*col).image(*id, alt);
                    }
                }
            }
            b.height(1, line_px.saturating_sub(1));
            b.finish()
        })
        .collect()
}

/// What a card row's line holds at a column: a card or a lane (by its index).
#[derive(Clone, Copy)]
enum Part {
    Card(usize),
    Lane(usize),
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
        } else if st.starts_with("draining")
            || st.starts_with("preempting")
            || st.starts_with("sleeping")
        {
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
    if runner.is_some_and(|r| r.mac) {
        l.push(" macOS", Some("drgnx-runners-os"));
    }
    if !extra.is_empty() {
        l.push(format!(" · {}", extra.join(" · ")), None);
    }
    if it.warn {
        l.push(" ⚠", Some("drgnx-work-overlap"));
    }
    l
}

// ---- the edges: band tiles and lanes -----------------------------------------------------------------------------

/// The width of an edge tile, logical px: any width from 128 to 256 costs the same to raster, so it is a layout
/// choice.
pub const TILE: u32 = 192;

/// An edge on the selection's chain: drawn in the accent, or (an edit) in its agent's colour, one px wider.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mark {
    Accent,
    Agent(u8),
}

/// What the edges are drawn from: the chain's marks, each agent's colour number, the labels.
struct Edges<'a> {
    s: &'a Scene<'a>,
    chain: BTreeMap<(&'a ItemId, &'a ItemId, EdgeKind), Mark>,
    palette: &'a Palette,
    epoch: u64,
    /// A card line's text height and ascent percent.
    line: (u32, u32),
    tile: u32,
}

/// An edge kind's look off the chain: (palette role, width, dash), logical px. Every kind differs from every other
/// in width or dash, so colour is never the only difference; `agent` is the agent's own colour.
fn stroke(kind: EdgeKind) -> (&'static str, f32, &'static [f32]) {
    match kind {
        EdgeKind::Edits => ("edit", 2.0, &[]),
        EdgeKind::Reads => ("agent", 1.5, &[1.5, 4.0]),
        EdgeKind::RunsOn => ("edge", 1.0, &[6.0, 3.0, 1.0, 3.0]),
        EdgeKind::BasedOn => ("edge", 1.0, &[4.0, 2.0]),
        EdgeKind::Overlap => ("warn", 2.0, &[6.0, 4.0]),
        EdgeKind::ReadVsEdit => ("warn", 1.0, &[2.0, 2.0]),
        EdgeKind::CameFrom | EdgeKind::Manages => ("edge", 1.0, &[]),
    }
}

/// An edge kind in words, for an image's alternative text.
fn kind_words(kind: EdgeKind) -> &'static str {
    match kind {
        EdgeKind::CameFrom => "came from",
        EdgeKind::Edits => "edits",
        EdgeKind::Reads => "reads",
        EdgeKind::RunsOn => "runs on",
        EdgeKind::BasedOn => "based on",
        EdgeKind::Overlap => "overlaps",
        EdgeKind::ReadVsEdit => "reads what another edits",
        EdgeKind::Manages => "manages",
    }
}

const AGENT_ROLES: [&str; 6] = [
    "agent-1", "agent-2", "agent-3", "agent-4", "agent-5", "agent-6",
];

impl<'a> Edges<'a> {
    fn new(s: &'a Scene<'a>, env: &'a Env, g: &Geo) -> Self {
        let mut chain = BTreeMap::new();
        for e in s.chain {
            let owner = (e.kind == EdgeKind::Edits)
                .then(|| {
                    s.edges
                        .iter()
                        .find(|c| c.kind == EdgeKind::CameFrom && c.to == e.from)
                        .and_then(|c| s.items.get(&c.from))
                        .filter(|it| matches!(it.kind, Kind::Agent | Kind::Subagent))
                        .map(agent_number)
                })
                .flatten();
            chain.insert(
                (&e.from, &e.to, e.kind),
                owner.map_or(Mark::Accent, Mark::Agent),
            );
        }
        Edges {
            s,
            chain,
            palette: env.palette,
            epoch: env.epoch,
            line: env.line,
            tile: (TILE as f32 * g.scale).round() as u32,
        }
    }

    fn label(&self, id: &ItemId) -> String {
        self.s
            .items
            .get(id)
            .map_or_else(|| id.0.clone(), |it| it.label.clone())
    }

    /// An edge's stroke: (palette role, width, dash) in logical px; on the chain the accent (an edit: its agent's
    /// colour), one px wider.
    fn look(
        &self,
        from: &ItemId,
        to: &ItemId,
        kind: EdgeKind,
    ) -> (&'static str, f32, &'static [f32]) {
        let (role, width, dash) = stroke(kind);
        let mark = self.chain.get(&(from, to, kind)).copied();
        let agent = match mark {
            Some(Mark::Agent(n)) => Some(n),
            _ => self
                .s
                .items
                .get(from)
                .filter(|it| matches!(it.kind, Kind::Agent | Kind::Subagent))
                .map(agent_number),
        };
        let role = match mark {
            Some(Mark::Agent(n)) => AGENT_ROLES[usize::from(n) - 1],
            Some(Mark::Accent) => "accent",
            None if role == "agent" => agent.map_or("edit", |n| AGENT_ROLES[usize::from(n) - 1]),
            None => role,
        };
        (role, width + if mark.is_some() { 1.0 } else { 0.0 }, dash)
    }

    fn on_chain(&self, seg: &crate::layout::Seg) -> bool {
        self.chain.contains_key(&(&seg.from, &seg.to, seg.kind))
    }

    /// The band above layout row I's tiles: (tile index, svg, alt) for each tile a curve or a port crosses.
    fn tiles(&self, index: &Index, i: usize, g: &Geo) -> Vec<(u32, String, String)> {
        let l = self.s.layout;
        let Some(band) = l.bands.iter().find(|b| b.row as usize == i) else {
            return Vec::new();
        };
        // the ports whose target sits in this row: (centre units, parents)
        let ports: Vec<(u32, usize)> = l
            .ports
            .iter()
            .filter(|p| index.first_row.get(&p.target) == Some(&i))
            .filter_map(|p| {
                l.at.get(&p.target)
                    .map(|r| (r.x + r.w / 2, p.parents.len()))
            })
            .collect();
        let w = i64::from(self.tile);
        let edge_px = |u: u32| i64::from(g.margin + g.px(u));
        let chip_w = i64::from((30.0 * g.scale).round() as u32);
        let seg_in = |s: &crate::layout::Seg, t: i64| {
            let (a, b) = (edge_px(s.x0), edge_px(s.x1));
            a.min(b) < (t + 1) * w + 2 && a.max(b) > t * w - 2
        };
        let port_in = |c: u32, t: i64| {
            let c = edge_px(c);
            c - chip_w / 2 < (t + 1) * w && c + chip_w / 2 > t * w
        };
        let far = band
            .segs
            .iter()
            .flat_map(|s| [edge_px(s.x0), edge_px(s.x1)])
            .chain(ports.iter().map(|(c, _)| edge_px(*c) + chip_w / 2))
            .max()
            .unwrap_or(0);
        let height = g.px(band.height_units);
        let mut out = Vec::new();
        for t in 0..=(far / w) {
            let segs: Vec<&crate::layout::Seg> =
                band.segs.iter().filter(|s| seg_in(s, t)).collect();
            let here: Vec<(u32, usize)> = ports
                .iter()
                .copied()
                .filter(|(c, _)| port_in(*c, t))
                .collect();
            if segs.is_empty() && here.is_empty() {
                continue;
            }
            let mut svg = Svg::new(self.palette, self.tile, height);
            // the chain's curves last: they draw on top
            let (on, off): (Vec<&crate::layout::Seg>, Vec<&crate::layout::Seg>) =
                segs.iter().copied().partition(|s| self.on_chain(s));
            for s in off.iter().chain(on.iter()) {
                let x0 = edge_px(s.x0) - t * w;
                let x1 = edge_px(s.x1) - t * w;
                let h = i64::from(height);
                let d = if s.arc {
                    let c = (0.4 * height as f32).round() as i64;
                    format!("M{x0} {h}C{x0} {c} {x1} {c} {x1} {h}")
                } else {
                    let m = (height as f32 / 2.0).round() as i64;
                    format!("M{x0} 0C{x0} {m} {x1} {m} {x1} {h}")
                };
                let (role, width, dash) = self.look(&s.from, &s.to, s.kind);
                let dash: Vec<f32> = dash.iter().map(|d| d * g.scale).collect();
                svg.path_dashed(&d, width * g.scale, role, &dash);
            }
            for (c, n) in &here {
                let cw = chip_w;
                let ch = i64::from(height.min((12.0 * g.scale).round() as u32));
                let cx = edge_px(*c) - t * w;
                let h = i64::from(height);
                svg.rect(
                    (cx - cw / 2) as f32,
                    (h - ch) as f32,
                    cw as f32,
                    ch as f32,
                    (ch / 2) as f32,
                    "chip-bg",
                );
                svg.label(
                    cx as f32,
                    (h - (ch as f32 * 0.22).round() as i64) as f32,
                    (ch as f32 * 0.75).round().max(6.0),
                    "chip-fg",
                    &format!("↑ {n}"),
                );
            }
            let words: Vec<String> = segs
                .iter()
                .map(|s| {
                    format!(
                        "{} → {} ({})",
                        self.label(&s.from),
                        self.label(&s.to),
                        kind_words(s.kind)
                    )
                })
                .chain(
                    here.iter()
                        .map(|(_, n)| format!("{n} more arrive by a port")),
                )
                .collect();
            out.push((
                u32::try_from(t).unwrap_or(0),
                svg.finish(),
                format!("Edges: {}", words.join(", ")),
            ));
        }
        out
    }

    /// The lanes of layout row I: (column px, svg, alt), one image per column: the widest stroke's (the chain's,
    /// when one is on it), its words naming every lane there.
    fn lanes(&self, i: usize, g: &Geo) -> Vec<(u32, String, String)> {
        let mut by_x: Vec<(u32, Vec<&crate::layout::Lane>)> = Vec::new();
        for lane in self.s.layout.lanes.iter().filter(|l| l.row as usize == i) {
            match by_x.iter_mut().find(|(x, _)| *x == lane.x) {
                Some((_, v)) => v.push(lane),
                None => by_x.push((lane.x, vec![lane])),
            }
        }
        let (height, _) = self.line;
        by_x.into_iter()
            .map(|(x, at)| {
                let width = |l: &crate::layout::Lane| self.look(&l.from, &l.to, l.kind).1;
                let lane =
                    at.iter().skip(1).fold(
                        at[0],
                        |best, l| if width(l) > width(best) { l } else { best },
                    );
                let (role, w, dash) = self.look(&lane.from, &lane.to, lane.kind);
                let px = (w.max(2.0) * g.scale).round() as u32;
                let mut svg = Svg::new(self.palette, px, height);
                let dash: Vec<f32> = dash.iter().map(|d| d * g.scale).collect();
                svg.path_dashed(
                    &format!("M{} 0V{height}", px as f32 / 2.0),
                    w * g.scale,
                    role,
                    &dash,
                );
                let alt = at
                    .iter()
                    .map(|l| {
                        format!(
                            "Edge {} → {} ({})",
                            self.label(&l.from),
                            self.label(&l.to),
                            kind_words(l.kind)
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("; ");
                (
                    (g.margin + g.px(x)).saturating_sub(px / 2),
                    svg.finish(),
                    alt,
                )
            })
            .collect()
    }

    fn id(&self, svg: &str) -> ImageId {
        ImageId::of(svg.as_bytes(), self.epoch)
    }
}

// ---- the strip ---------------------------------------------------------------------------------------------------

/// The needs-you strip (the header line), one row `strip`: a chip with its jump key for each of the first nine
/// entries (the cards, then the agents that need you with no card), +N for the rest, and the MACHINES' load at the
/// right edge of the view's width.
pub fn strip(
    s: &Scene,
    needs: &[crate::NeedsYou],
    machines: &[Item],
    env: &Env,
    m: &dyn Measure,
) -> Row {
    let covered: BTreeSet<&ItemId> = needs.iter().flat_map(|n| n.about.iter()).collect();
    let mut entries: Vec<String> = needs.iter().map(|n| n.text.clone()).collect();
    entries.extend(
        s.items
            .values()
            .filter(|it| {
                it.kind == Kind::Agent
                    && it.fields.state == Some(State::NeedsYou)
                    && !covered.contains(&it.id)
            })
            .map(|it| format!("{} needs you", it.label)),
    );
    let mut b = RowBuilder::new("strip");
    for (i, e) in entries.iter().take(9).enumerate() {
        if i > 0 {
            b.push(" ", None);
        }
        b.push(
            &format!(" ⚑ {e}  g{} ", i + 1),
            Some("drgnx-work-needs-you"),
        );
    }
    if entries.len() > 9 {
        b.push(
            &format!(" +{} ", entries.len() - 9),
            Some("drgnx-work-needs-you"),
        );
    }
    let chips: Vec<String> = machines
        .iter()
        .filter(|it| it.kind == Kind::Machine)
        .map(|it| {
            let (used, total) = it.fields.slots.unwrap_or((0, 0));
            let cost = it
                .fields
                .runner
                .as_ref()
                .and_then(|r| r.cost.as_ref())
                .map_or(String::new(), |c| format!(" · cloud {c}"));
            format!(" {} {used}/{total}{cost} ", it.label)
        })
        .collect();
    let tail = chips.join(" ");
    let w = fit::width(m, ROLE, &tail).ceil() as u32;
    b.stop(env.width_px.saturating_sub(w));
    for (i, c) in chips.iter().enumerate() {
        if i > 0 {
            b.push(" ", None);
        }
        b.push(c, Some("drgnx-work-chip"));
    }
    b.finish()
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Fields;
    use crate::{Item, ItemId, Kind, RunnerFact};

    fn machine(state: &str, mac: bool) -> Item {
        Item {
            id: ItemId("machine:mini".into()),
            kind: Kind::Machine,
            label: "mini".into(),
            live: true,
            block: None,
            parent: None,
            order: 0,
            warn: false,
            needs_you: false,
            shared: false,
            fields: Fields {
                slots: Some((1, 2)),
                runner: Some(RunnerFact {
                    trust: "mine".into(),
                    state: state.into(),
                    jobs: 1,
                    icon: "monitor".into(),
                    cost: None,
                    mac,
                }),
                ..Fields::default()
            },
        }
    }

    /// [D] A Mac runner's chip: the `macOS` chip in the code face after its name, then its load; a Mac that went quiet
    /// on battery (`sleeping`) has the subtle dot, not the error one. Other machines have no chip.
    #[test]
    fn a_mac_runner_has_the_macos_chip_and_a_sleeping_dot() {
        let l = chip_line(&machine("ready", true));
        assert!(l.text().ends_with(" mini macOS · 1/2"), "{:?}", l.text());
        assert!(l.0.contains(&(" macOS".to_string(), Some("drgnx-runners-os"))));
        assert!(!chip_line(&machine("ready", false)).text().contains("macOS"));
        assert_eq!(dot(&machine("sleeping", true)).1, "drgnx-runners-subtle");
        assert_eq!(dot(&machine("unreachable", true)).1, "drgnx-runners-error");
    }
}
