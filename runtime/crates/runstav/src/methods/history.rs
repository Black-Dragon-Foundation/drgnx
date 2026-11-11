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
    /// `user` (the default) or `agent:<session>#<step>` for a change merged in from an agent (its step's record).
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
    /// The buffer's version once the batch is in: the editor's count of its drains (a resync is one of them). The
    /// frames of its file name it as `doc_version`.
    pub version: u64,
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
    /// The buffer's version once the text is in, as for `history/batch`.
    pub version: u64,
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
        method!(
            "history/fork", HistoryFork(ForkParams) -> Forked,
            classes: [User], writes: true,
            doc: "fork from a step: a second agent in its own tree at the step's checkpoint, its conversation forked there (or told a labelled summary), started with the user's message; no task, no job, no approval",
        ),
        method!(
            "history/fork/drop", HistoryForkDrop(ForkDropParams) -> Done,
            classes: [User], writes: true,
            doc: "end a fork: its agent stopped, its tree removed, its history branch frozen (kept for compare until it expires)",
        ),
        method!(
            "history/compare", HistoryCompare(CompareParams) -> Compared,
            classes: [User], writes: false,
            doc: "the hunks branch B has that branch A does not, per file, each with who wrote it and in which record and step",
        ),
        method!(
            "history/blame", HistoryBlame(BlameParams) -> Blamed,
            classes: [User], writes: false,
            doc: "who wrote a range of a tracked file's text and in which record and step, from the edit history (not git's blame)",
        ),
        method!(
            "history/hunks", HistoryHunks(BranchHunksParams) -> BranchHunks,
            classes: [User], writes: false,
            doc: "what changed on a history branch since a record: per file, hunks numbered as git diff --unified=0 numbers them; the edits ledger and the review view read this",
        ),
        method!(
            "git/blame", GitBlame(GitBlameParams) -> GitBlamed,
            classes: [User], writes: false,
            doc: "git's blame of a whole file in one answer: per line the commit that last changed it, for the text of the editor's tracked buffer (unsaved typing included) or else the file; lines an agent wrote ride along; cached by path, HEAD and text",
        ),
        method!(
            "history/hunks/head", HistoryHunksHead(HeadHunksParams) -> HeadHunks,
            classes: [User], writes: false,
            doc: "what the editor's tracked buffer of a file changed against the last commit (HEAD), as hunks numbered as git diff --unified=0 numbers them; for the change marks in the margin",
        ),
        method!(
            "git/stage-hunk", GitStageHunk(StageHunkParams) -> Staged,
            classes: [User], writes: true,
            doc: "stage one hunk of the editor's tracked buffer against HEAD in git's index (git apply --cached); the work tree is untouched",
        ),
        method!(
            "history/take", HistoryTake(TakeParams) -> Taken,
            classes: [User], writes: true,
            doc: "whole hunks of a branch taken into a worktree's branch as the user's new text, with where it came from; the files are written",
        ),
        method!(
            "history/redo", HistoryRedo(RedoParams) -> Redone,
            classes: [User], writes: true,
            doc: "redo a revert: the files it changed go back to what they were before it (the user's later edits stay), one record and one forward commit; the agent is told by a message, its conversation is not restored",
        ),
        method!(
            "history/op/hunks", HistoryOpHunks(OpHunksParams) -> OpHunks,
            classes: [User], writes: false,
            doc: "the hunks of one record of a worktree's history, or of every record of a session's agent there (a paired chat's), each with what is still there and who undid it",
        ),
        method!(
            "history/revert/hunk", HistoryRevertHunk(RevertHunkParams) -> HunkReverted,
            classes: [User], writes: true,
            doc: "revert one hunk of an agent's record, keeping the user's later typing: applied and written by the hub, or handed to the editor buffer that holds the file; a hunk whose old text has no place to go back to is a conflict and changes nothing",
        ),
    ]
}

