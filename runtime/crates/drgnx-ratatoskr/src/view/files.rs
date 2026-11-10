//! Quick Open's and Find's rows: `search/files` ranks a root's file names for a query (hrafn's `rank`) on a thread of
//! its own and sends the view the N best as rows, one per file, keyed by its path relative to the root, the query's
//! words marked. A query of a view stops the one before it (a stopped query sends nothing), and the view's close or
//! its connection's end stops it too. The rows do not depend on the display class.
//!
//! The names are listed once per root and kept ([`Lists`], at most [`LISTS_MAX`] roots). A root whose Hrafn project
//! is open is listed again when its file watcher reports a change; any other root is listed again for each new view
//! (each time Quick Open opens), and the keys typed in that view rank the list it listed.

use super::{Key, Views, lock};
use crate::dispatch::Caller;
use crate::front::Front;
use drgnx_rows::{Row, RowBuilder};
use hrafn::WatchEvent;
use hrafn::grep::Ignore;
use hrafn::rank::{NameList, Ranked, names};
use runstav::methods::search::{FilesParams, FilesStarted, GrepIgnore};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};

/// Rows a query sends when it does not say.
pub const DEFAULT_N: u32 = 100;
/// The most rows a query may ask for.
pub const MAX_N: u32 = 1000;
/// Roots whose names are kept; the one used longest ago goes first.
pub const LISTS_MAX: usize = 8;
/// The face of a query's words in a row.
const MATCH_FACE: &str = "drgnx-quick-open-match";

/// The rule a listing follows: the call's when it says, else the setting `drgnx-search-ignore-rules` (SETTING, its
/// value); `index` when neither says `real`.
pub fn ignore_of(asked: Option<GrepIgnore>, setting: Option<&Value>) -> Ignore {
    match asked {
        Some(GrepIgnore::Real) => Ignore::Real,
        Some(GrepIgnore::Index) => Ignore::Index,
        None if setting.and_then(Value::as_str) == Some("real") => Ignore::Real,
        None => Ignore::Index,
    }
}

/// The setting's rule for a call that does not say (`search/files`, `search/run`).
pub fn ignore_for(f: &Front, asked: Option<GrepIgnore>) -> Ignore {
    let setting = f
        .settings
        .effective("drgnx-search-ignore-rules", None)
        .map(|(v, _)| v);
    ignore_of(asked, setting.as_ref())
}

/// A root's listing as the cache keeps it: by root, rule and exclude globs.
pub type ListKey = (PathBuf, bool, Vec<String>);

struct Listed {
    list: Arc<NameList>,
    /// The views that ranked this listing.
    views: BTreeSet<(u64, String)>,
    /// The root's Hrafn project's watcher, when the project was open at the listing: any event makes it stale.
    tap: Option<Receiver<WatchEvent>>,
    used: u64,
}

/// The names of the roots queried lately.
#[derive(Default)]
pub struct Lists {
    lists: Mutex<BTreeMap<ListKey, Listed>>,
    clock: AtomicU64,
}

impl Lists {
    /// KEY's names for VIEW: the kept listing when it is still good (a watched root with no event since, or a view
    /// that ranked it already), else LIST's, kept with TAP (LIST runs without the lock).
    pub fn get(
        &self,
        key: &ListKey,
        view: (u64, String),
        list: impl FnOnce() -> std::io::Result<Vec<String>>,
        tap: impl FnOnce() -> Option<Receiver<WatchEvent>>,
    ) -> std::io::Result<Arc<NameList>> {
        let now = self.clock.fetch_add(1, Ordering::Relaxed);
        {
            let mut lists = lock(&self.lists);
            if let Some(l) = lists.get_mut(key) {
                let changed = l
                    .tap
                    .as_ref()
                    .is_some_and(|t| std::iter::from_fn(|| t.try_recv().ok()).count() > 0);
                let good = !changed && (l.tap.is_some() || l.views.contains(&view));
                if good {
                    l.views.insert(view);
                    l.used = now;
                    return Ok(l.list.clone());
                }
            }
        }
        // the tap first: an event while the list is read makes it stale at once
        let tap = tap();
        let list = Arc::new(NameList::new(list()?));
        let mut lists = lock(&self.lists);
        lists.insert(
            key.clone(),
            Listed {
                list: list.clone(),
                views: BTreeSet::from([view]),
                tap,
                used: now,
            },
        );
        while lists.len() > LISTS_MAX {
            let Some(old) = lists
                .iter()
                .min_by_key(|(_, l)| l.used)
                .map(|(k, _)| k.clone())
            else {
                break;
            };
            lists.remove(&old);
        }
        Ok(list)
    }
}

/// One view's query: its number, its cancel flag, the rows it sent.
struct Run {
    id: u64,
    cancel: Arc<AtomicBool>,
    rows: Option<Vec<Row>>,
}

/// The queries, one per (connection, view).
#[derive(Default)]
pub(super) struct Files {
    runs: Mutex<BTreeMap<(u64, String), Run>>,
    next: AtomicU64,
    pub(super) lists: Lists,
}

impl Files {
    /// Start VIEW's query (the one before is stopped): its number and cancel flag. The rows sent so far stay.
    fn start(&self, conn: u64, view: &str) -> (u64, Arc<AtomicBool>) {
        let id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        let cancel = Arc::new(AtomicBool::new(false));
        let mut runs = lock(&self.runs);
        let rows = match runs.remove(&(conn, view.to_owned())) {
            Some(old) => {
                old.cancel.store(true, Ordering::Relaxed);
                old.rows
            }
            None => None,
        };
        runs.insert(
            (conn, view.to_owned()),
            Run {
                id,
                cancel: cancel.clone(),
                rows,
            },
        );
        (id, cancel)
    }

