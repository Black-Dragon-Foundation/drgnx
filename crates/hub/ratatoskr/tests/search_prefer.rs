//! Servers as embedders over the built-in floor (`search::prefer`, `Gate::embedders`, `embed::ProviderEmbedder`) and the
//! entity embedder over them. The servers (TEI, Ollama) are `ratatoskr-mock embed`, the stand-in for what is outside
//! drgnx; the gateway and the built-in model are real (the model from the read-only volume `DRGNX_TEST_MODELS`, on the
//! CPU path).
//!
//! test-pattern: pure (D) for `prefer`; handshake (C) for the rest: the mock prints its port, a request is answered
//! when the call returns, and what the mock saw is read from its log after that.
#![cfg(feature = "test-hooks")]

use hrafn::Lag;
use hrafn_embed::default_model;
use hrafn_embed::fingerprint::Fingerprint;
use norn::deny::DenyList;
use norn::store::CoordDb;
use ratatoskr::dispatch::Caller;
use ratatoskr::embed::{self, Outcome};
use ratatoskr::gateway::Gate;
use ratatoskr::proc::{Command, Io};
use ratatoskr::search::worker::{WorkerEmbedder, WorkerSpec};
use ratatoskr::search::{DocEmbedder, builtin_identity, prefer};
use ratatoskr::settings::providers::ChainStep;
use runstav::methods::gateway::{ProviderConfig, SpendParams};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::Child;
use tempfile::TempDir;
use urdr::graph::search::Embedder;

const BUILTIN: &str = "granite-embedding-small-english-r2";
const TASK: &str = "Given a question about code, retrieve the code that answers it";

fn mock_bin() -> PathBuf {
    let bin = skuld::workspace_bin("ratatoskr-mock", None, Some("RATATOSKR_MOCK"));
    assert!(
        bin.exists(),
        "{} is missing: build it first (cargo build -p domr --bin ratatoskr-mock) or name it in RATATOSKR_MOCK",
        bin.display()
    );
    bin
}

/// `ratatoskr-mock embed`: TEI's `/embed` and Ollama's `/api/embed` on 127.0.0.1, logging every request.
pub(crate) struct Server {
    child: Child,
    pub(crate) port: u16,
    log: PathBuf,
    /// `--model-file`: the model the server stands in for; rewriting it swaps the model under the same URL.
    pub(crate) model_file: PathBuf,
}

impl Drop for Server {
    fn drop(&mut self) {
        ratatoskr::soft::done(self.child.kill(), "search_prefer");
        ratatoskr::soft::done(self.child.wait(), "search_prefer");
    }
}

impl Server {
    pub(crate) fn start(dir: &Path) -> Server {
        let log = dir.join("embed.log");
        let model_file = dir.join("model.txt");
        ratatoskr::fsio::write(&model_file, "mock/embed-1\n").unwrap();
        let mut child = Command::new(mock_bin())
            .args(["embed", "--dims", "8", "--log"])
            .arg(&log)
            .arg("--model-file")
            .arg(&model_file)
            .arg("--parent")
            .arg(std::process::id().to_string())
            .spawn(Io::Inherit, Io::Pipe, Io::Inherit)
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let port = line
            .trim()
            .strip_prefix("MOCK-EMBED-PORT ")
            .unwrap()
            .parse()
            .unwrap();
        Server {
            child,
            port,
            log,
            model_file,
        }
    }

    /// Swaps the model the server stands in for (`MODEL [DIMS [EMBED_DIMS]]`).
    pub(crate) fn set_model(&self, line: &str) {
        ratatoskr::fsio::write(&self.model_file, format!("{line}\n")).unwrap();
    }

    /// The embedding requests that are not the hub's probe: what the hub sent to be embedded.
    pub(crate) fn embeds(&self) -> Vec<(String, Value)> {
        self.requests()
            .into_iter()
            .filter(|(p, b)| {
                p.contains("embed")
                    && b["inputs"] != json!(["drgnx fingerprint probe"])
                    && b["input"] != json!(["drgnx fingerprint probe"])
            })
            .collect()
    }

    /// What reached the server: `(path, body)`, in order.
    pub(crate) fn requests(&self) -> Vec<(String, Value)> {
        ratatoskr::fsio::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter_map(|v| v.get("request").cloned())
            .map(|r| {
                (
                    r["path"].as_str().unwrap().to_owned(),
                    // a GET (the probe's `/info`, `/api/tags`) has no body
                    serde_json::from_str(r["body"].as_str().unwrap()).unwrap_or(Value::Null),
                )
            })
            .collect()
    }
}

