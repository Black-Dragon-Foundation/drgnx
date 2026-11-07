//! Hrafn's index in the hub: the embed worker (`ratatoskr embed-worker`, a child process), the hub's side of it
//! (`WorkerEmbedder`), and a project (`Project`: its store, tier 1, tier 2 and their gates).
//!
//! The worker loads the real Granite small from the read-only model volume (`DRGNX_TEST_MODELS`) and fails without
//! it. Worker tests pass `--device cpu` unless they name an adapter (`DRGNX_TEST_ADAPTER`); those are ignored on macOS,
//! whose CI runner has no GPU (as `hrafn-embed/tests/parity_gpu.rs`).
//!
//! test-pattern: handshake (C) for the worker's own tests: the child announces (`ready`, `parked`) and the test acts
//! on that line. The project's gates are gated (B): the hub clock moves only by `clock::advance` (250 ms at a time),
//! tier 2 takes a request only on a permit the test gives, and the test asserts on the status tier 2 publishes when
//! it stops at a gate. The project's tier-1 and identity tests are pure (D): git runs to its exit, no clock.
#![cfg(feature = "test-hooks")]

use drgnx_ratatoskr::clock;
use drgnx_ratatoskr::search::DocEmbedder;
use drgnx_ratatoskr::search::project::{
    Project, ProjectError, ProjectSpec, Status, Tier2, project_id,
};
use drgnx_ratatoskr::search::worker::{WorkerEmbedder, WorkerSpec};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;
use tempfile::TempDir;
use tokio::sync::Semaphore;

const MODEL: &str = "granite-embedding-small-english-r2";
const DIMS: usize = 384;
/// Only bounds a failure: a passing test never waits on it.
const BOUND: Duration = Duration::from_secs(180);

fn exe() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_ratatoskr"))
}

fn model_dir() -> PathBuf {
    PathBuf::from(
        std::env::var("DRGNX_TEST_MODELS").expect("DRGNX_TEST_MODELS names the model volume"),
    )
    .join(MODEL)
}

fn adapter() -> String {
    std::env::var("DRGNX_TEST_ADAPTER")
        .expect("DRGNX_TEST_ADAPTER names the GPU adapter of this run")
}

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

fn vectors(v: &Value) -> Vec<Vec<f32>> {
    v["vectors"]
        .as_array()
        .unwrap_or_else(|| panic!("no vectors in {v}"))
        .iter()
        .map(|row| {
            row.as_array()
                .unwrap()
                .iter()
                .map(|x| x.as_f64().unwrap() as f32)
                .collect()
        })
        .collect()
}

/// A worker child, its stdin, and its stdout's lines read on a thread.
struct Worker {
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    lines: Receiver<Option<Value>>,
    _cache: TempDir,
}

impl Worker {
    fn start(device: &str, extra: &[&str]) -> Worker {
        let cache = tempfile::tempdir().unwrap();
        let mut child = Command::new(exe())
            .arg("embed-worker")
            .args(["--model", MODEL, "--threads", "2", "--device", device])
            .arg("--dir")
            .arg(model_dir())
            .arg("--device-cache")
            .arg(cache.path().join("device.json"))
            .args(extra)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take();
        let out = child.stdout.take().unwrap();
        let (tx, lines) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(out).lines() {
                let Ok(line) = line else { break };
                let v: Value =
                    serde_json::from_str(&line).unwrap_or_else(|e| panic!("{line}: {e}"));
                if tx.send(Some(v)).is_err() {
                    return;
                }
            }
            let _ = tx.send(None);
        });
        Worker {
            child: Some(child),
            stdin,
            lines,
            _cache: cache,
        }
    }

    fn send(&mut self, v: Value) {
        let stdin = self.stdin.as_mut().unwrap();
        writeln!(stdin, "{v}").unwrap();
        stdin.flush().unwrap();
    }

    /// The next line; `None` at the end of the output.
    fn line(&self) -> Option<Value> {
        self.lines
            .recv_timeout(BOUND)
            .expect("the worker said nothing")
    }

    fn exit(&mut self) -> ExitStatus {
        let mut child = self.child.take().unwrap();
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            let _ = tx.send(child.wait());
        });
        rx.recv_timeout(BOUND)
            .expect("the worker never exited")
            .unwrap()
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        if let Some(c) = self.child.as_mut() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

fn doc(id: u64, texts: &[&str]) -> Value {
    json!({"id": id, "kind": "doc", "texts": texts})
}

/// Pattern C. `--idle-ms 50`, its stdin left open: the test waits for the exit itself, and asserts no time.
#[test]
fn worker_unloads_after_idle() {
    let mut w = Worker::start("cpu", &["--idle-ms", "50"]);
    assert!(w.line().unwrap().get("ready").is_some());
    assert!(w.exit().success());
    assert_eq!(w.line(), None);
    assert!(
        w.stdin.is_some(),
        "it went by itself, not at the end of its stdin"
    );
}

