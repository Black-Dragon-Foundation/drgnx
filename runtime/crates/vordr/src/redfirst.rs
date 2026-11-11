//! The red-first gate's decision (`docs/develop/orchestration.md`, "Red first").
//!
//! A task passes when its **first commit is its test commit** and a hub job at that commit's tree failed the task's
//! rows with class `assert` (or `build`, naming a symbol the task's non-test diff adds, where the pack allows the
//! language), a job with the same selector and env stamp at the tip passed the same rows, and the test commit's test
//! lines are unchanged at the tip.  A task whose approved body says `**Red:** none (reason)` passes on that line.

use crate::evidence::Evidence;
use crate::pack::Pack;
use crate::rows::{Class, JOB_ROW, Row, Verdict};

/// What the gate knows about a task's commits.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Inputs {
    /// How many commits base..tip has.
    pub commits: usize,
    /// The test commit (the first).
    pub test_commit: String,
    /// The test commit's tree key and the tip's.
    pub test_key: String,
    pub tip_key: String,
    /// The symbols the task's non-test diff adds ([`added_symbols`]).
    pub added_symbols: Vec<String>,
    /// The test commit's test lines the tip deleted ([`weakened`]).
    pub weakened: Vec<String>,
    /// The approved task body's `**Red:** none (reason)` ([`red_none`]).
    pub red_none: Option<String>,
}

/// The gate's answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    /// It may merge; why.
    Pass(String),
    /// A run is missing (the hub can make it: `workflow/red-run`); which.
    Wait(String),
    /// It may not merge as it is; why.
    Hold(String),
}

fn class_word(c: Option<Class>) -> &'static str {
    match c {
        Some(Class::Assert) => "assert",
        Some(Class::Build) => "build",
        Some(Class::Error) => "error",
        Some(Class::Timeout) => "timeout",
        Some(Class::Infra) => "infra",
        None => "none",
    }
}

/// A build row's language: cargo's are `build` / `build:CRATE (TARGET)`, an ERT row is a test's name.
fn lang(row: &Row) -> &'static str {
    if row.name == "build" || row.name.starts_with("build:") {
        "rust"
    } else {
        "elisp"
    }
}

fn short(key: &str) -> &str {
    &key[..key.len().min(10)]
}

