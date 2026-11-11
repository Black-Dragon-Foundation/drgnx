//! Images (docs/develop/terminal.md, "Images"). One image model, kitty's, in the engine: sixel and iTerm2 images are cut
//! out of the program's output here, decoded off the worker's thread and written to the engine as kitty commands. Each
//! placement the engine reports is drawn into one PNG canvas the editor shows a row slice of per line. Pure: no engine,
//! no thread (the helper is in `worker.rs`).

use base64::Engine as _;
use std::io::Cursor;

/// The longest side of an image or canvas, in pixels: larger ones are refused before anything is allocated.
pub const SIDE_MAX: u32 = 16_384;
/// Base64 characters in one kitty command chunk (the spec's limit).
const KITTY_CHUNK: usize = 4096;

/// Decoded pixels, RGBA.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pixels {
    pub w: u32,
    pub h: u32,
    pub rgba: Vec<u8>,
}

/// Whether a W × H RGBA image fits CAP bytes and the side limit.
pub fn fits(w: u64, h: u64, cap: u64) -> bool {
    w > 0 && h > 0 && w <= SIDE_MAX as u64 && h <= SIDE_MAX as u64 && w * h * 4 <= cap
}

/// A PNG decoded to RGBA, refused (None) before allocating when its declared size does not fit CAP.
pub fn decode_png(bytes: &[u8], cap: u64) -> Option<Pixels> {
    let mut d = png::Decoder::new_with_limits(
        Cursor::new(bytes),
        png::Limits {
            bytes: cap.min(usize::MAX as u64) as usize,
        },
    );
    d.set_transformations(png::Transformations::normalize_to_color8());
    let mut r = d.read_info().ok()?;
    let (w, h) = (r.info().width, r.info().height);
    if !fits(w as u64, h as u64, cap) {
        return None;
    }
    let mut buf = vec![0; r.output_buffer_size()?];
    let info = r.next_frame(&mut buf).ok()?;
    buf.truncate(info.buffer_size());
    let channels = match info.color_type {
        png::ColorType::Rgba => 4,
        png::ColorType::Rgb => 3,
        png::ColorType::GrayscaleAlpha => 2,
        png::ColorType::Grayscale => 1,
        png::ColorType::Indexed => return None,
    };
    let rgba = rgba_from(&buf, channels)?;
    (rgba.len() == (w * h * 4) as usize).then_some(Pixels { w, h, rgba })
}

/// PX of CHANNELS bytes per pixel (gray, gray + alpha, RGB, RGBA) as RGBA.
pub fn rgba_from(px: &[u8], channels: usize) -> Option<Vec<u8>> {
    Some(match channels {
        4 => px.to_vec(),
        3 => px
            .as_chunks::<3>()
            .0
            .iter()
            .flat_map(|p| [p[0], p[1], p[2], 255])
            .collect(),
        2 => px
            .as_chunks::<2>()
            .0
            .iter()
            .flat_map(|p| [p[0], p[0], p[0], p[1]])
            .collect(),
        1 => px.iter().flat_map(|&g| [g, g, g, 255]).collect(),
        _ => return None,
    })
}

/// RGBA PNG bytes of PIXELS, fast compression (a canvas is written once and read by Emacs once).
pub fn encode_png(p: &Pixels) -> Vec<u8> {
    let mut out = Vec::new();
    {
        let mut e = png::Encoder::new(&mut out, p.w, p.h);
        e.set_color(png::ColorType::Rgba);
        e.set_depth(png::BitDepth::Eight);
        e.set_compression(png::Compression::Fast);
        if let Ok(mut w) = e.write_header() {
            let _ = w.write_image_data(&p.rgba);
        }
    }
    out
}

/// Where and how a placement is drawn, as the engine's render state reports it (pixel values use the cell size).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Placement {
    pub image: u32,
    pub generation: u64,
    pub z: i32,
    /// The top-left cell in the viewport (negative: left of it or above it).
    pub col: i32,
    pub row: i32,
    pub cols: u32,
    pub rows: u32,
    /// Where the image starts in the top-left cell.
    pub offset: (u32, u32),
    /// The size to draw it at.
    pub px: (u32, u32),
    /// The part of the image drawn: x, y, width, height in image pixels.
    pub source: (u32, u32, u32, u32),
}

