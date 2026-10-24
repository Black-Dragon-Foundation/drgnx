//! Records (Tasks 14, 14b; `docs/develop/records.md`): the importer (a backup of every file first, then `saga`'s
//! graph operations with `Origin::Imported`) and the views — written atomically at the imported file's path after
//! every change of the records they show (debounced 2 s), never committed, never over a hand edit: a changed view
//! becomes a proposal (`records/proposals`, `records/decide`) and is not rewritten while one is open.

use crate::coord::fail;
use crate::dispatch::Caller;
use crate::front::Front;
use norn::store::CoordDb;
use runstav::methods::records::{
    ByPath, DecideParams, Decided, ImportParams, ImportReport, ImportedFile, Proposal,
    ProposalStatus, Proposals, ProposedOp, RecordKind, ViewProposal, ViewStatus, ViewWritten,
    Views as ViewsAnswer,
};
use runstav::wire::{Error, ErrorCode};
use saga::import::{self, AnyDoc, GraphOp};
use saga::view::{self, ViewModel};
use saga::{proposal, status};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use urdr::graph::entity::{self, Changes, EntityNew, Origin};
use urdr::graph::{Class, TxMeta};

/// The quiet time after the last change of a view's records before the file is rewritten.
pub const DEBOUNCE: Duration = Duration::from_secs(2);

/// What a flush of one view did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Flush {
    /// The file was written; its hash.
    Written(String),
    /// The file already had the graph's text.
    Unchanged,
    /// An open proposal holds the view: it is not rewritten until the proposal is decided.
    Held,
    /// The file was changed by hand: its edit became (or replaced) the proposal with this id, and the file stays.
    Proposed(String),
}

#[derive(Default)]
struct State {
    /// Path -> (hash of the text the hub last wrote, when).
    written: HashMap<PathBuf, (String, f64)>,
    /// Path -> the pieces and versions the hub last wrote: what a hand edit was made against.
    bases: HashMap<PathBuf, (ViewModel, Vec<i64>)>,
    timers: HashMap<PathBuf, tokio::task::JoinHandle<()>>,
}

/// The views written and their hashes (the open proposals arrive with Task 14b).  Cheap to clone.
#[derive(Default, Clone)]
pub struct Views {
    state: Arc<Mutex<State>>,
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

fn err(msg: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: msg.into(),
        path: None,
    }
}

fn meta() -> TxMeta {
    TxMeta::new("hub", Class::System, "records")
}

fn lock(m: &Mutex<State>) -> MutexGuard<'_, State> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn kind_name(k: RecordKind) -> String {
    serde_json::to_value(k)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default()
}

fn kind_of(name: &str) -> Option<RecordKind> {
    serde_json::from_value(json!(name)).ok()
}

/// A record file found under the org folder.
struct Found {
    path: PathBuf,
    kind: RecordKind,
    parse: &'static str,
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, out);
        } else if p.extension().is_some_and(|x| x == "md") {
            out.push(p);
        }
    }
}

/// The record files of ROOT: plans and ledgers under `docs/plans/`, `DEFERRED.md`, `BUILD-BOARD.md`; `board.org`
/// only when ONLY names it.
fn discover(root: &Path, only: Option<RecordKind>) -> Vec<Found> {
    let mut md = Vec::new();
    walk(&root.join("docs/plans"), &mut md);
    md.sort();
    let mut out = Vec::new();
    for p in md {
        let ledger = p.to_string_lossy().ends_with(".ledger.md");
        out.push(if ledger {
            Found {
                path: p,
                kind: RecordKind::Ledgers,
                parse: "ledger",
            }
        } else {
            Found {
                path: p,
                kind: RecordKind::Plans,
                parse: "plan",
            }
        });
    }
    for (name, kind, parse) in [
        ("DEFERRED.md", RecordKind::Deferred, "deferred"),
        ("BUILD-BOARD.md", RecordKind::BuildBoard, "board-md"),
        ("board.org", RecordKind::Board, "org"),
    ] {
        let p = root.join(name);
        if p.is_file() && (kind != RecordKind::Board || only == Some(RecordKind::Board)) {
            out.push(Found {
                path: p,
                kind,
                parse,
            });
        }
    }
    out.retain(|f| only.is_none_or(|o| o == f.kind));
    out
}

fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

fn today(at: f64) -> String {
    let (y, m, d) = civil((at / 86_400.0).floor() as i64);
    format!("{y:04}-{m:02}-{d:02}")
}

/// Copy every file in FOUND to a new `<hub>/records-backup/<date>[-n]/` (the path relative to ROOT kept).
fn backup(hub: &Path, root: &Path, found: &[Found], at: f64) -> Result<PathBuf, Error> {
    let base = hub.join("records-backup");
    let date = today(at);
    let mut dir = base.join(&date);
    let mut n = 1;
    while dir.exists() {
        n += 1;
        dir = base.join(format!("{date}-{n}"));
    }
    for f in found {
        let rel = f.path.strip_prefix(root).unwrap_or(&f.path);
        let to = dir.join(rel);
        if let Some(parent) = to.parent() {
            std::fs::create_dir_all(parent).map_err(|e| err(format!("backup: {e}")))?;
        }
        std::fs::copy(&f.path, &to)
            .map_err(|e| err(format!("backup of {}: {e}", rel.display())))?;
    }
    Ok(dir)
}

/// A piece's entity data.
fn data_of(op: &GraphOp, file: &Path, kind: RecordKind) -> Value {
    let mut r = json!({"seq": op.seq, "role": op.role});
    if op.seq == 0 {
        r["file"] = json!(file.to_string_lossy());
        r["kind"] = json!(kind_name(kind));
    }
    let mut d = json!({"records": r});
    if let Some(t) = &op.task {
        d["number"] = json!(t.number);
        d["steps"] = json!(
            t.steps
                .iter()
                .map(|(done, text)| json!({"done": done, "text": text}))
                .collect::<Vec<_>>()
        );
        for (k, v) in [
            ("role", &t.role),
            ("model", &t.model),
            ("interfaces", &t.interfaces),
        ] {
            if let Some(v) = v {
                d[k] = json!(v);
            }
        }
    }
    if let Some(repo) = &op.repo {
        let dir = file.parent().unwrap_or(Path::new("/"));
        d["repo"] = json!(dir.join(repo).to_string_lossy());
    }
    d
}

/// A plan's structure: its tasks are under its head (`parent_of`), and a task waits on the tasks it `Depends:` on
/// (`blocks`, dependency to task).  Links already there are left as they are.
fn link_structure(
    tx: &mut norn::store::WTx<'_>,
    ops: &[GraphOp],
) -> Result<(), norn::store::CoordError> {
    let live =
        |tx: &norn::store::WTx<'_>, id: &str| -> Result<Option<i64>, norn::store::CoordError> {
            Ok(entity::by_id(tx.sql(), id)?
                .filter(|e| e.retired_tx.is_none())
                .map(|e| e.n))
        };
    for op in ops {
        let Some(t) = &op.task else { continue };
        let Some(me) = live(tx, &op.id)? else {
            continue;
        };
        if let Some(p) = op.parent.and_then(|p| ops.iter().find(|o| o.seq == p))
            && let Some(parent) = live(tx, &p.id)?
        {
            urdr::graph::link::add(
                tx,
                parent,
                "parent_of",
                me,
                None,
                Origin::Imported,
                Some(&op.source),
            )?;
        }
        for dep in &t.deps {
            let found = ops
                .iter()
                .find(|o| o.task.as_ref().is_some_and(|d| &d.number == dep));
            if let Some(d) = found
                && let Some(dep_n) = live(tx, &d.id)?
            {
                urdr::graph::link::add(
                    tx,
                    dep_n,
                    "blocks",
                    me,
                    None,
                    Origin::Imported,
                    Some(&op.source),
                )?;
            }
        }
    }
    Ok(())
}

enum Act {
    Create(usize),
    Update(i64, usize),
    Retire(i64),
}

