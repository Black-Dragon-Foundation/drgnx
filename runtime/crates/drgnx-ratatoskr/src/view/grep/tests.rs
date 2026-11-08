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
        attach: false,
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

/// [D] Past its window the model holds the first entries, its list `order` a window of all of them (Sjá takes no
/// longer list unwindowed).
#[test]
fn grep_model_windows_a_long_search() {
    let files = vec![
        (
            "/r/a.txt".to_owned(),
            (1..=3)
                .map(|l| m("/r/a.txt", l, "", "needle", ""))
                .collect(),
        ),
        (
            "/r/b.txt".to_owned(),
            vec![m("/r/b.txt", 1, "", "needle", "")],
        ),
    ];
    let d = grep_doc_in(&files, 3);
    assert_eq!(
        d.lists["order"],
        ["f:/r/a.txt", "m:/r/a.txt:1:0", "m:/r/a.txt:2:0"]
    );
    assert_eq!(d.nodes.len(), 3);
    assert_eq!(d.windows.get("order"), Some(&(6, 0)));
    let all = grep_doc_in(&files, 6);
    assert_eq!(all.lists["order"].len(), 6);
    assert!(all.windows.is_empty(), "no window when everything fits");
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

/// A search of 100 files holding 100 matches each, handed in file by file; the rows of every patch sent, counted.
fn ten_thousand(greps: &Greps, s: &mut Store, id: u64) -> usize {
    let mut sent = 0;
    for f in 0..100 {
        let file = format!("/r/f{f:03}.txt");
        let ms = (1..=100)
            .map(|l| m(&file, l, "a ", "needle", " in"))
            .collect();
        let (_, patches) = greps
            .with(CONN, "s", id, |run| {
                batch_patches(s, CONN, "s", run, file.clone(), ms)
            })
            .unwrap();
        for p in patches {
            for op in &p.ops {
                if let Op::Insert { rows, .. } = op {
                    sent += rows.len();
                }
            }
        }
    }
    sent
}

/// A 10,000-match search sends the window's rows and no more until the editor asks (`search/grep-look`); the model
/// still holds every match, and the totals are the search's.
#[test]
fn ten_thousand_matches_send_only_the_window_until_asked() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    start_patches(&mut s, CONN, "s");
    let sent = ten_thousand(&greps, &mut s, id);
    assert!(sent <= WINDOW, "{sent} rows sent, the window is {WINDOW}");
    assert!(sent >= WINDOW - 1, "{sent}: the window is filled");
    greps
        .with(CONN, "s", id, |run| {
            assert_eq!(run.files.len(), 100);
            assert_eq!(
                run.files.iter().map(|(_, ms)| ms.len()).sum::<usize>(),
                10_000
            );
            // the model holds the matches beyond the window
            let d = grep_doc(&run.files);
            assert_eq!(d.lists["order"].len(), 10_100);
        })
        .unwrap();
}

/// `more` sends the next window after the last row sent; `upto` a row beyond it (with a margin after it).
#[test]
fn look_sends_the_next_rows_and_the_row_asked_for() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    start_patches(&mut s, CONN, "s");
    ten_thousand(&greps, &mut s, id);
    let rows_of = |ps: &[Patch]| -> Vec<(Option<String>, Vec<String>)> {
        ps.iter()
            .flat_map(|p| p.ops.iter())
            .filter_map(|op| match op {
                Op::Insert { after, rows } => Some((
                    after.clone(),
                    rows.iter().map(|r| r.key.clone()).collect::<Vec<_>>(),
                )),
                _ => None,
            })
            .collect()
    };
    let last = s
        .pairs
        .values()
        .next()
        .unwrap()
        .rows
        .last()
        .unwrap()
        .key
        .clone();
    let more = greps
        .current(CONN, "s", |run| {
            look_patches(&mut s, CONN, "s", run, Look::More)
        })
        .unwrap();
    let ins = rows_of(&more);
    assert_eq!(ins.len(), 1);
    assert_eq!(ins[0].0.as_deref(), Some(last.as_str()));
    assert_eq!(ins[0].1.len(), WINDOW);
    // a match 5,000 rows down: the window reaches it and a margin, nothing before is sent twice
    let key = "m:/r/f050.txt:10:2".to_owned();
    let upto = greps
        .current(CONN, "s", |run| {
            look_patches(&mut s, CONN, "s", run, Look::Upto(&key))
        })
        .unwrap();
    let ins = rows_of(&upto);
    let flat: Vec<&String> = ins.iter().flat_map(|(_, k)| k).collect();
    assert!(flat.contains(&&key));
    assert_eq!(flat.iter().filter(|k| ***k == key).count(), 1);
    let at = flat.iter().position(|k| **k == key).unwrap();
    assert_eq!(flat.len() - at - 1, MARGIN);
    // asking again for a row already sent sends nothing
    let again = greps
        .current(CONN, "s", |run| {
            look_patches(&mut s, CONN, "s", run, Look::Upto(&key))
        })
        .unwrap();
    assert!(again.is_empty());
}

