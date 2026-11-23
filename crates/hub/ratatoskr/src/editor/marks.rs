//! What the editor's marks are made of, from the buffer text the hub holds (pure; `docs/develop/hub.md`, "Editor marks").
//!
//! The gutter marks (changed lines, blame, agent strips, debug breakpoints) used to be laid by Lisp on every keystroke:
//! count lines, walk to each, sort.  The hub holds the buffer's text (the edit history's mirror), so it answers in
//! positions, and Lisp only moves the overlays of the marks that changed.  Every answer here goes through
//! [`within_limit`]: a text over [`MAX_BYTES`] gets no marks (the guard `drgnx-large-file-p` is in Lisp).

use runstav::methods::editor::{BufferAgent, GutterRange};
use runstav::methods::history::{AgentLines, BlameCommit, HeadHunk, HunkMark, HunkMarkKind};

/// The size above which a buffer gets no marks: the large-files module's default `:ask-above` (50 MiB), the size from
/// which a file opens lean or in chunks and draws none.  Large-files v2's cost registry replaces this one constant.
pub const MAX_BYTES: usize = 50 * 1024 * 1024;

#[cfg(test)]
thread_local! {
    /// A test's own limit (a test thread's, so parallel tests do not see it).
    static TEST_LIMIT: std::cell::Cell<Option<usize>> = const { std::cell::Cell::new(None) };
}

/// Run F with the limit at LIMIT bytes on this thread: a test of the guard needs no 50 MiB text.
#[cfg(test)]
pub fn with_limit<R>(limit: usize, f: impl FnOnce() -> R) -> R {
    TEST_LIMIT.with(|l| l.set(Some(limit)));
    let out = f();
    TEST_LIMIT.with(|l| l.set(None));
    out
}

