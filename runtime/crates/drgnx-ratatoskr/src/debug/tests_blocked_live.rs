//! Live: debugpy and js-debug inside a port block, through the hub's sessions (spec §21). Each program starts a
//! child at once (js-debug: before its bootloader reaches the parent, unless the preload makes the fork wait for it;
//! spike runs 10 and 11), the breakpoint is in the child, and while it is stopped every TCP listener of the container's
//! processes in the network namespace is one of the block's ports (a listener nobody here owns, as Docker's embedded
//! DNS is, is not the debuggee's). Run alone, in the adapter image (`test/container/Containerfile.debug`):
//! `nextest run -p drgnx-ratatoskr --lib --features test-hooks --run-ignored only debug::tests_blocked_live`.
//! `DRGNX_DEBUG_LIVE_PYTHON` (default `python3`, with debugpy) and `DRGNX_DEBUG_LIVE_JS_DEBUG` (default
//! `/opt/js-debug/src/dapDebugServer.js`) say where the adapters are.
use super::adapters::{Env, Found, Table};
use super::blocked::{self, Blocked};
use super::breakpoints::Op as BpOp;
use super::ports::Blocks;
use super::session::{Op, Start};
use super::{BoxFut, Debug, Opened, Sink, Terminals};
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

struct NoTerms;

impl Terminals for NoTerms {
    fn open(
        &self,
        _: u64,
        _: String,
        _: Vec<String>,
        _: Vec<(String, String)>,
    ) -> BoxFut<'_, Result<Opened, String>> {
        Box::pin(async { Err("no terminal in the live test".to_owned()) })
    }
}

/// The socket inodes held open by the processes this container can see (the test, the adapter and the debuggee's whole
/// tree): what `/proc/<pid>/fd` names as `socket:[INODE]`.
fn owned_sockets() -> std::collections::HashSet<u64> {
    let mut out = std::collections::HashSet::new();
    let Ok(procs) = std::fs::read_dir("/proc") else {
        return out;
    };
    for p in procs.flatten() {
        if !p
            .file_name()
            .to_string_lossy()
            .bytes()
            .all(|b| b.is_ascii_digit())
        {
            continue;
        }
        let Ok(fds) = std::fs::read_dir(p.path().join("fd")) else {
            continue;
        };
        for fd in fds.flatten() {
            if let Ok(link) = std::fs::read_link(fd.path())
                && let Some(inode) = link
                    .to_string_lossy()
                    .strip_prefix("socket:[")
                    .and_then(|i| i.strip_suffix(']'))
                    .and_then(|i| i.parse().ok())
            {
                out.insert(inode);
            }
        }
    }
    out
}

/// Every TCP port listening in this network namespace that a process of this container holds: a listener of the
/// namespace that none of them owns is somebody else's (Docker's embedded DNS answers on a high port in the netns of a
/// job container on a user network), and no debuggee of the block's.
fn listeners() -> Vec<u16> {
    let owned = owned_sockets();
    let mut out = vec![];
    for f in ["/proc/net/tcp", "/proc/net/tcp6"] {
        let Ok(t) = std::fs::read_to_string(f) else {
            continue;
        };
        for line in t.lines().skip(1) {
            let cols: Vec<&str> = line.split_whitespace().collect();
            // state 0A: LISTEN
            if cols.get(3) == Some(&"0A")
                && cols
                    .get(9)
                    .and_then(|i| i.parse::<u64>().ok())
                    .is_some_and(|i| owned.contains(&i))
                && let Some(port) = cols[1].rsplit(':').next()
                && let Ok(p) = u16::from_str_radix(port, 16)
            {
                out.push(p);
            }
        }
    }
    out.sort_unstable();
    out.dedup();
    out
}

/// Waits (real time, at most a minute) for a `debug-frame` whose path ends in FILE; its line.
async fn stop_in(ev: &Events, file: &str) -> i64 {
    for _ in 0..3000 {
        let hit =
            ev.0.lock()
                .unwrap()
                .iter()
                .filter(|(n, _)| n == "debug-frame")
                .find(|(_, d)| d["path"].as_str().is_some_and(|p| p.ends_with(file)))
                .map(|(_, d)| d["line"].as_i64().unwrap_or(0));
        if let Some(l) = hit {
            return l;
        }
        crate::clock::sleep(Duration::from_millis(20)).await;
    }
    let seen: Vec<String> =
        ev.0.lock()
            .unwrap()
            .iter()
            .map(|(n, d)| format!("{n} {d}"))
            .collect();
    panic!("no stop in {file}; events:\n{}", seen.join("\n"));
}

