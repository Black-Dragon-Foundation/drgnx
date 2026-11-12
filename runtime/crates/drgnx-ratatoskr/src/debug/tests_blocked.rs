//! A session inside a port block (spec §21): debugpy as an attach with `listen`, js-debug attached to
//! `node --inspect-brk` with the children's preload.
use super::adapters::{Env, Found, Table};
use super::blocked::{self, Plan};
use super::session::Request;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const PORTS: [u16; 8] = [47000, 47001, 47002, 47003, 47004, 47005, 47006, 47007];

fn env() -> Env {
    Env {
        path: vec![],
        tools: PathBuf::from("/d/tools"),
    }
}

fn plan_of(id: &str, found: Found, config: Value) -> Result<Plan, String> {
    let t = Table::builtin();
    blocked::plan(
        t.by_id(id).unwrap(),
        &found,
        &env(),
        &config,
        &PORTS,
        Path::new("/s/tmp"),
        Path::new("/d/etc/debug-node-preload.js"),
    )
}

fn get<'a>(env: &'a [(String, String)], k: &str) -> Option<&'a str> {
    env.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str())
}

#[test]
fn a_debugpy_launch_becomes_an_attach_that_listens_on_the_blocks_second_port() {
    let p = plan_of(
        "debugpy",
        Found::Python("/d/tools/venv/bin/python3".into()),
        json!({"type": "debugpy", "request": "launch", "name": "Py", "program": "/p/a.py", "args": ["-v"],
               "cwd": "/p", "env": {"K": "1"}, "justMyCode": false, "console": "integratedTerminal"}),
    )
    .unwrap();
    assert_eq!(
        p.adapter,
        [
            "/d/tools/venv/bin/python3",
            "-m",
            "debugpy.adapter",
            "--host",
            "127.0.0.1",
            "--port",
            "47000"
        ]
    );
    assert_eq!(p.port, 47000);
    assert_eq!(p.request, Request::Attach);
    let a = &p.arguments;
    assert_eq!(a["request"], "attach");
    assert_eq!(a["listen"], json!({"host": "127.0.0.1", "port": 47001}));
    assert_eq!(a["justMyCode"], false);
    assert_eq!(a["subProcess"], true);
    assert_eq!(a["redirectOutput"], true);
    for gone in ["program", "args", "console", "env", "python"] {
        assert!(
            a.get(gone).is_none(),
            "{gone} is the program's, not the attach's"
        );
    }
    let d = &p.debuggee;
    assert_eq!(
        d.argv,
        [
            "/d/tools/venv/bin/python3",
            "-m",
            "debugpy",
            "--connect",
            "127.0.0.1:47001",
            "--configure-subProcess",
            "true",
            "/p/a.py",
            "-v"
        ]
    );
    assert_eq!(d.cwd, PathBuf::from("/p"));
    assert_eq!(get(&d.env, "K"), Some("1"));
    assert_eq!(get(&d.env, "TMPDIR"), Some("/s/tmp"));
    // it starts once the adapter listens on its port (debugpy connects once, no retry)
    assert_eq!(d.after_listen, Some(47001));
    assert_eq!(get(&d.env, "DRGNX_DEBUG_WAIT_BOOTLOADER"), None);
}

#[test]
fn a_debugpy_module_with_its_own_python_and_no_subprocesses() {
    let p = plan_of(
        "debugpy",
        Found::Python("/d/tools/venv/bin/python3".into()),
        json!({"type": "python", "request": "launch", "module": "pkg.main", "python": "/p/.venv/bin/python",
               "subProcess": false}),
    )
    .unwrap();
    assert_eq!(p.arguments["subProcess"], false);
    assert_eq!(
        p.debuggee.argv,
        [
            "/p/.venv/bin/python",
            "-m",
            "debugpy",
            "--connect",
            "127.0.0.1:47001",
            "--configure-subProcess",
            "false",
            "-m",
            "pkg.main"
        ]
    );
}

#[test]
fn a_js_debug_launch_attaches_to_inspect_brk_with_the_preload_mapping_children_to_the_block() {
    let p = plan_of(
        "js-debug",
        Found::Program("/d/tools/js-debug/src/dapDebugServer.js".into()),
        json!({"type": "pwa-node", "request": "launch", "name": "Node", "program": "/p/a.js", "args": ["x"],
               "runtimeArgs": ["--no-warnings"], "cwd": "/p", "env": {"NODE_OPTIONS": "--max-old-space-size=99"},
               "skipFiles": ["<node_internals>/**"], "outputCapture": "std"}),
    )
    .unwrap();
    assert_eq!(
        p.adapter,
        [
            "node",
            "/d/tools/js-debug/src/dapDebugServer.js",
            "47000",
            "127.0.0.1"
        ]
    );
    let a = &p.arguments;
    assert_eq!(a["request"], "attach");
    assert_eq!(a["address"], "127.0.0.1");
    assert_eq!(a["port"], 47001);
    assert_eq!(a["autoAttachChildProcesses"], true);
    assert_eq!(a["continueOnAttach"], true);
    assert_eq!(a["skipFiles"], json!(["<node_internals>/**"]));
    for gone in ["program", "args", "runtimeArgs", "env", "outputCapture"] {
        assert!(a.get(gone).is_none(), "{gone}");
    }
    let d = &p.debuggee;
    assert_eq!(
        d.argv,
        [
            "node",
            "--no-warnings",
            "--inspect-brk=127.0.0.1:47001",
            "/p/a.js",
            "x"
        ]
    );
    // it waits at its first line for the attach: started before the adapter
    assert_eq!(d.after_listen, None);
    assert_eq!(
        get(&d.env, "NODE_OPTIONS"),
        Some("--require /d/etc/debug-node-preload.js --max-old-space-size=99")
    );
    assert_eq!(
        get(&d.env, "DRGNX_DEBUG_PORTS"),
        Some("47002,47003,47004,47005,47006,47007")
    );
    assert_eq!(
        get(&d.env, "DRGNX_DEBUG_CLAIMS"),
        Some("/s/tmp/drgnx-debug-ports")
    );
    assert_eq!(get(&d.env, "TMPDIR"), Some("/s/tmp"));
    // a child started before js-debug's bootloader reaches the program waits for it (the preload)
    assert_eq!(get(&d.env, "DRGNX_DEBUG_WAIT_BOOTLOADER"), Some("1"));
}

