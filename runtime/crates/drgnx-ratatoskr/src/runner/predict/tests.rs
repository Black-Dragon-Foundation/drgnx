use super::*;
use crate::runner::clash::{FileDiff, Rule, RunTask, scan};
use skuld::{Bound, Core, Mode, Partial, every_order};

// ---- every order ----

#[derive(Clone, Debug)]
enum Ev {
    /// A's edit to PATH closed at AT; the check finds CONFLICTS against B.
    Check {
        a: &'static str,
        b: &'static str,
        path: &'static str,
        conflicts: usize,
        at: f64,
    },
}

skuld::events!(Ev { Check });

/// The predictor's pure part as the shell drives it for sessions outside a run.
#[derive(Default)]
struct Shell {
    gate: Gate,
    predictions: Predictions,
    carded: BTreeSet<String>,
    cards: Vec<String>,
}

impl Core for Shell {
    type Event = Ev;
    fn step(&mut self, ev: Ev) -> Vec<Ev> {
        let Ev::Check {
            a,
            b,
            path,
            conflicts,
            at,
        } = ev;
        if !self.gate.due(a, b, path, at) {
            return vec![];
        }
        self.predictions.put(Prediction {
            a: a.into(),
            b: b.into(),
            path: path.into(),
            conflicts,
        });
        let set: BTreeSet<&str> = [a, b].into();
        let run = outside_run(
            (a, None),
            (b, None),
            self.predictions.among(&set),
            &self.carded,
        );
        for c in scan(&run, &[], &DiffIndex::new()) {
            self.carded.insert(c.key.clone());
            self.cards.push(c.key);
        }
        vec![]
    }
}

/// [A] Two sessions conflicting in two files, each side's edits closing in any order, and a third session whose
/// change merges cleanly: one card, for the conflicting pair.
#[test]
fn every_order_one_card_per_pair() {
    let check = |a, b, path, conflicts, at| Ev::Check {
        a,
        b,
        path,
        conflicts,
        at,
    };
    let mut p = Partial::new();
    p.source(
        "a",
        vec![
            check("s1", "s2", "x.rs", 1, 0.0),
            check("s1", "s2", "y.rs", 2, 1.0),
        ],
    );
    p.source(
        "b",
        vec![
            check("s2", "s1", "x.rs", 1, 0.5),
            check("s2", "s1", "x.rs", 1, 45.0),
        ],
    );
    p.source("c", vec![check("s1", "s3", "x.rs", 0, 2.0)]);
    let r = every_order(&p, Bound::default(), Shell::default, |s, order| {
        if s.cards != ["conflict:s1:s2"] {
            return Err(format!("{order:?}: cards {:?}", s.cards));
        }
        Ok(())
    });
    assert_eq!(r.mode, Mode::Exhaustive);
    assert!(r.orders > 20, "{} orders", r.orders);
}

/// [D] The gate: once per (A, B, path) per 30 s of the hub's clock, each direction and file on its own.
#[test]
fn the_gate_checks_once_per_30_s() {
    let mut g = Gate::default();
    assert!(g.due("a", "b", "x", 0.0));
    assert!(!g.due("a", "b", "x", 29.9));
    assert!(g.due("b", "a", "x", 1.0));
    assert!(g.due("a", "b", "y", 1.0));
    assert!(g.due("a", "b", "x", 30.0));
}

// ---- a clean merge ----

fn lines(n: usize, change: Option<(usize, &str)>) -> String {
    (1..=n)
        .map(|i| match change {
            Some((at, text)) if at == i => format!("{text}\n"),
            _ => format!("line {i}\n"),
        })
        .collect()
}

