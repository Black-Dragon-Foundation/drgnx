//! The glyph atlases (design §6.2–6.3; Task 15's approved case): the one host raster chrome uses.
//!
//! Two atlases, as GPUI's monochrome and polychrome sprites: `Atlas<A8>` holds coverage masks, tinted by a run's
//! colour at compose; `Atlas<Bgra>` holds colour glyphs (an emoji), premultiplied, composed as they are and
//! never tinted. Each atlas is up to [`PAGES`] pages of [`PAGE`]² texels (a texture array); a page is packed in
//! shelves. When a mask fits on no page and all pages exist, the least recently used page is cleared and reused:
//! eviction is per page, LRU across pages. A key is (font, glyph, size in device px, scale × 120); a miss counter per
//! atlas says how often the host rasterised.
//!
//! Lucide icons are masks too ([`ICON_FONT`] as their font id), so a sprite is an A8 entry tinted like text.

use std::collections::HashMap;

/// A page's side, texels.
pub const PAGE: u32 = 1024;
/// The most pages an atlas grows to before it evicts.
pub const PAGES: usize = 4;
/// The font id of the icon masks (Lucide, rasterised once per size and scale).
pub const ICON_FONT: u32 = u32::MAX;

/// One mask's key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct GlyphKey {
    pub font: u32,
    pub glyph: u32,
    /// The run's size, device px.
    pub size_px: u32,
    /// The scale × 120 (1.0 → 120).
    pub scale120: u32,
}

/// Which atlas a glyph lives in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AtlasKind {
    A8,
    Bgra,
}

/// A rasterised mask as the host hands it over: `w` × `h`, its top-left `bearing_x` right of the pen and `bearing_y`
/// above the baseline. A8: one coverage byte per texel; BGRA: one premultiplied ARGB word (Cairo order) per texel.
#[derive(Clone, Debug, PartialEq)]
pub struct Mask {
    pub w: u32,
    pub h: u32,
    pub bearing_x: i32,
    pub bearing_y: i32,
    pub data: MaskData,
}

#[derive(Clone, Debug, PartialEq)]
pub enum MaskData {
    A8(Vec<u8>),
    Bgra(Vec<u32>),
}

impl Mask {
    pub fn kind(&self) -> AtlasKind {
        match self.data {
            MaskData::A8(_) => AtlasKind::A8,
            MaskData::Bgra(_) => AtlasKind::Bgra,
        }
    }
}

/// Where a mask sits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AtlasSlot {
    pub kind: AtlasKind,
    pub page: usize,
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    pub bearing_x: i32,
    pub bearing_y: i32,
}

/// A page's texels.
pub trait Texel: Copy + Default {
    const KIND: AtlasKind;
    fn of(d: &MaskData) -> Option<&[Self]>;
}

/// The coverage atlas's texel.
pub type A8 = u8;
/// The colour atlas's texel: premultiplied ARGB, Cairo's order.
pub type Bgra = u32;

impl Texel for A8 {
    const KIND: AtlasKind = AtlasKind::A8;
    fn of(d: &MaskData) -> Option<&[Self]> {
        match d {
            MaskData::A8(v) => Some(v.as_slice()),
            MaskData::Bgra(_) => None,
        }
    }
}

impl Texel for Bgra {
    const KIND: AtlasKind = AtlasKind::Bgra;
    fn of(d: &MaskData) -> Option<&[Self]> {
        match d {
            MaskData::Bgra(v) => Some(v.as_slice()),
            MaskData::A8(_) => None,
        }
    }
}

struct Page<T> {
    texels: Vec<T>,
    /// Shelves: (top, height, next free x).
    shelves: Vec<(u32, u32, u32)>,
    /// The next shelf's top.
    top: u32,
    /// The newest use of any entry on the page.
    used: u64,
}

impl<T: Texel> Page<T> {
    fn new() -> Self {
        Page {
            texels: vec![T::default(); (PAGE * PAGE) as usize],
            shelves: Vec::new(),
            top: 0,
            used: 0,
        }
    }

