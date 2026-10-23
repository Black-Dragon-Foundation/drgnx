//! Graph walks in Rust (Task 4; storage §6.2): breadth first with batched lookups, bidirectional paths, budgets
//! enforced inside SQLite, hot nodes, and the caller's scope checked per level.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use rusqlite::Connection;
use rusqlite::params_from_iter;
use rusqlite::types::Value;
use serde::{Deserialize, Serialize};

use super::hist;
use super::link::Direction;
use super::pool::ReadPool;
use super::schema::SENTINEL;

/// Ids per batched lookup.
const CHUNK: usize = 500;
/// The deepest walk or path; a request for more is clamped and answers `truncated: depth`.
pub const MAX_DEPTH: u32 = 16;
/// SQLite VM steps between two looks at the deadline.
const PROGRESS_STEPS: i32 = 1000;

/// How a node's project is shown to the caller.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Seen {
    Full,
    /// Only `id`, `kind` and `title` (entities without a project, e.g. `agent:`).
    Stub,
    /// Not followed; counted in `hidden`, never named.
    Hidden,
}

/// The caller's scope (norn's `StoreScope`).
pub trait Scope: Send + Sync {
    fn allows(&self, project: Option<i64>) -> Seen;
    /// Re-checked before each level: false stops the walk (`truncated: scope`).
    fn valid(&self) -> bool;
}

/// A walk's budget.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Budget {
    pub visits: u32,
    /// Enforced inside SQLite by the progress handler.
    pub deadline: Duration,
    /// The most nodes an answer carries.
    pub cap: u32,
    /// A node with more links than this is answered `hot`, not expanded.
    pub hot_degree: u32,
}

impl Default for Budget {
    fn default() -> Self {
        Budget {
            visits: 20_000,
            deadline: Duration::from_millis(250),
            cap: 200,
            hot_degree: 1_000,
        }
    }
}

/// A neighbors query.
#[derive(Clone, Debug, PartialEq)]
pub struct Walk {
    pub from: i64,
    /// Required past depth 3.
    pub kinds: Vec<String>,
    pub direction: Direction,
    pub depth: u32,
    /// A tx bound for an as-of walk.
    pub as_of: Option<i64>,
}

/// A path query.
#[derive(Clone, Debug, PartialEq)]
pub struct PathQ {
    pub from: i64,
    pub to: i64,
    pub kinds: Vec<String>,
    pub max_depth: u32,
    pub as_of: Option<i64>,
}

/// A node of an answer (`Seen::Full` or `Seen::Stub`; a stub carries no project).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Node {
    pub n: i64,
    pub id: String,
    pub kind: String,
    pub title: Option<String>,
    pub project: Option<i64>,
    pub seen: Seen,
    pub depth: u32,
    /// The degree of a hot node, which was not expanded.
    pub hot: Option<u64>,
}

/// A link of an answer.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Edge {
    pub src: i64,
    pub kind: String,
    pub dst: i64,
}

/// Why a walk stopped early.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Truncated {
    Budget,
    Deadline,
    Depth,
    Cap,
    Scope,
}

/// What a walk found.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct WalkOut {
    pub nodes: Vec<Node>,
    pub links: Vec<Edge>,
    pub hidden: u32,
    pub truncated: Option<Truncated>,
}

/// Why a walk was not run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WalkError {
    /// E.g. "name kinds for depth over 3".
    Refused(String),
    Sql(String),
}

/// Why a level did not finish.
enum Stop {
    /// The deadline interrupted a statement.
    Late,
    Sql(String),
}

impl From<Stop> for WalkError {
    fn from(s: Stop) -> WalkError {
        match s {
            Stop::Late => WalkError::Sql("deadline".into()),
            Stop::Sql(m) => WalkError::Sql(m),
        }
    }
}

/// One entity row as a level reads it.
struct Row {
    n: i64,
    project: Option<i64>,
    kind: String,
    id: String,
    title: Option<String>,
}

/// One level's request.
struct Level {
    ids: Vec<i64>,
    kinds: Vec<String>,
    dir: Direction,
    as_of: Option<i64>,
    hot: u32,
    /// Nodes whose rows the caller has: their rows are not read again.
    known: HashSet<i64>,
}

/// One level's answer.
struct LevelOut {
    hot: Vec<(i64, u64)>,
    edges: Vec<Edge>,
    rows: Vec<Row>,
}

fn marks(n: usize) -> String {
    vec!["?"; n].join(",")
}

fn live(as_of: Option<i64>) -> String {
    match as_of {
        None => format!("tx_to = {SENTINEL}"),
        Some(t) => format!("tx_from <= {t} and tx_to > {t}"),
    }
}

