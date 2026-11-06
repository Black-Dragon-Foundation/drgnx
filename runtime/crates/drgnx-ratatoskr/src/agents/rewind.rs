//! Rewinding and forking an agent's conversation at a step (`docs/develop/hub.md`, "Rewind and fork"): the level a
//! provider can restore ([`expected_level`]) and the point a conversation is cut at for a step ([`point_for`]).  A
//! fork always runs in a fresh process (`session::Attach::Fork`), so the lock is applied and verified at launch.
//! [`rewind_conversation`] and [`fork_conversation`] are the conversation half of a revert and a fork
//! (`history::revert`, `history::branches`).

use super::session::{self, Again, Attach};
use super::{Hub, Origin, handoff};
use crate::dispatch::Caller;
use crate::front::Front;
use crate::settings::profiles::Provider;
use hermod::ForkPoint;
use norn::read::steps::Step;
use runstav::methods::agents::{StartParams, Started};
pub use runstav::methods::history::RestoreLevel;
use runstav::wire::Error;
use serde_json::Value;
use std::path::{Path, PathBuf};

/// Whether CAPS (an agent's `agentCapabilities`) advertise `sessionCapabilities.fork`.
pub(crate) fn can_fork(caps: Option<&Value>) -> bool {
    caps.and_then(|c| c.pointer("/sessionCapabilities/fork"))
        .is_some_and(|v| !v.is_null() && *v != Value::Bool(false))
}

/// The level a fork of PROVIDER's agent with CAPS restores: Claude with the fork capability up to a message, Codex
/// with it up to a turn, anything else a summary.
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
pub(crate) struct PointStep {
    pub seq: i64,
    pub message_id: Option<String>,
    pub turn_id: Option<String>,
    pub parent_tool: Option<String>,
}

/// Where a conversation is cut for a step: the fork point AT (none: a summary), the step whose message or turn it is
/// (SOURCE_STEP), the steps after the cut the summary must carry (RETAINED, a `seq` range), and the LEVEL that holds.
#[derive(Clone, Debug, PartialEq, Eq)]
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

/// The step a rewind or a fork goes back to: step SEQ of hub session SID.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Target {
    pub sid: String,
    pub seq: i64,
}

/// A rewind of a session with no `asession` row (a finished one): there is no conversation to swap.
pub(crate) const SESSION_GONE: &str = "session-gone";
/// A rewind or fork whose new conversation must be told a summary, asked without a message from the user.
pub(crate) const NEEDS_MESSAGE: &str = "needs-message";

/// What a cut needs of a session: its steps, each with its subagent parent, in `seq` order.
async fn steps_of(front: &Front, sid: &str) -> Result<Vec<(Step, Option<String>)>, Error> {
    let s = format!("session:{sid}");
    front
        .writer
        .db
        .read(move |c| {
            let steps = norn::read::steps::for_session(c, &s, 0)?;
            let mut out = Vec::with_capacity(steps.len());
            for st in steps {
                let parent = norn::read::work::step_detail(c, st.id)?.and_then(|d| d.parent_tool);
                out.push((st, parent));
            }
            Ok(out)
        })
        .await
        .map_err(|e| session::internal(format!("the session's steps: {e}")))
}

/// The cut for T in STEPS at LEVEL, and the conversation it forks: the one the cut's step ran in (`step.acp`, so a
/// second rewind to a point before the first forks the older conversation, not the one running now).
fn cut(
    steps: &[(Step, Option<String>)],
    t: &Target,
    level: RestoreLevel,
) -> Result<(Point, String), Error> {
    let target = steps.iter().find(|(s, _)| s.seq == t.seq).ok_or_else(|| {
        session::invalid("seq", format!("session {} has no step {}", t.sid, t.seq))
    })?;
    let points: Vec<PointStep> = steps
        .iter()
        .map(|(s, parent)| PointStep {
            seq: s.seq,
            message_id: s.message_id.clone(),
            turn_id: s.turn_id.clone(),
            parent_tool: parent.clone(),
        })
        .collect();
    let point = point_for(&points, t.seq, level);
    let at = point.source_step.unwrap_or(t.seq);
    let source = steps
        .iter()
        .find(|(s, _)| s.seq == at)
        .and_then(|(s, _)| s.acp.clone())
        .or_else(|| target.0.acp.clone())
        .ok_or_else(|| {
            session::invalid(
                "seq",
                format!(
                    "step {} names no conversation: it is older than the record",
                    t.seq
                ),
            )
        })?;
    Ok((point, source))
}

