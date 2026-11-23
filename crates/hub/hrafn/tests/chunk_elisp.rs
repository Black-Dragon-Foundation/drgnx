use hrafn::Lang;
use hrafn::chunk::{BUDGET, Chunk, Symbol, chunk_file, top_level_forms};
use std::path::PathBuf;

fn fixture(name: &str) -> (String, PathBuf) {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/elisp");
    (eitri::read_string(&dir.join(name), 4 << 20).unwrap(), dir)
}

fn chunks(text: &str, budget: usize) -> (Vec<Chunk>, Vec<Symbol>) {
    chunk_file("core/sample.el", Lang::Elisp, false, text, budget)
}

fn names(syms: &[Symbol]) -> Vec<&str> {
    syms.iter().map(|s| s.name.as_str()).collect()
}

#[test]
fn spans_match_emacs_reader() {
    for name in ["basic.el", "reader.el"] {
        let (text, dir) = fixture(name);
        let json =
            eitri::read_string(&dir.join(name.replace(".el", ".forms.json")), 4 << 20).unwrap();
        let oracle: Vec<(usize, usize)> = serde_json::from_str::<Vec<[usize; 2]>>(&json)
            .unwrap()
            .into_iter()
            .map(|[a, b]| (a, b))
            .collect();
        assert_eq!(top_level_forms(&text), oracle, "{name}");
    }
}

#[test]
fn chunks_concatenate_to_file() {
    for name in ["basic.el", "reader.el"] {
        let (text, _) = fixture(name);
        for budget in [1, 40, 200, BUDGET] {
            let (cs, _) = chunks(&text, budget);
            let mut at = 0usize;
            let mut joined = String::new();
            for c in &cs {
                assert_eq!(
                    c.start as usize, at,
                    "{name} budget {budget}: gap before a chunk"
                );
                joined.push_str(&text[c.start as usize..c.end as usize]);
                at = c.end as usize;
            }
            assert_eq!(joined, text, "{name} budget {budget}");
            assert_eq!(at, text.len());
        }
    }
}

#[test]
fn merge_stops_at_section() {
    let text = ";;;; A\n\n(defun a ())\n(defun a2 ())\n\n;;;; B\n\n(defun b ())\n";
    let (cs, _) = chunks(text, BUDGET);
    assert_eq!(cs.len(), 2);
    assert!(cs[0].fts.body.contains("(defun a2 ())"));
    assert!(!cs[0].fts.body.contains("(defun b ())"));
    assert!(cs[0].header.contains("section: A"));
    assert!(cs[1].header.contains("section: B"));
    // the same text in one section is one chunk
    let (one, _) = chunks("(defun a ())\n\n(defun b ())\n", BUDGET);
    assert_eq!(one.len(), 1);
}

#[test]
fn oversized_defun_splits_with_part_headers() {
    let mut text = String::from("(defun big (x)\n  \"Do a big thing.\n\nMore.\"\n");
    for i in 0..20 {
        text.push_str(&format!("  (setq v{i} (* x {i}))\n"));
    }
    text.push_str(")\n");
    let (cs, syms) = chunks(&text, 120);
    assert!(cs.len() > 2, "{}", cs.len());
    let n = cs.len();
    for (i, c) in cs.iter().enumerate() {
        assert!(
            c.header.contains(&format!("part {}/{n}", i + 1)),
            "{}",
            c.header
        );
        assert!(c.header.contains("(defun big (x)"), "{}", c.header);
        assert!(c.header.contains("Do a big thing."), "{}", c.header);
        assert!(c.embed_text.contains("big (function)"));
    }
    // the parts cover the form, and its symbol is in the first part
    let joined: String = cs
        .iter()
        .map(|c| &text[c.start as usize..c.end as usize])
        .collect();
    assert_eq!(joined, text);
    assert_eq!(names(&syms), ["big"]);
    assert_eq!(syms[0].chunk, 0);
    assert_eq!(syms[0].doc1.as_deref(), Some("Do a big thing."));
}

#[test]
fn defconst_table_embeds_head_only() {
    let mut text = String::from("(defconst sample-big '(\n");
    for i in 0..40 {
        text.push_str(&format!("  (row-{i} . \"value {i}\")\n"));
    }
    text.push_str(")\n  \"A big table.\")\n");
    let (cs, syms) = chunks(&text, 200);
    assert_eq!(cs.len(), 1);
    assert!(cs[0].embed);
    assert!(cs[0].embed_text.contains("(defconst sample-big"));
    assert!(cs[0].embed_text.contains("A big table."));
    assert!(!cs[0].embed_text.contains("row-30"));
    assert!(cs[0].fts.body.contains("row-30"));
    assert_eq!(names(&syms), ["sample-big"]);
    assert_eq!(syms[0].kind, "constant");
}

