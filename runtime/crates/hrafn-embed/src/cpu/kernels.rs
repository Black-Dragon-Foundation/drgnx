//! One row of each non-linear step. The bodies are written so the compiler vectorises them, and are built twice on x86-64:
//! baseline, and under AVX2 + FMA, chosen at run time. The build itself stays baseline, and aarch64 uses baseline NEON.
//!
//! No AVX-512: it ran slower here (1.02 against 1.15 chunks/s).

/// A model's sizes, in floats.
#[derive(Clone, Copy)]
pub(super) struct Shape {
    pub(super) hidden: usize,
    pub(super) head: usize,
    pub(super) heads: usize,
    pub(super) glu: usize,
    pub(super) scale: f32,
    pub(super) eps: f32,
}

/// `exp` for x <= 0, cephes-style; the loop vectorises where `f32::exp` would not.
#[inline(always)]
fn exp_all(values: &mut [f32]) {
    for x in values.iter_mut() {
        let a = x.max(-87.0);
        let n = (a * std::f32::consts::LOG2_E + 0.5).floor();
        let r = a - n * 0.693_359_4 + n * 2.121_944_4e-4;
        let p = (((((1.987_569_1e-4 * r + 1.398_199_9e-3) * r + 8.333_452e-3) * r
            + 4.166_579_6e-2)
            * r
            + 0.166_666_66)
            * r
            + 0.5)
            * r
            * r
            + r
            + 1.0;
        *x = p * f32::from_bits((((n as i32) + 127) << 23) as u32);
    }
}

/// One token's attention over its span. `q`: the token's q row; `qkv`: all tokens' q, k and v; `out`: the token's row.
#[inline(always)]
fn attn_row(s: Shape, q: &[f32], qkv: &[f32], span: [u32; 2], out: &mut [f32], scores: &mut [f32]) {
    let (from, to) = (span[0] as usize, span[1] as usize);
    let row = 3 * s.hidden;
    for h in 0..s.heads {
        let head = h * s.head;
        let q = &q[head..head + s.head];
        let scores = &mut scores[..to - from];
        for (j, score) in scores.iter_mut().enumerate() {
            let k = &qkv[(from + j) * row + s.hidden + head..][..s.head];
            let mut sum = [0f32; 8];
            for (a, b) in q.as_chunks::<8>().0.iter().zip(k.as_chunks::<8>().0) {
                for l in 0..8 {
                    sum[l] += a[l] * b[l];
                }
            }
            *score = sum.iter().sum::<f32>() * s.scale;
        }
        let top = scores.iter().copied().fold(f32::MIN, f32::max);
        scores.iter_mut().for_each(|x| *x -= top);
        exp_all(scores);
        let den: f32 = scores.iter().sum();
        let out = &mut out[head..head + s.head];
        out.fill(0.0);
        for (j, score) in scores.iter().enumerate() {
            let v = &qkv[(from + j) * row + 2 * s.hidden + head..][..s.head];
            let w = score / den;
            for (o, x) in out.iter_mut().zip(v) {
                *o += w * x;
            }
        }
    }
}

/// LayerNorm without bias.
#[inline(always)]
fn norm_row(s: Shape, x: &[f32], gain: &[f32], y: &mut [f32]) {
    let (mut sum, mut squares) = ([0f32; 16], [0f32; 16]);
    let (lanes, rest) = x.as_chunks::<16>();
    for (l, v) in rest.iter().enumerate() {
        sum[l] += v;
        squares[l] += v * v;
    }
    for c in lanes {
        for l in 0..16 {
            sum[l] += c[l];
            squares[l] += c[l] * c[l];
        }
    }
    let size = s.hidden as f32;
    let mean = sum.iter().sum::<f32>() / size;
    let f = 1.0 / (squares.iter().sum::<f32>() / size - mean * mean + s.eps).sqrt();
    for ((y, x), g) in y.iter_mut().zip(x).zip(gain) {
        *y = (x - mean) * f * g;
    }
}

