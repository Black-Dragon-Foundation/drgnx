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
//! - **The vectors** are in the state's machine-wide caches ([`Caches`], one file per fingerprint): the store holds
//!   keys only, and every refresh reports its live key set to the cache of each fingerprint the embedders proved.
//! - **Tier 2** is a chain of sources per fingerprint ([`super::sources`]): requests of at most a source's `max_batch`
//!   missing keys ([`REQUEST_KEYS`] for the built-in model and servers), open and recently edited files first, then by
//!   git recency. Each embedder states its model by a probe (a server that is not running is no failure: it is
//!   asked again at the next change); the ones that state the same fingerprint are one chain, with a backoff per
//!   source. The built-in model's chain runs only while the main chains have nothing to fill. Between requests tier 2
//!   waits while typing holds ([`TYPING_HOLD`] from the last [`Project::note_typing`]); on battery the local sources
//!   (the built-in model) wait until AC, [`Project::index_now`] or `drgnx-search-battery-engine`, and remote ones go on.
//!   Idle, it stays idle until a wake finds a key missing or a down source is due. What it does is published as a
//!   [`Status`].

use super::caches::Caches;
use super::manage::{META_STATE, PauseWhy, RootState, UserState};
use super::sources::{ChainEntry, DocSource, Slot, Source, SourceChain, run_pass_with};
use super::{DocEmbedder, power};
use crate::clock;
use hrafn::fresh::{Due, Fresh, Settle};
use hrafn::{
    CodeStore, Config, Git, GitCli, Lag, Listed, Refresh, StoreError, VectorCache, WatchEvent,
};
use hrafn_embed::fingerprint::Identity;
use norn::deny::{DenyList, RootVerdict, Verdict};
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashMap, HashSet};
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
/// Paths of the order of work (open and edited files, then git recency) a batch looks through.
pub const ORDER_PATHS: usize = 500;
/// Recently edited files remembered for the order of work.
pub const RECENT_PATHS: usize = 64;
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
/// Worktree overlays a project holds rows for (resident trees); the least recently used one goes first.
pub const RESIDENT_CAP: usize = 16;
/// A stale or unwatched tree is checked at most this often.
pub const CHECK_TTL: Duration = Duration::from_secs(5);
/// A tree unused this long loses its rows (it seeds again on its next use).
pub const TREE_IDLE: Duration = Duration::from_secs(14 * 24 * 3600);
/// How often removed and idle trees are swept.
pub const TREE_SWEEP: Duration = Duration::from_secs(3600);

/// Which view answers a query about a root.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ViewOf {
    pub view: hrafn::View,
    /// The linked worktree's key (history's `WorktreeId`); none for the main checkout.
    pub worktree: Option<String>,
    /// Where the view's files are read (`now`): the tree's root, or the main checkout's.
    pub root: PathBuf,
    /// The tree's state; none for the main checkout. While `seeding`, `view` is the base.
    pub state: Option<hrafn::TreeState>,
    /// A seed or check of the tree runs now.
    pub checking: bool,
}

/// One worktree overlay, for the status and the tests.
#[derive(Clone, Debug)]
pub struct TreeLive {
    pub id: hrafn::TreeId,
    pub key: String,
    pub root: String,
    pub door: hrafn::DoorKind,
    pub state: hrafn::TreeState,
    pub watched: bool,
    /// Its `file` rows: the paths where it differs from the base.
    pub rows: u32,
    /// Checks (re-diffs) run since the project opened.
    pub checks: u64,
    /// What its last seed, check or re-check did.
    pub last: Option<hrafn::overlay::Seed>,
}

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

/// The files of ROOT by git recency: those changed by the newest commits first, each once (blocking: runs git).
fn git_recency(root: &Path) -> io::Result<Vec<String>> {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args([
            "-c",
            "core.quotepath=off",
            "log",
            "--name-only",
            "--no-renames",
            "--format=",
            "-n",
            "300",
        ])
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()?;
    if !out.status.success() {
        return Ok(Vec::new());
    }
    let mut seen = HashSet::new();
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter(|l| !l.is_empty())
        .filter(|l| seen.insert(l.to_string()))
        .take(ORDER_PATHS)
        .map(str::to_owned)
        .collect())
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
    /// The project's user layer (`drgnx-search-rules`) and `drgnx-search-off`, as the hub resolved them. The repo's
    /// layer (`.drgnx/search.toml`) is read at every listing, not here.
    pub config: Config,
    /// Tier 2's embedders (the built-in model's worker, and the servers that answer): each fills its own model's
    /// vectors.
    pub embedders: Vec<Arc<dyn DocEmbedder>>,
    /// The sysfs root for the battery gate (`/sys`).
    pub power_root: PathBuf,
    /// The checkout the base is built from (`drgnx-search-base`); none: the main checkout.
    pub base: Option<PathBuf>,
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
    /// Paused by the user (`search/pause`) until `search/resume`.
    Paused,
    /// An embedder failed; tier 2 waits for the next change.
    Failed(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub tier2: Tier2,
    /// Chunk vectors tier 2 has written since the project opened (the path vectors that go with them not counted).
    pub embedded: u64,
}

/// A tree's work in the hub.
#[derive(Clone)]
enum Job {
    Seed,
    /// A re-diff: a git event, a lost event, a restart, or a query in a stale or unwatched tree.
    Check,
    /// Re-check these paths (watcher and feed hints).
    Recheck(Vec<String>),
}

