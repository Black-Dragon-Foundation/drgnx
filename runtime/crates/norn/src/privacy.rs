//! The personal-file opt-in applied (Task 9b; answer 2, call 8, question 5): on `graph/privacy {reload}`, at the
//! hub's start and whenever `personal-notes-allow.json` or `personal-notes-deny.json` changes, by the user's commands
//! or by anything else (any same-uid process can write them, M9b2-11).
//!
//! - **The applied state** (`kv` [`APPLIED_KEY`]: the opt-ins, the user's own deny entries and the ignored entries,
//!   as last applied) is written here only, in a user-class tx (the `privacy:` key guard, [`register`]).
//! - **What the list now denies goes:** every entity one of whose paths ([`deny::paths_of`]: its source, the path in
//!   its id, `data.path`) is absolute and denied by the list just loaded is retired with its links and excised (all
//!   fields, every version, FTS, vectors, the coordination blankers), and the store is scrubbed. That covers a
//!   revoked opt-in (soft tier again), a new deny entry (hard tier) and a change made while the hub was down. Added
//!   opt-ins need nothing: the next scan reads them.
//! - **Every change is announced:** an `event` row in the same tx as the applied state ("personal-file opt-ins
//!   changed: +X / −Y", counts only, never a path), and [`PrivacyReport::notice`] for the hub to send its editors.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use urdr::graph::excise::{self, Target};
use urdr::graph::guard::{self, Guard};
use urdr::graph::schema::SENTINEL;
use urdr::graph::{Class, TxMeta, WriteError, WriterHandle, entity, link};

use crate::deny::{self, ALLOW_FILE, DENY_FILE, DenyList, EntryKind, SharedDeny, Source, Verdict};
use crate::store::CoordError;
use crate::write::event::{self, Event, EventKind};

/// The `kv` key of the applied state. Nothing but [`apply`] writes it.
pub const APPLIED_KEY: &str = "privacy:applied";

/// The `kv` keys only the user's class writes (the applied state).
pub const KEY_PREFIX: &str = "privacy:";

/// The excise's reason in `excise_log`.
pub const REASON: &str = "personal-file opt-in revoked";

/// The guard's refusal of a `privacy:` key from any other class.
pub const PRIVACY_IS_THE_USERS: &str = "the personal-file opt-ins are the user's";

/// The refusal that rolls back [`apply`]'s read in the writer when the list denies nothing stored.
const NOTHING_DENIED: &str = "nothing stored is denied";

/// What applying a change of the opt-ins did.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct PrivacyReport {
    pub added: Vec<PathBuf>,
    pub removed: Vec<PathBuf>,
    /// Entries the hard tier or the shape rules rejected.
    pub ignored: Vec<String>,
    pub excised: u64,
    /// The backups and set-aside copies ([`deletable_copies`]) that still hold an excised value: listed, never
    /// deleted here; the user's revoke command deletes them after asking ([`delete_copies`]).
    pub backups_holding: Vec<PathBuf>,
    /// The exports that still hold one: the user's own files, only listed.
    #[serde(default)]
    pub exports_holding: Vec<PathBuf>,
    /// The user's own deny entries added and removed (`kind:path`).
    #[serde(default)]
    pub denied_added: Vec<String>,
    #[serde(default)]
    pub denied_removed: Vec<String>,
    /// The notice's text when something changed (it was written as an `event` row); `None` when nothing did.
    #[serde(default)]
    pub notice: Option<String>,
}

/// The opt-in files as last seen by [`tick`].
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Watch {
    /// `personal-notes-allow.json`'s `(mtime, size)`.
    pub seen: Option<(SystemTime, u64)>,
    /// `personal-notes-deny.json`'s `(mtime, size)`.
    pub deny_seen: Option<(SystemTime, u64)>,
    /// The first tick has applied (at the hub's start, against the applied state in `kv`).
    pub started: bool,
    /// The last failure said, so a store that stays unready is said once.
    pub failed: Option<String>,
}

/// Put the opt-in's class rule into GUARD: `kv` keys `privacy:*` are the user's.
pub fn register(guard: &mut Guard) {
    guard::register_key_prefix(guard, KEY_PREFIX, Class::User, PRIVACY_IS_THE_USERS);
}

/// The applied state, as `kv` keeps it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct Applied {
    #[serde(default)]
    opt_ins: Vec<String>,
    #[serde(default)]
    denied: Vec<String>,
    #[serde(default)]
    ignored: Vec<String>,
}

