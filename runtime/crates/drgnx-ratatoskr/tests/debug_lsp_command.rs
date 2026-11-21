//! The `lsp-command` start kind (language packs Task 10j): the launcher against a language server that opens a DAP
//! server (`ratatoskr debug-lsp-mock`), and every way that can go wrong ends in a named error and no hang. The fill
//! steps refuse an answer that is not a plain string or a list of strings.
//!
//! test-pattern: pure (D) for the failures (each wait has a short deadline of its own), process (the mock is a child).
#![cfg(feature = "test-hooks")]

use drgnx_ratatoskr::debug::Launcher;
use drgnx_ratatoskr::debug::lsp_command::{LspLauncher, Within};
use drgnx_ratatoskr::debug::session::Sig;
use serde_json::{Value, json};
use skald::manifest::{Fill, LspCommand, Put, Select};
use std::path::{Path, PathBuf};
use std::time::Duration;

const BIN: &str = env!("CARGO_BIN_EXE_ratatoskr");

fn put(key: &str, field: Option<&str>, index: Option<usize>) -> Put {
    Put {
        key: key.into(),
        field: field.map(str::to_owned),
        index,
        optional: false,
    }
}

/// The steps a Java pack has, against the mock.
fn fills() -> Vec<Fill> {
    vec![
        Fill {
            command: "vscode.java.resolveMainClass".into(),
            args: vec!["{root-uri}".into()],
            select: Some(Select {
                field: "filePath".into(),
                equals: "${file}".into(),
            }),
            when_missing: Some("mainClass".into()),
            retry_empty: None,
            into: vec![
                put("mainClass", Some("mainClass"), None),
                put("projectName", Some("projectName"), None),
            ],
        },
        Fill {
            command: "vscode.java.resolveClasspath".into(),
            args: vec!["${config:mainClass}".into(), "${config:projectName}".into()],
            select: None,
            when_missing: None,
            retry_empty: None,
            into: vec![
                put("modulePaths", None, Some(0)),
                put("classPaths", None, Some(1)),
            ],
        },
        Fill {
            command: "vscode.java.resolveJavaExecutable".into(),
            args: vec!["${config:mainClass}".into()],
            select: None,
            when_missing: None,
            retry_empty: None,
            into: vec![put("javaExec", None, None)],
        },
    ]
}

/// FUT bounded: a wait that passes 30 s fails the test with LABEL, never hangs it (and the children are killed on drop).
async fn bounded<T>(label: &str, fut: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(30), fut)
        .await
        .unwrap_or_else(|_| panic!("{label}: no answer within 30 s"))
}

struct Rig {
    launcher: LspLauncher,
    file: PathBuf,
    _dir: tempfile::TempDir,
}

/// A launcher whose server is `debug-lsp-mock MODE [ARG]`. ARG `FILE` is the launch's file.
fn rig(mode: &str, port: Option<u16>) -> Rig {
    rig_with(mode, port, fills())
}

fn rig_with(mode: &str, port: Option<u16>, fill: Vec<Fill>) -> Rig {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("project");
    std::fs::create_dir_all(&root).unwrap();
    let file = root.join("Main.java");
    std::fs::write(&file, "class Main {}").unwrap();
    let bin = Path::new(BIN);
    let mut server = vec![
        "{tools}/ratatoskr".to_owned(),
        "debug-lsp-mock".into(),
        mode.into(),
    ];
    match port {
        Some(p) => {
            server.push(p.to_string());
            server.push(file.to_string_lossy().into_owned());
        }
        None => server.push(file.to_string_lossy().into_owned()),
    }
    let spec = LspCommand {
        server,
        root: None,
        init_options: Some(json!({"bundles": ["{tools}/ratatoskr"]})),
        debug_command: "vscode.java.startDebugSession".into(),
        debug_args: vec![],
        fill,
        open_file: None,
    };
    let mut launcher = LspLauncher::new(
        spec,
        bin.parent().unwrap().to_path_buf(),
        root,
        Some(file.clone()),
        dir.path().join("work"),
        vec![],
    );
    launcher.within = Within {
        init: Duration::from_secs(5),
        ready: Duration::from_secs(5),
        command: Duration::from_secs(5),
        port: Duration::from_secs(5),
    };
    Rig {
        launcher,
        file,
        _dir: dir,
    }
}

/// What starting the rig's server ends in: the error text, or a panic when it hangs.
async fn failure(rig: &Rig) -> String {
    let started = tokio::time::timeout(Duration::from_secs(60), rig.launcher.connect())
        .await
        .expect("the start must end with an answer, not hang");
    match started {
        Ok(_) => panic!("the start was meant to fail"),
        Err(e) => e,
    }
}

