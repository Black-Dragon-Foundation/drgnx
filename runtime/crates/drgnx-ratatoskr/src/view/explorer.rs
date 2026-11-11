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
use super::{Key, Views, git, icons, lock};
use crate::dispatch::Caller;
use crate::front::Front;
use drgnx_rows::{ImageId, Row, RowBuilder};
use runstav::methods::search::{ExplorerParams, ExplorerStarted};
use runstav::methods::view::{Display, ViewEnv};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::cmp::Ordering as Cmp;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The most roots a listing takes.
pub const ROOTS_MAX: usize = 16;
/// The most open folders a listing takes.
pub const EXPANDED_MAX: usize = 10_000;
/// The most entries the model and the rows hold (the editor names fewer, `explorer/subscribe`'s `window`); past them
/// its list `order` is a window of the listing (Sjá takes no longer list unwindowed).
const MODEL_WINDOW: usize = 20_000;
/// The fewest entries a window the editor names holds.
const WINDOW_MIN: usize = 50;
/// A burst of changes is read again once no change came for this long ...
const SETTLE: Duration = Duration::from_millis(30);
/// ... or this long after its first change, whichever comes first.
const SETTLE_MAX: Duration = Duration::from_millis(100);
/// Names never shown by default (`drgnx-explorer-exclude-names`'s default).
const EXCLUDED: [&str; 6] = [".git", ".hg", ".svn", ".DS_Store", "__pycache__", ".#*"];
/// The most names `exclude` takes, and the most files `only` (Find) takes.
const EXCLUDE_MAX: usize = 256;
const ONLY_MAX: usize = 5000;

/// Names a listing leaves out: exact names, or globs with `*` (any run) and `?` (one character).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Exclude(Vec<String>);

impl Default for Exclude {
    fn default() -> Self {
        Exclude(EXCLUDED.iter().map(|s| (*s).to_owned()).collect())
    }
}

impl Exclude {
    pub fn new(names: Vec<String>) -> Self {
        Exclude(names)
    }

    /// Whether NAME is left out.
    pub fn matches(&self, name: &str) -> bool {
        self.0.iter().any(|p| glob(p.as_bytes(), name.as_bytes()))
    }
}

/// Whether NAME matches the glob PAT (`*` any run, `?` one byte, else itself).
fn glob(pat: &[u8], name: &[u8]) -> bool {
    let (mut p, mut n, mut star, mut mark) = (0, 0, None, 0);
    while n < name.len() {
        if p < pat.len() && (pat[p] == b'?' || pat[p] == name[n]) {
            (p, n) = (p + 1, n + 1);
        } else if p < pat.len() && pat[p] == b'*' {
            (star, mark, p) = (Some(p), n, p + 1);
        } else if let Some(s) = star {
            (p, mark, n) = (s + 1, mark + 1, mark + 1);
        } else {
            return false;
        }
    }
    pat[p..].iter().all(|c| *c == b'*')
}

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

/// One piece of a name's [`NameKey`]: a character, or a run of digits (its first character, and its value as the
/// digits without leading zeros).
#[derive(Clone, Debug)]
enum Tok {
    Ch(char),
    Num(char, String),
}

impl Ord for Tok {
    /// Two digit runs by value (fewer digits first, then the digits); a digit run against a character by its first.
    fn cmp(&self, other: &Self) -> Cmp {
        match (self, other) {
            (Tok::Num(_, x), Tok::Num(_, y)) => x.len().cmp(&y.len()).then_with(|| x.cmp(y)),
            (Tok::Num(c, _), Tok::Ch(d))
            | (Tok::Ch(c), Tok::Num(d, _))
            | (Tok::Ch(c), Tok::Ch(d)) => c.cmp(d),
        }
    }
}

impl PartialOrd for Tok {
    fn partial_cmp(&self, other: &Self) -> Option<Cmp> {
        Some(self.cmp(other))
    }
}

impl PartialEq for Tok {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Cmp::Equal
    }
}

impl Eq for Tok {}

