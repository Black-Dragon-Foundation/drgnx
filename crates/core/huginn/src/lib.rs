//! huginn: a reader for the data subset of Emacs Lisp (docs/develop/settings.md, "The data subset").
//!
//! Generic: no drgnx type and no drgnx path. It reads literal values (numbers, strings, characters, symbols, lists,
//! dotted pairs, vectors, `'X` and `#'F`) with the byte span of each, exactly as Emacs's `read` would, and refuses
//! everything else: every reader macro, backquote, unibyte and raw-byte strings, invalid UTF-8, too deep, too big.
//! Nothing is ever evaluated.
//!
//! - `value`: the data (`Datum`, `Node`).
//! - `span`: byte spans and Emacs's line and column.
//! - `read`: `read_all`, the reader, and its refusals.
//! - `form`: settings files, `(drgnx-settings :version 1 (VAR VALUE)…)`, read into entries and problems.
//! - `de` (feature `serde`): a serde deserializer over a `Node`.

pub mod form;
pub mod read;
pub mod span;
pub mod value;

#[cfg(feature = "serde")]
pub mod de;