/// Run F on one pool connection with the deadline armed inside SQLite.
async fn guarded<R, F>(pool: &ReadPool, end: Instant, f: F) -> Result<R, Stop>
where
    R: Send + 'static,
    F: FnOnce(&Connection) -> rusqlite::Result<R> + Send + 'static,
{
    let late = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&late);
    let res = pool
        .with(move |conn| {
            let _ = conn.progress_handler(
                PROGRESS_STEPS,
                Some(move || {
                    let over = Instant::now() >= end;
                    if over {
                        flag.store(true, Ordering::Relaxed);
                    }
                    over
                }),
            );
            let r = f(conn);
            let _ = conn.progress_handler(0, None::<fn() -> bool>);
            r
        })
        .await
        .map_err(|e| Stop::Sql(e.to_string()))?;
    res.map_err(|e| {
        if late.load(Ordering::Relaxed) {
            Stop::Late
        } else {
            Stop::Sql(e.to_string())
        }
    })
}

fn dirs(d: Direction) -> &'static [Direction] {
    match d {
        Direction::Out => &[Direction::Out],
        Direction::In => &[Direction::In],
        Direction::Both => &[Direction::Out, Direction::In],
    }
}

fn col(d: Direction) -> &'static str {
    if d == Direction::In { "dst" } else { "src" }
}

/// Entity rows for IDS: those that exist and are not retired (search's rule), chunked. AS_OF reads each entity as
/// it was at that tx through history ([`hist::entity_as_of`]): one created later or retired by then is left out.
fn rows_of(conn: &Connection, ids: &[i64], as_of: Option<i64>) -> rusqlite::Result<Vec<Row>> {
    let mut out = Vec::new();
    if let Some(t) = as_of {
        for &n in ids {
            if let Some(a) = hist::entity_as_of(conn, n, t)?
                && a.ent.retired_tx.is_none()
            {
                out.push(Row {
                    n: a.ent.n,
                    project: a.ent.project,
                    kind: a.ent.kind,
                    id: a.ent.id,
                    title: a.ent.title,
                });
            }
        }
        return Ok(out);
    }
    for chunk in ids.chunks(CHUNK) {
        let sql = format!(
            "select n, project, kind, id, title from entity where n in ({}) and retired_tx is null",
            marks(chunk.len())
        );
        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query(params_from_iter(chunk.iter()))?;
        while let Some(r) = rows.next()? {
            out.push(Row {
                n: r.get(0)?,
                project: r.get(1)?,
                kind: r.get(2)?,
                id: r.get(3)?,
                title: r.get(4)?,
            });
        }
    }
    Ok(out)
}

/// The number of live links of ID in direction D, counting at most LIMIT of them.
fn degree(
    conn: &Connection,
    id: i64,
    d: Direction,
    as_of: Option<i64>,
    limit: Option<i64>,
) -> rusqlite::Result<u64> {
    let c = col(d);
    let lv = live(as_of);
    let sql = match limit {
        Some(l) => {
            format!("select count(*) from (select 1 from link where {c} = ?1 and {lv} limit {l})")
        }
        None => format!("select count(*) from link where {c} = ?1 and {lv}"),
    };
    conn.prepare(&sql)?
        .query_row([id], |r| r.get::<_, i64>(0))
        .map(|n| n as u64)
}

/// One level: which frontier nodes are hot, the links of the others, and the rows of the nodes they reach that
/// the caller does not know yet. One connection, one call.
fn level(conn: &Connection, q: &Level) -> rusqlite::Result<LevelOut> {
    let mut hot = Vec::new();
    let mut open = Vec::new();
    for &id in &q.ids {
        let mut seen = 0u64;
        for &d in dirs(q.dir) {
            seen += degree(conn, id, d, q.as_of, Some(i64::from(q.hot) + 1))?;
        }
        if seen > u64::from(q.hot) {
            let mut all = 0u64;
            for &d in dirs(q.dir) {
                all += degree(conn, id, d, q.as_of, None)?;
            }
            hot.push((id, all));
        } else {
            open.push(id);
        }
    }
    let lv = live(q.as_of);
    let kind_sql = if q.kinds.is_empty() {
        String::new()
    } else {
        format!(" and kind in ({})", marks(q.kinds.len()))
    };
    let mut edges = Vec::new();
    let mut reached: Vec<i64> = Vec::new();
    let mut want = HashSet::new();
    for &d in dirs(q.dir) {
        for chunk in open.chunks(CHUNK) {
            let sql = format!(
                "select src, kind, dst from link where {} in ({}){kind_sql} and {lv}",
                col(d),
                marks(chunk.len())
            );
            let mut stmt = conn.prepare(&sql)?;
            let params = chunk
                .iter()
                .map(|i| Value::Integer(*i))
                .chain(q.kinds.iter().map(|k| Value::Text(k.clone())));
            let mut rows = stmt.query(params_from_iter(params))?;
            while let Some(r) = rows.next()? {
                let e = Edge {
                    src: r.get(0)?,
                    kind: r.get(1)?,
                    dst: r.get(2)?,
                };
                let other = if d == Direction::In { e.src } else { e.dst };
                if !q.known.contains(&other) && want.insert(other) {
                    reached.push(other);
                }
                edges.push(e);
            }
        }
    }
    edges.sort_by(|a, b| (a.src, &a.kind, a.dst).cmp(&(b.src, &b.kind, b.dst)));
    edges.dedup();
    reached.sort_unstable();
    let rows = rows_of(conn, &reached, q.as_of)?;
    Ok(LevelOut { hot, edges, rows })
}

