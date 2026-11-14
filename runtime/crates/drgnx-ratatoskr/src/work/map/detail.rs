//! The Detail panel's rows (docs/develop/work-space.md, "Selection, the chain and the side panel"): what the map's
//! selection is, why it exists, what it touches, its conclusion and, for a machine, its queue, built from the map's
//! model and sent as the rows of the view `VIEW/detail` beside the map's own. Pure: the model and the selection in,
//! lines out; the rows are those lines, one per row.

use drgnx_rows::fit::{self, Measure};
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
fn why(m: &Model, it: &Item) -> Vec<(&'static str, String)> {
    let mut chain: Vec<(&'static str, String)> = Vec::new();
    let mut cur = it.id.clone();
    for _ in 0..8 {
        let Some(p) = parent(m, &cur) else { break };
        if let Some(pi) = m.item(&p) {
            let kind = word(&pi.kind);
            chain.push(match kind.as_str() {
                "ask" => ("you", format!("“{}”", pi.label)),
                "spec" => ("spec", pi.label),
                "plan" => ("plan", pi.label),
                _ => ("", pi.label),
            });
        }
        cur = p;
    }
    chain.reverse();
    chain.extend(it.fields.task.clone().map(|t| ("task", t)));
    chain
}

/// The edges of ID as `KEY\tVALUE` lines, both ways: the key names what the other end is to this one.
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
            ("came-from", true) => Some(format!(
                "{}\t{other} — came from this",
                kind_key(m, if here_from { &e.to } else { &e.from })
            )),
            ("came-from", false) => None,
            ("edits", true) => Some(format!("edits\t{other}")),
            ("edits", false) => Some(format!("edited by\t{other}")),
            ("reads", true) => Some(format!("reads\t{other}")),
            ("reads", false) => Some(format!("read by\t{other}")),
            ("runs-on", true) => Some(format!("machine\t{other}")),
            ("runs-on", false) => Some(format!("runs here\t{other}")),
            ("overlap", _) => Some(format!("overlap\t⚠ {other}")),
            ("based-on", true) => Some(format!("cut from\t{other}")),
            ("based-on", false) => Some(format!("cut here\t{other}")),
            _ => Some(format!("{kind}\t{other}")),
        };
        out.extend(line);
    }
    out
}

/// The Touches lines of IT. An agent's, in the mockup's order: its branch, its machine and slot, what it edits (the
/// branch's file that changed most, with its change), what it reads, then the rest (overlaps...); another item's
/// are its edges, then its own counts.
fn touches(m: &Model, it: &Item) -> Vec<String> {
    let f = &it.fields;
    let mut edges = edge_lines(m, &it.id);
    if word(&it.kind) != "agent" {
        if let Some(r) = f.reads {
            edges.push(format!("reads\t{r} files"));
        }
        if let Some((n, plus, minus)) = f.edits {
            edges.push(format!("edits\t{n} files +{plus} −{minus}"));
        }
        return edges;
    }
    let take = |edges: &mut Vec<String>, key: &str| -> Option<String> {
        let at = edges
            .iter()
            .position(|l| l.split('\t').next() == Some(key))?;
        Some(edges.remove(at))
    };
    let mut out = Vec::new();
    let branch = take(&mut edges, "branch");
    let branch_item = m
        .edges()
        .into_iter()
        .filter(|e| e.from == it.id && word(&e.kind) == "came-from")
        .filter_map(|e| m.item(&e.to))
        .find(|b| word(&b.kind) == "branch");
    out.extend(branch.map(|l| {
        let name = l.split_once('\t').map_or("", |(_, v)| v);
        format!("branch\t{}", name.split(" — ").next().unwrap_or(name))
    }));
    // "desktop · slot 3": the machine, and the slot its branch's tag ends in
    let machine = take(&mut edges, "machine");
    let slot = branch_item
        .as_ref()
        .and_then(|b| b.fields.tag.as_deref())
        .and_then(|t| t.rsplit(' ').next())
        .filter(|n| n.chars().all(|c| c.is_ascii_digit()));
    out.extend(machine.map(|l| {
        let name = l.split_once('\t').map_or("", |(_, v)| v);
        match slot {
            Some(n) => format!("machine\t{name} · slot {n}"),
            None => l.clone(),
        }
    }));
    // edits: the file its branch changed most, with its change (`edits\tNAME +P −M`, the value's parts in faces)
    let top = branch_item.as_ref().and_then(|b| {
        m.edges()
            .into_iter()
            .filter(|e| e.from == b.id && word(&e.kind) == "edits")
            .filter_map(|e| m.item(&e.to))
            .filter_map(|file| file.fields.change.map(|(p, d)| (file.label, p, d)))
            .max_by_key(|(_, p, d)| p + d)
    });
    if let Some((path, plus, minus)) = top {
        let name = path.rsplit('/').next().unwrap_or(&path);
        out.push(format!("edits\t{name} +{plus} −{minus}"));
    }
    while take(&mut edges, "edits").is_some() {}
    out.extend(
        f.reads
            .filter(|r| *r > 0)
            .map(|r| format!("reads\t{r} files ▸")),
    );
    while take(&mut edges, "reads").is_some() {}
    out.extend(edges);
    out
}

