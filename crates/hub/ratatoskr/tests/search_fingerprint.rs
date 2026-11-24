//! Fingerprints replace labels (Hrafn redesign Task 4): what a TEI or Ollama server proves of its model, the dims
//! check on write, a server swapped for another model under the same URL, and Ollama's untruncated requests. The servers
//! are `ratatoskr-mock embed` (its `--model-file` swaps the model under one URL); the gateway, the project and its
//! store are real.
//!
//! test-pattern: pure (D) for the records of a server's answers; handshake (C) for the rest: the mock answers when the
//! call returns, and the project's tier 2 is waited on by the rows it writes (`skuld::wait_until_async`).
#![cfg(feature = "test-hooks")]

use crate::search_prefer::{Server, gate, ollama, tei};
use hrafn_embed::fingerprint::{Fingerprint, Pooling};
use ratatoskr::embed::{record_from_ollama, record_from_tei};
use ratatoskr::search::DocEmbedder;
use ratatoskr::search::project::{Project, ProjectSpec, Tier2};
use ratatoskr::settings::providers::ChainStep;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tempfile::TempDir;
use urdr::graph::search::Embedder;

/// What TEI's `GET /info` says of a model.
fn tei_info(model: &str) -> Value {
    json!({
        "model_id": model, "model_sha": "9f2c", "model_dtype": "float16",
        "model_type": {"embedding": {"pooling": "last-token"}},
        "max_input_length": 8192, "max_client_batch_size": 32, "version": "1.9.4",
    })
}

/// Pattern D. TEI's `/info` and the length of one probe embed make the record: the model, its revision, dtype, pooling
/// and longest input; a changed revision, dtype or pooling is another fingerprint; an answer without a model is an error.
#[test]
fn tei_fingerprint_from_info() {
    let r = record_from_tei(&tei_info("Qwen/Qwen3-Embedding-0.6B"), 1024).unwrap();
    assert_eq!(r.model_id, "Qwen/Qwen3-Embedding-0.6B");
    assert_eq!(r.weights_sha256, "9f2c");
    assert_eq!(r.quant, "float16");
    assert_eq!(r.pooling, Pooling::Last);
    assert_eq!((r.dims, r.max_tokens), (1024, 8192));
    assert!(r.normalized);
    let base = r.fingerprint();
    let other = |edit: &dyn Fn(&mut Value)| {
        let mut v = tei_info("Qwen/Qwen3-Embedding-0.6B");
        edit(&mut v);
        record_from_tei(&v, 1024).unwrap().fingerprint()
    };
    assert_ne!(other(&|v| v["model_sha"] = json!("aaaa")), base);
    assert_ne!(other(&|v| v["model_dtype"] = json!("float32")), base);
    assert_ne!(
        other(&|v| v["model_type"]["embedding"]["pooling"] = json!("cls")),
        base
    );
    assert_ne!(
        record_from_tei(&tei_info("Qwen/Qwen3-Embedding-0.6B"), 512)
            .unwrap()
            .fingerprint(),
        base
    );
    assert!(record_from_tei(&json!({"version": "1"}), 8).is_err());
    assert!(
        record_from_tei(&tei_info("m"), 0).is_err(),
        "no dims, no fingerprint"
    );
}

/// Pattern D. Ollama's `/api/show` and the `/api/tags` digest make the record.
#[test]
fn ollama_fingerprint_from_show() {
    let show = json!({
        "details": {"family": "qwen3", "parameter_size": "0.6B", "quantization_level": "Q8_0"},
        "model_info": {"general.architecture": "qwen3", "qwen3.context_length": 32768, "qwen3.pooling_type": 3},
        "template": "{{ .Prompt }}",
    });
    let r = record_from_ollama(&show, "sha256:aa11", 1024).unwrap();
    assert_eq!(r.weights_sha256, "sha256:aa11");
    assert_eq!(r.quant, "Q8_0");
    assert_eq!(r.pooling, Pooling::Last);
    assert_eq!((r.dims, r.max_tokens), (1024, 32768));
    let base = r.fingerprint();
    assert_ne!(
        record_from_ollama(&show, "sha256:bb22", 1024)
            .unwrap()
            .fingerprint(),
        base
    );
    let mut q4 = show.clone();
    q4["details"]["quantization_level"] = json!("Q4_K_M");
    assert_ne!(
        record_from_ollama(&q4, "sha256:aa11", 1024)
            .unwrap()
            .fingerprint(),
        base
    );
    assert!(record_from_ollama(&json!({}), "sha256:aa11", 1024).is_err());
}

