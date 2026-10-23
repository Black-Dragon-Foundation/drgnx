//! Excise (Task 8; storage §8.3): blank a text in every version, the FTS and vector rows, the `tx` answers and notes,
//! and the caller's streams (blankers), in one tx; log what and why, never the content; then scrub the file.
//!
//! Outside the file, [`kept_copies`] lists the backups, the schema-5 copy and the exports, [`holding`] finds which of
//! them still hold an excised value (a byte search), and [`redact`] rewrites a file (a transcript) without them.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::{self, ErrorKind, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::backup::tmp_of;
use super::search::{fts_optimize, fts_put};
use super::tx::{Class, Tx, TxMeta};
use super::writer::{Maintenance, ScrubReport, WriteError, WriterHandle};

/// What to excise.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Target {
    /// An entity by id: the named fields of every version.
    Entity(String),
    /// Every field a tx wrote, and the cards and notices it made.
    Tx(i64),
}

/// What a blanker is told: the entities and txs excised, and the marker text (`[excised <tx>]`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Excised {
    pub entities: Vec<i64>,
    pub txs: Vec<i64>,
    pub marker: String,
}

/// The caller's own tables that hold copies (norn's: events, messages, cards; Tasks 12 and 13).
pub trait Blanker: Send + Sync {
    /// Blank what this blanker keeps of EXCISED, in the excise's tx; the rows changed.
    fn blank(&self, tx: &mut Tx<'_>, excised: &Excised) -> Result<u64, WriteError>;

    /// The txs that wrote a row of this blanker's about one of ENTITIES (an event or a notice for it), read before
    /// [`Blanker::blank`]: their `tx.answer` and `tx.note` are blanked too, as a keyed answer may quote what the row
    /// was about. None by default.
    fn txs_about(&self, tx: &Tx<'_>, entities: &[i64]) -> Result<Vec<i64>, WriteError> {
        let _ = (tx, entities);
        Ok(Vec::new())
    }
}

/// What an excise did. `needles` (the values removed) stay in memory for [`holding`]: never serialized.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ExciseReport {
    pub tx: i64,
    pub entities: u64,
    pub versions: u64,
    pub txs_blanked: u64,
    pub blanked: u64,
    #[serde(skip)]
    pub needles: Vec<Vec<u8>>,
}

/// The fields an excise can blank: the entity's text columns (`project` and `priority` are numbers).
pub const FIELDS: [&str; 5] = ["title", "status", "body", "assignee", "data"];

/// An entity target's fields when none are named.
pub const DEFAULT_FIELDS: [&str; 3] = ["title", "body", "data"];

/// A value shorter than this many bytes is no needle: it would match unrelated text in a backup or a transcript.
pub const MIN_NEEDLE: usize = 12;

/// How every marker starts; a marker is never a JSON value, so the writer knows an excised `tx.answer` by it.
pub(crate) const MARKER_PREFIX: &str = "[excised ";

/// The text an excise of tx TX writes in place of a value.
pub fn marker(tx: i64) -> String {
    format!("{MARKER_PREFIX}{tx}]")
}

/// Excise TARGET's FIELDS (default `title`, `body`, `data`) in one tx of META (the caller checks the class).
///
/// An entity target blanks the named fields in its current row and in every `entity_hist` version; a tx target
/// blanks, in every version of every entity, the fields whose `field_tx` names that tx (default: all of
/// [`FIELDS`]). Then, in the same tx: the FTS rows are put again and the index optimized, the vectors are deleted,
/// `tx.answer` and `tx.note` of every tx that wrote a blanked version (for an entity target, every version), of
/// the target tx and of every tx that names the target (its answer or note holds a blanked value; for an entity
/// target also a tx that linked or unlinked it, or wrote a blanker's row about it: [`Blanker::txs_about`]) become
/// the marker, every blanker runs, and `excise_log` gets the target, the fields and the reason.
/// An agent or outside agent is refused here as well as at the method.
pub async fn excise(
    writer: &WriterHandle,
    meta: TxMeta,
    target: Target,
    fields: Option<Vec<String>>,
    reason: String,
    blankers: Vec<Arc<dyn Blanker>>,
) -> Result<ExciseReport, WriteError> {
    if matches!(meta.class, Class::Agent | Class::Ext) {
        return Err(WriteError::Refused(
            "only the user excises; an agent cannot".into(),
        ));
    }
    if reason.trim().is_empty() {
        return Err(WriteError::Refused("an excise needs a reason".into()));
    }
    let fields = match fields {
        Some(f) if f.is_empty() => {
            return Err(WriteError::Refused("name at least one field".into()));
        }
        Some(f) => {
            if let Some(bad) = f.iter().find(|x| !FIELDS.contains(&x.as_str())) {
                return Err(WriteError::Refused(format!(
                    "cannot excise {bad:?}; the fields are {}",
                    FIELDS.join(", ")
                )));
            }
            f
        }
        None => match target {
            Target::Entity(_) => DEFAULT_FIELDS.iter().map(|s| s.to_string()).collect(),
            Target::Tx(_) => FIELDS.iter().map(|s| s.to_string()).collect(),
        },
    };
    let written = writer
        .write(meta, move |tx: &mut Tx<'_>| {
            run(tx, &target, &fields, &reason, &blankers)
        })
        .await?;
    Ok(written.value)
}

/// `VACUUM` and `wal_checkpoint(TRUNCATE)` through the writer's `maintain`, never a connection of its own.
pub async fn scrub(writer: &WriterHandle) -> Result<ScrubReport, WriteError> {
    writer.maintain(Maintenance::Scrub).await
}

/// One stored version: the current row (`ver: None`) or an `entity_hist` row, with the tx that wrote it.
struct Version {
    ver: Option<i64>,
    tx: i64,
    /// [`FIELDS`]' values, in that order.
    values: [Option<String>; 5],
    field_tx: BTreeMap<String, i64>,
}

impl Version {
    fn value(&self, field: &str) -> Option<&str> {
        let i = FIELDS.iter().position(|f| *f == field)?;
        self.values[i].as_deref()
    }
}

