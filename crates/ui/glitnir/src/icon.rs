//! Chrome icons (design §6.3 rule 4): Lucide's icons, stroke 1.6 in the 24-unit box with round caps and joins,
//! rasterised once per (icon, size, scale) into the A8 atlas and drawn as tinted sprites ([`crate::prim::Prim::Sprite`]).
//!
//! The rasteriser is this crate's own, pure Rust, so the Linux shell and Naglfar draw the same masks: each icon's SVG
//! shapes ([`lucide`]) are flattened into polylines, and a pixel's coverage is the share of its 4 × 4 samples within
//! half the stroke of a segment (a quarter-pixel soft edge per sample).  An icon's key is [`ICON_FONT`] with the name's
//! FNV-1a hash as its glyph, so the atlas finds the name again on a miss ([`ensure`]).  A 16 px icon at scale 2 is a
//! 32 × 32 mask: 1 KiB of the atlas.

use crate::atlas::{Atlases, GlyphKey, ICON_FONT, Mask, MaskData};

mod lucide;

/// One SVG element of an icon, in the 24-unit box.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Shape {
    /// A path's `d`.
    Path(&'static str),
    /// `cx cy r`.
    Circle(f32, f32, f32),
    /// `x1 y1 x2 y2`.
    Line(f32, f32, f32, f32),
    /// `x y width height rx ry`.
    Rect(f32, f32, f32, f32, f32, f32),
    /// A polyline's points, x and y alternating.
    Poly(&'static [f32]),
}

/// The stroke width in the 24-unit box (the look's rule; Lucide's files say 2).
pub const STROKE: f32 = 1.6;

/// The atlas glyph number of icon NAME: FNV-1a of its bytes.
pub fn glyph(name: &str) -> u32 {
    name.bytes().fold(0x811c_9dc5u32, |h, b| {
        (h ^ u32::from(b)).wrapping_mul(0x0100_0193)
    })
}

/// Icon NAME's sprite key at SIZE_PX device px and SCALE.
pub fn key(name: &str, size_px: u32, scale: f32) -> GlyphKey {
    GlyphKey {
        font: ICON_FONT,
        glyph: glyph(name),
        size_px,
        scale120: (scale * 120.0).round() as u32,
    }
}

/// Icon NAME's shapes; None for an icon the set lacks.
pub fn shapes(name: &str) -> Option<&'static [Shape]> {
    lucide::ICONS
        .binary_search_by(|(n, _)| (*n).cmp(name))
        .ok()
        .map(|i| lucide::ICONS[i].1)
}

/// Every icon's name.
pub fn names() -> impl Iterator<Item = &'static str> {
    lucide::ICONS.iter().map(|(n, _)| *n)
}

/// Icon NAME's A8 mask, SIZE_PX square; None for an unknown icon or no size.
pub fn mask(name: &str, size_px: u32) -> Option<Mask> {
    mask_of(shapes(name)?, size_px)
}

/// The A8 mask of SHAPES, SIZE_PX square, the 24-unit box scaled to it.
pub fn mask_of(shapes: &[Shape], size_px: u32) -> Option<Mask> {
    if size_px == 0 || size_px > 512 {
        return None;
    }
    let k = size_px as f32 / 24.0;
    let segs: Vec<Seg> = flatten(shapes)
        .iter()
        .flat_map(|line| line.windows(2).map(|w| (w[0], w[1])))
        .map(|((ax, ay), (bx, by))| Seg::new(ax * k, ay * k, bx * k, by * k))
        .collect();
    let hw = STROKE * k / 2.0;
    let n = size_px as usize;
    let mut data = vec![0u8; n * n];
    for y in 0..n {
        let (y0, y1) = (y as f32 - hw - 1.0, y as f32 + 1.0 + hw + 1.0);
        let row: Vec<&Seg> = segs.iter().filter(|s| s.y1 >= y0 && s.y0 <= y1).collect();
        if row.is_empty() {
            continue;
        }
        for x in 0..n {
            let (x0, x1) = (x as f32 - hw - 1.0, x as f32 + 1.0 + hw + 1.0);
            let near: Vec<&&Seg> = row.iter().filter(|s| s.x1 >= x0 && s.x0 <= x1).collect();
            if near.is_empty() {
                continue;
            }
            let mut cov = 0.0f32;
            for sy in 0..4 {
                for sx in 0..4 {
                    let px = x as f32 + (sx as f32 + 0.5) / 4.0;
                    let py = y as f32 + (sy as f32 + 0.5) / 4.0;
                    let d = near
                        .iter()
                        .map(|s| s.dist(px, py))
                        .fold(f32::INFINITY, f32::min);
                    cov += ((hw - d) * 4.0 + 0.5).clamp(0.0, 1.0);
                }
            }
            data[y * n + x] = (cov / 16.0 * 255.0).round() as u8;
        }
    }
    Some(Mask {
        w: size_px,
        h: size_px,
        bearing_x: 0,
        bearing_y: 0,
        data: MaskData::A8(data),
    })
}

