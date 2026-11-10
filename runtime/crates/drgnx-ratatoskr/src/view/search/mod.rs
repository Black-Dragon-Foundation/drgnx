//! The Search view's rows: `search/run` runs the view's search (hrafn's `grep` for Text) and sends its matches to the
//! view as rows, a reset when the search starts and each file's header and matches as that file's lines are complete.
//! `search/grep-replace` changes the replacement the rows preview, patching the rows without a new search. A search
//! of a view stops the one before it (a stopped search sends nothing more), and the view's close or its connection's
//! end stops it too. The rows do not depend on the display class: every class of the view gets the same rows.
//!
//! The view's model (`view-model`, before the rows that name it) is a `tree`: a node per file (`f:FILE`, open, FILE
//! relative to the root) with its matches as children (`m:RUN:N`, the run's number and the match's in it), the rows'
//! keys and their `drgnx-work-id`; a match's fields are what Replace writes from (file, line, col, end, text). A match's
//! id names it in its run only: the user's unticks reach the next run by the match's remap key (`run.rs`).
//!
//! `rows.rs` builds the rows and the model, `run.rs` keeps a run's records (numbers, snapshots, remap keys).

mod modes;
mod rows;
mod run;

use super::{Key, Store, Views, lock};
use crate::dispatch::Caller;
use crate::front::Front;
use drgnx_rows::{Op, Patch, Row};
use hrafn::grep::{self, Match, Query};
use modes::Mode;
use rows::{MODEL_WINDOW, entries_of, gap_row, grep_doc, row_index, rows_in, rows_upto, window_of};
use run::{Buffer, Found, Snap};
use runstav::methods::search::{
    BufferParams, FindQuery, GrepLookParams, GrepReplaceParams, GrepSkippedParams, RunDone,
    RunParams, RunStarted, ScopeKind,
};
use runstav::methods::view::ViewModel;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashSet};
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

/// One view's search: what it asked, what it found (files in the order their lines were complete), the replacement
/// the rows preview.
pub(super) struct Run {
    id: u64,
    query: Query,
    replace: String,
    files: Vec<Found>,
    /// The next match's number in the run.
    next: u32,
    /// The rows the views may have: the first this many of the rows of `files` (see [`WINDOW`]).
    limit: usize,
    /// The rows sent so far: the first `sent` rows of `files`.
    sent: usize,
    /// The rows of `files` sent after a gap row (a jump past [`FAR`]), when they do not meet the first `sent`.
    block: Option<std::ops::Range<usize>>,
    /// Match id → why Replace All skipped it (`search/grep-skipped`): its row shows it.
    reasons: BTreeMap<String, String>,
    /// The remap keys of the matches the user unticked in the runs before (`run.rs`): resolved at the run's end, or
    /// handed to the next run when a newer one stops this one first.
    carry: HashSet<u64>,
    /// The search has ended (`search-run-done` went out): a buffer's matches after it send the new totals again.
    done: bool,
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

/// The searches, one per (connection, view), and the editor's buffers each view searches in place of their files.
#[derive(Default)]
pub(super) struct Greps {
    runs: Mutex<BTreeMap<(u64, String), Run>>,
    next: AtomicU64,
    /// (connection, view) → file → its buffer (`search/buffer`), until the editor says the buffer is saved or gone.
    buffers: Mutex<BTreeMap<(u64, String), BTreeMap<String, Buffer>>>,
}

impl Greps {
    /// Start VIEW's search for QUERY (the one before is stopped): its number and cancel flag. OFF are the ids of the
    /// matches the user unticked in the run before; their keys, and those that run still carried, go to this one.
    fn start(
        &self,
        conn: u64,
        view: &str,
        query: Query,
        replace: String,
        off: &[String],
    ) -> (u64, Arc<AtomicBool>) {
        let id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        let cancel = Arc::new(AtomicBool::new(false));
        let mut runs = lock(&self.runs);
        let carry = match runs.get(&(conn, view.to_owned())) {
            Some(old) => {
                let mut keys = run::keys_of(old.id, &old.files, off);
                keys.extend(old.carry.iter().copied());
                keys
            }
            None => HashSet::new(),
        };
        let run = Run {
            id,
            query,
            replace,
            files: Vec::new(),
            next: 0,
            limit: WINDOW,
            sent: 0,
            block: None,
            reasons: BTreeMap::new(),
            carry,
            done: false,
            model_sent: 0,
            model_every: MODEL_EVERY,
            model_at: None,
            waiting: (Vec::new(), Vec::new()),
            cancel: cancel.clone(),
        };
        if let Some(old) = runs.insert((conn, view.to_owned()), run) {
            old.cancel.store(true, Ordering::Relaxed);
        }
        (id, cancel)
    }

