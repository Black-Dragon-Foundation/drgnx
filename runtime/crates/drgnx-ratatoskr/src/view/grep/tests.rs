use super::*;
use runstav::methods::view::{Display, ViewEnv};

const CONN: u64 = 1;

fn env(class: &str, epoch: u64) -> ViewEnv {
    ViewEnv {
        view: "s".into(),
        class: class.into(),
        epoch,
        display: Display::Gui,
        scale: 1.0,
        fonts: vec![],
        cell: (8, 16),
        width_px: 400,
        palette: vec![],
        tty_widths: vec![],
        tz: String::new(),
        reduced_motion: false,
    }
}

fn m(file: &str, line: u32, before: &str, text: &str, after: &str) -> Match {
    Match {
        file: file.into(),
        line,
        col: before.chars().count() as u32,
        end: (before.chars().count() + text.chars().count()) as u32,
        text: text.into(),
        before: before.into(),
        after: after.into(),
    }
}

fn query() -> Query {
    Query {
        root: "/r".into(),
        text: "needle".into(),
        ..Query::default()
    }
}

fn store() -> Store {
    let mut s = Store::new(7);
    s.env(CONN, env("gui-1", 1));
    s
}

fn run_of(greps: &Greps, replace: &str) -> u64 {
    greps.start(CONN, "s", query(), replace.into()).0
}

#[test]
fn streams_rows_per_file() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    let first = start_patches(&mut s, CONN, "s");
    assert_eq!(first.len(), 1);
    assert_eq!(first[0].ops, vec![Op::Reset(vec![])]);
    let mut seen = Vec::new();
    for (file, n) in [("/r/a.txt", 2), ("/r/sub/b.txt", 1)] {
        let ms = (0..n)
            .map(|i| m(file, i + 1, "x ", "needle", " y"))
            .collect();
        let (_, p) = greps
            .with(CONN, "s", id, |run| {
                batch_patches(&mut s, CONN, "s", run, file.into(), ms)
            })
            .unwrap();
        assert_eq!(p.len(), 1);
        seen.push(p.into_iter().next().unwrap());
    }
    // one insert per file: its header, then its matches, after the row before
    let Op::Insert { after, rows } = &seen[0].ops[0] else {
        panic!("{:?}", seen[0].ops)
    };
    assert_eq!(after, &None);
    assert_eq!(
        rows.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(),
        ["f:/r/a.txt", "m:/r/a.txt:1:2", "m:/r/a.txt:2:2"]
    );
    let Op::Insert { after, rows } = &seen[1].ops[0] else {
        panic!("{:?}", seen[1].ops)
    };
    assert_eq!(after.as_deref(), Some("m:/r/a.txt:2:2"));
    assert_eq!(rows.len(), 2);
    assert_eq!(
        (seen[0].base, seen[0].version, seen[1].base, seen[1].version),
        (
            first[0].version,
            first[0].version + 1,
            first[0].version + 1,
            first[0].version + 2
        )
    );
    assert_eq!(rows[0].text, "[x] b.txt  sub/");
}

/// [D] Each file's batch sends the model first: a `tree` of the files in the rows' order, each open, its matches as
/// children with what Replace writes from; the rows it names carry the node ids, and a later batch is a diff.
#[test]
fn grep_model_is_a_tree_of_files_and_matches() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    start_patches(&mut s, CONN, "s");
    let (model, p) = greps
        .with(CONN, "s", id, |run| {
            batch_patches(
                &mut s,
                CONN,
                "s",
                run,
                "/r/a.txt".into(),
                vec![m("/r/a.txt", 3, "let ", "needle", ";")],
            )
        })
        .unwrap();
    let model = model.expect("the first batch's model");
    assert!(model.reset);
    assert_eq!(p[0].model, Some(model.version), "the rows name the model");
    let v: Value = serde_json::from_str(&model.model).unwrap();
    let reset = &v["ops"][0]["reset"];
    assert_eq!(reset["descriptor"]["scheme"], "tree");
    assert_eq!(reset["descriptor"]["flags"], json!(["expanded"]));
    assert_eq!(
        reset["lists"],
        json!([{"name": "order", "ids": ["f:/r/a.txt", "m:/r/a.txt:3:4"]}])
    );
    let nodes = reset["nodes"].as_array().unwrap();
    let file = nodes.iter().find(|n| n["id"] == "f:/r/a.txt").unwrap();
    assert_eq!((&file["kind"], &file["flags"]), (&json!("file"), &json!(1)));
    let hit = nodes.iter().find(|n| n["id"] == "m:/r/a.txt:3:4").unwrap();
    assert_eq!(hit["parent"], "f:/r/a.txt");
    assert_eq!(
        hit["fields"],
        json!([
            ["label", "let needle;"],
            ["file", "/r/a.txt"],
            ["line", 3],
            ["col", 4],
            ["end", 10],
            ["text", "needle"]
        ])
    );
    let Op::Insert { rows, .. } = &p[0].ops[0] else {
        panic!("{:?}", p[0].ops)
    };
    let ids: Vec<&Value> = rows
        .iter()
        .map(|r| &r.props.iter().find(|p| p.2 == "drgnx-work-id").unwrap().3)
        .collect();
    assert_eq!(ids, [&json!("f:/r/a.txt"), &json!("m:/r/a.txt:3:4")]);
    // the next file: a diff, not a reset
    let (model, _) = greps
        .with(CONN, "s", id, |run| {
            batch_patches(
                &mut s,
                CONN,
                "s",
                run,
                "/r/b.txt".into(),
                vec![m("/r/b.txt", 1, "", "needle", "")],
            )
        })
        .unwrap();
    assert!(!model.expect("the second batch's model").reset);
}

