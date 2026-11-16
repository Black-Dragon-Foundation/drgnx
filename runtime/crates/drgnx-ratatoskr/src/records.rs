//! Records (`docs/develop/records.md`): a project's record files adopted into the graph (the files and the store
//! backed up first, then `saga`'s graph operations with `Origin::Imported`, then the notice), and kept in step with it
//! both ways by [`Views::sync`]: a three-way merge per piece against what the hub last wrote or read, under a lock
//! per file, re-reading the file just before the rename.  A hand edit is applied; a piece both sides changed keeps
//! the file's text and is flagged until it is resolved.  The hub never commits the files.

use crate::coord::fail;
use crate::dispatch::Caller;
use crate::front::Front;
use norn::store::CoordDb;
use runstav::methods::records::{
    ByPath, Conflict, ImportParams, ImportReport, ImportedFile, Keep, RecordKind, RecordsConflict,
    RecordsNotice, ResolveParams, Resolved, ViewStatus, ViewWritten, Views as ViewsAnswer,
};
use runstav::wire::{Error, ErrorCode};
use saga::import::{self, AnyDoc, GraphOp};
use saga::merge::{self, Act as MergeAct, Base, Merged};
use saga::{status, view};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use urdr::graph::entity::{self, Changes, EntityNew, Origin};
use urdr::graph::link;
use urdr::graph::{Class, TxMeta};

/// The quiet time after the last change of a file's records (or of the file) before the two are merged.
pub const DEBOUNCE: Duration = Duration::from_millis(300);

/// How many times a merge starts over when the file changed while it ran, before the file is left `busy` until the
/// next change.
const TRIES: usize = 3;

/// How many of a piece's last texts the base remembers (a stale editor save brings back one of them).
const BASE_KEEP: usize = 8;

/// What a sync of one file did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Flush {
    /// The file was written; its hash.
    Written(String),
    /// The file already had the merged text.
    Unchanged,
    /// The file is not rewritten before its project's notice went out.
    Waiting,
    /// The file kept changing while the merge ran: tried again at the next change.
    Busy,
}

/// The graph's pieces of a file, by id: what the hub last wrote or read of each.
type Bases = HashMap<String, Base>;

/// A hook the tests run between a merge's read of the file and its write.
#[cfg(test)]
type BeforeWrite = Arc<dyn Fn(&Path) + Send + Sync>;

#[derive(Default)]
struct State {
    /// Path -> (hash of the text the hub last wrote or read, when).
    written: HashMap<PathBuf, (String, f64)>,
    /// Path -> the base of every piece.
    bases: HashMap<PathBuf, Bases>,
    /// Path -> its lock: one merge of a file at a time.
    gates: HashMap<PathBuf, Arc<tokio::sync::Mutex<()>>>,
    timers: HashMap<PathBuf, tokio::task::JoinHandle<()>>,
    #[cfg(test)]
    before_write: Option<BeforeWrite>,
}

/// The files kept in step and what the hub knows of each.  Cheap to clone.
#[derive(Default, Clone)]
pub struct Views {
    state: Arc<Mutex<State>>,
}

fn now() -> f64 {
    crate::clock::wall_secs()
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

fn found(path: PathBuf, kind: RecordKind) -> Found {
    Found {
        parse: parse_of(kind),
        path,
        kind,
    }
}

/// The `saga` parser of a kind of file.
fn parse_of(kind: RecordKind) -> &'static str {
    match kind {
        RecordKind::Specs => "spec",
        RecordKind::Plans => "plan",
        RecordKind::Ledgers => "ledger",
        RecordKind::Deferred => "deferred",
        RecordKind::BuildBoard => "board-md",
        RecordKind::Board => "org",
        RecordKind::Decisions => "decision",
    }
}

