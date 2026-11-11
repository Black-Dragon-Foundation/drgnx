//! The worker's wire with the hub: one JSON object per line on the worker's socket, tagged by `t`
//! (docs/develop/terminal.md, "The worker"). The worker builds whole `drgnx-rows` patches (it owns the view's
//! versions, row keys and styles); the hub forwards them to the editor and the editor's `view/ack` back.

use drgnx_rows::Patch;
use serde::{Deserialize, Serialize};

/// The `term` protocol version: a newer hub adopts a worker of the same major version.
pub const PROTO: (u32, u32) = (1, 3);

/// From the hub.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "kebab-case")]
pub enum In {
    /// Draw for this view: the next patch is a reset.
    Attach {
        view: String,
        class: String,
        hub: u64,
        #[serde(default)]
        env_epoch: u64,
    },
    /// The editor's env epoch moved (terminal views keep their rows; the number is echoed).
    Env {
        env_epoch: u64,
    },
    /// A key event: its name (`"a"`, `"return"`, `"f5"`), modifiers, the text it types, the codepoint it gives
    /// without shift (0: from the name) and whether it is a press, a repeat or a release.
    Key {
        key: String,
        #[serde(default)]
        mods: Vec<String>,
        #[serde(default)]
        text: String,
        #[serde(default)]
        unshifted: u32,
        #[serde(default)]
        action: KeyAction,
    },
    /// Text typed through an input method: sent as it is.
    Text {
        text: String,
    },
    Paste {
        text: String,
    },
    Focus {
        #[serde(rename = "in")]
        gained: bool,
    },
    /// `kind`: press, release or motion; `button` 1–11 (0: none); the cell, 0-based.
    Mouse {
        kind: String,
        #[serde(default)]
        button: i32,
        col: u32,
        row: u32,
        #[serde(default)]
        mods: Vec<String>,
    },
    /// A new size; REDRAW (a reattach): the program gets SIGWINCH even when the size is the same, so a full-screen
    /// program draws its screen again.
    Resize {
        cols: u16,
        rows: u16,
        cell_px: (u32, u32),
        #[serde(default)]
        redraw: bool,
    },
    /// No editor draws this terminal now (its session went away or kept it at quit): nothing is sent until the next
    /// attach; `detached-keep` counts from here.
    Detach,
    /// The editor applied the patch of this version.
    Ack {
        version: u64,
    },
    /// The editor lost track: the next patch is a reset; with MODEL, only its replica did: the last `model` again, as a
    /// reset.
    Resync {
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        model: bool,
    },
    /// Live settings, `[name, value]`.
    Config {
        config: Vec<(String, serde_json::Value)>,
    },
    /// Whether a program runs, the working directory and the title: answered by `status` with the same REQ.
    Status {
        req: u64,
    },
    /// Where the editor should scroll, answered by `answer` `{key}`: TO `bottom` (the cursor's row), DELTA rows from
    /// FROM (a row key; none: the cursor's row), or PROMPT_DELTA shell prompts from it (OSC 133 A marks).
    Scroll {
        req: u64,
        #[serde(default)]
        from: Option<String>,
        #[serde(default)]
        delta: Option<i64>,
        #[serde(default)]
        prompt_delta: Option<i64>,
        #[serde(default)]
        to: Option<String>,
    },
    /// Send the next backfill chunk now (at most MAX_BYTES, above BEFORE_KEY when given), even with a patch in
    /// flight: answered by `answer` `{version}` (none: nothing above is missing).
    Fetch {
        req: u64,
        #[serde(default)]
        before_key: Option<String>,
        #[serde(default)]
        max_bytes: Option<usize>,
    },
    /// QUERY in every row the engine holds, the window's and above it. The matches in rows the editor holds go first
    /// as the view's `model` (a list `matches`, newest first for DIR `up`, the default, oldest first for `down`); then
    /// `answer` `{found, held, model}`: all the matches, those in the model, and its version (none: no view attached).
    Search {
        req: u64,
        query: String,
        #[serde(default)]
        dir: Option<String>,
    },
    /// The text from row FROM_KEY to row TO_KEY (none: the oldest row the engine holds, the last row): answered by
    /// `answer` `{text}`.
    TextRange {
        req: u64,
        #[serde(default)]
        from_key: Option<String>,
        #[serde(default)]
        to_key: Option<String>,
    },
    /// End the program (SIGHUP, or SIGNAL).
    Close {
        #[serde(default)]
        signal: Option<i32>,
    },
}

/// A key event's kind. A repeat or a release reaches the program as itself only while it asked for event types (the
/// kitty keyboard protocol's flag 2); otherwise a repeat is a press and a release sends nothing.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum KeyAction {
    #[default]
    Press,
    Repeat,
    Release,
}

/// To the hub.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "kebab-case")]
pub enum Out {
    Hello {
        proto: (u32, u32),
        pid: u32,
        shell_pid: u32,
    },
    Patch {
        patch: Box<Patch>,
    },
    /// A `view-model` event for the attached view, whole (`{view, hub, base, version, reset, model}`): the matches
    /// of the last `search` (docs/develop/terminal.md, "The editor's side").
    Model {
        model: serde_json::Value,
    },
    Title {
        title: String,
    },
    Cwd {
        cwd: String,
    },
    Bell,
    Notify {
        title: String,
        body: String,
    },
    Progress {
        state: i32,
        value: i32,
    },
    ClipboardWrite {
        primary: bool,
        mime: String,
        data: String,
    },
    /// OSC 133: `kind` 1 prompt, 2 input, 3 output (a program runs), 4 command ended with `exit`.
    Prompt {
        kind: i32,
        exit: Option<i32>,
    },
    /// The answer to `status`: RUNNING from the shell's OSC 133 marks, else whether the shell has a child.
    Status {
        req: u64,
        running: bool,
        cwd: String,
        title: String,
        shell_pid: u32,
    },
    /// The answer to `scroll`, `fetch`, `search` or `text-range` with the same REQ.
    Answer {
        req: u64,
        result: serde_json::Value,
    },
    /// The program ended: its exit code, or the signal that ended it.
    Exit {
        code: Option<i32>,
        signal: Option<i32>,
    },
}
