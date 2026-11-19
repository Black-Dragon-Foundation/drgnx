use super::*;
use serde_json::json;

/// The recorded transcript (`test/fixtures/agent-blocks/transcript.json`): its entries and what is kept beside them.
fn fixture() -> (Vec<Entry>, Meta) {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../test/fixtures/agent-blocks/transcript.json"
    );
    let v: Value =
        serde_json::from_str(&std::fs::read_to_string(path).expect("the fixture")).expect("JSON");
    let entries: Vec<Entry> = serde_json::from_value(v["entries"].clone()).expect("entries");
    let parents = v["parents"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, p)| (k.clone(), p.as_str().unwrap().to_owned()))
        .collect();
    let secs = v["secs"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, s)| (k.parse().unwrap(), s.as_f64().unwrap()))
        .collect();
    (entries, Meta { parents, secs })
}

fn entry(v: Value) -> Entry {
    serde_json::from_value(v).unwrap()
}

/// Each block's kind, in order.
fn kinds(bs: &[Block]) -> Vec<&'static str> {
    bs.iter()
        .map(|b| match b {
            Block::You { .. } => "you",
            Block::Explored { .. } => "explored",
            Block::Markdown { .. } => "markdown",
            Block::Finding { .. } => "finding",
            Block::Edit { .. } => "edit",
            Block::Step { .. } => "step",
            Block::Ask { .. } => "ask",
            Block::Subagent { .. } => "subagent",
            Block::Notice { .. } => "notice",
            Block::Live { .. } => "live",
            Block::Queued { .. } => "queued",
        })
        .collect()
}

#[test]
fn reads_and_searches_fold_into_one_explored_block() {
    let (es, m) = fixture();
    let bs = blocks(&es, &m);
    assert_eq!(
        kinds(&bs),
        [
            "you", "markdown", "explored", "edit", "explored", "finding", "step", "subagent",
            "step"
        ]
    );
    // read, search, a thought (it breaks nothing), read: one run, its seconds summed
    let Block::Explored {
        reads,
        searches,
        secs,
        steps,
    } = &bs[2]
    else {
        unreachable!()
    };
    assert_eq!(
        (*reads, *searches, *secs),
        (2, 1, 4),
        "1.2 + 0.4 + 2.1 s, rounded once"
    );
    assert_eq!(
        steps.iter().map(|s| (s.entry, s.step)).collect::<Vec<_>>(),
        [(2, Some(1)), (3, Some(2)), (5, Some(3))]
    );
}

#[test]
fn an_edit_breaks_the_explored_run() {
    let (es, m) = fixture();
    let bs = blocks(&es, &m);
    assert_eq!(
        bs[3],
        Block::Edit {
            path: "src/fetch.rs".into(),
            plus: 3,
            minus: 1,
            hunks: vec![
                HunkRef {
                    start_line: 2,
                    end_line: 2
                },
                HunkRef {
                    start_line: 4,
                    end_line: 5
                }
            ],
        }
    );
    assert!(matches!(
        bs[4],
        Block::Explored {
            reads: 1,
            searches: 0,
            ..
        }
    ));
    // a turn's end breaks a run too
    let read =
        |id: &str| entry(json!({"type": "tool", "id": id, "kind": "read", "title": "Read a"}));
    let bs = blocks(
        &[read("a"), entry(json!({"type": "stop"})), read("b")],
        &Meta::default(),
    );
    assert_eq!(kinds(&bs), ["explored", "explored"]);
}

#[test]
fn a_finding_carries_its_sources() {
    let (es, m) = fixture();
    let bs = blocks(&es, &m);
    let Block::Finding {
        conclusion,
        text,
        sources,
    } = &bs[5]
    else {
        unreachable!()
    };
    assert_eq!(
        (conclusion.as_str(), text.as_str()),
        ("finding", "send() has no backoff")
    );
    assert_eq!(
        sources,
        &[
            Source::Path {
                path: "src/fetch.rs".into(),
                lines: Some([1, 3])
            },
            Source::Url {
                url: "https://example.org/backoff".into()
            }
        ]
    );
    let d = entry(
        json!({"type": "tool", "id": "d", "title": "drgnx.record_decision",
        "rawInput": {"subject": "three tries", "reason": "the server drops one in ten"}}),
    );
    assert_eq!(
        blocks(&[d], &Meta::default()),
        [Block::Finding {
            conclusion: "decision".into(),
            text: "three tries: the server drops one in ten".into(),
            sources: Vec::new()
        }]
    );
}