impl Applied {
    /// DENY's state: the opt-ins that open something (an opt-in in the hard tier is ignored), its user entries and
    /// its warnings.
    fn of(deny: &DenyList) -> Applied {
        let opt_ins = deny
            .opt_ins()
            .iter()
            .filter(|p| deny.check(p) == Verdict::OptedIn)
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        let denied = deny
            .user_entries()
            .iter()
            .map(|e| {
                let kind = match e.kind {
                    EntryKind::File => "file",
                    EntryKind::Folder => "folder",
                    EntryKind::Glob => "glob",
                };
                format!("{kind}:{}", e.path.to_string_lossy())
            })
            .collect();
        Applied {
            opt_ins,
            denied,
            ignored: deny.warnings().to_vec(),
        }
    }
}

/// What is in NEW and not in OLD.
fn minus(new: &[String], old: &[String]) -> Vec<String> {
    let old: BTreeSet<&String> = old.iter().collect();
    new.iter().filter(|s| !old.contains(s)).cloned().collect()
}

/// An entity the list now denies.
struct Found {
    n: i64,
    id: String,
    /// The path of its source, when it has one (its `parsed_file` row goes).
    source: Option<String>,
}

/// Whether one of the absolute paths the record carries is denied by DENY. A relative path (a `file:` id of a code
/// file, `~/…`) is not looked at: the doors refuse those, and what a door let in is not removed for its form.
fn carries_denied(deny: &DenyList, source: Option<&str>, id: &str, data: &Value) -> bool {
    let source = source.and_then(Source::parse).unwrap_or(Source::Recorded);
    deny::paths_of(&source, id, data)
        .iter()
        .filter(|p| p.is_absolute())
        .any(|p| matches!(deny.check(p), Verdict::Denied { .. }))
}

/// The applied state in C (none when never applied).
fn applied_in(c: &urdr::Connection) -> Result<Applied, urdr::SqliteError> {
    let text: Option<String> =
        match c.query_row("select value from kv where key = ?1", [APPLIED_KEY], |r| {
            r.get(0)
        }) {
            Ok(v) => v,
            Err(urdr::SqliteError::QueryReturnedNoRows) => None,
            Err(e) => return Err(e),
        };
    Ok(text
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default())
}

/// The entities of C that carry a path DENY denies, except those already retired and excised since.
fn denied_in(c: &urdr::Connection, deny: &DenyList) -> Result<Vec<Found>, urdr::SqliteError> {
    let mut stmt = c.prepare(
        "select e.n, e.id, e.source, e.data from entity e \
         where (e.source is not null or e.id glob '*:/*' or json_extract(e.data, '$.path') is not null) \
           and not (e.retired_tx is not null \
                    and exists (select 1 from excise_log x where x.target = e.id and x.tx >= e.retired_tx))",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, Option<String>>(2)?,
            r.get::<_, String>(3)?,
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (n, id, source, data) = row?;
        let data: Value = serde_json::from_str(&data).unwrap_or(Value::Null);
        if carries_denied(deny, source.as_deref(), &id, &data) {
            let source = source
                .as_deref()
                .and_then(Source::parse)
                .and_then(|s| match s {
                    Source::File(p) | Source::Spec(p) => Some(p.to_string_lossy().into_owned()),
                    _ => None,
                });
            out.push(Found { n, id, source });
        }
    }
    Ok(out)
}

/// What [`apply`] read in the writer: the applied state, and the entities the list now denies.
type Read = (Applied, Vec<Found>);

