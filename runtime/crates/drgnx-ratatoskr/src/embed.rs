//! Entity vectors through the gateway (Urdr Task 12b; storage §5.2, §5.6 door 4; call 13).
//!
//! - **The provider** is the one of kind `tei` in `config/providers` ([`crate::gateway::Gate::embedder`]).  Texts go
//!   to the hub's own loopback listener as the editor's `POST /p/PROVIDER/embed` (an in-memory editor token, no key),
//!   so the gateway counts the request in `spend` like any other.  The hub **never starts** the provider: one that
//!   does not answer stops the round.
//! - **A round** ([`fill`]) takes at most [`BATCH`] stale entities (no vector of the model, [`urdr::graph::search::vec_stale`])
//!   at a time.  An entity whose source, id or `data.path` the personal-notes deny-list denies (an unknown source form
//!   too) is never sent, even when the scan's door let it in (door 4).  A batch that fails is tried once more; failing
//!   twice stops the round.
//! - **The schedule** ([`Timer`]): a round runs after the store has seen no write for [`IDLE`].  After a stop, one
//!   text is sent each idle minute, and rounds resume when the provider answers it.

use norn::deny::{DenyList, Source, Verdict};
use norn::store::{CoordDb, CoordError};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use urdr::graph::search::{BoxFuture, EmbedError, Embedder, vec_put, vec_stale};
use urdr::graph::{Class, TxMeta};

/// Entities per request.
pub const BATCH: usize = 64;

/// How long the store must be quiet before a round.
pub const IDLE: Duration = Duration::from_secs(60);

/// How long one request to the provider may take.
const DEADLINE: Duration = Duration::from_secs(60);

/// The most characters of one entity that are sent.
const MAX_TEXT: usize = 8000;

/// The `tei` provider PROVIDER, reached through the gateway's loopback listener on PORT with TOKEN.
pub struct Tei {
    port: u16,
    token: String,
    provider: String,
    model: String,
}

impl Tei {
    pub(crate) fn new(port: u16, token: String, provider: &str) -> Tei {
        Tei {
            port,
            token,
            provider: provider.to_owned(),
            model: format!("tei:{provider}"),
        }
    }

    async fn post(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        let body = json!({"inputs": texts}).to_string();
        let head = format!(
            "POST /p/{}/embed HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nAuthorization: Bearer {}\r\n\
             Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            self.provider,
            self.port,
            self.token,
            body.len()
        );
        let mut s = TcpStream::connect(("127.0.0.1", self.port))
            .await
            .map_err(|e| format!("the gateway does not answer: {e}"))?;
        s.write_all(head.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        s.write_all(body.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        let mut raw = Vec::new();
        s.read_to_end(&mut raw).await.map_err(|e| e.to_string())?;
        let (status, payload) = split_response(&raw)?;
        if status != 200 {
            return Err(format!(
                "{} answered {status}: {}",
                self.provider,
                String::from_utf8_lossy(&payload)
                    .chars()
                    .take(200)
                    .collect::<String>()
            ));
        }
        let rows: Vec<Vec<f32>> = serde_json::from_slice(&payload)
            .map_err(|e| format!("{} answered what is not vectors: {e}", self.provider))?;
        if rows.len() != texts.len() {
            return Err(format!(
                "{} answered {} vectors for {} texts",
                self.provider,
                rows.len(),
                texts.len()
            ));
        }
        Ok(rows)
    }
}

impl Embedder for Tei {
    fn embed<'a>(
        &'a self,
        texts: &'a [String],
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        Box::pin(async move {
            match tokio::time::timeout(DEADLINE, self.post(texts)).await {
                Ok(r) => r.map_err(EmbedError),
                Err(_) => Err(EmbedError(format!(
                    "{} did not answer in time",
                    self.provider
                ))),
            }
        })
    }

    fn model(&self) -> &str {
        &self.model
    }
}

/// An HTTP/1.1 response read to its end: the status and the (de-chunked) body.
fn split_response(raw: &[u8]) -> Result<(u16, Vec<u8>), String> {
    let end = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or("the gateway's answer has no head")?;
    let head = String::from_utf8_lossy(&raw[..end]).to_ascii_lowercase();
    let status = head
        .split(' ')
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or("the gateway's answer has no status")?;
    let rest = &raw[end + 4..];
    if !head.contains("transfer-encoding: chunked") {
        return Ok((status, rest.to_vec()));
    }
    let mut out = Vec::new();
    let mut at = 0;
    loop {
        let eol = rest[at..]
            .windows(2)
            .position(|w| w == b"\r\n")
            .ok_or("a chunk has no size")?;
        let size = std::str::from_utf8(&rest[at..at + eol])
            .ok()
            .and_then(|s| usize::from_str_radix(s.split(';').next().unwrap_or("").trim(), 16).ok())
            .ok_or("a chunk's size is not a number")?;
        at += eol + 2;
        if size == 0 {
            return Ok((status, out));
        }
        let chunk = rest
            .get(at..at + size)
            .ok_or("the answer ends inside a chunk")?;
        out.extend_from_slice(chunk);
        at += size + 2;
    }
}

/// How a round ended.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Nothing was stale (or only denied entities were).
    Nothing,
    /// Every stale entity has its vector, but the denied ones, which are counted.
    Filled { embedded: usize, denied: usize },
    /// A batch failed twice; the round stopped after EMBEDDED vectors.
    Stopped { embedded: usize, why: String },
}

