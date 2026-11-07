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
        let p = greps
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
    let p = greps
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
