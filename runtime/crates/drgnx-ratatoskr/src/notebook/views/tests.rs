//! The outline's rows and the views' wiring, against a recording stage and a real notebook (no kernel).

use std::collections::HashSet;
use std::sync::Mutex;

use super::*;
use crate::notebook::spec::private_folder;

fn cell(id: &str, kind: Kind, line: &str, count: Option<i64>, state: &'static str) -> OutlineCell {
    OutlineCell {
        id: id.into(),
        kind,
        first_line: line.into(),
        execution_count: count,
        state,
        stale: false,
    }
}

#[test]
fn an_outline_row_has_index_type_prompt_first_line_and_state_and_names_its_cell() {
    let cells = vec![
        cell("a", Kind::Code, "import os", Some(5), ""),
        cell("b", Kind::Markdown, "# Title", None, ""),
        cell("c", Kind::Code, "1/0", Some(6), "error"),
        cell("d", Kind::Code, "slow()", None, "running"),
    ];
    let rows = outline_rows(&cells, 4);
    assert_eq!(rows.len(), 4);
    assert_eq!(rows[0].key, "cell:a");
    assert_eq!(rows[0].text, "1  code    [5]    import os");
    assert_eq!(rows[1].text, "2  markdown       # Title");
    assert_eq!(rows[2].text, "3  code    [6]    1/0  error");
    assert_eq!(rows[3].text, "4  code    [*]    slow()  running");
    for (r, c) in rows.iter().zip(&cells) {
        let len = r.text.chars().count() as u32;
        assert_eq!(
            r.props,
            vec![(0, len, "drgnx-notebook-cell".to_string(), json!(c.id))]
        );
    }
    assert!(
        rows[2]
            .runs
            .iter()
            .any(|(_, _, f)| f == "drgnx-status-fail")
    );
    assert!(
        rows[3]
            .runs
            .iter()
            .any(|(_, _, f)| f == "drgnx-status-warn")
    );
}

#[test]
fn a_cell_that_never_ran_has_an_empty_prompt_and_a_stale_one_is_dim() {
    let mut c = cell("a", Kind::Code, "x", None, "");
    let r = &outline_rows(&[c.clone()], 1)[0];
    assert_eq!(r.text, "1  code    [ ]    x");
    c.stale = true;
    c.execution_count = Some(2);
    let r = &outline_rows(&[c], 1)[0];
    assert!(r.runs.iter().any(|(_, _, f)| f == "drgnx-notebook-stale"));
}

#[test]
fn the_outline_lists_a_bounded_number_of_cells_and_says_how_many_it_left_out() {
    let cells: Vec<OutlineCell> = (0..OUTLINE_ROWS)
        .map(|i| cell(&format!("c{i}"), Kind::Code, "x", None, ""))
        .collect();
    let rows = outline_rows(&cells, 5000);
    assert_eq!(rows.len(), OUTLINE_ROWS + 1);
    assert_eq!(rows.last().unwrap().text, "3000 more cells");
    // indexes line up at the width of the whole count
    assert!(rows[0].text.starts_with("   1  code"));
}

#[test]
fn the_first_line_skips_blanks_drops_controls_and_direction_marks_and_is_cut() {
    assert_eq!(first_line("\n  \n\t x = 1\ny = 2"), "x = 1");
    assert_eq!(first_line(""), "");
    assert_eq!(first_line("a\u{202e}b\u{7}c\td"), "abc d");
    let long = "x".repeat(500);
    let f = first_line(&long);
    assert_eq!(f.chars().count(), FIRST_LINE_CHARS);
    assert!(f.ends_with('\u{2026}'));
    // a huge line costs no more than its start
    let huge = "y".repeat(8 << 20);
    assert_eq!(first_line(&huge).chars().count(), FIRST_LINE_CHARS);
}

/// An editor that hears nothing.
struct Quiet;

impl Sink for Quiet {
    fn broadcast(&self, _: &str, _: Value, _: Option<u64>) {}
    fn send(&self, _: u64, _: &str, _: Value) -> bool {
        true
    }
}

#[derive(Default)]
struct Recorder {
    shown: Mutex<HashSet<String>>,
    got: Mutex<Vec<(u64, String, Vec<String>)>>,
}

