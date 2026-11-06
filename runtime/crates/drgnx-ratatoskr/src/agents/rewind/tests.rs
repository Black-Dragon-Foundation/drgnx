//! The restore level a provider gives and the point a conversation is cut at: pure, no process, no clock.

use super::*;
use crate::settings::profiles::Provider;
use serde_json::json;

fn step(seq: i64, message: Option<&str>, turn: Option<&str>) -> PointStep {
    PointStep {
        seq,
        message_id: message.map(Into::into),
        turn_id: turn.map(Into::into),
        parent_tool: None,
        undone_by: None,
    }
}

/// A step a revert (record OP) abandoned.
fn undone(seq: i64, message: Option<&str>, turn: Option<&str>, op: i64) -> PointStep {
    PointStep {
        undone_by: Some(op),
        ..step(seq, message, turn)
    }
}

/// A step a subagent made inside the `Task` call PARENT.
fn sub(seq: i64, message: Option<&str>, parent: &str) -> PointStep {
    PointStep {
        parent_tool: Some(parent.into()),
        ..step(seq, message, None)
    }
}

fn mid(p: &Point) -> Option<&str> {
    p.at.as_ref().map(|a| a.message_id.as_str())
}

#[test]
fn point_message_uses_the_last_id_at_or_before() {
    let steps = [
        step(1, None, None),
        step(2, Some("m1"), None),
        step(3, None, None),
        step(4, Some("m2"), Some("t1")),
        step(5, Some("m3"), None),
    ];
    let p = point_for(&steps, 3, RestoreLevel::Message);
    assert_eq!(
        (mid(&p), p.source_step, p.level, p.retained),
        (Some("m1"), Some(2), RestoreLevel::Message, None),
        "step 3 has no id of its own: step 2's"
    );
    let p = point_for(&steps, 4, RestoreLevel::Message);
    assert_eq!((mid(&p), p.source_step), (Some("m2"), Some(4)));
}

#[test]
fn point_two_tool_steps_of_one_message_share_it() {
    let steps = [
        step(1, Some("m1"), None),
        step(2, Some("m2"), None),
        step(3, Some("m2"), None),
        step(4, Some("m3"), Some("t1")),
    ];
    for seq in [2, 3] {
        let p = point_for(&steps, seq, RestoreLevel::Message);
        assert_eq!(
            (mid(&p), p.level),
            (Some("m2"), RestoreLevel::Message),
            "{seq}"
        );
    }
}

#[test]
fn point_rounds_a_subagent_step_to_before_its_task_call() {
    // m2 holds the `Task` call; the subagent's steps carry m2, the session's last message when they began
    let steps = [
        step(1, Some("m1"), None),
        step(2, Some("m2"), None),
        sub(3, Some("m2"), "task-1"),
        sub(4, Some("m2"), "task-1"),
        step(5, Some("m3"), Some("t1")),
    ];
    let p = point_for(&steps, 4, RestoreLevel::Message);
    assert_eq!(
        (mid(&p), p.source_step, p.level, p.retained),
        (Some("m1"), Some(1), RestoreLevel::Message, Some((2, 4))),
        "the cut is before m2, and the steps after it are carried as a summary"
    );
    // nothing before the Task call's message: no message to cut at
    let p = point_for(&steps[1..4], 4, RestoreLevel::Message);
    assert_eq!((p.level, p.at), (RestoreLevel::Summary, None));
}

#[test]
fn point_turn_rounds_down_mid_turn() {
    // as the `step` table holds them: once a turn ends, every one of its steps carries its id; a running turn's none
    let steps = [
        step(1, Some("u1"), Some("t1")),
        step(2, Some("a1"), Some("t1")),
        step(3, Some("u2"), Some("t2")),
        step(4, Some("a2"), Some("t2")),
        step(5, Some("a2"), Some("t2")),
        step(6, Some("u3"), None),
    ];
    let p = point_for(&steps, 4, RestoreLevel::Turn);
    assert_eq!(
        (mid(&p), p.source_step, p.level, p.retained),
        (Some("a1"), Some(2), RestoreLevel::Turn, Some((3, 4))),
        "step 4 is inside turn two: the end of turn one, and steps 3-4 as a summary"
    );
    let p = point_for(&steps, 6, RestoreLevel::Turn);
    assert_eq!(
        (mid(&p), p.source_step, p.retained),
        (Some("a2"), Some(5), Some((6, 6))),
        "turn three is still running at step 6: the end of turn two"
    );
    for (seq, want) in [(2, "a1"), (5, "a2")] {
        let p = point_for(&steps, seq, RestoreLevel::Turn);
        assert_eq!(
            (mid(&p), p.source_step, p.retained),
            (Some(want), Some(seq), None),
            "step {seq} ends its turn"
        );
    }
    let p = point_for(&steps, 1, RestoreLevel::Turn);
    assert_eq!(
        (p.level, p.at, p.retained),
        (RestoreLevel::Summary, None, Some((1, 1))),
        "inside the first turn no turn has ended"
    );
}

