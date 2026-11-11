//! Git letters as rows: `git/letters` reads a repository's status (`git status --porcelain=v2 -z`, the trusted git
//! of `draugr::git`) on a thread of its own and sends the view one row per changed path and per shown folder; a
//! later call patches only what changed (the store diffs the rows). The letters are the Explorer's and Buffers'
//! git marks; the editor reads them from its view instead of parsing the status itself. Once read, a repository is
//! watched (`watch_repo`: its gitdir and refs, so a commit, checkout or `git add` in a terminal is seen) and read
//! again after each burst of changes, until the connection goes or its view closes.

use super::{Key, Store, Views, lock};
use crate::dispatch::Caller;
use crate::front::Front;
use draugr::git::{GitCall, Place, command, git_program};
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::git::LettersParams;
use runstav::methods::view::VIEW_MAX;
use runstav::wire::{Error, ErrorCode};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// More ignored entries than this are not listed (a `node_modules` tree is not a row each).
pub const IGNORED_LIMIT: usize = 20_000;

/// What git says about a path, strongest first by rank.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    Ignored,
    Untracked,
    Added,
    Renamed,
    Modified,
    Deleted,
    Conflict,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Ignored => "ignored",
            Kind::Untracked => "untracked",
            Kind::Added => "added",
            Kind::Renamed => "renamed",
            Kind::Modified => "modified",
            Kind::Deleted => "deleted",
            Kind::Conflict => "conflict",
        }
    }

    fn letter(self) -> &'static str {
        match self {
            Kind::Ignored => " ",
            Kind::Untracked => "U",
            Kind::Added => "A",
            Kind::Renamed => "R",
            Kind::Modified => "M",
            Kind::Deleted => "D",
            Kind::Conflict => "C",
        }
    }

    fn face(self) -> &'static str {
        match self {
            Kind::Ignored => "drgnx-git-ignored",
            Kind::Untracked | Kind::Added => "drgnx-git-added",
            Kind::Renamed | Kind::Modified => "drgnx-git-modified",
            Kind::Deleted => "drgnx-git-deleted",
            Kind::Conflict => "drgnx-git-conflict",
        }
    }
}

/// The branch the status header names.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Branch {
    /// None: detached.
    pub head: Option<String>,
    pub ahead: Option<u32>,
    pub behind: Option<u32>,
}

/// A repository's status: every changed path (relative, no trailing slash), the ignored ones unless too many.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Status {
    pub files: BTreeMap<String, Kind>,
    pub branch: Option<Branch>,
}

fn xy(xy: &str) -> Kind {
    let (x, y) = (
        xy.as_bytes()[0],
        xy.as_bytes().get(1).copied().unwrap_or(b'.'),
    );
    if x == b'D' || y == b'D' {
        Kind::Deleted
    } else if x == b'A' {
        Kind::Added
    } else if x == b'R' {
        Kind::Renamed
    } else {
        Kind::Modified
    }
}

/// The path after N space-separated fields of ENTRY (a path may hold spaces).
fn after_fields(entry: &str, n: usize) -> Option<&str> {
    let mut rest = entry;
    for _ in 0..n {
        rest = &rest[rest.find(' ')? + 1..];
    }
    Some(rest)
}

