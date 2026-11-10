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
    let v: &Value = &model.model;
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
    let d = grep_doc_in(&files, 3, None);
    assert_eq!(
        d.lists["order"],
        ["f:/r/a.txt", "m:/r/a.txt:1:0", "m:/r/a.txt:2:0"]
    );
    assert_eq!(d.nodes.len(), 3);
    assert_eq!(d.windows.get("order"), Some(&(6, 0)));
    let all = grep_doc_in(&files, 6, None);
    assert_eq!(all.lists["order"].len(), 6);
    assert!(all.windows.is_empty(), "no window when everything fits");
    // a window from the third entry: a's last two matches and b; a's node is there (their parent), not in `order`
    let mid = grep_doc_in(&files, 3, Some(2));
    assert_eq!(
        mid.lists["order"],
        ["m:/r/a.txt:2:0", "m:/r/a.txt:3:0", "f:/r/b.txt"]
    );
    assert!(mid.nodes.contains_key("f:/r/a.txt"));
    assert_eq!(mid.windows.get("order"), Some(&(6, 2)));
    // past the end: the last window
    let end = grep_doc_in(&files, 3, Some(99));
    assert_eq!(end.windows.get("order"), Some(&(6, 3)));
    assert_eq!(end.lists["order"][2], "m:/r/b.txt:1:0");
    assert_eq!(
        grep_doc_in(&files, 6, Some(4)).windows.len(),
        0,
        "all fits: no window, whatever the from"
    );
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
            let d = grep_doc(&run.files, None);
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

/// Every file sends a model, and what is sent in all is about one whole model, since a list that grew by appending goes
/// as a splice at its end.
#[test]
fn every_file_sends_a_model_and_all_of_them_cost_about_one_whole_model() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    every_batch(&greps, id);
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
            bytes += model.model.to_string().len();
        }
    }
    assert_eq!(sends, 100, "{sends} models for 100 files");
    let whole = greps
        .current(CONN, "s", |run| {
            grep_doc(&run.files, None).reset().to_string().len()
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
        let out = sent
            .publish(grep_doc(&held, None))
            .expect("a model per batch");
        steps.push(json!({"base": out.base, "version": out.version, "reset": out.reset, "model": out.model}));
    }
    let ids = grep_doc(&held, None).lists["order"].clone();
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
        let ops = &step["model"];
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

/// Every file's batch sends a model, of that batch alone: its nodes and a splice at the end of `order`, built without
/// the whole model (SJA-MODEL-CADENCE-1: rebuilding and diffing the whole per batch cost the hub seconds at 10k
/// matches). What the editor then holds is the model whole.
#[test]
fn every_batch_sends_its_own_nodes_and_a_splice() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    every_batch(&greps, id);
    start_patches(&mut s, CONN, "s");
    let mut held = Vec::new();
    // past the rows' window, so the later batches bring no rows; lines 4, 8 and 12 sort apart from their order
    for f in 0..300 {
        let file = format!("/r/f{f:03}.txt");
        let ms: Vec<Match> = (1..=3)
            .map(|i| m(&file, i * 4, "a ", "needle", ""))
            .collect();
        held.push((file.clone(), ms.clone()));
        let (model, _) = greps
            .with(CONN, "s", id, |run| {
                batch_patches(&mut s, CONN, "s", run, file.clone(), ms)
            })
            .unwrap();
        let data = Store::model_data(model.expect("a model per batch"));
        if f > 0 {
            let ops = data["model"]["ops"].as_array().unwrap();
            assert_eq!(ops.len(), 2, "{ops:?}");
            assert_eq!(ops[0]["nodes"].as_array().unwrap().len(), 4);
            assert_eq!(
                ops[1]["splice"],
                json!({"name": "order", "at": 4 * f, "remove": 0,
                       "ids": [format!("f:{file}"), format!("m:{file}:4:2"), format!("m:{file}:8:2"), format!("m:{file}:12:2")]})
            );
        }
    }
    assert!(
        s.publish_model(CONN, "s", grep_doc(&held, None)).is_none(),
        "the editor holds the model whole"
    );
}

/// RUN ID's models go out with every batch (no throttle window), as when batches come further apart than one.
fn every_batch(greps: &Greps, id: u64) {
    greps
        .with(CONN, "s", id, |run| {
            run.model_every = std::time::Duration::ZERO
        })
        .unwrap();
}