/// What it takes to make the graph hold OPS (with DATA per op): read-only, so a dry run and an import share it.
fn diff(
    conn: &urdr::Connection,
    ops: &[GraphOp],
    data: &[Value],
) -> Result<Vec<Act>, urdr::SqliteError> {
    let mut acts = Vec::new();
    for (i, op) in ops.iter().enumerate() {
        match entity::by_id(conn, &op.id)? {
            None => acts.push(Act::Create(i)),
            Some(e) if e.retired_tx.is_some() => {}
            Some(e) => {
                let same = e.title == op.title
                    && e.status == op.status
                    && e.body.as_deref() == Some(op.body.as_str())
                    && e.data == data[i];
                if !same {
                    acts.push(Act::Update(e.n, i));
                }
            }
        }
    }
    if let Some(first) = ops.first() {
        let mut st =
            conn.prepare("select n, id from entity where source = ?1 and retired_tx is null")?;
        let rows = st.query_map([&first.source], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (n, id) = row?;
            if !ops.iter().any(|o| o.id == id) {
                acts.push(Act::Retire(n));
            }
        }
    }
    Ok(acts)
}

fn changes_of(op: &GraphOp, data: &Value) -> Changes {
    Changes {
        title: Some(op.title.clone()),
        status: Some(op.status.clone()),
        body: Some(Some(op.body.clone())),
        data_patch: Some(data.clone()),
        ..Default::default()
    }
}

/// Count ACTS, and carry them out when TX is given.
fn apply_acts(
    acts: Vec<Act>,
    ops: &[GraphOp],
    data: &[Value],
    mut tx: Option<&mut norn::store::WTx<'_>>,
) -> Result<(u64, u64), norn::store::CoordError> {
    let (mut ents, mut n_ops) = (0, 0);
    for a in acts {
        n_ops += 1;
        match a {
            Act::Create(i) => {
                ents += 1;
                if let Some(tx) = tx.as_deref_mut() {
                    let op = &ops[i];
                    entity::create(
                        tx,
                        EntityNew {
                            id: op.id.clone(),
                            kind: op.kind.into(),
                            project: None,
                            title: op.title.clone(),
                            status: op.status.clone(),
                            body: Some(op.body.clone()),
                            priority: None,
                            assignee: None,
                            data: data[i].clone(),
                            origin: Origin::Imported,
                            source: Some(op.source.clone()),
                        },
                    )?;
                }
            }
            Act::Update(n, i) => {
                ents += 1;
                if let Some(tx) = tx.as_deref_mut() {
                    entity::update(tx, n, None, changes_of(&ops[i], &data[i]))?;
                }
            }
            Act::Retire(n) => {
                if let Some(tx) = tx.as_deref_mut() {
                    entity::retire(tx, n)?;
                }
            }
        }
    }
    Ok((ents, n_ops))
}

/// Read, parse and diff one file; apply the diff unless DRY.  Answers the report row.
async fn import_one(db: &CoordDb, f: &Found, dry: bool) -> Result<ImportedFile, Error> {
    let text =
        std::fs::read_to_string(&f.path).map_err(|e| err(format!("{}: {e}", f.path.display())))?;
    let doc: AnyDoc = import::parse(f.parse, view::strip_header(&text))
        .ok_or_else(|| err("unknown record kind"))?;
    let ops = import::ops(&doc, &f.path);
    let data: Vec<Value> = ops.iter().map(|o| data_of(o, &f.path, f.kind)).collect();
    let root = ops.first().map(|o| o.id.clone());
    let (ops, data) = (Arc::new(ops), Arc::new(data));
    let source = f.path.to_string_lossy().into_owned();
    // read first: a write with nothing to do would still add a `tx` row
    let (r_ops, r_data) = (ops.clone(), data.clone());
    let (entities, n_ops) = db
        .read(move |c| {
            let acts = diff(c, &r_ops, &r_data)?;
            apply_acts(acts, &r_ops, &r_data, None)
        })
        .await
        .map_err(fail)?;
    let (entities, n_ops) = if dry || n_ops == 0 {
        (entities, n_ops)
    } else {
        db.write(meta(), move |tx| {
            let acts = diff(tx.sql(), &ops, &data)?;
            let done = apply_acts(acts, &ops, &data, Some(&mut *tx))?;
            link_structure(tx, &ops)?;
            Ok(done)
        })
        .await
        .map_err(fail)?
    };
    Ok(ImportedFile {
        path: source,
        kind: f.kind,
        entity: root,
        entities,
        ops: n_ops,
    })
}

/// A graph piece of a view.
struct Piece {
    n: i64,
    id: String,
    kind: String,
    role: String,
    status: Option<String>,
    body: String,
    ver: i64,
    updated: i64,
    data: Value,
}

/// The pieces of the file at PATH from the graph, in order.
async fn pieces(db: &CoordDb, path: &Path) -> Result<Vec<Piece>, Error> {
    let key = import::source_key(path);
    db.read(move |c| {
        let mut st = c.prepare(
            "select n, id, kind, status, coalesce(body, ''), data, ver, updated_tx from entity \
             where source = ?1 and retired_tx is null order by json_extract(data, '$.records.seq')",
        )?;
        let rows = st
            .query_map([&key], |r| {
                let data: String = r.get(5)?;
                let data: Value = serde_json::from_str(&data).unwrap_or_default();
                Ok(Piece {
                    n: r.get(0)?,
                    id: r.get(1)?,
                    kind: r.get(2)?,
                    role: data["records"]["role"].as_str().unwrap_or("").to_owned(),
                    status: r.get(3)?,
                    body: r.get(4)?,
                    ver: r.get(6)?,
                    updated: r.get(7)?,
                    data,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    })
    .await
    .map_err(fail)
}

/// The pieces of the file at PATH from the graph, in order: its kind, its head entity and the model.
async fn model(
    db: &CoordDb,
    path: &Path,
) -> Result<Option<(RecordKind, String, ViewModel)>, Error> {
    Ok(model_full(db, path).await?.map(|(k, r, m, _)| (k, r, m)))
}

/// [`model`] with each piece's version.
async fn model_full(
    db: &CoordDb,
    path: &Path,
) -> Result<Option<(RecordKind, String, ViewModel, Vec<i64>)>, Error> {
    let ps = pieces(db, path).await?;
    let Some(first) = ps.first() else {
        return Ok(None);
    };
    let Some(kind) = first.data["records"]["kind"].as_str().and_then(kind_of) else {
        return Ok(None);
    };
    let root = first.id.clone();
    let m = ViewModel {
        version: ps.iter().map(|p| p.updated).max().unwrap_or(0).max(0) as u64,
        parts: ps.iter().map(|p| p.body.clone()).collect(),
        ids: ps.iter().map(|p| p.id.clone()).collect(),
        kinds: ps.iter().map(|p| p.kind.clone()).collect(),
        roles: ps.iter().map(|p| p.role.clone()).collect(),
    };
    let vers = ps.iter().map(|p| p.ver).collect();
    Ok(Some((kind, root, m, vers)))
}

/// Graph statuses written into the text of their pieces (a graph-only change reaches the view): true when a body
/// changed.
async fn sync_bodies(db: &CoordDb, path: &Path) -> Result<bool, Error> {
    let mut ups = Vec::new();
    for p in pieces(db, path).await? {
        if let Some(want) = &p.status
            && let Some(b) = status::with_status(&p.kind, &p.role, &p.body, want)
            && b != p.body
        {
            ups.push((p.n, b));
        }
    }
    if ups.is_empty() {
        return Ok(false);
    }
    db.write(meta(), move |tx| {
        for (n, b) in ups {
            entity::update(
                tx,
                n,
                None,
                Changes {
                    body: Some(Some(b)),
                    ..Default::default()
                },
            )?;
        }
        Ok(())
    })
    .await
    .map_err(fail)?;
    Ok(true)
}

/// TEXT to PATH: a temporary file beside it, then a rename.
pub fn write_atomic(path: &Path, text: &str) -> std::io::Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".drgnx-tmp");
    let tmp = PathBuf::from(tmp);
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path)
}

/// What a view's follower tells the editors.
#[derive(Debug, Clone, PartialEq)]
pub enum ViewEvent {
    Written(ViewWritten),
    Proposal(ViewProposal),
}

impl ViewEvent {
    /// The event's name and body, as broadcast.
    pub fn parts(&self) -> (&'static str, Value) {
        match self {
            ViewEvent::Written(w) => ("view-written", serde_json::to_value(w).unwrap_or_default()),
            ViewEvent::Proposal(p) => {
                ("view-proposal", serde_json::to_value(p).unwrap_or_default())
            }
        }
    }
}

/// The id of the proposal on the view at PATH (one per view: a second edit replaces it).
fn proposal_id(path: &Path) -> String {
    format!("proposal:{}", import::source_key(path).replace(':', "-"))
}

fn state_status(state: &str) -> &'static str {
    match state {
        "accepted" => "done",
        "rejected" => "dropped",
        "stale" => "blocked",
        _ => "open",
    }
}

