//! The reader: bytes to data, or a refusal at a span (Task 1; the subset is docs/develop/settings.md's table).

use std::fmt;

use crate::span::Span;
use crate::value::Node;

/// How much a file may hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// The largest file read, in bytes.
    pub max_bytes: usize,
    /// The deepest nesting of lists and vectors.
    pub max_depth: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            max_bytes: 1 << 20,
            max_depth: 64,
        }
    }
}

/// Why a file was not read, and where.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub kind: RefusalKind,
    pub span: Span,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefusalKind {
    /// Not valid UTF-8.
    NotUtf8,
    /// Larger than `Limits::max_bytes`.
    TooBig,
    /// Nested deeper than `Limits::max_depth`.
    TooDeep,
    /// Not well-formed: an unbalanced paren, a stray dot, …
    Syntax,
    /// A reader macro or backquote: `` ` ``, `,`, `,@`, `#s(`, `#(`, `#[`, `#&`, `#N=`, `#N#`, `#@`, `#$`, `#.`, `##`,
    /// `#_`, `#:`.
    ReaderMacro,
    /// A string Emacs reads as unibyte with a byte ≥ 0x80 (`"\xe9"`).
    Unibyte,
    /// A raw byte in a multibyte string (`"é\xe9"`).
    RawByte,
    /// An integer beyond 64 bits.
    IntRange,
    /// `\N{NAME}`: Emacs's Unicode names are not carried here (the listed divergence).
    CharName,
    /// A string, character or list the file ends inside.
    Unterminated,
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(
            f,
            "{} (bytes {}..{})",
            self.message, self.span.start, self.span.end
        )
    }
}

impl std::error::Error for Refusal {}

/// Every top-level datum in `bytes`, or the first refusal.
pub fn read_all(bytes: &[u8], limits: Limits) -> Result<Vec<Node>, Refusal> {
    let _ = (bytes, limits);
    todo!("Task 1")
}
