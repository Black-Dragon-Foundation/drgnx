//! mot (*mót*, a mould): the UI kit's token table (docs/develop/standards/ui-kit.md).
//!
//! Every colour and metric the UI draws with is a [`Token`], generated from `themes/tokens.eld`. A [`Theme`] gives each
//! token a value, read from a theme file (`themes/dark.eld`, `light.eld`, `high-contrast.eld`: the approved look's
//! tokens). Nothing else makes a colour from numbers: the scan rule `no-colour-literal` rejects `Rgba::new(…)`, `rgb(…)`,
//! a hex number used as a colour and a `"#…"` string anywhere outside this crate and `themes/`.
//!
//! [`ThemeSwitch`] follows the `ui.theme` setting, and counts a damage event for each switch that changes the theme.

mod sexp;
mod switch;

use std::collections::BTreeMap;
use std::os::fd::AsFd;
use std::path::Path;

use kvardi::Lp;

pub use switch::{THEME_KEY, ThemeSwitch};

/// What a token is.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Colour,
    Metric,
}

include!(concat!(env!("OUT_DIR"), "/tokens.rs"));

/// A colour, 8 bits a channel, not premultiplied.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct Rgba {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Rgba {
    pub const fn new(r: u8, g: u8, b: u8, a: u8) -> Rgba {
        Rgba { r, g, b, a }
    }

    /// `0xAARRGGBB`, not premultiplied: the number Glitnir's `argb` fields hold.
    pub const fn to_argb(self) -> u32 {
        (self.a as u32) << 24 | (self.r as u32) << 16 | (self.g as u32) << 8 | self.b as u32
    }

    /// `#rrggbb` or `#rrggbbaa`.
    pub fn parse(text: &str) -> villa::Result<Rgba> {
        let bad =
            || villa::Error::invalid(format!("`{text}` is not a colour (#rrggbb or #rrggbbaa)."));
        let h = text.strip_prefix('#').ok_or_else(bad)?;
        if !h.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(bad());
        }
        let byte = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).map_err(|_| bad());
        match h.len() {
            6 => Ok(Rgba::new(byte(0)?, byte(2)?, byte(4)?, 255)),
            8 => Ok(Rgba::new(byte(0)?, byte(2)?, byte(4)?, byte(6)?)),
            _ => Err(bad()),
        }
    }
}

/// A theme: a value for every token.
#[derive(Clone, PartialEq, Debug)]
pub struct Theme {
    name: String,
    colours: BTreeMap<Token, Rgba>,
    metrics: BTreeMap<Token, Lp>,
}

fn token_named(name: &str) -> Option<Token> {
    Token::ALL.iter().copied().find(|t| t.name() == name)
}

const BUILTIN: [(&str, &str); 3] = [
    ("dark", include_str!("../themes/dark.eld")),
    ("light", include_str!("../themes/light.eld")),
    ("high-contrast", include_str!("../themes/high-contrast.eld")),
];

impl Theme {
    /// The themes that come with the editor.
    pub fn builtin() -> Vec<Theme> {
        BUILTIN
            .iter()
            .filter_map(|(name, text)| {
                Theme::parse(text)
                    .inspect_err(|e| debug_assert!(false, "{name}: {e}"))
                    .ok()
            })
            .collect()
    }

