//! Recorded runs: the configuration's hash, a stop's capture and its cap, the run file (blocks, index, cap), the
//! event order, retention, and a whole run through the hub with a mock adapter (launch snapshot, probes, stops, steps).
use super::record::{self, Launch, Opts, RunMeta, RunSink, Runs};
use super::runfile::{Frame, Reader, RunFile, RunHit, RunStop};
use super::session::{Op, Proc, Request, ScopeVars, Sig, Start, Stop};
use super::{BoxFut, Connected, Debug, Launcher, Opened, Sink, Terminals};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use vor::mock::{Mock, Script};

#[test]
fn the_config_hash_does_not_depend_on_key_order() {
    let a: Value = serde_json::from_str(
        r#"{"type":"debugpy","env":{"A":"1","B":"2"},"args":["x",{"k":1,"j":2}],"name":"n"}"#,
    )
    .unwrap();
    let b: Value = serde_json::from_str(
        r#"{"name":"n","args":["x",{"j":2,"k":1}],"env":{"B":"2","A":"1"},"type":"debugpy"}"#,
    )
    .unwrap();
    assert_eq!(record::config_hash(&a), record::config_hash(&b));
    assert_eq!(record::config_hash(&a).len(), 16);
    // an env value is part of it; array order is
    let mut c = a.clone();
    c["env"]["A"] = json!("9");
    assert_ne!(record::config_hash(&a), record::config_hash(&c));
    let d: Value = serde_json::from_str(
        r#"{"type":"debugpy","env":{"A":"1","B":"2"},"args":[{"k":1,"j":2},"x"],"name":"n"}"#,
    )
    .unwrap();
    assert_ne!(record::config_hash(&a), record::config_hash(&d));
}

fn var(name: &str, size: usize) -> Value {
    json!({"name": name, "value": "x".repeat(size), "variablesReference": 0})
}

fn a_stop(vars: Vec<Vec<Value>>, frames: usize) -> Stop {
    Stop {
        epoch: 1,
        thread: 1,
        reason: "breakpoint".into(),
        description: None,
        all_threads: false,
        threads: vec![json!({"id": 1, "name": "main"})],
        frames: (0..frames)
            .map(|i| json!({"id": i + 1, "name": format!("f{i}"), "line": 10 + i, "source": {"path": "/p/a.py"}}))
            .collect(),
        total_frames: Some(frames as i64),
        exception: None,
        frame: 1,
        scopes: vars
            .into_iter()
            .enumerate()
            .map(|(i, v)| ScopeVars {
                scope: json!({"name": format!("s{i}"), "variablesReference": 100 + i}),
                variables: Some(v),
            })
            .collect(),
    }
}

#[test]
fn a_stop_is_captured_from_what_was_fetched() {
    let c = record::capture(&a_stop(vec![vec![var("a", 3)], vec![var("b", 4)]], 3));
    assert_eq!(c["cut"], 0);
    assert_eq!(c["frames"].as_array().unwrap().len(), 3);
    assert_eq!(c["scopes"][1]["variables"][0]["name"], "b");
    assert_eq!(c["reason"], "breakpoint");
}

#[test]
fn a_capture_is_cut_to_64_kb_from_the_last_scope_first() {
    let locals: Vec<Value> = (0..20).map(|i| var(&format!("l{i}"), 1000)).collect();
    let globals: Vec<Value> = (0..200).map(|i| var(&format!("g{i}"), 1000)).collect();
    let c = record::capture(&a_stop(vec![locals, globals], 50));
    let size = serde_json::to_vec(&c).unwrap().len();
    assert!(size <= record::CAPTURE_MAX, "{size}");
    assert!(c["cut"].as_u64().unwrap() > 0);
    // the locals (the first scope) are whole; the globals were cut
    assert_eq!(c["scopes"][0]["variables"].as_array().unwrap().len(), 20);
    assert!(c["scopes"][1]["variables"].as_array().map_or(0, Vec::len) < 200);
    // the frames stay while variables can go
    assert_eq!(c["frames"].as_array().unwrap().len(), 50);
}

