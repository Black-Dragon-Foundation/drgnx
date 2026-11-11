//! A job's log read as rows: each test's name, its verdict and, for a failure, its class.
//!
//! The readers are portable: every line is offered to the cargo test, ERT and domr readers whatever the job's kind
//! (a container job or a script runs any of them), and their shapes don't overlap:
//!
//! - cargo test: `test NAME ... ok|FAILED|ignored`; a failed test panicked, class `assert`.  A compile error
//!   (`error[E0425]: cannot find function `x``) is a `build` row named after cargo's `could not compile `CRATE`
//!   (TARGET)` line, carrying the symbols the errors say are missing ([`MISSING`]).
//! - ERT (batch): `   FAILED  2/4  NAME (… sec) at FILE:LINE`; the `Test NAME condition:` block before it gives the
//!   class: `(ert-test-failed …` is `assert`, `(void-function S)` or `(void-variable S)` a `build` row naming S,
//!   anything else `error`.  The harness's `FAILED  load FILE` is a `build` row.
//! - domr: `PASS GROUP/NAME`, `FAIL GROUP/NAME: why` (class `assert`), `SKIP GROUP/NAME …`.
//!
//! [`close`] adds the row that stands for the job itself ([`JOB_ROW`]) when the job ran out of time (`timeout`),
//! failed for the machine's sake (`infra`) or failed without a failing row (`error`).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A row's verdict.  Ordered from best to worst: a name seen twice keeps its worst.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    Pass,
    Skip,
    Fail,
}

/// Why a row failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Class {
    /// An assertion or a panic in the test itself.
    Assert,
    /// The test didn't build (a compile error, an ERT void function or a file that didn't load).
    Build,
    /// Any other error the test raised.
    Error,
    /// The job ran out of time.
    Timeout,
    /// The machine, not the test (a lost job, a relay that ended).
    Infra,
}

/// One row of a job.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub name: String,
    pub verdict: Verdict,
    /// A failure's class; none for a pass or a skip.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class: Option<Class>,
    /// The symbols a `build` failure says are missing.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub symbols: Vec<String>,
}

impl Row {
    fn new(name: &str, verdict: Verdict, class: Option<Class>, symbols: Vec<String>) -> Row {
        Row {
            name: name.to_string(),
            verdict,
            class,
            symbols,
        }
    }

    fn pass(name: &str) -> Row {
        Row::new(name, Verdict::Pass, None, Vec::new())
    }

    fn skip(name: &str) -> Row {
        Row::new(name, Verdict::Skip, None, Vec::new())
    }

    fn fail(name: &str, class: Class, symbols: Vec<String>) -> Row {
        Row::new(name, Verdict::Fail, Some(class), symbols)
    }
}

/// The name of the row that stands for the job itself.
pub const JOB_ROW: &str = "(job)";

/// The rustc errors that say an item is missing: their first quoted name is the symbol.
pub const MISSING: &[&str] = &[
    "E0412", // cannot find type
    "E0422", // cannot find struct, variant or union type
    "E0423", // expected value, found struct
    "E0425", // cannot find value or function
    "E0432", // unresolved import
    "E0433", // failed to resolve
    "E0531", // cannot find tuple struct or variant
    "E0560", // struct has no field named
    "E0599", // no method or associated item named
    "E0609", // no field on type
];

/// Reads a log line by line, in bounded memory per row.
#[derive(Debug, Default)]
pub struct Reader {
    rows: Vec<Row>,
    at: HashMap<String, usize>,
    /// Missing symbols of compile errors not yet claimed by a `could not compile` line.
    pending: Vec<String>,
    /// An ERT test whose condition block has started.
    condition_of: Option<String>,
    /// Each failed ERT test's class, from its condition block.
    ert: HashMap<String, (Class, Vec<String>)>,
}

impl Reader {
    pub fn new() -> Reader {
        Reader::default()
    }

