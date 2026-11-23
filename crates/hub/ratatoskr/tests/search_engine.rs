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
