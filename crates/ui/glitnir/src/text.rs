//! Text runs (design §6.2): shaped glyphs placed on a pen line, drawn from the atlases.
//!
//! The host shapes (HarfBuzz through the host editor's font driver on Linux, Core Text on macOS) and rounds each advance to whole
//! device px, so a run's width equals `string-pixel-width`. A run never draws outside its clip: when its glyphs pass
//! the clip's right edge it keeps those that end before the ellipsis's start, then draws the ellipsis.

use crate::atlas::{AtlasKind, GlyphKey};
use crate::geom::Rect;

/// One shaped glyph: its key, its pen x from the run's origin (device px), its advance, and its atlas.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PlacedGlyph {
    pub key: GlyphKey,
    pub x: i32,
    pub adv: i32,
    pub kind: AtlasKind,
}

/// The ellipsis a run ends with when it does not fit: its glyph and advance (shaped in the run's font).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ellipsis {
    pub key: GlyphKey,
    pub adv: i32,
    pub kind: AtlasKind,
}

/// A text run: glyphs on a baseline at (`x`, `baseline`), device px of the target, in `color` (premultiplied ARGB),
/// inside `clip`.
#[derive(Clone, Debug, PartialEq)]
pub struct TextRun {
    pub x: i32,
    pub baseline: i32,
    pub glyphs: Vec<PlacedGlyph>,
    pub color: u32,
    pub clip: Rect,
    pub ellipsis: Option<Ellipsis>,
}

impl TextRun {
    /// The run's width: the last glyph's end.
    pub fn width(&self) -> i32 {
        self.glyphs.last().map_or(0, |g| g.x + g.adv)
    }

    /// The glyphs drawn: all of them when the run fits its clip; else those that end before the ellipsis, then the
    /// ellipsis at the pen after the last one kept.
    pub fn visible(&self) -> Vec<PlacedGlyph> {
        let right = self.clip.x + self.clip.w;
        if self.x + self.width() <= right {
            return self.glyphs.clone();
        }
        let Some(e) = self.ellipsis else {
            return self.glyphs.clone();
        };
        let room = right - e.adv;
        let mut out: Vec<PlacedGlyph> = self
            .glyphs
            .iter()
            .copied()
            .take_while(|g| self.x + g.x + g.adv <= room)
            .collect();
        let pen = out.last().map_or(0, |g| g.x + g.adv);
        out.push(PlacedGlyph {
            key: e.key,
            x: pen,
            adv: e.adv,
            kind: e.kind,
        });
        out
    }
}