/// `history/op/hunks`: in the history of the worktree WORKTREE, record OP, or every record of SESSION's agent.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct OpHunksParams {
    pub worktree: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub op: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
}

/// How much of a hunk is still there.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum HunkState {
    Live,
    PartlyUndone,
    Undone,
}

/// A record that undid (part of) a hunk, and who wrote it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct UndoneBy {
    pub op: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<serde_json::Value>,
}

/// One hunk of a record: its lines in the text now (1-based), the record's text still there, the text it removed.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct OpHunk {
    pub op: i64,
    pub path: String,
    pub index: i64,
    pub start_line: i64,
    pub end_line: i64,
    pub text: String,
    pub deleted: String,
    pub state: HunkState,
    pub undone_by: Vec<UndoneBy>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct OpHunks {
    pub hunks: Vec<OpHunk>,
}

/// `history/revert/hunk`: hunk HUNK (an `OpHunk.index`) of record OP in PATH, in the worktree WORKTREE.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RevertHunkParams {
    pub worktree: String,
    pub op: i64,
    pub path: String,
    pub hunk: i64,
}

/// What a hunk's revert did.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum HunkRevertState {
    /// The hub applied it and wrote the file.
    Applied,
    /// An editor buffer holds the file: it applies EDITS, as the origin `revert:<op>`, when its text hashes to VERSION.
    InBuffer,
    /// The old text has no place to go back to: nothing changed.
    Conflict,
    /// Undone already: nothing to do.
    Undone,
}

/// A conflicting hunk: its lines now, the user's text where the old text would go back, and that old text.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HunkConflict {
    pub start_line: i64,
    pub end_line: i64,
    pub users: String,
    pub reverted: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HunkReverted {
    pub state: HunkRevertState,
    /// The `revert` record (applied).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub op: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub buffer_id: Option<String>,
    /// SHA-256 in hex of the text EDITS apply to (`history/batch`'s hash).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// In order; offsets in the text as each earlier one left it.
    pub edits: Vec<BatchChange>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conflict: Option<HunkConflict>,
    pub undone_by: Vec<UndoneBy>,
}

/// `history/fork`: SESSION's step SEQ, the user's MESSAGE, and the profile of the second agent (none: the source's).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ForkParams {
    pub session: String,
    pub seq: i64,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
}

/// A fork: the new session, its history branch (what `history/compare` and `history/take` name), the source's, its
/// tree and the level its conversation landed at.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Forked {
    pub id: String,
    pub branch: String,
    pub source_branch: String,
    pub path: String,
    pub level: RestoreLevel,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ForkDropParams {
    pub id: String,
}

/// Two history branches of one project (`Forked.branch`, `Forked.source_branch`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CompareParams {
    pub a: String,
    pub b: String,
}

/// One place B differs from A: character offsets in each branch's text, the texts, and who wrote B's text in which
/// record (and the step that record names); none for a deletion.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ComparedHunk {
    pub ours_start: i64,
    pub ours_end: i64,
    pub theirs_start: i64,
    pub theirs_end: i64,
    pub ours_text: String,
    pub theirs_text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub record: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ComparedFile {
    pub path: String,
    pub hunks: Vec<ComparedHunk>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Compared {
    pub files: Vec<ComparedFile>,
}

/// `history/blame`: who wrote the characters START..END (0-based offsets in the document's LF text) of PATH in the
/// worktree at WORKTREE_ROOT.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BlameParams {
    /// Relative to the worktree.
    pub path: String,
    pub worktree_root: String,
    pub start: i64,
    pub end: i64,
}

/// A run of one author's text, in the record it was made in.  Typing no record holds yet, and text of the base, are
/// left out.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BlameSpan {
    pub start: i64,
    pub end: i64,
    /// The author as the history holds it (`{kind: user}`, `{kind: agent, session}`, `{kind: external, source}`, …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<serde_json::Value>,
    /// The record the text was made in.
    pub record: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Blamed {
    pub spans: Vec<BlameSpan>,
}

