//! Conflict prediction (`docs/develop/coordination.md`, "Predicted conflicts"): when an edit step closes on a file in
//! one agent's worktree and another live worktree of the same repository has that file changed too, the hub merges the
//! two texts from their merge base the way git will (`verdandi::threeway::conflicts`: `git merge-file` in a private
//! temporary folder, no repository, no config) and the clash rules card a pair that will conflict, once per pair.
//!
//! The texts are the files on disk, so uncommitted work counts.  The merge base is read in the main checkout of the
//! repository (the hub's trusted one), never in an agent's tree; a worktree's file is read beneath its folder without
//! following links.  At most one check per (editing session, other session, path) per [`EVERY`] of the hub's clock.
//!
//! [`check`], [`Gate`] and [`Predictions`] are pure; [`Live`] is the hub's shell: it runs the checks as hub jobs and
//! hands the predictions to the pure `clash::scan` (a plan run's through its own clash pass, sessions outside a run
//! through a small [`RunState`] of the two).

use crate::front::Front;
use crate::runner::clash::{self, DiffIndex, RunSession, RunState};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError, Weak};

/// A predicted conflict is looked for at most once per (A, B, path) per this many seconds of the hub's clock.
pub const EVERY: f64 = 30.0;

/// The most (A, B, path) keys and predictions remembered (each table is emptied when full).
const KEPT_MAX: usize = 4096;

/// The largest file a check reads.
const FILE_MAX: u64 = 8 << 20;

/// How many conflicting hunks merging A_TEXT and B_TEXT from MERGE_BASE_TEXT has (0: a clean merge).
pub fn check(merge_base_text: &str, a_text: &str, b_text: &str) -> verdandi::Result<usize> {
    verdandi::threeway::conflicts(merge_base_text, a_text, b_text)
}

/// What a check found: session A's change to PATH (relative to the worktrees) against session B's.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Prediction {
    pub a: String,
    pub b: String,
    pub path: String,
    /// Conflicting hunks; 0: the two merge cleanly.
    pub conflicts: usize,
}

impl Prediction {
    /// The two sessions, in order.
    pub fn pair(&self) -> (&str, &str) {
        if self.a <= self.b {
            (&self.a, &self.b)
        } else {
            (&self.b, &self.a)
        }
    }
}

/// At most one check per (A, B, path) per [`EVERY`].
#[derive(Debug, Default)]
pub struct Gate {
    last: BTreeMap<(String, String, String), f64>,
}

impl Gate {
    /// Whether A's change to PATH is checked against B's now (hub time NOW, seconds); when it is, the time is kept.
    pub fn due(&mut self, a: &str, b: &str, path: &str, now: f64) -> bool {
        let key = (a.to_owned(), b.to_owned(), path.to_owned());
        if self.last.get(&key).is_some_and(|t| now - t < EVERY) {
            return false;
        }
        if self.last.len() >= KEPT_MAX {
            self.last.retain(|_, t| now - *t < EVERY);
        }
        self.last.insert(key, now);
        true
    }
}

/// The latest prediction of each (pair, path).
#[derive(Debug, Default)]
pub struct Predictions {
    by: BTreeMap<(String, String, String), Prediction>,
}

impl Predictions {
    pub fn put(&mut self, p: Prediction) {
        if self.by.len() >= KEPT_MAX {
            self.by.clear();
        }
        let (lo, hi) = p.pair();
        self.by
            .insert((lo.to_owned(), hi.to_owned(), p.path.clone()), p);
    }

    /// The predictions SESSION is in.
    pub fn involving(&self, session: &str) -> Vec<Prediction> {
        self.by
            .values()
            .filter(|p| p.a == session || p.b == session)
            .cloned()
            .collect()
    }

    /// The predictions between two of SESSIONS.
    pub fn among(&self, sessions: &BTreeSet<&str>) -> Vec<Prediction> {
        self.by
            .values()
            .filter(|p| sessions.contains(p.a.as_str()) && sessions.contains(p.b.as_str()))
            .cloned()
            .collect()
    }
}

/// What the clash rules see of two sessions outside a run: both live, running, PREDICTIONS between them, the keys
/// already carded.
pub fn outside_run(
    a: (&str, Option<&str>),
    b: (&str, Option<&str>),
    predictions: Vec<Prediction>,
    carded: &BTreeSet<String>,
) -> RunState {
    let s = |(id, task): (&str, Option<&str>)| RunSession {
        id: id.to_owned(),
        task: task.map(str::to_owned),
        exited: false,
        held: 0,
        held_by_user: false,
    };
    RunState {
        status: "running".into(),
        sessions: vec![s(a), s(b)],
        carded: carded.clone(),
        predictions,
        ..Default::default()
    }
}

// ---- the texts ----

/// Git's answer in MAIN (the trusted main checkout), none when it fails.
fn git(main: &Path, args: &[&str]) -> Option<Vec<u8>> {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(main)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env_remove("GIT_DIR")
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    out.status.success().then_some(out.stdout)
}

