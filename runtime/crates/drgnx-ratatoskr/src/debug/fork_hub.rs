//! Forks in the hub (spec §19.3): each `debug/fork` is a hub object of its own (never `history/fork`), with a tree, a
//! sealed session and a result; the `debug-fork` event follows it, and `debug/fork/drop` removes it.
//!
//! - A fork's tree is a folder of its own under the runs root (`<state>/hub/runs/debug-forks/<fork>/w`) with the
//!   run's launch snapshot restored into it. A code what-if is made in two calls: the first stops at `editing` with
//!   the tree's path (the editor opens it), the second (`resume`) runs it.
//! - The configuration is resolved again for the user's project now, and its hash must equal the run's; then it is
//!   moved into the tree ([`super::fork::for_tree`]). Its environment's values reach the adapter's launch, and the
//!   project's `.env` files are bound into the tree read-only ([`Sealer`]); neither is stored.
//! - The result compares the fork with the run ([`super::compare`]): "matched on N of M hits" on the stopping thread
//!   before the point, the probes' lanes after it, and how each ended.
//! - Two uses without a fork of their own (no entry, no events): [`Forks::trace`] replays a run to a stop with extra
//!   environment and files in the tree (D3's origin trail), its tree kept until the [`TraceTree`] goes;
//!   [`Forks::run_in`] runs the run's configuration in a tree of the caller's to the end, watching an exception or a
//!   probe (D5's predicates).

use super::compare::{self, Matched};
use super::fork::{self, At, Change, Drive, End, Outcome, Refused, RunEnd, Until, Watch, Watched};
use super::record::{RunInfo, Runs, config_hash};
use super::session::{Request, Start};
use super::{BoxFut, Launcher, Sink};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Where forks' trees come from.
pub trait Trees: Send + Sync {
    /// A tree for fork ID with RUN's launch snapshot restored into it.
    fn make<'a>(&'a self, run: &'a RunInfo, id: &'a str) -> BoxFut<'a, Result<PathBuf, String>>;
    /// The files of TREE (relative names) that differ from the snapshot it was made from: a code what-if's edit.
    fn changed<'a>(&'a self, tree: &'a Path) -> BoxFut<'a, Vec<String>>;
    /// TREE and everything of its fork goes.
    fn remove<'a>(&'a self, tree: &'a Path) -> BoxFut<'a, ()>;
    /// A scratch folder for ID's sandbox (its tmp), outside any tree; [`Trees::remove`] of it takes it away.
    fn scratch(&self, id: &str) -> Result<PathBuf, String>;
}

/// The sealed adapter of a fork.
pub trait Sealer: Send + Sync {
    /// The launcher of ADAPTER (`debugpy`, `js-debug`) in TREE, TMP the sandbox's tmp, RUN's project's `.env`
    /// files bound read-only; CONFIG is the resolved configuration, moved into the tree.
    fn launcher(
        &self,
        adapter: &str,
        run: &RunInfo,
        tree: &Path,
        config: &Value,
        tmp: &Path,
    ) -> Result<Arc<dyn Launcher>, String>;
}

/// A `debug/fork` request, its configuration resolved again for the user's project.
#[derive(Clone, Debug)]
pub struct Ask {
    pub run: String,
    pub at: At,
    pub change: Change,
    pub until: Until,
    /// The user said yes to a slow replay.
    pub confirm: bool,
    /// The user said to fork at this pass anyway (a local differed that may come from an unreplayed source).
    pub anyway: bool,
    pub resolved: Value,
}

/// What `debug/fork` answers: the fork, or what it needs first.
#[derive(Clone, Debug, PartialEq)]
pub enum Made {
    Fork(String),
    /// A question for the user (the replay is slow).
    Ask(String),
}

/// RESOLVED is the configuration RUN ran with (its hash).
fn same_config(run: &RunInfo, resolved: &Value) -> Result<(), String> {
    if run.config_hash.as_deref() != Some(config_hash(resolved).as_str()) {
        return Err(
            "the configuration resolves differently now than at the run (launch.json, an input, a setting or an \
             environment value changed): the fork would not replay the same run"
                .into(),
        );
    }
    Ok(())
}

