//! The agent panel's rows, built in the hub (docs/develop/hub.md, "The agent panel's rows"): what an entry of the
//! transcript looks like in the panel, as finished rows the editor only inserts.  Pure: no lock, no I/O, no clock.
//!
//! An entry is drawn in a *group*: a tool call with the thoughts right after it (they fold under its step), or any
//! other entry alone.  A group's rows are keyed by its first entry's index, so a changed entry re-draws its group and
//! nothing else, and the view's patch (the store diffs by key) replaces only those rows:
//! - `e:I`: the entry's row (a step on one line: its state, title, result, undone mark and time and cost at a stop);
//! - `e:I/p:N`: the lines under a step (the hooks' verdicts, the Always that allowed it);
//! - `e:I/t`, `e:I/t:N`: its thinking, folded to a line count or open;
//! - `e:I/d:N`, `e:I/h:N`: its output and its diff hunks when open, at most [`ROW_LINES`] lines per row;
//! - `b:I:N`: block N of an agent message (its Markdown spans as runs).
//!
//! Every row carries `drgnx-agent-panel-entry` (the entry's index) over its text; a step whose edit can be reverted
//! carries `drgnx-agent-panel-checkpoint` (its step's seq), a diff hunk `drgnx-agent-panel-hunk` ([path, n]).

use super::super::markdown::Block;
use drgnx_rows::faces::FaceId;
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::agents::{Entry, EntryType};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// The most lines one row holds: a longer output, thinking or hunk is split over rows.
pub const ROW_LINES: usize = 30;
/// Lines of a large output shown at its head and at its tail.
pub const OUTPUT_EDGE: usize = 10;
/// Lines of a short output shown.
pub const DETAIL_LINES: usize = 12;
/// Lines of thinking shown when open.
pub const THINKING_LINES: usize = 40;
/// The step types the panel opens by type (a tool call's kind, and the agent's thinking).
pub const STEP_TYPES: [&str; 7] = [
    "thinking", "read", "search", "edit", "execute", "fetch", "other",
];

/// What the step of a tool entry says, from its `step` row (`agent-step`, `timeline/get`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Facts {
    pub start: Option<f64>,
    pub end: Option<f64>,
    pub cost: Option<f64>,
    /// A checkpoint was taken: the step can be reverted to.
    pub revertible: bool,
    /// A revert undid it (`undone_by`).
    pub undone: bool,
    /// The `Task` call of the subagent that made it.
    pub parent_tool: Option<String>,
    /// The step's hook rows (`[{outcome, records: [{source, verdict, reason?}]}]`), oldest first.
    pub hooks: Vec<Value>,
}

/// What the user chose for a panel: the step types open, and rows opened or folded by hand (entry index → open).
#[derive(Clone, Debug, PartialEq)]
pub struct Look {
    pub open: BTreeSet<String>,
    pub rows: BTreeMap<u64, bool>,
    pub slow_secs: f64,
    pub dear_cost: f64,
}

impl Default for Look {
    fn default() -> Self {
        Look {
            open: BTreeSet::new(),
            rows: BTreeMap::new(),
            slow_secs: 10.0,
            dear_cost: 0.5,
        }
    }
}

/// A text's parts as (text, face), each measured in the font its face draws in (`drgnx_rows::fit::width_in`).
pub type Parts<'p> = [(&'p str, &'p str)];

/// What a group's rows read besides its entries.
pub struct Cx<'a> {
    pub look: &'a Look,
    pub facts: &'a BTreeMap<u64, Facts>,
    /// Whether a live Always grant covers a tool entry.
    pub always: &'a dyn Fn(&Entry) -> bool,
    /// The line the hub cached for how a tool entry was allowed (its permission request's decision), if it was.
    pub prov: &'a dyn Fn(&Entry) -> Option<String>,
    /// The px a right-aligned text of these [`Parts`] starts at.
    pub right: &'a dyn Fn(&Parts<'_>) -> u32,
}

/// One group as the session hands it to the panel: its head's index and entry, the thoughts that fold under it, and
/// for an agent message its Markdown blocks.
pub struct GroupIn {
    pub head: usize,
    pub entry: Entry,
    pub thoughts: Vec<Entry>,
    pub blocks: Option<Vec<Block>>,
}

/// The groups of ENTRIES: (head, its thoughts), heads ascending.  A thought folds under the nearest tool call before
/// it with only thoughts between; any other thought is a head of its own.
pub fn groups(entries: &[(usize, &Entry)]) -> Vec<(usize, Vec<usize>)> {
    let mut out: Vec<(usize, Vec<usize>)> = Vec::new();
    let mut host: Option<usize> = None;
    for (i, e) in entries {
        match e.kind {
            EntryType::Thought if host.is_some() => {
                if let Some(g) = out.last_mut() {
                    g.1.push(*i);
                }
            }
            EntryType::Tool => {
                host = Some(*i);
                out.push((*i, Vec::new()));
            }
            _ => {
                host = None;
                out.push((*i, Vec::new()));
            }
        }
    }
    out
}

fn str_of<'a>(e: &'a Entry, k: &str) -> Option<&'a str> {
    e.rest.get(k).and_then(Value::as_str)
}

