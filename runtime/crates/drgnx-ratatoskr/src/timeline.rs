//! The timeline (Task 19; `docs/develop/hub.md`, "The timeline"): every step of every session classified from the
//! hub's stamps (`think`, `tool`, `user-wait`, `job-wait`, `machine-queue`, `paused`, `stalled`), written to the
//! `step` table with its anchors (message id, turn id, decision log version, step snapshot: a tree in the worktree's
//! shadow repository, `refs/drgnx/s/<sid>/<seq>`), the `agent-step` event, and `timeline/get`.
//!
//! The classifier itself is in [`crate::agents::session`] (it sees the updates as they arrive: text between tool
//! calls is `think`, a tool call runs from `in_progress` to `completed`, a permission request is `user-wait` because
//! the hub answers it, a paused session is `paused`); this module reads the table back and takes the snapshots.

pub mod effects;
pub mod snapshot;

use crate::dispatch::Caller;
use crate::front::Front;
use norn::read::steps as table;
use runstav::methods::matrix::{Limit, Unit};
use runstav::methods::timeline::{
    ClassSecs, Rollup, Scope, Step, StepClass, Timeline as TimelineAnswer, TimelineParams, Tokens,
};
use runstav::wire::{Error, ErrorCode};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// The most steps one `timeline/get` answers.
const PAGE: i64 = 500;

/// The snapshots' shared state: whether they stopped at the cap, the sessions that finished (oldest first), and the
/// sessions whose snapshots the cap removed in this hub's run.
#[derive(Default)]
pub struct SnapState {
    stopped: AtomicBool,
    finished: Mutex<Vec<String>>,
    pruned: Mutex<BTreeSet<String>>,
}

impl SnapState {
    /// GONE's snapshots were removed at the cap.
    fn pruned(&self, gone: &[String]) {
        self.pruned
            .lock()
            .expect("timeline")
            .extend(gone.iter().cloned());
    }

    fn is_pruned(&self, sid: &str) -> bool {
        self.pruned.lock().expect("timeline").contains(sid)
    }
}

/// The timeline's state (one per hub).
#[derive(Default)]
pub struct Timeline {
    state: Arc<SnapState>,
}

impl Timeline {
    /// Step row S as the wire has it: `revertible` while it has an edit history record and its session's
    /// checkpoints are kept.
    pub(crate) fn wire(&self, s: table::Step) -> Step {
        let mut w = step_of(s);
        w.revertible &= !self.state.is_pruned(&w.session);
        w
    }

    /// SID's task is done: its snapshots may go when the cap needs room.
    pub fn session_finished(&self, sid: &str) {
        let mut f = self.state.finished.lock().expect("timeline");
        if !f.iter().any(|s| s == sid) {
            f.push(sid.to_string());
        }
    }
}

/// An edit step's checkpoint, taken once: by the step writer when it writes the step's anchors, or by the session
/// before it serves the agent's next write, whichever comes first ([`Snap::before_write`]).  The writer holds it while
/// it takes its own, so no write is served meanwhile.
#[derive(Clone, Debug, Default)]
pub(crate) struct EditCell(Arc<tokio::sync::Mutex<Mark>>);

#[derive(Debug, Default)]
enum Mark {
    /// Nobody took it yet.
    #[default]
    Open,
    /// The tree before a later write (held by its ref until the writer keeps it).
    Before(String),
    /// The writer is done with it.
    Done,
}

impl EditCell {
    /// The writer is done with it: nothing more to take.
    pub(crate) fn is_done(&self) -> bool {
        self.0.try_lock().is_ok_and(|m| matches!(*m, Mark::Done))
    }
}

/// What a session needs to take its snapshots: the shadow repositories' folder, the cap (read at every use, so a
/// change applies at once) and the shared state.
#[derive(Clone)]
pub struct Snap {
    root: PathBuf,
    state: Arc<SnapState>,
    settings: Arc<crate::settings::Settings>,
}

impl Snap {
    /// None until the store's folders are known (a front without a state folder takes no snapshots).
    pub fn of(front: &Front) -> Option<Snap> {
        let dirs = front.dirs.get()?;
        Some(Snap {
            root: dirs.hub.join("checkpoints"),
            state: front.core.timeline.state.clone(),
            settings: front.settings.clone(),
        })
    }