fn version_of(r: &rusqlite::Row<'_>, ver: Option<i64>, at: usize) -> rusqlite::Result<Version> {
    let field_tx: Option<String> = r.get(at + 6)?;
    Ok(Version {
        ver,
        tx: r.get(at)?,
        values: [
            r.get(at + 1)?,
            r.get(at + 2)?,
            r.get(at + 3)?,
            r.get(at + 4)?,
            r.get(at + 5)?,
        ],
        field_tx: field_tx
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default(),
    })
}

/// Entity N's current row and every `entity_hist` version.
fn versions_of(conn: &Connection, n: i64) -> rusqlite::Result<Vec<Version>> {
    let mut out = Vec::new();
    if let Some(v) = conn
        .query_row(
            "select updated_tx, title, status, body, assignee, data, field_tx from entity where n = ?1",
            [n],
            |r| version_of(r, None, 0),
        )
        .optional()?
    {
        out.push(v);
    }
    let mut st = conn.prepare(
        "select ver, tx_from, title, status, body, assignee, data, field_tx from entity_hist where n = ?1 \
         order by ver",
    )?;
    let hist = st.query_map([n], |r| version_of(r, Some(r.get(0)?), 1))?;
    for v in hist {
        out.push(v?);
    }
    Ok(out)
}

/// Whether FIELD holds something: any text, and for `data` anything but `{}`.
fn is_set(field: &str, value: &str) -> bool {
    field != "data"
        || !matches!(serde_json::from_str::<Value>(value), Ok(Value::Object(o)) if o.is_empty())
}

/// Add S to NEEDLES as stored (SQLite keeps text as its bytes) and JSON-escaped (exports and transcripts), when long
/// enough and not a marker already.
fn push_needle(s: &str, needles: &mut BTreeSet<Vec<u8>>) {
    if s.starts_with(MARKER_PREFIX) {
        return;
    }
    let quoted = serde_json::to_string(s).unwrap_or_default();
    let escaped = quoted
        .get(1..quoted.len().saturating_sub(1))
        .unwrap_or_default();
    for form in [s, escaped] {
        if form.len() >= MIN_NEEDLE {
            needles.insert(form.as_bytes().to_vec());
        }
    }
}

/// FIELD's VALUE as needles: the text, or for `data` every string inside it (keys are structure, not content).
fn needles_of(field: &str, value: &str, needles: &mut BTreeSet<Vec<u8>>) {
    fn leaves(v: &Value, needles: &mut BTreeSet<Vec<u8>>) {
        match v {
            Value::String(s) => push_needle(s, needles),
            Value::Array(a) => a.iter().for_each(|x| leaves(x, needles)),
            Value::Object(o) => o.values().for_each(|x| leaves(x, needles)),
            _ => {}
        }
    }
    if field == "data" {
        match serde_json::from_str::<Value>(value) {
            Ok(v) => leaves(&v, needles),
            Err(_) => push_needle(value, needles),
        }
    } else {
        push_needle(value, needles);
    }
}

/// Overwrite BLANK's columns of entity N's version VER (`None`: the current row) with the markers.
fn blank_version(
    conn: &Connection,
    n: i64,
    ver: Option<i64>,
    blank: &[&str],
    marker: &str,
    data_marker: &str,
) -> rusqlite::Result<()> {
    // Column names come from FIELDS only.
    let sets = blank
        .iter()
        .map(|f| format!("{f} = {}", if *f == "data" { "?2" } else { "?1" }))
        .collect::<Vec<_>>()
        .join(", ");
    match ver {
        None => conn.execute(
            &format!("update entity set {sets} where n = ?3"),
            params![marker, data_marker, n],
        ),
        Some(v) => conn.execute(
            &format!("update entity_hist set {sets} where n = ?3 and ver = ?4"),
            params![marker, data_marker, n, v],
        ),
    }?;
    Ok(())
}

/// The txs that added or retired a link at entity N.
fn link_txs(conn: &Connection, n: i64) -> rusqlite::Result<Vec<i64>> {
    // plain lookups per end, not `src = ?1 or dst = ?1` (norn's privacy: SQLite's planner and that OR)
    let mut st = conn.prepare(
        "select tx_from from link where src = ?1 union select tx_from from link where dst = ?1 \
         union select tx_to from link where src = ?1 and tx_to <> ?2 \
         union select tx_to from link where dst = ?1 and tx_to <> ?2",
    )?;
    st.query_map(params![n, super::schema::SENTINEL], |r| r.get(0))?
        .collect()
}

/// The txs whose answer or note holds one of NEEDLES (a scan of `tx`; excise is rare).
fn txs_quoting(conn: &Connection, needles: &BTreeSet<Vec<u8>>) -> rusqlite::Result<Vec<i64>> {
    let mut st =
        conn.prepare("select id from tx where instr(answer, ?1) > 0 or instr(note, ?1) > 0")?;
    let mut out = Vec::new();
    for needle in needles {
        let Ok(text) = std::str::from_utf8(needle) else {
            continue;
        };
        for id in st.query_map([text], |r| r.get(0))? {
            out.push(id?);
        }
    }
    Ok(out)
}

