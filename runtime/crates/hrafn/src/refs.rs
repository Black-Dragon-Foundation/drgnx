//! The references a view sees: the `ref` rows (schema v5, written by tier 1 from `chunk::refs`) of the `(path, blob)`
//! pairs the view's `file` rows name, by name. The usages and the graph read them; they answer from the index alone.

use crate::query::seen_through;
use crate::store::{CodeStore, StoreError};
use crate::tree::View;
use rusqlite::{Connection, params};

/// One file's use of a name: how often, and its first lines.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RefRow {
    pub path: String,
    pub blob: String,
    /// The file's class: `code`, `test` or `docs`.
    pub class: String,
    pub n: u32,
    pub lines: Vec<u32>,
}

/// A name's references in the view (?2), by path (on `ref_name`).
pub const REFS_SQL: &str = concat!(
    "select r.path, r.blob, f.class, r.n, r.lines from ref r cross join ",
    seen_through!("r", "?2"),
    " where r.name = ?1 and f.blob = r.blob order by r.path"
);

/// A name's `(path, blob, n)` in every pair, the view not applied: on `ref_name` alone (schema v6 carries `n`), for the
/// usages, which filter the pairs by the view's graph (`map::usages`).
pub const COUNTS_SQL: &str = "select path, blob, n from ref where name = ?1";

/// One pair's first lines of a name, on the primary key.
const LINES_SQL: &str = "select lines from ref where path = ?1 and blob = ?2 and name = ?3";

/// The first lines of NAME in the pair `(path, blob)`.
pub(crate) fn lines(
    c: &Connection,
    path: &str,
    blob: &str,
    name: &str,
) -> rusqlite::Result<Vec<u32>> {
    let lines: Option<String> = c
        .prepare(LINES_SQL)?
        .query_row(params![path, blob, name], |r| r.get(0))
        .map(Some)
        .or_else(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            e => Err(e),
        })?;
    Ok(lines
        .unwrap_or_default()
        .split(' ')
        .filter_map(|l| l.parse().ok())
        .collect())
}

/// NAME's references in VIEW, by path, inside a read on the store thread.
pub(crate) fn rows(c: &Connection, view: View, name: &str) -> rusqlite::Result<Vec<RefRow>> {
    c.prepare(REFS_SQL)?
        .query_map(params![name, view.tree()], |r| {
            let lines: String = r.get(4)?;
            Ok(RefRow {
                path: r.get(0)?,
                blob: r.get(1)?,
                class: r.get(2)?,
                n: r.get(3)?,
                lines: lines.split(' ').filter_map(|l| l.parse().ok()).collect(),
            })
        })?
        .collect()
}

/// NAME's references in VIEW, by path.
pub async fn references(
    store: &CodeStore,
    view: View,
    name: &str,
) -> Result<Vec<RefRow>, StoreError> {
    let name = name.to_string();
    Ok(store
        .handle()
        .read(move |c| Ok(rows(c, view, &name)?))
        .await?)
}
