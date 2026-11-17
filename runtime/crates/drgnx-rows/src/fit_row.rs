//! A whole row fitted to its window (docs/develop/hub.md, "Fitting: no row wider than its window"): every segment of
//! the row (the text before its first stop, between two stops, after the last) is measured as drawn, each char in the
//! font of the face its top run names ([`crate::fit::Ink`], as the editor reported it), a cluster of several chars as
//! the editor measured it whole, images at their picture's
//! width, spaces at theirs, a boxed face's ends at its box's; a segment that runs past the next stop (the last: past
//! the window's body) is cut with an ellipsis between grapheme clusters, to the stop less [`SLACK`]. The row then
//! carries the role each run was measured in (`fonts`), so the editor's fit guard reports in the same role. A segment
//! whose sum fits but within the slack of its end is asked of the editor ([`Measure::measure_ask`]): the sum's error
//! decides there, so the editor's width does from then on.
//!
//! The hub fits every row it publishes, whatever its builder did, so no builder's estimate can overflow its window;
//! builders that place text against an edge still measure it in the face they draw it in (`fit::width_in`).

use crate::fit::{self, ELLIPSIS, Ink, Measure, SLACK, UI};
use crate::fit_tty;
use crate::row::{ImageId, Row, Tail};
use unicode_segmentation::UnicodeSegmentation;

/// A terminal's cell width in px and its width table (`view/env`'s `tty_widths`, `[from, to, width]` ranges).
pub type Tty<'a> = (u32, &'a [(u32, u32, u8)]);

/// What a row is fitted to.
pub struct Room<'a> {
    /// The window's body, device px (a terminal: columns, its cell 1 px wide).
    pub width_px: u32,
    /// A terminal's cell and width table: text is then counted in columns of `cell` px.
    pub tty: Option<Tty<'a>>,
    /// An image's width in px (its SVG's), by id; none: a cell.
    pub image_px: &'a dyn Fn(&ImageId) -> Option<u32>,
    /// Where a row's tail is drawn (`drgnx-wb-row-tail`), px (a terminal's: columns) from the window's right edge:
    /// `(mark, control)`, the start of its git mark and of its control (the env's `tail`); none: the view's rows get
    /// no tail. A row with a [`Tail`] ends its text short of what its tail always draws.
    pub tail: Option<(u32, u32)>,
}

/// The font roles of ROW's chars: an index into the returned list per char (0, the buffer's default `ui`). Runs
/// overlap, an earlier one above a later one, and Emacs merges their faces: a char is in the font of the topmost run
/// whose face sets one (its role is not `ui`; a face that sets only colours draws in the font of the faces under it).
fn inks(row: &Row, n: usize, m: &dyn Measure) -> (Vec<usize>, Vec<Ink>) {
    let mut list = vec![Ink {
        role: UI.to_owned(),
        pad: 0.0,
    }];
    let mut at = vec![0usize; n];
    for (s, e, face) in &row.runs {
        let role = fit::ink_of(m, Some(face)).role;
        if role == UI {
            continue;
        }
        let i = match list.iter().position(|k| k.role == role) {
            Some(i) => i,
            None => {
                list.push(Ink { role, pad: 0.0 });
                list.len() - 1
            }
        };
        let (s, e) = ((*s as usize).min(n), (*e as usize).min(n));
        for c in at.iter_mut().take(e).skip(s) {
            if *c == 0 {
                *c = i;
            }
        }
    }
    (at, list)
}

/// Each char's drawn width: a cluster's first char its advance in its ink's role, the rest none; a stop's
/// placeholder none (the segments start at stops), an image's or a space's its own; a run's first char also both ends
/// of its face's box.
fn widths(
    row: &Row,
    chars: &[char],
    at: &[usize],
    inks: &[Ink],
    m: &dyn Measure,
    room: &Room,
) -> Vec<f32> {
    let n = chars.len();
    let mut w = vec![0.0f32; n];
    let mut i = 0;
    for g in row.text.graphemes(true) {
        let len = g.chars().count();
        if i < n {
            w[i] = match room.tty {
                Some((cell, table)) => (fit_tty::width(g, table) as u32 * cell) as f32,
                // a cluster of several chars (joined emoji, marks) draws as the font joins it, which no advance tells:
                // the editor measures it, and until it answers its first char's advance stands in
                None if len > 1 => {
                    let key = roles_key(at, inks, i, (i + len).min(n));
                    m.measured(&key, g).unwrap_or_else(|| {
                        let runs: Vec<(u32, u32, String)> = row
                            .runs
                            .iter()
                            .filter(|r| (r.0 as usize) < i + len && (r.1 as usize) > i)
                            .map(|r| {
                                let s = (r.0 as usize).max(i) - i;
                                let e = (r.1 as usize).min(i + len) - i;
                                (s as u32, e as u32, r.2.clone())
                            })
                            .collect();
                        m.measure_ask(&key, g, &runs);
                        fit::advance(m, &inks[at[i]].role, chars[i])
                    })
                }
                None => fit::advance(m, &inks[at[i]].role, chars[i]),
            };
        }
        i += len;
    }
    for (pos, _) in &row.stops {
        if let Some(x) = w.get_mut(*pos as usize) {
            *x = 0.0;
        }
    }
    for (pos, id, alt) in &row.images {
        if let Some(x) = w.get_mut(*pos as usize) {
            *x = match room.tty {
                Some((cell, table)) => (fit_tty::width(alt, table) as u32 * cell) as f32,
                None => (room.image_px)(id).unwrap_or(0) as f32,
            };
        }
    }
    for (pos, width, _) in &row.spaces {
        if let Some(x) = w.get_mut(*pos as usize) {
            *x = *width as f32;
        }
    }
    if room.tty.is_none() {
        for (s, e, face) in &row.runs {
            let pad = fit::ink_of(m, Some(face)).pad;
            if pad > 0.0 && s < e && (*s as usize) < n {
                w[*s as usize] += 2.0 * pad;
            }
        }
    }
    w
}