/// The excise's body, inside its tx.
fn run(
    tx: &mut Tx<'_>,
    target: &Target,
    fields: &[String],
    reason: &str,
    blankers: &[Arc<dyn Blanker>],
) -> Result<ExciseReport, WriteError> {
    let id = tx.id();
    let marker = marker(id);
    let data_marker = json!({ "excised": id }).to_string();
    let (ns, only_tx, target_text) = match target {
        Target::Entity(eid) => {
            let n: Option<i64> = tx
                .sql()
                .query_row("select n from entity where id = ?1", [eid], |r| r.get(0))
                .optional()?;
            let n = n.ok_or_else(|| WriteError::Refused(format!("no entity {eid}")))?;
            (vec![n], None, eid.clone())
        }
        Target::Tx(t) => {
            let found: Option<i64> = tx
                .sql()
                .query_row("select id from tx where id = ?1", [t], |r| r.get(0))
                .optional()?;
            if found.is_none() || *t == id {
                return Err(WriteError::Refused(format!("no tx {t}")));
            }
            let mut st = tx.sql().prepare(
                "select n from entity where created_tx = ?1 or updated_tx = ?1 \
                 union select n from entity_hist where tx_from = ?1 order by 1",
            )?;
            let ns = st
                .query_map([t], |r| r.get(0))?
                .collect::<rusqlite::Result<Vec<i64>>>()?;
            (ns, Some(*t), format!("tx:{t}"))
        }
    };
    let mut needles = BTreeSet::new();
    let mut txs = BTreeSet::new();
    txs.extend(only_tx);
    let mut entities = Vec::new();
    let mut versions = 0u64;
    for &n in &ns {
        let mut touched = only_tx.is_none();
        for v in versions_of(tx.sql(), n)? {
            if only_tx.is_none() {
                // Every tx that wrote a version of an excised entity: its answer may quote it.
                txs.insert(v.tx);
            }
            let blank: Vec<&str> = FIELDS
                .iter()
                .copied()
                .filter(|f| fields.iter().any(|x| x == f))
                .filter(|f| only_tx.is_none_or(|t| v.field_tx.get(*f) == Some(&t)))
                .filter(|f| v.value(f).is_some_and(|x| is_set(f, x)))
                .collect();
            if blank.is_empty() {
                continue;
            }
            for f in &blank {
                if let Some(value) = v.value(f) {
                    needles_of(f, value, &mut needles);
                }
            }
            blank_version(tx.sql(), n, v.ver, &blank, &marker, &data_marker)?;
            versions += 1;
            txs.insert(v.tx);
            touched = true;
        }
        if touched {
            entities.push(n);
        }
    }
    for &n in &entities {
        let (title, body): (Option<String>, Option<String>) =
            tx.sql()
                .query_row("select title, body from entity where n = ?1", [n], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })?;
        // Put again (delete, insert), then one `optimize` below: the old versions' tombstoned tokens leave the file.
        fts_put(tx, n, title.as_deref(), body.as_deref())?;
        tx.sql()
            .execute("delete from entity_vec where n = ?1", [n])?;
    }
    if !entities.is_empty() {
        fts_optimize(tx)?;
    }
    // Every other tx whose answer or note names the target (a keyed write that wrote no version of it, call 3): it
    // quotes a blanked value, it linked or unlinked an excised entity, or a blanker holds an event or a notice of
    // it about one.
    let mut named = BTreeSet::new();
    if only_tx.is_none() {
        for &n in &entities {
            named.extend(link_txs(tx.sql(), n)?);
        }
        for b in blankers {
            named.extend(b.txs_about(tx, &entities)?);
        }
    }
    named.extend(txs_quoting(tx.sql(), &needles)?);
    named.remove(&id);
    let mut txs_blanked = 0u64;
    for &t in txs.union(&named) {
        let note: Option<String> = tx
            .sql()
            .query_row("select note from tx where id = ?1", [t], |r| r.get(0))
            .optional()?
            .flatten();
        if let Some(note) = &note {
            push_needle(note, &mut needles);
        }
        txs_blanked += tx.sql().execute(
            "update tx set answer = case when answer is null then null else ?1 end, \
             note = case when note is null then null else ?1 end \
             where id = ?2 and (answer is not null or note is not null)",
            params![marker, t],
        )? as u64;
    }
    let excised = Excised {
        entities: entities.clone(),
        txs: txs.into_iter().collect(),
        marker,
    };
    let mut blanked = 0u64;
    for b in blankers {
        blanked += b.blank(tx, &excised)?;
    }
    tx.sql().execute(
        "insert into excise_log (tx, target, fields, reason) values (?1, ?2, ?3, ?4)",
        params![id, target_text, json!(fields).to_string(), reason],
    )?;
    Ok(ExciseReport {
        tx: id,
        entities: entities.len() as u64,
        versions,
        txs_blanked,
        blanked,
        needles: needles.into_iter().collect(),
    })
}

/// The files outside WORK_DB that may keep copies of its content, sorted: every regular file under `<data>/backup/`
/// (the dated copies, `work-pre7-*.db`), the Lisp's never-replaced `work.db.schema5` beside WORK_DB, the schema-7 files
/// `ratatoskr store restore-pre7` moved aside (`work.db.schema7-*`, with their `-wal` and `-shm`), and every regular
/// file under `<data>/export/` (`<data>` is WORK_DB's directory). Links are not followed.
pub fn kept_copies(work_db: &Path) -> Vec<PathBuf> {
    fn files_under(dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(rd) = fs::read_dir(dir) else {
            return;
        };
        let mut paths: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
        paths.sort();
        for p in paths {
            match fs::symlink_metadata(&p) {
                Ok(m) if m.is_file() => out.push(p),
                Ok(m) if m.is_dir() => files_under(&p, out),
                _ => {}
            }
        }
    }
    let data = work_db.parent().unwrap_or(Path::new("."));
    let mut out = Vec::new();
    files_under(&data.join("backup"), &mut out);
    let mut schema5 = work_db.as_os_str().to_owned();
    schema5.push(".schema5");
    let schema5 = PathBuf::from(schema5);
    if fs::symlink_metadata(&schema5).is_ok_and(|m| m.is_file()) {
        out.push(schema5);
    }
    if let (Some(name), Ok(rd)) = (work_db.file_name(), fs::read_dir(data)) {
        let mut prefix = name.to_owned();
        prefix.push(".schema7-");
        let prefix = prefix.as_encoded_bytes();
        let mut aside: Vec<PathBuf> = rd
            .flatten()
            .filter(|e| e.file_name().as_encoded_bytes().starts_with(prefix))
            .filter(|e| fs::symlink_metadata(e.path()).is_ok_and(|m| m.is_file()))
            .map(|e| e.path())
            .collect();
        aside.sort();
        out.extend(aside);
    }
    files_under(&data.join("export"), &mut out);
    out
}

