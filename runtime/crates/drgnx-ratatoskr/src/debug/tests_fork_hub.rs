//! Forks as hub objects with fake trees and mock adapters: refusals, the config hash, the `debug-fork` event from
//! preparing to done, a code what-if's two calls, drop, compare, and that environment values are never in an event;
//! a trace (D3) with its injected environment and files; a plain run in a caller's tree (D5) and its time box.
use super::fork::{At, Change, RunEnd, Until, Watch};
use super::fork_hub::{Ask, Forks, Made, Sealer, Trees};
use super::record::{RunHit, RunInfo, RunProbe, RunSnapshot, RunStop, Runs, config_hash};
use super::session::{Proc, Sig};
use super::{BoxFut, Connected, Launcher, Sink};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use vor::mock::{Mock, Script};

#[derive(Default)]
struct Events(Mutex<Vec<(String, Value)>>);

impl Sink for Events {
    fn broadcast(&self, event: &str, data: Value, _: Option<u64>) {
        self.0.lock().unwrap().push((event.to_owned(), data));
    }
    fn send(&self, _: u64, event: &str, data: Value) -> bool {
        self.0.lock().unwrap().push((event.to_owned(), data));
        true
    }
}

impl Events {
    fn forks(&self) -> Vec<Value> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter(|(e, _)| e == "debug-fork")
            .map(|(_, d)| d.clone())
            .collect()
    }
    fn states(&self) -> Vec<String> {
        self.forks()
            .iter()
            .map(|d| d["state"].as_str().unwrap_or("").to_owned())
            .collect()
    }
}

struct OneRun(RunInfo);

impl Runs for OneRun {
    fn run(&self, id: &str) -> Option<RunInfo> {
        (id == self.0.id).then(|| self.0.clone())
    }
}

/// Trees at `/forks/<id>/w` (nothing on disk), or real folders under `base`.
#[derive(Default)]
struct FakeTrees {
    base: Option<PathBuf>,
    made: Mutex<Vec<String>>,
    removed: Mutex<Vec<PathBuf>>,
}

impl FakeTrees {
    fn root(&self) -> PathBuf {
        self.base.clone().unwrap_or_else(|| PathBuf::from("/forks"))
    }
}

impl Trees for FakeTrees {
    fn make<'a>(&'a self, _: &'a RunInfo, id: &'a str) -> BoxFut<'a, Result<PathBuf, String>> {
        Box::pin(async move {
            self.made.lock().unwrap().push(id.to_owned());
            let w = self.root().join(id).join("w");
            if self.base.is_some() {
                std::fs::create_dir_all(&w).unwrap();
            }
            Ok(w)
        })
    }
    fn scratch(&self, id: &str) -> Result<PathBuf, String> {
        let tmp = self.root().join(id).join("tmp");
        if self.base.is_some() {
            std::fs::create_dir_all(&tmp).unwrap();
        }
        Ok(tmp)
    }
    fn changed<'a>(&'a self, _: &'a Path) -> BoxFut<'a, Vec<String>> {
        Box::pin(async { vec!["stock.py".to_owned()] })
    }
    fn remove<'a>(&'a self, tree: &'a Path) -> BoxFut<'a, ()> {
        Box::pin(async move { self.removed.lock().unwrap().push(tree.to_path_buf()) })
    }
}

struct Exits;

impl Proc for Exits {
    fn signal(&mut self, _: Sig) {}
    fn wait(&mut self) -> BoxFut<'_, ()> {
        Box::pin(async {})
    }
}

/// Mock adapters for the forks, one script each; keeps what each fork's launch was given.
#[derive(Default)]
struct MockSealer {
    scripts: Mutex<VecDeque<Vec<Value>>>,
    configs: Mutex<Vec<Value>>,
    trees: Mutex<Vec<PathBuf>>,
    running: Arc<Mutex<Vec<Mock>>>,
}

struct OneMock {
    script: Mutex<Option<Vec<Value>>>,
    running: Arc<Mutex<Vec<Mock>>>,
}

