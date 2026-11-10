//! The references a view sees: the `ref` rows (schema v5, written by tier 1 from `chunk::refs`) of the `(path, blob)`
//! pairs the view's `file` rows name, by name. The usages and the graph read them; they answer from the index alone.

use crate::query::seen_through;
use crate::store::{CodeStore, StoreError};
use crate::tree::View;
use rusqlite::params;

/// One file's use of a name: how often, and its first lines.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RefRow {
    pub path: String,
    pub n: u32,
    pub lines: Vec<u32>,
}

/// A name's references in the view (?2), by path (on `ref_name`).
pub const REFS_SQL: &str = concat!(
    "select r.path, r.n, r.lines from ref r cross join ",
    seen_through!("r", "?2"),
    " where r.name = ?1 and f.blob = r.blob order by r.path"
);

/// NAME's references in VIEW, by path.
pub async fn references(
    store: &CodeStore,
    view: View,
    name: &str,
) -> Result<Vec<RefRow>, StoreError> {
    let name = name.to_string();
    Ok(store
        .handle()
        .read(move |c| {
            let mut st = c.prepare(REFS_SQL)?;
            let rows = st
                .query_map(params![name, view.tree()], |r| {
                    let lines: String = r.get(2)?;
                    Ok(RefRow {
                        path: r.get(0)?,
                        n: r.get(1)?,
                        lines: lines.split(' ').filter_map(|l| l.parse().ok()).collect(),
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await?)
}
