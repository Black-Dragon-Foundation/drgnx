//! The file watcher behind a trait: what the shell feeds [`crate::fresh::Settle`].
//!
//! `NotifyWatch` (feature `host`) watches the tree, gitdir included, through the `notify` crate (one non-recursive
//! watch per directory git does not ignore, and only the narrow part of the gitdir), and sorts what it sees: `index.lock` coming and going, a change to `HEAD`, the index or a ref, and a written file of the tree. The
//! quiet period and the wait for the lock are the settle core's, not the watcher's.

use std::sync::mpsc::Receiver;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WatchEvent {
    /// A file of the tree, relative to the root.
    File(String),
    /// `HEAD`, the index or a ref changed.
    Git,
    /// `index.lock` is there (true) or gone (false).
    Lock(bool),
}

pub trait Watch: Send + Sync {
    /// The events, from the first call on. A second call gets a receiver that never yields.
    fn events(&self) -> Receiver<WatchEvent>;
}

#[cfg(feature = "host")]
pub use host::{AddError, Adder, NotifyWatch, Walker, WatchState};

/// Which directories get a watch: pure, over an [`Adder`] so a test can stand in for inotify (and its limit).
#[cfg(feature = "host")]
mod host {
    use super::{Watch, WatchEvent};
    use notify::{RecommendedWatcher, RecursiveMode, Watcher};
    use std::collections::HashSet;
    use std::path::{Path, PathBuf};
    use std::sync::mpsc::{Receiver, Sender, channel};
    use std::sync::{Arc, Mutex};

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
        /// Why the project is not watched (none: it is).
        pub error: Option<String>,
    }

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

    struct NotifyAdder(RecommendedWatcher);

    impl Adder for NotifyAdder {
        fn add(&mut self, dir: &Path) -> Result<(), AddError> {
            self.0
                .watch(dir, RecursiveMode::NonRecursive)
                .map_err(|e| match &e.kind {
                    notify::ErrorKind::MaxFilesWatch => AddError::NoSpace(e.to_string()),
                    notify::ErrorKind::Io(io) if io.raw_os_error() == Some(28) => {
                        AddError::NoSpace(e.to_string())
                    }
                    _ => AddError::Other(format!("{}: {e}", dir.display())),
                })
        }

        fn remove(&mut self, dir: &Path) {
            let _ = self.0.unwatch(dir);
        }
    }

    enum Msg {
        Event(notify::Event),
        Stop,
    }

    pub struct NotifyWatch {
        rx: std::sync::Mutex<Option<Receiver<WatchEvent>>>,
        state: Arc<Mutex<WatchState>>,
        stop: Sender<Msg>,
    }

    /// What a changed PATH means, for a tree at ROOT whose gitdir is GITDIR.
    fn sort(root: &Path, gitdir: &Path, path: &Path) -> Option<WatchEvent> {
        if let Ok(rel) = path.strip_prefix(gitdir) {
            let first = rel.components().next()?.as_os_str().to_str()?;
            return match first {
                "index.lock" => Some(WatchEvent::Lock(path.exists())),
                "HEAD" | "index" | "refs" | "packed-refs" => Some(WatchEvent::Git),
                _ => None,
            };
        }
        let rel = path.strip_prefix(root).ok()?.to_str()?;
        (!rel.is_empty()).then(|| WatchEvent::File(rel.to_string()))
    }

    fn forward(tx: &Sender<WatchEvent>, root: &Path, gitdir: &Path, ev: &notify::Event) {
        if !(ev.kind.is_create() || ev.kind.is_modify() || ev.kind.is_remove()) {
            return;
        }
        for p in &ev.paths {
            if let Some(e) = sort(root, gitdir, p) {
                let _ = tx.send(e);
            }
        }
    }

    /// Git's view of the ignored directories under ROOT (root-relative, no trailing `/`).
    fn ignored_dirs(root: &Path) -> Vec<String> {
        crate::files::ignored_dirs(root)
            .map(|v| {
                v.into_iter()
                    .map(|d| d.trim_end_matches('/').to_string())
                    .collect()
            })
            .unwrap_or_default()
    }

    impl NotifyWatch {
        /// Watches every directory of ROOT that git does not ignore, and GITDIR (usually `ROOT/.git`) narrowly. A
        /// spent watch budget is not an error here: the watcher comes back `unwatched`, and [`NotifyWatch::state`]
        /// says why.
        pub fn new(root: &Path, gitdir: &Path) -> notify::Result<NotifyWatch> {
            let (tx, rx) = channel();
            let (mtx, mrx) = channel::<Msg>();
            let cb = mtx.clone();
            let watcher =
                notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
                    if let Ok(ev) = res {
                        let _ = cb.send(Msg::Event(ev));
                    }
                })?;
            let (r, g) = (root.to_path_buf(), gitdir.to_path_buf());
            let ignored = ignored_dirs(root);
            let check_root = root.to_path_buf();
            let check = Box::new(move |d: &Path| {
                d.strip_prefix(&check_root)
                    .ok()
                    .is_some_and(|rel| crate::files::is_ignored_dir(&check_root, rel))
            });
            let mut walker = Walker::new(NotifyAdder(watcher), root, gitdir, &ignored, check);
            let state = Arc::new(Mutex::new(WatchState::default()));
            let seeded = walker.seed();
            publish(&state, &mut walker, seeded);
            let st = state.clone();
            std::thread::Builder::new()
                .name("hrafn:watch".into())
                .spawn(move || {
                    while let Ok(Msg::Event(ev)) = mrx.recv() {
                        if ev.kind.is_create() || ev.kind.is_modify() {
                            for p in &ev.paths {
                                let is_dir = std::fs::symlink_metadata(p).is_ok_and(|m| m.is_dir());
                                if is_dir && !walker.is_watched(p) {
                                    let added = walker.created(p);
                                    let files = added.clone().unwrap_or_default();
                                    publish(&st, &mut walker, added.map(|_| ()));
                                    for f in files {
                                        if let Some(e) = sort(&r, &g, &f) {
                                            let _ = tx.send(e);
                                        }
                                    }
                                }
                            }
                        }
                        forward(&tx, &r, &g, &ev);
                    }
                })
                .map_err(notify::Error::io)?;
            Ok(NotifyWatch {
                rx: std::sync::Mutex::new(Some(rx)),
                state,
                stop: mtx,
            })
        }

        /// The count of watched directories, and why the project is unwatched if it is.
        pub fn state(&self) -> WatchState {
            self.state.lock().map(|s| s.clone()).unwrap_or_default()
        }

        /// The same state, shared: it changes when a created directory finds the budget spent.
        pub fn shared_state(&self) -> Arc<Mutex<WatchState>> {
            self.state.clone()
        }
    }

    /// Record the result of adding watches; a failure drops them all: a partial watch would be a lie.
    pub(super) fn publish<A: Adder>(
        state: &Mutex<WatchState>,
        w: &mut Walker<A>,
        r: Result<(), AddError>,
    ) {
        if r.is_err() {
            w.clear();
        }
        if let Ok(mut s) = state.lock() {
            s.watched = w.watched();
            if let Err(e) = r {
                s.error = Some(e.to_string());
            }
        }
    }

    impl Drop for NotifyWatch {
        fn drop(&mut self) {
            let _ = self.stop.send(Msg::Stop);
        }
    }

    impl Watch for NotifyWatch {
        fn events(&self) -> Receiver<WatchEvent> {
            match self.rx.lock().ok().and_then(|mut r| r.take()) {
                Some(rx) => rx,
                None => channel().1,
            }
        }
    }
}

#[cfg(all(test, feature = "host"))]
mod tests {
    use super::host::{AddError, Adder, Walker, WatchState, publish};
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
        // the state says so, and the partial watches are dropped: unwatched, not half watched
        let state = Mutex::new(WatchState::default());
        publish(&state, &mut w, seeded);
        let st = state.lock().unwrap().clone();
        assert!(
            st.error.as_deref().is_some_and(|e| e.contains("ENOSPC")),
            "{st:?}"
        );
        assert_eq!(st.watched, 0);
        assert!(f.names(root).is_empty());
    }
}
