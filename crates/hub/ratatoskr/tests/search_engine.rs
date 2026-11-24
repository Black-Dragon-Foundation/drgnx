//! The local engine (`search::engine`, MP-8) against `ratatoskr-mock embed --as llama-server`, the stand-in for llama.cpp's
//! server: a wrapper script named `llama-server` execs it, so the engine starts it as it starts the real one. The mock
//! is found at `RATATOSKR_MOCK`, else beside this test's binary (`cargo build -p domr --bin ratatoskr-mock`).
//!
//! test-pattern: gated (B) for the idle exit: the engine's idle timer runs on the hub's virtual clock and fires only
//! when the test advances it (`clock::advance`, which returns once the woken task has parked, its process gone); the
//! rest is handshake (C): each request's answer is the event, and the mock's log says what it was asked.

#![cfg(feature = "test-hooks")]

use hrafn_embed::fingerprint::{FingerprintRecord, Pooling};
use ratatoskr::clock;
use ratatoskr::search::engine::{EngineSpec, LocalEngine, SelfCheck};
use serde_json::Value;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::Duration;
use tempfile::TempDir;

const DIMS: usize = 8;
const MAX_TOKENS: u32 = 64;
const IDLE: Duration = Duration::from_secs(300);

/// The rows on the hub's runtime (its two workers and the clock's park hooks), one at a time: the clock is the process's.
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

fn mock_bin() -> PathBuf {
    let bin = skuld::workspace_bin("ratatoskr-mock", None, Some("RATATOSKR_MOCK"));
    assert!(
        bin.exists(),
        "{} is missing: build it first (cargo build -p domr --bin ratatoskr-mock) or name it in RATATOSKR_MOCK",
        bin.display()
    );
    bin
}

fn record() -> FingerprintRecord {
    FingerprintRecord {
        model_id: "mock/qwen3".into(),
        weights_sha256: "00".repeat(32),
        quant: "Q8_0".into(),
        pooling: Pooling::Last,
        normalized: true,
        dims: DIMS as u32,
        max_tokens: MAX_TOKENS,
        doc_prefix: String::new(),
        query_template: "Instruct: {task}\nQuery:{query}".into(),
        embed_text_version: 3,
    }
}

/// A folder with a `llama-server` that is the mock with KNOBS, and its log.
struct Rig {
    dir: TempDir,
    exe: PathBuf,
    log: PathBuf,
}

impl Rig {
    fn new(knobs: &[&str]) -> Rig {
        let dir = TempDir::new().unwrap();
        let (exe, log) = (dir.path().join("llama-server"), dir.path().join("mock.log"));
        let knobs: Vec<String> = knobs
            .iter()
            .map(|k| k.replace("{dir}", &dir.path().display().to_string()))
            .map(|k| format!("'{k}'"))
            .collect();
        std::fs::write(
            &exe,
            format!(
                "#!/bin/sh\nexec '{}' embed --as llama-server --log '{}' --dims {DIMS} {} \"$@\"\n",
                mock_bin().display(),
                log.display(),
                knobs.join(" ")
            ),
        )
        .unwrap();
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
        Rig { dir, exe, log }
    }

    fn spec(&self) -> EngineSpec {
        EngineSpec {
            exe: self.exe.clone(),
            gguf: self.dir.path().join("model.gguf"),
            record: record(),
            label: "the mock engine".into(),
            ctx: 8192,
            ubatch: MAX_TOKENS,
            idle: IDLE,
            selfcheck: None,
            device: None,
            limits: ratatoskr::search::engine_limits::Limits::default(),
            systemd: None,
            hold: None,
        }
    }

    fn engine(&self) -> LocalEngine {
        LocalEngine::new(self.spec())
    }

    fn lines(&self, key: &str) -> Vec<Value> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .map(|l| serde_json::from_str::<Value>(l).unwrap())
            .filter_map(|v| v.get(key).cloned())
            .collect()
    }

    /// Each start's arguments.
    fn starts(&self) -> Vec<Vec<String>> {
        self.lines("start")
            .iter()
            .map(|a| serde_json::from_value(a.clone()).unwrap())
            .collect()
    }

    /// Each embeddings request's inputs.
    fn embeds(&self) -> Vec<Vec<String>> {
        self.lines("embed")
            .iter()
            .map(|a| serde_json::from_value(a.clone()).unwrap())
            .collect()
    }
}

