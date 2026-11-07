//! The query (storage design §12A.3 items 1, 2, 7): lists from symbols, names, paths, keywords and vectors, fused by
//! reciprocal rank, with tests and generated files demoted and hits in changed files moved to where their chunk is now.
//!
//! - **Routing.** A query that is one identifier and an exact name pins that name's definitions first (non-test before
//!   test, then by kind). Prefix and trigram matches on names, from the identifier-like tokens of the question, add a
//!   ranked list that is never pinned. A token that names a file (a path, a file name, a file's stem) adds a path
//!   list. Identifier tokens are exact phrases on the `symbols` column and their parts a phrase on `doc` and `body`;
//!   the other words are OR'ed over `doc` and `body`; `bm25(chunk_fts, 5, 5, 2, 1)` ranks them.
//! - **Vectors** (when the caller gives the query's vector and its model) are scanned by Hamming distance over the sign
//!   bits, and the nearest [`SCAN`] re-ranked by their int8 values.
//! - **Fusion** is RRF with k = 60. A chunk of a test file or a generated file keeps [`DEMOTE`] of its score.
//! - **Re-anchoring.** The hits' files are read as they are now (the caller's `now`, at most [`REANCHOR_FILES`] files
//!   and [`REANCHOR_BUDGET`] in all); a chunk that is no longer at its lines is looked for by its first line, else by
//!   its symbol, and the hit moves with it.

use crate::index::{Lag, lag};
use crate::schema::encode_symbol;
use crate::store::{CodeStore, StoreError};
use crate::tree::View;
use rusqlite::{Connection, params};
use std::collections::{BinaryHeap, HashMap, HashSet};
use std::time::{Duration, Instant};

/// RRF's k.
pub const RRF_K: f64 = 60.0;
/// What a test or generated file's chunk keeps of its fused score.
pub const DEMOTE: f64 = 0.5;
/// How long each route's ranked list is.
const LIST: usize = 100;
/// How many chunks the Hamming scan hands to the int8 re-rank, and how many the re-rank keeps.
const SCAN: usize = 200;
const RERANKED: usize = 50;
/// How many files a query re-anchors, and for how long.
pub const REANCHOR_FILES: usize = 20;
pub const REANCHOR_BUDGET: Duration = Duration::from_millis(50);
/// The longest preview, in characters.
const PREVIEW: usize = 400;

/// Words that name no code in a question.
const STOP: &[&str] = &[
    "the", "an", "of", "in", "to", "is", "are", "do", "does", "where", "how", "what", "which",
    "and", "or", "for", "with", "it", "that", "this", "from", "when", "why", "who", "can", "be",
];

/// Which files a query looks in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    /// Code, and tests below it (demoted).
    Code,
    Tests,
    Docs,
    All,
}

impl Scope {
    pub fn parse(s: &str) -> Option<Scope> {
        match s {
            "code" => Some(Scope::Code),
            "tests" => Some(Scope::Tests),
            "docs" => Some(Scope::Docs),
            "all" => Some(Scope::All),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Scope::Code => "code",
            Scope::Tests => "tests",
            Scope::Docs => "docs",
            Scope::All => "all",
        }
    }

    fn admits(self, class: &str) -> bool {
        match self {
            Scope::Code => class == "code" || class == "test",
            Scope::Tests => class == "test",
            Scope::Docs => class == "docs",
            Scope::All => true,
        }
    }

