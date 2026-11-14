//! Jupyter notebooks (language packs Task 11a): an nbformat file read and written without changing a byte nobody edited, the
//! view the editor's buffer holds, and the chunker (one chunk set per cell by its language's pack, in the view's offsets and
//! lines). Fixtures are in `tests/fixtures/notebooks/`; `minimal.edited.ipynb` is what nbformat's own writer produces for the
//! edit of `an_edited_cell_is_written_the_way_nbformats_writer_writes_it` (`test/notebooks/make-goldens.py`).
//!
//! test-pattern: pure (D).

use hrafn::chunk::{BUDGET, CHUNKER_VERSION, chunk_file_refs};
use hrafn::notebook::{Kind, NotANotebook, Notebook, split_lines};
use hrafn::{Lang, classify, vec_key};
use serde_json::Value;
use std::fmt::Write;
use std::path::PathBuf;

fn fixture(name: &str) -> String {
    std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/notebooks")
            .join(name),
    )
    .unwrap()
}

fn ids(prefix: &'static str) -> impl FnMut() -> String {
    let mut n = 0;
    move || {
        n += 1;
        format!("{prefix}{n}")
    }
}

fn parse(name: &str) -> Notebook {
    Notebook::parse(fixture(name), &mut ids("m")).unwrap()
}

#[test]
fn a_notebook_nobody_edited_renders_the_original_bytes() {
    for name in [
        "minimal.ipynb",
        "floats.ipynb",
        "noids.ipynb",
        "two-space.ipynb",
    ] {
        let nb = parse(name);
        assert!(!nb.is_changed(), "{name}");
        assert_eq!(nb.render(), fixture(name), "{name}");
    }
}

#[test]
fn cells_are_read_with_their_kind_source_and_id() {
    let nb = parse("minimal.ipynb");
    let c = nb.cells();
    assert_eq!(c.len(), 3);
    assert_eq!((c[0].kind, c[0].id.as_str()), (Kind::Markdown, "a1b2c3d4"));
    assert_eq!(c[0].source, "# Cache experiments\nHow the hit rate moves.");
    assert_eq!((c[1].kind, c[1].execution_count), (Kind::Code, Some(1)));
    assert_eq!(c[1].source, "print('done')");
    assert_eq!(c[2].source, "");
    assert_eq!(nb.language().as_deref(), Some("python"));
    assert_eq!(nb.kernelspec_name().as_deref(), Some("python3"));
    assert!(!nb.needs_ids());
}

#[test]
fn an_edit_changes_only_the_edited_cell_and_copies_its_other_fields_as_they_were() {
    let original = fixture("floats.ipynb");
    let mut nb = parse("floats.ipynb");
    nb.set_source(0, "x = 2\nprint(x)\n");
    assert!(nb.is_changed());
    let out = nb.render();
    // what nobody edited is the file's own text: floats, big integers, escapes, odd spacing, inline arrays
    for kept in [
        "\"weird\": 1e-05",
        "12345678901234567890",
        "\"plain\": 1.0",
        "\"caf\\u00e9 \\ud83e\\udd80 \\/\"",
        "\"tags\": [\"keep\", \"raw\"]",
        "\"application/json\": {\"x\": 1E5, \"y\": [1,2,  3]}",
        "\"odd\": 0.1e1",
        "\"kernelspec\": {\"display_name\": \"Python 3\", \"language\": \"python\", \"name\": \"python3\"}",
    ] {
        assert!(out.contains(kept), "{kept} is gone from\\n{out}");
    }
    // the second cell is its own bytes
    let second = original.split("\"id\": \"f2\"").next().unwrap();
    assert!(second.len() < original.len());
    assert!(
        out.ends_with(
            &original[original
                .rfind("  {\n   \"cell_type\": \"code\",\n   \"execution_count\": null,")
                .unwrap()..]
        )
    );
    // the new source, as nbformat's writer splits it
    let v: Value = serde_json::from_str(&out).expect("the result is JSON");
    assert_eq!(
        v["cells"][0]["source"],
        serde_json::json!(["x = 2\n", "print(x)\n"])
    );
    assert_eq!(v["cells"][1]["source"], serde_json::json!(["y = 2"]));
    // and nothing else about the first cell changed in meaning
    assert_eq!(
        v["cells"][0]["metadata"]["big"].to_string(),
        "12345678901234567890"
    );
}

