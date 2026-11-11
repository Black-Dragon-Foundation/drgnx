//! The Flow lens as rows and a model (`work/flow/subscribe`; docs/develop/orchestration.md, "The Flow lens"): a plan
//! run's tasks as rows, the gates as columns (Brief, Red first, Build, Author check, Merge batch, Review), each cell a
//! chip of the gate's state; under them the merge batch, the line gate and the rule pack.  Pure: the facts in, the
//! cells, the model and the rows out.
//!
//! The model is the lens's own: a `task` node per task with the `flow` form's links (up and down), the lists `tasks`
//! and `held` (the tasks a gate holds: the needs-you chips).

use crate::view::model::Doc;
use drgnx_rows::fit::Measure;
use drgnx_rows::{ImageId, Row, RowBuilder};
use runstav::methods::view::ViewEnv;
use serde_json::{Map, Value, json};
use vordr::evidence::Evidence;
use vordr::gates::{State, checks, selector_of, state};
use vordr::pack::Pack;
use vordr::rows::{Verdict, failing};

/// The gate columns, left to right.
pub(crate) const GATES: [&str; 6] = [
    "Brief",
    "Red first",
    "Build",
    "Author check",
    "Merge batch",
    "Review",
];

/// A gate's state in one cell.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Chip {
    Ok,
    /// Running (in the accent).
    Run,
    /// Held: the user's attention.
    Held,
    Err,
    /// Not yet (subtle).
    Wait,
    /// The pack has no such gate.
    Na,
}

/// The Flow's text faces (drgnx-work-flow.el: the UI font, the theme's tokens).
const TEXT: &str = "drgnx-work-flow-text";
const LABEL: &str = "drgnx-work-flow-label";
const HEAD: &str = "drgnx-work-flow-heading";
/// A key's badge (the keycap).
const KEY: &str = "drgnx-work-flow-key";
/// A card's fill (drgnx-work-flow.el: the panel's surface), and the text faces on it.
const CARD: &str = "drgnx-work-flow-card";
const CARD_TEXT: &str = "drgnx-work-flow-card-text";
const CARD_LABEL: &str = "drgnx-work-flow-card-label";
const CARD_HEAD: &str = "drgnx-work-flow-card-heading";
/// The text property that marks a block Glitnir draws over the rows (`glitnir-blocks`): `["ring", ID, X0, X1]` on a
/// card's span of each of its rows, `["rule", KEY, X0, X1]` on a row with a hairline under it (device px).
const BLOCK: &str = "drgnx-work-flow-block";
/// The font role the Flow's text is measured in (the UI font: `drgnx-view-env-roles`).
const ROLE: &str = "card";

impl Chip {
    /// The chip's face.
    pub(crate) fn face(self) -> &'static str {
        match self {
            Chip::Ok => "drgnx-work-flow-chip-ok",
            Chip::Run => "drgnx-work-flow-chip-run",
            Chip::Held => "drgnx-work-flow-chip-held",
            Chip::Err => "drgnx-work-flow-chip-err",
            Chip::Wait => "drgnx-work-flow-chip-wait",
            Chip::Na => LABEL,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Chip::Ok => "ok",
            Chip::Run => "run",
            Chip::Held => "held",
            Chip::Err => "err",
            Chip::Wait => "wait",
            Chip::Na => "na",
        }
    }
}

/// One cell: its chip and its words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Cell {
    pub chip: Chip,
    pub text: String,
}

fn cell(chip: Chip, text: impl Into<String>) -> Cell {
    Cell {
        chip,
        text: text.into(),
    }
}

/// Where a task stands in the merge queue.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) enum Queue {
    #[default]
    None,
    /// Its gates passed; waiting for a batch.
    Ready,
    /// In the batch being checked.
    Batch,
}

/// What the hub knows of one task.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct TaskFacts {
    pub id: String,
    pub n: i64,
    pub title: String,
    pub status: String,
    /// The agent's label.
    pub agent: Option<String>,
    /// Its evidence, oldest first.
    pub evidence: Vec<Evidence>,
    pub queue: Queue,
    /// Why a gate holds it (its open `gate` card), when one does.
    pub held: Option<String>,
    /// That card's id (its actions: `job/card`).
    pub card: Option<i64>,
}

/// One task's row.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Task {
    pub id: String,
    pub label: String,
    pub title: String,
    pub agent: Option<String>,
    pub cells: [Cell; 6],
    pub held: Option<String>,
    pub card: Option<i64>,
}

/// One member of the merge batch.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Member {
    pub label: String,
    pub title: String,
    /// Its tip, short.
    pub tip: String,
    /// What the queue said to it last (its turn).
    pub said: Option<String>,
}

/// A gate's runs at one tree: the batch's affected groups at the combined tree, or the push tiers at the line's head.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Runs {
    /// The tree the gate judged.
    pub at: String,
    /// The checks it needs there.
    pub checks: Vec<vordr::pack::Check>,
    /// Their runs, oldest first.
    pub evidence: Vec<Evidence>,
}

/// The lens's facts: the job, its pack, its tasks, the batch and the line gate.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Flow {
    pub job: String,
    pub title: String,
    pub pack: Option<Pack>,
    pub tasks: Vec<TaskFacts>,
    /// The merge batch being checked.
    pub batch: Vec<Member>,
    /// Its affected groups' runs, once the groups gate judged it.
    pub groups: Option<Runs>,
    /// The push tiers' runs at the line's head, once a push was asked.
    pub push: Option<Runs>,
    /// The machines' load: (label, slots used, slots), as the map's strip has them.
    pub machines: Vec<(String, u32, u32)>,
    /// The run's spend in USD and its plan's USD budget, when it has one.
    pub cost: Option<(f64, Option<f64>)>,
}

/// What one Flow view shows: the lens, one task's detail tile, or the Rules tile.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Part {
    Lens,
    Detail(String),
    Rules,
}

/// TASK's cells under PACK (none: the job runs no gates).
pub(crate) fn cells(t: &TaskFacts, pack: Option<&Pack>) -> [Cell; 6] {
    let on = |id: &str| pack.is_some_and(|p| p.on(id));
    let queued = matches!(t.status.as_str(), "" | "open" | "queued");
    let done = matches!(t.status.as_str(), "done" | "merged");
    let brief = if queued {
        cell(Chip::Wait, "queued")
    } else {
        cell(Chip::Ok, "sent")
    };
    // red first: the oldest red run's failing rows
    let red = t
        .evidence
        .iter()
        .find(|e| e.kind == "red" && failing(&e.rows).next().is_some());
    let red_first = if !on("red-first") {
        cell(Chip::Na, "—")
    } else if let Some(r) = red {
        cell(
            Chip::Ok,
            format!("{} failed · base", failing(&r.rows).count()),
        )
    } else if t.status == "in-review" || t.held.is_some() {
        cell(Chip::Held, "no red · held")
    } else if queued {
        cell(Chip::Wait, "—")
    } else {
        cell(Chip::Run, "editing")
    };
    // build: the newest run's rows
    let build = match t.evidence.iter().rev().find(|e| e.kind != "waiver") {
        None if queued => cell(Chip::Wait, "—"),
        None => cell(Chip::Wait, "no run"),
        Some(e) => {
            let fails = failing(&e.rows).count();
            if fails > 0 && e.kind != "red" {
                cell(Chip::Err, format!("{fails} fail"))
            } else if e.kind == "red" {
                cell(Chip::Wait, "red only")
            } else {
                let pass = e.rows.iter().filter(|r| r.verdict == Verdict::Pass).count();
                cell(Chip::Ok, format!("{pass} pass"))
            }
        }
    };
    // the author check: its checks' newest runs, by selector
    let author = match pack.map(checks).filter(|c| !c.is_empty()) {
        None if on("author-check") => cell(Chip::Na, "own tests"),
        None => cell(Chip::Na, "—"),
        Some(cs) => {
            let states: Vec<State> = cs
                .iter()
                .map(|c| {
                    let sel = selector_of(c);
                    let newest = t.evidence.iter().rev().find(|e| e.facts.selector == sel);
                    newest.map_or(State::Missing, |e| {
                        state(&t.evidence, &e.facts.tree_key, &sel)
                    })
                })
                .collect();
            let green = states.iter().filter(|s| **s == State::Green).count();
            let text = format!("{green}/{}", cs.len());
            if states.iter().any(|s| matches!(s, State::Red(_))) {
                cell(Chip::Err, text)
            } else if green == cs.len() {
                cell(Chip::Ok, text)
            } else if red_first.chip == Chip::Held {
                // the author check runs at the tip once red first has its red
                cell(Chip::Na, "waits red")
            } else if queued {
                cell(Chip::Wait, "—")
            } else {
                cell(Chip::Run, text)
            }
        }
    };
    let merge = if done {
        cell(Chip::Ok, "merged")
    } else if t.held.is_some() {
        cell(Chip::Held, "held")
    } else {
        match t.queue {
            Queue::Batch => cell(Chip::Run, "checking"),
            Queue::Ready => cell(Chip::Wait, "ready"),
            Queue::None => cell(Chip::Wait, "—"),
        }
    };
    let review = if on("review") {
        cell(Chip::Wait, "at plan end")
    } else {
        cell(Chip::Na, "—")
    };
    [brief, red_first, build, author, merge, review]
}

