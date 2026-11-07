//! The Search view's rows: `search/grep` runs the text search (hrafn's `grep`) and sends its matches to the view as
//! rows, a reset when the search starts and each file's header and matches as that file's lines are complete.
//! `search/grep-replace` changes the replacement the rows preview, patching the rows without a new search. A search
//! of a view stops the one before it (a stopped search sends nothing more), and the view's close or its connection's
//! end stops it too. The rows do not depend on the display class: every class of the view gets the same rows.

use super::{Key, Store, Views, lock};
use crate::dispatch::Caller;
use crate::front::Front;
use drgnx_rows::{Op, Patch, Row, RowBuilder};
use hrafn::grep::{self, Ignore, Match, Query};
use runstav::methods::search::{GrepDone, GrepIgnore, GrepParams, GrepReplaceParams, GrepStarted};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// A preview keeps this much of the text before a match, and cuts longer text to its tail after an ellipsis.
const BEFORE_KEPT: usize = 16;

/// One view's search: what it asked, what it found (files in the order their lines were complete), the replacement
/// the rows preview.
pub(super) struct Run {
    id: u64,
    query: Query,
    replace: String,
    files: Vec<(String, Vec<Match>)>,
    cancel: Arc<AtomicBool>,
}

/// The searches, one per (connection, view).
#[derive(Default)]
pub(super) struct Greps {
    runs: Mutex<BTreeMap<(u64, String), Run>>,
    next: AtomicU64,
}

impl Greps {
    /// Start VIEW's search for QUERY (the one before is stopped): its number and cancel flag.
    fn start(
        &self,
        conn: u64,
        view: &str,
        query: Query,
        replace: String,
    ) -> (u64, Arc<AtomicBool>) {
        let id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        let cancel = Arc::new(AtomicBool::new(false));
        let run = Run {
            id,
            query,
            replace,
            files: Vec::new(),
            cancel: cancel.clone(),
        };
        if let Some(old) = lock(&self.runs).insert((conn, view.to_owned()), run) {
            old.cancel.store(true, Ordering::Relaxed);
        }
        (id, cancel)
    }

    /// Stop VIEW's search.
    pub(super) fn stop(&self, conn: u64, view: &str) {
        if let Some(r) = lock(&self.runs).remove(&(conn, view.to_owned())) {
            r.cancel.store(true, Ordering::Relaxed);
        }
    }

    /// Stop every search of CONN.
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.runs).retain(|(c, _), r| {
            if *c == conn {
                r.cancel.store(true, Ordering::Relaxed);
            }
            *c != conn
        });
    }

    /// Run THEN on VIEW's search when it is still search ID (a newer search, a close: none).
    fn with<R>(
        &self,
        conn: u64,
        view: &str,
        id: u64,
        then: impl FnOnce(&mut Run) -> R,
    ) -> Option<R> {
        let mut runs = lock(&self.runs);
        let run = runs.get_mut(&(conn, view.to_owned()))?;
        (run.id == id).then(|| then(run))
    }

    /// Run THEN on VIEW's search, whichever number it has.
    fn current<R>(&self, conn: u64, view: &str, then: impl FnOnce(&mut Run) -> R) -> Option<R> {
        Some(then(lock(&self.runs).get_mut(&(conn, view.to_owned()))?))
    }
}

fn flat(s: &str) -> String {
    s.replace('\n', "⏎")
}

fn match_json(m: &Match) -> Value {
    json!({"file": m.file, "line": m.line, "col": m.col, "end": m.end, "text": m.text,
           "before": m.before, "after": m.after})
}

