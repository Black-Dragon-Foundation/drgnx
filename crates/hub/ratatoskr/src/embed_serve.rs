//! `ratatoskr embed serve`: this machine's vector cache and embedders behind the vector protocol v1 (Hrafn redesign §8,
//! MP-9, MP-10; `docs/develop/vector-protocol.md`).
//!
//! - **The protocol.** `GET /v1/info` names the fingerprints served, whether this server embeds, and its limits.
//!   `POST /v1/lookup` answers keys with vectors from the cache and never receives a text. `POST /v1/embed` embeds the
//!   texts it is sent with this machine's chain (the engine or the built-in model), adds them to the cache and answers
//!   them; every item's key must be the key of its text (`KeyKind::key`), or nothing of the request is embedded
//!   (`422 key-mismatch`), so a client cannot put a vector into the cache under another text's key. Vectors travel in
//!   the stored quantised form (`bits`, `vec` base64, `scale`), so a lookup moves rows unchanged.
//! - **Access.** Every request carries `Authorization: Bearer TOKEN`. The server keeps only the token's sha256
//!   (`<state>/embed-serve/token.sha256`, 0600) and compares in constant time; `--new-token` replaces it and the old one
//!   is refused from the next request. Neither the token nor any text is logged.
//! - **Transport.** TLS with a self-signed certificate made once (`cert.der`, `key.der`, 0600), which the client pins on
//!   first use; plain HTTP only on loopback or a Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48).

use crate::search::DocEmbedder;
use crate::search::caches::Caches;
use hrafn::{KeyKind, QuantRow};
use hrafn_embed::fingerprint::Identity;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use urdr::graph::search::BoxFuture;

/// The protocol's version.
pub const VERSION: u32 = 1;
/// The most keys or items one request carries.
pub const MAX_BATCH: u32 = 64;
/// The longest text `/v1/embed` takes, in tokens (the engine's context).
pub const MAX_TOKENS: u32 = 8192;
/// The largest request body, in bytes.
pub const MAX_BODY: usize = 8 << 20;

/// The spend row's agent for an embed this hub served to a peer.
pub const SERVED: &str = "embed-serve";

/// One embed request of TEXTS to PROVIDER as a spend row (MP-9: embeds are spend, lookups are free). The protocol
/// carries no token counts, so `input` is estimated at four bytes a token; no price is known, so `cost` is 0.
pub fn spend_row(
    provider: &str,
    agent: &str,
    model: &str,
    texts: &[&str],
) -> bifrost::engine::SpendRow {
    bifrost::engine::SpendRow {
        agent: Some(agent.to_owned()),
        provider: provider.to_owned(),
        model: Some(model.to_owned()),
        input: texts.iter().map(|t| t.len().div_ceil(4) as u64).sum(),
        status: 200,
        ..Default::default()
    }
}

/// `GET /v1/info`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Info {
    pub version: u32,
    pub fingerprints: Vec<InfoFingerprint>,
    pub embed: bool,
    pub max_batch: u32,
    pub max_tokens: u32,
}

/// One fingerprint served: its hex and its record (the JSON `FingerprintRecord::to_json` writes).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InfoFingerprint {
    pub hex: String,
    pub record: serde_json::Value,
}

/// Which table a key is of.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WireKind {
    Chunk,
    Path,
}

impl WireKind {
    pub fn key_kind(self) -> KeyKind {
        match self {
            WireKind::Chunk => KeyKind::Chunk,
            WireKind::Path => KeyKind::Path,
        }
    }

    pub fn of(kind: KeyKind) -> WireKind {
        match kind {
            KeyKind::Chunk => WireKind::Chunk,
            KeyKind::Path => WireKind::Path,
        }
    }
}

/// A vector in the stored form.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WireVec {
    pub bits: u8,
    /// The stored bytes, base64.
    pub vec: String,
    pub scale: f64,
}

/// `POST /v1/lookup`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LookupRequest {
    pub fingerprint: String,
    pub kind: WireKind,
    /// Keys, hex.
    pub keys: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LookupAnswer {
    pub found: BTreeMap<String, WireVec>,
}

/// One text to embed under its key.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EmbedItem {
    pub key: String,
    pub text: String,
}

