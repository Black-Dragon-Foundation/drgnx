//! The graph store's methods the front serves (docs/develop/store.md; docs/develop/hub.md, "The store").
//!
//! - **The tracker scan's door** (Urdr Task 15a): `graph/put-parsed` and `graph/record`, each one request of the graph
//!   writer, applied by [`norn::parsed`] with the deny-list in force at the call. Projects are resolved before the
//!   write (git, on a blocking thread, never under the writer's lock); a put is `scan:<root>` (class `system`), a
//!   record the caller's, keyed by its `collected` key.
//! - **The store's methods for the user** (Urdr Task 15b; storage §6.6): reads (`graph/entity`, `neighbors`, `path`,
//!   `history`, `sql`), history's writes (`graph/revert`, `graph/proposed`), `graph/excise`, `graph/grants`, the
//!   copies (`export`, `import`, `backup`), the settings (`graph/settings`, `graph/privacy`) and the tracker for the
//!   editor (`tasks/*`). Every one is user class at the registry; the writes are the caller's tx (`coord::tx_meta`:
//!   the editor's `user`, the backend's connection `backend` of class `system`), so the store's own class rules (grants
//!   and `setting:*` keys are the user's) apply again, and the backend's connection is refused here first.
//! - **Cards** ([`settle`]): an `access` card settles into a grant (`session`, `project`, `profile`) or nothing
//!   (`refuse`, `resolved`), a `close` card into done (`accept`, at the version the card names) or a notice
//!   (`reject`, `resolved`); never a grant or a close from the backend's connection. The requester hears either way.
//! - **Errors** as the front's other writes: a refusal is `invalid-params` with its text, a newer file `schema`, the
//!   rest `internal`; what only the user may do, asked by the backend's connection, is `not-allowed`.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use crate::coord::{self, Writer};
use crate::dispatch::Caller;
use norn::deny::{DenyList, Source, Verdict};
use norn::grants::{self, Access, What, Who};
use norn::parsed;
use norn::project::{self, ProjectCache};
use norn::scope::{self, Caller as StoreCaller};
use norn::store::{CoordError, WTx};
use norn::tools::{Coord, GraphStore, ToolSets};
use norn::tracker::{self, TaskAnswer, TaskOp};
use norn::write::{cards, messages, notices};
use runstav::methods::Params;
use runstav::methods::coord::Settled;
use runstav::methods::graph as api;
use runstav::methods::tasks as tasks_api;
use runstav::wire::{Error, ErrorCode};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use urdr::Connection;
use urdr::graph::entity::{self, Ent};
use urdr::graph::schema::SENTINEL;
use urdr::graph::walk::{self, Seen};
use urdr::graph::writer::Blocker;
use urdr::graph::{
    Class as TxClass, Tx, TxMeta, WriteError, WriterHandle, Written, backup, excise, export, hist,
    link, search, sqlro,
};

/// Where the store's other files are (set by the server once the store is open).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoreDirs {
    /// The user's home (the personal-notes deny-list).
    pub home: PathBuf,
    /// drgnx's config folder (`personal-notes-allow.json`).
    pub config: PathBuf,
    /// `<state>/hub` (the session transcripts in `sessions/`).
    pub hub: PathBuf,
}

fn error(code: ErrorCode, message: impl Into<String>, path: Option<&str>) -> Error {
    Error {
        code,
        message: message.into(),
        path: path.map(str::to_owned),
    }
}

fn internal(message: impl Into<String>) -> Error {
    error(ErrorCode::Internal, message, None)
}

fn invalid(path: &str, message: impl Into<String>) -> Error {
    error(ErrorCode::InvalidParams, message, Some(path))
}

fn not_allowed(path: &str, message: impl Into<String>) -> Error {
    error(ErrorCode::NotAllowed, message, Some(path))
}

fn refused(text: impl Into<String>) -> CoordError {
    CoordError::Refused(text.into())
}

/// A graph writer's error as the method answers it.
fn fail(e: WriteError) -> Error {
    let (code, message) = match &e {
        WriteError::Refused(text) => (ErrorCode::InvalidParams, text.clone()),
        WriteError::Conflict(_) => (ErrorCode::InvalidParams, e.to_string()),
        WriteError::ReadOnly { .. } => (ErrorCode::Schema, e.to_string()),
        WriteError::Retryable(_) => (ErrorCode::Internal, "work.db is busy; retry".into()),
        WriteError::NotReady(text) => (ErrorCode::Internal, text.clone()),
        WriteError::Closed | WriteError::Sql(_) => {
            tracing::warn!("a graph write failed: {e}");
            (ErrorCode::Internal, e.to_string())
        }
    };
    error(code, message, None)
}

/// Seconds since the epoch.
fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// A wire number as the store's integer.
fn int(n: u64) -> i64 {
    i64::try_from(n).unwrap_or(i64::MAX)
}

fn show(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn opt<T>(r: Result<T, urdr::SqliteError>) -> Result<Option<T>, urdr::SqliteError> {
    match r {
        Ok(v) => Ok(Some(v)),
        Err(urdr::SqliteError::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e),
    }
}

/// The hub's graph store and the deny-list in force now.
fn store(tools: &Coord) -> Result<(GraphStore, Arc<DenyList>), Error> {
    let g = tools
        .graph()
        .cloned()
        .ok_or_else(|| internal("the graph store is not open"))?;
    let deny = tools
        .deny()
        .ok_or_else(|| internal("the graph store is not open"))?;
    Ok((g, deny))
}

/// `<data>`: work.db's folder.
fn data_dir(g: &GraphStore) -> PathBuf {
    g.writer
        .path()
        .parent()
        .map_or_else(|| PathBuf::from("."), Path::to_path_buf)
}

/// DIRS resolved to projects (git), on a blocking thread.
async fn resolve(dirs: Vec<PathBuf>) -> ProjectCache {
    if dirs.is_empty() {
        return ProjectCache::default();
    }
    tokio::task::spawn_blocking(move || {
        let mut cache = ProjectCache::default();
        for d in &dirs {
            cache.fill(d);
        }
        cache
    })
    .await
    .unwrap_or_default()
}

/// F in one request of WRITER after its `tx` row from META; a writer that is not open runs its tick (the opening
/// rule again) first, as the coordination store does.
async fn write<R, F>(writer: &WriterHandle, meta: TxMeta, f: F) -> Result<Written<R>, Error>
where
    R: Serialize + DeserializeOwned + Send + 'static,
    F: for<'t, 'c> FnOnce(&'t mut Tx<'c>) -> Result<R, WriteError> + Send + 'static,
{
    if !writer.status().open {
        writer.tick().await;
    }
    writer.write(meta, f).await.map_err(fail)
}

/// F on the store's read connection.
async fn read<R: Send + 'static>(
    w: &Writer,
    f: impl FnOnce(&Connection) -> Result<R, CoordError> + Send + 'static,
) -> Result<R, Error> {
    w.db.read(f).await.map_err(coord::fail)
}

/// What a write that is taken back answers to its writer (the caller never sees it).
const UNDONE: &str = "taken back: nothing written";

/// F in one transaction of CALLER's: kept when F says so, else rolled back (a revert that is blocked, a `cascade`
/// look) with F's answer all the same.
async fn write_or_undo<R: Send + 'static>(
    w: &Writer,
    caller: &Caller,
    method: &'static str,
    f: impl FnOnce(&mut WTx<'_>) -> Result<(R, bool), CoordError> + Send + 'static,
) -> Result<R, Error> {
    let slot: Arc<Mutex<Option<R>>> = Arc::new(Mutex::new(None));
    let theirs = slot.clone();
    let r = w
        .write(caller, method, move |tx| {
            let (v, keep) = f(tx)?;
            if keep {
                return Ok(v);
            }
            *lock(&theirs) = Some(v);
            Err(refused(UNDONE))
        })
        .await;
    match r {
        Ok(v) => Ok(v),
        Err(e) => lock(&slot).take().ok_or_else(|| coord::fail(e)),
    }
}

