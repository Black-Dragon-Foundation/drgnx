//! JSONL export and idempotent import (Task 7; storage §8.2). The caller's ALLOW filters every entity (norn's
//! deny-list: door 5 for export, door 2 for import), and on export the tx log: a tx that wrote a version of an entity
//! ALLOW refuses, or a link at one, leaves no line.
//!
//! An export directory holds `entities.jsonl` and `links.jsonl` (current state: one object per line, sorted by id,
//! keys in a fixed order, no database-local numbers), `tx.jsonl` (append-only; `since` limits it), and on request
//! `history.jsonl`, and with activity `link_stat.jsonl`. Entities are the authored ones (`recorded`, `imported`);
//! parsed entities are rebuilt from their files and inferred rows are activity (with `kind = "session"` entities and
//! `touched` links).

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::backup::tmp_of;
use super::entity::{self, COLS, Ent, EntityNew, Origin, from_row};
use super::guard;
use super::link;
use super::pool::ReadPool;
use super::schema::SENTINEL;
use super::search::fts_put;
use super::tx::{Class, Tx, TxMeta};
use super::writer::{WriteError, WriterHandle};

/// The caller's filter: true lets the entity through.
pub type Allow = Arc<dyn Fn(&Ent) -> bool + Send + Sync>;

/// What an export writes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Opts {
    /// `tx.jsonl` from this tx on (else all).
    pub since: Option<i64>,
    /// Also `history.jsonl`.
    pub history: bool,
    /// Also `touched` links, `link_stat` and sessions.
    pub with_activity: bool,
}

/// What an export or an import did.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub dir: PathBuf,
    pub entities: u64,
    pub links: u64,
    pub txs: u64,
    /// Filtered out by ALLOW, or (import) already present at that version or later.
    pub skipped: u64,
    /// Import: `(line, why)` of the records refused (`why` names the file).
    pub refused: Vec<(u64, String)>,
    pub error: Option<String>,
}

/// An entity as a line. Field order is the line's key order.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct EntLine {
    id: String,
    kind: String,
    project: Option<i64>,
    title: Option<String>,
    status: Option<String>,
    body: Option<String>,
    priority: Option<i64>,
    assignee: Option<String>,
    data: Value,
    origin: Origin,
    source: Option<String>,
    ver: i64,
}

impl EntLine {
    fn of(e: &Ent) -> EntLine {
        EntLine {
            id: e.id.clone(),
            kind: e.kind.clone(),
            project: e.project,
            title: e.title.clone(),
            status: e.status.clone(),
            body: e.body.clone(),
            priority: e.priority,
            assignee: e.assignee.clone(),
            data: e.data.clone(),
            origin: e.origin,
            source: e.source.clone(),
            ver: e.ver,
        }
    }