/// The proposal entity ID's data, with its entity number.
async fn load_proposal(db: &CoordDb, id: &str) -> Result<Option<(i64, Value)>, Error> {
    let id = id.to_owned();
    db.read(move |c| {
        Ok(entity::by_id(c, &id)?
            .filter(|e| e.kind == "proposal")
            .map(|e| (e.n, e.data)))
    })
    .await
    .map_err(fail)
}

/// A new copy of TEXT (a rejected edit of the view at PATH) in a new folder of the records backup.
fn backup_text(hub: &Path, path: &Path, text: &str, at: f64) -> Result<PathBuf, Error> {
    let base = hub.join("records-backup");
    let date = today(at);
    let mut dir = base.join(format!("{date}-rejected"));
    let mut n = 1;
    while dir.exists() {
        n += 1;
        dir = base.join(format!("{date}-rejected-{n}"));
    }
    let rel: PathBuf = path
        .components()
        .filter(|c| matches!(c, std::path::Component::Normal(_)))
        .collect();
    let to = dir.join(rel);
    if let Some(parent) = to.parent() {
        std::fs::create_dir_all(parent).map_err(|e| err(format!("backup: {e}")))?;
    }
    std::fs::write(&to, text).map_err(|e| err(format!("backup of {}: {e}", path.display())))?;
    Ok(dir)
}

fn proposal_of(id: &str, status: Option<&str>, data: &Value, diff: &str) -> Proposal {
    let state = match data["state"].as_str().or(status).unwrap_or("open") {
        "accepted" => ProposalStatus::Accepted,
        "rejected" => ProposalStatus::Rejected,
        "stale" => ProposalStatus::Stale,
        _ => ProposalStatus::Open,
    };
    let strs = |v: &Value| -> Vec<String> {
        v.as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default()
    };
    let ops = data["ops"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|o| ProposedOp {
                    op: "update".into(),
                    entity: o["entity"].as_str().unwrap_or("").to_owned(),
                    fields: strs(&o["fields"]),
                    user_only: o["user_only"].as_bool().filter(|b| *b),
                })
                .collect()
        })
        .unwrap_or_default();
    let unmapped = data["unmapped"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|r| Some((r[0].as_u64()?, r[1].as_u64()?)))
                .collect()
        })
        .unwrap_or_default();
    Proposal {
        id: id.to_owned(),
        path: data["path"].as_str().unwrap_or("").to_owned(),
        status: state,
        diff: diff.to_owned(),
        ops,
        unmapped,
        base_version: data["base_version"].as_u64().unwrap_or(0),
        by: data["by"].as_str().map(str::to_owned),
        at: data["at"].as_f64().unwrap_or(0.0),
    }
}

/// The proposals (those on the view at ONLY, or all), newest first.
pub async fn proposals_core(db: &CoordDb, only: Option<&Path>) -> Result<Proposals, Error> {
    let rows: Vec<(String, Option<String>, String, Option<String>)> = db
        .read(|c| {
            let mut st = c.prepare(
                "select id, status, data, body from entity where kind = 'proposal' and retired_tx is null \
                 order by updated_tx desc",
            )?;
            Ok(st
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
                .collect::<Result<Vec<_>, _>>()?)
        })
        .await
        .map_err(fail)?;
    let mut out = Vec::new();
    for (id, status, data, body) in rows {
        let data: Value = serde_json::from_str(&data).unwrap_or_default();
        if only.is_some_and(|o| data["path"].as_str().map(Path::new) != Some(o)) {
            continue;
        }
        out.push(proposal_of(
            &id,
            status.as_deref(),
            &data,
            body.as_deref().unwrap_or(""),
        ));
    }
    Ok(Proposals { proposals: out })
}

/// What a decision came to.
pub struct Outcome {
    pub decided: Decided,
    /// The view's path, when the decision rewrote it.
    pub path: Option<PathBuf>,
}

fn refuse(msg: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::NotAllowed,
        message: msg.into(),
        path: None,
    }
}

/// Decide proposal ID: ACCEPT applies its ops (all or none; `stale` when a record changed since the edit was read),
/// else the edited text is backed up under HUB; then the view is rewritten.  MANAGER: a manager decides (it cannot
/// accept an op on a user-only field).
pub async fn decide_core(
    db: &CoordDb,
    views: &Views,
    hub: &Path,
    id: &str,
    accept: bool,
    manager: bool,
) -> Result<(Decided, Vec<ViewEvent>), Error> {
    let Some((pn, data)) = load_proposal(db, id).await? else {
        return Err(err(format!("no proposal {id}")));
    };
    match data["state"].as_str().unwrap_or("open") {
        "open" => {}
        "stale" => {
            return Err(err(
                "stale: the file changed since it was read; read it again",
            ));
        }
        s => return Err(err(format!("proposal {id} is already {s}"))),
    }
    let path = PathBuf::from(data["path"].as_str().unwrap_or(""));
    let by = if manager { "manager" } else { "user" };
    let (state, note, backup_dir) = if accept {
        if manager
            && data["ops"]
                .as_array()
                .is_some_and(|a| a.iter().any(|o| o["user_only"].as_bool() == Some(true)))
        {
            return Err(refuse(
                "the proposal changes a field only the user may set; the user decides it",
            ));
        }
        let ops = data["ops"].as_array().cloned().unwrap_or_default();
        let base: HashMap<String, i64> = data["base"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|p| Some((p[0].as_str()?.to_owned(), p[1].as_i64()?)))
                    .collect()
            })
            .unwrap_or_default();
        let note_body = (!data["unmapped"].as_array().is_none_or(Vec::is_empty)).then(|| {
            format!(
                "Parts of a hand edit to {} that map to no change of the graph:\n\n{}",
                path.display(),
                data["diff"].as_str().unwrap_or("")
            )
        });
        let (pid, note_id) = (
            id.to_owned(),
            format!("note:{}-unmapped", id.replace(':', "-")),
        );
        let root = path.clone();
        let applied = db
            .write(meta(), move |tx| {
                let stale = ops.iter().any(|o| {
                    let id = o["entity"].as_str().unwrap_or("");
                    match entity::by_id(tx.sql(), id) {
                        Ok(Some(e)) => e.retired_tx.is_some() || base.get(id) != Some(&e.ver),
                        _ => true,
                    }
                });
                let (state, note) = if stale {
                    ("stale", None)
                } else {
                    for o in &ops {
                        let e = entity::by_id(tx.sql(), o["entity"].as_str().unwrap_or(""))?
                            .ok_or_else(|| {
                                norn::store::CoordError::Refused("no such record".into())
                            })?;
                        entity::update(
                            tx,
                            e.n,
                            Some(e.ver),
                            Changes {
                                body: Some(Some(o["body"].as_str().unwrap_or("").to_owned())),
                                status: o["status"].as_str().map(|s| Some(s.to_owned())),
                                ..Default::default()
                            },
                        )?;
                    }
                    let mut made = None;
                    if let Some(b) = note_body {
                        let n = match entity::by_id(tx.sql(), &note_id)? {
                            Some(e) => {
                                entity::update(
                                    tx,
                                    e.n,
                                    None,
                                    Changes {
                                        body: Some(Some(b)),
                                        ..Default::default()
                                    },
                                )?;
                                e.n
                            }
                            None => {
                                entity::create(
                                    tx,
                                    EntityNew {
                                        id: note_id.clone(),
                                        kind: "note".into(),
                                        project: None,
                                        title: Some(format!("Unmapped edit of {}", root.display())),
                                        status: Some("open".into()),
                                        body: Some(b),
                                        priority: None,
                                        assignee: None,
                                        data: json!({}),
                                        origin: Origin::Inferred,
                                        source: None,
                                    },
                                )?
                                .n
                            }
                        };
                        if let Some(r) = ops.first().and_then(|o| o["entity"].as_str())
                            && let Some(re) = entity::by_id(tx.sql(), r)?
                        {
                            urdr::graph::link::add(
                                tx,
                                n,
                                "relates",
                                re.n,
                                None,
                                Origin::Inferred,
                                None,
                            )?;
                        }
                        made = Some(note_id.clone());
                    }
                    ("accepted", made)
                };
                set_state(tx, &pid, pn, state, by)?;
                Ok((state, note))
            })
            .await
            .map_err(fail)?;
        (applied.0, applied.1, None)
    } else {
        let edited = data["edited"].as_str().unwrap_or("");
        let dir = backup_text(hub, &path, edited, now())?;
        let pid = id.to_owned();
        db.write(meta(), move |tx| set_state(tx, &pid, pn, "rejected", by))
            .await
            .map_err(fail)?;
        ("rejected", None, Some(dir))
    };
    let mut events = Vec::new();
    if state != "stale"
        && let Flush::Written(hash) = views.flush(db, &path, true).await?
        && let Some((kind, _, _)) = model(db, &path).await?
    {
        events.push(ViewEvent::Written(ViewWritten {
            path: path.to_string_lossy().into_owned(),
            kind,
            hash,
        }));
    }
    let status = match state {
        "accepted" => ProposalStatus::Accepted,
        "rejected" => ProposalStatus::Rejected,
        _ => ProposalStatus::Stale,
    };
    Ok((
        Decided {
            id: id.to_owned(),
            status,
            note,
            backup: backup_dir.map(|d| d.to_string_lossy().into_owned()),
        },
        events,
    ))
}

