//! `ratatoskr embed serve` and the vector protocol v1 (Hrafn redesign Tasks 22 and 23): the server in front of a real
//! cache, and the client source `vectors` ([`RemoteVectors`]) against it.
//!
//! The server, the cache and the client are the real ones; what stands in is what is outside drgnx: the machine's
//! embedder is TEI (`ratatoskr-mock embed`, through the gateway). The server listens on 127.0.0.1 (plain HTTP there, as
//! loopback allows; TLS for the pin rows), and the rows speak HTTP/1.1 to it themselves.
//!
//! test-pattern: handshake (C): a request is answered when the call returns; what TEI saw is read from its log after.
#![cfg(feature = "test-hooks")]

use crate::search_prefer::{Server, gate, tei};
use bifrost::engine::{Ledger, SpendRow};
use hrafn::{KeyKind, VectorCache};
use hrafn_embed::fingerprint::Identity;
use ratatoskr::embed_serve::{self, CacheServe, Running, ServeSpec, key_hex};
use ratatoskr::search::DocEmbedder;
use ratatoskr::search::caches::Caches;
use ratatoskr::search::remote::{CHANGED_CERT, MemPins, RemoteSpec, RemoteVectors};
use ratatoskr::search::sources::{FillOutcome, Item, Source, SourceChain, SourceKind};
use serde_json::{Value, json};
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use tempfile::TempDir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::Instant;

const DIMS: usize = 8;

/// The chain's "now" (its backoff's clock, nothing here waits on it): the virtual origin, as `search_sources` has it.
fn t0() -> Instant {
    Instant::from_std(skuld::origin())
}

/// A machine that serves: its state (cache, `embed-serve/`), TEI as its embedder, the server, and the first token.
struct Machine {
    /// The embedder reaches TEI through it.
    _gate: ratatoskr::gateway::Gate,
    _dir: TempDir,
    state: TempDir,
    tei: Server,
    id: Identity,
    cache: Arc<VectorCache>,
    running: Option<Running>,
    token: String,
    /// The spend rows of the embeds it served.
    spent: Arc<Spent>,
}

/// A spend ledger that keeps its rows.
#[derive(Default)]
struct Spent(Mutex<Vec<SpendRow>>);

impl Ledger for Spent {
    fn spent(&self, _job: &str) -> bifrost::engine::BoxFuture<'_, Result<f64, String>> {
        Box::pin(async { Ok(0.0) })
    }

    fn record(&self, row: SpendRow) -> bifrost::engine::BoxFuture<'_, ()> {
        saman::lock(&self.0).push(row);
        Box::pin(async {})
    }
}

impl Spent {
    fn rows(&self) -> Vec<SpendRow> {
        saman::lock(&self.0).clone()
    }
}

impl Machine {
    /// Serving on 127.0.0.1: PLAIN or TLS, NO_EMBED or not. The cache holds one chunk vector, under `chunk_key("held")`.
    async fn start(plain: bool, no_embed: bool) -> Machine {
        let dir = tempfile::tempdir().unwrap();
        let tei_server = Server::start(dir.path());
        let g = gate(
            dir.path(),
            json!([tei(&format!("http://127.0.0.1:{}", tei_server.port))]),
        )
        .await;
        let e = g.embedders(&[]).unwrap().remove(0);
        let id = DocEmbedder::probe(&e).await.unwrap();
        let state = tempfile::tempdir().unwrap();
        let caches = Caches::shared(state.path());
        let cache = caches.get(&id).await.unwrap();
        cache
            .put(
                KeyKind::Chunk,
                DIMS as u32,
                &[(hrafn::chunk_key("held"), vec![0.25; DIMS])],
            )
            .await
            .unwrap();
        let spent = Arc::new(Spent::default());
        let serve = Arc::new(CacheServe::new(caches, vec![Arc::new(e)]).with_ledger(spent.clone()));
        let (running, token) = embed_serve::start(
            ServeSpec {
                listen: "127.0.0.1:0".parse().unwrap(),
                plain,
                no_embed,
                dir: state.path().join("embed-serve"),
            },
            serve,
        )
        .await
        .unwrap();
        Machine {
            _gate: g,
            _dir: dir,
            state,
            tei: tei_server,
            id,
            cache,
            running: Some(running),
            token: token.expect("the first start shows a token"),
            spent,
        }
    }