/// Read `git status --porcelain=v2 --branch -z --ignored=matching` OUTPUT; more than LIMIT ignored entries are all
/// left out.
pub fn parse(output: &[u8], limit: usize) -> Status {
    let text = String::from_utf8_lossy(output);
    let mut st = Status::default();
    let mut ignored: Vec<String> = Vec::new();
    let mut branch = Branch::default();
    let mut saw_branch = false;
    let mut skip = false;
    for e in text.split('\0').filter(|e| !e.is_empty()) {
        if std::mem::take(&mut skip) {
            continue; // the original path of a rename
        }
        let mut bytes = e.bytes();
        match bytes.next() {
            // "1 XY sub mH mI mW hH hI path"
            Some(b'1') => {
                if let Some(p) = after_fields(e, 8) {
                    st.files.insert(p.to_owned(), xy(&e[2..]));
                }
            }
            // "2 XY sub mH mI mW hH hI Xscore path", then the origin as a record of its own
            Some(b'2') => {
                if let Some(p) = after_fields(e, 9) {
                    st.files.insert(p.to_owned(), xy(&e[2..]));
                }
                skip = true;
            }
            // "u XY sub m1 m2 m3 mW h1 h2 h3 path"
            Some(b'u') => {
                if let Some(p) = after_fields(e, 10) {
                    st.files.insert(p.to_owned(), Kind::Conflict);
                }
            }
            Some(b'?') => {
                let p = e[2..].trim_end_matches('/');
                st.files.insert(p.to_owned(), Kind::Untracked);
            }
            Some(b'!') => ignored.push(e[2..].trim_end_matches('/').to_owned()),
            Some(b'#') => {
                if let Some(h) = e.strip_prefix("# branch.head ") {
                    saw_branch = true;
                    branch.head = (h != "(detached)").then(|| h.to_owned());
                } else if let Some(ab) = e.strip_prefix("# branch.ab ") {
                    let mut it = ab.split(' ');
                    let num = |s: Option<&str>| s.and_then(|s| s[1..].parse().ok());
                    branch.ahead = num(it.next());
                    branch.behind = num(it.next());
                }
            }
            _ => {}
        }
    }
    if ignored.len() <= limit {
        st.files
            .extend(ignored.into_iter().map(|p| (p, Kind::Ignored)));
    }
    if saw_branch {
        st.branch = Some(branch);
    }
    st
}

/// Each folder in SHOWN (and the repository's own, `.`) → the strongest status inside it that is not ignored,
/// `Added` for one holding untracked files. A folder with nothing changed has no entry. Folders nobody shows are
/// not worked out.
pub fn rollup(files: &BTreeMap<String, Kind>, shown: &BTreeSet<String>) -> BTreeMap<String, Kind> {
    let mut out: BTreeMap<String, Kind> = BTreeMap::new();
    for (path, kind) in files {
        if *kind == Kind::Ignored {
            continue;
        }
        let kind = if *kind == Kind::Untracked {
            Kind::Added
        } else {
            *kind
        };
        let mut dirs = vec!["."];
        let mut end = 0;
        while let Some(i) = path[end..].find('/') {
            end += i;
            dirs.push(&path[..end]);
            end += 1;
        }
        for d in dirs {
            if d == "." || shown.contains(d) {
                let slot = out.entry(d.to_owned()).or_insert(kind);
                if kind > *slot {
                    *slot = kind;
                }
            }
        }
    }
    out
}

fn file_row(path: &str, kind: Kind) -> Row {
    let mut b = RowBuilder::new(format!("f:{path}"));
    b.push(kind.letter(), Some(kind.face()));
    b.prop(0, 1, "drgnx-git-status", json!(kind.name()));
    b.finish()
}

fn folder_row(path: &str, kind: Kind) -> Row {
    let mut b = RowBuilder::new(format!("d:{path}"));
    b.push("●", Some(kind.face()));
    b.prop(0, 1, "drgnx-git-status", json!(kind.name()));
    b.finish()
}

/// STATUS as rows: a row per path, a row per shown folder with a change, and the branch.
pub fn rows(status: &Status, shown: &BTreeSet<String>) -> Vec<Row> {
    let mut rows: Vec<Row> = status.files.iter().map(|(p, k)| file_row(p, *k)).collect();
    rows.extend(
        rollup(&status.files, shown)
            .iter()
            .map(|(p, k)| folder_row(p, *k)),
    );
    if let Some(b) = &status.branch {
        let mut r = RowBuilder::new("branch");
        r.push(b.head.as_deref().unwrap_or("(detached)"), None);
        let end = r.pos();
        r.prop(
            0,
            end,
            "drgnx-git-branch",
            json!({"head": b.head, "ahead": b.ahead, "behind": b.behind}),
        );
        rows.push(r.finish());
    }
    rows
}

/// A read's number and its rows.
type Read = (u64, Vec<Row>);

/// A repository's last read status and the number of the read.
type Kept = (u64, Arc<Status>);

