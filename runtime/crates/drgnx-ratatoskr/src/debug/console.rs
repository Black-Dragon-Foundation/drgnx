//! The debug console's output (docs/develop/debugging.md, "The debug console"; spec §10): a session's `output`
//! events made into lines the editor only inserts. Text is split into lines (a line without its newline waits for the
//! rest), ANSI SGR becomes face runs (other escapes are dropped), identical consecutive lines are counted, `group`
//! starts and ends indent the lines between them (the opening line names its group, each line the groups around it,
//! so the editor folds them), and the lines wait in a batch the session's loop sends every
//! [`BATCH`] or at [`BATCH_BYTES`]. A batch never holds more than [`QUEUE_CAP`] bytes: past it the oldest lines go and
//! the next batch says how many ("N lines skipped").

use serde_json::{Value, json};
use std::time::Duration;

/// How long output waits to be sent with what follows it.
pub const BATCH: Duration = Duration::from_millis(50);
/// A batch this big is sent at once.
pub const BATCH_BYTES: usize = 64 * 1024;
/// The most a batch keeps while the editor has not taken it.
pub const QUEUE_CAP: usize = 4 * 1024 * 1024;

/// One line of the console.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Line {
    pub text: String,
    /// Face runs over `text`, in characters: (start, end, face).
    pub runs: Vec<(usize, usize, &'static str)>,
    pub category: String,
    /// The group depth it is indented by.
    pub depth: u32,
    /// The group this line opens (`start` / `startCollapsed`), numbered per session.
    pub group: Option<u64>,
    /// The group it opens starts folded (`startCollapsed`).
    pub collapsed: bool,
    /// The groups around it, outermost first.
    pub within: Vec<u64>,
    /// How many identical lines in a row it stands for.
    pub count: u32,
    /// Where a logpoint's message came from: `{path, line}`.
    pub source: Option<Value>,
    /// An output's structured value: `{reference}`, which the editor opens in place.
    pub node: Option<Value>,
    /// It continues the last line of the batch before (identical to it): the editor adds `count` to that line's.
    pub more: bool,
}

impl Line {
    fn bytes(&self) -> usize {
        self.text.len() + 64
    }

    pub fn json(&self) -> Value {
        let mut o = json!({
            "text": self.text,
            "category": self.category,
            "count": self.count,
        });
        if !self.runs.is_empty() {
            o["runs"] = json!(self.runs);
        }
        if self.depth > 0 {
            o["depth"] = json!(self.depth);
        }
        if let Some(g) = self.group {
            o["group"] = json!(g);
        }
        if self.collapsed {
            o["collapsed"] = json!(true);
        }
        if !self.within.is_empty() {
            o["within"] = json!(self.within);
        }
        if let Some(s) = &self.source {
            o["source"] = s.clone();
        }
        if let Some(n) = &self.node {
            o["node"] = n.clone();
        }
        if self.more {
            o["more"] = json!(true);
        }
        o
    }
}

/// The SGR state carried from one output event to the next.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct Style {
    bold: bool,
    dim: bool,
    italic: bool,
    underline: bool,
    fg: Option<u8>,
}

impl Style {
    fn faces(&self) -> Vec<&'static str> {
        const FG: [&str; 16] = [
            "drgnx-debug-console-black",
            "drgnx-debug-console-red",
            "drgnx-debug-console-green",
            "drgnx-debug-console-yellow",
            "drgnx-debug-console-blue",
            "drgnx-debug-console-magenta",
            "drgnx-debug-console-cyan",
            "drgnx-debug-console-white",
            "drgnx-debug-console-bright-black",
            "drgnx-debug-console-bright-red",
            "drgnx-debug-console-bright-green",
            "drgnx-debug-console-bright-yellow",
            "drgnx-debug-console-bright-blue",
            "drgnx-debug-console-bright-magenta",
            "drgnx-debug-console-bright-cyan",
            "drgnx-debug-console-bright-white",
        ];
        let mut f = Vec::new();
        if let Some(c) = self.fg {
            f.push(FG[usize::from(c)]);
        }
        if self.bold {
            f.push("drgnx-debug-console-bold");
        }
        if self.dim {
            f.push("drgnx-debug-console-faint");
        }
        if self.italic {
            f.push("drgnx-debug-console-italic");
        }
        if self.underline {
            f.push("drgnx-debug-console-underline");
        }
        f
    }

    fn apply(&mut self, params: &str) {
        let ns: Vec<u16> = if params.is_empty() {
            vec![0]
        } else {
            params.split(';').map(|p| p.parse().unwrap_or(0)).collect()
        };
        let mut i = 0;
        while i < ns.len() {
            match ns[i] {
                0 => *self = Style::default(),
                1 => self.bold = true,
                2 => self.dim = true,
                3 => self.italic = true,
                4 => self.underline = true,
                22 => (self.bold, self.dim) = (false, false),
                23 => self.italic = false,
                24 => self.underline = false,
                n @ 30..=37 => self.fg = Some((n - 30) as u8),
                n @ 90..=97 => self.fg = Some((n - 90 + 8) as u8),
                39 => self.fg = None,
                // 256-colour and true-colour foregrounds: the 16 named ones only, the rest default
                38 => match ns.get(i + 1) {
                    Some(5) => {
                        self.fg = ns.get(i + 2).and_then(|c| (*c < 16).then_some(*c as u8));
                        i += 2;
                    }
                    Some(2) => {
                        self.fg = None;
                        i += 4;
                    }
                    _ => {}
                },
                48 => match ns.get(i + 1) {
                    Some(5) => i += 2,
                    Some(2) => i += 4,
                    _ => {}
                },
                _ => {}
            }
            i += 1;
        }
    }
}

