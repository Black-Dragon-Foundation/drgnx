//! Task 8's reading tools: inbox, ack, decisions, task and work status (`drgnx-coord-mcp--job-tools`,
//! `core/drgnx-coord-mcp.el`; `work_status` is `drgnx-work--status-rows`, `core/drgnx-work.el`, run read-only).

use mimir::BoxFuture;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize, Serializer};
use serde_json::Value;

use super::guard::{CoordTool, guarded};
use super::job::{DecisionOut, decisions_out, err, json_text};
use super::{Coord, Ctx, Identity};
use crate::read::decisions::{decisions_since, seen, version};
use crate::read::messages::{Message, inbox, message};
use crate::read::tasks::{opt, tasks};
use crate::store::{CoordError, Tx};
use crate::write::messages::mark;
use crate::write::meta::set_seen;

/// This file's tools.
pub fn tools() -> Vec<Box<dyn mimir::Tool<Ctx>>> {
    vec![
        guarded(ReadInbox),
        guarded(Ack),
        guarded(ReadDecisions),
        guarded(TaskStatus),
        guarded(WorkStatus),
    ]
}

#[derive(Deserialize, JsonSchema)]
struct NoArgs {}

/// A list as the Lisp's `--jsonable` writes it: an empty list is `null`.
fn list_text<T: Serialize>(rows: Vec<T>) -> String {
    json_text(&(!rows.is_empty()).then_some(rows))
}

// ---- read_inbox ----

/// A message row as the Lisp's `drgnx-coord--message-plist` gives it (keys in its order).
#[derive(Serialize)]
struct MessageOut {
    id: i64,
    job: Option<String>,
    sender: Option<String>,
    recipient: Option<String>,
    text: Option<String>,
    state: String,
    reason: Option<String>,
    at: Option<f64>,
    delivered: Option<f64>,
    read: Option<f64>,
    acted: Option<f64>,
}

impl From<Message> for MessageOut {
    fn from(m: Message) -> Self {
        MessageOut {
            id: m.id,
            job: m.job,
            sender: m.sender,
            recipient: m.recipient,
            text: m.text,
            state: m.state,
            reason: m.reason,
            at: m.at,
            delivered: m.delivered,
            read: m.read,
            acted: m.acted,
        }
    }
}

struct ReadInbox;

impl CoordTool for ReadInbox {
    type Args = NoArgs;
    const NAME: &'static str = "read_inbox";
    const DESCRIPTION: &'static str = "Messages to you not read yet (they become read)";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        _: NoArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(read_inbox(coord, who))
    }
}

/// The caller's queued and delivered messages, which become read; the rows are as they were read.
async fn read_inbox(coord: &Coord, who: &Identity) -> Result<String, String> {
    let me = who.me()?.to_owned();
    let now = coord.now();
    let rows = coord
        .db()
        .write(move |tx| {
            let rows = inbox(tx, &me, &["queued", "delivered"])?;
            for m in &rows {
                mark(tx, m.id, "read", now)?;
            }
            Ok(rows)
        })
        .await
        .map_err(err)?;
    Ok(list_text(rows.into_iter().map(MessageOut::from).collect()))
}

// ---- ack ----

#[derive(Deserialize, JsonSchema)]
struct AckArgs {
    /// The message's id
    id: i64,
}

struct Ack;

impl CoordTool for Ack {
    type Args = AckArgs;
    const NAME: &'static str = "ack";
    const DESCRIPTION: &'static str = "Say you acted on a message";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: AckArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(ack(coord, who, args))
    }
}

/// `ack`: the message must be the caller's; nothing changed means no news for the hub.
async fn ack(coord: &Coord, who: &Identity, args: AckArgs) -> Result<String, String> {
    let id = args.id;
    let found = coord
        .db()
        .read(move |c| message(c, id))
        .await
        .map_err(err)?;
    let no_message = || format!("No message {id} for you");
    let Some(m) = found else {
        return Err(no_message());
    };
    if m.recipient.as_deref() != Some(who.me()?) {
        return Err(no_message());
    }
    let now = coord.now();
    let moved = coord
        .db()
        .write(move |tx| mark(tx, id, "acted", now))
        .await
        .map_err(err)?;
    if moved {
        coord.hub().notify();
    }
    Ok("acted".into())
}

