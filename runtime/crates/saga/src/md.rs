//! Markdown reading shared by plans and ledgers: where the headings are (outside code fences, with byte offsets) and
//! the tables.  Nothing here rewrites text; callers slice the source at the offsets, which is what keeps every
//! section byte-exact.

use pulldown_cmark::{Event, HeadingLevel, Options, Parser, Tag, TagEnd};

/// One heading: `level` 1–6, `start` the byte offset of its line, `line_end` the offset just past its line terminator
/// (or the end of the text), `text` the heading text without `#` marks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Heading {
    pub level: u8,
    pub start: usize,
    pub line_end: usize,
    pub text: String,
}

fn level_number(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

/// Headings that start a line at column 0..=3 (so not inside a list item or a quote, and not inside a code fence),
/// in document order.
pub fn headings(text: &str) -> Vec<Heading> {
    let bytes = text.as_bytes();
    let mut found = Vec::new();
    for (event, range) in Parser::new_ext(text, Options::empty()).into_offset_iter() {
        let Event::Start(Tag::Heading { level, .. }) = event else {
            continue;
        };
        let line_start = text[..range.start].rfind('\n').map_or(0, |i| i + 1);
        if !text[line_start..range.start].bytes().all(|b| b == b' ') || range.start - line_start > 3
        {
            continue;
        }
        let mut line_end = range.end.max(range.start + 1).min(bytes.len());
        if bytes[line_end - 1] != b'\n' {
            line_end = text[line_end..]
                .find('\n')
                .map_or(bytes.len(), |i| line_end + i + 1);
        }
        let first = text[line_start..line_end].lines().next().unwrap_or("");
        found.push(Heading {
            level: level_number(level),
            start: line_start,
            line_end,
            text: heading_text(first),
        });
    }
    found
}

/// `## Task 5: x ##` → `Task 5: x`.
fn heading_text(line: &str) -> String {
    let t = line.trim();
    let t = t.trim_start_matches('#').trim();
    let t = t.trim_end_matches('#').trim();
    t.to_string()
}

/// A pipe table: header cells and body rows, cell text with inline markup flattened (code spans keep their text).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Table {
    pub header: Vec<String>,
    pub rows: Vec<Vec<String>>,
}

/// Every table in `text`, in order.
pub fn tables(text: &str) -> Vec<Table> {
    let mut out = Vec::new();
    let mut cur: Option<Table> = None;
    let mut row: Vec<String> = Vec::new();
    let mut cell = String::new();
    let mut in_head = false;
    for event in Parser::new_ext(text, Options::ENABLE_TABLES) {
        match event {
            Event::Start(Tag::Table(_)) => cur = Some(Table::default()),
            Event::Start(Tag::TableHead) => {
                in_head = true;
                row.clear();
            }
            Event::Start(Tag::TableRow) => row.clear(),
            Event::Start(Tag::TableCell) => cell.clear(),
            Event::Text(t) | Event::Code(t) => cell.push_str(&t),
            Event::SoftBreak | Event::HardBreak => cell.push(' '),
            Event::End(TagEnd::TableCell) => row.push(cell.trim().to_string()),
            Event::End(TagEnd::TableHead) => {
                in_head = false;
                if let Some(t) = cur.as_mut() {
                    t.header = std::mem::take(&mut row);
                }
            }
            Event::End(TagEnd::TableRow) if !in_head => {
                if let Some(t) = cur.as_mut() {
                    t.rows.push(std::mem::take(&mut row));
                }
            }
            Event::End(TagEnd::Table) => out.extend(cur.take()),
            _ => {}
        }
    }
    out
}

/// A task number at the start of `s` (`"5: x"` → `"5"`, `"22b (wave B1)"` → `"22b"`): digits and then lowercase letters.
pub fn task_number(s: &str) -> Option<&str> {
    let digits = s.bytes().take_while(u8::is_ascii_digit).count();
    if digits == 0 {
        return None;
    }
    let letters = s[digits..]
        .bytes()
        .take_while(u8::is_ascii_lowercase)
        .count();
    Some(&s[..digits + letters])
}

/// The task a heading text opens (`"Task 5: x"` → `"5"`); `None` for any other heading.
pub fn task_heading(text: &str) -> Option<&str> {
    task_number(text.strip_prefix("Task ")?)
}

/// The task a ledger heading mentions anywhere (`"Library evaluation (Task 5 step 1)"` → `"5"`).
pub fn task_mentioned(text: &str) -> Option<&str> {
    text.match_indices("Task ")
        .find_map(|(i, _)| task_number(&text[i + 5..]))
}