/// `POST /v1/embed`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EmbedRequest {
    pub fingerprint: String,
    pub kind: WireKind,
    pub items: Vec<EmbedItem>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EmbedAnswer {
    pub vectors: BTreeMap<String, WireVec>,
}

/// A key as the wire has it: 64 lower-case hex characters.
pub fn key_hex(k: &[u8; 32]) -> String {
    k.iter().map(|b| format!("{b:02x}")).collect()
}

/// A wire key back; none for anything but 64 hex characters.
pub fn key_of(hex: &str) -> Option<[u8; 32]> {
    if hex.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(hex.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(out)
}

/// A stored row as the wire has it.
pub fn wire_vec(r: &QuantRow) -> WireVec {
    use base64::Engine as _;
    WireVec {
        bits: r.bits,
        vec: base64::engine::general_purpose::STANDARD.encode(&r.vec),
        scale: r.scale,
    }
}

/// A wire vector back as KEY's stored row; none when its bytes are not base64.
pub fn quant_row(key: [u8; 32], v: &WireVec) -> Option<QuantRow> {
    use base64::Engine as _;
    Some(QuantRow {
        key,
        bits: v.bits,
        vec: base64::engine::general_purpose::STANDARD
            .decode(&v.vec)
            .ok()?,
        scale: v.scale,
    })
}

/// Whether plain HTTP may be served on IP: loopback, or a Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48), where
/// the tunnel is the encryption (MP-10).
pub fn plain_allowed(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_loopback() || (o[0] == 100 && (o[1] & 0xC0) == 64)
        }
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => plain_allowed(IpAddr::V4(v4)),
            None => v6.is_loopback() || v6.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0],
        },
    }
}

/// What a server answers from: this machine's cache and its embedders.
pub trait Serve: Send + Sync {
    /// The fingerprints it serves.
    fn fingerprints(&self) -> BoxFuture<'_, Vec<Identity>>;
    /// The stored rows of those of KEYS it has, of fingerprint FP.
    fn lookup<'a>(
        &'a self,
        fp: &'a str,
        kind: KeyKind,
        keys: &'a [[u8; 32]],
    ) -> BoxFuture<'a, Result<Vec<QuantRow>, String>>;
    /// Whether it can embed for fingerprint FP.
    fn embeds<'a>(&'a self, fp: &'a str) -> BoxFuture<'a, bool>;
    /// ITEMS' texts embedded (their keys checked by the caller), added to the cache, and answered as stored.
    fn embed<'a>(
        &'a self,
        fp: &'a str,
        kind: KeyKind,
        items: &'a [([u8; 32], String)],
    ) -> BoxFuture<'a, Result<Vec<QuantRow>, String>>;
}

/// The hub's [`Serve`]: the state's caches, and the embedders that may fill them (the engine, the built-in model).
pub struct CacheServe {
    caches: Arc<Caches>,
    embedders: Vec<Arc<dyn DocEmbedder>>,
    /// Where a served embed is counted (the hub's `spend` table); none: not counted.
    ledger: Option<Arc<dyn bifrost::engine::Ledger>>,
}

impl CacheServe {
    pub fn new(caches: Arc<Caches>, embedders: Vec<Arc<dyn DocEmbedder>>) -> CacheServe {
        CacheServe {
            caches,
            embedders,
            ledger: None,
        }
    }

    /// Every embed served is a spend row in LEDGER (provider and agent [`SERVED`]).
    #[must_use]
    pub fn with_ledger(mut self, ledger: Arc<dyn bifrost::engine::Ledger>) -> CacheServe {
        self.ledger = Some(ledger);
        self
    }

    /// The identity of EMBEDDER: what it last proved, else what it answers now.
    async fn identity_of(e: &Arc<dyn DocEmbedder>) -> Option<Identity> {
        match e.identity() {
            Some(id) => Some(id),
            None => e.probe().await.ok(),
        }
    }

    /// The embedder that answers for FP.
    async fn embedder(&self, fp: &str) -> Option<(Arc<dyn DocEmbedder>, Identity)> {
        for e in &self.embedders {
            if let Some(id) = Self::identity_of(e).await
                && id.fp.hex() == fp
            {
                return Some((e.clone(), id));
            }
        }
        None
    }
}