impl Launcher for OneMock {
    fn connect(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move {
            let steps = self.script.lock().unwrap().take().ok_or("no script")?;
            let script: Script = serde_json::from_value(Value::Array(steps)).unwrap();
            let (a, b) = tokio::io::duplex(1 << 20);
            let (cr, cw) = tokio::io::split(a);
            let (mr, mw) = tokio::io::split(b);
            self.running
                .lock()
                .unwrap()
                .push(Mock::start(script, mr, mw));
            let (client, incoming) = vor::Client::new(cr, cw);
            Ok(Connected {
                client,
                incoming,
                proc: Box::new(Exits),
            })
        })
    }
}

impl Sealer for MockSealer {
    fn launcher(
        &self,
        adapter: &str,
        _: &RunInfo,
        tree: &Path,
        config: &Value,
        tmp: &Path,
    ) -> Result<Arc<dyn Launcher>, String> {
        assert_eq!(adapter, "debugpy");
        // the sandbox's temp is never inside the tree
        assert!(!tmp.starts_with(tree), "{tmp:?} in {tree:?}");
        self.trees.lock().unwrap().push(tree.to_path_buf());
        self.configs.lock().unwrap().push(config.clone());
        Ok(Arc::new(OneMock {
            script: Mutex::new(self.scripts.lock().unwrap().pop_front()),
            running: self.running.clone(),
        }))
    }
}

fn resolved() -> Value {
    json!({"type": "debugpy", "request": "launch", "name": "Stock", "program": "/p/stock.py", "cwd": "/p",
           "env": {"API_TOKEN": "s3cr3t-value"}})
}

fn run() -> RunInfo {
    let hit = |v: &str, seq| RunHit {
        probe: "shortfall".into(),
        thread: "111".into(),
        value: v.into(),
        seq,
        t_ms: 0,
    };
    RunInfo {
        id: "r1".into(),
        root: "/p".into(),
        start: json!({"root": "/p", "config": "launch:0"}),
        config_hash: Some(config_hash(&resolved())),
        adapter_id: "debugpy".into(),
        request: "launch".into(),
        snapshot: Some(RunSnapshot {
            checkpoints: "/c".into(),
            source: "/p".into(),
            tree: "t".into(),
        }),
        hash_seed: Some(1234),
        to_stop_ms: Some(300),
        stops: vec![
            RunStop {
                index: 2,
                t_ms: 100,
                reason: "breakpoint".into(),
                thread: 1,
                path: "/p/stock.py".into(),
                line: 20,
                bp_hit: Some(1),
                steps: vec![],
                session: "d1".into(),
            },
            RunStop {
                index: 5,
                t_ms: 300,
                reason: "breakpoint".into(),
                thread: 1,
                path: "/p/stock.py".into(),
                line: 20,
                bp_hit: Some(2),
                steps: vec![],
                session: "d1".into(),
            },
        ],
        probes: vec![RunProbe {
            id: "shortfall".into(),
            path: "/p/stock.py".into(),
            line: 22,
            expr: "shortfall".into(),
        }],
        hits: vec![hit("16", 3), hit("12", 6), hit("9", 7)],
    }
}

const PY: &str = "/forks/f1/w/stock.py";

