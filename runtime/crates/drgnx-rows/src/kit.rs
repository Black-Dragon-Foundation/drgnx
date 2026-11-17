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

/// A button's style: the `style` axis of the `button` component.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ButtonStyle {
    Primary,
    #[default]
    Secondary,
    Quiet,
    Danger,
}

impl ButtonStyle {
    fn name(self) -> &'static str {
        match self {
            ButtonStyle::Primary => "primary",
            ButtonStyle::Secondary => "secondary",
            ButtonStyle::Quiet => "quiet",
            ButtonStyle::Danger => "danger",
        }
    }
}

/// A component's size: the `size` axis (geometry, never a face).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Size {
    #[default]
    Md,
    Sm,
}

impl Size {
    fn name(self) -> &'static str {
        match self {
            Size::Md => "md",
            Size::Sm => "sm",
        }
    }
}

/// A key hint's variant: `cap` is a key in its box, `menu` the keys as text (a menu's shortcut column).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum KeyHintVariant {
    #[default]
    Cap,
    Menu,
}

impl KeyHintVariant {
    fn name(self) -> &'static str {
        match self {
            KeyHintVariant::Cap => "cap",
            KeyHintVariant::Menu => "menu",
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
    /// A button: LABEL in a box of STYLE and SIZE, its key hint (KEY) after the label.
    Button {
        label: String,
        #[serde(default)]
        style: ButtonStyle,
        #[serde(default)]
        size: Size,
        #[serde(default)]
        state: State,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        key: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        action: Option<Action>,
    },
    /// A key hint: KEYS in their box (or as text, `menu`).
    KeyHint {
        keys: String,
        #[serde(default)]
        variant: KeyHintVariant,
        #[serde(default)]
        state: State,
    },
    /// An agent's mark: its HANDLE (one or two letters) on the colour of its SLOT (1–12, `drgnx-agent-identity`).
    AgentMark { slot: u8, handle: String },
    /// Progress: a bar WIDTH logical px wide or a ring, VALUE from 0 to 1.
    Progress {
        #[serde(default)]
        kind: ProgressKind,
        value: f64,
        #[serde(default)]
        width: u16,
    },
    /// A meter (`progress` of kind `meter`): SPENT against LIMIT (none: no bar) in UNIT, the FORECAST's p50 and p90
    /// totals, in STATE, at SIZE (`card` and `wide` WIDTH logical px wide), then TEXT, which the hub formats (the kit
    /// never converts a unit), and the state's word.
    Meter {
        spent: f64,
        #[serde(default)]
        limit: Option<f64>,
        #[serde(default)]
        unit: MeterUnit,
        #[serde(default)]
        forecast: Option<(f64, f64)>,
        #[serde(default)]
        state: MeterState,
        #[serde(default)]
        size: MeterSize,
        #[serde(default)]
        width: u16,
        #[serde(default)]
        text: String,
    },
}

/// What a meter counts: dollars (`usd-est`: priced at API rates, an estimate), tokens, a count or a share of the week.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum MeterUnit {
    #[default]
    Usd,
    UsdEst,
    Tokens,
    Count,
    Share,
}

impl MeterUnit {
    /// Its spoken word (`drgnx-ui-kit--meter-unit-words`).
    fn word(self) -> &'static str {
        match self {
            MeterUnit::Usd | MeterUnit::UsdEst => "dollars",
            MeterUnit::Tokens => "tokens",
            MeterUnit::Count => "items",
            MeterUnit::Share => "percent of the week",
        }
    }
}

/// A meter's state, which the hub decides (spec: under 80 % ok, from 80 % nearing, at the limit reached, …).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum MeterState {
    #[default]
    Ok,
    Nearing,
    Reached,
    Over,
    ForecastOver,
    None,
    Inherited,
    Unpriced,
}

impl MeterState {
    /// Its spoken word (`drgnx-ui-kit--meter-states`).
    fn spoken(self) -> &'static str {
        match self {
            MeterState::Ok => "ok",
            MeterState::Nearing => "nearing",
            MeterState::Reached => "at limit",
            MeterState::Over => "over",
            MeterState::ForecastOver => "forecast over",
            MeterState::None => "no limit",
            MeterState::Inherited => "inherited",
            MeterState::Unpriced => "unpriced",
        }
    }
}

/// A meter's size: `row` 46 x 4 px, `card` its width x 3, `wide` its width x 6 with the forecast's span.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum MeterSize {
    #[default]
    Row,
    Card,
    Wide,
}

