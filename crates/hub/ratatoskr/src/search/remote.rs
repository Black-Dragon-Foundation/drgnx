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
use hrafn::{KeyKind, QuantRow};
use hrafn_embed::fingerprint::Identity;
use std::sync::{Arc, Mutex};
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
        Box::pin(crate::gateway::kv_get(&self.db, &self.key))
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

impl Source for RemoteVectors {
    fn id(&self) -> &str {
        &self.spec.id
    }
    fn kind(&self) -> SourceKind {
        unimplemented!("Wave 9 stub")
    }
    fn identity(&self) -> Option<Identity> {
        self.ident.lock().ok().and_then(|i| i.clone())
    }
    fn may_send_text(&self) -> bool {
        unimplemented!("Wave 9 stub")
    }
    fn max_batch(&self) -> usize {
        self.batch.lock().map_or(1, |b| *b)
    }
    fn lookup<'a>(
        &'a self,
        _kind: KeyKind,
        _keys: &'a [[u8; 32]],
    ) -> BoxFuture<'a, Result<Vec<Option<QuantRow>>, EmbedError>> {
        unimplemented!("Wave 9 stub")
    }
    fn embed<'a>(
        &'a self,
        _items: &'a [Item],
        _overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        unimplemented!("Wave 9 stub")
    }
    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>> {
        unimplemented!("Wave 9 stub")
    }
}
