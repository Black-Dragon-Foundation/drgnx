//! The tracker tools — `task_read`, `task_write`, `note_add` (Task 14; storage §6.1) — the per-session tool list
//! (call 16), the plumbing the five new tools share (the caller from the identity, the scoped view of an entity,
//! the answer with its notices) and `hello`'s brief.
//!
//! Every tool here is a [`RichTool`]: it answers text plus `structuredContent` (every text field an
//! [`Authored`](crate::trust::Authored), so the author and the trust travel with it, and the text rendering fences
//! untrusted text), `resource_link` items for the entities it names, and `_meta["dev.drgnx/notices"]`.

use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError};

use mimir::{ArgsError, BoxFuture, Tool, ToolResult, typed};
use schemars::JsonSchema;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};
use urdr::Connection;
use urdr::graph::entity::{self, Ent, Origin};
use urdr::graph::schema::SENTINEL;
use urdr::graph::walk::{Scope, Seen};
use urdr::graph::{Class, TxMeta, WriteError, link};

use super::guard::{NO_IDENTITY_ARG, identity_arg, refuse_identity_args};
use super::{Coord, Ctx, Identity};
use crate::grants::{self, Access, Filter};
use crate::project;
use crate::scope::{self, Caller, Reach, StoreScope};
use crate::store::CoordError;
use crate::tracker::notices::notices_unread;
use crate::tracker::{self, TaskAnswer, TaskOp};
use crate::trust::{Authored, authored};
use crate::write::meta;

/// Which tool sets a session gets (call 16: on by default; a profile or a task turns them off).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ToolSets {
    /// The five tracker and graph tools.
    pub tracker: bool,
}

impl Default for ToolSets {
    fn default() -> Self {
        ToolSets { tracker: true }
    }
}

/// The five tools the `tracker` set adds.
pub const TRACKER_TOOLS: [&str; 5] = [
    "task_read",
    "task_write",
    "note_add",
    "graph_read",
    "access_request",
];

/// The most rows a list carries.
pub const LIST_MAX: usize = 50;

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![rich(TaskRead), rich(TaskWrite), rich(NoteAdd)]
}

/// The tools a session with SETS is served: 23 with the tracker tools, p2–p3's 16 and the two settings tools without
/// (the settings tools are every agent's: unified-settings call 10).
pub fn tools_for(sets: ToolSets) -> Vec<Box<dyn Tool<Ctx>>> {
    let mut all = super::report::tools_for(sets.tracker);
    all.extend(super::job::tools());
    all.extend(super::read::tools());
    if sets.tracker {
        all.extend(tools());
        all.extend(super::graph::tools());
    }
    all.extend(super::settings::tools());
    all
}

// ---------------------------------------------------------------------------------------------------------- plumbing

/// What a [`RichTool`] answers.
pub(super) struct Answer {
    pub text: String,
    pub structured: Value,
    /// The ids of the entities it names (`resource_link` items, at most [`LIST_MAX`]).
    pub links: Vec<String>,
}

/// A tracker or graph tool's body, behind the guard of every coordination tool and with the notices on its answer.
pub(super) trait RichTool: Send + Sync + 'static {
    type Args: DeserializeOwned + JsonSchema + Send + 'static;
    const NAME: &'static str;
    const DESCRIPTION: &'static str;
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: Self::Args,
    ) -> BoxFuture<'a, Result<Answer, String>>;
}

struct Rich<T>(T);

/// TOOL as a `mimir` tool.
pub(super) fn rich<T: RichTool>(tool: T) -> Box<dyn Tool<Ctx>> {
    Box::new(Rich(tool))
}

/// Every new tool's `outputSchema`: an object (the shapes are in docs/develop/coordination.md).
fn output_schema() -> Value {
    json!({"type": "object"})
}

impl<T: RichTool> Tool<Ctx> for Rich<T> {
    fn name(&self) -> &'static str {
        T::NAME
    }

    fn description(&self) -> &'static str {
        T::DESCRIPTION
    }

    fn input_schema(&self) -> Value {
        typed::<T::Args>().schema()
    }

    fn output_schema(&self) -> Option<Value> {
        Some(output_schema())
    }

    fn check(&self, args: &Value) -> Result<(), ArgsError> {
        if let Some(k) = identity_arg(args) {
            return Err(ArgsError {
                path: k.into(),
                message: NO_IDENTITY_ARG.into(),
            });
        }
        typed::<T::Args>().check(args)
    }

    fn call<'a>(&'a self, ctx: &'a Ctx, args: Value) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            match run_checked(&self.0, &ctx.0, &ctx.1, args).await {
                Ok(a) => finish(&ctx.0, &ctx.1, a).await,
                Err(text) => ToolResult::Err(text),
            }
        })
    }
}

async fn run_checked<T: RichTool>(
    tool: &T,
    coord: &Coord,
    who: &Identity,
    args: Value,
) -> Result<Answer, String> {
    who.check()?;
    refuse_identity_args(&args, who)?;
    let args = typed::<T::Args>()
        .decode(&args)
        .map_err(|e| e.to_string())?;
    tool.run(coord, who, args).await
}

/// The actor a caller's notices and writes are under (`agent:SID`, `ext:KIND:PID-HASH`).
fn actor_of(who: &Identity) -> Option<String> {
    match who {
        Identity::Session { sid, .. } => Some(format!("agent:{sid}")),
        Identity::Outside { id, .. } => Some(id.clone()),
        Identity::None => None,
    }
}

/// WHO's unread notices (0 when they cannot be counted: a notice count never fails an answer).
async fn unread(coord: &Coord, who: &Identity) -> u32 {
    let Some(actor) = actor_of(who) else { return 0 };
    coord
        .db()
        .read(move |c| Ok(notices_unread(c, &actor)?))
        .await
        .unwrap_or(0)
}

