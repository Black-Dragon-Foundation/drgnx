//! The Run and Debug view's rows: one per [`Line`], keyed by its id. On a graphical display a level's indent is a
//! space, the chevron an image (as the Explorer's); on a terminal, two spaces and `▸` / `▾`. Every face is one of
//! drgnx-debug-view.el's (`drgnx-debug-view-*`), so the editor knows it. A frame's place, a breakpoint's line and a
//! thread's state stand at the right edge; a value too long for the row ends in `…` (debugging.html `.dv`).

use super::model::Line;
use crate::view::explorer::RowLook;
use crate::view::icons;
use drgnx_rows::fit::{self, Measure};
use drgnx_rows::{ImageId, Row, RowBuilder};
use runstav::methods::view::{Display, ViewEnv};
use serde_json::json;
use std::collections::BTreeMap;

/// The row's width and how text is measured in it, device px: the class's narrowest window and its fonts (a
/// terminal: a column per char).
pub struct Room<'a> {
    pub width: u32,
    pub cell: Option<u32>,
    pub fonts: &'a dyn Measure,
}

impl<'a> Room<'a> {
    pub fn of(env: &ViewEnv, fonts: &'a dyn Measure) -> Self {
        Room {
            width: env.width_px,
            cell: matches!(env.display, Display::Tty).then_some(env.cell.0.max(1)),
            fonts,
        }
    }

    /// TEXT's width in px, in the row's font.
    fn width_of(&self, text: &str) -> u32 {
        self.width_in("ui", text)
    }

    /// TEXT's width in px in font ROLE (`caption`: the small UI font of a place at the right edge).
    fn width_in(&self, role: &str, text: &str) -> u32 {
        match self.cell {
            Some(c) => text.chars().count() as u32 * c,
            None => fit::width(self.fonts, role, text).ceil() as u32,
        }
    }

    /// TEXT cut with `…` to PX.
    fn fit(&self, text: &str, px: u32) -> String {
        match self.cell {
            Some(c) => drgnx_rows::fit_tty::fit(text, (px / c) as usize, &[]),
            None => fit::fit(self.fonts, "ui", text, px as f32),
        }
    }

    /// The room kept at the right edge, and between a text and what stands right of it.
    fn pad(&self) -> u32 {
        self.cell.unwrap_or(8)
    }
}

/// Where the row's text has got to, px: spaces and images count their size, text its measure.
struct Pen<'r, 'a> {
    b: RowBuilder,
    x: u32,
    room: &'r Room<'a>,
}

impl Pen<'_, '_> {
    fn push(&mut self, text: &str, face: Option<&str>) -> &mut Self {
        self.x += self.room.width_of(text);
        self.b.push(text, face);
        self
    }

    /// RIGHT (in FACE, whose font is ROLE's) against the right edge; after a gap when the row has no room for that.
    fn right(&mut self, right: &str, face: &str, role: &str) {
        let w = self.room.width_in(role, right);
        let at = self.room.width.saturating_sub(w + self.room.pad());
        if at >= self.x + self.room.pad() {
            self.b.stop(at);
            self.b.push(right, Some(face));
            self.x = at + w;
        } else {
            self.push(" ", None);
            self.b.push(right, Some(face));
            self.x += w;
        }
    }

    /// Room left on the row before RESERVE px at its right edge (and a gap before it, when there is one).
    fn left(&self, reserve: u32) -> u32 {
        let gaps = if reserve > 0 { 2 } else { 1 };
        self.room
            .width
            .saturating_sub(self.x + reserve + gaps * self.room.pad())
    }
}

/// The face of VALUE as a value: a string's, a number's, else the plain value's.
fn value_face(value: &str) -> &'static str {
    let v = value.trim();
    if v.starts_with('"') || v.starts_with('\'') || v.starts_with("b'") || v.starts_with("b\"") {
        "drgnx-debug-view-string"
    } else if !v.is_empty()
        && v.parse::<f64>().is_ok()
        && v.chars()
            .next()
            .is_some_and(|c| c.is_ascii_digit() || c == '-' || c == '.')
    {
        "drgnx-debug-view-number"
    } else {
        "drgnx-debug-view-value"
    }
}

