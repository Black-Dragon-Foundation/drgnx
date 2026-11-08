//! The Search view's rows: `search/grep` runs the text search (hrafn's `grep`) and sends its matches to the view as
//! rows, a reset when the search starts and each file's header and matches as that file's lines are complete.
//! `search/grep-replace` changes the replacement the rows preview, patching the rows without a new search. A search
//! of a view stops the one before it (a stopped search sends nothing more), and the view's close or its connection's
//! end stops it too. The rows do not depend on the display class: every class of the view gets the same rows.
//!
//! The view's model (`view-model`, before the rows that name it) is a `tree`: a node per file (`f:FILE`, open) with
//! its matches as children (`m:FILE:LINE:COL`), the rows' keys and their `drgnx-work-id`; a match's fields are what
//! Replace writes from (file, line, col, end, text).

use super::model::Doc;
use super::{Key, Store, Views, lock};
use crate::dispatch::Caller;
use crate::front::Front;
use drgnx_rows::{Op, Patch, Row, RowBuilder};
use hrafn::grep::{self, Match, Query};
use runstav::methods::search::{
    GrepDone, GrepLookParams, GrepParams, GrepReplaceParams, GrepStarted,
};
use runstav::methods::view::ViewModel;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// The rows a search sends a view: the first this many, and as many again each time the editor asks (the panel's shape,
/// `agents/panel/look`); the model holds every match.
pub(super) const WINDOW: usize = 200;

/// A row asked for with `upto` comes with this many rows after it.
pub(super) const MARGIN: usize = 100;

/// A preview keeps this much of the text before a match, and cuts longer text to its tail after an ellipsis.
const BEFORE_KEPT: usize = 16;

/// One view's search: what it asked, what it found (files in the order their lines were complete), the replacement
/// the rows preview.
pub(super) struct Run {
    id: u64,
    query: Query,
    replace: String,
    files: Vec<(String, Vec<Match>)>,
    /// The rows the views may have: the first this many of the rows of `files` (see [`WINDOW`]).
    limit: usize,
    /// The rows sent so far: the first `sent` rows of `files`.
    sent: usize,
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
            limit: WINDOW,
            sent: 0,
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
    let mut b = RowBuilder::new(file_id(file));
    b.push("[x]", None)
        .prop(0, 3, "drgnx-replace-box", json!(file));
    b.push(" ", None).push(&name, None);
    if !dir.is_empty() {
        b.push(&format!("  {dir}/"), Some("drgnx-replace-dim"));
    }
    let end = b.pos();
    b.prop(0, end, "drgnx-replace-file", json!(file));
    b.prop(0, end, "drgnx-work-id", json!(file_id(file)));
    b.finish()
}

/// FILE's node id (and its header row's key).
fn file_id(file: &str) -> String {
    format!("f:{file}")
}

/// M's node id (and its row's key).
fn match_id(m: &Match) -> String {
    format!("m:{}:{}:{}", m.file, m.line, m.col)
}

/// The entries (files and matches) a search's model holds; past them its list `order` is a window of the first ones
/// (Sjá takes no longer list unwindowed).
const MODEL_WINDOW: usize = 20_000;

/// The search's model: a `tree` of FILES in the rows' order, each open, with its matches as children.
fn grep_doc(files: &[(String, Vec<Match>)]) -> Doc {
    grep_doc_in(files, MODEL_WINDOW)
}

/// [`grep_doc`] holding at most WINDOW entries.
fn grep_doc_in(files: &[(String, Vec<Match>)], window: usize) -> Doc {
    let mut d = Doc {
        descriptor: json!({
            "scheme": "tree",
            "chain_kinds": [],
            "match_fields": ["label"],
            "lists": ["order"],
            "classes": ["selected", "match", "dim"],
            "flags": ["expanded"],
            "forms": [],
            "start": "order",
        }),
        ..Doc::default()
    };
    let total: usize = files.iter().map(|(_, ms)| 1 + ms.len()).sum();
    let mut order = Vec::new();
    for (file, ms) in files {
        if order.len() >= window {
            break;
        }
        let fid = file_id(file);
        let name = Path::new(file)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        d.nodes.insert(
            fid.clone(),
            json!({"id": fid, "kind": "file", "flags": 1,
                   "fields": [["label", name], ["path", file]]}),
        );
        order.push(fid.clone());
        for m in ms.iter().take(window - order.len()) {
            let id = match_id(m);
            d.nodes.insert(
                id.clone(),
                json!({"id": id, "kind": "match", "flags": 0, "parent": fid,
                       "fields": [["label", format!("{}{}{}", m.before.trim_start(), m.text, m.after)],
                                  ["file", m.file], ["line", m.line], ["col", m.col], ["end", m.end],
                                  ["text", m.text]]}),
            );
            order.push(id);
        }
    }
    if total > order.len() {
        d.windows.insert("order".into(), (total, 0));
    }
    d.lists.insert("order".into(), order);
    d
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
    let mut b = RowBuilder::new(match_id(m));
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
    b.prop(0, end, "drgnx-work-id", json!(match_id(m)));
    b.finish()
}

/// FILE's rows: its header and one row per match.
fn file_rows(run: &Run, file: &str, ms: &[Match]) -> Vec<Row> {
    let mut rows = vec![header(&run.query.root, file)];
    rows.extend(ms.iter().map(|m| match_row(&run.query, &run.replace, m)));
    rows
}

/// The first LIMIT rows of the search's rows (a file's header and its matches, files in the order they were complete).
fn rows_upto(run: &Run, limit: usize) -> Vec<Row> {
    let mut rows = Vec::new();
    'files: for (file, ms) in &run.files {
        if rows.len() >= limit {
            break;
        }
        rows.push(header(&run.query.root, file));
        for m in ms {
            if rows.len() >= limit {
                break 'files;
            }
            rows.push(match_row(&run.query, &run.replace, m));
        }
    }
    rows
}