/// A replay's tree (D3's trace): removed when this goes, never anything outside the forks' root.
pub struct TraceTree {
    pub path: PathBuf,
    trees: Arc<dyn Trees>,
}

impl std::fmt::Debug for TraceTree {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TraceTree")
            .field("path", &self.path)
            .finish()
    }
}

impl Drop for TraceTree {
    fn drop(&mut self) {
        let (trees, path) = (self.trees.clone(), std::mem::take(&mut self.path));
        // outside the hub's runtime (it is stopping) the hub-start sweep takes it
        if tokio::runtime::Handle::try_current().is_ok() {
            crate::clock::spawn("debug:trace-tree", async move { trees.remove(&path).await });
        }
    }
}

/// REL is a relative path inside a tree: no root, no `..`.
fn relative(rel: &str) -> Result<(), String> {
    use std::path::Component;
    let p = Path::new(rel);
    if rel.is_empty() || !p.components().all(|c| matches!(c, Component::Normal(_))) {
        return Err(format!("{rel:?} is not a path inside the tree"));
    }
    Ok(())
}

/// RESOLVED (`env` an object) with VARS added to its environment.
fn with_env(mut config: Value, vars: &[(String, String)]) -> Value {
    if let Value::Object(c) = &mut config {
        let env = c.entry("env").or_insert_with(|| json!({}));
        if let Value::Object(env) = env {
            for (k, v) in vars {
                env.insert(k.clone(), json!(v));
            }
        }
    }
    config
}

struct Entry {
    run: RunInfo,
    ask: Ask,
    tree: Option<PathBuf>,
    view: Value,
}

struct Inner {
    sink: Arc<dyn Sink>,
    runs: Arc<dyn Runs>,
    trees: Arc<dyn Trees>,
    sealer: Arc<dyn Sealer>,
    sealed: bool,
    forks: Mutex<BTreeMap<String, Entry>>,
    next: Mutex<u64>,
}

