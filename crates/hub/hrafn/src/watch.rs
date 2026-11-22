//! The file watcher behind a trait: what the shell feeds [`crate::fresh::Settle`], and what the edit history reads.
//!
//! One watcher instance serves a project and all its trees (the main checkout and its worktrees). Events carry the
//! key of the tree they belong to ([`Router`] decides: the longest registered root wins, so a nested worktree's file
//! goes to the worktree, never to main). On Linux and Android the backend is `inotify` driven directly with a mask of
//! our own (`InotifyWatch`: no `IN_OPEN`, no `IN_MODIFY`), one non-recursive watch per directory git does not ignore
//! (the [`Walker`]); on macOS it is `notify`'s FSEvents (`NotifyWatch`, one `paths_mut` batch per change). The quiet
//! period and the wait for the lock are the settle core's, not the watcher's.

use std::path::{Path, PathBuf};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};

/// The key of the project's main checkout among the trees of its watcher.
pub const MAIN_TREE: &str = "main";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WatchEvent {
    /// A file of tree TREE, relative to that tree's root.
    File { tree: String, rel: String },
    /// `HEAD`, the index or a ref of tree TREE changed.
    Git { tree: String },
    /// `index.lock` of tree TREE is there (true) or gone (false).
    Lock { tree: String, held: bool },
    /// The kernel queue overflowed (or the backend lost events): every tree of the instance is stale.
    Overflow,
}

impl WatchEvent {
    /// What this event means for the main checkout's tier 1. Events of other trees wake nothing there (a save in a
    /// worktree must not cost main a full listing); an overflow re-lists.
    pub fn main_fresh(&self) -> Option<crate::fresh::Fresh> {
        use crate::fresh::Fresh;
        match self {
            WatchEvent::File { tree, rel } if tree == MAIN_TREE => Some(Fresh::Save(rel.clone())),
            WatchEvent::Git { tree } if tree == MAIN_TREE => Some(Fresh::Git),
            WatchEvent::Lock { tree, held } if tree == MAIN_TREE => Some(Fresh::Lock(*held)),
            WatchEvent::Overflow => Some(Fresh::Git),
            _ => None,
        }
    }
}

/// A tree the watcher serves. The tree list is an input: the hub passes it in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeSpec {
    pub key: String,
    pub root: PathBuf,
    /// The tree's own gitdir: `<common>/worktrees/<n>` for a linked tree, the common dir for the main checkout.
    pub gitdir: PathBuf,
}

impl TreeSpec {
    /// The main checkout at ROOT (its gitdir is `ROOT/.git`).
    pub fn main(root: &Path) -> TreeSpec {
        TreeSpec {
            key: MAIN_TREE.into(),
            root: root.to_path_buf(),
            gitdir: root.join(".git"),
        }
    }
}

/// Why a watch could not be added.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AddError {
    /// The user's inotify watch budget (`max_user_watches`) is spent: `ENOSPC`.
    NoSpace(String),
    Other(String),
}

impl std::fmt::Display for AddError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AddError::NoSpace(d) => write!(
                f,
                "the inotify watch limit is spent (ENOSPC; raise fs.inotify.max_user_watches): {d}"
            ),
            AddError::Other(d) => f.write_str(d),
        }
    }
}

/// What the watcher knows about itself, for the doctor.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct WatchState {
    /// Directories under watch now.
    pub watched: usize,
    /// Why the main checkout is not watched (none: it is).
    pub error: Option<String>,
    /// Trees that run unwatched, with the reason (a spent watch budget, per tree).
    pub unwatched: Vec<(String, String)>,
}

pub trait Watch: Send + Sync {
    /// The events, from the first call on. A second call gets a receiver that never yields.
    fn events(&self) -> Receiver<WatchEvent>;
    /// The state the doctor reads; it changes as trees fail to be watched.
    fn shared_state(&self) -> Arc<Mutex<WatchState>> {
        Arc::default()
    }
    /// Serve one more tree on this same instance (blocking: it walks directories and runs git).
    fn add_tree(&self, _spec: TreeSpec) -> Result<(), AddError> {
        Ok(())
    }
    /// Stop serving a tree.
    fn remove_tree(&self, _key: &str) {}
}

/// The project's one watcher: the instance is made on the first tree and every later tree joins it.
pub struct ProjectWatch {
    make: Box<dyn Fn() -> std::io::Result<Arc<dyn Watch>> + Send + Sync>,
    inst: Mutex<Option<Arc<dyn Watch>>>,
}

impl ProjectWatch {
    pub fn new(
        make: impl Fn() -> std::io::Result<Arc<dyn Watch>> + Send + Sync + 'static,
    ) -> ProjectWatch {
        ProjectWatch {
            make: Box::new(make),
            inst: Mutex::new(None),
        }
    }

    fn instance(&self) -> std::io::Result<Arc<dyn Watch>> {
        let mut g = self.inst.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(i) = g.as_ref() {
            return Ok(i.clone());
        }
        let i = (self.make)()?;
        *g = Some(i.clone());
        Ok(i)
    }

    /// Whether the one instance exists (it could be started).
    pub fn is_up(&self) -> bool {
        self.inst.lock().is_ok_and(|g| g.is_some())
    }

    pub fn add_tree(&self, spec: TreeSpec) -> Result<(), AddError> {
        self.instance()
            .map_err(|e| AddError::Other(format!("the watcher could not start: {e}")))?
            .add_tree(spec)
    }

    pub fn remove_tree(&self, key: &str) {
        if let Ok(i) = self.instance() {
            i.remove_tree(key);
        }
    }
}

impl Watch for ProjectWatch {
    fn events(&self) -> Receiver<WatchEvent> {
        match self.instance() {
            Ok(i) => i.events(),
            Err(_) => std::sync::mpsc::channel().1,
        }
    }
    fn shared_state(&self) -> Arc<Mutex<WatchState>> {
        match self.instance() {
            Ok(i) => i.shared_state(),
            Err(_) => Arc::default(),
        }
    }
    fn add_tree(&self, spec: TreeSpec) -> Result<(), AddError> {
        ProjectWatch::add_tree(self, spec)
    }
    fn remove_tree(&self, key: &str) {
        ProjectWatch::remove_tree(self, key);
    }
}