/// A `row` meter's width, logical px (`drgnx-ui-kit-meter-row-px`).
pub const METER_ROW_PX: u16 = 46;
/// A meter's bar height by size (`row`, `card`, `wide`), logical px (`drgnx-ui-kit-meter-heights`).
pub const METER_HEIGHTS: [u16; 3] = [4, 3, 6];
/// A forecast tick's slot, logical px: its line is 1 px in the middle (all of it in high contrast).
pub const METER_TICK_PX: u16 = 2;
/// The gap between a meter's bar and its text, logical px.
pub const METER_GAP_PX: u16 = 6;

/// A progress's kind: the `progress` component's `kind` axis.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProgressKind {
    #[default]
    Bar,
    Ring,
    /// A meter: drawn from `Comp::Meter`; a `Comp::Progress` of this kind is a bar.
    Meter,
}

impl ProgressKind {
    fn name(self) -> &'static str {
        match self {
            ProgressKind::Bar => "bar",
            ProgressKind::Ring => "ring",
            ProgressKind::Meter => "meter",
        }
    }
}

/// A progress bar's height, logical px (`drgnx-ui-kit-progress-bar-px`).
pub const BAR_PX: u16 = 4;
/// Logical px of a progress bar's width per terminal cell (`drgnx-ui-kit-progress-cell-px`).
pub const BAR_CELL_PX: u16 = 8;

/// The agents' colours by slot, 1 first (`drgnx-agent-N`).
const AGENT_FACES: [FaceId; 12] = [
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
];

