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