/// A git repository of three small files.
fn repo(dir: &Path) {
    let git = |args: &[&str]| {
        let st = ratatoskr::proc::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
            .args(args)
            .status()
            .unwrap();
        assert!(st.success(), "git {args:?}");
    };
    std::fs::create_dir_all(dir).unwrap();
    git(&["init", "-q"]);
    add_files(dir, 3, "one");
    git(&["add", "-A"]);
    git(&["commit", "-q", "-m", "one"]);
}

fn add_files(dir: &Path, n: usize, tag: &str) {
    for i in 0..n {
        let f = dir.join(format!("core/{tag}{i}.el"));
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        ratatoskr::fsio::write(
            f,
            format!(";;; {tag}{i}.el\n(defun {tag}{i}-run () \"Run number {i} of {tag}.\" {i})\n"),
        )
        .unwrap();
    }
}

/// The vector cache files of STATE (`STATE/vectors/*.db`).
fn cache_files(state: &Path) -> Vec<PathBuf> {
    let Ok(rd) = std::fs::read_dir(state.join("vectors")) else {
        return Vec::new();
    };
    rd.filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "db"))
        .collect()
}

/// A project over a fresh repository with the embedders EMBEDDERS: its tier 2 runs freely (no gates).
struct Fixture {
    _home: TempDir,
    _state: TempDir,
    root: PathBuf,
    project: Arc<Project>,
}

async fn project(embedders: Vec<Arc<dyn DocEmbedder>>) -> Fixture {
    let (home, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let root = home.path().join("src/proj");
    repo(&root);
    let project = Arc::new(
        Project::open(ProjectSpec {
            root: root.clone(),
            state: state.path().to_path_buf(),
            home: home.path().to_path_buf(),
            config_dir: home.path().join(".config/drgnx"),
            config: hrafn::Config::default(),
            embedders,
            power_root: PathBuf::from("/nonexistent"),
            base: None,
            test_permits: None,
        })
        .await
        .unwrap(),
    );
    project.refresh_now().await.unwrap();
    Fixture {
        _home: home,
        _state: state,
        root,
        project,
    }
}

impl Fixture {
    /// `(fingerprint, rows)` of the state's vector caches' chunk vectors (the path vectors left out), one per cache file
    /// with any: the fixture's project is the only one of its state, so a cache's rows are its keys.
    async fn vec_models(&self) -> Vec<(String, i64)> {
        let mut out: Vec<(String, i64)> = cache_files(self._state.path())
            .iter()
            .filter_map(|f| {
                let c = rusqlite::Connection::open_with_flags(
                    f,
                    rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
                )
                .ok()?;
                let fp: String = c
                    .query_row(
                        "select value from meta where key = 'fingerprint'",
                        [],
                        |r| r.get(0),
                    )
                    .ok()?;
                let n: i64 = c
                    .query_row("select count(*) from chunk_vec", [], |r| r.get(0))
                    .ok()?;
                (n > 0).then_some((fp, n))
            })
            .collect();
        out.sort();
        out
    }

    /// `(kind, key)` of every vector in the state's caches (0 a chunk's, 1 a path's).
    fn written(&self) -> std::collections::HashSet<(i64, Vec<u8>)> {
        let mut out = std::collections::HashSet::new();
        for f in cache_files(self._state.path()) {
            let c = rusqlite::Connection::open_with_flags(
                &f,
                rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
            )
            .unwrap();
            for (kind, table) in [(0, "chunk_vec"), (1, "path_vec")] {
                let mut st = c.prepare(&format!("select key from {table}")).unwrap();
                let keys = st
                    .query_map([], |r| r.get::<_, Vec<u8>>(0))
                    .unwrap()
                    .collect::<Result<Vec<_>, _>>()
                    .unwrap();
                out.extend(keys.into_iter().map(|k| (kind, k)));
            }
        }
        out
    }

    /// The distinct keys of embeddable chunks.
    async fn live_keys(&self) -> i64 {
        self.project
            .store()
            .handle()
            .read(|c| {
                Ok(c.query_row(
                    "select count(distinct key) from chunk where embed = 1",
                    [],
                    |r| r.get(0),
                )?)
            })
            .await
            .unwrap()
    }

    async fn wait_for_rows(
        &self,
        what: &str,
        f: impl Fn(&[(String, i64)]) -> bool,
    ) -> Vec<(String, i64)> {
        let f = &f;
        skuld::wait_until_async(what, 30, || async move {
            let seen = self.vec_models().await;
            f(&seen).then_some(seen)
        })
        .await
    }
}

/// Pattern C. A server swapped for another model under the same URL is a new fingerprint: the next tier-2 batch writes
/// under the new hex, and the rows under the old hex stay.
#[test]
fn swapped_server_model_is_a_new_fingerprint_and_old_vectors_stay() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let dir = TempDir::new().unwrap();
        let server = Server::start(dir.path());
        server.set_model("model-a");
        let g = gate(
            dir.path(),
            json!([tei(&format!("http://127.0.0.1:{}", server.port))]),
        )
        .await;
        let e = Arc::new(g.embedders(&[]).unwrap().remove(0));
        let f = project(vec![e.clone() as Arc<dyn DocEmbedder>]).await;
        f.project.start_tier2();
        let keys_a = f.live_keys().await;
        let a = f
            .wait_for_rows("the rows of model a", |r| {
                r.iter().map(|(_, n)| n).sum::<i64>() == keys_a
            })
            .await;
        let (hex_a, id_a) = (a[0].0.clone(), e.identity().expect("it has probed"));
        assert_eq!((a.len(), hex_a.as_str()), (1, id_a.fp.hex().as_str()));
        assert_eq!(id_a.record.model_id, "model-a");

        // the same URL now serves another model; a new file wakes tier 2
        server.set_model("model-b");
        add_files(&f.root, 2, "two");
        f.project.refresh_now().await.unwrap();
        let keys_b = f.live_keys().await;
        let b = f
            .wait_for_rows("the rows of model b", |r| {
                r.iter()
                    .filter(|(m, _)| *m != hex_a)
                    .map(|(_, n)| n)
                    .sum::<i64>()
                    == keys_b
            })
            .await;
        assert_eq!(b.len(), 2, "{b:?}");
        assert_eq!(
            b.iter().find(|(m, _)| *m == hex_a).map(|(_, n)| *n),
            Some(keys_a),
            "the old model's rows stay: {b:?}"
        );
        let id_b = e.identity().unwrap();
        assert_ne!(id_b.fp, id_a.fp);
        assert_eq!(id_b.record.model_id, "model-b");
    })
}

