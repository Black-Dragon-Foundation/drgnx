//! Scratch (never committed): dumps each tree-sitter file's symbols, chunk keys and reference counts of the tree in
//! DUMP_ROOT to DUMP_OUT, one line each, sorted, so two builds can be diffed. Run with --ignored.
//! test-pattern: pure (D).

use hrafn::chunk::{BUDGET, CHUNKER_VERSION, chunk_file_refs};
use hrafn::{Lang, classify, vec_key};
use std::fmt::Write;
use std::path::Path;

fn walk(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    let mut es: Vec<_> = rd.flatten().collect();
    es.sort_by_key(|e| e.file_name());
    for e in es {
        let p = e.path();
        let n = e.file_name().to_string_lossy().into_owned();
        if n == ".git" || n == "node_modules" {
            continue;
        }
        if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            walk(&p, out);
        } else {
            out.push(p);
        }
    }
}

#[test]
#[ignore]
fn dump() {
    let root = std::env::var("DUMP_ROOT").expect("DUMP_ROOT");
    let outp = std::env::var("DUMP_OUT").expect("DUMP_OUT");
    let mut files = Vec::new();
    walk(Path::new(&root), &mut files);
    let mut out = String::new();
    for f in files {
        let rel = f
            .strip_prefix(&root)
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let Ok(bytes) = std::fs::read(&f) else {
            continue;
        };
        if bytes.len() > 1 << 20 {
            continue;
        }
        let Ok(text) = String::from_utf8(bytes.clone()) else {
            continue;
        };
        let (lang, _) = classify(&rel, &bytes[..bytes.len().min(512)]);
        if matches!(lang, Lang::Org | Lang::Markdown | Lang::Text | Lang::Elisp) {
            continue;
        }
        let (chunks, symbols, refs) = chunk_file_refs(&rel, lang, false, &text, BUDGET);
        writeln!(
            out,
            "F {rel} {} chunks {} symbols {} refs {}",
            lang.as_str(),
            chunks.len(),
            symbols.len(),
            refs.len()
        )
        .unwrap();
        for c in &chunks {
            let key: String = vec_key(CHUNKER_VERSION, &c.embed_text)
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            writeln!(out, "C {rel} {} {} {key}", c.start, c.end).unwrap();
        }
        for s in &symbols {
            writeln!(
                out,
                "S {rel} {} {} {} {} {}",
                s.kind, s.name, s.start, s.end, s.definer
            )
            .unwrap();
        }
        for r in &refs {
            writeln!(out, "R {rel} {} {} {:?}", r.name, r.n, r.lines).unwrap();
        }
    }
    std::fs::write(outp, out).unwrap();
}
