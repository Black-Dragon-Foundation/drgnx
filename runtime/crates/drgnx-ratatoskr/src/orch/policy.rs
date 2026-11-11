//! Base-side policy (`docs/develop/orchestration.md`, "Policy from the base"): the rule pack a job was approved with,
//! and the policy files (`vordr::pack::POLICY_PATHS`) read at the line's base commit, never at the tip, so a tip
//! can't change the rules it is judged by.  A tip that edits a policy file asks the user at its merge
//! (`runner::git`, `code.ci-config`).

use std::path::Path;

use huginn::read::{Limits, read_all};
use huginn::value::{Datum, Node};
use vordr::pack::Pack;

/// The pack drgnx ships: the one a plan run meets unless its plan names another (`**Pack:** FILE`).
pub const DEFAULT_PACK: &str = include_str!("../../../../../etc/orch/drgnx-default.eld");

/// One row of `test/frozen.eld`: a test file and its tests switched off.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Frozen {
    pub file: String,
    pub tests: Vec<String>,
}

/// The policy a gate reads for one line.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Policy {
    pub pack: Pack,
    /// `test/frozen.eld`'s rows: known reds a gate doesn't count.
    pub frozen: Vec<Frozen>,
    /// `test/flaky.eld`'s test names.
    pub flaky: Vec<String>,
}

impl Policy {
    /// The policy at commit REV of REPO, with PACK (the job's, frozen at its approval).  A policy file REV doesn't
    /// have reads as empty; one that doesn't read is an error.
    pub async fn at(repo: &Path, rev: &str, pack: &Pack) -> Result<Policy, String> {
        let (repo, rev) = (repo.to_owned(), rev.to_owned());
        let (frozen, flaky) = crate::clock::blocking(move || {
            Ok::<_, String>((
                show(&repo, &rev, "test/frozen.eld")?,
                show(&repo, &rev, "test/flaky.eld")?,
            ))
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(Policy {
            pack: pack.clone(),
            frozen: frozen_rows(&frozen)?,
            flaky: heads(&flaky)?,
        })
    }
}

/// FILE at REV in REPO; empty when REV has no such file.
fn show(repo: &Path, rev: &str, file: &str) -> Result<String, String> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["show", &format!("{rev}:{file}")])
        .output()
        .map_err(|e| format!("git show {rev}:{file}: {e}"))?;
    if out.status.success() {
        return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
    }
    // a missing path is "no rows"; a missing revision is an error
    let has_rev = std::process::Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["cat-file", "-e", &format!("{rev}^{{commit}}")])
        .status()
        .map_err(|e| format!("git cat-file {rev}: {e}"))?;
    if has_rev.success() {
        Ok(String::new())
    } else {
        Err(format!("no commit {rev} in {}", repo.display()))
    }
}

/// TEXT's one top-level list (a policy file), as its items.
fn top(text: &str) -> Result<Vec<Node>, String> {
    let nodes = read_all(text.as_bytes(), Limits::default()).map_err(|r| r.to_string())?;
    match nodes.into_iter().next().map(|n| n.datum) {
        None => Ok(Vec::new()),
        Some(Datum::List(items)) => Ok(items),
        Some(Datum::Sym(s)) if s == "nil" => Ok(Vec::new()),
        Some(_) => Err("a policy file is one list".into()),
    }
}

fn text(n: &Node) -> Option<&str> {
    match &n.datum {
        Datum::Sym(s) | Datum::Str(s) => Some(s),
        _ => None,
    }
}

/// Each row's head (a row is `(NAME :key value …)`).
fn heads(text_: &str) -> Result<Vec<String>, String> {
    Ok(top(text_)?
        .iter()
        .filter_map(|row| match &row.datum {
            Datum::List(items) => items.first().and_then(text).map(str::to_owned),
            _ => None,
        })
        .collect())
}

/// `test/frozen.eld`'s rows: `(FILE … :tests (NAME …) …)`.
fn frozen_rows(text_: &str) -> Result<Vec<Frozen>, String> {
    let mut out = Vec::new();
    for row in top(text_)? {
        let Datum::List(items) = &row.datum else {
            continue;
        };
        let Some(file) = items.first().and_then(text) else {
            continue;
        };
        let mut tests = Vec::new();
        for pair in items[1..].chunks(2) {
            if let [k, v] = pair
                && text(k) == Some(":tests")
                && let Datum::List(names) = &v.datum
            {
                tests.extend(names.iter().filter_map(text).map(str::to_owned));
            }
        }
        out.push(Frozen {
            file: file.to_owned(),
            tests,
        });
    }
    Ok(out)
}

/// TEXT (a pack file) as a pack; refused when it doesn't read or names what the hub doesn't know.
pub fn read_pack(text_: &str) -> Result<Pack, String> {
    let nodes = read_all(text_.as_bytes(), Limits::default()).map_err(|r| r.to_string())?;
    let node = nodes.first().ok_or("the pack file is empty")?;
    let pack: Pack = huginn::de::from_node(node).map_err(|e| e.to_string())?;
    let problems = pack.problems();
    if problems.is_empty() {
        Ok(pack)
    } else {
        Err(problems.join("; "))
    }
}

/// The pack drgnx ships.
pub fn default_pack() -> Pack {
    read_pack(DEFAULT_PACK).expect("etc/orch/drgnx-default.eld reads (orch::policy::tests)")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shipped_pack_reads() {
        let p = default_pack();
        assert_eq!(p.name, "drgnx-default");
        // red first, the author check, affected groups and the push gate; a project's own pack adds the rest
        assert!(
            p.on("red-first")
                && p.on("author-check")
                && p.on("affected-groups")
                && p.on("push-gate")
        );
        assert!(!p.on("merge-notes") && !p.on("trailers"));
        assert!(p.build_reds("rust") && p.build_reds("elisp"));
        assert_eq!(p.batch(), 3);
        assert!(p.is_test_path("runtime/crates/x/src/a/tests.rs"));
        // any project's: no project's commands (the author check is the task's own tests)
        assert!(p.author_check.is_empty() && p.rule_tests.is_empty() && p.push_tiers.is_empty());
        assert!(p.groups.is_empty() && p.shared_paths.is_empty());
        assert!(read_pack("(:name \"x\" :rules ((:id \"nope\" :kind \"enforced\")))").is_err());
    }

    #[test]
    fn frozen_and_flaky_rows_read() {
        let f = frozen_rows(
            ";; c\n((\"a.el\" :by \"p\" :tests (x y) :keep (z)) (\"b.el\" :tests (w)))\n",
        )
        .unwrap();
        assert_eq!(
            f,
            vec![
                Frozen {
                    file: "a.el".into(),
                    tests: vec!["x".into(), "y".into()]
                },
                Frozen {
                    file: "b.el".into(),
                    tests: vec!["w".into()]
                },
            ]
        );
        assert!(frozen_rows("()\n").unwrap().is_empty());
        assert_eq!(
            heads("((t1 :reason \"r\") (t2))").unwrap(),
            vec!["t1", "t2"]
        );
        // the line's own files read
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../test");
        for f in ["frozen.eld", "flaky.eld"] {
            top(&std::fs::read_to_string(root.join(f)).unwrap()).unwrap();
        }
    }
}
