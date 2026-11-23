//! Geometry: device-pixel rectangles. Lengths are physical pixels ([`kvardi::Px`]); a logical length reaches Glitnir
//! only through `kvardi::Lp::to_px` (the scale-zoom standard).

pub use kvardi::Px;

/// A rectangle in device pixels; empty when `w <= 0` or `h <= 0`.  Layout equals `GlitnirRect`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub const fn new(x: i32, y: i32, w: i32, h: i32) -> Self {
        Self { x, y, w, h }
    }

    /// A rectangle from pixels: the typed way in, which a logical length cannot take.
    pub const fn at(x: Px, y: Px, w: Px, h: Px) -> Self {
        Self::new(x.0, y.0, w.0, h.0)
    }

    pub const fn is_empty(&self) -> bool {
        self.w <= 0 || self.h <= 0
    }

    /// Area in pixels (0 when empty).
    pub fn area(&self) -> u64 {
        if self.is_empty() {
            0
        } else {
            self.w as u64 * self.h as u64
        }
    }

    /// The overlap of two rectangles (empty when they do not meet).
    pub fn intersect(&self, o: &Rect) -> Rect {
        let x0 = self.x.max(o.x);
        let y0 = self.y.max(o.y);
        let x1 = (self.x as i64 + self.w as i64).min(o.x as i64 + o.w as i64);
        let y1 = (self.y as i64 + self.h as i64).min(o.y as i64 + o.h as i64);
        if x1 <= x0 as i64 || y1 <= y0 as i64 {
            return Rect::default();
        }
        Rect::new(x0, y0, (x1 - x0 as i64) as i32, (y1 - y0 as i64) as i32)
    }

    /// The smallest rectangle holding both; an empty operand is ignored.
    pub fn bounds(&self, o: &Rect) -> Rect {
        if self.is_empty() {
            return *o;
        }
        if o.is_empty() {
            return *self;
        }
        let x0 = self.x.min(o.x);
        let y0 = self.y.min(o.y);
        let x1 = (self.x as i64 + self.w as i64).max(o.x as i64 + o.w as i64);
        let y1 = (self.y as i64 + self.h as i64).max(o.y as i64 + o.h as i64);
        Rect::new(x0, y0, (x1 - x0 as i64) as i32, (y1 - y0 as i64) as i32)
    }

    pub fn translate(&self, dx: i32, dy: i32) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.w, self.h)
    }

    pub fn contains(&self, px: i32, py: i32) -> bool {
        !self.is_empty()
            && px >= self.x
            && py >= self.y
            && (px as i64) < self.x as i64 + self.w as i64
            && (py as i64) < self.y as i64 + self.h as i64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rect_from_pixels() {
        assert_eq!(Rect::at(Px(1), Px(2), Px(3), Px(4)), Rect::new(1, 2, 3, 4));
    }
}
