//! The seam from a record file's text to the graph's structure (`docs/develop/records.md`, "The seam: text to
//! structure"): no file I/O and no three-way merge.  [`apply_text`] makes the graph hold a file's text, as one
//! transaction of the caller; [`render`] is the graph's text of a file; [`pieces`] lists what the graph has of it.
//! The file sync ([`super::Views::sync`]) and the importer call it for the graph side; records in the stream log
//! call it on each take of a document.

use super::{Piece, RecordKind, data_of, kind_in, meta, now, parse_of};
use crate::coord::fail;
use norn::store::{CoordDb, CoordError, WTx};
use runstav::wire::{Error, ErrorCode};
use saga::import::{self, GraphOp};
use saga::merge::{self, Act as MergeAct, Merged};
use saga::view::{self, ViewModel};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;
use urdr::graph::entity::{self, Changes, EntityNew, Origin};
use urdr::graph::{Class, TxMeta};

/// One piece of a file as the graph holds it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PieceRef {
    pub id: String,
    /// What the piece is in its file (`head`, `task 5`, `row 12`, …).
    pub key: String,
    pub kind: String,
    pub role: String,
    pub seq: u32,
    pub version: u64,
}

/// What [`apply_text`] did.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Applied {
    /// The transaction, none when the graph already held the text.
    pub tx: Option<u64>,
    pub created: Vec<String>,
    pub updated: Vec<String>,
    pub retired: Vec<String>,
    /// Pieces not applied: (id, why).  A field only the user may set, changed by a caller that is not the user.
    pub refused: Refused,
}

/// Why a piece is refused to a caller that is not the user.
const USER_ONLY: &str = "it changes a field only the user may set";

/// A method's error as the seam's.
fn villa_of(e: Error) -> villa::Error {
    match e.code {
        ErrorCode::NotAllowed => villa::Error::refused(e.message),
        ErrorCode::InvalidParams => villa::Error::invalid(e.message),
        _ => villa::Error::internal(e.message),
    }
}

/// The seam's error as a method's.
pub(super) fn wire_of(e: villa::Error) -> Error {
    let code = match e.kind() {
        villa::Kind::Refused => ErrorCode::NotAllowed,
        villa::Kind::Invalid | villa::Kind::NotFound => ErrorCode::InvalidParams,
        _ => ErrorCode::Internal,
    };
    Error {
        code,
        message: e.message().to_owned(),
        path: None,
    }
}

fn coord(e: CoordError) -> villa::Error {
    villa_of(fail(e))
}

/// The live pieces of FILE, in seq order.
pub async fn pieces(db: &CoordDb, file: &Path) -> villa::Result<Vec<PieceRef>> {
    Ok(super::pieces(db, file)
        .await
        .map_err(villa_of)?
        .into_iter()
        .map(|p| {
            let key = p.data["records"]["key"].as_str().unwrap_or("").to_owned();
            let seq = p.seq().unwrap_or(0) as u32;
            PieceRef {
                id: p.id,
                key,
                kind: p.kind,
                role: p.role,
                seq,
                version: p.ver.max(0) as u64,
            }
        })
        .collect())
}

/// TEXT as the graph's pieces of FILE: `saga` parses it, the pieces the graph knows by an older id keep it (by their
/// text), then the acts (new, changed, retired, links, seq) go in one transaction as META's actor.  A field only the
/// user may set (`saga::merge::USER_ONLY_FIELDS`), changed by an agent or an extension, is refused per piece and
/// never applied.  The file's kind is the graph's, else its path's.
pub async fn apply_text(
    db: &CoordDb,
    file: &Path,
    text: &str,
    meta: TxMeta,
) -> villa::Result<Applied> {
    let live = super::pieces(db, file).await.map_err(villa_of)?;
    let kind = kind_in(&live)
        .or_else(|| kind_by_path(file))
        .ok_or_else(|| villa::Error::invalid(format!("{} is not a record file", file.display())))?;
    apply_text_as(db, file, kind, text, meta).await
}

/// The graph's text of FILE: its pieces in seq order.
pub async fn render(db: &CoordDb, file: &Path) -> villa::Result<String> {
    let parts = super::pieces(db, file)
        .await
        .map_err(villa_of)?
        .into_iter()
        .map(|p| p.body)
        .collect();
    Ok(view::render(&ViewModel {
        parts,
        ..Default::default()
    }))
}

