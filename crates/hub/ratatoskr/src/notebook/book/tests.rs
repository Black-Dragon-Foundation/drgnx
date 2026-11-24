use serde_json::json;

use super::*;
use crate::notebook::output::{Output, mime::Bundle, terminal::Terminal};

const NB: &str = r##"{
 "cells": [
  {"cell_type": "markdown", "id": "md1", "metadata": {}, "source": ["# Title"]},
  {"cell_type": "code", "id": "c1", "metadata": {}, "execution_count": 3, "outputs": [
    {"output_type": "stream", "name": "stdout", "text": ["old\n"]}], "source": ["print('old')"]},
  {"cell_type": "code", "metadata": {}, "execution_count": null, "outputs": [], "source": []}
 ],
 "metadata": {"kernelspec": {"name": "python3", "language": "python", "display_name": "Python 3"}},
 "nbformat": 4, "nbformat_minor": 5
}"##;

fn open() -> Book {
    Book::open(Path::new("/x/a.ipynb"), NB.to_string()).unwrap()
}

fn run(outputs: Vec<Output>, count: Option<i64>) -> CellRun {
    let mut r = CellRun::from_outputs("r", outputs, RunStatus::Ok);
    r.execution_count = count;
    r
}

fn stream(text: &str) -> Output {
    let mut t = Terminal::default();
    t.push(text);
    Output::Stream {
        name: "stdout".into(),
        text: t,
    }
}

#[test]
fn a_notebook_opens_with_its_cells_ids_and_the_files_outputs_as_stale_tails() {
    let b = open();
    let cells = b.cells();
    assert_eq!(
        cells.iter().map(|c| c.kind).collect::<Vec<_>>(),
        [Kind::Markdown, Kind::Code, Kind::Code]
    );
    assert_eq!(
        (
            cells[1].id.as_str(),
            cells[1].execution_count,
            cells[1].source.as_str()
        ),
        ("c1", Some(3), "print('old')")
    );
    assert_eq!(
        cells[2].id.len(),
        16,
        "an id is minted for a cell without one: {}",
        cells[2].id
    );
    assert_eq!(
        (b.kernelspec_name().as_deref(), b.language().as_deref()),
        (Some("python3"), Some("python"))
    );
    let (t, stale) = b.tail("c1").unwrap();
    assert_eq!((t.text.as_str(), stale), ("old\n", true));
    assert_eq!(b.tail(&cells[2].id).unwrap().0.text, "");
    assert!(b.tail("nope").is_none());
    assert!(Book::open(Path::new("/x/b.ipynb"), "[]".into()).is_err());
}

#[test]
fn a_run_replaces_the_stale_outputs_and_the_tail_version_counts_up() {
    let mut b = open();
    // the pump counts a version for each tail it sends and the notebook is shown the output now and then
    assert_eq!(b.next_version("c1"), 2);
    b.show("c1", &run(vec![stream("new")], Some(4)));
    let (t, stale) = b.tail("c1").unwrap();
    assert_eq!((t.text.as_str(), stale, t.version), ("new", false, 2));
    assert_eq!(b.next_version("c1"), 3);
    b.show("c1", &run(vec![stream("newer")], Some(4)));
    assert_eq!(b.tail("c1").unwrap().0.version, 3);
    assert_eq!(b.cells()[1].execution_count, Some(4));
}

fn sync(id: &str, kind: Kind, source: &str) -> CellSync {
    CellSync {
        id: id.into(),
        kind,
        source: source.into(),
    }
}

#[test]
fn the_buffers_cells_make_the_notebooks_cells_removed_moved_added_and_edited() {
    let mut b = open();
    let minted = b.cells()[2].id.clone();
    b.sync(&[
        sync(&minted, Kind::Code, "x = 1"),
        sync("brand-new", Kind::Markdown, "hello"),
        sync("c1", Kind::Code, "print('old')"),
    ]);
    let cells = b.cells();
    assert_eq!(
        cells.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(),
        [minted.as_str(), "brand-new", "c1"]
    );
    assert_eq!(cells[0].source, "x = 1");
    assert_eq!(
        (cells[1].kind, cells[1].source.as_str()),
        (Kind::Markdown, "hello")
    );
    assert!(b.tail("md1").is_none(), "a removed cell has no tail");
    // a cell's type changes
    b.sync(&[sync("c1", Kind::Markdown, "now text")]);
    assert_eq!(b.cells().len(), 1);
    assert_eq!(
        (b.cells()[0].kind, b.cells()[0].source.as_str()),
        (Kind::Markdown, "now text")
    );
}

