//! launch.json: JSONC, the picker's order, platform sections, `${…}` variables in two passes, inputs and the process
//! picker as `needs`, and `debugServer` to this machine only.
use super::launch::{self, Need, Os, Vars};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;

const FILE: &str = r#"{
  // VS Code's own comment style
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Run app",
      "type": "debugpy",
      "request": "launch",
      "program": "${file}",
      "args": ["--name", "${input:who}", "a b"],
      "presentation": {"order": 2},
      "linux": {"env": {"ONLY_LINUX": "1"}},
      "osx": {"env": {"ONLY_MAC": "1"}},
      "env": {"BASE": "1"},
    },
    {"name": "Hidden helper", "type": "debugpy", "request": "launch", "presentation": {"hidden": true}},
    {"name": "Attach", "type": "debugpy", "request": "attach", "processId": "${command:pickProcess}",
     "presentation": {"order": 1}},
    /* a block comment */
    {"name": "No order", "type": "go", "request": "launch"},
  ],
  "inputs": [
    {"id": "who", "type": "promptString", "description": "Name?", "default": "world"},
    {"id": "mode", "type": "pickString", "description": "Mode", "options": ["fast", "slow"], "default": "fast"},
  ],
}"#;

fn vars(dir: &std::path::Path) -> Vars {
    Vars {
        roots: vec![("app".into(), dir.to_path_buf())],
        file: Some(dir.join("src/main.py")),
        line: Some(12),
        col: Some(4),
        selection: Some("total".into()),
        home: PathBuf::from("/home/u"),
        exec_path: PathBuf::from("/usr/bin/nidhogg"),
        default_build_task: Some("cargo build".into()),
        env: HashMap::from([("GREETING".to_owned(), "hi".to_owned())]),
        config: HashMap::from([(
            "debug-python-interpreter".to_owned(),
            json!("/usr/bin/python3.15"),
        )]),
    }
}

fn tmp() -> tempfile::TempDir {
    let d = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(d.path().join("src")).unwrap();
    std::fs::write(d.path().join("src/main.py"), "").unwrap();
    d
}

#[test]
fn jsonc_with_comments_and_trailing_commas_is_read() {
    let f = launch::parse(FILE).unwrap();
    assert_eq!(f.configs.len(), 4);
    assert_eq!(f.inputs.len(), 2);
}

#[test]
fn a_syntax_error_names_its_line_and_column() {
    let e = launch::parse("{\n  \"configurations\": [\n    {\"name\": }\n  ]\n}").unwrap_err();
    assert_eq!((e.line, e.col), (3, 14), "{e:?}");
    assert!(!e.message.is_empty());
}

#[test]
fn a_file_without_configurations_is_an_empty_list() {
    assert!(
        launch::parse("{\"version\": \"0.2.0\"}")
            .unwrap()
            .configs
            .is_empty()
    );
    assert!(launch::parse("[]").is_err(), "the top must be an object");
}