#[test]
fn an_edited_cell_is_written_the_way_nbformats_writer_writes_it() {
    let mut nb = parse("minimal.ipynb");
    nb.set_source(1, "print('done')\nprint(2)\n");
    assert_eq!(nb.render(), fixture("minimal.edited.ipynb"));
}

#[test]
fn the_files_indent_is_kept_for_a_cell_that_is_written() {
    let mut nb = parse("two-space.ipynb");
    nb.set_source(1, "a\nb");
    let out = nb.render();
    // members of a cell at depth 3, two spaces a level
    assert!(out.contains("\n      \"cell_type\": \"code\",\n"), "{out}");
    assert!(
        out.contains("\n        \"a\\n\",\n        \"b\"\n      ]"),
        "{out}"
    );
    serde_json::from_str::<Value>(&out).unwrap();
    // the other cells are the file's bytes
    let original = fixture("two-space.ipynb");
    let head = original[..original.find("\"id\": \"e5f6a7b8\"").unwrap()]
        .rsplit_once("    {")
        .unwrap()
        .0;
    assert!(out.starts_with(head));
}

#[test]
fn ids_are_minted_in_memory_and_written_by_the_first_saving_edit_for_every_cell_that_lacks_one() {
    let mut nb = parse("noids.ipynb");
    assert!(nb.needs_ids());
    assert_eq!(
        nb.cells().iter().map(|c| c.id.as_str()).collect::<Vec<_>>(),
        ["m1", "m2"]
    );
    // loading and rendering untouched changes nothing
    assert_eq!(nb.render(), fixture("noids.ipynb"));
    nb.set_source(1, "x = 5");
    let out = nb.render();
    let v: Value = serde_json::from_str(&out).unwrap();
    assert_eq!(v["nbformat_minor"], 5);
    assert_eq!(v["cells"][0]["id"], "m1");
    assert_eq!(v["cells"][1]["id"], "m2");
    // keys sorted as nbformat writes them
    assert!(
        out.contains("\"cell_type\": \"markdown\",\n   \"id\": \"m1\",\n   \"metadata\": {},"),
        "{out}"
    );
    assert!(
        out.contains("\"execution_count\": null,\n   \"id\": \"m2\","),
        "{out}"
    );
}

#[test]
fn a_notebook_with_ids_keeps_its_minor_version() {
    let mut nb = parse("minimal.ipynb");
    nb.set_source(0, "# New title");
    let v: Value = serde_json::from_str(&nb.render()).unwrap();
    assert_eq!(v["nbformat_minor"], 5);
    let mut older = Notebook::parse(
        fixture("minimal.ipynb").replace("\"nbformat_minor\": 5", "\"nbformat_minor\": 4"),
        &mut ids("m"),
    )
    .unwrap();
    older.set_source(0, "# x");
    // every cell has an id: nothing to mint, the minor version stays
    assert!(older.render().contains("\"nbformat_minor\": 4"));
}

#[test]
fn cells_are_added_removed_and_moved_and_the_rest_stays_their_bytes() {
    let original = fixture("minimal.ipynb");
    let mut nb = parse("minimal.ipynb");
    nb.insert(1, Kind::Code, "z = 1\n", &mut ids("n"));
    nb.remove(3); // the old last cell
    nb.move_cell(0, 2);
    let out = nb.render();
    let v: Value = serde_json::from_str(&out).unwrap();
    let got: Vec<&str> = v["cells"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["id"].as_str().unwrap())
        .collect();
    assert_eq!(got, ["n1", "e5f6a7b8", "a1b2c3d4"]);
    assert_eq!(v["cells"][0]["cell_type"], "code");
    assert_eq!(v["cells"][0]["source"], serde_json::json!(["z = 1\n"]));
    assert_eq!(v["cells"][0]["outputs"], serde_json::json!([]));
    // an untouched cell is its original bytes
    let cell = |from: &str, to: &str| {
        original[original.find(from).unwrap()..original.find(to).unwrap()].to_owned()
    };
    let first = cell(
        "{\n   \"cell_type\": \"markdown\"",
        "  },\n  {\n   \"cell_type\": \"code\",\n   \"execution_count\": 1",
    );
    assert!(
        out.contains(first.trim_end()),
        "the markdown cell moved with its own bytes"
    );
}

