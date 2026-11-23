//! The Detail panel's rows (docs/develop/work-space.md, "Selection, the chain and the side panel"): what the map's
//! selection is, why it exists, what it touches, its conclusion and, for a machine, its queue, built from the map's
//! model and sent as the rows of the view `VIEW/detail` beside the map's own. Pure: the model and the selection in,
//! lines out; the rows are those lines, one per row.

use rodd::faces::FaceId;
use rodd::fit::{self, Measure};
use rodd::kit::{self, ButtonStyle, Comp, KitEnv, Size, State};
use rodd::{Row, RowBuilder};
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
                "task" => ("task", pi.label),
                _ => ("", pi.label),
            });
        }
        cur = p;
    }
    chain.reverse();
    // an agent whose task is no item (a run's task) still names it
    if !chain.iter().any(|(k, _)| *k == "task") {
        chain.extend(it.fields.task.clone().map(|t| ("task", t)));
    }
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
            ("overlap", _) => {
                // `⚠ session.rs with Sonnet · fx-sess`: the file both edit, when the model knows it
                let items = m.items();
                let file = vegvisir::render::shared_file(&m.edges(), &items, &e.from, &e.to);
                Some(match file {
                    Some(f) => format!("overlap\t⚠ {f} with {other}"),
                    None => format!("overlap\t⚠ {other}"),
                })
            }
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
        let name = name.split(" — ").next().unwrap_or(name);
        match &f.worktree {
            Some(w) => format!("branch\t{name} · worktree {w}"),
            None => format!("branch\t{name}"),
        }
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

/// The item the Detail shows before anything is selected: the subject of the most urgent thing that needs you
/// (the strip's first chip), else the agent of the first task that is in progress, else none.
pub(crate) fn default_item(m: &Model) -> Option<ItemId> {
    let items = m.items();
    let sent: std::collections::BTreeMap<ItemId, Item> = items.clone();
    vegvisir::nav::strip_entries(&m.needs_you(), &sent)
        .into_iter()
        .map(|e| e.id)
        .find(|id| items.contains_key(id))
        .or_else(|| {
            items
                .values()
                .filter(|it| it.kind == vegvisir::Kind::Task)
                .filter(|it| {
                    matches!(
                        it.fields.task_state,
                        Some(vegvisir::TaskState::Running | vegvisir::TaskState::NeedsYou)
                    )
                })
                .find_map(|t| {
                    m.edges()
                        .into_iter()
                        .find(|e| {
                            e.from == t.id
                                && items
                                    .get(&e.to)
                                    .is_some_and(|i| i.kind == vegvisir::Kind::Agent)
                        })
                        .map(|e| e.to)
                })
        })
}