/// The fork's adapter: hit 2 of line 20 (one probe hit before), nothing changed, one hit after, the end.
fn script() -> Vec<Value> {
    let stop = || {
        vec![
            json!({"event": "stopped", "body": {"reason": "breakpoint", "threadId": 1}}),
            json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
            json!({"expect": "stackTrace", "ok": {"stackFrames": [{"id": 5, "name": "f", "line": 20, "column": 1, "source": {"path": PY}}]}}),
            json!({"expect": "scopes", "ok": {"scopes": []}}),
        ]
    };
    let out = |v: &str| json!({"event": "output", "body": {"output": format!("\u{1e}drgnx:shortfall:999:{v}\n")}});
    let mut s = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true, "supportsLogPoints": true}}),
        json!({"expect": "launch", "args": {"program": PY, "cwd": "/forks/f1/w", "env": {"PYTHONHASHSEED": "1234"}}, "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "setBreakpoints", "args": {"source": {"path": PY}}, "ok": {"breakpoints": [{"verified": true}, {"verified": true}]}}),
        json!({"expect": "configurationDone"}),
    ];
    s.extend(stop());
    s.push(json!({"expect": "continue", "ok": {}}));
    s.push(out("16"));
    s.extend(stop());
    s.push(json!({"expect": "evaluate", "ok": {"result": "999"}}));
    s.push(json!({"expect": "setBreakpoints", "ok": {"breakpoints": [{"verified": true}]}}));
    s.push(json!({"expect": "continue", "ok": {}}));
    s.push(out("11"));
    s.push(json!({"event": "exited", "body": {"exitCode": 0}}));
    s.push(json!({"event": "terminated"}));
    s.push(json!({"expect": "disconnect", "ok": {}}));
    s.push(json!({"die": true}));
    s
}

fn setup(scripts: Vec<Vec<Value>>) -> (Forks, Arc<Events>, Arc<FakeTrees>, Arc<MockSealer>) {
    let ev = Arc::new(Events::default());
    let trees = Arc::new(FakeTrees::default());
    let sealer = Arc::new(MockSealer {
        scripts: Mutex::new(scripts.into()),
        ..Default::default()
    });
    let f = Forks::new(
        ev.clone(),
        Arc::new(OneRun(run())),
        trees.clone(),
        sealer.clone(),
        true,
    );
    (f, ev, trees, sealer)
}

fn ask(change: Change) -> Ask {
    Ask {
        run: "r1".into(),
        at: At::Stop(5),
        change,
        until: Until::Exit,
        confirm: false,
        anyway: false,
        resolved: resolved(),
    }
}

async fn until(mut cond: impl FnMut() -> bool) {
    for _ in 0..10_000 {
        if cond() {
            return;
        }
        crate::clock::sleep(Duration::from_millis(1)).await;
    }
    panic!("never happened");
}

