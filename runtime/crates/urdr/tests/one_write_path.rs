//! The graph tables have one write path: no Rust file outside `urdr/src/graph/` writes them (storage §5.2).

use std::path::{Path, PathBuf};

const TABLES: [&str; 9] = [
    "tx",
    "entity",
    "entity_hist",
    "link",
    "link_stat",
    "entity_fts",
    "entity_vec",
    "project_alias",
    "excise_log",
];

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in rd.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        if path.is_dir() {
            if name != "target" && name != ".git" && name != "node_modules" {
                rust_files(&path, out);
            }
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

fn is_ident(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// The write statements in TEXT (lowercased, whitespace collapsed) that name one of the nine tables.
fn hits(text: &str) -> Vec<String> {
    let text = text
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    // Built from pieces so that this file does not match itself.
    let verbs = [
        ["insert", " into "].concat(),
        ["insert or replace", " into "].concat(),
        ["replace", " into "].concat(),
        ["upd", "ate "].concat(),
        ["delete", " from "].concat(),
    ];
    let mut found = Vec::new();
    for verb in &verbs {
        for (at, _) in text.match_indices(verb.as_str()) {
            if text[..at].chars().next_back().is_some_and(is_ident) {
                continue;
            }
            let rest = &text[at + verb.len()..];
            let word: String = rest.chars().take_while(|c| is_ident(*c)).collect();
            if TABLES.contains(&word.as_str()) {
                found.push(format!("{verb}{word}"));
            }
        }
    }
    found
}

#[test]
fn no_other_code_writes_graph_tables() {
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let graph = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("src")
        .join("graph");
    let mut files = Vec::new();
    rust_files(&crates, &mut files);
    assert!(
        files.len() > 10,
        "found only {} Rust files: wrong root?",
        files.len()
    );
    let mut bad = Vec::new();
    for file in files {
        let canon = file.canonicalize().unwrap_or(file.clone());
        let in_graph = graph.canonicalize().is_ok_and(|g| canon.starts_with(g));
        let this = canon.ends_with("tests/one_write_path.rs");
        if in_graph || this {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&file) else {
            continue;
        };
        for h in hits(&text) {
            bad.push(format!("{}: {h}", file.display()));
        }
    }
    assert!(
        bad.is_empty(),
        "graph tables written outside urdr/src/graph:\n{}",
        bad.join("\n")
    );
}

#[test]
fn the_scanner_sees_a_write() {
    let stmt = ["insert", " into entity (id) values (1)"].concat();
    assert_eq!(hits(&stmt).len(), 1);
    let stmt = ["delete", "\n   from  link where id = 1"].concat();
    assert_eq!(hits(&stmt).len(), 1);
    assert!(hits("select * from entity").is_empty());
}
