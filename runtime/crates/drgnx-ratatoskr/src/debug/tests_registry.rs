//! The hub's sessions ([`Debug`]) with mock adapters: the events, which editor opens a stop's file, children, restarts,
//! `runInTerminal` in a terminal, and the hub's end.
use super::session::{Op, Proc, Request, Sig, Start};
use super::{BoxFut, Connected, Debug, Launcher, Opened, Sink, Terminals};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use vor::mock::{Mock, Script};

/// One event: to (`None`: all but the except), except, name, data.
type Sent = (Option<u64>, Option<u64>, String, Value);

/// Every event, with where it went.
#[derive(Default)]
struct Events(Mutex<Vec<Sent>>);

impl Sink for Events {
    fn broadcast(&self, event: &str, data: Value, except: Option<u64>) {
        self.0
            .lock()
            .unwrap()
            .push((None, except, event.to_owned(), data));
    }
    fn send(&self, conn: u64, event: &str, data: Value) -> bool {
        self.0
            .lock()
            .unwrap()
            .push((Some(conn), None, event.to_owned(), data));
        true
    }
}

impl Events {
    fn named(&self, name: &str) -> Vec<(Option<u64>, Option<u64>, Value)> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.2 == name)
            .map(|e| (e.0, e.1, e.3.clone()))
            .collect()
    }
}

struct NoTerms(Mutex<Vec<(u64, String, Vec<String>)>>);

impl Terminals for NoTerms {
    fn open(
        &self,
        conn: u64,
        cwd: String,
        args: Vec<String>,
        _: Vec<(String, String)>,
    ) -> BoxFut<'_, Result<Opened, String>> {
        self.0.lock().unwrap().push((conn, cwd, args));
        Box::pin(async {
            Ok(Opened {
                term: "t1".into(),
                view: "term:t1".into(),
                pid: 4242,
                editor: None,
            })
        })
    }
}

struct Exits;

impl Proc for Exits {
    fn signal(&mut self, _: Sig) {}
    fn wait(&mut self) -> BoxFut<'_, ()> {
        Box::pin(async {})
    }
}

/// Hands out one mock per connection, from a queue of scripts; keeps the mocks and the order of every request.
#[derive(Default)]
struct Mocks {
    scripts: Mutex<VecDeque<Vec<Value>>>,
    running: Mutex<Vec<Mock>>,
    launched: Mutex<Vec<Value>>,
}

