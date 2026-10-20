//! A child's environment: only allowlisted names are copied from the hub's environment, then `set` is applied.
//! [`crate::spawn`] clears the child's environment and gives it exactly this list.

use std::ffi::{OsStr, OsString};

/// The environment for a child: every variable of this process named in `allow` or starting with one of
/// `allow_prefixes` (an empty prefix matches nothing), then each `set` pair, which replaces a copied value.
pub fn build(
    allow: &[&str],
    allow_prefixes: &[&str],
    set: &[(&str, &OsStr)],
) -> Vec<(OsString, OsString)> {
    build_from(std::env::vars_os(), allow, allow_prefixes, set)
}

fn build_from(
    source: impl IntoIterator<Item = (OsString, OsString)>,
    allow: &[&str],
    allow_prefixes: &[&str],
    set: &[(&str, &OsStr)],
) -> Vec<(OsString, OsString)> {
    let allowed = |name: &OsStr| {
        name.to_str().is_some_and(|n| {
            allow.contains(&n)
                || allow_prefixes
                    .iter()
                    .any(|p| !p.is_empty() && n.starts_with(p))
        })
    };
    let mut env: Vec<(OsString, OsString)> =
        source.into_iter().filter(|(k, _)| allowed(k)).collect();
    for (name, value) in set {
        env.retain(|(k, _)| k != name);
        env.push((name.into(), value.into()));
    }
    env
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spawn::{Spec, spawn};
    use tokio::io::AsyncReadExt;

    #[tokio::test]
    async fn a_key_canary_never_reaches_the_child() {
        let parent = std::env::vars_os().chain([
            ("OPENROUTER_API_KEY".into(), "canary".into()),
            ("DRGNX_PROC_TEST_KEEP".into(), "kept".into()),
        ]);
        let env = build_from(
            parent,
            &["PATH", "DRGNX_PROC_TEST_KEEP"],
            &["LC_", ""],
            &[("DRGNX_PROC_TEST_SET", OsStr::new("set"))],
        );
        assert!(env.iter().all(|(k, _)| k != "OPENROUTER_API_KEY"));
        let mut child = spawn(Spec {
            program: "/usr/bin/env".into(),
            args: vec![],
            env: env.clone(),
            cwd: None,
            stdin_null: true,
        })
        .await
        .unwrap();
        let mut out = String::new();
        child
            .take_stdout()
            .unwrap()
            .read_to_string(&mut out)
            .await
            .unwrap();
        assert!(child.wait().await.unwrap().unwrap().success());
        assert!(!out.contains("canary"), "{out}");
        assert!(
            out.lines().any(|l| l == "DRGNX_PROC_TEST_KEEP=kept"),
            "{out}"
        );
        assert!(out.lines().any(|l| l == "DRGNX_PROC_TEST_SET=set"), "{out}");
        // The child has exactly the built list: spawn cleared the rest of this process's environment.
        let mut names: Vec<&str> = out
            .lines()
            .filter_map(|l| l.split_once('=').map(|(k, _)| k))
            .collect();
        let mut want: Vec<&str> = env.iter().map(|(k, _)| k.to_str().unwrap()).collect();
        names.sort_unstable();
        want.sort_unstable();
        assert_eq!(names, want);
    }
}
