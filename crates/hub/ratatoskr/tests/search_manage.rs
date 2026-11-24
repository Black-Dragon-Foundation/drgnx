//! Managing indexing (Hrafn redesign Task 23b, §11A): pause, resume, stop and delete of a root's index, its state, and
//! why it waits.
//!
//! The project, its store, the cache and tier 2 are the real ones. What stands in is a remote (`Gated`: a source the
//! test steers, which can hold a request open) and the power supply (a stand-in sysfs).
//!
//! test-pattern: handshake (C): tier 2 takes one permit per pass (test-hooks), and a held request is let go by the
//! test; each wait is on the published status, never a sleep.
#![cfg(feature = "test-hooks")]

use hrafn::{KeyKind, QuantRow, VectorCache};
use hrafn_embed::fingerprint::{Identity, builtin_record};
use ratatoskr::clock;
use ratatoskr::search::caches::Caches;
use ratatoskr::search::manage::{self, PauseWhy, RootState};
use ratatoskr::search::project::{PROBE_POLL, Project, ProjectSpec, Tier2, store_path};
use ratatoskr::search::sources::{Item, Source, SourceKind};
use ratatoskr::search::{EMBED_TEXT_VERSION, TEST_TINY};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Semaphore;
use urdr::graph::search::{BoxFuture, EmbedError};

const DIMS: usize = 8;
/// The longest any wait on tier 2 may take before the row fails.
const LIMIT: Duration = Duration::from_secs(60);

fn ident(model: &str) -> Identity {
    let mut r = builtin_record(&TEST_TINY, EMBED_TEXT_VERSION);
    r.model_id = model.into();
    Identity::new(r, model)
}

/// A source the test steers: every text it was sent is recorded, and while HOLD has no permit a request waits.
struct Gated {
    kind: SourceKind,
    ident: Identity,
    texts: Mutex<Vec<String>>,
    /// Requests begun.
    calls: tokio::sync::watch::Sender<usize>,
    hold: Option<Arc<Semaphore>>,
    /// Whether the probe answers (a source that is down fails it).
    up: std::sync::atomic::AtomicBool,
}

impl Gated {
    fn new(kind: SourceKind, ident: &Identity, hold: Option<Arc<Semaphore>>) -> Arc<Gated> {
        Arc::new(Gated {
            kind,
            ident: ident.clone(),
            texts: Mutex::new(Vec::new()),
            calls: tokio::sync::watch::channel(0).0,
            hold,
            up: std::sync::atomic::AtomicBool::new(true),
        })
    }
    fn set_up(&self, up: bool) {
        self.up.store(up, std::sync::atomic::Ordering::SeqCst);
    }
    fn texts(&self) -> Vec<String> {
        saman::lock(&self.texts).clone()
    }
    fn calls(&self) -> usize {
        *self.calls.borrow()
    }
}

impl Source for Gated {
    fn id(&self) -> &str {
        "e"
    }
    fn kind(&self) -> SourceKind {
        self.kind
    }
    fn identity(&self) -> Option<Identity> {
        Some(self.ident.clone())
    }
    fn may_send_text(&self) -> bool {
        true
    }
    fn max_batch(&self) -> usize {
        8
    }
    fn lookup<'a>(
        &'a self,
        _kind: KeyKind,
        keys: &'a [[u8; 32]],
    ) -> BoxFuture<'a, Result<Vec<Option<QuantRow>>, EmbedError>> {
        Box::pin(async move { Ok(vec![None; keys.len()]) })
    }
    fn embed<'a>(
        &'a self,
        items: &'a [Item],
        _overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        self.calls.send_modify(|n| *n += 1);
        Box::pin(async move {
            if let Some(h) = &self.hold {
                h.acquire().await.unwrap().forget();
            }
            saman::lock(&self.texts).extend(items.iter().map(|(_, _, t)| t.clone()));
            Ok(vec![vec![0.5; DIMS]; items.len()])
        })
    }
    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>> {
        Box::pin(async move {
            if self.up.load(std::sync::atomic::Ordering::SeqCst) {
                Ok(self.ident.clone())
            } else {
                Err(EmbedError("down".into()))
            }
        })
    }
}

fn git(dir: &Path, args: &[&str]) {
    let st = ratatoskr::proc::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .status()
        .unwrap();
    assert!(st.success(), "git {args:?}");
}

