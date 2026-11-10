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
    GrepDone, GrepLookParams, GrepParams, GrepReplaceParams, GrepSkippedParams, GrepStarted,
};
use runstav::methods::view::ViewModel;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The rows a search sends a view: the first this many, and as many again each time the editor asks (the panel's shape,
/// `agents/panel/look`); the model holds every match.
pub(super) const WINDOW: usize = 200;

/// A row asked for with `upto` comes with this many rows after it (and, past [`FAR`], before it).
pub(super) const MARGIN: usize = 100;

/// A row `upto` asks for further than this past the rows sent comes in a block of rows around it, after a gap row,
/// not with every row before it (SJA-ROWS-FAR-1: 19,000 rows at once were over the hub's 16 MiB per client).
pub(super) const FAR: usize = 2 * WINDOW;

/// The gap row's key: the rows between the first ones sent and a far block (`fill` sends them).
const GAP: &str = "gap";

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
    /// The rows of `files` sent after a gap row (a jump past [`FAR`]), when they do not meet the first `sent`.
    block: Option<std::ops::Range<usize>>,
    /// Match id → why Replace All skipped it (`search/grep-skipped`): its row shows it.
    reasons: BTreeMap<String, String>,
    /// The entries (files and matches) the model last sent held. Up to [`MODEL_WINDOW`] the batches' nodes and ids
    /// are appended, at most one send per `model_every`; past it the model grows when the search has doubled it, when
    /// rows go out, and at the end.
    model_sent: usize,
    /// The least time between two model sends ([`MODEL_EVERY`]; tests set it).
    model_every: Duration,
    /// When the model was last sent.
    model_at: Option<Instant>,
    /// The batches' nodes and ids not sent yet, in order.
    waiting: (Vec<(String, Value)>, Vec<String>),
    cancel: Arc<AtomicBool>,
}

/// A search sends its model at most this often: the editor applies a model no row names one throttle
/// (`drgnx-view-delay`, 0.1 s) after it comes, and every line it reads costs it a redisplay pass.
const MODEL_EVERY: Duration = Duration::from_millis(100);

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
            block: None,
            reasons: BTreeMap::new(),
            model_sent: 0,
            model_every: MODEL_EVERY,
            model_at: None,
            waiting: (Vec::new(), Vec::new()),
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

/// The entries (files and matches) of FILES.
fn entries_of(files: &[(String, Vec<Match>)]) -> usize {
    files.iter().map(|(_, ms)| 1 + ms.len()).sum()
}

/// FILE's node in the model: its id and wire object.
fn file_node(file: &str) -> (String, Value) {
    let fid = file_id(file);
    let name = Path::new(file)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let node = json!({"id": fid, "kind": "file", "flags": 1,
                      "fields": [["label", name], ["path", file]]});
    (fid, node)
}

/// M's node in the model, a child of the file node FID: its id and wire object.
fn match_node(fid: &str, m: &Match) -> (String, Value) {
    let id = match_id(m);
    let node = json!({"id": id, "kind": "match", "flags": 0, "parent": fid,
                      "fields": [["label", format!("{}{}{}", m.before.trim_start(), m.text, m.after)],
                                 ["file", m.file], ["line", m.line], ["col", m.col], ["end", m.end],
                                 ["text", m.text]]});
    (id, node)
}

/// FILE's batch MS as the model's nodes and the ids it adds to `order`.
fn batch_nodes(file: &str, ms: &[Match]) -> (Vec<(String, Value)>, Vec<String>) {
    let (fid, node) = file_node(file);
    let mut nodes = vec![(fid.clone(), node)];
    nodes.extend(ms.iter().map(|m| match_node(&fid, m)));
    let ids = nodes.iter().map(|(id, _)| id.clone()).collect();
    (nodes, ids)
}

/// The search's model: a `tree` of FILES in the rows' order, each open, with its matches as children; past
/// [`MODEL_WINDOW`] entries `order` is a window of them, from FROM (`view/window`; none: the first).
fn grep_doc(files: &[(String, Vec<Match>)], from: Option<usize>) -> Doc {
    grep_doc_in(files, MODEL_WINDOW, from)
}

/// The entries of a search's model window: every node id it holds (`held`: the parent of a window that starts inside a
/// file first, outside `order`, then `order`'s ids), where each comes from (a file, and the match or none for the
/// file's own entry), and the window: its total and first entry.
struct Window<'a> {
    total: usize,
    from: usize,
    held: Vec<String>,
    order: std::ops::Range<usize>,
    from_files: Vec<(&'a str, Option<&'a Match>)>,
}

impl Window<'_> {
    /// `held[i]`'s wire object.
    fn node(&self, i: usize) -> Value {
        match self.from_files[i] {
            (file, None) => file_node(file).1,
            (file, Some(m)) => match_node(&file_id(file), m).1,
        }
    }
}

