//! The worker's wire with the hub: one JSON object per line on the worker's socket, tagged by `t`
//! (docs/develop/terminal.md, "The worker"). The worker builds whole `drgnx-rows` patches (it owns the view's
//! versions, row keys and styles); the hub forwards them to the editor and the editor's `view/ack` back.

use drgnx_rows::Patch;
use serde::{Deserialize, Serialize};

/// The `term` protocol version: a newer hub adopts a worker of the same major version.
pub const PROTO: (u32, u32) = (1, 0);

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
    /// A key press: its name (`"a"`, `"return"`, `"f5"`), modifiers, the text it types and the codepoint it gives
    /// without shift (0: from the name).
    Key {
        key: String,
        #[serde(default)]
        mods: Vec<String>,
        #[serde(default)]
        text: String,
        #[serde(default)]
        unshifted: u32,
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
    Resize {
        cols: u16,
        rows: u16,
        cell_px: (u32, u32),
    },
    /// The editor applied the patch of this version.
    Ack {
        version: u64,
    },
    /// The editor lost track: the next patch is a reset.
    Resync,
    /// Live settings, `[name, value]`.
    Config {
        config: Vec<(String, serde_json::Value)>,
    },
    /// Whether a program runs, the working directory and the title: answered by `status` with the same REQ.
    Status {
        req: u64,
    },
    /// End the program (SIGHUP, or SIGNAL).
    Close {
        #[serde(default)]
        signal: Option<i32>,
    },
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
    /// The program ended: its exit code, or the signal that ended it.
    Exit {
        code: Option<i32>,
        signal: Option<i32>,
    },
}
