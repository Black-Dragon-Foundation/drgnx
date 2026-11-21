//! Rows from pieces of text.

use crate::row::{ImageId, Row, RowHeight};
use serde_json::Value;

/// Builds one row: text pushed piece by piece, a face per piece.
#[derive(Debug, Default)]
pub struct RowBuilder {
    row: Row,
    len: u32,
    /// Where the last character pushed was a pad, and its face: the next pad joins it.
    last_pad: Option<(u32, Option<String>)>,
}

impl RowBuilder {
    pub fn new(key: impl Into<String>) -> Self {
        RowBuilder {
            row: Row {
                key: key.into(),
                ..Row::default()
            },
            len: 0,
            last_pad: None,
        }
    }

    /// The position the next piece starts at.
    pub fn pos(&self) -> u32 {
        self.len
    }

    /// TEXT in FACE (none: no face).
    pub fn push(&mut self, text: &str, face: Option<&str>) -> &mut Self {
        let start = self.len;
        // positions count scalar values, as Lisp's string indices do
        self.len += u32::try_from(text.chars().count()).unwrap_or(u32::MAX);
        self.row.text.push_str(text);
        let Some(f) = face else { return self };
        match self.row.runs.last_mut() {
            Some((_, end, last)) if *end == start && last == f => *end = self.len,
            _ => self.row.runs.push((start, self.len, f.to_owned())),
        }
        self
    }

    /// FACE over `[start, end)` too, under the runs before it: runs may overlap, and an earlier run's face is above a
    /// later one's (the editor adds them in order, each appended below; a card's box under its text's faces).
    pub fn face(&mut self, start: u32, end: u32, face: &str) -> &mut Self {
        self.row.runs.push((start, end, face.to_owned()));
        self
    }

    /// FACE over `[start, end)` above every run so far (the state of a component that has colours of its own: its
    /// fill, text and ring replace the component's).
    pub fn face_over(&mut self, start: u32, end: u32, face: &str) -> &mut Self {
        self.row.runs.insert(0, (start, end, face.to_owned()));
        self
    }

    /// The text property NAME = VALUE over `[start, end)`.
    pub fn prop(&mut self, start: u32, end: u32, name: &str, value: Value) -> &mut Self {
        self.row.props.push((start, end, name.to_owned(), value));
        self
    }

    /// The next piece starts at PX: one placeholder character, displayed as the space up to PX.
    pub fn stop(&mut self, px: u32) -> &mut Self {
        self.row.stops.push((self.len, px));
        self.push(" ", None)
    }

    /// The image ID here, ALT on a terminal (one placeholder character in the text).
    pub fn image(&mut self, id: ImageId, alt: &str) -> &mut Self {
        self.row.images.push((self.len, id, alt.to_owned()));
        self.push(" ", None)
    }

    /// A space WIDTH x HEIGHT device px in FACE here (one placeholder character in the text).
    pub fn space(&mut self, width: u32, height: u32, face: &str) -> &mut Self {
        self.row.spaces.push((self.len, width, height));
        self.push(" ", Some(face))
    }

    /// A pad WIDTH device px wide here, in FACE (none: no face): a space of no height of its own (one placeholder
    /// character in the text), as the kit's padding is. A pad right after a pad in the same face widens that one: two
    /// stretches side by side inside a box run draw a stray vertical edge between them and the next piece
    /// (measured on the background list, light theme, 2026-11-21).
    pub fn pad(&mut self, width: u32, face: Option<&str>) -> &mut Self {
        if let (Some((at, f)), Some(last)) = (&self.last_pad, self.row.spaces.last_mut()) {
            if *at + 1 == self.len && f.as_deref() == face && last.0 == *at {
                last.1 += width;
                return self;
            }
        }
        self.row.spaces.push((self.len, width, 0));
        self.last_pad = Some((self.len, face.map(str::to_owned)));
        self.push(" ", face)
    }

    pub fn height(&mut self, lines: u32, unit: u32) -> &mut Self {
        self.row.height = Some(RowHeight { lines, unit });
        self
    }

    /// The tail the editor draws after this row at the window's right edge ([`crate::row::Tail`]).
    pub fn tail(&mut self, tail: crate::row::Tail) -> &mut Self {
        self.row.tail = Some(tail);
        self
    }

    /// PX the editor draws after this row's text, before its tail ([`Row::keep`]).
    pub fn keep(&mut self, px: u32) -> &mut Self {
        self.row.keep = px;
        self
    }

    pub fn finish(self) -> Row {
        self.row
    }
}

#[cfg(test)]
mod pad_tests {
    use super::*;

    #[test]
    fn pads_side_by_side_in_one_face_are_one_pad() {
        let mut b = RowBuilder::new("k");
        b.pad(4, None).pad(4, None).push("x", None).pad(4, None);
        let r = b.finish();
        assert_eq!(r.text, " x ");
        assert_eq!(r.spaces, vec![(0, 8, 0), (2, 4, 0)]);
    }

    #[test]
    fn pads_in_other_faces_stay_apart() {
        let mut b = RowBuilder::new("k");
        b.pad(4, Some("a")).pad(4, Some("b"));
        assert_eq!(b.finish().spaces.len(), 2);
    }
}