/// `lines` for SEL, or for the default item (`default_item`) while nothing is selected, its head saying "Needs you
/// most". Nothing selected on a map with no such item: one head line.
pub(crate) fn lines_or_default(m: &Model, sel: Option<&ItemId>, now: u64) -> Vec<Line> {
    if sel.is_some_and(|s| m.item(s).is_some()) {
        return lines(m, sel, now);
    }
    match default_item(m) {
        Some(d) => {
            let mut out = lines(m, Some(&d), now);
            // an agent's head is its badge row, then its subtitle: the words go on the subtitle; any other head is one line
            let at = usize::from(out.first().is_some_and(|l| l.1.contains('\t')));
            if let Some(l) = out.get_mut(at).filter(|l| l.0 == "head") {
                l.1 = format!("Needs you most · {}", l.1);
            }
            out
        }
        None => lines(m, None, now),
    }
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
    let chip = vegvisir::render::activity(f);
    let mut sub: Vec<String> = f.task.clone().into_iter().collect();
    let run = [
        state_word(it),
        f.age.or(f.minutes).map(|n| format!("{n} min")),
    ]
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
/// The hub's unit of a budget's unit name (kebab-case; an unknown one reads as dollars).
fn unit_of(unit: &str) -> runstav::methods::matrix::Unit {
    use runstav::methods::matrix::Unit;
    match unit {
        "usd-est" => Unit::UsdEst,
        "tokens" => Unit::Tokens,
        "count" => Unit::Count,
        "limit-share" | "share" => Unit::LimitShare,
        _ => Unit::Usd,
    }
}

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
    // paragraph comments steered to no one: they reach the next agent that writes the record
    if let Some(n) = f.comments_waiting {
        let s = if n == 1 { "" } else { "s" };
        out.push((
            "head",
            format!("{n} comment{s} waiting: no agent is writing it"),
        ));
    }
    // a job on a machine: where it runs, and why there and not elsewhere (the queue's words)
    if let Some(job) = &f.job
        && let Some(on) = &job.runner
    {
        out.push((
            "head",
            match &job.why {
                Some(why) => format!("Runs on {on} · why: {why}"),
                None => format!("Runs on {on}"),
            },
        ));
    }
    // the Budget section: a line for each unit with a limit or a spend (the model holds the binding one), never summed
    if let Some(b) = &f.budget {
        out.push(("budget", "Budget".into()));
        let u = super::budget_detail::UnitLine {
            unit: unit_of(&b.unit),
            spent: b.spent.0,
            limit: b.limit.map(|l| l.0),
            forecast: None,
        };
        for l in super::budget_detail::budget_lines(&[u]) {
            out.push(("budget", format!("  {l}")));
        }
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
    } else if word(&it.kind) == "plan" {
        // Start has no key of its own: it is a button and a palette command
        &[("Open", "⏎"), ("Start", "")]
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

/// The face that gives the Detail's text its font (`drgnx-ui-text` under it): wrapped text is measured in the font the
/// editor says it draws in.
const PANE: &str = FaceId::WorkPane.name();

/// TEXT wrapped by word into lines of at most ROOM px, none cut and no continuation glyph (the mockup's subtitle
/// is two lines at the tile's width).
fn wrap(text: &str, room: f32, m: &dyn Measure) -> Vec<String> {
    // a number and its unit ("32 min") stay together
    let mut words: Vec<String> = Vec::new();
    for w in text.split(' ') {
        match words.last_mut() {
            Some(last) if w == "min" && last.chars().all(|c| c.is_ascii_digit()) => {
                last.push(' ');
                last.push_str(w);
            }
            _ => words.push(w.to_owned()),
        }
    }
    let mut lines: Vec<String> = Vec::new();
    for word in &words {
        match lines.last_mut() {
            Some(last)
                if fit::width_in(m, Some(PANE), &format!("{last} {word}")) <= room - fit::SLACK =>
            {
                last.push(' ');
                last.push_str(word);
            }
            _ => lines.push(word.clone()),
        }
    }
    lines
}

/// The registered command a button of the Detail's actions runs, by its label.
fn command_of(label: &str) -> Option<&'static str> {
    match label {
        "Open" => Some("work-open"),
        "Files" => Some("work-files"),
        "Diffs" => Some("work-diffs"),
        "Trail" => Some("work-trail"),
        "Steer" => Some("work-steer"),
        "Pause" => Some("work-pause"),
        "Start" => Some("work-start-plan"),
        "Review" => Some("work-review"),
        _ => None,
    }
}

/// The width of the key column, logical px.
const KEY_PX: f32 = 66.0;

/// The rows of LINES at SCALE: one per line, keyed `SECTION/N` (N its place in the panel), in the card's UI font
/// (work-space-dark.html `.det`): the head's first line in the heading face, a section's name in it too, a
/// `KEY\tVALUE` line as a muted key and its value in a column (an agent's why-chain and a link in the accent, an
/// overlap in the warning colour), an action as a button and its key. A job's line carries its id as
/// `drgnx-work-job`.
pub(crate) fn rows(lines: &[Line], kit: &KitEnv, width_px: u32, m: &dyn Measure) -> Vec<Row> {
    let scale = kit.scale;
    // the text sits 10 px inside the island's edge, as the design's `.detail` does
    let pad = (10.0 * scale).round() as u32;
    let key_px = (KEY_PX * scale).round() as u32 + pad;
    let room = width_px as f32 - 2.0 * pad as f32 - 8.0 * scale;
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
                        b.stop(pad);
                        b.push(&line, Some(FaceId::TextMuted.name()));
                        let end = b.pos();
                        b.face(0, end, FaceId::WorkPane.name());
                        b.finish()
                    })
                    .collect::<Vec<_>>();
            }
            let mut b = RowBuilder::new(format!("{section}/{i}"));
            b.stop(pad);
            match (*section, text.split_once('\t')) {
                // an agent's head: its badge, its name and its state as a chip at the right edge
                ("head", Some(_)) if i == 0 => {
                    let parts: Vec<&str> = text.split('\t').collect();
                    let badge = parts[0];
                    let letter = badge.chars().next().unwrap_or('?');
                    let number = badge.chars().last().unwrap_or('1');
                    kit::expand(
                        &mut b,
                        kit,
                        &Comp::AgentMark {
                            slot: number.to_digit(10).unwrap_or(1).clamp(1, 12) as u8,
                            handle: letter.to_string(),
                        },
                    );
                    b.push(" ", None)
                        .push(parts.get(1).unwrap_or(&""), Some(FaceId::UiHeading.name()));
                    if let Some(chip) = parts.get(2).filter(|c| !c.is_empty()) {
                        // the kit's chip at the right edge: measured as the kit expands it
                        let comp = Comp::Chip {
                            label: (*chip).to_owned(),
                            tone: kit::Tone::Neutral,
                            fill: kit::ChipFill::Soft,
                            icon: None,
                            state: State::Rest,
                            action: None,
                        };
                        let mut scratch = RowBuilder::new("measure");
                        kit::expand(&mut scratch, kit, &comp);
                        let width = crate::work::trail::flow::row_px(m, &scratch.finish());
                        b.stop(width_px.saturating_sub(width + pad));
                        kit::expand(&mut b, kit, &comp);
                    }
                }
                ("actions", Some(_)) => {
                    let parts: Vec<&str> = text.split('\t').collect();
                    for (n, pair) in parts.chunks(2).enumerate() {
                        if n > 0 {
                            b.push("  ", None);
                        }
                        // a kit button with its key hint after the label (no click: the keys are the profile's)
                        kit::expand(
                            &mut b,
                            kit,
                            &Comp::Button {
                                label: pair[0].to_owned(),
                                style: ButtonStyle::Secondary,
                                size: Size::Sm,
                                state: State::Rest,
                                key: pair
                                    .get(1)
                                    .filter(|k| !k.is_empty())
                                    .map(|k| (*k).to_owned()),
                                // a click runs the action's command in this window (`work-command`, as the Flow's)
                                action: command_of(pair[0]).map(|id| kit::Action {
                                    kind: "work-command".to_owned(),
                                    args: vec![Value::String(id.to_owned())],
                                }),
                            },
                        );
                    }
                }
                ("touches", Some(("branch", value))) if value.contains(" · worktree ") => {
                    // the branch, then its worktree muted
                    let (name, rest) = value.split_once(" · worktree ").unwrap_or((value, ""));
                    b.push("branch", Some(FaceId::TextMuted.name()))
                        .stop(key_px);
                    b.push(name, Some(FaceId::WorkPane.name())).push(
                        &format!(" · worktree {rest}"),
                        Some(FaceId::TextMuted.name()),
                    );
                }
                ("touches", Some(("edits", value))) => {
                    // `NAME +P −M`: the file in the code font, its change in the added and removed colours
                    b.push("edits", Some(FaceId::TextMuted.name())).stop(key_px);
                    let mut it = value.split(' ');
                    b.push(it.next().unwrap_or(""), Some(FaceId::WorkMeta.name()));
                    for w in it {
                        let face = if w.starts_with('+') {
                            FaceId::WorkPlus.name()
                        } else {
                            FaceId::WorkMinus.name()
                        };
                        b.push(" ", None).push(w, Some(face));
                    }
                }
                (s, Some((key, value))) => {
                    b.push(key, Some(FaceId::TextMuted.name())).stop(key_px);
                    let face = match (s, key) {
                        ("why", _) => FaceId::Accent.name(),
                        (_, "overlap") => FaceId::WorkOverlap.name(),
                        _ => FaceId::WorkPane.name(),
                    };
                    b.push(value, Some(face));
                }
                ("head", None) if i == 0 => {
                    b.push(text, Some(FaceId::UiHeading.name()));
                }
                ("head", None) => {
                    b.push(text, Some(FaceId::TextMuted.name()));
                }
                (_, None) if !text.starts_with(' ') => {
                    b.push(text, Some(FaceId::UiHeading.name()));
                }
                (_, None) => {
                    b.push(text, None);
                }
            }
            let end = b.pos();
            b.face(0, end, FaceId::WorkPane.name());
            if let Some(id) = job {
                b.prop(0, end, "drgnx-work-job", Value::String(id.clone()));
            }
            vec![b.finish()]
        })
        .collect()
}