/// [D] Two changes to one file far apart merge cleanly: no conflict card, and the two tasks' changes to that file are
/// no overlap either (without the prediction they are).  Changes to the same lines are one conflict card.
#[test]
fn a_clean_same_file_merge_is_no_clash() {
    let base = lines(20, None);
    let (a, b) = (lines(20, Some((1, "a's"))), lines(20, Some((20, "b's"))));
    assert_eq!(check(&base, &a, &b).unwrap(), 0);
    let both = lines(20, Some((1, "b's")));
    assert_eq!(check(&base, &a, &both).unwrap(), 1);

    let task = |id: &str, n| RunTask {
        id: id.into(),
        n,
        status: "in-review".into(),
        agent: None,
        head: None,
    };
    let session = |id: &str, t: &str| RunSession {
        id: id.into(),
        task: Some(t.into()),
        exited: false,
        held: 0,
        held_by_user: false,
    };
    let mut diffs = DiffIndex::new();
    for t in ["t1", "t2"] {
        diffs.entry(t.into()).or_default().insert(
            "x.rs".into(),
            FileDiff {
                hash: t.into(),
                ranges: vec![(1, 2)],
            },
        );
    }
    let mut run = RunState {
        status: "running".into(),
        tasks: vec![task("t1", 1), task("t2", 2)],
        sessions: vec![session("s1", "t1"), session("s2", "t2")],
        ..Default::default()
    };
    let rules = |run: &RunState| -> Vec<Rule> {
        scan(run, &[], &diffs).into_iter().map(|c| c.rule).collect()
    };
    assert_eq!(rules(&run), [Rule::Overlap]);
    run.predictions = vec![Prediction {
        a: "s2".into(),
        b: "s1".into(),
        path: "x.rs".into(),
        conflicts: 0,
    }];
    assert_eq!(rules(&run), []);
    run.predictions[0].conflicts = 1;
    let found = scan(&run, &[], &diffs);
    let conflict: Vec<_> = found.iter().filter(|c| c.rule == Rule::Conflict).collect();
    assert_eq!(conflict.len(), 1, "{found:?}");
    assert_eq!(conflict[0].key, "conflict:s1:s2");
    assert_eq!(conflict[0].files, ["x.rs"]);
    // an exited session's predictions card nothing
    run.sessions[1].exited = true;
    assert!(
        scan(&run, &[], &diffs)
            .iter()
            .all(|c| c.rule != Rule::Conflict)
    );
}

// ---- the texts ----

fn sh(dir: &Path, script: &str) {
    let ok = std::process::Command::new("sh")
        .args(["-c", script])
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .status()
        .unwrap()
        .success();
    assert!(ok, "{script}");
}

/// [D] Neither side committed anything: the texts are the files in the two trees, read against their merge base, and
/// they conflict.  A tree that left the file as it was is no prediction.
#[test]
fn uncommitted_work_counts() {
    let d = tempfile::tempdir().unwrap();
    let (main, wt) = (d.path().join("main"), d.path().join("wt"));
    std::fs::create_dir_all(&main).unwrap();
    sh(
        &main,
        "git init -q -b main && echo one > x.rs && git add x.rs && \
         git -c user.name=t -c user.email=t@t commit -q -m init && git worktree add -q -b b ../wt",
    );
    let head = String::from_utf8(
        std::process::Command::new("git")
            .args(["rev-parse", "HEAD"])
            .current_dir(&main)
            .output()
            .unwrap()
            .stdout,
    )
    .unwrap()
    .trim()
    .to_owned();
    assert_eq!(
        texts(&main, (&main, &head), (&wt, &head), "x.rs"),
        None,
        "neither changed it"
    );
    std::fs::write(main.join("x.rs"), "from a\n").unwrap();
    assert_eq!(
        texts(&main, (&main, &head), (&wt, &head), "x.rs"),
        None,
        "b did not change it"
    );
    std::fs::write(wt.join("x.rs"), "from b\n").unwrap();
    let (base, a, b) = texts(&main, (&main, &head), (&wt, &head), "x.rs").unwrap();
    assert_eq!(
        (base.as_str(), a.as_str(), b.as_str()),
        ("one\n", "from a\n", "from b\n")
    );
    assert_eq!(check(&base, &a, &b).unwrap(), 1);
    assert_eq!(
        crate::work::presence::main_checkout(&wt.join("x.rs")),
        std::fs::canonicalize(&main).ok()
    );
}