fn check_args(kinds: &[String], depth: u32) -> Result<(), WalkError> {
    if depth > 3 && kinds.is_empty() {
        return Err(WalkError::Refused("name kinds for depth over 3".into()));
    }
    Ok(())
}

/// Decide how ROW shows to the caller: `None` when hidden.
fn admit(row: Row, scope: &dyn Scope, depth: u32) -> Option<Node> {
    let seen = scope.allows(row.project);
    let project = match seen {
        Seen::Hidden => return None,
        Seen::Full => row.project,
        Seen::Stub => None,
    };
    Some(Node {
        n: row.n,
        id: row.id,
        kind: row.kind,
        title: row.title,
        project,
        seen,
        depth,
        hot: None,
    })
}

/// Breadth first from `walk.from`, one pool connection per level.
pub async fn neighbors(
    pool: &ReadPool,
    walk: Walk,
    scope: &dyn Scope,
    budget: Budget,
) -> Result<WalkOut, WalkError> {
    check_args(&walk.kinds, walk.depth)?;
    let end = Instant::now() + budget.deadline;
    let mut out = WalkOut::default();
    let depth = walk.depth.min(MAX_DEPTH);
    if walk.depth > MAX_DEPTH {
        out.truncated = Some(Truncated::Depth);
    }
    if !scope.valid() {
        out.truncated = Some(Truncated::Scope);
        return Ok(out);
    }
    let (from, as_of) = (walk.from, walk.as_of);
    let root = match guarded(pool, end, move |c| rows_of(c, &[from], as_of)).await {
        Ok(rows) => rows,
        Err(Stop::Late) => {
            out.truncated = Some(Truncated::Deadline);
            return Ok(out);
        }
        Err(e) => return Err(e.into()),
    };
    let Some(root) = root.into_iter().next() else {
        return Ok(out);
    };
    let mut visited: HashSet<i64> = HashSet::from([root.n]);
    let mut answer: HashSet<i64> = HashSet::new();
    let mut index: HashMap<i64, usize> = HashMap::new();
    let root_n = root.n;
    match admit(root, scope, 0) {
        Some(node) => {
            answer.insert(root_n);
            index.insert(root_n, 0);
            out.nodes.push(node);
        }
        None => {
            out.hidden = 1;
            return Ok(out);
        }
    }
    let mut seen_edges: HashSet<Edge> = HashSet::new();
    let mut frontier = vec![root_n];
    let mut stop = false;
    for d in 0..depth {
        if frontier.is_empty() || stop {
            break;
        }
        if !scope.valid() {
            out.truncated.get_or_insert(Truncated::Scope);
            break;
        }
        if Instant::now() >= end {
            out.truncated.get_or_insert(Truncated::Deadline);
            break;
        }
        let q = Level {
            ids: std::mem::take(&mut frontier),
            kinds: walk.kinds.clone(),
            dir: walk.direction,
            as_of: walk.as_of,
            hot: budget.hot_degree,
            known: visited.clone(),
        };
        let lv = match guarded(pool, end, move |c| level(c, &q)).await {
            Ok(lv) => lv,
            Err(Stop::Late) => {
                out.truncated.get_or_insert(Truncated::Deadline);
                break;
            }
            Err(e) => return Err(e.into()),
        };
        for (n, count) in lv.hot {
            if let Some(&i) = index.get(&n) {
                out.nodes[i].hot = Some(count);
            }
        }
        for row in lv.rows {
            if visited.len() >= budget.visits as usize {
                out.truncated.get_or_insert(Truncated::Budget);
                stop = true;
                break;
            }
            if out.nodes.len() >= budget.cap as usize {
                out.truncated.get_or_insert(Truncated::Cap);
                stop = true;
                break;
            }
            let n = row.n;
            visited.insert(n);
            match admit(row, scope, d + 1) {
                Some(node) => {
                    answer.insert(n);
                    index.insert(n, out.nodes.len());
                    out.nodes.push(node);
                    frontier.push(n);
                }
                None => out.hidden += 1,
            }
        }
        for e in lv.edges {
            if answer.contains(&e.src) && answer.contains(&e.dst) && seen_edges.insert(e.clone()) {
                out.links.push(e);
            }
        }
    }
    Ok(out)
}

/// What a path search did, for the tests.
#[derive(Debug, Default)]
struct Stats {
    levels: u32,
    seen: usize,
}

/// One side of a bidirectional search.
struct Side {
    dir: Direction,
    dist: HashMap<i64, u32>,
    parent: HashMap<i64, (i64, Edge)>,
    frontier: Vec<i64>,
    depth: u32,
}