#[test]
fn outputs_and_the_execution_count_are_set_in_nbformats_layout() {
    let mut nb = parse("minimal.ipynb");
    nb.set_execution_count(2, Some(7));
    nb.set_outputs(
        2,
        &[serde_json::json!({"output_type": "stream", "name": "stdout", "text": ["hi\n"]}),
          serde_json::json!({"output_type": "error", "ename": "E", "evalue": "v", "traceback": []})],
    );
    let out = nb.render();
    assert!(out.contains("\"execution_count\": 7,\n"), "{out}");
    assert!(
        out.contains("\"outputs\": [\n    {\n     \"name\": \"stdout\",\n     \"output_type\": \"stream\",\n     \"text\": [\n      \"hi\\n\"\n     ]\n    },"),
        "{out}"
    );
    assert!(out.contains("\"traceback\": []"), "{out}");
    serde_json::from_str::<Value>(&out).unwrap();
}

#[test]
fn a_cells_type_changes_with_the_members_its_new_type_needs() {
    let mut nb = parse("minimal.ipynb");
    nb.set_kind(1, Kind::Markdown);
    let v: Value = serde_json::from_str(&nb.render()).unwrap();
    assert_eq!(v["cells"][1]["cell_type"], "markdown");
    assert!(
        v["cells"][1].get("outputs").is_none() && v["cells"][1].get("execution_count").is_none()
    );
    nb.set_kind(0, Kind::Code);
    let v: Value = serde_json::from_str(&nb.render()).unwrap();
    assert_eq!(v["cells"][0]["outputs"], serde_json::json!([]));
    assert!(v["cells"][0]["execution_count"].is_null());
}

#[test]
fn a_repeated_id_is_not_the_files_own() {
    let text = fixture("minimal.ipynb").replace("\"c9d0e1f2\"", "\"a1b2c3d4\"");
    let nb = Notebook::parse(text, &mut ids("m")).unwrap();
    assert_eq!(nb.cells()[2].id, "m1");
    assert!(!nb.cells()[2].had_id() && nb.needs_ids());
}

#[test]
fn what_is_not_a_notebook_says_why_and_is_text() {
    let p = |t: &str| Notebook::parse(t.to_owned(), &mut ids("m")).err().unwrap();
    assert!(matches!(p("nope"), NotANotebook::Json(_)));
    assert_eq!(p("[1]"), NotANotebook::NotAnObject);
    assert_eq!(
        p(&fixture("not-a-notebook.json")),
        NotANotebook::Missing("nbformat")
    );
    assert_eq!(
        p("{\"nbformat\": 3, \"nbformat_minor\": 0, \"cells\": []}"),
        NotANotebook::Version(3)
    );
    assert_eq!(
        p("{\"nbformat\": 4, \"nbformat_minor\": 0}"),
        NotANotebook::Missing("cells")
    );
    assert_eq!(
        p("{\"nbformat\": 4, \"nbformat_minor\": 0, \"cells\": [1]}"),
        NotANotebook::BadCell(0)
    );
    assert_eq!(
        p(
            "{\"nbformat\": 4, \"nbformat_minor\": 0, \"cells\": [{\"cell_type\": \"x\", \"source\": \"\"}]}"
        ),
        NotANotebook::BadCell(0)
    );
}

#[test]
fn source_lines_split_as_pythons_splitlines_does() {
    assert_eq!(split_lines(""), Vec::<&str>::new());
    assert_eq!(split_lines("a\nb"), ["a\n", "b"]);
    assert_eq!(split_lines("a\nb\n"), ["a\n", "b\n"]);
    assert_eq!(split_lines("a\r\nb\rc"), ["a\r\n", "b\r", "c"]);
    assert_eq!(split_lines("\n"), ["\n"]);
    assert_eq!(
        split_lines("x\u{2028}y\u{85}z\x0cw"),
        ["x\u{2028}", "y\u{85}", "z\x0c", "w"]
    );
}

