//! The conclusion's step stamp in every order of its sources (pattern A); its links and the rows it is read from
//! (pattern D).

use super::*;
use serde_json::json;
use skuld::{Bound, Partial, every_order};
use std::collections::BTreeSet;

skuld::events!(StampEv {
    McpCall,
    ToolStep,
    StepClosed,
    TurnEnd
});

fn call(session: &str, tool: &str, conclusion: &str) -> StampEv {
    StampEv::McpCall {
        session: session.into(),
        tool: tool.into(),
        call: conclusion.into(),
        at: 1.0,
    }
}

fn began(session: &str, key: i64, tool_name: &str) -> StampEv {
    StampEv::ToolStep {
        session: session.into(),
        step: key,
        tool_name: tool_name.into(),
        at: 1.0,
    }
}

fn written(session: &str, key: i64, id: i64) -> StampEv {
    StampEv::StepClosed {
        session: session.into(),
        step: key,
        id,
    }
}

fn turn_end(session: &str) -> StampEv {
    StampEv::TurnEnd {
        session: session.into(),
    }
}

fn stamp(conclusion: &str, step: Option<i64>) -> Stamp {
    Stamp {
        conclusion: conclusion.into(),
        step,
    }
}

#[derive(Default)]
struct Harness {
    core: StampCore,
    stamps: Vec<Stamp>,
}

impl skuld::Core for Harness {
    type Event = StampEv;
    fn step(&mut self, ev: StampEv) -> Vec<StampEv> {
        let out = self.core.step(ev);
        self.stamps.extend(out);
        Vec::new()
    }
}

/// Pattern A. Two sessions; in one, a decision, a read, a finding and a second decision, each MCP call arriving at any
/// point against the session's ACP stream (before its tool step began, or after); a Codex-named one in the other.
/// Every call is stamped once with its own step, never with the read's or the other session's. Edges: a call is fed
/// before its own step is written (the hub reads a tool call's writes before it answers, and the agent reports the
/// step complete only after the answer); a turn's end comes last on its stream.
#[test]
fn both_arrival_orders_stamp_the_same_step() {
    let mut p = Partial::new();
    let acp = p.source(
        "acp a",
        vec![
            began("a", 1, "mcp__drgnx__record_decision"),
            written("a", 1, 101),
            began("a", 2, "Read"),
            written("a", 2, 102),
            began("a", 3, "mcp__drgnx__note_add"),
            written("a", 3, 103),
            began("a", 4, "mcp__drgnx__record_decision"),
            written("a", 4, 104),
            turn_end("a"),
        ],
    );
    let mcp = p.source(
        "mcp a",
        vec![
            call("a", "record_decision", "decision:1"),
            call("a", "note_add", "note:x"),
            call("a", "record_decision", "decision:2"),
        ],
    );
    let acp_b = p.source(
        "acp b",
        vec![
            began("b", 1, "drgnx.record_decision"),
            written("b", 1, 201),
            turn_end("b"),
        ],
    );
    let mcp_b = p.source("mcp b", vec![call("b", "record_decision", "decision:9")]);
    p.before((mcp, 0), (acp, 1));
    p.before((mcp, 1), (acp, 5));
    p.before((mcp, 2), (acp, 7));
    p.before((mcp_b, 0), (acp_b, 1));
    let want: BTreeSet<Stamp> = [
        stamp("decision:1", Some(101)),
        stamp("note:x", Some(103)),
        stamp("decision:2", Some(104)),
        stamp("decision:9", Some(201)),
    ]
    .into();
    let r = every_order(&p, Bound::default(), Harness::default, |h, _| {
        let got: BTreeSet<Stamp> = h.stamps.iter().cloned().collect();
        if got != want || h.stamps.len() != want.len() {
            return Err(format!("stamps {:?}", h.stamps));
        }
        Ok(())
    });
    assert!(r.orders > 100, "{} orders", r.orders);
}

/// Pattern D. A call whose tool step never comes by the turn's end (an adapter that reports no MCP calls) is stamped
/// "step unknown", once; a tool step with no call (a failed call) stamps nothing.
#[test]
fn no_tool_step_is_step_unknown() {
    let mut c = StampCore::new();
    assert_eq!(c.step(call("a", "record_decision", "decision:1")), []);
    assert_eq!(c.step(began("a", 1, "mcp__drgnx__note_add")), []);
    assert_eq!(c.step(written("a", 1, 11)), []);
    assert_eq!(
        c.step(turn_end("a")),
        [stamp("decision:1", None)],
        "the note_add step is no record_decision's"
    );
    assert_eq!(c.step(turn_end("a")), []);
    // another tool's step is never a conclusion's
    assert_eq!(c.step(began("a", 2, "mcp__other__record_decision")), []);
    assert_eq!(c.step(call("a", "record_decision", "decision:2")), []);
    assert_eq!(c.step(written("a", 2, 12)), []);
    assert_eq!(c.step(turn_end("a")), [stamp("decision:2", None)]);
    assert_eq!(
        mcp_tool_of("record_decision (drgnx MCP Server)"),
        Some("record_decision")
    );
    assert_eq!(mcp_tool_of("Read"), None);
}