/// X rounded half up (`drgnx-ui-kit--round`).
fn round_half_up(x: f64) -> u32 {
    (x + 0.5 + 1e-9).floor() as u32
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

/// ACTION's props over `[from, to)`: `drgnx-action` = `[kind, args…]` and `mouse-face` (the hover face).
fn put_action(b: &mut RowBuilder, from: u32, to: u32, a: &Action) {
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

/// A terminal bar onto B (`drgnx-ui-kit--tty-bar`): CELLS cells, V of them filled in eighths: the filled cells and a
/// partial block where the env draws one (an ASCII terminal does not: there the fill rounds to whole cells) in FILL,
/// then the empty ones in TRACK; ASCII's edges around them.
fn tty_bar(b: &mut RowBuilder, env: &KitEnv, cells: u32, v: f64, fill: &str, track: &str) {
    let units = round_half_up(f64::from(cells) * 8.0 * v);
    let part = if !units.is_multiple_of(8) {
        glyph(env, &format!("bar-{}", units % 8))
    } else {
        ""
    };
    let full = if !units.is_multiple_of(8) && part.is_empty() {
        round_half_up(f64::from(cells) * v)
    } else {
        units / 8
    };
    let empty = cells - full - u32::from(!part.is_empty());
    let filled = format!("{}{part}", glyph(env, "bar-full").repeat(full as usize));
    b.push(glyph(env, "bar-left"), None);
    if !filled.is_empty() {
        b.push(&filled, Some(fill));
    }
    if empty > 0 {
        b.push(&glyph(env, "bar-empty").repeat(empty as usize), Some(track));
    }
    b.push(glyph(env, "bar-right"), None);
}

/// X as spoken: a whole number, else up to two decimals (`drgnx-ui-kit--meter-number`).
fn spoken_number(x: f64) -> String {
    let s = format!("{x:.2}");
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s == "-0" { "0".into() } else { s.into() }
}

/// A meter onto B (`drgnx-ui-kit--meter`): with a limit (and a state that has a bar) its bar, the fill SPENT of LIMIT
/// in the state's colour over the track, the forecast's p50 a tick and on a `wide` meter a span to p90 (each part a
/// space the editor draws as an image, `drgnx-ui-kit-bar-display`; on a terminal the cells of a progress bar); then
/// TEXT and the state's word in the caption's face, the word in its colour; its label the amounts, the unit, the
/// state, "estimate" and the forecast, as its `help-echo`.
#[allow(clippy::too_many_arguments)]
fn meter(
    b: &mut RowBuilder,
    env: &KitEnv,
    spent: f64,
    limit: Option<f64>,
    unit: MeterUnit,
    forecast: Option<(f64, f64)>,
    state: MeterState,
    size: MeterSize,
    width: u16,
    text: &str,
) {
    let caption = FaceId::UiCaption.name();
    let fill_face = match state {
        MeterState::Nearing => FaceId::KitProgressMeterNear,
        MeterState::Reached | MeterState::Over => FaceId::KitProgressMeterReached,
        _ => FaceId::KitProgressMeterFill,
    }
    .name();
    let bar_limit =
        limit.filter(|l| *l > 0.0 && !matches!(state, MeterState::None | MeterState::Unpriced));
    let from = b.pos();
    if let Some(l) = bar_limit {
        let v = (spent / l).clamp(0.0, 1.0);
        let track = if state == MeterState::Inherited {
            FaceId::KitProgressMeterOutline.name()
        } else {
            FaceId::KitProgress.name()
        };
        let logical = match size {
            MeterSize::Row => METER_ROW_PX,
            MeterSize::Card | MeterSize::Wide => width,
        };
        if env.tty {
            let cells = round_half_up(f64::from(logical) / f64::from(BAR_CELL_PX)).max(1);
            tty_bar(b, env, cells, v, fill_face, FaceId::KitProgress.name());
            b.push(" ", None);
        } else {
            let total = px(logical, env.scale);
            let h = px(METER_HEIGHTS[size as usize], env.scale);
            let fill = round_half_up(f64::from(total) * v);
            let at = |x: f64| round_half_up(f64::from(total) * (x / l).clamp(0.0, 1.0));
            // the tick's slot [t0, t1) and the span [t1, s1), clamped into the bar
            let (t0, t1, s1) = match forecast {
                Some((p50, p90)) => {
                    let tw = px(METER_TICK_PX, env.scale).min(total);
                    let t0 = at(p50).saturating_sub(tw / 2).min(total - tw);
                    let s1 = if size == MeterSize::Wide {
                        at(p90).max(t0 + tw)
                    } else {
                        t0 + tw
                    };
                    (t0, t0 + tw, s1)
                }
                None => (total, total, total),
            };
            let tick = if state == MeterState::ForecastOver {
                FaceId::KitProgressMeterTickNear
            } else {
                FaceId::KitProgressMeterTick
            }
            .name();
            let span = FaceId::KitProgressMeterSpan.name();
            let mut cuts = vec![0, total, fill.min(total), t0, t1, s1];
            cuts.sort_unstable();
            cuts.dedup();
            // each stretch's top part: the tick over the fill over the span over the track; equal neighbours joined
            let mut parts: Vec<(u32, &str)> = Vec::new();
            for w in cuts.windows(2) {
                let (a, z) = (w[0], w[1]);
                if z <= a || a >= total {
                    continue;
                }
                let f = if a >= t0 && a < t1 {
                    tick
                } else if a < fill {
                    fill_face
                } else if a >= t1 && a < s1 {
                    span
                } else {
                    track
                };
                match parts.last_mut() {
                    Some((n, g)) if *g == f => *n += z - a,
                    _ => parts.push((z - a, f)),
                }
            }
            for (n, f) in parts {
                b.space(n, h, f);
            }
            b.pad(px(METER_GAP_PX, env.scale), None);
        }
    }
    if !text.is_empty() {
        b.push(text, Some(caption));
    }
    let word = match state {
        MeterState::Nearing => bar_limit.map(|l| format!("{} %", round_half_up(100.0 * spent / l))),
        MeterState::Reached => Some("at limit".into()),
        MeterState::Over => Some("over".into()),
        MeterState::ForecastOver => Some("p90 over".into()),
        MeterState::None => Some("no limit".into()),
        MeterState::Unpriced => Some("unpriced".into()),
        MeterState::Ok | MeterState::Inherited => None,
    };
    if let Some(w) = word {
        if !text.is_empty() {
            b.push(" · ", Some(caption));
        }
        let wf = match state {
            MeterState::Nearing | MeterState::ForecastOver => FaceId::KitProgressMeterNear.name(),
            MeterState::Reached | MeterState::Over => FaceId::KitProgressMeterReached.name(),
            _ => caption,
        };
        b.push(&w, Some(wf));
    }
    let to = b.pos();
    if to > from {
        let mut label = match bar_limit {
            Some(l) => format!(
                "{} of {} {}",
                spoken_number(spent),
                spoken_number(l),
                unit.word()
            ),
            None => format!("{} {}", spoken_number(spent), unit.word()),
        };
        label.push_str(", ");
        label.push_str(state.spoken());
        if unit == MeterUnit::UsdEst {
            label.push_str(", estimate");
        }
        if let Some((p50, p90)) = forecast {
            label.push_str(&format!(
                ", forecast {} to {}",
                spoken_number(p50),
                spoken_number(p90)
            ));
        }
        b.prop(from, to, "help-echo", Value::String(label));
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
                put_action(b, from, to, a);
            }
        }
        Comp::Button {
            label,
            style,
            size,
            state,
            key,
            action,
        } => {
            let variant = [style.name(), size.name(), env.density.name()];
            let g: Geom = kit_gen::geom(CompId::Button, &variant);
            let face = comp_face(kit_gen::face(CompId::Button, &variant));
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
            pad(b, env, px(g.pad.0, env.scale), usize::from(g.tty_pad), face);
            b.push(label, face);
            let mut key_run = None;
            if let Some(keys) = key {
                pad(b, env, px(g.gap, env.scale), 1, face);
                let at = b.pos();
                let hint = Comp::KeyHint {
                    keys: keys.clone(),
                    variant: KeyHintVariant::Cap,
                    state: State::Rest,
                };
                expand(b, env, &hint);
                key_run = Some((at, b.pos()));
            }
            pad(b, env, px(g.pad.1, env.scale), usize::from(g.tty_pad), face);
            let end = b.pos();
            if hit > 0 {
                b.pad(hit, None);
            }
            // the button's own fill under its key hint's box
            if let (Some((a, z)), Some(f)) = (key_run, face) {
                b.face(a, z, f);
            }
            // a button has colours of its own: its state is above them (a disabled label is dim, a pressed one filled)
            if let Some(f) = state_face(*state) {
                b.face_over(start, end, f.name());
            }
            if !env.tty && g.height > 0 {
                b.height(1, px(g.height, env.scale));
            }
            if let Some(a) = action {
                let to = b.pos();
                put_action(b, from, to, a);
            }
        }
        Comp::KeyHint {
            keys,
            variant,
            state,
        } => {
            let v = [variant.name(), env.density.name()];
            let from = b.pos();
            let g: Geom = kit_gen::geom(CompId::KeyHint, &v);
            let face = comp_face(kit_gen::face(CompId::KeyHint, &v));
            if env.tty {
                match variant {
                    KeyHintVariant::Cap => b.push(&format!("[{keys}]"), face),
                    KeyHintVariant::Menu => b.push(keys, face),
                };
            } else {
                pad(b, env, px(g.pad.0, env.scale), 0, face);
                b.push(keys, face);
                pad(b, env, px(g.pad.1, env.scale), 0, face);
            }
            // a key hint has a ring of its own: its state is above it
            if let Some(f) = state_face(*state) {
                let to = b.pos();
                b.face_over(from, to, f.name());
            }
        }
        Comp::AgentMark { slot, handle } => agent_mark(b, env, *slot, handle),
        Comp::Progress { kind, value, width } => progress(b, env, *kind, *value, *width),
        Comp::Meter {
            spent,
            limit,
            unit,
            forecast,
            state,
            size,
            width,
            text,
        } => meter(
            b, env, *spent, *limit, *unit, *forecast, *state, *size, *width, text,
        ),
    }
}

