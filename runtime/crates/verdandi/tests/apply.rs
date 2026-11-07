//! Redo, fork, compare and take across: a revert reverted, a part redone by diff with provenance, a branch from a
//! record, the hunks two branches differ by and the whole hunks taken from one into the other.
//! Pattern D (pure: a temporary folder and `git merge-file`, no clock; every time is a parameter).

use verdandi::{
    BranchId, BranchKind, Cause, Change, DocId, History, HunkRef, Kind, Mode, OpId, PeerId, Record,
    Span,
};

const BASE: &str = "one\ntwo\nthree\nfour\n";

struct Fx {
    _dir: tempfile::TempDir,
    h: History,
    doc: DocId,
    br: BranchId,
    agent: PeerId,
    user: PeerId,
}

fn fx() -> Fx {
    let dir = tempfile::tempdir().unwrap();
    let mut h = History::open(dir.path()).unwrap();
    let doc = h.doc_for("f.txt").unwrap();
    let br = h.branch("wt/a", BranchKind::Worktree, Some("c1")).unwrap();
    h.activate(doc, br, || Ok(BASE.into())).unwrap();
    let agent = h.peer(&serde_json::json!({"run": "r1"}), Some(br)).unwrap();
    let user = h.peer(&serde_json::json!({"user": 1}), Some(br)).unwrap();
    Fx {
        _dir: dir,
        h,
        doc,
        br,
        agent,
        user,
    }
}

/// PEER's change in DOC on BR; the element ids it made.
fn edit(
    h: &mut History,
    doc: DocId,
    br: BranchId,
    peer: PeerId,
    start: usize,
    old_len: usize,
    inserted: &str,
) -> Vec<(DocId, Span)> {
    h.activate(doc, br, || unreachable!())
        .unwrap()
        .apply(
            peer,
            &Change {
                start,
                old_len,
                inserted: inserted.into(),
            },
        )
        .unwrap()
        .into_iter()
        .map(|s| (doc, s))
        .collect()
}

fn record(h: &mut History, kind: Kind, peer: PeerId, spans: Vec<(DocId, Span)>) -> OpId {
    h.record(Record {
        kind,
        author: peer,
        cause: Cause::default(),
        spans,
        parents: vec![],
        git: None,
        summary: String::new(),
        at: 0.0,
    })
    .unwrap()
}

#[test]
fn redo_is_revert_of_revert() {
    let mut f = fx();
    let s = edit(&mut f.h, f.doc, f.br, f.agent, 4, 0, "AGENT\n");
    let step = record(&mut f.h, Kind::AgentStep, f.agent, s);
    let with = f.h.text(f.doc, f.br).unwrap();
    let p = f.h.preview_revert(f.br, &[step]).unwrap();
    let rev =
        f.h.apply_revert(p.id, &[], Mode::KeepMine, f.user, 1.0)
            .unwrap();
    assert_eq!(f.h.text(f.doc, f.br).unwrap(), BASE);
    let redo = f.h.redo(rev, f.br, &[], f.user, 2.0).unwrap();
    assert_eq!(f.h.text(f.doc, f.br).unwrap(), with);
    let r = f.h.op(redo).unwrap();
    assert_eq!((r.kind, r.parents, r.at), (Kind::Redo, vec![rev], 2.0));
    // only a revert can be redone
    assert!(f.h.redo(step, f.br, &[], f.user, 3.0).is_err());
}

#[test]
fn redo_part_applies_by_diff_with_provenance() {
    let mut f = fx();
    let doc2 = f.h.doc_for("g.txt").unwrap();
    f.h.activate(doc2, f.br, || Ok(BASE.into())).unwrap();
    let mut s = edit(&mut f.h, f.doc, f.br, f.agent, 0, 0, "A1\n");
    s.extend(edit(&mut f.h, doc2, f.br, f.agent, 0, 0, "A2\n"));
    let step = record(&mut f.h, Kind::AgentStep, f.agent, s);
    let p = f.h.preview_revert(f.br, &[step]).unwrap();
    let rev =
        f.h.apply_revert(p.id, &[], Mode::RollBackMine, f.user, 1.0)
            .unwrap();
    assert_eq!(f.h.text(f.doc, f.br).unwrap(), BASE);
    assert_eq!(f.h.text(doc2, f.br).unwrap(), BASE);

    let redo = f.h.redo_part(rev, f.br, &[f.doc], f.user, 2.0).unwrap();
    assert_eq!(f.h.text(f.doc, f.br).unwrap(), format!("A1\n{BASE}"));
    assert_eq!(f.h.text(doc2, f.br).unwrap(), BASE, "the other file stays");
    let r = f.h.op(redo).unwrap();
    assert_eq!((r.kind, r.parents), (Kind::Redo, vec![rev]));
    let prov = f.h.provenance(redo).unwrap();
    assert!(!prov.is_empty());
    assert!(
        prov.iter().all(|(d, s)| *d == f.doc && s.peer == f.agent),
        "the source spans are the agent's elements in the file redone: {prov:?}"
    );
    // a keep mine revert kept no copy to redo from by diff
    let s = edit(&mut f.h, f.doc, f.br, f.agent, 0, 0, "B\n");
    let step = record(&mut f.h, Kind::AgentStep, f.agent, s);
    let p = f.h.preview_revert(f.br, &[step]).unwrap();
    let keep =
        f.h.apply_revert(p.id, &[], Mode::KeepMine, f.user, 3.0)
            .unwrap();
    assert!(f.h.redo_part(keep, f.br, &[f.doc], f.user, 4.0).is_err());
}

