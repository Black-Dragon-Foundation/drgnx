//! tasks.json (spec §9.2, tier 2): `shell` and `process` tasks, `dependsOn` in order, `${defaultBuildTask}`, a failing
//! task stopping the start, `isBackground` refused.
use super::launch::Os;
use super::tasks::{self, Step};
use serde_json::json;
use std::path::Path;

fn file(text: &str) -> Vec<serde_json::Value> {
    tasks::parse(text).unwrap()
}

#[test]
fn tasks_json_is_read_as_jsonc_and_an_error_says_where() {
    let t = file(
        "{ // build steps\n \"tasks\": [ {\"label\": \"b\", \"type\": \"shell\", \"command\": \"make\"}, ], }",
    );
    assert_eq!(t.len(), 1);
    let e = tasks::parse("{\n \"tasks\": [ {\"label\": } ]\n}").unwrap_err();
    assert_eq!(e.line, 2, "{e}");
}

#[test]
fn a_shell_task_runs_its_line_in_sh_and_a_process_task_runs_its_argv_as_is() {
    let t = file(
        r#"{"tasks": [
          {"label": "s", "type": "shell", "command": "make", "args": ["all", "it's"]},
          {"label": "p", "type": "process", "command": "cargo", "args": ["build", "a b"]}]}"#,
    );
    let s = tasks::order(&t, "s", Os::Linux).unwrap();
    assert_eq!(
        s[0].argv,
        vec!["/bin/sh", "-c", "make all 'it'\\''s'"],
        "args quoted for the shell"
    );
    let p = tasks::order(&t, "p", Os::Linux).unwrap();
    assert_eq!(p[0].argv, vec!["cargo", "build", "a b"], "never split");
}

#[test]
fn depends_on_runs_first_in_order_each_task_once() {
    let t = file(
        r#"{"tasks": [
          {"label": "all", "command": "true", "dependsOn": ["gen", "lib"]},
          {"label": "gen", "command": "true"},
          {"label": "lib", "command": "true", "dependsOn": "gen"}]}"#,
    );
    let labels: Vec<String> = tasks::order(&t, "all", Os::Linux)
        .unwrap()
        .into_iter()
        .map(|s| s.label)
        .collect();
    assert_eq!(labels, ["gen", "lib", "all"]);
}

#[test]
fn an_unknown_task_and_a_cycle_are_named() {
    let t = file(
        r#"{"tasks": [
          {"label": "a", "command": "true", "dependsOn": "b"},
          {"label": "b", "command": "true", "dependsOn": "a"},
          {"label": "c", "command": "true", "dependsOn": "nope"}]}"#,
    );
    let e = tasks::order(&t, "a", Os::Linux).unwrap_err();
    assert!(e.contains("a → b → a"), "{e}");
    let e = tasks::order(&t, "c", Os::Linux).unwrap_err();
    assert!(e.contains("nope"), "{e}");
}

#[test]
fn a_background_task_is_refused() {
    let t = file(r#"{"tasks": [{"label": "watch", "command": "tsc -w", "isBackground": true}]}"#);
    let e = tasks::order(&t, "watch", Os::Linux).unwrap_err();
    assert!(e.contains("watch") && e.contains("isBackground"), "{e}");
}

#[test]
fn the_platform_section_replaces_the_base_fields() {
    let t = file(
        r#"{"tasks": [{"label": "b", "type": "process", "command": "make",
                       "linux": {"command": "gmake"}, "osx": {"command": "bsdmake"}}]}"#,
    );
    assert_eq!(tasks::order(&t, "b", Os::Linux).unwrap()[0].argv, ["gmake"]);
    assert_eq!(
        tasks::order(&t, "b", Os::Macos).unwrap()[0].argv,
        ["bsdmake"]
    );
}

