//! The affected groups before a batch merges (`docs/develop/orchestration.md`, "Affected groups"): git's and the
//! queue's side of `vordr::groups`.
//!
//! The batch's combined commit is the line's HEAD with each member's tip merged in order (`git merge-tree` and
//! `git commit-tree`: no worktree, no ref).  The pack's groups command runs in a detached worktree of the line's HEAD
//! (the base's own tool and `test/affected.eld`) over HEAD..combined; each group it names runs at the combined commit
//! through the queue as the user's job, its end recorded as evidence of the batch (`batch:JOB@TREE`).

use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

use vordr::batch::Ready;
use vordr::groups::{Outcome, command, judge, parse};
use vordr::pack::{Check, Pack};

use crate::front::Front;
use crate::orch::gates::{git, run_of, start};

/// The groups each combined tree needs, by tree key (the command runs once per tree).
#[derive(Default)]
pub struct Listed {
    by_tree: Mutex<HashMap<String, Vec<Check>>>,
}

/// What the groups say about a batch.
#[derive(Debug, PartialEq, Eq)]
pub enum Gate {
    Pass,
    Wait(String),
    /// Held, with the tree key a waiver would name.
    Hold(String, String),
    /// These tasks go back to their agents, with these words.
    Back(Vec<(String, String)>),
}

/// The combined commit of BATCH on DIR's HEAD and its tree: (head, commit, tree).  Blocking.
pub fn combined(dir: &Path, batch: &[Ready]) -> Result<(String, String, String), String> {
    let head = git(dir, &["rev-parse", "HEAD"])?.trim().to_owned();
    let mut prev = head.clone();
    for m in batch {
        let tree = git(dir, &["merge-tree", "--write-tree", &prev, &m.tip])
            .map_err(|e| format!("the batch's members don't merge: {e}"))?;
        let tree = tree.lines().next().unwrap_or("").trim().to_owned();
        prev = git(
            dir,
            &[
                "-c",
                "user.name=drgnx",
                "-c",
                "user.email=drgnx@localhost",
                "commit-tree",
                &tree,
                "-p",
                &prev,
                "-p",
                &m.tip,
                "-m",
                &format!("batch: {}", m.task),
            ],
        )?
        .trim()
        .to_owned();
    }
    let tree = git(dir, &["rev-parse", &format!("{prev}^{{tree}}")])?
        .trim()
        .to_owned();
    Ok((head, prev, tree))
}

