//! Debugging (docs/develop/debugging.md, spec §11): the editor lists a project's launch configurations
//! (`debug/configs`), starts one (`debug/start`, which may first need inputs or trust), controls a session
//! (`debug/control`, `debug/select`), tells the hub a project's trust (`debug/trust`) and installs an adapter
//! (`debug/install`) and reads a source with no file (`debug/source`). The Run and Debug view (`debug/view`,
//! `debug/expand`, `debug/watch`, `debug/set-value`, `debug/evaluate`) is a hub-fed view. The hub's events:
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
    /// `launch:N`, `user:N`, `default:ADAPTER:N` or `compound:N` (launch.json's compounds, after its
    /// configurations): what `debug/start` takes.
    pub id: String,
    pub name: String,
    /// `launch`, `user`, `default` or `compound` (whose type and request are empty).
    pub source: String,
    #[serde(rename = "type")]
    pub ty: String,
    pub request: String,
    /// ROOT is not trusted: starting it shows the trust card first.
    pub needs_trust: bool,
    /// Its adapter is not found here (none: found, or it connects to a running adapter, or a compound).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub missing: Option<DebugMissing>,
}

/// An adapter `debug/configs` did not find, and how drgnx installs it: `download` (a pinned archive) or `pip` (into
/// the tools venv) through `debug/install`; `system` (COMMAND names the package); `none` (the user adds it).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugMissing {
    pub adapter: String,
    pub name: String,
    pub install: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
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
    /// Files modified in the editor and not saved: the recorded run marks them "not what ran".
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unsaved: Vec<String>,
    /// The editor has a frame: the tasks run in terminal tabs it shows (`debug-terminal`), and the start waits for
    /// each to exit 0.  Without it (a headless or daemon start) they run captured, as before.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub terminal: bool,
}

/// One answer to `debug/start`'s `needs`: the input ID (`pickProcess` for the process picker) and its VALUE.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugAnswer {
    pub id: String,
    pub value: String,
}

/// `debug/start`'s answer: the session, or what must come first: `"trust"`, or the inputs to ask
/// (`[{input: {id, kind, description, default, options, password}} | "pickProcess"]`). A compound's start answers
/// every member's session in SESSIONS, in the compound's order (SESSION is the first).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugStarted {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub needs: Option<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sessions: Vec<String>,
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

/// `debug/source`: the text of SESSION's source REF (a frame whose source has no file: `sourceReference`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugSource {
    pub session: String,
    #[serde(rename = "ref")]
    pub reference: i64,
}

/// `debug/source`'s answer: the TEXT and its MIME type when the adapter gave one.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugSourceText {
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mime: Option<String>,
}

/// `debug/install`: ADAPTER's `:install` entry carried out (Debug: Install Adapter): a pinned archive checked and
/// unpacked into drgnx's tools folder, debugpy into the tools venv; ADAPTERS are the user's own, as for `debug/start`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugInstall {
    pub adapter: String,
    #[serde(default)]
    pub adapters: Vec<JsonObject>,
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

/// `debug/breakpoints`: ROOT's breakpoints. OP changes them (it reaches ROOT's sessions at once); the answer is the
/// view of the file OP changed, else of PATH.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugBreakpoints {
    pub root: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub op: Option<DebugBreakpointOp>,
}

/// One change to the breakpoint store, by id: `add` (PATH, LINE; the breakpoint already on that line if any),
/// `remove` (ID), `edit` (ID and the fields given; an empty text clears one), `move` (ID, LINE: the saved line),
/// `add-function` (NAME, CONDITION) and `remove-function` (NAME).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugBreakpointOp {
    pub op: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub condition: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub log: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// `filter`'s adapter type.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adapter: Option<String>,
}

/// The operations `debug/breakpoints` knows; `filter` turns exception filter NAME of adapters of type ADAPTER on or
/// off (ENABLED), `enable-all` sets every source breakpoint's ENABLED, `remove-all` removes them and the function
/// breakpoints.
pub const BP_OPS: &[&str] = &[
    "add",
    "remove",
    "edit",
    "move",
    "add-function",
    "remove-function",
    "filter",
    "enable-all",
    "remove-all",
];