/// An answer with its notices: `_meta["dev.drgnx/notices"]`, and a last text line only when there are some.
async fn finish(coord: &Coord, who: &Identity, a: Answer) -> ToolResult {
    let n = unread(coord, who).await;
    let mut text = a.text;
    if n > 0 {
        text.push_str(&format!("\nnotices: {n} (read_inbox)"));
    }
    let content = a
        .links
        .iter()
        .take(LIST_MAX)
        .map(|id| json!({"type": "resource_link", "uri": format!("drgnx://entity/{id}"), "name": id}))
        .collect();
    ToolResult::Rich {
        text,
        structured: Some(a.structured),
        content,
        meta: Some(json!({"dev.drgnx/notices": n})),
    }
}

/// A store error as the tool's error text.
pub(super) fn err(e: CoordError) -> String {
    e.to_string()
}

/// WHO as a store caller: the class and the actor from the identity, the project of the folder it works in
/// (resolved once and kept in [`Coord::projects`]). With REGISTER the project is made in the store when it is new
/// (writes); without, only a project the store knows is used (reads write nothing).
pub(super) async fn caller_of(
    coord: &Coord,
    who: &Identity,
    register: bool,
) -> Result<Caller, String> {
    who.check()?;
    if let Some(home) = who.home() {
        let home = home.to_path_buf();
        let known = coord.projects().lock().unwrap().project_n(&home).is_some();
        if !known {
            let cached = coord.projects().lock().unwrap().get(&home).cloned();
            let found = match cached {
                Some(p) => Some(p),
                None => {
                    let dir = home.clone();
                    let p = tokio::task::spawn_blocking(move || project::resolve(&dir))
                        .await
                        .ok()
                        .flatten();
                    coord
                        .projects()
                        .lock()
                        .unwrap()
                        .insert(home.clone(), p.clone());
                    p
                }
            };
            if let Some(p) = found {
                let n = if register {
                    let p2 = p.clone();
                    coord
                        .db()
                        .write(
                            TxMeta::new("hub", Class::System, "mcp:project"),
                            move |tx| Ok(project::register(tx, &p2)?),
                        )
                        .await
                        .ok()
                } else {
                    let id = p.id.clone();
                    coord
                        .db()
                        .read(move |c| {
                            Ok(entity::by_id(c, &id)?
                                .filter(|e| e.retired_tx.is_none())
                                .map(|e| e.n))
                        })
                        .await
                        .ok()
                        .flatten()
                };
                if let Some(n) = n {
                    coord.projects().lock().unwrap().set_registered(&p.id, n);
                }
            }
        }
    }
    Ok(Caller::from_identity(
        who,
        &coord.projects().lock().unwrap(),
    ))
}

/// The entity `n` as an id string, for an `Authored`'s `project`.
fn project_id(conn: &Connection, n: Option<i64>) -> Result<Option<String>, urdr::SqliteError> {
    match n {
        Some(n) => {
            tracker::opt(conn.query_row("select id from entity where n = ?1", [n], |r| r.get(0)))
        }
        None => Ok(None),
    }
}

/// Text TEXT written by BY (the caller), as the caller reads its own words: untrusted.
pub(super) fn own(text: &str, caller: &Caller, tx: i64, project: Option<String>) -> Value {
    json!(Authored::new(
        text,
        &caller.actor,
        caller.class,
        tx,
        project,
        false
    ))
}

fn authored_json(
    conn: &Connection,
    e: &Ent,
    field: &str,
) -> Result<Option<Value>, urdr::SqliteError> {
    Ok(authored(conn, e, field)?.map(|a| json!(a)))
}

/// A caller's view of the store: its scope at one moment.
pub(super) struct Look<'a> {
    pub conn: &'a Connection,
    pub scope: StoreScope,
}

