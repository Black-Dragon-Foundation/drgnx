//! history.db: the schema, reopening, the records with their parents, and one transaction per multi-file record.
//! Pattern D (pure: a temporary folder, no process, no clock; every time is a parameter).

use verdandi::{
    BranchKind, Cause, DocId, DocUpdate, Frontier, History, Kind, OpId, PeerId, Record, Span,
};

fn record(kind: Kind, author: PeerId, parents: Vec<OpId>, spans: Vec<(DocId, Span)>) -> Record {
    Record {
        kind,
        author,
        cause: Cause::default(),
        spans,
        parents,
        git: None,
        summary: "s".into(),
        at: 1.5,
    }
}

#[test]
fn open_creates_the_current_schema() {
    let d = tempfile::tempdir().unwrap();
    let h = History::open(&d.path().join("p")).unwrap();
    assert_eq!(h.schema().unwrap(), verdandi::SCHEMA_VERSION);
    let db = d.path().join("p/history.db");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        std::fs::metadata(&db).unwrap().permissions().mode() & 0o777,
        0o600
    );
    for t in [
        "op",
        "op_parent",
        "doc",
        "doc_update",
        "doc_snapshot",
        "peer",
        "branch",
        "pending",
        "preview",
        "provenance",
        "anchor",
    ] {
        assert_eq!(h.count(t).unwrap(), 0, "{t}");
    }
}

#[test]
fn reopen_is_idempotent() {
    let d = tempfile::tempdir().unwrap();
    let mut h = History::open(d.path()).unwrap();
    let doc = h.doc_for("src/a.rs").unwrap();
    let b = h.branch("wt/1", BranchKind::Worktree, Some("c1")).unwrap();
    drop(h);
    let mut h = History::open(d.path()).unwrap();
    assert_eq!(h.schema().unwrap(), verdandi::SCHEMA_VERSION);
    assert_eq!(h.doc_for("src/a.rs").unwrap(), doc);
    assert_eq!(
        h.branch("wt/1", BranchKind::Worktree, Some("c1")).unwrap(),
        b
    );
    assert_eq!(h.count("doc").unwrap(), 1);
    assert_eq!(h.base_of(b).unwrap().as_deref(), Some("c1"));
}

#[test]
fn ops_round_trip_with_parents() {
    let d = tempfile::tempdir().unwrap();
    let mut h = History::open(d.path()).unwrap();
    let doc = h.doc_for("a.txt").unwrap();
    let br = h.branch("wt/1", BranchKind::Worktree, None).unwrap();
    let user = h
        .peer(&serde_json::json!({"user": "session-1"}), Some(br))
        .unwrap();
    let agent = h.peer(&serde_json::json!({"run": "r1"}), Some(br)).unwrap();
    assert_ne!(user, agent);
    let span = Span {
        peer: agent,
        start: 0,
        end: 5,
    };
    let view = vec![(doc, br, Frontier(vec![1, 2, 3]))];
    let mut r = record(Kind::AgentStep, agent, vec![], vec![(doc, span)]);
    r.cause = Cause {
        session: Some("acp-1".into()),
        step: Some("7".into()),
        decision: Some("decision:3".into()),
        ..Cause::default()
    };
    r.git = Some("abc".into());
    let a = h.put_op(&r, &view, &[]).unwrap();
    let b = h
        .put_op(&record(Kind::Edits, user, vec![a], vec![]), &[], &[])
        .unwrap();
    let c = h
        .put_op(&record(Kind::Merge, user, vec![b, a], vec![]), &[], &[])
        .unwrap();
    let got = h.op(a).unwrap();
    assert_eq!(
        (
            got.kind, got.author, got.cause, got.spans, got.view, got.git
        ),
        (
            Kind::AgentStep,
            agent,
            r.cause.clone(),
            vec![(doc, span)],
            view,
            Some("abc".into())
        )
    );
    assert_eq!(h.op(b).unwrap().parents, [a]);
    assert_eq!(h.op(c).unwrap().parents, [a, b]);
    assert_eq!(
        h.author_of(agent).unwrap(),
        Some(serde_json::json!({"run": "r1"}))
    );
    // a revert names the record it acts on
    assert!(
        h.put_op(&record(Kind::Revert, user, vec![], vec![]), &[], &[])
            .is_err()
    );
    // and a reopened store reads the same
    drop(h);
    let h = History::open(d.path()).unwrap();
    assert_eq!(h.op(c).unwrap().parents, [a, b]);
    assert_eq!(h.op(a).unwrap().spans, [(doc, span)]);
}

#[test]
fn multi_file_record_is_one_transaction() {
    let d = tempfile::tempdir().unwrap();
    let mut h = History::open(d.path()).unwrap();
    let one = h.doc_for("one.txt").unwrap();
    let two = h.doc_for("two.txt").unwrap();
    let br = h.branch("wt/1", BranchKind::Worktree, None).unwrap();
    let p = h.peer(&serde_json::json!({"run": "r1"}), Some(br)).unwrap();
    let upd = |doc| DocUpdate {
        doc,
        branch: br,
        bytes: vec![9; 4],
    };
    // the third file's update fails (no such document): nothing of the record stays
    let bad = h.put_op(
        &record(Kind::AgentStep, p, vec![], vec![]),
        &[],
        &[upd(one), upd(two), upd(DocId(999))],
    );
    assert!(bad.is_err());
    assert_eq!(
        (h.count("op").unwrap(), h.count("doc_update").unwrap()),
        (0, 0)
    );
    // without it, all of it
    h.put_op(
        &record(Kind::AgentStep, p, vec![], vec![]),
        &[],
        &[upd(one), upd(two)],
    )
    .unwrap();
    assert_eq!(
        (h.count("op").unwrap(), h.count("doc_update").unwrap()),
        (1, 2)
    );
}
