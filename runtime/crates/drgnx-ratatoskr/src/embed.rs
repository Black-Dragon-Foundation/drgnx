//! Entity vectors through the gateway (Urdr Task 12b; storage §5.2, §5.6 door 4; call 13).
//!
//! - **The provider** is the one of kind `tei` in the settings' provider table ([`crate::gateway::Gate::embedder`]).  Texts go
//!   to the hub's own loopback listener as the editor's `POST /p/PROVIDER/embed` (an in-memory editor token, no key),
//!   so the gateway counts the request in `spend` like any other.  The hub **never starts** the provider: one that
//!   does not answer stops the round.
//! - **A round** ([`fill`]) takes at most [`BATCH`] stale entities (no vector of the model, [`urdr::graph::search::vec_stale`])
//!   at a time.  An entity whose source, id or `data.path` the personal-notes deny-list denies (an unknown source form
//!   too) is never sent, even when the scan's door let it in (door 4).  A batch that fails is tried once more; failing
//!   twice stops the round.
//! - **The write checks again.** The provider is awaited outside the writer, so the write stores a vector only for an
//!   entity that, in the writer's tx, is live at the version and with the text that was read: one excised, revoked,
//!   retired or changed meanwhile keeps no vector of the old text, and the next batch sends its text of now.
//! - **The schedule** ([`Timer`]): a round runs after the store has seen no write that put an entity's text for
//!   [`IDLE`] (the writer's `texts`, [`urdr::graph::writer::WriterStatus::texts`]).  Lease, status, event and `kv` writes do
//!   not count: the Lisp backend's housekeeping writes every 60 s, and would keep every round away.  After a stop,
//!   one text is sent each idle minute, and rounds resume when the provider answers it.

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

/// How long the store must be quiet (no text written) before a round.
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
    /// The version the text was read at.
    ver: i64,
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

