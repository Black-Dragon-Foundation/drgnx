//! The forwarding engine and its listeners (Task 20), end to end: a client over TCP or a session socket, the gateway
//! on its listener, and `ratatoskr-mock llm` as the provider (an outside service, so a mock: it is the one domr
//! builds, `runtime/conformance/src/bin/ratatoskr-mock.rs`). The ledger and the registry are in memory.
//!
//! The mock is found at `RATATOSKR_MOCK`, else beside this test's binary (`target/debug/ratatoskr-mock`): build it
//! first (`cargo build -p domr --bin ratatoskr-mock`; a workspace `cargo test` builds it anyway).

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use bifrost::admit::{Registry, token_hash};
use bifrost::budget::Price;
use bifrost::engine::{BoxFuture, Gateway, GatewayEvent, Ledger, SpendRow};
use bifrost::keys::Keys;
use bifrost::listen;
use bifrost::upstream::{Upstream, UpstreamOpts};
use bifrost::{Auth, Caps, Class, Kind, ListenerId, Provider, Registration, Restrictions, Step};
use bytes::Bytes;
use http::header::{AUTHORIZATION, CONTENT_TYPE, HOST, RETRY_AFTER};
use http::{HeaderMap, Request};
use http_body_util::{BodyExt, Full};
use hyper::client::conn::http1 as client;
use hyper_util::client::proxy::matcher::Matcher;
use hyper_util::rt::TokioIo;
use secrecy::SecretString;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UnixListener, UnixStream};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

const AGENT: &str = "agent-token-0123456789abcdef0123456789abcdef0123456789abcdef0123";
const OTHER: &str = "other-token-0123456789abcdef0123456789abcdef0123456789abcdef0123";
const SESSION: &str = "session-token-0123456789abcdef0123456789abcdef0123456789abcdef01";
const EDITOR: &str = "editor-token-0123456789abcdef0123456789abcdef0123456789abcdef012";

// ------------------------------------------------------------------------------------------ the provider

fn mock_bin() -> PathBuf {
    if let Some(path) = std::env::var_os("RATATOSKR_MOCK") {
        return path.into();
    }
    // target/debug/deps/engine-HASH -> target/debug/ratatoskr-mock
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

/// `ratatoskr-mock llm` with `script`, on 127.0.0.1; killed when dropped.
struct Mock {
    child: Child,
    port: u16,
    log: PathBuf,
    _dir: tempfile::TempDir,
}

impl Mock {
    fn start(script: Value) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let script_path = dir.path().join("script.json");
        std::fs::write(&script_path, script.to_string()).unwrap();
        let log = dir.path().join("log.jsonl");
        let mut child = Command::new(mock_bin())
            .arg("llm")
            .arg("--script")
            .arg(&script_path)
            .arg("--log")
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
            .strip_prefix("MOCK-LLM-PORT ")
            .and_then(|p| p.parse().ok())
            .unwrap_or_else(|| panic!("ratatoskr-mock said {line:?}"));
        Self {
            child,
            port,
            log,
            _dir: dir,
        }
    }

    /// The mock's URL with path `prefix` (each provider of a test gets its own).
    fn url(&self, prefix: &str) -> String {
        format!("http://127.0.0.1:{}{prefix}", self.port)
    }

    fn log(&self) -> Vec<Value> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect()
    }

    /// The requests it was sent, in order: `{method, path, headers, body}`.
    fn requests(&self) -> Vec<Value> {
        self.log()
            .into_iter()
            .filter_map(|v| v.get("request").cloned())
            .collect()
    }

    fn paths(&self) -> Vec<String> {
        self.requests()
            .iter()
            .map(|r| r["path"].as_str().unwrap().to_owned())
            .collect()
    }

    fn saw_a_hang_up(&self) -> bool {
        self.log().iter().any(|v| v["closed"] == json!(true))
    }
}

impl Drop for Mock {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A port nothing listens on.
fn dead_url() -> String {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    drop(l);
    format!("http://127.0.0.1:{port}")
}

// ------------------------------------------------------------------------------------------ the gateway

struct Mem(BTreeMap<String, Registration>);

impl Registry for Mem {
    fn find(&self, hash: &str) -> Option<Registration> {
        self.0.get(hash).cloned()
    }
}

/// The spend table: `before` USD spent by every job before the test, plus the rows recorded.
#[derive(Default)]
struct Book {
    before: f64,
    rows: Mutex<Vec<SpendRow>>,
}

impl Book {
    fn rows(&self) -> Vec<SpendRow> {
        self.rows.lock().unwrap().clone()
    }
}

impl Ledger for Book {
    fn spent(&self, job: &str) -> BoxFuture<'_, Result<f64, String>> {
        let total = self.before
            + self
                .rows()
                .iter()
                .filter(|r| r.job.as_deref() == Some(job))
                .map(|r| r.cost)
                .sum::<f64>();
        Box::pin(async move { Ok(total) })
    }