impl Serve for CacheServe {
    fn fingerprints(&self) -> BoxFuture<'_, Vec<Identity>> {
        Box::pin(async move {
            let mut out = self.caches.stored();
            for e in &self.embedders {
                if let Some(id) = Self::identity_of(e).await
                    && !out.iter().any(|o| o.fp == id.fp)
                {
                    out.push(id);
                }
            }
            out
        })
    }

    fn lookup<'a>(
        &'a self,
        fp: &'a str,
        kind: KeyKind,
        keys: &'a [[u8; 32]],
    ) -> BoxFuture<'a, Result<Vec<QuantRow>, String>> {
        Box::pin(async move {
            let Some(id) = self
                .fingerprints()
                .await
                .into_iter()
                .find(|i| i.fp.hex() == fp)
            else {
                return Err(UNKNOWN_FP.into());
            };
            let cache = self.caches.get(&id).await.map_err(|e| e.to_string())?;
            cache.get(kind, keys).await.map_err(|e| e.to_string())
        })
    }

    fn embeds<'a>(&'a self, fp: &'a str) -> BoxFuture<'a, bool> {
        Box::pin(async move { self.embedder(fp).await.is_some() })
    }

    fn embed<'a>(
        &'a self,
        fp: &'a str,
        kind: KeyKind,
        items: &'a [([u8; 32], String)],
    ) -> BoxFuture<'a, Result<Vec<QuantRow>, String>> {
        Box::pin(async move {
            let Some((e, id)) = self.embedder(fp).await else {
                return Err(UNKNOWN_FP.into());
            };
            let texts: Vec<String> = items.iter().map(|(_, t)| t.clone()).collect();
            let vecs = e.embed_docs(&texts, false).await.map_err(|e| e.0)?;
            if let Some(l) = &self.ledger {
                let texts: Vec<&str> = texts.iter().map(String::as_str).collect();
                l.record(spend_row(SERVED, SERVED, &id.record.model_id, &texts))
                    .await;
            }
            let dims = id.record.dims;
            if vecs.len() != items.len() || vecs.iter().any(|v| v.len() != dims as usize) {
                return Err(format!(
                    "the embedder answered other than {} vectors of {dims} dims",
                    items.len()
                ));
            }
            let rows: Vec<([u8; 32], Vec<f32>)> = items.iter().map(|(k, _)| *k).zip(vecs).collect();
            let cache = self.caches.get(&id).await.map_err(|e| e.to_string())?;
            cache
                .put(kind, dims, &rows)
                .await
                .map_err(|e| e.to_string())?;
            let keys: Vec<[u8; 32]> = items.iter().map(|(k, _)| *k).collect();
            cache.get(kind, &keys).await.map_err(|e| e.to_string())
        })
    }
}

/// `ratatoskr embed serve …`.
#[derive(Debug, PartialEq, Eq)]
pub enum EmbedCommand {
    Start {
        listen: String,
        plain: bool,
        no_embed: bool,
    },
    Stop,
    NewToken,
}

/// The arguments after `embed`.
pub fn parse(args: impl IntoIterator<Item = std::ffi::OsString>) -> Result<EmbedCommand, String> {
    use lexopt::Arg::{Long, Value as Word};
    use lexopt::ValueExt;
    const USE: &str =
        "embed serve --listen ADDR:PORT [--plain] [--no-embed] | --stop | --new-token";
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| e.to_string();
    match p.next().map_err(e)? {
        Some(Word(v)) if v == "serve" => {}
        _ => return Err(format!("usage: ratatoskr {USE}")),
    }
    let (mut listen, mut plain, mut no_embed, mut stop, mut new_token) =
        (None, false, false, false, false);
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("listen") => listen = Some(p.value().map_err(e)?.string().map_err(e)?),
            Long("plain") => plain = true,
            Long("no-embed") => no_embed = true,
            Long("stop") => stop = true,
            Long("new-token") => new_token = true,
            other => return Err(other.unexpected().to_string()),
        }
    }
    match (listen, stop, new_token) {
        (Some(listen), false, false) => Ok(EmbedCommand::Start {
            listen,
            plain,
            no_embed,
        }),
        (None, true, false) if !plain && !no_embed => Ok(EmbedCommand::Stop),
        (None, false, true) if !plain && !no_embed => Ok(EmbedCommand::NewToken),
        _ => Err(format!("usage: ratatoskr {USE}")),
    }
}