/// Tags a changed path with its tree and decides which trees a git change concerns.
pub struct Router {
    /// The common gitdir (the main checkout's `.git`): refs and `worktrees/` live here.
    common: PathBuf,
    /// Each tree and the HEAD commit this router last saw for it.
    trees: Vec<(TreeSpec, Option<String>)>,
}

/// The branch HEAD of GITDIR names (`refs/heads/X` gives `X`); none when detached.
fn head_branch(gitdir: &Path) -> Option<String> {
    let h = std::fs::read_to_string(gitdir.join("HEAD")).ok()?;
    h.trim()
        .strip_prefix("ref: refs/heads/")
        .map(str::to_string)
}

/// The commit HEAD of GITDIR points at (refs come from COMMON, loose or packed).
fn head_commit(common: &Path, gitdir: &Path) -> Option<String> {
    let h = std::fs::read_to_string(gitdir.join("HEAD")).ok()?;
    let h = h.trim();
    let Some(r) = h.strip_prefix("ref: ") else {
        return Some(h.to_string());
    };
    if let Ok(s) = std::fs::read_to_string(common.join(r)) {
        return Some(s.trim().to_string());
    }
    let packed = std::fs::read_to_string(common.join("packed-refs")).ok()?;
    packed.lines().find_map(|l| {
        let (sha, name) = l.split_once(' ')?;
        (name == r).then(|| sha.to_string())
    })
}

impl Router {
    pub fn new(common: &Path) -> Router {
        Router {
            common: common.to_path_buf(),
            trees: Vec::new(),
        }
    }

    pub fn add(&mut self, spec: TreeSpec) {
        self.remove(&spec.key);
        let head = head_commit(&self.common, &spec.gitdir);
        self.trees.push((spec, head));
    }

    pub fn remove(&mut self, key: &str) {
        self.trees.retain(|(t, _)| t.key != key);
    }

    /// The events for a change at PATH (absolute).
    pub fn route(&mut self, path: &Path) -> Vec<WatchEvent> {
        if let Ok(rel) = path.strip_prefix(&self.common) {
            return self.route_git(path, rel);
        }
        let best = self
            .trees
            .iter()
            .filter(|(t, _)| path.starts_with(&t.root))
            .max_by_key(|(t, _)| t.root.components().count());
        let Some((t, _)) = best else {
            return Vec::new();
        };
        let Some(rel) = path.strip_prefix(&t.root).ok().and_then(Path::to_str) else {
            return Vec::new();
        };
        // a gitdir inside the tree (the main checkout's `.git`) is the git router's, not a file of the tree
        if rel.is_empty() || rel == ".git" || rel.starts_with(".git/") {
            return Vec::new();
        }
        vec![WatchEvent::File {
            tree: t.key.clone(),
            rel: rel.to_string(),
        }]
    }

    fn route_git(&mut self, path: &Path, rel: &Path) -> Vec<WatchEvent> {
        let comps: Vec<&str> = rel
            .components()
            .filter_map(|c| c.as_os_str().to_str())
            .collect();
        match comps.as_slice() {
            ["worktrees", n, rest @ ..] => {
                let gitdir = self.common.join("worktrees").join(n);
                let Some(key) = self.key_of_gitdir(&gitdir) else {
                    return Vec::new();
                };
                self.own_file(&key, rest.first().copied(), path)
            }
            [one] if matches!(*one, "HEAD" | "index" | "index.lock") => {
                let common = self.common.clone();
                match self.key_of_gitdir(&common) {
                    Some(k) => self.own_file(&k, Some(one), path),
                    None => Vec::new(),
                }
            }
            ["packed-refs"] => self.ref_wake(None, true),
            ["refs", "heads", name @ ..] if !name.is_empty() => {
                let name = name.join("/");
                if name.ends_with(".lock") {
                    return Vec::new();
                }
                self.ref_wake(Some(&name), false)
            }
            ["refs", ..] => self.ref_wake(None, false),
            _ => Vec::new(),
        }
    }

    fn key_of_gitdir(&self, gitdir: &Path) -> Option<String> {
        self.trees
            .iter()
            .find(|(t, _)| t.gitdir == gitdir)
            .map(|(t, _)| t.key.clone())
    }

    /// `HEAD`, `index` or `index.lock` in the tree's own gitdir.
    fn own_file(&mut self, key: &str, name: Option<&str>, path: &Path) -> Vec<WatchEvent> {
        match name {
            Some("index.lock") => vec![WatchEvent::Lock {
                tree: key.to_string(),
                held: path.exists(),
            }],
            Some("HEAD") => {
                self.note_head(key);
                vec![WatchEvent::Git {
                    tree: key.to_string(),
                }]
            }
            Some("index") => vec![WatchEvent::Git {
                tree: key.to_string(),
            }],
            _ => Vec::new(),
        }
    }

    fn note_head(&mut self, key: &str) {
        let common = self.common.clone();
        if let Some((t, seen)) = self.trees.iter_mut().find(|(t, _)| t.key == key) {
            *seen = head_commit(&common, &t.gitdir);
        }
    }

    /// A ref changed. BRANCH is the branch `refs/heads/<branch>` that moved (none: packed-refs, a tag or a remote
    /// ref); ALL reads every tree's HEAD, otherwise only the trees on that branch and the detached ones do. A tree is
    /// woken only when the commit its HEAD resolves to differs from the one last seen.
    fn ref_wake(&mut self, branch: Option<&str>, all: bool) -> Vec<WatchEvent> {
        let common = self.common.clone();
        let mut out = Vec::new();
        for (t, seen) in &mut self.trees {
            let on = head_branch(&t.gitdir);
            let candidate = all || on.is_none() || (branch.is_some() && on.as_deref() == branch);
            if !candidate {
                continue;
            }
            let now = head_commit(&common, &t.gitdir);
            if now != *seen {
                *seen = now;
                out.push(WatchEvent::Git {
                    tree: t.key.clone(),
                });
            }
        }
        out
    }
}

