//! A job's summary (Task 11): cargo test, ERT and domr output read for failing names, at most 20 lines, as
//! `runstav::methods::exec::ExecSummary`.

use super::CheckKind;
use runstav::methods::exec::ExecSummary;

/// The most lines a summary keeps.
pub const MAX_LINES: usize = 20;
/// The most failing names a summary keeps.
const MAX_FAILING: usize = 50;
/// The longest line kept, in characters.
const MAX_LINE: usize = 300;

/// The failing test names in TEXT (a job's whole log) for KIND, in order of appearance, each once.
///
/// - cargo: `test NAME ... FAILED`;
/// - ERT (batch): `   FAILED  12/340  NAME`;
/// - domr: `FAIL NAME: what`.
pub fn failing(kind: CheckKind, text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for line in text.lines() {
        let name = match kind {
            CheckKind::Cargo => cargo_name(line),
            CheckKind::Ert => ert_name(line),
            CheckKind::Domr => domr_name(line),
            CheckKind::Other => None,
        };
        if let Some(n) = name
            && !out.iter().any(|o| o == n)
            && out.len() < MAX_FAILING
        {
            out.push(n.to_string());
        }
    }
    out
}

fn cargo_name(line: &str) -> Option<&str> {
    let rest = line.strip_prefix("test ")?;
    rest.strip_suffix(" ... FAILED")
}

fn ert_name(line: &str) -> Option<&str> {
    let mut words = line.split_whitespace();
    if words.next()? != "FAILED" {
        return None;
    }
    let count = words.next()?;
    if !count.contains('/') {
        return None;
    }
    words.next()
}

fn domr_name(line: &str) -> Option<&str> {
    let rest = line.strip_prefix("FAIL ")?;
    Some(rest.split(':').next().unwrap_or(rest).trim()).filter(|n| !n.is_empty())
}

/// The summary of a job that ended with EXIT: the failing names and at most [`MAX_LINES`] lines of TEXT — the lines
/// that name a failure first (up to half), then the end of the log (where the totals are).  LOG is the log's path.
pub fn summarise(kind: CheckKind, exit: Option<i32>, text: &str, log: &str) -> ExecSummary {
    let failing = failing(kind, text);
    let all: Vec<&str> = text.lines().collect();
    let is_failure = |l: &str| {
        failing.iter().any(|n| l.contains(n.as_str()))
            && (l.contains("FAIL") || l.contains("panicked"))
    };
    let head: Vec<usize> = (0..all.len())
        .filter(|&i| is_failure(all[i]))
        .take(MAX_LINES / 2)
        .collect();
    let tail_n = MAX_LINES - head.len();
    let tail_from = all.len().saturating_sub(tail_n);
    let mut keep: Vec<usize> = head;
    let tail: Vec<usize> = (tail_from..all.len())
        .filter(|i| !keep.contains(i))
        .collect();
    keep.extend(tail);
    keep.sort_unstable();
    keep.truncate(MAX_LINES);
    let lines = keep
        .into_iter()
        .map(|i| all[i].chars().take(MAX_LINE).collect())
        .collect();
    ExecSummary {
        exit,
        failing,
        lines,
        log: log.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cargo_failures() {
        let log = "running 3 tests\ntest a::ok ... ok\ntest a::bad ... FAILED\ntest b::worse ... FAILED\n\
                   \nfailures:\n    a::bad\n    b::worse\n\ntest result: FAILED. 1 passed; 2 failed\n";
        assert_eq!(
            failing(CheckKind::Cargo, log),
            vec!["a::bad".to_string(), "b::worse".to_string()]
        );
        let s = summarise(CheckKind::Cargo, Some(101), log, "/l");
        assert_eq!((s.exit, s.log.as_str()), (Some(101), "/l"));
        assert!(s.lines.iter().any(|l| l.contains("test result: FAILED")));
        assert!(failing(CheckKind::Cargo, "test a ... ok\n").is_empty());
    }

    #[test]
    fn ert_failures() {
        let log = "Running 4 tests\n   passed  1/4  t-one\n   FAILED  2/4  t-two\n   FAILED  3/4  t-three\n\
                   \nRan 4 tests, 2 results as expected, 2 unexpected\n";
        assert_eq!(
            failing(CheckKind::Ert, log),
            vec!["t-two".to_string(), "t-three".to_string()]
        );
        assert!(failing(CheckKind::Ert, "FAILED to start\n").is_empty());
    }

    #[test]
    fn domr_failures() {
        let log = "PASS a/b\nFAIL launch/x: expected y within 50 ms\nSKIP c/d (no bwrap)\nFAIL k/z: bad\nFAIL k/z: again\n";
        assert_eq!(
            failing(CheckKind::Domr, log),
            vec!["launch/x".to_string(), "k/z".to_string()]
        );
        assert!(failing(CheckKind::Other, log).is_empty());
    }

    #[test]
    fn at_most_20_lines() {
        let mut log = String::new();
        for i in 0..100 {
            log.push_str(&format!("test t{i} ... FAILED\n"));
        }
        for i in 0..100 {
            log.push_str(&format!("noise {i}\n"));
        }
        let s = summarise(CheckKind::Cargo, Some(101), &log, "/l");
        assert_eq!(s.lines.len(), MAX_LINES);
        assert_eq!(s.failing.len(), 50);
        assert_eq!(s.lines.last().unwrap(), "noise 99");
        assert!(s.lines[0].contains("t0 "));
        let long = "x".repeat(2000);
        let s = summarise(CheckKind::Other, Some(0), &long, "/l");
        assert_eq!(s.lines[0].chars().count(), MAX_LINE);
        assert!(summarise(CheckKind::Other, None, "", "/l").lines.is_empty());
    }
}
