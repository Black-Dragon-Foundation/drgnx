//! `graph/put-parsed` and `graph/record` applied in one tx (Task 15a; storage §5.6 door 1, §9 step 3): typed
//! sources, every path a record carries checked against the deny-list, content compare, derived statuses
//! (docs/develop/store.md, "Parsed entities").
//!
//! - **Door 1, per source.** Every path a source's records carry is checked: the source's own path, the path inside
//!   each path-form id (`spec:/…`, `plan:/…`, `task:/…#n`, …), `data.path`, `data.repo`, `data.worktree`, the id in
//!   `data.parent`, and the ids at both ends of each link. One denied path refuses the whole source, which then
//!   stores nothing (not even its file's time).
//! - **Consistency.** A `file` source holds plans, tasks, steps, rulings, todos and its `file:` entity, each carrying
//!   the source's path; a `spec` source is one `spec:PATH`; a `commit` or `branch` source holds commits or branches,
//!   whose ids carry no path. Anything else refuses the source (a plan whose `**Spec:**` names another file sends that
//!   spec as its own source, and its `derives` link is checked at both ends).
//! - **Content compare.** An entity whose fields are as stored is untouched; a changed one gets a new version (its
//!   `data` replaced as sent); one a `file` or `spec` source no longer holds is retired, and comes back when it holds
//!   it again. A `file` or `spec` source's links are retired and added by difference; a `commit` or `branch` source
//!   only adds.
//! - **Updates** carry the scan's derived attributes: `status` (`open`, `done`) on a parsed task, step or plan, and a
//!   merge patch of [`PATCH_KEYS`]. An update of this request's own entity is folded in before the compare, so a
//!   rescan that derives the same thing writes nothing.
//! - **Cleanups** (the Lisp `drgnx-work-forget-orphan-commits` and its spec rule): a scanned commit no live link names,
//!   and a spec no plan `derives` that lies outside a `specs/` folder, are retired, except what this request sent.

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::{Path, PathBuf};

use runstav::methods::graph::{
    self as api, LinkOrigin, ParsedSource, ParsedUpdate, Refusal, SourceKind, SourceRef,
};
use serde_json::{Map, Value, json};
use urdr::Connection;
use urdr::graph::entity::{self, Changes, EntityNew, Origin, Update};
use urdr::graph::link;
use urdr::graph::schema::SENTINEL;
use urdr::graph::{Tx, WriteError};

use crate::deny::{DenyList, Source, Verdict, paths_of};
use crate::kinds;
use crate::project::{self, ProjectCache};
use crate::store::CoordError;

/// `graph/put-parsed`'s params (runstav's wire type).
pub type PutParsed = api::PutParsedParams;
/// `graph/put-parsed`'s answer `{changed, retired, refused}`.
pub type PutAnswer = api::PutParsedAnswer;
/// `graph/record`'s params.
pub type Record = api::RecordParams;
/// `graph/record`'s answer `{ids}`.
pub type RecordAnswer = api::RecordAnswer;

/// Why a denied source or update is refused (it never names the path).
pub const DENIED: &str = "personal notes are never stored";

/// The statuses an update may set, on a parsed task, step or plan.
pub const STATUSES: &[&str] = &["open", "done"];

/// The `data` keys an update may patch: flags (`true`, `false`, `null`) and texts (`null` too); the two paths are
/// absolute and checked against the deny-list.
pub const PATCH_KEYS: &[&str] = &[
    "gone",
    "stale",
    "range-stale",
    "merged",
    "branch",
    "worktree",
    "repo",
];
const FLAG_KEYS: &[&str] = &["gone", "stale", "range-stale", "merged"];
const PATH_KEYS: &[&str] = &["worktree", "repo"];

/// The kinds a `file` source holds.
const FILE_KINDS: &[&str] = &["plan", "task", "step", "ruling", "todo", "file"];
/// The kinds whose id is `KIND:PATH#SUFFIX` (the others of a file are `KIND:PATH`).
const SUFFIXED: &[&str] = &["task", "step", "ruling", "todo"];
/// The kinds the scan makes (Names: "parsed").
const PARSED_KINDS: &[&str] = &[
    "spec", "plan", "task", "step", "ruling", "todo", "file", "commit", "branch",
];

