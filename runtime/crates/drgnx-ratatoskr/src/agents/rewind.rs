//! Rewinding and forking an agent's conversation at a step (`docs/develop/hub.md`, "Rewind and fork"): the level a
//! provider can restore ([`expected_level`]) and the point a conversation is cut at for a step ([`point_for`]).  A
//! fork always runs in a fresh process (`session::Attach::Fork`), so the lock is applied and verified at launch.

use crate::settings::profiles::Provider;
use hermod::ForkPoint;
pub use runstav::methods::history::RestoreLevel;
use serde_json::Value;

/// Whether CAPS (an agent's `agentCapabilities`) advertise `sessionCapabilities.fork`.
pub(crate) fn can_fork(caps: Option<&Value>) -> bool {
    caps.and_then(|c| c.pointer("/sessionCapabilities/fork"))
        .is_some_and(|v| !v.is_null() && *v != Value::Bool(false))
}

/// The level a fork of PROVIDER's agent with CAPS restores: Claude with the fork capability up to a message, Codex
/// with it up to a turn, anything else a summary.
#[cfg_attr(not(test), expect(dead_code, reason = "read by the rewind"))]
pub(crate) fn expected_level(provider: Option<Provider>, caps: Option<&Value>) -> RestoreLevel {
    match (provider, can_fork(caps)) {
        (Some(Provider::Claude), true) => RestoreLevel::Message,
        (Some(Provider::Codex), true) => RestoreLevel::Turn,
        _ => RestoreLevel::Summary,
    }
}

/// What the cut reads of a step: its `seq`, the message and turn ids the `step` table holds, and the `Task` call of
/// the subagent that made it (`step_detail.parent_tool`).
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(not(test), expect(dead_code, reason = "read by the rewind"))]
pub(crate) struct PointStep {
    pub seq: i64,
    pub message_id: Option<String>,
    pub turn_id: Option<String>,
    pub parent_tool: Option<String>,
}

/// Where a conversation is cut for a step: the fork point AT (none: a summary), the step whose message or turn it is
/// (SOURCE_STEP), the steps after the cut the summary must carry (RETAINED, a `seq` range), and the LEVEL that holds.
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(not(test), expect(dead_code, reason = "read by the rewind"))]
pub(crate) struct Point {
    pub at: Option<ForkPoint>,
    pub source_step: Option<i64>,
    pub retained: Option<(i64, i64)>,
    pub level: RestoreLevel,
}

/// The cut for step SEQ of STEPS (one session's, in `seq` order) at LEVEL.
///
/// Message: the last message id at or before SEQ (the steps of one message share it).  A subagent's step rounds down
/// to the message before the one that holds its `Task` call, so the cut never lands inside a call with no result; the
/// steps it drops are RETAINED.  Turn: the end of the last turn completed at or before SEQ (the step that carries its
/// turn id), cut at that turn's last message; a step inside a running turn rounds down, and the steps after the cut are
/// RETAINED.  Neither found, or Summary asked: Summary, carrying every step up to SEQ.
#[cfg_attr(not(test), expect(dead_code, reason = "read by the rewind"))]
pub(crate) fn point_for(steps: &[PointStep], seq: i64, level: RestoreLevel) -> Point {
    let upto: Vec<&PointStep> = steps.iter().filter(|s| s.seq <= seq).collect();
    let summary = Point {
        at: None,
        source_step: None,
        retained: Some((upto.first().map_or(seq, |s| s.seq), seq)),
        level: RestoreLevel::Summary,
    };
    // the last message id among UPTO[..END], with its step
    let last_id = |end: usize, skip: Option<&str>| {
        upto[..end].iter().rev().find_map(|s| {
            s.message_id
                .as_deref()
                .filter(|m| Some(*m) != skip)
                .map(|m| (s.seq, m.to_string()))
        })
    };
    let cut = match level {
        RestoreLevel::Summary => None,
        RestoreLevel::Message => {
            let Some(target) = upto.last() else {
                return summary;
            };
            match &target.parent_tool {
                None => last_id(upto.len(), None).map(|c| (c, None)),
                Some(parent) => {
                    // the subagent's first step began in the message that holds its `Task` call
                    let first = upto
                        .iter()
                        .position(|s| s.parent_tool.as_ref() == Some(parent))
                        .unwrap_or(upto.len() - 1);
                    let task_message = upto[first].message_id.as_deref();
                    last_id(first, task_message).map(|(s, m)| ((s, m), Some((s + 1, seq))))
                }
            }
        }
        RestoreLevel::Turn => upto
            .iter()
            .rposition(|s| s.turn_id.is_some())
            .and_then(|i| {
                let end = upto[i].seq;
                last_id(i + 1, None).map(|(_, m)| ((end, m), (end < seq).then_some((end + 1, seq))))
            }),
    };
    match cut {
        Some(((source, message_id), retained)) => Point {
            at: Some(ForkPoint { message_id }),
            source_step: Some(source),
            retained,
            level,
        },
        None => summary,
    }
}

#[cfg(test)]
mod tests;