#[test]
fn a_js_debug_launch_without_child_attach_starts_children_at_once() {
    let p = plan_of(
        "js-debug",
        Found::Program("/d/tools/js-debug/src/dapDebugServer.js".into()),
        json!({"type": "pwa-node", "request": "launch", "program": "/p/a.js", "autoAttachChildProcesses": false}),
    )
    .unwrap();
    assert_eq!(p.arguments["autoAttachChildProcesses"], false);
    assert_eq!(get(&p.debuggee.env, "DRGNX_DEBUG_WAIT_BOOTLOADER"), None);
}

#[test]
fn what_a_block_cannot_run_says_why() {
    let attach = plan_of(
        "debugpy",
        Found::Python("/x/python3".into()),
        json!({"type": "debugpy", "request": "attach", "processId": 12}),
    )
    .unwrap_err();
    assert!(attach.contains("launch"), "{attach}");
    let none = plan_of(
        "debugpy",
        Found::Python("/x/python3".into()),
        json!({"type": "debugpy", "request": "launch"}),
    )
    .unwrap_err();
    assert!(
        none.contains("program") && none.contains("module"),
        "{none}"
    );
    let lldb = plan_of(
        "lldb-dap",
        Found::Program("/x/lldb-dap".into()),
        json!({"type": "lldb-dap", "request": "launch", "program": "/p/a"}),
    )
    .unwrap_err();
    assert!(lldb.contains("lldb-dap"), "{lldb}");
}

/// A plan whose adapter and program never listen (`sleep`), on PORT and the next.
fn sleeping(port: u16) -> Plan {
    let idle = |s: &str| vec!["sleep".to_owned(), s.to_owned()];
    Plan {
        adapter: idle("30"),
        port,
        request: Request::Attach,
        arguments: json!({}),
        debuggee: blocked::Debuggee {
            argv: idle("30"),
            env: vec![],
            cwd: PathBuf::new(),
            after_listen: Some(port + 1),
        },
    }
}

#[tokio::test]
async fn a_strangers_listener_on_the_adapters_port_ends_the_session_unconnected() {
    use super::Launcher;
    // the test process listens where the adapter should: another process group than the adapter's
    let stranger = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    stranger.set_nonblocking(true).unwrap();
    let port = stranger.local_addr().unwrap().port();
    let l = blocked::Blocked::new(
        sleeping(port),
        std::env::vars_os().collect(),
        std::env::temp_dir(),
        None,
    );
    let e = match l.connect().await {
        Ok(_) => panic!("connected to a stranger's listener"),
        Err(e) => e,
    };
    assert!(
        e.contains(&port.to_string()) && e.contains("not the session's"),
        "{e}"
    );
    // never connected to it
    assert_eq!(
        stranger.accept().map(|_| ()).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
}

/// macOS: the adapter and the program each start through the session's seal (Seatbelt with the block's ports), never
/// bare; the seal's refusal is the start's error.
#[tokio::test]
async fn the_adapter_and_the_program_start_through_the_seal() {
    use super::Launcher;
    let seen: Arc<Mutex<Vec<Vec<String>>>> = Arc::default();
    let seal = |seen: Arc<Mutex<Vec<Vec<String>>>>| -> blocked::Seal {
        Arc::new(move |spec: draugr::Spec| {
            let seen = seen.clone();
            Box::pin(async move {
                let mut argv = vec![spec.program.display().to_string()];
                argv.extend(spec.args.iter().map(|a| a.to_string_lossy().into_owned()));
                seen.lock().unwrap().push(argv);
                Err::<draugr::Spec, String>("sealed: refused here".into())
            })
        })
    };
    // debugpy's shape: the adapter first
    let l = blocked::Blocked::new(sleeping(47990), vec![], std::env::temp_dir(), None)
        .sealed(seal(seen.clone()));
    let e = l
        .connect()
        .await
        .err()
        .expect("a refused seal starts nothing");
    assert!(e.contains("sealed: refused here"), "{e}");
    // js-debug's shape: the program first
    let mut p = sleeping(47990);
    p.debuggee.after_listen = None;
    p.debuggee.argv = vec!["sleep".into(), "31".into()];
    let l = blocked::Blocked::new(p, vec![], std::env::temp_dir(), None).sealed(seal(seen.clone()));
    let e = l
        .connect()
        .await
        .err()
        .expect("a refused seal starts nothing");
    assert!(e.contains("sealed: refused here"), "{e}");
    assert_eq!(
        *seen.lock().unwrap(),
        [
            vec!["sleep".to_owned(), "30".into()],
            vec!["sleep".to_owned(), "31".into()]
        ]
    );
}
