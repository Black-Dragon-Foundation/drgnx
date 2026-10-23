//! `work.db` schema 6 → 7 (Task 11; storage §9 step 5, calls 2, 4, 5, 6, 15, 18): the writer's opening rule, which
//! creates a fresh file at schema 7 or migrates a schema-6 one in one transaction after a checked `VACUUM INTO` copy,
//! with the deny-list at the migration's door, compat views with schema 6's columns, and `file`/`meta` behind
//! read-only views (docs/develop/store.md, "Migration from schema 6").
//!
//! The order, so a crash at any point leaves schema 6 intact and no git runs under the write lock:
//! 0. outside any transaction: the deny-list loaded, and the projects of the folders the allowed rows name resolved
//!    (git) into a [`ProjectCache`];
//! 1. `VACUUM INTO <backup>/work-pre7-<unix>.db`, checked (`urdr::graph::backup::check`); one copy per process;
//! 2. one `BEGIN IMMEDIATE` for everything below, the schema read again under it;
//! 3. the graph tables; `node`, `edge`, `jtask`, `jdep`, `decision` renamed `old_*`; `file` → `parsed_file`, `meta` →
//!    `kv` behind the read-only views `file` and `meta`;
//!    (3a) door 2: every row read again under the lock and put through the [`DenyList`]; a denied node, an edge with a
//!    denied end or path, and a denied `parsed_file` row are not kept (only their counts are);
//! 4. the backfill in time order: one imported tx per `(time, actor)`, each entity created at its earliest known time
//!    and each link in the tx where its later end is made; the projects first;
//! 5. the `tx` and `entity` columns of the kept tables; the compat views; `kv` `schema = 7`, `compat-read = 6`,
//!    `migrate-7` (the report); the `old_*` tables dropped; `COMMIT`;
//! 6. when the door denied anything: `VACUUM` and `wal_checkpoint(TRUNCATE)`, so the dropped pages leave the file and
//!    its WAL.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use urdr::Connection;
use urdr::graph::entity::{self, Changes, EntityNew, Lease, Origin};
use urdr::graph::guard::Guard;
use urdr::graph::link;
use urdr::graph::schema::{GRAPH_DDL, SENTINEL};
use urdr::graph::{Class, OpenOutcome, OpenRule, Tx, TxMeta, WriteError};

use crate::deny::{DenyList, Source, Verdict};
use crate::kinds;
use crate::project::{self, ProjectCache};

#[cfg(test)]
mod tests;

/// The schema this module makes.
pub const SCHEMA: u32 = 7;
/// The read views' level (`meta` `compat-read`): the Lisp readers of schema 6 read schema 7 through them.
pub const COMPAT_READ: u32 = 6;
/// The `kv` key that keeps the report.
pub const REPORT_KEY: &str = "migrate-7";

/// What the rule needs besides the connection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MigrateOpts {
    /// Where `work-pre7-<unix>.db` goes (`<data>/backup/`, or migrate-check's scratch dir).
    pub backup_dir: PathBuf,
    /// For the deny-list.
    pub home: PathBuf,
    pub config_dir: PathBuf,
}

/// What a migration did: counts and times, never a path of the user's content, a title or a body.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct MigrateReport {
    /// Table → (rows in, rows out).
    pub tables: BTreeMap<String, (u64, u64)>,
    pub denied_nodes: u64,
    pub denied_edges: u64,
    /// `parsed_file` rows the door removed.
    #[serde(default)]
    pub denied_files: u64,
    /// Entities made without a project (a folder that is gone, or no repository).
    pub no_project: u64,
    /// Every old edge and link-making row by `old->new` kind (`->dropped` when an end is missing, `->denied`).
    #[serde(default)]
    pub links: BTreeMap<String, u64>,
    /// Nodes of a kind schema 6 never made, kept as `note` entities (`data.was_kind`).
    #[serde(default)]
    pub retyped: u64,
    /// Rows whose id an earlier row already took (not migrated).
    #[serde(default)]
    pub duplicates: u64,
    /// The imported txs made.
    #[serde(default)]
    pub txs: u64,
    pub ms: f64,
    /// When the migration committed (unix seconds).
    #[serde(default)]
    pub at: f64,
    /// The checked pre-migration copy.
    pub backup: Option<PathBuf>,
    /// The copies that still hold what the door denied (the pre-migration copy, `work.db.schema5`): the doctor offers
    /// removing them.
    #[serde(default)]
    pub denied_in: Vec<PathBuf>,
}

impl MigrateReport {
    /// The report as `kv` `migrate-7` and the hub log keep it: with `denied = {nodes, edges, files}`.
    pub fn to_json(&self) -> Value {
        let mut v = serde_json::to_value(self).unwrap_or_else(|_| json!({}));
        v["denied"] = json!({
            "nodes": self.denied_nodes,
            "edges": self.denied_edges,
            "files": self.denied_files,
        });
        v
    }

    fn count(&mut self, label: String) {
        *self.links.entry(label).or_default() += 1;
    }
}

/// Why a migration stopped.
#[derive(Debug, PartialEq)]
enum Stop {
    /// Another process held the write lock, or changed the file meanwhile: nothing done; the rule answers
    /// `NotReady`, and the next tick tries again.
    Busy(String),
    /// Nothing migrated, for good in this process (call 18).
    Failed(String),
}

impl From<urdr::SqliteError> for Stop {
    fn from(e: urdr::SqliteError) -> Stop {
        let e = urdr::Error::Sqlite(e);
        if urdr::is_busy(&e) {
            Stop::Busy(BUSY_TEXT.into())
        } else {
            Stop::Failed(e.to_string())
        }
    }
}

impl From<WriteError> for Stop {
    fn from(e: WriteError) -> Stop {
        Stop::Failed(e.to_string())
    }
}

const BUSY_TEXT: &str =
    "work.db is busy (another process writes it); the move to schema 7 runs at the next tick";
const CHANGED_TEXT: &str =
    "work.db changed while its move to schema 7 was prepared; it is read again at the next tick";

/// The writer's opening rule: an empty file → schema 7; 6 → [`run`]; 7 → ready; above → read-only; below 6 → not
/// ready; a failed run → `Failed` (the writer never runs the rule again in this process).
pub fn open_rule(opts: MigrateOpts) -> OpenRule {
    Arc::new(move |conn: &mut Connection, path: &Path| open(conn, path, &opts))
}

