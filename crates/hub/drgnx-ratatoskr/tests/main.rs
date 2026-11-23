//! The crate's integration tests, one binary (`cargo test -p drgnx-ratatoskr --test it`; a file's rows are `<file>::<test>`).
//! Each `tests/<name>.rs` is a module below, so the lib links once, not once per file. A file that needs a
//! process of its own is a `[[test]]` of its own in Cargo.toml, with the reason there, and is named in `APART`; the
//! timing, sandbox and fleet files are modules of three more binaries (`tests/groups/<name>.rs`), also in `APART`.

mod debug_lsp_command;
mod gated;
mod gated_exit;
mod hrafn_parse;
mod hub_reads_its_clock;
mod packs_sync;
mod runners_orders;
mod sandbox_check;
mod search_download;
mod search_eval_sources;
mod search_fingerprint;
mod search_modes_rows;
mod search_prefer;
mod search_query;
mod search_servers;
mod search_tools;
mod server;
mod support;
mod wheel;

/// The test files that are binaries of their own (Cargo.toml says why).
const APART: &[&str] = &[
    "browser_real",
    "browser_sandboxed",
    "editor_timing",
    "fleet_cloud",
    "fleet_drills",
    "fleet_keys",
    "fleet_link",
    "fleet_registry",
    "fleet_runners",
    "fleet_sync",
    "hrafn_parse_sandbox",
    "launch_sandboxed",
    "mac_runner",
    "macos",
    "pair_timing",
    "sandbox_inner",
    "sandbox_run",
    "search_index",
    "term_scope",
    "timing",
    "work_timing",
];

/// `autotests = false` means a file nobody lists never runs, and nothing says so: a new `tests/*.rs` must be a `mod`
/// line above, or (process of its own) a `[[test]]` in Cargo.toml and a name in `APART`.
#[test]
fn every_test_file_is_a_module_here_or_a_declared_binary() {
    let main = include_str!("main.rs");
    let manifest = include_str!("../Cargo.toml");
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
    // the group binaries' roots (tests/groups/*.rs) name their member files by `#[path = "../<file>.rs"]`
    let groups: String = std::fs::read_dir(dir.join("groups"))
        .unwrap()
        .map(|e| std::fs::read_to_string(e.unwrap().path()).unwrap())
        .collect();
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
                || groups.contains(&format!("../{name}.rs"))
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
        "no `mod` line in tests/main.rs (or no [[test]] or groups/ root for an APART file): {unlisted:?}"
    );
}
