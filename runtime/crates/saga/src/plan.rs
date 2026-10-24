//! Plans: `docs/plans/**/<date>-<name>.md` parsed into a title, preamble, the waves table, tasks and the rest, and
//! rendered back byte-exact.  Every piece keeps its raw text, so `render(&parse(t)) == t` for any text; the parsed
//! fields (`model`, `files`, `steps`, …) are views derived from the raw body.

use crate::md::{self, Heading, Table};
use std::ops::Range;

/// A run of text from one heading to the next boundary.  `heading` is the raw heading line with its line terminator
/// (empty for text before the first heading), `body` everything after it, both byte-exact.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Section {
    pub level: u8,
    pub heading: String,
    pub body: String,
}

impl Section {
    /// The heading text without `#` marks.
    pub fn title(&self) -> String {
        md::headings(&self.heading)
            .into_iter()
            .next()
            .map(|h| h.text)
            .unwrap_or_default()
    }
}

/// One checkbox step of a task: `- [ ] text` / `- [x] text`; continuation lines (indented) are joined with `\n`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub done: bool,
    pub text: String,
}

/// One `## Task N…` / `### Task N…` section.  Edit the body with [`TaskDoc::set_body`], which re-derives the fields.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskDoc {
    /// `"5"`, `"22b"`.
    pub number: String,
    /// Heading text after the number, leading `:`/dash removed (`"(manager): base"`, `"`saga` — plans"`).
    pub title: String,
    /// `**Model:**` first word-group (`"opus"`, `"none"`).
    pub model: Option<String>,
    /// Backtick spans of the `**Files:**` paragraph.
    pub files: Vec<String>,
    /// The `**Interfaces:**` block, verbatim (without the label line's own text trimmed off).
    pub interfaces: Option<String>,
    pub steps: Vec<Step>,
    /// Byte range of the body in the text this task was parsed from (stale after edits).
    pub body_span: Range<usize>,
    pub level: u8,
    /// Raw heading line with terminator.
    pub heading: String,
    /// Raw body.
    pub body: String,
    /// Non-task sections that follow this task before the next one (`# Wave B`, `## Calls …`).
    pub after: Vec<Section>,
}

impl TaskDoc {
    /// Replace the body (a trailing newline is added when missing) and re-derive the fields.
    pub fn set_body(&mut self, body: &str) {
        let mut b = body.to_string();
        if !b.is_empty() && !b.ends_with('\n') {
            b.push('\n');
        }
        self.body_span = self.body_span.start..self.body_span.start + b.len();
        self.body = b;
        let f = fields(&self.body);
        (self.model, self.files, self.interfaces, self.steps) = (f.0, f.1, f.2, f.3);
    }
}

/// A parsed plan.  `waves` is a read-only view of the first table of the `Waves` section (which stays in `preamble`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanDoc {
    pub title: String,
    pub preamble: Vec<Section>,
    pub waves: Option<Table>,
    pub tasks: Vec<TaskDoc>,
    pub rest: Vec<Section>,
}

enum Chunk {
    Plain(Section),
    Task(TaskDoc),
}

/// Split `text` into chunks at the plan boundaries: every task heading, every heading of level 1–2, and any heading
/// that closes the open task (level at most the task's).
pub(crate) fn split(text: &str, is_task: impl Fn(&str) -> bool) -> Vec<(Heading, Range<usize>)> {
    let hs = md::headings(text);
    let mut cuts: Vec<Heading> = Vec::new();
    let mut open_task: Option<u8> = None;
    for h in hs {
        let task = is_task(&h.text);
        let closes = open_task.is_some_and(|l| h.level <= l);
        if task || h.level <= 2 || closes {
            open_task = if task { Some(h.level) } else { None };
            cuts.push(h);
        }
    }
    let mut out = Vec::new();
    for (i, h) in cuts.iter().enumerate() {
        let end = cuts.get(i + 1).map_or(text.len(), |n| n.start);
        out.push((h.clone(), h.start..end));
    }
    out
}