/// The kind an id names (`plan:/x.md` → `plan`).
fn kind_of(id: &str) -> Option<&str> {
    id.split_once(':').map(|(k, _)| k)
}

fn is_denied(v: &Verdict) -> bool {
    matches!(v, Verdict::Denied { .. })
}

/// The source column's text for S, as schema 6 kept it (`PATH`, `spec PATH`, `commit`, `branch`); `None` when the
/// source is not well formed (a path where none belongs, or none where one does).
pub fn source_text(s: &SourceRef) -> Option<String> {
    match (s.kind, &s.path) {
        (SourceKind::File, Some(p)) => Some(p.as_str().to_string()),
        (SourceKind::Spec, Some(p)) => Some(format!("spec {}", p.as_str())),
        (SourceKind::Commit, None) => Some("commit".into()),
        (SourceKind::Branch, None) => Some("branch".into()),
        _ => None,
    }
}

fn deny_source(s: &SourceRef) -> Source {
    match (s.kind, &s.path) {
        (SourceKind::File, Some(p)) => Source::File(PathBuf::from(p.as_str())),
        (SourceKind::Spec, Some(p)) => Source::Spec(PathBuf::from(p.as_str())),
        (SourceKind::Commit, _) => Source::Commit,
        (SourceKind::Branch, _) => Source::Branch,
        // a file or spec without a path: refused by its shape before anything is stored
        _ => Source::Recorded,
    }
}

/// VALUE with every `null` member left out, at any depth (a key set to `null` is a key not sent).
fn strip_nulls(value: Value) -> Value {
    match value {
        Value::Object(m) => Value::Object(
            m.into_iter()
                .filter(|(_, v)| !v.is_null())
                .map(|(k, v)| (k, strip_nulls(v)))
                .collect(),
        ),
        other => other,
    }
}

fn data_of(e: &api::ParsedEntity) -> Map<String, Value> {
    match e.data.clone() {
        Some(d) => match strip_nulls(Value::Object(d.into_inner())) {
            Value::Object(m) => m,
            _ => Map::new(),
        },
        None => Map::new(),
    }
}

/// Whether the id ID (an entity's, a link's end, a `data.parent`) carries a denied path.
fn id_denied(deny: &DenyList, id: &str) -> bool {
    paths_of(&Source::Recorded, id, &json!({}))
        .iter()
        .any(|p| is_denied(&deny.check(p)))
}

/// Whether the text at DATA's KEY, when there is one, is a denied path.
fn data_path_denied(deny: &DenyList, data: &Map<String, Value>, key: &str) -> bool {
    data.get(key)
        .and_then(Value::as_str)
        .is_some_and(|p| is_denied(&deny.check(Path::new(p))))
}

/// Door 1: whether any path the source S carries is denied.
fn source_denied(deny: &DenyList, s: &ParsedSource) -> bool {
    let src = deny_source(&s.source);
    if let Source::File(p) | Source::Spec(p) = &src
        && is_denied(&deny.check(p))
    {
        return true;
    }
    for e in s.entities.iter().flat_map(|v| v.iter()) {
        let data = data_of(e);
        if is_denied(&deny.check_record(&src, &e.id, &Value::Object(data.clone())))
            || data_path_denied(deny, &data, "repo")
            || data_path_denied(deny, &data, "worktree")
            || data
                .get("parent")
                .and_then(Value::as_str)
                .is_some_and(|p| id_denied(deny, p))
        {
            return true;
        }
    }
    s.links
        .iter()
        .flat_map(|v| v.iter())
        .any(|l| id_denied(deny, &l.src) || id_denied(deny, &l.dst))
}

/// The link kind and data a parsed link NAME from FROM to TO is kept as: a kind of storage §5.4 that joins them
/// (`on-branch` read as `on_branch`), or `relates` with `data.was` for schema 6's `ledger-of` (as the migration keeps
/// it); `None` for anything else.
fn link_as(name: &str, from: &str, to: &str) -> Option<(String, Option<Value>)> {
    let name = if name == "on-branch" {
        "on_branch"
    } else {
        name
    };
    if kinds::link_allowed(name, from, to) {
        Some((name.to_string(), None))
    } else if name == "ledger-of" {
        Some(("relates".into(), Some(json!({ "was": name }))))
    } else {
        None
    }
}

