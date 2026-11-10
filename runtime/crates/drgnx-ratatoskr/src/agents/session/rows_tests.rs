use super::*;
use std::collections::BTreeMap;

fn entry(kind: EntryType, rest: Value) -> Entry {
    Entry {
        kind,
        rest: rest.as_object().cloned().unwrap_or_default(),
    }
}

fn tool(rest: Value) -> Entry {
    entry(EntryType::Tool, rest)
}

/// The rows of tool entry E (index 3) under LOOK and FACTS, ALWAYS saying whether a grant covers it.
fn rows_of(e: &Entry, look: &Look, facts: &BTreeMap<u64, Facts>, always: bool) -> Vec<Row> {
    let always = move |_: &Entry| always;
    let right = |_: &str| 300;
    let cx = Cx {
        look,
        facts,
        always: &always,
        right: &right,
    };
    group_rows(3, e, &[], None, &cx)
}

fn keys(rows: &[Row]) -> Vec<&str> {
    rows.iter().map(|r| r.key.as_str()).collect()
}

fn faces(r: &Row) -> Vec<&str> {
    r.runs.iter().map(|(_, _, f)| f.as_str()).collect()
}

fn prop<'a>(r: &'a Row, name: &str) -> Option<&'a Value> {
    r.props.iter().find(|p| p.2 == name).map(|p| &p.3)
}

fn open_edits() -> Look {
    Look {
        open: BTreeSet::from(["edit".to_owned()]),
        ..Look::default()
    }
}

#[test]
fn hunks_split_at_30_lines() {
    let old: String = (0..80).map(|i| format!("line {i}\n")).collect();
    let new: String = (0..80).map(|i| format!("LINE {i}\n")).collect();
    let e = tool(
        json!({"title": "Edit a.el", "kind": "edit", "status": "completed",
                        "content": [{"type": "diff", "path": "a.el", "oldText": old, "newText": new}]}),
    );
    let rows = rows_of(&e, &open_edits(), &BTreeMap::new(), false);
    let hunks: Vec<&Row> = rows
        .iter()
        .filter(|r| r.key.starts_with("e:3/h:"))
        .collect();
    // one hunk of 1 header + 160 lines: six rows of at most 30 lines
    assert_eq!(hunks.len(), 6, "{:?}", keys(&rows));
    for (n, h) in hunks.iter().enumerate() {
        assert!(
            h.text.split('\n').count() <= ROW_LINES,
            "row {n} is too long"
        );
        assert_eq!(h.key, format!("e:3/h:{n}"));
        assert_eq!(
            prop(h, "drgnx-agent-panel-hunk"),
            Some(&json!(["a.el", 0, n]))
        );
    }
    assert!(hunks[0].text.starts_with("    a.el  @@"));
    assert!(faces(hunks[0]).contains(&"drgnx-agent-panel-removed"));
    assert!(faces(hunks[5]).contains(&"drgnx-agent-panel-added"));
}

/// agent-panel.html: the panel's prose is in the UI font, its output and diffs in the code font, so every line of a
/// tool's output and of a hunk names a face (a line with none would take the panel's UI font).
#[test]
fn output_and_hunk_lines_are_code() {
    let small = tool(
        json!({"title": "Run", "kind": "execute", "status": "failed",
                            "content": "Ran 14 tests\n1 unexpected"}),
    );
    let rows = rows_of(&small, &Look::default(), &BTreeMap::new(), false);
    let out: Vec<&Row> = rows.iter().filter(|r| r.key.starts_with("e:3/d")).collect();
    assert!(!out.is_empty(), "{:?}", keys(&rows));
    for r in &out {
        assert_eq!(faces(r), ["drgnx-agent-panel-output"], "{}", r.key);
    }
    let long: String = (0..40).map(|i| format!("line {i}\n")).collect();
    let large =
        tool(json!({"title": "Run", "kind": "execute", "status": "failed", "content": long}));
    let rows = rows_of(&large, &Look::default(), &BTreeMap::new(), false);
    for k in ["e:3/d:0", "e:3/d:2"] {
        let r = rows.iter().find(|r| r.key == k).expect(k);
        assert_eq!(faces(r), ["drgnx-agent-panel-output"], "{k}");
    }
    let e = tool(
        json!({"title": "Edit a.el", "kind": "edit", "status": "completed",
                        "content": [{"type": "diff", "path": "a.el", "oldText": "a\nb\nc\n", "newText": "a\nB\nc\n"}]}),
    );
    let rows = rows_of(&e, &open_edits(), &BTreeMap::new(), false);
    let h = rows
        .iter()
        .find(|r| r.key == "e:3/h:0")
        .expect("a hunk row");
    assert!(
        faces(h).contains(&"drgnx-agent-panel-context"),
        "{:?}",
        faces(h)
    );
}