/// One entity as the round needs it.
struct Row {
    n: i64,
    id: String,
    source: Option<String>,
    data: Value,
    text: String,
}

/// Whether R may be sent to a provider (door 4): the deny-list passes its source, id and `data.path`.
fn allowed(deny: &DenyList, r: &Row) -> bool {
    let src = match &r.source {
        None => Some(Source::Recorded),
        Some(s) => Source::parse(s),
    };
    src.is_some_and(|s| {
        !matches!(
            deny.check_record(&s, &r.id, &r.data),
            Verdict::Denied { .. }
        )
    })
}

fn meta() -> TxMeta {
    TxMeta::new("hub", Class::System, "embedder")
}

fn text_of(title: Option<String>, body: Option<String>) -> String {
    let mut t = title.unwrap_or_default();
    if let Some(b) = body {
        if !t.is_empty() {
            t.push_str("\n\n");
        }
        t.push_str(&b);
    }
    t.chars().take(MAX_TEXT).collect()
}

/// Give the stale entities of E's model their vectors, BATCH at a time, until none is left that may be sent.
pub async fn fill(db: &CoordDb, e: &dyn Embedder, deny: &DenyList) -> Outcome {
    let model = e.model().to_owned();
    let mut skipped: BTreeSet<i64> = BTreeSet::new();
    let mut embedded = 0;
    loop {
        let (m, extra) = (model.clone(), skipped.len());
        let rows = db
            .read(move |c| {
                let limit = u32::try_from(BATCH + extra).unwrap_or(u32::MAX);
                let mut out = Vec::new();
                for n in vec_stale(c, &m, limit)? {
                    out.push(n);
                }
                Ok(out)
            })
            .await;
        let stale = match rows {
            Ok(v) => v,
            Err(e) => {
                return Outcome::Stopped {
                    embedded,
                    why: e.to_string(),
                };
            }
        };
        let todo: Vec<i64> = stale
            .into_iter()
            .filter(|n| !skipped.contains(n))
            .take(BATCH)
            .collect();
        if todo.is_empty() {
            return if embedded == 0 && skipped.is_empty() {
                Outcome::Nothing
            } else {
                Outcome::Filled {
                    embedded,
                    denied: skipped.len(),
                }
            };
        }
        let ns = todo.clone();
        let loaded = db
            .read(move |c| {
                let mut st = c.prepare(
                    "select n, id, source, data, title, body from entity where n = ?1 and retired_tx is null",
                )?;
                let mut out = Vec::new();
                for n in ns {
                    let mut rows = st.query_map([n], |r| {
                        Ok(Row {
                            n: r.get(0)?,
                            id: r.get(1)?,
                            source: r.get(2)?,
                            data: serde_json::from_str(&r.get::<_, String>(3)?)
                                .unwrap_or(Value::Null),
                            text: text_of(r.get(4)?, r.get(5)?),
                        })
                    })?;
                    if let Some(r) = rows.next() {
                        out.push(r?);
                    }
                }
                Ok(out)
            })
            .await;
        let loaded = match loaded {
            Ok(v) => v,
            Err(e) => {
                return Outcome::Stopped {
                    embedded,
                    why: e.to_string(),
                };
            }
        };
        // an entity gone between the two reads is not stale any more; a denied one is passed over for this round
        let mut send = Vec::new();
        for r in loaded {
            if allowed(deny, &r) {
                send.push(r);
            } else {
                skipped.insert(r.n);
            }
        }
        for n in &todo {
            if !send.iter().any(|r| r.n == *n) {
                skipped.insert(*n);
            }
        }
        if send.is_empty() {
            continue;
        }
        let texts: Vec<String> = send.iter().map(|r| r.text.clone()).collect();
        let vectors = match e.embed(&texts).await {
            Ok(v) => v,
            Err(first) => match e.embed(&texts).await {
                Ok(v) => v,
                Err(second) => {
                    return Outcome::Stopped {
                        embedded,
                        why: format!("{}; then {}", first.0, second.0),
                    };
                }
            },
        };
        if vectors.len() != send.len() {
            return Outcome::Stopped {
                embedded,
                why: format!("{} vectors for {} texts", vectors.len(), send.len()),
            };
        }
        let put: Vec<(i64, Vec<f32>)> = send.iter().map(|r| r.n).zip(vectors).collect();
        let m = model.clone();
        let count = put.len();
        let wrote = db
            .write(meta(), move |tx| {
                for (n, v) in &put {
                    vec_put(tx, *n, &m, v).map_err(CoordError::from)?;
                }
                Ok(())
            })
            .await;
        match wrote {
            Ok(()) => embedded += count,
            Err(e) => {
                return Outcome::Stopped {
                    embedded,
                    why: e.to_string(),
                };
            }
        }
    }
}

