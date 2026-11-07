//! One project's index in the hub: its store, tier 1 (the file list and the rebuilt rows) and tier 2 (vectors, from
//! each embedder, between gates).
//!
//! - **Identity.** The store is `<state>/code/<id>.db`, `id` the first 16 hex characters of the sha256 of the main
//!   worktree's real path. A linked worktree maps to its main checkout (`git rev-parse --git-common-dir`), so worktree
//!   agents search main's store.
//! - **The deny-list.** A root `DenyList::check_root` refuses is refused before any file is listed; inside an allowed
//!   root, every file is checked again on its way into the list.
//! - **Tier 1.** [`Project::refresh_now`] lists the files and rebuilds the rows of those whose blob changed.
//!   [`Project::tick`] does it when the settle core says a watcher's events are due (git after `index.lock` and 2 s
//!   of quiet, a save after 30 s); without watches, [`Project::fresh_for_query`] diffs the blobs at query time.
//! - **Tier 2.** Requests of [`REQUEST_KEYS`] missing keys to each embedder that answers (a server that is not running
//!   gets none, and is no failure, until the next change wakes tier 2). Between requests it waits while typing
//!   holds ([`TYPING_HOLD`] from the last [`Project::note_typing`]) and, on battery, until AC or
//!   [`Project::index_now`]. Idle, it stays idle until a wake finds a key missing. What it does is published as a
//!   [`Status`].

use super::{DocEmbedder, power};
use crate::clock;
use hrafn::fresh::{Due, Fresh, Settle};
use hrafn::{CodeStore, Config, Git, GitCli, Lag, Listed, Refresh, StoreError, WatchEvent};
use norn::deny::{DenyList, RootVerdict, Verdict};
use sha2::{Digest, Sha256};
use std::io;
use std::os::fd::AsFd;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{Notify, watch};

/// Keys in one tier-2 request: about 0.25 s on the Radeon, 7 s on the CPU path.
pub const REQUEST_KEYS: u32 = 8;
/// How long tier 2 holds after the last keystroke.
pub const TYPING_HOLD: Duration = Duration::from_secs(3);
/// How often tier 2 looks at the power supply again while it waits on battery.
pub const POWER_POLL: Duration = Duration::from_secs(10);
/// The gitdir's quiet period before a git change is refreshed.
pub const GIT_QUIET: Duration = Duration::from_secs(2);
/// A saved file is refreshed once it has been quiet this long.
pub const SAVE_DEBOUNCE: Duration = Duration::from_secs(30);
/// The most differences the query-time diff names before it refreshes everything.
pub const DIFF_LIMIT: usize = 2000;

/// The project of ROOT: its main checkout's real path and its id.
pub fn project_id(root: &Path) -> io::Result<(PathBuf, String)> {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()?;
    let main = if out.status.success() {
        let common = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
        match common.file_name() {
            Some(n) if n == ".git" => common.parent().map_or(common.clone(), Path::to_path_buf),
            _ => common, // a bare repository
        }
    } else {
        root.to_path_buf()
    };
    let real = std::fs::canonicalize(main)?;
    let sum = Sha256::digest(real.as_os_str().as_bytes());
    let id: String = sum.iter().take(8).map(|b| format!("{b:02x}")).collect();
    Ok((real, id))
}

/// `<state>/code/<id>.db`.
pub fn store_path(state: &Path, id: &str) -> PathBuf {
    state.join("code").join(format!("{id}.db"))
}

/// What a project is opened with.
pub struct ProjectSpec {
    /// Any checkout of the project: a linked worktree means its main checkout.
    pub root: PathBuf,
    /// The hub's state directory.
    pub state: PathBuf,
    /// HOME and the config directory, for the deny-list.
    pub home: PathBuf,
    pub config_dir: PathBuf,
    /// The project's `drgnx-search-*` settings and `.drgnx/search.eld`, as the hub resolved them.
    pub config: Config,
    /// Tier 2's embedders (the built-in model's worker, and the servers that answer): each fills its own model's
    /// vectors.
    pub embedders: Vec<Arc<dyn DocEmbedder>>,
    /// The sysfs root for the battery gate (`/sys`).
    pub power_root: PathBuf,
    /// Test-hooks: tier 2 takes one permit before each request.
    #[cfg(feature = "test-hooks")]
    pub test_permits: Option<Arc<tokio::sync::Semaphore>>,
}

