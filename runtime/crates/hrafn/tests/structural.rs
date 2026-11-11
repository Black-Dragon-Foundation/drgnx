//! Structural search (`hrafn::structural`): ast-grep patterns over Hrafn's own grammars.
//!
//! test-pattern: pure (D): a pattern and a file's text in, matches out; no clock, no file system.

use hrafn::Lang;
use hrafn::structural::{Pattern, Skip};

fn found(lang: Lang, pattern: &str, text: &str) -> Vec<String> {
    let p = Pattern::new(lang, pattern, None).unwrap();
    p.find(text.as_bytes())
        .unwrap()
        .into_iter()
        .map(|m| text[m.start..m.end].to_owned())
        .collect()
}

#[test]
fn a_metavariable_matches_one_node_and_names_it() {
    let text = "fn f() { foo(1, x); foo(y); bar(2, z); }";
    let p = Pattern::new(Lang::Rust, "foo($A, $B)", None).unwrap();
    let ms = p.find(text.as_bytes()).unwrap();
    assert_eq!(ms.len(), 1);
    assert_eq!(&text[ms[0].start..ms[0].end], "foo(1, x)");
    assert_eq!(ms[0].captures.get("A").map(String::as_str), Some("1"));
    assert_eq!(ms[0].captures.get("B").map(String::as_str), Some("x"));
    // `$_`: one node, not named
    let p = Pattern::new(Lang::Rust, "foo($_)", None).unwrap();
    let ms = p.find(text.as_bytes()).unwrap();
    assert_eq!(ms.len(), 1);
    assert!(ms[0].captures.is_empty());
}

#[test]
fn a_sequence_metavariable_matches_any_number() {
    let text = "fn f() { bar(); bar(a, b, c); baz(a); }";
    assert_eq!(
        found(Lang::Rust, "bar($$$ARGS)", text),
        ["bar()", "bar(a, b, c)"]
    );
    let p = Pattern::new(Lang::Rust, "bar($$$ARGS)", None).unwrap();
    let ms = p.find(text.as_bytes()).unwrap();
    assert_eq!(
        ms[1].captures.get("ARGS").map(String::as_str),
        Some("a, b, c")
    );
}

#[test]
fn the_same_name_twice_matches_the_same_text() {
    let text = "(when (eq x x) (eq x y) (eq (car l) (car l)))";
    assert_eq!(
        found(Lang::Elisp, "(eq $A $A)", text),
        ["(eq x x)", "(eq (car l) (car l))"]
    );
    let text = "fn f() { g(a, a); g(a, b); }";
    assert_eq!(found(Lang::Rust, "g($X, $X)", text), ["g(a, a)"]);
}

#[test]
fn every_grammar_takes_a_metavariable() {
    for (lang, pattern, text, want) in [
        (Lang::Elisp, "(setq $V 1)", "(setq a 1)", "(setq a 1)"),
        (
            Lang::Rust,
            "let $V = 1;",
            "fn f() { let a = 1; }",
            "let a = 1;",
        ),
        (
            Lang::C,
            "f($A + 1)",
            "int g() { return f(2 + 1); }",
            "f(2 + 1)",
        ),
        (Lang::Shell, "echo $A", "echo hi\n", "echo hi"),
        (Lang::Python, "f($A)", "x = f(2)\n", "f(2)"),
        (Lang::JavaScript, "f($A)", "const x = f(2);", "f(2)"),
        (Lang::TypeScript, "f($A)", "const x: number = f(2);", "f(2)"),
        (Lang::Tsx, "f($A)", "const x = f(<a/>);", "f(<a/>)"),
        (Lang::Go, "f($A)", "package p\nfunc g() { f(2) }\n", "f(2)"),
        (
            Lang::Java,
            "f($A)",
            "class C { void g() { f(2); } }",
            "f(2)",
        ),
    ] {
        assert_eq!(found(lang, pattern, text), [want], "{lang:?} {pattern}");
    }
}

#[test]
fn a_template_expands_the_names() {
    let text = "(list (gethash k drgnx-gateway--queued) (gethash (car l) drgnx-gateway--queued))";
    let p = Pattern::new(
        Lang::Elisp,
        "(gethash $K drgnx-gateway--queued)",
        Some("(map-elt drgnx-gateway--queued $K)"),
    )
    .unwrap();
    let new: Vec<_> = p
        .find(text.as_bytes())
        .unwrap()
        .into_iter()
        .map(|m| m.replacement.unwrap())
        .collect();
    assert_eq!(
        new,
        [
            "(map-elt drgnx-gateway--queued k)",
            "(map-elt drgnx-gateway--queued (car l))"
        ]
    );
    let p = Pattern::new(Lang::Rust, "foo($$$A)", Some("bar($$$A)")).unwrap();
    let ms = p.find(b"fn f() { foo(1, 2); }").unwrap();
    assert_eq!(ms[0].replacement.as_deref(), Some("bar(1, 2)"));
}