/// Whether a text of LEN bytes gets marks: the one named check every mark builder asks.
pub fn within_limit(len: usize) -> bool {
    #[cfg(test)]
    if let Some(limit) = TEST_LIMIT.with(std::cell::Cell::get) {
        return len <= limit;
    }
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

/// The lines of a text as the buffer's positions: where each starts and ends.
pub struct Lines {
    starts: Vec<i64>,
    /// Each line's end (the position of its line break, or of the end of the text).
    ends: Vec<i64>,
}

impl Lines {
    /// TEXT's lines; none over the limit ([`within_limit`]).
    pub fn of(text: &str) -> Option<Lines> {
        if !within_limit(text.len()) {
            return None;
        }
        let starts = line_starts(text);
        let total = i64::try_from(text.chars().count()).unwrap_or(i64::MAX) + 1;
        let ends = starts
            .iter()
            .skip(1)
            .map(|s| s - 1)
            .chain(std::iter::once(total))
            .collect();
        Some(Lines { starts, ends })
    }

    fn index(&self, line: u32) -> usize {
        usize::try_from(line.max(1) - 1)
            .unwrap_or(0)
            .min(self.starts.len() - 1)
    }

    /// The position LINE (1-based; the last line for one past it) starts at.
    pub fn start(&self, line: u32) -> i64 {
        self.starts[self.index(line)]
    }

    /// The position COL characters into LINE, kept on the line.
    pub fn at(&self, line: u32, col: u32) -> i64 {
        let i = self.index(line);
        (self.starts[i] + i64::from(col)).min(self.ends[i])
    }
}

impl Lines {
    /// The position just after LINE, its line break included (the end of the text for the last line): the end of the
    /// span a whole-line mark covers.
    pub fn after(&self, line: u32) -> i64 {
        self.starts
            .get(self.index(line) + 1)
            .copied()
            .unwrap_or_else(|| self.ends[self.ends.len() - 1])
    }
}

/// Give each breakpoint of VIEW (the `debug-breakpoints` view of a file: `breakpoints: [{line, bound_line?, ...}]`) the
/// positions of the line its mark sits on (the adapter's line where it bound it elsewhere): `pos` where the line
/// starts and `end` just after it, in LINES' text.
pub fn place_breakpoints(view: &mut serde_json::Value, lines: &Lines) {
    let Some(bps) = view.get_mut("breakpoints").and_then(|b| b.as_array_mut()) else {
        return;
    };
    for bp in bps {
        let line = bp
            .get("bound_line")
            .and_then(serde_json::Value::as_u64)
            .or_else(|| bp.get("line").and_then(serde_json::Value::as_u64));
        if let Some(line) = line.and_then(|l| u32::try_from(l).ok()) {
            bp["pos"] = serde_json::json!(lines.start(line));
            bp["end"] = serde_json::json!(lines.after(line));
        }
    }
}

/// Give AGENTS and GUTTER the positions of their lines in LINES, and SYMBOL names each agent's symbol (the line; none
/// for a projected agent).
pub fn place(
    agents: &mut [BufferAgent],
    gutter: &mut [GutterRange],
    lines: &Lines,
    symbol: &mut dyn FnMut(u32) -> Option<String>,
) {
    for a in agents {
        let Some(line) = a.line else { continue };
        let end = a.line_end.unwrap_or(line);
        a.line_pos = Some(lines.start(line));
        a.end_pos = Some(lines.start(end));
        a.pos = Some(lines.at(end, a.col.unwrap_or(0)));
        if a.projected.is_none() {
            a.symbol = symbol(line);
        }
    }
    for g in gutter {
        g.start_pos = Some(lines.start(g.start));
        g.end_pos = Some(lines.start(g.end));
    }
}

/// An end-of-line diagnostic's TEXT cut, with an ellipsis, to the room a window WIDTH columns wide has after COLUMN (the
/// line's end) and a few columns of margin (one that does not fit would wrap onto a second screen line): at least 8
/// columns.
pub fn eol_fit(text: &str, column: usize, width: usize) -> String {
    let room = width.saturating_sub(column).saturating_sub(4).max(8);
    rodd::fit_tty::fit(text, room, &[])
}

/// The display column of the end of the line each position of POSITIONS (Emacs's, in characters) is on in TEXT, a tab
/// taking it to the next multiple of TAB columns; none when TEXT is over the limit.
pub fn eol_columns(text: &str, positions: &[i64], tab: u32) -> Option<Vec<usize>> {
    if !within_limit(text.len()) {
        return None;
    }
    let tab = usize::try_from(tab.max(1)).unwrap_or(8);
    // each line: where it starts (in characters) and its end column, one pass
    let mut starts = vec![1i64];
    let mut ends = Vec::new();
    let (mut pos, mut col) = (1i64, 0usize);
    for c in text.chars() {
        pos += 1;
        if c == '\n' {
            ends.push(col);
            col = 0;
            starts.push(pos);
        } else if c == '\t' {
            col += tab - col % tab;
        } else {
            col += rodd::fit_tty::char_width(c, &[]);
        }
    }
    ends.push(col);
    Some(
        positions
            .iter()
            .map(|p| ends[starts.partition_point(|s| s <= p).max(1) - 1])
            .collect(),
    )
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
    Some(rodd::fit_tty::fit(&line, width, &[]))
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

    fn agent(
        line: Option<u32>,
        end: Option<u32>,
        col: Option<u32>,
        projected: bool,
    ) -> BufferAgent {
        use runstav::methods::editor::Projected;
        use runstav::methods::work::{PresenceMode, PresenceSource};
        BufferAgent {
            session: "s".into(),
            ordinal: Some(1),
            handle: None,
            mode: PresenceMode::Edit,
            line,
            line_end: end,
            col,
            source: PresenceSource::Edit,
            live: false,
            projected: projected.then(|| Projected {
                worktree_label: "w".into(),
            }),
            step_title: None,
            plan_entry: None,
            pos: None,
            line_pos: None,
            end_pos: None,
            symbol: None,
        }
    }

    #[test]
    fn the_agents_and_ranges_get_the_positions_of_their_lines() {
        use runstav::methods::editor::GutterKind;
        // lines: "ab" 1-2, "cde" 4-6, "" 8, "f" 9 (the text has no final break)
        let text = "ab\ncde\n\nf";
        let lines = Lines::of(text).unwrap();
        assert_eq!((lines.start(2), lines.at(2, 1), lines.at(2, 99)), (4, 5, 7));
        assert_eq!(lines.start(99), 9, "a line past the end is the last");
        let mut agents = vec![
            agent(Some(2), Some(3), Some(2), false),
            agent(Some(4), None, None, true),
            agent(None, None, None, false),
        ];
        let mut gutter = vec![GutterRange {
            session: "s".into(),
            kind: GutterKind::Changed,
            start: 2,
            end: 4,
            projected: None,
            help: String::new(),
            start_pos: None,
            end_pos: None,
        }];
        let mut asked = Vec::new();
        place(&mut agents, &mut gutter, &lines, &mut |l| {
            asked.push(l);
            Some(format!("fn{l}"))
        });
        // an editing agent: the bar at (line_end, col), the ring from line to line_end
        assert_eq!(
            (agents[0].pos, agents[0].line_pos, agents[0].end_pos),
            (Some(8), Some(4), Some(8))
        );
        assert_eq!(agents[0].symbol.as_deref(), Some("fn2"));
        // a projected agent: its line's start, and no symbol asked for
        assert_eq!(agents[1].line_pos, Some(9));
        assert!(agents[1].symbol.is_none());
        // no line, nothing
        assert!(agents[2].pos.is_none() && agents[2].line_pos.is_none());
        assert_eq!(asked, [2]);
        assert_eq!((gutter[0].start_pos, gutter[0].end_pos), (Some(4), Some(9)));
    }

    #[test]
    fn a_breakpoint_view_gets_the_positions_of_its_marks_lines() {
        // "ab\ncde\n\nf": lines start at 1, 4, 8, 9 (no final break)
        let lines = Lines::of("ab\ncde\n\nf").unwrap();
        assert_eq!((lines.after(1), lines.after(2), lines.after(4)), (4, 8, 10));
        let mut v = serde_json::json!({"path": "p", "version": 1, "breakpoints": [
            {"id": 1, "line": 2}, {"id": 2, "line": 2, "bound_line": 4}, {"id": 3, "line": 3, "column": 1}]});
        place_breakpoints(&mut v, &lines);
        let at = |i: usize| {
            (
                v["breakpoints"][i]["pos"].as_i64(),
                v["breakpoints"][i]["end"].as_i64(),
            )
        };
        assert_eq!(at(0), (Some(4), Some(8)));
        assert_eq!(
            at(1),
            (Some(9), Some(10)),
            "the adapter's line, where it bound it"
        );
        assert_eq!(at(2), (Some(8), Some(9)));
        // a view with no breakpoints, or none of the shape, is left alone
        let mut none = serde_json::json!({"path": "p"});
        place_breakpoints(&mut none, &lines);
        assert_eq!(none, serde_json::json!({"path": "p"}));
    }

    #[test]
    fn an_end_of_line_text_is_cut_to_the_room_after_its_line() {
        // the Lisp it replaces: room = max(8, width - column - 4), whole when it fits
        assert_eq!(eol_fit("short", 20, 60), "short");
        let cut = eol_fit(&"x".repeat(80), 20, 60);
        assert_eq!(cut.chars().count(), 36);
        assert!(cut.ends_with('…'));
        // never nothing at all
        assert_eq!(eol_fit(&"x".repeat(80), 58, 60).chars().count(), 8);
        // wide characters count by columns
        let wide = eol_fit(&"漢".repeat(40), 20, 60);
        assert_eq!(rodd::fit_tty::width(&wide, &[]), 35);
    }

    #[test]
    fn the_column_of_a_lines_end_counts_tabs() {
        // "ab\n\tc\nde": the first line ends at column 2 (its break is position 3), the second at 4 + 1 with tab 4
        // (positions 4 to 6), the last at 2 (7, 8)
        let cols = eol_columns("ab\n\tc\nde", &[1, 3, 4, 5, 8], 4).unwrap();
        assert_eq!(cols, [2, 2, 5, 5, 2]);
        // a position on the empty last line after a final break
        assert_eq!(eol_columns("ab\n", &[4], 8).unwrap(), [0]);
        with_limit(2, || assert!(eol_columns("ab\ncd", &[1], 8).is_none()));
    }

    #[test]
    fn no_positions_over_the_limit() {
        with_limit(4, || assert!(Lines::of("a\nb\nc\n").is_none()));
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
        // the limit itself is a constant; the check is tried at a small one
        assert_eq!(MAX_BYTES, 50 * 1024 * 1024);
        with_limit(8, || {
            assert!(within_limit(8) && !within_limit(9));
            assert!(hunk_marks("x\nx\nx\nx\nx\n", &[hunk(1, 1, 1, 1)]).is_empty());
            assert_eq!(hunk_marks("x\nx\nx\nx", &[hunk(1, 1, 1, 1)]).len(), 1);
        });
        // and the override is gone after
        assert!(within_limit(9));
    }
}
