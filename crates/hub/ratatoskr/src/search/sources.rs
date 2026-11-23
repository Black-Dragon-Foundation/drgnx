//! Tier 2's sources: where the vectors of the keys a repo is missing come from, as a chain per fingerprint (Hrafn
//! redesign §7.2, MP-14, MP-15).
//!
//! - **A [`Source`]** answers keys with vectors ([`Source::lookup`]: keys only, never a text) or embeds texts
//!   ([`Source::embed`]). Its kind says which: [`SourceKind::Lookup`] sources are asked for keys and never receive a text;
//!   an embedder receives texts only when it [may send text](Source::may_send_text) (the built-in model, a local engine,
//!   a remote that is on this machine or marked trusted). Every source in a chain sits behind a guard that refuses an
//!   `embed` for one that may not, so the rule holds whatever the chain does.
//! - **A [`SourceChain`]** is one fingerprint's: per batch the cache first (a vector that arrived meanwhile), then the
//!   lookup sources, then the keys still missing go to the first embedder that answers. A source that fails is marked down
//!   ([`crate::chain::Chain`], the entity embedder's backoff: 1, 5 and 30 minutes, then 6 hours, per source) and the
//!   **same** batch goes to the next. While every source is down and none is due, [`SourceChain::step`] reads no store
//!   rows.
//! - **A pass** ([`run_pass`]) steps the main fingerprints' chains; the built-in model's chain (its own fingerprint, so
//!   its own vectors) steps only when no main chain had work (MP-15). On battery the local sources (the built-in model,
//!   the local engine) wait unless `index now` or `drgnx-search-battery-engine` says otherwise, and on a busy machine
//!   ([`super::host::busy`]) unless `index now`; remote sources never do.

use super::DocEmbedder;
use super::project::REQUEST_KEYS;
use crate::chain::{Chain, Change, Health};
use hrafn::{CodeStore, KeyKind, QuantRow, StoreError, VectorCache};
use hrafn_embed::fingerprint::{Fingerprint, Identity};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::Instant;
use urdr::graph::search::{BoxFuture, EmbedError};

/// One key to fill: its kind, its key and the text its key was made of.
pub type Item = (KeyKind, [u8; 32], String);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceKind {
    /// This machine's vector cache (the chain asks it itself, first).
    Cache,
    /// A remote that answers keys with vectors and never receives text.
    Lookup,
    /// A server that embeds the texts it is sent.
    Embed,
    /// The llama.cpp engine the hub manages.
    LocalEngine,
    /// The built-in model.
    Builtin,
}

impl SourceKind {
    pub fn name(self) -> &'static str {
        match self {
            SourceKind::Cache => "cache",
            SourceKind::Lookup => "lookup",
            SourceKind::Embed => "embed",
            SourceKind::LocalEngine => "engine",
            SourceKind::Builtin => "builtin",
        }
    }

    /// Runs on this machine's own hardware (battery matters).
    fn local(self) -> bool {
        matches!(self, SourceKind::LocalEngine | SourceKind::Builtin)
    }

    fn rank(self) -> u8 {
        match self {
            SourceKind::Cache => 0,
            SourceKind::Lookup => 1,
            SourceKind::Embed => 2,
            SourceKind::LocalEngine => 3,
            SourceKind::Builtin => 4,
        }
    }
}

pub trait Source: Send + Sync {
    /// A provider id, or `cache` / `builtin`.
    fn id(&self) -> &str;
    fn kind(&self) -> SourceKind;
    /// What its last [`probe`](Self::probe) proved of its model; none before the first answer.
    fn identity(&self) -> Option<Identity>;
    /// Whether it may be sent document text: an embedder on this machine or marked trusted, the local engine, the
    /// built-in model. Never a lookup source.
    fn may_send_text(&self) -> bool;
    /// The most keys one request carries.
    fn max_batch(&self) -> usize;
    /// The vectors it holds for KEYS (none for a key it lacks), by key alone.
    fn lookup<'a>(
        &'a self,
        kind: KeyKind,
        keys: &'a [[u8; 32]],
    ) -> BoxFuture<'a, Result<Vec<Option<QuantRow>>, EmbedError>>;
    /// Vectors for ITEMS' texts, in order. OVERRIDING (`index now`) lets a local source run on battery.
    fn embed<'a>(
        &'a self,
        items: &'a [Item],
        overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>>;
    /// Asks it what its model is now.
    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>>;
}

/// A source behind the text rule: an `embed` for a source that may not be sent text fails here, before the source.
struct Guarded(Arc<dyn Source>);

