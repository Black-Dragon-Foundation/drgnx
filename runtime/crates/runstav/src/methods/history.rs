//! The edit history's methods for the editor (agent system part 4; `docs/develop/history.md`, "The hub"): the editor
//! tells the hub which buffers it tracks and what changed in them, so the history holds the user's keystrokes beside
//! the agents' and the outside world's.  User only: no agent tool and no manager tool reaches them.
//! It also names what a revert or a fork of an agent's work restores (`docs/develop/hub.md`, "Rewind and fork").

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
        method!(
            "history/revert/preview", HistoryRevertPreview(RevertPreviewParams) -> RevertCard,
            classes: [User], writes: false,
            doc: "what reverting an agent's work to a step would do: the files, the user's later edits it meets, what it cannot undo, and whether it is blocked",
        ),
        method!(
            "history/revert/apply", HistoryRevertApply(RevertApplyParams) -> Applied,
            classes: [User], writes: true,
            doc: "apply a revert preview: the files, the steps and conclusions after it, the conversation and one forward commit, as one record; the user's later edits are kept or merged",
        ),
    ]
}

/// The step a revert goes back to: SESSION's step SEQ, or the step DECISION was recorded in.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RevertPreviewParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seq: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decision: Option<i64>,
}

/// Whether the conversation goes back with the code.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum ConversationRestore {
    Restored,
    /// Why not, as the card says it (`conversation not restored: the agent has finished`).
    NotRestored {
        label: String,
    },
}

/// A file the user changed after the agent's last step in a way that cannot be merged: what the user has there now and
/// what the revert would write (none: a file that is not text, or not there).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RevertOverlap {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub users: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reverted: Option<String>,
}

/// A path a revert leaves as it is, and why (`protected`, `gitlink`, `edited-later`, or what the write said).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RevertSkipped {
    pub path: String,
    pub reason: String,
}

/// `history/revert/preview`: the revert card.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RevertCard {
    pub preview_id: i64,
    pub session: String,
    pub seq: i64,
    /// Every path the revert writes or removes.
    pub files: Vec<String>,
    /// The user's later edits the revert meets, one choice each on apply (in this order).
    pub overlaps: Vec<RevertOverlap>,
    /// Files the user edited later where the revert merges with the user's edit.
    pub non_overlapping_files: Vec<String>,
    pub effects: RevertEffects,
    pub level: RestoreLevel,
    /// The conversation is restored by a summary, which goes with a message of the user's.
    pub needs_message: bool,
    /// Non-empty: refused, offered as a fork.
    pub blocked: Vec<Blocked>,
    pub skipped: Vec<RevertSkipped>,
    pub conversation: ConversationRestore,
    /// A fork from the step is offered beside the revert (a finished worker, a blocked revert).
    pub fork: bool,
}

/// How the user's own later edits are treated.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum RevertMode {
    /// Only the agent's changes go; the user's later edits stay (merged where they meet).
    KeepMine,
    /// Every file goes back to the step; the user's later versions are kept under `undone`.
    RollBackMine,
}

/// The user's answer to one overlap.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(tag = "choice", rename_all = "kebab-case")]
pub enum RevertChoice {
    /// The user's file stays (the default).
    KeepUsers,
    /// The reverted file; the user's version is kept under `undone`.
    TakeReverted,
    /// This text in its place.
    Edited { text: String },
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RevertApplyParams {
    pub preview_id: i64,
    /// `keep-mine` (the default) or `roll-back-mine`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<RevertMode>,
    /// One per overlap, in the card's order; a missing one keeps the user's.
    #[serde(default)]
    pub choices: Vec<RevertChoice>,
    /// What the restored conversation is told first.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

/// `history/revert/apply`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Applied {
    /// The revert's record in the edit history.
    pub op: i64,
    pub session: String,
    /// The level the conversation landed at (none: not restored).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub level: Option<RestoreLevel>,
    /// The forward commit, when the head had moved since the step.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    pub skipped: Vec<RevertSkipped>,
    pub conversation: ConversationRestore,
    /// Runners' patches that returned during the revert: kept on their jobs, never applied.
    pub kept_patches: Vec<String>,
    /// Where the files' versions before the revert are kept (a ref of the hub's shadow repository).
    pub undone: String,
}

/// How much of an agent's conversation a rewind or a fork restores: up to the step's message (Claude), up to the
/// last turn that completed at or before it (Codex), or a new conversation told a labelled summary (any other agent,
/// a fork across providers, a fork that failed).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum RestoreLevel {
    Message,
    Turn,
    Summary,
}

/// A commit made after the step that a remote already has: the remote-tracking refs that contain it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Pushed {
    pub commit: String,
    pub refs: Vec<String>,
}

/// What the session spent after the step: cost by unit (`usd`, an agent's own estimate unit) and tokens.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Spent {
    pub cost_by_unit: std::collections::BTreeMap<String, f64>,
    pub tokens: i64,
}

/// What a revert to a step cannot undo, each from a hub record after the step began: listed first on the card.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RevertEffects {
    pub pushed: Vec<Pushed>,
    /// Messages the session sent that their recipient has read.
    pub messages_read: Vec<i64>,
    /// The session's decisions after the step that another decision depends on (computed).
    pub decisions_relied_on: Vec<i64>,
    /// Tasks the session filed.
    pub tasks_filed: Vec<String>,
    /// The session's commits already merged into its integration branch (`<commit> into <branch>`).
    pub merges: Vec<String>,
    /// The settings the session changed.
    pub settings: Vec<String>,
    pub spent: Spent,
    /// The session's jobs that run or wait now, each with where (`<id> (here)`, `(queued)`, `(on <runner>)`).
    pub jobs_running: Vec<String>,
    /// `computed`: dependencies come from git, not from a recorded edge.
    pub label: String,
}

/// A commit of another session that depends on what a revert would undo and is already in the integration branch:
/// the revert is refused and offered as a fork.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Blocked {
    pub decision: i64,
    pub commit: String,
    pub session: String,
    pub branch: String,
}
