//! The gates before a task's merge (`docs/develop/orchestration.md`).
//!
//! [`before_merge`] runs them in order once the merge gate allows a task: trailers, red first (`orch::red_first`),
//! the author check.  A run a gate needs and the hub can make (the task's own test command at its test commit or its
//! tip, an author check at the tip) is started through the queue as a sealed job (`exec::start_sealed`), and the
//! gate waits for it
//! ([`Runs`]); its end is the task's evidence like any other job's.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{Map, Value, json};
use vordr::evidence::Evidence;
use vordr::gates::{State, checks, selector_of, state, trailers, waived};
use vordr::redfirst::{self, Decision};

use crate::exec::unit::Meta;
use crate::front::Front;
use crate::runner::TaskTree;

/// A run a gate started: the task it is for, the tree key and selector it runs (so it starts once), and a detached
/// worktree (and the tree it came from) to remove when it ends.
#[derive(Clone, Debug)]
pub struct Run {
    pub task: String,
    pub key: (String, String),
    pub worktree: Option<(PathBuf, PathBuf)>,
}

/// The gates' runs in flight, by exec job id.
#[derive(Default)]
pub struct Runs {
    jobs: Mutex<HashMap<String, Run>>,
}

impl Runs {
    /// TASK's run of SELECTOR at the tree KEY, claimed in the same step as the check that none is in flight (one whose
    /// job ENDED, an end the watcher missed, isn't): the claim's id until [`Self::started`] or [`Self::release`];
    /// none when one is in flight.
    fn claim(
        &self,
        task: &str,
        key: &str,
        selector: &str,
        ended: impl Fn(&str) -> bool,
    ) -> Option<String> {
        let mut jobs = self.jobs.lock().unwrap();
        if jobs
            .iter()
            .any(|(id, r)| r.task == task && r.key.0 == key && r.key.1 == selector && !ended(id))
        {
            return None;
        }
        let claim = format!("claim:{task}\n{key}\n{selector}");
        let run = Run {
            task: task.to_owned(),
            key: (key.to_owned(), selector.to_owned()),
            worktree: None,
        };
        jobs.insert(claim.clone(), run);
        Some(claim)
    }

    /// The claim CLAIM started as job ID.
    fn started(&self, claim: &str, id: String, run: Run) {
        let mut jobs = self.jobs.lock().unwrap();
        jobs.remove(claim);
        jobs.insert(id, run);
    }

    /// The claim CLAIM started nothing (or started already: then nothing changes).
    fn release(&self, claim: &str) {
        self.jobs.lock().unwrap().remove(claim);
    }

    /// Whether TASK waits on a gate's run (`gate-wait`): one is in flight (one whose job ENDED isn't).
    pub fn waiting(&self, task: &str, ended: impl Fn(&str) -> bool) -> bool {
        self.jobs
            .lock()
            .unwrap()
            .iter()
            .any(|(id, r)| r.task == task && !ended(id))
    }

    /// Job ID's run, once it ended (taken out).
    pub fn take(&self, id: &str) -> Option<Run> {
        self.jobs.lock().unwrap().remove(id)
    }

    /// The runs whose jobs ENDED (never a claim), taken out: what a watcher that lagged behind the job events missed.
    pub fn take_ended(&self, ended: impl Fn(&str) -> bool) -> Vec<(String, Run)> {
        let mut jobs = self.jobs.lock().unwrap();
        let ids: Vec<String> = jobs
            .keys()
            .filter(|id| !id.starts_with("claim:") && ended(id))
            .cloned()
            .collect();
        ids.into_iter()
            .filter_map(|id| jobs.remove(&id).map(|r| (id, r)))
            .collect()
    }
}

/// A command to run again: from the task's job JOB, in REL (relative to the tree's top).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rerun {
    pub job: String,
    pub rel: String,
    pub argv: Vec<String>,
    pub kind: String,
    pub image: Option<String>,
    pub selector: String,
    /// The test selector variables the job ran with (`vordr::facts::selector_env`): the rerun's selector is its own.
    pub env: Vec<(String, String)>,
}