/// The first text in CONTENT: a string, an object's `text` (else its `content`), or the first of a list.
pub fn text_of(content: &Value) -> Option<&str> {
    match content {
        Value::String(s) => Some(s),
        Value::Object(m) => match m.get("text") {
            Some(Value::String(s)) => Some(s),
            _ => m.get("content").and_then(text_of),
        },
        Value::Array(a) => a.iter().find_map(text_of),
        _ => None,
    }
}

/// TEXT's first non-blank line, trimmed, cut to WIDTH characters with an ellipsis.
pub fn one_line(text: &str, width: usize) -> String {
    let line = text
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("")
        .trim();
    if line.chars().count() <= width {
        return line.to_owned();
    }
    let mut out: String = line.chars().take(width.saturating_sub(1)).collect();
    out.push('…');
    out
}

fn duration(secs: f64) -> String {
    if secs < 1.0 {
        format!("{} ms", (secs * 1000.0).round() as i64)
    } else if secs < 60.0 {
        format!("{secs:.1} s")
    } else {
        let s = secs.floor() as i64;
        format!("{} m {:02} s", s / 60, s % 60)
    }
}

/// The face a subagent's steps are drawn in: one of the six agent colours, by its `Task` call.
fn child_face(parent: &str) -> String {
    let id = drgnx_rows::ImageId::of(parent.as_bytes(), 0);
    FaceId::AGENT[(id.hash % 6) as usize].name().to_owned()
}

fn step_type(e: &Entry) -> &str {
    match str_of(e, "kind") {
        Some(k) if STEP_TYPES.contains(&k) && k != "thinking" => k,
        _ => "other",
    }
}

fn thinking_open(idx: usize, cx: &Cx) -> bool {
    cx.look
        .rows
        .get(&(idx as u64))
        .copied()
        .unwrap_or_else(|| cx.look.open.contains("thinking"))
}

fn detail_open(idx: usize, e: &Entry, cx: &Cx) -> bool {
    match cx.look.rows.get(&(idx as u64)) {
        Some(o) => *o,
        None => str_of(e, "status") == Some("failed") || cx.look.open.contains(step_type(e)),
    }
}

/// A builder for one row of entry IDX: the entry prop goes over the whole text at the end.
struct Line {
    b: RowBuilder,
    idx: usize,
}

impl Line {
    fn new(key: String, idx: usize) -> Self {
        Line {
            b: RowBuilder::new(key),
            idx,
        }
    }
    fn push(&mut self, text: &str, face: Option<&str>) -> &mut Self {
        self.b.push(text, face);
        self
    }
    fn finish(mut self) -> Row {
        let end = self.b.pos();
        self.b
            .prop(0, end, "drgnx-agent-panel-entry", json!(self.idx));
        self.b.finish()
    }
}

/// LINES as rows of at most [`ROW_LINES`] lines each, keyed KEY:0, KEY:1, …, each line in FACE (none: plain).
fn chunked(key: &str, idx: usize, lines: &[String], face: Option<&str>) -> Vec<Row> {
    lines
        .chunks(ROW_LINES)
        .enumerate()
        .map(|(n, chunk)| {
            let mut l = Line::new(format!("{key}:{n}"), idx);
            l.push(&chunk.join("\n"), face);
            l.finish()
        })
        .collect()
}

/// TEXT as lines indented by four columns, at most LIMIT of them, then `…` when there were more.
fn indented(text: &str, limit: usize) -> Vec<String> {
    let lines: Vec<&str> = text.trim_end().split('\n').collect();
    let mut out: Vec<String> = lines
        .iter()
        .take(limit)
        .map(|l| format!("    {l}"))
        .collect();
    if lines.len() > limit {
        out.push("    …".into());
    }
    out
}

/// The rows of the group headed by IDX: ENTRY, the THOUGHTS that fold under it, and for an agent message its BLOCKS
/// (none: drawn from its text).
pub fn group_rows(
    idx: usize,
    entry: &Entry,
    thoughts: &[&Entry],
    blocks: Option<&[Block]>,
    cx: &Cx,
) -> Vec<Row> {
    let key = format!("e:{idx}");
    let plain = |text: String, face: &str| {
        let mut l = Line::new(key.clone(), idx);
        l.push(&text, Some(face));
        vec![l.finish()]
    };
    match entry.kind {
        EntryType::Plan | EntryType::Usage => Vec::new(),
        EntryType::Tool => tool_rows(idx, entry, thoughts, cx),
        EntryType::User => {
            let mut l = Line::new(key.clone(), idx);
            l.push("  ▍ you  ", Some(FaceId::AgentPanelYou.name()))
                .push(&one_line(str_of(entry, "text").unwrap_or(""), 70), None);
            vec![l.finish()]
        }
        EntryType::Agent => match blocks.filter(|b| !b.is_empty()) {
            Some(bs) => bs
                .iter()
                .enumerate()
                .map(|(n, b)| block_row(idx, n, b))
                .collect(),
            None => {
                let text = str_of(entry, "text").unwrap_or("").trim_end();
                let mut l = Line::new(key.clone(), idx);
                l.push(&format!("  {}", text.replace('\n', "\n  ")), None);
                vec![l.finish()]
            }
        },
        EntryType::Thought => {
            let mut rows = plain("  ▸ thinking".into(), FaceId::AgentPanelSubtle.name());
            if thinking_open(idx, cx) {
                let lines = indented(str_of(entry, "text").unwrap_or(""), THINKING_LINES);
                rows.extend(chunked(
                    &format!("{key}/t"),
                    idx,
                    &lines,
                    Some(FaceId::AgentPanelSubtle.name()),
                ));
            }
            rows
        }
        EntryType::Stop => plain("  — turn ended".into(), FaceId::AgentPanelSubtle.name()),
        EntryType::Error => {
            let text = str_of(entry, "text")
                .or_else(|| str_of(entry, "title"))
                .unwrap_or("error");
            plain(
                format!("  ✗ {}", one_line(text, 80)),
                FaceId::AgentPanelFail.name(),
            )
        }
        EntryType::Compaction => plain(
            "  — context compacted".into(),
            FaceId::AgentPanelSubtle.name(),
        ),
        EntryType::Notice | EntryType::Note => plain(
            format!("  {}", one_line(str_of(entry, "text").unwrap_or(""), 80)),
            FaceId::AgentPanelSubtle.name(),
        ),
    }
}

