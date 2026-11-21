//! A notebook as the one text the editor's buffer holds (design §4.2): for each cell a **head** boundary newline, the cell's
//! source, a **tail** boundary newline. The editor puts the cell's header and output strings on the boundaries (overlays, built
//! by the hub); the lines of this text are the buffer's lines, so a chunk's line opens the right place.

use super::{Kind, Notebook};
use std::ops::Range;

/// Where one cell is in the view.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CellRange {
    pub id: String,
    pub kind: Kind,
    /// The offset of the head boundary character.
    pub head: usize,
    /// The source's bytes.
    pub source: Range<usize>,
    /// The offset of the tail boundary character.
    pub tail: usize,
    /// The line (from 1) of the source's first line.
    pub first_line: u32,
}

/// The notebook's text and its cells' places.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct View {
    pub text: String,
    pub cells: Vec<CellRange>,
}

impl View {
    pub(super) fn of(nb: &Notebook) -> View {
        let mut text = String::new();
        let mut cells = Vec::new();
        let mut lines = 0u32;
        for c in nb.cells() {
            let head = text.len();
            text.push('\n');
            lines += 1;
            let start = text.len();
            text.push_str(&c.source);
            let end = text.len();
            let first_line = lines + 1;
            lines += c.source.matches('\n').count() as u32;
            let tail = text.len();
            text.push('\n');
            lines += 1;
            cells.push(CellRange {
                id: c.id.clone(),
                kind: c.kind,
                head,
                source: start..end,
                tail,
                first_line,
            });
        }
        View { text, cells }
    }
}
