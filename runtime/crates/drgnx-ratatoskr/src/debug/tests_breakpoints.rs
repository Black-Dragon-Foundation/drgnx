//! The breakpoint store, without sessions: operations by id, what the adapters made of them, persistence.

use super::breakpoints::{Change, Col, DataBp, Op, Store, chars_of, col_of, fit};
use serde_json::{Value, json};

fn add(path: &str, line: u32) -> Op {
    Op::Add {
        path: path.into(),
        line,
        column: None,
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
    s.apply(Op::Move {
        id: 1,
        line: 9,
        column: None,
    });
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
        column: None,
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

#[tokio::test]
async fn the_store_survives_the_hub_and_writes_atomically() {
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
        s.disk().unwrap().written().await;
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

#[tokio::test]
async fn a_damaged_file_starts_empty_and_is_kept_aside() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("bps.json");
    std::fs::write(&file, "{not json").unwrap();
    let mut s = Store::open(Some(file.clone()));
    assert!(s.paths().is_empty());
    assert!(dir.path().join("bps.json.damaged").exists());
    s.apply(add("/p/a.py", 1));
    s.disk().unwrap().written().await;
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

#[test]
fn a_triggered_breakpoint_waits_for_its_trigger_in_each_session() {
    let mut s = Store::open(None);
    let a = s.apply(add("/p/a.py", 2)).unwrap().id.unwrap();
    let b = s.apply(add("/p/a.py", 4)).unwrap().id.unwrap();
    let c = s.apply(add("/p/b.py", 7)).unwrap().id.unwrap();
    assert!(s.apply(Op::Trigger { id: b, by: Some(a) }).is_some());
    assert!(s.apply(Op::Trigger { id: c, by: Some(a) }).is_some());
    // not by itself, nor by a breakpoint that is not there
    assert!(s.apply(Op::Trigger { id: a, by: Some(a) }).is_none());
    assert!(
        s.apply(Op::Trigger {
            id: a,
            by: Some(99)
        })
        .is_none()
    );
    assert_eq!(s.send_list("d1", "/p/a.py"), vec![json!({"line": 2})]);
    assert!(s.send_list("d1", "/p/b.py").is_empty());
    assert_eq!(bp(&s, "/p/a.py", b)["triggered_by"], a);
    assert_eq!(bp(&s, "/p/a.py", b)["waiting"], true);
    assert_eq!(bp(&s, "/p/a.py", a)["waiting"], false);
    // d1's adapter knows A as its breakpoint 11, and d1 stops on it
    s.answer("d1", "/p/a.py", &[json!({"id": 11, "verified": true})]);
    let mut paths = s.hit("d1", &[11]);
    paths.sort();
    assert_eq!(paths, ["/p/a.py", "/p/b.py"]);
    assert_eq!(
        s.send_list("d1", "/p/a.py"),
        vec![json!({"line": 2}), json!({"line": 4})]
    );
    assert_eq!(s.send_list("d1", "/p/b.py"), vec![json!({"line": 7})]);
    assert_eq!(bp(&s, "/p/a.py", b)["waiting"], false);
    // another session still waits for its own stop there
    assert_eq!(s.send_list("d2", "/p/a.py"), vec![json!({"line": 2})]);
    assert!(s.hit("d1", &[11]).is_empty(), "armed once");
    assert!(
        s.hit("d1", &[42]).is_empty(),
        "not a breakpoint of the store"
    );
    // the session ends: the next one waits again
    s.ended("d1");
    assert_eq!(s.send_list("d1", "/p/a.py"), vec![json!({"line": 2})]);
    // cleared: a plain breakpoint again
    assert!(s.apply(Op::Trigger { id: b, by: None }).is_some());
    assert_eq!(
        s.send_list("d3", "/p/a.py"),
        vec![json!({"line": 2}), json!({"line": 4})]
    );
    // the trigger removed: what it held waits for nothing, and its file is touched to be sent again
    s.drain_touched();
    s.apply(Op::Remove { id: a });
    assert!(bp(&s, "/p/b.py", c).get("triggered_by").is_none());
    assert_eq!(s.send_list("d3", "/p/b.py"), vec![json!({"line": 7})]);
    let mut touched = s.drain_touched();
    touched.sort();
    assert_eq!(touched, ["/p/a.py", "/p/b.py"]);
}

#[test]
fn data_breakpoints_are_one_sessions_and_go_with_it() {
    let mut s = Store::open(None);
    let x = DataBp {
        data_id: "x1".into(),
        description: "count".into(),
        access_type: None,
    };
    assert!(s.data_add("d1", x.clone()));
    assert!(!s.data_add("d1", x.clone()), "once");
    assert!(s.data_add(
        "d1",
        DataBp {
            data_id: "x2".into(),
            description: "total".into(),
            access_type: Some("readWrite".into()),
        }
    ));
    assert_eq!(
        s.data_list("d1"),
        vec![
            json!({"dataId": "x1"}),
            json!({"dataId": "x2", "accessType": "readWrite"})
        ]
    );
    assert!(s.data_list("d2").is_empty());
    s.data_answer(
        "d1",
        &[
            json!({"verified": true}),
            json!({"verified": false, "message": "no room"}),
        ],
    );
    let shown = s.data_view();
    assert_eq!(shown.len(), 2);
    assert_eq!(
        shown[0],
        (
            "d1".to_owned(),
            json!({"data_id": "x1", "description": "count", "verified": true})
        )
    );
    assert_eq!(shown[1].1["message"], "no room");
    assert_eq!(shown[1].1["access_type"], "readWrite");
    assert!(s.data_remove("d1", "x1"));
    assert!(!s.data_remove("d1", "x1"));
    assert_eq!(s.data_list("d1").len(), 1);
    s.ended("d1");
    assert!(s.data_list("d1").is_empty());
    assert!(s.data_view().is_empty());
}

fn add_at(path: &str, line: u32, chars: u32, utf16: u32) -> Op {
    Op::Add {
        path: path.into(),
        line,
        column: Some(Col { chars, utf16 }),
        enabled: true,
        condition: None,
        hit: None,
        log: None,
    }
}

#[test]
fn breakpoints_at_two_columns_of_one_line_are_two_and_go_out_in_utf16() {
    let mut s = Store::open(None);
    let line = s.apply(add("/p/a.js", 3)).unwrap().id.unwrap();
    let a = s.apply(add_at("/p/a.js", 3, 5, 6)).unwrap().id.unwrap();
    let b = s.apply(add_at("/p/a.js", 3, 12, 13)).unwrap().id.unwrap();
    assert_eq!(ids(&s, "/p/a.js"), vec![line, a, b]);
    // the same column again is the same breakpoint
    assert_eq!(s.apply(add_at("/p/a.js", 3, 5, 6)), None);
    assert_eq!(s.at("/p/a.js", 3, Some(5)), Some(a));
    assert_eq!(s.at("/p/a.js", 3, None), Some(line));
    // the view gives the column in characters, never the adapter's units
    assert_eq!(bp(&s, "/p/a.js", a)["column"], 5);
    assert!(bp(&s, "/p/a.js", a).get("column_utf16").is_none());
    assert!(bp(&s, "/p/a.js", line).get("column").is_none());
    // the adapter gets UTF-16 columns (columnsStartAt1), the line breakpoint none
    assert_eq!(
        s.send_list("s1", "/p/a.js"),
        vec![
            json!({"line": 3}),
            json!({"line": 3, "column": 6}),
            json!({"line": 3, "column": 13})
        ]
    );
}

#[test]
fn a_move_keeps_the_column_unless_it_gives_one() {
    let mut s = Store::open(None);
    let a = s.apply(add_at("/p/a.js", 3, 5, 5)).unwrap().id.unwrap();
    assert!(
        s.apply(Op::Move {
            id: a,
            line: 4,
            column: None
        })
        .is_some()
    );
    assert_eq!(
        (
            bp(&s, "/p/a.js", a)["line"].clone(),
            bp(&s, "/p/a.js", a)["column"].clone()
        ),
        (json!(4), json!(5))
    );
    assert!(
        s.apply(Op::Move {
            id: a,
            line: 4,
            column: Some(Col {
                chars: 9,
                utf16: 10
            })
        })
        .is_some()
    );
    assert_eq!(bp(&s, "/p/a.js", a)["column"], 9);
    assert_eq!(
        s.send_list("s1", "/p/a.js"),
        vec![json!({"line": 4, "column": 10})]
    );
}

#[test]
fn columns_turn_between_characters_and_utf16_units() {
    // U+1D465 is two UTF-16 units, é one
    let text = "\u{1D465}é = f(y)";
    assert_eq!(col_of(Some(text), 1), Col { chars: 1, utf16: 1 });
    assert_eq!(col_of(Some(text), 2), Col { chars: 2, utf16: 3 });
    assert_eq!(col_of(Some(text), 5), Col { chars: 5, utf16: 6 });
    // past the line's end (or no text) each character counts one unit
    assert_eq!(
        col_of(Some(text), 12),
        Col {
            chars: 12,
            utf16: 13
        }
    );
    assert_eq!(col_of(None, 7), Col { chars: 7, utf16: 7 });
    assert_eq!(chars_of(Some(text), 1), 1);
    assert_eq!(chars_of(Some(text), 3), 2);
    assert_eq!(chars_of(Some(text), 6), 5);
    assert_eq!(chars_of(Some(text), 20), 19);
    assert_eq!(chars_of(None, 4), 4);
}

/// A save that waits on the disk (here a FIFO in place of the temp file, opened by nobody) holds no async worker: the
/// operation answers at once and the file lands once the disk does.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_save_that_waits_on_the_disk_holds_no_worker() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("bps.json");
    let tmp = dir.path().join("bps.json.drgnx-tmp");
    let made = std::process::Command::new("mkfifo")
        .arg(&tmp)
        .status()
        .unwrap();
    assert!(made.success());
    let applied = tokio::spawn(async move {
        let mut s = Store::open(Some(file));
        s.apply(add("/p/a.py", 7)).is_some()
    });
    let answered = crate::clock::timeout(std::time::Duration::from_secs(10), applied).await;
    // the disk answers: the write waiting on the FIFO goes on (and a worker held by it is freed)
    let reader = std::thread::spawn(move || std::fs::read_to_string(&tmp).unwrap_or_default());
    assert!(
        matches!(answered, Ok(Ok(true))),
        "the operation waited for the disk on a worker"
    );
    let written = reader.join().unwrap();
    assert!(written.contains("a.py"), "{written}");
}