/// Replace ROW's chars `[from, to)` with REPL (one char or none), every position after them moved; a stop, image or
/// space inside them goes.
fn splice(row: &mut Row, from: u32, to: u32, repl: &str) {
    let rl = repl.chars().count() as u32;
    let byte = |c: u32| {
        row.text
            .char_indices()
            .nth(c as usize)
            .map_or(row.text.len(), |(b, _)| b)
    };
    let (bf, bt) = (byte(from), byte(to));
    row.text.replace_range(bf..bt, repl);
    // a range that ends in the cut text takes the ellipsis; one that starts at or in it starts after it
    let map = |x: u32| {
        if x <= from {
            x
        } else if x < to {
            from + rl
        } else {
            x - (to - from) + rl
        }
    };
    let start = |x: u32| if x == from { from + rl } else { map(x) };
    let gone = |p: u32| p >= from && p < to;
    for r in &mut row.runs {
        (r.0, r.1) = (start(r.0), map(r.1));
    }
    row.runs.retain(|r| r.0 < r.1);
    for p in &mut row.props {
        (p.0, p.1) = (start(p.0), map(p.1));
    }
    row.props.retain(|p| p.0 < p.1);
    row.stops.retain(|s| !gone(s.0));
    for s in &mut row.stops {
        s.0 = map(s.0);
    }
    row.images.retain(|i| !gone(i.0));
    for i in &mut row.images {
        i.0 = map(i.0);
    }
    row.spaces.retain(|s| !gone(s.0));
    for s in &mut row.spaces {
        s.0 = map(s.0);
    }
}

/// A segment's text as the editor measures it: without its images' and spaces' placeholders, whose widths (PLACED)
/// are known, and its runs over what is left, in their order.
struct Plain {
    text: String,
    runs: Vec<(u32, u32, String)>,
    placed: f32,
}

impl Plain {
    /// ROW's chars `[s, e)` (CHARS, each W wide).
    fn of(row: &Row, chars: &[char], w: &[f32], s: usize, e: usize) -> Plain {
        let held: Vec<usize> = row
            .images
            .iter()
            .map(|i| i.0 as usize)
            .chain(row.spaces.iter().map(|x| x.0 as usize))
            .filter(|p| (s..e).contains(p))
            .collect();
        // each char's place in the plain text (a placeholder's: the next char's)
        let mut at = Vec::with_capacity(e - s + 1);
        let mut text = String::new();
        let mut placed = 0.0;
        let mut n = 0u32;
        for (i, c) in chars.iter().enumerate().take(e).skip(s) {
            at.push(n);
            if held.contains(&i) {
                placed += w[i];
            } else {
                text.push(*c);
                n += 1;
            }
        }
        at.push(n);
        let to = |x: u32| at[(x as usize).clamp(s, e) - s];
        let runs = row
            .runs
            .iter()
            .filter(|r| (r.0 as usize) < e && (r.1 as usize) > s)
            .map(|r| (to(r.0), to(r.1), r.2.clone()))
            .filter(|r| r.0 < r.1)
            .collect();
        Plain { text, runs, placed }
    }
}

/// The roles of chars `[s, e)` in the order they first appear, joined by `+`: the key of a segment the editor measured
/// (`view/measured`).
pub fn roles_key(at: &[usize], inks: &[Ink], s: usize, e: usize) -> String {
    let mut seen: Vec<usize> = Vec::new();
    for i in &at[s.min(at.len())..e.min(at.len())] {
        if !seen.contains(i) {
            seen.push(*i);
        }
    }
    if seen.is_empty() {
        return UI.to_owned();
    }
    seen.iter()
        .map(|i| inks[*i].role.as_str())
        .collect::<Vec<_>>()
        .join("+")
}

/// The property a row gets over its text when the text reaches its tail's control's place (a [`Tail::Hover`]): the
/// editor leaves the control out of the row's tail.
pub const SHORT: &str = "drgnx-row-tail-short";