    /// The task words of the query instruction a server's model is given for this scope (Qwen's code-task wording).
    pub fn instruction(self) -> &'static str {
        match self {
            Scope::Code | Scope::All => {
                "Given a question about a codebase, retrieve the code that answers it"
            }
            Scope::Tests => "Given a question about a codebase, retrieve the tests that cover it",
            Scope::Docs => {
                "Given a question about a codebase, retrieve the documentation that answers it"
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct Query {
    pub text: String,
    pub scope: Scope,
    pub k: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Hit {
    pub path: String,
    pub line_start: u32,
    pub line_end: u32,
    pub symbol: Option<String>,
    pub score: f64,
    pub preview: String,
    /// The routes that found it: `symbol`, `name`, `path`, `keyword`, `vector`.
    pub routes: Vec<&'static str>,
    /// Its lines were found again in the file as it is now.
    pub reanchored: bool,
}

#[derive(Clone, Debug)]
pub struct Answer {
    pub hits: Vec<Hit>,
    pub lag: Lag,
    /// The model whose vectors took part; none when the answer is keyword, symbol and path results only.
    pub model: Option<String>,
    /// What the caller should tell the reader (why there are no vectors).
    pub notice: Option<String>,
}

impl Answer {
    /// The line that ends a text answer: which view answered (a worktree's says how many files differ), what lags,
    /// and which model answered.
    pub fn lag_line(&self) -> String {
        let view = match self.lag.differing_files {
            Some(n) => format!("worktree: {n} files differ from the base; "),
            None => String::new(),
        };
        format!("{view}{}", self.vectors_line())
    }

    fn vectors_line(&self) -> String {
        let l = &self.lag;
        let stale = if l.dirty_files > 0 {
            format!("; {} files changed since indexing", l.dirty_files)
        } else {
            String::new()
        };
        match &self.model {
            None => format!(
                "vectors: not used ({}); keyword and symbol results are current{stale}",
                self.notice
                    .as_deref()
                    .unwrap_or("no embedding model answered")
            ),
            Some(m) if l.files_behind == 0 => format!("vectors: current ({m}){stale}"),
            Some(m) => format!(
                "vectors: {} files behind ({m}); keyword and symbol results are current{stale}",
                l.files_behind
            ),
        }
    }
}

/// One identifier-like token: it holds a letter and one of `- _ : / .`, or it is the whole query.
fn identifier_like(t: &str, whole: bool) -> bool {
    t.chars().any(char::is_alphabetic)
        && (whole || t.chars().any(|c| matches!(c, '-' | '_' | ':')))
        && !t.contains(char::is_whitespace)
}

/// `"w"`, an FTS5 string.
fn quoted(w: &str) -> String {
    format!("\"{}\"", w.replace('"', "\"\""))
}

/// The alphanumeric pieces of T, lower-cased.
fn parts(t: &str) -> Vec<String> {
    t.split(|c: char| !c.is_alphanumeric())
        .filter(|p| !p.is_empty())
        .map(str::to_lowercase)
        .collect()
}

/// The FTS5 MATCH for the tokens, or none when there is nothing to match.
fn fts_match(tokens: &[String], whole: bool) -> Option<String> {
    let mut terms = Vec::new();
    let mut words: Vec<String> = Vec::new();
    for t in tokens {
        if identifier_like(t, whole && tokens.len() == 1) {
            terms.push(format!("symbols : {}", quoted(&encode_symbol(t))));
            let p = parts(t);
            if p.len() > 1 {
                terms.push(format!("{{doc body}} : {}", quoted(&p.join(" "))));
            }
            words.extend(p);
        } else {
            words.extend(parts(t));
        }
    }
    words.retain(|w| w.len() > 1 && !STOP.contains(&w.as_str()));
    words.sort();
    words.dedup();
    if !words.is_empty() {
        let list: Vec<String> = words.iter().map(|w| quoted(w)).collect();
        terms.push(format!("{{doc body}} : ({})", list.join(" OR ")));
    }
    (!terms.is_empty()).then(|| terms.join(" OR "))
}

fn kind_rank(kind: &str) -> u8 {
    match kind {
        "function" | "defun" | "fn" => 0,
        "macro" => 1,
        "method" => 2,
        "struct" | "class" | "type" | "enum" | "trait" => 3,
        "variable" | "const" | "static" => 4,
        _ => 5,
    }
}

/// The ranked lists of the routes, each of chunk ids, best first.
#[derive(Default)]
struct Lists {
    pinned: Vec<i64>,
    ranked: Vec<(&'static str, Vec<i64>)>,
}

fn ids(c: &Connection, sql: &str, p: impl rusqlite::Params) -> rusqlite::Result<Vec<i64>> {
    c.prepare(sql)?.query_map(p, |r| r.get(0))?.collect()
}

/// The `file` row (alias `f`) through which a view sees a row (alias ROW) of `chunk` or `symbol`: its path's row in
/// the view, the tree's over the base's (`?V` is the view's tree, 0 for the base, so the base view reads one row). The
/// row is visible when `f.blob = ROW.blob`; a tombstone (NULL) matches nothing. At most two primary-key probes of
/// `file` per candidate. Every route applies it **before** its `limit` (H16 overlay design §4), and the view's tree is
/// each statement's last parameter.
macro_rules! seen_through {
    ($row:literal, $view:literal) => {
        concat!(
            "file f on f.path = ",
            $row,
            ".path and f.tree = (select max(o.tree) from file o where o.tree in (0, ",
            $view,
            ") and o.path = ",
            $row,
            ".path)"
        )
    };
}

/// An exact name's definitions in the view (?1 the name).
pub const PINNED_SQL: &str = concat!(
    "select s.chunk, s.kind, f.class, s.path from symbol s cross join ",
    seen_through!("s", "?2"),
    " where s.name = ?1 and f.blob = s.blob"
);

fn pinned(c: &Connection, name: &str, view: View) -> rusqlite::Result<Vec<i64>> {
    let mut rows: Vec<(i64, String, String, String)> = c
        .prepare(PINNED_SQL)?
        .query_map(params![name, view.tree()], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })?
        .collect::<Result<_, _>>()?;
    rows.sort_by(|a, b| {
        (a.2 == "test", kind_rank(&a.1), &a.3, a.0).cmp(&(
            b.2 == "test",
            kind_rank(&b.1),
            &b.3,
            b.0,
        ))
    });
    Ok(rows.into_iter().map(|r| r.0).collect())
}

/// The symbols whose name starts with ?1 (a `like` pattern), on the `symbol_name_nc` index: `like` ignores case, so
/// only an index of the same collation serves it (a scan of `symbol` was 18 ms at 50,000 chunks).
///
/// `cross join` keeps `symbol` the outer loop: without statistics the planner would walk every file row and probe its
/// symbols instead.
pub const NAME_PREFIX_SQL: &str = concat!(
    "select s.chunk from symbol s cross join ",
    seen_through!("s", "?2"),
    " where s.name like ?1 escape '\\' and f.blob = s.blob order by length(s.name) limit 30"
);
pub const NAME_EXACT_SQL: &str = concat!(
    "select s.chunk from symbol s cross join ",
    seen_through!("s", "?2"),
    " where s.name = ?1 and f.blob = s.blob limit 30"
);
pub const NAME_TRIGRAM_SQL: &str = concat!(
    "select s.chunk from symbol_fts join symbol s on s.id = symbol_fts.rowid cross join ",
    seen_through!("s", "?2"),
    " where symbol_fts match ?1 and f.blob = s.blob limit 30"
);

fn names(c: &Connection, token: &str, view: View) -> rusqlite::Result<Vec<i64>> {
    let v = view.tree();
    let mut out = ids(c, NAME_EXACT_SQL, params![token, v])?;
    let like = format!(
        "{}%",
        token
            .replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_")
    );
    out.extend(ids(c, NAME_PREFIX_SQL, params![like, v])?);
    if token.chars().count() >= 3 {
        out.extend(ids(c, NAME_TRIGRAM_SQL, params![quoted(token), v])?);
    }
    Ok(out)
}

/// The first chunk of each file whose path holds ?1 (the `file` table has a row per file; the `chunk` table has one per
/// chunk, each with its text: a scan of it for a `like` was 7 ms per token at 50,000 chunks).
pub const PATH_ANY_SQL: &str = "select id from (
       select (select min(c.id) from chunk c where c.path = f.path and c.blob = f.blob) as id, f.path as p
       from file f where f.tree in (0, ?2) and f.blob is not null and lower(f.path) like ?1 escape '\\'
         and f.tree = (select max(o.tree) from file o where o.tree in (0, ?2) and o.path = f.path))
     where id is not null order by length(p) limit 30";
/// The same for a path whose file name is ?1 or starts with it (`/name.` in ?1, `name.` in ?2).
pub const PATH_NAME_SQL: &str = "select id from (
       select (select min(c.id) from chunk c where c.path = f.path and c.blob = f.blob) as id, f.path as p
       from file f where f.tree in (0, ?3) and f.blob is not null
         and (lower(f.path) like ?1 escape '\\' or lower(f.path) like ?2 escape '\\')
         and f.tree = (select max(o.tree) from file o where o.tree in (0, ?3) and o.path = f.path))
     where id is not null order by length(p) limit 30";

fn paths(c: &Connection, token: &str, view: View) -> rusqlite::Result<Vec<i64>> {
    let t = token.to_lowercase();
    let like = |s: &str| {
        s.replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_")
    };
    if t.contains('/') || t.contains('.') {
        ids(
            c,
            PATH_ANY_SQL,
            params![format!("%{}%", like(&t)), view.tree()],
        )
    } else {
        ids(
            c,
            PATH_NAME_SQL,
            params![
                format!("%/{}.%", like(&t)),
                format!("{}.%", like(&t)),
                view.tree()
            ],
        )
    }
}

/// The vectors the scan reads: MODEL's, and nothing else. The chunk of a key is looked up (`FIRST_CHUNK_SQL`) only for
/// a vector that can enter the best SCAN, not for each of them: a lookup per vector was 160 ms of the 180 at 50,000
/// chunks. (A join of `chunk` with `vec` and `c.id in (select min(id) … group by key)` made SQLite probe a list once
/// per vector: 37 s for 16,000 chunks.)
pub const NEAREST_SQL: &str = "select key, dims, vec from vec where model = ?1";

/// The first visible chunk of a content key (none: the vector is kept for a file that is gone, or only a worktree
/// has the content).
pub const FIRST_CHUNK_SQL: &str = concat!(
    "select min(c.id) from chunk c cross join ",
    seen_through!("c", "?2"),
    " where c.key = ?1 and c.embed = 1 and f.blob = c.blob"
);

/// The nearest chunks of MODEL to the query vector V: Hamming over the sign bits, then the int8 dot product.
fn nearest(c: &Connection, model: &str, v: &[f32], view: View) -> rusqlite::Result<Vec<i64>> {
    let (qbits, qints, _) = urdr::graph::search::vec::quantize(v);
    let mut heap: BinaryHeap<(u32, i64)> = BinaryHeap::with_capacity(SCAN + 1);
    {
        let mut st = c.prepare(NEAREST_SQL)?;
        let mut first = c.prepare(FIRST_CHUNK_SQL)?;
        let mut rows = st.query([model])?;
        while let Some(r) = rows.next()? {
            let dims: i64 = r.get(1)?;
            let blob = r.get_ref(2)?.as_blob()?;
            if usize::try_from(dims).ok() != Some(v.len()) || blob.len() < qbits.len() {
                continue;
            }
            let d: u32 = blob[..qbits.len()]
                .iter()
                .zip(&qbits)
                .map(|(a, b)| (a ^ b).count_ones())
                .sum();
            let full = heap.len() >= SCAN;
            if full && heap.peek().is_some_and(|w| d > w.0) {
                continue;
            }
            let key = r.get_ref(0)?.as_blob()?;
            let Some(id) =
                first.query_row(params![key, view.tree()], |r| r.get::<_, Option<i64>>(0))?
            else {
                continue;
            };
            if !full {
                heap.push((d, id));
            } else if heap.peek().is_some_and(|w| (d, id) < *w) {
                heap.pop();
                heap.push((d, id));
            }
        }
    }
    let mut scored: Vec<(i64, i64)> = Vec::with_capacity(heap.len());
    for (_, id) in heap {
        let (blob, scale): (Vec<u8>, f64) = c.query_row(
            "select v.vec, v.scale from chunk c join vec v on v.key = c.key and v.model = ?1 where c.id = ?2",
            params![model, id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let dot: i64 = blob[qbits.len()..]
            .iter()
            .zip(&qints)
            .map(|(a, b)| i64::from(*a as i8) * i64::from(*b))
            .sum();
        // the scale is the vector's own; ranking by the dot of the dequantised values
        scored.push((id, (dot as f64 * scale * 1e6) as i64));
    }
    scored.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    scored.truncate(RERANKED);
    Ok(scored.into_iter().map(|s| s.0).collect())
}

/// The keyword list (?1 the MATCH, ?2 its length). FTS5 gives no top-N guarantee, so the whole match set is scored;
/// with shared content that set is about the distinct content, not trees times content.
pub const KEYWORD_SQL: &str = concat!(
    "select chunk_fts.rowid from chunk_fts join chunk c on c.id = chunk_fts.rowid cross join ",
    seen_through!("c", "?3"),
    " where chunk_fts match ?1 and f.blob = c.blob order by bm25(chunk_fts, 5, 5, 2, 1) limit ?2"
);

fn lists(
    c: &Connection,
    text: &str,
    qvec: Option<(&str, &[f32])>,
    view: View,
) -> rusqlite::Result<Lists> {
    let tokens: Vec<String> = text.split_whitespace().map(str::to_string).collect();
    let mut out = Lists::default();
    if tokens.is_empty() {
        return Ok(out);
    }
    let whole = tokens.len() == 1;
    if whole {
        out.pinned = pinned(c, &tokens[0], view)?;
    }
    let mut named = Vec::new();
    for t in tokens.iter().filter(|t| identifier_like(t, whole)) {
        named.extend(names(c, t, view)?);
    }
    if !named.is_empty() {
        out.ranked.push(("name", named));
    }
    let mut on_paths = Vec::new();
    for t in tokens.iter().filter(|t| t.chars().count() >= 3) {
        on_paths.extend(paths(c, t, view)?);
    }
    if !on_paths.is_empty() {
        out.ranked.push(("path", on_paths));
    }
    if let Some(m) = fts_match(&tokens, whole) {
        // a MATCH the engine cannot read (a stray operator) is no list, not an error
        if let Ok(found) = ids(c, KEYWORD_SQL, params![m, LIST as i64, view.tree()]) {
            out.ranked.push(("keyword", found));
        }
    }
    if let Some((model, v)) = qvec {
        out.ranked.push(("vector", nearest(c, model, v, view)?));
    }
    Ok(out)
}

struct Meta {
    path: String,
    line_start: u32,
    line_end: u32,
    symbol: Option<String>,
    embed_text: String,
    class: String,
    generated: bool,
}

/// A hit's chunk and the class of the view's file row it is seen through; none when the view does not see it.
pub const META_SQL: &str = concat!(
    "select c.path, c.line_start, c.line_end, c.symbol, c.embed_text, f.class, f.generated from chunk c cross join ",
    seen_through!("c", "?2"),
    " where c.id = ?1 and f.blob = c.blob"
);

fn meta(c: &Connection, id: i64, view: View) -> rusqlite::Result<Option<Meta>> {
    let mut st = c.prepare(META_SQL)?;
    let mut rows = st.query(params![id, view.tree()])?;
    Ok(match rows.next()? {
        Some(r) => Some(Meta {
            path: r.get(0)?,
            line_start: r.get(1)?,
            line_end: r.get(2)?,
            symbol: r.get(3)?,
            embed_text: r.get(4)?,
            class: r.get(5)?,
            generated: r.get::<_, i64>(6)? != 0,
        }),
        None => None,
    })
}

/// The chunk's own text: what follows the header.
fn body(embed_text: &str) -> &str {
    embed_text.split_once("\n\n").map_or(embed_text, |(_, b)| b)
}

fn preview(embed_text: &str) -> String {
    let b = body(embed_text).trim_end();
    let mut out: String = b.lines().take(8).collect::<Vec<_>>().join("\n");
    if out.chars().count() > PREVIEW {
        out = out.chars().take(PREVIEW).collect();
        out.push('…');
    }
    out
}

/// The hit's lines found again in TEXT (the file as it is now): none when its first line is where it was, the
/// shifted lines when it moved, `Err` when nothing like it is left.
fn reanchor(h: &Hit, embed_text: &str, text: &str) -> Result<Option<(u32, u32)>, ()> {
    let lines: Vec<&str> = text.lines().collect();
    let first = body(embed_text)
        .lines()
        .find(|l| !l.trim().is_empty())
        .map(str::trim_end);
    let at = h.line_start as usize;
    if first.is_some_and(|f| {
        lines
            .get(at.wrapping_sub(1))
            .is_some_and(|l| l.trim_end() == f)
    }) {
        return Ok(None);
    }
    let found = first
        .and_then(|f| {
            (0..lines.len())
                .filter(|i| lines[*i].trim_end() == f)
                .min_by_key(|i| i.abs_diff(at.saturating_sub(1)))
        })
        .or_else(|| {
            let sym = h.symbol.as_deref()?;
            (0..lines.len())
                .filter(|i| lines[*i].contains(sym))
                .min_by_key(|i| i.abs_diff(at.saturating_sub(1)))
        });
    match found {
        Some(i) => {
            let len = h.line_end.saturating_sub(h.line_start);
            let start = i as u32 + 1;
            Ok(Some((start, start + len)))
        }
        None => Err(()),
    }
}

/// The answer to Q: hits from the store's lists, the vectors of QVEC's model when given, and HITS' lines found again
/// by NOW (the file as it is now, by path).
pub async fn search(
    store: &CodeStore,
    q: &Query,
    view: View,
    qvec: Option<(&str, &[f32])>,
    now: &(dyn Fn(&str) -> Option<String> + Sync),
) -> Result<Answer, StoreError> {
    let (text, scope, k) = (q.text.clone(), q.scope, q.k.max(1) as usize);
    let owned = qvec.map(|(m, v)| (m.to_string(), v.to_vec()));
    let (mut hits, texts) = store
        .handle()
        .read(move |c| {
            let l = lists(
                c,
                &text,
                owned.as_ref().map(|(m, v)| (m.as_str(), v.as_slice())),
                view,
            )?;
            let mut score: HashMap<i64, f64> = HashMap::new();
            let mut routes: HashMap<i64, Vec<&'static str>> = HashMap::new();
            for (route, list) in &l.ranked {
                let mut seen = HashSet::new();
                let mut rank = 0.0;
                for id in list {
                    if !seen.insert(*id) {
                        continue;
                    }
                    rank += 1.0;
                    *score.entry(*id).or_insert(0.0) += 1.0 / (RRF_K + rank);
                    routes.entry(*id).or_default().push(route);
                }
            }
            let mut order: Vec<(i64, f64, bool)> = Vec::new();
            for id in &l.pinned {
                routes.entry(*id).or_default().insert(0, "symbol");
                order.push((*id, score.get(id).copied().unwrap_or(0.0) + 1.0, true));
            }
            let mut rest: Vec<(i64, f64, bool)> = score
                .iter()
                .filter(|(id, _)| !l.pinned.contains(id))
                .map(|(id, s)| (*id, *s, false))
                .collect();
            let mut metas: HashMap<i64, Meta> = HashMap::new();
            for (id, ..) in order.iter().chain(&rest) {
                if let Some(m) = meta(c, *id, view)? {
                    metas.insert(*id, m);
                }
            }
            order.retain(|(id, ..)| metas.get(id).is_some_and(|m| scope.admits(&m.class)));
            rest.retain(|(id, ..)| metas.get(id).is_some_and(|m| scope.admits(&m.class)));
            for (id, s, _) in &mut rest {
                if metas
                    .get(id)
                    .is_some_and(|m| m.class == "test" || m.generated)
                {
                    *s *= DEMOTE;
                }
            }
            rest.sort_by(|a, b| {
                b.1.total_cmp(&a.1).then_with(|| {
                    let (ma, mb) = (&metas[&a.0], &metas[&b.0]);
                    (&ma.path, ma.line_start).cmp(&(&mb.path, mb.line_start))
                })
            });
            let mut hits = Vec::new();
            let mut texts = Vec::new();
            for (id, s, _) in order.into_iter().chain(rest).take(k) {
                let m = &metas[&id];
                hits.push(Hit {
                    path: m.path.clone(),
                    line_start: m.line_start,
                    line_end: m.line_end,
                    symbol: m.symbol.clone(),
                    score: s,
                    preview: preview(&m.embed_text),
                    routes: routes.remove(&id).unwrap_or_default(),
                    reanchored: false,
                });
                texts.push(m.embed_text.clone());
            }
            Ok((hits, texts))
        })
        .await?;
    // re-anchor, within the files and the time it may take
    let started = Instant::now();
    let mut files: Vec<String> = Vec::new();
    let mut current: HashMap<String, Option<String>> = HashMap::new();
    for (h, t) in hits.iter_mut().zip(&texts) {
        if started.elapsed() > REANCHOR_BUDGET {
            break;
        }
        if !current.contains_key(&h.path) {
            if files.len() >= REANCHOR_FILES {
                continue;
            }
            files.push(h.path.clone());
            current.insert(h.path.clone(), now(&h.path));
        }
        if let Some(Some(file)) = current.get(&h.path)
            && let Ok(Some((a, b))) = reanchor(h, t, file)
        {
            (h.line_start, h.line_end, h.reanchored) = (a, b, true);
        }
    }
    let model = qvec.map(|(m, _)| m.to_string());
    let lag = lag(store, model.as_deref(), view).await?;
    let notice = model
        .is_none()
        .then(|| "no embedding model answered".to_string());
    Ok(Answer {
        hits,
        lag,
        model,
        notice,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::door::DoorKind;
    use crate::store::{ChunkIn, FileRow, SymbolIn, vec_key};

    /// N chunks of PATH, each defining one symbol `needle`.
    fn needles(path: &str, n: usize) -> (Vec<ChunkIn>, Vec<SymbolIn>) {
        let chunks = (0..n)
            .map(|i| {
                let text = format!("{path} {i}");
                ChunkIn {
                    start: 0,
                    end: 1,
                    line_start: i as u32 + 1,
                    line_end: i as u32 + 1,
                    symbol: Some("needle".into()),
                    key: vec_key(1, &text),
                    embed: true,
                    embed_text: text,
                    symbols: "needle".into(),
                    doc: String::new(),
                    body: "needle".into(),
                }
            })
            .collect();
        let symbols = (0..n)
            .map(|i| SymbolIn {
                name: "needle".into(),
                kind: "function".into(),
                start: 0,
                end: 1,
                chunk: i,
                definer: "defun".into(),
                doc1: None,
            })
            .collect();
        (chunks, symbols)
    }

    fn row(path: &str, blob: &str) -> FileRow {
        FileRow {
            path: path.into(),
            blob: Some(blob.into()),
            class: "code".into(),
            lang: "elisp".into(),
            generated: false,
            size: 1,
            indexed_at: 1,
        }
    }

    /// Pattern D. 40 symbols named `needle` that only a worktree has, written first so they come first in every index:
    /// the Base view's name routes still return 30 base hits each, none of them the tree's.
    #[tokio::test]
    async fn base_view_filters_before_limit() {
        let dir = tempfile::tempdir().unwrap();
        let s = CodeStore::open(&dir.path().join("p.db")).unwrap();
        let t = s.tree_open("wt", "/w", "/g", DoorKind::Cli).await.unwrap();
        let (c, y) = needles("t.el", 40);
        s.write_file(View::Tree(t), row("t.el", "T"), c, y)
            .await
            .unwrap();
        let (c, y) = needles("b.el", 35);
        let base: HashSet<i64> = s
            .write_file(View::Base, row("b.el", "B"), c, y)
            .await
            .unwrap()
            .into_iter()
            .collect();
        let found = s
            .handle()
            .read(|c| Ok(names(c, "needle", View::Base)?))
            .await
            .unwrap();
        assert_eq!(found.len(), 90, "30 from each of the three name routes");
        assert!(found.iter().all(|id| base.contains(id)), "{found:?}");
        let pinned = s
            .handle()
            .read(|c| Ok(pinned(c, "needle", View::Base)?))
            .await
            .unwrap();
        assert_eq!(pinned.len(), 35);
        assert!(pinned.iter().all(|id| base.contains(id)));
    }
}
