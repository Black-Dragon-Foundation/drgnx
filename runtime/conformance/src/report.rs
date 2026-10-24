//! What a run prints, and the perf file.

use serde_json::{Value, json};
use std::path::Path;

pub enum Outcome {
    Pass,
    Skip {
        reason: String,
        excused: bool,
    },
    Fail(String),
    /// A `pending` row that failed, as its mark expects: no failure.
    Pending {
        reason: String,
        what: String,
    },
}

#[derive(Default)]
pub struct Report {
    pub passed: usize,
    pub skipped: usize,
    pub unexcused_skips: usize,
    pub pending: usize,
    pub failed: usize,
    /// `measure` results: (name, milliseconds of each repeat).
    pub perf: Vec<(String, Vec<f64>)>,
}

impl Report {
    /// Print the scenario's line and count it.
    pub fn add(&mut self, name: &str, outcome: &Outcome) {
        match outcome {
            Outcome::Pass => {
                self.passed += 1;
                println!("PASS {name}");
            }
            Outcome::Skip { reason, excused } => {
                self.skipped += 1;
                if !excused {
                    self.unexcused_skips += 1;
                }
                println!("SKIP {name} ({reason})");
            }
            Outcome::Fail(what) => {
                self.failed += 1;
                println!("FAIL {name}: {what}");
            }
            Outcome::Pending { reason, what } => {
                self.pending += 1;
                println!("PENDING {name} ({reason}): {what}");
            }
        }
    }

    pub fn summary(&self) -> String {
        let pending = if self.pending > 0 {
            format!(", {} pending", self.pending)
        } else {
            String::new()
        };
        format!(
            "{} passed, {} skipped{pending}, {} failed",
            self.passed, self.skipped, self.failed
        )
    }

    /// Exit 0 only with no FAIL; with `--require-all` a SKIP fails too unless its tag excuses it.
    pub fn exit_code(&self, require_all: bool) -> i32 {
        i32::from(self.failed > 0 || (require_all && self.unexcused_skips > 0))
    }

    pub fn write_perf(&self, path: &Path) -> Result<(), String> {
        let rows: Vec<Value> = self
            .perf
            .iter()
            .map(|(name, ms)| {
                let mut sorted = ms.clone();
                sorted.sort_by(f64::total_cmp);
                let median = sorted.get(sorted.len() / 2).copied().unwrap_or(0.0);
                json!({"name": name, "repeats": ms.len(), "ms": ms, "median_ms": median})
            })
            .collect();
        let text = serde_json::to_string_pretty(&json!({"measurements": rows}))
            .map_err(|e| e.to_string())?;
        std::fs::write(path, text + "\n")
            .map_err(|e| format!("cannot write {}: {e}", path.display()))
    }
}

/// A run's outcome under the row's `pending` mark (none: as it ran).  A pending row that fails is expected; one that
/// passes is a failure, so the mark is removed once its task lands.
pub fn judge(ran: Result<(), String>, pending: Option<&str>) -> Outcome {
    match (ran, pending) {
        (Ok(()), None) => Outcome::Pass,
        (Err(what), None) => Outcome::Fail(what),
        (Err(what), Some(reason)) => Outcome::Pending {
            reason: reason.to_string(),
            what,
        },
        (Ok(()), Some(reason)) => Outcome::Fail(format!(
            "it passes now: remove its \"pending\" mark ({reason})"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pending_row_fails_as_expected_and_a_pass_fails_the_run() {
        let mut r = Report::default();
        r.add("p", &judge(Err("step 3".into()), Some("Task 16a")));
        assert_eq!((r.pending, r.failed), (1, 0));
        assert_eq!(r.exit_code(true), 0);
        assert_eq!(r.summary(), "0 passed, 0 skipped, 1 pending, 0 failed");
        r.add("q", &judge(Ok(()), Some("Task 16a")));
        assert_eq!(r.failed, 1, "a pending row that passes fails the run");
        assert!(matches!(judge(Ok(()), None), Outcome::Pass));
        assert!(matches!(judge(Err(String::new()), None), Outcome::Fail(_)));
    }

    #[test]
    fn exit_codes() {
        let mut r = Report {
            skipped: 1,
            unexcused_skips: 1,
            ..Report::default()
        };
        assert_eq!(r.exit_code(false), 0);
        assert_eq!(
            r.exit_code(true),
            1,
            "--require-all fails a skip nothing excuses"
        );
        r.unexcused_skips = 0;
        assert_eq!(r.exit_code(true), 0);
        r.failed = 1;
        assert_eq!(r.exit_code(false), 1);
    }
}