    fn record(&self, row: SpendRow) -> BoxFuture<'_, ()> {
        self.rows.lock().unwrap().push(row);
        Box::pin(async {})
    }
}

fn provider(id: &str, kind: Kind, base: &str, auth: Auth) -> Provider {
    Provider {
        id: id.to_owned(),
        kind,
        base: base.parse().unwrap(),
        auth,
        messages: true,
        caps: Caps::default(),
        price: None,
    }
}

/// An agent of job `j1`, task `t1`, named `a1`, on the loopback listener; each step's model is `P-model`.
fn agent(chain: &[&str], budget: Option<f64>) -> Registration {
    Registration {
        class: Class::Agent,
        job: Some("j1".into()),
        task: Some("t1".into()),
        agent: Some("a1".into()),
        chain: chain
            .iter()
            .map(|p| Step {
                provider: (*p).to_owned(),
                model: Some(format!("{p}-model")),
            })
            .collect(),
        budget,
        openrouter: None,
        listener: ListenerId::Loopback,
    }
}

struct Gw {
    gw: Arc<Gateway>,
    port: u16,
    book: Arc<Book>,
    events: mpsc::UnboundedReceiver<GatewayEvent>,
}

impl Gw {
    async fn start(
        providers: Vec<Provider>,
        registrations: Vec<(&str, Registration)>,
        keys: &[(&str, &str)],
        before: f64,
    ) -> Self {
        let registry = Arc::new(Mem(registrations
            .into_iter()
            .map(|(token, r)| (token_hash(token.as_bytes()), r))
            .collect()));
        let providers = Arc::new(RwLock::new(
            providers.into_iter().map(|p| (p.id.clone(), p)).collect(),
        ));
        let mut held = Keys::new();
        for (id, key) in keys {
            held.set(*id, SecretString::from(key.to_string()));
        }
        let book = Arc::new(Book {
            before,
            ..Book::default()
        });
        let (tx, events) = mpsc::unbounded_channel();
        // an empty matcher: the environment's proxy settings must not matter here
        let upstream =
            Upstream::with_proxy(UpstreamOpts::default(), Matcher::builder().build()).unwrap();
        let gw = Gateway::new(
            registry,
            providers,
            Arc::new(RwLock::new(held)),
            book.clone(),
            tx,
            upstream,
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(listen::serve_tcp(gw.clone(), listener, port));
        Self {
            gw,
            port,
            book,
            events,
        }
    }

    /// The first event `what` takes, within 5 s (the ones before it are dropped).
    async fn until(&mut self, what: impl Fn(&GatewayEvent) -> bool) -> GatewayEvent {
        let events = &mut self.events;
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let e = events.recv().await.expect("the event channel is open");
                if what(&e) {
                    return e;
                }
            }
        })
        .await
        .expect("the event within 5 s")
    }

    /// The events sent so far.
    fn pending(&mut self) -> Vec<GatewayEvent> {
        std::iter::from_fn(|| self.events.try_recv().ok()).collect()
    }

    async fn row(&mut self) -> SpendRow {
        match self.until(|e| matches!(e, GatewayEvent::Request(_))).await {
            GatewayEvent::Request(row) => row,
            _ => unreachable!(),
        }
    }

    fn request(&self, token: &str, path: &str, body: &str) -> Request<Full<Bytes>> {
        Request::post(path)
            .header(HOST, format!("127.0.0.1:{}", self.port))
            .header(AUTHORIZATION, format!("Bearer {token}"))
            .header(CONTENT_TYPE, "application/json")
            .body(Full::new(Bytes::from(body.to_owned())))
            .unwrap()
    }

    /// One request on a new connection, read to its end.
    async fn call(&self, token: &str, path: &str, body: &str) -> Reply {
        let (mut sender, _conn) =
            open(TcpStream::connect(("127.0.0.1", self.port)).await.unwrap()).await;
        read(
            sender
                .send_request(self.request(token, path, body))
                .await
                .unwrap(),
        )
        .await
    }
}

struct Reply {
    status: u16,
    headers: HeaderMap,
    body: String,
}

impl Reply {
    fn json(&self) -> Value {
        serde_json::from_str(&self.body).unwrap_or_else(|_| panic!("not JSON: {}", self.body))
    }
}

async fn open<S>(io: S) -> (client::SendRequest<Full<Bytes>>, JoinHandle<()>)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let (sender, conn) = client::handshake(TokioIo::new(io)).await.unwrap();
    let task = tokio::spawn(async move {
        let _ = conn.await;
    });
    (sender, task)
}

