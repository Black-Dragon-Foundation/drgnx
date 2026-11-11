//! The Explorer's listing (`explorer/subscribe`; docs/develop/hub.md, "The Explorer"): the roots, and inside them the
//! folders the editor says are open, are read on a thread of the view's own; the entries become a `tree` model (one
//! path node per entry, the flag `expanded` on an open folder, the list `order` in pre-order) and one row per entry
//! (indent guides and chevron, the name, the path over the row as `drgnx-work-id`), sent to every class of the view.
//! A newer listing of a view stops the one before it (a stopped listing sends nothing), and the view's close or its
//! connection's end stops it too. The editor opens or closes a folder by asking again with the new set; the model and
//! rows that go out are the difference. The rows do not depend on the display class. After its listing the thread
//! watches the folders it read (`notify`, one folder each, not recursive: a closed folder is never watched) and, once a
//! burst of changes settles, reads the changed folders again and sends what differs; it ends with its listing.

use super::model::Doc;
use super::{Key, Views, lock};
use crate::dispatch::Caller;
use crate::front::Front;
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::search::{ExplorerParams, ExplorerStarted};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::cmp::Ordering as Cmp;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The most roots a listing takes.
pub const ROOTS_MAX: usize = 16;
/// The most open folders a listing takes.
pub const EXPANDED_MAX: usize = 10_000;
/// The entries the model holds; past them its list `order` is a window of the first ones (Sjá takes no longer list
/// unwindowed). The rows hold every entry.
const MODEL_WINDOW: usize = 20_000;
/// A burst of changes is read again once no change came for this long ...
const SETTLE: Duration = Duration::from_millis(30);
/// ... or this long after its first change, whichever comes first.
const SETTLE_MAX: Duration = Duration::from_millis(100);
/// Names never shown (the Explorer's `drgnx-explorer-exclude` default), besides `.#…` lock files.
const EXCLUDED: [&str; 5] = [".git", ".hg", ".svn", ".DS_Store", "__pycache__"];

/// One row of the tree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// The node id: the folder or file the row stands for (a joined row's last folder).
    pub path: String,
    /// The entry above it in the tree; none for a root.
    pub parent: Option<String>,
    /// As shown: a name, `src/app` for a joined row, a root's name in capitals.
    pub label: String,
    pub depth: usize,
    pub dir: bool,
    pub open: bool,
}

fn excluded(name: &str) -> bool {
    EXCLUDED.contains(&name) || name.starts_with(".#")
}

/// A digit run's value as a comparable (length, digits) pair without leading zeros.
fn digits(s: &[char], mut i: usize) -> (usize, String) {
    let mut run = String::new();
    while i < s.len() && s[i].is_ascii_digit() {
        run.push(s[i]);
        i += 1;
    }
    (i, run.trim_start_matches('0').to_owned())
}

/// Natural, case-insensitive order (`file2` before `file10`), as Lisp's `string-version-lessp` of downcased names.
pub fn natural(a: &str, b: &str) -> Cmp {
    let a: Vec<char> = a.to_lowercase().chars().collect();
    let b: Vec<char> = b.to_lowercase().chars().collect();
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if a[i].is_ascii_digit() && b[j].is_ascii_digit() {
            let (ni, x) = digits(&a, i);
            let (nj, y) = digits(&b, j);
            let c = x.len().cmp(&y.len()).then_with(|| x.cmp(&y));
            if c != Cmp::Equal {
                return c;
            }
            (i, j) = (ni, nj);
        } else {
            match a[i].cmp(&b[j]) {
                Cmp::Equal => (i, j) = (i + 1, j + 1),
                c => return c,
            }
        }
    }
    (a.len() - i).cmp(&(b.len() - j))
}

/// DIR's entries as (NAME, FOLDER), folders first, then in natural order; excluded names left out. A link to a
/// folder is a folder. A folder that cannot be read has none.
pub fn read_folder(dir: &Path) -> Vec<(String, bool)> {
    let mut out: Vec<(String, bool)> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if excluded(&name) {
                return None;
            }
            let folder = match e.file_type() {
                Ok(t) if t.is_dir() => true,
                Ok(t) if t.is_symlink() => std::fs::metadata(e.path()).is_ok_and(|m| m.is_dir()),
                _ => false,
            };
            Some((name, folder))
        })
        .collect();
    out.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| natural(&a.0, &b.0)));
    out
}

fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

