//! GFM pipe tables sliced from the source text, byte-exact.  `md::tables` flattens inline markup; the record formats
//! (DEFERRED, the build board) need the raw cells, so rows are cut here line by line.
//!
//! A table is a header line starting with `|` (at most three spaces of indent), a separator line (`|---|:--:|`) and
//! the lines after it that start with `|`.  An indented non-blank line right after a row continues that row (a row
//! longer than one line is kept as written; its cells are read from the lines joined by spaces).  Fenced code is skipped.  Cells split at `|` unless escaped as `\|`;
//! cell text is trimmed but keeps its markup and escapes.

use std::ops::Range;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    /// The row's lines as written, with line terminators (continuation lines included).
    pub raw: String,
    /// Cells (continuation lines joined by a space), trimmed, escapes and markup kept.
    pub cells: Vec<String>,
    /// Byte range of `raw` in the parsed text.
    pub span: Range<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Table {
    pub header: Row,
    /// The separator line as written.
    pub separator: String,
    pub rows: Vec<Row>,
}

impl Table {
    pub fn render(&self) -> String {
        let mut s = self.header.raw.clone();
        s.push_str(&self.separator);
        for r in &self.rows {
            s.push_str(&r.raw);
        }
        s
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Block {
    Text(String),
    Table(Table),
}

pub fn render_blocks(blocks: &[Block]) -> String {
    blocks
        .iter()
        .map(|b| match b {
            Block::Text(t) => t.clone(),
            Block::Table(t) => t.render(),
        })
        .collect()
}

/// Cells of one table line.
pub fn split_cells(line: &str) -> Vec<String> {
    let line = line.trim_end_matches(['\n', '\r']).trim();
    let line = line.strip_prefix('|').unwrap_or(line);
    let mut cells = Vec::new();
    let mut cur = String::new();
    let mut escaped = false;
    for c in line.chars() {
        if c == '|' && !escaped {
            cells.push(cur.trim().to_string());
            cur.clear();
        } else {
            cur.push(c);
        }
        escaped = c == '\\' && !escaped;
    }
    // text after the last pipe is a cell only when it is not blank (a closing pipe leaves nothing)
    if !cur.trim().is_empty() {
        cells.push(cur.trim().to_string());
    }
    cells
}

fn is_row_start(line: &str) -> bool {
    let indent = line.len() - line.trim_start_matches(' ').len();
    indent <= 3 && line[indent..].starts_with('|')
}

fn is_separator(line: &str) -> bool {
    is_row_start(line) && {
        let cells = split_cells(line);
        !cells.is_empty()
            && cells.iter().all(|c| {
                let c = c.strip_prefix(':').unwrap_or(c);
                let c = c.strip_suffix(':').unwrap_or(c);
                !c.is_empty() && c.bytes().all(|b| b == b'-')
            })
    }
}

fn is_fence(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with("```") || t.starts_with("~~~")
}

/// Split `text` into text and table blocks; `render_blocks` gives `text` back.
pub fn blocks(text: &str) -> Vec<Block> {
    let lines: Vec<(usize, &str)> = {
        let mut off = 0;
        text.split_inclusive('\n')
            .map(|l| {
                let o = off;
                off += l.len();
                (o, l)
            })
            .collect()
    };
    let mut out = Vec::new();
    let mut text_start = 0;
    let mut in_fence = false;
    let mut i = 0;
    while i < lines.len() {
        let (off, line) = lines[i];
        if is_fence(line) {
            in_fence = !in_fence;
        }
        if in_fence || !is_row_start(line) || i + 1 >= lines.len() || !is_separator(lines[i + 1].1)
        {
            i += 1;
            continue;
        }
        if off > text_start {
            out.push(Block::Text(text[text_start..off].to_string()));
        }
        let header = Row {
            raw: line.to_string(),
            cells: split_cells(line),
            span: off..off + line.len(),
        };
        let separator = lines[i + 1].1.to_string();
        let mut j = i + 2;
        let mut rows: Vec<Row> = Vec::new();
        while j < lines.len() {
            let (o, l) = lines[j];
            if is_row_start(l) {
                rows.push(Row {
                    raw: l.to_string(),
                    cells: split_cells(l),
                    span: o..o + l.len(),
                });
            } else if l.starts_with([' ', '\t']) && !l.trim().is_empty() && !rows.is_empty() {
                let r = rows.last_mut().unwrap();
                r.raw.push_str(l);
                r.span.end = o + l.len();
                r.cells = split_cells(&r.raw.replace('\n', " "));
            } else {
                break;
            }
            j += 1;
        }
        out.push(Block::Table(Table {
            header,
            separator,
            rows,
        }));
        text_start = lines.get(j).map_or(text.len(), |l| l.0);
        i = j;
    }
    if text_start < text.len() {
        out.push(Block::Text(text[text_start..].to_string()));
    }
    out
}
