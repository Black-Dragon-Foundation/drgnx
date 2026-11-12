//! The bisect's states as trees: commits, and the edit history's records written over a base commit, in a shadow
//! repository that borrows the project's objects; and a slot's folder moved between them by delta.

use super::bisect::{Candidate, Stage};
use super::bisect_wire::{Make, Pending, commits, materialise, stage_repo};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env_remove("GIT_DIR")
        .env_remove("GIT_INDEX_FILE")
        .args(["-c", "user.name=Tess", "-c", "user.email=t@example.invalid"])
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

fn commit(dir: &Path, files: &[(&str, &str)], msg: &str, at: u64) -> String {
    for (p, t) in files {
        std::fs::write(dir.join(p), t).unwrap();
    }
    git(dir, &["add", "-A"]);
    let date = format!("@{at} +0000");
    let out = Command::new("git")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_AUTHOR_DATE", &date)
        .env("GIT_COMMITTER_DATE", &date)
        .args([
            "-c",
            "user.name=Tess",
            "-c",
            "user.email=t@example.invalid",
            "commit",
            "-q",
            "-m",
            msg,
        ])
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(out.status.success());
    git(dir, &["rev-parse", "HEAD"])
}

fn cand(id: &str) -> Candidate {
    Candidate {
        id: id.into(),
        kind: "save".into(),
        at: 0.0,
        label: id.into(),
        author: None,
        session: None,
        step: None,
        decision: None,
        record: None,
        tree: String::new(),
    }
}

