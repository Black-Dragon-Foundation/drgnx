//! The three-way projection: goldens (pattern D).

use super::*;

/// Lines 1..=N, "lN".
fn lines(n: usize) -> String {
    (1..=n).map(|i| format!("l{i}\n")).collect()
}

fn r(start: u32, end: u32) -> LineRange {
    LineRange { start, end }
}

/// Pattern D. The user typed two lines at the top and changed line 5; the agent changed line 8. The agent's range
/// is its line 8, now at the user's line 10; the user's changes are theirs alone.
#[test]
fn a_user_edit_is_never_the_agents() {
    let base = lines(12);
    let agent = base.replace("l8\n", "AGENT\n");
    let user = format!("u1\nu2\n{}", base.replace("l5\n", "USER\n"));
    let p = project(&base, &agent, &user, None);
    assert_eq!(p.agent_ranges, vec![r(10, 10)]);
    assert_eq!(p.user_ranges, vec![r(1, 2), r(7, 7)]);
    assert!(p.conflicts.is_empty());
    for u in &p.user_ranges {
        assert!(
            p.agent_ranges
                .iter()
                .all(|a| a.end < u.start || a.start > u.end),
            "{p:?}"
        );
    }
}

/// Pattern D. The user's branch gained a commit after the worktree's base (lines 3 and 4 rewritten, one added): that is
/// the user's side; the agent, which touched only line 10, shows there alone, one line down.
#[test]
fn a_later_head_commit_is_never_the_agents() {
    let base = lines(12);
    let head = base.replace("l3\nl4\n", "c3\nc4\nc4b\n");
    let agent = base.replace("l10\n", "agent10\n");
    let p = project(&base, &agent, &head, None);
    assert_eq!(p.agent_ranges, vec![r(11, 11)]);
    assert_eq!(p.user_ranges, vec![r(3, 5)]);
    assert!(p.conflicts.is_empty());
}

/// Pattern D. Both changed line 6: a conflict on the user's line, never an agent range.
#[test]
fn overlap_is_conflict() {
    let base = lines(10);
    let agent = base.replace("l6\nl7\n", "a6\na7\n");
    let user = base.replace("l6\n", "u6\n");
    let p = project(&base, &agent, &user, None);
    assert_eq!(p.conflicts, vec![r(6, 6)]);
    assert!(p.agent_ranges.is_empty(), "{p:?}");
    // an agent insertion inside the user's changed lines is one too
    let user = base.replace("l3\nl4\nl5\n", "x\ny\nz\n");
    let agent = base.replace("l4\n", "l4\nnew\n");
    let p = project(&base, &agent, &user, None);
    assert_eq!(p.conflicts, vec![r(3, 5)]);
}

/// Pattern D. A CRLF user buffer (or base) maps as LF does.
#[test]
fn crlf_buffer_maps_like_lf() {
    let base = lines(8);
    let agent = base.replace("l7\n", "seven\n");
    let user = format!("top\n{base}");
    let lf_p = project(&base, &agent, &user, None);
    let crlf_p = project(
        &base.replace('\n', "\r\n"),
        &agent,
        &user.replace('\n', "\r\n"),
        None,
    );
    assert_eq!(crlf_p, lf_p);
    assert_eq!(lf_p.agent_ranges, vec![r(8, 8)]);
}

/// Pattern D. The agent's cursor (on its own line 9, inside the two lines it added after line 6) lands on the user's
/// text where those lines go: after the user's added top line, at the user's line 8 (base line 7); a cursor on a
/// line both kept maps one to one.
#[test]
fn cursor_maps_onto_the_users_line() {
    let base = lines(10);
    let agent = base.replace("l6\n", "l6\nadd1\nadd2\n");
    let user = format!("top\n{base}");
    let p = project(&base, &agent, &user, Some(Pos { line: 8 }));
    assert_eq!(p.cursor_on_user, Some(8));
    let p = project(&base, &agent, &user, Some(Pos { line: 10 }));
    assert_eq!(
        p.cursor_on_user,
        Some(9),
        "agent line 10 is base line 8, the user's 9"
    );
    assert_eq!(
        p.agent_ranges,
        vec![r(7, 7)],
        "the insertion shows on the line before it"
    );
}