/// A repo of N one-chunk Lisp files (and SHARED, the same in every repo), committed, under HOME/src/NAME.
fn repo(home: &Path, name: &str, n: usize, shared: bool) -> PathBuf {
    let root = home.join("src").join(name);
    std::fs::create_dir_all(root.join("core")).unwrap();
    git(&root, &["init", "-q"]);
    for i in 0..n {
        ratatoskr::fsio::write(
            root.join(format!("core/{name}{i}.el")),
            format!(";;; {name}{i}.el\n(defun {name}{i}-run () \"Run {name} number {i}.\" {i})\n"),
        )
        .unwrap();
    }
    if shared {
        ratatoskr::fsio::write(
            root.join("core/shared.el"),
            ";;; shared.el\n(defun shared-run () \"The same in every repo.\" 0)\n",
        )
        .unwrap();
    }
    git(&root, &["add", "-A"]);
    git(&root, &["commit", "-q", "-m", "one"]);
    root
}

/// ROOT's project in STATE, tier 1 done, with SOURCES, POWER the sysfs root, tier 2 taking one of PERMITS per pass
/// (not started).
async fn open(
    home: &Path,
    state: &Path,
    root: &Path,
    sources: Vec<Arc<dyn Source>>,
    power: &Path,
    permits: &Arc<Semaphore>,
) -> Project {
    let p = Project::open(ProjectSpec {
        root: root.to_path_buf(),
        state: state.to_path_buf(),
        home: home.to_path_buf(),
        config_dir: home.join(".config/drgnx"),
        config: hrafn::Config::default(),
        embedders: Vec::new(),
        power_root: power.to_path_buf(),
        base: None,
        test_permits: Some(permits.clone()),
    })
    .await
    .unwrap();
    p.refresh_now().await.unwrap();
    p.add_sources(sources);
    p
}

/// Until tier 2 publishes a state F accepts.
async fn until(p: &Project, what: &str, f: impl Fn(&Tier2) -> bool) {
    let mut rx = p.status();
    tokio::time::timeout(LIMIT, rx.wait_for(|s| f(&s.tier2)))
        .await
        .unwrap_or_else(|_| panic!("tier 2 never {what}: {:?}", p.status().borrow().tier2))
        .unwrap();
}

/// Until the source has begun N requests.
async fn until_calls(s: &Gated, n: usize) {
    let mut rx = s.calls.subscribe();
    tokio::time::timeout(LIMIT, rx.wait_for(|c| *c >= n))
        .await
        .unwrap_or_else(|_| panic!("the source got {} requests, not {n}", s.calls()))
        .unwrap();
}

async fn missing(p: &Project, id: &Identity) -> usize {
    let cache = p.cache(id).await.unwrap();
    hrafn::missing(p.store(), &cache, 10_000)
        .await
        .unwrap()
        .len()
}

fn no_power() -> PathBuf {
    PathBuf::from("/nonexistent")
}

/// Pattern C. A pause during a request lets that batch finish and be written, then tier 2 holds: it says so, and no
/// other request goes.
#[test]
fn pause_finishes_the_batch_then_holds() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let (home, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let root = repo(home.path(), "a", 20, false);
        let id = ident("main");
        let hold = Arc::new(Semaphore::new(0));
        let e = Gated::new(SourceKind::Embed, &id, Some(hold.clone()));
        let permits = Arc::new(Semaphore::new(100));
        let p = open(
            home.path(),
            state.path(),
            &root,
            vec![e.clone()],
            &no_power(),
            &permits,
        )
        .await;
        let before = missing(&p, &id).await;
        p.start_tier2();
        until_calls(&e, 1).await;
        p.pause().await.unwrap();
        assert_eq!(p.state(), RootState::Paused(PauseWhy::User));
        hold.add_permits(1000);
        until(&p, "held", |t| *t == Tier2::Paused).await;
        assert_eq!(e.calls(), 1, "no request after the pause");
        assert_eq!(e.texts().len(), 8, "the batch in flight finished");
        assert_eq!(missing(&p, &id).await, before - 8, "and was written");
    })
}