fn block_row(idx: usize, n: usize, block: &Block) -> Row {
    let mut l = Line::new(format!("b:{idx}:{n}"), idx);
    let base = match block.kind {
        "code" => Some(FaceId::AgentPanelMdCode.name()),
        "quote" => Some(FaceId::AgentPanelMdQuote.name()),
        "heading" => Some(FaceId::AgentPanelMdHeading.name()),
        _ => None,
    };
    if block.kind == "rule" {
        l.push("  ", None)
            .push(&"─".repeat(24), Some(FaceId::AgentPanelMdRule.name()));
        return l.finish();
    }
    let quote = block.kind == "quote";
    let pad = if quote { "  ▎ " } else { "  " };
    l.push(pad, quote.then_some(FaceId::AgentPanelMdQuote.name()));
    for span in &block.spans {
        let face = span
            .style
            .split_whitespace()
            .find_map(|s| match s {
                "emph" => Some(FaceId::AgentPanelMdEmph.name()),
                "strong" => Some(FaceId::AgentPanelMdStrong.name()),
                "strike" => Some(FaceId::AgentPanelMdStrike.name()),
                "link" => Some(FaceId::AgentPanelMdLink.name()),
                "code" => Some(FaceId::AgentPanelMdCode.name()),
                h if h.len() == 2 && h.starts_with('h') => Some(FaceId::AgentPanelMdHeading.name()),
                _ => None,
            })
            .or(base);
        l.push(&span.text.replace('\n', &format!("\n{pad}")), face);
    }
    l.finish()
}

/// The transcript from the conversation blocks (`blocks.rs`; Flow Task 23, S3 and S4), one kit component per block
/// type: the user's bubble (a plain `Card`), "Explored · N files · t" (a collapsible `SectionHeader` that opens its
/// steps), a finding (a `Card` with its sources as `Chip`s), an edit (a `DiffBlock` head with Open, Revert and Comment),
/// an ask (a `QuestionCard` with its keys), a subagent (its blocks nested under its head, indented), a notice, the
/// live line (a pulse, still under REDUCED_MOTION) and a queued message.  Block N's rows are keyed `k:N/...` and each
/// carries `drgnx-block` N; OPEN holds the Explored blocks the user opened.  An agent message's Markdown is the
/// panel's own (`b:I:N` rows, drawn with its entry): it adds no row here.  The panel draws its blocks with
/// [`panel_block_rows`] (keyed by their first entry); this list form is the tests' way into the per-type rows.
#[cfg(test)]
pub fn block_list_rows(
    blocks: &[super::blocks::Block],
    open: &BTreeSet<usize>,
    env: &drgnx_rows::kit::KitEnv,
    reduced_motion: bool,
) -> Vec<Row> {
    let mut out = Vec::new();
    for (i, b) in blocks.iter().enumerate() {
        let mut rows = Vec::new();
        conv_rows(
            b,
            &format!("k:{i}"),
            i,
            0,
            open.contains(&i),
            env,
            reduced_motion,
            &mut rows,
        );
        for r in &mut rows {
            let end = r.text.chars().count() as u32;
            r.props.push((0, end, "drgnx-block".into(), json!(i)));
        }
        out.extend(rows);
    }
    out
}