/// Pattern C. The hub's end closes the worker's stdin: a dead hub leaves no worker.
#[test]
fn worker_exits_when_the_hub_goes() {
    let mut w = Worker::start("cpu", &[]);
    assert!(w.line().unwrap().get("ready").is_some());
    drop(w.stdin.take());
    assert!(w.exit().success());
    assert_eq!(w.line(), None);
}

/// Pattern C.
#[test]
fn worker_says_its_device_first() {
    let w = Worker::start("cpu", &[]);
    let first = w.line().unwrap();
    let ready = &first["ready"];
    assert_eq!(ready["device"], "cpu", "{first}");
    assert!(
        ready["name"].as_str().is_some_and(|n| !n.is_empty()),
        "{first}"
    );
    assert!(ready["why"].as_str().is_some(), "{first}");
}

/// Pattern C. `gpu:NAME` (test-hooks) runs on that adapter and destroys its device after the first batch; the next
/// batch runs again on the CPU path, says so first, and its vectors are interchangeable with the GPU's.
#[test]
#[cfg_attr(
    target_os = "macos",
    ignore = "a GPU row: CI's Mac has no GPU, Metal is a real Mac's"
)]
fn device_loss_requeues_on_cpu() {
    let mut w = Worker::start(&format!("gpu:{}", adapter()), &[]);
    let first = w.line().unwrap();
    assert_eq!(first["ready"]["device"], "gpu", "{first}");
    let text =
        "(defun drgnx-hub-call (method params) \"Send METHOD to the hub.\" (ignore method params))";
    w.send(doc(1, &[text]));
    let on_gpu = vectors(&w.line().unwrap()).remove(0);
    assert_eq!(on_gpu.len(), DIMS);
    w.send(doc(2, &[text]));
    let fallback = w.line().unwrap();
    assert_eq!(fallback["fallback"]["from"], "gpu", "{fallback}");
    assert!(
        fallback["fallback"]["reason"].as_str().is_some(),
        "{fallback}"
    );
    let answer = w.line().unwrap();
    assert_eq!(answer["id"], 2, "{answer}");
    let on_cpu = vectors(&answer).remove(0);
    assert!(
        cosine(&on_gpu, &on_cpu) >= 0.999,
        "{}",
        cosine(&on_gpu, &on_cpu)
    );
}

/// Pattern C. `--test-park`: before each batch after a request's first, the worker says `parked` and waits for a
/// line. A query sent then is answered before the next batch, not after the whole request.
#[test]
fn query_runs_before_the_next_batch() {
    let mut w = Worker::start("cpu", &["--test-park"]);
    assert!(w.line().unwrap().get("ready").is_some());
    // three chunks of about 900 tokens: two batches at the starting budget of 2,048
    let long = "word ".repeat(900);
    w.send(doc(1, &[&long, &long, &long]));
    assert_eq!(w.line().unwrap(), json!({"parked": 1}));
    w.send(json!({"id": 2, "kind": "query", "texts": ["where does the editor call the hub"]}));
    let query = w.line().unwrap();
    assert_eq!(query["id"], 2, "the query first: {query}");
    assert_eq!(vectors(&query).len(), 1);
    let docs = w.line().unwrap();
    assert_eq!(docs["id"], 1, "{docs}");
    assert_eq!(vectors(&docs).len(), 3);
}

/// Pattern C. The GPU path has no address-space cap (a Vulkan driver maps far more than it uses), so the worker reads
/// its peak resident memory between batches. `--test-rss-cap-mb 1` stands for the 1.5 GiB cap, which any worker is
/// over: before a batch it answers the request with the reason (and `exit`) and exits, by itself and cleanly.
#[test]
#[cfg_attr(
    target_os = "macos",
    ignore = "a GPU row: CI's Mac has no GPU, Metal is a real Mac's"
)]
fn gpu_worker_exits_over_its_rss_cap() {
    let mut w = Worker::start(&format!("gpu:{}", adapter()), &["--test-rss-cap-mb", "1"]);
    let first = w.line().unwrap();
    assert_eq!(first["ready"]["device"], "gpu", "{first}");
    let long = "word ".repeat(900);
    w.send(doc(1, &[&long, &long, &long]));
    let answer = w.line().unwrap();
    assert_eq!(answer["id"], 1, "{answer}");
    let why = answer["error"]
        .as_str()
        .unwrap_or_else(|| panic!("{answer}"));
    assert!(why.contains("memory") && why.contains("cap"), "{why}");
    assert!(w.exit().success());
    assert_eq!(w.line(), None);
}

