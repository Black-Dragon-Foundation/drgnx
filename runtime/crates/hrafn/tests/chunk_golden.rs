//! The chunks and symbols of the languages Hrafn already parsed (Rust, C, shell, Lisp, Org, Markdown) stay what they
//! were: a chunk's content key names its vectors, so a change here would re-embed every project. The golden was made
//! by the chunker before symbols gained lines and signatures (a missing golden is written, and the test fails once).
//!
//! The other tree-sitter languages (Python, JavaScript, TypeScript, TSX, Go, Java) have their own golden, made by the
//! chunker before it became query-driven (language packs, Task 5a): the query engine and the pack grammars must keep
//! it byte for byte, or each change is read in a commit of its own.
//!
//! test-pattern: pure (D).

use hrafn::chunk::{BUDGET, CHUNKER_VERSION, chunk_file};
use hrafn::{classify, vec_key};
use std::fmt::Write;
use std::path::PathBuf;

const FILES: &[&str] = &[
    "merge.rs",
    "gnu.c",
    "changes.sh",
    "memo.el",
    "projects.org",
    "search.md",
];

const LANG_FILES: &[&str] = &[
    "shapes.py",
    "server.js",
    "app.test.js",
    "client.ts",
    "view.tsx",
    "store.go",
    "Queue.java",
];

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn render(files: &[&str], dir: PathBuf) -> String {
    let mut out = String::new();
    for name in files {
        let text = std::fs::read_to_string(dir.join(name)).unwrap();
        let (lang, _) = classify(name, text.as_bytes());
        let (chunks, symbols) = chunk_file(name, lang, false, &text, BUDGET);
        writeln!(out, "# {name} {}", lang.as_str()).unwrap();
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
    }
    out
}

fn compare(golden_name: &str, now: String) {
    let path = fixtures().join("golden").join(golden_name);
    if !path.exists() {
        std::fs::write(&path, &now).unwrap();
        panic!(
            "{golden_name} was missing and is written now: make it on the chunker it guards, then commit it"
        );
    }
    let golden = std::fs::read_to_string(&path).unwrap();
    for (i, (a, b)) in golden.lines().zip(now.lines()).enumerate() {
        assert_eq!(a, b, "line {} of {golden_name}", i + 1);
    }
    assert_eq!(golden.lines().count(), now.lines().count());
}

#[test]
fn old_languages_chunk_as_before() {
    compare("chunks.golden", render(FILES, fixtures().join("golden")));
}

#[test]
fn tree_sitter_languages_chunk_as_before() {
    compare(
        "chunks-langs.golden",
        render(LANG_FILES, fixtures().join("langs")),
    );
}
