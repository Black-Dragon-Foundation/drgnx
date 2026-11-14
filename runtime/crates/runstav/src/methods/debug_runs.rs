//! Recorded runs and probes (docs/develop/debugging.md, spec §19.2, §19.8): a project's probes (`debug/probe/op`), its
//! runs (`debug/runs/list`), one run's strip (`debug/run/get`), a past stop (`debug/run/stop`) and pinning a run
//! (`debug/run/pin`). Run files hold the program's values unredacted, so these are the user's alone (an agent reads
//! them only through the matrix's `debug.read`, spec §19.5). The hub's events: `debug-run` (a run started, stopped,
//! ended), `debug-probe-hits` (batched, at most 20 a second) and `debug-recording-off` (a session not recorded: the
//! keyring that holds the runs' key is locked or absent; `why`, and `short`, the status bar's few words).

use super::{invalid, method};
use crate::registry::Method;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The longest path, id, expression or name a message carries, in bytes.
pub const TEXT_MAX: usize = 4096;
/// The largest file text `debug/probe/op` takes (to place "Probe the result").
pub const FILE_MAX: usize = 4 << 20;
/// The most stops one page of `debug/run/get` holds.
pub const PAGE_MAX: u32 = 1000;

/// `debug/probe/op`: ROOT's probes, after OP when given.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugProbeOp {
    pub root: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub op: Option<DebugProbeChange>,
}

/// One change to a project's probes: `add` (PATH, LINE, EXPR), `result` ("Probe the result": EXPR, which LINE
/// assigns, recorded on the next line that runs; TEXT is the file as the editor has it, LANGUAGE its language),
/// `remove` (ID) and `edit` (ID, and EXPR, ENABLED or LINE).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugProbeChange {
    pub op: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
}

/// The operations `debug/probe/op` knows.
pub const PROBE_OPS: &[&str] = &["add", "result", "remove", "edit"];

/// A project's probes (`{id, path, line, expr, enabled}`), the path OP changed and the probe it ADDED.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugProbes {
    pub root: String,
    pub probes: Vec<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub added: Option<String>,
}

/// `debug/runs/list`: ROOT's recorded runs, newest first.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugRunsList {
    pub root: String,
}

/// The runs: each `{id, n, name, started, ended?, outcome?, stops, hits, thinned, dropped, pinned, task?, …}`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugRuns {
    pub runs: Vec<Value>,
}

/// `debug/run/get`: run RUN for the strip: COUNT of its stops from FROM (0-based), and the probes' lanes over them.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugRunGet {
    pub run: String,
    #[serde(default)]
    pub from: u32,
    #[serde(default = "page")]
    pub count: u32,
    /// The stop (its `index`) the strip rings.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current: Option<u64>,
}

fn page() -> u32 {
    200
}

/// A run's page: its record, the stops (`{index, t_ms, reason, thread, path, line, bp_hit?, steps?, session}`), how
/// many it has, the lanes (`{probe, expr, path, line, hits: [{seq, t, thread, value}], shown_from}`), whether more
/// stops follow, and the strip's rows (docs/develop/hub.md, "Rows": a head, the lane of stops, one lane per probe).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugRunView {
    pub run: Value,
    pub stops: Vec<Value>,
    pub total: u64,
    pub lanes: Vec<Value>,
    pub more: bool,
    #[serde(default)]
    pub strip: Vec<Value>,
}

/// `debug/run/stop`: stop STOP (its `index`) of run RUN, with FILE as it ran (the stop's own file when absent).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugRunStop {
    pub run: String,
    pub stop: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
}

/// A past stop: the stop, its capture (threads, frames, scopes and variables as fetched then; `cut` counts what the
/// 64 KB cap left out), the launch snapshot's tree, and the file `{path, text, not_what_ran}` (text null: not in the
/// snapshot).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugPastStop {
    pub run: String,
    pub stop: Value,
    pub capture: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<String>,
    pub source: Value,
}

/// `debug/run/pin`: keep run RUN past the retention (PINNED), or not.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugRunPin {
    pub run: String,
    pub pinned: bool,
}

/// `debug/run/export`: run RUN (ended) sealed into the file PATH (absolute; replaced) under a one-time key, for the user
/// to send: the file, its size and the share code that opens it. The code is shown once and never stored.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugRunExport {
    pub run: String,
    pub path: String,
}

/// What `debug/run/export` made.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugRunExported {
    pub path: String,
    /// 52 letters and digits in groups of four: the only way to open the file.
    pub code: String,
    pub bytes: u64,
}

/// `debug/run/import`: the run someone sent (the file PATH, opened with CODE) added to project ROOT's runs, read-only
/// (never run here: no forks); its paths are moved under ROOT.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugRunImport {
    pub root: String,
    pub path: String,
    pub code: String,
}

/// The run `debug/run/import` added.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugRunImported {
    pub run: String,
}

fn check_text(path: &str, s: &str) -> Result<(), Error> {
    if s.is_empty() || s.len() > TEXT_MAX {
        return Err(invalid(path, "a non-empty text of at most 4096 bytes"));
    }
    Ok(())
}

