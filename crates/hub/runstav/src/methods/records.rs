//! Records: a project's specs, plans, ledgers, decision records, DEFERRED, the build board and `board.org` adopted
//! into the graph, and the files kept in step with it (`docs/develop/records.md`).  An edit on either side reaches
//! the other through a three-way merge per piece; both sides changing one piece keeps the file's text and flags the
//! record, which the user (or a manager, under `graph.change`) resolves.  The hub never commits the files.

use super::method;
use crate::registry::Method;
use crate::types::{AbsPath, Id, null_as_empty};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// A kind of record file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum RecordKind {
    Specs,
    Plans,
    Ledgers,
    Deferred,
    BuildBoard,
    Board,
    Decisions,
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
    /// Only this record file, which must lie under `root` and be one the importer would find (not ignored).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<AbsPath>,
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
    /// The records of the view both sides changed: the file's text is kept, the graph's version stays the record's
    /// until one is chosen (`records/resolve`).
    #[serde(default, deserialize_with = "null_as_empty")]
    pub conflicts: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Views {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub views: Vec<ViewStatus>,
}

/// Which version of a conflicted record stays.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Keep {
    /// The file's text becomes the record's.
    File,
    /// The graph's version is written back into the file.
    Graph,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ResolveParams {
    /// The conflicted record.
    pub id: Id,
    pub keep: Keep,
}

/// A conflicted record, both versions.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Conflict {
    pub id: String,
    pub path: String,
    /// The file's text of the record, and the graph's.
    pub file: String,
    pub graph: String,
    pub at: f64,
}

/// What resolving did.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Resolved {
    pub id: String,
    pub keep: Keep,
    pub path: String,
}

/// The `records-conflict` event: records of a file both its file and the graph changed, newly flagged.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RecordsConflict {
    pub path: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub ids: Vec<String>,
}

/// The `records-notice` event: a project's record files were adopted, once per root; the hub rewrites none of them
/// before it is sent.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RecordsNotice {
    pub root: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub files: Vec<String>,
    /// Where the files and the graph store were copied first.
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

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "records/import", RecordsImport(ImportParams) -> ImportReport,
            classes: [User], writes: true,
            doc: "a project's record files adopted into the graph (the files and the store backed up first; idempotent; the notice sent once per root); the hub never commits",
        ),
        method!(
            "records/status", RecordsStatus(ByPath) -> Views,
            classes: [User], writes: false,
            doc: "the record files: when each was written, whether it changed since, its conflicted records",
        ),
        method!(
            "records/conflict", RecordsConflict(crate::methods::exec::ById) -> Conflict,
            classes: [User], writes: false,
            doc: "a conflicted record: the file's text and the graph's version",
        ),
        method!(
            "records/resolve", RecordsResolve(ResolveParams) -> Resolved,
            classes: [User], writes: true,
            doc: "a conflicted record resolved: the file's text becomes the record's, or the graph's version is written back to the file",
        ),
    ]
}
