//! The Source Control view (`scm/subscribe`, `scm/set`) and the git commands it runs (`git/stage`, `git/commit`, …;
//! docs/develop/hub.md, "The Source Control view").
//!
//! A view lists the repositories under the workspace's folders ([`repos::find`], on a thread), reads each one's status
//! (and, its graph unfolded, its history) on a thread, and sends its rows ([`rows::rows`]); the store diffs them, so a
//! later read patches only what changed. While the view lives, one thread per view watches every repository's git
//! dir (a commit, a stage or a checkout made anywhere) and reads the shown ones again every [`POLL`] for files changed
//! outside git; the editor asks again after a save and when its frame takes the focus. Every git command runs on a
//! blocking thread with a deadline ([`run::LOCAL`], [`run::COMMIT`]), and a remote one ([`remote`]) answers at once
//! and ends with the event `scm-remote`, so the editor never waits on git.

pub mod graph;
pub mod repos;
pub mod rows;
pub mod run;
pub mod status;
#[cfg(test)]
mod tests;

use super::explorer::{INDENT, RowLook};
use super::git::{Heard, git_dirs};
use super::{Key, Views, lock};
use crate::dispatch::Caller;
use crate::front::Front;
use repos::Found;
use run::{As, GitError, LOCAL};
use runstav::methods::scm::{
    Branch, Branches, Checkout, Commit, Committed, DeleteBranch, Paths, Remote, RemoteEvent,
    RemoteId, RemoteOp, Root, Set, Stash, StashOp, Subscribe, ViewAs, ViewId,
};
use runstav::methods::view::Display;
use runstav::wire::{Error, ErrorCode};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

/// How often a view reads its shown repositories again for files changed outside git and the editor.
pub const POLL: Duration = Duration::from_secs(3);

/// A repository's history as the graph shows it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Graph {
    pub commits: Vec<graph::Commit>,
    pub lanes: Vec<String>,
    pub outgoing: BTreeSet<String>,
    pub incoming: BTreeSet<String>,
}

/// A repository of a view: where it is, its last status (or git's complaint), its graph when read.
#[derive(Clone, Debug)]
pub struct RepoState {
    pub found: Found,
    pub status: Option<Result<status::Status, GitError>>,
    pub graph: Option<Graph>,
    /// How many commits the graph reads.
    pub graph_limit: usize,
}

impl RepoState {
    pub fn new(found: Found) -> Self {
        RepoState {
            found,
            status: None,
            graph: None,
            graph_limit: graph::PAGE,
        }
    }

    pub fn root_str(&self) -> String {
        self.found.root.to_string_lossy().into_owned()
    }

    fn changed(&self) -> bool {
        matches!(&self.status, Some(Ok(s)) if s.count() > 0)
    }
}

/// One view: the workspace's folders, the editor's file, list or tree, the repositories, the ones the user showed or
/// hid, the rows folded or unfolded against their default.
#[derive(Clone, Debug, Default)]
pub struct ViewState {
    pub roots: Vec<PathBuf>,
    pub active: Option<PathBuf>,
    pub view_as: ViewAs,
    pub repos: Vec<RepoState>,
    pub chosen: BTreeMap<PathBuf, bool>,
    pub toggled: BTreeSet<String>,
    /// The repositories were looked for.
    pub scanned: bool,
    /// Bumped by every subscribe: a scan an older one started is dropped.
    pub generation: u64,
}

impl ViewState {
    /// The repository holding the editor's file: the deepest one it is in.
    fn active_repo(&self) -> Option<&Path> {
        let a = self.active.as_ref()?;
        self.repos
            .iter()
            .map(|r| r.found.root.as_path())
            .filter(|r| a.starts_with(r))
            .max_by_key(|r| r.as_os_str().len())
    }

    /// Whether R is shown below the Repositories list: as the user chose, else when it is the only one, holds the
    /// editor's file or has changes.
    pub fn selected(&self, r: &RepoState) -> bool {
        if let Some(on) = self.chosen.get(&r.found.root) {
            return *on;
        }
        self.repos.len() == 1 || self.active_repo() == Some(r.found.root.as_path()) || r.changed()
    }

    fn repo_mut(&mut self, root: &Path) -> Option<&mut RepoState> {
        self.repos.iter_mut().find(|r| r.found.root == root)
    }
}