#[allow(clippy::too_many_arguments)]
fn conv_rows(
    block: &super::blocks::Block,
    key: &str,
    idx: usize,
    depth: usize,
    open: bool,
    env: &drgnx_rows::kit::KitEnv,
    reduced_motion: bool,
    out: &mut Vec<Row>,
) {
    use super::blocks::{AskKind, Block as B};
    use drgnx_rows::kit::{
        self, Action, ButtonStyle, CardKind, CardShape, Comp, QuestionKind, Size, State,
    };
    let indent = "  ".repeat(depth);
    let row = |n: usize| {
        let mut b = RowBuilder::new(format!("{key}/{n}"));
        b.push(&indent, None);
        b
    };
    let act = |kind: &str, args: Vec<Value>| Action {
        kind: kind.to_owned(),
        args,
    };
    match block {
        B::You { text } => {
            for (n, line) in text.lines().enumerate() {
                let mut b = row(n);
                let shape = match (n, text.lines().count()) {
                    (_, 1) => CardShape::Single,
                    (0, _) => CardShape::Top,
                    (k, m) if k + 1 == m => CardShape::Bottom,
                    _ => CardShape::Mid,
                };
                kit::expand(
                    &mut b,
                    env,
                    &Comp::Card {
                        kind: CardKind::Plain,
                        shape,
                        text: line.to_owned(),
                    },
                );
                out.push(b.finish());
            }
        }
        B::Explored {
            reads,
            searches,
            secs,
            steps,
        } => {
            let mut b = row(0);
            kit::expand(
                &mut b,
                env,
                &Comp::SectionHeader {
                    title: format!(
                        "Explored · {} files · {}",
                        reads + searches,
                        duration(f64::from(*secs))
                    ),
                    collapsible: true,
                    collapsed: !open,
                    count: None,
                    state: State::Rest,
                    action: Some(act("block-toggle", vec![json!(idx)])),
                },
            );
            out.push(b.finish());
            if open {
                for (n, s) in steps.iter().enumerate() {
                    let mut b = row(n + 1);
                    b.push(
                        &format!("    step {}", s.step.unwrap_or(s.entry as u64)),
                        Some(FaceId::AgentPanelSubtle.name()),
                    );
                    let end = b.pos();
                    b.prop(0, end, "drgnx-work-id", json!(format!("e:{}", s.entry)));
                    out.push(b.finish());
                }
            }
        }
        B::Markdown { .. } => {}
        B::Finding {
            conclusion,
            text,
            sources,
        } => {
            let word = if conclusion == "decision" {
                "Decision"
            } else {
                "Finding"
            };
            let mut b = row(0);
            kit::expand(
                &mut b,
                env,
                &Comp::Card {
                    kind: CardKind::Plain,
                    shape: if sources.is_empty() {
                        CardShape::Single
                    } else {
                        CardShape::Top
                    },
                    text: format!("{word}: {}", one_line(text, 120)),
                },
            );
            out.push(b.finish());
            if !sources.is_empty() {
                let mut b = row(1);
                for s in sources {
                    let (label, a) = match s {
                        super::blocks::Source::Path { path, lines } => (
                            match lines {
                                Some([a, z]) => format!("{path}:{a}–{z}"),
                                None => path.clone(),
                            },
                            act(
                                "block-source",
                                vec![json!(path), json!(lines.map(|l| l[0]))],
                            ),
                        ),
                        super::blocks::Source::Url { url } => {
                            (url.clone(), act("block-source", vec![json!(url)]))
                        }
                    };
                    kit::expand(
                        &mut b,
                        env,
                        &Comp::Chip {
                            label,
                            tone: Default::default(),
                            fill: Default::default(),
                            icon: None,
                            state: State::Rest,
                            action: Some(a),
                        },
                    );
                    b.push(" ", None);
                }
                out.push(b.finish());
            }
        }
        B::Edit {
            path,
            plus,
            minus,
            hunks,
        } => {
            let mut b = row(0);
            let first = hunks.first().map_or(1, |h| h.start_line);
            kit::expand(
                &mut b,
                env,
                &Comp::DiffBlock {
                    file: path.clone(),
                    added: *plus,
                    removed: *minus,
                    hunks: Vec::new(),
                    buttons: vec![
                        (
                            "Open".into(),
                            act("block-open", vec![json!(idx), json!(path), json!(first)]),
                        ),
                        (
                            "Revert".into(),
                            act("block-revert", vec![json!(idx), json!(path)]),
                        ),
                        (
                            "Comment".into(),
                            act("block-comment", vec![json!(idx), json!(path)]),
                        ),
                    ],
                    icon: None,
                    width: None,
                },
            );
            out.push(b.finish());
        }
        B::Ask {
            kind,
            text,
            options,
        } => {
            let qk = match kind {
                AskKind::Permission => QuestionKind::Permission,
                AskKind::Question => QuestionKind::Question,
            };
            let mut b = row(0);
            kit::expand(
                &mut b,
                env,
                &Comp::QuestionCard {
                    kind: qk,
                    title: one_line(text, 120),
                    body: String::new(),
                    choices: Vec::new(),
                },
            );
            out.push(b.finish());
            let mut b = row(1);
            for (n, (label, k)) in options.iter().enumerate() {
                b.push(" ", None);
                kit::expand(
                    &mut b,
                    env,
                    &Comp::Button {
                        label: label.clone(),
                        style: if n == 0 {
                            ButtonStyle::Primary
                        } else {
                            ButtonStyle::Secondary
                        },
                        size: Size::Sm,
                        state: State::Rest,
                        key: Some(k.to_string()),
                        action: Some(act("block-answer", vec![json!(idx), json!(k.to_string())])),
                    },
                );
            }
            out.push(b.finish());
        }
        B::Subagent {
            call_id,
            title,
            blocks,
        } => {
            let mut b = row(0);
            kit::expand(
                &mut b,
                env,
                &Comp::Card {
                    kind: CardKind::Plain,
                    shape: CardShape::Top,
                    text: format!("↳ {}", one_line(title, 100)),
                },
            );
            let end = b.pos();
            b.face_over(0, end, &child_face(call_id));
            out.push(b.finish());
            for (n, inner) in blocks.iter().enumerate() {
                conv_rows(
                    inner,
                    &format!("{key}/s{n}"),
                    idx,
                    depth + 1,
                    false,
                    env,
                    reduced_motion,
                    out,
                );
            }
        }
        B::Step { step, kind, title } => {
            let mut b = row(0);
            b.push(
                &format!("  {} · {}", kind, one_line(title, 100)),
                Some(FaceId::AgentPanelSubtle.name()),
            );
            let end = b.pos();
            b.prop(0, end, "drgnx-work-id", json!(format!("e:{}", step.entry)));
            b.prop(0, end, "drgnx-action", json!(["block-open", idx]));
            out.push(b.finish());
        }
        B::Notice { text, error } => {
            let mut b = row(0);
            b.push(
                &format!("  {}", one_line(text, 100)),
                Some(if *error {
                    FaceId::AgentPanelFail.name()
                } else {
                    FaceId::AgentPanelSubtle.name()
                }),
            );
            out.push(b.finish());
        }
        B::Live { text } => {
            let mut b = row(0);
            let from = b.pos();
            b.push("  ● ", Some(FaceId::AgentPanelSubtle.name()));
            let to = b.pos();
            b.push(&one_line(text, 100), Some(FaceId::AgentPanelSubtle.name()));
            if !reduced_motion {
                b.prop(from, to, "drgnx-pulse", json!(true));
            }
            out.push(b.finish());
        }
        B::Queued { text } => {
            let mut b = row(0);
            b.push(
                &format!("  ↳ Queued for its next step: {}", one_line(text, 80)),
                Some(FaceId::AgentPanelSubtle.name()),
            );
            out.push(b.finish());
        }
    }
}

