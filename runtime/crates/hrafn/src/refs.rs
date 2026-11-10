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