/// Every Source Control view, by (connection, view), the watch of each, and the remote commands running.
#[derive(Default)]
pub struct Scms {
    views: Mutex<BTreeMap<(u64, String), ViewState>>,
    watches: Mutex<BTreeMap<(u64, String), Sender<Heard>>>,
    remotes: Mutex<BTreeMap<u64, Arc<AtomicBool>>>,
    next: AtomicU64,
}

impl Scms {
    pub(super) fn stop(&self, conn: u64, view: &str) {
        let key = (conn, view.to_owned());
        lock(&self.views).remove(&key);
        if let Some(tx) = lock(&self.watches).remove(&key) {
            crate::soft::done(tx.send(Heard::Stop), "tx send");
        }
    }

    pub(super) fn gone(&self, conn: u64) {
        lock(&self.views).retain(|(c, _), _| *c != conn);
        lock(&self.watches).retain(|(c, _), tx| {
            if *c == conn {
                crate::soft::done(tx.send(Heard::Stop), "tx send");
            }
            *c != conn
        });
    }

    /// The views showing the repository at ROOT.
    fn showing(&self, root: &Path) -> Vec<(u64, String)> {
        lock(&self.views)
            .iter()
            .filter(|(_, v)| v.repos.iter().any(|r| r.found.root == root))
            .map(|(k, _)| k.clone())
            .collect()
    }
}

