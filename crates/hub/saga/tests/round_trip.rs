//! Records drgnx takes over: specs and ADRs as records, the links between record files, ids that survive an edit in
//! the middle of a file, and the three-way merge that keeps a hand edit and a graph change both
//! (`docs/develop/records.md`, "Editing a view").

use proptest::prelude::*;
use saga::import::{GraphOp, ops, parse};
use saga::links::{Link, links};
use saga::merge::{Act, Base, Live, digest_piece, merge};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

const DEFERRED: &str = "# Deferred\n\n| # | Area | Item | Status |\n|---|---|---|---|\n| 1 | ui | one | open |\n| 2 | ui | two | open |\n| 3 | hub | three | open |\n\nTail.\n";

fn ops_of(kind: &str, text: &str) -> Vec<GraphOp> {
    ops(&parse(kind, text).unwrap(), Path::new("/p/DEFERRED.md"))
}

#[test]
fn a_spec_is_one_record_with_its_title_status_and_anchors() {
    let text = "# The menu bar: design\n\n**Status:** approved\n\n## 1. What you see\n\nText.\n\n## 2. Data\n";
    let o = ops(
        &parse("spec", text).unwrap(),
        Path::new("/p/docs/specs/a.md"),
    );
    assert_eq!(o.len(), 1);
    assert_eq!(o[0].kind, "spec");
    assert_eq!(o[0].title.as_deref(), Some("The menu bar: design"));
    assert_eq!(o[0].status.as_deref(), Some("done"));
    assert_eq!(o[0].body, text);
    let d = parse(
        "decision",
        "---\nstatus: accepted\n---\n# 0003 Use podman\n",
    )
    .unwrap();
    let o = ops(&d, Path::new("/p/docs/adr/0003.md"));
    assert_eq!(o[0].kind, "decision");
    assert_eq!(o[0].title.as_deref(), Some("0003 Use podman"));
    assert_eq!(o[0].status.as_deref(), Some("done"));
    let anchors = saga::spec::parse(text).anchors;
    assert_eq!(
        anchors.iter().map(|a| a.0.as_str()).collect::<Vec<_>>(),
        ["The menu bar: design", "1. What you see", "2. Data"]
    );
}

#[test]
fn ids_survive_an_insert_in_the_middle() {
    let before = ops_of("deferred", DEFERRED);
    let after = ops_of(
        "deferred",
        &DEFERRED.replace(
            "| 2 | ui | two | open |\n",
            "| 2 | ui | two | open |\n| 9 | ui | new | open |\n",
        ),
    );
    let id = |v: &[GraphOp], key: &str| v.iter().find(|o| o.key == key).map(|o| o.id.clone());
    for key in ["head", "row 1", "row 2", "row 3"] {
        assert_eq!(id(&before, key), id(&after, key), "{key}");
    }
    assert!(id(&after, "row 9").is_some());
    let mut ids: Vec<_> = after.iter().map(|o| o.id.clone()).collect();
    ids.dedup();
    assert_eq!(ids.len(), after.len(), "ids are unique");
}

#[test]
fn links_come_from_the_documents_own_text() {
    let root = Path::new("/p");
    let known = |p: &Path| {
        [
            "/p/docs/specs/a.md",
            "/p/docs/plans/a.md",
            "/p/docs/plans/a.ledger.md",
            "/p/docs/decisions/0002.md",
            "/p/docs/decisions/0001.md",
        ]
        .iter()
        .any(|k| Path::new(k) == p)
    };
    let plan = "# Plan\n\n**Spec:** `docs/specs/a.md`\n\nSee [the ADR](../decisions/0002.md) and [code](../../src/x.rs).\n\n```\n[not](../specs/a.md)\n```\n[out](../../../etc/passwd)\n";
    let got = links(plan, Path::new("/p/docs/plans/a.md"), root, &known);
    assert!(got.contains(&Link {
        to: PathBuf::from("/p/docs/specs/a.md"),
        kind: "derives",
    }));
    assert!(got.contains(&Link {
        to: PathBuf::from("/p/docs/decisions/0002.md"),
        kind: "relates",
    }));
    assert_eq!(got.len(), 2, "{got:?}");
    let ledger = links(
        "# Ledger\n",
        Path::new("/p/docs/plans/a.ledger.md"),
        root,
        &known,
    );
    assert_eq!(
        ledger,
        vec![Link {
            to: PathBuf::from("/p/docs/plans/a.md"),
            kind: "relates",
        }]
    );
    let adr = links(
        "# 0002\n\nSupersedes [0001](0001.md).\n",
        Path::new("/p/docs/decisions/0002.md"),
        root,
        &known,
    );
    assert_eq!(
        adr,
        vec![Link {
            to: PathBuf::from("/p/docs/decisions/0001.md"),
            kind: "supersedes",
        }]
    );
}