#[test]
fn saving_writes_the_runs_outputs_and_leaves_stale_ones_as_the_file_had_them() {
    let d = tempfile::tempdir().unwrap();
    let path = d.path().join("n.ipynb");
    crate::fsio::write(&path, NB).unwrap();
    let mut b = Book::open(&path, NB.to_string()).unwrap();
    let minted = b.cells()[2].id.clone();
    b.sync(&[
        sync("md1", Kind::Markdown, "# Title"),
        sync("c1", Kind::Code, "print('old')"),
        sync(&minted, Kind::Code, "1 + 1"),
    ]);
    let result = Output::Result {
        count: Some(5),
        bundle: Bundle::from_message(&json!({"data": {"text/plain": "2"}})),
    };
    b.show(&minted, &run(vec![result], Some(5)));
    b.save().unwrap();
    let saved: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let cells = saved["cells"].as_array().unwrap();
    assert_eq!(
        cells[1]["outputs"][0]["text"],
        json!(["old\n"]),
        "a stale cell is as the file had it"
    );
    assert_eq!(cells[2]["outputs"][0]["output_type"], "execute_result");
    assert_eq!(cells[2]["outputs"][0]["data"]["text/plain"], json!(["2"]));
    assert_eq!(cells[2]["execution_count"], 5);
    assert_eq!(cells[2]["source"], json!(["1 + 1"]));
    assert_eq!(cells[2]["id"], minted.as_str(), "the minted id is written");
    assert_eq!(saved["nbformat_minor"], 5);
    // a second save of an unchanged book writes the same bytes
    let first = std::fs::read(&path).unwrap();
    b.save().unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), first);
    // and the saved file opens again with the run's output (stale, from the file)
    let again = Book::open(&path, String::from_utf8(first).unwrap()).unwrap();
    assert_eq!(again.tail(&minted).unwrap().0.text, "2");
}

#[test]
fn a_file_over_the_size_limit_is_refused_before_it_is_parsed() {
    let e = Book::open(
        Path::new("/x/big.ipynb"),
        "x".repeat(MAX_NOTEBOOK_BYTES + 1),
    )
    .err()
    .unwrap();
    assert!(e.contains("too large"), "{e}");
}

#[test]
fn a_hostile_files_outputs_are_capped_when_it_is_opened() {
    let outs: Vec<String> = (0..200)
        .map(|_| r#"{"output_type": "stream", "name": "stdout", "text": ["x\n"]}"#.to_string())
        .collect();
    let err = format!(
        r#"{{"output_type": "error", "ename": "E", "evalue": "v", "traceback": [{}""]}}"#,
        r#""","#.repeat(500_000)
    );
    let text = format!(
        r#"{{"cells": [
          {{"cell_type": "code", "id": "many", "metadata": {{}}, "execution_count": 2, "outputs": [{}], "source": []}},
          {{"cell_type": "code", "id": "tb", "metadata": {{}}, "execution_count": 1, "outputs": [{err}], "source": []}}],
        "metadata": {{}}, "nbformat": 4, "nbformat_minor": 5}}"#,
        outs.join(",")
    );
    let b = Book::open(Path::new("/x/h.ipynb"), text).unwrap();
    assert_eq!(b.outputs_of("many").len(), MAX_OUTPUTS);
    assert!(b.tail("many").unwrap().0.more_lines > 0);
    let tb = &b.outputs_of("tb")[0];
    assert!(tb["traceback"].as_array().unwrap().len() <= crate::notebook::output::MAX_TRACEBACK);
    assert_eq!(b.cells()[0].execution_count, Some(2));
}

