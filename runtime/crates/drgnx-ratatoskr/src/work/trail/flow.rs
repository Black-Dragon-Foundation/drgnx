//! The Flow lens as rows and a model (`work/flow/subscribe`; docs/develop/orchestration.md, "The Flow lens"): a plan
//! run's tasks as rows, the gates as columns (Brief, Red first, Build, Author check, Merge batch, Review), each cell a
//! chip of the gate's state; under them the merge batch, the line gate and the rule pack.  Pure: the facts in, the
//! cells, the model and the rows out.
//!
//! The model is the lens's own: a `task` node per task with the `flow` form's links (up and down), the lists `tasks`
//! and `held` (the tasks a gate holds: the needs-you chips).

use crate::view::model::Doc;
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

/// The lens's facts: the job, its pack, its tasks, the batch's and the line gate's lines.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Flow {
    pub job: String,
    pub title: String,
    pub pack: Option<Pack>,
    pub tasks: Vec<TaskFacts>,
    /// The merge batch being checked: (task label, what it is at).
    pub batch: Vec<(String, String)>,
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
    } else if let Some(why) = &t.held {
        cell(Chip::Held, fit(why, 24))
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

/// The columns' left edges for ENV: the task (200 px), the agent (118 px), then six gate columns sharing the rest,
/// each at least 96 px (the mockup's grid, in device px).
fn stops(env: &ViewEnv) -> (Vec<u32>, u32) {
    let px = |v: f32| (f64::from(v) * f64::from(env.scale) + 0.5 + 1e-9).floor() as u32;
    let (task, agent) = (px(200.0), px(118.0));
    let gate = (env.width_px.saturating_sub(task + agent + px(20.0)) / 6).max(px(96.0));
    let mut out = vec![0, task];
    for i in 0..6 {
        out.push(task + agent + i * gate);
    }
    (out, gate)
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

/// CELL drawn at the cursor of B, its text cut to CHARS: a waiting cell with nothing to say is an empty ring; a
/// passed author check carries a check, a held cell a lock; a gate the pack lacks (or one that waits on another) is
/// its words in the label face.
fn draw_cell(b: &mut RowBuilder, pics: &mut Pics, gate: &str, c: &Cell, chars: usize) {
    let text = fit(&c.text, chars);
    match c.chip {
        Chip::Wait if c.text == "—" => {
            let start = b.pos();
            pics.put(b, "circle", "○");
            let end = b.pos();
            b.face(start, end, LABEL);
        }
        Chip::Na => {
            b.push(&text, Some(LABEL));
        }
        Chip::Ok if gate == "Author check" => {
            chip(b, pics, Some(("check", "✓")), &text, c.chip.face())
        }
        Chip::Held => chip(b, pics, Some(("lock", "!")), &text, c.chip.face()),
        _ => chip(b, pics, None, &text, c.chip.face()),
    }
}

/// The lens's rows for ENV and the icons they draw: the run's line, the needs-you chips (one per held task, carrying
/// its id), the column headings with their icons, a row per task (its id, title, agent and a chip per gate, carrying
/// the task's id and its gate card), then the merge batch's lines.  The rule pack is its own tile ([`rules_rows`]).
pub(crate) fn flow_rows(flow: &Flow, env: &ViewEnv) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let cell_w = env.cell.0.max(1);
    let (at, gate) = stops(env);
    let chars = |w: u32| (w.saturating_sub(8) / cell_w) as usize;
    let mut pics = Pics::new(env);
    let ts = tasks(flow);
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
    let mut rows = vec![head.finish()];
    // the needs-you chips: a task a gate holds, with why (its card's words)
    let held: Vec<&Task> = ts.iter().filter(|t| t.held.is_some()).collect();
    if !held.is_empty() {
        let mut b = RowBuilder::new("needs");
        for (i, t) in held.iter().enumerate() {
            if i > 0 {
                b.push("  ", None);
            }
            let start = b.pos();
            let why = t.held.as_deref().unwrap_or_default();
            chip(
                &mut b,
                &mut pics,
                Some(("flag", "⚑")),
                &format!("{} held: {}", t.label, fit(why, 48)),
                Chip::Held.face(),
            );
            let end = b.pos();
            b.prop(start, end, "drgnx-work-id", json!(t.id));
        }
        rows.push(b.finish());
    }
    let mut cols = RowBuilder::new("cols");
    for (i, name) in ["Task", "Agent"].iter().chain(GATES.iter()).enumerate() {
        cols.stop(at[i]);
        if i >= 2 {
            let start = cols.pos();
            pics.put(&mut cols, gate_icon(name), " ");
            cols.push(" ", None);
            let end = cols.pos();
            cols.face(start, end, LABEL);
        }
        cols.push(name, Some(LABEL));
    }
    rows.push(cols.finish());
    if ts.is_empty() {
        let mut b = RowBuilder::new("none");
        b.push("No tasks yet.", Some(LABEL));
        rows.push(b.finish());
    }
    for t in &ts {
        let mut b = RowBuilder::new(format!("task:{}", t.id));
        let start = b.pos();
        b.push(&format!("{:<4}", t.label), Some(LABEL))
            .push(&fit(&t.title, chars(at[1]).saturating_sub(4)), Some(TEXT));
        b.stop(at[1]).push(
            &fit(t.agent.as_deref().unwrap_or("—"), chars(at[2] - at[1])),
            Some(LABEL),
        );
        for (i, c) in t.cells.iter().enumerate() {
            b.stop(at[i + 2]);
            draw_cell(
                &mut b,
                &mut pics,
                GATES[i],
                c,
                chars(gate).saturating_sub(4),
            );
        }
        let end = b.pos();
        b.prop(start, end, "drgnx-work-id", json!(t.id));
        if let Some(card) = t.card {
            b.prop(start, end, "drgnx-work-card", json!(card));
        }
        rows.push(b.finish());
    }
    let mut blank = RowBuilder::new("gap");
    blank.push("", None);
    rows.push(blank.finish());
    let mut bh = RowBuilder::new("batch");
    pics.put(&mut bh, "git-merge", " ");
    bh.push(" ", None)
        .push(&format!("Merge batch → job/{}", flow.job), Some(HEAD));
    if flow.batch.is_empty() {
        bh.push("  empty", Some(LABEL));
    }
    rows.push(bh.finish());
    for (i, (who, what)) in flow.batch.iter().enumerate() {
        let mut b = RowBuilder::new(format!("batch:{i}"));
        b.push(&format!("  {who}"), Some(TEXT))
            .stop(at[2])
            .push(what, Some(LABEL));
        rows.push(b.finish());
    }
    (rows, pics.out)
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
        // the author check waits for the red
        assert_eq!((c[3].chip, c[3].text.as_str()), (Chip::Na, "waits red"));
        assert_eq!(c[4].chip, Chip::Held);
        assert!(c[4].text.ends_with('…'), "{}", c[4].text);
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
            batch: vec![("T2".into(), "trial merge clean".into())],
        }
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
            let (rows, images) = flow_rows(&flow(), &env(scale));
            let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
            assert_eq!(
                keys,
                [
                    "head",
                    "needs",
                    "cols",
                    "task:task:J#1",
                    "task:task:J#5",
                    "task:task:J#8",
                    "gap",
                    "batch",
                    "batch:0",
                ]
            );
            assert!(
                rows[0].text.contains("Search view") && rows[0].text.contains("rules drgnx-org v4")
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
            let needs = &rows[1];
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
            assert_eq!(stops[0], px(200.0), "scale {scale}");
            assert_eq!(stops[1], px(318.0), "scale {scale}");
            assert_eq!(stops.len(), 7);
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
        assert_eq!(flow_rows(&empty, &env(1.0)).0[2].key, "none");
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
