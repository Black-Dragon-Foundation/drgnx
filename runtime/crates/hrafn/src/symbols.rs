//! Definitions by name ([`find`]) and a file's outline ([`outline`]), in a view: the symbol table as agents ask it.
//!
//! Both answer from the index alone and never read a file, so what the file list leaves out (dot paths, secret-like
//! names, the configuration's excludes, large or binary files) is never in an answer. Every statement applies the
//! view's visibility (H16 overlay design §4) before its `limit`.
//!
//! - **Matching.** `exact` is case-sensitive equality; `prefix` ignores case (on `symbol_name_nc`); `contains` uses the
//!   trigram index from three characters and a scan below that; `regex` is matched in Rust against the distinct names
//!   (at most [`REGEX_NAMES`] of them are then looked up). `auto` tries exact, then prefix, then contains, and the
//!   answer says which one matched.
//! - **Order.** Code, then docs, then tests; within that a shorter name (prefix and contains), the kind (functions,
//!   macros, methods, types, variables), the path, the start.
//! - **Filters** (kinds, a path glob, the scope) run on the matched rows, of which at most [`FETCH`] are read.

use crate::files::Glob;
use crate::query::{Scope, kind_rank, quoted, seen_through};
use crate::store::{CodeStore, StoreError};
use crate::tree::View;
use rusqlite::{Connection, params};
use std::fmt;

/// How many matching rows a find reads before its filters.
const FETCH: i64 = 2000;
/// How many distinct names a regex may match before they are looked up.
pub const REGEX_NAMES: usize = 500;
/// The largest compiled regex.
const REGEX_SIZE: usize = 1 << 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Match {
    Auto,
    Exact,
    Prefix,
    Contains,
    Regex,
}

impl Match {
    pub fn parse(s: &str) -> Option<Match> {
        Some(match s {
            "auto" => Match::Auto,
            "exact" => Match::Exact,
            "prefix" => Match::Prefix,
            "contains" => Match::Contains,
            "regex" => Match::Regex,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Match::Auto => "auto",
            Match::Exact => "exact",
            Match::Prefix => "prefix",
            Match::Contains => "contains",
            Match::Regex => "regex",
        }
    }
}

/// What to find.
#[derive(Clone, Debug)]
pub struct Find {
    pub name: String,
    pub mode: Match,
    /// Only these kinds; empty: all.
    pub kinds: Vec<String>,
    /// Only paths this glob matches (a configuration glob, relative to the root).
    pub glob: Option<String>,
    pub scope: Scope,
    pub k: usize,
}

/// One definition.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SymbolHit {
    pub path: String,
    pub name: String,
    pub kind: String,
    pub line_start: u32,
    pub line_end: u32,
    pub sig: String,
    pub doc1: Option<String>,
    /// The innermost definition around it in the same file (a method's impl or class).
    pub container: Option<String>,
    /// `code`, `test` or `docs`.
    pub class: String,
}

/// A find's answer: which match answered (never `Auto`), and the definitions.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Found {
    pub matched: Match,
    pub hits: Vec<SymbolHit>,
}

/// One row of an outline; `depth` counts the definitions around it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutlineEntry {
    pub name: String,
    pub kind: String,
    pub line_start: u32,
    pub line_end: u32,
    pub sig: String,
    pub doc1: Option<String>,
    pub depth: u32,
}

/// A file's definitions in file order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Outline {
    pub path: String,
    pub lang: String,
    pub entries: Vec<OutlineEntry>,
}

#[derive(Debug)]
pub enum SymbolsError {
    Store(StoreError),
    BadRegex(String),
    /// The view holds no such file: there is none, or the file list leaves it out.
    NotIndexed,
}

impl fmt::Display for SymbolsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SymbolsError::Store(e) => write!(f, "{e}"),
            SymbolsError::BadRegex(e) => write!(f, "not a regular expression: {e}"),
            SymbolsError::NotIndexed => f.write_str(
                "not in the index: no such file in this view, or search leaves it out (dot paths, secret-like names, \
                 .drgnx/search.eld excludes, files over 1 MiB, binary files)",
            ),
        }
    }
}

impl std::error::Error for SymbolsError {}

impl From<StoreError> for SymbolsError {
    fn from(e: StoreError) -> SymbolsError {
        SymbolsError::Store(e)
    }
}

impl From<urdr::Error> for SymbolsError {
    fn from(e: urdr::Error) -> SymbolsError {
        SymbolsError::Store(e.into())
    }
}

