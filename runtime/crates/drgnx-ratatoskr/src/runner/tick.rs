//! The plan runner's 2 s step and starting a task's worker (`drgnx-job-step`, `drgnx-job--start-task`; the Lisp is
//! the oracle).  The step reads work.db and the hub's sessions and writes; **no git runs on it**: a ready task's
//! worktree is made by a task of its own (through [`super::RunGit`], with a deadline) and the task shows `starting`
//! meanwhile.  Review hand-off, the merge gate, fallback and the budget pause are Task 16b's, through
//! [`super::Hooks`].

use super::{
    GitError, GitFuture, MAX_AGENTS, RunGit, START_TRIES, TaskTree, TreeMode, TrialResult, changed,
    clash, data_for, data_of, internal, load, ordered, profile_of, put_in, raise_card, service,
    settle_cards, update_data, user,
};
use crate::agents::Origin;
use crate::coord::fail;
use crate::front::Front;
use crate::matrix_gate::Gate;
use norn::read::tasks::Task;
use norn::write::agents::{AgentRegister, agent_register};
use norn::write::jobs::job_set;
use norn::write::tasks::force_status;
use runstav::methods::agents::{SessionStatus, StartParams};
use runstav::methods::matrix::Role;
use runstav::types::{AbsPath, Bounded, Id, TaskRef};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

/// The step every this often (`drgnx-hub`'s tick).
pub const EVERY: Duration = Duration::from_secs(2);
/// A git call of the runner runs at most this long (`drgnx-job-git-timeout`).
pub const GIT_TIMEOUT: Duration = Duration::from_secs(300);

/// The loop: every running job steps each [`EVERY`] and when something wakes it (an approval, an unblock).
pub async fn run(front: Arc<Front>) {
    let mut every = tokio::time::interval(EVERY);
    every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = every.tick() => {}
            () = front.core.runs.woken() => {}
        }
        once(&front).await;
    }
}

/// One pass over the running jobs.
pub async fn once(front: &Arc<Front>) {
    if front.core.runs.recovering() {
        return;
    }
    let ids = match front
        .writer
        .db
        .read(|c| norn::read::jobs::jobs(c, Some("running")))
        .await
    {
        Ok(ids) => ids,
        Err(e) => {
            tracing::debug!("plan runs: no jobs read: {e}");
            return;
        }
    };
    for id in ids {
        if let Err(e) = step(front, &id).await {
            tracing::warn!("plan run {id}: {}", e.message);
        }
        if let Err(e) = clashes(front, &id).await {
            tracing::warn!("plan run {id}: clash scan: {}", e.message);
        }
        if let Some(h) = front.core.runs.hooks() {
            h.tick(front, &id).await;
        }
    }
}

