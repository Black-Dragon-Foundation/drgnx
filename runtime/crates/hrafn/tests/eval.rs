//! The shipped eval: the generator over a fixture repository's history, the metrics, and the non-inferiority gate.
//!
//! test-pattern: pure (D): git runs to its exit in a temporary repository, the store thread answers in order, and the
//! metrics and the bootstrap are functions of their inputs (the bootstrap's generator is seeded); no clock, no wait.

use hrafn::eval::{EvalRow, Report, compare, generate, judge, run};
use hrafn::{Answer, CodeStore, Config, GitCli, Hit, Lag, Query, refresh};
use std::path::Path;
use std::process::Command;

fn git(dir: &Path, day: u32, args: &[&str]) {
    let date = format!("2026-01-{day:02}T12:00:00+0000");
    let st = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .env("GIT_AUTHOR_DATE", &date)
        .env("GIT_COMMITTER_DATE", &date)
        .status()
        .unwrap();
    assert!(st.success(), "git {args:?}");
}

fn put(dir: &Path, path: &str, text: &str) {
    let f = dir.join(path);
    std::fs::create_dir_all(f.parent().unwrap()).unwrap();
    std::fs::write(f, text).unwrap();
}

fn defun(name: &str, body: &str) -> String {
    format!("(defun {name} (arg)\n  \"Docstring of {name}.\"\n  {body})\n\n")
}

/// Commits FILES under SUBJECT on DAY.
fn commit(dir: &Path, day: u32, subject: &str, files: &[(&str, String)]) {
    for (p, t) in files {
        put(dir, p, t);
    }
    git(dir, day, &["add", "-A"]);
    git(dir, day, &["commit", "-q", "-m", subject]);
}

/// The fixture's history; the subject of each commit says what the generator must do with it.
fn fixture() -> tempfile::TempDir {
    let t = tempfile::tempdir().unwrap();
    let d = t.path();
    git(d, 1, &["init", "-q"]);
    let timer =
        |a: &str, b: &str| format!("{}{}", defun("timer-fire", a), defun("timer-cancel", b));
    commit(
        d,
        1,
        "Add the timer and window files",
        &[
            ("core/timer.el", timer("(ignore arg)", "(ignore arg)")),
            ("core/window.el", defun("window-split", "(split arg 1)")),
            ("core/old.el", defun("old-helper", "(old arg)")),
            (
                "tests/timer-test.el",
                "(ert-deftest timer-fire-empty ()\n  (should (timer-fire nil)))\n".into(),
            ),
        ],
    );
    commit(
        d,
        2,
        "Run the timer when its time is due",
        &[("core/timer.el", timer("(run-due arg)", "(ignore arg)"))],
    );
    commit(
        d,
        3,
        "Fix timer-fire crash on an empty queue",
        &[("core/timer.el", timer("(run-due arg t)", "(ignore arg)"))],
    );
    commit(
        d,
        4,
        "ABC-123: split windows side by side",
        &[("core/window.el", defun("window-split", "(split arg 2)"))],
    );
    commit(
        d,
        5,
        "Drop the cancel helper",
        &[("core/timer.el", defun("timer-fire", "(run-due arg t)"))],
    );
    commit(
        d,
        6,
        "Tune the old helper for slow disks",
        &[("core/old.el", defun("old-helper", "(old arg 2)"))],
    );
    git(d, 7, &["rm", "-q", "core/old.el"]);
    git(d, 7, &["commit", "-q", "-m", "Remove the retired file"]);
    git(d, 8, &["mv", "core/window.el", "core/win.el"]);
    git(d, 8, &["commit", "-q", "-m", "Rename the window file"]);
    commit(
        d,
        9,
        "Shrink the gap between split windows",
        &[("core/win.el", defun("window-split", "(split arg 3)"))],
    );
    commit(
        d,
        10,
        "Cover the empty queue case",
        &[(
            "tests/timer-test.el",
            "(ert-deftest timer-fire-empty ()\n  (should (null (timer-fire nil))))\n".into(),
        )],
    );
    commit(
        d,
        11,
        "Share one queue between the timer and the window code",
        &[
            ("core/timer.el", defun("timer-fire", "(run-due arg 1)")),
            ("core/win.el", defun("window-split", "(split arg 4)")),
        ],
    );
    t
}

/// A store holding the fixture at HEAD (tier 1 only).
async fn indexed(root: &Path) -> (CodeStore, tempfile::TempDir) {
    let db = tempfile::tempdir().unwrap();
    let store = CodeStore::open(&db.path().join("code.db")).unwrap();
    let listed = hrafn::list(root, &GitCli, &Config::default(), &|_| true).unwrap();
    let root = root.to_path_buf();
    refresh(&store, &listed, &move |p| std::fs::read(root.join(p)), &[])
        .await
        .unwrap();
    (store, db)
}