#[test]
fn summary_is_one_line() {
    let e = tool(
        json!({"title": "Run the tests\nwith every flag", "kind": "execute", "status": "completed",
                        "content": [{"type": "content", "content": {"type": "text", "text": "\n  ok: 12 passed\nmore\n"}}]}),
    );
    let rows = rows_of(&e, &Look::default(), &BTreeMap::new(), false);
    assert_eq!(keys(&rows), ["e:3"], "a closed step is one row");
    let r = &rows[0];
    assert!(!r.text.contains('\n'), "{:?}", r.text);
    assert!(r.text.contains("Run the tests"), "{:?}", r.text);
    assert!(r.text.contains("· ok: 12 passed"), "{:?}", r.text);
    assert_eq!(prop(r, "drgnx-agent-panel-entry"), Some(&json!(3)));
    assert_eq!(one_line(&"x".repeat(100), 10).chars().count(), 10);
}

fn stepped(status: &str) -> Entry {
    tool(json!({"title": "Edit a.el", "kind": "edit", "status": status, "step": 7}))
}

#[test]
fn undone_steps_are_marked() {
    let facts = BTreeMap::from([(
        7,
        Facts {
            undone: true,
            ..Facts::default()
        },
    )]);
    let rows = rows_of(&stepped("completed"), &Look::default(), &facts, false);
    assert!(rows[0].text.contains("↶ undone"), "{:?}", rows[0].text);
    let rows = rows_of(
        &stepped("completed"),
        &Look::default(),
        &BTreeMap::new(),
        false,
    );
    assert!(!rows[0].text.contains("undone"));
}

#[test]
fn checkpoint_rows_carry_their_mark() {
    let facts = BTreeMap::from([(
        7,
        Facts {
            start: Some(10.0),
            end: Some(25.0),
            cost: Some(0.75),
            revertible: true,
            ..Facts::default()
        },
    )]);
    let rows = rows_of(&stepped("completed"), &Look::default(), &facts, false);
    let r = &rows[0];
    assert_eq!(prop(r, "drgnx-agent-panel-checkpoint"), Some(&json!(7)));
    // a slow, dear step: its time and cost right-aligned, both in the warning face
    assert!(r.text.ends_with("15.0 s · $0.75"), "{:?}", r.text);
    assert_eq!(r.stops.len(), 1);
    assert_eq!(r.stops[0].1, 300);
    assert_eq!(
        faces(r)
            .iter()
            .filter(|f| **f == "drgnx-agent-panel-warn")
            .count(),
        2
    );
    let plain = BTreeMap::from([(7, Facts::default())]);
    assert_eq!(
        prop(
            &rows_of(&stepped("completed"), &Look::default(), &plain, false)[0],
            "drgnx-agent-panel-checkpoint"
        ),
        None
    );
}

#[test]
fn paired_chat_hunks_are_rows() {
    let e = tool(
        json!({"title": "edit_file", "kind": "edit", "status": "completed",
                        "rawInput": {"path": "src/x.rs", "old": "a\nb\nc\n", "new": "a\nB\nc\n"}}),
    );
    let rows = rows_of(&e, &open_edits(), &BTreeMap::new(), false);
    assert_eq!(keys(&rows), ["e:3", "e:3/h:0"]);
    let h = &rows[1];
    assert_eq!(
        h.text,
        "    src/x.rs  @@ -1,3 +1,3 @@\n     a\n    -b\n    +B\n     c"
    );
    assert_eq!(
        prop(h, "drgnx-agent-panel-hunk"),
        Some(&json!(["src/x.rs", 0, 0]))
    );
    // folded, the edit is its summary alone
    assert_eq!(
        keys(&rows_of(&e, &Look::default(), &BTreeMap::new(), false)),
        ["e:3"]
    );
}

