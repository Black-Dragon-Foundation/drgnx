//! The graph store's methods (docs/develop/store.md): the tracker scan's door (Urdr Task 15a; storage §5.6 door 1, §9
//! step 3).  Every method here is the front's own, so the Lisp backend may call them too:
//!
//! - `graph/put-parsed`: what one scan read, by source (a file, a spec, the commits, the branches), applied in one
//!   transaction with the personal-notes deny-list at the door;
//! - `graph/record`: commits that did a task (`drgnx work record`, the job-commit collector), once per collected key.
//!
//! The ids are the scan's (`plan:/…/x.md`, `task:/…/x.md#3`, `commit:SHA`); norn (`norn::parsed`) checks them.
//!
//! The rest are the store's methods for the user (Urdr Task 15b; storage §6.6), every one user class and the front's:
//! reads (`graph/entity`, `graph/neighbors`, `graph/path`, `graph/history`, `graph/sql`), history's writes
//! (`graph/revert`, `graph/proposed`), `graph/excise`, `graph/grants`, the copies (`graph/export`, `graph/import`,
//! `graph/backup`, `graph/compact`), and the settings (`graph/settings`, `graph/privacy`).  The store checks the class
//! again where it matters (grants, `setting:*` keys, excise), so the registry alone never opens them.

use super::{Empty, method};
use crate::registry::Method;
use crate::types::{AbsPath, Bounded, JsonObject, Status, Text, null_as_empty};
use crate::wire::{Error, ErrorCode};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// An entity's id as the scan makes it (a path-form id may be as long as a path).
pub type ParsedId = Bounded<String, 4352>;

/// Where what a scan read came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum SourceKind {
    /// A file the scan read (a plan, a ledger, the board): its entities carry its path.
    File,
    /// A spec: its own source, one `spec:PATH` entity.
    Spec,
    /// Commits (`commit:SHA`): no path.
    Commit,
    /// Branches (`branch:…`): no path.
    Branch,
}

impl SourceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            SourceKind::File => "file",
            SourceKind::Spec => "spec",
            SourceKind::Commit => "commit",
            SourceKind::Branch => "branch",
        }
    }
}

/// A source, typed: never a free string the hub would read as a relative path.  `path` for `file` and `spec` only.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
pub struct SourceRef {
    pub kind: SourceKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<AbsPath>,
}

/// One entity a source holds.  `data` carries what the Lisp readers see as columns (`path`, `line`, `parent`, `ord`)
/// and the rest (`sha`, `date`, `repo`, …); a key set to `null` is left out.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ParsedEntity {
    pub id: ParsedId,
    /// spec, plan, task, step, ruling, todo, file, commit or branch.
    pub kind: Bounded<String, 32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<Text>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<Status>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<JsonObject>,
}

/// Who made a link: read from a file, or inferred (a ledger's commits, a worktree's branch).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum LinkOrigin {
    #[default]
    Parsed,
    Inferred,
}

/// One link a source holds, by the ids of its ends.  `kind` is a link kind of storage §5.4 (`on-branch` is read as
/// `on_branch`); `ledger-of` (a ledger's plan) is kept as `relates` with `data.was`, as the migration keeps it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ParsedLink {
    pub src: ParsedId,
    pub kind: Bounded<String, 32>,
    pub dst: ParsedId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<LinkOrigin>,
}

/// One source of a scan: everything it holds now (a `file` or `spec` source replaces what it held before; a `commit`
/// or `branch` source adds).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ParsedSource {
    pub source: SourceRef,
    /// The file's modification time as the scan saw it (the Lisp `file` view's `mtime`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mtime: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entities: Option<Bounded<Vec<ParsedEntity>, 10000>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub links: Option<Bounded<Vec<ParsedLink>, 10000>>,
}

/// A derived attribute the scan computed (a ledger's `done`, a task whose steps are all done, git facts).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ParsedUpdate {
    pub id: ParsedId,
    /// `open` or `done`, on a parsed task, step or plan.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<Status>,
    /// A merge patch of `gone`, `stale`, `range-stale`, `merged` (true, false or null), `branch`, `worktree`, `repo`
    /// (text or null; the two paths absolute).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data_patch: Option<JsonObject>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct PutParsedParams {
    /// The scan's root, for the tx's actor (`scan:ROOT`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<AbsPath>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sources: Option<Bounded<Vec<ParsedSource>, 1000>>,
    /// Sources that are gone: what they held retired, their file forgotten.  `file` and `spec` only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gone: Option<Bounded<Vec<SourceRef>, 1000>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updates: Option<Bounded<Vec<ParsedUpdate>, 10000>>,
    /// Keys the job-commit collector is done with (`job ID`), kept so it never collects them twice.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collected: Option<Bounded<Vec<CollectedKey>, 1000>>,
}