/// Pattern D. A subject that names an identifier is dropped, a ticket id is stripped from the others, and the queries
/// are the subjects that remain.
#[tokio::test]
async fn gen_drops_identifier_subjects() {
    let repo = fixture();
    let (store, _db) = indexed(repo.path()).await;
    let rows = generate(repo.path(), &GitCli, &store).await.unwrap();
    let mut queries: Vec<&str> = rows.iter().map(|r| r.query.as_str()).collect();
    queries.sort();
    assert_eq!(
        queries,
        [
            "Cover the empty queue case",
            "Run the timer when its time is due",
            "Share one queue between the timer and the window code",
            "Shrink the gap between split windows",
            "split windows side by side",
        ],
        "{rows:#?}"
    );
    assert!(rows.iter().all(|r| !r.query.contains("timer-fire")));
    assert!(rows.iter().all(|r| !r.query.contains("ABC")));
}

/// Pattern D. Targets are the forms around the hunks, found again at HEAD by name (a renamed file follows its
/// functions), and a form that is gone drops its commit.
#[tokio::test]
async fn gen_maps_targets_through_symbols() {
    let repo = fixture();
    let (store, _db) = indexed(repo.path()).await;
    let rows = generate(repo.path(), &GitCli, &store).await.unwrap();
    let row = |q: &str| {
        rows.iter()
            .find(|r| r.query == q)
            .unwrap_or_else(|| panic!("{q}: {rows:#?}"))
    };
    let t = |p: &str, s: &str| (p.to_string(), s.to_string());
    assert_eq!(
        row("split windows side by side").targets,
        [t("core/win.el", "window-split")]
    );
    assert_eq!(
        row("Shrink the gap between split windows").targets,
        [t("core/win.el", "window-split")]
    );
    assert_eq!(
        row("Run the timer when its time is due").targets,
        [t("core/timer.el", "timer-fire")]
    );
    assert_eq!(row("Cover the empty queue case").stratum, "tests");
    let both = row("Share one queue between the timer and the window code");
    assert_eq!(both.stratum, "cross-file");
    assert_eq!(both.targets.len(), 2);
    assert_eq!(row("Run the timer when its time is due").stratum, "symbol");
    // the old helper's commits and the cancel helper's removal leave no row
    assert!(
        rows.iter()
            .all(|r| !r.query.contains("old helper") && !r.query.contains("cancel"))
    );
    // ages count back from HEAD's day; the halves split the rows by commit id
    assert_eq!(row("Run the timer when its time is due").age_days, 9);
    assert!(rows.iter().all(|r| r.half == "dev" || r.half == "test"));
    assert!(rows.iter().all(|r| r.dir == "core" || r.dir == "tests"));
}

fn hit(path: &str, symbol: &str) -> Hit {
    Hit {
        path: path.into(),
        line_start: 1,
        line_end: 2,
        symbol: Some(symbol.into()),
        score: 1.0,
        preview: String::new(),
        routes: vec!["keyword"],
        reanchored: false,
    }
}

fn answer(hits: Vec<Hit>) -> Answer {
    Answer {
        hits,
        lag: Lag::default(),
        model: None,
        notice: None,
    }
}

/// Pattern D. Reciprocal rank, nDCG@10 and file-level recall on hand-worked cases, and a bootstrap interval that is
/// the value itself when every row agrees.
#[test]
fn metrics_known_values() {
    let t = |p: &str, s: &str| (p.to_string(), s.to_string());
    let hits = vec![hit("x.el", "x"), hit("y.el", "y"), hit("a.el", "f")];
    let j = judge(&[t("a.el", "f")], &hits);
    assert!((j.rr - 1.0 / 3.0).abs() < 1e-12);
    assert!((j.ndcg - 0.5).abs() < 1e-12, "1 / log2(3 + 1)");
    assert!(j.file_at5 == 1.0 && j.file_at10 == 1.0);
    // two targets in two files: one at rank 1, one at rank 7
    let mut hits: Vec<Hit> = (0..6).map(|i| hit("z.el", &format!("z{i}"))).collect();
    hits.insert(0, hit("a.el", "f"));
    hits.push(hit("b.el", "g"));
    let j = judge(&[t("a.el", "f"), t("b.el", "g")], &hits);
    assert_eq!(j.rr, 1.0);
    assert!((j.file_at5 - 0.5).abs() < 1e-12 && j.file_at10 == 1.0);
    let ideal = 1.0 + 1.0 / 3f64.log2();
    let got = 1.0 + 1.0 / 9f64.log2();
    assert!((j.ndcg - got / ideal).abs() < 1e-12);
    // a miss, and a target past rank 10
    let hits: Vec<Hit> = (0..12).map(|i| hit("z.el", &format!("z{i}"))).collect();
    let j = judge(&[t("a.el", "f")], &hits);
    assert_eq!(
        (j.rr, j.ndcg, j.file_at5, j.file_at10),
        (0.0, 0.0, 0.0, 0.0)
    );
    // a target with no symbol is any chunk of its file
    let j = judge(&[t("cfg.toml", "")], &[hit("cfg.toml", "x")]);
    assert_eq!(j.rr, 1.0);

    let rows = rows_of(&[("symbol", 50)]);
    let r = run(&rows, &|_q: &Query| answer(vec![hit("a.el", "f")]));
    let s = &r.strata["symbol"];
    assert_eq!((s.mrr, s.mrr_ci), (1.0, (1.0, 1.0)));
    assert_eq!(r.overall.n, 50);
}

