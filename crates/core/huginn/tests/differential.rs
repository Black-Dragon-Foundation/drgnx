//! The differential gate, huginn's side: what Nidhogg's reader (Emacs's `read` behind core/drgnx-file.el) read from
//! the committed files, as dumps Emacs generated (test/fixtures/huginn/gen.el), is what huginn reads. The editor's
//! side is test/unit/huginn-diff-test.el, which regenerates the dumps and compares them with these.

mod common;

use common::{dump, dump_all, same};
use huginn::read::{Limits, read_all};
use serde_json::Value;
use std::fs;
use std::path::PathBuf;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../test/fixtures/huginn")
}

/// The files with extension `ext` in `corpus/<dir>`, sorted.
fn corpus_files(dir: &str, ext: &str) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = fs::read_dir(fixtures().join("corpus").join(dir))
        .unwrap_or_else(|e| panic!("corpus/{dir}: {e}"))
        .map(|entry| entry.expect("a directory entry").path())
        .filter(|p| p.extension().is_some_and(|e| e == ext))
        .collect();
    files.sort();
    files
}

#[test]
fn committed_corpus_matches() {
    let mut failures = Vec::new();

    let accept = corpus_files("accept", "el");
    assert!(accept.len() >= 40, "only {} accept files", accept.len());
    for file in &accept {
        let name = file.file_name().unwrap().to_string_lossy().into_owned();
        let bytes = fs::read(file).unwrap();
        let Ok(json) = fs::read_to_string(file.with_extension("json")) else {
            failures.push(format!("{name}: no .json dump beside it"));
            continue;
        };
        let expected: Value = serde_json::from_str(&json)
            .unwrap_or_else(|e| panic!("{name}: the dump is not JSON: {e}"));
        match read_all(&bytes, Limits::default()) {
            Ok(nodes) => {
                let actual = dump_all(&nodes);
                if !same(&expected, &actual) {
                    failures.push(format!("{name}: Emacs read {expected}, huginn {actual}"));
                }
            }
            Err(r) => failures.push(format!("{name}: huginn refused it: {r} ({:?})", r.kind)),
        }
    }
    // a dump without its source is a leftover
    for json in corpus_files("accept", "json") {
        if !json.with_extension("el").exists() {
            failures.push(format!("{}: no .el beside it", json.display()));
        }
    }

    let refuse = corpus_files("refuse", "el");
    assert!(refuse.len() >= 40, "only {} refuse files", refuse.len());
    for file in &refuse {
        let name = file.file_name().unwrap().to_string_lossy().into_owned();
        let bytes = fs::read(file).unwrap();
        let first = bytes.split(|&b| b == b'\n').next().unwrap_or_default();
        let Some(kind) = std::str::from_utf8(first)
            .ok()
            .and_then(|l| l.strip_prefix(";; refuse: "))
        else {
            failures.push(format!("{name}: no \";; refuse: KIND\" first line"));
            continue;
        };
        match read_all(&bytes, Limits::default()) {
            Ok(nodes) => failures.push(format!(
                "{name}: expected a refusal ({kind}), huginn read {}",
                dump_all(&nodes)
            )),
            Err(r) if format!("{:?}", r.kind) == kind => {}
            Err(r) => failures.push(format!(
                "{name}: expected {kind}, huginn: {r} ({:?})",
                r.kind
            )),
        }
    }

    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn random_seeded_matches() {
    let eld = fs::read(fixtures().join("random-seeded.eld")).expect("random-seeded.eld");
    let dumps =
        fs::read_to_string(fixtures().join("random-seeded.dump")).expect("random-seeded.dump");
    let expected: Vec<Value> = dumps
        .lines()
        .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("{l}: {e}")))
        .collect();
    assert_eq!(expected.len(), 2000, "seed 1 and N 2000 are committed");

    let nodes = read_all(&eld, Limits::default()).unwrap_or_else(|r| panic!("refused: {r}"));
    assert_eq!(nodes.len(), expected.len(), "the number of data");
    let failures: Vec<String> = nodes
        .iter()
        .zip(&expected)
        .enumerate()
        .filter_map(|(i, (node, want))| {
            let got = dump(node);
            (!same(want, &got)).then(|| {
                let source = &eld[node.span.start..node.span.end];
                format!(
                    "datum {i} {:?}: Emacs read {want}, huginn {got}",
                    String::from_utf8_lossy(source)
                )
            })
        })
        .collect();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