impl<'a> Look<'a> {
    pub fn new(
        conn: &'a Connection,
        caller: &Caller,
        now: f64,
    ) -> Result<Look<'a>, urdr::SqliteError> {
        Ok(Look {
            conn,
            scope: scope::for_caller(conn, caller, now)?,
        })
    }

    /// How E shows to the caller.
    pub fn seen(&self, e: &Ent) -> Seen {
        self.scope.allows(e.project)
    }

    /// E with its id, kind and title (an `Authored`): what a link or a stub shows. `None` when hidden.
    pub fn reference(&self, e: &Ent) -> Result<Option<Value>, urdr::SqliteError> {
        if self.seen(e) == Seen::Hidden {
            return Ok(None);
        }
        Ok(Some(json!({
            "id": e.id,
            "kind": e.kind,
            "title": authored_json(self.conn, e, "title")?,
        })))
    }

    /// E as the caller may read it, with the line a text answer shows: `None` when hidden. A stub is its reference;
    /// a full view adds status, assignee, priority, version, labels and a live lease, and with DETAIL the body and
    /// the acceptance.
    pub fn view(
        &self,
        e: &Ent,
        detail: bool,
    ) -> Result<Option<(Value, String)>, urdr::SqliteError> {
        let title = authored(self.conn, e, "title")?;
        let shown = title.as_ref().map(Authored::render).unwrap_or_default();
        match self.seen(e) {
            Seen::Hidden => Ok(None),
            Seen::Stub => Ok(Some((
                json!({"id": e.id, "kind": e.kind, "title": title.map(|t| json!(t))}),
                format!("{} {shown}", e.id),
            ))),
            Seen::Full => {
                let mut o = Map::new();
                o.insert("id".into(), json!(e.id));
                o.insert("kind".into(), json!(e.kind));
                o.insert("ver".into(), json!(e.ver));
                o.insert("project".into(), json!(project_id(self.conn, e.project)?));
                o.insert("title".into(), json!(title));
                for field in ["status", "assignee"] {
                    if let Some(a) = authored_json(self.conn, e, field)? {
                        o.insert(field.into(), a);
                    }
                }
                if let Some(p) = e.priority {
                    o.insert("priority".into(), json!(p));
                }
                let labels = tracker::labels_of(e);
                if !labels.is_empty() {
                    o.insert("labels".into(), json!(labels));
                }
                if e.lease.holder.is_some() {
                    o.insert(
                        "lease".into(),
                        json!({"holder": e.lease.holder, "epoch": e.lease.epoch, "until": e.lease.until}),
                    );
                }
                if detail {
                    if let Some(b) = authored_json(self.conn, e, "body")? {
                        o.insert("body".into(), b);
                    }
                    if let Some(acc) = e.data.get("acceptance").and_then(Value::as_str) {
                        let mut tmp = e.clone();
                        tmp.body = Some(acc.to_owned());
                        tmp.field_tx.insert("body".into(), e.updated_tx);
                        o.insert(
                            "acceptance".into(),
                            authored_json(self.conn, &tmp, "body")?.unwrap_or(Value::Null),
                        );
                    }
                }
                let status = e.status.as_deref().unwrap_or("-");
                let mut line = format!("{} [{status}]", e.id);
                if let Some(p) = e.priority {
                    line.push_str(&format!(" p{p}"));
                }
                line.push(' ');
                line.push_str(&shown);
                Ok(Some((Value::Object(o), line)))
            }
        }
    }

    /// The current links of E (both ways) whose other end the caller may see, at most [`LIST_MAX`] and how many were
    /// hidden: `{dir, kind, id, ...}`.
    pub fn links(&self, e: &Ent) -> Result<(Vec<Value>, u32), urdr::SqliteError> {
        let mut stmt = self.conn.prepare(&format!(
            "select src, kind, dst from link where (src = ?1 or dst = ?1) and tx_to = {SENTINEL} order by id limit 500"
        ))?;
        let rows: Vec<(i64, String, i64)> = stmt
            .query_map([e.n], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<Result<_, _>>()?;
        let (mut out, mut hidden) = (Vec::new(), 0);
        for (src, kind, dst) in rows {
            let (dir, other) = if src == e.n {
                ("out", dst)
            } else {
                ("in", src)
            };
            let Some(o) = entity::by_n(self.conn, other)?.filter(|o| o.retired_tx.is_none()) else {
                continue;
            };
            match self.reference(&o)? {
                Some(mut r) => {
                    r["dir"] = json!(dir);
                    r["link"] = json!(kind);
                    if out.len() < LIST_MAX {
                        out.push(r);
                    }
                }
                None => hidden += 1,
            }
        }
        Ok((out, hidden))
    }

    /// The notes about E the caller may see, newest last, at most [`LIST_MAX`]: `{id, kind, body}`.
    pub fn notes(&self, e: &Ent) -> Result<Vec<Value>, urdr::SqliteError> {
        let mut stmt = self.conn.prepare(&format!(
            "select src from link where dst = ?1 and kind = 'about' and tx_to = {SENTINEL} order by id limit 200"
        ))?;
        let ns: Vec<i64> = stmt
            .query_map([e.n], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        let mut out = Vec::new();
        for n in ns {
            let Some(note) =
                entity::by_n(self.conn, n)?.filter(|o| o.retired_tx.is_none() && o.kind == "note")
            else {
                continue;
            };
            if self.seen(&note) != Seen::Full {
                continue;
            }
            out.push(json!({
                "id": note.id,
                "kind": note.data.get("kind"),
                "body": authored_json(self.conn, &note, "body")?,
            }));
            if out.len() == LIST_MAX {
                break;
            }
        }
        Ok(out)
    }
}

/// The offset a `cursor` names (`o:N`); none is 0.
pub(super) fn offset_of(cursor: &Option<String>) -> Result<usize, String> {
    match cursor.as_deref() {
        None => Ok(0),
        Some(c) => c
            .strip_prefix("o:")
            .and_then(|n| n.parse().ok())
            .ok_or_else(|| format!("{c:?} is not a cursor from an earlier answer")),
    }
}

/// A page of ROWS (each a view and its line) from OFFSET: the answer of a list, with the cursor for the next page.
pub(super) fn page(rows: Vec<(Value, String)>, offset: usize, key: &str) -> Answer {
    let more = rows.len() > LIST_MAX;
    let rows: Vec<(Value, String)> = rows.into_iter().take(LIST_MAX).collect();
    let links = rows
        .iter()
        .filter_map(|(v, _)| v.get("id").and_then(Value::as_str).map(str::to_owned))
        .collect();
    let mut text: Vec<String> = rows.iter().map(|(_, l)| l.clone()).collect();
    if text.is_empty() {
        text.push("nothing".into());
    }
    let mut structured = json!({});
    structured[key] = Value::Array(rows.iter().map(|(v, _)| v.clone()).collect());
    if more {
        let next = format!("o:{}", offset + LIST_MAX);
        text.push(format!("more: cursor {next}"));
        structured["next_cursor"] = json!(next);
    }
    Answer {
        text: text.join("\n"),
        structured,
        links,
    }
}

/// The 4th field of a requiring op: its value, or what is missing.
fn need<T>(v: Option<T>, field: &str, op: &str) -> Result<T, String> {
    v.ok_or_else(|| format!("{op} needs {field}"))
}

// ------------------------------------------------------------------------------------------------------- task_read

#[derive(Deserialize, JsonSchema)]
struct TaskReadArgs {
    /// get, find, ready or mine
    op: String,
    /// get: the task's id
    id: Option<String>,
    /// get: also links, notes and/or history
    include: Option<Vec<String>>,
    /// find: words to search for
    query: Option<String>,
    /// find: only this status
    status: Option<String>,
    /// find: only this assignee
    assignee: Option<String>,
    /// find, ready: only tasks with all of these labels
    labels: Option<Vec<String>>,
    /// ready: at most this many (up to 50)
    limit: Option<i64>,
    /// find, ready, mine: the `next_cursor` of the page before
    cursor: Option<String>,
    /// Full bodies and links
    detail: Option<bool>,
}

struct TaskRead;

impl RichTool for TaskRead {
    type Args = TaskReadArgs;
    const NAME: &'static str = "task_read";
    const DESCRIPTION: &'static str = "Read tasks in your project (and projects granted to you): get one by id (include links, notes, history), find by words, ready (what you can claim now), mine (yours). Text by others is fenced as untrusted data";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: TaskReadArgs,
    ) -> BoxFuture<'a, Result<Answer, String>> {
        Box::pin(task_read(coord, who, args))
    }
}