    fn running(&self) -> &Running {
        self.running.as_ref().unwrap()
    }

    fn addr(&self) -> SocketAddr {
        let url = self.running().url();
        url.rsplit("//").next().unwrap().parse().unwrap()
    }

    /// METHOD PATH with TOKEN (none: no header) and BODY, plain HTTP: the status and the body as JSON.
    async fn call(
        &self,
        method: &str,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> (u16, Value) {
        let mut s = tokio::net::TcpStream::connect(self.addr()).await.unwrap();
        let body = body.map(|b| b.to_string()).unwrap_or_default();
        let auth = token.map_or_else(String::new, |t| format!("Authorization: Bearer {t}\r\n"));
        let req = format!(
            "{method} {path} HTTP/1.1\r\nHost: x\r\n{auth}Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        s.write_all(req.as_bytes()).await.unwrap();
        let mut out = Vec::new();
        s.read_to_end(&mut out).await.unwrap();
        let text = String::from_utf8_lossy(&out).into_owned();
        let status: u16 = text.split(' ').nth(1).unwrap().parse().unwrap();
        let (_, rest) = text.split_once("\r\n\r\n").unwrap();
        // a chunked body: its first chunk is the JSON
        let json_text = rest
            .find('{')
            .map(|i| &rest[i..rest.rfind('}').map_or(rest.len(), |j| j + 1)])
            .unwrap_or("null");
        (
            status,
            serde_json::from_str(json_text).unwrap_or(Value::Null),
        )
    }

    fn texts_tei_saw(&self) -> Vec<String> {
        self.tei
            .embeds()
            .iter()
            .flat_map(|(_, b)| b["inputs"].as_array().cloned().unwrap_or_default())
            .map(|t| t.as_str().unwrap_or_default().to_owned())
            .collect()
    }
}

/// Pattern C. `/v1/info` names the fingerprints the cache and the embedder serve, that it embeds, and its limits.
#[test]
fn info_lists_fingerprints() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let m = Machine::start(true, false).await;
        let (status, info) = m.call("GET", "/v1/info", Some(&m.token), None).await;
        assert_eq!(status, 200, "{info}");
        assert_eq!(info["version"], 1);
        assert_eq!(info["embed"], true);
        assert_eq!(info["max_batch"], embed_serve::MAX_BATCH);
        let fps: Vec<&str> = info["fingerprints"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| f["hex"].as_str().unwrap())
            .collect();
        assert_eq!(fps, [m.id.fp.hex()], "{info}");
        assert_eq!(
            info["fingerprints"][0]["record"],
            serde_json::from_str::<Value>(&m.id.record.to_json()).unwrap()
        );
    })
}

/// Pattern C. A lookup carries keys only and answers the stored rows unchanged; a key the cache lacks is not in the
/// answer, and nothing reaches the embedder.
#[test]
fn lookup_never_needs_text() {
    saman::Executor::new(2).unwrap().block_on(async move {
    let m = Machine::start(true, false).await;
    let (held, lacking) = (hrafn::chunk_key("held"), hrafn::chunk_key("not here"));
    let (status, a) = m
        .call(
            "POST",
            "/v1/lookup",
            Some(&m.token),
            Some(json!({"fingerprint": m.id.fp.hex(), "kind": "chunk", "keys": [key_hex(&held), key_hex(&lacking)]})),
        )
        .await;
    assert_eq!(status, 200, "{a}");
    let found = a["found"].as_object().unwrap();
    assert_eq!(found.len(), 1, "{a}");
    let row = embed_serve::quant_row(
        held,
        &serde_json::from_value(found[&key_hex(&held)].clone()).unwrap(),
    )
    .unwrap();
    assert_eq!(
        row,
        m.cache.get(KeyKind::Chunk, &[held]).await.unwrap()[0],
        "moved unchanged"
    );
    assert!(m.texts_tei_saw().is_empty(), "a lookup embedded something");
})
}

