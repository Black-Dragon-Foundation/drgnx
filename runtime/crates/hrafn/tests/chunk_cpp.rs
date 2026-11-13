//! C++ is a language of its own (language packs Task 9): `.cc .cpp .cxx .hpp .hh .h++` are C++, `.h` stays C; its
//! pack's `chunks.scm` and `tags.scm` give symbols (classes, templates, namespaces, methods, destructors, operators,
//! macros), references and chunks; a golden keeps the chunks and their vector keys as designed.
//!
//! test-pattern: pure (D).

use hrafn::chunk::{BUDGET, CHUNKER_VERSION, chunk_file, chunk_file_refs};
use hrafn::{Lang, classify, vec_key};
use std::fmt::Write;
use std::path::PathBuf;

fn fixture(name: &str) -> String {
    std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/langs")
            .join(name),
    )
    .unwrap()
}

#[test]
fn cpp_files_are_cpp_and_h_stays_c() {
    for path in ["a.cc", "a.cpp", "a.cxx", "a.hpp", "a.hh", "a.h++"] {
        assert_eq!(classify(path, b"").0, Lang::Cpp, "{path}");
    }
    assert_eq!(classify("a.h", b"").0, Lang::C);
    assert_eq!(classify("a.c", b"").0, Lang::C);
    assert_eq!(Lang::Cpp.as_str(), "cpp");
    assert_eq!(Lang::parse("cpp"), Lang::Cpp);
}

#[test]
fn cpp_symbols_classes_templates_namespaces_methods_and_macros() {
    let text = fixture("cache.cpp");
    let (_, symbols) = chunk_file("cache.cpp", Lang::Cpp, false, &text, BUDGET);
    let got: Vec<(String, String)> = symbols
        .iter()
        .map(|s| (s.name.clone(), s.kind.clone()))
        .collect();
    let has = |name: &str, kind: &str| {
        assert!(
            got.iter().any(|(n, k)| n == name && k == kind),
            "{name} {kind} in {got:?}"
        )
    };
    has("CACHE_MAX_ENTRIES", "macro");
    has("CACHE_MIN", "macro");
    has("store", "namespace");
    has("Key", "type");
    has("Policy", "enum");
    has("Cache", "class");
    has("Cache", "method"); // the constructor, written in the class
    has("get", "method");
    has("operator==", "method");
    has("Stats", "struct");
    has("put", "function"); // the out-of-line definition, inside the template wrapper
    has("~Cache", "function");
    has("describe", "function");
    has("cache_version", "function");
    // a member function's name is its own, never a qualified path or the class
    assert!(got.iter().all(|(n, _)| !n.contains("::")), "{got:?}");
    // the doc line above a class and a function
    let doc = |name: &str, kind: &str| {
        symbols
            .iter()
            .find(|s| s.name == name && s.kind == kind)
            .and_then(|s| s.doc1.clone())
    };
    assert_eq!(
        doc("Cache", "class").as_deref(),
        Some("A least-recently-used cache of values by key.")
    );
    assert_eq!(
        doc("describe", "function").as_deref(),
        Some("Prints the size.")
    );
}

#[test]
fn cpp_references_are_calls_constructions_and_bases() {
    let text = "struct B : Base {\n  void f() {\n    bee(1);\n    obj.cee();\n    ns::dee();\n    new Eff(2);\n    gee<int>(3);\n  }\n};\n";
    let (_, _, refs) = chunk_file_refs("a.cpp", Lang::Cpp, false, text, BUDGET);
    let mut names: Vec<&str> = refs.iter().map(|r| r.name.as_str()).collect();
    names.sort();
    assert_eq!(names, ["Base", "Eff", "bee", "cee", "dee", "gee"]);
}

#[test]
fn cpp_chunks_and_their_vector_keys_stay_as_designed() {
    let text = fixture("cache.cpp");
    let (chunks, symbols) = chunk_file("cache.cpp", Lang::Cpp, false, &text, BUDGET);
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
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden/chunks-cpp.golden");
    if !path.exists() {
        std::fs::write(&path, &out).unwrap();
        panic!("chunks-cpp.golden was missing and is written now: read it, then commit it");
    }
    assert_eq!(std::fs::read_to_string(&path).unwrap(), out);
}