fn texts(t: &[&str]) -> Vec<String> {
    t.iter().map(|s| s.to_string()).collect()
}

fn alive(pid: i32) -> bool {
    draugr::alive(pid)
}

#[test]
fn engine_starts_on_demand_and_exits_idle() {
    on_hub_runtime(async {
        let r = Rig::new(&[]);
        let e = r.engine();
        assert!(r.starts().is_empty(), "nothing runs before a request");
        assert_eq!(e.pid(), None);

        let v = e.embed_docs(&texts(&["a short one", "b"])).await.unwrap();
        assert_eq!(v.len(), 2);
        assert!(v.iter().all(|x| x.len() == DIMS));
        let starts = r.starts();
        assert_eq!(starts.len(), 1, "{starts:?}");
        let args = &starts[0];
        let after = |flag: &str| {
            let i = args
                .iter()
                .position(|a| a == flag)
                .unwrap_or_else(|| panic!("{flag} in {args:?}"));
            args[i + 1].clone()
        };
        for flag in ["--embedding", "--no-webui"] {
            assert!(args.iter().any(|a| a == flag), "{flag} in {args:?}");
        }
        assert_eq!(after("--pooling"), "last");
        assert_eq!(after("--host"), "127.0.0.1");
        assert_eq!(after("--port"), "0", "a free port, read from its log line");
        assert_eq!(after("-c"), "512", "the longest text rounded up to 512");
        assert_eq!(
            after("-m"),
            r.dir.path().join("model.gguf").display().to_string()
        );
        let pid = e.pid().expect("running");

        clock::advance(IDLE - Duration::from_secs(1)).await;
        assert!(alive(pid), "not before its idle time");
        assert_eq!(e.pid(), Some(pid));

        clock::advance(Duration::from_secs(1)).await;
        skuld::wait_until("the engine exits after its idle time", 30, || {
            (!alive(pid)).then_some(())
        });
        assert_eq!(e.pid(), None);

        e.embed_docs(&texts(&["again"])).await.unwrap();
        assert_eq!(r.starts().len(), 2, "started again on demand");
        e.close().await;
    });
}

#[test]
fn engine_never_truncates() {
    on_hub_runtime(async {
        let r = Rig::new(&[]);
        let e = r.engine();
        let long = "x".repeat(MAX_TOKENS as usize * 3);
        let got = e.embed_docs(&[long]).await;
        let why = got.expect_err("an over-long text is an error").0;
        assert!(
            why.contains(&MAX_TOKENS.to_string()) && why.contains("tokens"),
            "it says the limit: {why}"
        );
        assert_eq!(
            r.embeds(),
            Vec::<Vec<String>>::new(),
            "no embeddings request"
        );
        e.close().await;
    });
}

#[test]
fn engine_selfcheck_refuses_a_vector_below_0_99_to_the_reference() {
    on_hub_runtime(async {
        const TEXT: &str = "(defun drgnx-selfcheck () \"The engine's own check.\")";
        // the reference: this text's vector as a sound engine gives it
        let sound = Rig::new(&[]);
        let reference = sound
            .engine()
            .embed_docs(&texts(&[TEXT]))
            .await
            .unwrap()
            .remove(0);
        let check = SelfCheck {
            text: TEXT.into(),
            vector: reference,
        };

        let mut spec = sound.spec();
        spec.selfcheck = Some(check.clone());
        let good = LocalEngine::new(spec);
        let c = good.selfcheck().await.unwrap();
        assert!(c > 0.999, "{c}");
        good.close().await;

        let off = Rig::new(&["--perturb"]);
        let mut spec = off.spec();
        spec.selfcheck = Some(check);
        let bad = LocalEngine::new(spec);
        let why = bad.selfcheck().await.expect_err("refused").0;
        assert!(why.contains("0.99"), "it says the threshold: {why}");
        let got = bad.embed_docs(&texts(&["any text"])).await;
        assert!(
            got.is_err(),
            "an engine that failed its check embeds nothing: {got:?}"
        );
        assert!(
            !off.embeds().iter().flatten().any(|t| t == "any text"),
            "never sent: {:?}",
            off.embeds()
        );
        bad.close().await;
    });
}

