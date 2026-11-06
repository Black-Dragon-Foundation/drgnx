//! Revert to here (`docs/develop/hub.md`, "Revert to here"): `history/revert/preview` and `history/revert/apply`, the
//! shell over [`super::revert_core`].  The core says what to do next; this does it.
//!
//! The files go back to the step's checkpoint (`timeline::snapshot`), one path at a time, and a revert never loses the
//! user's work: a path someone changed after the agent's last step (its newest checkpoint) is the user's.  Where the
//! user's edit and the agent's do not meet, the revert merges them (`git merge-file`: base the agent's last version,
//! ours the user's, theirs the step's) and keeps the user's edit; where they meet, the path is an overlap the user
//! answers (keep mine, the default; take the reverted file; or an edited text).  `roll-back-mine` writes every path
//! back.  What the files held before is kept under `refs/drgnx/undone/<op>` in the shadow repository either way.

use super::revert_core::{Pending, RevertCore, RevertEffect, RevertEvent, RevertStep};
use crate::agents::rewind::{self, Target};
use crate::agents::session::{self, internal, invalid};
use crate::dispatch::Caller;
use crate::front::Front;
use crate::timeline::snapshot;
use runstav::methods::history::{self as w, RestoreLevel, RevertChoice, RevertMode};
use runstav::registry::Class;
use runstav::wire::Error;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

/// A preview made against an older state of the files or the session.
pub(crate) const STALE: &str = "stale";
/// Another session's work rests on what the revert would undo.
pub(crate) const BLOCKED: &str = "blocked";
/// The step cannot be reverted: no checkpoint (older than the history), no tree, or the caller may not.
pub(crate) const NOT_REVERTIBLE: &str = "not-revertible";
/// What a finished worker's card says of its conversation.
pub(crate) const FINISHED: &str = "conversation not restored: the agent has finished";

/// A file the revert merges with the user's later edit: the merged text and the file's mode.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Merge {
    pub path: PathBuf,
    pub text: String,
    pub mode: u32,
}

/// What a revert does, worked out by the preview and kept (in memory, then in the pending record) until it is done.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub(crate) struct Plan {
    pub sid: String,
    pub seq: i64,
    pub cwd: PathBuf,
    /// The checkpoints' folder (`<state>/hub/checkpoints`).
    pub root: PathBuf,
    /// The session has a row: its conversation can be restored.
    pub live: bool,
    /// The manager the session is a worker of: told once the revert is done.
    #[serde(default)]
    pub manager: Option<String>,
    pub level: RestoreLevel,
    pub needs_message: bool,
    pub blocked: bool,
    /// The step's checkpoint, and the tree the files were when previewed.
    pub checkpoint: String,
    pub now: String,
    /// The session's newest step when previewed, the step's head and when it began.
    pub last_seq: i64,
    pub head: Option<String>,
    pub start: f64,
    /// Paths only the agent changed after the step: written back from the checkpoint.
    pub restore: Vec<PathBuf>,
    /// Paths the user edited too, where the edits do not meet.
    pub merges: Vec<Merge>,
    /// Paths the user edited where the edits meet, with the file's mode now.
    pub overlaps: Vec<(PathBuf, u32)>,
    pub skipped: Vec<(PathBuf, String)>,
}

/// A pending revert's record: the plan and the user's answers, and the conversation before the rewind.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct Saved {
    pub plan: Plan,
    pub mode: RevertMode,
    pub choices: Vec<RevertChoice>,
    pub message: Option<String>,
    pub acp_before: Option<String>,
}

/// The worktrees a revert runs in (one at a time each), and the sessions it runs for with the runners' patches kept
/// meanwhile.  The previews are kept in the project's history (`verdandi`'s `preview` table), not here.
#[derive(Default)]
pub(crate) struct Reverts {
    running: Mutex<HashSet<PathBuf>>,
    returned: Mutex<HashMap<String, Vec<String>>>,
    /// The test hook: the next revert parks after a step.
    #[cfg(test)]
    pub(crate) park: Mutex<Option<Park>>,
}

/// Where the next revert parks (test-only): after step AFTER it says so on REACHED and waits for GO, true to go on,
/// false (or the sender dropped) to end there as a hub that dies does.
#[cfg(test)]
pub(crate) struct Park {
    pub after: RevertStep,
    pub reached: tokio::sync::oneshot::Sender<()>,
    pub go: tokio::sync::oneshot::Receiver<bool>,
}

/// Whether a revert goes on after step AT (test-only): the parked hook's answer, or true.
#[cfg(test)]
async fn goes_on(f: &Front, at: RevertStep) -> bool {
    let park = {
        let mut g = lock(&f.core.history.reverts.park);
        match g.as_ref() {
            Some(p) if p.after == at => g.take(),
            _ => None,
        }
    };
    let Some(p) = park else { return true };
    let _ = p.reached.send(());
    p.go.await.unwrap_or(false)
}