#[cfg(feature = "host")]
pub use host::{Adder, Walker};
#[cfg(all(feature = "host", any(target_os = "linux", target_os = "android")))]
pub use inotify_backend::InotifyWatch as HostWatch;
#[cfg(all(feature = "host", target_os = "macos"))]
pub use macos::NotifyWatch as HostWatch;

/// Which directories get a watch: pure, over an [`Adder`] so a test can stand in for inotify (and its limit).
#[cfg(feature = "host")]
mod host {
    use super::AddError;
    use std::collections::HashSet;
    use std::path::{Path, PathBuf};

    /// One watch per directory, no recursion: the backend a [`Walker`] drives.
    pub trait Adder {
        fn add(&mut self, dir: &Path) -> Result<(), AddError>;
        fn remove(&mut self, dir: &Path);
    }

    /// The directories to watch under a root and its gitdir: every directory git does not ignore, and of the gitdir
    /// only itself (`HEAD`, `index`, `index.lock`, `packed-refs`) and the `refs/` tree, never `objects/`.
    pub struct Walker<A: Adder> {
        adder: A,
        root: PathBuf,
        gitdir: PathBuf,
        /// Directories git ignores (absolute), from one `ls-files --others --ignored --directory`.
        ignored: HashSet<PathBuf>,
        /// Whether git ignores a directory that appeared since (checked by path).
        check: Box<dyn Fn(&Path) -> bool + Send>,
        watched: HashSet<PathBuf>,
    }

    impl<A: Adder> Walker<A> {
        /// IGNORED are the root-relative directories git ignores (with or without a trailing `/`).
        pub fn new(
            adder: A,
            root: &Path,
            gitdir: &Path,
            ignored: &[String],
            check: Box<dyn Fn(&Path) -> bool + Send>,
        ) -> Walker<A> {
            Walker {
                adder,
                root: root.to_path_buf(),
                gitdir: gitdir.to_path_buf(),
                ignored: ignored
                    .iter()
                    .map(|d| root.join(d.trim_end_matches('/')))
                    .collect(),
                check,
                watched: HashSet::new(),
            }
        }

        pub fn watched(&self) -> usize {
            self.watched.len()
        }

        pub fn is_watched(&self, dir: &Path) -> bool {
            self.watched.contains(dir)
        }

        /// Watch the root's tree and the gitdir's narrow part.
        pub fn seed(&mut self) -> Result<(), AddError> {
            let root = self.root.clone();
            self.tree(&root, &mut Vec::new())?;
            if self.gitdir.is_dir() {
                let g = self.gitdir.clone();
                self.watch(&g)?;
                let refs = g.join("refs");
                if refs.is_dir() {
                    self.tree(&refs, &mut Vec::new())?;
                }
            }
            Ok(())
        }

        /// A directory appeared at DIR (created or moved in): watch it and what is under it unless git ignores it.
        /// Returns the files already inside (they were written before the watch existed).
        pub fn created(&mut self, dir: &Path) -> Result<Vec<PathBuf>, AddError> {
            let mut files = Vec::new();
            if self.watched.contains(dir) {
                return Ok(files);
            }
            if dir.starts_with(&self.gitdir) {
                if dir.starts_with(self.gitdir.join("refs")) {
                    self.tree(dir, &mut files)?;
                }
            } else if dir.starts_with(&self.root) && !self.skip(dir) && !(self.check)(dir) {
                self.tree(dir, &mut files)?;
            }
            Ok(files)
        }

        /// DIR (and what was under it) is gone: the kernel dropped its watches, so a directory of that name made
        /// later gets new ones.
        pub fn gone(&mut self, dir: &Path) {
            let gone: Vec<PathBuf> = self
                .watched
                .iter()
                .filter(|d| d.starts_with(dir))
                .cloned()
                .collect();
            for d in gone {
                self.watched.remove(&d);
                self.adder.remove(&d);
            }
        }

        /// Drop every watch (the project runs unwatched).
        pub fn clear(&mut self) {
            for d in std::mem::take(&mut self.watched) {
                self.adder.remove(&d);
            }
        }

        fn skip(&self, dir: &Path) -> bool {
            dir == self.gitdir
                || self.ignored.contains(dir)
                || dir.file_name().is_some_and(|n| n == ".git")
        }

        fn watch(&mut self, dir: &Path) -> Result<(), AddError> {
            if self.watched.contains(dir) {
                return Ok(());
            }
            self.adder.add(dir)?;
            self.watched.insert(dir.to_path_buf());
            Ok(())
        }

        /// DIR and every directory below it that is not skipped; the files met go to FILES.
        fn tree(&mut self, dir: &Path, files: &mut Vec<PathBuf>) -> Result<(), AddError> {
            let in_refs = dir.starts_with(self.gitdir.join("refs"));
            if !in_refs && self.skip(dir) {
                return Ok(());
            }
            self.watch(dir)?;
            let Ok(rd) = std::fs::read_dir(dir) else {
                return Ok(());
            };
            for e in rd.flatten() {
                match e.file_type() {
                    Ok(t) if t.is_dir() => self.tree(&e.path(), files)?,
                    Ok(t) if !in_refs && !t.is_dir() => files.push(e.path()),
                    _ => {}
                }
            }
            Ok(())
        }
    }

    /// A failed seed or add drops every watch of the walker: a partial watch would be a lie. Returns why, if it failed.
    #[cfg(any(target_os = "linux", target_os = "android", test))]
    pub(super) fn settle<A: Adder>(w: &mut Walker<A>, r: Result<(), AddError>) -> Option<String> {
        r.err().map(|e| {
            w.clear();
            e.to_string()
        })
    }