fn stop_frame(index: u64, line: u32) -> Frame {
    Frame::Stop {
        stop: RunStop {
            index,
            t_ms: index,
            reason: "breakpoint".into(),
            thread: 1,
            path: "/p/a.py".into(),
            line,
            bp_hit: Some(1),
            steps: vec![],
            session: "d1".into(),
        },
        capture: json!({"line": line}),
    }
}

/// Text that does not compress: a small LCG's digits.
fn noise(seed: u64, len: usize) -> String {
    let mut x = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
    (0..len)
        .map(|_| {
            x = x
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            char::from(b'!' + ((x >> 33) % 90) as u8)
        })
        .collect()
}

fn hit_frame(seq: u64, value: String) -> Frame {
    Frame::Hit(RunHit {
        probe: "p1".into(),
        thread: "7".into(),
        value,
        seq,
        t_ms: seq,
    })
}

#[test]
fn the_run_file_writes_zstd_blocks_with_an_index() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("r1.drun");
    let mut f = RunFile::create(&p, 64 << 20).unwrap();
    let mut seq = 0;
    for i in 0..3000u64 {
        seq += 1;
        if i % 500 == 0 {
            f.append(stop_frame(seq, i as u32));
        } else {
            f.append(hit_frame(
                seq,
                format!("value {i} {}", "same text ".repeat(10)),
            ));
        }
    }
    f.flush();
    let r = Reader::open(&p).unwrap();
    assert!(r.index.blocks.len() > 1, "{} blocks", r.index.blocks.len());
    // compressed: the file is much smaller than the frames
    let raw: u64 = r.index.blocks.iter().map(|b| u64::from(b.raw)).sum();
    assert!(f.size() * 4 < raw, "{} of {raw}", f.size());
    assert_eq!(r.frames().len(), 3000);
    assert_eq!(r.index.stops.len(), 6);
    assert_eq!(r.index.hits["p1"], 2994);
    // a stop is read from its block
    let (s, c) = r.stop(r.index.stops[3].index).unwrap();
    assert_eq!((s.line, &c["line"]), (1500, &json!(1500)));
    assert!(r.stop(2).is_none());
}

#[test]
fn past_the_cap_the_oldest_hits_go_and_stops_stay() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("r1.drun");
    let cap = 600 * 1024;
    let mut f = RunFile::create(&p, cap).unwrap();
    let mut seq = 0;
    for i in 0..2000u64 {
        seq += 1;
        if i % 100 == 0 {
            f.append(stop_frame(seq, i as u32));
        } else {
            f.append(hit_frame(seq, noise(i, 1000)));
        }
    }
    f.flush();
    assert!(f.size() <= cap, "{} > {cap}", f.size());
    let r = Reader::open(&p).unwrap();
    let frames = r.frames();
    let stops = frames
        .iter()
        .filter(|f| matches!(f, Frame::Stop { .. }))
        .count();
    assert_eq!(stops, 20, "every stop stays");
    assert!(r.index.dropped > 0);
    // the hits kept are the newest: the last one is there, the first is gone
    let hits: Vec<u64> = frames
        .iter()
        .filter_map(|f| match f {
            Frame::Hit(h) => Some(h.seq),
            _ => None,
        })
        .collect();
    assert_eq!(hits.last(), Some(&2000));
    assert!(hits[0] > 2);
    assert_eq!(hits.len() as u64 + r.index.dropped, 1980);
    // every stop is still read from its block
    for s in &r.index.stops {
        assert!(r.stop(s.index).is_some(), "stop {}", s.index);
    }
}

#[test]
fn stops_and_hits_share_one_counter() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("r1.drun");
    let mut f = RunFile::create(&p, 64 << 20).unwrap();
    // hit, hit, stop, hit, stop, hit
    for (seq, is_stop) in [
        (1, false),
        (2, false),
        (3, true),
        (4, false),
        (5, true),
        (6, false),
    ] {
        f.append(if is_stop {
            stop_frame(seq, 1)
        } else {
            hit_frame(seq, format!("{seq}"))
        });
    }
    f.flush();
    let r = Reader::open(&p).unwrap();
    let hits: Vec<RunHit> = r
        .frames()
        .into_iter()
        .filter_map(|f| match f {
            Frame::Hit(h) => Some(h),
            _ => None,
        })
        .collect();
    let before = |k: usize| -> Vec<u64> {
        let at = r.index.stops[k].index;
        hits.iter().filter(|h| h.seq < at).map(|h| h.seq).collect()
    };
    assert_eq!(before(0), [1, 2]);
    assert_eq!(before(1), [1, 2, 4]);
}

