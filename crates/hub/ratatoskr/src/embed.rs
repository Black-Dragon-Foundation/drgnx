//! Entity vectors through the gateway (Urdr Task 12b; storage §5.2, §5.6 door 4; call 13).
//!
//! - **The providers** are those of kind `tei` and `ollama` with the `embed` capability in the settings' provider table
//!   ([`crate::gateway::Gate::embedders`]), and the built-in model's worker ([`crate::search::worker::WorkerEmbedder`]).
//!   Texts go to the hub's own loopback listener as the editor's `POST /p/PROVIDER/embed` (TEI) or `/api/embed`
//!   (Ollama), with an in-memory editor token and no key, so the gateway counts the request in `spend` like any
//!   other.  The hub **never starts** a provider: one that does not answer is passed over.
//! - **The chain is the user's** ([`ordered`]): the embed role's steps in their order, each a server or `(builtin)`
//!   (the built-in model); the built-in model goes last only when no step names it and `drgnx-search-builtin` is on.
//!   Nothing else is added and nothing is reordered.  `entity_vec` is keyed `(n, model)`, so each model keeps its own
//!   vectors and the preferred one takes over again when it answers.
//! - **A round** ([`fill_chain`]) takes at most [`BATCH`] stale entities (no vector of the first answering model,
//!   [`urdr::graph::search::vec_stale`]) at a time.  An embedder that fails (refused, 5xx, timeout) is marked down and
//!   the **same batch** goes to the next one that answers.  An entity whose source, id or `data.path` the
//!   personal-notes deny-list denies (an unknown source form too) is never sent, even when the scan's door let it in
//!   (door 4).
//! - **The write checks again.** The provider is awaited outside the writer, so the write stores a vector only for an
//!   entity that, in the writer's tx, is live at the version and with the text that was read: one excised, revoked,
//!   retired or changed meanwhile keeps no vector of the old text, and the next batch sends its text of now.
//! - **Backoff per embedder** ([`Chain`], [`BACKOFF`]): a down one is asked again with one cached text after 1, 5 and
//!   30 minutes, then every 6 hours, on the hub's clock; an answer resets it.  While every embedder is down no round
//!   starts and no record is read ([`Driver`]).  Each change of state is one [`Change`]: one log line, and the
//!   Notices row ([`notice_text`]) follows the chain.
//! - **The schedule** ([`Timer`]): a round runs after the store has seen no write that put an entity's text for
//!   [`IDLE`] (the writer's `texts`, [`urdr::graph::writer::WriterStatus::texts`]).  Lease, status, event and `kv` writes do
//!   not count: housekeeping (leases, the prune) writes every minute, and would keep every round away.

use hrafn_embed::fingerprint::{FingerprintRecord, Identity, Pooling};
use norn::deny::{DenyList, Source, Verdict};
use norn::store::{CoordDb, CoordError};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::Instant;
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

/// Which API a provider speaks.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Api {
    /// `POST /embed {"inputs"}` answers a list of vectors.
    Tei,
    /// `POST /api/embed {"model", "input"}` answers `{"embeddings"}`; the model is the embed role's step.
    Ollama(String),
}

/// The `tei` or `ollama` provider PROVIDER at BASE (its URL in the table), reached through the gateway's loopback
/// listener on PORT with TOKEN.
///
/// Its model is what its last [`probe`](crate::search::DocEmbedder::probe) proved, as a fingerprint: a TEI server's
/// `/info` (model, revision, dtype, pooling, longest input) or an Ollama model's `/api/show` and `/api/tags` digest, and
/// the length of one probe embed. Until it has answered it has none, and it embeds nothing: no vector of a model that is
/// not known is ever stored.
pub struct ProviderEmbedder {
    port: u16,
    token: String,
    provider: String,
    base: String,
    api: Api,
    ident: std::sync::Mutex<Option<Identity>>,
    /// What the server said when the dims were last measured, and the dims.
    dims_seen: std::sync::Mutex<Option<(String, u32)>>,
    /// Its entry says `trusted`.
    marked: bool,
}

/// Whether the URL BASE names this machine (`localhost`, 127.x or ::1): the only providers that receive document text
/// unless their entry says `trusted` (Task 23).
pub fn is_loopback(base: &str) -> bool {
    let Ok(uri) = base.parse::<bifrost::Uri>() else {
        return false;
    };
    let Some(host) = uri.host() else {
        return false;
    };
    let host = host.trim_start_matches('[').trim_end_matches(']');
    host == "localhost"
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback())
}

/// The text a probe embeds to learn a server's dimensions (the mock server answers it with the model's real dims).
pub const PROBE_TEXT: &str = "drgnx fingerprint probe";

impl ProviderEmbedder {
    /// A TEI provider.
    pub(crate) fn tei(port: u16, token: String, provider: &str, base: &str) -> ProviderEmbedder {
        ProviderEmbedder {
            port,
            token,
            provider: provider.to_owned(),
            base: base.to_owned(),
            api: Api::Tei,
            ident: std::sync::Mutex::new(None),
            dims_seen: std::sync::Mutex::new(None),
            marked: false,
        }
    }

    /// An Ollama provider embedding with MODEL.
    pub(crate) fn ollama(
        port: u16,
        token: String,
        provider: &str,
        base: &str,
        model: &str,
    ) -> ProviderEmbedder {
        ProviderEmbedder {
            port,
            token,
            provider: provider.to_owned(),
            base: base.to_owned(),
            api: Api::Ollama(model.to_owned()),
            ident: std::sync::Mutex::new(None),
            dims_seen: std::sync::Mutex::new(None),
            marked: false,
        }
    }

    /// Its entry's `trusted`: text may go to it off this machine too.
    pub(crate) fn marked_trusted(mut self, yes: bool) -> ProviderEmbedder {
        self.marked = yes;
        self
    }

    /// What a probe of this server is cached under: the provider and, for Ollama, the model asked for.
    pub(crate) fn cache_key(&self) -> String {
        match &self.api {
            Api::Tei => format!("tei:{}", self.provider),
            Api::Ollama(m) => format!("ollama:{}:{m}", self.provider),
        }
    }