impl Stage for Recorder {
    fn shown(&self, _: u64, view: &str) -> bool {
        self.shown.lock().unwrap().contains(view)
    }
    fn publish(&self, conn: u64, view: &str, rows: Vec<Row>) {
        self.got.lock().unwrap().push((
            conn,
            view.into(),
            rows.into_iter().map(|r| r.text).collect(),
        ));
    }
}

const NB: &str = r##"{"cells": [
 {"cell_type": "code", "id": "a", "metadata": {}, "execution_count": 3, "outputs": [], "source": ["print(1)"]},
 {"cell_type": "markdown", "id": "b", "metadata": {}, "source": ["# Hi"]}
 ], "metadata": {}, "nbformat": 4, "nbformat_minor": 5}"##;

struct World {
    _d: tempfile::TempDir,
    nb: Arc<Notebooks>,
    views: Arc<NbViews>,
    stage: Arc<Recorder>,
    id: String,
}

async fn world() -> World {
    let d = tempfile::Builder::new()
        .prefix("nv")
        .tempdir_in("/tmp")
        .unwrap();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let path = d.path().join("n.ipynb");
    std::fs::write(&path, NB).unwrap();
    let views = Arc::new(NbViews::default());
    let sink = Arc::new(WatchSink {
        inner: Arc::new(Quiet),
        views: views.clone(),
    });
    let nb = Arc::new(Notebooks::new(
        sink,
        folder,
        vec![],
        crate::notebook::kernel::Timeouts::default(),
    ));
    let stage = Arc::new(Recorder::default());
    views.attach_stage(&nb, stage.clone());
    let id = nb.open(1, &path, None).await.unwrap().id;
    World {
        _d: d,
        nb,
        views,
        stage,
        id,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_shown_outline_is_built_from_the_notebook_and_a_view_nobody_shows_is_not() {
    let w = world().await;
    let view = w.views.register(1, &w.id, NotebookViewKind::Outline);
    assert_eq!(view, format!("notebook-outline:{}", w.id));
    w.views.mark(1, &w.id);
    w.views.flush().await;
    assert!(w.stage.got.lock().unwrap().is_empty(), "no class shows it");
    w.stage.shown.lock().unwrap().insert(view.clone());
    w.views.mark(1, &w.id);
    w.views.flush().await;
    let got = w.stage.got.lock().unwrap().clone();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].0, 1);
    assert_eq!(got[0].1, view);
    assert_eq!(
        got[0].2,
        vec!["1  code    [3]    print(1)", "2  markdown       # Hi"]
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn only_the_owner_gets_a_view_and_a_close_forgets_it() {
    let w = world().await;
    assert!(w.nb.owns(1, &w.id));
    assert!(
        !w.nb.owns(2, &w.id),
        "an id says nothing to another connection"
    );
    w.views.register(1, &w.id, NotebookViewKind::Outline);
    assert_eq!(w.views.watched().len(), 1);
    w.views.closed(1, &w.id);
    assert!(w.views.watched().is_empty());
    w.views.register(1, &w.id, NotebookViewKind::Outline);
    w.views.gone(1);
    assert!(w.views.watched().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn an_env_for_a_view_nobody_asked_for_builds_nothing() {
    let w = world().await;
    assert!(
        !w.views.env_build(1, &outline_view(&w.id)),
        "not registered"
    );
    assert!(!w.views.env_build(1, "extensions"));
    w.views.register(1, &w.id, NotebookViewKind::Outline);
    assert!(
        !w.views.env_build(2, &outline_view(&w.id)),
        "another connection's"
    );
    assert!(w.views.env_build(1, &outline_view(&w.id)));
}

#[cfg(feature = "test-hooks")]
#[test]
fn changes_are_rebuilt_once_after_the_pause_on_the_virtual_clock() {
    crate::clock::install_virtual();
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .on_thread_park(crate::clock::worker_parks)
        .on_thread_unpark(crate::clock::worker_unparks)
        .build()
        .unwrap();
    rt.block_on(async {
        let w = world().await;
        let view = w.views.register(1, &w.id, NotebookViewKind::Outline);
        w.stage.shown.lock().unwrap().insert(view);
        for _ in 0..5 {
            w.views.changed(1, &w.id);
        }
        crate::clock::advance(VIEW_EVERY / 2).await;
        assert!(
            w.stage.got.lock().unwrap().is_empty(),
            "not before the pause"
        );
        crate::clock::advance(VIEW_EVERY).await;
        assert_eq!(
            w.stage.got.lock().unwrap().len(),
            1,
            "five changes, one rebuild"
        );
    });
}
