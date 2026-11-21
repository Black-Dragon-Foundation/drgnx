//! Structured intent notes on a merge (`docs/develop/orchestration.md`, "Merge notes").
//!
//! A merge of two lines of work is resolved by both sides' intent (memory of the project's own practice, made a
//! rule): every hunk both sides changed, and every file both sides changed under a path the pack names as shared,
//! needs a note in the merge commit's message:
//!
//! ```text
//! Merge-note: core/x.el:12-18 ours=1a2b3c4 theirs=5d6e7f8 resolution=both | the new key and the renamed one both stay
//! ```
//!
//! - the hunk is `PATH:FIRST-LAST` in the merge base's lines ([`conflicts`]), or `PATH` for a shared file merged
//!   cleanly ([`shared`]);
//! - `ours` and `theirs` cite a commit on each side that touched that hunk (the hub checks with `git log -L`);
//! - `resolution` is `ours`, `theirs`, `both` or `new`; the prose after `|` is the reviewer's.
//!
//! [`check`] says what is missing: a hunk with no note, a note citing a commit that didn't touch its hunk, a note
//! without a reason.

use crate::pack::glob_match;

/// One hunk of a `git diff -U0`: its lines in the old file and in the new one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Range {
    pub old_start: usize,
    pub old_len: usize,
    pub new_start: usize,
    pub new_len: usize,
}

impl Range {
    /// The old (base) lines it covers, first and last; an insertion covers the line it follows.
    fn base(&self) -> (usize, usize) {
        (self.old_start, self.old_start + self.old_len.max(1) - 1)
    }
}

/// The hunks of a `git diff -U0 --no-color --no-renames`, by file (in the diff's order).
pub fn ranges(diff: &str) -> Vec<(String, Vec<Range>)> {
    let mut out: Vec<(String, Vec<Range>)> = Vec::new();
    for l in diff.lines() {
        if let Some(rest) = l.strip_prefix("diff --git ") {
            let path = rest.rsplit_once(" b/").map(|(_, p)| p).unwrap_or(rest);
            out.push((path.to_string(), Vec::new()));
        } else if let Some(rest) = l.strip_prefix("@@ -")
            && let Some((spec, _)) = rest.split_once(" @@")
            && let Some((old, new)) = spec.split_once(" +")
            && let Some((_, hunks)) = out.last_mut()
        {
            let pair = |s: &str| -> (usize, usize) {
                match s.split_once(',') {
                    Some((a, b)) => (a.parse().unwrap_or(0), b.parse().unwrap_or(0)),
                    None => (s.parse().unwrap_or(0), 1),
                }
            };
            let ((old_start, old_len), (new_start, new_len)) = (pair(old), pair(new));
            hunks.push(Range {
                old_start,
                old_len,
                new_start,
                new_len,
            });
        }
    }
    out
}

/// A hunk both sides changed: `PATH:FIRST-LAST` in the base's lines.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hunk {
    pub path: String,
    pub first: usize,
    pub last: usize,
}

impl Hunk {
    /// The hunk as a note names it.
    pub fn key(&self) -> String {
        format!("{}:{}-{}", self.path, self.first, self.last)
    }
}

/// The hunks both OURS and THEIRS (each [`ranges`] of a diff from the merge base) changed: base ranges of the two
/// sides that overlap or touch (git conflicts on neighbouring lines too), joined.
pub fn conflicts(ours: &[(String, Vec<Range>)], theirs: &[(String, Vec<Range>)]) -> Vec<Hunk> {
    let mut out = Vec::new();
    for (path, o) in ours {
        let Some((_, t)) = theirs.iter().find(|(p, _)| p == path) else {
            continue;
        };
        let mut spans: Vec<(usize, usize)> = Vec::new();
        for a in o {
            let (a1, a2) = a.base();
            for b in t {
                let (b1, b2) = b.base();
                if a1 <= b2 + 1 && b1 <= a2 + 1 {
                    spans.push((a1.min(b1), a2.max(b2)));
                }
            }
        }
        spans.sort();
        let mut joined: Vec<(usize, usize)> = Vec::new();
        for (s, e) in spans {
            match joined.last_mut() {
                Some(last) if s <= last.1 + 1 => last.1 = last.1.max(e),
                _ => joined.push((s, e)),
            }
        }
        out.extend(joined.into_iter().map(|(first, last)| Hunk {
            path: path.clone(),
            first,
            last,
        }));
    }
    out
}