fn invalid(path: &str, message: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

fn failed(message: GitError) -> Error {
    Error {
        code: ErrorCode::Internal,
        message,
        path: None,
    }
}

impl Views {
    /// KEY's rows, built from its view's state; false when KEY is not a Source Control view.
    pub(super) fn scm_build(&self, f: &Front, key: &Key) -> bool {
        let Some(state) = lock(&self.scms.views).get(&(key.0, key.1.clone())).cloned() else {
            return false;
        };
        let now = crate::clock::wall_secs() as i64;
        self.publish_built(f, key, |env, fonts| {
            let width = |face: Option<&str>, text: &str| match env.display {
                Display::Gui => rodd::fit::width_in(fonts, face, text),
                Display::Tty => (text.chars().count() as u32 * env.cell.0.max(1)) as f32,
            };
            let room = rows::Room {
                width: &width,
                px: env.width_px as f32 - rodd::fit::SLACK,
            };
            rows::rows(&state, &RowLook::of(env, INDENT, 1), &room, now)
        });
        true
    }

    /// CONN's VIEW changed: its rows go to every class of it.
    fn scm_publish(&self, f: &Front, conn: u64, view: &str) {
        for class in self.classes(conn, view) {
            self.scm_build(f, &(conn, view.to_owned(), class));
        }
    }
}

/// Read the repository at ROOT: its status, and its graph when GRAPH (the newest LIMIT commits).
pub fn read_repo(
    root: &Path,
    graph: bool,
    limit: usize,
) -> (Result<status::Status, GitError>, Option<Graph>) {
    let args = [
        "status",
        "--porcelain=v2",
        "--branch",
        "-z",
        "--untracked-files=all",
    ];
    let st = run::git(root, As::Reader, &args, None, Some(LOCAL), None).map(|o| status::parse(&o));
    let g = match (&st, graph) {
        (Ok(st), true) => Some(read_graph(root, st, limit)),
        _ => None,
    };
    (st, g)
}

fn read_graph(root: &Path, st: &status::Status, limit: usize) -> Graph {
    if st.head.oid.is_none() {
        return Graph::default();
    }
    let n = format!("-n{limit}");
    let mut args = vec!["log", "--topo-order", "-z", &n, graph::FORMAT, "HEAD"];
    let up = st.head.upstream.clone().unwrap_or_default();
    if !up.is_empty() {
        args.push("@{upstream}");
    }
    let commits = run::git(root, As::Reader, &args, None, Some(LOCAL), None)
        .map(|o| graph::parse(&o))
        .unwrap_or_default();
    let (outgoing, incoming) = if up.is_empty() {
        Default::default()
    } else {
        run::git(
            root,
            As::Reader,
            &["rev-list", "--left-right", "HEAD...@{upstream}"],
            None,
            Some(LOCAL),
            None,
        )
        .map(|o| graph::sides(&o))
        .unwrap_or_default()
    };
    let lanes = graph::lanes(&commits);
    Graph {
        commits,
        lanes,
        outgoing,
        incoming,
    }
}

/// Read again the repositories ROOTS of CONN's VIEW (none: every shown one), on this thread, and publish.
fn reread(f: &Front, conn: u64, view: &str, roots: Option<&[PathBuf]>) {
    let todo: Vec<(PathBuf, bool, usize)> = {
        let views = lock(&f.core.views.scms.views);
        let Some(v) = views.get(&(conn, view.to_owned())) else {
            return;
        };
        v.repos
            .iter()
            .filter(|r| match roots {
                Some(rs) => rs.contains(&r.found.root),
                None => v.selected(r),
            })
            .map(|r| {
                let graph_open = rows::open(v, &format!("graph\t{}", r.root_str()));
                (
                    r.found.root.clone(),
                    graph_open && v.selected(r),
                    r.graph_limit,
                )
            })
            .collect()
    };
    let mut changed = false;
    for (root, graph, limit) in todo {
        let (st, g) = read_repo(&root, graph, limit);
        let mut views = lock(&f.core.views.scms.views);
        if let Some(r) = views
            .get_mut(&(conn, view.to_owned()))
            .and_then(|v| v.repo_mut(&root))
        {
            let st = Some(st);
            if r.status != st || (graph && r.graph != g) {
                r.status = st;
                if graph {
                    r.graph = g;
                }
                changed = true;
            }
        }
    }
    if changed {
        f.core.views.scm_publish(f, conn, view);
    }
}

/// Every view showing ROOT reads it again (after a command ran in it), on a thread.
fn reread_everywhere(f: &Front, root: &Path) {
    let Some(front) = f.core.views.front_weak() else {
        return;
    };
    let root = root.to_path_buf();
    std::thread::spawn(move || {
        let Some(f) = front.upgrade() else { return };
        for (conn, view) in f.core.views.scms.showing(&root) {
            reread(&f, conn, &view, Some(std::slice::from_ref(&root)));
        }
    });
}

/// Scan CONN's VIEW's folders (generation GENERATION), read every repository, then watch them, on this thread.
fn scan(front: Weak<Front>, conn: u64, view: String, generation: u64) {
    let Some(f) = front.upgrade() else { return };
    let roots = match lock(&f.core.views.scms.views).get(&(conn, view.clone())) {
        Some(v) if v.generation == generation => v.roots.clone(),
        _ => return,
    };
    let found = repos::find(&roots);
    {
        let mut views = lock(&f.core.views.scms.views);
        let Some(v) = views.get_mut(&(conn, view.clone())) else {
            return;
        };
        if v.generation != generation {
            return;
        }
        let mut old: BTreeMap<PathBuf, RepoState> = v
            .repos
            .drain(..)
            .map(|r| (r.found.root.clone(), r))
            .collect();
        v.repos = found
            .into_iter()
            .map(|fd| match old.remove(&fd.root) {
                Some(mut r) => {
                    r.found = fd;
                    r
                }
                None => RepoState::new(fd),
            })
            .collect();
        v.scanned = true;
    }
    f.core.views.scm_publish(&f, conn, &view);
    // every repository's status (the list shows each one's branch and count), then the shown ones' graphs
    let all: Vec<PathBuf> = lock(&f.core.views.scms.views)
        .get(&(conn, view.clone()))
        .map(|v| v.repos.iter().map(|r| r.found.root.clone()).collect())
        .unwrap_or_default();
    reread(&f, conn, &view, Some(&all));
    drop(f);
    watch(front, conn, view, &all);
}

/// Watch the git dirs of ROOTS for CONN's VIEW and read again what changed, and every shown repository each
/// [`POLL`], until the view closes or the front goes.
fn watch(front: Weak<Front>, conn: u64, view: String, roots: &[PathBuf]) {
    use notify::event::EventKind;
    use notify::{RecursiveMode, Watcher};
    let (tx, rx) = channel::<Heard>();
    let (htx, hrx) = channel::<PathBuf>();
    {
        let Some(f) = front.upgrade() else { return };
        if let Some(old) = lock(&f.core.views.scms.watches).insert((conn, view.clone()), tx.clone())
        {
            crate::soft::done(old.send(Heard::Stop), "old send");
        }
    }
    // each git dir's events name the repository they belong to
    let dirs: Vec<(PathBuf, PathBuf, PathBuf)> = roots
        .iter()
        .filter_map(|r| git_dirs(r).map(|(g, c)| (r.clone(), g, c)))
        .collect();
    let owners: Vec<(PathBuf, PathBuf)> = dirs
        .iter()
        .flat_map(|(r, g, c)| [(g.clone(), r.clone()), (c.join("refs"), r.clone())])
        .collect();
    let poke = tx.clone();
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(ev) = res else { return };
        if matches!(ev.kind, EventKind::Access(_)) {
            return;
        }
        for p in &ev.paths {
            if p.extension().is_some_and(|e| e == "lock") {
                continue;
            }
            if let Some((_, root)) = owners.iter().find(|(d, _)| p.starts_with(d)) {
                crate::soft::done(htx.send(root.clone()), "htx send");
                crate::soft::done(poke.send(Heard::Changed), "poke send");
            }
        }
    })
    .ok();
    if let Some(w) = watcher.as_mut() {
        for (_, g, c) in &dirs {
            crate::soft::done(w.watch(g, RecursiveMode::NonRecursive), "scm");
            if c != g {
                crate::soft::done(w.watch(c, RecursiveMode::NonRecursive), "scm");
            }
            crate::soft::done(w.watch(&c.join("refs"), RecursiveMode::Recursive), "scm");
        }
    }
    loop {
        let heard = rx.recv_timeout(POLL);
        if matches!(heard, Ok(Heard::Stop) | Err(RecvTimeoutError::Disconnected)) {
            return;
        }
        // a burst settles before it is read
        std::thread::sleep(Duration::from_millis(80));
        let mut changed: BTreeSet<PathBuf> = hrx.try_iter().collect();
        for h in rx.try_iter() {
            if matches!(h, Heard::Stop) {
                return;
            }
        }
        changed.extend(hrx.try_iter());
        let Some(f) = front.upgrade() else { return };
        match heard {
            Ok(_) => {
                let roots: Vec<PathBuf> = changed.into_iter().collect();
                reread(&f, conn, &view, Some(&roots));
            }
            Err(_) => reread(&f, conn, &view, None),
        }
    }
}

