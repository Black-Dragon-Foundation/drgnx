//! Documents and branches: lazy from the base commit, branches apart, parking, idle documents, what text is.
//! Pattern D (pure: a temporary folder, no process; the idle clock is a parameter).

use std::cell::Cell;
use verdandi::text::{Coding, NotText, canonical, encode};
use verdandi::{BranchKind, Change, History};

fn ins(start: usize, s: &str) -> Change {
    Change {
        start,
        old_len: 0,
        inserted: s.into(),
    }
}

#[test]
fn lazy_branch_reads_base_once() {
    let d = tempfile::tempdir().unwrap();
    let mut h = History::open(d.path()).unwrap();
    let doc = h.doc_for("a.txt").unwrap();
    let a = h.branch("wt/a", BranchKind::Worktree, Some("c1")).unwrap();
    let b = h.branch("wt/b", BranchKind::Worktree, Some("c1")).unwrap();
    let reads = Cell::new(0);
    let base = || {
        reads.set(reads.get() + 1);
        Ok("line one\nline two\n".to_string())
    };
    let p = h.peer(&serde_json::json!({"user": 1}), Some(a)).unwrap();
    {
        let mut ad = h.activate(doc, a, base).unwrap();
        assert_eq!(ad.text(), "line one\nline two\n");
        ad.apply(p, &ins(0, "> ")).unwrap();
    }
    assert_eq!(reads.get(), 1);
    // parked and active again, and another branch at the same commit: the base is not read again
    h.park(doc, a).unwrap();
    assert_eq!(
        h.activate(doc, a, base).unwrap().text(),
        "> line one\nline two\n"
    );
    assert_eq!(
        h.activate(doc, b, base).unwrap().text(),
        "line one\nline two\n"
    );
    assert_eq!(reads.get(), 1);
    // nor after a restart
    h.close().unwrap();
    drop(h);
    let mut h = History::open(d.path()).unwrap();
    assert_eq!(
        h.activate(doc, a, base).unwrap().text(),
        "> line one\nline two\n"
    );
    assert_eq!(reads.get(), 1);
}

#[test]
fn two_active_branches_diverge_without_crossing() {
    let d = tempfile::tempdir().unwrap();
    let mut h = History::open(d.path()).unwrap();
    let doc = h.doc_for("a.txt").unwrap();
    let a = h.branch("wt/a", BranchKind::Worktree, Some("c1")).unwrap();
    let b = h.branch("wt/b", BranchKind::Worktree, Some("c1")).unwrap();
    let pa = h.peer(&serde_json::json!({"user": 1}), Some(a)).unwrap();
    let pb = h.peer(&serde_json::json!({"user": 1}), Some(b)).unwrap();
    let base = || Ok("hello\n".to_string());
    h.activate(doc, a, base)
        .unwrap()
        .apply(pa, &ins(0, "A"))
        .unwrap();
    h.activate(doc, b, base)
        .unwrap()
        .apply(pb, &ins(6, "B"))
        .unwrap();
    assert_eq!(h.text(doc, a).unwrap(), "Ahello\n");
    assert_eq!(h.text(doc, b).unwrap(), "hello\nB");
    assert_eq!(h.active_docs(), [(doc, a), (doc, b)]);
    drop(h);
    let mut h = History::open(d.path()).unwrap();
    assert_eq!(h.text(doc, a).unwrap(), "Ahello\n");
    assert_eq!(h.text(doc, b).unwrap(), "hello\nB");
}

#[test]
fn park_and_reactivate_round_trips_text_and_ids() {
    let d = tempfile::tempdir().unwrap();
    let mut h = History::open(d.path()).unwrap();
    let doc = h.doc_for("a.txt").unwrap();
    let a = h.branch("wt/a", BranchKind::Worktree, Some("c1")).unwrap();
    let p = h.peer(&serde_json::json!({"run": 1}), Some(a)).unwrap();
    let base = || Ok("abc\n".to_string());
    let (s1, f1) = {
        let mut ad = h.activate(doc, a, base).unwrap();
        let s = ad.apply(p, &ins(1, "XY")).unwrap();
        ad.apply(
            p,
            &Change {
                start: 0,
                old_len: 1,
                inserted: String::new(),
            },
        )
        .unwrap();
        (s, ad.frontier())
    };
    assert_eq!((s1[0].start, s1[0].end), (0, 2));
    h.park(doc, a).unwrap();
    assert!(h.active_docs().is_empty());
    let mut ad = h.activate(doc, a, base).unwrap();
    assert_eq!(ad.text(), "XYbc\n");
    assert_eq!(ad.frontier(), f1, "the same version after a reload");
    // the peer's counters go on where they stopped: the ids are the same ones
    let s3 = ad.apply(p, &ins(4, "!")).unwrap();
    assert_eq!((s3[0].start, s3[0].end), (3, 4));
    // a change past the end is refused
    assert!(ad.apply(p, &ins(99, "x")).is_err());
}

