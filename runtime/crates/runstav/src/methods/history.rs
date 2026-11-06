//! The edit history's methods for the editor (agent system part 4; `docs/develop/history.md`, "The hub"): the editor
//! tells the hub which buffers it tracks and what changed in them, so the history holds the user's keystrokes beside
//! the agents' and the outside world's.  User only: no agent tool and no manager tool reaches them.

use super::method;
use crate::registry::Method;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// A buffer the editor starts tracking.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RegisterParams {
    /// The file's path, relative to the worktree.
    pub path: String,
    /// The worktree's folder.
    pub worktree_root: String,
    /// The editor's name for the buffer, used by every later call.
    pub buffer_id: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Registered {
    /// The file's document (0 when untracked).
    pub doc: i64,
    /// False for a gitignored file, a credentials file and the personal-notes deny-list: the editor sends no batches.
    pub tracked: bool,
    /// Why not: `ignored`, `secret`, `personal` or `agent-tree`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// One change of a batch: OLD_LEN characters at START (offsets in the document's LF text) replaced by INSERTED.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BatchChange {
    pub start: u64,
    pub old_len: u64,
    pub inserted: String,
    /// `user` (the default) or `agent:<session>` for a change merged in from an agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BatchParams {
    pub buffer_id: String,
    /// At most 1 MiB of inserted text; more is refused as `split-required` and the editor splits it.
    pub changes: Vec<BatchChange>,
    /// SHA-256 in hex of the buffer's whole text after the batch.
    pub region_hash: String,
}

/// `{ok: true}`, or `{resync: true}` when the buffer and the document disagree (send `history/resync`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BatchResult {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ok: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resync: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ResyncParams {
    pub buffer_id: String,
    /// The buffer's whole text (LF line ends).
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct UnregisterParams {
    pub buffer_id: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Done {
    pub ok: bool,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "history/register", HistoryRegister(RegisterParams) -> Registered,
            classes: [User], writes: true,
            doc: "the editor tracks a buffer's file: its document, or why it is not tracked (ignored, secret, personal)",
        ),
        method!(
            "history/batch", HistoryBatch(BatchParams) -> BatchResult,
            classes: [User], writes: true,
            doc: "the changes of a tracked buffer as the user's (or a merged-in agent's) operations; resync when the hash differs",
        ),
        method!(
            "history/resync", HistoryResync(ResyncParams) -> Done,
            classes: [User], writes: true,
            doc: "a tracked buffer's whole text, as the user's change to its document",
        ),
        method!(
            "history/unregister", HistoryUnregister(UnregisterParams) -> Done,
            classes: [User], writes: true,
            doc: "the editor stops tracking a buffer",
        ),
    ]
}
