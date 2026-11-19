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

pub use crate::kit_gen::{ALL_GLYPHS, CompId, GLYPHS, State};

/// What an expansion reads of the display class: its scale, whether it is a terminal, the glyphs as the editor's
/// frame draws them (`ViewEnv.glyphs`: `[name, glyph]`, ASCII on a terminal that is not UTF-8) and the user's density
/// (`ViewEnv.density`, `drgnx-look-density`).
#[derive(Clone, Copy, Debug)]
pub struct KitEnv<'a> {
    pub scale: f32,
    pub tty: bool,
    pub glyphs: &'a [(String, String)],
    /// A terminal that is not UTF-8 (`drgnx-ui-ascii-frame-p`): a tab's icon not in [`KitEnv::glyphs`] takes its
    /// ASCII form from [`ALL_GLYPHS`].
    pub ascii: bool,
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

/// A card's kind: what its ring says (`needs-you`: the attention colour, `selected`: a 2 px ring).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum CardKind {
    #[default]
    Plain,
    NeedsYou,
    Selected,
}

impl CardKind {
    fn name(self) -> &'static str {
        match self {
            CardKind::Plain => "plain",
            CardKind::NeedsYou => "needs-you",
            CardKind::Selected => "selected",
        }
    }
}

/// Where a row sits in its card: the ring is open where the card goes on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum CardShape {
    #[default]
    Single,
    Top,
    Mid,
    Bottom,
}

impl CardShape {
    fn name(self) -> &'static str {
        match self {
            CardShape::Single => "single",
            CardShape::Top => "top",
            CardShape::Mid => "mid",
            CardShape::Bottom => "bottom",
        }
    }

    /// The shape of row I of N.
    pub fn of(i: usize, n: usize) -> CardShape {
        match (i, n) {
            (_, 0 | 1) => CardShape::Single,
            (0, _) => CardShape::Top,
            (i, n) if i + 1 == n => CardShape::Bottom,
            _ => CardShape::Mid,
        }
    }
}

/// A segment's kind in a range bar (a lane of the Timeline): its colour and its letter on a terminal.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum SegKind {
    #[default]
    Read,
    Search,
    Web,
    Think,
    Edit,
    Test,
    Job,
    WaitYou,
    WaitMachine,
    WaitPermission,
    Stalled,
}

impl SegKind {
    /// Its kit face.
    fn face(self) -> FaceId {
        match self {
            SegKind::Read => FaceId::KitRangeBarSegRead,
            SegKind::Search => FaceId::KitRangeBarSegSearch,
            SegKind::Web => FaceId::KitRangeBarSegWeb,
            SegKind::Think => FaceId::KitRangeBarSegThink,
            SegKind::Edit => FaceId::KitRangeBarSegEdit,
            SegKind::Test => FaceId::KitRangeBarSegTest,
            SegKind::Job => FaceId::KitRangeBarSegJob,
            SegKind::WaitYou | SegKind::WaitMachine | SegKind::WaitPermission => {
                FaceId::KitRangeBarSegWait
            }
            SegKind::Stalled => FaceId::KitRangeBarLate,
        }
    }

    /// Its letter on a terminal (thinking is the glyph `seg-think`: `·`, ASCII `.`).
    fn letter(self) -> Option<char> {
        match self {
            SegKind::Read => Some('R'),
            SegKind::Search => Some('S'),
            SegKind::Web => Some('W'),
            SegKind::Think => None,
            SegKind::Edit => Some('E'),
            SegKind::Test => Some('T'),
            SegKind::Job => Some('J'),
            SegKind::WaitYou => Some('Y'),
            SegKind::WaitMachine => Some('M'),
            SegKind::WaitPermission => Some('P'),
            SegKind::Stalled => Some('!'),
        }
    }
}

/// A tab's size: an editor's tab row (34 px) or a panel's (30 px).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum TabSize {
    #[default]
    Editor,
    Panel,
}

impl TabSize {
    fn name(self) -> &'static str {
        match self {
            TabSize::Editor => "editor",
            TabSize::Panel => "panel",
        }
    }
}

/// What a range bar shows: a scheduled span (`schedule`), spend against a limit (`cost`) or one span of a kind.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RangeVariant {
    #[default]
    Schedule,
    Cost,
    Segment(SegKind),
}

/// A range bar's state, which the hub decides; it picks the parts' colours and the terminal's word.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RangeState {
    #[default]
    OnTrack,
    Behind,
    Late,
    Waiting,
    Slipped,
    Done,
    Forecast,
    OnTarget,
    AtRisk,
    LateVsTarget,
}

/// The values of a range bar's spans on the axis's scale (`from`..`to`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize, Serialize)]
pub struct RangeSpans {
    #[serde(default)]
    pub done_to: Option<f64>,
    #[serde(default)]
    pub p50: Option<f64>,
    #[serde(default)]
    pub p90: Option<f64>,
    #[serde(default)]
    pub baseline: Option<f64>,
    #[serde(default)]
    pub target: Option<f64>,
    #[serde(default)]
    pub limit: Option<f64>,
}

/// A zone as its offset from UTC in minutes (east positive).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(transparent)]
pub struct Zone(pub i32);

/// How much a time axis shows: what its labels are.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AxisLevel {
    TenMin,
    #[default]
    Hour,
    FourHours,
    Day,
    Week,
}