/// A new preview id: 52 random bits, exact as a JSON number in every reader, and unique across the projects' stores.
fn preview_id() -> Result<i64, Error> {
    let n = runstav::proof::nonce().map_err(|e| internal(format!("no preview id: {e}")))?;
    i64::from_str_radix(&n[..13], 16)
        .map(|v| v.max(1))
        .map_err(|e| internal(e.to_string()))
}

/// PLAN kept as a preview in its project's history, under a new id.
async fn keep(f: &Front, plan: &Plan) -> Result<i64, Error> {
    let dirs = f
        .dirs
        .get()
        .ok_or_else(|| internal("the hub has no state folder"))?;
    let (hub, tree) = f.core.history.of_tree(&dirs.hub, &plan.cwd)?;
    let json = serde_json::to_string(plan).map_err(|e| internal(e.to_string()))?;
    let (id, now) = (preview_id()?, crate::clock::wall_secs());
    crate::clock::blocking(move || {
        let mut g = hub.lock();
        let br = g.h.branch(
            &tree.branch_name(),
            verdandi::BranchKind::Worktree,
            tree.base.as_deref(),
        )?;
        g.h.keep_preview(id, br, &json, now)
    })
    .await
    .map_err(|e| internal(e.to_string()))?
    .map_err(|e| internal(e.to_string()))?;
    Ok(id)
}

/// The plan of preview ID, taken from whichever project's history holds it (a preview is applied once).
pub(crate) async fn take(f: &Front, id: i64) -> Option<Plan> {
    let dirs = f.dirs.get()?;
    for hub in f.core.history.all(&dirs.hub) {
        let json = crate::clock::blocking(move || hub.lock().h.take_preview(id))
            .await
            .ok()
            .and_then(Result::ok)
            .flatten();
        if let Some(j) = json {
            return serde_json::from_str(&j)
                .map_err(|e| tracing::warn!(id, "a stored preview cannot be read: {e}"))
                .ok();
        }
    }
    None
}

/// A runner returned job JOB's patch for session SID: true when a revert of the session runs, and then the patch is
/// kept on its job and listed in the revert's `kept_patches`, never applied.  The returned-patch path asks this before
/// it applies anything (a patch after the revert is refused anyway: its files are not at their submit hash).
#[cfg_attr(
    not(test),
    expect(
        dead_code,
        reason = "the hub applies no returned patch yet: the runners' returned-patch path calls it"
    )
)]
pub(crate) fn patch_returned(f: &Front, sid: &str, job: &str) -> bool {
    match lock(&f.core.history.reverts.returned).get_mut(sid) {
        Some(kept) => {
            kept.push(job.to_owned());
            true
        }
        None => false,
    }
}

/// SID's revert runs: the runners' patches for it are kept until it ends ([`Listening::end`]).
struct Listening<'a>(&'a Reverts, String);

impl<'a> Listening<'a> {
    fn new(r: &'a Reverts, sid: &str) -> Listening<'a> {
        lock(&r.returned).entry(sid.to_owned()).or_default();
        Listening(r, sid.to_owned())
    }

    /// The patches kept since the last look.
    fn kept(&self) -> Vec<String> {
        lock(&self.0.returned)
            .get_mut(&self.1)
            .map(std::mem::take)
            .unwrap_or_default()
    }

    /// The revert ends: the patches kept since the last look, and none kept after.
    fn end(self) -> Vec<String> {
        lock(&self.0.returned).remove(&self.1).unwrap_or_default()
    }
}

impl Drop for Listening<'_> {
    fn drop(&mut self) {
        lock(&self.0.returned).remove(&self.1);
    }
}

/// The worktree a revert holds, given back when it ends.
struct Held<'a>(&'a Reverts, PathBuf);

impl Drop for Held<'_> {
    fn drop(&mut self) {
        lock(&self.0.running).remove(&self.1);
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Reverts {
    fn hold(&self, cwd: &Path) -> Option<Held<'_>> {
        lock(&self.running)
            .insert(cwd.to_path_buf())
            .then(|| Held(self, cwd.to_path_buf()))
    }
}

fn refused(reason: &str, why: impl std::fmt::Display) -> Error {
    invalid("preview_id", format!("{reason}: {why}"))
}

/// Only the user reverts an agent's work (the registry refuses other connections; this keeps an agent's own call out
/// too).
fn user_only(c: &Caller) -> Result<(), Error> {
    if c.class == Class::Agent {
        return Err(refused(NOT_REVERTIBLE, "an agent cannot revert"));
    }
    Ok(())
}

