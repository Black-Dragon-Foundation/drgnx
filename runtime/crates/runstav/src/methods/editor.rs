//! Agents in the editor's buffers (agent system part 3; `docs/develop/hub.md`, "The buffer view"): one view per
//! visible editor buffer, keyed by (connection, view) like the Work map's. `agents/buffer/watch` answers the view's
//! full frame; the event `agent-buffer` carries it again when it changed, at most once per view per 50 ms of the hub's
//! clock, to that connection only. Every frame is whole: `base` names the version it follows (0: a full frame after a
//! watch), so an editor that missed one asks again with `watch`.

use super::work::{PresenceMode, PresenceSource, VIEW_MAX};
use super::{invalid, method};
use crate::registry::Method;
use crate::types::null_as_empty;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// `agents/buffer/watch`'s params: VIEW (the editor's id for a buffer shown in a window) shows FILE.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BufferWatch {
    pub view: String,
    /// The buffer's absolute path.
    pub file: String,
    /// The edit history's worktree id, when the buffer is tracked.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<String>,
    /// The buffer's own change count: a watch of a view already watched with a newer one says the user changed it
    /// (the projection follows after 300 ms without another).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub doc_version: Option<u64>,
}

/// `agents/buffer/unwatch`'s params.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BufferUnwatch {
    pub view: String,
}

/// Where a projected item comes from: the agent's worktree.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Projected {
    /// The worktree's folder name ("editing in rp-df-hub").
    pub worktree_label: String,
}

/// One agent in the buffer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BufferAgent {
    pub session: String,
    /// Its ordinal in the workspace (the display maps it to a colour and a mark).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ordinal: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<String>,
    pub mode: PresenceMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_end: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub col: Option<u32>,
    pub source: PresenceSource,
    /// From a tool call still running.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub live: bool,
    /// Present for an agent working in another worktree, mapped onto this buffer: no bar or ring is drawn for it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub projected: Option<Projected>,
    /// Its current step's title (the agent's own words).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step_title: Option<String>,
    /// The plan entry it works on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan_entry: Option<String>,
}

/// What a gutter range says.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize, JsonSchema,
)]
#[serde(rename_all = "lowercase")]
pub enum GutterKind {
    /// Lines the agent's peer wrote.
    Changed,
    /// Lines an edit is about to change.
    Pending,
    /// Lines the agent changed that the user changed too (a projection only).
    Conflict,
}

/// One gutter range: lines START to END (1-based, inclusive) of one session, merged per session and kind.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GutterRange {
    pub session: String,
    pub kind: GutterKind,
    pub start: u32,
    pub end: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub projected: Option<Projected>,
    /// The hover text ("Opus · changed in step 14 · 2 min ago").
    pub help: String,
}

/// A view's frame: `agents/buffer/watch`'s answer, and the data of `agent-buffer`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BufferFrame {
    pub view: String,
    pub version: u64,
    /// The version this frame follows; 0: a full frame (a watch's answer).
    pub base: u64,
    /// The buffer's change count the frame was computed against (the last the editor sent).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub doc_version: Option<u64>,
    /// The user's text was read from disk: unsaved changes are not in the projection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approximate: Option<bool>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub agents: Vec<BufferAgent>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub gutter: Vec<GutterRange>,
}

fn check_view(view: &str) -> Result<(), Error> {
    if view.is_empty() || view.len() > VIEW_MAX {
        return Err(invalid("view", "a view id of 1 to 64 bytes"));
    }
    Ok(())
}

fn check_watch(p: &BufferWatch) -> Result<(), Error> {
    check_view(&p.view)?;
    if !p.file.starts_with('/') || p.file.len() > 4096 || p.file.contains('\0') {
        return Err(invalid("file", "an absolute path"));
    }
    Ok(())
}

fn check_unwatch(p: &BufferUnwatch) -> Result<(), Error> {
    check_view(&p.view)
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "agents/buffer/watch", AgentsBufferWatch(BufferWatch) -> BufferFrame,
            classes: [User], writes: false,
            doc: "one buffer view of this connection shows a file: the answer is its full frame (the agents in it, the gutter), and agent-buffer events follow, to this connection only; a watch again with a newer doc_version says the user changed the buffer",
            check: check_watch,
        ),
        method!(
            "agents/buffer/unwatch", AgentsBufferUnwatch(BufferUnwatch) -> bool,
            classes: [User], writes: false,
            doc: "end one buffer view of this connection (false: none was open; a connection's views end with it)",
            check: check_unwatch,
        ),
    ]
}
