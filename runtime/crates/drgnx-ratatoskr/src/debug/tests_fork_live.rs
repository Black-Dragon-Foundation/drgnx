//! Live: what-if forks of Python and JS programs in Gleipnir's full tier, through the hub's [`Forks`] with the real
//! trees and seal. Run alone, in the adapter image with bwrap (`test/container/Containerfile.debug`, `ctr.sh
//! --sandbox`), the hub built beside the tests (`cargo build --bin ratatoskr`):
//! `drgnx_ratatoskr-* --ignored --test-threads=1 debug::tests_fork_live`. `DRGNX_DEBUG_LIVE_PYTHON` (default
//! `python3`, with debugpy) and `DRGNX_DEBUG_LIVE_JS_DEBUG` (default `/opt/js-debug/src/dapDebugServer.js`) say where
//! the adapters are; the tests give them a tools folder of their own, as Debug: Install Adapter would.
//!
//! A recorded run is stood in for: its stops and probe hits are what the fixture prints (it is deterministic but for
//! the clock row), and its launch snapshot is taken of the fixture; one row records a real run (D1) and forks it.
//! Also: a trace (D3) with an injected environment value and file, and plain runs in a bisect slot (D5).
use super::fork::{At, Change, RunEnd, Until, Watch};
use super::fork_hub::{Ask, Forks, Made};
use super::fork_seal::{DirTrees, Sealed};
use super::record::{RunHit, RunInfo, RunProbe, RunSnapshot, RunStop, Runs, config_hash};
use super::{BoxFut, Connected, Launcher, Opened, Sink, Terminals};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

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
    fn last(&self, fork: &str) -> Option<Value> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .rev()
            .find(|(e, d)| e == "debug-fork" && d["fork"] == json!(fork))
            .map(|(_, d)| d.clone())
    }
}

struct OneRun(RunInfo);

impl Runs for OneRun {
    fn run(&self, id: &str) -> Option<RunInfo> {
        (id == self.0.id).then(|| self.0.clone())
    }
}

/// The hub built beside the tests is the sandbox's helper (as `exec::tests` does).
fn pin_hub() {
    let exe = std::env::current_exe().unwrap();
    let hub = exe.parent().unwrap().parent().unwrap().join("ratatoskr");
    assert!(hub.is_file(), "{} is not built", hub.display());
    crate::idle::pin_exe_for_test(std::fs::canonicalize(&hub).unwrap());
}

/// A tools folder as Debug: Install Adapter makes it: `venv/` with debugpy, `js-debug/`.
fn tools(at: &Path) -> PathBuf {
    let python = std::env::var("DRGNX_DEBUG_LIVE_PYTHON").unwrap_or_else(|_| "python3".into());
    let out = std::process::Command::new(&python)
        .args(["-c", "import debugpy, os, sys; print(os.path.dirname(debugpy.__file__)); print(sys.executable)"])
        .output()
        .unwrap();
    let text = String::from_utf8(out.stdout).unwrap();
    let mut lines = text.lines();
    let (pkg, exe) = (lines.next().unwrap(), lines.next().unwrap());
    let t = at.join("tools");
    std::fs::create_dir_all(t.join("venv/bin")).unwrap();
    std::fs::create_dir_all(t.join("venv/lib/python3/site-packages")).unwrap();
    std::os::unix::fs::symlink(exe, t.join("venv/bin/python3")).unwrap();
    std::os::unix::fs::symlink(pkg, t.join("venv/lib/python3/site-packages/debugpy")).unwrap();
    let js = std::env::var("DRGNX_DEBUG_LIVE_JS_DEBUG")
        .unwrap_or_else(|_| "/opt/js-debug/src/dapDebugServer.js".into());
    let release = Path::new(&js).parent().unwrap().parent().unwrap();
    std::os::unix::fs::symlink(release, t.join("js-debug")).unwrap();
    t
}

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    forks: Forks,
    events: Arc<Events>,
    resolved: Value,
}

const N: u32 = 40;
const POINT: u32 = 21;
/// The point's stop in the fixture's run (after every hit before it, before every hit after).
const AT: u64 = 100_000;

