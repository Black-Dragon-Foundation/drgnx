//! Tier 2's sources (stubs: the signatures of Task 14; the bodies come after the wave's red run).

use super::DocEmbedder;
use crate::chain::Chain;
use hrafn::{CodeStore, KeyKind, QuantRow, VectorCache};
use hrafn_embed::fingerprint::{Fingerprint, Identity};
use std::sync::Arc;
use tokio::time::Instant;
use urdr::graph::search::{BoxFuture, EmbedError};

/// One key to fill: its kind, its key and the text its key was made of.
pub type Item = (KeyKind, [u8; 32], String);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceKind {
    Cache,
    Lookup,
    Embed,
    LocalEngine,
    Builtin,
}

pub trait Source: Send + Sync {
    fn id(&self) -> &str;
    fn kind(&self) -> SourceKind;
    fn identity(&self) -> Option<Identity>;
    fn may_send_text(&self) -> bool;
    fn max_batch(&self) -> usize;
    fn lookup<'a>(
        &'a self,
        kind: KeyKind,
        keys: &'a [[u8; 32]],
    ) -> BoxFuture<'a, Result<Vec<Option<QuantRow>>, EmbedError>>;
    fn embed<'a>(
        &'a self,
        items: &'a [Item],
        overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>>;
    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>>;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FillOutcome {
    Filled { n: usize, from: String },
    AllDown,
    Nothing,
}

pub struct SourceChain {
    _fp: Fingerprint,
    _sources: Vec<Arc<dyn Source>>,
    _health: Chain,
}

impl SourceChain {
    pub fn new(fp: Fingerprint, sources: Vec<Arc<dyn Source>>) -> SourceChain {
        SourceChain {
            _fp: fp,
            _sources: sources,
            _health: Chain::default(),
        }
    }

    pub async fn fill(
        &mut self,
        _cache: &VectorCache,
        _batch: &[Item],
        _now: Instant,
    ) -> FillOutcome {
        unimplemented!("Task 14")
    }

    pub async fn step(
        &mut self,
        _store: &CodeStore,
        _cache: &VectorCache,
        _order: &[String],
        _now: Instant,
        _reads: &mut usize,
    ) -> Result<FillOutcome, hrafn::StoreError> {
        unimplemented!("Task 14")
    }

    pub fn set_gates(&mut self, _hold_local: bool, _overriding: bool) {
        unimplemented!("Task 15")
    }

    pub fn is_builtin(&self) -> bool {
        unimplemented!("Task 15")
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

#[derive(Debug, Default, PartialEq, Eq)]
pub struct PassOutcome {
    pub chunks: usize,
    pub filled: bool,
    pub held: bool,
    pub down: Option<String>,
}

pub async fn run_pass(
    _slots: &mut [Slot],
    _store: &CodeStore,
    _order: &[String],
    _now: Instant,
    _reads: &mut usize,
) -> Result<PassOutcome, hrafn::StoreError> {
    unimplemented!("Task 14")
}

/// Adapts a [`DocEmbedder`] (a TEI or Ollama provider, or the built-in worker) to a [`Source`].
pub struct DocSource {
    _inner: Arc<dyn DocEmbedder>,
}

impl DocSource {
    pub fn new(inner: Arc<dyn DocEmbedder>) -> DocSource {
        DocSource { _inner: inner }
    }
}

impl Source for DocSource {
    fn id(&self) -> &str {
        unimplemented!("Task 14")
    }
    fn kind(&self) -> SourceKind {
        unimplemented!("Task 14")
    }
    fn identity(&self) -> Option<Identity> {
        unimplemented!("Task 14")
    }
    fn may_send_text(&self) -> bool {
        unimplemented!("Task 14")
    }
    fn max_batch(&self) -> usize {
        unimplemented!("Task 14")
    }
    fn lookup<'a>(
        &'a self,
        _kind: KeyKind,
        _keys: &'a [[u8; 32]],
    ) -> BoxFuture<'a, Result<Vec<Option<QuantRow>>, EmbedError>> {
        unimplemented!("Task 14")
    }
    fn embed<'a>(
        &'a self,
        _items: &'a [Item],
        _overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        unimplemented!("Task 14")
    }
    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>> {
        unimplemented!("Task 14")
    }
}
