//! Fitting text to a pixel width (docs/develop/hub.md, "Rows: fitting"): the advances of the font file Emacs uses,
//! read with skrifa, summed and trimmed with an ellipsis to the width minus [`SLACK`]. The sum is an estimate (no
//! shaping, kerning or hinting): the editor's fit guard measures each changed line once and reports a string it found
//! wider ([`FontSet::measured`]), and that measurement wins from then on. A glyph the font lacks, or a role with no
//! font file, is asked of the editor once per (role, char) ([`FontSet::take_asks`]) and its answer cached.
//!
//! No I/O: the bytes come in loaded (the hub's `view/fonts.rs` reads the files), so every builder takes a
//! `&dyn Measure` and tests run on fixture bytes.

use skrifa::instance::{Location, Size};
use skrifa::{FontRef, MetadataProvider};
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard};

/// Pixels a fitted segment stays short of its width, for what the estimate misses.
pub const SLACK: f32 = 10.0;
/// The ellipsis a trimmed segment ends with.
pub const ELLIPSIS: char = '…';
/// The most chars one font's advance cache holds before it is emptied.
pub const CHAR_CACHE_MAX: usize = 4096;
/// The most strings the measured-width cache holds (least recently used first out).
pub const MEASURED_MAX: usize = 1024;

/// What a builder measures text with.
pub trait Measure {
    /// CH's advance in px in ROLE's font, or none when it is not known (yet).
    fn advance(&self, role: &str, ch: char) -> Option<f32>;
    /// The width the editor measured for TEXT in ROLE, when it reported one (it wins over a sum).
    fn measured(&self, _role: &str, _text: &str) -> Option<f32> {
        None
    }
    /// An estimate for a char whose advance is not known (the role's average width).
    fn fallback(&self, role: &str) -> f32;
}

/// How advances are summed (decided by the measurement against Emacs: docs/develop/hub.md, "Rows: fitting").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rounding {
    /// The unhinted fractional advances, summed.
    Fractional,
    /// Each advance rounded to whole pixels, then summed.
    PerGlyph,
}

/// The rounding the fitter uses: per glyph, as Emacs lays glyphs out on whole pixels. Measured against Emacs 31
/// (Nidhogg, GUI test image) on 40-char strings in Inter and JetBrains Mono at 11-16 px: largest error 4.0 px per
/// glyph, 16.4 px fractional.
pub const ROUNDING: Rounding = Rounding::PerGlyph;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// One face of a font file at one size and variation location, with its advances cached per char.
pub struct Font {
    data: Arc<Vec<u8>>,
    index: u32,
    px: f32,
    location: Location,
    cache: Mutex<HashMap<char, Option<f32>>>,
}

impl Font {
    /// Face INDEX of the font file DATA at PX, at the variation AXES (`[("wght", 700.0)]`; unknown axes are ignored).
    pub fn new(
        data: Arc<Vec<u8>>,
        index: u32,
        px: f32,
        axes: &[(&str, f32)],
    ) -> Result<Font, String> {
        let font = FontRef::from_index(&data, index).map_err(|e| format!("face {index}: {e}"))?;
        let location = font.axes().location(axes.iter().copied());
        Ok(Font {
            data: data.clone(),
            index,
            px,
            location,
            cache: Mutex::new(HashMap::new()),
        })
    }

    /// CH's unhinted advance in px, or none when the face has no glyph for it.
    pub fn advance(&self, ch: char) -> Option<f32> {
        let mut cache = lock(&self.cache);
        if let Some(a) = cache.get(&ch) {
            return *a;
        }
        let a = FontRef::from_index(&self.data, self.index)
            .ok()
            .and_then(|f| {
                let gid = f.charmap().map(ch).filter(|g| g.to_u32() != 0)?;
                f.glyph_metrics(Size::new(self.px), &self.location)
                    .advance_width(gid)
            });
        if cache.len() >= CHAR_CACHE_MAX {
            cache.clear();
        }
        cache.insert(ch, a);
        a
    }
}

/// One role's font: a face (none when Emacs named no file) and the env's average width.
pub struct Role {
    pub font: Option<Font>,
    pub avg: f32,
}

/// The (role, char) pairs asked of the editor, and those not yet sent.
type Asked = (BTreeSet<(String, char)>, Vec<(String, char)>);