/// The labelled summary a new conversation is told for T: the session's facts cut at T's step, from step FROM on.
async fn labelled(front: &Front, t: &Target, cwd: &Path, task: Option<&str>, from: i64) -> String {
    let facts = handoff::summary(front, &t.sid, cwd, task, Some(t.seq)).await;
    format!(
        "[Restored by summary: this conversation goes back to step {} of session {}; steps {from}-{} are not restored \
         as a conversation, and what follows is what they left.]\n{facts}",
        t.seq, t.sid, t.seq
    )
}

/// What the new conversation is told first at LEVEL for POINT: the user's MESSAGE alone when the conversation itself
/// is restored to the cut, else the labelled summary of what the cut leaves out joined with the message, which a
/// summary then needs (`needs-message`: no turn starts unasked).  None: nothing is told, so no turn starts.
pub(crate) async fn first_text(
    level: RestoreLevel,
    point: &Point,
    front: &Front,
    t: &Target,
    (cwd, task): (&Path, Option<&str>),
    message: Option<String>,
) -> Result<Option<String>, Error> {
    let from = match (level, point.retained) {
        (_, Some((from, _))) => from,
        (RestoreLevel::Summary, None) => 1,
        _ => return Ok(message),
    };
    let Some(m) = message else {
        return Err(needs_message());
    };
    Ok(Some(format!(
        "{}\n\n{m}",
        labelled(front, t, cwd, task, from).await
    )))
}

fn needs_message() -> Error {
    session::invalid(
        "first",
        format!(
            "{NEEDS_MESSAGE}: the conversation is restored by a summary, which goes with a message of yours"
        ),
    )
}

/// The level PROVIDER's agent would restore: from CAPS when its agent is running, else as if it can fork (a fork it
/// cannot do lands at Summary at the launch, which says so).
pub(crate) fn planned_level(provider: Option<Provider>, caps: Option<&Value>) -> RestoreLevel {
    let assumed = serde_json::json!({"sessionCapabilities": {"fork": {}}});
    expected_level(provider, Some(caps.unwrap_or(&assumed)))
}

/// Rewind hub session T.sid's conversation to step T.seq, keeping the hub session (its id, row, budget, task, queue
/// and workers).  Starts from the `asession` row, not a live session, so it runs at start-up too.  A live session is
/// detached (its running turn cut off, its queue kept) and closed as a rotation closes it; the agent is launched again
/// by a fork of the conversation the step ran in, at the cut; the row's conversation is written once that launch has
/// landed, so a launch that fails leaves the row resumable.  FIRST is the user's message; at Message or Turn level
/// with none, nothing is told and no turn starts.  The level that landed, or `session-gone` for a session with no row.
pub(crate) async fn rewind_conversation(
    hub: &Hub,
    front: &Front,
    t: &Target,
    first: Option<String>,
) -> Result<RestoreLevel, Error> {
    let Some(row) = session::read_rows(hub, Some(&t.sid))
        .await
        .into_iter()
        .next()
    else {
        return Err(session::invalid(
            "sid",
            format!(
                "{SESSION_GONE}: session {} has finished; its conversation cannot be restored",
                t.sid
            ),
        ));
    };
    let (cwd, task) = (PathBuf::from(&row.4), row.5.clone());
    let live = hub.find(&t.sid).ok();
    let provider = session::find_profile(front, &row.2).and_then(|p| p.provider());
    let level = planned_level(provider, live.as_ref().and_then(|s| s.capabilities()));
    let steps = steps_of(front, &t.sid).await?;
    let (point, source) = cut(&steps, t, level)?;
    // refused here, before anything changed, when a summary has no message
    let told = first_text(
        point.level,
        &point,
        front,
        t,
        (&cwd, task.as_deref()),
        first.clone(),
    )
    .await?;
    let summary = labelled(
        front,
        t,
        &cwd,
        task.as_deref(),
        steps.first().map_or(1, |(s, _)| s.seq),
    )
    .await;
    if let Some(s) = live {
        s.detach();
        session::close_for_swap(front, &s).await;
    }
    let attach = Attach::Fork {
        source,
        at: point.at.clone(),
        level: point.level,
    };
    let landed = session::relaunch(
        hub,
        front,
        row,
        Again::Fork {
            attach,
            told,
            summary,
            message: first,
        },
    )
    .await?;
    Ok(landed.unwrap_or(RestoreLevel::Summary))
}

