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
    from: std::sync::atomic::AtomicUsize,
}

impl Stage for Recorder {
    fn shown(&self, _: u64, view: &str) -> bool {
        self.shown.lock().unwrap().contains(view)
    }
    fn window(&self, _: u64, _: &str) -> usize {
        self.from.load(std::sync::atomic::Ordering::SeqCst)
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
    let view = w
        .views
        .register(1, &w.id, NotebookViewKind::Outline, None)
        .unwrap();
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
    w.views
        .register(1, &w.id, NotebookViewKind::Outline, None)
        .unwrap();
    assert_eq!(w.views.watched().len(), 1);
    w.views.closed(1, &w.id);
    assert!(w.views.watched().is_empty());
    w.views
        .register(1, &w.id, NotebookViewKind::Outline, None)
        .unwrap();
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
    w.views
        .register(1, &w.id, NotebookViewKind::Outline, None)
        .unwrap();
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
        let view = w
            .views
            .register(1, &w.id, NotebookViewKind::Outline, None)
            .unwrap();
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

// ---- the full output of one cell ----

fn run_with(feed: impl FnOnce(&mut dyn FnMut(&str, Value))) -> CellRun {
    use crate::notebook::output::{Change, Router};
    use crate::notebook::session::Channel;
    use crate::notebook::wire::Message;
    let mut r = Router::new();
    r.begin("r");
    feed(&mut |t, c| {
        let mut m = Message::request("k", t, c);
        m.parent = json!({"msg_id": "r"});
        assert_eq!(r.apply(Channel::Iopub, &m), Some(Change::Run("r".into())));
    });
    r.run("r").unwrap().clone()
}

fn lines(n: usize) -> CellRun {
    let text: String = (0..n).map(|i| format!("line {i}\n")).collect();
    run_with(|f| f("stream", json!({"name": "stdout", "text": text})))
}

#[test]
fn a_full_output_is_a_window_of_its_lines_with_rows_counting_what_lies_outside() {
    let run = lines(2500); // 2501 lines, the last empty
    let rows = output_rows("c", &run, 0);
    assert_eq!(rows.len(), OUTPUT_WINDOW + 1);
    assert_eq!(rows[0].key, "l:0");
    assert_eq!(rows[0].text, "line 0");
    assert_eq!(rows[OUTPUT_WINDOW].key, "below");
    assert_eq!(rows[OUTPUT_WINDOW].text, "1501 lines below");
    assert_eq!(
        rows[0].props,
        vec![
            (0, 6, "drgnx-notebook-cell".to_string(), json!("c")),
            (0, 6, "drgnx-notebook-line".to_string(), json!(1)),
        ]
    );
    let rows = output_rows("c", &run, 1200);
    assert_eq!(rows[0].text, "1200 lines above");
    assert_eq!(rows[1].key, "l:1200");
    assert_eq!(rows[1].text, "line 1200");
    assert_eq!(rows.last().unwrap().text, "301 lines below");
    // a window past the end comes back to the last line
    let rows = output_rows("c", &run, 1_000_000);
    assert_eq!(rows.last().unwrap().key, "l:2500");
    assert_eq!(rows.len(), 2);
    // everything fits: no row counts anything
    let rows = output_rows("c", &lines(3), 0);
    assert_eq!(
        rows.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(),
        ["l:0", "l:1", "l:2", "l:3"]
    );
}

#[test]
fn styled_text_carries_the_themes_terminal_roles_and_no_output_says_so() {
    let run = run_with(|f| {
        f(
            "stream",
            json!({"name": "stdout", "text": "ok \x1b[1;31mbad\x1b[0m"}),
        )
    });
    let r = &output_rows("c", &run, 0)[0];
    assert_eq!(r.text, "ok bad");
    assert!(
        r.runs
            .contains(&(3, 6, "drgnx-notebook-fg-red".to_string()))
    );
    assert!(r.runs.contains(&(3, 6, "bold".to_string())));
    let none = output_rows("c", &run_with(|_| {}), 0);
    assert_eq!(none.len(), 1);
    assert_eq!(none[0].text, "no output");
}

#[test]
fn an_image_is_a_row_that_says_so_and_kernel_svg_is_never_in_a_row() {
    use base64::Engine;
    let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    png.extend(10u32.to_be_bytes());
    png.extend(20u32.to_be_bytes());
    png.extend([8, 6, 0, 0, 0, 0, 0, 0, 0]);
    let b64 = base64::engine::general_purpose::STANDARD.encode(&png);
    let run = run_with(|f| {
        f(
            "display_data",
            json!({"data": {"image/png": b64, "text/plain": "<Figure>"}}),
        );
        f(
            "display_data",
            json!({"data": {"image/svg+xml": "<svg onload=evil()/>", "text/plain": "<Fig2>"}}),
        );
    });
    let rows = output_rows("c", &run, 0);
    assert_eq!(
        rows[0].text,
        "[image/png image, 10x20: save output as file]"
    );
    assert!(rows[0].images.is_empty());
    for r in &rows {
        assert!(
            !r.text.contains("<svg") && !r.text.contains("evil"),
            "{}",
            r.text
        );
        assert!(r.images.is_empty());
    }
    assert!(rows.iter().any(|r| r.text.contains("SVG output not shown")));
}

#[test]
fn full_output_views_are_numbered_per_notebook_bounded_and_given_back_when_closed() {
    let views = NbViews::default();
    let a = views
        .register(1, "nb", NotebookViewKind::Output, Some("a"))
        .unwrap();
    assert_eq!(a, "notebook-output:nb#0");
    assert_eq!(
        views
            .register(1, "nb", NotebookViewKind::Output, Some("a"))
            .unwrap(),
        a,
        "the same cell is the same view"
    );
    assert!(
        views
            .register(1, "nb", NotebookViewKind::Output, None)
            .is_err()
    );
    for i in 1..OUTPUT_VIEWS {
        views
            .register(1, "nb", NotebookViewKind::Output, Some(&format!("c{i}")))
            .unwrap();
    }
    assert!(
        views
            .register(1, "nb", NotebookViewKind::Output, Some("one more"))
            .is_err(),
        "at most {OUTPUT_VIEWS} at once"
    );
    views.view_closed(1, "notebook-output:nb#3");
    assert_eq!(
        views
            .register(1, "nb", NotebookViewKind::Output, Some("one more"))
            .unwrap(),
        "notebook-output:nb#3"
    );
    // another notebook or connection has its own numbers
    assert_eq!(
        views
            .register(2, "nb", NotebookViewKind::Output, Some("z"))
            .unwrap(),
        "notebook-output:nb#0"
    );
}

const NB_OUT: &str = r##"{"cells": [
 {"cell_type": "code", "id": "a", "metadata": {}, "execution_count": 1, "outputs": [
   {"output_type": "stream", "name": "stdout", "text": ["one\n", "two\n"]}], "source": ["x"]}
 ], "metadata": {}, "nbformat": 4, "nbformat_minor": 5}"##;