/// FLOW's task rows.
pub(crate) fn tasks(flow: &Flow) -> Vec<Task> {
    flow.tasks
        .iter()
        .map(|t| Task {
            id: t.id.clone(),
            label: format!("T{}", t.n),
            title: t.title.clone(),
            agent: t.agent.clone(),
            cells: cells(t, flow.pack.as_ref()),
            held: t.held.clone(),
            card: t.card,
        })
        .collect()
}

/// The lens's model.
pub(crate) fn flow_doc(flow: &Flow) -> Doc {
    let mut d = Doc {
        descriptor: json!({
            "scheme": "links",
            "chain_kinds": [],
            "match_fields": ["label"],
            "lists": ["tasks", "held"],
            "classes": ["selected", "match", "lit", "dim"],
            "flags": [],
            "forms": [{"name": "flow"}],
            "start": "tasks",
        }),
        ..Doc::default()
    };
    let ts = tasks(flow);
    let (mut all, mut held) = (Vec::new(), Vec::new());
    for (i, t) in ts.iter().enumerate() {
        let mut links = Map::new();
        if let Some(up) = i.checked_sub(1).map(|k| &ts[k]) {
            links.insert("up".into(), json!(up.id));
        }
        if let Some(down) = ts.get(i + 1) {
            links.insert("down".into(), json!(down.id));
        }
        let mut fields = vec![
            json!(["label", format!("{} {}", t.label, t.title)]),
            json!(["job", flow.job]),
        ];
        for (g, c) in GATES.iter().zip(&t.cells) {
            fields.push(json!([g, c.chip.name()]));
        }
        if let Some(why) = &t.held {
            fields.push(json!(["held", why]));
            held.push(t.id.clone());
        }
        d.nodes.insert(
            t.id.clone(),
            json!({"id": t.id, "kind": "task", "flags": 0, "navs": {"flow": Value::Object(links)},
                   "fields": fields}),
        );
        all.push(t.id.clone());
    }
    d.lists.insert("tasks".into(), all);
    d.lists.insert("held".into(), held);
    d
}

/// TEXT cut to CHARS characters, an ellipsis last when cut.
fn fit(text: &str, chars: usize) -> String {
    if text.chars().count() <= chars {
        return text.to_owned();
    }
    let mut s: String = text.chars().take(chars.saturating_sub(1)).collect();
    s.push('…');
    s
}

/// TEXT's width in device px in the Flow's font (M measures).
fn text_px(m: &dyn Measure, text: &str) -> u32 {
    drgnx_rows::fit::width(m, ROLE, text).ceil() as u32
}

/// The width CELL of GATE takes as [`draw_cell`] draws it, ICON the icons' size.
fn cell_px(m: &dyn Measure, icon: u32, gate: &str, c: &Cell) -> u32 {
    let sp = text_px(m, " ");
    match c.chip {
        Chip::Wait if c.text == "—" => icon,
        Chip::Na => text_px(m, &c.text),
        Chip::Held => 3 * sp + icon + text_px(m, &c.text),
        Chip::Ok if gate == "Author check" => 3 * sp + icon + text_px(m, &c.text),
        _ => 2 * sp + text_px(m, &c.text),
    }
}

/// The least the task column keeps, in logical px.
const TASK_MIN: f32 = 96.0;

/// The least a gate column keeps when it gives way, in logical px.
const GATE_MIN: f32 = 44.0;

