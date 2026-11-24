//! The chunks and symbols of the languages Hrafn already parsed (Rust, C, shell, Lisp, Org, Markdown) stay what they
//! were: a chunk's content key names its vectors, so a change here would re-embed every project. The golden was made
//! by the chunker before symbols gained lines and signatures (a missing golden is written, and the test fails once).
//!
//! The other tree-sitter languages (Python, JavaScript, TypeScript, TSX, Go, Java) have their own golden, made by the
//! chunker before it became query-driven (language packs, Task 5a): the query engine and the pack grammars must keep
//! it byte for byte, or each change is read in a commit of its own.
//!
//! test-pattern: pure (D).

use hrafn::chunk::{BUDGET, chunk_file, embed_text_and_key};
use hrafn::{chunk_key, classify};
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
        let text = eitri::read_string(&dir.join(name), 4 << 20).unwrap();
        let (lang, _) = classify(name, text.as_bytes());
        let (chunks, symbols) = chunk_file(name, lang, false, &text, BUDGET);
        writeln!(out, "# {name} {}", lang.as_str()).unwrap();
        for c in &chunks {
            let key: String = embed_text_and_key(c)
                .1
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
        eitri::replace_file(&path, now.as_bytes()).unwrap();
        panic!(
            "{golden_name} was missing and is written now: make it on the chunker it guards, then commit it"
        );
    }
    let golden = eitri::read_string(&path, 4 << 20).unwrap();
    for (i, (a, b)) in golden.lines().zip(now.lines()).enumerate() {
        assert_eq!(a, b, "line {} of {golden_name}", i + 1);
    }
    assert_eq!(golden.lines().count(), now.lines().count());
}

#[test]
fn old_languages_chunk_as_before() {
    compare("chunks.golden", render(FILES, fixtures().join("golden")));
}

/// Pattern D (Hrafn redesign Task 8). No golden fixture's chunk, put under a path of directories, carries its path or
/// file name in what is embedded: the header (title, section, `defines:`, `part i/n`) is path-free, and the text sent
/// is the chunk's `embed_text`, hashed into its key.
#[test]
fn embed_text_has_no_path() {
    for (files, dir) in [
        (FILES, fixtures().join("golden")),
        (LANG_FILES, fixtures().join("langs")),
    ] {
        for name in files {
            let text = eitri::read_string(&dir.join(name), 4 << 20).unwrap();
            let path = format!("deep/nested/{name}");
            let (lang, _) = classify(&path, text.as_bytes());
            let (chunks, _) = chunk_file(&path, lang, false, &text, BUDGET);
            assert!(!chunks.is_empty(), "{path}");
            let (elsewhere, _) = chunk_file(&format!("other/{name}"), lang, false, &text, BUDGET);
            let texts = |cs: &[hrafn::chunk::Chunk]| -> Vec<String> {
                cs.iter().map(|c| c.embed_text.clone()).collect()
            };
            assert_eq!(
                texts(&chunks),
                texts(&elsewhere),
                "{name}: the path changed the text"
            );
            for c in &chunks {
                let (sent, key) = embed_text_and_key(c);
                assert_eq!(sent, c.embed_text);
                assert_eq!(key, chunk_key(sent));
                assert!(
                    c.embed_text.starts_with(&c.header),
                    "{path}: {:?}",
                    c.embed_text
                );
                // (a header may quote the file's own text, a section heading naming the file, but never its path)
                assert!(
                    !c.header.contains("deep/nested"),
                    "{path}: the header {:?}",
                    c.header
                );
                // a file whose own text never names it: nothing embedded does
                if !text.contains(*name) {
                    assert!(!c.embed_text.contains(*name), "{path}");
                }
                assert_eq!(c.fts.path, path, "the FTS path column keeps it");
            }
        }
    }
}

#[test]
fn tree_sitter_languages_chunk_as_before() {
    compare(
        "chunks-langs.golden",
        render(LANG_FILES, fixtures().join("langs")),
    );
}