/// A project of FILE with TEXT (and a `.env`), a run of CONFIG recorded as if: the probe `shortfall` on PROBE_LINE
/// printing VALUE(i) for i in 0..N, a breakpoint stop at the POINT-th pass of POINT_LINE, one at END_LINE.
fn fixture(
    file: &str,
    text: &str,
    config: impl Fn(&Path) -> Value,
    lines: (u32, u32, u32),
    value: impl Fn(u32) -> String,
) -> Fixture {
    fixture_at(file, text, config, lines, value, (N, POINT))
}

/// [`fixture`] with N passes of the probe and the point's stop at pass POINT of its line.
fn fixture_at(
    file: &str,
    text: &str,
    config: impl Fn(&Path) -> Value,
    lines: (u32, u32, u32),
    value: impl Fn(u32) -> String,
    (n, point): (u32, u32),
) -> Fixture {
    pin_hub();
    let d = tempfile::tempdir_in("/tmp").unwrap();
    let home = d.path().join("home");
    let root = d.path().join("proj");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(
        root.join(file),
        text.replace("@ROOT@", &root.display().to_string()),
    )
    .unwrap();
    std::fs::write(root.join(".env"), "API_TOKEN=s3cr3t-value\n").unwrap();
    let checkpoints = d.path().join("checkpoints");
    let tree = crate::timeline::snapshot::tree_now(&checkpoints, &root, &root, &[]).unwrap();
    let resolved = config(&root);
    let path = root.join(file).display().to_string();
    let (probe_line, point_line, end_line) = lines;
    let hits = (0..n)
        .map(|i| RunHit {
            probe: "shortfall".into(),
            thread: "1".into(),
            value: value(i),
            // the passes before the point's stop come before it
            seq: if i + 1 < point {
                u64::from(i) + 1
            } else {
                AT + 1 + u64::from(i)
            },
            t_ms: 0,
        })
        .collect();
    let stop = |index, line, hit| RunStop {
        index,
        t_ms: 100,
        reason: "breakpoint".into(),
        thread: 1,
        path: path.clone(),
        line,
        bp_hit: Some(hit),
        steps: vec![],
        session: "d1".into(),
    };
    let run = RunInfo {
        id: "r1".into(),
        root: root.display().to_string(),
        start: json!({}),
        config_hash: Some(config_hash(&resolved)),
        adapter_id: resolved["type"].as_str().unwrap().into(),
        request: "launch".into(),
        snapshot: Some(RunSnapshot {
            checkpoints,
            source: root.clone(),
            tree,
        }),
        hash_seed: Some(0),
        to_stop_ms: Some(100),
        stops: vec![stop(AT, point_line, point), stop(5 * AT, end_line, 1)],
        probes: vec![RunProbe {
            id: "shortfall".into(),
            path: path.clone(),
            line: probe_line,
            expr: "shortfall".into(),
        }],
        hits,
    };
    let path_env = std::env::var("PATH").unwrap();
    let env = runstav::paths::Env::new(
        &[
            ("HOME", home.to_str().unwrap()),
            ("PATH", &path_env),
            ("XDG_RUNTIME_DIR", d.path().join("run").to_str().unwrap()),
        ],
        unsafe { libc::getuid() },
    );
    let events = Arc::new(Events::default());
    let forks = Forks::new(
        events.clone(),
        Arc::new(OneRun(run)),
        Arc::new(DirTrees::new(d.path().join("runs/debug-forks"))),
        Arc::new(Sealed {
            env,
            path: std::env::split_paths(&path_env).collect(),
            tools: tools(d.path()),
        }),
        true,
    );
    Fixture {
        _dir: d,
        root,
        forks,
        events,
        resolved,
    }
}

impl Fixture {
    fn ask(&self, until: Until, resolved: Value) -> Ask {
        Ask {
            run: "r1".into(),
            at: At::Stop(AT),
            change: Change::Nothing,
            until,
            confirm: false,
            resolved,
        }
    }