async fn task_read(coord: &Coord, who: &Identity, a: TaskReadArgs) -> Result<Answer, String> {
    let caller = caller_of(coord, who, false).await?;
    let now = coord.now();
    let offset = offset_of(&a.cursor)?;
    let detail = a.detail.unwrap_or(false);
    match a.op.as_str() {
        "get" => {
            let id = need(a.id, "id", "get")?;
            let include = a.include.unwrap_or_default();
            if let Some(bad) = include.iter().find(|i| !["links", "notes", "history"].contains(&i.as_str())) {
                return Err(format!("include is links, notes or history, not {bad:?}"));
            }
            coord
                .db()
                .read(move |c| get(c, &caller, now, &id, &include, detail))
                .await
                .map_err(err)?
        }
        "find" => {
            let q = FindQ {
                query: a.query,
                status: a.status,
                assignee: a.assignee,
                labels: a.labels.unwrap_or_default(),
            };
            coord
                .db()
                .read(move |c| find(c, &caller, now, q, offset, detail))
                .await
                .map_err(err)
        }
        "ready" => {
            let limit = a.limit.map_or(LIST_MAX, |l| (l.max(1) as usize).min(LIST_MAX));
            let labels = a.labels.unwrap_or_default();
            coord
                .db()
                .read(move |c| {
                    let look = Look::new(c, &caller, now)?;
                    let want = (offset + limit + 1) as u32;
                    let ents = tracker::ready(c, &look.scope, &labels, want)?;
                    let mut rows = Vec::new();
                    for e in ents.iter().skip(offset).take(limit + 1) {
                        rows.extend(look.view(e, detail)?);
                    }
                    Ok(cap(page(rows, offset, "tasks"), limit))
                })
                .await
                .map_err(err)
        }
        "mine" => coord
            .db()
            .read(move |c| {
                let look = Look::new(c, &caller, now)?;
                let mut stmt = c.prepare(
                    "select n from entity where kind = 'task' and retired_tx is null \
                     and (assignee = ?1 or lease_holder = ?1) and coalesce(status, '') not in ('done', 'dropped') \
                     order by coalesce(priority, 1000000), n",
                )?;
                let ns: Vec<i64> = stmt
                    .query_map([&caller.actor], |r| r.get(0))?
                    .collect::<Result<_, _>>()?;
                let mut rows = Vec::new();
                for n in ns.into_iter().skip(offset) {
                    if let Some(e) = entity::by_n(c, n)? {
                        rows.extend(look.view(&e, detail)?);
                    }
                    if rows.len() > LIST_MAX {
                        break;
                    }
                }
                Ok(page(rows, offset, "tasks"))
            })
            .await
            .map_err(err),
        other => Err(format!("op is get, find, ready or mine, not {other:?}")),
    }
}

/// A page of at most LIMIT rows (`ready` asks for fewer than the list cap).
fn cap(mut a: Answer, limit: usize) -> Answer {
    let over = a
        .structured
        .get("tasks")
        .and_then(Value::as_array)
        .is_some_and(|r| r.len() > limit);
    if over {
        if let Some(rows) = a.structured["tasks"].as_array_mut() {
            rows.truncate(limit);
        }
        a.links.truncate(limit);
        a.text = a.text.lines().take(limit).collect::<Vec<_>>().join("\n");
        if let Some(o) = a.structured.as_object_mut() {
            o.remove("next_cursor");
        }
    }
    a
}

fn get(
    c: &Connection,
    caller: &Caller,
    now: f64,
    id: &str,
    include: &[String],
    detail: bool,
) -> Result<Result<Answer, String>, CoordError> {
    let look = Look::new(c, caller, now)?;
    let no = || Err(format!("no such task: {id}"));
    let Some(e) = entity::by_id(c, id)?.filter(|e| e.retired_tx.is_none() && e.kind == "task")
    else {
        return Ok(no());
    };
    let Some((mut view, line)) = look.view(&e, detail)? else {
        return Ok(no());
    };
    let mut text = vec![line];
    let full = look.seen(&e) == Seen::Full;
    let mut links = vec![e.id.clone()];
    if full && (detail || include.iter().any(|i| i == "links")) {
        let (ls, hidden) = look.links(&e)?;
        for l in &ls {
            text.push(format!(
                "{} {} {}",
                l["dir"].as_str().unwrap_or(""),
                l["link"].as_str().unwrap_or(""),
                l["id"].as_str().unwrap_or("")
            ));
            links.extend(l["id"].as_str().map(str::to_owned));
        }
        view["links"] = json!(ls);
        view["hidden"] = json!(hidden);
    }
    if full && include.iter().any(|i| i == "notes") {
        let notes = look.notes(&e)?;
        for n in &notes {
            let body = n["body"].as_object().map(|_| {
                serde_json::from_value::<Authored>(n["body"].clone())
                    .map(|a| a.render())
                    .unwrap_or_default()
            });
            text.push(format!(
                "note {}: {}",
                n["id"].as_str().unwrap_or(""),
                body.unwrap_or_default()
            ));
        }
        view["notes"] = json!(notes);
    }
    if full && include.iter().any(|i| i == "history") {
        let versions = urdr::graph::hist::history(c, e.n, None)?;
        for v in &versions {
            text.push(format!(
                "ver {} by {} ({}): {}",
                v.ver,
                v.actor,
                v.class.as_str(),
                v.fields.join(", ")
            ));
        }
        view["history"] = json!(versions);
    }
    Ok(Ok(Answer {
        text: text.join("\n"),
        structured: json!({ "task": view }),
        links,
    }))
}