/// Move job ID on: tasks whose agent is gone are free again, ready tasks get agents (up to [`MAX_AGENTS`]) in the
/// run order, the job is done when every task is.
pub async fn step(front: &Arc<Front>, id: &str) -> Result<(), crate::runner::Error> {
    let Some(l) = load(front, id, false).await? else {
        return Ok(());
    };
    if l.job.status.as_deref() != Some("running") {
        return Ok(());
    }
    let svc = service();
    let data = data_of(&l.job);
    let runs = &front.core.runs;
    let live: Vec<_> = front
        .core
        .agents
        .snapshots()
        .into_iter()
        .filter(|s| s.job.as_deref() == Some(id) && s.status != Some(SessionStatus::Exited))
        .collect();
    for t in &l.tasks {
        let (tid, status) = (t.row.id.clone(), t.row.status.as_deref().unwrap_or(""));
        if runs.busy_of(&tid).is_some() {
            continue;
        }
        let alive = t
            .row
            .agent
            .as_ref()
            .is_some_and(|a| live.iter().any(|s| &s.id == a));
        // its agent died or the hub restarted: the task is free (its worktree stays) - a few times, then the user
        if matches!(status, "claimed" | "running") && !alive {
            if let Some(a) = &t.row.agent {
                runs.session_finished(front, a);
            }
            let n = data_for(&data, "exits", &tid)
                .and_then(Value::as_i64)
                .unwrap_or(0)
                + 1;
            let key = tid.clone();
            update_data(front, &svc, id, move |d| {
                put_in(d, "exits", &key, Some(json!(n)));
            })
            .await?;
            if n < START_TRIES {
                let t2 = tid.clone();
                front
                    .writer
                    .write(&svc, "job/step", move |tx| {
                        force_status(tx, &t2, "ready", None, super::now()).map(|_| ())
                    })
                    .await
                    .map_err(fail)?;
            } else {
                raise_card(
                    front,
                    &svc,
                    id,
                    Some(&tid),
                    "agent",
                    &format!("its agent ended {n} times without finishing it"),
                    json!({}),
                )
                .await?;
            }
        }
    }
    // ready tasks get agents, in the run order, up to the cap
    let starting = l
        .tasks
        .iter()
        .filter(|t| runs.busy_of(&t.row.id) == Some("starting"))
        .count();
    let mut count = live
        .iter()
        .filter(|s| {
            l.tasks
                .iter()
                .any(|t| t.row.agent.as_deref() == Some(s.id.as_str()))
        })
        .count()
        + starting;
    for t in ordered(&l.tasks, &data) {
        if t.row.status.as_deref() == Some("ready")
            && runs.busy_of(&t.row.id).is_none()
            && count < MAX_AGENTS
            && data_for(&data, "blocked", &t.row.id).is_none()
        {
            runs.set_busy(&t.row.id, Some("starting"));
            let (f, job, task) = (front.clone(), id.to_owned(), t.clone());
            tokio::spawn(async move {
                if let Err(e) = start(&f, &job, &task, None).await {
                    tracing::warn!(
                        "plan run {job}: task {} did not start: {}",
                        task.row.id,
                        e.message
                    );
                }
                f.core.runs.set_busy(&task.row.id, None);
                changed(&f, &job).await;
            });
            count += 1;
        }
    }
    // a finished task's open question went with it
    let finished: Vec<String> = l
        .tasks
        .iter()
        .filter(|t| matches!(t.row.status.as_deref(), Some("done" | "dropped")))
        .map(|t| t.row.id.clone())
        .collect();
    if l.open_cards
        .iter()
        .any(|c| c.task.as_ref().is_some_and(|t| finished.contains(t)))
    {
        settle_cards(front, &svc, id, |c| {
            c.task
                .as_ref()
                .is_some_and(|t| finished.contains(t))
                .then_some("resolved")
        })
        .await?;
    }
    if !l.tasks.is_empty() && finished.len() == l.tasks.len() {
        let jid = id.to_owned();
        front
            .writer
            .write(&svc, "coord/job-set", move |tx| {
                job_set(tx, &jid, Some("done"), None, super::now())
            })
            .await
            .map_err(fail)?;
        for s in &live {
            runs.session_finished(front, &s.id);
        }
        super::end_sessions(front, id).await;
    }
    changed(front, id).await;
    Ok(())
}

