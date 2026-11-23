//! A remote vector source (Hrafn redesign §8, MP-18): a `vectors` provider, another machine's `ratatoskr embed serve`
//! (or a team's or CI's), asked over the vector protocol v1 (`crate::embed_serve`).
//!
//! - **Lookup-only unless trusted.** [`RemoteVectors::kind`] is `Lookup`, so the chain asks it for keys and never sends
//!   it a text; with `trusted: true` in its provider entry it is `Embed`, and the keys it misses go to it as texts.
//! - **Its identity** is the first fingerprint its `/v1/info` serves.
//! - **The certificate is pinned on first use** ([`Pins`]: the hub's `runtime.db` `kv`, `vectors.pin.<provider>`): a
//!   later handshake with another certificate fails with [`CHANGED_CERT`] until the user forgets the pin
//!   (`search/forget-pin`). Plain `http://` URLs (a Tailscale address) have no certificate.
//! - The token comes from the provider's `key_env` through the gateway's key hand-over, and is never logged.

use super::sources::{Item, Source, SourceKind};
use crate::embed_serve::{
    EmbedAnswer, EmbedItem, EmbedRequest, Info, LookupAnswer, LookupRequest, WireKind, key_hex,
    quant_row,
};
use hrafn::{KeyKind, QuantRow};
use hrafn_embed::fingerprint::{FingerprintRecord, Identity};
use serde_json::Value;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use urdr::graph::search::{BoxFuture, EmbedError};

/// What a handshake with a certificate other than the pinned one says.
pub const CHANGED_CERT: &str =
    "the server's certificate changed; check it and run Search: forget server pin";

/// The `runtime.db` `kv` key of provider ID's pinned certificate sha256.
pub fn pin_key(id: &str) -> String {
    format!("vectors.pin.{id}")
}

/// Where a provider's pinned certificate sha256 is kept.
pub trait Pins: Send + Sync {
    fn get(&self) -> BoxFuture<'_, Option<String>>;
    fn set<'a>(&'a self, sha256: &'a str) -> BoxFuture<'a, ()>;
}

/// Pins in memory (a test's, or a run's that keeps none).
#[derive(Default)]
pub struct MemPins(pub Mutex<Option<String>>);

impl Pins for MemPins {
    fn get(&self) -> BoxFuture<'_, Option<String>> {
        Box::pin(async move { self.0.lock().ok().and_then(|p| p.clone()) })
    }
    fn set<'a>(&'a self, sha256: &'a str) -> BoxFuture<'a, ()> {
        Box::pin(async move {
            if let Ok(mut p) = self.0.lock() {
                *p = Some(sha256.to_owned());
            }
        })
    }
}

/// Pins in the hub's `runtime.db` `kv`.
pub struct KvPins {
    pub db: urdr::Handle,
    pub key: String,
}

impl Pins for KvPins {
    fn get(&self) -> BoxFuture<'_, Option<String>> {
        // a forgotten pin is kept as an empty value (`search/forget-pin`)
        Box::pin(async move {
            crate::gateway::kv_get(&self.db, &self.key)
                .await
                .filter(|v| !v.is_empty())
        })
    }
    fn set<'a>(&'a self, sha256: &'a str) -> BoxFuture<'a, ()> {
        Box::pin(crate::gateway::kv_set(&self.db, &self.key, sha256))
    }
}

/// A `vectors` provider.
pub struct RemoteSpec {
    /// The provider id.
    pub id: String,
    /// `https://HOST:PORT` (or `http://` on a Tailscale address).
    pub url: String,
    /// The bearer token (from its `key_env`); none: the request goes without one.
    pub token: Option<String>,
    /// Texts may be sent to it.
    pub trusted: bool,
    pub pins: Arc<dyn Pins>,
}

/// A remote vector source.
pub struct RemoteVectors {
    spec: RemoteSpec,
    ident: Mutex<Option<Identity>>,
    batch: Mutex<usize>,
}