/// SLOT's agent mark onto B (`drgnx-ui-kit--agent-mark`): the handle between the pads on the agent's colour (its face
/// under the kit face's inverse video); on a terminal `[H]` in the colour. Its label is its `help-echo`.
fn agent_mark(b: &mut RowBuilder, env: &KitEnv, slot: u8, handle: &str) {
    let agent = AGENT_FACES[usize::from(slot.clamp(1, 12)) - 1].name();
    let label = format!(
        "{} {handle}",
        kit_gen::label(CompId::AgentMark, &[]).unwrap_or_default()
    );
    let from = b.pos();
    if env.tty {
        b.push(&format!("[{handle}]"), Some(agent));
    } else {
        let g = kit_gen::geom(CompId::AgentMark, &[]);
        let kit = FaceId::KitAgentMark.name();
        b.pad(px(g.pad.0, env.scale), Some(kit));
        b.push(handle, Some(kit));
        b.pad(px(g.pad.1, env.scale), Some(kit));
        let to = b.pos();
        b.face(from, to, agent);
    }
    let to = b.pos();
    b.prop(from, to, "help-echo", Value::String(label));
}

/// Progress onto B (`drgnx-ui-kit--progress`): a bar is the fill (VALUE of the width, rounded half up) then the track,
/// each a space [`BAR_PX`] high in its face, which the editor draws as the bar's images (`drgnx-ui-kit-bar-display`);
/// on a terminal its cells (one per [`BAR_CELL_PX`]): the filled ones and a partial block, then the empty ones. A ring is one of
/// the glyphs `progress-0`..`progress-4`. Its label, "N percent", is its `help-echo`.
fn progress(b: &mut RowBuilder, env: &KitEnv, kind: ProgressKind, value: f64, width: u16) {
    let v = value.clamp(0.0, 1.0);
    let face = comp_face(kit_gen::face(CompId::Progress, &[kind.name()])).unwrap_or("default");
    let fill_face = FaceId::KitProgressFill.name();
    let from = b.pos();
    match kind {
        ProgressKind::Ring => {
            let name = format!("progress-{}", round_half_up(4.0 * v));
            b.push(glyph(env, &name), Some(fill_face));
        }
        ProgressKind::Bar | ProgressKind::Meter if env.tty => {
            let cells = round_half_up(f64::from(width) / f64::from(BAR_CELL_PX)).max(1);
            tty_bar(b, env, cells, v, fill_face, face);
        }
        ProgressKind::Bar | ProgressKind::Meter => {
            let total = px(width, env.scale);
            let fill = round_half_up(f64::from(total) * v);
            let h = px(BAR_PX, env.scale);
            for (w, f) in [(fill, fill_face), (total - fill, face)] {
                if w > 0 {
                    b.space(w, h, f);
                }
            }
        }
    }
    let to = b.pos();
    if to > from {
        let label = format!(
            "{} {}",
            round_half_up(100.0 * v),
            kit_gen::label(CompId::Progress, &[kind.name()]).unwrap_or_default()
        );
        b.prop(from, to, "help-echo", Value::String(label));
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

    fn meter_at(scale: f32, spent: f64, limit: Option<f64>, state: MeterState, text: &str) -> Row {
        let env = KitEnv {
            scale,
            tty: false,
            glyphs: &[],
            density: Density::Comfortable,
            icons: None,
        };
        let c = Comp::Meter {
            spent,
            limit,
            unit: MeterUnit::Usd,
            forecast: None,
            state,
            size: MeterSize::Card,
            width: 120,
            text: text.into(),
        };
        expand_rows(&env, "m", &c).remove(0)
    }

    /// The fill is SPENT over LIMIT of the bar's device px, rounded half up, then the track; a spend past the limit
    /// fills it; no limit, no bar.
    #[test]
    fn meter_fill_follows_spent_over_limit() {
        for scale in [1.0, 1.25, 2.0] {
            let total = px(120, scale);
            let h = px(3, scale);
            for (spent, limit) in [
                (31.0, 40.0),
                (10.0, 40.0),
                (1.0, 3.0),
                (50.0, 40.0),
                (0.0, 7.0),
            ] {
                let r = meter_at(scale, spent, Some(limit), MeterState::Ok, "x");
                let fill = round_half_up(f64::from(total) * (spent / limit).min(1.0));
                let bar: Vec<(u32, u32)> = r
                    .spaces
                    .iter()
                    .filter(|s| s.2 > 0)
                    .map(|s| (s.1, s.2))
                    .collect();
                let want: Vec<(u32, u32)> = [(fill, h), (total - fill, h)]
                    .into_iter()
                    .filter(|p| p.0 > 0)
                    .collect();
                assert_eq!(bar, want, "{spent} of {limit} at {scale}");
            }
        }
        assert!(
            meter_at(1.0, 12.0, None, MeterState::None, "$12")
                .spaces
                .is_empty()
        );
    }

    /// The text is the hub's, as it came: the kit adds only its separator and the state's word.
    #[test]
    fn meter_text_is_never_converted() {
        let r = meter_at(
            1.0,
            36.0,
            Some(40.0),
            MeterState::Nearing,
            "≈$36 / $40 est.",
        );
        assert!(r.text.ends_with("≈$36 / $40 est. · 90 %"), "{}", r.text);
        let r = meter_at(1.0, 12.0, None, MeterState::None, "$12");
        assert_eq!(r.text, "$12 · no limit");
        let r = meter_at(1.0, 31.0, Some(40.0), MeterState::Ok, "31 % wk");
        assert!(r.text.ends_with(" 31 % wk"), "{}", r.text);
    }
}