/// Whether ID is of KIND and carries PATH as a file source's entity must (`KIND:PATH`, or `KIND:PATH#…` for a
/// suffixed kind).
fn id_carries(id: &str, kind: &str, path: &str) -> bool {
    let Some(rest) = id.strip_prefix(kind).and_then(|r| r.strip_prefix(':')) else {
        return false;
    };
    rest == path
        || (SUFFIXED.contains(&kind)
            && rest
                .strip_prefix(path)
                .is_some_and(|tail| tail.starts_with('#')))
}

/// The source S's shape (after door 1): what it may hold, and that every entity carries its path. Reads TX for ids
/// stored as another kind.
fn check_shape(tx: &Tx<'_>, s: &ParsedSource) -> Result<(), String> {
    if source_text(&s.source).is_none() {
        return Err("a file or spec source names its path; a commit or branch source none".into());
    }
    let path = s.source.path.as_ref().map(|p| p.as_str().to_string());
    for e in s.entities.iter().flat_map(|v| v.iter()) {
        let (id, kind) = (e.id.as_str(), e.kind.as_str());
        let fits = match s.source.kind {
            SourceKind::File => FILE_KINDS.contains(&kind),
            SourceKind::Spec => kind == "spec",
            SourceKind::Commit => kind == "commit",
            SourceKind::Branch => kind == "branch",
        };
        if !fits {
            return Err(format!(
                "a {} source holds no {kind} (parsed kinds only)",
                s.source.kind.as_str()
            ));
        }
        match (&path, s.source.kind) {
            (Some(p), SourceKind::File | SourceKind::Spec) => {
                if !id_carries(id, kind, p) {
                    return Err(format!(
                        "{id} does not carry its source's path (a {kind} of this file is {kind}:PATH{})",
                        if SUFFIXED.contains(&kind) { "#…" } else { "" }
                    ));
                }
                let data = data_of(e);
                if let Some(dp) = data.get("path")
                    && dp.as_str() != Some(p.as_str())
                {
                    return Err(format!("{id}: its data.path is not its source's path"));
                }
            }
            (_, SourceKind::Commit) => {
                let sha = id.strip_prefix("commit:").unwrap_or("");
                if !(4..=64).contains(&sha.len()) || !sha.bytes().all(|b| b.is_ascii_hexdigit()) {
                    return Err(format!("{id} is no commit:SHA"));
                }
            }
            (_, SourceKind::Branch) => {
                if id.strip_prefix("branch:").is_none_or(str::is_empty) {
                    return Err(format!("{id} is no branch:…"));
                }
            }
            _ => {}
        }
        if let Some(stored) = entity::by_id(tx.sql(), id).map_err(|e| e.to_string())?
            && stored.kind != kind
        {
            return Err(format!("{id} is stored as a {}", stored.kind));
        }
    }
    for l in s.links.iter().flat_map(|v| v.iter()) {
        let (from, to) = (kind_of(&l.src).unwrap_or(""), kind_of(&l.dst).unwrap_or(""));
        if link_as(&l.kind, from, to).is_none() {
            return Err(format!(
                "a {} link does not join a {from} to a {to}",
                l.kind.as_str()
            ));
        }
    }
    Ok(())
}

/// An update's checks (door 1 first): a parsed entity, a status from [`STATUSES`] on a task, step or plan, and only
/// [`PATCH_KEYS`].
fn check_update(deny: &DenyList, u: &ParsedUpdate) -> Result<(), String> {
    let id = u.id.as_str();
    let patch = u.data_patch.as_ref().map(|d| d.clone().into_inner());
    if id_denied(deny, id)
        || patch
            .as_ref()
            .is_some_and(|p| PATH_KEYS.iter().any(|k| data_path_denied(deny, p, k)))
    {
        return Err(DENIED.into());
    }
    let kind = kind_of(id).unwrap_or("");
    let path_form = !paths_of(&Source::Recorded, id, &json!({})).is_empty();
    if !PARSED_KINDS.contains(&kind) || (!matches!(kind, "commit" | "branch") && !path_form) {
        return Err(format!("{id} is not a parsed entity"));
    }
    if let Some(st) = &u.status
        && !(matches!(kind, "task" | "step" | "plan") && STATUSES.contains(&st.as_str()))
    {
        return Err(format!(
            "an update sets status open or done on a task, step or plan, not {} on a {kind}",
            st.as_str()
        ));
    }
    for (k, v) in patch.iter().flatten() {
        if !PATCH_KEYS.contains(&k.as_str()) {
            return Err(format!(
                "an update sets status and data.{} only, not data.{k}",
                PATCH_KEYS.join("/")
            ));
        }
        let ok = if FLAG_KEYS.contains(&k.as_str()) {
            v.is_boolean() || v.is_null()
        } else if PATH_KEYS.contains(&k.as_str()) {
            v.is_null() || v.as_str().is_some_and(|p| Path::new(p).is_absolute())
        } else {
            v.is_null() || v.is_string()
        };
        if !ok {
            return Err(format!("data.{k} has the wrong type"));
        }
    }
    Ok(())
}

