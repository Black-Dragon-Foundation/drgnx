//! Fitting text to a pixel width (docs/develop/hub.md, "Rows: fitting"): the advances of the font file Emacs uses,
//! read with skrifa, summed per grapheme cluster (its first char's) and trimmed with an ellipsis to the width minus
//! [`SLACK`]. The sum is an estimate (no shaping, kerning or hinting): the editor's fit guard measures each changed line once and reports a string it found
//! wider ([`FontSet::measured`]), and that measurement wins from then on. Every char is asked of the editor once per
//! (role, char) ([`FontSet::take_asks`]) and its answer cached: the editor's advance is the one it draws (hinted: a
//! hinted font's advances can be a pixel wider than the file's, a dozen px over a row), so it wins over the file's,
//! which stands in until it comes (a glyph the font lacks, or a role with no font file: the role's average).
//!
//! No I/O: the bytes come in loaded (the hub's `view/fonts.rs` reads the files), so every builder takes a
//! `&dyn Measure` and tests run on fixture bytes.

use skrifa::instance::{Location, Size};
use skrifa::{FontRef, MetadataProvider};
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard};
use unicode_segmentation::UnicodeSegmentation;

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
    /// The font FACE draws in, as the editor reported it ([`Ink`]), or none when it is not known (yet): its text is
    /// then measured as the buffer's default font, [`UI`], and the editor is asked.
    fn face(&self, _face: &str) -> Option<Ink> {
        None
    }
    /// Ask the editor to measure TEXT as drawn in RUNS (`[start, end, face]` over its chars, an earlier run above a
    /// later one), its width kept under KEY ([`Measure::measured`]): a segment whose sum comes within [`SLACK`] of its
    /// end, where the sum's error decides whether it fits.
    fn measure_ask(&self, _key: &str, _text: &str, _runs: &[(u32, u32, String)]) {}
}

/// A string the editor is asked to measure (`view-glyphs`' `measure`): its key, its text, its runs.
pub type MeasureAsk = (String, String, Vec<(u32, u32, String)>);

/// The role of the buffer's default face: text in no face, or in one that sets no font, is drawn and measured in it.
pub const UI: &str = "ui";

/// How a face's text is measured: the font role it is drawn in (one of the env's roles, or one of its own the editor
/// reported) and the pixels its box adds at each end of a run in it.
#[derive(Clone, Debug, PartialEq)]
pub struct Ink {
    pub role: String,
    pub pad: f32,
}

impl Ink {
    fn ui() -> Ink {
        Ink {
            role: UI.to_owned(),
            pad: 0.0,
        }
    }
}

/// The [`Ink`] FACE's text is measured with: none, a terminal's style (`s:ID`, the buffer's default font) or a face
/// the editor has not reported yet is [`UI`]'s.
pub fn ink_of(m: &dyn Measure, face: Option<&str>) -> Ink {
    match face {
        Some(f) if !f.starts_with("s:") => m.face(f).unwrap_or_else(Ink::ui),
        _ => Ink::ui(),
    }
}

/// TEXT's width drawn in FACE (none: the buffer's default): in the font the editor said FACE draws in, its box's ends
/// included.
pub fn width_in(m: &dyn Measure, face: Option<&str>, text: &str) -> f32 {
    let ink = ink_of(m, face);
    width(m, &ink.role, text) + 2.0 * ink.pad
}