#[test]
fn crash_mid_request_restarts_once() {
    on_hub_runtime(async {
        let r = Rig::new(&["--crash-once", "{dir}/crashed"]);
        let e = r.engine();
        let v = e.embed_docs(&texts(&["one", "two"])).await.unwrap();
        assert_eq!(v.len(), 2);
        assert!(r.dir.path().join("crashed").exists(), "the first one died");
        assert_eq!(r.starts().len(), 2, "started again once");
        assert_eq!(r.embeds().len(), 2, "the request sent again");
        e.close().await;
    });
}

#[test]
fn batches_sorted_by_length() {
    on_hub_runtime(async {
        let r = Rig::new(&[]);
        let e = r.engine();
        let given = texts(&[
            &"a".repeat(40),
            "bbbbb",
            &"c".repeat(30),
            &"d".repeat(10),
            &"e".repeat(20),
        ]);
        let got = e.embed_docs(&given).await.unwrap();
        let asked = r.embeds();
        assert!(
            asked.len() > 1,
            "more than one batch under a budget of {MAX_TOKENS}: {asked:?}"
        );
        let lengths: Vec<usize> = asked.iter().flatten().map(String::len).collect();
        assert!(
            lengths.windows(2).all(|w| w[0] <= w[1]),
            "shortest first: {lengths:?}"
        );
        assert_eq!(lengths.len(), given.len(), "each text once");
        // and the answer is in the caller's order
        for (t, v) in given.iter().zip(&got) {
            let one = e.embed_docs(std::slice::from_ref(t)).await.unwrap();
            assert_eq!(&one[0], v, "{t}");
        }
        e.close().await;
    });
}

/// Pattern C. The engine takes more texts a request than the built-in model: a pass of the chain costs a store read
/// and a write whatever its size, so eight keys a pass left the GPU idle between requests (the first real run).
#[test]
fn the_engine_takes_a_wide_batch() {
    let rig = Rig::new(&[]);
    let batch = ratatoskr::search::DocEmbedder::max_batch(&rig.engine());
    assert_eq!(batch, ratatoskr::search::engine::ENGINE_BATCH);
    assert!(batch >= 32, "{batch}");
}

/// The args of the start that ran the server (the mock logs `{"start": ARGS}` only for a server, not for `--list-devices`).
fn flag_after(args: &[String], flag: &str) -> Option<String> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1).cloned())
}

const ROCM_ONE: &str = "  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 22212 MiB free)\n";

/// The rig with a device list the mock prints for `--list-devices`.
fn rig_with_devices(text: &str) -> Rig {
    let r = Rig::new(&["--devices", "{dir}/devices.txt"]);
    std::fs::write(r.dir.path().join("devices.txt"), text).unwrap();
    r
}

#[test]
fn the_engine_is_pinned_to_its_device_with_no_split() {
    on_hub_runtime(async {
        let r = rig_with_devices(ROCM_ONE);
        let mut spec = r.spec();
        spec.device = Some("ROCm0".into());
        let e = LocalEngine::new(spec);
        e.embed_docs(&texts(&["a"])).await.unwrap();
        let starts = r.starts();
        assert_eq!(
            starts.len(),
            1,
            "the device list is asked, not started: {starts:?}"
        );
        let args = &starts[0];
        assert_eq!(flag_after(args, "--device").as_deref(), Some("ROCm0"));
        assert_eq!(flag_after(args, "--split-mode").as_deref(), Some("none"));
        assert_eq!(
            flag_after(args, "-ngl").as_deref(),
            Some("999"),
            "every layer on the GPU"
        );
        e.close().await;
    });
}

#[test]
fn a_cpu_engine_says_so_in_its_args() {
    on_hub_runtime(async {
        let r = Rig::new(&[]);
        let mut spec = r.spec();
        spec.device = Some("none".into());
        let e = LocalEngine::new(spec);
        e.embed_docs(&texts(&["a"])).await.unwrap();
        let args = &r.starts()[0];
        assert_eq!(flag_after(args, "--device").as_deref(), Some("none"));
        assert_eq!(flag_after(args, "-ngl").as_deref(), Some("0"));
        e.close().await;
    });
}

