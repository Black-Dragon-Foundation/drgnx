//! Rows from a job's report or log, and the verdict they and the job's `expect` give.
//!
//! The registry is [`PARSERS`]; a preset or a stage names one, and an unknown name is refused by name:
//! - `exit`: no rows; the exit code alone decides, and such a job cannot claim `min_ran`.
//! - `regex:PATTERN`: a line per row, with the named groups `name` and `verdict` (`pass`, `fail`, `skip`).
//! - `tap`: TAP 13/14 (`ok N name`, `not ok N name`, `# SKIP`; `Bail out!` is a crash).
//! - `junit`: any JUnit XML report in the log (the stage prints it): pytest, gotestsum, Gradle, Maven surefire, ctest,
//!   jest, vitest and nextest, including nextest's `flakyFailure`.
//! - `libtest`: libtest's `test NAME ... ok|FAILED|ignored`; a test binary that died on a signal is a crash.
//! - `libtest-json`: libtest's `--format json` events.
//!
//! Nothing here knows a tool: the row's unit comes from the preset's naming rule, never from a parser.

mod junit;
mod libtest;
mod regexp;
mod tap;

use forseti::{Expect, Row, RowClass, Verdict};
use serde::{Deserialize, Serialize};

/// The parsers a stage may name (the `regex` parser's pattern follows a `:`).
pub const PARSERS: [&str; 6] = ["exit", "regex", "tap", "junit", "libtest", "libtest-json"];

/// Which parser reads a job's log. On the wire it is its name (`libtest`, `regex:^(?P<name>…)`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Parser {
    #[default]
    Exit,
    Regex(String),
    Tap,
    Junit,
    Libtest,
    LibtestJson,
}

impl Parser {
    /// The parser NAME names; an unknown name, and a bad `regex` pattern, are refused by name.
    pub fn from_name(name: &str) -> villa::Result<Parser> {
        if let Some(pattern) = name.strip_prefix("regex:") {
            regexp::compile(pattern)?;
            return Ok(Parser::Regex(pattern.to_string()));
        }
        Ok(match name {
            "" | "exit" => Parser::Exit,
            "tap" => Parser::Tap,
            "junit" => Parser::Junit,
            "libtest" => Parser::Libtest,
            "libtest-json" => Parser::LibtestJson,
            "regex" => {
                return Err(villa::Error::invalid(
                    "the parser regex needs its pattern: regex:PATTERN, with the named groups name and verdict",
                ));
            }
            other => {
                return Err(villa::Error::invalid(format!(
                    "no row parser {other:?} (the parsers are {})",
                    PARSERS.join(", ")
                )));
            }
        })
    }

    /// The name the wire and the key carry.
    pub fn name(&self) -> String {
        match self {
            Parser::Exit => "exit".into(),
            Parser::Regex(p) => format!("regex:{p}"),
            Parser::Tap => "tap".into(),
            Parser::Junit => "junit".into(),
            Parser::Libtest => "libtest".into(),
            Parser::LibtestJson => "libtest-json".into(),
        }
    }
}

impl Serialize for Parser {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.name())
    }
}

impl<'de> Deserialize<'de> for Parser {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Parser, D::Error> {
        let name = String::deserialize(d)?;
        Parser::from_name(&name).map_err(serde::de::Error::custom)
    }
}

/// A row's own outcome as the result file and the `row` frames carry it (a failed row of class crash is `crash`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RowVerdict {
    Pass,
    Fail,
    Skip,
    Crash,
}

impl RowVerdict {
    pub fn of(row: &Row) -> RowVerdict {
        use forseti::RowVerdict as V;
        match (row.verdict, row.class) {
            (V::Pass, _) => RowVerdict::Pass,
            (V::Skip, _) => RowVerdict::Skip,
            (V::Fail, Some(RowClass::Crash)) => RowVerdict::Crash,
            (V::Fail, _) => RowVerdict::Fail,
        }
    }
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
    pub rows: Vec<Row>,
    pub counts_rows: bool,
    /// Crashes that name no row (a test binary that died on a signal).
    pub anonymous_crashes: u32,
}

impl Parsed {
    pub(crate) fn counting() -> Parsed {
        Parsed {
            counts_rows: true,
            ..Default::default()
        }
    }

    /// Adds ROW; a name seen again keeps its worst verdict (a rerun's pass never hides a red).
    pub(crate) fn push(&mut self, row: Row) {
        if let Some(old) = self.rows.iter_mut().find(|r| r.name == row.name) {
            if row.verdict > old.verdict {
                *old = row;
            }
        } else {
            self.rows.push(row);
        }
    }

    /// The failed and crashed rows' names.
    pub fn failing(&self) -> Vec<String> {
        self.rows
            .iter()
            .filter(|r| r.failed())
            .map(|r| r.name.clone())
            .collect()
    }

