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

/// A `.h` is C++ when its text says so (a class, a namespace, a template, a `::`, an extension-less standard include), else C: the
/// same file gets the same language wherever it is read, in a pure C project, a mixed one or none.
#[test]
fn a_dot_h_is_cpp_when_its_text_is_and_c_otherwise() {
    let c_header = "#ifndef A_H\n#define A_H\n#include <stdio.h>\n/* class Foo { is only a comment; so is std::string */\ntypedef struct { int x; } point_t;\nint add(int a, int b);\n#endif\n";
    let cpp_headers = [
        "namespace store {\nint f();\n}\n",
        "template <typename T>\nT id(T v);\n",
        "class Cache {\n public:\n  int size();\n};\n",
        "class Fwd;\nvoid use(Fwd* f);\n",
        "#include <vector>\nvoid take(int n);\n",
        "void run(std::string s);\n",
        "struct S {\nprivate:\n  int v;\n};\n",
        "int Cache::size() const;\n",
    ];
    assert_eq!(classify("a.h", c_header.as_bytes()).0, Lang::C);
    for h in cpp_headers {
        assert_eq!(classify("a.h", h.as_bytes()).0, Lang::Cpp, "{h}");
    }
    // only a `.h` is judged by its text: `.c` stays C, `.cc` stays C++, whatever they hold
    assert_eq!(classify("a.c", cpp_headers[0].as_bytes()).0, Lang::C);
    assert_eq!(classify("a.cc", c_header.as_bytes()).0, Lang::Cpp);
    // the rule reads the whole file, not its first bytes: a long licence comment does not hide the class
    let long = format!("/*{}*/\nclass Late {{}};\n", "x".repeat(5000));
    assert_eq!(classify("late.h", long.as_bytes()).0, Lang::Cpp);
    // and a C header chunks as C, a C++ header as C++ (symbols differ: a class is a symbol only in C++)
    let (_, cs) = chunk_file("a.h", Lang::C, false, c_header, BUDGET);
    assert!(cs.iter().all(|s| s.kind != "class"));
    let (_, ps) = chunk_file("b.h", Lang::Cpp, false, cpp_headers[2], BUDGET);
    assert!(ps.iter().any(|s| s.name == "Cache" && s.kind == "class"));
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
fn a_template_specializations_name_is_the_templates() {
    let text = "template <typename T>\nstruct Hash {};\n\ntemplate <>\nstruct Hash<int*> {\n  int v;\n};\n\ntemplate <typename P, typename D>\nclass Random<Ptr<P>*, D> {};\n";
    let (_, symbols) = chunk_file("a.cc", Lang::Cpp, false, text, BUDGET);
    let got: Vec<(&str, &str)> = symbols
        .iter()
        .map(|s| (s.name.as_str(), s.kind.as_str()))
        .collect();
    assert_eq!(
        got,
        [("Hash", "struct"), ("Hash", "struct"), ("Random", "class")]
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