#[test]
fn rows_carry_provenance_lines() {
    let hooks = vec![
        json!({"outcome": "deny", "records": [
            {"source": "plugin:guard@1.2#abc", "verdict": "deny", "reason": "no writes"},
            {"source": "rule:7", "verdict": "allow"}]}),
        json!({"outcome": "at-server"}),
        json!({"outcome": "error", "records": [{"source": "rule:9", "verdict": "error", "reason": "busy now"}]}),
    ];
    let facts = BTreeMap::from([(
        7,
        Facts {
            hooks,
            ..Facts::default()
        },
    )]);
    let rows = rows_of(&stepped("failed"), &Look::default(), &facts, true);
    let under: Vec<&Row> = rows
        .iter()
        .filter(|r| r.key.starts_with("e:3/p:"))
        .collect();
    let texts: Vec<&str> = under.iter().map(|r| r.text.as_str()).collect();
    assert_eq!(
        texts,
        [
            "    refused by guard 1.2 · \"no writes\"",
            "    hooked at the hub's server",
            "    rule 9 was busy: its hook did not run · \"busy now\"",
            "    allowed by your Always · V revokes",
        ]
    );
    assert_eq!(
        prop(under[0], "drgnx-agent-panel-hook"),
        Some(&json!([7, 0, 0]))
    );
    assert_eq!(
        prop(under[2], "drgnx-agent-panel-hook"),
        Some(&json!([7, 2, 0]))
    );
    assert_eq!(prop(under[3], "drgnx-agent-panel-hook"), None);
    assert_eq!(faces(under[0]), ["drgnx-agents-hooks-refused"]);
    assert_eq!(faces(under[2]), ["drgnx-agents-hooks-busy"]);
}

#[test]
fn rows_indent_subagent_steps() {
    let facts = BTreeMap::from([(
        7,
        Facts {
            parent_tool: Some("toolu_task".into()),
            ..Facts::default()
        },
    )]);
    let child = rows_of(&stepped("completed"), &Look::default(), &facts, false);
    let top = rows_of(
        &stepped("completed"),
        &Look::default(),
        &BTreeMap::new(),
        false,
    );
    assert!(child[0].text.starts_with("      ●"), "{:?}", child[0].text);
    assert!(top[0].text.starts_with("  ●"), "{:?}", top[0].text);
    let face = faces(&child[0])
        .into_iter()
        .find(|f| f.starts_with("drgnx-agent-") && !f.contains("panel"));
    let n: u64 = face.expect("a subagent face")["drgnx-agent-".len()..]
        .parse()
        .expect("a number");
    assert!((1..=6).contains(&n));
    // the same Task call always gets the same colour
    let again = rows_of(&stepped("failed"), &Look::default(), &facts, false);
    assert!(faces(&again[0]).contains(&face.unwrap()));
}

#[test]
fn huddle_threads_are_rows() {
    let rec = json!({"id": "h1", "state": "open", "clash": "src/x.rs", "participants": ["s1", "s2"],
                     "replies": [{"from": "s2", "text": "I keep mine\nbecause", "proposal": "merge both"},
                                 {"from": "s1", "text": "fine"}],
                     "proposal": "merge both"});
    let rows = huddle_rows(&rec);
    assert_eq!(keys(&rows), ["h", "r:0", "r:1", "o"]);
    assert_eq!(rows[0].text, " Huddle · open · about src/x.rs\n  s1 ⇄ s2");
    assert_eq!(
        rows[1].text,
        "\n  s2 says\n  ▎ I keep mine\n  ▎ because\n  → proposes: merge both"
    );
    assert!(faces(&rows[1]).contains(&"drgnx-agent-2"));
    assert!(faces(&rows[2]).contains(&"drgnx-agent-1"));
    assert_eq!(rows[3].text, "\n  Agreed proposal: merge both");
    let ended = json!({"state": "done", "participants": ["s1", "s2"], "outcome": "s1 yields"});
    let rows = huddle_rows(&ended);
    assert_eq!(keys(&rows), ["h", "o"]);
    assert_eq!(rows[1].text, "\n  Outcome: s1 yields");
}

#[test]
fn thoughts_fold_under_the_tool_before_them() {
    let es = [
        tool(json!({"title": "Read"})),
        entry(EntryType::Thought, json!({"text": "a"})),
        entry(EntryType::Thought, json!({"text": "b"})),
        entry(EntryType::Agent, json!({"text": "ok"})),
        entry(EntryType::Thought, json!({"text": "c"})),
    ];
    let tail: Vec<(usize, &Entry)> = es.iter().enumerate().collect();
    assert_eq!(groups(&tail), [(0, vec![1, 2]), (3, vec![]), (4, vec![])]);
}
