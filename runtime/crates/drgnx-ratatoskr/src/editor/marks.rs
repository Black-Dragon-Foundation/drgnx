//! What the editor's marks are made of, from the buffer text the hub holds (pure; `docs/develop/hub.md`, "Editor marks").
//!
//! The gutter marks (changed lines, blame, agent strips, debug breakpoints) used to be laid by Lisp on every keystroke:
//! count lines, walk to each, sort.  The hub holds the buffer's text (the edit history's mirror), so it answers in
//! positions, and Lisp only moves the overlays of the marks that changed.  Every answer here goes through
//! [`within_limit`]: a text over [`MAX_BYTES`] gets no marks (the guard `drgnx-large-file-p` is in Lisp).

use runstav::methods::history::{HeadHunk, HunkMark, HunkMarkKind};

/// The size above which a buffer gets no marks: the large-files module's default `:ask-above` (50 MiB), the size from
/// which a file opens lean or in chunks and draws none.  Large-files v2's cost registry replaces this one constant.
pub const MAX_BYTES: usize = 50 * 1024 * 1024;

/// Whether a text of LEN bytes gets marks: the one named check every mark builder asks.
pub fn within_limit(len: usize) -> bool {
    len <= MAX_BYTES
}

/// The position (Emacs's: 1-based, in characters) each line of TEXT starts at; one entry more than the text has line
/// breaks, so the empty last line after a final break has its own.
pub fn line_starts(text: &str) -> Vec<i64> {
    let mut out = vec![1];
    let mut pos = 1i64;
    for c in text.chars() {
        pos += 1;
        if c == '\n' {
            out.push(pos);
        }
    }
    out
}

/// The gutter marks of HUNKS against TEXT, sorted by line: one per added or changed line (the first `old_count` lines
/// of a hunk are changed, the rest added), and for a deletion the line after it (the last line when it was at the
/// end).  None when TEXT is over the limit.
pub fn hunk_marks(text: &str, hunks: &[HeadHunk]) -> Vec<HunkMark> {
    if !within_limit(text.len()) {
        return Vec::new();
    }
    let starts = line_starts(text);
    let last = i64::try_from(starts.len()).unwrap_or(i64::MAX);
    let at = |line: i64| {
        let line = line.clamp(1, last);
        HunkMark {
            line,
            pos: starts[usize::try_from(line - 1).unwrap_or(0)],
            kind: HunkMarkKind::Added,
        }
    };
    let mut out = Vec::new();
    for h in hunks {
        if h.new_count == 0 {
            out.push(HunkMark {
                kind: HunkMarkKind::Deleted,
                ..at(h.new_start + 1)
            });
            continue;
        }
        for i in 0..h.new_count {
            out.push(HunkMark {
                kind: if i < h.old_count {
                    HunkMarkKind::Changed
                } else {
                    HunkMarkKind::Added
                },
                ..at(h.new_start + i)
            });
        }
    }
    out.sort_by_key(|m| m.line);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hunk(os: i64, oc: i64, ns: i64, nc: i64) -> HeadHunk {
        HeadHunk {
            old_start: os,
            old_count: oc,
            new_start: ns,
            new_count: nc,
            old_lines: Vec::new(),
        }
    }

    fn at(m: &[HunkMark]) -> Vec<(i64, i64, HunkMarkKind)> {
        m.iter().map(|m| (m.line, m.pos, m.kind)).collect()
    }

    #[test]
    fn line_starts_count_characters_not_bytes() {
        // "é" is two bytes and one character; the final break makes an empty last line
        assert_eq!(line_starts("aé\nb\n"), [1, 4, 6]);
        assert_eq!(line_starts(""), [1]);
    }

    #[test]
    fn hunks_become_marks_at_their_lines_positions() {
        use HunkMarkKind::{Added, Changed, Deleted};
        // line 2 changed, line 5 added after the old last line
        let m = hunk_marks("a\nB\nc\nd\ne\n", &[hunk(2, 1, 2, 1), hunk(4, 0, 5, 1)]);
        assert_eq!(at(&m), [(2, 3, Changed), (5, 9, Added)]);
        // a change that also grows: the first old_count lines are changed, the rest added
        let m = hunk_marks("a\nX\nY\nc\n", &[hunk(2, 1, 2, 2)]);
        assert_eq!(at(&m), [(2, 3, Changed), (3, 5, Added)]);
        // a deletion marks the line after it; at the end, the last line
        let m = hunk_marks("a\nc\n", &[hunk(2, 1, 1, 0)]);
        assert_eq!(at(&m), [(2, 3, Deleted)]);
        let m = hunk_marks("a\n", &[hunk(2, 1, 1, 0), hunk(5, 1, 9, 0)]);
        assert_eq!(at(&m), [(2, 3, Deleted), (2, 3, Deleted)]);
    }

    #[test]
    fn a_text_over_the_limit_gets_no_marks() {
        let big = "x\n".repeat(MAX_BYTES / 2 + 1);
        assert!(!within_limit(big.len()));
        assert!(hunk_marks(&big, &[hunk(1, 1, 1, 1)]).is_empty());
        let edge = "x".repeat(MAX_BYTES);
        assert!(within_limit(edge.len()));
        assert_eq!(hunk_marks(&edge, &[hunk(1, 1, 1, 1)]).len(), 1);
    }
}