/// The store's methods (`graph/*`, `tasks/*`) when PARAMS is one; any other method's params come back.
pub async fn serve(
    w: &Writer,
    tools: &Coord,
    dirs: Option<&StoreDirs>,
    caller: &Caller,
    params: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    Ok(match params {
        Params::GraphPutParsed(p) => put_parsed(w, tools, p).await,
        Params::GraphRecord(p) => record(w, tools, caller, p).await,
        Params::GraphEntity(p) => entity_of(w, p).await,
        Params::GraphNeighbors(p) => neighbors(w, tools, p).await,
        Params::GraphPath(p) => path(w, tools, p).await,
        Params::GraphHistory(p) => history(w, p).await,
        Params::GraphRevert(p) => revert(w, caller, p).await,
        Params::GraphExcise(p) => excise_of(w, dirs, caller, p).await,
        Params::GraphGrants(p) => grants_of(w, caller, p).await,
        Params::GraphProposed(p) => proposed(w, caller, p).await,
        Params::GraphSql(p) => sql(tools, p).await,
        Params::GraphExport(p) => export_of(w, tools, p).await,
        Params::GraphImport(p) => import(w, tools, caller, p).await,
        Params::GraphBackup(_) => backup_now(tools).await,
        Params::GraphCompact(_) => Err(internal(
            "graph/compact is not built yet (Urdr Task 17 brings compaction)",
        )),
        Params::GraphSettings(p) => settings(w, caller, p).await,
        Params::GraphPrivacy(_) => privacy(tools, dirs).await,
        Params::TasksReady(p) => tasks_ready(w, p).await,
        Params::TasksFind(p) => tasks_find(w, p).await,
        Params::TasksWrite(p) => tasks_write(w, caller, p).await,
        other => return Err(Box::new(other)),
    })
}

// ------------------------------------------------------------------------------------- the tracker scan's door

/// `graph/put-parsed`.
pub async fn put_parsed(
    w: &Writer,
    tools: &Coord,
    p: api::PutParsedParams,
) -> Result<Value, Error> {
    let (g, deny) = store(tools)?;
    let req = Arc::new(p);
    let (d, r) = (deny.clone(), req.clone());
    let dirs = g
        .pool
        .with(move |conn| parsed::dirs(conn, &d, &r))
        .await
        .map_err(|e| internal(e.to_string()))?
        .map_err(|e| internal(e.to_string()))?;
    let mut projects = resolve(dirs.into_iter().collect()).await;
    let req = Arc::try_unwrap(req).unwrap_or_else(|r| (*r).clone());
    let actor = match &req.root {
        Some(root) => format!("scan:{}", root.as_str()),
        None => "scan".into(),
    };
    let meta = TxMeta::new(actor, TxClass::System, "scan");
    let written = write(&g.writer, meta, move |tx| {
        parsed::put_with(tx, &deny, &mut projects, req)
    })
    .await?;
    w.signals.wrote();
    Ok(json!(written.value))
}

/// `graph/record`.
pub async fn record(
    w: &Writer,
    tools: &Coord,
    caller: &Caller,
    p: api::RecordParams,
) -> Result<Value, Error> {
    let (g, deny) = store(tools)?;
    let mut projects = resolve(parsed::record_dir(&deny, &p).into_iter().collect()).await;
    let mut meta = coord::tx_meta(caller, "graph/record");
    meta.req = p.collected.as_ref().map(|k| k.to_string());
    let written = write(&g.writer, meta, move |tx| {
        parsed::record(tx, &deny, &mut projects, p)
    })
    .await?;
    if !written.replayed {
        w.signals.wrote();
    }
    Ok(json!(written.value))
}

// ------------------------------------------------------------------------------------------------------- reads

/// The user's scope in a walk: everything.
struct Everything;

impl walk::Scope for Everything {
    fn allows(&self, _: Option<i64>) -> Seen {
        Seen::Full
    }

    fn valid(&self) -> bool {
        true
    }
}

/// Who wrote tx TX: `{tx, actor, class, tool, at}` (null when there is no such tx).
fn tx_by(c: &Connection, tx: i64) -> Result<Value, urdr::SqliteError> {
    Ok(opt(c.query_row(
        "select id, actor, class, tool, at from tx where id = ?1",
        [tx],
        |r| {
            Ok(json!({
                "tx": r.get::<_, i64>(0)?,
                "actor": r.get::<_, String>(1)?,
                "class": r.get::<_, String>(2)?,
                "tool": r.get::<_, Option<String>>(3)?,
                "at": r.get::<_, f64>(4)?,
            }))
        },
    ))?
    .unwrap_or(Value::Null))
}

/// The newest tx.
fn last_tx(c: &Connection) -> Result<i64, urdr::SqliteError> {
    c.query_row("select coalesce(max(id), 0) from tx", [], |r| r.get(0))
}

/// Entity ID's `n`, or `invalid-params` at PATH.
async fn n_of(w: &Writer, id: &str, path: &'static str) -> Result<i64, Error> {
    let key = id.to_owned();
    read(w, move |c| Ok(entity::by_id(c, &key)?.map(|e| e.n)))
        .await?
        .ok_or_else(|| invalid(path, format!("no entity {id}")))
}

/// `graph/entity`.
async fn entity_of(w: &Writer, p: api::EntityParams) -> Result<Value, Error> {
    let id = p.id.into_inner();
    let missing = format!("no entity {id}");
    let include: Vec<api::Include> = p
        .include
        .map(|v| v.iter().copied().collect())
        .unwrap_or_default();
    let as_of = p.as_of.map(int);
    let found = read(w, move |c| {
        let Some(cur) = entity::by_id(c, &id)? else {
            return Ok(None);
        };
        let (ent, approximate) = match as_of {
            Some(t) => match hist::entity_as_of(c, cur.n, t)? {
                Some(a) => (a.ent, a.approximate),
                None => return Ok(None),
            },
            None => (cur, false),
        };
        let mut a = api::EntityAnswer {
            by: json!({"created": tx_by(c, ent.created_tx)?, "updated": tx_by(c, ent.updated_tx)?}),
            entity: json!(ent),
            approximate: approximate.then_some(true),
            links: None,
            notes: None,
            history: None,
        };
        if include.contains(&api::Include::Links) {
            let at = match as_of {
                Some(t) => t,
                None => last_tx(c)?,
            };
            let links = hist::links_as_of(c, ent.n, &[], link::Direction::Both, at)?;
            a.links = Some(links.iter().map(|l| json!(l)).collect());
        }
        if include.contains(&api::Include::Notes) {
            let ns: Vec<i64> = {
                let mut st = c.prepare(
                    "select l.src from link l join entity e on e.n = l.src where l.dst = ?1 and l.kind = 'about' \
                     and l.tx_to = ?2 and e.kind = 'note' and e.retired_tx is null order by l.src",
                )?;
                st.query_map((ent.n, SENTINEL), |r| r.get(0))?
                    .collect::<Result<_, _>>()?
            };
            let mut notes = Vec::new();
            for n in ns {
                notes.extend(entity::by_n(c, n)?.map(|e| json!(e)));
            }
            a.notes = Some(notes);
        }
        if include.contains(&api::Include::History) {
            let versions = hist::history(c, ent.n, None)?;
            a.history = Some(versions.iter().map(|v| json!(v)).collect());
        }
        Ok(Some(a))
    })
    .await?;
    found
        .map(|a| json!(a))
        .ok_or_else(|| invalid("id", missing))
}

fn direction(d: api::Direction) -> link::Direction {
    match d {
        api::Direction::Out => link::Direction::Out,
        api::Direction::In => link::Direction::In,
        api::Direction::Both => link::Direction::Both,
    }
}

fn kinds(k: Option<runstav::types::Bounded<Vec<api::KindName>, 32>>) -> Vec<String> {
    k.map(|v| v.iter().map(|x| x.to_string()).collect())
        .unwrap_or_default()
}

fn walk_error(e: walk::WalkError) -> Error {
    match e {
        walk::WalkError::Refused(text) => invalid("kinds", text),
        walk::WalkError::Sql(text) => internal(text),
    }
}

fn walk_answer(out: walk::WalkOut) -> Value {
    json!(api::WalkAnswer {
        nodes: out.nodes.iter().map(|n| json!(n)).collect(),
        links: out.links.iter().map(|l| json!(l)).collect(),
        hidden: u64::from(out.hidden),
        truncated: out
            .truncated
            .and_then(|t| json!(t).as_str().map(str::to_owned)),
    })
}

/// `graph/neighbors`.
async fn neighbors(w: &Writer, tools: &Coord, p: api::NeighborsParams) -> Result<Value, Error> {
    let (g, _) = store(tools)?;
    let from = n_of(w, &p.id, "id").await?;
    let q = walk::Walk {
        from,
        kinds: kinds(p.kinds),
        direction: direction(p.direction.unwrap_or(api::Direction::Both)),
        depth: p.depth.unwrap_or(1),
        as_of: p.as_of.map(int),
    };
    let out = walk::neighbors(&g.pool, q, &Everything, walk::Budget::default())
        .await
        .map_err(walk_error)?;
    Ok(walk_answer(out))
}