/// The red-first decision for a task with INPUTS, under PACK, over EVIDENCE (the task's records, oldest first).
pub fn decide(pack: &Pack, inputs: &Inputs, evidence: &[Evidence]) -> Decision {
    if !pack.on("red-first") {
        return Decision::Pass("red-first is not in the pack".into());
    }
    if let Some(why) = &inputs.red_none {
        return Decision::Pass(format!("Red: none ({why}), in the plan as approved"));
    }
    if inputs.commits == 0 {
        return Decision::Hold("the task has no commits".into());
    }
    if !inputs.weakened.is_empty() {
        return Decision::Hold(format!(
            "the test commit's tests changed at the tip: {}",
            inputs.weakened.join("; ")
        ));
    }
    let failed = |r: &&Row| r.verdict == Verdict::Fail && r.name != JOB_ROW;
    let at_test: Vec<&Evidence> = evidence
        .iter()
        .filter(|e| e.facts.tree_key == inputs.test_key)
        .collect();
    let Some(red) = at_test
        .iter()
        .rev()
        .find(|e| e.rows.iter().any(|r| failed(&r)))
    else {
        if !at_test.is_empty() {
            return Decision::Hold(format!(
                "the task's tests pass at its first commit {}: a test commit fails without the change (was the \
                 implementation committed with them?)",
                short(&inputs.test_key)
            ));
        }
        return Decision::Wait(format!(
            "no run of the task's tests at its first commit's tree {}",
            short(&inputs.test_key)
        ));
    };
    let named: Vec<&Row> = red.rows.iter().filter(failed).collect();
    let mut builds = false;
    for r in &named {
        match r.class {
            Some(Class::Assert) => {}
            Some(Class::Build) => {
                if !pack.build_reds(lang(r)) {
                    return Decision::Hold(format!(
                        "{}: a build red, which the pack doesn't count for {}",
                        r.name,
                        lang(r)
                    ));
                }
                if r.symbols.is_empty() {
                    return Decision::Hold(format!(
                        "{}: a build red that names nothing the task adds",
                        r.name
                    ));
                }
                if !r.symbols.iter().any(|s| inputs.added_symbols.contains(s)) {
                    return Decision::Hold(format!(
                        "{}: a build red naming {}, which the task's change doesn't add",
                        r.name,
                        r.symbols.join(", ")
                    ));
                }
                builds = true;
            }
            c => {
                return Decision::Hold(format!(
                    "{} failed with class {}, not an assertion",
                    r.name,
                    class_word(c)
                ));
            }
        }
    }
    let Some(green) = evidence.iter().rev().find(|e| {
        e.facts.tree_key == inputs.tip_key
            && e.facts.selector == red.facts.selector
            && e.facts.env_stamp == red.facts.env_stamp
    }) else {
        return Decision::Wait(format!(
            "no run at the tip {} with the red run's selector and env",
            short(&inputs.tip_key)
        ));
    };
    if builds && let Some(f) = green.rows.iter().find(|r| r.verdict == Verdict::Fail) {
        return Decision::Hold(format!("{} fails at the tip", f.name));
    }
    for r in named.iter().filter(|r| r.class == Some(Class::Assert)) {
        if !green
            .rows
            .iter()
            .any(|g| g.name == r.name && g.verdict == Verdict::Pass)
        {
            return Decision::Hold(format!("{} doesn't pass at the tip", r.name));
        }
    }
    if builds && !green.rows.iter().any(|g| g.verdict == Verdict::Pass) {
        return Decision::Hold("the tip's run passed no row".into());
    }
    Decision::Pass(format!(
        "red at {} ({}), green at {}",
        short(&inputs.test_key),
        named
            .iter()
            .map(|r| r.name.as_str())
            .collect::<Vec<_>>()
            .join(", "),
        short(&inputs.tip_key)
    ))
}

/// BODY's `**Red:** none (reason)`: the reason; none without one.
pub fn red_none(body: &str) -> Option<String> {
    body.lines().find_map(|l| {
        let rest = l
            .trim()
            .strip_prefix("**Red:**")?
            .trim()
            .strip_prefix("none")?
            .trim();
        let why = rest.strip_prefix('(')?.strip_suffix(')')?.trim();
        (!why.is_empty()).then(|| why.to_string())
    })
}

/// One file of a `git diff -U0` (no renames): its new path, its added lines with their new line numbers, its removed
/// lines.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FileDiff {
    pub path: String,
    pub added: Vec<(usize, String)>,
    pub removed: Vec<String>,
}

/// TEXT, a `git diff -U0 --no-color --no-renames`, by file.
pub fn parse_diff(text: &str) -> Vec<FileDiff> {
    let mut out: Vec<FileDiff> = Vec::new();
    let mut line_no = 0usize;
    // between a `diff --git` line and its first hunk: the header (`---`/`+++` there are names, not lines)
    let mut header = false;
    for l in text.lines() {
        if let Some(rest) = l.strip_prefix("diff --git ") {
            let path = rest.rsplit_once(" b/").map(|(_, p)| p).unwrap_or(rest);
            out.push(FileDiff {
                path: path.to_string(),
                ..FileDiff::default()
            });
            header = true;
        } else if let Some(h) = l.strip_prefix("@@ ") {
            header = false;
            // @@ -a[,b] +c[,d] @@
            line_no = h
                .split(' ')
                .find_map(|w| w.strip_prefix('+'))
                .and_then(|w| w.split(',').next())
                .and_then(|n| n.parse().ok())
                .unwrap_or(0);
        } else if header {
            continue;
        } else if let Some(f) = out.last_mut() {
            if let Some(a) = l.strip_prefix('+') {
                f.added.push((line_no, a.to_string()));
                line_no += 1;
            } else if let Some(r) = l.strip_prefix('-') {
                f.removed.push(r.to_string());
            }
        }
    }
    out
}