#[test]
fn the_default_build_task_is_the_build_group_s_default() {
    let t = file(
        r#"{"tasks": [
          {"label": "test", "command": "true", "group": "test"},
          {"label": "build", "command": "true", "group": "build"},
          {"label": "release", "command": "true", "group": {"kind": "build", "isDefault": true}}]}"#,
    );
    assert_eq!(tasks::default_build_task(&t).as_deref(), Some("release"));
    let none = file(r#"{"tasks": [{"label": "build", "command": "true", "group": "build"}]}"#);
    assert_eq!(tasks::default_build_task(&none), None);
}

fn step(label: &str, script: &str, cwd: &Path) -> Step {
    Step {
        label: label.into(),
        argv: vec!["/bin/sh".into(), "-c".into(), script.into()],
        cwd: cwd.to_path_buf(),
        env: vec![("DRGNX_TASK_TEST".into(), "1".into())],
    }
}

#[tokio::test]
async fn the_steps_run_in_order_and_the_first_failure_stops_the_rest() {
    let d = tempfile::tempdir().unwrap();
    let env: Vec<(std::ffi::OsString, std::ffi::OsString)> =
        vec![("PATH".into(), "/usr/bin:/bin".into())];
    let ok = vec![
        step("one", "echo one >> log", d.path()),
        step("two", "echo \"two $DRGNX_TASK_TEST\" >> log", d.path()),
    ];
    tasks::run(&ok, &env).await.unwrap();
    assert_eq!(
        std::fs::read_to_string(d.path().join("log")).unwrap(),
        "one\ntwo 1\n"
    );
    let bad = vec![
        step("make", "echo 'error: no rule' >&2; exit 2", d.path()),
        step("after", "echo after >> log", d.path()),
    ];
    let e = tasks::run(&bad, &env).await.unwrap_err();
    assert!(
        e.contains("make") && e.contains("exit 2") && e.contains("no rule"),
        "{e}"
    );
    assert!(
        !std::fs::read_to_string(d.path().join("log"))
            .unwrap()
            .contains("after")
    );
}

#[tokio::test]
async fn a_pre_launch_task_comes_from_the_roots_tasks_json() {
    let d = tempfile::tempdir().unwrap();
    std::fs::create_dir(d.path().join(".vscode")).unwrap();
    std::fs::write(
        d.path().join(".vscode/tasks.json"),
        r#"{"tasks": [{"label": "build", "type": "process", "command": "/bin/sh",
                        "args": ["-c", "echo built > out"], "options": {"cwd": "${workspaceFolder}/sub"}}]}"#,
    )
    .unwrap();
    std::fs::create_dir(d.path().join("sub")).unwrap();
    let steps = tasks::before_launch(
        d.path(),
        &json!({"preLaunchTask": "build"}),
        Os::Linux,
        &|s| Ok(s.replace("${workspaceFolder}", &d.path().to_string_lossy())),
    )
    .unwrap();
    assert_eq!(steps.len(), 1);
    assert_eq!(steps[0].cwd, d.path().join("sub"));
    // no preLaunchTask, nothing to run; one that names no task in a missing file: an error naming it
    assert!(
        tasks::before_launch(d.path(), &json!({}), Os::Linux, &|s| Ok(s.into()))
            .unwrap()
            .is_empty()
    );
    let e = tasks::before_launch(
        Path::new("/nonexistent"),
        &json!({"preLaunchTask": "x"}),
        Os::Linux,
        &|s| Ok(s.into()),
    )
    .unwrap_err();
    assert!(e.contains("tasks.json") && e.contains('x'), "{e}");
}

#[test]
fn a_post_debug_task_comes_from_the_same_file() {
    let d = tempfile::tempdir().unwrap();
    std::fs::create_dir(d.path().join(".vscode")).unwrap();
    std::fs::write(
        d.path().join(".vscode/tasks.json"),
        r#"{"tasks": [{"label": "clean", "type": "process", "command": "rm", "args": ["-f", "out"]}]}"#,
    )
    .unwrap();
    let config = json!({"preLaunchTask": "nope", "postDebugTask": "clean"});
    let steps = tasks::after_debug(d.path(), &config, Os::Linux, &|s| Ok(s.into())).unwrap();
    assert_eq!(steps[0].argv, ["rm", "-f", "out"]);
}