    /// Room for a W × H mask (one texel of padding right and below): its top-left, or None.
    fn place(&mut self, w: u32, h: u32) -> Option<(u32, u32)> {
        let (pw, ph) = (w + 1, h + 1);
        if pw > PAGE || ph > PAGE {
            return None;
        }
        for s in &mut self.shelves {
            if ph <= s.1 && s.2 + pw <= PAGE {
                let at = (s.2, s.0);
                s.2 += pw;
                return Some(at);
            }
        }
        if self.top + ph > PAGE {
            return None;
        }
        let at = (0, self.top);
        self.shelves.push((self.top, ph, pw));
        self.top += ph;
        Some(at)
    }

    fn clear(&mut self) {
        self.texels.fill(T::default());
        self.shelves.clear();
        self.top = 0;
    }
}

/// One atlas.
pub struct Atlas<T> {
    pages: Vec<Page<T>>,
    slots: HashMap<GlyphKey, AtlasSlot>,
    tick: u64,
    misses: u64,
    evictions: u64,
}

impl<T: Texel> Default for Atlas<T> {
    fn default() -> Self {
        Atlas {
            pages: Vec::new(),
            slots: HashMap::new(),
            tick: 0,
            misses: 0,
            evictions: 0,
        }
    }
}

impl<T: Texel> Atlas<T> {
    /// KEY's slot, a use (the page's LRU tick).
    pub fn get(&mut self, key: &GlyphKey) -> Option<AtlasSlot> {
        let s = *self.slots.get(key)?;
        self.tick += 1;
        self.pages[s.page].used = self.tick;
        Some(s)
    }

    /// Whether KEY is held (not a use).
    pub fn contains(&self, key: &GlyphKey) -> bool {
        self.slots.contains_key(key)
    }

    /// KEY's slot; on a miss MASK makes it (counted). None when MASK is of the other atlas's kind or larger than a
    /// page.
    pub fn get_or_insert(
        &mut self,
        key: GlyphKey,
        mask: impl FnOnce() -> Option<Mask>,
    ) -> Option<AtlasSlot> {
        if let Some(s) = self.get(&key) {
            return Some(s);
        }
        let m = mask()?;
        self.misses += 1;
        self.insert(key, &m)
    }

    fn insert(&mut self, key: GlyphKey, m: &Mask) -> Option<AtlasSlot> {
        let src = T::of(&m.data)?;
        if src.len() != (m.w * m.h) as usize {
            return None;
        }
        self.tick += 1;
        let mut at = None;
        for (i, p) in self.pages.iter_mut().enumerate() {
            if let Some(xy) = p.place(m.w, m.h) {
                at = Some((i, xy));
                break;
            }
        }
        if at.is_none() && self.pages.len() < PAGES {
            let mut p = Page::new();
            let xy = p.place(m.w, m.h)?;
            self.pages.push(p);
            at = Some((self.pages.len() - 1, xy));
        }
        if at.is_none() {
            // every page full: the least recently used page goes
            let lru = (0..self.pages.len()).min_by_key(|i| self.pages[*i].used)?;
            self.pages[lru].clear();
            self.slots.retain(|_, s| s.page != lru);
            self.evictions += 1;
            let xy = self.pages[lru].place(m.w, m.h)?;
            at = Some((lru, xy));
        }
        let (page, (x, y)) = at?;
        let p = &mut self.pages[page];
        for row in 0..m.h {
            let d = ((y + row) * PAGE + x) as usize;
            let s = (row * m.w) as usize;
            p.texels[d..d + m.w as usize].copy_from_slice(&src[s..s + m.w as usize]);
        }
        p.used = self.tick;
        let slot = AtlasSlot {
            kind: T::KIND,
            page,
            x,
            y,
            w: m.w,
            h: m.h,
            bearing_x: m.bearing_x,
            bearing_y: m.bearing_y,
        };
        self.slots.insert(key, slot);
        Some(slot)
    }

