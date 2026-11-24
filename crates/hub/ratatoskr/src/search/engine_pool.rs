//! The engine pool (the user, 2026-11-23: one engine per GPU in v1; study §A10). Each member is one `llama-server` on
//! one device (`--device X --split-mode none`); the pool hands each whole batches, split by the members' measured
//! rates, and moves a dead member's batch to the others. A pool of one is the single engine.
//!
//! A member's rate is vectors per second, measured on the batches it embeds (a moving average) and kept with the pin
//! ([`super::engine_pick::Pin`]): the next start begins from it.

use super::engine::ENGINE_BATCH;
use super::sources::SourceKind;
use hrafn_embed::fingerprint::Identity;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use urdr::graph::search::{BoxFuture, EmbedError};

/// One engine of the pool.
pub trait Lane: Send + Sync + 'static {
    fn embed<'a>(&'a self, texts: &'a [String])
    -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>>;
    fn query<'a>(
        &'a self,
        q: &'a str,
        instruction: Option<&'a str>,
    ) -> BoxFuture<'a, Result<Vec<f32>, EmbedError>>;
}

/// How much of a new measurement the rate takes.
const NEW_WEIGHT: f64 = 0.5;
/// The fewest texts a measurement needs (a batch of one says little).
const MEASURE_MIN: usize = 4;

struct Member {
    id: String,
    lane: Arc<dyn Lane>,
    rate: Mutex<f64>,
    dead: AtomicBool,
}

/// What the pool tells whoever keeps the rates.
pub type OnRate = Box<dyn Fn(&str, f64) + Send + Sync>;

pub struct EnginePool {
    members: Vec<Arc<Member>>,
    identity: Identity,
    on_rate: Option<OnRate>,
}

/// N texts split over WEIGHTS: each gets its share, the rounding going to the largest remainders; the shares sum to N.
pub fn split_weighted(n: usize, weights: &[f64]) -> Vec<usize> {
    let total: f64 = weights.iter().map(|w| w.max(0.0)).sum();
    if weights.is_empty() {
        return Vec::new();
    }
    if total <= 0.0 {
        let mut out = vec![n / weights.len(); weights.len()];
        out[0] += n - out.iter().sum::<usize>();
        return out;
    }
    let exact: Vec<f64> = weights
        .iter()
        .map(|w| n as f64 * w.max(0.0) / total)
        .collect();
    let mut out: Vec<usize> = exact.iter().map(|e| *e as usize).collect();
    let mut left = n - out.iter().sum::<usize>();
    let mut order: Vec<usize> = (0..weights.len()).collect();
    order.sort_by(|&a, &b| {
        (exact[b] - exact[b].floor())
            .total_cmp(&(exact[a] - exact[a].floor()))
            .then(a.cmp(&b))
    });
    for i in order {
        if left == 0 {
            break;
        }
        out[i] += 1;
        left -= 1;
    }
    out
}

impl EnginePool {
    /// LANES: id, engine and its starting rate (the pin's, or 1 when none was measured).
    pub fn new(
        lanes: Vec<(String, Arc<dyn Lane>, f64)>,
        identity: Identity,
        on_rate: Option<OnRate>,
    ) -> EnginePool {
        EnginePool {
            members: lanes
                .into_iter()
                .map(|(id, lane, rate)| {
                    Arc::new(Member {
                        id,
                        lane,
                        rate: Mutex::new(if rate > 0.0 { rate } else { 1.0 }),
                        dead: AtomicBool::new(false),
                    })
                })
                .collect(),
            identity,
            on_rate,
        }
    }

    pub fn identity(&self) -> Identity {
        self.identity.clone()
    }

    /// The members' ids and rates now.
    pub fn rates(&self) -> Vec<(String, f64)> {
        self.members
            .iter()
            .map(|m| {
                (
                    m.id.clone(),
                    *m.rate.lock().unwrap_or_else(PoisonError::into_inner),
                )
            })
            .collect()
    }

    fn alive(&self) -> Vec<Arc<Member>> {
        self.members
            .iter()
            .filter(|m| !m.dead.load(Ordering::SeqCst))
            .cloned()
            .collect()
    }