#[test]
fn idle_docs_close_after_five_minutes() {
    let d = tempfile::tempdir().unwrap();
    let mut h = History::open(d.path()).unwrap();
    let one = h.doc_for("one.txt").unwrap();
    let two = h.doc_for("two.txt").unwrap();
    let a = h.branch("wt/a", BranchKind::Worktree, Some("c1")).unwrap();
    let p = h.peer(&serde_json::json!({"user": 1}), Some(a)).unwrap();
    let base = || Ok("x\n".to_string());
    h.activate(one, a, base)
        .unwrap()
        .apply(p, &ins(0, "1"))
        .unwrap();
    assert!(h.park_idle(300.0, 0.0).unwrap().is_empty());
    h.activate(two, a, base)
        .unwrap()
        .apply(p, &ins(0, "2"))
        .unwrap();
    assert!(h.park_idle(300.0, 200.0).unwrap().is_empty());
    // one has not been used since 0: idle at 300; two was used after 0
    assert!(h.park_idle(300.0, 299.0).unwrap().is_empty());
    assert_eq!(h.park_idle(300.0, 301.0).unwrap(), [(one, a)]);
    assert_eq!(h.active_docs(), [(two, a)]);
    // two, used before 200, is idle at 500
    assert_eq!(h.park_idle(300.0, 501.0).unwrap(), [(two, a)]);
    assert!(h.active_docs().is_empty());
    assert_eq!(h.text(one, a).unwrap(), "1x\n");
    assert_eq!(h.text(two, a).unwrap(), "2x\n");
}

#[test]
fn crlf_and_raw_bytes_classify() {
    let dos = b"one\r\ntwo\r\n";
    assert_eq!(Coding::detect(dos), Coding::Utf8Dos);
    let t = canonical(dos, Coding::Utf8Dos).unwrap();
    assert_eq!(t, "one\ntwo\n");
    assert_eq!(encode(&t, Coding::Utf8Dos), dos);
    // a mixed file is Unix: its carriage return is a character
    let mixed = b"one\r\ntwo\n";
    assert_eq!(Coding::detect(mixed), Coding::Utf8Unix);
    assert_eq!(canonical(mixed, Coding::Utf8Unix).unwrap(), "one\r\ntwo\n");
    assert_eq!(canonical(mixed, Coding::Utf8Dos), Err(NotText::NoRoundTrip));
    assert_eq!(
        canonical(&[b'a', 0xff, b'b'], Coding::Utf8Unix),
        Err(NotText::NotUtf8)
    );
    assert_eq!(canonical(b"a\0b", Coding::Utf8Unix), Err(NotText::Binary));
}

/// Offsets are characters, not bytes: emoji, CJK and combining marks, through a reload.
#[test]
fn non_ascii_text_round_trips() {
    let d = tempfile::tempdir().unwrap();
    let mut h = History::open(d.path()).unwrap();
    let doc = h.doc_for("u.txt").unwrap();
    let a = h.branch("wt/a", BranchKind::Worktree, Some("c1")).unwrap();
    let p = h.peer(&serde_json::json!({"user": 1}), Some(a)).unwrap();
    let base = "日本語のテキスト 🐉 e\u{301}\n".repeat(40);
    {
        let mut ad = h.activate(doc, a, || Ok(base.clone())).unwrap();
        // after the dragon (character 11 of the first line)
        ad.apply(p, &ins(11, "🔥")).unwrap();
        ad.apply(
            p,
            &Change {
                start: 0,
                old_len: 3,
                inserted: "中文".into(),
            },
        )
        .unwrap();
    }
    let mut want: Vec<char> = base.chars().collect();
    want.splice(11..11, ['🔥']);
    want.splice(0..3, ['中', '文']);
    let want: String = want.into_iter().collect();
    assert_eq!(h.text(doc, a).unwrap(), want);
    h.close().unwrap();
    drop(h);
    let mut h = History::open(d.path()).unwrap();
    assert_eq!(h.text(doc, a).unwrap(), want);
}

/// A real file (this crate's own source, CRLF on disk) typed in word by word with corrections, every few hundred
/// changes past the snapshot tail, then reloaded: the text and its round trip to the file's bytes hold.
#[test]
fn a_real_file_typed_through_the_snapshot_tail() {
    let real = include_str!("../src/docs.rs");
    let disk = encode(real, Coding::Utf8Dos);
    let text = canonical(&disk, Coding::detect(&disk)).unwrap();
    assert_eq!(text, real);
    let d = tempfile::tempdir().unwrap();
    let mut h = History::open(d.path()).unwrap();
    let doc = h.doc_for("docs.rs").unwrap();
    let a = h.branch("wt/a", BranchKind::Worktree, Some("c0")).unwrap();
    let p = h.peer(&serde_json::json!({"user": 1}), Some(a)).unwrap();
    let mut n = 0usize;
    {
        let mut ad = h.activate(doc, a, || Ok(String::new())).unwrap();
        let mut at = 0usize;
        for (i, word) in text.split_inclusive(' ').enumerate() {
            // every seventh word typed wrong first, then corrected
            if i % 7 == 3 {
                ad.apply(p, &ins(at, "teh ")).unwrap();
                ad.apply(
                    p,
                    &Change {
                        start: at,
                        old_len: 4,
                        inserted: String::new(),
                    },
                )
                .unwrap();
                n += 2;
            }
            ad.apply(p, &ins(at, word)).unwrap();
            at += word.chars().count();
            n += 1;
        }
        assert_eq!(ad.text(), text);
    }
    assert!(
        n > 2 * verdandi::docs::SNAPSHOT_TAIL as usize,
        "{n} changes"
    );
    assert!(h.count("doc_snapshot").unwrap() >= 1);
    drop(h);
    let mut h = History::open(d.path()).unwrap();
    let back = h.text(doc, a).unwrap();
    assert_eq!(back, text);
    assert_eq!(encode(&back, Coding::Utf8Dos), disk);
}
