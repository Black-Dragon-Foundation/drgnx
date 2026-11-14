//! The lines an edit changes and a read covers, from a tool call's ACP content (`docs/develop/hub.md`, "The presence
//! model"): every provider's edit carries `diff` items (`path`, `oldText`, `newText`), and the hub finds where they
//! land in the file's text as it is at that moment. `rawInput` is never read here.
//!
//! - A fragment (Claude's `Edit`, Codex's one `Diff` per hunk): `oldText` found once in the file is the place, before
//!   the edit lands; once it has landed `newText` found once is. Found nowhere or more than once: no lines ("file
//!   only").
//! - A whole file (Gemini, Claude's `Write`, a new file): `oldText` diffed against `newText` line by line (`similar`).
//!
//! Lines are 1-based and counted on LF (a CRLF text is normalised first); `col` is the column after the last inserted
//! character (0-based, in characters), where a person's cursor would be. Pure.

use serde_json::Value;

/// The lines an edit changes, in the file's text after it: `line` to `line_end`, its cursor at `col` on `line_end`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EditRange {
    pub line: u32,
    pub line_end: u32,
    pub col: u32,
}

/// `oldText` (or, once landed, `newText`) is not in the file exactly once: the edit is shown on the file only.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NoUniqueMatch;

fn lf(s: &str) -> std::borrow::Cow<'_, str> {
    if s.contains('\r') {
        std::borrow::Cow::Owned(s.replace("\r\n", "\n"))
    } else {
        std::borrow::Cow::Borrowed(s)
    }
}

fn to_u32(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

/// Where NEEDLE is in TEXT, when it is there exactly once.
fn unique(text: &str, needle: &str) -> Option<usize> {
    if needle.is_empty() {
        return None;
    }
    let mut it = text.match_indices(needle);
    let (at, _) = it.next()?;
    it.next().is_none().then_some(at)
}

/// The range of NEW once it sits at byte AT of TEXT (TEXT holds what was there before or NEW itself: only what comes
/// before AT is read).
fn range_at(text: &str, at: usize, new: &str) -> EditRange {
    let before = &text[..at];
    let line = 1 + before.matches('\n').count();
    let start_col = before
        .rfind('\n')
        .map_or(before, |i| &before[i + 1..])
        .chars()
        .count();
    // the last inserted character is the last one before a closing line break
    let inserted = new.strip_suffix('\n').unwrap_or(new);
    let breaks = inserted.matches('\n').count();
    let col = match inserted.rfind('\n') {
        Some(i) => inserted[i + 1..].chars().count(),
        None => start_col + inserted.chars().count(),
    };
    EditRange {
        line: to_u32(line),
        line_end: to_u32(line + breaks),
        col: to_u32(col),
    }
}

/// OLD against NEW, whole files: the first to the last changed line of NEW.
fn whole(old: &str, new: &str) -> Result<EditRange, NoUniqueMatch> {
    use similar::{DiffTag, TextDiff};
    let diff = TextDiff::from_lines(old, new);
    let changed: Vec<_> = diff
        .ops()
        .iter()
        .filter(|op| op.tag() != DiffTag::Equal)
        .collect();
    let (Some(first), Some(last)) = (changed.first(), changed.last()) else {
        return Err(NoUniqueMatch);
    };
    let start = first.new_range().start;
    let lr = last.new_range();
    // a deletion leaves no line of its own: its place is the line after it
    let end = if lr.is_empty() { lr.start } else { lr.end - 1 };
    let end = end.max(start);
    let lines: Vec<&str> = new.split_inclusive('\n').collect();
    let col = if lr.is_empty() {
        0
    } else {
        lines
            .get(end)
            .map_or(0, |l| l.strip_suffix('\n').unwrap_or(l).chars().count())
    };
    Ok(EditRange {
        line: to_u32(start + 1),
        line_end: to_u32(end + 1),
        col: to_u32(col),
    })
}

/// The range of one `diff` item in the file whose text is TEXT_NOW: OLD's place (or NEW's once it landed); a whole-file
/// item (WHOLE_FILE, or no OLD: a new file) is OLD diffed against NEW.
pub fn of_diff(
    text_now: &str,
    old: Option<&str>,
    new: &str,
    whole_file: bool,
) -> Result<EditRange, NoUniqueMatch> {
    let (text, new) = (lf(text_now), lf(new));
    let old = old.map(lf);
    match old.as_deref() {
        None => whole("", &new),
        Some(o) if whole_file => whole(o, &new),
        Some(o) => {
            if let Some(at) = unique(&text, o) {
                return Ok(range_at(&text, at, &new));
            }
            match unique(&text, &new) {
                Some(at) => Ok(range_at(&text, at, &new)),
                None => Err(NoUniqueMatch),
            }
        }
    }
}

/// Whether a `diff` item is a whole file: no OLD (a new file), or OLD (before it lands) or NEW (after) is the file's
/// whole text now.
pub fn is_whole_file(text_now: &str, old: Option<&str>, new: &str) -> bool {
    let text = lf(text_now);
    match old {
        None => true,
        Some(o) => *lf(o) == *text || *lf(new) == *text,
    }
}

/// Where a call whose `diff` ITEMS (oldText, newText) are all in one file sits in that file's TEXT_NOW: the last item
/// found once (its cursor is where it wrote last); none when no item is.
pub fn of_call(text_now: &str, items: &[(Option<String>, String)]) -> Option<EditRange> {
    items.iter().rev().find_map(|(o, n)| {
        let whole = is_whole_file(text_now, o.as_deref(), n);
        of_diff(text_now, o.as_deref(), n, whole).ok()
    })
}

/// The `diff` items of a tool call's CONTENT: (path, oldText, newText).
pub fn diffs(content: Option<&Value>) -> Vec<(String, Option<String>, String)> {
    content
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter(|i| i.get("type").and_then(Value::as_str) == Some("diff"))
                .filter_map(|i| {
                    Some((
                        i.get("path")?.as_str()?.to_string(),
                        i.get("oldText").and_then(Value::as_str).map(str::to_string),
                        i.get("newText")?.as_str()?.to_string(),
                    ))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The lines a read covers: from its first location's line, else its OFFSET (at least 1), else line 1 when it has a
/// LIMIT; to `line + limit - 1` with a LIMIT, else that line alone. None when nothing names a line.
pub fn of_read(locations: &[Value], offset: Option<u32>, limit: Option<u32>) -> Option<(u32, u32)> {
    let located = locations
        .first()
        .and_then(|l| l.get("line"))
        .and_then(Value::as_u64)
        .and_then(|n| u32::try_from(n).ok());
    let limit = limit.filter(|l| *l > 0);
    let line = located.or(offset.map(|o| o.max(1))).or(limit.map(|_| 1))?;
    Some((line, limit.map_or(line, |l| line.saturating_add(l - 1))))
}

#[cfg(test)]
mod tests;
