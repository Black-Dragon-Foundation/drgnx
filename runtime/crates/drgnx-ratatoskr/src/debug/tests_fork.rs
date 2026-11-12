//! What-if forks with mock adapters: what can be forked, the configuration moved into the tree, hit counting, the
//! recorded steps, the change, the probes on both sides of the point, js-debug's child sessions.
use super::fork::{self, At, Change, Drive, End, Refused, Target, Until};
use super::record::{RunHit, RunInfo, RunProbe, RunSnapshot, RunStop, config_hash};
use super::session::{Proc, Request, Sig, Start};
use super::{BoxFut, Connected, Launcher};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::path::Path;
use std::sync::{Arc, Mutex};
use vor::mock::{Mock, Script};

struct Exits;

impl Proc for Exits {
    fn signal(&mut self, _: Sig) {}
    fn wait(&mut self) -> BoxFut<'_, ()> {
        Box::pin(async {})
    }
}

/// One mock per connection (the root, then js-debug's children), from a queue of scripts.
#[derive(Default)]
struct Mocks {
    scripts: Mutex<VecDeque<Vec<Value>>>,
    running: Mutex<Vec<Mock>>,
}

impl Mocks {
    fn with(scripts: Vec<Vec<Value>>) -> Arc<Mocks> {
        Arc::new(Mocks {
            scripts: Mutex::new(scripts.into()),
            ..Default::default()
        })
    }
    async fn logs(&self) -> Vec<vor::mock::Log> {
        let ms: Vec<Mock> = std::mem::take(&mut *self.running.lock().unwrap());
        let mut out = vec![];
        for m in ms {
            out.push(m.finish().await.expect("the script played to its end"));
        }
        out
    }
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

const PY: &str = "/f/stock.py";
const THREAD: &str = "__import__('threading').get_ident()";

fn run() -> RunInfo {
    RunInfo {
        id: "r1".into(),
        root: "/p".into(),
        start: json!({"root": "/p", "config": "launch:0"}),
        config_hash: Some("h".into()),
        adapter_id: "debugpy".into(),
        request: "launch".into(),
        snapshot: Some(RunSnapshot {
            checkpoints: "/state/checkpoints".into(),
            source: "/p".into(),
            tree: "abc".into(),
        }),
        hash_seed: Some(7),
        to_stop_ms: Some(400),
        stops: vec![
            stop(3, 100, "breakpoint", 20, Some(1), &[]),
            stop(7, 200, "breakpoint", 20, Some(2), &[]),
            stop(8, 210, "step", 21, None, &["next"]),
            stop(9, 220, "step", 22, None, &["next", "next"]),
            stop(12, 300, "breakpoint", 20, Some(3), &[]),
        ],
        probes: vec![],
        hits: vec![],
    }
}

fn stop(
    index: u64,
    t_ms: u64,
    reason: &str,
    line: u32,
    bp: Option<u32>,
    steps: &[&str],
) -> RunStop {
    RunStop {
        index,
        t_ms,
        reason: reason.into(),
        thread: 1,
        path: "/p/stock.py".into(),
        line,
        bp_hit: bp,
        steps: steps.iter().map(|s| s.to_string()).collect(),
        session: "d1".into(),
    }
}

#[test]
fn attach_runs_and_ptrace_adapters_are_refused_with_the_reason() {
    let mut r = run();
    r.request = "attach".into();
    assert!(
        matches!(fork::check(&r, &At::Stop(3), true, false), Err(Refused::No(m)) if m.contains("attach"))
    );
    for ty in ["go", "lldb-dap"] {
        let mut r = run();
        r.adapter_id = ty.into();
        let Err(Refused::No(m)) = fork::check(&r, &At::Stop(3), true, false) else {
            panic!("{ty} forked");
        };
        assert!(m.contains("ptrace"), "{m}");
    }
    let Err(Refused::No(m)) = fork::check(&run(), &At::Stop(3), false, false) else {
        panic!("forked off Linux");
    };
    assert!(m.contains("Linux"), "{m}");
    let mut r = run();
    r.snapshot = None;
    assert!(
        matches!(fork::check(&r, &At::Stop(3), true, false), Err(Refused::No(m)) if m.contains("snapshot"))
    );
    assert!(matches!(
        fork::check(
            &run(),
            &At::Hit {
                path: "/p/stock.py".into(),
                line: 20,
                hit: fork::HIT_CAP + 1
            },
            true,
            false
        ),
        Err(Refused::No(_))
    ));
}

#[test]
fn a_slow_point_asks_first() {
    let mut r = run();
    r.stops[4].t_ms = 61_000;
    assert!(matches!(
        fork::check(&r, &At::Stop(12), true, false),
        Err(Refused::Ask(_))
    ));
    assert!(fork::check(&r, &At::Stop(12), true, true).is_ok());
    // an earlier point of the same run does not ask
    assert!(fork::check(&r, &At::Stop(7), true, false).is_ok());
}

#[test]
fn a_step_stop_is_its_breakpoint_stop_then_the_recorded_steps() {
    let t = fork::check(&run(), &At::Stop(9), true, false).unwrap();
    assert_eq!(
        t,
        Target {
            path: "/p/stock.py".into(),
            line: 20,
            hit: 2,
            steps: vec!["next".into(), "next".into()],
            seq: Some(9),
        }
    );
    let t = fork::check(&run(), &At::Stop(12), true, false).unwrap();
    assert_eq!((t.hit, t.steps.len(), t.seq), (3, 0, Some(12)));
    let t = fork::check(
        &run(),
        &At::Hit {
            path: "/p/stock.py".into(),
            line: 20,
            hit: 2,
        },
        true,
        false,
    )
    .unwrap();
    assert_eq!(t.seq, Some(7));
}

#[test]
fn the_configuration_moves_into_the_tree() {
    let c = json!({"program": "/p/app/main.py", "cwd": "/p", "args": ["--data=/p/d.csv", "/pp/other", "/p"],
                   "env": {"X": "/p/x"}, "n": 3});
    let t = fork::for_tree(&c, Path::new("/p"), Path::new("/t/f1"));
    assert_eq!(
        t,
        json!({"program": "/t/f1/app/main.py", "cwd": "/t/f1", "args": ["--data=/t/f1/d.csv", "/pp/other", "/t/f1"],
               "env": {"X": "/t/f1/x"}, "n": 3})
    );
    assert_eq!(
        fork::from_tree("/t/f1/app/main.py", Path::new("/p"), Path::new("/t/f1")),
        "/p/app/main.py"
    );
}

#[test]
fn the_config_hash_ignores_key_order_and_sees_every_value() {
    let a = json!({"a": 1, "b": {"y": [1, 2], "x": "s"}, "env": {"K": "v"}});
    let b = json!({"env": {"K": "v"}, "b": {"x": "s", "y": [1, 2]}, "a": 1});
    assert_eq!(config_hash(&a), config_hash(&b));
    let c = json!({"a": 1, "b": {"y": [1, 2], "x": "s"}, "env": {"K": "other"}});
    assert_ne!(config_hash(&a), config_hash(&c));
    assert_eq!(config_hash(&a).len(), 16);
}

// ---- driving the session ----------------------------------------------------------------------------------------

fn start() -> Start {
    Start {
        name: "fork".into(),
        adapter_id: "debugpy".into(),
        request: Request::Launch,
        arguments: json!({"program": "/f/stock.py"}),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    }
}

fn caps() -> Value {
    json!({"supportsConfigurationDoneRequest": true, "supportsSetVariable": true, "supportsLogPoints": true,
           "supportsTerminateRequest": true})
}

/// The launch, with BPS' setBreakpoints.
fn launch(caps: Value, bps: Vec<Value>) -> Vec<Value> {
    let mut v = vec![
        json!({"expect": "initialize", "ok": caps}),
        json!({"expect": "launch", "ok": {}}),
        json!({"event": "initialized"}),
    ];
    v.extend(bps);
    v.push(json!({"expect": "configurationDone"}));
    v
}

/// A stop at LINE (thread 1, frame 5) and the fetch that follows, with LOCALS.
fn stopped_at(line: u32, reason: &str, locals: Value) -> Vec<Value> {
    vec![
        json!({"event": "stopped", "body": {"reason": reason, "threadId": 1}}),
        json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
        json!({"expect": "stackTrace", "ok": {"stackFrames": [{"id": 5, "name": "f", "line": line, "column": 1, "source": {"path": PY}}]}}),
        json!({"expect": "scopes", "ok": {"scopes": [{"name": "Locals", "variablesReference": 10}]}}),
        json!({"expect": "variables", "args": {"variablesReference": 10}, "ok": {"variables": locals}}),
    ]
}

fn cont() -> Value {
    json!({"expect": "continue", "ok": {}})
}

fn probe_out(probe: &str, value: &str) -> Value {
    json!({"event": "output", "body": {"category": "console", "output": format!("\u{1e}drgnx:{probe}:140:{value}\n")}})
}

fn exited(code: i64) -> Vec<Value> {
    vec![
        json!({"event": "exited", "body": {"exitCode": code}}),
        json!({"event": "terminated"}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ]
}

fn probes() -> Vec<RunProbe> {
    vec![RunProbe {
        id: "shortfall".into(),
        path: PY.into(),
        line: 22,
        expr: "shortfall".into(),
    }]
}

fn target(hit: u32, steps: &[&str]) -> Target {
    Target {
        path: PY.into(),
        line: 20,
        hit,
        steps: steps.iter().map(|s| s.to_string()).collect(),
        seq: None,
    }
}

fn hit(probe: &str, value: &str) -> (String, String) {
    (probe.into(), value.into())
}

fn hits(h: &[RunHit]) -> Vec<(String, String)> {
    h.iter()
        .map(|h| (h.probe.clone(), h.value.clone()))
        .collect()
}

/// The mockup's fork: line 20, hit 3; `item.reserve` set; the probe's hits split at the point; run to the end.
#[tokio::test(start_paused = true)]
async fn hit_three_is_counted_by_the_hub_and_the_value_set_before_it_runs_on() {
    let item = json!([{"name": "item", "value": "Item(...)", "variablesReference": 11, "evaluateName": "item"}]);
    let mut s = launch(
        caps(),
        vec![
            json!({"expect": "setBreakpoints", "args": {"source": {"path": PY},
                      "breakpoints": [{"line": 20}, {"line": 22, "logMessage": format!("\u{1e}drgnx:shortfall:{{{THREAD}}}:{{repr(shortfall)}}")}]},
                      "ok": {"breakpoints": [{"verified": true}, {"verified": true}]}}),
        ],
    );
    // passes 1 and 2 run on; the probe hits once per pass
    for v in ["16", "12"] {
        s.extend(stopped_at(20, "breakpoint", item.clone()));
        s.push(cont());
        s.push(probe_out("shortfall", v));
    }
    s.extend(stopped_at(20, "breakpoint", item.clone()));
    s.push(json!({"expect": "evaluate", "args": {"expression": THREAD, "frameId": 5}, "ok": {"result": "140"}}));
    s.push(json!({"expect": "variables", "args": {"variablesReference": 11},
                  "ok": {"variables": [{"name": "reserve", "value": "8", "variablesReference": 0, "evaluateName": "item.reserve"}]}}));
    s.push(json!({"expect": "setVariable", "args": {"variablesReference": 11, "name": "reserve", "value": "0"}, "ok": {"value": "0"}}));
    // the fork line's breakpoint goes; the probe stays
    s.push(json!({"expect": "setBreakpoints", "args": {"source": {"path": PY}, "breakpoints": [{"line": 22}]}, "ok": {"breakpoints": [{"verified": true}]}}));
    s.push(cont());
    s.push(probe_out("shortfall", "1"));
    s.extend(exited(0));
    let m = Mocks::with(vec![s]);
    let out = fork::drive(Drive {
        launcher: m.clone(),
        start: start(),
        adapter: "debugpy".into(),
        target: target(3, &[]),
        probes: probes(),
        change: Change::Value {
            path: vec!["item".into(), "reserve".into()],
            text: "0".into(),
        },
        until: Until::Exit,
        later: vec![],
    })
    .await
    .unwrap();
    assert_eq!(
        hits(&out.before),
        [hit("shortfall", "16"), hit("shortfall", "12")]
    );
    assert_eq!(hits(&out.after), [hit("shortfall", "1")]);
    assert_eq!(out.thread.as_deref(), Some("140"));
    assert_eq!(out.applied.as_deref(), Some("0"));
    assert_eq!(out.at, (PY.to_owned(), 20));
    assert_eq!(out.end, End::Exit { code: Some(0) });
    let log = &m.logs().await[0];
    // two continues before the point (the hub counted), one after
    assert_eq!(
        log.commands().iter().filter(|c| **c == "continue").count(),
        3
    );
}

/// `setExpression` when the adapter has it and the value an `evaluateName`.
#[tokio::test(start_paused = true)]
async fn set_expression_is_preferred() {
    let mut c = caps();
    c["supportsSetExpression"] = json!(true);
    let mut s = launch(
        c,
        vec![json!({"expect": "setBreakpoints", "ok": {"breakpoints": [{"verified": true}]}})],
    );
    s.extend(stopped_at(
        20,
        "breakpoint",
        json!([{"name": "n", "value": "3", "variablesReference": 0, "evaluateName": "n"}]),
    ));
    s.push(json!({"expect": "evaluate", "ok": {"result": "140"}}));
    s.push(json!({"expect": "setExpression", "args": {"expression": "n", "value": "n + 1", "frameId": 5}, "ok": {"value": "4"}}));
    s.push(
        json!({"expect": "setBreakpoints", "args": {"breakpoints": []}, "ok": {"breakpoints": []}}),
    );
    s.push(cont());
    s.extend(stopped_at(
        30,
        "breakpoint",
        json!([{"name": "n", "value": "4", "variablesReference": 0}]),
    ));
    s.push(json!({"expect": "terminate", "ok": {}}));
    s.push(json!({"event": "terminated"}));
    s.push(json!({"expect": "disconnect", "ok": {}}));
    s.push(json!({"die": true}));
    let m = Mocks::with(vec![s]);
    let out = fork::drive(Drive {
        launcher: m.clone(),
        start: start(),
        adapter: "debugpy".into(),
        target: target(1, &[]),
        probes: vec![],
        change: Change::Value {
            path: vec!["n".into()],
            text: "n + 1".into(),
        },
        until: Until::NextStop,
        later: vec![],
    })
    .await
    .unwrap();
    assert_eq!(out.applied.as_deref(), Some("4"));
    let End::Stop { line, locals, .. } = out.end else {
        panic!("{:?}", out.end);
    };
    assert_eq!((line, locals[0]["value"].clone()), (30, json!("4")));
    m.logs().await;
}

/// A step stop: hit 2, then the two recorded `next`s.
#[tokio::test(start_paused = true)]
async fn a_step_stop_is_reached_by_repeating_the_recorded_steps() {
    let mut s = launch(
        caps(),
        vec![json!({"expect": "setBreakpoints", "ok": {"breakpoints": [{"verified": true}]}})],
    );
    s.extend(stopped_at(20, "breakpoint", json!([])));
    s.push(cont());
    s.extend(stopped_at(20, "breakpoint", json!([])));
    s.push(json!({"expect": "next", "args": {"threadId": 1}, "ok": {}}));
    s.extend(stopped_at(21, "step", json!([])));
    s.push(json!({"expect": "next", "args": {"threadId": 1}, "ok": {}}));
    s.extend(stopped_at(22, "step", json!([])));
    s.push(json!({"expect": "evaluate", "ok": {"result": "140"}}));
    s.push(json!({"expect": "setBreakpoints", "ok": {"breakpoints": []}}));
    s.push(cont());
    s.extend(exited(3));
    let m = Mocks::with(vec![s]);
    let out = fork::drive(Drive {
        launcher: m.clone(),
        start: start(),
        adapter: "debugpy".into(),
        target: target(2, &["next", "next"]),
        probes: vec![],
        change: Change::Nothing,
        until: Until::Exit,
        later: vec![],
    })
    .await
    .unwrap();
    assert_eq!(out.at, (PY.to_owned(), 22));
    assert_eq!(out.end, End::Exit { code: Some(3) });
    m.logs().await;
}

/// A program that ends before hit N says how far it got.
#[tokio::test(start_paused = true)]
async fn ending_before_hit_n_says_how_far_it_got() {
    let mut s = launch(
        caps(),
        vec![json!({"expect": "setBreakpoints", "ok": {"breakpoints": [{"verified": true}]}})],
    );
    for _ in 0..2 {
        s.extend(stopped_at(20, "breakpoint", json!([])));
        s.push(cont());
    }
    s.extend(exited(0));
    let m = Mocks::with(vec![s]);
    let e = fork::drive(Drive {
        launcher: m.clone(),
        start: start(),
        adapter: "debugpy".into(),
        target: target(3, &[]),
        probes: vec![],
        change: Change::Nothing,
        until: Until::Exit,
        later: vec![],
    })
    .await
    .unwrap_err();
    assert!(e.contains("2 of 3"), "{e}");
    m.logs().await;
}

/// A probe on the fork line gives way to the plain breakpoint and is read at each of its stops; the run ends at the
/// probe's next hit after the point.
#[tokio::test(start_paused = true)]
async fn a_probe_on_the_fork_line_is_read_at_its_stops() {
    let p = vec![RunProbe {
        id: "total".into(),
        path: PY.into(),
        line: 20,
        expr: "total".into(),
    }];
    let mut s = launch(
        caps(),
        vec![
            json!({"expect": "setBreakpoints", "args": {"breakpoints": [{"line": 20}]}, "ok": {"breakpoints": [{"verified": true}]}}),
        ],
    );
    s.extend(stopped_at(20, "breakpoint", json!([])));
    s.push(json!({"expect": "evaluate", "args": {"expression": THREAD}, "ok": {"result": "140"}}));
    s.push(json!({"expect": "evaluate", "args": {"expression": "total"}, "ok": {"result": "4"}}));
    s.push(cont());
    s.extend(stopped_at(20, "breakpoint", json!([])));
    s.push(json!({"expect": "evaluate", "args": {"expression": THREAD}, "ok": {"result": "140"}}));
    s.push(json!({"expect": "evaluate", "args": {"expression": "total"}, "ok": {"result": "9"}}));
    s.push(json!({"expect": "evaluate", "args": {"expression": THREAD}, "ok": {"result": "140"}}));
    // the logpoint comes back once the plain breakpoint goes
    s.push(json!({"expect": "setBreakpoints", "args": {"breakpoints": [{"line": 20, "logMessage": format!("\u{1e}drgnx:total:{{{THREAD}}}:{{repr(total)}}")}]}, "ok": {"breakpoints": [{"verified": true}]}}));
    s.push(cont());
    s.push(probe_out("total", "15"));
    s.push(json!({"expect": "terminate", "ok": {}}));
    s.push(json!({"event": "terminated"}));
    s.push(json!({"expect": "disconnect", "ok": {}}));
    s.push(json!({"die": true}));
    let m = Mocks::with(vec![s]);
    let out = fork::drive(Drive {
        launcher: m.clone(),
        start: start(),
        adapter: "debugpy".into(),
        target: target(2, &[]),
        probes: p,
        change: Change::Nothing,
        until: Until::Probe("total".into()),
        later: vec![],
    })
    .await
    .unwrap();
    assert_eq!(hits(&out.before), [hit("total", "4"), hit("total", "9")]);
    assert_eq!(
        out.end,
        End::Probe {
            probe: "total".into(),
            value: "15".into()
        }
    );
    m.logs().await;
}

/// js-debug: the program is a child session (`startDebugging`), whose stops count.
#[tokio::test(start_paused = true)]
async fn js_debugs_child_session_is_where_it_stops() {
    let js = "/f/app.js";
    let root = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true}}),
        json!({"expect": "launch", "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "setBreakpoints", "ok": {"breakpoints": [{"verified": true}]}}),
        json!({"expect": "configurationDone"}),
        json!({"reverse": "startDebugging", "arguments": {"request": "attach", "configuration": {"type": "pwa-node", "__pendingTargetId": "t1"}}}),
        // the fork line's breakpoint goes from every session
        json!({"expect": "setBreakpoints", "ok": {"breakpoints": []}}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ];
    let child = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true, "supportsSetVariable": true}}),
        json!({"expect": "attach", "args": {"__pendingTargetId": "t1"}, "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "setBreakpoints", "ok": {"breakpoints": [{"verified": true}]}}),
        json!({"expect": "configurationDone"}),
        json!({"event": "stopped", "body": {"reason": "breakpoint", "threadId": 1}}),
        json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
        json!({"expect": "stackTrace", "ok": {"stackFrames": [{"id": 5, "name": "f", "line": 4, "column": 1, "source": {"path": js}}]}}),
        json!({"expect": "scopes", "ok": {"scopes": []}}),
        json!({"expect": "setBreakpoints", "ok": {"breakpoints": []}}),
        json!({"expect": "continue", "ok": {}}),
        json!({"event": "stopped", "body": {"reason": "breakpoint", "threadId": 1}}),
        json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
        json!({"expect": "stackTrace", "ok": {"stackFrames": [{"id": 6, "name": "g", "line": 9, "column": 1, "source": {"path": js}}]}}),
        json!({"expect": "scopes", "ok": {"scopes": []}}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ];
    let m = Mocks::with(vec![root, child]);
    let mut st = start();
    st.adapter_id = "pwa-node".into();
    let out = fork::drive(Drive {
        launcher: m.clone(),
        start: st,
        adapter: "js-debug".into(),
        target: Target {
            path: js.into(),
            line: 4,
            hit: 1,
            steps: vec![],
            seq: None,
        },
        probes: vec![],
        change: Change::Nothing,
        until: Until::NextStop,
        later: vec![(js.into(), 9)],
    })
    .await
    .unwrap();
    // JavaScript names no thread: neither do the run's hits
    assert_eq!(out.thread.as_deref(), Some(""));
    assert!(matches!(out.end, End::Stop { line: 9, .. }));
    m.logs().await;
}
