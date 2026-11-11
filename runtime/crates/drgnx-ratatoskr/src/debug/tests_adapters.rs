//! The adapter table (`etc/debug-adapters.eld`, read as data), `type` → adapter, discovery, the command line, ports.
use super::adapters::{self, Env, Found, Table, Transport};
use serde_json::json;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

fn exe(p: &Path) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn the_built_in_table_reads_and_marks_the_four_tested_adapters() {
    let t = Table::builtin();
    let tested: Vec<&str> =
        t.0.iter()
            .filter(|a| a.tested)
            .map(|a| a.id.as_str())
            .collect();
    assert_eq!(tested, ["debugpy", "js-debug", "delve", "lldb-dap"]);
    assert!(
        t.0.iter()
            .filter(|a| !a.not_built_in)
            .all(|a| a.find.is_some() && a.start.is_some())
    );
}

#[test]
fn a_type_names_its_adapter_and_an_unknown_one_says_what_is_known() {
    let t = Table::builtin();
    assert_eq!(t.for_type("python").unwrap().id, "debugpy");
    assert_eq!(t.for_type("pwa-node").unwrap().id, "js-debug");
    assert_eq!(t.for_type("go").unwrap().id, "delve");
    let e = t.for_type("cobol").unwrap_err();
    assert!(
        e.contains("cobol") && e.contains("debugpy") && e.contains("debug.adapters"),
        "{e}"
    );
    let e = t.for_type("cppdbg").unwrap_err();
    assert!(
        e.contains("not built in") && e.contains("debug.adapters"),
        "{e}"
    );
}

#[test]
fn the_table_is_data_and_nothing_in_it_is_evaluated() {
    // a read-time evaluation is refused by the reader; a form is only a list
    assert!(Table::read(b"((:id \"x\" :name #.(shell-command \"id\") :types (\"x\")))").is_err());
    let t = Table::read(
        b"((:id \"x\" :name \"X\" :types (\"x\") :defaults ((:name (eval (kill-emacs))))))",
    )
    .unwrap();
    assert_eq!(
        t.0[0].defaults[0]["name"],
        json!(["eval", ["kill-emacs"]]),
        "a form is only a list of names"
    );
    assert!(
        Table::read(b"((:id \"x\" :name \"X\" :types (\"x\") :typo 1))")
            .unwrap_err()
            .contains("typo")
    );
}

#[test]
fn defaults_follow_the_files_language() {
    let t = Table::builtin();
    let d = t.defaults_for("python");
    assert_eq!(d[0]["name"], "Python: Current File");
    assert_eq!(d[0]["program"], "${file}");
    assert_eq!(d[0]["request"], "launch");
    assert!(t.defaults_for("cobol").is_empty());
}

#[test]
fn an_adapter_is_found_on_path_in_the_tools_folder_or_as_a_python_module() {
    let d = tempfile::tempdir().unwrap();
    let bin = d.path().join("bin");
    let tools = d.path().join("tools");
    exe(&bin.join("dlv"));
    std::fs::create_dir_all(tools.join("js-debug/src")).unwrap();
    std::fs::write(tools.join("js-debug/src/dapDebugServer.js"), "").unwrap();
    exe(&tools.join("venv/bin/python3"));
    std::fs::create_dir_all(tools.join("venv/lib/python3.15/site-packages/debugpy")).unwrap();
    let env = Env {
        path: vec![bin.clone()],
        tools: tools.clone(),
    };
    let t = Table::builtin();
    assert_eq!(
        adapters::find(t.by_id("delve").unwrap(), &env),
        Some(Found::Program(bin.join("dlv")))
    );
    assert_eq!(
        adapters::find(t.by_id("js-debug").unwrap(), &env),
        Some(Found::Program(tools.join("js-debug/src/dapDebugServer.js")))
    );
    assert_eq!(
        adapters::find(t.by_id("debugpy").unwrap(), &env),
        Some(Found::Python(tools.join("venv/bin/python3")))
    );
    assert_eq!(adapters::find(t.by_id("lldb-dap").unwrap(), &env), None);
}

#[test]
fn a_file_on_path_that_is_not_executable_is_not_found() {
    let d = tempfile::tempdir().unwrap();
    std::fs::write(d.path().join("dlv"), "").unwrap();
    let env = Env {
        path: vec![d.path().to_path_buf()],
        tools: d.path().join("tools"),
    };
    assert_eq!(
        adapters::find(Table::builtin().by_id("delve").unwrap(), &env),
        None
    );
}

#[test]
fn the_command_line_fills_in_program_python_tools_and_port() {
    let t = Table::builtin();
    let env = Env {
        path: vec![],
        tools: "/t".into(),
    };
    let (how, argv) = adapters::command(
        t.by_id("delve").unwrap(),
        &Found::Program("/b/dlv".into()),
        &env,
        Some(4711),
    )
    .unwrap();
    assert_eq!(how, Transport::Tcp);
    assert_eq!(argv, ["/b/dlv", "dap", "--listen", "127.0.0.1:4711"]);
    let (how, argv) = adapters::command(
        t.by_id("debugpy").unwrap(),
        &Found::Python("/t/venv/bin/python3".into()),
        &env,
        None,
    )
    .unwrap();
    assert_eq!(how, Transport::Stdio);
    assert_eq!(argv, ["/t/venv/bin/python3", "-m", "debugpy.adapter"]);
    let e = adapters::command(
        t.by_id("delve").unwrap(),
        &Found::Program("/b/dlv".into()),
        &env,
        None,
    )
    .unwrap_err();
    assert!(e.contains("port"), "{e}");
}

#[test]
fn a_free_port_is_on_this_machine() {
    let p = adapters::free_port().unwrap();
    assert!(p > 0);
    std::net::TcpListener::bind(("127.0.0.1", p)).expect("free again once the hub let go of it");
    let _ = json!(null);
}
