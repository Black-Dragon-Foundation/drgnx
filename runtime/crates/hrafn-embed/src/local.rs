//! The built-in embedder: one interface over the forward pass, whichever device runs it.
//!
//! `Engine` is private, with one impl per path, so a different engine replaces an impl and nothing else. What the paths
//! share is here: a batch's flat layout and the word embeddings, gathered on the CPU so that the table costs no VRAM and
//! fits any adapter's largest binding.

use crate::cache::{self, ModelState};
use crate::gpu::GpuEngine;
use crate::models::{Arch, LoadError, ModelConfig, ModelSpec};
use crate::tokens::Tokens;
use crate::weights::Weights;
use half::f16;
use half::slice::HalfFloatSliceExt;
use std::path::Path;
use std::time::Duration;

/// The most tokens in one batch, which sizes the GPU's scratch.
pub const TOKEN_CAP: usize = 4096;

/// The conveniences' batch budget. Task-sized work uses `embed_ids` with a budget of its own.
const DOC_BUDGET: usize = 2048;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Device {
    Cpu { threads: usize },
    Gpu { adapter: String },
}

pub struct Forward {
    pub vectors: Vec<Vec<f32>>,
    /// The longest submit of the batch. Zero on the CPU path.
    pub worst_submit: Duration,
}

#[derive(Debug, PartialEq, Eq)]
pub enum EmbedFail {
    DeviceLost(String),
    Other(String),
}

/// Measurement and test switches; production uses the default.
#[doc(hidden)]
#[derive(Debug, Clone, Copy, Default)]
pub struct Tuning {
    /// f32 weights even where the adapter has `SHADER_F16`.
    pub f32_weights: bool,
    /// wgpu's bounds checks in the shaders. Production runs without them: they cost 14 to 29 % on the Radeon.
    pub checked: bool,
}

pub(crate) trait Engine: Send {
    /// Raw CLS vectors of one validated batch.
    fn forward(&mut self, batch: &[Vec<u32>]) -> Result<Forward, EmbedFail>;
    fn lose_device(&self) {}
}

/// A batch laid out flat: token t of the batch is row t, whatever chunk it belongs to. Spans are half-open row ranges.
pub(crate) struct Layout {
    pub(crate) tokens: usize,
    /// Each chunk's first row.
    pub(crate) cls: Vec<u32>,
    /// `[position, 0]` per row.
    pub(crate) positions: Vec<[u32; 2]>,
    /// The chunk's rows, per row.
    pub(crate) global: Vec<[u32; 2]>,
    /// The rows within `half_window` of this one in its chunk, per row.
    pub(crate) local: Vec<[u32; 2]>,
}

impl Layout {
    pub(crate) fn new(batch: &[Vec<u32>], half_window: usize) -> Layout {
        let tokens = batch.iter().map(Vec::len).sum();
        let mut l = Layout {
            tokens,
            cls: Vec::with_capacity(batch.len()),
            positions: Vec::with_capacity(tokens),
            global: Vec::with_capacity(tokens),
            local: Vec::with_capacity(tokens),
        };
        let mut start = 0;
        for chunk in batch {
            let n = chunk.len();
            l.cls.push(start as u32);
            for i in 0..n {
                l.positions.push([i as u32, 0]);
                l.global.push([start as u32, (start + n) as u32]);
                let (from, to) = (i.saturating_sub(half_window), (i + half_window + 1).min(n));
                l.local.push([(start + from) as u32, (start + to) as u32]);
            }
            start += n;
        }
        l
    }
}

/// The word embeddings, kept as f16.
pub(crate) struct Gather {
    table: Vec<f16>,
    hidden: usize,
}

impl Gather {
    pub(crate) fn new(weights: &Weights, hidden: usize) -> Result<Gather, LoadError> {
        let bytes = weights.f16_bytes("embeddings.tok_embeddings.weight")?;
        let table = bytes
            .chunks_exact(2)
            .map(|b| f16::from_le_bytes([b[0], b[1]]))
            .collect();
        Ok(Gather { table, hidden })
    }

