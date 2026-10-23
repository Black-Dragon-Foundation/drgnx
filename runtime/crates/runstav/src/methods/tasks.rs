//! The tracker for the editor (Urdr Task 15b; storage §6.1, §6.6): what the agents' `task_read` and `task_write` do,
//! as the user (class `user`: the tracker's user rules apply, and `tools` is the user's only).  Every method here is
//! the front's own.
//!
//! - `tasks/ready`: the ready tasks, by priority then age.
//! - `tasks/find`: tasks by words (full text), status, assignee and labels, 50 at a time.
//! - `tasks/write`: one tracker operation (`op` and its fields).

use super::method;
use crate::registry::Method;
use crate::types::{AbsPath, Bounded, Status, Text, null_as_empty};
use crate::wire::{Error, ErrorCode};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// An entity's id (a tracker task's `task:xx-abcde`, a job's `task:JOB#N`, a parsed one's path form).
pub type EntityId = Bounded<String, 4352>;
/// A label: one line of at most 64.
pub type Label = Bounded<String, 64>;
/// A project: its id (`project:…`) or one of its aliases.
pub type ProjectName = Bounded<String, 256>;
/// Who a task goes to: an agent's actor (`agent:SID`, `ext:…`) or `user`.
pub type Assignee = Bounded<String, 256>;

/// The most tasks one answer lists.
pub const PAGE: u32 = 50;

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ReadyParams {
    /// Only tasks with every one of these labels.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub labels: Option<Bounded<Vec<Label>, 16>>,
    /// 1 to 50 (default 50).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    /// Only this project's tasks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<ProjectName>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct FindParams {
    /// Words, ranked by full text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query: Option<Text>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<Status>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assignee: Option<Assignee>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub labels: Option<Bounded<Vec<Label>, 16>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<ProjectName>,
    /// The `cursor` of the answer before: the next page.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<u64>,
}

/// A page of tasks: each `{id, title, status, priority, assignee, labels, project, ver, lease}`.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskList {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub tasks: Vec<Value>,
    /// More follow: pass it back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<u64>,
}

/// A tracker operation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Op {
    Create,
    Update,
    Claim,
    Heartbeat,
    Release,
    Handoff,
    Reassign,
    Split,
    Complete,
    Link,
    Unlink,
    Label,
    Tools,
}

/// How a split goes: the parts as children (default), or in the task's place.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum SplitMode {
    Children,
    Replace,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct WriteParams {
    pub op: Op,
    /// The task (every op but create, link and unlink).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<EntityId>,
    /// The version the change is based on (update, reassign, split).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ver: Option<i64>,
    /// The lease epoch a claim answered (heartbeat, release, handoff, complete).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lease: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<Text>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<Text>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub labels: Option<Bounded<Vec<Label>, 32>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acceptance: Option<Text>,
    /// Create: the new task's parent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<EntityId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<Status>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<Text>,
    /// Handoff, reassign: who next (none: back to open).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<Assignee>,
    /// Split: the parts' titles.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parts: Option<Bounded<Vec<Text>, 20>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<SplitMode>,
    /// Link, unlink: the link's ends and kind.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub src: Option<EntityId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<Bounded<String, 32>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dst: Option<EntityId>,
    /// Label: the labels added and removed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub add: Option<Bounded<Vec<Label>, 32>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remove: Option<Bounded<Vec<Label>, 32>>,
    /// Tools: the tracker tools on or off for sessions working on this task (absent: the profile decides).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tracker: Option<bool>,
    /// Create: the project (its id or alias), or the folder whose project it is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<ProjectName>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<AbsPath>,
}

/// `tasks/write`'s answer: `{id, title, ver, lease?, parts?}` when done, else one of `{conflict: {id, ver,
/// changed_since, next}}`, `{lease_lost: {by, how, tx, note, next}}` or `{proposed: {card}}`.
pub type WriteAnswer = Value;

fn invalid(path: &str, message: String) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message,
        path: Some(path.into()),
    }
}

fn check_ready(p: &ReadyParams) -> Result<(), Error> {
    match p.limit {
        Some(n) if n == 0 || n > PAGE => Err(invalid("limit", format!("1 to {PAGE}"))),
        _ => Ok(()),
    }
}

/// The fields each op needs.
fn check_write(p: &WriteParams) -> Result<(), Error> {
    let need = |ok: bool, path: &str| -> Result<(), Error> {
        if ok {
            Ok(())
        } else {
            Err(invalid(
                path,
                format!("{:?} needs {path}", p.op).to_lowercase(),
            ))
        }
    };
    match p.op {
        Op::Create => need(p.title.is_some(), "title"),
        Op::Update | Op::Reassign | Op::Split => {
            need(p.id.is_some(), "id")?;
            need(p.ver.is_some(), "ver")?;
            match p.op {
                Op::Reassign => need(p.note.is_some(), "note"),
                Op::Split => need(p.parts.as_ref().is_some_and(|v| !v.is_empty()), "parts"),
                _ => Ok(()),
            }
        }
        Op::Heartbeat | Op::Release | Op::Handoff | Op::Complete => {
            need(p.id.is_some(), "id")?;
            need(p.lease.is_some(), "lease")?;
            if p.op == Op::Handoff {
                need(p.note.is_some(), "note")?;
            }
            Ok(())
        }
        Op::Claim | Op::Label | Op::Tools => need(p.id.is_some(), "id"),
        Op::Link | Op::Unlink => {
            need(p.src.is_some(), "src")?;
            need(p.kind.is_some(), "kind")?;
            need(p.dst.is_some(), "dst")
        }
    }
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "tasks/ready", TasksReady(ReadyParams) -> TaskList,
            classes: [User], writes: false, home: Front,
            doc: "the ready tracker tasks (open, nothing open blocks them, no live lease), by priority then age",
            check: check_ready,
        ),
        method!(
            "tasks/find", TasksFind(FindParams) -> TaskList,
            classes: [User], writes: false, home: Front,
            doc: "tasks by words (full text), status, assignee, labels and project, 50 a page",
        ),
        method!(
            "tasks/write", TasksWrite(WriteParams) -> WriteAnswer,
            classes: [User], writes: true, home: Front,
            doc: "one tracker operation as the user (create, update, claim, heartbeat, release, handoff, reassign, split, complete, link, unlink, label, tools): done, a conflict with what changed, a lost lease, or a close proposal",
            check: check_write,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use crate::registry::find;
    use serde_json::json;

    #[test]
    fn each_op_names_what_it_needs() {
        let w = find("tasks/write").unwrap();
        let path = |v| (w.decode)(&v).err().map(|e| e.path.unwrap_or_default());
        assert_eq!(path(json!({"op": "create"})).as_deref(), Some("title"));
        assert_eq!(path(json!({"op": "create", "title": "t"})), None);
        assert_eq!(
            path(json!({"op": "update", "id": "task:xx-1"})).as_deref(),
            Some("ver")
        );
        assert_eq!(
            path(json!({"op": "complete", "id": "task:xx-1"})).as_deref(),
            Some("lease")
        );
        assert_eq!(
            path(json!({"op": "link", "src": "a", "kind": "blocks"})).as_deref(),
            Some("dst")
        );
        assert_eq!(
            path(json!({"op": "split", "id": "t", "ver": 1, "parts": []})).as_deref(),
            Some("parts")
        );
        assert!(path(json!({"op": "nope"})).is_some());
        let r = find("tasks/ready").unwrap();
        assert!((r.decode)(&json!({"limit": 51})).is_err());
        assert!((r.decode)(&json!({"limit": 5, "labels": ["a"]})).is_ok());
    }
}