impl Side {
    fn new(start: i64, dir: Direction) -> Side {
        Side {
            dir,
            dist: HashMap::from([(start, 0)]),
            parent: HashMap::new(),
            frontier: vec![start],
            depth: 0,
        }
    }
}

/// A shortest path, expanding the smaller frontier until they meet.
pub async fn path(
    pool: &ReadPool,
    q: PathQ,
    scope: &dyn Scope,
    budget: Budget,
) -> Result<WalkOut, WalkError> {
    path_stats(pool, q, scope, budget).await.map(|(o, _)| o)
}

async fn path_stats(
    pool: &ReadPool,
    q: PathQ,
    scope: &dyn Scope,
    budget: Budget,
) -> Result<(WalkOut, Stats), WalkError> {
    check_args(&q.kinds, q.max_depth)?;
    let end = Instant::now() + budget.deadline;
    let mut out = WalkOut::default();
    let mut stats = Stats::default();
    let max_depth = q.max_depth.min(MAX_DEPTH);
    if !scope.valid() {
        out.truncated = Some(Truncated::Scope);
        return Ok((out, stats));
    }
    let ends = vec![q.from, q.to];
    let as_of = q.as_of;
    let rows = match guarded(pool, end, move |c| rows_of(c, &ends, as_of)).await {
        Ok(r) => r,
        Err(Stop::Late) => {
            out.truncated = Some(Truncated::Deadline);
            return Ok((out, stats));
        }
        Err(e) => return Err(e.into()),
    };
    let mut info: HashMap<i64, Node> = HashMap::new();
    let mut hidden: HashSet<i64> = HashSet::new();
    for row in rows {
        let n = row.n;
        match admit(row, scope, 0) {
            Some(node) => {
                info.insert(n, node);
            }
            None => {
                hidden.insert(n);
            }
        }
    }
    out.hidden = hidden.len() as u32;
    if !info.contains_key(&q.from) || !info.contains_key(&q.to) {
        return Ok((out, stats));
    }
    let mut hot: HashMap<i64, u64> = HashMap::new();
    let mut fwd = Side::new(q.from, Direction::Out);
    let mut bwd = Side::new(q.to, Direction::In);
    let mut meet: Option<i64> = (q.from == q.to).then_some(q.from);
    while meet.is_none() && !fwd.frontier.is_empty() && !bwd.frontier.is_empty() {
        if fwd.depth + bwd.depth >= max_depth {
            out.truncated.get_or_insert(Truncated::Depth);
            break;
        }
        if !scope.valid() {
            out.truncated.get_or_insert(Truncated::Scope);
            break;
        }
        if Instant::now() >= end {
            out.truncated.get_or_insert(Truncated::Deadline);
            break;
        }
        if info.len() + hidden.len() >= budget.visits as usize {
            out.truncated.get_or_insert(Truncated::Budget);
            break;
        }
        let (side, other) = if fwd.frontier.len() <= bwd.frontier.len() {
            (&mut fwd, &bwd)
        } else {
            (&mut bwd, &fwd)
        };
        let known: HashSet<i64> = info.keys().chain(hidden.iter()).copied().collect();
        let req = Level {
            ids: std::mem::take(&mut side.frontier),
            kinds: q.kinds.clone(),
            dir: side.dir,
            as_of: q.as_of,
            hot: budget.hot_degree,
            known,
        };
        let lv = match guarded(pool, end, move |c| level(c, &req)).await {
            Ok(lv) => lv,
            Err(Stop::Late) => {
                out.truncated.get_or_insert(Truncated::Deadline);
                break;
            }
            Err(e) => return Err(e.into()),
        };
        stats.levels += 1;
        hot.extend(lv.hot);
        for row in lv.rows {
            let n = row.n;
            match admit(row, scope, 0) {
                Some(node) => {
                    info.insert(n, node);
                }
                None => {
                    hidden.insert(n);
                }
            }
        }
        side.depth += 1;
        let mut next = Vec::new();
        for e in lv.edges {
            let (cur, nb) = if side.dir == Direction::In {
                (e.dst, e.src)
            } else {
                (e.src, e.dst)
            };
            if !info.contains_key(&nb) || side.dist.contains_key(&nb) {
                continue;
            }
            side.dist.insert(nb, side.depth);
            side.parent.insert(nb, (cur, e));
            next.push(nb);
        }
        side.frontier = next;
        meet = side
            .frontier
            .iter()
            .filter_map(|n| other.dist.get(n).map(|d| (d + side.depth, *n)))
            .min()
            .map(|(_, n)| n);
    }
    out.hidden = hidden.len() as u32;
    stats.seen = info.len();
    let Some(m) = meet else {
        return Ok((out, stats));
    };
    out.truncated = None;
    // Rebuild: from -> m by the forward parents, m -> to by the backward ones.
    let mut ns = vec![m];
    let mut links = Vec::new();
    let mut at = m;
    while let Some((prev, e)) = fwd.parent.get(&at) {
        ns.insert(0, *prev);
        links.insert(0, e.clone());
        at = *prev;
    }
    at = m;
    while let Some((next, e)) = bwd.parent.get(&at) {
        ns.push(*next);
        links.push(e.clone());
        at = *next;
    }
    for (i, n) in ns.iter().enumerate() {
        if let Some(mut node) = info.get(n).cloned() {
            node.depth = i as u32;
            node.hot = hot.get(n).copied();
            out.nodes.push(node);
        }
    }
    out.links = links;
    Ok((out, stats))
}

