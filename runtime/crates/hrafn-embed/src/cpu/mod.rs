//! The CPU path: the same forward pass in pure Rust. Flat tokens, no padding, no S × S matrix, f32 weights. `gemm` does the
//! matmuls, and the rest runs row by row on a `rayon` pool the embedder owns, so `threads` means what it says.

mod kernels;

use crate::local::{EmbedFail, Engine, Forward, Gather, Layout, Tuning, rope_table};
use crate::models::{LoadError, ModelConfig};
use crate::weights::Weights;
use gemm::{Parallelism, gemm};
use kernels::{Kernels, Shape};
use rayon::prelude::*;
use std::time::Duration;

struct Layer {
    /// The first layer starts from the embeddings' norm instead.
    attn_norm: Option<Vec<f32>>,
    qkv: Vec<f32>,
    attn_out: Vec<f32>,
    mlp_norm: Vec<f32>,
    mlp_in: Vec<f32>,
    mlp_out: Vec<f32>,
    local: bool,
}

pub(crate) struct CpuEngine {
    shape: Shape,
    kernels: Kernels,
    pool: rayon::ThreadPool,
    threads: usize,
    gather: Gather,
    embedding_norm: Vec<f32>,
    final_norm: Vec<f32>,
    layers: Vec<Layer>,
    local_table: Vec<f32>,
    global_table: Vec<f32>,
    half_window: usize,
    max_tokens: usize,
}

/// y = x * W, for W as the file stores it: outputs × inputs.
fn linear(x: &[f32], inputs: usize, w: &[f32], outputs: usize, y: &mut [f32], threads: usize) {
    let tokens = x.len() / inputs;
    let parallelism = if threads > 1 {
        Parallelism::Rayon(threads)
    } else {
        Parallelism::None
    };
    let (cols, rows) = (inputs as isize, outputs as isize);
    // SAFETY: y holds tokens × outputs, x tokens × inputs and w outputs × inputs, at these strides.
    unsafe {
        gemm(
            tokens,
            outputs,
            inputs,
            y.as_mut_ptr(),
            1,
            rows,
            false,
            x.as_ptr(),
            1,
            cols,
            w.as_ptr(),
            cols,
            1,
            0.0,
            1.0,
            false,
            false,
            false,
            parallelism,
        );
    }
}

fn add(h: &mut [f32], r: &[f32]) {
    h.par_chunks_mut(4096)
        .zip(r.par_chunks(4096))
        .for_each(|(h, r)| {
            h.iter_mut().zip(r).for_each(|(a, b)| *a += b);
        });
}

impl CpuEngine {
    pub(crate) fn load(
        c: &ModelConfig,
        max_tokens: usize,
        weights: &Weights,
        threads: usize,
        tuning: Tuning,
    ) -> Result<CpuEngine, LoadError> {
        let threads = threads.max(1);
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .map_err(|e| LoadError::Device(e.to_string()))?;
        let head = c.hidden / c.heads;
        let mut layers = Vec::with_capacity(c.layers);
        for i in 0..c.layers {
            let name = |s: &str| format!("layers.{i}.{s}");
            layers.push(Layer {
                attn_norm: if i == 0 {
                    None
                } else {
                    Some(weights.f32(&name("attn_norm.weight"))?)
                },
                qkv: weights.f32(&name("attn.Wqkv.weight"))?,
                attn_out: weights.f32(&name("attn.Wo.weight"))?,
                mlp_norm: weights.f32(&name("mlp_norm.weight"))?,
                mlp_in: weights.f32(&name("mlp.Wi.weight"))?,
                mlp_out: weights.f32(&name("mlp.Wo.weight"))?,
                local: i % c.global_every != 0,
            });
        }
        Ok(CpuEngine {
            shape: Shape {
                hidden: c.hidden,
                head,
                heads: c.heads,
                glu: c.intermediate,
                scale: 1.0 / (head as f32).sqrt(),
                eps: c.norm_eps,
            },
            kernels: if tuning.baseline_cpu {
                kernels::BASELINE
            } else {
                kernels::detect()
            },
            pool,
            threads,
            gather: Gather::new(weights, c.hidden)?,
            embedding_norm: weights.f32("embeddings.norm.weight")?,
            final_norm: weights.f32("final_norm.weight")?,
            layers,
            local_table: rope_table(head, c.local_theta, max_tokens),
            global_table: rope_table(head, c.global_theta, max_tokens),
            half_window: c.local_window / 2,
            max_tokens,
        })
    }

