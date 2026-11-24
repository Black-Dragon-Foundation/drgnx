use super::*;
use rodd::faces::FaceId;
use std::collections::BTreeMap;

static NO_BG: BTreeMap<String, (u64, u64)> = BTreeMap::new();

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
    rows_with(e, look, facts, always, None)
}

/// [`rows_of`] with PROV, the line the hub cached for how the step was allowed.
fn rows_with(
    e: &Entry,
    look: &Look,
    facts: &BTreeMap<u64, Facts>,
    always: bool,
    prov: Option<&str>,
) -> Vec<Row> {
    let always = move |_: &Entry| always;
    let prov = move |_: &Entry| prov.map(str::to_owned);
    let right = |_: &[(&str, &str)]| 300;
    let cx = Cx {
        look,
        facts,
        always: &always,
        prov: &prov,
        right: &right,
        bg: &NO_BG,
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
    assert!(faces(hunks[0]).contains(&FaceId::KitDiffBlockDel.name()));
    assert!(faces(hunks[5]).contains(&FaceId::KitDiffBlockAdd.name()));
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
        assert_eq!(faces(r), [FaceId::AgentPanelOutput.name()], "{}", r.key);
    }
    let long: String = (0..40).map(|i| format!("line {i}\n")).collect();
    let large =
        tool(json!({"title": "Run", "kind": "execute", "status": "failed", "content": long}));
    let rows = rows_of(&large, &Look::default(), &BTreeMap::new(), false);
    for k in ["e:3/d:0", "e:3/d:2"] {
        let r = rows.iter().find(|r| r.key == k).expect(k);
        assert_eq!(faces(r), [FaceId::AgentPanelOutput.name()], "{k}");
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
        faces(h).contains(&FaceId::KitDiffBlockCtx.name()),
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
fn a_steps_time_and_cost_are_measured_in_the_fonts_they_are_drawn_in() {
    // a slow step that cost little: the time in the warning face, the separator and the cost in the code face, each
    // part named by the face it is drawn in (the hub measures it in that face's font, as the editor reports it)
    let facts = BTreeMap::from([(
        7,
        Facts {
            start: Some(10.0),
            end: Some(25.0),
            cost: Some(0.05),
            ..Facts::default()
        },
    )]);
    let seen = std::cell::RefCell::new(Vec::new());
    let right = |parts: &[(&str, &str)]| {
        seen.borrow_mut().extend(
            parts
                .iter()
                .map(|(t, r)| ((*t).to_owned(), (*r).to_owned())),
        );
        300
    };
    let (always, prov) = (|_: &Entry| false, |_: &Entry| None);
    let look = Look::default();
    let cx = Cx {
        look: &look,
        facts: &facts,
        always: &always,
        prov: &prov,
        right: &right,
        bg: &NO_BG,
    };
    group_rows(3, &stepped("completed"), &[], None, &cx);
    let want: Vec<(String, String)> = [
        ("15.0 s", FaceId::AgentPanelWarn.name()),
        (" · ", FaceId::AgentPanelCode.name()),
        ("$0.05", FaceId::AgentPanelCode.name()),
    ]
    .iter()
    .map(|(t, r)| ((*t).to_owned(), (*r).to_owned()))
    .collect();
    assert_eq!(*seen.borrow(), want);
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
            .filter(|f| **f == FaceId::AgentPanelWarn.name())
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
    assert_eq!(faces(under[0]), [FaceId::AgentsHooksRefused.name()]);
    assert_eq!(faces(under[2]), [FaceId::AgentsHooksBusy.name()]);
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
    assert!(faces(&rows[1]).contains(&FaceId::Agent2.name()));
    assert!(faces(&rows[2]).contains(&FaceId::Agent1.name()));
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

/// agent-panel.html `.step .what`: a shell step reads "Shell" and then its command in the code font (an adapter's
/// title quotes it in backticks: they go).
#[test]
fn a_shell_step_shows_its_command_in_code() {
    let e = tool(
        json!({"title": "`bin/drgnx test gateway`", "kind": "execute", "status": "completed"}),
    );
    let rows = rows_of(&e, &Look::default(), &BTreeMap::new(), false);
    let r = rows
        .iter()
        .find(|r| r.key == "e:3")
        .expect("the step's row");
    assert!(
        r.text.contains("Shell bin/drgnx test gateway"),
        "{:?}",
        r.text
    );
    let chars: Vec<char> = r.text.chars().collect();
    let code: Vec<String> = r
        .runs
        .iter()
        .filter(|(_, _, f)| f == FaceId::AgentPanelCode.name())
        .map(|(s, e, _)| chars[*s as usize..*e as usize].iter().collect())
        .collect();
    assert_eq!(code, ["bin/drgnx test gateway"], "{:?}", r.runs);
}

/// How an allowed step was allowed is one subtle line under it, read from what the hub cached (the cell's preset and
/// the session's scope, or an earlier yes); an Always grant says its own line instead, and no cached line adds none.
#[test]
fn an_allowed_step_says_how_it_was_allowed() {
    let look = Look::default();
    let facts = BTreeMap::new();
    let under = |rows: &[Row]| -> Vec<String> {
        rows.iter()
            .filter(|r| r.key.starts_with("e:3/p:"))
            .map(|r| r.text.clone())
            .collect()
    };
    let line = "auto-allowed: balanced \u{b7} this chat";
    let rows = rows_with(&stepped("completed"), &look, &facts, false, Some(line));
    assert_eq!(under(&rows), [format!("    {line}")]);
    let row = rows.iter().find(|r| r.key == "e:3/p:0").unwrap();
    assert_eq!(faces(row), [FaceId::AgentPanelSubtle.name()]);
    let rows = rows_with(&stepped("completed"), &look, &facts, true, Some(line));
    assert_eq!(
        under(&rows),
        ["    allowed by your Always \u{b7} V revokes"]
    );
    let rows = rows_with(&stepped("completed"), &look, &facts, false, None);
    assert!(under(&rows).is_empty());
}

// Flow Task 23, S3: the transcript from the conversation blocks (`blocks.rs`), one block type each.  The interface:
// `block_list_rows(blocks, open, kit, reduced_motion)`, rows keyed `k:N/...` for block N, each row carrying
// `drgnx-block` N; `open` holds the indexes of the Explored blocks the user opened.
mod block_rows {
    use super::*;
    use crate::agents::session::blocks::Block;
    use rodd::kit::KitEnv;
    use std::collections::BTreeSet;

    fn kit() -> KitEnv<'static> {
        KitEnv {
            scale: 1.0,
            tty: false,
            glyphs: &[],
            ascii: false,
            density: Default::default(),
            icons: None,
        }
    }

    fn text(rows: &[Row]) -> String {
        rows.iter()
            .map(|r| r.text.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// The user's message is a plain card, a bubble, with its words.
    #[test]
    fn a_you_block_is_a_bubble() {
        let rows = block_list_rows(
            &[Block::You {
                text: "fix the tests".into(),
            }],
            &BTreeSet::new(),
            &kit(),
            false,
        );
        assert!(rows[0].key.starts_with("k:0"), "{:?}", rows[0].key);
        assert!(text(&rows).contains("fix the tests"));
        assert!(rows.iter().all(|r| {
            r.props
                .iter()
                .any(|p| p.2 == "drgnx-block" && p.3 == json!(0))
        }));
    }

    /// Reads and searches fold into one collapsible section header, "Explored · N files · t"; it opens by a click.
    #[test]
    fn an_explored_block_is_a_collapsible_header_that_opens_its_steps() {
        let b = [Block::Explored {
            reads: 3,
            searches: 2,
            secs: 12,
            steps: vec![],
        }];
        let closed = block_list_rows(&b, &BTreeSet::new(), &kit(), false);
        assert_eq!(closed.len(), 1);
        assert!(
            closed[0].text.contains("Explored")
                && closed[0].text.contains('5')
                && closed[0].text.contains("12"),
            "{}",
            closed[0].text
        );
        let toggles: Vec<&Value> = closed[0]
            .props
            .iter()
            .filter(|p| p.2 == "drgnx-action")
            .map(|p| &p.3)
            .collect();
        assert_eq!(toggles, [&json!(["block-toggle", 0])]);
        // opened: the header says so (its twisty), and a click closes it
        let open = block_list_rows(&b, &BTreeSet::from([0]), &kit(), false);
        assert_ne!(closed[0].text, open[0].text);
    }

    /// A subagent's blocks nest under its head, indented.
    #[test]
    fn a_subagent_nests_and_indents() {
        let b = [Block::Subagent {
            call_id: "c1".into(),
            title: "Survey the tests".into(),
            blocks: vec![Block::You {
                text: "inner".into(),
            }],
        }];
        let rows = block_list_rows(&b, &BTreeSet::new(), &kit(), false);
        let head = rows
            .iter()
            .find(|r| r.text.contains("Survey the tests"))
            .expect("the head");
        let inner = rows
            .iter()
            .find(|r| r.text.contains("inner"))
            .expect("the nested block");
        let lead = |r: &Row| r.text.chars().take_while(|c| *c == ' ').count();
        assert!(
            lead(inner) > lead(head),
            "{:?} vs {:?}",
            inner.text,
            head.text
        );
    }

    /// The live line pulses, and stands still under reduced motion.
    #[test]
    fn the_live_line_pulses_unless_reduced_motion() {
        let b = [Block::Live {
            text: "reading the log".into(),
        }];
        let pulses = |rm: bool| {
            block_list_rows(&b, &BTreeSet::new(), &kit(), rm)
                .iter()
                .any(|r| r.props.iter().any(|p| p.2 == "drgnx-pulse"))
        };
        assert!(pulses(false));
        assert!(!pulses(true));
    }

    /// An edit is a kit diff block head: the path, `+N −M`, and Open, Revert and Comment as kit buttons.
    #[test]
    fn an_edit_block_has_open_revert_and_comment() {
        let b = [Block::Edit {
            path: "core/a.rs".into(),
            plus: 4,
            minus: 1,
            hunks: vec![crate::agents::session::blocks::HunkRef {
                start_line: 2,
                end_line: 6,
            }],
        }];
        let rows = block_list_rows(&b, &BTreeSet::new(), &kit(), false);
        let t = text(&rows);
        assert!(
            t.contains("core/a.rs") && t.contains("+4") && t.contains("\u{2212}1"),
            "{t}"
        );
        let kinds: Vec<String> = rows
            .iter()
            .flat_map(|r| r.props.iter())
            .filter(|p| p.2 == "drgnx-action")
            .filter_map(|p| p.3.get(0).and_then(Value::as_str).map(str::to_owned))
            .collect();
        assert_eq!(kinds, ["block-open", "block-revert", "block-comment"]);
    }

    /// A question the agent asks is the kit's question card with its choices; a permission's keys are y, a, n.
    #[test]
    fn an_ask_block_is_a_question_card() {
        let b = [Block::Ask {
            kind: crate::agents::session::blocks::AskKind::Permission,
            text: "Read the gateway's log?".into(),
            options: vec![
                ("Allow".into(), 'y'),
                ("Always".into(), 'a'),
                ("Deny".into(), 'n'),
            ],
        }];
        let rows = block_list_rows(&b, &BTreeSet::new(), &kit(), false);
        assert!(
            rows[0].text.contains("Read the gateway's log?"),
            "{}",
            rows[0].text
        );
        assert!(
            rows.iter()
                .flat_map(|r| r.runs.iter())
                .any(|x| x.2 == FaceId::KitQuestionCardHead.name())
        );
        let t = text(&rows);
        for label in ["Allow", "Always", "Deny"] {
            assert!(t.contains(label), "{t}");
        }
    }

    /// Any other tool call is one subtle line, "kind · title", that opens its step.
    #[test]
    fn a_step_block_is_one_line_that_opens_its_step() {
        use crate::agents::session::blocks::StepRef;
        let rows = block_list_rows(
            &[Block::Step {
                step: StepRef {
                    entry: 4,
                    step: Some(2),
                },
                kind: "shell".into(),
                title: "cargo build".into(),
            }],
            &BTreeSet::new(),
            &kit(),
            false,
        );
        assert_eq!(rows.len(), 1);
        assert!(
            rows[0].text.contains("shell · cargo build"),
            "{}",
            rows[0].text
        );
        assert_eq!(prop(&rows[0], "drgnx-work-id"), Some(&json!("e:4")));
        assert_eq!(
            prop(&rows[0], "drgnx-action"),
            Some(&json!(["block-open", 0]))
        );
    }
}

// The panel draws the user's messages, the Explored runs and the findings from the conversation's blocks (flow Task
// 23, S3), keyed by their first entry; the other entries stay groups.
mod panel_blocks {
    use super::*;
    use crate::agents::session::blocks::{Block as B, Meta, blocks};
    use rodd::kit::KitEnv;

    fn transcript() -> Vec<Entry> {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../test/fixtures/agent-blocks/transcript.json"
        );
        let v: Value =
            serde_json::from_str(&crate::fsio::read_to_string(path).expect("the fixture"))
                .expect("JSON");
        serde_json::from_value(v["entries"].clone()).expect("entries")
    }

    fn kit() -> KitEnv<'static> {
        KitEnv {
            scale: 1.0,
            tty: false,
            glyphs: &[],
            ascii: false,
            density: Default::default(),
            icons: None,
        }
    }

    /// An Explored run is one head at its first entry; its other steps are in it; the user's message is a head.
    #[test]
    fn a_run_of_reads_is_one_head_and_its_steps_are_in_it() {
        let es = transcript();
        let roles = panel_roles(&es, 10);
        assert!(
            matches!(roles.get(&10), Some(Role::Head(B::You { .. }))),
            "{roles:?}"
        );
        let (start, _) = roles
            .iter()
            .find(|(_, r)| matches!(r, Role::Head(B::Explored { .. })))
            .expect("an Explored head");
        let inside: Vec<usize> = roles
            .iter()
            .filter_map(|(i, r)| (*r == Role::In(*start)).then_some(*i))
            .collect();
        assert!(!inside.is_empty(), "{roles:?}");
        assert!(inside.iter().all(|i| i > start));
        // a finding is a head too; an edit is not (it stays a step group)
        assert!(
            roles
                .values()
                .any(|r| matches!(r, Role::Head(B::Finding { .. })))
        );
        let n_heads = roles
            .values()
            .filter(|r| matches!(r, Role::Head(_)))
            .count();
        let n_blocks = blocks(&es, &Meta::default())
            .iter()
            .filter(|b| matches!(b, B::You { .. } | B::Explored { .. } | B::Finding { .. }))
            .count();
        assert_eq!(n_heads, n_blocks);
    }

    /// The header of an Explored run is one row keyed by its first entry, carrying the entry the panel's toggle reads.
    #[test]
    fn an_explored_head_is_one_row_keyed_by_its_entry() {
        let b = B::Explored {
            reads: 2,
            searches: 1,
            secs: 4,
            steps: Vec::new(),
        };
        for open in [false, true] {
            let rows = panel_block_rows(7, &b, open, &kit());
            assert_eq!(rows.len(), 1);
            assert!(rows[0].key.starts_with("e:7"), "{}", rows[0].key);
            assert!(
                rows[0].text.contains("Explored · 3 files"),
                "{}",
                rows[0].text
            );
            assert_eq!(prop(&rows[0], "drgnx-agent-panel-entry"), Some(&json!(7)));
        }
    }
}

// ---- background work in the transcript ----

fn rows_bg(e: &Entry, bg: &BTreeMap<String, (u64, u64)>) -> Vec<Row> {
    let look = Look::default();
    let facts = BTreeMap::new();
    let (always, prov) = (|_: &Entry| false, |_: &Entry| None);
    let right = |_: &[(&str, &str)]| 300;
    let cx = Cx {
        look: &look,
        facts: &facts,
        always: &always,
        prov: &prov,
        right: &right,
        bg,
    };
    group_rows(3, e, &[], None, &cx)
}

#[test]
fn bg_tool_card_live_until_end() {
    let e = tool(
        json!({"id": "toolu_1", "title": "cargo test -p hermod", "kind": "execute", "status": "completed"}),
    );
    // the call returned at once, but its item still runs: the card is live, with its tag and elapsed time
    let live = BTreeMap::from([("toolu_1".to_owned(), (1_000_000u64 - 252_000, 1_000_000u64))]);
    let rows = rows_bg(&e, &live);
    assert!(rows[0].text.contains("in background"), "{:?}", rows[0].text);
    assert!(rows[0].text.contains("4:12"), "{:?}", rows[0].text);
    // the dot is filled and in the accent colour (the mockup's), not the hollow run dot or the done one's green
    assert!(rows[0].text.starts_with("  ●"), "{:?}", rows[0].text);
    assert!(
        rows[0]
            .runs
            .iter()
            .any(|(a, b, f)| *a <= 2 && 2 < *b && f == FaceId::Accent.name()),
        "{:?}",
        rows[0].runs
    );
    let el: Vec<_> = rows[0]
        .props
        .iter()
        .filter(|p| p.2 == "drgnx-bg-elapsed")
        .collect();
    assert_eq!(el.len(), 1);
    assert_eq!(el[0].3, json!(1_000_000u64 - 252_000));
    // once the item has ended the card is the ordinary one
    let done = rows_bg(&e, &BTreeMap::new());
    assert!(!done[0].text.contains("in background"));
    assert!(done[0].text.starts_with("  ●"), "{:?}", done[0].text);
}

fn rows_bg_with(
    e: &Entry,
    bg: &BTreeMap<String, (u64, u64)>,
    right: &dyn Fn(&Parts<'_>) -> u32,
) -> Vec<Row> {
    let look = Look::default();
    let facts = BTreeMap::new();
    let (always, prov) = (|_: &Entry| false, |_: &Entry| None);
    let cx = Cx {
        look: &look,
        facts: &facts,
        always: &always,
        prov: &prov,
        right,
        bg,
    };
    group_rows(3, e, &[], None, &cx)
}

#[test]
fn bg_shell_card_is_live_through_its_terminal() {
    // the shell's call has its own id; its content shows the terminal the background item is
    let e = tool(json!({
        "id": "call-t1", "title": "Bash: cargo test -p hermod", "kind": "execute", "status": "completed",
        "content": [{"type": "terminal", "terminalId": "t1"}]
    }));
    let live = BTreeMap::from([("t1".to_owned(), (1_000_000u64 - 252_000, 1_000_000u64))]);
    let rows = rows_bg(&e, &live);
    assert!(rows[0].text.contains("in background"), "{:?}", rows[0].text);
    assert!(rows[0].text.contains("4:12"), "{:?}", rows[0].text);
    assert!(
        !rows_bg(&e, &BTreeMap::new())[0]
            .text
            .contains("in background")
    );
}

#[test]
fn a_live_card_keeps_its_tag_and_its_time_at_the_docks_width() {
    let long = format!(
        "Bash: {}",
        "cargo test --features very-long-feature ".repeat(5)
    );
    let e = tool(json!({"id": "w1", "title": long, "kind": "execute", "status": "in_progress"}));
    let live = BTreeMap::from([("w1".to_owned(), (1_000_000u64 - 252_000, 1_000_000u64))]);
    // a 400 px dock, 8 px a character: what starts at `right(parts)` is `parts` right-aligned
    let right = |parts: &[(&str, &str)]| -> u32 {
        400u32.saturating_sub(
            8 * parts
                .iter()
                .map(|p| p.0.chars().count() as u32)
                .sum::<u32>(),
        )
    };
    let rows = rows_bg_with(&e, &live, &right);
    let text = &rows[0].text;
    assert!(text.contains("in background"), "{text:?}");
    assert!(text.trim_end().ends_with("4:12"), "{text:?}");
    assert!(
        text.contains('…'),
        "the command is cut in the middle of what is left: {text:?}"
    );
    assert!(
        (text.chars().count() as u32) * 8 <= 400,
        "the row fits the dock: {} chars",
        text.chars().count()
    );
    // the elapsed time is right-aligned: a stop before it
    assert_eq!(rows[0].stops.len(), 1);
}

#[test]
fn an_edit_step_says_how_many_lines_it_added_and_removed() {
    let new: String = (1..=142).map(|i| format!("line {i}\n")).collect();
    let e = tool(json!({
        "id": "c1", "title": "Edit hermod/src/v2.rs", "kind": "edit", "status": "completed",
        "content": [{"type": "diff", "path": "hermod/src/v2.rs", "oldText": "", "newText": new}]
    }));
    let rows = rows_bg(&e, &BTreeMap::new());
    assert!(
        rows[0].text.contains("Edit hermod/src/v2.rs +142"),
        "{:?}",
        rows[0].text
    );
    assert!(!rows[0].text.contains('−'));
    // an edit with no diff says nothing of lines
    let bare =
        tool(json!({"id": "c2", "title": "Edit a.el", "kind": "edit", "status": "completed"}));
    assert!(!rows_bg(&bare, &BTreeMap::new())[0].text.contains('+'));
}