/// Every Urdr record put, and every one gone.
#[derive(Default)]
struct Store(Mutex<Vec<RunMeta>>, Mutex<Vec<String>>);

impl RunSink for Store {
    fn put(&self, meta: &RunMeta) {
        self.0.lock().unwrap().push(meta.clone());
    }
    fn gone(&self, id: &str) {
        self.1.lock().unwrap().push(id.to_owned());
    }
}

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
    fn named(&self, name: &str) -> Vec<Value> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.0 == name)
            .map(|e| e.1.clone())
            .collect()
    }
}

fn meta(id: &str, root: &str, ended_days_ago: Option<f64>, now: f64) -> RunMeta {
    RunMeta {
        id: id.into(),
        root: root.into(),
        started: now - 30.0 * 86400.0,
        ended: ended_days_ago.map(|d| now - d * 86400.0),
        ..RunMeta::default()
    }
}

fn put_run(dir: &Path, m: &RunMeta, bytes: usize) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(
        dir.join(format!("{}.json", m.id)),
        serde_json::to_string(m).unwrap(),
    )
    .unwrap();
    std::fs::write(dir.join(format!("{}.drun", m.id)), vec![0u8; bytes]).unwrap();
}

#[tokio::test]
async fn runs_are_kept_14_days_unless_pinned_or_their_task_is_open() {
    let d = tempfile::tempdir().unwrap();
    let runs = d.path().join("runs");
    let now = 2_000_000_000.0;
    let store = Arc::new(Store::default());
    let mut opts = Opts::new(runs.clone(), d.path().join("cp"));
    opts.store = store.clone();
    opts.task_open = Arc::new(|t| Box::pin(async move { t == "task:open" }));
    opts.project_cap = 1000;
    let mut pinned = meta("r-pinned", "/p", Some(20.0), now);
    pinned.pinned = true;
    let mut open = meta("r-open", "/p", Some(20.0), now);
    open.task = Some("task:open".into());
    let mut closed = meta("r-closed", "/p", Some(20.0), now);
    closed.task = Some("task:done".into());
    for (m, b) in [
        (meta("r-old", "/p", Some(15.0), now), 10),
        (meta("r-new", "/p", Some(1.0), now), 10),
        (meta("r-live", "/p", None, now), 10),
        (pinned, 10),
        (open, 10),
        (closed, 10),
    ] {
        put_run(&runs, &m, b);
    }
    let rec = record::Records::new(opts, Arc::new(Events::default()));
    let mut gone = rec.prune(now).await;
    gone.sort();
    assert_eq!(gone, ["r-closed", "r-old"]);
    assert!(!runs.join("r-old.drun").exists() && !runs.join("r-old.json").exists());
    assert!(runs.join("r-new.drun").exists() && runs.join("r-pinned.drun").exists());
    let mut told = store.1.lock().unwrap().clone();
    told.sort();
    assert_eq!(told, ["r-closed", "r-old"]);
}

#[tokio::test]
async fn a_project_past_its_cap_loses_its_oldest_runs() {
    let d = tempfile::tempdir().unwrap();
    let runs = d.path().join("runs");
    let now = 2_000_000_000.0;
    let mut opts = Opts::new(runs.clone(), d.path().join("cp"));
    opts.project_cap = 250;
    for (i, id) in ["r1", "r2", "r3", "r4"].iter().enumerate() {
        let mut m = meta(id, "/p", Some(1.0), now);
        m.started = now - 86400.0 + i as f64;
        put_run(&runs, &m, 100);
    }
    // another project's runs count for it alone
    put_run(&runs, &meta("q1", "/q", Some(1.0), now), 200);
    let rec = record::Records::new(opts, Arc::new(Events::default()));
    let mut gone = rec.prune(now).await;
    gone.sort();
    assert_eq!(gone, ["r1", "r2"]);
}

// A whole run through the hub, with the mock adapter.

struct Exits;

impl Proc for Exits {
    fn signal(&mut self, _: Sig) {}
    fn wait(&mut self) -> BoxFut<'_, ()> {
        Box::pin(async {})
    }
}