/// The columns every statement reads (`s` the symbol, `f` its file row in the view).
const COLS: &str = "s.id, s.name, s.kind, s.path, s.blob, s.start, s.end, s.line_start, s.line_end, s.sig, s.doc1, f.class";

/// A row read by [`COLS`].
struct Row {
    id: i64,
    name: String,
    kind: String,
    path: String,
    blob: String,
    start: i64,
    end: i64,
    line_start: u32,
    line_end: u32,
    sig: String,
    doc1: Option<String>,
    class: String,
}

fn row(r: &rusqlite::Row) -> rusqlite::Result<Row> {
    Ok(Row {
        id: r.get(0)?,
        name: r.get(1)?,
        kind: r.get(2)?,
        path: r.get(3)?,
        blob: r.get(4)?,
        start: r.get(5)?,
        end: r.get(6)?,
        line_start: r.get(7)?,
        line_end: r.get(8)?,
        sig: r.get(9)?,
        doc1: r.get(10)?,
        class: r.get(11)?,
    })
}

const FROM: &str = concat!("from symbol s cross join ", seen_through!("s", "?2"));
const FROM_TRIGRAM: &str = concat!(
    "from symbol_fts join symbol s on s.id = symbol_fts.rowid cross join ",
    seen_through!("s", "?2")
);

fn rows(c: &Connection, sql: &str, p: impl rusqlite::Params) -> rusqlite::Result<Vec<Row>> {
    c.prepare(sql)?.query_map(p, row)?.collect()
}

fn like_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

fn exact(c: &Connection, name: &str, v: i64) -> rusqlite::Result<Vec<Row>> {
    rows(
        c,
        &format!("select {COLS} {FROM} where s.name = ?1 and f.blob = s.blob limit ?3"),
        params![name, v, FETCH],
    )
}

fn prefix(c: &Connection, name: &str, v: i64) -> rusqlite::Result<Vec<Row>> {
    rows(
        c,
        &format!(
            "select {COLS} {FROM} where s.name like ?1 escape '\\' and f.blob = s.blob order by length(s.name) limit ?3"
        ),
        params![format!("{}%", like_escape(name)), v, FETCH],
    )
}

fn contains(c: &Connection, name: &str, v: i64) -> rusqlite::Result<Vec<Row>> {
    if name.chars().count() >= 3 {
        rows(
            c,
            &format!(
                "select {COLS} {FROM_TRIGRAM} where symbol_fts match ?1 and f.blob = s.blob limit ?3"
            ),
            params![quoted(name), v, FETCH],
        )
    } else {
        rows(
            c,
            &format!(
                "select {COLS} {FROM} where s.name like ?1 escape '\\' and f.blob = s.blob limit ?3"
            ),
            params![format!("%{}%", like_escape(name)), v, FETCH],
        )
    }
}

fn by_regex(c: &Connection, re: &regex::Regex, v: i64) -> rusqlite::Result<Vec<Row>> {
    let mut names: Vec<String> = Vec::new();
    {
        let mut q = c.prepare("select distinct name from symbol")?;
        let mut it = q.query([])?;
        while let Some(r) = it.next()? {
            let n: String = r.get(0)?;
            if re.is_match(&n) {
                names.push(n);
                if names.len() >= REGEX_NAMES {
                    break;
                }
            }
        }
    }
    let mut out = Vec::new();
    for n in names {
        out.extend(exact(c, &n, v)?);
        if out.len() as i64 >= FETCH {
            break;
        }
    }
    Ok(out)
}

/// The innermost other definition of the same file whose span holds R's and is longer.
fn container(c: &Connection, r: &Row) -> rusqlite::Result<Option<String>> {
    let mut q = c.prepare(
        "select name from symbol where path = ?1 and blob = ?2 and start <= ?3 and end >= ?4 and id != ?5
           and end - start > ?4 - ?3 order by end - start limit 1",
    )?;
    let mut it = q.query(params![r.path, r.blob, r.start, r.end, r.id])?;
    Ok(match it.next()? {
        Some(x) => Some(x.get(0)?),
        None => None,
    })
}

fn class_rank(class: &str) -> u8 {
    match class {
        "code" => 0,
        "docs" => 1,
        _ => 2,
    }
}