/// The user's tx: the files are the user's, whoever wrote them.
fn meta() -> TxMeta {
    TxMeta::new("user", Class::User, "privacy")
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// The notice's text: counts only, never a path (an agent may read the event log).
fn notice_text(r: &PrivacyReport) -> String {
    let mut text = format!(
        "personal-file opt-ins changed: +{} / −{}",
        r.added.len(),
        r.removed.len()
    );
    if !(r.denied_added.is_empty() && r.denied_removed.is_empty()) {
        text.push_str(&format!(
            "; your deny list: +{} / −{}",
            r.denied_added.len(),
            r.denied_removed.len()
        ));
    }
    if !r.ignored.is_empty() {
        text.push_str(&format!("; {} ignored", r.ignored.len()));
    }
    if r.excised > 0 {
        text.push_str(&format!("; {} excised", r.excised));
    }
    text
}

fn coord(e: CoordError) -> WriteError {
    match e {
        CoordError::Refused(t) => WriteError::Refused(t),
        other => WriteError::Sql(other.to_string()),
    }
}

/// Retire the entities FOUND and their current links, and forget their source files' `parsed_file` rows (so a
/// later opt-in reads the file again), in TX.
fn retire_all(
    tx: &mut urdr::graph::Tx<'_>,
    found: &[(i64, Option<String>)],
) -> Result<(), WriteError> {
    for (n, _) in found {
        // two plain lookups, not `src = ?1 or dst = ?1`: SQLite 3.53.2 plans that OR as a covering-index loop
        // and fails with "internal query planner error"
        let links: Vec<(i64, String, i64)> = {
            let mut stmt = tx.sql().prepare(
                "select src, kind, dst from link where src = ?1 and tx_to = ?2 \
                 union select src, kind, dst from link where dst = ?1 and tx_to = ?2",
            )?;
            stmt.query_map((n, SENTINEL), |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                .collect::<Result<_, _>>()?
        };
        for (src, kind, dst) in links {
            link::retire(tx, src, &kind, dst)?;
        }
        entity::retire(tx, *n)?;
    }
    for path in found.iter().filter_map(|(_, s)| s.as_deref()) {
        tx.sql().execute(
            "delete from parsed_file where path = ?1 and not exists \
             (select 1 from entity where source in (?1, 'spec ' || ?1) and retired_tx is null)",
            [path],
        )?;
    }
    Ok(())
}

/// Apply DENY, the list just loaded (and already in force, so no door lets back in what goes here), against the
/// applied state in `kv`: what it now denies is retired and excised, then the applied state and the notice are
/// written in one tx, then the store is scrubbed. Nothing is written when nothing changed. The caller loads DENY;
/// this reads no file but the store.
pub async fn apply(writer: &WriterHandle, deny: Arc<DenyList>) -> Result<PrivacyReport, String> {
    #[cfg(test)]
    tests::hooks::reads(writer.path());
    // What the list now denies is read, and retired, inside the writer (call 8): every write queued before this one
    // (a scan's put with the list it read before the change) has committed by then, and every write after it reads
    // DENY. A read from a pool snapshot would miss a put still in the writer, which then stayed.
    let seen: Arc<Mutex<Option<Read>>> = Arc::default();
    let (d, s) = (Arc::clone(&deny), Arc::clone(&seen));
    let retired = writer
        .write(meta(), move |tx| {
            let old = applied_in(tx.sql())?;
            let found = denied_in(tx.sql(), &d)?;
            let doomed: Vec<(i64, Option<String>)> =
                found.iter().map(|f| (f.n, f.source.clone())).collect();
            *s.lock().unwrap_or_else(PoisonError::into_inner) = Some((old, found));
            if doomed.is_empty() {
                // rolled back: nothing to retire leaves no tx row
                return Err(WriteError::Refused(NOTHING_DENIED.into()));
            }
            retire_all(tx, &doomed)
        })
        .await;
    let Some((old, found)) = seen.lock().unwrap_or_else(PoisonError::into_inner).take() else {
        return Err(retired.map_or_else(|e| e.to_string(), |_| "nothing was read".into()));
    };
    if let Err(e) = retired
        && !found.is_empty()
    {
        return Err(e.to_string());
    }
    let new = Applied::of(&deny);
    let mut report = PrivacyReport {
        added: minus(&new.opt_ins, &old.opt_ins)
            .into_iter()
            .map(PathBuf::from)
            .collect(),
        removed: minus(&old.opt_ins, &new.opt_ins)
            .into_iter()
            .map(PathBuf::from)
            .collect(),
        ignored: new.ignored.clone(),
        denied_added: minus(&new.denied, &old.denied),
        denied_removed: minus(&old.denied, &new.denied),
        ..PrivacyReport::default()
    };
    if new == old && found.is_empty() {
        return Ok(report);
    }
    let mut needles = Vec::new();
    if !found.is_empty() {
        for f in &found {
            let rep = excise::excise(
                writer,
                meta(),
                Target::Entity(f.id.clone()),
                Some(excise::FIELDS.iter().map(|s| s.to_string()).collect()),
                REASON.into(),
                crate::write::blankers(),
            )
            .await
            .map_err(|e| e.to_string())?;
            needles.extend(rep.needles);
            report.excised += 1;
        }
    }
    let text = notice_text(&report);
    let state = serde_json::to_string(&new).map_err(|e| e.to_string())?;
    let data = json!({
        "privacy": true,
        "added": report.added.len(),
        "removed": report.removed.len(),
        "denied_added": report.denied_added.len(),
        "denied_removed": report.denied_removed.len(),
        "ignored": report.ignored.len(),
        "excised": report.excised,
    });
    let summary = text.clone();
    writer
        .write(meta(), move |tx| {
            guard::check_key(tx.guard(), tx.meta(), APPLIED_KEY)?;
            tx.sql().execute(
                "insert into kv (key, value) values (?1, ?2) \
                 on conflict (key) do update set value = excluded.value",
                (APPLIED_KEY, &state),
            )?;
            event::event(
                tx,
                Event {
                    at: now(),
                    agent: None,
                    job: None,
                    task: None,
                    kind: EventKind::Status,
                    summary,
                    data: Some(data),
                    turn: false,
                },
            )
            .map_err(coord)?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?;
    if !found.is_empty() {
        if let Err(e) = excise::scrub(writer).await {
            tracing::warn!("the scrub after a personal file's excise failed: {e}");
        }
        let deletable = deletable_copies(writer.path());
        for f in excise::holding(&excise::kept_copies(writer.path()), &needles) {
            if deletable.contains(&f) {
                report.backups_holding.push(f);
            } else {
                report.exports_holding.push(f);
            }
        }
    }
    report.notice = Some(text);
    Ok(report)
}

/// The copies of WORK_DB a revoke may delete: [`excise::kept_copies`] (the backups, `work.db.schema5`, the
/// `work.db.schema7-*` a rollback set aside) without the exports, which are the user's own files.
pub fn deletable_copies(work_db: &Path) -> Vec<PathBuf> {
    let export = work_db.parent().unwrap_or(Path::new(".")).join("export");
    excise::kept_copies(work_db)
        .into_iter()
        .filter(|p| !p.starts_with(&export))
        .collect()
}

/// Delete the copies of WANTED that are [`deletable_copies`] of WORK_DB (anything else is left alone); those
/// deleted. Only for the user's own confirmed request (`graph/privacy {delete_copies}`); [`apply`] and [`tick`]
/// never delete: a change of the opt-in file by anything else must not cost a backup.
/// A name counts only when it is absolute with no `.` or `..`, is itself a regular file (not a link), resolves
/// (`canonicalize`) inside WORK_DB's resolved folder, and is one of the copies as listed.
pub fn delete_copies(work_db: &Path, wanted: &[PathBuf]) -> Vec<PathBuf> {
    use std::path::Component;
    let Some(data) = work_db.parent().and_then(|d| std::fs::canonicalize(d).ok()) else {
        return Vec::new();
    };
    let safe = |p: &PathBuf| {
        p.is_absolute()
            && p.components()
                .all(|c| matches!(c, Component::RootDir | Component::Normal(_)))
            && std::fs::symlink_metadata(p).is_ok_and(|m| m.is_file())
            && std::fs::canonicalize(p).is_ok_and(|real| real.starts_with(&data))
    };
    let wanted: Vec<&PathBuf> = wanted.iter().filter(|p| safe(p)).collect();
    let mut gone = Vec::new();
    for f in deletable_copies(work_db) {
        if !wanted.contains(&&f) {
            continue;
        }
        match std::fs::remove_file(&f) {
            Ok(()) => gone.push(f),
            Err(e) => tracing::warn!("cannot delete {}: {e}", f.display()),
        }
    }
    gone
}

/// FILE's `(mtime, size)`; `None` when it is missing or cannot be read.
fn stamp(file: &Path) -> Option<(SystemTime, u64)> {
    let meta = std::fs::metadata(file).ok()?;
    Some((meta.modified().ok()?, meta.len()))
}

/// The hub's tick: at the first one, and whenever `CONFIG_DIR/personal-notes-allow.json` or
/// `personal-notes-deny.json` moved (`(mtime, size)`), reload the list into DENY (in force at once) and [`apply`] it.
/// The report when it changed something; a failure (a store not ready yet) is tried again at the next tick.
pub async fn tick(
    watch: &mut Watch,
    writer: &WriterHandle,
    deny: &SharedDeny,
    home: &Path,
    config_dir: &Path,
) -> Option<PrivacyReport> {
    let now = (
        stamp(&config_dir.join(ALLOW_FILE)),
        stamp(&config_dir.join(DENY_FILE)),
    );
    if watch.started && (watch.seen, watch.deny_seen) == now {
        return None;
    }
    let (h, c) = (home.to_path_buf(), config_dir.to_path_buf());
    let list = Arc::new(
        tokio::task::spawn_blocking(move || DenyList::load(&h, &c))
            .await
            .ok()?,
    );
    *deny.write().unwrap_or_else(|e| e.into_inner()) = Arc::clone(&list);
    match apply(writer, list).await {
        Ok(r) => {
            (watch.seen, watch.deny_seen) = now;
            watch.started = true;
            watch.failed = None;
            r.notice.is_some().then_some(r)
        }
        Err(e) => {
            if watch.failed.as_deref() != Some(e.as_str()) {
                tracing::warn!("the personal-notes opt-ins are not applied yet: {e}");
                watch.failed = Some(e);
            }
            None
        }
    }
}

#[cfg(test)]
mod tests;
