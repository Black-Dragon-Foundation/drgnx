//! The breakpoint store, without sessions: operations by id, what the adapters made of them, persistence.

use super::breakpoints::{Change, Op, Store, fit};
use serde_json::{Value, json};

fn add(path: &str, line: u32) -> Op {
    Op::Add {
        path: path.into(),
        line,
        enabled: true,
        condition: None,
        hit: None,
        log: None,
    }
}

fn ids(s: &Store, path: &str) -> Vec<u64> {
    s.view(path)["breakpoints"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| b["id"].as_u64().unwrap())
        .collect()
}

fn bp(s: &Store, path: &str, id: u64) -> Value {
    s.view(path)["breakpoints"]
        .as_array()
        .unwrap()
        .iter()
        .find(|b| b["id"] == id)
        .cloned()
        .unwrap()
}

#[test]
fn two_editors_toggling_one_file_never_undo_each_other() {
    let mut s = Store::open(None);
    let a = s.apply(add("/p/a.py", 5)).unwrap();
    assert_eq!(
        a,
        Change {
            path: "/p/a.py".into(),
            version: 1,
            id: Some(1)
        }
    );
    // the second editor adds the same line: the same breakpoint, nothing changes
    assert_eq!(s.apply(add("/p/a.py", 5)), None);
    assert_eq!(ids(&s, "/p/a.py"), vec![1]);
    // both remove it: the second removal is no change, not an error, and adds nothing back
    assert!(s.apply(Op::Remove { id: 1 }).is_some());
    assert_eq!(s.apply(Op::Remove { id: 1 }), None);
    assert!(ids(&s, "/p/a.py").is_empty());
    assert_eq!(s.version("/p/a.py"), 2);
    // an edit of a breakpoint another editor removed is no change either
    assert_eq!(
        s.apply(Op::Edit {
            id: 1,
            enabled: Some(false),
            condition: None,
            hit: None,
            log: None
        }),
        None
    );
}

#[test]
fn edits_by_id_and_empty_clears() {
    let mut s = Store::open(None);
    s.apply(add("/p/a.py", 5));
    let c = s
        .apply(Op::Edit {
            id: 1,
            enabled: Some(false),
            condition: Some("x > 1".into()),
            hit: Some("3".into()),
            log: Some("x is {x}".into()),
        })
        .unwrap();
    assert_eq!(c.version, 2);
    let b = bp(&s, "/p/a.py", 1);
    assert_eq!(b["enabled"], false);
    assert_eq!(b["condition"], "x > 1");
    assert_eq!(b["hit"], "3");
    assert_eq!(b["log"], "x is {x}");
    s.apply(Op::Edit {
        id: 1,
        enabled: None,
        condition: Some(String::new()),
        hit: None,
        log: None,
    });
    let b = bp(&s, "/p/a.py", 1);
    assert!(b.get("condition").is_none_or(Value::is_null));
    assert_eq!(b["hit"], "3");
}

#[test]
fn a_move_holds_the_saved_line() {
    let mut s = Store::open(None);
    s.apply(add("/p/a.py", 5));
    s.apply(Op::Move { id: 1, line: 9 });
    assert_eq!(bp(&s, "/p/a.py", 1)["line"], 9);
    // the editor's toggle on the saved line finds it
    assert_eq!(s.apply(add("/p/a.py", 9)), None);
}

#[test]
fn only_enabled_breakpoints_are_sent_in_line_order() {
    let mut s = Store::open(None);
    s.apply(add("/p/a.py", 9));
    s.apply(add("/p/a.py", 3));
    s.apply(add("/p/a.py", 6));
    s.apply(Op::Edit {
        id: 3,
        enabled: Some(false),
        condition: None,
        hit: None,
        log: None,
    });
    let sent = s.send_list("d1", "/p/a.py");
    assert_eq!(sent, vec![json!({"line": 3}), json!({"line": 9})]);
}

#[test]
fn verified_if_any_session_verified_and_the_adapter_moved_line() {
    let mut s = Store::open(None);
    s.apply(add("/p/a.py", 5));
    s.send_list("d1", "/p/a.py");
    s.send_list("d2", "/p/a.py");
    s.answer(
        "d1",
        "/p/a.py",
        &[json!({"id": 7, "verified": false, "message": "no code"})],
    );
    let b = bp(&s, "/p/a.py", 1);
    assert_eq!(b["verified"], false);
    assert_eq!(b["message"], "no code");
    s.answer(
        "d2",
        "/p/a.py",
        &[json!({"id": 3, "verified": true, "line": 6})],
    );
    let b = bp(&s, "/p/a.py", 1);
    assert_eq!(b["verified"], true);
    assert_eq!(b["bound_line"], 6);
    // a breakpoint event by the adapter's id, in the session it came from
    let changed = s.event(
        "d1",
        &json!({"reason": "changed", "breakpoint": {"id": 7, "verified": true, "line": 8}}),
    );
    assert_eq!(changed.as_deref(), Some("/p/a.py"));
    assert_eq!(bp(&s, "/p/a.py", 1)["verified"], true);
    assert_eq!(
        s.event(
            "d1",
            &json!({"reason": "changed", "breakpoint": {"id": 99}})
        ),
        None
    );
    // the sessions end: nothing verifies it any more
    s.ended("d1");
    s.ended("d2");
    assert_eq!(bp(&s, "/p/a.py", 1)["verified"], false);
}