/// Pattern C (§12 security). An item whose key is not its text's is refused with 422 and the key, and nothing of the
/// request is embedded or written; a request whose keys are right is embedded and kept.
#[test]
fn embed_key_mismatch_is_refused() {
    saman::Executor::new(2).unwrap().block_on(async move {
    let m = Machine::start(true, false).await;
    let (a, lie) = (
        hrafn::chunk_key("alpha"),
        hrafn::chunk_key("someone else's"),
    );
    let body = json!({"fingerprint": m.id.fp.hex(), "kind": "chunk",
                      "items": [{"key": key_hex(&a), "text": "alpha"}, {"key": key_hex(&lie), "text": "poison"}]});
    let (status, answer) = m
        .call("POST", "/v1/embed", Some(&m.token), Some(body))
        .await;
    assert_eq!(status, 422, "{answer}");
    assert_eq!(
        answer,
        json!({"error": "key-mismatch", "key": key_hex(&lie)})
    );
    assert!(
        m.texts_tei_saw().is_empty(),
        "embedded: {:?}",
        m.texts_tei_saw()
    );
    assert_eq!(
        m.cache.has(KeyKind::Chunk, &[a, lie]).await.unwrap(),
        [false, false]
    );
    // a path key is its path text's
    let p = hrafn::path_text("src/a.rs");
    let body = json!({"fingerprint": m.id.fp.hex(), "kind": "path",
                      "items": [{"key": key_hex(&hrafn::path_key("src/a.rs")), "text": p}]});
    let (status, answer) = m
        .call("POST", "/v1/embed", Some(&m.token), Some(body))
        .await;
    assert_eq!(status, 200, "{answer}");
    assert_eq!(answer["vectors"].as_object().unwrap().len(), 1);
    assert_eq!(
        m.cache
            .has(KeyKind::Path, &[hrafn::path_key("src/a.rs")])
            .await
            .unwrap(),
        [true],
        "added to the cache"
    );
})
}

/// Pattern C. No token and a wrong token are both 401, on every path.
#[test]
fn no_token_is_401_wrong_token_is_401() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let m = Machine::start(true, false).await;
        let lookup = json!({"fingerprint": m.id.fp.hex(), "kind": "chunk", "keys": []});
        for (method, path, body) in [
            ("GET", "/v1/info", None),
            ("POST", "/v1/lookup", Some(lookup.clone())),
        ] {
            assert_eq!(
                m.call(method, path, None, body.clone()).await.0,
                401,
                "{path}: no token"
            );
            let wrong = format!("{}x", &m.token[..m.token.len() - 1]);
            assert_eq!(
                m.call(method, path, Some(&wrong), body.clone()).await.0,
                401,
                "{path}: wrong token"
            );
            assert_eq!(
                m.call(method, path, Some(&m.token), body).await.0,
                200,
                "{path}: the token"
            );
        }
    })
}

/// A `tracing` writer into a buffer.
#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl std::io::Write for Captured {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        saman::lock(&self.0).extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Pattern C. Every request is logged (at trace and above, all captured), and no line holds the token, a wrong token
/// or a text. One thread: the server's tasks log to this test's subscriber.
#[test]
fn token_never_in_logs() {
    saman::block_on_current(async move {
        let logs = Captured::default();
        let sink = logs.clone();
        let subscriber = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::TRACE)
            .with_writer(move || sink.clone())
            .finish();
        let _guard = tracing::subscriber::set_default(subscriber);
        let m = Machine::start(true, false).await;
        let wrong = "wrong-token-0123456789";
        let secret = "SECRET-TEXT-7f3a";
        m.call("GET", "/v1/info", Some(wrong), None).await;
        let body = json!({"fingerprint": m.id.fp.hex(), "kind": "chunk",
                      "items": [{"key": key_hex(&hrafn::chunk_key(secret)), "text": secret}]});
        let (status, _) = m
            .call("POST", "/v1/embed", Some(&m.token), Some(body))
            .await;
        assert_eq!(status, 200);
        let text = String::from_utf8_lossy(&saman::lock(&logs.0)).into_owned();
        assert!(
            text.contains("embed serve"),
            "the requests are logged: {text}"
        );
        for (what, s) in [
            ("the token", m.token.as_str()),
            ("a wrong token", wrong),
            ("a text", secret),
        ] {
            assert!(!text.contains(s), "{what} in the log:\n{text}");
        }
    })
}