#[test]
fn a_match_over_lines_carries_its_end() {
    let text = "fn f() {\n    foo(\n        1,\n        2,\n    );\n}\n";
    let p = Pattern::new(Lang::Rust, "foo($$$A)", None).unwrap();
    let ms = p.find(text.as_bytes()).unwrap();
    assert_eq!(ms.len(), 1);
    let m = &ms[0];
    // lines from 1, columns in characters from 0
    assert_eq!((m.line, m.col), (2, 4));
    assert_eq!((m.end_line, m.end_col), (5, 5));
}

#[test]
fn a_column_counts_characters() {
    let text = "(list \"äö\" (eq x x))";
    let p = Pattern::new(Lang::Elisp, "(eq $A $A)", None).unwrap();
    let m = &p.find(text.as_bytes()).unwrap()[0];
    assert_eq!((m.col, m.end_col), (11, 19));
}

#[test]
fn a_file_that_cannot_be_parsed_is_skipped_with_a_reason() {
    let p = Pattern::new(Lang::Rust, "foo($A)", None).unwrap();
    let skip = p.find(b"fn f() { foo(\xff\xfe); }").unwrap_err();
    assert_eq!(skip, Skip::NotUtf8);
    assert_eq!(skip.reason(), "not UTF-8");
}

#[test]
fn a_language_without_a_grammar_is_refused() {
    let e = Pattern::new(Lang::Org, "* $A", None).err().unwrap();
    assert_eq!(e.lang, Lang::Org);
    assert_eq!(e.to_string(), "no grammar for org files");
    assert!(Pattern::new(Lang::Text, "x", None).is_err());
}

#[test]
fn a_pattern_that_does_not_parse_names_the_language_and_column() {
    let e = Pattern::new(Lang::Rust, "fn $F() { let = 1; }", None)
        .err()
        .unwrap();
    assert_eq!(e.lang, Lang::Rust);
    assert_eq!(e.col, Some(14));
    assert_eq!(e.to_string(), "pattern is not valid Rust at col 14");
    let e = Pattern::new(Lang::Elisp, "(eq $A $A))", None)
        .err()
        .unwrap();
    assert_eq!(e.to_string(), "pattern is not valid Emacs Lisp at col 10");
    // an expression at a file's top level is no error (the grammar's wrapper around one whole node)
    assert!(Pattern::new(Lang::Rust, "foo($A)", None).is_ok());
    // an empty one says so
    let e = Pattern::new(Lang::Elisp, "  ", None).err().unwrap();
    assert_eq!(e.col, None);
}

#[test]
fn the_literals_are_the_names_that_are_not_metavariables() {
    let p = Pattern::new(Lang::Elisp, "(gethash $K drgnx-gateway--queued)", None).unwrap();
    assert_eq!(p.literals(), ["gethash", "drgnx-gateway--queued"]);
    let p = Pattern::new(Lang::Rust, "foo($A, \"s\", 1)", None).unwrap();
    assert_eq!(p.literals(), ["foo"]);
    // only metavariables: nothing narrows the files
    let p = Pattern::new(Lang::Rust, "$F($$$A)", None).unwrap();
    assert!(p.literals().is_empty());
}

/// The pre-filter's golden: over a corpus per language, every text the full scan matches holds every literal, so a
/// search that reads only files holding them drops none.
#[test]
fn the_pre_filter_never_drops_a_match() {
    for (lang, pattern, texts) in [
        (
            Lang::Elisp,
            "(setq $V (gethash $K tbl))",
            &[
                "(setq a (gethash k tbl))",
                "(setq a\n  (gethash\n   k tbl))",
                "(setq a (gethash k other))",
                ";; tbl gethash\n(setq a b)",
            ][..],
        ),
        (
            Lang::Rust,
            "self.queue.push($A)",
            &[
                "fn f(&mut self) { self.queue.push(1); }",
                "fn f(&mut self) { self\n  .queue\n  .push(1); }",
                "fn f(&mut self) { self.queue.pop(); }",
                "// self.queue.push(x)\nfn f() {}",
            ][..],
        ),
        (
            Lang::Python,
            "logger.info($A)",
            &[
                "logger.info('x')\n",
                "logger . info ( 'x' )\n",
                "log.info('x')\n",
            ][..],
        ),
        (
            Lang::Go,
            "fmt.Println($A, $B)",
            &[
                "package p\nfunc g() { fmt.Println(1, 2) }\n",
                "package p\nfunc g() { fmt.Printf(\"\") }\n",
            ][..],
        ),
    ] {
        let p = Pattern::new(lang, pattern, None).unwrap();
        assert!(!p.literals().is_empty(), "{lang:?}: {pattern} has literals");
        let mut matched = 0;
        for t in texts {
            if !p.find(t.as_bytes()).unwrap().is_empty() {
                matched += 1;
                for l in p.literals() {
                    assert!(t.contains(l.as_str()), "{lang:?}: {t:?} lacks {l:?}");
                }
            }
        }
        assert!(matched >= 1, "{lang:?}: the corpus has a match");
    }
}