/// Pattern C. The hub sees that exit as the worker's answer, not a crash: no retry, no crash counted, and the next
/// request starts a fresh worker.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[cfg_attr(
    target_os = "macos",
    ignore = "a GPU row: CI's Mac has no GPU, Metal is a real Mac's"
)]
async fn rss_exit_is_not_a_crash_loop() {
    let (cache, ac) = (tempfile::tempdir().unwrap(), power(true));
    let dev = format!("gpu:{}", adapter());
    let e = WorkerEmbedder::new(spec(
        cache.path(),
        ac.path(),
        &["--device", &dev, "--test-rss-cap-mb", "1"],
    ));
    let long = "word ".repeat(900);
    let texts = vec![long.clone(), long.clone(), long];
    let err = e.embed_docs(&texts, false).await.unwrap_err();
    assert!(err.0.contains("memory"), "{err:?}");
    let facts = e.facts();
    assert_eq!((facts.crashes, facts.spawns), (0, 1), "{facts:?}");
    let err = e.embed_docs(&texts, false).await.unwrap_err();
    assert!(err.0.contains("memory"), "{err:?}");
    let facts = e.facts();
    assert_eq!((facts.crashes, facts.spawns), (0, 2), "{facts:?}");
}

fn spec(cache: &Path, power: &Path, test_args: &[&str]) -> WorkerSpec {
    WorkerSpec {
        exe: exe(),
        model: MODEL.into(),
        dir: model_dir(),
        device_cache: cache.join("device.json"),
        threads: 2,
        idle_ms: None,
        power_root: power.to_path_buf(),
        test_args: test_args.iter().map(|s| s.to_string()).collect(),
    }
}

/// `<root>/class/power_supply/`: a mains supply, online or not, and a battery.
fn power(on_ac: bool) -> TempDir {
    let d = tempfile::tempdir().unwrap();
    let ps = d.path().join("class/power_supply");
    for (name, ty, online) in [
        ("AC", "Mains", if on_ac { "1" } else { "0" }),
        ("BAT0", "Battery", "1"),
    ] {
        std::fs::create_dir_all(ps.join(name)).unwrap();
        std::fs::write(ps.join(name).join("type"), format!("{ty}\n")).unwrap();
        std::fs::write(ps.join(name).join("online"), format!("{online}\n")).unwrap();
    }
    d
}

/// Pattern C. The worker dies inside a request (killed mid-batch): the embedder reports it, starts another and sends
/// the request again, once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn worker_crash_is_reported_and_retried_once() {
    let (cache, ac) = (tempfile::tempdir().unwrap(), power(true));
    let marker = cache.path().join("crashed");
    let once = WorkerEmbedder::new(spec(
        cache.path(),
        ac.path(),
        &[
            "--device",
            "cpu",
            "--test-crash-once",
            marker.to_str().unwrap(),
        ],
    ));
    let got = once
        .embed_docs(&["(defun a () 1)".to_string()], false)
        .await
        .unwrap();
    assert_eq!(got.len(), 1);
    let facts = once.facts();
    assert_eq!((facts.crashes, facts.spawns), (1, 2), "{facts:?}");
    assert!(marker.exists());

    let always = WorkerEmbedder::new(spec(
        cache.path(),
        ac.path(),
        &["--device", "cpu", "--test-crash-always"],
    ));
    let err = always
        .embed_docs(&["(defun a () 1)".to_string()], false)
        .await
        .unwrap_err();
    assert!(err.0.contains("crash"), "{err:?}");
    let facts = always.facts();
    assert_eq!(
        (facts.crashes, facts.spawns),
        (2, 2),
        "retried once only: {facts:?}"
    );
}

fn git(dir: &Path, args: &[&str]) {
    let st = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .status()
        .unwrap();
    assert!(st.success(), "git {args:?}");
}

fn repo_at(dir: &Path, files: &[(&str, &str)]) {
    std::fs::create_dir_all(dir).unwrap();
    git(dir, &["init", "-q"]);
    for (p, c) in files {
        let f = dir.join(p);
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        std::fs::write(f, c).unwrap();
    }
    git(dir, &["add", "-A"]);
    git(dir, &["commit", "-q", "-m", "one"]);
}

/// A project of N small Lisp files, one chunk each.
fn lisp_files(n: usize) -> Vec<(String, String)> {
    (0..n)
        .map(|i| {
            (
                format!("core/f{i}.el"),
                format!(";;; f{i}.el\n(defun f{i}-run () \"Run number {i}.\" {i})\n"),
            )
        })
        .collect()
}

struct Fixture {
    home: TempDir,
    state: TempDir,
    root: PathBuf,
}

fn fixture(files: &[(String, String)]) -> Fixture {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join("src/proj");
    let refs: Vec<(&str, &str)> = files
        .iter()
        .map(|(p, c)| (p.as_str(), c.as_str()))
        .collect();
    repo_at(&root, &refs);
    Fixture {
        home,
        state: tempfile::tempdir().unwrap(),
        root,
    }
}

