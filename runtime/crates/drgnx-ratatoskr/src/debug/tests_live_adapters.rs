//! Live: the spec §13 scenario against each built-in adapter that drgnx tests (debugpy, delve, lldb-dap, js-debug,
//! CodeLLDB), through the hub's sessions and the production launcher. A launch with three breakpoints (a hit count, a condition, a
//! logpoint), the hit-count stop, the condition stop with Variables (a structure expanded), `setVariable` and a watch,
//! step in, out and over, an exception filter's stop, a restart, a child session (debugpy's `subprocess`, js-debug's
//! `child_process.fork`), lldb-dap's `runInTerminal`, and Stop. debugpy and lldb-dap also attach to a running process
//! by PID, and Stop leaves it running. Each test prints a `T10-REPORT` line (capabilities, exception filters, what
//! was measured) for the plan's ledger; the `*_probe_cost` tests print `T10-PROBES` (a probe's cost and value text).
//!
//! Run alone, in the adapter image (`test/container/Containerfile.debug`) with ptrace (`ctr.sh --ptrace`):
//! `nextest run -p drgnx-ratatoskr --lib --features test-hooks --run-ignored only debug::tests_live_adapters`.
//! `DRGNX_DEBUG_LIVE_PYTHON` (default `python3`, with debugpy), `DRGNX_DEBUG_LIVE_JS_DEBUG` (default
//! `/opt/js-debug/src/dapDebugServer.js`) and `DRGNX_DEBUG_LIVE_CODELLDB` (default
//! `/opt/codelldb/extension/adapter/codelldb`) say where those adapters are; delve (`dlv`) and `lldb-dap` are found on
//! `PATH`. CodeLLDB and lldb-dap also break on a value change (a data breakpoint).
use super::adapters::{self, Found, Table, Transport};
use super::breakpoints::Op as BpOp;
use super::session::{Op, Request, Start, Stop};
use super::wire::Spawned;
use super::{BoxFut, Connected, Debug, Launcher, Opened, Sink, Terminals};
use serde_json::{Value, json};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;
use vor::Incoming;

/// What the hub tells the editors.
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
    fn dump(&self) -> String {
        let all = self.0.lock().unwrap();
        let from = all.len().saturating_sub(40);
        all[from..]
            .iter()
            .map(|(n, d)| format!("{n} {d}"))
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// Waits (real time, at most 90 s) for an event NAME at index FROM or later that PRED accepts; the index after it
    /// and its data.
    async fn next(&self, from: usize, name: &str, pred: impl Fn(&Value) -> bool) -> (usize, Value) {
        for _ in 0..4500 {
            let hit = self
                .0
                .lock()
                .unwrap()
                .iter()
                .enumerate()
                .skip(from)
                .find(|(_, (n, d))| n == name && pred(d))
                .map(|(i, (_, d))| (i + 1, d.clone()));
            if let Some(h) = hit {
                return h;
            }
            crate::clock::sleep(Duration::from_millis(20)).await;
        }
        panic!("no {name} after {from}; the last events:\n{}", self.dump());
    }

    /// The next stop at index FROM or later: a `debug-frame` to the editor that started it, of a session and epoch no
    /// earlier frame had (an `invalidated` after `setVariable` publishes the same stop again).
    async fn stop(&self, from: usize) -> (usize, Value) {
        let key = |d: &Value| (d["session"].clone(), d["epoch"].clone());
        let before: Vec<(Value, Value)> = {
            let all = self.0.lock().unwrap();
            all[..from.min(all.len())]
                .iter()
                .filter(|(n, _)| n == "debug-frame")
                .map(|(_, d)| key(d))
                .collect()
        };
        let mut from = from;
        loop {
            let (next, f) = self
                .next(from, "debug-frame", |d| d["open"] == json!(true))
                .await;
            if !before.contains(&key(&f)) {
                return (next, f);
            }
            from = next;
        }
    }
}

/// The adapter's own events, as it sent them (the console is not in the hub yet: the logpoints' `output` is read here).
type Seen = Arc<Mutex<Vec<(String, Value)>>>;

/// The production launcher with a tap on what the adapter sends.
struct Tap {
    inner: Arc<dyn Launcher>,
    seen: Seen,
}

impl Tap {
    fn wrap(&self, c: Connected) -> Connected {
        let (tx, rx) = mpsc::unbounded_channel();
        let mut incoming = c.incoming;
        let seen = self.seen.clone();
        crate::clock::spawn("test:live-tap", async move {
            while let Some(m) = incoming.recv().await {
                if let Incoming::Event { event, body } = &m {
                    seen.lock().unwrap().push((event.clone(), body.clone()));
                }
                if tx.send(m).is_err() {
                    break;
                }
            }
        });
        Connected {
            client: c.client,
            incoming: rx,
            proc: c.proc,
        }
    }
}

impl Launcher for Tap {
    fn connect(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move { Ok(self.wrap(self.inner.connect().await?)) })
    }
    fn child(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move { Ok(self.wrap(self.inner.child().await?)) })
    }
}

/// `runInTerminal` as a plain process (the terminal itself is the editor's, tested there).
#[derive(Default)]
struct Procs(Mutex<Vec<std::process::Child>>);

impl Terminals for Procs {
    fn open(
        &self,
        _: u64,
        cwd: String,
        args: Vec<String>,
        env: Vec<(String, String)>,
    ) -> BoxFut<'_, Result<Opened, String>> {
        Box::pin(async move {
            let (program, rest) = args.split_first().ok_or("no command")?;
            let mut cmd = std::process::Command::new(program);
            cmd.args(rest).envs(env);
            if !cwd.is_empty() {
                cmd.current_dir(cwd);
            }
            let c = cmd.spawn().map_err(|e| format!("{program}: {e}"))?;
            let pid = i64::from(c.id());
            self.0.lock().unwrap().push(c);
            Ok(Opened {
                term: "t1".into(),
                view: "v1".into(),
                pid,
                editor: None,
            })
        })
    }
}

