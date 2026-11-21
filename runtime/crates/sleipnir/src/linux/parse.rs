//! Row counts from a job's log, and the verdict they and the job's `expect` give.
//!
//! - `ert`: ERT's batch lines (`   passed  3/10  name (0.1 sec)`, `FAILED`, `skipped`, `failed` for an expected
//!   failure) and `Ran N tests`; a run with `Running N tests` and no `Ran` line died mid-way (one crash).
//! - `cargo-test`: libtest's `test NAME ... ok|FAILED|ignored`; a test binary that died on a signal is a crash.
//! - `plist`: one row per line, `(:name "NAME" :verdict pass|fail|skip|crash …)`.
//! - `exit`: no rows; the exit code alone decides, and such a job cannot claim `min_ran`.

use forseti::{Expect, Verdict};
use serde::{Deserialize, Serialize};

/// Which parser reads a job's log.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Parser {
    Ert,
    CargoTest,
    Plist,
    #[default]
    Exit,
}

/// A row's own outcome.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RowVerdict {
    Pass,
    Fail,
    Skip,
    Crash,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Counts {
    pub ran: u32,
    pub passed: u32,
    pub failed: u32,
    pub skipped: u32,
    pub crashed: u32,
}

/// What a parser read: the counts, each row in order, and whether the parser counts rows at all.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Parsed {
    pub counts: Counts,
    pub rows: Vec<(String, RowVerdict)>,
    pub counts_rows: bool,
}

impl Parsed {
    fn row(&mut self, name: &str, v: RowVerdict) {
        let c = &mut self.counts;
        match v {
            RowVerdict::Pass => c.passed += 1,
            RowVerdict::Fail => c.failed += 1,
            RowVerdict::Skip => c.skipped += 1,
            RowVerdict::Crash => c.crashed += 1,
        }
        if v != RowVerdict::Skip {
            c.ran += 1;
        }
        self.rows.push((name.to_string(), v));
    }
}

/// Reads LOG with PARSER.
pub fn parse(parser: Parser, log: &[u8]) -> Parsed {
    match parser {
        Parser::Ert => ert(log),
        Parser::CargoTest => cargo_test(log),
        Parser::Plist => plist(log),
        Parser::Exit => exit(log),
    }
}

pub fn ert(log: &[u8]) -> Parsed {
    let text = String::from_utf8_lossy(log);
    let mut p = Parsed {
        counts_rows: true,
        ..Default::default()
    };
    let (mut running, mut ran_line) = (false, false);
    for line in text.lines() {
        let t = line.trim_start();
        if t.starts_with("Running ") && t.contains(" tests") {
            running = true;
        } else if t.starts_with("Ran ") && t.contains(" test") {
            ran_line = true;
        }
        let mut w = t.split_whitespace();
        let v = match w.next() {
            Some("passed") => RowVerdict::Pass,
            // an expected failure is a result as expected
            Some("failed") => RowVerdict::Pass,
            Some("FAILED") => RowVerdict::Fail,
            Some("skipped") => RowVerdict::Skip,
            _ => continue,
        };
        let (Some(n), Some(name)) = (w.next(), w.next()) else {
            continue;
        };
        let is_index = n.split_once('/').is_some_and(|(a, b)| {
            !a.is_empty()
                && !b.is_empty()
                && a.bytes().all(|c| c.is_ascii_digit())
                && b.bytes().all(|c| c.is_ascii_digit())
        });
        if is_index {
            p.row(name, v);
        }
    }
    if running && !ran_line {
        p.counts.crashed += 1;
    }
    p
}

pub fn cargo_test(log: &[u8]) -> Parsed {
    let text = String::from_utf8_lossy(log);
    let mut p = Parsed {
        counts_rows: true,
        ..Default::default()
    };
    for line in text.lines() {
        if line.contains("process didn't exit successfully") && line.contains("(signal: ") {
            p.counts.crashed += 1;
            continue;
        }
        let Some(rest) = line.strip_prefix("test ") else {
            continue;
        };
        let Some((name, outcome)) = rest.split_once(" ... ") else {
            continue;
        };
        let v = match outcome.trim() {
            "ok" => RowVerdict::Pass,
            "FAILED" => RowVerdict::Fail,
            o if o == "ignored" || o.starts_with("ignored, ") => RowVerdict::Skip,
            _ => continue,
        };
        p.row(name.trim(), v);
    }
    p
}

pub fn plist(log: &[u8]) -> Parsed {
    let text = String::from_utf8_lossy(log);
    let mut p = Parsed {
        counts_rows: true,
        ..Default::default()
    };
    for line in text.lines() {
        let t = line.trim();
        if !t.starts_with("(:") {
            continue;
        }
        let Some(name) = t
            .split_once(":name \"")
            .and_then(|(_, r)| r.split_once('"'))
            .map(|(n, _)| n)
        else {
            continue;
        };
        let v = match t
            .split_once(":verdict ")
            .map(|(_, r)| r.split([' ', ')']).next().unwrap_or(""))
        {
            Some("pass") => RowVerdict::Pass,
            Some("fail") => RowVerdict::Fail,
            Some("skip") => RowVerdict::Skip,
            Some("crash") => RowVerdict::Crash,
            _ => continue,
        };
        p.row(name, v);
    }
    p
}

