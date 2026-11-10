//! The reference graph of a view and its PageRank: which files the code leans on (Aider's repo map, by name).
//!
//! - **Nodes** are the view's files. **Edges** run from a file to each file that defines a name it references (the
//!   view's `ref` rows joined with its `symbol` rows on the name), one per name, weighted `sqrt(n) × m(name)`
//!   ([`weight`]); a file's references to its own names are dropped.
//! - **PageRank:** damping [`DAMPING`], stopping when the L1 change is under [`TOLERANCE`] or after [`ITERATIONS`];
//!   the teleport and the dangling files' mass go by the personalisation vector (uniform, or the focus files). A
//!   file's rank is split over its out-edges to rank `(file, name)` definitions.
//! - **Scope** `code` leaves tests and docs out of the walk (a mask on the one graph, not a second graph).
//! - **Cache:** the graph and its unpersonalised ranks per view live in the memo (`memo.rs`) until the store changes:
//!   at most [`CACHE_BYTES`] of them (by [`Graph::bytes`]' estimate), the least recently used going first.

use crate::memo;
use crate::store::{CodeStore, StoreError};
use crate::tree::View;
use rusqlite::{Connection, params};
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

pub const DAMPING: f64 = 0.85;
pub const TOLERANCE: f64 = 1e-6;
pub const ITERATIONS: usize = 100;
/// The graph cache's budget, by [`Graph::bytes`]' estimate: past it the least recently used views' graphs go.
pub const CACHE_BYTES: usize = 64 << 20;
/// A name defined in more files than this is weighed down.
const WIDE: usize = 5;

/// An edge: to the defining file, for which name, how heavy (before the request's named boost).
#[derive(Clone, Copy, Debug)]
pub(crate) struct Edge {
    pub to: u32,
    pub name: u32,
    pub w: f32,
}

/// A view's reference graph.
pub(crate) struct Graph {
    pub paths: Vec<String>,
    pub blobs: Vec<String>,
    /// Whether each file is code (not a test or docs).
    pub code: Vec<bool>,
    pub names: Vec<String>,
    by_path: HashMap<String, u32>,
    /// The out-edges of file `i` are `edges[start[i]..start[i + 1]]`.
    start: Vec<u32>,
    edges: Vec<Edge>,
    rank_all: OnceLock<Vec<f64>>,
    rank_code: OnceLock<Vec<f64>>,
}

/// How heavy a reference is: `sqrt(n)`, × 10 for a name the request names, × 10 for a long compound name (snake,
/// kebab or camel case, 8 characters or more), × 0.1 for a `_`-private name, × 0.1 for a name defined in more than 5
/// files.
pub fn weight(name: &str, n: u32, definers: usize, named: bool) -> f64 {
    let mut m = 1.0;
    if named {
        m *= 10.0;
    }
    let compound = name.contains('_')
        || name.contains('-')
        || (name.chars().any(char::is_uppercase) && name.chars().any(char::is_lowercase));
    if compound && name.chars().count() >= 8 {
        m *= 10.0;
    }
    if name.starts_with('_') {
        m *= 0.1;
    }
    if definers > WIDE {
        m *= 0.1;
    }
    (n as f64).sqrt() * m
}

/// The view's files (`?1` the view's tree).
pub const FILES_SQL: &str = "select f.path, f.blob, f.class from file f where f.blob is not null
  and f.tree = (select max(o.tree) from file o where o.tree in (0, ?1) and o.path = f.path)";