/// FILE's header: its tick box, its name, the folder (relative to the root) after it.
fn header(root: &Path, file: &str) -> Row {
    let path = Path::new(file);
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let dir = path
        .parent()
        .and_then(|d| d.strip_prefix(root).ok())
        .map(|d| d.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut b = RowBuilder::new(format!("f:{file}"));
    b.push("[x]", None)
        .prop(0, 3, "drgnx-replace-box", json!(file));
    b.push(" ", None).push(&name, None);
    if !dir.is_empty() {
        b.push(&format!("  {dir}/"), Some("drgnx-replace-dim"));
    }
    let end = b.pos();
    b.prop(0, end, "drgnx-replace-file", json!(file));
    b.finish()
}

/// M's row: a tick box, the text around the match (the match struck out and the replacement beside it when REPLACE
/// is not empty and still fits the match).
fn match_row(q: &Query, replace: &str, m: &Match) -> Row {
    let before = m.before.trim_start();
    let kept: Vec<char> = before.chars().collect();
    let before = if kept.len() > BEFORE_KEPT {
        format!(
            "…{}",
            kept[kept.len() - (BEFORE_KEPT - 1)..]
                .iter()
                .collect::<String>()
        )
    } else {
        before.to_owned()
    };
    let new = if replace.is_empty() {
        None
    } else {
        grep::new_text(q, &m.text, replace)
    };
    let mut b = RowBuilder::new(format!("m:{}:{}:{}", m.file, m.line, m.col));
    b.push("  ", None);
    let at = b.pos();
    b.push("[x]", None)
        .prop(at, at + 3, "drgnx-replace-box", match_json(m));
    b.push(" ", None).push(&flat(&before), None);
    match new {
        Some(n) => {
            b.push(&flat(&m.text), Some("drgnx-replace-old"));
            b.push(&flat(&n), Some("drgnx-replace-new"));
        }
        None => {
            b.push(&flat(&m.text), Some("drgnx-replace-match"));
        }
    }
    b.push(&flat(&m.after), None);
    let end = b.pos();
    b.prop(0, end, "drgnx-replace-match", match_json(m));
    b.finish()
}

/// FILE's rows: its header and one row per match.
fn file_rows(run: &Run, file: &str, ms: &[Match]) -> Vec<Row> {
    let mut rows = vec![header(&run.query.root, file)];
    rows.extend(ms.iter().map(|m| match_row(&run.query, &run.replace, m)));
    rows
}

fn all_rows(run: &Run) -> Vec<Row> {
    run.files
        .iter()
        .flat_map(|(f, ms)| file_rows(run, f, ms))
        .collect()
}

impl Store {
    /// A new search: the rows are none and the next patch a reset.
    fn restart(&mut self, key: &Key) {
        if let Some(p) = self.pairs.get_mut(key) {
            p.reset_due = true;
            p.rows.clear();
        }
    }

    /// ROWS after the last row, one insert; `None` when the pair has no env or its next patch is a reset.
    fn append(&mut self, key: &Key, rows: Vec<Row>) -> Option<Patch> {
        let p = self.pairs.get_mut(key)?;
        if p.reset_due || rows.is_empty() {
            return None;
        }
        let after = p.rows.last().map(|r| r.key.clone());
        p.rows.extend(rows.iter().cloned());
        Some(Self::send(
            self.hub,
            key,
            p,
            vec![Op::Insert { after, rows }],
            &[],
        ))
    }
}

fn keys(store: &Store, conn: u64, view: &str) -> Vec<Key> {
    store
        .classes(conn, view)
        .into_iter()
        .map(|c| (conn, view.to_owned(), c))
        .collect()
}

/// Every class of VIEW starts afresh: a reset of no rows.
fn start_patches(store: &mut Store, conn: u64, view: &str) -> Vec<Patch> {
    keys(store, conn, view)
        .iter()
        .filter_map(|k| {
            store.restart(k);
            store.publish(k, Vec::new(), &[])
        })
        .collect()
}

/// A file's rows after the ones sent: an insert (a reset for a class whose env just changed).
fn batch_patches(
    store: &mut Store,
    conn: u64,
    view: &str,
    run: &mut Run,
    file: String,
    ms: Vec<Match>,
) -> Vec<Patch> {
    let rows = file_rows(run, &file, &ms);
    run.files.push((file, ms));
    keys(store, conn, view)
        .iter()
        .filter_map(|k| match store.append(k, rows.clone()) {
            Some(p) => Some(p),
            None => store.publish(k, all_rows(run), &[]),
        })
        .collect()
}

/// The rows as they are now, for the classes whose rows differ (replace text changed, an env arrived).
fn rebuild_patches(store: &mut Store, conn: u64, view: &str, run: &Run) -> Vec<Patch> {
    let rows = all_rows(run);
    keys(store, conn, view)
        .iter()
        .filter_map(|k| store.publish(k, rows.clone(), &[]))
        .collect()
}

impl Views {
    /// The rows of VIEW's search for a class that just got its env; false when VIEW has no search.
    pub(super) fn grep_build(&self, f: &Front, key: &Key) -> bool {
        self.greps
            .current(key.0, &key.1, |run| {
                let rows = all_rows(run);
                if let Some(p) = lock(&self.store).publish(key, rows, &[]) {
                    f.send_to(key.0, "view-patch", json!(p));
                }
            })
            .is_some()
    }

    /// The thread's hand-over of one file's matches (dropped when VIEW's search is not search ID any more).
    fn grep_batch(
        &self,
        f: &Front,
        conn: u64,
        view: &str,
        id: u64,
        file: String,
        ms: Vec<Match>,
    ) -> bool {
        self.greps
            .with(conn, view, id, |run| {
                for p in batch_patches(&mut lock(&self.store), conn, view, run, file, ms) {
                    f.send_to(conn, "view-patch", json!(p));
                }
            })
            .is_some()
    }

    fn grep_done(&self, f: &Front, conn: u64, view: &str, id: u64, error: Option<String>) {
        self.greps.with(conn, view, id, |run| {
            let done = GrepDone {
                view: view.to_owned(),
                query: id,
                files: run.files.len() as u64,
                matches: run.files.iter().map(|(_, ms)| ms.len() as u64).sum(),
                error,
            };
            f.send_to(conn, "search-grep-done", json!(done));
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

/// `search/grep`: stop VIEW's search, send its classes a reset, and search on a thread of its own.
pub fn start(f: &Front, c: &Caller, p: GrepParams) -> Result<GrepStarted, Error> {
    let views = &f.core.views;
    if p.view.is_empty() || p.view.len() > runstav::methods::view::VIEW_MAX {
        return Err(invalid("view", "a view id of 1 to 64 bytes"));
    }
    let root = std::path::PathBuf::from(p.root.as_str());
    let query = Query {
        root,
        file: p.file.as_ref().map(|f| f.as_str().into()),
        text: p.text,
        case: p.case.unwrap_or(false),
        word: p.word.unwrap_or(false),
        regexp: p.regexp.unwrap_or(false),
        include: p.include.unwrap_or_default(),
        exclude: p.exclude.unwrap_or_default(),
        ignore: match p.ignore {
            Some(GrepIgnore::Real) => Ignore::Real,
            _ => Ignore::Index,
        },
    };
    if !query.root.is_dir() {
        return Err(invalid("root", "an existing folder"));
    }
    let (conn, view) = (c.conn_id, p.view);
    let (id, cancel) = views
        .greps
        .start(conn, &view, query.clone(), p.replace.unwrap_or_default());
    for patch in start_patches(&mut lock(&views.store), conn, &view) {
        f.send_to(conn, "view-patch", json!(patch));
    }
    let Some(front) = views.front.get().cloned() else {
        return Err(invalid("view", "the hub is starting"));
    };
    std::thread::Builder::new()
        .name("grep".into())
        .spawn(move || {
            let on_file = |ms: Vec<Match>| {
                let file = ms[0].file.clone();
                let Some(f) = front.upgrade() else {
                    cancel.store(true, Ordering::Relaxed);
                    return;
                };
                if !f.core.views.grep_batch(&f, conn, &view, id, file, ms) {
                    cancel.store(true, Ordering::Relaxed);
                }
            };
            let result = grep::run(&query, &cancel, on_file);
            if let Some(f) = front.upgrade() {
                f.core.views.grep_done(&f, conn, &view, id, result.err());
            }
        })
        .map_err(|e| invalid("view", &e.to_string()))?;
    Ok(GrepStarted { query: id })
}

/// `search/grep-replace`: VIEW's rows preview P's replacement from now on.
pub fn replace(f: &Front, c: &Caller, p: GrepReplaceParams) -> Result<bool, Error> {
    let views = &f.core.views;
    Ok(views
        .greps
        .current(c.conn_id, &p.view, |run| {
            run.replace = p.replace.clone();
            for patch in rebuild_patches(&mut lock(&views.store), c.conn_id, &p.view, run) {
                f.send_to(c.conn_id, "view-patch", json!(patch));
            }
        })
        .is_some())
}

#[cfg(test)]
mod tests;