/// Make sure the A8 atlas holds KEY when it is an icon's: rasterised on the first use of its name, size and scale.
/// Whether the atlas holds it.
pub fn ensure(atlases: &mut Atlases, key: &GlyphKey) -> bool {
    if key.font != ICON_FONT {
        return false;
    }
    if atlases.a8.contains(key) {
        return true;
    }
    atlases
        .a8
        .get_or_insert(*key, || {
            let name = names().find(|n| glyph(n) == key.glyph)?;
            mask(name, key.size_px)
        })
        .is_some()
}

/// A segment with its bounds.
struct Seg {
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
}

impl Seg {
    fn new(ax: f32, ay: f32, bx: f32, by: f32) -> Seg {
        Seg {
            ax,
            ay,
            bx,
            by,
            x0: ax.min(bx),
            y0: ay.min(by),
            x1: ax.max(bx),
            y1: ay.max(by),
        }
    }

    /// The distance from (PX, PY) to the segment.
    fn dist(&self, px: f32, py: f32) -> f32 {
        let (dx, dy) = (self.bx - self.ax, self.by - self.ay);
        let l2 = dx * dx + dy * dy;
        let t = if l2 > 0.0 {
            (((px - self.ax) * dx + (py - self.ay) * dy) / l2).clamp(0.0, 1.0)
        } else {
            0.0
        };
        let (qx, qy) = (self.ax + t * dx - px, self.ay + t * dy - py);
        (qx * qx + qy * qy).sqrt()
    }
}

type Pt = (f32, f32);

/// SHAPES as polylines (a closed one ends at its start).
fn flatten(shapes: &[Shape]) -> Vec<Vec<Pt>> {
    let mut out = Vec::new();
    for s in shapes {
        match *s {
            Shape::Path(d) => path(d, &mut out),
            Shape::Circle(cx, cy, r) => {
                let n = 48;
                out.push(
                    (0..=n)
                        .map(|i| {
                            let t = i as f32 / n as f32 * std::f32::consts::TAU;
                            (cx + r * t.cos(), cy + r * t.sin())
                        })
                        .collect(),
                );
            }
            Shape::Line(x1, y1, x2, y2) => out.push(vec![(x1, y1), (x2, y2)]),
            Shape::Rect(x, y, w, h, rx, ry) => out.push(rounded_rect(x, y, w, h, rx, ry)),
            Shape::Poly(p) => out.push(p.as_chunks::<2>().0.iter().map(|c| (c[0], c[1])).collect()),
        }
    }
    out
}

fn rounded_rect(x: f32, y: f32, w: f32, h: f32, rx: f32, ry: f32) -> Vec<Pt> {
    let (rx, ry) = (rx.clamp(0.0, w / 2.0), ry.clamp(0.0, h / 2.0));
    let mut v = Vec::new();
    // the corners clockwise from the top right: centre and start angle
    let corners = [
        (x + w - rx, y + ry, -90.0f32),
        (x + w - rx, y + h - ry, 0.0),
        (x + rx, y + h - ry, 90.0),
        (x + rx, y + ry, 180.0),
    ];
    for (cx, cy, a0) in corners {
        for i in 0..=8 {
            let t = (a0 + 90.0 * i as f32 / 8.0).to_radians();
            v.push((cx + rx * t.cos(), cy + ry * t.sin()));
        }
    }
    v.push(v[0]);
    v
}