    #[cfg(test)]
    pub(crate) fn for_test(root: PathBuf, settings: Arc<crate::settings::Settings>) -> Snap {
        Snap {
            root,
            state: Arc::default(),
            settings,
        }
    }

    /// A tree of WORKTREE as it is before SID's turn reaches its agent: the checkpoint of the turn's first step, which
    /// [`Snap::after_edit`] keeps once that step is written.  Taken before the prompt goes, so nothing the agent does
    /// in the turn is in it.
    pub async fn before_turn(&self, sid: &str, worktree: &Path) -> Option<String> {
        if self.state.stopped.load(Ordering::Relaxed) {
            return None;
        }
        let (root, wt, sid_) = (self.root.clone(), worktree.to_path_buf(), sid.to_string());
        crate::clock::blocking(move || snapshot::turn_tree(&root, &wt, &sid_))
            .await
            .ok()?
            .map_err(|e| tracing::warn!(sid, "turn snapshot not taken: {e}"))
            .ok()
    }

    /// The tree of WORKTREE before SID's agent's next write is served, kept in CELLS (edit steps closed before the write
    /// whose checkpoints nobody took yet): one tree for all of them, taken only when one is still open.  A cell the
    /// writer holds is waited for, since the writer takes the tree then.
    pub(crate) async fn before_write(&self, sid: &str, worktree: &Path, cells: Vec<EditCell>) {
        if self.state.stopped.load(Ordering::Relaxed) {
            return;
        }
        let mut tree: Option<String> = None;
        for c in cells {
            let mut m = c.0.lock().await;
            if !matches!(*m, Mark::Open) {
                continue;
            }
            if tree.is_none() {
                let (root, wt, sid_) = (self.root.clone(), worktree.to_path_buf(), sid.to_string());
                match crate::clock::blocking(move || snapshot::write_tree_before(&root, &wt, &sid_))
                    .await
                {
                    Ok(Ok(t)) => tree = Some(t),
                    Ok(Err(e)) => {
                        tracing::warn!(sid, "the tree before a write is not taken: {e}");
                        return;
                    }
                    Err(_) => return,
                }
            }
            *m = Mark::Before(tree.clone().unwrap_or_default());
        }
    }

    /// A tree of WORKTREE after a completed edit (step SEQ of SID), or TURN (the [`Snap::before_turn`] tree of the
    /// turn's first step) kept as that step's; its id.  An edit step's CELL gives the tree taken before the agent's next
    /// write when there is one ([`Snap::before_write`]), else the tree is taken now, with the cell held so no write is
    /// served meanwhile.  Over the cap, the oldest finished sessions' refs go first; with none left, snapshots stop and
    /// the editors get one notice.
    pub(crate) async fn after_edit(
        &self,
        sid: &str,
        worktree: &Path,
        seq: u64,
        (turn, cell): (Option<&str>, Option<&EditCell>),
        editors: &crate::settings::agents::Editors,
    ) -> Option<String> {
        let mut held = match cell {
            Some(c) => Some(c.0.lock().await),
            None => None,
        };
        let before = match held
            .as_deref_mut()
            .map(|m| std::mem::replace(m, Mark::Done))
        {
            Some(Mark::Before(t)) => Some(t),
            _ => None,
        };
        if self.state.stopped.load(Ordering::Relaxed) {
            return None;
        }
        let (root, wt, sid_, turn) = (
            self.root.clone(),
            worktree.to_path_buf(),
            sid.to_string(),
            turn.map(str::to_string),
        );
        let tree = crate::clock::blocking(move || match (before, turn) {
            (Some(t), _) => snapshot::put_write_tree(&root, &wt, &sid_, seq, &t).map(|()| t),
            (None, Some(t)) => snapshot::put_turn_tree(&root, &wt, &sid_, seq, &t).map(|()| t),
            (None, None) => snapshot::take(&root, &wt, &sid_, seq, &[]),
        })
        .await
        .ok()?
        .map_err(|e| tracing::warn!(sid, "snapshot not taken: {e}"))
        .ok()?;
        drop(held);
        let cap = self.settings.current().loaded.values.agents_checkpoint_cap;
        let (root, finished) = (
            self.root.clone(),
            self.state.finished.lock().expect("timeline").clone(),
        );
        let pruned = crate::clock::blocking(move || {
            let repos: Vec<PathBuf> = std::fs::read_dir(&root)
                .into_iter()
                .flatten()
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.extension().is_some_and(|x| x == "git"))
                .collect();
            snapshot::prune(&repos, cap, &finished)
        })
        .await
        .ok()?;
        if let snapshot::Pruned::Freed(gone) = &pruned {
            self.state.pruned(gone);
        }
        if pruned == snapshot::Pruned::Stop {
            self.state.stopped.store(true, Ordering::Relaxed);
            editors.broadcast(
                "notice",
                serde_json::json!({
                    "source": "agents", "severity": "warning", "id": "agents-checkpoint-cap",
                    "life": "session",
                    "text": "Step snapshots stopped: the checkpoint cap is reached and no task has finished. \
                             Raise drgnx-agents-checkpoint-cap or finish a task.",
                }),
            );
        }
        Some(tree)
    }
}