fn open(conn: &mut Connection, path: &Path, opts: &MigrateOpts) -> OpenOutcome {
    let tables: i64 = match conn.query_row("select count(*) from sqlite_master", [], |r| r.get(0)) {
        Ok(n) => n,
        Err(e) => return OpenOutcome::NotReady(format!("work.db cannot be read: {e}")),
    };
    if tables == 0 {
        return match create(conn) {
            Ok(()) => OpenOutcome::Ready { schema: SCHEMA },
            Err(Stop::Busy(t)) => OpenOutcome::NotReady(t),
            Err(Stop::Failed(r)) => {
                OpenOutcome::Failed(format!("work.db: cannot make schema 7: {r}"))
            }
        };
    }
    match schema_of(conn) {
        Err(e) => OpenOutcome::NotReady(format!("work.db cannot be read: {e}")),
        Ok(SCHEMA) => OpenOutcome::Ready { schema: SCHEMA },
        Ok(s) if s > SCHEMA => OpenOutcome::ReadOnly { schema: s },
        Ok(6) => match migrate(conn, path, opts) {
            Ok(report) => {
                tracing::info!(report = %report.to_json(), "work.db moved to schema 7");
                if !report.denied_in.is_empty() {
                    tracing::warn!(
                        copies = ?report.denied_in,
                        "the migration kept personal notes out of work.db; these copies still hold them"
                    );
                }
                OpenOutcome::Ready { schema: SCHEMA }
            }
            Err(Stop::Busy(t)) => OpenOutcome::NotReady(t),
            Err(Stop::Failed(r)) => {
                let reason = format!("the move of work.db to schema 7 failed: {r}");
                tracing::error!("{reason}");
                OpenOutcome::Failed(reason)
            }
        },
        Ok(s) => OpenOutcome::NotReady(format!(
            "work.db is schema {s}; open it once with drgnx 6 first, or remove it (installs are disposable)"
        )),
    }
}

/// `meta.schema` as a number; 0 without one.
fn schema_of(conn: &Connection) -> Result<u32, String> {
    Ok(urdr::meta(conn, "schema")
        .map_err(|e| e.to_string())?
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0))
}

/// Migrate the schema-6 file at PATH, open on CONN (the writer's connection).
pub fn run(
    conn: &mut Connection,
    path: &Path,
    opts: &MigrateOpts,
) -> Result<MigrateReport, String> {
    migrate(conn, path, opts).map_err(|s| match s {
        Stop::Busy(t) | Stop::Failed(t) => t,
    })
}

/// A fresh schema-7 database on CONN (an empty one), as the opening of a missing file leaves it: the writers' unit
/// tests run on it.
#[cfg(test)]
pub(crate) fn make_fresh(conn: &mut Connection) -> Result<(), String> {
    create(conn).map_err(|s| match s {
        Stop::Busy(t) | Stop::Failed(t) => t,
    })
}

/// `ratatoskr store migrate-check`: migrate the copy DB in place, its pre-migration backup in `opts.backup_dir`.
pub fn check_copy(db: &Path, opts: &MigrateOpts) -> Result<MigrateReport, String> {
    if !db.is_file() {
        return Err(format!("{}: no such file", db.display()));
    }
    // An existing file (checked above): `open` creates none here.
    let mut conn = Connection::open(db).map_err(|e| e.to_string())?;
    conn.busy_timeout(std::time::Duration::from_secs(5))
        .map_err(|e| e.to_string())?;
    conn.pragma_update(None, "secure_delete", "ON")
        .map_err(|e| e.to_string())?;
    match schema_of(&conn)? {
        6 => run(&mut conn, db, opts),
        s => Err(format!(
            "the copy is schema {s}; migrate-check moves a schema-6 file"
        )),
    }
}

// ------------------------------------------------------------------------------------------------ the tables

/// Schema 6's tables as `core/drgnx-work-db.el` leaves them (`test/fixtures/work-db-6.sql` holds the same): a fresh
/// file is made from them and shaped as a migrated one is, so the two have the same schema
/// (`a_fresh_file_is_schema_7`).
const SCHEMA_6_TABLES: &str = r#"
CREATE TABLE agent (id text primary key, kind text, name text, cwd text, worktree text, branch text,
        base text, plan text, task text, pid integer, started real, seen real);
CREATE TABLE "card" (id integer primary key, job text, task text, kind text, title text, data text check (data is null or json_valid(data)), state text, at real, settled_at real, choice text, ref integer);
CREATE INDEX card_job on card(job, state);
CREATE TABLE decision (n integer primary key, kind text, subject text, task text, paths text,
        reason text, author text, status text, replaces integer, at real, ver integer, job text);
CREATE TABLE edge (src text, dst text, kind text, origin text, source text,
        primary key (src, dst, kind));
CREATE INDEX edge_dst on edge(dst, kind);
CREATE TABLE "event" (id integer primary key autoincrement, at real, agent text, job text, task text, kind text, summary text, data text check (data is null or json_valid(data)), turn integer);
CREATE INDEX event_agent on event(agent, id);
CREATE INDEX event_at on event(at);
CREATE INDEX event_job on event(job, id);
CREATE INDEX event_kind on event(kind, id);
CREATE TABLE file (path text primary key, mtime real);
CREATE TABLE jdep (task text, dep text, primary key (task, dep));
CREATE TABLE "job" (id text primary key, title text, plan text, repo text, status text, created real, data text check (data is null or json_valid(data)));
CREATE TABLE "jtask" (id text primary key, job text, n integer, title text, role text, status text, agent text, lease_until real, data text check (data is null or json_valid(data)));
CREATE INDEX jtask_job on jtask(job);
CREATE TABLE message (id integer primary key, job text, sender text, recipient text, text text,
        state text, reason text, at real, delivered real, read real, acted real, answers integer);
CREATE INDEX message_to on message(recipient, state);
CREATE TABLE meta (key text primary key, value text);
CREATE TABLE "node" (id text primary key, kind text, title text, path text, line integer, status text, parent text, ord integer, source text, data text check (data is null or json_valid(data)), updated real);
CREATE INDEX node_parent on node(parent);
CREATE INDEX node_source on node(source);
CREATE TABLE review_mark (agent text, path text, state text, hash text, at real,
        primary key (agent, path));
CREATE TABLE spend (at real, job text, task text, agent text, provider text, model text,
        input integer, output integer, cost real, status integer);
CREATE INDEX spend_job on spend(job);
"#;

/// Step 3's renames: the five tables the compat views replace, and the two kept behind read-only views.
const RENAMES: &[(&str, &str)] = &[
    ("node", "old_node"),
    ("edge", "old_edge"),
    ("jtask", "old_jtask"),
    ("jdep", "old_jdep"),
    ("decision", "old_decision"),
    ("file", "parsed_file"),
    ("meta", "kv"),
];