#[derive(Debug)]
pub enum ProjectError {
    /// The deny-list refuses the root.
    Denied(String),
    Io(io::Error),
    Store(StoreError),
}

impl std::fmt::Display for ProjectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProjectError::Denied(why) => write!(f, "the project root is refused: {why}"),
            ProjectError::Io(e) => write!(f, "{e}"),
            ProjectError::Store(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for ProjectError {}

impl From<StoreError> for ProjectError {
    fn from(e: StoreError) -> Self {
        ProjectError::Store(e)
    }
}

impl From<io::Error> for ProjectError {
    fn from(e: io::Error) -> Self {
        ProjectError::Io(e)
    }
}

/// What tier 2 is doing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Tier2 {
    /// Not started.
    Stopped,
    /// Nothing missing.
    Idle,
    /// Sending requests.
    Running,
    /// Waiting while typing holds.
    Typing,
    /// Waiting on battery.
    Battery,
    /// An embedder failed; tier 2 waits for the next change.
    Failed(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub tier2: Tier2,
    /// Vectors tier 2 has written since the project opened.
    pub embedded: u64,
}

#[derive(Default)]
struct Gate {
    hold_until: Option<tokio::time::Instant>,
    /// A task waits for the hold to end.
    timer: bool,
    /// `index now`: tier 2 runs on battery until nothing is missing.
    overriding: bool,
}

struct Inner {
    root: PathBuf,
    id: String,
    store: CodeStore,
    deny: DenyList,
    config: Config,
    embedders: Vec<Arc<dyn DocEmbedder>>,
    power_root: PathBuf,
    gate: Mutex<Gate>,
    wake: Notify,
    status: watch::Sender<Status>,
    tier1: tokio::sync::Mutex<()>,
    settle: Mutex<Settle>,
    events: Mutex<Option<Receiver<WatchEvent>>>,
    /// Others reading the same events (the edit history): each event is copied to them as `tick` takes it.
    taps: Mutex<Vec<std::sync::mpsc::Sender<WatchEvent>>>,
    opened: tokio::time::Instant,
    #[cfg(feature = "test-hooks")]
    permits: Option<Arc<tokio::sync::Semaphore>>,
}

/// One project's index. Dropping it stops tier 2; its workers exit when their stdin closes.
pub struct Project {
    inner: Arc<Inner>,
    tier2: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Drop for Project {
    fn drop(&mut self) {
        if let Ok(mut t) = self.tier2.lock()
            && let Some(h) = t.take()
        {
            h.abort();
        }
    }
}

impl Project {
    /// Opens (creating) the project's store; refuses a root the deny-list refuses, before anything is listed.
    pub async fn open(spec: ProjectSpec) -> Result<Project, ProjectError> {
        let deny = DenyList::load(&spec.home, &spec.config_dir);
        if let RootVerdict::Denied { why } = deny.check_root(&spec.root) {
            return Err(ProjectError::Denied(why));
        }
        let given = spec.root.clone();
        let (root, id) = crate::clock::blocking(move || project_id(&given))
            .await
            .map_err(io::Error::other)??;
        if let RootVerdict::Denied { why } = deny.check_root(&root) {
            return Err(ProjectError::Denied(why));
        }
        let path = store_path(&spec.state, &id);
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let store = CodeStore::open(&path)?;
        let (status, _) = watch::channel(Status {
            tier2: Tier2::Stopped,
            embedded: 0,
        });
        Ok(Project {
            inner: Arc::new(Inner {
                root,
                id,
                store,
                deny,
                config: spec.config,
                embedders: spec.embedders,
                power_root: spec.power_root,
                gate: Mutex::new(Gate::default()),
                wake: Notify::new(),
                status,
                tier1: tokio::sync::Mutex::new(()),
                settle: Mutex::new(Settle::new(GIT_QUIET, SAVE_DEBOUNCE)),
                events: Mutex::new(None),
                taps: Mutex::new(Vec::new()),
                opened: clock::now(),
                #[cfg(feature = "test-hooks")]
                permits: spec.test_permits,
            }),
            tier2: Mutex::new(None),
        })
    }

    /// The main checkout's real path.
    pub fn root(&self) -> &Path {
        &self.inner.root
    }

    pub fn id(&self) -> &str {
        &self.inner.id
    }

    pub fn store(&self) -> &CodeStore {
        &self.inner.store
    }

    pub fn status(&self) -> watch::Receiver<Status> {
        self.inner.status.subscribe()
    }

    /// The watcher's events from now on; `tick` feeds them to the settle core.
    pub fn watch(&self, w: &dyn hrafn::Watch) {
        if let Ok(mut e) = self.inner.events.lock() {
            *e = Some(w.events());
        }
    }

    /// A second reader of the watcher's events from now on (one watcher per project): every event `tick` takes is
    /// copied to it.  Dropping the receiver ends the tap.
    pub fn tap(&self) -> Receiver<WatchEvent> {
        let (tx, rx) = std::sync::mpsc::channel();
        if let Ok(mut t) = self.inner.taps.lock() {
            t.push(tx);
        }
        rx
    }

    /// Tier 1 now: the file list, and the rows of the files whose blob changed.
    pub async fn refresh_now(&self) -> Result<Refresh, ProjectError> {
        let inner = self.inner.clone();
        let _one = inner.tier1.lock().await;
        let job = inner.clone();
        // the listing runs git and reads every file; the chunking is CPU work: neither on a runtime worker
        let rt = tokio::runtime::Handle::current();
        let r = crate::clock::blocking(move || rt.block_on(job.refresh()))
            .await
            .map_err(io::Error::other)??;
        if r.keys_missing > 0 || r.files_changed > 0 {
            inner.wake.notify_one();
        }
        Ok(r)
    }

    /// Tier 1 when the watcher's events are due (or the index was never built).
    pub async fn tick(&self) -> Result<Option<Refresh>, ProjectError> {
        let due = {
            let events: Vec<WatchEvent> = match self.inner.events.lock() {
                Ok(g) => g
                    .as_ref()
                    .map_or_else(Vec::new, |rx| rx.try_iter().collect()),
                Err(_) => vec![],
            };
            if let Ok(mut taps) = self.inner.taps.lock() {
                taps.retain(|t| events.iter().all(|e| t.send(e.clone()).is_ok()));
            }
            let now = clock::now() - self.inner.opened;
            let mut settle = self
                .inner
                .settle
                .lock()
                .map_err(|_| io::Error::other("settle"))?;
            let mut due = None;
            for e in events {
                let fed = match e {
                    WatchEvent::File(p) => Fresh::Save(p),
                    WatchEvent::Git => Fresh::Git,
                    WatchEvent::Lock(on) => Fresh::Lock(on),
                };
                settle.feed(Fresh::At(now));
                due = due.or(settle.feed(fed));
            }
            due.or(settle.feed(Fresh::At(now)))
        };
        let built = self
            .inner
            .store
            .meta_get(hrafn::index::META_BUILT_FROM)
            .await?
            .is_some();
        match due {
            Some(Due::All | Due::Files(_)) => Ok(Some(self.refresh_now().await?)),
            None if !built => Ok(Some(self.refresh_now().await?)),
            None => Ok(None),
        }
    }

    /// Before a query, for a project with no watches: the blobs diffed (at most [`DIFF_LIMIT`] named), tier 1 when
    /// any differ.
    pub async fn fresh_for_query(&self) -> Result<Option<Refresh>, ProjectError> {
        let has_watch = self.inner.events.lock().is_ok_and(|e| e.is_some());
        if has_watch {
            return self.tick().await;
        }
        let inner = self.inner.clone();
        let listed = crate::clock::blocking(move || inner.list())
            .await
            .map_err(io::Error::other)??;
        let d = hrafn::fresh::diff(&self.inner.store, &listed, DIFF_LIMIT).await?;
        if d.is_empty() {
            return Ok(None);
        }
        Ok(Some(self.refresh_now().await?))
    }

    /// Holds tier 2 for [`TYPING_HOLD`] from now (between requests, never inside one).
    pub fn note_typing(&self) {
        let until = clock::now() + TYPING_HOLD;
        let start_timer = match self.inner.gate.lock() {
            Ok(mut g) => {
                g.hold_until = Some(until);
                !std::mem::replace(&mut g.timer, true)
            }
            Err(_) => false,
        };
        if start_timer {
            let inner = self.inner.clone();
            clock::spawn("search:typing", async move {
                loop {
                    let wait = match inner.gate.lock() {
                        Ok(mut g) => match g.hold_until {
                            Some(t) if t > clock::now() => Some(t - clock::now()),
                            _ => {
                                g.timer = false;
                                None
                            }
                        },
                        Err(_) => None,
                    };
                    match wait {
                        Some(d) => clock::sleep(d).await,
                        None => break,
                    }
                }
                inner.wake.notify_one();
            });
        }
    }

    /// `search/index` with `now`: tier 2 runs on battery too, until nothing is missing.
    pub fn index_now(&self) {
        if let Ok(mut g) = self.inner.gate.lock() {
            g.overriding = true;
        }
        self.inner.wake.notify_one();
    }

    /// Starts tier 2 (once).
    pub fn start_tier2(&self) {
        let Ok(mut t) = self.tier2.lock() else { return };
        if t.is_some() {
            return;
        }
        let inner = self.inner.clone();
        *t = Some(clock::spawn(
            "search:tier2",
            async move { inner.tier2().await },
        ));
    }

    pub async fn lag(&self, model: Option<&str>) -> Result<Lag, ProjectError> {
        Ok(hrafn::lag(&self.inner.store, model, hrafn::View::Base).await?)
    }

    /// The file REL as it is now (read through the root's descriptor, at most [`hrafn::files::MAX_FILE_BYTES`]); none
    /// when it cannot be read or is not text.
    pub fn read_now(&self, rel: &str) -> Option<String> {
        let root = eitri::open_path(&self.inner.root, eitri::Kind::Dir).ok()?;
        let bytes = eitri::read_regular(
            root.fd.as_fd(),
            Path::new(rel),
            hrafn::files::MAX_FILE_BYTES,
        )
        .ok()?;
        String::from_utf8(bytes).ok()
    }

    /// What is wrong with the index's coverage of the listed files (storage design §12A.3 item 9), one line each.
    pub async fn coverage_errors(&self) -> Result<Vec<String>, ProjectError> {
        let inner = self.inner.clone();
        let listed = crate::clock::blocking(move || inner.list())
            .await
            .map_err(io::Error::other)??;
        let per_file: std::collections::HashMap<String, u32> = self
            .inner
            .store
            .handle()
            .read(|c| {
                // the base's chunks: the store holds worktrees' content too
                let mut st = c.prepare(
                    "select c.path, count(*) from chunk c
                     join file f on f.tree = 0 and f.path = c.path and f.blob = c.blob group by c.path",
                )?;
                let rows = st
                    .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<Result<_, _>>()?;
                Ok(rows)
            })
            .await
            .map_err(StoreError::from)?;
        Ok(hrafn::coverage(&listed, &per_file)
            .into_iter()
            .map(|e| match e {
                hrafn::CoverageError::ClassWithNoChunks(c) => {
                    format!(
                        "files of class {} are listed and none has a chunk",
                        c.as_str()
                    )
                }
                hrafn::CoverageError::FileWithoutChunks(p) => format!("{p} has no chunk"),
            })
            .collect())
    }

    /// Drops the index's rows (the vectors stay) and builds them again.
    pub async fn rebuild(&self) -> Result<Refresh, ProjectError> {
        hrafn::reset(&self.inner.store).await?;
        self.refresh_now().await
    }
}

impl Inner {
    fn allowed(&self, rel: &str) -> bool {
        self.deny.check(&self.root.join(rel)) == Verdict::Allowed
    }

    /// The file list (blocking: git and a read of every file).
    fn list(&self) -> io::Result<Vec<Listed>> {
        hrafn::list(&self.root, &GitCli, &self.config, &|p: &str| {
            self.allowed(p)
        })
    }

    fn models(&self) -> Vec<(String, usize)> {
        self.embedders
            .iter()
            .map(|e| (e.model().to_string(), e.dims()))
            .collect()
    }

    async fn refresh(&self) -> Result<Refresh, ProjectError> {
        let listed = self.list()?;
        let root = eitri::open_path(&self.root, eitri::Kind::Dir)
            .map_err(|e| io::Error::other(e.to_string()))?;
        let read = |p: &str| {
            eitri::read_regular(root.fd.as_fd(), Path::new(p), hrafn::files::MAX_FILE_BYTES)
                .map_err(|e| io::Error::other(e.to_string()))
        };
        let models = self.models();
        let pairs: Vec<(&str, usize)> = models.iter().map(|(m, d)| (m.as_str(), *d)).collect();
        let r = hrafn::refresh(&self.store, &listed, &read, &pairs).await?;
        if let Ok(head) = GitCli.head(&self.root) {
            self.store
                .meta_set(hrafn::index::META_BUILT_FROM, &head)
                .await?;
        }
        Ok(r)
    }

    fn publish(&self, tier2: Tier2) {
        self.status.send_if_modified(|s| {
            let changed = s.tier2 != tier2;
            s.tier2 = tier2;
            changed
        });
    }

    /// Waits until the gates let a request go; whether it goes as `index now`.
    async fn gates(&self) -> bool {
        loop {
            let (typing, overriding) = match self.gate.lock() {
                Ok(g) => (g.hold_until.is_some_and(|t| t > clock::now()), g.overriding),
                Err(_) => (false, false),
            };
            if typing {
                self.publish(Tier2::Typing);
                self.wake.notified().await;
                continue;
            }
            if !overriding && power::on_battery(&self.power_root) {
                self.publish(Tier2::Battery);
                tokio::select! {
                    () = self.wake.notified() => {}
                    () = clock::sleep(POWER_POLL) => {}
                }
                continue;
            }
            return overriding;
        }
    }

    async fn tier2(self: Arc<Self>) {
        if self.embedders.is_empty() {
            self.publish(Tier2::Idle);
            return;
        }
        loop {
            #[cfg(feature = "test-hooks")]
            if let Some(p) = &self.permits {
                match p.acquire().await {
                    Ok(permit) => permit.forget(),
                    Err(_) => return,
                }
            }
            let overriding = self.gates().await;
            let mut sent = false;
            for e in &self.embedders {
                // a server that is not running is no failure of tier 2: it is asked again at the next change
                if !e.answers().await {
                    continue;
                }
                let keys = match hrafn::missing(&self.store, e.model(), REQUEST_KEYS).await {
                    Ok(k) => k,
                    Err(err) => {
                        self.publish(Tier2::Failed(err.to_string()));
                        continue;
                    }
                };
                if keys.is_empty() {
                    continue;
                }
                self.publish(Tier2::Running);
                let texts: Vec<String> = keys.iter().map(|(_, t)| t.clone()).collect();
                match e.embed_docs(&texts, overriding).await {
                    Ok(vectors) if vectors.len() == keys.len() => {
                        let rows: Vec<([u8; 32], Vec<f32>)> =
                            keys.iter().map(|(k, _)| *k).zip(vectors).collect();
                        if let Err(err) = hrafn::put_vectors(&self.store, e.model(), &rows).await {
                            self.publish(Tier2::Failed(err.to_string()));
                            continue;
                        }
                        self.status.send_modify(|s| s.embedded += rows.len() as u64);
                        sent = true;
                    }
                    Ok(vectors) => self.publish(Tier2::Failed(format!(
                        "{} vectors for {} texts",
                        vectors.len(),
                        keys.len()
                    ))),
                    Err(err) => self.publish(Tier2::Failed(err.0)),
                }
            }
            if !sent {
                if let Ok(mut g) = self.gate.lock() {
                    g.overriding = false;
                }
                for e in &self.embedders {
                    let _ = hrafn::collect(&self.store, e.model()).await;
                }
                if !matches!(self.status.borrow().tier2, Tier2::Failed(_)) {
                    self.publish(Tier2::Idle);
                }
                self.until_missing().await;
            }
        }
    }

    /// Waits until a wake finds a key missing for an embedder that answers. A wake is only a hint: `Notify` keeps one
    /// sent while tier 2 was not waiting (a refresh, `index now` read before its wake), so one that finds nothing to
    /// do leaves tier 2 where it is, idle, and ends an `index now`, rather than taking it back to its gates.
    async fn until_missing(&self) {
        loop {
            self.wake.notified().await;
            for e in &self.embedders {
                // a store error is the pass's to report
                if e.answers().await
                    && !matches!(hrafn::missing(&self.store, e.model(), 1).await, Ok(k) if k.is_empty())
                {
                    return;
                }
            }
            if let Ok(mut g) = self.gate.lock() {
                g.overriding = false;
            }
        }
    }
}
