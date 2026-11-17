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
use crate::row::{ImageId, Row};
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
    /// On a graphical display that draws icons: the image of an icon name at a size in device px (the view keeps
    /// its SVG), none where the name has no file. Without it an icon is its glyph.
    pub icons: Option<Icons<'a>>,
}

/// The image of an icon NAME at PX device px (`KitEnv::icons`).
#[derive(Clone, Copy)]
pub struct Icons<'a>(pub &'a dyn Fn(&str, u32) -> Option<ImageId>);

impl std::fmt::Debug for Icons<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Icons")
    }
}

/// An icon's size in logical px (Lucide at 16, as the Explorer draws them).
pub const ICON_PX: u16 = 16;

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

/// A chip's tone: its colours. `Agent(N)` (slot 1 to 12) takes the agent's own colour (`drgnx-agent-N`) over the
/// neutral chip.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Tone {
    #[default]
    Neutral,
    Accent,
    Warn,
    Ok,
    Error,
    Agent(u8),
}

impl Tone {
    fn name(self) -> &'static str {
        match self {
            Tone::Neutral => "neutral",
            Tone::Accent => "accent",
            Tone::Warn => "warn",
            Tone::Ok => "ok",
            Tone::Error => "error",
            Tone::Agent(_) => "agent",
        }
    }
}

/// A chip's fill: a tint with the tone's text (soft), or the tone's fill with the on-accent text (solid).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ChipFill {
    #[default]
    Soft,
    Solid,
}

impl ChipFill {
    fn name(self) -> &'static str {
        match self {
            ChipFill::Soft => "soft",
            ChipFill::Solid => "solid",
        }
    }
}

/// A status dot's status.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Status {
    Done,
    Running,
    NeedsYou,
    #[default]
    Idle,
    Error,
}