/// A root's path as the node id: no trailing slash, except `/` itself.
fn root_id(root: &Path) -> String {
    let s = root.to_string_lossy();
    let t = s.trim_end_matches('/');
    if t.is_empty() { "/".into() } else { t.into() }
}

/// The entries of ROOTS: each root, then its folder's entries, recursing into the open ones (EXPANDED). COMPACT joins
/// an open folder whose only entry is a folder with it on one row; the chain ends at the first closed folder, which is
/// never read. READ lists a folder (sorted). None when CANCEL is set before the end.
pub fn list_tree(
    roots: &[PathBuf],
    expanded: &HashSet<String>,
    compact: bool,
    cancel: &AtomicBool,
    read: &mut dyn FnMut(&Path) -> Vec<(String, bool)>,
) -> Option<Vec<Entry>> {
    let mut out = Vec::new();
    for root in roots {
        let id = root_id(root);
        let name = Path::new(&id)
            .file_name()
            .map_or_else(|| id.clone(), |n| n.to_string_lossy().into_owned());
        out.push(Entry {
            path: id.clone(),
            parent: None,
            label: name.to_uppercase(),
            depth: 0,
            dir: true,
            open: true,
        });
        let kids = read(Path::new(&id));
        walk(kids, &id, 1, expanded, compact, cancel, read, &mut out)?;
    }
    Some(out)
}

#[allow(clippy::too_many_arguments)]
fn walk(
    kids: Vec<(String, bool)>,
    parent: &str,
    depth: usize,
    expanded: &HashSet<String>,
    compact: bool,
    cancel: &AtomicBool,
    read: &mut dyn FnMut(&Path) -> Vec<(String, bool)>,
    out: &mut Vec<Entry>,
) -> Option<()> {
    if cancel.load(Ordering::Relaxed) {
        return None;
    }
    for (name, dir) in kids {
        let mut label = name.clone();
        let mut path = join(parent, &name);
        let mut open = dir && expanded.contains(&path);
        let mut inner = if open {
            read(Path::new(&path))
        } else {
            Vec::new()
        };
        while compact && open {
            let [(next, true)] = inner.as_slice() else {
                break;
            };
            let next = next.clone();
            label = format!("{label}/{next}");
            path = join(&path, &next);
            open = expanded.contains(&path);
            inner = if open {
                read(Path::new(&path))
            } else {
                Vec::new()
            };
        }
        out.push(Entry {
            path: path.clone(),
            parent: Some(parent.to_owned()),
            label,
            depth,
            dir,
            open,
        });
        if open {
            walk(
                inner,
                &path,
                depth + 1,
                expanded,
                compact,
                cancel,
                read,
                out,
            )?;
        }
    }
    Some(())
}

/// NAME as one row shows it: control characters (a newline in a file name) as `^X`, as `drgnx-wb-display-name`.
fn display(name: &str) -> String {
    let mut s = String::with_capacity(name.len());
    for c in name.chars() {
        match c {
            '\u{7f}' => s.push_str("^?"),
            c if (c as u32) < 32 => {
                s.push('^');
                s.push(char::from(b'@' + c as u8));
            }
            c => s.push(c),
        }
    }
    s
}

/// The model of ENTRIES: a `tree` of path nodes in pre-order, a folder open (flag 1) when its entries are listed; past
/// [`MODEL_WINDOW`] entries `order` is a window of them, from FROM (`view/window`; none: the first).
pub fn explorer_doc(entries: &[Entry], from: Option<usize>) -> Doc {
    explorer_doc_in(entries, MODEL_WINDOW, from)
}

fn entry_node(e: &Entry) -> Value {
    let kind = match (e.depth, e.dir) {
        (0, _) => "root",
        (_, true) => "dir",
        _ => "file",
    };
    let mut node = json!({"id": e.path, "kind": kind, "flags": u8::from(e.open),
                          "fields": [["label", e.label], ["path", e.path], ["dir", i64::from(e.dir)]]});
    if let Some(p) = &e.parent {
        node["parent"] = json!(p);
    }
    node
}