/// Who a session was, from its row or, for a finished one, its `session:<sid>` entity: profile, cwd and task.
pub(crate) async fn source_of(
    hub: &Hub,
    front: &Front,
    sid: &str,
) -> Result<(String, PathBuf, Option<String>), Error> {
    if let Some(row) = session::read_rows(hub, Some(sid)).await.into_iter().next() {
        return Ok((row.2, PathBuf::from(row.4), row.5));
    }
    let id = format!("session:{sid}");
    let data = front
        .writer
        .db
        .read(move |c| Ok(urdr::graph::entity::by_id(c, &id)?.map(|e| e.data)))
        .await
        .map_err(|e| session::internal(format!("the session's record: {e}")))?
        .ok_or_else(|| session::invalid("sid", format!("no session {sid}")))?;
    let profile = data["profile"]
        .as_str()
        .ok_or_else(|| session::internal(format!("session {sid} names no profile")))?;
    let cwd = data["cwd"].as_str().map(PathBuf::from).unwrap_or_default();
    Ok((profile.to_owned(), cwd, None))
}

/// A new session from step T.seq of hub session T.sid, in CWD, on PROFILE (none: the source's), told FIRST (the
/// user's message): the source keeps running.  The same provider forks the conversation the step ran in, at the cut;
/// another provider starts a new conversation told the labelled summary.  A finished source is read from its entity.
/// The new session is linked `forked_from` its source with `{seq, level}`.  SID is its id when the caller made one
/// first (the fork's tree is named for it), else a new one; ROLE its matrix column (none: as a start without a task).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn fork_conversation(
    hub: &Hub,
    front: &Front,
    caller: &Caller,
    t: &Target,
    cwd: &Path,
    profile: Option<&str>,
    first: String,
    sid: Option<String>,
    role: Option<runstav::methods::matrix::Role>,
) -> Result<(Started, RestoreLevel), Error> {
    let (src_profile, src_cwd, task) = source_of(hub, front, &t.sid).await?;
    let name = profile.unwrap_or(&src_profile).to_owned();
    front.refresh_settings().await;
    let provider = |n: &str| session::find_profile(front, n).and_then(|p| p.provider());
    let same = provider(&name).is_some() && provider(&name) == provider(&src_profile);
    let steps = steps_of(front, &t.sid).await?;
    let (point, attach) = if same {
        let live = hub.find(&t.sid).ok();
        let level = planned_level(
            provider(&name),
            live.as_ref().and_then(|s| s.capabilities()),
        );
        let (point, source) = cut(&steps, t, level)?;
        let attach = Attach::Fork {
            source,
            at: point.at.clone(),
            level: point.level,
        };
        (point, attach)
    } else {
        let summary = Point {
            at: None,
            source_step: None,
            retained: Some((steps.first().map_or(1, |(s, _)| s.seq), t.seq)),
            level: RestoreLevel::Summary,
        };
        (summary, Attach::New)
    };
    let ctx = (src_cwd.as_path(), task.as_deref());
    let told = first_text(point.level, &point, front, t, ctx, Some(first.clone())).await?;
    let p: StartParams =
        serde_json::from_value(serde_json::json!({"profile": name, "cwd": cwd, "role": role}))
            .map_err(|e| session::invalid("cwd", e.to_string()))?;
    let (started, landed) = session::open_with(hub, front, p, caller, None, sid, &attach).await?;
    let level = landed.unwrap_or(RestoreLevel::Summary);
    let text = if level == point.level {
        told.unwrap_or(first)
    } else {
        let from = steps.first().map_or(1, |(s, _)| s.seq);
        format!(
            "{}\n\n{first}",
            labelled(front, t, ctx.0, ctx.1, from).await
        )
    };
    hub.prompt(&started.id, text, Origin::User)?;
    link_fork(front, caller, &started.id, t, level).await;
    Ok((started, level))
}

/// The `forked_from` link of session NEW to T's session, with the step and the level; best effort.
async fn link_fork(front: &Front, caller: &Caller, new: &str, t: &Target, level: RestoreLevel) {
    use urdr::graph::{entity, link};
    let (new, src) = (format!("session:{new}"), format!("session:{}", t.sid));
    let data = serde_json::json!({"seq": t.seq, "level": level});
    let r = front
        .writer
        .write(caller, "agents/start", move |tx| {
            let refused = norn::store::CoordError::Refused;
            let mut ns = Vec::with_capacity(2);
            for id in [&new, &src] {
                let e = entity::by_id(tx.sql(), id).map_err(|e| refused(e.to_string()))?;
                ns.push(e.ok_or_else(|| refused(format!("no entity {id}")))?.n);
            }
            let origin = entity::Origin::Recorded;
            link::add(tx, ns[0], "forked_from", ns[1], Some(data), origin, None)
                .map_err(|e| refused(e.to_string()))?;
            Ok(())
        })
        .await;
    if let Err(e) = r {
        tracing::warn!(sid = t.sid, "the fork's link is not recorded: {e}");
    }
}

#[cfg(test)]
mod live;
#[cfg(test)]
mod tests;