#[tokio::test(start_paused = true)]
async fn what_is_refused_and_what_asks() {
    let (f, ev, _, _) = setup(vec![]);
    let mut a = ask(Change::Nothing);
    a.run = "nope".into();
    assert!(f.fork(a).unwrap_err().contains("no recorded run"));
    // the configuration resolves differently now: refused
    let mut a = ask(Change::Nothing);
    a.resolved["program"] = json!("/p/other.py");
    assert!(f.fork(a).unwrap_err().contains("differently"));
    assert!(ev.forks().is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_slow_point_asks_before_anything_is_made() {
    let mut r = run();
    r.stops[1].t_ms = 90_000;
    let ev = Arc::new(Events::default());
    let trees = Arc::new(FakeTrees::default());
    let f = Forks::new(
        ev.clone(),
        Arc::new(OneRun(r)),
        trees.clone(),
        Arc::new(MockSealer::default()),
        true,
    );
    let Made::Ask(q) = f.fork(ask(Change::Nothing)).unwrap() else {
        panic!("made");
    };
    assert!(q.contains("90 s"), "{q}");
    assert!(trees.made.lock().unwrap().is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_fork_goes_from_preparing_to_done_with_its_comparison() {
    let (f, ev, _, sealer) = setup(vec![script()]);
    let Made::Fork(id) = f.fork(ask(Change::Nothing)).unwrap() else {
        panic!("asked");
    };
    assert_eq!(id, "f1");
    until(|| ev.states().last().map(String::as_str) == Some("done")).await;
    assert_eq!(ev.states(), ["preparing", "running", "done"]);
    let v = ev.forks().pop().unwrap();
    // the run's hits before stop 5: one ("16"), matched; after it: "12", "9" then, "11" now
    assert_eq!(v["matched"], json!({"matched": 1, "of": 1, "first": null}));
    assert_eq!(
        v["lanes"],
        json!([{"probe": "shortfall", "then": ["12", "9"], "now": ["11"]}])
    );
    assert_eq!(v["at"]["path"], json!("/p/stock.py"));
    assert_eq!(v["now"], json!({"kind": "exit", "code": 0}));
    assert_eq!(v["root"], json!("/p"));
    assert_eq!(f.compare("r1", "f1").unwrap(), v);
    assert!(f.compare("r2", "f1").is_err());
    // the launch ran in the tree, with the run's hash seed
    let c = sealer.configs.lock().unwrap()[0].clone();
    assert_eq!(c["program"], json!(PY));
    assert_eq!(c["env"]["PYTHONHASHSEED"], json!("1234"));
    // an environment value reaches the launch, never an event
    assert_eq!(c["env"]["API_TOKEN"], json!("s3cr3t-value"));
    assert!(
        !ev.0
            .lock()
            .unwrap()
            .iter()
            .any(|(_, d)| d.to_string().contains("s3cr3t")),
        "an environment value is in an event"
    );
    let mocks: Vec<Mock> = std::mem::take(&mut *sealer.running.lock().unwrap());
    for m in mocks {
        m.finish().await.unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn a_code_what_if_waits_for_its_edit_then_runs() {
    let (f, ev, trees, sealer) = setup(vec![script()]);
    let Made::Fork(id) = f.fork(ask(Change::Code)).unwrap() else {
        panic!("asked");
    };
    until(|| ev.states().last().map(String::as_str) == Some("editing")).await;
    assert_eq!(ev.forks().last().unwrap()["tree"], json!("/forks/f1/w"));
    assert!(
        sealer.configs.lock().unwrap().is_empty(),
        "ran before the edit"
    );
    f.resume(&id).unwrap();
    assert!(f.resume(&id).is_err(), "resumed twice");
    until(|| ev.states().last().map(String::as_str) == Some("done")).await;
    // what the edit changed, measured before it ran
    assert_eq!(ev.forks().last().unwrap()["changed"], json!(["stock.py"]));
    assert!(f.resume(&id).is_err(), "a done fork resumed");
    f.drop_fork(&id).await.unwrap();
    assert_eq!(
        *trees.removed.lock().unwrap(),
        [PathBuf::from("/forks/f1/w")]
    );
    assert_eq!(ev.states().last().map(String::as_str), Some("dropped"));
    assert!(f.list().is_empty());
}

fn setup_in(
    scripts: Vec<Vec<Value>>,
    base: &Path,
) -> (Forks, Arc<Events>, Arc<FakeTrees>, Arc<MockSealer>) {
    let ev = Arc::new(Events::default());
    let trees = Arc::new(FakeTrees {
        base: Some(base.to_path_buf()),
        ..Default::default()
    });
    let sealer = Arc::new(MockSealer {
        scripts: Mutex::new(scripts.into()),
        ..Default::default()
    });
    let f = Forks::new(
        ev.clone(),
        Arc::new(OneRun(run())),
        trees.clone(),
        sealer.clone(),
        true,
    );
    (f, ev, trees, sealer)
}

/// A stop of thread 1 at PATH:LINE (REASON), as the session reads it.
fn stop_at(path: &str, line: u32, reason: &str) -> Vec<Value> {
    vec![
        json!({"event": "stopped", "body": {"reason": reason, "threadId": 1}}),
        json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
        json!({"expect": "stackTrace", "ok": {"stackFrames": [{"id": 5, "name": "f", "line": line, "column": 1, "source": {"path": path}}]}}),
        json!({"expect": "scopes", "ok": {"scopes": []}}),
    ]
}

#[tokio::test(start_paused = true)]
async fn a_trace_reaches_its_stop_with_the_env_and_files_it_was_given() {
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().to_path_buf();
    let tree = base.join("t1").join("w");
    let py = tree.join("stock.py").display().to_string();
    let origin = tree.join(".drgnx-origin").display().to_string();
    // the program gets the injected value, the tree's own path in it, with the run's seed
    let mut s = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true, "supportsLogPoints": true}}),
        json!({"expect": "launch", "args": {"program": py, "env": {"PYTHONHASHSEED": "1234", "PYTHONPATH": origin}}, "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "setBreakpoints", "args": {"source": {"path": py}}, "ok": {"breakpoints": [{"verified": true}, {"verified": true}]}}),
        json!({"expect": "configurationDone"}),
    ];
    // stop 2 of the run: line 20's first pass; the trace ends there
    s.extend(stop_at(&py, 20, "breakpoint"));
    s.push(json!({"expect": "evaluate", "ok": {"result": "999"}}));
    s.push(json!({"expect": "disconnect", "ok": {}}));
    s.push(json!({"die": true}));
    let (f, ev, trees, sealer) = setup_in(vec![s], &base);
    let g = f
        .trace(
            "r1",
            2,
            resolved(),
            |t: &Path| {
                vec![(
                    "PYTHONPATH".into(),
                    t.join(".drgnx-origin").display().to_string(),
                )]
            },
            vec![(
                ".drgnx-origin/sitecustomize.py".into(),
                b"import tracer\n".to_vec(),
            )],
        )
        .await
        .unwrap();
    assert_eq!(g.path, tree);
    assert_eq!(
        std::fs::read(tree.join(".drgnx-origin/sitecustomize.py")).unwrap(),
        b"import tracer\n"
    );
    let config = sealer.configs.lock().unwrap()[0].clone();
    assert_eq!(config["env"]["PYTHONPATH"], json!(origin));
    // the user's environment values still reach it; no fork entry, no event
    assert_eq!(config["env"]["API_TOKEN"], json!("s3cr3t-value"));
    assert!(ev.forks().is_empty());
    assert!(f.list().is_empty());
    // the tree goes with the guard
    drop(g);
    until(|| trees.removed.lock().unwrap().contains(&tree)).await;
    // a file outside the tree is refused before anything is made
    let e = f
        .trace(
            "r1",
            2,
            resolved(),
            |_: &Path| vec![],
            vec![("../x".into(), vec![])],
        )
        .await
        .unwrap_err();
    assert!(e.contains("inside the tree"), "{e}");
    assert_eq!(*trees.made.lock().unwrap(), ["t1"]);
    // a configuration resolved differently is refused too
    let mut r = resolved();
    r["program"] = json!("/p/other.py");
    let e = f
        .trace("r1", 2, r, |_: &Path| vec![], vec![])
        .await
        .unwrap_err();
    assert!(e.contains("differently"), "{e}");
}

/// A plain run's adapter: launch in TREE, then BODY, then the session's end.
fn plain(tree: &Path, caps: Value, configure: Vec<Value>, body: Vec<Value>) -> Vec<Value> {
    let py = tree.join("stock.py").display().to_string();
    let mut s = vec![
        json!({"expect": "initialize", "ok": caps}),
        json!({"expect": "launch", "args": {"program": py, "env": {"PYTHONHASHSEED": "1234"}}, "ok": {}}),
        json!({"event": "initialized"}),
    ];
    s.extend(configure);
    s.push(json!({"expect": "configurationDone"}));
    s.extend(body);
    s
}

#[tokio::test(start_paused = true)]
async fn a_plain_run_finds_the_watched_exception_and_runs_past_others() {
    let dir = tempfile::tempdir().unwrap();
    let slot = dir.path().join("slots/b1/slot-1");
    std::fs::create_dir_all(&slot).unwrap();
    let py = slot.join("stock.py").display().to_string();
    let mut body = stop_at(&py, 9, "exception");
    body.push(json!({"expect": "continue", "ok": {}}));
    body.extend(stop_at(&py, 30, "exception"));
    body.push(json!({"expect": "disconnect", "ok": {}}));
    body.push(json!({"die": true}));
    let s = plain(
        &slot,
        json!({"supportsConfigurationDoneRequest": true,
               "exceptionBreakpointFilters": [{"filter": "raised", "label": "Raised"}]}),
        vec![
            json!({"expect": "setExceptionBreakpoints", "args": {"filters": ["raised"]}, "ok": {}}),
        ],
        body,
    );
    let (f, ev, trees, sealer) = setup_in(vec![s], dir.path());
    let end = f
        .run_in(
            "r1",
            resolved(),
            slot.clone(),
            Watch::Exception {
                path: "stock.py".into(),
                line: 30,
            },
            Duration::from_secs(60),
        )
        .await
        .unwrap();
    assert_eq!(
        end,
        RunEnd {
            exception_at: Some(("stock.py".into(), 30)),
            ..RunEnd::default()
        }
    );
    // the caller's tree is used as it is: neither made nor removed; the temp beside it goes
    assert_eq!(*sealer.trees.lock().unwrap(), vec![slot]);
    assert!(trees.made.lock().unwrap().is_empty());
    assert_eq!(*trees.removed.lock().unwrap(), [dir.path().join("r1/tmp")]);
    assert!(ev.forks().is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_plain_run_returns_a_probes_values_and_its_exit() {
    let dir = tempfile::tempdir().unwrap();
    let slot = dir.path().join("slots/b1/slot-2");
    std::fs::create_dir_all(&slot).unwrap();
    let py = slot.join("stock.py").display().to_string();
    let out = |v: &str| json!({"event": "output", "body": {"output": format!("\u{1e}drgnx:watch:1:{v}\n")}});
    let s = plain(
        &slot,
        json!({"supportsConfigurationDoneRequest": true, "supportsLogPoints": true}),
        vec![
            json!({"expect": "setBreakpoints", "args": {"source": {"path": py}}, "ok": {"breakpoints": [{"verified": true}]}}),
        ],
        vec![
            out("16"),
            out("12"),
            json!({"event": "exited", "body": {"exitCode": 3}}),
            json!({"event": "terminated"}),
            json!({"expect": "disconnect", "ok": {}}),
            json!({"die": true}),
        ],
    );
    let (f, _, _, _) = setup_in(vec![s], dir.path());
    let end = f
        .run_in(
            "r1",
            resolved(),
            slot,
            Watch::Probe {
                path: "stock.py".into(),
                line: 22,
                expr: "shortfall".into(),
            },
            Duration::from_secs(60),
        )
        .await
        .unwrap();
    assert_eq!(end.probe_values, ["16", "12"]);
    assert_eq!(end.exit, Some(3));
    assert!(!end.timed_out && end.exception_at.is_none());
}

#[tokio::test(start_paused = true)]
async fn a_plain_run_past_its_time_box_is_timed_out_not_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let slot = dir.path().join("slots/b1/slot-3");
    std::fs::create_dir_all(&slot).unwrap();
    let py = slot.join("stock.py").display().to_string();
    let out = |v: &str| json!({"event": "output", "body": {"output": format!("\u{1e}drgnx:watch:1:{v}\n")}});
    // one value, then the program runs on and on
    let s = plain(
        &slot,
        json!({"supportsConfigurationDoneRequest": true, "supportsLogPoints": true}),
        vec![
            json!({"expect": "setBreakpoints", "args": {"source": {"path": py}}, "ok": {"breakpoints": [{"verified": true}]}}),
        ],
        vec![
            out("7"),
            json!({"expect": "disconnect", "ok": {}}),
            json!({"die": true}),
        ],
    );
    let (f, _, _, _) = setup_in(vec![s], dir.path());
    let end = f
        .run_in(
            "r1",
            resolved(),
            slot,
            Watch::Probe {
                path: "stock.py".into(),
                line: 22,
                expr: "shortfall".into(),
            },
            Duration::from_secs(5),
        )
        .await
        .unwrap();
    assert!(end.timed_out);
    assert_eq!(end.probe_values, ["7"]);
    // a watched path out of the tree is refused
    let e = f
        .run_in(
            "r1",
            resolved(),
            dir.path().join("slots/b1/slot-3"),
            Watch::Exception {
                path: "/etc/passwd".into(),
                line: 1,
            },
            Duration::from_secs(5),
        )
        .await
        .unwrap_err();
    assert!(e.contains("inside the tree"), "{e}");
}

#[test]
fn a_plain_run_takes_only_a_tree_strictly_under_the_slots_root() {
    let dir = tempfile::tempdir().unwrap();
    let slots = dir.path().join("slots");
    let nested = slots.join("b1/narrow/slot-4");
    std::fs::create_dir_all(&nested).unwrap();
    let outside = dir.path().join("elsewhere");
    std::fs::create_dir_all(&outside).unwrap();
    std::os::unix::fs::symlink(&outside, slots.join("b1/out")).unwrap();
    let ok = super::fork_wire::in_slots(&slots, &nested).unwrap();
    assert_eq!(ok, std::fs::canonicalize(&nested).unwrap());
    // the root itself, a link out of it, a path outside, a missing one: refused
    for bad in [
        slots.clone(),
        slots.join("b1/out"),
        outside,
        slots.join("b1/../../elsewhere"),
        slots.join("nope"),
    ] {
        assert!(super::fork_wire::in_slots(&slots, &bad).is_err(), "{bad:?}");
    }
}

/// D4's fix check: the fix's files go into a fresh tree of the run's launch snapshot, the run's configuration runs
/// there to its end with the predicate's watch, and the tree goes; a file outside the tree is refused before anything
/// runs.
#[tokio::test(start_paused = true)]
async fn a_fix_is_run_in_a_fresh_tree_with_its_files() {
    let dir = tempfile::tempdir().unwrap();
    let tree = dir.path().join("x1/w");
    let py = tree.join("stock.py").display().to_string();
    let s = plain(
        &tree,
        json!({"supportsConfigurationDoneRequest": true,
               "exceptionBreakpointFilters": [{"filter": "raised", "label": "Raised"}]}),
        vec![
            json!({"expect": "setExceptionBreakpoints", "args": {"filters": ["raised"]}, "ok": {}}),
        ],
        vec![
            json!({"event": "exited", "body": {"exitCode": 0}}),
            json!({"event": "terminated"}),
            json!({"expect": "disconnect", "ok": {}}),
            json!({"die": true}),
        ],
    );
    let (f, _, trees, _) = setup_in(vec![s], dir.path());
    let files = vec![("stock.py".to_owned(), "fixed = True\n".to_owned())];
    let watch = Watch::Exception {
        path: "stock.py".into(),
        line: 9,
    };
    let end = f
        .check_fix(
            "r1",
            resolved(),
            &files,
            watch.clone(),
            Duration::from_secs(60),
        )
        .await
        .unwrap();
    assert_eq!(
        (end.exit, end.exception_at, end.timed_out),
        (Some(0), None, false)
    );
    assert_eq!(std::fs::read_to_string(&py).unwrap(), "fixed = True\n");
    assert!(trees.removed.lock().unwrap().contains(&tree));
    let bad = vec![("../escape.py".to_owned(), "x".to_owned())];
    let e = f
        .check_fix("r1", resolved(), &bad, watch, Duration::from_secs(60))
        .await
        .unwrap_err();
    assert!(e.contains("not a path inside the tree"), "{e}");
}

/// A fork an agent made says whose it is in its view, which `view` reads back.
#[tokio::test(start_paused = true)]
async fn a_forks_view_names_the_agent_that_made_it() {
    let (f, _, _, _) = setup(vec![]);
    assert!(f.view("f9").unwrap_err().contains("no fork f9"));
    let Made::Fork(id) = f.fork(ask(Change::Nothing)).unwrap() else {
        panic!("no fork")
    };
    f.mark(&id, "s1");
    let v = f.view(&id).unwrap();
    assert_eq!(v["agent"], json!("s1"));
}