/// The task's test command to run again: the newest of its EVIDENCE at the tree PREFER, else the newest anywhere,
/// whose job (META) ran inside the task's tree TOP.
pub fn rerun_of(
    evidence: &[Evidence],
    prefer: &str,
    top: &Path,
    meta: impl Fn(&str) -> Option<Meta>,
) -> Option<Rerun> {
    let of = |e: &Evidence| {
        let m = meta(&e.job)?;
        let rel = Path::new(&m.cwd).strip_prefix(top).ok()?;
        let rel = rel.to_string_lossy().into_owned();
        Some(Rerun {
            job: e.job.clone(),
            env: vordr::facts::selector_env(&e.facts.selector, &rel, &m.argv),
            rel,
            argv: m.argv,
            kind: m.kind,
            image: m.image,
            selector: e.facts.selector.clone(),
        })
    };
    evidence
        .iter()
        .rev()
        .filter(|e| e.facts.tree_key == prefer)
        .find_map(of)
        .or_else(|| evidence.iter().rev().find_map(of))
}

pub(crate) fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .map_err(|e| format!("git {}: {e}", args.join(" ")))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

/// The attribution trailers of the commits BASE..TIP in DIR, as `SHORT: line`.
fn trailers_in(dir: &Path, base: &str, tip: &str) -> Result<Vec<String>, String> {
    let log = git(
        dir,
        &["log", "--format=%h%x00%B%x1e", &format!("{base}..{tip}")],
    )?;
    let mut out = Vec::new();
    for c in log.split('\x1e') {
        let Some((sha, msg)) = c.trim_start().split_once('\0') else {
            continue;
        };
        out.extend(trailers(msg).into_iter().map(|t| format!("{sha}: {t}")));
    }
    Ok(out)
}

/// A pack's CHECK (an author check, a rule test, a group) as a run.
pub(crate) fn run_of(c: &vordr::pack::Check) -> Rerun {
    let kind = if c.run.first().map(String::as_str) == Some("cargo") {
        "cargo"
    } else {
        "other"
    };
    Rerun {
        job: String::new(),
        rel: c.dir.clone(),
        argv: c.run.clone(),
        kind: kind.into(),
        image: None,
        selector: selector_of(c),
        env: Vec::new(),
    }
}

/// Start RERUN for TASK at COMMIT (whose tree key is KEY) of the task's tree TOP, through the queue in an agent's
/// sandbox, once: in a detached worktree beside TOP, removed when the job ends.  Some(why) when the gate holds instead:
/// the run already ended there without a test result (`vordr::evidence::no_rerun`).
pub(crate) async fn start(
    front: &Front,
    task: &str,
    top: &Path,
    commit: &str,
    key: &str,
    rerun: &Rerun,
) -> Result<Option<String>, String> {
    let ended = |id: &str| front.core.exec.done(id).is_some();
    let Some(claim) = front.orch.claim(task, key, &rerun.selector, ended) else {
        return Ok(None);
    };
    let r = start_claimed(front, task, top, commit, key, rerun, &claim).await;
    front.orch.release(&claim);
    r
}

/// [`start`] once CLAIM holds the run's place.
async fn start_claimed(
    front: &Front,
    task: &str,
    top: &Path,
    commit: &str,
    key: &str,
    rerun: &Rerun,
    claim: &str,
) -> Result<Option<String>, String> {
    let t = task.to_owned();
    let evidence = front
        .writer
        .db
        .read(move |c| norn::read::evidence::of_task(c, &t))
        .await
        .map_err(|e| e.to_string())?;
    if let Some((class, job)) = vordr::evidence::no_rerun(&evidence, key, &rerun.selector) {
        // a gate's own words on the run (its tree moved) before what the job said
        let said = evidence
            .iter()
            .find(|e| e.job == job)
            .and_then(|e| e.note.clone())
            .unwrap_or_else(|| front.core.exec.log_slice(&job, 0, 3).join(" / "));
        let cmd = rerun.argv.join(" ");
        return Ok(Some(match class {
            vordr::rows::Class::Error => {
                format!("{cmd} failed without a test result (error): {said}")
            }
            c => format!(
                "{cmd} ran twice without a test result ({}): {said}",
                vordr::redfirst::class_word(Some(c))
            ),
        }));
    }
    let (from, c, sel) = (top.to_owned(), commit.to_owned(), rerun.selector.clone());
    let dir = crate::clock::blocking(move || detached(&from, &c, &sel))
        .await
        .map_err(|e| e.to_string())??;
    let worktree = Some((top.to_owned(), dir.clone()));
    let cwd = if rerun.rel.is_empty() {
        dir.clone()
    } else {
        dir.join(&rerun.rel)
    };
    let mut p = json!({"argv": rerun.argv, "cwd": cwd.to_string_lossy(), "kind": rerun.kind});
    if let Some(i) = &rerun.image {
        p["image"] = json!(i);
    }
    if !rerun.env.is_empty() {
        let env: Vec<_> = rerun
            .env
            .iter()
            .map(|(name, value)| json!({"name": name, "value": value}))
            .collect();
        p["env"] = json!(env);
    }
    let params = serde_json::from_value(p).map_err(|e| e.to_string())?;
    // the agent's command (or the pack's, over the agent's tree): in an agent's sandbox, the detached tree its only
    // writable folder
    let gate = crate::exec::Sealed {
        label: gate_sid(task, &dir),
        tree: dir.clone(),
    };
    let started = match crate::exec::start_sealed(front, &gate, params).await {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!(
                task,
                tree = %dir.display(),
                "the gate's run of {} did not start: {}",
                rerun.argv.join(" "),
                e.message
            );
            let run = Run {
                task: task.to_owned(),
                key: (key.to_owned(), rerun.selector.clone()),
                worktree,
            };
            let _ = crate::clock::blocking(move || cleanup(&run)).await;
            return Err(e.message);
        }
    };
    let id = started.id;
    tracing::info!(
        task,
        job = %id,
        tree = %dir.display(),
        "the gate runs {} at {commit}",
        rerun.argv.join(" ")
    );
    front.orch.started(
        claim,
        id.clone(),
        Run {
            task: task.to_owned(),
            key: (key.to_owned(), rerun.selector.clone()),
            worktree,
        },
    );
    // a job that ended before it was added here was missed by the watcher: settled here
    if front.core.exec.done(&id).is_some()
        && let Some(run) = front.orch.take(&id)
    {
        crate::orch::evidence::settle(front, &id, run).await;
    }
    Ok(None)
}