/// A synthetic graph for the benches (Task 20): NODES entities of one kind and about LINKS links over KINDS kinds.
#[cfg(any(test, feature = "test-hooks"))]
pub fn synthetic(
    path: &std::path::Path,
    nodes: i64,
    links: i64,
    kinds: i64,
) -> rusqlite::Result<()> {
    let conn = Connection::open(path)?;
    conn.pragma_update(None, "journal_mode", "wal")?;
    conn.execute_batch(super::schema::GRAPH_DDL)?;
    conn.execute(
        "insert into entity (n, id, kind, origin, ver, created_tx, updated_tx)
         with recursive c(i) as (select 1 union all select i + 1 from c where i < ?1)
         select i, 'note:' || i, 'note', 'recorded', 1, 1, 1 from c",
        [nodes],
    )?;
    conn.execute(
        "insert or ignore into link (src, kind, dst, origin, tx_from)
         with recursive c(i) as (select 1 union all select i + 1 from c where i < ?1)
         select (i * 2654435761) % ?2 + 1, 'k' || (i % ?3), (i * 40503 + i / 7) % ?2 + 1, 'recorded', 1 from c",
        [links, nodes, kinds],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::atomic::AtomicU32;

    struct Fx {
        _dir: tempfile::TempDir,
        conn: Connection,
        pool: ReadPool,
    }

    fn fx(pool_size: usize) -> Fx {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("work.db");
        let conn = Connection::open(&file).unwrap();
        conn.pragma_update(None, "journal_mode", "wal").unwrap();
        conn.execute_batch(super::super::schema::GRAPH_DDL).unwrap();
        let pool = ReadPool::open(file, pool_size);
        Fx {
            _dir: dir,
            conn,
            pool,
        }
    }

    impl Fx {
        fn ent(&self, n: i64, project: Option<i64>) {
            self.conn
                .execute(
                    "insert into entity (n, id, kind, project, title, origin, ver, created_tx, updated_tx)
                     values (?1, 'note:' || ?1, 'note', ?2, 't' || ?1, 'recorded', 1, 1, 1)",
                    rusqlite::params![n, project],
                )
                .unwrap();
        }
        fn ents(&self, from: i64, to: i64) {
            for n in from..=to {
                self.ent(n, Some(1));
            }
        }
        fn link(&self, src: i64, kind: &str, dst: i64) {
            self.link_at(src, kind, dst, 1, SENTINEL);
        }
        fn link_at(&self, src: i64, kind: &str, dst: i64, from: i64, to: i64) {
            self.conn
                .execute(
                    "insert into link (src, kind, dst, origin, tx_from, tx_to)
                     values (?1, ?2, ?3, 'recorded', ?4, ?5)",
                    rusqlite::params![src, kind, dst, from, to],
                )
                .unwrap();
        }
    }

    struct Open;
    impl Scope for Open {
        fn allows(&self, project: Option<i64>) -> Seen {
            if project.is_none() {
                Seen::Stub
            } else {
                Seen::Full
            }
        }
        fn valid(&self) -> bool {
            true
        }
    }

    struct Hides(i64);
    impl Scope for Hides {
        fn allows(&self, project: Option<i64>) -> Seen {
            match project {
                Some(p) if p == self.0 => Seen::Hidden,
                Some(_) => Seen::Full,
                None => Seen::Stub,
            }
        }
        fn valid(&self) -> bool {
            true
        }
    }

    /// Valid for the first OK calls only.
    struct Revoked {
        calls: AtomicU32,
        ok: u32,
    }
    impl Scope for Revoked {
        fn allows(&self, _: Option<i64>) -> Seen {
            Seen::Full
        }
        fn valid(&self) -> bool {
            self.calls.fetch_add(1, Ordering::SeqCst) < self.ok
        }
    }

    fn walk(from: i64, depth: u32) -> Walk {
        Walk {
            from,
            kinds: if depth > 3 {
                vec!["x".into(), "next".into()]
            } else {
                vec![]
            },
            direction: Direction::Out,
            depth,
            as_of: None,
        }
    }

    fn ids(o: &WalkOut) -> Vec<i64> {
        let mut v: Vec<i64> = o.nodes.iter().map(|n| n.n).collect();
        v.sort_unstable();
        v
    }

    #[tokio::test]
    async fn dedups_nodes_not_rows() {
        let f = fx(2);
        f.ents(1, 4);
        f.link(1, "blocks", 2);
        f.link(1, "relates", 2);
        f.link(1, "blocks", 3);
        f.link(2, "blocks", 4);
        f.link(3, "blocks", 4);
        let o = neighbors(&f.pool, walk(1, 3), &Open, Budget::default())
            .await
            .unwrap();
        assert_eq!(ids(&o), vec![1, 2, 3, 4]);
        assert_eq!(o.links.len(), 5, "every link once, every node once");
        assert_eq!(o.truncated, None);
    }

    #[tokio::test]
    async fn path_meets_in_the_middle() {
        let f = fx(2);
        f.ents(1, 60);
        for n in 1..9 {
            f.link(n, "next", n + 1);
        }
        for n in 10..=59 {
            f.link(1, "fan", n);
        }
        let q = PathQ {
            from: 1,
            to: 9,
            kinds: vec!["next".into(), "fan".into()],
            max_depth: 10,
            as_of: None,
        };
        let (o, st) = path_stats(&f.pool, q, &Open, Budget::default())
            .await
            .unwrap();
        let order: Vec<i64> = o.nodes.iter().map(|n| n.n).collect();
        assert_eq!(order, (1..=9).collect::<Vec<_>>());
        assert_eq!(o.links.len(), 8);
        assert_eq!(st.levels, 8);
        assert!(st.seen < 60, "the fan was expanded: {}", st.seen);
        assert!(o.nodes.iter().enumerate().all(|(i, n)| n.depth == i as u32));
    }

    #[tokio::test]
    async fn path_not_found_and_depth() {
        let f = fx(1);
        f.ents(1, 5);
        for n in 1..5 {
            f.link(n, "next", n + 1);
        }
        let q = |to, max_depth| PathQ {
            from: 1,
            to,
            kinds: vec!["next".into()],
            max_depth,
            as_of: None,
        };
        let o = path(&f.pool, q(5, 2), &Open, Budget::default())
            .await
            .unwrap();
        assert!(o.nodes.is_empty());
        assert_eq!(o.truncated, Some(Truncated::Depth));
        f.ent(9, Some(1));
        let o = path(&f.pool, q(9, 8), &Open, Budget::default())
            .await
            .unwrap();
        assert!(o.nodes.is_empty() && o.truncated.is_none());
    }

    #[tokio::test]
    async fn visit_budget() {
        let f = fx(1);
        f.ents(1, 40);
        for n in 2..=40 {
            f.link(1, "x", n);
        }
        let b = Budget {
            visits: 10,
            cap: 1000,
            ..Budget::default()
        };
        let o = neighbors(&f.pool, walk(1, 2), &Open, b).await.unwrap();
        assert_eq!(o.truncated, Some(Truncated::Budget));
        assert_eq!(o.nodes.len(), 10);
    }

    #[tokio::test]
    async fn deadline_inside_sqlite() {
        let f = fx(1);
        f.conn
            .execute(
                "insert into entity (n, id, kind, project, origin, ver, created_tx, updated_tx)
                 with recursive c(i) as (select 1 union all select i + 1 from c where i < 300001)
                 select i, 'note:' || i, 'note', 1, 'recorded', 1, 1, 1 from c",
                [],
            )
            .unwrap();
        f.conn
            .execute(
                "insert into link (src, kind, dst, origin, tx_from)
                 with recursive c(i) as (select 2 union all select i + 1 from c where i < 300001)
                 select 1, 'x', i, 'recorded', 1 from c",
                [],
            )
            .unwrap();
        let b = Budget {
            deadline: Duration::from_millis(2),
            hot_degree: u32::MAX,
            cap: 1_000_000,
            visits: 1_000_000,
        };
        let t = Instant::now();
        let o = neighbors(&f.pool, walk(1, 1), &Open, b).await.unwrap();
        assert_eq!(o.truncated, Some(Truncated::Deadline));
        assert!(
            t.elapsed() < Duration::from_millis(300),
            "{:?}",
            t.elapsed()
        );
        // The connection went back to the pool without the handler.
        let again = neighbors(&f.pool, walk(2, 1), &Open, Budget::default())
            .await
            .unwrap();
        assert_eq!(again.truncated, None);
    }

    #[tokio::test]
    async fn kinds_required_past_three() {
        let f = fx(1);
        f.ents(1, 2);
        let mut bare = walk(1, 4);
        bare.kinds.clear();
        let e = neighbors(&f.pool, bare, &Open, Budget::default())
            .await
            .unwrap_err();
        assert_eq!(e, WalkError::Refused("name kinds for depth over 3".into()));
        let mut w = walk(1, 4);
        w.kinds = vec!["x".into()];
        assert!(
            neighbors(&f.pool, w, &Open, Budget::default())
                .await
                .is_ok()
        );
    }

    #[tokio::test]
    async fn answers_capped_at_200() {
        let f = fx(1);
        f.ents(1, 301);
        for n in 2..=301 {
            f.link(1, "x", n);
        }
        let b = Budget {
            hot_degree: 10_000,
            ..Budget::default()
        };
        let o = neighbors(&f.pool, walk(1, 1), &Open, b).await.unwrap();
        assert_eq!(o.nodes.len(), 200);
        assert_eq!(o.truncated, Some(Truncated::Cap));
        assert!(o.links.len() <= 199);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn one_connection_per_level() {
        let f = fx(1);
        f.ents(1, 8);
        for n in 1..8 {
            f.link(n, "next", n + 1);
        }
        // Between level 0 and level 1 (the third scope check) the walker holds no connection, and another reader
        // (the pool has one) gets it there. The reader runs inside that check, so nothing depends on when a spawned
        // task is first polled: one spawned at a level once lost the race to the whole walk on a loaded machine.
        struct Spy {
            pool: ReadPool,
            events: Arc<Mutex<Vec<&'static str>>>,
        }
        impl Scope for Spy {
            fn allows(&self, _: Option<i64>) -> Seen {
                Seen::Full
            }
            fn valid(&self) -> bool {
                let checks = {
                    let mut ev = self.events.lock().unwrap();
                    ev.push("level");
                    ev.len()
                };
                if checks == 3 {
                    assert_eq!(self.pool.in_use(), 0, "the walker kept its connection");
                    let (pool, events) = (self.pool.clone(), Arc::clone(&self.events));
                    tokio::task::block_in_place(move || {
                        tokio::runtime::Handle::current()
                            .block_on(pool.with(move |_| events.lock().unwrap().push("reader")))
                            .unwrap();
                    });
                }
                true
            }
        }
        let events = Arc::new(Mutex::new(Vec::new()));
        let spy = Spy {
            pool: f.pool.clone(),
            events: Arc::clone(&events),
        };
        let o = neighbors(&f.pool, walk(1, 7), &spy, Budget::default())
            .await
            .unwrap();
        assert_eq!(o.nodes.len(), 8);
        let ev = events.lock().unwrap().clone();
        let at = ev.iter().position(|e| *e == "reader").unwrap();
        let last = ev.iter().rposition(|e| *e == "level").unwrap();
        assert!(at < last, "the reader waited for the whole walk: {ev:?}");
    }

    #[tokio::test]
    async fn a_hot_node_is_not_expanded() {
        let f = fx(1);
        f.ents(1, 9);
        f.link(1, "x", 2);
        for n in 3..=7 {
            f.link(2, "x", n);
        }
        f.link(7, "x", 8);
        let b = Budget {
            hot_degree: 3,
            ..Budget::default()
        };
        let o = neighbors(&f.pool, walk(1, 5), &Open, b).await.unwrap();
        assert_eq!(ids(&o), vec![1, 2]);
        let hot = o.nodes.iter().find(|n| n.n == 2).unwrap();
        assert_eq!(hot.hot, Some(5));
    }

    #[tokio::test]
    async fn a_link_out_of_scope_is_counted_never_named() {
        let f = fx(1);
        f.ents(1, 2);
        f.ent(3, Some(2));
        f.ent(4, Some(1));
        f.link(1, "x", 2);
        f.link(1, "x", 3);
        f.link(3, "x", 4);
        let o = neighbors(&f.pool, walk(1, 3), &Hides(2), Budget::default())
            .await
            .unwrap();
        assert_eq!(ids(&o), vec![1, 2]);
        assert_eq!(o.hidden, 1);
        let text = serde_json::to_string(&o).unwrap();
        assert!(!text.contains("note:3") && !text.contains("t3"), "{text}");
        assert!(o.links.iter().all(|l| l.src != 3 && l.dst != 3));
    }

    #[tokio::test]
    async fn stubs_show_only_id_kind_title() {
        let f = fx(1);
        f.ent(1, Some(1));
        f.ent(2, None);
        f.link(1, "x", 2);
        let o = neighbors(&f.pool, walk(1, 1), &Open, Budget::default())
            .await
            .unwrap();
        let stub = o.nodes.iter().find(|n| n.n == 2).unwrap();
        assert_eq!(stub.seen, Seen::Stub);
        assert_eq!(stub.project, None);
        assert_eq!(stub.id, "note:2");
        assert_eq!(stub.title.as_deref(), Some("t2"));
    }

    #[tokio::test]
    async fn scope_is_rechecked_each_level() {
        let f = fx(1);
        f.ents(1, 5);
        for n in 1..5 {
            f.link(n, "next", n + 1);
        }
        let s = Revoked {
            calls: AtomicU32::new(0),
            ok: 3,
        };
        let o = neighbors(&f.pool, walk(1, 4), &s, Budget::default())
            .await
            .unwrap();
        assert_eq!(o.truncated, Some(Truncated::Scope));
        assert_eq!(ids(&o), vec![1, 2, 3]);
    }

    #[tokio::test]
    async fn as_of_walk_skips_retired_links() {
        let f = fx(1);
        f.ents(1, 3);
        f.link_at(1, "x", 2, 1, 5);
        f.link(1, "x", 3);
        let mut w = walk(1, 1);
        w.as_of = Some(3);
        let o = neighbors(&f.pool, w.clone(), &Open, Budget::default())
            .await
            .unwrap();
        assert_eq!(ids(&o), vec![1, 2, 3]);
        w.as_of = Some(6);
        let o = neighbors(&f.pool, w, &Open, Budget::default())
            .await
            .unwrap();
        assert_eq!(ids(&o), vec![1, 3]);
        let o = neighbors(&f.pool, walk(1, 1), &Open, Budget::default())
            .await
            .unwrap();
        assert_eq!(ids(&o), vec![1, 3]);
    }

    #[tokio::test]
    async fn incoming_and_both_directions() {
        let f = fx(1);
        f.ents(1, 3);
        f.link(2, "x", 1);
        f.link(1, "x", 3);
        let mut w = walk(1, 1);
        w.direction = Direction::In;
        let o = neighbors(&f.pool, w.clone(), &Open, Budget::default())
            .await
            .unwrap();
        assert_eq!(ids(&o), vec![1, 2]);
        w.direction = Direction::Both;
        let o = neighbors(&f.pool, w, &Open, Budget::default())
            .await
            .unwrap();
        assert_eq!(ids(&o), vec![1, 2, 3]);
    }

    /// Entity N: version 1 (title OLD) from tx 1 until tx AT, then version 2 written at AT: a new title, or retired.
    fn second_version(f: &Fx, n: i64, at: i64, retire: bool) {
        f.conn
            .execute(
                "insert into entity_hist (n, ver, tx_from, tx_to, kind, project, title, data, field_tx)
                 values (?1, 1, 1, ?2, 'note', 1, 'old', '{}', '{}')",
                rusqlite::params![n, at],
            )
            .unwrap();
        let sql = if retire {
            "update entity set ver = 2, updated_tx = ?2, retired_tx = ?2, title = 'old' where n = ?1"
        } else {
            "update entity set ver = 2, updated_tx = ?2, title = 'new' where n = ?1"
        };
        f.conn.execute(sql, rusqlite::params![n, at]).unwrap();
    }

    fn title_of(o: &WalkOut, n: i64) -> Option<String> {
        o.nodes.iter().find(|x| x.n == n).unwrap().title.clone()
    }

    #[tokio::test]
    async fn an_as_of_walk_reads_entities_as_they_were() {
        let f = fx(1);
        f.ents(1, 3);
        second_version(&f, 2, 5, false);
        second_version(&f, 3, 2, true);
        f.link(1, "x", 2);
        f.link(1, "x", 3);
        let mut w = walk(1, 1);
        w.as_of = Some(1);
        let o = neighbors(&f.pool, w.clone(), &Open, Budget::default())
            .await
            .unwrap();
        assert_eq!(ids(&o), vec![1, 2, 3], "3 was not retired yet");
        assert_eq!(title_of(&o, 2).as_deref(), Some("old"));
        w.as_of = Some(3);
        let o = neighbors(&f.pool, w, &Open, Budget::default())
            .await
            .unwrap();
        assert_eq!(ids(&o), vec![1, 2], "3 was retired at tx 2");
        assert_eq!(title_of(&o, 2).as_deref(), Some("old"));
        let q = PathQ {
            from: 1,
            to: 3,
            kinds: vec!["x".into()],
            max_depth: 2,
            as_of: Some(1),
        };
        let o = path(&f.pool, q, &Open, Budget::default()).await.unwrap();
        assert_eq!(ids(&o), vec![1, 3]);
        assert_eq!(title_of(&o, 3).as_deref(), Some("old"));
        let o = neighbors(&f.pool, walk(1, 1), &Open, Budget::default())
            .await
            .unwrap();
        assert_eq!(title_of(&o, 2).as_deref(), Some("new"));
    }

    #[tokio::test]
    async fn a_current_walk_never_surfaces_a_retired_entity() {
        let f = fx(1);
        f.ents(1, 4);
        second_version(&f, 3, 2, true);
        f.link(1, "x", 2);
        f.link(2, "x", 3);
        f.link(3, "x", 4);
        let o = neighbors(&f.pool, walk(1, 3), &Open, Budget::default())
            .await
            .unwrap();
        assert_eq!(ids(&o), vec![1, 2]);
        assert!(o.links.iter().all(|l| l.src != 3 && l.dst != 3));
        assert_eq!(o.hidden, 0, "retired is gone, not hidden");
        let o = neighbors(&f.pool, walk(3, 1), &Open, Budget::default())
            .await
            .unwrap();
        assert!(o.nodes.is_empty(), "a retired root answers nothing");
        let q = |from, to| PathQ {
            from,
            to,
            kinds: vec!["x".into()],
            max_depth: 4,
            as_of: None,
        };
        let o = path(&f.pool, q(1, 4), &Open, Budget::default())
            .await
            .unwrap();
        assert!(o.nodes.is_empty(), "no path through a retired node");
        let o = path(&f.pool, q(1, 3), &Open, Budget::default())
            .await
            .unwrap();
        assert!(o.nodes.is_empty(), "no path to a retired node");
    }
}