#[tokio::test(flavor = "multi_thread")]
async fn a_shown_full_output_is_built_from_the_notebook_in_the_editors_window_and_a_gone_cell_says_so()
 {
    let w = world().await;
    std::fs::write(w._d.path().join("o.ipynb"), NB_OUT).unwrap();
    let id =
        w.nb.open(1, &w._d.path().join("o.ipynb"), None)
            .await
            .unwrap()
            .id;
    let view = w
        .views
        .register(1, &id, NotebookViewKind::Output, Some("a"))
        .unwrap();
    assert!(!w.views.env_build(2, &view), "another connection's");
    assert!(w.views.env_build(1, &view));
    w.views.flush().await;
    assert!(w.stage.got.lock().unwrap().is_empty(), "no class shows it");
    w.stage.shown.lock().unwrap().insert(view.clone());
    w.stage.from.store(1, std::sync::atomic::Ordering::SeqCst);
    assert!(w.views.window(1, &view), "a moved window builds it again");
    w.views.flush().await;
    let got = w.stage.got.lock().unwrap().clone();
    assert_eq!(got.last().unwrap().1, view);
    assert_eq!(got.last().unwrap().2, vec!["1 lines above", "two", ""]);
    // a cell that is not in the notebook
    let gone = w
        .views
        .register(1, &id, NotebookViewKind::Output, Some("zz"))
        .unwrap();
    w.stage.shown.lock().unwrap().insert(gone.clone());
    assert!(w.views.env_build(1, &gone));
    w.views.flush().await;
    assert_eq!(
        w.stage.got.lock().unwrap().last().unwrap().2,
        vec!["the cell is gone"]
    );
}