#[test]
fn point_never_cuts_into_steps_a_revert_abandoned() {
    // turn two was reverted to the end of turn one; the new conversation's turn has the id "t2" again, as Codex's
    // ids restart after a fork
    let running = [
        step(1, Some("u1"), Some("t1")),
        step(2, Some("a1"), Some("t1")),
        undone(3, Some("u2"), Some("t2"), 9),
        undone(4, Some("a2"), Some("t2"), 9),
        step(5, Some("u3"), None),
        step(6, Some("a3"), None),
    ];
    let p = point_for(&running, 6, RestoreLevel::Turn);
    assert_eq!(
        (mid(&p), p.source_step, p.level, p.retained),
        (Some("a1"), Some(2), RestoreLevel::Turn, Some((5, 6))),
        "the new turn runs: the end of turn one, not of the abandoned turn with the same id"
    );
    let ended = [
        step(1, Some("u1"), Some("t1")),
        step(2, Some("a1"), Some("t1")),
        undone(3, Some("u2"), Some("t2"), 9),
        undone(4, Some("a2"), Some("t2"), 9),
        step(5, Some("u3"), Some("t2")),
        step(6, Some("a3"), Some("t2")),
    ];
    let p = point_for(&ended, 5, RestoreLevel::Turn);
    assert_eq!(
        (mid(&p), p.source_step, p.retained),
        (Some("a1"), Some(2), Some((5, 5))),
        "inside the new turn: the summary carries none of the abandoned steps"
    );
    // a tool step of the new conversation with no message id of its own: the message before the abandoned ones
    let claude = [
        step(1, Some("m1"), None),
        step(2, Some("m2"), Some("t1")),
        undone(3, Some("m3"), None, 9),
        undone(4, Some("m4"), Some("t2"), 9),
        step(5, None, None),
    ];
    let p = point_for(&claude, 5, RestoreLevel::Message);
    assert_eq!(
        (mid(&p), p.source_step, p.level),
        (Some("m2"), Some(2), RestoreLevel::Message)
    );
    // with nothing of its own line before it, the cut is a summary of that line only
    let p = point_for(&running[2..], 6, RestoreLevel::Turn);
    assert_eq!(
        (p.level, p.at, p.retained),
        (RestoreLevel::Summary, None, Some((5, 6)))
    );
    // a revert to step 3 marks the steps after it before it rewinds: they still end its turn
    let reverting = [
        step(1, Some("u1"), Some("t1")),
        step(2, Some("a1"), Some("t1")),
        step(3, Some("u2"), Some("t2")),
        undone(4, Some("a2"), Some("t2"), 9),
    ];
    let p = point_for(&reverting, 3, RestoreLevel::Turn);
    assert_eq!(
        (mid(&p), p.source_step, p.retained),
        (Some("a1"), Some(2), Some((3, 3))),
        "step 3 is inside turn two, which ended at step 4"
    );
    // an abandoned step's own line: its revert's steps and those before them, not the new conversation's
    let p = point_for(&ended, 4, RestoreLevel::Turn);
    assert_eq!(
        (mid(&p), p.source_step, p.retained),
        (Some("a2"), Some(4), None),
        "step 4 ended the abandoned turn two"
    );
}

#[test]
fn point_turn_in_the_first_turn_is_summary() {
    let steps = [step(1, Some("u1"), None), step(2, Some("a1"), None)];
    let p = point_for(&steps, 2, RestoreLevel::Turn);
    assert_eq!(
        (p.level, p.at, p.source_step, p.retained),
        (RestoreLevel::Summary, None, None, Some((1, 2)))
    );
}

#[test]
fn point_without_ids_is_summary() {
    let steps = [step(1, None, None), step(2, None, None)];
    for level in [
        RestoreLevel::Message,
        RestoreLevel::Turn,
        RestoreLevel::Summary,
    ] {
        let p = point_for(&steps, 2, level);
        assert_eq!(
            (p.level, p.at, p.retained),
            (RestoreLevel::Summary, None, Some((1, 2))),
            "{level:?}"
        );
    }
}

#[test]
fn expected_level_per_provider() {
    let fork = json!({"sessionCapabilities": {"fork": {}}});
    let none = json!({"sessionCapabilities": {"resume": {}}});
    let cases = [
        (Some(Provider::Claude), Some(&fork), RestoreLevel::Message),
        (Some(Provider::Codex), Some(&fork), RestoreLevel::Turn),
        (Some(Provider::Gemini), Some(&fork), RestoreLevel::Summary),
        (None, Some(&fork), RestoreLevel::Summary),
        (Some(Provider::Claude), Some(&none), RestoreLevel::Summary),
        (Some(Provider::Codex), None, RestoreLevel::Summary),
    ];
    for (provider, caps, want) in cases {
        assert_eq!(
            expected_level(provider, caps),
            want,
            "{provider:?} {caps:?}"
        );
    }
}
