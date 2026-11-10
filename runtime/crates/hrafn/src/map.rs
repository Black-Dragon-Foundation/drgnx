//! The repo map and the usages of a name, in a view, from the reference graph (`graph.rs`) and the symbol table.
//!
//! - **Map.** Definitions `(file, name)` by rank (the graph's rank split over its edges; a name the request gives
//!   ranks 10 times higher), the focus files left out; files grouped in rank order, each definition rendered from its
//!   signature and lines, nested members indented, `⋮` between rows that are not neighbours in the file. The number of
//!   definitions is the largest whose text fits the budget, by binary search on the estimate `ceil(chars / 4)`.
//! - **Usages.** The view's `ref` rows for the name, without the lines inside the name's own definitions in that file,
//!   each under the innermost definition that holds its first line; ranked by the file's (unpersonalised) rank ×
//!   `ln(1 + n)`, tests after code. By name only: same-named things elsewhere show up too.

use crate::graph::{Graph, graph_of};
use crate::query::Scope;
use crate::store::{CodeStore, StoreError};
use crate::symbols::{Find, Match, OutlineEntry, SymbolHit, SymbolsError, entries, find};
use crate::tree::View;
use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;

/// What a map asks.
#[derive(Clone, Debug)]
pub struct MapAsk {
    /// Tokens the map may take (by the estimate).
    pub budget: usize,
    /// Files to centre on (relative paths); they are left out of the listing.
    pub focus: Vec<String>,
    /// Names whose definitions rank higher.
    pub names: Vec<String>,
    /// Tests and docs too (otherwise code only).
    pub all: bool,
}