    /// Offer LINE to every reader.
    pub fn line(&mut self, line: &str) {
        if let Some(name) = self.condition_of.take() {
            let t = line.trim();
            if t.is_empty() {
                self.condition_of = Some(name);
            } else {
                let c = ert_condition(t);
                self.ert.insert(name, c);
            }
            return;
        }
        if let Some(row) = cargo_row(line)
            .or_else(|| self.compile(line))
            .or_else(|| self.ert_row(line))
            .or_else(|| domr_row(line))
        {
            self.push(row);
        }
    }

    /// The rows read, in order of first appearance; missing symbols no `could not compile` line claimed are a
    /// `build` row of their own.
    pub fn finish(mut self) -> Vec<Row> {
        if !self.pending.is_empty() {
            let syms = std::mem::take(&mut self.pending);
            self.push(Row::fail("build", Class::Build, syms));
        }
        self.rows
    }

    fn push(&mut self, row: Row) {
        match self.at.get(&row.name) {
            Some(&i) => {
                let old = &mut self.rows[i];
                if row.verdict > old.verdict {
                    *old = row;
                }
            }
            None => {
                self.at.insert(row.name.clone(), self.rows.len());
                self.rows.push(row);
            }
        }
    }

    /// A rustc error's missing symbol is kept; `could not compile` makes the build row.
    fn compile(&mut self, line: &str) -> Option<Row> {
        if let Some(rest) = line.strip_prefix("error[") {
            let (code, msg) = rest.split_once("]: ")?;
            if MISSING.contains(&code)
                && let Some(sym) = first_quoted(msg)
            {
                let sym = sym.rsplit("::").next().unwrap_or(sym).to_string();
                if !self.pending.contains(&sym) {
                    self.pending.push(sym);
                }
            }
            return None;
        }
        let rest = line.strip_prefix("error: could not compile `")?;
        let (krate, after) = rest.split_once('`')?;
        let target = after
            .strip_prefix(" (")
            .and_then(|t| t.split_once(')'))
            .map(|(t, _)| format!(" ({t})"))
            .unwrap_or_default();
        let syms = std::mem::take(&mut self.pending);
        Some(Row::fail(
            &format!("build:{krate}{target}"),
            Class::Build,
            syms,
        ))
    }

    fn ert_row(&mut self, line: &str) -> Option<Row> {
        if let Some(rest) = line.strip_prefix("Test ")
            && let Some(name) = rest.strip_suffix(" condition:")
        {
            self.condition_of = Some(name.to_string());
            return None;
        }
        let mut w = line.split_whitespace();
        let status = w.next()?;
        let second = w.next()?;
        if status == "FAILED" && second == "load" {
            let file = w.next()?;
            return Some(Row::fail(&format!("load {file}"), Class::Build, Vec::new()));
        }
        let (a, b) = second.split_once('/')?;
        if a.is_empty() || b.is_empty() || !(a.bytes().chain(b.bytes()).all(|c| c.is_ascii_digit()))
        {
            return None;
        }
        let name = w.next()?;
        Some(match status {
            "passed" | "failed" => Row::pass(name),
            "skipped" => Row::skip(name),
            "FAILED" => {
                let (class, syms) = self.ert.remove(name).unwrap_or((Class::Error, Vec::new()));
                Row::fail(name, class, syms)
            }
            // an unexpected pass of a test expected to fail
            "PASSED" => Row::fail(name, Class::Assert, Vec::new()),
            _ => return None,
        })
    }
}

fn cargo_row(line: &str) -> Option<Row> {
    let rest = line.strip_prefix("test ")?;
    let (name, result) = rest.rsplit_once(" ... ")?;
    match result.trim_end() {
        "ok" => Some(Row::pass(name)),
        "FAILED" => Some(Row::fail(name, Class::Assert, Vec::new())),
        r if r.starts_with("ignored") => Some(Row::skip(name)),
        _ => None,
    }
}

fn domr_row(line: &str) -> Option<Row> {
    let named = |s: &str| {
        let n = s.split([':', ' ']).next().unwrap_or("").trim();
        (n.contains('/') && !n.starts_with('/')).then(|| n.to_string())
    };
    if let Some(rest) = line.strip_prefix("PASS ") {
        return named(rest).map(|n| Row::pass(&n));
    }
    if let Some(rest) = line.strip_prefix("SKIP ") {
        return named(rest).map(|n| Row::skip(&n));
    }
    let rest = line.strip_prefix("FAIL ")?;
    named(rest).map(|n| Row::fail(&n, Class::Assert, Vec::new()))
}