pub fn parse(text: &str) -> PlanDoc {
    let cuts = split(text, |t| md::task_heading(t).is_some());
    let mut chunks: Vec<Chunk> = Vec::new();
    let lead_end = cuts.first().map_or(text.len(), |(h, _)| h.start);
    if lead_end > 0 {
        chunks.push(Chunk::Plain(Section {
            level: 0,
            heading: String::new(),
            body: text[..lead_end].to_string(),
        }));
    }
    for (h, span) in cuts {
        let raw_heading = text[h.start..h.line_end].to_string();
        if let Some(number) = md::task_heading(&h.text) {
            let title = h.text["Task ".len() + number.len()..]
                .trim_start_matches(|c: char| {
                    c == ':' || c == '—' || c == '–' || c == '-' || c.is_whitespace()
                })
                .to_string();
            let body = text[h.line_end..span.end].to_string();
            let f = fields(&body);
            chunks.push(Chunk::Task(TaskDoc {
                number: number.to_string(),
                title,
                model: f.0,
                files: f.1,
                interfaces: f.2,
                steps: f.3,
                body_span: h.line_end..span.end,
                level: h.level,
                heading: raw_heading,
                body,
                after: Vec::new(),
            }));
        } else {
            let body = text[h.line_end..span.end].to_string();
            chunks.push(Chunk::Plain(Section {
                level: h.level,
                heading: raw_heading,
                body,
            }));
        }
    }
    let last_task = chunks.iter().rposition(|c| matches!(c, Chunk::Task(_)));
    let (mut preamble, mut tasks, mut rest) = (Vec::new(), Vec::<TaskDoc>::new(), Vec::new());
    for (i, c) in chunks.into_iter().enumerate() {
        match c {
            Chunk::Task(t) => tasks.push(t),
            Chunk::Plain(s) if last_task.is_some_and(|l| i > l) => rest.push(s),
            Chunk::Plain(s) => match tasks.last_mut() {
                Some(t) => t.after.push(s),
                None => preamble.push(s),
            },
        }
    }
    let title = preamble
        .iter()
        .find(|s| s.level == 1)
        .map(Section::title)
        .unwrap_or_default();
    let waves = preamble
        .iter()
        .find(|s| s.title().starts_with("Waves"))
        .and_then(|s| md::tables(&s.body).into_iter().next());
    PlanDoc {
        title,
        preamble,
        waves,
        tasks,
        rest,
    }
}

pub fn render(doc: &PlanDoc) -> String {
    let mut out = String::new();
    let mut push = |s: &Section| {
        out.push_str(&s.heading);
        out.push_str(&s.body);
    };
    doc.preamble.iter().for_each(&mut push);
    for t in &doc.tasks {
        push(&Section {
            level: t.level,
            heading: t.heading.clone(),
            body: t.body.clone(),
        });
        t.after.iter().for_each(&mut push);
    }
    doc.rest.iter().for_each(&mut push);
    out
}

type Fields = (Option<String>, Vec<String>, Option<String>, Vec<Step>);

/// Lines of `body` that are not inside a code fence, with their text (terminator removed).
fn plain_lines(body: &str) -> Vec<&str> {
    let mut fenced = false;
    let mut out = Vec::new();
    for line in body.lines() {
        if line.trim_start().starts_with("```") || line.trim_start().starts_with("~~~") {
            fenced = !fenced;
            out.push("");
        } else if fenced {
            out.push("");
        } else {
            out.push(line);
        }
    }
    out
}

fn fields(body: &str) -> Fields {
    let lines = plain_lines(body);
    let mut model = None;
    let mut files = Vec::new();
    let mut interfaces: Option<String> = None;
    let mut steps: Vec<Step> = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if let Some(rest) = line.strip_prefix("**Model:**") {
            let cut = [" · ", " (", " ·"]
                .iter()
                .filter_map(|m| rest.find(m))
                .min()
                .unwrap_or(rest.len());
            let m = rest[..cut].trim().trim_end_matches('.').trim();
            if !m.is_empty() && model.is_none() {
                model = Some(m.to_string());
            }
        } else if line.starts_with("**Files:**") {
            let mut j = i;
            let mut para = String::new();
            while j < lines.len() && !lines[j].trim().is_empty() {
                para.push_str(lines[j]);
                para.push('\n');
                j += 1;
            }
            files = backtick_spans(&para);
            i = j;
            continue;
        } else if line.starts_with("**Interfaces:**") {
            let mut j = i + 1;
            while j < lines.len() && !is_step(lines[j]) && !is_label(lines[j]) {
                j += 1;
            }
            let block: Vec<&str> = lines[i + 1..j].to_vec();
            let text = block.join("\n").trim_matches('\n').to_string();
            interfaces = Some(text);
            i = j;
            continue;
        } else if let Some((done, first)) = step_start(line) {
            let mut text = first.to_string();
            let mut j = i + 1;
            while j < lines.len() && lines[j].starts_with(' ') && !lines[j].trim().is_empty() {
                text.push('\n');
                text.push_str(lines[j].trim_start());
                j += 1;
            }
            steps.push(Step { done, text });
            i = j;
            continue;
        }
        i += 1;
    }
    (model, files, interfaces, steps)
}

fn is_step(line: &str) -> bool {
    step_start(line).is_some()
}

fn is_label(line: &str) -> bool {
    line.starts_with("**") && line.contains(":**")
}

fn step_start(line: &str) -> Option<(bool, &str)> {
    if let Some(r) = line.strip_prefix("- [ ] ") {
        Some((false, r))
    } else {
        line.strip_prefix("- [x] ")
            .or_else(|| line.strip_prefix("- [X] "))
            .map(|r| (true, r))
    }
}

fn backtick_spans(s: &str) -> Vec<String> {
    s.split('`')
        .skip(1)
        .step_by(2)
        .map(str::to_string)
        .collect()
}