/// The kind of record a file is by its path alone (a file the graph has no pieces of yet).
fn kind_by_path(file: &Path) -> Option<RecordKind> {
    let name = file.file_name()?.to_str()?;
    match name {
        "DEFERRED.md" => return Some(RecordKind::Deferred),
        "BUILD-BOARD.md" => return Some(RecordKind::BuildBoard),
        "board.org" => return Some(RecordKind::Board),
        n if n.ends_with(".ledger.md") => return Some(RecordKind::Ledgers),
        n if !n.ends_with(".md") => return None,
        _ => {}
    }
    let dirs: Vec<&str> = file
        .parent()?
        .components()
        .filter_map(|c| c.as_os_str().to_str())
        .collect();
    let has = |d: &str| dirs.contains(&d);
    if has("plans") {
        Some(RecordKind::Plans)
    } else if has("specs") {
        Some(RecordKind::Specs)
    } else if has("decisions") || has("adr") {
        Some(RecordKind::Decisions)
    } else {
        None
    }
}

/// [`apply_text`] for a file of KIND.
pub(super) async fn apply_text_as(
    db: &CoordDb,
    file: &Path,
    kind: RecordKind,
    text: &str,
    meta: TxMeta,
) -> villa::Result<Applied> {
    let live = super::pieces(db, file).await.map_err(villa_of)?;
    let ops = ops_of(kind, file, text, &live)?;
    let data: Vec<Value> = ops.iter().map(|o| data_of(o, file, kind)).collect();
    let class = meta.class;
    let (ops, data) = (Arc::new(ops), Arc::new(data));
    // read first: a write with nothing to do would still add a `tx` row
    let (r_ops, r_data) = (ops.clone(), data.clone());
    let (todo, refused) = db
        .read(move |c| {
            let acts = diff(c, &r_ops, &r_data)?;
            Ok(screen(c, acts, &r_ops, class)?)
        })
        .await
        .map_err(coord)?;
    if todo.is_empty() {
        return Ok(Applied {
            refused,
            ..Default::default()
        });
    }
    let (tx, done, refused) = db
        .write(meta, move |tx| {
            let acts = diff(tx.sql(), &ops, &data)?;
            let (acts, refused) = screen(tx.sql(), acts, &ops, class)?;
            let done = apply_acts(acts, &ops, &data, Some(&mut *tx))?;
            link_structure(tx, &ops)?;
            Ok((tx.id(), done, refused))
        })
        .await
        .map_err(coord)?;
    Ok(Applied {
        tx: Some(tx.max(0) as u64),
        created: done.created,
        updated: done.updated,
        retired: done.retired,
        refused,
    })
}

/// TEXT of a file of KIND at FILE as its pieces, the ones the graph knows by an older id (LIVE) keeping it.
pub(super) fn ops_of(
    kind: RecordKind,
    file: &Path,
    text: &str,
    live: &[Piece],
) -> villa::Result<Vec<GraphOp>> {
    let doc = import::parse(parse_of(kind), view::strip_header(text))
        .ok_or_else(|| villa::Error::internal("unknown record kind"))?;
    let mut ops = import::ops(&doc, file);
    align(&mut ops, live);
    Ok(ops)
}

/// Pieces not applied: (id, why).
pub type Refused = Vec<(String, String)>;