#[test]
fn the_same_cells_in_the_same_order_are_updated_in_place() {
    let mut b = open();
    let ids: Vec<String> = b.cells().iter().map(|c| c.id.clone()).collect();
    b.sync(&[
        sync(&ids[0], Kind::Markdown, "# New"),
        sync(&ids[1], Kind::Markdown, "now text"),
        sync(&ids[2], Kind::Code, "z = 3"),
    ]);
    let cells = b.cells();
    assert_eq!(cells.iter().map(|c| c.id.clone()).collect::<Vec<_>>(), ids);
    assert_eq!(
        (
            cells[0].source.as_str(),
            cells[1].kind,
            cells[1].source.as_str(),
            cells[2].source.as_str()
        ),
        ("# New", Kind::Markdown, "now text", "z = 3")
    );
}

#[test]
fn a_notebook_with_too_many_cells_is_refused_and_the_language_is_read_once_and_short() {
    let cell = r#"{"cell_type": "markdown", "metadata": {}, "source": []}"#;
    let many = format!(
        r#"{{"cells": [{}], "metadata": {{}}, "nbformat": 4, "nbformat_minor": 4}}"#,
        vec![cell; MAX_CELLS + 1].join(",")
    );
    let e = Book::open(Path::new("/x/many.ipynb"), many).err().unwrap();
    assert!(e.contains("too many cells"), "{e}");
    let lang = "p".repeat(500);
    let text = format!(
        r#"{{"cells": [], "metadata": {{"kernelspec": {{"name": "{lang}", "language": "{lang}"}}}}, "nbformat": 4, "nbformat_minor": 5}}"#
    );
    let b = Book::open(Path::new("/x/l.ipynb"), text).unwrap();
    assert_eq!(b.language().unwrap().len(), 64);
    assert_eq!(b.kernelspec_name().unwrap().len(), 64);
}

#[test]
fn a_notebook_of_ten_thousand_cells_is_opened_synced_and_given_tails_by_index() {
    let outs = r#"[{"output_type": "stream", "name": "stdout", "text": ["x\n"]}]"#;
    let cells: Vec<String> = (0..MAX_CELLS)
        .map(|i| format!(r#"{{"cell_type": "code", "id": "c{i}", "metadata": {{}}, "execution_count": {i}, "outputs": {outs}, "source": ["{i}"]}}"#))
        .collect();
    let text = format!(
        r#"{{"cells": [{}], "metadata": {{}}, "nbformat": 4, "nbformat_minor": 5}}"#,
        cells.join(",")
    );
    // on a thread waited for with a deadline: quadratic work here would fail the test, not hang it
    let slot = std::sync::Arc::new(std::sync::Mutex::new(None));
    let s2 = slot.clone();
    std::thread::spawn(move || {
        let mut b = Book::open(Path::new("/x/big.ipynb"), text).unwrap();
        let tails = (0..MAX_CELLS)
            .filter_map(|i| b.tail(&format!("c{i}")))
            .count();
        // the last cell first, a cell added in the middle, one gone: not the fast path
        let mut plan: Vec<CellSync> = b
            .cells()
            .into_iter()
            .map(|c| CellSync {
                id: c.id,
                kind: c.kind,
                source: c.source,
            })
            .collect();
        plan.rotate_right(1);
        plan.remove(5);
        plan.insert(
            7,
            CellSync {
                id: "added".into(),
                kind: Kind::Code,
                source: "new".into(),
            },
        );
        b.sync(&plan);
        let cells = b.cells();
        *s2.lock().unwrap() = Some((
            tails,
            cells.len(),
            cells[0].id.clone(),
            cells[7].id.clone(),
            b.tail("c4").is_none(),
            b.tail("added").is_some(),
        ));
    });
    let (tails, n, first, seventh, c5_gone, added) =
        skuld::wait_until("the notebook", 60, || slot.lock().unwrap().take());
    assert_eq!((tails, n), (MAX_CELLS, MAX_CELLS));
    assert_eq!(
        (first.as_str(), seventh.as_str(), c5_gone, added),
        (format!("c{}", MAX_CELLS - 1).as_str(), "added", true, true)
    );
}

#[test]
fn a_cell_that_did_not_run_keeps_its_outputs_and_only_its_state_changes() {
    let mut b = open();
    let before = b.outputs_of("c1");
    assert_eq!(before.len(), 1);
    b.mark("c1", RunStatus::Aborted);
    assert_eq!(
        b.outputs_of("c1"),
        before,
        "the output it had stays, and is saved"
    );
    let (t, _) = b.tail("c1").unwrap();
    assert_eq!(t.text, "old\n\naborted");
}
