//! What the editor's marks are made of, from the buffer text the hub holds (pure; `docs/develop/hub.md`, "Editor marks").
//!
//! The gutter marks (changed lines, blame, agent strips, debug breakpoints) used to be laid by Lisp on every keystroke:
//! count lines, walk to each, sort.  The hub holds the buffer's text (the edit history's mirror), so it answers in
//! positions, and Lisp only moves the overlays of the marks that changed.  Every answer here goes through
//! [`within_limit`]: a text over [`MAX_BYTES`] gets no marks (the guard `drgnx-large-file-p` is in Lisp).

use runstav::methods::history::{AgentLines, BlameCommit, HeadHunk, HunkMark, HunkMarkKind};

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

/// Fewer columns than this left for the blame: none (a stump says nothing).
pub const BLAME_MIN_WIDTH: usize = 20;
/// The blame is never wider than this.
pub const BLAME_MAX_WIDTH: usize = 80;

/// How long before NOW the time SECONDS was, in words ("3 days ago").
pub fn ago(seconds: i64, now: f64) -> String {
    #[allow(clippy::cast_possible_truncation)]
    let d = (now.floor() as i64 - seconds).max(0);
    let say = |n: i64, unit: &str| format!("{n} {unit}{} ago", if n == 1 { "" } else { "s" });
    match d {
        0..60 => "just now".to_owned(),
        60..3600 => say(d / 60, "minute"),
        3600..86_400 => say(d / 3600, "hour"),
        86_400..2_592_000 => say(d / 86_400, "day"),
        2_592_000..31_536_000 => say(d / 2_592_000, "month"),
        _ => say(d / 31_536_000, "year"),
    }
}

/// The number (1-based) of the line the position POS (Emacs's) is on in TEXT; the empty line after the last line break
/// for a position past the end.
pub fn line_number_at(text: &str, pos: i64) -> usize {
    let upto = usize::try_from(pos - 1).unwrap_or(0);
    1 + text.chars().take(upto).filter(|c| *c == '\n').count()
}

/// The inline blame of one line: "Ada, 3 days ago · Fix the parser" (COMMIT's author, age at NOW and subject), "You ·
/// Uncommitted changes" for a line not committed, "agent s1 · …" for a line AGENT wrote; one line, cut with an
/// ellipsis to WIDTH columns (at most [`BLAME_MAX_WIDTH`]); none under [`BLAME_MIN_WIDTH`].
pub fn blame_text(
    commit: &BlameCommit,
    agent: Option<&AgentLines>,
    now: f64,
    width: usize,
) -> Option<String> {
    let width = width.min(BLAME_MAX_WIDTH);
    if width < BLAME_MIN_WIDTH {
        return None;
    }
    let author = agent.map_or_else(
        || commit.author.clone(),
        |a| format!("agent {}", a.session.as_deref().unwrap_or("")),
    );
    let line = match commit.time {
        Some(t) => format!("{author}, {} · {}", ago(t, now), commit.summary),
        None => format!("{author} · {}", commit.summary),
    };
    let line = line.replace(['\n', '\r'], " ");
    Some(drgnx_rows::fit_tty::fit(&line, width, &[]))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn commit(author: &str, time: Option<i64>, summary: &str) -> BlameCommit {
        BlameCommit {
            sha: "a".repeat(40),
            author: author.into(),
            time,
            summary: summary.into(),
        }
    }

    #[test]
    fn ago_counts_whole_units_like_the_lisp_it_replaces() {
        let now = 10_000_000.0;
        let at = |d: i64| ago(now as i64 - d, now);
        assert_eq!(at(5), "just now");
        assert_eq!(at(60), "1 minute ago");
        assert_eq!(at(3 * 3600 + 5), "3 hours ago");
        assert_eq!(at(86_400), "1 day ago");
        assert_eq!(at(3 * 86_400), "3 days ago");
        assert_eq!(at(40 * 86_400), "1 month ago");
        assert_eq!(at(800 * 86_400), "2 years ago");
        // a time after now is "just now"
        assert_eq!(ago(now as i64 + 99, now), "just now");
    }

    #[test]
    fn a_position_names_its_line() {
        assert_eq!(line_number_at("a\nbb\nc\n", 1), 1);
        assert_eq!(line_number_at("a\nbb\nc\n", 3), 2);
        assert_eq!(line_number_at("a\nbb\nc\n", 5), 2);
        assert_eq!(line_number_at("a\nbb\nc\n", 6), 3);
        // past the end: the empty last line
        assert_eq!(line_number_at("a\nbb\nc\n", 99), 4);
        // characters, not bytes
        assert_eq!(line_number_at("éé\nb", 4), 2);
    }

    #[test]
    fn the_blame_text_is_author_age_and_subject_fitted_to_the_room() {
        let now = 1_000_000.0;
        let c = commit("Ada", Some(now as i64 - 3 * 86_400), "Fix the parser");
        assert_eq!(
            blame_text(&c, None, now, 60).as_deref(),
            Some("Ada, 3 days ago · Fix the parser")
        );
        // cut with an ellipsis at the width, never wider than 80, none under 20
        let cut = blame_text(&c, None, now, 24).unwrap();
        assert_eq!(cut.chars().count(), 24);
        assert!(cut.ends_with('…'));
        assert!(blame_text(&c, None, now, 19).is_none());
        let long = commit("Ada", None, &"x".repeat(200));
        assert_eq!(
            blame_text(&long, None, now, 500).unwrap().chars().count(),
            80
        );
        // not committed: no age; an agent's line names its session; line breaks in a subject are spaces
        let u = commit("You", None, "Uncommitted changes");
        assert_eq!(
            blame_text(&u, None, now, 60).as_deref(),
            Some("You · Uncommitted changes")
        );
        let a = AgentLines {
            from: 1,
            to: 2,
            session: Some("s1".into()),
            step: None,
        };
        let c2 = commit("Ada", Some(now as i64), "one\ntwo");
        assert_eq!(
            blame_text(&c2, Some(&a), now, 60).as_deref(),
            Some("agent s1, just now · one two")
        );
    }

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
