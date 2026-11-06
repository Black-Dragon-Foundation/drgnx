//! Merges: the union keeps every element id, a conflict resolved by the user is one correction, and rebased work finds
//! its source by diff.  Pattern D (pure: no process but `git merge-file` for reverts, no clock; every time is a parameter).

use std::collections::HashMap;
use verdandi::{BranchId, BranchKind, Change, DocId, History, Kind, OpId, PeerId, Span};

const BASE: &str = "one\ntwo\nthree\nfour\n";

struct Fx {
    _dir: tempfile::TempDir,
    h: History,
    doc: DocId,
    /// The merge target.
    a: BranchId,
    /// The source, at the same commit (so it shares the target's seed).
    b: BranchId,
    pa: PeerId,
    pb: PeerId,
    merger: PeerId,
}

fn fx() -> Fx {
    let dir = tempfile::tempdir().unwrap();
    let mut h = History::open(dir.path()).unwrap();
    let doc = h.doc_for("f.txt").unwrap();
    let a = h.branch("wt/a", BranchKind::Worktree, Some("c1")).unwrap();
    let b = h.branch("wt/b", BranchKind::Worktree, Some("c1")).unwrap();
    h.activate(doc, a, || Ok(BASE.into())).unwrap();
    h.activate(doc, b, || unreachable!("b shares a's seed"))
        .unwrap();
    let pa = h.peer(&serde_json::json!({"user": "a"}), Some(a)).unwrap();
    let pb = h.peer(&serde_json::json!({"user": "b"}), Some(b)).unwrap();
    let merger = h.peer(&serde_json::json!({"user": "m"}), Some(a)).unwrap();
    Fx {
        _dir: dir,
        h,
        doc,
        a,
        b,
        pa,
        pb,
        merger,
    }
}

impl Fx {
    fn edit(&mut self, br: BranchId, peer: PeerId, start: usize, old: usize, ins: &str) {
        self.h
            .activate(self.doc, br, || unreachable!())
            .unwrap()
            .apply(
                peer,
                &Change {
                    start,
                    old_len: old,
                    inserted: ins.into(),
                },
            )
            .unwrap();
    }

    fn text(&mut self, br: BranchId) -> String {
        self.h.text(self.doc, br).unwrap()
    }

    fn merge(&mut self, git: &str) -> OpId {
        let m = HashMap::from([("f.txt".to_string(), git.to_string())]);
        self.h
            .record_merge(self.a, self.b, &m, self.merger, 7.0)
            .unwrap()
    }
}

fn spans_of(h: &History, op: OpId) -> Vec<(DocId, Span)> {
    h.op(op).unwrap().spans
}

#[test]
fn clean_merge_keeps_ids_and_anchors() {
    let mut f = fx();
    f.edit(f.a, f.pa, 0, 0, "TGT\n");
    f.edit(f.b, f.pb, BASE.chars().count(), 0, "SRC\n");
    let (ids_a, ids_b) = (
        f.h.element_ids(f.doc, f.a).unwrap(),
        f.h.element_ids(f.doc, f.b).unwrap(),
    );
    let git = format!("TGT\n{BASE}SRC\n");
    let op = f.merge(&git);
    assert_eq!(f.text(f.a), git);
    let after = f.h.element_ids(f.doc, f.a).unwrap();
    for id in ids_a.iter().chain(&ids_b) {
        assert!(after.contains(id), "{id:?} lost its id in the merge");
    }
    let r = f.h.op(op).unwrap();
    assert_eq!(r.kind, Kind::Merge);
    assert!(
        r.spans.is_empty(),
        "git agreed with the union: no correction"
    );
    assert!(f.h.provenance(op).unwrap().is_empty());
}

#[test]
fn conflicting_merge_adds_one_correction_op() {
    let mut f = fx();
    f.edit(f.a, f.pa, 4, 3, "TWO-A");
    f.edit(f.b, f.pb, 4, 3, "TWO-B");
    let ids_before = f.h.element_ids(f.doc, f.a).unwrap();
    let git = "one\nTWO-A and TWO-B\nthree\nfour\n";
    let op = f.merge(git);
    assert_eq!(f.text(f.a), git);
    let spans = spans_of(&f.h, op);
    assert_eq!(spans.len(), 1, "one correction: {spans:?}");
    assert_eq!(spans[0].1.peer, f.merger);
    // the lines the conflict did not touch keep their ids
    let after = f.h.element_ids(f.doc, f.a).unwrap();
    let kept = ids_before.iter().filter(|i| after.contains(i)).count();
    assert!(kept >= "one\n".len() + "three\nfour\n".len(), "{kept}");
}

#[test]
fn rebased_work_falls_back_to_provenance() {
    let mut f = fx();
    // the source was rebased: its documents start from another commit, so the two share no element ids
    let r =
        f.h.branch("wt/r", BranchKind::Worktree, Some("c9"))
            .unwrap();
    f.h.activate(f.doc, r, || Ok(BASE.into())).unwrap();
    let pr =
        f.h.peer(&serde_json::json!({"user": "r"}), Some(r))
            .unwrap();
    f.edit(r, pr, 4, 3, "TWO");
    f.edit(f.a, f.pa, 14, 4, "FOUR");
    let git = "one\nTWO\nthree\nFOUR\n";
    let m = HashMap::from([("f.txt".to_string(), git.to_string())]);
    let op = f.h.record_merge(f.a, r, &m, f.merger, 7.0).unwrap();
    assert_eq!(f.text(f.a), git);
    assert_eq!(spans_of(&f.h, op).len(), 1, "one correction");
    let prov = f.h.provenance(op).unwrap();
    assert!(
        prov.iter().any(|(d, s)| *d == f.doc && s.peer == pr),
        "the rebased line is traced to the source: {prov:?}"
    );
}