const RUST_ITEMS: &[&str] = &[
    "fn ",
    "struct ",
    "enum ",
    "trait ",
    "mod ",
    "const ",
    "static ",
    "type ",
    "union ",
    "macro_rules! ",
];
const LISP_DEFS: &[&str] = &[
    "(defun ",
    "(defmacro ",
    "(defvar ",
    "(defvar-local ",
    "(defcustom ",
    "(defconst ",
    "(defface ",
    "(defsubst ",
    "(cl-defun ",
    "(cl-defmacro ",
    "(cl-defgeneric ",
    "(cl-defmethod ",
    "(cl-defstruct ",
    "(define-minor-mode ",
    "(define-derived-mode ",
    "(define-inline ",
];

fn ident(s: &str, lisp: bool) -> Option<String> {
    let s = s.trim_start_matches('(');
    let id: String = s
        .chars()
        .take_while(|c| c.is_alphanumeric() || *c == '_' || (lisp && "-/*+<>=!?:.".contains(*c)))
        .collect();
    (!id.is_empty()).then_some(id)
}

/// A Rust line's item or field name: `[pub[(…)]] [async|unsafe|extern] fn|struct|… NAME`, or `NAME: Type,`.
fn rust_symbol(line: &str) -> Option<String> {
    let mut r = line;
    if let Some(x) = r.strip_prefix("pub") {
        r = x.trim_start();
        if r.starts_with('(') {
            r = r.split_once(')').map(|(_, x)| x.trim_start()).unwrap_or(r);
        }
    }
    while let Some(x) = ["async ", "unsafe ", "extern "]
        .iter()
        .find_map(|q| r.strip_prefix(q))
    {
        r = x;
    }
    if r.starts_with("const fn ") {
        r = &r["const ".len()..];
    }
    if let Some(x) = RUST_ITEMS.iter().find_map(|k| r.strip_prefix(k)) {
        return ident(x, false);
    }
    // a field; a variant isn't read
    let (name, rest) = r.split_once(':')?;
    (!rest.starts_with(':')
        && line.trim_end().ends_with(',')
        && !name.is_empty()
        && name.chars().all(|c| c.is_alphanumeric() || c == '_'))
    .then(|| name.to_string())
}

/// The symbols LINES (added to PATH) define: a Rust item's name (and a field's: `name: Type,`), an Emacs Lisp
/// definition's.
pub fn added_symbols(path: &str, lines: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for l in lines {
        let t = l.trim_start();
        let found = if path.ends_with(".el") {
            LISP_DEFS
                .iter()
                .find_map(|d| t.strip_prefix(d))
                .and_then(|r| ident(r, true))
        } else if path.ends_with(".rs") {
            rust_symbol(t)
        } else {
            None
        };
        if let Some(s) = found
            && !out.contains(&s)
        {
            out.push(s);
        }
    }
    out
}

/// Of ADDED (lines the test commit added to PATH, with their line numbers in TEXT, the file at the test commit), its
/// test lines: all of them in a test path (the pack's globs), those below the first `#[cfg(test)]` in a Rust file.
pub fn test_lines(pack: &Pack, path: &str, text: &str, added: &[(usize, String)]) -> Vec<String> {
    if pack.is_test_path(path) {
        return added.iter().map(|(_, l)| l.clone()).collect();
    }
    if !path.ends_with(".rs") {
        return Vec::new();
    }
    let Some(cut) = text
        .lines()
        .position(|l| l.trim_start().starts_with("#[cfg(test)]"))
    else {
        return Vec::new();
    };
    added
        .iter()
        .filter(|(n, _)| *n > cut + 1)
        .map(|(_, l)| l.clone())
        .collect()
}