/// TEXT drawn in FACE fitted to WIDTH px ([`fit`] in FACE's font, less its box's ends).
pub fn fit_in(m: &dyn Measure, face: Option<&str>, text: &str, width_px: f32) -> String {
    let ink = ink_of(m, face);
    fit(m, &ink.role, text, width_px - 2.0 * ink.pad)
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
type MeasureAsked = (BTreeSet<(String, String)>, Vec<MeasureAsk>);

/// The fonts of one (view, class), by role, plus what the editor told the hub: glyph advances it asked for and the
/// strings its fit guard measured.
#[derive(Default)]
pub struct FontSet {
    roles: HashMap<String, Role>,
    /// The roles of the faces whose font is none of the env's roles (a face's own font, `view/glyphs`' faces).
    own: Mutex<HashMap<String, Arc<Role>>>,
    /// face → its ink, as the editor reported it (`view/glyphs`' faces).
    faces: Mutex<HashMap<String, Ink>>,
    /// The faces asked of the editor (asked once), and those not yet sent.
    faces_asked: Mutex<(BTreeSet<String>, Vec<String>)>,
    /// (role, char) → the editor's advance (`view/glyphs`).
    glyphs: Mutex<HashMap<(String, char), f32>>,
    /// (role, char) asked of the editor (asked once), and those not yet sent.
    asked: Mutex<Asked>,
    /// (role, text) → the editor's measured width, least recently used first.
    measured: Mutex<VecDeque<((String, String), f32)>>,
    /// The strings asked to be measured (asked once, at most [`MEASURED_MAX`] remembered), and those not yet sent.
    measure_asked: Mutex<MeasureAsked>,
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

    /// The strings to ask the editor to measure (`view-glyphs`' `measure`), each once.
    pub fn take_measure_asks(&self) -> Vec<MeasureAsk> {
        std::mem::take(&mut lock(&self.measure_asked).1)
    }

    /// The faces to ask the editor for (`view-glyphs`' `faces`), each once.
    pub fn take_face_asks(&self) -> Vec<String> {
        std::mem::take(&mut lock(&self.faces_asked).1)
    }

    /// The editor's answer for FACE: it draws in ROLE, its box adds PAD px at each end of a run; OWN is the font of a
    /// role of FACE's own (a font none of the env's roles has: ROLE is then FACE), with its average width.
    pub fn face_answer(&self, face: &str, ink: Ink, own: Option<(Option<Font>, f32)>) {
        if let Some((font, avg)) = own {
            let mut o = lock(&self.own);
            if o.len() >= CHAR_CACHE_MAX {
                o.clear();
            }
            o.insert(ink.role.clone(), Arc::new(Role { font, avg }));
        }
        let mut f = lock(&self.faces);
        if f.len() >= CHAR_CACHE_MAX {
            f.clear();
        }
        f.insert(face.to_owned(), ink);
    }

    fn role(&self, role: &str) -> Option<Arc<Role>> {
        lock(&self.own).get(role).cloned()
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
        // the editor's advance is the one it draws (hinted, at its size): it wins; until it answers, the file's
        if let Some(a) = lock(&self.glyphs).get(&(role.to_owned(), ch)) {
            return Some(*a);
        }
        self.ask(role, ch);
        let font = self.roles.get(role).and_then(|r| r.font.as_ref());
        if let Some(a) = font.and_then(|f| f.advance(ch)) {
            return Some(a);
        }
        if font.is_none() {
            return self
                .role(role)
                .and_then(|r| r.font.as_ref().and_then(|f| f.advance(ch)));
        }
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
        match self.roles.get(role) {
            Some(r) => r.avg,
            None => self.role(role).map_or(8.0, |r| r.avg),
        }
    }

    fn face(&self, face: &str) -> Option<Ink> {
        if let Some(i) = lock(&self.faces).get(face) {
            return Some(i.clone());
        }
        let mut a = lock(&self.faces_asked);
        if a.0.insert(face.to_owned()) {
            a.1.push(face.to_owned());
        }
        None
    }

    fn measure_ask(&self, key: &str, text: &str, runs: &[(u32, u32, String)]) {
        let mut a = lock(&self.measure_asked);
        if a.0.len() >= MEASURED_MAX {
            a.0.clear();
        }
        if a.0.insert((key.to_owned(), text.to_owned())) {
            a.1.push((key.to_owned(), text.to_owned(), runs.to_vec()));
        }
    }
}

/// TEXT's width in ROLE: the editor's measurement when it reported one, else the sum of its grapheme clusters'.
pub fn width(m: &dyn Measure, role: &str, text: &str) -> f32 {
    if let Some(px) = m.measured(role, text) {
        return px;
    }
    text.graphemes(true).map(|g| cluster(m, role, g)).sum()
}

/// A grapheme cluster's width: its first char's advance. The marks, joiners and joined emoji after it are drawn into
/// that glyph, while measured alone (the editor's answers when there is no font file, as on macOS) each has a width
/// of its own; a cluster the font does not join draws wider, so a row's fit asks the editor for the whole cluster
/// ([`crate::fit_row`]).
fn cluster(m: &dyn Measure, role: &str, g: &str) -> f32 {
    g.chars().next().map_or(0.0, |c| advance(m, role, c))
}

pub(crate) fn advance(m: &dyn Measure, role: &str, c: char) -> f32 {
    let a = m.advance(role, c).unwrap_or_else(|| m.fallback(role));
    match ROUNDING {
        Rounding::Fractional => a,
        Rounding::PerGlyph => a.round(),
    }
}

/// TEXT in ROLE fitted to WIDTH px minus [`SLACK`]: whole when it fits, else cut with an ellipsis between grapheme
/// clusters.
pub fn fit(m: &dyn Measure, role: &str, text: &str, width_px: f32) -> String {
    let budget = width_px - SLACK;
    if width(m, role, text) <= budget {
        return text.to_owned();
    }
    let room = budget - advance(m, role, ELLIPSIS);
    let mut used = 0.0;
    let mut out = String::new();
    for g in text.graphemes(true) {
        let a = cluster(m, role, g);
        if used + a > room {
            break;
        }
        used += a;
        out.push_str(g);
    }
    out.push(ELLIPSIS);
    out
}
