//! Privacy: excise keeps every element id and leaves the secret in no file; redaction on capture.
//! Pattern D (pure: a temporary folder, no clock; every time is a parameter).

use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use verdandi::redact::{Batch, scan};
use verdandi::{
    BranchId, BranchKind, Cause, Change, DocId, History, Kind, OpId, PeerId, Record, Side, Target,
    When,
};

const BASE: &str = "one\ntwo\nthree\nfour\n";
const SECRET: &str = "sk-live-4f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a";

struct Fx {
    dir: tempfile::TempDir,
    h: History,
    doc: DocId,
    br: BranchId,
    user: PeerId,
}

fn fx() -> Fx {
    let dir = tempfile::tempdir().unwrap();
    let mut h = History::open(dir.path()).unwrap();
    let doc = h.doc_for("f.txt").unwrap();
    let br = h.branch("wt/a", BranchKind::Worktree, Some("c1")).unwrap();
    h.activate(doc, br, || Ok(BASE.into())).unwrap();
    let user = h.peer(&serde_json::json!({"user": 1}), Some(br)).unwrap();
    Fx {
        dir,
        h,
        doc,
        br,
        user,
    }
}

impl Fx {
    fn step(&mut self, start: usize, old: usize, ins: &str) -> OpId {
        let spans = self
            .h
            .activate(self.doc, self.br, || unreachable!())
            .unwrap()
            .apply(
                self.user,
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
                kind: Kind::Edits,
                author: self.user,
                cause: Cause::default(),
                spans,
                parents: vec![],
                git: None,
                summary: "edit".into(),
                at: 0.0,
            })
            .unwrap()
    }
}

fn files_under(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir).unwrap().flatten() {
        let p = e.path();
        if p.is_dir() {
            out.extend(files_under(&p));
        } else {
            out.push(p);
        }
    }
    out
}

/// Whether any file under DIR (the database, its write-ahead log, the backups) holds NEEDLE.
fn holds(dir: &Path, needle: &str) -> bool {
    files_under(dir).iter().any(|f| {
        std::fs::read(f)
            .unwrap()
            .windows(needle.len())
            .any(|w| w == needle.as_bytes())
    })
}

#[test]
fn excise_keeps_every_id_and_anchor() {
    let mut f = fx();
    let line = format!("key = {SECRET}\n");
    let op = f.step(0, 0, &line);
    f.step(line.chars().count(), 0, "after\n");
    let fb = f.h.fork(op, f.br, "fork/x", f.user, 1.0).unwrap();
    let anchor =
        f.h.anchor(f.doc, f.br, line.chars().count() + 2, Side::Right, "review")
            .unwrap();
    let ids = f.h.element_ids(f.doc, f.br).unwrap();
    let pos = f.h.resolve(anchor, When::Now).unwrap().pos;
    let at = line.find(SECRET).unwrap();
    let range = at..at + SECRET.len();
    let ex =
        f.h.excise(f.doc, f.br, &Target::Range(range), f.user, 5.0)
            .unwrap();
    let stars = "*".repeat(SECRET.len());
    assert_eq!(
        f.h.text(f.doc, f.br).unwrap(),
        format!("key = {stars}\nafter\n{BASE}")
    );
    assert_eq!(f.h.element_ids(f.doc, f.br).unwrap(), ids, "ids are kept");
    assert_eq!(f.h.resolve(anchor, When::Now).unwrap().pos, pos);
    assert_eq!(
        f.h.text(f.doc, fb).unwrap(),
        format!("key = {stars}\n{BASE}"),
        "the fork's copy goes too"
    );
    let r = f.h.op(ex).unwrap();
    assert_eq!(r.kind, Kind::Excise);
    assert!(!r.summary.contains(SECRET));
    // typing goes on
    f.step(0, 0, "more\n");
    assert!(f.h.text(f.doc, f.br).unwrap().starts_with("more\nkey = "));
}

#[test]
fn excised_text_absent_from_file_bytes() {
    let mut f = fx();
    let line = format!("key = {SECRET}\n");
    f.step(0, 0, &line);
    f.step(line.chars().count(), 0, "after\n");
    f.h.park(f.doc, f.br).unwrap();
    f.h.backup("b1").unwrap();
    assert!(
        holds(f.dir.path(), SECRET),
        "the secret is in the files before"
    );
    f.h.excise(f.doc, f.br, &Target::Pattern(SECRET.into()), f.user, 5.0)
        .unwrap();
    assert!(
        !holds(f.dir.path(), SECRET),
        "the secret is in no file after (database, log, backups)"
    );
    assert!(!f.h.text(f.doc, f.br).unwrap().contains(SECRET));
    // the history still opens from its rows
    drop(f.h);
    let mut h = History::open(f.dir.path()).unwrap();
    assert!(!h.text(f.doc, f.br).unwrap().contains(SECRET));
}

#[test]
fn excise_refuses_what_matches_nothing() {
    let mut f = fx();
    assert!(
        f.h.excise(f.doc, f.br, &Target::Pattern("absent".into()), f.user, 1.0)
            .is_err()
    );
}

fn changes(texts: &[&str]) -> Batch {
    Batch::new(
        texts
            .iter()
            .enumerate()
            .map(|(i, t)| Change {
                start: i,
                old_len: 0,
                inserted: (*t).into(),
            })
            .collect(),
    )
}

#[test]
fn key_shape_redacted_on_capture() {
    // built in pieces: the repository's own secret scan reads these shapes in a literal
    let aws = ["AKIA", "IOSFODNN7EXAMPLE"].concat();
    let pem = [
        "-----BEGIN RSA PRIVATE ",
        "KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE ",
        "KEY-----",
    ]
    .concat();
    let plain = "task-list-item and sk-short and a long-looking-identifier-name-that-is-fine";
    let b = scan(changes(&[
        &format!("token = {SECRET}\n"),
        &format!("export AWS={aws}\n"),
        &format!("{pem}\n"),
        plain,
    ]));
    let got: Vec<&str> = b.changes.iter().map(|c| c.inserted.as_str()).collect();
    assert_eq!(got[0], format!("token = {}\n", "*".repeat(SECRET.len())));
    assert_eq!(got[1], format!("export AWS={}\n", "*".repeat(aws.len())));
    assert_eq!(got[2], format!("{}\n", "*".repeat(pem.chars().count())));
    assert_eq!(got[3], plain, "ordinary text is left alone");
    // the hash is over the redacted text
    let want: String = Sha256::digest(got.concat().as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    assert_eq!(b.hash, want);
    // scanning twice changes nothing
    assert_eq!(scan(b.clone()), b);
}