#[test]
fn commits_and_records_become_trees_a_slot_runs() {
    let tmp = tempfile::tempdir().unwrap();
    let proj = tmp.path().join("proj");
    std::fs::create_dir_all(&proj).unwrap();
    git(&proj, &["init", "-q", "-b", "main"]);
    std::fs::write(proj.join("run.sh"), "exit 0\n").unwrap();
    std::fs::set_permissions(proj.join("run.sh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let c1 = commit(&proj, &[("a.py", "x = 1\n")], "first", 1_000);
    let c2 = commit(&proj, &[("a.py", "x = 2\n")], "second", 2_000);
    let _c3 = commit(&proj, &[("b.py", "y = 1\n")], "add b", 3_000);
    let gd = proj.join(".git");

    // the commits after the good one, oldest first, with their subjects and authors
    let after = commits(&gd, Some(&c1), 0.0).unwrap();
    let labels: Vec<&str> = after.iter().map(|p| p.cand.label.as_str()).collect();
    assert_eq!(labels, vec!["second", "add b"]);
    assert_eq!(after[0].cand.id, format!("commit-{}", &c2[..12]));
    assert_eq!(after[0].cand.at, 2_000.0);
    assert_eq!(after[0].cand.author.as_ref().unwrap()["name"], "Tess");
    // with no good commit: those after a time
    assert_eq!(commits(&gd, None, 1_500.0).unwrap().len(), 2);

    // a save written over the first commit; a state equal to the one before it is dropped
    let work = tmp.path().join("work");
    let source = work.join("stage");
    let repo = stage_repo(&work, &source, &[gd.join("objects")]).unwrap();
    let c1_tree = git(&proj, &["rev-parse", &format!("{c1}^{{tree}}")]);
    let mut pending = vec![
        Pending {
            cand: cand("good"),
            make: Make::Tree(c1_tree.clone()),
        },
        Pending {
            cand: cand("save"),
            make: Make::Texts {
                base: Some(c1.clone()),
                texts: vec![
                    ("a.py".into(), "x = 9\n".into()),
                    ("lib/new.py".into(), "n = 1\n".into()),
                ],
            },
        },
    ];
    pending.extend(after);
    pending.push(Pending {
        cand: cand("same"),
        make: Make::Tree(
            pending
                .last()
                .map(|p| match &p.make {
                    Make::Tree(t) => t.clone(),
                    Make::Texts { .. } => unreachable!(),
                })
                .unwrap(),
        ),
    });
    let states = materialise(&repo, pending).unwrap();
    let ids: Vec<&str> = states.iter().map(|c| c.id.as_str()).collect();
    assert_eq!(ids.len(), 4, "{ids:?}");
    assert_eq!(ids[1], "save");
    assert!(!ids.contains(&"same"));

    // one slot, moved from state to state
    let stage = Stage::new(work.clone(), source, work.clone());
    let slot = stage.restore(0, &states[1].tree).unwrap();
    assert_eq!(
        std::fs::read_to_string(slot.join("a.py")).unwrap(),
        "x = 9\n"
    );
    assert_eq!(
        std::fs::read_to_string(slot.join("lib/new.py")).unwrap(),
        "n = 1\n"
    );
    assert!(!slot.join("b.py").exists());
    let mode = std::fs::metadata(slot.join("run.sh"))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o111, 0o111, "the base's modes are kept");
    let slot = stage.restore(0, &states[3].tree).unwrap();
    assert_eq!(
        std::fs::read_to_string(slot.join("a.py")).unwrap(),
        "x = 2\n"
    );
    assert_eq!(
        std::fs::read_to_string(slot.join("b.py")).unwrap(),
        "y = 1\n"
    );
    assert!(!slot.join("lib/new.py").exists(), "nothing stale stays");

    // the hunks between two states, and a tree with some of them
    let hunks = stage.hunks(&states[0].tree, &states[3].tree).unwrap();
    let paths: Vec<&str> = hunks.iter().map(|h| h.path.as_str()).collect();
    assert_eq!(paths, vec!["a.py", "b.py"]);
    let only_b = stage.with_hunks(&states[0].tree, &[&hunks[1]]).unwrap();
    let slot = stage.restore(1, &only_b).unwrap();
    assert_eq!(
        std::fs::read_to_string(slot.join("a.py")).unwrap(),
        "x = 1\n"
    );
    assert_eq!(
        std::fs::read_to_string(slot.join("b.py")).unwrap(),
        "y = 1\n"
    );
    stage.drop_slots();
    assert!(!work.join("slot-0").exists() && !work.join("slot-1").exists());
}

/// The card from the events as they come: the estimate and dots while it runs, then the result with who made the first
/// bad state, its step and decision, and the actions it offers.
#[test]
fn the_card_follows_the_events() {
    use super::bisect_card::{merge, rows};
    use serde_json::json;
    let text = |s: &serde_json::Value| {
        rows(s)
            .iter()
            .map(|r| r.text.clone())
            .collect::<Vec<_>>()
            .join("\n")
    };
    let mut s = serde_json::Value::Null;
    merge(
        &mut s,
        &json!({"bisect": "b1", "state": "checking-good", "dots": [],
                          "estimate": {"runs": 6, "slots": 3, "states": 9}}),
    );
    let t = text(&s);
    assert!(
        t.starts_with("Bisect · 9 states · about 6 runs in 3 slots · checking the good state"),
        "{t}"
    );
    assert!(t.contains("Cancel"));
    merge(
        &mut s,
        &json!({"state": "running", "dots": [
        {"i": 0, "id": "good", "outcome": "good"}, {"i": 1, "id": "s1", "outcome": "skip"},
        {"i": 2, "id": "s2", "outcome": ""}, {"i": 3, "id": "now", "outcome": "bad"}]}),
    );
    assert!(text(&s).contains("● ◌ · ✕"), "{}", text(&s));
    merge(
        &mut s,
        &json!({"state": "found", "dots": [
        {"i": 0, "id": "good", "outcome": "good"}, {"i": 1, "id": "s1", "outcome": "skip"},
        {"i": 2, "id": "s2", "outcome": "bad"}, {"i": 3, "id": "now", "outcome": "bad"}],
        "result": {"first_bad": {"id": "s2", "kind": "agent_step", "label": "Tighten the stock check",
                                 "author": {"agent": "claude"}, "step": "7", "decision": "dec-3", "session": "S1"},
                   "skipped": ["s1"], "flaky": [], "runs": 5}}),
    );
    let t = text(&s);
    assert!(
        t.contains("First bad: Tighten the stock check · claude"),
        "{t}"
    );
    assert!(t.contains("step 7 · decision dec-3 · agent step"), "{t}");
    assert!(t.contains("Or one of the 1 state before it"), "{t}");
    assert!(!t.contains("Cancel"));
    let acts = rows(&s).into_iter().find(|r| r.key == "actions").unwrap();
    let names: Vec<String> = acts
        .props
        .iter()
        .filter(|p| p.2 == "drgnx-debug-bisect-action")
        .map(|p| p.3.as_str().unwrap().to_owned())
        .collect();
    assert_eq!(names, vec!["show", "revert", "ask", "narrow"]);
    // the first bad dot is ringed
    let dots = rows(&s).into_iter().find(|r| r.key == "dots").unwrap();
    assert!(
        dots.runs
            .iter()
            .any(|r| r.2 == "drgnx-debug-timeline-current")
    );
    // a user's save: no revert or ask; narrowing's result
    let mut u = s.clone();
    u["result"]["first_bad"] =
        json!({"id": "r9", "kind": "save", "label": "a save", "author": {"user": 1}});
    merge(
        &mut u,
        &json!({"state": "narrowed", "hunks": [{"path": "a.py", "hunk": "@@ -1 +1 @@\n-x = 1\n+x = 2\n"}], "of": 4}),
    );
    let t = text(&u);
    assert!(t.contains("First bad: a save · you"), "{t}");
    assert!(
        t.contains("It fails with 1 hunk of the 4:\n  a.py  -x = 1"),
        "{t}"
    );
    assert!(!t.contains("Revert Step") && !t.contains("Narrow"), "{t}");
    // the good state fails too
    let mut g = serde_json::Value::Null;
    merge(
        &mut g,
        &json!({"state": "needs-good", "why": "the good state fails too", "estimate": {"runs": 4, "slots": 1, "states": 3}}),
    );
    assert!(text(&g).contains("the good state fails too: pick an earlier good state"));
}