impl RemoteVectors {
    pub fn new(spec: RemoteSpec) -> RemoteVectors {
        RemoteVectors {
            spec,
            ident: Mutex::new(None),
            batch: Mutex::new(crate::embed_serve::MAX_BATCH as usize),
        }
    }
}

/// How long a connection may take.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// How long a request may take, connection included.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);

impl RemoteVectors {
    fn fp_hex(&self) -> Result<String, EmbedError> {
        self.identity()
            .map(|i| i.fp.hex())
            .ok_or_else(|| EmbedError(format!("{}: has not stated its model yet", self.spec.id)))
    }

    /// METHOD PATH with BODY: the answer's JSON. Errors name the provider and never the token.
    async fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, EmbedError> {
        let id = &self.spec.id;
        crate::clock::timeout(REQUEST_TIMEOUT, self.call_inner(method, path, body))
            .await
            .unwrap_or_else(|_| Err("timed out".to_owned()))
            .map_err(|e| EmbedError(format!("{id}: {e}")))
    }

    async fn call_inner(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, String> {
        let (tls, rest) = if let Some(r) = self.spec.url.strip_prefix("https://") {
            (true, r)
        } else if let Some(r) = self.spec.url.strip_prefix("http://") {
            (false, r)
        } else {
            return Err(format!("{}: not an http:// or https:// URL", self.spec.url));
        };
        let authority = rest.trim_end_matches('/');
        let (host, _) = authority
            .rsplit_once(':')
            .ok_or_else(|| format!("{}: no port", self.spec.url))?;
        let host = host
            .trim_start_matches('[')
            .trim_end_matches(']')
            .to_owned();
        let tcp = crate::clock::timeout(
            CONNECT_TIMEOUT,
            crate::clock::real(tokio::net::TcpStream::connect(authority.to_owned())),
        )
        .await
        .map_err(|_| "connecting timed out".to_owned())?
        .map_err(|e| format!("cannot connect: {e}"))?;
        let mut req = hyper::Request::builder()
            .method(method)
            .uri(path)
            .header(hyper::header::HOST, authority)
            .header(hyper::header::CONTENT_TYPE, "application/json");
        if let Some(t) = &self.spec.token {
            req = req.header(hyper::header::AUTHORIZATION, format!("Bearer {t}"));
        }
        let req = req
            .body(http_body_util::Full::new(bytes::Bytes::from(
                body.map(|b| b.to_string()).unwrap_or_default(),
            )))
            .map_err(|e| format!("the request: {e}"))?;
        if !tls {
            return exchange(tcp, req).await;
        }
        let pinned = self.spec.pins.get().await;
        let seen = Arc::new(Mutex::new(None));
        let verifier = Arc::new(PinVerifier {
            pinned: pinned.clone(),
            seen: seen.clone(),
            provider: Arc::new(rustls::crypto::ring::default_provider()),
        });
        let config = rustls::ClientConfig::builder_with_provider(verifier.provider.clone())
            .with_safe_default_protocol_versions()
            .map_err(|e| e.to_string())?
            .dangerous()
            .with_custom_certificate_verifier(verifier)
            .with_no_client_auth();
        let name = rustls::pki_types::ServerName::try_from(host)
            .map_err(|e| format!("{}: {e}", self.spec.url))?;
        let stream = crate::clock::real(
            tokio_rustls::TlsConnector::from(Arc::new(config)).connect(name, tcp),
        )
        .await;
        let seen = seen.lock().ok().and_then(|s| s.clone());
        if pinned.is_some() && seen.is_some() && seen != pinned {
            return Err(CHANGED_CERT.into());
        }
        let stream = stream.map_err(|e| format!("TLS: {e}"))?;
        let answer = exchange(stream, req).await?;
        if pinned.is_none()
            && let Some(s) = seen
        {
            self.spec.pins.set(&s).await;
        }
        Ok(answer)
    }

    /// Vectors for KIND's KEYS from the remote: a row for each it holds, in KEYS' order.
    async fn lookup_rows(
        &self,
        kind: KeyKind,
        keys: &[[u8; 32]],
    ) -> Result<Vec<Option<QuantRow>>, EmbedError> {
        let mut out = Vec::with_capacity(keys.len());
        for part in keys.chunks(self.max_batch().max(1)) {
            let req = LookupRequest {
                fingerprint: self.fp_hex()?,
                kind: WireKind::of(kind),
                keys: part.iter().map(key_hex).collect(),
            };
            let a: LookupAnswer = self
                .call_as("POST", "/v1/lookup", Some(to_value(&req)))
                .await?;
            for k in part {
                out.push(match a.found.get(&key_hex(k)) {
                    Some(v) => Some(
                        quant_row(*k, v).ok_or_else(|| self.bad("a vector that is not base64"))?,
                    ),
                    None => None,
                });
            }
        }
        Ok(out)
    }

    async fn call_as<T: serde::de::DeserializeOwned>(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
    ) -> Result<T, EmbedError> {
        let v = self.call(method, path, body).await?;
        serde_json::from_value(v).map_err(|e| self.bad(&e.to_string()))
    }

    fn bad(&self, what: &str) -> EmbedError {
        EmbedError(format!("{}: answered {what}", self.spec.id))
    }

    fn dims(&self) -> Result<usize, EmbedError> {
        Ok(self
            .identity()
            .ok_or_else(|| EmbedError(format!("{}: has not stated its model yet", self.spec.id)))?
            .record
            .dims as usize)
    }
}

fn to_value<T: serde::Serialize>(v: &T) -> Value {
    serde_json::to_value(v).unwrap_or_default()
}

/// A stored row back as DIMS floats: the int8 part (after the sign bytes) times its scale.
fn dequantize(r: &QuantRow, dims: usize) -> Option<Vec<f32>> {
    let ints = r.vec.get(dims.div_ceil(8)..)?;
    (ints.len() == dims).then(|| {
        ints.iter()
            .map(|&b| (b as i8 as f64 * r.scale) as f32)
            .collect()
    })
}

/// REQ over S, HTTP/1.1, one exchange: the body as JSON, or the status and the server's `error`.
async fn exchange<S>(
    s: S,
    req: hyper::Request<http_body_util::Full<bytes::Bytes>>,
) -> Result<Value, String>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    use http_body_util::BodyExt as _;
    let (mut sender, conn) = hyper::client::conn::http1::handshake(hyper_util::rt::TokioIo::new(s))
        .await
        .map_err(|e| format!("HTTP: {e}"))?;
    let conn = crate::clock::spawn("search:vectors", async move {
        let _ = conn.await;
    });
    let resp = crate::clock::real(sender.send_request(req))
        .await
        .map_err(|e| format!("HTTP: {e}"));
    let out = async {
        let (head, body) = resp?.into_parts();
        let body = crate::clock::real(
            http_body_util::Limited::new(body, crate::embed_serve::MAX_BODY).collect(),
        )
        .await
        .map_err(|e| format!("the answer broke off: {e}"))?
        .to_bytes();
        let v: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        if head.status.is_success() {
            Ok(v)
        } else {
            Err(format!(
                "HTTP {}: {}",
                head.status.as_u16(),
                v["error"].as_str().unwrap_or("no reason")
            ))
        }
    }
    .await;
    conn.abort();
    out
}