/// What an item is, as a key: "branch", "file", "machine"…
fn kind_key(m: &Model, id: &ItemId) -> String {
    m.item(id).map_or_else(String::new, |it| word(&it.kind))
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
        // the queue goes before the actions
        let at = out
            .iter()
            .position(|l| l.0 == "actions")
            .unwrap_or(out.len());
        let queue = machine_queue(m, &it, now)
            .into_iter()
            .map(|(l, job)| ("queue", l, job));
        out.splice(at..at, queue);
    }
    out
}

/// An agent's head (work-space-dark.html `.det .hd`): its badge (its initial and its number), its name and its state
/// tab-separated, then its task, how long it has run and what it cost.
fn agent_head(it: &Item) -> Vec<(&'static str, String)> {
    let f = &it.fields;
    let letter = f
        .model
        .as_deref()
        .and_then(|m| m.chars().next())
        .map_or('?', |c| c.to_ascii_uppercase());
    let number = vegvisir::render::agent_number(it);
    let chip = f
        .activity
        .clone()
        .or_else(|| state_word(it))
        .unwrap_or_default();
    let mut sub: Vec<String> = f.task.clone().into_iter().collect();
    let run = [state_word(it), f.minutes.map(|n| format!("{n} min"))]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" ");
    if !run.is_empty() {
        sub.push(run);
    }
    if let Some(spend) = &f.spend {
        sub.push(format!("≈{} (API prices)", spend.trim_start_matches('≈')));
    }
    vec![
        ("head", format!("{letter}{number}\t{}\t{chip}", it.label)),
        ("head", sub.join(" · ")),
    ]
}

/// The lines of IT every kind has: head, why, touches, conclusions, actions.
fn text_lines(m: &Model, it: &Item) -> Vec<Line> {
    let f = &it.fields;
    let mut out = if word(&it.kind) == "agent" {
        agent_head(it)
    } else {
        vec![("head", format!("{} · {}", it.label, word(&it.kind)))]
    };
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
    if !bits.is_empty() && word(&it.kind) != "agent" {
        out.push(("head", bits.join(" · ")));
    }
    out.push(("why", "Why ↑".into()));
    let w = why(m, it);
    if w.is_empty() {
        out.push(("why", "  no ask, spec or plan recorded".into()));
    }
    out.extend(w.into_iter().map(|(k, l)| ("why", format!("{k}\t{l}"))));
    out.push(("touches", "Touches ↓".into()));
    let t = touches(m, it);
    if t.is_empty() {
        out.push(("touches", "  nothing yet".into()));
    }
    out.extend(t.into_iter().map(|l| ("touches", l)));
    out.push(("conclusions", "Conclusions".into()));
    out.push((
        "conclusions",
        f.conclusion
            .as_ref()
            .map_or_else(|| "  none recorded".into(), |c| format!("  → {c}")),
    ));
    // the keys of the default profile, as the mockup shows them; an agent has the rest
    let acts: &[(&str, &str)] = if word(&it.kind) == "agent" {
        &[
            ("Open", "⏎"),
            ("Files", "e"),
            ("Diffs", "d"),
            ("Trail", "r"),
            ("Steer", "s"),
            ("Pause", "p"),
            ("Review", "v"),
        ]
    } else {
        &[("Open", "⏎")]
    };
    // the buttons in rows of four, as the mockup wraps them
    for row in acts.chunks(4) {
        out.push((
            "actions",
            row.iter()
                .map(|(l, k)| format!("{l}\t{k}"))
                .collect::<Vec<_>>()
                .join("\t"),
        ));
    }
    out.into_iter().map(|(s, t)| (s, t, None)).collect()
}

/// The UI font role the Detail text is measured in.
const ROLE: &str = "text";

/// TEXT wrapped by word into lines of at most ROOM px, none cut and no continuation glyph (the mockup's subtitle
/// is two lines at the tile's width).
fn wrap(text: &str, room: f32, m: &dyn Measure) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for word in text.split(' ') {
        match lines.last_mut() {
            Some(last) if fit::width(m, ROLE, &format!("{last} {word}")) <= room - fit::SLACK => {
                last.push(' ');
                last.push_str(word);
            }
            _ => lines.push(word.to_owned()),
        }
    }
    lines
}