/// `graph/path`.
async fn path(w: &Writer, tools: &Coord, p: api::PathParams) -> Result<Value, Error> {
    let (g, _) = store(tools)?;
    let from = n_of(w, &p.from, "from").await?;
    let to = n_of(w, &p.to, "to").await?;
    let q = walk::PathQ {
        from,
        to,
        kinds: kinds(p.kinds),
        max_depth: p.max_depth.unwrap_or(3),
        as_of: p.as_of.map(int),
    };
    let out = walk::path(&g.pool, q, &Everything, walk::Budget::default())
        .await
        .map_err(walk_error)?;
    Ok(walk_answer(out))
}

/// `graph/history`.
async fn history(w: &Writer, p: api::HistoryParams) -> Result<Value, Error> {
    let n = n_of(w, &p.id, "id").await?;
    let since = p.since.map(int);
    let versions = read(w, move |c| Ok(hist::history(c, n, since)?)).await?;
    Ok(json!(api::HistoryAnswer {
        versions: versions.iter().map(|v| json!(v)).collect(),
    }))
}

/// `graph/sql`.
async fn sql(tools: &Coord, p: api::SqlParams) -> Result<Value, Error> {
    let (g, _) = store(tools)?;
    let params: Vec<Value> = p
        .params
        .map(|v| {
            v.into_inner()
                .into_iter()
                .map(|x| match x {
                    api::SqlParam::Null(()) => Value::Null,
                    api::SqlParam::Bool(b) => json!(b),
                    api::SqlParam::Int(i) => json!(i),
                    api::SqlParam::Real(f) => json!(f),
                    api::SqlParam::Text(t) => json!(t.as_str()),
                })
                .collect()
        })
        .unwrap_or_default();
    let deadline = Duration::from_millis(p.deadline_ms.unwrap_or(2000));
    let cap = usize::try_from(p.rows.unwrap_or(1000)).unwrap_or(1000);
    let rows = sqlro::run(&g.pool, p.sql.into_inner(), params, deadline, cap)
        .await
        .map_err(|r| match r {
            sqlro::SqlRefusal::NotAllowed(what) => invalid(
                "sql",
                format!("graph/sql runs one read-only SELECT: {what} is not allowed"),
            ),
            sqlro::SqlRefusal::Deadline => {
                invalid("deadline_ms", "the query ran past its deadline")
            }
            sqlro::SqlRefusal::TooManyStatements => invalid("sql", "one statement only"),
            sqlro::SqlRefusal::Sql(text) => invalid("sql", text),
        })?;
    Ok(json!(api::SqlAnswer {
        columns: rows.columns,
        rows: rows.rows,
        truncated: rows.truncated,
    }))
}

// ------------------------------------------------------------------------------------------- history's writes

fn revert_answer(out: hist::Revert, listed: bool) -> api::RevertAnswer {
    let mut a = api::RevertAnswer {
        listed: listed.then_some(true),
        ..api::RevertAnswer::default()
    };
    match out {
        hist::Revert::Done { entities, links } => {
            a.reverted = Some(api::Reverted { entities, links })
        }
        hist::Revert::Blocked { later } => a.blocked = Some(later),
    }
    a
}

/// `graph/revert`: a tx (blocked: nothing written, the later txs named), or an entity put back to a version; with
/// `cascade` only what it would do.
async fn revert(w: &Writer, caller: &Caller, p: api::RevertParams) -> Result<Value, Error> {
    let cascade = p.cascade == Some(true);
    let a = match (p.tx, p.entity, p.ver) {
        (Some(t), _, _) => {
            let t = int(t);
            write_or_undo(w, caller, "graph/revert", move |tx| {
                let out = hist::revert(tx, t)?;
                let done = matches!(out, hist::Revert::Done { .. });
                // a reverted grant changes scopes at once
                scope::grants_changed(tx.sql());
                Ok((revert_answer(out, cascade), done && !cascade))
            })
            .await?
        }
        (None, Some(id), Some(ver)) => {
            let (id, ver) = (id.into_inner(), int(ver));
            write_or_undo(w, caller, "graph/revert", move |tx| {
                let e = entity::by_id(tx.sql(), &id)?
                    .ok_or_else(|| refused(format!("no entity {id}")))?;
                hist::restore(tx, e.n, ver)?;
                scope::grants_changed(tx.sql());
                let a = api::RevertAnswer {
                    reverted: Some(api::Reverted {
                        entities: vec![e.n],
                        links: Vec::new(),
                    }),
                    blocked: None,
                    listed: cascade.then_some(true),
                };
                Ok((a, !cascade))
            })
            .await?
        }
        _ => return Err(invalid("tx", "revert takes tx, or entity and ver")),
    };
    Ok(json!(a))
}

/// `graph/proposed`.
async fn proposed(w: &Writer, caller: &Caller, p: api::ProposedParams) -> Result<Value, Error> {
    let (txs, accept) = match (p.accept, p.reject) {
        (Some(a), None) => (a.into_inner(), true),
        (None, Some(r)) => (r.into_inner(), false),
        _ => return Err(invalid("accept", "one of accept or reject")),
    };
    let txs: Vec<i64> = txs.into_iter().map(int).collect();
    let a = write_or_undo(w, caller, "graph/proposed", move |tx| {
        let out = hist::settle_proposed(tx, &txs, accept)?;
        let keep = matches!(out, hist::Revert::Done { .. });
        Ok((revert_answer(out, false), keep))
    })
    .await?;
    Ok(json!(a))
}

/// The regular `*.jsonl` files in DIR (the session transcripts), sorted.
fn transcripts(dir: &Path) -> Vec<PathBuf> {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<PathBuf> = rd
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
        .filter(|p| std::fs::symlink_metadata(p).is_ok_and(|m| m.is_file()))
        .collect();
    out.sort();
    out
}

/// `graph/excise`: the excise, the scrub after it, then the copies outside work.db that hold the text (removed or
/// redacted on request).
async fn excise_of(
    w: &Writer,
    dirs: Option<&StoreDirs>,
    caller: &Caller,
    p: api::ExciseParams,
) -> Result<Value, Error> {
    if caller.backend {
        return Err(not_allowed(
            "target",
            "only the user excises: the backend's connection never does",
        ));
    }
    let writer =
        w.db.graph_writer()
            .cloned()
            .ok_or_else(|| internal("the graph store is not open"))?;
    let target = match &p.target {
        api::ExciseTarget::Tx(n) => excise::Target::Tx(int(*n)),
        api::ExciseTarget::Entity(id) => excise::Target::Entity(id.to_string()),
    };
    let fields = p
        .fields
        .as_ref()
        .map(|f| f.iter().map(|x| x.as_str().to_owned()).collect());
    let rep = excise::excise(
        &writer,
        coord::tx_meta(caller, "graph/excise"),
        target,
        fields,
        p.reason.as_str().to_owned(),
        norn::write::blankers(),
    )
    .await
    .map_err(fail)?;
    w.signals.wrote();
    let mut a = api::ExciseAnswer {
        tx: rep.tx,
        entities: rep.entities,
        versions: rep.versions,
        txs_blanked: rep.txs_blanked,
        blanked: rep.blanked,
        ..api::ExciseAnswer::default()
    };
    match excise::scrub(&writer).await {
        Ok(s) => {
            a.vacuumed = s.vacuumed;
            a.wal_truncated = s.wal_truncated;
            a.blocked_by = s.blocked_by.map(|b| {
                match b {
                    Blocker::Readers => "readers",
                    Blocker::Writer => "writer",
                }
                .to_owned()
            });
        }
        Err(e) => tracing::warn!("the scrub after an excise failed: {e}"),
    }
    let holding = excise::holding(&excise::kept_copies(writer.path()), &rep.needles);
    for f in holding {
        if p.rotate_backups == Some(true) {
            match std::fs::remove_file(&f) {
                Ok(()) => {
                    a.backups_removed.push(show(&f));
                    continue;
                }
                Err(e) => tracing::warn!("cannot remove {}: {e}", f.display()),
            }
        }
        a.backups_holding.push(show(&f));
    }
    if let Some(d) = dirs {
        let marker = excise::marker(rep.tx);
        let files = transcripts(&d.hub.join("sessions"));
        for f in excise::holding(&files, &rep.needles) {
            if p.transcripts == Some(true) {
                match excise::redact(&f, &rep.needles, &marker) {
                    Ok(_) => {
                        a.transcripts_redacted.push(show(&f));
                        continue;
                    }
                    Err(e) => tracing::warn!("cannot redact {}: {e}", f.display()),
                }
            }
            a.transcripts_holding.push(show(&f));
        }
    }
    Ok(json!(a))
}

// ------------------------------------------------------------------------------------------------------ grants