/// Proposal PID (entity PN) in STATE, decided BY.
fn set_state(
    tx: &mut norn::store::WTx<'_>,
    _pid: &str,
    pn: i64,
    state: &str,
    by: &str,
) -> Result<(), norn::store::CoordError> {
    entity::update(
        tx,
        pn,
        None,
        Changes {
            status: Some(Some(state_status(state).into())),
            data_patch: Some(json!({"state": state, "decided_by": by, "decided_at": now()})),
            ..Default::default()
        },
    )?;
    Ok(())
}

impl Views {
    /// The file at PATH differs from what the hub last wrote there (false when the hub wrote nothing yet).
    pub fn changed(&self, path: &Path) -> bool {
        let last = lock(&self.state).written.get(path).map(|w| w.0.clone());
        match (last, std::fs::read_to_string(path)) {
            (Some(h), Ok(t)) => view::digest(&t) != h,
            (Some(_), Err(_)) => true,
            (None, _) => false,
        }
    }

    fn record(&self, path: &Path, hash: &str, base: (ViewModel, Vec<i64>)) {
        let mut st = lock(&self.state);
        st.written
            .insert(path.to_path_buf(), (hash.to_owned(), now()));
        st.bases.insert(path.to_path_buf(), base);
    }

    /// The edit EDITED of the view at PATH read into its proposal (new, or the open one replaced).  Its id.
    async fn propose(&self, db: &CoordDb, path: &Path, edited: String) -> Result<String, Error> {
        let Some((_, root, cur, cur_vers)) = model_full(db, path).await? else {
            return Err(err("no such view"));
        };
        // the edit was made against what the hub last wrote, not against the graph's changes since
        let (m, vers) = match lock(&self.state).bases.get(path).cloned() {
            Some((b, v)) if b.ids == cur.ids => (
                ViewModel {
                    version: cur.version,
                    ..b
                },
                v,
            ),
            _ => (cur, cur_vers),
        };
        let view_text = view::file_text(path, &m);
        let p = proposal::read(&view_text, &edited, &m);
        let id = proposal_id(path);
        let ops: Vec<Value> = p
            .ops
            .iter()
            .map(|o| {
                let mut fields = vec!["body"];
                if o.status.is_some() {
                    fields.push("status");
                }
                json!({
                    "op": "update", "entity": o.id, "fields": fields, "body": o.body, "status": o.status,
                    "user_only": p.user_only.contains(&o.id),
                })
            })
            .collect();
        let ids: Vec<String> = p.ops.iter().map(|o| o.id.clone()).collect();
        let data = json!({
            "path": path.to_string_lossy(), "state": "open", "ops": ops,
            "unmapped": p.unmapped.iter().map(|r| json!([r.start, r.end])).collect::<Vec<_>>(),
            "base_version": p.base_version, "edited": edited, "at": now(), "by": Value::Null,
        });
        let (diff, pid) = (p.diff, id.clone());
        let m_ids = m.ids.clone();
        let title = format!(
            "Edit of {}",
            path.file_name()
                .map_or(String::new(), |f| f.to_string_lossy().into_owned())
        );
        db.write(meta(), move |tx| {
            let mut data = data;
            let base: Vec<Value> = ids
                .iter()
                .filter_map(|i| Some(json!([i, vers.get(m_ids.iter().position(|x| x == i)?)?])))
                .collect();
            data["base"] = json!(base);
            let n = match entity::by_id(tx.sql(), &pid)? {
                None => {
                    entity::create(
                        tx,
                        EntityNew {
                            id: pid.clone(),
                            kind: "proposal".into(),
                            project: None,
                            title: Some(title),
                            status: Some("open".into()),
                            body: Some(diff),
                            priority: None,
                            assignee: None,
                            data,
                            origin: Origin::Inferred,
                            source: None,
                        },
                    )?
                    .n
                }
                Some(e) => {
                    entity::update(
                        tx,
                        e.n,
                        None,
                        Changes {
                            title: Some(Some(title)),
                            status: Some(Some("open".into())),
                            body: Some(Some(diff)),
                            data_patch: Some(data),
                            ..Default::default()
                        },
                    )?;
                    e.n
                }
            };
            if let Some(r) = entity::by_id(tx.sql(), &root)? {
                urdr::graph::link::add(tx, n, "proposes", r.n, None, Origin::Inferred, None)?;
            }
            Ok(())
        })
        .await
        .map_err(fail)?;
        Ok(id)
    }

    /// The hash the hub last wrote at PATH, from the store after a restart (`kv`, key `records-view:PATH`).
    async fn seed(&self, db: &CoordDb, path: &Path) -> Result<(), Error> {
        if lock(&self.state).written.contains_key(path) {
            return Ok(());
        }
        let key = format!("records-view:{}", path.to_string_lossy());
        let hash: Option<String> = db
            .read(move |c| {
                Ok(
                    c.query_row("select value from kv where key = ?1", [&key], |r| r.get(0))
                        .ok(),
                )
            })
            .await
            .map_err(fail)?;
        if let Some(h) = hash {
            lock(&self.state)
                .written
                .entry(path.to_path_buf())
                .or_insert((h, 0.0));
        }
        Ok(())
    }

    /// HASH, which the hub wrote at PATH, kept in the store (only when it is not the one already kept).
    async fn persist(
        &self,
        db: &CoordDb,
        path: &Path,
        prior: Option<String>,
        hash: &str,
    ) -> Result<(), Error> {
        if prior.as_deref() == Some(hash) {
            return Ok(());
        }
        let (key, hash) = (
            format!("records-view:{}", path.to_string_lossy()),
            hash.to_owned(),
        );
        db.write(meta(), move |tx| {
            tx.sql().execute(
                "insert or replace into kv (key, value) values (?1, ?2)",
                (&key, &hash),
            )?;
            Ok(())
        })
        .await
        .map_err(fail)
    }

