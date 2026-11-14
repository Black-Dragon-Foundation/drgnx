//! Which representation of a display the view shows, and which the file keeps (design §5.5). Only a short list of types is
//! held; an image is held only after its bytes are checked (magic, dimensions from the header, size caps); an SVG from a kernel
//! is untrusted and never rendered: its text alternative is shown, with a note, and its bytes stay for "save output as file".

use base64::Engine as _;
use serde_json::{Map, Value};

pub const MAX_IMAGE: usize = 5 << 20;
pub const MAX_SIDE: u32 = 8192;
/// The text of one representation held (the cell's cap is in the router).
const MAX_REPR: usize = 1 << 20;

/// What the view shows for a display.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Shown {
    Text {
        text: String,
        markdown: bool,
    },
    Image {
        mime: &'static str,
        width: u32,
        height: u32,
    },
    /// Nothing to show but a line saying why.
    Note(String),
}

#[derive(Clone, Debug)]
pub struct Bundle {
    data: Map<String, Value>,
    metadata: Value,
    shown: Shown,
    /// A line under the shown representation (SVG not shown, image too large).
    pub note: Option<String>,
}

fn text_of(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Array(a) => a
            .iter()
            .map(|x| x.as_str().map(String::from))
            .collect::<Option<Vec<_>>>()
            .map(|v| v.concat()),
        _ => None,
    }
}

/// An image's width and height from its header, when BYTES start as the type MIME says.
pub fn dimensions(mime: &str, b: &[u8]) -> Result<(u32, u32), String> {
    match mime {
        "image/png" => {
            if b.len() < 24 || b[..8] != *b"\x89PNG\r\n\x1a\n" || &b[12..16] != b"IHDR" {
                return Err("not a PNG".into());
            }
            Ok((
                u32::from_be_bytes(b[16..20].try_into().unwrap()),
                u32::from_be_bytes(b[20..24].try_into().unwrap()),
            ))
        }
        _ => {
            if b.len() < 4 || b[..3] != [0xff, 0xd8, 0xff] {
                return Err("not a JPEG".into());
            }
            // walk the segments to a start-of-frame
            let mut i = 2;
            while i + 4 <= b.len() {
                if b[i] != 0xff {
                    return Err("a broken JPEG".into());
                }
                let marker = b[i + 1];
                if marker == 0xff {
                    i += 1;
                    continue;
                }
                let len = u16::from_be_bytes([b[i + 2], b[i + 3]]) as usize;
                if (0xc0..=0xcf).contains(&marker) && !matches!(marker, 0xc4 | 0xc8 | 0xcc) {
                    if i + 9 > b.len() {
                        return Err("a cut JPEG".into());
                    }
                    let h = u16::from_be_bytes([b[i + 5], b[i + 6]]) as u32;
                    let w = u16::from_be_bytes([b[i + 7], b[i + 8]]) as u32;
                    return Ok((w, h));
                }
                i += 2 + len;
            }
            Err("a JPEG without a frame".into())
        }
    }
}