/// Accepts the certificate pinned (or any, the first time), after checking the handshake's signature; records what it
/// saw.
#[derive(Debug)]
struct PinVerifier {
    pinned: Option<String>,
    seen: Arc<Mutex<Option<String>>>,
    provider: Arc<rustls::crypto::CryptoProvider>,
}

impl rustls::client::danger::ServerCertVerifier for PinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        let d = ring::digest::digest(&ring::digest::SHA256, end_entity.as_ref());
        let mut sha = [0u8; 32];
        sha.copy_from_slice(d.as_ref());
        let hex = key_hex(&sha);
        if let Ok(mut s) = self.seen.lock() {
            *s = Some(hex.clone());
        }
        match &self.pinned {
            Some(p) if *p != hex => Err(rustls::Error::General(CHANGED_CERT.into())),
            _ => Ok(rustls::client::danger::ServerCertVerified::assertion()),
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

impl Source for RemoteVectors {
    fn id(&self) -> &str {
        &self.spec.id
    }
    fn kind(&self) -> SourceKind {
        if self.spec.trusted {
            SourceKind::Embed
        } else {
            SourceKind::Lookup
        }
    }
    fn identity(&self) -> Option<Identity> {
        self.ident.lock().ok().and_then(|i| i.clone())
    }
    fn may_send_text(&self) -> bool {
        self.spec.trusted
    }
    fn max_batch(&self) -> usize {
        self.batch.lock().map_or(1, |b| *b)
    }
    fn lookup<'a>(
        &'a self,
        kind: KeyKind,
        keys: &'a [[u8; 32]],
    ) -> BoxFuture<'a, Result<Vec<Option<QuantRow>>, EmbedError>> {
        Box::pin(self.lookup_rows(kind, keys))
    }

    /// A trusted remote is asked for the keys first; only the ones it lacks go as texts.
    fn embed<'a>(
        &'a self,
        items: &'a [Item],
        _overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        Box::pin(async move {
            if !self.spec.trusted {
                return Err(EmbedError(format!("{} may not be sent text", self.spec.id)));
            }
            let dims = self.dims()?;
            let mut out: Vec<Option<Vec<f32>>> = vec![None; items.len()];
            for kind in [KeyKind::Chunk, KeyKind::Path] {
                let at: Vec<usize> = (0..items.len()).filter(|&i| items[i].0 == kind).collect();
                if at.is_empty() {
                    continue;
                }
                let keys: Vec<[u8; 32]> = at.iter().map(|&i| items[i].1).collect();
                let rows = self.lookup_rows(kind, &keys).await?;
                let mut missing = Vec::new();
                for (&i, row) in at.iter().zip(rows) {
                    match row.and_then(|r| dequantize(&r, dims)) {
                        Some(v) => out[i] = Some(v),
                        None => missing.push(i),
                    }
                }
                for part in missing.chunks(self.max_batch().max(1)) {
                    let req = EmbedRequest {
                        fingerprint: self.fp_hex()?,
                        kind: WireKind::of(kind),
                        items: part
                            .iter()
                            .map(|&i| EmbedItem {
                                key: key_hex(&items[i].1),
                                text: items[i].2.clone(),
                            })
                            .collect(),
                    };
                    let a: EmbedAnswer = self
                        .call_as("POST", "/v1/embed", Some(to_value(&req)))
                        .await?;
                    for &i in part {
                        let v = a
                            .vectors
                            .get(&key_hex(&items[i].1))
                            .and_then(|w| quant_row(items[i].1, w))
                            .and_then(|r| dequantize(&r, dims))
                            .ok_or_else(|| self.bad("no vector for a text it was sent"))?;
                        out[i] = Some(v);
                    }
                }
            }
            Ok(out.into_iter().map(Option::unwrap_or_default).collect())
        })
    }

    /// `/v1/info`: its first fingerprint is its identity, its `max_batch` this source's.
    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>> {
        Box::pin(async move {
            let info: Info = self.call_as("GET", "/v1/info", None).await?;
            if info.version != crate::embed_serve::VERSION {
                return Err(self.bad(&format!("protocol version {}", info.version)));
            }
            let f = info
                .fingerprints
                .first()
                .ok_or_else(|| self.bad("no fingerprint"))?;
            let record =
                FingerprintRecord::from_json(&f.record.to_string()).map_err(|e| self.bad(&e))?;
            let id = Identity::new(record.clone(), record.model_id.clone());
            if id.fp.hex() != f.hex {
                return Err(self.bad("a record that is not its fingerprint's"));
            }
            if let Ok(mut b) = self.batch.lock() {
                *b = (info.max_batch as usize).clamp(1, crate::embed_serve::MAX_BATCH as usize);
            }
            if let Ok(mut i) = self.ident.lock() {
                *i = Some(id.clone());
            }
            Ok(id)
        })
    }
}