/// Whether R is, in the writer's tx, still live at the version and with the text it was read with: its vector may be
/// stored.  An excise blanks in place without a new version, so the text is compared too.
fn unchanged(c: &urdr::Connection, r: &Row) -> Result<bool, CoordError> {
    let now = c.query_row(
        "select ver, title, body from entity where n = ?1 and retired_tx is null",
        [r.n],
        |row| Ok((row.get::<_, i64>(0)?, text_of(row.get(1)?, row.get(2)?))),
    );
    match now {
        Ok((ver, text)) => Ok(ver == r.ver && text == r.text),
        Err(urdr::SqliteError::QueryReturnedNoRows) => Ok(false),
        Err(e) => Err(e.into()),
    }
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
                    "select n, id, source, data, title, body, ver from entity where n = ?1 and retired_tx is null",
                )?;
                let mut out = Vec::new();
                for n in ns {
                    let mut rows = st.query_map([n], |r| {
                        Ok(Row {
                            n: r.get(0)?,
                            ver: r.get(6)?,
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
        let put: Vec<(Row, Vec<f32>)> = send.into_iter().zip(vectors).collect();
        let m = model.clone();
        let wrote = db
            .write(meta(), move |tx| {
                let mut count = 0;
                for (r, v) in &put {
                    // the provider was awaited outside the writer: an entity excised, retired or changed meanwhile
                    // keeps no vector of the text that was sent (it is stale again, and the next batch sends its
                    // text of now)
                    if !unchanged(tx.sql(), r)? {
                        continue;
                    }
                    vec_put(tx, r.n, &m, v).map_err(CoordError::from)?;
                    count += 1;
                }
                Ok(count)
            })
            .await;
        match wrote {
            Ok(count) => embedded += count,
            Err(e) => {
                return Outcome::Stopped {
                    embedded,
                    why: e.to_string(),
                };
            }
        }
    }
}

/// When a round may start: no text was written for [`IDLE`], and no round runs.  Pure (the clock and the writer's
/// count of writes that put text, [`urdr::graph::writer::WriterStatus::texts`], are arguments).
#[derive(Debug)]
pub struct Timer {
    texts: u64,
    since: Instant,
    running: bool,
    /// A round stopped: the next one starts by sending one text.
    stopped: bool,
}

impl Timer {
    pub fn new(now: Instant) -> Timer {
        Timer {
            texts: 0,
            since: now,
            running: false,
            stopped: false,
        }
    }

    /// Whether a round starts now, given the writer's count of writes that put text so far.
    pub fn due(&mut self, texts: u64, now: Instant) -> bool {
        if texts != self.texts {
            self.texts = texts;
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
    use runstav::methods::gateway::ProviderConfig;
    use std::io::{BufRead, BufReader};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};

    /// `ratatoskr-mock`, next to the test binary's own directory; built once when it is not there, into the run's own
    /// target dir and profile (DIR is `<target dir>/<profile dir>`, `debug` for the dev profile), so a run with
    /// `--target-dir` or `--release` finds it.
    fn mock_binary() -> PathBuf {
        let exe = std::env::current_exe().unwrap();
        let dir = exe.parent().unwrap().parent().unwrap();
        let bin = dir.join("ratatoskr-mock");
        if !bin.exists() {
            let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
            let profile = dir.file_name().unwrap().to_str().unwrap();
            let profile = if profile == "debug" { "dev" } else { profile };
            let ok = Command::new(cargo)
                .args([
                    "build",
                    "-p",
                    "domr",
                    "--bin",
                    "ratatoskr-mock",
                    "--profile",
                    profile,
                ])
                .arg("--target-dir")
                .arg(dir.parent().unwrap())
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
        let table: Vec<ProviderConfig> = serde_json::from_value(json!([
            {"id": "tei", "kind": "tei", "base": format!("http://127.0.0.1:{port}"), "auth": "none",
             "messages": false, "caps": ["embed"]}]))
        .unwrap();
        gate.apply(&table).unwrap();
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

    /// An embedder without a provider: each text's vector is made from its bytes (64 signs of an FNV-1a hash), so a
    /// vector shows which text it was made from.  With `hold`, its first call says so (`called`) and waits for `go`.
    struct Fake {
        hold: bool,
        calls: std::sync::atomic::AtomicUsize,
        called: tokio::sync::Notify,
        go: tokio::sync::Notify,
    }

    impl Fake {
        fn new(hold: bool) -> Fake {
            Fake {
                hold,
                calls: Default::default(),
                called: tokio::sync::Notify::new(),
                go: tokio::sync::Notify::new(),
            }
        }

        fn vector(text: &str) -> Vec<f32> {
            let h = text.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| {
                (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
            });
            (0..64)
                .map(|i| if (h >> i) & 1 == 1 { 0.125 } else { -0.125 })
                .collect()
        }
    }

    impl Embedder for Fake {
        fn embed<'a>(
            &'a self,
            texts: &'a [String],
        ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
            Box::pin(async move {
                let first = self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0;
                if self.hold && first {
                    self.called.notify_one();
                    self.go.notified().await;
                }
                Ok(texts.iter().map(|t| Fake::vector(t)).collect())
            })
        }

        fn model(&self) -> &str {
            "fake"
        }
    }

    /// Every entity that has a vector, with its current text and whether the vector was made from that text.
    async fn vectors_and_texts(db: &CoordDb) -> Vec<(String, String, bool)> {
        db.read(|c| {
            let mut st = c.prepare(
                "select e.id, e.title, e.body, v.bits from entity e join entity_vec v on v.n = e.n order by e.n",
            )?;
            let rows = st.query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    text_of(r.get(1)?, r.get(2)?),
                    r.get::<_, Vec<u8>>(3)?,
                ))
            })?;
            let mut out = Vec::new();
            for row in rows {
                let (id, text, bits) = row?;
                let current = urdr::graph::search::vec::quantize(&Fake::vector(&text)).0 == bits;
                out.push((id, text, current));
            }
            Ok(out)
        })
        .await
        .unwrap()
    }

    /// The bits of entity ID's vector, if it has one.
    async fn bits_of(db: &CoordDb, id: &'static str) -> Option<Vec<u8>> {
        db.read(move |c| {
            Ok(c.query_row(
                "select v.bits from entity_vec v join entity e on e.n = v.n where e.id = ?1",
                [id],
                |r| r.get(0),
            )
            .ok())
        })
        .await
        .unwrap()
    }

    /// Entity ID's title set to TITLE.
    async fn retitle(db: &CoordDb, id: &'static str, title: &'static str) {
        db.write(meta(), move |tx| {
            let n = urdr::graph::entity::by_id(tx.sql(), id)?.expect("stored").n;
            urdr::graph::entity::update(
                tx,
                n,
                None,
                urdr::graph::entity::Changes {
                    title: Some(Some(title.into())),
                    ..Default::default()
                },
            )?;
            Ok(())
        })
        .await
        .unwrap();
    }

    /// The embedder vs excise and edits (review finding 6): a text excised, retired or changed while the provider is
    /// answering gets no vector of the text that was sent; the vector each one has afterwards is of its text now.
    #[tokio::test]
    async fn a_text_changed_while_the_provider_answers_gets_no_old_vector() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        put(&db, "task:keep", None, "kept as it is", json!({})).await;
        put(&db, "task:gone", None, "a text to excise now", json!({})).await;
        put(&db, "task:moved", None, "the first text", json!({})).await;
        put(&db, "task:retired", None, "retired meanwhile", json!({})).await;
        let e = Fake::new(true);
        let writer = db.graph_writer().unwrap().clone();
        let deny = allow_all(dir.path());
        let (out, ()) = tokio::join!(fill(&db, &e, &deny), async {
            e.called.notified().await;
            urdr::graph::excise::excise(
                &writer,
                TxMeta::new("user", Class::User, "test"),
                urdr::graph::excise::Target::Entity("task:gone".into()),
                None,
                "a test".into(),
                Vec::new(),
            )
            .await
            .unwrap();
            retitle(&db, "task:moved", "the second text").await;
            db.write(meta(), |tx| {
                let n = urdr::graph::entity::by_id(tx.sql(), "task:retired")?
                    .expect("stored")
                    .n;
                urdr::graph::entity::retire(tx, n)?;
                Ok(())
            })
            .await
            .unwrap();
            e.go.notify_one();
        });
        assert!(matches!(out, Outcome::Filled { .. }), "{out:?}");
        let old = |t: &str| Some(urdr::graph::search::vec::quantize(&Fake::vector(t)).0);
        assert_ne!(bits_of(&db, "task:gone").await, old("a text to excise now"));
        assert_ne!(bits_of(&db, "task:moved").await, old("the first text"));
        assert_eq!(bits_of(&db, "task:retired").await, None);
        assert_eq!(bits_of(&db, "task:keep").await, old("kept as it is"));
        let all = vectors_and_texts(&db).await;
        assert!(all.iter().all(|(_, _, current)| *current), "{all:?}");
    }

    /// Stale vectors (review finding 7): a changed title drops the vector in the same tx, so the next round embeds
    /// the new text, and no vector is left of the old one.
    #[tokio::test]
    async fn an_edited_text_is_embedded_again() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        put(&db, "task:note", None, "the old words", json!({})).await;
        let e = Fake::new(false);
        let deny = allow_all(dir.path());
        assert_eq!(
            fill(&db, &e, &deny).await,
            Outcome::Filled {
                embedded: 1,
                denied: 0
            }
        );
        retitle(&db, "task:note", "the new words").await;
        assert_eq!(
            vectors(&db).await,
            0,
            "the edit dropped the old text's vector"
        );
        assert_eq!(
            fill(&db, &e, &deny).await,
            Outcome::Filled {
                embedded: 1,
                denied: 0
            }
        );
        let all = vectors_and_texts(&db).await;
        assert_eq!(
            all,
            [("task:note".to_owned(), "the new words".to_owned(), true)]
        );
        let old = urdr::graph::search::vec::quantize(&Fake::vector("the old words")).0;
        assert_ne!(bits_of(&db, "task:note").await, Some(old));
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

    /// The writer's counts: (every write, the writes that put text).
    fn counts(db: &CoordDb) -> (u64, u64) {
        let st = db.graph_writer().unwrap().status();
        (st.writes, st.texts)
    }

    /// The lease of `j#1`'s entity: (holder, until).
    async fn lease_of(db: &CoordDb) -> (Option<String>, Option<f64>) {
        db.read(|c| {
            Ok(c.query_row(
                "select lease_holder, lease_until from entity where id = ?1",
                [norn::write::tasks::entity_id("j#1")],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?)
        })
        .await
        .unwrap()
    }

    /// A job whose one task agent-a holds: the lease the housekeeping renews.
    async fn claimed_job(db: &CoordDb) {
        use norn::write::{jobs, tasks};
        let claimed = db
            .write(meta(), |tx| {
                jobs::job_create(
                    tx,
                    jobs::NewJob {
                        id: "j".into(),
                        title: "the job".into(),
                        plan: None,
                        repo: None,
                        tasks: vec![jobs::NewTask {
                            n: 1,
                            title: "the one task".into(),
                            role: None,
                            deps: vec![],
                        }],
                        data: None,
                    },
                    1.0,
                )?;
                tasks::claim(tx, "j#1", "agent-a", None, 1.0)
            })
            .await
            .unwrap();
        assert_eq!(claimed, tasks::ClaimResult::Ok);
    }

    /// One run of the Lisp backend's housekeeping (`drgnx-hub--housekeeping`, every 60 s) at unix time NOW, as the
    /// front writes it: `coord/leases` (agent-a renewed, stale leases released), then `coord/prune`.
    async fn housekeeping(db: &CoordDb, now: f64) {
        use norn::write::{prune, tasks};
        db.write(
            TxMeta::new("hub", Class::System, "coord/leases"),
            move |tx| {
                tasks::renew(tx, "agent-a", now)?;
                tasks::release_stale(tx, now)?;
                Ok(())
            },
        )
        .await
        .unwrap();
        db.write(
            TxMeta::new("hub", Class::System, "coord/prune"),
            move |tx| {
                prune::prune_daily_tx(tx, now)?;
                Ok(())
            },
        )
        .await
        .unwrap();
    }

    /// URDR-EMBED-NEVER-IDLE-1: the housekeeping writes every minute (a lease renewed, the event log pruned), yet puts
    /// no text, so a round still starts after the quiet minute.  Counted by every write, it never would.
    #[tokio::test]
    async fn housekeeping_every_minute_still_lets_a_round_start() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        claimed_job(&db).await;
        let t0 = Instant::now();
        let mut t = Timer::new(t0);
        let mut by_writes = Timer::new(t0);
        let (w0, x0) = counts(&db);
        assert!(x0 > 0, "the job's tasks put text");
        assert!(!t.due(x0, t0));
        assert!(!by_writes.due(w0, t0));
        for minute in 1..=3u32 {
            let unix = 1.0 + 60.0 * f64::from(minute);
            housekeeping(&db, unix).await;
            let (w, x) = counts(&db);
            assert_eq!(
                w,
                w0 + 2 * u64::from(minute),
                "both housekeeping writes committed"
            );
            assert_eq!(x, x0, "the housekeeping put no text");
            assert_eq!(
                lease_of(&db).await,
                (
                    Some("agent-a".into()),
                    Some(unix + norn::write::tasks::LEASE_SECS)
                ),
                "the lease was renewed: an entity write"
            );
            let now = t0 + IDLE * minute;
            assert!(!by_writes.due(w, now), "every write restarts its minute");
            // each minute is quiet: its round starts (and ends, which starts the next minute)
            assert!(t.due(x, now), "minute {minute}: no round");
            t.finish(false, now);
        }
    }

    /// A write that puts text (a new entity, a changed title) restarts the quiet minute; the housekeeping between them
    /// does not.
    #[tokio::test]
    async fn a_content_write_restarts_the_quiet_minute() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        claimed_job(&db).await;
        let t0 = Instant::now();
        let mut t = Timer::new(t0);
        let (_, x0) = counts(&db);
        assert!(!t.due(x0, t0));
        // half a minute in, an entity with text is stored
        put(&db, "task:new", None, "new text", json!({})).await;
        let (_, x1) = counts(&db);
        assert_eq!(x1, x0 + 1);
        assert!(!t.due(x1, t0 + IDLE / 2));
        housekeeping(&db, 61.0).await;
        assert_eq!(counts(&db).1, x1);
        assert!(
            !t.due(x1, t0 + IDLE),
            "a minute after the start, half a minute after the text"
        );
        // its title changes: the minute starts over again
        db.write(meta(), |tx| {
            let n = urdr::graph::entity::by_id(tx.sql(), "task:new")?
                .expect("stored")
                .n;
            urdr::graph::entity::update(
                tx,
                n,
                None,
                urdr::graph::entity::Changes {
                    title: Some(Some("newer text".into())),
                    ..Default::default()
                },
            )?;
            Ok(())
        })
        .await
        .unwrap();
        let (_, x2) = counts(&db);
        assert_eq!(x2, x1 + 1);
        let at = t0 + IDLE + IDLE / 4;
        assert!(!t.due(x2, at));
        assert!(!t.due(x2, at + IDLE / 2));
        assert!(t.due(x2, at + IDLE), "a quiet minute after the last text");
    }
}