    /// Counts the rows, once every row is in.
    pub(crate) fn finish(mut self) -> Parsed {
        let mut c = Counts {
            crashed: self.anonymous_crashes,
            ..Counts::default()
        };
        for r in &self.rows {
            match RowVerdict::of(r) {
                RowVerdict::Pass => c.passed += 1,
                RowVerdict::Fail => c.failed += 1,
                RowVerdict::Skip => c.skipped += 1,
                RowVerdict::Crash => c.crashed += 1,
            }
            if r.verdict != forseti::RowVerdict::Skip {
                c.ran += 1;
            }
        }
        self.counts = c;
        self
    }
}

/// Reads LOG with PARSER.
pub fn parse(parser: &Parser, log: &[u8]) -> Parsed {
    match parser {
        Parser::Exit => Parsed::default(),
        Parser::Regex(p) => regexp::parse(p, log),
        Parser::Tap => tap::parse(log),
        Parser::Junit => junit::parse(log),
        Parser::Libtest => libtest::parse(log),
        Parser::LibtestJson => libtest::parse_json(log),
    }
}

/// The rows of several sources as one set: a name in two sources is an error (two reports of one test are two stories).
pub fn merge(sources: Vec<Vec<Row>>) -> villa::Result<Vec<Row>> {
    let mut out: Vec<Row> = Vec::new();
    for rows in sources {
        for r in rows {
            if out.iter().any(|o| o.name == r.name) {
                return Err(villa::Error::conflict(format!(
                    "the row {:?} is in two reports",
                    r.name
                )));
            }
            out.push(r);
        }
    }
    Ok(out)
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

    fn names(p: &Parsed) -> Vec<&str> {
        p.rows.iter().map(|r| r.name.as_str()).collect()
    }

    /// [D]
    #[test]
    fn libtest_counts_and_a_dead_binary_is_a_crash() {
        let log = b"running 4 tests\ntest a::one ... ok\ntest a::two ... FAILED\ntest a::three ... ignored\n\
            test a::four ... ignored, runner-host\ntest result: FAILED. 1 passed; 1 failed; 2 ignored\n\
            test b::x has been running for over 60 seconds\n\
            error: test failed, to rerun pass `--lib`\n\
            process didn't exit successfully: `/t/deps/c-1` (signal: 11, SIGSEGV: invalid memory reference)\n";
        let p = parse(&Parser::Libtest, log);
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
        assert_eq!(names(&p), ["a::one", "a::two", "a::three", "a::four"]);
        assert!(!parse(&Parser::Exit, b"anything").counts_rows);
    }

    /// [D] A set that ran fewer rows than it expects, or skipped more than it may, is never a pass; the exit parser
    /// can't claim a row count at all.
    #[test]
    fn suspect_on_too_few_rows() {
        let p = parse(
            &Parser::Libtest,
            b"test a ... ok\ntest b ... ok\ntest c ... ignored\n",
        );
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
        let exit = parse(&Parser::Exit, b"");
        assert!(
            matches!(judge(&exit, &ex(Some(1), None)), Verdict::Suspect(s) if s.contains("counts none"))
        );
        assert_eq!(judge(&exit, &ex(None, None)), Verdict::Pass);
        let empty = parse(&Parser::Libtest, b"running 0 tests\n");
        assert_eq!(
            judge(&empty, &ex(Some(1), None)),
            Verdict::Suspect("ran 0 rows, expected at least 1".into())
        );
    }

    /// [D]
    #[test]
    fn an_unknown_parser_is_refused_by_name() {
        let e = Parser::from_name("ert").unwrap_err().to_string();
        assert!(e.contains("\"ert\"") && e.contains("libtest-json"), "{e}");
        assert!(Parser::from_name("plist").is_err());
        assert!(
            Parser::from_name("regex").is_err(),
            "regex needs its pattern"
        );
        assert!(
            Parser::from_name("regex:(").is_err(),
            "a bad pattern is refused"
        );
        for n in PARSERS.iter().filter(|n| **n != "regex") {
            assert_eq!(Parser::from_name(n).unwrap().name(), *n);
        }
        let p = Parser::from_name("regex:^(?P<name>\\w+) (?P<verdict>\\w+)$").unwrap();
        let back: Parser = serde_json::from_str(&serde_json::to_string(&p).unwrap()).unwrap();
        assert_eq!(back, p);
    }

    /// [D]
    #[test]
    fn a_duplicate_row_name_is_an_error() {
        let a = vec![Row::pass("t::one")];
        let b = vec![Row::pass("t::two"), Row::pass("t::one")];
        let e = merge(vec![a.clone(), b]).unwrap_err().to_string();
        assert!(e.contains("t::one"), "{e}");
        let ok = merge(vec![a, vec![Row::pass("t::two")]]).unwrap();
        assert_eq!(ok.len(), 2);
        // inside one report a name seen twice keeps its worst
        let mut p = Parsed::counting();
        p.push(Row::pass("x"));
        p.push(Row::fail("x", RowClass::Assert));
        p.push(Row::pass("x"));
        let p = p.finish();
        assert_eq!((p.counts.ran, p.counts.failed), (1, 1));
    }
}
