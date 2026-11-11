//! Debugging (docs/develop/debugging.md, spec §11): the editor lists a project's launch configurations
//! (`debug/configs`), starts one (`debug/start`, which may first need inputs or trust), controls a session
//! (`debug/control`, `debug/select`) and tells the hub a project's trust (`debug/trust`). The hub's events:
//! `debug-state` (every session), `debug-frame` (a stop's line), `debug-terminal` (`runInTerminal`'s terminal),
//! `debug-ended`.

use super::{invalid, method};
use crate::registry::Method;
use crate::types::JsonObject;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The longest path, id or name a message carries, in bytes.
pub const TEXT_MAX: usize = 4096;
/// The most user configurations or inputs one message carries.
pub const LIST_MAX: usize = 256;

/// `debug/configs`: the configurations the picker shows for ROOT: launch.json's, the user's own USER configs (the
/// setting `debug.configurations`), and the adapter table's defaults for LANGUAGE. ADAPTERS are the user's own adapter
/// entries (the setting `debug.adapters`, in the table's fields), looked at before the built-in ones. ROOT's trust is
/// what `debug/trust` last said.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugConfigs {
    pub root: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    /// The file's language (`python`, `go`, `javascript` …), for the defaults.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(default)]
    pub user: Vec<JsonObject>,
    #[serde(default)]
    pub adapters: Vec<JsonObject>,
}

/// One configuration of `debug/configs`' list.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugConfig {
    /// `launch:N`, `user:N` or `default:ADAPTER:N`: what `debug/start` takes.
    pub id: String,
    pub name: String,
    /// `launch`, `user` or `default`.
    pub source: String,
    #[serde(rename = "type")]
    pub ty: String,
    pub request: String,
    /// ROOT is not trusted: starting it shows the trust card first.
    pub needs_trust: bool,
}

/// A launch.json that could not be read, and where.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugFileError {
    pub path: String,
    pub line: u32,
    pub col: u32,
    pub message: String,
}

/// `debug/configs`' answer: the list in the picker's order, the configuration last started in ROOT, and launch.json's
/// syntax error.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugConfigList {
    pub configs: Vec<DebugConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<DebugFileError>,
}

/// `debug/start`: start CONFIG (an id of `debug/configs`) in ROOT, from FILE at LINE:COL with SELECTION (the editor's
/// state the variables read). INPUTS answer an earlier `needs` (`pickProcess` for the process picker); USER, ADAPTERS
/// and LANGUAGE as `debug/configs`' (a `user:N` or `default:N` id reads them again).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugStart {
    pub root: String,
    pub config: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub col: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(default)]
    pub inputs: Vec<DebugAnswer>,
    #[serde(default)]
    pub user: Vec<JsonObject>,
    #[serde(default)]
    pub adapters: Vec<JsonObject>,
}

/// One answer to `debug/start`'s `needs`: the input ID (`pickProcess` for the process picker) and its VALUE.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugAnswer {
    pub id: String,
    pub value: String,
}

/// `debug/start`'s answer: the session, or what must come first: `"trust"`, or the inputs to ask
/// (`[{input: {id, kind, description, default, options, password}} | "pickProcess"]`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugStarted {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub needs: Option<Value>,
}

/// `debug/control`: OP on SESSION (on THREAD, else the stopped one): `continue`, `pause`, `next`, `step-in`,
/// `step-out`, `restart`, `stop`, `stop-and-kill` (an attach session's debuggee too) or `disconnect`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugControl {
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread: Option<i64>,
    pub op: String,
}

/// The controls `debug/control` knows.
pub const OPS: &[&str] = &[
    "continue",
    "pause",
    "next",
    "step-in",
    "step-out",
    "restart",
    "stop",
    "stop-and-kill",
    "disconnect",
];

/// `debug/select`: show FRAME of SESSION's stop (the Call Stack's selection): its scopes and variables, and its line.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugSelect {
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread: Option<i64>,
    pub frame: i64,
}

/// `debug/trust`: ROOT's trust changed (Trust This Folder, or its revocation, which stops ROOT's sessions).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugTrust {
    pub root: String,
    pub trusted: bool,
}