impl Source for Guarded {
    fn id(&self) -> &str {
        self.0.id()
    }
    fn kind(&self) -> SourceKind {
        self.0.kind()
    }
    fn identity(&self) -> Option<Identity> {
        self.0.identity()
    }
    fn may_send_text(&self) -> bool {
        self.0.may_send_text() && !matches!(self.0.kind(), SourceKind::Lookup | SourceKind::Cache)
    }
    fn max_batch(&self) -> usize {
        self.0.max_batch()
    }
    fn lookup<'a>(
        &'a self,
        kind: KeyKind,
        keys: &'a [[u8; 32]],
    ) -> BoxFuture<'a, Result<Vec<Option<QuantRow>>, EmbedError>> {
        self.0.lookup(kind, keys)
    }
    fn embed<'a>(
        &'a self,
        items: &'a [Item],
        overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        if !self.may_send_text() {
            let id = self.0.id().to_owned();
            return Box::pin(async move { Err(EmbedError(format!("{id} may not be sent text"))) });
        }
        self.0.embed(items, overriding)
    }
    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>> {
        self.0.probe()
    }
}

/// What a [`SourceChain::fill`] did with a batch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FillOutcome {
    /// N chunk vectors were filled, the last by FROM (a source id, or `cache`); path vectors ride along.
    Filled { n: usize, from: String },
    /// Keys are left and no source could take them (down, not due, held or not allowed text).
    AllDown,
    /// The batch was empty.
    Nothing,
}

/// One source of a chain, as `search/status` shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChainEntry {
    pub id: String,
    pub kind: &'static str,
    /// `answering`, `down`, `held` (battery) or `no text` (a remote not allowed text).
    pub state: &'static str,
    pub why: Option<String>,
}

/// One fingerprint's chain of sources, in the order cache, lookup, embed, engine, built-in.
pub struct SourceChain {
    fp: Fingerprint,
    sources: Vec<Arc<dyn Source>>,
    health: Chain,
    hold_local: bool,
    overriding: bool,
    why: Option<String>,
}

impl SourceChain {
    pub fn new(fp: Fingerprint, sources: Vec<Arc<dyn Source>>) -> SourceChain {
        let mut c = SourceChain {
            fp,
            sources: Vec::new(),
            health: Chain::default(),
            hold_local: false,
            overriding: false,
            why: None,
        };
        c.sync(sources);
        c
    }

    /// The chain's sources are SOURCES now; one already known keeps its backoff.
    pub fn sync(&mut self, sources: Vec<Arc<dyn Source>>) {
        let mut guarded: Vec<Arc<dyn Source>> = sources
            .into_iter()
            .map(|s| Arc::new(Guarded(s)) as Arc<dyn Source>)
            .collect();
        guarded.sort_by_key(|s| s.kind().rank());
        let ids: Vec<String> = guarded.iter().map(|s| s.id().to_owned()).collect();
        self.health.sync(&ids);
        self.sources = guarded;
    }

    pub fn fingerprint(&self) -> Fingerprint {
        self.fp
    }

    /// The built-in model's chain: its own fingerprint, filled only while the main chains idle.
    pub fn is_builtin(&self) -> bool {
        self.sources.iter().any(|s| s.kind() == SourceKind::Builtin)
    }

    /// The battery rule: HOLD_LOCAL keeps the local sources waiting, unless OVERRIDING (`index now`).
    pub fn set_gates(&mut self, hold_local: bool, overriding: bool) {
        self.hold_local = hold_local;
        self.overriding = overriding;
    }

    /// Why the last fill ended with keys left.
    pub fn why(&self) -> Option<&str> {
        self.why.as_deref()
    }

    /// The most keys a request to the chain's embedders carries.
    pub fn batch(&self) -> usize {
        self.sources
            .iter()
            .filter(|s| s.may_send_text())
            .map(|s| s.max_batch())
            .max()
            .unwrap_or(REQUEST_KEYS as usize)
            .max(1)
    }

    fn due(&self, id: &str, now: Instant) -> bool {
        match self.health.entries().iter().find(|(m, _)| m == id) {
            Some((_, Health::Down { until, .. })) => *until <= now,
            _ => true,
        }
    }

    /// Whether S may be asked at NOW: it states this fingerprint, its backoff is over, and the battery rule (unless
    /// IGNORING_HOLD) lets it run.
    fn eligible(&self, s: &Arc<dyn Source>, now: Instant, ignoring_hold: bool) -> bool {
        if s.identity().is_some_and(|i| i.fp != self.fp) || !self.due(s.id(), now) {
            return false;
        }
        ignoring_hold || self.overriding || !(self.hold_local && s.kind().local())
    }