/// `file` and `meta` as read-only views (call 2: a schema-6 Lisp writer fails on them instead of writing).
const RO_VIEWS: &str = "
create view file as select path, mtime from parsed_file;
create view meta as select key, value from kv;";

/// Step 8: the kept tables' `tx` column (the tx that wrote a row; null for old rows) and the `entity` column of
/// `message` and `card` (Task 13's notices, Task 15b's close cards, Task 8's blankers).
const ADD_COLUMNS: &str = "
alter table job add column tx integer;
alter table card add column tx integer;
alter table message add column tx integer;
alter table spend add column tx integer;
alter table review_mark add column tx integer;
alter table event add column tx integer;
alter table agent add column tx integer;
alter table message add column entity integer;
alter table card add column entity integer;";

/// The kept tables, as the report counts them.
const KEPT: &[&str] = &[
    "agent",
    "card",
    "event",
    "job",
    "message",
    "review_mark",
    "spend",
];

/// The tables step 5 drops.
const OLD: &[&str] = &[
    "old_node",
    "old_edge",
    "old_jtask",
    "old_jdep",
    "old_decision",
];

/// The parsed kinds schema 6's `node` table held: what the `node` view lists.
const NODE_KINDS: &[&str] = &[
    "spec", "plan", "task", "step", "ruling", "todo", "commit", "branch",
];

/// Step 9: schema 6's five tables as views over current, non-retired rows, with their exact columns in order.
fn compat_views() -> String {
    format!(
        "
create view node as
select e.id as id, e.kind as kind, e.title as title,
  json_extract(e.data, '$.path') as path,
  json_extract(e.data, '$.line') as line,
  e.status as status,
  json_extract(e.data, '$.parent') as parent,
  json_extract(e.data, '$.ord') as ord,
  e.source as source,
  nullif(json_remove(e.data, '$.path', '$.line', '$.parent', '$.ord'), '{{}}') as data,
  (select t.at from tx t where t.id = e.updated_tx) as updated
from entity e
where e.retired_tx is null
  and (e.kind in ('spec', 'plan', 'step', 'todo', 'ruling', 'commit', 'branch')
       or (e.kind = 'task' and substr(e.id, 1, 6) = 'task:/'));

create view edge as
select case when s.kind = 'file' then substr(s.id, 6) else s.id end as src,
  case when d.kind = 'file' then substr(d.id, 6) else d.id end as dst,
  coalesce(json_extract(l.data, '$.was'), case l.kind when 'on_branch' then 'on-branch' else l.kind end) as kind,
  l.origin as origin,
  l.source as source
from link l join entity s on s.n = l.src join entity d on d.n = l.dst
where l.tx_to = {SENTINEL} and s.retired_tx is null and d.retired_tx is null
  and (l.kind in ('derives', 'implements', 'on_branch') or json_extract(l.data, '$.was') is not null);

create view jtask as
select substr(e.id, 6) as id,
  json_extract(e.data, '$.job') as job,
  json_extract(e.data, '$.n') as n,
  e.title as title,
  json_extract(e.data, '$.role') as role,
  e.status as status,
  e.assignee as agent,
  e.lease_until as lease_until,
  nullif(json_remove(e.data, '$.job', '$.n', '$.role'), '{{}}') as data
from entity e
where e.retired_tx is null and e.kind = 'task' and substr(e.id, 1, 6) <> 'task:/'
  and json_extract(e.data, '$.job') is not null;

create view jdep as
select substr(t.id, 6) as task, substr(d.id, 6) as dep
from link l join entity d on d.n = l.src join entity t on t.n = l.dst
where l.kind = 'blocks' and l.tx_to = {SENTINEL} and d.retired_tx is null and t.retired_tx is null
  and json_extract(t.data, '$.job') is not null and json_extract(d.data, '$.job') is not null;

create view decision as
select json_extract(e.data, '$.n') as n,
  json_extract(e.data, '$.kind') as kind,
  e.title as subject,
  json_extract(e.data, '$.task') as task,
  json_extract(e.data, '$.paths') as paths,
  e.body as reason,
  json_extract(e.data, '$.author') as author,
  e.status as status,
  coalesce((select json_extract(o.data, '$.n') from link l join entity o on o.n = l.dst
            where l.src = e.n and l.kind = 'supersedes' and l.tx_to = {SENTINEL}),
           json_extract(e.data, '$.replaces')) as replaces,
  json_extract(e.data, '$.at') as at,
  json_extract(e.data, '$.ver') as ver,
  json_extract(e.data, '$.job') as job
from entity e
where e.retired_tx is null and e.kind = 'decision';
"
    )
}

/// Steps 3's start, shared by a fresh file and a migration: the graph tables, the renames, the read-only views.
fn shape_start(conn: &Connection) -> Result<(), Stop> {
    conn.execute_batch(GRAPH_DDL)?;
    for (from, to) in RENAMES {
        conn.execute_batch(&format!("alter table {from} rename to {to}"))?;
    }
    conn.execute_batch(RO_VIEWS)?;
    Ok(())
}

/// Steps 8–10, shared: the kept tables' columns, the compat views, `kv`, the `old_*` tables dropped.
fn shape_end(conn: &Connection, report: Option<&MigrateReport>) -> Result<(), Stop> {
    conn.execute_batch(ADD_COLUMNS)?;
    conn.execute_batch(&compat_views())?;
    let put = |key: &str, value: &str| {
        conn.execute(
            "insert or replace into kv (key, value) values (?1, ?2)",
            (key, value),
        )
    };
    put("schema", &SCHEMA.to_string())?;
    put("compat-read", &COMPAT_READ.to_string())?;
    if let Some(r) = report {
        put(REPORT_KEY, &r.to_json().to_string())?;
    }
    for t in OLD {
        conn.execute_batch(&format!("drop table {t}"))?;
    }
    Ok(())
}

fn begin(conn: &Connection) -> Result<(), Stop> {
    conn.execute_batch("begin immediate")?;
    Ok(())
}

/// Commit on `Ok` (rolled back when the commit fails), roll back on `Err`.
fn finish<T>(conn: &Connection, out: Result<T, Stop>) -> Result<T, Stop> {
    match out {
        Ok(v) => match conn.execute_batch("commit") {
            Ok(()) => Ok(v),
            Err(e) => {
                let _ = conn.execute_batch("rollback");
                Err(e.into())
            }
        },
        Err(e) => {
            let _ = conn.execute_batch("rollback");
            Err(e)
        }
    }
}

