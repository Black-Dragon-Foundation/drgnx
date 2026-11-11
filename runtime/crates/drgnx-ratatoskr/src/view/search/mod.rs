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

mod apply;
mod edits;
mod group;
mod handoff;
mod modes;
mod pattern;
mod rows;
mod run;
mod scoped;

use scoped::{GitScope, Keep};

use super::{Key, Store, Views, lock};
use crate::dispatch::Caller;
use crate::front::Front;
use drgnx_rows::{Op, Patch, Row};
use hrafn::grep::{self, Match, Query};
use modes::Mode;
use rows::{
    FIRST_MODEL_WINDOW, MODEL_WINDOW, gap_row, grep_doc, row_index, rows_in, rows_total, rows_upto,
    run_doc, run_entries, run_window,
};
use run::{Buffer, Found, Read};
use runstav::methods::search::{
    AppliedParams, ApplyParams, BufferParams, ChangeOrigin, EditDocAnswer, EditDocParams,
    EditsAnswer, EditsParams, FileEdits, FindQuery, FoldParams, GrepGroup, GrepLookParams,
    GrepReplaceParams, GrepSkippedParams, GrepSort, GroupParams, HandoffAnswer, HandoffMark,
    HandoffMarkParams, HandoffParams, HandoffState, HandoffStateParams, HandoffTo, PreviewAnswer,
    PreviewParams, RunDone, RunParams, RunStarted, ScopeDone, ScopeKind, UndoParams,
};
use runstav::methods::view::ViewModel;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::time::Instant;

/// The mark of the agent a match was handed to, as the editor gives it: the face of its colour and its glyph.
#[derive(Clone, Debug)]
pub(super) struct AgentMark {
    pub face: String,
    pub glyph: String,
}

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
    /// Match id → the mark of the agent it was handed to (`search/handoff`): its row shows it.
    handed: BTreeMap<String, AgentMark>,
    /// The remap keys of the matches the user unticked in the runs before (`run.rs`): resolved at the run's end, or
    /// handed to the next run when a newer one stops this one first.
    carry: HashSet<u64>,
    /// The search has ended (`search-run-done` went out): a buffer's matches after it send the new totals again.
    done: bool,
    /// The matches get their definitions' label rows (`context`).
    context: bool,
    /// A git scope with `±`: each file's lines that keep a match (`scoped.rs`).
    keep: Option<Arc<Keep>>,
    /// What a git scope searched, for the end (`search-run-done`).
    scope: Option<ScopeDone>,
    /// A Symbol search: its definitions' counts per kind, for the end (`search-run-done`).
    kinds: Option<BTreeMap<String, u64>>,
    /// Only the totals go out (`count`): no model, no rows.
    count: bool,
    /// How the rows are grouped, in what order (`search/group`), and their layout when not by file in the order found,
    /// built when first asked after the files change ([`Run::layout`]).
    group: GrepGroup,
    sort: Option<GrepSort>,
    layout: std::cell::OnceCell<group::Layout>,
    /// The files' ranks in Hrafn's map, for the sort by rank (`search/group` asks the index for them once per run).
    ranks: Option<Arc<HashMap<String, f64>>>,
    /// The folded folders' ids (`search/fold`; a regroup opens them all).
    folded: HashSet<String>,
    /// A grouped search's files changed since its rows and model went out (they go at most once per `model_every`, and
    /// at the end).
    stale: bool,
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

/// With context labels on, at most this many threads read and parse a search's files (each file one parse).
const CONTEXT_READERS: usize = 4;

/// The searches, one per (connection, view), and the editor's buffers each view searches in place of their files.
#[derive(Default)]
pub(super) struct Greps {
    runs: Mutex<BTreeMap<(u64, String), Run>>,
    next: AtomicU64,
    /// (connection, view) → file → its buffer (`search/buffer`), until the editor says the buffer is saved or gone.
    buffers: Mutex<BTreeMap<(u64, String), BTreeMap<String, Buffer>>>,
    /// The change sets of the views' writes (`apply.rs`).
    changes: apply::Changes,
    /// The hand-offs to agents (`handoff.rs`).
    handoffs: handoff::Handoffs,
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
            handed: BTreeMap::new(),
            carry,
            done: false,
            context: true,
            keep: None,
            scope: None,
            kinds: None,
            count: false,
            group: GrepGroup::File,
            sort: None,
            layout: std::cell::OnceCell::new(),
            ranks: None,
            folded: HashSet::new(),
            stale: false,
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

/// Whether Q searches FILE (absolute): its one file, else one of its list, else a file under its root that its ignore
/// rules search. A buffer's file outside it is not searched (the include and exclude globs are the searcher's: a
/// buffer is searched whatever they say).
fn in_scope(q: &Query, file: &str) -> bool {
    if let Some(one) = &q.file {
        return Path::new(file) == one.as_path();
    }
    if let Some(list) = &q.files
        && !list.iter().any(|f| f.as_path() == Path::new(file))
    {
        return false;
    }
    Path::new(file)
        .strip_prefix(&q.root)
        .ok()
        .and_then(|rel| rel.to_str())
        .is_some_and(|rel| !rel.is_empty() && grep::searched(q.ignore, rel))
}

/// FILE's buffer BUF as a run takes it: its text's matches for Q (those KEEP keeps) and its snapshot, or `Large`;
/// none when its file is not one Q searches. Searched here, outside every lock.
fn put_of(q: &Query, file: &str, buf: &Buffer, context: bool, keep: Option<&Keep>) -> Option<Put> {
    if !in_scope(q, file) {
        return None;
    }
    Some(match &buf.text {
        Some(text) => {
            let mut ms = grep::search_text(q, file, text).unwrap_or_default();
            scoped::kept(keep, file, &mut ms);
            let ctx = if context {
                run::ctx_of(file, text, &ms)
            } else {
                Vec::new()
            };
            let read = Read {
                snap: run::buffer_snap(buf.tick, text),
                ctx,
                marks: Vec::new(),
            };
            Put::Text(ms, read)
        }
        None => Put::Large,
    })
}

/// What a buffer gives a run for its file.
enum Put {
    /// Its text's matches, and the text's snapshot (and context): they take the place of the file's.
    Text(Vec<Match>, Read),
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
        Put::Text(ms, read) => {
            let ns: Vec<u32> = (run.next..).take(ms.len()).collect();
            run.next += ms.len() as u32;
            let found = Found::new(file.to_owned(), ms, ns, Some(read));
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
    run.files_changed();
    true
}

/// RUN's model in the window CONN's editor asked for (`view/window`; after a regroup, the whole window): the same
/// entries in another window are the move alone (the nodes held stay as they are), else the model's diff.
fn window_model(store: &mut Store, conn: u64, view: &str, run: &Run) -> Option<ViewModel> {
    let from = store.window_from(conn, view, "order");
    let w = run_window(run, MODEL_WINDOW, from);
    let m = super::model::WindowMove {
        name: "order",
        window: (w.total, w.from),
        held: &w.held,
        order: w.order.clone(),
    };
    match store.move_model(conn, view, m, |i| w.node(i)) {
        Some(m) => Some(m),
        None => store.publish_model(conn, view, run_doc(run, from)),
    }
}

/// RUN's whole model, and its rows, as diffs for each class (files changed somewhere in them).
fn whole_patches(
    store: &mut Store,
    conn: u64,
    view: &str,
    run: &mut Run,
) -> (Option<ViewModel>, Vec<Patch>) {
    whole_patches_of(store, conn, view, run, MODEL_WINDOW)
}

/// [`whole_patches`] with a model window of at most WINDOW entries.
fn whole_patches_of(
    store: &mut Store,
    conn: u64,
    view: &str,
    run: &mut Run,
    window: usize,
) -> (Option<ViewModel>, Vec<Patch>) {
    run.waiting = (Vec::new(), Vec::new());
    // a first window holds fewer: a batch then publishes the whole, never extends what the editor does not hold
    run.model_sent = run_entries(run).min(window);
    run.model_at = Some(crate::clock::now());
    let from = store.window_from(conn, view, "order");
    let model = store.publish_model(conn, view, rows::run_doc_of(run, window, from));
    let rows = view_rows(run);
    let patches = keys(store, conn, view)
        .iter()
        .filter_map(|k| store.publish(k, rows.clone(), &[]))
        .collect();
    (model, patches)
}

impl Run {
    /// The rows' layout when they are grouped ([`group::grouped`]); none by file in the order found.
    fn layout(&self) -> Option<&group::Layout> {
        group::grouped(self.group, self.sort).then(|| {
            self.layout.get_or_init(|| {
                let order = group::Order {
                    sort: self.sort,
                    ranks: self.ranks.as_deref(),
                    folded: Some(&self.folded),
                };
                group::Layout::build(&self.query.root, &self.files, self.group, &order)
            })
        })
    }