/// What was not stored, and why (a refused source stores nothing of itself; WHY never names a denied path).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Refusal {
    /// The refused source, as sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<SourceRef>,
    /// The id of a refused update.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub why: String,
}

/// `graph/put-parsed`'s answer: entities made or given a new version, entities retired, and what was refused.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PutParsedAnswer {
    pub changed: u64,
    pub retired: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub refused: Vec<Refusal>,
}

/// A collected key: `job ` and a job's id.
pub type CollectedKey = Bounded<String, 133>;

/// Whether KEY is a collected key: `job ` and an id (ASCII letters, digits and `._:+-`, not first).  Nothing else
/// reaches `kv`, so a scan never writes the store's own keys (`schema`, `log-version`, `seen:*`, `setting:*`).
pub fn is_collected_key(key: &str) -> bool {
    key.strip_prefix("job ")
        .is_some_and(|id| crate::types::Id::new(id).is_ok())
}

/// One commit `graph/record` records.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct RecordCommit {
    /// 4 to 64 hex digits.
    pub sha: Bounded<String, 64>,
    /// The commit time (unix seconds).
    pub date: f64,
    pub subject: Text,
    /// Its place among the repository's commits (`drgnx-work--put-commits`: older is smaller).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seq: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct RecordParams {
    /// The task, step or todo the commits did (an entity id).
    pub task: ParsedId,
    /// The main repository the commits are in.
    pub repo: AbsPath,
    pub commits: Bounded<Vec<RecordCommit>, 1000>,
    /// The job-commit collector's key (`job ID`): the request's key, so a second record of the same job answers the
    /// first answer and writes nothing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collected: Option<CollectedKey>,
}

/// `graph/record`'s answer: the commits' ids, in the order sent.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RecordAnswer {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub ids: Vec<String>,
}

fn bad_key(path: String) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: "a collected key is `job ` and a job's id".into(),
        path: Some(path),
    }
}

fn check_put(p: &PutParsedParams) -> Result<(), Error> {
    for (i, k) in p.collected.iter().flat_map(|c| c.iter()).enumerate() {
        if !is_collected_key(k) {
            return Err(bad_key(format!("collected[{i}]")));
        }
    }
    Ok(())
}

fn check_record(p: &RecordParams) -> Result<(), Error> {
    if let Some(k) = &p.collected
        && !is_collected_key(k)
    {
        return Err(bad_key("collected".into()));
    }
    for (i, c) in p.commits.iter().enumerate() {
        let ok = (4..=64).contains(&c.sha.len()) && c.sha.bytes().all(|b| b.is_ascii_hexdigit());
        if !ok {
            return Err(Error {
                code: ErrorCode::InvalidParams,
                message: "a commit's sha is 4 to 64 hex digits".into(),
                path: Some(format!("commits[{i}].sha")),
            });
        }
    }
    Ok(())
}

// ------------------------------------------------------------------------------- the store's methods (Task 15b)

/// An entity's or a link's kind (`task`, `blocks`, …).
pub type KindName = Bounded<String, 32>;

/// What `graph/entity` adds to the entity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Include {
    /// Its current links, both ways.
    Links,
    /// The notes `about` it.
    Notes,
    /// Every version, with its author.
    History,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct EntityParams {
    pub id: ParsedId,
    /// The entity as of this tx (its version then).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub as_of: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub include: Option<Bounded<Vec<Include>, 3>>,
}

/// One entity with who wrote it (`by` of its creating and its last tx); the store's columns as they are.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EntityAnswer {
    /// The entity's columns (`n`, `id`, `kind`, `project`, `title`, `status`, `body`, `data`, `ver`, …).
    pub entity: Value,
    /// The authors: `{created: {tx, actor, class, at}, updated: {…}}`.
    pub by: Value,
    /// An as-of read of a version the migration synthesized (its time is the migration's).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approximate: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub links: Option<Vec<Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<Vec<Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history: Option<Vec<Value>>,
}