struct FindQ {
    query: Option<String>,
    status: Option<String>,
    assignee: Option<String>,
    labels: Vec<String>,
}

/// Live entities in SCOPE with text and no vector: how far the vectors are behind for this caller (another
/// project's texts are neither its lag nor its business).
fn vectors_behind(c: &Connection, scope: &StoreScope) -> Result<i64, urdr::SqliteError> {
    let within = match scope.reach() {
        Reach::Everything => String::new(),
        Reach::AnyProject => " and e.project is not null".into(),
        Reach::Projects(ps) => format!(
            " and e.project in ({})",
            ps.iter().map(i64::to_string).collect::<Vec<_>>().join(", ")
        ),
    };
    c.query_row(
        &format!(
            "select count(*) from entity e where e.retired_tx is null and (e.title is not null or e.body is not null) \
             and not exists (select 1 from entity_vec v where v.n = e.n){within}"
        ),
        [],
        |r| r.get(0),
    )
}

fn find(
    c: &Connection,
    caller: &Caller,
    now: f64,
    q: FindQ,
    offset: usize,
    detail: bool,
) -> Result<Answer, CoordError> {
    let look = Look::new(c, caller, now)?;
    let wanted = offset + LIST_MAX + 1;
    let ns: Vec<i64> = match q.query.as_deref().filter(|s| !s.trim().is_empty()) {
        Some(words) => urdr::graph::search::find_fts(c, words, 1000)?
            .into_iter()
            .map(|h| h.n)
            .collect(),
        None => {
            let mut stmt = c.prepare(
                "select n from entity where kind = 'task' and retired_tx is null \
                 order by coalesce(priority, 1000000), n",
            )?;
            stmt.query_map([], |r| r.get(0))?
                .collect::<Result<_, _>>()?
        }
    };
    let mut rows = Vec::new();
    let mut seen_rows = 0;
    for n in ns {
        let Some(e) = entity::by_n(c, n)?.filter(|e| e.retired_tx.is_none() && e.kind == "task")
        else {
            continue;
        };
        if q.status
            .as_ref()
            .is_some_and(|s| e.status.as_ref() != Some(s))
            || q.assignee
                .as_ref()
                .is_some_and(|s| e.assignee.as_ref() != Some(s))
        {
            continue;
        }
        let have = tracker::labels_of(&e);
        if !q.labels.iter().all(|l| have.contains(l)) {
            continue;
        }
        let Some(v) = look.view(&e, detail)? else {
            continue;
        };
        seen_rows += 1;
        if seen_rows > offset {
            rows.push(v);
        }
        if seen_rows >= wanted {
            break;
        }
    }
    let mut a = page(rows, offset, "tasks");
    let behind = vectors_behind(c, &look.scope)?;
    let vectors = if behind > 0 {
        format!("behind {behind}")
    } else {
        "current".into()
    };
    a.structured["vectors"] = json!(vectors);
    if behind > 0 {
        a.text
            .push_str(&format!("\nvectors: {vectors} (ranked by words only)"));
    }
    Ok(a)
}

// ------------------------------------------------------------------------------------------------------ task_write

#[derive(Deserialize, JsonSchema)]
struct TaskWriteArgs {
    /// create, update, claim, heartbeat, release, handoff, reassign, split, complete, link, unlink, label or tools
    op: String,
    /// The task (every op but create, link and unlink)
    id: Option<String>,
    /// The task's version you read (update, reassign, split)
    ver: Option<i64>,
    /// The lease number claim gave you (heartbeat, release, handoff, complete)
    lease: Option<i64>,
    /// create, update: one line
    title: Option<String>,
    /// create, update
    body: Option<String>,
    /// create, update: lower is first
    priority: Option<i64>,
    /// create, update: when it is done
    acceptance: Option<String>,
    /// update: open, running, needs-input, in-review, blocked, done or dropped
    status: Option<String>,
    /// create: labels; label: use add and remove
    labels: Option<Vec<String>>,
    /// create: the parent task
    parent: Option<String>,
    /// handoff, reassign: an agent's id, or user
    to: Option<String>,
    /// release, handoff, reassign, complete: what was done and what is left
    note: Option<String>,
    /// split: the titles of the parts
    parts: Option<Vec<String>>,
    /// split: children (default) or replace
    mode: Option<String>,
    /// link, unlink: the source task
    src: Option<String>,
    /// link, unlink: blocks, parent_of, split_from, discovered_from, relates, duplicates
    kind: Option<String>,
    /// link, unlink: the target
    dst: Option<String>,
    /// label: labels to add
    add: Option<Vec<String>>,
    /// label: labels to remove
    remove: Option<Vec<String>>,
    /// tools (the user's): the task's tracker tools on or off
    tracker: Option<bool>,
    /// A request key (1-64 of A-Za-z0-9._-): retrying with the same key returns the first answer
    req: Option<String>,
}