/// Project TEXT's `n`: its id (`project:…`), one of its slugs, or its `n`; a live project only.
fn project_n(c: &Connection, text: &str) -> Result<Option<i64>, urdr::SqliteError> {
    let live = |e: &Ent| e.kind == "project" && e.retired_tx.is_none();
    let full = if text.starts_with("project:") {
        text.to_owned()
    } else {
        format!("project:{text}")
    };
    if let Some(e) = entity::by_id(c, &full)?.filter(live) {
        return Ok(Some(e.n));
    }
    let bare = text.strip_prefix("project:").unwrap_or(text);
    let alias: Option<i64> = opt(c.query_row(
        "select project from project_alias where slug = ?1",
        [bare],
        |r| r.get(0),
    ))?;
    if alias.is_some() {
        return Ok(alias);
    }
    if let Ok(n) = bare.parse::<i64>()
        && entity::by_n(c, n)?.is_some_and(|e| live(&e))
    {
        return Ok(Some(n));
    }
    Ok(None)
}

/// A grant's `who` as the user writes it: `project:ID|SLUG|N`, `profile:NAME`, `session:SID`.
fn who_of(c: &Connection, text: &str) -> Result<Option<Who>, urdr::SqliteError> {
    if text.starts_with("project:") {
        return Ok(project_n(c, text)?.map(Who::Project));
    }
    Ok(Who::parse(text))
}

/// A grant's `what`: `project:ID|SLUG|N`, `*`, `task:ID` or `task:N`.
fn what_of(c: &Connection, text: &str) -> Result<Option<What>, urdr::SqliteError> {
    if text == "*" {
        return Ok(Some(What::All));
    }
    if text.starts_with("project:") {
        return Ok(project_n(c, text)?.map(What::Project));
    }
    if let Some(rest) = text.strip_prefix("task:") {
        if let Some(e) = entity::by_id(c, text)?.filter(|e| e.kind == "task") {
            return Ok(Some(What::Task(e.n)));
        }
        return Ok(rest.parse().ok().map(What::Task));
    }
    Ok(None)
}

fn view(g: &grants::Grant, now: f64) -> api::GrantView {
    api::GrantView {
        id: g.id.clone(),
        who: g.who.to_string(),
        what: g.what.to_string(),
        access: g.access.as_str().to_owned(),
        expires: g.expires,
        status: g.status.clone(),
        active: g.active(now),
    }
}

/// `graph/grants`.
async fn grants_of(w: &Writer, caller: &Caller, p: api::GrantsParams) -> Result<Value, Error> {
    let at = now();
    if let Some(l) = p.list {
        let who = l.who.map(|s| s.into_inner());
        let active = l.active;
        let list = read(w, move |c| {
            let who = match who {
                Some(t) => {
                    Some(who_of(c, &t)?.ok_or_else(|| refused(format!("no such who: {t}")))?)
                }
                None => None,
            };
            let filter = grants::Filter { who, active };
            Ok(grants::list(c, &StoreCaller::user(false), &filter, at)?)
        })
        .await?;
        return Ok(json!(api::GrantsAnswer {
            grants: Some(list.iter().map(|g| view(g, at)).collect()),
            ..api::GrantsAnswer::default()
        }));
    }
    // the registry's class check is the first door; this one holds without it
    if caller.backend || caller.class != runstav::registry::Class::User {
        let path = if p.grant.is_some() { "grant" } else { "revoke" };
        return Err(not_allowed(
            path,
            "grants are the user's: an agent's or the backend's connection never makes or revokes one",
        ));
    }
    if let Some(g) = p.grant {
        let (who, what, access, expires) =
            (g.who.into_inner(), g.what.into_inner(), g.access, g.expires);
        let made = w
            .write(caller, "graph/grants", move |tx| {
                let w = who_of(tx.sql(), &who)?.ok_or_else(|| {
                    refused(format!(
                        "no such who: {who} (project:ID or a slug, profile:NAME or session:SID)"
                    ))
                })?;
                let x = what_of(tx.sql(), &what)?.ok_or_else(|| {
                    refused(format!(
                        "no such what: {what} (project:ID or a slug, *, or task:ID)"
                    ))
                })?;
                let a = match access {
                    api::GrantAccess::Read => Access::Read,
                    api::GrantAccess::EditUserTasks => Access::EditUserTasks,
                };
                Ok(grants::create(tx, w, x, a, expires)?)
            })
            .await
            .map_err(coord::fail)?;
        return Ok(json!(api::GrantsAnswer {
            grant: Some(view(&made, at)),
            ..api::GrantsAnswer::default()
        }));
    }
    let id = p.revoke.map(|r| r.into_inner()).unwrap_or_default();
    let revoked = w
        .write(caller, "graph/grants", move |tx| {
            Ok(grants::revoke(tx, &id)?)
        })
        .await
        .map_err(coord::fail)?;
    Ok(json!(api::GrantsAnswer {
        revoked: Some(revoked),
        ..api::GrantsAnswer::default()
    }))
}

// ------------------------------------------------------------------------------------------------------- cards

/// An access card's choices that make a grant.
const GRANT_CHOICES: [&str; 3] = ["session", "project", "profile"];

fn check_access(choice: &str, backend: bool) -> Result<(), Error> {
    match choice {
        c if GRANT_CHOICES.contains(&c) && backend => Err(not_allowed(
            "choice",
            "only the user grants access: the backend's connection settles an access card only by refusing",
        )),
        "session" | "project" | "profile" | "refuse" | "resolved" => Ok(()),
        other => Err(invalid(
            "choice",
            format!(
                "an access card's choices are session, project, profile and refuse, not {other:?}"
            ),
        )),
    }
}

fn check_close(choice: &str, backend: bool) -> Result<(), Error> {
    match choice {
        "accept" if backend => Err(not_allowed(
            "choice",
            "only the user closes a task: the backend's connection settles a close card only by rejecting",
        )),
        "accept" | "reject" | "resolved" => Ok(()),
        other => Err(invalid(
            "choice",
            format!("a close card's choices are accept and reject, not {other:?}"),
        )),
    }
}

/// The actor a session's notices go to (`agent:SID`; an outside agent's own name).
fn requester(session: &str) -> String {
    if session.starts_with("agent:") || session.starts_with("ext:") {
        session.to_owned()
    } else {
        format!("agent:{session}")
    }
}

/// The card's `data`, parsed (null when it has none, or none that parses).
fn card_data(text: Option<String>) -> Value {
    text.and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null)
}

/// Access card CARD settled with CHOICE (checked): a read grant of the target project for the requesting session,
/// its project or its profile, made in this tx (the user's); nothing for `refuse` and `resolved`. A message tells the
/// requester either way. False when the card was not open.
pub(crate) fn settle_access(
    tx: &mut WTx<'_>,
    card: i64,
    choice: &str,
    now: f64,
) -> Result<bool, CoordError> {
    let Some(data) = opt(tx.sql().query_row(
        "select data from card where id = ?1 and state = 'open'",
        [card],
        |r| r.get::<_, Option<String>>(0),
    ))?
    else {
        return Ok(false);
    };
    let d = card_data(data);
    let session = d["session"].as_str().unwrap_or_default().to_owned();
    let target = d["target"].as_str().unwrap_or_default().to_owned();
    let who = match choice {
        "session" if session.is_empty() => {
            return Err(refused("the card names no session: refuse it"));
        }
        "session" => Some(Who::Session(session.clone())),
        "profile" => Some(Who::Profile(
            d["profile"]
                .as_str()
                .filter(|p| !p.is_empty())
                .ok_or_else(|| {
                    refused("the session runs without a profile: grant its session or its project")
                })?
                .to_owned(),
        )),
        "project" => {
            let mine = d["project"].as_str().unwrap_or_default();
            Some(Who::Project(project_n(tx.sql(), mine)?.ok_or_else(
                || refused("the session has no project in the store: grant its session"),
            )?))
        }
        _ => None,
    };
    if !cards::card_settle(tx, card, choice, now)? {
        return Ok(false);
    }
    let said = match who {
        Some(who) => {
            let what = project_n(tx.sql(), &target)?
                .ok_or_else(|| refused(format!("no project {target} in the store: refuse it")))?;
            let shown = who.to_string();
            let g = grants::create(tx, who, What::Project(what), Access::Read, None)?;
            format!("granted ({}): {shown} may read {target}", g.id)
        }
        None => format!("refused: no access to {target}"),
    };
    if !session.is_empty() {
        messages::send(
            tx,
            messages::Send {
                job: None,
                sender: None,
                recipient: requester(&session),
                text: format!("your access request (card {card}): {said}"),
                seen: None,
                answers: None,
                question: false,
            },
            now,
        )?;
    }
    Ok(true)
}