fn step(id: i64, class: &str, d: Option<StepDetail>) -> StepWithDetail {
    StepWithDetail {
        id,
        class: class.into(),
        start: id as f64,
        detail: d,
    }
}

fn read(path: &str, lines: Option<(i64, Option<i64>)>) -> Option<StepDetail> {
    Some(StepDetail {
        kind: Some("read".into()),
        path: Some(path.into()),
        line_start: lines.map(|l| l.0),
        line_end: lines.and_then(|l| l.1),
        origin: "acp".into(),
        ..StepDetail::default()
    })
}

fn of_kind(kind: &str, url: Option<&str>) -> Option<StepDetail> {
    Some(StepDetail {
        kind: Some(kind.into()),
        url: url.map(str::to_string),
        origin: "acp".into(),
        ..StepDetail::default()
    })
}

fn conclusion(step: Option<i64>, at: f64, sources: Vec<Source>) -> Conclusion {
    Conclusion {
        id: "decision:1".into(),
        kind: "decision".into(),
        text: "use the cache".into(),
        sources,
        step,
        at,
        origin: "own".into(),
    }
}

fn path(p: &str, lines: Option<[u32; 2]>) -> Source {
    Source::Path {
        path: p.into(),
        lines,
    }
}

/// The session the link tests read: reads of `src/a.rs` at three ranges, a whole-file read of `b.rs`, a page, and a
/// read after the conclusion (step 9).
fn trail() -> Vec<StepWithDetail> {
    vec![
        step(1, "tool", read("/w/src/a.rs", Some((1, Some(50))))),
        step(2, "think", None),
        step(3, "tool", read("/w/src/a.rs", Some((100, Some(150))))),
        step(4, "tool", of_kind("fetch", Some("https://example.test/a"))),
        step(5, "tool", read("/w/src/a.rs", Some((120, Some(200))))),
        step(6, "tool", read("/w/b.rs", Some((10, None)))),
        step(7, "tool", of_kind("edit", None)),
        step(8, "tool", None),
        step(9, "tool", read("/w/src/a.rs", Some((120, Some(130))))),
    ]
}

/// Pattern D. A named source matches the latest read of that path up to the conclusion whose lines overlap, and a
/// page its latest fetch; a read with no end (no limit) covers the rest of the file.
#[test]
fn named_sources_match_the_latest_overlapping_read() {
    let c = conclusion(
        Some(8),
        8.0,
        vec![
            path("src/a.rs", Some([125, 126])),
            path("src/a.rs", Some([10, 20])),
            Source::Url {
                url: "https://example.test/a".into(),
            },
            path("b.rs", Some([900, 901])),
        ],
    );
    let l = links(&c, None, &trail());
    assert_eq!(l.named, [5, 1, 4, 6]);
    assert_eq!(l.unmatched, []);
}

/// Pattern D. The steps since the previous conclusion, filtered to reads, searches, pages and thoughts, are the links
/// of a conclusion that names no source; a conclusion whose step is unknown is placed by its time.
#[test]
fn unnamed_falls_back_to_since_last() {
    let prev = conclusion(Some(2), 2.0, Vec::new());
    let c = conclusion(Some(8), 8.0, Vec::new());
    let l = links(&c, Some(&prev), &trail());
    assert_eq!(l.since_last, [3, 4, 5, 6]);
    assert_eq!(l.named, Vec::<i64>::new());
    let unknown = conclusion(None, 4.5, Vec::new());
    assert_eq!(links(&unknown, None, &trail()).since_last, [1, 2, 3, 4]);
}

/// Pattern D. A named source no step matches stays, as "named, not read in this session"; one read only after the
/// conclusion does not match.
#[test]
fn an_unmatched_source_is_kept_and_labelled() {
    let gone = path("src/never.rs", None);
    let later = path("src/a.rs", Some([300, 310]));
    let c = conclusion(Some(8), 8.0, vec![gone.clone(), later.clone()]);
    let l = links(&c, None, &trail());
    assert_eq!(l.named, Vec::<i64>::new());
    assert_eq!(l.unmatched, [gone, later]);
}