/// The base, as the hub keeps it after writing TEXT's pieces at graph version VER.
fn base_of(file: &[GraphOp], ver: i64) -> HashMap<String, Base> {
    file.iter()
        .map(|o| {
            (
                o.id.clone(),
                Base {
                    ver,
                    hashes: vec![digest_piece(&o.body)],
                },
            )
        })
        .collect()
}

fn live_of(file: &[GraphOp], ver: i64) -> Vec<Live> {
    file.iter()
        .map(|o| Live {
            id: o.id.clone(),
            ver,
            body: o.body.clone(),
            seq: o.seq,
        })
        .collect()
}

fn set_live(live: &mut [Live], id: &str, body: &str) {
    let l = live.iter_mut().find(|l| l.id == id).unwrap();
    l.body = body.into();
    l.ver += 1;
}

#[test]
fn a_hand_edit_survives_a_regeneration_and_the_graph_change_lands_too() {
    let start = ops_of("deferred", DEFERRED);
    let base = base_of(&start, 1);
    let mut live = live_of(&start, 1);
    let row3 = start.iter().find(|o| o.key == "row 3").unwrap().id.clone();
    let row1 = start.iter().find(|o| o.key == "row 1").unwrap().id.clone();
    // the graph closes row 3 while someone edits row 1 in the file
    set_live(&mut live, &row3, "| 3 | hub | three | done |\n");
    let edited = DEFERRED.replace(
        "| 1 | ui | one | open |",
        "| 1 | ui | one, reworded | open |",
    );
    let m = merge(&ops_of("deferred", &edited), &base, &live);
    assert!(m.text.contains("one, reworded"));
    assert!(m.text.contains("| 3 | hub | three | done |"));
    assert!(m.conflicts.is_empty());
    assert!(
        m.acts
            .iter()
            .any(|a| matches!(a, Act::Update { id, .. } if *id == row1))
    );
}

#[test]
fn the_same_piece_changed_on_both_sides_keeps_the_file_and_flags_it() {
    let start = ops_of("deferred", DEFERRED);
    let base = base_of(&start, 1);
    let mut live = live_of(&start, 1);
    let row2 = start.iter().find(|o| o.key == "row 2").unwrap().id.clone();
    set_live(&mut live, &row2, "| 2 | ui | two | done |\n");
    let edited = DEFERRED.replace("| 2 | ui | two | open |", "| 2 | ui | two (file) | open |");
    let m = merge(&ops_of("deferred", &edited), &base, &live);
    assert!(m.text.contains("two (file)"));
    assert_eq!(m.conflicts, vec![row2.clone()]);
    assert!(m.acts.iter().any(
        |a| matches!(a, Act::Conflict { id, file } if *id == row2 && file.contains("two (file)"))
    ));
    assert!(
        !m.acts
            .iter()
            .any(|a| matches!(a, Act::Update { id, .. } if *id == row2))
    );
}

#[test]
fn a_stale_editor_save_is_flagged_not_applied() {
    let start = ops_of("deferred", DEFERRED);
    let row2 = start.iter().find(|o| o.key == "row 2").unwrap().id.clone();
    // the hub wrote the graph's change to row 2 (base now has the new text, the old one before it)
    let mut base = base_of(&start, 2);
    base.get_mut(&row2).unwrap().hashes = vec![
        digest_piece("| 2 | ui | two | done |\n"),
        digest_piece("| 2 | ui | two | open |\n"),
    ];
    let mut live = live_of(&start, 2);
    live.iter_mut().find(|l| l.id == row2).unwrap().body = "| 2 | ui | two | done |\n".into();
    // an editor that still held the old text saves it
    let m = merge(&ops_of("deferred", DEFERRED), &base, &live);
    assert_eq!(m.conflicts, vec![row2]);
}

