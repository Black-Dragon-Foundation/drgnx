use saga::deferred::{self, DeferredPiece};
use saga::import::{ops, parse};
use saga::status::{normalize_deferred, status_of, with_status};
use std::path::Path;

const B: &str = include_str!("fixtures/deferred-b.md");

#[test]
fn every_register_table_and_entry_is_read() {
    let d = deferred::parse(B);
    assert_eq!(deferred::render(&d), B);
    let rows = d.rows();
    let got: Vec<(&str, &str, bool)> = rows
        .iter()
        .map(|r| (r.id.as_str(), r.status.as_str(), r.entry))
        .collect();
    assert_eq!(
        got,
        [
            ("1", "open", false),
            ("2", "fixed in M2", false),
            ("H-3", "moved to M4", false),
            ("H-4", "Dropped", false),
            ("AS1-NET-1", "open", true),
            ("AS1-NET-2", "fixed", true),
        ]
    );
    assert!(rows[1].raw.contains("\n  near the second knot"));
    assert_eq!(rows[4].text, "Gate stays shut (quay)");
    assert!(rows[5].raw.contains("- **Was:** open until"));
    assert!(!rows[5].raw.contains("## Closing"));
    assert_eq!(&B[rows[4].span.clone()], rows[4].raw);
    // the 2-column table and the prose stay prose; the head comes first
    let prose: String = d
        .pieces
        .iter()
        .filter_map(|p| match p {
            DeferredPiece::Prose(s) => Some(s.as_str()),
            _ => None,
        })
        .collect();
    assert!(prose.contains("| Name | Count |") && prose.contains("Prose between the tables."));
    assert!(matches!(d.pieces[0], DeferredPiece::Prose(_)));
}

#[test]
fn odd_inputs_round_trip() {
    for t in [
        "",
        "### X1-A — t\n",
        "### X1-A — t",
        "### Notes\n- **Status:** open\n",
        "```\n### X1-A — t\n```\n",
        "### X1-A — t\n- **Status:**\n#### sub\n## h\n",
        "| # | Area | Item | Status |\r\n|---|---|---|---|\r\n| 1 | a | b | c |",
        "| # | a | b | other |\n|---|---|---|---|\n| 1 | a | b | c |\n",
    ] {
        assert_eq!(deferred::render(&deferred::parse(t)), t, "{t:?}");
    }
    // a plain `### Notes` is prose and a fenced one is not an entry
    assert!(deferred::parse("### Notes\n").rows().is_empty());
    assert!(
        deferred::parse("```\n### X1-A — t\n```\n")
            .rows()
            .is_empty()
    );
}

#[test]
fn deferred_words_map_conservatively() {
    for (raw, want) in [
        ("open, 2026-10-24.", "open"),
        ("Fixed in M2", "done"),
        ("closed: n/a", "done"),
        ("done", "done"),
        ("decided", "done"),
        ("mitigated", "done"),
        ("dropped", "dropped"),
        ("moot", "dropped"),
        ("moved to M4", "open"),
        ("re-tagged", "open"),
        ("narrowed", "open"),
        ("partly", "open"),
        ("shrunk", "open"),
        ("kept", "open"),
        ("watching", "open"),
        ("", "open"),
    ] {
        assert_eq!(normalize_deferred(raw), want, "{raw}");
    }
}

#[test]
fn the_import_has_a_todo_per_row_and_is_stable() {
    let doc = parse("deferred", B).unwrap();
    let a = ops(&doc, Path::new("/x/D.md"));
    let todos: Vec<_> = a.iter().filter(|o| o.kind == "todo").collect();
    assert_eq!(todos.len(), 6);
    let st: Vec<_> = todos.iter().map(|o| o.status.as_deref().unwrap()).collect();
    assert_eq!(st, ["open", "done", "open", "dropped", "open", "done"]);
    assert_eq!(todos[4].role, "entry");
    assert_eq!(a[0].role, "head");
    let body: String = a.iter().map(|o| o.body.as_str()).collect();
    assert_eq!(body, B);
    assert!(a.iter().enumerate().all(|(i, o)| o.seq as usize == i));
    assert_eq!(a, ops(&parse("deferred", B).unwrap(), Path::new("/x/D.md")));
}

#[test]
fn a_status_change_writes_the_state_cell_and_the_bullet() {
    let row = "| H-3 | quay | Lamp is dim | moved to M4 |\n";
    assert_eq!(status_of("todo", "row", row).as_deref(), Some("open"));
    assert_eq!(with_status("todo", "row", row, "open"), None);
    assert_eq!(
        with_status("todo", "row", row, "done").unwrap(),
        "| H-3 | quay | Lamp is dim | done |\n"
    );
    let e = "### AS1-NET-1 — Gate\n\n- **Status:** open, 2026-10-24. Waiting.\n- **Was:** x\n";
    assert_eq!(status_of("todo", "entry", e).as_deref(), Some("open"));
    assert_eq!(with_status("todo", "entry", e, "open"), None);
    let w = with_status("todo", "entry", e, "done").unwrap();
    assert_eq!(
        w,
        "### AS1-NET-1 — Gate\n\n- **Status:** done, 2026-10-24. Waiting.\n- **Was:** x\n"
    );
    assert_eq!(status_of("todo", "entry", &w).as_deref(), Some("done"));
    // no bullet: nothing to write, and the entry reads as open
    let n = "### AS1-NET-3 — No bullet\n";
    assert_eq!(status_of("todo", "entry", n).as_deref(), Some("open"));
    assert_eq!(with_status("todo", "entry", n, "done"), None);
}