fn check_abs(path: &str, s: &str) -> Result<(), Error> {
    check_text(path, s)?;
    if !s.starts_with('/') {
        return Err(invalid(path, "an absolute path"));
    }
    Ok(())
}

fn check_run(run: &str) -> Result<(), Error> {
    check_text("run", run)?;
    if !run.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return Err(invalid("run", "a run id"));
    }
    Ok(())
}

fn check_probe_op(p: &DebugProbeOp) -> Result<(), Error> {
    check_abs("root", &p.root)?;
    let Some(op) = &p.op else { return Ok(()) };
    if !PROBE_OPS.contains(&op.op.as_str()) {
        return Err(invalid("op.op", "one of add, result, remove, edit"));
    }
    if let Some(e) = &op.expr {
        check_text("op.expr", e)?;
    }
    if op.text.as_ref().is_some_and(|t| t.len() > FILE_MAX) {
        return Err(invalid("op.text", "at most 4 MB"));
    }
    let need = |k: &str, ok: bool| {
        if ok {
            Ok(())
        } else {
            Err(invalid(k, "required by this op"))
        }
    };
    match op.op.as_str() {
        "add" | "result" => {
            check_abs("op.path", op.path.as_deref().unwrap_or_default())?;
            need("op.line", op.line.is_some_and(|l| l > 0))?;
            need("op.expr", op.expr.is_some())?;
            if op.op == "result" {
                need("op.text", op.text.is_some())?;
            }
            Ok(())
        }
        _ => check_text("op.id", op.id.as_deref().unwrap_or_default()),
    }
}

fn check_list(p: &DebugRunsList) -> Result<(), Error> {
    check_abs("root", &p.root)
}

fn check_get(p: &DebugRunGet) -> Result<(), Error> {
    check_run(&p.run)?;
    if p.count == 0 || p.count > PAGE_MAX {
        return Err(invalid("count", "from 1 to 1000 stops"));
    }
    Ok(())
}

fn check_stop(p: &DebugRunStop) -> Result<(), Error> {
    check_run(&p.run)?;
    if let Some(f) = &p.file {
        check_abs("file", f)?;
    }
    Ok(())
}

fn check_pin(p: &DebugRunPin) -> Result<(), Error> {
    check_run(&p.run)
}

fn check_export(p: &DebugRunExport) -> Result<(), Error> {
    check_run(&p.run)?;
    check_abs("path", &p.path)
}

fn check_import(p: &DebugRunImport) -> Result<(), Error> {
    check_abs("root", &p.root)?;
    check_abs("path", &p.path)?;
    if p.code.is_empty() || p.code.len() > 128 {
        return Err(invalid("code", "a share code"));
    }
    Ok(())
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "debug/probe/op", DebugProbeOp(DebugProbeOp) -> DebugProbes,
            classes: [User], writes: false,
            doc: "a project's probes (logpoints whose values are recorded, never printed): add one, add one for what a line assigns on the next line that runs, edit or remove one; it reaches the project's sessions at once",
            check: check_probe_op,
        ),
        method!(
            "debug/run/export", DebugRunExport(DebugRunExport) -> DebugRunExported,
            classes: [User], writes: false,
            doc: "send a recorded run: it and the files that ran, sealed into one file under a one-time key; the answer's share code opens it and is shown once, never stored (the hub sends nothing)",
            check: check_export,
        ),
        method!(
            "debug/run/get", DebugRunGet(DebugRunGet) -> DebugRunView,
            classes: [User], writes: false,
            doc: "a recorded run for the stop timeline: a page of its stops and each probe's values over them",
            check: check_get,
        ),
        method!(
            "debug/run/import", DebugRunImport(DebugRunImport) -> DebugRunImported,
            classes: [User], writes: false,
            doc: "add a run someone sent (its file and share code) to a project's runs: read-only, its stops readable, its program never run here",
            check: check_import,
        ),
        method!(
            "debug/run/pin", DebugRunPin(DebugRunPin) -> bool,
            classes: [User], writes: false,
            doc: "keep a recorded run past the 14 days, or let it go with the others",
            check: check_pin,
        ),
        method!(
            "debug/run/stop", DebugRunStop(DebugRunStop) -> DebugPastStop,
            classes: [User], writes: false,
            doc: "a past stop of a recorded run: its variables and stack as captured then, and a file as it ran (from the launch snapshot), marked when it was unsaved at the launch",
            check: check_stop,
        ),
        method!(
            "debug/runs/list", DebugRunsList(DebugRunsList) -> DebugRuns,
            classes: [User], writes: false,
            doc: "a project's recorded runs, newest first",
            check: check_list,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use crate::registry::{self, Class};

    /// Run files hold the program's values unredacted: an agent never calls these (spec §19.5's `debug.read`).
    #[test]
    fn runs_and_probes_are_the_users_alone() {
        for name in [
            "debug/probe/op",
            "debug/runs/list",
            "debug/run/get",
            "debug/run/stop",
            "debug/run/pin",
            "debug/run/export",
            "debug/run/import",
        ] {
            let m = registry::find(name).unwrap_or_else(|| panic!("{name} is not registered"));
            assert!(m.allows(Class::User), "{name}");
            assert!(!m.allows(Class::Agent), "{name}");
            assert!(!m.allows(Class::Service), "{name}");
        }
    }
}