fn tool_rows(idx: usize, e: &Entry, thoughts: &[&Entry], cx: &Cx) -> Vec<Row> {
    let key = format!("e:{idx}");
    let facts = e
        .rest
        .get("step")
        .and_then(Value::as_u64)
        .and_then(|s| cx.facts.get(&s).map(|f| (s, f)));
    let parent = facts.and_then(|(_, f)| f.parent_tool.as_deref());
    let status = str_of(e, "status").unwrap_or("");
    let title = one_line(
        str_of(e, "title")
            .or_else(|| str_of(e, "kind"))
            .unwrap_or("tool"),
        50,
    );
    let output = e.rest.get("content").and_then(text_of);
    let result = one_line(output.unwrap_or(""), 40);
    let mut rows = Vec::new();

    // the step on one line
    let mut l = Line::new(key.clone(), idx);
    l.push(if parent.is_some() { "      " } else { "  " }, None);
    let (dot, face) = match status {
        "completed" | "done" => ("●", FaceId::AgentPanelOk.name()),
        "failed" => ("●", FaceId::AgentPanelFail.name()),
        _ => ("○", FaceId::AgentPanelRun.name()),
    };
    l.push(dot, Some(face)).push(" ", None);
    let child = parent.map(child_face);
    if str_of(e, "kind") == Some("execute") {
        // agent-panel.html `.step .what`: "Shell" and the command in the code font
        l.push("Shell ", child.as_deref())
            .push(title.trim_matches('`'), Some(FaceId::AgentPanelCode.name()));
    } else {
        l.push(&title, child.as_deref());
    }
    if !result.is_empty() {
        l.push(
            &format!("  · {result}"),
            Some(FaceId::AgentPanelSubtle.name()),
        );
    }
    if facts.is_some_and(|(_, f)| f.undone) {
        l.push("  ↶ undone", Some(FaceId::AgentPanelSubtle.name()));
    }
    if let Some((_, f)) = facts {
        let secs = f.start.zip(f.end).map(|(s, e)| (e - s).max(0.0));
        let cost = f.cost.filter(|c| *c > 0.0);
        let mut parts: Vec<(String, &str)> = Vec::new();
        if let Some(s) = secs {
            let warn = s > cx.look.slow_secs;
            parts.push((
                duration(s),
                if warn {
                    FaceId::AgentPanelWarn.name()
                } else {
                    FaceId::AgentPanelCode.name()
                },
            ));
        }
        if let Some(c) = cost {
            let warn = c > cx.look.dear_cost;
            parts.push((
                format!("${c:.2}"),
                if warn {
                    FaceId::AgentPanelWarn.name()
                } else {
                    FaceId::AgentPanelCode.name()
                },
            ));
        }
        if !parts.is_empty() {
            // each part is measured in the font its face draws in, as the editor reports it
            let mut meta: Vec<(&str, &str)> = Vec::new();
            for (n, (t, f)) in parts.iter().enumerate() {
                if n > 0 {
                    meta.push((" · ", FaceId::AgentPanelCode.name()));
                }
                meta.push((t.as_str(), f));
            }
            l.b.stop((cx.right)(&meta));
            for (n, (t, f)) in parts.iter().enumerate() {
                if n > 0 {
                    l.push(" · ", Some(FaceId::AgentPanelCode.name()));
                }
                l.push(t, Some(f));
            }
        }
    }
    if let Some((seq, f)) = facts
        && f.revertible
    {
        let end = l.b.pos();
        l.b.prop(0, end, "drgnx-agent-panel-checkpoint", json!(seq));
    }
    rows.push(l.finish());

    // the lines under it: the hooks' verdicts, and the Always that allowed it
    let mut under: Vec<(String, &str, Option<Value>)> = facts
        .map(|(seq, f)| {
            hook_lines(&f.hooks)
                .into_iter()
                .map(|h| (h.text, h.face, Some(json!([seq, h.row, h.rec]))))
                .collect()
        })
        .unwrap_or_default();
    if (cx.always)(e) {
        under.push((
            "allowed by your Always · V revokes".into(),
            FaceId::AgentPanelSubtle.name(),
            None,
        ));
    } else if let Some(how) = (cx.prov)(e) {
        under.push((how, FaceId::AgentPanelSubtle.name(), None));
    }
    for (n, (text, face, hook)) in under.into_iter().enumerate() {
        let mut l = Line::new(format!("{key}/p:{n}"), idx);
        l.push(&format!("    {text}"), Some(face));
        if let Some(h) = hook {
            let end = l.b.pos();
            l.b.prop(4, end, "drgnx-agent-panel-hook", h);
        }
        rows.push(l.finish());
    }

    // its thinking, folded to a line count or open
    if !thoughts.is_empty() {
        let text: Vec<&str> = thoughts
            .iter()
            .map(|t| str_of(t, "text").unwrap_or(""))
            .collect();
        let text = text.join("\n");
        let mut l = Line::new(format!("{key}/t"), idx);
        if thinking_open(idx, cx) {
            l.push("    ▾ thinking", Some(FaceId::AgentPanelSubtle.name()));
            rows.push(l.finish());
            rows.extend(chunked(
                &format!("{key}/t"),
                idx,
                &indented(&text, THINKING_LINES),
                Some(FaceId::AgentPanelSubtle.name()),
            ));
        } else {
            let n = text.trim_end().split('\n').count();
            l.push(
                &format!("    ▸ thinking · {n} lines"),
                Some(FaceId::AgentPanelSubtle.name()),
            );
            rows.push(l.finish());
        }
    }

    // its output and its hunks, when open
    if detail_open(idx, e, cx) {
        if let Some(text) = output {
            rows.extend(detail_rows(
                idx,
                &key,
                text,
                e.rest.get("outputBytes").and_then(Value::as_u64),
            ));
        }
        rows.extend(hunk_rows(idx, &key, &diffs_of(e)));
    }
    rows
}