/// Of TESTS (path, line), those AT_TIP (the diff from the test commit to the tip) deletes and doesn't add back to
/// the same file, as `path: line`.
pub fn weakened(tests: &[(String, String)], at_tip: &[FileDiff]) -> Vec<String> {
    let mut out = Vec::new();
    for f in at_tip {
        for r in &f.removed {
            let a_test = tests.iter().any(|(p, l)| *p == f.path && l == r);
            if r.trim().is_empty() || !a_test || f.added.iter().any(|(_, a)| a == r) {
                continue;
            }
            out.push(format!("{}: {r}", f.path));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::evidence::Evidence;
    use crate::facts::Facts;
    use crate::pack::{Pack, Rule};
    use crate::rows::{Class, Row};

    fn pack() -> Pack {
        Pack {
            name: "p".into(),
            rules: vec![Rule {
                id: "red-first".into(),
                kind: "enforced".into(),
                doc: String::new(),
            }],
            compile_fail_reds: vec!["rust".into(), "elisp".into()],
            test_globs: vec!["test/*".into(), "*/tests.rs".into()],
            ..Pack::default()
        }
    }

    fn ev(key: &str, rows: Vec<Row>) -> Evidence {
        Evidence {
            kind: "red".into(),
            task: "t1".into(),
            job: "x".into(),
            facts: Facts {
                tree_key: key.into(),
                env_stamp: "e".into(),
                platform: "p".into(),
                selector: "s".into(),
            },
            rows,
            truncated: false,
            at: 1.0,
            note: None,
        }
    }

    fn inputs() -> Inputs {
        Inputs {
            commits: 2,
            test_commit: "c".into(),
            test_key: "T".into(),
            tip_key: "P".into(),
            added_symbols: vec!["start_or_reuse".into(), "drgnx-new".into()],
            weakened: vec![],
            red_none: None,
        }
    }

    fn is_pass(d: &Decision) -> bool {
        matches!(d, Decision::Pass(_))
    }

    #[test]
    fn an_assertion_red_that_passes_at_the_tip_passes() {
        // an inline `mod tests` red is a row like any other: the commit may touch any file
        let e = [
            ev(
                "T",
                vec![
                    Row::fail("exec::tests::a", Class::Assert, vec![]),
                    Row::pass("exec::tests::b"),
                ],
            ),
            ev(
                "P",
                vec![Row::pass("exec::tests::a"), Row::pass("exec::tests::b")],
            ),
        ];
        assert!(
            is_pass(&decide(&pack(), &inputs(), &e)),
            "{:?}",
            decide(&pack(), &inputs(), &e)
        );
    }

    #[test]
    fn an_ert_red_passes_and_a_void_function_naming_an_added_symbol_counts() {
        let e = [
            ev(
                "T",
                vec![Row::fail("t-three", Class::Build, vec!["drgnx-new".into()])],
            ),
            ev("P", vec![Row::pass("t-three")]),
        ];
        assert!(is_pass(&decide(&pack(), &inputs(), &e)));
        let e = [
            ev("T", vec![Row::fail("drgnx-x/one", Class::Assert, vec![])]),
            ev("P", vec![Row::pass("drgnx-x/one")]),
        ];
        assert!(is_pass(&decide(&pack(), &inputs(), &e)));
    }

    #[test]
    fn a_compile_fail_red_counts_only_naming_an_added_symbol() {
        let green = ev("P", vec![Row::pass("exec::tests::a")]);
        let named = [
            ev(
                "T",
                vec![Row::fail(
                    "build",
                    Class::Build,
                    vec!["start_or_reuse".into()],
                )],
            ),
            green.clone(),
        ];
        assert!(is_pass(&decide(&pack(), &inputs(), &named)));
        let nothing = [
            ev(
                "T",
                vec![Row::fail("build:demo (lib test)", Class::Build, vec![])],
            ),
            green.clone(),
        ];
        assert!(
            matches!(decide(&pack(), &inputs(), &nothing), Decision::Hold(w) if w.contains("names nothing"))
        );
        let other = [
            ev(
                "T",
                vec![Row::fail("build", Class::Build, vec!["Elsewhere".into()])],
            ),
            green.clone(),
        ];
        assert!(
            matches!(decide(&pack(), &inputs(), &other), Decision::Hold(w) if w.contains("Elsewhere"))
        );
        // not where the pack doesn't allow the language
        let rust_off = Pack {
            compile_fail_reds: vec!["elisp".into()],
            ..pack()
        };
        assert!(matches!(
            decide(&rust_off, &inputs(), &named),
            Decision::Hold(_)
        ));
        // and a build red is green at the tip only when the tip's run has no failed row
        let still_red = [
            named[0].clone(),
            ev("P", vec![Row::fail("x", Class::Assert, vec![])]),
        ];
        assert!(matches!(
            decide(&pack(), &inputs(), &still_red),
            Decision::Hold(_)
        ));
    }

    #[test]
    fn a_test_commit_with_the_implementation_is_held() {
        let e = [
            ev("T", vec![Row::pass("exec::tests::a")]),
            ev("P", vec![Row::pass("exec::tests::a")]),
        ];
        assert!(
            matches!(decide(&pack(), &inputs(), &e), Decision::Hold(w) if w.contains("pass at"))
        );
    }

    #[test]
    fn a_timeout_or_error_is_not_a_red() {
        for c in [Class::Timeout, Class::Error, Class::Infra] {
            let e = [
                ev("T", vec![Row::fail("a", c, vec![])]),
                ev("P", vec![Row::pass("a")]),
            ];
            assert!(
                matches!(decide(&pack(), &inputs(), &e), Decision::Hold(_)),
                "{c:?}"
            );
        }
    }

    #[test]
    fn a_weakened_test_is_held() {
        let e = [
            ev("T", vec![Row::fail("a", Class::Assert, vec![])]),
            ev("P", vec![Row::pass("a")]),
        ];
        let i = Inputs {
            weakened: vec!["test/a.el: (should (= x 2))".into()],
            ..inputs()
        };
        assert!(matches!(decide(&pack(), &i, &e), Decision::Hold(w) if w.contains("should")));
    }

    #[test]
    fn a_red_row_that_doesnt_pass_at_the_tip_is_held() {
        let e = [
            ev("T", vec![Row::fail("a", Class::Assert, vec![])]),
            ev("P", vec![Row::pass("b")]),
        ];
        assert!(matches!(decide(&pack(), &inputs(), &e), Decision::Hold(w) if w.contains("a")));
    }

    #[test]
    fn missing_runs_wait_and_only_matching_ones_count() {
        assert!(matches!(decide(&pack(), &inputs(), &[]), Decision::Wait(_)));
        let red = ev("T", vec![Row::fail("a", Class::Assert, vec![])]);
        assert!(
            matches!(decide(&pack(), &inputs(), std::slice::from_ref(&red)), Decision::Wait(w) if w.contains("tip"))
        );
        // a tip run of another selector or env stamp isn't the same rows' run
        let mut other = ev("P", vec![Row::pass("a")]);
        other.facts.selector = "other".into();
        assert!(matches!(
            decide(&pack(), &inputs(), &[red.clone(), other]),
            Decision::Wait(_)
        ));
        let mut overlay = ev("T+abc", vec![Row::fail("a", Class::Assert, vec![])]);
        overlay.kind = "red".into();
        assert!(matches!(
            decide(&pack(), &inputs(), &[overlay]),
            Decision::Wait(_)
        ));
    }

    #[test]
    fn red_none_counts_from_the_approved_body_and_the_rule_can_be_off() {
        let i = Inputs {
            red_none: red_none("**Role:** docs\n**Red:** none (docs only)\n"),
            ..inputs()
        };
        assert!(matches!(decide(&pack(), &i, &[]), Decision::Pass(w) if w.contains("docs only")));
        assert_eq!(red_none("**Red:** none"), None, "a reason is required");
        assert_eq!(red_none("**Red:** exec::tests::a"), None);
        let off = Pack {
            rules: vec![],
            ..pack()
        };
        assert!(is_pass(&decide(&off, &inputs(), &[])));
        let none = Inputs {
            commits: 0,
            ..inputs()
        };
        assert!(matches!(decide(&pack(), &none, &[]), Decision::Hold(_)));
    }

    #[test]
    fn diffs_symbols_and_test_lines() {
        let d = parse_diff(
            "diff --git a/src/a.rs b/src/a.rs\n--- a/src/a.rs\n+++ b/src/a.rs\n@@ -3,0 +4,2 @@ fn x()\n\
             +pub fn start_or_reuse(&self) {}\n+    pub(crate) struct Pack;\n@@ -9 +10,0 @@\n-    assert!(x);\n\
             diff --git a/test/b-test.el b/test/b-test.el\nnew file mode 100644\n--- /dev/null\n+++ b/test/b-test.el\n\
             @@ -0,0 +1 @@\n+(ert-deftest b () (should (drgnx-new)))\n",
        );
        assert_eq!(d.len(), 2);
        assert_eq!(d[0].path, "src/a.rs");
        assert_eq!(
            d[0].added,
            vec![
                (4, "pub fn start_or_reuse(&self) {}".to_string()),
                (5, "    pub(crate) struct Pack;".into())
            ]
        );
        assert_eq!(d[0].removed, vec!["    assert!(x);".to_string()]);
        assert_eq!(d[1].path, "test/b-test.el");
        let rs: Vec<String> = d[0].added.iter().map(|(_, l)| l.clone()).collect();
        assert_eq!(
            added_symbols("src/a.rs", &rs),
            vec!["start_or_reuse", "Pack"]
        );
        let el = vec![
            "(defun drgnx-new (x)".to_string(),
            "(cl-defmethod drgnx-m ((x t)))".into(),
            "  (defvar-local drgnx--v nil)".into(),
            "(foo bar)".into(),
        ];
        assert_eq!(
            added_symbols("core/x.el", &el),
            vec!["drgnx-new", "drgnx-m", "drgnx--v"]
        );
        // a test path's lines are all test lines; a source file's only below its #[cfg(test)]
        let added = vec![
            (2, "fn f() {}".to_string()),
            (5, "    assert!(f());".to_string()),
        ];
        let text = "a\nfn f() {}\n#[cfg(test)]\nmod tests {\n    assert!(f());\n}\n";
        assert_eq!(
            test_lines(&pack(), "src/a.rs", text, &added),
            vec!["    assert!(f());"]
        );
        assert_eq!(test_lines(&pack(), "src/x/tests.rs", "", &added).len(), 2);
        assert!(test_lines(&pack(), "core/a.el", text, &added).is_empty());
        // weakened: a test line the tip deletes and doesn't add back
        let at_tip = parse_diff(
            "diff --git a/src/a.rs b/src/a.rs\n--- a/src/a.rs\n+++ b/src/a.rs\n@@ -5 +5 @@\n-    assert!(f());\n+    assert!(true);\n",
        );
        let tests = vec![("src/a.rs".to_string(), "    assert!(f());".to_string())];
        assert_eq!(
            weakened(&tests, &at_tip),
            vec!["src/a.rs:     assert!(f());"]
        );
        let moved = parse_diff(
            "diff --git a/src/a.rs b/src/a.rs\n--- a/src/a.rs\n+++ b/src/a.rs\n@@ -5 +7 @@\n-    assert!(f());\n+    assert!(f());\n",
        );
        assert!(weakened(&tests, &moved).is_empty());
    }
}
