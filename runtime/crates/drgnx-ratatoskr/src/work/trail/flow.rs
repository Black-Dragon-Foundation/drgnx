//! The Flow lens as rows and a model (`work/flow/subscribe`; docs/develop/orchestration.md, "The Flow lens"): a plan
//! run's tasks as rows, the gates as columns (Brief, Red first, Build, Author check, Merge batch, Review), each cell a
//! chip of the gate's state; under them the merge batch, the line gate and the rule pack.  Pure: the facts in, the
//! cells, the model and the rows out.
//!
//! The model is the lens's own: a `task` node per task with the `flow` form's links (up and down), the lists `tasks`
//! and `held` (the tasks a gate holds: the needs-you chips).

use crate::view::model::Doc;
use drgnx_rows::{Row, RowBuilder};
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

impl Chip {
    /// The chip's face.
    pub(crate) fn face(self) -> &'static str {
        match self {
            Chip::Ok => "drgnx-chip-ok",
            Chip::Run => "drgnx-chip-accent",
            Chip::Held => "drgnx-chip-attention",
            Chip::Err => "drgnx-chip-error",
            Chip::Wait => "drgnx-chip-quiet",
            Chip::Na => "drgnx-work-label",
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
        cell(Chip::Ok, format!("{} failed", failing(&r.rows).count()))
    } else if t.status == "in-review" || t.held.is_some() {
        cell(Chip::Held, "no red")
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

/// The lens's rows for ENV: the run's line, the column headings, a row per task (its id, title, agent and a chip per
/// gate, each carrying the task's id), then the merge batch's lines and the rule pack's.
pub(crate) fn flow_rows(flow: &Flow, env: &ViewEnv) -> Vec<Row> {
    let cell_w = env.cell.0.max(1);
    let (at, gate) = stops(env);
    let chars = |w: u32| (w.saturating_sub(8) / cell_w) as usize;
    let ts = tasks(flow);
    let done = ts.iter().filter(|t| t.cells[4].chip == Chip::Ok).count();
    let mut head = RowBuilder::new("head");
    head.push(&flow.title, Some("bold")).push(
        &format!(
            " · job/{} · rules {} · {done} / {} done",
            flow.job,
            flow.pack.as_ref().map_or("none", |p| p.name.as_str()),
            ts.len()
        ),
        Some("drgnx-work-label"),
    );
    let mut rows = vec![head.finish()];
    let mut cols = RowBuilder::new("cols");
    for (i, name) in ["Task", "Agent"].iter().chain(GATES.iter()).enumerate() {
        cols.stop(at[i]).push(name, Some("drgnx-work-label"));
    }
    rows.push(cols.finish());
    if ts.is_empty() {
        let mut b = RowBuilder::new("none");
        b.push("No tasks yet.", Some("drgnx-work-label"));
        rows.push(b.finish());
    }
    for t in &ts {
        let mut b = RowBuilder::new(format!("task:{}", t.id));
        let start = b.pos();
        b.push(&format!("{:<4}", t.label), Some("drgnx-work-label"))
            .push(&fit(&t.title, chars(at[1]).saturating_sub(4)), None);
        b.stop(at[1]).push(
            &fit(t.agent.as_deref().unwrap_or("—"), chars(at[2] - at[1])),
            Some("drgnx-work-label"),
        );
        for (i, c) in t.cells.iter().enumerate() {
            b.stop(at[i + 2]);
            let text = fit(&c.text, chars(gate).saturating_sub(2));
            b.push(&format!(" {text} "), Some(c.chip.face()));
        }
        let end = b.pos();
        b.prop(start, end, "drgnx-work-id", json!(t.id));
        rows.push(b.finish());
    }
    let mut blank = RowBuilder::new("gap");
    blank.push("", None);
    rows.push(blank.finish());
    let mut bh = RowBuilder::new("batch");
    bh.push(&format!("Merge batch → job/{}", flow.job), Some("bold"));
    if flow.batch.is_empty() {
        bh.push(" · empty", Some("drgnx-work-label"));
    }
    rows.push(bh.finish());
    for (i, (who, what)) in flow.batch.iter().enumerate() {
        let mut b = RowBuilder::new(format!("batch:{i}"));
        b.push(&format!("  {who}"), None)
            .stop(at[2])
            .push(what, Some("drgnx-work-label"));
        rows.push(b.finish());
    }
    if let Some(p) = &flow.pack {
        let mut rh = RowBuilder::new("rules");
        rh.push(&format!("Rules · {} v{}", p.name, p.version), Some("bold"));
        rows.push(rh.finish());
        for r in &p.rules {
            let mut b = RowBuilder::new(format!("rule:{}", r.id));
            b.push(&format!("  {}", r.id), None)
                .stop(at[2])
                .push(&r.kind, Some("drgnx-work-label"))
                .stop(at[3])
                .push(
                    &fit(&r.doc, chars(env.width_px.saturating_sub(at[3]))),
                    Some("drgnx-work-label"),
                );
            rows.push(b.finish());
        }
    }
    rows
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
                (Chip::Ok, "2 failed"),
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
        assert_eq!((c[1].chip, c[1].text.as_str()), (Chip::Held, "no red"));
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

    /// [D] The rows: the run's line, the headings, a row per task with a chip per gate in its state's face at the
    /// column's stop (device px: the scale's), the task's id on the row; then the batch and the rules.
    #[test]
    fn the_flow_rows_put_a_chip_per_gate_at_its_column() {
        for scale in [1.0, 2.0] {
            let rows = flow_rows(&flow(), &env(scale));
            let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
            assert_eq!(
                keys,
                [
                    "head",
                    "cols",
                    "task:task:J#1",
                    "task:task:J#5",
                    "task:task:J#8",
                    "gap",
                    "batch",
                    "batch:0",
                    "rules",
                    "rule:red-first",
                    "rule:author-check",
                    "rule:review"
                ]
            );
            assert!(
                rows[0].text.contains("Search view") && rows[0].text.contains("rules drgnx-org")
            );
            let px = |v: f32| (v * scale).round() as u32;
            let held = &rows[3];
            let stops: Vec<u32> = held.stops.iter().map(|s| s.1).collect();
            assert_eq!(stops[0], px(200.0), "scale {scale}");
            assert_eq!(stops[1], px(318.0), "scale {scale}");
            assert_eq!(stops.len(), 7);
            let faces: Vec<&str> = held.runs.iter().map(|r| r.2.as_str()).collect();
            assert!(faces.contains(&"drgnx-chip-attention"), "{faces:?}");
            assert!(
                held.props
                    .iter()
                    .any(|p| p.2 == "drgnx-work-id" && p.3 == json!("task:J#5"))
            );
            assert!(rows[1].text.contains("Red first") && rows[1].text.contains("Merge batch"));
        }
        let empty = Flow {
            tasks: vec![],
            ..flow()
        };
        assert_eq!(flow_rows(&empty, &env(1.0))[2].key, "none");
    }
}