#[test]
fn cl_defstruct_makes_accessors() {
    let (_, syms) = chunks(
        "(cl-defstruct (pt (:constructor pt-new)) \"A point.\" x (y 0))\n(cl-defstruct seg a)\n",
        BUDGET,
    );
    let n = names(&syms);
    for want in [
        "pt", "make-pt", "pt-new", "pt-p", "pt-x", "pt-y", "seg", "make-seg", "seg-p", "seg-a",
    ] {
        assert!(n.contains(&want), "{want} in {n:?}");
    }
}

#[test]
fn minor_mode_makes_hook_and_map() {
    let (_, syms) = chunks(
        "(define-minor-mode sample-mode \"Toggle it.\" :global t)\n",
        BUDGET,
    );
    assert_eq!(
        names(&syms),
        ["sample-mode", "sample-mode-hook", "sample-mode-map"]
    );
    assert_eq!(syms[1].kind, "hook");
    assert_eq!(syms[0].doc1.as_deref(), Some("Toggle it."));
}

#[test]
fn drgnx_module_define_is_a_definer() {
    let text = "(drgnx-module-define 'editor/clipboard\n  :doc \"The clipboard.\" :setup #'ignore)\n\
                (drgnx-defsetting drgnx-x 1 :doc \"A setting.\")\n\
                (defalias 'old #'new)\n";
    let (_, syms) = chunks(text, BUDGET);
    assert_eq!(names(&syms), ["editor/clipboard", "drgnx-x", "old"]);
    assert_eq!(syms[0].kind, "module");
    assert_eq!(syms[0].definer, "drgnx-module-define");
    assert_eq!(syms[0].doc1.as_deref(), Some("The clipboard."));
    assert_eq!(syms[1].kind, "setting");
}

/// Pattern D (Hrafn redesign Task 8, MP-22). A Lisp file's first line gives a title only when it says more than the
/// file's name: `name.el --- Title` keeps `Title`; a line that is the name (with or without the cookie) gives none. The
/// title does not depend on where the file is, so the same text under another path or name is the same header.
#[test]
fn elisp_title_never_carries_the_file_name() {
    let body = "\n(defun t-one ()\n  \"One.\"\n  1)\n";
    let cases = [
        (
            ";;; foo.el --- Timers for all  -*- lexical-binding: t; -*-",
            Some("Timers for all"),
        ),
        (";;; foo.el --- Timers for all", Some("Timers for all")),
        (";;; foo.el -*- lexical-binding: t; -*-", None),
        (";;; foo.el", None),
        (";;; foo.el: the foo things", Some("the foo things")),
    ];
    for (first, title) in cases {
        let text = format!("{first}\n{body}");
        let mut headers = Vec::new();
        for path in ["core/foo.el", "moved/elsewhere/bar.el"] {
            let (cs, _) = chunk_file(path, Lang::Elisp, false, &text, BUDGET);
            for c in &cs {
                // the title is the first line; a `;;;` first line is also the file's first section heading, which
                // is the file's own text (the same wherever it is), not its name
                let line = c.header.lines().next().unwrap_or_default();
                match title {
                    Some(t) => assert_eq!(line, t, "{path} {first:?}: {:?}", c.header),
                    None => assert!(
                        line.starts_with("section: ") || line.starts_with("defines: "),
                        "{path} {first:?}: no title: {:?}",
                        c.header
                    ),
                }
            }
            headers.push(cs.iter().map(|c| c.embed_text.clone()).collect::<Vec<_>>());
        }
        assert_eq!(
            headers[0], headers[1],
            "{first:?}: the path changed the text"
        );
    }
}

#[test]
fn header_not_in_body() {
    let (text, _) = fixture("basic.el");
    let (cs, _) = chunks(&text, 300);
    for c in &cs {
        assert_eq!(c.fts.body, text[c.start as usize..c.end as usize]);
        // the title first; the path is not in the embedded text (Hrafn redesign Task 8)
        assert!(c.embed_text.starts_with("A sample for the chunker"));
        assert!(!c.embed_text.contains("core/sample.el"));
        assert!(c.header.contains("A sample for the chunker"));
        assert_eq!(c.fts.path, "core/sample.el");
        assert!(!c.fts.body.starts_with("core/sample.el"));
        if let Some(s) = &c.symbol {
            assert!(c.fts.symbols.split(' ').any(|x| x == s));
            assert!(!c.fts.body.starts_with(&format!("defines: {s}")));
        }
    }
    // symbols carry their chunk
    let (cs, syms) = chunks(&text, 300);
    for s in &syms {
        let c = &cs[s.chunk as usize];
        assert!(c.start <= s.start && s.start < c.end, "{}", s.name);
    }
}

#[test]
fn generated_file_fts_only() {
    let (text, _) = fixture("basic.el");
    let (cs, syms) = chunk_file("loaddefs.el", Lang::Elisp, true, &text, BUDGET);
    assert!(!cs.is_empty());
    assert!(cs.iter().all(|c| !c.embed));
    assert!(cs.iter().all(|c| !c.fts.body.is_empty()));
    assert!(!syms.is_empty());
}