    /// Fork ASK, wait for it to finish: its last view.
    async fn fork(&self, ask: Ask) -> Value {
        let Made::Fork(id) = self.forks.fork(ask).unwrap() else {
            panic!("asked");
        };
        for _ in 0..1200 {
            if let Some(v) = self.events.last(&id)
                && matches!(v["state"].as_str(), Some("done" | "failed"))
            {
                return v;
            }
            crate::clock::sleep(Duration::from_millis(100)).await;
        }
        panic!("fork {id} did not finish: {:?}", self.events.last(&id));
    }
}

const PY: &str = r#"import os, socket, time
CLOCK = os.environ.get("FIXTURE_CLOCK") == "1"
def step(i):
    shortfall = time.monotonic_ns() % 1000 if CLOCK else (i * 7) % 13
    return shortfall
total = 0
for i in range(40):
    total += step(i)
try:
    socket.create_connection(("1.1.1.1", 80), timeout=3)
    net = "out"
except OSError:
    net = "blocked"
try:
    with open("@ROOT@/escaped.txt", "w") as f:
        f.write("x")
    wrote = "outside"
except OSError:
    wrote = "refused"
try:
    has_env = "API_TOKEN=" in open(".env").read()
except OSError:
    has_env = False
done = 1
"#;

fn py_config(root: &Path) -> Value {
    json!({"type": "debugpy", "request": "launch", "name": "Stock", "program": root.join("stock.py"),
           "cwd": root, "console": "internalConsole", "justMyCode": true})
}

fn local<'a>(view: &'a Value, name: &str) -> &'a str {
    view["now"]["locals"]
        .as_array()
        .and_then(|l| l.iter().find(|v| v["name"] == json!(name)))
        .and_then(|v| v["value"].as_str())
        .unwrap_or_else(|| panic!("no local {name} in {view}"))
}

#[tokio::test]
#[ignore = "live: the adapter image with bwrap"]
async fn a_python_fork_replays_its_run_sealed() {
    let f = fixture("stock.py", PY, py_config, (5, 8, 24), |i| {
        ((i * 7) % 13).to_string()
    });
    let v = f.fork(f.ask(Until::NextStop, f.resolved.clone())).await;
    assert_eq!(v["state"], json!("done"), "{v}");
    assert_eq!(
        v["matched"],
        json!({"matched": 20, "of": 20, "first": null}),
        "{v}"
    );
    assert_eq!(v["now"]["line"], json!(24), "{v}");
    // nothing gets out, nothing is written outside the tree, the .env is read in place and never copied or shown
    assert_eq!(local(&v, "net"), "'blocked'");
    assert_eq!(local(&v, "wrote"), "'refused'");
    assert_eq!(local(&v, "has_env"), "True");
    assert!(!f.root.join("escaped.txt").exists());
    let tree = PathBuf::from(v["tree"].as_str().unwrap());
    assert_eq!(std::fs::read(tree.join(".env")).unwrap(), b"");
    assert!(
        !f.events
            .0
            .lock()
            .unwrap()
            .iter()
            .any(|(_, d)| d.to_string().contains("s3cr3t")),
        "an environment value is in an event"
    );
    // after the point: the same values, then and now
    let lane = &v["lanes"][0];
    assert_eq!(lane["then"], lane["now"], "{v}");
}

#[tokio::test]
#[ignore = "live: the adapter image with bwrap"]
async fn a_clock_fixture_shows_its_first_difference() {
    let f = fixture("stock.py", PY, py_config, (5, 8, 24), |i| {
        ((i * 7) % 13).to_string()
    });
    let mut resolved = f.resolved.clone();
    resolved["env"] = json!({"FIXTURE_CLOCK": "1"});
    // the configuration resolves differently: refused, never a fork of another run
    assert!(f.forks.fork(f.ask(Until::Exit, resolved)).is_err());
    // the run's own configuration with the clock in the program: the hits differ
    let clock = PY.replace(r#"os.environ.get("FIXTURE_CLOCK") == "1""#, "True");
    let g = fixture("stock.py", &clock, py_config, (5, 8, 24), |i| {
        ((i * 7) % 13).to_string()
    });
    let v = g.fork(g.ask(Until::Exit, g.resolved.clone())).await;
    assert_eq!(v["state"], json!("done"), "{v}");
    assert_eq!(v["matched"]["of"], json!(20), "{v}");
    assert!(v["matched"]["first"].is_object(), "{v}");
    assert_eq!(v["now"]["kind"], json!("exit"), "{v}");
}

const JS: &str = r#"function step(i) {
  const shortfall = (i * 7) % 13;
  return shortfall;
}
let total = 0;
for (let i = 0; i < 40; i++) {
  total += step(i);
}
const done = 1;
"#;