    /// Read the theme file at PATH.
    pub fn load(path: &Path) -> villa::Result<Theme> {
        let io = |e: eitri::FsError| {
            villa::Error::io(format!("The theme {} could not be read.", path.display()))
                .with_detail(e.to_string())
        };
        let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
            return Err(villa::Error::invalid("A theme path names no file."));
        };
        let dir = eitri::open_path(parent, eitri::Kind::Dir).map_err(io)?;
        let bytes = eitri::read_regular(dir.fd.as_fd(), Path::new(name), 1 << 20).map_err(io)?;
        Theme::parse(&String::from_utf8_lossy(&bytes))
    }

    /// A theme from the text of a file: `(drgnx-theme :version 1 :name "dark" (token value)…)`. A token the table does not
    /// have, a value of the wrong kind, a token twice and a token left without a value are errors.
    pub fn parse(text: &str) -> villa::Result<Theme> {
        use sexp::Item;
        let forms = sexp::parse(text).map_err(|e| {
            villa::Error::invalid("A theme could not be read.")
                .with_detail(format!("line {}: {}", e.line, e.message))
        })?;
        let Some(Item::List(items)) = forms.first() else {
            return Err(villa::Error::invalid("A theme file holds no form."));
        };
        let mut name = String::new();
        let mut colours = BTreeMap::new();
        let mut metrics = BTreeMap::new();
        let mut it = items.iter();
        if it.next() != Some(&Item::Atom("drgnx-theme".into())) {
            return Err(villa::Error::invalid(
                "A theme file starts with `(drgnx-theme`.",
            ));
        }
        let mut rest = it.peekable();
        while let Some(Item::Atom(k)) = rest.peek() {
            let k = k.clone();
            rest.next();
            match (k.as_str(), rest.next()) {
                (":version", Some(Item::Num(_))) => {}
                (":name", Some(Item::Str(n))) => name = n.clone(),
                _ => {
                    return Err(villa::Error::invalid(format!(
                        "A theme's `{k}` has no usable value."
                    )));
                }
            }
        }
        if name.is_empty() {
            return Err(villa::Error::invalid("A theme needs a :name."));
        }
        for item in rest {
            let Item::List(e) = item else {
                return Err(villa::Error::invalid(format!(
                    "The theme `{name}` has a stray item."
                )));
            };
            let [Item::Atom(tok), value] = e.as_slice() else {
                return Err(villa::Error::invalid(format!(
                    "The theme `{name}` has an entry that is not (token value)."
                )));
            };
            let token = token_named(tok).ok_or_else(|| {
                villa::Error::invalid(format!(
                    "The theme `{name}` has the token `{tok}`, which the table does not."
                ))
            })?;
            let again =
                || villa::Error::invalid(format!("The theme `{name}` gives `{tok}` twice."));
            match (token.kind(), value) {
                (Kind::Colour, Item::Str(c)) => {
                    if colours.insert(token, Rgba::parse(c)?).is_some() {
                        return Err(again());
                    }
                }
                (Kind::Metric, Item::Num(n)) => {
                    if metrics.insert(token, Lp(*n as f32)).is_some() {
                        return Err(again());
                    }
                }
                (Kind::Colour, _) => {
                    return Err(villa::Error::invalid(format!(
                        "`{tok}` is a colour: the theme `{name}` must give it as \"#rrggbb\"."
                    )));
                }
                (Kind::Metric, _) => {
                    return Err(villa::Error::invalid(format!(
                        "`{tok}` is a metric: the theme `{name}` must give it as a number."
                    )));
                }
            }
        }
        let missing: Vec<&str> = Token::ALL
            .iter()
            .filter(|t| !colours.contains_key(t) && !metrics.contains_key(t))
            .map(|t| t.name())
            .collect();
        if !missing.is_empty() {
            return Err(villa::Error::invalid(format!(
                "The theme `{name}` has no value for: {}.",
                missing.join(", ")
            )));
        }
        Ok(Theme {
            name,
            colours,
            metrics,
        })
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// Whether the theme gives TOKEN a value of its kind.
    pub fn has(&self, token: Token) -> bool {
        self.colours.contains_key(&token) || self.metrics.contains_key(&token)
    }

    /// The colour of TOKEN. A metric token has none: it is a programming mistake the table's kinds make visible, so it
    /// answers a transparent colour rather than panic in a draw path.
    pub fn colour(&self, token: Token) -> Rgba {
        self.colours
            .get(&token)
            .copied()
            .unwrap_or(Rgba::new(0, 0, 0, 0))
    }

    /// The metric of TOKEN, in logical px (zero for a colour token).
    pub fn metric(&self, token: Token) -> Lp {
        self.metrics.get(&token).copied().unwrap_or(Lp(0.0))
    }
}