#[test]
fn the_view_is_what_the_buffer_holds_a_boundary_a_source_a_boundary_for_each_cell() {
    let nb = parse("minimal.ipynb");
    let v = nb.view();
    assert_eq!(
        v.text,
        "\n# Cache experiments\nHow the hit rate moves.\n\nprint('done')\n\n\n"
    );
    let c = &v.cells;
    assert_eq!(c[0].head, 0);
    assert_eq!(
        &v.text[c[0].source.clone()],
        "# Cache experiments\nHow the hit rate moves."
    );
    assert_eq!(
        (c[0].first_line, c[1].first_line, c[2].first_line),
        (2, 5, 7)
    );
    for r in c {
        assert_eq!(&v.text[r.head..=r.head], "\n");
        assert_eq!(&v.text[r.tail..=r.tail], "\n");
        assert_eq!(r.source.end, r.tail);
    }
}

#[test]
fn ipynb_is_a_notebook_and_its_cells_are_chunked_by_their_languages_in_the_views_lines() {
    assert_eq!(classify("work/cache.ipynb", b"").0, Lang::Notebook);
    assert_eq!(Lang::Notebook.as_str(), "notebook");
    assert_eq!(Lang::parse("notebook"), Lang::Notebook);
    let text = fixture("with-code.ipynb");
    let (chunks, symbols, refs) =
        chunk_file_refs("work/cache.ipynb", Lang::Notebook, false, &text, BUDGET);
    let nb = Notebook::parse(text.clone(), &mut ids("m")).unwrap();
    let view = nb.view();
    let names: Vec<(&str, &str)> = symbols
        .iter()
        .map(|s| (s.name.as_str(), s.kind.as_str()))
        .collect();
    assert!(names.contains(&("add", "function")), "{names:?}");
    // a symbol's lines and bytes are the view's: the text at its span is its definition
    let add = symbols.iter().find(|s| s.name == "add").unwrap();
    assert!(
        view.text[add.start as usize..add.end as usize].starts_with("def add"),
        "{:?}",
        &view.text[add.start as usize..add.end as usize]
    );
    let line = view.text[..add.start as usize].matches('\n').count() as u32 + 1;
    assert_eq!(add.line_start, line);
    // the chunk says which cell it is
    let c = &chunks[add.chunk as usize];
    assert!(
        c.fts.path.contains("work/cache.ipynb#code-cell-1"),
        "{:?}",
        c.fts.path
    );
    // markdown cells chunk as markdown, a reference counts across cells
    assert!(chunks.iter().any(|c| c.fts.path.contains("#md-cell-1")));
    assert!(refs.iter().any(|r| r.name == "add"), "{refs:?}");
    // a file that is not a notebook reads as text
    let (tc, ts, _) = chunk_file_refs(
        "x.ipynb",
        Lang::Notebook,
        false,
        "not json at all\n",
        BUDGET,
    );
    assert!(ts.is_empty() && !tc.is_empty());
}

#[test]
fn notebook_chunks_and_their_vector_keys_stay_as_designed() {
    let text = fixture("with-code.ipynb");
    let (chunks, symbols, _) =
        chunk_file_refs("work/cache.ipynb", Lang::Notebook, false, &text, BUDGET);
    let mut out = String::new();
    for c in &chunks {
        let key: String = vec_key(CHUNKER_VERSION, &c.embed_text)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        writeln!(
            out,
            "chunk {} {} {} {} {:?} {} {}",
            c.start, c.end, c.line_start, c.line_end, c.symbol, c.embed, key
        )
        .unwrap();
    }
    for s in &symbols {
        writeln!(
            out,
            "symbol {} {} {} {} {} {} {:?}",
            s.name, s.kind, s.start, s.end, s.chunk, s.definer, s.doc1
        )
        .unwrap();
    }
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/golden/chunks-notebook.golden");
    if !path.exists() {
        std::fs::write(&path, &out).unwrap();
        panic!("chunks-notebook.golden was missing and is written now: read it, then commit it");
    }
    assert_eq!(std::fs::read_to_string(&path).unwrap(), out);
}