fn project_spec(f: &Fixture, embedders: Vec<Arc<WorkerEmbedder>>, power: &Path) -> ProjectSpec {
    ProjectSpec {
        root: f.root.clone(),
        state: f.state.path().to_path_buf(),
        home: f.home.path().to_path_buf(),
        config_dir: f.home.path().join(".config/drgnx"),
        config: hrafn::Config::default(),
        embedders: embedders
            .into_iter()
            .map(|e| e as Arc<dyn DocEmbedder>)
            .collect(),
        power_root: power.to_path_buf(),
        test_permits: None,
    }
}

/// F on the virtual clock, on the hub's runtime (`serve`'s: two workers and the clock's park hooks), one F at a time.
/// The clock is the process's, and so is this runtime: an advance and a barrier wait for the workers to park, which
/// only a runtime with the hooks reports, and for every task the clock tracks, so the tests that start tier 2 run
/// here, one after another.
fn on_hub_runtime<F: std::future::Future>(f: F) -> F::Output {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    static ONE: Mutex<()> = Mutex::new(());
    let _one = ONE.lock().unwrap_or_else(PoisonError::into_inner);
    clock::install_virtual();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .on_thread_park(clock::worker_parks)
            .on_thread_unpark(clock::worker_unparks)
            .build()
            .unwrap()
    })
    .block_on(f)
}

async fn status_until(p: &Project, what: &str, f: impl Fn(&Status) -> bool) -> Status {
    let mut rx = p.status();
    let got = tokio::time::timeout(BOUND, rx.wait_for(|s| f(s)))
        .await
        .unwrap_or_else(|_| {
            panic!(
                "tier 2 never reached: {what} (now {:?})",
                *p.status().borrow()
            )
        });
    got.unwrap().clone()
}

/// Pattern D.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tier1_without_embedder() {
    let f = fixture(&lisp_files(3));
    let p = Project::open(project_spec(&f, vec![], Path::new("/nonexistent")))
        .await
        .unwrap();
    let r = p.refresh_now().await.unwrap();
    assert_eq!(r.files_changed, 3);
    assert!(r.chunks_written >= 3);
    assert_eq!(r.keys_missing, 0, "no model, nothing to embed");
    let lag = p.lag(None).await.unwrap();
    assert_eq!(lag.model, None);
    assert_eq!(lag.chunks_behind, 0);
    let symbols: i64 = p
        .store()
        .handle()
        .read(|c| {
            Ok(c.query_row(
                "select count(*) from symbol where name = 'f1-run'",
                [],
                |r| r.get(0),
            )?)
        })
        .await
        .unwrap();
    assert_eq!(symbols, 1, "keyword and symbol search have their rows");
    assert_eq!(p.refresh_now().await.unwrap().files_changed, 0);
}

/// Pattern D. A linked worktree is its main checkout's project: worktree agents search main's store.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn worktree_maps_to_the_main_store() {
    let f = fixture(&lisp_files(1));
    let wt = f.home.path().join("src/proj-topic");
    git(
        &f.root,
        &["worktree", "add", "-q", "-b", "topic", wt.to_str().unwrap()],
    );
    let (main_root, main_id) = project_id(&f.root).unwrap();
    let (wt_root, wt_id) = project_id(&wt).unwrap();
    assert_eq!(wt_id, main_id);
    assert_eq!(wt_root, main_root);
    assert_eq!(main_root, std::fs::canonicalize(&f.root).unwrap());
    assert_eq!(main_id.len(), 16);
    assert!(main_id.bytes().all(|b| b.is_ascii_hexdigit()));

    let mut s = project_spec(&f, vec![], Path::new("/nonexistent"));
    s.root = wt.clone();
    let p = Project::open(s).await.unwrap();
    assert_eq!(p.id(), main_id);
    assert!(f.state.path().join(format!("code/{main_id}.db")).exists());
}

/// Pattern D. Storage §5.6: a root under `~/org` is refused before anything is listed; a root that holds `~/org`
/// (HOME itself) indexes around it, and a canary there never reaches what tier 2 would embed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn denied_root_refused_and_canary_never_embedded() {
    let home = tempfile::tempdir().unwrap();
    let canary = format!(
        "canary-{:016x}",
        u64::from(std::process::id()).wrapping_mul(0x9e37_79b9_7f4a_7c15)
    );
    let inside = home.path().join("org/proj");
    repo_at(&inside, &[("a.el", "(defun a () 1)\n")]);
    let state = tempfile::tempdir().unwrap();
    let spec_for = |root: PathBuf| ProjectSpec {
        root,
        state: state.path().to_path_buf(),
        home: home.path().to_path_buf(),
        config_dir: home.path().join(".config/drgnx"),
        config: hrafn::Config::default(),
        embedders: vec![],
        power_root: PathBuf::from("/nonexistent"),
        test_permits: None,
    };
    match Project::open(spec_for(inside.clone())).await {
        Err(ProjectError::Denied(why)) => assert!(why.contains("personal notes"), "{why}"),
        Err(e) => panic!("refused for the wrong reason: {e}"),
        Ok(_) => panic!("a root under ~/org was opened"),
    }
    assert!(
        !state.path().join("code").exists(),
        "no store for a refused root"
    );

    // HOME as a repository holding ~/org
    std::fs::remove_dir_all(home.path().join("org/proj/.git")).unwrap();
    std::fs::write(home.path().join("org/notes.org"), format!("* {canary}\n")).unwrap();
    repo_at(home.path(), &[("src/a.el", "(defun a-home () 1)\n")]);
    let p = Project::open(spec_for(home.path().to_path_buf()))
        .await
        .unwrap();
    let r = p.refresh_now().await.unwrap();
    assert_eq!(r.files_changed, 1, "src/a.el only: {r:?}");
    let leaked: i64 = {
        let like = format!("%{canary}%");
        p.store()
            .handle()
            .read(move |c| {
                Ok(c.query_row(
                    "select count(*) from chunk where embed_text like ?1 or path like 'org/%'",
                    [&like],
                    |r| r.get(0),
                )?)
            })
            .await
            .unwrap()
    };
    assert_eq!(leaked, 0);
    let pending = hrafn::missing(p.store(), MODEL, 1000).await.unwrap();
    assert!(pending.iter().all(|(_, t)| !t.contains(&canary)));
}