    /// Git's view of the ignored directories under ROOT (root-relative, no trailing `/`).
    #[cfg(any(target_os = "linux", target_os = "android", target_os = "macos"))]
    pub(super) fn ignored_dirs(root: &Path) -> Vec<String> {
        crate::files::ignored_dirs(root)
            .map(|v| {
                v.into_iter()
                    .map(|d| d.trim_end_matches('/').to_string())
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// The inotify backend (Linux, Android): one instance, one non-recursive watch per directory, a mask of our own.
#[cfg(all(feature = "host", any(target_os = "linux", target_os = "android")))]
mod inotify_backend {
    use super::host::{Adder, Walker, ignored_dirs, settle};
    use super::{AddError, Router, TreeSpec, Watch, WatchEvent, WatchState};
    use inotify::{EventMask, Inotify, WatchDescriptor, WatchMask, Watches};
    use std::collections::{HashMap, HashSet};
    use std::ffi::OsStr;
    use std::os::fd::AsRawFd;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc::{Receiver, Sender, channel};
    use std::sync::{Arc, Mutex};

    /// A saved file, a file or directory that appeared, went or moved, a watched directory that went. No `IN_OPEN`
    /// (every read would fill the queue) and no `IN_MODIFY` (a save is reported once, at its close).
    const MASK: WatchMask = WatchMask::CLOSE_WRITE
        .union(WatchMask::CREATE)
        .union(WatchMask::DELETE)
        .union(WatchMask::MOVED_FROM)
        .union(WatchMask::MOVED_TO)
        .union(WatchMask::DELETE_SELF)
        .union(WatchMask::MOVE_SELF);

    /// `ENOSPC` (the user's watch budget) is its own error; everything else is the message.
    pub(super) fn map_add_error(e: &std::io::Error, dir: &Path) -> AddError {
        if e.raw_os_error() == Some(libc::ENOSPC) {
            AddError::NoSpace(format!("{}: {e}", dir.display()))
        } else {
            AddError::Other(format!("{}: {e}", dir.display()))
        }
    }

    /// What one inotify event means, before it is routed.
    #[derive(Debug, PartialEq, Eq)]
    pub(super) enum Raw {
        Overflow,
        /// The kernel dropped the watch.
        Ignored,
        /// A watched directory itself was deleted or moved.
        SelfGone(PathBuf),
        DirCreated(PathBuf),
        DirGone(PathBuf),
        /// A file changed, appeared or went.
        Changed(PathBuf),
    }

    /// DIR is the directory the event's watch is on, NAME the entry the event is about.
    pub(super) fn classify(
        mask: EventMask,
        dir: Option<&Path>,
        name: Option<&OsStr>,
    ) -> Option<Raw> {
        if mask.contains(EventMask::Q_OVERFLOW) {
            return Some(Raw::Overflow);
        }
        let dir = dir?;
        if mask.contains(EventMask::IGNORED) {
            return Some(Raw::Ignored);
        }
        let Some(name) = name else {
            return mask
                .intersects(EventMask::DELETE_SELF | EventMask::MOVE_SELF)
                .then(|| Raw::SelfGone(dir.to_path_buf()));
        };
        let path = dir.join(name);
        let is_dir = mask.contains(EventMask::ISDIR);
        let came = mask.intersects(EventMask::CREATE | EventMask::MOVED_TO);
        let went = mask.intersects(EventMask::DELETE | EventMask::MOVED_FROM);
        Some(match (is_dir, came, went) {
            (true, true, _) => Raw::DirCreated(path),
            (true, _, true) => Raw::DirGone(path),
            (true, _, _) => return None,
            _ => Raw::Changed(path),
        })
    }

    struct Shared {
        watches: Mutex<Watches>,
        by_id: Mutex<HashMap<i32, PathBuf>>,
        /// Each watched directory: its watch and the trees that hold it (one inotify watch per directory, however many
        /// trees want it; it goes when the last of them lets go).
        by_path: Mutex<HashMap<PathBuf, (WatchDescriptor, HashSet<String>)>>,
        trees: Mutex<Vec<Tree>>,
        router: Mutex<Router>,
        state: Arc<Mutex<WatchState>>,
        tx: Sender<WatchEvent>,
    }

    struct Tree {
        spec: TreeSpec,
        walker: Walker<Hook>,
    }

    /// The walker's door onto the shared inotify instance, for the tree KEY.
    struct Hook(Arc<Shared>, String);

    impl Adder for Hook {
        fn add(&mut self, dir: &Path) -> Result<(), AddError> {
            let s = &self.0;
            let mut by_path = lock(&s.by_path);
            if let Some((_, users)) = by_path.get_mut(dir) {
                users.insert(self.1.clone());
                return Ok(());
            }
            let wd = lock(&s.watches)
                .add(dir, MASK)
                .map_err(|e| map_add_error(&e, dir))?;
            lock(&s.by_id).insert(wd.get_watch_descriptor_id(), dir.to_path_buf());
            by_path.insert(dir.to_path_buf(), (wd, HashSet::from([self.1.clone()])));
            Ok(())
        }

        fn remove(&mut self, dir: &Path) {
            let s = &self.0;
            let mut by_path = lock(&s.by_path);
            let Some((_, users)) = by_path.get_mut(dir) else {
                return;
            };
            users.remove(&self.1);
            if users.is_empty()
                && let Some((wd, _)) = by_path.remove(dir)
            {
                lock(&s.by_id).remove(&wd.get_watch_descriptor_id());
                let _ = lock(&s.watches).remove(wd);
            }
        }
    }

    fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
        m.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub struct InotifyWatch {
        rx: Mutex<Option<Receiver<WatchEvent>>>,
        shared: Arc<Shared>,
        stop: Arc<AtomicBool>,
    }

    impl InotifyWatch {
        /// One instance for the project whose common gitdir is COMMON; trees join with [`Watch::add_tree`].
        pub fn new(common: &Path) -> std::io::Result<InotifyWatch> {
            let ino = Inotify::init()?;
            let (tx, rx) = channel();
            let shared = Arc::new(Shared {
                watches: Mutex::new(ino.watches()),
                by_id: Mutex::default(),
                by_path: Mutex::default(),
                trees: Mutex::default(),
                router: Mutex::new(Router::new(common)),
                state: Arc::default(),
                tx,
            });
            let stop = Arc::new(AtomicBool::new(false));
            let (s, st) = (shared.clone(), stop.clone());
            std::thread::Builder::new()
                .name("hrafn:watch".into())
                .spawn(move || read_loop(ino, &s, &st))?;
            Ok(InotifyWatch {
                rx: Mutex::new(Some(rx)),
                shared,
                stop,
            })
        }

        pub fn state(&self) -> WatchState {
            lock(&self.shared.state).clone()
        }
    }

    impl Drop for InotifyWatch {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
        }
    }

    impl Shared {
        fn refresh_state(&self, trees: &[Tree]) {
            lock(&self.state).watched = trees.iter().map(|t| t.walker.watched()).sum();
        }

        /// KEY could not be watched (ENOSPC or another error): its watches go, the others keep theirs.
        fn unwatch(&self, key: &str, why: String) {
            lock(&self.router).remove(key);
            let mut st = lock(&self.state);
            if key == super::MAIN_TREE {
                st.error = Some(why.clone());
            }
            st.unwatched.retain(|(k, _)| k != key);
            st.unwatched.push((key.to_string(), why));
        }
    }

    impl Watch for InotifyWatch {
        /// Shared: it changes when a created directory finds the budget spent.
        fn shared_state(&self) -> Arc<Mutex<WatchState>> {
            self.shared.state.clone()
        }

        fn events(&self) -> Receiver<WatchEvent> {
            match lock(&self.rx).take() {
                Some(rx) => rx,
                None => channel().1,
            }
        }

        fn add_tree(&self, spec: TreeSpec) -> Result<(), AddError> {
            self.remove_tree(&spec.key);
            let ignored = ignored_dirs(&spec.root);
            let root = spec.root.clone();
            let check = Box::new(move |d: &Path| {
                d.strip_prefix(&root)
                    .ok()
                    .is_some_and(|rel| crate::files::is_ignored_dir(&root, rel))
            });
            let mut walker = Walker::new(
                Hook(self.shared.clone(), spec.key.clone()),
                &spec.root,
                &spec.gitdir,
                &ignored,
                check,
            );
            let seeded = walker.seed();
            let failed = settle(&mut walker, seeded.clone());
            let mut trees = lock(&self.shared.trees);
            if let Some(why) = failed {
                self.shared.unwatch(&spec.key, why);
            } else {
                lock(&self.shared.state)
                    .unwatched
                    .retain(|(k, _)| *k != spec.key);
                if spec.key == super::MAIN_TREE {
                    lock(&self.shared.state).error = None;
                }
                lock(&self.shared.router).add(spec.clone());
                trees.push(Tree { spec, walker });
            }
            self.shared.refresh_state(&trees);
            seeded
        }

        fn remove_tree(&self, key: &str) {
            lock(&self.shared.router).remove(key);
            let mut trees = lock(&self.shared.trees);
            if let Some(i) = trees.iter().position(|t| t.spec.key == key) {
                trees.remove(i).walker.clear();
            }
            self.shared.refresh_state(&trees);
        }
    }

    fn read_loop(mut ino: Inotify, s: &Arc<Shared>, stop: &AtomicBool) {
        let fd = ino.as_raw_fd();
        let mut buf = vec![0u8; 64 * 1024];
        while !stop.load(Ordering::Relaxed) {
            let mut p = libc::pollfd {
                fd,
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: P is one valid pollfd and the count says so.
            let n = unsafe { libc::poll(&raw mut p, 1, 100) };
            if n <= 0 {
                continue;
            }
            let events = match ino.read_events(&mut buf) {
                Ok(e) => e,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
                Err(_) => {
                    // a read error loses events: never silently
                    let _ = s.tx.send(WatchEvent::Overflow);
                    continue;
                }
            };
            for ev in events {
                let dir = lock(&s.by_id)
                    .get(&ev.wd.get_watch_descriptor_id())
                    .cloned();
                let raw = classify(ev.mask, dir.as_deref(), ev.name);
                if let Some(raw) = raw {
                    handle(s, raw);
                }
            }
        }
    }

    fn handle(s: &Shared, raw: Raw) {
        match raw {
            Raw::Overflow => {
                let _ = s.tx.send(WatchEvent::Overflow);
            }
            Raw::Ignored => {}
            Raw::SelfGone(dir) | Raw::DirGone(dir) => {
                for t in lock(&s.trees).iter_mut() {
                    t.walker.gone(&dir);
                }
            }
            Raw::Changed(path) => {
                for e in lock(&s.router).route(&path) {
                    let _ = s.tx.send(e);
                }
            }
            Raw::DirCreated(dir) => created(s, &dir),
        }
    }

    /// A directory appeared: the tree that owns it (the one with the longest matching root) watches it, and the
    /// files already inside are reported as written.
    fn created(s: &Shared, dir: &Path) {
        let mut trees = lock(&s.trees);
        let best = trees
            .iter_mut()
            .filter(|t| dir.starts_with(&t.spec.root) || dir.starts_with(&t.spec.gitdir))
            .max_by_key(|t| {
                let r = if dir.starts_with(&t.spec.root) {
                    t.spec.root.components().count()
                } else {
                    0
                };
                let g = if dir.starts_with(&t.spec.gitdir) {
                    t.spec.gitdir.components().count()
                } else {
                    0
                };
                r.max(g)
            });
        let Some(t) = best else { return };
        let key = t.spec.key.clone();
        match t.walker.created(dir) {
            Ok(files) => {
                let mut router = lock(&s.router);
                for f in files {
                    for e in router.route(&f) {
                        let _ = s.tx.send(e);
                    }
                }
            }
            Err(e) => {
                t.walker.clear();
                s.unwatch(&key, e.to_string());
            }
        }
        s.refresh_state(&trees);
    }
}

/// notify's FSEvents (macOS): recursive, so ignored directories are filtered here, and one `paths_mut` batch per
/// tree because `watch()` restarts the stream on every call. Not built or run on the Linux lane.
#[cfg(all(feature = "host", target_os = "macos"))]
mod macos {
    use super::host::ignored_dirs;
    use super::{AddError, Router, TreeSpec, Watch, WatchEvent, WatchState};
    use notify::{RecommendedWatcher, RecursiveMode, Watcher};
    use std::path::{Path, PathBuf};
    use std::sync::mpsc::{Receiver, Sender, channel};
    use std::sync::{Arc, Mutex};

    pub struct NotifyWatch {
        rx: Mutex<Option<Receiver<WatchEvent>>>,
        watcher: Mutex<RecommendedWatcher>,
        router: Arc<Mutex<Router>>,
        ignored: Arc<Mutex<Vec<PathBuf>>>,
        state: Arc<Mutex<WatchState>>,
    }

    impl NotifyWatch {
        pub fn new(common: &Path) -> std::io::Result<NotifyWatch> {
            let (tx, rx): (Sender<WatchEvent>, _) = channel();
            let router = Arc::new(Mutex::new(Router::new(common)));
            let ignored: Arc<Mutex<Vec<PathBuf>>> = Arc::default();
            let (r, ig) = (router.clone(), ignored.clone());
            let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
                let Ok(ev) = res else {
                    let _ = tx.send(WatchEvent::Overflow);
                    return;
                };
                if ev.need_rescan() {
                    let _ = tx.send(WatchEvent::Overflow);
                }
                if !(ev.kind.is_create() || ev.kind.is_modify() || ev.kind.is_remove()) {
                    return;
                }
                let (Ok(mut r), Ok(ig)) = (r.lock(), ig.lock()) else {
                    return;
                };
                for p in &ev.paths {
                    if ig.iter().any(|d| p.starts_with(d)) {
                        continue;
                    }
                    for e in r.route(p) {
                        let _ = tx.send(e);
                    }
                }
            })
            .map_err(std::io::Error::other)?;
            Ok(NotifyWatch {
                rx: Mutex::new(Some(rx)),
                watcher: Mutex::new(watcher),
                router,
                ignored,
                state: Arc::default(),
            })
        }

        pub fn state(&self) -> WatchState {
            self.state.lock().map(|s| s.clone()).unwrap_or_default()
        }
    }

    impl Watch for NotifyWatch {
        fn shared_state(&self) -> Arc<Mutex<WatchState>> {
            self.state.clone()
        }

        fn events(&self) -> Receiver<WatchEvent> {
            match self.rx.lock().ok().and_then(|mut r| r.take()) {
                Some(rx) => rx,
                None => channel().1,
            }
        }

        fn add_tree(&self, spec: TreeSpec) -> Result<(), AddError> {
            let skip = ignored_dirs(&spec.root);
            let (Ok(mut w), Ok(mut ig), Ok(mut r)) =
                (self.watcher.lock(), self.ignored.lock(), self.router.lock())
            else {
                return Err(AddError::Other("the watcher is poisoned".into()));
            };
            ig.extend(skip.iter().map(|d| spec.root.join(d)));
            let mut paths = w.paths_mut();
            let added = paths
                .add(&spec.root, RecursiveMode::Recursive)
                .and_then(|()| {
                    if spec.gitdir.starts_with(&spec.root) {
                        Ok(())
                    } else {
                        paths.add(&spec.gitdir, RecursiveMode::Recursive)
                    }
                })
                .and_then(|()| paths.commit());
            added.map_err(|e| AddError::Other(format!("{}: {e}", spec.root.display())))?;
            r.add(spec);
            Ok(())
        }

        fn remove_tree(&self, key: &str) {
            if let Ok(mut r) = self.router.lock() {
                r.remove(key);
            }
        }
    }
}

#[cfg(all(test, feature = "host"))]
mod tests {
    use super::host::{Adder, Walker, settle};
    use super::{AddError, WatchState};
    use std::collections::BTreeSet;
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex};

    /// An inotify stand-in with a limit of its own: no test depends on the host's `max_user_watches`.
    #[derive(Clone)]
    struct Fake {
        dirs: Arc<Mutex<BTreeSet<PathBuf>>>,
        limit: usize,
    }

    impl Fake {
        fn new(limit: usize) -> Fake {
            Fake {
                dirs: Arc::default(),
                limit,
            }
        }
        fn names(&self, root: &Path) -> Vec<String> {
            self.dirs
                .lock()
                .unwrap()
                .iter()
                .map(|d| d.strip_prefix(root).unwrap().display().to_string())
                .collect()
        }
    }

    impl Adder for Fake {
        fn add(&mut self, dir: &Path) -> Result<(), AddError> {
            let mut d = self.dirs.lock().unwrap();
            if d.len() >= self.limit {
                return Err(AddError::NoSpace("fake limit".into()));
            }
            d.insert(dir.to_path_buf());
            Ok(())
        }
        fn remove(&mut self, dir: &Path) {
            self.dirs.lock().unwrap().remove(dir);
        }
    }

    fn mk(root: &Path, dirs: &[&str]) {
        for d in dirs {
            std::fs::create_dir_all(root.join(d)).unwrap();
        }
    }

    fn walker(f: &Fake, root: &Path, ignored: &[&str]) -> Walker<Fake> {
        let ig: Vec<String> = ignored.iter().map(|s| s.to_string()).collect();
        let ig2 = ig.clone();
        let r = root.to_path_buf();
        Walker::new(
            f.clone(),
            root,
            &root.join(".git"),
            &ig,
            Box::new(move |d| {
                let rel = d.strip_prefix(&r).unwrap().to_string_lossy().into_owned();
                ig2.iter().any(|i| rel.starts_with(i.trim_end_matches('/')))
            }),
        )
    }

    #[test]
    fn ignored_directories_get_no_watch() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        mk(
            root,
            &[
                "src/a",
                "target/debug/deps",
                ".claude/worktrees/x/src",
                ".claude/hooks",
                ".git/objects/ab",
            ],
        );
        let f = Fake::new(1000);
        let mut w = walker(&f, root, &["target/", ".claude/worktrees/"]);
        w.seed().unwrap();
        let names = f.names(root);
        for want in ["", "src", "src/a", ".claude", ".claude/hooks"] {
            assert!(
                names.contains(&want.to_string()),
                "{want:?} missing in {names:?}"
            );
        }
        for no in [
            "target",
            "target/debug",
            ".claude/worktrees",
            ".claude/worktrees/x",
        ] {
            assert!(
                !names.contains(&no.to_string()),
                "{no:?} watched: {names:?}"
            );
        }
        // a created directory that git does not ignore gets a watch, with what is inside; an ignored one does not
        mk(root, &["new/deep", "target/other"]);
        std::fs::write(root.join("new/deep/f.rs"), "x").unwrap();
        let files = w.created(&root.join("new")).unwrap();
        assert!(f.names(root).contains(&"new/deep".to_string()));
        assert_eq!(files, vec![root.join("new/deep/f.rs")]);
        w.created(&root.join("target/other")).unwrap();
        assert!(!f.names(root).contains(&"target/other".to_string()));
    }

