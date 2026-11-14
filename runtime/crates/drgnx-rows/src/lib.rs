//! drgnx-rows: the rows and row patches the hub builds for a view, and Lisp only inserts (`docs/develop/hub.md`,
//! "Rows").
//!
//! A [`Row`] is one line of a view: its text, face runs, text properties, tab stops, images and height. A [`Patch`]
//! moves one (view, display class) from version `base` to `version`. [`RowBuilder`] makes rows from pieces of text,
//! merging adjacent runs of one face. Positions are Unicode scalar indices into the row's text (what Lisp sees after
//! `json-parse-string`), never bytes. Ids go in arrays, never in JSON object keys, so Lisp interns no keywords.
//!
//! The crate does no I/O, reads no clock and has no platform dependency, so it builds for every target the hub does
//! (Android included) and its tests run it in any order.

mod builder;
pub mod fit;
pub mod fit_tty;
pub mod image;
mod patch;
mod row;
pub mod style;
pub mod svg;

pub use builder::RowBuilder;
pub use patch::{Op, Patch, diff};
pub use row::{ImageId, Row, RowHeight};
pub use style::{Colour, CursorShape, Face, Style, StyleId, TermMeta};