impl Graph {
    /// One pass over `file`, `symbol` and `ref`, keeping the view's pairs.
    fn build(c: &Connection, view: View) -> rusqlite::Result<Graph> {
        let mut paths = Vec::new();
        let mut blobs = Vec::new();
        let mut code = Vec::new();
        let mut by_path = HashMap::new();
        {
            let mut q = c.prepare(FILES_SQL)?;
            let mut it = q.query(params![view.tree()])?;
            while let Some(r) = it.next()? {
                let path: String = r.get(0)?;
                by_path.insert(path.clone(), paths.len() as u32);
                paths.push(path);
                blobs.push(r.get::<_, String>(1)?);
                code.push(r.get_ref(2)?.as_str()? == "code");
            }
        }
        // the node of a (path, blob) the view sees
        let node = |path: &str, blob: &str| -> Option<u32> {
            let &i = by_path.get(path)?;
            (blobs[i as usize] == blob).then_some(i)
        };
        let mut names: Vec<String> = Vec::new();
        let mut name_ix: HashMap<String, u32> = HashMap::new();
        let mut definers: Vec<Vec<u32>> = Vec::new();
        {
            let mut q = c.prepare("select path, blob, name from symbol")?;
            let mut it = q.query([])?;
            while let Some(r) = it.next()? {
                let Some(i) = node(r.get_ref(0)?.as_str()?, r.get_ref(1)?.as_str()?) else {
                    continue;
                };
                let name = r.get_ref(2)?.as_str()?;
                let k = match name_ix.get(name) {
                    Some(&k) => k,
                    None => {
                        let k = names.len() as u32;
                        name_ix.insert(name.to_string(), k);
                        names.push(name.to_string());
                        definers.push(Vec::new());
                        k
                    }
                };
                definers[k as usize].push(i);
            }
        }
        for d in &mut definers {
            d.sort_unstable();
            d.dedup();
        }
        let mut out: Vec<Vec<Edge>> = vec![Vec::new(); paths.len()];
        {
            let mut q = c.prepare("select path, blob, name, n from ref")?;
            let mut it = q.query([])?;
            while let Some(r) = it.next()? {
                let Some(u) = node(r.get_ref(0)?.as_str()?, r.get_ref(1)?.as_str()?) else {
                    continue;
                };
                let name = r.get_ref(2)?.as_str()?;
                let Some(&k) = name_ix.get(name) else {
                    continue;
                };
                let defs = &definers[k as usize];
                let w = weight(name, r.get(3)?, defs.len(), false) as f32;
                for &v in defs.iter().filter(|&&v| v != u) {
                    out[u as usize].push(Edge { to: v, name: k, w });
                }
            }
        }
        let mut start = Vec::with_capacity(paths.len() + 1);
        let mut edges = Vec::with_capacity(out.iter().map(Vec::len).sum());
        for e in out {
            start.push(edges.len() as u32);
            edges.extend(e);
        }
        start.push(edges.len() as u32);
        Ok(Graph {
            paths,
            blobs,
            code,
            names,
            by_path,
            start,
            edges,
            rank_all: OnceLock::new(),
            rank_code: OnceLock::new(),
        })
    }

    pub fn len(&self) -> usize {
        self.paths.len()
    }

    pub fn node(&self, path: &str) -> Option<u32> {
        self.by_path.get(path).copied()
    }

    pub fn out(&self, i: usize) -> &[Edge] {
        &self.edges[self.start[i] as usize..self.start[i + 1] as usize]
    }

    /// Which files the walk takes.
    fn active(&self, code_only: bool) -> Vec<bool> {
        if code_only {
            self.code.clone()
        } else {
            vec![true; self.len()]
        }
    }

    /// An edge's weight with the request's named boost.
    fn w(e: &Edge, named: &[bool]) -> f64 {
        let w = e.w as f64;
        if named.get(e.name as usize).copied().unwrap_or(false) {
            w * 10.0
        } else {
            w
        }
    }

    /// The personalisation: the focus files the walk takes, else every file it takes, each equal.
    fn teleport(&self, active: &[bool], focus: &[u32]) -> Vec<f64> {
        let mut p = vec![0.0; self.len()];
        let chosen: Vec<u32> = focus
            .iter()
            .copied()
            .filter(|&i| active[i as usize])
            .collect();
        if chosen.is_empty() {
            let n = active.iter().filter(|a| **a).count().max(1) as f64;
            for (i, a) in active.iter().enumerate() {
                if *a {
                    p[i] = 1.0 / n;
                }
            }
        } else {
            for &i in &chosen {
                p[i as usize] += 1.0 / chosen.len() as f64;
            }
        }
        p
    }

