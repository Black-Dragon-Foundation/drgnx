//! Chrome primitives (design §6.3; Task 15's approved case): the only things chrome is made of.
//!
//! Quads with a radius, a two-stop gradient quad (the tab strip's fade), rings, shadows, sprites (icon masks from the
//! A8 atlas, tinted) and text runs. Every primitive carries a stable id per chrome element part, so a commit diffs by
//! id and a GPU presenter resubmits. There is no primitive that carries pixels: the one host raster is the glyph masks
//! in the atlases; icon masks are Glitnir's own raster ([`crate::icon`]). Colours are premultiplied ARGB, Cairo's order.
//!
//! [`compose`] draws a list in order, source-over, into a premultiplied ARGB buffer (the CPU presenter); each primitive
//! is clipped to the strip or band it belongs to, so nothing draws outside it. Naglfar draws the same list.

use crate::atlas::{AtlasKind, Atlases, GlyphId};
use crate::geom::Rect;
use crate::text::TextRun;

/// A gradient's direction.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Axis {
    /// Left to right.
    H,
    /// Top to bottom.
    V,
}

/// One chrome primitive. Rects are device px of the target; radii and widths device px.
#[derive(Clone, Debug, PartialEq)]
pub enum Prim {
    Quad {
        id: u64,
        rect: Rect,
        radius: f32,
        fill: u32,
    },
    /// Two stops at positions 0..1 along `axis`, interpolated premultiplied.
    GradQuad {
        id: u64,
        rect: Rect,
        radius: f32,
        axis: Axis,
        stops: [(f32, u32); 2],
    },
    /// A ring `width` px wide just inside `rect`'s rounded edge.
    Ring {
        id: u64,
        rect: Rect,
        radius: f32,
        width: u32,
        argb: u32,
    },
    /// A soft shadow of the rounded `rect`, grown by `spread`, blurred by `blur` (CSS: σ = blur / 2), offset.
    Shadow {
        id: u64,
        rect: Rect,
        radius: f32,
        blur: f32,
        offset: (f32, f32),
        spread: f32,
        argb: u32,
    },
    /// An icon mask (A8 atlas, `key.font` = [`crate::atlas::ICON_FONT`]) with its top-left at `at`, tinted.
    Sprite {
        id: u64,
        at: (i32, i32),
        key: GlyphId,
        tint: u32,
    },
    Text {
        id: u64,
        run: TextRun,
    },
}

/// The kinds a scene may hold: nothing else exists (§6.3 rule 1).
pub const KINDS: [&str; 6] = ["quad", "grad-quad", "ring", "shadow", "sprite", "text"];

impl Prim {
    pub fn id(&self) -> u64 {
        match self {
            Prim::Quad { id, .. }
            | Prim::GradQuad { id, .. }
            | Prim::Ring { id, .. }
            | Prim::Shadow { id, .. }
            | Prim::Sprite { id, .. }
            | Prim::Text { id, .. } => *id,
        }
    }

    /// Where the primitive may draw (device px): its rect, a shadow's reach, a sprite's square, a run's clip.
    pub fn bounds(&self) -> Rect {
        match self {
            Prim::Quad { rect, .. } | Prim::GradQuad { rect, .. } | Prim::Ring { rect, .. } => {
                *rect
            }
            Prim::Shadow {
                rect,
                blur,
                offset,
                spread,
                ..
            } => {
                let reach = (3.0 * (blur / 2.0).max(0.5)).ceil() as i32 + spread.ceil() as i32;
                let r = rect.translate(offset.0.round() as i32, offset.1.round() as i32);
                Rect::new(r.x - reach, r.y - reach, r.w + 2 * reach, r.h + 2 * reach)
            }
            Prim::Sprite { at, key, .. } => {
                Rect::new(at.0, at.1, key.size_px as i32, key.size_px as i32)
            }
            Prim::Text { run, .. } => run.clip,
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Prim::Quad { .. } => KINDS[0],
            Prim::GradQuad { .. } => KINDS[1],
            Prim::Ring { .. } => KINDS[2],
            Prim::Shadow { .. } => KINDS[3],
            Prim::Sprite { .. } => KINDS[4],
            Prim::Text { .. } => KINDS[5],
        }
    }
}