/// The latest rows of each (connection, view) and the number of the read that made them; the last status read of
/// each (connection, repository root), which the connection's Explorer listings mark their rows from.
#[derive(Default)]
pub(super) struct Letters {
    views: Mutex<BTreeMap<(u64, String), Read>>,
    statuses: Mutex<BTreeMap<(u64, PathBuf), Kept>>,
    next: std::sync::atomic::AtomicU64,
    /// Each (connection, repository root)'s watch: the view it reads for, its folders shown, and the channel that
    /// pokes or stops it.
    watches: Mutex<BTreeMap<(u64, PathBuf), Watch>>,
}

/// A repository's watch ([`watch_repo`]): what a read gives the view, and its channel.
struct Watch {
    view: String,
    shown: Arc<Mutex<BTreeSet<String>>>,
    tx: Sender<Heard>,
}

impl Letters {
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.views).retain(|(c, _), _| *c != conn);
        lock(&self.statuses).retain(|(c, _), _| *c != conn);
        lock(&self.watches).retain(|(c, _), w| {
            if *c == conn {
                let _ = w.tx.send(Heard::Stop);
            }
            *c != conn
        });
    }

    /// The next read's number.
    fn number(&self) -> u64 {
        self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1
    }

    /// CONN's repositories that hold or sit in one of PATHS were perhaps changed outside git (a file made or removed
    /// under a watched Explorer folder): their watches read them again.
    pub(super) fn poke(&self, conn: u64, paths: &[PathBuf]) {
        for ((c, root), w) in lock(&self.watches).iter() {
            if *c == conn
                && paths
                    .iter()
                    .any(|p| p.starts_with(root) || root.starts_with(p))
            {
                let _ = w.tx.send(Heard::Changed);
            }
        }
    }

    /// CONN's repositories' roots and their last read statuses.
    pub(super) fn statuses(&self, conn: u64) -> Vec<(PathBuf, Arc<Status>)> {
        lock(&self.statuses)
            .iter()
            .filter(|((c, _), _)| *c == conn)
            .map(|((_, root), (_, st))| (root.clone(), st.clone()))
            .collect()
    }

    /// Keep READ's STATUS of ROOT for CONN unless a newer read of it came first; whether it changed.
    fn keep(&self, conn: u64, root: PathBuf, read: u64, status: Status) -> bool {
        let mut statuses = lock(&self.statuses);
        let slot = statuses.entry((conn, root)).or_insert((0, Arc::default()));
        if slot.0 > read || *slot.1 == status {
            return false;
        }
        *slot = (read, Arc::new(status));
        true
    }

    pub(super) fn stop(&self, conn: u64, view: &str) {
        lock(&self.views).remove(&(conn, view.to_owned()));
        lock(&self.watches).retain(|(c, _), w| {
            let mine = *c == conn && w.view == view;
            if mine {
                let _ = w.tx.send(Heard::Stop);
            }
            !mine
        });
    }
}

impl Views {
    /// The letters of VIEW for a class that just got its env; false when VIEW has none.
    pub(super) fn git_build(&self, f: &Front, key: &Key) -> bool {
        let views = lock(&self.letters.views);
        let Some((_, rows)) = views.get(&(key.0, key.1.clone())) else {
            return false;
        };
        if let Some(p) = lock(&self.store).publish(key, rows.clone(), &[]) {
            f.send_to(key.0, "view-patch", json!(p));
        }
        true
    }

    /// READ's rows are VIEW's now (a read a newer call overtook is dropped).
    fn git_publish(&self, f: &Front, conn: u64, view: &str, read: u64, rows: Vec<Row>) {
        let mut views = lock(&self.letters.views);
        let mine = views
            .entry((conn, view.to_owned()))
            .or_insert((0, Vec::new()));
        if mine.0 > read {
            return;
        }
        *mine = (read, rows.clone());
        let mut store = lock(&self.store);
        for k in keys(&store, conn, view) {
            if let Some(p) = store.publish(&k, rows.clone(), &[]) {
                f.send_to(conn, "view-patch", json!(p));
            }
        }
    }
}