    /// The files' PageRank: by FOCUS (none: uniform), with NAMED names' edges boosted, over the active files.
    pub fn pagerank(&self, code_only: bool, focus: &[u32], named: &[bool]) -> Vec<f64> {
        let active = self.active(code_only);
        let p = self.teleport(&active, focus);
        let n = self.len();
        let total: Vec<f64> = (0..n)
            .map(|u| {
                self.out(u)
                    .iter()
                    .filter(|e| active[e.to as usize])
                    .map(|e| Self::w(e, named))
                    .sum()
            })
            .collect();
        let live = active.iter().filter(|a| **a).count().max(1) as f64;
        let mut r: Vec<f64> = active
            .iter()
            .map(|&a| if a { 1.0 / live } else { 0.0 })
            .collect();
        let mut next = vec![0.0; n];
        for _ in 0..ITERATIONS {
            next.iter_mut().for_each(|x| *x = 0.0);
            let mut dangling = 0.0;
            for u in 0..n {
                if !active[u] {
                    continue;
                }
                if total[u] == 0.0 {
                    dangling += r[u];
                    continue;
                }
                let share = DAMPING * r[u] / total[u];
                for e in self.out(u).iter().filter(|e| active[e.to as usize]) {
                    next[e.to as usize] += share * Self::w(e, named);
                }
            }
            let base = DAMPING * dangling + (1.0 - DAMPING);
            for v in 0..n {
                next[v] += base * p[v];
            }
            let err: f64 = next.iter().zip(&r).map(|(a, b)| (a - b).abs()).sum();
            std::mem::swap(&mut r, &mut next);
            if err < TOLERANCE {
                break;
            }
        }
        r
    }

    /// The unpersonalised rank, computed once.
    pub fn rank(&self, code_only: bool) -> &[f64] {
        let cell = if code_only {
            &self.rank_code
        } else {
            &self.rank_all
        };
        cell.get_or_init(|| self.pagerank(code_only, &[], &[]))
    }

    /// The definitions' ranks: each active file's RANK split over its out-edges by weight, summed per `(file, name)`.
    pub fn definitions(
        &self,
        rank: &[f64],
        code_only: bool,
        named: &[bool],
    ) -> HashMap<(u32, u32), f64> {
        let active = self.active(code_only);
        let mut out = HashMap::new();
        for (u, &ru) in rank.iter().enumerate() {
            if !active[u] || ru == 0.0 {
                continue;
            }
            let edges: Vec<&Edge> = self
                .out(u)
                .iter()
                .filter(|e| active[e.to as usize])
                .collect();
            let total: f64 = edges.iter().map(|e| Self::w(e, named)).sum();
            if total == 0.0 {
                continue;
            }
            for e in edges {
                *out.entry((e.to, e.name)).or_insert(0.0) += ru * Self::w(e, named) / total;
            }
        }
        out
    }

    /// Which names NAMES picks, by name id.
    pub fn named(&self, names: &[String]) -> Vec<bool> {
        if names.is_empty() {
            return Vec::new();
        }
        self.names.iter().map(|n| names.contains(n)).collect()
    }

    /// An estimate of the memory the graph holds: its strings (the paths twice, with the index's), the edges, and per
    /// file the offsets, the class flag and both cached ranks.
    pub fn bytes(&self) -> usize {
        let strings: usize = self
            .paths
            .iter()
            .chain(&self.paths)
            .chain(&self.blobs)
            .chain(&self.names)
            .map(|s| s.len() + 24)
            .sum();
        strings + self.edges.len() * std::mem::size_of::<Edge>() + self.len() * (4 + 1 + 8 + 8 + 8)
    }
}

/// The graph cache of the memo: views' graphs within [`CACHE_BYTES`], least recently used first.
#[derive(Default)]
pub(crate) struct Graphs {
    views: Vec<(View, Arc<Graph>)>,
}

impl Graphs {
    pub fn clear(&mut self) {
        self.views.clear();
    }

    fn bytes(&self) -> usize {
        self.views.iter().map(|(_, g)| g.bytes()).sum()
    }

    fn get(&mut self, view: View) -> Option<Arc<Graph>> {
        let i = self.views.iter().position(|(v, _)| *v == view)?;
        let e = self.views.remove(i);
        let g = e.1.clone();
        self.views.push(e);
        Some(g)
    }

    fn put(&mut self, view: View, g: Arc<Graph>) {
        self.put_within(view, g, CACHE_BYTES);
    }