/// Which way links are followed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Out,
    In,
    Both,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NeighborsParams {
    pub id: ParsedId,
    /// The link kinds to follow (needed past depth 3).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kinds: Option<Bounded<Vec<KindName>, 32>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub direction: Option<Direction>,
    /// 1 to 4 (default 1).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub depth: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub as_of: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct PathParams {
    pub from: ParsedId,
    pub to: ParsedId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kinds: Option<Bounded<Vec<KindName>, 32>>,
    /// 1 to 6 (default 3).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_depth: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub as_of: Option<u64>,
}

/// A walk's answer: the nodes and links found, how many were out of scope (`hidden`, never named), and why it
/// stopped early.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WalkAnswer {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub nodes: Vec<Value>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub links: Vec<Value>,
    pub hidden: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub truncated: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct HistoryParams {
    pub id: ParsedId,
    /// Versions from this tx on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HistoryAnswer {
    /// Each version: `{ver, tx, at, actor, class, tool, session, fields, imported}`.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub versions: Vec<Value>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct RevertParams {
    /// Revert this tx.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tx: Option<u64>,
    /// Or put ENTITY back to version VER (a new version).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entity: Option<ParsedId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ver: Option<u64>,
    /// List only: what the revert would do, or the later txs that block it; nothing is written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cascade: Option<bool>,
}

/// What a revert did: the entities given a restoring version and the links retired or added again, or the later txs
/// that block it (nothing written).  `listed`: a `cascade` look, nothing written either way.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RevertAnswer {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reverted: Option<Reverted>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked: Option<Vec<i64>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub listed: Option<bool>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Reverted {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub entities: Vec<i64>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub links: Vec<i64>,
}

/// An excise's target: a tx, or an entity by id.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum ExciseTarget {
    Tx(u64),
    Entity(ParsedId),
}

/// A field an excise blanks.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ExciseField {
    Title,
    Status,
    Body,
    Assignee,
    Data,
}

