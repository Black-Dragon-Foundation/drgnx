//! C# is a language of its own (language packs Task 10b): `.cs` files are C#; its pack's `chunks.scm` and `tags.scm` give
//! symbols (namespaces, classes, structs, interfaces, enums, records, delegates, methods, constructors, destructors,
//! operators, properties, events), references and chunks; a golden keeps the chunks and their vector keys as designed.
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
fn cs_files_are_csharp() {
    assert_eq!(classify("A.cs", b"").0, Lang::Csharp);
    assert_eq!(classify("a.csx", b"").0, Lang::Text);
    assert_eq!(Lang::Csharp.as_str(), "csharp");
    assert_eq!(Lang::parse("csharp"), Lang::Csharp);
}

#[test]
fn csharp_symbols_types_members_and_namespaces() {
    let text = fixture("Cache.cs");
    let (_, symbols) = chunk_file("Cache.cs", Lang::Csharp, false, &text, BUDGET);
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
    has("Store", "namespace");
    has("Evicted", "delegate");
    has("Policy", "enum");
    has("Cache", "class");
    has("Cache", "constructor");
    has("Cache", "destructor");
    has("Capacity", "property");
    has("OnEvicted", "event");
    has("Get", "method");
    has("Put", "method");
    has("Evict", "method");
    has("==", "operator");
    has("!=", "operator");
    has("Stats", "struct");
    has("ICache", "interface");
    has("Entry", "record");
    has("Describe", "class");
    has("Print", "method");
}

#[test]
fn csharp_references_are_calls_constructions_and_bases() {
    let text = "class B : Base, IFoo<int> {\n  void F() {\n    Bee(1);\n    obj.Cee();\n    Dee<int>(3);\n    var e = new Eff(2);\n    var g = new Gen<int>();\n  }\n}\n";
    let (_, _, refs) = chunk_file_refs("a.cs", Lang::Csharp, false, text, BUDGET);
    let mut names: Vec<&str> = refs.iter().map(|r| r.name.as_str()).collect();
    names.sort();
    assert_eq!(names, ["Base", "Bee", "Cee", "Dee", "Eff", "Gen", "IFoo"]);
}

#[test]
fn csharp_chunks_and_their_vector_keys_stay_as_designed() {
    let text = fixture("Cache.cs");
    let (chunks, symbols) = chunk_file("Cache.cs", Lang::Csharp, false, &text, BUDGET);
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
        .join("tests/fixtures/golden/chunks-csharp.golden");
    if !path.exists() {
        std::fs::write(&path, &out).unwrap();
        panic!("chunks-csharp.golden was missing and is written now: read it, then commit it");
    }
    assert_eq!(std::fs::read_to_string(&path).unwrap(), out);
}