/// Pattern B: tier 2 holds while typing holds, and only between requests. The clock moves by 250 ms advances;
/// tier 2 takes each request on a permit the test gives.
#[test]
fn typing_holds_tier2_between_requests() {
    on_hub_runtime(async {
        let (cache, ac) = (tempfile::tempdir().unwrap(), power(true));
        let f = fixture(&lisp_files(20));
        let embedder = Arc::new(WorkerEmbedder::new(spec(
            cache.path(),
            ac.path(),
            &["--device", "cpu"],
        )));
        let permits = Arc::new(Semaphore::new(0));
        let mut s = project_spec(&f, vec![embedder], ac.path());
        s.test_permits = Some(permits.clone());
        let p = Project::open(s).await.unwrap();
        let total = p.refresh_now().await.unwrap().keys_missing as u64;
        assert_eq!(total, 20);

        p.note_typing();
        p.start_tier2();
        permits.add_permits(1);
        let held = status_until(&p, "typing", |s| s.tier2 == Tier2::Typing).await;
        assert_eq!(held.embedded, 0);
        for _ in 0..11 {
            clock::advance(Duration::from_millis(250)).await;
            let now = p.status().borrow().clone();
            assert_eq!(
                (now.tier2, now.embedded),
                (Tier2::Typing, 0),
                "held for 3 s from the last keystroke"
            );
        }
        clock::advance(Duration::from_millis(250)).await;
        // one request of 8 keys, then tier 2 waits for its next permit
        let after_one = status_until(&p, "the first request", |s| s.embedded == 8).await;
        assert_eq!(after_one.tier2, Tier2::Running);

        p.note_typing();
        permits.add_permits(1);
        let again = status_until(&p, "typing again", |s| s.tier2 == Tier2::Typing).await;
        assert_eq!(again.embedded, 8, "held between requests, never inside one");
        assert_eq!(
            p.lag(Some(MODEL)).await.unwrap().chunks_behind as u64,
            total - 8
        );

        permits.add_permits(100);
        for _ in 0..12 {
            clock::advance(Duration::from_millis(250)).await;
        }
        let done = status_until(&p, "idle", |s| s.tier2 == Tier2::Idle).await;
        assert_eq!(done.embedded, total);
        assert_eq!(p.lag(Some(MODEL)).await.unwrap().chunks_behind, 0);
    })
}

/// Pattern B (the gate is the power supply's state). On battery tier 2 waits for AC and no worker starts; tier 1
/// goes on.
#[test]
fn battery_holds_tier2_and_tier1_goes_on() {
    on_hub_runtime(async {
        let (cache, bat) = (tempfile::tempdir().unwrap(), power(false));
        let f = fixture(&lisp_files(3));
        let embedder = Arc::new(WorkerEmbedder::new(spec(cache.path(), bat.path(), &[])));
        let p = Project::open(project_spec(&f, vec![embedder.clone()], bat.path()))
            .await
            .unwrap();
        assert_eq!(p.refresh_now().await.unwrap().files_changed, 3);
        p.start_tier2();
        let held = status_until(&p, "battery", |s| s.tier2 == Tier2::Battery).await;
        assert_eq!(held.embedded, 0);
        assert_eq!(embedder.facts().spawns, 0, "no worker on battery");

        std::fs::write(
            f.root.join("core/f1.el"),
            ";;; f1.el\n(defun f1-run () \"Changed.\" 10)\n",
        )
        .unwrap();
        assert_eq!(p.refresh_now().await.unwrap().files_changed, 1);
        assert_eq!(p.status().borrow().tier2, Tier2::Battery);
        assert_eq!(embedder.facts().spawns, 0);
    })
}