impl ExciseField {
    pub fn as_str(self) -> &'static str {
        match self {
            ExciseField::Title => "title",
            ExciseField::Status => "status",
            ExciseField::Body => "body",
            ExciseField::Assignee => "assignee",
            ExciseField::Data => "data",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ExciseParams {
    pub target: ExciseTarget,
    /// Default: an entity's title, body and data; a tx's every field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fields: Option<Bounded<Vec<ExciseField>, 5>>,
    /// Kept in `excise_log` (never the content).
    pub reason: Text,
    /// Remove the backup copies and exports that still hold the excised text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rotate_backups: Option<bool>,
    /// Redact the session transcripts that hold it, in place.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcripts: Option<bool>,
}

/// What an excise did (`ExciseReport`), what the scrub after it did (`ScrubReport`: the WAL truncated or what blocked
/// it), and the files outside `work.db` that hold the excised text.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ExciseAnswer {
    pub tx: i64,
    pub entities: u64,
    pub versions: u64,
    pub txs_blanked: u64,
    pub blanked: u64,
    pub vacuumed: bool,
    pub wal_truncated: bool,
    /// `readers` or `writer`: what kept the WAL from being truncated (close drgnx editors, then `graph scrub`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked_by: Option<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub backups_holding: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub backups_removed: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub transcripts_holding: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub transcripts_redacted: Vec<String>,
}

/// `project:N` (or `project:SLUG`), `profile:NAME` or `session:SID`.
pub type GrantWho = Bounded<String, 256>;
/// `project:N` (or `project:SLUG`), `*`, or `task:N` / `task:ID` (an `edit-user-tasks` grant).
pub type GrantWhat = Bounded<String, 4352>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum GrantAccess {
    Read,
    EditUserTasks,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct GrantsList {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub who: Option<GrantWho>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NewGrant {
    pub who: GrantWho,
    pub what: GrantWhat,
    pub access: GrantAccess,
    /// Unix seconds, in the future.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires: Option<f64>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct GrantsParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub list: Option<GrantsList>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grant: Option<NewGrant>,
    /// A grant's id (`grant:…`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revoke: Option<Bounded<String, 64>>,
}

/// A grant as the user sees it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrantView {
    pub id: String,
    pub who: String,
    pub what: String,
    pub access: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires: Option<f64>,
    /// `active` or `revoked`.
    pub status: String,
    /// Active and not expired now.
    pub active: bool,
}

/// `graph/grants`' answer: the list, the new grant, or whether a grant was revoked.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrantsAnswer {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grants: Option<Vec<GrantView>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grant: Option<GrantView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revoked: Option<bool>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ProposedParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accept: Option<Bounded<Vec<u64>, 1000>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reject: Option<Bounded<Vec<u64>, 1000>>,
}

/// A value bound to a `?` of `graph/sql`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum SqlParam {
    Null(()),
    Bool(bool),
    Int(i64),
    Real(f64),
    Text(Text),
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SqlParams {
    /// One `SELECT` (no `ATTACH`, `PRAGMA`, writes or recursive CTEs).
    pub sql: Bounded<String, 100000>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<Bounded<Vec<SqlParam>, 100>>,
    /// At most 10000 (default 2000).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deadline_ms: Option<u64>,
    /// At most 10000 (default 1000).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SqlAnswer {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub columns: Vec<String>,
    /// Each row's values (a blob as `{"blob": LEN}`).
    #[serde(default, deserialize_with = "null_as_empty")]
    pub rows: Vec<Vec<Value>>,
    pub truncated: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ExportParams {
    /// One project's entities only (its id or alias); needs `out`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<Bounded<String, 256>>,
    /// Default: `<data>/export/`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub out: Option<AbsPath>,
    /// `tx.jsonl` from this tx on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history: Option<bool>,
    /// Also `touched` links, `link_stat` and sessions.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub with_activity: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ImportParams {
    pub dir: AbsPath,
}

/// What an export or import did.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PortAnswer {
    pub dir: String,
    pub entities: u64,
    pub links: u64,
    pub txs: u64,
    pub skipped: u64,
    /// Import: `[line, why]` of each record refused.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub refused: Vec<(u64, String)>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// What a backup did: the checked copy, and the old copies rotation removed.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BackupAnswer {
    pub path: String,
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub bytes: u64,
    pub ms: f64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub removed: Vec<String>,
}

/// What a scrub did (`graph/scrub`; the excise's own report carries the same three fields).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ScrubAnswer {
    pub vacuumed: bool,
    pub wal_truncated: bool,
    /// `readers` or `writer`: what kept the WAL from being truncated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked_by: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct CompactParams {
    /// Say what would go, change nothing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dry_run: Option<bool>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CompactAnswer {
    pub versions: u64,
    pub link_stats: u64,
    pub dry_run: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SettingsSet {
    /// "Only I close my tasks" (`setting:only-user-closes`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub only_user_closes: Option<bool>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SettingsParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub get: Option<crate::methods::Empty>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub set: Option<SettingsSet>,
}

/// The store's settings.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub only_user_closes: bool,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct PrivacyParams {
    /// Read `personal-notes-allow.json` and `personal-notes-deny.json` again now and apply the change.
    pub reload: bool,
}

/// What applying a change of the opt-ins did (`norn::privacy::PrivacyReport`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PrivacyAnswer {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub added: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub removed: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub ignored: Vec<String>,
    pub excised: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub backups_holding: Vec<String>,
}