fn internal(e: impl std::fmt::Display) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: format!("timeline/get: {e}"),
        path: None,
    }
}

fn unit_of(name: &str) -> Option<Unit> {
    serde_json::from_value(serde_json::json!(name)).ok()
}

fn class_of(c: norn::write::steps::StepClass) -> StepClass {
    serde_json::from_value(serde_json::json!(c.as_str())).unwrap_or(StepClass::Think)
}

/// Step row S as the wire has it, without the checkpoints' state: [`Timeline::wire`] adds it.
fn step_of(s: table::Step) -> Step {
    let plain = |v: String, p: &str| v.strip_prefix(p).map(str::to_string).unwrap_or(v);
    Step {
        id: s.id,
        session: plain(s.session, "session:"),
        task: s.task,
        plan: s.plan,
        project: s.project,
        agent: s.agent.map(|a| plain(a, "agent:")),
        provider: s.provider,
        seq: s.seq as u64,
        class: class_of(s.class),
        start: s.start,
        end: s.end,
        tool: s.tool,
        tool_kind: s.tool_kind,
        message_id: s.message_id,
        turn_id: s.turn_id,
        snapshot: s.snapshot,
        log_version: s.log_version.map(|v| v as u64),
        tokens_in: Some(s.tokens_in as u64),
        tokens_out: Some(s.tokens_out as u64),
        cache_read: Some(s.cache_read as u64),
        cache_write: Some(s.cache_write as u64),
        cost: s.cost,
        cost_unit: s.cost_unit.as_deref().and_then(unit_of),
        detail: None,
        acp: s.acp,
        head: s.head,
        revertible: s.history_op.is_some(),
        history_op: s.history_op.map(|v| v as u64),
        undone_by: s.undone_by.map(|v| v as u64),
    }
}

fn rollup_of(r: table::Rollup) -> Rollup {
    Rollup {
        secs: r
            .secs_by_class
            .into_iter()
            .filter_map(|(c, secs)| {
                let class = serde_json::from_value(serde_json::json!(c)).ok()?;
                Some(ClassSecs { class, secs })
            })
            .collect(),
        cost: r
            .cost_by_unit
            .into_iter()
            .filter_map(|(u, amount)| {
                Some(Limit {
                    amount,
                    unit: unit_of(&u)?,
                })
            })
            .collect(),
        tokens: Tokens {
            tokens_in: r.tokens.input as u64,
            out: r.tokens.output as u64,
            cache_read: r.tokens.cache_read as u64,
            cache_write: r.tokens.cache_write as u64,
        },
    }
}