#[test]
fn the_cpu_limit_sets_the_engines_threads() {
    on_hub_runtime(async {
        let r = Rig::new(&[]);
        let mut spec = r.spec();
        spec.limits.cpu_percent = Some(1);
        let e = LocalEngine::new(spec);
        e.embed_docs(&texts(&["a"])).await.unwrap();
        assert_eq!(
            flag_after(&r.starts()[0], "-t").as_deref(),
            Some("1"),
            "1 percent is one thread"
        );
        e.close().await;
    });
}

#[test]
fn a_start_over_the_video_memory_limit_is_refused_and_not_started() {
    on_hub_runtime(async {
        let r = rig_with_devices(ROCM_ONE);
        let mut spec = r.spec();
        spec.device = Some("ROCm0".into());
        spec.limits.vram_mib = Some(100);
        let e = LocalEngine::new(spec);
        let err = e.embed_docs(&texts(&["a"])).await.unwrap_err();
        assert!(err.0.contains("drgnx-search-vram-limit"), "{}", err.0);
        assert!(r.starts().is_empty(), "never started over the ceiling");
        assert_eq!(e.pid(), None);
    });
}

#[test]
fn a_start_without_the_free_video_memory_is_refused_with_the_numbers() {
    on_hub_runtime(async {
        let r = rig_with_devices("  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 50 MiB free)\n");
        let mut spec = r.spec();
        spec.device = Some("ROCm0".into());
        let e = LocalEngine::new(spec);
        let err = e.embed_docs(&texts(&["a"])).await.unwrap_err();
        assert!(err.0.contains("50 MiB free"), "{}", err.0);
        assert!(r.starts().is_empty());
    });
}

/// A pool member that records what it was given and fails when told to.
struct Fake {
    got: Mutex<Vec<String>>,
    fail: std::sync::atomic::AtomicBool,
}

impl Fake {
    fn new(fail: bool) -> std::sync::Arc<Fake> {
        std::sync::Arc::new(Fake {
            got: Mutex::new(Vec::new()),
            fail: fail.into(),
        })
    }

    fn count(&self) -> usize {
        self.got.lock().unwrap().len()
    }
}

impl ratatoskr::search::engine_pool::Lane for Fake {
    fn embed<'a>(
        &'a self,
        t: &'a [String],
    ) -> urdr::graph::search::BoxFuture<'a, Result<Vec<Vec<f32>>, urdr::graph::search::EmbedError>>
    {
        Box::pin(async move {
            if self.fail.load(std::sync::atomic::Ordering::SeqCst) {
                return Err(urdr::graph::search::EmbedError("this engine died".into()));
            }
            self.got.lock().unwrap().extend(t.iter().cloned());
            // the vector says which text it is: the order of the answer is checkable
            Ok(t.iter()
                .map(|x| vec![x[1..].parse::<f32>().unwrap()])
                .collect())
        })
    }

    fn query<'a>(
        &'a self,
        _: &'a str,
        _: Option<&'a str>,
    ) -> urdr::graph::search::BoxFuture<'a, Result<Vec<f32>, urdr::graph::search::EmbedError>> {
        Box::pin(async { Ok(vec![0.0]) })
    }
}

fn pool_of(
    lanes: &[(&str, &std::sync::Arc<Fake>, f64)],
) -> ratatoskr::search::engine_pool::EnginePool {
    let identity = Rig::new(&[]).engine().identity();
    ratatoskr::search::engine_pool::EnginePool::new(
        lanes
            .iter()
            .map(|(id, f, rate)| {
                (
                    id.to_string(),
                    {
                        let own: std::sync::Arc<Fake> = std::sync::Arc::clone(*f);
                        let lane: std::sync::Arc<dyn ratatoskr::search::engine_pool::Lane> = own;
                        lane
                    },
                    *rate,
                )
            })
            .collect(),
        identity,
        None,
    )
}

fn numbered(n: usize) -> Vec<String> {
    (0..n).map(|i| format!("t{i}")).collect()
}

fn in_order(v: &[Vec<f32>]) -> bool {
    v.iter().enumerate().all(|(i, x)| x[0] == i as f32)
}