#[tokio::test]
async fn the_server_opens_a_dap_port_the_hub_connects_and_the_launch_is_filled() {
    let r = rig("ok", None);
    let mut c = tokio::time::timeout(Duration::from_secs(60), r.launcher.connect())
        .await
        .expect("no hang")
        .unwrap_or_else(|e| panic!("{e}"));
    // DAP works over the port the server answered
    let answer = c
        .client
        .request("initialize", json!({"adapterID": "java"}))
        .await
        .unwrap();
    assert_eq!(answer["supportsConfigurationDoneRequest"], true, "{answer}");
    // the launch is completed from the server's answers: the main class of the current file, its classpath, its JVM
    let args = bounded(
        "the fill",
        r.launcher
            .fill(json!({"type": "java", "request": "launch", "cwd": "/p"})),
    )
    .await
    .unwrap();
    assert_eq!(args["mainClass"], "app.Main");
    assert_eq!(args["projectName"], "app");
    assert_eq!(args["modulePaths"], json!(["/mp/a"]));
    assert_eq!(args["classPaths"], json!(["/cp/a", "/cp/b"]));
    assert_eq!(args["javaExec"], "/jdk/bin/java");
    assert_eq!(args["cwd"], "/p", "what the launch had stays");
    // a main class the launch names is kept, and its project is still resolved from it
    let named = bounded(
        "the fill of a named class",
        r.launcher
            .fill(json!({"mainClass": "app.Other", "projectName": "mine"})),
    )
    .await
    .unwrap();
    assert_eq!(
        (named["mainClass"].as_str(), named["projectName"].as_str()),
        (Some("app.Other"), Some("mine"))
    );
    // a second DAP connection (a child session) reaches the same server
    let child = bounded("the child connection", r.launcher.child())
        .await
        .unwrap_or_else(|e| panic!("{e}"));
    bounded(
        "the DAP initialize of the child session",
        child.client.request("initialize", json!({})),
    )
    .await
    .unwrap();
    // the server and what it started are one group: ending it ends them
    c.proc.signal(Sig::Kill);
    tokio::time::timeout(Duration::from_secs(30), c.proc.wait())
        .await
        .expect("the server ends");
    let _ = &r.file;
}

#[tokio::test]
async fn a_server_that_never_returns_a_port_a_stranger_s_port_or_not_a_port_ends_in_a_named_error()
{
    let e = failure(&rig("no-port", None)).await;
    assert!(
        e.contains("the debug command")
            && e.contains("did not answer vscode.java.startDebugSession within 5 s"),
        "{e}"
    );
    let held = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = held.local_addr().unwrap().port();
    let e = failure(&rig("stranger", Some(port))).await;
    assert!(
        e.contains(&format!("port {port} is held by process"))
            && e.contains("not the session's adapter"),
        "{e}"
    );
    let e = failure(&rig("bad-port", None)).await;
    assert!(e.contains("answered \"not a port\", not a port"), "{e}");
}

#[tokio::test]
async fn an_oversized_frame_a_server_that_exits_in_initialize_and_one_never_ready_each_end_in_a_named_error()
 {
    let e = failure(&rig("oversized", None)).await;
    assert!(
        e.starts_with("initialize:")
            && e.contains("a frame of 20971520 bytes, over the 16777216-byte cap"),
        "{e}"
    );
    let e = failure(&rig("exit-init", None)).await;
    assert!(
        e.starts_with("initialize:") && e.contains("connection ended"),
        "{e}"
    );
    assert!(
        e.contains("the mock server cannot start"),
        "its stderr is in the error: {e}"
    );
    let e = failure(&rig("never-ready", None)).await;
    assert!(
        e.starts_with("start:") && e.contains("did not answer the start (ServiceReady) within 5 s"),
        "{e}"
    );
    // a server that is not there
    let mut missing = rig("ok", None);
    missing.launcher.spec.server[0] = "{tools}/no-such-server".into();
    let e = failure(&missing).await;
    assert!(e.contains("no-such-server is not installed"), "{e}");
}

#[tokio::test]
async fn a_hostile_answer_is_refused_whether_nested_objects_a_list_in_a_list_or_a_variable() {
    let r = rig("hostile", None);
    let c = tokio::time::timeout(Duration::from_secs(60), r.launcher.connect())
        .await
        .expect("no hang")
        .unwrap_or_else(|e| panic!("{e}"));
    // (the connection stays open: a dropped one ends the server)
    let _keep = c;
    // an object where a string belongs
    let e = r
        .launcher
        .fill(json!({"request": "launch"}))
        .await
        .unwrap_err();
    assert!(
        e.contains("mainClass") && e.contains("not a string or a list of strings"),
        "{e}"
    );
    // with the main class known, the classpath answer is a list in a list, then the JVM path holds a variable
    let e = r
        .launcher
        .fill(json!({"mainClass": "app.Main", "projectName": "app"}))
        .await
        .unwrap_err();
    assert!(
        e.contains("classPaths") && e.contains("not a string or a list of strings"),
        "{e}"
    );
    let mut only_java = rig("hostile", None);
    only_java.launcher.spec.fill = fills().split_off(2);
    let c = only_java
        .launcher
        .connect()
        .await
        .unwrap_or_else(|e| panic!("{e}"));
    let _keep2 = c;
    let e = only_java
        .launcher
        .fill(json!({"mainClass": "app.Main"}))
        .await
        .unwrap_err();
    assert!(
        e.contains("javaExec") && e.contains("holding a variable"),
        "{e}"
    );
    let _: Value = json!(null);
}