/// One file of a map and the definitions it shows.
#[derive(Clone, Debug, PartialEq)]
pub struct MapFile {
    pub path: String,
    pub rank: f64,
    pub defs: Vec<OutlineEntry>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RepoMap {
    pub text: String,
    pub files: Vec<MapFile>,
    /// The estimate of `text`: `ceil(chars / 4)`.
    pub tokens: usize,
    /// The files the map ranked (the view's code files, or all with `all`).
    pub files_total: usize,
    /// Whether the graph was built for this map (cold) rather than taken from the cache.
    pub built: bool,
}

/// One place a name is used.
#[derive(Clone, Debug, PartialEq)]
pub struct Usage {
    pub path: String,
    /// The first line it is used on.
    pub line: u32,
    /// The first lines it is used on (at most 8).
    pub lines: Vec<u32>,
    pub n: u32,
    /// The innermost definition holding `line`; none at top level.
    pub enclosing: Option<String>,
    pub rank: f64,
    /// `code`, `test` or `docs`.
    pub class: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Usages {
    /// Where the name is defined (exact).
    pub defined: Vec<SymbolHit>,
    pub usages: Vec<Usage>,
}

/// `1,234`.
fn thousands(n: usize) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

fn estimate(text: &str) -> usize {
    text.chars().count().div_ceil(4)
}

/// A file's definitions, and which of them a map may show.
struct Loaded {
    entries: Vec<OutlineEntry>,
}

/// The map of the first K candidates.
fn render(
    g: &Graph,
    rank: &[f64],
    cands: &[(u32, u32)],
    loaded: &HashMap<u32, Loaded>,
    k: usize,
    files_total: usize,
    budget: usize,
) -> (String, Vec<MapFile>, usize) {
    let mut order: Vec<u32> = Vec::new();
    let mut picked: HashMap<u32, HashSet<&str>> = HashMap::new();
    for &(f, name) in &cands[..k] {
        let set = picked.entry(f).or_insert_with(|| {
            order.push(f);
            HashSet::new()
        });
        set.insert(g.names[name as usize].as_str());
    }
    let mut text = String::new();
    let mut files = Vec::new();
    for f in order {
        let Some(l) = loaded.get(&f) else { continue };
        let names = &picked[&f];
        let path = &g.paths[f as usize];
        let _ = writeln!(text, "{path}:");
        let mut defs = Vec::new();
        let mut last: Option<usize> = None;
        for (i, e) in l.entries.iter().enumerate() {
            if !names.contains(e.name.as_str()) {
                continue;
            }
            if last.is_some_and(|j| i > j + 1) {
                text.push_str("⋮\n");
            }
            last = Some(i);
            let indent = "  ".repeat(e.depth as usize);
            let sig = if e.sig.trim().is_empty() {
                e.name.as_str()
            } else {
                e.sig.as_str()
            };
            for (j, line) in sig.lines().enumerate() {
                let _ = writeln!(
                    text,
                    "{:>4}│ {indent}{}",
                    e.line_start as usize + j,
                    line.trim()
                );
            }
            defs.push(e.clone());
        }
        files.push(MapFile {
            path: path.clone(),
            rank: rank[f as usize],
            defs,
        });
    }
    // the last line names its own estimate: settle the number (its width rarely moves it)
    let mut tokens = estimate(&text);
    let mut tail = String::new();
    for _ in 0..4 {
        tail = format!(
            "map: {} files of {}, ~{} tokens (estimate), budget {}",
            thousands(files.len()),
            thousands(files_total),
            thousands(tokens),
            thousands(budget)
        );
        let next = (text.chars().count() + tail.chars().count()).div_ceil(4);
        if next == tokens {
            break;
        }
        tokens = next;
    }
    text.push_str(&tail);
    (text, files, tokens)
}

/// The map ASK asks of VIEW.
pub async fn repo_map(store: &CodeStore, view: View, ask: &MapAsk) -> Result<RepoMap, StoreError> {
    let memo = store.memo();
    let ask = ask.clone();
    Ok(store
        .handle()
        .read(move |c| {
            let (g, built) = graph_of(c, &memo, view)?;
            let code_only = !ask.all;
            let focus: Vec<u32> = ask.focus.iter().filter_map(|p| g.node(p)).collect();
            let named = g.named(&ask.names);
            let rank = if focus.is_empty() && named.is_empty() {
                g.rank(code_only).to_vec()
            } else {
                g.pagerank(code_only, &focus, &named)
            };
            let mut defs: Vec<((u32, u32), f64)> = g
                .definitions(&rank, code_only, &named)
                .into_iter()
                .filter(|((f, _), _)| !focus.contains(f))
                .map(|((f, n), r)| {
                    let boost = if named.get(n as usize).copied().unwrap_or(false) {
                        10.0
                    } else {
                        1.0
                    };
                    ((f, n), r * boost)
                })
                .collect();
            defs.sort_by(|a, b| {
                b.1.total_cmp(&a.1).then_with(|| {
                    (&g.paths[a.0.0 as usize], &g.names[a.0.1 as usize])
                        .cmp(&(&g.paths[b.0.0 as usize], &g.names[b.0.1 as usize]))
                })
            });
            // a row is at least a few tokens: more candidates than this never fit
            defs.truncate(ask.budget / 2 + 1);
            let cands: Vec<(u32, u32)> = defs.iter().map(|d| d.0).collect();
            let mut loaded: HashMap<u32, Loaded> = HashMap::new();
            for &(f, _) in &cands {
                if let std::collections::hash_map::Entry::Vacant(v) = loaded.entry(f) {
                    let entries = entries(c, &g.paths[f as usize], &g.blobs[f as usize])?;
                    v.insert(Loaded { entries });
                }
            }
            let files_total = if code_only {
                g.code.iter().filter(|c| **c).count()
            } else {
                g.len()
            };
            let fits = |k: usize| {
                let r = render(&g, &rank, &cands, &loaded, k, files_total, ask.budget);
                (r.2 <= ask.budget, r)
            };
            let (mut lo, mut hi) = (0, cands.len());
            while lo < hi {
                let mid = (lo + hi).div_ceil(2);
                if fits(mid).0 {
                    lo = mid;
                } else {
                    hi = mid - 1;
                }
            }
            let (_, (text, files, tokens)) = fits(lo);
            Ok(RepoMap {
                text,
                files,
                tokens,
                files_total,
                built,
            })
        })
        .await?)
}

/// Where NAME is used in VIEW: the definitions first (exact), then at most K places in SCOPE.
pub async fn usages(
    store: &CodeStore,
    view: View,
    name: &str,
    scope: Scope,
    k: usize,
) -> Result<Usages, SymbolsError> {
    let defined = find(
        store,
        view,
        &Find {
            name: name.to_string(),
            mode: Match::Exact,
            kinds: Vec::new(),
            glob: None,
            scope: Scope::All,
            k: 20,
        },
    )
    .await?
    .hits;
    let memo = store.memo();
    let name = name.to_string();
    let usages = store
        .handle()
        .read(move |c| {
            let (g, _) = graph_of(c, &memo, view)?;
            let rank = g.rank(false);
            // the files defining the name: only there can a use sit inside its own definition
            let defining: HashSet<String> = c
                .prepare(crate::query::PINNED_SQL)?
                .query_map(rusqlite::params![name, view.tree()], |r| r.get(3))?
                .collect::<Result<_, _>>()?;
            let mut out = Vec::new();
            // (the usage, its pair's blob): the enclosing definitions are read for the K kept only
            let mut blobs = Vec::new();
            for r in crate::refs::rows(c, view, &name)? {
                if !scope.admits(&r.class) {
                    continue;
                }
                let mut lines = r.lines.clone();
                let mut n = r.n;
                if defining.contains(&r.path) {
                    let defs = entries(c, &r.path, &r.blob)?;
                    lines.retain(|&l| {
                        !defs
                            .iter()
                            .any(|d| d.name == name && d.line_start <= l && l <= d.line_end)
                    });
                    n = n.saturating_sub((r.lines.len() - lines.len()) as u32);
                }
                if n == 0 {
                    continue;
                }
                let file_rank = g.node(&r.path).map_or(0.0, |i| rank[i as usize]);
                blobs.push(r.blob);
                out.push((
                    Usage {
                        rank: file_rank * (1.0 + n as f64).ln(),
                        path: r.path,
                        line: lines.first().copied().unwrap_or(0),
                        lines,
                        n,
                        enclosing: None,
                        class: r.class,
                    },
                    blobs.len() - 1,
                ));
            }
            out.sort_by(|(a, _), (b, _)| {
                (a.class == "test")
                    .cmp(&(b.class == "test"))
                    .then_with(|| b.rank.total_cmp(&a.rank))
                    .then_with(|| (&a.path, a.line).cmp(&(&b.path, b.line)))
            });
            out.truncate(k.max(1));
            let mut kept = Vec::with_capacity(out.len());
            for (mut u, b) in out {
                u.enclosing = entries(c, &u.path, &blobs[b])?
                    .into_iter()
                    .filter(|d| d.line_start <= u.line && u.line <= d.line_end)
                    .min_by_key(|d| (d.line_end - d.line_start, u32::MAX - d.depth))
                    .map(|d| d.name);
                kept.push(u);
            }
            Ok(kept)
        })
        .await
        .map_err(StoreError::from)?;
    Ok(Usages { defined, usages })
}
