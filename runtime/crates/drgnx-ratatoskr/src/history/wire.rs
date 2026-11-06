//! The `history/*` methods: the front's handlers over [`Hub`].  One hub per project (its git common folder), its
//! `history.db` under `<state>/hub/history/<project>/`.  Git and the store run in blocking tasks.

use super::watch;
use super::{BatchChange, BatchReply, Hub, Tree};
use crate::dispatch::Caller;
use crate::front::Front;
use crate::runner::{internal, invalid};
use runstav::methods::history as w;
use runstav::wire::Error;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};

/// The open projects' histories, and which hub each tracked buffer belongs to.
#[derive(Default)]
pub struct Hubs {
    open: Mutex<HashMap<String, Arc<Hub>>>,
    buffers: Mutex<HashMap<String, Arc<Hub>>>,
    /// The revert previews not applied yet, and the worktrees a revert runs in.
    pub(crate) reverts: super::revert::Reverts,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// P with its `.` and `..` components taken away by name (no link is read): a linked worktree's `commondir` (`../..`)
/// names its project's common folder as the main worktree's `.git` is named, so both share one history.
fn tidy(p: &Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            c => out.push(c),
        }
    }
    out
}

/// ROOT's git directory and its common folder, read as an agent-writable pointer is: no link followed.  A `.git` file
/// (a linked worktree) is followed to its `gitdir:` and `commondir`.
pub(crate) fn git_dirs(root: &Path) -> Option<(PathBuf, PathBuf)> {
    use rustix::fs::{Mode, OFlags};
    let dir = rustix::fs::open(
        root,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .ok()?;
    let dot = root.join(".git");
    if eitri::open_beneath(dir.as_fd(), Path::new(".git"), eitri::Kind::Dir).is_ok() {
        return Some((dot.clone(), dot));
    }
    let text =
        String::from_utf8(eitri::read_regular(dir.as_fd(), Path::new(".git"), 4096).ok()?).ok()?;
    let target = text.trim().strip_prefix("gitdir:")?.trim();
    let gitdir = if Path::new(target).is_absolute() {
        PathBuf::from(target)
    } else {
        root.join(target)
    };
    let gd = rustix::fs::open(
        &gitdir,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .ok()?;
    let common = eitri::read_regular(gd.as_fd(), Path::new("commondir"), 4096)
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
        .map_or_else(|| gitdir.clone(), |c| gitdir.join(c.trim()));
    Some((gitdir, tidy(&common)))
}

fn key_of(common: &Path) -> String {
    Sha256::digest(common.as_os_str().as_encoded_bytes())
        .iter()
        .take(8)
        .map(|b| format!("{b:02x}"))
        .collect()
}

impl Hubs {
    fn hub_for(&self, dir: &Path, key: &str) -> Result<Arc<Hub>, Error> {
        let mut open = lock(&self.open);
        if let Some(h) = open.get(key) {
            return Ok(h.clone());
        }
        let hub = Arc::new(Hub::open(&dir.join(key)).map_err(|e| internal(e.to_string()))?);
        hub.start_timers();
        open.insert(key.to_owned(), hub.clone());
        Ok(hub)
    }

    /// The history of the project worktree ROOT belongs to, and the tree (its git directory read with no link
    /// followed; nothing here runs git in it).  Every history the state folder STATE holds, for the start-up's pending
    /// reverts: [`Hubs::all`].
    pub(crate) fn of_tree(&self, state: &Path, root: &Path) -> Result<(Arc<Hub>, Tree), Error> {
        let (git_dir, common) = git_dirs(root)
            .ok_or_else(|| invalid(format!("{} is not a git worktree", root.display())))?;
        let hub = self.hub_for(&state.join("history"), &key_of(&common))?;
        let tree = Tree::new(
            root,
            &git_dir,
            crate::timeline::snapshot::head_of(root).as_deref(),
        );
        Ok((hub, tree))
    }

    /// Every project history under STATE (`<state>/history/<project>/`), opened.
    pub(crate) fn all(&self, state: &Path) -> Vec<Arc<Hub>> {
        let dir = state.join("history");
        let Ok(rd) = std::fs::read_dir(&dir) else {
            return Vec::new();
        };
        let mut keys: Vec<String> = rd
            .flatten()
            .filter(|e| e.path().join("history.db").exists())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        keys.sort();
        keys.iter()
            .filter_map(|k| self.hub_for(&dir, k).ok())
            .collect()
    }

    fn of_buffer(&self, id: &str) -> Result<Arc<Hub>, Error> {
        lock(&self.buffers)
            .get(id)
            .cloned()
            .ok_or_else(|| invalid(format!("buffer {id} is not registered")))
    }
}

fn failed(e: verdandi::Error) -> Error {
    match e {
        verdandi::Error::Refused(m) => invalid(m),
        verdandi::Error::NotFound(m) => invalid(format!("not found: {m}")),
        e => internal(e.to_string()),
    }
}

/// `history/register`.
pub async fn register(f: &Front, _: &Caller, p: w::RegisterParams) -> Result<w::Registered, Error> {
    let untracked = |why: &str| w::Registered {
        doc: 0,
        tracked: false,
        reason: Some(why.to_owned()),
    };
    let root = PathBuf::from(&p.worktree_root);
    let (Some((git_dir, common)), Some(dirs)) = (git_dirs(&root), f.dirs.get()) else {
        return Ok(untracked("ignored"));
    };
    // plain git never runs where a sandboxed agent worked
    if f.core.runs.git().is_touched(&root).await.unwrap_or(true) {
        return Ok(untracked("agent-tree"));
    }
    let hub = f
        .core
        .history
        .hub_for(&dirs.hub.join("history"), &key_of(&common))?;
    let deny = norn::deny::DenyList::load(&dirs.home, &dirs.config);
    let (h2, id, rel) = (hub.clone(), p.buffer_id.clone(), p.path.clone());
    let root2 = root.clone();
    let tree = crate::clock::blocking(move || {
        let tree = Tree::new(
            &root2,
            &git_dir,
            crate::timeline::snapshot::head_of(&root2).as_deref(),
        );
        h2.register(&tree, &rel, &id, &deny).map(|r| (tree, r))
    })
    .await
    .map_err(|e| internal(e.to_string()))?
    .map_err(failed)?;
    let (tree, r) = tree;
    if r.tracked {
        lock(&f.core.history.buffers).insert(p.buffer_id, hub.clone());
        start_watch(f, hub, tree, root).await;
    }
    Ok(w::Registered {
        doc: r.doc,
        tracked: r.tracked,
        reason: r.reason,
    })
}

/// The watcher's events for TREE reach the hub, once per tree: a second reader of the project's one watcher.
async fn start_watch(f: &Front, hub: Arc<Hub>, tree: Tree, root: PathBuf) {
    static WATCHED: Mutex<Vec<String>> = Mutex::new(Vec::new());
    {
        let mut w = lock(&WATCHED);
        if w.contains(&tree.id.0) {
            return;
        }
        w.push(tree.id.0.clone());
    }
    let Ok(project) = f.search.project(f, &root).await else {
        lock(&WATCHED).retain(|i| *i != tree.id.0);
        return;
    };
    let rx = Arc::new(Mutex::new(project.tap()));
    let weak = Arc::downgrade(&hub);
    drop(hub);
    crate::clock::spawn("history:watch", async move {
        loop {
            let Some(hub) = weak.upgrade() else { return };
            let (t, r) = (tree.clone(), rx.clone());
            let now = crate::clock::wall_secs();
            let _ = crate::clock::blocking(move || {
                let rx = lock(&r);
                watch::pump(&hub, &t, &rx, now);
            })
            .await;
            crate::clock::sleep(std::time::Duration::from_secs(1)).await;
        }
    });
}

/// `history/batch`.
pub async fn batch(f: &Front, _: &Caller, p: w::BatchParams) -> Result<w::BatchResult, Error> {
    let hub = f.core.history.of_buffer(&p.buffer_id)?;
    let changes: Vec<BatchChange> = p
        .changes
        .into_iter()
        .map(|c| BatchChange {
            start: usize::try_from(c.start).unwrap_or(usize::MAX),
            old_len: usize::try_from(c.old_len).unwrap_or(usize::MAX),
            inserted: c.inserted,
            origin: c.origin.unwrap_or_else(|| "user".into()),
        })
        .collect();
    let (id, hash) = (p.buffer_id, p.region_hash);
    // the time is read here: a blocking thread does not carry the virtual clock
    let now = crate::clock::wall_secs();
    let reply = crate::clock::blocking(move || hub.batch(&id, &changes, &hash, now))
        .await
        .map_err(|e| internal(e.to_string()))?
        .map_err(failed)?;
    Ok(match reply {
        BatchReply::Ok => w::BatchResult {
            ok: Some(true),
            resync: None,
        },
        BatchReply::Resync => w::BatchResult {
            ok: None,
            resync: Some(true),
        },
    })
}

/// `history/resync`.
pub async fn resync(f: &Front, _: &Caller, p: w::ResyncParams) -> Result<w::Done, Error> {
    let hub = f.core.history.of_buffer(&p.buffer_id)?;
    let now = crate::clock::wall_secs();
    crate::clock::blocking(move || hub.resync(&p.buffer_id, &p.text, now))
        .await
        .map_err(|e| internal(e.to_string()))?
        .map_err(failed)?;
    Ok(w::Done { ok: true })
}

/// `history/unregister`.
pub async fn unregister(f: &Front, _: &Caller, p: w::UnregisterParams) -> Result<w::Done, Error> {
    if let Some(hub) = lock(&f.core.history.buffers).remove(&p.buffer_id) {
        hub.unregister(&p.buffer_id);
    }
    Ok(w::Done { ok: true })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pure (D, a temporary repository): a linked worktree names its project's common folder as the main worktree
    /// does, so both are one project's history.
    #[test]
    fn a_linked_worktree_is_its_projects_history() {
        let d = tempfile::tempdir().unwrap();
        let (main, linked) = (d.path().join("main"), d.path().join("main/.claude/wt"));
        std::fs::create_dir_all(&main).unwrap();
        let git = |args: &[&str]| {
            let ok = std::process::Command::new("git")
                .args(["-c", "user.name=t", "-c", "user.email=t@t"])
                .args(args)
                .current_dir(&main)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .status()
                .unwrap()
                .success();
            assert!(ok, "git {args:?}");
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["commit", "-q", "--allow-empty", "-m", "base"]);
        git(&[
            "worktree",
            "add",
            "-q",
            "-b",
            "wt",
            linked.to_str().unwrap(),
        ]);
        let (_, a) = git_dirs(&main).unwrap();
        let (gd, b) = git_dirs(&linked).unwrap();
        assert_ne!(gd, b, "a linked worktree's own folder");
        assert_eq!(key_of(&a), key_of(&b), "{a:?} {b:?}");
    }
}