// ---- read_decisions ----

#[derive(Deserialize, JsonSchema)]
struct ReadDecisionsArgs {
    /// The last version you read (0 for all)
    since: Option<i64>,
}

#[derive(Serialize)]
struct DecisionsOut {
    version: u64,
    decisions: Option<Vec<DecisionOut>>,
}

struct ReadDecisions;

impl CoordTool for ReadDecisions {
    type Args = ReadDecisionsArgs;
    const NAME: &'static str = "read_decisions";
    const DESCRIPTION: &'static str =
        "The decision log since a version (0: all), and the current version";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ReadDecisionsArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(read_decisions(coord, who, args))
    }
}

/// `read_decisions`: the caller's `seen` is set to the current version, only when it changed (the hub stops telling
/// it).
async fn read_decisions(
    coord: &Coord,
    who: &Identity,
    args: ReadDecisionsArgs,
) -> Result<String, String> {
    let me = who.id().map(str::to_owned);
    let since = args.since.unwrap_or(0).max(0) as u64;
    let (v, last, found) = {
        let me = me.clone();
        coord
            .db()
            .read(move |c| {
                let v = version(c)?;
                let last = match &me {
                    Some(me) => Some(seen(c, me)?),
                    None => None,
                };
                Ok((v, last, decisions_since(c, since, None)?))
            })
            .await
            .map_err(err)?
    };
    if let (Some(me), Some(last)) = (me, last)
        && last != v
    {
        coord
            .db()
            .write(move |tx| set_seen(tx, &me, v))
            .await
            .map_err(err)?;
    }
    Ok(json_text(&DecisionsOut {
        version: v,
        decisions: decisions_out(&found),
    }))
}

// ---- task_status ----

#[derive(Deserialize, JsonSchema)]
struct TaskStatusArgs {
    /// The job (default: yours)
    job: Option<String>,
}

/// A job's task as the Lisp's `drgnx-coord--task-plist` gives it (keys in its order).
#[derive(Serialize)]
struct TaskOut {
    id: String,
    n: i64,
    title: Option<String>,
    role: Option<String>,
    status: Option<String>,
    agent: Option<String>,
    lease_until: Option<f64>,
    deps: Option<Vec<String>>,
}

struct TaskStatus;

impl CoordTool for TaskStatus {
    type Args = TaskStatusArgs;
    const NAME: &'static str = "task_status";
    const DESCRIPTION: &'static str = "The job's tasks: status, agent, dependencies";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: TaskStatusArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(task_status(coord, who, args))
    }
}

/// `task_status`: the named job's tasks, else the caller's job's (an outside caller has none: `null`).
async fn task_status(
    coord: &Coord,
    who: &Identity,
    args: TaskStatusArgs,
) -> Result<String, String> {
    let Some(job) = args.job.or_else(|| who.job().map(str::to_owned)) else {
        return Ok("null".into());
    };
    let list = coord
        .db()
        .read(move |c| tasks(c, &job))
        .await
        .map_err(err)?;
    Ok(list_text(
        list.into_iter()
            .map(|t| TaskOut {
                id: t.row.id,
                n: t.row.n,
                title: t.row.title,
                role: t.row.role,
                status: t.row.status,
                agent: t.row.agent,
                lease_until: t.row.lease_until,
                deps: (!t.deps.is_empty()).then_some(t.deps),
            })
            .collect(),
    ))
}

// ---- work_status ----

/// One node of the work tracker's graph, with what the counts read (`drgnx-work--row-node`).
struct Node {
    id: String,
    kind: Option<String>,
    title: Option<String>,
    path: Option<String>,
    status: Option<String>,
    parent: Option<String>,
    data: Data,
}

