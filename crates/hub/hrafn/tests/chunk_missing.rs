//! A pack whose grammar is not built reads as text (language packs Task 6a): no chunk is named after a symbol, no
//! reference is found, structural search and inline values have no grammar, the pack is named once through the hook,
//! and nothing panics or waits. Its own process: the grammar registry is process-wide.
//!
//! test-pattern: pure (D).

use hrafn::chunk::{BUDGET, chunk_file, on_missing};
use hrafn::{Lang, classify};
use std::sync::Mutex;

static SAID: Mutex<Vec<String>> = Mutex::new(Vec::new());

#[test]
fn a_pack_with_no_built_grammar_reads_as_text_and_is_named_once() {
    skald::registry::install(Vec::new());
    on_missing(|pack, why| SAID.lock().unwrap().push(format!("{pack}: {why}")));
    let text = "pub fn alpha() {}\n\nfn beta() { alpha(); }\n";
    let (lang, _) = classify("a.rs", text.as_bytes());
    assert_eq!(lang, Lang::Rust);
    for _ in 0..2 {
        let (chunks, symbols) = chunk_file("a.rs", lang, false, text, BUDGET);
        assert!(!chunks.is_empty());
        assert!(symbols.is_empty(), "text has no symbols: {symbols:?}");
        assert!(chunks.iter().all(|c| c.symbol.is_none()));
    }
    assert!(hrafn::structural::language(Lang::Rust).is_none());
    let said = SAID.lock().unwrap();
    assert_eq!(said.len(), 1, "{said:?}");
    assert!(said[0].starts_with("rust: "), "{said:?}");
    // Lisp has no pack grammar: it still chunks
    let (_, symbols) = chunk_file("a.el", Lang::Elisp, false, "(defun f () 1)\n", BUDGET);
    assert_eq!(symbols.len(), 1);
}