    /// The line as an entity (for ALLOW); `n` and the tx numbers are not the line's.
    fn as_ent(&self) -> Ent {
        Ent {
            n: 0,
            id: self.id.clone(),
            kind: self.kind.clone(),
            project: self.project,
            title: self.title.clone(),
            status: self.status.clone(),
            body: self.body.clone(),
            priority: self.priority,
            assignee: self.assignee.clone(),
            lease: Default::default(),
            data: self.data.clone(),
            field_tx: BTreeMap::new(),
            origin: self.origin,
            source: self.source.clone(),
            ver: self.ver,
            created_tx: 0,
            updated_tx: 0,
            retired_tx: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct LinkLine {
    src: String,
    kind: String,
    dst: String,
    data: Option<Value>,
    origin: Origin,
    source: Option<String>,
}

#[derive(Serialize)]
struct StatLine {
    src: String,
    kind: String,
    dst: String,
    count: i64,
    first_tx: i64,
    last_tx: i64,
}

#[derive(Serialize)]
struct TxLine {
    id: i64,
    at: f64,
    actor: String,
    class: String,
    session: Option<String>,
    profile: Option<String>,
    job: Option<String>,
    project: Option<i64>,
    tool: Option<String>,
    req: Option<String>,
    state: String,
    reverts: Option<i64>,
    imported: i64,
    note: Option<String>,
}

#[derive(Serialize)]
struct HistLine {
    id: String,
    ver: i64,
    tx_from: i64,
    tx_to: i64,
    kind: Option<String>,
    project: Option<i64>,
    title: Option<String>,
    status: Option<String>,
    body: Option<String>,
    priority: Option<i64>,
    assignee: Option<String>,
    data: Value,
}

/// Removes the half-written directory unless the export finished (also when ALLOW panics).
struct Scratch {
    path: PathBuf,
    armed: bool,
}

impl Drop for Scratch {
    fn drop(&mut self) {
        if self.armed {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }
}

struct Lines {
    w: BufWriter<File>,
    count: u64,
}

impl Lines {
    fn create(dir: &Path, name: &str) -> std::io::Result<Lines> {
        Ok(Lines {
            w: BufWriter::new(File::create(dir.join(name))?),
            count: 0,
        })
    }

    fn put<T: Serialize>(&mut self, line: &T) -> Result<(), String> {
        serde_json::to_writer(&mut self.w, line).map_err(|e| e.to_string())?;
        self.w.write_all(b"\n").map_err(|e| e.to_string())?;
        self.count += 1;
        Ok(())
    }

    fn finish(self) -> Result<u64, String> {
        let file = self.w.into_inner().map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        Ok(self.count)
    }
}

fn json_text(text: Option<String>) -> Value {
    text.and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null)
}

/// The files an export directory holds.
const EXPORT_FILES: [&str; 5] = [
    "entities.jsonl",
    "links.jsonl",
    "tx.jsonl",
    "history.jsonl",
    "link_stat.jsonl",
];

/// Whether an export may replace or remove PATH (DIR, `DIR.tmp` or `DIR.old`): when nothing is there, or a folder
/// (not a link) that holds only an export's files (an earlier export, a crashed one's `.tmp`, an empty folder).
/// Anything else is refused: an export never deletes what it did not write.
fn replaceable(path: &Path) -> Result<(), String> {
    let refuse = |why: String| {
        Err(format!(
            "{} {why}: an export replaces only an earlier export; name a new or an empty folder",
            path.display()
        ))
    };
    match std::fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("{}: {e}", path.display())),
        Ok(m) if !m.is_dir() => return refuse("is not a folder".into()),
        Ok(_) => {}
    }
    let entries = std::fs::read_dir(path).map_err(|e| format!("{}: {e}", path.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("{}: {e}", path.display()))?;
        let name = entry.file_name();
        let ours = name.to_str().is_some_and(|n| EXPORT_FILES.contains(&n))
            && entry.file_type().is_ok_and(|t| t.is_file());
        if !ours {
            return refuse(format!("holds {}", name.to_string_lossy()));
        }
    }
    Ok(())
}

fn export_sync(
    conn: &rusqlite::Connection,
    dir: &Path,
    opts: &Opts,
    allow: &Allow,
) -> Result<Report, String> {
    let io = |e: std::io::Error| e.to_string();
    let sql = |e: rusqlite::Error| e.to_string();
    let tmp = tmp_of(dir);
    let old = {
        let mut name = dir.file_name().unwrap_or_default().to_os_string();
        name.push(".old");
        dir.with_file_name(name)
    };
    for path in [dir, &tmp, &old] {
        replaceable(path)?;
    }
    // Only the folders made here are made private: an existing parent keeps its mode.
    if let Some(parent) = dir.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)
            .map_err(io)?;
    }
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&tmp)
        .map_err(io)?;
    let mut scratch = Scratch {
        path: tmp.clone(),
        armed: true,
    };
    let mut report = Report {
        dir: dir.to_path_buf(),
        ..Report::default()
    };
    let read = conn.unchecked_transaction().map_err(sql)?;

    let (ent_extra, link_extra) = if opts.with_activity {
        (
            " or origin = 'inferred' or kind = 'session'",
            " or kind = 'touched' or origin = 'inferred'",
        )
    } else {
        ("", "")
    };

    // Entities, sorted by id; the allowed ones give the ids links and history refer to.
    let mut ids: HashMap<i64, String> = HashMap::new();
    let mut refused: Vec<i64> = Vec::new();
    let mut ents = Lines::create(&tmp, "entities.jsonl").map_err(io)?;
    let exported =
        format!("retired_tx is null and (origin in ('recorded', 'imported'){ent_extra})");
    {
        let mut stmt = read
            .prepare(&format!(
                "select {COLS} from entity where {exported} order by id"
            ))
            .map_err(sql)?;
        for ent in stmt.query_map([], from_row).map_err(sql)? {
            let ent = ent.map_err(sql)?;
            if !allow(&ent) {
                report.skipped += 1;
                refused.push(ent.n);
                continue;
            }
            ents.put(&EntLine::of(&ent))?;
            ids.insert(ent.n, ent.id);
        }
    }
    report.entities = ents.finish()?;
    // ALLOW is asked for the entities not exported too (parsed, retired): what it refuses keeps its txs out below.
    {
        let mut stmt = read
            .prepare(&format!("select {COLS} from entity where not ({exported})"))
            .map_err(sql)?;
        for ent in stmt.query_map([], from_row).map_err(sql)? {
            let ent = ent.map_err(sql)?;
            if !allow(&ent) {
                refused.push(ent.n);
            }
        }
    }
    // The txs that wrote a version of a refused entity, or a link at one: their notes may quote it (door 5).
    let mut hidden: HashSet<i64> = HashSet::new();
    {
        let mut stmt = read
            .prepare(&format!(
                "select created_tx from entity where n = ?1 union select updated_tx from entity where n = ?1 \
                 union select retired_tx from entity where n = ?1 and retired_tx is not null \
                 union select tx_from from entity_hist where n = ?1 \
                 union select tx_from from link where src = ?1 union select tx_from from link where dst = ?1 \
                 union select tx_to from link where src = ?1 and tx_to <> {SENTINEL} \
                 union select tx_to from link where dst = ?1 and tx_to <> {SENTINEL}"
            ))
            .map_err(sql)?;
        for n in &refused {
            for t in stmt.query_map([n], |r| r.get::<_, i64>(0)).map_err(sql)? {
                hidden.insert(t.map_err(sql)?);
            }
        }
    }

    // Links between exported entities, sorted by (src, kind, dst).
    let mut links: Vec<LinkLine> = Vec::new();
    {
        let mut stmt = read
            .prepare(&format!(
                "select src, kind, dst, data, origin, source from link where tx_to = {SENTINEL} \
                 and ((origin in ('recorded', 'imported') and kind <> 'touched'){link_extra})"
            ))
            .map_err(sql)?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, Option<String>>(5)?,
                ))
            })
            .map_err(sql)?;
        for row in rows {
            let (src, kind, dst, data, origin, source) = row.map_err(sql)?;
            let (Some(s), Some(d), Some(origin)) =
                (ids.get(&src), ids.get(&dst), Origin::parse(&origin))
            else {
                continue;
            };
            links.push(LinkLine {
                src: s.clone(),
                kind,
                dst: d.clone(),
                data: data.and_then(|t| serde_json::from_str(&t).ok()),
                origin,
                source,
            });
        }
    }
    links.sort_by(|a, b| (&a.src, &a.kind, &a.dst).cmp(&(&b.src, &b.kind, &b.dst)));
    let mut out = Lines::create(&tmp, "links.jsonl").map_err(io)?;
    for l in &links {
        out.put(l)?;
    }
    report.links = out.finish()?;

    // The tx log (append-only).
    let mut out = Lines::create(&tmp, "tx.jsonl").map_err(io)?;
    {
        let mut stmt = read
            .prepare(
                "select id, at, actor, class, session, profile, job, project, tool, req, state, reverts, \
                 imported, note from tx where id >= ?1 order by id",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map([opts.since.unwrap_or(0)], |r| {
                Ok(TxLine {
                    id: r.get(0)?,
                    at: r.get(1)?,
                    actor: r.get(2)?,
                    class: r.get(3)?,
                    session: r.get(4)?,
                    profile: r.get(5)?,
                    job: r.get(6)?,
                    project: r.get(7)?,
                    tool: r.get(8)?,
                    req: r.get(9)?,
                    state: r.get(10)?,
                    reverts: r.get(11)?,
                    imported: r.get(12)?,
                    note: r.get(13)?,
                })
            })
            .map_err(sql)?;
        for row in rows {
            let row = row.map_err(sql)?;
            if hidden.contains(&row.id) {
                continue;
            }
            out.put(&row)?;
        }
    }
    report.txs = out.finish()?;

    if opts.history {
        let mut out = Lines::create(&tmp, "history.jsonl").map_err(io)?;
        let mut by_id: Vec<(&String, &i64)> = ids.iter().map(|(n, id)| (id, n)).collect();
        by_id.sort();
        let mut stmt = read
            .prepare(
                "select ver, tx_from, tx_to, kind, project, title, status, body, priority, assignee, data \
                 from entity_hist where n = ?1 order by ver",
            )
            .map_err(sql)?;
        for (id, n) in by_id {
            let rows = stmt
                .query_map([n], |r| {
                    Ok(HistLine {
                        id: id.clone(),
                        ver: r.get(0)?,
                        tx_from: r.get(1)?,
                        tx_to: r.get(2)?,
                        kind: r.get(3)?,
                        project: r.get(4)?,
                        title: r.get(5)?,
                        status: r.get(6)?,
                        body: r.get(7)?,
                        priority: r.get(8)?,
                        assignee: r.get(9)?,
                        data: json_text(r.get(10)?),
                    })
                })
                .map_err(sql)?;
            for row in rows {
                out.put(&row.map_err(sql)?)?;
            }
        }
        out.finish()?;
    }

    if opts.with_activity {
        let mut stats: Vec<StatLine> = Vec::new();
        let mut stmt = read
            .prepare("select src, kind, dst, count, first_tx, last_tx from link_stat")
            .map_err(sql)?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, i64>(5)?,
                ))
            })
            .map_err(sql)?;
        for row in rows {
            let (src, kind, dst, count, first_tx, last_tx) = row.map_err(sql)?;
            if let (Some(s), Some(d)) = (ids.get(&src), ids.get(&dst)) {
                stats.push(StatLine {
                    src: s.clone(),
                    kind,
                    dst: d.clone(),
                    count,
                    first_tx,
                    last_tx,
                });
            }
        }
        stats.sort_by(|a, b| (&a.src, &a.kind, &a.dst).cmp(&(&b.src, &b.kind, &b.dst)));
        let mut out = Lines::create(&tmp, "link_stat.jsonl").map_err(io)?;
        for s in &stats {
            out.put(s)?;
        }
        out.finish()?;
    }
    drop(read);

    // Swap the finished directory in; an older export moves aside first and goes after.
    let _ = std::fs::remove_dir_all(&old);
    let had = dir.exists();
    if had {
        std::fs::rename(dir, &old).map_err(io)?;
    }
    if let Err(e) = std::fs::rename(&tmp, dir) {
        if had {
            let _ = std::fs::rename(&old, dir);
        }
        return Err(e.to_string());
    }
    scratch.armed = false;
    if had {
        let _ = std::fs::remove_dir_all(&old);
    }
    Ok(report)
}