/// [`lines`] with the Budget section read from FACTS (`budget/get` along the chain: a line for each unit, "Counts toward"
/// with the binding scope, "Set to p90" where it applies) and a Schedule section; while there are no facts and the item has
/// a budget, "forecasting…". The model's own binding-budget lines give way to them.
pub(crate) fn lines_with_facts(
    m: &Model,
    sel: Option<&ItemId>,
    now: u64,
    facts: Option<&super::budget_detail::Facts>,
) -> Vec<Line> {
    use super::budget_detail as bd;
    let mut out = lines(m, sel, now);
    let Some(it) = sel.and_then(|s| m.item(s)) else {
        return out;
    };
    let had = out.iter().any(|l| l.0 == "budget");
    out.retain(|l| l.0 != "budget");
    let mut section: Vec<Line> = Vec::new();
    match facts {
        Some(f) if !f.units.is_empty() => {
            section.push(("budget", "Budget".into(), None));
            for l in bd::budget_lines(&f.units) {
                section.push(("budget", format!("  {l}"), None));
            }
            if !f.chain.is_empty() {
                section.push(("budget", "  Counts toward".into(), None));
                for l in bd::counts_toward(&f.chain) {
                    section.push(("budget", format!("    {l}"), None));
                }
            }
        }
        Some(_) => {}
        None if had => {
            section.push(("budget", "Budget".into(), None));
            section.push(("budget", "  forecasting…".into(), None));
        }
        None => {}
    }
    // the Schedule section: a spec's or plan's target, a task's nothing yet known
    let kind = word(&it.kind);
    if matches!(kind.as_str(), "spec" | "plan") {
        let s = bd::ScheduleFacts {
            target: it.fields.target_at.map(|t| (t.0, String::new())),
            ..bd::ScheduleFacts::default()
        };
        section.push(("schedule", "Schedule".into(), None));
        for l in bd::schedule_lines(&s, &kind, 0) {
            section.push(("schedule", format!("  {l}"), None));
        }
    }
    let at = out.iter().position(|l| l.0 == "why").unwrap_or(out.len());
    out.splice(at..at, section);
    out
}