/// The sandbox id of TASK's gate run in the detached tree DIR: `gate-` and the tree's folder name, kept to the letters a
/// session id may hold (no session holds it: the run wakes no one).
pub(crate) fn gate_sid(task: &str, dir: &Path) -> String {
    let name = dir.file_name().and_then(|n| n.to_str()).unwrap_or(task);
    let mut sid = String::from("gate-");
    sid.extend(name.chars().map(|c| {
        if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
            c
        } else {
            '-'
        }
    }));
    sid
}

/// A detached worktree of the tree TOP at COMMIT, beside it, for the run with SELECTOR (one per run: each goes when
/// its job ends).
fn detached(top: &Path, commit: &str, selector: &str) -> Result<PathBuf, String> {
    let name = top
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut h: u32 = 0x811c_9dc5;
    for b in selector.bytes() {
        h ^= u32::from(b);
        h = h.wrapping_mul(0x0100_0193);
    }
    let at = top.with_file_name(format!(
        "{name}.gate-{}-{h:08x}",
        &commit[..commit.len().min(12)]
    ));
    if !at.exists() {
        git(
            top,
            &["worktree", "add", "--detach", &at.to_string_lossy(), commit],
        )?;
    }
    Ok(at)
}

/// Remove a gate run's detached worktree once its job ended (blocking: git).
pub fn cleanup(run: &Run) {
    if let Some((top, dir)) = &run.worktree
        && let Err(e) = git(
            top,
            &["worktree", "remove", "--force", &dir.to_string_lossy()],
        )
    {
        tracing::warn!("{}: {e}", dir.display());
    }
}