fn invalid(path: &str, message: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

fn check_neighbors(p: &NeighborsParams) -> Result<(), Error> {
    match p.depth {
        Some(d) if !(1..=4).contains(&d) => Err(invalid("depth", "a depth of 1 to 4")),
        _ => Ok(()),
    }
}

fn check_path(p: &PathParams) -> Result<(), Error> {
    match p.max_depth {
        Some(d) if !(1..=6).contains(&d) => Err(invalid("max_depth", "a max_depth of 1 to 6")),
        _ => Ok(()),
    }
}

fn check_revert(p: &RevertParams) -> Result<(), Error> {
    match (&p.tx, &p.entity, &p.ver) {
        (Some(_), None, None) | (None, Some(_), Some(_)) => Ok(()),
        (None, Some(_), None) => Err(invalid("ver", "an entity is put back to a version: ver")),
        _ => Err(invalid("tx", "revert takes tx, or entity and ver")),
    }
}

fn check_excise(p: &ExciseParams) -> Result<(), Error> {
    if p.reason.as_str().trim().is_empty() {
        return Err(invalid("reason", "an excise needs a reason"));
    }
    if p.fields.as_ref().is_some_and(|f| f.is_empty()) {
        return Err(invalid("fields", "name at least one field"));
    }
    Ok(())
}

fn check_grants(p: &GrantsParams) -> Result<(), Error> {
    let n = [p.list.is_some(), p.grant.is_some(), p.revoke.is_some()]
        .iter()
        .filter(|x| **x)
        .count();
    if n != 1 {
        return Err(invalid(
            "list",
            "graph/grants takes one of list, grant or revoke",
        ));
    }
    if let Some(g) = &p.grant
        && g.expires.is_some_and(|t| !t.is_finite())
    {
        return Err(invalid("grant.expires", "unix seconds"));
    }
    Ok(())
}

fn check_proposed(p: &ProposedParams) -> Result<(), Error> {
    match (&p.accept, &p.reject) {
        (Some(a), None) if !a.is_empty() => Ok(()),
        (None, Some(r)) if !r.is_empty() => Ok(()),
        _ => Err(invalid(
            "accept",
            "graph/proposed takes one non-empty list: accept or reject",
        )),
    }
}

fn check_sql(p: &SqlParams) -> Result<(), Error> {
    if p.deadline_ms.is_some_and(|d| d == 0 || d > 10_000) {
        return Err(invalid("deadline_ms", "1 to 10000 ms"));
    }
    if p.rows.is_some_and(|r| r == 0 || r > 10_000) {
        return Err(invalid("rows", "1 to 10000 rows"));
    }
    Ok(())
}

fn check_export(p: &ExportParams) -> Result<(), Error> {
    if p.project.is_some() && p.out.is_none() {
        return Err(invalid(
            "out",
            "a project's export names its folder (out): it never writes into a repository unasked",
        ));
    }
    Ok(())
}

fn check_settings(p: &SettingsParams) -> Result<(), Error> {
    match (&p.get, &p.set) {
        (Some(_), None) | (None, Some(_)) => Ok(()),
        _ => Err(invalid("get", "graph/settings takes one of get or set")),
    }
}

fn check_privacy(p: &PrivacyParams) -> Result<(), Error> {
    if p.reload {
        Ok(())
    } else {
        Err(invalid("reload", "graph/privacy reloads: reload: true"))
    }
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "graph/put-parsed", GraphPutParsed(PutParsedParams) -> PutParsedAnswer,
            classes: [User], writes: true, home: Front,
            doc: "what a tracker scan read, by typed source, in one transaction: every path a record carries checked against the personal-notes deny-list (a denied path refuses its whole source), unchanged entities untouched, derived statuses, collected keys",
            check: check_put,
        ),
        method!(
            "graph/record", GraphRecord(RecordParams) -> RecordAnswer,
            classes: [User], writes: true, home: Front,
            doc: "commits that did a task (implements links), once per collected key (the request's key: a second record answers the first)",
            check: check_record,
        ),
        method!(
            "graph/entity", GraphEntity(EntityParams) -> EntityAnswer,
            classes: [User], writes: false, home: Front,
            doc: "an entity (as of a tx) with who wrote it; its links, the notes about it and its history on request",
        ),
        method!(
            "graph/neighbors", GraphNeighbors(NeighborsParams) -> WalkAnswer,
            classes: [User], writes: false, home: Front,
            doc: "a breadth-first walk from an entity (depth 1 to 4, kinds past 3), within its budget: what stopped it in truncated",
            check: check_neighbors,
        ),
        method!(
            "graph/path", GraphPath(PathParams) -> WalkAnswer,
            classes: [User], writes: false, home: Front,
            doc: "a shortest path between two entities (at most 6 links), within its budget",
            check: check_path,
        ),
        method!(
            "graph/history", GraphHistory(HistoryParams) -> HistoryAnswer,
            classes: [User], writes: false, home: Front,
            doc: "every version of an entity, with its tx's author, class and tool",
        ),
        method!(
            "graph/revert", GraphRevert(RevertParams) -> RevertAnswer,
            classes: [User], writes: true, home: Front,
            doc: "a tx reverted (or an entity put back to a version) as a new tx of the user's; a later change to what it wrote blocks it and is named; cascade only lists",
            check: check_revert,
        ),
        method!(
            "graph/excise", GraphExcise(ExciseParams) -> ExciseAnswer,
            classes: [User], writes: true, home: Front,
            doc: "an entity's (or a tx's) text blanked in every version, its search rows and copies in the coordination tables, then VACUUM and a WAL checkpoint; the backups and transcripts still holding it, removed or redacted on request",
            check: check_excise,
        ),
        method!(
            "graph/grants", GraphGrants(GrantsParams) -> GrantsAnswer,
            classes: [User], writes: true, home: Front,
            doc: "the user's grants: list them, grant a project, profile or session read access (or the edit of user-made tasks), revoke one; the store refuses a grant from any other class",
            check: check_grants,
        ),
        method!(
            "graph/proposed", GraphProposed(ProposedParams) -> RevertAnswer,
            classes: [User], writes: true, home: Front,
            doc: "proposed txs accepted, or rejected (reverted newest first)",
            check: check_proposed,
        ),
        method!(
            "graph/sql", GraphSql(SqlParams) -> SqlAnswer,
            classes: [User], writes: false, home: Front,
            doc: "one read-only SELECT on a hardened connection of its own (no ATTACH, PRAGMA, writes, recursive CTEs or extension loading), with a deadline and a row cap",
            check: check_sql,
        ),
        method!(
            "graph/export", GraphExport(ExportParams) -> PortAnswer,
            classes: [User], writes: false, home: Front,
            doc: "the store as sorted JSON lines (entities, links, txs; history and activity on request) in <data>/export/ or OUT, the personal-notes deny-list applied",
            check: check_export,
        ),
        method!(
            "graph/import", GraphImport(ImportParams) -> PortAnswer,
            classes: [User], writes: true, home: Front,
            doc: "an export read back, idempotent by version, the personal-notes deny-list applied; never a grant",
        ),
        method!(
            "graph/backup", GraphBackup(Empty) -> BackupAnswer,
            classes: [User], writes: false, home: Front,
            doc: "a checked copy of work.db in <data>/backup/ (VACUUM INTO), then the old copies rotated",
        ),
        method!(
            "graph/compact", GraphCompact(CompactParams) -> CompactAnswer,
            classes: [User], writes: true, home: Front,
            doc: "parsed entities' old versions thinned and retired sessions' link stats folded (authored facts never)",
        ),
        method!(
            "graph/scrub", GraphScrub(Empty) -> ScrubAnswer,
            classes: [User], writes: true, home: Front,
            doc: "VACUUM and a WAL checkpoint (TRUNCATE) of work.db as a writer request, saying when readers keep the WAL from being truncated",
        ),
        method!(
            "graph/settings", GraphSettings(SettingsParams) -> Settings,
            classes: [User], writes: true, home: Front,
            doc: "the store's settings (only_user_closes: only I close my tasks), written in a user-class tx only",
            check: check_settings,
        ),
        method!(
            "graph/privacy", GraphPrivacy(PrivacyParams) -> PrivacyAnswer,
            classes: [User], writes: true, home: Front,
            doc: "the personal-notes opt-ins and hard entries read again now and applied: a removed opt-in excises what came in",
            check: check_privacy,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::registry::find;
    use serde_json::json;

    #[test]
    fn collected_keys_are_job_ids_only() {
        assert!(is_collected_key("job j-1"));
        for k in [
            "schema",
            "log-version",
            "seen:a",
            "setting:x",
            "job ",
            "job -x",
            "jobs x",
        ] {
            assert!(!is_collected_key(k), "{k}");
        }
        let put = find("graph/put-parsed").unwrap();
        let e = (put.decode)(&json!({"collected": ["job j1", "schema"]}))
            .err()
            .unwrap();
        assert_eq!(e.path.as_deref(), Some("collected[1]"));
        let rec = find("graph/record").unwrap();
        let ok = json!({"task": "task:/p/x.md#1", "repo": "/r", "commits": [{"sha": "abc1234", "date": 1.0, "subject": "s"}]});
        assert!((rec.decode)(&ok).is_ok());
        let mut bad = ok.clone();
        bad["commits"][0]["sha"] = json!("../x");
        assert_eq!(
            (rec.decode)(&bad).err().unwrap().path.as_deref(),
            Some("commits[0].sha")
        );
    }

    #[test]
    fn a_source_is_typed() {
        let put = find("graph/put-parsed").unwrap();
        // a relative path is never a source's path
        let e = (put.decode)(
            &json!({"sources": [{"source": {"kind": "file", "path": "org/notes.org"}}]}),
        )
        .err()
        .unwrap();
        assert_eq!(e.path.as_deref(), Some("sources[0].source.path"));
        // nor is a source a free string
        assert!((put.decode)(&json!({"sources": [{"source": "spec /x"}]})).is_err());
        assert!(
            (put.decode)(&json!({"sources": [{"source": {"kind": "spec", "path": "/p/s.md"}}]}))
                .is_ok()
        );
    }
}
