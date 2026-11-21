//! The Run and Debug view's rows: one per [`Line`], keyed by its id. On a graphical display a level's indent is a
//! space, the chevron an image (as the Explorer's); on a terminal, two spaces and `▸` / `▾`. Every face is one of
//! drgnx-debug-view.el's (`drgnx-debug-view-*`), so the editor knows it. A frame's place, a breakpoint's line and a
//! thread's state stand at the right edge; a value too long for the row ends in `…` (debugging.html `.dv`).

use super::model::Line;
use crate::view::explorer::RowLook;
use crate::view::icons;
use drgnx_rows::faces::FaceId;
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

    /// TEXT's width in px drawn in FACE (none: the view's default), in the font the editor says FACE draws in.
    fn width_in(&self, face: Option<&str>, text: &str) -> u32 {
        match self.cell {
            Some(c) => text.chars().count() as u32 * c,
            None => fit::width_in(self.fonts, face, text).ceil() as u32,
        }
    }

    /// TEXT drawn in FACE cut with `…` to PX.
    fn fit(&self, face: Option<&str>, text: &str, px: u32) -> String {
        match self.cell {
            Some(c) => drgnx_rows::fit_tty::fit(text, (px / c) as usize, &[]),
            None => fit::fit_in(self.fonts, face, text, px as f32),
        }
    }

    /// The room kept at the right edge, and between a text and what stands right of it.
    fn pad(&self) -> u32 {
        self.cell.unwrap_or(8)
    }
}

/// The face of a frame's place and a breakpoint's line at the right edge.
const PLACE: &str = FaceId::DebugViewPlace.name();

/// Where the row's text has got to, px: spaces and images count their size, text its measure.
struct Pen<'r, 'a> {
    b: RowBuilder,
    x: u32,
    room: &'r Room<'a>,
}

impl Pen<'_, '_> {
    fn push(&mut self, text: &str, face: Option<&str>) -> &mut Self {
        self.x += self.room.width_in(face, text);
        self.b.push(text, face);
        self
    }

    /// RIGHT (in FACE) against the right edge; after a gap when the row has no room for that (the hub's row fit then
    /// cuts it at the edge).
    fn right(&mut self, right: &str, face: &str) {
        let w = self.room.width_in(Some(face), right);
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
        FaceId::DebugViewString.name()
    } else if !v.is_empty()
        && v.parse::<f64>().is_ok()
        && v.chars()
            .next()
            .is_some_and(|c| c.is_ascii_digit() || c == '-' || c == '.')
    {
        FaceId::DebugViewNumber.name()
    } else {
        FaceId::DebugViewValue.name()
    }
}

fn line_row(l: &Line, look: &RowLook, room: &Room, images: &mut BTreeMap<ImageId, String>) -> Row {
    let mut p = Pen {
        b: RowBuilder::new(l.id.clone()),
        x: 0,
        room,
    };
    let guide = FaceId::DebugViewGuide.name();
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
        p.push(tick, Some(FaceId::DebugViewTick.name()));
    }
    match l.kind {
        "section" => {
            p.push(&l.label, Some(FaceId::DebugViewSection.name()));
        }
        "scope" | "var" | "watch" => {
            let name_face = if l.kind == "scope" {
                FaceId::DebugViewScope.name()
            } else {
                FaceId::DebugViewName.name()
            };
            p.push(&l.label, Some(name_face));
            if l.lazy {
                p.push(": ", None)
                    .push("(…)", Some(FaceId::DebugViewLink.name()));
            } else if let Some(v) = &l.value {
                let face = if l.error {
                    FaceId::DebugViewError.name()
                } else if l.changed {
                    FaceId::DebugViewChanged.name()
                } else {
                    value_face(v)
                };
                p.push(": ", None);
                let fitted = room.fit(Some(face), &one_line(v), p.left(0));
                p.push(&fitted, Some(face));
            }
            if l.capped {
                p.push("  ", None)
                    .push("expand again", Some(FaceId::DebugViewType.name()));
            }
        }
        "breakpoint" => {
            let (glyph, face) = match l.mark.unwrap_or("plain") {
                "condition" => ("⊜ ", FaceId::DebugViewBreakpoint.name()),
                "log" => ("◆ ", FaceId::DebugViewBreakpoint.name()),
                "off" => ("○ ", FaceId::DebugViewBreakpointOff.name()),
                "unbound" => ("● ", FaceId::DebugViewBreakpointOff.name()),
                _ => ("● ", FaceId::DebugViewBreakpoint.name()),
            };
            p.push(glyph, Some(face));
            // `file:line[:col]`: the file here, the line at the right edge
            let (file, place) = l.label.split_once(':').unwrap_or((&l.label, ""));
            p.push(file, None);
            let reserve = room.width_in(Some(PLACE), place) + room.pad();
            if let Some(d) = &l.detail {
                let d = if l.mark == Some("log") {
                    format!("\"{}\"", one_line(d))
                } else {
                    one_line(d)
                };
                let face = if l.mark == Some("unbound") {
                    FaceId::DebugViewType.name()
                } else {
                    FaceId::DebugViewCondition.name()
                };
                p.push("  ", None);
                let fitted = room.fit(Some(face), &d, p.left(reserve));
                p.push(&fitted, Some(face));
            }
            if !place.is_empty() {
                p.right(place, PLACE);
            }
        }
        "frame" => {
            let face = if l.current {
                Some(FaceId::DebugViewCurrent.name())
            } else {
                None
            };
            let reserve = l
                .detail
                .as_deref()
                .map_or(0, |d| room.width_in(Some(PLACE), d) + room.pad());
            let fitted = room.fit(face, &l.label, p.left(reserve));
            p.push(&fitted, face);
            if let Some(d) = &l.detail {
                p.right(&one_line(d), PLACE);
            }
        }
        "more" => {
            p.push(&l.label, Some(FaceId::DebugViewLink.name()));
        }
        "chunk" | "hidden" | "label" | "empty" => {
            p.push(&l.label, Some(FaceId::DebugViewType.name()));
        }
        _ => {
            p.push(&l.label, None);
        }
    }
    if l.kind != "frame" && l.kind != "breakpoint" {
        if let Some(c) = &l.chip {
            // a thread's state at the right edge; a running one quiet (debugging.html `.st2`, `.st2.run`)
            let face = if c == "RUNNING" {
                FaceId::DebugViewChipQuiet.name()
            } else {
                FaceId::DebugViewChip.name()
            };
            p.right(&format!(" {c} "), face);
        }
        if let Some(d) = &l.detail {
            p.push("  ", None)
                .push(&one_line(d), Some(FaceId::DebugViewType.name()));
        }
    }
    let mut b = p.b;
    let end = b.pos();
    if l.dim {
        b.face(body, end, FaceId::DebugViewDim.name());
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