/// `scm/subscribe`: the view shows P's folders' repositories; they are looked for and read on a thread.
pub fn subscribe(f: &Front, c: &Caller, p: Subscribe) -> Result<bool, Error> {
    let roots: Vec<PathBuf> = p.roots.iter().map(|r| PathBuf::from(r.as_str())).collect();
    if let Some(r) = roots.iter().find(|r| !r.is_dir()) {
        return Err(invalid("roots", &format!("not a folder: {}", r.display())));
    }
    let Some(front) = f.core.views.front_weak() else {
        return Err(invalid("view", "the hub is starting"));
    };
    let key = (c.conn_id, p.view.clone());
    let generation = {
        let mut views = lock(&f.core.views.scms.views);
        let v = views.entry(key).or_default();
        if v.roots != roots {
            v.scanned = false;
        }
        v.roots = roots;
        v.active = p.active.map(|a| PathBuf::from(a.as_str()));
        v.view_as = p.view_as;
        v.generation += 1;
        v.generation
    };
    f.core.views.scm_publish(f, c.conn_id, &p.view);
    let (conn, view) = (c.conn_id, p.view);
    std::thread::Builder::new()
        .name("scm-scan".into())
        .spawn(move || scan(front, conn, view, generation))
        .map_err(|e| invalid("view", &e.to_string()))?;
    Ok(true)
}

