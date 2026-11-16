//! Proposals (frontend flow plan, Task 18): what an agent working in its own worktree changed in the file you are
//! looking at, offered as hunks. A paired agent writes into your buffer live and proposes nothing. Accept is
//! `review/mark accepted` for the hunk; Revert is `history/revert/hunk` in the agent's worktree.

use runstav::methods::editor::Proposal;

/// The proposals in DIFF (a unified diff of the file against the session's base), numbered from 0 per session: each
/// hunk's lines in the new file, and the lines it adds as its text.
pub fn from_diff(session: &str, diff: &str) -> Vec<Proposal> {
    let mut out: Vec<Proposal> = Vec::new();
    let mut in_hunk = false;
    for line in diff.lines() {
        if line.starts_with("@@") {
            let new = line
                .split_whitespace()
                .find(|w| w.starts_with('+'))
                .map(|w| w.trim_start_matches('+'));
            let parsed = new.and_then(|n| {
                let (a, b) = n.split_once(',').unwrap_or((n, "1"));
                Some((a.parse::<u32>().ok()?, b.parse::<u32>().ok()?))
            });
            in_hunk = parsed.is_some();
            if let Some((start, len)) = parsed {
                out.push(Proposal {
                    session: session.to_owned(),
                    op: None,
                    index: u32::try_from(out.len()).unwrap_or(u32::MAX),
                    start_line: start,
                    end_line: start + len.saturating_sub(1),
                    text: String::new(),
                    reason: None,
                });
            }
        } else if in_hunk
            && let Some(added) = line.strip_prefix('+')
            && let Some(p) = out.last_mut()
        {
            if !p.text.is_empty() {
                p.text.push('\n');
            }
            p.text.push_str(added);
        }
    }
    out
}

/// The proposals of every session in SESSIONS (id, paired now, diff): a paired agent's writes land in the buffer
/// itself, so it makes none.
pub fn for_sessions(sessions: &[(String, bool, String)]) -> Vec<Proposal> {
    sessions
        .iter()
        .filter(|(_, paired, _)| !paired)
        .flat_map(|(sid, _, diff)| from_diff(sid, diff))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const DIFF: &str =
        "--- a/f\n+++ b/f\n@@ -1,2 +1,3 @@\n a\n+b\n c\n@@ -10 +11,2 @@\n-x\n+y\n+z\n";

    #[test]
    fn a_diff_is_read_into_hunks_with_their_added_text() {
        let ps = from_diff("s1", DIFF);
        assert_eq!(ps.len(), 2);
        assert_eq!(
            (ps[0].start_line, ps[0].end_line, ps[0].text.as_str()),
            (1, 3, "b")
        );
        assert_eq!(
            (ps[1].start_line, ps[1].end_line, ps[1].text.as_str()),
            (11, 12, "y\nz")
        );
        assert_eq!(ps[1].index, 1);
        assert_eq!(ps[0].reason, None);
    }

    #[test]
    fn proposals_only_for_non_pair_sessions() {
        let got = for_sessions(&[
            ("worktree".into(), false, DIFF.into()),
            ("paired".into(), true, DIFF.into()),
        ]);
        assert!(!got.is_empty());
        assert!(got.iter().all(|p| p.session == "worktree"), "{got:?}");
    }
}
