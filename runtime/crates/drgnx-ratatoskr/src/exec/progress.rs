//! A job's progress as events (docs/develop/hub.md, "Job progress"): a job whose command says `--progress FILE`
//! (`drgnx sync`, `upgrade`, `rollback`, `extensions refresh`) replaces FILE at each step and writes FILE.plan.json
//! before each swap. While it runs, the hub looks at both every [`EVERY`] and once more at its end, and sends what
//! changed as `exec-progress {id, file, step}` and `exec-progress {id, file, plan}` to the editors (FILE the
//! progress file), so the editor reads no file.
//! The core ([`Watch`]) is pure: it is given what a look read and answers the events.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// How often a running job's progress is looked at (the editor read it at most four times a second).
pub const EVERY: Duration = Duration::from_millis(250);
/// The largest progress or plan file read (a step is at most 1 KiB, a plan names every package of a swap).
pub const MAX_BYTES: u64 = 1 << 20;

/// The progress file ARGV names (`--progress FILE`), if it names one.
pub fn file_of(argv: &[String]) -> Option<PathBuf> {
    let i = argv.iter().position(|a| a == "--progress")?;
    argv.get(i + 1).filter(|f| !f.is_empty()).map(PathBuf::from)
}

/// FILE's plan file.
pub fn plan_of(file: &Path) -> PathBuf {
    let mut s = file.as_os_str().to_owned();
    s.push(".plan.json");
    PathBuf::from(s)
}

/// What one look at a file found: its modification time and contents, or none (no file yet, or unreadable).
pub type Seen = Option<(SystemTime, Vec<u8>)>;

/// One job's two files as last sent.
#[derive(Debug, Default)]
pub struct Watch {
    step: Option<(SystemTime, Vec<u8>)>,
    plan: Option<(SystemTime, Vec<u8>)>,
}

fn changed(last: &mut Option<(SystemTime, Vec<u8>)>, seen: Seen) -> Option<Value> {
    let (t, bytes) = seen?;
    if last
        .as_ref()
        .is_some_and(|(lt, lb)| *lt == t && *lb == bytes)
    {
        return None;
    }
    let v: Value = serde_json::from_slice(&bytes)
        .ok()
        .filter(Value::is_object)?;
    *last = Some((t, bytes));
    Some(v)
}

impl Watch {
    /// The events of job ID for a look that found STEP and PLAN: the plan first (a reader repoints before the swap's
    /// step says it swapped), then the step; nothing for a file that did not change or is not a JSON object yet (a
    /// writer replaces it by rename, so a half-written file is never seen).
    pub fn look(&mut self, id: &str, step: Seen, plan: Seen) -> Vec<Value> {
        let mut out = Vec::new();
        if let Some(p) = changed(&mut self.plan, plan) {
            out.push(json!({"id": id, "plan": p}));
        }
        if let Some(s) = changed(&mut self.step, step) {
            out.push(json!({"id": id, "step": s}));
        }
        out
    }
}

/// FILE as one look reads it.
pub fn read(file: &Path) -> Seen {
    let m = std::fs::metadata(file).ok()?;
    if m.len() > MAX_BYTES {
        return None;
    }
    let t = m.modified().ok()?;
    std::fs::read(file).ok().map(|b| (t, b))
}

#[cfg(test)]
mod tests;
