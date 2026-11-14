//! The tail of a cell: the string the editor puts after the cell's boundary character (design §4.2). The hub builds it whole, the
//! text, its runs (theme roles, never colours) and its images; Lisp only puts it. Inline output is capped below a window's height
//! (20 rows and 8 KiB); what is cut is one row, "N more lines: open output".

use super::output::mime::Shown;
use super::output::terminal::{Run, Style};
use super::output::{CellRun, Output, RunStatus};

pub const MAX_ROWS: usize = 20;
pub const MAX_BYTES: usize = 8192;
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
}

/// A line of the tail with its styled runs (offsets within the line, in characters).
struct Line {
    text: String,
    runs: Vec<Run>,
    image: Option<(usize, String, u32, u32)>,
}

fn plain(s: &str) -> Vec<Line> {
    s.split('\n')
        .map(|l| Line {
            text: l.to_string(),
            runs: Vec::new(),
            image: None,
        })
        .collect()
}

fn lines_of_output(i: usize, o: &Output) -> Vec<Line> {
    let mut out = Vec::new();
    let styled = |t: &super::output::terminal::Terminal| -> Vec<Line> {
        let (text, runs) = t.render();
        // split the rendered text into lines, giving each line the runs that fall in it
        let mut lines = Vec::new();
        let mut start = 0;
        for l in text.split('\n') {
            let len = l.chars().count();
            let rs = runs
                .iter()
                .filter(|r| r.start < start + len && r.end > start)
                .map(|r| Run {
                    start: r.start.max(start) - start,
                    end: r.end.min(start + len) - start,
                    style: r.style,
                })
                .collect();
            lines.push(Line {
                text: l.to_string(),
                runs: rs,
                image: None,
            });
            start += len + 1;
        }
        lines
    };
    match o {
        Output::Stream { text, .. } => out.extend(styled(text)),
        Output::Display { bundle, .. } | Output::Result { bundle, .. } => {
            match bundle.shown() {
                Shown::Text { text, .. } => out.extend(plain(text)),
                Shown::Image {
                    mime,
                    width,
                    height,
                } => out.push(Line {
                    text: IMAGE_CHAR.to_string(),
                    runs: Vec::new(),
                    image: Some((i, mime.to_string(), *width, *height)),
                }),
                Shown::Note(n) => out.extend(plain(n)),
            }
            if let Some(n) = &bundle.note {
                out.push(Line {
                    text: n.clone(),
                    runs: Vec::new(),
                    image: None,
                });
            }
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
            let head = format!("{ename}: {evalue}");
            let n = head.chars().count();
            out.push(Line {
                text: head,
                runs: vec![Run {
                    start: 0,
                    end: n,
                    style: red,
                }],
                image: None,
            });
            for t in traceback {
                out.extend(styled(t));
            }
        }
    }
    out
}

/// The tail of RUN for the cell CELL, as its VERSION-th state.
pub fn build(cell: &str, run: &CellRun, version: u64) -> Tail {
    let mut lines: Vec<Line> = Vec::new();
    for (i, o) in run.outputs.iter().enumerate() {
        lines.extend(lines_of_output(i, o));
    }
    if run.truncated {
        lines.extend(plain(
            "output cut at the limit: open output for what is held",
        ));
    }
    match run.status {
        RunStatus::Aborted => lines.extend(plain("aborted")),
        RunStatus::Cancelled => lines.extend(plain("cancelled")),
        _ => {}
    }
    let total = lines.len();
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
    }
}

#[cfg(test)]
mod tests;