impl Status {
    fn name(self) -> &'static str {
        match self {
            Status::Done => "done",
            Status::Running => "running",
            Status::NeedsYou => "needs-you",
            Status::Idle => "idle",
            Status::Error => "error",
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
        /// An icon before the text (a file kind, a folder): its name, an image where the env draws icons, else its
        /// glyph.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        action: Option<Action>,
    },
    /// A short label in a tinted rounded box, optionally led by an icon.
    Chip {
        label: String,
        #[serde(default)]
        tone: Tone,
        #[serde(default)]
        fill: ChipFill,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        action: Option<Action>,
    },
    /// A status's glyph in its face, its word after it when `word` is on (always on a terminal).
    StatusDot {
        #[serde(default)]
        status: Status,
        #[serde(default)]
        word: bool,
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
            icon,
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
            // the twisty and the icon: images then a gap where the env draws icons, else glyphs then a space
            let twisty_name = match (twisty, g.twisty) {
                (Some(open), Some((closed, opened))) => Some(if *open { opened } else { closed }),
                _ => None,
            };
            let names = twisty_name
                .map(|n| (n, true))
                .into_iter()
                .chain(icon.as_deref().map(|n| (n, false)));
            for (name, is_twisty) in names {
                let at = b.pos();
                let mark = glyph(env, name);
                // the twisty in the subtle role (the mockups' chevrons), above the row's own and state colours
                let subtle = FaceId::TextSubtle.name();
                match env
                    .icons
                    .filter(|_| !env.tty)
                    .and_then(|i| (i.0)(name, px(ICON_PX, env.scale)))
                {
                    Some(id) => {
                        b.image(id, mark);
                        if is_twisty {
                            b.face(at, at + 1, subtle);
                        }
                        pad(b, env, px(g.gap, env.scale), 0, face);
                    }
                    None if !mark.is_empty() && is_twisty => {
                        b.push(mark, Some(subtle));
                        if let Some(f) = face {
                            b.face(at, b.pos(), f);
                        }
                        b.push(" ", face);
                    }
                    None if !mark.is_empty() => {
                        b.push(&format!("{mark} "), face);
                    }
                    None => {}
                }
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
            // the row is the density's height (`:height (density tree-row)`), in device px; a terminal's is one line
            if !env.tty && g.height > 0 {
                b.height(1, px(g.height, env.scale));
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
        Comp::Chip {
            label,
            tone,
            fill,
            icon,
            action,
        } => {
            let variant = [tone.name(), fill.name(), env.density.name()];
            let g: Geom = kit_gen::geom(CompId::Chip, &variant);
            // an agent's chip is the neutral one with the agent's colour on its text
            let face = match tone {
                Tone::Agent(_) => comp_face(kit_gen::face(CompId::Chip, &["neutral", fill.name()])),
                _ => comp_face(kit_gen::face(CompId::Chip, &variant)),
            };
            let from = b.pos();
            pad(b, env, px(g.pad.0, env.scale), usize::from(g.tty_pad), face);
            if let Some(name) = icon.as_deref() {
                let mark = glyph(env, name);
                match env
                    .icons
                    .filter(|_| !env.tty)
                    .and_then(|i| (i.0)(name, px(ICON_PX, env.scale)))
                {
                    Some(id) => {
                        b.image(id, mark);
                        pad(b, env, px(g.gap, env.scale), 0, face);
                    }
                    None if !mark.is_empty() => {
                        b.push(&format!("{mark} "), face);
                    }
                    None => {}
                }
            }
            let text_from = b.pos();
            b.push(label, face);
            let text_to = b.pos();
            pad(b, env, px(g.pad.1, env.scale), usize::from(g.tty_pad), face);
            // the agent's colour over its label, after the chip's own run (the Lisp expansion's order)
            if let Some(a) = match tone {
                Tone::Agent(n) => agent_face(*n),
                _ => None,
            } {
                b.face(text_from, text_to, a.name());
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
        Comp::StatusDot { status, word } => {
            let variant = [status.name(), env.density.name()];
            let g: Geom = kit_gen::geom(CompId::StatusDot, &variant);
            let face = comp_face(kit_gen::face(CompId::StatusDot, &variant));
            let mark = g.glyph.map_or("", |n| glyph(env, n));
            b.push(mark, face);
            if let Some(w) =
                kit_gen::label(CompId::StatusDot, &variant).filter(|_| *word || env.tty)
            {
                b.push(&format!(" {w}"), face);
            }
        }
    }
}

/// The face of agent SLOT (1 to 12), none outside it.
fn agent_face(slot: u8) -> Option<FaceId> {
    [
        FaceId::Agent1,
        FaceId::Agent2,
        FaceId::Agent3,
        FaceId::Agent4,
        FaceId::Agent5,
        FaceId::Agent6,
        FaceId::Agent7,
        FaceId::Agent8,
        FaceId::Agent9,
        FaceId::Agent10,
        FaceId::Agent11,
        FaceId::Agent12,
    ]
    .get(usize::from(slot).checked_sub(1)?)
    .copied()
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
            icon: None,
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
            icons: None,
        };
        assert_eq!(expand_rows(&env, "k", &row(Some(true)))[0].text, "   v a ");
        assert_eq!(expand_rows(&env, "k", &row(Some(false)))[0].text, "   > a ");
        // no env glyph: the Unicode form
        let env = KitEnv {
            scale: 1.0,
            tty: true,
            glyphs: &[],
            density: Density::Comfortable,
            icons: None,
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
            icon: None,
            action: None,
        };
        let r = &expand_rows(
            &KitEnv {
                scale: 1.75,
                tty: false,
                glyphs: &[],
                density: Density::Comfortable,
                icons: None,
            },
            "k",
            &c,
        )[0];
        assert_eq!(r.spaces, vec![(0, 53, 0), (2, 11, 0)]);
        // the row's own face (the UI font) under the state's
        assert_eq!(
            r.runs,
            vec![
                (0, 3, FaceId::KitRow.name().to_owned()),
                (0, 3, FaceId::Selected.name().to_owned())
            ]
        );
        assert_eq!(r.height, Some(crate::RowHeight { lines: 1, unit: 46 }));
    }

    #[test]
    fn twisty_and_icon_are_images_where_the_env_draws_icons() {
        // a tree row with an open twisty and a folder icon: two images (16 px at 1.25: 20) each with the row's gap
        // after it (6 at 1.25: 8); without icons, the chevron's glyph and a space, and an icon with no glyph is left out
        let c = Comp::Row {
            kind: RowKind::Tree,
            depth: 0,
            twisty: Some(true),
            text: "src".into(),
            state: State::Rest,
            icon: Some("folder".into()),
            action: None,
        };
        let img = |name: &str, px: u32| {
            Some(ImageId {
                hash: if name == "folder" { 2 } else { 1 } * 1000 + u64::from(px),
                epoch: 0,
            })
        };
        let env = |icons| KitEnv {
            scale: 1.25,
            tty: false,
            glyphs: &[],
            density: Density::Comfortable,
            icons,
        };
        let r = &expand_rows(&env(Some(Icons(&img))), "k", &c)[0];
        let ids: Vec<u64> = r.images.iter().map(|(_, id, _)| id.hash).collect();
        assert_eq!(ids, vec![1020, 2020]);
        assert_eq!(r.images[0].0, 1);
        assert_eq!(r.spaces, vec![(0, 8, 0), (2, 8, 0), (4, 8, 0), (8, 8, 0)]);
        assert_eq!(r.text, "     src ");
        let plain = &expand_rows(&env(None), "k", &c)[0];
        assert!(plain.images.is_empty());
        assert_eq!(plain.text, " ⌄ src ");
        // the twisty (image or glyph) in the subtle role, the icon in the row's colours (the mockups' chevrons)
        let subtle = |r: &Row| {
            r.runs
                .iter()
                .filter(|x| x.2 == FaceId::TextSubtle.name())
                .map(|x| (x.0, x.1))
                .collect::<Vec<_>>()
        };
        assert_eq!(subtle(r), vec![(1, 2)]);
        assert_eq!(subtle(plain), vec![(1, 2)]);
    }

    fn chip_env(scale: f32, tty: bool) -> KitEnv<'static> {
        KitEnv {
            scale,
            tty,
            glyphs: &[],
            density: Density::Comfortable,
            icons: None,
        }
    }

    #[test]
    fn a_chip_is_its_label_between_two_pads_in_its_kit_face() {
        // 7 + label + 7 logical px at 1.25: 9 device px a side; the tone's soft face over all of it
        let c = Comp::Chip {
            label: "ok".into(),
            tone: Tone::Ok,
            fill: ChipFill::Soft,
            icon: None,
            action: None,
        };
        let r = &expand_rows(&chip_env(1.25, false), "k", &c)[0];
        assert_eq!(r.text, " ok ");
        assert_eq!(r.spaces, vec![(0, 9, 0), (3, 9, 0)]);
        assert_eq!(
            r.runs,
            vec![(0, 4, FaceId::KitChipOkSoft.name().to_owned())]
        );
        // the solid fill is another face; a terminal is the label between spaces
        let solid = Comp::Chip {
            label: "ok".into(),
            tone: Tone::Ok,
            fill: ChipFill::Solid,
            icon: None,
            action: None,
        };
        let r = &expand_rows(&chip_env(1.0, true), "k", &solid)[0];
        assert_eq!(r.text, " ok ");
        assert!(r.spaces.is_empty());
        assert_eq!(
            r.runs,
            vec![(0, 4, FaceId::KitChipOkSolid.name().to_owned())]
        );
    }

    #[test]
    fn an_agent_chip_has_the_agents_colour_on_its_text() {
        let c = Comp::Chip {
            label: "fix".into(),
            tone: Tone::Agent(3),
            fill: ChipFill::Soft,
            icon: None,
            action: None,
        };
        let r = &expand_rows(&chip_env(1.0, false), "k", &c)[0];
        assert_eq!(
            r.runs,
            vec![
                (0, 5, FaceId::KitChipNeutralSoft.name().to_owned()),
                (1, 4, FaceId::Agent3.name().to_owned())
            ]
        );
    }

    #[test]
    fn a_status_dot_has_its_word_when_asked_and_on_a_terminal() {
        let c = |word| Comp::StatusDot {
            status: Status::NeedsYou,
            word,
        };
        let gui = &expand_rows(&chip_env(1.0, false), "k", &c(false))[0];
        assert_eq!(gui.text, "●");
        let gui = &expand_rows(&chip_env(1.0, false), "k", &c(true))[0];
        assert_eq!(gui.text, "● needs you");
        // an ASCII terminal: the dot's ASCII form and its word
        let ascii = vec![("dot".to_owned(), "*".to_owned())];
        let env = KitEnv {
            glyphs: &ascii,
            ..chip_env(1.0, true)
        };
        assert_eq!(expand_rows(&env, "k", &c(false))[0].text, "* needs you");
        assert_eq!(
            expand_rows(&env, "k", &c(true))[0].runs,
            vec![(0, 11, FaceId::KitStatusDotNeedsYou.name().to_owned())]
        );
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
                    icons: None,
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