/// The step P names: SESSION's SEQ, or the step DECISION was recorded in.
async fn target_of(f: &Front, p: &w::RevertPreviewParams) -> Result<Target, Error> {
    match (&p.session, p.seq, p.decision) {
        (Some(s), Some(seq), None) => Ok(Target {
            sid: s.trim_start_matches("session:").to_owned(),
            seq,
        }),
        (None, None, Some(n)) => {
            let id = format!("decision:{n}");
            let found = f
                .writer
                .db
                .read(move |c| {
                    let Some(e) = urdr::graph::entity::by_id(c, &id)? else {
                        return Ok(None);
                    };
                    let Some(step) = e.data["step"].as_i64() else {
                        return Ok(None);
                    };
                    Ok(
                        c.query_row("select session, seq from step where id = ?1", [step], |r| {
                            Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
                        })
                        .ok(),
                    )
                })
                .await
                .map_err(|e| internal(format!("the decision's step: {e}")))?;
            let (s, seq) =
                found.ok_or_else(|| invalid("decision", format!("decision {n} names no step")))?;
            Ok(Target {
                sid: s.trim_start_matches("session:").to_owned(),
                seq,
            })
        }
        _ => Err(invalid(
            "session",
            "name a session and a step, or a decision",
        )),
    }
}

/// The plan for reverting to T, from the session's steps and checkpoints and the files now.
async fn plan_for(f: &Front, t: &Target) -> Result<(Plan, Vec<w::RevertOverlap>), Error> {
    let (profile, cwd, _) = rewind::source_of(&f.core.agents, f, &t.sid).await?;
    let row = session::read_rows(&f.core.agents, Some(&t.sid))
        .await
        .into_iter()
        .next();
    let (live, manager) = (row.is_some(), row.and_then(|r| r.8));
    let key = format!("session:{}", t.sid);
    let steps = f
        .writer
        .db
        .read(move |c| norn::read::steps::for_session(c, &key, 0))
        .await
        .map_err(|e| internal(format!("the session's steps: {e}")))?;
    let step = steps
        .iter()
        .find(|s| s.seq == t.seq)
        .ok_or_else(|| invalid("seq", format!("session {} has no step {}", t.sid, t.seq)))?
        .clone();
    let last_seq = steps.last().map_or(t.seq, |s| s.seq);
    let newest = steps.iter().rev().find_map(|s| s.snapshot.clone());
    let root = f
        .dirs
        .get()
        .map(|d| d.hub.join("checkpoints"))
        .ok_or_else(|| internal("the hub has no state folder"))?;
    let caps = f
        .core
        .agents
        .find(&t.sid)
        .ok()
        .and_then(|s| s.capabilities().cloned());
    let provider = session::find_profile(f, &profile).and_then(|p| p.provider());
    let level = rewind::planned_level(provider, caps.as_ref());
    let (sid, seq) = (t.sid.clone(), t.seq);
    let (mut plan, cards) = crate::clock::blocking(move || {
        classify(root, cwd, sid, seq, live, level, step, last_seq, newest)
    })
    .await
    .map_err(|e| internal(e.to_string()))??;
    plan.manager = manager;
    Ok((plan, cards))
}

/// The plan's paths: every path the checkpoint and the files now differ in, each the agent's alone (restored), the
/// user's too and mergeable (merged), or the user's where the edits meet (an overlap).
#[allow(clippy::too_many_arguments)]
fn classify(
    root: PathBuf,
    cwd: PathBuf,
    sid: String,
    seq: i64,
    live: bool,
    level: RestoreLevel,
    step: norn::read::steps::Step,
    last_seq: i64,
    newest: Option<String>,
) -> Result<(Plan, Vec<w::RevertOverlap>), Error> {
    let checkpoint = step
        .snapshot
        .clone()
        .or_else(|| snapshot::tree_at(&root, &cwd, &sid, seq))
        .ok_or_else(|| {
            refused(
                NOT_REVERTIBLE,
                format!("step {seq} is older than the history: it has no checkpoint"),
            )
        })?;
    let agent_last = newest.or_else(|| snapshot::tree_at(&root, &cwd, &sid, i64::MAX));
    let now = snapshot::tree_now(&root, &cwd, &cwd, &[])
        .map_err(|e| refused(NOT_REVERTIBLE, format!("the tree cannot be read: {e}")))?;
    let changes = snapshot::changed(&root, &cwd, &now, &checkpoint).map_err(internal)?;
    let users: BTreeSet<PathBuf> = match &agent_last {
        Some(al) => snapshot::changed(&root, &cwd, al, &now)
            .map_err(internal)?
            .into_iter()
            .map(|c| c.path)
            .collect(),
        None => BTreeSet::new(),
    };
    let text = |tree: Option<&str>, p: &str| {
        tree.and_then(|t| snapshot::blob(&root, &cwd, t, p).ok())
            .and_then(|b| String::from_utf8(b).ok())
    };
    let regular = |m: u32| m == 0o100644 || m == 0o100755;
    let mut plan = Plan {
        sid,
        seq,
        cwd: cwd.clone(),
        root: root.clone(),
        live,
        manager: None,
        level,
        needs_message: live && level == RestoreLevel::Summary,
        blocked: false,
        checkpoint: checkpoint.clone(),
        now: now.clone(),
        last_seq,
        head: step.head.clone(),
        start: step.start,
        restore: Vec::new(),
        merges: Vec::new(),
        overlaps: Vec::new(),
        skipped: Vec::new(),
    };
    let mut cards = Vec::new();
    for c in changes {
        let p = c.path.to_string_lossy().into_owned();
        if !super::tree::restorable(&c.path, &[]) {
            plan.skipped.push((c.path, "protected".into()));
            continue;
        }
        if c.from_mode == 0o160000 || c.to_mode == 0o160000 {
            plan.skipped.push((c.path, "gitlink".into()));
            continue;
        }
        if !users.contains(&c.path) {
            plan.restore.push(c.path);
            continue;
        }
        // changed after the agent's last step: the user's
        let ours = text(Some(&now), &p);
        let theirs = text(Some(&checkpoint), &p);
        if regular(c.from_mode)
            && regular(c.to_mode)
            && let (Some(base), Some(o), Some(t)) =
                (text(agent_last.as_deref(), &p), &ours, &theirs)
            && let Ok((true, merged)) = verdandi::merge3(&base, o, t)
        {
            plan.merges.push(Merge {
                path: c.path,
                text: merged,
                mode: c.from_mode & 0o777,
            });
            continue;
        }
        cards.push(w::RevertOverlap {
            path: p,
            users: ours,
            reverted: theirs,
        });
        plan.overlaps.push((c.path, c.from_mode & 0o777));
    }
    Ok((plan, cards))
}

