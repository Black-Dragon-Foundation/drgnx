//! SVG images for rows (lanes, band tiles, chips), coloured only from the editor's palette (`view/env`'s
//! `palette`, read from the theme's faces through `core/drgnx-color.el`'s callers). The writer takes palette roles,
//! never colour literals: a role the palette lacks is drawn in `currentColor`.

use std::fmt::Write as _;

/// The editor's palette: `[role, colour]`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Palette(pub Vec<(String, String)>);

impl Palette {
    /// ROLE's colour, or `currentColor` when the palette lacks it. Only a `#hex` or a colour name the editor sent
    /// is written; anything else (a quote, a bracket) reads as missing.
    pub fn colour(&self, role: &str) -> &str {
        self.0
            .iter()
            .find(|(r, _)| r == role)
            .map(|(_, c)| c.as_str())
            .filter(|c| {
                !c.is_empty() && c.chars().all(|ch| ch == '#' || ch.is_ascii_alphanumeric())
            })
            .unwrap_or("currentColor")
    }
}

/// One SVG image, built shape by shape.
pub struct Svg<'a> {
    palette: &'a Palette,
    body: String,
    width: u32,
    height: u32,
}

/// Text escaped for SVG.
fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

impl<'a> Svg<'a> {
    pub fn new(palette: &'a Palette, width: u32, height: u32) -> Self {
        Svg {
            palette,
            body: String::new(),
            width,
            height,
        }
    }

    /// A rectangle filled with ROLE's colour, corners rounded by R.
    pub fn rect(&mut self, x: f32, y: f32, w: f32, h: f32, r: f32, fill: &str) -> &mut Self {
        let c = self.palette.colour(fill);
        let _ = write!(
            self.body,
            r#"<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{c}"/>"#
        );
        self
    }

    /// A line in ROLE's colour, WIDTH px wide.
    pub fn line(
        &mut self,
        from: (f32, f32),
        to: (f32, f32),
        width: f32,
        stroke: &str,
    ) -> &mut Self {
        let c = self.palette.colour(stroke);
        let _ = write!(
            self.body,
            r#"<line x1="{}" y1="{}" x2="{}" y2="{}" stroke="{c}" stroke-width="{width}"/>"#,
            from.0, from.1, to.0, to.1
        );
        self
    }

    /// A path (its `d`) stroked in ROLE's colour.
    pub fn path(&mut self, d: &str, width: f32, stroke: &str) -> &mut Self {
        let c = self.palette.colour(stroke);
        let _ = write!(
            self.body,
            r#"<path d="{}" fill="none" stroke="{c}" stroke-width="{width}"/>"#,
            escape(d)
        );
        self
    }

    /// A path (its `d`) stroked in ROLE's colour, dashed by DASH (lengths in px; none: solid).
    pub fn path_dashed(&mut self, d: &str, width: f32, stroke: &str, dash: &[f32]) -> &mut Self {
        if dash.is_empty() {
            return self.path(d, width, stroke);
        }
        let c = self.palette.colour(stroke);
        let dash: Vec<String> = dash.iter().map(f32::to_string).collect();
        let _ = write!(
            self.body,
            r#"<path d="{}" fill="none" stroke="{c}" stroke-width="{width}" stroke-dasharray="{}"/>"#,
            escape(d),
            dash.join(" ")
        );
        self
    }

    /// TEXT centred on X at baseline Y in ROLE's colour, SIZE px.
    pub fn label(&mut self, x: f32, y: f32, size: f32, fill: &str, text: &str) -> &mut Self {
        let c = self.palette.colour(fill);
        let _ = write!(
            self.body,
            r#"<text x="{x}" y="{y}" font-size="{size}" text-anchor="middle" fill="{c}">{}</text>"#,
            escape(text)
        );
        self
    }

    /// TEXT at (X, Y) in ROLE's colour, SIZE px.
    pub fn text(&mut self, x: f32, y: f32, size: f32, fill: &str, text: &str) -> &mut Self {
        let c = self.palette.colour(fill);
        let _ = write!(
            self.body,
            r#"<text x="{x}" y="{y}" font-size="{size}" fill="{c}">{}</text>"#,
            escape(text)
        );
        self
    }

    pub fn finish(&self) -> String {
        format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{}</svg>"#,
            self.body,
            w = self.width,
            h = self.height
        )
    }
}