/// Pure (D). Plain HTTP only on loopback or a Tailscale address; `start` refuses it elsewhere before binding.
#[test]
fn plain_http_refused_on_a_public_address() {
    saman::block_on_current(async move {
        for (ip, ok) in [
            ("127.0.0.1", true),
            ("::1", true),
            ("100.94.36.51", true),
            ("100.64.0.1", true),
            ("100.127.255.254", true),
            ("fd7a:115c:a1e0::5", true),
            ("100.128.0.1", false),
            ("100.63.255.255", false),
            ("192.168.1.10", false),
            ("8.8.8.8", false),
            ("0.0.0.0", false),
            ("fd7a:115c:a1e1::5", false),
        ] {
            assert_eq!(
                embed_serve::plain_allowed(ip.parse::<IpAddr>().unwrap()),
                ok,
                "{ip}"
            );
        }
        let state = tempfile::tempdir().unwrap();
        let serve = Arc::new(CacheServe::new(Caches::shared(state.path()), Vec::new()));
        let refused = embed_serve::start(
            ServeSpec {
                listen: "0.0.0.0:0".parse().unwrap(),
                plain: true,
                no_embed: false,
                dir: state.path().join("embed-serve"),
            },
            serve,
        )
        .await;
        let err = refused.err().expect("plain on 0.0.0.0 is refused");
        assert!(err.to_string().contains("plain"), "{err}");
        assert!(
            !state.path().join("embed-serve/token.sha256").exists(),
            "refused before a token"
        );
    })
}

/// Pattern C. `--new-token`: the new token is shown once, the old one is refused from the next request, and only the
/// sha256 is kept (0600).
#[test]
fn new_token_revokes_old() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let m = Machine::start(true, false).await;
        let kept = m.state.path().join("embed-serve/token.sha256");
        let at_rest = ratatoskr::fsio::read_to_string(&kept).unwrap();
        assert!(!at_rest.contains(&m.token), "the token itself is kept");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&kept).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let new = m.running().new_token().unwrap();
        assert_ne!(new, m.token);
        assert_eq!(
            m.call("GET", "/v1/info", Some(&m.token), None).await.0,
            401,
            "the old token"
        );
        assert_eq!(
            m.call("GET", "/v1/info", Some(&new), None).await.0,
            200,
            "the new one"
        );
    })
}

/// Pattern C. `--no-embed`: `/v1/info` says so and `/v1/embed` is refused; lookups still answer.
#[test]
fn no_embed_flag_refuses_embed() {
    saman::Executor::new(2).unwrap().block_on(async move {
    let m = Machine::start(true, true).await;
    let (_, info) = m.call("GET", "/v1/info", Some(&m.token), None).await;
    assert_eq!(info["embed"], false, "{info}");
    let body = json!({"fingerprint": m.id.fp.hex(), "kind": "chunk",
                      "items": [{"key": key_hex(&hrafn::chunk_key("x")), "text": "x"}]});
    let (status, answer) = m
        .call("POST", "/v1/embed", Some(&m.token), Some(body))
        .await;
    assert_eq!(status, 403, "{answer}");
    assert_eq!(answer["error"], "no-embed");
    assert!(m.texts_tei_saw().is_empty());
    let lookup = json!({"fingerprint": m.id.fp.hex(), "kind": "chunk", "keys": [key_hex(&hrafn::chunk_key("held"))]});
    assert_eq!(
        m.call("POST", "/v1/lookup", Some(&m.token), Some(lookup))
            .await
            .0,
        200
    );
})
}