    /// Whether some source could take a batch at NOW.
    pub fn ready(&self, now: Instant) -> bool {
        self.sources.iter().any(|s| {
            (s.kind() == SourceKind::Lookup || s.may_send_text()) && self.eligible(s, now, false)
        })
    }

    /// Whether only the battery rule keeps a source from taking a batch at NOW.
    pub fn blocked_by_hold(&self, now: Instant) -> bool {
        !self.ready(now)
            && self
                .sources
                .iter()
                .any(|s| s.kind().local() && s.may_send_text() && self.eligible(s, now, true))
    }

    /// How long until a down source is asked again (none: none is down).
    pub fn next_due(&self, now: Instant) -> Option<Duration> {
        self.health
            .entries()
            .iter()
            .filter_map(|(_, h)| match h {
                Health::Down { until, .. } => Some(until.saturating_duration_since(now)),
                Health::Answering => None,
            })
            .min()
    }

    /// The cache and each source with its state, for `search/status`.
    pub fn status(&self) -> Vec<ChainEntry> {
        let mut out = vec![ChainEntry {
            id: "cache".into(),
            kind: SourceKind::Cache.name(),
            state: "answering",
            why: None,
        }];
        for s in &self.sources {
            let (state, why) = match self.health.entries().iter().find(|(m, _)| m == s.id()) {
                Some((_, Health::Down { why, .. })) => ("down", Some(why.clone())),
                _ if self.hold_local && !self.overriding && s.kind().local() => ("held", None),
                _ if s.kind() != SourceKind::Lookup && !s.may_send_text() => ("no text", None),
                _ => ("answering", None),
            };
            out.push(ChainEntry {
                id: s.id().to_owned(),
                kind: s.kind().name(),
                state,
                why,
            });
        }
        out
    }

    fn failed(&mut self, id: &str, why: String, now: Instant) {
        if let Some(Change::Down { .. }) = self.health.fail(id, &why, now) {
            tracing::warn!("search: source {id} is down: {why}");
        }
        self.why = Some(format!("{id}: {why}"));
    }

    fn answered(&mut self, id: &str) {
        if let Some(Change::Up { .. }) = self.health.answered(id) {
            tracing::info!("search: source {id} answers again");
        }
    }

    fn outcome(batch: &[Item], left: &[Item], from: String) -> FillOutcome {
        let chunks = |v: &[Item]| v.iter().filter(|(k, _, _)| *k == KeyKind::Chunk).count();
        if left.len() < batch.len() {
            FillOutcome::Filled {
                n: chunks(batch) - chunks(left),
                from,
            }
        } else if left.is_empty() {
            FillOutcome::Nothing
        } else {
            FillOutcome::AllDown
        }
    }