/// What one entity should be after this request.
struct Want {
    kind: String,
    title: Option<String>,
    status: Option<String>,
    data: Map<String, Value>,
    source: String,
    dir: Option<PathBuf>,
}

/// The folder whose project an entity belongs to: `data.repo`, else a commit's or branch's own `data.path`, else the
/// folder of its file (the migration's rule).
fn dir_of(kind: &str, data: &Map<String, Value>, source_path: Option<&str>) -> Option<PathBuf> {
    let abs = |v: Option<&Value>| {
        v.and_then(Value::as_str)
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
    };
    if let Some(repo) = abs(data.get("repo")) {
        return Some(repo);
    }
    if matches!(kind, "commit" | "branch") {
        return abs(data.get("path"));
    }
    abs(data.get("path"))
        .or_else(|| source_path.map(PathBuf::from))
        .and_then(|p| p.parent().map(Path::to_path_buf))
}

/// A merge patch that turns OLD into NEW exactly (`null` removes a key; objects are patched member by member).
fn diff(old: &Value, new: &Map<String, Value>) -> Map<String, Value> {
    let empty = Map::new();
    let old = old.as_object().unwrap_or(&empty);
    let mut patch = Map::new();
    for k in old.keys() {
        if !new.contains_key(k) {
            patch.insert(k.clone(), Value::Null);
        }
    }
    for (k, v) in new {
        match (old.get(k), v) {
            (Some(o), v) if o == v => {}
            (Some(o @ Value::Object(_)), Value::Object(n)) => {
                patch.insert(k.clone(), Value::Object(diff(o, n)));
            }
            _ => {
                patch.insert(k.clone(), v.clone());
            }
        }
    }
    patch
}

/// Merge PATCH into DATA (`null` removes).
fn merge(data: &mut Map<String, Value>, patch: &Map<String, Value>) {
    for (k, v) in patch {
        if v.is_null() {
            data.remove(k);
        } else {
            data.insert(k.clone(), v.clone());
        }
    }
}

/// The live entity ID's `n`.
fn live_n(tx: &Tx<'_>, id: &str) -> Result<Option<i64>, WriteError> {
    Ok(entity::by_id(tx.sql(), id)?
        .filter(|e| e.retired_tx.is_none())
        .map(|e| e.n))
}