#[test]
fn conditions_hits_and_logs_go_only_to_adapters_that_take_them() {
    let all = vec![json!({"line": 3, "condition": "x", "hitCondition": "2", "logMessage": "m"})];
    assert_eq!(fit(&all, &json!({})), vec![json!({"line": 3})]);
    assert_eq!(
        fit(
            &all,
            &json!({"supportsConditionalBreakpoints": true, "supportsLogPoints": true})
        ),
        vec![json!({"line": 3, "condition": "x", "logMessage": "m"})]
    );
    let mut s = Store::open(None);
    s.apply(Op::Add {
        path: "/p/a.py".into(),
        line: 3,
        enabled: true,
        condition: Some("x".into()),
        hit: None,
        log: Some("m".into()),
    });
    s.set_caps("d1", json!({"supportsLogPoints": true}));
    s.send_list("d1", "/p/a.py");
    assert_eq!(bp(&s, "/p/a.py", 1)["unsupported"], json!(["condition"]));
    // kept in the store all the same
    assert_eq!(bp(&s, "/p/a.py", 1)["condition"], "x");
}

#[test]
fn run_to_cursor_is_one_sessions_until_its_next_stop() {
    let mut s = Store::open(None);
    s.apply(add("/p/a.py", 3));
    assert_eq!(s.add_temp("d1", "/p/a.py", 12), "/p/a.py");
    assert_eq!(
        s.send_list("d1", "/p/a.py"),
        vec![json!({"line": 3}), json!({"line": 12})]
    );
    assert_eq!(s.send_list("d2", "/p/a.py"), vec![json!({"line": 3})]);
    // never shown as the user's breakpoint
    assert_eq!(ids(&s, "/p/a.py").len(), 1);
    assert_eq!(s.stopped("d1"), vec!["/p/a.py".to_owned()]);
    assert_eq!(s.send_list("d1", "/p/a.py"), vec![json!({"line": 3})]);
    assert!(s.stopped("d1").is_empty());
    s.add_temp("d1", "/p/b.py", 4);
    assert_eq!(s.ended("d1"), vec!["/p/b.py".to_owned()]);
    assert!(s.send_list("d1", "/p/b.py").is_empty());
}

#[test]
fn the_store_survives_the_hub_and_writes_atomically() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("bps.json");
    {
        let mut s = Store::open(Some(file.clone()));
        s.apply(add("/p/a.py", 5));
        s.apply(Op::Edit {
            id: 1,
            enabled: None,
            condition: Some("x".into()),
            hit: None,
            log: None,
        });
        s.add_temp("d1", "/p/a.py", 8);
        s.apply(Op::AddFunction {
            name: "main".into(),
            condition: None,
        });
        s.set_filters("debugpy", vec!["raised".into()]);
    }
    let names: Vec<_> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(names, vec![std::ffi::OsString::from("bps.json")]);
    let mut s = Store::open(Some(file));
    assert_eq!(bp(&s, "/p/a.py", 1)["condition"], "x");
    assert_eq!(
        s.send_list("d1", "/p/a.py"),
        vec![json!({"line": 5, "condition": "x"})]
    );
    assert_eq!(s.functions(), vec![json!({"name": "main"})]);
    assert_eq!(s.filters("debugpy", &json!({})), vec!["raised".to_owned()]);
    // ids go on from where they were
    assert_eq!(s.apply(add("/p/a.py", 6)).unwrap().id, Some(2));
}

#[test]
fn a_damaged_file_starts_empty_and_is_kept_aside() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("bps.json");
    std::fs::write(&file, "{not json").unwrap();
    let mut s = Store::open(Some(file.clone()));
    assert!(s.paths().is_empty());
    assert!(dir.path().join("bps.json.damaged").exists());
    s.apply(add("/p/a.py", 1));
    assert!(std::fs::read_to_string(&file).unwrap().contains("a.py"));
}

#[test]
fn exception_filters_default_from_the_adapter_and_are_remembered_per_type() {
    let caps = json!({"exceptionBreakpointFilters": [
        {"filter": "raised", "label": "Raised"},
        {"filter": "uncaught", "label": "Uncaught", "default": true}]});
    let mut s = Store::open(None);
    assert_eq!(s.filters("debugpy", &caps), vec!["uncaught".to_owned()]);
    s.set_filters("debugpy", vec![]);
    assert!(s.filters("debugpy", &caps).is_empty());
    assert_eq!(s.filters("go", &caps), vec!["uncaught".to_owned()]);
}

#[test]
fn function_breakpoints_by_name() {
    let mut s = Store::open(None);
    s.apply(Op::AddFunction {
        name: "main".into(),
        condition: Some("n > 2".into()),
    });
    assert_eq!(
        s.apply(Op::AddFunction {
            name: "main".into(),
            condition: Some("n > 2".into())
        }),
        None
    );
    s.apply(Op::AddFunction {
        name: "run".into(),
        condition: None,
    });
    assert_eq!(
        s.functions(),
        vec![
            json!({"name": "main", "condition": "n > 2"}),
            json!({"name": "run"})
        ]
    );
    s.apply(Op::RemoveFunction {
        name: "main".into(),
    });
    assert_eq!(s.functions(), vec![json!({"name": "run"})]);
}