pub fn exit(_log: &[u8]) -> Parsed {
    Parsed::default()
}

/// The verdict of a job that exited 0, from its rows and its `expect`: a failed row is red, a crashed one a crash; too
/// few rows or too many skips is `Suspect` (a set that silently ran nothing never passes).
pub fn judge(p: &Parsed, expect: &Expect) -> Verdict {
    let c = &p.counts;
    if c.failed > 0 {
        return Verdict::Red;
    }
    if c.crashed > 0 {
        return Verdict::Crash;
    }
    if let Some(min) = expect.min_ran {
        if !p.counts_rows {
            return Verdict::Suspect(format!(
                "expected at least {min} rows, and this parser counts none"
            ));
        }
        if c.ran < min {
            return Verdict::Suspect(format!("ran {} rows, expected at least {min}", c.ran));
        }
    }
    if let Some(max) = expect.max_skipped
        && c.skipped > max
    {
        return Verdict::Suspect(format!(
            "skipped {} rows, expected at most {max}",
            c.skipped
        ));
    }
    Verdict::Pass
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D]
    #[test]
    fn ert_parser_counts() {
        let log = b"Running 5 tests (2026-11-05 10:00:00+0530, selector `t')\n\
            \x20  passed  1/5  drgnx-a (0.001 sec)\n\
            \x20  FAILED  2/5  drgnx-b (0.010 sec) at test/unit/b.el:3\n\
            \x20 skipped  3/5  drgnx-c (0.000 sec)\n\
            \x20  failed  4/5  drgnx-d (0.000 sec)\n\
            \x20  passed  5/5  drgnx-e (0.002 sec)\n\
            the test passed 1/2 of the time\n\n\
            Ran 5 tests, 3 results as expected, 1 unexpected, 1 skipped\n";
        let p = ert(log);
        assert_eq!(
            p.counts,
            Counts {
                ran: 4,
                passed: 3,
                failed: 1,
                skipped: 1,
                crashed: 0
            }
        );
        assert_eq!(p.rows[1], ("drgnx-b".to_string(), RowVerdict::Fail));
        assert_eq!(judge(&p, &Expect::default()), Verdict::Red);
        // Emacs died before its summary: a crash
        let p = ert(b"Running 3 tests\n   passed  1/3  drgnx-a (0.001 sec)\n");
        assert_eq!((p.counts.ran, p.counts.crashed), (1, 1));
        assert_eq!(judge(&p, &Expect::default()), Verdict::Crash);
    }

    /// [D]
    #[test]
    fn cargo_parser_counts() {
        let log = b"running 4 tests\ntest a::one ... ok\ntest a::two ... FAILED\ntest a::three ... ignored\n\
            test a::four ... ignored, runner-host\ntest result: FAILED. 1 passed; 1 failed; 2 ignored\n\
            test b::x has been running for over 60 seconds\n\
            error: test failed, to rerun pass `--lib`\n\
            process didn't exit successfully: `/t/deps/c-1` (signal: 11, SIGSEGV: invalid memory reference)\n";
        let p = cargo_test(log);
        assert_eq!(
            p.counts,
            Counts {
                ran: 2,
                passed: 1,
                failed: 1,
                skipped: 2,
                crashed: 1
            }
        );
        assert_eq!(
            p.rows.iter().map(|r| r.0.as_str()).collect::<Vec<_>>(),
            ["a::one", "a::two", "a::three", "a::four"]
        );
        let p = plist(b"(:name \"frames p95\" :verdict pass :value 12)\n(:name \"rss\" :verdict fail)\nnoise\n(:name \"x\" :verdict skip)\n");
        assert_eq!(
            p.counts,
            Counts {
                ran: 2,
                passed: 1,
                failed: 1,
                skipped: 1,
                crashed: 0
            }
        );
        assert!(!exit(b"anything").counts_rows);
    }

    /// [D] A set that ran fewer rows than it expects, or skipped more than it may, is never a pass; the exit parser
    /// can't claim a row count at all.
    #[test]
    fn suspect_on_too_few_rows() {
        let p = cargo_test(b"test a ... ok\ntest b ... ok\ntest c ... ignored\n");
        let ex = |min: Option<u32>, max: Option<u32>| Expect {
            min_ran: min,
            max_skipped: max,
        };
        assert_eq!(judge(&p, &ex(Some(2), Some(1))), Verdict::Pass);
        assert!(
            matches!(judge(&p, &ex(Some(3), None)), Verdict::Suspect(s) if s.contains("ran 2 rows"))
        );
        assert!(
            matches!(judge(&p, &ex(None, Some(0))), Verdict::Suspect(s) if s.contains("skipped 1"))
        );
        assert!(
            matches!(judge(&exit(b""), &ex(Some(1), None)), Verdict::Suspect(s) if s.contains("counts none"))
        );
        assert_eq!(judge(&exit(b""), &ex(None, None)), Verdict::Pass);
        // an empty set with no expectation is a pass only for the exit parser's kind of job
        assert_eq!(
            judge(&ert(b"Running 0 tests\nRan 0 tests\n"), &ex(Some(1), None)),
            Verdict::Suspect("ran 0 rows, expected at least 1".into())
        );
    }
}