/// `timeline/get`: the steps of a scope after `since` (500 a page; `next` continues), and their rollup.
pub async fn get(front: &Front, _: &Caller, p: TimelineParams) -> Result<TimelineAnswer, Error> {
    let scope = match p.scope {
        Scope::Session => table::Scope::Session,
        Scope::Task => table::Scope::Task,
        Scope::Plan => table::Scope::Plan,
        Scope::Project => table::Scope::Project,
    };
    let id = p.id.as_str().to_string();
    let id = match scope {
        table::Scope::Session if !id.starts_with("session:") => format!("session:{id}"),
        _ => id,
    };
    // a session says it is idle before the row of the step that ended its turn is written: the steps it closed are
    // rows before they are read (a scope wider than a session waits for every session the hub holds)
    let sessions = match (scope, id.strip_prefix("session:")) {
        (table::Scope::Session, Some(sid)) => front.core.agents.find(sid).into_iter().collect(),
        _ => front.core.agents.live_sessions(),
    };
    for s in sessions {
        s.steps_written().await;
    }
    let since = p.since.unwrap_or(0) as i64;
    let rollup_only = p.rollup == Some(true);
    // backwards paging: `limit` and/or `before` (the newest `limit` steps before it, newest last)
    let back = if p.limit.is_some() || p.before.is_some() {
        let limit = i64::from(p.limit.unwrap_or(PAGE as u32));
        if !(1..=PAGE).contains(&limit) {
            return Err(crate::runner::invalid(format!(
                "limit is 1 to {PAGE}, not {limit}"
            )));
        }
        Some((
            p.before.map_or(i64::MAX, |b| b.min(i64::MAX as u64) as i64),
            limit,
        ))
    } else {
        None
    };
    let (steps, details, roll) = front
        .writer
        .db
        .read(move |c| {
            let steps = if rollup_only {
                Vec::new()
            } else if let Some((before, limit)) = back {
                table::before_scope(c, scope, &id, before, limit)?
            } else {
                table::for_scope(c, scope, &id, since, PAGE + 1)?
            };
            let mut details = Vec::with_capacity(steps.len());
            for s in &steps {
                details.push(norn::read::work::step_detail(c, s.id)?);
            }
            Ok((steps, details, table::rollup(c, scope, &id)?))
        })
        .await
        .map_err(internal)?;
    let mut steps: Vec<Step> = steps
        .into_iter()
        .zip(details)
        .map(|(s, d)| Step {
            detail: d.as_ref().map(crate::work::detail::wire),
            ..front.core.timeline.wire(s)
        })
        .collect();
    let next = if back.is_some() {
        None
    } else if steps.len() as i64 > PAGE {
        steps.truncate(PAGE as usize);
        steps.last().map(|s| match p.scope {
            Scope::Session => s.seq,
            _ => s.id as u64,
        })
    } else {
        None
    };
    Ok(TimelineAnswer {
        steps,
        rollup: Some(rollup_of(roll)),
        next,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";

    fn row(history_op: Option<i64>) -> table::Step {
        table::Step {
            id: 7,
            session: "session:a1".into(),
            task: None,
            plan: None,
            project: None,
            agent: Some("agent:mock".into()),
            provider: None,
            seq: 3,
            class: norn::write::steps::StepClass::Tool,
            start: 1.0,
            end: Some(2.0),
            tool: None,
            tool_kind: Some("edit".into()),
            message_id: Some("m1".into()),
            turn_id: None,
            snapshot: Some("tree".into()),
            log_version: Some(4),
            tokens_in: 0,
            tokens_out: 0,
            cache_read: 0,
            cache_write: 0,
            cost: None,
            cost_unit: None,
            acp: Some("acp-2".into()),
            head: Some(HEAD.into()),
            history_op,
            undone_by: Some(9),
        }
    }

    /// Pattern D: a row's conversation, head, history record and revert mark reach the wire; a step with a history
    /// record is revertible until its session's checkpoints are pruned, and one without never is.
    #[test]
    fn step_carries_acp_head_and_revertible() {
        let t = Timeline::default();
        let w = t.wire(row(Some(5)));
        assert_eq!(
            (
                w.acp.as_deref(),
                w.head.as_deref(),
                w.history_op,
                w.undone_by,
                w.revertible
            ),
            (Some("acp-2"), Some(HEAD), Some(5), Some(9), true)
        );
        let j = serde_json::to_value(&w).unwrap();
        assert_eq!(
            (&j["acp"], &j["head"], &j["revertible"]),
            (
                &serde_json::json!("acp-2"),
                &serde_json::json!(HEAD),
                &serde_json::json!(true)
            )
        );
        // a step from before the history began
        let old = t.wire(row(None));
        assert!(!old.revertible);
        assert!(
            serde_json::to_value(&old)
                .unwrap()
                .get("history_op")
                .is_none()
        );
        // the session's checkpoints were pruned at the cap
        t.state.pruned(&["a1".to_string()]);
        assert!(!t.wire(row(Some(5))).revertible);
    }
}