    fn norm_all(&self, x: &[f32], gain: &[f32], y: &mut [f32]) {
        let (s, kernels) = (self.shape, self.kernels);
        y.par_chunks_mut(s.hidden)
            .zip(x.par_chunks(s.hidden))
            .for_each(|(y, x)| {
                // SAFETY: `detect` chose kernels this CPU runs.
                unsafe { (kernels.norm)(s, x, gain, y) }
            });
    }

    fn run(&self, batch: &[Vec<u32>]) -> Vec<Vec<f32>> {
        let (s, kernels) = (self.shape, self.kernels);
        let (hid, glu) = (s.hidden, s.glu);
        let layout = Layout::new(batch, self.half_window);
        let t = layout.tokens;
        let embedded = self.gather.rows(batch);
        let (mut h, mut n, mut r) = (
            vec![0f32; t * hid],
            vec![0f32; t * hid],
            vec![0f32; t * hid],
        );
        let (mut q, mut m, mut g) = (
            vec![0f32; t * 3 * hid],
            vec![0f32; t * 2 * glu],
            vec![0f32; t * glu],
        );
        self.norm_all(&embedded, &self.embedding_norm, &mut h);
        for layer in &self.layers {
            match &layer.attn_norm {
                Some(gain) => {
                    self.norm_all(&h, gain, &mut n);
                    linear(&n, hid, &layer.qkv, 3 * hid, &mut q, self.threads);
                }
                None => linear(&h, hid, &layer.qkv, 3 * hid, &mut q, self.threads),
            }
            let (table, spans) = if layer.local {
                (&self.local_table, &layout.local)
            } else {
                (&self.global_table, &layout.global)
            };
            q.par_chunks_mut(3 * hid)
                .zip(layout.positions.par_iter())
                .for_each(|(x, p)| {
                    let position = p[0] as usize * s.head;
                    // SAFETY: as in `norm_all`.
                    unsafe { (kernels.rope)(s, x, &table[position..position + s.head]) }
                });
            let qkv = &q;
            r.par_chunks_mut(hid).enumerate().for_each_init(
                || vec![0f32; self.max_tokens],
                |scores, (token, out)| {
                    let row = &qkv[token * 3 * hid..token * 3 * hid + hid];
                    // SAFETY: as in `norm_all`.
                    unsafe { (kernels.attn)(s, row, qkv, spans[token], out, scores) }
                },
            );
            linear(&r, hid, &layer.attn_out, hid, &mut n, self.threads);
            add(&mut h, &n);
            self.norm_all(&h, &layer.mlp_norm, &mut n);
            linear(&n, hid, &layer.mlp_in, 2 * glu, &mut m, self.threads);
            g.par_chunks_mut(glu)
                .zip(m.par_chunks(2 * glu))
                .for_each(|(y, m)| {
                    // SAFETY: as in `norm_all`.
                    unsafe { (kernels.glu)(m, y) }
                });
            linear(&g, glu, &layer.mlp_out, hid, &mut n, self.threads);
            add(&mut h, &n);
        }
        self.norm_all(&h, &self.final_norm, &mut n);
        layout
            .cls
            .iter()
            .map(|&at| n[at as usize * hid..(at as usize + 1) * hid].to_vec())
            .collect()
    }
}

impl Engine for CpuEngine {
    fn forward(&mut self, batch: &[Vec<u32>]) -> Result<Forward, EmbedFail> {
        let vectors = self.pool.install(|| self.run(batch));
        Ok(Forward {
            vectors,
            worst_submit: Duration::ZERO,
        })
    }
}
