//! DEFERRED.md: the register of deferred items.  The register is every table whose header has four cells, the first
//! `#` or `id` and the last `status` or `state` (case-insensitive: `| # | Area | Item | Status |`, `| ID | Area |
//! Item | State |`), and every `### <ID> — title` entry (the ID has a digit and an upper-case letter; the entry runs
//! to the next heading of level 3 or less, its status is the first word of its `- **Status:**` bullet).  Each row
//! and each entry is one [`DeferredRow`]; everything between them (headings, prose, other tables, a register
//! table's header) is a prose piece.  Rows keep their raw text (`raw`), so `render(&parse(t)) == t`.

use crate::table::{self, Block};
use std::ops::Range;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeferredRow {
    pub id: String,
    pub area: String,
    /// The item text, raw cell (escapes like `\|` and markup kept); an entry's heading after its ID.
    pub text: String,
    pub status: String,
    /// A `###` entry rather than a table row.
    pub entry: bool,
    /// Byte range of the row (continuation lines included) in the parsed text.
    pub span: Range<usize>,
    pub raw: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeferredPiece {
    Prose(String),
    Row(DeferredRow),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeferredDoc {
    /// In file order.  The first piece is always prose (the head; empty when a row starts the file).
    pub pieces: Vec<DeferredPiece>,
}

impl DeferredDoc {
    pub fn rows(&self) -> Vec<&DeferredRow> {
        self.pieces
            .iter()
            .filter_map(|p| match p {
                DeferredPiece::Row(r) => Some(r),
                DeferredPiece::Prose(_) => None,
            })
            .collect()
    }
}

fn is_register(t: &table::Table) -> bool {
    let h = &t.header.cells;
    h.len() == 4
        && (h[0] == "#" || h[0].eq_ignore_ascii_case("id"))
        && (h[3].eq_ignore_ascii_case("status") || h[3].eq_ignore_ascii_case("state"))
}

/// The heading level (1 to 6) of LINE, when it is a heading.
fn heading_level(line: &str) -> Option<usize> {
    let n = line.len() - line.trim_start_matches('#').len();
    let rest = &line[n..];
    ((1..=6).contains(&n) && (rest.is_empty() || rest.starts_with([' ', '\t', '\n', '\r'])))
        .then_some(n)
}

/// `(id, text)` of a `### <ID> — title` line.
fn entry_head(line: &str) -> Option<(String, String)> {
    let rest = line.strip_prefix("### ")?.trim();
    let (id, text) = rest.split_once(char::is_whitespace).unwrap_or((rest, ""));
    let ok = id.bytes().any(|b| b.is_ascii_digit())
        && id.bytes().any(|b| b.is_ascii_uppercase())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_./".contains(&b));
    let text = text.trim_start_matches(['—', '–', '-']).trim();
    ok.then(|| (id.to_string(), text.to_string()))
}

/// Byte range, in the entry RAW, of the first word of its `- **Status:**` bullet (punctuation around it left out).
pub fn status_word(raw: &str) -> Option<Range<usize>> {
    let mut off = 0;
    for l in raw.split_inclusive('\n') {
        if let Some(rest) = l.strip_prefix("- **Status:**") {
            let lead = rest.len() - rest.trim_start().len();
            let start = off + "- **Status:**".len() + lead;
            let word = rest[lead..].split_whitespace().next()?;
            let core = word.trim_matches(|c: char| !c.is_alphanumeric());
            if core.is_empty() {
                return None;
            }
            let s = start + (core.as_ptr() as usize - word.as_ptr() as usize);
            return Some(s..s + core.len());
        }
        off += l.len();
    }
    None
}

struct Builder {
    pieces: Vec<DeferredPiece>,
    acc: String,
}

impl Builder {
    fn row(&mut self, r: DeferredRow) {
        if !self.acc.is_empty() || self.pieces.is_empty() {
            self.pieces
                .push(DeferredPiece::Prose(std::mem::take(&mut self.acc)));
        }
        self.pieces.push(DeferredPiece::Row(r));
    }

    fn entry(&mut self, head: (String, String), raw: String, start: usize) {
        let status = status_word(&raw).map_or(String::new(), |r| raw[r].to_string());
        self.row(DeferredRow {
            id: head.0,
            area: String::new(),
            text: head.1,
            status,
            entry: true,
            span: start..start + raw.len(),
            raw,
        });
    }

    /// TEXT (at byte BASE of the file): prose with `###` entries cut out.
    fn text(&mut self, text: &str, base: usize) {
        let mut entry: Option<((String, String), String, usize)> = None;
        let mut in_fence = false;
        let mut off = 0;
        for line in text.split_inclusive('\n') {
            let level = if in_fence { None } else { heading_level(line) };
            let t = line.trim_start();
            if t.starts_with("```") || t.starts_with("~~~") {
                in_fence = !in_fence;
            }
            if let Some(l) = level {
                if let Some((h, raw, s)) = entry.take() {
                    self.entry(h, raw, s);
                }
                if l == 3
                    && let Some(h) = entry_head(line.trim_end_matches(['\n', '\r']))
                {
                    entry = Some((h, line.to_string(), base + off));
                    off += line.len();
                    continue;
                }
            }
            match &mut entry {
                Some((_, raw, _)) => raw.push_str(line),
                None => self.acc.push_str(line),
            }
            off += line.len();
        }
        if let Some((h, raw, s)) = entry.take() {
            self.entry(h, raw, s);
        }
    }
}

pub fn parse(text: &str) -> DeferredDoc {
    let mut b = Builder {
        pieces: Vec::new(),
        acc: String::new(),
    };
    let mut pos = 0;
    for blk in table::blocks(text) {
        match blk {
            Block::Table(t) if is_register(&t) => {
                b.acc.push_str(&t.header.raw);
                b.acc.push_str(&t.separator);
                pos += t.header.raw.len() + t.separator.len();
                for r in t.rows {
                    pos += r.raw.len();
                    let mut c = r.cells.into_iter();
                    let mut next = || c.next().unwrap_or_default();
                    b.row(DeferredRow {
                        id: next(),
                        area: next(),
                        text: next(),
                        status: next(),
                        entry: false,
                        span: r.span,
                        raw: r.raw,
                    });
                }
            }
            Block::Table(t) => {
                let s = t.render();
                pos += s.len();
                b.acc.push_str(&s);
            }
            Block::Text(s) => {
                b.text(&s, pos);
                pos += s.len();
            }
        }
    }
    if !b.acc.is_empty() || b.pieces.is_empty() {
        b.pieces.push(DeferredPiece::Prose(b.acc));
    }
    DeferredDoc { pieces: b.pieces }
}

pub fn render(doc: &DeferredDoc) -> String {
    doc.pieces
        .iter()
        .map(|p| match p {
            DeferredPiece::Prose(s) => s.as_str(),
            DeferredPiece::Row(r) => r.raw.as_str(),
        })
        .collect()
}