/// Within one of the editor's throttle windows the batches that bring no rows send nothing: their appends wait, and
/// the next send carries them all, one `nodes` op and one splice (the editor applies a model no row names a throttle
/// later anyway, and each line it reads costs it a redisplay pass). Rows name the model they were built from, so a
/// batch with rows sends at once.
#[test]
fn appends_within_a_throttle_window_go_in_one_send() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    greps
        .with(CONN, "s", id, |run| {
            run.model_every = std::time::Duration::from_secs(3600)
        })
        .unwrap();
    start_patches(&mut s, CONN, "s");
    let mut held = Vec::new();
    let mut sends = Vec::new();
    // 101 rows a file: the first two fill the rows' window
    for f in 0..10 {
        let file = format!("/r/f{f:03}.txt");
        let ms: Vec<Match> = (1..=100).map(|l| m(&file, l, "a ", "needle", "")).collect();
        held.push((file.clone(), ms.clone()));
        let (model, _) = greps
            .with(CONN, "s", id, |run| {
                batch_patches(&mut s, CONN, "s", run, file.clone(), ms)
            })
            .unwrap();
        sends.push(model.is_some());
    }
    assert_eq!(
        sends,
        [
            true, true, false, false, false, false, false, false, false, false
        ]
    );
    let m = greps
        .with(CONN, "s", id, |run| flush_model(&mut s, CONN, "s", run))
        .unwrap()
        .expect("the waiting appends");
    let ops = Store::model_data(m)["model"]["ops"].clone();
    let ops = ops.as_array().unwrap();
    assert_eq!(ops.len(), 2, "{ops:?}");
    assert_eq!(ops[0]["nodes"].as_array().unwrap().len(), 8 * 101);
    assert_eq!(ops[1]["splice"]["at"], json!(2 * 101));
    assert_eq!(ops[1]["splice"]["ids"].as_array().unwrap().len(), 8 * 101);
    assert!(
        greps
            .with(CONN, "s", id, |run| flush_model(&mut s, CONN, "s", run))
            .unwrap()
            .is_none(),
        "nothing waits"
    );
    assert!(
        s.publish_model(CONN, "s", grep_doc(&held, None)).is_none(),
        "the editor holds the model whole"
    );
}

/// [D] A window move over the same search is the ops the whole model's diff would send, for every start (windows that
/// begin on a file, inside one, at the end), and builds only the nodes the editor does not hold.
#[test]
fn a_window_move_is_the_diff_of_the_whole() {
    let files: Vec<(String, Vec<Match>)> = (0..4)
        .map(|f| {
            let name = format!("/r/f{f}.txt");
            let ms = (1..=4).map(|l| m(&name, l, "", "needle", "")).collect();
            (name, ms)
        })
        .collect();
    for a in 0..14 {
        for b in 0..14 {
            let old = grep_doc_in(&files, 6, Some(a));
            let mut sent = crate::view::model::Sent::default();
            sent.publish(old.clone()).unwrap();
            let new = grep_doc_in(&files, 6, Some(b));
            let w = window_of(&files, 6, Some(b));
            let mut built = 0;
            let m = crate::view::model::WindowMove {
                name: "order",
                window: (w.total, w.from),
                held: &w.held,
                order: w.order.clone(),
            };
            let out = sent.move_window(m, |i| {
                built += 1;
                w.node(i)
            });
            let diff = new.diff(&old);
            match out {
                Some(o) => assert_eq!(o.model, json!({ "ops": diff }), "from {a} to {b}"),
                None => assert!(
                    diff.is_empty(),
                    "from {a} to {b}: no move but a diff {diff:?}"
                ),
            }
            let fresh = new
                .nodes
                .keys()
                .filter(|k| !old.nodes.contains_key(*k))
                .count();
            assert_eq!(
                built, fresh,
                "from {a} to {b}: only the new nodes are built"
            );
        }
    }
}

/// [D] Moves one after another (a page each, the parents the last move left known, not scanned for) are each the ops the
/// whole model's diff would send from the model before, over every pair of starts in a row.
#[test]
fn successive_window_moves_are_the_diff_of_the_whole() {
    let files: Vec<(String, Vec<Match>)> = (0..4)
        .map(|f| {
            let name = format!("/r/f{f}.txt");
            let ms = (1..=4).map(|l| m(&name, l, "", "needle", "")).collect();
            (name, ms)
        })
        .collect();
    for a in 0..14 {
        let mut sent = crate::view::model::Sent::default();
        let mut prev = grep_doc_in(&files, 6, Some(a));
        sent.publish(prev.clone()).unwrap();
        for b in (0..14).chain((0..14).rev()).chain([a, 13, 0, 7]) {
            let new = grep_doc_in(&files, 6, Some(b));
            let w = window_of(&files, 6, Some(b));
            let m = crate::view::model::WindowMove {
                name: "order",
                window: (w.total, w.from),
                held: &w.held,
                order: w.order.clone(),
            };
            let out = sent.move_window(m, |i| w.node(i));
            let diff = new.diff(&prev);
            match out {
                Some(o) => assert_eq!(o.model, json!({ "ops": diff }), "from {a}, to {b}"),
                None => assert!(diff.is_empty(), "from {a}, to {b}: no move but {diff:?}"),
            }
            prev = new;
        }
    }
}