#[test]
fn new_rows_on_both_sides_are_both_kept() {
    let start = ops_of("deferred", DEFERRED);
    let base = base_of(&start, 1);
    let mut live = live_of(&start, 1);
    // the graph adds a row after row 3; the file adds one after row 1
    let row3 = live
        .iter()
        .position(|l| l.body.starts_with("| 3 "))
        .unwrap();
    live.insert(
        row3 + 1,
        Live {
            id: "todo:new-from-graph".into(),
            ver: 1,
            body: "| 4 | hub | from the graph | open |\n".into(),
            seq: live[row3].seq,
        },
    );
    let edited = DEFERRED.replace(
        "| 1 | ui | one | open |\n",
        "| 1 | ui | one | open |\n| 5 | ui | from the file | open |\n",
    );
    let m = merge(&ops_of("deferred", &edited), &base, &live);
    let (g, f) = (
        m.text.find("from the graph").unwrap(),
        m.text.find("from the file").unwrap(),
    );
    assert!(f < g);
    assert!(m.text.find("| 3 | hub").unwrap() < g, "after its neighbour");
    assert!(
        m.acts
            .iter()
            .any(|a| matches!(a, Act::Create(o) if o.body.contains("from the file")))
    );
}

#[test]
fn a_row_deleted_in_the_file_is_retired_unless_the_graph_changed_it() {
    let start = ops_of("deferred", DEFERRED);
    let base = base_of(&start, 1);
    let live = live_of(&start, 1);
    let row1 = start.iter().find(|o| o.key == "row 1").unwrap().id.clone();
    let edited = DEFERRED.replace("| 1 | ui | one | open |\n", "");
    let m = merge(&ops_of("deferred", &edited), &base, &live);
    assert!(
        m.acts
            .iter()
            .any(|a| matches!(a, Act::Retire { id } if *id == row1))
    );
    let mut live = live_of(&start, 1);
    set_live(&mut live, &row1, "| 1 | ui | one | done |\n");
    let m = merge(&ops_of("deferred", &edited), &base, &live);
    assert_eq!(m.conflicts, vec![row1]);
    assert!(!m.text.contains("| 1 |"), "the file's text is kept");
}

#[test]
fn a_file_edit_of_a_user_only_field_is_a_conflict() {
    let text = "# Deferred\n\n### D1 — a thing\n\n- **Status:** open\n- matrix: off\n";
    let start = ops_of("deferred", text);
    let edited = text.replace("matrix: off", "matrix: on");
    let m = merge(
        &ops_of("deferred", &edited),
        &base_of(&start, 1),
        &live_of(&start, 1),
    );
    assert!(m.text.contains("matrix: on"), "the file keeps its text");
    assert_eq!(m.conflicts.len(), 1);
    assert!(!m.acts.iter().any(|a| matches!(a, Act::Update { .. })));
}

#[test]
fn nothing_changed_renders_the_file_byte_for_byte() {
    let start = ops_of("deferred", DEFERRED);
    let m = merge(&start, &base_of(&start, 1), &live_of(&start, 1));
    assert_eq!(m.text, DEFERRED);
    assert!(m.acts.is_empty());
}

proptest! {
    /// Random edits of different rows on both sides: every edit ends up in the merged text.
    #[test]
    fn edits_on_both_sides_are_never_lost(file_rows in proptest::collection::btree_set(1u8..=3, 0..=3),
                                           graph_rows in proptest::collection::btree_set(1u8..=3, 0..=3)) {
        let start = ops_of("deferred", DEFERRED);
        let base = base_of(&start, 1);
        let mut live = live_of(&start, 1);
        let mut edited = DEFERRED.to_string();
        let word = |n: u8| ["one", "two", "three"][usize::from(n - 1)];
        for n in &file_rows {
            edited = edited.replace(&format!("| {n} | "), &format!("| {n} | F-"));
        }
        for n in &graph_rows {
            let id = start.iter().find(|o| o.key == format!("row {n}")).unwrap().id.clone();
            let body = start.iter().find(|o| o.id == id).unwrap().body.replace(word(*n), &format!("G-{}", word(*n)));
            set_live(&mut live, &id, &body);
        }
        let m = merge(&ops_of("deferred", &edited), &base, &live);
        for n in &file_rows {
            prop_assert!(m.text.contains(&format!("| {n} | F-")), "file edit of row {} lost", n);
        }
        for n in &graph_rows {
            if file_rows.contains(n) {
                let id = start.iter().find(|o| o.key == format!("row {n}")).unwrap().id.clone();
                prop_assert!(m.conflicts.contains(&id));
            } else {
                prop_assert!(m.text.contains(&format!("G-{}", word(*n))), "graph edit of row {} lost", n);
            }
        }
    }
}