/// Close card CARD settled with CHOICE (checked): `accept` sets the task done as the user if it is still at the
/// card's version (else the conflict: an error, so the card stays open); `reject` and `resolved` change nothing and
/// tell the agent that proposed it. False when the card was not open.
pub(crate) fn settle_close(
    tx: &mut WTx<'_>,
    card: i64,
    choice: &str,
    now: f64,
) -> Result<bool, CoordError> {
    let Some((entity_n, data)) = opt(tx.sql().query_row(
        "select entity, data from card where id = ?1 and state = 'open'",
        [card],
        |r| Ok((r.get::<_, Option<i64>>(0)?, r.get::<_, Option<String>>(1)?)),
    ))?
    else {
        return Ok(false);
    };
    let d = card_data(data);
    let task = d["task"].as_str().unwrap_or_default().to_owned();
    let ver = d["ver"].as_i64().unwrap_or(-1);
    let by = d["by"].as_str().unwrap_or_default().to_owned();
    if !cards::card_settle(tx, card, choice, now)? {
        return Ok(false);
    }
    if choice == "accept" {
        match tracker::accept_close(tx, &StoreCaller::user(false), &task, ver)? {
            TaskAnswer::Done { .. } => {}
            TaskAnswer::Conflict { ver: at, .. } => {
                return Err(refused(format!(
                    "conflict: {task} changed since the close was proposed (version {ver} then, {at} now); \
                     the card stays open"
                )));
            }
            other => return Err(refused(format!("{task} was not closed: {other:?}"))),
        }
    } else if !by.is_empty() {
        let title = entity::by_id(tx.sql(), &task)?.and_then(|e| e.title);
        notices::notice(
            tx,
            notices::Notice {
                recipient: by,
                entity: entity_n.unwrap_or(0),
                task: task.clone(),
                title,
                fields: vec!["status".into()],
                by: "user".into(),
                note: None,
                says: Some("close rejected".into()),
            },
            now,
        )?;
    }
    Ok(true)
}

/// `cards/settle`: an access or a close card as above (the choice checked first, the backend's connection held to
/// refusing and rejecting), any other card settled as it is.
pub async fn settle(
    w: &Writer,
    caller: &Caller,
    card: i64,
    choice: String,
    now: f64,
) -> Result<Value, Error> {
    let backend = caller.backend;
    let refusal: Arc<Mutex<Option<Error>>> = Arc::default();
    let theirs = refusal.clone();
    let r = w
        .write(caller, "cards/settle", move |tx| {
            let kind: Option<String> =
                opt(tx
                    .sql()
                    .query_row("select kind from card where id = ?1", [card], |r| {
                        r.get::<_, Option<String>>(0)
                    }))?
                .flatten();
            let checked = match kind.as_deref() {
                Some("access") => check_access(&choice, backend),
                Some("close") => check_close(&choice, backend),
                _ => Ok(()),
            };
            if let Err(e) = checked {
                *lock(&theirs) = Some(e);
                return Err(refused(UNDONE));
            }
            match kind.as_deref() {
                Some("access") => settle_access(tx, card, &choice, now),
                Some("close") => settle_close(tx, card, &choice, now),
                _ => cards::card_settle(tx, card, &choice, now),
            }
        })
        .await;
    match r {
        Ok(settled) => Ok(json!(Settled { settled })),
        Err(e) => Err(lock(&refusal).take().unwrap_or_else(|| coord::fail(e))),
    }
}

// ----------------------------------------------------------------------------------------------------- copies

/// Whether E may leave the store or come in: its record passes the personal-notes deny-list (an unknown source form
/// does not).
fn allowed(deny: &DenyList, e: &Ent) -> bool {
    let src = match &e.source {
        None => Some(Source::Recorded),
        Some(s) => Source::parse(s),
    };
    src.is_some_and(|s| {
        !matches!(
            deny.check_record(&s, &e.id, &e.data),
            Verdict::Denied { .. }
        )
    })
}

fn port(r: export::Report) -> Value {
    json!(api::PortAnswer {
        dir: show(&r.dir),
        entities: r.entities,
        links: r.links,
        txs: r.txs,
        skipped: r.skipped,
        refused: r.refused,
        error: r.error,
    })
}

/// `graph/export`.
async fn export_of(w: &Writer, tools: &Coord, p: api::ExportParams) -> Result<Value, Error> {
    let (g, deny) = store(tools)?;
    let dir = match &p.out {
        Some(o) => PathBuf::from(o.as_str()),
        None => data_dir(&g).join("export"),
    };
    let project = match p.project {
        Some(name) => {
            let name = name.into_inner();
            let shown = name.clone();
            let n = read(w, move |c| Ok(project_n(c, &name)?)).await?;
            Some(n.ok_or_else(|| invalid("project", format!("no project {shown}")))?)
        }
        None => None,
    };
    let opts = export::Opts {
        since: p.since.map(int),
        history: p.history == Some(true),
        with_activity: p.with_activity == Some(true),
    };
    let allow: export::Allow =
        Arc::new(move |e: &Ent| allowed(&deny, e) && project.is_none_or(|n| e.project == Some(n)));
    Ok(port(export::export(&g.pool, dir, opts, allow).await))
}

/// `graph/import`: never a grant.
async fn import(
    w: &Writer,
    tools: &Coord,
    caller: &Caller,
    p: api::ImportParams,
) -> Result<Value, Error> {
    if caller.backend {
        return Err(not_allowed(
            "dir",
            "an import is the user's: the backend's connection never runs one",
        ));
    }
    let (g, deny) = store(tools)?;
    let allow: export::Allow = Arc::new(move |e: &Ent| e.kind != "grant" && allowed(&deny, e));
    let r = export::import(&g.writer, PathBuf::from(p.dir.as_str()), allow).await;
    w.signals.wrote();
    Ok(port(r))
}

/// `graph/backup`: `<data>/backup/work-YYYYMMDD.db`, then the rotation.
async fn backup_now(tools: &Coord) -> Result<Value, Error> {
    let (g, _) = store(tools)?;
    let dir = data_dir(&g).join("backup");
    let day: String = crate::log::rfc3339(now() as u64)
        .chars()
        .take(10)
        .filter(char::is_ascii_digit)
        .collect();
    let r = backup::vacuum_into(&g.pool, dir.join(format!("work-{day}.db"))).await;
    let removed = if r.ok {
        backup::rotate(&dir, backup::Policy::default()).unwrap_or_else(|e| {
            tracing::warn!("cannot rotate the backups in {}: {e}", dir.display());
            Vec::new()
        })
    } else {
        Vec::new()
    };
    Ok(json!(api::BackupAnswer {
        path: show(&r.path),
        ok: r.ok,
        error: r.error,
        bytes: r.bytes,
        ms: r.ms,
        removed: removed.iter().map(|p| show(p)).collect(),
    }))
}

// ---------------------------------------------------------------------------------------------------- settings

/// Whether setting KEY is on.
fn setting_on(c: &Connection, key: &str) -> Result<bool, urdr::SqliteError> {
    let v: Option<String> =
        opt(c.query_row("select value from kv where key = ?1", [key], |r| r.get(0)))?;
    Ok(v.is_some_and(|v| {
        matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "on" | "t"
        )
    }))
}

/// Setting KEY to ON in TX: a user-class tx only (the store's `setting:` key guard refuses any other).
pub(crate) fn put_setting(tx: &mut WTx<'_>, key: &str, on: bool) -> Result<(), CoordError> {
    urdr::graph::guard::check_key(tx.guard(), tx.meta(), key)?;
    tx.sql().execute(
        "insert or replace into kv (key, value) values (?1, ?2)",
        (key, if on { "true" } else { "false" }),
    )?;
    Ok(())
}

/// `graph/settings`: the settings after a `set`, or as they are.
async fn settings(w: &Writer, caller: &Caller, p: api::SettingsParams) -> Result<Value, Error> {
    if let Some(set) = p.set {
        if caller.backend {
            return Err(not_allowed(
                "set",
                "settings are the user's: the backend's connection never writes one",
            ));
        }
        if let Some(on) = set.only_user_closes {
            w.write(caller, "graph/settings", move |tx| {
                put_setting(tx, tracker::ONLY_USER_CLOSES, on)
            })
            .await
            .map_err(coord::fail)?;
        }
    }
    let on = read(w, |c| Ok(setting_on(c, tracker::ONLY_USER_CLOSES)?)).await?;
    Ok(json!(api::Settings {
        only_user_closes: on
    }))
}

