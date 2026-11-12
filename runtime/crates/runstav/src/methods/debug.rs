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
    /// Run Without Debugging: the configuration launches with `noDebug: true` (its breakpoints do not stop it).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub no_debug: bool,
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
    /// `instruction`: `next`, `step-in` and `step-out` step one instruction (the adapter's
    /// `supportsSteppingGranularity`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub granularity: Option<String>,
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

/// `debug/breakpoint-locations`: where on PATH's LINE SESSION's adapter can stop (inline breakpoints).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugBreakpointLocations {
    pub session: String,
    pub path: String,
    pub line: u32,
}

/// One place a breakpoint can go: LINE and COLUMN (1-based, in characters), to END_LINE and END_COLUMN when it covers a
/// range.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct BreakpointLocation {
    pub line: u32,
    pub column: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_column: Option<u32>,
}

/// `debug/breakpoint-locations`' answer: the LOCATIONS in the adapter's order; none when it cannot say
/// (`supportsBreakpointLocationsRequest`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugBreakpointLocationsList {
    pub locations: Vec<BreakpointLocation>,
}

/// `debug/disassemble`: COUNT instructions (at most [`DISASSEMBLE_MAX`]) from INSTRUCTION_OFFSET instructions after
/// the one at OFFSET bytes from SESSION's memory REFERENCE (a frame's `instruction_pointer`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugDisassemble {
    pub session: String,
    pub reference: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offset: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instruction_offset: Option<i64>,
    pub count: u32,
}

/// The most instructions one `debug/disassemble` reads.
pub const DISASSEMBLE_MAX: u32 = 500;

/// One instruction: its ADDRESS, BYTES, text, SYMBOL, and the source PATH and LINE(s) it comes from.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DisassembledInstruction {
    pub address: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bytes: Option<String>,
    pub instruction: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symbol: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_line: Option<u32>,
}

/// `debug/disassemble`'s answer: the INSTRUCTIONS in address order.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugDisassembly {
    pub instructions: Vec<DisassembledInstruction>,
}

/// `debug/completions`: the Debug Console's completions for TEXT with point at COLUMN (0-based, in characters), in
/// FRAME (the stopped one when none).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugCompletions {
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame: Option<i64>,
    pub text: String,
    pub column: u32,
}

/// One completion: LABEL, the TEXT it inserts when not the label, its TYPE, and the span of the text it replaces
/// (START and LENGTH, 0-based characters) when the adapter gave one.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct CompletionTarget {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    pub ty: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub length: Option<u32>,
}

/// `debug/completions`' answer: the TARGETS in the adapter's order; none when it has no completions
/// (`supportsCompletionsRequest`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugCompletionList {
    pub targets: Vec<CompletionTarget>,
}

/// `debug/read-memory`: COUNT bytes (at most [`READ_MEMORY_MAX`]) at OFFSET from SESSION's memory REFERENCE (a
/// variable's `memoryReference`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugReadMemory {
    pub session: String,
    pub reference: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offset: Option<i64>,
    pub count: u32,
}

/// The most bytes one `debug/read-memory` reads.
pub const READ_MEMORY_MAX: u32 = 64 * 1024;

/// `debug/read-memory`'s answer: the first byte's ADDRESS, the DATA read (base64; empty when none could be), and how
/// many bytes after it could not be read.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugMemory {
    pub address: String,
    pub data: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unreadable: Option<u64>,
}

/// `debug/write-memory`: DATA (base64) written at OFFSET from SESSION's memory REFERENCE; ALLOW_PARTIAL lets the
/// adapter write what it can.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugWriteMemory {
    pub session: String,
    pub reference: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offset: Option<i64>,
    pub data: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allow_partial: Option<bool>,
}

/// `debug/write-memory`'s answer, as the adapter gave it: where the write began (OFFSET from the reference) and how
/// many bytes it WROTE.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugMemoryWritten {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offset: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub written: Option<u64>,
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
    /// With KIND `instruction`: SESSION's instruction breakpoints (they are the session's, never kept), their view
    /// and their ops (`add-instruction`, `remove-instruction`, `edit-instruction`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