/// What the clash rules see of a run (Task 18): its tasks and sessions, the keys already carded (the job data's
/// `clashes`), the subjects of settled clash cards and the tasks with an open one.  A task's head is a digest of its
/// diff, so a task that changed again is looked at again.
pub(crate) fn run_state(
    l: &super::Loaded,
    data: &serde_json::Map<String, Value>,
    sessions: &[runstav::methods::agents::Snapshot],
    held: &std::collections::BTreeMap<String, u64>,
    settled: &[norn::read::cards::Card],
    diffs: &clash::DiffIndex,
) -> clash::RunState {
    use sha2::{Digest, Sha256};
    let head = |tid: &str| {
        let d = diffs.get(tid)?;
        let all: String = d
            .iter()
            .map(|(p, f)| format!("{p}\t{}\n", f.hash))
            .collect();
        Some(
            Sha256::digest(all.as_bytes())
                .iter()
                .take(8)
                .map(|b| format!("{b:02x}"))
                .collect(),
        )
    };
    let subject_of = |c: &norn::read::cards::Card| {
        c.data
            .as_ref()
            .and_then(|d| d.get("subject"))
            .and_then(Value::as_str)
            .map(clash::subject)
    };
    clash::RunState {
        status: l.job.status.clone().unwrap_or_default(),
        tasks: l
            .tasks
            .iter()
            .map(|t| clash::RunTask {
                id: t.row.id.clone(),
                n: t.row.n,
                status: t.row.status.clone().unwrap_or_default(),
                agent: t.row.agent.clone(),
                head: head(&t.row.id),
            })
            .collect(),
        sessions: sessions
            .iter()
            .map(|s| clash::RunSession {
                id: s.id.clone(),
                task: s.task.clone(),
                exited: s.status == Some(SessionStatus::Exited),
                held: held
                    .get(&s.id)
                    .copied()
                    .unwrap_or(0)
                    .try_into()
                    .unwrap_or(u32::MAX),
            })
            .collect(),
        carded: data
            .get("clashes")
            .and_then(Value::as_object)
            .map(|m| m.keys().cloned().collect())
            .unwrap_or_default(),
        settled_subjects: settled
            .iter()
            .filter(|c| c.kind.as_deref() == Some("clash"))
            .filter_map(subject_of)
            .collect(),
        open_clash_tasks: l
            .open_cards
            .iter()
            .filter(|c| c.kind.as_deref() == Some("clash"))
            .filter_map(|c| c.task.clone())
            .collect(),
    }
}

/// Scan job ID for clashes and card each new one once; its key is kept in the job's data (`clashes`), so a restart
/// does not card it again.  Reviewers for the cards are Task 16b's.
pub async fn clashes(front: &Arc<Front>, id: &str) -> Result<(), crate::runner::Error> {
    let Some(l) = load(front, id, true).await? else {
        return Ok(());
    };
    if !matches!(l.job.status.as_deref(), Some("running" | "paused")) {
        return Ok(());
    }
    let data = data_of(&l.job);
    let sessions: Vec<_> = front
        .core
        .agents
        .snapshots()
        .into_iter()
        .filter(|s| s.job.as_deref() == Some(id))
        .collect();
    let (jid, ids) = (
        id.to_owned(),
        sessions.iter().map(|s| s.id.clone()).collect::<Vec<_>>(),
    );
    let (held, settled) = front
        .writer
        .db
        .read(move |c| {
            let mut held = std::collections::BTreeMap::new();
            for a in ids {
                let n = norn::write::meta::held(c, &a)?;
                held.insert(a, n);
            }
            Ok((held, norn::read::cards::cards(c, &jid, Some("settled"))?))
        })
        .await
        .map_err(fail)?;
    // the diffs of the tasks in review, from the trusted repository
    let repo = PathBuf::from(l.job.repo.clone().unwrap_or_default());
    let git = front.core.runs.git();
    let mut diffs = clash::DiffIndex::new();
    for t in l
        .tasks
        .iter()
        .filter(|t| t.row.status.as_deref() == Some("in-review"))
    {
        let Some(base) = data_for(&data, "bases", &t.row.id).and_then(Value::as_str) else {
            continue;
        };
        let tree = TaskTree {
            path: sessions
                .iter()
                .find(|s| s.task.as_deref() == Some(t.row.id.as_str()))
                .and_then(|s| s.cwd.clone())
                .map(PathBuf::from)
                .unwrap_or_default(),
            branch: format!("job/{id}-{}", t.row.n),
            base: base.to_owned(),
            mode: TreeMode::Worktree,
        };
        if let Ok(hashes) = git.diffs(&repo, &tree).await {
            diffs.insert(
                t.row.id.clone(),
                hashes
                    .into_iter()
                    .map(|(p, hash)| {
                        (
                            p,
                            clash::FileDiff {
                                hash,
                                ranges: Vec::new(),
                            },
                        )
                    })
                    .collect(),
            );
        }
    }
    let run = run_state(&l, &data, &sessions, &held, &settled, &diffs);
    let decisions: Vec<runstav::methods::coord::Decision> = l
        .decisions
        .iter()
        .map(|d| runstav::methods::coord::Decision {
            n: d.n,
            kind: d.kind.clone(),
            subject: d.subject.clone(),
            task: d.task.clone(),
            paths: d.paths.clone(),
            reason: d.reason.clone(),
            author: d.author.clone(),
            status: d.status.clone(),
            job: d.job.clone(),
            replaces: d.replaces,
            at: d.at,
            ver: d.ver,
        })
        .collect();
    let found = clash::scan(&run, &decisions, &diffs);
    let svc = service();
    for c in found {
        let kind = match c.rule {
            clash::Rule::Stale => "stalled",
            clash::Rule::Overlap => "overlap",
            _ => "clash",
        };
        raise_card(
            front,
            &svc,
            id,
            c.task.as_deref(),
            kind,
            &c.title,
            json!({
                "key": c.key, "rule": c.rule, "subject": c.subject, "sides": c.sides, "files": c.files,
                "lines": c.lines, "size": c.size, "blocks_review": c.blocks_review,
            }),
        )
        .await?;
        let key = c.key.clone();
        update_data(front, &svc, id, move |d| {
            put_in(d, "clashes", &key, Some(json!(true)));
        })
        .await?;
    }
    Ok(())
}

