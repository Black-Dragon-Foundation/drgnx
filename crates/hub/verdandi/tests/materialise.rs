//! Materialise at a record: the project's documents as they were after a record, so a user's save (or an agent's step)
//! is a state a bisect can run.  Pattern D (pure: every time is a parameter).

use verdandi::{BranchKind, Cause, Change, DocId, History, Kind, OpId, PeerId, Record, Span};

struct Fx {
    _dir: tempfile::TempDir,
    h: History,
    br: verdandi::BranchId,
    user: PeerId,
    agent: PeerId,
}

fn fx() -> Fx {
    let dir = tempfile::tempdir().unwrap();
    let mut h = History::open(dir.path()).unwrap();
    let br = h.branch("wt/a", BranchKind::Worktree, Some("c1")).unwrap();
    let user = h.peer(&serde_json::json!({"user": 1}), Some(br)).unwrap();
    let agent = h.peer(&serde_json::json!({"run": "r1"}), Some(br)).unwrap();
    Fx {
        _dir: dir,
        h,
        br,
        user,
        agent,
    }
}

impl Fx {
    fn doc(&mut self, path: &str, base: &str) -> DocId {
        let d = self.h.doc_for(path).unwrap();
        let base = base.to_owned();
        self.h.activate(d, self.br, move || Ok(base)).unwrap();
        d
    }

    /// PEER's change to DOC as one record of KIND at AT, with CAUSE.
    #[allow(clippy::too_many_arguments)]
    fn step(
        &mut self,
        doc: DocId,
        kind: Kind,
        peer: PeerId,
        start: usize,
        old: usize,
        ins: &str,
        at: f64,
        cause: Cause,
    ) -> OpId {
        let spans: Vec<(DocId, Span)> = self
            .h
            .activate(doc, self.br, || unreachable!())
            .unwrap()
            .apply(
                peer,
                &Change {
                    start,
                    old_len: old,
                    inserted: ins.into(),
                },
            )
            .unwrap()
            .into_iter()
            .map(|s| (doc, s))
            .collect();
        self.h
            .record(Record {
                kind,
                author: peer,
                cause,
                spans,
                parents: vec![],
                git: None,
                summary: String::new(),
                at,
            })
            .unwrap()
    }
}

#[test]
fn every_document_as_it_was_after_a_record() {
    let mut f = fx();
    let a = f.doc("a.py", "x = 1\n");
    let b = f.doc("lib/b.py", "def f():\n    pass\n");
    let user = f.user;
    let agent = f.agent;
    let s1 = f.step(a, Kind::Save, user, 4, 1, "2", 10.0, Cause::default());
    let step = Cause {
        step: Some("s7".into()),
        decision: Some("dec-1".into()),
        ..Cause::default()
    };
    let s2 = f.step(b, Kind::AgentStep, agent, 13, 4, "return 3", 20.0, step);
    let s3 = f.step(a, Kind::Save, user, 4, 1, "9", 30.0, Cause::default());
    // a document that only came later
    let c = f.doc("new.py", "");
    let s4 = f.step(c, Kind::Save, user, 0, 0, "y = 0\n", 40.0, Cause::default());

    let at = |h: &mut History, op| {
        let mut v = h.texts_after(f.br, op).unwrap();
        v.sort();
        v
    };
    assert_eq!(
        at(&mut f.h, s1),
        vec![
            ("a.py".to_owned(), "x = 2\n".to_owned()),
            ("lib/b.py".to_owned(), "def f():\n    pass\n".to_owned())
        ]
    );
    assert_eq!(
        at(&mut f.h, s2)[1],
        ("lib/b.py".to_owned(), "def f():\n    return 3\n".to_owned())
    );
    assert_eq!(at(&mut f.h, s3)[0].1, "x = 9\n");
    // new.py did not exist after s3; after s4 it does
    assert_eq!(at(&mut f.h, s3).len(), 2);
    assert_eq!(
        at(&mut f.h, s4)[2],
        ("new.py".to_owned(), "y = 0\n".to_owned())
    );
}

#[test]
fn the_records_a_bisect_can_stop_at() {
    let mut f = fx();
    let a = f.doc("a.py", "x = 1\n");
    let (user, agent) = (f.user, f.agent);
    let s1 = f.step(a, Kind::Save, user, 4, 1, "2", 10.0, Cause::default());
    let e = f.step(a, Kind::Edits, user, 4, 1, "3", 15.0, Cause::default());
    let s2 = f.step(a, Kind::AgentStep, agent, 4, 1, "4", 20.0, Cause::default());
    let kinds = [Kind::Save, Kind::AgentStep];
    let all: Vec<OpId> =
        f.h.records_on(f.br, None, &kinds)
            .unwrap()
            .into_iter()
            .map(|r| r.id)
            .collect();
    assert_eq!(all, vec![s1, s2]);
    // after a record: only the later ones; typing (edits) is never a state
    let later: Vec<OpId> =
        f.h.records_on(f.br, Some(s1), &kinds)
            .unwrap()
            .into_iter()
            .map(|r| r.id)
            .collect();
    assert_eq!(later, vec![s2]);
    assert!(!all.contains(&e));
}
