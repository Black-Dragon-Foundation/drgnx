//! What a job ran on, as the hub recorded it at its start: the tree key, the env stamp, the platform and the
//! selector.  Evidence counts for a gate only when all four match (`docs/develop/orchestration.md`, "Facts").

use serde::{Deserialize, Serialize};

/// A job's facts.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Facts {
    /// The commit's tree id; with uncommitted work, `TREE+OVERLAY` (the input key's first 16 hex digits).
    pub tree_key: String,
    /// The toolchain and Emacs build the job ran with, one line each.
    pub env_stamp: String,
    /// `OS-ARCH/MACHINE` (`linux-x86_64/local`, `macos-aarch64/mac-mini`).
    pub platform: String,
    /// What it ran: [`selector`].
    pub selector: String,
}

/// The tree key of a tree TREE with an overlay whose input key is OVERLAY (none: a clean tree).
pub fn tree_key(tree: &str, overlay: Option<&str>) -> String {
    match overlay {
        Some(k) => format!("{tree}+{}", &k[..k.len().min(16)]),
        None => tree.to_string(),
    }
}

/// A job's selector: the folder it ran in relative to its tree's top (`.` for the top), its command, and the test
/// selector variables it was given (`DRGNX_TEST_SELECTOR`, `DRGNX_TEST_ONLY`), one per line.
pub fn selector(rel_cwd: &str, argv: &[String], env: &[(String, String)]) -> String {
    let mut out = format!(
        "{}\n{}",
        if rel_cwd.is_empty() { "." } else { rel_cwd },
        argv.join(" ")
    );
    for name in SELECTOR_VARS {
        if let Some((_, v)) = env.iter().find(|(k, _)| k == name) {
            out.push_str(&format!("\n{name}={v}"));
        }
    }
    out
}

/// The test selector variables SELECTOR names for the command ARGV run in REL_CWD (as [`selector`] wrote them), or
/// none when SELECTOR isn't that command's.
pub fn selector_env(selector_text: &str, rel_cwd: &str, argv: &[String]) -> Vec<(String, String)> {
    let head = selector(rel_cwd, argv, &[]);
    let Some(rest) = selector_text.strip_prefix(&head) else {
        return Vec::new();
    };
    let env: Vec<(String, String)> = rest
        .split('\n')
        .skip(1)
        .filter_map(|l| l.split_once('='))
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect();
    if selector(rel_cwd, argv, &env) == selector_text {
        env
    } else {
        Vec::new()
    }
}

/// The variables that narrow what a test command runs.
pub const SELECTOR_VARS: &[&str] = &["DRGNX_TEST_SELECTOR", "DRGNX_TEST_ONLY"];

/// Whether a group with SELECTOR may be served from the cache: none of NO_CACHE (the pack's `no-cache` words, each
/// matched as a substring of the selector) names it.
pub fn cacheable(selector: &str, no_cache: &[String]) -> bool {
    !no_cache
        .iter()
        .any(|w| !w.is_empty() && selector.contains(w.as_str()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A rerun of a job carries the test selector variables its selector names, so the rerun's selector is the
    /// job's (its evidence lands where the gate looks).
    #[test]
    fn a_selectors_variables_are_read_back() {
        let argv = vec!["sh".to_string(), "-c".to_string(), "a\nb".to_string()];
        let env = vec![
            ("DRGNX_TEST_SELECTOR".to_string(), "^a/\\|^b/".to_string()),
            ("DRGNX_TEST_ONLY".to_string(), "x".to_string()),
        ];
        let s = selector("sub", &argv, &env);
        assert_eq!(selector_env(&s, "sub", &argv), env);
        assert!(selector_env(&selector("", &argv, &[]), "", &argv).is_empty());
        // a selector that isn't this command's: none
        assert!(selector_env(&s, "sub", &argv[..2]).is_empty());
    }

    #[test]
    fn keys_and_selectors() {
        assert_eq!(tree_key("abc", None), "abc");
        assert_eq!(
            tree_key("abc", Some("0123456789abcdef0123")),
            "abc+0123456789abcdef"
        );
        let argv = vec!["cargo".to_string(), "test".to_string()];
        let env = vec![
            ("X".to_string(), "1".to_string()),
            ("DRGNX_TEST_SELECTOR".to_string(), "^a/".to_string()),
        ];
        assert_eq!(selector("", &argv, &[]), ".\ncargo test");
        assert_eq!(
            selector("runtime", &argv, &env),
            "runtime\ncargo test\nDRGNX_TEST_SELECTOR=^a/"
        );
        assert!(cacheable("x\ncargo test", &["perf".into(), String::new()]));
        assert!(!cacheable("x\nbin/drgnx test --perf", &["perf".into()]));
    }
}