/// Export into DIR (through `DIR.tmp`, then renamed; the folders it makes are 0700). DIR, `DIR.tmp` and `DIR.old`
/// must each be missing or hold only an export's files: anything else is refused before a file is written.
pub async fn export(pool: &ReadPool, dir: PathBuf, opts: Opts, allow: Allow) -> Report {
    let target = dir.clone();
    let done = pool
        .with(move |conn| export_sync(conn, &target, &opts, &allow))
        .await;
    match done {
        Ok(Ok(report)) => report,
        Ok(Err(e)) => Report {
            dir,
            error: Some(e),
            ..Report::default()
        },
        Err(e) => Report {
            dir,
            error: Some(e.to_string()),
            ..Report::default()
        },
    }
}

/// Records per import tx.
const CHUNK: usize = 500;

#[derive(Default, Serialize, Deserialize)]
struct ChunkOut {
    written: u64,
    skipped: u64,
    refused: Vec<(u64, String)>,
}

enum Outcome {
    Written,
    Skipped,
    Refused(String),
}

/// One entity record: absent → created (then its `ver` set to the record's); present at a lower `ver` → the
/// record's fields with the old row to `entity_hist`; at that `ver` or later, or retired → skipped. A different kind
/// under the same id is refused.
fn import_entity(tx: &mut Tx<'_>, rec: &EntLine) -> Result<Outcome, WriteError> {
    let Some(cur) = entity::by_id(tx.sql(), &rec.id)? else {
        entity::create(
            tx,
            EntityNew {
                id: rec.id.clone(),
                kind: rec.kind.clone(),
                project: rec.project,
                title: rec.title.clone(),
                status: rec.status.clone(),
                body: rec.body.clone(),
                priority: rec.priority,
                assignee: rec.assignee.clone(),
                data: rec.data.clone(),
                origin: rec.origin,
                source: rec.source.clone(),
            },
        )?;
        if rec.ver > 1 {
            tx.sql().execute(
                "update entity set ver = ?2 where id = ?1",
                params![rec.id, rec.ver],
            )?;
        }
        return Ok(Outcome::Written);
    };
    if cur.kind != rec.kind {
        return Ok(Outcome::Refused(format!(
            "{} is a {} here, the record says {}",
            rec.id, cur.kind, rec.kind
        )));
    }
    if cur.ver >= rec.ver || cur.retired_tx.is_some() {
        return Ok(Outcome::Skipped);
    }
    guard::check_entity(
        tx,
        &cur.kind,
        guard::Target {
            id: &cur.id,
            project: rec.project,
        },
    )?;
    let id = tx.id();
    let mut field_tx = cur.field_tx.clone();
    for (name, changed) in [
        ("project", rec.project != cur.project),
        ("title", rec.title != cur.title),
        ("status", rec.status != cur.status),
        ("body", rec.body != cur.body),
        ("priority", rec.priority != cur.priority),
        ("assignee", rec.assignee != cur.assignee),
        ("data", rec.data != cur.data),
    ] {
        if changed {
            field_tx.insert(name.to_string(), id);
        }
    }
    tx.sql().execute(
        "insert into entity_hist (n, ver, tx_from, tx_to, kind, project, title, status, body, priority, assignee, \
         data, field_tx, lease_holder, lease_epoch, lease_until, origin, retired_tx) \
         select n, ver, updated_tx, ?2, kind, project, title, status, body, priority, assignee, data, field_tx, \
         lease_holder, lease_epoch, lease_until, origin, retired_tx from entity where n = ?1",
        params![cur.n, id],
    )?;
    tx.sql().execute(
        "update entity set project = ?2, title = ?3, status = ?4, body = ?5, priority = ?6, assignee = ?7, \
         data = ?8, field_tx = ?9, ver = ?10, updated_tx = ?11 where n = ?1",
        params![
            cur.n,
            rec.project,
            rec.title,
            rec.status,
            rec.body,
            rec.priority,
            rec.assignee,
            rec.data.to_string(),
            serde_json::to_string(&field_tx).expect("a map of integers"),
            rec.ver,
            id,
        ],
    )?;
    if rec.title != cur.title || rec.body != cur.body {
        fts_put(tx, cur.n, rec.title.as_deref(), rec.body.as_deref())?;
    }
    Ok(Outcome::Written)
}