    #[test]
    fn gitdir_objects_unwatched() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        mk(
            root,
            &[
                ".git/objects/ab",
                ".git/refs/heads/feat",
                ".git/refs/tags",
                ".git/logs/refs",
                ".git/hooks",
            ],
        );
        let f = Fake::new(1000);
        let mut w = walker(&f, root, &[]);
        w.seed().unwrap();
        let mut git: Vec<String> = f
            .names(root)
            .into_iter()
            .filter(|n| n.starts_with(".git"))
            .collect();
        git.sort();
        assert_eq!(
            git,
            [
                ".git",
                ".git/refs",
                ".git/refs/heads",
                ".git/refs/heads/feat",
                ".git/refs/tags"
            ]
        );
        // a new branch directory is watched, a new objects directory is not
        mk(root, &[".git/refs/heads/new", ".git/objects/cd"]);
        w.created(&root.join(".git/refs/heads/new")).unwrap();
        w.created(&root.join(".git/objects/cd")).unwrap();
        let names = f.names(root);
        assert!(names.contains(&".git/refs/heads/new".to_string()));
        assert!(
            !names.iter().any(|n| n.starts_with(".git/objects")),
            "{names:?}"
        );
    }

    #[test]
    fn watch_enospc_is_reported() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        mk(root, &["a", "b", "c", "d", ".git"]);
        let f = Fake::new(3);
        let mut w = walker(&f, root, &[]);
        let seeded = w.seed();
        let err = seeded.clone().unwrap_err();
        assert!(matches!(err, AddError::NoSpace(_)), "{err:?}");
        let why = settle(&mut w, seeded);
        let st = WatchState {
            error: why,
            ..WatchState::default()
        };
        assert!(
            st.error.as_deref().is_some_and(|e| e.contains("ENOSPC")),
            "{st:?}"
        );
        assert_eq!(w.watched(), 0);
        assert!(f.names(root).is_empty());
    }

    #[test]
    fn a_removed_directory_can_be_watched_again() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        mk(root, &["a/b"]);
        let f = Fake::new(1000);
        let mut w = walker(&f, root, &[]);
        w.seed().unwrap();
        std::fs::remove_dir_all(root.join("a")).unwrap();
        w.gone(&root.join("a"));
        assert!(!f.names(root).contains(&"a/b".to_string()));
        mk(root, &["a/c"]);
        w.created(&root.join("a")).unwrap();
        let names = f.names(root);
        assert!(
            names.contains(&"a".to_string()) && names.contains(&"a/c".to_string()),
            "{names:?}"
        );
    }
}