    /// Stop VIEW's search (the view closed): its buffers go too.
    pub(super) fn stop(&self, conn: u64, view: &str) {
        if let Some(r) = lock(&self.runs).remove(&(conn, view.to_owned())) {
            r.cancel.store(true, Ordering::Relaxed);
        }
        lock(&self.buffers).remove(&(conn, view.to_owned()));
    }

    /// Stop every search of CONN, and forget its buffers.
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.runs).retain(|(c, _), r| {
            if *c == conn {
                r.cancel.store(true, Ordering::Relaxed);
            }
            *c != conn
        });
        lock(&self.buffers).retain(|(c, _), _| *c != conn);
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

    /// VIEW's buffer of FILE is BUF from now on; none: the file is searched on disk again.
    fn put_buffer(&self, conn: u64, view: &str, file: String, buf: Option<Buffer>) {
        let mut all = lock(&self.buffers);
        let key = (conn, view.to_owned());
        match buf {
            Some(b) => {
                all.entry(key).or_default().insert(file, b);
            }
            None => {
                if let Some(bufs) = all.get_mut(&key) {
                    bufs.remove(&file);
                    if bufs.is_empty() {
                        all.remove(&key);
                    }
                }
            }
        }
    }

    /// Whether VIEW's search takes FILE's matches on disk: not when a buffer's text stands for it.
    fn disk_ok(&self, conn: u64, view: &str, file: &str) -> bool {
        lock(&self.buffers)
            .get(&(conn, view.to_owned()))
            .and_then(|bufs| bufs.get(file))
            .is_none_or(|b| b.text.is_none())
    }

    /// VIEW's buffers, by file.
    fn buffers_of(&self, conn: u64, view: &str) -> Vec<(String, Buffer)> {
        lock(&self.buffers)
            .get(&(conn, view.to_owned()))
            .map(|bufs| bufs.iter().map(|(f, b)| (f.clone(), b.clone())).collect())
            .unwrap_or_default()
    }
}

/// Whether Q searches FILE (absolute): its one file, else a file under its root that its ignore rules search. A
/// buffer's file outside it is not searched (the include and exclude globs are the searcher's: a buffer is searched
/// whatever they say).
fn in_scope(q: &Query, file: &str) -> bool {
    if let Some(one) = &q.file {
        return Path::new(file) == one.as_path();
    }
    Path::new(file)
        .strip_prefix(&q.root)
        .ok()
        .and_then(|rel| rel.to_str())
        .is_some_and(|rel| !rel.is_empty() && grep::searched(q.ignore, rel))
}

/// FILE's buffer BUF as a run takes it: its text's matches for Q and its snapshot, or `Large`; none when its file is
/// not one Q searches. Searched here, outside every lock.
fn put_of(q: &Query, file: &str, buf: &Buffer) -> Option<Put> {
    if !in_scope(q, file) {
        return None;
    }
    Some(match &buf.text {
        Some(text) => Put::Text(
            grep::search_text(q, file, text).unwrap_or_default(),
            run::buffer_snap(buf.tick, text),
        ),
        None => Put::Large,
    })
}

/// What a buffer gives a run for its file.
enum Put {
    /// Its text's matches, and the text's snapshot: they take the place of the file's.
    Text(Vec<Match>, Snap),
    /// Too large to send: the file's matches on disk stay, and its header says the buffer is open in chunks.
    Large,
}

/// FILE's matches in RUN as PUT gives them: its matches (if any) replaced in place, with new numbers, or the file
/// added after the others; a file with none goes. False when nothing changed ([`whole_patches`] sends the rest).
fn put_file(run: &mut Run, file: &str, put: Put) -> bool {
    let at = run.files.iter().position(|f| f.file == file);
    match put {
        Put::Large => match at {
            Some(i) if !run.files[i].large => run.files[i].large = true,
            _ => return false,
        },
        Put::Text(ms, snap) => {
            let ns: Vec<u32> = (run.next..).take(ms.len()).collect();
            run.next += ms.len() as u32;
            let found = Found {
                file: file.to_owned(),
                ms,
                ns,
                snap: Some(snap),
                large: false,
            };
            match (at, found.ms.is_empty()) {
                (Some(i), true) => {
                    run.files.remove(i);
                }
                (Some(i), false) => run.files[i] = found,
                (None, true) => return false,
                (None, false) => run.files.push(found),
            }
        }
    }
    true
}