    /// Fills BATCH at NOW: the cache, the lookup sources, then the first embedder that answers; a source that fails is
    /// marked down and the same keys go to the next. Vectors are written to CACHE.
    pub async fn fill(&mut self, cache: &VectorCache, batch: &[Item], now: Instant) -> FillOutcome {
        self.why = None;
        let mut left: Vec<Item> = batch.to_vec();
        let mut from = String::new();
        let keys_of = |left: &[Item], kind: KeyKind| -> Vec<[u8; 32]> {
            left.iter()
                .filter(|(k, _, _)| *k == kind)
                .map(|(_, key, _)| *key)
                .collect()
        };
        // 1. the cache: a vector that arrived since the keys were read
        for kind in [KeyKind::Chunk, KeyKind::Path] {
            let keys = keys_of(&left, kind);
            if keys.is_empty() {
                continue;
            }
            match cache.has(kind, &keys).await {
                Ok(has) => {
                    let hit: HashSet<[u8; 32]> = keys
                        .iter()
                        .zip(has)
                        .filter(|(_, h)| *h)
                        .map(|(k, _)| *k)
                        .collect();
                    if !hit.is_empty() {
                        left.retain(|(k, key, _)| !(*k == kind && hit.contains(key)));
                        from = "cache".into();
                    }
                }
                Err(e) => {
                    self.why = Some(e.to_string());
                    return Self::outcome(batch, &left, from);
                }
            }
        }
        // 2. the lookup sources: keys only
        let lookups: Vec<Arc<dyn Source>> = self
            .sources
            .iter()
            .filter(|s| s.kind() == SourceKind::Lookup)
            .cloned()
            .collect();
        for s in lookups {
            if left.is_empty() {
                break;
            }
            if !self.eligible(&s, now, false) {
                continue;
            }
            let mut ok = true;
            for kind in [KeyKind::Chunk, KeyKind::Path] {
                let keys = keys_of(&left, kind);
                if keys.is_empty() {
                    continue;
                }
                match s.lookup(kind, &keys).await {
                    Ok(rows) if rows.len() == keys.len() => {
                        let found: Vec<QuantRow> = rows.into_iter().flatten().collect();
                        if found.is_empty() {
                            continue;
                        }
                        if let Err(e) = cache.put_quantized(kind, &found).await {
                            self.why = Some(e.to_string());
                            return Self::outcome(batch, &left, from);
                        }
                        let got: HashSet<[u8; 32]> = found.iter().map(|r| r.key).collect();
                        left.retain(|(k, key, _)| !(*k == kind && got.contains(key)));
                        from = s.id().to_owned();
                    }
                    Ok(rows) => {
                        let why = format!("{} rows for {} keys", rows.len(), keys.len());
                        self.failed(s.id(), why, now);
                        ok = false;
                        break;
                    }
                    Err(e) => {
                        self.failed(s.id(), e.0, now);
                        ok = false;
                        break;
                    }
                }
            }
            if ok {
                self.answered(s.id());
            }
        }
        // 3. the first embedder that answers; its failure sends the same keys on
        let mut tried: HashSet<String> = HashSet::new();
        'embedders: while !left.is_empty() {
            let Some(s) = self
                .sources
                .iter()
                .find(|s| {
                    s.may_send_text() && !tried.contains(s.id()) && self.eligible(s, now, false)
                })
                .cloned()
            else {
                break;
            };
            tried.insert(s.id().to_owned());
            let Some(dims) = s.identity().map(|i| i.record.dims as usize) else {
                self.failed(s.id(), "has not stated its model yet".into(), now);
                continue;
            };
            while !left.is_empty() {
                let n = left.len().min(s.max_batch().max(1));
                match s.embed(&left[..n], self.overriding).await {
                    Ok(vectors) if vectors.len() == n => {
                        // the fingerprint says how long a vector is: another length writes nothing of the batch
                        if let Some(v) = vectors.iter().find(|v| v.len() != dims) {
                            let why = format!("{} dims, the fingerprint says {dims}", v.len());
                            self.failed(s.id(), why, now);
                            continue 'embedders;
                        }
                        for kind in [KeyKind::Chunk, KeyKind::Path] {
                            let rows: Vec<([u8; 32], Vec<f32>)> = left[..n]
                                .iter()
                                .zip(&vectors)
                                .filter(|((k, _, _), _)| *k == kind)
                                .map(|((_, key, _), v)| (*key, v.clone()))
                                .collect();
                            if rows.is_empty() {
                                continue;
                            }
                            if let Err(e) = cache.put(kind, dims as u32, &rows).await {
                                // the cache failed, not the source: nothing is marked down
                                self.why = Some(e.to_string());
                                return Self::outcome(batch, &left, from);
                            }
                        }
                        left.drain(..n);
                        from = s.id().to_owned();
                        self.answered(s.id());
                    }
                    Ok(vectors) => {
                        let why = format!("{} vectors for {n} texts", vectors.len());
                        self.failed(s.id(), why, now);
                        continue 'embedders;
                    }
                    Err(e) => {
                        self.failed(s.id(), e.0, now);
                        continue 'embedders;
                    }
                }
            }
        }
        Self::outcome(batch, &left, from)
    }

    /// One step: while no source can take a batch, no store row is read (AllDown); else the next keys the CACHE lacks
    /// (the chunks of ORDER's paths first) are read, counted in READS, and filled.
    pub async fn step(
        &mut self,
        store: &CodeStore,
        cache: &VectorCache,
        order: &[String],
        now: Instant,
        reads: &mut usize,
    ) -> Result<FillOutcome, StoreError> {
        self.step_with(store, cache, order, now, reads, &|| {})
            .await
    }

    /// [`step`](Self::step), calling ON_WORK once keys are found and before they are filled (tier 2 is `Running`
    /// while a request is in flight).
    pub async fn step_with(
        &mut self,
        store: &CodeStore,
        cache: &VectorCache,
        order: &[String],
        now: Instant,
        reads: &mut usize,
        on_work: &(dyn Fn() + Sync),
    ) -> Result<FillOutcome, StoreError> {
        if !self.ready(now) {
            return Ok(FillOutcome::AllDown);
        }
        *reads += 1;
        let keys = hrafn::missing_first(store, cache, self.batch() as u32, order).await?;
        if keys.is_empty() {
            return Ok(FillOutcome::Nothing);
        }
        on_work();
        Ok(self.fill(cache, &keys, now).await)
    }
}