/// `scm/set`: a change to the view; what it needs read again is read on a thread.
pub fn set(f: &Front, c: &Caller, p: Set) -> Result<bool, Error> {
    let key = (c.conn_id, p.view.clone());
    let mut again: Vec<PathBuf> = Vec::new();
    let all = p.refresh;
    {
        let mut views = lock(&f.core.views.scms.views);
        let Some(v) = views.get_mut(&key) else {
            return Err(invalid(
                "view",
                "not a Source Control view (scm/subscribe first)",
            ));
        };
        if let Some(a) = p.active {
            let a = PathBuf::from(a.as_str());
            v.active = Some(a);
            if let Some(r) = v.active_repo() {
                again.push(r.to_path_buf());
            }
        }
        if let Some(s) = p.select {
            let root = PathBuf::from(s.root.as_str());
            v.chosen.insert(root.clone(), s.on);
            again.push(root);
        }
        if let Some(va) = p.view_as {
            v.view_as = va;
        }
        if let Some(t) = p.toggle {
            if !v.toggled.remove(&t) {
                v.toggled.insert(t.clone());
            }
            if let Some(root) = t.strip_prefix("graph\t") {
                again.push(PathBuf::from(root));
            }
        }
        if let Some(m) = p.more {
            let root = PathBuf::from(m.as_str());
            if let Some(r) = v.repo_mut(&root) {
                r.graph_limit += graph::PAGE;
                again.push(root);
            }
        }
    }
    f.core.views.scm_publish(f, c.conn_id, &p.view);
    if all || !again.is_empty() {
        let front = f.core.views.front_weak();
        let (conn, view) = (c.conn_id, p.view);
        std::thread::spawn(move || {
            let Some(f) = front.and_then(|w| w.upgrade()) else {
                return;
            };
            reread(&f, conn, &view, (!all).then_some(again.as_slice()));
        });
    }
    Ok(true)
}

/// `scm/close`.
pub fn close(f: &Front, c: &Caller, p: ViewId) -> Result<bool, Error> {
    f.core.views.scms.stop(c.conn_id, &p.view);
    Ok(true)
}

/// ROOT as a folder that is a repository's top.
fn repo_root(root: &str) -> Result<PathBuf, Error> {
    let p = PathBuf::from(root);
    if !p.join(".git").exists() {
        return Err(invalid("root", "the top folder of a git repository"));
    }
    Ok(p)
}

/// Run git ARGS in ROOT as WHO on a blocking thread (STDIN, DEADLINE); no view reads the repository again.
async fn git_quiet(
    root: &Path,
    who: As,
    args: Vec<String>,
    stdin: Option<Vec<u8>>,
    deadline: Duration,
) -> Result<Vec<u8>, Error> {
    let r = root.to_path_buf();
    crate::clock::blocking(move || {
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        run::git(&r, who, &args, stdin.as_deref(), Some(deadline), None)
    })
    .await
    .map_err(|e| failed(e.to_string()))?
    .map_err(failed)
}

/// Run the user's git ARGS in ROOT on a blocking thread (STDIN, DEADLINE), then have the views showing it read it.
async fn user_git(
    f: &Front,
    root: PathBuf,
    args: Vec<String>,
    stdin: Option<Vec<u8>>,
    deadline: Duration,
) -> Result<Vec<u8>, Error> {
    let out = git_quiet(&root, As::User, args, stdin, deadline).await;
    reread_everywhere(f, &root);
    out
}

fn with_paths(head: &[&str], paths: &[String]) -> Vec<String> {
    head.iter()
        .map(|s| (*s).to_owned())
        .chain(std::iter::once("--".to_owned()))
        .chain(paths.iter().cloned())
        .collect()
}

/// Whether ROOT has a commit yet.
async fn has_head(root: &Path) -> bool {
    let r = root.to_path_buf();
    crate::clock::blocking(move || {
        run::git(
            &r,
            As::Reader,
            &["rev-parse", "--verify", "-q", "HEAD"],
            None,
            Some(LOCAL),
            None,
        )
        .is_ok()
    })
    .await
    .unwrap_or(false)
}

/// `git/stage`.
pub async fn stage(f: &Front, p: Paths) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    user_git(f, root, with_paths(&["add", "-A"], &p.paths), None, LOCAL).await?;
    Ok(true)
}

/// `git/unstage`: `restore --staged`, or before the first commit `rm --cached`.
pub async fn unstage(f: &Front, p: Paths) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    let head: &[&str] = if has_head(&root).await {
        &["restore", "--staged"]
    } else {
        &["rm", "--cached", "-r", "-q"]
    };
    user_git(f, root, with_paths(head, &p.paths), None, LOCAL).await?;
    Ok(true)
}