impl Drop for Procs {
    fn drop(&mut self) {
        for c in self.0.lock().unwrap().iter_mut() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

/// The adapter ID's launcher as the hub builds it (`debug/start`): the table's command line for FOUND, a free port for
/// a TCP adapter, this process's environment with ENV over it, started in DIR.
fn launcher(id: &str, found: &Found, dir: &Path, env: &[(String, String)]) -> Arc<dyn Launcher> {
    let table = Table::builtin();
    let adapter = table.by_id(id).unwrap();
    let where_ = adapters::Env {
        path: vec![],
        tools: dir.to_path_buf(),
    };
    let tcp = adapter.start.as_ref().is_some_and(|s| s.stdio.is_none());
    let port = tcp.then(|| adapters::free_port().unwrap());
    let (how, argv) = adapters::command(adapter, found, &where_, port).unwrap();
    let mut vars: Vec<(OsString, OsString)> = std::env::vars_os()
        .filter(|(k, _)| !env.iter().any(|(e, _)| k == e.as_str()))
        .collect();
    vars.extend(env.iter().map(|(k, v)| (k.into(), v.into())));
    Arc::new(Spawned {
        argv,
        env: vars,
        cwd: dir.to_path_buf(),
        port: (how == Transport::Tcp).then_some(port).flatten(),
    })
}

/// The adapter ID found on `PATH` (delve, lldb-dap).
fn on_path(id: &str) -> Found {
    let table = Table::builtin();
    let env = adapters::Env {
        path: std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).collect(),
        tools: PathBuf::new(),
    };
    adapters::find(table.by_id(id).unwrap(), &env)
        .unwrap_or_else(|| panic!("{id} is not on PATH (run in the adapter image)"))
}

fn python() -> Found {
    Found::Python(
        std::env::var("DRGNX_DEBUG_LIVE_PYTHON")
            .unwrap_or_else(|_| "python3".into())
            .into(),
    )
}

fn js_debug() -> Found {
    Found::Program(
        std::env::var("DRGNX_DEBUG_LIVE_JS_DEBUG")
            .unwrap_or_else(|_| "/opt/js-debug/src/dapDebugServer.js".into())
            .into(),
    )
}

fn live_dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("drgnx-live-adapters-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

fn write(dir: &Path, name: &str, text: &str) -> PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, text).unwrap();
    p
}

/// Runs PROGRAM with ARGS in DIR; panics with its output when it fails.
fn run(dir: &Path, program: &str, args: &[&str]) {
    let o = std::process::Command::new(program)
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap_or_else(|e| panic!("{program}: {e}"));
    assert!(
        o.status.success(),
        "{program} {args:?}: {}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
}

/// The variable NAME in STOP's first scope that has variables (Locals): its `value` and `variablesReference`, and the
/// scope's reference.
fn local(stop: &Stop, name: &str) -> (String, i64, i64) {
    for s in &stop.scopes {
        let Some(vars) = &s.variables else { continue };
        if let Some(v) = vars.iter().find(|v| v["name"] == json!(name)) {
            return (
                v["value"].as_str().unwrap_or_default().to_owned(),
                v["variablesReference"].as_i64().unwrap_or(0),
                s.scope["variablesReference"].as_i64().unwrap_or(0),
            );
        }
    }
    panic!("no variable {name} in {:#?}", stop.scopes);
}

/// The leading integer of VALUE (`3`, `3 (0x3)`, `int: 3`).
fn int_of(value: &str) -> i64 {
    let digits: String = value
        .trim_start_matches(|c: char| !c.is_ascii_digit() && c != '-')
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '-')
        .collect();
    digits
        .parse()
        .unwrap_or_else(|_| panic!("no integer in {value:?}"))
}

/// Whether PID runs (not gone, a zombie or stopped by a tracer).
fn running(pid: u32) -> bool {
    let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
        return false;
    };
    let state = stat
        .rsplit_once(") ")
        .and_then(|(_, r)| r.chars().next())
        .unwrap_or('?');
    !matches!(state, 'Z' | 'X' | 't' | 'T')
}

/// The capabilities that are on, and the exception filters (`id`, `id*` for the defaults).
fn caps_report(caps: &Value) -> Value {
    let on: Vec<&String> = caps
        .as_object()
        .map(|m| {
            m.iter()
                .filter(|(_, v)| **v == json!(true))
                .map(|(k, _)| k)
                .collect()
        })
        .unwrap_or_default();
    let filters: Vec<String> = caps["exceptionBreakpointFilters"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|f| {
                    let star = if f["default"] == json!(true) { "*" } else { "" };
                    format!("{}{star}", f["filter"].as_str().unwrap_or("?"))
                })
                .collect()
        })
        .unwrap_or_default();
    json!({"on": on, "filters": filters})
}

/// The session's capabilities, from the hub's state.
fn caps_of(ev: &Events, session: &str) -> Value {
    ev.0.lock()
        .unwrap()
        .iter()
        .rev()
        .filter(|(n, _)| n == "debug-state")
        .flat_map(|(_, d)| d["sessions"].as_array().cloned().unwrap_or_default())
        .find(|s| s["id"] == json!(session) && !s["caps"].is_null())
        .map(|s| s["caps"].clone())
        .unwrap_or(Value::Null)
}

/// The scenario's program, by line.
struct Lines {
    /// `total = add(total, i)` in the loop: the condition `i == 3`.
    cond: u32,
    /// The loop's print: the logpoint `i is {i}`, and where Step Over lands.
    log: u32,
    /// `count += 1` in the loop: the hit count 2.
    hit: u32,
    /// `add`'s first line (Step Into).
    callee: u32,
    /// The exception's line in the program (none: the stop is outside it, in the runtime).
    exc: Option<u32>,
}

struct Scn {
    id: &'static str,
    found: Found,
    dir: PathBuf,
    file: PathBuf,
    config: Value,
    env: Vec<(String, String)>,
    lines: Lines,
    /// The exception filter chosen (none: the adapter stops on its own, as delve on an unrecovered panic).
    filter: Option<&'static str>,
    /// The structure in Locals and one of its fields' names.
    structure: (&'static str, &'static str),
    /// A child program and the line to stop at in it.
    child: Option<(PathBuf, u32)>,
}

async fn add(
    d: &Debug,
    root: &str,
    path: &Path,
    line: u32,
    cond: Option<&str>,
    hit: Option<&str>,
    log: Option<&str>,
) -> u64 {
    let v = d
        .breakpoints(
            root,
            Some(BpOp::Add {
                path: path.display().to_string(),
                line,
                column: None,
                enabled: true,
                condition: cond.map(str::to_owned),
                hit: hit.map(str::to_owned),
                log: log.map(str::to_owned),
            }),
            None,
        )
        .await;
    v["added"].as_u64().unwrap()
}

async fn remove(d: &Debug, root: &str, id: u64) {
    d.breakpoints(root, Some(BpOp::Remove { id }), None).await;
}

fn line_of(f: &Value) -> u32 {
    u32::try_from(f["line"].as_i64().unwrap_or(0)).unwrap_or(0)
}

fn path_is(f: &Value, file: &Path) -> bool {
    f["path"]
        .as_str()
        .is_some_and(|p| Path::new(p) == file || std::fs::canonicalize(p).is_ok_and(|c| c == file))
}

/// Whether frame F is an exception filter's stop: reason `exception`, or (CodeLLDB, whose filters are breakpoints on
/// the runtime's throw) a `breakpoint` stop in `__cxa_throw`.
fn an_exception_stop(f: &Value) -> bool {
    let thrown = f["name"]
        .as_str()
        .is_some_and(|n| n.contains("__cxa_throw"));
    f["reason"] == json!("exception") || (f["reason"] == json!("breakpoint") && thrown)
}