/// [`explorer_doc`] holding at most WINDOW entries, from entry FROM (clamped so the window is full). The folders above
/// a window's first entry are nodes too, outside `order`: Sjá shows an entry only under its open folders.
fn explorer_doc_in(entries: &[Entry], window: usize, from: Option<usize>) -> Doc {
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
    let from = from.unwrap_or(0).min(entries.len().saturating_sub(window));
    let mut order = Vec::new();
    for e in entries.iter().skip(from).take(window) {
        d.nodes.insert(e.path.clone(), entry_node(e));
        order.push(e.path.clone());
    }
    if let Some(first) = entries.get(from).filter(|_| from > 0) {
        // pre-order: each folder above the first entry comes before it
        let mut parent = first.parent.as_deref();
        for e in entries[..from].iter().rev() {
            if parent.is_none() {
                break;
            }
            if Some(e.path.as_str()) == parent {
                d.nodes.insert(e.path.clone(), entry_node(e));
                parent = e.parent.as_deref();
            }
        }
    }
    if from > 0 || entries.len() > from + order.len() {
        d.windows.insert("order".into(), (entries.len(), from));
    }
    d.lists.insert("order".into(), order);
    d
}

/// E's row: the guides and chevron, then the name; the path over all of it.
fn entry_row(e: &Entry) -> Row {
    let chevron = match (e.dir, e.open) {
        (false, _) => "  ",
        (true, true) => "▾ ",
        (true, false) => "▸ ",
    };
    let mut b = RowBuilder::new(e.path.clone());
    let guides = "│ ".repeat(e.depth.saturating_sub(1));
    b.push(&format!("{guides}{chevron}"), Some("drgnx-explorer-guide"));
    let face = match (e.depth, e.dir) {
        (0, _) => "drgnx-explorer-root",
        (_, true) => "drgnx-explorer-directory",
        _ => "drgnx-explorer-file",
    };
    b.push(&display(&e.label), Some(face));
    let end = b.pos();
    b.prop(0, end, "drgnx-work-id", json!(e.path));
    b.finish()
}

/// The rows of ENTRIES, one per entry, keyed by its path.
pub fn explorer_rows(entries: &[Entry]) -> Vec<Row> {
    entries.iter().map(entry_row).collect()
}

/// What a listing's thread hears after its listing: changed paths, a watch that lost events (read every folder
/// again), or the end of the listing.
pub(crate) enum Heard {
    Changed(Vec<PathBuf>),
    Rescan,
    Stop,
}

/// A watcher sending what it sees in the folders it is given to TX. A change of a file's data or metadata is not
/// sent (the listing shows names only).
fn watcher(tx: Sender<Heard>) -> Option<notify::RecommendedWatcher> {
    use notify::EventKind;
    use notify::event::ModifyKind;
    notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let heard = match res {
            Ok(ev) if ev.need_rescan() => Heard::Rescan,
            Ok(ev) => match ev.kind {
                EventKind::Create(_)
                | EventKind::Remove(_)
                | EventKind::Modify(ModifyKind::Name(_)) => Heard::Changed(ev.paths),
                EventKind::Modify(ModifyKind::Any | ModifyKind::Other) => Heard::Changed(ev.paths),
                _ => return,
            },
            Err(_) => Heard::Rescan,
        };
        let _ = tx.send(heard);
    })
    .ok()
}

/// Watch exactly WANT with WATCHER (WATCHING: what it watches now). A folder that cannot be watched (gone, the
/// inotify limit) is left out and tried again on the next relisting.
fn rewatch(
    watcher: &mut Option<notify::RecommendedWatcher>,
    watching: &mut HashSet<PathBuf>,
    want: HashSet<PathBuf>,
) {
    use notify::{RecursiveMode, Watcher};
    let Some(w) = watcher.as_mut() else { return };
    for gone in watching.difference(&want) {
        let _ = w.unwatch(gone);
    }
    watching.retain(|d| want.contains(d));
    for d in want {
        if !watching.contains(&d) && w.watch(&d, RecursiveMode::NonRecursive).is_ok() {
            watching.insert(d);
        }
    }
}