/// When a round may start: the store was quiet for [`IDLE`], and no round runs.  Pure (the clock and the writer's
/// write count are arguments).
#[derive(Debug)]
pub struct Timer {
    writes: u64,
    since: Instant,
    running: bool,
    /// A round stopped: the next one starts by sending one text.
    stopped: bool,
}

impl Timer {
    pub fn new(now: Instant) -> Timer {
        Timer {
            writes: 0,
            since: now,
            running: false,
            stopped: false,
        }
    }

    /// Whether a round starts now, given the writer's count of writes so far.
    pub fn due(&mut self, writes: u64, now: Instant) -> bool {
        if writes != self.writes {
            self.writes = writes;
            self.since = now;
            return false;
        }
        if self.running || now.duration_since(self.since) < IDLE {
            return false;
        }
        self.running = true;
        true
    }

    /// Whether the round that starts now begins with a probe.
    pub fn probing(&self) -> bool {
        self.stopped
    }

    /// The round ended; STOPPED: it ended on a failure.  The quiet minute starts over either way.
    pub fn finish(&mut self, stopped: bool, now: Instant) {
        self.running = false;
        self.stopped = stopped;
        self.since = now;
    }
}

/// A round with its probe: after a stop, one text must be answered first.
pub async fn run(db: &CoordDb, e: &dyn Embedder, deny: &DenyList, probe: bool) -> Outcome {
    if probe && let Err(err) = e.embed(&["ping".to_owned()]).await {
        return Outcome::Stopped {
            embedded: 0,
            why: err.0,
        };
    }
    fill(db, e, deny).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gateway::Gate;
    use runstav::methods::gateway::ProvidersParams;
    use std::io::{BufRead, BufReader};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};

    /// `ratatoskr-mock`, next to the test binary's own directory; built once when it is not there.
    fn mock_binary() -> PathBuf {
        let exe = std::env::current_exe().unwrap();
        let dir = exe.parent().unwrap().parent().unwrap();
        let bin = dir.join("ratatoskr-mock");
        if !bin.exists() {
            let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
            let ok = Command::new(cargo)
                .args(["build", "-p", "domr", "--bin", "ratatoskr-mock"])
                .status()
                .unwrap()
                .success();
            assert!(ok && bin.exists(), "ratatoskr-mock is not built");
        }
        bin
    }

    struct Mock {
        child: Child,
        port: u16,
        log: PathBuf,
    }

    impl Drop for Mock {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    impl Mock {
        /// `ratatoskr-mock llm` with SCRIPT (the answers), logging to a file in DIR.
        fn start(dir: &Path, script: &Value) -> Mock {
            let file = dir.join("script.json");
            std::fs::write(&file, script.to_string()).unwrap();
            let log = dir.join("mock.log");
            let mut child = Command::new(mock_binary())
                .args(["llm", "--script"])
                .arg(&file)
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
                .unwrap()
                .parse()
                .unwrap();
            Mock { child, port, log }
        }

        /// The texts of each request that reached `/embed`, in order.
        fn requests(&self) -> Vec<Vec<String>> {
            let text = std::fs::read_to_string(&self.log).unwrap_or_default();
            text.lines()
                .filter_map(|l| serde_json::from_str::<Value>(l).ok())
                .filter_map(|v| v.get("request").cloned())
                .filter(|r| r["path"] == "/embed")
                .map(|r| {
                    let body: Value = serde_json::from_str(r["body"].as_str().unwrap()).unwrap();
                    body["inputs"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|t| t.as_str().unwrap().to_owned())
                        .collect()
                })
                .collect()
        }
    }

    /// A gateway listening, with the `tei` provider at PORT; and its embedder.
    async fn tei(dir: &Path, port: u16) -> (Gate, Tei) {
        let gate = Gate::new(CoordDb::spawn(dir.join("gw.db")));
        let p: ProvidersParams = runstav::decode::typed(&json!({"providers": [
            {"id": "tei", "kind": "tei", "base": format!("http://127.0.0.1:{port}"), "auth": "none",
             "messages": false, "caps": ["embed"]}]}))
        .unwrap()
        .0;
        gate.config_providers(p).await.unwrap();
        gate.listen(None).await.unwrap();
        let e = gate.embedder().unwrap().expect("a tei provider");
        (gate, e)
    }

    async fn put(db: &CoordDb, id: &str, source: Option<&str>, title: &str, data: Value) {
        let (id, source, title) = (id.to_owned(), source.map(str::to_owned), title.to_owned());
        db.write(meta(), move |tx| {
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
                    data,
                    origin: urdr::graph::entity::Origin::Recorded,
                    source,
                },
            )?;
            Ok(())
        })
        .await
        .unwrap();
    }

    async fn vectors(db: &CoordDb) -> i64 {
        db.read(|c| Ok(c.query_row("select count(*) from entity_vec", [], |r| r.get(0))?))
            .await
            .unwrap()
    }

    fn vecs(n: usize) -> String {
        json!(vec![[1.0, 0.0, 0.5, 0.25]; n]).to_string()
    }

    fn allow_all(dir: &Path) -> DenyList {
        DenyList::load(&dir.join("home"), &dir.join("config"))
    }

    #[tokio::test]
    async fn never_starts_the_provider() {
        let dir = tempfile::tempdir().unwrap();
        // a port nobody listens on: the provider is down
        let port = {
            let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            l.local_addr().unwrap().port()
        };
        let (gate, e) = tei(dir.path(), port).await;
        let db = CoordDb::spawn(dir.path().join("work.db"));
        put(&db, "task:a", None, "alpha", json!({})).await;
        let out = fill(&db, &e, &allow_all(dir.path())).await;
        assert!(
            matches!(out, Outcome::Stopped { embedded: 0, .. }),
            "{out:?}"
        );
        assert_eq!(vectors(&db).await, 0);
        // nothing was started in its place
        assert!(std::net::TcpStream::connect(("127.0.0.1", port)).is_err());
        drop(gate);
    }

    #[tokio::test]
    async fn a_denied_source_is_never_sent() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        std::fs::create_dir_all(home.join("org")).unwrap();
        // the canary is random bytes made here, never a real note
        let canary = runstav::proof::nonce().unwrap();
        let notes = home.join("org/notes.org");
        let mock = Mock::start(dir.path(), &json!([{"path": "/embed", "body": vecs(2)}]));
        let (_gate, e) = tei(dir.path(), mock.port).await;
        let db = CoordDb::spawn(dir.path().join("work.db"));
        put(&db, "task:ok1", None, "fine one", json!({})).await;
        put(
            &db,
            "task:src",
            Some(notes.to_str().unwrap()),
            &format!("by source {canary}"),
            json!({}),
        )
        .await;
        put(
            &db,
            "task:path",
            Some("recorded"),
            &format!("by data path {canary}"),
            json!({"path": notes.to_str().unwrap()}),
        )
        .await;
        put(
            &db,
            &format!("file:{}", notes.display()),
            Some("recorded"),
            &format!("by id {canary}"),
            json!({}),
        )
        .await;
        put(
            &db,
            "task:odd",
            Some("somewhere/relative"),
            &format!("unknown form {canary}"),
            json!({}),
        )
        .await;
        put(&db, "task:ok2", Some("commit"), "fine two", json!({})).await;
        let deny = DenyList::load(&home, &dir.path().join("config"));
        let out = fill(&db, &e, &deny).await;
        assert_eq!(
            out,
            Outcome::Filled {
                embedded: 2,
                denied: 4
            }
        );
        let sent = mock.requests();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0], ["fine one", "fine two"]);
        let log = std::fs::read_to_string(&mock.log).unwrap();
        assert!(!log.contains(&canary), "a denied text reached the provider");
        assert_eq!(vectors(&db).await, 2);
    }

    #[tokio::test]
    async fn fills_stale_vectors_in_batches() {
        let dir = tempfile::tempdir().unwrap();
        // 130 entities: batches of 64, 64 and 2, told apart by the first text of each
        let script = json!([
            {"path": "/embed", "match": "text 000", "body": vecs(64)},
            {"path": "/embed", "match": "text 064", "body": vecs(64)},
            {"path": "/embed", "match": "text 128", "body": vecs(2)},
        ]);
        let mock = Mock::start(dir.path(), &script);
        let (_gate, e) = tei(dir.path(), mock.port).await;
        let db = CoordDb::spawn(dir.path().join("work.db"));
        for i in 0..130 {
            put(
                &db,
                &format!("task:e{i:03}"),
                None,
                &format!("text {i:03}"),
                json!({}),
            )
            .await;
        }
        let out = fill(&db, &e, &allow_all(dir.path())).await;
        assert_eq!(
            out,
            Outcome::Filled {
                embedded: 130,
                denied: 0
            }
        );
        let sizes: Vec<usize> = mock.requests().iter().map(Vec::len).collect();
        assert_eq!(sizes, [64, 64, 2]);
        assert_eq!(vectors(&db).await, 130);
        let stale = db.read(|c| Ok(vec_stale(c, "tei:tei", 10)?)).await.unwrap();
        assert!(stale.is_empty());
        // a second round has nothing to do and sends nothing
        assert_eq!(
            fill(&db, &e, &allow_all(dir.path())).await,
            Outcome::Nothing
        );
        assert_eq!(mock.requests().len(), 3);
    }

    #[test]
    fn a_round_starts_after_a_quiet_minute_and_probes_after_a_stop() {
        let t0 = Instant::now();
        let mut t = Timer::new(t0);
        assert!(!t.due(0, t0 + IDLE / 2));
        assert!(t.due(0, t0 + IDLE));
        // one round at a time
        assert!(!t.due(0, t0 + IDLE * 3));
        t.finish(true, t0 + IDLE * 3);
        assert!(t.probing());
        // a write restarts the quiet minute
        assert!(!t.due(5, t0 + IDLE * 5));
        assert!(!t.due(5, t0 + IDLE * 5 + IDLE / 2));
        assert!(t.due(5, t0 + IDLE * 6 + IDLE));
        t.finish(false, t0 + IDLE * 7);
        assert!(!t.probing());
    }
}
