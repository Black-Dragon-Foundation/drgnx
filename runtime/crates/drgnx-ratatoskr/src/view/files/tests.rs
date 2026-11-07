use super::*;
use std::cell::Cell;

const CONN: u64 = 1;

fn key(root: &str) -> ListKey {
    (root.into(), false, vec![])
}

fn view(v: &str) -> (u64, String) {
    (CONN, v.into())
}

/// LISTS' names of ROOT for view V, counting the listings in N.
fn get(
    lists: &Lists,
    root: &str,
    v: &str,
    n: &Cell<u32>,
    tap: Option<Receiver<WatchEvent>>,
) -> usize {
    lists
        .get(
            &key(root),
            view(v),
            || {
                n.set(n.get() + 1);
                Ok(vec!["a.rs".into(), "b.rs".into()])
            },
            || tap,
        )
        .unwrap()
        .len()
}

/// Pattern D. A newer query of a view stops the one before: its flag is set and its rows are not kept or sent.
#[test]
fn a_newer_query_stops_the_old_one() {
    let files = Files::default();
    let (first, cancel) = files.start(CONN, "q");
    let (second, _) = files.start(CONN, "q");
    assert!(cancel.load(Ordering::Relaxed));
    assert_eq!(files.finish(CONN, "q", first, vec![], |_| ()), None);
    let rows = vec![row(&Ranked {
        path: "src/map.rs".into(),
        runs: vec![(4, 7)],
    })];
    assert_eq!(files.finish(CONN, "q", second, rows, |r| r.len()), Some(1));
    // the rows stay for the next query until it sends its own
    files.start(CONN, "q");
    assert_eq!(files.rows(CONN, "q").map(|r| r.len()), Some(1));
    files.stop(CONN, "q");
    assert_eq!(files.rows(CONN, "q"), None);
}

/// Pattern D. A row is the path, keyed by it, the query's words in the match face.
#[test]
fn a_row_marks_the_words() {
    let r = row(&Ranked {
        path: "src/map.rs".into(),
        runs: vec![(0, 3), (4, 7)],
    });
    assert_eq!(r.key, "src/map.rs");
    assert_eq!(r.text, "src/map.rs");
    assert_eq!(
        serde_json::to_value(&r).unwrap()["runs"],
        json!([[0, 3, MATCH_FACE], [4, 7, MATCH_FACE]])
    );
}

/// Pattern D. The call's rule wins; without one the setting decides; `index` when neither says `real`.
#[test]
fn the_call_wins_else_the_setting() {
    let real = json!("real");
    let index = json!("index");
    assert_eq!(
        ignore_of(Some(GrepIgnore::Real), Some(&index)),
        Ignore::Real
    );
    assert_eq!(
        ignore_of(Some(GrepIgnore::Index), Some(&real)),
        Ignore::Index
    );
    assert_eq!(ignore_of(None, Some(&real)), Ignore::Real);
    assert_eq!(ignore_of(None, Some(&index)), Ignore::Index);
    assert_eq!(ignore_of(None, None), Ignore::Index);
}

/// Pattern D. Unwatched, a root is listed once per view: the keys of one Quick Open rank one listing, the next Quick
/// Open lists again.
#[test]
fn an_unwatched_root_is_listed_once_per_view() {
    let (lists, n) = (Lists::default(), Cell::new(0));
    assert_eq!(get(&lists, "/r", "q1", &n, None), 2);
    get(&lists, "/r", "q1", &n, None);
    assert_eq!(n.get(), 1);
    get(&lists, "/r", "q2", &n, None);
    assert_eq!(n.get(), 2);
}

/// Pattern D. Watched, a listing serves every view until the watcher reports a change.
#[test]
fn a_watched_root_is_listed_again_after_a_change() {
    let (lists, n) = (Lists::default(), Cell::new(0));
    let (tx, rx) = std::sync::mpsc::channel();
    get(&lists, "/r", "q1", &n, Some(rx));
    get(&lists, "/r", "q2", &n, None);
    assert_eq!(n.get(), 1);
    tx.send(WatchEvent::File {
        tree: hrafn::MAIN_TREE.into(),
        rel: "new.rs".into(),
    })
    .unwrap();
    get(&lists, "/r", "q2", &n, None);
    assert_eq!(n.get(), 2);
}

/// Pattern D. At most `LISTS_MAX` roots are kept; the one used longest ago goes.
#[test]
fn the_kept_lists_are_bounded() {
    let (lists, n) = (Lists::default(), Cell::new(0));
    for i in 0..=LISTS_MAX {
        get(&lists, &format!("/r{i}"), "q", &n, None);
    }
    assert_eq!(lock(&lists.lists).len(), LISTS_MAX);
    assert!(!lock(&lists.lists).contains_key(&key("/r0")));
}