/// The files both sides changed under a SHARED glob that have no hunk in CONFLICTS (a clean merge there is still
/// audited).
pub fn shared(
    ours: &[(String, Vec<Range>)],
    theirs: &[(String, Vec<Range>)],
    conflicts: &[Hunk],
    globs: &[String],
) -> Vec<String> {
    ours.iter()
        .map(|(p, _)| p)
        .filter(|p| theirs.iter().any(|(q, _)| q == *p))
        .filter(|p| globs.iter().any(|g| glob_match(g, p)))
        .filter(|p| !conflicts.iter().any(|h| &h.path == *p))
        .cloned()
        .collect()
}

/// The new file's lines HUNK covers on a side whose diff from the base has RANGES (the side's hunks that overlap
/// it, joined); `None` when that side didn't change it.
pub fn side_lines(ranges: &[Range], hunk: &Hunk) -> Option<(usize, usize)> {
    let mut span: Option<(usize, usize)> = None;
    for r in ranges {
        let (b1, b2) = r.base();
        if b1 <= hunk.last + 1 && hunk.first <= b2 + 1 {
            let s = r.new_start.max(1);
            let e = s + r.new_len.max(1) - 1;
            span = Some(span.map_or((s, e), |(a, b)| (a.min(s), b.max(e))));
        }
    }
    span
}

/// How a hunk was resolved.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Resolution {
    Ours,
    Theirs,
    Both,
    New,
}

/// One `Merge-note:` line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Note {
    pub hunk: String,
    pub ours: String,
    pub theirs: String,
    pub resolution: Option<Resolution>,
    pub prose: String,
}

/// The `Merge-note:` lines of a merge commit's MESSAGE.
pub fn parse_notes(message: &str) -> Vec<Note> {
    message
        .lines()
        .filter_map(|l| l.trim().strip_prefix("Merge-note:"))
        .map(|rest| {
            let (head, prose) = rest.split_once('|').unwrap_or((rest, ""));
            let mut words = head.split_whitespace();
            let mut n = Note {
                hunk: words.next().unwrap_or("").to_string(),
                ours: String::new(),
                theirs: String::new(),
                resolution: None,
                prose: prose.trim().to_string(),
            };
            for w in words {
                match w.split_once('=') {
                    Some(("ours", v)) => n.ours = v.to_string(),
                    Some(("theirs", v)) => n.theirs = v.to_string(),
                    Some(("resolution", v)) => {
                        n.resolution = match v {
                            "ours" => Some(Resolution::Ours),
                            "theirs" => Some(Resolution::Theirs),
                            "both" => Some(Resolution::Both),
                            "new" => Some(Resolution::New),
                            _ => None,
                        }
                    }
                    _ => {}
                }
            }
            n
        })
        .collect()
}

/// Which side a citation is on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Ours,
    Theirs,
}