/// The width of the key column, logical px.
const KEY_PX: f32 = 66.0;

/// The rows of LINES at SCALE: one per line, keyed `SECTION/N` (N its place in the panel), in the card's UI font
/// (work-space-dark.html `.det`): the head's first line in the heading face, a section's name in it too, a
/// `KEY\tVALUE` line as a muted key and its value in a column (an agent's why-chain and a link in the accent, an
/// overlap in the warning colour), an action as a button and its key. A job's line carries its id as
/// `drgnx-work-job`.
pub(crate) fn rows(lines: &[Line], scale: f32, width_px: u32, m: &dyn Measure) -> Vec<Row> {
    let key_px = (KEY_PX * scale).round() as u32;
    let room = width_px as f32 - 16.0 * scale;
    lines
        .iter()
        .enumerate()
        .flat_map(|(i, (section, text, job))| {
            // the head's subtitle (its second line) wraps by word into rows of its own, no continuation glyph
            if *section == "head" && i == 1 && !text.contains('\t') {
                return wrap(text, room, m)
                    .into_iter()
                    .enumerate()
                    .map(|(k, line)| {
                        let key = if k == 0 {
                            format!("head/{i}")
                        } else {
                            format!("head/{i}.{k}")
                        };
                        let mut b = RowBuilder::new(key);
                        b.push(&line, Some("drgnx-text-muted"));
                        let end = b.pos();
                        b.face(0, end, "drgnx-work-card");
                        b.finish()
                    })
                    .collect::<Vec<_>>();
            }
            let mut b = RowBuilder::new(format!("{section}/{i}"));
            match (*section, text.split_once('\t')) {
                // an agent's head: its badge, its name and its state as a chip at the right edge
                ("head", Some(_)) if i == 0 => {
                    let parts: Vec<&str> = text.split('\t').collect();
                    let badge = parts[0];
                    let letter = badge.chars().next().unwrap_or('?');
                    let number = badge.chars().last().unwrap_or('1');
                    let from = b.pos();
                    b.push(
                        &format!(" {letter} "),
                        Some(&format!("drgnx-work-agent-{number}")),
                    );
                    let to = b.pos();
                    b.face(from, to, "drgnx-badge");
                    b.push(" ", None)
                        .push(parts.get(1).unwrap_or(&""), Some("drgnx-ui-heading"));
                    if let Some(chip) = parts.get(2).filter(|c| !c.is_empty()) {
                        let width = (chip.chars().count() as f32 * 7.0 + 28.0) * scale;
                        b.stop(width_px.saturating_sub(width as u32));
                        let from = b.pos();
                        b.push(&format!(" {chip} "), None);
                        let to = b.pos();
                        b.face(from, to, "drgnx-chip");
                    }
                }
                ("actions", Some(_)) => {
                    let parts: Vec<&str> = text.split('\t').collect();
                    for (n, pair) in parts.chunks(2).enumerate() {
                        if n > 0 {
                            b.push("  ", None);
                        }
                        b.push(&format!(" {} ", pair[0]), Some("drgnx-button"))
                            .push(" ", None)
                            .push(
                                &format!(" {} ", pair.get(1).unwrap_or(&"")),
                                Some("drgnx-keycap"),
                            );
                    }
                }
                ("touches", Some(("edits", value))) => {
                    // `NAME +P −M`: the file in the code font, its change in the added and removed colours
                    b.push("edits", Some("drgnx-text-muted")).stop(key_px);
                    let mut it = value.split(' ');
                    b.push(it.next().unwrap_or(""), Some("drgnx-work-meta"));
                    for w in it {
                        let face = if w.starts_with('+') {
                            "drgnx-work-plus"
                        } else {
                            "drgnx-work-minus"
                        };
                        b.push(" ", None).push(w, Some(face));
                    }
                }
                (s, Some((key, value))) => {
                    b.push(key, Some("drgnx-text-muted")).stop(key_px);
                    let face = match (s, key) {
                        ("why", _) => "drgnx-accent",
                        (_, "overlap") => "drgnx-work-overlap",
                        _ => "drgnx-work-card",
                    };
                    b.push(value, Some(face));
                }
                ("head", None) if i == 0 => {
                    b.push(text, Some("drgnx-ui-heading"));
                }
                ("head", None) => {
                    b.push(text, Some("drgnx-text-muted"));
                }
                (_, None) if !text.starts_with(' ') => {
                    b.push(text, Some("drgnx-ui-heading"));
                }
                (_, None) => {
                    b.push(text, None);
                }
            }
            let end = b.pos();
            b.face(0, end, "drgnx-work-card");
            if let Some(id) = job {
                b.prop(0, end, "drgnx-work-job", Value::String(id.clone()));
            }
            vec![b.finish()]
        })
        .collect()
}