    /// Vectors for TEXTS in their order: one share per live member by its rate, all at once; a member that fails is
    /// marked dead (when another is left) and its share goes to the others.
    pub async fn embed_docs(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedError> {
        if texts.is_empty() {
            return Ok(Vec::new());
        }
        let mut out: Vec<Option<Vec<f32>>> = vec![None; texts.len()];
        let mut todo: Vec<usize> = (0..texts.len()).collect();
        while !todo.is_empty() {
            let alive = self.alive();
            if alive.is_empty() {
                return Err(EmbedError("every engine of the pool failed".into()));
            }
            let weights: Vec<f64> = alive
                .iter()
                .map(|m| *m.rate.lock().unwrap_or_else(PoisonError::into_inner))
                .collect();
            let shares = split_weighted(todo.len(), &weights);
            let mut jobs = Vec::new();
            let mut at = 0;
            for (m, n) in alive.iter().zip(shares) {
                if n == 0 {
                    continue;
                }
                let ids: Vec<usize> = todo[at..at + n].to_vec();
                at += n;
                let batch: Vec<String> = ids.iter().map(|&i| texts[i].clone()).collect();
                let m = m.clone();
                jobs.push((
                    ids,
                    crate::clock::spawn("search:engine-pool", async move {
                        let begun = crate::clock::real_now();
                        let got = m.lane.embed(&batch).await;
                        (m, batch.len(), begun.elapsed(), got)
                    }),
                ));
            }
            let mut retry = Vec::new();
            let mut last_error = None;
            for (ids, job) in jobs {
                let (m, n, took, got) = job
                    .await
                    .map_err(|e| EmbedError(format!("an engine task ended: {e}")))?;
                match got {
                    Ok(vectors) if vectors.len() == ids.len() => {
                        self.measured(&m, n, took);
                        for (i, v) in ids.into_iter().zip(vectors) {
                            out[i] = Some(v);
                        }
                    }
                    other => {
                        let why = match other {
                            Ok(v) => EmbedError(format!(
                                "the engine {} answered {} vectors for {} texts",
                                m.id,
                                v.len(),
                                ids.len()
                            )),
                            Err(e) => e,
                        };
                        if alive.len() == 1 {
                            return Err(why);
                        }
                        tracing::warn!(
                            "search: the engine {} failed; its batch moves: {}",
                            m.id,
                            why.0
                        );
                        m.dead.store(true, Ordering::SeqCst);
                        last_error = Some(why);
                        retry.extend(ids);
                    }
                }
            }
            if self.alive().is_empty() {
                return Err(last_error.unwrap_or_else(|| EmbedError("every engine failed".into())));
            }
            retry.sort_unstable();
            todo = retry;
        }
        Ok(out.into_iter().map(Option::unwrap_or_default).collect())
    }

    fn measured(&self, m: &Member, n: usize, took: std::time::Duration) {
        if n < MEASURE_MIN || took.is_zero() {
            return;
        }
        let new = n as f64 / took.as_secs_f64();
        let rate = {
            let mut r = m.rate.lock().unwrap_or_else(PoisonError::into_inner);
            *r = *r * (1.0 - NEW_WEIGHT) + new * NEW_WEIGHT;
            *r
        };
        if let Some(f) = &self.on_rate {
            f(&m.id, rate);
        }
    }

    /// The vector of query Q, from the fastest live member.
    pub async fn embed_query(
        &self,
        q: &str,
        instruction: Option<&str>,
    ) -> Result<Vec<f32>, EmbedError> {
        let alive = self.alive();
        let best = alive
            .iter()
            .max_by(|a, b| {
                let r = |m: &Member| *m.rate.lock().unwrap_or_else(PoisonError::into_inner);
                r(a).total_cmp(&r(b))
            })
            .ok_or_else(|| EmbedError("every engine of the pool failed".into()))?;
        best.lane.query(q, instruction).await
    }

    pub fn len(&self) -> usize {
        self.members.len()
    }

    pub fn is_empty(&self) -> bool {
        self.members.is_empty()
    }
}

impl super::DocEmbedder for EnginePool {
    fn identity(&self) -> Option<Identity> {
        Some(self.identity.clone())
    }

    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>> {
        Box::pin(async move { Ok(self.identity.clone()) })
    }

    fn source_id(&self) -> String {
        "llama".into()
    }

    fn source_kind(&self) -> SourceKind {
        SourceKind::LocalEngine
    }

    /// One engine's batch per live member, so each stays as busy as alone.
    fn max_batch(&self) -> usize {
        ENGINE_BATCH * self.alive().len().max(1)
    }

    fn embed_docs<'a>(
        &'a self,
        texts: &'a [String],
        _overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        Box::pin(EnginePool::embed_docs(self, texts))
    }
}

impl urdr::graph::search::Embedder for EnginePool {
    fn embed<'a>(
        &'a self,
        texts: &'a [String],
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        Box::pin(EnginePool::embed_docs(self, texts))
    }

    /// The fingerprint's hex: the key of the entity vectors it makes.
    fn model(&self) -> String {
        self.identity.fp.hex()
    }
}
