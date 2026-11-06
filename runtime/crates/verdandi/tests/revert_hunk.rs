//! The selective revert of one record, per hunk: a record's hunks, one rejected while the others stay, the user's later
//! typing kept, a hunk whose old text has no place to go back to, and who undid a hunk.
//! Pattern D (pure: a temporary folder, no clock; every time is a parameter).

use verdandi::{
    BranchId, BranchKind, Cause, Change, DocId, History, HunkPlan, HunkState, Kind, OpId, PeerId,
    Record,
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
    let agent = h
        .peer(
            &serde_json::json!({"kind": "agent", "session": "s9"}),
            Some(br),
        )
        .unwrap();
    let user = h
        .peer(&serde_json::json!({"kind": "user"}), Some(br))
        .unwrap();
    Fx {
        _dir: dir,
        h,
        doc,
        br,
        agent,
        user,
    }
}

impl Fx {
    /// PEER's CHANGES as one `edits` record.
    fn step(&mut self, peer: PeerId, changes: &[(usize, usize, &str)]) -> OpId {
        let mut spans = Vec::new();
        for (start, old_len, inserted) in changes {
            let s = self
                .h
                .activate(self.doc, self.br, || unreachable!())
                .unwrap()
                .apply(
                    peer,
                    &Change {
                        start: *start,
                        old_len: *old_len,
                        inserted: (*inserted).into(),
                    },
                )
                .unwrap();
            spans.extend(s.into_iter().map(|s| (self.doc, s)));
        }
        self.h
            .record(Record {
                kind: Kind::Edits,
                author: peer,
                cause: Cause {
                    session: Some("s9".into()),
                    ..Cause::default()
                },
                spans,
                parents: vec![],
                git: None,
                summary: String::new(),
                at: 0.0,
            })
            .unwrap()
    }

    fn text(&mut self) -> String {
        self.h.text(self.doc, self.br).unwrap()
    }

    /// Reject hunk INDEX of OP as the user; the revert record.
    fn reject(&mut self, op: OpId, index: usize) -> OpId {
        let changes = match self
            .h
            .plan_hunk_revert(self.br, op, self.doc, index)
            .unwrap()
        {
            HunkPlan::Edits(c) => c,
            other => panic!("not revertible: {other:?}"),
        };
        assert!(!changes.is_empty());
        self.h
            .apply_hunk_revert(self.br, op, self.doc, &changes, self.user, 7.0)
            .unwrap()
    }
}

/// Character offset of NEEDLE in HAY.
fn at(hay: &str, needle: &str) -> usize {
    hay[..hay.find(needle).unwrap()].chars().count()
}

#[test]
fn a_record_has_a_hunk_per_place_it_changed() {
    let mut f = fx();
    // a new line after "one", and "four" made "4"
    let step = f.step(f.agent, &[(4, 0, "AGENT\n"), (20, 4, "4")]);
    assert_eq!(f.text(), "one\nAGENT\ntwo\nthree\n4\n");
    let hunks = f.h.op_hunks(f.br, step).unwrap();
    let got: Vec<_> = hunks
        .iter()
        .map(|h| {
            (
                h.index,
                h.start_line,
                h.end_line,
                h.text.as_str(),
                h.deleted.as_str(),
                h.state,
            )
        })
        .collect();
    assert_eq!(
        got,
        vec![
            (0, 2, 2, "AGENT\n", "", HunkState::Live),
            (1, 5, 5, "4", "four", HunkState::Live),
        ]
    );
    assert!(hunks.iter().all(|h| h.op == step && h.path == "f.txt"));
    assert!(hunks.iter().all(|h| h.undone_by.is_empty()));
}

#[test]
fn rejecting_one_hunk_leaves_the_others() {
    let mut f = fx();
    let step = f.step(f.agent, &[(4, 0, "AGENT\n"), (20, 4, "4")]);
    let rev = f.reject(step, 1);
    assert_eq!(f.text(), "one\nAGENT\ntwo\nthree\nfour\n");
    let r = f.h.op(rev).unwrap();
    assert_eq!(
        (r.kind, r.parents, r.author),
        (Kind::Revert, vec![step], f.user)
    );
    assert_eq!(r.cause.session.as_deref(), Some("s9"), "the agent's cause");
    let hunks = f.h.op_hunks(f.br, step).unwrap();
    assert_eq!(hunks[0].state, HunkState::Live);
    assert_eq!(hunks[1].state, HunkState::Undone);
    assert_eq!(hunks[1].undone_by, vec![rev]);
}