fn live_n(tx: &Tx<'_>, id: &str) -> Result<Option<i64>, WriteError> {
    Ok(tx
        .sql()
        .query_row(
            "select n from entity where id = ?1 and retired_tx is null",
            [id],
            |r| r.get(0),
        )
        .optional()?)
}

fn import_link(tx: &mut Tx<'_>, rec: &LinkLine) -> Result<Outcome, WriteError> {
    let (Some(src), Some(dst)) = (live_n(tx, &rec.src)?, live_n(tx, &rec.dst)?) else {
        return Ok(Outcome::Refused(format!(
            "link {} -{}-> {}: an end is missing here",
            rec.src, rec.kind, rec.dst
        )));
    };
    let added = link::add(
        tx,
        src,
        &rec.kind,
        dst,
        rec.data.clone(),
        rec.origin,
        rec.source.as_deref(),
    )?;
    Ok(if added.existed {
        Outcome::Skipped
    } else {
        Outcome::Written
    })
}

/// The records of FILE with their line numbers; a line that is not a record is refused.
fn read_lines<T: for<'de> Deserialize<'de>>(
    path: &Path,
    refused: &mut Vec<(u64, String)>,
) -> std::io::Result<Vec<(u64, T)>> {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let mut out = Vec::new();
    for (i, line) in BufReader::new(File::open(path)?).lines().enumerate() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let no = i as u64 + 1;
        match serde_json::from_str::<T>(&line) {
            Ok(rec) => out.push((no, rec)),
            Err(e) => refused.push((no, format!("{name}: {e}"))),
        }
    }
    Ok(out)
}