/// [D] Replace All's leftovers (`search/grep-skipped`, SJA-SEARCH-1 (3)): the search lists only the skipped matches,
/// each with its reason after the text, under their files; the model holds them alone, and the search stops.
#[test]
fn skipped_leaves_the_skipped_matches_with_their_reasons() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    start_patches(&mut s, CONN, "s");
    for file in ["/r/a.txt", "/r/b.txt"] {
        let ms = (1..=2).map(|i| m(file, i, "x ", "needle", " y")).collect();
        greps
            .with(CONN, "s", id, |run| {
                batch_patches(&mut s, CONN, "s", run, file.into(), ms)
            })
            .unwrap();
    }
    let why = BTreeMap::from([(
        "m:/r/b.txt:2:2".to_string(),
        "changed since the search".to_string(),
    )]);
    let (model, patches) = greps
        .current(CONN, "s", |run| skip_patches(&mut s, CONN, "s", run, why))
        .unwrap();
    assert!(model.is_some());
    assert!(!patches.is_empty());
    greps.current(CONN, "s", |run| {
        assert!(run.cancel.load(Ordering::Relaxed));
        let left: Vec<(&str, Vec<String>)> = run
            .files
            .iter()
            .map(|(f, ms)| (f.as_str(), ms.iter().map(match_id).collect()))
            .collect();
        assert_eq!(left, [("/r/b.txt", vec!["m:/r/b.txt:2:2".to_string()])]);
        let doc = grep_doc(&run.files, None);
        assert_eq!(doc.lists["order"], ["f:/r/b.txt", "m:/r/b.txt:2:2"]);
    });
    let rows = &s.pairs[&(CONN, "s".to_string(), "gui-1".to_string())].rows;
    assert_eq!(
        rows.iter().map(|r| r.text.as_str()).collect::<Vec<_>>(),
        ["[x] b.txt", "  [x] x needle y  — changed since the search"]
    );
}

/// The keys of the rows the editor holds.
fn held(s: &Store) -> Vec<String> {
    s.pairs[&(CONN, "s".to_string(), "gui-1".to_string())]
        .rows
        .iter()
        .map(|r| r.key.clone())
        .collect()
}

/// [D] SJA-ROWS-FAR-1: a jump far past the rows sent (`upto` a match 29,000 rows on, of a 30,300-row search) sends the
/// rows around it after a gap row, well under 1 MiB, never every row before it (19,000 rows were over the hub's
/// 16 MiB per client); `more` grows the block, `upto` just before it grows it back, `fill` (the gap in sight) grows the
/// rows before the gap, and when they meet the block the gap goes.
#[test]
fn a_far_jump_sends_the_rows_around_it_after_a_gap() {
    let mut s = store();
    let greps = Greps::default();
    let id = run_of(&greps, "");
    start_patches(&mut s, CONN, "s");
    for f in 0..300 {
        let file = format!("/r/f{f:03}.txt");
        let ms = (1..=100)
            .map(|l| m(&file, l, "a ", "needle", " in"))
            .collect();
        greps
            .with(CONN, "s", id, |run| {
                batch_patches(&mut s, CONN, "s", run, file, ms)
            })
            .unwrap();
    }
    let look = |s: &mut Store, l: Look| {
        greps
            .current(CONN, "s", |run| look_patches(s, CONN, "s", run, l))
            .unwrap()
    };
    let size = |ps: &[Patch]| serde_json::to_string(ps).unwrap().len();
    // f287.txt:30 is row 287 * 101 + 30 = 29,017
    let key = "m:/r/f287.txt:30:2".to_owned();
    let jump = look(&mut s, Look::Upto(&key));
    assert!(size(&jump) < 1 << 20, "{} bytes", size(&jump));
    let rows = held(&s);
    let at = rows
        .iter()
        .position(|k| *k == key)
        .expect("the row asked for");
    let gap = rows.iter().position(|k| k == "gap").expect("a gap row");
    assert_eq!(gap, WINDOW, "the first window, then the gap");
    assert_eq!(rows.len() - at - 1, MARGIN);
    assert_eq!(at - gap - 1, MARGIN);
    // more: the block grows at its end
    let n = rows.len();
    let more = look(&mut s, Look::More);
    assert!(size(&more) < 1 << 20);
    assert_eq!(held(&s).len(), n + WINDOW);
    // the match just before the block: the block grows back, the gap row stays
    let first = held(&s)[gap + 1].clone();
    let before = greps
        .current(CONN, "s", |run| {
            let i = row_index(run, &first).unwrap();
            rows_upto(run, i).pop().unwrap().key
        })
        .unwrap();
    look(&mut s, Look::Upto(&before));
    let rows = held(&s);
    assert!(rows.contains(&before));
    assert_eq!(rows.iter().filter(|k| *k == "gap").count(), 1);
    // fill until the rows before the gap reach the block: the gap goes, every row is there once, in order
    for _ in 0..200 {
        if !held(&s).iter().any(|k| k == "gap") {
            break;
        }
        let fill = look(&mut s, Look::Fill);
        assert!(size(&fill) < 1 << 20);
    }
    let rows = held(&s);
    assert!(!rows.iter().any(|k| k == "gap"));
    let all = greps
        .current(CONN, "s", |run| {
            rows_upto(run, rows.len())
                .into_iter()
                .map(|r| r.key)
                .collect::<Vec<_>>()
        })
        .unwrap();
    assert_eq!(rows, all);
}
