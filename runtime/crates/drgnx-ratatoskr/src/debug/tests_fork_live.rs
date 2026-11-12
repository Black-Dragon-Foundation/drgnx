//! Live: what-if forks of Python and JS programs in Gleipnir's full tier, through the hub's [`Forks`] with the real
//! trees and seal. Run alone, in the adapter image with bwrap (`test/container/Containerfile.debug`, `ctr.sh
//! --sandbox`), the hub built beside the tests (`cargo build --bin ratatoskr`):
//! `drgnx_ratatoskr-* --ignored --test-threads=1 debug::tests_fork_live`. `DRGNX_DEBUG_LIVE_PYTHON` (default
//! `python3`, with debugpy) and `DRGNX_DEBUG_LIVE_JS_DEBUG` (default `/opt/js-debug/src/dapDebugServer.js`) say where
//! the adapters are; the tests give them a tools folder of their own, as Debug: Install Adapter would.
//!
//! A recorded run is stood in for: its stops and probe hits are what the fixture prints (it is deterministic but for
//! the clock row), and its launch snapshot is taken of the fixture.
use super::Sink;
use super::fork::{At, Change, Until};
use super::fork_hub::{Ask, Forks, Made};
use super::fork_run::{RunHit, RunInfo, RunProbe, RunSnapshot, RunStop, Runs, config_hash};
use super::fork_seal::{DirTrees, Sealed};
use super::session::Request;
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

/// A project of FILE with TEXT (and a `.env`), a run of CONFIG recorded as if: the probe `shortfall` on PROBE_LINE
/// printing VALUE(i) for i in 0..N, a breakpoint stop at the POINT-th pass of POINT_LINE, one at END_LINE.
fn fixture(
    file: &str,
    text: &str,
    config: impl Fn(&Path) -> Value,
    lines: (u32, u32, u32),
    value: impl Fn(u32) -> String,
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
    let hits = (0..N)
        .map(|i| RunHit {
            probe: "shortfall".into(),
            thread: "1".into(),
            value: value(i),
            // the point's stop is seq 100: the passes before it come before
            seq: if i + 1 < POINT {
                u64::from(i) + 1
            } else {
                101 + u64::from(i)
            },
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
    };
    let run = RunInfo {
        id: "r1".into(),
        root: root.clone(),
        start: json!({}),
        config_hash: config_hash(&resolved),
        adapter_id: resolved["type"].as_str().unwrap().into(),
        request: Request::Launch,
        snapshot: Some(RunSnapshot {
            checkpoints,
            source: root.clone(),
            tree,
        }),
        hash_seed: Some(0),
        to_stop_ms: Some(100),
        stops: vec![stop(100, point_line, POINT), stop(500, end_line, 1)],
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
            at: At::Stop(100),
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

#[tokio::test]
#[ignore = "live: the adapter image with bwrap"]
async fn a_js_fork_replays_its_run_sealed() {
    let f = fixture(
        "stock.js",
        JS,
        |root| {
            json!({"type": "pwa-node", "request": "launch", "name": "Stock", "program": root.join("stock.js"),
                   "cwd": root, "console": "internalConsole"})
        },
        (3, 7, 9),
        |i| ((i * 7) % 13).to_string(),
    );
    let v = f.fork(f.ask(Until::NextStop, f.resolved.clone())).await;
    assert_eq!(v["state"], json!("done"), "{v}");
    assert_eq!(
        v["matched"],
        json!({"matched": 20, "of": 20, "first": null}),
        "{v}"
    );
    assert_eq!(v["now"]["line"], json!(9), "{v}");
}
