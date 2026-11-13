//! skald: the language pack format (docs/develop/packs.md; design `language-packs-design.md` §3).
//!
//! A pack is a folder with one manifest, `pack.eld`, plus tree-sitter queries and fixtures. This crate reads the
//! manifest as data (huginn: nothing is evaluated; every unknown field is refused with its path), holds the reserved
//! names, and checks the rules a pack that is not built in must meet: the command rules, the claim rules, install
//! digests and the `highlights.scm` predicate subset. Fetching, building and loading grammars is the pack job's
//! (Task 2a), not this crate's.
//!
//! - `manifest`: the types and `read`.
//! - `reserved`: the names only built-in packs may use.
//! - `builtin`: the built-in packs' manifests, compiled in.
//! - `check`: the schema checks, the command rules and the claim rules.
//! - `highlights`: the `highlights.scm` predicate subset.
//! - `job`: the pack job's grammar half: fetch, hash, build, load check, query check, stage (Task 2a).
//! - `translate`: `highlights.scm` into the queries of Emacs's font-lock (the generic mode, Task 3g).
//! - `dir`: a pack folder, checked (`ratatoskr packs check`).

pub mod builtin;
pub mod check;
pub mod dir;
pub mod highlights;
pub mod job;
pub mod manifest;
pub mod reserved;
pub mod translate;

pub use check::{Claims, Problem, ProblemKind, Source, check};
pub use dir::{Report, check_dir};
pub use manifest::{Manifest, PackError, read};
