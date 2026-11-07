//! The tree registry and the per-tree file rows (H16 overlay design §3).
//!
//! The base is one checkout's rows (`file.tree = 0`); each registered worktree has a `tree` row and, in `file`, only
//! the paths where its admitted blob differs from the base's. Chunks and symbols are keyed by `(path, blob)` and
//! shared by every row that names them; the last row to let go of a pair takes its chunks, FTS rows and symbols with
//! it (the reference sweep).

use crate::door::DoorKind;
use crate::store::{
    ChunkIn, CodeStore, FileRow, StoreError, SymbolIn, remove_file_row, row_blob, write_version,
};
use rusqlite::{Connection, OptionalExtension, Row, params};

/// Rows a dropped tree loses per transaction, so queries run between the batches.
const DROP_BATCH: i64 = 512;

/// A registered worktree's id (`tree.id`, > 0).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TreeId(pub i64);

/// Which rows a query or a write sees: the base, or a worktree's overlay on the base.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum View {
    Base,
    Tree(TreeId),
}

impl View {
    /// The `file.tree` value of the view's own rows.
    pub fn tree(self) -> i64 {
        match self {
            View::Base => 0,
            View::Tree(t) => t.0,
        }
    }
}

/// A tree's lifecycle state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TreeState {
    Seeding,
    Live,
    Stale,
    Unwatched,
}

impl TreeState {
    pub fn as_str(self) -> &'static str {
        match self {
            TreeState::Seeding => "seeding",
            TreeState::Live => "live",
            TreeState::Stale => "stale",
            TreeState::Unwatched => "unwatched",
        }
    }

    pub fn parse(s: &str) -> Option<TreeState> {
        match s {
            "seeding" => Some(TreeState::Seeding),
            "live" => Some(TreeState::Live),
            "stale" => Some(TreeState::Stale),
            "unwatched" => Some(TreeState::Unwatched),
            _ => None,
        }
    }
}

/// One row of `tree`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeRow {
    pub id: TreeId,
    /// History's `WorktreeId`.
    pub key: String,
    pub root: String,
    pub git_dir: String,
    /// HEAD's symref target, none when detached.
    pub branch: Option<String>,
    pub head: Option<String>,
    /// The base's `built_from` the overlay was last diffed against.
    pub seeded_from: Option<String>,
    pub door: DoorKind,
    pub state: TreeState,
    pub last_used: i64,
}

/// The base's PATH moves to NEW (none: gone or no longer admitted), inside the base batch's transaction, before the
/// base row is written (H16 overlay design §5.1 item 4). Every tree that is not seeding follows, with no read of its
/// files: a tree whose row names NEW now equals the base, so its row goes; a tree with no row was equal to the old
/// base content, so it gets a row naming that content (a tombstone when the base had none), which keeps that content
/// from the sweep.
pub(crate) fn transition(c: &Connection, path: &str, new: Option<&str>) -> urdr::Result<()> {
    let old: Option<FileRow> = c
        .prepare(
            "select blob, class, lang, generated, size, indexed_at from file where tree = 0 and path = ?1",
        )?
        .query_row([path], |r| {
            Ok(FileRow {
                path: path.to_string(),
                blob: r.get(0)?,
                class: r.get(1)?,
                lang: r.get(2)?,
                generated: r.get::<_, i64>(3)? != 0,
                size: r.get::<_, i64>(4)?.try_into().unwrap_or(0),
                indexed_at: r.get(5)?,
            })
        })
        .optional()?;
    if old.as_ref().and_then(|o| o.blob.as_deref()) == new {
        return Ok(());
    }
    // a tree being seeded is not followed: its seed compares every path that can differ with the base as it is then
    let trees: Vec<i64> = c
        .prepare("select id from tree where state != 'seeding'")?
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    for t in trees {
        match row_blob(c, t, path)? {
            Some(z) if z.as_deref() == new => {
                // no sweep: the base's row names the content next
                c.prepare("delete from file where tree = ?1 and path = ?2")?
                    .execute(params![t, path])?;
            }
            Some(_) => {}
            None => {
                let row = old.clone().unwrap_or_else(|| FileRow::tombstone(path));
                c.prepare(
                    "insert into file(tree, path, blob, class, lang, generated, size, indexed_at)
                     values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                )?
                .execute(params![
                    t,
                    row.path,
                    row.blob,
                    row.class,
                    row.lang,
                    row.generated,
                    row.size as i64,
                    row.indexed_at
                ])?;
            }
        }
    }
    Ok(())
}