/// An opened tab: its connection, folder, argv and environment.
type Open = (u64, String, Vec<String>, Vec<(String, String)>);

/// Terminals that record what they open and end each with the next of EXITS, the tab's text TEXT.
struct Tabs {
    opened: std::sync::Mutex<Vec<Open>>,
    exits: std::sync::Mutex<Vec<Option<i32>>>,
    text: String,
}

impl super::Terminals for Tabs {
    fn open(
        &self,
        conn: u64,
        cwd: String,
        args: Vec<String>,
        env: Vec<(String, String)>,
    ) -> super::BoxFut<'_, Result<super::Opened, String>> {
        let mut o = self.opened.lock().unwrap();
        o.push((conn, cwd, args, env));
        let n = o.len();
        Box::pin(async move {
            Ok(super::Opened {
                term: format!("t{n}"),
                view: format!("term:t{n}"),
                pid: 1,
                editor: None,
            })
        })
    }

    fn run_task(&self, term: String) -> super::BoxFut<'_, (Option<i32>, String)> {
        let code = self.exits.lock().unwrap().remove(0);
        let text = if code == Some(0) {
            String::new()
        } else {
            format!("{term}: {}", self.text)
        };
        Box::pin(async move { (code, text) })
    }
}

#[tokio::test]
async fn in_a_tab_each_step_runs_wrapped_and_a_failure_says_its_status_and_text() {
    let d = tempfile::tempdir().unwrap();
    let tabs = Tabs {
        opened: Default::default(),
        exits: std::sync::Mutex::new(vec![Some(0), Some(2)]),
        text: "error: no rule\nEnter closes this tab.".into(),
    };
    let steps = vec![
        step("gen", "echo gen", d.path()),
        step("make", "make", d.path()),
        step("after", "echo after", d.path()),
    ];
    let shown = std::sync::Mutex::new(vec![]);
    let e = tasks::run_in(&steps, &tabs, 7, &|s, o| {
        shown
            .lock()
            .unwrap()
            .push((s.label.clone(), o.term.clone()))
    })
    .await
    .unwrap_err();
    assert_eq!(
        *shown.lock().unwrap(),
        [
            ("gen".to_owned(), "t1".to_owned()),
            ("make".into(), "t2".into())
        ],
        "each tab shown as it opens"
    );
    assert!(
        e.contains("task make failed (exit 2)") && e.contains("t2: error: no rule"),
        "{e}"
    );
    assert!(
        !e.contains("Enter closes"),
        "the tab's own line is not the task's: {e}"
    );
    let opened = tabs.opened.lock().unwrap();
    assert_eq!(opened.len(), 2, "the first failure stops the rest");
    let (conn, cwd, args, env) = &opened[0];
    assert_eq!(*conn, 7);
    assert_eq!(cwd, &d.path().to_string_lossy());
    assert_eq!(
        &args[..2],
        ["/bin/sh", "-c"],
        "the step runs in the tab's wrapper"
    );
    assert_eq!(
        &args[3..],
        ["drgnx-task", "/bin/sh", "-c", "echo gen"],
        "its argv as is"
    );
    assert_eq!(env, &[("DRGNX_TASK_TEST".to_owned(), "1".to_owned())]);
    // the wrapper marks the end with the status (OSC 133 D) and keeps a failed tab open
    assert!(
        args[2].contains("133;D;%d") && args[2].contains("read"),
        "{}",
        args[2]
    );
}

#[tokio::test]
async fn a_tab_that_goes_without_a_status_fails_the_start() {
    let d = tempfile::tempdir().unwrap();
    let tabs = Tabs {
        opened: Default::default(),
        exits: std::sync::Mutex::new(vec![None]),
        text: String::new(),
    };
    let e = tasks::run_in(&[step("b", "true", d.path())], &tabs, 1, &|_, _| {})
        .await
        .unwrap_err();
    assert!(e.contains("task b") && e.contains("closed"), "{e}");
}