/// `git/discard`: the unstaged changes of tracked paths, back to the index's text.
pub async fn discard(f: &Front, p: Paths) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    user_git(
        f,
        root,
        with_paths(&["restore", "--worktree"], &p.paths),
        None,
        LOCAL,
    )
    .await?;
    Ok(true)
}

/// `git/commit`.  The views read the repository once, after the commit and the read of its sha (each `user_git` would
/// make them read it, and the status is read per repository: the second read only repeated the first).
pub async fn commit(f: &Front, p: Commit) -> Result<Committed, Error> {
    let root = repo_root(p.root.as_str())?;
    let done = commit_quiet(&root, &p).await;
    reread_everywhere(f, &root);
    done
}

async fn commit_quiet(root: &Path, p: &Commit) -> Result<Committed, Error> {
    if p.all {
        git_quiet(root, As::User, vec!["add".into(), "-A".into()], None, LOCAL).await?;
    }
    let mut args: Vec<String> = vec!["commit".into(), "-q".into()];
    if p.amend {
        args.push("--amend".into());
        if p.message.trim().is_empty() {
            args.push("--no-edit".into());
        }
    }
    let stdin = (!p.message.trim().is_empty()).then(|| p.message.clone().into_bytes());
    if stdin.is_some() {
        args.extend(["-F".into(), "-".into()]);
    }
    git_quiet(root, As::User, args, stdin, run::COMMIT).await?;
    let sha = git_quiet(
        root,
        As::Reader,
        vec!["rev-parse".into(), "HEAD".into()],
        None,
        LOCAL,
    )
    .await?;
    Ok(Committed {
        sha: String::from_utf8_lossy(&sha).trim().to_owned(),
    })
}

/// `git/undo-commit`.
pub async fn undo_commit(f: &Front, p: Root) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    let args = ["reset", "--soft", "HEAD~1"].map(String::from).to_vec();
    user_git(f, root, args, None, LOCAL).await?;
    Ok(true)
}

/// The remote a branch with no upstream is published to: `origin`, else the only one.
fn publish_remote(root: &Path) -> String {
    let out = run::git(root, As::Reader, &["remote"], None, Some(LOCAL), None).unwrap_or_default();
    let names: Vec<String> = String::from_utf8_lossy(&out)
        .lines()
        .map(str::to_owned)
        .collect();
    if names.len() == 1 && names[0] != "origin" {
        names[0].clone()
    } else {
        "origin".to_owned()
    }
}

/// `git/remote`: answers its id at once; a thread runs OP and sends `scm-remote` when it starts and ends.
pub fn remote(f: &Front, c: &Caller, p: Remote) -> Result<RemoteId, Error> {
    let root = repo_root(p.root.as_str())?;
    let scms = &f.core.views.scms;
    let id = scms.next.fetch_add(1, Ordering::Relaxed) + 1;
    let cancel = Arc::new(AtomicBool::new(false));
    lock(&scms.remotes).insert(id, cancel.clone());
    let Some(front) = f.core.views.front_weak() else {
        return Err(invalid("root", "the hub is starting"));
    };
    let (conn, op) = (c.conn_id, p.op);
    let root2 = root.clone();
    let event = move |f: &Front, state: &str, error: Option<String>| {
        let e = RemoteEvent {
            id,
            root: root_string(&root),
            op,
            state: state.to_owned(),
            error,
        };
        f.send_to(conn, "scm-remote", json!(e));
    };
    std::thread::Builder::new()
        .name("scm-remote".into())
        .spawn(move || {
            if let Some(f) = front.upgrade() {
                event(&f, "running", None);
            }
            let steps: Vec<Vec<String>> = match op {
                RemoteOp::Push => vec![vec!["push".into()]],
                RemoteOp::Pull => vec![vec!["pull".into()]],
                RemoteOp::Fetch => vec![vec!["fetch".into()]],
                RemoteOp::Sync => vec![vec!["pull".into()], vec!["push".into()]],
                RemoteOp::Publish => {
                    vec![vec![
                        "push".into(),
                        "-u".into(),
                        publish_remote(&root2),
                        "HEAD".into(),
                    ]]
                }
            };
            let mut result = Ok(Vec::new());
            for s in steps {
                let args: Vec<&str> = s.iter().map(String::as_str).collect();
                result = run::git(&root2, As::User, &args, None, None, Some(&cancel));
                if result.is_err() {
                    break;
                }
            }
            let Some(f) = front.upgrade() else { return };
            lock(&f.core.views.scms.remotes).remove(&id);
            match result {
                Ok(_) => event(&f, "done", None),
                Err(e) if e == run::STOPPED => event(&f, "stopped", None),
                Err(e) => event(&f, "failed", Some(e)),
            }
            reread_everywhere(&f, &root2);
        })
        .map_err(|e| invalid("root", &e.to_string()))?;
    Ok(RemoteId { id })
}

