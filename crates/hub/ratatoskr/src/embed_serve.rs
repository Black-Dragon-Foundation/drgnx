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
    let _ = ip;
    unimplemented!("Wave 9 stub")
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
}

impl CacheServe {
    pub fn new(caches: Arc<Caches>, embedders: Vec<Arc<dyn DocEmbedder>>) -> CacheServe {
        CacheServe { caches, embedders }
    }
}

impl Serve for CacheServe {
    fn fingerprints(&self) -> BoxFuture<'_, Vec<Identity>> {
        let _ = (&self.caches, &self.embedders);
        unimplemented!("Wave 9 stub")
    }
    fn lookup<'a>(
        &'a self,
        _fp: &'a str,
        _kind: KeyKind,
        _keys: &'a [[u8; 32]],
    ) -> BoxFuture<'a, Result<Vec<QuantRow>, String>> {
        unimplemented!("Wave 9 stub")
    }
    fn embeds<'a>(&'a self, _fp: &'a str) -> BoxFuture<'a, bool> {
        unimplemented!("Wave 9 stub")
    }
    fn embed<'a>(
        &'a self,
        _fp: &'a str,
        _kind: KeyKind,
        _items: &'a [([u8; 32], String)],
    ) -> BoxFuture<'a, Result<Vec<QuantRow>, String>> {
        unimplemented!("Wave 9 stub")
    }
}

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
        let _ = (&self.dir, &self.token_sha);
        unimplemented!("Wave 9 stub")
    }

    /// Stops listening; requests in flight end with their connections.
    pub fn stop(self) {
        self.task.abort();
    }
}

/// Starts serving SERVE as SPEC says: the URL, the certificate's sha256 and, the first time (no token kept yet), the
/// token. Err: plain HTTP on an address that is neither loopback nor Tailscale, or the address cannot be bound.
pub async fn start(
    spec: ServeSpec,
    serve: Arc<dyn Serve>,
) -> Result<(Running, Option<String>), String> {
    let _ = (spec, serve, Path::new(""));
    unimplemented!("Wave 9 stub")
}