/// Whether REQ is a request key.
fn valid_req(req: &str) -> bool {
    (1..=64).contains(&req.len())
        && req
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn task_op(a: TaskWriteArgs) -> Result<TaskOp, String> {
    let op = a.op.clone();
    let op = op.as_str();
    let id = || need(a.id.clone(), "id", op);
    Ok(match op {
        "create" => TaskOp::Create {
            title: need(a.title.clone(), "title", op)?,
            body: a.body.clone(),
            priority: a.priority,
            labels: a.labels.clone().unwrap_or_default(),
            acceptance: a.acceptance.clone(),
            parent: a.parent.clone(),
        },
        "update" => TaskOp::Update {
            id: id()?,
            ver: need(a.ver, "ver", op)?,
            title: a.title.clone(),
            body: a.body.clone(),
            priority: a.priority,
            acceptance: a.acceptance.clone(),
            status: a.status.clone(),
        },
        "claim" => TaskOp::Claim { id: id()? },
        "heartbeat" => TaskOp::Heartbeat {
            id: id()?,
            lease: need(a.lease, "lease", op)?,
        },
        "release" => TaskOp::Release {
            id: id()?,
            lease: need(a.lease, "lease", op)?,
            note: a.note.clone(),
        },
        "handoff" => TaskOp::Handoff {
            id: id()?,
            lease: need(a.lease, "lease", op)?,
            to: a.to.clone(),
            note: a.note.clone().unwrap_or_default(),
        },
        "reassign" => TaskOp::Reassign {
            id: id()?,
            ver: need(a.ver, "ver", op)?,
            to: a.to.clone(),
            note: a.note.clone().unwrap_or_default(),
        },
        "split" => TaskOp::Split {
            id: id()?,
            ver: need(a.ver, "ver", op)?,
            parts: need(a.parts.clone(), "parts", op)?,
            mode: a.mode.clone(),
        },
        "complete" => TaskOp::Complete {
            id: id()?,
            lease: need(a.lease, "lease", op)?,
            note: a.note.clone(),
        },
        "link" | "unlink" => {
            let (src, kind, dst) = (
                need(a.src.clone(), "src", op)?,
                need(a.kind.clone(), "kind", op)?,
                need(a.dst.clone(), "dst", op)?,
            );
            if op == "link" {
                TaskOp::Link { src, kind, dst }
            } else {
                TaskOp::Unlink { src, kind, dst }
            }
        }
        "label" => TaskOp::Label {
            id: id()?,
            add: a.add.clone().unwrap_or_default(),
            remove: a.remove.clone().unwrap_or_default(),
        },
        "tools" => TaskOp::Tools {
            id: id()?,
            tracker: a.tracker,
        },
        other => {
            return Err(format!(
                "op is create, update, claim, heartbeat, release, handoff, reassign, split, complete, link, unlink, label or tools, not {other:?}"
            ));
        }
    })
}

struct TaskWrite;

impl RichTool for TaskWrite {
    type Args = TaskWriteArgs;
    const NAME: &'static str = "task_write";
    const DESCRIPTION: &'static str = "Change tasks in your project: create, update (with ver), claim (lease), heartbeat, release, handoff, reassign, split, complete, link, unlink, label. Answers {id, title, ver, lease?}, a conflict (re-read, retry) or a refusal that says what to do next";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: TaskWriteArgs,
    ) -> BoxFuture<'a, Result<Answer, String>> {
        Box::pin(task_write(coord, who, args))
    }
}

/// A task op's answer, as the caller reads it.
fn task_answer(a: &TaskAnswer, caller: &Caller, tx: i64, project: Option<String>) -> Answer {
    match a {
        TaskAnswer::Done {
            id,
            title,
            ver,
            lease,
            parts,
        } => {
            let mut s = json!({
                "id": id, "title": own(title, caller, tx, project), "ver": ver,
            });
            if let Some(l) = lease {
                s["lease"] = json!(l);
            }
            let mut text = format!("done: {id} at ver {ver}");
            if let Some(l) = lease {
                text.push_str(&format!(", lease {l}"));
            }
            let mut links = vec![id.clone()];
            if !parts.is_empty() {
                s["parts"] = json!(parts);
                text.push_str(&format!("; parts: {}", parts.join(", ")));
                links.extend(parts.iter().cloned());
            }
            Answer {
                text,
                structured: json!({"done": s}),
                links,
            }
        }
        TaskAnswer::Conflict {
            id,
            ver,
            changed_since,
            next,
        } => {
            let changes: Vec<Value> = changed_since
                .iter()
                .map(|c| {
                    let to = match &c.to {
                        Value::String(t) => json!(Authored::new(
                            t,
                            &c.by,
                            c.class,
                            c.tx,
                            project.clone(),
                            false
                        )),
                        v => v.clone(),
                    };
                    json!({"field": c.field, "to": to, "by": c.by, "class": c.class, "tx": c.tx})
                })
                .collect();
            let fields: Vec<&str> = changed_since.iter().map(|c| c.field.as_str()).collect();
            Answer {
                text: format!(
                    "conflict: {id} is at ver {ver}; changed: {}; {next}",
                    fields.join(", ")
                ),
                structured: json!({"conflict": {"id": id, "ver": ver, "changed_since": changes, "next": next}}),
                links: vec![id.clone()],
            }
        }
        TaskAnswer::LeaseLost {
            by,
            how,
            tx,
            note,
            next,
        } => {
            let note_v = note.as_ref().map(|n| {
                json!(Authored::new(
                    n,
                    by.clone().unwrap_or_else(|| "unknown".into()),
                    Class::Agent,
                    *tx,
                    project.clone(),
                    false
                ))
            });
            Answer {
                text: format!(
                    "lease lost ({}) by {}; {next}",
                    serde_json::to_value(how)
                        .ok()
                        .and_then(|v| v.as_str().map(str::to_owned))
                        .unwrap_or_default(),
                    by.as_deref().unwrap_or("nobody")
                ),
                structured: json!({"lease_lost": {"by": by, "how": how, "tx": tx, "note": note_v, "next": next}}),
                links: Vec::new(),
            }
        }
        TaskAnswer::Proposed { card } => Answer {
            text: format!(
                "proposed: the user closes this task (card {card}); go on with other work"
            ),
            structured: json!({"proposed": {"card": card}}),
            links: Vec::new(),
        },
    }
}