/// The checked image of an encoded string: its dimensions, or why it is not shown.
fn check_image(mime: &'static str, s: &str) -> Result<(u32, u32), String> {
    let clean: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    // decoded size is 3/4 of the encoded: refuse before decoding
    if clean.len() / 4 * 3 > MAX_IMAGE + 3 {
        return Err(format!(
            "image not shown: {} MiB is over the {} MiB limit",
            (clean.len() * 3 / 4) >> 20,
            MAX_IMAGE >> 20
        ));
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(clean)
        .map_err(|_| "image not shown: not valid base64".to_string())?;
    if bytes.len() > MAX_IMAGE {
        return Err(format!(
            "image not shown: {} MiB is over the {} MiB limit",
            bytes.len() >> 20,
            MAX_IMAGE >> 20
        ));
    }
    let (w, h) = dimensions(mime, &bytes).map_err(|e| format!("image not shown: {e}"))?;
    if w == 0 || h == 0 || w > MAX_SIDE || h > MAX_SIDE {
        return Err(format!(
            "image not shown: {w} x {h} is over {MAX_SIDE} x {MAX_SIDE}"
        ));
    }
    Ok((w, h))
}

impl Bundle {
    /// The bundle of a `display_data`, `update_display_data` or `execute_result` content.
    pub fn from_message(content: &Value) -> Bundle {
        let empty = Map::new();
        let incoming = content
            .get("data")
            .and_then(Value::as_object)
            .unwrap_or(&empty);
        let mut data = Map::new();
        let mut notes: Vec<String> = Vec::new();
        let mut image = None;
        for mime in ["image/png", "image/jpeg"] {
            let Some(s) = incoming.get(mime).and_then(text_of) else {
                continue;
            };
            match check_image(
                if mime == "image/png" {
                    "image/png"
                } else {
                    "image/jpeg"
                },
                &s,
            ) {
                Ok((w, h)) => {
                    data.insert(mime.into(), Value::String(s));
                    image.get_or_insert((
                        if mime == "image/png" {
                            "image/png"
                        } else {
                            "image/jpeg"
                        },
                        w,
                        h,
                    ));
                }
                Err(why) => notes.push(why),
            }
        }
        let keep_text = |mime: &str, data: &mut Map<String, Value>| {
            if let Some(s) = incoming.get(mime).and_then(text_of)
                && s.len() <= MAX_REPR
            {
                data.insert(mime.into(), Value::String(s));
            }
        };
        keep_text("text/plain", &mut data);
        keep_text("text/markdown", &mut data);
        let svg = incoming.get("image/svg+xml").and_then(text_of);
        if let Some(s) = &svg
            && s.len() <= MAX_REPR
        {
            data.insert("image/svg+xml".into(), Value::String(s.clone()));
        }
        if let Some(j) = incoming.get("application/json")
            && j.to_string().len() <= MAX_REPR
        {
            data.insert("application/json".into(), j.clone());
        }
        if svg.is_some() {
            notes.push("SVG output not shown: save as file".into());
        }
        let shown = if let Some((mime, width, height)) = image {
            Shown::Image {
                mime,
                width,
                height,
            }
        } else if let Some(s) = data.get("text/markdown").and_then(Value::as_str) {
            Shown::Text {
                text: s.into(),
                markdown: true,
            }
        } else if let Some(s) = data.get("text/plain").and_then(Value::as_str) {
            Shown::Text {
                text: s.into(),
                markdown: false,
            }
        } else if let Some(j) = data.get("application/json") {
            Shown::Text {
                text: serde_json::to_string_pretty(j).unwrap_or_default(),
                markdown: false,
            }
        } else {
            Shown::Note("[mime type not shown]".into())
        };
        Bundle {
            data,
            metadata: content
                .get("metadata")
                .filter(|m| m.is_object())
                .cloned()
                .unwrap_or_else(|| Value::Object(Map::new())),
            shown,
            note: (!notes.is_empty()).then(|| notes.join("; ")),
        }
    }

    pub fn shown(&self) -> &Shown {
        &self.shown
    }

    /// The `data` object of the nbformat output.
    pub fn data(&self) -> Value {
        Value::Object(self.data.clone())
    }

    pub fn metadata(&self) -> Value {
        self.metadata.clone()
    }

    /// The decoded bytes of the held image of MIME (it was checked on the way in).
    pub fn image_bytes(&self, mime: &str) -> Option<Vec<u8>> {
        let s: String = self
            .data
            .get(mime)?
            .as_str()?
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect();
        base64::engine::general_purpose::STANDARD.decode(s).ok()
    }

    /// The SVG a kernel sent, for "save output as file" (never rendered).
    pub fn svg(&self) -> Option<&str> {
        self.data.get("image/svg+xml")?.as_str()
    }

    /// Bytes of text this holds (images count by their encoded size against the image cap, not the text cap).
    pub fn text_len(&self) -> usize {
        self.data
            .iter()
            .filter(|(k, _)| !k.starts_with("image/png") && !k.starts_with("image/jpeg"))
            .map(|(_, v)| {
                v.as_str()
                    .map(str::len)
                    .unwrap_or_else(|| v.to_string().len())
            })
            .sum()
    }
}