/// `debug/view`: VIEW is the Run and Debug view of ROOT's sessions, its Variables and Watch of SESSION (none: the
/// first stopped one), a level INDENT logical px (default 12), only the rows whose name or value contains FILTER
/// (any case) and the rows above them. The hub builds it now and at every change.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugView {
    pub view: String,
    pub root: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub indent: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filter: Option<String>,
}

/// `debug/expand`: NODE of VIEW opened (OPEN) or closed; a variable's children, a chunk, another thread's frames are
/// fetched; "Load more frames" (`m:` node) fetches the next page.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugExpand {
    pub view: String,
    pub node: String,
    pub open: bool,
}

/// `debug/watch`: ROOT's watch expressions changed: `add` EXPR (at the end), `edit` INDEX to EXPR, `remove` INDEX,
/// `move` INDEX to TO. The answer is the list.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugWatch {
    pub root: String,
    pub op: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<u32>,
}

/// The operations `debug/watch` knows.
pub const WATCH_OPS: &[&str] = &["add", "edit", "remove", "move"];

/// `debug/set-value`: the variable or watch NODE of VIEW is now VALUE (`setExpression` when the adapter has it and
/// the node an `evaluateName`, else `setVariable`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugSetValue {
    pub view: String,
    pub node: String,
    pub value: String,
}

/// `debug/set-value`'s answer: the value as the adapter now shows it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugValue {
    pub value: String,
}

/// `debug/evaluate`: EXPR in SESSION's FRAME (none: the selected one) in CONTEXT (`repl`, `hover`, `clipboard`,
/// `watch`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugEvaluate {
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame: Option<i64>,
    pub expr: String,
    pub context: String,
}

/// The contexts `debug/evaluate` knows.
pub const EVAL_CONTEXTS: &[&str] = &["repl", "hover", "clipboard", "watch"];

/// `debug/evaluate`'s answer: the RESULT, its TYPE, and its children's REFERENCE when it has some.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugEvaluated {
    pub result: String,
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    pub ty: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<i64>,
    /// The stop the answer is of: its children are there while that stop lasts (`debug/children`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub epoch: Option<u64>,
}

/// `debug/children`: the children of REFERENCE (a console value's) in SESSION's stop EPOCH (none: the current one).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugChildren {
    pub session: String,
    pub reference: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub epoch: Option<u64>,
}

/// `debug/children`' answer: the VARIABLES.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugChildList {
    pub variables: Vec<DebugChild>,
}

/// A child: its NAME, VALUE, TYPE, and its own children's REFERENCE when it has some.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugChild {
    pub name: String,
    pub value: String,
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    pub ty: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<i64>,
}

/// A file's breakpoints (`debug/breakpoints`' answer, and the event `debug-breakpoints`): PATH's VERSION and its
/// BREAKPOINTS (`{id, line, enabled, condition?, hit?, log?, verified, message?, bound_line?, unsupported}`), with the
/// project's ROOT; the answer also has the function breakpoints and the id ADDED.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugBreakpointsView {
    pub root: String,
    pub path: String,
    pub version: u64,
    pub breakpoints: Vec<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub functions: Option<Vec<Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub added: Option<u64>,
}