fn line_row(l: &Line, look: &RowLook, room: &Room, images: &mut BTreeMap<ImageId, String>) -> Row {
    let mut p = Pen {
        b: RowBuilder::new(l.id.clone()),
        x: 0,
        room,
    };
    let guide = "drgnx-debug-view-guide";
    match look.gui {
        Some((indent, icon, gap)) => {
            for _ in 0..l.depth {
                p.b.space(indent, icon, guide);
            }
            let name = match l.open {
                Some(true) => Some(("chevron-down", "▾")),
                Some(false) => Some(("chevron-right", "▸")),
                None => None,
            };
            match name.and_then(|(n, alt)| icons::svg(n, icon).map(|i| (i, alt))) {
                Some(((id, svg), alt)) => {
                    images.insert(id, svg);
                    p.b.image(id, alt);
                }
                None => {
                    p.b.space(icon, icon, guide);
                }
            }
            p.b.space(gap, icon, guide);
            p.x = l.depth as u32 * indent + icon + gap;
        }
        None => {
            let chevron = match l.open {
                Some(true) => "▾ ",
                Some(false) => "▸ ",
                None => "  ",
            };
            p.push(&format!("{}{chevron}", "  ".repeat(l.depth)), Some(guide));
        }
    }
    let body = p.b.pos();
    // a filter's tick box (a breakpoint shows its state in its dot)
    if let (Some(t), "filter") = (l.ticked, l.kind) {
        let tick = if look.gui.is_some() {
            if t { "☑ " } else { "☐ " }
        } else if t {
            "[x] "
        } else {
            "[ ] "
        };
        p.push(tick, Some("drgnx-debug-view-tick"));
    }
    match l.kind {
        "section" => {
            p.push(&l.label, Some("drgnx-debug-view-section"));
        }
        "scope" | "var" | "watch" => {
            let name_face = if l.kind == "scope" {
                "drgnx-debug-view-scope"
            } else {
                "drgnx-debug-view-name"
            };
            p.push(&l.label, Some(name_face));
            if l.lazy {
                p.push(": ", None)
                    .push("(…)", Some("drgnx-debug-view-link"));
            } else if let Some(v) = &l.value {
                let face = if l.error {
                    "drgnx-debug-view-error"
                } else if l.changed {
                    "drgnx-debug-view-changed"
                } else {
                    value_face(v)
                };
                p.push(": ", None);
                let fitted = room.fit(&one_line(v), p.left(0));
                p.push(&fitted, Some(face));
            }
            if l.capped {
                p.push("  ", None)
                    .push("expand again", Some("drgnx-debug-view-type"));
            }
        }
        "breakpoint" => {
            let (glyph, face) = match l.mark.unwrap_or("plain") {
                "condition" => ("⊜ ", "drgnx-debug-view-breakpoint"),
                "log" => ("◆ ", "drgnx-debug-view-breakpoint"),
                "off" => ("○ ", "drgnx-debug-view-breakpoint-off"),
                "unbound" => ("● ", "drgnx-debug-view-breakpoint-off"),
                _ => ("● ", "drgnx-debug-view-breakpoint"),
            };
            p.push(glyph, Some(face));
            // `file:line[:col]`: the file here, the line at the right edge
            let (file, place) = l.label.split_once(':').unwrap_or((&l.label, ""));
            p.push(file, None);
            let reserve = room.width_in("caption", place) + room.pad();
            if let Some(d) = &l.detail {
                let d = if l.mark == Some("log") {
                    format!("\"{}\"", one_line(d))
                } else {
                    one_line(d)
                };
                let face = if l.mark == Some("unbound") {
                    "drgnx-debug-view-type"
                } else {
                    "drgnx-debug-view-condition"
                };
                p.push("  ", None);
                let fitted = room.fit(&d, p.left(reserve));
                p.push(&fitted, Some(face));
            }
            if !place.is_empty() {
                p.right(place, "drgnx-debug-view-place", "caption");
            }
        }
        "frame" => {
            let face = if l.current {
                Some("drgnx-debug-view-current")
            } else {
                None
            };
            let reserve = l
                .detail
                .as_deref()
                .map_or(0, |d| room.width_in("caption", d) + room.pad());
            let fitted = room.fit(&l.label, p.left(reserve));
            p.push(&fitted, face);
            if let Some(d) = &l.detail {
                p.right(&one_line(d), "drgnx-debug-view-place", "caption");
            }
        }
        "more" => {
            p.push(&l.label, Some("drgnx-debug-view-link"));
        }
        "chunk" | "hidden" | "label" => {
            p.push(&l.label, Some("drgnx-debug-view-type"));
        }
        _ => {
            p.push(&l.label, None);
        }
    }
    if l.kind != "frame" && l.kind != "breakpoint" {
        if let Some(c) = &l.chip {
            // a thread's state at the right edge; a running one quiet (debugging.html `.st2`, `.st2.run`)
            let face = if c == "RUNNING" {
                "drgnx-debug-view-chip-quiet"
            } else {
                "drgnx-debug-view-chip"
            };
            p.right(&format!(" {c} "), face, "caption");
        }
        if let Some(d) = &l.detail {
            p.push("  ", None)
                .push(&one_line(d), Some("drgnx-debug-view-type"));
        }
    }
    let mut b = p.b;
    let end = b.pos();
    if l.dim {
        b.face(body, end, "drgnx-debug-view-dim");
    }
    b.prop(0, end, "drgnx-work-id", json!(l.id));
    b.finish()
}

/// TEXT on one row: a newline shown as `↵`.
fn one_line(text: &str) -> String {
    text.replace('\n', "↵")
}

/// LINES' rows in LOOK and ROOM, and the icons they name (each once).
pub fn rows(lines: &[Line], look: &RowLook, room: &Room) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let mut images = BTreeMap::new();
    let rows = lines
        .iter()
        .map(|l| line_row(l, look, room, &mut images))
        .collect();
    (rows, images.into_iter().collect())
}