/// The other sessions' commits that rest on SID's decisions after its step and are merged already.
async fn blocked_of(f: &Front, t: &Target) -> Result<Vec<w::Blocked>, Error> {
    let (sid, seq) = (t.sid.clone(), t.seq);
    let after = f
        .writer
        .db
        .read(move |c| crate::work::conclusions::after(c, &sid, seq))
        .await
        .map_err(|e| internal(format!("the conclusions after the step: {e}")))?;
    let mut out = Vec::new();
    for c in after {
        if let crate::work::conclusions::Concluded::Decision(n) = c {
            let deps = crate::runner::effects::dependents(f, n).await?;
            out.extend(crate::timeline::effects::blocked(f, &deps, &t.sid).await?);
        }
    }
    Ok(out)
}

/// `history/revert/preview`: the card.  Changes nothing but the previews kept.
pub async fn preview(
    f: &Front,
    c: &Caller,
    p: w::RevertPreviewParams,
) -> Result<w::RevertCard, Error> {
    user_only(c)?;
    let t = target_of(f, &p).await?;
    let (mut plan, overlaps) = plan_for(f, &t).await?;
    let effects = crate::timeline::effects::of(f, &t).await?;
    let blocked = blocked_of(f, &t).await?;
    plan.blocked = !blocked.is_empty();
    let conversation = if plan.live {
        w::ConversationRestore::Restored
    } else {
        w::ConversationRestore::NotRestored {
            label: FINISHED.into(),
        }
    };
    let card = w::RevertCard {
        preview_id: 0,
        session: t.sid.clone(),
        seq: t.seq,
        files: plan
            .restore
            .iter()
            .chain(plan.merges.iter().map(|m| &m.path))
            .chain(plan.overlaps.iter().map(|(p, _)| p))
            .map(|p| p.to_string_lossy().into_owned())
            .collect(),
        overlaps,
        non_overlapping_files: plan
            .merges
            .iter()
            .map(|m| m.path.to_string_lossy().into_owned())
            .collect(),
        effects,
        level: plan.level,
        needs_message: plan.needs_message,
        fork: !plan.live || !blocked.is_empty(),
        blocked,
        skipped: skipped_of(&plan.skipped),
        conversation,
    };
    let id = keep(f, &plan).await?;
    Ok(w::RevertCard {
        preview_id: id,
        ..card
    })
}

fn skipped_of(v: &[(PathBuf, String)]) -> Vec<w::RevertSkipped> {
    v.iter()
        .map(|(p, r)| w::RevertSkipped {
            path: p.to_string_lossy().into_owned(),
            reason: r.clone(),
        })
        .collect()
}

