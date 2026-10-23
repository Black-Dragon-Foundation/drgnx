//! Byte spans in the source, and the line and column Emacs reports for a position (Task 1).

/// Bytes `start..end` of the source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

/// The 1-based line and 0-based column, in characters, of byte offset `at` in `text`, as Emacs reports them.
/// An offset inside a character counts as that character's; one past the end as the end.
pub fn line_col(text: &str, at: usize) -> (u32, u32) {
    let mut at = at.min(text.len());
    while !text.is_char_boundary(at) {
        at -= 1;
    }
    let before = &text[..at];
    let line_start = before.rfind('\n').map_or(0, |i| i + 1);
    let line = before.bytes().filter(|&b| b == b'\n').count() + 1;
    let column = before[line_start..].chars().count();
    let clamp = |n: usize| u32::try_from(n).unwrap_or(u32::MAX);
    (clamp(line), clamp(column))
}
