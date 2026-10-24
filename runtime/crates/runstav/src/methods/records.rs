//! Records: the org folder's plans, ledgers, DEFERRED, the build board and `board.org` imported into the graph, and
//! the files written back as views (agent system part 1, Tasks 14, 14b; `docs/develop/records.md`).  The hub writes
//! view files and never commits them; a hand edit to a view becomes a proposal the user (or a manager, under
//! `graph.change`) decides.

use super::method;
use crate::registry::Method;
use crate::types::{AbsPath, Id, null_as_empty};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// A kind of record file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum RecordKind {
    Plans,
    Ledgers,
    Deferred,
    BuildBoard,
    Board,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ImportParams {
    /// The org folder.
    pub root: AbsPath,
    /// Only one kind of file (`board` is never imported unless named).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub only: Option<RecordKind>,
    /// Read and count, write nothing (no backup, no graph, no view).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dry_run: Option<bool>,
}

/// One file the importer read.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ImportedFile {
    pub path: String,
    pub kind: RecordKind,
    /// The entity the file became (its plan, ledger or register).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entity: Option<String>,
    /// Entities created or changed, and graph operations applied (or that would be, on a dry run).
    pub entities: u64,
    pub ops: u64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ImportReport {
    pub dry_run: bool,
    /// Where every file was copied before the import (none on a dry run).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backup: Option<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub files: Vec<ImportedFile>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ByPath {
    /// One view's file; none: every view.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<AbsPath>,
}

/// One view file and where it stands.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ViewStatus {
    pub path: String,
    pub kind: RecordKind,
    /// The entity the view shows.
    pub entity: String,
    /// When the hub last wrote it, and the hash it wrote.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub written: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hash: Option<String>,
    /// The file differs from what the hub last wrote.
    pub changed: bool,
    /// The open proposal holding the view (it is not rewritten while one is open).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Views {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub views: Vec<ViewStatus>,
}

/// Where a proposal is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ProposalStatus {
    Open,
    Accepted,
    Rejected,
    /// The records it touches changed since it was read: read the file again.
    Stale,
}

/// A graph operation a proposal would apply, as the user reads it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProposedOp {
    /// `create`, `update`, `link` or `unlink`.
    pub op: String,
    pub entity: String,
    /// The fields it sets, by name (`status`, `title`, `body`, …).
    #[serde(default, deserialize_with = "null_as_empty")]
    pub fields: Vec<String>,
    /// A field only the user may set (a plan's `matrix`): a manager cannot accept it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_only: Option<bool>,
}

/// A hand edit to a view, read back.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Proposal {
    pub id: String,
    pub path: String,
    pub status: ProposalStatus,
    /// A unified diff of the edited file against the view.
    pub diff: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub ops: Vec<ProposedOp>,
    /// Byte ranges of the edited file that map to no operation (they become a note on accept).
    #[serde(default, deserialize_with = "null_as_empty")]
    pub unmapped: Vec<(u64, u64)>,
    /// The graph version it was read against.
    pub base_version: u64,
    /// Who edited it, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by: Option<String>,
    pub at: f64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Proposals {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub proposals: Vec<Proposal>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DecideParams {
    pub id: Id,
    pub accept: bool,
}

/// What a decision did: the proposal's new status, the note its unmapped parts became, the backup of a rejected edit.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Decided {
    pub id: String,
    pub status: ProposalStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backup: Option<String>,
}

/// The `view-written` event.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ViewWritten {
    pub path: String,
    pub kind: RecordKind,
    pub hash: String,
}

/// The `view-proposal` event: a hand edit became (or replaced) a proposal.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ViewProposal {
    pub id: String,
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by: Option<String>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "records/import", RecordsImport(ImportParams) -> ImportReport,
            classes: [User], writes: true, home: Front,
            doc: "the org folder's record files into the graph (a backup of each first; idempotent), their views written; the hub never commits",
        ),
        method!(
            "records/status", RecordsStatus(ByPath) -> Views,
            classes: [User], writes: false, home: Front,
            doc: "the view files: when each was written, whether it changed by hand, the proposal holding it",
        ),
        method!(
            "records/proposals", RecordsProposals(ByPath) -> Proposals,
            classes: [User], writes: false, home: Front,
            doc: "the proposals hand edits to views became (a view's, or every open one)",
        ),
        method!(
            "records/decide", RecordsDecide(DecideParams) -> Decided,
            classes: [User], writes: true, home: Front,
            doc: "a proposal accepted (its ops applied if its base still holds, else stale) or rejected (the edit backed up); then the view is rewritten",
        ),
    ]
}