/// Pattern C. The pause is kept in the store: a new hub (the project opened again) starts paused, and a change to the
/// files does not lift it.
#[test]
fn pause_survives_a_hub_restart() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let (home, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let root = repo(home.path(), "a", 5, false);
        let id = ident("main");
        let permits = Arc::new(Semaphore::new(100));
        {
            let p = open(
                home.path(),
                state.path(),
                &root,
                Vec::new(),
                &no_power(),
                &permits,
            )
            .await;
            p.pause().await.unwrap();
        }
        let e = Gated::new(SourceKind::Embed, &id, None);
        let p = open(
            home.path(),
            state.path(),
            &root,
            vec![e.clone()],
            &no_power(),
            &permits,
        )
        .await;
        assert_eq!(
            p.state(),
            RootState::Paused(PauseWhy::User),
            "kept across the restart"
        );
        p.start_tier2();
        until(&p, "held", |t| *t == Tier2::Paused).await;
        ratatoskr::fsio::write(
            root.join("core/new.el"),
            ";;; new.el\n(defun new-run () 1)\n",
        )
        .unwrap();
        let r = p.refresh_now().await.unwrap();
        assert!(r.files_changed > 0);
        until(&p, "held after the change", |t| *t == Tier2::Paused).await;
        assert_eq!(
            p.state(),
            RootState::Paused(PauseWhy::User),
            "a change does not lift it"
        );
        assert!(
            e.texts().is_empty(),
            "embedded while paused: {:?}",
            e.texts()
        );
    })
}

/// Pattern C. After a pause, resume sends exactly the keys still missing: nothing done is sent again.
#[test]
fn resume_redoes_nothing() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let (home, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let root = repo(home.path(), "a", 20, false);
        let id = ident("main");
        let e = Gated::new(SourceKind::Embed, &id, None);
        // two passes, then tier 2 waits for a permit
        let permits = Arc::new(Semaphore::new(2));
        let p = open(
            home.path(),
            state.path(),
            &root,
            vec![e.clone()],
            &no_power(),
            &permits,
        )
        .await;
        p.start_tier2();
        until_calls(&e, 2).await;
        p.pause().await.unwrap();
        permits.add_permits(1000);
        until(&p, "held", |t| *t == Tier2::Paused).await;
        let done = e.texts().len();
        let left = missing(&p, &id).await;
        assert!(done > 0 && left > 0, "{done} done, {left} left");
        p.resume().await.unwrap();
        until(&p, "done", |t| *t == Tier2::Idle).await;
        assert_eq!(missing(&p, &id).await, 0);
        assert_eq!(
            e.texts().len() - done,
            left,
            "resume sent only the keys left"
        );
        let mut all = e.texts();
        all.sort();
        all.dedup();
        assert_eq!(all.len(), e.texts().len(), "no text was sent twice");
    })
}

/// Pattern C. Stop cancels the request in flight at once and keeps what was written before it; the watcher's next
/// change (a refresh) goes on from there.
#[test]
fn stop_keeps_the_done_part_and_the_watcher() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let (home, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let root = repo(home.path(), "a", 20, false);
        let id = ident("main");
        // the first request answers, the second waits
        let hold = Arc::new(Semaphore::new(1));
        let e = Gated::new(SourceKind::Embed, &id, Some(hold.clone()));
        let permits = Arc::new(Semaphore::new(100));
        let p = open(
            home.path(),
            state.path(),
            &root,
            vec![e.clone()],
            &no_power(),
            &permits,
        )
        .await;
        let before = missing(&p, &id).await;
        p.start_tier2();
        until_calls(&e, 2).await;
        p.stop().await.unwrap();
        assert_eq!(p.state(), RootState::Stopped);
        until(&p, "stopped", |t| *t == Tier2::Stopped).await;
        hold.add_permits(1000);
        tokio::task::yield_now().await;
        assert_eq!(e.texts().len(), 8, "the request in flight was cancelled");
        assert_eq!(
            missing(&p, &id).await,
            before - 8,
            "the first batch is kept"
        );
        // a change: tier 2 goes on from the keys left
        ratatoskr::fsio::write(
            root.join("core/new.el"),
            ";;; new.el\n(defun new-run () 1)\n",
        )
        .unwrap();
        p.refresh_now().await.unwrap();
        assert_ne!(p.state(), RootState::Stopped);
        until(&p, "done", |t| *t == Tier2::Idle).await;
        assert_eq!(missing(&p, &id).await, 0);
        let mut all = e.texts();
        all.sort();
        all.dedup();
        assert_eq!(
            all.len(),
            e.texts().len(),
            "the kept part was not sent again"
        );
    })
}