    /// The view at PATH rewritten from the graph now (its pieces' text first follows the graph's statuses), unless
    /// the file was changed by hand or a proposal on it is open: a hand edit becomes the proposal and the file stays
    /// (FORCE: after an import or a decision, when the file was just read and backed up or decided).
    pub async fn flush(&self, db: &CoordDb, path: &Path, force: bool) -> Result<Flush, Error> {
        sync_bodies(db, path).await?;
        self.seed(db, path).await?;
        let prior = lock(&self.state).written.get(path).map(|w| w.0.clone());
        let Some((_, _, m, vers)) = model_full(db, path).await? else {
            return Ok(Flush::Unchanged);
        };
        let text = view::file_text(path, &m);
        let hash = view::digest(&text);
        let current = std::fs::read_to_string(path).ok();
        if !force
            && let Some((_, open)) = load_proposal(db, &proposal_id(path)).await?
            && open["state"].as_str() == Some("open")
        {
            return match &current {
                Some(c) if *c != text && open["edited"].as_str() != Some(c.as_str()) => {
                    Ok(Flush::Proposed(self.propose(db, path, c.clone()).await?))
                }
                _ => Ok(Flush::Held),
            };
        }
        if current.as_deref() == Some(text.as_str()) {
            self.record(path, &hash, (m, vers));
            self.persist(db, path, prior, &hash).await?;
            return Ok(Flush::Unchanged);
        }
        let known = lock(&self.state).written.contains_key(path);
        let by_hand = if known {
            self.changed(path)
        } else {
            current.is_some()
        };
        if by_hand
            && !force
            && let Some(c) = current.clone()
        {
            return Ok(Flush::Proposed(self.propose(db, path, c).await?));
        }
        // an edit that landed since the file was read is a proposal too
        if !force
            && let Some(again) = std::fs::read_to_string(path)
                .ok()
                .filter(|a| Some(a) != current.as_ref())
        {
            return Ok(Flush::Proposed(self.propose(db, path, again).await?));
        }
        write_atomic(path, &text).map_err(|e| err(format!("{}: {e}", path.display())))?;
        self.record(path, &hash, (m, vers));
        self.persist(db, path, prior, &hash).await?;
        Ok(Flush::Written(hash))
    }

    /// What a flush of PATH came to, as the event to send.
    async fn event_of(&self, db: &CoordDb, path: &Path, f: Flush) -> Option<ViewEvent> {
        match f {
            Flush::Written(hash) => {
                let (kind, _, _) = model(db, path).await.ok().flatten()?;
                Some(ViewEvent::Written(ViewWritten {
                    path: path.to_string_lossy().into_owned(),
                    kind,
                    hash,
                }))
            }
            Flush::Proposed(id) => Some(ViewEvent::Proposal(ViewProposal {
                id,
                path: path.to_string_lossy().into_owned(),
                by: None,
            })),
            _ => None,
        }
    }

    /// Every view the graph knows, flushed now: the graph's changes reach the files, hand edits become proposals.
    pub async fn flush_all(&self, db: &CoordDb) -> Result<Vec<ViewEvent>, Error> {
        let mut events = Vec::new();
        for v in status_core(db, self, None).await?.views {
            let path = PathBuf::from(&v.path);
            let f = self.flush(db, &path, false).await?;
            events.extend(self.event_of(db, &path, f).await);
        }
        Ok(events)
    }

    /// The records behind the view at PATH changed: rewrite it after [`DEBOUNCE`] of quiet.  EMIT hears each write
    /// and each new proposal.
    pub fn on_change(
        &self,
        db: CoordDb,
        path: PathBuf,
        emit: Arc<dyn Fn(ViewEvent) + Send + Sync>,
    ) {
        let me = self.clone();
        let p = path.clone();
        let h = tokio::spawn(async move {
            tokio::time::sleep(DEBOUNCE).await;
            if let Ok(f) = me.flush(&db, &p, false).await
                && let Some(e) = me.event_of(&db, &p, f).await
            {
                emit(e);
            }
        });
        if let Some(old) = lock(&self.state).timers.insert(path, h) {
            old.abort();
        }
    }
}

/// The follower: after every write of the front's methods, [`DEBOUNCE`] of quiet, then every view is flushed
/// (a graph change reaches its file; a hand edit becomes a proposal) and the editors hear of it.
pub async fn follow(front: Arc<Front>) {
    let signals = front.writer.signals.clone();
    loop {
        signals.records.notified().await;
        loop {
            tokio::select! {
                () = signals.records.notified() => {}
                () = tokio::time::sleep(DEBOUNCE) => break,
            }
        }
        match front.core.records.flush_all(&front.writer.db).await {
            Ok(events) => {
                for e in events {
                    let (name, body) = e.parts();
                    front.broadcast(name, body);
                }
            }
            Err(e) => tracing::warn!("records: {}", e.message),
        }
    }
}

/// The importer: ROOT's record files backed up (not on DRY), imported, their views written.  The events to send.
pub async fn import_core(
    db: &CoordDb,
    views: &Views,
    hub: &Path,
    root: &Path,
    only: Option<RecordKind>,
    dry: bool,
) -> Result<(ImportReport, Vec<ViewWritten>), Error> {
    let found = discover(root, only);
    let backup_dir = if dry || found.is_empty() {
        None
    } else {
        Some(backup(hub, root, &found, now())?)
    };
    let (mut files, mut events) = (Vec::new(), Vec::new());
    for f in &found {
        files.push(import_one(db, f, dry).await?);
        if !dry && let Flush::Written(hash) = views.flush(db, &f.path, true).await? {
            events.push(ViewWritten {
                path: f.path.to_string_lossy().into_owned(),
                kind: f.kind,
                hash,
            });
        }
    }
    Ok((
        ImportReport {
            dry_run: dry,
            backup: backup_dir.map(|d| d.to_string_lossy().into_owned()),
            files,
        },
        events,
    ))
}