/// A range bar's height in logical px by density: compact, comfortable, roomy.
const RANGE_BAR_HEIGHTS: [u16; 3] = [8, 10, 12];
/// A span is never drawn under this many device px.
const MIN_SPAN_PX: u32 = 2;
/// A tick (the baseline, the target, the limit) is this many device px wide.
const TICK_PX: u32 = 2;

/// A range bar's layers, bottom first: (FROM, TO, FACE) in device px of a bar TOTAL px wide, the top layer at each px
/// the one drawn.
fn range_layers(
    variant: RangeVariant,
    from: f64,
    to: f64,
    spans: &RangeSpans,
    state: RangeState,
    total: u32,
) -> Vec<(u32, u32, FaceId)> {
    let width = (to - from).max(f64::MIN_POSITIVE);
    let at = |x: f64| round_half_up(f64::from(total) * ((x - from) / width).clamp(0.0, 1.0));
    let span = |a: f64, z: f64, f: FaceId| {
        let a = at(a);
        let z = at(z).max(a + MIN_SPAN_PX).min(total.max(MIN_SPAN_PX));
        (a.min(z.saturating_sub(MIN_SPAN_PX)), z, f)
    };
    let tick = |x: f64, f: FaceId| {
        let c = at(x);
        let a = c
            .saturating_sub(TICK_PX / 2)
            .min(total.saturating_sub(TICK_PX));
        (a, a + TICK_PX, f)
    };
    let late = matches!(
        state,
        RangeState::Late | RangeState::Slipped | RangeState::LateVsTarget
    );
    let mut out = Vec::new();
    match variant {
        RangeVariant::Segment(k) => out.push(span(from, to, k.face())),
        RangeVariant::Cost => {
            let p50 = spans.p50.unwrap_or(from);
            if let Some(p90) = spans.p90 {
                out.push(span(p50, p90, FaceId::KitRangeBarTail));
            }
            out.push(span(from, p50, FaceId::KitRangeBar));
            if let Some(l) = spans.limit {
                out.push(tick(l, FaceId::KitRangeBarLate));
            }
        }
        RangeVariant::Schedule => {
            let done = if state == RangeState::Waiting {
                FaceId::KitRangeBarWait
            } else if late {
                FaceId::KitRangeBarLate
            } else {
                FaceId::KitRangeBar
            };
            let done_to = spans.done_to.unwrap_or(from);
            let p50 = spans.p50.unwrap_or(done_to);
            if let Some(p90) = spans.p90 {
                let tail = if late {
                    FaceId::KitRangeBarLate
                } else {
                    FaceId::KitRangeBarTail
                };
                out.push(span(p50, p90, tail));
            }
            out.push(span(done_to, p50, FaceId::KitRangeBarForecast));
            if spans.done_to.is_some() {
                out.push(span(from, done_to, done));
            }
            if let Some(b) = spans.baseline {
                out.push(tick(b, FaceId::KitRangeBar));
            }
            if let Some(t) = spans.target {
                let f = match state {
                    RangeState::AtRisk => FaceId::KitRangeBarWait,
                    RangeState::LateVsTarget => FaceId::KitRangeBarLate,
                    _ => FaceId::KitRangeBar,
                };
                out.push(tick(t, f));
            }
        }
    }
    out
}

/// The face on top at device px X of LAYERS (bottom first), none where nothing is drawn.
fn range_top(layers: &[(u32, u32, FaceId)], x: u32) -> Option<FaceId> {
    layers
        .iter()
        .rev()
        .find(|(a, z, _)| *a <= x && x < *z)
        .map(|l| l.2)
}