// ---- Task 23: the client source `vectors` against the server

fn client(m: &Machine, trusted: bool, pins: Arc<MemPins>) -> Arc<RemoteVectors> {
    client_counted(m, trusted, pins, None)
}

fn client_counted(
    m: &Machine,
    trusted: bool,
    pins: Arc<MemPins>,
    ledger: Option<Arc<Spent>>,
) -> Arc<RemoteVectors> {
    Arc::new(RemoteVectors::new(RemoteSpec {
        id: "desk".into(),
        url: m.running().url().to_owned(),
        token: Some(m.token.clone()),
        trusted,
        pins,
        ledger: ledger.map(|l| l as Arc<dyn Ledger>),
    }))
}

fn items(texts: &[&str]) -> Vec<Item> {
    texts
        .iter()
        .map(|t| (KeyKind::Chunk, hrafn::chunk_key(t), (*t).to_owned()))
        .collect()
}

/// Pattern C. A remote not marked trusted is a lookup source: the keys it holds are filled from it, the ones it lacks
/// stay missing, and no text reaches it (nor its embedder).
#[test]
fn untrusted_remote_gets_lookups_only() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let m = Machine::start(true, false).await;
        let remote = client(&m, false, Arc::default());
        assert_eq!(
            (remote.kind(), remote.may_send_text()),
            (SourceKind::Lookup, false)
        );
        let id = remote.probe().await.unwrap();
        assert_eq!(id.fp, m.id.fp, "its identity is the served fingerprint");
        let here = tempfile::tempdir().unwrap();
        let cache = Caches::shared(here.path()).get(&id).await.unwrap();
        let mut chain = SourceChain::new(id.fp, vec![remote.clone() as Arc<dyn Source>]);
        let out = chain.fill(&cache, &items(&["held", "missing"]), t0()).await;
        assert_eq!(
            out,
            FillOutcome::Filled {
                n: 1,
                from: "desk".into()
            }
        );
        assert_eq!(
            cache
                .has(
                    KeyKind::Chunk,
                    &[hrafn::chunk_key("held"), hrafn::chunk_key("missing")]
                )
                .await
                .unwrap(),
            [true, false]
        );
        assert!(
            m.texts_tei_saw().is_empty(),
            "text reached the remote: {:?}",
            m.texts_tei_saw()
        );
    })
}

/// Pattern C. A trusted remote is asked for the keys first, then the ones it lacks go to it as texts.
#[test]
fn trusted_remote_gets_text_after_lookup_misses() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let m = Machine::start(true, false).await;
        let remote = client(&m, true, Arc::default());
        assert_eq!(
            (remote.kind(), remote.may_send_text()),
            (SourceKind::Embed, true)
        );
        let id = remote.probe().await.unwrap();
        let here = tempfile::tempdir().unwrap();
        let cache = Caches::shared(here.path()).get(&id).await.unwrap();
        let mut chain = SourceChain::new(id.fp, vec![remote.clone() as Arc<dyn Source>]);
        let out = chain
            .fill(&cache, &items(&["held", "fresh one"]), t0())
            .await;
        assert_eq!(
            out,
            FillOutcome::Filled {
                n: 2,
                from: "desk".into()
            }
        );
        assert_eq!(
            m.texts_tei_saw(),
            ["fresh one"],
            "only the miss went as text"
        );
        assert_eq!(
            cache
                .has(KeyKind::Chunk, &[hrafn::chunk_key("fresh one")])
                .await
                .unwrap(),
            [true]
        );
    })
}