    /// The run's files changed: a grouped layout is built again when next asked.
    fn files_changed(&mut self) {
        self.layout.take();
    }

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
    let total = rows_total(run);
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
    let entries = run_entries(run);
    if run.model_sent >= entries {
        return None;
    }
    let (nodes, ids) = std::mem::take(&mut run.waiting);
    let appends =
        run.model_sent > 0 && run.model_sent + ids.len() == entries && entries <= MODEL_WINDOW;
    run.model_sent = entries;
    run.model_at = Some(crate::clock::now());
    appends
        .then(|| store.append_model(conn, view, nodes, "order", ids))
        .flatten()
        .or_else(|| {
            let from = store.window_from(conn, view, "order");
            store.publish_model(conn, view, run_doc(run, from))
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
    read: Option<Read>,
) -> (Option<ViewModel>, Vec<Patch>) {
    let ns: Vec<u32> = (run.next..).take(ms.len()).collect();
    run.next += ms.len() as u32;
    let found = Found::new(file, ms, ns, read);
    let (nodes, ids) = rows::batch_nodes(&run.query.root, run.id, &found);
    let n = found.rows();
    run.files.push(found);
    run.files_changed();
    if run.layout().is_some() {
        // grouped: a new file may go anywhere in the rows, so the rows and the model go whole (diffs), at most once
        // per throttle window, and at the end
        let due = run
            .model_at
            .is_none_or(|t| crate::clock::now().duration_since(t) >= run.model_every);
        if !due {
            run.stale = true;
            return (None, Vec::new());
        }
        run.stale = false;
        return whole_patches(store, conn, view, run);
    }
    // the file's rows (its header, its labels and its matches), only what the window still has room for
    let entries = run_entries(run);
    let at = rows_total(run) - n;
    let room = run.limit.saturating_sub(run.sent).min(n);
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
        let due = !rows.is_empty()
            || run
                .model_at
                .is_none_or(|t| crate::clock::now().duration_since(t) >= run.model_every);
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
        store.publish_model(conn, view, run_doc(run, from))
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
            // a row under a folded folder: the folders above it open
            let above = run.layout().and_then(|l| {
                rows::ent_index(run, l, key)
                    .filter(|at| l.shown_at[*at].is_none())
                    .map(|at| l.folded_above(at))
            });
            let opened = above.is_some();
            for d in above.into_iter().flatten() {
                run.folded.remove(&d);
            }
            if opened {
                run.files_changed();
            }
            let Some(i) = row_index(run, key) else {
                return Vec::new();
            };
            let sent = i < run.limit || run.block.as_ref().is_some_and(|b| b.contains(&i));
            if sent && !opened {
                return Vec::new();
            }
            if sent {
                // the folders opened: the rows again, the window as it is
                return rebuild_patches(store, conn, view, run);
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
    let total = rows_total(run);
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
            let keep: Vec<bool> =
                f.ns.iter()
                    .map(|n| why.contains_key(&run::match_id(id, *n)))
                    .collect();
            fn pick<T>(v: Vec<T>, keep: &[bool]) -> Vec<T> {
                v.into_iter()
                    .zip(keep)
                    .filter_map(|(x, k)| k.then_some(x))
                    .collect()
            }
            let (ms, ns) = (pick(f.ms, &keep), pick(f.ns, &keep));
            if ms.is_empty() {
                return None;
            }
            let ctx = if f.ctx.is_empty() {
                Vec::new()
            } else {
                pick(f.ctx, &keep)
            };
            // a replacement runs in Text mode only: no marks
            let read = f.snap.map(|snap| Read {
                snap,
                ctx,
                marks: Vec::new(),
            });
            Some(Found {
                large: f.large,
                ..Found::new(f.file, ms, ns, read)
            })
        })
        .collect();
    run.files_changed();
    run.reasons = why;
    run.carry.clear();
    run.waiting = (Vec::new(), Vec::new());
    run.model_sent = run_entries(run);
    run.limit = WINDOW;
    run.block = None;
    store.forget_windows(conn, view);
    let model = store.publish_model(conn, view, run_doc(run, None));
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
                self.publish_model(f, key.0, &key.1, run_doc(run, from));
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
                if let Some(m) = window_model(&mut lock(&self.store), conn, view, run) {
                    f.send_to(conn, "view-model", super::Store::model_data(m));
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
        read: Option<Read>,
    ) -> bool {
        self.greps
            .with(conn, view, id, |run| {
                let (model, patches) =
                    batch_patches(&mut lock(&self.store), conn, view, run, file, ms, read);
                if run.count {
                    return;
                }
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
                if let (Some(m), false) = (model, run.count) {
                    f.send_to(conn, "view-model", super::Store::model_data(m));
                }
                for p in patches.into_iter().filter(|_| !run.count) {
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
            if run.stale && !run.count {
                run.stale = false;
                let mut store = lock(&self.store);
                let (model, patches) = whole_patches(&mut store, conn, view, run);
                drop(store);
                if let Some(m) = model {
                    f.send_to(conn, "view-model", super::Store::model_data(m));
                }
                for p in patches {
                    f.send_to(conn, "view-patch", json!(p));
                }
            }
            // the model is whole before the search is done: what waits goes now
            if let (Some(m), false) = (
                flush_model(&mut lock(&self.store), conn, view, run),
                run.count,
            ) {
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
        scope: run.scope.clone(),
        kinds: run.kinds.as_ref().map(modes::kind_list),
    }
}

fn invalid(path: &str, message: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

/// P's search as hrafn's query, its mode and its git scope, or why it is refused. Symbol and Meaning are read-only (no
/// replacement) and search the project; their query holds the root and what was typed (the rows read it). A git
/// scope's query lists no file until the search's thread has found them.
fn query_of(f: &Front, p: &RunParams) -> Result<(Query, Mode, Option<GitScope>), Error> {
    let root = std::path::PathBuf::from(p.root.as_str());
    if !root.is_dir() {
        return Err(invalid("root", "an existing folder"));
    }
    let (text, case, word, regexp, mode) = match &p.search.query {
        FindQuery::Text {
            text,
            case,
            word,
            regexp,
        } => (text, case, word, regexp, Mode::Text),
        // Text's files; its rewrite templates come with their write path
        FindQuery::Pattern { pattern, lang } => {
            if p.search.replace.as_deref().is_some_and(|r| !r.is_empty()) {
                return Err(invalid(
                    "search.replace",
                    "a Pattern search is read-only for now",
                ));
            }
            let lang = lang
                .as_deref()
                .map(pattern::lang_of)
                .transpose()
                .map_err(|e| invalid("search.query.lang", &e))?;
            let find = pattern::Find {
                pattern: pattern.clone(),
                lang,
            };
            (pattern, &None, &None, &None, Mode::Pattern(find))
        }
        other => {
            if p.search.replace.as_deref().is_some_and(|r| !r.is_empty()) {
                return Err(invalid(
                    "search.replace",
                    "Symbol and Meaning searches are read-only",
                ));
            }
            let mode = match other {
                FindQuery::Symbol { name, case, kinds } => Mode::Symbol {
                    name: name.clone(),
                    case: case.unwrap_or(true),
                    kinds: kinds.clone().unwrap_or_default(),
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
            return Ok((q, mode, None));
        }
    };
    let (mut file, mut files, mut git) = (None, None, None);
    if let Some(s) = p.search.scope.as_ref() {
        match s.kind {
            ScopeKind::Project => {}
            ScopeKind::File => match s.files.as_deref() {
                Some([one]) => file = Some(one.as_str().into()),
                _ => {
                    return Err(invalid(
                        "search.scope.files",
                        "the File scope names its one file",
                    ));
                }
            },
            ScopeKind::Open => {
                let Some(list) = s.files.as_ref() else {
                    return Err(invalid(
                        "search.scope.files",
                        "the Open scope names its files",
                    ));
                };
                files = Some(list.iter().map(|f| f.as_str().into()).collect());
            }
            ScopeKind::Changed | ScopeKind::Staged | ScopeKind::Branch => {
                files = Some(Vec::new());
                git = Some(GitScope {
                    kind: s.kind,
                    base: s.base.clone(),
                    changed_lines: s.changed_lines.unwrap_or(false),
                });
            }
        }
    }
    let q = Query {
        root,
        file,
        files,
        text: text.clone(),
        case: case.unwrap_or(false),
        word: word.unwrap_or(false),
        regexp: regexp.unwrap_or(false),
        include: p.search.include.clone().unwrap_or_default(),
        exclude: p.search.exclude.clone().unwrap_or_default(),
        ignore: super::files::ignore_for(f, p.ignore),
        first: false,
    };
    Ok((q, mode, git))
}

/// `search/run`: stop VIEW's search, send its classes a reset, and search on a thread of its own (Text), or ask the
/// index on a task of its own (Symbol, Meaning: all their files at once). The search is offered to the project's
/// recent searches (kept once it stood for the typing pause).
pub fn run(f: &Front, c: &Caller, p: RunParams) -> Result<RunStarted, Error> {
    let views = &f.core.views;
    if p.view.is_empty() || p.view.len() > runstav::methods::view::VIEW_MAX {
        return Err(invalid("view", "a view id of 1 to 64 bytes"));
    }
    if p.sort == Some(GrepSort::Rank) {
        return Err(invalid(
            "sort",
            "path or count: the sort by rank waits for the index, so search/group takes it",
        ));
    }
    let (query, mode, git) = query_of(f, &p)?;
    // a count is not a search the user typed: it is not recent, and it sends only its totals (no labels to read)
    let count = p.count.unwrap_or(false);
    if !count {
        f.search
            .offer_recent(&query.root, &p.view, p.search.clone());
    }
    let (conn, view) = (c.conn_id, p.view);
    let replace = p.search.replace.unwrap_or_default();
    let off = p.off.unwrap_or_default();
    let (id, cancel) = views.greps.start(conn, &view, query.clone(), replace, &off);
    let context = p.context.unwrap_or(true) && !count;
    views.greps.with(conn, &view, id, |r| {
        r.context = context;
        r.count = count;
        r.group = p.group.unwrap_or_default();
        r.sort = p.sort;
    });
    if !count {
        // a new search's model: no files yet, and its window from the start
        lock(&views.store).forget_windows(conn, &view);
        views.publish_model(f, conn, &view, grep_doc(Path::new("/"), id, &[], None));
        for patch in start_patches(&mut lock(&views.store), conn, &view) {
            f.send_to(conn, "view-patch", json!(patch));
        }
    }
    let Some(front) = views.front.get().cloned() else {
        return Err(invalid("view", "the hub is starting"));
    };
    if !matches!(mode, Mode::Text | Mode::Pattern(_)) {
        let root = p.root.clone();
        crate::clock::spawn("search:modes", async move {
            let Some(f) = front.upgrade() else { return };
            let found = modes::found(&f, &root, &mode, context).await;
            let error = match found {
                Ok((files, kinds)) => {
                    if kinds.is_some() {
                        f.core
                            .views
                            .greps
                            .with(conn, &view, id, |r| r.kinds = kinds);
                    }
                    for (file, ms, read) in files {
                        if !f.core.views.grep_batch(&f, conn, &view, id, file, ms, read) {
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
            // a git scope's files (and with `±` their added lines), found here, off the request's path
            let (mut query, mut keep) = (query, None::<Arc<Keep>>);
            if let Some(g) = &git {
                let (done, why) = match scoped::find(&query.root, g) {
                    Ok(s) => {
                        query.files = Some(s.files);
                        keep = s.keep.map(Arc::new);
                        (s.done, None)
                    }
                    Err((done, why)) => (done, Some(why)),
                };
                let Some(f) = front.upgrade() else { return };
                let (files, k) = (query.files.clone(), keep.clone());
                f.core.views.greps.with(conn, &view, id, |r| {
                    r.query.files = files;
                    r.keep = k;
                    r.scope = Some(done);
                });
                if why.is_some() {
                    f.core.views.grep_done(&f, conn, &view, id, why);
                    return;
                }
            }
            // a file's matches as the run lists them, and the file as the search read it (and its definitions), read
            // outside every lock; none when the run is over or a buffer's text stands for the file (its matches come
            // at the end)
            let read_file = |mut ms: Vec<Match>| -> Option<(String, Vec<Match>, Option<Read>)> {
                if cancel.load(Ordering::Relaxed) {
                    return None;
                }
                let file = ms[0].file.clone();
                scoped::kept(keep.as_deref(), &file, &mut ms);
                if ms.is_empty() {
                    return None;
                }
                let Some(f) = front.upgrade() else {
                    cancel.store(true, Ordering::Relaxed);
                    return None;
                };
                if !f.core.views.greps.disk_ok(conn, &view, &file) {
                    return None;
                }
                let read = run::read(Path::new(&file), &ms, context);
                Some((file, ms, read))
            };
            // the batches go from one thread, as they come: one holder of the run's locks at a time, so the next
            // search's request never waits behind several
            let send = |(file, ms, read): (String, Vec<Match>, Option<Read>)| {
                if cancel.load(Ordering::Relaxed) {
                    return;
                }
                let Some(f) = front.upgrade() else {
                    cancel.store(true, Ordering::Relaxed);
                    return;
                };
                if !f.core.views.grep_batch(&f, conn, &view, id, file, ms, read) {
                    cancel.store(true, Ordering::Relaxed);
                }
            };
            // a Pattern search reads and parses each file itself (`pattern`), its marks kept with the matches a
            // `±` scope leaves; the editor's unsaved buffers are not searched (their files neither)
            if let Mode::Pattern(find) = &mode {
                let result = pattern::run(&query, find, &cancel, |batch| {
                    let marks: std::collections::HashMap<(u32, u32), run::Mark> = batch
                        .iter()
                        .map(|(m, k)| ((m.line, m.col), k.clone()))
                        .collect();
                    let ms = batch.into_iter().map(|(m, _)| m).collect();
                    if let Some((file, ms, read)) = read_file(ms) {
                        let read = read.map(|mut r| {
                            r.marks = ms
                                .iter()
                                .map(|m| marks.get(&(m.line, m.col)).cloned())
                                .collect();
                            r
                        });
                        send((file, ms, read));
                    }
                });
                if let Some(f) = front.upgrade() {
                    f.core.views.grep_done(&f, conn, &view, id, result.err());
                }
                return;
            }
            // with context, a file's read parses it: a few readers take the files as grep finds them (its order is
            // already unordered) and hand them to this thread
            let result = if context {
                let (to_read, files) = std::sync::mpsc::channel::<Vec<Match>>();
                let (to_send, reads) = std::sync::mpsc::channel();
                let files = std::sync::Mutex::new(files);
                let readers = std::thread::available_parallelism()
                    .map_or(1, |n| n.get().min(CONTEXT_READERS));
                std::thread::scope(|s| {
                    for _ in 0..readers {
                        let to_send = to_send.clone();
                        let (files, read_file) = (&files, &read_file);
                        s.spawn(move || {
                            // the receiver's lock is let go before the file is read
                            loop {
                                let next = lock(files).recv();
                                let Ok(ms) = next else { break };
                                if let Some(r) = read_file(ms) {
                                    let _ = to_send.send(r);
                                }
                            }
                        });
                    }
                    drop(to_send);
                    let (q, c) = (&query, &cancel);
                    let grep = s.spawn(move || {
                        // its end drops the readers' sender: they stop once they have taken every file
                        grep::run(q, c, |ms| {
                            let _ = to_read.send(ms);
                        })
                    });
                    for r in reads {
                        send(r);
                    }
                    grep.join()
                        .unwrap_or_else(|_| Err("the search's grep thread failed".into()))
                })
            } else {
                grep::run(&query, &cancel, |ms| {
                    if let Some(r) = read_file(ms) {
                        send(r);
                    }
                })
            };
            if let Some(f) = front.upgrade() {
                // the editor's buffers with unsaved edits, searched here, outside every lock
                let puts = f
                    .core
                    .views
                    .greps
                    .buffers_of(conn, &view)
                    .into_iter()
                    .filter_map(|(file, b)| {
                        Some((
                            file.clone(),
                            put_of(&query, &file, &b, context, keep.as_deref())?,
                        ))
                    })
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
    let Some((id, query, context, keep)) = views.greps.current(conn, &p.view, |run| {
        (run.id, run.query.clone(), run.context, run.keep.clone())
    }) else {
        return Ok(true);
    };
    if let Some(put) = put_of(&query, &file, &buf, context, keep.as_deref()) {
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

/// RUN grouped as GROUP in the order SORT: its model from its start and its rows from the first window, whole (diffs);
/// nothing when it is grouped so already.
fn regroup_patches(
    store: &mut Store,
    conn: u64,
    view: &str,
    run: &mut Run,
    group: GrepGroup,
    sort: Option<GrepSort>,
) -> (Option<ViewModel>, Vec<Patch>) {
    if run.group == group && run.sort == sort {
        return (None, Vec::new());
    }
    run.group = group;
    run.sort = sort;
    run.folded.clear();
    run.files_changed();
    run.stale = false;
    run.limit = WINDOW;
    run.block = None;
    store.forget_windows(conn, view);
    // the first window's model; the editor asks for the whole window once its rows are drawn
    whole_patches_of(store, conn, view, run, FIRST_MODEL_WINDOW)
}

/// `search/group`: VIEW's search grouped as asked, without searching again: its model (from its start) and rows whole,
/// as diffs; the match ids stay, so the ticks do.
pub async fn group(f: &Front, c: &Caller, p: GroupParams) -> Result<bool, Error> {
    let views = &f.core.views;
    if p.sort == Some(GrepSort::Rank) {
        // the ranks once per run, from the project's index (waiting for it): a project without one says why
        let Some((root, has)) = views.greps.current(c.conn_id, &p.view, |run| {
            (run.query.root.clone(), run.ranks.is_some())
        }) else {
            return Ok(false);
        };
        if !has {
            let ranks = Arc::new(f.search.file_ranks(f, &root).await?);
            views.greps.current(c.conn_id, &p.view, |run| {
                if run.query.root == root {
                    run.ranks = Some(ranks);
                    run.files_changed();
                }
            });
        }
    }
    Ok(views
        .greps
        .current(c.conn_id, &p.view, |run| {
            let mut store = lock(&views.store);
            let (model, patches) =
                regroup_patches(&mut store, c.conn_id, &p.view, run, p.group, p.sort);
            drop(store);
            if let Some(m) = model {
                f.send_to(c.conn_id, "view-model", super::Store::model_data(m));
            }
            for patch in patches {
                f.send_to(c.conn_id, "view-patch", json!(patch));
            }
        })
        .is_some())
}

/// `search/fold`: a folder of VIEW's search (grouped by Folders) folded or opened: only the rows change, as diffs.
pub fn fold(f: &Front, c: &Caller, p: FoldParams) -> Result<bool, Error> {
    let views = &f.core.views;
    Ok(views
        .greps
        .current(c.conn_id, &p.view, |run| {
            let mut store = lock(&views.store);
            let patches = fold_patches(&mut store, c.conn_id, &p.view, run, &p.node, p.open)?;
            drop(store);
            for patch in patches {
                f.send_to(c.conn_id, "view-patch", json!(patch));
            }
            Some(())
        })
        .flatten()
        .is_some())
}

/// RUN's folder NODE folded (or opened when OPEN): its rows again, as diffs; none when RUN is not grouped by Folders
/// or has no such folder.
fn fold_patches(
    store: &mut Store,
    conn: u64,
    view: &str,
    run: &mut Run,
    node: &str,
    open: bool,
) -> Option<Vec<Patch>> {
    if run.group != GrepGroup::Tree
        || !node.starts_with("d:")
        || !run.layout()?.at_node.contains_key(node)
    {
        return None;
    }
    let changed = if open {
        run.folded.remove(node)
    } else {
        run.folded.insert(node.to_owned())
    };
    if !changed {
        return Some(Vec::new());
    }
    run.files_changed();
    Some(rebuild_patches(store, conn, view, run))
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

/// The files of RUN's matches P asks for (`ids`, else all but `off`), as the edit set takes them, and the buffers'
/// texts the run searched in their files' place (BUFS).
fn plans_of(
    run: &Run,
    p: &EditsParams,
    bufs: &BTreeMap<String, std::sync::Arc<str>>,
) -> Vec<edits::FilePlan> {
    let ids: Option<HashSet<&str>> = p
        .ids
        .as_ref()
        .map(|v| v.iter().map(String::as_str).collect());
    let off: HashSet<&str> = p.off.iter().flatten().map(String::as_str).collect();
    run.files
        .iter()
        .filter_map(|f| {
            let wants: Vec<edits::Want> =
                f.ms.iter()
                    .zip(&f.ns)
                    .filter_map(|(m, n)| {
                        let id = run::match_id(run.id, *n);
                        let take = match &ids {
                            Some(ids) => ids.contains(id.as_str()),
                            None => !off.contains(id.as_str()),
                        };
                        take.then(|| edits::Want {
                            new: grep::new_text(
                                &run.query,
                                &m.text,
                                p.replace.as_deref().unwrap_or(&run.replace),
                            ),
                            id,
                            line: m.line,
                            col: m.col,
                            end_line: m.line,
                            end_col: m.end,
                            old: m.text.clone(),
                        })
                    })
                    .collect();
            (!wants.is_empty()).then(|| edits::FilePlan {
                path: f.file.clone(),
                snap: f.snap.clone(),
                large: f.large,
                buffer: bufs.get(&f.file).cloned(),
                wants,
            })
        })
        .collect()
}

/// The edits P names itself, by file in the order first named; each `e:K` (its place in P's list).
fn given_plans(given: &[runstav::methods::search::GivenEdit]) -> Vec<edits::FilePlan> {
    let mut by: Vec<edits::FilePlan> = Vec::new();
    for (k, g) in given.iter().enumerate() {
        let want = edits::Want {
            id: format!("e:{k}"),
            line: g.line,
            col: g.col,
            end_line: g.end_line.unwrap_or(g.line),
            end_col: g.end_col,
            old: g.old.clone(),
            new: Some(g.new.clone()),
        };
        match by.iter_mut().find(|f| f.path == g.path.as_str()) {
            Some(f) => f.wants.push(want),
            None => by.push(edits::FilePlan {
                path: g.path.as_str().to_owned(),
                snap: None,
                large: false,
                buffer: None,
                wants: vec![want],
            }),
        }
    }
    by
}

/// An Edit Results line set's plans: LINES' edits by file in the order first named (`line_want`), each file's text the
/// buffer's the hub holds (BUFS) or the file's.
fn line_plans(
    lines: &[runstav::methods::search::EditedLine],
    bufs: &BTreeMap<String, std::sync::Arc<str>>,
) -> Vec<edits::FilePlan> {
    let mut by: Vec<edits::FilePlan> = Vec::new();
    for l in lines {
        let want = edits::line_want(l);
        match by.iter_mut().find(|f| f.path == l.path.as_str()) {
            Some(f) => f.wants.push(want),
            None => by.push(edits::FilePlan {
                path: l.path.as_str().to_owned(),
                snap: None,
                large: false,
                buffer: bufs.get(l.path.as_str()).cloned(),
                wants: vec![want],
            }),
        }
    }
    by
}

/// The buffers' texts the run of VIEW (CONN's) searched in their files' place, by file.
fn texts_of(views: &Views, conn: u64, view: &str) -> BTreeMap<String, std::sync::Arc<str>> {
    views
        .greps
        .buffers_of(conn, view)
        .into_iter()
        .filter_map(|(f, b)| Some((f, b.text?)))
        .collect()
}

/// `search/edits`: the edit set of VIEW's search (or of the edits P names, or of an Edit Results buffer's changed
/// lines), kept as a change set for `search/apply`. The files are read on a blocking thread, outside every lock.
pub async fn edits(f: &Front, c: &Caller, p: EditsParams) -> Result<EditsAnswer, Error> {
    let views = &f.core.views;
    let conn = c.conn_id;
    let origin = if p.lines.is_some() {
        ChangeOrigin::EditResults
    } else {
        ChangeOrigin::ReplaceAll
    };
    let (root, plans) = match (&p.edits, &p.lines) {
        (_, Some(lines)) => {
            let bufs = texts_of(views, conn, &p.view);
            let root = views
                .greps
                .current(conn, &p.view, |run| run.query.root.clone())
                .ok_or_else(|| invalid("view", "the view has no search"))?;
            (root, line_plans(lines, &bufs))
        }
        (Some(given), None) => {
            let Some(root) = &p.root else {
                return Err(invalid("root", "the project the edits are in"));
            };
            (std::path::PathBuf::from(root.as_str()), given_plans(given))
        }
        (None, None) => {
            let bufs = texts_of(views, conn, &p.view);
            views
                .greps
                .current(conn, &p.view, |run| {
                    (run.query.root.clone(), plans_of(run, &p, &bufs))
                })
                .ok_or_else(|| invalid("view", "the view has no search"))?
        }
    };
    let made = crate::clock::blocking(move || {
        plans.into_iter().map(edits::file_edits).collect::<Vec<_>>()
    })
    .await
    .map_err(|e| invalid("view", &e.to_string()))?;
    let (mut files, mut skipped) = (Vec::new(), Vec::new());
    for (planned, skips) in made {
        files.extend(planned);
        skipped.extend(skips);
    }
    let answer_files = files
        .iter()
        .map(|p| FileEdits {
            path: p.path.clone(),
            source: p.source,
            edits: p.edits.clone(),
        })
        .collect();
    let change = views
        .greps
        .changes
        .add(conn, &p.view, root, origin, None, files);
    Ok(EditsAnswer {
        change,
        files: answer_files,
        skipped,
    })
}

/// How many lines an Edit Results buffer holds at most, unless the editor says (`search/edit-doc` `max`).
const EDIT_DOC_MAX: u32 = 20_000;

/// The Edit Results document's plans of RUN: each file's match lines, once each, in order.
fn doc_plans(run: &Run, bufs: &BTreeMap<String, std::sync::Arc<str>>) -> Vec<edits::DocPlan> {
    let mut by: BTreeMap<&str, edits::DocPlan> = BTreeMap::new();
    for f in &run.files {
        let d = by.entry(f.file.as_str()).or_insert_with(|| edits::DocPlan {
            path: f.file.clone(),
            snap: f.snap.clone(),
            large: f.large,
            buffer: bufs.get(&f.file).cloned(),
            lines: Vec::new(),
        });
        d.lines.extend(f.ms.iter().map(|m| m.line));
    }
    by.into_values()
        .map(|mut d| {
            d.lines.sort_unstable();
            d.lines.dedup();
            d
        })
        .collect()
}

/// `search/edit-doc`: VIEW's search as an Edit Results document, P.context lines around each match line; none past
/// P.max lines (counted from the match lines first, so a huge search reads no file). Read on a blocking thread.
pub async fn edit_doc(f: &Front, c: &Caller, p: EditDocParams) -> Result<EditDocAnswer, Error> {
    let views = &f.core.views;
    let conn = c.conn_id;
    let context = p.context.unwrap_or(0).min(3);
    let max = u64::from(p.max.unwrap_or(EDIT_DOC_MAX));
    let bufs = texts_of(views, conn, &p.view);
    let plans = views
        .greps
        .current(conn, &p.view, |run| doc_plans(run, &bufs))
        .ok_or_else(|| invalid("view", "the view has no search"))?;
    let over = |total: u64, skipped| EditDocAnswer {
        lines: Vec::new(),
        total,
        over: true,
        skipped,
    };
    let first: u64 = plans.iter().map(|d| d.lines.len() as u64).sum();
    if first > max {
        return Ok(over(first, Vec::new()));
    }
    let (lines, skipped) = crate::clock::blocking(move || {
        let (mut next, mut lines, mut skipped) = (0, Vec::new(), Vec::new());
        for d in plans {
            match edits::doc_lines(d, context, &mut next) {
                Ok(ls) => lines.extend(ls),
                Err(s) => skipped.push(s),
            }
        }
        (lines, skipped)
    })
    .await
    .map_err(|e| invalid("view", &e.to_string()))?;
    let total = lines.len() as u64;
    if total > max {
        return Ok(over(total, skipped));
    }
    Ok(EditDocAnswer {
        lines,
        total,
        over: false,
        skipped,
    })
}

/// `search/preview`: P.path's changes of VIEW's search as a diff (the preview tile). Read on a blocking thread.
pub async fn preview(f: &Front, c: &Caller, p: PreviewParams) -> Result<PreviewAnswer, Error> {
    let views = &f.core.views;
    let conn = c.conn_id;
    let path = p.path.as_str().to_owned();
    let bufs: BTreeMap<String, std::sync::Arc<str>> = views
        .greps
        .buffers_of(conn, &p.view)
        .into_iter()
        .filter(|(f, _)| *f == path)
        .filter_map(|(f, b)| Some((f, b.text?)))
        .collect();
    let edits_params = EditsParams {
        view: p.view.clone(),
        root: None,
        ids: None,
        off: p.off.clone(),
        edits: None,
        replace: p.replace.clone(),
        lines: None,
    };
    let (query, plan, around) = views
        .greps
        .current(conn, &p.view, |run| {
            let plan = plans_of(run, &edits_params, &bufs)
                .into_iter()
                .find(|f| f.path == path);
            (
                run.query.clone(),
                plan,
                around_of(run, &path, &edits_params),
            )
        })
        .ok_or_else(|| invalid("view", "the view has no search"))?;
    let Some(plan) = plan else {
        return Ok(PreviewAnswer {
            path,
            diff: String::new(),
            plus: 0,
            minus: 0,
            hunks: Vec::new(),
            skipped: Vec::new(),
        });
    };
    let (answer, skipped) = crate::clock::blocking(move || {
        edits::preview(plan, |old| grep::captures(&query, old), &around)
    })
    .await
    .map_err(|e| invalid("view", &e.to_string()))?;
    let mut answer = answer.unwrap_or(PreviewAnswer {
        path: p.path.as_str().to_owned(),
        diff: String::new(),
        plus: 0,
        minus: 0,
        hunks: Vec::new(),
        skipped: Vec::new(),
    });
    answer.skipped = skipped;
    Ok(answer)
}

/// The preview's knowledge of PATH from RUN: each match's definition (its first line and name) and the lines of the
/// matches P leaves unticked.
fn around_of(run: &Run, path: &str, p: &EditsParams) -> edits::Around {
    let off: HashSet<&str> = p.off.iter().flatten().map(String::as_str).collect();
    let mut around = edits::Around::default();
    for f in run.files.iter().filter(|f| f.file == path) {
        for (i, (m, n)) in f.ms.iter().zip(&f.ns).enumerate() {
            let id = run::match_id(run.id, *n);
            if let Some(Some(def)) = f.ctx.get(i) {
                around
                    .defs
                    .insert(id.clone(), (def.line_start, def.name.clone()));
            }
            if off.contains(id.as_str()) {
                around.kept.push(m.line);
            }
        }
    }
    around
}

/// `search/apply`: change set P.change written (`apply.rs`); false when there is none of the caller's to write.
pub fn apply_change(f: &Front, c: &Caller, p: ApplyParams) -> Result<bool, Error> {
    let front = f.core.views.front.get().and_then(std::sync::Weak::upgrade);
    let front = front.ok_or_else(|| invalid("view", "the hub is starting"))?;
    Ok(apply::apply(&front, c.conn_id, p.change, p.open))
}

/// `search/applied`: the editor's answer to `search-apply`.
pub fn applied(f: &Front, _c: &Caller, p: AppliedParams) -> Result<bool, Error> {
    Ok(f.core.views.greps.changes.answer(p))
}

/// `search/undo`: change set P.change put back (`apply.rs`); false when there is none of the caller's.
pub fn undo_change(f: &Front, c: &Caller, p: UndoParams) -> Result<bool, Error> {
    let front = f.core.views.front.get().and_then(std::sync::Weak::upgrade);
    let front = front.ok_or_else(|| invalid("view", "the hub is starting"))?;
    Ok(apply::undo(&front, c.conn_id, p.change, p.open))
}

/// RUN's matches P hands off (P.ids, else all but P.off), by file in the run's order: (handed, hidden paths left out).
fn handed_of(run: &Run, p: &HandoffParams) -> (Vec<handoff::Handed>, Vec<String>) {
    let ids: Option<HashSet<&str>> = p
        .ids
        .as_ref()
        .map(|v| v.iter().map(String::as_str).collect());
    let off: HashSet<&str> = p.off.iter().flatten().map(String::as_str).collect();
    let (mut handed, mut hidden) = (Vec::new(), Vec::new());
    for f in &run.files {
        let rel = Path::new(&f.file)
            .strip_prefix(&run.query.root)
            .map(|r| r.to_string_lossy().into_owned())
            .unwrap_or_else(|_| f.file.clone());
        let shown = p.hidden || grep::searched(grep::Ignore::Index, &rel);
        for (i, (m, n)) in f.ms.iter().zip(&f.ns).enumerate() {
            let id = run::match_id(run.id, *n);
            let take = match &ids {
                Some(ids) => ids.contains(id.as_str()),
                None => !off.contains(id.as_str()),
            };
            if !take {
                continue;
            }
            if !shown {
                if hidden.last() != Some(&rel) {
                    hidden.push(rel.clone());
                }
                continue;
            }
            handed.push(handoff::Handed {
                id,
                path: f.file.clone(),
                rel: rel.clone(),
                line: m.line,
                col: m.col,
                old: m.text.clone(),
                text: format!("{}{}{}", m.before, m.text, m.after),
                ctx: f.ctx.get(i).cloned().flatten().map(|d| d.name.clone()),
                snap: f.snap.clone(),
            });
        }
    }
    (handed, hidden)
}

/// What RUN searched, in a line: the text (a regexp, case, word) and the globs.
fn query_line(q: &Query) -> String {
    let mut s = format!("{:?}", q.text);
    let how: Vec<&str> = [
        (q.regexp, "a regular expression"),
        (q.case, "case matched"),
        (q.word, "whole words"),
    ]
    .into_iter()
    .filter_map(|(on, w)| on.then_some(w))
    .collect();
    if !how.is_empty() {
        s.push_str(&format!(" ({})", how.join(", ")));
    }
    if !q.include.is_empty() {
        s.push_str(&format!(", in {}", q.include.join(" ")));
    }
    if !q.exclude.is_empty() {
        s.push_str(&format!(", not in {}", q.exclude.join(" ")));
    }
    s
}

/// A new worker of PROFILE for ROOT's hand-off, in a worktree of its own from ROOT's HEAD, registered as a worker so
/// the Work space's review lists it: its session id and worktree.
/// A new chat of PROFILE in ROOT (the view's checkout), paired: it edits the user's buffers through the editor.  The
/// matrix decides as for any pair (`agents/pair`: `chat.project-edit` not never); a refusal ends the chat.
async fn handoff_pair(f: &Front, c: &Caller, root: &Path, profile: &str) -> Result<String, Error> {
    let started = f
        .core
        .agents
        .start(
            f,
            runstav::methods::agents::StartParams {
                profile: runstav::types::Bounded(profile.to_owned()),
                cwd: runstav::types::AbsPath::new(root.to_string_lossy().into_owned()).ok(),
                task: None,
                job: None,
                role: Some(runstav::methods::matrix::Role::Chat),
                about: None,
                document: None,
                env: None,
            },
            c,
        )
        .await?;
    let paired = match f.core.agents.find(started.id.as_str()) {
        Ok(s) => s.pair_toggle(true).await,
        Err(e) => Err(e),
    };
    if let Err(e) = paired {
        let _ = f.core.agents.kill(started.id.as_str()).await;
        return Err(e);
    }
    Ok(started.id)
}

async fn handoff_worker(
    f: &Front,
    c: &Caller,
    root: &Path,
    profile: &str,
) -> Result<(String, PathBuf), Error> {
    let base = crate::runner::tick::git(root, &["rev-parse", "--verify", "HEAD"])
        .await
        .map_err(|e| {
            invalid(
                "to",
                &format!("no commit to start a worktree from: {}", e.stderr),
            )
        })?;
    let name = format!(
        "search-{}",
        &runstav::proof::nonce().map_err(|e| invalid("to", &e.to_string()))?[..8]
    );
    let tree = f
        .core
        .runs
        .git()
        .task_worktree(root, "search", &name, base.trim())
        .await
        .map_err(|e| invalid("to", &format!("no worktree: {}", e.stderr)))?;
    let started = f
        .core
        .agents
        .start(
            f,
            runstav::methods::agents::StartParams {
                profile: runstav::types::Bounded(profile.to_owned()),
                cwd: runstav::types::AbsPath::new(tree.path.to_string_lossy().into_owned()).ok(),
                task: None,
                job: None,
                role: Some(runstav::methods::matrix::Role::Worker),
                about: None,
                document: None,
                env: None,
            },
            c,
        )
        .await?;
    let _ = f.core.runs.git().touched(&tree.path).await;
    let cwd = tree.path.to_string_lossy().into_owned();
    let reg = norn::write::agents::AgentRegister {
        id: started.id.clone(),
        kind: Some("worker".into()),
        cwd: Some(cwd.clone()),
        worktree: Some(cwd),
        branch: Some(tree.branch.clone()),
        base: Some(tree.base.clone()),
        ..Default::default()
    };
    let now = crate::clock::wall_secs();
    if let Err(e) = f
        .writer
        .write(
            &crate::runner::service(),
            "coord/agent-register",
            move |tx| norn::write::agents::agent_register(tx, reg.clone(), now).map(|_| ()),
        )
        .await
    {
        tracing::warn!(
            sid = started.id,
            "the hand-off's worker is not registered: {e:?}"
        );
    }
    Ok((started.id, tree.path))
}

/// `search/handoff`: VIEW's matches to an agent with a brief (`handoff.rs`): a new worker in its own worktree, or a live
/// session (which edits in its own folder: a worker's worktree, a paired chat's checkout). The hand-off is watched.
pub async fn handoff(f: &Front, c: &Caller, p: HandoffParams) -> Result<HandoffAnswer, Error> {
    let views = &f.core.views;
    let (root, query, replace, (handed, hidden)) = views
        .greps
        .current(c.conn_id, &p.view, |run| {
            (
                run.query.root.clone(),
                query_line(&run.query),
                run.replace.clone(),
                handed_of(run, &p),
            )
        })
        .ok_or_else(|| invalid("view", "the view has no search"))?;
    if handed.is_empty() {
        return Err(invalid(
            "ids",
            "no match to hand off (hidden paths are left out unless asked)",
        ));
    }
    let (session, tree, new) = match &p.to {
        HandoffTo::Session { id } => {
            let s = f.core.agents.find(id.as_str())?;
            let tree = f
                .core
                .agents
                .worktree(id.as_str())
                .unwrap_or_else(|| root.clone());
            drop(s);
            (id.as_str().to_owned(), tree, false)
        }
        HandoffTo::New { profile } => {
            let (sid, tree) = handoff_worker(f, c, &root, profile).await?;
            (sid, tree, true)
        }
        HandoffTo::Pair { profile } => (
            handoff_pair(f, c, &root, profile).await?,
            root.clone(),
            false,
        ),
    };
    let rows: Vec<String> = handed.iter().map(handoff::row).collect();
    let changed = {
        let h = handed.clone();
        crate::clock::blocking(move || handoff::changed_since(&h))
            .await
            .unwrap_or_default()
    };
    let ids: Vec<String> = handed.iter().map(|m| m.id.clone()).collect();
    let id = views.greps.handoffs.add(handoff::Handoff {
        conn: c.conn_id,
        view: p.view.clone(),
        session: session.clone(),
        tree: tree.clone(),
        matches: handed,
        rows: rows.clone(),
        at: crate::clock::now(),
        served: 0,
        edited: false,
    });
    let replace = (!replace.is_empty()).then_some(replace.as_str());
    let (text, sent, more) = handoff::brief(
        &id,
        p.instruction.as_str(),
        &query,
        replace,
        &rows,
        &changed,
    );
    if let Err(e) = f.core.agents.send(&session, text) {
        views.greps.handoffs.forget(&id);
        return Err(e);
    }
    // the handed-off rows show the agent's mark (a new worker's comes later: `search/handoff-mark`)
    if let Some(mark) = &p.mark {
        mark_handed(f, c, &p.view, &ids, mark);
    }
    if let Some(front) = views.front.get().and_then(std::sync::Weak::upgrade) {
        handoff::watch(front, c.clone(), id.clone(), session.clone());
    }
    Ok(HandoffAnswer {
        handoff: id,
        session,
        worktree: new.then(|| tree.to_string_lossy().into_owned()),
        ids,
        sent,
        more,
        hidden,
    })
}

/// VIEW's rows of match IDS show MARK, redrawn.
fn mark_handed(f: &Front, c: &Caller, view: &str, ids: &[String], mark: &HandoffMark) {
    let views = &f.core.views;
    let mark = AgentMark {
        face: mark.face.clone(),
        glyph: mark.glyph.clone(),
    };
    views.greps.current(c.conn_id, view, |run| {
        for i in ids {
            run.handed.insert(i.clone(), mark.clone());
        }
        for patch in rebuild_patches(&mut lock(&views.store), c.conn_id, view, run) {
            f.send_to(c.conn_id, "view-patch", json!(patch));
        }
    });
}

/// `search/handoff-mark`: hand-off P.handoff's rows show P.mark; the asking connection's own hand-offs only.
pub fn handoff_mark(f: &Front, c: &Caller, p: HandoffMarkParams) -> Result<bool, Error> {
    let found = f.core.views.greps.handoffs.with(&p.handoff, |h| {
        (h.conn == c.conn_id).then(|| {
            (
                h.view.clone(),
                h.matches.iter().map(|m| m.id.clone()).collect::<Vec<_>>(),
            )
        })
    });
    let Some(Some((view, ids))) = found else {
        return Err(invalid(
            "handoff",
            "no such hand-off (ended, older than 24 h, or another window's)",
        ));
    };
    mark_handed(f, c, &view, &ids, &p.mark);
    Ok(true)
}

/// `search/handoff-state`: where hand-off P.handoff is (`handoff.rs`); the asking connection's own only.
pub async fn handoff_state(
    f: &Front,
    c: &Caller,
    p: HandoffStateParams,
) -> Result<HandoffState, Error> {
    let mine = f
        .core
        .views
        .greps
        .handoffs
        .with(&p.handoff, |h| h.conn == c.conn_id);
    if mine != Some(true) {
        return Err(invalid(
            "handoff",
            "no such hand-off (ended, older than 24 h, or another window's)",
        ));
    }
    handoff::state_of(f, c, &p.handoff)
        .await
        .ok_or_else(|| invalid("handoff", "the hand-off ended"))
}

/// `search_results` (the drgnx-search tool): page PAGE of hand-off ID's matches for SESSION, its own only.
pub(crate) fn handoff_page(
    f: &Front,
    id: &str,
    session: &str,
    page: usize,
) -> Result<String, String> {
    f.core.views.greps.handoffs.page(id, session, page)
}

#[cfg(test)]
mod tests;