/// `history/revert/apply`.
pub async fn apply(f: &Front, c: &Caller, p: w::RevertApplyParams) -> Result<w::Applied, Error> {
    user_only(c)?;
    let reverts = &f.core.history.reverts;
    let plan = take(f, p.preview_id).await.ok_or_else(|| {
        refused(
            STALE,
            format!("no preview {}: preview the revert again", p.preview_id),
        )
    })?;
    if plan.blocked {
        return Err(refused(
            BLOCKED,
            "another session's merged work rests on it: fork from the step instead",
        ));
    }
    if plan.needs_message && p.message.is_none() {
        return Err(invalid(
            "message",
            format!(
                "{}: the conversation is restored by a summary, which goes with a message of yours",
                rewind::NEEDS_MESSAGE
            ),
        ));
    }
    let Some(_held) = reverts.hold(&plan.cwd) else {
        return Err(refused("busy", "a revert of this tree runs"));
    };
    let acp_before = session::read_rows(&f.core.agents, Some(&plan.sid))
        .await
        .into_iter()
        .next()
        .map(|r| r.7);
    let saved = Saved {
        plan,
        mode: p.mode.unwrap_or(RevertMode::KeepMine),
        choices: p.choices,
        message: p.message,
        acp_before,
    };
    run(f, saved, None).await
}

/// The paths S writes or removes, in a fixed order (the commit's, the broadcast's, the pending record's).
fn targets(s: &Saved) -> Vec<PathBuf> {
    let p = &s.plan;
    let mut v: Vec<PathBuf> = p.restore.clone();
    v.extend(p.merges.iter().map(|m| m.path.clone()));
    for (i, (path, _)) in p.overlaps.iter().enumerate() {
        let take = s.mode == RevertMode::RollBackMine
            || matches!(
                s.choices.get(i),
                Some(RevertChoice::TakeReverted | RevertChoice::Edited { .. })
            );
        if take {
            v.push(path.clone());
        }
    }
    v
}

/// The paths a write wrote, and those it left with the reason.
type Wrote = (Vec<PathBuf>, Vec<(PathBuf, String)>);

/// The files written by S's mode and choices, by content (a second run writes the same): the written paths and the
/// skipped ones.
fn write_files(s: &Saved) -> Result<Wrote, String> {
    use std::os::fd::AsFd;
    let p = &s.plan;
    let mut skipped = p.skipped.clone();
    let mut written = Vec::new();
    let mut take = p.restore.clone();
    if s.mode == RevertMode::RollBackMine {
        take.extend(p.merges.iter().map(|m| m.path.clone()));
        take.extend(p.overlaps.iter().map(|(path, _)| path.clone()));
    } else {
        let dir = std::fs::File::open(&p.cwd).map_err(|e| format!("{}: {e}", p.cwd.display()))?;
        let mut puts: Vec<(&Path, &[u8], u32)> = p
            .merges
            .iter()
            .map(|m| (m.path.as_path(), m.text.as_bytes(), m.mode))
            .collect();
        for (i, (path, mode)) in p.overlaps.iter().enumerate() {
            match s.choices.get(i) {
                Some(RevertChoice::TakeReverted) => take.push(path.clone()),
                Some(RevertChoice::Edited { text }) => {
                    puts.push((
                        path,
                        text.as_bytes(),
                        if *mode == 0 { 0o644 } else { *mode },
                    ));
                }
                Some(RevertChoice::KeepUsers) | None => {
                    skipped.push((path.clone(), "edited-later".into()));
                }
            }
        }
        for (path, bytes, mode) in puts {
            match eitri::write_regular(dir.as_fd(), path, bytes, mode) {
                Ok(()) => written.push(path.to_path_buf()),
                Err(e) => skipped.push((path.to_path_buf(), e.to_string())),
            }
        }
    }
    let r = snapshot::restore_into(&p.root, &p.cwd, &p.cwd, &p.checkpoint, Some(&take), &[])?;
    written.extend(r.written);
    skipped.extend(r.skipped);
    Ok((written, skipped))
}