/// A port nobody listens on.
fn dead_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// A gateway listening, with these providers.
pub(crate) async fn gate(dir: &Path, providers: Value) -> Gate {
    let gate = Gate::new(CoordDb::spawn(dir.join("gw.db")));
    let table: Vec<ProviderConfig> = serde_json::from_value(providers).unwrap();
    gate.apply(&table).unwrap();
    gate.listen(None).await.unwrap();
    gate
}

pub(crate) fn tei(base: &str) -> Value {
    json!({"id": "tei", "kind": "tei", "base": base, "auth": "none", "messages": false, "caps": ["embed"]})
}

pub(crate) fn ollama(base: &str) -> Value {
    json!({"id": "ollama", "kind": "ollama", "base": base, "auth": "none", "messages": false, "caps": ["embed"]})
}

/// The built-in model's fingerprint, and a server's (any other).
fn builtin_fp() -> Fingerprint {
    builtin_identity(default_model()).fp
}

const SERVER_FP: Fingerprint = Fingerprint([7; 32]);

fn lag(fp: &Fingerprint, total: u32, behind: u32) -> Lag {
    Lag {
        model: Some(fp.hex()),
        chunks_total: total,
        chunks_behind: behind,
        ..Lag::default()
    }
}

/// Pattern D. A server that does not answer is passed over: the query uses the built-in model, which says so.
#[test]
fn server_down_falls_back_to_builtin() {
    let b = builtin_fp();
    let builtin = lag(&b, 100, 0);
    let servers = [(SERVER_FP, lag(&SERVER_FP, 100, 0), false)];
    assert_eq!(prefer(Some((&b, &builtin)), &servers), Some(b));
}

/// Pattern D. A server that answers but holds fewer than 95 % of the live chunks does not qualify; at 95 % it does.
#[test]
fn server_partial_coverage_uses_builtin() {
    let b = builtin_fp();
    let builtin = lag(&b, 100, 0);
    let partial = [(SERVER_FP, lag(&SERVER_FP, 100, 6), true)];
    assert_eq!(prefer(Some((&b, &builtin)), &partial), Some(b));
    let enough = [(SERVER_FP, lag(&SERVER_FP, 100, 5), true)];
    assert_eq!(prefer(Some((&b, &builtin)), &enough), Some(SERVER_FP));
    // nothing indexed yet: nothing is behind
    let empty = [(SERVER_FP, lag(&SERVER_FP, 0, 0), true)];
    assert_eq!(prefer(Some((&b, &builtin)), &empty), Some(SERVER_FP));
}

/// Pattern D (Hrafn redesign Task 15). A query uses the main fingerprint once it covers 95 % of the chunks, and the
/// built-in one until then, whichever of them is filling: the first of several main fingerprints that qualifies wins.
#[test]
fn query_uses_main_at_95_percent_else_builtin() {
    let b = builtin_fp();
    let builtin = lag(&b, 200, 0);
    let (other, third) = (Fingerprint([8; 32]), Fingerprint([9; 32]));
    let at = |behind: u32| [(SERVER_FP, lag(&SERVER_FP, 200, behind), true)];
    assert_eq!(prefer(Some((&b, &builtin)), &at(11)), Some(b), "94.5 %");
    assert_eq!(
        prefer(Some((&b, &builtin)), &at(10)),
        Some(SERVER_FP),
        "95 %"
    );
    let two = [
        (other, lag(&other, 200, 40), true),
        (third, lag(&third, 200, 4), true),
    ];
    assert_eq!(prefer(Some((&b, &builtin)), &two), Some(third));
}

/// Pattern D. With the built-in model off (`drgnx-search-builtin` nil) or not downloaded, an answering server is used
/// whatever it covers, and with none answering there is no vector model.
#[test]
fn builtin_off_server_only() {
    let partial = [(SERVER_FP, lag(&SERVER_FP, 100, 60), true)];
    assert_eq!(prefer(None, &partial), Some(SERVER_FP));
    let down = [(SERVER_FP, lag(&SERVER_FP, 100, 0), false)];
    assert_eq!(prefer(None, &down), None);
    assert_eq!(prefer(None, &[]), None);
}