/// A range bar onto B (`drgnx-ui-kit--range-bar`): its spans as spaces of the parts' faces (the editor draws each as
/// an image in the face's colour), the row's gaps between them plain; on a terminal a cell per 8 px (`█` to p50 done,
/// `▓` to p50, `░` the tail, `┄` a forecast alone, a segment its letter then `█`) and for a late bar a `▌` and the word
/// late; the hub's LABEL as its `help-echo`.
#[allow(clippy::too_many_arguments)]
fn range_bar(
    b: &mut RowBuilder,
    env: &KitEnv,
    variant: RangeVariant,
    from: f64,
    to: f64,
    spans: &RangeSpans,
    state: RangeState,
    label: &str,
    width: u16,
) {
    let start = b.pos();
    if env.tty {
        let cells = round_half_up(f64::from(width) / f64::from(u32::from(BAR_CELL_PX))).max(1);
        let layers = range_layers(
            variant,
            from,
            to,
            spans,
            state,
            cells * u32::from(BAR_CELL_PX),
        );
        // the glyph is the part's role (done, forecast, tail), the colour the state's: a late tail is still a tail
        let plain = range_layers(
            variant,
            from,
            to,
            spans,
            RangeState::OnTrack,
            cells * u32::from(BAR_CELL_PX),
        );
        for i in 0..cells {
            let mid = i * u32::from(BAR_CELL_PX) + u32::from(BAR_CELL_PX) / 2;
            let top = range_top(&layers, mid);
            let face = top.map(FaceId::name);
            let role = range_top(&plain, mid);
            let text = match (role, variant) {
                (None, _) => " ".to_owned(),
                (Some(_), RangeVariant::Segment(k)) if i == 0 => match k.letter() {
                    Some(c) => c.to_string(),
                    None => glyph(env, "seg-think").to_owned(),
                },
                (Some(_), RangeVariant::Segment(_)) => glyph(env, "bar-full").to_owned(),
                (Some(FaceId::KitRangeBarForecast), _) if state == RangeState::Forecast => {
                    glyph(env, "range-forecast").to_owned()
                }
                (Some(FaceId::KitRangeBarForecast), _) => glyph(env, "range-light").to_owned(),
                (Some(FaceId::KitRangeBarTail), _) => glyph(env, "bar-empty").to_owned(),
                (Some(_), _) => glyph(env, "bar-full").to_owned(),
            };
            b.push(&text, face);
        }
        if matches!(
            state,
            RangeState::Late | RangeState::Slipped | RangeState::LateVsTarget
        ) {
            b.push(
                glyph(env, "range-late"),
                Some(FaceId::KitRangeBarLate.name()),
            );
            b.push(" late", Some(FaceId::KitRangeBarLate.name()));
        }
    } else {
        let total = px(width, env.scale);
        let h = px(RANGE_BAR_HEIGHTS[env.density as usize], env.scale);
        let layers = range_layers(variant, from, to, spans, state, total);
        let mut cuts: Vec<u32> = vec![0, total];
        for (a, z, _) in &layers {
            cuts.push(*a);
            cuts.push((*z).min(total));
        }
        cuts.sort_unstable();
        cuts.dedup();
        let mut parts: Vec<(u32, Option<FaceId>)> = Vec::new();
        for w in cuts.windows(2) {
            let (a, z) = (w[0], w[1]);
            if z <= a || a >= total {
                continue;
            }
            let f = range_top(&layers, a);
            match parts.last_mut() {
                Some((n, g)) if *g == f => *n += z - a,
                _ => parts.push((z - a, f)),
            }
        }
        for (n, f) in parts {
            match f {
                Some(f) => b.space(n, h, f.name()),
                None => b.pad(n, None),
            };
        }
    }
    let end = b.pos();
    if end > start && !label.is_empty() {
        b.prop(start, end, "help-echo", Value::String(label.to_owned()));
    }
}

/// The civil date of DAYS since 1970-01-01: (year, month 1-12, day 1-31).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m, d)
}

/// A tick's label at T (seconds since the epoch) in ZONE at LEVEL: `HH:MM` for the hour levels, the weekday for a day,
/// the month and day for a week.
fn axis_label(t: f64, zone: Zone, level: AxisLevel) -> String {
    let local = t.floor() as i64 + i64::from(zone.0) * 60;
    let days = local.div_euclid(86_400);
    let secs = local.rem_euclid(86_400);
    match level {
        AxisLevel::TenMin | AxisLevel::Hour | AxisLevel::FourHours => {
            format!("{:02}:{:02}", secs / 3600, secs % 3600 / 60)
        }
        AxisLevel::Day => ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]
            [days.rem_euclid(7) as usize]
            .to_owned(),
        AxisLevel::Week => {
            let (_, m, d) = civil_from_days(days);
            let name = [
                "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
            ][m as usize - 1];
            format!("{name} {d}")
        }
    }
}

