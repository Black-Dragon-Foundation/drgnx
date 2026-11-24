//! One result row, whatever tool printed it (docs/develop/forseti.md, "Rows"). The parsers in `sleipnir::linux::parse`
//! produce it, the hub stores and shows it, and a tool's own words (a test's name, an excerpt of its failure) are
//! carried as data. Pure.

use serde::{Deserialize, Serialize};

/// A row's own outcome. Ordered from best to worst: a name seen twice keeps its worst.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RowVerdict {
    Pass,
    Skip,
    Fail,
}

/// Why a row failed, in the tool's signals mapped to one vocabulary.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RowClass {
    /// An assertion or a panic in the test itself.
    Assert,
    /// The test didn't build (a compile error); [`Row::missing`] may name what was missing.
    Build,
    /// Any other error the test raised.
    Error,
    /// The job or the test ran out of time.
    Timeout,
    /// The test's process died (a signal, a bail-out).
    Crash,
    /// The machine, not the test (a lost job, a relay that ended).
    Infra,
    /// The report contradicts itself (a parent that passes over a failing child).
    Inconsistent,
}

/// One row of a job's result.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub name: String,
    pub verdict: RowVerdict,
    /// A failure's class; none for a pass or a skip.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class: Option<RowClass>,
    /// The symbols a [`RowClass::Build`] failure says are missing.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub missing: Vec<String>,
    /// A few lines of the failure, as the tool printed them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub excerpt: Option<String>,
}

impl Row {
    pub fn pass(name: &str) -> Row {
        Row::new(name, RowVerdict::Pass, None)
    }

    pub fn skip(name: &str) -> Row {
        Row::new(name, RowVerdict::Skip, None)
    }

    pub fn fail(name: &str, class: RowClass) -> Row {
        Row::new(name, RowVerdict::Fail, Some(class))
    }

    fn new(name: &str, verdict: RowVerdict, class: Option<RowClass>) -> Row {
        Row {
            name: name.to_string(),
            verdict,
            class,
            missing: Vec::new(),
            excerpt: None,
        }
    }

    pub fn with_excerpt(mut self, excerpt: impl Into<String>) -> Row {
        self.excerpt = Some(excerpt.into());
        self
    }

    pub fn with_missing(mut self, missing: Vec<String>) -> Row {
        self.missing = missing;
        self
    }

    /// Whether the row counts as a red one for a gate: a failure of any class.
    pub fn failed(&self) -> bool {
        self.verdict == RowVerdict::Fail
    }

    /// Whether the test's process died rather than failed an assertion.
    pub fn crashed(&self) -> bool {
        self.class == Some(RowClass::Crash)
    }
}

/// The verdict of a stage from its check summary's `rc=` word (`drgnx-check.sh`'s `summary.txt`): `0` passes, another
/// number is a red, and `no-result` (the stage never reported: its container died on the memory guard, the slot guard
/// or a lost link) is the machine's failure, never the test's.
pub fn stage_verdict(rc: &str) -> crate::model::Verdict {
    use crate::model::Verdict;
    match rc.trim() {
        "0" => Verdict::Pass,
        "no-result" | "" => Verdict::Infra("the stage never reported a result".into()),
        n if n.bytes().all(|b| b.is_ascii_digit()) => Verdict::Red,
        other => Verdict::Infra(format!("the stage's result {other:?} is not an exit code")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stage_that_never_reported_is_infra_never_red() {
        // [D] pure: today's `drgnx-check.sh` prints `rc=no-result` for a stage whose container died
        use crate::model::Verdict;
        assert_eq!(stage_verdict("0"), Verdict::Pass);
        assert_eq!(stage_verdict("101"), Verdict::Red);
        assert!(matches!(stage_verdict("no-result"), Verdict::Infra(_)));
        assert!(matches!(stage_verdict("x"), Verdict::Infra(_)));
    }

    #[test]
    fn a_row_keeps_its_worst_verdict_by_order() {
        // [D] pure
        assert!(RowVerdict::Pass < RowVerdict::Skip && RowVerdict::Skip < RowVerdict::Fail);
    }

    #[test]
    fn a_row_round_trips_without_its_empty_fields() {
        // [D] pure: a pass is `{name, verdict}`; a build failure carries its missing symbols
        let pass = serde_json::to_string(&Row::pass("a::b")).unwrap();
        assert_eq!(pass, r#"{"name":"a::b","verdict":"pass"}"#);
        let red = Row::fail("c", RowClass::Build).with_missing(vec!["f".into()]);
        let back: Row = serde_json::from_str(&serde_json::to_string(&red).unwrap()).unwrap();
        assert_eq!(back, red);
        assert!(back.failed() && !back.crashed());
        assert!(Row::fail("d", RowClass::Crash).crashed());
    }
}