/// Pattern B. `index now` overrides the battery wait, in a worker started with `--device auto`; on battery that
/// worker measures nothing and caches nothing.
#[test]
fn index_now_overrides_battery() {
    on_hub_runtime(async {
        let (cache, bat) = (tempfile::tempdir().unwrap(), power(false));
        let f = fixture(&lisp_files(3));
        let embedder = Arc::new(WorkerEmbedder::new(spec(cache.path(), bat.path(), &[])));
        let p = Project::open(project_spec(&f, vec![embedder.clone()], bat.path()))
            .await
            .unwrap();
        p.refresh_now().await.unwrap();
        p.start_tier2();
        status_until(&p, "battery", |s| s.tier2 == Tier2::Battery).await;
        p.index_now();
        let done = status_until(&p, "idle", |s| s.tier2 == Tier2::Idle).await;
        assert_eq!(done.embedded, 3);
        let facts = embedder.facts();
        assert_eq!(facts.device_arg.as_deref(), Some("auto"), "{facts:?}");
        let ready = facts.ready.expect("the worker said its device");
        assert_eq!(ready["device"], "cpu");
        assert!(
            ready["why"].as_str().unwrap().contains("battery"),
            "{ready}"
        );
        assert!(
            !cache.path().join("device.json").exists(),
            "nothing measured on battery is kept"
        );
    })
}

/// Pattern B. A wake that finds nothing missing leaves tier 2 idle. The refresh before tier 2 starts leaves a wake
/// (`Notify` keeps it), and `index now`, read at the gate of tier 2's first pass, is never waited for; once the request
/// is done that kept wake must not take tier 2 back to its battery gate. Tier 2 takes each pass on a permit, and the
/// test gives one more than the request and the pass that finds nothing; the hub's barrier is the gate after them.
#[test]
fn a_wake_with_nothing_missing_stays_idle() {
    on_hub_runtime(async {
        let (cache, bat) = (tempfile::tempdir().unwrap(), power(false));
        let f = fixture(&lisp_files(3));
        let embedder = Arc::new(WorkerEmbedder::new(spec(cache.path(), bat.path(), &[])));
        let permits = Arc::new(Semaphore::new(0));
        let mut s = project_spec(&f, vec![embedder], bat.path());
        s.test_permits = Some(permits.clone());
        let p = Project::open(s).await.unwrap();
        assert_eq!(p.refresh_now().await.unwrap().keys_missing, 3);
        p.start_tier2();
        p.index_now();
        permits.add_permits(3);
        let done = status_until(&p, "the request's end", |s| {
            s.embedded == 3 && s.tier2 != Tier2::Running
        })
        .await;
        assert_eq!(done.tier2, Tier2::Idle);
        assert_eq!(
            clock::barrier().await,
            Vec::<String>::new(),
            "the barrier held"
        );
        assert_eq!(
            *p.status().borrow(),
            Status {
                tier2: Tier2::Idle,
                embedded: 3
            },
            "nothing is missing: tier 2 stays idle"
        );
        assert_eq!(permits.available_permits(), 1, "no pass after the last");
    })
}

/// Pattern B. A query on battery uses the CPU path, so it doesn't wake a sleeping dGPU.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn query_on_battery_uses_the_cpu() {
    let (cache, bat) = (tempfile::tempdir().unwrap(), power(false));
    let embedder = WorkerEmbedder::new(spec(cache.path(), bat.path(), &[]));
    let v = embedder
        .embed_query("where does the editor call the hub", None)
        .await
        .unwrap();
    assert_eq!(v.len(), DIMS);
    let facts = embedder.facts();
    assert_eq!(facts.device_arg.as_deref(), Some("cpu"), "{facts:?}");
    assert_eq!(facts.ready.unwrap()["device"], "cpu");
    assert_eq!(facts.spawns, 1);
}

// ---- worktree overlays in the hub (H16 overlay design §6, O6) ----

/// A project of three Lisp files, its base built, and N linked worktrees `wt-0`… on branches `b0`….
async fn with_trees(n: usize) -> (Fixture, Project, Vec<PathBuf>) {
    let f = fixture(&lisp_files(3));
    let trees: Vec<PathBuf> = (0..n)
        .map(|i| {
            let wt = f.home.path().join(format!("src/wt-{i}"));
            git(
                &f.root,
                &[
                    "worktree",
                    "add",
                    "-q",
                    "-b",
                    &format!("b{i}"),
                    wt.to_str().unwrap(),
                ],
            );
            wt
        })
        .collect();
    let p = Project::open(project_spec(&f, vec![], Path::new("/nonexistent")))
        .await
        .unwrap();
    p.refresh_now().await.unwrap();
    (f, p, trees)
}