/// The definitions F asks for, in VIEW.
pub async fn find(store: &CodeStore, view: View, f: &Find) -> Result<Found, SymbolsError> {
    let re = match f.mode {
        Match::Regex => Some(
            regex::RegexBuilder::new(&f.name)
                .size_limit(REGEX_SIZE)
                .build()
                .map_err(|e| SymbolsError::BadRegex(e.to_string()))?,
        ),
        _ => None,
    };
    let glob = f.glob.as_deref().map(Glob::config);
    let f = f.clone();
    let v = view.tree();
    let found = store
        .handle()
        .read(move |c| {
            let keep = |rows: Vec<Row>| -> Vec<Row> {
                rows.into_iter()
                    .filter(|r| f.scope.admits(&r.class))
                    .filter(|r| f.kinds.is_empty() || f.kinds.contains(&r.kind))
                    .filter(|r| glob.as_ref().is_none_or(|g| g.matches(&r.path)))
                    .collect()
            };
            let (matched, mut got) = match f.mode {
                Match::Exact => (Match::Exact, keep(exact(c, &f.name, v)?)),
                Match::Prefix => (Match::Prefix, keep(prefix(c, &f.name, v)?)),
                Match::Contains => (Match::Contains, keep(contains(c, &f.name, v)?)),
                Match::Regex => (
                    Match::Regex,
                    keep(by_regex(c, re.as_ref().expect("compiled above"), v)?),
                ),
                Match::Auto => {
                    let mut out = (Match::Exact, keep(exact(c, &f.name, v)?));
                    if out.1.is_empty() {
                        out = (Match::Prefix, keep(prefix(c, &f.name, v)?));
                    }
                    if out.1.is_empty() {
                        out = (Match::Contains, keep(contains(c, &f.name, v)?));
                    }
                    out
                }
            };
            got.sort_by(|a, b| {
                (
                    class_rank(&a.class),
                    a.name.len(),
                    kind_rank(&a.kind),
                    &a.path,
                    a.start,
                )
                    .cmp(&(
                        class_rank(&b.class),
                        b.name.len(),
                        kind_rank(&b.kind),
                        &b.path,
                        b.start,
                    ))
            });
            got.truncate(f.k.max(1));
            let mut hits = Vec::with_capacity(got.len());
            for r in got {
                let container = container(c, &r)?;
                hits.push(SymbolHit {
                    path: r.path,
                    name: r.name,
                    kind: r.kind,
                    line_start: r.line_start,
                    line_end: r.line_end,
                    sig: r.sig,
                    doc1: r.doc1,
                    container,
                    class: r.class,
                });
            }
            Ok(Found { matched, hits })
        })
        .await?;
    Ok(found)
}

/// `(name, kind, start, end, line_start, line_end, sig, doc1)` of one symbol of an outline.
type OutlineRow = (String, String, i64, i64, u32, u32, String, Option<String>);

/// PATH's definitions in VIEW, in file order, each with the number of definitions around it.
pub async fn outline(store: &CodeStore, view: View, path: &str) -> Result<Outline, SymbolsError> {
    let path = path.to_string();
    let v = view.tree();
    let out = store
        .handle()
        .read(move |c| {
            let file: Option<(String, String)> = {
                let mut q = c.prepare(
                    "select f.lang, f.blob from file f where f.path = ?1 and f.blob is not null
                       and f.tree = (select max(o.tree) from file o where o.tree in (0, ?2) and o.path = ?1)",
                )?;
                let mut it = q.query(params![path, v])?;
                match it.next()? {
                    Some(r) => Some((r.get(0)?, r.get(1)?)),
                    None => None,
                }
            };
            let Some((lang, blob)) = file else {
                return Ok(None);
            };
            let mut q = c.prepare(
                "select name, kind, start, end, line_start, line_end, sig, doc1 from symbol
                 where path = ?1 and blob = ?2 order by start, end desc, id",
            )?;
            let all: Vec<OutlineRow> = q
                .query_map(params![path, blob], |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        r.get(4)?,
                        r.get(5)?,
                        r.get(6)?,
                        r.get(7)?,
                    ))
                })?
                .collect::<Result<_, _>>()?;
            // the ends of the definitions around the current one
            let mut open: Vec<(i64, i64)> = Vec::new();
            let mut entries = Vec::with_capacity(all.len());
            for (name, kind, start, end, line_start, line_end, sig, doc1) in all {
                while open
                    .last()
                    .is_some_and(|&(s, e)| !(s <= start && end <= e && e - s > end - start))
                {
                    open.pop();
                }
                entries.push(OutlineEntry {
                    name,
                    kind,
                    line_start,
                    line_end,
                    sig,
                    doc1,
                    depth: open.len() as u32,
                });
                open.push((start, end));
            }
            Ok(Some(Outline {
                path: path.clone(),
                lang,
                entries,
            }))
        })
        .await?;
    out.ok_or(SymbolsError::NotIndexed)
}