/// GeGLU: `m` holds x then g; erf is Abramowitz & Stegun 7.1.28.
#[inline(always)]
fn glu_row(m: &[f32], y: &mut [f32]) {
    let (a, g) = m.split_at(m.len() / 2);
    for ((y, a), g) in y.iter_mut().zip(a).zip(g) {
        let v = a * std::f32::consts::FRAC_1_SQRT_2;
        let x = v.abs();
        let p = 1.0
            + x * (0.070_523_08
                + x * (0.042_282_01
                    + x * (0.009_270_527
                        + x * (0.000_152_014_3 + x * (0.000_276_567_2 + x * 0.000_043_063_8)))));
        let p2 = p * p;
        let p4 = p2 * p2;
        let p16 = (p4 * p4) * (p4 * p4);
        let erf = (1.0 - 1.0 / p16).copysign(v);
        *y = 0.5 * a * (1.0 + erf) * g;
    }
}

/// In place on a token's q and k. `table`: this position's cos then sin.
#[inline(always)]
fn rope_row(s: Shape, x: &mut [f32], table: &[f32]) {
    let half = s.head / 2;
    let (cos, sin) = table.split_at(half);
    for head in x[..2 * s.hidden].chunks_exact_mut(s.head) {
        let (lo, hi) = head.split_at_mut(half);
        for i in 0..half {
            let (l, h) = (lo[i], hi[i]);
            lo[i] = l * cos[i] - h * sin[i];
            hi[i] = h * cos[i] + l * sin[i];
        }
    }
}

type Attn = unsafe fn(Shape, &[f32], &[f32], [u32; 2], &mut [f32], &mut [f32]);

/// The row kernels of one instruction set.
#[derive(Clone, Copy)]
pub(super) struct Kernels {
    pub(super) attn: Attn,
    pub(super) norm: unsafe fn(Shape, &[f32], &[f32], &mut [f32]),
    pub(super) glu: unsafe fn(&[f32], &mut [f32]),
    pub(super) rope: unsafe fn(Shape, &mut [f32], &[f32]),
}

mod baseline {
    use super::*;
    pub(super) fn attn(
        s: Shape,
        q: &[f32],
        a: &[f32],
        span: [u32; 2],
        o: &mut [f32],
        t: &mut [f32],
    ) {
        attn_row(s, q, a, span, o, t)
    }
    pub(super) fn norm(s: Shape, x: &[f32], g: &[f32], y: &mut [f32]) {
        norm_row(s, x, g, y)
    }
    pub(super) fn glu(m: &[f32], y: &mut [f32]) {
        glu_row(m, y)
    }
    pub(super) fn rope(s: Shape, x: &mut [f32], c: &[f32]) {
        rope_row(s, x, c)
    }
}

#[cfg(target_arch = "x86_64")]
mod avx2 {
    use super::*;
    #[target_feature(enable = "avx2,fma")]
    pub(super) fn attn(
        s: Shape,
        q: &[f32],
        a: &[f32],
        span: [u32; 2],
        o: &mut [f32],
        t: &mut [f32],
    ) {
        attn_row(s, q, a, span, o, t)
    }
    #[target_feature(enable = "avx2,fma")]
    pub(super) fn norm(s: Shape, x: &[f32], g: &[f32], y: &mut [f32]) {
        norm_row(s, x, g, y)
    }
    #[target_feature(enable = "avx2,fma")]
    pub(super) fn glu(m: &[f32], y: &mut [f32]) {
        glu_row(m, y)
    }
    #[target_feature(enable = "avx2,fma")]
    pub(super) fn rope(s: Shape, x: &mut [f32], c: &[f32]) {
        rope_row(s, x, c)
    }
}

pub(super) const BASELINE: Kernels = Kernels {
    attn: baseline::attn,
    norm: baseline::norm,
    glu: baseline::glu,
    rope: baseline::rope,
};

/// The best kernels this CPU runs.
pub(super) fn detect() -> Kernels {
    #[cfg(target_arch = "x86_64")]
    if is_x86_feature_detected!("avx2") && is_x86_feature_detected!("fma") {
        return Kernels {
            attn: avx2::attn,
            norm: avx2::norm,
            glu: avx2::glu,
            rope: avx2::rope,
        };
    }
    BASELINE
}