fn js_config(root: &Path) -> Value {
    json!({"type": "pwa-node", "request": "launch", "name": "Stock", "program": root.join("stock.js"),
           "cwd": root, "console": "internalConsole"})
}

#[tokio::test]
#[ignore = "live: the adapter image with bwrap"]
async fn a_js_fork_replays_its_run_sealed() {
    let f = fixture("stock.js", JS, js_config, (3, 7, 9), |i| {
        ((i * 7) % 13).to_string()
    });
    let v = f.fork(f.ask(Until::NextStop, f.resolved.clone())).await;
    assert_eq!(v["state"], json!("done"), "{v}");
    assert_eq!(
        v["matched"],
        json!({"matched": 20, "of": 20, "first": null}),
        "{v}"
    );
    assert_eq!(v["now"]["line"], json!(9), "{v}");
}

/// The trace row's program: given `TRACE_AT` (the tree's path), it writes what it saw into the tree first.
const PY_SEES: &str = "O = __import__('os').environ.get('TRACE_AT'); O and open(O + '/seen.txt', 'w').write(O + '|' + open(O + '/in/given.txt').read())\n";

#[tokio::test]
#[ignore = "live: the adapter image with bwrap"]
async fn a_python_trace_sees_its_injected_env_and_file() {
    // one line first: the run's lines move down by one
    let text = format!("{PY_SEES}{PY}");
    let f = fixture("stock.py", &text, py_config, (6, 9, 25), |i| {
        ((i * 7) % 13).to_string()
    });
    let g = f
        .forks
        .trace(
            "r1",
            AT,
            f.resolved.clone(),
            |tree: &Path| vec![("TRACE_AT".into(), tree.display().to_string())],
            vec![("in/given.txt".into(), b"origin-17".to_vec())],
        )
        .await
        .unwrap();
    let seen = std::fs::read_to_string(g.path.join("seen.txt")).unwrap();
    assert_eq!(seen, format!("{}|origin-17", g.path.display()));
    // no fork entry; the tree goes with the guard
    assert!(f.forks.list().is_empty());
    let tree = g.path.clone();
    drop(g);
    for _ in 0..100 {
        if !tree.exists() {
            break;
        }
        crate::clock::sleep(Duration::from_millis(50)).await;
    }
    assert!(!tree.exists(), "{} is still there", tree.display());
}

/// D3's replay through these forks: the trace's tree gets the tracer, its records are read back as the project's.
struct Traces {
    forks: Forks,
    resolved: Value,
    root: PathBuf,
}

impl super::origin::Replay for Traces {
    fn trace(
        &self,
        run: &str,
        stop: u64,
        watch: Vec<String>,
    ) -> BoxFut<'static, Result<super::origin::Traced, String>> {
        let (forks, resolved, root, run) = (
            self.forks.clone(),
            self.resolved.clone(),
            self.root.clone(),
            run.to_owned(),
        );
        Box::pin(async move {
            let t = forks
                .trace(
                    &run,
                    stop,
                    resolved,
                    move |tree: &Path| super::origin::trace_env(tree, &watch),
                    super::origin::trace_files(),
                )
                .await?;
            super::origin::read_trace(&t.path, &root)
        })
    }
}