impl Mocks {
    fn with(scripts: Vec<Vec<Value>>) -> Arc<Mocks> {
        Arc::new(Mocks {
            scripts: Mutex::new(scripts.into()),
            ..Default::default()
        })
    }
    async fn finish(&self) -> Vec<Result<vor::mock::Log, String>> {
        let ms: Vec<Mock> = std::mem::take(&mut *self.running.lock().unwrap());
        let mut out = vec![];
        for m in ms {
            out.push(m.finish().await);
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
            if let Some(l) = steps
                .iter()
                .find(|s| s["expect"] == "launch" || s["expect"] == "attach")
            {
                self.launched.lock().unwrap().push(l["args"].clone());
            }
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

fn start() -> Start {
    Start {
        name: "Node: app".into(),
        adapter_id: "pwa-node".into(),
        request: Request::Launch,
        arguments: json!({"program": "/p/app.js"}),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    }
}

fn launch(extra: Vec<Value>) -> Vec<Value> {
    let mut v = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true}}),
        json!({"expect": "launch", "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "configurationDone"}),
    ];
    v.extend(extra);
    v
}

fn end() -> Vec<Value> {
    vec![
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ]
}

fn setup(scripts: Vec<Vec<Value>>) -> (Debug, Arc<Events>, Arc<Mocks>, Arc<NoTerms>) {
    let ev = Arc::new(Events::default());
    let terms = Arc::new(NoTerms(Mutex::default()));
    let d = Debug::new(ev.clone(), terms.clone());
    (d, ev, Mocks::with(scripts), terms)
}

/// Waits (on paused time) until COND holds.
async fn until(mut cond: impl FnMut() -> bool) {
    for _ in 0..10_000 {
        if cond() {
            return;
        }
        crate::clock::sleep(Duration::from_millis(1)).await;
    }
    panic!("never happened");
}

fn last_states(ev: &Events) -> Vec<String> {
    ev.named("debug-state")
        .last()
        .map(|(_, _, d)| {
            d["sessions"]
                .as_array()
                .unwrap()
                .iter()
                .map(|s| {
                    format!(
                        "{}:{}",
                        s["id"].as_str().unwrap(),
                        s["state"].as_str().unwrap()
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

#[tokio::test(start_paused = true)]
async fn the_state_event_says_which_sessions_attach() {
    let mut a = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true}}),
        json!({"expect": "attach", "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "configurationDone"}),
    ];
    a.extend(end());
    let mut l = launch(vec![]);
    l.extend(end());
    let (d, ev, m, _) = setup(vec![a, l]);
    let attach = Start {
        request: Request::Attach,
        arguments: json!({"processId": 42}),
        ..start()
    };
    let ia = d.start(7, "/p", attach, m.clone()).await.unwrap();
    let il = d.start(7, "/p", start(), m.clone()).await.unwrap();
    until(|| {
        last_states(&ev).len() == 2 && last_states(&ev).iter().all(|s| s.ends_with(":running"))
    })
    .await;
    let (_, _, data) = ev.named("debug-state").last().unwrap().clone();
    let of = |id: &str| {
        data["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["id"] == id)
            .unwrap()["attach"]
            .clone()
    };
    assert_eq!(of(&ia), json!(true));
    assert_eq!(of(&il), json!(false));
    d.control(&ia, Op::Disconnect).await.unwrap();
    d.control(
        &il,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    until(|| last_states(&ev).is_empty()).await;
}

#[tokio::test(start_paused = true)]
async fn the_state_event_follows_a_session_from_start_to_end() {
    let mut s = launch(vec![]);
    s.extend(end());
    let (d, ev, m, _) = setup(vec![s]);
    let id = d.start(7, "/p", start(), m.clone()).await.unwrap();
    until(|| last_states(&ev) == [format!("{id}:running")]).await;
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    assert!(last_states(&ev).is_empty());
    assert_eq!(ev.named("debug-ended").len(), 1);
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

#[tokio::test(start_paused = true)]
async fn only_the_starting_editor_is_told_to_open_the_file() {
    let mut s = launch(vec![
        json!({"event": "stopped", "body": {"reason": "breakpoint", "threadId": 1}}),
        json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
        json!({"expect": "stackTrace", "ok": {"stackFrames": [{"id": 5, "name": "f", "line": 7, "column": 3, "source": {"path": "/p/app.js"}}]}}),
        json!({"expect": "scopes", "ok": {"scopes": []}}),
    ]);
    s.extend(end());
    let (d, ev, m, _) = setup(vec![s]);
    let id = d.start(7, "/p", start(), m.clone()).await.unwrap();
    until(|| ev.named("debug-frame").len() == 2).await;
    let frames = ev.named("debug-frame");
    let (to_all, except, others) = &frames[0];
    assert_eq!(
        (*to_all, *except, &others["open"]),
        (None, Some(7), &json!(false))
    );
    let (to, _, mine) = &frames[1];
    assert_eq!((*to, &mine["open"]), (Some(7), &json!(true)));
    assert_eq!(
        (&mine["path"], &mine["line"], &mine["top"]),
        (&json!("/p/app.js"), &json!(7), &json!(true))
    );
    assert_eq!(
        (&mine["name"], &mine["source_name"]),
        (&json!("f"), &Value::Null)
    );
    assert_eq!(last_states(&ev), [format!("{id}:stopped")]);
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    m.finish().await;
}

/// A parent that ends while its children are being stopped (js-debug ends its root session once the program is gone)
/// has done what the stop asked: the stop succeeds.
#[tokio::test(start_paused = true)]
async fn a_parent_that_ends_while_its_children_stop_is_stopped() {
    let mut parent = launch(vec![json!({"reverse": "startDebugging",
        "arguments": {"request": "launch", "configuration": {"name": "worker", "__pendingTargetId": "t1"}}})]);
    parent.extend([
        json!({"expect": "evaluate", "ok": {"result": "1"}}),
        json!({"die": true}),
    ]);
    let child = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true}}),
        json!({"expect": "launch", "args": {"__pendingTargetId": "t1"}, "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "configurationDone"}),
        // the child's stop takes a while: its adapter does not answer the disconnect
        json!({"expect": "disconnect", "silent": true}),
    ];
    let (d, ev, m, _) = setup(vec![parent, child]);
    let id = d.start(7, "/p", start(), m.clone()).await.unwrap();
    until(|| d.list().len() == 2).await;
    let h = d.session(&id).unwrap();
    let stop = {
        let d = d.clone();
        let id = id.clone();
        crate::clock::spawn("debug:test-stop", async move {
            d.control(
                &id,
                Op::Stop {
                    kill_debuggee: None,
                },
            )
            .await
        })
    };
    // while the child is stopping, the parent's adapter goes
    crate::clock::sleep(Duration::from_millis(10)).await;
    h.request("evaluate", json!({"expression": "1"}))
        .await
        .unwrap();
    assert_eq!(stop.await.unwrap(), Ok(()));
    assert_eq!(ev.named("debug-ended").len(), 2);
    m.finish().await;
}

#[tokio::test(start_paused = true)]
async fn start_debugging_starts_a_child_and_children_stop_before_their_parent() {
    let order = Arc::new(Mutex::new(Vec::<String>::new()));
    let mut parent = launch(vec![json!({"reverse": "startDebugging",
        "arguments": {"request": "launch", "configuration": {"name": "worker", "__pendingTargetId": "t1"}}})]);
    parent.extend(end());
    let mut child = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true}}),
        json!({"expect": "launch", "args": {"__pendingTargetId": "t1"}, "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "configurationDone"}),
    ];
    child.extend(end());
    let (d, ev, m, _) = setup(vec![parent, child]);
    let id = d.start(7, "/p", start(), m.clone()).await.unwrap();
    until(|| d.list().len() == 2).await;
    let kid = d.list().into_iter().find(|(_, p)| p.is_some()).unwrap();
    assert_eq!(kid.1.as_deref(), Some(id.as_str()));
    let names: Vec<String> = ev
        .named("debug-ended")
        .iter()
        .map(|e| e.2["session"].to_string())
        .collect();
    assert!(names.is_empty());
    let o = order.clone();
    let watch = {
        let ev = ev.clone();
        crate::clock::spawn("debug:test-watch", async move {
            until(|| !ev.named("debug-ended").is_empty()).await;
            o.lock().unwrap().push(
                ev.named("debug-ended")[0].2["session"]
                    .as_str()
                    .unwrap()
                    .to_owned(),
            );
        })
    };
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    watch.await.unwrap();
    assert_eq!(
        *order.lock().unwrap(),
        std::slice::from_ref(&kid.0),
        "the child ended first"
    );
    assert_eq!(ev.named("debug-ended").len(), 2);
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

#[tokio::test(start_paused = true)]
async fn run_in_terminal_opens_a_terminal_for_the_starting_editor() {
    let mut s = launch(vec![json!({"reverse": "runInTerminal",
        "arguments": {"kind": "integrated", "cwd": "/p", "args": ["node", "app.js"]}, "answer": {"processId": 4242}})]);
    s.extend(end());
    let (d, ev, m, terms) = setup(vec![s]);
    let id = d.start(7, "/p", start(), m.clone()).await.unwrap();
    until(|| !ev.named("debug-terminal").is_empty()).await;
    assert_eq!(
        terms.0.lock().unwrap()[0],
        (
            7,
            "/p".to_owned(),
            vec!["node".to_owned(), "app.js".to_owned()]
        )
    );
    let t = &ev.named("debug-terminal")[0];
    assert_eq!(
        (t.0, &t.2["term"], &t.2["view"]),
        (Some(7), &json!("t1"), &json!("term:t1"))
    );
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

#[tokio::test(start_paused = true)]
async fn a_restart_without_the_request_starts_the_same_configuration_again() {
    let mut first = launch(vec![]);
    first.extend(end());
    let mut second = launch(vec![]);
    second.extend(end());
    let (d, ev, m, _) = setup(vec![first, second]);
    let id = d.start(7, "/p", start(), m.clone()).await.unwrap();
    until(|| last_states(&ev) == [format!("{id}:running")]).await;
    d.control(&id, Op::Restart).await.unwrap();
    until(|| {
        last_states(&ev).len() == 1
            && last_states(&ev)[0] != format!("{id}:running")
            && last_states(&ev)[0].ends_with(":running")
    })
    .await;
    let id2 = d.list()[0].0.clone();
    d.control(
        &id2,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    assert_eq!(m.launched.lock().unwrap().len(), 2);
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

#[tokio::test(start_paused = true)]
async fn the_adapters_restart_value_goes_back_as_restart() {
    let mut first = launch(vec![
        json!({"event": "terminated", "body": {"restart": {"port": 9229}}}),
    ]);
    first.extend(end());
    let mut second = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true}}),
        json!({"expect": "launch", "args": {"program": "/p/app.js", "__restart": {"port": 9229}}, "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "configurationDone"}),
    ];
    second.extend(end());
    let (d, ev, m, _) = setup(vec![first, second]);
    d.start(7, "/p", start(), m.clone()).await.unwrap();
    until(|| {
        ev.named("debug-ended").len() == 1
            && last_states(&ev).iter().any(|s| s.ends_with(":running"))
    })
    .await;
    let id2 = d.list()[0].0.clone();
    d.control(
        &id2,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

#[tokio::test(start_paused = true)]
async fn the_hubs_end_stops_every_session_and_refuses_new_ones() {
    let mut a = launch(vec![]);
    a.extend(end());
    let mut b = launch(vec![]);
    b.extend(end());
    let (d, ev, m, _) = setup(vec![a, b]);
    d.start(7, "/p", start(), m.clone()).await.unwrap();
    d.start(8, "/q", start(), m.clone()).await.unwrap();
    until(|| {
        last_states(&ev)
            .iter()
            .filter(|s| s.ends_with(":running"))
            .count()
            == 2
    })
    .await;
    d.shutdown().await;
    assert!(d.list().is_empty());
    assert_eq!(ev.named("debug-ended").len(), 2);
    assert!(d.start(7, "/p", start(), m.clone()).await.is_err());
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

fn add_bp(path: &str, line: u32, condition: Option<&str>) -> super::breakpoints::Op {
    super::breakpoints::Op::Add {
        path: path.into(),
        line,
        column: None,
        enabled: true,
        condition: condition.map(str::to_owned),
        hit: None,
        log: None,
    }
}

fn last_bps(ev: &Events, path: &str) -> Option<Value> {
    ev.named("debug-breakpoints")
        .into_iter()
        .rev()
        .map(|(_, _, d)| d)
        .find(|d| d["path"] == path)
}

#[tokio::test(start_paused = true)]
async fn a_breakpoint_reaches_a_running_session_at_once_and_its_answer_is_shown() {
    let mut s = launch(vec![json!({"expect": "setBreakpoints",
        "args": {"source": {"path": "/p/app.js"}, "breakpoints": [{"line": 4}]},
        "ok": {"breakpoints": [{"id": 11, "verified": true, "line": 5}]}})]);
    s.extend(end());
    let (d, ev, m, _) = setup(vec![s]);
    let id = d.start(1, "/p", start(), m.clone()).await.unwrap();
    until(|| last_states(&ev) == [format!("{id}:running")]).await;
    let view = d
        .breakpoints("/p", Some(add_bp("/p/app.js", 4, None)), None)
        .await;
    assert!(view["version"].as_u64() >= Some(1), "{view}");
    until(|| last_bps(&ev, "/p/app.js").is_some_and(|v| v["breakpoints"][0]["verified"] == true))
        .await;
    // the call's answer can reach the editor after this event: when it was taken before the adapter verified it, its
    // version is lower, so the editor passes over it and the dot stays verified
    let shown = last_bps(&ev, "/p/app.js").unwrap();
    if view["breakpoints"][0]["verified"] == true {
        assert!(
            shown["version"].as_u64() >= view["version"].as_u64(),
            "{view} {shown}"
        );
    } else {
        assert!(
            shown["version"].as_u64() > view["version"].as_u64(),
            "{view} {shown}"
        );
    }
    assert_eq!(
        last_bps(&ev, "/p/app.js").unwrap()["breakpoints"][0]["bound_line"],
        5
    );
    // the editors' view: by path, without an operation
    assert_eq!(
        d.breakpoints("/p", None, Some("/p/app.js")).await["breakpoints"][0]["id"],
        1
    );
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    // the session ended: nothing verifies it now
    assert_eq!(
        last_bps(&ev, "/p/app.js").unwrap()["breakpoints"][0]["verified"],
        false
    );
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

#[tokio::test(start_paused = true)]
async fn a_session_starts_with_the_projects_breakpoints_cut_to_its_adapter() {
    let steps = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true,
               "supportsFunctionBreakpoints": true,
               "exceptionBreakpointFilters": [{"filter": "uncaught", "label": "Uncaught", "default": true}]}}),
        json!({"expect": "launch", "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "setBreakpoints", "args": {"source": {"path": "/p/a.js"}, "breakpoints": [{"line": 3}]},
               "ok": {"breakpoints": [{"id": 1, "verified": true}]}}),
        json!({"expect": "setFunctionBreakpoints", "args": {"breakpoints": [{"name": "main"}]}, "ok": {}}),
        json!({"expect": "setExceptionBreakpoints", "args": {"filters": ["uncaught"]}, "ok": {}}),
        json!({"expect": "configurationDone"}),
    ];
    let mut steps = steps;
    steps.extend(end());
    let (d, ev, m, _) = setup(vec![steps]);
    d.breakpoints("/p", Some(add_bp("/p/a.js", 3, Some("x > 1"))), None)
        .await;
    d.breakpoints(
        "/p",
        Some(super::breakpoints::Op::AddFunction {
            name: "main".into(),
            condition: None,
        }),
        None,
    )
    .await;
    // another project's breakpoints stay out
    d.breakpoints("/q", Some(add_bp("/q/b.js", 8, None)), None)
        .await;
    let id = d.start(1, "/p", start(), m.clone()).await.unwrap();
    until(|| last_bps(&ev, "/p/a.js").is_some_and(|v| v["breakpoints"][0]["verified"] == true))
        .await;
    assert_eq!(
        last_bps(&ev, "/p/a.js").unwrap()["breakpoints"][0]["unsupported"],
        json!(["condition"])
    );
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    let logs = m.finish().await;
    let log = logs[0].as_ref().unwrap();
    let sent = &log
        .requests
        .iter()
        .find(|(c, _)| c == "setBreakpoints")
        .unwrap()
        .1;
    assert!(sent["breakpoints"][0].get("condition").is_none(), "{sent}");
}

#[tokio::test(start_paused = true)]
async fn run_to_cursor_goes_at_the_next_stop() {
    let stop = |line: u32| {
        vec![
            json!({"event": "stopped", "body": {"reason": "breakpoint", "threadId": 1}}),
            json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
            json!({"expect": "stackTrace", "ok": {"stackFrames": [{"id": 5, "name": "f", "line": line, "column": 1, "source": {"path": "/p/app.js"}}]}}),
            json!({"expect": "scopes", "ok": {"scopes": []}}),
        ]
    };
    let mut s = launch(stop(2));
    s.push(json!({"expect": "setBreakpoints", "args": {"source": {"path": "/p/app.js"}, "breakpoints": [{"line": 12}]},
                  "ok": {"breakpoints": [{"id": 3, "verified": true}]}}));
    s.push(json!({"expect": "continue", "ok": {}}));
    s.extend(stop(12));
    s.push(json!({"expect": "setBreakpoints", "args": {"source": {"path": "/p/app.js"}, "breakpoints": []},
                  "ok": {"breakpoints": []}}));
    s.extend(end());
    let (d, ev, m, _) = setup(vec![s]);
    let id = d.start(1, "/p", start(), m.clone()).await.unwrap();
    until(|| ev.named("debug-frame").len() == 2).await;
    d.run_to_cursor(&id, "/p/app.js", 12).await.unwrap();
    until(|| ev.named("debug-frame").len() == 4).await;
    // the user's breakpoints never showed it
    assert!(last_bps(&ev, "/p/app.js").is_none_or(|v| v["breakpoints"] == json!([])));
    // every answer is shown: the Run to Cursor's and the one after it went
    until(|| ev.named("debug-breakpoints").len() == 2).await;
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

#[tokio::test(start_paused = true)]
async fn the_store_is_kept_per_project_in_the_state_directory() {
    let dir = tempfile::tempdir().unwrap();
    let ev = Arc::new(Events::default());
    let terms = Arc::new(NoTerms(Mutex::default()));
    let d = Debug::with_store(ev.clone(), terms.clone(), Some(dir.path().to_owned()));
    d.breakpoints("/p", Some(add_bp("/p/a.js", 3, None)), None)
        .await;
    d.breakpoints("/q", Some(add_bp("/q/b.js", 8, None)), None)
        .await;
    d.written().await;
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 2);
    let again = Debug::with_store(ev, terms, Some(dir.path().to_owned()));
    assert_eq!(
        again.breakpoints("/p", None, Some("/p/a.js")).await["breakpoints"][0]["line"],
        3
    );
    assert_eq!(
        again.breakpoints("/p", None, Some("/q/b.js")).await["breakpoints"],
        json!([])
    );
}

/// An exception stop: `exceptionInfo` (when the adapter has it) is asked in the same stop and goes in `debug-frame`'s
/// `exception` (its id, message, break mode and details), for the editor's exception card.
#[tokio::test(start_paused = true)]
async fn an_exception_stop_carries_exception_info() {
    let mut s = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true, "supportsExceptionInfoRequest": true}}),
        json!({"expect": "launch", "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "configurationDone"}),
        json!({"event": "stopped", "body": {"reason": "exception", "threadId": 1, "description": "Paused on exception"}}),
        json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
        json!({"expect": "stackTrace", "ok": {"stackFrames": [{"id": 5, "name": "f", "line": 7, "column": 3, "source": {"path": "/p/app.py"}}]}}),
        json!({"expect": "scopes", "ok": {"scopes": []}}),
        json!({"expect": "exceptionInfo", "args": {"threadId": 1},
               "ok": {"exceptionId": "ZeroDivisionError", "description": "division by zero", "breakMode": "unhandled",
                      "details": {"typeName": "ZeroDivisionError", "stackTrace": "Traceback …"}}}),
    ];
    s.extend(end());
    let (d, ev, m, _) = setup(vec![s]);
    let id = d.start(7, "/p", start(), m.clone()).await.unwrap();
    until(|| ev.named("debug-frame").len() == 2).await;
    let (_, _, mine) = &ev.named("debug-frame")[1];
    assert_eq!(mine["reason"], json!("exception"));
    assert_eq!(
        mine["exception"],
        json!({"id": "ZeroDivisionError", "message": "division by zero", "break_mode": "unhandled",
               "type": "ZeroDivisionError", "trace": "Traceback …"})
    );
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

/// Without `exceptionInfo`, the stop's own description is the card's message; a stop that is not an exception has none.
#[tokio::test(start_paused = true)]
async fn without_exception_info_the_description_is_the_message() {
    let mut s = launch(vec![
        json!({"event": "stopped", "body": {"reason": "exception", "threadId": 1, "description": "Uncaught TypeError"}}),
        json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
        json!({"expect": "stackTrace", "ok": {"stackFrames": [{"id": 5, "name": "f", "line": 7, "column": 3, "source": {"path": "/p/app.js"}}]}}),
        json!({"expect": "scopes", "ok": {"scopes": []}}),
    ]);
    s.extend(end());
    let (d, ev, m, _) = setup(vec![s]);
    let id = d.start(7, "/p", start(), m.clone()).await.unwrap();
    until(|| ev.named("debug-frame").len() == 2).await;
    let (_, _, mine) = &ev.named("debug-frame")[1];
    assert_eq!(mine["exception"], json!({"message": "Uncaught TypeError"}));
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

/// A frame whose source has no file (`sourceReference`): `debug/source` asks the adapter for its text.
#[tokio::test(start_paused = true)]
async fn a_source_reference_is_fetched_from_the_adapter() {
    let mut s = launch(vec![
        json!({"expect": "source", "args": {"sourceReference": 42, "source": {"sourceReference": 42}},
               "ok": {"content": "function f() {}\n", "mimeType": "text/javascript"}}),
        json!({"expect": "source", "args": {"sourceReference": 9, "source": {"sourceReference": 9}},
               "fail": "no such source"}),
    ]);
    s.extend(end());
    let (d, ev, m, _) = setup(vec![s]);
    let id = d.start(7, "/p", start(), m.clone()).await.unwrap();
    until(|| last_states(&ev) == [format!("{id}:running")]).await;
    assert_eq!(
        d.source(&id, 42).await.unwrap(),
        json!({"text": "function f() {}\n", "mime": "text/javascript"})
    );
    assert!(
        d.source(&id, 9)
            .await
            .unwrap_err()
            .contains("no such source")
    );
    assert!(d.source("nope", 42).await.is_err());
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

/// A stop publishes its inline values (`debug-inline`, spec §8) after its frame: the selected frame's file, its lines
/// with values, changed against the session's previous stop; the session's end forgets them.
#[tokio::test(start_paused = true)]
async fn a_stop_publishes_its_inline_values() {
    let dir = std::env::temp_dir().join(format!("drgnx-inline-hub-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("app.py");
    std::fs::write(&path, "def f(n):\n    total = n * 2\n    return total\n").unwrap();
    let stopped = |total: i64| {
        vec![
            json!({"event": "stopped", "body": {"reason": "step", "threadId": 1}}),
            json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
            json!({"expect": "stackTrace", "ok": {"stackFrames": [{"id": 5, "name": "f", "line": 3, "column": 5,
                                                                     "source": {"path": path}}]}}),
            json!({"expect": "scopes", "ok": {"scopes": [{"name": "Locals", "variablesReference": 9}]}}),
            json!({"expect": "variables", "ok": {"variables": [
                {"name": "n", "value": "2", "variablesReference": 0},
                {"name": "total", "value": total.to_string(), "variablesReference": 0}]}}),
        ]
    };
    let mut steps = stopped(4);
    steps.push(json!({"expect": "next", "ok": {}}));
    steps.extend(stopped(5));
    let mut s = launch(steps);
    s.extend(end());
    let (d, ev, m, _) = setup(vec![s]);
    let id = d.start(7, "/p", start(), m.clone()).await.unwrap();
    until(|| ev.named("debug-inline").len() == 1).await;
    let (_, _, first) = &ev.named("debug-inline")[0];
    assert_eq!(
        *first,
        json!({"session": id, "epoch": 1, "path": path,
               "lines": [{"line": 2, "text": "n = 2", "changed": []},
                         {"line": 3, "text": "total = 4", "changed": []}]})
    );
    d.control(&id, Op::Next { thread: None }).await.unwrap();
    until(|| ev.named("debug-inline").len() == 2).await;
    let (_, _, next) = &ev.named("debug-inline")[1];
    assert_eq!(
        next["lines"],
        json!([{"line": 2, "text": "n = 2", "changed": []}, {"line": 3, "text": "total = 5", "changed": [[0, 9]]}])
    );
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

/// debugpy's child (`startDebugging`: an attach whose `connect` names the parent adapter's own client listener)
/// connects there, as VS Code's Python extension does; no new adapter is started for it.
#[tokio::test]
async fn a_debugpy_child_connects_to_its_parent_adapters_listener() {
    use tokio::io::AsyncReadExt;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let mut parent = launch(vec![json!({"reverse": "startDebugging",
        "arguments": {"request": "attach", "configuration": {"name": "Subprocess 9", "request": "attach",
                      "subProcessId": 9, "connect": {"host": "127.0.0.1", "port": port}}}})]);
    parent.extend(end());
    // one script: a new adapter for the child would find none
    let (d, _, m, _) = setup(vec![parent]);
    let mut s = start();
    s.adapter_id = "debugpy".into();
    let id = d.start(7, "/p", s, m.clone()).await.unwrap();
    let (mut conn, _) = crate::clock::timeout(Duration::from_secs(10), listener.accept())
        .await
        .expect("the child connected to the parent adapter's listener")
        .unwrap();
    let mut buf = vec![0u8; 4096];
    let n = crate::clock::timeout(Duration::from_secs(10), conn.read(&mut buf))
        .await
        .unwrap()
        .unwrap();
    assert!(String::from_utf8_lossy(&buf[..n]).contains("\"initialize\""));
    drop(conn);
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    assert!(m.finish().await.into_iter().all(|r| r.is_ok()));
}

/// An adapter that restarts in place (delve: `restart` answered, then `initialized` again) is configured again, with
/// the project's breakpoints as they are now, and runs on; without it the restarted program waits for ever.
#[tokio::test(start_paused = true)]
async fn an_initialized_after_a_restart_configures_again_with_the_breakpoints_of_now() {
    let both = json!({"source": {"path": "/p/a.js"}, "breakpoints": [{"line": 3}, {"line": 5}]});
    let mut s = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true, "supportsRestartRequest": true}}),
        json!({"expect": "launch", "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "setBreakpoints", "args": {"source": {"path": "/p/a.js"}, "breakpoints": [{"line": 3}]},
               "ok": {"breakpoints": [{"id": 1, "verified": true}]}}),
        json!({"expect": "configurationDone"}),
        // added while it runs
        json!({"expect": "setBreakpoints", "args": both,
               "ok": {"breakpoints": [{"id": 1, "verified": true}, {"id": 2, "verified": true}]}}),
        json!({"expect": "restart", "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "setBreakpoints", "args": both,
               "ok": {"breakpoints": [{"id": 3, "verified": true}, {"id": 4, "verified": true}]}}),
        json!({"expect": "configurationDone"}),
    ];
    s.extend(end());
    let (d, ev, m, _) = setup(vec![s]);
    d.breakpoints("/p", Some(add_bp("/p/a.js", 3, None)), None)
        .await;
    let id = d.start(1, "/p", start(), m.clone()).await.unwrap();
    until(|| last_bps(&ev, "/p/a.js").is_some_and(|v| v["breakpoints"][0]["verified"] == true))
        .await;
    d.breakpoints("/p", Some(add_bp("/p/a.js", 5, None)), None)
        .await;
    until(|| last_bps(&ev, "/p/a.js").is_some_and(|v| v["breakpoints"][1]["verified"] == true))
        .await;
    d.control(&id, Op::Restart).await.unwrap();
    // the script checks the rest: both breakpoints sent again, then configurationDone, before the Stop's disconnect
    crate::clock::sleep(Duration::from_millis(500)).await;
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    let logs = m.finish().await;
    assert!(logs.iter().all(|r| r.is_ok()), "{logs:?}");
}

#[tokio::test(start_paused = true)]
async fn toggle_all_turns_every_breakpoint_off_then_on_again() {
    let (d, _ev, _m, _) = setup(vec![]);
    d.breakpoints("/p", Some(add_bp("/p/a.py", 3, None)), None)
        .await;
    d.breakpoints("/p", Some(add_bp("/p/b.py", 7, None)), None)
        .await;
    // one on is enough for "on": all go off
    assert!(!d.toggle_all_breakpoints("/p").await);
    for path in ["/p/a.py", "/p/b.py"] {
        assert_eq!(
            d.breakpoints("/p", None, Some(path)).await["breakpoints"][0]["enabled"],
            false,
            "{path}"
        );
    }
    // none on: all come on
    assert!(d.toggle_all_breakpoints("/p").await);
    for path in ["/p/a.py", "/p/b.py"] {
        assert_eq!(
            d.breakpoints("/p", None, Some(path)).await["breakpoints"][0]["enabled"],
            true,
            "{path}"
        );
    }
}