/// A chain with the cache its vectors go to.
pub struct Slot {
    pub chain: SourceChain,
    pub cache: Arc<VectorCache>,
}

impl Slot {
    pub fn new(chain: SourceChain, cache: Arc<VectorCache>) -> Slot {
        Slot { chain, cache }
    }
}

/// What one [`run_pass`] did.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct PassOutcome {
    /// Chunk vectors filled.
    pub chunks: usize,
    /// Something was filled: the next pass goes on at once.
    pub filled: bool,
    /// Nothing was filled and only the battery rule kept a local source from it.
    pub held: bool,
    /// Nothing was filled and every source of a chain with work is down (why).
    pub down: Option<String>,
}

/// One pass over SLOTS at NOW: the main fingerprints' chains step; the built-in model's chain steps only when no main
/// chain filled anything (MP-15), so it never holds the main source back.
pub async fn run_pass(
    slots: &mut [Slot],
    store: &CodeStore,
    order: &[String],
    now: Instant,
    reads: &mut usize,
) -> Result<PassOutcome, StoreError> {
    run_pass_with(slots, store, order, now, reads, &|| {}).await
}

/// [`run_pass`], calling ON_WORK before each chain's request.
pub async fn run_pass_with(
    slots: &mut [Slot],
    store: &CodeStore,
    order: &[String],
    now: Instant,
    reads: &mut usize,
    on_work: &(dyn Fn() + Sync),
) -> Result<PassOutcome, StoreError> {
    let mut out = PassOutcome::default();
    let (mut held, mut down) = (false, None);
    for builtin in [false, true] {
        if builtin && out.filled {
            break;
        }
        for slot in slots.iter_mut().filter(|s| s.chain.is_builtin() == builtin) {
            match slot
                .chain
                .step_with(store, &slot.cache, order, now, reads, on_work)
                .await?
            {
                FillOutcome::Filled { n, .. } => {
                    out.filled = true;
                    out.chunks += n;
                }
                FillOutcome::AllDown => {
                    if slot.chain.blocked_by_hold(now) {
                        held = true;
                    } else if down.is_none() {
                        down = Some(slot.chain.why().unwrap_or("no source answers").to_owned());
                    }
                }
                FillOutcome::Nothing => {}
            }
        }
    }
    if !out.filled {
        out.held = held;
        out.down = down;
    }
    Ok(out)
}

/// Adapts a [`DocEmbedder`] (a TEI or Ollama provider, or the built-in worker) to a [`Source`].
pub struct DocSource {
    inner: Arc<dyn DocEmbedder>,
    id: String,
    kind: SourceKind,
    trusted: bool,
}

impl DocSource {
    pub fn new(inner: Arc<dyn DocEmbedder>) -> DocSource {
        DocSource {
            id: inner.source_id(),
            kind: inner.source_kind(),
            trusted: inner.trusted(),
            inner,
        }
    }
}

impl Source for DocSource {
    fn id(&self) -> &str {
        &self.id
    }
    fn kind(&self) -> SourceKind {
        self.kind
    }
    fn identity(&self) -> Option<Identity> {
        self.inner.identity()
    }
    fn may_send_text(&self) -> bool {
        match self.kind {
            SourceKind::Embed => self.trusted,
            SourceKind::LocalEngine | SourceKind::Builtin => true,
            SourceKind::Lookup | SourceKind::Cache => false,
        }
    }
    /// Eight keys a request, as before the chain (the built-in model's batch; a server's number comes with Wave 9).
    fn max_batch(&self) -> usize {
        REQUEST_KEYS as usize
    }
    fn lookup<'a>(
        &'a self,
        _kind: KeyKind,
        _keys: &'a [[u8; 32]],
    ) -> BoxFuture<'a, Result<Vec<Option<QuantRow>>, EmbedError>> {
        Box::pin(async { Err(EmbedError("an embedder answers no lookups".into())) })
    }
    fn embed<'a>(
        &'a self,
        items: &'a [Item],
        overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        Box::pin(async move {
            let texts: Vec<String> = items.iter().map(|(_, _, t)| t.clone()).collect();
            self.inner.embed_docs(&texts, overriding).await
        })
    }
    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>> {
        self.inner.probe()
    }
}
