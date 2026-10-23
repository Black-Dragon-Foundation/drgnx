//! The graph store's methods (docs/develop/store.md): the tracker scan's door (Urdr Task 15a; storage §5.6 door 1, §9
//! step 3).  Every method here is the front's own, so the Lisp backend may call them too:
//!
//! - `graph/put-parsed`: what one scan read, by source (a file, a spec, the commits, the branches), applied in one
//!   transaction with the personal-notes deny-list at the door;
//! - `graph/record`: commits that did a task (`drgnx work record`, the job-commit collector), once per collected key.
//!
//! The ids are the scan's (`plan:/…/x.md`, `task:/…/x.md#3`, `commit:SHA`); norn (`norn::parsed`) checks them.

use super::method;
use crate::registry::Method;
use crate::types::{AbsPath, Bounded, JsonObject, Status, Text, null_as_empty};
use crate::wire::{Error, ErrorCode};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

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
