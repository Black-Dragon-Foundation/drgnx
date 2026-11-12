//! The bisect's methods (runstav `methods::debug_bisect`, spec §19.6) and the states it runs: commits (their trees),
//! launch snapshots (their kept trees) and the edit history's saves and agent steps (the branch's base commit with
//! every document as it was after the record), each written as a tree into a bisect's own shadow repository, which
//! borrows the objects of the project's repository and of its snapshots (`objects/info/alternates`): nothing is
//! copied, and no state touches the disk until a slot runs it.  The predicate runs as sealed jobs (`exec::start_sealed`:
//! an agent's sandbox, the slot its only writable folder), one per state, in the slot's folder.

use super::bisect::{self, Bisect, Canceller, Candidate, Ending, Found, Outcome, Prober, Stage};
use crate::dispatch::Caller;
use crate::exec::JobEvent;
use crate::front::Front;
use crate::timeline::snapshot::{repo_of, run_git};
use runstav::methods::Params;
use runstav::methods::debug_bisect::{
    DebugBisect, DebugBisectId, DebugBisectStarted, DebugBisectState, DebugBisectStateList,
    DebugBisectStates, DebugPredicate,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};

fn err(code: ErrorCode, message: impl Into<String>) -> Error {
    Error {
        code,
        message: message.into(),
        path: None,
    }
}

fn invalid(message: impl Into<String>) -> Error {
    err(ErrorCode::InvalidParams, message)
}

/// A state before its tree is written.
#[derive(Clone, Debug)]
pub struct Pending {
    pub cand: Candidate,
    pub make: Make,
}

/// How a state's tree is made.
#[derive(Clone, Debug)]
pub enum Make {
    /// A tree the alternates already hold (a commit's, a launch snapshot's).
    Tree(String),
    /// BASE (a commit, none: empty) with each `(path, text)` written over it.
    Texts {
        base: Option<String>,
        texts: Vec<(String, String)>,
    },
}

/// The bisect's shadow repository for the staging folder SOURCE under ROOT, made with alternates OBJECTS.  Blocking.
pub fn stage_repo(root: &Path, source: &Path, objects: &[PathBuf]) -> Result<PathBuf, String> {
    let repo = repo_of(root, source);
    std::fs::create_dir_all(source).map_err(|e| format!("{}: {e}", source.display()))?;
    std::fs::create_dir_all(&repo).map_err(|e| format!("{}: {e}", repo.display()))?;
    if !repo.join("HEAD").exists() {
        run_git(&repo, None, None, &["init", "--bare", "-q"])?;
    }
    let info = repo.join("objects").join("info");
    std::fs::create_dir_all(&info).map_err(|e| e.to_string())?;
    let mut text = String::new();
    for o in objects.iter().filter(|o| o.is_dir()) {
        text.push_str(&o.to_string_lossy());
        text.push('\n');
    }
    std::fs::write(info.join("alternates"), text).map_err(|e| e.to_string())?;
    Ok(repo)
}

/// Each pending state's tree written into REPO: the candidates, a state whose tree equals the one before it dropped
/// (nothing to run).  Blocking.
pub fn materialise(repo: &Path, pending: Vec<Pending>) -> Result<Vec<Candidate>, String> {
    let index = repo.join("bisect-index");
    let git = |args: &[&str]| run_git(repo, None, Some(&index), args);
    let mut out: Vec<Candidate> = Vec::new();
    let mut base_modes: HashMap<String, HashMap<String, String>> = HashMap::new();
    for p in pending {
        let tree = match p.make {
            Make::Tree(t) => t,
            Make::Texts { base, texts } => {
                let _ = std::fs::remove_file(&index);
                let modes = match &base {
                    Some(b) => {
                        git(&["read-tree", b])?;
                        base_modes
                            .entry(b.clone())
                            .or_insert_with(|| modes_of(repo, b))
                            .clone()
                    }
                    None => {
                        git(&["read-tree", "--empty"])?;
                        HashMap::new()
                    }
                };
                for (path, text) in texts {
                    let blob = hash_text(repo, &text)?;
                    let mode = modes.get(&path).map_or("100644", String::as_str);
                    let info = format!("{mode},{blob},{path}");
                    git(&["update-index", "--add", "--cacheinfo", &info])?;
                }
                git(&["write-tree"])?
            }
        };
        if out.last().is_some_and(|c| c.tree == tree) {
            continue;
        }
        out.push(Candidate { tree, ..p.cand });
    }
    let _ = std::fs::remove_file(&index);
    Ok(out)
}