/// Retire every live entity whose source is SOURCE (except KEEP); how many.
fn retire_source(tx: &mut Tx<'_>, source: &str, keep: &HashSet<&str>) -> Result<u64, WriteError> {
    let rows: Vec<(i64, String)> = {
        let mut stmt = tx.sql().prepare(
            "select n, id from entity where source = ?1 and retired_tx is null order by n",
        )?;
        stmt.query_map([source], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<Result<_, _>>()?
    };
    let mut retired = 0;
    for (n, id) in rows {
        if !keep.contains(id.as_str()) {
            entity::retire(tx, n)?;
            retired += 1;
        }
    }
    Ok(retired)
}

/// Write WANT for ID: made, brought back, or given a new version when it differs; whether anything was written.
fn apply_want(
    tx: &mut Tx<'_>,
    id: &str,
    want: &Want,
    projects: &ProjectCache,
) -> Result<bool, WriteError> {
    let project = want.dir.as_deref().and_then(|d| projects.project_n(d));
    let Some(cur) = entity::by_id(tx.sql(), id)? else {
        entity::create(
            tx,
            EntityNew {
                id: id.to_string(),
                kind: want.kind.clone(),
                project,
                title: want.title.clone(),
                status: want.status.clone(),
                body: None,
                priority: None,
                assignee: None,
                data: Value::Object(want.data.clone()),
                origin: Origin::Parsed,
                source: Some(want.source.clone()),
            },
        )?;
        return Ok(true);
    };
    let back = entity::unretire(tx, cur.n)?;
    let ver = cur.ver + i64::from(back);
    let patch = diff(&cur.data, &want.data);
    let changes = Changes {
        project: project.filter(|p| cur.project != Some(*p)).map(Some),
        title: Some(want.title.clone()),
        status: Some(want.status.clone()),
        data_patch: (!patch.is_empty()).then_some(Value::Object(patch)),
        ..Changes::default()
    };
    match entity::update(tx, cur.n, None, changes)? {
        Update::Done { ver: now } => Ok(back || now != ver),
        Update::Conflict { .. } => Err(WriteError::Refused(format!("{id} changed meanwhile"))),
    }
}

/// A link a source should hold: `(src id, kind, dst id, data as JSON text, inferred)`.
type WantLink = (String, String, String, Option<String>, bool);

/// The links a source should hold: its own, and `parent_of` from each entity's `data.parent` where §5.4 allows it.
fn wanted_links(s: &ParsedSource) -> BTreeSet<WantLink> {
    let mut out = BTreeSet::new();
    for l in s.links.iter().flat_map(|v| v.iter()) {
        let (from, to) = (kind_of(&l.src).unwrap_or(""), kind_of(&l.dst).unwrap_or(""));
        if let Some((kind, data)) = link_as(&l.kind, from, to) {
            out.insert((
                l.src.to_string(),
                kind,
                l.dst.to_string(),
                data.map(|d| d.to_string()),
                l.origin == Some(LinkOrigin::Inferred),
            ));
        }
    }
    for e in s.entities.iter().flat_map(|v| v.iter()) {
        if let Some(parent) = data_of(e).get("parent").and_then(Value::as_str)
            && kinds::link_allowed("parent_of", kind_of(parent).unwrap_or(""), &e.kind)
        {
            out.insert((
                parent.to_string(),
                "parent_of".into(),
                e.id.to_string(),
                None,
                false,
            ));
        }
    }
    out
}

/// Make the current links of SOURCE what WANTED says: retired and added by difference (FULL), or added only.
fn apply_links(
    tx: &mut Tx<'_>,
    source: &str,
    wanted: &BTreeSet<WantLink>,
    full: bool,
) -> Result<(), WriteError> {
    let mut want: BTreeMap<(i64, String, i64), (Option<Value>, Origin)> = BTreeMap::new();
    for (src, kind, dst, data, inferred) in wanted {
        let (Some(s), Some(d)) = (live_n(tx, src)?, live_n(tx, dst)?) else {
            // an end that is not stored (refused, or never sent): no link
            continue;
        };
        let origin = if *inferred {
            Origin::Inferred
        } else {
            Origin::Parsed
        };
        let data = data.as_deref().and_then(|t| serde_json::from_str(t).ok());
        want.insert((s, kind.clone(), d), (data, origin));
    }
    let have: Vec<(i64, String, i64)> = {
        let mut stmt = tx.sql().prepare(
            "select src, kind, dst from link where source = ?1 and tx_to = ?2 order by id",
        )?;
        stmt.query_map((source, SENTINEL), |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?
        .collect::<Result<_, _>>()?
    };
    if full {
        for key in &have {
            if !want.contains_key(key) {
                link::retire(tx, key.0, &key.1, key.2)?;
            }
        }
    }
    for ((s, kind, d), (data, origin)) in want {
        link::add(tx, s, &kind, d, data, origin, Some(source))?;
    }
    Ok(())
}

fn kv_put(tx: &mut Tx<'_>, key: &str, value: &str) -> Result<(), WriteError> {
    crate::write::meta::put_text(tx, key, value).map_err(|e| match e {
        CoordError::Refused(t) => WriteError::Refused(t),
        other => WriteError::Sql(other.to_string()),
    })
}

fn kv_has(tx: &Tx<'_>, key: &str) -> Result<bool, WriteError> {
    let n: i64 = tx
        .sql()
        .query_row("select count(*) from kv where key = ?1", [key], |r| {
            r.get(0)
        })?;
    Ok(n > 0)
}

/// Forget the file PATH's row unless a live entity still comes from it.
fn drop_file(tx: &Tx<'_>, path: &str) -> Result<(), WriteError> {
    tx.sql().execute(
        "delete from parsed_file where path = ?1 \
         and not exists (select 1 from entity where source = ?1 and retired_tx is null)",
        [path],
    )?;
    Ok(())
}

/// Register the projects PROJECTS resolved and has no `n` for yet (in this tx).
fn register_projects(tx: &mut Tx<'_>, projects: &mut ProjectCache) -> Result<(), WriteError> {
    for p in projects.unregistered() {
        let n = project::register(tx, &p)?;
        projects.set_registered(&p.id, n);
    }
    Ok(())
}

/// The folders whose projects a put of REQ needs (resolved outside the write, with git): those of the entities of
/// sources door 1 lets through that are new or have no project, the denied ones left out.
pub fn dirs(
    conn: &Connection,
    deny: &DenyList,
    req: &PutParsed,
) -> Result<BTreeSet<PathBuf>, urdr::SqliteError> {
    let mut out = BTreeSet::new();
    for s in req.sources.iter().flat_map(|v| v.iter()) {
        if source_denied(deny, s) {
            continue;
        }
        let path = s.source.path.as_ref().map(|p| p.as_str());
        for e in s.entities.iter().flat_map(|v| v.iter()) {
            let Some(dir) = dir_of(&e.kind, &data_of(e), path) else {
                continue;
            };
            let has: Option<Option<i64>> = match conn.query_row(
                "select project from entity where id = ?1",
                [e.id.as_str()],
                |r| r.get(0),
            ) {
                Ok(p) => Some(p),
                Err(urdr::SqliteError::QueryReturnedNoRows) => None,
                Err(e) => return Err(e),
            };
            if !matches!(has, Some(Some(_))) && !is_denied(&deny.check(&dir)) {
                out.insert(dir);
            }
        }
    }
    Ok(out)
}

/// The folder whose project `graph/record`'s commits get (its `repo`), when the deny-list lets it through.
pub fn record_dir(deny: &DenyList, req: &Record) -> Option<PathBuf> {
    let repo = PathBuf::from(req.repo.as_str());
    (!is_denied(&deny.check(&repo))).then_some(repo)
}

/// Apply one scan's REQ in TX (actor `scan:<root>`, class `system`, tool `scan`), with no projects resolved.
pub fn put(tx: &mut Tx<'_>, deny: &DenyList, req: PutParsed) -> Result<PutAnswer, WriteError> {
    put_with(tx, deny, &mut ProjectCache::default(), req)
}

/// [`put`] with PROJECTS: the folders [`dirs`] named, resolved outside the write (new projects are registered here).
pub fn put_with(
    tx: &mut Tx<'_>,
    deny: &DenyList,
    projects: &mut ProjectCache,
    req: PutParsed,
) -> Result<PutAnswer, WriteError> {
    let mut answer = PutAnswer::default();
    let sources: Vec<ParsedSource> = req.sources.map(|s| s.into_inner()).unwrap_or_default();
    // Door 1, then each source's shape: a refused source stores nothing.
    let mut accepted: Vec<ParsedSource> = Vec::new();
    for s in sources {
        let why = if source_denied(deny, &s) {
            Some(DENIED.to_string())
        } else {
            check_shape(tx, &s).err()
        };
        match why {
            Some(why) => answer.refused.push(Refusal {
                source: Some(s.source.clone()),
                id: None,
                why,
            }),
            None => accepted.push(s),
        }
    }
    // What each entity should be, with this request's updates of it folded in.
    let mut wants: BTreeMap<String, Want> = BTreeMap::new();
    for s in &accepted {
        let text = source_text(&s.source).expect("checked");
        let path = s.source.path.as_ref().map(|p| p.as_str());
        for e in s.entities.iter().flat_map(|v| v.iter()) {
            let data = data_of(e);
            wants.insert(
                e.id.to_string(),
                Want {
                    kind: e.kind.to_string(),
                    title: e.title.as_ref().map(|t| t.as_str().to_string()),
                    status: e.status.as_ref().map(|s| s.as_str().to_string()),
                    dir: dir_of(&e.kind, &data, path),
                    data,
                    source: text.clone(),
                },
            );
        }
    }
    let mut later: Vec<ParsedUpdate> = Vec::new();
    for u in req.updates.map(|u| u.into_inner()).unwrap_or_default() {
        if let Err(why) = check_update(deny, &u) {
            answer.refused.push(Refusal {
                source: None,
                id: Some(u.id.to_string()),
                why,
            });
            continue;
        }
        match wants.get_mut(u.id.as_str()) {
            Some(w) => {
                if let Some(st) = &u.status {
                    w.status = Some(st.as_str().to_string());
                }
                if let Some(p) = &u.data_patch {
                    merge(&mut w.data, &p.clone().into_inner());
                }
            }
            None => later.push(u),
        }
    }
    register_projects(tx, projects)?;
    for (id, want) in &wants {
        if apply_want(tx, id, want, projects)? {
            answer.changed += 1;
        }
    }
    let sent: HashSet<&str> = wants.keys().map(String::as_str).collect();
    for s in &accepted {
        let text = source_text(&s.source).expect("checked");
        let full = matches!(s.source.kind, SourceKind::File | SourceKind::Spec);
        if full {
            let mine: HashSet<&str> = s
                .entities
                .iter()
                .flat_map(|v| v.iter())
                .map(|e| e.id.as_str())
                .collect();
            answer.retired += retire_source(tx, &text, &mine)?;
        }
    }
    for s in &accepted {
        let text = source_text(&s.source).expect("checked");
        let full = matches!(s.source.kind, SourceKind::File | SourceKind::Spec);
        apply_links(tx, &text, &wanted_links(s), full)?;
        if let (Some(p), Some(mtime)) = (&s.source.path, s.mtime) {
            tx.sql().execute(
                "insert into parsed_file (path, mtime) values (?1, ?2) \
                 on conflict (path) do update set mtime = excluded.mtime",
                (p.as_str(), mtime),
            )?;
        }
    }
    for g in req.gone.map(|g| g.into_inner()).unwrap_or_default() {
        let path = match (g.kind, &g.path) {
            (SourceKind::File | SourceKind::Spec, Some(p)) => p.as_str().to_string(),
            _ => {
                answer.refused.push(Refusal {
                    source: Some(g.clone()),
                    id: None,
                    why: "only a file or spec source (with its path) is gone".into(),
                });
                continue;
            }
        };
        // a file gone takes its spec form with it (`drgnx-work-scan`'s rule)
        let mut texts = vec![format!("spec {path}")];
        if g.kind == SourceKind::File {
            texts.push(path.clone());
        }
        for text in texts {
            answer.retired += retire_source(tx, &text, &HashSet::new())?;
            link::retire_by_source(tx, &text)?;
        }
        drop_file(tx, &path)?;
    }
    for u in later {
        let why = match entity::by_id(tx.sql(), &u.id)? {
            Some(e) if e.retired_tx.is_none() && e.origin == Origin::Parsed => {
                let changes = Changes {
                    status: u.status.as_ref().map(|s| Some(s.as_str().to_string())),
                    data_patch: u
                        .data_patch
                        .as_ref()
                        .map(|p| Value::Object(p.clone().into_inner())),
                    ..Changes::default()
                };
                if let Update::Done { ver } = entity::update(tx, e.n, None, changes)?
                    && ver != e.ver
                {
                    answer.changed += 1;
                }
                continue;
            }
            Some(e) if e.retired_tx.is_none() => {
                format!("{} is not a parsed entity", u.id.as_str())
            }
            _ => format!("{} is not stored", u.id.as_str()),
        };
        answer.refused.push(Refusal {
            source: None,
            id: Some(u.id.to_string()),
            why,
        });
    }
    answer.retired += cleanups(tx, &sent)?;
    for key in req.collected.map(|c| c.into_inner()).unwrap_or_default() {
        if !api::is_collected_key(&key) {
            return Err(WriteError::Refused(
                "a collected key is `job ` and a job's id".into(),
            ));
        }
        kv_put(tx, &key, "collected")?;
    }
    Ok(answer)
}

/// The scan's reachability rules, except for what this request SENT: a scanned commit no live link names, and a spec
/// no live plan `derives` outside a `specs/` folder, are retired (the spec's links and file row with it).
fn cleanups(tx: &mut Tx<'_>, sent: &HashSet<&str>) -> Result<u64, WriteError> {
    fn ids(tx: &Tx<'_>, sql: &str) -> Result<Vec<(i64, String)>, WriteError> {
        let mut stmt = tx.sql().prepare(sql)?;
        let rows = stmt
            .query_map([SENTINEL], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<Result<_, _>>()?;
        Ok(rows)
    }
    let orphans = ids(
        tx,
        "select e.n, e.id from entity e where e.kind = 'commit' and e.source = 'commit' and e.retired_tx is null \
         and not exists (select 1 from link l join entity o on o.n = l.dst \
                         where l.src = e.n and l.tx_to = ?1 and o.retired_tx is null) \
         and not exists (select 1 from link l join entity o on o.n = l.src \
                         where l.dst = e.n and l.tx_to = ?1 and o.retired_tx is null) \
         order by e.n",
    )?;
    let mut retired = 0;
    for (n, id) in orphans {
        if !sent.contains(id.as_str()) {
            entity::retire(tx, n)?;
            retired += 1;
        }
    }
    let specs = ids(
        tx,
        "select e.n, e.id from entity e where e.kind = 'spec' and e.retired_tx is null \
         and not exists (select 1 from link l join entity p on p.n = l.src \
                         where l.dst = e.n and l.kind = 'derives' and l.tx_to = ?1 and p.retired_tx is null) \
         order by e.n",
    )?;
    for (_, id) in specs {
        let Some(path) = id.strip_prefix("spec:") else {
            continue;
        };
        let under_specs = Path::new(path)
            .components()
            .any(|c| c.as_os_str() == "specs");
        if sent.contains(id.as_str()) || under_specs {
            continue;
        }
        let text = format!("spec {path}");
        retired += retire_source(tx, &text, &HashSet::new())?;
        link::retire_by_source(tx, &text)?;
        drop_file(tx, path)?;
    }
    Ok(retired)
}

/// `graph/record`: REQ's commits (made, or brought up to date) and an `implements` link from each to its task, in TX
/// (keyed by `collected` when given: the writer answers a repeat with the first answer). A collected key already kept
/// (by the Lisp collector before the cutover, or a put) writes nothing.
pub fn record(
    tx: &mut Tx<'_>,
    deny: &DenyList,
    projects: &mut ProjectCache,
    req: Record,
) -> Result<RecordAnswer, WriteError> {
    let repo = req.repo.as_str().to_string();
    if is_denied(&deny.check(Path::new(&repo))) || id_denied(deny, &req.task) {
        return Err(WriteError::Refused(DENIED.into()));
    }
    if let Some(key) = &req.collected {
        if !api::is_collected_key(key) {
            return Err(WriteError::Refused(
                "a collected key is `job ` and a job's id".into(),
            ));
        }
        if kv_has(tx, key)? {
            return Ok(RecordAnswer::default());
        }
    }
    let task = entity::by_id(tx.sql(), &req.task)?
        .filter(|e| e.retired_tx.is_none() && matches!(e.kind.as_str(), "task" | "step" | "todo"))
        .ok_or_else(|| WriteError::Refused(format!("no task {}", req.task.as_str())))?;
    register_projects(tx, projects)?;
    let project = projects.project_n(Path::new(&repo));
    let mut ids = Vec::new();
    for c in req.commits.into_inner() {
        let id = format!("commit:{}", c.sha.as_str());
        let mut data = json!({
            "sha": c.sha.as_str(),
            "date": c.date,
            "repo": repo,
            "path": repo,
        });
        if let Some(seq) = c.seq {
            data["seq"] = json!(seq);
        }
        let n = match entity::by_id(tx.sql(), &id)? {
            Some(cur) => {
                entity::unretire(tx, cur.n)?;
                entity::update(
                    tx,
                    cur.n,
                    None,
                    Changes {
                        project: project.filter(|p| cur.project != Some(*p)).map(Some),
                        title: Some(Some(c.subject.as_str().to_string())),
                        data_patch: Some(data),
                        ..Changes::default()
                    },
                )?;
                cur.n
            }
            None => {
                entity::create(
                    tx,
                    EntityNew {
                        id: id.clone(),
                        kind: "commit".into(),
                        project,
                        title: Some(c.subject.as_str().to_string()),
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
        link::add(
            tx,
            n,
            "implements",
            task.n,
            None,
            Origin::Recorded,
            Some("recorded"),
        )?;
        ids.push(id);
    }
    if let Some(key) = &req.collected {
        kv_put(tx, key, "collected")?;
    }
    Ok(RecordAnswer { ids })
}