fn root_string(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

/// `git/remote-stop`: false when ID is not running.
pub fn remote_stop(f: &Front, p: RemoteId) -> Result<bool, Error> {
    Ok(match lock(&f.core.views.scms.remotes).get(&p.id) {
        Some(c) => {
            c.store(true, Ordering::Relaxed);
            true
        }
        None => false,
    })
}

/// `git for-each-ref` OUTPUT (`%(refname)NUL%(committerdate:unix)NUL%(HEAD)` per line) as the picker lists it: local
/// branches, then remote ones (not `*/HEAD`), each newest first (git sorted them).
pub fn parse_branches(output: &[u8]) -> Vec<Branch> {
    let mut local = Vec::new();
    let mut remote = Vec::new();
    for l in String::from_utf8_lossy(output).lines() {
        let mut it = l.split('\0');
        let (Some(name), Some(time), head) = (it.next(), it.next(), it.next()) else {
            continue;
        };
        let time = time.parse().unwrap_or(0);
        let current = head == Some("*");
        if let Some(n) = name.strip_prefix("refs/heads/") {
            local.push(Branch {
                name: n.to_owned(),
                remote: false,
                current,
                time,
            });
        } else if let Some(n) = name.strip_prefix("refs/remotes/")
            && !n.ends_with("/HEAD")
        {
            remote.push(Branch {
                name: n.to_owned(),
                remote: true,
                current: false,
                time,
            });
        }
    }
    local.extend(remote);
    local
}

/// `git/branches`.
pub async fn branches(p: Root) -> Result<Branches, Error> {
    let root = repo_root(p.root.as_str())?;
    let out = crate::clock::blocking(move || {
        let args = [
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname)%00%(committerdate:unix)%00%(HEAD)",
            "refs/heads",
            "refs/remotes",
        ];
        run::git(&root, As::Reader, &args, None, Some(LOCAL), None)
    })
    .await
    .map_err(|e| failed(e.to_string()))?
    .map_err(failed)?;
    Ok(Branches {
        branches: parse_branches(&out),
    })
}

/// `git/checkout`: a new branch (CREATE), a remote one as a local branch tracking it, else the branch.
pub async fn checkout(f: &Front, p: Checkout) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    let b = p.branch.clone();
    let r = root.clone();
    let remote_only = !p.create
        && crate::clock::blocking(move || {
            let is = |r#ref: &str| {
                run::git(
                    &r,
                    As::Reader,
                    &["show-ref", "--verify", "-q", r#ref],
                    None,
                    Some(LOCAL),
                    None,
                )
                .is_ok()
            };
            !is(&format!("refs/heads/{b}")) && is(&format!("refs/remotes/{b}"))
        })
        .await
        .unwrap_or(false);
    let args: Vec<String> = if p.create {
        vec!["switch".into(), "-c".into(), p.branch]
    } else if remote_only {
        vec!["switch".into(), "--track".into(), p.branch]
    } else {
        vec!["switch".into(), p.branch]
    };
    user_git(f, root, args, None, LOCAL).await?;
    Ok(true)
}

/// `git/delete-branch`.
pub async fn delete_branch(f: &Front, p: DeleteBranch) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    let flag = if p.force { "-D" } else { "-d" };
    user_git(
        f,
        root,
        vec!["branch".into(), flag.into(), p.branch],
        None,
        LOCAL,
    )
    .await?;
    Ok(true)
}

/// `git/stash`.
pub async fn stash(f: &Front, p: Stash) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    let args: Vec<String> = match p.op {
        StashOp::Push => vec!["stash".into(), "push".into(), "--include-untracked".into()],
        StashOp::Pop => vec!["stash".into(), "pop".into()],
    };
    user_git(f, root, args, None, LOCAL).await?;
    Ok(true)
}