/// The rows the views have: the window.  Sets `sent` to their number.
fn window_rows(run: &mut Run) -> Vec<Row> {
    let rows = rows_upto(run, run.limit);
    run.sent = rows.len();
    rows
}

/// The position among the search's rows of the row KEY (a file's header or a match), if it is there yet.
fn row_index(run: &Run, key: &str) -> Option<usize> {
    let mut at = 0;
    for (file, ms) in &run.files {
        if key == file_id(file) {
            return Some(at);
        }
        if key.starts_with(&format!("m:{file}:")) {
            return ms
                .iter()
                .position(|m| match_id(m) == key)
                .map(|i| at + 1 + i);
        }
        at += 1 + ms.len();
    }
    None
}

impl Store {
    /// A new search (or a new subscription of a view): the rows are none and the next patch a reset.
    pub(super) fn restart(&mut self, key: &Key) {
        if let Some(p) = self.pairs.get_mut(key) {
            p.reset_due = true;
            p.rows.clear();
        }
    }

    /// ROWS after the last row, one insert; `None` when the pair has no env or its next patch is a reset.
    fn append(&mut self, key: &Key, rows: Vec<Row>) -> Option<Patch> {
        let model = self.model_version(key);
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
            model,
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

/// A file's matches: the model with them (none when nothing changed), then the rows after the ones sent, an insert (a
/// reset for a class whose env just changed), which name its version.
fn batch_patches(
    store: &mut Store,
    conn: u64,
    view: &str,
    run: &mut Run,
    file: String,
    ms: Vec<Match>,
) -> (Option<ViewModel>, Vec<Patch>) {
    let mut rows = file_rows(run, &file, &ms);
    run.files.push((file, ms));
    // only what the window still has room for
    rows.truncate(run.limit.saturating_sub(run.sent));
    // a send carries this batch's nodes and ids alone (the list grew at its end: a splice)
    let model = store.publish_model(conn, view, grep_doc(&run.files));
    if rows.is_empty() {
        return (model, Vec::new());
    }
    run.sent += rows.len();
    let all = rows_upto(run, run.limit);
    let patches = keys(store, conn, view)
        .iter()
        .filter_map(|k| match store.append(k, rows.clone()) {
            Some(p) => Some(p),
            None => store.publish(k, all.clone(), &[]),
        })
        .collect();
    (model, patches)
}

/// What the editor asks of the window (`search/grep-look`).
pub(super) enum Look<'a> {
    /// One window more.
    More,
    /// The row with this key, and a margin of rows after it.
    Upto(&'a str),
}

/// The window grown as LOOK asks: the rows it gains after the last row sent, an insert for each class.
fn look_patches(store: &mut Store, conn: u64, view: &str, run: &mut Run, look: Look) -> Vec<Patch> {
    let want = match look {
        Look::More => run.limit + WINDOW,
        Look::Upto(key) => match row_index(run, key) {
            Some(i) => i + 1 + MARGIN,
            None => return Vec::new(),
        },
    };
    if want <= run.limit {
        return Vec::new();
    }
    run.limit = want;
    let all = rows_upto(run, want);
    if all.len() <= run.sent {
        return Vec::new();
    }
    let new = all[run.sent..].to_vec();
    run.sent = all.len();
    keys(store, conn, view)
        .iter()
        .filter_map(|k| match store.append(k, new.clone()) {
            Some(p) => Some(p),
            None => store.publish(k, all.clone(), &[]),
        })
        .collect()
}

/// The rows as they are now, for the classes whose rows differ (replace text changed, an env arrived).
fn rebuild_patches(store: &mut Store, conn: u64, view: &str, run: &mut Run) -> Vec<Patch> {
    let rows = window_rows(run);
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
                self.publish_model(f, key.0, &key.1, grep_doc(&run.files));
                let rows = window_rows(run);
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
                let (model, patches) =
                    batch_patches(&mut lock(&self.store), conn, view, run, file, ms);
                if let Some(m) = model {
                    f.send_to(conn, "view-model", json!(m));
                }
                for p in patches {
                    f.send_to(conn, "view-patch", json!(p));
                }
            })
            .is_some()
    }

    fn grep_done(&self, f: &Front, conn: u64, view: &str, id: u64, error: Option<String>) {
        self.greps.with(conn, view, id, |run| {
            // every batch sent its model, so this sends nothing unless a batch's was lost
            self.publish_model(f, conn, view, grep_doc(&run.files));
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
        ignore: super::files::ignore_for(f, p.ignore),
    };
    if !query.root.is_dir() {
        return Err(invalid("root", "an existing folder"));
    }
    let (conn, view) = (c.conn_id, p.view);
    let (id, cancel) = views
        .greps
        .start(conn, &view, query.clone(), p.replace.unwrap_or_default());
    // a new search's model: no files yet
    views.publish_model(f, conn, &view, grep_doc(&[]));
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

/// `search/grep-look`: VIEW's rows go on, as P asks (the editor scrolled to the end of them, or went to a match
/// beyond them).
pub fn look(f: &Front, c: &Caller, p: GrepLookParams) -> Result<bool, Error> {
    let views = &f.core.views;
    let ask = match (&p.upto, p.more) {
        (Some(key), _) => Look::Upto(key),
        (None, Some(true)) => Look::More,
        _ => return Err(invalid("more", "more, or upto a row's key")),
    };
    Ok(views
        .greps
        .current(c.conn_id, &p.view, |run| {
            for patch in look_patches(&mut lock(&views.store), c.conn_id, &p.view, run, ask) {
                f.send_to(c.conn_id, "view-patch", json!(patch));
            }
        })
        .is_some())
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
