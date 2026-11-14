//! The chunker's rules of each tree-sitter language, from its pack (language packs Task 5): the manifest's docs rules
//! and `queries/chunks.scm`, compiled into the hub and built once. The grammars come from the pack registry
//! (`skald::registry`): the libraries the pack job built, never a crate linked into the hub.

use super::engine::{DocKind, Spec};
use super::ts::Kind;
use skald::manifest::DocMember;
use std::sync::{Mutex, OnceLock, PoisonError};

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
        Kind::Cpp => pack!("cpp"),
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
    let language = language(kind).ok_or("its grammar is not built")?;
    Spec::new(
        &language,
        scm,
        docs.line.as_deref(),
        docs.block.is_some(),
        &members,
        &top,
    )
}

/// The name of the grammar KIND's pack owns (its first `:grammars` entry; a test pins it).
pub(super) fn grammar_name(kind: Kind) -> &'static str {
    match kind {
        Kind::Rust => "rust",
        Kind::C => "c",
        Kind::Cpp => "cpp",
        Kind::Shell => "bash",
        Kind::Python => "python",
        Kind::JavaScript => "javascript",
        Kind::TypeScript => "typescript",
        Kind::Tsx => "tsx",
        Kind::Go => "go",
        Kind::Java => "java",
    }
}

pub(super) fn pack_name(kind: Kind) -> &'static str {
    match kind {
        Kind::Rust => "rust",
        Kind::C => "c",
        Kind::Cpp => "cpp",
        Kind::Shell => "shell",
        Kind::Python => "python",
        Kind::JavaScript => "javascript",
        Kind::TypeScript => "typescript",
        Kind::Tsx => "tsx",
        Kind::Go => "go",
        Kind::Java => "java",
    }
}

/// Called once for each pack whose grammar is not available: the pack and why. The hub logs the line.
pub type MissingHook = fn(pack: &str, reason: &str);

static HOOK: OnceLock<MissingHook> = OnceLock::new();
static SAID: Mutex<Vec<&'static str>> = Mutex::new(Vec::new());

/// Install the function that says a pack's grammar is not built (the hub's log). Only the first call counts.
pub fn on_missing(hook: MissingHook) {
    let _ = HOOK.set(hook);
}

fn say_missing(kind: Kind, reason: &str) {
    let pack = pack_name(kind);
    let mut said = SAID.lock().unwrap_or_else(PoisonError::into_inner);
    if !said.contains(&pack) {
        said.push(pack);
        if let Some(h) = HOOK.get() {
            h(pack, reason);
        }
    }
}

/// KIND's grammar from the pack registry, or none: the file then reads as text. The first miss of a pack is said.
pub(super) fn language(kind: Kind) -> Option<tree_sitter::Language> {
    match skald::registry::language(grammar_name(kind)) {
        Ok(l) => Some(l),
        Err(e) => {
            say_missing(kind, &e.reason);
            None
        }
    }
}

/// KIND's chunking rules, built on first use once its grammar is there; none while it is not (nothing is cached
/// then, so a grammar built later is found). A pack that does not compile against its grammar is a bug a test pins.
pub(super) fn spec(kind: Kind) -> Option<&'static Spec> {
    static SPECS: Mutex<Vec<(Kind, &'static Spec)>> = Mutex::new(Vec::new());
    let mut specs = SPECS.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some((_, s)) = specs.iter().find(|(k, _)| *k == kind) {
        return Some(s);
    }
    language(kind)?;
    match build(kind) {
        Ok(s) => {
            let s: &'static Spec = Box::leak(Box::new(s));
            specs.push((kind, s));
            Some(s)
        }
        Err(e) => {
            say_missing(kind, &format!("its chunks.scm does not build: {e}"));
            None
        }
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

/// The packs whose grammar the hub parses with, as (pack, grammar): what the doctor checks is built.
pub fn hub_grammars() -> Vec<(&'static str, &'static str)> {
    Kind::ALL
        .iter()
        .map(|k| (pack_name(*k), grammar_name(*k)))
        .collect()
}

/// A hash of what the chunker derives from the packs: each tree-sitter language's pack (manifest, `chunks.scm`,
/// `tags.scm`, the grammar's commit is in the manifest) and whether its grammar is built. It moves when a pack changes
/// or a grammar is built (or lost); the index then parses its files again, and a chunk whose text did not change keeps
/// its key and its vector.
pub fn stamp() -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(crate::files::LANG_RULES.to_le_bytes());
    for k in Kind::ALL {
        let (manifest, chunks) = source(k);
        for part in [pack_name(k), manifest, chunks, super::refs::tags_source(k)] {
            h.update(part.as_bytes());
            h.update([0]);
        }
        h.update([u8::from(skald::registry::language(grammar_name(k)).is_ok())]);
    }
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}
