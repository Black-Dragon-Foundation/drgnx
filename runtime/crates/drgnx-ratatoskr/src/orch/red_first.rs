//! The red-first gate's inputs (`docs/develop/orchestration.md`, "Red first"): a task's commits base..tip read from
//! git; `orch::gates` adds the evidence and the job's rule pack, the decision is `vordr::redfirst`'s.

use std::path::Path;
use std::process::Command;

use serde_json::{Map, Value};
use vordr::pack::Pack;
use vordr::redfirst::{self, Inputs};

fn git(repo: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .map_err(|e| format!("git {}: {e}", args.join(" ")))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

fn diff(repo: &Path, from: &str, to: &str) -> Result<Vec<redfirst::FileDiff>, String> {
    let text = git(
        repo,
        &[
            "diff",
            "-U0",
            "--no-color",
            "--no-renames",
            "--no-ext-diff",
            from,
            to,
        ],
    )?;
    Ok(redfirst::parse_diff(&text))
}

/// The gate's inputs for the commits BASE..TIP of REPO under PACK, with the task's approved BODY (blocking: git).
pub fn inputs(
    repo: &Path,
    base: &str,
    tip: &str,
    pack: &Pack,
    body: &str,
) -> Result<Inputs, String> {
    let range = format!("{base}..{tip}");
    let commits: Vec<String> = git(repo, &["rev-list", "--reverse", &range])?
        .lines()
        .map(str::to_owned)
        .collect();
    let tree =
        |c: &str| git(repo, &["rev-parse", &format!("{c}^{{tree}}")]).map(|s| s.trim().to_owned());
    let mut i = Inputs {
        commits: commits.len(),
        red_none: redfirst::red_none(body),
        ..Inputs::default()
    };
    let Some(test) = commits.first() else {
        return Ok(i);
    };
    i.test_commit = test.clone();
    i.test_key = tree(test)?;
    i.tip_key = tree(tip)?;
    // the test commit's test lines, then those the tip deleted
    let mut tests: Vec<(String, String)> = Vec::new();
    for f in diff(repo, base, test)? {
        let text = if f.path.ends_with(".rs") && !pack.is_test_path(&f.path) {
            git(repo, &["show", &format!("{test}:{}", f.path)]).unwrap_or_default()
        } else {
            String::new()
        };
        for l in redfirst::test_lines(pack, &f.path, &text, &f.added) {
            tests.push((f.path.clone(), l));
        }
    }
    i.weakened = redfirst::weakened(&tests, &diff(repo, test, tip)?);
    // the symbols the task's non-test change adds (a Rust file's inline tests are test lines)
    for f in diff(repo, base, tip)? {
        if pack.is_test_path(&f.path) {
            continue;
        }
        let text = if f.path.ends_with(".rs") {
            git(repo, &["show", &format!("{tip}:{}", f.path)]).unwrap_or_default()
        } else {
            String::new()
        };
        let in_tests = redfirst::test_lines(pack, &f.path, &text, &f.added);
        let lines: Vec<String> = f
            .added
            .into_iter()
            .map(|(_, l)| l)
            .filter(|l| !in_tests.contains(l))
            .collect();
        for s in redfirst::added_symbols(&f.path, &lines) {
            if !i.added_symbols.contains(&s) {
                i.added_symbols.push(s);
            }
        }
    }
    Ok(i)
}

/// Task N's body in the job's DATA (as the user approved it).
pub(crate) fn body_of(data: &Map<String, Value>, n: i64) -> String {
    data.get("tasks")
        .and_then(Value::as_array)
        .and_then(|a| {
            a.iter()
                .find(|t| t.get("n").and_then(Value::as_i64) == Some(n))
        })
        .and_then(|t| t.get("body").and_then(Value::as_str))
        .unwrap_or("")
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sh(dir: &Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .args([
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "-c",
                "commit.gpgsign=false",
            ])
            .args(args)
            .current_dir(dir)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    fn commit(dir: &Path, file: &str, text: &str) -> String {
        let p = dir.join(file);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
        sh(dir, &["add", "-A"]);
        sh(dir, &["commit", "-q", "-m", file]);
        sh(dir, &["rev-parse", "HEAD"])
    }

    const BASE: &str = "pub fn a() {}\n";
    const TESTS: &str = "pub fn a() {}\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn t() {\n        assert!(super::b());\n    }\n}\n";
    const DONE: &str = "pub fn a() {}\npub fn b() -> bool {\n    true\n}\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn t() {\n        assert!(super::b());\n    }\n}\n";

    fn repo() -> (tempfile::TempDir, String) {
        let d = tempfile::tempdir().unwrap();
        sh(d.path(), &["init", "-q", "-b", "main"]);
        let base = commit(d.path(), "src/a.rs", BASE);
        (d, base)
    }

    #[test]
    fn an_inline_test_commit_then_the_change() {
        let (d, base) = repo();
        let test = commit(d.path(), "src/a.rs", TESTS);
        let tip = commit(d.path(), "src/a.rs", DONE);
        let pack = crate::orch::policy::default_pack();
        let i = inputs(d.path(), &base, &tip, &pack, "Body.").unwrap();
        assert_eq!(i.commits, 2);
        assert_eq!(
            i.test_key,
            sh(d.path(), &["rev-parse", &format!("{test}^{{tree}}")])
        );
        assert_eq!(i.tip_key, sh(d.path(), &["rev-parse", "HEAD^{tree}"]));
        assert_eq!(
            i.added_symbols,
            vec!["b"],
            "the inline tests' own items aren't the change's"
        );
        assert!(i.weakened.is_empty(), "{:?}", i.weakened);
        assert_eq!(i.red_none, None);
    }

    #[test]
    fn a_weakened_test_and_red_none() {
        let (d, base) = repo();
        commit(d.path(), "src/a.rs", TESTS);
        commit(d.path(), "src/a.rs", DONE);
        let tip = commit(
            d.path(),
            "src/a.rs",
            &DONE.replace("assert!(super::b())", "assert!(true)"),
        );
        let pack = crate::orch::policy::default_pack();
        let i = inputs(d.path(), &base, &tip, &pack, "**Red:** none (a refactor)").unwrap();
        assert_eq!(i.weakened, vec!["src/a.rs:         assert!(super::b());"]);
        assert_eq!(i.red_none.as_deref(), Some("a refactor"));
        // no commits
        let i = inputs(d.path(), &tip, &tip, &pack, "").unwrap();
        assert_eq!(i.commits, 0);
    }

    #[test]
    fn the_approved_body_is_read_by_task_number() {
        let data: Map<String, Value> = serde_json::from_value(serde_json::json!({
            "tasks": [{"n": 1, "body": "a"}, {"n": 2, "body": "**Red:** none (docs)"}]
        }))
        .unwrap();
        assert_eq!(body_of(&data, 2), "**Red:** none (docs)");
        assert_eq!(body_of(&data, 3), "");
    }
}