/// Give TASK of job JOB its worker: a tree of its own (git, off the tick), a session of the task's profile with the
/// role Worker in it, the task claimed by that session, and its prompt.  A failure raises the task's `agent` card.
/// HANDOVER: what the agent before it left.
pub async fn start(
    front: &Arc<Front>,
    job: &str,
    task: &Task,
    handover: Option<&str>,
) -> Result<(), crate::runner::Error> {
    let runs = &front.core.runs;
    let svc = service();
    let (tid, n) = (task.row.id.as_str(), task.row.n);
    let Some(l) = load(front, job, false).await? else {
        return Ok(());
    };
    let data = data_of(&l.job);
    let repo = PathBuf::from(l.job.repo.clone().unwrap_or_default());
    let profile = profile_of(front, &data, task);
    // the job's branch is made from HEAD when absent; the task's tree starts from the commit it is at now
    let base = format!("job/{job}");
    let base = match git(&repo, &["rev-parse", "--verify", "-q", &base]).await {
        Ok(sha) => sha,
        Err(_) => match git(&repo, &["branch", &base, "HEAD"]).await {
            Ok(_) => git(&repo, &["rev-parse", "--verify", &base])
                .await
                .unwrap_or(base),
            Err(_) => base,
        },
    };
    let tree = match runs
        .git()
        .task_worktree(&repo, job, &n.to_string(), &base)
        .await
    {
        Ok(t) => t,
        Err(e) => {
            raise_card(
                front,
                &svc,
                job,
                Some(tid),
                "agent",
                &format!("no worktree for it: {}", e.stderr.trim()),
                json!({}),
            )
            .await?;
            return Ok(());
        }
    };
    // blocked, stopped or taken meanwhile: not now
    let Some(l) = load(front, job, false).await? else {
        return Ok(());
    };
    let data = data_of(&l.job);
    let still_ready = l
        .tasks
        .iter()
        .any(|t| t.row.id == tid && t.row.status.as_deref() == Some("ready"));
    if l.job.status.as_deref() != Some("running")
        || !still_ready
        || data_for(&data, "blocked", tid).is_some()
    {
        return Ok(());
    }
    // its edits are against where the task's tree started, not where the job's branch is later: kept from the first
    if data_for(&data, "bases", tid).is_none() {
        let (key, base) = (tid.to_owned(), tree.base.clone());
        update_data(front, &svc, job, move |d| {
            put_in(d, "bases", &key, Some(json!(base)));
        })
        .await?;
    }
    let cwd = tree.path.to_string_lossy().into_owned();
    let started = front
        .core
        .agents
        .start(
            front,
            StartParams {
                profile: Bounded(profile.clone()),
                cwd: AbsPath::new(cwd.clone()).ok(),
                task: TaskRef::new(tid).ok(),
                job: Id::new(job).ok(),
                role: Some(Role::Worker),
                about: None,
                document: None,
            },
            &user(),
        )
        .await;
    let sid = match started {
        Ok(s) => s.id,
        Err(e) => {
            raise_card(
                front,
                &svc,
                job,
                Some(tid),
                "agent",
                &format!("no agent on {profile}: {}", e.message),
                json!({"profile": profile}),
            )
            .await?;
            return Ok(());
        }
    };
    // the session's steps are filed under its plan and project
    let plan = l
        .job
        .plan
        .as_deref()
        .map(|p| format!("plan:{p}"))
        .unwrap_or_else(|| format!("plan:{job}"));
    let project = {
        let dir = repo.clone();
        tokio::task::spawn_blocking(move || norn::project::resolve(&dir).map(|p| p.id))
            .await
            .ok()
            .flatten()
    };
    // spend counts toward the plan, and the plan toward its project; the gateway books the session's requests
    // under the job
    {
        use runstav::methods::timeline::BudgetScope;
        let b = &front.core.budgets;
        let worker = crate::agents::session::scope_of(Role::Worker, &sid);
        let plan_scope = BudgetScope::Plan(Bounded(plan.clone()));
        match &project {
            Some(p) => {
                let project_scope = BudgetScope::Project(Bounded(p.clone()));
                b.link(&plan_scope, &project_scope);
            }
            None => b.enroll(&plan_scope),
        }
        b.link(&worker, &plan_scope);
        b.bind_job(job, &worker);
    }
    runs.set_scope(&sid, plan, project);
    // a run folder a sandboxed session worked in is never touched by plain git again
    if let Err(e) = runs.git().touched(&tree.path).await {
        tracing::warn!("run folder not marked touched: {}", e.stderr);
    }
    let reg = AgentRegister {
        id: sid.clone(),
        kind: Some("job".into()),
        name: None,
        cwd: Some(cwd.clone()),
        worktree: Some(cwd),
        branch: Some(tree.branch.clone()),
        base: Some(tree.base.clone()),
        plan: None,
        task: Some(tid.to_owned()),
        pid: None,
        clear: Vec::new(),
    };
    let (t2, s2) = (tid.to_owned(), sid.clone());
    front
        .writer
        .write(&svc, "coord/agent-register", move |tx| {
            agent_register(tx, reg.clone(), super::now())?;
            force_status(tx, &t2, "claimed", Some(&s2), super::now()).map(|_| ())
        })
        .await
        .map_err(fail)?;
    let notes = data_for(&data, "notes", tid).and_then(Value::as_str);
    let body = data
        .get("tasks")
        .and_then(Value::as_array)
        .and_then(|a| {
            a.iter()
                .find(|t| t.get("n").and_then(Value::as_i64) == Some(n))
        })
        .and_then(|t| t.get("body").and_then(Value::as_str))
        .unwrap_or("");
    let body = crate::brief::for_dispatch(front, tid)
        .await
        .unwrap_or_else(|| body.to_owned());
    let prompt = format!(
        "[drgnx task {tid}] {}\n\n{body}\n\n{}{}First call read_decisions (the job's decision log). Work only in this \
         directory (a git worktree of your own). Commit your work. Then call complete_task.",
        task.row.title.as_deref().unwrap_or(""),
        handover.unwrap_or(""),
        notes
            .map(|n| format!("The reviewer asked for changes:\n{n}\n\n"))
            .unwrap_or_default(),
    );
    front
        .core
        .agents
        .prompt(&sid, prompt, Origin::Hub)
        .map_err(|e| internal(format!("the task's prompt: {}", e.message)))?;
    Ok(())
}

