//! The operation log: the settle rule, the flushes, the view, the records that name a target.
//! Pattern D (pure: a temporary folder, no process; every time is a parameter).

use verdandi::{
    BranchId, BranchKind, Cause, Change, DocId, FlushReason, History, Kind, PeerId, Record,
    Settler, Span,
};

struct Fx {
    _dir: tempfile::TempDir,
    h: History,
    doc: DocId,
    br: BranchId,
}

fn fx() -> Fx {
    let dir = tempfile::tempdir().unwrap();
    let mut h = History::open(dir.path()).unwrap();
    let doc = h.doc_for("a.txt").unwrap();
    let br = h.branch("wt/a", BranchKind::Worktree, Some("c1")).unwrap();
    h.activate(doc, br, || Ok("abc\n".into())).unwrap();
    Fx {
        _dir: dir,
        h,
        doc,
        br,
    }
}

fn type_at(f: &mut Fx, p: PeerId, at: usize, s: &str) -> Vec<Span> {
    f.h.activate(f.doc, f.br, || unreachable!())
        .unwrap()
        .apply(
            p,
            &Change {
                start: at,
                old_len: 0,
                inserted: s.into(),
            },
        )
        .unwrap()
}

#[test]
fn typing_settles_into_one_edits_record_after_30s() {
    let mut f = fx();
    let user =
        f.h.peer(&serde_json::json!({"user": 1}), Some(f.br))
            .unwrap();
    let mut s = Settler::default();
    for (i, t) in [0.0, 5.0, 10.0].into_iter().enumerate() {
        let spans = type_at(&mut f, user, i, "x");
        s.change(f.doc, user, &spans, t);
    }
    assert!(
        s.settle_due(&mut f.h, 39.0).unwrap().is_empty(),
        "29 s quiet"
    );
    let ids = s.settle_due(&mut f.h, 40.0).unwrap();
    assert_eq!(ids.len(), 1);
    let r = f.h.op(ids[0]).unwrap();
    assert_eq!((r.kind, r.author, r.at), (Kind::Edits, user, 40.0));
    // three keystrokes, one span of three element ids
    assert_eq!(
        r.spans,
        [(
            f.doc,
            Span {
                peer: user,
                start: 0,
                end: 3
            }
        )]
    );
    assert!(s.is_empty());
    assert!(s.settle_due(&mut f.h, 100.0).unwrap().is_empty());
}

#[test]
fn save_flushes_at_once() {
    let mut f = fx();
    let user =
        f.h.peer(&serde_json::json!({"user": 1}), Some(f.br))
            .unwrap();
    let mut s = Settler::default();
    let spans = type_at(&mut f, user, 0, "y");
    s.change(f.doc, user, &spans, 0.0);
    let ids = s.flush(&mut f.h, FlushReason::Save, 1.0).unwrap();
    assert_eq!(ids.len(), 1);
    assert_eq!(f.h.op(ids[0]).unwrap().at, 1.0);
    assert!(s.settle_due(&mut f.h, 100.0).unwrap().is_empty());
    // the next record follows the last
    let spans = type_at(&mut f, user, 0, "z");
    s.change(f.doc, user, &spans, 2.0);
    let next = s.flush(&mut f.h, FlushReason::BufferSwitch, 3.0).unwrap();
    assert_eq!(f.h.op(next[0]).unwrap().parents, ids);
}

#[test]
fn step_boundary_flushes_per_author() {
    let mut f = fx();
    let user =
        f.h.peer(&serde_json::json!({"user": 1}), Some(f.br))
            .unwrap();
    let agent =
        f.h.peer(&serde_json::json!({"run": "r1"}), Some(f.br))
            .unwrap();
    let mut s = Settler::default();
    let su = type_at(&mut f, user, 0, "u");
    s.change(f.doc, user, &su, 0.0);
    let sa = type_at(&mut f, agent, 4, "a");
    s.change(f.doc, agent, &sa, 0.5);
    let ids = s.flush(&mut f.h, FlushReason::StepBoundary, 1.0).unwrap();
    assert_eq!(ids.len(), 2);
    let mut got: Vec<(PeerId, Vec<Span>)> = ids
        .iter()
        .map(|i| {
            let r = f.h.op(*i).unwrap();
            (r.author, r.spans.into_iter().map(|(_, s)| s).collect())
        })
        .collect();
    got.sort_by_key(|g| g.0);
    assert_eq!(got, [(user, su), (agent, sa)]);
}

#[test]
fn record_view_names_every_branch_head() {
    let mut f = fx();
    let b2 =
        f.h.branch("wt/b", BranchKind::Worktree, Some("c1"))
            .unwrap();
    let other = f.h.doc_for("b.txt").unwrap();
    f.h.activate(f.doc, b2, || Ok("abc\n".into())).unwrap();
    f.h.activate(other, f.br, || Ok("other\n".into())).unwrap();
    let agent =
        f.h.peer(&serde_json::json!({"run": "r1"}), Some(f.br))
            .unwrap();
    let spans = type_at(&mut f, agent, 0, "Q");
    let id =
        f.h.record(Record {
            kind: Kind::AgentStep,
            author: agent,
            cause: Cause {
                step: Some("4".into()),
                ..Cause::default()
            },
            spans: spans.iter().map(|s| (f.doc, *s)).collect(),
            parents: vec![],
            git: None,
            summary: "step 4".into(),
            at: 2.0,
        })
        .unwrap();
    let view = f.h.op(id).unwrap().view;
    let mut want = Vec::new();
    for (d, b) in [(f.doc, f.br), (f.doc, b2), (other, f.br)] {
        want.push((d, b, f.h.frontier(d, b).unwrap()));
    }
    want.sort_by_key(|w| (w.0, w.1));
    assert_eq!(view, want);
}

#[test]
fn revert_record_names_its_target() {
    let mut f = fx();
    let agent =
        f.h.peer(&serde_json::json!({"run": "r1"}), Some(f.br))
            .unwrap();
    let user =
        f.h.peer(&serde_json::json!({"user": 1}), Some(f.br))
            .unwrap();
    let rec = |kind, author, parents| Record {
        kind,
        author,
        cause: Cause::default(),
        spans: vec![],
        parents,
        git: None,
        summary: String::new(),
        at: 0.0,
    };
    let step = f.h.record(rec(Kind::AgentStep, agent, vec![])).unwrap();
    let rev = f.h.record(rec(Kind::Revert, user, vec![step])).unwrap();
    let r = f.h.op(rev).unwrap();
    assert_eq!((r.kind, r.parents), (Kind::Revert, vec![step]));
    // a redo is a revert of the revert
    let redo = f.h.record(rec(Kind::Redo, user, vec![rev])).unwrap();
    assert_eq!(f.h.op(redo).unwrap().parents, [rev]);
    for k in [Kind::Revert, Kind::Restore, Kind::Redo] {
        assert!(f.h.record(rec(k, user, vec![])).is_err(), "{k:?}");
    }
}
