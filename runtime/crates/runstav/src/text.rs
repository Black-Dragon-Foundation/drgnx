//! User-visible text through one sanitizer (contract Task 13; design §6.2 rule 8).  Task 1 fills the bodies; the
//! signatures are fixed at Task 0.

use std::ops::RangeInclusive;

/// The control characters: C0, DEL, C1, U+061C, U+200E, U+200F, U+202A–U+202E, U+2066–U+2069, U+2028, U+2029
/// (`drgnx-coord-control-chars`, the contract's `drgnx-text-control-chars`).
pub const CONTROL: &[RangeInclusive<char>] = &[];

/// Every run of [`CONTROL`] characters and of `\n\r\t` becomes one space; trimmed; cut at MAX characters with `…`.
/// HEADER also turns `]` and `#` into spaces (`drgnx-coord-message-prompt`).
pub fn one_line(text: &str, max: usize, header: bool) -> String {
    let _ = (text, max, header);
    todo!("Task 1")
}

/// Control characters other than `\n` and `\t` replaced, cut at MAX characters (`drgnx-coord-mcp--text-cut`).  The
/// flag says whether it was cut.
pub fn cut(text: &str, max: usize) -> (String, bool) {
    let _ = (text, max);
    todo!("Task 1")
}

/// "outside agent (unverified) KIND" for `ext:KIND:…`, else NAME or ID.
pub fn agent_label(id: &str, name: Option<&str>) -> String {
    let _ = (id, name);
    todo!("Task 1")
}