/// One call to the running hub; prints what it answered (the token only when it is new).
pub fn run(env: &runstav::paths::Env, cmd: EmbedCommand) -> i32 {
    let hub = crate::supervise::ensure_quiet(env, crate::cli::ENSURE_TIMEOUT);
    if hub != 0 {
        return hub;
    }
    let (method, params) = match &cmd {
        EmbedCommand::Start {
            listen,
            plain,
            no_embed,
        } => (
            "embed/serve-start",
            serde_json::json!({"listen": listen, "plain": plain, "no_embed": no_embed}),
        ),
        EmbedCommand::Stop => ("embed/serve-stop", serde_json::json!({})),
        EmbedCommand::NewToken => ("embed/serve-token", serde_json::json!({})),
    };
    let answer = crate::client::Client::user(env, std::time::Duration::from_secs(5))
        .and_then(|mut c| c.call(method, params, std::time::Duration::from_secs(30)));
    let a = match answer {
        Ok(a) => a,
        Err(e) => {
            eprintln!("ratatoskr embed serve: {e}");
            return 1;
        }
    };
    let text = |k: &str| a.get(k).and_then(serde_json::Value::as_str);
    match cmd {
        EmbedCommand::Start { .. } => {
            println!("serving on {}", text("url").unwrap_or_default());
            if let Some(c) = text("cert_sha256") {
                println!("certificate sha256 {c} (the client pins it on first use)");
            }
            match text("token") {
                Some(t) => println!("token {t}\n(shown once: put it in the client's key_env)"),
                None => println!(
                    "the token is the one shown before (embed serve --new-token makes another)"
                ),
            }
        }
        EmbedCommand::Stop => println!(
            "{}",
            if a.as_bool() == Some(true) {
                "stopped"
            } else {
                "no vector server was running"
            }
        ),
        EmbedCommand::NewToken => {
            println!(
                "token {}\n(shown once; the old one is refused from now)",
                text("token").unwrap_or_default()
            );
        }
    }
    0
}

/// What a fingerprint this server does not serve is answered with.
const UNKNOWN_FP: &str = "unknown-fingerprint";

/// How to serve.
#[derive(Clone, Debug)]
pub struct ServeSpec {
    pub listen: SocketAddr,
    /// Plain HTTP (loopback or Tailscale only).
    pub plain: bool,
    /// Lookups only: `/v1/embed` is refused.
    pub no_embed: bool,
    /// `<state>/embed-serve/`: the token's sha256 and the certificate.
    pub dir: PathBuf,
}

/// A running server.
pub struct Running {
    url: String,
    cert_sha256: Option<String>,
    dir: PathBuf,
    token_sha: Arc<Mutex<[u8; 32]>>,
    task: tokio::task::JoinHandle<()>,
}

impl Running {
    /// `https://ADDR:PORT` (or `http://` when plain), with the port bound.
    pub fn url(&self) -> &str {
        &self.url
    }

    /// The certificate's sha256, hex (none when plain).
    pub fn cert_sha256(&self) -> Option<&str> {
        self.cert_sha256.as_deref()
    }

    /// A new token, shown once: the old one is refused from the next request.
    pub fn new_token(&self) -> std::io::Result<String> {
        let (token, sha) = mint_token(&self.dir)?;
        *self.token_sha.lock().unwrap_or_else(|p| p.into_inner()) = sha;
        Ok(token)
    }

    /// Stops listening; requests in flight end with their connections.
    pub fn stop(self) {
        self.task.abort();
    }
}

/// The file that keeps the token's sha256.
const TOKEN_FILE: &str = "token.sha256";

fn sha256(b: &[u8]) -> [u8; 32] {
    let d = ring::digest::digest(&ring::digest::SHA256, b);
    let mut out = [0u8; 32];
    out.copy_from_slice(d.as_ref());
    out
}

/// BYTES written to DIR/NAME, 0600, replacing it whole (a new file renamed over the old).
fn write_private(dir: &Path, name: &str, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    let tmp = dir.join(format!(".{name}.new"));
    let _ = std::fs::remove_file(&tmp);
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    std::fs::rename(&tmp, dir.join(name))
}