/// RUN's whole model, and its rows, as diffs for each class (files changed somewhere in them).
fn whole_patches(
    store: &mut Store,
    conn: u64,
    view: &str,
    run: &mut Run,
) -> (Option<ViewModel>, Vec<Patch>) {
    run.waiting = (Vec::new(), Vec::new());
    run.model_sent = entries_of(&run.files);
    run.model_at = Some(Instant::now());
    let from = store.window_from(conn, view, "order");
    let model = store.publish_model(
        conn,
        view,
        grep_doc(&run.query.root, run.id, &run.files, from),
    );
    let rows = view_rows(run);
    let patches = keys(store, conn, view)
        .iter()
        .filter_map(|k| store.publish(k, rows.clone(), &[]))
        .collect();
    (model, patches)
}

impl Run {
    /// The matches the carried unticks name in this run, which has ended: each key held by one match alone; the
    /// carry is spent (a key two matches hold, or none, is dropped: those come back ticked).
    fn off(&mut self) -> Vec<String> {
        let carry = std::mem::take(&mut self.carry);
        run::ids_with(self.id, &self.files, &carry)
    }
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
            store.publish_model(
                conn,
                view,
                grep_doc(&run.query.root, run.id, &run.files, from),
            )
        })
}

/// A file's matches (and the file as the search read it): the model with them when it is due ([`flush_model`]; none
/// when nothing changed or a throttle window has not passed), then the rows after the ones sent, an insert (a reset for
/// a class whose env just changed), which name its version.
fn batch_patches(
    store: &mut Store,
    conn: u64,
    view: &str,
    run: &mut Run,
    file: String,
    ms: Vec<Match>,
    snap: Option<Snap>,
) -> (Option<ViewModel>, Vec<Patch>) {
    let ns: Vec<u32> = (run.next..).take(ms.len()).collect();
    run.next += ms.len() as u32;
    let found = Found {
        file,
        ms,
        ns,
        snap,
        large: false,
    };
    let (nodes, ids) = rows::batch_nodes(&run.query.root, run.id, &found);
    run.files.push(found);
    // the file's rows (its header, then its matches), only what the window still has room for
    let entries = entries_of(&run.files);
    let at = entries - nodes.len();
    let room = run.limit.saturating_sub(run.sent).min(nodes.len());
    let rows = if room > 0 {
        rows_in(run, at..at + room)
    } else {
        Vec::new()
    };
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
        store.publish_model(
            conn,
            view,
            grep_doc(&run.query.root, run.id, &run.files, from),
        )
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
    let id = run.id;
    let files = std::mem::take(&mut run.files);
    run.files = files
        .into_iter()
        .filter_map(|f| {
            let (ms, ns): (Vec<Match>, Vec<u32>) =
                f.ms.into_iter()
                    .zip(f.ns)
                    .filter(|(_, n)| why.contains_key(&run::match_id(id, *n)))
                    .unzip();
            (!ms.is_empty()).then_some(Found { ms, ns, ..f })
        })
        .collect();
    run.reasons = why;
    run.carry.clear();
    run.waiting = (Vec::new(), Vec::new());
    run.model_sent = entries_of(&run.files);
    run.limit = WINDOW;
    run.block = None;
    store.forget_windows(conn, view);
    let model = store.publish_model(
        conn,
        view,
        grep_doc(&run.query.root, run.id, &run.files, None),
    );
    let rows = view_rows(run);
    let patches = keys(store, conn, view)
        .iter()
        .filter_map(|k| store.publish(k, rows.clone(), &[]))
        .collect();
    (model, patches)
}