    /// Stop VIEW's query.
    pub(super) fn stop(&self, conn: u64, view: &str) {
        if let Some(r) = lock(&self.runs).remove(&(conn, view.to_owned())) {
            r.cancel.store(true, Ordering::Relaxed);
        }
    }

    /// Stop every query of CONN.
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.runs).retain(|(c, _), r| {
            if *c == conn {
                r.cancel.store(true, Ordering::Relaxed);
            }
            *c != conn
        });
    }

    /// Keep ROWS as VIEW's when its query is still query ID, and run THEN with them; none when a newer query or a
    /// close came first.
    fn finish<R>(
        &self,
        conn: u64,
        view: &str,
        id: u64,
        rows: Vec<Row>,
        then: impl FnOnce(&[Row]) -> R,
    ) -> Option<R> {
        let mut runs = lock(&self.runs);
        let run = runs.get_mut(&(conn, view.to_owned()))?;
        if run.id != id {
            return None;
        }
        let r = then(&rows);
        run.rows = Some(rows);
        Some(r)
    }

    /// VIEW's rows, when a query sent some.
    fn rows(&self, conn: u64, view: &str) -> Option<Vec<Row>> {
        lock(&self.runs).get(&(conn, view.to_owned()))?.rows.clone()
    }
}

/// R's row: the path, the query's words marked.
pub fn row(r: &Ranked) -> Row {
    let mut b = RowBuilder::new(r.path.clone());
    b.push(&r.path, None);
    for &(from, to) in &r.runs {
        b.face(from as u32, to as u32, MATCH_FACE);
    }
    b.finish()
}

impl Views {
    /// The rows of VIEW's query for a class that just got its env; false when VIEW has no query.
    pub(super) fn files_build(&self, f: &Front, key: &Key) -> bool {
        let Some(rows) = self.files.rows(key.0, &key.1) else {
            return false;
        };
        if let Some(p) = lock(&self.store).publish(key, rows, &[]) {
            f.send_to(key.0, "view-patch", json!(p));
        }
        true
    }

    /// The thread's hand-over of query ID's rows (dropped when VIEW's query is not query ID any more).
    fn files_rows(&self, f: &Front, conn: u64, view: &str, id: u64, rows: Vec<Row>) {
        self.files.finish(conn, view, id, rows, |rows| {
            let mut store = lock(&self.store);
            for class in store.classes(conn, view) {
                let key = (conn, view.to_owned(), class);
                if let Some(p) = store.publish(&key, rows.to_vec(), &[]) {
                    f.send_to(conn, "view-patch", json!(p));
                }
            }
        });
    }
}

fn invalid(path: &str, message: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

/// The exclude globs of ROOT: `.drgnx/search.eld`'s and the setting `drgnx-search-exclude`'s.
fn excludes(f: &Front, root: &std::path::Path) -> Vec<String> {
    let mut globs = crate::search::methods::config_file(root)
        .map(|c| c.exclude)
        .unwrap_or_default();
    let setting: Vec<String> = f
        .settings
        .effective("drgnx-search-exclude", None)
        .and_then(|(v, _)| serde_json::from_value(v).ok())
        .unwrap_or_default();
    for g in setting {
        if !globs.contains(&g) {
            globs.push(g);
        }
    }
    globs
}

/// The watcher of ROOT's Hrafn project, when the hub has it open.
fn tap_of(f: &Front, root: &std::path::Path) -> Option<Receiver<WatchEvent>> {
    let (_, id) = crate::search::project::project_id(root).ok()?;
    Some(f.search.opened(&id)?.tap())
}

/// `search/files`: stop VIEW's query and rank ROOT's names on a thread of its own; the rows go to every class of VIEW.
pub fn start(f: &Front, c: &Caller, p: FilesParams) -> Result<FilesStarted, Error> {
    let views = &f.core.views;
    if p.view.is_empty() || p.view.len() > runstav::methods::view::VIEW_MAX {
        return Err(invalid("view", "a view id of 1 to 64 bytes"));
    }
    let n = p.n.unwrap_or(DEFAULT_N);
    if !(1..=MAX_N).contains(&n) {
        return Err(invalid("n", "1 to 1000"));
    }
    let root = PathBuf::from(p.root.as_str());
    if !root.is_dir() {
        return Err(invalid("root", "an existing folder"));
    }
    let ignore = ignore_for(f, p.ignore);
    let (conn, view, query) = (c.conn_id, p.view, p.query);
    let (id, cancel) = views.files.start(conn, &view);
    let Some(front) = views.front.get().cloned() else {
        return Err(invalid("view", "the hub is starting"));
    };
    std::thread::Builder::new()
        .name("files".into())
        .spawn(move || {
            let Some(f) = front.upgrade() else { return };
            let exclude = excludes(&f, &root);
            let key: ListKey = (root.clone(), ignore == Ignore::Real, exclude.clone());
            let list = f.core.views.files.lists.get(
                &key,
                (conn, view.clone()),
                || names(&root, ignore, &exclude),
                || tap_of(&f, &root),
            );
            let list = match list {
                Ok(l) => l,
                Err(e) => {
                    tracing::warn!("search/files: {}: {e}", root.display());
                    return;
                }
            };
            let Some(top) = list.top(&query, n as usize, &cancel) else {
                return;
            };
            let rows = top.iter().map(row).collect();
            f.core.views.files_rows(&f, conn, &view, id, rows);
        })
        .map_err(|e| invalid("view", &e.to_string()))?;
    Ok(FilesStarted { query: id })
}

#[cfg(test)]
mod tests;
