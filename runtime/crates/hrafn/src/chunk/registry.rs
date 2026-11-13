//! The chunker's rules of each tree-sitter language, from its pack (language packs Task 5): the manifest's docs rules
//! and `queries/chunks.scm`, compiled into the hub and built once. The grammars are still the crates' (Task 6a moves
//! them to the packs' own builds).

use super::engine::{DocKind, Spec};
use super::ts::Kind;
use skald::manifest::DocMember;
use std::sync::OnceLock;

/// (pack.eld, queries/chunks.scm) of each kind's pack.
fn source(kind: Kind) -> (&'static str, &'static str) {
    macro_rules! pack {
        ($p:literal) => {
            (
                include_str!(concat!("../../../../../packs/", $p, "/pack.eld")),
                include_str!(concat!("../../../../../packs/", $p, "/queries/chunks.scm")),
            )
        };
    }
    match kind {
        Kind::Rust => pack!("rust"),
        Kind::C => pack!("c"),
        Kind::Shell => pack!("shell"),
        Kind::Python => pack!("python"),
        Kind::JavaScript => pack!("javascript"),
        Kind::TypeScript => pack!("typescript"),
        Kind::Tsx => pack!("tsx"),
        Kind::Go => pack!("go"),
        Kind::Java => pack!("java"),
    }
}

fn doc_kind(m: &DocMember) -> DocKind {
    match m {
        DocMember::Line => DocKind::Line,
        DocMember::Block => DocKind::Block,
        DocMember::Docstring => DocKind::Docstring,
    }
}

fn build(kind: Kind) -> Result<Spec, String> {
    let (manifest, scm) = source(kind);
    let m = skald::read(manifest.as_bytes()).map_err(|e| e.to_string())?;
    let docs = m.hrafn.and_then(|h| h.docs).unwrap_or_default();
    let members: Vec<DocKind> = docs.members.iter().map(doc_kind).collect();
    let top: Vec<DocKind> = docs.top.iter().map(doc_kind).collect();
    Spec::new(
        &kind.language(),
        scm,
        docs.line.as_deref(),
        docs.block.is_some(),
        &members,
        &top,
    )
}

/// KIND's chunking rules, built once. A pack that does not compile against its grammar is a bug a test pins.
pub(super) fn spec(kind: Kind) -> &'static Spec {
    static SPECS: OnceLock<Vec<Result<Spec, String>>> = OnceLock::new();
    let all = SPECS.get_or_init(|| Kind::ALL.iter().map(|k| build(*k)).collect());
    let i = Kind::ALL
        .iter()
        .position(|k| *k == kind)
        .expect("a listed kind");
    match &all[i] {
        Ok(s) => s,
        Err(e) => panic!(
            "the {} pack's chunks.scm does not build: {e}",
            pack_name(kind)
        ),
    }
}

fn pack_name(kind: Kind) -> &'static str {
    match kind {
        Kind::Rust => "rust",
        Kind::C => "c",
        Kind::Shell => "shell",
        Kind::Python => "python",
        Kind::JavaScript => "javascript",
        Kind::TypeScript => "typescript",
        Kind::Tsx => "tsx",
        Kind::Go => "go",
        Kind::Java => "java",
    }
}

/// Every kind's build result (a test checks each compiles).
#[cfg(test)]
pub(super) fn build_all() -> Vec<(Kind, Result<(), String>)> {
    Kind::ALL
        .iter()
        .map(|k| (*k, build(*k).map(|_| ())))
        .collect()
}
