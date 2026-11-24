//! kvardi (*kvarði*, a measuring rod): the one place where a length in logical units becomes pixels
//! (docs/develop/standards/scale-zoom.md).
//!
//! A view measures in [`Lp`] (logical, scale-independent). Glitnir draws in [`Px`] (physical). [`Lp::to_px`] is the
//! only conversion, and it rounds half away from zero, so a 1-lp hairline at 1.5 is 2 px in every frame.
//!
//! The scale is four zoom levels on top of the display's own: [`Scale`] holds the display's `output` scale and the
//! `app`, `window`, `pane` and `panel` zooms, and [`Scale::effective`] is their product. Each display has its own
//! output scale ([`Screens`]); a window takes the scale of the display that holds most of it, and its zoom is
//! remembered per display and per window preset.

mod screens;
pub mod snap;

pub use screens::{Display, DisplayId, Rect, Screens, Window};

/// The smallest and the largest a zoom level may be.
pub const MIN_ZOOM: f32 = 0.25;
pub const MAX_ZOOM: f32 = 5.0;

/// A length in logical units: what a view measures in, whatever the display.
#[derive(Clone, Copy, PartialEq, PartialOrd, Debug, Default)]
pub struct Lp(pub f32);

/// A length in physical pixels: what Glitnir draws in. It adds, subtracts and scales by whole numbers with its own
/// kind and with plain `i32`s (a count of pixels), never with an [`Lp`]: a logical length reaches pixels only through
/// [`Lp::to_px`].
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, Default)]
#[repr(transparent)]
pub struct Px(pub i32);

impl Px {
    pub const ZERO: Px = Px(0);

    pub const fn abs(self) -> Px {
        Px(self.0.abs())
    }
}

macro_rules! px_ops {
    ($($tr:ident $m:ident $op:tt, $tra:ident $ma:ident $opa:tt);* $(;)?) => {$(
        impl std::ops::$tr for Px {
            type Output = Px;
            fn $m(self, o: Px) -> Px { Px(self.0 $op o.0) }
        }
        impl std::ops::$tr<i32> for Px {
            type Output = Px;
            fn $m(self, o: i32) -> Px { Px(self.0 $op o) }
        }
        impl std::ops::$tra for Px {
            fn $ma(&mut self, o: Px) { self.0 $opa o.0 }
        }
        impl std::ops::$tra<i32> for Px {
            fn $ma(&mut self, o: i32) { self.0 $opa o }
        }
    )*};
}
px_ops! {
    Add add +, AddAssign add_assign +=;
    Sub sub -, SubAssign sub_assign -=;
    Mul mul *, MulAssign mul_assign *=;
    Div div /, DivAssign div_assign /=;
}

impl std::ops::Neg for Px {
    type Output = Px;
    fn neg(self) -> Px {
        Px(-self.0)
    }
}

impl PartialEq<i32> for Px {
    fn eq(&self, o: &i32) -> bool {
        self.0 == *o
    }
}

impl PartialOrd<i32> for Px {
    fn partial_cmp(&self, o: &i32) -> Option<std::cmp::Ordering> {
        self.0.partial_cmp(o)
    }
}

impl From<Px> for i32 {
    fn from(p: Px) -> i32 {
        p.0
    }
}

impl From<i32> for Px {
    fn from(v: i32) -> Px {
        Px(v)
    }
}

/// The scale of a place: the display's own, then the four zoom levels (all 1.0 when not zoomed).
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Scale {
    pub output: f32,
    pub app: f32,
    pub window: f32,
    pub pane: f32,
    pub panel: f32,
}

impl Default for Scale {
    fn default() -> Scale {
        Scale {
            output: 1.0,
            app: 1.0,
            window: 1.0,
            pane: 1.0,
            panel: 1.0,
        }
    }
}

impl Scale {
    /// The scale a length is multiplied by: the product of the display's scale and the four zooms.
    pub fn effective(&self) -> f32 {
        self.output * self.app * self.window * self.pane * self.panel
    }
}

/// A logical length (in f64) as device pixels at SCALE, unrounded: the one place a length meets a scale for geometry
/// that rounds by its own rules (Glitnir's edge snapping).
pub fn device_f64(logical: f64, scale: f64) -> f64 {
    logical * scale
}

/// Clamp a zoom level to the range the editor allows; a value that is not a number is 1.
pub fn clamp_zoom(z: f32) -> f32 {
    if z.is_nan() {
        1.0
    } else {
        z.clamp(MIN_ZOOM, MAX_ZOOM)
    }
}

impl Lp {
    /// Physical pixels at SCALE: the length times the effective scale, rounded half away from zero. This is the one
    /// rounding rule, so a length is the same number of pixels in every frame.
    pub fn to_px(self, s: &Scale) -> Px {
        // in f64 so that 1.5 times an odd number is exactly a half, never a hair below it
        let v = f64::from(self.0) * f64::from(s.effective());
        Px(v.round() as i32)
    }

    /// The same length in device pixels, not rounded: for what is not a pixel count (a blur's sigma, a stroke's width
    /// before it is snapped).
    pub fn to_px_f32(self, s: &Scale) -> f32 {
        self.0 * s.effective()
    }
}