/// FILES' window of at most WINDOW entries from entry FROM (clamped so the window is full): its ids only, no node built.
fn window_of(files: &[(String, Vec<Match>)], window: usize, from: Option<usize>) -> Window<'_> {
    let total = entries_of(files);
    let from = from.unwrap_or(0).min(total.saturating_sub(window));
    let end = from + window;
    let mut w = Window {
        total,
        from,
        held: Vec::new(),
        order: 0..0,
        from_files: Vec::new(),
    };
    let mut parent = false;
    let mut at = 0;
    for (file, ms) in files {
        if at >= end {
            break;
        }
        let n = 1 + ms.len();
        if at + n <= from {
            at += n;
            continue;
        }
        parent |= at < from;
        w.held.push(file_id(file));
        w.from_files.push((file, None));
        at += 1;
        let skip = from.saturating_sub(at);
        at += skip;
        for m in ms.iter().skip(skip).take(end.saturating_sub(at)) {
            w.held.push(match_id(m));
            w.from_files.push((file, Some(m)));
            at += 1;
        }
    }
    w.order = usize::from(parent)..w.held.len();
    w
}

/// [`grep_doc`] holding at most WINDOW entries, from entry FROM (clamped so the window is full). A window that starts
/// inside a file holds the file's node too, outside `order`: Sjá shows a match under its file.
fn grep_doc_in(files: &[(String, Vec<Match>)], window: usize, from: Option<usize>) -> Doc {
    let w = window_of(files, window, from);
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
    for (i, id) in w.held.iter().enumerate() {
        d.nodes.insert(id.clone(), w.node(i));
    }
    let order = w.held[w.order.clone()].to_vec();
    if w.total > order.len() {
        d.windows.insert("order".into(), (w.total, w.from));
    }
    d.lists.insert("order".into(), order);
    d
}

/// M's row: a tick box, the text around the match (the match struck out and the replacement beside it when REPLACE
/// is not empty and still fits the match), and WHY Replace All skipped it, if it did.
fn match_row(q: &Query, replace: &str, m: &Match, why: Option<&str>) -> Row {
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
    if let Some(why) = why {
        b.push(&format!("  — {why}"), Some("drgnx-replace-dim"));
    }
    let end = b.pos();
    b.prop(0, end, "drgnx-replace-match", match_json(m));
    b.prop(0, end, "drgnx-work-id", json!(match_id(m)));
    b.finish()
}

/// Why Replace All skipped M, if it did.
fn why<'a>(run: &'a Run, m: &Match) -> Option<&'a str> {
    if run.reasons.is_empty() {
        return None;
    }
    run.reasons.get(&match_id(m)).map(String::as_str)
}

/// M's row in RUN.
fn row_of(run: &Run, m: &Match) -> Row {
    match_row(&run.query, &run.replace, m, why(run, m))
}

/// FILE's rows: its header and one row per match.
fn file_rows(run: &Run, file: &str, ms: &[Match]) -> Vec<Row> {
    let mut rows = vec![header(&run.query.root, file)];
    rows.extend(ms.iter().map(|m| row_of(run, m)));
    rows
}

/// The search's rows AT (a file's header and its matches, files in the order they were complete); none is built
/// before it.
fn rows_in(run: &Run, at: std::ops::Range<usize>) -> Vec<Row> {
    let mut rows = Vec::new();
    let mut i = 0;
    for (file, ms) in &run.files {
        if i >= at.end {
            break;
        }
        let n = 1 + ms.len();
        if i + n <= at.start {
            i += n;
            continue;
        }
        if at.contains(&i) {
            rows.push(header(&run.query.root, file));
        }
        let skip = at.start.saturating_sub(i + 1);
        for m in ms
            .iter()
            .skip(skip)
            .take(at.end.saturating_sub(i + 1 + skip))
        {
            rows.push(row_of(run, m));
        }
        i += n;
    }
    rows
}

/// The first LIMIT rows of the search's rows.
fn rows_upto(run: &Run, limit: usize) -> Vec<Row> {
    rows_in(run, 0..limit)
}

/// The gap row: N rows between the first ones sent and the block (they come when it is in sight, `fill`).
fn gap_row(n: usize) -> Row {
    let mut b = RowBuilder::new(GAP.to_owned());
    b.push(&format!("  ⋯ {n} more"), Some("drgnx-replace-dim"));
    b.finish()
}

/// The rows the views have: the first `sent` (as many as the window has room for and the search found), then, after
/// a gap row, the block.  A block the first rows reach is theirs: the gap goes.
fn view_rows(run: &mut Run) -> Vec<Row> {
    let total = entries_of(&run.files);
    run.sent = run.limit.min(total);
    if let Some(b) = run.block.clone()
        && run.sent >= b.start
    {
        run.limit = run.limit.max(b.end);
        run.sent = run.limit.min(total);
        run.block = None;
    }
    let mut rows = rows_upto(run, run.sent);
    if let Some(b) = run.block.clone() {
        rows.push(gap_row(b.start - run.sent));
        rows.extend(rows_in(run, b));
    }
    rows
}