/// The rows as they are now, for the classes whose rows differ (replace text changed, an env arrived).
fn rebuild_patches(store: &mut Store, conn: u64, view: &str, run: &mut Run) -> Vec<Patch> {
    let rows = view_rows(run);
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
                self.publish_model(
                    f,
                    key.0,
                    &key.1,
                    grep_doc(&run.query.root, run.id, &run.files, from),
                );
                let rows = view_rows(run);
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
                let w = window_of(&run.query.root, run.id, &run.files, MODEL_WINDOW, from);
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
                        self.publish_model(
                            f,
                            conn,
                            view,
                            grep_doc(&run.query.root, run.id, &run.files, from),
                        );
                    }
                }
            })
            .is_some()
    }

    /// The thread's hand-over of one file's matches and the file as it read it (dropped when VIEW's search is not
    /// search ID any more).
    #[allow(clippy::too_many_arguments)]
    fn grep_batch(
        &self,
        f: &Front,
        conn: u64,
        view: &str,
        id: u64,
        file: String,
        ms: Vec<Match>,
        snap: Option<Snap>,
    ) -> bool {
        self.greps
            .with(conn, view, id, |run| {
                let (model, patches) =
                    batch_patches(&mut lock(&self.store), conn, view, run, file, ms, snap);
                if let Some(m) = model {
                    f.send_to(conn, "view-model", super::Store::model_data(m));
                }
                for p in patches {
                    f.send_to(conn, "view-patch", json!(p));
                }
            })
            .is_some()
    }

    /// The buffers' matches (PUTS, by file) in VIEW's search ID, one model and one patch for all of them; false when
    /// VIEW's search is not search ID any more.
    fn grep_puts(
        &self,
        f: &Front,
        conn: u64,
        view: &str,
        id: u64,
        puts: Vec<(String, Put)>,
    ) -> bool {
        self.greps
            .with(conn, view, id, |run| {
                let mut changed = false;
                for (file, put) in puts {
                    changed |= put_file(run, &file, put);
                }
                if !changed {
                    return;
                }
                let (model, patches) = whole_patches(&mut lock(&self.store), conn, view, run);
                if let Some(m) = model {
                    f.send_to(conn, "view-model", super::Store::model_data(m));
                }
                for p in patches {
                    f.send_to(conn, "view-patch", json!(p));
                }
                if run.done {
                    // the totals changed after the end: they go again (the unticks went with the end)
                    f.send_to(
                        conn,
                        "search-run-done",
                        json!(done_of(view, run, None, Vec::new())),
                    );
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
            let off = run.off();
            run.done = true;
            f.send_to(
                conn,
                "search-run-done",
                json!(done_of(view, run, error, off)),
            );
        });
    }
}

/// `search-run-done` of VIEW's RUN: its totals, ERROR, the matches that come back unticked (OFF).
fn done_of(view: &str, run: &Run, error: Option<String>, off: Vec<String>) -> RunDone {
    RunDone {
        view: view.to_owned(),
        run: run.id,
        files: run.files.len() as u64,
        matches: run.files.iter().map(|f| f.ms.len() as u64).sum(),
        error,
        off,
    }
}