/// `graph/privacy {reload}`: the opt-ins read again and applied (`norn::privacy`, Task 9b); the new list in force
/// once applied.
async fn privacy(tools: &Coord, dirs: Option<&StoreDirs>) -> Result<Value, Error> {
    let (g, old) = store(tools)?;
    let d = dirs.ok_or_else(|| internal("the store's folders are not known yet"))?;
    let (home, config) = (d.home.clone(), d.config.clone());
    let new = tokio::task::spawn_blocking(move || DenyList::load(&home, &config))
        .await
        .map_err(|e| internal(e.to_string()))?;
    let r = norn::privacy::apply(&g.writer, &new, old.opt_ins(), new.opt_ins())
        .await
        .map_err(|t| internal(format!("graph/privacy: {t}")))?;
    *g.deny.write().unwrap_or_else(|e| e.into_inner()) = Arc::new(new);
    let paths = |v: &[PathBuf]| v.iter().map(|p| show(p)).collect::<Vec<_>>();
    Ok(json!(api::PrivacyAnswer {
        added: paths(&r.added),
        removed: paths(&r.removed),
        ignored: r.ignored,
        excised: r.excised,
        backups_holding: paths(&r.backups_holding),
    }))
}

// ------------------------------------------------------------------------------------------- tools of a session

/// A session's tool sets (call 16): the task's setting, else the profile's, else on.
pub fn tool_sets(task: Option<bool>, profile: Option<bool>) -> ToolSets {
    ToolSets {
        tracker: task.or(profile).unwrap_or(true),
    }
}

/// Task ID's `data.tracker_tools` (none when unset, or no such task, or the store cannot be read).
pub async fn task_tools(tools: &Coord, id: String) -> Option<bool> {
    tools
        .db()
        .read(move |c| {
            Ok(entity::by_id(c, &id)?
                .and_then(|e| e.data.get("tracker_tools").and_then(Value::as_bool)))
        })
        .await
        .ok()
        .flatten()
}

// --------------------------------------------------------------------------------------------- tasks for the editor

/// A task as `tasks/*` list it.
fn task_view(c: &Connection, e: &Ent, at: f64) -> Result<Value, urdr::SqliteError> {
    let project: Option<String> = match e.project {
        Some(n) => opt(c.query_row("select id from entity where n = ?1", [n], |r| r.get(0)))?,
        None => None,
    };
    let lease = e
        .lease
        .holder
        .as_ref()
        .filter(|_| e.lease.until.is_some_and(|u| u > at))
        .map(|h| json!({"holder": h, "epoch": e.lease.epoch, "until": e.lease.until}));
    Ok(json!({
        "id": e.id,
        "title": e.title,
        "status": e.status,
        "priority": e.priority,
        "assignee": e.assignee,
        "labels": e.data.get("labels"),
        "project": project,
        "ver": e.ver,
        "lease": lease,
    }))
}

/// Project NAME's `n` in a read, or a refusal.
fn named_project(c: &Connection, name: &str) -> Result<i64, CoordError> {
    project_n(c, name)?.ok_or_else(|| refused(format!("no project {name}")))
}

fn label_list(l: Option<runstav::types::Bounded<Vec<tasks_api::Label>, 16>>) -> Vec<String> {
    l.map(|v| v.iter().map(|x| x.to_string()).collect())
        .unwrap_or_default()
}

/// `tasks/ready`.
async fn tasks_ready(w: &Writer, p: tasks_api::ReadyParams) -> Result<Value, Error> {
    let labels = label_list(p.labels);
    let limit = p.limit.unwrap_or(tasks_api::PAGE);
    let project = p.project.map(|x| x.into_inner());
    let tasks = read(w, move |c| {
        let only = match &project {
            Some(name) => Some(named_project(c, name)?),
            None => None,
        };
        let at = now();
        let scope = scope::for_caller(c, &StoreCaller::user(false), at)?;
        // a project's ready tasks are a filter of everyone's
        let ask = if only.is_some() { 10_000 } else { limit };
        let mut out = Vec::new();
        for e in tracker::ready(c, &scope, &labels, ask)? {
            if only.is_some_and(|n| e.project != Some(n)) {
                continue;
            }
            out.push(task_view(c, &e, at)?);
            if out.len() >= limit as usize {
                break;
            }
        }
        Ok(out)
    })
    .await?;
    Ok(json!(tasks_api::TaskList {
        tasks,
        cursor: None
    }))
}

/// `tasks/find`.
async fn tasks_find(w: &Writer, p: tasks_api::FindParams) -> Result<Value, Error> {
    let page = tasks_api::PAGE as usize;
    let offset = usize::try_from(p.cursor.unwrap_or(0)).unwrap_or(usize::MAX);
    let words = p
        .query
        .as_ref()
        .map(|q| q.as_str().to_owned())
        .filter(|q| !q.trim().is_empty());
    let status = p.status.as_ref().map(|s| s.as_str().to_owned());
    let assignee = p.assignee.map(|a| a.into_inner());
    let labels = label_list(p.labels);
    let project = p.project.map(|x| x.into_inner());
    let list = read(w, move |c| {
        let only = match &project {
            Some(name) => Some(named_project(c, name)?),
            None => None,
        };
        let ns: Vec<i64> = match &words {
            Some(q) => search::find_fts(c, q, 1000)?
                .into_iter()
                .map(|h| h.n)
                .collect(),
            None => {
                let mut st = c.prepare(
                    "select n from entity where kind = 'task' and retired_tx is null \
                     order by coalesce(priority, 1000000), n",
                )?;
                st.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?
            }
        };
        let at = now();
        let (mut tasks, mut seen, mut more) = (Vec::new(), 0usize, false);
        for n in ns {
            let Some(e) =
                entity::by_n(c, n)?.filter(|e| e.kind == "task" && e.retired_tx.is_none())
            else {
                continue;
            };
            if status
                .as_ref()
                .is_some_and(|s| e.status.as_ref() != Some(s))
                || assignee
                    .as_ref()
                    .is_some_and(|a| e.assignee.as_ref() != Some(a))
                || only.is_some_and(|p| e.project != Some(p))
            {
                continue;
            }
            let have = e.data.get("labels").and_then(Value::as_array);
            if !labels
                .iter()
                .all(|l| have.is_some_and(|h| h.iter().any(|x| x.as_str() == Some(l.as_str()))))
            {
                continue;
            }
            seen += 1;
            if seen <= offset {
                continue;
            }
            if tasks.len() == page {
                more = true;
                break;
            }
            tasks.push(task_view(c, &e, at)?);
        }
        Ok(tasks_api::TaskList {
            tasks,
            cursor: more.then_some((offset + page) as u64),
        })
    })
    .await?;
    Ok(json!(list))
}

fn text(t: Option<runstav::types::Text>) -> Option<String> {
    t.map(|t| t.as_str().to_owned())
}

fn labels32(l: Option<runstav::types::Bounded<Vec<tasks_api::Label>, 32>>) -> Vec<String> {
    l.map(|v| v.iter().map(|x| x.to_string()).collect())
        .unwrap_or_default()
}

/// The tracker op P names (its fields checked by the registry).
fn task_op(p: tasks_api::WriteParams) -> TaskOp {
    use tasks_api::Op;
    let id = p.id.map(|x| x.into_inner()).unwrap_or_default();
    let (ver, lease) = (p.ver.unwrap_or(0), p.lease.unwrap_or(0));
    let to = p.to.map(|x| x.into_inner());
    let (src, kind, dst) = (
        p.src.map(|x| x.into_inner()).unwrap_or_default(),
        p.kind.map(|x| x.into_inner()).unwrap_or_default(),
        p.dst.map(|x| x.into_inner()).unwrap_or_default(),
    );
    match p.op {
        Op::Create => TaskOp::Create {
            title: text(p.title).unwrap_or_default(),
            body: text(p.body),
            priority: p.priority,
            labels: labels32(p.labels),
            acceptance: text(p.acceptance),
            parent: p.parent.map(|x| x.into_inner()),
        },
        Op::Update => TaskOp::Update {
            id,
            ver,
            title: text(p.title),
            body: text(p.body),
            priority: p.priority,
            acceptance: text(p.acceptance),
            status: p.status.map(|s| s.as_str().to_owned()),
        },
        Op::Claim => TaskOp::Claim { id },
        Op::Heartbeat => TaskOp::Heartbeat { id, lease },
        Op::Release => TaskOp::Release {
            id,
            lease,
            note: text(p.note),
        },
        Op::Handoff => TaskOp::Handoff {
            id,
            lease,
            to,
            note: text(p.note).unwrap_or_default(),
        },
        Op::Reassign => TaskOp::Reassign {
            id,
            ver,
            to,
            note: text(p.note).unwrap_or_default(),
        },
        Op::Split => TaskOp::Split {
            id,
            ver,
            parts: p
                .parts
                .map(|v| v.iter().map(|t| t.as_str().to_owned()).collect())
                .unwrap_or_default(),
            mode: p.mode.map(|m| {
                match m {
                    tasks_api::SplitMode::Children => "children",
                    tasks_api::SplitMode::Replace => "replace",
                }
                .to_owned()
            }),
        },
        Op::Complete => TaskOp::Complete {
            id,
            lease,
            note: text(p.note),
        },
        Op::Link => TaskOp::Link { src, kind, dst },
        Op::Unlink => TaskOp::Unlink { src, kind, dst },
        Op::Label => TaskOp::Label {
            id,
            add: labels32(p.add),
            remove: labels32(p.remove),
        },
        Op::Tools => TaskOp::Tools {
            id,
            tracker: p.tracker,
        },
    }
}

