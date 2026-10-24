//! Records (Tasks 14, 14b; `docs/develop/records.md`): the importer (a backup of every file first, then `saga`'s
//! graph operations with `Origin::Imported`) and the views — written atomically at the imported file's path after
//! every change of the records they show (debounced 2 s), never committed, never over a hand edit: a changed view
//! becomes a proposal (`records/proposals`, `records/decide`) and is not rewritten while one is open.

use crate::agent_core::not_yet;
use crate::coord::fail;
use crate::dispatch::Caller;
use crate::front::Front;
use norn::store::CoordDb;
use runstav::methods::records::{
    ByPath, DecideParams, Decided, ImportParams, ImportReport, ImportedFile, Proposals, RecordKind,
    ViewStatus, ViewWritten, Views as ViewsAnswer,
};
use runstav::wire::{Error, ErrorCode};
use saga::import::{self, AnyDoc, GraphOp};
use saga::view::{self, ViewModel};
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
    /// The file was changed by hand: it is not overwritten (Task 14b turns it into a proposal; until then a hold).
    Held,
}

#[derive(Default)]
struct State {
    /// Path -> (hash of the text the hub last wrote, when).
    written: HashMap<PathBuf, (String, f64)>,
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
    json!({"records": r})
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
            apply_acts(acts, &ops, &data, Some(tx))
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

/// The pieces of the file at PATH from the graph, in order: its kind, its head entity and the model.
async fn model(
    db: &CoordDb,
    path: &Path,
) -> Result<Option<(RecordKind, String, ViewModel)>, Error> {
    let key = import::source_key(path);
    let rows: Vec<(String, String, Option<String>)> = db
        .read(move |c| {
            let mut st = c.prepare(
                "select id, data, body from entity where source = ?1 and retired_tx is null \
                 order by json_extract(data, '$.records.seq')",
            )?;
            let rows = st
                .query_map([&key], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .map_err(fail)?;
    let Some((id, data, _)) = rows.first() else {
        return Ok(None);
    };
    let data: Value = serde_json::from_str(data).unwrap_or_default();
    let Some(kind) = data["records"]["kind"].as_str().and_then(kind_of) else {
        return Ok(None);
    };
    let parts = rows
        .iter()
        .map(|r| r.2.clone().unwrap_or_default())
        .collect();
    Ok(Some((kind, id.clone(), ViewModel { parts })))
}

/// TEXT to PATH: a temporary file beside it, then a rename.
pub fn write_atomic(path: &Path, text: &str) -> std::io::Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".drgnx-tmp");
    let tmp = PathBuf::from(tmp);
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path)
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

    fn record(&self, path: &Path, hash: &str) {
        lock(&self.state)
            .written
            .insert(path.to_path_buf(), (hash.to_owned(), now()));
    }

    /// The view at PATH rewritten from the graph now, unless the file was changed by hand (FORCE: after an import,
    /// when the file was just read and backed up).
    pub async fn flush(&self, db: &CoordDb, path: &Path, force: bool) -> Result<Flush, Error> {
        let Some((_, _, m)) = model(db, path).await? else {
            return Ok(Flush::Unchanged);
        };
        let text = view::file_text(path, &m);
        let hash = view::digest(&text);
        let current = std::fs::read_to_string(path).ok();
        if current.as_deref() == Some(text.as_str()) {
            self.record(path, &hash);
            return Ok(Flush::Unchanged);
        }
        let known = lock(&self.state).written.contains_key(path);
        let by_hand = if known {
            self.changed(path)
        } else {
            current.is_some()
        };
        if by_hand && !force {
            return Ok(Flush::Held);
        }
        write_atomic(path, &text).map_err(|e| err(format!("{}: {e}", path.display())))?;
        self.record(path, &hash);
        Ok(Flush::Written(hash))
    }

    /// The records behind the view at PATH changed: rewrite it after [`DEBOUNCE`] of quiet.  EMIT hears each write.
    pub fn on_change(
        &self,
        db: CoordDb,
        path: PathBuf,
        emit: Arc<dyn Fn(ViewWritten) + Send + Sync>,
    ) {
        let me = self.clone();
        let p = path.clone();
        let h = tokio::spawn(async move {
            tokio::time::sleep(DEBOUNCE).await;
            if let Ok(Flush::Written(hash)) = me.flush(&db, &p, false).await
                && let Ok(Some((kind, _, _))) = model(&db, &p).await
            {
                emit(ViewWritten {
                    path: p.to_string_lossy().into_owned(),
                    kind,
                    hash,
                });
            }
        });
        if let Some(old) = lock(&self.state).timers.insert(path, h) {
            old.abort();
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
        out.push(ViewStatus {
            path: file.to_owned(),
            kind,
            entity: id,
            written: last.as_ref().map(|l| l.1),
            hash: last.map(|l| l.0),
            changed,
            pending: None,
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

pub async fn proposals(_: &Front, _: &Caller, _: ByPath) -> Result<Proposals, Error> {
    Err(not_yet("records/proposals", "14b"))
}

pub async fn decide(_: &Front, _: &Caller, _: DecideParams) -> Result<Decided, Error> {
    Err(not_yet("records/decide", "14b"))
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
        assert_eq!(f.views.flush(&f.db, &p, false).await.unwrap(), Flush::Held);
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
}