/// `debug-state`: every session (`{id, name, parent, root, state, reason, caps}`), whenever one starts, runs, stops
/// or ends.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugState {
    pub sessions: Vec<Value>,
}

/// `debug-frame`: a stop's selected frame. OPEN: this editor started the session and opens the file; the others draw
/// it only where the file is shown.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugFrame {
    pub session: String,
    pub epoch: u64,
    pub thread: i64,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default, rename = "ref")]
    pub source_ref: Option<i64>,
    #[serde(default)]
    pub line: Option<i64>,
    #[serde(default)]
    pub col: Option<i64>,
    pub top: bool,
    pub reason: String,
    #[serde(default)]
    pub exception: Option<String>,
    pub open: bool,
}

/// `debug-terminal`: SESSION's program runs in terminal TERM (`runInTerminal`), to the editor that started it, which
/// shows its VIEW.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugTerminal {
    pub session: String,
    pub term: String,
    /// The terminal's view, as `term/open` answers it.
    pub view: String,
}

/// `debug-ended`: SESSION ended, with why and its program's exit code.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugEnded {
    pub session: String,
    pub name: String,
    pub reason: String,
    #[serde(default)]
    pub exit_code: Option<i64>,
}

fn check_text(path: &str, s: &str) -> Result<(), Error> {
    if s.is_empty() || s.len() > TEXT_MAX {
        return Err(invalid(path, "a non-empty text of at most 4096 bytes"));
    }
    Ok(())
}

fn check_root(root: &str) -> Result<(), Error> {
    check_text("root", root)?;
    if !root.starts_with('/') {
        return Err(invalid("root", "an absolute path"));
    }
    Ok(())
}

fn check_configs(p: &DebugConfigs) -> Result<(), Error> {
    check_root(&p.root)?;
    if p.user.len() > LIST_MAX || p.adapters.len() > LIST_MAX {
        return Err(invalid("user", "at most 256 configurations and adapters"));
    }
    Ok(())
}

fn check_start(p: &DebugStart) -> Result<(), Error> {
    check_root(&p.root)?;
    check_text("config", &p.config)?;
    if p.user.len() > LIST_MAX || p.inputs.len() > LIST_MAX || p.adapters.len() > LIST_MAX {
        return Err(invalid("inputs", "at most 256 inputs and configurations"));
    }
    Ok(())
}

fn check_control(p: &DebugControl) -> Result<(), Error> {
    check_text("session", &p.session)?;
    if !OPS.contains(&p.op.as_str()) {
        return Err(invalid(
            "op",
            "one of continue, pause, next, step-in, step-out, restart, stop, stop-and-kill, disconnect",
        ));
    }
    Ok(())
}

fn check_select(p: &DebugSelect) -> Result<(), Error> {
    check_text("session", &p.session)
}

fn check_trust(p: &DebugTrust) -> Result<(), Error> {
    check_root(&p.root)
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "debug/configs", DebugConfigs(DebugConfigs) -> DebugConfigList,
            classes: [User], writes: false,
            doc: "the launch configurations the Start picker shows for a project: launch.json's (a syntax error with its line and column), the user's own, and the adapters' defaults for the file's language once the project is trusted",
            check: check_configs,
        ),
        method!(
            "debug/start", DebugStart(DebugStart) -> DebugStarted,
            classes: [User], writes: false,
            doc: "start a configuration: the session's id, or what must come first (trust, or the inputs and process picker the editor asks for in the palette)",
            check: check_start,
        ),
        method!(
            "debug/control", DebugControl(DebugControl) -> bool,
            classes: [User], writes: false,
            doc: "continue, pause, step, restart, stop or disconnect a session (stop and disconnect stop its children first and answer once all have ended)",
            check: check_control,
        ),
        method!(
            "debug/select", DebugSelect(DebugSelect) -> bool,
            classes: [User], writes: false,
            doc: "show a frame of a session's stop: its scopes and variables are fetched in the same stop, and debug-frame names its line",
            check: check_select,
        ),
        method!(
            "debug/trust", DebugTrust(DebugTrust) -> bool,
            classes: [User], writes: false,
            doc: "a project's trust changed: a project never told trusted runs no configuration, and revoking trust stops its sessions",
            check: check_trust,
        ),
    ]
}
