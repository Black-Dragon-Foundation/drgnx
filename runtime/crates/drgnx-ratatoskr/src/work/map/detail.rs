//! The Detail panel's rows (docs/develop/work-space.md, "Selection, the chain and the side panel"): what the map's
//! selection is, why it exists, what it touches, its conclusion and, for a machine, its queue, built from the map's
//! model and sent as the rows of the view `VIEW/detail` beside the map's own. Pure: the model and the selection in,
//! lines out; the rows are those lines, one per row.

use drgnx_rows::{Row, RowBuilder};
use serde_json::Value;
use vegvisir::{Item, ItemId, Model};

/// The name of the Detail view beside the map view VIEW.
pub(crate) fn view_of(map_view: &str) -> String {
    format!("{map_view}/detail")
}

/// The map view a Detail view VIEW sits beside, when it is one.
pub(crate) fn map_of(view: &str) -> Option<&str> {
    view.strip_suffix("/detail")
}

/// A serde enum's word (`agent`, `came-from`, `needs-you`).
fn word<T: serde::Serialize>(t: &T) -> String {
    match serde_json::to_value(t) {
        Ok(Value::String(s)) => s,
        _ => String::new(),
    }
}

fn label(m: &Model, id: &ItemId) -> String {
    m.item(id).map_or_else(|| id.0.clone(), |it| it.label)
}

/// What ID came from: the first `came-from` edge into it, by id.
fn parent(m: &Model, id: &ItemId) -> Option<ItemId> {
    m.edges()
        .into_iter()
        .filter(|e| &e.to == id && word(&e.kind) == "came-from")
        .map(|e| e.from)
        .min()
}

/// The why-chain of ID: the first parent at each level, from the ask down, then its task.
fn why(m: &Model, it: &Item) -> Vec<String> {
    let mut chain = Vec::new();
    let mut cur = it.id.clone();
    for _ in 0..8 {
        let Some(p) = parent(m, &cur) else { break };
        if let Some(pi) = m.item(&p) {
            chain.push(if word(&pi.kind) == "ask" {
                format!("you: \"{}\"", pi.label)
            } else {
                pi.label
            });
        }
        cur = p;
    }
    chain.reverse();
    chain.extend(it.fields.task.clone());
    chain
}

/// The edges of ID in words, both ways.
fn edge_lines(m: &Model, id: &ItemId) -> Vec<String> {
    let mut out = Vec::new();
    for e in m.edges() {
        let (here_from, here_to) = (&e.from == id, &e.to == id);
        if !here_from && !here_to {
            continue;
        }
        let other = label(m, if here_from { &e.to } else { &e.from });
        let kind = word(&e.kind);
        let line = match (kind.as_str(), here_from) {
            ("came-from", true) => Some(format!("{other} — came from this")),
            ("came-from", false) => None,
            ("edits", true) => Some(format!("edits {other}")),
            ("edits", false) => Some(format!("edited by {other}")),
            ("reads", true) => Some(format!("reads {other}")),
            ("reads", false) => Some(format!("read by {other}")),
            ("runs-on", true) => Some(format!("runs on {other}")),
            ("runs-on", false) => Some(format!("{other} runs on this")),
            ("overlap", _) => Some(format!("overlaps with {other}")),
            ("based-on", true) => Some(format!("cut from {other}")),
            ("based-on", false) => Some(format!("{other} was cut from this")),
            _ => Some(format!("{kind}: {other}")),
        };
        out.extend(line);
    }
    out
}

fn state_word(it: &Item) -> Option<String> {
    it.fields
        .state
        .as_ref()
        .map(|s| word(s).replace("needs-you", "needs you"))
}

/// A job's elapsed time against its time box at NOW: `M:SS/Nm`.
fn job_time(started: u64, limit: Option<u32>, now: u64) -> String {
    let secs = now.saturating_sub(started);
    let limit = limit.map(|l| format!("/{l}m")).unwrap_or_default();
    format!("{}:{:02}{limit}", secs / 60, secs % 60)
}