/// List ROOTS (EXPANDED open, COMPACT joining chains) and hand the entries to SEND; then watch every folder that listing
/// read and, after each burst of changes settles (`SETTLE`, at most `SETTLE_MAX`), read the changed folders again and
/// hand over the entries when they differ from the last. The watcher sends on TX; RX hears it and `Heard::Stop`. Ends
/// on `Heard::Stop`, CANCEL, a closed channel, or SEND answering false; the watcher goes with it.
pub(crate) fn list_and_watch(
    roots: &[PathBuf],
    expanded: &HashSet<String>,
    compact: bool,
    cancel: &AtomicBool,
    tx: Sender<Heard>,
    rx: Receiver<Heard>,
    send: &mut dyn FnMut(Vec<Entry>) -> bool,
) {
    let mut cache: HashMap<PathBuf, Vec<(String, bool)>> = HashMap::new();
    let list = |cache: &mut HashMap<PathBuf, Vec<(String, bool)>>| {
        list_tree(roots, expanded, compact, cancel, &mut |d| {
            cache
                .entry(d.to_path_buf())
                .or_insert_with(|| read_folder(d))
                .clone()
        })
    };
    let Some(mut last) = list(&mut cache) else {
        return;
    };
    // watched before the listing goes out: a change made once it is seen is never missed
    let mut w = watcher(tx);
    let mut watching = HashSet::new();
    rewatch(&mut w, &mut watching, cache.keys().cloned().collect());
    if !send(last.clone()) {
        return;
    }
    loop {
        let (mut dirty, mut all) = (HashSet::new(), false);
        let hear = |h: Heard, dirty: &mut HashSet<PathBuf>, all: &mut bool| match h {
            Heard::Changed(paths) => {
                for p in paths {
                    if let Some(parent) = p.parent() {
                        dirty.insert(parent.to_path_buf());
                    }
                    dirty.insert(p);
                }
                true
            }
            Heard::Rescan => {
                *all = true;
                true
            }
            Heard::Stop => false,
        };
        let Ok(h) = rx.recv() else { return };
        if !hear(h, &mut dirty, &mut all) {
            return;
        }
        let end = Instant::now() + SETTLE_MAX;
        loop {
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            match rx.recv_timeout(SETTLE.min(left)) {
                Ok(h) => {
                    if !hear(h, &mut dirty, &mut all) {
                        return;
                    }
                }
                Err(RecvTimeoutError::Disconnected) => return,
                Err(RecvTimeoutError::Timeout) => break,
            }
        }
        if cancel.load(Ordering::Relaxed) {
            return;
        }
        if all {
            cache.clear();
        } else {
            cache.retain(|d, _| !dirty.contains(d));
        }
        let Some(now) = list(&mut cache) else { return };
        rewatch(&mut w, &mut watching, cache.keys().cloned().collect());
        if now != last {
            if !send(now.clone()) {
                return;
            }
            last = now;
        }
    }
}

/// One view's listing: its number, its cancel flag and the channel that stops its watch, the entries it sent.
struct Run {
    id: u64,
    cancel: Arc<AtomicBool>,
    stop: Sender<Heard>,
    entries: Option<Arc<Vec<Entry>>>,
}

impl Run {
    fn end(&self) {
        self.cancel.store(true, Ordering::Relaxed);
        let _ = self.stop.send(Heard::Stop);
    }
}

/// The listings, one per (connection, view).
#[derive(Default)]
pub(super) struct Explorers {
    runs: Mutex<BTreeMap<(u64, String), Run>>,
    next: AtomicU64,
}

impl Explorers {
    /// Start VIEW's listing (the one before is stopped): its number, cancel flag and channel (the watcher's sending
    /// end, and the end its thread hears on). The entries sent so far stay.
    fn start(
        &self,
        conn: u64,
        view: &str,
    ) -> (u64, Arc<AtomicBool>, Sender<Heard>, Receiver<Heard>) {
        let id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        let cancel = Arc::new(AtomicBool::new(false));
        let (tx, rx) = channel();
        let mut runs = lock(&self.runs);
        let entries = runs.remove(&(conn, view.to_owned())).and_then(|old| {
            old.end();
            old.entries
        });
        runs.insert(
            (conn, view.to_owned()),
            Run {
                id,
                cancel: cancel.clone(),
                stop: tx.clone(),
                entries,
            },
        );
        (id, cancel, tx, rx)
    }

    /// Stop VIEW's listing.
    pub(super) fn stop(&self, conn: u64, view: &str) {
        if let Some(r) = lock(&self.runs).remove(&(conn, view.to_owned())) {
            r.end();
        }
    }

    /// Stop every listing of CONN.
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.runs).retain(|(c, _), r| {
            if *c == conn {
                r.end();
            }
            *c != conn
        });
    }

    /// Keep ENTRIES as VIEW's when its listing is still listing ID, and run THEN with them (the lock held, so a newer
    /// listing's entries go out after these); none when a newer listing or a close came first.
    fn finish<R>(
        &self,
        conn: u64,
        view: &str,
        id: u64,
        entries: Vec<Entry>,
        then: impl FnOnce(&[Entry]) -> R,
    ) -> Option<R> {
        let mut runs = lock(&self.runs);
        let run = runs.get_mut(&(conn, view.to_owned()))?;
        if run.id != id {
            return None;
        }
        let r = then(&entries);
        run.entries = Some(Arc::new(entries));
        Some(r)
    }

    /// VIEW's entries, when a listing sent some.
    fn entries(&self, conn: u64, view: &str) -> Option<Arc<Vec<Entry>>> {
        lock(&self.runs)
            .get(&(conn, view.to_owned()))?
            .entries
            .clone()
    }
}

