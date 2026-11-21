//! Anchors, who-wrote-this and the hunks view.  Pattern D (pure: no clock, every time is a parameter; the hunks test runs
//! `git diff --no-index` over two temporary files).

use verdandi::{
    BranchId, BranchKind, Cause, Change, DocId, History, Kind, OpId, PeerId, Record, Side, Span,
    When,
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

impl Fx {
    /// PEER's change as one record of KIND.
    fn step(&mut self, kind: Kind, peer: PeerId, start: usize, old: usize, ins: &str) -> OpId {
        let spans: Vec<(DocId, Span)> = self
            .h
            .activate(self.doc, self.br, || unreachable!())
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

    fn text(&mut self) -> String {
        self.h.text(self.doc, self.br).unwrap()
    }
}

#[test]
fn anchor_follows_edits() {
    let mut f = fx();
    let a = f.h.anchor(f.doc, f.br, 5, Side::Right, "review").unwrap();
    f.step(Kind::Edits, f.user, 0, 0, "XX");
    let r = f.h.resolve(a, When::Now).unwrap();
    assert_eq!((r.pos, r.deleted, r.text_then), (7, false, None));
    // and after an edit on its own line
    f.step(Kind::Edits, f.user, 6, 0, "..");
    assert_eq!(f.h.resolve(a, When::Now).unwrap().pos, 9);
    // the anchor survives a reload of the document from its rows
    f.h.park(f.doc, f.br).unwrap();
    assert_eq!(f.h.resolve(a, When::Now).unwrap().pos, 9);
}

#[test]
fn anchor_in_deleted_text_says_deleted() {
    let mut f = fx();
    let a = f.h.anchor(f.doc, f.br, 5, Side::Right, "review").unwrap();
    f.step(Kind::AgentStep, f.agent, 4, 4, "");
    let r = f.h.resolve(a, When::Now).unwrap();
    assert!(r.deleted);
    assert_eq!(r.pos, 4, "where the text was");
    assert_eq!(r.text_then.as_deref(), Some("two"));
}

#[test]
fn anchor_then_shows_text_as_written() {
    let mut f = fx();
    let a = f.h.anchor(f.doc, f.br, 5, Side::Right, "ledger").unwrap();
    f.step(Kind::Edits, f.user, 0, 0, "XX");
    f.step(Kind::AgentStep, f.agent, 6, 3, "TWO");
    assert_eq!(f.text(), "XXone\nTWO\nthree\nfour\n");
    let r = f.h.resolve(a, When::Then).unwrap();
    assert_eq!((r.pos, r.deleted), (5, false));
    assert_eq!(r.text_then.as_deref(), Some("two"));
    assert!(f.h.resolve(a, When::Now).unwrap().deleted);
}

#[test]
fn blame_names_step_per_char() {
    let mut f = fx();
    let ag = f.step(Kind::AgentStep, f.agent, 0, 0, "AG\n");
    let us = f.step(Kind::Edits, f.user, 1, 0, "x");
    let end = f.text().chars().count();
    let us2 = f.step(Kind::Edits, f.user, end, 0, "US\n");
    let t = f.text();
    assert_eq!(t, "AxG\none\ntwo\nthree\nfour\nUS\n");
    let b = f.h.blame(f.doc, f.br, 0..t.chars().count()).unwrap();
    let got: Vec<_> = b.iter().map(|e| (e.range.clone(), e.peer, e.op)).collect();
    // the base text has no author: it is left out
    assert_eq!(
        got,
        vec![
            (0..1, f.agent, ag),
            (1..2, f.user, us),
            (2..4, f.agent, ag),
            (end..end + 3, f.user, us2),
        ]
    );
    // a narrower range is cut to it
    let b = f.h.blame(f.doc, f.br, 2..3).unwrap();
    assert_eq!(b.len(), 1);
    assert_eq!(b[0].range, 2..3);
}

/// The hunks `git diff --unified=0` gives for OLD to NEW, as (old start, old count, new start, new count).
fn git_hunks(old: &str, new: &str) -> Vec<(usize, usize, usize, usize)> {
    let d = tempfile::tempdir().unwrap();
    std::fs::write(d.path().join("old"), old).unwrap();
    std::fs::write(d.path().join("new"), new).unwrap();
    let out = std::process::Command::new("git")
        .args([
            "diff",
            "--no-index",
            "--no-color",
            "--unified=0",
            "old",
            "new",
        ])
        .current_dir(d.path())
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .output()
        .unwrap();
    let num = |s: &str| -> (usize, usize) {
        let s = s.trim_start_matches(['-', '+']);
        match s.split_once(',') {
            Some((a, b)) => (a.parse().unwrap(), b.parse().unwrap()),
            None => (s.parse().unwrap(), 1),
        }
    };
    String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .filter(|l| l.starts_with("@@"))
        .map(|l| {
            let mut w = l.split_whitespace().skip(1);
            let (o, n) = (num(w.next().unwrap()), num(w.next().unwrap()));
            (o.0, o.1, n.0, n.1)
        })
        .collect()
}

#[test]
fn hunks_view_equals_git_diff() {
    let mut f = fx();
    let since = f.step(Kind::Edits, f.user, 0, 0, "zero\n");
    let before = f.text();
    f.step(Kind::AgentStep, f.agent, 9, 3, "TWO");
    let end = f.text().chars().count();
    f.step(Kind::AgentStep, f.agent, end, 0, "five\n");
    let after = f.text();
    let files = f.h.hunks(f.br, since).unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].path, "f.txt");
    let got: Vec<_> = files[0]
        .hunks
        .iter()
        .map(|h| (h.old_start, h.old_count, h.new_start, h.new_count))
        .collect();
    assert_eq!(got, git_hunks(&before, &after));
    assert_eq!(got.len(), 2, "{got:?}");
    // nothing changed since the last record: no file
    let last = f.step(Kind::Edits, f.user, 0, 0, "");
    assert!(f.h.hunks(f.br, last).unwrap().is_empty());
}
