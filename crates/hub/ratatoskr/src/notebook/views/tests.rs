//! The outline's rows and the views' wiring, against a recording stage and a real notebook (no kernel).

use std::collections::HashSet;
use std::sync::Mutex;

use super::*;
use crate::notebook::spec::private_folder;
use rodd::faces::FaceId;

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
    let rows = outline_rows(&cells, 4, None);
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
            vec![(0, len, FaceId::NotebookCell.name().to_string(), json!(c.id))]
        );
    }
    assert!(
        rows[2]
            .runs
            .iter()
            .any(|(_, _, f)| f == FaceId::KitChipErrorSoft.name())
    );
    assert!(
        rows[3]
            .runs
            .iter()
            .any(|(_, _, f)| f == FaceId::KitChipAccentSoft.name())
    );
}

#[test]
fn a_cell_that_never_ran_has_an_empty_prompt_and_a_stale_one_is_dim() {
    let mut c = cell("a", Kind::Code, "x", None, "");
    let r = &outline_rows(&[c.clone()], 1, None)[0];
    assert_eq!(r.text, "1  code    [ ]    x");
    c.stale = true;
    c.execution_count = Some(2);
    let r = &outline_rows(&[c], 1, None)[0];
    assert!(
        r.runs
            .iter()
            .any(|(_, _, f)| f == FaceId::NotebookStale.name())
    );
}

#[test]
fn the_outline_lists_a_bounded_number_of_cells_and_says_how_many_it_left_out() {
    let cells: Vec<OutlineCell> = (0..OUTLINE_ROWS)
        .map(|i| cell(&format!("c{i}"), Kind::Code, "x", None, ""))
        .collect();
    let rows = outline_rows(&cells, 5000, None);
    assert_eq!(rows.len(), OUTLINE_ROWS + 1);
    assert_eq!(rows.last().unwrap().text, "more: 3000 cells are not listed");
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
    /// The rows of each publish that carry the current-cell mark.
    marked: Mutex<Vec<Vec<usize>>>,
    from: std::sync::atomic::AtomicUsize,
}