/// An ERT condition's first line as a class.
fn ert_condition(t: &str) -> (Class, Vec<String>) {
    if t.starts_with("(ert-test-failed") {
        return (Class::Assert, Vec::new());
    }
    for head in ["(void-function ", "(void-variable "] {
        if let Some(rest) = t.strip_prefix(head) {
            let sym: String = rest
                .chars()
                .take_while(|c| *c != ')' && !c.is_whitespace())
                .collect();
            if !sym.is_empty() {
                return (Class::Build, vec![sym]);
            }
        }
    }
    (Class::Error, Vec::new())
}

/// The first name between backticks in MSG.
fn first_quoted(msg: &str) -> Option<&str> {
    let (_, rest) = msg.split_once('`')?;
    let (sym, _) = rest.split_once('`')?;
    (!sym.is_empty()).then_some(sym)
}

/// TEXT read as rows.
pub fn parse(text: &str) -> Vec<Row> {
    let mut r = Reader::new();
    for line in text.lines() {
        r.line(line);
    }
    r.finish()
}

/// Add the job's own row to ROWS for how it ended: STATUS is the job's end (`done`, `stopped`, `timed-out`, `infra`,
/// `lost`), EXIT its exit code.  A job that ended `done` with exit 0, or with a failing row already, adds nothing.
pub fn close(rows: &mut Vec<Row>, status: &str, exit: Option<i32>) {
    let class = match status {
        "timed-out" => Class::Timeout,
        "infra" | "lost" => Class::Infra,
        "stopped" => Class::Error,
        _ if exit == Some(0) => return,
        _ if rows.iter().any(|r| r.verdict == Verdict::Fail) => return,
        _ => Class::Error,
    };
    rows.push(Row::fail(JOB_ROW, class, Vec::new()));
}

