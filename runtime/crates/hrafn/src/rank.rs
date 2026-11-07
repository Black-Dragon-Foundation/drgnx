//! The ranked file query's view (H16 overlay design §4): in a worktree view the file set is the base's paths, less
//! the tree's tombstones, plus the tree's new paths. One base list is shared by every view; a tree adds a small delta.
//! The ranking here is the simple one the overlay needs; render offload Task 21 builds the full ranked query on it.

use crate::CodeStore;
use crate::store::StoreError;
use crate::tree::View;
use std::collections::HashSet;
use std::sync::Arc;

/// A tree's difference from the base's file list.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Delta {
    /// Paths the tree has and the base does not.
    pub added: Vec<String>,
    /// Base paths the tree does not admit (its tombstones).
    pub removed: HashSet<String>,
}

/// The base's file list (the paths it has content for), sorted.
pub async fn base_paths(store: &CodeStore) -> Result<Arc<[String]>, StoreError> {
    let paths: Vec<String> = store
        .handle()
        .read(|c| {
            let mut st = c.prepare(
                "select path from file where tree = 0 and blob is not null order by path",
            )?;
            Ok(st.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?)
        })
        .await?;
    Ok(Arc::from(paths))
}

/// VIEW's delta from the base (empty for the base view): read from the tree's own rows, through the `file` primary
/// key, so it costs the tree's differing paths only.
pub async fn delta(store: &CodeStore, view: View) -> Result<Delta, StoreError> {
    let View::Tree(t) = view else {
        return Ok(Delta::default());
    };
    let rows: Vec<(String, bool, bool)> = store
        .handle()
        .read(move |c| {
            let mut st = c.prepare(
                "select f.path, f.blob is null,
                   exists (select 1 from file b where b.tree = 0 and b.path = f.path and b.blob is not null)
                 from file f where f.tree = ?1 order by f.path",
            )?;
            Ok(st
                .query_map([t.0], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                .collect::<Result<_, _>>()?)
        })
        .await?;
    let mut d = Delta::default();
    for (path, tombstone, in_base) in rows {
        match (tombstone, in_base) {
            (true, true) => {
                d.removed.insert(path);
            }
            (false, false) => d.added.push(path),
            // T's other content of a base path, or a tombstone over nothing: the list is the same
            _ => {}
        }
    }
    Ok(d)
}

/// The N best paths of BASE with DELTA applied for QUERY (case-insensitive): a basename that starts with it, then a
/// basename that holds it, then a path that holds it; shorter, then by path, among equals.
pub fn rank(base: &[String], delta: &Delta, query: &str, n: usize) -> Vec<String> {
    let q = query.to_lowercase();
    let mut scored: Vec<(u8, usize, &str)> = base
        .iter()
        .filter(|p| !delta.removed.contains(*p))
        .chain(&delta.added)
        .filter_map(|p| {
            let lower = p.to_lowercase();
            let name = lower.rsplit('/').next().unwrap_or(&lower);
            let tier = if name.starts_with(&q) {
                0
            } else if name.contains(&q) {
                1
            } else if lower.contains(&q) {
                2
            } else {
                return None;
            };
            Some((tier, p.len(), p.as_str()))
        })
        .collect();
    scored.sort_unstable();
    scored
        .into_iter()
        .take(n)
        .map(|(_, _, p)| p.to_string())
        .collect()
}

/// The N best paths of VIEW for QUERY.
pub async fn files(
    store: &CodeStore,
    view: View,
    query: &str,
    n: usize,
) -> Result<Vec<String>, StoreError> {
    let (base, d) = (base_paths(store).await?, delta(store, view).await?);
    Ok(rank(&base, &d, query, n))
}