/// The columns' left edges for TS in ENV (device px, M measuring): the task, the agent, then the six gates; and the
/// gates' widths.  Each gate column wants its widest cell or heading, the agent's is its widest agent, each with a gap
/// after.  The task column wants its widest title, up to a third of the window; when the gates' wants don't leave it
/// that, the widest gate columns give way first (their cells are cut, [`fit_cell`]), down to [`GATE_MIN`] each, and
/// only then the titles, down to [`TASK_MIN`].
fn columns(ts: &[Task], env: &ViewEnv, m: &dyn Measure) -> (Vec<u32>, Vec<u32>) {
    let (icon, gap) = (dpx(env, 14.0), dpx(env, 10.0));
    let mut gates: Vec<u32> = GATES
        .iter()
        .map(|g| icon + text_px(m, " ") + text_px(m, g))
        .collect();
    for t in ts {
        for (i, c) in t.cells.iter().enumerate() {
            gates[i] = gates[i].max(cell_px(m, icon, GATES[i], c));
        }
    }
    let agent = ts
        .iter()
        .map(|t| text_px(m, t.agent.as_deref().unwrap_or("—")))
        .chain([text_px(m, "Agent")])
        .max()
        .unwrap_or(0);
    let fixed = agent + gap + gap * gates.len() as u32;
    let title = ts
        .iter()
        .map(|t| text_px(m, &format!("{}  ", t.label)) + text_px(m, &t.title) + gap)
        .max()
        .unwrap_or(0)
        .min(env.width_px / 3)
        .max(dpx(env, TASK_MIN));
    let room = env.width_px.saturating_sub(fixed + title);
    if gates.iter().sum::<u32>() > room {
        // the highest level L with every gate cut to L (but not below its least) fitting ROOM, or the leasts
        let least = dpx(env, GATE_MIN);
        let at_level = |l: u32| -> u32 { gates.iter().map(|&g| g.min(l.max(least))).sum() };
        let (mut lo, mut hi) = (0, gates.iter().copied().max().unwrap_or(0));
        while lo < hi {
            let mid = (lo + hi).div_ceil(2);
            if at_level(mid) <= room {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        gates = gates.iter().map(|&g| g.min(lo.max(least))).collect();
    }
    let right = fixed + gates.iter().sum::<u32>();
    let task = env.width_px.saturating_sub(right).max(dpx(env, TASK_MIN));
    let mut at = vec![0, task];
    let mut x = task + agent + gap;
    for g in &gates {
        at.push(x);
        x += g + gap;
    }
    (at, gates)
}

/// C, a cell of GATE, with its text cut so the cell is at most W device px wide as [`draw_cell`] draws it (M
/// measuring, ICON the icons' size).
fn fit_cell(m: &dyn Measure, icon: u32, gate: &str, c: &Cell, w: u32) -> Cell {
    let px = cell_px(m, icon, gate, c);
    if px <= w || (c.chip == Chip::Wait && c.text == "—") {
        return c.clone();
    }
    let room = w.saturating_sub(px - text_px(m, &c.text));
    Cell {
        text: drgnx_rows::fit::fit(m, ROLE, &c.text, room as f32),
        ..c.clone()
    }
}

/// V logical px in ENV's device px.
fn dpx(env: &ViewEnv, v: f32) -> u32 {
    (f64::from(v) * f64::from(env.scale) + 0.5 + 1e-9).floor() as u32
}

/// The icons one build of rows draws (each image once, for the patch), 14 logical px square.
struct Pics {
    px: u32,
    out: Vec<(ImageId, String)>,
}

impl Pics {
    fn new(env: &ViewEnv) -> Self {
        Pics {
            px: dpx(env, 14.0),
            out: Vec::new(),
        }
    }

    /// Icon NAME here (ALT on a terminal, or where the icon has no file).
    fn put(&mut self, b: &mut RowBuilder, name: &str, alt: &str) {
        match crate::view::icons::svg(name, self.px) {
            Some((id, svg)) => {
                if !self.out.iter().any(|(i, _)| *i == id) {
                    self.out.push((id, svg));
                }
                b.image(id, alt);
            }
            None => {
                b.push(alt, None);
            }
        }
    }
}

/// A chip here: ICON (none: text alone) and TEXT on FACE's tint, the icon in the chip's colour.
fn chip(b: &mut RowBuilder, pics: &mut Pics, icon: Option<(&str, &str)>, text: &str, face: &str) {
    let start = b.pos();
    b.push(" ", None);
    if let Some((name, alt)) = icon {
        pics.put(b, name, alt);
        b.push(" ", None);
    }
    b.push(text, None).push(" ", None);
    let end = b.pos();
    b.face(start, end, face);
}

/// The strip under the run's line, when it has anything to say: a chip per task a gate holds (why, its card's words,
/// carrying the task's id) with its jump key's badge (`g N`: the Nth held task), the push the line gate leaves to the
/// user once its tiers are green; at the window's right edge the run's cost (against its plan's budget) and each
/// machine's load.
fn strip_row(
    flow: &Flow,
    ts: &[Task],
    env: &ViewEnv,
    fonts: &dyn Measure,
    pics: &mut Pics,
) -> Option<Row> {
    let held: Vec<&Task> = ts.iter().filter(|t| t.held.is_some()).collect();
    let push_green = flow
        .push
        .as_ref()
        .is_some_and(|p| tally(p).0 == p.checks.len());
    if held.is_empty() && !push_green && flow.cost.is_none() && flow.machines.is_empty() {
        return None;
    }
    // the right part: the cost, then a chip per machine (" ", icon, " label u/n ")
    let cost = flow.cost.map(|(spent, limit)| match limit {
        Some(l) => format!("${spent:.2} / ${l:.0}"),
        None => format!("${spent:.2}"),
    });
    let machines: Vec<String> = flow
        .machines
        .iter()
        .map(|(label, used, total)| format!("{label} {used}/{total}"))
        .collect();
    let (sp, gap) = (text_px(fonts, " "), dpx(env, 6.0));
    // a chip's width as `chip' draws it: its spaces, its icon (its placeholder counted too) and its text
    let chip_px = |text: &str, icon: bool| {
        2 * sp + text_px(fonts, text) + if icon { 2 * sp + pics.px } else { 0 }
    };
    let mut width = cost.as_ref().map_or(0, |c| chip_px(c, false) + sp + gap)
        + machines
            .iter()
            .map(|m| chip_px(m, true) + sp + gap)
            .sum::<u32>();
    // the left part fits before it: the push's words stay whole, the held tasks' reasons share what is left (each
    // keeps room for a word and its ellipsis); when even that does not fit, the right part gives way
    let push = push_green.then(|| format!("push job/{}? gate green", flow.job));
    let fixed = push.as_ref().map_or(0, |p| chip_px(p, true) + 2 * sp)
        + held
            .iter()
            .enumerate()
            .map(|(i, t)| {
                chip_px(&format!("{} held: ", t.label), true)
                    + text_px(fonts, &format!(" g{} ", i + 1))
                    + 2 * sp
            })
            .sum::<u32>();
    let least = u32::try_from(held.len()).unwrap_or(0) * text_px(fonts, "word…");
    let room_with = |width: u32| {
        if width > 0 {
            env.width_px.saturating_sub(width + dpx(env, 4.0) + gap)
        } else {
            env.width_px
        }
    };
    if room_with(width) < fixed + least {
        width = 0;
    }
    let stop = env.width_px.saturating_sub(width + dpx(env, 4.0));
    let room = room_with(width);
    let each = room.saturating_sub(fixed) / u32::try_from(held.len().max(1)).unwrap_or(1);
    let mut b = RowBuilder::new("needs");
    for (i, t) in held.iter().enumerate() {
        if i > 0 {
            b.push("  ", None);
        }
        let start = b.pos();
        let why = t.held.as_deref().unwrap_or_default();
        let why = drgnx_rows::fit::fit(fonts, ROLE, why, each as f32);
        chip(
            &mut b,
            pics,
            Some(("flag", "⚑")),
            &format!("{} held: {why}", t.label),
            Chip::Held.face(),
        );
        b.push(&format!(" g{} ", i + 1), Some(KEY));
        let end = b.pos();
        b.prop(start, end, "drgnx-work-id", json!(t.id));
    }
    if let Some(p) = &push {
        if !held.is_empty() {
            b.push("  ", None);
        }
        chip(&mut b, pics, Some(("flag", "⚑")), p, Chip::Held.face());
    }
    if width > 0 {
        b.stop(stop);
        if let Some(c) = &cost {
            chip(&mut b, pics, None, c, Chip::Wait.face());
            b.push(" ", None);
        }
        for m in &machines {
            chip(&mut b, pics, Some(("server", "▣")), m, Chip::Wait.face());
            b.push(" ", None);
        }
    }
    Some(b.finish())
}

/// A gate column's icon (Lucide, as the mockup's headings).
fn gate_icon(gate: &str) -> &'static str {
    match gate {
        "Brief" => "file-text",
        "Red first" => "flask-conical",
        "Build" => "pencil",
        "Author check" => "shield",
        "Merge batch" => "git-merge",
        _ => "eye",
    }
}

/// CELL drawn whole at the cursor of B (its column fits it: [`columns`]): a waiting cell with nothing to say is an
/// empty ring; a passed author check carries a check, a held cell a lock; a gate the pack lacks (or one that waits on
/// another) is its words in the label face.
fn draw_cell(b: &mut RowBuilder, pics: &mut Pics, gate: &str, c: &Cell) {
    let text = &c.text;
    match c.chip {
        Chip::Wait if c.text == "—" => {
            let start = b.pos();
            pics.put(b, "circle", "○");
            let end = b.pos();
            b.face(start, end, LABEL);
        }
        Chip::Na => {
            b.push(text, Some(LABEL));
        }
        Chip::Ok if gate == "Author check" => {
            chip(b, pics, Some(("check", "✓")), text, c.chip.face())
        }
        Chip::Held => chip(b, pics, Some(("lock", "!")), text, c.chip.face()),
        _ => chip(b, pics, None, text, c.chip.face()),
    }
}

/// The lens's rows for ENV and the icons they draw: the strip ([`strip_row`]: the needs-you chips, one per held task
/// carrying its id, the push, the cost and the machines), the run's line, the column headings with their icons, a row per task (its id, title, agent and a chip per gate, carrying
/// the task's id and its gate card), then the merge batch ([`batch_rows`]) and the line gate ([`line_rows`]).  FONTS
/// measure the columns ([`columns`]).  The rule pack is its own tile ([`rules_rows`]).
pub(crate) fn flow_rows(
    flow: &Flow,
    env: &ViewEnv,
    fonts: &dyn Measure,
) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let mut pics = Pics::new(env);
    let ts = tasks(flow);
    let (at, widths) = columns(&ts, env, fonts);
    let (gap, icon) = (dpx(env, 10.0), dpx(env, 14.0));
    let done = ts.iter().filter(|t| t.cells[4].chip == Chip::Ok).count();
    let mut head = RowBuilder::new("head");
    pics.put(&mut head, "list-checks", "≡");
    head.push(" ", None)
        .push(&flow.title, Some(HEAD))
        .push(
            &format!(
                "  plan run · job/{} · rules {}",
                flow.job,
                flow.pack.as_ref().map_or_else(
                    || "none".to_owned(),
                    |p| format!("{} v{}", p.name, p.version)
                )
            ),
            Some(LABEL),
        )
        .push("  ", None);
    chip(
        &mut head,
        &mut pics,
        None,
        &format!("{done} / {} done", ts.len()),
        Chip::Wait.face(),
    );
    // the strip first, under the lens bar, then the run's line (the mockup)
    let mut rows: Vec<Row> = strip_row(flow, &ts, env, fonts, &mut pics)
        .into_iter()
        .collect();
    rows.push(head.finish());
    let mut cols = RowBuilder::new("cols");
    for (i, name) in ["Task", "Agent"].iter().chain(GATES.iter()).enumerate() {
        cols.stop(at[i]);
        if i >= 2 {
            let start = cols.pos();
            pics.put(&mut cols, gate_icon(name), " ");
            cols.push(" ", None);
            let end = cols.pos();
            cols.face(start, end, LABEL);
            let room = widths[i - 2].saturating_sub(icon + text_px(fonts, " "));
            if text_px(fonts, name) <= room {
                cols.push(name, Some(LABEL));
            } else {
                cols.push(
                    &drgnx_rows::fit::fit(fonts, ROLE, name, room as f32),
                    Some(LABEL),
                );
            }
        } else {
            cols.push(name, Some(LABEL));
        }
    }
    rule(&mut cols, "cols", env);
    rows.push(cols.finish());
    if ts.is_empty() {
        let mut b = RowBuilder::new("none");
        b.push("No tasks yet.", Some(LABEL));
        rows.push(b.finish());
    }
    for t in &ts {
        let mut b = RowBuilder::new(format!("task:{}", t.id));
        let start = b.pos();
        let label = format!("{}  ", t.label);
        let room = at[1].saturating_sub(text_px(fonts, &label) + gap);
        b.push(&label, Some(LABEL)).push(
            &drgnx_rows::fit::fit(fonts, ROLE, &t.title, room as f32),
            Some(TEXT),
        );
        b.stop(at[1])
            .push(t.agent.as_deref().unwrap_or("—"), Some(LABEL));
        for (i, c) in t.cells.iter().enumerate() {
            b.stop(at[i + 2]);
            draw_cell(
                &mut b,
                &mut pics,
                GATES[i],
                &fit_cell(fonts, icon, GATES[i], c, widths[i]),
            );
        }
        let end = b.pos();
        b.prop(start, end, "drgnx-work-id", json!(t.id));
        if let Some(card) = t.card {
            b.prop(start, end, "drgnx-work-card", json!(card));
        }
        rule(&mut b, &format!("task:{}", t.id), env);
        rows.push(b.finish());
    }
    let mut blank = RowBuilder::new("gap");
    blank.push("", None);
    rows.push(blank.finish());
    rows.extend(card_rows(flow, env, fonts, &mut pics));
    (rows, pics.out)
}

/// B's row, keyed KEY, as a rule block (`BLOCK`): a hairline under it across the table, which Glitnir draws.
fn rule(b: &mut RowBuilder, key: &str, env: &ViewEnv) {
    let end = b.pos();
    b.prop(0, end, BLOCK, json!(["rule", key, 0, env.width_px]));
}

/// RUNS' checks at their tree: (green, red).
fn tally(r: &Runs) -> (usize, usize) {
    let (mut green, mut red) = (0, 0);
    for c in &r.checks {
        match state(&r.evidence, &r.at, &selector_of(c)) {
            State::Green => green += 1,
            State::Red(_) => red += 1,
            State::Missing => {}
        }
    }
    (green, red)
}

/// The machine a run ran on (its platform's part after `/`).
fn machine(e: &Evidence) -> &str {
    e.facts
        .platform
        .rsplit('/')
        .next()
        .unwrap_or(&e.facts.platform)
}