/// The face of a tool's output lines: the code font (the panel's own text is in the UI font).
const OUTPUT: &str = FaceId::AgentPanelOutput.name();

/// A tool's output: a short one whole (its first [`DETAIL_LINES`]), a large one its first and last [`OUTPUT_EDGE`]
/// lines around a line that says how many are hidden (an estimate, `~`, when the hub kept only its ends: TOTAL bytes).
fn detail_rows(idx: usize, key: &str, text: &str, total: Option<u64>) -> Vec<Row> {
    let text = text.trim_end();
    let lines: Vec<&str> = text.split('\n').collect();
    let bytes = text.len().max(1) as u64;
    let large = lines.len() > 2 * OUTPUT_EDGE || total.is_some_and(|t| t > bytes);
    let dkey = format!("{key}/d");
    if !large {
        return chunked(&dkey, idx, &indented(text, DETAIL_LINES), Some(OUTPUT));
    }
    let have = lines.len();
    let whole = match total {
        Some(t) if t > bytes => (have as f64 * (t as f64 / bytes as f64)).ceil() as usize,
        _ => have,
    };
    let hidden = whole.saturating_sub(2 * OUTPUT_EDGE);
    let head: Vec<String> = lines[..OUTPUT_EDGE]
        .iter()
        .map(|l| format!("    {l}"))
        .collect();
    let tail: Vec<String> = lines[have - OUTPUT_EDGE..]
        .iter()
        .map(|l| format!("    {l}"))
        .collect();
    let mut mid = Line::new(format!("{dkey}:1"), idx);
    mid.push(
        &format!(
            "    {}{hidden} lines hidden · / search · O open in a buffer",
            if whole == have { "" } else { "~" }
        ),
        Some(FaceId::AgentPanelSubtle.name()),
    );
    let mut h = Line::new(format!("{dkey}:0"), idx);
    h.push(&head.join("\n"), Some(OUTPUT));
    let mut t = Line::new(format!("{dkey}:2"), idx);
    t.push(&tail.join("\n"), Some(OUTPUT));
    vec![h.finish(), mid.finish(), t.finish()]
}

/// A tool entry's edits as (path, old, new): its ACP `diff` items, or the old and new text of a paired chat's
/// `edit_file` call (its raw input).
pub fn diffs_of(e: &Entry) -> Vec<(String, String, String)> {
    let mut out = Vec::new();
    if let Some(items) = e.rest.get("content").and_then(Value::as_array) {
        for i in items {
            if i.get("type").and_then(Value::as_str) == Some("diff") {
                let s = |k: &str| i.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
                out.push((s("path"), s("oldText"), s("newText")));
            }
        }
    }
    if out.is_empty()
        && let Some(raw) = e.rest.get("rawInput")
        && let (Some(old), Some(new)) = (
            raw.get("old").and_then(Value::as_str),
            raw.get("new").and_then(Value::as_str),
        )
    {
        let path = raw.get("path").and_then(Value::as_str).unwrap_or("");
        out.push((path.to_owned(), old.to_owned(), new.to_owned()));
    }
    out
}