/// A target: premultiplied ARGB rows of `stride` words, its top-left at `origin` in the prims' coordinates.
pub struct Target<'a> {
    pub px: &'a mut [u32],
    pub w: i32,
    pub h: i32,
    pub stride: usize,
    pub origin: (i32, i32),
}

/// Source-over of premultiplied SRC scaled by COV (0..=255) onto DST.
#[inline]
pub fn over(dst: u32, src: u32, cov: u32) -> u32 {
    if cov == 0 {
        return dst;
    }
    let s = |c: u32| ((src >> c) & 0xff) * cov / 255;
    let (sa, sr, sg, sb) = (s(24), s(16), s(8), s(0));
    let inv = 255 - sa;
    let d = |c: u32, sv: u32| (sv + ((dst >> c) & 0xff) * inv / 255).min(255);
    (d(24, sa) << 24) | (d(16, sr) << 16) | (d(8, sg) << 8) | d(0, sb)
}

/// Multiply premultiplied ARGB by an alpha (0..=255): a coverage-tinted colour.
#[inline]
fn tint(argb: u32, a: u32) -> u32 {
    let c = |s: u32| (((argb >> s) & 0xff) * a / 255) << s;
    c(24) | c(16) | c(8) | c(0)
}

/// The signed distance (negative inside) from (PX, PY) to the rounded rectangle R with radius RAD, grown by GROW.
fn rrect_dist(r: Rect, rad: f32, grow: f32, px: f32, py: f32) -> f32 {
    let (cx, cy) = (r.x as f32 + r.w as f32 / 2.0, r.y as f32 + r.h as f32 / 2.0);
    let (hw, hh) = (r.w as f32 / 2.0 + grow, r.h as f32 / 2.0 + grow);
    let rad = (rad + grow).clamp(0.0, hw.min(hh).max(0.0));
    let qx = (px - cx).abs() - (hw - rad);
    let qy = (py - cy).abs() - (hh - rad);
    (qx.max(0.0).powi(2) + qy.max(0.0).powi(2)).sqrt() + qx.max(qy).min(0.0) - rad
}

/// Coverage (0..=1) of the pixel centred at (PX, PY) by that shape, with one pixel of antialiasing.
fn rrect_cov(r: Rect, rad: f32, grow: f32, px: f32, py: f32) -> f32 {
    (0.5 - rrect_dist(r, rad, grow, px, py)).clamp(0.0, 1.0)
}