#[tokio::test]
#[ignore = "live: the adapter image with bwrap"]
async fn a_python_trail_is_traced_in_sealed_replays() {
    // the origin fixture, stopped at its first pass of `return shortfall` (line 16)
    let text = include_str!("../../tests/fixtures/origin/stock.py");
    let f = fixture_at(
        "stock.py",
        text,
        py_config,
        (15, 16, 23),
        |_| "16".into(),
        1,
    );
    let r = Traces {
        forks: f.forks.clone(),
        resolved: f.resolved.clone(),
        root: f.root.clone(),
    };
    let t = super::origin::trail(&r, "r1", 100, "shortfall", 3, Vec::new, |_| {})
        .await
        .unwrap();
    let got: Vec<(u32, &str, Option<&str>, u32)> = t
        .links
        .iter()
        .map(|l| (l.level, l.target.as_str(), l.value.as_deref(), l.line))
        .collect();
    assert_eq!(
        got,
        vec![
            (1, "shortfall", Some("16"), 15),
            (2, "self.min", Some("10"), 4),
            (2, "self.qty", Some("2"), 3),
            (2, "item.reserve", Some("8"), 10),
        ],
        "{:#?}",
        t.links
    );
    // the links name the project's file, not the trace's tree, and are traced
    let file = f.root.join("stock.py").display().to_string();
    assert!(
        t.links.iter().all(|l| l.path == file && l.traced),
        "{:#?}",
        t.links
    );
    assert!(t.note.is_none());
}

#[tokio::test]
#[ignore = "live: the adapter image with bwrap"]
async fn python_runs_in_bisect_slots_report_a_probe_and_an_exception() {
    let f = fixture("stock.py", PY, py_config, (5, 8, 24), |i| {
        ((i * 7) % 13).to_string()
    });
    let slots = f._dir.path().join("runs/debug-forks/slots/b1");
    // slot 1: the project as it is; the probe's values, the program's exit
    let one = slots.join("s1");
    std::fs::create_dir_all(&one).unwrap();
    std::fs::copy(f.root.join("stock.py"), one.join("stock.py")).unwrap();
    let end = f
        .forks
        .run_in(
            "r1",
            f.resolved.clone(),
            one,
            Watch::Probe {
                path: "stock.py".into(),
                line: 5,
                expr: "shortfall".into(),
            },
            Duration::from_secs(60),
        )
        .await
        .unwrap();
    let want: Vec<String> = (0..N).map(|i| ((i * 7) % 13).to_string()).collect();
    assert_eq!(end.probe_values, want, "{end:?}");
    assert_eq!(end.exit, Some(0), "{end:?}");
    assert!(!end.timed_out && end.exception_at.is_none(), "{end:?}");
    // slot 2: a version that raises (one caught on line 2 first): the watched raise is found
    let two = slots.join("s2");
    std::fs::create_dir_all(&two).unwrap();
    std::fs::write(
        two.join("stock.py"),
        "def f():\n    raise ValueError('x')\ntry:\n    f()\nexcept ValueError:\n    pass\nraise KeyError('y')\n",
    )
    .unwrap();
    let end = f
        .forks
        .run_in(
            "r1",
            f.resolved.clone(),
            two,
            Watch::Exception {
                path: "stock.py".into(),
                line: 7,
            },
            Duration::from_secs(60),
        )
        .await
        .unwrap();
    assert_eq!(end.exception_at, Some(("stock.py".into(), 7)), "{end:?}");
    // slot 3: a program that never ends: the time box
    let three = slots.join("s3");
    std::fs::create_dir_all(&three).unwrap();
    std::fs::write(
        three.join("stock.py"),
        "import time\nwhile True:\n    time.sleep(0.1)\n",
    )
    .unwrap();
    let end = f
        .forks
        .run_in(
            "r1",
            f.resolved.clone(),
            three,
            Watch::Probe {
                path: "stock.py".into(),
                line: 3,
                expr: "1".into(),
            },
            Duration::from_secs(3),
        )
        .await
        .unwrap();
    assert!(end.timed_out, "{end:?}");
    assert!(!end.probe_values.is_empty(), "{end:?}");
    assert_ne!(end, RunEnd::default());
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

/// debugpy's adapter on stdio, unsealed: how the user's own run is debugged.
struct Debugpy;

impl Launcher for Debugpy {
    fn connect(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move {
            let python =
                std::env::var("DRGNX_DEBUG_LIVE_PYTHON").unwrap_or_else(|_| "python3".into());
            let mut child = draugr::spawn(draugr::Spec {
                program: PathBuf::from(python),
                args: vec!["-m".into(), "debugpy.adapter".into()],
                env: std::env::vars_os().collect(),
                cwd: None,
                stdin_null: false,
                pass_fds: vec![],
                new_session: false,
            })
            .await
            .map_err(|e| e.to_string())?;
            let (Some(stdin), Some(stdout)) = (child.take_stdin(), child.take_stdout()) else {
                return Err("no stdio".into());
            };
            let (client, incoming) = vor::Client::new(stdout, stdin);
            Ok(Connected {
                client,
                incoming,
                proc: Box::new(child),
            })
        })
    }
}