async fn task_write(coord: &Coord, who: &Identity, a: TaskWriteArgs) -> Result<Answer, String> {
    who.me()?;
    let req = a.req.clone();
    if let Some(r) = &req
        && !valid_req(r)
    {
        return Err("req is 1-64 characters of A-Za-z0-9._-".into());
    }
    let op = task_op(a)?;
    let name = op.name();
    let caller = caller_of(coord, who, true).await?;
    let mut meta = caller.tx_meta(format!("mcp:task_write/{name}"));
    meta.req = req;
    let writer = coord.db().graph_writer().ok_or("work.db is not open yet")?;
    let c2 = caller.clone();
    // a conflict or a lost lease rolls the request back (no empty tx row) and answers from here
    let kept = Arc::new(Mutex::new(None));
    let k2 = kept.clone();
    let written = writer
        .write(meta, move |tx| {
            let answer = tracker::op_or_roll_back(tx, &c2, op, &k2)?;
            Ok((answer, tx.id()))
        })
        .await;
    let (answer, tx) = match written {
        Ok(written) => {
            if !written.replayed {
                coord.hub().notify();
            }
            written.value
        }
        Err(e) => match kept.lock().unwrap_or_else(PoisonError::into_inner).take() {
            Some(answer) => (answer, 0),
            None => return Err(err(e.into())),
        },
    };
    let proj = caller.project;
    let project = coord
        .db()
        .read(move |c| Ok(project_id(c, proj)?))
        .await
        .map_err(err)?;
    Ok(task_answer(&answer, &caller, tx, project))
}

// -------------------------------------------------------------------------------------------------------- note_add

#[derive(Deserialize, JsonSchema)]
struct NoteAddArgs {
    /// The entity it is about: a task, decision, plan, file:PATH or sym:NAME
    about: String,
    /// The note
    text: String,
    /// progress (default), finding, question or handoff
    kind: Option<String>,
    /// A request key (1-64 of A-Za-z0-9._-): retrying with the same key returns the first answer
    req: Option<String>,
}

struct NoteAdd;

impl RichTool for NoteAdd {
    type Args = NoteAddArgs;
    const NAME: &'static str = "note_add";
    const DESCRIPTION: &'static str = "Add a note about a task, decision, plan, file:PATH or sym:NAME (progress, finding, question, handoff). Notes are how you tell the next agent what you learned";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: NoteAddArgs,
    ) -> BoxFuture<'a, Result<Answer, String>> {
        Box::pin(note_add(coord, who, args))
    }
}

/// The commit HEAD of the folder an agent works in (a `file:` or `sym:` note records where it was written), if git
/// answers.
async fn head_of(home: Option<&Path>) -> Option<String> {
    let dir = home?.to_path_buf();
    tokio::task::spawn_blocking(move || {
        project::git(&dir, &["rev-parse", "HEAD"]).map(|s| s.trim().to_owned())
    })
    .await
    .ok()
    .flatten()
    .filter(|s| !s.is_empty())
}

async fn note_add(coord: &Coord, who: &Identity, a: NoteAddArgs) -> Result<Answer, String> {
    who.me()?;
    if let Some(r) = &a.req
        && !valid_req(r)
    {
        return Err("req is 1-64 characters of A-Za-z0-9._-".into());
    }
    let kind = a.kind.clone().unwrap_or_else(|| "progress".into());
    if !["progress", "finding", "question", "handoff"].contains(&kind.as_str()) {
        return Err(format!(
            "kind is progress, finding, question or handoff, not {kind:?}"
        ));
    }
    let code = a.about.starts_with("file:") || a.about.starts_with("sym:");
    let at = if code {
        head_of(who.home()).await
    } else {
        None
    };
    let caller = caller_of(coord, who, true).await?;
    // a caller without a project writes nothing (Task 10): its note would be a stub every agent sees
    if caller.project.is_none() {
        return Err(
            "you have no project: notes are made in the project (git repository) you work in"
                .into(),
        );
    }
    let mut meta = caller.tx_meta("mcp:note_add");
    meta.req = a.req.clone();
    let writer = coord.db().graph_writer().ok_or("work.db is not open yet")?;
    let (about, text) = (a.about, a.text);
    let c2 = caller.clone();
    let written = writer
        .write(meta, move |tx| {
            let body = tracker::clean_text("text", &text)?;
            if body.trim().is_empty() {
                return Err(tracker::refused("a note needs text"));
            }
            let target = match tracker::visible(tx, &c2, &about, "entity") {
                Ok((e, _)) => e,
                // a file or symbol nobody recorded yet: made as a bare entity of the project (the caller has one: a
                // caller without is refused above), so the note has an end
                Err(WriteError::Refused(_)) if code => {
                    let kind = if about.starts_with("file:") {
                        "file"
                    } else {
                        "symbol"
                    };
                    entity::create(
                        tx,
                        entity::EntityNew {
                            id: about.clone(),
                            kind: kind.into(),
                            project: c2.project,
                            title: Some(about.clone()),
                            status: None,
                            body: None,
                            priority: None,
                            assignee: None,
                            data: json!({}),
                            origin: Origin::Inferred,
                            source: None,
                        },
                    )?
                }
                Err(e) => return Err(e),
            };
            let id = tracker::new_id(tx, "note", c2.project)?;
            let note = entity::create(
                tx,
                entity::EntityNew {
                    id: id.clone(),
                    kind: "note".into(),
                    project: c2.project,
                    title: Some(runstav::text::one_line(&body, 80, false)),
                    status: None,
                    body: Some(body),
                    priority: None,
                    assignee: None,
                    data: json!({ "kind": kind }),
                    origin: Origin::Recorded,
                    source: None,
                },
            )?;
            let data = at.map(|sha| json!({"at": sha}));
            link::add(tx, note.n, "about", target.n, data, Origin::Recorded, None)?;
            Ok((id, target.id, tx.id()))
        })
        .await
        .map_err(|e| err(e.into()))?;
    let (id, about, _tx) = written.value;
    if !written.replayed {
        coord.hub().notify();
    }
    Ok(Answer {
        text: format!("noted: {id} about {about}"),
        structured: json!({"note": {"id": id, "about": about}}),
        links: vec![id, about],
    })
}