/// What keeps a merge's notes from passing: each REQUIRED hunk key needs a note (the newest for a key counts) with a
/// resolution, a reason, and citations TOUCHES confirms (the side, the hunk key and the cited commit).  Empty: the
/// notes pass.
pub fn check(
    required: &[String],
    notes: &[Note],
    touches: impl Fn(Side, &str, &str) -> bool,
) -> Vec<String> {
    let mut out = Vec::new();
    for key in required {
        let Some(n) = notes.iter().rev().find(|n| &n.hunk == key) else {
            out.push(format!("{key}: no Merge-note"));
            continue;
        };
        if n.resolution.is_none() {
            out.push(format!("{key}: no resolution (ours, theirs, both or new)"));
        }
        if n.prose.is_empty() {
            out.push(format!("{key}: no reason after |"));
        }
        for (side, sha, name) in [
            (Side::Ours, &n.ours, "ours"),
            (Side::Theirs, &n.theirs, "theirs"),
        ] {
            if sha.len() < 7 {
                out.push(format!("{key}: {name} cites no commit"));
            } else if !touches(side, key, sha) {
                out.push(format!("{key}: {name} {sha} did not touch it"));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const OURS: &str = "diff --git a/core/x.el b/core/x.el\n--- a/core/x.el\n+++ b/core/x.el\n\
@@ -10,2 +10,3 @@ (defun a\n-a\n-b\n+A\n+B\n+C\n@@ -40 +41,0 @@\n-z\n\
diff --git a/settings/s.el b/settings/s.el\n--- a/settings/s.el\n+++ b/settings/s.el\n@@ -3,0 +4 @@\n+k\n\
diff --git a/only/ours.el b/only/ours.el\n@@ -1 +1 @@\n-x\n+y\n";
    const THEIRS: &str = "diff --git a/core/x.el b/core/x.el\n@@ -12 +12 @@\n-c\n+C2\n@@ -30 +30 @@\n-q\n+Q\n\
diff --git a/settings/s.el b/settings/s.el\n@@ -20 +20 @@\n-m\n+M\n";

    #[test]
    fn hunks_both_sides_changed_are_found_in_the_bases_lines() {
        let (o, t) = (ranges(OURS), ranges(THEIRS));
        assert_eq!(o.len(), 3);
        assert_eq!(
            o[0].1[0],
            Range {
                old_start: 10,
                old_len: 2,
                new_start: 10,
                new_len: 3
            }
        );
        // ours 10-11 and theirs 12 touch: one hunk 10-12; ours' deletion at 40 and theirs' 30 don't meet
        let c = conflicts(&o, &t);
        assert_eq!(
            c.iter().map(Hunk::key).collect::<Vec<_>>(),
            vec!["core/x.el:10-12"]
        );
        // settings/s.el: both changed it, apart: a shared file merged cleanly
        let globs = vec!["settings/*".to_string()];
        assert_eq!(shared(&o, &t, &c, &globs), vec!["settings/s.el"]);
        assert!(shared(&o, &t, &c, &[]).is_empty());
        // the hunk's lines on each side, for git log -L
        assert_eq!(side_lines(&o[0].1, &c[0]), Some((10, 12)));
        assert_eq!(side_lines(&t[0].1, &c[0]), Some((12, 12)));
    }

    #[test]
    fn notes_are_read_from_the_merge_message() {
        let n = parse_notes(
            "Merge job/j into task\n\nMerge-note: core/x.el:10-12 ours=1a2b3c4 theirs=5d6e7f8 resolution=both | keep both keys\n\
             Merge-note: settings/s.el ours=aaaaaaa theirs=bbbbbbb resolution=maybe\n",
        );
        assert_eq!(n.len(), 2);
        assert_eq!(
            n[0],
            Note {
                hunk: "core/x.el:10-12".into(),
                ours: "1a2b3c4".into(),
                theirs: "5d6e7f8".into(),
                resolution: Some(Resolution::Both),
                prose: "keep both keys".into(),
            }
        );
        assert_eq!(n[1].resolution, None);
        assert_eq!(n[1].prose, "");
    }

    #[test]
    fn every_hunk_needs_a_note_citing_commits_that_touched_it() {
        let required = vec!["core/x.el:10-12".to_string(), "settings/s.el".to_string()];
        let good = parse_notes(
            "Merge-note: core/x.el:10-12 ours=1a2b3c4 theirs=5d6e7f8 resolution=both | keep both\n",
        );
        let touches = |side: Side, _: &str, sha: &str| match side {
            Side::Ours => sha == "1a2b3c4",
            Side::Theirs => sha == "5d6e7f8",
        };
        // the shared file has no note
        assert_eq!(
            check(&required, &good, touches),
            vec!["settings/s.el: no Merge-note"]
        );
        // a citation of a commit that never touched the hunk, a missing reason
        let bad = parse_notes(
            "Merge-note: core/x.el:10-12 ours=1a2b3c4 theirs=9999999 resolution=ours\n\
             Merge-note: settings/s.el ours=1a2b3c4 theirs=5d6e7f8 resolution=new | a new table\n",
        );
        assert_eq!(
            check(&required, &bad, touches),
            vec![
                "core/x.el:10-12: no reason after |",
                "core/x.el:10-12: theirs 9999999 did not touch it"
            ]
        );
        assert!(check(&[], &[], touches).is_empty());
    }
}
