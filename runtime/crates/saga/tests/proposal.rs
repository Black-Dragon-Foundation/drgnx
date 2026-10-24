use saga::proposal::read;
use saga::status::{STATUSES, normalize, status_of, with_status};
use saga::view::{ViewModel, file_text, render};
use std::path::Path;

fn model(parts: &[&str], kinds: &[&str], roles: &[&str]) -> ViewModel {
    ViewModel {
        parts: parts.iter().map(|s| s.to_string()).collect(),
        ids: (0..parts.len()).map(|i| format!("e{i}")).collect(),
        kinds: kinds.iter().map(|s| s.to_string()).collect(),
        roles: roles.iter().map(|s| s.to_string()).collect(),
        version: 7,
    }
}

#[test]
fn file_words_map_to_the_graphs_statuses() {
    for (raw, want) in [
        ("open", "open"),
        ("fixed in M2", "done"),
        ("closed: not needed", "done"),
        ("DONE", "done"),
        ("CANCELLED", "dropped"),
        ("wontfix", "dropped"),
        ("STARTED", "running"),
        ("in progress", "running"),
        ("WAITING", "waiting"),
        ("blocked on X", "blocked"),
        ("TODO", "open"),
        ("NEXT", "open"),
        ("something odd", "open"),
    ] {
        assert_eq!(normalize(raw), want, "{raw}");
        assert!(STATUSES.contains(&want));
    }
}

#[test]
fn a_status_written_into_text_reads_back() {
    let row = "| D-1 | area | text | open |\n";
    let done = with_status("todo", "row", row, "done").unwrap();
    assert_eq!(done, "| D-1 | area | text | done |\n");
    assert_eq!(status_of("todo", "row", &done).as_deref(), Some("done"));
    assert_eq!(with_status("todo", "row", &done, "done"), None);
    let org = "** TODO Write it :tag:\nbody\n";
    let s = with_status("task", "item", org, "running").unwrap();
    assert_eq!(s, "** STARTED Write it :tag:\nbody\n");
    // a keyword of the file's own is left alone
    assert_eq!(
        with_status("task", "item", "* BLOCKED Child\n", "waiting"),
        None
    );
    let plan = "### Task 1\n- [ ] one\n- [ ] two\n";
    let ticked = with_status("task", "task", plan, "done").unwrap();
    assert_eq!(ticked, "### Task 1\n- [x] one\n- [x] two\n");
    assert_eq!(status_of("task", "task", &ticked).as_deref(), Some("done"));
    assert_eq!(with_status("task", "task", &ticked, "open").unwrap(), plan);
}

#[test]
fn an_untouched_view_is_no_proposal() {
    let m = model(&["a\n", "b\n"], &["note", "note"], &["head", "block"]);
    let view = file_text(Path::new("x.md"), &m);
    let p = read(&view, &view, &m);
    assert!(p.ops.is_empty() && p.unmapped.is_empty() && p.diff.is_empty());
    assert_eq!(p.base_version, 7);
    assert_eq!(render(&m), "a\nb\n");
}

#[test]
fn a_changed_line_is_one_op_on_its_piece() {
    let m = model(
        &[
            "# T\n",
            "| 1 | x | one | open |\n",
            "| 2 | x | two | open |\n",
        ],
        &["note", "todo", "todo"],
        &["head", "row", "row"],
    );
    let view = file_text(Path::new("x.md"), &m);
    let edited = view.replace("two | open", "two | done");
    let p = read(&view, &edited, &m);
    assert_eq!(p.ops.len(), 1);
    assert_eq!(p.ops[0].id, "e2");
    assert_eq!(p.ops[0].body, "| 2 | x | two | done |\n");
    assert_eq!(p.ops[0].status.as_deref(), Some("done"));
    assert!(
        p.diff.contains("-| 2 | x | two | open |") && p.diff.contains("+| 2 | x | two | done |")
    );
    assert!(p.unmapped.is_empty() && p.user_only.is_empty());
}

#[test]
fn an_inserted_line_joins_the_piece_before_and_a_deleted_piece_is_unmapped() {
    let m = model(
        &["h\n", "r1\n", "mid\n", "r2\n"],
        &["note", "note", "note", "note"],
        &["head", "block", "block", "block"],
    );
    let view = file_text(Path::new("x.md"), &m);
    let edited = view.replace("r1\n", "r1\nnew\n").replace("r2\n", "");
    let p = read(&view, &edited, &m);
    assert_eq!(p.ops.len(), 1);
    assert_eq!(p.ops[0].body, "r1\nnew\n");
    assert_eq!(p.unmapped.len(), 1);
    let at = p.unmapped[0].start;
    assert_eq!(&edited[at..], "", "the deleted piece was last");
}

#[test]
fn a_user_only_field_is_flagged() {
    let m = model(&["h\n"], &["plan"], &["head"]);
    let view = file_text(Path::new("x.md"), &m);
    let p = read(&view, &view.replace("h\n", "h\nmatrix: allow\n"), &m);
    assert_eq!(p.user_only, ["e0"]);
}
