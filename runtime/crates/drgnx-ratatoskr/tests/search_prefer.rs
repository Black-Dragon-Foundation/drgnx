//! Servers as embedders over the built-in floor (`search::prefer`, `Gate::embedders`, `embed::ProviderEmbedder`) and the
//! entity embedder over them. The servers (TEI, Ollama) are `ratatoskr-mock embed`, the stand-in for what is outside
//! drgnx; the gateway and the built-in model are real (the model from the read-only volume `DRGNX_TEST_MODELS`, on the
//! CPU path).
//!
//! test-pattern: pure (D) for `prefer`; handshake (C) for the rest: the mock prints its port, a request is answered
//! when the call returns, and what the mock saw is read from its log after that.
#![cfg(feature = "test-hooks")]

use drgnx_ratatoskr::dispatch::Caller;
use drgnx_ratatoskr::embed::{self, Outcome};
use drgnx_ratatoskr::gateway::Gate;
use drgnx_ratatoskr::search::prefer;
use drgnx_ratatoskr::search::worker::{WorkerEmbedder, WorkerSpec};
use drgnx_ratatoskr::settings::providers::ChainStep;
use hrafn::Lag;
use norn::deny::DenyList;
use norn::store::CoordDb;
use runstav::methods::gateway::{ProviderConfig, SpendParams};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use tempfile::TempDir;
use urdr::graph::search::Embedder;

const BUILTIN: &str = "granite-embedding-small-english-r2";
const TASK: &str = "Given a question about code, retrieve the code that answers it";

fn mock_bin() -> PathBuf {
    if let Some(path) = std::env::var_os("RATATOSKR_MOCK") {
        return path.into();
    }
    let exe = std::env::current_exe().unwrap();
    let bin = exe
        .parent()
        .and_then(Path::parent)
        .unwrap()
        .join("ratatoskr-mock");
    assert!(
        bin.exists(),
        "{} is missing: build it first (cargo build -p domr --bin ratatoskr-mock) or name it in RATATOSKR_MOCK",
        bin.display()
    );
    bin
}

