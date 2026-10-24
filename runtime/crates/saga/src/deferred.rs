//! DEFERRED.md: the register of deferred items.  The register is the first table whose header has four columns and
//! starts with `#` or `id` (`| # | Area | Item | Status |`); everything before its rows is `preamble`, everything
//! after is `rest`.  Rows keep their raw text (`raw`), so `render(&parse(t)) == t`.

use crate::table::{self, Block};
use std::ops::Range;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeferredRow {
    pub id: String,
    pub area: String,
    /// The item text, raw cell (escapes like `\|` and markup kept).
    pub text: String,
    pub status: String,
    /// Byte range of the row (continuation lines included) in the parsed text.
    pub span: Range<usize>,
    pub raw: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeferredDoc {
    /// Text up to and including the table's header and separator lines.
    pub preamble: String,
    pub rows: Vec<DeferredRow>,
    pub rest: String,
}

fn is_register(t: &table::Table) -> bool {
    let h = &t.header.cells;
    h.len() == 4 && (h[0] == "#" || h[0].eq_ignore_ascii_case("id"))
}

pub fn parse(text: &str) -> DeferredDoc {
    let blocks = table::blocks(text);
    let mut doc = DeferredDoc {
        preamble: String::new(),
        rows: Vec::new(),
        rest: String::new(),
    };
    let mut found = false;
    for b in blocks {
        match b {
            Block::Table(t) if !found && is_register(&t) => {
                found = true;
                doc.preamble.push_str(&t.header.raw);
                doc.preamble.push_str(&t.separator);
                for r in t.rows {
                    let mut c = r.cells.into_iter();
                    let mut next = || c.next().unwrap_or_default();
                    doc.rows.push(DeferredRow {
                        id: next(),
                        area: next(),
                        text: next(),
                        status: next(),
                        span: r.span,
                        raw: r.raw,
                    });
                }
            }
            Block::Table(t) => {
                let s = t.render();
                if found {
                    &mut doc.rest
                } else {
                    &mut doc.preamble
                }
                .push_str(&s);
            }
            Block::Text(s) => {
                if found {
                    &mut doc.rest
                } else {
                    &mut doc.preamble
                }
                .push_str(&s);
            }
        }
    }
    doc
}

pub fn render(doc: &DeferredDoc) -> String {
    let mut s = doc.preamble.clone();
    for r in &doc.rows {
        s.push_str(&r.raw);
    }
    s.push_str(&doc.rest);
    s
}
