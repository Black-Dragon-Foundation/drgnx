//! Records: a project's specs, plans, ledgers, decision records, DEFERRED, the build board and `board.org` adopted
//! into the graph, and the files kept in step with it (`docs/develop/records.md`).  An edit on either side reaches
//! the other through a three-way merge per piece; both sides changing one piece keeps the file's text and flags the
//! record, which the user (or a manager, under `graph.change`) resolves.  The hub never commits the files.

use super::graph::ParsedId;
use super::{invalid, method};
use crate::registry::Method;
use crate::types::{AbsPath, Bounded, Id, Status, Text, null_as_empty};
use crate::wire::Error;
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

/// What a written record is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum DocKind {
    Spec,
    Decision,
}

/// One section written: with a `key` (from `records/read`) it replaces that section, without one it is new (after
/// `after`, else last).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SectionWrite {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<Bounded<String, 128>>,
    /// The heading text: no `#`, no line break.
    pub heading: Bounded<String, 256>,
    /// The text under the heading; it may hold no level-2 heading outside a code fence.
    pub body: Text,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<Bounded<String, 128>>,
}

/// A spec or decision record written, in one transaction.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct RecordWrite {
    /// The record (its head's id); none creates one (then `project`, `path` and `title` are needed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub record: Option<ParsedId>,
    pub kind: DocKind,
    /// The project of a new record (an agent's is its own).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<ParsedId>,
    /// A new record's view file, relative to the project root: `docs/specs/<repo>/<name>.md` (or `docs/decisions/…`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<Bounded<String, 512>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<Bounded<String, 512>>,
    /// `proposed` or `approved` (`accepted` for a decision), `superseded`; an agent may not approve.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<Status>,
    #[serde(default)]
    pub sections: Bounded<Vec<SectionWrite>, 64>,
    /// Section keys to drop.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remove: Option<Bounded<Vec<Bounded<String, 128>>, 64>>,
    /// The version the writer read (`records/read`); 0 for a new record.
    pub base_version: u64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SectionId {
    pub key: String,
    pub id: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RecordWritten {
    pub record: String,
    pub path: String,
    pub tx: u64,
    pub version: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub sections: Vec<SectionId>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct RecordRead {
    pub record: ParsedId,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SectionView {
    pub key: String,
    pub id: String,
    pub heading: String,
    pub body: String,
    pub conflict: bool,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RecordLink {
    pub kind: String,
    pub to: String,
    pub outgoing: bool,
}

/// A spec or decision with its sections, as `records/write` takes them back.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RecordView {
    pub record: String,
    pub kind: DocKind,
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    pub version: u64,
    pub head: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub sections: Vec<SectionView>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub links: Vec<RecordLink>,
}

fn check_write(p: &RecordWrite) -> Result<(), Error> {
    if p.path.is_some() && p.record.is_some() {
        return Err(invalid("path", "a record that exists has its path already"));
    }
    Ok(())
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
            "records/write", RecordsWrite(RecordWrite) -> RecordWritten,
            classes: [User], writes: true,
            doc: "a spec or decision record created or changed by section, in one tx (refused when base_version is behind); a new one names its view file under the project's docs/specs|decisions/<repo>/",
            check: check_write,
        ),
        method!(
            "records/read", RecordsRead(RecordRead) -> RecordView,
            classes: [User], writes: false,
            doc: "a spec or decision record: its head, sections with keys, links and version",
        ),
        method!(
            "records/resolve", RecordsResolve(ResolveParams) -> Resolved,
            classes: [User], writes: true,
            doc: "a conflicted record resolved: the file's text becomes the record's, or the graph's version is written back to the file",
        ),
    ]
}