/// What the hub knows of a tree beyond its registry row.
#[derive(Default)]
struct Live {
    /// The project's watcher serves it.
    watched: bool,
    /// Its watch was asked for (once per open: an unwatched tree is not retried on every query).
    tried: bool,
    /// A seed or check runs.
    busy: bool,
    /// A check was asked for while one ran: it runs again after.
    again: bool,
    checked: Option<tokio::time::Instant>,
    checks: u64,
    last: Option<hrafn::overlay::Seed>,
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
    /// The checkout tier 1 builds the base from: the main checkout, or the one `drgnx-search-base` names.
    base: PathBuf,
    id: String,
    store: CodeStore,
    /// The state's vector caches, shared with every project of the state.
    caches: Arc<Caches>,
    /// The fingerprints (hex) whose cache holds the store's live key set as of the last refresh.
    held: Mutex<HashSet<String>>,
    deny: DenyList,
    config: Config,
    /// Tier 2's sources: the spec's embedders, and what [`Project::add_sources`] added.
    sources: Mutex<Vec<Arc<dyn Source>>>,
    /// `drgnx-search-battery-engine`: the local sources run on battery.
    battery_engine: std::sync::atomic::AtomicBool,
    /// Open files, edited files (newest first) and the git recency of the paths, for the order of work (MP-14).
    open_paths: Mutex<Vec<String>>,
    recent_paths: Mutex<Vec<String>>,
    recency: Mutex<Option<Vec<String>>>,
    /// Each fingerprint's chain as the last pass left it, for `search/status`.
    chains: Mutex<Vec<(String, Vec<ChainEntry>)>>,
    power_root: PathBuf,
    gate: Mutex<Gate>,
    /// What the user set (`search/pause`, `resume`, `stop`), as the store's `index_state` keeps it.
    user: Mutex<UserState>,
    wake: Notify,
    status: watch::Sender<Status>,
    tier1: tokio::sync::Mutex<()>,
    settle: Mutex<Settle>,
    events: Mutex<Option<Receiver<WatchEvent>>>,
    /// The project's one watcher, which more trees (worktrees) join.
    watcher: Mutex<Option<Arc<hrafn::ProjectWatch>>>,
    /// Others reading the same events (the edit history): each event is copied to them as `tick` takes it.
    taps: Mutex<Vec<std::sync::mpsc::Sender<WatchEvent>>>,
    opened: tokio::time::Instant,
    /// The worktree overlays' state in the hub, by tree.
    trees: Mutex<HashMap<hrafn::TreeId, Live>>,
    /// The trees' running work (seeds, checks, re-checks, sweeps).
    jobs: Mutex<Vec<tokio::task::JoinHandle<()>>>,
    /// The history feed is attached.
    fed: std::sync::atomic::AtomicBool,
    /// When the trees were last swept.
    swept: Mutex<Option<tokio::time::Instant>>,
    /// Directories Hrafn watches at most: half of `max_user_watches`.
    watch_budget: Mutex<Option<usize>>,
    /// What the base's last listing read: the next reads and hashes only the files whose status moved.
    listing: Mutex<hrafn::files::Snapshot>,
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
        // the base: another checkout of this project when the setting names one, else the main checkout
        let base = match spec.base {
            Some(b) => {
                let (r2, b2) = (root.clone(), b.clone());
                let same = crate::clock::blocking(move || {
                    let real = std::fs::canonicalize(&b2).ok()?;
                    (project_id(&real).ok()?.0 == r2).then_some(real)
                })
                .await
                .ok()
                .flatten();
                if same.is_none() {
                    tracing::warn!(
                        "search: drgnx-search-base {} is not a checkout of {}: the main checkout is the base",
                        b.display(),
                        root.display()
                    );
                }
                same.unwrap_or_else(|| root.clone())
            }
            None => root.clone(),
        };
        let store = CodeStore::open(&path)?;
        // another base: the base is built again from it, and every tree re-seeds against it
        let named = base.to_string_lossy().into_owned();
        if store.meta_get(META_BASE_ROOT).await?.as_deref() != Some(named.as_str()) {
            if store.meta_get(META_BASE_ROOT).await?.is_some() {
                hrafn::reset(&store).await?;
            }
            store.meta_set(META_BASE_ROOT, &named).await?;
        }
        // edits may have happened while the hub was down: every tree is checked on its next use
        store.trees_reopened().await?;
        let user = UserState::parse(store.meta_get(META_STATE).await?.as_deref());
        let (status, _) = watch::channel(Status {
            tier2: Tier2::Stopped,
            embedded: 0,
        });
        Ok(Project {
            inner: Arc::new(Inner {
                root,
                base,
                id,
                store,
                caches: Caches::shared(&spec.state),
                held: Mutex::new(HashSet::new()),
                deny,
                config: spec.config,
                sources: Mutex::new(
                    spec.embedders
                        .into_iter()
                        .map(|e| Arc::new(DocSource::new(e)) as Arc<dyn Source>)
                        .collect(),
                ),
                battery_engine: false.into(),
                open_paths: Mutex::new(Vec::new()),
                recent_paths: Mutex::new(Vec::new()),
                recency: Mutex::new(None),
                chains: Mutex::new(Vec::new()),
                power_root: spec.power_root,
                gate: Mutex::new(Gate::default()),
                user: Mutex::new(user),
                wake: Notify::new(),
                status,
                tier1: tokio::sync::Mutex::new(()),
                settle: Mutex::new(Settle::new(GIT_QUIET, SAVE_DEBOUNCE)),
                events: Mutex::new(None),
                watcher: Mutex::new(None),
                taps: Mutex::new(Vec::new()),
                opened: clock::now(),
                trees: Mutex::new(HashMap::new()),
                jobs: Mutex::new(Vec::new()),
                fed: false.into(),
                swept: Mutex::new(None),
                watch_budget: Mutex::new(None),
                listing: Mutex::new(Default::default()),
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

    /// The checkout the base is built from (the main checkout unless `drgnx-search-base` names another).
    pub fn base_root(&self) -> &Path {
        &self.inner.base
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
    pub fn watch(&self, w: Arc<hrafn::ProjectWatch>) {
        if let Ok(mut e) = self.inner.events.lock() {
            *e = Some(hrafn::Watch::events(&*w));
        }
        if let Ok(mut h) = self.inner.watcher.lock() {
            *h = Some(w);
        }
        if let Ok(mut b) = self.inner.watch_budget.lock() {
            *b = std::fs::read_to_string(MAX_USER_WATCHES)
                .ok()
                .and_then(|t| t.trim().parse::<usize>().ok())
                .map(|n| n / 2);
        }
    }

    /// Another tree of this project (a worktree) joins the project's one watcher; its events are tagged with
    /// its key. Blocking: it walks the tree and runs git.
    pub fn add_tree(&self, spec: hrafn::TreeSpec) -> Result<(), hrafn::AddError> {
        let w = self.inner.watcher.lock().ok().and_then(|h| h.clone());
        match w {
            Some(w) => w.add_tree(spec),
            None => Err(hrafn::AddError::Other("the project has no watcher".into())),
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
        // a stop holds until the next change
        if r.files_changed > 0 && inner.user() == UserState::Stopped {
            self.resume().await?;
        }
        Ok(r)
    }

    /// Tier 1 when the watcher's events are due (or the index was never built).
    pub async fn tick(&self) -> Result<Option<Refresh>, ProjectError> {
        let mut hints: HashMap<String, BTreeSet<String>> = HashMap::new();
        let (mut gits, mut overflow) = (HashSet::new(), false);
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
            for e in &events {
                match e {
                    WatchEvent::File { tree, rel } if tree != hrafn::MAIN_TREE => {
                        hints.entry(tree.clone()).or_default().insert(rel.clone());
                    }
                    WatchEvent::Git { tree } if tree != hrafn::MAIN_TREE => {
                        gits.insert(tree.clone());
                    }
                    WatchEvent::Overflow => overflow = true,
                    _ => {}
                }
            }
            let mut due = None;
            for e in events {
                // only the main checkout's own events arm its tier 1: a save in a worktree wakes nothing here
                let Some(fed) = e.main_fresh() else { continue };
                settle.feed(Fresh::At(now));
                due = due.or(settle.feed(fed));
            }
            due.or(settle.feed(Fresh::At(now)))
        };
        // the worktrees' events go to their overlays; an overflow lost events of every tree
        self.inner.hints(hints, gits, overflow).await?;
        let sweep = match self.inner.swept.lock() {
            Ok(mut s) => {
                let now = clock::now();
                let due = s.is_none_or(|t| now - t >= TREE_SWEEP);
                if due {
                    *s = Some(now);
                }
                due
            }
            Err(_) => false,
        };
        if sweep {
            let inner = self.inner.clone();
            let h = clock::spawn("search:tree-sweep", async move {
                if let Err(e) = inner.sweep().await {
                    tracing::warn!(
                        "search: the worktree sweep of {}: {e}",
                        inner.root.display()
                    );
                }
                // the state's caches, beside it (once per CACHE_SWEEP, whichever project comes first)
                let now_ms = (clock::wall_secs() * 1000.0) as i64;
                if let Err(e) = inner.caches.sweep_if_due(clock::now(), now_ms).await {
                    tracing::warn!("search: the vector cache sweep: {e}");
                }
            });
            if let Ok(mut j) = self.inner.jobs.lock() {
                j.push(h);
            }
        }
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
    /// any differ. The listing reads and hashes only the files whose status moved since the last one
    /// (`hrafn::files::list_with`).
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

    /// More sources for tier 2 (a lookup source, an engine): before [`start_tier2`](Self::start_tier2).
    pub fn add_sources(&self, more: Vec<Arc<dyn Source>>) {
        if let Ok(mut s) = self.inner.sources.lock() {
            s.extend(more);
        }
    }

    /// `drgnx-search-battery-engine` as it is now: the local sources run on battery. Applies at the next pass.
    pub fn set_battery_engine(&self, on: bool) {
        let was = self
            .inner
            .battery_engine
            .swap(on, std::sync::atomic::Ordering::Relaxed);
        if was != on {
            self.inner.wake.notify_one();
        }
    }

    /// The files open in the editor and the ones edited lately: tier 2 embeds their chunks first (MP-14); the rest
    /// follow by git recency. A history version of a file also makes it a recently edited one.
    pub fn order_hint(&self, open: &[String], recent: &[String]) {
        if let Ok(mut o) = self.inner.open_paths.lock() {
            *o = open.to_vec();
        }
        self.inner.note_recent(recent.iter().rev());
    }

    /// Each fingerprint's (hex) chain of sources as the last pass left it.
    pub fn chains(&self) -> Vec<(String, Vec<ChainEntry>)> {
        self.inner
            .chains
            .lock()
            .map(|c| c.clone())
            .unwrap_or_default()
    }

    /// `search/pause`: the batch in flight finishes, then tier 2 holds until [`resume`](Self::resume); kept in the
    /// store, so a restart or a file change does not undo it.
    pub async fn pause(&self) -> Result<(), ProjectError> {
        self.inner.set_user(UserState::Paused).await?;
        self.inner.wake.notify_one();
        Ok(())
    }

    /// `search/resume`: tier 2 goes on with the keys still missing (a pause or a stop lifted).
    pub async fn resume(&self) -> Result<(), ProjectError> {
        self.inner.set_user(UserState::On).await?;
        self.start_tier2();
        self.inner.wake.notify_one();
        Ok(())
    }

    /// `search/stop`: the running build is cancelled now; what it finished stays. The watcher stays on: the next change
    /// or `search/index` goes on from there.
    pub async fn stop(&self) -> Result<(), ProjectError> {
        self.inner.set_user(UserState::Stopped).await?;
        let running = self.tier2.lock().ok().and_then(|mut t| t.take());
        if let Some(h) = running {
            h.abort();
            let _ = h.await;
        }
        self.inner.publish(Tier2::Stopped);
        Ok(())
    }

    /// The root's state as the user sees it: the user's pause or stop first, then what tier 2 waits for.
    pub fn state(&self) -> RootState {
        match self.inner.user() {
            UserState::Stopped => return RootState::Stopped,
            UserState::Paused => return RootState::Paused(PauseWhy::User),
            UserState::On => {}
        }
        match self.inner.status.borrow().tier2 {
            Tier2::Battery => RootState::Paused(PauseWhy::Battery),
            Tier2::Failed(_) => RootState::Paused(PauseWhy::NoEmbedder),
            Tier2::Running | Tier2::Typing | Tier2::Paused => RootState::Running,
            Tier2::Idle | Tier2::Stopped if self.inner.sources().is_empty() => {
                RootState::Paused(PauseWhy::NoEmbedder)
            }
            Tier2::Idle | Tier2::Stopped => RootState::Idle,
        }
    }

    /// Starts tier 2 (once; again when it ended), unless the user stopped it.
    pub fn start_tier2(&self) {
        if self.inner.user() == UserState::Stopped {
            return;
        }
        let Ok(mut t) = self.tier2.lock() else { return };
        if t.as_ref().is_some_and(|h| !h.is_finished()) {
            return;
        }
        let inner = self.inner.clone();
        *t = Some(clock::spawn(
            "search:tier2",
            async move { inner.tier2().await },
        ));
    }

    /// The lag of the base against MODEL's vectors (none: no model, nothing behind on vectors).
    pub async fn lag(&self, model: Option<&Identity>) -> Result<Lag, ProjectError> {
        self.lag_in(model, hrafn::View::Base).await
    }

    /// The lag of VIEW.
    pub async fn lag_in(
        &self,
        model: Option<&Identity>,
        view: hrafn::View,
    ) -> Result<Lag, ProjectError> {
        let cache = match model {
            Some(id) => Some(self.cache(id).await?),
            None => None,
        };
        Ok(hrafn::lag(&self.inner.store, cache.as_deref(), view).await?)
    }

    /// ID's vector cache (the state's, shared by every project).
    pub async fn cache(&self, id: &Identity) -> Result<Arc<VectorCache>, ProjectError> {
        Ok(self.inner.caches.get(id).await?)
    }

    /// The state's vector caches.
    pub fn caches(&self) -> &Arc<Caches> {
        &self.inner.caches
    }

    /// The view a query about ROOT answers from: the base for the main checkout (or a folder in it); for a linked
    /// worktree its overlay, registered, watched and seeded on first use (H16 overlay design §6). A tree being seeded
    /// answers from the base; a stale or unwatched one answers at once from its rows and starts a check (at most one
    /// per [`CHECK_TTL`]). TOUCHED: an agent's sandbox worked in the tree, so its git door is gix, never the CLI.
    pub async fn view_for(&self, root: &Path, touched: bool) -> Result<ViewOf, ProjectError> {
        let (given, main) = (root.to_path_buf(), self.inner.base.clone());
        let found = clock::blocking(move || tree_of(&given, &main))
            .await
            .map_err(io::Error::other)??;
        let Some((given_root, given_git)) = found else {
            return Ok(ViewOf {
                view: hrafn::View::Base,
                worktree: None,
                root: self.inner.base.clone(),
                state: None,
                checking: false,
            });
        };
        // the key is history's, of the paths as given: the watcher tags the tree's events with it, and the feed names
        // it. The overlay reads and watches the true names: `eitri` refuses a link in a path, and a watcher reports
        // true names (macOS's temporary folders are under /var, a link to /private/var)
        let key = verdandi::WorktreeId::of(&given_root, &given_git).0;
        let (troot, git_dir) = clock::blocking(move || {
            Ok::<_, io::Error>((
                std::fs::canonicalize(&given_root)?,
                std::fs::canonicalize(&given_git)?,
            ))
        })
        .await
        .map_err(io::Error::other)??;
        let inner = &self.inner;
        let t = inner
            .open_tree(&key, &troot, &git_dir, hrafn::DoorKind::for_tree(touched))
            .await?;
        let state = inner.state_of(t).await?;
        let now = clock::now();
        let checking = match state {
            hrafn::TreeState::Seeding => inner.start(t, Job::Seed) || inner.live(t, |l| l.busy),
            hrafn::TreeState::Live if inner.live(t, |l| l.watched) => false,
            _ => {
                let due = inner.live(t, |l| {
                    let due = !l.busy && l.checked.is_none_or(|c| now - c >= CHECK_TTL);
                    if due {
                        l.checked = Some(now);
                    }
                    due
                });
                (due && inner.start(t, Job::Check)) || inner.live(t, |l| l.busy)
            }
        };
        let seeding = state == hrafn::TreeState::Seeding;
        Ok(ViewOf {
            view: if seeding {
                hrafn::View::Base
            } else {
                hrafn::View::Tree(t)
            },
            worktree: Some(key),
            root: if seeding {
                self.inner.base.clone()
            } else {
                troot
            },
            state: Some(state),
            checking,
        })
    }

    /// Every worktree overlay of the project.
    pub async fn tree_status(&self) -> Result<Vec<TreeLive>, ProjectError> {
        let rows = self.inner.store.trees().await?;
        let counts: HashMap<i64, u32> = self
            .inner
            .store
            .handle()
            .read(|c| {
                let mut st =
                    c.prepare("select tree, count(*) from file where tree > 0 group by tree")?;
                let rows = st
                    .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<Result<_, _>>()?;
                Ok(rows)
            })
            .await
            .map_err(StoreError::from)?;
        Ok(rows
            .into_iter()
            .map(|r| {
                let (watched, checks, last) =
                    self.inner.live(r.id, |l| (l.watched, l.checks, l.last));
                TreeLive {
                    rows: counts.get(&r.id.0).copied().unwrap_or(0),
                    id: r.id,
                    key: r.key,
                    root: r.root,
                    door: r.door,
                    state: r.state,
                    watched,
                    checks,
                    last,
                }
            })
            .collect())
    }

    /// Waits until no seed, check, re-check or sweep of the trees runs.
    pub async fn settle_trees(&self) {
        loop {
            let jobs: Vec<tokio::task::JoinHandle<()>> = match self.inner.jobs.lock() {
                Ok(mut j) => j.drain(..).collect(),
                Err(_) => return,
            };
            if jobs.is_empty() {
                return;
            }
            for j in jobs {
                let _ = j.await;
            }
        }
    }

    /// The history's `file-version` feed reaches the overlays (once per project): the versions waiting are taken
    /// together, and each tree re-checks its paths; a lag (the channel dropped versions) marks every tree stale and
    /// re-diffs it. The task ends when the feed closes. None: the project has its feed already.
    pub fn feed(
        &self,
        mut rx: tokio::sync::broadcast::Receiver<crate::history::FileVersion>,
    ) -> Option<tokio::task::JoinHandle<()>> {
        use tokio::sync::broadcast::error::{RecvError, TryRecvError};
        if self
            .inner
            .fed
            .swap(true, std::sync::atomic::Ordering::SeqCst)
        {
            return None;
        }
        // the project is not kept open by its feed: a closed project's feed ends at its next version
        let weak = Arc::downgrade(&self.inner);
        Some(clock::spawn("search:feed", async move {
            loop {
                let mut hints: HashMap<String, BTreeSet<String>> = HashMap::new();
                let (mut lagged, mut closed) = (false, false);
                match rx.recv().await {
                    Ok(v) => {
                        hints.entry(v.worktree).or_default().insert(v.path);
                    }
                    Err(RecvError::Lagged(_)) => lagged = true,
                    Err(RecvError::Closed) => closed = true,
                }
                while !closed {
                    match rx.try_recv() {
                        Ok(v) => {
                            hints.entry(v.worktree).or_default().insert(v.path);
                        }
                        Err(TryRecvError::Lagged(_)) => lagged = true,
                        Err(TryRecvError::Empty) => break,
                        Err(TryRecvError::Closed) => closed = true,
                    }
                }
                let Some(inner) = weak.upgrade() else { return };
                // an edited file is embedded before the rest (MP-14)
                inner.note_recent(hints.values().flatten());
                if let Err(e) = inner.hints(hints, HashSet::new(), lagged).await {
                    tracing::warn!("search: the history feed of {}: {e}", inner.root.display());
                }
                if closed {
                    return;
                }
            }
        }))
    }

    /// Drops the overlays of removed worktrees (not those `git worktree list` shows `locked`) and of trees unused
    /// for [`TREE_IDLE`]. How many.
    pub async fn sweep_trees(&self) -> Result<u32, ProjectError> {
        self.inner.sweep().await
    }

    /// The file REL of the checkout at ROOT as it is now (as [`Project::read_now`]).
    pub fn read_now_in(&self, root: &Path, rel: &str) -> Option<String> {
        let root = eitri::open_path(root, eitri::Kind::Dir).ok()?;
        let bytes = eitri::read_regular(
            root.fd.as_fd(),
            Path::new(rel),
            hrafn::files::MAX_FILE_BYTES,
        )
        .ok()?;
        String::from_utf8(bytes).ok()
    }

    /// The file REL as it is now (read through the root's descriptor, at most [`hrafn::files::MAX_FILE_BYTES`]); none
    /// when it cannot be read or is not text.
    pub fn read_now(&self, rel: &str) -> Option<String> {
        self.read_now_in(&self.inner.base, rel)
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

/// The store's meta key naming the checkout its base was built from.
const META_BASE_ROOT: &str = "base_root";

/// `max_user_watches`: the user's inotify budget.
const MAX_USER_WATCHES: &str = "/proc/sys/fs/inotify/max_user_watches";

/// The checkout GIVEN is in, when it is a linked worktree of the project whose main checkout is MAIN: its root and
/// its own git directory (read with no link followed, and no git run in it). None: the main checkout, or no checkout.
fn tree_of(given: &Path, main: &Path) -> io::Result<Option<(PathBuf, PathBuf)>> {
    let mut at = Some(given);
    while let Some(d) = at {
        if std::fs::symlink_metadata(d.join(".git")).is_ok() {
            if std::fs::canonicalize(d)? == main {
                return Ok(None);
            }
            return Ok(crate::history::wire::git_dirs(d).map(|(g, _)| (d.to_path_buf(), g)));
        }
        at = d.parent();
    }
    Ok(None)
}

/// The worktrees `git worktree list --porcelain` names in the project at MAIN, and whether each is `locked`.
fn worktree_list(main: &Path) -> io::Result<Vec<(PathBuf, bool)>> {
    let out = Command::new("git")
        .arg("-C")
        .arg(main)
        .args(["worktree", "list", "--porcelain"])
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "git worktree list: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let mut trees: Vec<(PathBuf, bool)> = Vec::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if let Some(p) = line.strip_prefix("worktree ") {
            trees.push((PathBuf::from(p), false));
        } else if (line == "locked" || line.starts_with("locked "))
            && let Some(last) = trees.last_mut()
        {
            last.1 = true;
        }
    }
    Ok(trees)
}

/// A and B name one folder.
fn same_path(a: &Path, b: &Path) -> bool {
    a == b
        || matches!(
            (std::fs::canonicalize(a), std::fs::canonicalize(b)),
            (Ok(x), Ok(y)) if x == y
        )
}

impl Inner {
    fn live<R>(&self, t: hrafn::TreeId, f: impl FnOnce(&mut Live) -> R) -> R {
        let mut g = self
            .trees
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        f(g.entry(t).or_default())
    }

    fn watcher(&self) -> Option<Arc<hrafn::ProjectWatch>> {
        self.watcher.lock().ok().and_then(|h| h.clone())
    }

    async fn state_of(&self, t: hrafn::TreeId) -> Result<hrafn::TreeState, ProjectError> {
        Ok(self
            .store
            .trees()
            .await?
            .into_iter()
            .find(|r| r.id == t)
            .map_or(hrafn::TreeState::Seeding, |r| r.state))
    }

    /// The tree KEY registered (evicting the least recently used tree past [`RESIDENT_CAP`]), its use noted, and its
    /// watch asked for once.
    async fn open_tree(
        self: &Arc<Self>,
        key: &str,
        root: &Path,
        git_dir: &Path,
        door: hrafn::DoorKind,
    ) -> Result<hrafn::TreeId, ProjectError> {
        let rows = self.store.trees().await?;
        if !rows.iter().any(|r| r.key == key)
            && rows.len() >= RESIDENT_CAP
            && let Some(lru) = rows.iter().min_by_key(|r| (r.last_used, r.id))
        {
            self.drop_tree(lru).await?;
        }
        let t = self
            .store
            .tree_open(
                key,
                &root.to_string_lossy(),
                &git_dir.to_string_lossy(),
                door,
            )
            .await?;
        self.store
            .tree_touch(t, (clock::wall_secs() * 1000.0) as i64)
            .await?;
        if !self.live(t, |l| std::mem::replace(&mut l.tried, true)) {
            self.watch_tree(t, key, root, git_dir).await;
        }
        Ok(t)
    }

    /// The tree joins the project's watcher. Past the budget (or on `ENOSPC`) the least recently used other tree
    /// gives its watch up and is checked at query time instead; a tree that still finds no room runs unwatched.
    async fn watch_tree(
        self: &Arc<Self>,
        t: hrafn::TreeId,
        key: &str,
        root: &Path,
        git_dir: &Path,
    ) {
        let Some(w) = self.watcher() else { return };
        let spec = hrafn::TreeSpec {
            key: key.to_string(),
            root: root.to_path_buf(),
            gitdir: git_dir.to_path_buf(),
        };
        let add = |w: Arc<hrafn::ProjectWatch>, spec: hrafn::TreeSpec| async move {
            clock::blocking(move || w.add_tree(spec))
                .await
                .unwrap_or_else(|e| Err(hrafn::AddError::Other(e.to_string())))
        };
        let mut added = add(w.clone(), spec.clone()).await;
        if matches!(added, Err(hrafn::AddError::NoSpace(_))) && self.unwatch_lru(t).await {
            added = add(w.clone(), spec).await;
        }
        match added {
            Ok(()) => {
                self.live(t, |l| l.watched = true);
                let state = hrafn::Watch::shared_state(&*w);
                let over = || {
                    let budget = self.watch_budget.lock().ok().and_then(|b| *b);
                    let used = state.lock().map(|s| s.watched).unwrap_or(0);
                    budget.is_some_and(|b| used > b)
                };
                while over() && self.unwatch_lru(t).await {}
            }
            Err(e) => {
                tracing::warn!("search: worktree {} runs unwatched: {e}", root.display());
            }
        }
    }

    /// The least recently used watched tree other than KEEP gives its watch up. Whether there was one.
    async fn unwatch_lru(&self, keep: hrafn::TreeId) -> bool {
        let Ok(rows) = self.store.trees().await else {
            return false;
        };
        let Some(lru) = rows
            .iter()
            .filter(|r| r.id != keep && self.live(r.id, |l| l.watched))
            .min_by_key(|r| (r.last_used, r.id))
        else {
            return false;
        };
        if let Some(w) = self.watcher() {
            let (w2, k) = (w.clone(), lru.key.clone());
            let _ = clock::blocking(move || w2.remove_tree(&k)).await;
            if let Ok(mut s) = hrafn::Watch::shared_state(&*w).lock() {
                s.unwatched.retain(|(k, _)| *k != lru.key);
                s.unwatched.push((
                    lru.key.clone(),
                    "the watch budget is spent: the least recently used worktree is checked at query time".into(),
                ));
            }
        }
        self.live(lru.id, |l| l.watched = false);
        if lru.state != hrafn::TreeState::Seeding {
            let _ = self
                .store
                .tree_mark(lru.id, hrafn::TreeState::Unwatched)
                .await;
        }
        true
    }

    /// The tree's rows and registry row go, and its watch.
    async fn drop_tree(&self, r: &hrafn::TreeRow) -> Result<(), ProjectError> {
        // not under a seed or check of it, nor under a base batch
        let _one = self.tier1.lock().await;
        if let Some(w) = self.watcher() {
            let (w2, k) = (w.clone(), r.key.clone());
            let _ = clock::blocking(move || w2.remove_tree(&k)).await;
            if let Ok(mut s) = hrafn::Watch::shared_state(&*w).lock() {
                s.unwatched.retain(|(k, _)| *k != r.key);
            }
        }
        self.store.tree_drop(r.id).await?;
        if let Ok(mut t) = self.trees.lock() {
            t.remove(&r.id);
        }
        Ok(())
    }

    /// Starts JOB on tree T. A seed or check does not start while one runs (a check asked for meanwhile runs after
    /// it); re-checks queue. Whether it started.
    fn start(self: &Arc<Self>, t: hrafn::TreeId, job: Job) -> bool {
        if !matches!(job, Job::Recheck(_)) {
            let go = self.live(t, |l| {
                if l.busy {
                    l.again |= matches!(job, Job::Check);
                    return false;
                }
                l.busy = true;
                true
            });
            if !go {
                return false;
            }
        }
        let inner = self.clone();
        let h = clock::spawn("search:tree", async move {
            let (i2, j2) = (inner.clone(), job.clone());
            let rt = tokio::runtime::Handle::current();
            let r = {
                // after any base batch: a base change moves the trees in its own transaction
                let _one = inner.tier1.lock().await;
                clock::blocking(move || rt.block_on(i2.run(t, &j2))).await
            };
            match r {
                Ok(Ok(())) => {}
                Ok(Err(e)) => tracing::warn!("search: worktree overlay {}: {e}", t.0),
                Err(e) => tracing::warn!("search: worktree overlay {}: {e}", t.0),
            }
            if !matches!(job, Job::Recheck(_)) {
                let again = inner.live(t, |l| {
                    l.busy = false;
                    std::mem::take(&mut l.again)
                });
                if again {
                    inner.start(t, Job::Check);
                }
            }
        });
        if let Ok(mut j) = self.jobs.lock() {
            j.retain(|h| !h.is_finished());
            j.push(h);
        }
        true
    }

    /// JOB on tree T, on the blocking pool: the tree's git door, its root, the base's rules.
    async fn run(&self, t: hrafn::TreeId, job: &Job) -> Result<(), ProjectError> {
        let Some(row) = self.store.trees().await?.into_iter().find(|r| r.id == t) else {
            return Ok(());
        };
        let root = PathBuf::from(&row.root);
        let door = hrafn::door(row.door);
        let allow = |p: &str| self.deny.check(&root.join(p)) == Verdict::Allowed;
        // the repo's rules are read for every run, so an edit of `.drgnx/search.toml` takes effect at once
        let repo = hrafn::files::read_repo(&self.base)?;
        let cx = hrafn::overlay::Cx {
            store: &self.store,
            tree: t,
            root: &root,
            door: &*door,
            config: &self.config,
            repo: &repo,
            allow: &allow,
        };
        let s = match job {
            Job::Seed => hrafn::overlay::seed(&cx).await?,
            Job::Check => hrafn::overlay::rediff(&cx).await?,
            Job::Recheck(paths) => hrafn::overlay::recheck(&cx, paths).await?,
        };
        let watched = self.live(t, |l| {
            l.last = Some(s);
            if matches!(job, Job::Check) {
                l.checks += 1;
            }
            l.watched
        });
        // a seed or re-diff leaves the tree live: one the watcher does not serve is checked at query time
        if !watched && !matches!(job, Job::Recheck(_)) {
            self.store.tree_mark(t, hrafn::TreeState::Unwatched).await?;
        }
        Ok(())
    }

    /// Watcher and feed hints, by tree key: PATHS re-checked, GITS re-diffed; with STALE every tree is marked stale
    /// and re-diffed (events were lost). Keys of trees not registered are not this project's overlays (yet).
    async fn hints(
        self: &Arc<Self>,
        paths: HashMap<String, BTreeSet<String>>,
        gits: HashSet<String>,
        stale: bool,
    ) -> Result<(), ProjectError> {
        if paths.is_empty() && gits.is_empty() && !stale {
            return Ok(());
        }
        for r in self.store.trees().await? {
            if stale && r.state != hrafn::TreeState::Seeding {
                self.store.tree_mark(r.id, hrafn::TreeState::Stale).await?;
            }
            if stale || gits.contains(&r.key) {
                self.start(r.id, Job::Check);
            } else if let Some(p) = paths.get(&r.key) {
                self.start(r.id, Job::Recheck(p.iter().cloned().collect()));
            }
        }
        Ok(())
    }

    async fn sweep(self: &Arc<Self>) -> Result<u32, ProjectError> {
        let main = self.root.clone();
        let listed = clock::blocking(move || worktree_list(&main))
            .await
            .map_err(io::Error::other)??;
        let now = (clock::wall_secs() * 1000.0) as i64;
        let idle = TREE_IDLE.as_millis() as i64;
        let mut dropped = 0;
        for r in self.store.trees().await? {
            let root = Path::new(&r.root);
            let keep = match listed.iter().find(|(p, _)| same_path(p, root)) {
                None => false,
                // a locked worktree is never dropped, even with its folder gone (a removable disk)
                Some((_, true)) => true,
                Some((_, false)) => root.is_dir() && now - r.last_used < idle,
            };
            if !keep {
                self.drop_tree(&r).await?;
                dropped += 1;
            }
        }
        Ok(dropped)
    }

    fn allowed(&self, rel: &str) -> bool {
        self.deny.check(&self.base.join(rel)) == Verdict::Allowed
    }

    /// The file list (blocking: git and a read of every file).
    fn list(&self) -> io::Result<Vec<Listed>> {
        let mut snap = self
            .listing
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        hrafn::files::list_with(
            &self.base,
            &GitCli,
            &self.config,
            &|p: &str| self.allowed(p),
            &mut snap,
        )
    }

    /// Tier 2's sources now.
    fn sources(&self) -> Vec<Arc<dyn Source>> {
        self.sources.lock().map(|s| s.clone()).unwrap_or_default()
    }

    /// The caches of the fingerprints the sources have proved so far (a source not probed yet has none).
    async fn models(&self) -> Result<Vec<Arc<VectorCache>>, ProjectError> {
        let mut out: Vec<Arc<VectorCache>> = Vec::new();
        for id in self.sources().iter().filter_map(|e| e.identity()) {
            let c = self.caches.get(&id).await?;
            if !out.iter().any(|o| o.fp_hex() == c.fp_hex()) {
                out.push(c);
            }
        }
        Ok(out)
    }

    async fn refresh(&self) -> Result<Refresh, ProjectError> {
        let listed = self.list()?;
        // the files' git recency is read again for the next batch
        if let Ok(mut r) = self.recency.lock() {
            *r = None;
        }
        let root = eitri::open_path(&self.base, eitri::Kind::Dir)
            .map_err(|e| io::Error::other(e.to_string()))?;
        let read = |p: &str| {
            eitri::read_regular(root.fd.as_fd(), Path::new(p), hrafn::files::MAX_FILE_BYTES)
                .map_err(|e| io::Error::other(e.to_string()))
        };
        let caches = self.models().await?;
        let refs: Vec<&VectorCache> = caches.iter().map(|c| c.as_ref()).collect();
        let r = hrafn::refresh(&self.store, &listed, &read, &refs).await?;
        if let Ok(head) = GitCli.head(&self.base) {
            self.store
                .meta_set(hrafn::index::META_BUILT_FROM, &head)
                .await?;
        }
        // the store's live key set, to each cache (MP-21); a fingerprint first proved later is held by tier 2
        if let Ok(mut h) = self.held.lock() {
            h.clear();
        }
        for c in &caches {
            self.hold(c).await?;
        }
        Ok(r)
    }

    /// The store's live key set reported to CACHE (once per refresh and fingerprint).
    async fn hold(&self, cache: &VectorCache) -> Result<(), ProjectError> {
        let now_ms = (clock::wall_secs() * 1000.0) as i64;
        hrafn::hold(&self.store, cache, &self.base, now_ms).await?;
        if let Ok(mut h) = self.held.lock() {
            h.insert(cache.fp_hex().to_string());
        }
        Ok(())
    }

    /// ID's cache, holding the store's live key set (reported now when no refresh has since ID was first proved).
    async fn cache_held(&self, id: &Identity) -> Result<Arc<VectorCache>, ProjectError> {
        let cache = self.caches.get(id).await?;
        let held = self.held.lock().is_ok_and(|h| h.contains(cache.fp_hex()));
        if !held {
            self.hold(&cache).await?;
        }
        Ok(cache)
    }

    fn user(&self) -> UserState {
        self.user.lock().map_or(UserState::On, |u| *u)
    }

    /// The user's state, kept in the store first.
    async fn set_user(&self, state: UserState) -> Result<(), ProjectError> {
        self.store.meta_set(META_STATE, state.as_str()).await?;
        if let Ok(mut u) = self.user.lock() {
            *u = state;
        }
        Ok(())
    }

    fn publish(&self, tier2: Tier2) {
        self.status.send_if_modified(|s| {
            let changed = s.tier2 != tier2;
            s.tier2 = tier2;
            changed
        });
    }

    /// Waits until typing lets a request go; whether it goes as `index now`, and whether the local sources wait for AC
    /// (on battery, unless `index now` or `drgnx-search-battery-engine`; remote sources are never held by battery).
    async fn gates(&self) -> (bool, bool) {
        loop {
            // the user's pause first: no automatic reason lifts it, only `resume`
            if self.user() != UserState::On {
                self.publish(Tier2::Paused);
                self.wake.notified().await;
                continue;
            }
            let (typing, overriding) = match self.gate.lock() {
                Ok(g) => (g.hold_until.is_some_and(|t| t > clock::now()), g.overriding),
                Err(_) => (false, false),
            };
            if typing {
                self.publish(Tier2::Typing);
                self.wake.notified().await;
                continue;
            }
            let battery = !overriding
                && !self
                    .battery_engine
                    .load(std::sync::atomic::Ordering::Relaxed)
                && power::on_battery(&self.power_root);
            return (overriding, battery);
        }
    }

    /// The paths to embed first: open files, then recently edited ones, then the rest by git recency (MP-14).
    async fn order(&self) -> Vec<String> {
        let cached = self.recency.lock().ok().and_then(|r| r.clone());
        let recency = match cached {
            Some(r) => r,
            None => {
                let base = self.base.clone();
                let r = clock::blocking(move || git_recency(&base))
                    .await
                    .ok()
                    .and_then(Result::ok)
                    .unwrap_or_default();
                if let Ok(mut c) = self.recency.lock() {
                    *c = Some(r.clone());
                }
                r
            }
        };
        let mut seen = HashSet::new();
        let take = |v: &Mutex<Vec<String>>| v.lock().map(|v| v.clone()).unwrap_or_default();
        take(&self.open_paths)
            .into_iter()
            .chain(take(&self.recent_paths))
            .chain(recency)
            .filter(|p| seen.insert(p.clone()))
            .take(ORDER_PATHS)
            .collect()
    }

    /// Remembers the paths a history version names as the most recently edited.
    fn note_recent<'a>(&self, paths: impl Iterator<Item = &'a String>) {
        if let Ok(mut r) = self.recent_paths.lock() {
            for p in paths {
                r.retain(|o| o != p);
                r.insert(0, p.clone());
            }
            r.truncate(RECENT_PATHS);
        }
    }

    /// One chain per fingerprint the sources state now (a source that does not answer its probe is no failure: it is
    /// asked again at the next change). A swapped server states another fingerprint and gets another chain; the rows
    /// under the old one stay. A fingerprint's chain keeps its backoff from pass to pass.
    async fn slots(&self, old: Vec<Slot>, battery: bool, overriding: bool) -> Vec<Slot> {
        let mut groups: Vec<(Identity, Vec<Arc<dyn Source>>)> = Vec::new();
        for s in self.sources() {
            let Ok(id) = s.probe().await else {
                continue;
            };
            match groups.iter_mut().find(|(g, _)| g.fp == id.fp) {
                Some((_, v)) => v.push(s),
                None => groups.push((id, vec![s])),
            }
        }
        let mut old = old;
        let mut slots = Vec::new();
        for (id, sources) in groups {
            let cache = match self.cache_held(&id).await {
                Ok(c) => c,
                Err(err) => {
                    self.publish(Tier2::Failed(err.to_string()));
                    continue;
                }
            };
            let mut slot = match old.iter().position(|s| s.chain.fingerprint() == id.fp) {
                Some(i) => {
                    let mut s = old.swap_remove(i);
                    s.chain.sync(sources);
                    s.cache = cache;
                    s
                }
                None => Slot::new(SourceChain::new(id.fp, sources), cache),
            };
            slot.chain.set_gates(battery, overriding);
            slots.push(slot);
        }
        slots
    }

    async fn tier2(self: Arc<Self>) {
        if self.sources().is_empty() {
            self.publish(Tier2::Idle);
            return;
        }
        let mut slots: Vec<Slot> = Vec::new();
        loop {
            #[cfg(feature = "test-hooks")]
            if let Some(p) = &self.permits {
                match p.acquire().await {
                    Ok(permit) => permit.forget(),
                    Err(_) => return,
                }
            }
            let mut sent = false;
            loop {
                let (overriding, battery) = self.gates().await;
                slots = self.slots(slots, battery, overriding).await;
                if let Ok(mut v) = self.chains.lock() {
                    *v = slots
                        .iter()
                        .map(|s| (s.chain.fingerprint().hex(), s.chain.status()))
                        .collect();
                }
                let order = self.order().await;
                let mut reads = 0;
                let running = || self.publish(Tier2::Running);
                match run_pass_with(
                    &mut slots,
                    &self.store,
                    &order,
                    clock::now(),
                    &mut reads,
                    &running,
                )
                .await
                {
                    Ok(out) if out.filled => {
                        self.publish(Tier2::Running);
                        // the chunks filled (what `keys_missing` and the lag count); a path's vector rides along
                        self.status.send_modify(|s| s.embedded += out.chunks as u64);
                        sent = true;
                    }
                    Ok(out) if out.held => {
                        // only the battery keeps a local source from the work: wait for AC, `index now` or a change
                        self.publish(Tier2::Battery);
                        tokio::select! {
                            () = self.wake.notified() => {}
                            () = clock::sleep(POWER_POLL) => {}
                        }
                        continue;
                    }
                    Ok(out) => {
                        if let Some(why) = out.down {
                            self.publish(Tier2::Failed(why));
                        }
                    }
                    Err(err) => self.publish(Tier2::Failed(err.to_string())),
                }
                break;
            }
            if !sent {
                if let Ok(mut g) = self.gate.lock() {
                    g.overriding = false;
                }
                // (unreferenced vectors are the caches' to collect: their hourly sweep)
                if !matches!(self.status.borrow().tier2, Tier2::Failed(_)) {
                    self.publish(Tier2::Idle);
                }
                let now = clock::now();
                let due = slots.iter().filter_map(|s| s.chain.next_due(now)).min();
                self.until_missing(due).await;
            }
        }
    }

    /// Waits until a wake finds a key missing for a source that answers, or until DUE (a source that is down is
    /// asked again when its backoff is over). A wake is only a hint: `Notify` keeps one sent while tier 2 was not
    /// waiting (a refresh, `index now` read before its wake), so one that finds nothing to do leaves tier 2 where it
    /// is, idle, and ends an `index now`, rather than taking it back to its gates.
    async fn until_missing(&self, due: Option<Duration>) {
        loop {
            match due {
                Some(d) => {
                    tokio::select! {
                        () = self.wake.notified() => {}
                        () = clock::sleep(d) => return,
                    }
                }
                None => self.wake.notified().await,
            }
            for e in self.sources() {
                // a store error is the pass's to report
                if let Ok(id) = e.probe().await
                    && let Ok(cache) = self.cache_held(&id).await
                    && !matches!(hrafn::missing(&self.store, &cache, 1).await, Ok(k) if k.is_empty())
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