/// What a node's `data` holds that the status reads.  A `data` the node-data schema refuses reads as empty
/// (`drgnx-work-db-decode`): a wrong type for one of its fields, or not an object.
#[derive(Default)]
struct Data {
    branch: Option<String>,
    merged: bool,
}

/// The node-data schema's fields by type (`drgnx-records-node-data`).
const DATA_STRINGS: [&str; 5] = ["sha", "repo", "name", "branch", "worktree"];
const DATA_INTEGERS: [&str; 2] = ["date", "seq"];
const DATA_BOOLEANS: [&str; 5] = ["range-stale", "merged", "gone", "stale", "truncated"];

fn decode_data(text: Option<String>) -> Data {
    let Some(Value::Object(o)) = text.and_then(|t| serde_json::from_str(&t).ok()) else {
        return Data::default();
    };
    let fits = |names: &[&str], ok: fn(&Value) -> bool| {
        names
            .iter()
            .all(|k| o.get(*k).is_none_or(|v| v.is_null() || ok(v)))
    };
    if !(fits(&DATA_STRINGS, Value::is_string)
        && fits(&DATA_INTEGERS, |v| v.is_i64() || v.is_u64())
        && fits(&DATA_BOOLEANS, Value::is_boolean))
    {
        return Data::default();
    }
    Data {
        branch: o.get("branch").and_then(Value::as_str).map(str::to_owned),
        merged: o.get("merged").and_then(Value::as_bool).unwrap_or(false),
    }
}

const NODE_SELECT: &str = "select id, kind, title, path, status, parent, data from node";

/// The row closure for [`NODE_SELECT`] (a macro: `urdr` does not export SQLite's row type).
macro_rules! node_row {
    () => {
        |r| {
            Ok(Node {
                id: r.get(0)?,
                kind: r.get(1)?,
                title: r.get(2)?,
                path: r.get(3)?,
                status: r.get(4)?,
                parent: r.get(5)?,
                data: decode_data(r.get(6)?),
            })
        }
    };
}

/// Node ID, or `None` (`drgnx-work-node`).
fn node(tx: &Tx, id: &str) -> Result<Option<Node>, CoordError> {
    opt(tx.query_row(&format!("{NODE_SELECT} where id = ?1"), [id], node_row!()))
}

/// The tree children of ID (`drgnx-work-children`): the nodes whose parent it is, then those with a `derives` or
/// `implements` edge into it.  The Lisp sorts the second part; the counts do not depend on the order.
fn children(tx: &Tx, id: &str) -> Result<Vec<Node>, CoordError> {
    let mut out: Vec<Node> = {
        let mut st = tx.prepare(&format!(
            "{NODE_SELECT} where parent = ?1 order by ord, line, title"
        ))?;
        let rows = st.query_map([id], node_row!())?;
        rows.collect::<Result<_, _>>()?
    };
    for kind in ["derives", "implements"] {
        let srcs: Vec<String> = {
            let mut st =
                tx.prepare("select src from edge where dst = ?1 and kind = ?2 order by src")?;
            let rows = st.query_map((id, kind), |r| r.get(0))?;
            rows.collect::<Result<_, _>>()?
        };
        for src in srcs {
            out.extend(node(tx, &src)?);
        }
    }
    Ok(out)
}

/// `(DONE . ALL)` of NODES whose status is done.
fn done_of<'a>(nodes: impl Iterator<Item = &'a Node>, done: impl Fn(&Node) -> bool) -> Pair {
    nodes.fold((0, 0), |(d, n), x| (d + usize::from(done(x)), n + 1))
}

/// A string, or the empty object where the Lisp has nil (`json-serialize` writes nil as `{}`).
fn nil_object<S: Serializer>(v: &Option<String>, s: S) -> Result<S::Ok, S::Error> {
    match v {
        Some(v) => s.serialize_str(v),
        None => {
            use serde::ser::SerializeMap;
            s.serialize_map(Some(0))?.end()
        }
    }
}

/// `(DONE, ALL)`, which the row writes as `[done, all]`.
type Pair = (usize, usize);