/// A new token (32 random bytes, hex), its sha256 kept in DIR.
fn mint_token(dir: &Path) -> std::io::Result<(String, [u8; 32])> {
    use ring::rand::SecureRandom as _;
    let mut raw = [0u8; 32];
    ring::rand::SystemRandom::new()
        .fill(&mut raw)
        .map_err(|_| std::io::Error::other("no random bytes"))?;
    let token = key_hex(&raw);
    let sha = sha256(token.as_bytes());
    write_private(dir, TOKEN_FILE, format!("{}\n", key_hex(&sha)).as_bytes())?;
    Ok((token, sha))
}

/// The certificate and key in DIR, made once (self-signed, for the names `localhost` and the address served).
fn certificate(
    dir: &Path,
    ip: IpAddr,
) -> Result<
    (
        rustls::pki_types::CertificateDer<'static>,
        rustls::pki_types::PrivateKeyDer<'static>,
    ),
    String,
> {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
    let (cert, key) = (dir.join("cert.der"), dir.join("key.der"));
    if !(cert.exists() && key.exists()) {
        let made = rcgen::generate_simple_self_signed(vec!["localhost".to_owned(), ip.to_string()])
            .map_err(|e| format!("the certificate: {e}"))?;
        write_private(dir, "key.der", &made.signing_key.serialize_der())
            .and_then(|()| write_private(dir, "cert.der", made.cert.der()))
            .map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    let read = |p: &Path| std::fs::read(p).map_err(|e| format!("{}: {e}", p.display()));
    Ok((
        CertificateDer::from(read(&cert)?),
        PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(read(&key)?)),
    ))
}

/// What every connection shares.
struct Shared {
    serve: Arc<dyn Serve>,
    no_embed: bool,
    token_sha: Arc<Mutex<[u8; 32]>>,
}

/// Starts serving SERVE as SPEC says: the URL, the certificate's sha256 and, the first time (no token kept yet), the
/// token. Err: plain HTTP on an address that is neither loopback nor Tailscale, or the address cannot be bound.
pub async fn start(
    spec: ServeSpec,
    serve: Arc<dyn Serve>,
) -> Result<(Running, Option<String>), String> {
    if spec.plain && !plain_allowed(spec.listen.ip()) {
        return Err(format!(
            "plain HTTP is served only on loopback or a Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48), not {}; \
             leave out --plain for TLS",
            spec.listen.ip()
        ));
    }
    let listener = crate::clock::real(tokio::net::TcpListener::bind(spec.listen))
        .await
        .map_err(|e| format!("{}: {e}", spec.listen))?;
    let addr = listener.local_addr().map_err(|e| e.to_string())?;
    {
        use std::os::unix::fs::DirBuilderExt as _;
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&spec.dir)
            .map_err(|e| format!("{}: {e}", spec.dir.display()))?;
    }
    let kept = std::fs::read_to_string(spec.dir.join(TOKEN_FILE))
        .ok()
        .and_then(|t| key_of(t.trim()));
    let (token_sha, token) = match kept {
        Some(sha) => (sha, None),
        None => {
            let (t, sha) =
                mint_token(&spec.dir).map_err(|e| format!("{}: {e}", spec.dir.display()))?;
            (sha, Some(t))
        }
    };
    let (acceptor, cert_sha256) = if spec.plain {
        (None, None)
    } else {
        let (cert, key) = certificate(&spec.dir, addr.ip())?;
        let fp = key_hex(&sha256(cert.as_ref()));
        let config = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .map_err(|e| e.to_string())?
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .map_err(|e| format!("the certificate: {e}"))?;
        (
            Some(tokio_rustls::TlsAcceptor::from(Arc::new(config))),
            Some(fp),
        )
    };
    let token_sha = Arc::new(Mutex::new(token_sha));
    let sh = Arc::new(Shared {
        serve,
        no_embed: spec.no_embed,
        token_sha: token_sha.clone(),
    });
    let task = crate::clock::spawn("embed:serve", accept_loop(listener, acceptor, sh));
    let scheme = if spec.plain { "http" } else { "https" };
    tracing::info!(%addr, scheme, no_embed = spec.no_embed, "embed serve: listening");
    Ok((
        Running {
            url: format!("{scheme}://{addr}"),
            cert_sha256,
            dir: spec.dir,
            token_sha,
            task,
        },
        token,
    ))
}

/// How long a connection may take to send a request's head.
const HEADER_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