    /// One f32 row per token. Ids were checked against the vocabulary.
    pub(crate) fn rows(&self, batch: &[Vec<u32>]) -> Vec<f32> {
        let tokens: usize = batch.iter().map(Vec::len).sum();
        let mut out = vec![0f32; tokens * self.hidden];
        let rows = out.chunks_exact_mut(self.hidden);
        for (id, row) in batch.iter().flatten().zip(rows) {
            let at = *id as usize * self.hidden;
            self.table[at..at + self.hidden].convert_to_f32_slice(row);
        }
        out
    }
}

/// The RoPE table: for each position, the cos and then the sin of each of the head's `head / 2` frequencies.
pub(crate) fn rope_table(head: usize, theta: f64, positions: usize) -> Vec<f32> {
    let inverse: Vec<f64> = (0..head)
        .step_by(2)
        .map(|i| theta.powf(i as f64 / head as f64).recip())
        .collect();
    let mut table = Vec::with_capacity(positions * head);
    for position in 0..positions {
        table.extend(inverse.iter().map(|f| (position as f64 * f).cos() as f32));
        table.extend(inverse.iter().map(|f| (position as f64 * f).sin() as f32));
    }
    table
}

fn unit(v: &mut [f32]) {
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-12);
    v.iter_mut().for_each(|x| *x /= n);
}

/// Greedy batches of at most `budget` tokens, in order. A list over the budget gets a batch of its own.
fn batches(lists: Vec<Vec<u32>>, budget: usize) -> Vec<Vec<Vec<u32>>> {
    let mut out: Vec<Vec<Vec<u32>>> = Vec::new();
    let mut held = 0;
    for list in lists {
        let n = list.len();
        match out.last_mut() {
            Some(batch) if held + n <= budget => batch.push(list),
            _ => {
                out.push(vec![list]);
                held = 0;
            }
        }
        held += n;
    }
    out
}

pub struct LocalEmbedder {
    spec: &'static ModelSpec,
    tokens: Tokens,
    vocab: usize,
    engine: Box<dyn Engine>,
}

impl LocalEmbedder {
    /// Refuses a model that is not `Ready` (this hashes it), a family with no engine, and an adapter whose limits are too
    /// small.
    pub fn load(
        spec: &'static ModelSpec,
        dir: &Path,
        device: &Device,
    ) -> Result<LocalEmbedder, LoadError> {
        Self::load_tuned(spec, dir, device, Tuning::default())
    }

    #[doc(hidden)]
    pub fn load_tuned(
        spec: &'static ModelSpec,
        dir: &Path,
        device: &Device,
        tuning: Tuning,
    ) -> Result<LocalEmbedder, LoadError> {
        match cache::state(spec, dir) {
            ModelState::Ready => {}
            other => return Err(LoadError::NotReady(format!("{}: {other:?}", spec.id))),
        }
        if spec.arch != Arch::ModernBert {
            return Err(LoadError::Format(format!(
                "{}: no engine for {:?} yet",
                spec.id, spec.arch
            )));
        }
        let config = ModelConfig::read(dir)?;
        config.check_engine_shape(spec.dims)?;
        let weights = Weights::read(dir)?;
        let tokens = Tokens::load(spec, dir)?;
        let engine: Box<dyn Engine> = match device {
            Device::Cpu { .. } => return Err(LoadError::Device("no CPU path yet".into())),
            Device::Gpu { adapter } => Box::new(GpuEngine::load(
                &config,
                spec.max_tokens,
                &weights,
                adapter,
                tuning,
            )?),
        };
        Ok(LocalEmbedder {
            spec,
            tokens,
            vocab: config.vocab,
            engine,
        })
    }

