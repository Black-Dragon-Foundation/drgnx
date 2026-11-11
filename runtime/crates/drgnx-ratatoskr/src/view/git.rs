//! Git letters as rows: `git/letters` reads a repository's status (`git status --porcelain=v2 -z`, the trusted git
//! of `draugr::git`) on a thread of its own and sends the view one row per changed path and per shown folder; a
//! later call patches only what changed (the store diffs the rows). The letters are the Explorer's and Buffers'
//! git marks; the editor reads them from its view instead of parsing the status itself.

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
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

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
}

impl Letters {
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.views).retain(|(c, _), _| *c != conn);
        lock(&self.statuses).retain(|(c, _), _| *c != conn);
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
    let read = views
        .letters
        .next
        .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        + 1;
    let Some(front) = views.front.get().cloned() else {
        return Err(invalid("view", "the hub is starting"));
    };
    let (conn, view) = (c.conn_id, p.view);
    std::thread::Builder::new()
        .name("git-letters".into())
        .spawn(move || {
            let out = match read_status(&root) {
                Ok(out) => out,
                Err(e) => {
                    if let Some(f) = front.upgrade() {
                        f.send_to(conn, "git-letters-error", error_event(&view, &root, &e));
                    }
                    return;
                }
            };
            let status = parse(&out, IGNORED_LIMIT);
            let rows = rows(&status, &shown);
            if let Some(f) = front.upgrade() {
                f.core.views.git_publish(&f, conn, &view, read, rows);
                if f.core.views.letters.keep(conn, root, read, status) {
                    f.core.views.explorer_marks_changed(&f, conn);
                }
            }
        })
        .map_err(|e| invalid("view", &e.to_string()))?;
    Ok(true)
}

#[cfg(test)]
mod tests;
