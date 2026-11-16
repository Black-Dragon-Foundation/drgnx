//! The kit's expansion in the hub: a component and its props (a [`Comp`]) become a row's text, face runs, properties
//! and spaces, from the generated tables of `etc/ui/components.eld` ([`crate::kit_gen`]). `core/drgnx-ui-kit.el`
//! expands the same file the same way for Lisp-drawn chrome; the conformance fixture (`test/fixtures/kit`) keeps the
//! two equal (`docs/develop/hub.md`, "The kit").
//!
//! The rule both follow:
//! - padding is a pad of `px = floor(logical × scale + 0.5 + 1e-9)` device px per part, a size made of parts the sum of
//!   the rounded parts (`drgnx-px`); on a terminal, `tty_pad` spaces and `tty_indent` per level;
//! - a glyph is drawn in the env's form ([`KitEnv::glyphs`], what the editor's frame draws), else its Unicode form;
//! - runs: the component's face (none where it has no kit face), then the state's face under it, over the component;
//! - an [`Action`] puts `drgnx-action` = `[kind, args…]` and `mouse-face` (the hover face) over the component and
//!   `hit` px of extra padding each side (none on a terminal).

use crate::builder::RowBuilder;
use crate::faces::FaceId;
use crate::kit_gen::{self, Geom, STATES};
use crate::row::Row;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub use crate::kit_gen::{CompId, GLYPHS, State};

/// What an expansion reads of the display class: its scale, whether it is a terminal, the glyphs as the editor's
/// frame draws them (`ViewEnv.glyphs`: `[name, glyph]`, ASCII on a terminal that is not UTF-8) and the user's density
/// (`ViewEnv.density`, `drgnx-look-density`).
#[derive(Clone, Copy, Debug)]
pub struct KitEnv<'a> {
    pub scale: f32,
    pub tty: bool,
    pub glyphs: &'a [(String, String)],
    pub density: Density,
}

/// The user's density (`drgnx-look-density`): the sizes the kit's `(density KEY)` geometry takes. On the wire, its
/// name; an env without one is comfortable.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "kebab-case")]
pub enum Density {
    Compact,
    #[default]
    Comfortable,
    Roomy,
}

impl Density {
    /// Its name, as a kit variant slice names it (`kit_gen::geom`).
    pub fn name(self) -> &'static str {
        match self {
            Density::Compact => "compact",
            Density::Comfortable => "comfortable",
            Density::Roomy => "roomy",
        }
    }
}

/// What a click or RET on a component does: the editor calls KIND's function (`drgnx-ui-kit-define-action`) with ARGS.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
pub struct Action {
    pub kind: String,
    #[serde(default)]
    pub args: Vec<Value>,
}

/// A row's kind: the `row` component's `kind` axis.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RowKind {
    #[default]
    List,
    Tree,
    Map,
}

impl RowKind {
    fn name(self) -> &'static str {
        match self {
            RowKind::List => "list",
            RowKind::Tree => "tree",
            RowKind::Map => "map",
        }
    }
}

/// A component with its props, as JSON `{"c": "row", …}`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(tag = "c", rename_all = "kebab-case")]
pub enum Comp {
    /// A row of a list, a tree (DEPTH levels in, a twisty: open, closed or none) or a map.
    Row {
        #[serde(default)]
        kind: RowKind,
        #[serde(default)]
        depth: u16,
        #[serde(default)]
        twisty: Option<bool>,
        text: String,
        #[serde(default)]
        state: State,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        action: Option<Action>,
    },
}

/// LOGICAL px at SCALE in device px, rounded half up (`drgnx-px`).
fn px(logical: u16, scale: f32) -> u32 {
    (f64::from(logical) * f64::from(scale) + 0.5 + 1e-9).floor() as u32
}

/// Glyph NAME as ENV draws it: the env's form, else the Unicode one.
fn glyph<'a>(env: &'a KitEnv, name: &str) -> &'a str {
    env.glyphs
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, g)| g.as_str())
        .or_else(|| {
            GLYPHS
                .iter()
                .find(|(n, _, _)| *n == name)
                .map(|(_, u, _)| *u)
        })
        .unwrap_or("")
}

/// STATE's face, none at rest.
fn state_face(state: State) -> Option<FaceId> {
    STATES.iter().find(|(s, _)| *s == state).map(|(_, f)| *f)
}

/// The face a component's text is in: its kit face, none where it has none (the surface's own).
fn comp_face(f: FaceId) -> Option<&'static str> {
    (f != FaceId::Default).then(|| f.name())
}

/// A pad of LOGICAL px (on a graphical display) or CHARS characters (on a terminal) in FACE; nothing when empty.
fn pad(b: &mut RowBuilder, env: &KitEnv, width_px: u32, chars: usize, face: Option<&str>) {
    if env.tty {
        if chars > 0 {
            b.push(&" ".repeat(chars), face);
        }
    } else if width_px > 0 {
        b.pad(width_px, face);
    }
}

