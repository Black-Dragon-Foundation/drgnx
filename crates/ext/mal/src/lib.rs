//! mal (*mál*, speech, language): the WIT package `drgnx:api` (docs/develop/standards/api-versioning.md).
//!
//! The file is `drgnx.wit` beside `src/`. The xtask's `wit-check` fails when it changes without the version bump the
//! change needs. The hosts (sattr) are generated from it by mal-gen; nothing binds a function of it by hand.

/// The WIT source.
pub const WIT: &str = include_str!("../drgnx.wit");

/// The package line, as the file spells it.
pub const PACKAGE: &str = "drgnx:api@0.1.0";