struct NoTerms;

impl Terminals for NoTerms {
    fn open(
        &self,
        _: u64,
        _: String,
        _: Vec<String>,
        _: Vec<(String, String)>,
    ) -> BoxFut<'_, Result<Opened, String>> {
        Box::pin(async { Err("no terminals".into()) })
    }
}

#[derive(Default)]
struct Mocks {
    scripts: Mutex<VecDeque<Vec<Value>>>,
    running: Mutex<Vec<Mock>>,
}

impl Launcher for Mocks {
    fn connect(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move {
            let steps = self
                .scripts
                .lock()
                .unwrap()
                .pop_front()
                .ok_or("no script left")?;
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

async fn until(what: &str, mut cond: impl FnMut() -> bool) {
    for _ in 0..2000 {
        if cond() {
            return;
        }
        crate::clock::sleep(Duration::from_millis(5)).await;
    }
    panic!("never happened: {what}");
}

fn stopped(reason: &str, line: u32, path: &str) -> Vec<Value> {
    vec![
        json!({"event": "stopped", "body": {"reason": reason, "threadId": 1}}),
        json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
        json!({"expect": "stackTrace", "ok": {"stackFrames": [{"id": 5, "name": "f", "line": line, "column": 1, "source": {"path": path}}]}}),
        json!({"expect": "scopes", "ok": {"scopes": [{"name": "Locals", "variablesReference": 9}]}}),
        json!({"expect": "variables", "ok": {"variables": [{"name": "shortfall", "value": "16", "variablesReference": 0}]}}),
    ]
}

fn hit(probe: &str, value: &str) -> Value {
    json!({"event": "output", "body": {"category": "console", "output": format!("\u{1e}drgnx:{probe}:140:{value}\n")}})
}

#[tokio::test]
async fn a_run_is_recorded_against_the_files_that_ran() {
    let d = tempfile::tempdir().unwrap();
    let project = d.path().join("proj");
    std::fs::create_dir_all(&project).unwrap();
    let file = project.join("stock.py");
    std::fs::write(&file, "shortfall = 16\nprint(shortfall)\nprint('done')\n").unwrap();
    let other = project.join("other.py");
    std::fs::write(&other, "x = 1\n").unwrap();
    let root = project.to_string_lossy().into_owned();
    let path = file.to_string_lossy().into_owned();

    let ev = Arc::new(Events::default());
    let dbg = Debug::new(ev.clone(), Arc::new(NoTerms));
    let store = Arc::new(Store::default());
    let mut opts = Opts::new(d.path().join("runs"), d.path().join("checkpoints"));
    opts.store = store.clone();
    let rec = dbg.record_into(opts);
    // "Probe the result" of line 1: the probe sits on line 2
    rec.probes(&root, |p| {
        p.apply(super::probes::Op::Result {
            path: path.clone(),
            line: 1,
            expr: "shortfall".into(),
            text: std::fs::read_to_string(&file).unwrap(),
            lang: super::probes::Lang::Python,
        })
        .unwrap()
    });

    let mut script = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true, "supportsLogPoints": true}}),
        json!({"expect": "launch", "args": {"program": path}, "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "setBreakpoints", "args": {"source": {"path": path},
            "breakpoints": [{"line": 2, "logMessage": super::probes::log_message("debugpy", "p1", "shortfall")}]},
            "ok": {"breakpoints": [{"verified": true, "line": 2}]}}),
        json!({"expect": "configurationDone"}),
        hit("p1", "16"),
        json!({"event": "output", "body": {"category": "stdout", "output": "16\n"}}),
        hit("p1", "11"),
    ];
    script.extend(stopped("breakpoint", 3, &path));
    script.push(json!({"expect": "next", "ok": {}}));
    script.extend(stopped("step", 4, &path));
    script.push(hit("p1", "12"));
    script.extend([
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ]);
    let mocks = Arc::new(Mocks {
        scripts: Mutex::new(vec![script].into()),
        ..Mocks::default()
    });
    let start = Start {
        name: "Python: stock".into(),
        adapter_id: "debugpy".into(),
        request: Request::Launch,
        arguments: json!({"program": path}),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    let launch = Launch {
        config_hash: Some("abc".into()),
        start: json!({"root": root, "config": "launch:0"}),
        unsaved: vec![other.to_string_lossy().into_owned()],
        ..Launch::default()
    };
    let id = dbg
        .start_with(7, &root, start, mocks.clone(), launch)
        .await
        .unwrap();
    until("the first stop", || dbg.stop_of(&id).is_some()).await;
    // the file changes on disk after the launch: the run keeps the launch's text
    std::fs::write(&file, "changed\n").unwrap();
    dbg.control(&id, Op::Next { thread: None }).await.unwrap();
    until("the step stop", || {
        dbg.stop_of(&id).is_some_and(|s| s.reason == "step")
    })
    .await;
    until("the last hit", || {
        ev.named("debug-probe-hits")
            .iter()
            .flat_map(|e| e["hits"].as_array().cloned().unwrap_or_default())
            .count()
            == 3
    })
    .await;
    dbg.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    let running = std::mem::take(&mut *mocks.running.lock().unwrap());
    for m in running {
        m.finish().await.unwrap();
    }

    // the record: put at the start and at the end
    let metas = store.0.lock().unwrap().clone();
    let last = metas.last().unwrap();
    assert!(metas.len() >= 2);
    assert_eq!((last.stops, last.hits, last.n), (2, 3, 1));
    assert!(last.ended.is_some());
    assert_eq!(last.config_hash.as_deref(), Some("abc"));
    // the hub picked a PYTHONHASHSEED and kept it
    let seed = last.hash_seed.unwrap();
    assert!(seed > 0);
    let runs = rec.list(&root);
    assert_eq!(runs.len(), 1);
    let run = runs[0].id.clone();

    let info = rec.run(&run).unwrap();
    assert_eq!(info.adapter_id, "debugpy");
    assert_eq!(info.request, "launch");
    assert!(info.snapshot.is_some());
    assert_eq!(info.probes.len(), 1);
    assert_eq!(info.probes[0].line, 2);
    // one counter: hit, hit, stop, stop, hit
    let seqs: Vec<u64> = info.hits.iter().map(|h| h.seq).collect();
    assert_eq!(seqs, [1, 2, 5]);
    assert_eq!(info.hits[0].thread, "140");
    assert_eq!(info.hits[1].value, "11");
    assert_eq!(
        info.stops
            .iter()
            .map(|s| (s.index, s.reason.as_str(), s.line))
            .collect::<Vec<_>>(),
        [(3, "breakpoint", 3), (4, "step", 4)]
    );
    assert_eq!(info.stops[0].bp_hit, Some(1));
    assert_eq!(info.stops[1].steps, ["next"]);
    assert!(info.to_stop_ms.is_some());

    // a past stop: its capture and the file as it ran
    let past = rec.past_stop(&run, 3, None).unwrap();
    assert_eq!(past["capture"]["scopes"][0]["variables"][0]["value"], "16");
    assert_eq!(
        past["source"]["text"],
        "shortfall = 16\nprint(shortfall)\nprint('done')\n"
    );
    assert_eq!(past["source"]["not_what_ran"], false);
    let other_past = rec
        .past_stop(&run, 3, Some(&other.to_string_lossy()))
        .unwrap();
    assert_eq!(other_past["source"]["not_what_ran"], true);
    // the strip: stops and the probe's lane
    let strip = rec.get(&run, 0, 50).unwrap();
    assert_eq!(strip["total"], 2);
    assert_eq!(strip["lanes"][0]["hits"].as_array().unwrap().len(), 3);
    // the events
    let runs_ev = ev.named("debug-run");
    assert_eq!(runs_ev.first().unwrap()["state"], "recording");
    assert_eq!(runs_ev.last().unwrap()["state"], "ended");
    assert!(runs_ev.iter().any(|e| e["stop"]["reason"] == "step"));
}

#[tokio::test]
async fn an_unknown_run_is_refused() {
    let d = tempfile::tempdir().unwrap();
    let rec = record::Records::new(
        Opts::new(d.path().join("runs"), d.path().join("cp")),
        Arc::new(Events::default()),
    );
    assert!(rec.get("../../etc/passwd", 0, 10).is_err());
    assert!(rec.past_stop("r1", 1, None).is_err());
    assert!(rec.run("nope").is_none());
}