/// The gates before task TID (number N) of JOB at TREE merges: trailers, red first, the author check, judged at
/// JUDGED (the tip the merge gate checked; none: the branch as it is).  A job approved without a rule pack passes.
pub async fn before_merge(
    front: &Front,
    job: &str,
    tid: &str,
    n: i64,
    tree: &TaskTree,
    judged: Option<&str>,
    data: &Map<String, Value>,
) -> Result<Decision, String> {
    let (j, t) = (job.to_owned(), tid.to_owned());
    let (pack, evidence) = front
        .writer
        .db
        .read(move |c| {
            Ok((
                norn::read::evidence::pack_of_job(c, &j)?,
                norn::read::evidence::of_task(c, &t)?,
            ))
        })
        .await
        .map_err(|e| e.to_string())?;
    let Some(pack) = pack else {
        return Ok(Decision::Pass("the job has no rule pack".into()));
    };
    let tip = judged.map_or_else(|| tree.branch.clone(), str::to_owned);
    let (top, base) = (tree.path.clone(), tree.base.clone());
    let body = crate::orch::red_first::body_of(data, n);
    let p = pack.clone();
    let (tip_commit, found, unnoted, inputs, commits) = crate::clock::blocking(move || {
        let tip_commit = git(&top, &["rev-parse", &tip])?.trim().to_owned();
        let found = if p.on("trailers") {
            trailers_in(&top, &base, &tip)?
        } else {
            Vec::new()
        };
        let unnoted = if p.on("merge-notes") {
            crate::orch::notes::check(&top, &base, &tip, &p.shared_paths)?
        } else {
            Vec::new()
        };
        let inputs = crate::orch::red_first::inputs(&top, &base, &tip, &p, &body)?;
        let commits = crate::orch::red_first::commits(&top, &base, &tip, &p)?;
        Ok::<_, String>((tip_commit, found, unnoted, inputs, commits))
    })
    .await
    .map_err(|e| e.to_string())??;
    // what the gate checked, for the Flow's detail (base .. tip and each commit)
    let key = tid.to_owned();
    crate::runner::update_data(front, &crate::runner::service(), job, move |d| {
        crate::runner::put_in(d, "commits", &key, Some(commits));
    })
    .await
    .map_err(|e| e.message)?;
    if !found.is_empty() {
        return Ok(Decision::Hold(format!(
            "attribution trailers: {}",
            found.join("; ")
        )));
    }
    // like the trailers, a commit's own words: no waiver passes them
    if !unnoted.is_empty() {
        return Ok(Decision::Hold(format!(
            "merge notes: {}. Each needs a line in its merge commit's message: Merge-note: HUNK ours=COMMIT \
             theirs=COMMIT resolution=ours|theirs|both|new | why",
            unnoted.join("; ")
        )));
    }
    // the user's waiver at this tip passes red first and the author check (never the trailers: those are reworded)
    let (waivers, evidence): (Vec<Evidence>, Vec<Evidence>) =
        evidence.into_iter().partition(|e| e.kind == "waiver");
    if let Some(why) = waived(&waivers, &inputs.tip_key) {
        return Ok(Decision::Pass(format!("waived by the user: {why}")));
    }
    let top = tree.path.as_path();
    let meta = |id: &str| front.core.exec.meta(id);
    match redfirst::decide(&pack, &inputs, &evidence) {
        Decision::Pass(_) => {}
        Decision::Hold(why) => return Ok(Decision::Hold(why)),
        Decision::Wait(why) => {
            let at_test = evidence.iter().any(|e| e.facts.tree_key == inputs.test_key);
            // the tip's run repeats the red's command; the test commit's repeats the newest at the tip
            let (commit, key, prefer) = if at_test {
                (&tip_commit, &inputs.tip_key, &inputs.test_key)
            } else {
                (&inputs.test_commit, &inputs.test_key, &inputs.tip_key)
            };
            let Some(r) = rerun_of(&evidence, prefer, top, meta) else {
                return Ok(Decision::Hold(format!(
                    "{why}, and no run of the task's tests through the hub to repeat: run them with exec/start, \
                     or say **Red:** none (reason) in the plan"
                )));
            };
            if let Some(why) = start(front, tid, top, commit, key, &r).await? {
                return Ok(Decision::Hold(why));
            }
            return Ok(Decision::Wait(format!(
                "{why}: the hub runs {}",
                r.argv.join(" ")
            )));
        }
    }
    // an author check counts a run made with this machine's toolchain, here (an old green after a bump is no run)
    let here = vordr::gates::current(
        &evidence,
        crate::exec::env_stamp(),
        &crate::exec::local_platform(),
    );
    for c in checks(&pack) {
        let sel = selector_of(&c);
        match state(&here, &inputs.tip_key, &sel) {
            State::Green => {}
            State::Red(rows) => {
                return Ok(Decision::Hold(format!(
                    "the author check {} fails at the tip: {}",
                    c.name,
                    rows.join(", ")
                )));
            }
            State::Missing => {
                let r = run_of(&c);
                if let Some(why) = start(front, tid, top, &tip_commit, &inputs.tip_key, &r).await? {
                    return Ok(Decision::Hold(format!(
                        "the author check {}: {why}",
                        c.name
                    )));
                }
                return Ok(Decision::Wait(format!(
                    "the author check {} runs at the tip",
                    c.name
                )));
            }
        }
    }
    Ok(Decision::Pass(
        "trailers, red first and the author check".into(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::exec::unit::Meta;
    use std::path::Path;
    use vordr::evidence::Evidence;
    use vordr::facts::Facts;

    fn ev(job: &str, key: &str, at: f64) -> Evidence {
        Evidence {
            kind: "red".into(),
            task: "t1".into(),
            job: job.into(),
            facts: Facts {
                tree_key: key.into(),
                env_stamp: "e".into(),
                platform: "p".into(),
                selector: format!("sel-{job}"),
            },
            rows: vec![],
            truncated: false,
            at,
            note: None,
        }
    }

    fn meta(id: &str, cwd: &str, argv: &[&str]) -> Meta {
        serde_json::from_value(serde_json::json!({
            "id": id, "session": "s", "kind": "cargo", "argv": argv, "cwd": cwd, "started": 1.0,
            "timebox_s": 600, "deadline": null, "unit": null, "pid": null, "start_time": null, "entity": null,
        }))
        .unwrap()
    }

    /// Two gates asking for the same run at once (two pushes) start it once: the check and the claim are one step.
    #[test]
    fn a_run_is_claimed_once_until_it_ends() {
        let runs = Runs::default();
        let none = |_: &str| false;
        let c = runs
            .claim("t", "K", "s", none)
            .expect("the first claims it");
        assert_eq!(runs.claim("t", "K", "s", none), None, "in flight");
        assert!(runs.claim("t", "K", "other", none).is_some());
        let run = Run {
            task: "t".into(),
            key: ("K".into(), "s".into()),
            worktree: None,
        };
        runs.started(&c, "x1".into(), run);
        assert_eq!(runs.claim("t", "K", "s", none), None, "started");
        assert_eq!(
            runs.claim("t", "K", "s", |id| id == "x1").map(|_| ()),
            Some(())
        );
        // a claim that never started is let go
        let d = runs.claim("u", "K", "s", none).unwrap();
        runs.release(&d);
        let e = runs.claim("u", "K", "s", none).unwrap();
        // the watcher lagged: the runs whose jobs ended are taken out to settle; a claim and a running job stay
        let ended = runs.take_ended(|id| id == "x1" || id == e);
        assert_eq!(
            ended.iter().map(|(id, _)| id.as_str()).collect::<Vec<_>>(),
            vec!["x1"]
        );
        assert!(runs.take("x1").is_none());
        assert_eq!(runs.claim("u", "K", "s", none), None, "the claim stays");
    }

    #[test]
    fn the_command_to_rerun_is_the_tasks_own_preferring_the_named_tree() {
        let top = Path::new("/runs/J/1");
        let metas = |id: &str| match id {
            "a" => Some(meta(
                "a",
                "/runs/J/1/runtime",
                &["cargo", "test", "-p", "x"],
            )),
            "b" => Some(meta("b", "/runs/J/1", &["bin/drgnx", "test"])),
            "c" => Some(meta("c", "/elsewhere", &["make"])),
            _ => None,
        };
        let e = [
            ev("a", "T", 1.0),
            ev("b", "P", 2.0),
            ev("c", "P", 3.0),
            ev("gone", "P", 4.0),
        ];
        // the newest at the preferred tree whose command ran inside the task's tree
        let r = rerun_of(&e, "P", top, metas).unwrap();
        assert_eq!((r.job.as_str(), r.rel.as_str()), ("b", ""));
        assert_eq!(r.argv, vec!["bin/drgnx", "test"]);
        // none there: the newest anywhere in the task's tree
        let r = rerun_of(&e, "Z", top, metas).unwrap();
        assert_eq!(
            (r.job.as_str(), r.rel.as_str(), r.kind.as_str()),
            ("b", "", "cargo")
        );
        let r = rerun_of(&e[..1], "Z", top, metas).unwrap();
        assert_eq!(r.rel, "runtime");
        assert!(
            rerun_of(&e[2..], "P", top, metas).is_none(),
            "outside the tree, or gone"
        );
        // the test selector the job ran with goes with the rerun, so its selector is the job's
        let env = vec![("DRGNX_TEST_SELECTOR".to_string(), "^a/".to_string())];
        let argv: Vec<String> = vec!["bin/drgnx".into(), "test".into()];
        let mut sel = ev("b", "P", 5.0);
        sel.facts.selector = vordr::facts::selector("", &argv, &env);
        let r = rerun_of(&[sel], "P", top, metas).unwrap();
        assert_eq!(r.env, env);
        assert_eq!(vordr::facts::selector(&r.rel, &r.argv, &r.env), r.selector);
    }
}