/// The record files of ROOT: specs under `docs/specs/`, plans and ledgers under `docs/plans/`, decision records under
/// `docs/decisions/` and `docs/adr/`, `DEFERRED.md`, `BUILD-BOARD.md`; `board.org` only when ONLY names it.
fn discover(root: &Path, only: Option<RecordKind>) -> Vec<Found> {
    let mut out = Vec::new();
    for (dir, kind) in [
        ("docs/specs", RecordKind::Specs),
        ("docs/plans", RecordKind::Plans),
        ("docs/decisions", RecordKind::Decisions),
        ("docs/adr", RecordKind::Decisions),
    ] {
        let mut md = Vec::new();
        walk(&root.join(dir), &mut md);
        md.sort();
        for p in md {
            let ledger = kind == RecordKind::Plans && p.to_string_lossy().ends_with(".ledger.md");
            out.push(found(p, if ledger { RecordKind::Ledgers } else { kind }));
        }
    }
    for (name, kind) in [
        ("DEFERRED.md", RecordKind::Deferred),
        ("BUILD-BOARD.md", RecordKind::BuildBoard),
        ("board.org", RecordKind::Board),
    ] {
        let p = root.join(name);
        if p.is_file() && (kind != RecordKind::Board || only == Some(RecordKind::Board)) {
            out.push(found(p, kind));
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

/// A piece's entity data: where it is (its file, kind, key and place) and, for a plan's task, its fields.
fn data_of(op: &GraphOp, file: &Path, kind: RecordKind) -> Value {
    let r = json!({
        "seq": op.seq, "role": op.role, "key": op.key,
        "file": file.to_string_lossy(), "kind": kind_name(kind),
    });
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

/// A graph piece of a file.
struct Piece {
    n: i64,
    id: String,
    kind: String,
    role: String,
    status: Option<String>,
    body: String,
    ver: i64,
    data: Value,
}

impl Piece {
    fn seq(&self) -> Option<u64> {
        self.data["records"]["seq"].as_u64()
    }
}

/// The live pieces of the file at PATH from the graph, in order.
async fn pieces(db: &CoordDb, path: &Path) -> Result<Vec<Piece>, Error> {
    let key = import::source_key(path);
    db.read(move |c| {
        let mut st = c.prepare(
            "select n, id, kind, status, coalesce(body, ''), data, ver from entity \
             where source = ?1 and retired_tx is null order by json_extract(data, '$.records.seq'), n",
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
                    data,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    })
    .await
    .map_err(fail)
}

/// The kind of the file at PATH, from its pieces (none when the graph has none).
fn kind_in(ps: &[Piece]) -> Option<RecordKind> {
    ps.iter()
        .find_map(|p| p.data["records"]["kind"].as_str().and_then(kind_of))
}

/// Graph statuses written into the text of their pieces (a graph-only change reaches the file): true when a body
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

/// TEXT to PATH: a temporary file beside it, synced, then a rename (the old file is never truncated, so an editor's
/// own atomic save cannot interleave with half of ours).
pub fn write_atomic(path: &Path, text: &str) -> std::io::Result<()> {
    use std::io::Write;
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".drgnx-tmp");
    let tmp = PathBuf::from(tmp);
    let mut f = std::fs::File::create(&tmp)?;
    f.write_all(text.as_bytes())?;
    f.sync_all()?;
    std::fs::rename(&tmp, path)
}

/// What the records tell the editors.
#[derive(Debug, Clone, PartialEq)]
pub enum ViewEvent {
    Written(ViewWritten),
    Notice(RecordsNotice),
    Conflict(RecordsConflict),
}

impl ViewEvent {
    /// The event's name and body, as broadcast.
    pub fn parts(&self) -> (&'static str, Value) {
        match self {
            ViewEvent::Written(w) => ("view-written", serde_json::to_value(w).unwrap_or_default()),
            ViewEvent::Notice(n) => (
                "records-notice",
                serde_json::to_value(n).unwrap_or_default(),
            ),
            ViewEvent::Conflict(c) => (
                "records-conflict",
                serde_json::to_value(c).unwrap_or_default(),
            ),
        }
    }
}

fn kv_get(c: &urdr::Connection, key: &str) -> Option<String> {
    c.query_row("select value from kv where key = ?1", [key], |r| r.get(0))
        .ok()
}

async fn kv_put(db: &CoordDb, pairs: Vec<(String, Option<String>)>) -> Result<(), Error> {
    if pairs.is_empty() {
        return Ok(());
    }
    db.write(meta(), move |tx| {
        for (k, v) in &pairs {
            match v {
                Some(v) => tx.sql().execute(
                    "insert or replace into kv (key, value) values (?1, ?2)",
                    (k, v),
                )?,
                None => tx.sql().execute("delete from kv where key = ?1", [k])?,
            };
        }
        Ok(())
    })
    .await
    .map_err(fail)
}

fn adopted_key(path: &Path) -> String {
    format!("records-adopted:{}", path.to_string_lossy())
}

/// The notice listing the file at PATH went out: the hub may rewrite it.
async fn noticed(db: &CoordDb, path: &Path) -> Result<bool, Error> {
    let key = adopted_key(path);
    db.read(move |c| Ok(kv_get(c, &key).is_some()))
        .await
        .map_err(fail)
}

fn base_json(b: &Bases) -> String {
    let m: serde_json::Map<String, Value> = b
        .iter()
        .map(|(id, b)| (id.clone(), json!([b.ver, b.hashes])))
        .collect();
    Value::Object(m).to_string()
}

fn base_of_json(s: &str) -> Bases {
    let v: Value = serde_json::from_str(s).unwrap_or_default();
    v.as_object()
        .map(|m| {
            m.iter()
                .map(|(id, b)| {
                    (
                        id.clone(),
                        Base {
                            ver: b[0].as_i64().unwrap_or(0),
                            hashes: b[1]
                                .as_array()
                                .map(|a| {
                                    a.iter()
                                        .filter_map(|h| h.as_str().map(str::to_owned))
                                        .collect()
                                })
                                .unwrap_or_default(),
                        },
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

/// OLD with each piece of IDS now at its text in TEXTS (newest first, the last [`BASE_KEEP`] kept), at the versions
/// in VERS; the pieces in HOLD (conflicted) keep their old base, and pieces not in IDS are dropped.
fn next_base(
    old: &Bases,
    ids: &[String],
    texts: &[String],
    vers: &HashMap<String, i64>,
    hold: &HashSet<String>,
) -> Bases {
    let mut out = Bases::new();
    for (id, text) in ids.iter().zip(texts) {
        let prev = old.get(id);
        if hold.contains(id) {
            if let Some(b) = prev {
                out.insert(id.clone(), b.clone());
            }
            continue;
        }
        let h = merge::digest_piece(text);
        let mut hashes = vec![h.clone()];
        hashes.extend(
            prev.map(|b| b.hashes.clone())
                .unwrap_or_default()
                .into_iter()
                .filter(|x| *x != h),
        );
        hashes.truncate(BASE_KEEP);
        out.insert(
            id.clone(),
            Base {
                ver: vers.get(id).copied().unwrap_or(0),
                hashes,
            },
        );
    }
    // a conflicted piece the file deleted keeps its base too
    for id in hold {
        if let (false, Some(b)) = (out.contains_key(id), old.get(id)) {
            out.insert(id.clone(), b.clone());
        }
    }
    out
}

/// FILE's pieces given the ids the graph already has for them: a piece the graph knows by another id (one adopted
/// before the ids were keyed) keeps that id when its text is the graph's.
fn align(file: &mut [GraphOp], live: &[Piece]) {
    let ids: HashSet<String> = file.iter().map(|o| o.id.clone()).collect();
    let mut free: Vec<&Piece> = live.iter().filter(|p| !ids.contains(&p.id)).collect();
    let known: HashSet<&str> = live.iter().map(|p| p.id.as_str()).collect();
    for op in file.iter_mut() {
        if known.contains(op.id.as_str()) {
            continue;
        }
        if let Some(i) = free
            .iter()
            .position(|p| p.kind == op.kind && p.body == op.body)
        {
            op.id = free.remove(i).id.clone();
        }
    }
}

impl Views {
    /// The file at PATH differs from what the hub last wrote or read there (false when it knows nothing of it yet).
    pub fn changed(&self, path: &Path) -> bool {
        let last = lock(&self.state).written.get(path).map(|w| w.0.clone());
        match (last, std::fs::read_to_string(path)) {
            (Some(h), Ok(t)) => view::digest(&t) != h,
            (Some(_), Err(_)) => true,
            (None, _) => false,
        }
    }

    fn gate(&self, path: &Path) -> Arc<tokio::sync::Mutex<()>> {
        lock(&self.state)
            .gates
            .entry(path.to_path_buf())
            .or_default()
            .clone()
    }

    /// The bases of the file at PATH: kept in memory, from the store after a restart (`kv`, `records-base:PATH`).
    async fn bases(&self, db: &CoordDb, path: &Path) -> Result<Bases, Error> {
        if let Some(b) = lock(&self.state).bases.get(path) {
            return Ok(b.clone());
        }
        let key = format!("records-base:{}", path.to_string_lossy());
        let (b, w) = db
            .read(move |c| {
                Ok((
                    kv_get(c, &key),
                    kv_get(c, &key.replacen("records-base:", "records-view:", 1)),
                ))
            })
            .await
            .map_err(fail)?;
        let b = b.map(|s| base_of_json(&s)).unwrap_or_default();
        let mut st = lock(&self.state);
        st.bases.insert(path.to_path_buf(), b.clone());
        if let Some(w) = w {
            st.written.entry(path.to_path_buf()).or_insert((w, 0.0));
        }
        Ok(b)
    }

    /// BASE (and HASH, the file's text now) kept for PATH, in memory and, when either changed, in the store.
    async fn keep(
        &self,
        db: &CoordDb,
        path: &Path,
        base: Bases,
        hash: String,
    ) -> Result<(), Error> {
        let (old_b, old_w) = {
            let st = lock(&self.state);
            (
                st.bases.get(path).cloned(),
                st.written.get(path).map(|w| w.0.clone()),
            )
        };
        let p = path.to_string_lossy();
        let mut pairs = Vec::new();
        if old_b.as_ref() != Some(&base) {
            pairs.push((format!("records-base:{p}"), Some(base_json(&base))));
        }
        if old_w.as_deref() != Some(hash.as_str()) {
            pairs.push((format!("records-view:{p}"), Some(hash.clone())));
        }
        {
            let mut st = lock(&self.state);
            st.bases.insert(path.to_path_buf(), base);
            st.written.insert(path.to_path_buf(), (hash, now()));
        }
        kv_put(db, pairs).await
    }

    #[cfg(test)]
    fn hook(&self) -> Option<BeforeWrite> {
        lock(&self.state).before_write.clone()
    }

    /// The file at PATH and its records merged, both ways (`docs/develop/records.md`, "Keeping files and records in
    /// step"): the file is read, parsed and merged piece by piece with the graph against the base; the graph takes
    /// the file's changes and the file the graph's, a piece both changed keeps the file's text and is flagged; the
    /// file is re-read just before the rename and the merge starts over when it changed ([`TRIES`] times, then
    /// `busy`).  Also how many graph changes it made, and the records it newly flagged.
    pub async fn sync(&self, db: &CoordDb, path: &Path) -> Result<(Flush, u64), Error> {
        let (f, acts, _) = self.sync_flagged(db, path).await?;
        Ok((f, acts))
    }

    /// [`Views::sync`], with the ids it newly flagged.  A plan and its ledger (`<plan>.ledger.md`) are two files that
    /// say one thing: whichever synced, the plan's tasks' `ledger` data is read from the ledger again.
    async fn sync_flagged(
        &self,
        db: &CoordDb,
        path: &Path,
    ) -> Result<(Flush, u64, Vec<String>), Error> {
        let r = self.sync_inner(db, path).await?;
        ledger_marks(db, path).await?;
        Ok(r)
    }

    async fn sync_inner(
        &self,
        db: &CoordDb,
        path: &Path,
    ) -> Result<(Flush, u64, Vec<String>), Error> {
        let gate = self.gate(path);
        let _held = gate.lock().await;
        sync_bodies(db, path).await?;
        let Some(kind) = kind_in(&pieces(db, path).await?) else {
            return Ok((Flush::Unchanged, 0, Vec::new()));
        };
        let may_write = noticed(db, path).await?;
        let mut base = self.bases(db, path).await?;
        let mut acts = 0;
        let mut flagged: Vec<String> = Vec::new();
        for _ in 0..TRIES {
            // a missing file retires nothing: its records stay until the project forgets them
            let Ok(raw) = std::fs::read_to_string(path) else {
                return Ok((Flush::Unchanged, acts, flagged));
            };
            let doc = import::parse(parse_of(kind), view::strip_header(&raw))
                .ok_or_else(|| err("unknown record kind"))?;
            let mut ops = import::ops(&doc, path);
            let live = pieces(db, path).await?;
            align(&mut ops, &live);
            let lv: Vec<merge::Live> = live
                .iter()
                .map(|p| merge::Live {
                    id: p.id.clone(),
                    ver: p.ver,
                    body: p.body.clone(),
                    seq: p.seq().unwrap_or(0) as u32,
                })
                .collect();
            let m = merge::merge(&ops, &base, &lv);
            for id in &m.conflicts {
                let was = live
                    .iter()
                    .find(|p| p.id == *id)
                    .is_some_and(|p| !p.data["records"]["conflict"].is_null());
                if !was && !flagged.contains(id) {
                    flagged.push(id.clone());
                }
            }
            acts += apply(db, path, kind, &ops, &m, &live).await?;
            let vers: HashMap<String, i64> = pieces(db, path)
                .await?
                .into_iter()
                .map(|p| (p.id, p.ver))
                .collect();
            let hold: HashSet<String> = m.conflicts.iter().cloned().collect();
            let (ids, bodies): (Vec<String>, Vec<String>) =
                ops.iter().map(|o| (o.id.clone(), o.body.clone())).unzip();
            // what the file holds now, which the graph has taken
            let on_disk = next_base(&base, &ids, &bodies, &vers, &hold);
            if m.text == raw {
                self.keep(db, path, on_disk, view::digest(&raw)).await?;
                return Ok((Flush::Unchanged, acts, flagged));
            }
            if !may_write {
                self.keep(db, path, on_disk, view::digest(&raw)).await?;
                return Ok((Flush::Waiting, acts, flagged));
            }
            #[cfg(test)]
            if let Some(h) = self.hook() {
                h(path);
            }
            if std::fs::read_to_string(path).ok().as_deref() != Some(raw.as_str()) {
                base = on_disk;
                continue;
            }
            write_atomic(path, &m.text).map_err(|e| err(format!("{}: {e}", path.display())))?;
            let hash = view::digest(&m.text);
            let written = next_base(&base, &m.order, &m.parts, &vers, &hold);
            self.keep(db, path, written, hash.clone()).await?;
            return Ok((Flush::Written(hash), acts, flagged));
        }
        let h = std::fs::read_to_string(path)
            .map(|t| view::digest(&t))
            .unwrap_or_default();
        self.keep(db, path, base, h).await?;
        Ok((Flush::Busy, acts, flagged))
    }

    /// What a sync of PATH came to, as the events to send: the write, and the records it newly flagged.
    fn events_of(path: &Path, kind: RecordKind, f: &Flush, flagged: Vec<String>) -> Vec<ViewEvent> {
        let mut out = Vec::new();
        if let Flush::Written(hash) = f {
            out.push(ViewEvent::Written(ViewWritten {
                path: path.to_string_lossy().into_owned(),
                kind,
                hash: hash.clone(),
            }));
        }
        if !flagged.is_empty() {
            out.push(ViewEvent::Conflict(RecordsConflict {
                path: path.to_string_lossy().into_owned(),
                ids: flagged,
            }));
        }
        out
    }

    /// Every file the graph knows, synced now.
    pub async fn sync_all(&self, db: &CoordDb) -> Result<Vec<ViewEvent>, Error> {
        let mut events = Vec::new();
        for v in status_core(db, self, None).await?.views {
            let path = PathBuf::from(&v.path);
            let (f, _, flagged) = self.sync_flagged(db, &path).await?;
            events.extend(Self::events_of(&path, v.kind, &f, flagged));
        }
        Ok(events)
    }

    /// The file at PATH (or its records) changed: merge the two after [`DEBOUNCE`] of quiet.  EMIT hears each write.
    pub fn on_change(
        &self,
        db: CoordDb,
        path: PathBuf,
        emit: Arc<dyn Fn(ViewEvent) + Send + Sync>,
    ) {
        let me = self.clone();
        let p = path.clone();
        let h = crate::clock::spawn("records:debounce", async move {
            crate::clock::sleep(DEBOUNCE).await;
            let kind = kind_in(&pieces(&db, &p).await.unwrap_or_default());
            if let Ok((f, _, flagged)) = me.sync_flagged(&db, &p).await
                && let Some(k) = kind
            {
                for e in Self::events_of(&p, k, &f, flagged) {
                    emit(e);
                }
            }
        });
        if let Some(old) = lock(&self.state).timers.insert(path, h) {
            old.abort();
        }
    }
}

/// The plan file and its ledger when PATH is either (`X.md` and `X.ledger.md`).
fn plan_and_ledger(path: &Path) -> Option<(PathBuf, PathBuf)> {
    let name = path.file_name()?.to_str()?;
    let stem = name.strip_suffix(".ledger.md").or_else(|| {
        let s = name.strip_suffix(".md")?;
        path.with_file_name(format!("{s}.ledger.md"))
            .is_file()
            .then_some(s)
    })?;
    Some((
        path.with_file_name(format!("{stem}.md")),
        path.with_file_name(format!("{stem}.ledger.md")),
    ))
}

/// What the plan's ledger says of each of its tasks, kept on the task as `data.ledger` (`done`, `commits` as written,
/// `ahead`: the ledger says done while the plan's steps are not all checked, and the file of the ledger).  A task the
/// ledger does not mark has none.  It is data beside the task, never its status: the status is the plan's steps, which
/// the sync writes back into the plan's text, and a ledger must not tick a plan's boxes.  The map reads both.
async fn ledger_marks(db: &CoordDb, path: &Path) -> Result<(), Error> {
    let Some((plan, ledger)) = plan_and_ledger(path) else {
        return Ok(());
    };
    let marks = std::fs::read_to_string(&ledger)
        .map(|t| saga::ledger::done_marks(&t))
        .unwrap_or_default();
    let file = ledger.to_string_lossy().into_owned();
    let tasks: Vec<Piece> = pieces(db, &plan)
        .await?
        .into_iter()
        .filter(|p| p.role == "task")
        .collect();
    let mut changes: Vec<(i64, Value)> = Vec::new();
    for t in &tasks {
        let Some(number) = t.data["number"].as_str() else {
            continue;
        };
        let want = marks
            .iter()
            .find(|m| m.tasks.iter().any(|n| n == number))
            .map(|m| {
                let steps = t.data["steps"].as_array();
                let ticked = steps.is_some_and(|s| {
                    !s.is_empty() && s.iter().all(|x| x["done"].as_bool() == Some(true))
                });
                json!({"done": true, "commits": m.commits, "ahead": !ticked, "file": file})
            })
            .unwrap_or(Value::Null);
        let have = t.data.get("ledger").cloned().unwrap_or(Value::Null);
        if have != want {
            changes.push((t.n, want));
        }
    }
    if !changes.is_empty() {
        db.write(meta(), move |tx| {
            for (n, want) in changes {
                entity::update(
                    tx,
                    n,
                    None,
                    Changes {
                        data_patch: Some(json!({ "ledger": want })),
                        ..Default::default()
                    },
                )?;
            }
            Ok(())
        })
        .await
        .map_err(fail)?;
    }
    // a ledger in a linked git worktree gives its plan that branch, and whether it is merged (git changes on its own:
    // this is asked every time)
    ledger_branch(db, &plan, &ledger, &marks, &tasks).await?;
    // git is asked again only when the ledger or the plan's task numbers changed since the last time
    let stamp = {
        let text = std::fs::read_to_string(&ledger).unwrap_or_default();
        let ids: Vec<String> = tasks
            .iter()
            .map(|t| format!("{}:{}", t.n, t.data["number"].as_str().unwrap_or("")))
            .collect();
        view::digest(&format!("{text}\0{}", ids.join(",")))
    };
    let key = format!("ledger-commits:{file}");
    let k = key.clone();
    let seen = db.read(move |c| Ok(kv_get(c, &k))).await.map_err(fail)?;
    if seen.as_deref() == Some(stamp.as_str()) {
        return Ok(());
    }
    ledger_commits(db, &plan, &ledger, &marks, &tasks).await?;
    kv_put(db, vec![(key, Some(stamp))]).await
}

/// A ledger that lies in a linked git worktree gives its plan the worktree's branch: a `branch:COMMON:NAME` entity the plan
/// is `on_branch` of, and on the plan `data.git` (`branch`, `worktree` while its folder exists, `repo` the main checkout,
/// `merged`).  Merged: every task is done (its steps or its ledger) and the branch is in main, or no longer exists.
async fn ledger_branch(
    db: &CoordDb,
    plan: &Path,
    ledger: &Path,
    marks: &[saga::ledger::DoneMark],
    tasks: &[Piece],
) -> Result<(), Error> {
    let dir = ledger.parent().unwrap_or(Path::new("/")).to_path_buf();
    let all_done = !tasks.is_empty()
        && tasks.iter().all(|t| {
            let number = t.data["number"].as_str().unwrap_or("");
            t.status.as_deref() == Some("done")
                || marks.iter().any(|m| m.tasks.iter().any(|n| n == number))
        });
    let facts = crate::clock::blocking(move || {
        let git_dir = git_out(&dir, &["rev-parse", "--absolute-git-dir"])?;
        let common = git_out(
            &dir,
            &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        )?;
        let same =
            |a: &str, b: &str| std::fs::canonicalize(a).ok() == std::fs::canonicalize(b).ok();
        if same(&git_dir, &common) {
            return None;
        }
        let top = git_out(&dir, &["rev-parse", "--show-toplevel"])?;
        let name = git_out(&dir, &["rev-parse", "--abbrev-ref", "HEAD"])?;
        let repo = main_repo(&dir)?;
        let main = ["main", "master"]
            .into_iter()
            .find(|m| git_out(&repo, &["rev-parse", "--verify", "-q", m]).is_some());
        let exists = git_out(
            &repo,
            &["rev-parse", "--verify", "-q", &format!("refs/heads/{name}")],
        )
        .is_some();
        let merged = all_done
            && main.is_some_and(|m| {
                !exists
                    || std::process::Command::new("git")
                        .arg("-C")
                        .arg(&repo)
                        .args(["merge-base", "--is-ancestor", &name, m])
                        .status()
                        .is_ok_and(|s| s.success())
            });
        Some((common, top, name, repo, merged))
    })
    .await
    .map_err(|e| err(format!("git: {e}")))?;
    let Some((common, top, name, repo, merged)) = facts else {
        return Ok(());
    };
    let Some(head) = pieces(db, plan)
        .await?
        .into_iter()
        .find(|p| p.role == "head")
    else {
        return Ok(());
    };
    let worktree = Path::new(&top).is_dir().then(|| top.clone());
    let want = json!({
        "branch": name,
        "worktree": worktree,
        "repo": format!("{}/", repo.to_string_lossy().trim_end_matches('/')),
        "merged": merged,
    });
    let bid = format!("branch:{common}:{name}");
    let top2 = top.clone();
    db.write(meta(), move |tx| {
        let cur = entity::by_n(tx.sql(), head.n)?;
        if cur
            .as_ref()
            .is_some_and(|c| c.data.get("git") == Some(&want))
        {
            // facts unchanged: the link is there too
            if let Some(b) = entity::by_id(tx.sql(), &bid)? {
                link::add(
                    tx,
                    head.n,
                    "on_branch",
                    b.n,
                    None,
                    Origin::Inferred,
                    Some("branch"),
                )?;
            }
            return Ok(());
        }
        entity::update(
            tx,
            head.n,
            None,
            Changes {
                data_patch: Some(json!({ "git": want })),
                ..Default::default()
            },
        )?;
        let b = match entity::by_id(tx.sql(), &bid)? {
            Some(b) => {
                entity::unretire(tx, b.n)?;
                b.n
            }
            None => {
                entity::create(
                    tx,
                    EntityNew {
                        id: bid,
                        kind: "branch".into(),
                        project: cur.and_then(|c| c.project),
                        title: Some(name.clone()),
                        status: None,
                        body: None,
                        priority: None,
                        assignee: None,
                        data: json!({"repo": top2, "name": name}),
                        origin: Origin::Parsed,
                        source: Some("branch".into()),
                    },
                )?
                .n
            }
        };
        link::add(
            tx,
            head.n,
            "on_branch",
            b,
            None,
            Origin::Inferred,
            Some("branch"),
        )?;
        Ok(())
    })
    .await
    .map_err(fail)
}

/// A commit a ledger names: its full sha, its time and its subject.
struct GitCommit {
    sha: String,
    date: i64,
    subject: String,
}

/// What `git ARGS` prints in REPO, or none when it fails.
fn git_out(repo: &Path, args: &[&str]) -> Option<String> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .env_remove("GIT_DIR")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// The main checkout of the repository DIR is in (never a linked worktree, which may go).
fn main_repo(dir: &Path) -> Option<PathBuf> {
    let common = git_out(
        dir,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?;
    let common = PathBuf::from(common);
    Some(if common.file_name().is_some_and(|n| n == ".git") {
        common.parent()?.to_path_buf()
    } else {
        common
    })
}

fn git_log(repo: &Path, args: &[&str]) -> Vec<GitCommit> {
    let mut a = vec!["log", "--format=%H%x09%ct%x09%s"];
    a.extend_from_slice(args);
    git_out(repo, &a)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let mut p = l.splitn(3, '\t');
            Some(GitCommit {
                sha: p.next()?.to_owned(),
                date: p.next()?.parse().ok()?,
                subject: p.next().unwrap_or("").to_owned(),
            })
        })
        .collect()
}

/// The commits a mark names (`A..B`: the commits after A up to B; one sha: that commit) in the first of REPOS that has
/// them: (the repo, the commits).  None when no repository has them (the range is stale).
fn resolve_commits(repos: &[PathBuf], named: &[String]) -> Option<(PathBuf, Vec<GitCommit>)> {
    repos.iter().find_map(|repo| {
        let has =
            |sha: &str| git_out(repo, &["cat-file", "-e", &format!("{sha}^{{commit}}")]).is_some();
        match named {
            [a, b] if has(a) && has(b) => {
                Some((repo.clone(), git_log(repo, &[&format!("{a}..{b}")])))
            }
            [one] if has(one) => Some((repo.clone(), git_log(repo, &["-1", one]))),
            _ => None,
        }
    })
}

/// A ledger's commits as links: for each mark that names commits, the commits (entities `commit:SHA`) `implements` the
/// mark's first task, inferred, with the ledger as the link's source; a link this ledger made before and no mark makes now
/// is retired.  The range is read in the repository of the plan, so git runs here, in the hub.
async fn ledger_commits(
    db: &CoordDb,
    plan: &Path,
    ledger: &Path,
    marks: &[saga::ledger::DoneMark],
    tasks: &[Piece],
) -> Result<(), Error> {
    let source = ledger.to_string_lossy().into_owned();
    let dir = plan.parent().unwrap_or(Path::new("/")).to_path_buf();
    let wants: Vec<(i64, Vec<String>)> = marks
        .iter()
        .filter_map(|m| {
            let first = m.tasks.first()?;
            let t = tasks
                .iter()
                .find(|t| t.data["number"].as_str() == Some(first.as_str()))?;
            Some((t.n, m.commits.clone()))
        })
        .collect();
    let task_ns: Vec<i64> = tasks.iter().map(|t| t.n).collect();
    let resolved = crate::clock::blocking(move || {
        let repos: Vec<PathBuf> = main_repo(&dir).into_iter().collect();
        wants
            .into_iter()
            .map(|(n, named)| {
                let r = if named.is_empty() {
                    None
                } else {
                    resolve_commits(&repos, &named)
                };
                (n, r)
            })
            .collect::<Vec<_>>()
    })
    .await
    .map_err(|e| err(format!("git: {e}")))?;
    db.write(meta(), move |tx| {
        let mut keep: Vec<(i64, i64)> = Vec::new();
        for (task, found) in resolved {
            let Some((repo, commits)) = found else {
                continue;
            };
            let project = entity::by_n(tx.sql(), task)?.and_then(|t| t.project);
            let repo_s = format!("{}/", repo.to_string_lossy().trim_end_matches('/'));
            for c in commits {
                let id = format!("commit:{}", c.sha);
                let data = json!({"sha": c.sha, "date": c.date, "repo": repo_s, "path": repo_s});
                let n = match entity::by_id(tx.sql(), &id)? {
                    Some(cur) => {
                        entity::unretire(tx, cur.n)?;
                        cur.n
                    }
                    None => {
                        entity::create(
                            tx,
                            EntityNew {
                                id,
                                kind: "commit".into(),
                                project,
                                title: Some(c.subject.clone()),
                                status: None,
                                body: None,
                                priority: None,
                                assignee: None,
                                data,
                                origin: Origin::Parsed,
                                source: Some("commit".into()),
                            },
                        )?
                        .n
                    }
                };
                link::add(tx, n, "implements", task, None, Origin::Inferred, Some(&source))?;
                keep.push((n, task));
            }
        }
        // what this ledger linked before and no mark links now
        let old: Vec<(i64, i64)> = {
            let mut st = tx.sql().prepare(
                "select src, dst from link where kind = 'implements' and source = ?1 and tx_to = ?2",
            )?;
            st.query_map((source.as_str(), urdr::graph::schema::SENTINEL), |r| {
                Ok((r.get(0)?, r.get(1)?))
            })?
            .collect::<Result<_, _>>()?
        };
        for (src, dst) in old {
            if task_ns.contains(&dst) && !keep.contains(&(src, dst)) {
                link::retire(tx, src, "implements", dst)?;
            }
        }
        Ok(())
    })
    .await
    .map_err(fail)
}

/// M's acts carried out on the graph, and its pieces put in its order.  How many acts.
async fn apply(
    db: &CoordDb,
    path: &Path,
    kind: RecordKind,
    ops: &[GraphOp],
    m: &Merged,
    live: &[Piece],
) -> Result<u64, Error> {
    let seqs: HashMap<&str, Option<u64>> = live.iter().map(|p| (p.id.as_str(), p.seq())).collect();
    let reorder: Vec<(String, usize)> = m
        .order
        .iter()
        .enumerate()
        .filter(|(i, id)| seqs.get(id.as_str()).is_some_and(|s| *s != Some(*i as u64)))
        .map(|(i, id)| (id.clone(), i))
        .collect();
    if m.acts.is_empty() && reorder.is_empty() {
        return Ok(0);
    }
    let n = m.acts.len() as u64;
    let (acts, order, ops, file) = (
        m.acts.clone(),
        m.order.clone(),
        ops.to_vec(),
        path.to_path_buf(),
    );
    db.write(meta(), move |tx| {
        let at = |id: &str, op: &GraphOp| -> GraphOp {
            let mut op = op.clone();
            op.id = id.to_owned();
            if let Some(i) = order.iter().position(|x| x == id) {
                op.seq = i as u32;
            }
            op
        };
        for a in &acts {
            match a {
                MergeAct::Update { id, op } => {
                    let op = at(id, op);
                    if let Some(e) = entity::by_id(tx.sql(), id)? {
                        entity::update(tx, e.n, None, changes_of(&op, &data_of(&op, &file, kind)))?;
                    }
                }
                MergeAct::Create(op) => {
                    let op = at(&op.id, op);
                    let data = data_of(&op, &file, kind);
                    match entity::by_id(tx.sql(), &op.id)? {
                        Some(e) => {
                            if e.retired_tx.is_some() {
                                entity::unretire(tx, e.n)?;
                            }
                            entity::update(tx, e.n, None, changes_of(&op, &data))?;
                        }
                        None => {
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
                                    data,
                                    origin: Origin::Imported,
                                    source: Some(op.source.clone()),
                                },
                            )?;
                        }
                    }
                }
                MergeAct::Retire { id } => {
                    if let Some(e) = entity::by_id(tx.sql(), id)?
                        && e.retired_tx.is_none()
                    {
                        entity::retire(tx, e.n)?;
                    }
                }
                MergeAct::Conflict { id, file: text } => {
                    if let Some(e) = entity::by_id(tx.sql(), id)? {
                        entity::update(
                            tx,
                            e.n,
                            None,
                            Changes {
                                data_patch: Some(
                                    json!({"records": {"conflict": {"file": text, "at": now()}}}),
                                ),
                                ..Default::default()
                            },
                        )?;
                    }
                }
            }
        }
        for (id, i) in &reorder {
            if let Some(e) = entity::by_id(tx.sql(), id)? {
                entity::update(
                    tx,
                    e.n,
                    None,
                    Changes {
                        data_patch: Some(json!({"records": {"seq": i}})),
                        ..Default::default()
                    },
                )?;
            }
        }
        let placed: Vec<GraphOp> = ops.iter().map(|o| at(&o.id, o)).collect();
        link_structure(tx, &placed)?;
        Ok(())
    })
    .await
    .map_err(fail)?;
    Ok(n)
}

/// The conflicted record ID: its file, its file text and the graph's version.
async fn conflict_of(db: &CoordDb, id: &str) -> Result<Conflict, Error> {
    let id = id.to_owned();
    let e = db
        .read(move |c| Ok(entity::by_id(c, &id)?))
        .await
        .map_err(fail)?
        .filter(|e| e.retired_tx.is_none() || !e.data["records"]["conflict"].is_null())
        .ok_or_else(|| err("no such record"))?;
    let c = &e.data["records"]["conflict"];
    if c.is_null() {
        return Err(err(format!("{} is not in conflict", e.id)));
    }
    Ok(Conflict {
        id: e.id.clone(),
        path: e.data["records"]["file"].as_str().unwrap_or("").to_owned(),
        file: c["file"].as_str().unwrap_or("").to_owned(),
        graph: e.body.clone().unwrap_or_default(),
        at: c["at"].as_f64().unwrap_or(0.0),
    })
}

/// Resolve the conflicted record ID: KEEP the file's text (it becomes the record's) or the graph's version (written
/// back into the file).  Then the file is synced.
pub async fn resolve_core(
    db: &CoordDb,
    views: &Views,
    id: &str,
    keep: Keep,
) -> Result<(Resolved, Vec<ViewEvent>), Error> {
    let c = conflict_of(db, id).await?;
    let path = PathBuf::from(&c.path);
    {
        let gate = views.gate(&path);
        let _held = gate.lock().await;
        let mut base = views.bases(db, &path).await?;
        let deleted = c.file.is_empty();
        let (rid, file_text) = (c.id.clone(), c.file.clone());
        db.write(meta(), move |tx| {
            let Some(e) = entity::by_id(tx.sql(), &rid)? else {
                return Ok(());
            };
            let clear = json!({"records": {"conflict": null}});
            match (keep, deleted) {
                (Keep::File, true) => {
                    entity::update(
                        tx,
                        e.n,
                        None,
                        Changes {
                            data_patch: Some(clear),
                            ..Default::default()
                        },
                    )?;
                    entity::retire(tx, e.n)?;
                }
                (Keep::File, false) => {
                    let st = status::status_of(
                        &e.kind,
                        e.data["records"]["role"].as_str().unwrap_or(""),
                        &file_text,
                    );
                    entity::update(
                        tx,
                        e.n,
                        None,
                        Changes {
                            body: Some(Some(file_text)),
                            status: st.map(Some),
                            data_patch: Some(clear),
                            ..Default::default()
                        },
                    )?;
                }
                (Keep::Graph, _) => {
                    entity::update(
                        tx,
                        e.n,
                        None,
                        Changes {
                            data_patch: Some(clear),
                            ..Default::default()
                        },
                    )?;
                }
            }
            Ok(())
        })
        .await
        .map_err(fail)?;
        // the base now says the file's text was seen: the file is unchanged since, so the side kept wins
        if deleted {
            base.remove(&c.id);
        } else {
            let b = base.entry(c.id.clone()).or_default();
            let h = merge::digest_piece(&c.file);
            b.hashes.retain(|x| *x != h);
            b.hashes.insert(0, h);
            b.hashes.truncate(BASE_KEEP);
        }
        let w = lock(&views.state)
            .written
            .get(&path)
            .map(|w| w.0.clone())
            .unwrap_or_default();
        views.keep(db, &path, base, w).await?;
    }
    let (f, _, flagged) = views.sync_flagged(db, &path).await?;
    let kind = kind_in(&pieces(db, &path).await?);
    let events = kind
        .map(|k| Views::events_of(&path, k, &f, flagged))
        .unwrap_or_default();
    Ok((
        Resolved {
            id: c.id,
            keep,
            path: c.path,
        },
        events,
    ))
}

/// The follower: after every write of the front's methods, [`DEBOUNCE`] of quiet, then every file is synced (a graph
/// change reaches its file, a hand edit its records) and the editors hear of each write.
pub async fn follow(front: Arc<Front>) {
    let signals = front.writer.signals.clone();
    loop {
        signals.records.notified().await;
        loop {
            tokio::select! {
                () = signals.records.notified() => {}
                () = crate::clock::sleep(DEBOUNCE) => break,
            }
        }
        match front.core.records.sync_all(&front.writer.db).await {
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

/// A copy of the graph store (`work.db`) beside the backed-up files.
async fn backup_store(db: &CoordDb, dir: &Path) -> Result<(), Error> {
    std::fs::create_dir_all(dir).map_err(|e| err(format!("backup: {e}")))?;
    let to = dir.join("work.db").to_string_lossy().into_owned();
    db.read(move |c| {
        c.execute("vacuum into ?1", [&to])?;
        Ok(())
    })
    .await
    .map_err(fail)
}

/// The adoption of ROOT's record files: on the first one the files and the graph store are backed up and the notice
/// goes out (EMIT) before anything is rewritten; files the graph does not have yet are imported (their text as the
/// records), the others merged ([`Views::sync`]).  A dry run reads and counts.
pub async fn import_core(
    db: &CoordDb,
    views: &Views,
    hub: &Path,
    root: &Path,
    only: Option<RecordKind>,
    dry: bool,
    emit: &(dyn Fn(ViewEvent) + Send + Sync),
) -> Result<ImportReport, Error> {
    let found = discover(root, only);
    let mut fresh = Vec::new();
    for f in &found {
        if !noticed(db, &f.path).await? {
            fresh.push(f);
        }
    }
    // the first adoption of a file backs up (every call, a backup of everything: opening Work imports each time)
    let backup_dir = if dry || fresh.is_empty() {
        None
    } else {
        let dir = backup(hub, root, &found, now())?;
        if !fresh.is_empty() {
            backup_store(db, &dir).await?;
        }
        Some(dir)
    };
    let mut files = Vec::new();
    for f in &found {
        let has = !pieces(db, &f.path).await?.is_empty();
        if dry || !has {
            files.push(import_one(db, f, dry).await?);
        } else {
            files.push(ImportedFile {
                path: f.path.to_string_lossy().into_owned(),
                kind: f.kind,
                entity: pieces(db, &f.path).await?.first().map(|p| p.id.clone()),
                entities: 0,
                ops: 0,
            });
        }
    }
    if dry {
        return Ok(ImportReport {
            dry_run: true,
            backup: None,
            files,
        });
    }
    if !fresh.is_empty() {
        emit(ViewEvent::Notice(RecordsNotice {
            root: root.to_string_lossy().into_owned(),
            files: fresh
                .iter()
                .map(|f| f.path.to_string_lossy().into_owned())
                .collect(),
            backup: backup_dir
                .as_ref()
                .map(|d| d.to_string_lossy().into_owned()),
        }));
        kv_put(
            db,
            fresh
                .iter()
                .map(|f| (adopted_key(&f.path), Some("1".to_owned())))
                .collect(),
        )
        .await?;
    }
    for (f, row) in found.iter().zip(files.iter_mut()) {
        let (fl, acts, flagged) = views.sync_flagged(db, &f.path).await?;
        row.entities += acts;
        row.ops += acts;
        for e in Views::events_of(&f.path, f.kind, &fl, flagged) {
            emit(e);
        }
    }
    Ok(ImportReport {
        dry_run: false,
        backup: backup_dir.map(|d| d.to_string_lossy().into_owned()),
        files,
    })
}

/// The files the graph knows, and where each stands.
pub async fn status_core(
    db: &CoordDb,
    views: &Views,
    only: Option<&Path>,
) -> Result<ViewsAnswer, Error> {
    let rows: Vec<(String, String)> = db
        .read(|c| {
            let mut st = c.prepare(
                "select id, data from entity where source like 'records:%' and retired_tx is null \
                 order by json_extract(data, '$.records.seq'), n",
            )?;
            Ok(st
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<Result<Vec<_>, _>>()?)
        })
        .await
        .map_err(fail)?;
    let mut by_file: Vec<(PathBuf, RecordKind, String, Vec<String>)> = Vec::new();
    for (id, data) in rows {
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
        let conflicted = !d["records"]["conflict"].is_null();
        match by_file.iter_mut().find(|v| v.0 == path) {
            Some(v) => {
                if conflicted {
                    v.3.push(id);
                }
            }
            None => {
                let c = if conflicted {
                    vec![id.clone()]
                } else {
                    Vec::new()
                };
                by_file.push((path, kind, id, c));
            }
        }
    }
    let mut out = Vec::new();
    for (path, kind, entity, conflicts) in by_file {
        let _ = views.bases(db, &path).await?;
        let last = lock(&views.state).written.get(&path).cloned();
        out.push(ViewStatus {
            path: path.to_string_lossy().into_owned(),
            kind,
            entity,
            written: last.as_ref().map(|l| l.1).filter(|t| *t > 0.0),
            changed: last.is_some() && views.changed(&path),
            hash: last.map(|l| l.0),
            conflicts,
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
    let emit = |e: ViewEvent| {
        let (name, body) = e.parts();
        f.broadcast(name, body);
    };
    import_core(
        &f.writer.db,
        &f.core.records,
        &hub,
        Path::new(p.root.as_str()),
        p.only,
        p.dry_run.unwrap_or(false),
        &emit,
    )
    .await
}

pub async fn status(f: &Front, _: &Caller, p: ByPath) -> Result<ViewsAnswer, Error> {
    // an edit is read when somebody looks
    for e in f.core.records.sync_all(&f.writer.db).await? {
        let (name, body) = e.parts();
        f.broadcast(name, body);
    }
    status_core(
        &f.writer.db,
        &f.core.records,
        p.path.as_ref().map(|a| Path::new(a.as_str())),
    )
    .await
}

pub async fn conflict(
    f: &Front,
    _: &Caller,
    p: runstav::methods::exec::ById,
) -> Result<Conflict, Error> {
    conflict_of(&f.writer.db, p.id.as_str()).await
}

pub async fn resolve(f: &Front, _: &Caller, p: ResolveParams) -> Result<Resolved, Error> {
    let (r, events) = resolve_core(&f.writer.db, &f.core.records, p.id.as_str(), p.keep).await?;
    for e in events {
        let (name, body) = e.parts();
        f.broadcast(name, body);
    }
    Ok(r)
}

fn refuse(msg: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::NotAllowed,
        message: msg.into(),
        path: None,
    }
}

/// The conflict tools' door into the records ([`crate::coord::Signals::records_tool`]).
pub fn install_tool(front: &Arc<Front>) {
    let weak = Arc::downgrade(front);
    let door: crate::coord::RecordsTool = Arc::new(move |id, keep_file, session| {
        let weak = weak.clone();
        Box::pin(async move {
            let front = weak
                .upgrade()
                .ok_or_else(|| "the hub is stopping".to_string())?;
            tool_call(&front, id, keep_file, session)
                .await
                .map_err(|e| e.message)
        })
    });
    let _ = front.writer.signals.records_tool.set(door);
}

/// `record_conflict_read` (KEEP_FILE none) and `record_conflict_resolve` of an agent: resolving needs the matrix's
/// `graph.change`.
async fn tool_call(
    f: &Front,
    id: String,
    keep_file: Option<bool>,
    session: Option<String>,
) -> Result<String, Error> {
    use crate::matrix_gate::{ActionCtx, Gate};
    let db = &f.writer.db;
    // an agent reads and resolves the conflicts in its own project's files only; a session the hub does not hold (or
    // one outside any project) reaches none
    let scope = match session.as_deref() {
        Some(s) => crate::runner::effects::scope_of_session(f, s).await.ok(),
        None => None,
    }
    .unwrap_or(crate::runner::effects::Scope::Project {
        id: None,
        root: None,
        jobs: Vec::new(),
        sessions: Vec::new(),
    });
    let c = conflict_of(db, &id).await?;
    scope
        .allows_path(Path::new(&c.path))
        .map_err(|e| refuse(e.to_string()))?;
    let Some(keep_file) = keep_file else {
        return Ok(json!(c).to_string());
    };
    f.core.matrix.refresh(f);
    let gate = f.core.matrix.clone();
    // the session's own column; a caller the hub does not hold gets the worker column, the more restrictive of the two
    // that may change the graph
    let who = session
        .as_deref()
        .and_then(|s| f.core.agents.who(s))
        .unwrap_or(norn::matrix::Who {
            role: Some(runstav::methods::matrix::Role::Worker),
            agent: None,
            provider: None,
        });
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
                "the matrix asks the user first (card {card}); resolve again once it is settled"
            )));
        }
        Gate::Never(why) => return Err(refuse(why)),
    }
    // a field only the user sets stays the user's: an agent may keep the graph's version, not the file's
    if keep_file && merge::touches_user_only(&c.file) {
        return Err(refuse(
            "the file's text changes a field only the user may set; the user resolves it",
        ));
    }
    let keep = if keep_file { Keep::File } else { Keep::Graph };
    let (r, events) = resolve_core(db, &f.core.records, &id, keep).await?;
    for e in events {
        let (name, body) = e.parts();
        f.broadcast(name, body);
    }
    Ok(json!(r).to_string())
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
            self.import_heard(only, dry).await.0
        }
        async fn import_heard(
            &self,
            only: Option<RecordKind>,
            dry: bool,
        ) -> (ImportReport, Vec<ViewEvent>) {
            let heard = Arc::new(Mutex::new(Vec::new()));
            let h = heard.clone();
            let emit = move |e: ViewEvent| h.lock().unwrap().push(e);
            let r = import_core(
                &self.db,
                &self.views,
                &self.hub,
                &self.root,
                only,
                dry,
                &emit,
            )
            .await
            .unwrap();
            let heard = heard.lock().unwrap().clone();
            (r, heard)
        }
        async fn sync(&self, p: &Path) -> Flush {
            self.views.sync(&self.db, p).await.unwrap().0
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
            assert_eq!(written, text, "{rel}: adopting rewrites nothing");
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
        // the first adoption copies the graph store too, a readable SQLite file
        assert!(
            rusqlite_open(&b.join("work.db")) > 0,
            "the store copy has its tables"
        );
        // opening Work imports every time: a second import with nothing new backs nothing up (a backup of every
        // record file per open would fill the disk), and one with a new file backs up again, never over the first
        let r2 = f.import(None, false).await;
        assert!(r2.backup.is_none(), "{:?}", r2.backup);
        std::fs::create_dir_all(f.root.join("docs/specs")).unwrap();
        std::fs::write(f.root.join("docs/specs/new.md"), "# New spec\n\nText.\n").unwrap();
        let r3 = f.import(None, false).await;
        assert_ne!(r3.backup.unwrap(), b.to_string_lossy());
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

    // ---- statuses, files that follow the graph, hand edits and conflicts ----

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

    /// A task's `data.ledger` (as text), or "none".
    async fn ledger_of(f: &Fix, number: &'static str) -> String {
        f.db.read(move |c| {
            Ok(c.query_row(
                "select coalesce(json_extract(data, '$.ledger'), 'none') from entity \
                 where kind = 'task' and json_extract(data, '$.number') = ?1 and retired_tx is null \
                 and json_extract(data, '$.records.file') like '%/pair.md'",
                [number],
                |r| r.get::<_, String>(0),
            )?)
        })
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn a_ledger_marks_its_plans_tasks_without_ticking_the_plan() {
        let f = fix();
        let plan = "# Pair\n\n### Task 1: one\n\n- [ ] a\n\n### Task 2: two\n\n- [x] b\n\n### Task 3: three\n\n- [ ] c\n";
        let ledger = "# SDD ledger — plan: pair.md\nTask 1: complete (commit abc1234, tests ok)\nTask 2: complete (commits 1111111..2222222)\n";
        let (pp, lp) = (
            f.root.join("docs/plans/drgnx/pair.md"),
            f.root.join("docs/plans/drgnx/pair.ledger.md"),
        );
        std::fs::write(&pp, plan).unwrap();
        std::fs::write(&lp, ledger).unwrap();
        f.import(Some(RecordKind::Plans), false).await;
        f.import(Some(RecordKind::Ledgers), false).await;
        // task 1: the ledger is ahead of its unchecked steps; task 2: both agree; task 3: unmarked
        let one: Value = serde_json::from_str(&ledger_of(&f, "1").await).unwrap();
        assert_eq!(one["done"], true);
        assert_eq!(one["ahead"], true);
        assert_eq!(one["commits"], json!(["abc1234"]));
        let two: Value = serde_json::from_str(&ledger_of(&f, "2").await).unwrap();
        assert_eq!(
            (two["done"].clone(), two["ahead"].clone()),
            (json!(true), json!(false))
        );
        assert_eq!(two["commits"], json!(["1111111", "2222222"]));
        assert_eq!(ledger_of(&f, "3").await, "none");
        // the ledger never ticks the plan's boxes, and a second import changes nothing
        assert_eq!(std::fs::read_to_string(&pp).unwrap(), plan);
        let again = f.import(None, false).await;
        assert!(
            again
                .files
                .iter()
                .filter(|r| r.path.contains("/pair"))
                .all(|r| r.ops == 0),
            "{again:?}"
        );
        // the ledger loses its first line: that task has no mark any more, found by a sync of the ledger alone
        std::fs::write(
            &lp,
            "# SDD ledger — plan: pair.md\nTask 2: complete (commits 1111111..2222222)\n",
        )
        .unwrap();
        f.sync(&lp).await;
        assert_eq!(ledger_of(&f, "1").await, "none");
        assert_ne!(ledger_of(&f, "2").await, "none");
    }

    /// The live `implements` links: (commit id, task title, origin, source).
    async fn implements_of(f: &Fix) -> Vec<(String, String, String, String)> {
        f.db.read(|c| {
            let mut st = c.prepare(
                "select a.id, t.title, l.origin, l.source from link l join entity a on a.n = l.src \
                 join entity t on t.n = l.dst where l.kind = 'implements' and l.tx_to = ?1 \
                 and a.retired_tx is null and t.retired_tx is null",
            )?;
            Ok(st
                .query_map([urdr::graph::schema::SENTINEL], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                })?
                .collect::<Result<Vec<_>, _>>()?)
        })
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn a_ledgers_commits_become_implements_links_of_the_importers_task() {
        let f = fix();
        let repo = f.root.clone();
        let git = |args: &[&str]| {
            let o = std::process::Command::new("git")
                .arg("-C")
                .arg(&repo)
                .args(["-c", "user.name=t", "-c", "user.email=t@t.invalid"])
                .args(args)
                .output()
                .unwrap();
            assert!(o.status.success(), "git {args:?}: {o:?}");
            String::from_utf8_lossy(&o.stdout).trim().to_owned()
        };
        git(&["init", "-q"]);
        std::fs::write(repo.join("a"), "1").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", "first"]);
        let first = git(&["rev-parse", "HEAD"]);
        std::fs::write(repo.join("a"), "2").unwrap();
        git(&["commit", "-q", "-am", "second"]);
        let second = git(&["rev-parse", "HEAD"]);
        let plan = "# Pair\n\n### Task 1: one\n\n- [ ] a\n\n### Task 2: two\n\n- [ ] b\n";
        let ledger = format!(
            "# SDD ledger — plan: pair.md\nTask 1: complete (commits {}..{}, tests ok)\n",
            &first[..9],
            &second[..9]
        );
        let (pp, lp) = (
            f.root.join("docs/plans/drgnx/pair.md"),
            f.root.join("docs/plans/drgnx/pair.ledger.md"),
        );
        std::fs::write(&pp, plan).unwrap();
        std::fs::write(&lp, &ledger).unwrap();
        f.import(Some(RecordKind::Plans), false).await;
        f.import(Some(RecordKind::Ledgers), false).await;
        // the range A..B is the commits after A up to B: the second commit, on task 1, from the ledger
        let got = implements_of(&f).await;
        assert_eq!(got.len(), 1, "{got:?}");
        assert_eq!(got[0].0, format!("commit:{second}"));
        assert!(got[0].1.starts_with("1 "), "{got:?}");
        assert_eq!(got[0].2, "inferred");
        assert_eq!(got[0].3, lp.to_string_lossy());
        // a second import asks nothing and changes nothing
        f.import(None, false).await;
        assert_eq!(implements_of(&f).await.len(), 1);
        // the ledger no longer names it: the link goes
        std::fs::write(&lp, "# SDD ledger — plan: pair.md\n").unwrap();
        f.sync(&lp).await;
        assert!(implements_of(&f).await.is_empty());
    }

    /// The head of the plan `pair.md`'s `data.git`, as text (or "none").
    async fn git_of(f: &Fix) -> String {
        f.db.read(|c| {
            Ok(c.query_row(
                "select coalesce(json_extract(data, '$.git'), 'none') from entity \
                 where kind = 'plan' and json_extract(data, '$.records.role') = 'head' \
                 and json_extract(data, '$.records.file') like '%/pair.md'",
                [],
                |r| r.get::<_, String>(0),
            )?)
        })
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn a_ledger_in_a_linked_worktree_gives_its_plan_the_branch_and_whether_it_is_merged() {
        let f = fix();
        let repo = f.root.clone();
        let git = |dir: &Path, args: &[&str]| {
            let o = std::process::Command::new("git")
                .arg("-C")
                .arg(dir)
                .args(["-c", "user.name=t", "-c", "user.email=t@t.invalid"])
                .args(args)
                .output()
                .unwrap();
            assert!(o.status.success(), "git {args:?}: {o:?}");
        };
        git(&repo, &["init", "-q", "-b", "main"]);
        std::fs::write(repo.join("a"), "1").unwrap();
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-q", "-m", "first"]);
        let wt = f.root.parent().unwrap().join("wt");
        git(
            &repo,
            &["worktree", "add", "-q", "-b", "feat", wt.to_str().unwrap()],
        );
        let dir = wt.join("docs/plans/drgnx");
        std::fs::create_dir_all(&dir).unwrap();
        let (pp, lp) = (dir.join("pair.md"), dir.join("pair.ledger.md"));
        std::fs::write(&pp, "# Pair\n\n### Task 1: one\n\n- [ ] a\n").unwrap();
        std::fs::write(&lp, "# SDD ledger — plan: pair.md\n").unwrap();
        let heard = |_e: ViewEvent| {};
        import_core(
            &f.db,
            &f.views,
            &f.hub,
            &wt,
            Some(RecordKind::Plans),
            false,
            &heard,
        )
        .await
        .unwrap();
        import_core(
            &f.db,
            &f.views,
            &f.hub,
            &wt,
            Some(RecordKind::Ledgers),
            false,
            &heard,
        )
        .await
        .unwrap();
        let g: Value = serde_json::from_str(&git_of(&f).await).unwrap();
        assert_eq!(g["branch"], "feat");
        assert_eq!(g["merged"], false, "{g}");
        assert!(
            g["worktree"].as_str().is_some_and(|w| w.ends_with("/wt")),
            "{g}"
        );
        let on = f
            .count(
                "select count(*) from link l join entity b on b.n = l.dst join entity a on a.n = l.src \
                 where l.kind = 'on_branch' and l.tx_to = 4611686018427387904 and b.kind = 'branch' \
                 and b.title = 'feat' and json_extract(a.data, '$.records.file') like '%/pair.md'",
            )
            .await;
        assert_eq!(on, 1);
        // every task done by the ledger, and feat has nothing main lacks: merged
        std::fs::write(
            &lp,
            "# SDD ledger — plan: pair.md\nTask 1: complete (tests ok)\n",
        )
        .unwrap();
        f.sync(&lp).await;
        let g: Value = serde_json::from_str(&git_of(&f).await).unwrap();
        assert_eq!(g["merged"], true, "{g}");
        // a commit on feat that main lacks: not merged
        std::fs::write(wt.join("b"), "2").unwrap();
        git(&wt, &["add", "-A"]);
        git(&wt, &["commit", "-q", "-m", "more"]);
        f.sync(&lp).await;
        let g: Value = serde_json::from_str(&git_of(&f).await).unwrap();
        assert_eq!(g["merged"], false, "{g}");
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
        assert!(matches!(f.sync(&p).await, Flush::Written(_)));
        let t = std::fs::read_to_string(&p).unwrap();
        assert!(t.contains("bold** text | open |"), "{t}");
        // the other rows are as they were, and the file imports back to the same graph
        assert!(t.contains("| fixed in M2 |"));
        let again = f.import(Some(RecordKind::Deferred), false).await;
        assert!(again.files.iter().all(|x| x.ops == 0), "{again:?}");
    }

    fn rusqlite_open(p: &Path) -> i64 {
        let c = urdr::Connection::open(p).unwrap();
        c.query_row(
            "select count(*) from sqlite_master where type = 'table'",
            [],
            |r| r.get(0),
        )
        .unwrap()
    }

    async fn row_body(f: &Fix, like: &'static str) -> String {
        f.db.read(move |c| {
            Ok(c.query_row(
                "select body from entity where kind = 'todo' and title like ?1 and retired_tx is null",
                [like],
                |r| r.get::<_, String>(0),
            )?)
        })
        .await
        .unwrap()
    }

    async fn conflicts(f: &Fix, p: &Path) -> Vec<String> {
        status_core(&f.db, &f.views, Some(p))
            .await
            .unwrap()
            .views
            .into_iter()
            .flat_map(|v| v.conflicts)
            .collect()
    }

    async fn row_id(f: &Fix, like: &'static str) -> String {
        f.db.read(move |c| {
            Ok(c.query_row(
                "select id from entity where kind = 'todo' and title like ?1 and retired_tx is null",
                [like],
                |r| r.get::<_, String>(0),
            )?)
        })
        .await
        .unwrap()
    }

    fn closed() -> Changes {
        Changes {
            status: Some(Some("open".into())),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn a_hand_edit_survives_a_regeneration() {
        let f = fix();
        let p = imported(&f).await;
        // someone edits a row in the file while the graph reopens another
        edit(
            &p,
            "Retry budget is hard-coded",
            "Retry budget is a setting",
        );
        set_row(&f, "M2-1%", closed()).await;
        assert!(matches!(f.sync(&p).await, Flush::Written(_)));
        let t = std::fs::read_to_string(&p).unwrap();
        assert!(
            t.contains("Retry budget is a setting"),
            "the hand edit stays: {t}"
        );
        assert!(
            t.contains("bold** text | open |"),
            "the graph's change lands: {t}"
        );
        assert!(
            row_body(&f, "M1-2%").await.contains("is a setting"),
            "the graph took the edit"
        );
        assert!(conflicts(&f, &p).await.is_empty());
        // and nothing more to do
        assert_eq!(f.sync(&p).await, Flush::Unchanged);
    }

    #[tokio::test]
    async fn two_writers_on_different_pieces_lose_nothing() {
        let f = fix();
        let p = imported(&f).await;
        // a file writer adds a row while the graph closes another
        edit(
            &p,
            "| M2-1 |",
            "| M1-3 | sync | A row added by hand | open |\n| M2-1 |",
        );
        set_row(&f, "M2-1%", closed()).await;
        f.sync(&p).await;
        let t = std::fs::read_to_string(&p).unwrap();
        assert!(
            t.contains("| M1-3 | sync | A row added by hand | open |"),
            "{t}"
        );
        assert!(t.contains("bold** text | open |"), "{t}");
        assert_eq!(
            row_status(&f, "M1-3%").await,
            "open",
            "the new row is a record"
        );
        // the file changes again between the merge's read and its write: the merge starts over and keeps it
        set_row(&f, "M1-1%", closed()).await;
        let late = p.clone();
        lock(&f.views.state).before_write = Some(Arc::new(move |_| {
            let t = std::fs::read_to_string(&late).unwrap();
            if !t.contains("written meanwhile") {
                std::fs::write(
                    &late,
                    t.replace("Closing note", "Closing note written meanwhile"),
                )
                .unwrap();
            }
        }));
        assert!(matches!(f.sync(&p).await, Flush::Written(_)));
        let t = std::fs::read_to_string(&p).unwrap();
        assert!(
            t.contains("written meanwhile"),
            "the late edit is kept: {t}"
        );
        assert!(
            t.contains("shown as `a\\|b` | open |"),
            "the graph's change too: {t}"
        );
    }

    #[tokio::test]
    async fn the_same_piece_on_both_sides_keeps_the_file_and_flags_it() {
        let f = fix();
        let p = imported(&f).await;
        // (a one-line row: the graph's status reaches its text)
        set_row(&f, "M1-1%", closed()).await;
        let mine = edit(&p, "A failed `measure`", "A failed measure, edited by hand");
        let (_, _, flagged) = f.views.sync_flagged(&f.db, &p).await.unwrap();
        assert_eq!(flagged.len(), 1, "the new conflict is told once");
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            mine,
            "the file's text is kept"
        );
        let id = row_id(&f, "M1-1%").await;
        assert_eq!(conflicts(&f, &p).await, std::slice::from_ref(&id));
        assert!(
            row_body(&f, "M1-1%").await.contains("A failed `measure`"),
            "the graph keeps its own"
        );
        let c = conflict_of(&f.db, &id).await.unwrap();
        assert!(
            c.file.contains("edited by hand") && c.graph.contains("| open |"),
            "{c:?}"
        );
        // a second sync changes nothing, loses nothing and tells nothing again
        assert!(f.views.sync_flagged(&f.db, &p).await.unwrap().2.is_empty());
        assert_eq!(std::fs::read_to_string(&p).unwrap(), mine);
        // keep the graph's: written back into the file, flag cleared
        resolve_core(&f.db, &f.views, &id, Keep::Graph)
            .await
            .unwrap();
        let t = std::fs::read_to_string(&p).unwrap();
        assert!(
            t.contains("A failed `measure`") && t.contains("`a\\|b` | open |"),
            "{t}"
        );
        assert!(conflicts(&f, &p).await.is_empty());
        // again, and keep the file's this time
        set_row(
            &f,
            "M1-1%",
            Changes {
                status: Some(Some("done".into())),
                ..Default::default()
            },
        )
        .await;
        edit(&p, "A failed `measure`", "A failed thing, the file wins");
        f.sync(&p).await;
        assert_eq!(conflicts(&f, &p).await, std::slice::from_ref(&id));
        resolve_core(&f.db, &f.views, &id, Keep::File)
            .await
            .unwrap();
        assert!(row_body(&f, "M1-1%").await.contains("the file wins"));
        assert!(
            std::fs::read_to_string(&p)
                .unwrap()
                .contains("the file wins")
        );
        assert!(conflicts(&f, &p).await.is_empty());
    }

    #[tokio::test]
    async fn a_stale_editor_save_is_flagged_not_applied() {
        let f = fix();
        let p = imported(&f).await;
        let old = std::fs::read_to_string(&p).unwrap();
        set_row(&f, "M2-1%", closed()).await;
        assert!(matches!(f.sync(&p).await, Flush::Written(_)));
        // an editor that loaded the file before that write saves it
        std::fs::write(&p, &old).unwrap();
        f.sync(&p).await;
        assert_eq!(
            row_status(&f, "M2-1%").await,
            "open",
            "the graph's change is not undone"
        );
        assert_eq!(conflicts(&f, &p).await, [row_id(&f, "M2-1%").await]);
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            old,
            "the file is kept"
        );
    }

    #[tokio::test]
    async fn an_insert_in_the_middle_of_a_plan_keeps_every_id_and_link() {
        let f = fix();
        f.import(None, false).await;
        let p = f.root.join("docs/plans/drgnx/p.md");
        const IDS: &str =
            "select id from entity where kind = 'task' and retired_tx is null order by id";
        const LINKS: &str =
            "select count(*) from link where kind = 'parent_of' and tx_to = 4611686018427387904"; // urdr's SENTINEL, 1 << 62
        async fn ids(f: &Fix) -> Result<Vec<String>, norn::store::CoordError> {
            f.db.read(|c| {
                let mut st = c.prepare(IDS)?;
                Ok(st
                    .query_map([], |r| r.get::<_, String>(0))?
                    .collect::<Result<Vec<_>, _>>()?)
            })
            .await
        }
        let before: Vec<String> = ids(&f).await.unwrap();
        let links = f.count(LINKS).await;
        edit(
            &p,
            "## Task 1: `basket`",
            "## Task 0b: a task added in the middle\n\n- [ ] **Step 1: do it**\n\n## Task 1: `basket`",
        );
        f.sync(&p).await;
        let after: Vec<String> = ids(&f).await.unwrap();
        assert_eq!(after.len(), before.len() + 1);
        assert!(
            before.iter().all(|i| after.contains(i)),
            "every task keeps its id"
        );
        assert_eq!(f.count(LINKS).await, links + 1);
    }

    #[tokio::test]
    async fn adoption_alone_writes_no_byte() {
        let f = fix();
        let stamp = |f: &Fix| -> Vec<(String, std::time::SystemTime)> {
            FILES
                .iter()
                .map(|(rel, _)| {
                    let p = f.root.join(rel);
                    (
                        std::fs::read_to_string(&p).unwrap(),
                        std::fs::metadata(&p).unwrap().modified().unwrap(),
                    )
                })
                .collect()
        };
        let before = stamp(&f);
        let (r, heard) = f.import_heard(None, false).await;
        assert_eq!(stamp(&f), before);
        // the notice went out once, listing the files, with the backup
        let notices: Vec<&RecordsNotice> = heard
            .iter()
            .filter_map(|e| match e {
                ViewEvent::Notice(n) => Some(n),
                _ => None,
            })
            .collect();
        assert_eq!(notices.len(), 1);
        assert_eq!(notices[0].files.len(), r.files.len());
        assert_eq!(notices[0].backup, r.backup);
        let (_, again) = f.import_heard(None, false).await;
        assert!(again.is_empty(), "{again:?}");
    }

    #[tokio::test]
    async fn no_rewrite_before_the_notice() {
        let f = fix();
        let p = imported(&f).await;
        kv_put(&f.db, vec![(adopted_key(&p), None)]).await.unwrap();
        let before = std::fs::read_to_string(&p).unwrap();
        set_row(&f, "M2-1%", closed()).await;
        assert_eq!(f.sync(&p).await, Flush::Waiting);
        assert_eq!(std::fs::read_to_string(&p).unwrap(), before);
    }

    #[tokio::test]
    async fn a_hub_restart_reads_its_own_writes_as_its_own() {
        let f = fix();
        let p = imported(&f).await;
        set_row(&f, "M2-1%", closed()).await;
        assert!(matches!(f.sync(&p).await, Flush::Written(_)));
        let written = std::fs::read_to_string(&p).unwrap();
        // a new hub: the bases come from the store
        let fresh = Views::default();
        assert_eq!(fresh.sync(&f.db, &p).await.unwrap().0, Flush::Unchanged);
        assert_eq!(std::fs::read_to_string(&p).unwrap(), written);
        assert!(conflicts(&f, &p).await.is_empty());
        assert!(!fresh.changed(&p));
    }
}
