//! Span revert: keep mine, the overlaps, roll back mine too, after a reload, a stale preview.
//! Pattern D (pure: a temporary folder and `git merge-file`, no clock; every time is a parameter).

use verdandi::{
    BranchId, BranchKind, Cause, Change, DocId, History, Kind, Mode, OpId, OverlapChoice, PeerId,
    Record,
};

const BASE: &str = "one\ntwo\nthree\nfour\n";

struct Fx {
    dir: tempfile::TempDir,
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
        dir,
        h,
        doc,
        br,
        agent,
        user,
    }
}

impl Fx {
    /// PEER's CHANGES as one record of KIND.
    fn step(&mut self, kind: Kind, peer: PeerId, changes: &[(usize, usize, &str)]) -> OpId {
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

    fn text(&mut self) -> String {
        self.h.text(self.doc, self.br).unwrap()
    }
}

/// Character offset of NEEDLE in HAY.
fn at(hay: &str, needle: &str) -> usize {
    hay[..hay.find(needle).unwrap()].chars().count()
}

#[test]
fn keep_mine_removes_only_agent_text() {
    let mut f = fx();
    let step = f.step(Kind::AgentStep, f.agent, &[(4, 0, "AGENT LINE\n")]);
    let t = f.text();
    f.step(Kind::Edits, f.user, &[(t.chars().count(), 0, "mine\n")]);
    let p = f.h.preview_revert(f.br, &[step]).unwrap();
    let want = "one\ntwo\nthree\nfour\nmine\n";
    assert!(p.overlaps.is_empty() && !p.threeway_differs);
    assert_eq!((p.files.len(), p.files[0].after.as_str()), (1, want));
    assert_eq!(
        f.text(),
        "one\nAGENT LINE\ntwo\nthree\nfour\nmine\n",
        "a preview changes nothing"
    );
    let rev =
        f.h.apply_revert(p.id, &[], Mode::KeepMine, f.user, 9.0)
            .unwrap();
    assert_eq!(f.text(), want);
    let r = f.h.op(rev).unwrap();
    assert_eq!((r.kind, r.parents, r.at), (Kind::Revert, vec![step], 9.0));
    assert!(!r.spans.is_empty(), "the revert's own operations");
    // a preview is applied once
    assert!(
        f.h.apply_revert(p.id, &[], Mode::KeepMine, f.user, 9.0)
            .is_err()
    );
}

#[test]
fn keep_mine_restores_text_agent_deleted() {
    let mut f = fx();
    // the agent deletes "two\n" and turns "three" into "3"
    let step = f.step(Kind::AgentStep, f.agent, &[(4, 4, ""), (4, 5, "3")]);
    assert_eq!(f.text(), "one\n3\nfour\n");
    f.step(Kind::Edits, f.user, &[(0, 0, "# ")]);
    let p = f.h.preview_revert(f.br, &[step]).unwrap();
    assert!(p.overlaps.is_empty() && !p.threeway_differs);
    f.h.apply_revert(p.id, &[], Mode::KeepMine, f.user, 1.0)
        .unwrap();
    assert_eq!(f.text(), "# one\ntwo\nthree\nfour\n");
}

#[test]
fn overlap_inside_agent_insert_is_a_hunk() {
    // the agent's text goes, its newline with it; the hunk is the user's ZZ
    for (choice, want) in [
        (OverlapChoice::KeepUsers, "one\nZZtwo\nthree\nfour\n"),
        (OverlapChoice::TakeReverted, BASE),
        (
            OverlapChoice::Edited("ok".into()),
            "one\noktwo\nthree\nfour\n",
        ),
    ] {
        let mut f = fx();
        let step = f.step(Kind::AgentStep, f.agent, &[(4, 0, "alpha beta\n")]);
        // the user types inside the agent's line
        let t = f.text();
        f.step(Kind::Edits, f.user, &[(at(&t, " beta"), 0, "ZZ")]);
        let p = f.h.preview_revert(f.br, &[step]).unwrap();
        assert_eq!(p.overlaps.len(), 1, "{choice:?}");
        assert_eq!(p.overlaps[0].users, "ZZ");
        f.h.apply_revert(
            p.id,
            std::slice::from_ref(&choice),
            Mode::KeepMine,
            f.user,
            1.0,
        )
        .unwrap();
        assert_eq!(f.text(), want, "{choice:?}");
    }
    // the user deleting a character of the agent's insert is an overlap too
    let mut f = fx();
    let step = f.step(Kind::AgentStep, f.agent, &[(4, 0, "alpha beta\n")]);
    let t = f.text();
    f.step(Kind::Edits, f.user, &[(at(&t, "beta"), 1, "")]);
    let p = f.h.preview_revert(f.br, &[step]).unwrap();
    assert_eq!(p.overlaps.len(), 1);
    assert_eq!(p.overlaps[0].users, "");
}

#[test]
fn roll_back_mine_moves_users_ops_to_undone() {
    let mut f = fx();
    let step = f.step(Kind::AgentStep, f.agent, &[(8, 0, "agent\n")]);
    f.step(Kind::Edits, f.user, &[(0, 3, "ONE")]);
    let before = f.text();
    assert_eq!(before, "ONE\ntwo\nagent\nthree\nfour\n");
    let p = f.h.preview_revert(f.br, &[step]).unwrap();
    let rev =
        f.h.apply_revert(p.id, &[], Mode::RollBackMine, f.user, 1.0)
            .unwrap();
    assert_eq!(f.text(), BASE, "the user's later edit is rolled back too");
    let undone =
        f.h.branch(&format!("undone/{}", rev.0), BranchKind::Undone, None)
            .unwrap();
    assert_eq!(f.h.text(f.doc, undone).unwrap(), before);
}

#[test]
fn revert_works_after_reload() {
    let mut f = fx();
    let step = f.step(
        Kind::AgentStep,
        f.agent,
        &[(0, 0, "agent says\n"), (19, 5, "")],
    );
    f.step(Kind::Edits, f.user, &[(0, 0, "! ")]);
    let now = f.text();
    // the hub restarts: a new document from the rows, with another local peer
    let Fx {
        dir,
        h,
        doc,
        br,
        user,
        ..
    } = f;
    drop(h);
    let mut h = History::open(dir.path()).unwrap();
    assert_eq!(h.text(doc, br).unwrap(), now);
    let p = h.preview_revert(br, &[step]).unwrap();
    assert!(!p.threeway_differs, "{:?}", p.files);
    h.apply_revert(p.id, &[], Mode::KeepMine, user, 1.0)
        .unwrap();
    assert_eq!(h.text(doc, br).unwrap(), "! one\ntwo\nthree\nfour\n");
}

#[test]
fn a_stale_preview_is_refused() {
    let mut f = fx();
    let step = f.step(Kind::AgentStep, f.agent, &[(0, 0, "x")]);
    let p = f.h.preview_revert(f.br, &[step]).unwrap();
    f.step(Kind::Edits, f.user, &[(0, 0, "y")]);
    let e =
        f.h.apply_revert(p.id, &[], Mode::KeepMine, f.user, 1.0)
            .unwrap_err();
    assert!(e.to_string().contains("stale"), "{e}");
    assert_eq!(f.text(), "yxone\ntwo\nthree\nfour\n");
}
