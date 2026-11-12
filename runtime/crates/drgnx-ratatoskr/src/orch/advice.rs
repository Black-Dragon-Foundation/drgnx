//! Advice in the agent's loop (`docs/develop/orchestration.md`, "Advice before the gate"): a provider with a
//! `before-tool` hook gets a soft deny when a commit in its task's tree changes code before the task has any red
//! evidence, so it does not build work the merge will hold.  Advice saves wasted work; it is never the gate (the gate
//! at the merge is the same for every provider).

use std::path::Path;

use vordr::pack::Pack;

use crate::front::Front;
use crate::orch::gates::git;

/// Whether COMMAND (an `execute` step's) makes a commit.
pub fn is_commit(command: &str) -> bool {
    command.contains("git commit")
}

/// The advice on a commit of CHANGED paths under PACK, for a task with red evidence or not (HAS_RED): none when the
/// pack has no red-first rule, the task has a red, or only test paths change.
pub fn commit_advice(pack: &Pack, changed: &[String], has_red: bool) -> Option<String> {
    if has_red || !pack.on("red-first") {
        return None;
    }
    let code: Vec<&str> = changed
        .iter()
        .map(String::as_str)
        .filter(|p| !pack.is_test_path(p))
        .collect();
    if code.is_empty() {
        return None;
    }
    let mut named = code.iter().take(3).copied().collect::<Vec<_>>().join(", ");
    if code.len() > 3 {
        named.push_str(&format!(" and {} more", code.len() - 3));
    }
    Some(format!(
        "the merge will hold this: the task has no red yet and this commit changes code ({named}). Commit the \
         failing tests first and run your tests first, so the hub records the red; then commit the code."
    ))
}

/// The advice on CALL at SITE (the adapter's `before-tool` seam: our forks' `_drgnx/before_tool`, Codex's managed
/// hook) in the session's tree DIR: a commit of a job's task, judged by [`before_commit`]; anything else, none.
pub async fn at_seam(
    front: &Front,
    site: &crate::hook_points::Site,
    call: &crate::hook_points::ToolCallInfo,
    dir: &Path,
) -> Option<String> {
    if call.kind != "execute" {
        return None;
    }
    let (job, task, command) = (
        site.job.as_deref()?,
        site.task.as_deref()?,
        call.command.as_deref()?,
    );
    before_commit(front, job, task, dir, command).await
}

/// The advice on the commit COMMAND of JOB's TASK in the tree DIR, read from the store and the tree (none when it is
/// not a commit, the job has no pack, or anything cannot be read: advice never blocks on its own failure).
pub async fn before_commit(
    front: &Front,
    job: &str,
    task: &str,
    dir: &Path,
    command: &str,
) -> Option<String> {
    if !is_commit(command) {
        return None;
    }
    let (j, t) = (job.to_owned(), task.to_owned());
    let (pack, evidence) = front
        .writer
        .db
        .read(move |c| {
            Ok((
                norn::read::evidence::pack_of_job(c, &j)?,
                norn::read::evidence::of_task(c, &t)?,
            ))
        })
        .await
        .ok()?;
    let pack = pack?;
    let d = dir.to_owned();
    let changed = crate::clock::blocking(move || git(&d, &["diff", "--name-only", "HEAD"]))
        .await
        .ok()?
        .ok()?;
    let changed: Vec<String> = changed.lines().map(str::to_owned).collect();
    commit_advice(&pack, &changed, evidence.iter().any(|e| e.kind == "red"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use vordr::pack::Rule;

    fn pack(kind: &str) -> Pack {
        Pack {
            rules: vec![Rule {
                id: "red-first".into(),
                kind: kind.into(),
                doc: String::new(),
            }],
            test_globs: vec!["test/**".into(), "**/tests.rs".into()],
            ..Pack::default()
        }
    }

    fn paths(p: &[&str]) -> Vec<String> {
        p.iter().map(|s| (*s).to_owned()).collect()
    }

    /// [D] A commit that changes code before the task has a red is advised against, in words that say the merge will
    /// hold it and what to do; tests alone, a task with a red, or a pack without red first are let through.
    #[test]
    fn a_commit_of_code_before_a_red_is_advised_against() {
        let why = commit_advice(&pack("enforced"), &paths(&["src/a.rs", "test/a.el"]), false)
            .expect("advice");
        assert!(why.contains("the merge will hold this"), "{why}");
        assert!(
            why.contains("src/a.rs") && !why.contains("test/a.el"),
            "{why}"
        );
        assert!(why.contains("run your tests first"), "{why}");
        assert_eq!(
            commit_advice(
                &pack("enforced"),
                &paths(&["test/a.el", "x/tests.rs"]),
                false
            ),
            None
        );
        assert_eq!(
            commit_advice(&pack("enforced"), &paths(&["src/a.rs"]), true),
            None
        );
        assert_eq!(
            commit_advice(&pack("advice"), &paths(&["src/a.rs"]), false),
            None
        );
        assert_eq!(commit_advice(&pack("enforced"), &[], false), None);
        // many paths: a few named, the rest counted
        let many: Vec<String> = (0..9).map(|i| format!("src/{i}.rs")).collect();
        let why = commit_advice(&pack("checked"), &many, false).expect("advice");
        assert!(why.contains("and 6 more"), "{why}");
        assert!(is_commit("git commit -m x") && !is_commit("git status"));
    }
}