/// Pattern C (Hrafn redesign Review Focus 1). Every text tier 2 sends is the text its key was made of: for each text
/// the server received, sha256 over its version and the text (a chunk's, or a path's) is a key tier 2 wrote, and every
/// key written is one of a received text.
#[test]
fn sent_text_hashes_to_its_key() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let dir = TempDir::new().unwrap();
        let server = Server::start(dir.path());
        server.set_model("model-a");
        let g = gate(
            dir.path(),
            json!([tei(&format!("http://127.0.0.1:{}", server.port))]),
        )
        .await;
        let e = Arc::new(g.embedders(&[]).unwrap().remove(0));
        let f = project(vec![e.clone() as Arc<dyn DocEmbedder>]).await;
        f.project.start_tier2();
        let chunks = f.live_keys().await;
        f.wait_for_rows("the chunk rows", |r| {
            r.iter().map(|(_, n)| n).sum::<i64>() == chunks
        })
        .await;
        let id = e.identity().expect("it has probed");
        let store = f.project.store();
        let cache = f.project.cache(&id).await.unwrap();
        skuld::wait_until_async("tier 2 embedding every key", 30, || async {
            hrafn::missing(store, &cache, 1)
                .await
                .unwrap()
                .is_empty()
                .then_some(())
        })
        .await;
        let written = f.written();
        assert!(
            written.iter().any(|(k, _)| *k == 1),
            "the files' path keys too: {written:?}"
        );
        let mut received = std::collections::HashSet::new();
        for (_, body) in server.embeds() {
            for t in body["inputs"].as_array().expect("TEI's inputs") {
                let t = t.as_str().unwrap();
                let chunk = (0, hrafn::KeyKind::Chunk.key(t).to_vec());
                let path = (1, hrafn::KeyKind::Path.key(t).to_vec());
                let key = if written.contains(&chunk) {
                    chunk
                } else {
                    path
                };
                assert!(
                    written.contains(&key),
                    "a sent text whose key was not written: {t:?}"
                );
                received.insert(key);
            }
        }
        assert_eq!(received, written, "every key written is a sent text's");
    })
}