fn rows_of(strata: &[(&str, usize)]) -> Vec<EvalRow> {
    let mut rows = Vec::new();
    for (s, n) in strata {
        for i in 0..*n {
            rows.push(EvalRow {
                id: format!("{s}-{i:03}"),
                stratum: (*s).into(),
                query: format!("{s}-{i:03}"),
                targets: vec![("a.el".into(), "f".into())],
                age_days: 1,
                dir: ".".into(),
                half: "dev".into(),
            });
        }
    }
    rows
}

/// A run in which the rows named in WORSE find their target at rank 2, and all others at rank 1.
fn report(rows: &[EvalRow], worse: &[&str]) -> Report {
    run(rows, &|q: &Query| {
        if worse.contains(&q.text.as_str()) {
            answer(vec![hit("b.el", "g"), hit("a.el", "f")])
        } else {
            answer(vec![hit("a.el", "f")])
        }
    })
}

/// Pattern D. The gate: the lower bound of the paired MRR@10 difference must stay above -0.01 overall and -0.03 in
/// each stratum; two reports over different rows are refused.
#[test]
fn compare_noninferiority_rule() {
    let rows = rows_of(&[("symbol", 400), ("docs", 20)]);
    let base = report(&rows, &[]);
    // the same: passes, difference exactly 0
    let v = compare(&base, &report(&rows, &[])).unwrap();
    assert!(v.pass, "{v:?}");
    assert_eq!(v.overall.mean, 0.0);
    // one row of 420 slips a rank: inside both bounds
    let v = compare(&base, &report(&rows, &["symbol-000"])).unwrap();
    assert!(v.pass, "{v:?}");
    assert!(v.overall.mean < 0.0 && v.overall.lo > -0.01);
    // one row of the 20-row stratum slips: overall is fine, the stratum's bound is not
    let v = compare(&base, &report(&rows, &["docs-000"])).unwrap();
    assert!(!v.pass, "{v:?}");
    assert!(v.overall.lo > -0.01, "{v:?}");
    assert!(v.reasons.iter().any(|r| r.contains("docs")), "{v:?}");
    // everything slips: overall fails
    let all: Vec<String> = rows.iter().map(|r| r.query.clone()).collect();
    let all: Vec<&str> = all.iter().map(String::as_str).collect();
    let v = compare(&base, &report(&rows, &all)).unwrap();
    assert!(
        !v.pass && v.reasons.iter().any(|r| r.contains("overall")),
        "{v:?}"
    );
    // different queries: refused
    let other = rows_of(&[("symbol", 399), ("docs", 20)]);
    assert!(compare(&base, &report(&other, &[])).is_err());
}

/// Pattern D. A candidate with a coverage failure, or an exact-symbol recall below 1.0, fails whatever its ranks.
#[test]
fn coverage_failure_fails_gate() {
    let rows = rows_of(&[("symbol", 50)]);
    let base = report(&rows, &[]);
    let mut cand = report(&rows, &[]);
    assert!(compare(&base, &cand).unwrap().pass);
    cand.coverage_errors = vec!["file without chunks: x.el".into()];
    let v = compare(&base, &cand).unwrap();
    assert!(
        !v.pass && v.reasons.iter().any(|r| r.contains("coverage")),
        "{v:?}"
    );
    cand.coverage_errors.clear();
    cand.exact_symbol_r1 = Some(0.98);
    let v = compare(&base, &cand).unwrap();
    assert!(
        !v.pass && v.reasons.iter().any(|r| r.contains("exact")),
        "{v:?}"
    );
    cand.exact_symbol_r1 = Some(1.0);
    assert!(compare(&base, &cand).unwrap().pass);
}