impl Views {
    /// The model and rows of VIEW's listing for a class that just got its env; false when VIEW has no listing.
    pub(super) fn explorer_build(&self, f: &Front, key: &Key) -> bool {
        let Some(entries) = self.explorers.entries(key.0, &key.1) else {
            return false;
        };
        let from = self.window_from(key.0, &key.1, "order");
        self.publish_model(f, key.0, &key.1, explorer_doc(&entries, from));
        if let Some(p) = lock(&self.store).publish(key, explorer_rows(&entries), &[]) {
            f.send_to(key.0, "view-patch", json!(p));
        }
        true
    }

    /// `view/window` of CONN's VIEW: its listing's model again, with `order`'s window where the editor asked; false
    /// when VIEW has no listing.
    pub(super) fn explorer_window(&self, f: &Front, conn: u64, view: &str) -> bool {
        let Some(entries) = self.explorers.entries(conn, view) else {
            return false;
        };
        let from = self.window_from(conn, view, "order");
        self.publish_model(f, conn, view, explorer_doc(&entries, from));
        true
    }

    /// The thread's hand-over of listing ID's entries (dropped when VIEW's listing is not listing ID any more): the
    /// model, then the rows to every class. False when they were dropped.
    fn explorer_listed(
        &self,
        f: &Front,
        conn: u64,
        view: &str,
        id: u64,
        entries: Vec<Entry>,
    ) -> bool {
        self.explorers
            .finish(conn, view, id, entries, |entries| {
                let from = self.window_from(conn, view, "order");
                self.publish_model(f, conn, view, explorer_doc(entries, from));
                let rows = explorer_rows(entries);
                let mut store = lock(&self.store);
                for class in store.classes(conn, view) {
                    let key = (conn, view.to_owned(), class);
                    if let Some(p) = store.publish(&key, rows.clone(), &[]) {
                        f.send_to(conn, "view-patch", json!(p));
                    }
                }
            })
            .is_some()
    }
}

fn invalid(path: &str, message: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

/// `explorer/subscribe`: stop VIEW's listing and list its roots and open folders on a thread of its own, which then
/// watches them (`list_and_watch`); the model and rows go to every class of VIEW.
pub fn subscribe(f: &Front, c: &Caller, p: ExplorerParams) -> Result<ExplorerStarted, Error> {
    let views = &f.core.views;
    if p.view.is_empty() || p.view.len() > runstav::methods::view::VIEW_MAX {
        return Err(invalid("view", "a view id of 1 to 64 bytes"));
    }
    if p.roots.is_empty() || p.roots.len() > ROOTS_MAX {
        return Err(invalid("roots", "1 to 16 folders"));
    }
    let roots: Vec<PathBuf> = p.roots.iter().map(|r| PathBuf::from(r.as_str())).collect();
    if let Some(i) = roots.iter().position(|r| !r.is_dir()) {
        return Err(invalid(&format!("roots/{i}"), "an existing folder"));
    }
    if p.expanded.len() > EXPANDED_MAX {
        return Err(invalid("expanded", "at most 10000 folders"));
    }
    let expanded: HashSet<String> = p
        .expanded
        .iter()
        .map(|e| root_id(Path::new(e.as_str())))
        .collect();
    let compact = p.compact.unwrap_or(true);
    let (conn, view) = (c.conn_id, p.view);
    let (id, cancel, tx, rx) = views.explorers.start(conn, &view);
    let Some(front) = views.front.get().cloned() else {
        return Err(invalid("view", "the hub is starting"));
    };
    std::thread::Builder::new()
        .name("explorer".into())
        .spawn(move || {
            list_and_watch(
                &roots,
                &expanded,
                compact,
                &cancel,
                tx,
                rx,
                &mut |entries| {
                    front
                        .upgrade()
                        .is_some_and(|f| f.core.views.explorer_listed(&f, conn, &view, id, entries))
                },
            );
        })
        .map_err(|e| invalid("view", &e.to_string()))?;
    Ok(ExplorerStarted { listing: id })
}

#[cfg(test)]
mod tests;