/// The hub's forks.
#[derive(Clone)]
pub struct Forks {
    inner: Arc<Inner>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Forks {
    /// Forks of RUNS' runs, trees from TREES, sessions sealed by SEALER; SEALED: this host runs them
    /// ([`fork::SEALS_HERE`]).
    pub fn new(
        sink: Arc<dyn Sink>,
        runs: Arc<dyn Runs>,
        trees: Arc<dyn Trees>,
        sealer: Arc<dyn Sealer>,
        sealed: bool,
    ) -> Forks {
        Forks {
            inner: Arc::new(Inner {
                sink,
                runs,
                trees,
                sealer,
                sealed,
                forks: Mutex::new(BTreeMap::new()),
                next: Mutex::new(0),
            }),
        }
    }

    /// Recorded run ID.
    pub fn recorded(&self, id: &str) -> Option<RunInfo> {
        self.inner.runs.run(id)
    }

    /// The fork ASK makes: checked, its tree made and run in the background (`debug-fork` says how it goes).
    pub fn fork(&self, ask: Ask) -> Result<Made, String> {
        let run = self
            .inner
            .runs
            .run(&ask.run)
            .ok_or_else(|| format!("no recorded run {}", ask.run))?;
        match fork::check(&run, &ask.at, self.inner.sealed, ask.confirm) {
            Ok(_) => {}
            Err(Refused::No(why)) => return Err(why),
            Err(Refused::Ask(q)) => return Ok(Made::Ask(q)),
        }
        same_config(&run, &ask.resolved)?;
        let id = self.next_id("f");
        lock(&self.inner.forks).insert(
            id.clone(),
            Entry {
                run,
                ask,
                tree: None,
                view: Value::Null,
            },
        );
        self.publish(&id, json!({"state": "preparing"}));
        let me = self.clone();
        let fid = id.clone();
        crate::clock::spawn("debug:fork", async move { me.prepare(&fid).await });
        Ok(Made::Fork(id))
    }

    /// A new id with PREFIX (`f` a fork, `t` a trace, `r` a plain run's scratch).
    fn next_id(&self, prefix: &str) -> String {
        let mut n = lock(&self.inner.next);
        *n += 1;
        format!("{prefix}{n}")
    }

    /// Run RUN replayed to its stop STOP and ended there (D3's trace): FILES (relative path, bytes) written into the
    /// tree and ENV(the tree's path) added to RESOLVED's environment before the launch. No fork entry, no events.
    pub fn trace<F>(
        &self,
        run: &str,
        stop: u64,
        resolved: Value,
        env: F,
        files: Vec<(String, Vec<u8>)>,
    ) -> BoxFut<'static, Result<TraceTree, String>>
    where
        F: FnOnce(&Path) -> Vec<(String, String)> + Send + 'static,
    {
        let me = self.clone();
        let run_id = run.to_owned();
        Box::pin(async move {
            let run = me
                .inner
                .runs
                .run(&run_id)
                .ok_or_else(|| format!("no recorded run {run_id}"))?;
            match fork::check(&run, &At::Stop(stop), me.inner.sealed, true) {
                Ok(_) => {}
                Err(Refused::No(w) | Refused::Ask(w)) => return Err(w),
            }
            same_config(&run, &resolved)?;
            for (rel, _) in &files {
                relative(rel)?;
            }
            let id = me.next_id("t");
            let tree = me
                .inner
                .trees
                .make(&run, &id)
                .await
                .map_err(|e| format!("the trace's tree: {e}"))?;
            let guard = TraceTree {
                path: tree.clone(),
                trees: me.inner.trees.clone(),
            };
            for (rel, bytes) in files {
                let at = tree.join(&rel);
                if let Some(d) = at.parent() {
                    std::fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
                }
                std::fs::write(&at, bytes).map_err(|e| format!("{}: {e}", at.display()))?;
            }
            let extra = env(&tree);
            let ask = Ask {
                run: run_id,
                at: At::Stop(stop),
                change: Change::Nothing,
                until: Until::Here,
                confirm: true,
                anyway: false,
                resolved,
            };
            me.drive(&run, &ask, &tree, &extra).await?;
            Ok(guard)
        })
    }

    /// Run RUN's configuration (RESOLVED) in the caller's TREE, sealed, to the program's end: WATCH (paths relative to
    /// the project) watched, LIMIT the time box. No fork entry, no events; TREE is neither made nor removed.
    pub fn run_in(
        &self,
        run: &str,
        resolved: Value,
        tree: PathBuf,
        watch: Watch,
        limit: Duration,
    ) -> BoxFut<'static, Result<RunEnd, String>> {
        let me = self.clone();
        let run_id = run.to_owned();
        Box::pin(async move {
            let run = me
                .inner
                .runs
                .run(&run_id)
                .ok_or_else(|| format!("no recorded run {run_id}"))?;
            if !me.inner.sealed {
                return Err("runs in a sealed tree are Linux and macOS only".into());
            }
            if run.request == "attach" {
                return Err(
                    "an attach session cannot be run again: the hub did not start its program"
                        .into(),
                );
            }
            same_config(&run, &resolved)?;
            let ty = resolved
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or(&run.adapter_id)
                .to_owned();
            let adapter = fork::fork_adapter(&ty)?;
            let root = Path::new(&run.root);
            let mut config = fork::for_tree(&resolved, root, &tree);
            if let Some(seed) = run.hash_seed {
                config = with_env(config, &[("PYTHONHASHSEED".into(), seed.to_string())]);
            }
            let in_tree = |rel: &str| tree.join(rel).display().to_string();
            let watch_t = match &watch {
                Watch::Exception { path, line } => {
                    relative(path)?;
                    Watch::Exception {
                        path: in_tree(path),
                        line: *line,
                    }
                }
                Watch::Probe { path, line, expr } => {
                    relative(path)?;
                    Watch::Probe {
                        path: in_tree(path),
                        line: *line,
                        expr: expr.clone(),
                    }
                }
            };
            let id = me.next_id("r");
            let tmp = me.inner.trees.scratch(&id)?;
            let r = async {
                let launcher = me
                    .inner
                    .sealer
                    .launcher(adapter, &run, &tree, &config, &tmp)?;
                fork::watch(Watched {
                    launcher,
                    start: Start {
                        name: format!("Run of {} in {}", run.id, tree.display()),
                        adapter_id: ty,
                        request: Request::Launch,
                        arguments: super::launch::adapter_arguments(&config),
                        breakpoints: vec![],
                        functions: vec![],
                        exception_filters: None,
                    },
                    adapter: adapter.to_owned(),
                    watch: watch_t,
                    limit,
                })
                .await
            }
            .await;
            me.inner.trees.remove(&tmp).await;
            let mut end = r?;
            // the watched place as the caller named it
            if end.exception_at.is_some()
                && let Watch::Exception { path, line } = watch
            {
                end.exception_at = Some((path, line));
            }
            Ok(end)
        })
    }

