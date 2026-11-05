//! The file watcher behind a trait: what the shell feeds [`crate::fresh::Settle`].
//!
//! `NotifyWatch` (feature `host`) watches the tree, gitdir included, through the `notify` crate, and sorts what it
//! sees: `index.lock` coming and going, a change to `HEAD`, the index or a ref, and a written file of the tree. The
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
pub use host::NotifyWatch;

#[cfg(feature = "host")]
mod host {
    use super::{Watch, WatchEvent};
    use notify::{RecommendedWatcher, RecursiveMode, Watcher};
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;
    use std::sync::mpsc::{Receiver, Sender, channel};

    pub struct NotifyWatch {
        _watcher: RecommendedWatcher,
        rx: Mutex<Option<Receiver<WatchEvent>>>,
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

    fn forward(tx: &Sender<WatchEvent>, root: &Path, gitdir: &Path, ev: notify::Event) {
        if !(ev.kind.is_create() || ev.kind.is_modify() || ev.kind.is_remove()) {
            return;
        }
        for p in &ev.paths {
            if let Some(e) = sort(root, gitdir, p) {
                let _ = tx.send(e);
            }
        }
    }

    impl NotifyWatch {
        /// Watches ROOT recursively; GITDIR (usually `ROOT/.git`) too, when it lies outside ROOT.
        pub fn new(root: &Path, gitdir: &Path) -> notify::Result<NotifyWatch> {
            let (tx, rx) = channel();
            let (r, g): (PathBuf, PathBuf) = (root.to_path_buf(), gitdir.to_path_buf());
            let mut watcher =
                notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
                    if let Ok(ev) = res {
                        forward(&tx, &r, &g, ev);
                    }
                })?;
            watcher.watch(root, RecursiveMode::Recursive)?;
            if !gitdir.starts_with(root) {
                watcher.watch(gitdir, RecursiveMode::Recursive)?;
            }
            Ok(NotifyWatch {
                _watcher: watcher,
                rx: Mutex::new(Some(rx)),
            })
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