/// Pattern C. A server whose vectors are not as long as its probe said is refused on write: tier 2 fails naming the
/// dims, and nothing of the batch is stored.
#[test]
fn wrong_dims_are_refused_on_write() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let dir = TempDir::new().unwrap();
        let server = Server::start(dir.path());
        server.set_model("model-a 8 5"); // the probe sees 8, every other text gets 5
        let g = gate(
            dir.path(),
            json!([tei(&format!("http://127.0.0.1:{}", server.port))]),
        )
        .await;
        let e = Arc::new(g.embedders(&[]).unwrap().remove(0));
        let f = project(vec![e as Arc<dyn DocEmbedder>]).await;
        f.project.start_tier2();
        let mut rx = f.project.status();
        let why = tokio::time::timeout(
            std::time::Duration::from_secs(60),
            rx.wait_for(|s| matches!(s.tier2, Tier2::Failed(_))),
        )
        .await
        .expect("tier 2 never failed")
        .unwrap()
        .tier2
        .clone();
        let Tier2::Failed(why) = why else {
            unreachable!()
        };
        assert!(
            why.contains("5 dims") && why.contains("the fingerprint says 8"),
            "{why}"
        );
        assert_eq!(
            f.vec_models().await,
            vec![],
            "nothing of the batch was written"
        );
    })
}

/// Pattern C. Every Ollama request that embeds sets `truncate: false` and `options.num_ctx` to the record's token limit.
#[test]
fn ollama_requests_set_truncate_false_and_num_ctx() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let dir = TempDir::new().unwrap();
        let server = Server::start(dir.path());
        server.set_model("qwen3-embedding:0.6b");
        let g = gate(
            dir.path(),
            json!([ollama(&format!("http://127.0.0.1:{}", server.port))]),
        )
        .await;
        let chain = [ChainStep {
            provider: "ollama".into(),
            model: Some("qwen3-embedding:0.6b".into()),
        }];
        let e = g.embedders(&chain).unwrap().remove(0);
        let id = e.probe().await.unwrap();
        assert_eq!(id.record.max_tokens, 4096, "the mock's context length");
        e.embed(&["(defun f ())".to_string()]).await.unwrap();
        let embeds: Vec<_> = server
            .requests()
            .into_iter()
            .filter(|(p, _)| p == "/api/embed")
            .collect();
        assert!(embeds.len() >= 2, "the probe's and the text's: {embeds:?}");
        for (_, body) in &embeds {
            assert_eq!(body["truncate"], json!(false), "{body}");
        }
        // the probe does not know the model's limit yet (the default context); every request after it sets the record's
        let (probe, text): (Vec<_>, Vec<_>) = embeds
            .iter()
            .partition(|(_, b)| b["input"] == json!(["drgnx fingerprint probe"]));
        assert_eq!(probe[0].1["options"]["num_ctx"], json!(8192));
        assert_eq!(
            text[0].1["options"]["num_ctx"],
            json!(4096),
            "{:?}",
            text[0]
        );
    })
}

/// Pattern C. No `vec.model` is a label (`tei:..`, `ollama:..`): each is a fingerprint of 64 hex characters, whether a
/// server or the built-in model wrote it.
#[test]
fn no_label_reaches_the_store() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let dir = TempDir::new().unwrap();
        let server = Server::start(dir.path());
        let g = gate(
            dir.path(),
            json!([tei(&format!("http://127.0.0.1:{}", server.port))]),
        )
        .await;
        let e = Arc::new(g.embedders(&[]).unwrap().remove(0));
        let f = project(vec![e.clone() as Arc<dyn DocEmbedder>]).await;
        f.project.start_tier2();
        let keys = f.live_keys().await;
        let rows = f
            .wait_for_rows("the server's rows", |r| {
                r.iter().map(|(_, n)| n).sum::<i64>() == keys
            })
            .await;
        assert!(!rows.is_empty());
        for (model, _) in &rows {
            assert!(Fingerprint::parse(model).is_some(), "{model}");
            assert!(
                !model.starts_with("tei:") && !model.starts_with("ollama:"),
                "{model}"
            );
        }
        assert_eq!(rows[0].0, e.identity().unwrap().fp.hex());
    })
}
