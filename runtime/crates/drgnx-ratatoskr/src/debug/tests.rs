//! A session against the mock adapter (`vor::mock`), on paused time: the launch sequence, stops and their epochs, the
//! stop sequence with its waits, restarts, reverse requests and the session's one end.
use super::session::{self, End, Op, Proc, Request, Sig, Start, Stop, Update};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::time::Instant;
use vor::mock::{Log, Mock, Script};

/// How the fake adapter process ends.
#[derive(Clone, Copy, PartialEq)]
enum Exit {
    /// On its own, once its connection is closed (a well-behaved adapter).
    Itself,
    OnTerm,
    OnKill,
}

#[derive(Clone)]
struct FakeProc {
    exit: Exit,
    signals: Arc<Mutex<Vec<(Sig, Duration)>>>,
    t0: Instant,
    gone: Arc<tokio::sync::Notify>,
    dead: Arc<Mutex<bool>>,
}

impl FakeProc {
    fn new(exit: Exit) -> FakeProc {
        FakeProc {
            exit,
            signals: Arc::default(),
            t0: crate::clock::now(),
            gone: Arc::default(),
            dead: Arc::default(),
        }
    }
    fn signals(&self) -> Vec<(Sig, Duration)> {
        self.signals.lock().unwrap().clone()
    }
    fn die(&self) {
        *self.dead.lock().unwrap() = true;
        self.gone.notify_waiters();
    }
}

impl Proc for FakeProc {
    fn signal(&mut self, sig: Sig) {
        self.signals
            .lock()
            .unwrap()
            .push((sig, crate::clock::now().duration_since(self.t0)));
        if (sig == Sig::Term && self.exit == Exit::OnTerm) || sig == Sig::Kill {
            self.die();
        }
    }
    fn wait(&mut self) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + '_>> {
        Box::pin(async move {
            loop {
                let n = self.gone.notified();
                if *self.dead.lock().unwrap() || self.exit == Exit::Itself {
                    return;
                }
                n.await;
            }
        })
    }
}

const INIT: &str = "initialize";

fn start_of(request: Request, arguments: Value) -> Start {
    Start {
        name: "Python: Current File".into(),
        adapter_id: "debugpy".into(),
        request,
        arguments,
        breakpoints: vec![],
        exception_filters: vec![],
    }
}