/// A missing (empty) file → schema 7, made as a migration of an empty schema-6 file would leave it.
fn create(conn: &mut Connection) -> Result<(), Stop> {
    begin(conn)?;
    let out = (|| {
        let tables: i64 = conn.query_row("select count(*) from sqlite_master", [], |r| r.get(0))?;
        if tables != 0 {
            return Err(Stop::Busy(CHANGED_TEXT.into()));
        }
        conn.execute_batch(SCHEMA_6_TABLES)?;
        shape_start(conn)?;
        shape_end(conn, None)
    })();
    finish(conn, out)
}

// ------------------------------------------------------------------------------------------------ the old rows

struct OldNode {
    id: Option<String>,
    kind: Option<String>,
    title: Option<String>,
    path: Option<String>,
    line: Option<i64>,
    status: Option<String>,
    parent: Option<String>,
    ord: Option<i64>,
    source: Option<String>,
    data: Option<String>,
    updated: Option<f64>,
}

struct OldEdge {
    src: Option<String>,
    dst: Option<String>,
    kind: Option<String>,
    origin: Option<String>,
    source: Option<String>,
}

struct OldJTask {
    id: Option<String>,
    job: Option<String>,
    n: Option<i64>,
    title: Option<String>,
    role: Option<String>,
    status: Option<String>,
    agent: Option<String>,
    lease_until: Option<f64>,
    data: Option<String>,
}

struct OldDecision {
    n: i64,
    kind: Option<String>,
    subject: Option<String>,
    task: Option<String>,
    paths: Option<String>,
    reason: Option<String>,
    author: Option<String>,
    status: Option<String>,
    replaces: Option<i64>,
    at: Option<f64>,
    ver: Option<i64>,
    job: Option<String>,
}

/// A job's creation time and repository.
struct OldJob {
    created: Option<f64>,
    repo: Option<String>,
}