    pub fn encode_doc(&self, text: &str) -> Vec<u32> {
        self.tokens.encode_doc(text)
    }

    pub fn encode_query(&self, q: &str, instruction: Option<&str>) -> Vec<u32> {
        self.tokens.encode_query(q, instruction)
    }

    /// One batch of at most `TOKEN_CAP` tokens, unit vectors in order. Nothing unchecked reaches an engine.
    pub fn embed_ids(&mut self, batch: &[Vec<u32>]) -> Result<Forward, EmbedFail> {
        let total: usize = batch.iter().map(Vec::len).sum();
        if total > TOKEN_CAP {
            return Err(EmbedFail::Other(format!(
                "{total} tokens is over the batch cap of {TOKEN_CAP}"
            )));
        }
        for ids in batch {
            if ids.is_empty() || ids.len() > self.spec.max_tokens {
                return Err(EmbedFail::Other(format!("a chunk of {} tokens", ids.len())));
            }
            if let Some(id) = ids.iter().find(|id| **id as usize >= self.vocab) {
                return Err(EmbedFail::Other(format!(
                    "token id {id} is over the vocabulary of {}",
                    self.vocab
                )));
            }
        }
        if batch.is_empty() {
            return Ok(Forward {
                vectors: Vec::new(),
                worst_submit: Duration::ZERO,
            });
        }
        let mut forward = self.engine.forward(batch)?;
        forward.vectors.iter_mut().for_each(|v| unit(v));
        Ok(forward)
    }

    /// One unit vector per text, in order.
    pub fn embed_docs(&mut self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedFail> {
        let lists = texts.iter().map(|t| self.tokens.encode_doc(t)).collect();
        let mut out = Vec::with_capacity(texts.len());
        for batch in batches(lists, DOC_BUDGET) {
            out.extend(self.embed_ids(&batch)?.vectors);
        }
        Ok(out)
    }

    pub fn embed_query(
        &mut self,
        q: &str,
        instruction: Option<&str>,
    ) -> Result<Vec<f32>, EmbedFail> {
        let ids = self.tokens.encode_query(q, instruction);
        let mut vectors = self.embed_ids(&[ids])?.vectors;
        vectors
            .pop()
            .ok_or_else(|| EmbedFail::Other("no vector".into()))
    }

    /// Ends the device under the embedder, as a driver reset would.
    #[doc(hidden)]
    pub fn lose_device(&self) {
        self.engine.lose_device();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn batches_keep_order_and_budget() {
        let lists = vec![vec![1; 3], vec![2; 3], vec![3; 3], vec![4; 7], vec![5; 1]];
        let sizes: Vec<Vec<usize>> = batches(lists, 6)
            .iter()
            .map(|b| b.iter().map(Vec::len).collect())
            .collect();
        assert_eq!(sizes, [vec![3, 3], vec![3], vec![7], vec![1]]);
    }

    #[test]
    fn spans_stay_inside_their_chunk() {
        let l = Layout::new(&[vec![0; 3], vec![0; 200]], 64);
        assert_eq!(l.tokens, 203);
        assert_eq!(l.cls, [0, 3]);
        assert_eq!(l.global[2], [0, 3]);
        assert_eq!(l.global[3], [3, 203]);
        assert_eq!(l.local[1], [0, 3]);
        assert_eq!(l.local[3], [3, 3 + 65]);
        assert_eq!(l.local[3 + 100], [3 + 36, 3 + 165]);
        assert_eq!(l.local[202], [3 + 135, 203]);
        assert_eq!(l.positions[202], [199, 0]);
    }

    #[test]
    fn rope_table_starts_at_identity() {
        let t = rope_table(8, 10000.0, 2);
        assert_eq!(t.len(), 16);
        assert_eq!(&t[..8], [1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0]);
        assert!((t[8] - 1f32.cos()).abs() < 1e-6 && (t[12] - 1f32.sin()).abs() < 1e-6);
    }
}