fn launch_steps(mut caps: Value) -> Vec<Value> {
    caps["supportsConfigurationDoneRequest"] = json!(true);
    vec![
        json!({"expect": INIT, "args": {"adapterID": "debugpy", "clientID": "drgnx", "linesStartAt1": true,
               "supportsRunInTerminalRequest": true, "supportsStartDebuggingRequest": true,
               "supportsVariablePaging": true, "supportsInvalidatedEvent": true}, "ok": caps}),
        json!({"expect": "launch", "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "configurationDone"}),
    ]
}

struct Run {
    h: session::Handle,
    up: UnboundedReceiver<Update>,
    mock: Mock,
    proc: FakeProc,
}

fn run(start: Start, steps: Vec<Value>, exit: Exit) -> Run {
    let script: Script = serde_json::from_value(Value::Array(steps)).unwrap();
    let (a, b) = tokio::io::duplex(1 << 20);
    let (cr, cw) = tokio::io::split(a);
    let (mr, mw) = tokio::io::split(b);
    let mock = Mock::start(script, mr, mw);
    let (client, incoming) = vor::Client::new(cr, cw);
    let proc = FakeProc::new(exit);
    let (tx, up) = tokio::sync::mpsc::unbounded_channel();
    let h = session::spawn(start, client, incoming, Box::new(proc.clone()), tx);
    Run { h, up, mock, proc }
}

impl Run {
    /// The next update that is not output or a passed-on event.
    async fn next(&mut self) -> Update {
        loop {
            match self
                .up
                .recv()
                .await
                .expect("the session's updates ended early")
            {
                Update::Event { .. } | Update::Breakpoints { .. } => continue,
                u => return u,
            }
        }
    }
    async fn stopped(&mut self) -> Stop {
        loop {
            match self.next().await {
                Update::Stopped(s) => return s,
                Update::Caps(_) | Update::Running { .. } => {}
                u => panic!("not a stop: {u:?}"),
            }
        }
    }
    /// Until the launch is done.
    async fn running(&mut self) {
        loop {
            if let Update::Running { .. } = self.next().await {
                return;
            }
        }
    }
    async fn end(&mut self) -> End {
        loop {
            if let Update::Ended(e) = self.next().await {
                return e;
            }
        }
    }
    async fn finish(mut self) -> (End, Log, FakeProc) {
        let end = self.end().await;
        while let Some(u) = self.up.recv().await {
            assert!(!matches!(u, Update::Ended(_)), "a second end");
        }
        let log = self.mock.finish().await.unwrap();
        (end, log, self.proc)
    }
}

fn stop_fetch(epoch_threads: i64) -> Vec<Value> {
    vec![
        json!({"event": "stopped", "body": {"reason": "breakpoint", "threadId": epoch_threads, "allThreadsStopped": true}}),
        json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "MainThread"}, {"id": 2, "name": "worker"}]}}),
        json!({"expect": "stackTrace", "args": {"threadId": epoch_threads, "startFrame": 0, "levels": 20},
               "ok": {"stackFrames": [{"id": 1000, "name": "main", "line": 9, "column": 1, "source": {"path": "/p/a.py"}},
                                      {"id": 1001, "name": "<module>", "line": 20, "column": 1}],
                      "totalFrames": 2}}),
        json!({"expect": "scopes", "args": {"frameId": 1000},
               "ok": {"scopes": [{"name": "Locals", "variablesReference": 7, "expensive": false},
                                 {"name": "Globals", "variablesReference": 8, "expensive": true}]}}),
        json!({"expect": "variables", "args": {"variablesReference": 7},
               "ok": {"variables": [{"name": "total", "value": "10", "variablesReference": 0}]}}),
    ]
}

fn polite_end() -> Vec<Value> {
    vec![
        json!({"expect": "terminate", "ok": {}}),
        json!({"event": "terminated"}),
        json!({"expect": "disconnect", "args": {"terminateDebuggee": true}, "ok": {}}),
        json!({"die": true}),
    ]
}

#[tokio::test(start_paused = true)]
async fn the_launch_sequence_sends_breakpoints_and_configuration_done_before_the_launch_answer() {
    let mut start = start_of(Request::Launch, json!({"program": "/p/a.py"}));
    start.breakpoints = vec![
        session::SourceBps {
            path: "/p/a.py".into(),
            breakpoints: vec![json!({"line": 9})],
        },
        session::SourceBps {
            path: "/p/b.py".into(),
            breakpoints: vec![json!({"line": 3, "condition": "x > 1"})],
        },
    ];
    start.exception_filters = vec!["uncaught".into()];
    let steps = vec![
        json!({"expect": INIT, "ok": {"supportsConfigurationDoneRequest": true, "supportsTerminateRequest": true,
               "exceptionBreakpointFilters": [{"filter": "uncaught", "label": "Uncaught"}]}}),
        json!({"expect": "launch", "args": {"program": "/p/a.py"}, "defer": true}),
        json!({"event": "initialized"}),
        json!({"any": [
            {"expect": "setBreakpoints", "args": {"source": {"path": "/p/a.py"}, "breakpoints": [{"line": 9}]},
             "ok": {"breakpoints": [{"verified": true, "line": 9}]}},
            {"expect": "setBreakpoints", "args": {"source": {"path": "/p/b.py"}, "breakpoints": [{"line": 3, "condition": "x > 1"}]},
             "ok": {"breakpoints": [{"verified": true, "line": 3}]}},
        ]}),
        json!({"expect": "setExceptionBreakpoints", "args": {"filters": ["uncaught"]}, "ok": {}}),
        json!({"expect": "configurationDone"}),
        json!({"answer": "launch"}),
    ];
    let mut steps = steps;
    steps.extend(polite_end());
    let mut r = run(start, steps, Exit::Itself);
    assert!(matches!(r.next().await, Update::Caps(c) if c["supportsTerminateRequest"] == true));
    // the session is running once the launch is answered
    loop {
        if let Update::Running { .. } = r.next().await {
            break;
        }
    }
    r.h.op(Op::Stop {
        kill_debuggee: None,
    })
    .await
    .unwrap();
    let (end, log, proc) = r.finish().await;
    assert_eq!(end.restart, None);
    assert!(proc.signals().is_empty(), "a polite adapter gets no signal");
    let cmds = log.commands();
    let pos = |c: &str| cmds.iter().position(|x| *x == c).unwrap();
    assert!(pos("setExceptionBreakpoints") < pos("configurationDone"));
}