/// Pattern C. A server's query carries the instruction its scope chose (`Instruct: TASK\nQuery:Q`); documents go plain.
#[test]
fn server_query_carries_the_instruction() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let dir = TempDir::new().unwrap();
        let server = Server::start(dir.path());
        let g = gate(
            dir.path(),
            json!([tei(&format!("http://127.0.0.1:{}", server.port))]),
        )
        .await;
        let e = g.embedders(&[]).unwrap().remove(0);
        let id = e.probe().await.unwrap();
        assert_eq!(
            Embedder::model(&e),
            id.fp.hex(),
            "the model is the fingerprint"
        );
        let q = e
            .embed_query("where is the timer set", Some(TASK))
            .await
            .unwrap();
        assert_eq!(q.len(), 8);
        e.embed(&["(defun f ())".to_string()]).await.unwrap();
        let seen = server.embeds();
        assert_eq!(seen[0].0, "/embed");
        assert_eq!(
            seen[0].1["inputs"],
            json!([format!("Instruct: {TASK}\nQuery:where is the timer set")])
        );
        assert_eq!(seen[1].1["inputs"], json!(["(defun f ())"]));
    })
}

/// Pattern C. An Ollama provider embeds through the gateway (`/api/embed`, the model of the embed role's step), and
/// the request is counted in `spend` like any other.
#[test]
fn ollama_embed_through_gateway_counts_spend() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let dir = TempDir::new().unwrap();
        let server = Server::start(dir.path());
        let g = gate(
            dir.path(),
            json!([ollama(&format!("http://127.0.0.1:{}", server.port))]),
        )
        .await;
        // an Ollama provider with no model named by the embed role cannot embed
        assert!(g.embedders(&[]).unwrap().is_empty());
        let chain = [ChainStep {
            provider: "ollama".into(),
            model: Some("qwen3-embedding:0.6b".into()),
        }];
        let e = g.embedders(&chain).unwrap().remove(0);
        server.set_model("qwen3-embedding:0.6b");
        let id = e.probe().await.unwrap();
        assert_eq!(
            Embedder::model(&e),
            id.fp.hex(),
            "the model is the fingerprint"
        );
        let texts = vec!["alpha beta".to_string(), "gamma".to_string()];
        let got = e.embed(&texts).await.unwrap();
        assert_eq!((got.len(), got[0].len()), (2, 8));
        let seen = server.embeds();
        assert_eq!(seen[0].0, "/api/embed");
        assert_eq!(seen[0].1["model"], "qwen3-embedding:0.6b");
        assert_eq!(seen[0].1["input"], json!(["alpha beta", "gamma"]));
        let params: SpendParams = runstav::decode::typed(&json!({})).unwrap().0;
        let caller = Caller {
            class: runstav::registry::Class::User,
            sid: None,
            job: None,
            conn_id: 1,
        };
        // the probe's embed ("drgnx fingerprint probe", 3 words) and the texts' 3 words, all through the gateway
        let spent = skuld::wait_until_async("the requests are in spend", 30, || async {
            let s = g.spend(&caller, params.clone()).await.unwrap();
            (s.input >= 6).then_some(s)
        })
        .await;
        assert_eq!(spent.input, 6, "{spent:?}");
        assert!(spent.requests >= 2, "{spent:?}");
    })
}

/// Pattern C. An endpoint named `localhost` reaches a server that listens on 127.0.0.1 only, and the doctor's probe
/// says which address family answered.
#[test]
fn localhost_resolves_to_127() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let dir = TempDir::new().unwrap();
        let server = Server::start(dir.path());
        let base = format!("http://localhost:{}", server.port);
        let g = gate(dir.path(), json!([tei(&base)])).await;
        let e = g.embedders(&[]).unwrap().remove(0);
        e.probe().await.unwrap();
        assert_eq!(e.embed(&["x".to_string()]).await.unwrap().len(), 1);
        assert_eq!(embed::answered_family(&base).await, Some("ipv4"));
        assert_eq!(
            embed::answered_family(&format!("http://127.0.0.1:{}", dead_port())).await,
            None
        );
    })
}

fn model_dir() -> PathBuf {
    PathBuf::from(
        std::env::var("DRGNX_TEST_MODELS").expect("DRGNX_TEST_MODELS names the model volume"),
    )
    .join(BUILTIN)
}