/// One piece of a card's line.
enum Piece {
    /// Text in a face.
    Text(String, &'static str),
    /// An icon (name, alt) in a face.
    Icon(&'static str, &'static str, &'static str),
    /// A chip: its icon, text and face ([`chip`]).
    Chip(Option<(&'static str, &'static str)>, String, &'static str),
    /// The next piece starts this many px into the card's content.
    At(u32),
}

/// A line per machine that ran any of RUNS' checks at their tree: each check's newest run there, a tick in the ok
/// face when it passed, a cross in the error face when it failed.
fn machine_lines(r: &Runs) -> Vec<Vec<Piece>> {
    let mut machines: Vec<&str> = Vec::new();
    for e in r.evidence.iter().filter(|e| e.facts.tree_key == r.at) {
        if !machines.contains(&machine(e)) {
            machines.push(machine(e));
        }
    }
    let mut out = Vec::new();
    for m in machines {
        let mut line = vec![Piece::Text(format!("{m}:"), LABEL)];
        for c in &r.checks {
            let sel = selector_of(c);
            let Some(e) =
                r.evidence.iter().rev().find(|e| {
                    e.facts.tree_key == r.at && e.facts.selector == sel && machine(e) == m
                })
            else {
                continue;
            };
            let ok = failing(&e.rows).next().is_none();
            line.push(Piece::Text("  ".into(), LABEL));
            line.push(if ok {
                Piece::Icon("check", "✓", Chip::Ok.face())
            } else {
                Piece::Icon("x", "✗", Chip::Err.face())
            });
            line.push(Piece::Text(format!(" {}", c.name), TEXT));
        }
        out.push(line);
    }
    out
}

/// TREE short.
fn short(tree: &str) -> &str {
    &tree[..tree.len().min(7)]
}

/// A batch member's note: what the queue SAID to it, with the job's task ids named by their labels (NAMES, id to
/// label), and what the merge-notes check found on it (AUDITED).
pub fn note(
    said: Option<&str>,
    audited: Option<&str>,
    names: &[(String, String)],
) -> Option<String> {
    let said = said.map(|s| {
        let mut ids: Vec<&(String, String)> = names.iter().collect();
        // longest first, so an id never replaces the head of a longer one
        ids.sort_by_key(|(id, _)| std::cmp::Reverse(id.len()));
        let mut s = s.to_owned();
        for (id, label) in ids {
            s = s.replace(id.as_str(), label);
        }
        s
    });
    match (said, audited) {
        (Some(s), Some(a)) => Some(format!("{s} · {a}")),
        (s, a) => s.or_else(|| a.map(str::to_owned)),
    }
}

/// The merge batch card's lines, its content CW px wide (FONTS measure): its heading with the affected groups' chip
/// (green of listed at the combined tree), a line per member (its label and title, its tip, what the queue said to
/// it), and its groups' runs per machine.
fn batch_lines(flow: &Flow, cw: u32, fonts: &dyn Measure) -> Vec<Vec<Piece>> {
    let mut head = vec![
        Piece::Icon("git-merge", " ", LABEL),
        Piece::Text(format!(" Merge batch → job/{}", flow.job), HEAD),
    ];
    if flow.batch.is_empty() {
        head.push(Piece::Text("  empty".into(), LABEL));
    }
    if let Some(g) = &flow.groups {
        let (green, red) = tally(g);
        let face = if red > 0 {
            Chip::Err
        } else if green == g.checks.len() {
            Chip::Ok
        } else {
            Chip::Run
        };
        head.push(Piece::Text("  ".into(), LABEL));
        head.push(Piece::Chip(
            None,
            format!("affected groups {green}/{}", g.checks.len()),
            face.face(),
        ));
    }
    let mut out = vec![head];
    let (tip_at, said_at) = (cw * 2 / 5, cw * 3 / 5);
    let fit = |s: &str, px: u32| drgnx_rows::fit::fit(fonts, ROLE, s, px as f32);
    for m in &flow.batch {
        let label = format!("{}  ", m.label);
        let room = tip_at.saturating_sub(text_px(fonts, &label) + 8);
        let mut line = vec![
            Piece::Text(label, TEXT),
            Piece::Text(fit(&m.title, room), LABEL),
            Piece::At(tip_at),
            Piece::Text(format!("tip {}", m.tip), LABEL),
        ];
        if let Some(said) = &m.said {
            line.push(Piece::At(said_at));
            line.push(Piece::Text(fit(said, cw.saturating_sub(said_at)), LABEL));
        }
        out.push(line);
    }
    if let Some(g) = &flow.groups {
        out.extend(machine_lines(g));
    }
    out
}

/// The line gate card's lines (the pack's push gate), its content CW px wide: its heading with the tiers' chip at the
/// tree it judged (green, how many of the tiers, or red), the tiers' runs per machine and the note that the push
/// stays the user's; before any push was asked, the heading says so.
fn line_lines(flow: &Flow, cw: u32, fonts: &dyn Measure) -> Vec<Vec<Piece>> {
    let mut head = vec![
        Piece::Icon("git-branch", " ", LABEL),
        Piece::Text(format!(" Line gate · push job/{}", flow.job), HEAD),
    ];
    let Some(p) = &flow.push else {
        head.push(Piece::Text("  no push asked yet".into(), LABEL));
        return vec![head];
    };
    let (green, red) = tally(p);
    let n = p.checks.len();
    let (face, text) = if red > 0 {
        (Chip::Err, format!("{red} red at {}", short(&p.at)))
    } else if green == n {
        (Chip::Ok, format!("green on {}", short(&p.at)))
    } else {
        (Chip::Run, format!("{green}/{n} at {}", short(&p.at)))
    };
    head.push(Piece::Text("  ".into(), LABEL));
    head.push(Piece::Chip(None, text, face.face()));
    let mut out = vec![head];
    out.extend(machine_lines(p));
    let note = "Pushing needs you (push.ci, Ask): the gate only refuses an early push.";
    out.push(vec![Piece::Text(
        drgnx_rows::fit::fit(fonts, ROLE, note, cw as f32),
        LABEL,
    )]);
    out
}

/// FACE on a card: the text faces have card twins that carry its fill (one face per span: a fill run under the text's
/// runs replaced their faces where the rows were inserted, so they never overlap); a chip keeps its own tint.
fn on_card(face: &'static str) -> &'static str {
    match face {
        TEXT => CARD_TEXT,
        LABEL => CARD_LABEL,
        HEAD => CARD_HEAD,
        f => f,
    }
}

/// B's next piece starts at PX, the space up to it in the card's fill.
fn card_gap(b: &mut RowBuilder, px: u32) {
    let s = b.pos();
    b.stop(px);
    let e = b.pos();
    b.face(s, e, CARD);
}

/// LINE of card ID drawn on B between X0 and X1 (device px), its content PAD in: the space before X0 bare, the card's
/// span filled up to X1 (its gaps in [`CARD`], its text in the faces' card twins: [`on_card`]) and marked as the ring
/// block ID (`BLOCK`: Glitnir draws the ring).
fn put_line(
    b: &mut RowBuilder,
    pics: &mut Pics,
    line: Vec<Piece>,
    id: &str,
    x0: u32,
    x1: u32,
    pad: u32,
) {
    if x0 > 0 {
        b.stop(x0);
    }
    let start = b.pos();
    card_gap(b, x0 + pad);
    for p in line {
        match p {
            Piece::Text(t, f) => {
                b.push(&t, Some(on_card(f)));
            }
            Piece::Icon(name, alt, f) => {
                let s = b.pos();
                pics.put(b, name, alt);
                let e = b.pos();
                b.face(s, e, on_card(f));
            }
            Piece::Chip(icon, t, f) => chip(b, pics, icon, &t, f),
            Piece::At(px) => card_gap(b, x0 + pad + px),
        }
    }
    card_gap(b, x1);
    let end = b.pos();
    b.prop(start, end, BLOCK, json!(["ring", id, x0, x1]));
}

/// The batch and line gate cards side by side under the tasks (the line gate only when the pack runs the push gate;
/// else the batch's card spans the table), a row per line, keyed `cards:N`.
fn card_rows(flow: &Flow, env: &ViewEnv, fonts: &dyn Measure, pics: &mut Pics) -> Vec<Row> {
    let (w, gap, pad, edge) = (env.width_px, dpx(env, 10.0), dpx(env, 10.0), dpx(env, 2.0));
    let line_on = flow.pack.as_ref().is_some_and(|p| p.on("push-gate"));
    let right_x1 = w.saturating_sub(edge);
    let (left_x1, right_x0) = if line_on {
        (w / 2 - gap / 2, w / 2 + gap / 2)
    } else {
        (right_x1, right_x1)
    };
    let cw = |x0: u32, x1: u32| x1.saturating_sub(x0 + 2 * pad);
    let mut left = batch_lines(flow, cw(0, left_x1), fonts).into_iter();
    let mut right = if line_on {
        line_lines(flow, cw(right_x0, right_x1), fonts)
    } else {
        Vec::new()
    }
    .into_iter();
    let mut rows = Vec::new();
    for i in 0.. {
        let (l, r) = (left.next(), right.next());
        if l.is_none() && r.is_none() {
            break;
        }
        let mut b = RowBuilder::new(format!("cards:{i}"));
        if let Some(l) = l {
            put_line(&mut b, pics, l, "batch", 0, left_x1, pad);
        }
        if let Some(r) = r {
            put_line(&mut b, pics, r, "line", right_x0, right_x1, pad);
        }
        rows.push(b.finish());
    }
    rows
}

/// How the hub holds rule ID (the Rules tile's third column).
fn how(id: &str) -> &'static str {
    match id {
        "red-first" => "checked at the merge over every commit in base..tip",
        "author-check" => "the task can't reach \"ready to merge\" without it",
        "affected-groups" => "groups from the base's affected.eld; per-tip reruns on red",
        "push-gate" => "push gate; results reused by tree key",
        "merge-notes" => "a notes record per hunk is required; its content is the agent's",
        "flake-hold" => "a test that failed then passed on the same facts holds the merge",
        "trailers" => "checked over base..tip; no waiver passes it",
        _ => "",
    }
}

/// The Rules tile's rows for ENV and their icons: its heading, the columns (Rule, Kind, How the hub holds it), a row
/// per rule with its kind as a chip (enforced with a lock, checked and routing in the accent).
pub(crate) fn rules_rows(flow: &Flow, env: &ViewEnv) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let cell_w = env.cell.0.max(1);
    let mut pics = Pics::new(env);
    let (kind_at, how_at) = (env.width_px * 2 / 5, env.width_px * 2 / 5 + dpx(env, 100.0));
    let mut head = RowBuilder::new("rules-head");
    pics.put(&mut head, "shield", " ");
    head.push(" ", None);
    let Some(p) = &flow.pack else {
        head.push("Rules", Some(HEAD))
            .push("  this run has no rule pack", Some(LABEL));
        return (vec![head.finish()], pics.out);
    };
    head.push(&format!("Rules · {} v{}", p.name, p.version), Some(HEAD));
    let mut rows = vec![head.finish()];
    let mut cols = RowBuilder::new("rules-cols");
    cols.push("Rule", Some(LABEL))
        .stop(kind_at)
        .push("Kind", Some(LABEL))
        .stop(how_at)
        .push("How the hub holds it", Some(LABEL));
    rows.push(cols.finish());
    for r in &p.rules {
        let mut b = RowBuilder::new(format!("rule:{}", r.id));
        b.push(
            &fit(&r.doc, (kind_at.saturating_sub(8) / cell_w) as usize),
            Some(TEXT),
        )
        .stop(kind_at);
        let lock = (r.kind == "enforced").then_some(("lock", "!"));
        let face = if r.kind == "enforced" {
            Chip::Ok.face()
        } else {
            Chip::Run.face()
        };
        chip(&mut b, &mut pics, lock, &r.kind, face);
        b.stop(how_at).push(
            &fit(
                how(&r.id),
                (env.width_px.saturating_sub(how_at) / cell_w) as usize,
            ),
            Some(LABEL),
        );
        rows.push(b.finish());
    }
    (rows, pics.out)
}

/// TEXT in lines of at most CHARS characters, broken at spaces (a word longer than a line is cut).
fn wrap(text: &str, chars: usize) -> Vec<String> {
    let chars = chars.max(8);
    let mut out: Vec<String> = Vec::new();
    let mut line = String::new();
    for word in text.split_whitespace() {
        let n = line.chars().count();
        if n > 0 && n + 1 + word.chars().count() > chars {
            out.push(std::mem::take(&mut line));
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line.push_str(word);
        if line.chars().count() > chars {
            out.push(fit(&line, chars));
            line.clear();
        }
    }
    if !line.is_empty() {
        out.push(line);
    }
    out
}

/// What clears a hold of GATE (a column of [`GATES`]).
fn clears(gate: &str) -> &'static str {
    match gate {
        "Red first" => {
            "Any run of the task's tests on its test commit's tree where those rows fail. The agent's own run \
             counts; else Run the red starts one."
        }
        "Author check" => "The pack's author checks green on the tip's tree.",
        "Build" => "A green run on the tip's tree.",
        _ => "What the hold names, fixed on a new tip; then Check again.",
    }
}

/// One evidence record in a line: its kind, its rows' counts, its run and its tree.
fn evidence_line(e: &Evidence) -> String {
    if e.kind == "waiver" {
        return format!("waiver · {}", e.note.as_deref().unwrap_or(""));
    }
    let pass = e.rows.iter().filter(|r| r.verdict == Verdict::Pass).count();
    let fail = failing(&e.rows).count();
    let run = e.facts.selector.lines().last().unwrap_or_default();
    let tree: String = e.facts.tree_key.chars().take(7).collect();
    format!(
        "{} · {pass} pass · {fail} failed · {run} · tree {tree}",
        e.kind
    )
}

/// The detail tile of task TASK of FLOW for ENV, one line per row: its head (the task's id and its card's on it),
/// for a held task why it is held, what clears it, then the evidence so far and the actions with their keys (the
/// waiver the user's alone).  A task FLOW does not have: one row saying to select one.
pub(crate) fn detail_rows(flow: &Flow, task: &str, env: &ViewEnv) -> Vec<Row> {
    let chars = (env.width_px / env.cell.0.max(1)) as usize;
    let Some((facts, t)) = flow
        .tasks
        .iter()
        .zip(tasks(flow))
        .find(|(f, _)| f.id == task)
    else {
        let mut b = RowBuilder::new("d:none");
        b.push("Select a task in the Flow.", Some(LABEL));
        return vec![b.finish()];
    };
    let mut rows = Vec::new();
    let mut line = |key: String, text: &str, face: Option<&str>| {
        for (i, l) in wrap(text, chars).iter().enumerate() {
            let mut b = RowBuilder::new(if i == 0 {
                key.clone()
            } else {
                format!("{key}+{i}")
            });
            b.push(l, face);
            rows.push(b.finish());
        }
    };
    // the head: what it is, who works on it, where it stands
    let mut head = RowBuilder::new("d:head");
    let start = head.pos();
    head.push(
        &fit(&format!("{} · {}", t.label, t.title), chars),
        Some(HEAD),
    );
    let end = head.pos();
    head.prop(start, end, "drgnx-work-id", json!(t.id));
    if let Some(card) = t.card {
        head.prop(start, end, "drgnx-work-card", json!(card));
    }
    let mut out = vec![head.finish()];
    let mut sub = RowBuilder::new("d:sub");
    sub.push(
        &fit(
            &format!(
                "{} · {}",
                t.agent.as_deref().unwrap_or("no agent"),
                facts.status
            ),
            chars.saturating_sub(7),
        ),
        Some(LABEL),
    );
    if t.held.is_some() {
        sub.push(" ", None).push(" held ", Some(Chip::Held.face()));
    }
    out.push(sub.finish());
    let held_gates: Vec<(&str, &Cell)> = GATES
        .iter()
        .zip(&t.cells)
        .filter(|(_, c)| c.chip == Chip::Held)
        .map(|(g, c)| (*g, c))
        .collect();
    if let Some(why) = &t.held {
        line("d:gap1".into(), " ", None);
        line("d:why-h".into(), "Why it is held", Some(HEAD));
        line("d:why".into(), why, Some(TEXT));
        for (g, c) in &held_gates {
            line(
                format!("d:why:{g}"),
                &format!("{g}: {}", c.text),
                Some(TEXT),
            );
        }
        line("d:gap2".into(), " ", None);
        line("d:clear-h".into(), "What clears it", Some(HEAD));
        let gates: Vec<&str> = match held_gates
            .iter()
            .map(|(g, _)| *g)
            .find(|g| *g != "Merge batch")
        {
            Some(g) => vec![g],
            None => vec!["Merge batch"],
        };
        for g in gates {
            line(format!("d:clear:{g}"), clears(g), Some(TEXT));
        }
    }
    line("d:gap3".into(), " ", None);
    line("d:ev-h".into(), "Evidence so far", Some(HEAD));
    if facts.evidence.is_empty() {
        line("d:ev".into(), "none recorded", Some(LABEL));
    }
    for (i, e) in facts.evidence.iter().enumerate() {
        let face = if e.kind == "red" || failing(&e.rows).next().is_none() {
            LABEL
        } else {
            Chip::Err.face()
        };
        line(format!("d:ev:{i}"), &evidence_line(e), Some(face));
    }
    out.append(&mut rows);
    // the actions, with their keys (the Flow's own map)
    out.push(RowBuilder::new("d:gap4").finish());
    if t.card.is_some() {
        let first = if held_gates.iter().any(|(g, _)| *g == "Red first") {
            "Run the red"
        } else {
            "Check again"
        };
        let mut act = RowBuilder::new("d:act");
        act.push(&format!(" {first} r "), Some(Chip::Run.face()))
            .push(" ", None)
            .push(" Tell the agent s ", Some(Chip::Wait.face()));
        out.push(act.finish());
    }
    let mut act = RowBuilder::new("d:act2");
    if t.card.is_some() {
        act.push(" Waive once w ", Some(Chip::Wait.face()))
            .push(" ", None);
    }
    act.push(" Evidence e ", Some(Chip::Wait.face()));
    out.push(act.finish());
    if t.card.is_some() {
        for (i, l) in wrap(
            "Waiving is yours only (a user-only rule); it is recorded on the task.",
            chars,
        )
        .iter()
        .enumerate()
        {
            let mut b = RowBuilder::new(format!("d:waive:{i}"));
            b.push(l, Some(LABEL));
            out.push(b.finish());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use runstav::methods::view::Display;
    use vordr::facts::Facts;
    use vordr::pack::{Check, Rule};
    use vordr::rows::{Row as VRow, parse};

    fn ev(kind: &str, sel: &str, rows: Vec<VRow>) -> Evidence {
        Evidence {
            kind: kind.into(),
            task: "task:J#1".into(),
            job: "x".into(),
            facts: Facts {
                tree_key: "T".into(),
                env_stamp: "e".into(),
                platform: "linux-x86_64/local".into(),
                selector: sel.into(),
            },
            rows,
            truncated: false,
            at: 1.0,
            note: None,
        }
    }

    fn pack() -> Pack {
        let rule = |id: &str| Rule {
            id: id.into(),
            kind: "enforced".into(),
            doc: format!("{id} doc"),
        };
        Pack {
            name: "drgnx-org".into(),
            version: 4,
            rules: vec![rule("red-first"), rule("author-check"), rule("review")],
            author_check: vec![Check {
                name: "build".into(),
                dir: String::new(),
                run: vec!["bin/drgnx".into(), "build".into()],
            }],
            ..Pack::default()
        }
    }

    fn task(n: i64, status: &str) -> TaskFacts {
        TaskFacts {
            id: format!("task:J#{n}"),
            n,
            title: format!("Task {n}"),
            status: status.into(),
            agent: Some("Sonnet".into()),
            ..TaskFacts::default()
        }
    }

    fn chips(c: &[Cell; 6]) -> Vec<(Chip, &str)> {
        c.iter().map(|c| (c.chip, c.text.as_str())).collect()
    }

    /// [D] A task's cells: queued waits; a red run is red first's evidence; the build is the newest run; the author
    /// check counts its checks green at their newest runs; a held task says why; a pack without a gate shows `—`.
    #[test]
    fn a_tasks_cells_read_its_evidence_under_the_pack() {
        let p = pack();
        let q = task(0, "open");
        assert_eq!(
            chips(&cells(&q, Some(&p))),
            [
                (Chip::Wait, "queued"),
                (Chip::Wait, "—"),
                (Chip::Wait, "—"),
                (Chip::Wait, "—"),
                (Chip::Wait, "—"),
                (Chip::Wait, "at plan end")
            ]
        );
        let build = selector_of(&p.author_check[0]);
        let mut t = task(1, "in-review");
        t.evidence = vec![
            ev(
                "red",
                "s",
                parse("test a::x ... FAILED\ntest a::y ... FAILED\n"),
            ),
            ev("green", &build, parse("test b::build ... ok\n")),
            ev(
                "green",
                "s",
                parse("test a::x ... ok\ntest a::y ... ok\ntest a::z ... ok\n"),
            ),
        ];
        t.queue = Queue::Batch;
        assert_eq!(
            chips(&cells(&t, Some(&p))),
            [
                (Chip::Ok, "sent"),
                (Chip::Ok, "2 failed · base"),
                (Chip::Ok, "3 pass"),
                (Chip::Ok, "1/1"),
                (Chip::Run, "checking"),
                (Chip::Wait, "at plan end")
            ]
        );
        // no red at review: red first holds; a gate card's words go in the merge column
        let mut h = task(5, "in-review");
        h.held = Some("no red for its test commit".into());
        let c = cells(&h, Some(&p));
        assert_eq!(
            (c[1].chip, c[1].text.as_str()),
            (Chip::Held, "no red · held")
        );
        // the author check waits for the red; the merge column says held (why is the needs-you chip's and the tile's)
        assert_eq!((c[3].chip, c[3].text.as_str()), (Chip::Na, "waits red"));
        assert_eq!((c[4].chip, c[4].text.as_str()), (Chip::Held, "held"));
        // no pack: no gates
        let none = cells(&t, None);
        assert_eq!(
            (none[1].chip, none[3].chip, none[5].chip),
            (Chip::Na, Chip::Na, Chip::Na)
        );
        assert_eq!(
            cells(&task(2, "done"), Some(&p))[4],
            cell(Chip::Ok, "merged")
        );
    }

    fn flow() -> Flow {
        let mut held = task(5, "in-review");
        held.held = Some("no red".into());
        held.card = Some(42);
        Flow {
            job: "J".into(),
            title: "Search view".into(),
            pack: Some(pack()),
            tasks: vec![task(1, "running"), held, task(8, "open")],
            batch: vec![Member {
                label: "T2".into(),
                title: "Open buffers".into(),
                tip: "7d21c0e".into(),
                said: Some("trial merge clean".into()),
            }],
            groups: None,
            push: None,
            machines: vec![],
            cost: None,
        }
    }

    fn fonts() -> drgnx_rows::fit::FontSet {
        let mut f = drgnx_rows::fit::FontSet::new();
        f.set_role(ROLE, None, 7.0);
        f
    }

    fn check(name: &str) -> Check {
        Check {
            name: name.into(),
            dir: String::new(),
            run: vec!["bin/drgnx".into(), "test".into(), name.into()],
        }
    }

    /// A run of CHECK at TREE on MACHINE, its rows passing or not.
    fn run_of(c: &Check, tree: &str, machine: &str, ok: bool) -> Evidence {
        let mut e = ev(
            if ok { "green" } else { "red" },
            &selector_of(c),
            parse(if ok {
                "test g::a ... ok\n"
            } else {
                "test g::a ... FAILED\n"
            }),
        );
        e.facts.tree_key = tree.into();
        e.facts.platform = format!("linux-x86_64/{machine}");
        e
    }

    /// [D] The columns fit the window: in a window that holds the cells and a third for the titles, each gate column is
    /// as wide as its widest cell (whole), the agent's as its widest agent, and the task column takes the rest, a title
    /// longer than that cut to it.
    #[test]
    fn the_columns_fit_the_window_and_the_task_column_gives_way() {
        let mut f = flow();
        f.tasks[0].title =
            "A task with a title far too long for a narrow window's task column".into();
        f.tasks[0].evidence = vec![ev("red", "s", parse("test a::x ... FAILED\n"))];
        for scale in [1.0, 2.0] {
            let mut e = env(scale);
            // the env's fonts are its scale's (device px)
            let mut m = drgnx_rows::fit::FontSet::new();
            m.set_role(ROLE, None, 7.0 * scale);
            let mut wide = e.clone();
            wide.width_px = 100_000;
            let natural = 100_000 - columns(&tasks(&f), &wide, &m).0[1];
            e.width_px = natural * 3 / 2 + 3;
            let (rows, _) = flow_rows(&f, &e, &m);
            let t1 = &rows[3];
            let stops: Vec<u32> = t1.stops.iter().map(|s| s.1).collect();
            assert!(stops.windows(2).all(|w| w[0] < w[1]), "{stops:?}");
            // the last column's widest cell ends inside the window
            let review = drgnx_rows::fit::width(&m, ROLE, " at plan end ") as u32;
            assert!(
                stops[6] + review <= e.width_px,
                "scale {scale}: {stops:?} + {review} > {}",
                e.width_px
            );
            // the cells are whole; the title gave way
            assert!(t1.text.contains("1 failed · base"), "{}", t1.text);
            assert!(
                t1.text.contains("A task") && t1.text.contains('…'),
                "scale {scale}: {}",
                t1.text
            );
            assert!(!rows[4].text.contains("no red · h…"), "{}", rows[4].text);
        }
    }

    /// [D] The gate columns give way to the titles before the titles give way (as in the mockup): in a window too
    /// narrow for both, a title of a usual length stays whole and the widest cells are cut instead, each within its
    /// column; a title longer than its column's share is still cut, and in a very narrow window the title gives way
    /// too, down to the least the task column keeps.
    #[test]
    fn the_columns_give_way_to_the_titles_before_the_titles_do() {
        let mut f = flow();
        f.tasks[0].title = "Open buffers in the model".into();
        f.tasks[0].evidence = vec![ev("red", "s", parse("test a::x ... FAILED\n"))];
        f.tasks[1].title =
            "A task with a title far too long for any task column's share of a window".into();
        for scale in [1.0, 2.0] {
            let mut e = env(scale);
            let mut m = drgnx_rows::fit::FontSet::new();
            m.set_role(ROLE, None, 7.0 * scale);
            // the natural cells and the whole title don't both fit here
            let title = drgnx_rows::fit::width(&m, ROLE, "T1  Open buffers in the model") as u32;
            let natural = {
                let mut wide = e.clone();
                wide.width_px = 100_000;
                let (at, _) = columns(&tasks(&f), &wide, &m);
                100_000 - at[1]
            };
            e.width_px = natural + title / 2;
            let (rows, _) = flow_rows(&f, &e, &m);
            let (t1, t5) = (&rows[3], &rows[4]);
            assert!(
                t1.text.contains("Open buffers in the model"),
                "scale {scale}: {}",
                t1.text
            );
            assert!(
                t5.text.contains("A task") && t5.text.contains('…'),
                "scale {scale}: {}",
                t5.text
            );
            let stops: Vec<u32> = t1.stops.iter().map(|s| s.1).collect();
            assert!(stops.windows(2).all(|w| w[0] < w[1]), "{stops:?}");
            // each cell ends before the next column starts, the last inside the window
            for row in [t1, t5] {
                let mut ends = row.stops.iter().map(|s| s.1).skip(1).chain([e.width_px]);
                for (i, s) in row.stops.iter().enumerate() {
                    let next = ends.next().unwrap();
                    let from = s.0 as usize + 1;
                    let upto = row
                        .stops
                        .get(i + 1)
                        .map_or(row.text.chars().count(), |n| n.0 as usize);
                    let cell: String = row
                        .text
                        .chars()
                        .skip(from)
                        .take(upto.saturating_sub(from))
                        .collect();
                    let w = drgnx_rows::fit::width(&m, ROLE, cell.trim_end()) as u32;
                    assert!(
                        s.1 + w <= next,
                        "scale {scale}: {cell:?} at {} + {w} > {next}",
                        s.1
                    );
                }
            }
            // very narrow: the title gives way too, the task column keeps its least
            e.width_px = natural / 2;
            let (rows, _) = flow_rows(&f, &e, &m);
            assert!(
                rows[3].stops[0].1 >= dpx(&e, TASK_MIN),
                "{:?}",
                rows[3].stops
            );
        }
    }

    /// [D] A member's note names the job's tasks by their labels, and adds what the merge-notes check found.
    #[test]
    fn a_members_note_names_tasks_by_label_and_adds_the_audit() {
        let names = [("j#1", "T1"), ("j#10", "T10")].map(|(a, b)| (a.to_string(), b.to_string()));
        assert_eq!(
            note(Some("j#10 merges first"), None, &names).as_deref(),
            Some("T10 merges first")
        );
        assert_eq!(
            note(Some("waits for the batch ahead (j#1, j#10)"), None, &names).as_deref(),
            Some("waits for the batch ahead (T1, T10)")
        );
        assert_eq!(
            note(
                Some("trial merge clean"),
                Some("1 hunk by intent · notes"),
                &names
            )
            .as_deref(),
            Some("trial merge clean · 1 hunk by intent · notes")
        );
        assert_eq!(note(None, None, &names), None);
    }

    /// [D] The batch and the line gate: the batch's heading with its affected groups' chip (green of listed at the
    /// combined tree), a row per member (its tip, title and what the queue said to it), a row per machine with each
    /// group's tick; the line gate's heading with its tiers' chip at the line's head, a row per machine, and a note
    /// that the push stays the user's.  A pack without a push gate has no line gate.
    #[test]
    fn the_batch_and_the_line_gate_show_their_runs_per_machine() {
        let mut f = flow();
        let (unit, gui) = (check("unit"), check("gui"));
        f.pack.as_mut().unwrap().rules.push(Rule {
            id: "push-gate".into(),
            kind: "enforced".into(),
            doc: "One full run before a push".into(),
        });
        f.pack.as_mut().unwrap().push_tiers = vec![unit.clone(), gui.clone()];
        f.groups = Some(Runs {
            at: "B".into(),
            checks: vec![unit.clone(), gui.clone()],
            evidence: vec![
                run_of(&unit, "B", "desktop", true),
                run_of(&gui, "B", "mac-mini", false),
            ],
        });
        f.push = Some(Runs {
            at: "L".into(),
            checks: vec![unit.clone(), gui.clone()],
            evidence: vec![
                run_of(&unit, "L", "desktop", true),
                run_of(&gui, "L", "desktop", true),
            ],
        });
        let e = env(1.0);
        let (rows, _) = flow_rows(&f, &e, &fonts());
        let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
        let tail: Vec<&str> = keys[keys.iter().position(|k| *k == "gap").unwrap() + 1..].to_vec();
        // the two cards side by side: the batch's 4 lines (heading, a member, 2 machines), the line gate's 3
        assert_eq!(tail, ["cards:0", "cards:1", "cards:2", "cards:3"]);
        let row = |k: &str| rows.iter().find(|r| r.key == k).unwrap();
        let text: Vec<&str> = tail.iter().map(|k| row(k).text.as_str()).collect();
        assert!(text[0].contains("Merge batch") && text[0].contains("affected groups 1/2"));
        assert!(
            text[0].contains("Line gate") && text[0].contains("green on L"),
            "{}",
            text[0]
        );
        assert!(row("cards:0").runs.iter().any(|r| r.2 == Chip::Err.face()));
        assert!(row("cards:0").runs.iter().any(|r| r.2 == Chip::Ok.face()));
        assert!(
            text[1].contains("T2")
                && text[1].contains("7d21c0e")
                && text[1].contains("trial merge clean")
        );
        assert!(
            text[1].contains("desktop") && text[1].contains("unit"),
            "{}",
            text[1]
        );
        // the batch's machines on its lines 3 and 4 (the line gate's note beside the first)
        assert!(
            text[2].contains("desktop:") && text[2].contains("Pushing needs you"),
            "{}",
            text[2]
        );
        assert!(
            text[3].contains("mac-mini") && text[3].contains("gui"),
            "{}",
            text[3]
        );
        assert!(text.iter().any(|t| t.contains("Pushing needs you")));
        // each card is a ring block on every one of its rows (Glitnir's `glitnir-blocks`), the batch on the left
        // half and the line gate on the right, its rows filled to its edge in the card's face
        let blocks = |r: &Row| -> Vec<Value> {
            r.props
                .iter()
                .filter(|p| p.2 == BLOCK)
                .map(|p| p.3.clone())
                .collect()
        };
        let half = e.width_px / 2;
        for k in &tail[..3] {
            let b = blocks(row(k));
            assert!(
                b.iter().any(|v| v[0] == "ring"
                    && v[1] == "batch"
                    && v[2] == 0
                    && v[3].as_u64().unwrap() < u64::from(half)),
                "{k}: {b:?}"
            );
            assert!(
                b.iter().any(|v| v[0] == "ring"
                    && v[1] == "line"
                    && v[2].as_u64().unwrap() > u64::from(half)),
                "{k}: {b:?}"
            );
            assert!(row(k).runs.iter().any(|r| r.2 == CARD), "{k}");
            // one face per span: a fill under text would replace its face where the rows are inserted
            let mut runs = row(k).runs.clone();
            runs.sort();
            assert!(runs.windows(2).all(|w| w[0].1 <= w[1].0), "{k}: {runs:?}");
            assert!(
                row(k)
                    .runs
                    .iter()
                    .any(|r| r.2 == CARD_TEXT || r.2 == CARD_HEAD)
            );
        }
        // the batch's 4th line: the line gate has none there, so only the batch's ring
        assert_eq!(blocks(row("cards:3")).len(), 1);
        // the headings and every task row carry a rule (a hairline under the row, across the table)
        for k in ["cols", "task:task:J#1", "task:task:J#5", "task:task:J#8"] {
            let b = blocks(row(k));
            assert!(
                b.iter().any(|v| v[0] == "rule" && v[1] == k && v[2] == 0),
                "{k}: {b:?}"
            );
        }
        // no push gate in the pack: no line gate, the batch's card across the table
        let mut g = f.clone();
        g.pack
            .as_mut()
            .unwrap()
            .rules
            .retain(|r| r.id != "push-gate");
        let (rows, _) = flow_rows(&g, &e, &fonts());
        assert!(!rows.iter().any(|r| r.text.contains("Line gate")));
        let c0 = rows.iter().find(|r| r.key == "cards:0").unwrap();
        assert!(
            blocks(c0)
                .iter()
                .any(|v| v[1] == "batch" && v[3].as_u64().unwrap() > u64::from(half))
        );
        // a push gate with no push asked yet says so
        let mut h = f.clone();
        h.push = None;
        let (rows, _) = flow_rows(&h, &e, &fonts());
        assert!(
            rows.iter()
                .any(|r| r.key == "cards:0" && r.text.contains("no push asked"))
        );
    }

    /// [D] The model: a task node per task, the `flow` form's links up and down, its gates' chips as fields; the held
    /// tasks are the list `held` (the needs-you chips).
    #[test]
    fn the_flow_model_links_tasks_and_lists_the_held() {
        let d = flow_doc(&flow());
        assert_eq!(d.lists["tasks"], ["task:J#1", "task:J#5", "task:J#8"]);
        assert_eq!(d.lists["held"], ["task:J#5"]);
        let nav = |id: &str, n: &str| d.nodes[id]["navs"]["flow"][n].as_str().map(str::to_owned);
        assert_eq!(nav("task:J#1", "down").as_deref(), Some("task:J#5"));
        assert_eq!(nav("task:J#5", "up").as_deref(), Some("task:J#1"));
        assert_eq!(nav("task:J#1", "up"), None);
        let fields = &d.nodes["task:J#5"]["fields"];
        assert!(
            fields
                .as_array()
                .unwrap()
                .contains(&json!(["Red first", "held"])),
            "{fields}"
        );
        assert!(
            fields
                .as_array()
                .unwrap()
                .contains(&json!(["held", "no red"])),
            "{fields}"
        );
    }

    fn env(scale: f32) -> ViewEnv {
        ViewEnv {
            view: "f".into(),
            class: "c".into(),
            epoch: 1,
            display: Display::Gui,
            scale,
            fonts: vec![],
            cell: (8, 16),
            width_px: (1280.0 * scale) as u32,
            palette: vec![],
            tty_widths: vec![],
            tz: String::new(),
            reduced_motion: false,
            attach: false,
        }
    }

    /// [D] The rows: the run's line, the headings (an icon each), a row per task with a chip per gate in its state's
    /// face at the column's stop (device px: the scale's), the task's id on the row; then the batch.  Icons are drawn
    /// at 14 logical px, each image once; an empty cell is a ring, a held one carries a lock.
    #[test]
    fn the_flow_rows_put_a_chip_per_gate_at_its_column() {
        for scale in [1.0, 2.0] {
            let (rows, images) = flow_rows(&flow(), &env(scale), &fonts());
            let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
            assert_eq!(
                keys,
                [
                    "needs",
                    "head",
                    "cols",
                    "task:task:J#1",
                    "task:task:J#5",
                    "task:task:J#8",
                    "gap",
                    "cards:0",
                    "cards:1",
                ]
            );
            assert!(
                rows[1].text.contains("Search view") && rows[1].text.contains("rules drgnx-org v4")
            );
            let px = |v: f32| (v * scale).round() as u32;
            // every image a row names is in the build's images, once, at 14 logical px
            let named: Vec<ImageId> = rows
                .iter()
                .flat_map(|r| r.images.iter().map(|i| i.1))
                .collect();
            assert!(named.iter().all(|id| images.iter().any(|(i, _)| i == id)));
            let mut ids: Vec<ImageId> = images.iter().map(|(i, _)| *i).collect();
            ids.dedup();
            assert_eq!(ids.len(), images.len());
            assert!(
                images[0].1.contains(&format!("width=\"{}\"", px(14.0))),
                "{}",
                images[0].1
            );
            // six column icons on the headings
            assert_eq!(rows[2].images.len(), 6);
            // the needs-you chips: one per held task, in the held face, carrying the task's id
            let needs = &rows[0];
            assert!(needs.text.contains("T5 held: no red"), "{}", needs.text);
            assert!(needs.runs.iter().any(|r| r.2 == Chip::Held.face()));
            assert!(
                needs
                    .props
                    .iter()
                    .any(|p| p.2 == "drgnx-work-id" && p.3 == json!("task:J#5"))
            );
            let held = &rows[4];
            // the held task's row carries its card, for the actions
            assert!(
                held.props
                    .iter()
                    .any(|p| p.2 == "drgnx-work-card" && p.3 == json!(42))
            );
            let stops: Vec<u32> = held.stops.iter().map(|s| s.1).collect();
            assert_eq!(stops.len(), 7);
            // at 1280 logical px the task column keeps the mockup's 220 px at least
            assert!(stops[0] >= px(220.0), "scale {scale}: {stops:?}");
            let faces: Vec<&str> = held.runs.iter().map(|r| r.2.as_str()).collect();
            assert!(faces.contains(&Chip::Held.face()), "{faces:?}");
            assert!(faces.contains(&TEXT) && faces.contains(&LABEL), "{faces:?}");
            // the held red-first cell carries a lock; the queued task's empty cells are rings
            assert!(!held.images.is_empty());
            assert!(rows[5].images.len() >= 4, "{:?}", rows[5].images);
            assert!(
                held.props
                    .iter()
                    .any(|p| p.2 == "drgnx-work-id" && p.3 == json!("task:J#5"))
            );
            assert!(rows[2].text.contains("Red first") && rows[2].text.contains("Merge batch"));
        }
        let empty = Flow {
            tasks: vec![],
            ..flow()
        };
        // no held task: no needs-you row
        assert_eq!(flow_rows(&empty, &env(1.0), &fonts()).0[2].key, "none");
    }

    /// [D] The strip under the run's line: a chip per held task with its jump key's badge (`g 1` …), the push the line
    /// gate leaves to the user once it is green, and at the window's right edge the run's cost against its budget and
    /// each machine's load, with a server icon.
    #[test]
    fn the_strip_says_what_needs_you_and_the_machines_load() {
        let unit = check("unit");
        for scale in [1.0, 2.0] {
            let f = Flow {
                push: Some(Runs {
                    at: "9c41e07a".into(),
                    checks: vec![unit.clone()],
                    evidence: vec![run_of(&unit, "9c41e07a", "desktop", true)],
                }),
                machines: vec![("desk".into(), 4, 6), ("mac-mini".into(), 1, 2)],
                cost: Some((6.2, Some(18.0))),
                ..flow()
            };
            let e = env(scale);
            let (rows, _) = flow_rows(&f, &e, &fonts());
            let strip = &rows[0];
            assert_eq!(strip.key, "needs");
            assert!(strip.text.contains("T5 held: no red"), "{}", strip.text);
            assert!(
                strip.text.contains("push job/J? gate green"),
                "{}",
                strip.text
            );
            assert!(strip.text.contains("$6.20 / $18"), "{}", strip.text);
            assert!(strip.text.contains("desk 4/6") && strip.text.contains("mac-mini 1/2"));
            // the held chip's key badge in the key face
            let g1 = strip.text[..strip.text.find("g1").expect("g1")]
                .chars()
                .count() as u32;
            assert!(
                strip
                    .runs
                    .iter()
                    .any(|r| r.0 <= g1 && g1 < r.1 && r.2 == KEY),
                "{:?}",
                strip.runs
            );
            // a server icon per machine, and the right part starts past the window's middle, ending inside it
            // two flags (the held task, the push) and two servers
            assert!(strip.images.len() >= 4, "{:?}", strip.images);
            let stop = strip.stops.last().expect("a stop").1;
            assert!(stop > e.width_px / 2 && stop < e.width_px, "{stop}");
        }
        // a narrow window: the held reasons give way (ellipsis), the push's words stay whole, and the left part ends
        // before the right part's stop
        let mut f = Flow {
            push: Some(Runs {
                at: "9c41e07a".into(),
                checks: vec![unit.clone()],
                evidence: vec![run_of(&unit, "9c41e07a", "desktop", true)],
            }),
            machines: vec![("desk".into(), 4, 6), ("mac-mini".into(), 1, 2)],
            cost: Some((6.2, Some(18.0))),
            ..flow()
        };
        f.tasks[1].held =
            Some("the gates hold the merge: no red for its test commit, so it waits".into());
        let mut e = env(1.0);
        e.width_px = 900;
        let fs = fonts();
        let (rows, _) = flow_rows(&f, &e, &fs);
        let strip = &rows[0];
        assert!(
            strip.text.contains("push job/J? gate green"),
            "{}",
            strip.text
        );
        assert!(strip.text.contains('…'), "{}", strip.text);
        let (at, stop) = *strip.stops.last().expect("a stop");
        let left: String = strip.text.chars().take(at as usize).collect();
        let icons = strip.images.iter().filter(|i| i.0 < at).count() as u32;
        let px = text_px(&fs, &left) + icons * dpx(&e, 14.0);
        assert!(px <= stop, "{px} > {stop}: {left}");
        // narrower still: the cost and the machines give way to what needs you
        e.width_px = 400;
        let (rows, _) = flow_rows(&f, &e, &fs);
        let strip = &rows[0];
        assert!(
            strip.stops.is_empty() && !strip.text.contains("desk 4/6"),
            "{}",
            strip.text
        );
        assert!(
            strip.text.contains("push job/J? gate green"),
            "{}",
            strip.text
        );
        // a push gate not green yet: no push chip; no budget: the cost alone
        let f = Flow {
            cost: Some((1.5, None)),
            ..flow()
        };
        let strip = &flow_rows(&f, &env(1.0), &fonts()).0[0];
        assert!(!strip.text.contains("push job/"));
        assert!(strip.text.contains("$1.50") && !strip.text.contains(" / $"));
    }

    /// [D] The Rules tile: its heading, the columns, a row per rule (its words, its kind as a chip, how the hub holds
    /// it); an enforced rule's chip carries a lock in the ok face, the others are in the accent; no pack says so.
    #[test]
    fn the_rules_tile_lists_the_pack() {
        let mut f = flow();
        f.pack.as_mut().unwrap().rules[2].kind = "routing".into();
        let (rows, images) = rules_rows(&f, &env(1.0));
        let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
        assert_eq!(
            keys,
            [
                "rules-head",
                "rules-cols",
                "rule:red-first",
                "rule:author-check",
                "rule:review"
            ]
        );
        assert!(rows[0].text.contains("Rules · drgnx-org v4"));
        assert!(rows[1].text.contains("How the hub holds it"));
        let red = &rows[2];
        assert!(red.text.contains("red-first doc") && red.text.contains("enforced"));
        assert!(red.text.contains("checked at the merge"));
        assert!(red.runs.iter().any(|r| r.2 == Chip::Ok.face()));
        assert_eq!(red.images.len(), 1);
        assert!(rows[4].runs.iter().any(|r| r.2 == Chip::Run.face()));
        assert!(rows[4].images.is_empty());
        assert!(!images.is_empty());
        let none = Flow {
            pack: None,
            ..flow()
        };
        let (rows, _) = rules_rows(&none, &env(1.0));
        assert_eq!(rows.len(), 1);
        assert!(rows[0].text.contains("no rule pack"));
    }

    /// [D] The detail tile of a held task: its head (id and card on it), why it is held (the card's words and the
    /// held gates), what clears it, the evidence so far, and the actions with their keys, the waiver the user's
    /// alone; a task the gates don't hold has no hold sections and only the evidence action; an unknown task says so.
    #[test]
    fn the_detail_tile_says_why_a_task_is_held_and_what_clears_it() {
        let mut f = flow();
        f.tasks[1].evidence = vec![ev("green", "s", parse("test a::x ... ok\n"))];
        // the tile's width: 50 cells
        let mut tile = env(1.0);
        tile.width_px = 400;
        let rows = detail_rows(&f, "task:J#5", &tile);
        let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
        let all = text.join("\n");
        assert!(
            text[0].starts_with("T5") && text[0].contains("Task 5"),
            "{all}"
        );
        assert!(
            rows[0]
                .props
                .iter()
                .any(|p| p.2 == "drgnx-work-card" && p.3 == json!(42))
        );
        for want in [
            "Why it is held",
            "no red",
            "Red first: no red",
            "What clears it",
            "test commit",
            "Evidence so far",
            "green",
            "1 pass",
            "Run the red r",
            "Tell the agent s",
            "Waive once w",
            "Evidence e",
            "yours only",
        ] {
            assert!(all.contains(want), "no {want:?} in\n{all}");
        }
        // the lines fit the tile: none longer than its width in cells
        assert!(text.iter().all(|t| t.chars().count() <= 50), "{all}");
        let free = detail_rows(&f, "task:J#1", &tile);
        let free_all: Vec<&str> = free.iter().map(|r| r.text.as_str()).collect();
        let free_all = free_all.join("\n");
        assert!(
            !free_all.contains("Why it is held") && !free_all.contains("Waive"),
            "{free_all}"
        );
        assert!(free_all.contains("Evidence e") && free_all.contains("none recorded"));
        let none = detail_rows(&f, "task:J#99", &tile);
        assert_eq!(none.len(), 1);
        assert!(none[0].text.contains("Select a task"));
    }
}