/// The mock's answer to `resolveMainClass` has a main class and no project name.
async fn fill_without_project(optional: bool) -> Result<serde_json::Value, String> {
    let mut steps = fills();
    steps[0].into[1].optional = optional;
    steps[1].args[1] = if optional {
        "${config:projectName?}".into()
    } else {
        "${config:projectName}".into()
    };
    let r = rig_with("no-project", None, steps);
    let _c = bounded("the start", r.launcher.connect())
        .await
        .unwrap_or_else(|e| panic!("{e}"));
    bounded(
        "the fill",
        r.launcher
            .fill(json!({"type": "java", "request": "launch"})),
    )
    .await
}

#[tokio::test]
async fn an_optional_key_the_answer_lacks_is_left_out_and_its_config_word_reads_null() {
    let args = fill_without_project(true).await.unwrap();
    assert_eq!(args["mainClass"], "app.Main");
    assert!(args.get("projectName").is_none(), "{args}");
    assert_eq!(args["javaExec"], "/jdk/bin/java");
}

#[tokio::test]
async fn a_key_that_is_not_optional_still_errors_when_the_answer_lacks_it() {
    let e = fill_without_project(false).await.unwrap_err();
    assert!(e.contains("the answer has no projectName"), "{e}");
}

/// A key the launch has but not as a string is an error, as `${config:KEY}` says; only a missing key (or null) reads null.
#[tokio::test]
async fn an_optional_config_word_errors_on_a_key_of_the_wrong_type_and_reads_null_when_it_is_missing()
 {
    // mainClass is named, so step 1 is skipped; step 2 and 3 ask with `${config:projectName?}`
    let mut steps = fills();
    steps[1].args[1] = "${config:projectName?}".into();
    let r = rig_with("no-project", None, steps);
    let _c = bounded("the start", r.launcher.connect())
        .await
        .unwrap_or_else(|e| panic!("{e}"));
    let e = bounded(
        "the fill",
        r.launcher
            .fill(json!({"mainClass": "app.Main", "projectName": 123})),
    )
    .await
    .unwrap_err();
    assert!(e.contains("projectName"), "{e}");
    for fine in [
        json!({"mainClass": "app.Main"}),
        json!({"mainClass": "app.Main", "projectName": null}),
    ] {
        bounded("the fill", r.launcher.fill(fine.clone()))
            .await
            .unwrap_or_else(|e| panic!("{fine}: {e}"));
    }
}

/// `{session}` is the folder of this session in `:fill` as it is in `:server`.
#[tokio::test]
async fn session_is_the_sessions_own_folder_in_fill_steps() {
    let steps = vec![Fill {
        command: "echo.args".into(),
        args: vec!["{session}".into()],
        select: None,
        when_missing: None,
        retry_empty: None,
        into: vec![put("sessionDir", None, Some(0))],
    }];
    let r = rig_with("ok", None, steps);
    let _c = bounded("the start", r.launcher.connect())
        .await
        .unwrap_or_else(|e| panic!("{e}"));
    let args = bounded("the fill", r.launcher.fill(json!({})))
        .await
        .unwrap_or_else(|e| panic!("{e}"));
    let dir = PathBuf::from(args["sessionDir"].as_str().unwrap());
    assert!(dir.is_dir(), "{}", dir.display());
    assert_eq!(
        dir.parent().unwrap(),
        r.launcher.work_base,
        "{}",
        dir.display()
    );
}

/// A child session reconnects only to the server's own port: when the server is gone and a stranger binds the port, the
/// child session is refused, never connected.
#[tokio::test]
async fn a_child_session_never_connects_to_a_stranger_on_the_port_of_a_dead_server() {
    let r = rig("ok", None);
    let mut c = bounded("the start", r.launcher.connect())
        .await
        .unwrap_or_else(|e| panic!("{e}"));
    let port = r.launcher.port().expect("a running server has a port");
    c.proc.signal(Sig::Kill);
    bounded("the server ends", c.proc.wait()).await;
    let stranger = std::net::TcpListener::bind(("127.0.0.1", port))
        .unwrap_or_else(|e| panic!("the stranger cannot bind {port}: {e}"));
    let got = bounded("the child connection", r.launcher.child()).await;
    assert!(got.is_err(), "the child session connected to a stranger");
    drop(stranger);
}