    /// The texel at (X, Y) of SLOT's mask.
    pub fn texel(&self, slot: &AtlasSlot, x: u32, y: u32) -> T {
        let p = &self.pages[slot.page];
        p.texels[((slot.y + y) * PAGE + slot.x + x) as usize]
    }

    /// How many masks were rasterised (misses), and how many pages were evicted.
    pub fn misses(&self) -> u64 {
        self.misses
    }

    pub fn evictions(&self) -> u64 {
        self.evictions
    }

    pub fn pages(&self) -> usize {
        self.pages.len()
    }

    pub fn len(&self) -> usize {
        self.slots.len()
    }

    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }
}

/// Both atlases.
#[derive(Default)]
pub struct Atlases {
    pub a8: Atlas<A8>,
    pub bgra: Atlas<Bgra>,
}

impl Atlases {
    /// KEY's slot in KIND's atlas; on a miss MASK makes it.
    pub fn get_or_insert(
        &mut self,
        kind: AtlasKind,
        key: GlyphKey,
        mask: impl FnOnce() -> Option<Mask>,
    ) -> Option<AtlasSlot> {
        match kind {
            AtlasKind::A8 => self.a8.get_or_insert(key, mask),
            AtlasKind::Bgra => self.bgra.get_or_insert(key, mask),
        }
    }
}

/// A colour strike (a fixed bitmap size, e.g. Noto Color Emoji's 109 px) scaled to the run's size once, before it
/// goes into the atlas: a box filter over premultiplied texels (bilinear when enlarging). `strike_px` is the strike's
/// em size, `size_px` the run's; the bearings scale with it.
pub fn scale_strike(m: &Mask, strike_px: u32, size_px: u32) -> Mask {
    let MaskData::Bgra(src) = &m.data else {
        return m.clone();
    };
    if strike_px == 0 || strike_px == size_px || m.w == 0 || m.h == 0 {
        return m.clone();
    }
    let f = f64::from(size_px) / f64::from(strike_px);
    let w = ((f64::from(m.w) * f).round() as u32).max(1);
    let h = ((f64::from(m.h) * f).round() as u32).max(1);
    let mut out = vec![0u32; (w * h) as usize];
    let (sx, sy) = (f64::from(m.w) / f64::from(w), f64::from(m.h) / f64::from(h));
    for y in 0..h {
        for x in 0..w {
            // the source box under this texel
            let (x0, x1) = (f64::from(x) * sx, f64::from(x + 1) * sx);
            let (y0, y1) = (f64::from(y) * sy, f64::from(y + 1) * sy);
            let mut acc = [0f64; 4];
            let mut area = 0f64;
            let mut yy = y0.floor() as u32;
            while f64::from(yy) < y1 && yy < m.h {
                let wy = (y1.min(f64::from(yy + 1)) - y0.max(f64::from(yy))).max(0.0);
                let mut xx = x0.floor() as u32;
                while f64::from(xx) < x1 && xx < m.w {
                    let wx = (x1.min(f64::from(xx + 1)) - x0.max(f64::from(xx))).max(0.0);
                    let a = wx * wy;
                    let p = src[(yy * m.w + xx) as usize];
                    for (c, v) in acc.iter_mut().enumerate() {
                        *v += a * f64::from((p >> (24 - 8 * c)) & 0xff);
                    }
                    area += a;
                    xx += 1;
                }
                yy += 1;
            }
            let px = acc.iter().enumerate().fold(0u32, |o, (c, v)| {
                o | ((((v / area.max(1e-9)).round() as u32).min(255)) << (24 - 8 * c))
            });
            out[(y * w + x) as usize] = px;
        }
    }
    Mask {
        w,
        h,
        bearing_x: (f64::from(m.bearing_x) * f).round() as i32,
        bearing_y: (f64::from(m.bearing_y) * f).round() as i32,
        data: MaskData::Bgra(out),
    }
}