/// The hunks of DIFFS as rows: each hunk a header (the path and its `@@` line) then its lines, at most [`ROW_LINES`]
/// lines a row, keyed `KEY/h:N` in order.
fn hunk_rows(idx: usize, key: &str, diffs: &[(String, String, String)]) -> Vec<Row> {
    let mut rows = Vec::new();
    let mut hunk = 0usize;
    for (path, old, new) in diffs {
        let d = similar::TextDiff::from_lines(old.as_str(), new.as_str());
        for h in d.unified_diff().context_radius(3).iter_hunks() {
            // (text, face) per line: the header first
            let mut lines: Vec<(String, Option<&str>)> = vec![(
                format!("    {path}  {}", h.header()),
                Some(FaceId::AgentPanelTitle.name()),
            )];
            for change in h.iter_changes() {
                let (sign, face) = match change.tag() {
                    similar::ChangeTag::Insert => ("+", Some(FaceId::KitDiffBlockAdd.name())),
                    similar::ChangeTag::Delete => ("-", Some(FaceId::KitDiffBlockDel.name())),
                    similar::ChangeTag::Equal => (" ", Some(FaceId::KitDiffBlockCtx.name())),
                };
                let text = change.value().trim_end_matches('\n');
                lines.push((format!("    {sign}{text}"), face));
            }
            for (n, chunk) in lines.chunks(ROW_LINES).enumerate() {
                let mut l = Line::new(format!("{key}/h:{}", rows.len()), idx);
                for (j, (text, face)) in chunk.iter().enumerate() {
                    if j > 0 {
                        l.push("\n", None);
                    }
                    l.push(text, *face);
                }
                let end = l.b.pos();
                l.b.prop(0, end, "drgnx-agent-panel-hunk", json!([path, hunk, n]));
                rows.push(l.finish());
            }
            hunk += 1;
        }
    }
    rows
}

/// The rows of a huddle's thread from its record REC (`agents/huddle/get`): `h` (its state, what it is about and who is
/// in it), `r:N` (reply N: who says what, and what it proposes) and `o` (the outcome, or the proposal agreed).  Each
/// participant is drawn in one of the six agent colours, by their place in the huddle.
#[allow(dead_code)] // the thread still draws in Lisp; the hub sends these when the huddle view moves to rows
pub fn huddle_rows(rec: &Value) -> Vec<Row> {
    let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
    let who: Vec<String> = rec
        .get("participants")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|p| p.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();
    let face = |p: &str| {
        FaceId::AGENT[who.iter().position(|w| w == p).unwrap_or(0) % 6]
            .name()
            .to_owned()
    };
    let mut rows = Vec::new();
    let mut h = RowBuilder::new("h");
    h.push(
        &format!(" Huddle · {}", s(rec, "state").unwrap_or_default()),
        Some(FaceId::AgentPanelTitle.name()),
    );
    if let Some(c) = s(rec, "clash") {
        h.push(
            &format!(" · about {c}"),
            Some(FaceId::AgentPanelSubtle.name()),
        );
    }
    h.push("\n  ", None);
    for (n, p) in who.iter().enumerate() {
        if n > 0 {
            h.push(" ⇄ ", None);
        }
        h.push(p, Some(&face(p)));
    }
    rows.push(h.finish());
    for (n, r) in rec
        .get("replies")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        let from = s(r, "from").unwrap_or_default();
        let mut b = RowBuilder::new(format!("r:{n}"));
        b.push(&format!("\n  {from} says"), Some(&face(&from)));
        for line in s(r, "text").unwrap_or_default().trim_end().split('\n') {
            b.push(
                &format!("\n  ▎ {line}"),
                Some(FaceId::AgentPanelMdQuote.name()),
            );
        }
        if let Some(p) = s(r, "proposal") {
            b.push(
                &format!("\n  → proposes: {p}"),
                Some(FaceId::AgentPanelSubtle.name()),
            );
        }
        rows.push(b.finish());
    }
    let outcome = match (s(rec, "outcome"), s(rec, "proposal")) {
        (Some(o), _) => Some(format!("Outcome: {o}")),
        (None, Some(p)) => Some(format!("Agreed proposal: {p}")),
        _ => None,
    };
    if let Some(o) = outcome {
        let mut b = RowBuilder::new("o");
        b.push(&format!("\n  {o}"), Some(FaceId::AgentPanelTitle.name()));
        rows.push(b.finish());
    }
    rows
}

/// One line under a step: a hook's verdict.
#[derive(Clone, Debug, PartialEq)]
pub struct HookLine {
    pub text: String,
    pub face: &'static str,
    /// The hook row and record it tells of (for the editor's provenance).
    pub row: usize,
    pub rec: usize,
}