/// Pattern C. Deleting a root removes its store, its packs and the vectors only it held; a vector another root's store
/// holds stays, as does the other root's own.
#[test]
fn delete_frees_the_root_and_keeps_shared_vectors() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let (home, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (ra, rb) = (
            repo(home.path(), "a", 3, true),
            repo(home.path(), "b", 3, true),
        );
        let id = ident("main");
        let permits = Arc::new(Semaphore::new(1000));
        let e = Gated::new(SourceKind::Embed, &id, None);
        let a = open(
            home.path(),
            state.path(),
            &ra,
            vec![e.clone()],
            &no_power(),
            &permits,
        )
        .await;
        let b = open(
            home.path(),
            state.path(),
            &rb,
            vec![e.clone()],
            &no_power(),
            &permits,
        )
        .await;
        for p in [&a, &b] {
            p.start_tier2();
            until(p, "done", |t| *t == Tier2::Idle).await;
            assert_eq!(missing(p, &id).await, 0);
        }
        let cache: Arc<VectorCache> = a.cache(&id).await.unwrap();
        // a file's one chunk key, from its store
        async fn key(p: &Project, rel: &str) -> [u8; 32] {
            let rel = rel.to_owned();
            let k: Vec<u8> = p
                .store()
                .handle()
                .read(move |c| {
                    Ok(c.query_row("select key from chunk where path = ?1", [rel], |r| r.get(0))?)
                })
                .await
                .unwrap();
            k.try_into().unwrap()
        }
        let (only_a, shared, only_b) = (
            key(&a, "core/a0.el").await,
            key(&a, "core/shared.el").await,
            key(&b, "core/b0.el").await,
        );
        assert_eq!(
            shared,
            key(&b, "core/shared.el").await,
            "the same text, the same key"
        );
        let packs = ra.join(".drgnx/packs");
        std::fs::create_dir_all(&packs).unwrap();
        ratatoskr::fsio::write(packs.join("0123456789abcdef.vpack"), b"pack").unwrap();
        let a_id = a.id().to_owned();
        drop(a);
        let caches = Caches::shared(state.path());
        let gone = manage::delete_root(&caches, &a_id, Some(&ra))
            .await
            .unwrap();
        assert!(
            !store_path(state.path(), &a_id).exists(),
            "the store is gone"
        );
        assert!(!packs.exists(), "the packs are gone");
        assert_eq!(gone.packs, 1);
        assert!(gone.bytes > 0);
        assert_eq!(
            cache
                .has(KeyKind::Chunk, &[only_a, shared, only_b])
                .await
                .unwrap(),
            [false, true, true],
            "only a's own vectors went"
        );
        assert_eq!(
            cache
                .has(KeyKind::Path, &[hrafn::path_key("core/shared.el")])
                .await
                .unwrap(),
            [true],
            "a path both repos have stays"
        );
        // a's three files: three chunks and three paths, none shared
        assert_eq!(gone.vectors, 6, "{gone:?}");
        assert_eq!(missing(&b, &id).await, 0, "b lost nothing");
        assert!(!Caches::shared(state.path()).stores().contains(&a_id));
    })
}

/// A stand-in sysfs: one mains supply, ONLINE or not.
fn power(dir: &Path, online: bool) -> PathBuf {
    let ac = dir.join("class/power_supply/AC");
    std::fs::create_dir_all(&ac).unwrap();
    ratatoskr::fsio::write(ac.join("type"), "Mains\n").unwrap();
    ratatoskr::fsio::write(ac.join("online"), if online { "1\n" } else { "0\n" }).unwrap();
    dir.to_path_buf()
}

/// Pattern C. The battery pauses by itself, and the user's pause comes first; when the battery's reason clears, the
/// user's pause still holds and nothing is embedded until resume.
#[test]
fn an_auto_pause_never_clears_a_user_pause() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let (home, state, sys) = (
            tempfile::tempdir().unwrap(),
            tempfile::tempdir().unwrap(),
            tempfile::tempdir().unwrap(),
        );
        let root = repo(home.path(), "a", 5, false);
        let id = ident("builtin");
        let local = Gated::new(SourceKind::Builtin, &id, None);
        let permits = Arc::new(Semaphore::new(1000));
        let sysfs = power(sys.path(), false);
        let p = open(
            home.path(),
            state.path(),
            &root,
            vec![local.clone()],
            &sysfs,
            &permits,
        )
        .await;
        p.start_tier2();
        until(&p, "on battery", |t| *t == Tier2::Battery).await;
        assert_eq!(p.state(), RootState::Paused(PauseWhy::Battery));
        p.pause().await.unwrap();
        assert_eq!(
            p.state(),
            RootState::Paused(PauseWhy::User),
            "the user's reason first"
        );
        // the battery's reason clears: AC, and the setting that lets local sources run on battery (it wakes tier 2)
        power(sys.path(), true);
        p.set_battery_engine(true);
        until(&p, "held by the user", |t| *t == Tier2::Paused).await;
        assert_eq!(p.state(), RootState::Paused(PauseWhy::User));
        assert!(
            local.texts().is_empty(),
            "the auto pause's end lifted the user's"
        );
        p.resume().await.unwrap();
        until(&p, "done", |t| *t == Tier2::Idle).await;
        assert!(!local.texts().is_empty());
    })
}

