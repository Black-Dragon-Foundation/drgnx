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

/// What a group's rows read besides its entries.
pub struct Cx<'a> {
    pub look: &'a Look,
    pub facts: &'a BTreeMap<u64, Facts>,
    /// Whether a live Always grant covers a tool entry.
    pub always: &'a dyn Fn(&Entry) -> bool,
    /// The px a right-aligned text starts at.
    pub right: &'a dyn Fn(&str) -> u32,
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
    format!("drgnx-agent-{}", 1 + id.hash % 6)
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
            l.push("  ▍ you  ", Some("drgnx-agent-panel-you"))
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
            let mut rows = plain("  ▸ thinking".into(), "drgnx-agent-panel-subtle");
            if thinking_open(idx, cx) {
                let lines = indented(str_of(entry, "text").unwrap_or(""), THINKING_LINES);
                rows.extend(chunked(
                    &format!("{key}/t"),
                    idx,
                    &lines,
                    Some("drgnx-agent-panel-subtle"),
                ));
            }
            rows
        }
        EntryType::Stop => plain("  — turn ended".into(), "drgnx-agent-panel-subtle"),
        EntryType::Error => {
            let text = str_of(entry, "text")
                .or_else(|| str_of(entry, "title"))
                .unwrap_or("error");
            plain(
                format!("  ✗ {}", one_line(text, 80)),
                "drgnx-agent-panel-fail",
            )
        }
        EntryType::Compaction => plain("  — context compacted".into(), "drgnx-agent-panel-subtle"),
        EntryType::Notice | EntryType::Note => plain(
            format!("  {}", one_line(str_of(entry, "text").unwrap_or(""), 80)),
            "drgnx-agent-panel-subtle",
        ),
    }
}

fn block_row(idx: usize, n: usize, block: &Block) -> Row {
    let mut l = Line::new(format!("b:{idx}:{n}"), idx);
    let base = match block.kind {
        "code" => Some("drgnx-agent-panel-md-code"),
        "quote" => Some("drgnx-agent-panel-md-quote"),
        "heading" => Some("drgnx-agent-panel-md-heading"),
        _ => None,
    };
    if block.kind == "rule" {
        l.push("  ", None)
            .push(&"─".repeat(24), Some("drgnx-agent-panel-md-rule"));
        return l.finish();
    }
    let quote = block.kind == "quote";
    let pad = if quote { "  ▎ " } else { "  " };
    l.push(pad, quote.then_some("drgnx-agent-panel-md-quote"));
    for span in &block.spans {
        let face = span
            .style
            .split_whitespace()
            .find_map(|s| match s {
                "emph" => Some("drgnx-agent-panel-md-emph"),
                "strong" => Some("drgnx-agent-panel-md-strong"),
                "strike" => Some("drgnx-agent-panel-md-strike"),
                "link" => Some("drgnx-agent-panel-md-link"),
                "code" => Some("drgnx-agent-panel-md-code"),
                h if h.len() == 2 && h.starts_with('h') => Some("drgnx-agent-panel-md-heading"),
                _ => None,
            })
            .or(base);
        l.push(&span.text.replace('\n', &format!("\n{pad}")), face);
    }
    l.finish()
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
        "completed" | "done" => ("●", "drgnx-agent-panel-ok"),
        "failed" => ("●", "drgnx-agent-panel-fail"),
        _ => ("○", "drgnx-agent-panel-run"),
    };
    l.push(dot, Some(face)).push(" ", None);
    let child = parent.map(child_face);
    l.push(&title, child.as_deref());
    if !result.is_empty() {
        l.push(&format!("  · {result}"), Some("drgnx-agent-panel-subtle"));
    }
    if facts.is_some_and(|(_, f)| f.undone) {
        l.push("  ↶ undone", Some("drgnx-agent-panel-subtle"));
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
                    "drgnx-agent-panel-warn"
                } else {
                    "drgnx-agent-panel-code"
                },
            ));
        }
        if let Some(c) = cost {
            let warn = c > cx.look.dear_cost;
            parts.push((
                format!("${c:.2}"),
                if warn {
                    "drgnx-agent-panel-warn"
                } else {
                    "drgnx-agent-panel-code"
                },
            ));
        }
        if !parts.is_empty() {
            let meta: Vec<&str> = parts.iter().map(|(t, _)| t.as_str()).collect();
            l.b.stop((cx.right)(&meta.join(" · ")));
            for (n, (t, f)) in parts.iter().enumerate() {
                if n > 0 {
                    l.push(" · ", Some("drgnx-agent-panel-code"));
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
            "drgnx-agent-panel-subtle",
            None,
        ));
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
            l.push("    ▾ thinking", Some("drgnx-agent-panel-subtle"));
            rows.push(l.finish());
            rows.extend(chunked(
                &format!("{key}/t"),
                idx,
                &indented(&text, THINKING_LINES),
                Some("drgnx-agent-panel-subtle"),
            ));
        } else {
            let n = text.trim_end().split('\n').count();
            l.push(
                &format!("    ▸ thinking · {n} lines"),
                Some("drgnx-agent-panel-subtle"),
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
const OUTPUT: &str = "drgnx-agent-panel-output";

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
        Some("drgnx-agent-panel-subtle"),
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
                Some("drgnx-agent-panel-title"),
            )];
            for change in h.iter_changes() {
                let (sign, face) = match change.tag() {
                    similar::ChangeTag::Insert => ("+", Some("drgnx-agent-panel-added")),
                    similar::ChangeTag::Delete => ("-", Some("drgnx-agent-panel-removed")),
                    similar::ChangeTag::Equal => (" ", Some("drgnx-agent-panel-context")),
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
        format!(
            "drgnx-agent-{}",
            1 + who.iter().position(|w| w == p).unwrap_or(0) % 6
        )
    };
    let mut rows = Vec::new();
    let mut h = RowBuilder::new("h");
    h.push(
        &format!(" Huddle · {}", s(rec, "state").unwrap_or_default()),
        Some("drgnx-agent-panel-title"),
    );
    if let Some(c) = s(rec, "clash") {
        h.push(&format!(" · about {c}"), Some("drgnx-agent-panel-subtle"));
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
            b.push(&format!("\n  ▎ {line}"), Some("drgnx-agent-panel-md-quote"));
        }
        if let Some(p) = s(r, "proposal") {
            b.push(
                &format!("\n  → proposes: {p}"),
                Some("drgnx-agent-panel-subtle"),
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
        b.push(&format!("\n  {o}"), Some("drgnx-agent-panel-title"));
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
                face: "drgnx-agents-hooks-note",
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
                    "drgnx-agents-hooks-refused",
                )),
                Some("change") => Some((format!("changed by {w}"), "drgnx-agents-hooks-changed")),
                Some("error")
                    if s("reason").is_some_and(|r| {
                        r.split(|c: char| !c.is_alphanumeric()).any(|w| w == "busy")
                    }) =>
                {
                    Some((
                        format!("{w} was busy: its hook did not run{}", quoted(s("reason"))),
                        "drgnx-agents-hooks-busy",
                    ))
                }
                Some("error") => Some((
                    format!("{w} failed{}", quoted(s("reason"))),
                    "drgnx-agents-hooks-refused",
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

#[cfg(test)]
#[path = "rows_tests.rs"]
mod tests;