/// The numbers and commands of path data D.
fn tokens(d: &str) -> Vec<Tok> {
    let b = d.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if c.is_ascii_alphabetic() && c != b'e' && c != b'E' {
            out.push(Tok::Cmd(c));
            i += 1;
        } else if c == b'-' || c == b'+' || c == b'.' || c.is_ascii_digit() {
            let start = i;
            i += 1;
            let mut dot = c == b'.';
            while i < b.len() {
                let ch = b[i];
                if ch.is_ascii_digit() {
                    i += 1;
                } else if ch == b'.' && !dot {
                    dot = true;
                    i += 1;
                } else if (ch == b'e' || ch == b'E') && i + 1 < b.len() {
                    i += 1;
                    if b[i] == b'-' || b[i] == b'+' {
                        i += 1;
                    }
                } else {
                    break;
                }
            }
            if let Ok(v) = d[start..i].parse::<f32>() {
                out.push(Tok::Num(v));
            }
        } else {
            i += 1;
        }
    }
    out
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Tok {
    Cmd(u8),
    Num(f32),
}

/// Path data D flattened into OUT.
fn path(d: &str, out: &mut Vec<Vec<Pt>>) {
    let toks = tokens(d);
    let mut i = 0;
    let mut cmd = b'M';
    let (mut cur, mut start) = ((0.0f32, 0.0f32), (0.0f32, 0.0f32));
    // the last control point of a cubic (S) or a quadratic (T)
    let mut last_c: Option<Pt> = None;
    let mut last_q: Option<Pt> = None;
    let mut line: Vec<Pt> = Vec::new();
    let nums = |i: &mut usize, n: usize| -> Option<Vec<f32>> {
        let mut v = Vec::with_capacity(n);
        for _ in 0..n {
            match toks.get(*i) {
                Some(Tok::Num(x)) => {
                    v.push(*x);
                    *i += 1;
                }
                _ => return None,
            }
        }
        Some(v)
    };
    while i < toks.len() {
        if let Tok::Cmd(c) = toks[i] {
            cmd = c;
            i += 1;
            if c == b'Z' || c == b'z' {
                line.push(start);
                cur = start;
                out.push(std::mem::take(&mut line));
                line.push(cur);
                last_c = None;
                last_q = None;
                continue;
            }
        }
        let rel = cmd.is_ascii_lowercase();
        let off = |p: Pt, cur: Pt| if rel { (p.0 + cur.0, p.1 + cur.1) } else { p };
        let (mut nc, mut nq) = (None, None);
        match cmd.to_ascii_uppercase() {
            b'M' => {
                let Some(v) = nums(&mut i, 2) else { break };
                if line.len() > 1 {
                    out.push(std::mem::take(&mut line));
                }
                cur = off((v[0], v[1]), cur);
                start = cur;
                line = vec![cur];
                // further pairs are lines
                cmd = if rel { b'l' } else { b'L' };
            }
            b'L' => {
                let Some(v) = nums(&mut i, 2) else { break };
                cur = off((v[0], v[1]), cur);
                line.push(cur);
            }
            b'H' => {
                let Some(v) = nums(&mut i, 1) else { break };
                cur.0 = if rel { cur.0 + v[0] } else { v[0] };
                line.push(cur);
            }
            b'V' => {
                let Some(v) = nums(&mut i, 1) else { break };
                cur.1 = if rel { cur.1 + v[0] } else { v[0] };
                line.push(cur);
            }
            b'C' | b'S' => {
                let s = cmd.eq_ignore_ascii_case(&b'S');
                let Some(v) = nums(&mut i, if s { 4 } else { 6 }) else {
                    break;
                };
                let (c1, c2, p) = if s {
                    let c1 = last_c.map_or(cur, |c| (2.0 * cur.0 - c.0, 2.0 * cur.1 - c.1));
                    (c1, off((v[0], v[1]), cur), off((v[2], v[3]), cur))
                } else {
                    (
                        off((v[0], v[1]), cur),
                        off((v[2], v[3]), cur),
                        off((v[4], v[5]), cur),
                    )
                };
                for k in 1..=16 {
                    let t = k as f32 / 16.0;
                    let u = 1.0 - t;
                    let (a, b, c, d) = (u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t);
                    line.push((
                        a * cur.0 + b * c1.0 + c * c2.0 + d * p.0,
                        a * cur.1 + b * c1.1 + c * c2.1 + d * p.1,
                    ));
                }
                nc = Some(c2);
                cur = p;
            }
            b'Q' | b'T' => {
                let t_ = cmd.eq_ignore_ascii_case(&b'T');
                let Some(v) = nums(&mut i, if t_ { 2 } else { 4 }) else {
                    break;
                };
                let (c1, p) = if t_ {
                    let c1 = last_q.map_or(cur, |c| (2.0 * cur.0 - c.0, 2.0 * cur.1 - c.1));
                    (c1, off((v[0], v[1]), cur))
                } else {
                    (off((v[0], v[1]), cur), off((v[2], v[3]), cur))
                };
                for k in 1..=12 {
                    let t = k as f32 / 12.0;
                    let u = 1.0 - t;
                    line.push((
                        u * u * cur.0 + 2.0 * u * t * c1.0 + t * t * p.0,
                        u * u * cur.1 + 2.0 * u * t * c1.1 + t * t * p.1,
                    ));
                }
                nq = Some(c1);
                cur = p;
            }
            b'A' => {
                let Some(v) = nums(&mut i, 7) else { break };
                let p = off((v[5], v[6]), cur);
                arc(
                    cur,
                    v[0],
                    v[1],
                    v[2],
                    v[3] != 0.0,
                    v[4] != 0.0,
                    p,
                    &mut line,
                );
                cur = p;
            }
            _ => {
                // an unknown command: skip its numbers
                i += 1;
            }
        }
        last_c = nc;
        last_q = nq;
    }
    if line.len() > 1 {
        out.push(line);
    }
}