/// C's inline expansion onto B (the row being built), at ENV.
pub fn expand(b: &mut RowBuilder, env: &KitEnv, c: &Comp) {
    match c {
        Comp::Row {
            kind,
            depth,
            twisty,
            text,
            state,
            action,
        } => {
            let variant = [kind.name(), env.density.name()];
            let g: Geom = kit_gen::geom(CompId::Row, &variant);
            let face = comp_face(kit_gen::face(CompId::Row, &variant));
            let hit = if action.is_some() && !env.tty {
                px(g.hit, env.scale)
            } else {
                0
            };
            let from = b.pos();
            if hit > 0 {
                b.pad(hit, None);
            }
            let start = b.pos();
            let lead = px(g.pad.0, env.scale) + u32::from(*depth) * px(g.indent, env.scale);
            let lead_chars =
                usize::from(g.tty_pad) + usize::from(*depth) * usize::from(g.tty_indent);
            pad(b, env, lead, lead_chars, face);
            if let (Some(open), Some((closed_name, open_name))) = (twisty, g.twisty) {
                let mark = glyph(env, if *open { open_name } else { closed_name });
                b.push(&format!("{mark} "), face);
            }
            b.push(text, face);
            pad(b, env, px(g.pad.1, env.scale), usize::from(g.tty_pad), face);
            let end = b.pos();
            if hit > 0 {
                b.pad(hit, None);
            }
            if let Some(f) = state_face(*state) {
                b.face(start, end, f.name());
            }
            if let Some(a) = action {
                let to = b.pos();
                let mut v = vec![Value::String(a.kind.clone())];
                v.extend(a.args.iter().cloned());
                b.prop(from, to, "drgnx-action", Value::Array(v));
                b.prop(
                    from,
                    to,
                    "mouse-face",
                    Value::String(FaceId::Hover.name().to_owned()),
                );
            }
        }
    }
}

/// C as whole rows, keys `KEY/0`, `KEY/1`…: a block component's rows (cards, toasts…, in later tasks), an inline one's
/// one row.
pub fn expand_rows(env: &KitEnv, key: &str, c: &Comp) -> Vec<Row> {
    let mut b = RowBuilder::new(format!("{key}/0"));
    expand(&mut b, env, c);
    vec![b.finish()]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(twisty: Option<bool>) -> Comp {
        Comp::Row {
            kind: RowKind::Tree,
            depth: 1,
            twisty,
            text: "a".into(),
            state: State::Rest,
            action: None,
        }
    }

    #[test]
    fn env_glyphs_reach_tty_rows() {
        let glyphs = vec![
            ("chevron-down".to_owned(), "v".to_owned()),
            ("chevron-right".to_owned(), ">".to_owned()),
        ];
        let env = KitEnv {
            scale: 1.0,
            tty: true,
            glyphs: &glyphs,
            density: Density::Comfortable,
        };
        assert_eq!(expand_rows(&env, "k", &row(Some(true)))[0].text, "   v a ");
        assert_eq!(expand_rows(&env, "k", &row(Some(false)))[0].text, "   > a ");
        // no env glyph: the Unicode form
        let env = KitEnv {
            scale: 1.0,
            tty: true,
            glyphs: &[],
            density: Density::Comfortable,
        };
        assert_eq!(expand_rows(&env, "k", &row(Some(true)))[0].text, "   ⌄ a ");
        assert_eq!(expand_rows(&env, "k", &row(None))[0].key, "k/0");
    }

    #[test]
    fn pads_are_rounded_parts() {
        // 6 + 2 × 12 logical px at 1.75: 11 + 2 × 21 = 53 device px, the sum of rounded parts
        let c = Comp::Row {
            kind: RowKind::Tree,
            depth: 2,
            twisty: None,
            text: "a".into(),
            state: State::Selected,
            action: None,
        };
        let r = &expand_rows(
            &KitEnv {
                scale: 1.75,
                tty: false,
                glyphs: &[],
                density: Density::Comfortable,
            },
            "k",
            &c,
        )[0];
        assert_eq!(r.spaces, vec![(0, 53, 0), (2, 11, 0)]);
        assert_eq!(r.runs, vec![(0, 3, FaceId::Selected.name().to_owned())]);
    }

    #[test]
    fn roomy_env_indents_14() {
        // a tree level is the density's `tree-indent`: 12 at comfortable, 14 at roomy
        let at = |density| {
            expand_rows(
                &KitEnv {
                    scale: 1.0,
                    tty: false,
                    glyphs: &[],
                    density,
                },
                "k",
                &row(None),
            )[0]
            .spaces[0]
                .1
        };
        assert_eq!(at(Density::Comfortable), 6 + 12);
        assert_eq!(at(Density::Roomy), 6 + 14);
        // on the wire, its name; none is comfortable
        assert_eq!(serde_json::to_value(Density::Roomy).unwrap(), "roomy");
        assert_eq!(
            serde_json::from_value::<Density>("compact".into()).unwrap(),
            Density::Compact
        );
        assert_eq!(Density::default(), Density::Comfortable);
    }
}