/// One change to the breakpoint store, by id: `add` (PATH, LINE; the breakpoint already on that line if any),
/// `remove` (ID), `edit` (ID and the fields given; an empty text clears one), `move` (ID, LINE: the saved line),
/// `add-function` (NAME, CONDITION), `remove-function` (NAME) and `trigger` (ID is triggered by TRIGGERED_BY: sent to
/// a session only once it has stopped on that breakpoint; none: a plain breakpoint again).
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
    /// `trigger`'s triggering breakpoint.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub triggered_by: Option<u64>,
    /// `add-instruction`'s instruction (a memory reference: a frame's `instruction_pointer`, a disassembled
    /// address) and its OFFSET in bytes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instruction: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offset: Option<i64>,
    /// `add`'s and `move`'s column (1-based, in characters): an inline breakpoint. `move` without one keeps the
    /// breakpoint's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub column: Option<u32>,
}

/// The operations `debug/breakpoints` knows; `filter` turns exception filter NAME of adapters of type ADAPTER on or
/// off (ENABLED), `enable-all` sets every source breakpoint's ENABLED, `toggle-all` turns them all off when any is on,
/// else all on, `remove-all` removes them and the function breakpoints.
pub const BP_OPS: &[&str] = &[
    "add",
    "remove",
    "edit",
    "move",
    "add-function",
    "remove-function",
    "trigger",
    "filter",
    "enable-all",
    "toggle-all",
    "remove-all",
    "add-instruction",
    "remove-instruction",
    "edit-instruction",
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// The session of an instruction view (no path).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    pub version: u64,
    pub breakpoints: Vec<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub functions: Option<Vec<Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub added: Option<u64>,
}

/// `debug/data-breakpoint`: a session's data breakpoints (Break on Value Change). `add` watches variable NAME of the
/// container REFERENCE in SESSION (or the variable NODE of the Run and Debug view VIEW), for ACCESS_TYPE (`write`
/// by default; `read`, `readWrite` where the adapter has them); `remove` drops DATA_ID; `list` changes nothing. They
/// last as long as the session.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugDataBreakpoint {
    pub op: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub node: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub access_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data_id: Option<String>,
}

/// `debug/data-breakpoint`'s answer: SESSION's data breakpoints, `{data_id, description, access_type?, verified,
/// message?}` in order.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugDataBreakpoints {
    pub session: String,
    pub breakpoints: Vec<Value>,
}