fn invalid(path: &str, message: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

/// P's search as hrafn's query and its mode, or why it is refused. Symbol and Meaning are read-only (no replacement);
/// their query holds the root and what was typed (the rows read it).
fn query_of(f: &Front, p: &RunParams) -> Result<(Query, Mode), Error> {
    let root = std::path::PathBuf::from(p.root.as_str());
    if !root.is_dir() {
        return Err(invalid("root", "an existing folder"));
    }
    let (text, case, word, regexp) = match &p.search.query {
        FindQuery::Text {
            text,
            case,
            word,
            regexp,
        } => (text, case, word, regexp),
        other => {
            if p.search.replace.as_deref().is_some_and(|r| !r.is_empty()) {
                return Err(invalid(
                    "search.replace",
                    "Symbol and Meaning searches are read-only",
                ));
            }
            let mode = match other {
                FindQuery::Symbol { name, case } => Mode::Symbol {
                    name: name.clone(),
                    case: case.unwrap_or(true),
                },
                _ => Mode::Meaning {
                    question: other.typed().to_owned(),
                },
            };
            let q = Query {
                root,
                text: other.typed().to_owned(),
                ..Query::default()
            };
            return Ok((q, mode));
        }
    };
    let file = match p.search.scope.as_ref() {
        None => None,
        Some(s) => match s.kind {
            ScopeKind::Project => None,
            ScopeKind::File => match s.files.as_deref() {
                Some([one]) => Some(one.as_str().into()),
                _ => {
                    return Err(invalid(
                        "search.scope.files",
                        "the File scope names its one file",
                    ));
                }
            },
            _ => {
                return Err(invalid(
                    "search.scope.kind",
                    "this hub searches the project or one file",
                ));
            }
        },
    };
    let q = Query {
        root,
        file,
        text: text.clone(),
        case: case.unwrap_or(false),
        word: word.unwrap_or(false),
        regexp: regexp.unwrap_or(false),
        include: p.search.include.clone().unwrap_or_default(),
        exclude: p.search.exclude.clone().unwrap_or_default(),
        ignore: super::files::ignore_for(f, p.ignore),
    };
    Ok((q, Mode::Text))
}

/// `search/run`: stop VIEW's search, send its classes a reset, and search on a thread of its own (Text), or ask the
/// index on a task of its own (Symbol, Meaning: all their files at once). The search is offered to the project's
/// recent searches (kept once it stood for the typing pause).
pub fn run(f: &Front, c: &Caller, p: RunParams) -> Result<RunStarted, Error> {
    let views = &f.core.views;
    if p.view.is_empty() || p.view.len() > runstav::methods::view::VIEW_MAX {
        return Err(invalid("view", "a view id of 1 to 64 bytes"));
    }
    let (query, mode) = query_of(f, &p)?;
    f.search
        .offer_recent(&query.root, &p.view, p.search.clone());
    let (conn, view) = (c.conn_id, p.view);
    let replace = p.search.replace.unwrap_or_default();
    let off = p.off.unwrap_or_default();
    let (id, cancel) = views.greps.start(conn, &view, query.clone(), replace, &off);
    // a new search's model: no files yet, and its window from the start
    lock(&views.store).forget_windows(conn, &view);
    views.publish_model(f, conn, &view, grep_doc(Path::new("/"), id, &[], None));
    for patch in start_patches(&mut lock(&views.store), conn, &view) {
        f.send_to(conn, "view-patch", json!(patch));
    }
    let Some(front) = views.front.get().cloned() else {
        return Err(invalid("view", "the hub is starting"));
    };
    if !matches!(mode, Mode::Text) {
        let root = p.root.clone();
        tokio::spawn(async move {
            let Some(f) = front.upgrade() else { return };
            let found = modes::batches(&f, &root, &mode).await;
            let error = match found {
                Ok(files) => {
                    for (file, ms) in files {
                        if !f.core.views.grep_batch(&f, conn, &view, id, file, ms, None) {
                            return;
                        }
                    }
                    None
                }
                Err(e) => Some(e),
            };
            f.core.views.grep_done(&f, conn, &view, id, error);
        });
        return Ok(RunStarted { run: id });
    }
    std::thread::Builder::new()
        .name("grep".into())
        .spawn(move || {
            let on_file = |ms: Vec<Match>| {
                let file = ms[0].file.clone();
                let Some(f) = front.upgrade() else {
                    cancel.store(true, Ordering::Relaxed);
                    return;
                };
                // a buffer's text stands for the file: its matches come at the end
                if !f.core.views.greps.disk_ok(conn, &view, &file) {
                    return;
                }
                // the file as the search read it, read here, outside every lock
                let snap = run::snapshot(Path::new(&file));
                if !f.core.views.grep_batch(&f, conn, &view, id, file, ms, snap) {
                    cancel.store(true, Ordering::Relaxed);
                }
            };
            let result = grep::run(&query, &cancel, on_file);
            if let Some(f) = front.upgrade() {
                // the editor's buffers with unsaved edits, searched here, outside every lock
                let puts = f
                    .core
                    .views
                    .greps
                    .buffers_of(conn, &view)
                    .into_iter()
                    .filter_map(|(file, b)| Some((file.clone(), put_of(&query, &file, &b)?)))
                    .collect::<Vec<_>>();
                if !cancel.load(Ordering::Relaxed) && !puts.is_empty() {
                    f.core.views.grep_puts(&f, conn, &view, id, puts);
                }
                f.core.views.grep_done(&f, conn, &view, id, result.err());
            }
        })
        .map_err(|e| invalid("view", &e.to_string()))?;
    Ok(RunStarted { run: id })
}

/// `search/buffer`: VIEW's searches search the buffer's text in place of its file from now on (or the file on disk,
/// saying the buffer is too large; neither: the file again); the current search takes it at once. True.
pub fn buffer(f: &Front, c: &Caller, p: BufferParams) -> Result<bool, Error> {
    let views = &f.core.views;
    if p.view.is_empty() || p.view.len() > runstav::methods::view::VIEW_MAX {
        return Err(invalid("view", "a view id of 1 to 64 bytes"));
    }
    let (conn, file) = (c.conn_id, p.path.as_str().to_owned());
    let buf = match (p.text, p.large) {
        (Some(text), _) => Some(Buffer {
            tick: p.tick,
            text: Some(text.into()),
        }),
        (None, Some(true)) => Some(Buffer {
            tick: p.tick,
            text: None,
        }),
        _ => None,
    };
    views
        .greps
        .put_buffer(conn, &p.view, file.clone(), buf.clone());
    // the current search's query, then its matches in the text, searched outside every lock
    let Some(buf) = buf else { return Ok(true) };
    let Some((id, query)) = views
        .greps
        .current(conn, &p.view, |run| (run.id, run.query.clone()))
    else {
        return Ok(true);
    };
    if let Some(put) = put_of(&query, &file, &buf) {
        views.grep_puts(f, conn, &p.view, id, vec![(file, put)]);
    }
    Ok(true)
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