async fn accept_loop(
    listener: tokio::net::TcpListener,
    acceptor: Option<tokio_rustls::TlsAcceptor>,
    sh: Arc<Shared>,
) {
    loop {
        let (s, peer) = match crate::clock::real(listener.accept()).await {
            Ok(x) => x,
            Err(e) => {
                tracing::warn!("embed serve: accept: {e}");
                crate::clock::sleep(std::time::Duration::from_millis(100)).await;
                continue;
            }
        };
        let (sh, acceptor) = (sh.clone(), acceptor.clone());
        crate::clock::spawn("embed:serve-conn", async move {
            match acceptor {
                None => serve_conn(s, peer, sh).await,
                Some(a) => match crate::clock::real(a.accept(s)).await {
                    Ok(tls) => serve_conn(tls, peer, sh).await,
                    Err(e) => tracing::info!(%peer, "embed serve: TLS: {e}"),
                },
            }
        });
    }
}

async fn serve_conn<S>(s: S, peer: SocketAddr, sh: Arc<Shared>)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    use hyper_util::rt::{TokioIo, TokioTimer};
    let svc = hyper::service::service_fn(move |req| {
        let sh = sh.clone();
        async move { Ok::<_, std::convert::Infallible>(handle(&sh, peer, req).await) }
    });
    let mut b = hyper::server::conn::http1::Builder::new();
    b.timer(TokioTimer::new())
        .header_read_timeout(HEADER_READ_TIMEOUT);
    let _ = b.serve_connection(TokioIo::new(s), svc).await;
}

type Reply = hyper::Response<http_body_util::Full<bytes::Bytes>>;

/// One request, logged by its peer, method, path and status: never its token or its texts.
async fn handle(
    sh: &Shared,
    peer: SocketAddr,
    req: hyper::Request<hyper::body::Incoming>,
) -> Reply {
    let (method, path) = (req.method().clone(), req.uri().path().to_owned());
    let (status, body) = answer(sh, req).await;
    tracing::info!(%peer, %method, path, status, "embed serve");
    hyper::Response::builder()
        .status(status)
        .header(hyper::header::CONTENT_TYPE, "application/json")
        .body(http_body_util::Full::new(bytes::Bytes::from(
            body.to_string(),
        )))
        .expect("a JSON response builds")
}

fn refusal(status: u16, error: &str) -> (u16, serde_json::Value) {
    (status, serde_json::json!({ "error": error }))
}

/// Whether REQ carries the token (its sha256 compared in constant time).
fn authorized(sh: &Shared, req: &hyper::Request<hyper::body::Incoming>) -> bool {
    use subtle::ConstantTimeEq as _;
    let Some(token) = req
        .headers()
        .get(hyper::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
    else {
        return false;
    };
    let want = *sh.token_sha.lock().unwrap_or_else(|p| p.into_inner());
    bool::from(sha256(token.trim().as_bytes()).ct_eq(&want))
}

/// REQ's body as T: a 413 past [`MAX_BODY`], a 400 for what does not parse.
async fn body<T: serde::de::DeserializeOwned>(
    req: hyper::Request<hyper::body::Incoming>,
) -> Result<T, (u16, serde_json::Value)> {
    use http_body_util::BodyExt as _;
    let bytes =
        crate::clock::real(http_body_util::Limited::new(req.into_body(), MAX_BODY).collect())
            .await
            .map_err(|_| refusal(413, "too-large"))?
            .to_bytes();
    serde_json::from_slice(&bytes).map_err(|e| {
        (
            400,
            serde_json::json!({ "error": "bad-request", "detail": e.to_string() }),
        )
    })
}

/// Keys as the wire has them back; a 400 for one that is not 64 hex characters, a 413 past [`MAX_BATCH`].
fn keys_of<'a>(
    keys: impl ExactSizeIterator<Item = &'a str>,
) -> Result<Vec<[u8; 32]>, (u16, serde_json::Value)> {
    if keys.len() > MAX_BATCH as usize {
        return Err(refusal(413, "too-many"));
    }
    keys.map(|k| key_of(k).ok_or_else(|| refusal(400, "bad-key")))
        .collect()
}

fn not_served(e: String) -> (u16, serde_json::Value) {
    if e == UNKNOWN_FP {
        refusal(404, UNKNOWN_FP)
    } else {
        (502, serde_json::json!({ "error": "failed", "detail": e }))
    }
}

