//! The Run and Debug view's rows: one per [`Line`], keyed by its id. On a graphical display a level's indent is a
//! space, the chevron an image (as the Explorer's); on a terminal, two spaces and `▸` / `▾`. Every face is one of
//! drgnx-debug-view.el's (`drgnx-debug-view-*`), so the editor knows it.

use super::model::Line;
use crate::view::explorer::RowLook;
use crate::view::icons;
use drgnx_rows::{ImageId, Row, RowBuilder};
use serde_json::json;
use std::collections::BTreeMap;

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

fn line_row(l: &Line, look: &RowLook, images: &mut BTreeMap<ImageId, String>) -> Row {
    let mut b = RowBuilder::new(l.id.clone());
    let guide = "drgnx-debug-view-guide";
    match look.gui {
        Some((indent, icon, gap)) => {
            for _ in 0..l.depth {
                b.space(indent, icon, guide);
            }
            let name = match l.open {
                Some(true) => Some(("chevron-down", "▾")),
                Some(false) => Some(("chevron-right", "▸")),
                None => None,
            };
            match name.and_then(|(n, alt)| icons::svg(n, icon).map(|i| (i, alt))) {
                Some(((id, svg), alt)) => {
                    images.insert(id, svg);
                    b.image(id, alt);
                }
                None => {
                    b.space(icon, icon, guide);
                }
            }
            b.space(gap, icon, guide);
        }
        None => {
            let chevron = match l.open {
                Some(true) => "▾ ",
                Some(false) => "▸ ",
                None => "  ",
            };
            b.push(&format!("{}{chevron}", "  ".repeat(l.depth)), Some(guide));
        }
    }
    let body = b.pos();
    if let Some(t) = l.ticked {
        let tick = if look.gui.is_some() {
            if t { "☑ " } else { "☐ " }
        } else if t {
            "[x] "
        } else {
            "[ ] "
        };
        b.push(tick, Some("drgnx-debug-view-tick"));
    }
    match l.kind {
        "section" => {
            b.push(&l.label, Some("drgnx-debug-view-section"));
        }
        "scope" | "var" | "watch" => {
            let name_face = if l.kind == "scope" {
                "drgnx-debug-view-scope"
            } else {
                "drgnx-debug-view-name"
            };
            b.push(&l.label, Some(name_face));
            if l.lazy {
                b.push(": ", None)
                    .push("(…)", Some("drgnx-debug-view-link"));
            } else if let Some(v) = &l.value {
                let face = if l.error {
                    "drgnx-debug-view-error"
                } else if l.changed {
                    "drgnx-debug-view-changed"
                } else {
                    value_face(v)
                };
                b.push(": ", None).push(&one_line(v), Some(face));
            }
            if let Some(t) = &l.ty {
                b.push("  ", None).push(t, Some("drgnx-debug-view-type"));
            }
            if l.capped {
                b.push("  ", None)
                    .push("expand again", Some("drgnx-debug-view-type"));
            }
        }
        "breakpoint" => {
            let glyph = if l.dim { "○ " } else { "● " };
            b.push(glyph, Some("drgnx-debug-view-breakpoint"));
            b.push(&l.label, None);
        }
        "more" => {
            b.push(&l.label, Some("drgnx-debug-view-link"));
        }
        "chunk" | "hidden" | "label" => {
            b.push(&l.label, Some("drgnx-debug-view-type"));
        }
        "frame" if l.current => {
            b.push(&l.label, Some("drgnx-debug-view-current"));
        }
        _ => {
            b.push(&l.label, None);
        }
    }
    if let Some(c) = &l.chip {
        b.push("  ", None).push(c, Some("drgnx-debug-view-chip"));
    }
    if let Some(d) = &l.detail {
        b.push("  ", None)
            .push(&one_line(d), Some("drgnx-debug-view-type"));
    }
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

/// LINES' rows in LOOK, and the icons they name (each once).
pub fn rows(lines: &[Line], look: &RowLook) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let mut images = BTreeMap::new();
    let rows = lines
        .iter()
        .map(|l| line_row(l, look, &mut images))
        .collect();
    (rows, images.into_iter().collect())
}