#[tokio::test(start_paused = true)]
async fn a_failed_launch_ends_the_session_with_its_message() {
    let steps = vec![
        json!({"expect": INIT, "ok": {}}),
        json!({"expect": "launch", "fail": "No such file: /p/a.py"}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ];
    let r = run(start_of(Request::Launch, json!({})), steps, Exit::Itself);
    let (end, _, _) = r.finish().await;
    assert!(
        end.reason.contains("No such file: /p/a.py"),
        "{}",
        end.reason
    );
}

#[tokio::test(start_paused = true)]
async fn a_stop_fetches_threads_frames_scopes_and_the_cheap_variables_in_one_epoch() {
    let mut steps = launch_steps(json!({"supportsTerminateRequest": true}));
    steps.extend(stop_fetch(1));
    steps.extend(polite_end());
    let mut r = run(start_of(Request::Launch, json!({})), steps, Exit::Itself);
    let s = r.stopped().await;
    assert_eq!((s.epoch, s.thread, s.reason.as_str()), (1, 1, "breakpoint"));
    assert_eq!(s.threads.len(), 2);
    assert_eq!(s.frames.len(), 2);
    assert_eq!(s.frame, 1000);
    assert_eq!(s.scopes.len(), 2);
    assert_eq!(s.scopes[0].variables.as_ref().unwrap()[0]["name"], "total");
    assert!(
        s.scopes[1].variables.is_none(),
        "an expensive scope waits to be opened"
    );
    r.h.op(Op::Stop {
        kill_debuggee: None,
    })
    .await
    .unwrap();
    let (_, log, _) = r.finish().await;
    assert!(
        !log.requests
            .iter()
            .any(|(c, a)| c == "variables" && a["variablesReference"] == 8)
    );
}

#[tokio::test(start_paused = true)]
async fn more_frames_come_twenty_at_a_time_while_total_frames_says_there_are_more() {
    let mut steps = launch_steps(json!({"supportsDelayedStackTraceLoading": true}));
    steps.extend([
        json!({"event": "stopped", "body": {"reason": "step", "threadId": 1}}),
        json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
        json!({"expect": "stackTrace", "args": {"levels": 20},
               "ok": {"stackFrames": (0..20).map(|i| json!({"id": i, "name": "f", "line": 1, "column": 1})).collect::<Vec<_>>(),
                      "totalFrames": 45}}),
        json!({"expect": "scopes", "ok": {"scopes": []}}),
        json!({"expect": "stackTrace", "args": {"threadId": 1, "startFrame": 20, "levels": 20},
               "ok": {"stackFrames": (20..40).map(|i| json!({"id": i, "name": "f", "line": 1, "column": 1})).collect::<Vec<_>>(),
                      "totalFrames": 45}}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ]);
    let mut r = run(start_of(Request::Launch, json!({})), steps, Exit::Itself);
    let s = r.stopped().await;
    assert_eq!((s.frames.len(), s.total_frames), (20, Some(45)));
    let frames = r.h.more_frames(s.epoch, 1).await.unwrap();
    assert_eq!(frames.len(), 20);
    r.h.op(Op::Stop {
        kill_debuggee: None,
    })
    .await
    .unwrap();
    r.finish().await;
}

#[tokio::test(start_paused = true)]
async fn a_variables_reference_from_an_old_epoch_is_never_sent() {
    let mut steps = launch_steps(json!({}));
    steps.extend(stop_fetch(1));
    steps.extend([
        json!({"expect": "continue", "args": {"threadId": 1}, "ok": {"allThreadsContinued": true}}),
        json!({"event": "continued", "body": {"threadId": 1, "allThreadsContinued": true}}),
    ]);
    steps.extend(stop_fetch(1));
    steps.extend([
        json!({"expect": "variables", "args": {"variablesReference": 8}, "ok": {"variables": []}}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ]);
    let mut r = run(start_of(Request::Launch, json!({})), steps, Exit::Itself);
    let first = r.stopped().await;
    r.h.op(Op::Continue { thread: None }).await.unwrap();
    let second = r.stopped().await;
    assert_eq!((first.epoch, second.epoch), (1, 2));
    let old = r.h.variables(first.epoch, 8).await;
    assert!(old.is_err(), "an old epoch's reference is refused here");
    assert!(r.h.variables(second.epoch, 8).await.is_ok());
    r.h.op(Op::Stop {
        kill_debuggee: None,
    })
    .await
    .unwrap();
    let (_, log, _) = r.finish().await;
    let n8 = log
        .requests
        .iter()
        .filter(|(c, a)| c == "variables" && a["variablesReference"] == 8)
        .count();
    assert_eq!(n8, 1);
}

#[tokio::test(start_paused = true)]
async fn invalidated_areas_are_fetched_again_in_the_same_epoch() {
    let mut steps = launch_steps(json!({}));
    steps.extend(stop_fetch(1));
    steps.extend([
        json!({"event": "invalidated", "body": {"areas": ["variables"]}}),
        json!({"expect": "scopes", "args": {"frameId": 1000},
               "ok": {"scopes": [{"name": "Locals", "variablesReference": 9, "expensive": false}]}}),
        json!({"expect": "variables", "args": {"variablesReference": 9},
               "ok": {"variables": [{"name": "total", "value": "11", "variablesReference": 0}]}}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ]);
    let mut r = run(start_of(Request::Launch, json!({})), steps, Exit::Itself);
    let a = r.stopped().await;
    let b = r.stopped().await;
    assert_eq!(a.epoch, b.epoch);
    assert_eq!(b.scopes[0].variables.as_ref().unwrap()[0]["value"], "11");
    r.h.op(Op::Stop {
        kill_debuggee: None,
    })
    .await
    .unwrap();
    r.finish().await;
}

#[tokio::test(start_paused = true)]
async fn a_silent_adapter_gets_terminate_disconnect_sigterm_then_sigkill_on_time() {
    let mut steps = launch_steps(json!({"supportsTerminateRequest": true}));
    steps.extend([
        json!({"expect": "terminate", "silent": true}),
        json!({"expect": "disconnect", "args": {"terminateDebuggee": true}, "silent": true}),
    ]);
    let mut r = run(start_of(Request::Launch, json!({})), steps, Exit::OnKill);
    loop {
        if let Update::Running { .. } = r.next().await {
            break;
        }
    }
    let t0 = crate::clock::now().duration_since(r.proc.t0);
    r.h.op(Op::Stop {
        kill_debuggee: None,
    })
    .await
    .unwrap();
    let end = r.end().await;
    let sig = r.proc.signals();
    assert_eq!(
        sig.len(),
        2,
        "{:?}",
        sig.iter().map(|s| s.0).collect::<Vec<_>>()
    );
    assert_eq!(sig[0].0, Sig::Term);
    assert_eq!(
        sig[0].1 - t0,
        Duration::from_secs(4),
        "terminate 2 s, disconnect 2 s"
    );
    assert_eq!(sig[1].0, Sig::Kill);
    assert_eq!(sig[1].1 - sig[0].1, Duration::from_secs(1));
    assert!(end.reason.contains("stopped"), "{}", end.reason);
    drop(r.h);
    drop(r.up);
    // the mock never saw its connection end cleanly: it is not checked here
}

#[tokio::test(start_paused = true)]
async fn an_attach_session_disconnects_and_leaves_the_debuggee_running() {
    let mut steps = vec![
        json!({"expect": INIT, "ok": {"supportsTerminateRequest": true, "supportsConfigurationDoneRequest": true}}),
        json!({"expect": "attach", "args": {"processId": 42}, "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "configurationDone"}),
    ];
    steps.extend([
        json!({"expect": "disconnect", "args": {"terminateDebuggee": false}, "ok": {}}),
        json!({"die": true}),
    ]);
    let mut r = run(
        start_of(Request::Attach, json!({"processId": 42})),
        steps,
        Exit::Itself,
    );
    loop {
        if let Update::Running { .. } = r.next().await {
            break;
        }
    }
    r.h.op(Op::Stop {
        kill_debuggee: None,
    })
    .await
    .unwrap();
    let (_, log, proc) = r.finish().await;
    assert!(!log.commands().contains(&"terminate"));
    assert!(proc.signals().is_empty());
}

#[tokio::test(start_paused = true)]
async fn without_terminate_support_a_stop_starts_at_disconnect() {
    let mut steps = launch_steps(json!({}));
    steps.extend([
        json!({"expect": "disconnect", "args": {"terminateDebuggee": true}, "ok": {}}),
        json!({"die": true}),
    ]);
    let mut r = run(start_of(Request::Launch, json!({})), steps, Exit::Itself);
    r.running().await;
    r.h.op(Op::Stop {
        kill_debuggee: None,
    })
    .await
    .unwrap();
    r.finish().await;
}

#[tokio::test(start_paused = true)]
async fn restart_uses_the_request_when_the_adapter_has_it() {
    let mut steps = launch_steps(json!({"supportsRestartRequest": true}));
    steps.extend([
        json!({"expect": "restart", "args": {"arguments": {"program": "/p/a.py"}}, "ok": {}}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ]);
    let mut r = run(
        start_of(Request::Launch, json!({"program": "/p/a.py"})),
        steps,
        Exit::Itself,
    );
    r.running().await;
    r.h.op(Op::Restart).await.unwrap();
    r.h.op(Op::Stop {
        kill_debuggee: None,
    })
    .await
    .unwrap();
    let (end, _, _) = r.finish().await;
    assert_eq!(end.restart, None);
}

#[tokio::test(start_paused = true)]
async fn restart_without_the_request_stops_and_asks_for_a_new_start() {
    let mut steps = launch_steps(json!({}));
    steps.extend([
        json!({"expect": "disconnect", "args": {"terminateDebuggee": true}, "ok": {}}),
        json!({"die": true}),
    ]);
    let mut r = run(start_of(Request::Launch, json!({})), steps, Exit::Itself);
    r.running().await;
    r.h.op(Op::Restart).await.unwrap();
    let (end, _, _) = r.finish().await;
    assert_eq!(
        end.restart,
        Some(Value::Null),
        "start again, with no `__restart` value"
    );
}

#[tokio::test(start_paused = true)]
async fn a_terminated_event_with_restart_passes_its_value_on() {
    let mut steps = launch_steps(json!({}));
    steps.extend([
        json!({"event": "terminated", "body": {"restart": {"port": 9229}}}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ]);
    let r = run(start_of(Request::Launch, json!({})), steps, Exit::Itself);
    let (end, _, _) = r.finish().await;
    assert_eq!(end.restart, Some(json!({"port": 9229})));
    let mut again = start_of(Request::Launch, json!({"program": "x"}));
    again.restart_with(end.restart.unwrap());
    assert_eq!(again.arguments["__restart"], json!({"port": 9229}));
}

#[tokio::test(start_paused = true)]
async fn exited_then_terminated_ends_the_session_once() {
    let mut steps = launch_steps(json!({}));
    steps.extend([
        json!({"event": "exited", "body": {"exitCode": 3}}),
        json!({"event": "terminated"}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ]);
    let r = run(start_of(Request::Launch, json!({})), steps, Exit::Itself);
    let (end, _, _) = r.finish().await;
    assert_eq!(end.exit_code, Some(3));
}

#[tokio::test(start_paused = true)]
async fn an_adapter_that_dies_ends_the_session_once_and_is_reaped() {
    let mut steps = launch_steps(json!({}));
    steps.push(json!({"die": true}));
    let mut r = run(start_of(Request::Launch, json!({})), steps, Exit::OnTerm);
    let end = r.end().await;
    assert!(end.reason.contains("adapter"), "{}", end.reason);
    let sig = r.proc.signals();
    assert_eq!(
        sig.iter().map(|s| s.0).collect::<Vec<_>>(),
        [Sig::Term],
        "reaped: SIGTERM after its 2 s"
    );
    while let Some(u) = r.up.recv().await {
        assert!(!matches!(u, Update::Ended(_)));
    }
}

#[tokio::test(start_paused = true)]
async fn run_in_terminal_is_handed_up_and_answered_with_the_pid() {
    let mut steps = launch_steps(json!({}));
    steps.extend([
        json!({"reverse": "runInTerminal", "arguments": {"kind": "integrated", "cwd": "/p", "args": ["python3", "a.py"]},
               "answer": {"processId": 4242}}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ]);
    let mut r = run(start_of(Request::Launch, json!({})), steps, Exit::Itself);
    loop {
        match r.next().await {
            Update::RunInTerminal { arguments, reply } => {
                assert_eq!(arguments["args"][0], "python3");
                reply.send(Ok(4242)).unwrap();
                break;
            }
            Update::Caps(_) | Update::Running { .. } => {}
            u => panic!("{u:?}"),
        }
    }
    r.h.op(Op::Stop {
        kill_debuggee: None,
    })
    .await
    .unwrap();
    r.finish().await;
}

#[tokio::test(start_paused = true)]
async fn start_debugging_is_handed_up_and_answered() {
    let mut steps = launch_steps(json!({}));
    steps.extend([
        json!({"reverse": "startDebugging", "arguments": {"request": "launch", "configuration": {"__pendingTargetId": "t1"}},
               "answer": {}}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ]);
    let mut r = run(start_of(Request::Launch, json!({})), steps, Exit::Itself);
    loop {
        match r.next().await {
            Update::StartDebugging { arguments, reply } => {
                assert_eq!(arguments["configuration"]["__pendingTargetId"], "t1");
                reply.send(Ok(())).unwrap();
                break;
            }
            Update::Caps(_) | Update::Running { .. } => {}
            u => panic!("{u:?}"),
        }
    }
    r.h.op(Op::Stop {
        kill_debuggee: None,
    })
    .await
    .unwrap();
    r.finish().await;
}

#[tokio::test(start_paused = true)]
async fn dropping_the_handle_stops_the_session() {
    let mut steps = launch_steps(json!({}));
    steps.extend([
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ]);
    let mut r = run(start_of(Request::Launch, json!({})), steps, Exit::Itself);
    loop {
        if let Update::Running { .. } = r.next().await {
            break;
        }
    }
    let Run {
        h, mut up, mock, ..
    } = r;
    drop(h);
    loop {
        if let Update::Ended(_) = up.recv().await.expect("an end") {
            break;
        }
    }
    mock.finish().await.unwrap();
}
