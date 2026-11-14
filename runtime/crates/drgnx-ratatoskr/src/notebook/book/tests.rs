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
    b.show("c1", vec![stream("new")], Some(4));
    let (t, stale) = b.tail("c1").unwrap();
    assert_eq!((t.text.as_str(), stale, t.version), ("new", false, 2));
    b.show("c1", vec![stream("newer")], Some(4));
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
    std::fs::write(&path, NB).unwrap();
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
    b.show(&minted, vec![result], Some(5));
    b.save().unwrap();
    let saved: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let cells = saved["cells"].as_array().unwrap();
    assert_eq!(
        cells[1]["outputs"][0]["text"],
        json!(["old\n"]),
        "a stale cell is as the file had it"
    );
    assert_eq!(cells[2]["outputs"][0]["output_type"], "execute_result");
    assert_eq!(cells[2]["outputs"][0]["data"]["text/plain"], "2");
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
