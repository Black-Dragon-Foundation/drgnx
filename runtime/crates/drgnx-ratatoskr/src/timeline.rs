//! The timeline (Task 19; `docs/develop/hub.md`, "The timeline"): every step of every session classified from the
//! hub's stamps (`think`, `tool`, `user-wait`, `job-wait`, `machine-queue`, `paused`, `stalled`), written to the
//! `step` table with its anchors (message id, turn id, decision log version, step snapshot: a tree in the worktree's
//! shadow repository, `refs/drgnx/s/<sid>/<seq>`), the `agent-step` event, and `timeline/get`.
//!
//! The classifier itself is in [`crate::agents::session`] (it sees the updates as they arrive: text between tool
//! calls is `think`, a tool call runs from `in_progress` to `completed`, a permission request is `user-wait` because
//! the hub answers it, a paused session is `paused`); this module reads the table back and takes the snapshots.

pub mod snapshot;

use crate::dispatch::Caller;
use crate::front::Front;
use norn::read::steps as table;
use runstav::methods::matrix::{Limit, Unit};
use runstav::methods::timeline::{
    ClassSecs, Rollup, Scope, Step, StepClass, Timeline as TimelineAnswer, TimelineParams, Tokens,
};
use runstav::wire::{Error, ErrorCode};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// The most steps one `timeline/get` answers.
const PAGE: i64 = 500;

/// The snapshots' shared state: whether they stopped at the cap, and the sessions that finished (oldest first).
#[derive(Default)]
pub struct SnapState {
    stopped: AtomicBool,
    finished: Mutex<Vec<String>>,
}

/// The timeline's state (one per hub).
#[derive(Default)]
pub struct Timeline {
    state: Arc<SnapState>,
}

impl Timeline {
    /// SID's task is done: its snapshots may go when the cap needs room.
    pub fn session_finished(&self, sid: &str) {
        let mut f = self.state.finished.lock().expect("timeline");
        if !f.iter().any(|s| s == sid) {
            f.push(sid.to_string());
        }
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

    /// A tree of WORKTREE after a completed edit (step SEQ of SID); its id.  Over the cap, the oldest finished
    /// sessions' refs go first; with none left, snapshots stop and the editors get one notice.
    pub async fn after_edit(
        &self,
        sid: &str,
        worktree: &Path,
        seq: u64,
        editors: &crate::settings::agents::Editors,
    ) -> Option<String> {
        if self.state.stopped.load(Ordering::Relaxed) {
            return None;
        }
        let (root, wt, sid_) = (self.root.clone(), worktree.to_path_buf(), sid.to_string());
        let tree = tokio::task::spawn_blocking(move || snapshot::take(&root, &wt, &sid_, seq, &[]))
            .await
            .ok()?
            .map_err(|e| tracing::warn!(sid, "snapshot not taken: {e}"))
            .ok()?;
        let cap = self.settings.current().loaded.values.agents_checkpoint_cap;
        let (root, finished) = (
            self.root.clone(),
            self.state.finished.lock().expect("timeline").clone(),
        );
        let pruned = tokio::task::spawn_blocking(move || {
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
    let since = p.since.unwrap_or(0) as i64;
    let rollup_only = p.rollup == Some(true);
    let (steps, roll) = front
        .writer
        .db
        .read(move |c| {
            let steps = if rollup_only {
                Vec::new()
            } else {
                table::for_scope(c, scope, &id, since, PAGE + 1)?
            };
            Ok((steps, table::rollup(c, scope, &id)?))
        })
        .await
        .map_err(internal)?;
    let mut steps: Vec<Step> = steps.into_iter().map(step_of).collect();
    let next = if steps.len() as i64 > PAGE {
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