/// The spec §13 scenario; its report.
async fn scenario(s: Scn) -> Value {
    let ev = Arc::new(Events::default());
    let seen: Seen = Arc::default();
    let terms = Arc::new(Procs::default());
    let d = Debug::new(ev.clone(), terms.clone());
    let root = s.dir.display().to_string();
    let ty = s.config["type"].as_str().unwrap().to_owned();
    let l = &s.lines;
    let hit = add(&d, &root, &s.file, l.hit, None, Some("2"), None).await;
    let cond = add(&d, &root, &s.file, l.cond, Some("i == 3"), None, None).await;
    let log = add(&d, &root, &s.file, l.log, None, None, Some("i is {i}")).await;
    if let Some((child, line)) = &s.child {
        add(&d, &root, child, *line, None, None, None).await;
    }
    if let Some(f) = s.filter {
        d.store(&root, |st| st.set_filters(&ty, vec![f.to_owned()]));
    }
    let start = Start {
        name: s.id.into(),
        adapter_id: ty.clone(),
        request: Request::Launch,
        arguments: super::launch::adapter_arguments(&s.config),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    let tap = Arc::new(Tap {
        inner: launcher(s.id, &s.found, &s.dir, &s.env),
        seen: seen.clone(),
    });
    let t0 = crate::clock::now();
    let root_sid = d.start(1, &root, start, tap).await.unwrap();
    let mut report = json!({"adapter": s.id});

    // the hit count: its second hit (or later: the adapter's reading of "2" is reported)
    let (c, f) = ev.stop(0).await;
    report["first_stop_ms"] = json!(t0.elapsed().as_millis());
    assert!(
        path_is(&f, &s.file) && line_of(&f) == l.hit,
        "hit count: {f}"
    );
    let sid = f["session"].as_str().unwrap().to_owned();
    report["caps"] = caps_report(&caps_of(&ev, &sid));
    if let Some(filter) = s.filter {
        assert!(
            report["caps"]["filters"]
                .as_array()
                .unwrap()
                .iter()
                .any(|x| x.as_str().unwrap().trim_end_matches('*') == filter),
            "no filter {filter}: {}",
            report["caps"]
        );
    }
    let stop = d.stop_of(&sid).unwrap();
    let (i, _, _) = local(&stop, "i");
    report["hit_count_2_stops_at_i"] = json!(int_of(&i));
    assert!(int_of(&i) >= 1, "the hit count stopped at i = {i}");
    remove(&d, &root, hit).await;
    d.control(&sid, Op::Continue { thread: None })
        .await
        .unwrap();

    // the condition
    let (c, f) = ev.stop(c).await;
    assert!(
        path_is(&f, &s.file) && line_of(&f) == l.cond,
        "condition: {f}"
    );
    let stop = d.stop_of(&sid).unwrap();
    let (i, _, _) = local(&stop, "i");
    assert_eq!(int_of(&i), 3, "the condition i == 3");
    let (total, _, scope) = local(&stop, "total");
    assert_eq!(int_of(&total), 3, "0 + 1 + 2");
    // the logpoint wrote its lines (and nothing stopped there)
    let logs: Vec<String> = seen
        .lock()
        .unwrap()
        .iter()
        .filter(|(n, _)| n == "output")
        .filter_map(|(_, b)| b["output"].as_str().map(str::to_owned))
        .filter(|o| o.contains("i is"))
        .collect();
    assert!(
        logs.iter().any(|o| o.contains("i is 2")),
        "logpoint output: {logs:?}"
    );
    report["logpoint"] = json!(logs.first());
    // Variables: the structure expanded
    let h = d.session(&sid).unwrap();
    let (shown, reference, _) = local(&stop, s.structure.0);
    assert!(reference > 0, "{} has no children: {shown}", s.structure.0);
    let kids = h.variables(stop.epoch, reference).await.unwrap();
    let names: Vec<&str> = kids.iter().filter_map(|k| k["name"].as_str()).collect();
    assert!(
        names.iter().any(|n| n.contains(s.structure.1)),
        "{} children: {names:?}",
        s.structure.0
    );
    report["structure"] = json!({"value": shown, "children": names});
    // set a value, and a watch sees it
    let set = h
        .request(
            "setVariable",
            json!({"variablesReference": scope, "name": "total", "value": "100"}),
        )
        .await
        .unwrap();
    assert_eq!(
        int_of(set["value"].as_str().unwrap_or_default()),
        100,
        "{set}"
    );
    let watch = h
        .request(
            "evaluate",
            json!({"expression": "total + 1", "frameId": stop.frame, "context": "watch"}),
        )
        .await
        .unwrap();
    assert_eq!(
        int_of(watch["result"].as_str().unwrap_or_default()),
        101,
        "{watch}"
    );
    report["watch"] = watch["result"].clone();

    // step in, out, over
    d.control(&sid, Op::StepIn { thread: None }).await.unwrap();
    // in: `add`'s first line, or (delve: the prologue) its `func` line just above
    let (c, f) = ev.stop(c).await;
    let into = line_of(&f);
    assert!(
        (into == l.callee || into + 1 == l.callee)
            && f["name"].as_str().is_some_and(|n| n.contains("add")),
        "step in: {f}"
    );
    report["step_in_line"] = json!(if into == l.callee {
        "the body's"
    } else {
        "the function's"
    });
    // out: back on the call's line, or (js-debug: the assignment has no stop of its own) on the next
    d.control(&sid, Op::StepOut { thread: None }).await.unwrap();
    let (c, f) = ev.stop(c).await;
    let out = line_of(&f);
    assert!(
        path_is(&f, &s.file) && (out == l.cond || out == l.log),
        "step out: {f}"
    );
    report["step_out_line"] = json!(if out == l.cond {
        "the call's"
    } else {
        "the next"
    });
    d.control(&sid, Op::Next { thread: None }).await.unwrap();
    let (c, f) = ev.stop(c).await;
    let over = if out == l.cond { l.log } else { l.hit };
    assert!(
        path_is(&f, &s.file) && line_of(&f) == over,
        "step over: {f}"
    );
    // the value set went into the program: add(100, 3)
    let (total, _, _) = local(&d.stop_of(&sid).unwrap(), "total");
    assert_eq!(int_of(&total), 103, "after setVariable");
    remove(&d, &root, cond).await;
    remove(&d, &root, log).await;
    d.control(&sid, Op::Continue { thread: None })
        .await
        .unwrap();

    // the exception
    let (c, f) = ev.stop(c).await;
    assert!(an_exception_stop(&f), "exception: {f}");
    if let Some(line) = l.exc {
        assert!(
            path_is(&f, &s.file) && line_of(&f) == line,
            "exception: {f}"
        );
    }
    report["exception"] = f["exception"].clone();

    // restart: the same configuration again, to the exception
    d.control(&sid, Op::Restart).await.unwrap();
    let (c, f) = ev.stop(c).await;
    assert!(an_exception_stop(&f), "after the restart: {f}");
    let sid2 = f["session"].as_str().unwrap().to_owned();
    report["restart"] = json!(if sid2 == sid {
        "request"
    } else {
        "new session"
    });

    // the child
    if let Some((child, line)) = &s.child {
        d.control(&sid2, Op::Continue { thread: None })
            .await
            .unwrap();
        let (_, f) = ev.stop(c).await;
        assert!(path_is(&f, child) && line_of(&f) == *line, "child: {f}");
        let csid = f["session"].as_str().unwrap().to_owned();
        let parent = d
            .list()
            .into_iter()
            .find(|(id, _)| *id == csid)
            .and_then(|(_, p)| p);
        assert!(
            parent.is_some() && csid != sid2,
            "child {csid} of {parent:?}"
        );
        report["child"] = json!({"session": csid, "parent": parent});
    }

    // the debuggee's pid, when the adapter said it
    let pid = seen
        .lock()
        .unwrap()
        .iter()
        .rev()
        .find(|(n, _)| n == "process")
        .and_then(|(_, b)| b["systemProcessId"].as_u64())
        .and_then(|p| u32::try_from(p).ok());
    report["run_in_terminal"] = json!(
        ev.0.lock()
            .unwrap()
            .iter()
            .any(|(n, _)| n == "debug-terminal")
    );
    d.control(
        &root_sid,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .ok();
    d.shutdown().await;
    for _ in 0..1500 {
        if d.list().is_empty() {
            break;
        }
        crate::clock::sleep(Duration::from_millis(20)).await;
    }
    assert!(d.list().is_empty(), "sessions left: {:?}", d.list());
    if let Some(pid) = pid {
        for _ in 0..250 {
            if !running(pid) {
                break;
            }
            crate::clock::sleep(Duration::from_millis(20)).await;
        }
        assert!(!running(pid), "the debuggee {pid} runs on after Stop");
    }
    eprintln!("T10-REPORT {report}");
    report
}

/// Attach to PROGRAM (already running) with CONFIG (its pid filled in), stop at FILE:LINE, Stop: the program runs on.
async fn attach(
    id: &'static str,
    found: Found,
    dir: &Path,
    mut prog: std::process::Child,
    config: Value,
    file: &Path,
    line: u32,
) {
    let pid = prog.id();
    let ev = Arc::new(Events::default());
    let seen: Seen = Arc::default();
    let d = Debug::new(ev.clone(), Arc::new(Procs::default()));
    let root = dir.display().to_string();
    add(&d, &root, file, line, None, None, None).await;
    let start = Start {
        name: id.into(),
        adapter_id: config["type"].as_str().unwrap().into(),
        request: Request::Attach,
        arguments: super::launch::adapter_arguments(&config),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    let tap = Arc::new(Tap {
        inner: launcher(id, &found, dir, &[]),
        seen,
    });
    let sid = d.start(1, &root, start, tap).await.unwrap();
    let (_, f) = ev.stop(0).await;
    assert!(path_is(&f, file) && line_of(&f) == line, "attach: {f}");
    let caps = caps_report(&caps_of(&ev, &sid));
    d.control(
        &sid,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    assert!(d.list().is_empty(), "sessions left: {:?}", d.list());
    // it runs on, untraced, for a while
    crate::clock::sleep(Duration::from_millis(500)).await;
    let alive = prog.try_wait().unwrap().is_none() && running(pid);
    let _ = prog.kill();
    let _ = prog.wait();
    assert!(
        alive,
        "the attached program {pid} did not run on after Stop"
    );
    eprintln!(
        "T10-REPORT {}",
        json!({"adapter": id, "attach": true, "caps": caps})
    );
}

const PY: &str = r#"import subprocess, sys, os


def add(a, b):
    s = a + b
    return s


def main():
    point = {"x": 1, "y": [1, 2]}
    total = 0
    count = 0
    for i in range(5):
        total = add(total, i)
        print("tick", i)
        count += 1
    try:
        raise ValueError("boom")
    except ValueError:
        pass
    print("done", total, count, point["x"])
    subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "child.py")], check=True)


main()
"#;

const CHILD_PY: &str = "n = 0\nn += 1\nprint(n)\n";

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: debugpy in the adapter image (see the module's doc)"]
async fn debugpy_runs_the_scenario_with_a_subprocess_child() {
    let dir = live_dir("py");
    let file = write(&dir, "prog.py", PY);
    let child = write(&dir, "child.py", CHILD_PY);
    let config = json!({"type": "debugpy", "request": "launch", "name": "py", "program": file, "cwd": dir,
                        "justMyCode": true, "subProcess": true});
    scenario(Scn {
        id: "debugpy",
        found: python(),
        dir: dir.clone(),
        file,
        config,
        env: vec![],
        lines: Lines {
            cond: 14,
            log: 15,
            hit: 16,
            callee: 5,
            exc: Some(18),
        },
        filter: Some("raised"),
        structure: ("point", "x"),
        child: Some((child, 2)),
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: debugpy and gdb in the adapter image, with ptrace (see the module's doc)"]
async fn debugpy_attaches_to_a_pid_and_stop_leaves_it_running() {
    let dir = live_dir("pya");
    let file = write(
        &dir,
        "loop.py",
        "import time\nn = 0\nwhile True:\n    n += 1\n    time.sleep(0.05)\n",
    );
    let Found::Python(py) = python() else {
        unreachable!()
    };
    let prog = std::process::Command::new(&py)
        .arg(&file)
        .current_dir(&dir)
        .spawn()
        .unwrap();
    crate::clock::sleep(Duration::from_millis(500)).await;
    let config = json!({"type": "debugpy", "request": "attach", "name": "pya", "processId": prog.id(),
                        "justMyCode": true});
    attach("debugpy", python(), &dir, prog, config, &file, 4).await;
}

const GO: &str = "package main

import (
\t\"errors\"
\t\"fmt\"
)

type Point struct {
\tX int
\tY []int
}

func add(a, b int) int {
\ts := a + b
\treturn s
}

func main() {
\tpoint := Point{X: 1, Y: []int{1, 2}}
\ttotal := 0
\tcount := 0
\tfor i := 0; i < 5; i++ {
\t\ttotal = add(total, i)
\t\tfmt.Println(\"tick\", i)
\t\tcount++
\t}
\tfmt.Println(\"done\", total, count, point.X)
\tpanic(errors.New(\"boom\"))
}
";

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: delve in the adapter image, with ptrace (see the module's doc)"]
async fn delve_runs_the_scenario() {
    let dir = live_dir("go");
    let file = write(&dir, "main.go", GO);
    let d = dir.display();
    let env = vec![
        ("GOCACHE".to_owned(), format!("{d}/gocache")),
        ("GOPATH".to_owned(), format!("{d}/gopath")),
        ("GOTOOLCHAIN".to_owned(), "local".to_owned()),
        ("GOFLAGS".to_owned(), String::new()),
        ("GO111MODULE".to_owned(), "off".to_owned()),
    ];
    let config = json!({"type": "go", "request": "launch", "name": "go", "mode": "debug", "program": file,
                        "cwd": dir, "output": dir.join("debug_bin")});
    scenario(Scn {
        id: "delve",
        found: on_path("delve"),
        dir: dir.clone(),
        file,
        config,
        env,
        lines: Lines {
            cond: 23,
            log: 24,
            hit: 25,
            callee: 14,
            exc: None,
        },
        filter: None,
        structure: ("point", "X"),
        child: None,
    })
    .await;
}

const CPP: &str = r#"#include <cstdio>
#include <stdexcept>

struct Point {
  int x;
  int y[2];
};

int add(int a, int b) {
  int s = a + b;
  return s;
}

int main() {
  Point point = {1, {1, 2}};
  int total = 0;
  int count = 0;
  for (int i = 0; i < 5; i++) {
    total = add(total, i);
    std::printf("tick %d\n", i);
    count++;
  }
  try {
    throw std::runtime_error("boom");
  } catch (const std::exception &) {
  }
  std::printf("done %d %d %d\n", total, count, point.x);
  return 0;
}
"#;

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: lldb-dap and clang in the adapter image, with ptrace (see the module's doc)"]
async fn lldb_dap_runs_the_scenario_in_a_terminal() {
    let dir = live_dir("cpp");
    let file = write(&dir, "prog.cpp", CPP);
    run(&dir, "clang++", &["-g", "-O0", "-o", "prog", "prog.cpp"]);
    let config = json!({"type": "lldb-dap", "request": "launch", "name": "cpp", "program": dir.join("prog"),
                        "cwd": dir, "disableASLR": false, "runInTerminal": true});
    let r = scenario(Scn {
        id: "lldb-dap",
        found: on_path("lldb-dap"),
        dir: dir.clone(),
        file,
        config,
        env: vec![],
        lines: Lines {
            cond: 19,
            log: 20,
            hit: 21,
            callee: 10,
            exc: None,
        },
        filter: Some("cpp_throw"),
        structure: ("point", "x"),
        child: None,
    })
    .await;
    assert_eq!(
        r["run_in_terminal"],
        json!(true),
        "runInTerminal was not used"
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: lldb-dap and clang in the adapter image, with ptrace (see the module's doc)"]
async fn lldb_dap_attaches_to_a_pid_and_stop_leaves_it_running() {
    let dir = live_dir("ca");
    let file = write(
        &dir,
        "loop.c",
        "#include <unistd.h>\nint main(void) {\n  volatile int n = 0;\n  for (;;) {\n    n++;\n    usleep(50000);\n  }\n}\n",
    );
    run(&dir, "clang", &["-g", "-O0", "-o", "loop", "loop.c"]);
    let prog = std::process::Command::new(dir.join("loop"))
        .current_dir(&dir)
        .spawn()
        .unwrap();
    crate::clock::sleep(Duration::from_millis(300)).await;
    let config = json!({"type": "lldb-dap", "request": "attach", "name": "ca", "pid": prog.id(),
                        "program": dir.join("loop")});
    attach(
        "lldb-dap",
        on_path("lldb-dap"),
        &dir,
        prog,
        config,
        &file,
        5,
    )
    .await;
}

const JS: &str = "function add(a, b) {
  const s = a + b;
  return s;
}

function main() {
  const point = { x: 1, y: [1, 2] };
  let total = 0;
  let count = 0;
  for (let i = 0; i < 5; i++) {
    total = add(total, i);
    console.log('tick', i);
    count++;
  }
  try {
    throw new Error('boom');
  } catch (e) {}
  console.log('done', total, count, point.x);
  require('child_process').fork(require('path').join(__dirname, 'child.js'));
}

main();
";

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: js-debug in the adapter image (see the module's doc)"]
async fn js_debug_runs_the_scenario_with_a_forked_child() {
    let dir = live_dir("js");
    let file = write(&dir, "prog.js", JS);
    let child = write(&dir, "child.js", "let n = 0;\nn += 1;\nconsole.log(n);\n");
    let config =
        json!({"type": "pwa-node", "request": "launch", "name": "js", "program": file, "cwd": dir});
    scenario(Scn {
        id: "js-debug",
        found: js_debug(),
        dir: dir.clone(),
        file,
        config,
        env: vec![],
        lines: Lines {
            cond: 11,
            log: 12,
            hit: 13,
            callee: 2,
            exc: Some(16),
        },
        filter: Some("all"),
        structure: ("point", "x"),
        child: Some((child, 2)),
    })
    .await;
}

/// Probes (spec §19.2's per-adapter table): how long one costs, and its value's text. PROBES iterations of a loop, the
/// logpoint `probe={v}` on LINE (a small structure), run with it and then without; the cost of a hit is the
/// difference over the hits seen. Prints a `T10-PROBES` line.
async fn probes(
    id: &'static str,
    found: Found,
    dir: &Path,
    config: Value,
    env: &[(String, String)],
    file: &Path,
    line: u32,
) {
    let mut times = vec![];
    let mut hits = 0;
    let mut sample = String::new();
    for with in [true, false] {
        let ev = Arc::new(Events::default());
        let seen: Seen = Arc::default();
        let d = Debug::new(ev.clone(), Arc::new(Procs::default()));
        let root = dir.display().to_string();
        if with {
            add(&d, &root, file, line, None, None, Some("probe={v}")).await;
        }
        let start = Start {
            name: id.into(),
            adapter_id: config["type"].as_str().unwrap().into(),
            request: Request::Launch,
            arguments: super::launch::adapter_arguments(&config),
            breakpoints: vec![],
            functions: vec![],
            exception_filters: None,
        };
        let tap = Arc::new(Tap {
            inner: launcher(id, &found, dir, env),
            seen: seen.clone(),
        });
        let t0 = crate::clock::now();
        d.start(1, &root, start, tap).await.unwrap();
        ev.next(0, "debug-ended", |_| true).await;
        times.push(t0.elapsed());
        if with {
            let outs: Vec<String> = seen
                .lock()
                .unwrap()
                .iter()
                .filter(|(n, _)| n == "output")
                .filter_map(|(_, b)| b["output"].as_str().map(str::to_owned))
                .flat_map(|o| o.lines().map(str::to_owned).collect::<Vec<_>>())
                .filter(|o| o.contains("probe="))
                .collect();
            hits = outs.len();
            sample = outs.first().cloned().unwrap_or_default();
        }
        d.shutdown().await;
    }
    assert!(hits > 0, "{id}: no probe output");
    let per_hit_ms = (times[0].as_secs_f64() - times[1].as_secs_f64()) * 1000.0 / hits as f64;
    eprintln!(
        "T10-PROBES {}",
        json!({"adapter": id, "iterations": PROBES, "hits": hits, "with_ms": times[0].as_millis(),
               "without_ms": times[1].as_millis(), "per_hit_ms": (per_hit_ms * 1000.0).round() / 1000.0,
               "per_s": if per_hit_ms > 0.0 { (1000.0 / per_hit_ms).round() } else { 0.0 },
               "value_text": sample})
    );
}

const PROBES: u32 = 500;

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: debugpy in the adapter image (see the module's doc)"]
async fn debugpy_probe_cost() {
    let dir = live_dir("py-probe");
    let file = write(
        &dir,
        "probe.py",
        &format!(
            "def main():\n    total = 0\n    for i in range({PROBES}):\n        v = {{\"i\": i, \"s\": [i, 2]}}\n        total += i\n    print(total)\n\n\nmain()\n"
        ),
    );
    let config = json!({"type": "debugpy", "request": "launch", "name": "pyp", "program": file, "cwd": dir,
                        "justMyCode": true});
    probes("debugpy", python(), &dir, config, &[], &file, 5).await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: js-debug in the adapter image (see the module's doc)"]
async fn js_debug_probe_cost() {
    let dir = live_dir("js-probe");
    let file = write(
        &dir,
        "probe.js",
        &format!(
            "let total = 0;\nfor (let i = 0; i < {PROBES}; i++) {{\n  const v = {{ i: i, s: [i, 2] }};\n  total += i;\n}}\nconsole.log(total);\n"
        ),
    );
    let config = json!({"type": "pwa-node", "request": "launch", "name": "jsp", "program": file, "cwd": dir});
    probes("js-debug", js_debug(), &dir, config, &[], &file, 4).await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: delve in the adapter image, with ptrace (see the module's doc)"]
async fn delve_probe_cost() {
    let dir = live_dir("go-probe");
    let file = write(
        &dir,
        "main.go",
        &format!(
            "package main\n\nimport \"fmt\"\n\ntype V struct {{\n\tI int\n\tS []int\n}}\n\nfunc main() {{\n\ttotal := 0\n\tfor i := 0; i < {PROBES}; i++ {{\n\t\tv := V{{I: i, S: []int{{i, 2}}}}\n\t\ttotal += v.I\n\t}}\n\tfmt.Println(total)\n}}\n"
        ),
    );
    let d = dir.display();
    let env = vec![
        ("GOCACHE".to_owned(), format!("{d}/gocache")),
        ("GOPATH".to_owned(), format!("{d}/gopath")),
        ("GOTOOLCHAIN".to_owned(), "local".to_owned()),
        ("GOFLAGS".to_owned(), String::new()),
        ("GO111MODULE".to_owned(), "off".to_owned()),
    ];
    let config = json!({"type": "go", "request": "launch", "name": "gop", "mode": "debug", "program": file,
                        "cwd": dir, "output": dir.join("debug_bin")});
    probes("delve", on_path("delve"), &dir, config, &env, &file, 14).await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: lldb-dap and clang in the adapter image, with ptrace (see the module's doc)"]
async fn lldb_dap_probe_cost() {
    let dir = live_dir("c-probe");
    let file = write(
        &dir,
        "probe.c",
        &format!(
            "#include <stdio.h>\nstruct V {{ int i; int s[2]; }};\nint main(void) {{\n  int total = 0;\n  for (int i = 0; i < {PROBES}; i++) {{\n    struct V v = {{ i, {{ i, 2 }} }};\n    total += v.i;\n  }}\n  printf(\"%d\\n\", total);\n  return 0;\n}}\n"
        ),
    );
    run(&dir, "clang", &["-g", "-O0", "-o", "probe", "probe.c"]);
    let config = json!({"type": "lldb-dap", "request": "launch", "name": "cp", "program": dir.join("probe"),
                        "cwd": dir, "disableASLR": false});
    probes("lldb-dap", on_path("lldb-dap"), &dir, config, &[], &file, 7).await;
}

fn codelldb() -> Found {
    Found::Program(
        std::env::var("DRGNX_DEBUG_LIVE_CODELLDB")
            .unwrap_or_else(|_| "/opt/codelldb/extension/adapter/codelldb".into())
            .into(),
    )
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: CodeLLDB and clang in the adapter image, with ptrace (see the module's doc)"]
async fn codelldb_runs_the_scenario() {
    let dir = live_dir("codelldb");
    let file = write(&dir, "prog.cpp", CPP);
    run(&dir, "clang++", &["-g", "-O0", "-o", "prog", "prog.cpp"]);
    let config = json!({"type": "lldb", "request": "launch", "name": "cpp", "program": dir.join("prog"),
                        "cwd": dir});
    scenario(Scn {
        id: "codelldb",
        found: codelldb(),
        dir: dir.clone(),
        file,
        config,
        env: vec![],
        lines: Lines {
            cond: 19,
            log: 20,
            hit: 21,
            callee: 10,
            exc: None,
        },
        filter: Some("cpp_throw"),
        structure: ("point", "x"),
        child: None,
    })
    .await;
}

/// Break on Value Change with a native adapter: stopped in the loop, a data breakpoint on `count`; the next stop is
/// its change (0 → 1), with the adapter's reason reported.
async fn breaks_on_value_change(id: &'static str, found: Found, ty: &str) {
    let dir = live_dir(&format!("{id}-data"));
    let file = write(&dir, "prog.cpp", CPP);
    run(&dir, "clang++", &["-g", "-O0", "-o", "prog", "prog.cpp"]);
    let config = json!({"type": ty, "request": "launch", "name": "data", "program": dir.join("prog"),
                        "cwd": dir, "disableASLR": false});
    let ev = Arc::new(Events::default());
    let seen: Seen = Arc::default();
    let d = Debug::new(ev.clone(), Arc::new(Procs::default()));
    let root = dir.display().to_string();
    let bp = add(&d, &root, &file, 20, None, None, None).await;
    let start = Start {
        name: id.into(),
        adapter_id: ty.into(),
        request: Request::Launch,
        arguments: super::launch::adapter_arguments(&config),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    let tap = Arc::new(Tap {
        inner: launcher(id, &found, &dir, &[]),
        seen,
    });
    d.start(1, &root, start, tap).await.unwrap();
    let (c, f) = ev.stop(0).await;
    assert_eq!(line_of(&f), 20, "{f}");
    let sid = f["session"].as_str().unwrap().to_owned();
    let stop = d.stop_of(&sid).unwrap();
    let (count, _, scope) = local(&stop, "count");
    assert_eq!(int_of(&count), 0);
    let list = d
        .add_data_breakpoint(&sid, scope, "count", None)
        .await
        .unwrap();
    assert_eq!(list.len(), 1, "{list:?}");
    assert_eq!(list[0]["verified"], json!(true), "{list:?}");
    remove(&d, &root, bp).await;
    d.control(&sid, Op::Continue { thread: None })
        .await
        .unwrap();
    let (_, f) = ev.stop(c).await;
    let stop = d.stop_of(&sid).unwrap();
    let (count, _, _) = local(&stop, "count");
    assert_eq!(int_of(&count), 1, "the stop after the change: {f}");
    println!(
        "T10-REPORT {}",
        json!({"adapter": id, "data_breakpoint": {"reason": stop.reason, "line": line_of(&f),
                                                  "description": list[0]["description"]}})
    );
    d.control(
        &sid,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    ev.next(0, "debug-ended", |e| e["session"] == json!(sid))
        .await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: CodeLLDB and clang in the adapter image, with ptrace (see the module's doc)"]
async fn codelldb_breaks_on_value_change() {
    breaks_on_value_change("codelldb", codelldb(), "lldb").await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: lldb-dap and clang in the adapter image, with ptrace (see the module's doc)"]
async fn lldb_dap_breaks_on_value_change() {
    breaks_on_value_change("lldb-dap", on_path("lldb-dap"), "lldb-dap").await;
}

/// Hot reload (D8): stopped in the loop, `lib.val` is saved returning 2 and reloaded; the next call returns it.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: debugpy in the adapter image (see the module's doc)"]
async fn debugpy_hot_reloads_a_saved_function() {
    let dir = live_dir("py-reload");
    let lib = write(&dir, "lib.py", "def val():\n    return 1\n");
    let file = write(
        &dir,
        "prog.py",
        "import lib\nx = 0\nfor i in range(3):\n    x = lib.val()\n    print(x)\n",
    );
    let config = json!({"type": "debugpy", "request": "launch", "name": "pyr", "program": file, "cwd": dir,
                        "justMyCode": true});
    let ev = Arc::new(Events::default());
    let d = Debug::new(ev.clone(), Arc::new(Procs::default()));
    let root = dir.display().to_string();
    let bp = add(&d, &root, &file, 4, None, None, None).await;
    let start = Start {
        name: "debugpy".into(),
        adapter_id: "debugpy".into(),
        request: Request::Launch,
        arguments: super::launch::adapter_arguments(&config),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    d.start(1, &root, start, launcher("debugpy", &python(), &dir, &[]))
        .await
        .unwrap();
    let (c, f) = ev.stop(0).await;
    assert_eq!(line_of(&f), 4, "{f}");
    let sid = f["session"].as_str().unwrap().to_owned();
    // the first call ran with the old code: stop on the loop's second turn
    d.control(&sid, Op::Continue { thread: None })
        .await
        .unwrap();
    let (c, _) = ev.stop(c).await;
    let x = local(&d.stop_of(&sid).unwrap(), "x").0;
    assert_eq!(int_of(&x), 1);
    std::fs::write(&lib, "def val():\n    return 2\n").unwrap();
    let out = super::hot_reload::hot_reload(&d, &sid, &lib.display().to_string())
        .await
        .unwrap();
    assert_eq!(out["patched"], json!(["val"]), "{out}");
    remove(&d, &root, bp).await;
    d.control(&sid, Op::Next { thread: None }).await.unwrap();
    let (_, f) = ev.stop(c).await;
    let x = local(&d.stop_of(&sid).unwrap(), "x").0;
    assert_eq!(int_of(&x), 2, "the call after the reload: {f}");
    println!("T-HOT-RELOAD-REPORT {out}");
    d.control(
        &sid,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    ev.next(0, "debug-ended", |e| e["session"] == json!(sid))
        .await;
}

/// The heap graph live (spec §19.7 D7): a ring of three nodes (a → b → c → a) and `shared` = b, stopped on LINE; the
/// walk from every scope's variables with the adapter's identity must give three objects, `shared` as b, and the
/// ring closed through the field NEXT. Prints a `HEAP-GRAPH` line.
#[allow(clippy::too_many_arguments)]
async fn heap_graph(
    id: &'static str,
    found: Found,
    dir: &Path,
    config: Value,
    env: &[(String, String)],
    file: &Path,
    line: u32,
    next: &str,
) {
    let ev = Arc::new(Events::default());
    let terms = Arc::new(Procs::default());
    let d = Debug::new(ev.clone(), terms.clone());
    let root = dir.display().to_string();
    add(&d, &root, file, line, None, None, None).await;
    let ty = config["type"].as_str().unwrap().to_owned();
    let start = Start {
        name: id.into(),
        adapter_id: ty.clone(),
        request: Request::Launch,
        arguments: super::launch::adapter_arguments(&config),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    d.start(1, &root, start, launcher(id, &found, dir, env))
        .await
        .unwrap();
    let (_, f) = ev.stop(0).await;
    let sid = f["session"].as_str().unwrap().to_owned();
    let stop = d.stop_of(&sid).unwrap();
    let probe = super::heap::SessionProbe {
        handle: d.session(&sid).unwrap(),
        epoch: stop.epoch,
        frame: stop.frame,
    };
    // every scope's variables (js-debug's locals are in "Local: main", after none)
    let roots: Vec<Value> = stop
        .scopes
        .iter()
        .filter_map(|s| s.variables.clone())
        .flatten()
        .filter(|v| ["a", "b", "c", "shared"].contains(&v["name"].as_str().unwrap_or_default()))
        .collect();
    let ident = super::heap::Ident::of(&ty);
    let t0 = crate::clock::now();
    let g = super::heap::walk(&probe, ident, roots, super::heap::Limits::default()).await;
    eprintln!(
        "HEAP-GRAPH {}",
        json!({"adapter": id, "ident": format!("{ident:?}"), "nodes": g.nodes.len(), "cut": g.cut,
               "ms": t0.elapsed().as_millis(), "roots": g.roots})
    );
    // `debug/heap`'s read: the root by expression, evaluated in the frame
    let from_a = super::heap::read(&d, &sid, None, "a", super::heap::Limits::default())
        .await
        .unwrap();
    d.shutdown().await;
    assert_eq!(from_a.nodes.len(), 3, "{id}: from a: {from_a:#?}");
    assert_eq!(
        from_a.roots[0].1,
        g.roots
            .iter()
            .find(|(r, _)| r == "a")
            .and_then(|(_, n)| n.clone()),
        "{id}: the root evaluated is a's object"
    );
    let root_of = |n: &str| {
        g.roots
            .iter()
            .find(|(r, _)| r == n)
            .and_then(|(_, i)| i.clone())
            .unwrap_or_else(|| panic!("{id}: no node for {n}: {g:#?}"))
    };
    let (a, b, c) = (root_of("a"), root_of("b"), root_of("c"));
    assert!(a != b && b != c && a != c, "{id}: three objects: {g:#?}");
    assert_eq!(root_of("shared"), b, "{id}: shared is b");
    assert_eq!(g.nodes.len(), 3, "{id}: {g:#?}");
    let to = |n: &str| {
        g.nodes
            .iter()
            .find(|x| x.id == n)
            .and_then(|x| x.fields.iter().find(|f| f.name == next))
            .and_then(|f| f.to.clone())
    };
    assert_eq!(to(&a).as_ref(), Some(&b), "{id}: a.next is b");
    assert_eq!(to(&c).as_ref(), Some(&a), "{id}: the ring closes");
}

const HEAP_PY: &str = "class Node:\n    def __init__(self, v):\n        self.v = v\n        self.next = None\n\n\ndef main():\n    a, b, c = Node(1), Node(2), Node(3)\n    a.next, b.next, c.next = b, c, a\n    shared = b\n    print(a.v, shared.v)\n\n\nmain()\n";

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: debugpy in the adapter image"]
async fn heap_graph_debugpy() {
    let dir = live_dir("heap-py");
    let file = write(&dir, "heap.py", HEAP_PY);
    let config = json!({"type": "debugpy", "request": "launch", "name": "hp", "program": file, "cwd": dir,
                        "justMyCode": true});
    heap_graph("debugpy", python(), &dir, config, &[], &file, 11, "next").await;
}

const HEAP_JS: &str = "class Node {\n  constructor(v) { this.v = v; this.next = null; }\n}\nfunction main() {\n  const a = new Node(1), b = new Node(2), c = new Node(3);\n  a.next = b; b.next = c; c.next = a;\n  const shared = b;\n  console.log(a.v, shared.v);\n}\nmain();\n";

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: js-debug in the adapter image"]
async fn heap_graph_js_debug() {
    let dir = live_dir("heap-js");
    let file = write(&dir, "heap.js", HEAP_JS);
    let config =
        json!({"type": "pwa-node", "request": "launch", "name": "hj", "program": file, "cwd": dir});
    heap_graph("js-debug", js_debug(), &dir, config, &[], &file, 8, "next").await;
}

const HEAP_GO: &str = "package main\n\nimport \"fmt\"\n\ntype Node struct {\n\tV    int\n\tNext *Node\n}\n\nfunc main() {\n\ta, b, c := &Node{V: 1}, &Node{V: 2}, &Node{V: 3}\n\ta.Next, b.Next, c.Next = b, c, a\n\tshared := b\n\tfmt.Println(a.V, shared.V)\n}\n";

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: delve in the adapter image, with ptrace"]
async fn heap_graph_delve() {
    let dir = live_dir("heap-go");
    let file = write(&dir, "main.go", HEAP_GO);
    let d = dir.display();
    let env = vec![
        ("GOCACHE".to_owned(), format!("{d}/gocache")),
        ("GOPATH".to_owned(), format!("{d}/gopath")),
        ("GOTOOLCHAIN".to_owned(), "local".to_owned()),
        ("GOFLAGS".to_owned(), String::new()),
        ("GO111MODULE".to_owned(), "off".to_owned()),
    ];
    let config = json!({"type": "go", "request": "launch", "name": "hg", "mode": "debug", "program": file,
                        "cwd": dir, "output": dir.join("debug_bin")});
    heap_graph(
        "delve",
        on_path("delve"),
        &dir,
        config,
        &env,
        &file,
        14,
        "Next",
    )
    .await;
}

const HEAP_CPP: &str = "#include <cstdio>\n\nstruct Node {\n  int v;\n  Node *next;\n};\n\nint main() {\n  Node *a = new Node{1, nullptr}, *b = new Node{2, nullptr}, *c = new Node{3, nullptr};\n  a->next = b; b->next = c; c->next = a;\n  Node *shared = b;\n  std::printf(\"%d %d\\n\", a->v, shared->v);\n  return 0;\n}\n";

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: lldb-dap and clang in the adapter image, with ptrace"]
async fn heap_graph_lldb_dap() {
    let dir = live_dir("heap-lldb");
    let file = write(&dir, "heap.cpp", HEAP_CPP);
    run(&dir, "clang++", &["-g", "-O0", "-o", "heap", "heap.cpp"]);
    let config = json!({"type": "lldb-dap", "request": "launch", "name": "hl", "program": dir.join("heap"),
                        "cwd": dir, "disableASLR": false});
    heap_graph(
        "lldb-dap",
        on_path("lldb-dap"),
        &dir,
        config,
        &[],
        &file,
        12,
        "next",
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: CodeLLDB and clang in the adapter image, with ptrace"]
async fn heap_graph_codelldb() {
    let dir = live_dir("heap-codelldb");
    let file = write(&dir, "heap.cpp", HEAP_CPP);
    run(&dir, "clang++", &["-g", "-O0", "-o", "heap", "heap.cpp"]);
    let config = json!({"type": "lldb", "request": "launch", "name": "hc", "program": dir.join("heap"),
                        "cwd": dir});
    heap_graph("codelldb", codelldb(), &dir, config, &[], &file, 12, "next").await;
}

/// The heap graph's hidden map in JavaScript (the user's ruling, 2026-11-13): there while attached, gone after a
/// detach that leaves the program running, as the program itself sees it (`Object.getOwnPropertySymbols`).
#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: js-debug and node in the adapter image"]
async fn js_debug_detach_leaves_no_hidden_map() {
    let dir = live_dir("heap-js-detach");
    let out = dir.join("symbols.txt");
    let file = write(
        &dir,
        "tick.js",
        "const fs = require('fs');\nconst out = process.argv[2];\nclass Node { constructor(v) { this.v = v; this.next = null; } }\nlet n = 0;\nfunction tick() {\n  const a = new Node(1), b = new Node(2);\n  a.next = b; b.next = a;\n  n += 1;\n  fs.writeFileSync(out, n + ' ' + Object.getOwnPropertySymbols(globalThis).map(String).join(','));\n}\nsetInterval(tick, 50);\n",
    );
    let port = adapters::free_port().unwrap();
    let mut prog = std::process::Command::new("node")
        .arg(format!("--inspect=127.0.0.1:{port}"))
        .arg(&file)
        .arg(&out)
        .current_dir(&dir)
        .spawn()
        .unwrap();
    crate::clock::sleep(Duration::from_millis(800)).await;
    let ev = Arc::new(Events::default());
    let d = Debug::new(ev.clone(), Arc::new(Procs::default()));
    let root = dir.display().to_string();
    let bp = add(&d, &root, &file, 8, None, None, None).await;
    let config = json!({"type": "pwa-node", "request": "attach", "name": "ja", "port": port,
                        "address": "127.0.0.1"});
    let start = Start {
        name: "js-debug".into(),
        adapter_id: "pwa-node".into(),
        request: Request::Attach,
        arguments: super::launch::adapter_arguments(&config),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    let sid = d
        .start(
            1,
            &root,
            start,
            launcher("js-debug", &js_debug(), &dir, &[]),
        )
        .await
        .unwrap();
    let (_, f) = ev.stop(0).await;
    let sid = f["session"].as_str().map_or(sid, str::to_owned);
    let g = super::heap::read(&d, &sid, None, "a", super::heap::Limits::default())
        .await
        .unwrap();
    assert_eq!(g.nodes.len(), 2, "{g:#?}");
    let stop = d.stop_of(&sid).unwrap();
    let seen = d
        .session(&sid)
        .unwrap()
        .request(
            "evaluate",
            json!({"expression": "Object.getOwnPropertySymbols(globalThis).map(String).join(',')",
                   "frameId": stop.frame, "context": "watch"}),
        )
        .await
        .unwrap();
    assert!(
        seen["result"]
            .as_str()
            .unwrap_or_default()
            .contains("drgnx.ids"),
        "the map is there while attached: {seen}"
    );
    let at_stop = std::fs::read_to_string(&out).unwrap_or_default();
    remove(&d, &root, bp).await;
    d.control(
        &sid,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    d.shutdown().await;
    crate::clock::sleep(Duration::from_millis(600)).await;
    let after = std::fs::read_to_string(&out).unwrap_or_default();
    let _ = prog.kill();
    let _ = prog.wait();
    let n = |s: &str| {
        s.split(' ')
            .next()
            .and_then(|n| n.parse::<u64>().ok())
            .unwrap_or(0)
    };
    assert!(
        n(&after) > n(&at_stop),
        "it ran on after the detach: {at_stop:?} then {after:?}"
    );
    assert!(
        !after.contains("drgnx.ids"),
        "the program still sees the map: {after:?}"
    );
}