/// The built-in model's worker, on the CPU path.
fn builtin(dir: &Path) -> WorkerEmbedder {
    let power = dir.join("power");
    std::fs::create_dir_all(&power).unwrap();
    WorkerEmbedder::new(WorkerSpec {
        exe: PathBuf::from(env!("CARGO_BIN_EXE_ratatoskr")),
        model: BUILTIN.into(),
        dir: model_dir(),
        device_cache: dir.join("device.json"),
        threads: 2,
        idle_ms: None,
        power_root: power,
        test_args: vec!["--device".into(), "cpu".into()],
    })
}

async fn put(db: &CoordDb, id: &str, title: &str) {
    let (id, title) = (id.to_owned(), title.to_owned());
    db.write(
        urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "gateway"),
        move |tx| {
            urdr::graph::entity::create(
                tx,
                urdr::graph::entity::EntityNew {
                    id,
                    kind: "task".into(),
                    project: None,
                    title: Some(title),
                    status: None,
                    body: None,
                    priority: None,
                    assignee: None,
                    data: json!({}),
                    origin: urdr::graph::entity::Origin::Recorded,
                    source: None,
                },
            )?;
            Ok(())
        },
    )
    .await
    .unwrap();
}

async fn models_of_vectors(db: &CoordDb) -> Vec<(String, i64)> {
    db.read(|c| {
        let mut st = c.prepare("select model, count(*) from entity_vec group by model")?;
        let rows = st
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    })
    .await
    .unwrap()
}

/// Pattern C. On a fresh install, with no server, tasks and notes get vectors from the built-in model; with a server
/// that does not answer first in line, its batch goes to the built-in model, which fills them, and the server backs off.
#[test]
fn entity_vectors_fill_with_builtin() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let dir = TempDir::new().unwrap();
        let g = gate(
            dir.path(),
            json!([tei(&format!("http://127.0.0.1:{}", dead_port()))]),
        )
        .await;
        let down = g.embedders(&[]).unwrap().remove(0);
        let own = builtin(dir.path());
        let db = CoordDb::spawn(dir.path().join("work.db"));
        for (id, title) in [("task:a", "fix the timer"), ("task:b", "write the docs")] {
            put(&db, id, title).await;
        }
        let deny = DenyList::load(&dir.path().join("home"), &dir.path().join("config"));
        let mut chain = embed::Chain::default();
        let (now, mut changes) = (tokio::time::Instant::from_std(skuld::origin()), Vec::new());
        let out = embed::run(&db, &[&down, &own], &deny, &mut chain, now, &mut changes).await;
        assert_eq!(
            out,
            Outcome::Filled {
                embedded: 2,
                denied: 0
            }
        );
        assert_eq!(models_of_vectors(&db).await, vec![(builtin_fp().hex(), 2)]);
        assert!(
            matches!(changes.as_slice(), [embed::Change::Down { .. }]),
            "{changes:?}"
        );
        // a second round has nothing to do, and the server is not asked while it backs off
        assert_eq!(
            embed::run(&db, &[&down, &own], &deny, &mut chain, now, &mut changes).await,
            Outcome::Nothing
        );
        assert_eq!(changes.len(), 1);
    })
}

/// Pattern C (Hrafn redesign Task 5). A server's round writes its entities' vectors under the fingerprint it proved
/// (64 hex), never a label (`tei:tei`).
#[test]
fn entity_round_writes_fingerprint_hex() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let dir = TempDir::new().unwrap();
        let server = Server::start(dir.path());
        server.set_model("model-a");
        let g = gate(
            dir.path(),
            json!([tei(&format!("http://127.0.0.1:{}", server.port))]),
        )
        .await;
        let e = g.embedders(&[]).unwrap().remove(0);
        let id = e.probe().await.unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        for (id, title) in [("task:a", "fix the timer"), ("task:b", "write the docs")] {
            put(&db, id, title).await;
        }
        let deny = DenyList::load(&dir.path().join("home"), &dir.path().join("config"));
        let mut chain = embed::Chain::default();
        let (now, mut changes) = (tokio::time::Instant::from_std(skuld::origin()), Vec::new());
        let out = embed::run(&db, &[&e], &deny, &mut chain, now, &mut changes).await;
        assert_eq!(
            out,
            Outcome::Filled {
                embedded: 2,
                denied: 0
            }
        );
        assert_eq!(models_of_vectors(&db).await, vec![(id.fp.hex(), 2)]);
    })
}