#[test]
fn weighted_splits_sum_to_the_whole_and_follow_the_weights() {
    use ratatoskr::search::engine_pool::split_weighted;
    assert_eq!(split_weighted(8, &[3.0, 1.0]), [6, 2]);
    assert_eq!(
        split_weighted(10, &[1.0, 1.0, 1.0]),
        [4, 3, 3],
        "the remainder goes to the first of equals"
    );
    assert_eq!(split_weighted(5, &[1.0]), [5]);
    assert_eq!(split_weighted(0, &[2.0, 1.0]), [0, 0]);
    assert_eq!(
        split_weighted(7, &[0.0, 0.0]),
        [4, 3],
        "no rates: an even split"
    );
    let eight = split_weighted(64, &[8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0]);
    assert_eq!(eight.iter().sum::<usize>(), 64);
    assert!(eight.windows(2).all(|w| w[0] >= w[1]), "{eight:?}");
}

#[test]
fn a_pool_gives_each_engine_batches_by_its_rate_and_keeps_the_order() {
    on_hub_runtime(async {
        let (fast, slow) = (Fake::new(false), Fake::new(false));
        let p = pool_of(&[("CUDA0", &fast, 3.0), ("CUDA1", &slow, 1.0)]);
        let v = p.embed_docs(&numbered(8)).await.unwrap();
        assert!(in_order(&v), "{v:?}");
        assert_eq!((fast.count(), slow.count()), (6, 2));
    });
}

#[test]
fn eight_engines_share_a_batch_by_their_rates() {
    on_hub_runtime(async {
        let fakes: Vec<_> = (0..8).map(|_| Fake::new(false)).collect();
        let ids: Vec<String> = (0..8).map(|i| format!("CUDA{i}")).collect();
        let lanes: Vec<(&str, &std::sync::Arc<Fake>, f64)> = fakes
            .iter()
            .zip(&ids)
            .enumerate()
            .map(|(i, (f, id))| (id.as_str(), f, (8 - i) as f64))
            .collect();
        let p = pool_of(&lanes);
        let v = p.embed_docs(&numbered(72)).await.unwrap();
        assert!(in_order(&v));
        let counts: Vec<usize> = fakes.iter().map(|f| f.count()).collect();
        assert_eq!(counts, [16, 14, 12, 10, 8, 6, 4, 2]);
    });
}

#[test]
fn a_dead_engines_batch_moves_to_the_others() {
    on_hub_runtime(async {
        let (a, b) = (Fake::new(true), Fake::new(false));
        let p = pool_of(&[("ROCm0", &a, 5.0), ("ROCm1", &b, 5.0)]);
        let v = p.embed_docs(&numbered(10)).await.unwrap();
        assert!(in_order(&v), "every text has its own vector");
        assert_eq!((a.count(), b.count()), (0, 10));
        // the dead one gets nothing the next time
        b.got.lock().unwrap().clear();
        a.fail.store(false, std::sync::atomic::Ordering::SeqCst);
        let v = p.embed_docs(&numbered(4)).await.unwrap();
        assert!(in_order(&v));
        assert_eq!((a.count(), b.count()), (0, 4));
    });
}

#[test]
fn the_only_engine_failing_is_an_error_not_a_silent_loss() {
    on_hub_runtime(async {
        let a = Fake::new(true);
        let p = pool_of(&[("CUDA0", &a, 1.0)]);
        let err = p.embed_docs(&numbered(3)).await.unwrap_err();
        assert!(err.0.contains("died"), "{}", err.0);
        let (x, y) = (Fake::new(true), Fake::new(true));
        let p = pool_of(&[("A", &x, 1.0), ("B", &y, 1.0)]);
        assert!(
            p.embed_docs(&numbered(3)).await.is_err(),
            "all dead is an error"
        );
    });
}

// The hold (the manager's ruling): another program using the device, or its free video memory under the engine's need,
// pauses the engine after the batch it is on; `search status` says why; it goes on when both clear.

/// Five texts of different lengths: more than one batch under the budget.
fn several() -> Vec<String> {
    texts(&[
        &"a".repeat(40),
        "bbbbb",
        &"c".repeat(30),
        &"d".repeat(10),
        &"e".repeat(20),
    ])
}

