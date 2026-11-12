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

use super::compare::{self, Matched};
use super::fork::{self, At, Change, Drive, End, Outcome, Refused, Until};
use super::fork_run::{RunInfo, Runs, config_hash};
use super::session::{Request, Start};
use super::{BoxFut, Launcher, Sink};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// Where forks' trees come from.
pub trait Trees: Send + Sync {
    /// A tree for fork ID with RUN's launch snapshot restored into it.
    fn make<'a>(&'a self, run: &'a RunInfo, id: &'a str) -> BoxFut<'a, Result<PathBuf, String>>;
    /// The files of TREE (relative names) that differ from the snapshot it was made from: a code what-if's edit.
    fn changed<'a>(&'a self, tree: &'a Path) -> BoxFut<'a, Vec<String>>;
    /// TREE and everything of its fork goes.
    fn remove<'a>(&'a self, tree: &'a Path) -> BoxFut<'a, ()>;
}

/// The sealed adapter of a fork.
pub trait Sealer: Send + Sync {
    /// The launcher of ADAPTER (`debugpy`, `js-debug`) for fork ID in TREE, RUN's project's `.env` files bound
    /// read-only; CONFIG is the resolved configuration, moved into the tree.
    fn launcher(
        &self,
        adapter: &str,
        run: &RunInfo,
        tree: &Path,
        config: &Value,
        id: &str,
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
    pub resolved: Value,
}

/// What `debug/fork` answers: the fork, or what it needs first.
#[derive(Clone, Debug, PartialEq)]
pub enum Made {
    Fork(String),
    /// A question for the user (the replay is slow).
    Ask(String),
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
    linux: bool,
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
    /// Forks of RUNS' runs, trees from TREES, sessions sealed by SEALER; LINUX: this host runs them.
    pub fn new(
        sink: Arc<dyn Sink>,
        runs: Arc<dyn Runs>,
        trees: Arc<dyn Trees>,
        sealer: Arc<dyn Sealer>,
        linux: bool,
    ) -> Forks {
        Forks {
            inner: Arc::new(Inner {
                sink,
                runs,
                trees,
                sealer,
                linux,
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
        match fork::check(&run, &ask.at, self.inner.linux, ask.confirm) {
            Ok(_) => {}
            Err(Refused::No(why)) => return Err(why),
            Err(Refused::Ask(q)) => return Ok(Made::Ask(q)),
        }
        if config_hash(&ask.resolved) != run.config_hash {
            return Err(
                "the configuration resolves differently now than at the run (launch.json, an input, a setting or \
                 an environment value changed): the fork would not replay the same run"
                    .into(),
            );
        }
        let id = {
            let mut n = lock(&self.inner.next);
            *n += 1;
            format!("f{n}")
        };
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
                e.view =
                    json!({"fork": id, "run": e.run.id, "root": e.run.root.display().to_string()});
            }
            if let (Value::Object(v), Value::Object(d)) = (&mut e.view, data) {
                v.extend(d);
            }
            e.view.clone()
        };
        self.inner.sink.broadcast("debug-fork", view, None);
    }

    fn failed(&self, id: &str, why: String) {
        self.publish(id, json!({"state": "failed", "error": why}));
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
        match self.drive(id, &run, &ask, &tree).await {
            Ok(view) => self.publish(id, view),
            Err(e) => self.failed(id, e),
        }
    }

    async fn drive(
        &self,
        id: &str,
        run: &RunInfo,
        ask: &Ask,
        tree: &Path,
    ) -> Result<Value, String> {
        let target = match fork::check(run, &ask.at, self.inner.linux, true) {
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
        let root = run.root.as_path();
        let mut config = fork::for_tree(&ask.resolved, root, tree);
        if let (Some(seed), Value::Object(c)) = (run.hash_seed, &mut config) {
            let env = c.entry("env").or_insert_with(|| json!({}));
            if let Value::Object(env) = env {
                env.insert("PYTHONHASHSEED".into(), json!(seed.to_string()));
            }
        }
        let launcher = self
            .inner
            .sealer
            .launcher(adapter, run, tree, &config, id)?;
        let into = |p: &str| fork::into_tree(p, root, tree);
        let mut target_t = target.clone();
        target_t.path = into(&target.path);
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
        Ok(self.view(run, &target, &out, root, tree))
    }

    /// The What-if tab's view of OUT, paths shown in the user's project.
    fn view(
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