    /// VIEW's graph G, the most recent; then the least recently used go until the cache is within LIMIT bytes (G
    /// stays, even alone over it).
    fn put_within(&mut self, view: View, g: Arc<Graph>, limit: usize) {
        self.views.retain(|(v, _)| *v != view);
        self.views.push((view, g));
        while self.views.len() > 1 && self.bytes() > limit {
            self.views.remove(0);
        }
    }
}

/// VIEW's graph, from the memo or built (and whether it was built now), inside a read on the store thread.
pub(crate) fn graph_of(
    c: &Connection,
    m: &memo::Shared,
    view: View,
) -> rusqlite::Result<(Arc<Graph>, bool)> {
    let mut guard = memo::lock(m);
    let memo = guard.at(c)?;
    if let Some(g) = memo.graphs.get(view) {
        return Ok((g, false));
    }
    let g = Arc::new(Graph::build(c, view)?);
    memo.graphs.put(view, g.clone());
    Ok((g, true))
}

/// The estimated memory of the store's cached graphs (none until a map, a rank or usages asked).
pub fn cache_bytes(store: &CodeStore) -> usize {
    memo::lock(&store.memo()).graphs.bytes()
}

/// What [`file_ranks`] asks.
#[derive(Clone, Debug, Default)]
pub struct RankAsk {
    /// Files to centre on (paths); none: the unpersonalised rank.
    pub focus: Vec<String>,
    /// Names whose references weigh 10 times more.
    pub names: Vec<String>,
    /// Tests and docs left out of the walk.
    pub code_only: bool,
}

/// The view's files by rank, best first, and whether the graph was built for this call.
pub async fn file_ranks(
    store: &CodeStore,
    view: View,
    ask: &RankAsk,
) -> Result<(Vec<(String, f64)>, bool), StoreError> {
    let memo = store.memo();
    let ask = ask.clone();
    Ok(store
        .handle()
        .read(move |c| {
            let (g, built) = graph_of(c, &memo, view)?;
            let focus: Vec<u32> = ask.focus.iter().filter_map(|p| g.node(p)).collect();
            let named = g.named(&ask.names);
            let rank = if focus.is_empty() && named.is_empty() {
                g.rank(ask.code_only).to_vec()
            } else {
                g.pagerank(ask.code_only, &focus, &named)
            };
            let mut out: Vec<(String, f64)> = rank
                .iter()
                .enumerate()
                .filter(|(i, _)| !ask.code_only || g.code[*i])
                .map(|(i, r)| (g.paths[i].clone(), *r))
                .collect();
            out.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
            Ok((out, built))
        })
        .await?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree::TreeId;

    /// A graph of N files and no edges, for the cache's arithmetic.
    fn sized(n: usize) -> Arc<Graph> {
        let paths: Vec<String> = (0..n).map(|i| format!("f{i:06}")).collect();
        Arc::new(Graph {
            by_path: HashMap::new(),
            blobs: paths.clone(),
            code: vec![true; n],
            names: Vec::new(),
            start: vec![0; n + 1],
            edges: Vec::new(),
            paths,
            rank_all: OnceLock::new(),
            rank_code: OnceLock::new(),
        })
    }

    fn views(g: &Graphs) -> Vec<View> {
        g.views.iter().map(|(v, _)| *v).collect()
    }

    /// The cache keeps graphs within its byte budget, letting go of the least recently used first; the graph just
    /// built stays even when it alone is over.
    #[test]
    fn the_cache_keeps_to_its_byte_budget() {
        let one = sized(1000).bytes();
        let limit = 3 * one + one / 2;
        let t = |i| View::Tree(TreeId(i));
        let mut g = Graphs::default();
        g.put_within(View::Base, sized(1000), limit);
        g.put_within(t(1), sized(1000), limit);
        g.put_within(t(2), sized(1000), limit);
        assert_eq!(views(&g), [View::Base, t(1), t(2)]);
        assert!(g.get(t(1)).is_some(), "used: now the most recent");
        g.put_within(t(3), sized(1000), limit);
        assert_eq!(
            views(&g),
            [t(2), t(1), t(3)],
            "the base was the least recently used"
        );
        assert!(g.bytes() <= limit);
        g.put_within(t(4), sized(10_000), limit);
        assert_eq!(
            views(&g),
            [t(4)],
            "a graph over the budget alone is kept, the others go"
        );
    }
}