/// A time axis onto B: the ticks every STEP from FROM to TO with their labels, each label at its tick's pixel (a stop;
/// on a terminal its cell), and NOW as a marker in the now face.
#[allow(clippy::too_many_arguments)]
fn time_axis(
    b: &mut RowBuilder,
    env: &KitEnv,
    from: f64,
    to: f64,
    step: f64,
    zone: Zone,
    now: Option<f64>,
    level: AxisLevel,
    width: u16,
) {
    let face = FaceId::KitTimeAxis.name();
    let now_face = FaceId::KitTimeAxisNow.name();
    let span = (to - from).max(f64::MIN_POSITIVE);
    let mut marks: Vec<(f64, String, &str)> = Vec::new();
    if step > 0.0 {
        let mut t = (from / step).ceil() * step;
        while t <= to + 1e-9 {
            marks.push((t, axis_label(t, zone, level), face));
            t += step;
        }
    }
    if let Some(n) = now.filter(|n| *n >= from && *n <= to) {
        marks.push((n, glyph(env, "axis-now").to_owned(), now_face));
    }
    marks.sort_by(|a, c| a.0.total_cmp(&c.0));
    if env.tty {
        let cells = round_half_up(f64::from(width) / f64::from(BAR_CELL_PX)).max(1) as usize;
        let mut line: Vec<char> = vec![' '; cells];
        let mut now_at = None;
        for (t, text, f) in &marks {
            let col =
                round_half_up(cells as f64 * ((t - from) / span)).min(cells as u32 - 1) as usize;
            if *f == now_face {
                now_at = Some(col);
                continue;
            }
            if text.chars().count() + col <= cells {
                for (i, c) in text.chars().enumerate() {
                    line[col + i] = c;
                }
            }
        }
        match now_at {
            Some(col) => {
                let before: String = line[..col].iter().collect();
                let after: String = line[col + 1..].iter().collect();
                b.push(&before, Some(face));
                b.push(glyph(env, "axis-now"), Some(now_face));
                b.push(&after, Some(face));
            }
            None => {
                let text: String = line.iter().collect();
                b.push(&text, Some(face));
            }
        }
    } else {
        let total = px(width, env.scale);
        for (t, text, f) in &marks {
            let x = round_half_up(f64::from(total) * ((t - from) / span));
            b.stop(x);
            b.push(text, Some(f));
        }
    }
}
/// A tab's icon size in logical px (window-dark.html's `.tab`: 14, as the chrome draws them).
pub const TAB_ICON_PX: u16 = 14;
/// The room each side of a tab's close mark in its 18 px slot, logical px.
pub const TAB_CLOSE_PAD_PX: u16 = 2;
/// A rail item's icon size in logical px (sidebars.html `.rb`: a 32 px square round a 16 px icon).
pub const RAIL_ICON_PX: u16 = 16;

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
    /// A section's header: TITLE (a twisty before it when COLLAPSIBLE, open unless COLLAPSED) and an optional COUNT (a neutral soft chip).
    SectionHeader {
        title: String,
        #[serde(default)]
        collapsible: bool,
        #[serde(default)]
        collapsed: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        count: Option<u32>,
        #[serde(default)]
        state: State,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        action: Option<Action>,
    },
    /// One line of a card of KIND in SHAPE: TEXT with the card's room each side.
    Card {
        #[serde(default)]
        kind: CardKind,
        #[serde(default)]
        shape: CardShape,
        text: String,
    },
    /// A key hint: KEYS in their box (or as text, `menu`).
    KeyHint {
        keys: String,
        #[serde(default)]
        variant: KeyHintVariant,
        #[serde(default)]
        state: State,
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
        #[serde(default)]
        state: State,
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
    /// An agent's mark: its HANDLE (one or two letters) on the colour of its SLOT (1–12, `drgnx-agent-identity`).
    AgentMark { slot: u8, handle: String },
    /// A tab: TITLE of SIZE, an ICON before it, a close mark after it when CLOSE (a dot when MODIFIED). Its STATE:
    /// `selected` is the shown tab, `selected-inactive` the shown tab of a group that is not the active one.
    Tab {
        title: String,
        #[serde(default)]
        size: TabSize,
        #[serde(default)]
        state: State,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
        #[serde(default)]
        close: bool,
        #[serde(default)]
        modified: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        action: Option<Action>,
    },
    /// A segmented switch: ITEMS (a label and its action each) in one track, CURRENT the one shown.
    Segmented {
        items: Vec<(String, Action)>,
        #[serde(default)]
        current: usize,
    },
    /// A rail item: the place's name PLACE (its label), its ICON in a cell in STATE (`selected`: the current place), a
    /// warn dot when DOT (the place changed).
    RailItem {
        place: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
        #[serde(default)]
        state: State,
        #[serde(default)]
        dot: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        action: Option<Action>,
    },
    /// Progress: a bar WIDTH logical px wide or a ring, VALUE from 0 to 1.
    Progress {
        #[serde(default)]
        kind: ProgressKind,
        value: f64,
        #[serde(default)]
        width: u16,
    },
    /// A range bar WIDTH logical px wide: the spans of SPANS on the axis FROM to TO, in STATE; LABEL is its
    /// `help-echo` (the hub writes it).
    RangeBar {
        #[serde(default)]
        variant: RangeVariant,
        from: f64,
        to: f64,
        #[serde(default)]
        spans: RangeSpans,
        #[serde(default)]
        state: RangeState,
        #[serde(default)]
        label: String,
        #[serde(default)]
        width: u16,
    },
    /// A time axis WIDTH logical px wide: ticks every STEP between FROM and TO labelled in ZONE at LEVEL, a marker at
    /// NOW.
    TimeAxis {
        from: f64,
        to: f64,
        step: f64,
        #[serde(default)]
        zone: Zone,
        #[serde(default)]
        now: Option<f64>,
        #[serde(default)]
        level: AxisLevel,
        #[serde(default)]
        width: u16,
    },
    /// The now line through a row: a 1 px stop in the focus colour at AT on the axis FROM to TO, WIDTH logical px wide.
    NowStop {
        at: f64,
        from: f64,
        to: f64,
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

/// A tab's icon NAME as ENV draws it: the env's form, else the whole standard table's ([`ALL_GLYPHS`], ASCII on an
/// ASCII terminal), as the Lisp kit's tab looks it up (`drgnx-ui-kit--glyph`). Other components keep [`glyph`].
fn icon_glyph<'a>(env: &'a KitEnv, name: &str) -> &'a str {
    env.glyphs
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, g)| g.as_str())
        .or_else(|| {
            ALL_GLYPHS
                .iter()
                .find(|(n, _, _)| *n == name)
                .map(|(_, u, a)| if env.ascii { *a } else { *u })
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
        Comp::SectionHeader {
            title,
            collapsible,
            collapsed,
            count,
            state,
            action,
        } => {
            let variant = [if *collapsible { "yes" } else { "no" }, env.density.name()];
            let g: Geom = kit_gen::geom(CompId::SectionHeader, &variant);
            let face = comp_face(kit_gen::face(CompId::SectionHeader, &variant));
            let from = b.pos();
            pad(b, env, px(g.pad.0, env.scale), usize::from(g.tty_pad), face);
            if *collapsible {
                let name = match (g.twisty, *collapsed) {
                    (Some((closed, _)), true) => closed,
                    (Some((_, open)), false) => open,
                    (None, _) => "",
                };
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
                    None => {
                        b.push(mark, face);
                        b.push(" ", face);
                    }
                }
            }
            b.push(title, face);
            if let Some(n) = count {
                pad(b, env, px(g.gap, env.scale), 1, face);
                // the count is a neutral soft chip, as the design draws it
                expand(
                    b,
                    env,
                    &Comp::Chip {
                        label: n.to_string(),
                        tone: Tone::Neutral,
                        fill: ChipFill::Soft,
                        icon: None,
                        state: State::Rest,
                        action: None,
                    },
                );
            }
            pad(b, env, px(g.pad.1, env.scale), usize::from(g.tty_pad), face);
            let to = b.pos();
            if let Some(f) = state_face(*state) {
                b.face_over(from, to, f.name());
            }
            if !env.tty && g.height > 0 {
                b.height(1, px(g.height, env.scale));
            }
            if let Some(a) = action {
                put_action(b, from, to, a);
            }
        }
        Comp::Card { kind, shape, text } => {
            let variant = [kind.name(), shape.name(), env.density.name()];
            let g: Geom = kit_gen::geom(CompId::Card, &variant);
            let face = comp_face(kit_gen::face(CompId::Card, &variant));
            pad(b, env, px(g.pad.0, env.scale), usize::from(g.tty_pad), face);
            b.push(text, face);
            pad(b, env, px(g.pad.1, env.scale), usize::from(g.tty_pad), face);
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
        Comp::Chip {
            label,
            tone,
            fill,
            icon,
            state,
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
                Tone::Agent(n) => usize::from(*n)
                    .checked_sub(1)
                    .and_then(|i| AGENT_FACES.get(i)),
                _ => None,
            } {
                b.face(text_from, text_to, a.name());
            }
            // a chip has colours of its own: its state is above them
            if let Some(f) = state_face(*state) {
                b.face_over(from, b.pos(), f.name());
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
        Comp::AgentMark { slot, handle } => agent_mark(b, env, *slot, handle),
        Comp::Tab {
            title,
            size,
            state,
            icon,
            close,
            modified,
            action,
        } => tab(
            b,
            env,
            title,
            *size,
            *state,
            icon.as_deref(),
            (*close, *modified),
            action.as_ref(),
        ),
        Comp::Segmented { items, current } => segmented(b, env, items, *current),
        Comp::RailItem {
            place,
            icon,
            state,
            dot,
            action,
        } => rail_item(
            b,
            env,
            place,
            icon.as_deref(),
            *state,
            *dot,
            action.as_ref(),
        ),
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
        Comp::RangeBar {
            variant,
            from,
            to,
            spans,
            state,
            label,
            width,
        } => range_bar(b, env, *variant, *from, *to, spans, *state, label, *width),
        Comp::TimeAxis {
            from,
            to,
            step,
            zone,
            now,
            level,
            width,
        } => time_axis(b, env, *from, *to, *step, *zone, *now, *level, *width),
        Comp::NowStop {
            at,
            from,
            to,
            width,
        } => {
            let total = px(*width, env.scale);
            let x = round_half_up(
                f64::from(total)
                    * ((at - from) / (to - from).max(f64::MIN_POSITIVE)).clamp(0.0, 1.0),
            );
            if !env.tty {
                b.stop(x);
                b.space(px(1, env.scale), 0, FaceId::Focus.name());
            }
        }
    }
}

/// A tab onto B (`drgnx-ui-kit--tab`): its pad, the ICON (an image at [`TAB_ICON_PX`] where the env draws icons, then
/// the gap; else its glyph and a space), TITLE, and with CLOSE (CLOSE_MODIFIED's first) the gap and an 18 px slot
/// holding the close mark (the `x` icon, else the glyph `close`), or with MODIFIED (its second) the glyph `dot` in the
/// muted text; then its end pad. The tab's face is its state's: the shown tab `current` (`current-inactive` in a
/// group that is not the active one; a panel's `panel-current`), the others the component's own with the state's
/// face above. The close mark is in the row's colour (`drgnx-control-hidden`) unless the tab is shown or hovered or
/// on a terminal. Its label (`help-echo`) is TITLE, with "modified" after it.
#[allow(clippy::too_many_arguments)]
fn tab(
    b: &mut RowBuilder,
    env: &KitEnv,
    title: &str,
    size: TabSize,
    state: State,
    icon: Option<&str>,
    (close, modified): (bool, bool),
    action: Option<&Action>,
) {
    let variant = [size.name(), env.density.name()];
    let g: Geom = kit_gen::geom(CompId::Tab, &variant);
    let shown = matches!(state, State::Selected | State::SelectedInactive);
    let own = match (size, state) {
        (TabSize::Editor, State::Selected) => FaceId::KitTabCurrent,
        (TabSize::Editor, State::SelectedInactive) => FaceId::KitTabCurrentInactive,
        (TabSize::Panel, State::Selected | State::SelectedInactive) => FaceId::KitTabPanelCurrent,
        _ => kit_gen::face(CompId::Tab, &variant),
    };
    let f = own.name();
    let face = Some(f);
    let icon_image = |name: &str| {
        env.icons
            .filter(|_| !env.tty)
            .and_then(|i| (i.0)(name, px(TAB_ICON_PX, env.scale)))
    };
    let from = b.pos();
    pad(b, env, px(g.pad.0, env.scale), usize::from(g.tty_pad), face);
    if let Some(name) = icon {
        let at = b.pos();
        let mark = icon_glyph(env, name);
        match icon_image(name) {
            Some(id) => {
                b.image(id, mark);
                b.face(at, at + 1, f);
                pad(b, env, px(g.gap, env.scale), 0, face);
            }
            None if !mark.is_empty() => {
                b.push(&format!("{mark} "), face);
            }
            None => {}
        }
    }
    b.push(title, face);
    if close || modified {
        pad(b, env, px(g.gap, env.scale), 1, face);
        let slot = px(TAB_CLOSE_PAD_PX, env.scale);
        pad(b, env, slot, 0, face);
        let at = b.pos();
        let mark_face = if modified {
            FaceId::TextMuted
        } else if shown || state == State::Hover || env.tty {
            FaceId::UiClose
        } else {
            FaceId::ControlHidden
        };
        match icon_image("x").filter(|_| !modified) {
            Some(id) => {
                b.image(id, glyph(env, "close"));
                b.face(at, at + 1, mark_face.name());
            }
            None => {
                b.push(
                    glyph(env, if modified { "dot" } else { "close" }),
                    Some(mark_face.name()),
                );
            }
        }
        // the tab's own colours under the mark's
        let end = b.pos();
        b.face(at, end, f);
        pad(b, env, slot, 0, face);
    }
    pad(b, env, px(g.pad.1, env.scale), usize::from(g.tty_pad), face);
    let to = b.pos();
    // a tab has colours of its own: a state other than shown is above them
    if !shown && let Some(s) = state_face(state) {
        b.face_over(from, to, s.name());
    }
    if let Some(a) = action {
        put_action(b, from, to, a);
    }
    let label = match kit_gen::label(CompId::Tab, &variant).filter(|_| modified) {
        Some(word) => format!("{title}, {word}"),
        None => title.to_owned(),
    };
    b.prop(from, to, "help-echo", Value::String(label));
}

/// A segmented switch onto B (`drgnx-ui-kit--segmented`): each item its pads and label, the CURRENT one in the
/// `current` face, each with its action and its label (`help-echo`, "LABEL, selected" for the current one); the
/// track's face (its ring) under them all.
fn segmented(b: &mut RowBuilder, env: &KitEnv, items: &[(String, Action)], current: usize) {
    let variant = [env.density.name()];
    let g: Geom = kit_gen::geom(CompId::Segmented, &variant);
    let track = kit_gen::face(CompId::Segmented, &variant).name();
    let word = kit_gen::label(CompId::Segmented, &variant).unwrap_or_default();
    let from = b.pos();
    for (i, (label, action)) in items.iter().enumerate() {
        let on = i == current;
        let face = on.then(|| FaceId::KitSegmentedCurrent.name());
        let at = b.pos();
        pad(b, env, px(g.pad.0, env.scale), usize::from(g.tty_pad), face);
        b.push(label, face);
        pad(b, env, px(g.pad.1, env.scale), usize::from(g.tty_pad), face);
        let to = b.pos();
        put_action(b, at, to, action);
        let spoken = if on {
            format!("{label}, {word}")
        } else {
            label.clone()
        };
        b.prop(at, to, "help-echo", Value::String(spoken));
    }
    let end = b.pos();
    b.face(from, end, track);
}

/// A rail item onto B (`drgnx-ui-kit--rail-item`): the surface's inset, then the cell (the icon's inset, the ICON, the
/// warn dot or the inset again) in the `current` face when STATE is shown, then the inset; any other state's face
/// above the cell. Its label is its `help-echo`: PLACE, with the word after it when DOT.
fn rail_item(
    b: &mut RowBuilder,
    env: &KitEnv,
    place: &str,
    icon: Option<&str>,
    state: State,
    dot: bool,
    action: Option<&Action>,
) {
    let variant = [env.density.name()];
    let g: Geom = kit_gen::geom(CompId::RailItem, &variant);
    let shown = matches!(state, State::Selected | State::SelectedInactive);
    let f = if shown {
        FaceId::KitRailItemCurrent
    } else {
        kit_gen::face(CompId::RailItem, &variant)
    }
    .name();
    let face = Some(f);
    pad(b, env, px(g.pad.0, env.scale), 0, None);
    let from = b.pos();
    // a space as high as the cell in FACE (the editor draws it as a picture), the cell's own colours under it
    let tall = |b: &mut RowBuilder, face: FaceId| {
        let at = b.pos();
        b.space(px(g.gap, env.scale), px(g.height, env.scale), face.name());
        let end = b.pos();
        b.face(at, end, f);
    };
    if shown && !env.tty {
        tall(b, FaceId::KitRailItemBar);
    } else {
        pad(b, env, px(g.gap, env.scale), usize::from(g.tty_pad), face);
    }
    if let Some(name) = icon {
        let mark = icon_glyph(env, name);
        let image = env
            .icons
            .filter(|_| !env.tty)
            .and_then(|i| (i.0)(name, px(RAIL_ICON_PX, env.scale)));
        match image {
            Some(id) => {
                let at = b.pos();
                b.image(id, mark);
                b.face(at, at + 1, f);
            }
            None if !mark.is_empty() => {
                b.push(mark, face);
            }
            None => {}
        }
    }
    if dot && env.tty {
        let at = b.pos();
        b.push(glyph(env, "dot"), Some(FaceId::KitRailItemDot.name()));
        let end = b.pos();
        b.face(at, end, f);
    } else if dot {
        tall(b, FaceId::KitRailItemDot);
    } else {
        pad(b, env, px(g.gap, env.scale), usize::from(g.tty_pad), face);
    }
    let to = b.pos();
    pad(b, env, px(g.pad.1, env.scale), 0, None);
    let end = b.pos();
    if !shown && let Some(s) = state_face(state) {
        b.face_over(from, to, s.name());
    }
    if let Some(a) = action {
        put_action(b, from, end, a);
    }
    let label = match kit_gen::label(CompId::RailItem, &variant).filter(|_| dot) {
        Some(word) => format!("{place}, {word}"),
        None => place.to_owned(),
    };
    b.prop(0, end, "help-echo", Value::String(label));
    // the item is its own height, as a row is
    if !env.tty && g.height > 0 {
        b.height(1, px(g.height, env.scale));
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

/// ROWS as the rows of one card of KIND: each row's text under the card's ring face of its shape (single, top, mid,
/// bottom: the ring is open where the card goes on), put under the runs it has.
pub fn card_rows(env: &KitEnv, kind: CardKind, mut rows: Vec<Row>) -> Vec<Row> {
    let n = rows.len();
    for (i, r) in rows.iter_mut().enumerate() {
        let variant = [kind.name(), CardShape::of(i, n).name(), env.density.name()];
        let len = u32::try_from(r.text.chars().count()).unwrap_or(u32::MAX);
        r.runs.push((
            0,
            len,
            kit_gen::face(CompId::Card, &variant).name().to_owned(),
        ));
    }
    rows
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
            ascii: false,
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
            ascii: false,
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
                ascii: false,
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
            ascii: false,
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
            ascii: false,
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
            state: State::Rest,
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
            state: State::Rest,
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
            state: State::Rest,
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
    fn work_cards_are_kit_cards() {
        // the rows of one card get the ring face of their shape under their own runs: single, top/bottom, top/mid/bottom
        let env = KitEnv {
            scale: 1.0,
            tty: false,
            glyphs: &[],
            ascii: false,
            density: Density::Comfortable,
            icons: None,
        };
        let row = |k: &str| {
            let mut b = RowBuilder::new(k);
            b.push("ab", Some(FaceId::TextMuted.name()));
            b.finish()
        };
        let faces = |kind, n: usize| -> Vec<String> {
            card_rows(&env, kind, (0..n).map(|i| row(&i.to_string())).collect())
                .iter()
                .map(|r| r.runs.last().unwrap().2.clone())
                .collect()
        };
        assert_eq!(
            faces(CardKind::Plain, 1),
            vec![FaceId::KitCardPlainSingle.name()]
        );
        assert_eq!(
            faces(CardKind::Selected, 3),
            vec![
                FaceId::KitCardSelectedTop.name(),
                FaceId::KitCardSelectedMid.name(),
                FaceId::KitCardSelectedBottom.name()
            ]
        );
        // under the row's own run: the row's face stays first, the ring covers the whole text
        let r = &card_rows(&env, CardKind::NeedsYou, vec![row("k")])[0];
        assert_eq!(r.runs[0].2, FaceId::TextMuted.name());
        assert_eq!(
            r.runs[1],
            (0, 2, FaceId::KitCardNeedsYouSingle.name().to_owned())
        );
        assert_eq!(CardShape::of(0, 2), CardShape::Top);
        assert_eq!(CardShape::of(1, 2), CardShape::Bottom);
    }

    fn range_env(scale: f32, tty: bool) -> KitEnv<'static> {
        KitEnv {
            scale,
            tty,
            glyphs: &[],
            density: Density::Comfortable,
            icons: None,
            ascii: false,
        }
    }

    fn range(variant: RangeVariant, spans: RangeSpans, state: RangeState) -> Comp {
        Comp::RangeBar {
            variant,
            from: 0.0,
            to: 100.0,
            spans,
            state,
            label: "build: on track".into(),
            width: 200,
        }
    }

    #[test]
    fn range_bar_pixel_stops_at_scale_1_25() {
        // 200 logical px at 1.25 = 250 device px; done to 40, p50 to 60, p90 to 80 of 100: 100, 150, 200 px; the parts
        // are spaces 12.5 -> 13 px tall (10 logical), the rest of the bar a gap
        let c = range(
            RangeVariant::Schedule,
            RangeSpans {
                done_to: Some(40.0),
                p50: Some(60.0),
                p90: Some(80.0),
                ..RangeSpans::default()
            },
            RangeState::OnTrack,
        );
        let r = &expand_rows(&range_env(1.25, false), "k", &c)[0];
        assert_eq!(
            r.spaces,
            vec![(0, 100, 13), (1, 50, 13), (2, 50, 13), (3, 50, 0)]
        );
        assert_eq!(
            r.runs,
            vec![
                (0, 1, FaceId::KitRangeBar.name().to_owned()),
                (1, 2, FaceId::KitRangeBarForecast.name().to_owned()),
                (2, 3, FaceId::KitRangeBarTail.name().to_owned())
            ]
        );
        assert!(r.props.iter().any(|p| p.2 == "help-echo"));
    }

    #[test]
    fn a_tiny_span_is_two_px() {
        // a span of 1 % of 100 px is 1 px: drawn 2
        let c = Comp::RangeBar {
            variant: RangeVariant::Segment(SegKind::Edit),
            from: 0.0,
            to: 100.0,
            spans: RangeSpans::default(),
            state: RangeState::OnTrack,
            label: String::new(),
            width: 100,
        };
        let tiny = Comp::RangeBar {
            variant: RangeVariant::Cost,
            from: 0.0,
            to: 1000.0,
            spans: RangeSpans {
                p50: Some(1.0),
                ..RangeSpans::default()
            },
            state: RangeState::OnTrack,
            label: String::new(),
            width: 100,
        };
        let r = &expand_rows(&range_env(1.0, false), "k", &tiny)[0];
        assert_eq!(r.spaces[0].1, 2, "{:?}", r.spaces);
        let r = &expand_rows(&range_env(1.0, false), "k", &c)[0];
        assert_eq!(r.spaces, vec![(0, 100, 10)]);
    }

    #[test]
    fn seg_face_is_a_kit_face() {
        for (k, f) in [
            (SegKind::Read, FaceId::KitRangeBarSegRead),
            (SegKind::Think, FaceId::KitRangeBarSegThink),
            (SegKind::WaitMachine, FaceId::KitRangeBarSegWait),
            (SegKind::Stalled, FaceId::KitRangeBarLate),
        ] {
            assert_eq!(k.face(), f);
        }
    }

    #[test]
    fn a_terminal_range_bar_is_cells_and_a_late_one_says_so() {
        // 80 logical px: 10 cells; done to 30 %: 3 cells of █, to p50 (50 %) two of ▓, the tail of ░
        let c = range(
            RangeVariant::Schedule,
            RangeSpans {
                done_to: Some(30.0),
                p50: Some(50.0),
                p90: Some(100.0),
                ..RangeSpans::default()
            },
            RangeState::Late,
        );
        let c = match c {
            Comp::RangeBar {
                variant,
                from,
                to,
                spans,
                state,
                label,
                ..
            } => Comp::RangeBar {
                variant,
                from,
                to,
                spans,
                state,
                label,
                width: 80,
            },
            c => c,
        };
        let r = &expand_rows(&range_env(1.0, true), "k", &c)[0];
        assert_eq!(r.text, "███▓▓░░░░░▌ late");
        let ascii = vec![
            ("bar-full".to_owned(), "#".to_owned()),
            ("range-light".to_owned(), "=".to_owned()),
            ("bar-empty".to_owned(), "-".to_owned()),
            ("range-late".to_owned(), "!".to_owned()),
        ];
        let env = KitEnv {
            glyphs: &ascii,
            ..range_env(1.0, true)
        };
        assert_eq!(expand_rows(&env, "k", &c)[0].text, "###==-----! late");
    }

    #[test]
    fn a_terminal_segment_has_its_letter() {
        let c = Comp::RangeBar {
            variant: RangeVariant::Segment(SegKind::WaitYou),
            from: 0.0,
            to: 10.0,
            spans: RangeSpans::default(),
            state: RangeState::OnTrack,
            label: String::new(),
            width: 32,
        };
        assert_eq!(expand_rows(&range_env(1.0, true), "k", &c)[0].text, "Y███");
        let think = Comp::RangeBar {
            variant: RangeVariant::Segment(SegKind::Think),
            from: 0.0,
            to: 10.0,
            spans: RangeSpans::default(),
            state: RangeState::OnTrack,
            label: String::new(),
            width: 16,
        };
        assert_eq!(
            expand_rows(&range_env(1.0, true), "k", &think)[0].text,
            "·█"
        );
    }

    #[test]
    fn a_time_axis_labels_its_ticks_in_the_zone_and_marks_now() {
        // 2026-11-18 00:00 UTC is 1_794_960_000; the zone +05:30 reads 05:30; ticks every hour for 3 hours at 100 px
        let t0 = 1_794_960_000.0;
        let c = Comp::TimeAxis {
            from: t0,
            to: t0 + 10_800.0,
            step: 3600.0,
            zone: Zone(330),
            now: Some(t0 + 5400.0),
            level: AxisLevel::Hour,
            width: 120,
        };
        let r = &expand_rows(&range_env(1.0, false), "k", &c)[0];
        assert_eq!(r.text, " 05:30 06:30 │ 07:30 08:30");
        assert_eq!(
            r.stops.iter().map(|s| s.1).collect::<Vec<_>>(),
            vec![0, 40, 60, 80, 120]
        );
        assert_eq!(axis_label(t0, Zone(0), AxisLevel::Day), "Wed");
        assert_eq!(axis_label(t0, Zone(0), AxisLevel::Week), "Nov 18");
    }

    #[test]
    fn the_now_line_is_a_one_px_focus_stop() {
        let c = Comp::NowStop {
            at: 25.0,
            from: 0.0,
            to: 100.0,
            width: 200,
        };
        let r = &expand_rows(&range_env(2.0, false), "k", &c)[0];
        assert_eq!(r.stops, vec![(0, 100)]);
        assert_eq!(r.spaces, vec![(1, 2, 0)]);
        assert_eq!(r.runs, vec![(1, 2, FaceId::Focus.name().to_owned())]);
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
                    ascii: false,
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
            ascii: false,
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