async fn run_chunks<T, F>(
    writer: &WriterHandle,
    records: Vec<(u64, T)>,
    file: &'static str,
    each: F,
    report: &mut Report,
) -> Result<(), WriteError>
where
    T: Send + 'static,
    F: Fn(&mut Tx<'_>, &T) -> Result<Outcome, WriteError> + Send + Sync + Clone + 'static,
{
    let mut records = records.into_iter().peekable();
    while records.peek().is_some() {
        let chunk: Vec<(u64, T)> = records.by_ref().take(CHUNK).collect();
        let each = each.clone();
        let mut meta = TxMeta::new("import", Class::System, "import");
        meta.imported = false;
        let out = writer
            .write(meta, move |tx| {
                let mut out = ChunkOut::default();
                for (line, rec) in &chunk {
                    match each(tx, rec) {
                        Ok(Outcome::Written) => out.written += 1,
                        Ok(Outcome::Skipped) => out.skipped += 1,
                        Ok(Outcome::Refused(why)) => {
                            out.refused.push((*line, format!("{file}: {why}")))
                        }
                        Err(WriteError::Refused(why)) => {
                            out.refused.push((*line, format!("{file}: {why}")))
                        }
                        Err(e) => return Err(e),
                    }
                }
                Ok(out)
            })
            .await?
            .value;
        if file == "entities.jsonl" {
            report.entities += out.written;
        } else {
            report.links += out.written;
        }
        report.skipped += out.skipped;
        report.refused.extend(out.refused);
    }
    Ok(())
}

/// Import DIR: idempotent by `id` and `ver`, one tx per 500 records (`actor: "import"`, `tool: "import"`). The
/// txs are class `system`, so a kind the guard reserves for the user is refused, line by line.
pub async fn import(writer: &WriterHandle, dir: PathBuf, allow: Allow) -> Report {
    let mut report = Report {
        dir: dir.clone(),
        ..Report::default()
    };
    let read = {
        let dir = dir.clone();
        let allow = Arc::clone(&allow);
        tokio::task::spawn_blocking(move || {
            let mut refused = Vec::new();
            let mut skipped = 0u64;
            let ents: Vec<(u64, EntLine)> =
                read_lines::<EntLine>(&dir.join("entities.jsonl"), &mut refused)?
                    .into_iter()
                    .filter(|(_, e)| {
                        let ok = allow(&e.as_ent());
                        if !ok {
                            skipped += 1;
                        }
                        ok
                    })
                    .collect();
            let links: Vec<(u64, LinkLine)> = match dir.join("links.jsonl") {
                p if p.exists() => read_lines(&p, &mut refused)?,
                _ => Vec::new(),
            };
            Ok::<_, std::io::Error>((ents, links, refused, skipped))
        })
        .await
    };
    let (ents, links, refused, skipped) = match read {
        Ok(Ok(x)) => x,
        Ok(Err(e)) => {
            report.error = Some(e.to_string());
            return report;
        }
        Err(e) => {
            report.error = Some(e.to_string());
            return report;
        }
    };
    report.refused = refused;
    report.skipped = skipped;
    let done = run_chunks(writer, ents, "entities.jsonl", import_entity, &mut report).await;
    let done = match done {
        Ok(()) => run_chunks(writer, links, "links.jsonl", import_link, &mut report).await,
        err => err,
    };
    if let Err(e) = done {
        report.error = Some(e.to_string());
    }
    report
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::entity::Changes;
    use crate::graph::writer::Writer;
    use crate::graph::writer::tests::{opts, rule};
    use serde_json::json;

    struct Db {
        _dir: tempfile::TempDir,
        root: PathBuf,
        w: Option<Writer>,
        h: WriterHandle,
        pool: ReadPool,
    }

    impl Drop for Db {
        fn drop(&mut self) {
            if let Some(w) = self.w.take() {
                w.shutdown();
            }
        }
    }

    fn db() -> Db {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_path_buf();
        let path = root.join("work.db");
        let (w, h) = Writer::spawn(&path, opts(256, 1), rule()).unwrap();
        let pool = ReadPool::open(&path, 2);
        Db {
            _dir: dir,
            root,
            w: Some(w),
            h,
            pool,
        }
    }

    fn all() -> Allow {
        Arc::new(|_| true)
    }

    fn meta() -> TxMeta {
        TxMeta::new("u", Class::User, "test")
    }

    async fn put(h: &WriterHandle, id: &str, kind: &str, title: &str, origin: Origin) -> i64 {
        let (id, kind, title) = (id.to_string(), kind.to_string(), title.to_string());
        h.write(meta(), move |tx| {
            Ok(entity::create(
                tx,
                EntityNew {
                    id,
                    kind,
                    project: None,
                    title: Some(title),
                    status: None,
                    body: Some("body".into()),
                    priority: None,
                    assignee: None,
                    data: json!({"k": 1}),
                    origin,
                    source: None,
                },
            )?
            .n)
        })
        .await
        .unwrap()
        .value
    }

    async fn join(h: &WriterHandle, a: i64, kind: &str, b: i64, origin: Origin) {
        let kind = kind.to_string();
        h.write(meta(), move |tx| {
            link::add(tx, a, &kind, b, None, origin, None)?;
            Ok(())
        })
        .await
        .unwrap();
    }

    async fn retitle(h: &WriterHandle, n: i64, title: &str) {
        let title = title.to_string();
        h.write(meta(), move |tx| {
            entity::update(
                tx,
                n,
                None,
                Changes {
                    title: Some(Some(title)),
                    ..Changes::default()
                },
            )?;
            Ok(())
        })
        .await
        .unwrap();
    }

    async fn seed(d: &Db) -> (i64, i64, i64) {
        let b = put(&d.h, "task:b", "task", "B", Origin::Recorded).await;
        let a = put(&d.h, "task:a", "task", "A", Origin::Recorded).await;
        let c = put(&d.h, "note:c", "note", "C", Origin::Recorded).await;
        put(&d.h, "spec:p", "spec", "parsed", Origin::Parsed).await;
        join(&d.h, a, "blocks", b, Origin::Recorded).await;
        join(&d.h, c, "about", a, Origin::Recorded).await;
        (a, b, c)
    }

    fn lines(dir: &Path, name: &str) -> Vec<String> {
        std::fs::read_to_string(dir.join(name))
            .unwrap()
            .lines()
            .map(String::from)
            .collect()
    }

    #[tokio::test]
    async fn sorted_stable_lines() {
        let d = db();
        seed(&d).await;
        let one = d.root.join("export").join("one");
        let two = d.root.join("export").join("two");
        let r = export(&d.pool, one.clone(), Opts::default(), all()).await;
        assert_eq!(r.error, None);
        export(&d.pool, two.clone(), Opts::default(), all()).await;
        let ents = lines(&one, "entities.jsonl");
        assert_eq!(ents.len(), 3, "the parsed entity is not exported");
        let ids: Vec<String> = ents
            .iter()
            .map(|l| {
                serde_json::from_str::<Value>(l).unwrap()["id"]
                    .as_str()
                    .unwrap()
                    .to_string()
            })
            .collect();
        assert_eq!(ids, ["note:c", "task:a", "task:b"]);
        assert!(ents[0].starts_with(r#"{"id":"note:c","kind":"note","project":null,"title":"C""#));
        for f in ["entities.jsonl", "links.jsonl"] {
            assert_eq!(lines(&one, f), lines(&two, f));
        }
        let links = lines(&one, "links.jsonl");
        assert_eq!(links.len(), 2);
        assert!(links[0].contains(r#""src":"note:c""#) && links[1].contains(r#""src":"task:a""#));
        let mode = std::fs::metadata(d.root.join("export"))
            .unwrap()
            .permissions();
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(mode.mode() & 0o777, 0o700);
        assert_eq!((r.entities, r.links), (3, 2));
        assert_eq!(r.txs, lines(&one, "tx.jsonl").len() as u64);
    }

    #[tokio::test]
    async fn a_change_touches_only_its_lines() {
        let d = db();
        let (a, _, _) = seed(&d).await;
        let dir = d.root.join("export").join("e");
        export(&d.pool, dir.clone(), Opts::default(), all()).await;
        let before = lines(&dir, "entities.jsonl");
        let links_before = lines(&dir, "links.jsonl");
        retitle(&d.h, a, "A, renamed").await;
        let r = export(&d.pool, dir.clone(), Opts::default(), all()).await;
        assert_eq!(r.error, None);
        let after = lines(&dir, "entities.jsonl");
        assert_eq!(before.len(), after.len());
        let changed: Vec<usize> = (0..before.len())
            .filter(|&i| before[i] != after[i])
            .collect();
        assert_eq!(changed.len(), 1);
        assert!(after[changed[0]].contains("A, renamed"));
        assert_eq!(links_before, lines(&dir, "links.jsonl"));
        assert!(!tmp_of(&dir).exists());
    }

    #[tokio::test]
    async fn activity_is_opt_in() {
        let d = db();
        let (a, _, _) = seed(&d).await;
        let s = put(&d.h, "session:s1", "session", "s", Origin::Inferred).await;
        join(&d.h, s, "touched", a, Origin::Inferred).await;
        d.h.write(meta(), move |tx| {
            link::stat_bump(tx, s, "touched", a)?;
            Ok(())
        })
        .await
        .unwrap();
        let plain = d.root.join("export").join("plain");
        export(&d.pool, plain.clone(), Opts::default(), all()).await;
        assert!(
            !lines(&plain, "entities.jsonl")
                .iter()
                .any(|l| l.contains("session:s1"))
        );
        assert!(
            !lines(&plain, "links.jsonl")
                .iter()
                .any(|l| l.contains("touched"))
        );
        assert!(!plain.join("link_stat.jsonl").exists());
        let full = d.root.join("export").join("full");
        let opts = Opts {
            with_activity: true,
            ..Opts::default()
        };
        export(&d.pool, full.clone(), opts, all()).await;
        assert!(
            lines(&full, "entities.jsonl")
                .iter()
                .any(|l| l.contains("session:s1"))
        );
        assert!(
            lines(&full, "links.jsonl")
                .iter()
                .any(|l| l.contains("touched"))
        );
        assert_eq!(lines(&full, "link_stat.jsonl").len(), 1);
    }

    #[tokio::test]
    async fn allow_filters() {
        let d = db();
        let (_, _, c) = seed(&d).await;
        retitle(&d.h, c, "C2").await;
        let deny: Allow = Arc::new(|e| e.id != "note:c");
        let dir = d.root.join("export").join("e");
        let opts = Opts {
            history: true,
            ..Opts::default()
        };
        let r = export(&d.pool, dir.clone(), opts, deny).await;
        assert_eq!(r.skipped, 1);
        assert_eq!(r.entities, 2);
        for f in ["entities.jsonl", "links.jsonl", "history.jsonl"] {
            assert!(
                !lines(&dir, f).iter().any(|l| l.contains("note:c")),
                "{f} leaked the denied entity"
            );
        }
        assert_eq!(r.links, 1, "the link to the denied entity is dropped");
    }

    /// Door 5 covers the tx log: a tx that wrote a version of an entity ALLOW refuses leaves no line, so its note
    /// never leaves the store; the other txs stay.
    #[tokio::test]
    async fn allow_filters_the_tx_log() {
        let d = db();
        let (a, _, c) = seed(&d).await;
        // A parsed entity is never exported, but ALLOW is asked for it too.
        let q = put(&d.h, "spec:q", "spec", "parsed q", Origin::Parsed).await;
        for (n, note) in [
            (c, "why: CANARY-door5-tx-note"),
            (q, "why: CANARY-door5-parsed"),
            (a, "a note about task a"),
        ] {
            let mut noted = meta();
            noted.note = Some(note.into());
            d.h.write(noted, move |tx| {
                entity::update(
                    tx,
                    n,
                    None,
                    Changes {
                        body: Some(Some("changed".into())),
                        ..Changes::default()
                    },
                )?;
                Ok(())
            })
            .await
            .unwrap();
        }
        let deny: Allow = Arc::new(|e| e.id != "note:c" && e.id != "spec:q");
        let dir = d.root.join("export").join("e");
        let r = export(&d.pool, dir.clone(), Opts::default(), deny).await;
        assert_eq!(r.error, None);
        let txs = lines(&dir, "tx.jsonl");
        assert!(
            !txs.iter().any(|l| l.contains("CANARY-door5")),
            "the denied entity's tx note left the store"
        );
        assert!(txs.iter().any(|l| l.contains("a note about task a")));
        assert_eq!(r.txs, txs.len() as u64);
        // Unfiltered, every tx is there.
        let all_dir = d.root.join("export").join("all");
        let r = export(&d.pool, all_dir.clone(), Opts::default(), all()).await;
        assert!(lines(&all_dir, "tx.jsonl").len() > txs.len());
        assert_eq!(r.error, None);
    }

    #[tokio::test]
    async fn a_crash_leaves_no_half_export() {
        let d = db();
        seed(&d).await;
        let dir = d.root.join("export").join("e");
        export(&d.pool, dir.clone(), Opts::default(), all()).await;
        let good = lines(&dir, "entities.jsonl");
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let boom: Allow = Arc::new(move |_| {
            if calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 1 {
                panic!("crash mid-export");
            }
            true
        });
        let r = export(&d.pool, dir.clone(), Opts::default(), boom.clone()).await;
        assert!(r.error.is_some());
        assert_eq!(
            lines(&dir, "entities.jsonl"),
            good,
            "the earlier export is intact"
        );
        assert!(!tmp_of(&dir).exists(), "no half-written directory stays");
        // A first export that crashes leaves nothing at all.
        let fresh = d.root.join("export").join("fresh");
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(1));
        let boom: Allow = Arc::new(move |_| {
            if calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 2 {
                panic!("crash mid-export");
            }
            true
        });
        let r = export(&d.pool, fresh.clone(), Opts::default(), boom).await;
        assert!(r.error.is_some());
        assert!(!fresh.exists() && !tmp_of(&fresh).exists());
    }

    /// `--out` naming a folder of the user's (a repository) costs nothing: refused before anything is written, and
    /// an existing parent keeps its mode. The same holds for `DIR.tmp` and `DIR.old`.
    #[tokio::test]
    async fn an_export_never_replaces_what_it_did_not_write() {
        use std::os::unix::fs::PermissionsExt;
        let d = db();
        seed(&d).await;
        let work = d.root.join("work");
        std::fs::create_dir(&work).unwrap();
        std::fs::set_permissions(&work, std::fs::Permissions::from_mode(0o755)).unwrap();
        let repo = work.join("repo");
        std::fs::create_dir_all(repo.join("src")).unwrap();
        std::fs::write(repo.join("README.md"), "mine").unwrap();
        std::fs::write(repo.join("entities.jsonl"), "not an export's alone").unwrap();
        let r = export(&d.pool, repo.clone(), Opts::default(), all()).await;
        let e = r.error.expect("refused");
        assert!(e.contains("replaces only an earlier export"), "{e}");
        assert_eq!(
            std::fs::read_to_string(repo.join("README.md")).unwrap(),
            "mine"
        );
        assert!(repo.join("src").is_dir());
        assert!(!tmp_of(&repo).exists() && !work.join("repo.old").exists());
        let mode = std::fs::metadata(&work).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o755, "an existing parent keeps its mode");
        // A file at DIR, and foreign files at DIR.tmp or DIR.old, are refused alike.
        std::fs::write(work.join("plain"), "mine").unwrap();
        for (name, side) in [("t", "t.tmp"), ("o", "o.old")] {
            std::fs::create_dir(work.join(side)).unwrap();
            std::fs::write(work.join(side).join("keep"), "mine").unwrap();
            let r = export(&d.pool, work.join(name), Opts::default(), all()).await;
            assert!(r.error.is_some(), "{side}");
            assert!(work.join(side).join("keep").exists(), "{side}");
            assert!(!work.join(name).exists(), "{side}");
        }
        let r = export(&d.pool, work.join("plain"), Opts::default(), all()).await;
        let e = r.error.expect("a file is refused");
        assert!(e.contains("is not a folder"), "{e}");
        assert_eq!(std::fs::read_to_string(work.join("plain")).unwrap(), "mine");
        // An empty folder and an earlier export are replaced; the export's own folder is 0700.
        let fresh = work.join("fresh");
        std::fs::create_dir(&fresh).unwrap();
        for _ in 0..2 {
            let r = export(&d.pool, fresh.clone(), Opts::default(), all()).await;
            assert_eq!(r.error, None);
        }
        assert_eq!(lines(&fresh, "entities.jsonl").len(), 3);
        let mode = std::fs::metadata(&fresh).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700);
        assert_eq!(
            std::fs::metadata(&work).unwrap().permissions().mode() & 0o777,
            0o755
        );
    }

    async fn ents_of(d: &Db) -> Vec<(String, String, Option<String>, Value, i64)> {
        d.pool
            .with(|c| {
                let mut s = c
                    .prepare(&format!("select {COLS} from entity order by id"))
                    .unwrap();
                s.query_map([], from_row)
                    .unwrap()
                    .map(|e| {
                        let e = e.unwrap();
                        (e.id, e.kind, e.title, e.data, e.ver)
                    })
                    .collect()
            })
            .await
            .unwrap()
    }

    async fn links_of(d: &Db) -> Vec<(String, String, String)> {
        d.pool
            .with(|c| {
                let mut s = c
                    .prepare(
                        "select s.id, l.kind, t.id from link l join entity s on s.n = l.src \
                         join entity t on t.n = l.dst where l.tx_to = ?1 order by 1, 2, 3",
                    )
                    .unwrap();
                s.query_map([SENTINEL], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                    .unwrap()
                    .map(|r| r.unwrap())
                    .collect()
            })
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn import_is_idempotent_by_ver() {
        let a = db();
        let (an, _, _) = seed(&a).await;
        retitle(&a.h, an, "A2").await;
        let dir = a.root.join("export").join("e");
        export(&a.pool, dir.clone(), Opts::default(), all()).await;
        let b = db();
        let r = import(&b.h, dir.clone(), all()).await;
        assert_eq!(r.error, None);
        assert_eq!((r.entities, r.links, r.skipped), (3, 2, 0));
        let once = ents_of(&b).await;
        let r = import(&b.h, dir.clone(), all()).await;
        assert_eq!((r.entities, r.links, r.skipped), (0, 0, 5));
        assert_eq!(ents_of(&b).await, once);
        // A newer version of one record updates it, keeping the old one in history.
        retitle(&a.h, an, "A3").await;
        export(&a.pool, dir.clone(), Opts::default(), all()).await;
        let r = import(&b.h, dir.clone(), all()).await;
        assert_eq!((r.entities, r.skipped), (1, 4));
        let mut want = ents_of(&a).await;
        want.retain(|e| e.1 != "spec");
        assert_eq!(want, ents_of(&b).await);
        let hist: i64 = b
            .pool
            .with(|c| {
                c.query_row("select count(*) from entity_hist", [], |r| r.get(0))
                    .unwrap()
            })
            .await
            .unwrap();
        assert_eq!(hist, 1);
        // The imported txs are real versions.
        let imported: i64 = b
            .pool
            .with(|c| {
                c.query_row(
                    "select count(*) from tx where actor = 'import' and tool = 'import' and imported = 0",
                    [],
                    |r| r.get(0),
                )
                .unwrap()
            })
            .await
            .unwrap();
        assert!(imported >= 1);
        // The same id under another kind is refused, with its line.
        put(&b.h, "task:z", "task", "Z", Origin::Recorded).await;
        let c = db();
        put(&c.h, "task:z", "note", "Z", Origin::Recorded).await;
        let zdir = c.root.join("export").join("z");
        export(&c.pool, zdir.clone(), Opts::default(), all()).await;
        let r = import(&b.h, zdir, all()).await;
        assert_eq!(r.entities, 0);
        assert_eq!(r.refused.len(), 1);
        assert_eq!(r.refused[0].0, 1);
        assert!(r.refused[0].1.contains("task:z"));
    }

    #[tokio::test]
    async fn export_import_round_trip() {
        let a = db();
        seed(&a).await;
        let dir = a.root.join("export").join("e");
        let r = export(&a.pool, dir.clone(), Opts::default(), all()).await;
        assert_eq!(r.error, None);
        let b = db();
        let deny: Allow = Arc::new(|e| e.id != "note:c");
        let r = import(&b.h, dir.clone(), deny).await;
        assert_eq!(r.skipped, 1);
        assert_eq!(r.entities, 2);
        assert_eq!(
            r.refused.len(),
            1,
            "the link to the filtered entity is refused: {r:?}"
        );
        let b2 = db();
        let r = import(&b2.h, dir.clone(), all()).await;
        assert_eq!(r.error, None);
        let mut want = ents_of(&a).await;
        want.retain(|e| e.1 != "spec");
        assert_eq!(ents_of(&b2).await, want);
        let mut links = links_of(&a).await;
        links.sort();
        assert_eq!(links_of(&b2).await, links);
        // Exporting the copy gives the same files.
        let again = b2.root.join("export").join("again");
        export(&b2.pool, again.clone(), Opts::default(), all()).await;
        for f in ["entities.jsonl", "links.jsonl"] {
            assert_eq!(lines(&dir, f), lines(&again, f));
        }
    }
}