/// The file rows of the tree KEY names.
async fn tree_rows(p: &Project, key: &str) -> Vec<(String, Option<String>)> {
    let key = key.to_string();
    p.store()
        .handle()
        .read(move |c| {
            let mut st = c.prepare(
                "select f.path, f.blob from file f join tree t on t.id = f.tree where t.key = ?1 order by f.path",
            )?;
            Ok(st
                .query_map([key], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<Result<_, _>>()?)
        })
        .await
        .unwrap()
}

/// The tree's line in the project's tree status.
async fn tree_live(p: &Project, key: &str) -> drgnx_ratatoskr::search::project::TreeLive {
    p.tree_status()
        .await
        .unwrap()
        .into_iter()
        .find(|t| t.key == key)
        .unwrap_or_else(|| panic!("no tree {key}"))
}

/// The tree at ROOT opened and seeded: its key.
async fn seeded(p: &Project, root: &Path) -> String {
    let v = p.view_for(root, false).await.unwrap();
    p.settle_trees().await;
    v.worktree.expect("a linked worktree has a key")
}

fn edit(root: &Path, rel: &str, name: &str) {
    std::fs::write(
        root.join(rel),
        format!(";;; edited\n(defun {name} () \"Edited here.\" 1)\n"),
    )
    .unwrap();
}

/// Pattern D. The main checkout answers from the base; a linked worktree from its own view once seeded.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn view_for_names_the_tree() {
    let (f, p, trees) = with_trees(1).await;
    let v = p.view_for(&f.root, false).await.unwrap();
    assert_eq!(v.view, hrafn::View::Base);
    assert_eq!(v.worktree, None);
    edit(&trees[0], "core/f1.el", "wt-only-fn");
    let key = seeded(&p, &trees[0]).await;
    let v = p.view_for(&trees[0], false).await.unwrap();
    assert!(matches!(v.view, hrafn::View::Tree(_)), "{v:?}");
    assert_eq!(tree_rows(&p, &key).await.len(), 1);
}

/// Pattern D. A feed subscriber that lagged past the channel's 256 versions marks the trees stale and re-diffs them:
/// the version it missed reaches the overlay.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn lagged_feed_rediffs() {
    let (_f, p, trees) = with_trees(1).await;
    let key = seeded(&p, &trees[0]).await;
    assert!(tree_rows(&p, &key).await.is_empty());
    edit(&trees[0], "core/f1.el", "missed-fn");
    let (tx, rx) = tokio::sync::broadcast::channel(256);
    let version = |path: &str| drgnx_ratatoskr::history::FileVersion {
        worktree: key.clone(),
        path: path.into(),
        blob: None,
        op: 1,
        class: drgnx_ratatoskr::history::Class::Text,
    };
    // the version of f1 is the first of 300: the subscriber never sees it
    tx.send(version("core/f1.el")).unwrap();
    for _ in 0..299 {
        tx.send(version("core/f0.el")).unwrap();
    }
    drop(tx);
    let checks = tree_live(&p, &key).await.checks;
    p.feed(rx).expect("the first feed is taken").await.unwrap();
    p.settle_trees().await;
    let rows = tree_rows(&p, &key).await;
    assert_eq!(
        rows.iter().map(|r| r.0.as_str()).collect::<Vec<_>>(),
        ["core/f1.el"]
    );
    assert!(tree_live(&p, &key).await.checks > checks, "a lag re-diffs");
}

/// A watcher double: one tree besides main at a time, the next one is `ENOSPC`.
struct OneTree {
    trees: Mutex<Vec<String>>,
}

impl hrafn::Watch for OneTree {
    fn events(&self) -> Receiver<hrafn::WatchEvent> {
        channel().1
    }
    fn add_tree(&self, spec: hrafn::TreeSpec) -> Result<(), hrafn::AddError> {
        let mut t = self.trees.lock().unwrap();
        if spec.key != hrafn::MAIN_TREE && t.iter().any(|k| k != hrafn::MAIN_TREE) {
            return Err(hrafn::AddError::NoSpace("the double's budget".into()));
        }
        t.push(spec.key);
        Ok(())
    }
    fn remove_tree(&self, key: &str) {
        self.trees.lock().unwrap().retain(|k| k != key);
    }
}

/// Pattern D. On `ENOSPC` the least recently used tree is unwatched (the new one is watched), and the unwatched tree
/// still answers right after its check.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn watch_budget_unwatches_lru_tree() {
    let (_f, p, trees) = with_trees(2).await;
    let w = Arc::new(hrafn::ProjectWatch::new(|| {
        Ok(Arc::new(OneTree {
            trees: Mutex::new(vec![]),
        }) as Arc<dyn hrafn::Watch>)
    }));
    w.add_tree(hrafn::TreeSpec::main(p.root())).unwrap();
    p.watch(w);
    let a = seeded(&p, &trees[0]).await;
    assert!(tree_live(&p, &a).await.watched);
    let b = seeded(&p, &trees[1]).await;
    assert!(tree_live(&p, &b).await.watched, "the new tree is watched");
    let la = tree_live(&p, &a).await;
    assert!(!la.watched);
    assert_eq!(la.state, hrafn::TreeState::Unwatched);
    edit(&trees[0], "core/f2.el", "after-unwatch-fn");
    p.view_for(&trees[0], false).await.unwrap();
    p.settle_trees().await;
    assert_eq!(
        tree_rows(&p, &a)
            .await
            .iter()
            .map(|r| r.0.as_str())
            .collect::<Vec<_>>(),
        ["core/f2.el"]
    );
}

