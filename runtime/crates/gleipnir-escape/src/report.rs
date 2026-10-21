//! The report: one `{row, status, reason}` per row (Task 14).

use crate::run::Outcome;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Pass,
    Fail,
    Skip,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub row: String,
    pub status: Status,
    pub reason: String,
}

impl Entry {
    pub fn new(row: &str, outcome: Outcome) -> Entry {
        let (status, reason) = match outcome {
            Outcome::Pass => (Status::Pass, String::new()),
            Outcome::Fail(r) => (Status::Fail, r),
            Outcome::Skip(r) => (Status::Skip, r),
        };
        Entry {
            row: row.to_string(),
            status,
            reason,
        }
    }
}

/// `(pass, fail, skip)`.
pub fn counts(entries: &[Entry]) -> (usize, usize, usize) {
    let n = |s: Status| entries.iter().filter(|e| e.status == s).count();
    (n(Status::Pass), n(Status::Fail), n(Status::Skip))
}

/// The exit code: 1 on a fail; with `require_all`, a skip is a fail too.
pub fn exit_code(entries: &[Entry], require_all: bool) -> i32 {
    let (_, fail, skip) = counts(entries);
    i32::from(fail > 0 || (require_all && skip > 0))
}

pub fn write(path: &Path, entries: &[Entry]) -> std::io::Result<()> {
    std::fs::write(
        path,
        serde_json::to_string_pretty(entries).expect("serializable") + "\n",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_codes() {
        let e = |o| Entry::new("r", o);
        let ok = vec![e(Outcome::Pass), e(Outcome::Skip("needs macos".into()))];
        assert_eq!(exit_code(&ok, false), 0);
        assert_eq!(
            exit_code(&ok, true),
            1,
            "--require-all turns skips into fails"
        );
        assert_eq!(exit_code(&[e(Outcome::Fail("x".into()))], false), 1);
        assert_eq!(counts(&ok), (1, 0, 1));
    }
}