/// `debug/run-to-cursor`: SESSION stops once at PATH's LINE (a breakpoint for it alone), continuing if it is stopped.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugRunToCursor {
    pub session: String,
    pub path: String,
    pub line: u32,
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
    if p.unsaved.len() > LIST_MAX || p.unsaved.iter().any(|f| f.len() > TEXT_MAX) {
        return Err(invalid("unsaved", "at most 256 paths"));
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

fn check_source(p: &DebugSource) -> Result<(), Error> {
    check_text("session", &p.session)?;
    if p.reference <= 0 {
        return Err(invalid("ref", "a positive sourceReference"));
    }
    Ok(())
}

fn check_install(p: &DebugInstall) -> Result<(), Error> {
    check_text("adapter", &p.adapter)
}

fn check_trust(p: &DebugTrust) -> Result<(), Error> {
    check_root(&p.root)
}

fn check_path(path: &str, s: &str) -> Result<(), Error> {
    check_text(path, s)?;
    if !s.starts_with('/') {
        return Err(invalid(path, "an absolute path"));
    }
    Ok(())
}

fn check_breakpoints(p: &DebugBreakpoints) -> Result<(), Error> {
    check_root(&p.root)?;
    if let Some(path) = &p.path {
        check_path("path", path)?;
    }
    let Some(op) = &p.op else { return Ok(()) };
    if !BP_OPS.contains(&op.op.as_str()) {
        return Err(invalid(
            "op.op",
            "one of add, remove, edit, move, add-function, remove-function, filter, enable-all, remove-all",
        ));
    }
    for (k, v) in [
        ("op.condition", &op.condition),
        ("op.hit", &op.hit),
        ("op.log", &op.log),
    ] {
        if v.as_ref().is_some_and(|t| t.len() > TEXT_MAX) {
            return Err(invalid(k, "at most 4096 bytes"));
        }
    }
    let need = |k: &str, ok: bool| {
        if ok {
            Ok(())
        } else {
            Err(invalid(k, "required by this op"))
        }
    };
    match op.op.as_str() {
        "add" => {
            check_path("op.path", op.path.as_deref().unwrap_or_default())?;
            need("op.line", op.line.is_some_and(|l| l > 0))
        }
        "remove" | "edit" => need("op.id", op.id.is_some()),
        "filter" => {
            check_text("op.adapter", op.adapter.as_deref().unwrap_or_default())?;
            check_text("op.name", op.name.as_deref().unwrap_or_default())?;
            need("op.enabled", op.enabled.is_some())
        }
        "enable-all" => need("op.enabled", op.enabled.is_some()),
        "remove-all" => Ok(()),
        "move" => {
            need("op.id", op.id.is_some())?;
            need("op.line", op.line.is_some_and(|l| l > 0))
        }
        _ => check_text("op.name", op.name.as_deref().unwrap_or_default()),
    }
}

fn check_run_to(p: &DebugRunToCursor) -> Result<(), Error> {
    check_text("session", &p.session)?;
    check_path("path", &p.path)?;
    if p.line == 0 {
        return Err(invalid("line", "a line number from 1"));
    }
    Ok(())
}

fn check_view(p: &DebugView) -> Result<(), Error> {
    check_text("view", &p.view)?;
    check_root(&p.root)?;
    if let Some(s) = &p.session {
        check_text("session", s)?;
    }
    if p.filter.as_ref().is_some_and(|f| f.len() > TEXT_MAX) {
        return Err(invalid("filter", "at most 4096 bytes"));
    }
    if p.indent.is_some_and(|i| i > 256) {
        return Err(invalid("indent", "at most 256"));
    }
    Ok(())
}

fn check_expand(p: &DebugExpand) -> Result<(), Error> {
    check_text("view", &p.view)?;
    check_text("node", &p.node)
}

fn check_watch(p: &DebugWatch) -> Result<(), Error> {
    check_root(&p.root)?;
    if !WATCH_OPS.contains(&p.op.as_str()) {
        return Err(invalid("op", "one of add, edit, remove, move"));
    }
    if matches!(p.op.as_str(), "add" | "edit") {
        check_text("expr", p.expr.as_deref().unwrap_or_default())?;
    }
    if p.op != "add" && p.index.is_none() {
        return Err(invalid("index", "required by this op"));
    }
    if p.op == "move" && p.to.is_none() {
        return Err(invalid("to", "required by this op"));
    }
    Ok(())
}

fn check_set_value(p: &DebugSetValue) -> Result<(), Error> {
    check_text("view", &p.view)?;
    check_text("node", &p.node)?;
    if p.value.len() > TEXT_MAX {
        return Err(invalid("value", "at most 4096 bytes"));
    }
    Ok(())
}

fn check_children(p: &DebugChildren) -> Result<(), Error> {
    check_text("session", &p.session)?;
    if p.reference <= 0 {
        return Err(invalid("reference", "a positive variablesReference"));
    }
    Ok(())
}

fn check_evaluate(p: &DebugEvaluate) -> Result<(), Error> {
    check_text("session", &p.session)?;
    check_text("expr", &p.expr)?;
    if !EVAL_CONTEXTS.contains(&p.context.as_str()) {
        return Err(invalid("context", "one of repl, hover, clipboard, watch"));
    }
    Ok(())
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "debug/breakpoints", DebugBreakpoints(DebugBreakpoints) -> DebugBreakpointsView,
            classes: [User], writes: false,
            doc: "a project's breakpoints: a change by id (add, remove, edit, move, function breakpoints) that reaches its sessions at once, and the file's breakpoints with what the adapters made of them",
            check: check_breakpoints,
        ),
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
            "debug/run-to-cursor", DebugRunToCursor(DebugRunToCursor) -> bool,
            classes: [User], writes: false,
            doc: "Run to Cursor: a session stops once at a line (a breakpoint for it alone, gone at its next stop), continuing if it is stopped",
            check: check_run_to,
        ),
        method!(
            "debug/select", DebugSelect(DebugSelect) -> bool,
            classes: [User], writes: false,
            doc: "show a frame of a session's stop: its scopes and variables are fetched in the same stop, and debug-frame names its line",
            check: check_select,
        ),
        method!(
            "debug/view", DebugView(DebugView) -> bool,
            classes: [User], writes: false,
            doc: "show the Run and Debug view of a project: its variables, watches, call stack and breakpoints, built by the hub at every stop and change",
            check: check_view,
        ),
        method!(
            "debug/expand", DebugExpand(DebugExpand) -> bool,
            classes: [User], writes: false,
            doc: "open or close a node of the Run and Debug view: a variable's children, a chunk of a long array, another thread's frames, more frames",
            check: check_expand,
        ),
        method!(
            "debug/watch", DebugWatch(DebugWatch) -> Vec<String>,
            classes: [User], writes: false,
            doc: "add, edit, remove or move a project's watch expression (kept with its breakpoints): the list",
            check: check_watch,
        ),
        method!(
            "debug/set-value", DebugSetValue(DebugSetValue) -> DebugValue,
            classes: [User], writes: false,
            doc: "set a variable or watched expression of the Run and Debug view to a new value in the debugged program",
            check: check_set_value,
        ),
        method!(
            "debug/evaluate", DebugEvaluate(DebugEvaluate) -> DebugEvaluated,
            classes: [User], writes: false,
            doc: "evaluate an expression in a stopped session's frame (the value to copy, a hover, the console)",
            check: check_evaluate,
        ),
        method!(
            "debug/children", DebugChildren(DebugChildren) -> DebugChildList,
            classes: [User], writes: false,
            doc: "the children of a value the debug console shows, while the stop it is of lasts (after a resume: an error, the value is stale)",
            check: check_children,
        ),
        method!(
            "debug/trust", DebugTrust(DebugTrust) -> bool,
            classes: [User], writes: false,
            doc: "a project's trust changed: a project never told trusted runs no configuration, and revoking trust stops its sessions",
            check: check_trust,
        ),
        method!(
            "debug/source", DebugSource(DebugSource) -> DebugSourceText,
            classes: [User], writes: false,
            doc: "the text of a frame's source that has no file (its sourceReference), from the adapter, for a read-only buffer",
            check: check_source,
        ),
        method!(
            "debug/install", DebugInstall(DebugInstall) -> String,
            classes: [User], writes: false,
            doc: "install an adapter from its pinned download (checked against its sha256) or into the tools venv with its hash required; a system package's command is named, never run: what was installed",
            check: check_install,
        ),
    ]
}