/// Pattern D. A query in an unwatched tree answers at once from its rows; its check reads only the stat-dirty file,
/// and a burst of queries within the TTL runs one check.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn query_check_is_stat_bound_and_ttl() {
    let (_f, p, trees) = with_trees(1).await;
    let key = seeded(&p, &trees[0]).await;
    assert_eq!(tree_live(&p, &key).await.state, hrafn::TreeState::Unwatched);
    let before = tree_live(&p, &key).await.checks;
    edit(&trees[0], "core/f1.el", "dirty-fn");
    for _ in 0..3 {
        let v = p.view_for(&trees[0], false).await.unwrap();
        assert!(matches!(v.view, hrafn::View::Tree(_)), "{v:?}");
        assert_eq!(v.state, Some(hrafn::TreeState::Unwatched));
    }
    p.settle_trees().await;
    let l = tree_live(&p, &key).await;
    assert_eq!(l.checks, before + 1, "one check for the burst");
    assert_eq!(l.last.map(|s| s.read), Some(1), "{:?}", l.last);
    assert_eq!(tree_rows(&p, &key).await.len(), 1);
}

/// Pattern D. A 17th tree evicts the least recently used tree's rows; a tree used again is kept.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn resident_cap_evicts_lru() {
    use drgnx_ratatoskr::search::project::RESIDENT_CAP;
    let (_f, p, trees) = with_trees(RESIDENT_CAP + 1).await;
    let mut keys = Vec::new();
    for (i, t) in trees.iter().enumerate().take(RESIDENT_CAP) {
        edit(t, "core/f0.el", &format!("tree-{i}-fn"));
        keys.push(seeded(&p, t).await);
    }
    // tree 0 is used again: tree 1 is now the least recently used
    p.view_for(&trees[0], false).await.unwrap();
    p.settle_trees().await;
    let last = &trees[RESIDENT_CAP];
    edit(last, "core/f0.el", "last-tree-fn");
    seeded(&p, last).await;
    let held: Vec<String> = p
        .tree_status()
        .await
        .unwrap()
        .into_iter()
        .map(|t| t.key)
        .collect();
    assert_eq!(held.len(), RESIDENT_CAP);
    assert!(!held.contains(&keys[1]), "{held:?}");
    assert!(held.contains(&keys[0]), "{held:?}");
    assert!(tree_rows(&p, &keys[1]).await.is_empty());
    assert_eq!(tree_rows(&p, &keys[0]).await.len(), 1);
}

/// Pattern D. `git worktree remove` drops the tree's overlay; a locked worktree whose folder is missing keeps its rows.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn removed_worktree_drops_its_overlay() {
    let (f, p, trees) = with_trees(2).await;
    edit(&trees[0], "core/f0.el", "gone-fn");
    edit(&trees[1], "core/f0.el", "locked-fn");
    let (a, b) = (seeded(&p, &trees[0]).await, seeded(&p, &trees[1]).await);
    git(&f.root, &["worktree", "lock", trees[1].to_str().unwrap()]);
    std::fs::rename(&trees[1], f.home.path().join("src/moved-away")).unwrap();
    git(
        &f.root,
        &["worktree", "remove", "--force", trees[0].to_str().unwrap()],
    );
    p.sweep_trees().await.unwrap();
    let held: Vec<String> = p
        .tree_status()
        .await
        .unwrap()
        .into_iter()
        .map(|t| t.key)
        .collect();
    assert_eq!(held, [b.clone()]);
    assert!(tree_rows(&p, &a).await.is_empty());
    assert_eq!(tree_rows(&p, &b).await.len(), 1);
}

/// Pattern D. Edits made while the hub was down: on open the tree is stale, the first query answers at once from the
/// stored rows, and its check brings the edits in.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn restart_rechecks_stale_tree() {
    let (f, p, trees) = with_trees(1).await;
    edit(&trees[0], "core/f0.el", "before-down-fn");
    let key = seeded(&p, &trees[0]).await;
    drop(p);
    edit(&trees[0], "core/f2.el", "while-down-fn");
    let p = Project::open(project_spec(&f, vec![], Path::new("/nonexistent")))
        .await
        .unwrap();
    assert_eq!(tree_live(&p, &key).await.state, hrafn::TreeState::Stale);
    let v = p.view_for(&trees[0], false).await.unwrap();
    assert_eq!(v.state, Some(hrafn::TreeState::Stale));
    p.settle_trees().await;
    assert_eq!(
        tree_rows(&p, &key)
            .await
            .iter()
            .map(|r| r.0.as_str())
            .collect::<Vec<_>>(),
        ["core/f0.el", "core/f2.el"]
    );
}