#[cfg(test)]
mod route_tests {
    use super::*;
    use crate::fresh::Fresh;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn w(p: &Path, s: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, s).unwrap();
    }

    fn spec(key: &str, root: &Path, gitdir: &Path) -> TreeSpec {
        TreeSpec {
            key: key.into(),
            root: root.to_path_buf(),
            gitdir: gitdir.to_path_buf(),
        }
    }

    /// A main checkout with `.claude/worktrees/x` linked to it, on branches main and feat.
    fn layout(root: &Path) -> (PathBuf, Router) {
        let common = root.join(".git");
        let xroot = root.join(".claude/worktrees/x");
        let xgit = common.join("worktrees/x");
        w(&common.join("HEAD"), "ref: refs/heads/main\n");
        w(&common.join("refs/heads/main"), "aaa\n");
        w(&common.join("refs/heads/feat"), "bbb\n");
        w(&xgit.join("HEAD"), "ref: refs/heads/feat\n");
        std::fs::create_dir_all(&xroot).unwrap();
        let mut r = Router::new(&common);
        r.add(TreeSpec::main(root));
        r.add(spec("x", &xroot, &xgit));
        (common, r)
    }

    // pattern: D
    #[test]
    fn nested_tree_event_goes_to_the_tree() {
        let t = tempfile::tempdir().unwrap();
        let (_, mut r) = layout(t.path());
        let ev = r.route(&t.path().join(".claude/worktrees/x/a.rs"));
        assert_eq!(
            ev,
            [WatchEvent::File {
                tree: "x".into(),
                rel: "a.rs".into()
            }]
        );
        // main's settle is not armed by it, and is by main's own file
        assert_eq!(ev[0].main_fresh(), None);
        let own = r.route(&t.path().join("src/b.rs"));
        assert_eq!(own[0].main_fresh(), Some(Fresh::Save("src/b.rs".into())));
        // the gitdir inside main's root is not a file of main
        assert!(r.route(&t.path().join(".git/objects/ab")).is_empty());
    }

    // pattern: D
    #[test]
    fn linked_tree_git_event_is_tagged() {
        let t = tempfile::tempdir().unwrap();
        let (common, mut r) = layout(t.path());
        let git = |tree: &str| WatchEvent::Git { tree: tree.into() };
        assert_eq!(r.route(&common.join("worktrees/x/HEAD")), [git("x")]);
        assert_eq!(r.route(&common.join("worktrees/x/index")), [git("x")]);
        assert_eq!(
            r.route(&common.join("worktrees/x/index.lock")),
            [WatchEvent::Lock {
                tree: "x".into(),
                held: false
            }]
        );
        assert_eq!(r.route(&common.join("HEAD")), [git(MAIN_TREE)]);
        assert_eq!(r.route(&common.join("index")), [git(MAIN_TREE)]);
        // a worktree the router was not told about gives nothing
        assert!(r.route(&common.join("worktrees/nope/HEAD")).is_empty());
    }

    // pattern: D
    #[test]
    fn ref_change_wakes_only_its_trees() {
        let t = tempfile::tempdir().unwrap();
        let (common, mut r) = layout(t.path());
        let ydir = t.path().join("y");
        let ygit = common.join("worktrees/y");
        w(&ygit.join("HEAD"), "ccc\n"); // detached
        r.add(spec("y", &ydir, &ygit));
        let git = |tree: &str| WatchEvent::Git { tree: tree.into() };
        // a commit on feat: x (on feat) re-diffs; main (on main) and y (detached, same commit) do not
        w(&common.join("refs/heads/feat"), "ddd\n");
        assert_eq!(r.route(&common.join("refs/heads/feat")), [git("x")]);
        // the same ref event again changes nothing
        assert!(r.route(&common.join("refs/heads/feat")).is_empty());
        // a lock file of a ref is no change
        assert!(r.route(&common.join("refs/heads/feat.lock")).is_empty());
        // packed-refs: main's branch moved there, nobody else's HEAD did
        std::fs::remove_file(common.join("refs/heads/main")).unwrap();
        w(
            &common.join("packed-refs"),
            "# pack-refs\neee refs/heads/main\n",
        );
        assert_eq!(r.route(&common.join("packed-refs")), [git(MAIN_TREE)]);
    }

    struct Counting {
        trees: Mutex<Vec<String>>,
    }

    impl Watch for Counting {
        fn events(&self) -> Receiver<WatchEvent> {
            std::sync::mpsc::channel().1
        }
        fn add_tree(&self, spec: TreeSpec) -> Result<(), AddError> {
            self.trees.lock().unwrap().push(spec.key);
            Ok(())
        }
    }

    // pattern: D
    #[test]
    fn one_watcher_per_project() {
        let made = Arc::new(AtomicUsize::new(0));
        let inst = Arc::new(Counting {
            trees: Mutex::default(),
        });
        let (m, i) = (made.clone(), inst.clone());
        let pw = ProjectWatch::new(move || {
            m.fetch_add(1, Ordering::SeqCst);
            Ok(i.clone() as Arc<dyn Watch>)
        });
        for k in ["main", "x", "y"] {
            pw.add_tree(spec(k, Path::new("/r"), Path::new("/r/.git")))
                .unwrap();
        }
        let _ = Watch::events(&pw);
        assert_eq!(made.load(Ordering::SeqCst), 1);
        assert_eq!(*inst.trees.lock().unwrap(), ["main", "x", "y"]);
    }
}