fn check_data_bp(p: &DebugDataBreakpoint) -> Result<(), Error> {
    let need = |k: &str, ok: bool| {
        if ok {
            Ok(())
        } else {
            Err(invalid(k, "required by this op"))
        }
    };
    for (k, v) in [
        ("session", &p.session),
        ("name", &p.name),
        ("view", &p.view),
        ("node", &p.node),
        ("data_id", &p.data_id),
    ] {
        if let Some(t) = v {
            check_text(k, t)?;
        }
    }
    if let Some(a) = &p.access_type
        && !["read", "write", "readWrite"].contains(&a.as_str())
    {
        return Err(invalid("access_type", "read, write or readWrite"));
    }
    match p.op.as_str() {
        "add" => {
            let by_ref = p.session.is_some() && p.reference.is_some() && p.name.is_some();
            let by_node = p.view.is_some() && p.node.is_some();
            need(
                "session, reference and name (or view and node)",
                by_ref || by_node,
            )
        }
        "remove" => {
            need("session", p.session.is_some())?;
            need("data_id", p.data_id.is_some())
        }
        "list" => need("session", p.session.is_some()),
        _ => Err(invalid("op", "one of add, remove, list")),
    }
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
    match p.granularity.as_deref() {
        None => Ok(()),
        Some("instruction") if matches!(p.op.as_str(), "next" | "step-in" | "step-out") => Ok(()),
        Some(_) => Err(invalid(
            "granularity",
            "instruction, with next, step-in or step-out",
        )),
    }
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

fn check_breakpoint_locations(p: &DebugBreakpointLocations) -> Result<(), Error> {
    check_text("session", &p.session)?;
    check_text("path", &p.path)?;
    if p.line == 0 {
        return Err(invalid("line", "1-based"));
    }
    Ok(())
}

fn check_disassemble(p: &DebugDisassemble) -> Result<(), Error> {
    check_text("session", &p.session)?;
    check_text("reference", &p.reference)?;
    if p.count == 0 || p.count > DISASSEMBLE_MAX {
        return Err(invalid("count", "1 to 500 instructions"));
    }
    Ok(())
}

fn check_completions(p: &DebugCompletions) -> Result<(), Error> {
    check_text("session", &p.session)?;
    if p.column as usize > p.text.chars().count() {
        return Err(invalid("column", "a position in text"));
    }
    Ok(())
}

fn check_read_memory(p: &DebugReadMemory) -> Result<(), Error> {
    check_text("session", &p.session)?;
    check_text("reference", &p.reference)?;
    if p.count == 0 || p.count > READ_MEMORY_MAX {
        return Err(invalid("count", "1 to 65536 bytes"));
    }
    Ok(())
}

fn check_write_memory(p: &DebugWriteMemory) -> Result<(), Error> {
    check_text("session", &p.session)?;
    check_text("reference", &p.reference)?;
    let b64 = |c: char| c.is_ascii_alphanumeric() || matches!(c, '+' | '/' | '=');
    if p.data.is_empty() || !p.data.len().is_multiple_of(4) || !p.data.chars().all(b64) {
        return Err(invalid("data", "base64 bytes"));
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
    match p.kind.as_deref() {
        None => {}
        Some("instruction") => check_text("session", p.session.as_deref().unwrap_or_default())?,
        Some(_) => return Err(invalid("kind", "instruction or none")),
    }
    if let Some(path) = &p.path {
        check_path("path", path)?;
    }
    let Some(op) = &p.op else { return Ok(()) };
    if !BP_OPS.contains(&op.op.as_str()) {
        return Err(invalid(
            "op.op",
            "one of add, remove, edit, move, add-function, remove-function, trigger, filter, enable-all, toggle-all, remove-all, add-instruction, remove-instruction, edit-instruction",
        ));
    }
    let instruction_op = op.op.ends_with("-instruction");
    if instruction_op != (p.kind.as_deref() == Some("instruction")) {
        return Err(invalid(
            "kind",
            "instruction with an instruction op, none otherwise",
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
        "remove" | "edit" | "trigger" | "remove-instruction" | "edit-instruction" => {
            need("op.id", op.id.is_some())
        }
        "add-instruction" => check_text(
            "op.instruction",
            op.instruction.as_deref().unwrap_or_default(),
        ),
        "filter" => {
            check_text("op.adapter", op.adapter.as_deref().unwrap_or_default())?;
            check_text("op.name", op.name.as_deref().unwrap_or_default())?;
            need("op.enabled", op.enabled.is_some())
        }
        "enable-all" => need("op.enabled", op.enabled.is_some()),
        "remove-all" | "toggle-all" => Ok(()),
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
            "debug/data-breakpoint", DebugDataBreakpoint(DebugDataBreakpoint) -> DebugDataBreakpoints,
            classes: [User], writes: false,
            doc: "a session's data breakpoints (Break on Value Change): watch a variable as the adapter's dataBreakpointInfo names it, or drop one; they last as long as the session",
            check: check_data_bp,
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
            "debug/disassemble", DebugDisassemble(DebugDisassemble) -> DebugDisassembly,
            classes: [User], writes: false,
            doc: "the debugged program's instructions around a memory reference (a frame's instruction pointer), at most 500, for the disassembly view",
            check: check_disassemble,
        ),
        method!(
            "debug/completions", DebugCompletions(DebugCompletions) -> DebugCompletionList,
            classes: [User], writes: false,
            doc: "the Debug Console's completions for its text at point, from the adapter; none when it has none",
            check: check_completions,
        ),
        method!(
            "debug/read-memory", DebugReadMemory(DebugReadMemory) -> DebugMemory,
            classes: [User], writes: false,
            doc: "bytes of the debugged program's memory at a variable's memory reference (at most 64 KiB), for the memory view",
            check: check_read_memory,
        ),
        method!(
            "debug/write-memory", DebugWriteMemory(DebugWriteMemory) -> DebugMemoryWritten,
            classes: [User], writes: false,
            doc: "write bytes into the debugged program's memory at a variable's memory reference, from the memory view",
            check: check_write_memory,
        ),
        method!(
            "debug/breakpoint-locations", DebugBreakpointLocations(DebugBreakpointLocations) -> DebugBreakpointLocationsList,
            classes: [User], writes: false,
            doc: "where on a line the session's adapter can stop (inline breakpoints), in characters; none when it cannot say",
            check: check_breakpoint_locations,
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