#[test]
fn a_game_on_the_device_pauses_the_engine_after_its_batch_and_says_why() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    on_hub_runtime(async {
        let r = rig_with_devices(ROCM_ONE);
        let game = Arc::new(AtomicBool::new(true));
        let looks = Arc::new(AtomicUsize::new(0));
        let mut spec = r.spec();
        spec.device = Some("ROCm0".into());
        let (g, l) = (game.clone(), looks.clone());
        // the first look is before the first batch: the game starts as that batch runs
        spec.hold = Some(Arc::new(move |device, _own| {
            assert_eq!(device, "ROCm0", "the look is at the engine's own device");
            let first = l.fetch_add(1, Ordering::SeqCst) == 0;
            (!first && g.load(Ordering::SeqCst)).then(|| "game (pid 9) uses the GPU".to_owned())
        }));
        let e = Arc::new(LocalEngine::new(spec));
        assert_eq!(e.holding(), None);
        let run = tokio::spawn({
            let e = e.clone();
            async move { e.embed_docs(&several()).await }
        });
        let why =
            skuld::wait_until_async("the engine says it is held", 30, || async { e.holding() })
                .await;
        assert!(why.contains("game (pid 9)"), "{why}");
        assert_eq!(
            r.embeds().len(),
            1,
            "it finished the batch it was on and no more"
        );
        assert!(!run.is_finished());
        game.store(false, Ordering::SeqCst);
        clock::advance(ratatoskr::search::engine_hold::HOLD_POLL).await;
        let out = run.await.unwrap().unwrap();
        assert_eq!(out.len(), 5, "every text got its vector");
        assert!(r.embeds().len() > 1);
        assert_eq!(e.holding(), None, "released once the game stopped");
        e.close().await;
    });
}

#[test]
fn free_video_memory_under_the_need_pauses_the_engine_until_it_is_back() {
    use std::sync::Arc;
    on_hub_runtime(async {
        let r = rig_with_devices(ROCM_ONE);
        let mut spec = r.spec();
        spec.device = Some("ROCm0".into());
        let e = Arc::new(LocalEngine::new(spec));
        e.embed_docs(&texts(&["a"])).await.unwrap();
        let devices = r.dir.path().join("devices.txt");
        std::fs::write(
            &devices,
            "  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 50 MiB free)\n",
        )
        .unwrap();
        let before = r.embeds().len();
        let run = tokio::spawn({
            let e = e.clone();
            async move { e.embed_docs(&several()).await }
        });
        let why =
            skuld::wait_until_async("the engine says it is held", 30, || async { e.holding() })
                .await;
        assert!(why.contains("50 MiB"), "{why}");
        assert_eq!(
            r.embeds().len(),
            before,
            "nothing was sent while it was short"
        );
        std::fs::write(&devices, ROCM_ONE).unwrap();
        clock::advance(ratatoskr::search::engine_hold::HOLD_POLL).await;
        assert_eq!(run.await.unwrap().unwrap().len(), 5);
        assert_eq!(e.holding(), None);
        e.close().await;
    });
}

#[test]
fn a_held_engine_shows_as_held_with_its_reason_in_the_chain_status() {
    use ratatoskr::search::DocEmbedder;
    use ratatoskr::search::sources::{DocSource, Source, SourceChain};
    use std::sync::Arc;
    on_hub_runtime(async {
        let r = rig_with_devices(ROCM_ONE);
        let mut spec = r.spec();
        spec.device = Some("ROCm0".into());
        spec.hold = Some(Arc::new(|_, _| {
            Some("train.py (pid 4) uses the GPU".to_owned())
        }));
        let e = Arc::new(LocalEngine::new(spec));
        let fp = DocEmbedder::identity(&*e).unwrap().fp;
        let chain = SourceChain::new(
            fp,
            vec![Arc::new(DocSource::new(e.clone())) as Arc<dyn Source>],
        );
        let engine_entry =
            |c: &SourceChain| c.status().into_iter().find(|s| s.kind != "cache").unwrap();
        assert_eq!(engine_entry(&chain).state, "answering");
        let run = tokio::spawn({
            let e = e.clone();
            async move { e.embed_docs(&several()).await }
        });
        skuld::wait_until_async("held", 30, || async { e.holding() }).await;
        let entry = engine_entry(&chain);
        assert_eq!(entry.state, "held");
        assert!(entry.why.unwrap().contains("train.py (pid 4)"));
        run.abort();
        e.close().await;
    });
}