/// Worktrees by plain `git`, until Task 17's `HubGit` replaces it ([`super::Runs::set_git`]): the task's tree
/// `<repo>/.claude/worktrees/<job>-<n>/` on the branch `job/<job>-<n>`, from the job's branch (made from `HEAD` when
/// absent).  The merge gate and trial merges are Task 17's.
pub struct BasicGit;

async fn git(dir: &Path, args: &[&str]) -> Result<String, GitError> {
    let what = format!("git {}", args.join(" "));
    let mut cmd = tokio::process::Command::new("git");
    cmd.arg("-C")
        .arg(dir)
        .args(["-c", "core.hooksPath=/dev/null"])
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    match tokio::time::timeout(GIT_TIMEOUT, cmd.output()).await {
        Err(_) => Err(GitError {
            what,
            stderr: "timed out".into(),
        }),
        Ok(Err(e)) => Err(GitError {
            what,
            stderr: e.to_string(),
        }),
        Ok(Ok(o)) if o.status.success() => Ok(String::from_utf8_lossy(&o.stdout).trim().to_owned()),
        Ok(Ok(o)) => Err(GitError {
            what,
            stderr: String::from_utf8_lossy(&o.stderr).trim().to_owned(),
        }),
    }
}

impl RunGit for BasicGit {
    fn task_worktree<'a>(
        &'a self,
        repo: &'a Path,
        run: &'a str,
        task: &'a str,
        base: &'a str,
    ) -> GitFuture<'a, TaskTree> {
        Box::pin(async move {
            let path = repo.join(format!(".claude/worktrees/{run}-{task}"));
            let branch = format!("job/{run}-{task}");
            if !path.is_dir() {
                if git(repo, &["rev-parse", "--verify", "-q", base])
                    .await
                    .is_err()
                {
                    git(repo, &["branch", base, "HEAD"]).await?;
                }
                let p = path.to_string_lossy().into_owned();
                if git(repo, &["worktree", "add", "-q", "-b", &branch, &p, base])
                    .await
                    .is_err()
                {
                    git(repo, &["worktree", "add", "-q", &p, &branch]).await?; // its branch from before
                }
            }
            let head = git(&path, &["rev-parse", "HEAD"]).await?;
            Ok(TaskTree {
                path,
                branch,
                base: head,
                mode: TreeMode::Worktree,
            })
        })
    }

    fn merge_gate<'a>(&'a self, _: &'a Path, _: &'a TaskTree) -> GitFuture<'a, Gate> {
        Box::pin(async {
            Err(GitError {
                what: "merge gate".into(),
                stderr: "not yet (agent system part 1, Task 17)".into(),
            })
        })
    }

    fn trial_merge<'a>(&'a self, _: &'a Path, _: &'a [String]) -> GitFuture<'a, TrialResult> {
        Box::pin(async {
            Err(GitError {
                what: "trial merge".into(),
                stderr: "not yet (agent system part 1, Task 17)".into(),
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use norn::read::jobs::Job;

    #[test]
    fn the_run_state_remembers_carded_keys_from_the_job_data() {
        let job = Job {
            id: "j".into(),
            title: None,
            plan: None,
            repo: None,
            status: Some("running".into()),
            created: None,
            data: Some(json!({"clashes": {"contradiction:1:2": true}})),
        };
        let l = super::super::Loaded {
            job,
            tasks: Vec::new(),
            open_cards: Vec::new(),
            messages: Vec::new(),
            decisions: Vec::new(),
            spent: 0.0,
        };
        let data = data_of(&l.job);
        let run = run_state(
            &l,
            &data,
            &[],
            &Default::default(),
            &[],
            &Default::default(),
        );
        assert_eq!(run.status, "running");
        assert!(run.carded.contains("contradiction:1:2"));
    }

    #[test]
    fn a_runs_scopes_are_shared_with_the_step_writers() {
        let runs = super::super::Runs::default();
        let scopes = runs.scopes();
        runs.set_scope("a1", "plan:p".into(), Some("project:q".into()));
        assert_eq!(
            scopes.get("a1"),
            Some(("plan:p".into(), Some("project:q".into())))
        );
    }
}