/// One canvas: a placement's cells (COLS × CELL_W by ROWS × CELL_H device pixels) with the source rectangle scaled to
/// the placement's pixel size at its cell offset; transparent elsewhere. None when the canvas does not fit CAP.
pub fn canvas(p: &Placement, image: &Pixels, cell: (u32, u32), cap: u64) -> Option<Pixels> {
    let (cw, ch) = (p.cols.checked_mul(cell.0)?, p.rows.checked_mul(cell.1)?);
    if !fits(cw as u64, ch as u64, cap) || !fits(p.px.0 as u64, p.px.1 as u64, cap) {
        return None;
    }
    let (sx, sy, sw, sh) = p.source;
    let (sw, sh) = (
        sw.min(image.w.saturating_sub(sx)),
        sh.min(image.h.saturating_sub(sy)),
    );
    if sw == 0 || sh == 0 {
        return None;
    }
    let src = image::RgbaImage::from_raw(image.w, image.h, image.rgba.clone())?;
    let crop = image::imageops::crop_imm(&src, sx, sy, sw, sh).to_image();
    let scaled = if (sw, sh) == p.px {
        crop
    } else {
        image::imageops::resize(&crop, p.px.0, p.px.1, image::imageops::FilterType::Triangle)
    };
    let mut out = image::RgbaImage::new(cw, ch);
    image::imageops::overlay(&mut out, &scaled, p.offset.0 as i64, p.offset.1 as i64);
    Some(Pixels {
        w: cw,
        h: ch,
        rgba: out.into_raw(),
    })
}

/// IMAGE fit inside BOX (w, h) px keeping its aspect ratio (KEEP), or stretched to it.
fn fit(image: Pixels, target: (u32, u32), keep: bool) -> Option<Pixels> {
    let (mut w, mut h) = target;
    if keep {
        let r = (w as f64 / image.w as f64).min(h as f64 / image.h as f64);
        w = ((image.w as f64 * r).round() as u32).max(1);
        h = ((image.h as f64 * r).round() as u32).max(1);
    }
    if (w, h) == (image.w, image.h) {
        return Some(image);
    }
    let src = image::RgbaImage::from_raw(image.w, image.h, image.rgba)?;
    let out = image::imageops::resize(&src, w, h, image::imageops::FilterType::Triangle);
    Some(Pixels {
        w,
        h,
        rgba: out.into_raw(),
    })
}

/// The kitty command that shows PIXELS at the cursor and moves the cursor past it (`C=0`, the default), silently
/// (`q=2`: the program gets no answer to a command it did not send), chunked.
pub fn kitty_command(p: &Pixels) -> Vec<u8> {
    let data = base64::engine::general_purpose::STANDARD.encode(&p.rgba);
    let chunks: Vec<&[u8]> = data.as_bytes().chunks(KITTY_CHUNK).collect();
    let mut out = Vec::with_capacity(data.len() + chunks.len() * 16 + 64);
    for (i, c) in chunks.iter().enumerate() {
        let more = u8::from(i + 1 < chunks.len());
        if i == 0 {
            out.extend_from_slice(
                format!("\x1b_Ga=T,f=32,s={},v={},C=0,q=2,m={more};", p.w, p.h).as_bytes(),
            );
        } else {
            out.extend_from_slice(format!("\x1b_Gm={more};").as_bytes());
        }
        out.extend_from_slice(c);
        out.extend_from_slice(b"\x1b\\");
    }
    out
}

// ---- Cutting sixel and iTerm2 images out of the output ----

/// A piece of the program's output.
#[derive(Debug, PartialEq, Eq)]
pub enum Piece<'a> {
    /// Bytes for the engine as they are.
    Pass(&'a [u8]),
    /// A sixel image: the DCS parameters (`P1;P2;P3`) and the data after `q`.
    Sixel { params: Vec<u8>, data: Vec<u8> },
    /// An iTerm2 `OSC 1337` image sequence: what follows `1337;` (`File=…`, `MultipartFile=…`, `FilePart=…`,
    /// `FileEnd`).
    Iterm(Vec<u8>),
    /// A sixel or iTerm2 sequence longer than the limit: dropped to its end.
    TooLong,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Ground,
    /// ESC seen.
    Esc,
    /// `ESC P` and parameters seen: a sixel if `q` comes next.
    Dcs,
    /// `ESC ]` and some of `1337;Key=` seen.
    Osc,
    /// Inside a sixel (true) or iTerm2 sequence; `esc`: an ESC just came.
    Data {
        sixel: bool,
        esc: bool,
    },
}

