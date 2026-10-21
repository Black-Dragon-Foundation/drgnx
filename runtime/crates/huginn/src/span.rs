//! Byte spans in the source, and the line and column Emacs reports for a position (Task 1).

/// Bytes `start..end` of the source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

/// The 1-based line and 0-based column, in characters, of byte offset `at` in `text`, as Emacs reports them.
pub fn line_col(text: &str, at: usize) -> (u32, u32) {
    let _ = (text, at);
    todo!("Task 1")
}