#[test]
fn new_query_starts_with_reset() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    start_patches(&mut s, CONN, "s");
    greps
        .with(CONN, "s", id, |run| {
            batch_patches(
                &mut s,
                CONN,
                "s",
                run,
                "/r/a.txt".into(),
                vec![m("/r/a.txt", 1, "", "needle", "")],
            )
        })
        .unwrap();
    // the next search: one reset to no rows, whatever the first one showed
    run_of(&greps, "");
    let again = start_patches(&mut s, CONN, "s");
    assert_eq!(again.len(), 1);
    assert_eq!(again[0].ops, vec![Op::Reset(vec![])]);
    assert_eq!(again[0].version, 3);
}

#[test]
fn late_rows_of_a_stopped_query_are_dropped() {
    let greps = Greps::default();
    let old = run_of(&greps, "");
    let new = run_of(&greps, "");
    assert!(greps.with(CONN, "s", old, |_| ()).is_none());
    assert!(greps.with(CONN, "s", new, |_| ()).is_some());
    greps.stop(CONN, "s");
    assert!(greps.with(CONN, "s", new, |_| ()).is_none());
}

#[test]
fn replace_preview_runs() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    start_patches(&mut s, CONN, "s");
    greps
        .with(CONN, "s", id, |run| {
            batch_patches(
                &mut s,
                CONN,
                "s",
                run,
                "/r/a.txt".into(),
                vec![m("/r/a.txt", 1, "let ", "needle", ";")],
            )
        })
        .unwrap();
    let patches = greps
        .current(CONN, "s", |run| {
            run.replace = "pin".into();
            rebuild_patches(&mut s, CONN, "s", run)
        })
        .unwrap();
    let Op::Replace(rows) = &patches[0].ops[0] else {
        panic!("{:?}", patches[0].ops)
    };
    assert_eq!(rows.len(), 1);
    let row = &rows[0];
    assert_eq!(row.text, "  [x] let needlepin;");
    assert_eq!(
        row.runs,
        vec![
            (10, 16, "drgnx-replace-old".into()),
            (16, 19, "drgnx-replace-new".into())
        ]
    );
    assert_eq!(row.props[0].2, "drgnx-replace-box");
    assert_eq!(row.props[0].3["line"], 1);
    // no replacement: the match alone, in its own face
    let patches = greps
        .current(CONN, "s", |run| {
            run.replace = String::new();
            rebuild_patches(&mut s, CONN, "s", run)
        })
        .unwrap();
    let Op::Replace(rows) = &patches[0].ops[0] else {
        panic!()
    };
    assert_eq!(rows[0].runs, vec![(10, 16, "drgnx-replace-match".into())]);
}

#[test]
fn an_env_after_rows_gets_all_of_them_as_a_reset() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    start_patches(&mut s, CONN, "s");
    // a new epoch: the next patch of the class is a reset of every row so far
    s.env(CONN, env("gui-1", 2));
    let (_, p) = greps
        .with(CONN, "s", id, |run| {
            batch_patches(
                &mut s,
                CONN,
                "s",
                run,
                "/r/a.txt".into(),
                vec![m("/r/a.txt", 1, "", "needle", "")],
            )
        })
        .unwrap();
    let Op::Reset(rows) = &p[0].ops[0] else {
        panic!("{:?}", p[0].ops)
    };
    assert_eq!(rows.len(), 2);
    assert_eq!(p[0].env_epoch, 2);
}