async fn read(response: http::Response<hyper::body::Incoming>) -> Reply {
    let (head, body) = response.into_parts();
    let bytes = body.collect().await.unwrap().to_bytes();
    Reply {
        status: head.status.as_u16(),
        headers: head.headers,
        body: String::from_utf8_lossy(&bytes).into_owned(),
    }
}

fn text(b: &Bytes) -> String {
    String::from_utf8_lossy(b).into_owned()
}

fn fallbacks(events: &[GatewayEvent]) -> Vec<(String, String, String)> {
    events
        .iter()
        .filter_map(|e| match e {
            GatewayEvent::Fallback { from, to, why, .. } => {
                Some((from.clone(), to.clone(), why.clone()))
            }
            _ => None,
        })
        .collect()
}

const MESSAGE_START: &str = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\n\n";
const MESSAGE_DELTA: &str =
    "event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":5}}\n\n";
const MESSAGE_STOP: &str = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";

// ------------------------------------------------------------------------------------------ the agent's chain

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stream_passes_through_and_the_first_chunk_goes_first() {
    let mock = Mock::start(json!([
        {"path": "/a/v1/messages", "chunks": [[0, MESSAGE_START], [1500, MESSAGE_DELTA]]}
    ]));
    let mut gw = Gw::start(
        vec![provider(
            "a",
            Kind::Anthropic,
            &mock.url("/a"),
            Auth::XApiKey,
        )],
        vec![(AGENT, agent(&["a"], None))],
        &[("a", "sk-a")],
        0.0,
    )
    .await;
    let (mut sender, _conn) = open(TcpStream::connect(("127.0.0.1", gw.port)).await.unwrap()).await;
    let sent = Instant::now();
    let response = sender
        .send_request(gw.request(AGENT, "/v1/messages", "{\"stream\":true}"))
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.headers()[CONTENT_TYPE], "text/event-stream");
    let mut body = response.into_body();
    let first = body.frame().await.unwrap().unwrap().into_data().unwrap();
    assert!(
        sent.elapsed() < Duration::from_millis(1200),
        "the first chunk came after {:?}, with the last",
        sent.elapsed()
    );
    assert!(
        text(&first).starts_with("event: message_start"),
        "{first:?}"
    );
    assert!(!text(&first).contains("message_delta"));
    let rest = body.collect().await.unwrap().to_bytes();
    assert_eq!(
        text(&first) + &text(&rest),
        format!("{MESSAGE_START}{MESSAGE_DELTA}")
    );
    let row = gw.row().await;
    assert_eq!((row.input, row.output, row.status), (10, 5, 200));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rate_limit_moves_to_the_next_provider() {
    let mock = Mock::start(json!([
        {"path": "/a/", "status": 429, "body": "{\"error\":\"slow down\"}", "headers": {"Retry-After": "3"}},
        {"path": "/b/", "body": "{\"id\":\"from-b\"}"}
    ]));
    let mut gw = Gw::start(
        vec![
            provider("a", Kind::Anthropic, &mock.url("/a"), Auth::XApiKey),
            provider("b", Kind::Anthropic, &mock.url("/b"), Auth::XApiKey),
        ],
        vec![(AGENT, agent(&["a", "b"], None))],
        &[("a", "sk-a"), ("b", "sk-b")],
        0.0,
    )
    .await;
    let reply = gw.call(AGENT, "/v1/messages", "{\"model\":\"x\"}").await;
    assert_eq!(reply.status, 200);
    assert_eq!(reply.body, "{\"id\":\"from-b\"}");
    assert!(reply.headers.get(RETRY_AFTER).is_none());
    assert_eq!(
        fallbacks(&gw.pending()),
        vec![("a".to_string(), "b".to_string(), "HTTP 429".to_string())]
    );
    assert_eq!(mock.paths(), vec!["/a/v1/messages", "/b/v1/messages"]);
    // each step's own model
    let bodies: Vec<Value> = mock
        .requests()
        .iter()
        .map(|r| serde_json::from_str(r["body"].as_str().unwrap()).unwrap())
        .collect();
    assert_eq!(bodies[0]["model"], "a-model");
    assert_eq!(bodies[1]["model"], "b-model");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_last_provider_429_is_passed_through_with_retry_after() {
    let refusal =
        "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"later\"}}";
    let mock = Mock::start(json!([
        {"path": "/a/", "status": 500, "body": "{}"},
        {"path": "/b/", "status": 429, "body": refusal, "headers": {"Retry-After": "7"}}
    ]));
    let mut gw = Gw::start(
        vec![
            provider("a", Kind::Anthropic, &mock.url("/a"), Auth::XApiKey),
            provider("b", Kind::Anthropic, &mock.url("/b"), Auth::XApiKey),
        ],
        vec![(AGENT, agent(&["a", "b"], None))],
        &[("a", "sk-a"), ("b", "sk-b")],
        0.0,
    )
    .await;
    let reply = gw.call(AGENT, "/v1/messages", "{}").await;
    assert_eq!(reply.status, 429);
    assert_eq!(reply.headers[RETRY_AFTER], "7");
    assert_eq!(reply.headers[CONTENT_TYPE], "application/json");
    assert_eq!(reply.body, refusal);
    // the passed-through refusal is a completed request: one row, with its status. The row may already be sent when
    // the reply is read, so the events are taken in order up to it (the fallback comes first).
    let mut before = Vec::new();
    let row = loop {
        match gw.until(|_| true).await {
            GatewayEvent::Request(row) => break row,
            e => before.push(e),
        }
    };
    assert_eq!(
        fallbacks(&before),
        vec![("a".to_string(), "b".to_string(), "HTTP 500".to_string())]
    );
    assert_eq!((row.provider.as_str(), row.status), ("b", 429));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_dead_or_failing_provider_moves_on_too() {
    let mock = Mock::start(json!([
        {"path": "/f/", "status": 503, "body": "{}"},
        {"path": "/g/", "body": "{\"ok\":true}"}
    ]));
    let mut gw = Gw::start(
        vec![
            provider("dead", Kind::Anthropic, &dead_url(), Auth::None),
            provider("failing", Kind::Anthropic, &mock.url("/f"), Auth::None),
            provider("good", Kind::Anthropic, &mock.url("/g"), Auth::None),
        ],
        vec![(AGENT, agent(&["dead", "failing", "good"], None))],
        &[],
        0.0,
    )
    .await;
    let reply = gw.call(AGENT, "/v1/messages", "{}").await;
    assert_eq!(reply.status, 200);
    assert_eq!(reply.body, "{\"ok\":true}");
    let moves = fallbacks(&gw.pending());
    assert_eq!(moves.len(), 2, "{moves:?}");
    assert_eq!(
        (moves[0].0.as_str(), moves[0].1.as_str()),
        ("dead", "failing")
    );
    assert!(moves[0].2.starts_with("no answer ("), "{moves:?}");
    assert_eq!(
        moves[1],
        (
            "failing".to_string(),
            "good".to_string(),
            "HTTP 503".to_string()
        )
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn when_every_provider_fails_the_agent_hears_why() {
    let mut nomsg = provider("nomsg", Kind::Openai, &dead_url(), Auth::None);
    nomsg.messages = false;
    let mut gw = Gw::start(
        vec![
            nomsg,
            provider("nokey", Kind::Anthropic, &dead_url(), Auth::XApiKey),
            provider("dead", Kind::Anthropic, &dead_url(), Auth::None),
        ],
        vec![(AGENT, agent(&["ghost", "nomsg", "nokey", "dead"], None))],
        &[],
        0.0,
    )
    .await;
    let reply = gw.call(AGENT, "/v1/messages", "{}").await;
    assert_eq!(reply.status, 502);
    let error = reply.json();
    assert_eq!(error["type"], "error");
    assert_eq!(error["error"]["type"], "api_error");
    let message = error["error"]["message"].as_str().unwrap();
    assert!(
        message.starts_with(
            "no provider answered: ghost: not configured; nomsg: the gateway cannot carry it; nokey: no key; dead: no answer ("
        ),
        "{message}"
    );
    let events = gw.pending();
    assert_eq!(
        fallbacks(&events)
            .iter()
            .map(|(from, to, _)| (from.as_str(), to.as_str()))
            .collect::<Vec<_>>(),
        vec![("ghost", "nomsg"), ("nomsg", "nokey"), ("nokey", "dead")]
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        gw.book.rows().is_empty(),
        "no provider answered: no spend row"
    );
    assert!(
        !gw.pending()
            .iter()
            .any(|e| matches!(e, GatewayEvent::Request(_)))
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_fallback_once_the_answer_started() {
    let overloaded =
        "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}\n\n";
    let mock = Mock::start(json!([
        {"path": "/a/", "chunks": [[0, MESSAGE_START], [100, overloaded]], "no_end": true},
        {"path": "/b/", "body": "{\"from\":\"b\"}"}
    ]));
    let mut gw = Gw::start(
        vec![
            provider("a", Kind::Anthropic, &mock.url("/a"), Auth::None),
            provider("b", Kind::Anthropic, &mock.url("/b"), Auth::None),
        ],
        vec![(AGENT, agent(&["a", "b"], None))],
        &[],
        0.0,
    )
    .await;
    let (mut sender, _conn) = open(TcpStream::connect(("127.0.0.1", gw.port)).await.unwrap()).await;
    let response = sender
        .send_request(gw.request(AGENT, "/v1/messages", "{}"))
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    // the answer is a's, however it ends
    let mut seen = Vec::new();
    let mut body = response.into_body();
    while let Some(Ok(frame)) = body.frame().await {
        if let Ok(data) = frame.into_data() {
            seen.extend_from_slice(&data);
        }
    }
    let seen = String::from_utf8_lossy(&seen);
    assert!(seen.starts_with(MESSAGE_START), "{seen}");
    assert!(!seen.contains("from"), "{seen}");
    let row = gw.row().await;
    assert_eq!(row.provider, "a");
    assert!(fallbacks(&gw.pending()).is_empty());
    assert_eq!(mock.paths(), vec!["/a/v1/messages"], "b was never asked");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn spend_is_recorded_once_per_request() {
    let mock = Mock::start(json!([
        {"path": "/a/", "chunks": [[0, MESSAGE_START], [20, MESSAGE_DELTA], [20, MESSAGE_STOP]]}
    ]));
    let mut priced = provider("a", Kind::Anthropic, &mock.url("/a"), Auth::None);
    priced.price = Some(Price {
        input_per_m: 3.0,
        output_per_m: 15.0,
    });
    let mut gw = Gw::start(vec![priced], vec![(AGENT, agent(&["a"], None))], &[], 0.0).await;
    let reply = gw.call(AGENT, "/v1/messages", "{}").await;
    assert_eq!(reply.status, 200);
    assert_eq!(
        reply.body,
        format!("{MESSAGE_START}{MESSAGE_DELTA}{MESSAGE_STOP}")
    );
    let row = gw.row().await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        gw.book.rows(),
        vec![row.clone()],
        "one row for three chunks"
    );
    assert!(
        !gw.pending()
            .iter()
            .any(|e| matches!(e, GatewayEvent::Request(_)))
    );
    assert_eq!(row.job.as_deref(), Some("j1"));
    assert_eq!(row.task.as_deref(), Some("t1"));
    assert_eq!(row.agent.as_deref(), Some("a1"));
    assert_eq!(row.provider, "a");
    assert_eq!(row.model.as_deref(), Some("a-model"));
    assert_eq!((row.input, row.output, row.status), (10, 5, 200));
    assert!(
        (row.cost - (10.0 * 3.0 + 5.0 * 15.0) / 1e6).abs() < 1e-12,
        "{}",
        row.cost
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_skipped_step_records_nothing() {
    let mock = Mock::start(json!([
        {"path": "/a/", "body": "{\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}"}
    ]));
    let mut gw = Gw::start(
        vec![
            provider("nokey", Kind::Anthropic, &mock.url("/n"), Auth::XApiKey),
            provider("a", Kind::Anthropic, &mock.url("/a"), Auth::None),
        ],
        vec![(AGENT, agent(&["nokey", "a"], None))],
        &[],
        0.0,
    )
    .await;
    assert_eq!(gw.call(AGENT, "/v1/messages", "{}").await.status, 200);
    let row = gw.row().await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(gw.book.rows(), vec![row.clone()]);
    assert_eq!((row.provider.as_str(), row.input, row.output), ("a", 4, 2));
    assert_eq!(mock.paths(), vec!["/a/v1/messages"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_budget_stops_new_requests_at_equal() {
    let mock = Mock::start(json!([{"path": "/a/", "body": "{}"}]));
    let mut gw = Gw::start(
        vec![provider("a", Kind::Anthropic, &mock.url("/a"), Auth::None)],
        vec![(AGENT, agent(&["a"], Some(1.0)))],
        &[],
        1.0,
    )
    .await;
    let reply = gw.call(AGENT, "/v1/messages", "{}").await;
    assert_eq!(reply.status, 429);
    let error = reply.json();
    assert_eq!(error["error"]["type"], "budget_exceeded");
    assert_eq!(
        error["error"]["message"],
        "the job's budget (1 USD) is spent"
    );
    assert_eq!(
        gw.pending(),
        vec![GatewayEvent::Budget {
            job: "j1".into(),
            spent: 1.0,
            budget: 1.0
        }]
    );
    assert!(mock.requests().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn budget_event_after_the_crossing_request() {
    let mock = Mock::start(json!([
        {"path": "/a/", "body": "{\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"cost\":0.6}}"}
    ]));
    let mut gw = Gw::start(
        vec![provider("a", Kind::Anthropic, &mock.url("/a"), Auth::None)],
        vec![(AGENT, agent(&["a"], Some(1.0)))],
        &[],
        0.5,
    )
    .await;
    assert_eq!(gw.call(AGENT, "/v1/messages", "{}").await.status, 200);
    let row = gw.row().await;
    assert!((row.cost - 0.6).abs() < 1e-12);
    match gw.until(|e| matches!(e, GatewayEvent::Budget { .. })).await {
        GatewayEvent::Budget { job, spent, budget } => {
            assert_eq!(job, "j1");
            assert!((spent - 1.1).abs() < 1e-9, "{spent}");
            assert_eq!(budget, 1.0);
        }
        _ => unreachable!(),
    }
    assert_eq!(gw.call(AGENT, "/v1/messages", "{}").await.status, 429);
    assert_eq!(mock.requests().len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_hang_up_stops_the_upstream() {
    let mut chunks = vec![json!([0, MESSAGE_START])];
    chunks.extend((0..40).map(|_| json!([100, ": tick\n\n"])));
    let mock = Mock::start(json!([{"path": "/a/", "chunks": chunks}]));
    let mut gw = Gw::start(
        vec![provider("a", Kind::Anthropic, &mock.url("/a"), Auth::None)],
        vec![(AGENT, agent(&["a"], None))],
        &[],
        0.0,
    )
    .await;
    let (mut sender, conn) = open(TcpStream::connect(("127.0.0.1", gw.port)).await.unwrap()).await;
    let response = sender
        .send_request(gw.request(AGENT, "/v1/messages", "{}"))
        .await
        .unwrap();
    let mut body = response.into_body();
    let first = body.frame().await.unwrap().unwrap().into_data().unwrap();
    assert!(text(&first).starts_with("event: message_start"));
    // the agent hangs up
    drop(body);
    drop(sender);
    conn.abort();
    let gone = Instant::now();
    while !mock.saw_a_hang_up() {
        assert!(
            gone.elapsed() < Duration::from_secs(1),
            "the provider still streams 1 s after the agent hung up"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let row = gw.row().await;
    assert_eq!(
        (row.provider.as_str(), row.status, row.input),
        ("a", 200, 10)
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(gw.book.rows().len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_key_sends_need_keys_once_a_minute() {
    let mut gw = Gw::start(
        vec![provider(
            "nokey",
            Kind::Anthropic,
            &dead_url(),
            Auth::Bearer,
        )],
        vec![(AGENT, agent(&["nokey"], None))],
        &[],
        0.0,
    )
    .await;
    assert_eq!(gw.call(AGENT, "/v1/messages", "{}").await.status, 502);
    assert_eq!(gw.call(AGENT, "/v1/messages", "{}").await.status, 502);
    let asked: Vec<_> = gw
        .pending()
        .into_iter()
        .filter(|e| matches!(e, GatewayEvent::NeedKeys { .. }))
        .collect();
    assert_eq!(
        asked,
        vec![GatewayEvent::NeedKeys {
            providers: vec!["nokey".into()]
        }]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_key_never_reaches_the_agent() {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let canary = format!("sk-canary-{}-{nanos:x}", std::process::id());
    let mock = Mock::start(json!([{"path": "/a/", "body": "{\"ok\":true}"}]));
    let gw = Gw::start(
        vec![
            provider("a", Kind::Anthropic, &mock.url("/a"), Auth::Bearer),
            provider("d", Kind::Anthropic, &dead_url(), Auth::XApiKey),
        ],
        vec![(AGENT, agent(&["a"], None)), (OTHER, agent(&["d"], None))],
        &[("a", canary.as_str()), ("d", canary.as_str())],
        0.0,
    )
    .await;
    let answered = gw.call(AGENT, "/v1/messages", "{}").await;
    assert_eq!(answered.status, 200);
    let failed = gw.call(OTHER, "/v1/messages", "{}").await;
    assert_eq!(failed.status, 502);
    for reply in [&answered, &failed] {
        let seen = format!("{:?}{}", reply.headers, reply.body);
        assert!(!seen.contains(&canary), "the key reached the agent: {seen}");
    }
    // the provider got it, as the provider's auth header
    assert_eq!(
        mock.requests()[0]["headers"]["authorization"],
        format!("Bearer {canary}")
    );
}

// ------------------------------------------------------------------------------------------ connections

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn keep_alive_checks_the_token_on_each_request() {
    let mock = Mock::start(json!([{"path": "/a/", "body": "{\"ok\":true}"}]));
    let gw = Gw::start(
        vec![provider("a", Kind::Anthropic, &mock.url("/a"), Auth::None)],
        vec![(AGENT, agent(&["a"], None))],
        &[],
        0.0,
    )
    .await;
    let (mut sender, _conn) = open(TcpStream::connect(("127.0.0.1", gw.port)).await.unwrap()).await;
    let first = read(
        sender
            .send_request(gw.request(AGENT, "/v1/messages", "{}"))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(first.status, 200);
    sender.ready().await.expect("the connection is kept alive");
    let second = read(
        sender
            .send_request(gw.request("not-a-token", "/v1/messages", "{}"))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(second.status, 401);
    assert_eq!(
        second.json()["error"]["message"],
        "not a drgnx gateway token"
    );
    assert_eq!(mock.requests().len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_body_is_drained() {
    let gw = Gw::start(vec![], vec![], &[], 0.0).await;
    let mut s = TcpStream::connect(("127.0.0.1", gw.port)).await.unwrap();
    let n = 60_000;
    let head = format!(
        "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nAuthorization: Bearer not-a-token\r\n\
         Content-Type: application/json\r\nContent-Length: {n}\r\n\r\n",
        gw.port
    );
    s.write_all(head.as_bytes()).await.unwrap();
    s.write_all(&vec![b'x'; n]).await.unwrap();
    let mut answer = Vec::new();
    let read = tokio::time::timeout(Duration::from_secs(5), s.read_to_end(&mut answer))
        .await
        .expect("the gateway closes within 5 s");
    // a close with the body unread would reset the connection under the client
    assert!(read.is_ok(), "{read:?}");
    let answer = String::from_utf8_lossy(&answer);
    assert!(answer.starts_with("HTTP/1.1 401"), "{answer}");
    assert!(answer.contains("not a drgnx gateway token"), "{answer}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_token_is_401_on_tcp() {
    let mock = Mock::start(json!([{"path": "/a/", "body": "{\"ok\":true}"}]));
    let mut session = agent(&["a"], None);
    session.listener = ListenerId::Session("s1".into());
    let gw = Gw::start(
        vec![provider("a", Kind::Anthropic, &mock.url("/a"), Auth::None)],
        vec![(SESSION, session), (AGENT, agent(&["a"], None))],
        &[],
        0.0,
    )
    .await;
    let on_tcp = gw.call(SESSION, "/v1/messages", "{}").await;
    assert_eq!(on_tcp.status, 401);

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sock");
    tokio::spawn(listen::serve_unix(
        gw.gw.clone(),
        UnixListener::bind(&path).unwrap(),
        ListenerId::Session("s1".into()),
    ));
    let on_socket = |token: &'static str| {
        Request::post("/v1/messages")
            .header(HOST, "localhost")
            .header(AUTHORIZATION, format!("Bearer {token}"))
            .body(Full::new(Bytes::from_static(b"{}")))
            .unwrap()
    };
    let (mut sender, _conn) = open(UnixStream::connect(&path).await.unwrap()).await;
    let reply = read(sender.send_request(on_socket(SESSION)).await.unwrap()).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    // and the loopback listener's token is no token on the session's socket
    let (mut sender, _conn) = open(UnixStream::connect(&path).await.unwrap()).await;
    let reply = read(sender.send_request(on_socket(AGENT)).await.unwrap()).await;
    assert_eq!(reply.status, 401);
    assert_eq!(mock.requests().len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_sixty_fifth_connection_is_closed() {
    let gw = Gw::start(vec![], vec![], &[], 0.0).await;
    let mut held = Vec::new();
    for _ in 0..listen::TCP_CONNECTIONS {
        held.push(TcpStream::connect(("127.0.0.1", gw.port)).await.unwrap());
    }
    let mut extra = TcpStream::connect(("127.0.0.1", gw.port)).await.unwrap();
    let mut buf = [0u8; 64];
    let ended = tokio::time::timeout(Duration::from_secs(2), extra.read(&mut buf)).await;
    assert!(
        matches!(ended, Ok(Ok(0) | Err(_))),
        "the 65th connection was not closed: {ended:?}"
    );
    // the 64 are still served
    let head = format!(
        "GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nAuthorization: Bearer not-a-token\r\n\r\n",
        gw.port
    );
    held[0].write_all(head.as_bytes()).await.unwrap();
    let mut answer = Vec::new();
    let _ = tokio::time::timeout(Duration::from_secs(5), held[0].read_to_end(&mut answer)).await;
    assert!(
        String::from_utf8_lossy(&answer).starts_with("HTTP/1.1 401"),
        "{}",
        String::from_utf8_lossy(&answer)
    );
}

// ------------------------------------------------------------------------------------------ the editor's route

/// The editor's provider `or`: OpenAI-shaped at `base`, keyed (Bearer).
fn editor_gw_providers(base: &str) -> Vec<Provider> {
    vec![provider("or", Kind::Openai, base, Auth::Bearer)]
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_editor_route_passes_the_body_unchanged() {
    let mock = Mock::start(json!([
        {"path": "/api/v1/chat/completions", "body": "{\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1}}"}
    ]));
    let mut providers = editor_gw_providers(&mock.url("/api/v1"));
    providers.push(provider(
        "openrouter",
        Kind::Openai,
        &mock.url("/api/v1"),
        Auth::Bearer,
    ));
    // the agent's restrictions are the agent's: none reach the editor's request
    let mut restricted = agent(&["openrouter"], None);
    restricted.openrouter =
        Some(Restrictions::new(vec!["anthropic".into()], vec![], true, true).unwrap());
    let gw = Gw::start(
        providers,
        vec![(EDITOR, Registration::editor()), (AGENT, restricted)],
        &[("openrouter", "sk-or"), ("or", "sk-or")],
        0.0,
    )
    .await;
    let sent = "{\"model\":\"m\",  \"provider\" : {\"only\":[\"x\"]},\"stream\":false}";
    for id in ["or", "openrouter"] {
        let reply = gw
            .call(EDITOR, &format!("/p/{id}/chat/completions"), sent)
            .await;
        assert_eq!(reply.status, 200, "{}", reply.body);
    }
    for request in mock.requests() {
        assert_eq!(request["path"], "/api/v1/chat/completions");
        assert_eq!(
            request["body"], sent,
            "the bytes exactly as the editor sent them"
        );
        assert_eq!(request["headers"]["authorization"], "Bearer sk-or");
    }
    assert_eq!(mock.requests().len(), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_editor_route_never_falls_back() {
    let mock = Mock::start(json!([
        {"path": "/o/", "status": 429, "body": "{\"error\":\"later\"}", "headers": {"Retry-After": "9"}},
        {"path": "/p2/", "body": "{}"}
    ]));
    let mut gw = Gw::start(
        vec![
            provider("o", Kind::Openai, &mock.url("/o"), Auth::None),
            provider("p2", Kind::Openai, &mock.url("/p2"), Auth::None),
        ],
        vec![(EDITOR, Registration::editor())],
        &[],
        0.0,
    )
    .await;
    let reply = gw.call(EDITOR, "/p/o/chat/completions", "{}").await;
    assert_eq!(reply.status, 429);
    assert_eq!(reply.headers[RETRY_AFTER], "9");
    assert_eq!(reply.body, "{\"error\":\"later\"}");
    assert_eq!(mock.paths(), vec!["/o/chat/completions"]);
    assert!(fallbacks(&gw.pending()).is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_editor_route_streams_sse() {
    let keep_alive = ": OPENROUTER PROCESSING\n\n";
    let last = "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4}}\n\ndata: [DONE]\n\n";
    let mock = Mock::start(json!([
        {"path": "/api/v1/chat/completions", "chunks": [[0, keep_alive], [1500, last]]}
    ]));
    let mut gw = Gw::start(
        editor_gw_providers(&mock.url("/api/v1")),
        vec![(EDITOR, Registration::editor())],
        &[("or", "sk-or")],
        0.0,
    )
    .await;
    let (mut sender, _conn) = open(TcpStream::connect(("127.0.0.1", gw.port)).await.unwrap()).await;
    let sent = Instant::now();
    let response = sender
        .send_request(gw.request(EDITOR, "/p/or/chat/completions", "{\"stream\":true}"))
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.headers()[CONTENT_TYPE], "text/event-stream");
    let mut body = response.into_body();
    let first = body.frame().await.unwrap().unwrap().into_data().unwrap();
    assert!(
        sent.elapsed() < Duration::from_millis(1200),
        "{:?}",
        sent.elapsed()
    );
    assert_eq!(
        text(&first),
        keep_alive,
        "the keep-alive comment is passed on, first"
    );
    let rest = body.collect().await.unwrap().to_bytes();
    assert_eq!(text(&rest), last);
    let row = gw.row().await;
    assert_eq!((row.input, row.output), (3, 4));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_editor_route_records_a_spend_row_with_no_job() {
    let mock = Mock::start(json!([
        {"path": "/ol/api/chat", "body": "{\"done\":true,\"prompt_eval_count\":7,\"eval_count\":3}"}
    ]));
    let mut gw = Gw::start(
        vec![provider("ol", Kind::Ollama, &mock.url("/ol"), Auth::None)],
        vec![(EDITOR, Registration::editor())],
        &[],
        0.0,
    )
    .await;
    assert_eq!(gw.call(EDITOR, "/p/ol/api/chat", "{}").await.status, 200);
    let row = gw.row().await;
    assert_eq!(
        row,
        SpendRow {
            job: None,
            task: None,
            agent: Some("editor".into()),
            provider: "ol".into(),
            model: None,
            input: 7,
            output: 3,
            cost: 0.0,
            status: 200,
        }
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(gw.book.rows(), vec![row]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_editor_route_without_a_key_is_503_and_need_keys() {
    let mock = Mock::start(json!([{"path": "/", "body": "{}"}]));
    let mut gw = Gw::start(
        editor_gw_providers(&mock.url("/api/v1")),
        vec![(EDITOR, Registration::editor())],
        &[],
        0.0,
    )
    .await;
    let reply = gw.call(EDITOR, "/p/or/chat/completions", "{}").await;
    assert_eq!(reply.status, 503);
    let error = reply.json();
    assert_eq!(error["error"]["type"], "api_error");
    assert_eq!(error["error"]["message"], "no key for or in the drgnx hub");
    assert_eq!(
        gw.pending(),
        vec![GatewayEvent::NeedKeys {
            providers: vec!["or".into()]
        }]
    );
    assert!(mock.requests().is_empty());
}