/// ACTS split into those CLASS may take and those it may not: an agent or an extension never changes a field only the
/// user may set (adding a piece that sets one, changing one, or retiring a piece that holds one).
fn screen(
    conn: &urdr::Connection,
    acts: Vec<Act>,
    ops: &[GraphOp],
    class: Class,
) -> Result<(Vec<Act>, Refused), urdr::SqliteError> {
    if !matches!(class, Class::Agent | Class::Ext) {
        return Ok((acts, Vec::new()));
    }
    let body_of = |n: i64| -> Result<String, urdr::SqliteError> {
        conn.query_row(
            "select coalesce(body, '') from entity where n = ?1",
            [n],
            |r| r.get(0),
        )
    };
    let (mut keep, mut refused) = (Vec::new(), Vec::new());
    for a in acts {
        let (id, same) = match &a {
            Act::Create(i) => (ops[*i].id.clone(), merge::same_user_only("", &ops[*i].body)),
            Act::Update(n, i) => (
                ops[*i].id.clone(),
                merge::same_user_only(&body_of(*n)?, &ops[*i].body),
            ),
            Act::Retire(n, id) => (id.clone(), merge::same_user_only(&body_of(*n)?, "")),
        };
        if same {
            keep.push(a);
        } else {
            refused.push((id, USER_ONLY.to_owned()));
        }
    }
    Ok((keep, refused))
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

/// A plan's structure: its tasks are under its head (`parent_of`), and a task waits on the tasks it `Depends:` on
/// (`blocks`, dependency to task).  Links already there are left as they are.
pub(super) fn link_structure(tx: &mut WTx<'_>, ops: &[GraphOp]) -> Result<(), CoordError> {
    let live = |tx: &WTx<'_>, id: &str| -> Result<Option<i64>, CoordError> {
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

pub(super) enum Act {
    Create(usize),
    Update(i64, usize),
    /// The entity's `n` and id.
    Retire(i64, String),
}

/// What it takes to make the graph hold OPS (with DATA per op): read-only, so a dry run and an import share it.
pub(super) fn diff(
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
                acts.push(Act::Retire(n, id));
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

/// The ids [`apply_acts`] created, changed and retired (or would, without a transaction).
#[derive(Debug, Default)]
pub(super) struct Done {
    pub created: Vec<String>,
    pub updated: Vec<String>,
    pub retired: Vec<String>,
}

impl Done {
    /// Entities created or changed.
    pub(super) fn entities(&self) -> u64 {
        (self.created.len() + self.updated.len()) as u64
    }

    /// Graph operations.
    pub(super) fn ops(&self) -> u64 {
        self.entities() + self.retired.len() as u64
    }
}

/// Count ACTS, and carry them out when TX is given.
pub(super) fn apply_acts(
    acts: Vec<Act>,
    ops: &[GraphOp],
    data: &[Value],
    mut tx: Option<&mut WTx<'_>>,
) -> Result<Done, CoordError> {
    let mut done = Done::default();
    for a in acts {
        match a {
            Act::Create(i) => {
                let op = &ops[i];
                if let Some(tx) = tx.as_deref_mut() {
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
                done.created.push(op.id.clone());
            }
            Act::Update(n, i) => {
                if let Some(tx) = tx.as_deref_mut() {
                    entity::update(tx, n, None, changes_of(&ops[i], &data[i]))?;
                }
                done.updated.push(ops[i].id.clone());
            }
            Act::Retire(n, id) => {
                if let Some(tx) = tx.as_deref_mut() {
                    entity::retire(tx, n)?;
                }
                done.retired.push(id);
            }
        }
    }
    Ok(done)
}

/// The graph side of a three-way merge of the file at PATH: M's acts (the file's changes, the flags) and the pieces'
/// new order, in one transaction as the hub.  How many acts it took.
pub(super) async fn apply_merged(
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

#[cfg(test)]
mod tests {
    use super::super::tests::Fix;
    use super::*;
    use norn::deny::DenyList;

    const PLAN: &str = "# P\n\n### Task 1: a\n\n- [ ] x\n\n### Task 2: b\n\n- [ ] y\n";

    fn agent() -> TxMeta {
        TxMeta::new("agent:s1", Class::Agent, "test")
    }

    fn user() -> TxMeta {
        TxMeta::new("user", Class::User, "test")
    }

    /// A store and a root holding only REL with TEXT, imported.
    async fn lone(rel: &str, text: &str, only: Option<RecordKind>) -> (Fix, std::path::PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("org");
        let p = root.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        crate::fsio::write(&p, text).unwrap();
        let f = Fix {
            hub: dir.path().join("hub"),
            root,
            db: CoordDb::spawn(dir.path().join("work.db")),
            views: super::super::Views::default(),
            deny: DenyList::load(&dir.path().join("home"), &dir.path().join("config")),
            _dir: dir,
        };
        f.import(only, false).await;
        (f, p)
    }

    async fn plan() -> (Fix, std::path::PathBuf) {
        lone("docs/plans/x/m.md", PLAN, None).await
    }

    #[test]
    fn apply_text_is_one_tx_with_the_callers_actor() {
        saman::block_on_current(async move {
            let (f, p) = plan().await;
            let before = f.count("select count(*) from tx").await;
            let text = PLAN.replace("- [ ] y", "- [ ] y, and z");
            let a = apply_text(&f.db, &p, &text, agent()).await.unwrap();
            assert_eq!(f.count("select count(*) from tx").await, before + 1);
            let tx = a.tx.expect("a change makes a tx");
            let actor: String =
                f.db.read(move |c| {
                    Ok(
                        c.query_row("select actor from tx where id = ?1", [tx as i64], |r| {
                            r.get(0)
                        })?,
                    )
                })
                .await
                .unwrap();
            assert_eq!(actor, "agent:s1");
            assert_eq!(a.updated.len(), 1, "{a:?}");
            assert!(a.created.is_empty() && a.retired.is_empty(), "{a:?}");
            // the same text again: nothing to do, no tx
            let again = apply_text(&f.db, &p, &text, agent()).await.unwrap();
            assert_eq!(again.tx, None);
            assert_eq!(f.count("select count(*) from tx").await, before + 1);
        })
    }

    #[test]
    fn apply_text_keeps_ids_of_unchanged_pieces_and_retires_removed_ones() {
        saman::block_on_current(async move {
            let (f, p) = plan().await;
            let before = pieces(&f.db, &p).await.unwrap();
            assert_eq!(before.len(), 3, "{before:?}");
            let gone = before[2].id.clone();
            let text = "# P\n\n### Task 1: a\n\n- [ ] x\n";
            let a = apply_text(&f.db, &p, text, user()).await.unwrap();
            assert_eq!(a.retired, vec![gone.clone()], "{a:?}");
            let after = pieces(&f.db, &p).await.unwrap();
            let ids: Vec<&str> = after.iter().map(|x| x.id.as_str()).collect();
            assert_eq!(ids, [before[0].id.as_str(), before[1].id.as_str()]);
            assert!(!ids.contains(&gone.as_str()));
        })
    }

    #[test]
    fn apply_text_refuses_a_user_only_field_from_an_agent() {
        saman::block_on_current(async move {
            let (f, p) = plan().await;
            let text = PLAN.replace("### Task 1: a\n", "### Task 1: a\n\nmatrix: allow-all\n");
            let a = apply_text(&f.db, &p, &text, agent()).await.unwrap();
            assert_eq!(a.refused.len(), 1, "{a:?}");
            assert!(a.updated.is_empty(), "{a:?}");
            assert_eq!(
                render(&f.db, &p).await.unwrap(),
                PLAN,
                "the graph keeps its text"
            );
            // the user may
            let u = apply_text(&f.db, &p, &text, user()).await.unwrap();
            assert!(u.refused.is_empty() && u.updated.len() == 1, "{u:?}");
            assert_eq!(render(&f.db, &p).await.unwrap(), text);
        })
    }

    /// RF1: every file of the `saga` round-trip corpus, adopted, renders back byte for byte.
    #[test]
    fn render_of_an_unchanged_graph_is_the_file() {
        saman::block_on_current(async move {
            let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../saga/tests/fixtures");
            let mut names: Vec<String> = std::fs::read_dir(&dir)
                .unwrap()
                .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
                .collect();
            names.sort();
            assert!(names.len() >= 10, "{names:?}");
            for name in names {
                let text = crate::fsio::read_to_string(dir.join(&name)).unwrap();
                let (rel, only) = match name.as_str() {
                    "board-a.org" => ("board.org".to_owned(), Some(RecordKind::Board)),
                    "board-a.md" => ("BUILD-BOARD.md".to_owned(), None),
                    n if n.starts_with("deferred") => ("DEFERRED.md".to_owned(), None),
                    n if n.starts_with("ledger") => (
                        format!("docs/plans/x/{}.ledger.md", n.trim_end_matches(".md")),
                        None,
                    ),
                    n if n.starts_with("plan") => (format!("docs/plans/x/{n}"), None),
                    n if n.starts_with("spec") => (format!("docs/specs/x/{n}"), None),
                    n if n.starts_with("decision") => (format!("docs/decisions/{n}"), None),
                    n => panic!("a fixture this row does not place: {n}"),
                };
                let (f, p) = lone(&rel, &text, only).await;
                assert!(
                    !pieces(&f.db, &p).await.unwrap().is_empty(),
                    "{name} adopted"
                );
                assert_eq!(render(&f.db, &p).await.unwrap(), text, "{name}");
            }
        })
    }

    #[test]
    fn pieces_lists_keys_in_seq_order() {
        saman::block_on_current(async move {
            let (f, p) = plan().await;
            let got = pieces(&f.db, &p).await.unwrap();
            let keys: Vec<&str> = got.iter().map(|x| x.key.as_str()).collect();
            assert_eq!(keys.len(), 3, "{keys:?}");
            assert_eq!(keys[0], "head");
            assert!(
                keys[1].starts_with("task 1") && keys[2].starts_with("task 2"),
                "{keys:?}"
            );
            let seqs: Vec<u32> = got.iter().map(|x| x.seq).collect();
            assert_eq!(seqs, [0, 1, 2]);
            assert!(
                got.iter().all(|x| x.version >= 1 && !x.kind.is_empty()),
                "{got:?}"
            );
            assert_eq!(got[1].role, "task");
        })
    }
}