impl Stage for Recorder {
    fn shown(&self, _: u64, view: &str) -> bool {
        self.shown.lock().unwrap().contains(view)
    }
    fn window(&self, _: u64, _: &str) -> usize {
        self.from.load(std::sync::atomic::Ordering::SeqCst)
    }
    fn columns(&self, _: u64, _: &str) -> usize {
        0
    }
    fn publish(&self, conn: u64, view: &str, rows: Vec<Row>) {
        self.marked.lock().unwrap().push(
            rows.iter()
                .enumerate()
                .filter(|(_, r)| r.props.iter().any(|p| p.2 == "drgnx-notebook-current"))
                .map(|(i, _)| i)
                .collect(),
        );
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
    crate::fsio::write(&path, NB).unwrap();
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
    // the test's own clock: the process's (install_virtual) would reach every other test's threads
    crate::clock::on_virtual(async {
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
    let rows = output_rows("c", &run, 0, 0);
    assert_eq!(rows.len(), OUTPUT_WINDOW + 1);
    assert_eq!(rows[0].key, "l:0");
    assert_eq!(rows[0].text, "line 0");
    assert_eq!(rows[OUTPUT_WINDOW].key, "below");
    assert_eq!(
        rows[OUTPUT_WINDOW].text,
        "▼ 1501 lines below   M-n later lines"
    );
    assert_eq!(
        rows[0].props,
        vec![
            (0, 6, FaceId::NotebookCell.name().to_string(), json!("c")),
            (0, 6, "drgnx-notebook-line".to_string(), json!(1)),
        ]
    );
    let rows = output_rows("c", &run, 1200, 0);
    assert_eq!(rows[0].text, "▲ 1200 lines above   M-p earlier lines");
    assert_eq!(rows[1].key, "l:1200");
    assert_eq!(rows[1].text, "line 1200");
    assert_eq!(
        rows.last().unwrap().text,
        "▼ 301 lines below   M-n later lines"
    );
    // a window past the end comes back to the last line
    let rows = output_rows("c", &run, 1_000_000, 0);
    assert_eq!(rows.last().unwrap().key, "l:2500");
    assert_eq!(rows.len(), 2);
    // everything fits: no row counts anything
    let rows = output_rows("c", &lines(3), 0, 0);
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
    let r = &output_rows("c", &run, 0, 0)[0];
    assert_eq!(r.text, "ok bad");
    assert!(
        r.runs
            .contains(&(3, 6, "drgnx-notebook-fg-red".to_string()))
    );
    assert!(r.runs.contains(&(3, 6, "bold".to_string())));
    let none = output_rows("c", &run_with(|_| {}), 0, 0);
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
    let rows = output_rows("c", &run, 0, 0);
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
    crate::fsio::write(w._d.path().join("o.ipynb"), NB_OUT).unwrap();
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
    // shown, and the window moved, before the env: its rebuild runs at once on a task of its own
    w.stage.shown.lock().unwrap().insert(view.clone());
    w.stage.from.store(1, std::sync::atomic::Ordering::SeqCst);
    assert!(w.views.env_build(1, &view));
    let got = skuld::wait_until("the output is built", 30, || {
        w.stage.got.lock().unwrap().last().cloned()
    });
    assert_eq!(got.1, view);
    assert_eq!(
        got.2,
        vec!["▲ 1 lines above   M-p earlier lines", "two", ""]
    );
    assert!(w.views.window(1, &view), "a moved window builds it again");
    // a cell that is not in the notebook
    let gone = w
        .views
        .register(1, &id, NotebookViewKind::Output, Some("zz"))
        .unwrap();
    w.stage.shown.lock().unwrap().insert(gone.clone());
    assert!(w.views.env_build(1, &gone));
    skuld::wait_until("the gone cell is said", 30, || {
        (w.stage
            .got
            .lock()
            .unwrap()
            .iter()
            .any(|g| g.1 == gone && g.2 == vec!["the cell is gone"]))
        .then_some(())
    });
}

// ---- the kernel log ----

fn entry(seq: u64, ty: &str, text: &str) -> LogEntry {
    LogEntry {
        seq,
        msg_type: ty.into(),
        text: text.into(),
    }
}

#[test]
fn the_kernel_log_keeps_the_last_entries_and_says_how_many_after_a_number_are_gone() {
    let mut log = KernelLog::default();
    assert_eq!((log.last_seq(), log.since(0)), (0, (vec![], 0)));
    for i in 1..=600 {
        assert_eq!(log.push("stream", &format!("m{i}")), i);
    }
    let (all, lost) = log.since(0);
    assert_eq!((all.len(), lost, all[0].seq), (LOG_ENTRIES, 100, 101));
    let (some, lost) = log.since(550);
    assert_eq!((some.len(), lost, some[0].text.as_str()), (50, 0, "m551"));
    assert_eq!(log.since(50).1, 50, "entries 51 to 100 are gone");
    assert_eq!(log.since(700), (vec![], 0));
    assert_eq!(log.last_seq(), 600);
}

#[test]
fn log_rows_show_the_type_and_the_text_a_bounded_number_of_lines_and_say_what_is_missing() {
    let ten: String = (0..10).map(|i| format!("l{i}\n")).collect();
    let rows = log_rows(
        &[
            entry(4, "stream", "hello\u{202e}"),
            entry(5, "error", &ten),
            entry(6, "comm_open", ""),
        ],
        3,
    );
    let texts: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
    assert_eq!(texts[0], "lost            3 earlier entries");
    assert_eq!(texts[1], "stream          hello");
    assert_eq!(texts[2], "error           l0");
    assert_eq!(
        texts[2 + LOG_LINES - 1],
        "                l7  (2 more lines)"
    );
    assert_eq!(texts[2 + LOG_LINES], "comm_open       ");
    assert_eq!(rows[2].key, "e:5:0");
    assert!(
        rows[2]
            .runs
            .iter()
            .any(|(_, _, f)| f == FaceId::KitChipErrorSoft.name())
    );
    assert_eq!(
        rows[1].props,
        vec![(0, 21, "drgnx-notebook-log".to_string(), json!(4))]
    );
    assert_eq!(log_rows(&[], 0)[0].text, "the kernel has logged nothing");
    let long = "x".repeat(5000);
    assert_eq!(
        log_rows(&[entry(1, "stream", &long)], 0)[0]
            .text
            .chars()
            .count(),
        16 + LOG_LINE_CHARS
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_shown_log_is_built_on_its_env_and_a_notebook_log_event_rebuilds_it_only_for_its_owner() {
    let w = world().await;
    let view = w
        .views
        .register(1, &w.id, NotebookViewKind::Log, None)
        .unwrap();
    assert_eq!(view, format!("notebook-log:{}", w.id));
    assert!(!w.views.env_build(2, &view), "another connection's");
    // shown before the env, whose rebuild runs at once on a task of its own
    w.stage.shown.lock().unwrap().insert(view.clone());
    assert!(w.views.env_build(1, &view));
    w.views.flush().await;
    skuld::wait_until("the log is built", 30, || {
        w.stage.got.lock().unwrap().last().cloned()
    });
    let got = w.stage.got.lock().unwrap().clone();
    assert_eq!(got.last().unwrap().2, vec!["the kernel has logged nothing"]);
    // an event of another connection marks nothing
    w.views
        .event(2, "notebook-log", &json!({"id": w.id, "seq": 1}));
    assert!(w.views.dirty_is_empty());
    assert!(!w.views.env_build(1, "notebook-log:nb-other"));
}

// ---- the look: chips, cut rows, error rows, the current cell ----

/// The faces over the characters `[from, to)` of R.
fn faces_at(r: &Row, from: u32, to: u32) -> Vec<&str> {
    r.runs
        .iter()
        .filter(|(a, b, _)| *a <= from && to <= *b)
        .map(|(_, _, f)| f.as_str())
        .collect()
}

#[test]
fn the_outlines_type_and_state_are_chips_of_the_look() {
    let cells = vec![
        cell("a", Kind::Code, "x", Some(1), "running"),
        cell("b", Kind::Code, "x", Some(1), "queued"),
        cell("c", Kind::Code, "x", Some(1), "error"),
        cell("d", Kind::Code, "x", Some(1), "aborted"),
        cell("e", Kind::Markdown, "x", None, "cancelled"),
        cell("f", Kind::Code, "x", Some(1), ""),
    ];
    let rows = outline_rows(&cells, 6, None);
    // the type word is a quiet chip, the padding after it is not
    for r in &rows {
        let kind_len = if r.text.contains("markdown") { 8 } else { 4 };
        assert_eq!(
            faces_at(r, 3, 3 + kind_len),
            [FaceId::KitChipNeutralSoft.name()],
            "{}",
            r.text
        );
        assert!(
            faces_at(r, 3 + kind_len, 3 + kind_len + 1).is_empty(),
            "{}",
            r.text
        );
    }
    let chip = |r: &Row, word: &str| {
        let at = r.text.rfind(word).unwrap() as u32;
        faces_at(r, at, at + word.len() as u32)
            .first()
            .map(|f| f.to_string())
    };
    assert_eq!(
        chip(&rows[0], "running").as_deref(),
        Some(FaceId::KitChipAccentSoft.name())
    );
    assert_eq!(
        chip(&rows[1], "queued").as_deref(),
        Some(FaceId::KitChipNeutralSoft.name())
    );
    assert_eq!(
        chip(&rows[2], "error").as_deref(),
        Some(FaceId::KitChipErrorSoft.name())
    );
    assert_eq!(
        chip(&rows[3], "aborted").as_deref(),
        Some(FaceId::KitChipWarnSoft.name())
    );
    assert_eq!(
        chip(&rows[4], "cancelled").as_deref(),
        Some(FaceId::KitChipWarnSoft.name())
    );
    assert_eq!(
        rows[5]
            .runs
            .iter()
            .filter(|r| r.2.starts_with("drgnx-kit-chip-"))
            .count(),
        1,
        "a cell at rest has the type chip only"
    );
}

#[test]
fn the_cell_the_editor_is_in_is_marked_in_the_outline_and_no_other() {
    let cells = vec![
        cell("a", Kind::Code, "x", None, ""),
        cell("b", Kind::Code, "y", None, ""),
    ];
    let rows = outline_rows(&cells, 2, Some("b"));
    let current = |r: &Row| r.props.iter().any(|p| p.2 == "drgnx-notebook-current");
    assert!(!current(&rows[0]) && current(&rows[1]));
    let len = rows[1].text.chars().count() as u32;
    assert!(
        rows[1]
            .props
            .contains(&(0, len, "drgnx-notebook-current".to_string(), json!(true)))
    );
    assert_eq!(
        faces_at(&rows[1], 0, len).last().copied(),
        Some(FaceId::NotebookCurrentRow.name())
    );
    assert!(
        !rows[0]
            .runs
            .iter()
            .any(|(_, _, f)| f == FaceId::NotebookCurrentRow.name())
    );
    // no cell, or one that is not listed: nothing is marked
    for c in [None, Some("zz")] {
        assert!(!outline_rows(&cells, 2, c).iter().any(current));
    }
}

#[test]
fn the_rows_that_count_what_is_left_out_carry_the_number_as_a_property() {
    let n = |r: &Row, name: &str| r.props.iter().find(|p| p.2 == name).map(|p| p.3.clone());
    let cells: Vec<OutlineCell> = (0..3)
        .map(|i| cell(&format!("c{i}"), Kind::Code, "x", None, ""))
        .collect();
    let more = outline_rows(&cells, 2003, None).pop().unwrap();
    assert_eq!(more.text, "more: 2000 cells are not listed");
    assert_eq!(n(&more, "drgnx-notebook-more"), Some(json!(2000)));
    let rows = output_rows("c", &lines(2500), 1200, 0);
    assert_eq!(n(&rows[0], "drgnx-notebook-above"), Some(json!(1200)));
    assert_eq!(
        n(rows.last().unwrap(), "drgnx-notebook-below"),
        Some(json!(301))
    );
    let lost = &log_rows(&[entry(9, "stream", "x")], 12)[0];
    assert_eq!(lost.text, "lost            12 earlier entries");
    assert_eq!(n(lost, "drgnx-notebook-lost"), Some(json!(12)));
}

#[test]
fn a_cut_row_is_a_tinted_row_with_the_key_that_moves_the_window() {
    let rows = output_rows("c", &lines(2500), 1200, 0);
    let (up, down) = (&rows[0], rows.last().unwrap());
    let len = up.text.chars().count() as u32;
    assert_eq!(
        faces_at(up, 0, len).last().copied(),
        Some(FaceId::NotebookCut.name())
    );
    // the arrow is one character, not three bytes: the key's place is counted in characters
    let key = up.text[..up.text.find("M-p").unwrap()].chars().count() as u32;
    assert_eq!(
        faces_at(up, key, key + 3)[0],
        FaceId::KitChipNeutralSoft.name()
    );
    let dlen = down.text.chars().count() as u32;
    assert_eq!(
        faces_at(down, 0, dlen).last().copied(),
        Some(FaceId::NotebookCut.name())
    );
    assert!(down.text.contains("M-n later lines"));
}

#[test]
fn a_cut_row_fits_the_panes_columns_with_its_key_chip_whole() {
    let text = |cols| output_rows("c", &lines(2500), 1200, cols)[0].text.clone();
    // the gutter takes the last line's number (2 200, five columns) and two
    assert_eq!(text(0), "▲ 1200 lines above   M-p earlier lines");
    assert_eq!(text(80), "▲ 1200 lines above   M-p earlier lines");
    // too narrow for the words before the chip: they give way first
    assert_eq!(text(7 + 26), "▲ 1200   M-p earlier lines");
    // narrower: the label after the chip goes, the chip stays whole
    assert_eq!(text(7 + 12), "▲ 1200   M-p");
    let rows = output_rows("c", &lines(2500), 1200, 7 + 12);
    let up = &rows[0];
    let key = up.text[..up.text.find("M-p").unwrap()].chars().count() as u32;
    assert_eq!(
        faces_at(up, key, key + 3)[0],
        FaceId::KitChipNeutralSoft.name()
    );
    let len = up.text.chars().count() as u32;
    assert_eq!(
        faces_at(up, 0, len).last().copied(),
        Some(FaceId::NotebookCut.name())
    );
}

#[test]
fn the_lines_of_an_error_output_are_error_rows_and_other_lines_are_not() {
    let run = run_with(|f| {
        f("stream", json!({"name": "stdout", "text": "fine\n"}));
        f(
            "error",
            json!({"ename": "ValueError", "evalue": "shapes", "traceback": ["Cell In[3], line 4", "", "ValueError: shapes"]}),
        );
    });
    let rows = output_rows("c", &run, 0, 0);
    let is_err = |r: &Row| {
        r.runs
            .iter()
            .any(|(_, _, f)| f == FaceId::NotebookErrorRow.name())
    };
    assert_eq!(rows[0].text, "fine");
    assert!(!is_err(&rows[0]), "the stream before it is not");
    assert_eq!(rows[2].text, "ValueError: shapes");
    let errors: Vec<&Row> = rows.iter().filter(|r| is_err(r)).collect();
    assert_eq!(errors.len(), 4, "the name line and the traceback's three");
    for r in errors {
        let len = r.text.chars().count() as u32;
        assert!(len > 0, "an empty line of an error still has a row to tint");
        assert_eq!(
            faces_at(r, 0, len).last().copied(),
            Some(FaceId::NotebookErrorRow.name())
        );
    }
}

#[test]
fn the_logs_type_is_a_chip_and_an_error_entry_is_an_error_row() {
    let rows = log_rows(&[entry(1, "stream", "hi"), entry(2, "error", "a\nb")], 0);
    assert_eq!(
        faces_at(&rows[0], 0, 6),
        [FaceId::KitChipNeutralSoft.name()]
    );
    assert!(
        faces_at(&rows[0], 6, 7).is_empty(),
        "the padding is no chip"
    );
    let is_err = |r: &Row| {
        r.runs
            .iter()
            .any(|(_, _, f)| f == FaceId::NotebookErrorRow.name())
    };
    assert!(!is_err(&rows[0]));
    assert!(
        is_err(&rows[1]) && is_err(&rows[2]),
        "every line of an error entry"
    );
    assert!(faces_at(&rows[1], 0, 5).contains(&FaceId::KitChipErrorSoft.name()));
}

#[tokio::test(flavor = "multi_thread")]
async fn the_editors_current_cell_marks_its_outline_row() {
    let w = world().await;
    let view = w
        .views
        .register(1, &w.id, NotebookViewKind::Outline, None)
        .unwrap();
    w.stage.shown.lock().unwrap().insert(view);
    assert!(w.views.focus(1, &w.id, Some("b")), "a change");
    assert!(
        !w.views.focus(1, &w.id, Some("b")),
        "the same again is none"
    );
    w.views.flush().await;
    assert_eq!(w.stage.marked.lock().unwrap().last(), Some(&vec![1]));
    assert!(
        w.views.focus(1, &w.id, None),
        "the editor left the notebook's cells"
    );
    w.views.flush().await;
    assert_eq!(w.stage.marked.lock().unwrap().last(), Some(&vec![]));
}