/// REL in worktree TREE, read beneath it without following links: "" when it is not there, none when it can't be
/// read (not a regular file, too large, not UTF-8).
fn tree_text(tree: &Path, rel: &str) -> Option<String> {
    use rustix::fs::{Mode, OFlags};
    use std::os::fd::AsFd;
    let dir = rustix::fs::open(
        tree,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .ok()?;
    match eitri::read_regular(dir.as_fd(), Path::new(rel), FILE_MAX) {
        Ok(bytes) => String::from_utf8(bytes).ok(),
        Err(eitri::FsError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => {
            Some(String::new())
        }
        Err(_) => None,
    }
}

/// The three texts of REL: (merge base, A's, B's), for worktrees A and B cut from commits BASE_A and BASE_B of the
/// repository whose main checkout is MAIN.  None when B has not changed REL, A has not, or a text can't be read.
/// Blocking.
pub fn texts(
    main: &Path,
    (a, base_a): (&Path, &str),
    (b, base_b): (&Path, &str),
    rel: &str,
) -> Option<(String, String, String)> {
    let mb = git(main, &["merge-base", base_a, base_b])?;
    let mb = String::from_utf8(mb).ok()?.trim().to_owned();
    let base = match git(main, &["show", &format!("{mb}:{rel}")]) {
        Some(bytes) => String::from_utf8(bytes).ok()?,
        None => String::new(),
    };
    let (at, bt) = (tree_text(a, rel)?, tree_text(b, rel)?);
    (at != base && bt != base).then_some((base, at, bt))
}

// ---- the hub's shell ----

/// Each of TREES' base commits, by its path: the one the hub recorded at its session's start (`work.db`), else the edit
/// history's (the tree's branch base, else its head).  The row is written after the session starts, unordered with the
/// agent's first edit, so a check never waits on it.
pub(crate) async fn bases(front: &Front, trees: Vec<PathBuf>) -> BTreeMap<String, String> {
    let keys: Vec<String> = trees
        .iter()
        .map(|t| t.to_string_lossy().into_owned())
        .collect();
    let mut out = front
        .writer
        .db
        .read(move |c| {
            let mut out = BTreeMap::new();
            for t in keys {
                if let Some(b) = norn::read::work::base(c, &t)?.and_then(|b| b.base_commit) {
                    out.insert(t, b);
                }
            }
            Ok(out)
        })
        .await
        .unwrap_or_default();
    let missing: Vec<PathBuf> = trees
        .into_iter()
        .filter(|t| !out.contains_key(t.to_string_lossy().as_ref()))
        .collect();
    let (Some(dirs), false) = (front.dirs.get(), missing.is_empty()) else {
        return out;
    };
    let (hubs, state) = (front.core.history.clone(), dirs.hub.clone());
    let found = crate::clock::blocking(move || {
        missing
            .into_iter()
            .filter_map(|t| {
                let (hub, tree) = hubs.of_tree(&state, &t).ok()?;
                let base = hub.base_commit(&tree).ok().flatten()?;
                Some((t.to_string_lossy().into_owned(), base))
            })
            .collect::<Vec<_>>()
    })
    .await
    .unwrap_or_default();
    out.extend(found);
    out
}

#[derive(Default)]
struct Inner {
    gate: Gate,
    predictions: Predictions,
    /// Keys of the clashes carded for sessions outside a run (a run keeps its own in its job's data).
    carded: BTreeSet<String>,
}

/// The hub's predictor: the checks it runs and what they found.
#[derive(Default)]
pub struct Live {
    front: OnceLock<Weak<Front>>,
    inner: Mutex<Inner>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// One check to run: the other session, its worktree, its job and task.
struct Other {
    id: String,
    tree: PathBuf,
    job: Option<String>,
    task: Option<String>,
}

impl Live {
    /// From now on the predictor runs its checks in FRONT.
    pub fn bind(&self, front: &Arc<Front>) {
        let _ = self.front.set(Arc::downgrade(front));
    }

    /// The predictions SESSION is in (an escalation's huddle).
    pub fn involving(&self, session: &str) -> Vec<Prediction> {
        lock(&self.inner).predictions.involving(session)
    }

    /// The predictions between two of SESSIONS (a plan run's clash pass).
    pub fn among(&self, sessions: &BTreeSet<&str>) -> Vec<Prediction> {
        lock(&self.inner).predictions.among(sessions)
    }

    /// Session SID's edit step closed on FILE (absolute): check it against every other live worktree of the same
    /// repository that has the file changed, as a hub job.
    pub fn edited(self: &Arc<Self>, sid: &str, file: PathBuf) {
        let Some(front) = self.front.get().and_then(Weak::upgrade) else {
            return;
        };
        let (me, sid) = (self.clone(), sid.to_owned());
        crate::clock::spawn("predict:edited", async move {
            me.run(&front, &sid, &file).await;
        });
    }

    async fn run(&self, front: &Arc<Front>, sid: &str, file: &Path) {
        use runstav::methods::agents::SessionStatus;
        let Some(tree) = front.core.agents.worktree(sid) else {
            return;
        };
        let snaps = front.core.agents.snapshots();
        let Some(mine) = snaps.iter().find(|s| s.id == sid) else {
            return;
        };
        let (job, task) = (mine.job.clone(), mine.task.clone());
        let others: Vec<Other> = snaps
            .iter()
            .filter(|s| s.id != sid && s.status != Some(SessionStatus::Exited))
            .filter_map(|s| {
                Some(Other {
                    id: s.id.clone(),
                    tree: front.core.agents.worktree(&s.id)?,
                    job: s.job.clone(),
                    task: s.task.clone(),
                })
            })
            .filter(|o| o.tree != tree)
            .collect();
        if others.is_empty() {
            return;
        }
        let (file, tree2) = (file.to_owned(), tree.clone());
        // the repository and the path in it, then the others in that repository with a tree of their own
        let Ok(Some((main, rel, others))) = crate::clock::blocking(move || {
            let (_, repo) = crate::work::presence::checkout_of(&file)?;
            let main = crate::work::presence::main_checkout(&file)?;
            let real = std::fs::canonicalize(&tree2).ok()?;
            let rel = file
                .strip_prefix(&real)
                .or_else(|_| file.strip_prefix(&tree2))
                .ok()?
                .to_string_lossy()
                .into_owned();
            let others: Vec<Other> = others
                .into_iter()
                .filter(|o| {
                    crate::work::presence::checkout_of(&o.tree.join(".git"))
                        .is_some_and(|(_, r)| r == repo)
                })
                .collect();
            Some((main, rel, others))
        })
        .await
        else {
            return;
        };
        let now = crate::clock::wall_secs();
        let others: Vec<Other> = {
            let mut g = lock(&self.inner);
            others
                .into_iter()
                .filter(|o| g.gate.due(sid, &o.id, &rel, now))
                .collect()
        };
        if others.is_empty() {
            return;
        }
        // each tree's base commit, as the hub recorded it
        let trees: Vec<PathBuf> = std::iter::once(&tree)
            .chain(others.iter().map(|o| &o.tree))
            .cloned()
            .collect();
        let bases = bases(front, trees).await;
        let Some(my_base) = bases.get(tree.to_string_lossy().as_ref()).cloned() else {
            return;
        };
        for o in others {
            let Some(their_base) = bases.get(o.tree.to_string_lossy().as_ref()).cloned() else {
                continue;
            };
            let (main, a, b, rel2, my_base) = (
                main.clone(),
                tree.clone(),
                o.tree.clone(),
                rel.clone(),
                my_base.clone(),
            );
            let n = crate::clock::blocking(move || {
                let (base, at, bt) = texts(&main, (&a, &my_base), (&b, &their_base), &rel2)?;
                check(&base, &at, &bt).ok()
            })
            .await
            .ok()
            .flatten();
            let Some(conflicts) = n else {
                continue;
            };
            let p = Prediction {
                a: sid.to_owned(),
                b: o.id.clone(),
                path: rel.clone(),
                conflicts,
            };
            lock(&self.inner).predictions.put(p.clone());
            match (&job, &o.job) {
                // both in one plan run: the run's own clash pass cards it, keyed in the job's data
                (Some(j), Some(k)) if j == k => {
                    let _ = crate::runner::tick::clashes(front, j).await;
                }
                _ => {
                    self.outside(front, (sid, task.as_deref()), (&o.id, o.task.as_deref()), p)
                        .await;
                }
            }
        }
    }

    /// The clash rules over two sessions outside a run (or in two runs): each new clash a card of its own, with no job.
    async fn outside(
        &self,
        front: &Arc<Front>,
        a: (&str, Option<&str>),
        b: (&str, Option<&str>),
        p: Prediction,
    ) {
        let found = {
            let mut g = lock(&self.inner);
            let set: BTreeSet<&str> = [p.a.as_str(), p.b.as_str()].into();
            let run = outside_run(a, b, g.predictions.among(&set), &g.carded);
            let found = clash::scan(&run, &[], &DiffIndex::new());
            g.carded.extend(found.iter().map(|c| c.key.clone()));
            found
        };
        for c in &found {
            let _ = card(front, c).await;
        }
        front.core.huddles.clashed(front, None, &found);
    }
}

/// Clash C as a card with no job (a predicted conflict between sessions outside a run), announced as `card`.
async fn card(front: &Front, c: &clash::Clash) -> Result<i64, crate::runner::Error> {
    use norn::write::cards::{NewCard, card_create};
    use serde_json::json;
    let new = NewCard {
        job: None,
        task: c.task.clone(),
        kind: Some("clash".into()),
        title: Some(c.title.clone()),
        data: Some(json!({
            "key": c.key, "rule": c.rule, "subject": c.subject, "sides": c.sides, "files": c.files,
            "lines": c.lines, "size": c.size, "blocks_review": c.blocks_review,
        })),
    };
    let id = front
        .writer
        .write(&crate::runner::service(), "coord/card-create", move |tx| {
            card_create(tx, new, crate::clock::wall_secs())
        })
        .await
        .map_err(|e| crate::runner::invalid(e.to_string()))?;
    front.broadcast(
        "card",
        json!({"id": id, "job": null, "task": c.task, "kind": "clash", "title": c.title}),
    );
    Ok(id)
}

#[cfg(test)]
mod tests;
