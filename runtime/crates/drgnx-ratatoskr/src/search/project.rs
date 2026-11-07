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
    /// An embedder failed; tier 2 waits for the next change.
    Failed(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub tier2: Tier2,
    /// Vectors tier 2 has written since the project opened.
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
                watcher: Mutex::new(None),
                taps: Mutex::new(Vec::new()),
                opened: clock::now(),
                trees: Mutex::new(HashMap::new()),
                jobs: Mutex::new(Vec::new()),
                fed: false.into(),
                swept: Mutex::new(None),
                watch_budget: Mutex::new(None),
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
        self.lag_in(model, hrafn::View::Base).await
    }

    /// The lag of VIEW.
    pub async fn lag_in(
        &self,
        model: Option<&str>,
        view: hrafn::View,
    ) -> Result<Lag, ProjectError> {
        Ok(hrafn::lag(&self.inner.store, model, view).await?)
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
        let Some((troot, git_dir)) = found else {
            return Ok(ViewOf {
                view: hrafn::View::Base,
                worktree: None,
                root: self.inner.base.clone(),
                state: None,
                checking: false,
            });
        };
        // the key is history's: the watcher tags the tree's events with it, and the feed names it
        let key = verdandi::WorktreeId::of(&troot, &git_dir).0;
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
        let cx = hrafn::overlay::Cx {
            store: &self.store,
            tree: t,
            root: &root,
            door: &*door,
            config: &self.config,
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
        hrafn::list(&self.base, &GitCli, &self.config, &|p: &str| {
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
        let root = eitri::open_path(&self.base, eitri::Kind::Dir)
            .map_err(|e| io::Error::other(e.to_string()))?;
        let read = |p: &str| {
            eitri::read_regular(root.fd.as_fd(), Path::new(p), hrafn::files::MAX_FILE_BYTES)
                .map_err(|e| io::Error::other(e.to_string()))
        };
        let models = self.models();
        let pairs: Vec<(&str, usize)> = models.iter().map(|(m, d)| (m.as_str(), *d)).collect();
        let r = hrafn::refresh(&self.store, &listed, &read, &pairs).await?;
        if let Ok(head) = GitCli.head(&self.base) {
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