fn keys(store: &Store, conn: u64, view: &str) -> Vec<Key> {
    store
        .classes(conn, view)
        .into_iter()
        .map(|c| (conn, view.to_owned(), c))
        .collect()
}

fn invalid(path: &str, message: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

/// Run git's status in ROOT.
fn read_status(root: &std::path::Path) -> Result<Vec<u8>, String> {
    let program = git_program().map_err(|e| e.to_string())?;
    let call = GitCall {
        place: Place::Trusted { read_only: true },
        allow_protocols: vec![],
        args: [
            "status",
            "--porcelain=v2",
            "--branch",
            "-z",
            "--ignored=matching",
            "--untracked-files=normal",
        ]
        .iter()
        .map(Into::into)
        .collect(),
    };
    let (argv, env) = command(&call).map_err(|e| e.to_string())?;
    let out = Command::new(&program.path)
        .args(argv)
        .envs(env)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .current_dir(root)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(out.stdout)
    } else {
        Err(String::from_utf8_lossy(&out.stderr)
            .lines()
            .next()
            .unwrap_or("git failed")
            .to_owned())
    }
}

/// The event `git-letters-error` for VIEW and ROOT: git's complaint ERROR.
pub fn error_event(view: &str, root: &std::path::Path, error: &str) -> serde_json::Value {
    json!({"view": view, "root": root.to_string_lossy(), "error": error})
}

/// `git/letters`: read ROOT's status on a thread and give VIEW the rows; answers at once.
pub fn letters(f: &Front, c: &Caller, p: LettersParams) -> Result<bool, Error> {
    let views = &f.core.views;
    if p.view.is_empty() || p.view.len() > VIEW_MAX {
        return Err(invalid("view", "a view id of 1 to 64 bytes"));
    }
    let root = PathBuf::from(p.root.as_str());
    if !root.is_dir() {
        return Err(invalid("root", "an existing folder"));
    }
    let shown: BTreeSet<String> = p.shown.unwrap_or_default().into_iter().collect();
    let Some(front) = views.front.get().cloned() else {
        return Err(invalid("view", "the hub is starting"));
    };
    let (conn, view) = (c.conn_id, p.view);
    let read = views.letters.number();
    // the repository's watch: started once per (connection, root); a later call names the view and folders it reads for
    let mut watches = lock(&views.letters.watches);
    match watches.get(&(conn, root.clone())) {
        Some(w) if w.view == view => *lock(&w.shown) = shown.clone(),
        _ => {
            let (tx, rx) = channel();
            let shown = Arc::new(Mutex::new(shown.clone()));
            let (w_front, w_root, w_view, kept) =
                (front.clone(), root.clone(), view.clone(), shown.clone());
            let watch_tx = tx.clone();
            std::thread::Builder::new()
                .name("git-watch".into())
                .spawn(move || {
                    watch_repo(&w_root, watch_tx, rx, &mut || {
                        let Some(f) = w_front.upgrade() else {
                            return false;
                        };
                        let read = f.core.views.letters.number();
                        let shown = lock(&kept).clone();
                        read_and_publish(&f, conn, &w_view, &w_root, &shown, read);
                        true
                    });
                })
                .map_err(|e| invalid("view", &e.to_string()))?;
            if let Some(old) = watches.insert(
                (conn, root.clone()),
                Watch {
                    view: view.clone(),
                    shown,
                    tx,
                },
            ) {
                let _ = old.tx.send(Heard::Stop);
            }
        }
    }
    drop(watches);
    std::thread::Builder::new()
        .name("git-letters".into())
        .spawn(move || {
            if let Some(f) = front.upgrade() {
                read_and_publish(&f, conn, &view, &root, &shown, read);
            }
        })
        .map_err(|e| invalid("view", &e.to_string()))?;
    Ok(true)
}