#[cfg(all(
    test,
    feature = "host",
    any(target_os = "linux", target_os = "android")
))]
mod inotify_tests {
    use super::inotify_backend::{InotifyWatch, Raw, classify, map_add_error};
    use super::*;
    use inotify::EventMask;
    use std::ffi::OsStr;

    // pattern: D
    #[test]
    fn queue_overflow_marks_trees_stale() {
        // the kernel's overflow has no watch and no name; it becomes the one event every tree reads as "stale"
        assert_eq!(
            classify(EventMask::Q_OVERFLOW, None, None),
            Some(Raw::Overflow)
        );
        assert_eq!(
            WatchEvent::Overflow.main_fresh(),
            Some(crate::fresh::Fresh::Git)
        );
        // entries are classified by what they are
        let d = Path::new("/r");
        let n = Some(OsStr::new("x"));
        assert_eq!(
            classify(EventMask::CREATE | EventMask::ISDIR, Some(d), n),
            Some(Raw::DirCreated("/r/x".into()))
        );
        assert_eq!(
            classify(EventMask::MOVED_FROM | EventMask::ISDIR, Some(d), n),
            Some(Raw::DirGone("/r/x".into()))
        );
        assert_eq!(
            classify(EventMask::CLOSE_WRITE, Some(d), n),
            Some(Raw::Changed("/r/x".into()))
        );
        assert_eq!(
            classify(EventMask::DELETE_SELF, Some(d), None),
            Some(Raw::SelfGone(d.into()))
        );
        assert_eq!(
            classify(EventMask::IGNORED, Some(d), None),
            Some(Raw::Ignored)
        );
    }