/// The OSC 1337 keys that carry images; other `OSC 1337` keys (`CurrentDir`, `Copy`, …) go to the engine.
const ITERM_KEYS: [&[u8]; 4] = [
    b"1337;File=",
    b"1337;MultipartFile=",
    b"1337;FilePart=",
    b"1337;FileEnd",
];
/// The most bytes held while deciding (a DCS's parameters, an OSC's key).
const DECIDE_MAX: usize = 64;

/// Cuts sixel and iTerm2 images out of a byte stream that may split them anywhere.  A DCS with intermediates (`$ q`,
/// `+ q`: DECRQSS, XTGETTCAP) and every other sequence go on untouched.
#[derive(Debug)]
pub struct Cutter {
    state: State,
    held: Vec<u8>,
    data: Vec<u8>,
    params: Vec<u8>,
    too_long: bool,
    max: usize,
}

impl Cutter {
    /// A cutter dropping sequences over MAX bytes.
    pub fn new(max: usize) -> Cutter {
        Cutter {
            state: State::Ground,
            held: Vec::new(),
            data: Vec::new(),
            params: Vec::new(),
            too_long: false,
            max,
        }
    }

    pub fn set_max(&mut self, max: usize) {
        self.max = max;
    }

    /// Feed BYTES; F gets the pieces in order.
    pub fn feed(&mut self, bytes: &[u8], mut f: impl FnMut(Piece<'_>)) {
        let mut i = 0;
        while i < bytes.len() {
            match self.state {
                State::Ground => {
                    let rest = &bytes[i..];
                    match rest.iter().position(|&b| b == 0x1b) {
                        None => {
                            f(Piece::Pass(rest));
                            return;
                        }
                        Some(at) => {
                            if at > 0 {
                                f(Piece::Pass(&rest[..at]));
                            }
                            self.held.clear();
                            self.held.push(0x1b);
                            self.state = State::Esc;
                            i += at + 1;
                        }
                    }
                }
                State::Esc => {
                    let b = bytes[i];
                    match b {
                        b'P' => {
                            self.held.push(b);
                            self.params.clear();
                            self.state = State::Dcs;
                            i += 1;
                        }
                        b']' => {
                            self.held.push(b);
                            self.state = State::Osc;
                            i += 1;
                        }
                        _ => self.pass_held(&mut f),
                    }
                }
                State::Dcs => {
                    let b = bytes[i];
                    if (b.is_ascii_digit() || b == b';') && self.held.len() < DECIDE_MAX {
                        self.held.push(b);
                        self.params.push(b);
                        i += 1;
                    } else if b == b'q' {
                        self.start_data(true);
                        i += 1;
                    } else {
                        self.pass_held(&mut f);
                    }
                }
                State::Osc => {
                    let b = bytes[i];
                    self.held.push(b);
                    let key = &self.held[2..];
                    if let Some(k) = ITERM_KEYS.iter().find(|k| **k == key) {
                        // the data starts after `1337;`
                        self.start_data(false);
                        self.data.extend_from_slice(&k[5..]);
                        i += 1;
                    } else if ITERM_KEYS.iter().any(|k| k.starts_with(key)) {
                        i += 1;
                    } else {
                        // not an image: the held bytes, this one included, go as they are
                        f(Piece::Pass(&self.held));
                        self.held.clear();
                        self.state = State::Ground;
                        i += 1;
                    }
                }
                State::Data { sixel, esc } => {
                    let rest = &bytes[i..];
                    if esc {
                        self.state = State::Data { sixel, esc: false };
                        if rest[0] == b'\\' {
                            self.finish(sixel, &mut f);
                            i += 1;
                        } else {
                            // a new escape sequence cuts this one short: it is dropped, the escape goes on
                            self.abort();
                            self.held.clear();
                            self.held.push(0x1b);
                            self.state = State::Esc;
                        }
                        continue;
                    }
                    // the data runs to the next ESC, BEL (OSC only), CAN or SUB
                    let end = rest.iter().position(|&b| {
                        b == 0x1b || b == 0x18 || b == 0x1a || (!sixel && b == 0x07)
                    });
                    let take = end.unwrap_or(rest.len());
                    if !self.too_long {
                        if self.data.len() + take > self.max {
                            self.too_long = true;
                            self.data = Vec::new();
                        } else {
                            self.data.extend_from_slice(&rest[..take]);
                        }
                    }
                    i += take;
                    if let Some(e) = end {
                        let b = rest[e];
                        i += 1;
                        match b {
                            0x1b => self.state = State::Data { sixel, esc: true },
                            0x07 => self.finish(sixel, &mut f),
                            _ => self.abort(),
                        }
                    }
                }
            }
        }
    }

    fn pass_held(&mut self, f: &mut impl FnMut(Piece<'_>)) {
        f(Piece::Pass(&self.held));
        self.held.clear();
        self.state = State::Ground;
    }

    fn start_data(&mut self, sixel: bool) {
        self.held.clear();
        self.data.clear();
        self.too_long = false;
        self.state = State::Data { sixel, esc: false };
    }

    fn finish(&mut self, sixel: bool, f: &mut impl FnMut(Piece<'_>)) {
        self.state = State::Ground;
        if std::mem::take(&mut self.too_long) {
            f(Piece::TooLong);
            return;
        }
        let data = std::mem::take(&mut self.data);
        if sixel {
            f(Piece::Sixel {
                params: std::mem::take(&mut self.params),
                data,
            });
        } else {
            f(Piece::Iterm(data));
        }
    }

    fn abort(&mut self) {
        self.state = State::Ground;
        self.too_long = false;
        self.data = Vec::new();
    }
}

// ---- Decoding a cut-out sequence ----

/// What the helper needs to know about the terminal when a sequence reaches it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct At {
    pub cell: (u32, u32),
    pub cols: u16,
    pub rows: u16,
    /// The cursor's column (0-based).
    pub col: u16,
    /// The decode cap in bytes of RGBA.
    pub cap: u64,
}

/// The upper bound of a sixel image's size from its data, read without decoding: the widest band (repeats counted)
/// and six rows per band, or the raster attributes when larger.
pub fn sixel_bound(data: &[u8]) -> (u64, u64) {
    let (mut x, mut w, mut bands) = (0u64, 0u64, 1u64);
    let (mut rw, mut rh) = (0u64, 0u64);
    let mut i = 0;
    let num = |i: &mut usize| -> u64 {
        let mut n = 0u64;
        while *i < data.len() && data[*i].is_ascii_digit() {
            n = n
                .saturating_mul(10)
                .saturating_add((data[*i] - b'0') as u64);
            *i += 1;
        }
        n
    };
    while i < data.len() {
        match data[i] {
            b'!' => {
                i += 1;
                let n = num(&mut i).max(1);
                if i < data.len() && (b'?'..=b'~').contains(&data[i]) {
                    x = x.saturating_add(n);
                    i += 1;
                }
            }
            b'"' => {
                i += 1;
                let mut v = [0u64; 4];
                for (k, slot) in v.iter_mut().enumerate() {
                    *slot = num(&mut i);
                    if k < 3 && i < data.len() && data[i] == b';' {
                        i += 1;
                    } else {
                        break;
                    }
                }
                rw = rw.max(v[2]);
                rh = rh.max(v[3]);
            }
            b'#' => {
                i += 1;
                while i < data.len() && (data[i].is_ascii_digit() || data[i] == b';') {
                    i += 1;
                }
            }
            b'$' => {
                x = 0;
                i += 1;
            }
            b'-' => {
                x = 0;
                bands = bands.saturating_add(1);
                i += 1;
            }
            b'?'..=b'~' => {
                x = x.saturating_add(1);
                i += 1;
            }
            _ => i += 1,
        }
        w = w.max(x);
    }
    (w.max(rw), bands.saturating_mul(6).max(rh))
}

/// A sixel image decoded (P2 = 1: unset pixels transparent), or why not.
pub fn decode_sixel(params: &[u8], data: &[u8], cap: u64) -> Result<Pixels, String> {
    let (w, h) = sixel_bound(data);
    if !fits(w.max(1), h.max(1), cap) {
        return Err(format!("sixel of up to {w}×{h} px is over the limit"));
    }
    let p: Vec<Option<u16>> = params
        .split(|&b| b == b';')
        .map(|s| std::str::from_utf8(s).ok()?.parse().ok())
        .collect();
    let at = |i: usize| p.get(i).copied().flatten();
    let settings = icy_sixel::DcsSettings::new(at(0), at(1), at(2));
    let img = icy_sixel::SixelImage::decode_from_dcs(data, settings).map_err(|e| e.to_string())?;
    let (w, h) = (img.width as u32, img.height as u32);
    if !fits(w as u64, h as u64, cap) || img.pixels.len() != (w * h * 4) as usize {
        return Err(format!("sixel of {w}×{h} px is over the limit"));
    }
    Ok(Pixels {
        w,
        h,
        rgba: img.pixels,
    })
}

/// The engine's bytes for a sixel at AT: the image, then the row below it at the column the image started in
/// (xterm's sixel scrolling).
pub fn sixel_bytes(p: &Pixels, at: &At) -> Vec<u8> {
    let mut out = kitty_command(p);
    out.extend_from_slice(format!("\r\n\x1b[{}G", at.col as u32 + 1).as_bytes());
    out
}

/// An iTerm2 file's arguments (`name=…;width=…;…`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ItermArgs {
    pub inline: bool,
    pub width: Option<String>,
    pub height: Option<String>,
    pub keep_aspect: bool,
}

pub fn iterm_args(s: &[u8]) -> ItermArgs {
    let mut a = ItermArgs {
        keep_aspect: true,
        ..Default::default()
    };
    for kv in String::from_utf8_lossy(s).split(';') {
        let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
        match k {
            "inline" => a.inline = v == "1",
            "width" => a.width = Some(v.to_string()),
            "height" => a.height = Some(v.to_string()),
            "preserveAspectRatio" => a.keep_aspect = v != "0",
            _ => {}
        }
    }
    a
}

/// A size argument in px: N cells (of CELL px), Npx, N% of FULL px, `auto` or none (None).
fn iterm_size(v: Option<&str>, cell: u32, full: u32) -> Option<u32> {
    let v = v?;
    if v == "auto" || v.is_empty() {
        None
    } else if let Some(n) = v.strip_suffix("px") {
        n.parse().ok()
    } else if let Some(n) = v.strip_suffix('%') {
        n.parse::<u64>()
            .ok()
            .map(|n| (n * full as u64 / 100) as u32)
    } else {
        v.parse::<u32>().ok().map(|n| n.saturating_mul(cell))
    }
}

/// An iTerm2 image decoded and sized as ARGS ask (PNG, JPEG or GIF), or why not.
pub fn decode_iterm(args: &ItermArgs, b64: &[u8], at: &At) -> Result<Pixels, String> {
    if !args.inline {
        return Err("a file to save (inline=0): refused".into());
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(
            b64.iter()
                .copied()
                .filter(|b| !b.is_ascii_whitespace())
                .collect::<Vec<_>>(),
        )
        .map_err(|e| e.to_string())?;
    let format = image::guess_format(&bytes).map_err(|e| e.to_string())?;
    if !matches!(
        format,
        image::ImageFormat::Png | image::ImageFormat::Jpeg | image::ImageFormat::Gif
    ) {
        return Err(format!("{format:?} is not shown"));
    }
    let mut r = image::ImageReader::with_format(Cursor::new(&bytes), format);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(SIDE_MAX);
    limits.max_image_height = Some(SIDE_MAX);
    limits.max_alloc = Some(at.cap);
    r.limits(limits.clone());
    let (w, h) = r.into_dimensions().map_err(|e| e.to_string())?;
    if !fits(w as u64, h as u64, at.cap) {
        return Err(format!("{w}×{h} px is over the limit"));
    }
    let mut r = image::ImageReader::with_format(Cursor::new(&bytes), format);
    r.limits(limits);
    let img = r.decode().map_err(|e| e.to_string())?.into_rgba8();
    let (w, h) = img.dimensions();
    let full = (at.cols as u32 * at.cell.0, at.rows as u32 * at.cell.1);
    let tw = iterm_size(args.width.as_deref(), at.cell.0, full.0);
    let th = iterm_size(args.height.as_deref(), at.cell.1, full.1);
    let pixels = Pixels {
        w,
        h,
        rgba: img.into_raw(),
    };
    let target = match (tw, th) {
        (None, None) => return Ok(pixels),
        (Some(tw), None) => (tw, ((h as u64 * tw as u64) / w as u64) as u32),
        (None, Some(th)) => (((w as u64 * th as u64) / h as u64) as u32, th),
        (Some(tw), Some(th)) => (tw, th),
    };
    if !fits(target.0 as u64, target.1 as u64, at.cap) {
        return Err(format!("{}×{} px is over the limit", target.0, target.1));
    }
    fit(pixels, target, args.keep_aspect).ok_or_else(|| "resize".into())
}

/// iTerm2 sequences in order: `File=` is whole; `MultipartFile=` starts one that `FilePart=` chunks fill and `FileEnd`
/// ends.
#[derive(Debug, Default)]
pub struct Iterm {
    multipart: Option<(ItermArgs, Vec<u8>)>,
}

impl Iterm {
    /// The image a sequence (what follows `1337;`) completes: its arguments and base64 data, or none yet. MAX bounds a
    /// multipart file's data (past it the file is dropped).
    pub fn take(&mut self, seq: &[u8], max: usize) -> Option<(ItermArgs, Vec<u8>)> {
        if let Some(rest) = seq.strip_prefix(b"File=") {
            let colon = rest.iter().position(|&b| b == b':')?;
            return Some((iterm_args(&rest[..colon]), rest[colon + 1..].to_vec()));
        }
        if let Some(rest) = seq.strip_prefix(b"MultipartFile=") {
            self.multipart = Some((iterm_args(rest), Vec::new()));
            return None;
        }
        if let Some(rest) = seq.strip_prefix(b"FilePart=") {
            if let Some((_, data)) = &mut self.multipart {
                if data.len() + rest.len() > max {
                    self.multipart = None;
                } else {
                    data.extend_from_slice(rest);
                }
            }
            return None;
        }
        if seq == b"FileEnd" {
            return self.multipart.take();
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cut(c: &mut Cutter, chunks: &[&[u8]]) -> (Vec<u8>, Vec<String>) {
        let mut pass = Vec::new();
        let mut got = Vec::new();
        for ch in chunks {
            c.feed(ch, |p| match p {
                Piece::Pass(b) => pass.extend_from_slice(b),
                Piece::Sixel { params, data } => got.push(format!(
                    "sixel {} {}",
                    String::from_utf8_lossy(&params),
                    String::from_utf8_lossy(&data)
                )),
                Piece::Iterm(d) => got.push(format!("iterm {}", String::from_utf8_lossy(&d))),
                Piece::TooLong => got.push("too long".into()),
            });
        }
        (pass, got)
    }

    #[test]
    fn sixel_and_iterm_are_cut_out_wherever_the_writes_split_them() {
        let stream: &[u8] =
            b"a\x1bP0;1;0q#0~~-~~\x1b\\b\x1b]1337;File=inline=1:QUJD\x07c\x1b]1337;CurrentDir=/x\x07d";
        let whole = cut(&mut Cutter::new(1 << 20), &[stream]);
        assert_eq!(
            whole.1,
            vec!["sixel 0;1;0 #0~~-~~", "iterm File=inline=1:QUJD"]
        );
        assert_eq!(whole.0, b"abc\x1b]1337;CurrentDir=/x\x07d");
        for split in 1..stream.len() {
            let (a, b) = stream.split_at(split);
            assert_eq!(
                cut(&mut Cutter::new(1 << 20), &[a, b]),
                whole,
                "split at {split}"
            );
        }
    }

    #[test]
    fn decrqss_xtgettcap_and_other_sequences_go_to_the_engine() {
        let stream: &[u8] = b"\x1bP$qm\x1b\\\x1bP+q544e\x1b\\\x1b[1m\x1b]0;title\x07\x1b]133;A\x07";
        let (pass, got) = cut(&mut Cutter::new(1 << 20), &[stream]);
        assert!(got.is_empty());
        assert_eq!(pass, stream);
    }

    #[test]
    fn a_sequence_over_the_limit_is_dropped_to_its_end_and_an_escape_cuts_one_short() {
        let (pass, got) = cut(&mut Cutter::new(4), &[b"\x1bPq~~~~~~~~\x1b\\x"]);
        assert_eq!(got, vec!["too long"]);
        assert_eq!(pass, b"x");
        let (pass, got) = cut(&mut Cutter::new(64), &[b"\x1bPq~~\x1b[1my"]);
        assert!(got.is_empty());
        assert_eq!(pass, b"\x1b[1my");
        let (pass, got) = cut(&mut Cutter::new(64), &[b"\x1bPq~~\x18z"]);
        assert!(got.is_empty());
        assert_eq!(pass, b"z");
    }

    #[test]
    fn a_sixel_s_size_is_bounded_before_decoding() {
        assert_eq!(sixel_bound(b"#0~~~-~~"), (3, 12));
        assert_eq!(sixel_bound(b"\"1;1;100;50#0!20~"), (100, 50));
        assert_eq!(sixel_bound(b"!65535~!65535~"), (131_070, 6));
        // a huge repeat is refused before any pixel is allocated
        assert!(decode_sixel(b"0;1;0", b"!65535~!65535~", 64 << 20).is_err());
        let p = decode_sixel(b"0;1;0", b"#0;2;100;0;0#0~~", 64 << 20).unwrap();
        assert_eq!((p.w, p.h), (2, 6));
        assert_eq!(&p.rgba[..4], &[255, 0, 0, 255]);
    }

    #[test]
    fn a_png_over_the_cap_is_refused_and_one_under_it_decodes() {
        let p = Pixels {
            w: 3,
            h: 2,
            rgba: (0..24).collect(),
        };
        let png = encode_png(&p);
        assert_eq!(decode_png(&png, 1 << 20), Some(p));
        assert_eq!(decode_png(&png, 8), None);
    }

    #[test]
    fn a_canvas_holds_the_cropped_scaled_source_at_its_cell_offset() {
        let red = Pixels {
            w: 4,
            h: 4,
            rgba: [255, 0, 0, 255].repeat(16),
        };
        let p = Placement {
            image: 1,
            generation: 1,
            z: 0,
            col: 0,
            row: 0,
            cols: 2,
            rows: 1,
            offset: (1, 0),
            px: (2, 2),
            source: (0, 0, 4, 4),
        };
        let c = canvas(&p, &red, (4, 4), 1 << 20).unwrap();
        assert_eq!((c.w, c.h), (8, 4));
        let px = |x: usize, y: usize| &c.rgba[(y * 8 + x) * 4..(y * 8 + x) * 4 + 4];
        assert_eq!(px(0, 0), &[0, 0, 0, 0]);
        assert_eq!(px(1, 0), &[255, 0, 0, 255]);
        assert_eq!(px(2, 1), &[255, 0, 0, 255]);
        assert_eq!(px(3, 0), &[0, 0, 0, 0]);
        assert_eq!(px(1, 2), &[0, 0, 0, 0]);
        // a canvas over the cap is refused
        assert!(canvas(&p, &red, (4, 4), 16).is_none());
    }

    #[test]
    fn iterm_files_whole_and_in_parts_size_and_refuse_saving() {
        let mut it = Iterm::default();
        let (a, d) = it
            .take(b"File=name=eA==;inline=1;width=2:QUJD", 1 << 20)
            .unwrap();
        assert!(a.inline);
        assert_eq!(a.width.as_deref(), Some("2"));
        assert_eq!(d, b"QUJD");
        assert!(it.take(b"MultipartFile=inline=1", 1 << 20).is_none());
        assert!(it.take(b"FilePart=QU", 1 << 20).is_none());
        assert!(it.take(b"FilePart=JD", 1 << 20).is_none());
        let (a, d) = it.take(b"FileEnd", 1 << 20).unwrap();
        assert!(a.inline);
        assert_eq!(d, b"QUJD");
        let at = At {
            cell: (10, 20),
            cols: 80,
            rows: 24,
            col: 0,
            cap: 64 << 20,
        };
        assert!(
            decode_iterm(&iterm_args(b"inline=0"), b"QUJD", &at)
                .unwrap_err()
                .contains("refused")
        );
        let png = encode_png(&Pixels {
            w: 40,
            h: 20,
            rgba: [0, 0, 255, 255].repeat(800),
        });
        let b64 = base64::engine::general_purpose::STANDARD.encode(&png);
        let p = decode_iterm(&iterm_args(b"inline=1;width=2"), b64.as_bytes(), &at).unwrap();
        assert_eq!((p.w, p.h), (20, 10));
        let p = decode_iterm(&iterm_args(b"inline=1;height=50%"), b64.as_bytes(), &at).unwrap();
        assert_eq!((p.w, p.h), (480, 240));
    }

    #[test]
    fn the_kitty_command_is_chunked_and_silent() {
        let p = Pixels {
            w: 64,
            h: 64,
            rgba: vec![7; 64 * 64 * 4],
        };
        let c = String::from_utf8(kitty_command(&p)).unwrap();
        assert!(c.starts_with("\x1b_Ga=T,f=32,s=64,v=64,C=0,q=2,m=1;"));
        assert!(c.contains("\x1b_Gm=1;"));
        assert!(c.ends_with("\x1b\\"));
        assert_eq!(c.matches("m=0;").count(), 1);
    }
}