/// A machine's queue: the jobs running on it, then (for the local machine or a runner) those waiting for one; a
/// job's line carries its id (for `drgnx-work-job-log`).
fn machine_queue(m: &Model, machine: &Item, now: u64) -> Vec<(String, Option<String>)> {
    let name = &machine.label;
    let takes_waiting = name == "local" || machine.fields.runner.is_some();
    let (mut running, mut waiting) = (Vec::new(), Vec::new());
    for it in m.items().into_values() {
        let Some(job) = it.fields.job.as_ref().filter(|_| word(&it.kind) == "agent") else {
            continue;
        };
        let mut bits = vec![
            job.name.clone(),
            it.label.clone(),
            job.runner
                .clone()
                .unwrap_or_else(|| "waiting for a machine".into()),
            job.state.clone(),
        ];
        if job.state == "running" {
            bits.push(job_time(job.started, job.limit_min, now));
        }
        if !job.keys.is_empty() {
            bits.push(format!("keys: {}", job.keys.join(", ")));
        }
        let row = (format!("  {}", bits.join(" · ")), Some(job.id.clone()));
        match &job.runner {
            Some(r) if r == name => running.push(row),
            None if takes_waiting => waiting.push(row),
            _ => {}
        }
    }
    if running.is_empty() && waiting.is_empty() {
        return Vec::new();
    }
    let mut out = vec![(format!("queue · {name}"), None)];
    out.extend(running);
    if !waiting.is_empty() {
        out.push(("waiting".into(), None));
        out.extend(waiting);
    }
    out.push(("  l live log".into(), None));
    out
}

/// One line of the panel: its section, its text and, on a queue's job, the job's id.
pub(crate) type Line = (&'static str, String, Option<String>);

/// The panel's lines for SEL in M at NOW (seconds since the epoch), each with its section: head, why, touches,
/// conclusions, queue, actions. Nothing selected, or an item the model no longer holds: one head line.
pub(crate) fn lines(m: &Model, sel: Option<&ItemId>, now: u64) -> Vec<Line> {
    let Some(it) = sel.and_then(|s| m.item(s)) else {
        return vec![("head", "Nothing is selected.".into(), None)];
    };
    let mut out = text_lines(m, &it);
    if word(&it.kind) == "machine" {
        let at = out.len() - 2; // the queue goes before the actions
        let queue = machine_queue(m, &it, now)
            .into_iter()
            .map(|(l, job)| ("queue", l, job));
        out.splice(at..at, queue);
    }
    out
}

/// The lines of IT every kind has: head, why, touches, conclusions, actions.
fn text_lines(m: &Model, it: &Item) -> Vec<Line> {
    let f = &it.fields;
    let mut out = vec![("head", format!("{} · {}", it.label, word(&it.kind)))];
    let bits: Vec<String> = [
        state_word(it),
        f.minutes.map(|n| format!("{n} min")),
        f.spend.clone(),
        f.model.clone(),
        f.context.map(|c| format!("context {c} %")),
    ]
    .into_iter()
    .flatten()
    .collect();
    if !bits.is_empty() {
        out.push(("head", bits.join(" · ")));
    }
    out.push(("why", "why ↑".into()));
    let w = why(m, it);
    if w.is_empty() {
        out.push(("why", "  no ask, spec or plan recorded".into()));
    }
    out.extend(w.into_iter().map(|l| ("why", format!("  › {l}"))));
    out.push(("touches", "touches ↓".into()));
    let t = edge_lines(m, &it.id);
    if t.is_empty() {
        out.push(("touches", "  nothing yet".into()));
    }
    out.extend(t.into_iter().map(|l| ("touches", format!("  {l}"))));
    if let Some(r) = f.reads {
        out.push(("touches", format!("  reads {r} files")));
    }
    if let Some((n, plus, minus)) = f.edits {
        out.push(("touches", format!("  edits {n} files (+{plus} −{minus})")));
    }
    out.push(("conclusions", "conclusions".into()));
    out.push((
        "conclusions",
        f.conclusion
            .as_ref()
            .map_or_else(|| "  none recorded".into(), |c| format!("  → {c}")),
    ));
    out.push(("actions", "actions".into()));
    out.push(("actions", "  open (RET)".into()));
    out.into_iter().map(|(s, t)| (s, t, None)).collect()
}

/// The rows of LINES: one per line, keyed `SECTION/N` (N its place in the panel), the head's first line in bold, a
/// job's line carrying its id as `drgnx-work-job`.
pub(crate) fn rows(lines: &[Line]) -> Vec<Row> {
    lines
        .iter()
        .enumerate()
        .map(|(i, (section, text, job))| {
            let mut b = RowBuilder::new(format!("{section}/{i}"));
            b.push(text, (i == 0).then_some("bold"));
            if let Some(id) = job {
                let end = b.pos();
                b.prop(0, end, "drgnx-work-job", Value::String(id.clone()));
            }
            b.finish()
        })
        .collect()
}
