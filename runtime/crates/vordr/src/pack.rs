//! A rule pack: a project's gate rules and their parameters, read (as Emacs Lisp data) from the pack the plan names
//! and frozen with the job at its approval (`docs/develop/orchestration.md`, "The rule pack").

use serde::{Deserialize, Serialize};

/// The gates' policy files: read from the line's base, never from the tip, and a tip that changes one asks the user
/// at its merge (`code.ci-config`).
pub const POLICY_PATHS: &[&str] = &["test/affected.eld", "test/frozen.eld", "test/flaky.eld"];

/// The rules a pack may name.
pub const RULE_IDS: &[&str] = &[
    "red-first",
    "author-check",
    "trailers",
    "rule-tests",
    "affected-groups",
    "merge-notes",
    "flake-hold",
    "push-gate",
    "review",
];

/// The kinds of a rule: `enforced` and `checked` gate the merge, `routing` and `advice` don't.
pub const RULE_KINDS: &[&str] = &["enforced", "checked", "routing", "advice"];

/// One rule.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Rule {
    /// One of [`RULE_IDS`].
    pub id: String,
    /// One of [`RULE_KINDS`].
    pub kind: String,
    /// What it asks, for the Rules tab and the brief.
    pub doc: String,
}

/// A command a gate runs through the queue (an author check, a rule test, a push tier).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Check {
    pub name: String,
    /// The folder it runs in, relative to the tree's top (empty: the top).
    pub dir: String,
    pub run: Vec<String>,
}

/// A rule pack.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Pack {
    pub name: String,
    pub version: i64,
    pub rules: Vec<Rule>,
    /// The paths of test files (`*` matches across `/`); a Rust file's `#[cfg(test)]` part is a test hunk too.
    pub test_globs: Vec<String>,
    /// The languages whose compile-fail reds count when they name a symbol the task adds (`rust`, `elisp`).
    pub compile_fail_reds: Vec<String>,
    /// The tips a merge batch takes at most.
    pub batch_size: i64,
    /// The compile steps of the author check (with the task's own tests and the rule tests).
    pub author_check: Vec<Check>,
    /// The repo-wide rule tests.
    pub rule_tests: Vec<Check>,
    /// The tiers one full run before a push runs.
    pub push_tiers: Vec<Check>,
    /// The command that lists the groups a range affects, run in the base's tree; `%r` is the range.
    pub groups: Vec<String>,
    /// Words that mark a selector never served from the cache (clock-, network- or machine-dependent).
    pub no_cache: Vec<String>,
    /// Paths whose clean merges still need structured intent notes (registries, settings, migrations, key profiles).
    pub shared_paths: Vec<String>,
    /// Tokens past which a workflow task's agent is rotated.
    pub context_share: i64,
}

impl Pack {
    /// Whether rule ID gates the merge (`enforced` or `checked`).
    pub fn on(&self, id: &str) -> bool {
        self.rules
            .iter()
            .any(|r| r.id == id && matches!(r.kind.as_str(), "enforced" | "checked"))
    }

    /// The batch size, at least 1.
    pub fn batch(&self) -> usize {
        usize::try_from(self.batch_size.max(1)).unwrap_or(1)
    }

    pub fn is_test_path(&self, path: &str) -> bool {
        self.test_globs.iter().any(|g| glob_match(g, path))
    }

    pub fn is_shared(&self, path: &str) -> bool {
        self.shared_paths.iter().any(|g| glob_match(g, path))
    }

    /// Whether a `build` red counts for LANG (`rust`, `elisp`).
    pub fn build_reds(&self, lang: &str) -> bool {
        self.compile_fail_reds.iter().any(|l| l == lang)
    }

    /// What is wrong with the pack, each said once; empty when it can be used.
    pub fn problems(&self) -> Vec<String> {
        let mut out = Vec::new();
        if self.name.is_empty() {
            out.push("the pack has no :name".to_string());
        }
        for r in &self.rules {
            if !RULE_IDS.contains(&r.id.as_str()) {
                out.push(format!(
                    "unknown rule {} (one of {})",
                    r.id,
                    RULE_IDS.join(", ")
                ));
            }
            if !RULE_KINDS.contains(&r.kind.as_str()) {
                out.push(format!("rule {}: unknown kind {:?}", r.id, r.kind));
            }
        }
        for c in self
            .author_check
            .iter()
            .chain(&self.rule_tests)
            .chain(&self.push_tiers)
        {
            if c.run.is_empty() {
                out.push(format!("check {} runs nothing", c.name));
            }
        }
        if self.on("push-gate") && self.push_tiers.is_empty() {
            out.push("the push gate is on but the pack names no :push-tiers".to_string());
        }
        out
    }
}

/// Whether GLOB matches PATH: `*` (and `**`) matches any run of characters, `/` included, as `test/affected.eld`'s
/// rows do; anything else matches itself.
pub fn glob_match(glob: &str, path: &str) -> bool {
    let parts: Vec<&str> = glob.split('*').collect();
    if parts.len() == 1 {
        return glob == path;
    }
    let (first, last) = (parts[0], parts[parts.len() - 1]);
    if !path.starts_with(first) || path.len() < first.len() + last.len() || !path.ends_with(last) {
        return false;
    }
    let mut rest = &path[first.len()..path.len() - last.len()];
    for mid in &parts[1..parts.len() - 1] {
        match rest.find(mid) {
            Some(at) => rest = &rest[at + mid.len()..],
            None => return false,
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn globs() {
        assert!(glob_match("test/*", "test/unit/a-test.el"));
        assert!(glob_match("**/tests/*", "runtime/crates/x/tests/y.rs"));
        assert!(glob_match("*_test.rs", "src/a_test.rs"));
        assert!(glob_match("test/affected.eld", "test/affected.eld"));
        assert!(!glob_match("test/*", "src/test/a"));
        assert!(!glob_match("a*b*c", "abx"));
        assert!(glob_match("a*b*c", "a-b-c"));
    }

    #[test]
    fn rules_and_problems() {
        let p = Pack {
            name: "p".into(),
            rules: vec![
                Rule {
                    id: "red-first".into(),
                    kind: "enforced".into(),
                    doc: String::new(),
                },
                Rule {
                    id: "review".into(),
                    kind: "advice".into(),
                    doc: String::new(),
                },
            ],
            compile_fail_reds: vec!["rust".into()],
            ..Pack::default()
        };
        assert!(p.on("red-first") && !p.on("review") && !p.on("push-gate"));
        assert!(p.build_reds("rust") && !p.build_reds("elisp"));
        assert_eq!(p.batch(), 1);
        assert!(p.problems().is_empty());
        let bad = Pack {
            rules: vec![Rule {
                id: "nope".into(),
                kind: "maybe".into(),
                doc: String::new(),
            }],
            ..Pack::default()
        };
        assert_eq!(bad.problems().len(), 3);
    }
}
