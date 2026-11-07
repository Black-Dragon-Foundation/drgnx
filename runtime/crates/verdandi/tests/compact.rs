//! Size, expiry and compaction: a cut never passes a live reference, expired branches stop pinning, a pinned branch
//! never expires, a dropped fork expires as a frozen worktree does, a revert past the cut is refused with its reason,
//! and what pins the size can be named.
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
    let rs = pile(&mut f);
    let shift: usize = (0..60).map(|i| format!("l{i}\n").len()).sum();
    let done = f.h.compact(0, f.user, 9.0).unwrap();
    assert_eq!(done.cuts, 1);
    assert_eq!(
        f.h.cut(f.doc, f.br).unwrap(),
        Some(r2),
        "not past the anchor, though 60 records are newer"
    );
    let then = f.h.resolve(a, When::Then).unwrap();
    assert_eq!(then.text_then.as_deref(), Some("b"));
    assert_eq!(f.h.resolve(a, When::Now).unwrap().pos, now_line.pos + shift);
    // records after the cut still revert
    f.h.preview_revert(f.br, &[rs[59]]).unwrap();
    assert!(f.h.preview_revert(f.br, &[r1]).is_err());
    // the compaction is a record that stays
    let n = f.h.count("op").unwrap();
    assert_eq!(f.h.op(OpId(n)).unwrap().kind, Kind::Compact);
    assert!(f.h.op(r1).is_ok(), "the records stay");

    // a live branch pins the cut at its first record
    let mut f = fx();
    f.step(Kind::Edits, f.user, "a\n");
    let b =
        f.h.branch("wt/b", BranchKind::Worktree, Some("c1"))
            .unwrap();
    f.h.activate(f.doc, b, || unreachable!("b shares the seed"))
        .unwrap();
    let rb = f.step(Kind::Edits, f.user, "b\n");
    pile(&mut f);
    f.h.compact(0, f.user, 9.0).unwrap();
    assert_eq!(f.h.cut(f.doc, f.br).unwrap(), Some(rb), "a live branch");

    // a frozen worktree pins it too, until it expires
    let mut f = fx();
    f.step(Kind::Edits, f.user, "a\n");
    let b =
        f.h.branch("wt/b", BranchKind::Worktree, Some("c1"))
            .unwrap();
    f.h.activate(f.doc, b, || unreachable!("b shares the seed"))
        .unwrap();
    let rb = f.step(Kind::Edits, f.user, "b\n");
    f.h.park(f.doc, b).unwrap();
    f.h.freeze(b, 10.0).unwrap();
    pile(&mut f);
    f.h.compact(0, f.user, 9.0).unwrap();
    assert_eq!(f.h.cut(f.doc, f.br).unwrap(), Some(rb), "a frozen worktree");
    assert_eq!(f.h.expire(10.0 + 91.0 * DAY).unwrap(), vec![b]);
    f.h.compact(0, f.user, 9.0).unwrap();
    assert!(
        f.h.cut(f.doc, f.br).unwrap().unwrap() > rb,
        "expired, it pins no more"
    );

    // an undone branch that has not expired
    let mut f = fx();
    let (rev, _) = f.rolled_back(10.0);
    pile(&mut f);
    f.h.compact(0, f.user, 9.0).unwrap();
    assert_eq!(f.h.cut(f.doc, f.br).unwrap(), Some(rev), "an undone branch");
    f.h.expire(10.0 + 91.0 * DAY).unwrap();
    f.h.compact(0, f.user, 9.0).unwrap();
    assert!(f.h.cut(f.doc, f.br).unwrap().unwrap() > rev);
}

/// 60 more records on the live branch: more than the 50 newest, so no count of records protects what a reference pins.
fn pile(f: &mut Fx) -> Vec<OpId> {
    (0..60)
        .map(|i| f.step(Kind::Edits, f.user, &format!("l{i}\n")))
        .collect()
}