/// The replacement's preview patches the rows sent, not the ones the window has not reached.
#[test]
fn replace_previews_the_window_only() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    start_patches(&mut s, CONN, "s");
    ten_thousand(&greps, &mut s, id);
    let patches = greps
        .current(CONN, "s", |run| {
            run.replace = "pin".into();
            rebuild_patches(&mut s, CONN, "s", run)
        })
        .unwrap();
    let n: usize = patches
        .iter()
        .flat_map(|p| p.ops.iter())
        .map(|op| match op {
            Op::Replace(rows) => rows.len(),
            _ => 0,
        })
        .sum();
    assert!(n > 0 && n <= WINDOW, "{n}");
}

/// Once the rows' window is full the model is sent when the search has doubled it (each send is a delta, but each send
/// costs the editor a redisplay and a queue entry: 101 sends cost five times the CPU of 9), and what is sent in all is
/// about one whole model, since a list that grew by appending goes as a splice at its end.
#[test]
fn the_model_grows_by_doubling_and_costs_about_one_whole_model() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    start_patches(&mut s, CONN, "s");
    let (mut sends, mut bytes) = (0, 0);
    for f in 0..100 {
        let file = format!("/r/f{f:03}.txt");
        let ms = (1..=100)
            .map(|l| m(&file, l, "a ", "needle", " in"))
            .collect();
        let (model, _) = greps
            .with(CONN, "s", id, |run| {
                batch_patches(&mut s, CONN, "s", run, file.clone(), ms)
            })
            .unwrap();
        if let Some(model) = model {
            sends += 1;
            bytes += json!(model)["model"].as_str().unwrap().len();
        }
    }
    assert!((3..=20).contains(&sends), "{sends} models for 100 files");
    let whole = greps
        .current(CONN, "s", |run| {
            grep_doc(&run.files).reset().to_string().len()
        })
        .unwrap();
    assert!(
        bytes * 10 <= whole * 12,
        "{bytes} bytes sent, the whole model is {whole}"
    );
}

/// The model stream of a grow-by-appending search, as the hub writes it, is what Nidhogg's Sjá loads: the same JSON
/// file sits in Nidhogg's test tree (`sja/tests/fixtures/grep-append.json`), where a test applies it. `UPDATE_SJA_FIXTURES=1` rewrites it here;
/// copy it to Nidhogg's tree.
#[test]
fn the_model_stream_is_the_fixture_sja_loads() {
    let mut sent = super::super::model::Sent::default();
    let files = [
        (
            "/r/a.txt",
            vec![
                m("/r/a.txt", 1, "x ", "needle", " y"),
                m("/r/a.txt", 5, "", "needle", ""),
            ],
        ),
        ("/r/b.txt", vec![m("/r/b.txt", 2, "", "needle", " z")]),
        (
            "/r/c.txt",
            vec![
                m("/r/c.txt", 9, "p ", "needle", ""),
                m("/r/c.txt", 10, "", "needle", "q"),
            ],
        ),
    ];
    let mut held: Vec<(String, Vec<Match>)> = Vec::new();
    let mut steps = Vec::new();
    for (file, ms) in files {
        held.push((file.to_owned(), ms));
        let out = sent.publish(grep_doc(&held)).expect("a model per batch");
        steps.push(json!({"base": out.base, "version": out.version, "reset": out.reset, "model": out.model}));
    }
    let ids = grep_doc(&held).lists["order"].clone();
    let now = json!({"list": "order", "ids": ids, "steps": steps});
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/grep-append.json"
    );
    if std::env::var_os("UPDATE_SJA_FIXTURES").is_some() {
        std::fs::write(
            path,
            format!("{}\n", serde_json::to_string_pretty(&now).unwrap()),
        )
        .unwrap();
    }
    let have: Value =
        serde_json::from_str(include_str!("../../../tests/fixtures/grep-append.json")).unwrap();
    assert_eq!(
        have, now,
        "the fixture is stale: UPDATE_SJA_FIXTURES=1 rewrites it"
    );
    // the second and third sends carry the appended ids as a splice at the end of the list, not the list
    for step in &steps[1..] {
        let ops: Value = serde_json::from_str(step["model"].as_str().unwrap()).unwrap();
        let list_ops: Vec<&Value> = ops["ops"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|o| o.get("list").is_some() || o.get("splice").is_some())
            .collect();
        assert_eq!(list_ops.len(), 1);
        assert!(list_ops[0].get("splice").is_some(), "{list_ops:?}");
    }
}