fn load_nodes(conn: &Connection, table: &str) -> Result<Vec<OldNode>, Stop> {
    let mut stmt = conn.prepare(&format!(
        "select cast(id as text), cast(kind as text), cast(title as text), cast(path as text), \
         cast(line as integer), cast(status as text), cast(parent as text), cast(ord as integer), \
         cast(source as text), cast(data as text), cast(updated as real) from {table} order by rowid"
    ))?;
    let rows = stmt.query_map([], |r| {
        Ok(OldNode {
            id: r.get(0)?,
            kind: r.get(1)?,
            title: r.get(2)?,
            path: r.get(3)?,
            line: r.get(4)?,
            status: r.get(5)?,
            parent: r.get(6)?,
            ord: r.get(7)?,
            source: r.get(8)?,
            data: r.get(9)?,
            updated: r.get(10)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

fn load_edges(conn: &Connection) -> Result<Vec<OldEdge>, Stop> {
    let mut stmt = conn.prepare(
        "select cast(src as text), cast(dst as text), cast(kind as text), cast(origin as text), \
         cast(source as text) from old_edge order by rowid",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(OldEdge {
            src: r.get(0)?,
            dst: r.get(1)?,
            kind: r.get(2)?,
            origin: r.get(3)?,
            source: r.get(4)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

fn load_jtasks(conn: &Connection) -> Result<Vec<OldJTask>, Stop> {
    let mut stmt = conn.prepare(
        "select cast(id as text), cast(job as text), cast(n as integer), cast(title as text), cast(role as text), \
         cast(status as text), cast(agent as text), cast(lease_until as real), cast(data as text) \
         from old_jtask order by rowid",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(OldJTask {
            id: r.get(0)?,
            job: r.get(1)?,
            n: r.get(2)?,
            title: r.get(3)?,
            role: r.get(4)?,
            status: r.get(5)?,
            agent: r.get(6)?,
            lease_until: r.get(7)?,
            data: r.get(8)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// A schema-6 `jdep` row: (task, dep).
type OldJdep = (Option<String>, Option<String>);

fn load_jdeps(conn: &Connection) -> Result<Vec<OldJdep>, Stop> {
    let mut stmt =
        conn.prepare("select cast(task as text), cast(dep as text) from old_jdep order by rowid")?;
    let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

fn load_decisions(conn: &Connection) -> Result<Vec<OldDecision>, Stop> {
    let mut stmt = conn.prepare(
        "select n, cast(kind as text), cast(subject as text), cast(task as text), cast(paths as text), \
         cast(reason as text), cast(author as text), cast(status as text), cast(replaces as integer), \
         cast(at as real), cast(ver as integer), cast(job as text) from old_decision order by n",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(OldDecision {
            n: r.get(0)?,
            kind: r.get(1)?,
            subject: r.get(2)?,
            task: r.get(3)?,
            paths: r.get(4)?,
            reason: r.get(5)?,
            author: r.get(6)?,
            status: r.get(7)?,
            replaces: r.get(8)?,
            at: r.get(9)?,
            ver: r.get(10)?,
            job: r.get(11)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

fn load_jobs(conn: &Connection) -> Result<HashMap<String, OldJob>, Stop> {
    let mut stmt = conn.prepare(
        "select cast(id as text), cast(created as real), cast(repo as text) from job where id is not null",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            OldJob {
                created: r.get(1)?,
                repo: r.get(2)?,
            },
        ))
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// The first event time of each job task (`event.task`).
fn load_task_times(conn: &Connection) -> Result<HashMap<String, f64>, Stop> {
    let mut stmt = conn.prepare(
        "select cast(task as text), min(cast(at as real)) from event \
         where task is not null and at is not null group by task",
    )?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?)))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

fn count_rows(conn: &Connection, table: &str) -> Result<u64, Stop> {
    let n: i64 = conn.query_row(&format!("select count(*) from {table}"), [], |r| r.get(0))?;
    Ok(n.max(0) as u64)
}

// ------------------------------------------------------------------------------------------------ the door

/// A JSON object from a `data` column: an object as it is, nothing for null, anything else under `data`.
fn object(text: Option<&str>) -> Map<String, Value> {
    let Some(text) = text else {
        return Map::new();
    };
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(m)) => m,
        Ok(Value::Null) => Map::new(),
        Ok(other) => Map::from_iter([("data".to_string(), other)]),
        Err(_) => Map::from_iter([("data".to_string(), Value::String(text.to_string()))]),
    }
}

/// Whether a source string names something the door denies: an unknown form (deny when `Source::parse` is `None`),
/// or a path the deny-list refuses. Schema 6's origin words, which `drgnx-work-put-edge` stores as the source when
/// it has none, name no path.
fn source_denied(deny: &DenyList, source: Option<&str>) -> bool {
    match source {
        None | Some("parsed" | "inferred" | "recorded") => false,
        Some(s) => match Source::parse(s) {
            None => true,
            Some(Source::File(p) | Source::Spec(p)) => is_denied(&deny.check(&p)),
            Some(_) => false,
        },
    }
}

fn is_denied(v: &Verdict) -> bool {
    matches!(v, Verdict::Denied { .. })
}

/// Door 2 for a node: its source, its id and its `path` (as `data.path`).
fn node_denied(deny: &DenyList, n: &OldNode) -> bool {
    let Some(id) = &n.id else { return false };
    let source = match n.source.as_deref() {
        None => Source::Recorded,
        Some(s) => match Source::parse(s) {
            Some(src) => src,
            None => return true,
        },
    };
    let mut data = object(n.data.as_deref());
    if let Some(p) = &n.path {
        data.insert("path".into(), Value::String(p.clone()));
    }
    is_denied(&deny.check_record(&source, id, &Value::Object(data)))
}

/// The folder whose project an entity of a node belongs to: `data.repo`, else a commit's or branch's own path,
/// else the folder of its file.
fn node_dir(kind: &str, path: Option<&str>, data: &Map<String, Value>) -> Option<PathBuf> {
    if let Some(repo) = data.get("repo").and_then(Value::as_str) {
        return Some(PathBuf::from(repo)).filter(|p| p.is_absolute());
    }
    let p = Path::new(path?);
    if !p.is_absolute() {
        return None;
    }
    if matches!(kind, "commit" | "branch") {
        Some(p.to_path_buf())
    } else {
        p.parent().map(Path::to_path_buf)
    }
}

/// Step 0: the folders of the allowed nodes and of the jobs, whose projects are resolved before the transaction.
fn project_dirs(conn: &Connection, deny: &DenyList) -> Result<BTreeSet<PathBuf>, Stop> {
    let mut dirs = BTreeSet::new();
    for n in load_nodes(conn, "node")? {
        if node_denied(deny, &n) {
            continue;
        }
        let data = object(n.data.as_deref());
        if let Some(d) = node_dir(n.kind.as_deref().unwrap_or(""), n.path.as_deref(), &data) {
            dirs.insert(d);
        }
    }
    for job in load_jobs(conn)?.into_values() {
        if let Some(repo) = job.repo.map(PathBuf::from).filter(|p| p.is_absolute()) {
            dirs.insert(repo);
        }
    }
    dirs.retain(|d| !is_denied(&deny.check(d)));
    Ok(dirs)
}

// ------------------------------------------------------------------------------------------------ the copy

/// What a database file looked like: (dev, inode, size, mtime ns) of the file and (size, mtime ns) of its `-wal`.
type Stamp = Option<(u64, u64, u64, i128, u64, i128)>;

fn stamp(db: &Path) -> Stamp {
    let m = fs::metadata(db).ok()?;
    let mut wal = db.as_os_str().to_owned();
    wal.push("-wal");
    let (wal_size, wal_mtime) = fs::metadata(PathBuf::from(wal)).map_or((0, 0), |w| {
        (
            w.size(),
            i128::from(w.mtime()) * 1_000_000_000 + i128::from(w.mtime_nsec()),
        )
    });
    Some((
        m.dev(),
        m.ino(),
        m.size(),
        i128::from(m.mtime()) * 1_000_000_000 + i128::from(m.mtime_nsec()),
        wal_size,
        wal_mtime,
    ))
}

/// The pre-migration copies this process made: database → (its stamp then, the copy).
static COPIES: Mutex<Vec<(PathBuf, Stamp, PathBuf)>> = Mutex::new(Vec::new());

fn unix_now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// Step 1: `VACUUM INTO` a temporary name in DIR (0700), 0600, checked, renamed to `work-pre7-<unix>.db`. A copy
/// this process made of the unchanged file is used again (a migration that found the file busy runs again at the
/// next tick); a file that changed since gets a copy of its own. No copy is ever removed here.
fn backup(conn: &Connection, db: &Path, dir: &Path) -> Result<PathBuf, Stop> {
    let failed = |what: &str, e: &dyn std::fmt::Display| {
        Stop::Failed(format!("the pre-migration copy: {what}: {e}"))
    };
    let now = stamp(db);
    let mut copies = COPIES.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(i) = copies.iter().position(|(p, _, _)| p == db) {
        let (_, then, copy) = &copies[i];
        if *then == now && copy.is_file() {
            return Ok(copy.clone());
        }
        // The file changed since (another writer, a replaced file): a new copy; the older one stays.
        copies.remove(i);
    }
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| failed("its folder", &e))?;
    let unix = unix_now() as u64;
    let mut dest = dir.join(format!("work-pre7-{unix}.db"));
    let mut k = 1;
    while dest.exists() {
        dest = dir.join(format!("work-pre7-{unix}-{k}.db"));
        k += 1;
    }
    let mut tmp = dest.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    let _ = fs::remove_file(&tmp);
    if let Err(e) = conn.execute("vacuum into ?1", [tmp.to_string_lossy().as_ref()]) {
        let _ = fs::remove_file(&tmp);
        return Err(failed("VACUUM INTO", &e));
    }
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))
        .map_err(|e| failed("its mode", &e))?;
    #[cfg(test)]
    tests::hooks::before_check(db, &tmp);
    let checked = urdr::graph::backup::check(&tmp);
    if !checked.ok {
        return Err(Stop::Failed(format!(
            "the pre-migration copy failed its check: {}",
            checked.error.unwrap_or_default()
        )));
    }
    fs::rename(&tmp, &dest).map_err(|e| failed("its rename", &e))?;
    copies.push((db.to_path_buf(), now, dest.clone()));
    Ok(dest)
}

// ------------------------------------------------------------------------------------------------ hooks

/// The test seams: a trace of the steps and a failure at one (`cfg(test)`), and with the `test-hooks` feature the
/// hub's: `DRGNX_TEST_MIGRATE7_FAIL=<step>` fails there, `DRGNX_TEST_MIGRATE7_PAUSE=<step>:<file>` writes FILE and
/// waits there for good (a test kills the process). The binary has neither.
#[allow(unused_variables)]
fn hook(path: &Path, step: &'static str) -> Result<(), Stop> {
    #[cfg(test)]
    tests::hooks::reach(path, step)?;
    #[cfg(any(test, feature = "test-hooks"))]
    {
        if std::env::var("DRGNX_TEST_MIGRATE7_FAIL").as_deref() == Ok(step) {
            return Err(Stop::Failed(format!("a test hook failed step {step}")));
        }
        if let Ok(v) = std::env::var("DRGNX_TEST_MIGRATE7_PAUSE")
            && let Some((at, file)) = v.split_once(':')
            && at == step
        {
            let _ = fs::write(file, b"paused");
            loop {
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        }
    }
    Ok(())
}

// ------------------------------------------------------------------------------------------------ the migration

/// An entity to make, at its time, by its actor.
struct Make {
    at: f64,
    actor: String,
    class: Class,
    new: EntityNew,
    /// The folder its project is looked up by.
    dir: Option<PathBuf>,
    /// Set after the create (a held job task's lease).
    lease: Option<Lease>,
}

/// A link to make once both its ends are.
struct LinkPlan {
    src: String,
    kind: String,
    dst: String,
    data: Option<Value>,
    origin: Origin,
    source: Option<String>,
    /// `old->new`, the report's key.
    label: String,
    /// The table row it came from, for the report's rows out.
    from: RowOf,
}

#[derive(Clone, Copy)]
enum RowOf {
    Edge,
    Jdep,
    Other,
}

/// The tx actor and class of a decision's author: never `user` class (an import), `agent:<name>` for an agent.
fn actor_of(author: Option<&str>) -> (String, Class) {
    match author.map(str::trim).filter(|a| !a.is_empty()) {
        None => ("import".into(), Class::System),
        Some("user") => ("user".into(), Class::System),
        Some(a) if a.starts_with("agent:") => (a.into(), Class::Agent),
        Some(a) if a.starts_with("ext:") => (a.into(), Class::Ext),
        Some(a) if a.contains(':') => (a.into(), Class::System),
        Some(a) => (format!("agent:{a}"), Class::Agent),
    }
}

fn norn_guard() -> Arc<Guard> {
    let mut g = Guard::default();
    crate::grants::register(&mut g);
    Arc::new(g)
}

fn migrate(conn: &mut Connection, path: &Path, opts: &MigrateOpts) -> Result<MigrateReport, Stop> {
    let started = Instant::now();
    match schema_of(conn).map_err(Stop::Failed)? {
        6 => {}
        s => {
            return Err(Stop::Failed(format!(
                "work.db is schema {s}; only schema 6 is moved"
            )));
        }
    }
    // 0. Outside any transaction: the deny-list, and git for the projects.
    let deny = DenyList::load(&opts.home, &opts.config_dir);
    let mut cache = ProjectCache::default();
    for dir in project_dirs(conn, &deny)? {
        hook(path, "resolve")?;
        cache.fill(&dir);
    }
    // 1. The checked copy.
    let copy = backup(conn, path, &opts.backup_dir)?;
    // 2. One transaction.
    begin(conn)?;
    let mut report = MigrateReport {
        backup: Some(copy.clone()),
        ..MigrateReport::default()
    };
    let out = hook(path, "begin").and_then(|()| {
        fill(conn, path, &deny, &mut cache, &mut report)?;
        report.ms = started.elapsed().as_secs_f64() * 1000.0;
        report.at = unix_now();
        if report.denied_nodes + report.denied_edges + report.denied_files > 0 {
            report.denied_in.push(copy.clone());
            if let Some(dir) = path.parent()
                && dir.join("work.db.schema5").exists()
            {
                report.denied_in.push(dir.join("work.db.schema5"));
            }
        }
        shape_end(conn, Some(&report))?;
        hook(path, "commit")
    });
    finish(conn, out)?;
    // 11. The scrub, when the door kept anything out.
    if !report.denied_in.is_empty()
        && let Err(e) = scrub(conn)
    {
        tracing::warn!("work.db: the scrub after the migration did not finish: {e}");
    }
    Ok(report)
}

/// `VACUUM` and `wal_checkpoint(TRUNCATE)` (`secure_delete` is on): the pages of the dropped rows leave the file and
/// its WAL.
fn scrub(conn: &Connection) -> Result<(), String> {
    conn.execute_batch("vacuum").map_err(|e| e.to_string())?;
    let busy: i64 = conn
        .query_row("pragma wal_checkpoint(TRUNCATE)", [], |r| r.get(0))
        .map_err(|e| e.to_string())?;
    if busy != 0 {
        return Err("a reader held the WAL; it is truncated at the next checkpoint".into());
    }
    Ok(())
}

/// Steps 3–7 inside the transaction.
fn fill(
    conn: &mut Connection,
    path: &Path,
    deny: &DenyList,
    cache: &mut ProjectCache,
    report: &mut MigrateReport,
) -> Result<(), Stop> {
    if schema_of(conn).map_err(Stop::Failed)? != 6 {
        return Err(Stop::Busy(CHANGED_TEXT.into()));
    }
    let now = unix_now();
    // 3. The graph tables, the renames, the read-only views.
    shape_start(conn)?;
    // 3a. Door 2, over the rows as they are now (under the lock).
    let nodes = load_nodes(conn, "old_node")?;
    let edges = load_edges(conn)?;
    let jtasks = load_jtasks(conn)?;
    let jdeps = load_jdeps(conn)?;
    let decisions = load_decisions(conn)?;
    let jobs = load_jobs(conn)?;
    let task_times = load_task_times(conn)?;
    let mut denied: HashSet<&str> = HashSet::new();
    for n in &nodes {
        if node_denied(deny, n) {
            denied.insert(n.id.as_deref().unwrap_or(""));
            report.denied_nodes += 1;
        }
    }
    let files: Vec<String> = {
        let mut stmt = conn.prepare("select cast(path as text) from parsed_file")?;
        let rows = stmt.query_map([], |r| r.get::<_, Option<String>>(0))?;
        rows.collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .flatten()
            .collect()
    };
    let files_in = count_rows(conn, "parsed_file")?;
    for f in &files {
        if is_denied(&deny.check(Path::new(f))) {
            conn.execute("delete from parsed_file where path = ?1", [f])?;
            report.denied_files += 1;
        }
    }
    let meta_rows = count_rows(conn, "kv")?;
    // 4–5. The entities to make, each at its earliest known time.
    let mut makes: Vec<Make> = Vec::new();
    let mut kind_of: HashMap<String, String> = HashMap::new();
    let mut time_of: HashMap<String, f64> = HashMap::new();
    let mut parents: Vec<(String, String)> = Vec::new();
    for n in &nodes {
        let Some(id) = n.id.clone() else { continue };
        if denied.contains(id.as_str()) {
            continue;
        }
        let mut data = object(n.data.as_deref());
        let old_kind = n.kind.clone().unwrap_or_default();
        let kind = if NODE_KINDS.contains(&old_kind.as_str()) {
            old_kind.clone()
        } else {
            report.retyped += 1;
            data.insert("was_kind".into(), Value::String(old_kind.clone()));
            "note".to_string()
        };
        let dir = node_dir(&kind, n.path.as_deref(), &data);
        let mut at = n.updated.unwrap_or(now);
        if kind == "commit"
            && let Some(date) = data.get("date").and_then(Value::as_f64)
        {
            at = at.min(date);
        }
        if let Some(p) = &n.path {
            data.insert("path".into(), json!(p));
        }
        if let Some(l) = n.line {
            data.insert("line".into(), json!(l));
        }
        if let Some(p) = &n.parent
            && !denied.contains(p.as_str())
        {
            data.insert("parent".into(), json!(p));
            parents.push((p.clone(), id.clone()));
        }
        if let Some(o) = n.ord {
            data.insert("ord".into(), json!(o));
        }
        kind_of.insert(id.clone(), kind.clone());
        time_of.insert(id.clone(), at);
        makes.push(Make {
            at,
            actor: "import".into(),
            class: Class::System,
            new: EntityNew {
                id,
                kind,
                project: None,
                title: n.title.clone(),
                status: n.status.clone(),
                body: None,
                priority: None,
                assignee: None,
                data: Value::Object(data),
                origin: if n.source.as_deref() == Some("recorded") {
                    Origin::Recorded
                } else {
                    Origin::Parsed
                },
                source: n.source.clone(),
            },
            dir,
            lease: None,
        });
    }
    for t in &jtasks {
        let Some(old_id) = &t.id else { continue };
        let id = format!("task:{old_id}");
        let job = t.job.as_ref().and_then(|j| jobs.get(j));
        let at = [job.and_then(|j| j.created), task_times.get(old_id).copied()]
            .into_iter()
            .flatten()
            .reduce(f64::min)
            .unwrap_or(now);
        let mut data = object(t.data.as_deref());
        data.insert("job".into(), json!(t.job));
        data.insert("n".into(), json!(t.n));
        data.insert("role".into(), json!(t.role));
        let lease = match (&t.agent, t.lease_until) {
            (Some(holder), Some(until)) => Some(Lease {
                holder: Some(holder.clone()),
                epoch: 1,
                until: Some(until),
            }),
            _ => None,
        };
        kind_of.insert(id.clone(), "task".into());
        time_of.insert(id.clone(), at);
        makes.push(Make {
            at,
            actor: "import".into(),
            class: Class::System,
            new: EntityNew {
                id,
                kind: "task".into(),
                project: None,
                title: t.title.clone(),
                status: t.status.clone(),
                body: None,
                priority: None,
                assignee: t.agent.clone(),
                data: Value::Object(data),
                origin: Origin::Recorded,
                source: None,
            },
            dir: job
                .and_then(|j| j.repo.clone())
                .map(PathBuf::from)
                .filter(|p| p.is_absolute()),
            lease,
        });
    }
    let decision_ns: HashSet<i64> = decisions.iter().map(|d| d.n).collect();
    let mut links: Vec<LinkPlan> = Vec::new();
    for d in &decisions {
        let id = format!("decision:{}", d.n);
        let (actor, class) = actor_of(d.author.as_deref());
        let mut data = Map::new();
        data.insert("n".into(), json!(d.n));
        for (k, v) in [
            ("kind", json!(d.kind)),
            ("task", json!(d.task)),
            ("paths", json!(d.paths)),
            ("author", json!(d.author)),
            ("at", json!(d.at)),
            ("ver", json!(d.ver)),
            ("job", json!(d.job)),
        ] {
            if !v.is_null() {
                data.insert(k.into(), v);
            }
        }
        if let Some(m) = d.replaces {
            if decision_ns.contains(&m) {
                links.push(LinkPlan {
                    src: id.clone(),
                    kind: "supersedes".into(),
                    dst: format!("decision:{m}"),
                    data: None,
                    origin: Origin::Recorded,
                    source: None,
                    label: "replaces->supersedes".into(),
                    from: RowOf::Other,
                });
            } else {
                // The number it replaced is kept, so the view still shows it.
                data.insert("replaces".into(), json!(m));
                report.count("replaces->dropped".into());
            }
        }
        let at = d.at.unwrap_or(now);
        kind_of.insert(id.clone(), "decision".into());
        time_of.insert(id.clone(), at);
        makes.push(Make {
            at,
            actor,
            class,
            new: EntityNew {
                id,
                kind: "decision".into(),
                project: None,
                title: d.subject.clone(),
                status: d.status.clone(),
                body: d.reason.clone(),
                priority: None,
                assignee: None,
                data: Value::Object(data),
                origin: Origin::Recorded,
                source: None,
            },
            dir: d
                .job
                .as_ref()
                .and_then(|j| jobs.get(j))
                .and_then(|j| j.repo.clone())
                .map(PathBuf::from)
                .filter(|p| p.is_absolute()),
            lease: None,
        });
    }
    // 6. The links: edges, then parents, then job dependencies.
    let mut ledgers: BTreeMap<String, f64> = BTreeMap::new();
    for e in &edges {
        let old = e.kind.clone().unwrap_or_default();
        let (Some(src), Some(dst)) = (e.src.clone(), e.dst.clone()) else {
            report.count(format!("{old}->dropped"));
            continue;
        };
        let ledger = old == "ledger-of";
        let path_denied = ledger && is_denied(&deny.check(Path::new(&src)));
        if denied.contains(src.as_str())
            || denied.contains(dst.as_str())
            || path_denied
            || source_denied(deny, e.source.as_deref())
        {
            report.denied_edges += 1;
            report.count(format!("{old}->denied"));
            continue;
        }
        let src = if ledger && Path::new(&src).is_absolute() {
            let file = format!("file:{src}");
            if let Some(at) = time_of.get(&dst) {
                let t = ledgers.entry(file.clone()).or_insert(*at);
                *t = t.min(*at);
            }
            file
        } else {
            src
        };
        let from = if src.starts_with("file:/") {
            Some("file")
        } else {
            kind_of.get(&src).map(String::as_str)
        };
        let to = kind_of.get(&dst).map(String::as_str);
        let (Some(from), Some(to)) = (from, to) else {
            report.count(format!("{old}->dropped"));
            continue;
        };
        let new = if old == "on-branch" {
            "on_branch".to_string()
        } else {
            old.clone()
        };
        let (kind, data) = if kinds::link_allowed(&new, from, to) {
            (new, None)
        } else {
            ("relates".to_string(), Some(json!({ "was": old })))
        };
        links.push(LinkPlan {
            label: format!("{old}->{kind}"),
            src,
            kind,
            dst,
            data,
            origin: e
                .origin
                .as_deref()
                .and_then(Origin::parse)
                .unwrap_or(Origin::Imported),
            source: e.source.clone(),
            from: RowOf::Edge,
        });
    }
    for (file, at) in &ledgers {
        let p = &file["file:".len()..];
        kind_of.insert(file.clone(), "file".into());
        makes.push(Make {
            at: *at,
            actor: "import".into(),
            class: Class::System,
            new: EntityNew {
                id: file.clone(),
                kind: "file".into(),
                project: None,
                title: Path::new(p)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned()),
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data: json!({ "path": p }),
                origin: Origin::Parsed,
                source: Some(p.to_string()),
            },
            dir: Path::new(p).parent().map(Path::to_path_buf),
            lease: None,
        });
    }
    for (parent, child) in parents {
        let (Some(pk), Some(ck)) = (kind_of.get(&parent), kind_of.get(&child)) else {
            if matches!(
                kind_of.get(&child).map(String::as_str),
                Some("task" | "step")
            ) {
                report.count("parent->dropped".into());
            }
            continue;
        };
        if kinds::link_allowed("parent_of", pk, ck) {
            links.push(LinkPlan {
                src: parent,
                kind: "parent_of".into(),
                dst: child,
                data: None,
                origin: Origin::Parsed,
                source: None,
                label: "parent->parent_of".into(),
                from: RowOf::Other,
            });
        }
    }
    for (task, dep) in &jdeps {
        let (Some(task), Some(dep)) = (task, dep) else {
            report.count("jdep->dropped".into());
            continue;
        };
        let (t, d) = (format!("task:{task}"), format!("task:{dep}"));
        if kind_of.contains_key(&t) && kind_of.contains_key(&d) {
            links.push(LinkPlan {
                src: d,
                kind: "blocks".into(),
                dst: t,
                data: None,
                origin: Origin::Recorded,
                source: None,
                label: "jdep->blocks".into(),
                from: RowOf::Jdep,
            });
        } else {
            report.count("jdep->dropped".into());
        }
    }
    // 4. The groups: one tx per (time, actor), in time order.
    makes.sort_by(|a, b| a.at.total_cmp(&b.at).then_with(|| a.actor.cmp(&b.actor)));
    let mut groups: Vec<Vec<Make>> = Vec::new();
    for m in makes {
        match groups.last_mut() {
            Some(g) if g[0].at == m.at && g[0].actor == m.actor => g.push(m),
            _ => groups.push(vec![m]),
        }
    }
    let group_of: HashMap<String, usize> = groups
        .iter()
        .enumerate()
        .flat_map(|(i, g)| g.iter().map(move |m| (m.new.id.clone(), i)))
        .collect();
    let mut links_of: Vec<Vec<LinkPlan>> = (0..groups.len()).map(|_| Vec::new()).collect();
    for l in links {
        match (group_of.get(&l.src), group_of.get(&l.dst)) {
            (Some(a), Some(b)) => links_of[*a.max(b)].push(l),
            _ => report.count(format!(
                "{}->dropped",
                l.label.split("->").next().unwrap_or("")
            )),
        }
    }
    hook(path, "entities")?;
    let guard = norn_guard();
    let mut last_at = groups.first().map_or(now, |g| g[0].at);
    // 7. The projects first, at the earliest time.
    let projects = cache.unregistered();
    if !projects.is_empty() {
        let mut meta = TxMeta::new("import", Class::System, "import");
        meta.imported = true;
        let mut tx = Tx::in_rule(conn, meta, last_at, guard.clone())?;
        for p in &projects {
            let n = project::register(&mut tx, p)?;
            cache.set_registered(&p.id, n);
        }
        tx.release_in_rule()?;
        report.txs += 1;
    }
    let mut n_of: HashMap<String, i64> = HashMap::new();
    let (mut nodes_out, mut jtasks_out, mut decisions_out) = (0u64, 0u64, 0u64);
    let (mut edges_out, mut jdeps_out) = (0u64, 0u64);
    for (group, group_links) in groups.into_iter().zip(links_of) {
        let at = group[0].at.max(last_at);
        last_at = at;
        let mut meta = TxMeta::new(group[0].actor.clone(), group[0].class, "import");
        meta.imported = true;
        let mut tx = Tx::in_rule(conn, meta, at, guard.clone())?;
        for mut m in group {
            m.new.project = m.dir.as_deref().and_then(|d| cache.project_n(d));
            if m.new.project.is_none() {
                report.no_project += 1;
            }
            let (id, kind) = (m.new.id.clone(), m.new.kind.clone());
            let made = match entity::create(&mut tx, m.new) {
                Ok(e) => e.n,
                Err(WriteError::Refused(t)) if t == "id exists" => {
                    report.duplicates += 1;
                    continue;
                }
                Err(e) => return Err(Stop::Failed(format!("an entity of kind {kind}: {e}"))),
            };
            if let Some(lease) = m.lease {
                entity::update(
                    &mut tx,
                    made,
                    None,
                    Changes {
                        lease: Some(lease),
                        ..Changes::default()
                    },
                )?;
            }
            if id.starts_with("decision:") {
                decisions_out += 1;
            } else if kind == "task" && !id.starts_with("task:/") {
                jtasks_out += 1;
            } else if !id.starts_with("file:") {
                nodes_out += 1;
            }
            n_of.insert(id, made);
        }
        for l in group_links {
            let (Some(&s), Some(&d)) = (n_of.get(&l.src), n_of.get(&l.dst)) else {
                report.count(format!(
                    "{}->dropped",
                    l.label.split("->").next().unwrap_or("")
                ));
                continue;
            };
            let added = link::add(
                &mut tx,
                s,
                &l.kind,
                d,
                l.data,
                l.origin,
                l.source.as_deref(),
            )?;
            if added.existed {
                report.count(format!("{}->merged", l.label));
                continue;
            }
            match l.from {
                RowOf::Edge => edges_out += 1,
                RowOf::Jdep => jdeps_out += 1,
                RowOf::Other => {}
            }
            report.count(l.label);
        }
        tx.release_in_rule()?;
        report.txs += 1;
    }
    let mut tables = BTreeMap::new();
    tables.insert("node".to_string(), (nodes.len() as u64, nodes_out));
    tables.insert("edge".to_string(), (edges.len() as u64, edges_out));
    tables.insert("jtask".to_string(), (jtasks.len() as u64, jtasks_out));
    tables.insert("jdep".to_string(), (jdeps.len() as u64, jdeps_out));
    tables.insert(
        "decision".to_string(),
        (decisions.len() as u64, decisions_out),
    );
    tables.insert(
        "file".to_string(),
        (files_in, files_in - report.denied_files),
    );
    tables.insert("meta".to_string(), (meta_rows, meta_rows));
    for t in KEPT {
        let n = count_rows(conn, t)?;
        tables.insert((*t).to_string(), (n, n));
    }
    report.tables = tables;
    Ok(())
}