/// The elliptical arc from P0 to P1 (SVG's endpoint form, implementation notes F.6.5) flattened into LINE.
#[allow(clippy::too_many_arguments)]
fn arc(p0: Pt, rx: f32, ry: f32, phi: f32, large: bool, sweep: bool, p1: Pt, line: &mut Vec<Pt>) {
    use std::f32::consts::{PI, TAU};
    let (mut rx, mut ry) = (rx.abs(), ry.abs());
    if rx == 0.0 || ry == 0.0 || p0 == p1 {
        line.push(p1);
        return;
    }
    let (s, c) = phi.to_radians().sin_cos();
    let (dx2, dy2) = ((p0.0 - p1.0) / 2.0, (p0.1 - p1.1) / 2.0);
    let (x1, y1) = (c * dx2 + s * dy2, -s * dx2 + c * dy2);
    let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry);
    if lambda > 1.0 {
        rx *= lambda.sqrt();
        ry *= lambda.sqrt();
    }
    let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
    let den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
    let coef = (num / den).max(0.0).sqrt() * if large == sweep { -1.0 } else { 1.0 };
    let (cxp, cyp) = (coef * rx * y1 / ry, -coef * ry * x1 / rx);
    let (cx, cy) = (
        c * cxp - s * cyp + (p0.0 + p1.0) / 2.0,
        s * cxp + c * cyp + (p0.1 + p1.1) / 2.0,
    );
    let angle = |ux: f32, uy: f32, vx: f32, vy: f32| (ux * vy - uy * vx).atan2(ux * vx + uy * vy);
    let (ux, uy) = ((x1 - cxp) / rx, (y1 - cyp) / ry);
    let (vx, vy) = ((-x1 - cxp) / rx, (-y1 - cyp) / ry);
    let th1 = angle(1.0, 0.0, ux, uy);
    let mut dth = angle(ux, uy, vx, vy);
    if !sweep && dth > 0.0 {
        dth -= TAU;
    } else if sweep && dth < 0.0 {
        dth += TAU;
    }
    let n = ((dth.abs() / (PI / 16.0)).ceil() as usize).max(1);
    for k in 1..=n {
        let t = th1 + dth * k as f32 / n as f32;
        let (st, ct) = t.sin_cos();
        line.push((
            c * rx * ct - s * ry * st + cx,
            s * rx * ct + c * ry * st + cy,
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atlas::Atlases;

    fn cov(m: &Mask, x: u32, y: u32) -> u8 {
        match &m.data {
            MaskData::A8(v) => v[(y * m.w + x) as usize],
            MaskData::Bgra(_) => 0,
        }
    }

    fn total(m: &Mask) -> f32 {
        match &m.data {
            MaskData::A8(v) => v.iter().map(|&c| f32::from(c) / 255.0).sum(),
            MaskData::Bgra(_) => 0.0,
        }
    }

    /// `minus` is one line from (5, 12) to (19, 12): its mask's ink is the stroke's area (14 × 1.6 plus the round
    /// caps' disc), at 16 px (scale 1) and 32 px (scale 2), solid on the line and empty away from it.
    #[test]
    fn a_mask_covers_the_stroke_at_s1_and_s2() {
        for size in [16u32, 32] {
            let m = mask("minus", size).expect("minus has a mask");
            assert_eq!((m.w, m.h), (size, size));
            let k = size as f32 / 24.0;
            let area = (14.0 * STROKE + std::f32::consts::PI * (STROKE / 2.0).powi(2)) * k * k;
            let ink = total(&m);
            assert!(
                (ink - area).abs() <= area * 0.06,
                "size {size}: ink {ink} against the stroke's {area}"
            );
            let mid = size / 2;
            // on the line, in the middle: the pixel row straddling y = 12 carries most of it
            let col = cov(&m, mid, mid - 1) as u32 + cov(&m, mid, mid) as u32;
            assert!(col >= 230 * size / 16, "size {size}: column {col}");
            assert_eq!(cov(&m, mid, 2), 0);
            assert_eq!(cov(&m, 1, mid), 0);
        }
    }

    /// An arc goes the way its sweep flag says: from (2, 12) to (22, 12) with sweep 0 through the bottom (12, 22).
    #[test]
    fn an_arc_follows_its_sweep() {
        let m = mask_of(&[Shape::Path("M2 12a10 10 0 0 0 20 0")], 24).expect("a mask");
        assert!(cov(&m, 12, 21) > 100, "bottom {}", cov(&m, 12, 21));
        assert_eq!(cov(&m, 12, 2), 0);
        let m = mask_of(&[Shape::Path("M2 12A10 10 0 0 1 22 12")], 24).expect("a mask");
        assert!(cov(&m, 12, 2) > 100, "top {}", cov(&m, 12, 2));
        assert_eq!(cov(&m, 12, 21), 0);
    }

    /// Every icon the chrome builder names (smidja's description) has ink.
    #[test]
    fn every_chrome_icon_has_ink() {
        for name in [
            "search",
            "minus",
            "square",
            "x",
            "bot",
            "bell",
            "info",
            "inbox",
            "git-pull-request",
            "pin",
            "columns-2",
            "ellipsis",
            "file",
        ] {
            let m = mask(name, 16).unwrap_or_else(|| panic!("{name} has no mask"));
            assert!(total(&m) > 8.0, "{name}: ink {}", total(&m));
        }
        assert!(mask("no-such-icon", 16).is_none());
        let sorted: Vec<&str> = names().collect();
        assert!(sorted.windows(2).all(|w| w[0] < w[1]));
    }

    /// An icon's key finds its name again on a miss: rasterised once per (icon, size, scale).
    #[test]
    fn icons_rasterise_once_per_key() {
        let mut a = Atlases::default();
        let k1 = key("bell", 16, 1.0);
        assert!(ensure(&mut a, &k1));
        assert!(ensure(&mut a, &k1));
        assert_eq!(a.a8.misses(), 1);
        assert!(ensure(&mut a, &key("bell", 32, 2.0)));
        assert_eq!(a.a8.misses(), 2);
        assert!(!ensure(&mut a, &key("no-such-icon", 16, 1.0)));
    }
}