/// The stand-in machine beside a stand-in sysfs (`search::host`): a load average of LOAD over CPUS online, and AVAIL
/// free of TOTAL bytes under the state directory.
fn machine(dir: &Path, load: f64, cpus: u32, avail: u64, total: u64) -> PathBuf {
    let cpu = dir.join("devices/system/cpu");
    std::fs::create_dir_all(&cpu).unwrap();
    ratatoskr::fsio::write(cpu.join("online"), format!("0-{}\n", cpus - 1)).unwrap();
    ratatoskr::fsio::write(
        dir.join("loadavg"),
        format!("{load:.2} 1.00 1.00 2/300 42\n"),
    )
    .unwrap();
    ratatoskr::fsio::write(dir.join("statvfs"), format!("{avail} {total}\n")).unwrap();
    dir.to_path_buf()
}

const GB: u64 = 1 << 30;

/// Pattern C. A busy machine pauses tier 2 by itself (a load of 9 on 4 CPUs): it says so, and nothing is asked of the
/// source; `index now` goes through the load; quiet again, a root that was not overridden goes on by itself (woken by
/// the next change; here `resume`, which changes nothing else for a root the user never paused).
#[test]
fn load_pauses_until_the_machine_is_quiet() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let (home, state, sys) = (
            tempfile::tempdir().unwrap(),
            tempfile::tempdir().unwrap(),
            tempfile::tempdir().unwrap(),
        );
        let root = repo(home.path(), "a", 5, false);
        let id = ident("builtin");
        let local = Gated::new(SourceKind::Builtin, &id, None);
        let permits = Arc::new(Semaphore::new(1000));
        let host = machine(sys.path(), 9.0, 4, 500 * GB, 1000 * GB);
        let p = open(
            home.path(),
            state.path(),
            &root,
            vec![local.clone()],
            &host,
            &permits,
        )
        .await;
        p.start_tier2();
        until(&p, "held by the load", |t| *t == Tier2::Load).await;
        assert_eq!(p.state(), RootState::Paused(PauseWhy::Load));
        assert!(local.texts().is_empty(), "a busy machine embedded");
        machine(sys.path(), 7.9, 4, 500 * GB, 1000 * GB);
        p.resume().await.unwrap();
        until(&p, "done", |t| *t == Tier2::Idle).await;
        assert!(!local.texts().is_empty());
        until(&p, "idle", |t| *t == Tier2::Idle).await;
        assert_eq!(p.state(), RootState::Idle);
    })
}

/// Pattern C. `index now` overrides the load: a busy machine embeds when asked to now.
#[test]
fn index_now_goes_through_the_load() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let (home, state, sys) = (
            tempfile::tempdir().unwrap(),
            tempfile::tempdir().unwrap(),
            tempfile::tempdir().unwrap(),
        );
        let root = repo(home.path(), "a", 5, false);
        let id = ident("builtin");
        let local = Gated::new(SourceKind::Builtin, &id, None);
        let permits = Arc::new(Semaphore::new(1000));
        let host = machine(sys.path(), 9.0, 4, 500 * GB, 1000 * GB);
        let p = open(
            home.path(),
            state.path(),
            &root,
            vec![local.clone()],
            &host,
            &permits,
        )
        .await;
        p.start_tier2();
        until(&p, "held by the load", |t| *t == Tier2::Load).await;
        p.index_now();
        until(&p, "done", |t| *t == Tier2::Idle).await;
        assert!(!local.texts().is_empty());
    })
}

