//! The tail of a cell: the string the editor puts after the cell's boundary character (design §4.2). The hub builds it whole, the
//! text, its runs (theme roles, never colours) and its images; Lisp only puts it. Inline output is capped below a window's height
//! (20 rows and 8 KiB); what is cut is one row, "N more lines: open output".
//!
//! The work is the rows' and not the output's: each output is counted (its lines) and only as many of its first lines as can still
//! be shown are built, so half a million styled lines cost the twenty that are shown.

use super::output::mime::Shown;
use super::output::terminal::{Run, Style, clean};
use super::output::{CellRun, Output, RunStatus};

pub const MAX_ROWS: usize = 20;
pub const MAX_BYTES: usize = 8192;
/// The most style runs one tail carries (an event stays small however the text is coloured).
pub const MAX_RUNS: usize = 512;
/// One character stands for an image in the text.
pub const IMAGE_CHAR: char = '\u{fffc}';

/// An image shown in the tail: the character at AT (in characters) is its place; OUTPUT is the output's index in the cell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TailImage {
    pub at: usize,
    pub output: usize,
    pub mime: String,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tail {
    pub cell: String,
    pub text: String,
    pub runs: Vec<Run>,
    pub images: Vec<TailImage>,
    /// Rows left out of the inline text.
    pub more_lines: usize,
    pub version: u64,
    /// The cell's execution count (the number of its prompt), when it has run.
    pub execution_count: Option<i64>,
}

/// The string at a cell's head: its prompt (`[n]`, `[ ]`, `[*]` while queued or running) and what kind of cell it is; the chrome around
/// it (buttons, toolbar) is the editor's to place. STATE is `idle`, `queued` or `running`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Head {
    pub text: String,
    pub runs: Vec<Run>,
    pub state: &'static str,
}

pub fn head(
    kind: hrafn::notebook::Kind,
    language: &str,
    count: Option<i64>,
    state: &'static str,
) -> Head {
    use hrafn::notebook::Kind;
    let (prompt, chip) = match kind {
        Kind::Code => (
            match (state, count) {
                ("queued" | "running", _) => "[*]".to_string(),
                (_, Some(n)) => format!("[{n}]"),
                _ => "[ ]".to_string(),
            },
            if language.is_empty() {
                "code"
            } else {
                language
            },
        ),
        Kind::Markdown => (String::new(), "markdown"),
        Kind::Raw => (String::new(), "raw"),
    };
    let strong = Style {
        bold: true,
        ..Style::default()
    };
    // role 8 is the terminal's bright black: the dim one
    let dim = Style {
        fg: Some(8),
        ..Style::default()
    };
    let mut runs = Vec::new();
    let mut text = String::new();
    if !prompt.is_empty() {
        runs.push(Run {
            start: 0,
            end: prompt.chars().count(),
            style: strong,
        });
        text.push_str(&prompt);
        text.push_str("  ");
    }
    let start = text.chars().count();
    let chip: String = clean(chip).chars().take(64).collect();
    text.push_str(&chip);
    runs.push(Run {
        start,
        end: start + chip.chars().count(),
        style: dim,
    });
    Head { text, runs, state }
}

/// A line of the tail with its styled runs (offsets within the line, in characters).
pub(super) struct Line {
    pub(super) text: String,
    pub(super) runs: Vec<Run>,
    pub(super) image: Option<(usize, String, u32, u32)>,
}

/// The lines of text S: how many, and the first TAKE of them.
fn plain(s: &str, take: usize) -> (usize, Vec<Line>) {
    let count = s.bytes().filter(|b| *b == b'\n').count() + 1;
    let lines = s
        .split('\n')
        .take(take)
        .map(|l| Line {
            text: l.to_string(),
            runs: Vec::new(),
            image: None,
        })
        .collect();
    (count, lines)
}

fn note(s: &str) -> Line {
    Line {
        text: s.to_string(),
        runs: Vec::new(),
        image: None,
    }
}

fn styled(t: &super::output::terminal::Terminal, take: usize) -> (usize, Vec<Line>) {
    let lines = t
        .head(take)
        .into_iter()
        .map(|(text, runs)| Line {
            text,
            runs,
            image: None,
        })
        .collect();
    (t.line_count(), lines)
}

