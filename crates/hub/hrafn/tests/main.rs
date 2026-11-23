//! The crate's integration tests, one binary (`cargo test -p hrafn --test it`; a file's rows are `<file>::<test>`).
//! Each `tests/<name>.rs` is a module below, so the lib links once, not once per file. A file that needs a
//! process of its own is a `[[test]]` of its own in Cargo.toml, with the reason there, and is named in `APART`.

mod cache;
mod chunk_cpp;
mod chunk_csharp;
mod chunk_elisp;
mod chunk_golden;
mod chunk_langs;
mod chunk_other;
mod door;
mod eval;
mod files;
mod graph;
mod index;
mod map;
mod notebook;
mod overlay;
mod query;
mod rank;
mod refs;
mod rules;
mod shared_content;
mod store;
mod structural;
mod symbol_at;
mod symbols;
mod vector_pack;
mod view_query;

/// The test files that are binaries of their own (Cargo.toml says why).
const APART: &[&str] = &["chunk_missing", "door_no_git", "fetched_pack", "lang_stamp"];

/// `autotests = false` means a file nobody lists never runs, and nothing says so: a new `tests/*.rs` must be a `mod`
/// line above, or (process of its own) a `[[test]]` in Cargo.toml and a name in `APART`.
#[test]
fn every_test_file_is_a_module_here_or_a_declared_binary() {
    let main = include_str!("main.rs");
    let manifest = include_str!("../Cargo.toml");
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
    let mut unlisted = Vec::new();
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|e| e != "rs") {
            continue;
        }
        let name = path.file_stem().unwrap().to_str().unwrap().to_owned();
        if name == "main" {
            continue;
        }
        let listed = if APART.contains(&name.as_str()) {
            manifest.contains(&format!("name = \"{name}\""))
        } else {
            main.lines().any(|l| l.trim() == format!("mod {name};"))
        };
        if !listed {
            unlisted.push(format!("tests/{name}.rs"));
        }
    }
    unlisted.sort();
    assert!(
        unlisted.is_empty(),
        "no `mod` line in tests/main.rs (or no [[test]] for an APART file): {unlisted:?}"
    );
}