/// The views the graph knows, and where each stands.
pub async fn status_core(
    db: &CoordDb,
    views: &Views,
    only: Option<&Path>,
) -> Result<ViewsAnswer, Error> {
    let roots: Vec<(String, String)> = db
        .read(|c| {
            let mut st = c.prepare(
                "select id, data from entity where source like 'records:%' and retired_tx is null \
                 and json_extract(data, '$.records.seq') = 0",
            )?;
            Ok(st
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<Result<Vec<_>, _>>()?)
        })
        .await
        .map_err(fail)?;
    let mut out = Vec::new();
    for (id, data) in roots {
        let d: Value = serde_json::from_str(&data).unwrap_or_default();
        let (Some(file), Some(kind)) = (
            d["records"]["file"].as_str(),
            d["records"]["kind"].as_str().and_then(kind_of),
        ) else {
            continue;
        };
        let path = PathBuf::from(file);
        if only.is_some_and(|o| o != path) {
            continue;
        }
        let last = lock(&views.state).written.get(&path).cloned();
        let changed = match &last {
            Some(_) => views.changed(&path),
            None => model(db, &path).await?.is_some_and(|(_, _, m)| {
                std::fs::read_to_string(&path).ok().as_deref()
                    != Some(view::file_text(&path, &m).as_str())
            }),
        };
        let pending = match load_proposal(db, &proposal_id(&path)).await? {
            Some((_, d)) if d["state"].as_str() == Some("open") => Some(proposal_id(&path)),
            _ => None,
        };
        out.push(ViewStatus {
            path: file.to_owned(),
            kind,
            entity: id,
            written: last.as_ref().map(|l| l.1),
            hash: last.map(|l| l.0),
            changed,
            pending,
        });
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(ViewsAnswer { views: out })
}

fn hub_dir(f: &Front) -> Result<PathBuf, Error> {
    f.dirs
        .get()
        .map(|d| d.hub.clone())
        .ok_or_else(|| err("the graph store is not open"))
}

pub async fn import(f: &Front, _: &Caller, p: ImportParams) -> Result<ImportReport, Error> {
    let hub = hub_dir(f)?;
    let (report, events) = import_core(
        &f.writer.db,
        &f.core.records,
        &hub,
        Path::new(p.root.as_str()),
        p.only,
        p.dry_run.unwrap_or(false),
    )
    .await?;
    for e in events {
        f.broadcast("view-written", serde_json::to_value(e).unwrap_or_default());
    }
    Ok(report)
}

pub async fn status(f: &Front, _: &Caller, p: ByPath) -> Result<ViewsAnswer, Error> {
    status_core(
        &f.writer.db,
        &f.core.records,
        p.path.as_ref().map(|a| Path::new(a.as_str())),
    )
    .await
}

pub async fn proposals(f: &Front, _: &Caller, p: ByPath) -> Result<Proposals, Error> {
    // a hand edit is read when somebody looks
    for e in f.core.records.flush_all(&f.writer.db).await? {
        let (name, body) = e.parts();
        f.broadcast(name, body);
    }
    proposals_core(&f.writer.db, p.path.as_ref().map(|a| Path::new(a.as_str()))).await
}

pub async fn decide(f: &Front, _: &Caller, p: DecideParams) -> Result<Decided, Error> {
    let hub = hub_dir(f)?;
    let (decided, events) = decide_core(
        &f.writer.db,
        &f.core.records,
        &hub,
        p.id.as_str(),
        p.accept,
        false,
    )
    .await?;
    for e in events {
        let (name, body) = e.parts();
        f.broadcast(name, body);
    }
    Ok(decided)
}

/// The proposal tools' door into the records ([`crate::coord::Signals::records_tool`]).
pub fn install_tool(front: &Arc<Front>) {
    let weak = Arc::downgrade(front);
    let door: crate::coord::RecordsTool = Arc::new(move |id, accept, session| {
        let weak = weak.clone();
        Box::pin(async move {
            let front = weak
                .upgrade()
                .ok_or_else(|| "the hub is stopping".to_string())?;
            tool_call(&front, id, accept, session)
                .await
                .map_err(|e| e.message)
        })
    });
    let _ = front.writer.signals.records_tool.set(door);
}

/// `proposal_read` (ACCEPT none) and `proposal_decide` of an agent: a decision needs the matrix's `graph.change`.
async fn tool_call(
    f: &Front,
    id: String,
    accept: Option<bool>,
    session: Option<String>,
) -> Result<String, Error> {
    use crate::matrix_gate::{ActionCtx, Gate};
    let db = &f.writer.db;
    let Some(accept) = accept else {
        let all = proposals_core(db, None).await?;
        let p = all
            .proposals
            .into_iter()
            .find(|p| p.id == id)
            .ok_or_else(|| err(format!("no proposal {id}")))?;
        return Ok(json!(p).to_string());
    };
    f.core.matrix.refresh(f);
    let gate = f.core.matrix.clone();
    // a session's own column is not known here: the worker column, the more restrictive of the two that may change the graph
    let who = norn::matrix::Who {
        role: Some(runstav::methods::matrix::Role::Worker),
        agent: None,
        provider: None,
    };
    let ctx = ActionCtx {
        session,
        ..Default::default()
    };
    let verdict = db
        .write(meta(), move |tx| {
            gate.check(
                tx,
                &who,
                runstav::methods::matrix::Action::GraphChange,
                &ctx,
                now(),
            )
        })
        .await
        .map_err(fail)?;
    match verdict {
        Gate::Allow => {}
        Gate::Ask(card) => {
            return Err(refuse(format!(
                "the matrix asks the user first (card {card}); decide again once it is settled"
            )));
        }
        Gate::Never(why) => return Err(refuse(why)),
    }
    let hub = hub_dir(f)?;
    let (decided, events) = decide_core(db, &f.core.records, &hub, &id, accept, true).await?;
    for e in events {
        let (name, body) = e.parts();
        f.broadcast(name, body);
    }
    Ok(json!(decided).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const FILES: [(&str, &str); 5] = [
        (
            "docs/plans/drgnx/p.md",
            include_str!("../../saga/tests/fixtures/plan-h2.md"),
        ),
        (
            "docs/plans/drgnx/p.ledger.md",
            include_str!("../../saga/tests/fixtures/ledger-a.md"),
        ),
        (
            "DEFERRED.md",
            include_str!("../../saga/tests/fixtures/deferred-a.md"),
        ),
        (
            "BUILD-BOARD.md",
            include_str!("../../saga/tests/fixtures/board-a.md"),
        ),
        (
            "board.org",
            include_str!("../../saga/tests/fixtures/board-a.org"),
        ),
    ];

    struct Fix {
        _dir: tempfile::TempDir,
        root: PathBuf,
        hub: PathBuf,
        db: CoordDb,
        views: Views,
    }

    fn fix() -> Fix {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("org");
        for (rel, text) in FILES {
            let p = root.join(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, text).unwrap();
        }
        let db = CoordDb::spawn(dir.path().join("work.db"));
        Fix {
            hub: dir.path().join("hub"),
            root,
            db,
            views: Views::default(),
            _dir: dir,
        }
    }

    impl Fix {
        async fn import(&self, only: Option<RecordKind>, dry: bool) -> ImportReport {
            import_core(&self.db, &self.views, &self.hub, &self.root, only, dry)
                .await
                .unwrap()
                .0
        }
        async fn count(&self, sql: &'static str) -> i64 {
            self.db
                .read(move |c| Ok(c.query_row(sql, [], |r| r.get(0))?))
                .await
                .unwrap()
        }
    }

    const TX: &str = "select count(*) from tx";
    const RECS: &str = "select count(*) from entity where source like 'records:%'";

    #[tokio::test]
    async fn import_then_view_equals_the_file() {
        let f = fix();
        f.import(None, false).await;
        f.import(Some(RecordKind::Board), false).await;
        for (rel, text) in FILES {
            let written = std::fs::read_to_string(f.root.join(rel)).unwrap();
            assert_ne!(written, text, "{rel}: the view carries its header");
            assert_eq!(view::strip_header(&written), text, "{rel}");
        }
    }

    #[tokio::test]
    async fn an_imported_plan_reads_with_its_tasks() {
        let f = fix();
        let rel = "docs/plans/drgnx/q.md";
        std::fs::write(
            f.root.join(rel),
            "# Q plan\n\n**Repo:** ../../..\n\n### Task 1: first\n\n**Role:** implement\n\n- [ ] **Step 1: a**\n\n\
             ### Task 2: second\n\n**Depends:** Task 1\n\n### Task 3b: third\n\n**Depends:** Task 1, Task 2\n",
        )
        .unwrap();
        f.import(Some(RecordKind::Plans), false).await;
        // the plan entity with its tasks under it, by number, and each task's waits (what plan_read and job/propose read)
        let q = "select p.id, t.data from link l join entity p on p.n = l.src join entity t on t.n = l.dst \
                 where l.kind = 'parent_of' and p.title = 'Q plan' and l.tx_to = ?1 order by l.id";
        let rows: Vec<(String, String)> =
            f.db.read(move |c| {
                let mut st = c.prepare(q)?;
                let r = st
                    .query_map([urdr::graph::schema::SENTINEL], |r| {
                        Ok((r.get(0)?, r.get(1)?))
                    })?
                    .collect::<Result<_, _>>()?;
                Ok(r)
            })
            .await
            .unwrap();
        assert_eq!(rows.len(), 3);
        let numbers: Vec<String> = rows
            .iter()
            .map(|(_, d)| {
                serde_json::from_str::<Value>(d).unwrap()["number"]
                    .as_str()
                    .unwrap()
                    .to_owned()
            })
            .collect();
        assert_eq!(numbers, ["1", "2", "3b"]);
        let deps: Vec<(String, String)> = f
            .db
            .read(|c| {
                let mut st = c.prepare(
                    "select json_extract(a.data, '$.number'), json_extract(b.data, '$.number') from link l \
                     join entity a on a.n = l.src join entity b on b.n = l.dst \
                     where l.kind = 'blocks' and l.tx_to = ?1 order by 2, 1",
                )?;
                let r = st
                    .query_map([urdr::graph::schema::SENTINEL], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<Result<_, _>>()?;
                Ok(r)
            })
            .await
            .unwrap();
        assert_eq!(
            deps,
            [
                ("1".into(), "2".into()),
                ("1".into(), "3b".into()),
                ("2".into(), "3b".into())
            ]
        );
        let repo: String =
            f.db.read(|c| {
                Ok(c.query_row(
                    "select json_extract(data, '$.repo') from entity where title = 'Q plan'",
                    [],
                    |r| r.get(0),
                )?)
            })
            .await
            .unwrap();
        assert!(repo.ends_with("docs/plans/drgnx/../../.."), "{repo}");
        // importing again links nothing twice
        let again = f.import(Some(RecordKind::Plans), false).await;
        assert!(again.files.iter().all(|x| x.ops == 0));
    }

    #[tokio::test]
    async fn import_is_idempotent() {
        let f = fix();
        let first = f.import(None, false).await;
        assert!(first.files.iter().all(|x| x.ops > 0));
        let (txs, ents) = (f.count(TX).await, f.count(RECS).await);
        let again = f.import(None, false).await;
        assert!(
            again.files.iter().all(|x| x.ops == 0 && x.entities == 0),
            "{again:?}"
        );
        assert_eq!((f.count(TX).await, f.count(RECS).await), (txs, ents));
    }

    #[tokio::test]
    async fn a_changed_view_is_never_overwritten() {
        let f = fix();
        f.import(None, false).await;
        let p = f.root.join("DEFERRED.md");
        let mine = format!("{}\nmy hand edit\n", std::fs::read_to_string(&p).unwrap());
        std::fs::write(&p, &mine).unwrap();
        assert!(f.views.changed(&p));
        // the graph changes: a row's body
        f.db.write(meta(), |tx| {
            let id = tx.sql().query_row(
                "select id from entity where kind = 'todo' limit 1",
                [],
                |r| r.get::<_, String>(0),
            )?;
            let n = entity::by_id(tx.sql(), &id)?.unwrap().n;
            entity::update(
                tx,
                n,
                None,
                Changes {
                    body: Some(Some("| X-1 | a | b | c |\n".into())),
                    ..Default::default()
                },
            )?;
            Ok(())
        })
        .await
        .unwrap();
        assert!(matches!(
            f.views.flush(&f.db, &p, false).await.unwrap(),
            Flush::Proposed(_)
        ));
        assert_eq!(std::fs::read_to_string(&p).unwrap(), mine);
        // an untouched view is rewritten
        let q = f.root.join("BUILD-BOARD.md");
        assert!(!f.views.changed(&q));
        assert!(matches!(
            f.views.flush(&f.db, &q, false).await.unwrap(),
            Flush::Unchanged
        ));
    }

    #[tokio::test]
    async fn the_backup_is_written_first() {
        let f = fix();
        let r = f.import(None, false).await;
        let b = PathBuf::from(r.backup.unwrap());
        assert!(b.starts_with(f.hub.join("records-backup")));
        for (rel, text) in FILES.iter().filter(|(r, _)| *r != "board.org") {
            assert_eq!(
                std::fs::read_to_string(b.join(rel)).unwrap(),
                *text,
                "{rel}"
            );
        }
        assert!(
            !b.join("board.org").exists(),
            "board.org is not imported unless named"
        );
        // a second import makes a second backup, never overwriting the first
        let r2 = f.import(None, false).await;
        assert_ne!(r2.backup.unwrap(), b.to_string_lossy());
    }

    #[tokio::test]
    async fn dry_run_writes_nothing() {
        let f = fix();
        let txs = f.count(TX).await;
        let r = f.import(None, true).await;
        assert!(r.dry_run && r.backup.is_none());
        assert!(r.files.iter().all(|x| x.ops > 0));
        for (rel, text) in FILES {
            assert_eq!(std::fs::read_to_string(f.root.join(rel)).unwrap(), text);
        }
        assert!(!f.hub.exists());
        assert_eq!((f.count(TX).await, f.count(RECS).await), (txs, 0));
    }

    fn git(dir: &Path, args: &[&str]) -> String {
        let out = std::process::Command::new("git")
            .args([
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "-c",
                "commit.gpgsign=false",
            ])
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {out:?}");
        String::from_utf8_lossy(&out.stdout).into_owned()
    }

    #[tokio::test]
    async fn the_hub_never_commits() {
        let f = fix();
        git(&f.root, &["init", "-q"]);
        git(&f.root, &["add", "-A"]);
        git(&f.root, &["commit", "-q", "-m", "records"]);
        let (log, index) = (
            git(&f.root, &["log", "--format=%H"]),
            std::fs::read(f.root.join(".git/index")).unwrap(),
        );
        f.import(None, false).await;
        // a changed file, imported again: the graph changes and the view is rewritten
        let p = f.root.join("DEFERRED.md");
        let t = std::fs::read_to_string(&p).unwrap();
        std::fs::write(&p, format!("{t}\nmore\n")).unwrap();
        f.import(None, false).await;
        assert_eq!(git(&f.root, &["log", "--format=%H"]), log);
        assert_eq!(std::fs::read(f.root.join(".git/index")).unwrap(), index);
    }

    // ---- Task 14b: statuses, views that follow the graph, proposals ----

    async fn imported(f: &Fix) -> PathBuf {
        f.import(None, false).await;
        f.root.join("DEFERRED.md")
    }

    /// P's text with FROM replaced by TO, written back.  Returns the new text.
    fn edit(p: &Path, from: &str, to: &str) -> String {
        let t = std::fs::read_to_string(p).unwrap();
        assert!(t.contains(from), "{from:?} not in the view");
        let n = t.replacen(from, to, 1);
        std::fs::write(p, &n).unwrap();
        n
    }

    async fn row_status(f: &Fix, like: &'static str) -> String {
        f.db.read(move |c| {
            Ok(c.query_row(
                "select status from entity where kind = 'todo' and title like ?1",
                [like],
                |r| r.get::<_, String>(0),
            )?)
        })
        .await
        .unwrap()
    }

    async fn set_row(f: &Fix, like: &'static str, ch: Changes) {
        f.db.write(meta(), move |tx| {
            let id = tx.sql().query_row(
                "select id from entity where kind = 'todo' and title like ?1",
                [like],
                |r| r.get::<_, String>(0),
            )?;
            let n = entity::by_id(tx.sql(), &id)?.unwrap().n;
            entity::update(tx, n, None, ch)?;
            Ok(())
        })
        .await
        .unwrap();
    }

    async fn the_proposal(f: &Fix) -> Proposal {
        let all = proposals_core(&f.db, None).await.unwrap().proposals;
        assert_eq!(all.len(), 1, "{all:?}");
        all.into_iter().next().unwrap()
    }

    #[tokio::test]
    async fn statuses_are_the_graphs_words() {
        let f = fix();
        f.import(None, false).await;
        let all: Vec<String> = f
            .db
            .read(|c| {
                let mut st = c.prepare(
                    "select distinct status from entity where source like 'records:%' and status is not null",
                )?;
                Ok(st
                    .query_map([], |r| r.get::<_, String>(0))?
                    .collect::<Result<Vec<_>, _>>()?)
            })
            .await
            .unwrap();
        assert!(!all.is_empty());
        for s in &all {
            assert!(status::STATUSES.contains(&s.as_str()), "{s}");
        }
        assert_eq!(row_status(&f, "M1-1%").await, "done");
        assert_eq!(row_status(&f, "M1-2%").await, "open");
        assert_eq!(row_status(&f, "M2-1%").await, "done");
    }

    #[tokio::test]
    async fn a_graph_status_change_rewrites_the_view() {
        let f = fix();
        let p = imported(&f).await;
        set_row(
            &f,
            "M2-1%",
            Changes {
                status: Some(Some("open".into())),
                ..Default::default()
            },
        )
        .await;
        assert!(matches!(
            f.views.flush(&f.db, &p, false).await.unwrap(),
            Flush::Written(_)
        ));
        let t = std::fs::read_to_string(&p).unwrap();
        assert!(t.contains("bold** text | open |"), "{t}");
        // the other rows are as they were, and the file imports back to the same graph
        assert!(t.contains("| fixed in M2 |"));
        let again = f.import(Some(RecordKind::Deferred), false).await;
        assert!(again.files.iter().all(|x| x.ops == 0), "{again:?}");
    }

    #[tokio::test]
    async fn a_status_edit_becomes_a_proposal_not_a_write() {
        let f = fix();
        let p = imported(&f).await;
        let txs = f.count(RECS).await;
        let mine = edit(&p, "line | open |", "line | done |");
        let Flush::Proposed(id) = f.views.flush(&f.db, &p, false).await.unwrap() else {
            panic!("not a proposal");
        };
        assert_eq!(std::fs::read_to_string(&p).unwrap(), mine, "the edit stays");
        assert_eq!(row_status(&f, "M1-2%").await, "open", "nothing written");
        assert_eq!(f.count(RECS).await, txs);
        let pr = the_proposal(&f).await;
        assert_eq!(
            (pr.id.as_str(), pr.status),
            (id.as_str(), ProposalStatus::Open)
        );
        assert_eq!(pr.ops.len(), 1);
        assert_eq!(pr.ops[0].fields, ["body", "status"]);
        assert!(pr.diff.contains("second line | done |"), "{}", pr.diff);
        assert!(pr.unmapped.is_empty());
        assert_eq!(
            f.count("select count(*) from link where kind = 'proposes'")
                .await,
            1
        );
    }

    #[tokio::test]
    async fn accept_applies_then_rewrites() {
        let f = fix();
        let p = imported(&f).await;
        let mine = edit(&p, "line | open |", "line | done |");
        let Flush::Proposed(id) = f.views.flush(&f.db, &p, false).await.unwrap() else {
            panic!()
        };
        let (d, ev) = decide_core(&f.db, &f.views, &f.hub, &id, true, false)
            .await
            .unwrap();
        assert_eq!(d.status, ProposalStatus::Accepted);
        assert_eq!(row_status(&f, "M1-2%").await, "done");
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            mine,
            "the graph now says what the file said"
        );
        assert!(ev.iter().all(|e| matches!(e, ViewEvent::Written(_))));
        assert_eq!(the_proposal(&f).await.status, ProposalStatus::Accepted);
        assert!(!f.views.changed(&p));
        let st = status_core(&f.db, &f.views, Some(&p)).await.unwrap();
        assert_eq!(st.views[0].pending, None);
        assert!(matches!(
            f.views.flush(&f.db, &p, false).await.unwrap(),
            Flush::Unchanged
        ));
    }

    #[tokio::test]
    async fn reject_backs_up_then_rewrites() {
        let f = fix();
        let p = imported(&f).await;
        let before = std::fs::read_to_string(&p).unwrap();
        let mine = edit(&p, "line | open |", "line | done |");
        let Flush::Proposed(id) = f.views.flush(&f.db, &p, false).await.unwrap() else {
            panic!()
        };
        let (d, _) = decide_core(&f.db, &f.views, &f.hub, &id, false, false)
            .await
            .unwrap();
        assert_eq!(d.status, ProposalStatus::Rejected);
        let dir = PathBuf::from(d.backup.unwrap());
        assert!(dir.starts_with(f.hub.join("records-backup")));
        let rel: PathBuf = p.components().skip(1).collect();
        assert_eq!(std::fs::read_to_string(dir.join(rel)).unwrap(), mine);
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            before,
            "the view is back"
        );
        assert_eq!(row_status(&f, "M1-2%").await, "open");
    }

    #[tokio::test]
    async fn the_view_waits_while_open() {
        let f = fix();
        let p = imported(&f).await;
        let first = edit(&p, "line | open |", "line | done |");
        let Flush::Proposed(id) = f.views.flush(&f.db, &p, false).await.unwrap() else {
            panic!()
        };
        // the graph changes meanwhile: the view waits
        set_row(
            &f,
            "M2-1%",
            Changes {
                status: Some(Some("open".into())),
                ..Default::default()
            },
        )
        .await;
        assert_eq!(f.views.flush(&f.db, &p, false).await.unwrap(), Flush::Held);
        assert_eq!(std::fs::read_to_string(&p).unwrap(), first);
        let st = status_core(&f.db, &f.views, Some(&p)).await.unwrap();
        assert_eq!(st.views[0].pending.as_deref(), Some(id.as_str()));
        // a second edit replaces the proposal: same id, new diff
        let second = edit(&p, "Invented register for tests.", "Reworded.");
        let Flush::Proposed(id2) = f.views.flush(&f.db, &p, false).await.unwrap() else {
            panic!()
        };
        assert_eq!(id2, id);
        let pr = the_proposal(&f).await;
        assert!(pr.diff.contains("Reworded."));
        assert_eq!(pr.ops.len(), 2);
        assert_eq!(std::fs::read_to_string(&p).unwrap(), second);
    }

    #[tokio::test]
    async fn an_edit_racing_a_rewrite_becomes_a_proposal() {
        let f = fix();
        let p = imported(&f).await;
        // the hub has a rewrite due (the graph changed) when a hand edit lands
        set_row(
            &f,
            "M2-1%",
            Changes {
                status: Some(Some("open".into())),
                ..Default::default()
            },
        )
        .await;
        let mine = edit(
            &p,
            "Invented register for tests.",
            "Typed while the hub rewrote.",
        );
        let r = f.views.flush(&f.db, &p, false).await.unwrap();
        assert!(matches!(r, Flush::Proposed(_)), "{r:?}");
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            mine,
            "the edit is never lost"
        );
        assert!(
            the_proposal(&f)
                .await
                .diff
                .contains("Typed while the hub rewrote.")
        );
    }

    #[tokio::test]
    async fn stale_base_is_not_applied() {
        let f = fix();
        let p = imported(&f).await;
        let mine = edit(&p, "line | open |", "line | done |");
        let Flush::Proposed(id) = f.views.flush(&f.db, &p, false).await.unwrap() else {
            panic!()
        };
        set_row(
            &f,
            "M1-2%",
            Changes {
                body: Some(Some("| M1-2 | sync | changed meanwhile | open |\n".into())),
                ..Default::default()
            },
        )
        .await;
        let (d, ev) = decide_core(&f.db, &f.views, &f.hub, &id, true, false)
            .await
            .unwrap();
        assert_eq!(d.status, ProposalStatus::Stale);
        assert!(ev.is_empty());
        assert_eq!(row_status(&f, "M1-2%").await, "open");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), mine);
        // read again: the edit becomes a fresh proposal under the same id
        let Flush::Proposed(id2) = f.views.flush(&f.db, &p, false).await.unwrap() else {
            panic!()
        };
        assert_eq!(id2, id);
        assert_eq!(the_proposal(&f).await.status, ProposalStatus::Open);
    }

    #[tokio::test]
    async fn manager_cannot_accept_a_user_only_field() {
        let f = fix();
        let p = imported(&f).await;
        edit(
            &p,
            "Invented register for tests.\n",
            "Invented register for tests.\nmatrix: allow all\n",
        );
        let Flush::Proposed(id) = f.views.flush(&f.db, &p, false).await.unwrap() else {
            panic!()
        };
        let pr = the_proposal(&f).await;
        assert_eq!(pr.ops[0].user_only, Some(true));
        let e = decide_core(&f.db, &f.views, &f.hub, &id, true, true)
            .await
            .unwrap_err();
        assert_eq!(e.code, ErrorCode::NotAllowed);
        assert_eq!(the_proposal(&f).await.status, ProposalStatus::Open);
        // a manager may reject it, and the user may accept it
        let (d, _) = decide_core(&f.db, &f.views, &f.hub, &id, true, false)
            .await
            .unwrap();
        assert_eq!(d.status, ProposalStatus::Accepted);
    }

    #[tokio::test]
    async fn prose_edit_becomes_ops_or_a_note() {
        let f = fix();
        let p = imported(&f).await;
        edit(
            &p,
            "Invented register for tests.",
            "Invented register, reworded.",
        );
        let t = std::fs::read_to_string(&p).unwrap();
        let row = "| M2-1 | docs | Pipes \\| in prose and **bold** text | closed: not needed |\n";
        assert!(t.contains(row));
        std::fs::write(&p, t.replacen(row, "", 1)).unwrap();
        let Flush::Proposed(id) = f.views.flush(&f.db, &p, false).await.unwrap() else {
            panic!()
        };
        let pr = the_proposal(&f).await;
        assert_eq!(pr.ops.len(), 1, "the prose is an operation: {pr:?}");
        assert_eq!(pr.unmapped.len(), 1, "the deleted row maps to nothing");
        let (d, _) = decide_core(&f.db, &f.views, &f.hub, &id, true, false)
            .await
            .unwrap();
        assert!(d.note.is_some());
        assert_eq!(
            f.count(
                "select count(*) from entity where kind = 'note' and title like 'Unmapped edit%'"
            )
            .await,
            1
        );
        // the record stays, so the view has the row back
        let back = std::fs::read_to_string(&p).unwrap();
        assert!(back.contains("M2-1") && back.contains("reworded"));
    }

    #[tokio::test]
    async fn a_hub_restart_does_not_turn_its_own_writes_into_proposals() {
        let f = fix();
        let p = imported(&f).await;
        // the hub restarts (nothing in memory) and the graph changed while it was down
        let restarted = Views::default();
        set_row(
            &f,
            "M2-1%",
            Changes {
                status: Some(Some("open".into())),
                ..Default::default()
            },
        )
        .await;
        let r = restarted.flush(&f.db, &p, false).await.unwrap();
        assert!(matches!(r, Flush::Written(_)), "{r:?}");
        assert_eq!(
            proposals_core(&f.db, None).await.unwrap().proposals.len(),
            0
        );
        // and a hand edit after the restart still is one
        let again = Views::default();
        edit(&p, "line | open |", "line | done |");
        assert!(matches!(
            again.flush(&f.db, &p, false).await.unwrap(),
            Flush::Proposed(_)
        ));
    }
}