    /// A code what-if, edited: run it.
    pub fn resume(&self, id: &str) -> Result<(), String> {
        let ready = lock(&self.inner.forks)
            .get(id)
            .map(|e| e.view.get("state") == Some(&json!("editing")))
            .ok_or_else(|| format!("no fork {id}"))?;
        if !ready {
            return Err(format!("fork {id} is not waiting for its edit"));
        }
        // running moves it on at once: a second resume is refused
        if let Some(e) = lock(&self.inner.forks).get_mut(id)
            && let Value::Object(v) = &mut e.view
        {
            v.insert("state".into(), json!("running"));
        }
        let me = self.clone();
        let fid = id.to_owned();
        crate::clock::spawn("debug:fork", async move {
            // the user's edit, before the program writes anything: what Take Fork's Change offers
            let tree = lock(&me.inner.forks).get(&fid).and_then(|e| e.tree.clone());
            if let Some(t) = tree {
                let changed = me.inner.trees.changed(&t).await;
                me.publish(&fid, json!({"changed": changed}));
            }
            me.run(&fid).await
        });
        Ok(())
    }

    /// Fork ID goes, with its tree.
    pub async fn drop_fork(&self, id: &str) -> Result<(), String> {
        let e = lock(&self.inner.forks)
            .remove(id)
            .ok_or_else(|| format!("no fork {id}"))?;
        if let Some(t) = &e.tree {
            self.inner.trees.remove(t).await;
        }
        self.inner.sink.broadcast(
            "debug-fork",
            json!({"fork": id, "run": e.run.id, "state": "dropped"}),
            None,
        );
        Ok(())
    }

    /// Fork B against its run A: the What-if tab's view.
    pub fn compare(&self, a: &str, b: &str) -> Result<Value, String> {
        let forks = lock(&self.inner.forks);
        let e = forks.get(b).ok_or_else(|| format!("no fork {b}"))?;
        if e.run.id != a {
            return Err(format!("fork {b} is of run {}, not {a}", e.run.id));
        }
        Ok(e.view.clone())
    }

    /// Fork ID's view (what `debug-fork` last said of it).
    pub fn view(&self, id: &str) -> Result<Value, String> {
        lock(&self.inner.forks)
            .get(id)
            .map(|e| e.view.clone())
            .ok_or_else(|| format!("no fork {id}"))
    }

    /// Fork ID is agent session AGENT's (D4): its view says so.
    pub fn mark(&self, id: &str, agent: &str) {
        self.publish(id, json!({"agent": agent}));
    }