#[test]
fn typing_inside_the_hunk_survives_a_reject() {
    let mut f = fx();
    let step = f.step(f.agent, &[(4, 0, "alpha beta\n")]);
    let t = f.text();
    // the user types inside the agent's line, and at the end of the file
    let typed = f.step(f.user, &[(at(&t, " beta"), 0, "ZZ")]);
    let t = f.text();
    f.step(f.user, &[(t.chars().count(), 0, "five\n")]);
    f.reject(step, 0);
    assert_eq!(f.text(), "one\nZZtwo\nthree\nfour\nfive\n");
    let blame = f.h.blame(f.doc, f.br, 4..6).unwrap();
    assert_eq!(
        (blame.len(), blame[0].op),
        (1, typed),
        "the user's characters are the same ones"
    );
}

#[test]
fn old_text_with_no_place_to_go_back_to_conflicts() {
    // "two" made "2", and the user typed right beside it: the old text and the user's meet
    let mut f = fx();
    let step = f.step(f.agent, &[(4, 3, "2")]);
    f.step(f.user, &[(4, 0, "X")]);
    let before = f.text();
    assert_eq!(before, "one\nX2\nthree\nfour\n");
    match f.h.plan_hunk_revert(f.br, step, f.doc, 0).unwrap() {
        HunkPlan::Conflict(c) => {
            assert_eq!((c.start_line, c.end_line), (2, 2));
            assert_eq!((c.users.as_str(), c.reverted.as_str()), ("X", "two"));
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(f.text(), before, "a conflict changes nothing");
    // the agent deleted "two\n" and the user deleted the line it sat after
    let mut f = fx();
    let step = f.step(f.agent, &[(4, 4, "")]);
    f.step(f.user, &[(0, 4, "")]);
    assert!(matches!(
        f.h.plan_hunk_revert(f.br, step, f.doc, 0).unwrap(),
        HunkPlan::Conflict(_)
    ));
}

#[test]
fn a_users_undo_is_who_undid_the_hunk() {
    // the user's C-/ of an insert deletes it; of a replacement, deletes the new text and inserts the old again
    let mut f = fx();
    let step = f.step(f.agent, &[(4, 0, "AGENT\n"), (20, 4, "4")]);
    assert_eq!(f.text(), "one\nAGENT\ntwo\nthree\n4\n");
    let undo = f.step(f.user, &[(20, 1, "four"), (4, 6, "")]);
    assert_eq!(f.text(), BASE);
    let hunks = f.h.op_hunks(f.br, step).unwrap();
    for h in &hunks {
        assert_eq!(
            (h.state, &h.undone_by),
            (HunkState::Undone, &vec![undo]),
            "{h:?}"
        );
    }
    assert!(matches!(
        f.h.plan_hunk_revert(f.br, step, f.doc, 0).unwrap(),
        HunkPlan::Undone(by) if by == vec![undo]
    ));
    // part of it undone
    let mut f = fx();
    let step = f.step(f.agent, &[(4, 0, "AGENT\n")]);
    let undo = f.step(f.user, &[(4, 2, "")]);
    let h = &f.h.op_hunks(f.br, step).unwrap()[0];
    assert_eq!(
        (h.state, h.text.as_str()),
        (HunkState::PartlyUndone, "ENT\n")
    );
    assert_eq!(h.undone_by, vec![undo]);
}

#[test]
fn a_sessions_records_on_a_branch() {
    let mut f = fx();
    let a = f.step(f.agent, &[(0, 0, "x")]);
    f.step(f.user, &[(0, 0, "y")]);
    let b = f.step(f.agent, &[(0, 0, "z")]);
    assert_eq!(f.h.records_of(f.br, "s9").unwrap(), vec![a, b]);
    assert!(f.h.records_of(f.br, "s1").unwrap().is_empty());
}