#[test]
fn the_picker_takes_order_then_file_order_and_leaves_hidden_ones_out() {
    let f = launch::parse(FILE).unwrap();
    let names: Vec<&str> = launch::listed(&f.configs)
        .into_iter()
        .map(|i| f.configs[i]["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["Attach", "Run app", "No order"]);
}

#[test]
fn the_platform_section_is_merged_over_the_base_and_removed() {
    let f = launch::parse(FILE).unwrap();
    let c = launch::for_platform(&f.configs[0], Os::Linux);
    assert_eq!(c["env"], json!({"BASE": "1", "ONLY_LINUX": "1"}));
    assert!(c.get("linux").is_none() && c.get("osx").is_none());
    let m = launch::for_platform(&f.configs[0], Os::Macos);
    assert_eq!(m["env"], json!({"BASE": "1", "ONLY_MAC": "1"}));
}

#[test]
fn every_predefined_variable() {
    let d = tmp();
    let root = d.path().canonicalize().unwrap();
    let r = root.display().to_string();
    let c = json!({
        "a": "${workspaceFolder}", "b": "${workspaceFolderBasename}", "c": "${file}", "d": "${fileWorkspaceFolder}",
        "e": "${relativeFile}", "f": "${relativeFileDirname}", "g": "${fileBasename}",
        "h": "${fileBasenameNoExtension}", "i": "${fileExtname}", "j": "${fileDirname}", "k": "${fileDirnameBasename}",
        "l": "${cwd}", "m": "${lineNumber}", "n": "${columnNumber}", "o": "${selectedText}", "p": "${execPath}",
        "q": "${pathSeparator}", "r": "${/}", "s": "${userHome}", "t": "${defaultBuildTask}",
        "u": "${workspaceFolder:app}", "v": "${env:GREETING}", "w": "${env:NOT_SET}",
        "x": "${config:debug-python-interpreter}", "y": "${config:python.defaultInterpreterPath}",
        "z": "${workspaceRoot}"
    });
    let out = launch::substitute(&c, &vars(d.path()), &HashMap::new()).unwrap();
    let base = d.path().file_name().unwrap().to_str().unwrap();
    let want = json!({
        "a": r, "b": base, "c": format!("{r}/src/main.py"), "d": r, "e": "src/main.py", "f": "src",
        "g": "main.py", "h": "main", "i": ".py", "j": format!("{r}/src"), "k": "src",
        "l": r, "m": "12", "n": "4", "o": "total", "p": "/usr/bin/nidhogg",
        "q": "/", "r": "/", "s": "/home/u", "t": "cargo build",
        "u": r, "v": "hi", "w": "",
        "x": "/usr/bin/python3.15", "y": "/usr/bin/python3.15",
        "z": r
    });
    for (k, v) in want.as_object().unwrap() {
        assert_eq!(&out[k], v, "{k}");
    }
}

#[test]
fn paths_are_given_by_their_true_names() {
    let d = tmp();
    let link = d
        .path()
        .parent()
        .unwrap()
        .join(format!("link-{}", std::process::id()));
    let _ = std::fs::remove_file(&link);
    std::os::unix::fs::symlink(d.path(), &link).unwrap();
    let mut v = vars(&link);
    v.file = Some(link.join("src/main.py"));
    let out = launch::substitute(
        &json!({"p": "${file}", "w": "${workspaceFolder}"}),
        &v,
        &HashMap::new(),
    )
    .unwrap();
    std::fs::remove_file(&link).unwrap();
    let real = d.path().canonicalize().unwrap();
    assert_eq!(out["w"], json!(real.display().to_string()));
    assert_eq!(
        out["p"],
        json!(real.join("src/main.py").display().to_string())
    );
}

#[test]
fn an_unknown_variable_or_setting_is_an_error_that_names_it() {
    let d = tmp();
    let e =
        launch::substitute(&json!({"a": "${nope}"}), &vars(d.path()), &HashMap::new()).unwrap_err();
    assert!(e.contains("${nope}"), "{e}");
    let e = launch::substitute(
        &json!({"a": "${config:editor.fontSize}"}),
        &vars(d.path()),
        &HashMap::new(),
    )
    .unwrap_err();
    assert!(e.contains("editor.fontSize"), "{e}");
    let e = launch::substitute(
        &json!({"a": "${workspaceFolder:other}"}),
        &vars(d.path()),
        &HashMap::new(),
    )
    .unwrap_err();
    assert!(e.contains("other"), "{e}");
}

#[test]
fn inputs_and_the_process_picker_are_asked_for_first() {
    let f = launch::parse(FILE).unwrap();
    let n = launch::needs(&f.configs[0], &f.inputs, &HashMap::new()).unwrap();
    assert_eq!(
        n,
        [Need::Input {
            id: "who".into(),
            kind: "promptString".into(),
            description: "Name?".into(),
            default: Some("world".into()),
            options: vec![],
            password: false,
        }]
    );
    let n = launch::needs(&f.configs[2], &f.inputs, &HashMap::new()).unwrap();
    assert_eq!(n, [Need::PickProcess]);
    let answers = HashMap::from([("pickProcess".to_owned(), "4242".to_owned())]);
    assert!(
        launch::needs(&f.configs[2], &f.inputs, &answers)
            .unwrap()
            .is_empty()
    );
    let e = launch::needs(
        &json!({"a": "${input:missing}"}),
        &f.inputs,
        &HashMap::new(),
    )
    .unwrap_err();
    assert!(e.contains("missing"), "{e}");
}

#[test]
fn an_answer_is_taken_as_it_is_never_substituted_again_and_args_are_never_split() {
    let d = tmp();
    let f = launch::parse(FILE).unwrap();
    let c = launch::for_platform(&f.configs[0], Os::Linux);
    let answers = HashMap::from([("who".to_owned(), "${file} and more".to_owned())]);
    let out = launch::substitute(&c, &vars(d.path()), &answers).unwrap();
    assert_eq!(out["args"], json!(["--name", "${file} and more", "a b"]));
}

#[test]
fn a_pick_string_answer_must_be_one_of_its_options() {
    let f = launch::parse(FILE).unwrap();
    let c = json!({"m": "${input:mode}"});
    let bad = HashMap::from([("mode".to_owned(), "medium".to_owned())]);
    assert!(
        launch::check_answers(&c, &f.inputs, &bad)
            .unwrap_err()
            .contains("medium")
    );
    let good = HashMap::from([("mode".to_owned(), "slow".to_owned())]);
    launch::check_answers(&c, &f.inputs, &good).unwrap();
}

#[test]
fn a_debug_server_is_this_machine_only() {
    assert_eq!(launch::debug_server(&json!({})).unwrap(), None);
    assert_eq!(
        launch::debug_server(&json!({"debugServer": 4711}))
            .unwrap()
            .unwrap()
            .to_string(),
        "127.0.0.1:4711"
    );
    assert_eq!(
        launch::debug_server(&json!({"debugServer": "localhost:4711"}))
            .unwrap()
            .unwrap()
            .to_string(),
        "127.0.0.1:4711"
    );
    assert!(
        launch::debug_server(&json!({"debugServer": "10.0.0.2:4711"}))
            .unwrap_err()
            .contains("10.0.0.2")
    );
    assert!(launch::debug_server(&json!({"debugServer": 0})).is_err());
}

#[test]
fn the_fields_drgnx_reads_are_left_out_of_the_adapters_arguments() {
    let c = json!({"name": "x", "type": "debugpy", "request": "launch", "presentation": {}, "preLaunchTask": "b",
                   "postDebugTask": "c", "debugServer": 1, "internalConsoleOptions": "neverOpen",
                   "serverReadyAction": {}, "program": "p", "noDebug": false});
    let a = launch::adapter_arguments(&c);
    let mut keys: Vec<&str> = a.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(keys, ["name", "noDebug", "program", "request", "type"]);
}

#[test]
fn values_that_are_not_strings_pass_unchanged() {
    let d = tmp();
    let c = json!({"n": 3, "b": true, "o": {"deep": ["${lineNumber}", 1, null]}});
    let out = launch::substitute(&c, &vars(d.path()), &HashMap::new()).unwrap();
    assert_eq!(
        out,
        json!({"n": 3, "b": true, "o": {"deep": ["12", 1, null]}})
    );
}

#[test]
fn file_variables_without_a_file_are_an_error() {
    let d = tmp();
    let mut v = vars(d.path());
    v.file = None;
    let e = launch::substitute(&json!({"a": "${file}"}), &v, &HashMap::new()).unwrap_err();
    assert!(e.contains("file"), "{e}");
    let _ = Value::Null;
}
