//! Cell styles and terminal metadata: what a terminal view's rows need beyond face names (`docs/develop/hub.md`,
//! "Rows"). A patch sends each style once as `[id, style]` (ids in arrays, never object keys), and a run names it as
//! the face `s:<id>`. A colour is `{ansi: N}`, `{rgb: "#rrggbb"}` (program data, not a theme literal) or absent (the
//! default).

use serde::{Deserialize, Serialize};

/// A style's id in its view, from the builder's counter.
pub type StyleId = u32;

/// A row's key on the wire.
pub type RowKey = String;

/// A cell colour.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "lowercase")]
pub enum Colour {
    /// One of the 16 palette colours.
    Ansi(u8),
    /// A colour the program chose (the 256-colour cube included), `"#rrggbb"` on the wire.
    Rgb(
        #[serde(with = "hex")]
        #[cfg_attr(feature = "schema", schemars(with = "String"))]
        [u8; 3],
    ),
    /// The view's default: absent on the wire.
    #[default]
    Default,
}

impl Colour {
    pub fn is_default(&self) -> bool {
        *self == Colour::Default
    }
}

/// `[r, g, b]` as `"#rrggbb"`.
mod hex {
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(c: &[u8; 3], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&format!("#{:02x}{:02x}{:02x}", c[0], c[1], c[2]))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<[u8; 3], D::Error> {
        let s = String::deserialize(d)?;
        let bad = || serde::de::Error::custom(format!("not a #rrggbb colour: {s:?}"));
        let h = s
            .strip_prefix('#')
            .filter(|h| h.len() == 6)
            .ok_or_else(bad)?;
        let byte =
            |i: usize| u8::from_str_radix(h.get(i..i + 2).ok_or_else(bad)?, 16).map_err(|_| bad());
        Ok([byte(0)?, byte(2)?, byte(4)?])
    }
}

fn no(b: &bool) -> bool {
    !*b
}

/// One cell style: colours and attributes. Every field left at its default is absent on the wire.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Style {
    #[serde(default, skip_serializing_if = "Colour::is_default")]
    pub fg: Colour,
    #[serde(default, skip_serializing_if = "Colour::is_default")]
    pub bg: Colour,
    #[serde(default, skip_serializing_if = "Colour::is_default")]
    pub ul_color: Colour,
    #[serde(default, skip_serializing_if = "no")]
    pub bold: bool,
    #[serde(default, skip_serializing_if = "no")]
    pub faint: bool,
    #[serde(default, skip_serializing_if = "no")]
    pub italic: bool,
    #[serde(default, skip_serializing_if = "no")]
    pub underline: bool,
    #[serde(default, skip_serializing_if = "no")]
    pub strike: bool,
    #[serde(default, skip_serializing_if = "no")]
    pub inverse: bool,
    #[serde(default, skip_serializing_if = "no")]
    pub blink: bool,
}

/// What a run's face string names: a registered face, or a style of the patch's (or an earlier patch's) `styles`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Face {
    Named(String),
    Style(StyleId),
}

impl Face {
    /// The face a run's string names: `s:<id>` is a style, anything else a face name.
    pub fn parse(s: &str) -> Face {
        match s.strip_prefix("s:").map(str::parse) {
            Some(Ok(id)) => Face::Style(id),
            _ => Face::Named(s.to_owned()),
        }
    }
}

impl std::fmt::Display for Face {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Face::Named(n) => f.write_str(n),
            Face::Style(id) => write!(f, "s:{id}"),
        }
    }
}

/// The cursor's shape.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "snake_case")]
pub enum CursorShape {
    #[default]
    Block,
    BlockHollow,
    Bar,
    Underline,
}

/// A terminal view's state besides its rows, on every patch that changes it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct TermMeta {
    /// `[row_key, col, shape, visible]`: COL is a scalar index into the row's text.
    pub cursor: (RowKey, u32, CursorShape, bool),
    #[serde(default)]
    pub alt_screen: bool,
    #[serde(default)]
    pub mouse_tracking: bool,
    /// The program asked for bracketed paste (mode 2004).
    #[serde(default)]
    pub bracketed_paste: bool,
    /// The program asked for key event types (the kitty keyboard protocol's flag 2): the editor sends repeats and
    /// releases.
    #[serde(default)]
    pub key_events: bool,
    #[serde(default)]
    pub title: String,
}