/// How much of a file [`holding`] reads at a time.
const CHUNK: usize = 1 << 20;

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty() && hay.windows(needle.len()).any(|w| w == needle)
}

/// Whether the file at PATH holds any of NEEDLES, read a chunk at a time (a needle across two chunks is found).
fn holds(path: &Path, needles: &[&[u8]]) -> io::Result<bool> {
    let mut f = fs::File::open(path)?;
    let keep = needles.iter().map(|n| n.len()).max().unwrap_or(1) - 1;
    let mut chunk = vec![0u8; CHUNK];
    let mut buf: Vec<u8> = Vec::with_capacity(CHUNK + keep);
    loop {
        let got = match f.read(&mut chunk) {
            Ok(0) => return Ok(false),
            Ok(got) => got,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        buf.extend_from_slice(&chunk[..got]);
        if needles.iter().any(|n| contains(&buf, n)) {
            return Ok(true);
        }
        let cut = buf.len().saturating_sub(keep);
        buf.drain(..cut);
    }
}

/// The FILES that hold any of NEEDLES (a byte search over backups and exports). A file that is gone is left out; one
/// that cannot be read is listed, since it cannot be shown not to hold them.
pub fn holding(files: &[PathBuf], needles: &[Vec<u8>]) -> Vec<PathBuf> {
    let needles: Vec<&[u8]> = needles
        .iter()
        .filter(|n| !n.is_empty())
        .map(Vec::as_slice)
        .collect();
    if needles.is_empty() {
        return Vec::new();
    }
    files
        .iter()
        .filter(|f| match holds(f, &needles) {
            Ok(held) => held,
            Err(e) => e.kind() != ErrorKind::NotFound,
        })
        .cloned()
        .collect()
}

/// Rewrite the file at PATH (a transcript) with every NEEDLE replaced by MARKER, longest needles first, through a
/// `.tmp` beside it and a rename, keeping its mode; false, and nothing written, when it holds none. The caller makes
/// sure nothing appends to it meanwhile.
pub fn redact(path: &Path, needles: &[Vec<u8>], marker: &str) -> io::Result<bool> {
    let mut text = fs::read(path)?;
    let mut sorted: Vec<&[u8]> = needles
        .iter()
        .filter(|n| !n.is_empty())
        .map(Vec::as_slice)
        .collect();
    sorted.sort_by_key(|n| std::cmp::Reverse(n.len()));
    let mut changed = false;
    for n in sorted {
        if !contains(&text, n) {
            continue;
        }
        changed = true;
        let mut out = Vec::with_capacity(text.len());
        let mut i = 0;
        while i < text.len() {
            if text[i..].starts_with(n) {
                out.extend_from_slice(marker.as_bytes());
                i += n.len();
            } else {
                out.push(text[i]);
                i += 1;
            }
        }
        text = out;
    }
    if !changed {
        return Ok(false);
    }
    let mode = fs::metadata(path)?.permissions().mode() & 0o777;
    let tmp = tmp_of(path);
    let written = (|| {
        let mut f = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(mode)
            .open(&tmp)?;
        f.set_permissions(fs::Permissions::from_mode(mode))?;
        f.write_all(&text)?;
        f.sync_all()?;
        fs::rename(&tmp, path)
    })();
    if written.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    written.map(|()| true)
}

#[cfg(test)]
mod tests {
    use std::hash::{BuildHasher, Hasher};

    use super::*;
    use crate::graph::entity::{self, Changes, EntityNew, Origin};
    use crate::graph::search::{find_fts, vec_put};
    use crate::graph::writer::Writer;
    use crate::graph::writer::tests::{keyed, opts, rule, stop};

    fn spawn(dir: &tempfile::TempDir) -> (Writer, WriterHandle, PathBuf) {
        let path = dir.path().join("work.db");
        let (w, h) = Writer::spawn(&path, opts(16, 1), rule()).unwrap();
        (w, h, path)
    }

    fn user() -> TxMeta {
        TxMeta::new("user", Class::User, "cli:graph-excise")
    }

    fn agent() -> TxMeta {
        TxMeta::new("agent:s1", Class::Agent, "mcp:task_write")
    }

    /// A random 32-byte canary, one FTS word.
    fn canary() -> String {
        let s = std::collections::hash_map::RandomState::new();
        let mut out = String::from("zzcanary");
        for i in 0..2u64 {
            let mut h = s.build_hasher();
            h.write_u64(i);
            out.push_str(&format!("{:016x}", h.finish()));
        }
        out
    }

    fn task(id: &str, title: &str, body: &str, data: Value) -> EntityNew {
        EntityNew {
            id: id.into(),
            kind: "task".into(),
            project: None,
            title: Some(title.into()),
            status: Some("open".into()),
            body: Some(body.into()),
            priority: None,
            assignee: None,
            data,
            origin: Origin::Recorded,
            source: None,
        }
    }

    async fn create(h: &WriterHandle, meta: TxMeta, new: EntityNew) -> (i64, i64) {
        let w = h
            .write(meta, move |tx: &mut Tx<'_>| Ok(entity::create(tx, new)?.n))
            .await
            .unwrap();
        (w.value, w.tx)
    }

    async fn change(h: &WriterHandle, meta: TxMeta, n: i64, changes: Changes) -> i64 {
        h.write(meta, move |tx: &mut Tx<'_>| {
            entity::update(tx, n, None, changes).map(|_| ())
        })
        .await
        .unwrap()
        .tx
    }

    fn body(text: String) -> Changes {
        Changes {
            body: Some(Some(text)),
            ..Default::default()
        }
    }

    fn ro(path: &Path) -> Connection {
        crate::open_readonly(path).unwrap()
    }

    fn bytes(path: &Path) -> Vec<u8> {
        fs::read(path).unwrap_or_default()
    }

    fn wal(path: &Path) -> PathBuf {
        let mut p = path.as_os_str().to_owned();
        p.push("-wal");
        PathBuf::from(p)
    }

    /// Every stored version of N: `(ver, title, body, data)`, the current row last.
    fn stored(path: &Path, n: i64) -> Vec<(i64, Option<String>, Option<String>, String)> {
        let c = ro(path);
        let mut st = c
            .prepare(
                "select ver, title, body, data from entity_hist where n = ?1 \
                 union all select ver, title, body, data from entity where n = ?1 order by 1",
            )
            .unwrap();
        st.query_map([n], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
    }

    #[tokio::test]
    async fn fields_blanked_in_every_version() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn(&dir);
        let c = canary();
        let (n, _) = create(
            &h,
            agent(),
            task("task:a", &format!("t {c}"), "b1", json!({ "k": c })),
        )
        .await;
        change(&h, agent(), n, body(format!("b2 {c}"))).await;
        change(&h, agent(), n, body(format!("b3 {c}"))).await;
        let report = excise(
            &h,
            user(),
            Target::Entity("task:a".into()),
            None,
            "pasted by mistake".into(),
            vec![],
        )
        .await
        .unwrap();
        let m = marker(report.tx);
        let dm = json!({ "excised": report.tx }).to_string();
        let rows = stored(&path, n);
        assert_eq!(rows.len(), 3, "the versions stay");
        for (ver, title, body, data) in rows {
            assert_eq!(title.as_deref(), Some(m.as_str()), "title of ver {ver}");
            assert_eq!(body.as_deref(), Some(m.as_str()), "body of ver {ver}");
            assert_eq!(data, dm, "data of ver {ver}");
        }
        assert_eq!((report.entities, report.versions), (1, 3));
        // Who changed what stays: the status was not named, and field_tx still names the writers.
        let (status, ver, field_tx): (String, i64, String) = ro(&path)
            .query_row(
                "select status, ver, field_tx from entity where n = ?1",
                [n],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!((status.as_str(), ver), ("open", 3));
        let field_tx: BTreeMap<String, i64> = serde_json::from_str(&field_tx).unwrap();
        assert!(field_tx.values().all(|t| *t != report.tx), "{field_tx:?}");
        // Only named fields: a second excise of the status alone leaves the rest as they are.
        let r2 = excise(
            &h,
            user(),
            Target::Entity("task:a".into()),
            Some(vec!["status".into()]),
            "again".into(),
            vec![],
        )
        .await
        .unwrap();
        let (status, title): (String, String) = ro(&path)
            .query_row("select status, title from entity where n = ?1", [n], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!((status, title), (marker(r2.tx), m));
        // Unknown fields, an empty reason and an agent are refused before anything is written.
        for (meta, fields, reason) in [
            (user(), Some(vec!["id".to_string()]), "r"),
            (user(), Some(vec![]), "r"),
            (user(), None, "  "),
            (agent(), None, "r"),
        ] {
            let e = excise(
                &h,
                meta,
                Target::Entity("task:a".into()),
                fields,
                reason.into(),
                vec![],
            )
            .await
            .unwrap_err();
            assert!(matches!(e, WriteError::Refused(_)), "{e:?}");
        }
        let e = excise(
            &h,
            user(),
            Target::Entity("task:none".into()),
            None,
            "r".into(),
            vec![],
        )
        .await
        .unwrap_err();
        assert_eq!(e, WriteError::Refused("no entity task:none".into()));
        stop(w).await;
    }

    #[tokio::test]
    async fn a_tx_target_blanks_only_what_it_wrote() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn(&dir);
        let c = canary();
        let (n, _) = create(
            &h,
            agent(),
            task("task:a", "a plain title", "b1", json!({})),
        )
        .await;
        let t = change(&h, agent(), n, body(format!("b2 {c}"))).await;
        change(
            &h,
            agent(),
            n,
            Changes {
                status: Some(Some("done".into())),
                ..Default::default()
            },
        )
        .await;
        let report = excise(&h, user(), Target::Tx(t), None, "secret".into(), vec![])
            .await
            .unwrap();
        let m = marker(report.tx);
        let rows = stored(&path, n);
        let bodies: Vec<Option<String>> = rows.iter().map(|r| r.2.clone()).collect();
        // ver 1 (b1) stays; ver 2 (written by t) and ver 3 (the status change, body still t's) are blanked.
        assert_eq!(
            bodies,
            [Some("b1".into()), Some(m.clone()), Some(m.clone())]
        );
        assert!(rows.iter().all(|r| r.1.as_deref() == Some("a plain title")));
        let status: String = ro(&path)
            .query_row("select status from entity where n = ?1", [n], |r| r.get(0))
            .unwrap();
        assert_eq!(status, "done", "a field the tx did not write stays");
        assert_eq!((report.entities, report.versions), (1, 2));
        assert!(
            report
                .needles
                .iter()
                .any(|x| x == format!("b2 {c}").as_bytes())
        );
        let e = excise(&h, user(), Target::Tx(9999), None, "r".into(), vec![])
            .await
            .unwrap_err();
        assert_eq!(e, WriteError::Refused("no tx 9999".into()));
        stop(w).await;
    }

    /// The FTS shadow tables' bytes (segments and their index).
    fn fts_bytes(path: &Path) -> Vec<u8> {
        let c = ro(path);
        let mut out = Vec::new();
        for sql in [
            "select block from entity_fts_data",
            "select term from entity_fts_idx",
        ] {
            let mut st = c.prepare(sql).unwrap();
            let rows = st
                .query_map([], |r| r.get::<_, rusqlite::types::Value>(0))
                .unwrap();
            for v in rows {
                match v.unwrap() {
                    rusqlite::types::Value::Blob(b) => out.extend(b),
                    rusqlite::types::Value::Text(t) => out.extend(t.into_bytes()),
                    _ => {}
                }
            }
        }
        out
    }

    #[tokio::test]
    async fn fts_has_no_token() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn(&dir);
        let c = canary();
        let (n, _) = create(
            &h,
            agent(),
            task("task:a", &c, &format!("x {c}"), json!({})),
        )
        .await;
        change(&h, agent(), n, body(format!("y {c}"))).await;
        create(
            &h,
            agent(),
            task("task:b", "another one", "other words", json!({})),
        )
        .await;
        assert!(
            contains(&fts_bytes(&path), c.as_bytes()),
            "the token is indexed"
        );
        assert_eq!(find_fts(&ro(&path), &c, 10).unwrap().len(), 1);
        excise(
            &h,
            user(),
            Target::Entity("task:a".into()),
            None,
            "r".into(),
            vec![],
        )
        .await
        .unwrap();
        assert!(find_fts(&ro(&path), &c, 10).unwrap().is_empty());
        assert!(
            !contains(&fts_bytes(&path), c.as_bytes()),
            "no token left in the index"
        );
        // The marker is indexed in its place, and the other entity is still found.
        let hits = find_fts(&ro(&path), "excised", 10).unwrap();
        assert_eq!(hits.iter().map(|h| h.n).collect::<Vec<_>>(), [n]);
        assert_eq!(find_fts(&ro(&path), "another", 10).unwrap().len(), 1);
        stop(w).await;
    }

    #[tokio::test]
    async fn vec_row_gone() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn(&dir);
        let (n, _) = create(&h, agent(), task("task:a", "a title here", "b", json!({}))).await;
        let (m, _) = create(&h, agent(), task("task:b", "b title here", "b", json!({}))).await;
        h.write(user(), move |tx: &mut Tx<'_>| {
            vec_put(tx, n, "m", &[0.5, -0.25])?;
            vec_put(tx, m, "m", &[0.5, -0.25])
        })
        .await
        .unwrap();
        excise(
            &h,
            user(),
            Target::Entity("task:a".into()),
            None,
            "r".into(),
            vec![],
        )
        .await
        .unwrap();
        let left: Vec<i64> = {
            let c = ro(&path);
            let mut st = c.prepare("select n from entity_vec order by n").unwrap();
            st.query_map([], |r| r.get(0))
                .unwrap()
                .map(|r| r.unwrap())
                .collect()
        };
        assert_eq!(
            left,
            [m],
            "the excised entity's vector is gone; the embedder makes it again"
        );
        stop(w).await;
    }

    /// Records what it was told and writes one row into the tests' `t` table with the tx it ran in.
    struct Probe {
        seen: std::sync::Mutex<Vec<Excised>>,
        fail: bool,
    }

    impl Blanker for Probe {
        fn blank(&self, tx: &mut Tx<'_>, excised: &Excised) -> Result<u64, WriteError> {
            self.seen.lock().unwrap().push(excised.clone());
            tx.sql()
                .execute("insert into t (v, tx) values (1, ?1)", [tx.id()])?;
            if self.fail {
                return Err(WriteError::Refused("the probe failed".into()));
            }
            Ok(2)
        }
    }

    #[tokio::test]
    async fn blankers_run_in_the_same_tx() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn(&dir);
        let (n, t1) = create(&h, agent(), task("task:a", "a title here", "b", json!({}))).await;
        let t2 = change(&h, agent(), n, body("b2".into())).await;
        let probe = Arc::new(Probe {
            seen: Default::default(),
            fail: false,
        });
        let twice: Vec<Arc<dyn Blanker>> = vec![probe.clone(), probe.clone()];
        let report = excise(
            &h,
            user(),
            Target::Entity("task:a".into()),
            None,
            "r".into(),
            twice,
        )
        .await
        .unwrap();
        assert_eq!(report.blanked, 4, "each blanker's count is summed");
        let seen = probe.seen.lock().unwrap().clone();
        assert_eq!(
            seen[0],
            Excised {
                entities: vec![n],
                txs: vec![t1, t2],
                marker: marker(report.tx),
            }
        );
        let txs: Vec<i64> = {
            let c = ro(&path);
            let mut st = c.prepare("select tx from t").unwrap();
            st.query_map([], |r| r.get(0))
                .unwrap()
                .map(|r| r.unwrap())
                .collect()
        };
        assert_eq!(txs, [report.tx, report.tx], "in the excise's own tx");
        // A failing blanker fails the whole excise: nothing is blanked, nothing logged.
        let (m, _) = create(
            &h,
            agent(),
            task("task:b", "keep this title", "b", json!({})),
        )
        .await;
        let failing: Arc<dyn Blanker> = Arc::new(Probe {
            seen: Default::default(),
            fail: true,
        });
        let e = excise(
            &h,
            user(),
            Target::Entity("task:b".into()),
            None,
            "r".into(),
            vec![failing],
        )
        .await
        .unwrap_err();
        assert_eq!(e, WriteError::Refused("the probe failed".into()));
        let c = ro(&path);
        let title: String = c
            .query_row("select title from entity where n = ?1", [m], |r| r.get(0))
            .unwrap();
        assert_eq!(title, "keep this title");
        let logged: i64 = c
            .query_row("select count(*) from excise_log", [], |r| r.get(0))
            .unwrap();
        assert_eq!(logged, 1, "only the first excise");
        stop(w).await;
    }

    #[tokio::test]
    async fn log_never_holds_content() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn(&dir);
        let c = canary();
        create(&h, agent(), task("task:a", &c, &c, json!({ "k": c }))).await;
        let report = excise(
            &h,
            user(),
            Target::Entity("task:a".into()),
            None,
            "a token was pasted".into(),
            vec![],
        )
        .await
        .unwrap();
        let row: (i64, String, String, String) = ro(&path)
            .query_row(
                "select tx, target, fields, reason from excise_log",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert_eq!(
            row,
            (
                report.tx,
                "task:a".into(),
                r#"["title","body","data"]"#.into(),
                "a token was pasted".into()
            )
        );
        // Neither the log nor the excise's own tx row nor its serialized report names the content.
        let tx_row: String = ro(&path)
            .query_row(
                "select json_array(actor, class, tool, note, answer) from tx where id = ?1",
                [report.tx],
                |r| r.get(0),
            )
            .unwrap();
        let shown = serde_json::to_string(&report).unwrap();
        for text in [format!("{row:?}"), tx_row, shown] {
            assert!(!text.contains(&c), "{text}");
        }
        assert!(
            report.needles.iter().any(|x| x == c.as_bytes()),
            "kept in memory only"
        );
        stop(w).await;
    }

    #[tokio::test]
    async fn tx_answer_and_note_are_blanked() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn(&dir);
        let c = canary();
        let title = format!("t {c}");
        let new = task("task:a", &title, "b", json!({}));
        let first = h
            .write(keyed("agent:s1", "r-1"), move |tx: &mut Tx<'_>| {
                Ok(entity::create(tx, new)?.title)
            })
            .await
            .unwrap();
        let n: i64 = ro(&path)
            .query_row("select n from entity where id = 'task:a'", [], |r| r.get(0))
            .unwrap();
        let mut noted = agent();
        noted.note = Some(format!("because {c}"));
        let t2 = change(&h, noted, n, body("b2".into())).await;
        let mut other = agent();
        other.note = Some("an unrelated note".into());
        create(&h, other, task("task:b", "b title here", "b", json!({}))).await;
        let report = excise(
            &h,
            user(),
            Target::Entity("task:a".into()),
            None,
            "r".into(),
            vec![],
        )
        .await
        .unwrap();
        let m = marker(report.tx);
        assert_eq!(report.txs_blanked, 2);
        let c2 = ro(&path);
        let row = |id: i64| -> (Option<String>, Option<String>) {
            c2.query_row("select answer, note from tx where id = ?1", [id], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap()
        };
        assert_eq!(
            row(first.tx),
            (Some(m.clone()), None),
            "an unset note stays unset"
        );
        assert_eq!(row(t2), (None, Some(m.clone())));
        let unrelated: String = c2
            .query_row(
                "select note from tx where note like 'an unrelated%'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(unrelated, "an unrelated note");
        assert!(
            report
                .needles
                .iter()
                .any(|x| x == format!("because {c}").as_bytes())
        );
        stop(w).await;
    }

    #[tokio::test]
    async fn a_replay_after_excise_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn(&dir);
        let make = || {
            let new = task("task:a", "a secret title", "b", json!({}));
            move |tx: &mut Tx<'_>| Ok(entity::create(tx, new)?.title)
        };
        let first = h.write(keyed("agent:s1", "r-1"), make()).await.unwrap();
        assert_eq!(first.value.as_deref(), Some("a secret title"));
        excise(
            &h,
            user(),
            Target::Entity("task:a".into()),
            None,
            "r".into(),
            vec![],
        )
        .await
        .unwrap();
        let again = h.write(keyed("agent:s1", "r-1"), make()).await.unwrap_err();
        assert_eq!(
            again,
            WriteError::Refused("this answer was excised; read the entity".into())
        );
        let entities: i64 = ro(&path)
            .query_row("select count(*) from entity", [], |r| r.get(0))
            .unwrap();
        assert_eq!(entities, 1, "the repeat ran nothing");
        stop(w).await;
    }

    /// A keyed write that wrote no version of the target still loses its answer when the answer quotes the target's
    /// text, or the write linked the target: its replay names nothing of it (call 3).
    #[tokio::test]
    async fn an_answer_that_names_the_target_is_blanked() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn(&dir);
        let c = canary();
        let title = format!("t {c}");
        let (a, _) = create(&h, agent(), task("task:a", &title, "b", json!({}))).await;
        let (b, _) = create(&h, agent(), task("task:b", "b title here", "b", json!({}))).await;
        // Writes a version of task:b only, and answers task:a's title.
        let quote = move || {
            move |tx: &mut Tx<'_>| -> Result<Option<String>, WriteError> {
                entity::update(tx, b, None, body("b2".into()))?;
                Ok(tx
                    .sql()
                    .query_row("select title from entity where n = ?1", [a], |r| r.get(0))?)
            }
        };
        let first = h.write(keyed("agent:s1", "q-1"), quote()).await.unwrap();
        assert_eq!(first.value.as_deref(), Some(title.as_str()));
        // Links task:a, and answers nothing of its text.
        let link = move || {
            move |tx: &mut Tx<'_>| -> Result<String, WriteError> {
                crate::graph::link::add(tx, a, "blocks", b, None, Origin::Recorded, None)?;
                Ok("linked".into())
            }
        };
        h.write(keyed("agent:s1", "l-1"), link()).await.unwrap();
        let mut plain = agent();
        plain.note = Some("an unrelated note".into());
        let other = change(&h, plain, b, body("b3".into())).await;
        let report = excise(
            &h,
            user(),
            Target::Entity("task:a".into()),
            None,
            "r".into(),
            vec![],
        )
        .await
        .unwrap();
        let excised = WriteError::Refused("this answer was excised; read the entity".into());
        let again = h
            .write(keyed("agent:s1", "q-1"), quote())
            .await
            .unwrap_err();
        assert_eq!(again, excised);
        let again = h.write(keyed("agent:s1", "l-1"), link()).await.unwrap_err();
        assert_eq!(again, excised);
        let c2 = ro(&path);
        let left: i64 = c2
            .query_row(
                "select count(*) from tx where instr(coalesce(answer, '') || coalesce(note, ''), ?1) > 0",
                [&c],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(left, 0, "no tx row keeps the target's text");
        let note: String = c2
            .query_row("select note from tx where id = ?1", [other], |r| r.get(0))
            .unwrap();
        assert_eq!(
            note, "an unrelated note",
            "a tx that names nothing of it stays"
        );
        assert_eq!(report.entities, 1);
        stop(w).await;
    }

    #[tokio::test]
    async fn holding_lists_pre7_and_schema5() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn(&dir);
        let c = canary();
        // A quote in the title: an export holds it JSON-escaped.
        let title = format!("say \"{c}\"");
        create(&h, agent(), task("task:a", &title, "b", json!({}))).await;
        let report = excise(
            &h,
            user(),
            Target::Entity("task:a".into()),
            None,
            "r".into(),
            vec![],
        )
        .await
        .unwrap();
        let data = dir.path();
        let backup = data.join("backup");
        let export = data.join("export").join("e1");
        fs::create_dir_all(&backup).unwrap();
        fs::create_dir_all(&export).unwrap();
        let mut held = title.clone().into_bytes();
        held.splice(0..0, vec![0u8; CHUNK - 5]); // across a chunk boundary
        fs::write(backup.join("work-20261020.db"), &held).unwrap();
        fs::write(backup.join("work-pre7-1761000000.db"), format!("x{title}x")).unwrap();
        fs::write(backup.join("work-20261021.db"), b"nothing here").unwrap();
        fs::write(data.join("work.db.schema5"), title.as_bytes()).unwrap();
        // What `restore-pre7` moved aside: a schema-7 file and its WAL.
        fs::write(data.join("work.db.schema7-1761000100"), b"no text").unwrap();
        fs::write(
            data.join("work.db.schema7-1761000100-wal"),
            title.as_bytes(),
        )
        .unwrap();
        let escaped = serde_json::to_string(&title).unwrap();
        fs::write(
            export.join("entities.jsonl"),
            format!("{{\"title\":{escaped}}}\n"),
        )
        .unwrap();
        fs::write(export.join("links.jsonl"), b"").unwrap();
        let files = kept_copies(&path);
        assert_eq!(
            files,
            [
                backup.join("work-20261020.db"),
                backup.join("work-20261021.db"),
                backup.join("work-pre7-1761000000.db"),
                data.join("work.db.schema5"),
                data.join("work.db.schema7-1761000100"),
                data.join("work.db.schema7-1761000100-wal"),
                export.join("entities.jsonl"),
                export.join("links.jsonl"),
            ]
        );
        let mut with_gone = files.clone();
        with_gone.push(backup.join("gone.db"));
        assert_eq!(
            holding(&with_gone, &report.needles),
            [
                backup.join("work-20261020.db"),
                backup.join("work-pre7-1761000000.db"),
                data.join("work.db.schema5"),
                data.join("work.db.schema7-1761000100-wal"),
                export.join("entities.jsonl"),
            ]
        );
        assert!(holding(&files, &[]).is_empty());
        stop(w).await;
    }

    #[test]
    fn redact_rewrites_in_place() {
        let dir = tempfile::tempdir().unwrap();
        let c = canary();
        let file = dir.path().join("s1.jsonl");
        let title = format!("say \"{c}\"");
        let line = format!("{{\"text\":{}}}\n", serde_json::to_string(&title).unwrap());
        fs::write(&file, format!("{line}{{\"text\":\"plain\"}}\n")).unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        let mut needles = BTreeSet::new();
        push_needle(&title, &mut needles);
        let needles: Vec<Vec<u8>> = needles.into_iter().collect();
        assert!(redact(&file, &needles, "[excised 9]").unwrap());
        let text = fs::read_to_string(&file).unwrap();
        assert_eq!(text, "{\"text\":\"[excised 9]\"}\n{\"text\":\"plain\"}\n");
        let mode = fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert!(!tmp_of(&file).exists());
        assert!(
            !redact(&file, &needles, "[excised 9]").unwrap(),
            "nothing left"
        );
    }

    #[tokio::test]
    async fn no_trace_in_file_or_wal() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn(&dir);
        let c = canary();
        // A keyed write whose answer is the canary title.
        let new = task(
            "task:a",
            &format!("t {c}"),
            &format!("b1 {c}"),
            json!({ "k": c }),
        );
        h.write(keyed("agent:s1", "r-1"), move |tx: &mut Tx<'_>| {
            Ok(entity::create(tx, new)?.title)
        })
        .await
        .unwrap();
        let n: i64 = ro(&path)
            .query_row("select n from entity where id = 'task:a'", [], |r| r.get(0))
            .unwrap();
        // The body edited twice (three versions); a tx note.
        let mut noted = agent();
        noted.note = Some(format!("why {c}"));
        change(&h, noted, n, body(format!("b2 {c}"))).await;
        change(&h, agent(), n, body(format!("b3 {c}"))).await;
        let both = |path: &Path| [bytes(path), bytes(&wal(path))].concat();
        assert!(
            contains(&both(&path), c.as_bytes()),
            "the canary is in the file first"
        );
        excise(
            &h,
            user(),
            Target::Entity("task:a".into()),
            None,
            "r".into(),
            vec![],
        )
        .await
        .unwrap();
        let report = scrub(&h).await.unwrap();
        assert_eq!(
            report,
            ScrubReport {
                vacuumed: true,
                wal_truncated: true,
                blocked_by: None
            }
        );
        assert!(
            !contains(&bytes(&path), c.as_bytes()),
            "work.db holds the canary"
        );
        assert!(
            !contains(&bytes(&wal(&path)), c.as_bytes()),
            "work.db-wal holds the canary"
        );
        stop(w).await;
    }

    #[tokio::test]
    async fn a_reader_blocks_truncate_and_the_report_says_so() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h, path) = spawn(&dir);
        create(&h, agent(), task("task:a", "a title here", "b", json!({}))).await;
        // A read transaction pins a snapshot in the WAL.
        let reader = ro(&path);
        reader.execute_batch("begin").unwrap();
        let _: i64 = reader
            .query_row("select count(*) from entity", [], |r| r.get(0))
            .unwrap();
        excise(
            &h,
            user(),
            Target::Entity("task:a".into()),
            None,
            "r".into(),
            vec![],
        )
        .await
        .unwrap();
        let report = scrub(&h).await.unwrap();
        assert!(!report.wal_truncated);
        assert_eq!(
            report.blocked_by,
            Some(crate::graph::writer::Blocker::Readers)
        );
        let shown = serde_json::to_value(&report).unwrap();
        assert_eq!(shown["wal_truncated"], json!(false));
        assert_eq!(shown["blocked_by"], json!("readers"));
        // Once the reader is gone, scrub on its own finishes the job.
        reader.execute_batch("commit").unwrap();
        drop(reader);
        let again = scrub(&h).await.unwrap();
        assert!(
            again.wal_truncated && again.blocked_by.is_none(),
            "{again:?}"
        );
        stop(w).await;
    }
}
