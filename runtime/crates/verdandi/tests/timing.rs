//! Timing rows, run on demand (`cargo test -p verdandi --test timing -- --ignored --nocapture`); each prints its number.
//! `tests/timing.rs` is the one test file that may read the clock.

use std::time::Instant;
use verdandi::{BranchKind, Cause, Change, History, Kind, Record};

/// A history in which an agent's record deleted a line and the user then deleted LATER characters elsewhere in the
/// file, one delete operation each; the agent's record.
fn history_with_later_deletes(
    later: usize,
) -> (
    tempfile::TempDir,
    History,
    verdandi::BranchId,
    verdandi::OpId,
) {
    let dir = tempfile::tempdir().unwrap();
    let mut h = History::open(dir.path()).unwrap();
    let doc = h.doc_for("f.txt").unwrap();
    let br = h.branch("wt/a", BranchKind::Worktree, Some("c1")).unwrap();
    let base = format!("keep\ngone\n{}\n", "x".repeat(later));
    h.activate(doc, br, || Ok(base.clone())).unwrap();
    let agent = h
        .peer(
            &serde_json::json!({"kind": "agent", "session": "s9"}),
            Some(br),
        )
        .unwrap();
    let user = h
        .peer(&serde_json::json!({"kind": "user"}), Some(br))
        .unwrap();
    let record = |h: &mut History, peer, changes: Vec<Change>| {
        let mut spans = Vec::new();
        for c in &changes {
            let s = h
                .activate(doc, br, || unreachable!())
                .unwrap()
                .apply(peer, c)
                .unwrap();
            spans.extend(s.into_iter().map(|s| (doc, s)));
        }
        h.record(Record {
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
    };
    let op = record(
        &mut h,
        agent,
        vec![Change {
            start: 5,
            old_len: 5,
            inserted: String::new(),
        }],
    );
    // the characters after "keep\n", one at a time
    let deletes = (0..later)
        .map(|_| Change {
            start: 5,
            old_len: 1,
            inserted: String::new(),
        })
        .collect();
    record(&mut h, user, deletes);
    (dir, h, br, op)
}

#[test]
#[ignore = "timing: the 'undone by' scan of one record's hunks, by the number of later deletes in the file"]
fn undone_by_scan_cost_by_later_deletes() {
    for later in [0, 100, 1000] {
        let (_dir, mut h, br, op) = history_with_later_deletes(later);
        let t = Instant::now();
        let hunks = h.op_hunks(br, op).unwrap();
        let ms = t.elapsed().as_secs_f64() * 1000.0;
        assert_eq!(hunks.len(), 1);
        eprintln!("undone-by scan: {later} later deletes, {ms:.1} ms");
    }
}