/// The count of OUTPUT's lines and the first TAKE of them.
fn part(i: usize, o: &Output, take: usize) -> (usize, Vec<Line>) {
    match o {
        Output::Stream { text, .. } => styled(text, take),
        Output::Display { bundle, .. } | Output::Result { bundle, .. } => {
            let (mut count, mut lines) = match bundle.shown() {
                Shown::Text { text, .. } => plain(text, take),
                Shown::Image {
                    mime,
                    width,
                    height,
                } => (
                    1,
                    vec![Line {
                        text: IMAGE_CHAR.to_string(),
                        runs: Vec::new(),
                        image: Some((i, mime.to_string(), *width, *height)),
                    }]
                    .into_iter()
                    .take(take)
                    .collect(),
                ),
                Shown::Note(n) => (1, vec![note(n)].into_iter().take(take).collect()),
            };
            if let Some(n) = &bundle.note {
                count += 1;
                if lines.len() < take {
                    lines.push(note(n));
                }
            }
            (count, lines)
        }
        Output::Error {
            ename,
            evalue,
            traceback,
        } => {
            let red = Style {
                fg: Some(1),
                bold: true,
                ..Style::default()
            };
            let (mut count, mut lines) = plain(&clean(&format!("{ename}: {evalue}")), take);
            for l in &mut lines {
                let n = l.text.chars().count();
                if n > 0 {
                    l.runs.push(Run {
                        start: 0,
                        end: n,
                        style: red,
                    });
                }
            }
            for t in traceback {
                let (c, more) = styled(t, take.saturating_sub(lines.len()));
                count += c;
                lines.extend(more);
            }
            (count, lines)
        }
    }
}

/// How many lines RUN's output has (its notes included) and the first TAKE of them: only as many are built as are asked for.
pub(super) fn lines(run: &CellRun, take: usize) -> (usize, Vec<Line>) {
    let mut lines: Vec<Line> = Vec::new();
    let mut total = 0;
    for (i, o) in run.outputs.iter().enumerate() {
        let (count, mut more) = part(i, o, take.saturating_sub(lines.len()));
        total += count;
        lines.append(&mut more);
    }
    let mut tail_notes = Vec::new();
    if run.truncated {
        tail_notes.push("output cut at the limit: open output for what is held");
    }
    match run.status {
        RunStatus::Aborted => tail_notes.push("aborted"),
        RunStatus::Cancelled => tail_notes.push("cancelled"),
        _ => {}
    }
    for n in tail_notes {
        total += 1;
        if lines.len() < take {
            lines.push(note(n));
        }
    }
    (total, lines)
}

/// The tail of RUN for the cell CELL, as its VERSION-th state.
pub fn build(cell: &str, run: &CellRun, version: u64) -> Tail {
    let (total, lines) = lines(run, MAX_ROWS);
    let (mut kept, mut bytes) = (0, 0);
    for l in &lines {
        // a row too long for the byte cap is cut, never skipped whole
        if kept >= MAX_ROWS || (kept > 0 && bytes + l.text.len() + 1 > MAX_BYTES) {
            break;
        }
        bytes += l.text.len() + 1;
        kept += 1;
    }
    let more_lines = total - kept;
    let (mut text, mut runs, mut images) = (String::new(), Vec::new(), Vec::new());
    let mut at = 0;
    for l in lines.iter().take(kept) {
        let mut t = l.text.as_str();
        let cut: String;
        if t.len() > MAX_BYTES {
            cut = t
                .chars()
                .scan(0, |n, c| {
                    *n += c.len_utf8();
                    (*n <= MAX_BYTES).then_some(c)
                })
                .collect();
            t = &cut;
        }
        let len = t.chars().count();
        runs.extend(l.runs.iter().filter(|r| r.start < len).map(|r| Run {
            start: at + r.start,
            end: at + r.end.min(len),
            style: r.style,
        }));
        if let Some((output, mime, width, height)) = &l.image {
            images.push(TailImage {
                at,
                output: *output,
                mime: mime.clone(),
                width: *width,
                height: *height,
            });
        }
        text.push_str(t);
        text.push('\n');
        at += len + 1;
    }
    runs.truncate(MAX_RUNS);
    if more_lines > 0 {
        text.push_str(&format!("{more_lines} more lines: open output"));
    } else {
        text.pop();
    }
    Tail {
        cell: cell.to_string(),
        text,
        runs,
        images,
        more_lines,
        version,
        execution_count: run.execution_count,
    }
}

#[cfg(test)]
mod tests;