/// Compose PRIMS into T in order, every primitive clipped to CLIP (the strip's or band's rect).
pub fn compose(prims: &[Prim], atlases: &mut Atlases, clip: Rect, t: &mut Target) {
    let view = Rect::new(t.origin.0, t.origin.1, t.w, t.h);
    let clip = clip.intersect(&view);
    if clip.is_empty() {
        return;
    }
    for p in prims {
        match p {
            Prim::Quad {
                rect, radius, fill, ..
            } => fill_shape(t, clip, *rect, |x, y| {
                let c = rrect_cov(*rect, *radius, 0.0, x, y);
                tint(*fill, (c * 255.0).round() as u32)
            }),
            Prim::GradQuad {
                rect,
                radius,
                axis,
                stops,
                ..
            } => fill_shape(t, clip, *rect, |x, y| {
                let c = rrect_cov(*rect, *radius, 0.0, x, y);
                let f = match axis {
                    Axis::H => (x - rect.x as f32) / rect.w.max(1) as f32,
                    Axis::V => (y - rect.y as f32) / rect.h.max(1) as f32,
                };
                let (p0, c0) = stops[0];
                let (p1, c1) = stops[1];
                let k = ((f - p0) / (p1 - p0).max(1e-6)).clamp(0.0, 1.0);
                let lerp = |s: u32| {
                    let a = ((c0 >> s) & 0xff) as f32;
                    let b = ((c1 >> s) & 0xff) as f32;
                    ((a + (b - a) * k).round() as u32) << s
                };
                tint(
                    lerp(24) | lerp(16) | lerp(8) | lerp(0),
                    (c * 255.0).round() as u32,
                )
            }),
            Prim::Ring {
                rect,
                radius,
                width,
                argb,
                ..
            } => fill_shape(t, clip, *rect, |x, y| {
                let outer = rrect_cov(*rect, *radius, 0.0, x, y);
                let inner = rrect_cov(*rect, *radius, -(*width as f32), x, y);
                tint(*argb, ((outer - inner).max(0.0) * 255.0).round() as u32)
            }),
            Prim::Shadow {
                rect,
                radius,
                blur,
                offset,
                spread,
                argb,
                ..
            } => {
                let sigma = (blur / 2.0).max(0.5);
                let reach = (3.0 * sigma).ceil() as i32 + spread.ceil() as i32;
                let r = rect.translate(offset.0.round() as i32, offset.1.round() as i32);
                let grown = Rect::new(r.x - reach, r.y - reach, r.w + 2 * reach, r.h + 2 * reach);
                fill_shape(t, clip, grown, |x, y| {
                    // a Gaussian's edge (σ) over the distance to the spread shape (logistic approximation of erfc)
                    let d = rrect_dist(r, *radius, *spread, x, y);
                    let v = 1.0 / (1.0 + (1.702 * d / sigma).exp());
                    tint(*argb, (v * 255.0).round() as u32)
                })
            }
            Prim::Sprite {
                at, key, tint: c, ..
            } => {
                // an icon's mask is Glitnir's own raster, made on its first use (`icon`)
                crate::icon::ensure(atlases, key);
                if let Some(s) = atlases.a8.get(key) {
                    let r = Rect::new(at.0, at.1, s.w as i32, s.h as i32);
                    each_px(t, clip, r, |t, i, x, y| {
                        let cov =
                            u32::from(atlases.a8.texel(&s, (x - at.0) as u32, (y - at.1) as u32));
                        t.px[i] = over(t.px[i], *c, cov);
                    });
                }
            }
            Prim::Text { run, .. } => draw_run(run, atlases, clip, t),
        }
    }
}

/// Visit each pixel of R inside CLIP and the target: (target, index, x, y) in prim coordinates.
fn each_px(t: &mut Target, clip: Rect, r: Rect, mut f: impl FnMut(&mut Target, usize, i32, i32)) {
    let r = r.intersect(&clip);
    for y in r.y..r.y + r.h {
        for x in r.x..r.x + r.w {
            let i = (y - t.origin.1) as usize * t.stride + (x - t.origin.0) as usize;
            f(t, i, x, y);
        }
    }
}

/// Paint R (clipped) with the premultiplied colour SHADE gives each pixel centre.
fn fill_shape(t: &mut Target, clip: Rect, r: Rect, shade: impl Fn(f32, f32) -> u32) {
    each_px(t, clip, r, |t, i, x, y| {
        let c = shade(x as f32 + 0.5, y as f32 + 0.5);
        t.px[i] = over(t.px[i], c, 255);
    });
}

fn draw_run(run: &TextRun, atlases: &mut Atlases, clip: Rect, t: &mut Target) {
    let clip = clip.intersect(&run.clip);
    for g in run.visible() {
        let slot = match g.kind {
            AtlasKind::A8 => atlases.a8.get(&g.key),
            AtlasKind::Bgra => atlases.bgra.get(&g.key),
        };
        let Some(s) = slot else { continue };
        let (gx, gy) = (run.x + g.x + s.bearing_x, run.baseline - s.bearing_y);
        let r = Rect::new(gx, gy, s.w as i32, s.h as i32);
        match g.kind {
            AtlasKind::A8 => each_px(t, clip, r, |t, i, x, y| {
                let cov = u32::from(atlases.a8.texel(&s, (x - gx) as u32, (y - gy) as u32));
                t.px[i] = over(t.px[i], run.color, cov);
            }),
            // a colour glyph as it is: never tinted by the run's colour
            AtlasKind::Bgra => each_px(t, clip, r, |t, i, x, y| {
                let c = atlases.bgra.texel(&s, (x - gx) as u32, (y - gy) as u32);
                t.px[i] = over(t.px[i], c, 255);
            }),
        }
    }
}