/// Pattern D. A frame from the user's text on disk is approximate; one from the edit history's mirror is not. The
/// base cache reads each (commit, path) once and keeps at most its bound.
#[test]
fn approximate_when_the_users_text_is_disk() {
    assert!(UserSource::Disk.approximate());
    assert!(!UserSource::Mirror.approximate());
    let mut cache = BaseCache::default();
    let mut reads = 0;
    for _ in 0..3 {
        let t = cache.get_or("c1", "a.rs", || {
            reads += 1;
            Some("x\n".into())
        });
        assert_eq!(t.as_deref(), Some("x\n"));
    }
    assert_eq!(reads, 1);
    assert!(cache.get_or("c1", "gone.rs", || None).is_none());
    for i in 0..(BASE_CACHE + 10) {
        cache.get_or("c2", &format!("f{i}"), || Some(String::new()));
    }
    assert_eq!(cache.len(), BASE_CACHE);
}

/// Pattern D. The user changed line 2 in the buffer and has not saved: the disk still has the base. Projected through
/// the edit history's mirror, the agent's change of line 2 meets the user's and is a conflict, and the frame is exact;
/// from disk it would be the agent's line, marked approximate.
#[test]
fn unsaved_user_edits_are_seen_through_the_mirror() {
    let base = lines(5);
    let agent = base.replace("l2\n", "AGENT\n");
    let unsaved = base.replace("l2\n", "TYPED\n");
    let disk = base.clone();
    let (user, source) = user_text(Some(unsaved.clone()), || Some(disk.clone())).unwrap();
    assert_eq!(
        (user.as_str(), source),
        (unsaved.as_str(), UserSource::Mirror)
    );
    assert!(!source.approximate());
    let p = project(&base, &agent, &user, None);
    assert!(p.agent_ranges.is_empty(), "{p:?}");
    assert_eq!(p.conflicts, vec![r(2, 2)]);
    // without a mirror (an untracked buffer): the disk, approximate
    let (user, source) = user_text(None, || Some(disk.clone())).unwrap();
    assert_eq!(source, UserSource::Disk);
    assert!(source.approximate());
    assert_eq!(
        project(&base, &agent, &user, None).agent_ranges,
        vec![r(2, 2)]
    );
}

/// Pattern D (golden). A paired agent P wrote line 3 of the user's checkout (through the user's buffer); an agent W in
/// another worktree changed lines 3 and 5. P's line is the user's side of W's projection (W's change there is a
/// conflict, never W's line), and it is drawn in P's identity from the history's line authors; W keeps line 5.
#[test]
fn a_paired_agents_edits_are_the_users_side_in_its_identity() {
    use crate::editor::ranges::{AgentRanges, Op, agent_lines};
    let base = lines(6);
    let mut checkout = AgentRanges::new(&base);
    // P replaces "l3" (characters 6..8) through the user's buffer; the user types on line 1
    assert!(checkout.apply_op(Op {
        author: "agent:P",
        start: 6,
        old_len: 2,
        inserted: "paired",
    }));
    assert!(checkout.apply_op(Op {
        author: "user",
        start: 0,
        old_len: 0,
        inserted: "u",
    }));
    let user = "ul1\nl2\npaired\nl4\nl5\nl6\n";
    let worktree = base.replace("l3\n", "W3\n").replace("l5\n", "W5\n");
    let p = project(&base, &worktree, user, None);
    assert_eq!(
        (p.agent_ranges, p.user_ranges, p.conflicts),
        (vec![r(5, 5)], vec![r(1, 1), r(3, 3)], vec![r(3, 3)])
    );
    let by: Vec<(String, Vec<LineRange>)> = checkout
        .authors()
        .into_iter()
        .map(|a| {
            let rs = checkout.ranges(&a);
            (a, rs)
        })
        .collect();
    assert_eq!(agent_lines(&by), vec![("P".to_string(), r(3, 3))]);
}