/// Text with its escapes taken out, and its face runs (in characters) under STYLE, which it updates.
fn sgr(text: &str, style: &mut Style) -> (String, Vec<(usize, usize, &'static str)>) {
    let mut out = String::with_capacity(text.len());
    let mut runs: Vec<(usize, usize, &'static str)> = Vec::new();
    let mut chars = 0usize;
    let mut run_start = 0usize;
    let mut faces = style.faces();
    let close = |runs: &mut Vec<(usize, usize, &'static str)>,
                 faces: &[&'static str],
                 s: usize,
                 e: usize| {
        if e > s {
            for f in faces {
                runs.push((s, e, f));
            }
        }
    };
    let mut it = text.chars().peekable();
    while let Some(c) = it.next() {
        if c == '\u{1b}' {
            match it.peek() {
                Some('[') => {
                    it.next();
                    let mut params = String::new();
                    let mut fin = None;
                    for d in it.by_ref() {
                        if ('\u{40}'..='\u{7e}').contains(&d) {
                            fin = Some(d);
                            break;
                        }
                        params.push(d);
                    }
                    if fin == Some('m') {
                        close(&mut runs, &faces, run_start, chars);
                        style.apply(&params);
                        faces = style.faces();
                        run_start = chars;
                    }
                }
                // OSC: up to BEL or ST
                Some(']') => {
                    let mut prev = ' ';
                    for d in it.by_ref() {
                        if d == '\u{7}' || (prev == '\u{1b}' && d == '\\') {
                            break;
                        }
                        prev = d;
                    }
                }
                _ => {
                    it.next();
                }
            }
            continue;
        }
        if c == '\r' {
            continue;
        }
        out.push(c);
        chars += 1;
    }
    close(&mut runs, &faces, run_start, chars);
    (out, runs)
}

/// One session's console output on its way to the editor.
#[derive(Debug, Default)]
pub struct Console {
    lines: Vec<Line>,
    bytes: usize,
    skipped: usize,
    /// The end of the last output that had no newline yet, with its category.
    partial: Option<(String, String)>,
    /// The groups open now, outermost first, and the last group's number.
    open: Vec<u64>,
    groups: u64,
    style: Style,
    /// The last line sent, to count an identical one that comes in a later batch.
    last: Option<Line>,
}

impl Console {
    /// An `output` event's BODY into lines; ANSI is read when the adapter said `supportsANSIStyling` or for a
    /// program's own `stdout` / `stderr`.
    pub fn output(&mut self, body: &Value, ansi: bool) {
        let category = body
            .get("category")
            .and_then(Value::as_str)
            .unwrap_or("console")
            .to_owned();
        if category == "telemetry" {
            return;
        }
        let text = body.get("output").and_then(Value::as_str).unwrap_or("");
        let group = body.get("group").and_then(Value::as_str);
        let source = body.get("source").and_then(|s| {
            let path = s.get("path")?.as_str()?;
            Some(json!({"path": path, "line": body.get("line").and_then(Value::as_i64)}))
        });
        let node = body
            .get("variablesReference")
            .and_then(Value::as_i64)
            .filter(|r| *r > 0)
            .map(|r| json!({"reference": r}));
        let ansi = ansi || category == "stdout" || category == "stderr";
        if group == Some("end") {
            self.open.pop();
            if text.is_empty() {
                return;
            }
        }
        let mut whole = match self.partial.take() {
            Some((cat, rest)) if cat == category => rest,
            Some((cat, rest)) => {
                self.line(&rest, &cat, None, None, ansi, None);
                String::new()
            }
            None => String::new(),
        };
        whole.push_str(text);
        let ends = whole.ends_with('\n');
        let mut parts: Vec<&str> = whole.split('\n').collect();
        if ends {
            parts.pop();
        } else if group.is_none() && node.is_none() && source.is_none() {
            let last = parts.pop().unwrap_or("");
            if !last.is_empty() {
                self.partial = Some((category.clone(), last.to_owned()));
            }
        }
        let opens = matches!(group, Some("start") | Some("startCollapsed")).then(|| {
            self.groups += 1;
            (self.groups, group == Some("startCollapsed"))
        });
        let n = parts.len();
        for (i, p) in parts.into_iter().enumerate() {
            // a structured value or a logpoint's source belongs to the event's last line
            let last = i + 1 == n;
            self.line(
                p,
                &category,
                if last { source.clone() } else { None },
                if last { node.clone() } else { None },
                ansi,
                if last { opens } else { None },
            );
        }
        if let Some((g, _)) = opens {
            self.open.push(g);
        }
    }

    /// A line the hub writes itself (an evaluate's answer, a task's failure), in CATEGORY.
    pub fn say(&mut self, text: &str, category: &str, node: Option<Value>) {
        self.line(text, category, None, node, false, None);
    }

    fn line(
        &mut self,
        text: &str,
        category: &str,
        source: Option<Value>,
        node: Option<Value>,
        ansi: bool,
        opens: Option<(u64, bool)>,
    ) {
        let (text, runs) = if ansi {
            sgr(text, &mut self.style)
        } else {
            (text.replace('\r', ""), Vec::new())
        };
        let line = Line {
            text,
            runs,
            category: category.to_owned(),
            depth: self.open.len() as u32,
            group: opens.map(|o| o.0),
            collapsed: opens.is_some_and(|o| o.1),
            within: self.open.clone(),
            count: 1,
            source,
            node,
            more: false,
        };
        let same = |a: &Line| {
            a.node.is_none()
                && line.node.is_none()
                && a.text == line.text
                && a.category == line.category
                && a.group.is_none()
                && line.group.is_none()
                && a.within == line.within
                && a.runs == line.runs
                && a.source == line.source
        };
        if let Some(prev) = self.lines.last_mut()
            && same(prev)
        {
            prev.count += 1;
            return;
        }
        if self.lines.is_empty()
            && let Some(prev) = &self.last
            && same(prev)
        {
            // the line before it went in an earlier batch: the editor adds to that line's count
            let mut l = line;
            l.more = true;
            self.bytes += l.bytes();
            self.lines.push(l);
            self.trim();
            return;
        }
        self.bytes += line.bytes();
        self.lines.push(line);
        self.trim();
    }

    fn trim(&mut self) {
        let mut drop = 0;
        while self.bytes > QUEUE_CAP && drop < self.lines.len() {
            self.bytes -= self.lines[drop].bytes();
            drop += 1;
        }
        if drop > 0 {
            self.lines.drain(..drop);
            self.skipped += drop;
        }
    }

    /// Whether the batch should go now.
    pub fn full(&self) -> bool {
        self.bytes >= BATCH_BYTES
    }

    pub fn is_empty(&self) -> bool {
        self.lines.is_empty() && self.skipped == 0
    }

    /// The batch to send, `{lines, skipped?}`, and an empty one in its place; the line that waits for its newline
    /// stays unless FLUSH (the session ended).
    pub fn take(&mut self, flush: bool) -> Option<Value> {
        if flush && let Some((cat, rest)) = self.partial.take() {
            self.line(&rest, &cat, None, None, false, None);
        }
        if self.is_empty() {
            return None;
        }
        let lines = std::mem::take(&mut self.lines);
        self.bytes = 0;
        self.last = lines.last().cloned();
        let mut o = json!({"lines": lines.iter().map(Line::json).collect::<Vec<_>>()});
        if self.skipped > 0 {
            o["skipped"] = json!(std::mem::take(&mut self.skipped));
        }
        Some(o)
    }
}