// ------------------------------------------------------------------------------------------------------ hello brief

/// `hello` with the brief after it: the tool INNER's first text item is kept byte for byte; a second item and
/// `structuredContent.brief` follow.
pub(super) fn with_brief(inner: Box<dyn Tool<Ctx>>, tasks: bool) -> Box<dyn Tool<Ctx>> {
    Box::new(Brief { inner, tasks })
}

struct Brief {
    inner: Box<dyn Tool<Ctx>>,
    tasks: bool,
}

impl Tool<Ctx> for Brief {
    fn name(&self) -> &'static str {
        self.inner.name()
    }

    fn description(&self) -> &'static str {
        self.inner.description()
    }

    fn input_schema(&self) -> Value {
        self.inner.input_schema()
    }

    fn output_schema(&self) -> Option<Value> {
        Some(output_schema())
    }

    fn check(&self, args: &Value) -> Result<(), ArgsError> {
        self.inner.check(args)
    }

    fn call<'a>(&'a self, ctx: &'a Ctx, args: Value) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            match self.inner.call(ctx, args).await {
                ToolResult::Ok { text, .. } => match brief(&ctx.0, &ctx.1, self.tasks).await {
                    Ok((second, brief)) => ToolResult::Rich {
                        text,
                        structured: Some(json!({ "brief": brief })),
                        content: vec![json!({"type": "text", "text": second})],
                        meta: None,
                    },
                    Err(_) => ToolResult::Ok {
                        text,
                        structured: None,
                    },
                },
                other => other,
            }
        })
    }
}

/// The brief of WHO: the project and the effective scope, the caller's tasks, the top five ready tasks, the unread
/// notices and the decision-log version. With TRACKER off, no task and no tracker tool.
async fn brief(coord: &Coord, who: &Identity, tasks: bool) -> Result<(String, Value), String> {
    let caller = caller_of(coord, who, false).await?;
    let now = coord.now();
    coord
        .db()
        .read(move |c| {
            let look = Look::new(c, &caller, now)?;
            let mut lines = Vec::new();
            let project = match caller.project {
                Some(n) => entity::by_n(c, n)?.map(|e| e.id),
                None => None,
            };
            lines.push(match &project {
                Some(p) => format!("project: {p}"),
                None => "project: none (not in a git repository the store knows)".into(),
            });
            let mut granted = Vec::new();
            for g in grants::list(c, &caller, &Filter { who: None, active: Some(true) }, now)? {
                if g.access != Access::Read {
                    continue;
                }
                let by: Option<(String, f64)> = tracker::opt(c.query_row(
                    "select t.actor, t.at from entity e join tx t on t.id = e.created_tx where e.n = ?1",
                    [g.n],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                ))?;
                lines.push(format!(
                    "scope: read {} (granted by {} at {})",
                    g.what,
                    by.as_ref().map_or("?", |b| b.0.as_str()),
                    by.as_ref().map_or(0.0, |b| b.1)
                ));
                granted.push(json!({"id": g.id, "what": g.what.to_string(), "by": by.as_ref().map(|b| &b.0), "at": by.as_ref().map(|b| b.1), "expires": g.expires}));
            }
            if granted.is_empty() {
                lines.push("scope: your project only".into());
            }
            let mut out = json!({"project": project, "grants": granted});
            if tasks {
                let mut stmt = c.prepare(
                    "select n from entity where kind = 'task' and retired_tx is null \
                     and (assignee = ?1 or lease_holder = ?1) and coalesce(status, '') not in ('done', 'dropped') \
                     order by coalesce(priority, 1000000), n limit 20",
                )?;
                let ns: Vec<i64> = stmt
                    .query_map([&caller.actor], |r| r.get(0))?
                    .collect::<Result<_, _>>()?;
                let mut mine = Vec::new();
                for n in ns {
                    if let Some(e) = entity::by_n(c, n)?
                        && let Some((v, l)) = look.view(&e, false)?
                    {
                        lines.push(format!("yours: {l}"));
                        mine.push(v);
                    }
                }
                let mut ready = Vec::new();
                for e in tracker::ready(c, &look.scope, &[], 5)? {
                    if let Some((v, l)) = look.view(&e, false)? {
                        lines.push(format!("ready: {l}"));
                        ready.push(v);
                    }
                }
                out["tasks"] = json!(mine);
                out["ready"] = json!(ready);
                lines.push("task_read mine / ready, task_write claim; note_add to tell the next agent".into());
            }
            let notices = notices_unread(c, &caller.actor)?;
            let version = meta::version(c)?;
            if notices > 0 {
                lines.push(format!("notices: {notices} (read_inbox)"));
            }
            lines.push(format!("decision log: version {version}"));
            out["notices"] = json!(notices);
            out["decision_log"] = json!(version);
            Ok((lines.join("\n"), out))
        })
        .await
        .map_err(err)
}