/// The rows the views have, as [`view_rows`] (sets `sent`).
fn window_rows(run: &mut Run) -> Vec<Row> {
    view_rows(run)
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

/// RUN's model as the editor should hold it now, when it holds less: the batches waiting appended to what it holds
/// when that is this run's model up to them (never the whole rebuilt and diffed per send), else the whole.
fn flush_model(store: &mut Store, conn: u64, view: &str, run: &mut Run) -> Option<ViewModel> {
    let entries = entries_of(&run.files);
    if run.model_sent >= entries {
        return None;
    }
    let (nodes, ids) = std::mem::take(&mut run.waiting);
    let appends =
        run.model_sent > 0 && run.model_sent + ids.len() == entries && entries <= MODEL_WINDOW;
    run.model_sent = entries;
    run.model_at = Some(Instant::now());
    appends
        .then(|| store.append_model(conn, view, nodes, "order", ids))
        .flatten()
        .or_else(|| {
            let from = store.window_from(conn, view, "order");
            store.publish_model(conn, view, grep_doc(&run.files, from))
        })
}

/// A file's matches: the model with them when it is due ([`flush_model`]; none when nothing changed or a throttle
/// window has not passed), then the rows after the ones sent, an insert (a reset for a class whose env just changed),
/// which name its version.
fn batch_patches(
    store: &mut Store,
    conn: u64,
    view: &str,
    run: &mut Run,
    file: String,
    ms: Vec<Match>,
) -> (Option<ViewModel>, Vec<Patch>) {
    let mut rows = file_rows(run, &file, &ms);
    let (nodes, ids) = batch_nodes(&file, &ms);
    run.files.push((file, ms));
    // only what the window still has room for
    rows.truncate(run.limit.saturating_sub(run.sent));
    let entries = entries_of(&run.files);
    let model = if entries <= MODEL_WINDOW {
        // the batch's nodes wait; they go when rows go out (the rows name the model they were built from), or once a
        // throttle window has passed since the last send, with the others waiting (SJA-MODEL-CADENCE-1)
        run.waiting.0.extend(nodes);
        run.waiting.1.extend(ids);
        let due = !rows.is_empty() || run.model_at.is_none_or(|t| t.elapsed() >= run.model_every);
        if due {
            flush_model(store, conn, view, run)
        } else {
            None
        }
    } else if !rows.is_empty() || entries >= 2 * run.model_sent {
        // past the model's window `order` is a window of the first entries: only its total grows, whole each time
        run.waiting = (Vec::new(), Vec::new());
        run.model_sent = entries;
        let from = store.window_from(conn, view, "order");
        store.publish_model(conn, view, grep_doc(&run.files, from))
    } else {
        None
    };
    if rows.is_empty() {
        return (model, Vec::new());
    }
    if run.block.is_some() {
        // the rows go before the gap row: the whole as it is now, a diff
        let all = view_rows(run);
        let patches = keys(store, conn, view)
            .iter()
            .filter_map(|k| store.publish(k, all.clone(), &[]))
            .collect();
        return (model, patches);
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
    /// One window more at the end of the rows (of the block, after a jump).
    More,
    /// The rows before the gap row, one window more (the gap row is in sight).
    Fill,
    /// The row with this key, and a margin of rows after it; past [`FAR`] a block around it after a gap row.
    Upto(&'a str),
}

/// The window grown as LOOK asks, sent as a diff for each class: rows inserted where they go (after the last row sent,
/// before the gap row, or around the block), the gap row's count replaced, the gap row gone once the rows meet.
fn look_patches(store: &mut Store, conn: u64, view: &str, run: &mut Run, look: Look) -> Vec<Patch> {
    match look {
        Look::More => match &mut run.block {
            Some(b) => b.end += WINDOW,
            None => run.limit += WINDOW,
        },
        Look::Fill => {
            if run.block.is_none() {
                return Vec::new();
            }
            run.limit = run.sent + WINDOW;
        }
        Look::Upto(key) => {
            let Some(i) = row_index(run, key) else {
                return Vec::new();
            };
            if i < run.limit || run.block.as_ref().is_some_and(|b| b.contains(&i)) {
                return Vec::new();
            }
            let want = i + 1 + MARGIN;
            if want <= run.sent + FAR {
                run.limit = want;
            } else {
                let start = i.saturating_sub(MARGIN);
                run.block = Some(match run.block.clone() {
                    // next to the block (Next or Previous Match walking out of it): it grows
                    Some(b) if start <= b.end && want >= b.start => {
                        b.start.min(start)..b.end.max(want)
                    }
                    _ => start..want,
                });
            }
        }
    }
    let total = entries_of(&run.files);
    if let Some(b) = &mut run.block {
        b.end = b.end.min(total);
    }
    let rows = view_rows(run);
    keys(store, conn, view)
        .iter()
        .filter_map(|k| store.publish(k, rows.clone(), &[]))
        .collect()
}

/// Replace All's leftovers (`search/grep-skipped`): RUN keeps only the matches WHY names, each showing its reason, and
/// its files; the search stops (what it lists is what Replace All left). The model then, and the rows, for each class.
fn skip_patches(
    store: &mut Store,
    conn: u64,
    view: &str,
    run: &mut Run,
    why: BTreeMap<String, String>,
) -> (Option<ViewModel>, Vec<Patch>) {
    run.cancel.store(true, Ordering::Relaxed);
    let files = std::mem::take(&mut run.files);
    run.files = files
        .into_iter()
        .filter_map(|(file, ms)| {
            let ms: Vec<Match> = ms
                .into_iter()
                .filter(|m| why.contains_key(&match_id(m)))
                .collect();
            (!ms.is_empty()).then_some((file, ms))
        })
        .collect();
    run.reasons = why;
    run.waiting = (Vec::new(), Vec::new());
    run.model_sent = entries_of(&run.files);
    run.limit = WINDOW;
    run.block = None;
    store.forget_windows(conn, view);
    let model = store.publish_model(conn, view, grep_doc(&run.files, None));
    let rows = view_rows(run);
    let patches = keys(store, conn, view)
        .iter()
        .filter_map(|k| store.publish(k, rows.clone(), &[]))
        .collect();
    (model, patches)
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
                let from = self.window_from(key.0, &key.1, "order");
                self.publish_model(f, key.0, &key.1, grep_doc(&run.files, from));
                let rows = window_rows(run);
                if let Some(p) = lock(&self.store).publish(key, rows, &[]) {
                    f.send_to(key.0, "view-patch", json!(p));
                }
            })
            .is_some()
    }

    /// `view/window` of CONN's VIEW: `order`'s window where the editor asked, sent as the move alone when the search
    /// has not grown since the last model (the nodes it adds, the ids it drops, the list), else its model again; false
    /// when VIEW has no search.
    pub(super) fn grep_window(&self, f: &Front, conn: u64, view: &str) -> bool {
        self.greps
            .current(conn, view, |run| {
                let from = self.window_from(conn, view, "order");
                // the same entries in another window: the move alone (the nodes held stay as they are)
                let w = window_of(&run.files, MODEL_WINDOW, from);
                let m = super::model::WindowMove {
                    name: "order",
                    window: (w.total, w.from),
                    held: &w.held,
                    order: w.order.clone(),
                };
                let moved = lock(&self.store).move_model(conn, view, m, |i| w.node(i));
                match moved {
                    Some(m) => {
                        f.send_to(conn, "view-model", super::Store::model_data(m));
                    }
                    None => {
                        self.publish_model(f, conn, view, grep_doc(&run.files, from));
                    }
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
                    f.send_to(conn, "view-model", super::Store::model_data(m));
                }
                for p in patches {
                    f.send_to(conn, "view-patch", json!(p));
                }
            })
            .is_some()
    }

    fn grep_done(&self, f: &Front, conn: u64, view: &str, id: u64, error: Option<String>) {
        self.greps.with(conn, view, id, |run| {
            // the model is whole before the search is done: what waits goes now
            if let Some(m) = flush_model(&mut lock(&self.store), conn, view, run) {
                f.send_to(conn, "view-model", super::Store::model_data(m));
            }
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
    // a new search's model: no files yet, and its window from the start
    lock(&views.store).forget_windows(conn, &view);
    views.publish_model(f, conn, &view, grep_doc(&[], None));
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
    let ask = match (&p.upto, p.more, p.fill) {
        (Some(key), _, _) => Look::Upto(key),
        (None, Some(true), _) => Look::More,
        (None, _, Some(true)) => Look::Fill,
        _ => return Err(invalid("more", "more, fill, or upto a row's key")),
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

/// `search/grep-skipped`: VIEW lists only the matches Replace All skipped, each with its reason.
pub fn skipped(f: &Front, c: &Caller, p: GrepSkippedParams) -> Result<bool, Error> {
    let views = &f.core.views;
    let why = p.skipped.into_iter().map(|s| (s.id, s.why)).collect();
    Ok(views
        .greps
        .current(c.conn_id, &p.view, |run| {
            let (model, patches) =
                skip_patches(&mut lock(&views.store), c.conn_id, &p.view, run, why);
            if let Some(m) = model {
                f.send_to(c.conn_id, "view-model", super::Store::model_data(m));
            }
            for patch in patches {
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