/// Read ROOT's status (read number READ) and give CONN's VIEW its rows (SHOWN: the folders it shows), the error event
/// when git cannot; a changed status draws CONN's Explorer listings again.
fn read_and_publish(
    f: &Front,
    conn: u64,
    view: &str,
    root: &Path,
    shown: &BTreeSet<String>,
    read: u64,
) {
    let out = match read_status(root) {
        Ok(out) => out,
        Err(e) => {
            f.send_to(conn, "git-letters-error", error_event(view, root, &e));
            return;
        }
    };
    let status = parse(&out, IGNORED_LIMIT);
    let rows = rows(&status, shown);
    f.core.views.git_publish(f, conn, view, read, rows);
    if f.core
        .views
        .letters
        .keep(conn, root.to_path_buf(), read, status)
    {
        f.core.views.explorer_decor_changed(f, conn);
    }
}

/// What a repository's watch hears: a change (from its watcher, or a poke), or the end.
#[derive(Debug)]
pub(crate) enum Heard {
    Changed,
    Stop,
}

/// A burst of changes is read once it is quiet this long...
const SETTLE: Duration = Duration::from_millis(50);
/// ...or this long after its first change (a `git commit` writes the index, the ref and the log in turn).
const SETTLE_MAX: Duration = Duration::from_millis(250);

/// The gitdir and the common dir of the repository at ROOT: `.git` itself, or for a linked worktree the folder its
/// `.git` file names and that folder's `commondir`; none outside a repository's top.
pub(crate) fn git_dirs(root: &Path) -> Option<(PathBuf, PathBuf)> {
    let dot = root.join(".git");
    if dot.is_dir() {
        return Some((dot.clone(), dot));
    }
    let text = std::fs::read_to_string(&dot).ok()?;
    let gitdir = root.join(text.strip_prefix("gitdir:")?.trim());
    let common = std::fs::read_to_string(gitdir.join("commondir"))
        .map(|c| gitdir.join(c.trim()))
        .unwrap_or_else(|_| gitdir.clone());
    Some((gitdir, common))
}

/// Watch the repository at ROOT for changes git makes (its gitdir's files: index, HEAD, packed-refs; the common
/// dir's refs, for a branch moved from anywhere) and call READ once after each burst settles (`SETTLE`, at most
/// `SETTLE_MAX`); a lock file's events and reads are not changes. TX is the watcher's sending end, RX hears it,
/// pokes (`Letters::poke`) and `Heard::Stop`. Ends on `Heard::Stop`, a closed channel, or READ answering false; the
/// watcher goes with it. Nothing is watched outside a repository's top (the pokes still read).
pub(crate) fn watch_repo(
    root: &Path,
    tx: Sender<Heard>,
    rx: Receiver<Heard>,
    read: &mut dyn FnMut() -> bool,
) {
    use notify::event::EventKind;
    use notify::{RecursiveMode, Watcher};
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if let Ok(ev) = &res {
            let locks = !ev.paths.is_empty()
                && ev
                    .paths
                    .iter()
                    .all(|p| p.extension().is_some_and(|e| e == "lock"));
            if matches!(ev.kind, EventKind::Access(_)) || locks {
                return;
            }
        }
        let _ = tx.send(Heard::Changed);
    })
    .ok();
    if let (Some(w), Some((gitdir, common))) = (watcher.as_mut(), git_dirs(root)) {
        let _ = w.watch(&gitdir, RecursiveMode::NonRecursive);
        if common != gitdir {
            let _ = w.watch(&common, RecursiveMode::NonRecursive);
        }
        let _ = w.watch(&common.join("refs"), RecursiveMode::Recursive);
    }
    loop {
        match rx.recv() {
            Ok(Heard::Changed) => {}
            Ok(Heard::Stop) | Err(_) => return,
        }
        // the watcher's thread waits for the file system, outside the hub: real time, whatever clock the hub runs on
        let end = crate::clock::real_now() + SETTLE_MAX;
        loop {
            let left = end.saturating_duration_since(crate::clock::real_now());
            if left.is_zero() {
                break;
            }
            match rx.recv_timeout(SETTLE.min(left)) {
                Ok(Heard::Changed) => {}
                Ok(Heard::Stop) | Err(RecvTimeoutError::Disconnected) => return,
                Err(RecvTimeoutError::Timeout) => break,
            }
        }
        if !read() {
            return;
        }
    }
}

#[cfg(test)]
mod tests;
