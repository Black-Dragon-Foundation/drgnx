//! Forks as hub objects with fake trees and mock adapters: refusals, the config hash, the `debug-fork` event from
//! preparing to done, a code what-if's two calls, drop, compare, and that environment values are never in an event.
use super::fork::{At, Change, Until};
use super::fork_hub::{Ask, Forks, Made, Sealer, Trees};
use super::fork_run::{RunHit, RunInfo, RunProbe, RunSnapshot, RunStop, Runs, config_hash};
use super::session::{Proc, Request, Sig};
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

#[derive(Default)]
struct FakeTrees {
    made: Mutex<Vec<String>>,
    removed: Mutex<Vec<PathBuf>>,
}

impl Trees for FakeTrees {
    fn make<'a>(&'a self, _: &'a RunInfo, id: &'a str) -> BoxFut<'a, Result<PathBuf, String>> {
        Box::pin(async move {
            self.made.lock().unwrap().push(id.to_owned());
            Ok(PathBuf::from(format!("/forks/{id}/w")))
        })
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
        _: &str,
    ) -> Result<Arc<dyn Launcher>, String> {
        assert_eq!(adapter, "debugpy");
        assert!(tree.starts_with("/forks"));
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
    };
    RunInfo {
        id: "r1".into(),
        root: PathBuf::from("/p"),
        start: json!({"root": "/p", "config": "launch:0"}),
        config_hash: config_hash(&resolved()),
        adapter_id: "debugpy".into(),
        request: Request::Launch,
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