/// The revert's history record (`revert`, its parents the records the session caused after the step, or one record
/// standing for those steps when the history has none), its pending record, and the files as they were kept under
/// `refs/drgnx/undone/<op>`.
async fn record(f: &Front, s: &Saved) -> Result<i64, String> {
    let dirs = f.dirs.get().ok_or("the hub has no state folder")?;
    let (hub, _) = f
        .core
        .history
        .of_tree(&dirs.hub, &s.plan.cwd)
        .map_err(|e| e.message)?;
    let json = serde_json::to_string(s).map_err(|e| e.to_string())?;
    let (p, now) = (s.plan.clone(), crate::clock::wall_secs());
    crate::clock::blocking(move || {
        use verdandi::{Cause, Kind, Record};
        let mut g = hub.lock();
        let h = &mut g.h;
        let e = |e: verdandi::Error| e.to_string();
        let author = h.peer(&json!({"kind": "user"}), None).map_err(e)?;
        let cause = |step: i64| Cause {
            session: Some(p.sid.clone()),
            step: Some(step.to_string()),
            ..Cause::default()
        };
        let mut parents = h.caused_by(&p.sid, p.start).map_err(e)?;
        if parents.is_empty() {
            parents.push(
                h.record(Record {
                    kind: Kind::AgentStep,
                    author,
                    cause: cause(p.seq + 1),
                    spans: Vec::new(),
                    parents: Vec::new(),
                    git: None,
                    summary: format!(
                        "steps {}-{} of session {}, as their checkpoints hold them",
                        p.seq + 1,
                        p.last_seq,
                        p.sid
                    ),
                    at: now,
                })
                .map_err(e)?,
            );
        }
        let op = h
            .record(Record {
                kind: Kind::Revert,
                author,
                cause: cause(p.seq),
                spans: Vec::new(),
                parents,
                git: None,
                summary: format!("revert to step {} of session {}", p.seq, p.sid),
                at: now,
            })
            .map_err(e)?;
        snapshot::keep(
            &p.root,
            &p.cwd,
            &format!("refs/drgnx/undone/{}", op.0),
            &p.now,
        )?;
        h.mark_pending(op, &json, now).map_err(e)?;
        Ok(op.0)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// What the revert writes at a path.
enum Goes {
    /// The checkpoint's version (or nothing, where the checkpoint has none).
    Checkpoint,
    /// This text: a merge with the user's later edit, or the user's edited answer.
    Text(String),
    /// Nothing: the user's file stays.
    Stays,
}

/// What S writes at PATH, by its mode and the user's answers.
fn goes(s: &Saved, path: &Path) -> Goes {
    let p = &s.plan;
    if s.mode == RevertMode::RollBackMine || p.restore.iter().any(|r| r == path) {
        return Goes::Checkpoint;
    }
    if let Some(m) = p.merges.iter().find(|m| m.path == path) {
        return Goes::Text(m.text.clone());
    }
    match p.overlaps.iter().position(|(o, _)| o == path) {
        Some(i) => match s.choices.get(i) {
            Some(RevertChoice::TakeReverted) => Goes::Checkpoint,
            Some(RevertChoice::Edited { text }) => Goes::Text(text.clone()),
            Some(RevertChoice::KeepUsers) | None => Goes::Stays,
        },
        None => Goes::Stays,
    }
}

/// The paths the revert writes, told to the tree's origin core as the hub's own versions first (the checkpoint's
/// blob or gone, or the blob of the merged or edited text, hashed as the watcher hashes what it reads), so the
/// watcher's event about them is no outside edit.
async fn expect(f: &Front, s: &Saved, path: &Path) {
    let Some(dirs) = f.dirs.get() else { return };
    let Ok((hub, tree)) = f.core.history.of_tree(&dirs.hub, &s.plan.cwd) else {
        return;
    };
    let what = goes(s, path);
    if matches!(what, Goes::Stays) {
        return;
    }
    let (p, rel) = (s.plan.clone(), path.to_string_lossy().into_owned());
    let _ = crate::clock::blocking(move || {
        let hash = match what {
            Goes::Text(t) => {
                match super::blob::hash_object(&tree.git_dir, &tree.root, &rel, t.as_bytes()) {
                    Ok(h) => h,
                    Err(e) => {
                        tracing::warn!(rel, "the revert's text is not announced: {e}");
                        return;
                    }
                }
            }
            _ => snapshot::blob_id(&p.root, &p.cwd, &p.checkpoint, &rel)
                .unwrap_or_else(|| "gone".into()),
        };
        hub.lock()
            .origin
            .step(super::origin::OriginEv::HubWrite { path: rel, hash });
    })
    .await;
}

/// The steps after the target marked undone by OP, and the session's conclusions after it withdrawn.
async fn graph(f: &Front, p: &Plan, op: i64) -> Result<(), String> {
    let (sid, seq) = (p.sid.clone(), p.seq);
    let after = f
        .writer
        .db
        .read(move |c| crate::work::conclusions::after(c, &sid, seq))
        .await
        .map_err(|e| e.to_string())?;
    let (key, seq, now) = (
        format!("session:{}", p.sid),
        p.seq,
        crate::clock::wall_secs(),
    );
    let why = format!("reverted: step {seq} of {key} went back");
    f.writer
        .write(
            &crate::work::asks::hub(),
            "history/revert/apply",
            move |tx| {
                norn::write::steps::mark_undone(tx, &key, seq, op)?;
                for c in &after {
                    match c {
                        crate::work::conclusions::Concluded::Decision(n) => {
                            norn::write::decisions::withdraw(tx, *n, &why, "revert", now)?;
                        }
                        crate::work::conclusions::Concluded::Finding(id) => {
                            norn::write::notes::withdraw(tx, id, &why, "revert", now)?;
                        }
                    }
                }
                Ok(())
            },
        )
        .await
        .map_err(|e| e.to_string())
}

/// The session's jobs stopped: every one it runs or queued here or on a runner.
async fn stop_jobs(f: &Front, sid: &str) {
    for row in f.core.exec.list(Some(sid), true) {
        if let Err(e) = f.core.exec.stop(&row.id).await {
            tracing::warn!(
                sid,
                job = row.id,
                "a job is not stopped for the revert: {}",
                e.message
            );
        }
    }
}

/// S done step by step as the core says, from the start (OP none) or, after a crash, from the pending record OP.
async fn run(f: &Front, s: Saved, op: Option<i64>) -> Result<w::Applied, Error> {
    use RevertEffect as E;
    use RevertEvent as V;
    use RevertStep as S;
    let p = s.plan.clone();
    let paths = targets(&s);
    let pending = Pending {
        op: op.unwrap_or(0),
        sid: p.sid.clone(),
        seq: p.seq,
        level: p.level,
        message: s.message.clone(),
        paths: paths.clone(),
        acp_before: s.acp_before.clone(),
        live: p.live,
    };
    let mut core = RevertCore::new();
    let first = match op {
        Some(_) => V::Resume(pending),
        None => V::Begin(pending),
    };
    let mut q: VecDeque<RevertEffect> = core.step(first).into();
    let mut out = w::Applied {
        op: op.unwrap_or(0),
        session: p.sid.clone(),
        level: None,
        commit: None,
        skipped: Vec::new(),
        conversation: w::ConversationRestore::Restored,
        kept_patches: Vec::new(),
        undone: String::new(),
    };
    let mut why = String::new();
    let mut rewound = false;
    let target = Target {
        sid: p.sid.clone(),
        seq: p.seq,
    };
    let listen = Listening::new(&f.core.history.reverts, &p.sid);
    loop {
        // a runner's patch that came back meanwhile: the core says what becomes of it
        for id in listen.kept() {
            q.extend(core.step(V::RunnerPatch(id)));
        }
        let Some(e) = q.pop_front() else { break };
        let ev = match e {
            E::Refuse(r) => return Err(refused(r, &why)),
            E::Detach => {
                if let Ok(sess) = f.core.agents.find(&p.sid) {
                    sess.detach();
                    let _ = f.core.agents.cancel_after_tool(&p.sid);
                }
                continue;
            }
            E::StopJobs => {
                stop_jobs(f, &p.sid).await;
                V::Done(S::Quiet)
            }
            E::Rescan => {
                let (root, cwd) = (p.root.clone(), p.cwd.clone());
                let now =
                    crate::clock::blocking(move || snapshot::tree_now(&root, &cwd, &cwd, &[]))
                        .await
                        .map_err(|e| internal(e.to_string()))?;
                let key = format!("session:{}", p.sid);
                let last = f
                    .writer
                    .db
                    .read(move |c| norn::read::steps::for_session(c, &key, 0))
                    .await
                    .map_err(|e| internal(e.to_string()))?
                    .last()
                    .map(|s| s.seq);
                if now.ok().as_ref() == Some(&p.now) && last.unwrap_or(p.last_seq) == p.last_seq {
                    V::Done(S::Rescan)
                } else {
                    why = "the files or the session moved since the preview: preview again".into();
                    V::Failed(S::Rescan)
                }
            }
            E::Record => match record(f, &s).await {
                Ok(o) => {
                    out.op = o;
                    V::Done(S::Record)
                }
                Err(e) => {
                    why = e;
                    V::Failed(S::Record)
                }
            },
            E::ExpectWrite(path) => {
                expect(f, &s, &path).await;
                continue;
            }
            E::WriteFiles => {
                let s2 = s.clone();
                match crate::clock::blocking(move || write_files(&s2))
                    .await
                    .map_err(|e| e.to_string())
                    .and_then(|r| r)
                {
                    Ok((_, skipped)) => {
                        out.skipped = skipped_of(&skipped);
                        V::Done(S::Files)
                    }
                    Err(e) => {
                        tracing::warn!(sid = p.sid, "the revert's files are not written: {e}");
                        why = e;
                        V::Failed(S::Files)
                    }
                }
            }
            E::Graph => match graph(f, &p, out.op).await {
                Ok(()) => V::Done(S::Graph),
                Err(e) => {
                    tracing::warn!(sid = p.sid, "the revert's steps are not marked: {e}");
                    V::Failed(S::Graph)
                }
            },
            E::Rewind => {
                let acp = session::read_rows(&f.core.agents, Some(&p.sid))
                    .await
                    .into_iter()
                    .next()
                    .map(|r| r.7);
                if acp.is_some() && acp != s.acp_before {
                    // rewound before a crash: not again
                    rewound = true;
                    V::Done(S::Conversation)
                } else {
                    match rewind::rewind_conversation(&f.core.agents, f, &target, s.message.clone())
                        .await
                    {
                        Ok(level) => {
                            rewound = true;
                            out.level = Some(level);
                            V::Done(S::Conversation)
                        }
                        Err(e) => {
                            out.conversation = w::ConversationRestore::NotRestored {
                                label: format!("conversation not restored: {}", e.message),
                            };
                            V::Failed(S::Conversation)
                        }
                    }
                }
            }
            E::Reattach => {
                if !rewound && let Ok(sess) = f.core.agents.find(&p.sid) {
                    sess.reattach(None);
                }
                continue;
            }
            E::NotRestored => {
                if out.conversation == w::ConversationRestore::Restored {
                    out.conversation = w::ConversationRestore::NotRestored {
                        label: FINISHED.into(),
                    };
                }
                continue;
            }
            E::Commit => {
                if p.head.is_some() && p.head == snapshot::head_of(&p.cwd) {
                    V::Done(S::Commit)
                } else {
                    let subject = format!("revert to step {} of session {}", p.seq, p.sid);
                    match super::tree::commit_in_sandbox(f, &p.sid, &p.cwd, &paths, &subject).await
                    {
                        Ok(c) => {
                            out.commit = c;
                            V::Done(S::Commit)
                        }
                        Err(e) => {
                            tracing::warn!(sid = p.sid, "the revert's commit failed: {e}");
                            out.skipped.push(w::RevertSkipped {
                                path: String::new(),
                                reason: format!("commit: {e}"),
                            });
                            V::Failed(S::Commit)
                        }
                    }
                }
            }
            E::Clear => match clear(f, &p, out.op).await {
                Ok(()) => V::Done(S::Clear),
                Err(e) => {
                    tracing::warn!(sid = p.sid, "the revert's pending record stays: {e}");
                    V::Failed(S::Clear)
                }
            },
            E::Broadcast => {
                f.broadcast(
                    "history/applied",
                    json!({"op": out.op, "paths": paths, "worktree": p.cwd}),
                );
                continue;
            }
            E::TellManager => {
                tell_manager(f, &p, &out);
                continue;
            }
            E::KeepPatch(id) => {
                out.kept_patches.push(id);
                continue;
            }
        };
        #[cfg(test)]
        if let V::Done(at) = &ev
            && !goes_on(f, *at).await
        {
            return Err(internal(format!("the hub stopped after {at:?}")));
        }
        q.extend(core.step(ev));
    }
    // came back as the revert ended: kept all the same
    out.kept_patches.extend(listen.end());
    out.undone = format!("refs/drgnx/undone/{}", out.op);
    Ok(out)
}

/// The manager P's session is a worker of, told what the user's revert did (a message from the hub, queued behind
/// its turn when it is busy).  A manager that is not running is not told: the revert is in its worker's record.
fn tell_manager(f: &Front, p: &Plan, out: &w::Applied) {
    let Some(m) = &p.manager else { return };
    let conversation = match &out.conversation {
        w::ConversationRestore::Restored => {
            "its conversation went back to that step too".to_owned()
        }
        w::ConversationRestore::NotRestored { label } => label.clone(),
    };
    let text = format!(
        "[drgnx] The user reverted your worker {} to its step {}: its files went back to that step and its \
         decisions and findings after it were withdrawn; {conversation}.{}",
        p.sid,
        p.seq,
        out.commit
            .as_deref()
            .map(|c| format!(" The revert is commit {c}."))
            .unwrap_or_default()
    );
    if let Err(e) = f
        .core
        .agents
        .prompt(m, text, crate::agents::queue::Origin::Hub)
    {
        tracing::info!(
            manager = m,
            sid = p.sid,
            "the manager is not told of the revert: {}",
            e.message
        );
    }
}

/// Record OP's pending record cleared.
async fn clear(f: &Front, p: &Plan, op: i64) -> Result<(), String> {
    let dirs = f.dirs.get().ok_or("the hub has no state folder")?;
    let (hub, _) = f
        .core
        .history
        .of_tree(&dirs.hub, &p.cwd)
        .map_err(|e| e.message)?;
    crate::clock::blocking(move || hub.lock().h.clear_pending(verdandi::OpId(op)).map(drop))
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| e.to_string())
}

/// At start-up, before the sessions resume: every revert a crash left pending finished from its record (the files by
/// content, the steps and conclusions, the conversation unless it was rewound already, a commit only when one is
/// left to make, then the record cleared).
pub(crate) async fn finish_pending(f: &Front) {
    let Some(dirs) = f.dirs.get() else { return };
    for hub in f.core.history.all(&dirs.hub) {
        let h = hub.clone();
        let rows = crate::clock::blocking(move || h.lock().h.pending())
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default();
        for (op, json) in rows {
            let Ok(saved) = serde_json::from_str::<Saved>(&json) else {
                tracing::warn!(op = op.0, "a pending revert's record cannot be read");
                continue;
            };
            let _held = f.core.history.reverts.hold(&saved.plan.cwd);
            match run(f, saved, Some(op.0)).await {
                Ok(a) => tracing::info!(op = a.op, sid = a.session, "a pending revert finished"),
                Err(e) => {
                    tracing::warn!(op = op.0, "a pending revert did not finish: {}", e.message)
                }
            }
        }
    }
}

#[cfg(test)]
mod live;
#[cfg(test)]
mod tests;