/// The names of ROWS that failed, in order.
pub fn failing(rows: &[Row]) -> impl Iterator<Item = &str> {
    rows.iter()
        .filter(|r| r.verdict == Verdict::Fail)
        .map(|r| r.name.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn one(rows: &[Row], name: &str) -> Row {
        rows.iter()
            .find(|r| r.name == name)
            .unwrap_or_else(|| panic!("no row {name} in {rows:?}"))
            .clone()
    }

    #[test]
    fn cargo_rows_and_their_classes() {
        let log = "running 4 tests\ntest a::ok ... ok\ntest a::bad ... FAILED\ntest a::skip ... ignored, slow\n\
                   test a::bad ... ok\ntest result: FAILED. 1 passed; 1 failed\n";
        let rows = parse(log);
        assert_eq!(rows.len(), 3);
        assert_eq!(one(&rows, "a::ok").verdict, Verdict::Pass);
        // a name seen twice keeps its worst
        assert_eq!(one(&rows, "a::bad").class, Some(Class::Assert));
        assert_eq!(one(&rows, "a::skip").verdict, Verdict::Skip);
    }

    #[test]
    fn a_compile_error_names_the_missing_symbols() {
        let log = "error[E0425]: cannot find function `added_fn` in this scope\n\
                   error[E0432]: unresolved import `crate::orch::Gate`\n\
                   error[E0308]: mismatched types\n\
                   error[E0599]: no method named `reds` found for struct `Job`\n\
                   error[E0425]: cannot find function `added_fn` in this scope\n\
                   error: could not compile `demo` (lib test) due to 4 previous errors; 1 warning emitted\n";
        let rows = parse(log);
        assert_eq!(
            rows,
            vec![Row::fail(
                "build:demo (lib test)",
                Class::Build,
                vec!["added_fn".into(), "Gate".into(), "reds".into()]
            )]
        );
        // a type error alone names nothing
        let rows = parse("error[E0308]: mismatched types\nerror: could not compile `demo` (lib)\n");
        assert_eq!(
            rows,
            vec![Row::fail("build:demo (lib)", Class::Build, vec![])]
        );
        // errors with no could-not-compile line still make a build row
        let rows = parse("error[E0412]: cannot find type `Pack` in this scope\n");
        assert_eq!(
            rows,
            vec![Row::fail("build", Class::Build, vec!["Pack".into()])]
        );
    }

    #[test]
    fn ert_rows_and_their_conditions() {
        let log = "Test t-two backtrace:\n  x\nTest t-two condition:\n    (ert-test-failed\n     ((should nil)))\n\
                   \x20  passed  1/5  t-one (0.001 sec)\n   FAILED  2/5  t-two (0.002 sec) at x-test.el:3\n\
                   Test t-three condition:\n\n    (void-function drgnx-new)\n   FAILED  3/5  t-three (0.0 sec)\n\
                   Test t-four condition:\n    (wrong-type-argument stringp 1)\n   FAILED  4/5  t-four (0.0 sec)\n\
                   \x20 skipped  5/5  t-five (0.0 sec)\n\nRan 5 tests, 2 results as expected, 3 unexpected\n\
                   \n3 unexpected results:\n   FAILED  t-two\n   FAILED  t-three\n   FAILED  load y-test.el\n";
        let rows = parse(log);
        assert_eq!(one(&rows, "t-one").verdict, Verdict::Pass);
        assert_eq!(one(&rows, "t-two").class, Some(Class::Assert));
        assert_eq!(
            one(&rows, "t-three"),
            Row::fail("t-three", Class::Build, vec!["drgnx-new".into()])
        );
        assert_eq!(one(&rows, "t-four").class, Some(Class::Error));
        assert_eq!(one(&rows, "t-five").verdict, Verdict::Skip);
        assert_eq!(one(&rows, "load y-test.el").class, Some(Class::Build));
        // the summary's bare names are not rows of their own
        assert_eq!(rows.len(), 6);
    }

    #[test]
    fn domr_rows() {
        let log = "PASS a/b\nFAIL launch/x: expected y within 50 ms\nSKIP c/d (no bwrap)\nFAIL k/z: bad\nPASS nothing\n";
        let rows = parse(log);
        assert_eq!(
            rows.iter()
                .map(|r| (r.name.as_str(), r.verdict))
                .collect::<Vec<_>>(),
            vec![
                ("a/b", Verdict::Pass),
                ("launch/x", Verdict::Fail),
                ("c/d", Verdict::Skip),
                ("k/z", Verdict::Fail)
            ]
        );
        assert_eq!(failing(&rows).collect::<Vec<_>>(), vec!["launch/x", "k/z"]);
    }

    #[test]
    fn the_jobs_own_row() {
        let close_of = |status: &str, exit: Option<i32>, rows: Vec<Row>| {
            let mut rows = rows;
            close(&mut rows, status, exit);
            rows.into_iter()
                .find(|r| r.name == JOB_ROW)
                .and_then(|r| r.class)
        };
        assert_eq!(close_of("timed-out", None, vec![]), Some(Class::Timeout));
        assert_eq!(close_of("lost", None, vec![]), Some(Class::Infra));
        assert_eq!(close_of("infra", Some(1), vec![]), Some(Class::Infra));
        assert_eq!(close_of("done", Some(2), vec![]), Some(Class::Error));
        assert_eq!(close_of("done", Some(0), vec![]), None);
        let failed = vec![Row::fail("t", Class::Assert, vec![])];
        assert_eq!(close_of("done", Some(1), failed), None);
    }

    #[test]
    fn rows_round_trip_as_json() {
        let r = Row::fail("t", Class::Build, vec!["s".into()]);
        let j = serde_json::to_value(&r).unwrap();
        assert_eq!(
            j,
            serde_json::json!({"name": "t", "verdict": "fail", "class": "build", "symbols": ["s"]})
        );
        assert_eq!(serde_json::from_value::<Row>(j).unwrap(), r);
        let p = serde_json::to_value(Row::pass("p")).unwrap();
        assert_eq!(p, serde_json::json!({"name": "p", "verdict": "pass"}));
    }
}