    /// Takes IDENTITY as what a probe proved (a probe of this server a moment ago, kept by the hub).
    pub(crate) fn seed(&self, identity: Identity) {
        *self
            .ident
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(identity);
    }

    /// What the last probe proved, if it did.
    fn known(&self) -> Option<Identity> {
        self.ident
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// The key the entity chain knows this embedder by: its fingerprint's hex, or `unprobed:<provider>` before it has
    /// answered (never a key of a vector: an unprobed embedder embeds nothing).
    fn key(&self) -> String {
        self.known()
            .map_or_else(|| format!("unprobed:{}", self.provider), |i| i.fp.hex())
    }

    /// The provider's id in the table.
    pub fn provider(&self) -> &str {
        &self.provider
    }

    /// `tei` or `ollama`.
    pub fn kind(&self) -> &'static str {
        match self.api {
            Api::Tei => "tei",
            Api::Ollama(_) => "ollama",
        }
    }

    /// The vector of query Q. With an INSTRUCTION (the query wording of the query's scope) the text is
    /// `Instruct: <instruction>\nQuery:<q>`, as the Qwen3 embedding models are trained on; documents go plain.
    pub async fn embed_query(
        &self,
        q: &str,
        instruction: Option<&str>,
    ) -> Result<Vec<f32>, EmbedError> {
        let text = match instruction {
            Some(i) => format!("Instruct: {i}\nQuery:{q}"),
            None => q.to_owned(),
        };
        let mut v = self.embed(&[text]).await?;
        v.pop()
            .ok_or_else(|| EmbedError(format!("{} answered no vector", self.provider)))
    }