async fn ended(ev: &Events) {
    for _ in 0..3000 {
        if ev.0.lock().unwrap().iter().any(|(n, _)| n == "debug-ended") {
            return;
        }
        crate::clock::sleep(Duration::from_millis(20)).await;
    }
    panic!("the session did not end");
}

fn write(dir: &Path, name: &str, text: &str) -> PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, text).unwrap();
    p
}

/// Runs CONFIG of the adapter ID found at FOUND with a breakpoint at CHILD:LINE in a block of LEN ports; once
/// stopped (and, with WAIT_FOR, once that file exists) the stop's line, the listeners, the block's ports, and the
/// session's tmp.
#[allow(clippy::too_many_arguments)]
async fn run(
    id: &str,
    found: Found,
    config: Value,
    dir: &Path,
    child: &Path,
    line: u32,
    len: u16,
    wait_for: Option<&Path>,
) -> (i64, Vec<u16>, Vec<u16>, PathBuf) {
    let table = Table::builtin();
    let adapter = table.by_id(id).unwrap();
    let blocks = Blocks::new(super::ports::RANGE, len);
    let block = blocks.claim().unwrap();
    let ports = block.ports();
    let tmp = dir.join("tmp");
    std::fs::create_dir_all(&tmp).unwrap();
    let preload = tmp.join(blocked::PRELOAD_NAME);
    std::fs::write(&preload, blocked::PRELOAD).unwrap();
    let env = Env {
        path: vec![],
        tools: dir.to_path_buf(),
    };
    let plan = blocked::plan(adapter, &found, &env, &config, &ports, &tmp, &preload).unwrap();
    let start = Start {
        name: id.into(),
        adapter_id: config["type"].as_str().unwrap().into(),
        request: plan.request,
        arguments: plan.arguments.clone(),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    let launcher = Arc::new(Blocked::new(
        plan,
        std::env::vars_os().collect(),
        dir.to_path_buf(),
        Some(block),
    ));
    let ev = Arc::new(Events::default());
    let d = Debug::new(ev.clone(), Arc::new(NoTerms));
    let root = dir.display().to_string();
    d.breakpoints(
        &root,
        Some(BpOp::Add {
            path: child.display().to_string(),
            line,
            column: None,
            enabled: true,
            condition: None,
            hit: None,
            log: None,
        }),
        None,
    )
    .await;
    let sid = d.start(1, &root, start, launcher).await.unwrap();
    let file = child.file_name().unwrap().to_string_lossy().into_owned();
    let stopped = stop_in(&ev, &file).await;
    if let Some(f) = wait_for {
        for _ in 0..3000 {
            if f.exists() {
                break;
            }
            crate::clock::sleep(Duration::from_millis(20)).await;
        }
    }
    let held = listeners();
    d.control(
        &sid,
        Op::Stop {
            kill_debuggee: Some(true),
        },
    )
    .await
    .unwrap_or_else(|e| {
        let seen: Vec<String> =
            ev.0.lock()
                .unwrap()
                .iter()
                .map(|(n, d)| format!("{n} {d}"))
                .collect();
        panic!("stop: {e}; events:\n{}", seen.join("\n"))
    });
    ended(&ev).await;
    d.shutdown().await;
    (stopped, held, ports, tmp)
}

fn live_dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("drgnx-debug-live-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&d).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: debugpy in the adapter image, alone (see the module's doc)"]
async fn debugpy_stops_in_a_subprocess_with_every_listener_in_the_block() {
    let dir = live_dir("py");
    write(
        &dir,
        "parent.py",
        "import subprocess, sys, os\nsubprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), 'child.py')], check=True)\n",
    );
    let child = write(
        &dir,
        "child.py",
        "total = 0\nfor i in range(5):\n    total += i\nprint(total)\n",
    );
    let python = std::env::var("DRGNX_DEBUG_LIVE_PYTHON").unwrap_or_else(|_| "python3".into());
    let config = json!({"type": "debugpy", "request": "launch", "name": "py",
                        "program": dir.join("parent.py"), "cwd": dir, "justMyCode": true});
    let (line, held, ports, _) = run(
        "debugpy",
        Found::Python(python.into()),
        config,
        &dir,
        &child,
        4,
        super::ports::LEN,
        None,
    )
    .await;
    assert_eq!(line, 4);
    assert!(
        held.iter().all(|p| ports.contains(p)),
        "listeners outside the block {ports:?}: {held:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: js-debug in the adapter image, alone (see the module's doc)"]
async fn js_debug_stops_in_a_child_forked_at_once_with_every_listener_in_the_block() {
    let dir = live_dir("js");
    // the fork is the program's first statement: no wait for js-debug's bootloader
    write(
        &dir,
        "parent.js",
        "const c = require('child_process').fork(require('path').join(__dirname, 'child.js'));\nc.on('exit', (code) => process.exit(code ?? 0));\n",
    );
    let child = write(
        &dir,
        "child.js",
        "let total = 0;\nfor (let i = 0; i < 5; i++) total += i;\nconsole.log(total);\n",
    );
    let js = std::env::var("DRGNX_DEBUG_LIVE_JS_DEBUG")
        .unwrap_or_else(|_| "/opt/js-debug/src/dapDebugServer.js".into());
    let config = json!({"type": "pwa-node", "request": "launch", "name": "js",
                        "program": dir.join("parent.js"), "cwd": dir});
    let (line, held, ports, tmp) = run(
        "js-debug",
        Found::Program(js.into()),
        config,
        &dir,
        &child,
        3,
        super::ports::LEN,
        None,
    )
    .await;
    assert_eq!(line, 3);
    assert!(
        held.iter().all(|p| ports.contains(p)),
        "listeners outside the block {ports:?}: {held:?}"
    );
    // the child's inspector took a block port through the preload
    let claims: Vec<String> = std::fs::read_dir(tmp.join(blocked::CLAIMS_DIR))
        .map(|r| {
            r.flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    assert_eq!(claims, [format!("port-{}", ports[2])]);
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: js-debug in the adapter image, alone (see the module's doc)"]
async fn a_child_past_the_blocks_ports_runs_without_the_debugger_and_says_so() {
    let dir = live_dir("js7");
    // a block of three ports: the adapter's, the program's, one child's. The first child takes it (it has said
    // "up" once its debugger is there), the second gets none
    write(
        &dir,
        "parent.js",
        "const cp = require('child_process'), path = require('path');\n\
         const a = cp.fork(path.join(__dirname, 'child.js'));\n\
         a.once('message', () => cp.fork(path.join(__dirname, 'second.js')));\n",
    );
    let child = write(
        &dir,
        "child.js",
        "process.send('up');\nlet total = 0;\nfor (let i = 0; i < 5; i++) total += i;\nconsole.log(total);\n",
    );
    write(
        &dir,
        "second.js",
        "require('fs').writeFileSync(require('path').join(__dirname, 'second.out'), String(require('inspector').url()));\n",
    );
    let js = std::env::var("DRGNX_DEBUG_LIVE_JS_DEBUG")
        .unwrap_or_else(|_| "/opt/js-debug/src/dapDebugServer.js".into());
    let config = json!({"type": "pwa-node", "request": "launch", "name": "js",
                        "program": dir.join("parent.js"), "cwd": dir});
    let out = dir.join("second.out");
    let (line, held, ports, tmp) = run(
        "js-debug",
        Found::Program(js.into()),
        config,
        &dir,
        &child,
        3,
        3,
        Some(&out),
    )
    .await;
    assert_eq!(line, 3);
    assert!(
        held.iter().all(|p| ports.contains(p)),
        "{ports:?}: {held:?}"
    );
    // the second child ran, with no inspector, and said why
    assert_eq!(std::fs::read_to_string(&out).unwrap(), "undefined");
    let refused: Vec<String> = std::fs::read_dir(tmp.join(blocked::CLAIMS_DIR))
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("refused-"))
        .collect();
    assert_eq!(refused.len(), 1, "{refused:?}");
}
