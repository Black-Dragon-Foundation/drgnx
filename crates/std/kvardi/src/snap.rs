//! The device grid's rounding rules, named: every place a length is rounded to device pixels by something other than
//! `Lp::to_px` is one of these functions (the scale-zoom standard), so there is one place to read them.
//!
//! - *stable*: mutter's fractional-scale rule: an origin is `roundf(pos * s)` and an extent is
//!   `roundf((pos + size) * s) - roundf(pos * s)`, in `f32`, half away from zero, so a child's edges land where its
//!   parent's rounding puts them ([`stable_origin`], [`stable_extent`]);
//! - *outward*: the logical position whose stable origin is at or before, or at or after, a device coordinate
//!   ([`outward_before`], [`outward_after`]): a device rectangle's edges moved out to rows and columns a compositor can
//!   place a subsurface on;
//! - *snap*: an edge moves to `round(e * s) / s`, and a span under two device pixels is a line width of
//!   `max(1, floor(len * s))` of them (CSS Values 4); at an integer scale nothing changes ([`snap_span`], [`snap_line`]).

/// A scale as the host's 120ths (`wp_fractional_scale`'s unit): 1.5 is 180.
pub fn scale_120ths(scale: f64) -> u32 {
    (120.0 * scale).round() as u32
}

fn scale_of(scale120: u32) -> f32 {
    scale120 as f32 / 120.0
}

/// `roundf(pos * s)`: the device origin of a surface at logical `pos`.
pub fn stable_origin(pos: i32, scale120: u32) -> i32 {
    (pos as f32 * scale_of(scale120)).round() as i32
}

/// `roundf((pos + size) * s) - roundf(pos * s)`: the device extent of the span `pos .. pos + size`.
pub fn stable_extent(pos: i32, size: i32, scale120: u32) -> i32 {
    let s = scale_of(scale120);
    ((pos + size) as f32 * s).round() as i32 - (pos as f32 * s).round() as i32
}

/// A first guess of the logical position of the device coordinate `d`.
fn guess(d: i32, scale120: u32) -> i32 {
    (f64::from(d) * 120.0 / f64::from(scale120)) as i32
}

/// The last logical position whose device origin is at or before `d` (`scale120` is not 0).
pub fn outward_before(d: i32, scale120: u32) -> i32 {
    let mut l = guess(d, scale120);
    while stable_origin(l, scale120) > d {
        l -= 1;
    }
    while stable_origin(l + 1, scale120) <= d {
        l += 1;
    }
    l
}

/// The first logical position whose device origin is at or after `d` (`scale120` is not 0).
pub fn outward_after(d: i32, scale120: u32) -> i32 {
    let mut l = guess(d, scale120);
    while stable_origin(l, scale120) < d {
        l += 1;
    }
    while stable_origin(l - 1, scale120) >= d {
        l -= 1;
    }
    l
}

/// Whether SCALE leaves the grid as it is: not a positive finite number, or a whole one.
pub fn identity_scale(scale: f64) -> bool {
    !scale.is_finite() || scale <= 0.0 || scale.fract() == 0.0
}

/// One axis snapped to the device grid at SCALE: the start and length, in logical units.
pub fn snap_span(pos: f64, len: f64, scale: f64) -> (f64, f64) {
    let dev = |v: f64| v * scale;
    if dev(len) < 2.0 {
        (dev(pos).round() / scale, dev(len).floor().max(1.0) / scale)
    } else {
        let a = dev(pos).round();
        let b = dev(pos + len).round();
        (a / scale, (b - a) / scale)
    }
}

/// A line width snapped: under two device pixels `max(1, floor(w * s))` of them, else the nearest whole count.
pub fn snap_line(w: f64, scale: f64) -> f64 {
    let px = w * scale;
    if px < 2.0 {
        px.floor().max(1.0) / scale
    } else {
        px.round() / scale
    }
}