fn tree_row(r: &Row<'_>) -> rusqlite::Result<TreeRow> {
    let door: String = r.get(7)?;
    let state: String = r.get(8)?;
    Ok(TreeRow {
        id: TreeId(r.get(0)?),
        key: r.get(1)?,
        root: r.get(2)?,
        git_dir: r.get(3)?,
        branch: r.get(4)?,
        head: r.get(5)?,
        seeded_from: r.get(6)?,
        // the schema's checks hold these to the known names
        door: DoorKind::parse(&door).unwrap_or(DoorKind::Cli),
        state: TreeState::parse(&state).unwrap_or(TreeState::Stale),
        last_used: r.get(9)?,
    })
}

impl CodeStore {
    /// Register the worktree KEY at ROOT (or find it, its root, git dir and door updated). A new tree starts in
    /// `seeding`. Its id.
    pub async fn tree_open(
        &self,
        key: &str,
        root: &str,
        git_dir: &str,
        door: DoorKind,
    ) -> Result<TreeId, StoreError> {
        let (key, root, git_dir) = (key.to_string(), root.to_string(), git_dir.to_string());
        Ok(self
            .handle()
            .write(move |c| {
                c.execute(
                    "insert into tree(key, root, git_dir, door) values (?1, ?2, ?3, ?4)
                     on conflict(key) do update set root = excluded.root, git_dir = excluded.git_dir,
                       door = excluded.door",
                    params![key, root, git_dir, door.as_str()],
                )?;
                Ok(TreeId(c.query_row(
                    "select id from tree where key = ?1",
                    [&key],
                    |r| r.get(0),
                )?))
            })
            .await?)
    }

    /// Every registered tree, by id.
    pub async fn trees(&self) -> Result<Vec<TreeRow>, StoreError> {
        Ok(self
            .handle()
            .read(|c| {
                let mut st = c.prepare(
                    "select id, key, root, git_dir, branch, head, seeded_from, door, state, last_used
                     from tree order by id",
                )?;
                Ok(st.query_map([], tree_row)?.collect::<Result<_, _>>()?)
            })
            .await?)
    }

    /// Note a use of the tree (a query, an event, a buffer) at AT, for the idle collection.
    pub async fn tree_touch(&self, t: TreeId, at: i64) -> Result<(), StoreError> {
        Ok(self
            .handle()
            .write(move |c| {
                c.execute(
                    "update tree set last_used = ?2 where id = ?1",
                    params![t.0, at],
                )?;
                Ok(())
            })
            .await?)
    }

    /// Set the tree's lifecycle state.
    pub async fn tree_mark(&self, t: TreeId, state: TreeState) -> Result<(), StoreError> {
        Ok(self
            .handle()
            .write(move |c| {
                c.execute(
                    "update tree set state = ?2 where id = ?1",
                    params![t.0, state.as_str()],
                )?;
                Ok(())
            })
            .await?)
    }

    /// Drop the tree: its rows go in batches (each sweeping what only it named), then its registry row.
    pub async fn tree_drop(&self, t: TreeId) -> Result<(), StoreError> {
        loop {
            let left = self
                .handle()
                .write(move |c| {
                    let paths: Vec<String> = c
                        .prepare("select path from file where tree = ?1 limit ?2")?
                        .query_map(params![t.0, DROP_BATCH], |r| r.get(0))?
                        .collect::<Result<_, _>>()?;
                    for p in &paths {
                        remove_file_row(c, t.0, p)?;
                    }
                    if paths.is_empty() {
                        c.execute("delete from tree where id = ?1", [t.0])?;
                    }
                    Ok(!paths.is_empty())
                })
                .await?;
            if !left {
                return Ok(());
            }
        }
    }

    /// Set VIEW's row of a file and, when no row named its `(path, blob)` yet, write that content's chunks and
    /// symbols; the pair the row named before is swept. The chunk ids of the content.
    pub async fn write_file(
        &self,
        view: View,
        row: FileRow,
        chunks: Vec<ChunkIn>,
        symbols: Vec<SymbolIn>,
    ) -> Result<Vec<i64>, StoreError> {
        Ok(self
            .handle()
            .write(move |c| {
                Ok(
                    write_version(c, view.tree(), &row, Some((&chunks, &symbols)), false)?
                        .unwrap_or_default(),
                )
            })
            .await?)
    }

    /// Remove VIEW's row of PATH; its content goes when no other row names it.
    pub async fn remove_file(&self, view: View, path: &str) -> Result<(), StoreError> {
        let path = path.to_string();
        Ok(self
            .handle()
            .write(move |c| remove_file_row(c, view.tree(), &path))
            .await?)
    }
}
