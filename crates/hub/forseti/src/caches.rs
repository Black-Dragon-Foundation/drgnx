//! Named caches (docs/develop/forseti.md, "Caches"): what a job's cache declares, how much disk it may keep, and how it
//! is shared. Pure: the pack's cache entry, resolved by the hub, reaches the runner as a [`CacheSpec`] in the job's
//! [`crate::Derived`]; `sleipnir::sync::cache` turns it into folders and mounts.
//!
//! - **Budget.** A cache's `budget-gib` is its register budget. A cache of kind `compiler` (the project's, or a
//!   preset's: a compiler's object cache) that sets none gets [`crate::disk::COMPILER_CACHE_GB`]. The tool's variable
//!   comes from the preset or the project file, never from product code.
//! - **Sharing.** `shared`: every job of the project at that trust and role, at once. `locked`: one job at a time
//!   (the others wait as `state`, holding nothing). `private`: an empty folder per job.
//! - **Roles.** A gate's cache is its own partition. An author's job writes its own partition and may read the gate's,
//!   read-only, through the cache's `readonly-env` (never the other way: a gate never reads what an author wrote).

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::disk::COMPILER_CACHE_GB;

/// How a cache is shared between jobs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Sharing {
    /// Every job at once (a package store, a compiler's object cache).
    #[default]
    Shared,
    /// One job at a time; the others wait as `state`, holding nothing.
    Locked,
    /// An empty folder per job.
    Private,
}

impl Sharing {
    /// The pack's word.
    pub fn parse(s: &str) -> Option<Sharing> {
        Some(match s {
            "shared" => Sharing::Shared,
            "locked" => Sharing::Locked,
            "private" => Sharing::Private,
            _ => return None,
        })
    }
}

/// One cache a job uses, resolved: where it appears in the container, its kind, sharing and budget, and the variables
/// that point the tool at it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CacheSpec {
    pub name: String,
    /// Its path inside the container (an absolute path of its own).
    pub inside: String,
    /// `compiler`, `packages` or `other`.
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub sharing: Sharing,
    /// The cache's own budget, GiB; none: the kind's default ([`CacheSpec::budget_gib`]).
    #[serde(default)]
    pub budget_gib: Option<u64>,
    /// Set in the job: the variables that point the tool at the cache (`{cache:NAME}` already expanded to `inside`).
    #[serde(default)]
    pub env: Vec<(String, String)>,
    /// Set in an author's job beside `env`: the variables that point the tool at the gate's partition, read-only.
    #[serde(default)]
    pub readonly_env: Vec<(String, String)>,
}

impl CacheSpec {
    /// The cache's budget, GiB: its own, else [`COMPILER_CACHE_GB`] for a compiler cache, else none (only age and the
    /// floor decide).
    pub fn budget_gib(&self) -> Option<u64> {
        self.budget_gib
            .or((self.kind.as_deref() == Some("compiler")).then_some(COMPILER_CACHE_GB))
    }

    /// The register budget in bytes (a gigabyte as §4.8 counts it: 2^30).
    pub fn budget_bytes(&self) -> Option<u64> {
        self.budget_gib().map(|g| g << 30)
    }
}

/// The paths a job holds exclusively for its `locked` caches: the hub puts them in the job's `state`, so a second job
/// naming one waits as `state` holding nothing.
pub fn locked_state(project: &str, role: crate::Role, caches: &[CacheSpec]) -> Vec<PathBuf> {
    caches
        .iter()
        .filter(|c| c.sharing == Sharing::Locked)
        .map(|c| PathBuf::from(format!("cache/{project}/{}/{}", role.name(), c.name)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Role;

    fn cache(name: &str, kind: Option<&str>, gib: Option<u64>, sharing: Sharing) -> CacheSpec {
        CacheSpec {
            name: name.into(),
            inside: format!("/{name}"),
            kind: kind.map(String::from),
            sharing,
            budget_gib: gib,
            env: vec![],
            readonly_env: vec![],
        }
    }

    #[test]
    fn the_compiler_cache_defaults_to_15_gb() {
        let c = cache("objects", Some("compiler"), None, Sharing::Shared);
        assert_eq!(c.budget_gib(), Some(15));
        assert_eq!(c.budget_bytes(), Some(15 << 30));
        // its own budget wins, and another kind has none unless it sets one
        assert_eq!(
            cache("o", Some("compiler"), Some(4), Sharing::Shared).budget_gib(),
            Some(4)
        );
        assert_eq!(
            cache("p", Some("packages"), None, Sharing::Shared).budget_gib(),
            None
        );
        assert_eq!(
            cache("q", None, Some(2), Sharing::Shared).budget_gib(),
            Some(2)
        );
    }

    #[test]
    fn only_a_locked_cache_holds_state() {
        let cs = [
            cache("a", None, None, Sharing::Shared),
            cache("b", None, None, Sharing::Locked),
            cache("c", None, None, Sharing::Private),
        ];
        assert_eq!(
            locked_state("p", Role::Gate, &cs),
            [PathBuf::from("cache/p/gate/b")]
        );
        // the author's partition is another path: the two never wait on each other
        assert_ne!(
            locked_state("p", Role::Author, &cs),
            locked_state("p", Role::Gate, &cs)
        );
    }

    #[test]
    fn sharing_words_round_trip() {
        for (w, s) in [
            ("shared", Sharing::Shared),
            ("locked", Sharing::Locked),
            ("private", Sharing::Private),
        ] {
            assert_eq!(Sharing::parse(w), Some(s));
            assert_eq!(serde_json::to_string(&s).unwrap(), format!("\"{w}\""));
        }
        assert_eq!(Sharing::parse("exclusive"), None);
    }
}
