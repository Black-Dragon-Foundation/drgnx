//! Size, expiry and compaction: a cut never passes a live reference, expired branches stop pinning, a pinned branch
//! never expires, a revert past the cut is refused with its reason, and what pins the size can be named.
//! Pattern D (pure: a temporary folder, no clock; `now` is a parameter).

use verdandi::{
    BranchId, BranchKind, Cause, Change, DocId, History, Kind, Mode, OpId, PeerId, PinKind, Record,
    Side, When,
};

const BASE: &str = "one\ntwo\nthree\nfour\n";
const DAY: f64 = 86_400.0;

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

impl Fx {
    fn step(&mut self, kind: Kind, peer: PeerId, ins: &str) -> OpId {
        let spans = self
            .h
            .activate(self.doc, self.br, || unreachable!())
            .unwrap()
            .apply(
                peer,
                &Change {
                    start: 0,
                    old_len: 0,
                    inserted: ins.into(),
                },
            )
            .unwrap()
            .into_iter()
            .map(|s| (self.doc, s))
            .collect();
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

    /// An agent step rolled back at AT: the branch `undone/<record>` holds the text set aside.
    fn rolled_back(&mut self, at: f64) -> (OpId, BranchId) {
        let step = self.step(Kind::AgentStep, self.agent, "AGENT\n");
        let p = self.h.preview_revert(self.br, &[step]).unwrap();
        let rev = self
            .h
            .apply_revert(p.id, &[], Mode::RollBackMine, self.user, at)
            .unwrap();
        let ub = self
            .h
            .branch(&format!("undone/{}", rev.0), BranchKind::Undone, None)
            .unwrap();
        (rev, ub)
    }
}

#[test]
fn expired_branches_stop_pinning() {
    let mut f = fx();
    let (rev, ub) = f.rolled_back(10.0);
    let name = format!("undone/{}", rev.0);
    let pins = f.h.pins().unwrap();
    let p = pins.iter().find(|p| p.name == name).expect("it pins");
    assert_eq!(p.kind, PinKind::Undone);
    assert!(p.bytes > 0);
    assert!(
        f.h.expire(10.0 + 89.0 * DAY).unwrap().is_empty(),
        "not yet 90 days"
    );
    let before = f.h.size().unwrap();
    assert_eq!(f.h.expire(10.0 + 91.0 * DAY).unwrap(), vec![ub]);
    assert!(f.h.pins().unwrap().iter().all(|p| p.name != name));
    assert!(f.h.size().unwrap() <= before);
    // the live branch is not touched
    assert!(f.h.text(f.doc, f.br).unwrap().starts_with("one"));
    assert!(f.h.redo_part(rev, f.br, &[f.doc], f.user, 1e9).is_err());
}

#[test]
fn pinned_branch_never_expires() {
    let mut f = fx();
    let (rev, ub) = f.rolled_back(10.0);
    f.h.pin(ub, true).unwrap();
    assert!(f.h.expire(10.0 + 900.0 * DAY).unwrap().is_empty());
    let pins = f.h.pins().unwrap();
    let p = pins
        .iter()
        .find(|p| p.name == format!("undone/{}", rev.0))
        .unwrap();
    assert_eq!(p.kind, PinKind::Pinned);
    f.h.pin(ub, false).unwrap();
    assert_eq!(f.h.expire(10.0 + 900.0 * DAY).unwrap(), vec![ub]);
}

#[test]
fn cut_never_passes_a_live_reference() {
    let mut f = fx();
    let r1 = f.step(Kind::Edits, f.user, "a\n");
    let r2 = f.step(Kind::Edits, f.user, "b\n");
    // an anchor made after r2 needs the history from r2 on
    let a = f.h.anchor(f.doc, f.br, 1, Side::Right, "review").unwrap();
    let now_line = f.h.resolve(a, When::Now).unwrap();
    let rs: Vec<OpId> = ["c\n", "d\n", "e\n"]
        .iter()
        .map(|t| f.step(Kind::Edits, f.user, t))
        .collect();
    let done = f.h.compact_keeping(0, 2, f.user, 9.0).unwrap();
    assert_eq!(done.cuts, 1);
    assert_eq!(
        f.h.cut(f.doc, f.br).unwrap(),
        Some(r2),
        "not past the anchor"
    );
    let then = f.h.resolve(a, When::Then).unwrap();
    assert_eq!(then.text_then.as_deref(), Some("b"));
    assert_eq!(
        f.h.resolve(a, When::Now).unwrap().pos,
        now_line.pos + "c\nd\ne\n".len()
    );
    // records after the cut still revert
    f.h.preview_revert(f.br, &[rs[2]]).unwrap();
    assert!(f.h.preview_revert(f.br, &[r1]).is_err());
    // the compaction is a record
    let last = (1..=20).map(OpId).filter_map(|i| f.h.op(i).ok()).last();
    assert_eq!(last.unwrap().kind, Kind::Compact);
}

#[test]
fn revert_past_cut_is_refused_with_reason() {
    let mut f = fx();
    let rs: Vec<OpId> = ["a\n", "b\n", "c\n", "d\n", "e\n"]
        .iter()
        .map(|t| f.step(Kind::Edits, f.user, t))
        .collect();
    let before = f.h.size().unwrap();
    f.h.compact_keeping(0, 2, f.user, 9.0).unwrap();
    assert_eq!(f.h.cut(f.doc, f.br).unwrap(), Some(rs[2]));
    let e = f.h.preview_revert(f.br, &[rs[0]]).unwrap_err().to_string();
    assert!(e.contains("compacted"), "{e}");
    assert!(f.h.preview_revert(f.br, &[rs[2]]).is_err());
    let p = f.h.preview_revert(f.br, &[rs[4]]).unwrap();
    f.h.apply_revert(p.id, &[], Mode::KeepMine, f.user, 10.0)
        .unwrap();
    assert_eq!(
        f.h.text(f.doc, f.br).unwrap(),
        format!("d\nc\nb\na\n{BASE}")
    );
    // the text and a reload are as before
    f.h.park(f.doc, f.br).unwrap();
    assert_eq!(
        f.h.text(f.doc, f.br).unwrap(),
        format!("d\nc\nb\na\n{BASE}")
    );
    assert!(f.h.size().unwrap() > 0 && before > 0);
    // under the cap nothing is cut
    let again = f.h.compact(u64::MAX, f.user, 11.0).unwrap();
    assert_eq!(again.cuts, 0);
}

#[test]
fn doctor_names_what_pins_size() {
    let mut f = fx();
    let (rev, ub) = f.rolled_back(10.0);
    let fork_at = f.step(Kind::Edits, f.user, "x\n");
    let fb = f.h.fork(fork_at, f.br, "fork/x", f.user, 11.0).unwrap();
    f.h.pin(fb, true).unwrap();
    f.h.anchor(f.doc, f.br, 1, Side::Right, "ledger").unwrap();
    f.h.anchor(f.doc, f.br, 2, Side::Right, "ledger").unwrap();
    let pins = f.h.pins().unwrap();
    let find = |k: PinKind| pins.iter().find(|p| p.kind == k).map(|p| p.name.clone());
    assert_eq!(find(PinKind::Pinned).as_deref(), Some("fork/x"));
    assert_eq!(
        find(PinKind::Undone).as_deref(),
        Some(format!("undone/{}", rev.0).as_str())
    );
    assert_eq!(
        find(PinKind::Anchors).as_deref(),
        Some("ledger (2 anchors)")
    );
    // the biggest first
    assert!(
        pins.windows(2).all(|w| w[0].bytes >= w[1].bytes),
        "{pins:?}"
    );
    assert!(f.h.size().unwrap() > pins.iter().map(|p| p.bytes).max().unwrap());
    let _ = ub;
}