/// Each regular file's mode in tree-ish BASE of REPO, by path.
fn modes_of(repo: &Path, base: &str) -> HashMap<String, String> {
    run_git(
        repo,
        None,
        None,
        &["ls-tree", "-r", "-z", "--full-tree", base],
    )
    .unwrap_or_default()
    .split('\0')
    .filter_map(|l| {
        let (meta, path) = l.split_once('\t')?;
        Some((path.to_owned(), meta.split(' ').next()?.to_owned()))
    })
    .collect()
}

/// TEXT written into REPO as a blob: its id.
fn hash_text(repo: &Path, text: &str) -> Result<String, String> {
    use std::io::Write;
    use std::process::{Command, Stdio};
    let mut c = Command::new("git")
        .env("GIT_DIR", repo)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .current_dir(repo)
        .args(["hash-object", "-w", "--stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("git: {e}"))?;
    c.stdin
        .take()
        .ok_or("git: no stdin")?
        .write_all(text.as_bytes())
        .map_err(|e| format!("git: {e}"))?;
    let out = c.wait_with_output().map_err(|e| format!("git: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_owned());
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// The commits of GIT_DIR after GOOD (a commit) up to HEAD on the first-parent line, oldest first; with no GOOD, the
/// ones made after the time SINCE (the newest [`bisect::STATES_MAX`]).  Blocking.
pub fn commits(git_dir: &Path, good: Option<&str>, since: f64) -> Result<Vec<Pending>, String> {
    let range = good.map(|g| format!("{g}..HEAD"));
    let max = format!("-n{}", bisect::STATES_MAX);
    let mut args = vec![
        "log",
        "--first-parent",
        &max,
        "--format=%H%x09%T%x09%ct%x09%an%x09%s",
    ];
    args.push(range.as_deref().unwrap_or("HEAD"));
    let text = run_git(git_dir, None, None, &args)?;
    let mut v: Vec<Pending> = text
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.splitn(5, '\t').collect();
            let [id, tree, at, author, subject] = f[..] else {
                return None;
            };
            let at: f64 = at.parse().ok()?;
            (good.is_some() || at > since).then(|| Pending {
                cand: Candidate {
                    id: format!("commit-{}", &id[..id.len().min(12)]),
                    kind: "commit".into(),
                    at,
                    label: subject.to_owned(),
                    author: Some(json!({"name": author})),
                    session: None,
                    step: None,
                    decision: None,
                    record: None,
                    tree: String::new(),
                },
                make: Make::Tree(tree.to_owned()),
            })
        })
        .collect();
    v.reverse();
    Ok(v)
}

/// The saves and agent steps of the history HUB's branch for TREE after the time SINCE (AFTER: after that record), each
/// as the branch's base with the documents as they were then.
fn records(
    hub: &crate::history::Hub,
    tree: &crate::history::Tree,
    after: Option<i64>,
    since: f64,
) -> Result<Vec<Pending>, String> {
    use verdandi::{Kind, OpId};
    hub.with(|h| {
        let e = |e: verdandi::Error| e.to_string();
        let Some(branch) = h.find_branch(&tree.branch_name()).map_err(e)? else {
            return Ok(Vec::new());
        };
        let base = h.base_of(branch).map_err(e)?;
        let ops = h
            .records_on(branch, after.map(OpId), &[Kind::Save, Kind::AgentStep])
            .map_err(e)?;
        let mut v = Vec::new();
        for op in ops.into_iter().filter(|o| o.at > since) {
            let texts = h.texts_after(branch, op.id).map_err(e)?;
            let author = h.author_of(op.author).map_err(e)?;
            let label = if op.summary.is_empty() {
                match op.kind {
                    Kind::AgentStep => "an agent's step".to_owned(),
                    _ => "a save".to_owned(),
                }
            } else {
                op.summary.clone()
            };
            v.push(Pending {
                cand: Candidate {
                    id: format!("record-{}", op.id.0),
                    kind: op.kind.as_str().to_owned(),
                    at: op.at,
                    label,
                    author,
                    session: op.cause.session.clone(),
                    step: op.cause.step.clone(),
                    decision: op.cause.decision.clone(),
                    record: Some(op.id.0),
                    tree: String::new(),
                },
                make: Make::Texts {
                    base: base.clone(),
                    texts,
                },
            });
        }
        Ok(v)
    })
}

/// The bisects of this hub, by id (the last ones' results kept for narrowing), and the front once it is in its `Arc`.
#[derive(Default)]
pub struct Bisects {
    front: OnceLock<Weak<Front>>,
    live: Mutex<HashMap<String, Live>>,
    cleared: OnceLock<()>,
}

struct Live {
    root: String,
    /// The ref that keeps now's tree in the project's shadow repository.
    now_ref: Option<String>,
    cancel: Option<Canceller>,
    jobs: Jobs,
    events: Arc<Events>,
    stage: Arc<Stage>,
    found: Option<Found>,
}

impl Bisects {
    pub fn bind(&self, front: &Arc<Front>) {
        let _ = self.front.set(Arc::downgrade(front));
    }

    fn front(&self) -> Option<Arc<Front>> {
        self.front.get()?.upgrade()
    }

    fn live(&self) -> std::sync::MutexGuard<'_, HashMap<String, Live>> {
        self.live
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// The predicate as sealed jobs, one per state, in the state's folder.
#[derive(Clone)]
struct Jobs {
    front: Weak<Front>,
    bisect: String,
    predicate: DebugPredicate,
    running: Arc<Mutex<BTreeSet<String>>>,
}

impl Jobs {
    async fn job(&self, dir: &Path, argv: &[String]) -> Result<Option<i32>, String> {
        let front = self.front.upgrade().ok_or("the hub is stopping")?;
        let mut events = front.core.exec.subscribe();
        // the project's own command over states an agent may have written: an agent's sandbox, the slot its only
        // writable folder (`exec::start_sealed`)
        let params = serde_json::from_value(json!({
            "argv": argv,
            "cwd": dir.to_string_lossy(),
            "timebox_s": self.predicate.timebox_s.unwrap_or(600),
            "name": format!("bisect {}", self.bisect),
        }))
        .map_err(|e| e.to_string())?;
        let sealed = crate::exec::Sealed {
            label: format!("bisect-{}", self.bisect),
            tree: dir.to_owned(),
        };
        let id = crate::exec::start_sealed(&front, &sealed, params)
            .await
            .map_err(|e| e.message)?
            .id;
        drop(front);
        self.running.lock().expect("bisect jobs").insert(id.clone());
        let r = loop {
            match events.recv().await {
                Ok(JobEvent::Done(d)) if d.id == id => break Ok(d.exit),
                Ok(_) => {}
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                    let ended = self
                        .front
                        .upgrade()
                        .and_then(|f| f.core.exec.get(&id))
                        .is_none_or(|r| r.ended.is_some());
                    if ended {
                        break Err("its end was missed".to_owned());
                    }
                }
                Err(_) => break Err("the hub is stopping".to_owned()),
            }
        };
        self.running.lock().expect("bisect jobs").remove(&id);
        r
    }
}

impl Prober for Jobs {
    fn run(&self, dir: &Path) -> super::BoxFut<'static, Outcome> {
        let me = self.clone();
        let dir = dir.to_owned();
        Box::pin(async move {
            let p = &me.predicate;
            if !p.build.is_empty() {
                match me.job(&dir, &p.build).await {
                    Ok(Some(0)) => {}
                    Ok(c) => return Outcome::Skip(format!("it does not build (exit {c:?})")),
                    Err(e) => return Outcome::Skip(e),
                }
            }
            match (p.kind.as_str(), me.job(&dir, &p.argv).await) {
                (_, Err(e)) => Outcome::Skip(e),
                ("exit", Ok(Some(125))) => Outcome::Skip("the predicate said skip (125)".into()),
                ("exit", Ok(Some(c))) if Some(c) == p.code => Outcome::Bad,
                ("exit", Ok(Some(_))) => Outcome::Good,
                (_, Ok(c)) => Outcome::of_exit(c),
            }
        })
    }

    fn cancel(&self) {
        let ids: Vec<String> = std::mem::take(&mut *self.running.lock().expect("bisect jobs"))
            .into_iter()
            .collect();
        let Some(front) = self.front.upgrade() else {
            return;
        };
        crate::clock::spawn("debug:bisect-stop", async move {
            for id in ids {
                let _ = front.core.exec.stop(&id).await;
            }
        });
    }
}

/// The `debug-bisect` events, to every editor, each with the card (`rows`) of the bisect's state so far.
struct Events {
    editors: Arc<crate::settings::agents::Editors>,
    card: Mutex<Value>,
}

impl Events {
    fn new(editors: Arc<crate::settings::agents::Editors>) -> Events {
        Events {
            editors,
            card: Mutex::new(Value::Null),
        }
    }
}

impl bisect::Sink for Events {
    fn event(&self, mut v: Value) {
        let rows = {
            let mut card = self
                .card
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            super::bisect_card::merge(&mut card, &v);
            super::bisect_card::rows(&card)
        };
        v["rows"] = serde_json::to_value(rows).unwrap_or(Value::Null);
        self.editors.broadcast("debug-bisect", v);
    }
}

/// Where a hub's bisects keep their folders: `<runs>/debug-forks/slots` (the forks' `slots_root`), the one place in
/// the state folder a sealed job's tree may be.
fn bisect_dir(front: &Front) -> PathBuf {
    crate::sandbox::runs_root(&front.shell_env.paths_env())
        .join("debug-forks")
        .join("slots")
}

fn checkpoints(front: &Front) -> PathBuf {
    runstav::paths::state_dir(&front.shell_env.paths_env())
        .join("hub")
        .join("checkpoints")
}

/// The states of ROOT from GOOD to now, oldest first: the good state, the later ones, and now (the folder as it is);
/// and the object folders their trees are in.
struct Gathered {
    states: Vec<Pending>,
    objects: Vec<PathBuf>,
    /// The ref that keeps now's tree in the project's shadow repository (dropped with the bisect).
    now_ref: Option<String>,
}

async fn gather(
    front: &Front,
    root: &str,
    good: Option<&DebugBisectState>,
    now: Option<&str>,
) -> Result<Gathered, Error> {
    let dirs = front
        .dirs
        .get()
        .ok_or_else(|| err(ErrorCode::Internal, "the store is not open yet"))?;
    let rootp = PathBuf::from(root);
    let (git_dir, common) = crate::history::wire::git_dirs(&rootp)
        .ok_or_else(|| invalid(format!("{root} is not a git worktree")))?;
    let (hub, tree) = front.core.history.of_tree(&dirs.hub, &rootp)?;
    let runs: Vec<super::record::RunMeta> = front
        .debug
        .debug(front)
        .records()
        .map(|r| r.list(root))
        .unwrap_or_default();
    let cp = checkpoints(front);
    let good = good.cloned();
    let now = now.map(str::to_owned);
    let root = root.to_owned();
    let r = crate::clock::blocking(move || -> Result<Gathered, Error> {
        let mut objects = vec![common.join("objects"), repo_of(&cp, &rootp).join("objects")];
        // the good state, and what comes after it
        let (first, since, good_commit, good_record) = match &good {
            None => (None, 0.0, None, None),
            Some(g) => match g.kind.as_str() {
                "commit" => {
                    let id = run_git(
                        &git_dir,
                        None,
                        None,
                        &["rev-parse", "--verify", &format!("{}^{{commit}}", g.id)],
                    )
                    .map_err(|_| invalid(format!("no commit {}", g.id)))?;
                    let mut c = commits(&git_dir, Some(&format!("{id}~1")), 0.0)
                        .or_else(|_| commits(&git_dir, None, 0.0))
                        .map_err(invalid)?
                        .into_iter()
                        .filter(|p| p.cand.id == format!("commit-{}", &id[..12]))
                        .collect::<Vec<_>>();
                    let p = c.pop().ok_or_else(|| {
                        invalid(format!(
                            "commit {} is not on HEAD's first-parent line",
                            g.id
                        ))
                    })?;
                    let at = p.cand.at;
                    (Some(p), at, Some(id), None)
                }
                "run" => {
                    let m = runs
                        .iter()
                        .find(|m| m.id == g.id)
                        .ok_or_else(|| invalid(format!("no recorded run {}", g.id)))?;
                    let p = run_state(m)
                        .ok_or_else(|| invalid(format!("run {} has no launch snapshot", g.id)))?;
                    (Some(p), m.started, None, None)
                }
                _ => {
                    let id: i64 =
                        g.id.parse()
                            .map_err(|_| invalid(format!("no record {}", g.id)))?;
                    let p = records(&hub, &tree, Some(id - 1), f64::MIN)
                        .map_err(invalid)?
                        .into_iter()
                        .find(|p| p.cand.record == Some(id))
                        .ok_or_else(|| {
                            invalid(format!("record {} is not a save or an agent's step", g.id))
                        })?;
                    let at = p.cand.at;
                    (Some(p), at, None, Some(id))
                }
            },
        };
        let mut later = commits(&git_dir, good_commit.as_deref(), since).unwrap_or_default();
        later.extend(records(&hub, &tree, good_record, since).map_err(invalid)?);
        for m in runs.iter().filter(|m| m.started > since) {
            if let Some(p) = run_state(m) {
                later.push(p);
            }
        }
        for m in &runs {
            if let Some(s) = &m.snapshot {
                objects.push(repo_of(&s.checkpoints, &s.source).join("objects"));
            }
        }
        later.sort_by(|a, b| a.cand.at.total_cmp(&b.cand.at));
        let keep = bisect::STATES_MAX - 2;
        if later.len() > keep {
            later.drain(..later.len() - keep);
        }
        let mut states: Vec<Pending> = first.into_iter().collect();
        states.extend(later);
        // now: the folder as it is, kept until the bisect ends
        let mut now_ref = None;
        if let Some(bid) = now {
            let name = format!("refs/drgnx/bisect/{bid}");
            let t = crate::timeline::snapshot::take_kept(&cp, &rootp, "bisect-now", &name)
                .map_err(|e| err(ErrorCode::Internal, e))?;
            now_ref = Some(name);
            states.push(Pending {
                cand: Candidate {
                    id: "now".into(),
                    kind: "now".into(),
                    at: crate::clock::wall_secs(),
                    label: "now".into(),
                    author: None,
                    session: None,
                    step: None,
                    decision: None,
                    record: None,
                    tree: String::new(),
                },
                make: Make::Tree(t),
            });
        }
        objects.sort();
        objects.dedup();
        let _ = root;
        Ok(Gathered {
            states,
            objects,
            now_ref,
        })
    })
    .await
    .map_err(|e| err(ErrorCode::Internal, e.to_string()))??;
    Ok(r)
}

/// A recorded run's launch snapshot as a state.
fn run_state(m: &super::record::RunMeta) -> Option<Pending> {
    let s = m.snapshot.as_ref()?;
    Some(Pending {
        cand: Candidate {
            id: format!("run-{}", m.id),
            kind: "launch".into(),
            at: m.started,
            label: format!("Run {} · {}", m.n, m.name),
            author: None,
            session: None,
            step: None,
            decision: None,
            record: None,
            tree: String::new(),
        },
        make: Make::Tree(s.tree.clone()),
    })
}

async fn states(front: &Front, p: DebugBisectStates) -> Result<DebugBisectStateList, Error> {
    let g = gather(front, &p.root, p.good.as_ref(), None).await?;
    Ok(DebugBisectStateList {
        states: g
            .states
            .iter()
            .map(|s| serde_json::to_value(&s.cand).unwrap_or(Value::Null))
            .collect(),
    })
}

fn new_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    format!(
        "b{:x}{:x}",
        (crate::clock::wall_secs() * 1000.0) as u64,
        NEXT.fetch_add(1, Ordering::Relaxed)
    )
}

async fn start(front: &Front, p: DebugBisect) -> Result<DebugBisectStarted, Error> {
    let bisects = &front.debug.bisects;
    let me = bisects
        .front()
        .ok_or_else(|| err(ErrorCode::Internal, "the hub is not ready for a bisect"))?;
    if bisects
        .live()
        .values()
        .any(|l| l.root == p.root && l.cancel.is_some())
    {
        return Err(invalid(format!("a bisect of {} is running", p.root)));
    }
    let dir = bisect_dir(front);
    // no bisect outlives the hub: what an earlier one left goes
    bisects.cleared.get_or_init(|| {
        let _ = std::fs::remove_dir_all(&dir);
    });
    // a project keeps its last bisect only (narrowing reads it)
    let old: Vec<(String, Live)> = {
        let mut live = bisects.live();
        let ids: Vec<String> = live
            .iter()
            .filter(|(_, l)| l.root == p.root)
            .map(|(k, _)| k.clone())
            .collect();
        ids.into_iter()
            .filter_map(|k| live.remove(&k).map(|l| (k, l)))
            .collect()
    };
    let cp = checkpoints(front);
    for (_, l) in old {
        let (work, cp, root) = (l.stage.work.clone(), cp.clone(), PathBuf::from(&p.root));
        let _ = crate::clock::blocking(move || {
            if let Some(r) = l.now_ref {
                let _ = crate::timeline::snapshot::drop_kept(&cp, &root, &r);
            }
            std::fs::remove_dir_all(work)
        })
        .await;
    }
    let id = new_id();
    let g = gather(front, &p.root, Some(&p.good), Some(&id)).await?;
    let work = dir.join(&id);
    let source = work.join("stage");
    let (objects, pending) = (g.objects, g.states);
    let (w2, s2) = (work.clone(), source.clone());
    let made = crate::clock::blocking(move || {
        let repo = stage_repo(&w2, &s2, &objects)?;
        materialise(&repo, pending)
    })
    .await
    .map_err(|e| err(ErrorCode::Internal, e.to_string()))?;
    let states = made.map_err(|e| err(ErrorCode::Internal, e))?;
    if states.len() < 2 {
        return Err(invalid("nothing changed after the good state"));
    }
    let stage = Stage::new(work.clone(), source, work);
    let jobs = Jobs {
        front: Arc::downgrade(&me),
        bisect: id.clone(),
        predicate: p.predicate.clone(),
        running: Arc::default(),
    };
    let slots = p.parallel.map_or(bisect::SLOTS, |n| n as usize);
    let events = Arc::new(Events::new(front.editors.clone()));
    let b = Bisect::new(
        id.clone(),
        states.clone(),
        stage,
        Arc::new(jobs.clone()),
        events.clone(),
        slots,
    );
    let estimate = b.estimate();
    bisects.live().insert(
        id.clone(),
        Live {
            root: p.root.clone(),
            now_ref: g.now_ref,
            cancel: Some(b.canceller()),
            jobs,
            events,
            stage: b.stage(),
            found: None,
        },
    );
    let bid = id.clone();
    crate::clock::spawn("debug:bisect", async move {
        let end = b.run().await;
        let found = match end {
            Ending::Found(f) => Some(*f),
            _ => None,
        };
        let stage = {
            let mut live = me.debug.bisects.live();
            let Some(l) = live.get_mut(&bid) else { return };
            l.cancel = None;
            l.found = found;
            l.stage.clone()
        };
        // the slots go; the stage's repository stays for narrowing
        let _ = crate::clock::blocking(move || stage.drop_slots()).await;
    });
    Ok(DebugBisectStarted {
        bisect: id,
        states: states
            .iter()
            .map(|s| serde_json::to_value(s).unwrap_or(Value::Null))
            .collect(),
        estimate,
    })
}

fn cancel(front: &Front, p: &DebugBisectId) -> bool {
    let live = front.debug.bisects.live();
    let Some(l) = live.get(&p.bisect) else {
        return false;
    };
    match &l.cancel {
        Some(c) => {
            c.cancel();
            l.jobs.cancel();
            true
        }
        None => false,
    }
}

async fn narrow(front: &Front, p: DebugBisectId) -> Result<bool, Error> {
    let (stage, jobs, found, sink) = {
        let live = front.debug.bisects.live();
        let l = live
            .get(&p.bisect)
            .ok_or_else(|| invalid(format!("no bisect {}", p.bisect)))?;
        let f = l
            .found
            .clone()
            .ok_or_else(|| invalid("the bisect has not found a first bad state"))?;
        (l.stage.clone(), l.jobs.clone(), f, l.events.clone())
    };
    let id = p.bisect.clone();
    crate::clock::spawn("debug:bisect-narrow", async move {
        use bisect::Sink as _;
        let (s2, good, bad) = (
            stage.clone(),
            found.last_good.tree.clone(),
            found.first_bad.tree.clone(),
        );
        let hunks = match crate::clock::blocking(move || s2.hunks(&good, &bad)).await {
            Ok(Ok(h)) => h,
            Ok(Err(e)) => {
                return sink.event(json!({"bisect": id, "state": "narrow-failed", "why": e}));
            }
            Err(e) => {
                return sink
                    .event(json!({"bisect": id, "state": "narrow-failed", "why": e.to_string()}));
            }
        };
        sink.event(json!({"bisect": id, "state": "narrowing", "hunks": hunks.len()}));
        let keep: Vec<usize> = if hunks.len() <= 1 {
            (0..hunks.len()).collect()
        } else {
            let j = jobs.clone();
            bisect::narrow(&stage, &found.last_good.tree, &hunks, move |dir| {
                j.run(&dir)
            })
            .await
        };
        let picked: Vec<Value> = keep
            .iter()
            .map(|i| json!({"path": hunks[*i].path, "hunk": hunks[*i].body}))
            .collect();
        sink.event(json!({"bisect": id, "state": "narrowed", "hunks": picked, "of": hunks.len()}));
    });
    Ok(true)
}

fn answer<T: serde::Serialize>(r: Result<T, Error>) -> Result<Value, Error> {
    r.map(|v| json!(v))
}

/// P served by the bisect's methods, or handed back.
pub async fn serve(
    front: &Front,
    _caller: &Caller,
    p: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    Ok(match p {
        Params::DebugBisect(p) => answer(start(front, p).await),
        Params::DebugBisectCancel(p) => Ok(json!(cancel(front, &p))),
        Params::DebugBisectNarrow(p) => answer(narrow(front, p).await),
        Params::DebugBisectStates(p) => answer(states(front, p).await),
        other => return Err(Box::new(other)),
    })
}