#[test]
fn fork_starts_at_record_frontier() {
    let mut f = fx();
    let s = edit(&mut f.h, f.doc, f.br, f.agent, 0, 0, "L1\n");
    let op1 = record(&mut f.h, Kind::AgentStep, f.agent, s);
    let s = edit(&mut f.h, f.doc, f.br, f.user, 0, 0, "L2\n");
    record(&mut f.h, Kind::Edits, f.user, s);
    let fb = f.h.fork(op1, f.br, "fork/x", f.user, 3.0).unwrap();
    assert_eq!(f.h.text(f.doc, fb).unwrap(), format!("L1\n{BASE}"));
    assert_eq!(
        f.h.text(f.doc, f.br).unwrap(),
        format!("L2\nL1\n{BASE}"),
        "the source branch is untouched"
    );
    assert_eq!(f.h.base_of(fb).unwrap().as_deref(), Some("c1"));
    // the fork is a record whose parent is where it started
    let rec = (1..=10).map(OpId).find_map(|i| {
        let r = f.h.op(i).ok()?;
        (r.kind == Kind::Fork).then_some(r)
    });
    assert_eq!(rec.unwrap().parents, vec![op1]);
    // the same name twice is refused
    assert!(f.h.fork(op1, f.br, "fork/x", f.user, 4.0).is_err());
}

/// A fork of the first record with the second agent's changes in it: (fork, that agent, the record).
fn forked(f: &mut Fx, changes: &[(usize, usize, &str)]) -> (BranchId, PeerId, OpId) {
    let s = edit(&mut f.h, f.doc, f.br, f.agent, 0, 0, "L1\n");
    let op1 = record(&mut f.h, Kind::AgentStep, f.agent, s);
    let fb = f.h.fork(op1, f.br, "fork/x", f.user, 1.0).unwrap();
    let agent2 =
        f.h.peer(&serde_json::json!({"run": "r2"}), Some(fb))
            .unwrap();
    let mut spans = Vec::new();
    for (start, old, ins) in changes {
        spans.extend(edit(&mut f.h, f.doc, fb, agent2, *start, *old, ins));
    }
    let op2 = record(&mut f.h, Kind::AgentStep, agent2, spans);
    (fb, agent2, op2)
}

#[test]
fn compare_names_author_and_step_per_hunk() {
    let mut f = fx();
    let (fb, agent2, op2) = forked(&mut f, &[(3, 0, "NEW\n")]);
    let files = f.h.compare(f.br, fb).unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].path, "f.txt");
    let hunks = &files[0].hunks;
    assert_eq!(hunks.len(), 1);
    let h = &hunks[0];
    assert_eq!(h.theirs_text, "NEW\n");
    assert_eq!(h.ours_text, "");
    assert_eq!((h.author, h.step), (Some(agent2), Some(op2)));
    // the same branch differs from itself nowhere
    assert!(
        f.h.compare(f.br, f.br)
            .unwrap()
            .iter()
            .all(|d| d.hunks.is_empty())
    );
}

#[test]
fn take_across_never_imports_a_subset() {
    let mut f = fx();
    let end = BASE.chars().count() + 3;
    let (fb, agent2, _) = forked(&mut f, &[(3, 0, "XX\n"), (end, 0, "YY\n")]);
    let files = f.h.compare(f.br, fb).unwrap();
    let hunks = &files[0].hunks;
    assert_eq!(hunks.len(), 2, "{hunks:?}");
    // part of a hunk is refused, and nothing changed
    let cut = HunkRef {
        doc: f.doc,
        theirs_start: hunks[0].theirs_start,
        theirs_end: hunks[0].theirs_end - 1,
    };
    let before = f.h.text(f.doc, f.br).unwrap();
    assert!(f.h.take(fb, f.br, &[cut], f.user, 2.0).is_err());
    assert_eq!(f.h.text(f.doc, f.br).unwrap(), before);
    // one whole hunk comes across, the other does not
    let op =
        f.h.take(fb, f.br, &[hunks[0].as_ref()], f.user, 3.0)
            .unwrap();
    let now = f.h.text(f.doc, f.br).unwrap();
    assert!(now.contains("XX\n") && !now.contains("YY\n"), "{now}");
    let prov = f.h.provenance(op).unwrap();
    assert!(!prov.is_empty() && prov.iter().all(|(_, s)| s.peer == agent2));
    // the rest comes across too: the two texts are the same
    let rest = f.h.compare(f.br, fb).unwrap();
    let refs: Vec<HunkRef> = rest[0].hunks.iter().map(|h| h.as_ref()).collect();
    assert_eq!(refs.len(), 1);
    f.h.take(fb, f.br, &refs, f.user, 4.0).unwrap();
    assert_eq!(f.h.text(f.doc, f.br).unwrap(), f.h.text(f.doc, fb).unwrap());
}