/// The fonts of one (view, class), by role, plus what the editor told the hub: glyph advances it asked for and the
/// strings its fit guard measured.
#[derive(Default)]
pub struct FontSet {
    roles: HashMap<String, Role>,
    /// (role, char) → the editor's advance (`view/glyphs`).
    glyphs: Mutex<HashMap<(String, char), f32>>,
    /// (role, char) asked of the editor (asked once), and those not yet sent.
    asked: Mutex<Asked>,
    /// (role, text) → the editor's measured width, least recently used first.
    measured: Mutex<VecDeque<((String, String), f32)>>,
}

impl FontSet {
    pub fn new() -> Self {
        FontSet::default()
    }

    pub fn set_role(&mut self, role: &str, font: Option<Font>, avg: f32) {
        self.roles.insert(role.to_owned(), Role { font, avg });
    }

    /// The editor's advances (`view/glyphs`), `[role, char, px]`.
    pub fn glyphs(&self, answers: &[(String, char, f32)]) {
        let mut g = lock(&self.glyphs);
        if g.len() + answers.len() > CHAR_CACHE_MAX {
            g.clear();
        }
        for (role, ch, px) in answers {
            g.insert((role.clone(), *ch), *px);
        }
    }

    /// The editor's fit guard measured TEXT in ROLE as PX (`view/measured`).
    pub fn measured(&self, role: &str, text: &str, px: f32) {
        let mut m = lock(&self.measured);
        m.retain(|((r, t), _)| !(r == role && t == text));
        if m.len() >= MEASURED_MAX {
            m.pop_front();
        }
        m.push_back(((role.to_owned(), text.to_owned()), px));
    }

    /// The (role, char) pairs to ask the editor for (`view-glyphs`), each once.
    pub fn take_asks(&self) -> Vec<(String, char)> {
        std::mem::take(&mut lock(&self.asked).1)
    }

    fn ask(&self, role: &str, ch: char) {
        let mut a = lock(&self.asked);
        if a.0.insert((role.to_owned(), ch)) {
            a.1.push((role.to_owned(), ch));
        }
    }
}

impl Measure for FontSet {
    fn advance(&self, role: &str, ch: char) -> Option<f32> {
        let font = self.roles.get(role).and_then(|r| r.font.as_ref());
        if let Some(a) = font.and_then(|f| f.advance(ch)) {
            return Some(a);
        }
        if let Some(a) = lock(&self.glyphs).get(&(role.to_owned(), ch)) {
            return Some(*a);
        }
        self.ask(role, ch);
        None
    }

    fn measured(&self, role: &str, text: &str) -> Option<f32> {
        let mut m = lock(&self.measured);
        let i = m.iter().position(|((r, t), _)| r == role && t == text)?;
        // a hit is used: it moves to the back
        let e = m.remove(i)?;
        let px = e.1;
        m.push_back(e);
        Some(px)
    }

    fn fallback(&self, role: &str) -> f32 {
        self.roles.get(role).map_or(8.0, |r| r.avg)
    }
}

/// TEXT's width in ROLE: the editor's measurement when it reported one, else the sum of the advances.
pub fn width(m: &dyn Measure, role: &str, text: &str) -> f32 {
    if let Some(px) = m.measured(role, text) {
        return px;
    }
    text.chars().map(|c| advance(m, role, c)).sum()
}

fn advance(m: &dyn Measure, role: &str, c: char) -> f32 {
    let a = m.advance(role, c).unwrap_or_else(|| m.fallback(role));
    match ROUNDING {
        Rounding::Fractional => a,
        Rounding::PerGlyph => a.round(),
    }
}

/// TEXT in ROLE fitted to WIDTH px minus [`SLACK`]: whole when it fits, else cut with an ellipsis.
pub fn fit(m: &dyn Measure, role: &str, text: &str, width_px: f32) -> String {
    let budget = width_px - SLACK;
    if width(m, role, text) <= budget {
        return text.to_owned();
    }
    let room = budget - advance(m, role, ELLIPSIS);
    let mut used = 0.0;
    let mut out = String::new();
    for c in text.chars() {
        let a = advance(m, role, c);
        if used + a > room {
            break;
        }
        used += a;
        out.push(c);
    }
    out.push(ELLIPSIS);
    out
}