/// `ratatoskr-mock embed`: TEI's `/embed` and Ollama's `/api/embed` on 127.0.0.1, logging every request.
struct Server {
    child: Child,
    port: u16,
    log: PathBuf,
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Server {
    fn start(dir: &Path) -> Server {
        let log = dir.join("embed.log");
        let mut child = Command::new(mock_bin())
            .args(["embed", "--dims", "8", "--log"])
            .arg(&log)
            .arg("--parent")
            .arg(std::process::id().to_string())
            .stdout(Stdio::piped())
            .spawn()
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
        Server { child, port, log }
    }

    /// What reached the server: `(path, body)`, in order.
    fn requests(&self) -> Vec<(String, Value)> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter_map(|v| v.get("request").cloned())
            .map(|r| {
                (
                    r["path"].as_str().unwrap().to_owned(),
                    serde_json::from_str(r["body"].as_str().unwrap()).unwrap(),
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
async fn gate(dir: &Path, providers: Value) -> Gate {
    let gate = Gate::new(CoordDb::spawn(dir.join("gw.db")));
    let table: Vec<ProviderConfig> = serde_json::from_value(providers).unwrap();
    gate.apply(&table).unwrap();
    gate.listen(None).await.unwrap();
    gate
}

fn tei(base: &str) -> Value {
    json!({"id": "tei", "kind": "tei", "base": base, "auth": "none", "messages": false, "caps": ["embed"]})
}

fn ollama(base: &str) -> Value {
    json!({"id": "ollama", "kind": "ollama", "base": base, "auth": "none", "messages": false, "caps": ["embed"]})
}

fn lag(model: &str, total: u32, behind: u32) -> Lag {
    Lag {
        model: Some(model.into()),
        chunks_total: total,
        chunks_behind: behind,
        ..Lag::default()
    }
}

/// Pattern D. A server that does not answer is passed over: the query uses the built-in model, which says so.
#[test]
fn server_down_falls_back_to_builtin() {
    let builtin = lag(BUILTIN, 100, 0);
    let servers = [("tei:tei".to_string(), lag("tei:tei", 100, 0), false)];
    assert_eq!(prefer(Some(&builtin), &servers).as_deref(), Some(BUILTIN));
}

/// Pattern D. A server that answers but holds fewer than 95 % of the live chunks does not qualify; at 95 % it does.
#[test]
fn server_partial_coverage_uses_builtin() {
    let builtin = lag(BUILTIN, 100, 0);
    let partial = [("tei:tei".to_string(), lag("tei:tei", 100, 6), true)];
    assert_eq!(prefer(Some(&builtin), &partial).as_deref(), Some(BUILTIN));
    let enough = [("tei:tei".to_string(), lag("tei:tei", 100, 5), true)];
    assert_eq!(prefer(Some(&builtin), &enough).as_deref(), Some("tei:tei"));
    // nothing indexed yet: nothing is behind
    let empty = [("tei:tei".to_string(), lag("tei:tei", 0, 0), true)];
    assert_eq!(prefer(Some(&builtin), &empty).as_deref(), Some("tei:tei"));
}

/// Pattern D. With the built-in model off (`drgnx-search-builtin` nil) or not downloaded, an answering server is used
/// whatever it covers, and with none answering there is no vector model.
#[test]
fn builtin_off_server_only() {
    let partial = [("tei:tei".to_string(), lag("tei:tei", 100, 60), true)];
    assert_eq!(prefer(None, &partial).as_deref(), Some("tei:tei"));
    let down = [("tei:tei".to_string(), lag("tei:tei", 100, 0), false)];
    assert_eq!(prefer(None, &down), None);
    assert_eq!(prefer(None, &[]), None);
}

/// Pattern C. A server's query carries the instruction its scope chose (`Instruct: TASK\nQuery:Q`); documents go plain.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_query_carries_the_instruction() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(dir.path());
    let g = gate(
        dir.path(),
        json!([tei(&format!("http://127.0.0.1:{}", server.port))]),
    )
    .await;
    let e = g.embedders(&[]).unwrap().remove(0);
    assert_eq!(e.model(), "tei:tei");
    let q = e
        .embed_query("where is the timer set", Some(TASK))
        .await
        .unwrap();
    assert_eq!(q.len(), 8);
    e.embed(&["(defun f ())".to_string()]).await.unwrap();
    let seen = server.requests();
    assert_eq!(seen[0].0, "/embed");
    assert_eq!(
        seen[0].1["inputs"],
        json!([format!("Instruct: {TASK}\nQuery:where is the timer set")])
    );
    assert_eq!(seen[1].1["inputs"], json!(["(defun f ())"]));
}

/// Pattern C. An Ollama provider embeds through the gateway (`/api/embed`, the model of the embed role's step), and
/// the request is counted in `spend` like any other.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ollama_embed_through_gateway_counts_spend() {
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
    assert_eq!(e.model(), "ollama:ollama:qwen3-embedding:0.6b");
    let texts = vec!["alpha beta".to_string(), "gamma".to_string()];
    let got = e.embed(&texts).await.unwrap();
    assert_eq!((got.len(), got[0].len()), (2, 8));
    let seen = server.requests();
    assert_eq!(seen[0].0, "/api/embed");
    assert_eq!(
        seen[0].1,
        json!({"model": "qwen3-embedding:0.6b", "input": ["alpha beta", "gamma"]})
    );
    let params: SpendParams = runstav::decode::typed(&json!({})).unwrap().0;
    let caller = Caller {
        class: runstav::registry::Class::User,
        sid: None,
        job: None,
        conn_id: 1,
    };
    let spent = skuld::wait_until_async("the request is in spend", 30, || async {
        let s = g.spend(&caller, params.clone()).await.unwrap();
        (s.requests > 0).then_some(s)
    })
    .await;
    assert_eq!((spent.requests, spent.input), (1, 3), "{spent:?}");
}

/// Pattern C. An endpoint named `localhost` reaches a server that listens on 127.0.0.1 only, and the doctor's probe
/// says which address family answered.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn localhost_resolves_to_127() {
    let dir = TempDir::new().unwrap();
    let server = Server::start(dir.path());
    let base = format!("http://localhost:{}", server.port);
    let g = gate(dir.path(), json!([tei(&base)])).await;
    let e = g.embedders(&[]).unwrap().remove(0);
    assert_eq!(e.embed(&["x".to_string()]).await.unwrap().len(), 1);
    assert_eq!(embed::answered_family(&base).await, Some("ipv4"));
    assert_eq!(
        embed::answered_family(&format!("http://127.0.0.1:{}", dead_port())).await,
        None
    );
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
/// that does not answer first in line, the round passes it over and the built-in model fills them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn entity_vectors_fill_with_builtin() {
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
    let out = embed::run(&db, &[&down, &own], &deny, false).await;
    assert_eq!(
        out,
        Outcome::Filled {
            embedded: 2,
            denied: 0
        }
    );
    assert_eq!(models_of_vectors(&db).await, vec![(BUILTIN.to_string(), 2)]);
    // a second round has nothing to do
    assert_eq!(
        embed::run(&db, &[&down, &own], &deny, false).await,
        Outcome::Nothing
    );
}