/// A plan's row (`drgnx-work--json-row`, keys in its order).
#[derive(Serialize)]
struct PlanRow {
    id: String,
    #[serde(serialize_with = "nil_object")]
    title: Option<String>,
    #[serde(serialize_with = "nil_object")]
    path: Option<String>,
    spec: Option<String>,
    branch: Option<String>,
    merged: bool,
    tasks: Pair,
    steps: Pair,
    todos: Pair,
    commits: usize,
}

/// `drgnx-work-counts` of PLAN, as the row's `tasks`, `steps`, `todos` and `commits`.
fn counts(tx: &Tx, plan: &str) -> Result<(Pair, Pair, Pair, usize), CoordError> {
    let kids = children(tx, plan)?;
    let is = |n: &Node, kind: &str| n.kind.as_deref() == Some(kind);
    let is_done = |n: &Node| n.status.as_deref() == Some("done");
    let task_nodes: Vec<&Node> = kids.iter().filter(|n| is(n, "task")).collect();
    let todo_nodes: Vec<&Node> = kids.iter().filter(|n| is(n, "todo")).collect();
    let mut task_kids = Vec::new();
    for t in &task_nodes {
        task_kids.extend(children(tx, &t.id)?);
    }
    let done_tasks: Vec<&str> = task_nodes
        .iter()
        .filter(|n| is_done(n))
        .map(|n| n.id.as_str())
        .collect();
    // a step is done when ticked, or when its task is complete
    let steps = done_of(task_kids.iter().filter(|n| is(n, "step")), |n| {
        is_done(n) || n.parent.as_deref().is_some_and(|p| done_tasks.contains(&p))
    });
    let mut todo_kids = Vec::new();
    for t in &todo_nodes {
        todo_kids.extend(children(tx, &t.id)?);
    }
    let mut commits: Vec<&str> = Vec::new();
    for n in kids.iter().chain(&task_kids).chain(&todo_kids) {
        if is(n, "commit") && !commits.contains(&n.id.as_str()) {
            commits.push(&n.id);
        }
    }
    Ok((
        done_of(task_nodes.iter().copied(), is_done),
        steps,
        done_of(todo_nodes.iter().copied(), is_done),
        commits.len(),
    ))
}

/// One row per plan, sorted by path (`drgnx-work--status-rows`).
fn status_rows(tx: &Tx) -> Result<Vec<PlanRow>, CoordError> {
    let mut plans: Vec<Node> = {
        let mut st = tx.prepare(&format!("{NODE_SELECT} where kind = 'plan' order by rowid"))?;
        let rows = st.query_map([], node_row!())?;
        rows.collect::<Result<_, _>>()?
    };
    // `string<` reads a missing path as the symbol `nil`; the sort is stable
    plans.sort_by(|a, b| {
        a.path
            .as_deref()
            .unwrap_or("nil")
            .cmp(b.path.as_deref().unwrap_or("nil"))
    });
    let mut rows = Vec::new();
    for p in plans {
        let spec: Option<String> = opt(tx.query_row(
            "select dst from edge where src = ?1 and kind = 'derives' order by dst limit 1",
            [&p.id],
            |r| r.get(0),
        ))?;
        let (done_tasks, steps, todos, commits) = counts(tx, &p.id)?;
        rows.push(PlanRow {
            id: p.id,
            title: p.title,
            path: p.path,
            spec,
            branch: p.data.branch,
            merged: p.data.merged,
            tasks: done_tasks,
            steps,
            todos,
            commits,
        });
    }
    Ok(rows)
}

struct WorkStatus;

impl CoordTool for WorkStatus {
    type Args = NoArgs;
    const NAME: &'static str = "work_status";
    const DESCRIPTION: &'static str = "The work tracker's plans: what `drgnx work status --json' gives, one object per plan (tasks, steps, todos as [done, all], commits, branch, merged)";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        _: &'a Identity,
        _: NoArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let rows = coord.db().read(status_rows).await.map_err(err)?;
            Ok(json_text(&rows))
        })
    }
}