    /// A partner agent's fix checked (D4): FILES (paths relative to the project, texts) written into a fresh tree of
    /// RUN's launch snapshot, and RUN's configuration (RESOLVED) run there sealed to the end, WATCH watched, LIMIT the
    /// time box ([`Forks::run_in`]).  The tree goes after.
    pub fn check_fix(
        &self,
        run: &str,
        resolved: Value,
        files: &[(String, String)],
        watch: Watch,
        limit: Duration,
    ) -> BoxFut<'static, Result<RunEnd, String>> {
        let me = self.clone();
        let run_id = run.to_owned();
        let files = files.to_vec();
        Box::pin(async move {
            for (rel, _) in &files {
                relative(rel)?;
            }
            let info = me
                .inner
                .runs
                .run(&run_id)
                .ok_or_else(|| format!("no recorded run {run_id}"))?;
            let id = me.next_id("x");
            let tree = me.inner.trees.make(&info, &id).await?;
            let r = async {
                for (rel, text) in &files {
                    let at = tree.join(rel);
                    if let Some(dir) = at.parent() {
                        std::fs::create_dir_all(dir).map_err(|e| format!("{rel}: {e}"))?;
                    }
                    std::fs::write(&at, text).map_err(|e| format!("{rel}: {e}"))?;
                }
                me.run_in(&run_id, resolved, tree.clone(), watch, limit)
                    .await
            }
            .await;
            me.inner.trees.remove(&tree).await;
            r
        })
    }

    /// The forks' ids and runs.
    pub fn list(&self) -> Vec<(String, String)> {
        lock(&self.inner.forks)
            .iter()
            .map(|(k, e)| (k.clone(), e.run.id.clone()))
            .collect()
    }

    /// Fork ID's view, with DATA merged into it, to the editors.
    fn publish(&self, id: &str, data: Value) {
        let view = {
            let mut forks = lock(&self.inner.forks);
            let Some(e) = forks.get_mut(id) else { return };
            if e.view.is_null() {
                e.view = json!({"fork": id, "run": e.run.id, "root": e.run.root});
            }
            if let (Value::Object(v), Value::Object(d)) = (&mut e.view, data) {
                v.extend(d);
            }
            e.view.clone()
        };
        self.inner.sink.broadcast("debug-fork", view, None);
    }

    fn failed(&self, id: &str, why: String) {
        // a landing that may differ only by an unreplayed value: the user may fork at this pass anyway
        let anyway = why.contains(fork::MAY_BE_UNREPLAYED);
        self.publish(
            id,
            json!({"state": "failed", "error": why, "anyway": anyway}),
        );
    }

    async fn prepare(&self, id: &str) {
        let Some(run) = lock(&self.inner.forks).get(id).map(|e| e.run.clone()) else {
            return;
        };
        let tree = match self.inner.trees.make(&run, id).await {
            Ok(t) => t,
            Err(e) => return self.failed(id, format!("the fork's tree: {e}")),
        };
        let code = {
            let mut forks = lock(&self.inner.forks);
            let Some(e) = forks.get_mut(id) else { return };
            e.tree = Some(tree.clone());
            e.ask.change == Change::Code
        };
        if code {
            self.publish(
                id,
                json!({"state": "editing", "tree": tree.display().to_string()}),
            );
            return;
        }
        self.run(id).await;
    }

    async fn run(&self, id: &str) {
        let Some((run, ask, tree)) = lock(&self.inner.forks)
            .get(id)
            .and_then(|e| Some((e.run.clone(), e.ask.clone(), e.tree.clone()?)))
        else {
            return;
        };
        self.publish(
            id,
            json!({"state": "running", "tree": tree.display().to_string()}),
        );
        match self.drive(&run, &ask, &tree, &[]).await {
            Ok(view) => self.publish(id, view),
            Err(e) => self.failed(id, e),
        }
    }

    async fn drive(
        &self,
        run: &RunInfo,
        ask: &Ask,
        tree: &Path,
        extra_env: &[(String, String)],
    ) -> Result<Value, String> {
        let target = match fork::check(run, &ask.at, self.inner.sealed, true) {
            Ok(t) => t,
            Err(Refused::No(w) | Refused::Ask(w)) => return Err(w),
        };
        let ty = ask
            .resolved
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or(&run.adapter_id)
            .to_owned();
        let adapter = fork::fork_adapter(&ty)?;
        let root = Path::new(&run.root);
        let mut config = fork::for_tree(&ask.resolved, root, tree);
        if let Some(seed) = run.hash_seed {
            config = with_env(config, &[("PYTHONHASHSEED".into(), seed.to_string())]);
        }
        let config = with_env(config, extra_env);
        let tmp = tree
            .parent()
            .ok_or("the fork's tree has no folder")?
            .join("tmp");
        let launcher = self
            .inner
            .sealer
            .launcher(adapter, run, tree, &config, &tmp)?;
        let into = |p: &str| fork::into_tree(p, root, tree);
        let mut target_t = target.clone();
        target_t.path = into(&target.path);
        target_t.recorded = target
            .landing
            .and_then(|i| self.inner.runs.capture(&run.id, i));
        // the run's own passes of the line tell which locals change from pass to pass
        let passes: Vec<Value> = run
            .stops
            .iter()
            .filter(|s| s.path == target.path && s.line == target.line)
            .filter_map(|s| self.inner.runs.capture(&run.id, s.index))
            .collect();
        target_t.varying = fork::varying(&passes);
        target_t.anyway = ask.anyway;
        let probes: Vec<_> = run
            .probes
            .iter()
            .map(|p| {
                let mut p = p.clone();
                p.path = into(&p.path);
                p
            })
            .collect();
        let after_point = |seq: u64| target.seq.is_none_or(|t| seq > t);
        let mut later: Vec<(String, u32)> = vec![];
        for s in run
            .stops
            .iter()
            .filter(|s| s.bp_hit.is_some() && after_point(s.index))
        {
            let k = (into(&s.path), s.line);
            if !later.contains(&k) {
                later.push(k);
            }
        }
        let start = Start {
            name: format!("What if: {}", run.id),
            adapter_id: ty,
            request: Request::Launch,
            arguments: super::launch::adapter_arguments(&config),
            breakpoints: vec![],
            functions: vec![],
            exception_filters: None,
        };
        let out = fork::drive(Drive {
            launcher,
            start,
            adapter: adapter.to_owned(),
            target: target_t,
            probes,
            change: ask.change.clone(),
            until: ask.until.clone(),
            later,
        })
        .await?;
        Ok(self.render(run, &target, &out, root, tree))
    }

    /// The What-if tab's view of OUT, paths shown in the user's project.
    fn render(
        &self,
        run: &RunInfo,
        target: &fork::Target,
        out: &Outcome,
        root: &Path,
        tree: &Path,
    ) -> Value {
        let back = |p: &str| fork::from_tree(p, root, tree);
        let (then_before, then_after): (Vec<_>, Vec<_>) = match target.seq {
            Some(s) => run.hits.iter().cloned().partition(|h| h.seq < s),
            // a point the run never stopped at: its hits are compared as far as the fork's go
            None => {
                let n = out.before.len();
                let mut b = run.hits.clone();
                let a = b.split_off(n.min(b.len()));
                (b, a)
            }
        };
        let m: Matched = compare::matched(&then_before, &out.before, out.thread.as_deref());
        let lanes: Vec<Value> = compare::lanes(&run.probes, &then_after, &out.after)
            .into_iter()
            .map(|l| json!({"probe": l.probe, "then": l.then, "now": l.now}))
            .collect();
        // how the run went on from its point: its next stop, else its end
        let then_end = target
            .seq
            .and_then(|s| run.stops.iter().find(|x| x.index > s))
            .map(|s| json!({"kind": "stop", "path": s.path, "line": s.line, "reason": s.reason}));
        let now_end = match &out.end {
            End::Stop {
                path,
                line,
                reason,
                locals,
            } => {
                json!({"kind": "stop", "path": back(path), "line": line, "reason": reason, "locals": locals})
            }
            End::Probe { probe, value } => json!({"kind": "probe", "probe": probe, "value": value}),
            End::Exit { code } => json!({"kind": "exit", "code": code}),
        };
        json!({
            "state": "done",
            "at": {"path": back(&out.at.0), "line": out.at.1, "hit": target.hit, "steps": target.steps},
            "matched": {"matched": m.matched, "of": m.of, "first": m.first.map(|f| json!({
                "probe": f.probe, "hit": f.hit, "then": f.then, "now": f.now}))},
            "applied": out.applied,
            "lanes": lanes,
            "then": then_end,
            "now": now_end,
        })
    }
}