/// What [`natural`] compares of a name, made once per name (a sort compares each name many times): the downcased name
/// as characters and digit runs, compared piece by piece, a name that runs out first coming first.
type NameKey = Vec<Tok>;

fn name_key(name: &str) -> NameKey {
    let mut key = Vec::with_capacity(name.len());
    let mut chars = name
        .to_lowercase()
        .chars()
        .collect::<Vec<_>>()
        .into_iter()
        .peekable();
    while let Some(c) = chars.next() {
        if c.is_ascii_digit() {
            let mut run = String::from(c);
            while let Some(d) = chars.next_if(char::is_ascii_digit) {
                run.push(d);
            }
            key.push(Tok::Num(c, run.trim_start_matches('0').to_owned()));
        } else {
            key.push(Tok::Ch(c));
        }
    }
    key
}

/// Natural, case-insensitive order (`file2` before `file10`), as Lisp's `string-version-lessp` of downcased names.
pub fn natural(a: &str, b: &str) -> Cmp {
    name_key(a).cmp(&name_key(b))
}

/// DIR's entries as (NAME, FOLDER), folders first, then in natural order; EXCLUDE's names left out. A link to a
/// folder is a folder. A folder that cannot be read has none.
pub fn read_folder(dir: &Path, exclude: &Exclude) -> Vec<(String, bool)> {
    let mut out: Vec<(String, bool)> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if exclude.matches(&name) {
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
    sort_folder(&mut out);
    out
}

/// Folders first, then natural order.
fn sort_folder(out: &mut [(String, bool)]) {
    out.sort_by_cached_key(|(name, folder)| (std::cmp::Reverse(*folder), name_key(name)));
}

/// Each folder read: its entries, (name, folder?) pairs.
type Folders = HashMap<PathBuf, Vec<(String, bool)>>;

/// Find's tree: the FILES under ROOTS and the folders above them, as each folder's entries (sorted) and the set of
/// open folders (every one of them). A file under no root is left out.
pub fn only_tree(roots: &[PathBuf], files: &[PathBuf]) -> (Folders, HashSet<String>) {
    let mut kids: Folders = HashMap::new();
    let mut open = HashSet::new();
    for file in files {
        let Some(root) = roots.iter().find(|r| file.starts_with(r) && file != *r) else {
            continue;
        };
        let mut at = file.as_path();
        let mut dir = false;
        while at != root.as_path() {
            let (Some(parent), Some(name)) = (at.parent(), at.file_name()) else {
                break;
            };
            let entry = (name.to_string_lossy().into_owned(), dir);
            let list = kids.entry(parent.to_path_buf()).or_default();
            if !list.contains(&entry) {
                list.push(entry);
            }
            open.insert(root_id(parent));
            (at, dir) = (parent, true);
        }
    }
    for list in kids.values_mut() {
        sort_folder(list);
    }
    (kids, open)
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

/// The entries a window of WINDOW entries from FROM holds in a listing of LEN: FROM clamped so the window is full.
pub fn window_range(len: usize, window: usize, from: Option<usize>) -> std::ops::Range<usize> {
    let from = from.unwrap_or(0).min(len.saturating_sub(window));
    from..len.min(from + window)
}

/// The model of ENTRIES: a `tree` of path nodes in pre-order, a folder open (flag 1) when its entries are listed. It
/// holds at most WINDOW entries, from entry FROM (`view/window`; none: the first; clamped so the window is full): past
/// them `order` is a window of the listing. The folders above
/// a window's first entry are nodes too, outside `order`: Sjá shows an entry only under its open folders.
pub(crate) fn explorer_doc_in(entries: &[Entry], window: usize, from: Option<usize>) -> Doc {
    let mut d = Doc {
        descriptor: json!({
            "scheme": "tree",
            "chain_kinds": [],
            "match_fields": ["label"],
            "lists": ["order"],
            "classes": ["selected", "match", "dim", "ticked"],
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

/// A level's indent in logical px when the editor names none (the comfortable density's `tree-indent`).
pub const INDENT: u32 = 12;

/// How one display class draws the rows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RowLook {
    /// On a graphical display, in device px: a level's indent, an icon's size and the gap either side of the icon
    /// (window-dark.html `.row`, 6 px); none on a terminal (text guides and chevrons).
    pub gui: Option<(u32, u32, u32)>,
    /// The listing has one root, whose row is hidden (the island's header names it).
    pub one_root: bool,
}

impl RowLook {
    /// The look of ENV's class for a listing of ROOTS roots with levels INDENT logical px apart, sizes in device px at
    /// the env's scale rounded half up (`drgnx-px`).
    pub fn of(env: &ViewEnv, indent: u32, roots: usize) -> Self {
        let px = |v: f32| (f64::from(v) * f64::from(env.scale) + 0.5 + 1e-9).floor() as u32;
        RowLook {
            gui: matches!(env.display, Display::Gui)
                .then(|| (px(indent as f32), px(icons::SIZE), px(6.0))),
            one_root: roots == 1,
        }
    }
}

/// Each entry's git status (by path) where its repository's status was read: a file's own, a folder's strongest
/// inside it, `Ignored` (or `Untracked`) under an ignored (or untracked) folder.
pub type Marks = HashMap<String, git::Kind>;

/// Who is here by path (`agents/presence/subscribe`'s model, [`crate::work::presence::here`]): the ordinals of the
/// agents changing a file, or a file inside a folder.
pub type Here = BTreeMap<String, BTreeSet<u32>>;

/// What a listing's rows show besides the entries: the git marks, and who is here.
#[derive(Default)]
pub struct Decor {
    pub git: Marks,
    pub here: Arc<Here>,
}

/// The marks of ENTRIES from STATUSES, each a repository's root and its last read status.
pub fn marks_of(entries: &[Entry], statuses: &[(PathBuf, Arc<git::Status>)]) -> Marks {
    let mut marks = Marks::new();
    for (root, st) in statuses {
        let root = root_id(root);
        let rel = |p: &str| -> Option<String> {
            if p == root {
                Some(".".into())
            } else {
                p.strip_prefix(root.as_str())?
                    .strip_prefix('/')
                    .map(str::to_owned)
            }
        };
        let shown: BTreeSet<String> = entries
            .iter()
            .filter(|e| e.dir)
            .filter_map(|e| rel(&e.path))
            .collect();
        let folders = git::rollup(&st.files, &shown);
        for e in entries {
            let Some(r) = rel(&e.path) else { continue };
            // an ignored or untracked folder's entries are not listed one by one: they take its status
            let mut above = r.as_str();
            let inherited = loop {
                match above.rfind('/') {
                    Some(i) => above = &above[..i],
                    None => break None,
                }
                if let Some(k @ (git::Kind::Ignored | git::Kind::Untracked)) = st.files.get(above) {
                    break Some(*k);
                }
            };
            let own = if e.dir {
                st.files
                    .get(&r)
                    .filter(|k| matches!(k, git::Kind::Ignored | git::Kind::Untracked))
                    .or_else(|| folders.get(&r))
            } else {
                st.files.get(&r)
            };
            if let Some(k) = inherited.or(own.copied()) {
                marks.insert(e.path.clone(), k);
            }
        }
    }
    marks
}

/// E's row in LOOK: the guides and chevron (on a graphical display the indents as spaces, the chevron and the file
/// or folder icon as images with the gap either side), then the name; the path over all of it, the git status over
/// the name (`drgnx-git-status`, which the editor draws as the mark at the right edge), an ignored name dimmed. A
/// single root's row is invisible. The ordinals of the agents here go over the name too (`drgnx-agents-here`, a list:
/// the editor draws their badge, whose marks and colours are its own). Icons go into IMAGES.
fn entry_row(
    e: &Entry,
    mark: Option<git::Kind>,
    here: Option<&BTreeSet<u32>>,
    look: &RowLook,
    images: &mut BTreeMap<ImageId, String>,
) -> Row {
    let guide = "drgnx-explorer-guide";
    let mut b = RowBuilder::new(e.path.clone());
    // a hidden root's row is its name alone: an image is drawn even on invisible text
    let hidden = e.depth == 0 && look.one_root;
    match look.gui.filter(|_| !hidden) {
        Some((indent, icon, gap)) => {
            for _ in 1..e.depth.max(1) {
                b.space(indent, icon, guide);
            }
            let mut image = |b: &mut RowBuilder, name: &str, alt: &str| {
                if let Some((id, svg)) = icons::svg(name, icon) {
                    images.insert(id, svg);
                    b.image(id, alt);
                } else {
                    b.push(alt, None);
                }
            };
            let at = b.pos();
            match (e.dir, e.open) {
                (true, true) => image(&mut b, "chevron-down", "▾"),
                (true, false) => image(&mut b, "chevron-right", "▸"),
                (false, _) => {
                    b.push(" ", None);
                }
            }
            b.space(gap, icon, guide);
            let kind = match (e.dir, e.open) {
                (true, true) => "folder-open",
                (true, false) => "folder",
                (false, _) => icons::file_icon(&e.label),
            };
            image(&mut b, kind, " ");
            b.space(gap, icon, guide);
            let end = b.pos();
            b.face(at, end, guide);
        }
        None if hidden => {}
        None => {
            let chevron = match (e.dir, e.open) {
                (false, _) => "  ",
                (true, true) => "▾ ",
                (true, false) => "▸ ",
            };
            let guides = "│ ".repeat(e.depth.saturating_sub(1));
            b.push(&format!("{guides}{chevron}"), Some(guide));
        }
    }
    let name = b.pos();
    let face = match (e.depth, e.dir, mark) {
        (_, _, Some(git::Kind::Ignored)) => "drgnx-git-ignored",
        (0, _, _) => "drgnx-explorer-root",
        (_, true, _) => "drgnx-explorer-directory",
        _ => "drgnx-explorer-file",
    };
    b.push(&display(&e.label), Some(face));
    let end = b.pos();
    if let Some(k) = mark.filter(|k| *k != git::Kind::Ignored) {
        b.prop(name, end, "drgnx-git-status", json!(k.name()));
    }
    if let Some(ords) = here.filter(|o| !o.is_empty()) {
        b.prop(name, end, "drgnx-agents-here", json!(ords));
    }
    b.prop(0, end, "drgnx-work-id", json!(e.path));
    if hidden {
        b.prop(0, end, "invisible", json!(true));
    }
    b.finish()
}

/// The rows of ENTRIES in LOOK with their DECOR, one per entry keyed by its path, and the icons they name (each
/// once).
pub fn explorer_rows(
    entries: &[Entry],
    decor: &Decor,
    look: &RowLook,
) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let mut images = BTreeMap::new();
    let rows = entries
        .iter()
        .map(|e| {
            let mark = decor.git.get(&e.path).copied();
            entry_row(e, mark, decor.here.get(&e.path), look, &mut images)
        })
        .collect();
    (rows, images.into_iter().collect())
}

/// What a listing's thread hears after its listing: changed paths, a watch that lost events (read every folder
/// again), a new subscribe of its view (list again as that says), or the end of the listing.
pub(crate) enum Heard {
    Changed(Vec<PathBuf>),
    Rescan,
    Relist(Box<Listing>),
    Stop,
}

/// What one listing of a view lists: its number, the roots, the open folders, whether chains join, the names left out.
#[derive(Clone, Debug)]
pub(crate) struct Listing {
    pub id: u64,
    pub roots: Vec<PathBuf>,
    pub expanded: HashSet<String>,
    pub compact: bool,
    pub exclude: Exclude,
}

/// Folders a listing's thread keeps read (and watched) beyond the ones its listing shows: closed ones, so opening one
/// again reads nothing.
const KEPT_CLOSED: usize = 64;

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

/// List AT (its roots, its open folders, chains joined when it says, its names left out) and hand the entries to SEND;
/// then watch every folder read and, after each burst of changes settles (`SETTLE`, at most `SETTLE_MAX`), read the
/// changed folders again and hand over the entries when they differ from the last (SEND's third argument says the watch
/// found them). A `Heard::Relist` (a new subscribe of the view) lists again at once as it says, from the folders read
/// so far, and is always handed over: the thread, its watcher and what it has read last the view's whole life, so
/// opening a folder again reads nothing and no change falls between two watchers (the closed folders kept are at most
/// [`KEPT_CLOSED`]). The watcher sends on CHAN's sender; its receiver hears it, the relistings and `Heard::Stop`. Ends
/// on `Heard::Stop`, CANCEL, a closed channel, or SEND answering false; the watcher goes with it.
pub(crate) fn list_and_watch(
    first: Listing,
    cancel: &AtomicBool,
    (tx, rx): (Sender<Heard>, Receiver<Heard>),
    send: &mut dyn FnMut(&Listing, Vec<Entry>, bool) -> bool,
) {
    let mut at = first;
    let mut cache: Folders = HashMap::new();
    // the listing's entries, and the folders it read (from the cache or the disk)
    let list = |at: &Listing, cache: &mut Folders| {
        let mut used = HashSet::new();
        let entries = list_tree(&at.roots, &at.expanded, at.compact, cancel, &mut |d| {
            used.insert(d.to_path_buf());
            cache
                .entry(d.to_path_buf())
                .or_insert_with(|| read_folder(d, &at.exclude))
                .clone()
        });
        entries.map(|e| (e, used))
    };
    let Some((mut last, _)) = list(&at, &mut cache) else {
        return;
    };
    // watched before the listing goes out: a change made once it is seen is never missed
    let mut w = watcher(tx);
    let mut watching = HashSet::new();
    rewatch(&mut w, &mut watching, cache.keys().cloned().collect());
    if !send(&at, last.clone(), false) {
        return;
    }
    loop {
        let (mut dirty, mut all, mut next) = (HashSet::new(), false, None);
        let hear = |h: Heard,
                    dirty: &mut HashSet<PathBuf>,
                    all: &mut bool,
                    next: &mut Option<Box<Listing>>| {
            match h {
                Heard::Changed(paths) => {
                    for p in paths {
                        if let Some(parent) = p.parent() {
                            dirty.insert(parent.to_path_buf());
                        }
                        dirty.insert(p);
                    }
                }
                Heard::Rescan => *all = true,
                Heard::Relist(l) => *next = Some(l),
                Heard::Stop => return false,
            }
            true
        };
        let Ok(h) = rx.recv() else { return };
        if !hear(h, &mut dirty, &mut all, &mut next) {
            return;
        }
        // a burst settles; a relisting does not wait (the editor waits for it), but takes what is already heard
        // the watcher's thread waits for the file system, outside the hub: real time, whatever clock the hub runs on
        let end = crate::clock::real_now() + SETTLE_MAX;
        loop {
            let left = end.saturating_duration_since(crate::clock::real_now());
            let h = if next.is_some() {
                match rx.try_recv() {
                    Ok(h) => h,
                    Err(std::sync::mpsc::TryRecvError::Empty) => break,
                    Err(std::sync::mpsc::TryRecvError::Disconnected) => return,
                }
            } else if left.is_zero() {
                break;
            } else {
                match rx.recv_timeout(SETTLE.min(left)) {
                    Ok(h) => h,
                    Err(RecvTimeoutError::Disconnected) => return,
                    Err(RecvTimeoutError::Timeout) => break,
                }
            };
            if !hear(h, &mut dirty, &mut all, &mut next) {
                return;
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
        let relisted = next.is_some();
        if let Some(l) = next {
            if l.exclude != at.exclude {
                cache.clear();
            }
            at = *l;
        }
        let Some((now, used)) = list(&at, &mut cache) else {
            return;
        };
        if cache.len() > used.len() + KEPT_CLOSED {
            cache.retain(|d, _| used.contains(d));
        }
        rewatch(&mut w, &mut watching, cache.keys().cloned().collect());
        if relisted || now != last {
            if !send(&at, now.clone(), !relisted) {
                return;
            }
            last = now;
        }
    }
}

/// What a listing's model and rows are made with: a level's indent in logical px and how many roots the listing has
/// (the rows' look), and how many entries a window holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Shape {
    pub indent: u32,
    pub roots: usize,
    pub window: usize,
}

/// One view's listing: its number, its cancel flag and the channel that stops its watch, the entries it sent, its
/// shape, and the entry its window must hold once listed (a reveal).
struct Run {
    id: u64,
    cancel: Arc<AtomicBool>,
    stop: Sender<Heard>,
    entries: Option<Arc<Vec<Entry>>>,
    shape: Shape,
    around: Option<String>,
    /// Its thread watches (`list_and_watch`) and takes a new subscribe as a `Heard::Relist`; a Find's does not.
    watch: bool,
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
    /// Who is here per connection, the last its presence subscription saw.
    here: Mutex<BTreeMap<u64, Arc<Here>>>,
}

impl Explorers {
    /// Start VIEW's listing (the one before is stopped): its number, cancel flag and channel (the watcher's sending
    /// end, and the end its thread hears on). The entries sent so far stay.
    /// Hand VIEW's watching thread a new subscribe (LISTING as made by MAKE from its new number) with its SHAPE and
    /// AROUND: its number, or none when VIEW has no such thread (none yet, a Find's, or it ended).
    fn relist(
        &self,
        conn: u64,
        view: &str,
        shape: Shape,
        around: Option<String>,
        make: impl FnOnce(u64) -> Listing,
    ) -> Option<u64> {
        let mut runs = lock(&self.runs);
        let run = runs.get_mut(&(conn, view.to_owned())).filter(|r| r.watch)?;
        let id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        // sent under the lock: two subscribes reach the thread in the order their numbers were given
        run.stop.send(Heard::Relist(Box::new(make(id)))).ok()?;
        (run.id, run.shape, run.around) = (id, shape, around);
        Some(id)
    }

    fn start(
        &self,
        conn: u64,
        view: &str,
        shape: Shape,
        around: Option<String>,
        watch: bool,
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
                shape,
                around,
                watch,
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

    /// CONN's who is here (empty before its presence came).
    fn here(&self, conn: u64) -> Arc<Here> {
        lock(&self.here).get(&conn).cloned().unwrap_or_default()
    }

    /// Keep HERE as CONN's; whether it changed.
    fn keep_here(&self, conn: u64, here: Here) -> bool {
        let mut all = lock(&self.here);
        if all.get(&conn).is_some_and(|h| **h == here) {
            return false;
        }
        all.insert(conn, Arc::new(here));
        true
    }

    /// Stop every listing of CONN.
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.here).remove(&conn);
        lock(&self.runs).retain(|(c, _), r| {
            if *c == conn {
                r.end();
            }
            *c != conn
        });
    }

    /// Keep ENTRIES as VIEW's when its listing is still listing ID, and run THEN with them, its shape and the entry its
    /// window must hold (taken: once per listing) — the lock held, so a newer listing's entries go out after these; none
    /// when a newer listing or a close came first.
    fn finish<R>(
        &self,
        conn: u64,
        view: &str,
        id: u64,
        entries: Vec<Entry>,
        then: impl FnOnce(&[Entry], Shape, Option<String>) -> R,
    ) -> Option<R> {
        let mut runs = lock(&self.runs);
        let run = runs.get_mut(&(conn, view.to_owned()))?;
        if run.id != id {
            return None;
        }
        let r = then(&entries, run.shape, run.around.take());
        run.entries = Some(Arc::new(entries));
        Some(r)
    }

    /// VIEW's entries, when a listing sent some, with its shape.
    fn entries(&self, conn: u64, view: &str) -> Option<(Arc<Vec<Entry>>, Shape)> {
        let runs = lock(&self.runs);
        let run = runs.get(&(conn, view.to_owned()))?;
        Some((run.entries.clone()?, run.shape))
    }

    /// The views of CONN with a listing.
    fn views_of(&self, conn: u64) -> Vec<String> {
        lock(&self.runs)
            .keys()
            .filter(|(c, _)| *c == conn)
            .map(|(_, v)| v.clone())
            .collect()
    }
}

impl Views {
    /// The model and rows of VIEW's listing for a class that just got its env; false when VIEW has no listing.
    pub(super) fn explorer_build(&self, f: &Front, key: &Key) -> bool {
        let Some((entries, shape)) = self.explorers.entries(key.0, &key.1) else {
            return false;
        };
        let from = self.window_from(key.0, &key.1, "order");
        self.publish_model(
            f,
            key.0,
            &key.1,
            explorer_doc_in(&entries, shape.window, from),
        );
        let decor = self.explorer_decor(key.0, &entries);
        self.explorer_rows_to(f, key, &entries, &decor, shape, from);
        true
    }

    /// The decor of CONN's listing of ENTRIES: the marks from CONN's statuses, and who is here.
    fn explorer_decor(&self, conn: u64, entries: &[Entry]) -> Decor {
        Decor {
            git: marks_of(entries, &self.letters.statuses(conn)),
            here: self.explorers.here(conn),
        }
    }

    /// The rows of ENTRIES' window from FROM (as the model's `order` holds it) with their DECOR for KEY's class (its
    /// env's look), and the icons they name.
    fn explorer_rows_to(
        &self,
        f: &Front,
        key: &Key,
        entries: &[Entry],
        decor: &Decor,
        shape: Shape,
        from: Option<usize>,
    ) {
        let shown = &entries[window_range(entries.len(), shape.window, from)];
        self.publish_built(f, key, |env, _| {
            explorer_rows(shown, decor, &RowLook::of(env, shape.indent, shape.roots))
        });
    }

    /// Every class of CONN's VIEW gets the rows of ENTRIES' window from FROM.
    fn explorer_rows_all(
        &self,
        f: &Front,
        conn: u64,
        view: &str,
        entries: &[Entry],
        shape: Shape,
        from: Option<usize>,
    ) {
        let decor = self.explorer_decor(conn, entries);
        let classes = lock(&self.store).classes(conn, view);
        for class in classes {
            self.explorer_rows_to(
                f,
                &(conn, view.to_owned(), class),
                entries,
                &decor,
                shape,
                from,
            );
        }
    }

    /// CONN's decor changed (`git/letters` read a status, who is here moved): every listing of CONN draws its rows
    /// again; only the rows that changed go out.
    pub(super) fn explorer_decor_changed(&self, f: &Front, conn: u64) {
        for view in self.explorers.views_of(conn) {
            let Some((entries, shape)) = self.explorers.entries(conn, &view) else {
                continue;
            };
            let from = self.window_from(conn, &view, "order");
            self.explorer_rows_all(f, conn, &view, &entries, shape, from);
        }
    }

    /// `view/window` of CONN's VIEW: its listing's model and rows again, with `order`'s window where the editor asked
    /// (the rows the window dropped go, the ones it added come); false when VIEW has no listing.
    pub(super) fn explorer_window(&self, f: &Front, conn: u64, view: &str) -> bool {
        let Some((entries, shape)) = self.explorers.entries(conn, view) else {
            return false;
        };
        let from = self.window_from(conn, view, "order");
        self.publish_model(f, conn, view, explorer_doc_in(&entries, shape.window, from));
        self.explorer_rows_all(f, conn, view, &entries, shape, from);
        true
    }

    /// The thread's hand-over of listing ID's entries (dropped when VIEW's listing is not listing ID any more): the
    /// model, then the rows to every class, of the window (moved to hold the listing's `around` when it falls
    /// outside). False when they were dropped.
    fn explorer_listed(
        &self,
        f: &Front,
        conn: u64,
        view: &str,
        id: u64,
        entries: Vec<Entry>,
    ) -> bool {
        self.explorers
            .finish(conn, view, id, entries, |entries, shape, around| {
                let mut from = self.window_from(conn, view, "order");
                let at = around.and_then(|a| entries.iter().position(|e| e.path == a));
                if let Some(i) =
                    at.filter(|i| !window_range(entries.len(), shape.window, from).contains(i))
                {
                    let want = i.saturating_sub(shape.window / 4);
                    lock(&self.store).set_window(conn, view, "order", want);
                    from = Some(want);
                }
                self.publish_model(f, conn, view, explorer_doc_in(entries, shape.window, from));
                self.explorer_rows_all(f, conn, view, entries, shape, from);
            })
            .is_some()
    }

    /// Who is here for CONN's workspace (by path, the ordinals there) after a presence change: kept, and CONN's
    /// listings drawn again when it differs from the last.
    pub fn explorer_here(&self, f: &Front, conn: u64, here: Here) {
        if self.explorers.keep_here(conn, here) {
            self.explorer_decor_changed(f, conn);
        }
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
    let exclude = match p.exclude {
        Some(names) if names.len() > EXCLUDE_MAX => {
            return Err(invalid("exclude", "at most 256 names"));
        }
        Some(names) => Exclude::new(names),
        None => Exclude::default(),
    };
    let only: Option<Vec<PathBuf>> = match p.only {
        Some(files) if files.len() > ONLY_MAX => return Err(invalid("only", "at most 5000 files")),
        Some(files) => Some(files.iter().map(|f| PathBuf::from(f.as_str())).collect()),
        None => None,
    };
    let window = match p.window {
        Some(w) if !(WINDOW_MIN..=MODEL_WINDOW).contains(&(w as usize)) => {
            return Err(invalid("window", "50 to 20000 entries"));
        }
        Some(w) => w as usize,
        None => MODEL_WINDOW,
    };
    let shape = Shape {
        indent: p.indent.unwrap_or(INDENT),
        roots: roots.len(),
        window,
    };
    let around = p.around.map(|a| root_id(Path::new(a.as_str())));
    let (conn, view) = (c.conn_id, p.view);
    let listing = |id| Listing {
        id,
        roots: roots.clone(),
        expanded: expanded.clone(),
        compact,
        exclude: exclude.clone(),
    };
    // the view's watching thread lists again (what it has read and watches stays); else a thread of its own
    if only.is_none()
        && let Some(id) = views
            .explorers
            .relist(conn, &view, shape, around.clone(), listing)
    {
        return Ok(ExplorerStarted { listing: id });
    }
    let (id, cancel, tx, rx) = views
        .explorers
        .start(conn, &view, shape, around, only.is_none());
    let first = listing(id);
    let Some(front) = views.front.get().cloned() else {
        return Err(invalid("view", "the hub is starting"));
    };
    std::thread::Builder::new()
        .name("explorer".into())
        .spawn(move || {
            if let Some(files) = only {
                // Find: the tree of the files it found, from nothing on disk, not watched
                let (kids, open) = only_tree(&roots, &files);
                let entries = list_tree(&roots, &open, compact, &cancel, &mut |d| {
                    kids.get(d).cloned().unwrap_or_default()
                });
                if let (Some(entries), Some(f)) = (entries, front.upgrade()) {
                    f.core.views.explorer_listed(&f, conn, &view, id, entries);
                }
                return;
            }
            list_and_watch(first, &cancel, (tx, rx), &mut |at, entries, watched| {
                front.upgrade().is_some_and(|f| {
                    // a name made or removed outside Emacs may change git's status too
                    if watched {
                        f.core.views.letters.poke(conn, &at.roots);
                    }
                    // a listing a newer subscribe overtook is dropped; the thread goes on (the newer one is queued)
                    f.core
                        .views
                        .explorer_listed(&f, conn, &view, at.id, entries);
                    true
                })
            });
        })
        .map_err(|e| invalid("view", &e.to_string()))?;
    Ok(ExplorerStarted { listing: id })
}

#[cfg(test)]
mod tests;