/// Pattern C. TLS: the certificate is pinned at the first answer; a server with another certificate under the same
/// provider is refused with the message that names the pin, and nothing is asked of it.
#[test]
fn pin_on_first_use_then_refuse_a_changed_cert() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let pins = Arc::new(MemPins::default());
        let first = Machine::start(false, false).await;
        assert!(first.running().url().starts_with("https://"));
        let remote = client(&first, false, pins.clone());
        remote.probe().await.unwrap();
        assert_eq!(
            saman::lock(&pins.0).as_deref(),
            first.running().cert_sha256(),
            "pinned on first use"
        );
        remote.probe().await.expect("the same certificate again");
        // another machine (another certificate) under the same provider
        let second = Machine::start(false, false).await;
        assert_ne!(
            first.running().cert_sha256(),
            second.running().cert_sha256()
        );
        let moved = client(&second, false, pins.clone());
        let err = moved
            .probe()
            .await
            .expect_err("a changed certificate is refused");
        assert!(err.0.contains(CHANGED_CERT), "{}", err.0);
        assert_eq!(
            saman::lock(&pins.0).as_deref(),
            first.running().cert_sha256(),
            "the pin stays"
        );
    })
}

/// Pattern C (§10). On battery the local sources wait; a remote is not this machine's battery: a trusted one fills,
/// and the built-in model beside it is not asked.
#[test]
fn remote_not_gated_by_battery() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let m = Machine::start(true, false).await;
        let remote = client(&m, true, Arc::default());
        let id = remote.probe().await.unwrap();
        let here = tempfile::tempdir().unwrap();
        let cache = Caches::shared(here.path()).get(&id).await.unwrap();
        let mut chain = SourceChain::new(id.fp, vec![remote.clone() as Arc<dyn Source>]);
        chain.set_gates(true, false);
        assert!(chain.ready(t0()), "the battery holds no remote");
        let out = chain.fill(&cache, &items(&["on battery"]), t0()).await;
        assert_eq!(
            out,
            FillOutcome::Filled {
                n: 1,
                from: "desk".into()
            }
        );
        assert_eq!(chain.status()[1].state, "answering");
    })
}

/// Pattern C (MP-9: embeds are spend, lookups are free). A trusted remote's fill of one held key and one text is one
/// spend row on each side: the client's under the provider id, the server's as `embed-serve`, both for the one text.
/// An untrusted remote's lookups, and a fill the remote holds whole, count nothing.
#[test]
fn served_and_trusted_remote_embeds_count_as_spend() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let m = Machine::start(true, false).await;
        let mine = Arc::new(Spent::default());
        // each fill into a cache of its own, so every key is missing here
        let fill = |remote: Arc<RemoteVectors>, texts: &'static [&'static str]| async move {
            let here = tempfile::tempdir().unwrap();
            let id = remote.probe().await.unwrap();
            let cache = Caches::shared(here.path()).get(&id).await.unwrap();
            let mut chain = SourceChain::new(id.fp, vec![remote as Arc<dyn Source>]);
            chain.fill(&cache, &items(texts), t0()).await
        };
        // lookups only: nothing counted
        let looked = fill(
            client_counted(&m, false, Arc::default(), Some(mine.clone())),
            &["held", "never sent"],
        )
        .await;
        assert!(
            matches!(looked, FillOutcome::Filled { n: 1, .. }),
            "{looked:?}"
        );
        let held = fill(
            client_counted(&m, true, Arc::default(), Some(mine.clone())),
            &["held"],
        )
        .await;
        assert!(matches!(held, FillOutcome::Filled { n: 1, .. }), "{held:?}");
        assert!(mine.rows().is_empty(), "{:?}", mine.rows());
        assert!(m.spent.rows().is_empty(), "{:?}", m.spent.rows());
        // a text sent: one row each side, for that text only
        let text = "sixteen bytes!!!";
        let sent = fill(
            client_counted(&m, true, Arc::default(), Some(mine.clone())),
            &["held", "sixteen bytes!!!"],
        )
        .await;
        assert!(matches!(sent, FillOutcome::Filled { n: 2, .. }), "{sent:?}");
        let label = m.id.record.model_id.clone();
        assert_eq!(
            mine.rows(),
            [embed_serve::spend_row("desk", "hrafn", &label, &[text])]
        );
        assert_eq!(
            m.spent.rows(),
            [embed_serve::spend_row(
                "embed-serve",
                "embed-serve",
                &label,
                &[text]
            )]
        );
        assert_eq!(mine.rows()[0].input, 4, "16 bytes, four to a token");
    })
}