/// The groups the line's own tool names for HEAD..COMMIT: TEMPLATE run in a detached worktree of HEAD beside DIR.
/// Blocking.
fn list(dir: &Path, template: &[String], head: &str, commit: &str) -> Result<Vec<Check>, String> {
    let argv = command(template, &format!("{head}..{commit}"));
    let Some((prog, args)) = argv.split_first() else {
        return Ok(Vec::new());
    };
    let wt = dir.with_file_name(format!(
        "{}.groups-{}",
        dir.file_name().and_then(|n| n.to_str()).unwrap_or("line"),
        &commit[..commit.len().min(12)]
    ));
    let w = wt.to_string_lossy().into_owned();
    git(dir, &["worktree", "add", "-q", "--detach", &w, head])?;
    let out = std::process::Command::new(wt.join(prog))
        .args(args)
        .current_dir(&wt)
        .output();
    let _ = git(dir, &["worktree", "remove", "--force", &w]);
    let out = out.map_err(|e| format!("{}: {e}", argv.join(" ")))?;
    if !out.status.success() {
        return Err(format!(
            "{}: {}",
            argv.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    parse(&String::from_utf8_lossy(&out.stdout))
}

/// The groups gate of JOB's BATCH (in the job's tree DIR, HEAD its line) under PACK: pass when the pack runs no
/// groups, or every group is green at the combined tree (a failing row the base's `test/frozen.eld` lists is
/// tolerated), or the user waived it at that tree; otherwise the missing groups start and it waits, or a red holds.
pub async fn gate(
    front: &Front,
    job: &str,
    dir: &Path,
    pack: &Pack,
    batch: &[Ready],
) -> Result<Gate, String> {
    if pack.groups.is_empty() || !pack.on("affected-groups") || batch.is_empty() {
        return Ok(Gate::Pass);
    }
    let (d, b) = (dir.to_owned(), batch.to_vec());
    let (head, commit, tree) = crate::clock::blocking(move || combined(&d, &b))
        .await
        .map_err(|e| e.to_string())??;
    let cached = front.groups.by_tree.lock().unwrap().get(&tree).cloned();
    let groups = match cached {
        Some(g) => g,
        None => {
            let (d, t, h, c) = (
                dir.to_owned(),
                pack.groups.clone(),
                head.clone(),
                commit.clone(),
            );
            let g = crate::clock::blocking(move || list(&d, &t, &h, &c))
                .await
                .map_err(|e| e.to_string())??;
            front
                .groups
                .by_tree
                .lock()
                .unwrap()
                .insert(tree.clone(), g.clone());
            g
        }
    };
    let key = format!("batch:{job}@{tree}");
    let (k, members) = (
        key.clone(),
        batch.iter().map(|m| m.task.clone()).collect::<Vec<_>>(),
    );
    let (evidence, waivers) = front
        .writer
        .db
        .read(move |c| {
            let mut w = Vec::new();
            for t in &members {
                w.extend(norn::read::evidence::of_task(c, t)?);
            }
            Ok((norn::read::evidence::of_task(c, &k)?, w))
        })
        .await
        .map_err(|e| e.to_string())?;
    if let Some(why) = vordr::gates::waived(&waivers, &tree) {
        tracing::info!("batch {key}: waived by the user: {why}");
        return Ok(Gate::Pass);
    }
    // a row that failed, then passed on the same tree holds the batch: flakes are fixed at the cause
    let flakes = vordr::gates::flake_holds(pack, &evidence);
    if !flakes.is_empty() {
        let why = format!("flaky rows in the batch's groups: {}", flakes.join(", "));
        follow(
            front,
            &why,
            serde_json::json!({"job": job, "tree": tree, "rows": flakes}),
        )
        .await;
        return Ok(Gate::Hold(format!("{why} (a followup is open)"), tree));
    }
    let policy = crate::orch::policy::Policy::at(dir, &head, pack).await?;
    let known = |row: &str| {
        policy
            .frozen
            .iter()
            .any(|f| f.tests.iter().any(|t| t == row))
    };
    match judge(&groups, &evidence, &tree, known) {
        Outcome::Green => Ok(Gate::Pass),
        Outcome::Red(reds) => {
            let red: Vec<Check> = groups
                .iter()
                .filter(|g| reds.iter().any(|(n, _)| *n == g.name))
                .cloned()
                .collect();
            reruns(front, job, dir, &head, batch, &red, &tree, &known).await
        }
        Outcome::Missing(missing) => {
            for g in &missing {
                start(front, &key, dir, &commit, &tree, &run_of(g)).await?;
            }
            let names: Vec<&str> = missing.iter().map(|g| g.name.as_str()).collect();
            Ok(Gate::Wait(format!(
                "the batch's groups run: {}",
                names.join(", ")
            )))
        }
    }
}

/// A followup TITLE (with DATA) the gates leave, one open per title (`norn::write::evidence::followup`).
pub(crate) async fn follow(front: &Front, title: &str, data: serde_json::Value) {
    let (t, tx) = (
        title.to_owned(),
        urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "orch/followup"),
    );
    let r = front
        .writer
        .db
        .write(tx, move |tx| {
            norn::write::evidence::followup(tx, &t, data, None)
        })
        .await;
    match r {
        Ok(_) => front.writer.signals.wrote(),
        Err(e) => tracing::warn!("a gate's followup was not recorded: {e}"),
    }
}

/// The batch's RED groups run again at the line's HEAD and at each member's tip merged alone onto it (in parallel,
/// one round: `vordr::reruns`).  Rows red at the line hold it (a followup); tips red alone go back; every tip green
/// alone, the later one goes back (an interaction red).  KNOWN rows (frozen) never count.
#[allow(clippy::too_many_arguments)]
async fn reruns(
    front: &Front,
    job: &str,
    dir: &Path,
    head: &str,
    batch: &[Ready],
    red: &[Check],
    tree: &str,
    known: &(dyn Fn(&str) -> bool + Sync),
) -> Result<Gate, String> {
    use vordr::gates::{State, selector_of, state};
    use vordr::reruns::{Verdict, verdict};
    // (task, commit, tree): the line's first ("" its task), then each tip alone
    let (d, h, b) = (dir.to_owned(), head.to_owned(), batch.to_vec());
    let runs: Vec<(String, String, String)> = crate::clock::blocking(move || {
        let line = git(&d, &["rev-parse", &format!("{h}^{{tree}}")])?
            .trim()
            .to_owned();
        let mut out = vec![(String::new(), h.clone(), line)];
        for m in &b {
            let (_, c, t) = combined(&d, std::slice::from_ref(m))?;
            out.push((m.task.clone(), c, t));
        }
        Ok::<_, String>(out)
    })
    .await
    .map_err(|e| e.to_string())??;
    let keys: Vec<String> = runs
        .iter()
        .map(|(_, _, t)| format!("batch:{job}@{t}"))
        .collect();
    let k2 = keys.clone();
    let evidence = front
        .writer
        .db
        .read(move |c| {
            k2.iter()
                .map(|k| norn::read::evidence::of_task(c, k))
                .collect::<Result<Vec<_>, _>>()
        })
        .await
        .map_err(|e| e.to_string())?;
    let mut rows: Vec<Option<Vec<String>>> = Vec::new();
    for (i, (_, commit, t)) in runs.iter().enumerate() {
        let mut failed: Option<Vec<String>> = Some(Vec::new());
        for g in red {
            match state(&evidence[i], t, &selector_of(g)) {
                State::Green => {}
                State::Red(r) => {
                    if let Some(f) = failed.as_mut() {
                        f.extend(r.into_iter().filter(|x| !known(x)));
                    }
                }
                State::Missing => {
                    start(front, &keys[i], dir, commit, t, &run_of(g)).await?;
                    failed = None;
                }
            }
        }
        rows.push(failed);
    }
    let tips: Vec<(String, Option<Vec<String>>)> = runs[1..]
        .iter()
        .zip(&rows[1..])
        .map(|((task, _, _), r)| (task.clone(), r.clone()))
        .collect();
    let names: Vec<&str> = red.iter().map(|g| g.name.as_str()).collect();
    Ok(match verdict(rows[0].as_deref(), &tips) {
        Verdict::Wait(p) => Gate::Wait(format!(
            "the batch's red groups ({}) run again at {}",
            names.join(", "),
            p.join(", ")
        )),
        Verdict::Line(r) => {
            let why = format!("job/{job} itself fails {}: {}", names.join(", "), r.join(", "));
            follow(front, &why, serde_json::json!({"job": job, "head": head, "rows": r})).await;
            Gate::Hold(format!("{why} (a followup is open)"), tree.to_owned())
        }
        Verdict::Culprits(c) => Gate::Back(
            c.into_iter()
                .map(|(t, r)| {
                    let note = format!(
                        "The affected groups {} fail with your tip alone on job/{job}: {}. Fix them, commit, then \
                         call complete_task.",
                        names.join(", "),
                        r.join(", ")
                    );
                    (t, note)
                })
                .collect(),
        ),
        Verdict::Interaction { back, tips } => {
            let others: Vec<&str> = tips.iter().map(String::as_str).filter(|t| *t != back).collect();
            let note = format!(
                "Your tip and {} each pass the affected groups {} alone on job/{job}, but fail together. Once they \
                 merged, merge job/{job} into your branch, make both work, commit, then call complete_task.",
                others.join(", "),
                names.join(", ")
            );
            Gate::Back(vec![(back, note)])
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

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
        assert!(out.status.success(), "{args:?}");
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    fn commit(dir: &Path, file: &str, text: &str) -> String {
        std::fs::write(dir.join(file), text).unwrap();
        sh(dir, &["add", "-A"]);
        sh(dir, &["commit", "-q", "-m", file]);
        sh(dir, &["rev-parse", "HEAD"])
    }

    #[test]
    fn the_combined_commit_is_the_line_with_each_tip_merged_and_moves_no_ref() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path();
        sh(p, &["init", "-q", "-b", "line"]);
        commit(p, "base", "b\n");
        sh(p, &["checkout", "-q", "-b", "t1"]);
        let a = commit(p, "a", "a\n");
        sh(p, &["checkout", "-q", "line"]);
        sh(p, &["checkout", "-q", "-b", "t2"]);
        let b = commit(p, "b", "b\n");
        sh(p, &["checkout", "-q", "line"]);
        let head = sh(p, &["rev-parse", "HEAD"]);
        let r = |task: &str, tip: &str| Ready {
            task: task.into(),
            tip: tip.into(),
            at: 0.0,
        };
        let (h, c, tree) = combined(p, &[r("t1", &a), r("t2", &b)]).unwrap();
        assert_eq!(h, head);
        assert_eq!(sh(p, &["rev-parse", "HEAD"]), head, "no ref moved");
        assert_eq!(sh(p, &["ls-tree", "--name-only", &c]), "a\nb\nbase");
        assert_eq!(sh(p, &["rev-parse", &format!("{c}^{{tree}}")]), tree);
        // the same members in the other order: the same tree, so the same groups' runs count
        assert_eq!(combined(p, &[r("t2", &b), r("t1", &a)]).unwrap().2, tree);
    }

    /// Three tips, the reruns' commits (the line, each tip alone on it) and a stand-in group that fails a tree with
    /// `broken` in it, or with both `x` and `y` (two tips that only fail together): the culprit, then the later tip.
    #[test]
    fn three_tips_rerun_alone_name_the_culprit_or_the_later_of_an_interaction() {
        use vordr::reruns::{Verdict, verdict};
        let d = tempfile::tempdir().unwrap();
        let p = d.path();
        sh(p, &["init", "-q", "-b", "line"]);
        commit(p, "base", "b\n");
        let tip = |name: &str, file: &str| {
            sh(p, &["checkout", "-q", "-b", name, "line"]);
            let c = commit(p, file, "1\n");
            sh(p, &["checkout", "-q", "line"]);
            Ready {
                task: name.into(),
                tip: c,
                at: 0.0,
            }
        };
        let group = |commit: &str| -> Vec<String> {
            let files = sh(p, &["ls-tree", "--name-only", commit]);
            let has = |f: &str| files.lines().any(|l| l == f);
            if has("broken") || (has("x") && has("y")) {
                vec!["g::t".into()]
            } else {
                vec![]
            }
        };
        let rerun = |batch: &[Ready]| {
            let (head, all, _) = combined(p, batch).unwrap();
            assert_eq!(group(&all), vec!["g::t".to_string()], "the batch is red");
            let tips: Vec<(String, Option<Vec<String>>)> = batch
                .iter()
                .map(|m| {
                    let (_, c, _) = combined(p, std::slice::from_ref(m)).unwrap();
                    (m.task.clone(), Some(group(&c)))
                })
                .collect();
            verdict(Some(&group(&head)), &tips)
        };
        let (a, b, c) = (tip("a", "a"), tip("b", "broken"), tip("c", "c"));
        assert_eq!(
            rerun(&[a, b, c]),
            Verdict::Culprits(vec![("b".into(), vec!["g::t".into()])])
        );
        let (x, m, y) = (tip("x", "x"), tip("m", "m"), tip("y", "y"));
        assert_eq!(
            rerun(&[x, m, y]),
            Verdict::Interaction {
                back: "y".into(),
                tips: vec!["x".into(), "m".into(), "y".into()]
            }
        );
    }
}