#[test]
fn a_permission_is_an_ask_block_with_y_a_n() {
    let (es, _) = fixture();
    let ask = AskIn {
        kind: AskKind::Permission,
        text: "Edit src/fetch.rs".into(),
        options: vec![
            ("Allow".into(), "allow_once".into()),
            ("Always allow".into(), "allow_always".into()),
            ("Deny".into(), "reject_once".into()),
        ],
    };
    let o = overlay(&es, &[ask], true, &["and add a test".into()]);
    assert_eq!(
        o,
        [
            Block::Ask {
                kind: AskKind::Permission,
                text: "Edit src/fetch.rs".into(),
                options: vec![
                    ("Allow".into(), 'y'),
                    ("Always allow".into(), 'a'),
                    ("Deny".into(), 'n')
                ],
            },
            Block::Queued {
                text: "and add a test".into()
            }
        ]
    );
    // a tool call still running is the live block, last before the queue
    let running = entry(
        json!({"type": "tool", "id": "x", "kind": "execute", "title": "cargo test", "status": "in_progress"}),
    );
    assert_eq!(
        overlay(&[running], &[], true, &[]),
        [Block::Live {
            text: "cargo test".into()
        }]
    );
    // an agent's question keeps its kind; its options take the same keys
    let question = AskIn {
        kind: AskKind::Question,
        text: "Keep the old name?".into(),
        options: vec![
            ("Yes".into(), "allow_once".into()),
            ("No".into(), "reject_once".into()),
        ],
    };
    assert_eq!(
        overlay(&[], &[question], false, &[]),
        [Block::Ask {
            kind: AskKind::Question,
            text: "Keep the old name?".into(),
            options: vec![("Yes".into(), 'y'), ("No".into(), 'n')],
        }]
    );
}

#[test]
fn subagent_steps_nest_under_their_call() {
    let (es, m) = fixture();
    let bs = blocks(&es, &m);
    let Block::Subagent {
        call_id,
        title,
        blocks: inner,
    } = &bs[7]
    else {
        unreachable!()
    };
    assert_eq!(
        (call_id.as_str(), title.as_str()),
        ("t7", "Task: check the tests")
    );
    assert_eq!(kinds(inner), ["explored", "step"]);
    assert!(matches!(
        inner[0],
        Block::Explored {
            reads: 1,
            searches: 1,
            ..
        }
    ));
    // the parent's next step is the parent's again
    assert!(matches!(&bs[8], Block::Step { title, .. } if title == "cargo build"));
}

#[test]
fn append_touches_only_the_tail() {
    let (es, m) = fixture();
    let mut all: Vec<Entry> = Vec::new();
    while all.len() < 10_000 {
        all.extend(es.iter().cloned());
    }
    let mut f = Folder::of(&all, &m);
    let before = f.blocks.clone();
    let n = before.len();
    // a read after a step: one new block
    let read = entry(json!({"type": "tool", "id": "r1", "kind": "read", "title": "Read z"}));
    let p = append(&mut f, std::slice::from_ref(&read), &m);
    assert_eq!(
        p,
        Patch {
            from: n,
            len: n + 1
        }
    );
    // a second read joins it: the last block is patched, nothing added
    let read2 = entry(json!({"type": "tool", "id": "r2", "kind": "search", "title": "grep z"}));
    let p = append(&mut f, std::slice::from_ref(&read2), &m);
    assert_eq!(
        p,
        Patch {
            from: n,
            len: n + 1
        }
    );
    assert_eq!(f.blocks[..n], before[..]);
    // a changed entry folds again from its block only
    all.push(read);
    all.push(read2);
    let mut edit = entry(json!({"type": "tool", "id": "e1", "kind": "edit", "title": "Edit z"}));
    all.push(edit.clone());
    append(&mut f, std::slice::from_ref(&edit), &m);
    edit.rest.insert(
        "content".into(),
        json!([{"type": "diff", "path": "z", "oldText": "a\n", "newText": "b\n"}]),
    );
    let last = all.len() - 1;
    all[last] = edit;
    let p = f.update(&all, last, &m);
    assert_eq!(
        p,
        Patch {
            from: n + 1,
            len: n + 2
        }
    );
    assert!(matches!(&f.blocks[n + 1], Block::Edit { plus: 1, minus: 1, path, .. } if path == "z"));
    assert_eq!(f.blocks[..n], before[..]);
}

#[test]
fn plan_strip_follows_the_latest_plan_entry() {
    let (es, _) = fixture();
    assert_eq!(
        plan_strip(&es),
        [
            ("Read the fetcher".to_string(), PlanState::Done),
            ("Add the retry".to_string(), PlanState::Done),
            ("Test it".to_string(), PlanState::Doing)
        ]
    );
    assert_eq!(
        plan_strip(&es[..15])[1],
        ("Add the retry".to_string(), PlanState::Doing)
    );
    assert!(plan_strip(&es[..2]).is_empty());
}

/// Flow Task 23a: the limit a paused agent's block suggests is its spend plus the forecast's p90 of what remains,
/// rounded up to the unit's next step: the next dollar, the next whole percent of a window, the next 100k tokens;
/// a count has none.
#[test]
fn at_limit_block_suggests_p90_rounded_up() {
    use runstav::methods::matrix::Unit;
    let near = |got: Option<f64>, want: f64| {
        let g = got.expect("a suggestion");
        assert!((g - want).abs() < 1e-9, "{g} != {want}");
    };
    near(at_limit_suggestion(Unit::UsdEst, 5.0, 2.3), 8.0); // 7.30 -> 8
    near(at_limit_suggestion(Unit::Usd, 5.0, 3.0), 8.0); // 8.00 stays 8
    near(at_limit_suggestion(Unit::LimitShare, 0.31, 0.052), 0.37); // 36.2 % -> 37 %
    near(at_limit_suggestion(Unit::Tokens, 450_000.0, 120_500.0), 600_000.0); // 570,500 -> 600k
    assert_eq!(at_limit_suggestion(Unit::Count, 3.0, 1.0), None);
}