#[test]
fn revert_past_cut_is_refused_with_reason() {
    let mut f = fx();
    let rs: Vec<OpId> = ["a\n", "b\n", "c\n", "d\n", "e\n"]
        .iter()
        .map(|t| f.step(Kind::Edits, f.user, t))
        .collect();
    let before = f.h.size().unwrap();
    f.h.compact(0, f.user, 9.0).unwrap();
    // nothing pins it: the newest record stays revertable, the rest is cut
    assert_eq!(f.h.cut(f.doc, f.br).unwrap(), Some(rs[3]));
    let e = f.h.preview_revert(f.br, &[rs[0]]).unwrap_err().to_string();
    assert!(e.contains("compacted"), "{e}");
    assert!(f.h.preview_revert(f.br, &[rs[3]]).is_err());
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

/// A fork that was dropped (its branch frozen) is kept for compare until its 90 days are over, then goes like a
/// frozen worktree.
#[test]
fn a_dropped_fork_expires_like_a_frozen_worktree() {
    let mut f = fx();
    let at = f.step(Kind::Edits, f.user, "x\n");
    let fb = f.h.fork(at, f.br, "wt/fork", f.user, 11.0).unwrap();
    assert_eq!(f.h.find_branch("wt/fork").unwrap(), Some(fb));
    assert_eq!(f.h.find_branch("wt/none").unwrap(), None);
    f.h.freeze(fb, 20.0).unwrap();
    assert!(f.h.expire(20.0 + 89.0 * DAY).unwrap().is_empty());
    assert!(f.h.compare(f.br, fb).is_ok(), "kept for compare meanwhile");
    assert_eq!(f.h.expire(20.0 + 91.0 * DAY).unwrap(), vec![fb]);
    assert_eq!(f.h.find_branch("wt/fork").unwrap(), None);
    assert!(f.h.text(f.doc, f.br).unwrap().starts_with("x\none"));
}

#[test]
fn a_worktree_branch_remembers_its_folder_and_is_listed_until_frozen() {
    let mut f = fx();
    // a folder is named once; the first name stays
    f.h.set_root(f.br, "/work/a").unwrap();
    f.h.set_root(f.br, "/work/elsewhere").unwrap();
    let fork = f.h.branch("fork/y", BranchKind::Fork, None).unwrap();
    f.h.set_root(fork, "/work/fork").unwrap();
    // only live worktree branches are listed: not forks, not frozen ones
    assert_eq!(f.h.roots().unwrap(), vec![(f.br, "/work/a".to_owned())]);
    f.h.freeze(f.br, 5.0).unwrap();
    assert!(f.h.roots().unwrap().is_empty());
    // it expires like any frozen worktree, 90 days on
    assert_eq!(f.h.expire(5.0 + 91.0 * DAY).unwrap(), vec![f.br]);
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

#[test]
fn the_cap_is_two_gibibytes() {
    assert_eq!(verdandi::compact::DEFAULT_CAP, 2_147_483_648);
}

#[test]
fn size_is_whole_pages() {
    let f = fx();
    let s = f.h.size().unwrap();
    // SQLite's default 4096-byte pages; a fresh history holds several
    assert_eq!(s % 4096, 0, "{s}");
    assert!(s >= 4 * 4096, "{s}");
}

#[test]
fn a_cut_at_the_limit_is_not_made_twice() {
    let mut f = fx();
    f.step(Kind::Edits, f.user, "a\n");
    let r2 = f.step(Kind::Edits, f.user, "b\n");
    f.h.anchor(f.doc, f.br, 1, Side::Right, "review").unwrap();
    pile(&mut f);
    assert_eq!(f.h.compact(0, f.user, 9.0).unwrap().cuts, 1);
    assert_eq!(f.h.cut(f.doc, f.br).unwrap(), Some(r2));
    // the anchor still pins the cut at r2: nothing newer may be cut, and r2 itself is done
    let again = f.h.compact(0, f.user, 10.0).unwrap();
    assert_eq!(again.cuts, 0);
    assert_eq!(f.h.cut(f.doc, f.br).unwrap(), Some(r2));
}
