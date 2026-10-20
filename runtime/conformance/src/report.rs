//! What a run prints, and the perf file.

use serde_json::{Value, json};
use std::path::Path;

pub enum Outcome {
    Pass,
    Skip { reason: String, excused: bool },
    Fail(String),
}

#[derive(Default)]
pub struct Report {
    pub passed: usize,
    pub skipped: usize,
    pub unexcused_skips: usize,
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
        }
    }

    pub fn summary(&self) -> String {
        format!(
            "{} passed, {} skipped, {} failed",
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

#[cfg(test)]
mod tests {
    use super::*;

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