/// Pattern C. Below the disk floor (1 GB free of 10: under the 2 GB floor) tier 2 waits, even for `index now`, since it
/// writes vectors; with space again it goes on.
#[test]
fn the_disk_floor_pauses_even_index_now() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let (home, state, sys) = (
            tempfile::tempdir().unwrap(),
            tempfile::tempdir().unwrap(),
            tempfile::tempdir().unwrap(),
        );
        let root = repo(home.path(), "a", 5, false);
        let id = ident("builtin");
        let local = Gated::new(SourceKind::Builtin, &id, None);
        let permits = Arc::new(Semaphore::new(1000));
        let host = machine(sys.path(), 0.5, 4, GB, 10 * GB);
        let p = open(
            home.path(),
            state.path(),
            &root,
            vec![local.clone()],
            &host,
            &permits,
        )
        .await;
        // asked to go now before tier 2 starts: its first gates already see the override, and the floor still holds
        p.index_now();
        p.start_tier2();
        until(&p, "held by the disk floor", |t| *t == Tier2::DiskFloor).await;
        assert_eq!(p.state(), RootState::Paused(PauseWhy::DiskFloor));
        assert!(
            local.texts().is_empty(),
            "below the floor, index now embedded"
        );
        machine(sys.path(), 0.5, 4, 3 * GB, 10 * GB);
        p.resume().await.unwrap();
        until(&p, "done", |t| *t == Tier2::Idle).await;
        assert!(!local.texts().is_empty());
    })
}

/// Pattern D and C. Each reason has its words, and a root says which one holds: no embedder at all, an embedder that
/// is down, the battery (above), the user.
#[test]
fn status_names_why_it_waits() {
    saman::Executor::new(2).unwrap().block_on(async move {
        for (why, words) in [
            (PauseWhy::User, "paused by the user"),
            (PauseWhy::Battery, "on battery"),
            (PauseWhy::Load, "busy"),
            (PauseWhy::DiskFloor, "disk"),
            (PauseWhy::NoEmbedder, "no embedder"),
        ] {
            assert!(why.text().contains(words), "{why:?}: {}", why.text());
        }
        let (home, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let root = repo(home.path(), "a", 3, false);
        let permits = Arc::new(Semaphore::new(1000));
        let p = open(
            home.path(),
            state.path(),
            &root,
            Vec::new(),
            &no_power(),
            &permits,
        )
        .await;
        p.start_tier2();
        until(&p, "settled", |t| *t != Tier2::Stopped).await;
        assert_eq!(
            p.state(),
            RootState::Paused(PauseWhy::NoEmbedder),
            "keys missing, nothing to fill them"
        );
        p.pause().await.unwrap();
        assert_eq!(p.state().why(), Some(PauseWhy::User));
        p.resume().await.unwrap();
        assert_eq!(p.state(), RootState::Paused(PauseWhy::NoEmbedder));
    })
}

/// F on the hub's virtual clock and runtime (as `search_index.rs`'s), one F at a time; this process's clock is virtual
/// from here on.
fn on_hub_runtime<F: std::future::Future>(f: F) -> F::Output {
    use std::sync::OnceLock;
    static RT: OnceLock<saman::Executor> = OnceLock::new();
    static ONE: Mutex<()> = Mutex::new(());
    let _one = saman::lock(&ONE);
    clock::install_virtual();
    RT.get_or_init(|| {
        saman::Executor::tuned(2, |b| {
            b.on_thread_park(clock::worker_parks)
                .on_thread_unpark(clock::worker_unparks);
        })
        .unwrap()
    })
    .block_on(f)
}

/// Pattern C (the first real run, Wave 10). An index that waits because no source answers its probe goes on when one
/// answers again, with no call to wake it: a remote source can come back unannounced, so tier 2 asks again at
/// [`PROBE_POLL`] (an install's end wakes it at once instead: the projects are reopened). The hub clock moves only by
/// `advance`: before `PROBE_POLL` the index still waits, after it the vectors are written.
#[test]
fn no_embedder_waits_then_resumes_when_one_answers() {
    on_hub_runtime(async {
        let (home, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let root = repo(home.path(), "a", 5, false);
        let id = ident("main");
        let e = Gated::new(SourceKind::Embed, &id, None);
        e.set_up(false);
        let permits = Arc::new(Semaphore::new(1000));
        let p = open(
            home.path(),
            state.path(),
            &root,
            vec![e.clone()],
            &no_power(),
            &permits,
        )
        .await;
        p.start_tier2();
        until(&p, "settled", |t| *t != Tier2::Stopped).await;
        assert_eq!(p.state(), RootState::Paused(PauseWhy::NoEmbedder));
        assert!(missing(&p, &id).await > 0);
        e.set_up(true);
        clock::advance(Duration::from_secs(1)).await;
        assert!(
            missing(&p, &id).await > 0,
            "it went on before the probe was due"
        );
        clock::advance(PROBE_POLL).await;
        until(&p, "idle", |t| *t == Tier2::Idle).await;
        assert_eq!(missing(&p, &id).await, 0);
        assert_eq!(p.state(), RootState::Idle);
    })
}
