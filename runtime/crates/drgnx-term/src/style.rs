//! Cells to rows: a screen row's cells become one `drgnx_rows::Row` whose text has one character per cell, its runs
//! naming styles `s:<id>` from the view's style table, and a stop after each wide character so the columns keep their
//! place whatever width the editor's font gives it.

use drgnx_rows::{Colour, Face, Row, RowBuilder, Style, StyleId};
use std::collections::HashMap;

/// How wide a cell is.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Wide {
    #[default]
    Narrow,
    /// The first cell of a two-cell character.
    Wide,
    /// The second cell of a wide character (no text of its own).
    Tail,
    /// A wide character that did not fit at the end of the row: blank.
    Head,
}

/// One cell, as the engine reports it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Cell {
    /// The grapheme cluster (empty: blank).
    pub text: String,
    pub style: Style,
    pub wide: Wide,
    /// The OSC 8 link the cell is part of (read for the screen's rows only).
    pub link: Option<String>,
}

/// The view's styles: each distinct style gets an id once (the worker's counter); a patch carries the styles its rows
/// name that the editor was not sent yet (a reset: all of them).
#[derive(Debug, Default)]
pub struct StyleTable {
    ids: HashMap<Style, StyleId>,
    styles: Vec<Style>,
    sent: usize,
}

impl StyleTable {
    /// STYLE's id (the default style has none).
    pub fn id(&mut self, style: &Style) -> Option<StyleId> {
        if *style == Style::default() {
            return None;
        }
        if let Some(id) = self.ids.get(style) {
            return Some(*id);
        }
        let id = self.styles.len() as StyleId;
        self.ids.insert(*style, id);
        self.styles.push(*style);
        Some(id)
    }

    /// The styles to send with the next patch: those not sent yet, or every one for a reset.
    pub fn take(&mut self, reset: bool) -> Vec<(StyleId, Style)> {
        let from = if reset { 0 } else { self.sent };
        self.sent = self.styles.len();
        (from..self.styles.len())
            .map(|i| (i as StyleId, self.styles[i]))
            .collect()
    }

    /// Forget every style (a new stream: ids start again).
    pub fn clear(&mut self) {
        *self = StyleTable::default();
    }

    pub fn len(&self) -> usize {
        self.styles.len()
    }

    pub fn is_empty(&self) -> bool {
        self.styles.is_empty()
    }
}

/// A built row and where each column starts in its text (scalar index), for the cursor.
pub struct Built {
    pub row: Row,
    /// `cols[x]`: the scalar index of column X's text (for the cursor and the editor's column math).
    pub cols: Vec<u32>,
}

/// The text property of an OSC 8 link's characters: its URI (the editor makes them a button).
pub const LINK_PROP: &str = "drgnx-term-link";

/// The row KEY of CELLS: one character per cell (a blank is a space), trailing default blanks dropped, a wide
/// character followed by a stop at the next column's pixel (CELL_PX wide cells; none when 0), runs naming styles, and
/// each OSC 8 link's characters a [`LINK_PROP`].
pub fn build(key: &str, cells: &[Cell], cell_px: u32, styles: &mut StyleTable) -> Built {
    let mut end = cells.len();
    while end > 0 {
        let c = &cells[end - 1];
        if (c.text.is_empty() || c.text == " ")
            && c.style == Style::default()
            && c.wide != Wide::Tail
        {
            end -= 1;
        } else {
            break;
        }
    }
    let mut b = RowBuilder::new(key);
    let mut cols = Vec::with_capacity(end);
    let mut face_buf = String::new();
    // the link being read: where it started and its URI
    let mut link: Option<(u32, &str)> = None;
    for (x, c) in cells[..end].iter().enumerate() {
        let here = c.link.as_deref();
        if link.map(|l| l.1) != here && c.wide != Wide::Tail {
            if let Some((start, uri)) = link.take() {
                b.prop(start, b.pos(), LINK_PROP, uri.into());
            }
            link = here.map(|u| (b.pos(), u));
        }
        cols.push(b.pos());
        let face = styles.id(&c.style).map(|id| {
            face_buf.clear();
            face_buf.push_str(&Face::Style(id).to_string());
            face_buf.as_str()
        });
        match c.wide {
            Wide::Tail => {
                if cell_px > 0 {
                    b.stop((x as u32 + 1) * cell_px);
                } else {
                    // no pixel width yet: the cell is simply not drawn
                }
            }
            Wide::Head => {
                b.push(" ", face);
            }
            _ => {
                // a kitty placeholder cell (U+10EEEE and its diacritics) is blank: its image's slice covers it
                let t = if c.text.is_empty() || c.text.starts_with('\u{10EEEE}') {
                    " "
                } else {
                    c.text.as_str()
                };
                b.push(t, face);
            }
        }
    }
    if let Some((start, uri)) = link {
        b.prop(start, b.pos(), LINK_PROP, uri.into());
    }
    Built {
        row: b.finish(),
        cols,
    }
}

/// An engine colour: `Ansi` for the 16 palette colours, `Rgb` for the rest of the palette (from the palette the
/// engine holds) and for direct colours, `Default` for none.
pub fn colour_of(tag: u8, value: [u8; 3], palette: &[[u8; 3]; 256]) -> Colour {
    match tag {
        1 if value[0] < 16 => Colour::Ansi(value[0]),
        1 => Colour::Rgb(palette[value[0] as usize]),
        2 => Colour::Rgb(value),
        _ => Colour::Default,
    }
}