/// `tasks/write`: one tracker op as the user, in the project named or the folder's (registered when new).
async fn tasks_write(
    w: &Writer,
    caller: &Caller,
    p: tasks_api::WriteParams,
) -> Result<Value, Error> {
    if caller.backend {
        return Err(not_allowed(
            "op",
            "the tracker's user ops are the user's: the backend's connection never writes them",
        ));
    }
    let found = match (&p.project, &p.cwd) {
        (None, Some(cwd)) => {
            let dir = PathBuf::from(cwd.as_str());
            tokio::task::spawn_blocking(move || project::resolve(&dir))
                .await
                .ok()
                .flatten()
        }
        _ => None,
    };
    let name = p.project.as_ref().map(|x| x.to_string());
    let op = task_op(p);
    // a conflict or a lost lease rolls the request back (no empty tx row) and answers from here
    let kept = Arc::new(Mutex::new(None));
    let k2 = kept.clone();
    let written = w
        .write(caller, "tasks/write", move |tx| {
            let mut who = StoreCaller::user(false);
            who.project = match (&name, &found) {
                (Some(name), _) => Some(named_project(tx.sql(), name)?),
                (None, Some(p)) => Some(project::register(tx, p)?),
                (None, None) => None,
            };
            Ok(tracker::op_or_roll_back(tx, &who, op, &k2)?)
        })
        .await;
    let answer = match written {
        Ok(answer) => {
            w.signals.notify_soon();
            answer
        }
        Err(e) => match kept.lock().unwrap_or_else(PoisonError::into_inner).take() {
            Some(answer) => answer,
            None => return Err(coord::fail(e)),
        },
    };
    Ok(match answer {
        TaskAnswer::Done {
            id,
            title,
            ver,
            lease,
            parts,
        } => {
            let mut v = json!({"id": id, "title": title, "ver": ver});
            if let Some(l) = lease {
                v["lease"] = json!(l);
            }
            if !parts.is_empty() {
                v["parts"] = json!(parts);
            }
            v
        }
        other => json!(other),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use norn::store::CoordDb;
    use norn::write::cards::NewCard;
    use runstav::registry::Class;

    const DDL: &str = include_str!("../../../../test/fixtures/work-db-6.sql");
    const MINE: &str = "project:aaaaaaaaaaaa";
    const THEIRS: &str = "project:bbbbbbbbbbbb";

    fn user(backend: bool) -> Caller {
        Caller {
            class: Class::User,
            sid: None,
            job: None,
            conn_id: 1,
            backend,
        }
    }

    fn system() -> TxMeta {
        TxMeta::new("hub", TxClass::System, "test")
    }

    /// A store at schema 7 with two projects (their `n`).
    async fn fixture() -> (tempfile::TempDir, Writer, i64, i64) {
        let dir = tempfile::tempdir().unwrap();
        urdr::Connection::open(dir.path().join("work.db"))
            .unwrap()
            .execute_batch(DDL)
            .unwrap();
        let w = Writer {
            db: CoordDb::spawn(dir.path().join("work.db")),
            signals: Arc::default(),
        };
        let (a, b) =
            w.db.write(system(), |tx| {
                let p = |id: &str, root: &str, c: &str| project::ProjectRef {
                    id: id.into(),
                    root: PathBuf::from(root),
                    slug: root.trim_start_matches('/').into(),
                    root_commit: Some(c.into()),
                    roots: vec![c.into()],
                };
                Ok((
                    project::register(tx, &p(MINE, "/r1", "c1"))?,
                    project::register(tx, &p(THEIRS, "/r2", "c2"))?,
                ))
            })
            .await
            .unwrap();
        (dir, w, a, b)
    }

    async fn access_card(w: &Writer, profile: Option<&str>) -> i64 {
        let data = json!({"session": "s1", "profile": profile, "project": MINE, "target": THEIRS,
                          "reason": "r", "known": true, "choices": ["session", "project", "profile", "refuse"]});
        w.db.write(TxMeta::new("agent:s1", TxClass::Agent, "test"), move |tx| {
            cards::card_create(
                tx,
                NewCard {
                    job: None,
                    task: None,
                    kind: Some("access".into()),
                    title: Some("s1 asks to read".into()),
                    data: Some(data),
                },
                1.0,
            )
        })
        .await
        .unwrap()
    }

    async fn grants_now(w: &Writer) -> Vec<grants::Grant> {
        w.db.read(|c| {
            Ok(grants::list(
                c,
                &StoreCaller::user(false),
                &grants::Filter::default(),
                now(),
            )?)
        })
        .await
        .unwrap()
    }

    async fn count(w: &Writer, sql: &'static str) -> i64 {
        w.db.read(move |c| Ok(c.query_row(sql, [], |r| r.get(0))?))
            .await
            .unwrap()
    }

    async fn text_of(w: &Writer, sql: &'static str) -> String {
        w.db.read(move |c| Ok(c.query_row(sql, [], |r| r.get(0))?))
            .await
            .unwrap()
    }

    async fn task_write(w: &Writer, p: Value) -> Value {
        tasks_write(w, &user(false), serde_json::from_value(p).unwrap())
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn tasks_write_answers_the_new_title_and_a_conflict_commits_no_tx_row() {
        let (_dir, w, _, _) = fixture().await;
        let made = task_write(
            &w,
            json!({"op": "create", "title": "first", "project": MINE}),
        )
        .await;
        let id = made["id"].as_str().unwrap().to_owned();
        let renamed = task_write(
            &w,
            json!({"op": "update", "id": id, "ver": made["ver"], "title": "second", "project": MINE}),
        )
        .await;
        assert_eq!(renamed["title"], "second", "{renamed}");
        let txs = count(&w, "select count(*) from tx").await;
        let stale = task_write(
            &w,
            json!({"op": "update", "id": id, "ver": made["ver"], "title": "third", "project": MINE}),
        )
        .await;
        assert!(stale.get("conflict").is_some(), "{stale}");
        assert_eq!(count(&w, "select count(*) from tx").await, txs);
    }

    /// The registry's class door stops an agent's `graph/grants` first (the row `grants/an-agent-cannot-grant-itself`);
    /// this one holds without it.
    #[tokio::test]
    async fn grants_refuse_an_agent_past_the_registry() {
        let (_dir, w, _, _) = fixture().await;
        for class in [Class::Agent, Class::Service] {
            let caller = Caller {
                class,
                sid: Some("s1".into()),
                job: None,
                conn_id: 2,
                backend: false,
            };
            for p in [
                json!({"grant": {"who": "session:s1", "what": "*", "access": "read"}}),
                json!({"revoke": "grant:x"}),
            ] {
                let e = grants_of(&w, &caller, serde_json::from_value(p).unwrap())
                    .await
                    .unwrap_err();
                assert_eq!(e.code, ErrorCode::NotAllowed, "{class:?}");
            }
        }
        assert!(grants_now(&w).await.is_empty());
    }

    #[tokio::test]
    async fn access_card_settle_makes_a_grant() {
        let (_dir, w, a, b) = fixture().await;
        let card = access_card(&w, Some("p1")).await;
        let r = settle(&w, &user(false), card, "project".into(), now()).await;
        assert_eq!(r.unwrap(), json!({"settled": true}));
        let gs = grants_now(&w).await;
        assert_eq!(gs.len(), 1);
        assert_eq!(
            (&gs[0].who, &gs[0].what, gs[0].access),
            (&Who::Project(a), &What::Project(b), Access::Read)
        );
        // the requester hears it, and the card is settled once
        let heard = count(
            &w,
            "select count(*) from message where recipient = 'agent:s1'",
        )
        .await;
        assert_eq!(heard, 1);
        let again = settle(&w, &user(false), card, "project".into(), now()).await;
        assert_eq!(again.unwrap(), json!({"settled": false}));
        assert_eq!(grants_now(&w).await.len(), 1);
        // a session grant and a profile grant name the session and its profile
        let card = access_card(&w, Some("p1")).await;
        settle(&w, &user(false), card, "session".into(), now())
            .await
            .unwrap();
        let card = access_card(&w, Some("p1")).await;
        settle(&w, &user(false), card, "profile".into(), now())
            .await
            .unwrap();
        let whos: Vec<Who> = grants_now(&w).await.into_iter().map(|g| g.who).collect();
        assert!(whos.contains(&Who::Session("s1".into())), "{whos:?}");
        assert!(whos.contains(&Who::Profile("p1".into())), "{whos:?}");
        // a profile choice for a session without one is refused, the card left open
        let card = access_card(&w, None).await;
        let e = settle(&w, &user(false), card, "profile".into(), now())
            .await
            .unwrap_err();
        assert_eq!(e.code, ErrorCode::InvalidParams);
        let state: String =
            w.db.read(move |c| {
                Ok(c.query_row("select state from card where id = ?1", [card], |r| r.get(0))?)
            })
            .await
            .unwrap();
        assert_eq!(state, "open");
    }

    #[tokio::test]
    async fn an_unknown_choice_is_invalid() {
        let (_dir, w, _, _) = fixture().await;
        let card = access_card(&w, None).await;
        let e = settle(&w, &user(false), card, "maybe".into(), now())
            .await
            .unwrap_err();
        assert_eq!(
            (e.code, e.path.as_deref()),
            (ErrorCode::InvalidParams, Some("choice"))
        );
        assert!(grants_now(&w).await.is_empty());
        let open = count(&w, "select count(*) from card where state = 'open'").await;
        assert_eq!(open, 1);
    }

    #[tokio::test]
    async fn resolved_on_an_access_card_is_refuse() {
        let (_dir, w, _, _) = fixture().await;
        for choice in ["resolved", "refuse"] {
            let card = access_card(&w, Some("p1")).await;
            let r = settle(&w, &user(false), card, choice.into(), now()).await;
            assert_eq!(r.unwrap(), json!({"settled": true}), "{choice}");
        }
        assert!(grants_now(&w).await.is_empty());
        let heard = count(
            &w,
            "select count(*) from message where recipient = 'agent:s1' and text like '%refused%'",
        )
        .await;
        assert_eq!(heard, 2);
    }

    #[tokio::test]
    async fn the_backend_cannot_settle_a_grant() {
        let (_dir, w, _, _) = fixture().await;
        let card = access_card(&w, Some("p1")).await;
        for choice in GRANT_CHOICES {
            let e = settle(&w, &user(true), card, choice.into(), now())
                .await
                .unwrap_err();
            assert_eq!(e.code, ErrorCode::NotAllowed, "{choice}");
        }
        assert!(grants_now(&w).await.is_empty());
        // refusing is the backend's to do
        let r = settle(&w, &user(true), card, "refuse".into(), now()).await;
        assert_eq!(r.unwrap(), json!({"settled": true}));
        assert!(grants_now(&w).await.is_empty());
    }

    /// A user's task in project A, and a close card an agent proposed at its version: (task id, card).
    async fn close_card(w: &Writer, a: i64) -> (String, i64) {
        let id =
            w.db.write(TxMeta::new("user", TxClass::User, "test"), move |tx| {
                let mut u = StoreCaller::user(false);
                u.project = Some(a);
                match tracker::op(
                    tx,
                    &u,
                    TaskOp::Create {
                        title: "the task".into(),
                        body: None,
                        priority: None,
                        labels: Vec::new(),
                        acceptance: None,
                        parent: None,
                    },
                )? {
                    TaskAnswer::Done { id, .. } => Ok(id),
                    other => panic!("{other:?}"),
                }
            })
            .await
            .unwrap();
        let task = id.clone();
        let card =
            w.db.write(system(), move |tx| {
                let e = entity::by_id(tx.sql(), &task)?.unwrap();
                Ok(notices::close_card(
                    tx,
                    notices::Close {
                        entity: e.n,
                        task: &e.id,
                        title: "the task",
                        ver: e.ver,
                        by: "agent:s1",
                        note: None,
                    },
                    1.0,
                )?)
            })
            .await
            .unwrap();
        (id, card)
    }

    async fn status_of(w: &Writer, id: &str) -> Option<String> {
        let id = id.to_owned();
        w.db.read(move |c| Ok(entity::by_id(c, &id)?.and_then(|e| e.status)))
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn close_accept_sets_done() {
        let (_dir, w, a, _) = fixture().await;
        let (id, card) = close_card(&w, a).await;
        let e = settle(&w, &user(true), card, "accept".into(), now())
            .await
            .unwrap_err();
        assert_eq!(e.code, ErrorCode::NotAllowed, "never from the backend");
        let r = settle(&w, &user(false), card, "accept".into(), now()).await;
        assert_eq!(r.unwrap(), json!({"settled": true}));
        assert_eq!(status_of(&w, &id).await.as_deref(), Some("done"));
        // the change is the user's
        let actor = text_of(
            &w,
            "select t.actor from entity e join tx t on t.id = e.updated_tx where e.kind = 'task'",
        )
        .await;
        assert_eq!(actor, "user");
    }

    #[tokio::test]
    async fn close_accept_on_a_changed_task_conflicts() {
        let (_dir, w, a, _) = fixture().await;
        let (id, card) = close_card(&w, a).await;
        let task = id.clone();
        w.db.write(TxMeta::new("user", TxClass::User, "test"), move |tx| {
            let e = entity::by_id(tx.sql(), &task)?.unwrap();
            Ok(tracker::op(
                tx,
                &StoreCaller::user(false),
                TaskOp::Update {
                    id: task.clone(),
                    ver: e.ver,
                    title: Some("renamed".into()),
                    body: None,
                    priority: None,
                    acceptance: None,
                    status: None,
                },
            )?)
        })
        .await
        .unwrap();
        let e = settle(&w, &user(false), card, "accept".into(), now())
            .await
            .unwrap_err();
        assert_eq!(e.code, ErrorCode::InvalidParams);
        assert!(e.message.starts_with("conflict"), "{}", e.message);
        assert_ne!(status_of(&w, &id).await.as_deref(), Some("done"));
        let state: String =
            w.db.read(move |c| {
                Ok(c.query_row("select state from card where id = ?1", [card], |r| r.get(0))?)
            })
            .await
            .unwrap();
        assert_eq!(state, "open", "the card stays open");
    }

    #[tokio::test]
    async fn close_reject_notifies() {
        let (_dir, w, a, _) = fixture().await;
        let (id, card) = close_card(&w, a).await;
        let before = count(
            &w,
            "select count(*) from message where recipient = 'agent:s1'",
        )
        .await;
        let r = settle(&w, &user(true), card, "reject".into(), now()).await;
        assert_eq!(
            r.unwrap(),
            json!({"settled": true}),
            "rejecting is the backend's too"
        );
        assert_ne!(status_of(&w, &id).await.as_deref(), Some("done"));
        let after = count(
            &w,
            "select count(*) from message where recipient = 'agent:s1'",
        )
        .await;
        assert_eq!(after, before + 1);
        let text = text_of(
            &w,
            "select text from message where recipient = 'agent:s1' order by id desc limit 1",
        )
        .await;
        assert!(text.contains("close rejected"), "{text}");
    }

    #[tokio::test]
    async fn settings_are_user_only() {
        let (_dir, w, _, _) = fixture().await;
        let set = |on| api::SettingsParams {
            get: None,
            set: Some(api::SettingsSet {
                only_user_closes: Some(on),
            }),
        };
        let e = settings(&w, &user(true), set(true)).await.unwrap_err();
        assert_eq!(e.code, ErrorCode::NotAllowed);
        assert_eq!(
            settings(&w, &user(false), set(true)).await.unwrap(),
            json!({"only_user_closes": true})
        );
        // any other class is refused by the store itself
        for meta in [
            TxMeta::new("agent:s1", TxClass::Agent, "test"),
            TxMeta::new("backend", TxClass::System, "test"),
        ] {
            let r =
                w.db.write(meta, |tx| put_setting(tx, tracker::ONLY_USER_CLOSES, false))
                    .await;
            assert_eq!(
                r,
                Err(CoordError::Refused(grants::SETTINGS_ARE_THE_USERS.into()))
            );
        }
        let get = api::SettingsParams {
            get: Some(runstav::methods::Empty::default()),
            set: None,
        };
        assert_eq!(
            settings(&w, &user(false), get).await.unwrap(),
            json!({"only_user_closes": true})
        );
    }

    #[test]
    fn tools_resolution_task_then_profile_then_on() {
        for (task, profile, on) in [
            (None, None, true),
            (None, Some(false), false),
            (None, Some(true), true),
            (Some(true), Some(false), true),
            (Some(false), Some(true), false),
            (Some(false), None, false),
        ] {
            assert_eq!(
                tool_sets(task, profile),
                ToolSets { tracker: on },
                "{task:?} {profile:?}"
            );
        }
    }
}