/// How a line names a hook's SOURCE (`rule:ID` or `plugin:NAME@VERSION#HASH`).
fn who(source: Option<&str>) -> String {
    let Some(s) = source else {
        return "a hook".into();
    };
    if let Some(rest) = s.strip_prefix("plugin:") {
        let name_ver = rest.split('#').next().unwrap_or(rest);
        return match name_ver.split_once('@') {
            Some((n, v)) if !v.is_empty() => format!("{n} {v}"),
            Some((n, _)) => n.to_owned(),
            None => name_ver.to_owned(),
        };
    }
    if let Some(id) = s.strip_prefix("rule:") {
        return format!("rule {id}");
    }
    s.to_owned()
}

fn quoted(reason: Option<&str>) -> String {
    match reason {
        Some(r) if !r.is_empty() => format!(" · \"{r}\""),
        _ => String::new(),
    }
}

/// The verdicts worth a line in a step's hook ROWS: refused, changed, failed, busy and hooked at the server (an allow
/// and an annotation make none).
pub fn hook_lines(rows: &[Value]) -> Vec<HookLine> {
    let mut out = Vec::new();
    for (r, row) in rows.iter().enumerate() {
        if row.get("outcome").and_then(Value::as_str) == Some("at-server") {
            out.push(HookLine {
                text: "hooked at the hub's server".into(),
                face: FaceId::AgentsHooksNote.name(),
                row: r,
                rec: 0,
            });
            continue;
        }
        let recs = row.get("records").and_then(Value::as_array);
        for (n, rec) in recs.into_iter().flatten().enumerate() {
            let s = |k: &str| rec.get(k).and_then(Value::as_str);
            let w = who(s("source"));
            let line = match s("verdict") {
                Some("deny") => Some((
                    format!("refused by {w}{}", quoted(s("reason"))),
                    FaceId::AgentsHooksRefused.name(),
                )),
                Some("change") => {
                    Some((format!("changed by {w}"), FaceId::AgentsHooksChanged.name()))
                }
                Some("error")
                    if s("reason").is_some_and(|r| {
                        r.split(|c: char| !c.is_alphanumeric()).any(|w| w == "busy")
                    }) =>
                {
                    Some((
                        format!("{w} was busy: its hook did not run{}", quoted(s("reason"))),
                        FaceId::AgentsHooksBusy.name(),
                    ))
                }
                Some("error") => Some((
                    format!("{w} failed{}", quoted(s("reason"))),
                    FaceId::AgentsHooksRefused.name(),
                )),
                _ => None,
            };
            if let Some((text, face)) = line {
                out.push(HookLine {
                    text,
                    face,
                    row: r,
                    rec: n,
                });
            }
        }
    }
    out
}

/// What the conversation's blocks make of an entry the panel draws (flow Task 23, S3): the entries whose block the
/// panel draws from the blocks ([`panel_block_rows`]) and the ones folded into another's. An entry with no role is
/// drawn as its group ([`group_rows`]): a tool step keeps its time, cost, provenance, hunks and checkpoint there.
#[derive(Clone, Debug, PartialEq)]
pub enum Role {
    /// The first entry of a block the panel draws: the user's message, an Explored run, a finding.
    Head(super::blocks::Block),
    /// A step of the Explored run that starts at this entry: drawn only while that run is open.
    In(usize),
}

/// The roles of ENTRIES, the transcript from entry FROM on (indexes are the transcript's).
pub fn panel_roles(entries: &[Entry], from: usize) -> BTreeMap<usize, Role> {
    use super::blocks::{Block as B, Folder, Meta};
    let f = Folder::of(entries, &Meta::default());
    let mut out = BTreeMap::new();
    for (k, b) in f.blocks.iter().enumerate() {
        let start = f.starts()[k];
        let end = f.starts().get(k + 1).copied().unwrap_or(entries.len());
        match b {
            B::You { .. } | B::Finding { .. } => {
                out.insert(from + start, Role::Head(b.clone()));
            }
            B::Explored { .. } => {
                out.insert(from + start, Role::Head(b.clone()));
                for (i, e) in entries.iter().enumerate().take(end).skip(start + 1) {
                    if e.kind == EntryType::Tool {
                        out.insert(from + i, Role::In(from + start));
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// The rows of BLOCK, the block whose first entry is HEAD, keyed `e:HEAD/...` and carrying the entry as every step
/// row does (`drgnx-agent-panel-entry`): the panel's keys, toggle and selection work on them as on a step.  An
/// Explored run is its header only; OPEN, its steps follow as their own groups.
pub fn panel_block_rows(
    head: usize,
    block: &super::blocks::Block,
    open: bool,
    env: &drgnx_rows::kit::KitEnv,
) -> Vec<Row> {
    let mut out = Vec::new();
    conv_rows(
        block,
        &format!("e:{head}"),
        head,
        0,
        open,
        env,
        false,
        &mut out,
    );
    if matches!(block, super::blocks::Block::Explored { .. }) {
        out.truncate(1);
    }
    for r in &mut out {
        let end = r.text.chars().count() as u32;
        r.props
            .push((0, end, "drgnx-agent-panel-entry".into(), json!(head)));
    }
    out
}

#[cfg(test)]
#[path = "rows_tests.rs"]
mod tests;