fn rows_map(rows: &[QuantRow]) -> BTreeMap<String, WireVec> {
    rows.iter()
        .map(|r| (key_hex(&r.key), wire_vec(r)))
        .collect()
}

async fn answer(
    sh: &Shared,
    req: hyper::Request<hyper::body::Incoming>,
) -> (u16, serde_json::Value) {
    if !authorized(sh, &req) {
        return refusal(401, "unauthorized");
    }
    match (req.method().as_str(), req.uri().path()) {
        ("GET", "/v1/info") => {
            let ids = sh.serve.fingerprints().await;
            let mut embed = false;
            if !sh.no_embed {
                for id in &ids {
                    embed |= sh.serve.embeds(&id.fp.hex()).await;
                }
            }
            let info = Info {
                version: VERSION,
                fingerprints: ids
                    .iter()
                    .map(|id| InfoFingerprint {
                        hex: id.fp.hex(),
                        record: serde_json::from_str(&id.record.to_json()).unwrap_or_default(),
                    })
                    .collect(),
                embed,
                max_batch: MAX_BATCH,
                max_tokens: MAX_TOKENS,
            };
            (200, to_json(&info))
        }
        ("POST", "/v1/lookup") => {
            let r: LookupRequest = match body(req).await {
                Ok(r) => r,
                Err(e) => return e,
            };
            let keys = match keys_of(r.keys.iter().map(String::as_str)) {
                Ok(k) => k,
                Err(e) => return e,
            };
            match sh
                .serve
                .lookup(&r.fingerprint, r.kind.key_kind(), &keys)
                .await
            {
                Ok(rows) => (
                    200,
                    to_json(&LookupAnswer {
                        found: rows_map(&rows),
                    }),
                ),
                Err(e) => not_served(e),
            }
        }
        ("POST", "/v1/embed") => {
            if sh.no_embed {
                return refusal(403, "no-embed");
            }
            let r: EmbedRequest = match body(req).await {
                Ok(r) => r,
                Err(e) => return e,
            };
            let keys = match keys_of(r.items.iter().map(|i| i.key.as_str())) {
                Ok(k) => k,
                Err(e) => return e,
            };
            let kind = r.kind.key_kind();
            // every key must be its text's, or nothing of the request is embedded
            for (k, item) in keys.iter().zip(&r.items) {
                if kind.key(&item.text) != *k {
                    return (
                        422,
                        serde_json::json!({ "error": "key-mismatch", "key": item.key }),
                    );
                }
            }
            let items: Vec<([u8; 32], String)> = keys
                .into_iter()
                .zip(r.items.into_iter().map(|i| i.text))
                .collect();
            match sh.serve.embed(&r.fingerprint, kind, &items).await {
                Ok(rows) => (
                    200,
                    to_json(&EmbedAnswer {
                        vectors: rows_map(&rows),
                    }),
                ),
                Err(e) => not_served(e),
            }
        }
        _ => refusal(404, "not-found"),
    }
}

fn to_json<T: Serialize>(v: &T) -> serde_json::Value {
    serde_json::to_value(v).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> Result<EmbedCommand, String> {
        parse(args.iter().map(std::ffi::OsString::from))
    }

    /// `embed serve`: --listen with its flags, or --stop, or --new-token; never two of them.
    #[test]
    fn embed_serve_parses() {
        assert_eq!(
            p(&[
                "serve",
                "--listen",
                "100.94.36.51:7878",
                "--plain",
                "--no-embed"
            ])
            .unwrap(),
            EmbedCommand::Start {
                listen: "100.94.36.51:7878".into(),
                plain: true,
                no_embed: true
            }
        );
        assert_eq!(p(&["serve", "--stop"]).unwrap(), EmbedCommand::Stop);
        assert_eq!(
            p(&["serve", "--new-token"]).unwrap(),
            EmbedCommand::NewToken
        );
        for bad in [
            &["serve"][..],
            &["serve", "--stop", "--new-token"],
            &["serve", "--listen", "a:1", "--stop"],
            &["serve", "--stop", "--plain"],
            &["lookup"],
        ] {
            assert!(p(bad).is_err(), "{bad:?}");
        }
    }
}