    // pattern: D
    #[test]
    fn inotify_enospc_is_the_budget_error() {
        let full = std::io::Error::from_raw_os_error(28);
        assert!(matches!(
            map_add_error(&full, Path::new("/r/a")),
            AddError::NoSpace(_)
        ));
        let other = std::io::Error::from_raw_os_error(13);
        assert!(matches!(
            map_add_error(&other, Path::new("/r/a")),
            AddError::Other(_)
        ));
    }

    // pattern: D
    #[test]
    fn the_inotify_backend_tags_what_it_sees() {
        let t = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(t.path()).unwrap();
        let wt = InotifyWatch::new(&root.join(".git")).unwrap();
        let rx = wt.events();
        wt.add_tree(TreeSpec::main(&root)).unwrap();
        std::fs::write(root.join("a.rs"), "x").unwrap();
        let want = WatchEvent::File {
            tree: MAIN_TREE.into(),
            rel: "a.rs".into(),
        };
        skuld::wait_until("the saved file", 10, || {
            (rx.try_recv().ok().as_ref() == Some(&want)).then_some(())
        });
        // a directory made later is watched, and a file written in it is seen
        std::fs::create_dir_all(root.join("new")).unwrap();
        skuld::wait_until("the new directory is watched", 10, || {
            (wt.state().watched >= 2).then_some(())
        });
        std::fs::write(root.join("new/b.rs"), "x").unwrap();
        let want = WatchEvent::File {
            tree: MAIN_TREE.into(),
            rel: "new/b.rs".into(),
        };
        skuld::wait_until("the file in it", 10, || {
            (rx.try_recv().ok().as_ref() == Some(&want)).then_some(())
        });
    }

    // pattern: D
    #[test]
    fn a_shared_directory_keeps_its_watch_until_the_last_tree_drops_it() {
        let t = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(t.path()).unwrap();
        std::fs::create_dir_all(root.join("shared")).unwrap();
        let wt = InotifyWatch::new(&root.join(".git")).unwrap();
        let rx = wt.events();
        wt.add_tree(TreeSpec::main(&root)).unwrap();
        // a second tree whose root is the directory main also watches
        let inner = TreeSpec {
            key: "b".into(),
            root: root.join("shared"),
            gitdir: root.join("shared/.git"),
        };
        wt.add_tree(inner).unwrap();
        wt.remove_tree("b");
        std::fs::write(root.join("shared/f.rs"), "x").unwrap();
        let want = WatchEvent::File {
            tree: MAIN_TREE.into(),
            rel: "shared/f.rs".into(),
        };
        skuld::wait_until("main still hears the shared directory", 10, || {
            (rx.try_recv().ok().as_ref() == Some(&want)).then_some(())
        });
    }
}