/// `history/hunks`: what changed on the history branch BRANCH since record SINCE.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BranchHunksParams {
    pub branch: String,
    pub since: i64,
}

/// One hunk with git's numbers (`@@ -old_start,old_count +new_start,new_count @@` of `git diff --unified=0`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct LineHunk {
    pub old_start: i64,
    pub old_count: i64,
    pub new_start: i64,
    pub new_count: i64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FileHunks {
    pub path: String,
    pub hunks: Vec<LineHunk>,
}

/// `history/hunks`' answer: the files that changed, in path order of their documents.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BranchHunks {
    pub files: Vec<FileHunks>,
}

/// `git/blame`: PATH of the worktree at WORKTREE_ROOT, as the editor's tracked buffer holds it (else the file).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GitBlameParams {
    /// Relative to the worktree.
    pub path: String,
    pub worktree_root: String,
}

/// One commit of a blame.  The lines not committed yet name the commit `0000000000000000000000000000000000000000`, no
/// time and the summary `Uncommitted changes`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BlameCommit {
    pub sha: String,
    pub author: String,
    /// The author time, seconds since the epoch; none for uncommitted lines.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub time: Option<i64>,
    pub summary: String,
}

/// Lines FROM..=TO (1-based) an agent wrote, from the edit history, not yet committed or committed unchanged by it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AgentLines {
    pub from: i64,
    pub to: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step: Option<String>,
}

/// `git/blame`'s answer: COMMITS, and for each line of the text (in order) the index of its commit.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GitBlamed {
    /// The commit HEAD named when the blame was made.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    pub commits: Vec<BlameCommit>,
    pub lines: Vec<u32>,
    pub agents: Vec<AgentLines>,
}

/// `history/hunks/head`: PATH of the worktree at WORKTREE_ROOT, the editor's tracked buffer against HEAD.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HeadHunksParams {
    /// Relative to the worktree.
    pub path: String,
    pub worktree_root: String,
}

/// A hunk against HEAD: git's numbers and the lines HEAD has there (the text a revert puts back and a stage applies).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HeadHunk {
    pub old_start: i64,
    pub old_count: i64,
    pub new_start: i64,
    pub new_count: i64,
    /// HEAD's lines OLD_START..OLD_START+OLD_COUNT, each with its line end.
    pub old_lines: Vec<String>,
}

/// `history/hunks/head`'s answer.  `tracked` is false when no buffer of the file is tracked (no hunks were computed);
/// a file HEAD does not hold is one hunk of all its lines.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HeadHunks {
    pub tracked: bool,
    pub hunks: Vec<HeadHunk>,
}

/// `git/stage-hunk`: stage one hunk of the tracked buffer's change against HEAD (as `history/hunks/head` numbered it)
/// in the index, as `git apply --cached` does; the work tree is not touched.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct StageHunkParams {
    /// Relative to the worktree.
    pub path: String,
    pub worktree_root: String,
    /// Which of the hunks: the line the hunk starts at in the buffer (`new_start`; for a pure deletion, the line it
    /// sits before).
    pub new_start: i64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Staged {
    pub staged: bool,
}

/// A hunk to take: the file and its exact range in the source branch's text (a `ComparedHunk`'s `theirs_*`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TakeHunk {
    pub path: String,
    pub theirs_start: i64,
    pub theirs_end: i64,
}

/// `history/take`: HUNKS of branch FROM into the branch of the worktree WORKTREE (whose files are written).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TakeParams {
    pub from: String,
    pub worktree: String,
    pub hunks: Vec<TakeHunk>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Taken {
    pub op: i64,
    pub written: Vec<String>,
    pub skipped: Vec<RevertSkipped>,
}

/// `history/redo`: SESSION's revert record OP.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RedoParams {
    pub session: String,
    pub op: i64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Redone {
    pub op: i64,
    pub written: Vec<String>,
    pub skipped: Vec<RevertSkipped>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
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