/// Pattern D. A conclusion from a message's fenced block reads back labelled `from-text`, its step unknown; a
/// finding's text is its body, a decision's its subject, and the hub's stamp is its step.
#[test]
fn from_text_block_is_labelled() {
    let d = from_entity(
        "decision:3",
        "decision",
        Some("use the cache"),
        Some("the reason"),
        &json!({"n": 3, "origin": "from-text", "session": "a", "sources": [{"path": "src/a.rs", "lines": [1, 2]}]}),
        5.0,
    );
    assert_eq!(
        (d.kind.as_str(), d.text.as_str(), d.origin.as_str(), d.step),
        ("decision", "use the cache", "from-text", None)
    );
    assert_eq!(d.sources, [path("src/a.rs", Some([1, 2]))]);
    let f = from_entity(
        "note:pa-1",
        "note",
        Some("it is so"),
        Some("it is so, because"),
        &json!({"kind": "finding", "step": 12}),
        6.0,
    );
    assert_eq!(
        (f.kind.as_str(), f.text.as_str(), f.origin.as_str(), f.step),
        ("finding", "it is so, because", "own", Some(12))
    );
}

// ---- conclusions after a step: rows read from a real store (pattern D) ----

mod after_a_step {
    use super::*;
    use norn::store::CoordDb;
    use norn::write::decisions::{Decide, DecideResult, decide};
    use norn::write::steps::{StepClass, StepNew, open};
    use urdr::graph::entity::{self, Changes, EntityNew, Origin};

    fn meta() -> urdr::graph::TxMeta {
        urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "test")
    }

    fn step(tx: &mut norn::store::WTx<'_>, log_version: i64) -> i64 {
        open(
            tx,
            StepNew {
                session: "session:s1".into(),
                task: None,
                plan: None,
                project: None,
                agent: None,
                provider: None,
                class: StepClass::Tool,
                start: 1.0,
                tool: None,
                tool_kind: None,
                message_id: None,
                turn_id: None,
                snapshot: None,
                log_version: Some(log_version),
                acp: None,
            },
        )
        .unwrap()
    }

    /// A decision of session s1, stamped with STEP when it has one.
    fn decision(tx: &mut norn::store::WTx<'_>, step: Option<i64>) -> i64 {
        let DecideResult::Ok { n, .. } = decide(
            tx,
            Decide {
                kind: "build".into(),
                subject: "x".into(),
                author: "user".into(),
                ..Decide::default()
            },
            2.0,
        )
        .unwrap() else {
            panic!("held")
        };
        let e = entity::by_id(tx.sql(), &format!("decision:{n}"))
            .unwrap()
            .unwrap();
        entity::update(
            tx,
            e.n,
            None,
            Changes {
                data_patch: Some(json!({"session": "s1", "step": step})),
                ..Changes::default()
            },
        )
        .unwrap();
        n
    }

    fn finding(tx: &mut norn::store::WTx<'_>, id: &str, step: Option<i64>) {
        let project = tx.meta().project;
        entity::create(
            tx,
            EntityNew {
                id: id.into(),
                kind: "note".into(),
                project,
                title: Some("f".into()),
                status: None,
                body: Some("f".into()),
                priority: None,
                assignee: None,
                data: json!({"kind": "finding", "session": "s1", "step": step}),
                origin: Origin::Recorded,
                source: None,
            },
        )
        .unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn conclusions_after_use_the_stamped_step() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        let late = db
            .write(meta(), |tx| {
                let (a, b, c) = (step(tx, 0), step(tx, 0), step(tx, 0));
                decision(tx, Some(a));
                decision(tx, Some(b));
                let late = decision(tx, Some(c));
                finding(tx, "note:early", Some(a));
                finding(tx, "note:late", Some(c));
                Ok(late)
            })
            .await
            .unwrap();
        let got = db.read(|c| after(c, "s1", 2)).await.unwrap();
        assert_eq!(
            got,
            [
                Concluded::Decision(late),
                Concluded::Finding("note:late".into())
            ]
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn conclusions_without_a_stamp_fall_back_to_the_log_version() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        let after_it = db
            .write(meta(), |tx| {
                // the target step saw the decision log at version 1; the first decision made it, the second came after
                let first = decision(tx, None);
                let _ = step(tx, 0);
                let target = step(tx, 1);
                let _ = target;
                let second = decision(tx, None);
                finding(tx, "note:unstamped", None);
                Ok((first, second))
            })
            .await
            .unwrap();
        let got = db.read(|c| after(c, "s1", 2)).await.unwrap();
        assert!(got.contains(&Concluded::Decision(after_it.1)), "{got:?}");
        assert!(!got.contains(&Concluded::Decision(after_it.0)), "{got:?}");
        assert!(got.contains(&Concluded::Finding("note:unstamped".into())));
    }
}
