//! One fact a gate reads: a hub job's end (or a gate's own finding) bound to a task, with the job's facts and rows.

use crate::facts::Facts;
use crate::rows::Row;
use serde::{Deserialize, Serialize};

/// The kinds of evidence.  `red` and `green` are a task's own jobs as they ended (failing rows or none); the gates
/// write the others.
pub const KINDS: &[&str] = &[
    "red",
    "green",
    "author-check",
    "group",
    "full-run",
    "review",
    "merge-notes",
    "waiver",
];

/// The most rows one evidence record keeps: the failed rows always, then passes and skips up to this many.
pub const MAX_ROWS: usize = 5000;

/// One evidence record.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Evidence {
    /// One of [`KINDS`].
    pub kind: String,
    /// The task it is evidence for (`task:JOB#N`).
    pub task: String,
    /// The hub job it comes from (empty for a gate's own finding, such as a waiver).
    #[serde(default)]
    pub job: String,
    pub facts: Facts,
    #[serde(default)]
    pub rows: Vec<Row>,
    /// Rows were left out past [`MAX_ROWS`] (never a failed one).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub truncated: bool,
    /// Seconds since the epoch.
    pub at: f64,
    /// A gate's words (a waiver's reason, what a held gate needs).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// ROWS cut to [`MAX_ROWS`], failed rows first kept: the rows kept, and whether any were left out.
pub fn bounded(rows: Vec<Row>) -> (Vec<Row>, bool) {
    if rows.len() <= MAX_ROWS {
        return (rows, false);
    }
    let fails = rows
        .iter()
        .filter(|r| r.verdict == crate::rows::Verdict::Fail)
        .count();
    let mut room = MAX_ROWS.saturating_sub(fails);
    let kept = rows
        .into_iter()
        .filter(|r| {
            if r.verdict == crate::rows::Verdict::Fail {
                return true;
            }
            if room > 0 {
                room -= 1;
                return true;
            }
            false
        })
        .collect();
    (kept, true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rows::parse;

    #[test]
    fn bounded_keeps_every_failure() {
        let mut log = String::new();
        for i in 0..MAX_ROWS + 10 {
            log.push_str(&format!("test p{i} ... ok\n"));
        }
        log.push_str("test bad ... FAILED\n");
        let (kept, cut) = bounded(parse(&log));
        assert!(cut);
        assert_eq!(kept.len(), MAX_ROWS);
        assert!(kept.iter().any(|r| r.name == "bad"));
        let (small, cut) = bounded(parse("test a ... ok\n"));
        assert_eq!((small.len(), cut), (1, false));
    }
}