    /// One request to the provider through the gateway: METHOD of PATH (under `/p/ID/`) with BODY (JSON text; none for a
    /// GET). The payload of a 200; any other status is an error naming it.
    async fn request(
        &self,
        method: &str,
        path: &str,
        body: Option<String>,
    ) -> Result<Vec<u8>, String> {
        let body = body.unwrap_or_default();
        let head = format!(
            "{method} /p/{}/{path} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nAuthorization: Bearer {}\r\n\
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
        Ok(payload)
    }

    /// Embeds TEXTS (an Ollama request never truncates, and sets its context to CTX tokens).
    async fn post(&self, texts: &[String], ctx: u32) -> Result<Vec<Vec<f32>>, String> {
        let (path, body) = match &self.api {
            Api::Tei => ("embed", json!({"inputs": texts})),
            Api::Ollama(model) => (
                "api/embed",
                json!({"model": model, "input": texts, "truncate": false,
                       "options": {"num_ctx": ctx}}),
            ),
        };
        let payload = self.request("POST", path, Some(body.to_string())).await?;
        let vectors =
            |e: serde_json::Error| format!("{} answered what is not vectors: {e}", self.provider);
        let rows: Vec<Vec<f32>> = match &self.api {
            Api::Tei => serde_json::from_slice(&payload).map_err(vectors)?,
            Api::Ollama(_) => {
                #[derive(serde::Deserialize)]
                struct Answer {
                    embeddings: Vec<Vec<f32>>,
                }
                serde_json::from_slice::<Answer>(&payload)
                    .map_err(vectors)?
                    .embeddings
            }
        };
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

impl Embedder for ProviderEmbedder {
    fn embed<'a>(
        &'a self,
        texts: &'a [String],
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        Box::pin(async move {
            let Some(id) = self.known() else {
                return Err(EmbedError(format!(
                    "{} has not stated its model yet: it is probed before it embeds",
                    self.provider
                )));
            };
            match crate::clock::timeout(DEADLINE, self.post(texts, id.record.max_tokens)).await {
                Ok(r) => r.map_err(EmbedError),
                Err(_) => Err(EmbedError(format!(
                    "{} did not answer in time",
                    self.provider
                ))),
            }
        })
    }

    /// The fingerprint's hex once probed, else `unprobed:<provider>`.
    fn model(&self) -> String {
        self.key()
    }
}

impl ProviderEmbedder {
    /// Asks the server what its model is, and remembers the answer ([`DocEmbedder::probe`]).
    async fn probe_identity(&self) -> Result<Identity, EmbedError> {
        let asked = async {
            let (record, label) = match &self.api {
                Api::Tei => {
                    let info = self.request("GET", "info", None).await?;
                    let info: Value = serde_json::from_slice(&info)
                        .map_err(|e| format!("{} answered no model info: {e}", self.provider))?;
                    let dims = self.probe_dims(&info.to_string()).await?;
                    let record = record_from_tei(&info, dims).map_err(|e| e.0)?;
                    let label = record.model_id.clone();
                    (record, label)
                }
                Api::Ollama(model) => {
                    let show = self
                        .request(
                            "POST",
                            "api/show",
                            Some(json!({"model": model}).to_string()),
                        )
                        .await?;
                    let show: Value = serde_json::from_slice(&show)
                        .map_err(|e| format!("{} answered no model details: {e}", self.provider))?;
                    let tags = self.request("GET", "api/tags", None).await?;
                    let tags: Value = serde_json::from_slice(&tags)
                        .map_err(|e| format!("{} answered no model list: {e}", self.provider))?;
                    let digest = tags["models"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .find(|m| m["name"] == *model || m["model"] == *model)
                        .and_then(|m| m["digest"].as_str())
                        .ok_or_else(|| format!("{} has no model {model}", self.provider))?
                        .to_owned();
                    let dims = self.probe_dims(&format!("{show}{digest}")).await?;
                    (
                        record_from_ollama(&show, &digest, dims).map_err(|e| e.0)?,
                        model.clone(),
                    )
                }
            };
            Ok::<_, String>(Identity::new(record, label))
        };
        let id = match crate::clock::timeout(DEADLINE, asked).await {
            Ok(r) => r.map_err(EmbedError)?,
            Err(_) => {
                return Err(EmbedError(format!(
                    "{} did not answer in time",
                    self.provider
                )));
            }
        };
        *self
            .ident
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(id.clone());
        Ok(id)
    }

    /// The length of the vector of [`PROBE_TEXT`]: the dims the fingerprint says. A model's dims do not change while
    /// what the server says of it (SAID) does not, so an unchanged answer reuses the last probe's: a probe before every
    /// batch of tier 2 is then one request, not two.
    async fn probe_dims(&self, said: &str) -> Result<u32, String> {
        if let Some((s, d)) = self
            .dims_seen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            && s == said
        {
            return Ok(*d);
        }
        let rows = self
            .post(&[PROBE_TEXT.to_owned()], crate::embed_direct::OLLAMA_CTX)
            .await?;
        let dims = rows
            .first()
            .map(|v| v.len() as u32)
            .ok_or_else(|| format!("{} answered no vector", self.provider))?;
        *self
            .dims_seen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some((said.to_owned(), dims));
        Ok(dims)
    }
}

/// The record of a TEI server from its `GET /info` answer INFO and the dims DIMS of one probe embed: the model, its
/// revision (`model_sha`), dtype, pooling and longest input. TEI normalises what it returns. An answer that names no
/// model, or dims of 0, proves nothing.
pub fn record_from_tei(info: &Value, dims: u32) -> Result<FingerprintRecord, EmbedError> {
    let model_id = info["model_id"]
        .as_str()
        .filter(|m| !m.is_empty())
        .ok_or_else(|| EmbedError("the server's info names no model".to_owned()))?;
    if dims == 0 {
        return Err(EmbedError("the server's vectors have no dims".to_owned()));
    }
    let text = |v: &Value| v.as_str().unwrap_or_default().to_owned();
    Ok(FingerprintRecord {
        model_id: model_id.to_owned(),
        weights_sha256: text(&info["model_sha"]),
        quant: text(&info["model_dtype"]),
        pooling: Pooling::parse(
            info["model_type"]["embedding"]["pooling"]
                .as_str()
                .unwrap_or(""),
        ),
        normalized: true,
        dims,
        max_tokens: info["max_input_length"]
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .unwrap_or(0),
        doc_prefix: String::new(),
        query_template: QUERY_TEMPLATE.to_owned(),
        embed_text_version: crate::search::EMBED_TEXT_VERSION,
    })
}

/// The record of an Ollama model from its `POST /api/show` answer SHOW, the digest DIGEST its `/api/tags` row gives and
/// the dims DIMS of one probe embed. The digest is what proves the weights. A show without a family proves nothing.
pub fn record_from_ollama(
    show: &Value,
    digest: &str,
    dims: u32,
) -> Result<FingerprintRecord, EmbedError> {
    let family = show["details"]["family"]
        .as_str()
        .filter(|f| !f.is_empty())
        .ok_or_else(|| EmbedError("the model's details name no family".to_owned()))?;
    if digest.is_empty() || dims == 0 {
        return Err(EmbedError(
            "no digest or no dims: the model is not proven".to_owned(),
        ));
    }
    let model_id = match show["details"]["parameter_size"].as_str() {
        Some(size) if !size.is_empty() => format!("{family}/{size}"),
        _ => family.to_owned(),
    };
    let info = &show["model_info"];
    let arch = info["general.architecture"].as_str().unwrap_or(family);
    // llama.cpp's pooling types: 0 none, 1 mean, 2 cls, 3 last
    let pooling = match info[format!("{arch}.pooling_type")].as_u64() {
        Some(1) => Pooling::Mean,
        Some(2) => Pooling::Cls,
        Some(3) => Pooling::Last,
        _ => Pooling::Unknown,
    };
    Ok(FingerprintRecord {
        model_id,
        weights_sha256: digest.to_owned(),
        quant: show["details"]["quantization_level"]
            .as_str()
            .unwrap_or_default()
            .to_owned(),
        pooling,
        normalized: true,
        dims,
        max_tokens: info[format!("{arch}.context_length")]
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .unwrap_or(crate::embed_direct::OLLAMA_CTX),
        doc_prefix: String::new(),
        query_template: QUERY_TEMPLATE.to_owned(),
        embed_text_version: crate::search::EMBED_TEXT_VERSION,
    })
}

/// The wording of a query to a server ([`ProviderEmbedder::embed_query`]): the Qwen3 embedding models' instruction form.
const QUERY_TEMPLATE: &str = "Instruct: {task}\nQuery:{query}";

impl crate::search::DocEmbedder for ProviderEmbedder {
    fn identity(&self) -> Option<Identity> {
        self.known()
    }

    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>> {
        Box::pin(self.probe_identity())
    }

    fn source_id(&self) -> String {
        self.provider.clone()
    }

    /// A server on this machine, or one whose entry says `trusted`.
    fn trusted(&self) -> bool {
        self.marked || is_loopback(&self.base)
    }

    fn embed_docs<'a>(
        &'a self,
        texts: &'a [String],
        _overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        self.embed(texts)
    }
}

/// How long the doctor's probe waits for one address to accept.
const PROBE: Duration = Duration::from_secs(3);

/// Which address family answers at BASE (a URL): `ipv4` or `ipv6`, the first address of the host's that accepts a
/// connection; none when none does.  `localhost` can resolve to `::1` first and the server listen on `127.0.0.1` only
/// (storage design §12A.3 item 11), so the doctor says what answered.
pub async fn answered_family(base: &str) -> Option<&'static str> {
    let uri: bifrost::Uri = base.parse().ok()?;
    let host = uri.host()?.trim_start_matches('[').trim_end_matches(']');
    let port = uri
        .port_u16()
        .unwrap_or(if uri.scheme_str() == Some("https") {
            443
        } else {
            80
        });
    let addrs = crate::clock::real(tokio::net::lookup_host((host, port)))
        .await
        .ok()?;
    for a in addrs {
        let connect = crate::clock::real(TcpStream::connect(a));
        if let Ok(Ok(_)) = crate::clock::timeout(PROBE, connect).await {
            return Some(if a.is_ipv4() { "ipv4" } else { "ipv6" });
        }
    }
    None
}

/// An HTTP/1.1 response read to its end: the status and the (de-chunked) body.
pub(crate) fn split_response(raw: &[u8]) -> Result<(u16, Vec<u8>), String> {
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

pub use crate::chain::{BACKOFF, Chain, Change, Health, backoff};

/// Give the stale entities their vectors, BATCH at a time, from the first embedder of EMBEDDERS (the chain, in the
/// user's order) that answers: the batch is read for it, and when it fails the same batch goes to the next one that
/// answers (each model's vectors are its own, so a fallback fills its own and the preferred one takes over when it
/// answers again).  CHAIN says which answer; a failure marks one down at NOW and is told in CHANGES.  READS counts the
/// store reads, the record work.  While no embedder answers, nothing is read.
pub async fn fill_chain(
    db: &CoordDb,
    embedders: &[&dyn Embedder],
    deny: &DenyList,
    chain: &mut Chain,
    now: Instant,
    changes: &mut Vec<Change>,
    reads: &mut u64,
) -> Outcome {
    let mut skipped: BTreeSet<i64> = BTreeSet::new();
    let mut embedded = 0;
    let mut stops: Vec<String> = Vec::new();
    loop {
        let Some(first) = embedders.iter().position(|e| chain.answering(&e.model())) else {
            return Outcome::Stopped {
                embedded,
                why: if stops.is_empty() {
                    "no embedder of the chain answers".to_owned()
                } else {
                    stops.join("; ")
                },
            };
        };
        let (m, extra) = (embedders[first].model(), skipped.len());
        *reads += 1;
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
        *reads += 1;
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
        // the same batch down the chain: a failure marks the embedder down and the next one that answers takes it
        let mut answer = None;
        for e in &embedders[first..] {
            let model = e.model();
            if !chain.answering(&model) {
                continue;
            }
            let why = match e.embed(&texts).await {
                Ok(v) if v.len() == send.len() => {
                    answer = Some((model, v));
                    break;
                }
                Ok(v) => format!("{} vectors for {} texts", v.len(), send.len()),
                Err(err) => err.0,
            };
            stops.push(format!("{model}: {why}"));
            changes.extend(chain.fail(&model, &why, now));
        }
        let Some((m, vectors)) = answer else { continue };
        let put: Vec<(Row, Vec<f32>)> = send.into_iter().zip(vectors).collect();
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

/// Give the stale entities of E's model their vectors, BATCH at a time, until none is left that may be sent; a failure
/// stops it.
pub async fn fill(db: &CoordDb, e: &dyn Embedder, deny: &DenyList) -> Outcome {
    let mut chain = Chain::default();
    chain.sync(&[e.model()]);
    fill_chain(
        db,
        &[e],
        deny,
        &mut chain,
        crate::clock::now(),
        &mut Vec::new(),
        &mut 0,
    )
    .await
}

/// When a round may start: no text was written for [`IDLE`], and no round runs.  Pure (the clock and the writer's
/// count of writes that put text, [`urdr::graph::writer::WriterStatus::texts`], are arguments).
#[derive(Debug)]
pub struct Timer {
    texts: u64,
    since: Instant,
    running: bool,
}

impl Timer {
    pub fn new(now: Instant) -> Timer {
        Timer {
            texts: 0,
            since: now,
            running: false,
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

    /// The round ended; the quiet minute starts over.
    pub fn finish(&mut self, now: Instant) {
        self.running = false;
        self.since = now;
    }
}

/// A round over the chain EMBEDDERS (the user's order) with its health CHAIN at NOW ([`fill_chain`]); the changes of
/// state it made go to CHANGES.
pub async fn run(
    db: &CoordDb,
    embedders: &[&dyn Embedder],
    deny: &DenyList,
    chain: &mut Chain,
    now: Instant,
    changes: &mut Vec<Change>,
) -> Outcome {
    let models: Vec<String> = embedders.iter().map(|e| e.model()).collect();
    chain.sync(&models);
    fill_chain(db, embedders, deny, chain, now, changes, &mut 0).await
}

/// What one step of the embedder did.
#[derive(Debug, Default)]
pub struct Step {
    /// The changes of state, in order: each one is one log line, and the Notices row follows them.
    pub changes: Vec<Change>,
    /// The round, when one ran.
    pub outcome: Option<Outcome>,
}

/// The embedder's schedule and the chain's health, stepped by the hub's tick (Task 192): the down embedders whose
/// wait is over are asked with one cached text; a round runs after a quiet minute only while one answers, so while
/// every embedder is down no record is read.
#[derive(Debug)]
pub struct Driver {
    timer: Timer,
    chain: Chain,
    /// The one text a probe sends, made once.
    ping: Vec<String>,
    /// The store reads of every round so far.
    reads: u64,
    /// When the last step ran.
    last: Option<Instant>,
}

impl Driver {
    pub fn new(now: Instant) -> Driver {
        Driver {
            timer: Timer::new(now),
            chain: Chain::default(),
            ping: vec!["ping".to_owned()],
            reads: 0,
            last: None,
        }
    }

    /// Whether the hub's tick at NOW steps it: the first time, on Retry now (RETRY), when a down embedder's wait is
    /// over, and else once every [`IDLE`] (the chain is read again then: a changed setting, a model now ready).
    /// Between those the tick costs nothing.
    pub fn wants(&self, now: Instant, retry: bool) -> bool {
        retry
            || self.last.is_none_or(|l| now.duration_since(l) >= IDLE)
            || !self.chain.probes_due(now).is_empty()
    }

    pub fn chain(&self) -> &Chain {
        &self.chain
    }

    /// The store reads of every round so far.
    pub fn reads(&self) -> u64 {
        self.reads
    }

    /// Retry now: every down embedder is asked at the next step.
    pub fn retry_now(&mut self, now: Instant) {
        self.chain.retry_now(now);
    }

    /// One step at NOW: EMBEDDERS is the chain in the user's order, TEXTS the writer's count of writes that put text.
    pub async fn step(
        &mut self,
        db: &CoordDb,
        embedders: &[&dyn Embedder],
        deny: &DenyList,
        texts: u64,
        now: Instant,
    ) -> Step {
        let models: Vec<String> = embedders.iter().map(|e| e.model()).collect();
        self.chain.sync(&models);
        self.last = Some(now);
        let mut step = Step::default();
        for m in self.chain.probes_due(now) {
            let Some(e) = embedders.iter().find(|e| e.model() == m) else {
                continue;
            };
            match e.embed(&self.ping).await {
                Ok(_) => step.changes.extend(self.chain.answered(&m)),
                Err(err) => step.changes.extend(self.chain.fail(&m, &err.0, now)),
            }
        }
        if !self.chain.any_answering() || !self.timer.due(texts, now) {
            return step;
        }
        let out = fill_chain(
            db,
            embedders,
            deny,
            &mut self.chain,
            now,
            &mut step.changes,
            &mut self.reads,
        )
        .await;
        self.timer.finish(now);
        step.outcome = Some(out);
        step
    }
}

/// The hub's embedder ([`crate::server`]'s tick steps it): the driver, one step at a time, and what `search/embedders`
/// says of the chain.
#[derive(Default)]
pub struct Shared {
    /// None until the first step.
    pub driver: std::sync::Arc<tokio::sync::Mutex<Option<Driver>>>,
    /// The chain as the last step left it: each entry's label and health.
    pub view: std::sync::Mutex<Vec<(Label, Health)>>,
    /// Retry now was asked (`search/embed-retry`): the next tick probes every down embedder.
    pub retry: std::sync::atomic::AtomicBool,
}

/// One entry of the chain as the user reads it: LABEL ("TEI at 127.0.0.1:8080", "the built-in model") and its model.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Label {
    pub model: String,
    pub label: String,
}

/// The Notices row of the chain CHAIN with LABELS: none while every embedder answers; else the first down one, and
/// what takes its place (the next that answers, or search on text alone).
pub fn notice_text(chain: &Chain, labels: &[Label]) -> Option<String> {
    let name = |m: &str| {
        labels
            .iter()
            .find(|l| l.model == m)
            .map_or_else(|| m.to_owned(), |l| l.label.clone())
    };
    let down = chain
        .entries()
        .iter()
        .position(|(_, h)| *h != Health::Answering)?;
    let instead = chain.entries()[down + 1..]
        .iter()
        .find(|(_, h)| *h == Health::Answering)
        .map(|(m, _)| m);
    let first = name(&chain.entries()[down].0);
    Some(match instead {
        Some(m) => format!("Embeddings: {first} is not answering; using {}", name(m)),
        None => format!(
            "Embeddings: {first} is not answering; search falls back to text until it answers"
        ),
    })
}

/// The role's chain in the user's order (Task 192): each step of STEPS that names a server of SERVERS on this machine
/// (by provider id), the local engine (ENGINE: its provider id and the engine, when it may run) or `builtin` (the
/// built-in model, BUILTIN when it is ready), nothing else and nothing reordered; the built-in model goes last only when
/// no step names it and SEARCH_BUILTIN is on. A server elsewhere never gets a place (MP-17: work-graph text goes to no
/// remote source, whatever the role names).
pub fn ordered(
    steps: &[crate::settings::ChainStep],
    servers: Vec<ProviderEmbedder>,
    engine: Option<(&str, std::sync::Arc<dyn Embedder>)>,
    builtin: Option<std::sync::Arc<dyn Embedder>>,
    search_builtin: bool,
) -> Vec<(Label, std::sync::Arc<dyn Embedder>)> {
    let builtin_label = |e: &std::sync::Arc<dyn Embedder>| Label {
        model: e.model(),
        label: "the built-in model".to_owned(),
    };
    let mut servers: Vec<Option<ProviderEmbedder>> = servers
        .into_iter()
        .filter(|s| is_loopback(&s.base))
        .map(Some)
        .collect();
    let mut engine = engine;
    let mut out: Vec<(Label, std::sync::Arc<dyn Embedder>)> = Vec::new();
    let mut placed = false;
    for s in steps {
        if engine.as_ref().is_some_and(|(id, _)| *id == s.provider)
            && let Some((_, e)) = engine.take()
        {
            out.push((
                Label {
                    model: e.model(),
                    label: "the local engine".to_owned(),
                },
                e,
            ));
            continue;
        }
        if s.provider == BUILTIN_STEP {
            if let Some(b) = &builtin
                && !placed
            {
                out.push((builtin_label(b), b.clone()));
            }
            placed = true;
            continue;
        }
        if let Some(e) = servers
            .iter_mut()
            .find(|e| e.as_ref().is_some_and(|e| e.provider() == s.provider))
            .and_then(Option::take)
        {
            let label = format!("{} at {}", e.kind().to_uppercase(), short_base(&e.base));
            out.push((
                Label {
                    model: e.model(),
                    label,
                },
                std::sync::Arc::new(e),
            ));
        }
    }
    if !placed
        && search_builtin
        && let Some(b) = builtin
    {
        out.push((builtin_label(&b), b));
    }
    out
}

/// The step of the embed role that names the built-in model: `(builtin)`.
pub const BUILTIN_STEP: &str = "builtin";

/// BASE without its scheme: `127.0.0.1:8080`.
fn short_base(base: &str) -> &str {
    let rest = base.split_once("://").map_or(base, |(_, r)| r);
    rest.trim_end_matches('/')
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::gateway::Gate;
    use runstav::methods::gateway::ProviderConfig;
    use std::io::{BufRead, BufReader};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};

    /// `ratatoskr-mock`, in the test build's profile folder ([`skuld::profile_dir`]); built once when it is not there,
    /// into the run's own target dir and profile, so a run with `--target-dir` or `--release` finds it.
    pub(crate) fn mock_binary() -> PathBuf {
        skuld::workspace_bin_built("domr", "ratatoskr-mock", None)
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
    async fn tei(dir: &Path, port: u16) -> (Gate, ProviderEmbedder) {
        let gate = Gate::new(CoordDb::spawn(dir.join("gw.db")));
        let table: Vec<ProviderConfig> = serde_json::from_value(json!([
            {"id": "tei", "kind": "tei", "base": format!("http://127.0.0.1:{port}"), "auth": "none",
             "messages": false, "caps": ["embed"]}]))
        .unwrap();
        gate.apply(&table).unwrap();
        gate.listen(None).await.unwrap();
        let e = gate.embedders(&[]).unwrap().remove(0);
        // the scripted mock answers vectors only (no `/info`): the embedder is given the identity a probe would make
        e.seed(Identity::new(
            FingerprintRecord {
                model_id: "scripted".into(),
                weights_sha256: String::new(),
                quant: String::new(),
                pooling: Pooling::Unknown,
                normalized: true,
                dims: 4,
                max_tokens: 512,
                doc_prefix: String::new(),
                query_template: QUERY_TEMPLATE.into(),
                embed_text_version: crate::search::EMBED_TEXT_VERSION,
            },
            "scripted",
        ));
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
        let model = Embedder::model(&e);
        assert_eq!(model.len(), 64, "the vectors are keyed by a fingerprint");
        let stale = db
            .read(move |c| Ok(vec_stale(c, &model, 10)?))
            .await
            .unwrap();
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

        fn model(&self) -> String {
            "fake".to_owned()
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
    fn a_round_starts_after_a_quiet_minute() {
        let t0 = Instant::from_std(skuld::origin());
        let mut t = Timer::new(t0);
        assert!(!t.due(0, t0 + IDLE / 2));
        assert!(t.due(0, t0 + IDLE));
        // one round at a time
        assert!(!t.due(0, t0 + IDLE * 3));
        t.finish(t0 + IDLE * 3);
        // a write restarts the quiet minute
        assert!(!t.due(5, t0 + IDLE * 5));
        assert!(!t.due(5, t0 + IDLE * 5 + IDLE / 2));
        assert!(t.due(5, t0 + IDLE * 6 + IDLE));
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

    /// One run of housekeeping at unix time NOW, as the front writes it: `coord/leases` (agent-a renewed, stale leases
    /// released), then `coord/prune`.
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
        let t0 = Instant::from_std(skuld::origin());
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
            t.finish(now);
        }
    }

    /// A write that puts text (a new entity, a changed title) restarts the quiet minute; the housekeeping between them
    /// does not.
    #[tokio::test]
    async fn a_content_write_restarts_the_quiet_minute() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        claimed_job(&db).await;
        let t0 = Instant::from_std(skuld::origin());
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

    // ---- the chain (Task 192): fallback in the user's order, backoff per embedder, nothing done while all are down ----

    /// An embedder of the chain whose answers the test turns on and off: its vectors are `Fake`'s, and it keeps the
    /// virtual time of each call (set by the test) and the texts of each.
    struct Toy {
        model: String,
        up: std::sync::atomic::AtomicBool,
        calls: std::sync::Mutex<Vec<(Instant, Vec<String>)>>,
        at: std::sync::Mutex<Instant>,
    }

    impl Toy {
        fn new(model: &str, up: bool) -> Toy {
            Toy {
                model: model.to_owned(),
                up: std::sync::atomic::AtomicBool::new(up),
                calls: Default::default(),
                at: std::sync::Mutex::new(Instant::from_std(skuld::origin())),
            }
        }

        fn set_up(&self, up: bool) {
            self.up.store(up, std::sync::atomic::Ordering::SeqCst);
        }

        /// The virtual time of each call.
        fn times(&self) -> Vec<Instant> {
            self.calls.lock().unwrap().iter().map(|c| c.0).collect()
        }

        fn texts(&self) -> Vec<Vec<String>> {
            self.calls
                .lock()
                .unwrap()
                .iter()
                .map(|c| c.1.clone())
                .collect()
        }
    }

    impl Embedder for Toy {
        fn embed<'a>(
            &'a self,
            texts: &'a [String],
        ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
            Box::pin(async move {
                let at = *self.at.lock().unwrap();
                self.calls.lock().unwrap().push((at, texts.to_vec()));
                if self.up.load(std::sync::atomic::Ordering::SeqCst) {
                    Ok(texts.iter().map(|t| Fake::vector(t)).collect())
                } else {
                    Err(EmbedError(format!(
                        "{} answered 502: connection refused",
                        self.model
                    )))
                }
            })
        }

        fn model(&self) -> String {
            self.model.clone()
        }
    }

    /// The models that have vectors, with how many.
    async fn models_of_vectors(db: &CoordDb) -> Vec<(String, i64)> {
        db.read(|c| {
            let mut st =
                c.prepare("select model, count(*) from entity_vec group by model order by model")?;
            let rows = st
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .unwrap()
    }

    /// The hub's tick, as `server::embed_idle` runs it: every 2 s of virtual time from FROM to UNTIL, a step when the
    /// driver wants one.  Each embedder's clock is set to the step's time first.  The steps' changes, in order.
    async fn ticks(
        d: &mut Driver,
        db: &CoordDb,
        chain: &[&Toy],
        deny: &DenyList,
        texts: u64,
        from: Instant,
        until: Instant,
    ) -> Vec<Change> {
        let each: Vec<&dyn Embedder> = chain.iter().map(|t| *t as &dyn Embedder).collect();
        let mut changes = Vec::new();
        let mut now = from;
        while now <= until {
            if d.wants(now, false) {
                for t in chain {
                    *t.at.lock().unwrap() = now;
                }
                changes.extend(d.step(db, &each, deny, texts, now).await.changes);
            }
            now += crate::server::SCHEMA_TICK;
        }
        changes
    }

    const MIN: Duration = Duration::from_secs(60);

    #[tokio::test]
    async fn a_down_provider_falls_through_to_the_next_in_the_users_order() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        for (id, title) in [("task:a", "one"), ("task:b", "two"), ("task:c", "three")] {
            put(&db, id, None, title, json!({})).await;
        }
        let (tei, builtin) = (Toy::new("tei:tei", false), Toy::new("builtin", true));
        let mut chain = Chain::default();
        chain.sync(&["tei:tei".to_owned(), "builtin".to_owned()]);
        let mut changes = Vec::new();
        let mut reads = 0;
        let now = Instant::from_std(skuld::origin());
        let out = fill_chain(
            &db,
            &[&tei, &builtin],
            &allow_all(dir.path()),
            &mut chain,
            now,
            &mut changes,
            &mut reads,
        )
        .await;
        assert_eq!(
            out,
            Outcome::Filled {
                embedded: 3,
                denied: 0
            }
        );
        // the same batch, in the same round: TEI was asked first, then the built-in model with the same texts, and
        // the store was read for it once (the stale list and the rows, then the empty stale list that ends the round)
        assert_eq!(reads, 3);
        assert_eq!(tei.texts().len(), 1);
        assert_eq!(builtin.texts(), tei.texts());
        assert_eq!(models_of_vectors(&db).await, [("builtin".to_owned(), 3)]);
        assert_eq!(
            changes,
            [Change::Down {
                model: "tei:tei".into(),
                why: "tei:tei answered 502: connection refused".into()
            }]
        );
        assert!(!chain.answering("tei:tei") && chain.answering("builtin"));
    }

    #[test]
    fn the_chain_is_never_reordered_or_extended() {
        let server = |id: &str| {
            ProviderEmbedder::tei(1, "t".into(), id, &format!("http://127.0.0.1:80{id}"))
        };
        let servers = || vec![server("b"), server("a"), server("c")];
        let builtin: std::sync::Arc<dyn Embedder> = std::sync::Arc::new(Toy::new("builtin", true));
        let step = |p: &str| crate::settings::ChainStep {
            provider: p.into(),
            model: None,
        };
        let models = |steps: &[crate::settings::ChainStep], on: bool| {
            ordered(steps, servers(), None, Some(builtin.clone()), on)
                .into_iter()
                .map(|(l, e)| {
                    assert_eq!(l.model, e.model());
                    l.model
                })
                .collect::<Vec<_>>()
        };
        // [a, b] with search_builtin off: those two, in that order; c and the built-in model never
        // (a server that has not answered a probe yet is known as `unprobed:<provider>`)
        assert_eq!(
            models(&[step("a"), step("b")], false),
            ["unprobed:a", "unprobed:b"]
        );
        // the user put the built-in model between them: there it stays, whatever search_builtin says
        let mid = [step("b"), step("builtin"), step("a")];
        assert_eq!(models(&mid, false), ["unprobed:b", "builtin", "unprobed:a"]);
        assert_eq!(models(&mid, true), ["unprobed:b", "builtin", "unprobed:a"]);
        // search_builtin adds it last only when no step names it
        assert_eq!(models(&[step("a")], true), ["unprobed:a", "builtin"]);
        // an unknown step adds nothing
        assert_eq!(models(&[step("nope"), step("c")], false), ["unprobed:c"]);
        let labels = ordered(&mid, servers(), None, Some(builtin.clone()), false);
        assert_eq!(labels[0].0.label, "TEI at 127.0.0.1:80b");
        assert_eq!(labels[1].0.label, "the built-in model");
    }

    #[test]
    fn default_embed_role_is_llama() {
        let d = crate::settings::defaults();
        let chain = crate::settings::providers::role_chain(&[], &d.roles, "embed");
        let names: Vec<&str> = chain.iter().map(|s| s.provider.as_str()).collect();
        assert_eq!(names, ["llama"]);
        let kind = |id: &str| d.presets.iter().find(|p| p.id == id).and_then(|p| p.kind);
        assert_eq!(
            kind("llama"),
            Some(runstav::methods::gateway::ProviderKind::Llama)
        );
        assert_eq!(
            kind("tei"),
            Some(runstav::methods::gateway::ProviderKind::Tei),
            "TEI stays a provider"
        );
        let llama = d.presets.iter().find(|p| p.id == "llama").unwrap();
        assert_eq!(llama.url, None, "the engine has no URL");
        assert_eq!(llama.caps, ["embed"]);
    }

    /// MP-17: the entity chain is the local engine, the built-in model and servers on this machine; a server elsewhere
    /// (a remote source) never gets a place in it, whatever the role names.
    #[test]
    fn entity_chain_has_no_remote_vectors_source() {
        let near = ProviderEmbedder::tei(1, "t".into(), "near", "http://127.0.0.1:8080");
        let far = ProviderEmbedder::tei(1, "t".into(), "far", "https://vectors.example.com");
        let engine: std::sync::Arc<dyn Embedder> = std::sync::Arc::new(Toy::new("engine", true));
        let builtin: std::sync::Arc<dyn Embedder> = std::sync::Arc::new(Toy::new("builtin", true));
        let step = |p: &str| crate::settings::ChainStep {
            provider: p.into(),
            model: None,
        };
        let steps = [step("far"), step("llama"), step("near"), step("builtin")];
        let got: Vec<String> = ordered(
            &steps,
            vec![far, near],
            Some(("llama", engine)),
            Some(builtin),
            false,
        )
        .into_iter()
        .map(|(l, _)| l.model)
        .collect();
        assert_eq!(got, ["engine", "unprobed:near", "builtin"]);
    }

    #[tokio::test]
    async fn backoff_is_1_5_30_min_then_6_h_on_the_virtual_clock() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        put(&db, "task:a", None, "one", json!({})).await;
        let tei = Toy::new("tei:tei", false);
        let t0 = Instant::from_std(skuld::origin());
        let mut d = Driver::new(t0);
        let deny = allow_all(dir.path());
        ticks(&mut d, &db, &[&tei], &deny, 0, t0, t0 + MIN * 60 * 13).await;
        let times = tei.times();
        // the first round after a quiet minute fails at F; then one text each wait: 1, 5, 30 min, then every 6 h
        let f = times[0];
        assert_eq!(f, t0 + MIN);
        let waits: Vec<Duration> = times.windows(2).map(|w| w[1] - w[0]).collect();
        assert_eq!(
            waits,
            [MIN, MIN * 5, MIN * 30, MIN * 360, MIN * 360],
            "{times:?}"
        );
        // each probe is one text
        assert!(tei.texts()[1..].iter().all(|t| t.len() == 1));
    }

    #[tokio::test]
    async fn an_answer_resets_the_backoff_and_the_preferred_model_takes_over() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        put(&db, "task:a", None, "one", json!({})).await;
        put(&db, "task:b", None, "two", json!({})).await;
        let (tei, builtin) = (Toy::new("tei:tei", false), Toy::new("builtin", true));
        let t0 = Instant::from_std(skuld::origin());
        let mut d = Driver::new(t0);
        let deny = allow_all(dir.path());
        // TEI down: the built-in model fills; its probes at +1 and +6 min fail
        ticks(&mut d, &db, &[&tei, &builtin], &deny, 0, t0, t0 + MIN * 3).await;
        assert_eq!(models_of_vectors(&db).await, [("builtin".to_owned(), 2)]);
        tei.set_up(true);
        let changes = ticks(
            &mut d,
            &db,
            &[&tei, &builtin],
            &deny,
            0,
            t0 + MIN * 3,
            t0 + MIN * 10,
        )
        .await;
        // it answered the probe at +7 min (1 + 1 + 5): it is back, and the same step's round filled its own vectors
        assert_eq!(
            changes,
            [Change::Up {
                model: "tei:tei".into()
            }]
        );
        assert_eq!(tei.times()[2], t0 + MIN * 7);
        assert_eq!(
            models_of_vectors(&db).await,
            [("builtin".to_owned(), 2), ("tei:tei".to_owned(), 2)]
        );
        // it fails again: the wait starts over at 1 minute, not 30
        tei.set_up(false);
        put(&db, "task:c", None, "three", json!({})).await;
        let n = tei.times().len();
        ticks(
            &mut d,
            &db,
            &[&tei, &builtin],
            &deny,
            1,
            t0 + MIN * 10,
            t0 + MIN * 20,
        )
        .await;
        let times = tei.times();
        assert_eq!(times[n + 1] - times[n], MIN, "{times:?}");
    }

    #[tokio::test]
    async fn all_down_does_no_record_work() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        for i in 0..10 {
            put(
                &db,
                &format!("task:e{i}"),
                None,
                &format!("text {i}"),
                json!({}),
            )
            .await;
        }
        let (a, b) = (Toy::new("tei:a", false), Toy::new("ollama:b:m", false));
        let t0 = Instant::from_std(skuld::origin());
        let mut d = Driver::new(t0);
        let deny = allow_all(dir.path());
        // the first round reads its batch and both fail it
        ticks(&mut d, &db, &[&a, &b], &deny, 0, t0, t0 + MIN).await;
        let read = d.reads();
        assert!(read > 0);
        assert!(!d.chain().any_answering());
        // 60 virtual minutes with every embedder down: the probes only, no store read
        ticks(&mut d, &db, &[&a, &b], &deny, 0, t0 + MIN, t0 + MIN * 61).await;
        assert_eq!(d.reads(), read, "record work while every embedder was down");
        // the probes: the round, then +1, +6 and +36 min, each one text
        assert_eq!(a.times().len(), 4);
        assert_eq!(b.times().len(), 4);
    }

    #[tokio::test]
    async fn one_log_line_per_state_change() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        put(&db, "task:a", None, "one", json!({})).await;
        let tei = Toy::new("tei:tei", false);
        let t0 = Instant::from_std(skuld::origin());
        let mut d = Driver::new(t0);
        let deny = allow_all(dir.path());
        // 60 failing minutes: one change (it went down), whatever the probes
        let changes = ticks(&mut d, &db, &[&tei], &deny, 0, t0, t0 + MIN * 61).await;
        assert_eq!(changes.len(), 1, "{changes:?}");
        assert!(tei.times().len() > 1);
        let labels = [Label {
            model: "tei:tei".into(),
            label: "TEI at 127.0.0.1:8080".into(),
        }];
        assert_eq!(
            notice_text(d.chain(), &labels).as_deref(),
            Some(
                "Embeddings: TEI at 127.0.0.1:8080 is not answering; search falls back to text until it answers"
            )
        );
    }

    #[tokio::test]
    async fn retry_now_probes_at_once() {
        let dir = tempfile::tempdir().unwrap();
        let db = CoordDb::spawn(dir.path().join("work.db"));
        put(&db, "task:a", None, "one", json!({})).await;
        let tei = Toy::new("tei:tei", false);
        let t0 = Instant::from_std(skuld::origin());
        let mut d = Driver::new(t0);
        let deny = allow_all(dir.path());
        ticks(&mut d, &db, &[&tei], &deny, 0, t0, t0 + MIN * 2).await;
        assert_eq!(tei.times().len(), 2); // the round at +1, the probe at +2
        // 10 s later the next wait is 5 minutes away; Retry now asks at the next tick
        let at = t0 + MIN * 2 + Duration::from_secs(10);
        assert!(!d.wants(at, false));
        assert!(d.wants(at, true));
        d.retry_now(at);
        *tei.at.lock().unwrap() = at;
        d.step(&db, &[&tei], &deny, 0, at).await;
        assert_eq!(tei.times().last(), Some(&at));
    }

    /// The perf row `embed-idle-dead-provider`: the hub's embedder over 10 virtual minutes with the only provider (a TEI
    /// that refuses, through the gateway) down costs under its budget of one percent of one core's CPU.
    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn embed_idle_dead_provider() {
        // the budget the Lisp era kept in test/perf/budgets.eld (gone with it)
        let pct: f64 = 1.0;
        let dir = tempfile::tempdir().unwrap();
        let port = {
            let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            l.local_addr().unwrap().port()
        };
        let (_gate, e) = tei(dir.path(), port).await;
        let db = CoordDb::spawn(dir.path().join("work.db"));
        for i in 0..300 {
            put(
                &db,
                &format!("task:e{i:03}"),
                None,
                &format!("text {i:03}"),
                json!({}),
            )
            .await;
        }
        let deny = allow_all(dir.path());
        let t0 = Instant::from_std(skuld::origin());
        let mut d = Driver::new(t0);
        let span = MIN * 10;
        let cpu = || {
            let mut r = std::mem::MaybeUninit::<libc::rusage>::uninit();
            // SAFETY: getrusage fills the struct it is given
            unsafe { libc::getrusage(libc::RUSAGE_THREAD, r.as_mut_ptr()) };
            // SAFETY: filled above
            let r = unsafe { r.assume_init() };
            let us = |t: libc::timeval| t.tv_sec as f64 * 1e6 + t.tv_usec as f64;
            Duration::from_micros((us(r.ru_utime) + us(r.ru_stime)) as u64)
        };
        let before = cpu();
        let mut now = t0;
        while now <= t0 + span {
            if d.wants(now, false) {
                d.step(&db, &[&e], &deny, 0, now).await;
            }
            now += crate::server::SCHEMA_TICK;
        }
        let used = cpu() - before;
        assert!(!d.chain().any_answering(), "the provider is down");
        let share = used.as_secs_f64() / span.as_secs_f64() * 100.0;
        assert!(
            share < pct,
            "embed-idle-dead-provider: {share:.3} % of one core over 10 virtual minutes (budget {pct} %)"
        );
    }
}