/// The px ROW keeps clear at the window's right edge for what its tail always draws (ROOM's `tail` places).
fn kept(row: &Row, room: &Room) -> u32 {
    match (row.tail, room.tail) {
        (Some(Tail::Mark), Some((mark, _))) => mark,
        (Some(Tail::Control), Some((_, control))) => control,
        // a terminal shows the control always
        (Some(Tail::Hover), Some((_, control))) if room.tty.is_some() => control,
        _ => 0,
    }
}

/// ROW fitted to ROOM: each segment that runs past its end cut with an ellipsis, and `fonts` set to the roles its
/// text is measured in. Returns whether anything was cut.
pub fn fit_row(row: &mut Row, m: &dyn Measure, room: &Room) -> bool {
    let mut cut = false;
    let segments = row.stops.len();
    let mut chars: Vec<char> = row.text.chars().collect();
    let (mut at, mut list) = inks(row, chars.len(), m);
    let mut w = widths(row, &chars, &at, &list, m, room);
    // the last segment first: a cut moves only the positions after it, which are done
    for k in (0..=segments).rev() {
        let n = chars.len();
        let mut stops_now = row.stops.clone();
        stops_now.sort_by_key(|s| s.0);
        let (s, x0) = match k {
            0 => (0usize, 0.0f32),
            _ => match stops_now.get(k - 1) {
                Some(st) => (st.0 as usize + 1, st.1 as f32),
                None => continue,
            },
        };
        let (e, limit) = match stops_now.get(k) {
            Some(st) if k < stops_now.len() => (st.0 as usize, st.1 as f32),
            _ => (
                n,
                (room.width_px - kept(row, room).min(room.width_px)) as f32,
            ),
        };
        if s >= e {
            continue;
        }
        // the editor measures the segment's text without its images and spaces (their widths are known), keyed by
        // its roles
        let plain = Plain::of(row, &chars, &w, s, e);
        let key = roles_key(&at, &list, s, e);
        let measured = room
            .tty
            .is_none()
            .then(|| m.measured(&key, &plain.text))
            .flatten()
            .map(|px| px + plain.placed);
        let total = measured.unwrap_or_else(|| w[s..e].iter().sum());
        if x0 + total <= limit {
            // a sum this close to the end may be off by more than what is left: the editor measures it, and its width
            // decides from then on
            if measured.is_none() && room.tty.is_none() && x0 + total > limit - SLACK {
                m.measure_ask(&key, &plain.text, &plain.runs);
            }
            continue;
        }
        cut = true;
        let slack = if room.tty.is_some() { 0.0 } else { SLACK };
        let budget = limit - slack;
        // the cut's ellipsis is drawn in the ink of the char before it
        let ell = |p: usize| match room.tty {
            Some((cell, table)) => (fit_tty::char_width(ELLIPSIS, table) as u32 * cell) as f32,
            None => fit::advance(
                m,
                &list[at[p.saturating_sub(1).max(s).min(n - 1)]].role,
                ELLIPSIS,
            ),
        };
        let mut best = None;
        let mut used = 0.0;
        let mut i = 0usize;
        for g in row.text.graphemes(true) {
            let len = g.chars().count();
            if i >= s && i <= e && x0 + used + ell(i) <= budget {
                best = Some(i);
            }
            if i >= e {
                break;
            }
            if i >= s {
                used += w[i..(i + len).min(n)].iter().sum::<f32>();
            }
            i += len;
        }
        match best {
            Some(p) => splice(row, p as u32, e as u32, &ELLIPSIS.to_string()),
            None => splice(row, s as u32, e as u32, ""),
        }
        chars = row.text.chars().collect();
        (at, list) = inks(row, chars.len(), m);
        w = widths(row, &chars, &at, &list, m, room);
    }
    // a tail's control shown on hover only is left out where the text reaches its place (the editor shows it over
    // the text on hover)
    row.props.retain(|p| p.2 != SHORT);
    if let (Some(Tail::Hover), Some((_, control)), None) = (row.tail, room.tail, room.tty) {
        let s = row
            .stops
            .iter()
            .map(|st| st.0 as usize + 1)
            .max()
            .unwrap_or(0)
            .min(chars.len());
        let x0 = row
            .stops
            .iter()
            .max_by_key(|st| st.0)
            .map_or(0.0, |st| st.1 as f32);
        let plain = Plain::of(row, &chars, &w, s, chars.len());
        let key = roles_key(&at, &list, s, chars.len());
        let total = room
            .tty
            .is_none()
            .then(|| m.measured(&key, &plain.text))
            .flatten()
            .map(|px| px + plain.placed)
            .unwrap_or_else(|| w[s..].iter().sum());
        if x0 + total > room.width_px.saturating_sub(control) as f32 {
            let end = chars.len() as u32;
            row.props
                .push((0, end, SHORT.to_owned(), serde_json::Value::Bool(true)));
        }
    }
    let n = chars.len();
    row.fonts.clear();
    let mut i = 0;
    while i < n {
        let j = (i..n).find(|j| at[*j] != at[i]).unwrap_or(n);
        if at[i] != 0 {
            row.fonts
                .push((i as u32, j as u32, list[at[i]].role.clone()));
        }
        i = j;
    }
    cut
}
