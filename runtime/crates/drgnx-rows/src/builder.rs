//! Rows from pieces of text.

use crate::row::{ImageId, Row, RowHeight};
use serde_json::Value;

/// Builds one row: text pushed piece by piece, a face per piece.
#[derive(Debug, Default)]
pub struct RowBuilder {
    row: Row,
    len: u32,
}

impl RowBuilder {
    pub fn new(key: impl Into<String>) -> Self {
        RowBuilder {
            row: Row {
                key: key.into(),
                ..Row::default()
            },
            len: 0,
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

    pub fn height(&mut self, lines: u32, unit: u32) -> &mut Self {
        self.row.height = Some(RowHeight { lines, unit });
        self
    }

    pub fn finish(self) -> Row {
        self.row
    }
}