#[tokio::test]
#[ignore = "live: the adapter image with bwrap"]
async fn a_recorded_python_run_is_forked_end_to_end() {
    pin_hub();
    let d = tempfile::tempdir_in("/tmp").unwrap();
    let home = d.path().join("home");
    let root = d.path().join("proj");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&root).unwrap();
    let text = PY.replace("@ROOT@", &root.display().to_string());
    let file = root.join("stock.py");
    std::fs::write(&file, &text).unwrap();
    let path = file.display().to_string();
    let root_s = root.display().to_string();
    let resolved = py_config(&root);

    // the user's run, recorded: a probe on `shortfall`, a breakpoint at the end
    let ev = Arc::new(Events::default());
    let dbg = super::Debug::new(ev.clone(), Arc::new(NoTerms));
    let rec = dbg.record_into(super::record::Opts::new(
        d.path().join("runs"),
        d.path().join("checkpoints"),
    ));
    rec.probes(&root_s, |p| {
        p.apply(super::probes::Op::Result {
            path: path.clone(),
            line: 4,
            expr: "shortfall".into(),
            text: text.clone(),
            lang: super::probes::Lang::Python,
        })
        .unwrap()
    });
    // the project's breakpoint store: sessions start from it
    dbg.breakpoints(
        &root_s,
        Some(super::breakpoints::Op::Add {
            path: path.clone(),
            line: 24,
            enabled: true,
            condition: None,
            hit: None,
            log: None,
        }),
        None,
    )
    .await;
    let start = super::session::Start {
        name: "Stock".into(),
        adapter_id: "debugpy".into(),
        request: super::session::Request::Launch,
        arguments: resolved.clone(),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    let launch = super::record::Launch {
        config_hash: Some(config_hash(&resolved)),
        start: json!({"root": root_s, "config": "launch:0"}),
        ..Default::default()
    };
    let id = dbg
        .start_with(1, &root_s, start, Arc::new(Debugpy), launch)
        .await
        .unwrap();
    let mut stop = None;
    for _ in 0..600 {
        stop = dbg.stop_of(&id);
        if stop.is_some() {
            break;
        }
        crate::clock::sleep(Duration::from_millis(100)).await;
    }
    let stop = stop.unwrap_or_else(|| {
        let seen: Vec<String> =
            ev.0.lock()
                .unwrap()
                .iter()
                .map(|(e, d)| {
                    format!(
                        "{e} {}",
                        d.to_string().chars().take(400).collect::<String>()
                    )
                })
                .collect();
        panic!(
            "the run never stopped at the end; events:\n{}",
            seen.join("\n")
        )
    });
    dbg.control(
        &id,
        super::Op::Continue {
            thread: Some(stop.thread),
        },
    )
    .await
    .unwrap();
    let ended = || {
        ev.0.lock()
            .unwrap()
            .iter()
            .any(|(e, d)| e == "debug-run" && d["state"] == json!("ended"))
    };
    for _ in 0..600 {
        if ended() {
            break;
        }
        crate::clock::sleep(Duration::from_millis(100)).await;
    }
    assert!(ended(), "the run did not end");
    let runs = rec.list(&root_s);
    assert_eq!(runs.len(), 1);
    let info = rec.run(&runs[0].id).unwrap();
    assert_eq!(info.hits.len(), N as usize);
    assert_eq!(info.stops.len(), 1);

    // forked from its stop, sealed, to the end: every hit before the point matched
    let path_env = std::env::var("PATH").unwrap();
    let env = runstav::paths::Env::new(
        &[
            ("HOME", home.to_str().unwrap()),
            ("PATH", &path_env),
            ("XDG_RUNTIME_DIR", d.path().join("run").to_str().unwrap()),
        ],
        unsafe { libc::getuid() },
    );
    let fev = Arc::new(Events::default());
    let forks = Forks::new(
        fev.clone(),
        rec.clone(),
        Arc::new(DirTrees::new(d.path().join("runs/debug-forks"))),
        Arc::new(Sealed {
            env,
            path: std::env::split_paths(&path_env).collect(),
            tools: tools(d.path()),
        }),
        true,
    );
    let Made::Fork(fork) = forks
        .fork(Ask {
            run: info.id.clone(),
            at: At::Stop(info.stops[0].index),
            change: Change::Nothing,
            until: Until::Exit,
            confirm: false,
            resolved,
        })
        .unwrap()
    else {
        panic!("asked");
    };
    let mut v = Value::Null;
    for _ in 0..1200 {
        if let Some(l) = fev.last(&fork)
            && matches!(l["state"].as_str(), Some("done" | "failed"))
        {
            v = l;
            break;
        }
        crate::clock::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(v["state"], json!("done"), "{v}");
    assert_eq!(
        v["matched"],
        json!({"matched": N, "of": N, "first": null}),
        "{v}"
    );
    assert_eq!(v["now"]["kind"], json!("exit"), "{v}");
}

/// `debug-fork-start` (spec §22, at most 2 s at the 95th percentile on Linux): a fork's tree restored, its sandbox and
/// adapter started and its program run to its first stop (the point is the first pass of its line), here a trace,
/// ten times. It measures and prints; the combined pass judges.
#[tokio::test]
#[ignore = "timing: live, the adapter image with bwrap"]
async fn debug_fork_start() {
    let f = fixture_at(
        "stock.py",
        PY,
        py_config,
        (5, 8, 24),
        |i| ((i * 7) % 13).to_string(),
        (N, 1),
    );
    let mut took = vec![];
    for _ in 0..10 {
        let t0 = crate::clock::now();
        let g = f
            .forks
            .trace("r1", AT, f.resolved.clone(), |_: &Path| vec![], vec![])
            .await
            .unwrap();
        took.push(t0.elapsed());
        drop(g);
    }
    took.sort();
    let p95 = took[(took.len() * 95).div_ceil(100) - 1];
    println!(
        "debug-fork-start: 10 forks to the point, p50 {:.0} ms, p95 {:.0} ms, max {:.0} ms (budget p95 2000)",
        took[took.len() / 2].as_secs_f64() * 1000.0,
        p95.as_secs_f64() * 1000.0,
        took[took.len() - 1].as_secs_f64() * 1000.0
    );
}

/// A replay to a late pass (spec §19.9's fork start, for a point deep in a loop): pass 200 of 300 within 6 s, where a
/// stop per pass would take about 50 s. The adapter counts the passes (`hitCondition`), and the fork's landing is
/// checked against the run's probe hits before it.
async fn a_late_pass(
    file: &str,
    text: &str,
    config: impl Fn(&Path) -> Value,
    lines: (u32, u32, u32),
) {
    let f = fixture_at(
        file,
        text,
        config,
        lines,
        |i| ((i * 7) % 13).to_string(),
        (300, 200),
    );
    let t0 = crate::clock::now();
    let v = f.fork(f.ask(Until::NextStop, f.resolved.clone())).await;
    let took = t0.elapsed();
    assert_eq!(v["state"], json!("done"), "{v}");
    assert_eq!(
        v["matched"],
        json!({"matched": 199, "of": 199, "first": null}),
        "{v}"
    );
    println!(
        "{file}: a fork to pass 200 in {} ms (budget 6000)",
        took.as_millis()
    );
    assert!(
        took < Duration::from_secs(6),
        "a fork to pass 200 took {took:?}"
    );
}

#[tokio::test]
#[ignore = "timing: live, the adapter image with bwrap"]
async fn a_python_fork_to_a_late_pass_is_quick() {
    let text = PY.replace("range(40)", "range(300)");
    a_late_pass("stock.py", &text, py_config, (5, 8, 24)).await;
}

#[tokio::test]
#[ignore = "timing: live, the adapter image with bwrap"]
async fn a_js_fork_to_a_late_pass_is_quick() {
    let text = JS.replace("i < 40", "i < 300");
    a_late_pass("stock.js", &text, js_config, (3, 7, 9)).await;
}
