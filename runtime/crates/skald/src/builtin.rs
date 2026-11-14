//! The built-in packs' manifests, compiled in (`packs/NAME/pack.eld`): what the hub reads for its own languages without
//! `active.eld` (Hrafn's chunker, the debug adapters, inline values and origin trails), as the manifests of installed
//! packs are read from disk.

use crate::manifest::{Manifest, read};
use std::sync::OnceLock;

/// (name, manifest text) of every built-in pack, by name.
pub const SOURCES: &[(&str, &str)] = &[
    ("c", include_str!("../../../../packs/c/pack.eld")),
    ("cpp", include_str!("../../../../packs/cpp/pack.eld")),
    ("css", include_str!("../../../../packs/css/pack.eld")),
    ("dart", include_str!("../../../../packs/dart/pack.eld")),
    ("elixir", include_str!("../../../../packs/elixir/pack.eld")),
    ("go", include_str!("../../../../packs/go/pack.eld")),
    (
        "haskell",
        include_str!("../../../../packs/haskell/pack.eld"),
    ),
    ("html", include_str!("../../../../packs/html/pack.eld")),
    ("java", include_str!("../../../../packs/java/pack.eld")),
    (
        "javascript",
        include_str!("../../../../packs/javascript/pack.eld"),
    ),
    ("json", include_str!("../../../../packs/json/pack.eld")),
    ("kotlin", include_str!("../../../../packs/kotlin/pack.eld")),
    ("lua", include_str!("../../../../packs/lua/pack.eld")),
    ("php", include_str!("../../../../packs/php/pack.eld")),
    ("python", include_str!("../../../../packs/python/pack.eld")),
    ("ruby", include_str!("../../../../packs/ruby/pack.eld")),
    ("rust", include_str!("../../../../packs/rust/pack.eld")),
    ("shell", include_str!("../../../../packs/shell/pack.eld")),
    ("sql", include_str!("../../../../packs/sql/pack.eld")),
    ("swift", include_str!("../../../../packs/swift/pack.eld")),
    (
        "terraform",
        include_str!("../../../../packs/terraform/pack.eld"),
    ),
    ("toml", include_str!("../../../../packs/toml/pack.eld")),
    ("tsx", include_str!("../../../../packs/tsx/pack.eld")),
    (
        "typescript",
        include_str!("../../../../packs/typescript/pack.eld"),
    ),
    ("yaml", include_str!("../../../../packs/yaml/pack.eld")),
    ("zig", include_str!("../../../../packs/zig/pack.eld")),
];

/// Every built-in manifest, read once, by name. An unreadable shipped manifest is a bug (a test reads each).
pub fn manifests() -> &'static [Manifest] {
    static ALL: OnceLock<Vec<Manifest>> = OnceLock::new();
    ALL.get_or_init(|| {
        SOURCES
            .iter()
            .map(|(name, text)| {
                read(text.as_bytes()).unwrap_or_else(|e| panic!("the {name} pack: {e}"))
            })
            .collect()
    })
}

/// The built-in manifest named NAME.
pub fn get(name: &str) -> Option<&'static Manifest> {
    manifests().iter().find(|m| m.pack == name)
}
