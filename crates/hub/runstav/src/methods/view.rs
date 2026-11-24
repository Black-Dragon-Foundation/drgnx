//! Hub-built rows (docs/develop/hub.md, "Rows"): the editor tells the hub how one view looks in one display class
//! (`view/env`), the hub sends that (view, class) its rows as patches (the event `view-patch`), and the editor asks
//! for a whole set again when a patch does not fit what it holds (`view/resync`). Glyphs the hub cannot measure are
//! asked of the editor (the event `view-glyphs`, answered by `view/glyphs`); the editor's fit guard reports what it
//! measured (`view/measured`). A view that asked for acknowledged patches says `view/ack` after it applied one; the
//! hub then sends that (view, class) at most one patch it has not acknowledged. Ids are in arrays, never object keys.

use super::{invalid, method};
use crate::registry::Method;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

pub use rodd::{Colour, CursorShape, ImageId, Op, Patch, Row, RowHeight, Style, StyleId, TermMeta};

/// The longest view id, in bytes.
pub const VIEW_MAX: usize = 64;
/// The longest display class name, in bytes.
pub const CLASS_MAX: usize = 64;
/// The most fonts, palette roles, glyphs or measurements one message carries.
pub const LIST_MAX: usize = 4096;

/// A display's kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Display {
    Gui,
    Tty,
}

/// One font role: `[role, file, index, px, ascent, descent, avg, space]`. FILE is the font file Emacs uses (none
/// when it names none: the hub then measures through the editor), INDEX the face in a collection, the rest in px.
pub type FontFact = (String, Option<String>, u32, f32, f32, f32, f32, f32);

/// The Explorer's who-is-here badge (`view/env`'s `badge`): `((file_each, file_limit), (folder_each, folder_limit),
/// more)`, px (a terminal's: columns).
pub type Badge = ((u32, u32), (u32, u32), u32);

/// `view/env`: how VIEW looks in display class CLASS, measured in the view's buffer. EPOCH is the editor's number for
/// this env (the hub echoes it on every patch); a new epoch makes the next patch a reset.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ViewEnv {
    pub view: String,
    pub class: String,
    pub epoch: u64,
    pub display: Display,
    pub scale: f32,
    #[serde(default)]
    pub fonts: Vec<FontFact>,
    /// The frame's character cell, `[width, height]` px.
    pub cell: (u32, u32),
    /// The narrowest live window of the class showing the view, body px.
    pub width_px: u32,
    /// Where the editor draws a row's tail after its text (`drgnx-wb-row-tail`: the Explorer's, the Buffers panel's),
    /// `[mark, control]` px (a terminal's: columns) from the window's right edge: the start of its git mark and of its
    /// control. The rows a view gives a tail keep their text short of what it always draws
    /// (`rodd::fit_row::Room::tail`). None: the view's rows get no tail.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tail: Option<(u32, u32)>,
    /// What the editor draws right after a row's name, before its tail: the Explorer's who-is-here badge
    /// (`drgnx-explorer-badge-functions`), as `[[file_each, file_limit], [folder_each, folder_limit], more]` px (a
    /// terminal's: columns): each agent shown takes EACH (a space and its mark, a file's with its initial), up to LIMIT
    /// shown, and MORE for the `+N` of the rest. A row with agents here ends its name that much shorter. None: no badge.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub badge: Option<Badge>,
    /// `[role, colour]`: the SVG writer's colours, from the theme.
    #[serde(default)]
    pub palette: Vec<(String, String)>,
    /// `[from, to, width]`: the terminal's character widths that differ from Unicode's.
    #[serde(default)]
    pub tty_widths: Vec<(u32, u32, u8)>,
    /// The editor's offset from UTC, `+HHMM` as `%z` prints it (the trail's times); anything else is UTC.
    #[serde(default)]
    pub tz: String,
    #[serde(default)]
    pub reduced_motion: bool,
    /// The theme is a high-contrast one (`drgnx-look-variant` `hc`): the Timeline writes segment kinds' letters and
    /// draws bars' tails as outlines.
    #[serde(default)]
    pub hc: bool,
    /// `[name, glyph]`: the kit's glyphs (those `etc/ui/components.eld` names) as `drgnx-face-glyph` draws them on the
    /// class's frame, ASCII on a terminal that is not UTF-8; a name missing here is drawn in its Unicode form
    /// (`rodd::kit`).
    #[serde(default)]
    pub glyphs: Vec<(String, String)>,
    /// The class's frame is a terminal that is not UTF-8 (`drgnx-ui-ascii-frame-p`): a glyph the hub takes from its own
    /// table (a tab's icon, `rodd::kit::ALL_GLYPHS`) is drawn in its ASCII form.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub ascii: bool,
    /// The user's density (`drgnx-look-density`): the kit's sizes that follow it (a tree level's indent). None:
    /// comfortable. A change is a new epoch, as a scale change is.
    #[serde(default)]
    pub density: rodd::kit::Density,
    /// The first env of a new buffer for this (view, class): a pair the hub already holds for the connection (no
    /// `view/close` came) is dropped and starts again, so the new buffer gets the rows whole.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub attach: bool,
    /// The editor holds this view's rows in Sjá: its patches come as a `view-model` line's `rows` (`{view, rows}`),
    /// which Sjá takes whole, for any view (a terminal's from `term/open` and `term/attach` too).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub rows_in_sja: bool,
    /// The view is in no window: its rows are read, never drawn (the git letters), so the hub does not fit them to
    /// `width_px`, the selected window's.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub headless: bool,
}

impl ViewEnv {
    /// What the kit's expansion reads of this env (`rodd::kit`): its scale, whether it is a terminal, its
    /// glyphs and the density; no icons (a view that draws them builds its own).
    pub fn kit(&self) -> rodd::kit::KitEnv<'_> {
        rodd::kit::KitEnv {
            scale: self.scale,
            tty: self.display == Display::Tty,
            glyphs: &self.glyphs,
            ascii: self.ascii,
            density: self.density,
            icons: None,
        }
    }
}

/// `view/resync`: the editor's rows of (VIEW, CLASS) are not what the hub thinks (a patch's base it does not hold, an
/// image it lacks); VERSION is what it holds. The answer is a `reset`. With MODEL, it is VIEW's model the editor's
/// replica cannot take (a gap, a hub it has no reset from): the answer is a `view-model` reset, and CLASS is not read.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ViewResync {
    pub view: String,
    #[serde(default)]
    pub class: String,
    #[serde(default)]
    pub version: u64,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub model: bool,
}

/// `view-model`: what changed in one view's model (the editor's replica, docs/develop/hub.md "The native view
/// model"), from version BASE to VERSION. MODEL is a JSON object, `{"ops": [...]}`; the editor hands the whole line,
/// unparsed, to its replica (Sjá), which reads the envelope and the model (the line starts `{"event":"view-model"`:
/// [`crate::wire::Event`] writes `event` first). Its first op after a subscribe, a hidden view shown again, a hub
/// restart or a `view/resync` with `model` is a `reset`. The view's rows built from it follow it, each `view-patch`
/// naming it (`model`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ViewModel {
    pub view: String,
    /// The hub's instance id, as on `view-patch`.
    pub hub: u64,
    /// The version this patch applies to: 0 for the first model of a subscription.
    pub base: u64,
    pub version: u64,
    /// MODEL starts with a `reset`: the replica decides by the envelope.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub reset: bool,
    /// `{"ops": [...]}`.
    pub model: serde_json::Value,
}

/// `view/ack`: the editor applied (VIEW, CLASS)'s patch VERSION. For a view whose patches are acknowledged (a
/// terminal's), the hub holds the next patch until this; a reconnect or a `view/resync` clears what it waits for.
/// Other views may send it or not.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ViewAck {
    pub view: String,
    pub class: String,
    pub version: u64,
}

/// `view/glyphs`: the editor's answer to `view-glyphs`, `[role, char, px]` each, and the faces it asked about.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ViewGlyphs {
    pub view: String,
    pub class: String,
    pub glyphs: Vec<(String, String, f32)>,
    #[serde(default)]
    pub faces: Vec<ViewFace>,
}

/// How FACE draws in the view's buffer: in ROLE's font (one of the env's roles whose font it is; else FACE itself, a
/// role of its own, with its font FILE, INDEX, PX, AVG and weight WGHT, as the env's `fonts` say them), its box adding
/// PAD px at each end of a run.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ViewFace {
    pub face: String,
    pub role: String,
    #[serde(default)]
    pub pad: f32,
    #[serde(default)]
    pub file: Option<String>,
    #[serde(default)]
    pub index: u32,
    #[serde(default)]
    pub px: f32,
    #[serde(default)]
    pub avg: f32,
    #[serde(default)]
    pub wght: Option<f32>,
}

/// `view/measured`: the fit guard measured these strings wider than the hub fitted them, `[role, string, px]` each.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ViewMeasured {
    pub view: String,
    pub class: String,
    pub measured: Vec<(String, String, f32)>,
}

/// `view/close`: the editor shows VIEW no more; the hub forgets its envs and rows.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ViewClose {
    pub view: String,
}

/// `view/window`: the editor's replica of VIEW's model needs another window of list LIST, starting at FROM (a
/// position in the whole list; the hub clamps it). The view's builder sends the model with that window, whole
/// (docs/develop/core.md, "Views": windows); the answer is false when no builder holds such a list.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ViewWindow {
    pub view: String,
    pub list: String,
    pub from: u64,
}

/// `view-glyphs`: the hub asks the editor for advances it cannot read from the font, `[role, char]` each, and how
/// the FACES its rows name draw (answered by `view/glyphs`' `faces`), and to MEASURE strings as drawn, `[key, text,
/// runs]` each, the runs `[start, end, face]` over the text's chars, an earlier above a later (answered by
/// `view/measured`, `[key, text, px]`): a row segment whose sum came too close to its end to decide.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ViewGlyphsAsk {
    pub view: String,
    pub class: String,
    pub ask: Vec<(String, String)>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub faces: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub measure: Vec<MeasureAsk>,
}

/// A string `view-glyphs` asks the editor to measure: its key, its text, its runs `[start, end, face]`.
pub type MeasureAsk = (String, String, Vec<(u32, u32, String)>);

pub(crate) fn check_ids(view: &str, class: Option<&str>) -> Result<(), Error> {
    if view.is_empty() || view.len() > VIEW_MAX {
        return Err(invalid("view", "a view id of 1 to 64 bytes"));
    }
    if class.is_some_and(|c| c.is_empty() || c.len() > CLASS_MAX) {
        return Err(invalid("class", "a display class of 1 to 64 bytes"));
    }
    Ok(())
}

fn check_env(p: &ViewEnv) -> Result<(), Error> {
    check_ids(&p.view, Some(&p.class))?;
    if p.fonts.len() > LIST_MAX || p.palette.len() > LIST_MAX || p.tty_widths.len() > LIST_MAX {
        return Err(invalid(
            "fonts",
            "at most 4096 fonts, palette roles or widths",
        ));
    }
    if !(p.scale.is_finite() && p.scale > 0.0) {
        return Err(invalid("scale", "a scale above 0"));
    }
    Ok(())
}

/// The most changes one `buffers/set` carries (a reset and thousands of open buffers fit).
pub const BUFFER_OPS_MAX: usize = 50_000;

/// `buffers/set`: changes to the Buffers panel's open buffers for the hub-fed VIEW, in order; the hub sends VIEW's
/// rows that changed to every class of it (docs/develop/hub.md, "Rows"). The editor sends one when the set of open
/// buffers, a name or an unsaved flag changed, or the window's scope or the filter did, never per keystroke.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BuffersSet {
    pub view: String,
    pub ops: Vec<BufferOp>,
}

/// One change of `buffers/set`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(tag = "op", rename_all = "lowercase", deny_unknown_fields)]
pub enum BufferOp {
    /// No buffer is open (the editor puts its set again after it, in open order: a new hub, a reconnect).
    Reset,
    /// Buffer ID (the editor's, at most 64 bytes) is open with NAME, visiting FILE (none: no file, such as a folder's
    /// listing), MODIFIED when it has unsaved changes: a new id goes last in the open order, a known one keeps its place.
    Put {
        id: String,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        file: Option<String>,
        #[serde(default)]
        modified: bool,
    },
    /// Buffer ID's unsaved flag flipped.
    Modified { id: String, modified: bool },
    /// Buffer ID was closed.
    Remove { id: String },
    /// Only the buffers IDS are on rows (those of the window the user works in), in the open order; none: every one.
    Scope {
        #[serde(default)]
        ids: Option<Vec<String>>,
    },
    /// Only the buffers whose names hold TEXT (any case) are on rows; none or empty: every one.
    Filter {
        #[serde(default)]
        text: Option<String>,
    },
}

/// The longest file name `outline/set` takes, in bytes.
pub const OUTLINE_FILE_MAX: usize = 4096;

/// `outline/set`: the Outline panel's hub-fed VIEW now shows FILE (absolute; none: the editor shows no file the hub
/// can read, such as a buffer without one or a remote file).  The hub outlines the file as the editor's tracked buffer
/// of it has it (unsaved typing included), else as it is on disk, keeps it per (connection, view), outlines it again
/// after the editor's edits pause, and sends the view's model and rows (docs/develop/hub.md, "The Outline panel's
/// rows").  Sent again when the editor shows another file or saves this one, never per keystroke.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct OutlineSet {
    pub view: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    /// The lines (from 1) where the editor has a folded range start: the definitions starting there are marked folded.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub folded: Vec<u32>,
}

/// The most folded lines `outline/set` takes.
pub const OUTLINE_FOLDED_MAX: usize = 65536;

/// `outline/scopes`: the definitions around LINE (from 1) of a file, as the Outline reads it (the editor's unsaved text
/// where its edit history tracks the buffer, else the disk): what the breadcrumb's symbol and sticky scroll show.  The
/// file is FILE (absolute), or PATH under WORKTREE_ROOT (the edit history's names: a tracked buffer asks through the
/// history, its changes handed over first).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct OutlineScopesParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_root: Option<String>,
    pub line: u32,
}

/// One definition around a line: its NAME and the LINE (from 1) it starts on.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct OutlineScope {
    pub name: String,
    pub line: u32,
}

/// `outline/scopes`' answer: the definitions that hold the line, outermost first (one that starts on it included);
/// empty for a file with none, one that cannot be read, or one past the Outline's size limit.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct OutlineScopes {
    pub scopes: Vec<OutlineScope>,
}

/// `minimap/watch`: the editor shows FILE (absolute) in a minimap (ON), or no longer (not ON).  While a connection
/// watches it, the hub sends the file's minimap labels (its definitions as the Outline reads them, up to
/// `MINIMAP_LABELS_MAX` bytes of text) on the model's raw path (`view-model` with `minimap`, docs/develop/hub.md,
/// "The minimap's layers"), at once and again after the editor's edits to it pause; never per keystroke.  With HEAT
/// it also sends that heat layer (`heat:HEAT`), and removes the one an earlier watch asked for.  With DENSITY (a file
/// past the density limit, design M7) it scans the file on disk instead and sends its `density` layer in parts.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MinimapWatch {
    pub file: String,
    pub on: bool,
    /// The heat layer shown: `blame`, `coverage`, `profile` or `agent-read`; none: no heat.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub heat: Option<String>,
    /// Where coverage reports are, relative to the file's worktree (`*` and `?` match in the last part): the newest
    /// that names the file is read, and read again when it changes.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub coverage: Vec<String>,
    /// The profile the heat layer `profile` reads (absolute): pprof, `perf script` text or speedscope.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    /// The file is past the density limit: scan it on disk for the density strip (no labels, folds or heat).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub density: Option<MinimapDensity>,
}

/// What a density scan counts: the lines matching ERROR and those matching WARNING, Rust `regex` syntax each (at most
/// 1024 bytes).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MinimapDensity {
    pub error: String,
    pub warning: String,
}

/// `minimap/bucket`: the first LINES (1 to 40) lines of a density bucket of FILE (its index, from 0, of the scan's
/// buckets): the bucket peek.  Read from disk; no buffer is touched.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MinimapBucketParams {
    pub file: String,
    pub bucket: u32,
    pub lines: u32,
}

/// The bucket's first lines (invalid UTF-8 replaced, each cut at 400 bytes), the byte offset of the first and the
/// buckets the file has.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MinimapBucket {
    pub text: String,
    pub start: u64,
    pub buckets: u32,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "view/env", ViewEnv(ViewEnv) -> bool,
            classes: [User], writes: false,
            doc: "how one view looks in one display class (fonts, scale, width, palette), with the editor's epoch: a new epoch makes the next view-patch a reset",
            check: check_env,
        ),
        method!(
            "view/resync", ViewResync(ViewResync) -> bool,
            classes: [User], writes: false,
            doc: "the editor's rows of a (view, class) are not the hub's: answered by a view-patch reset; with model, its replica of the view's model is not: answered by a view-model reset",
            check: |p: &ViewResync| check_ids(&p.view, (!p.model).then_some(p.class.as_str())),
        ),
        method!(
            "view/ack", ViewAck(ViewAck) -> bool,
            classes: [User], writes: false,
            doc: "the editor applied a (view, class)'s patch of this version: an acknowledged view's next patch may go",
            check: |p: &ViewAck| check_ids(&p.view, Some(&p.class)),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    /// A `view-model` line starts with `{"event":"view-model"` (the editor routes it to Sjá by that prefix, unparsed)
    /// and carries its model as a JSON object, not a string.
    #[test]
    fn a_view_model_line_starts_with_its_event_and_carries_an_object() {
        let m = super::ViewModel {
            view: "v".into(),
            hub: 1,
            base: 0,
            version: 1,
            reset: true,
            model: json!({"ops": []}),
        };
        let line = serde_json::to_string(&crate::wire::Event {
            event: "view-model".into(),
            data: json!(m),
        })
        .unwrap();
        assert!(line.starts_with(r#"{"event":"view-model""#), "{line}");
        let v: Value = serde_json::from_str(&line).unwrap();
        assert!(v["data"]["model"].is_object(), "{line}");
    }

    /// A schema that is a map: an object whose keys are data (ids), not field names.
    fn maps(v: &Value, at: &str, out: &mut Vec<String>) {
        match v {
            Value::Object(m) => {
                let map = m.contains_key("patternProperties")
                    || m.get("additionalProperties")
                        .is_some_and(|a| !matches!(a, Value::Bool(false)))
                        && !m.contains_key("properties");
                if map {
                    out.push(at.to_owned());
                }
                for (k, x) in m {
                    maps(x, &format!("{at}/{k}"), out);
                }
            }
            Value::Array(a) => a
                .iter()
                .enumerate()
                .for_each(|(i, x)| maps(x, &format!("{at}/{i}"), out)),
            _ => {}
        }
    }

    /// The hub-built rows' methods and events carry ids in arrays, never as object keys.
    #[test]
    fn view_protocol_uses_no_ids_as_object_keys() {
        let methods: Vec<_> = crate::registry::registry()
            .iter()
            .filter(|m| m.name.starts_with("view/"))
            .collect();
        assert_eq!(
            methods.len(),
            7,
            "the view/ methods: {:?}",
            methods.iter().map(|m| m.name).collect::<Vec<_>>()
        );
        let mut found = Vec::new();
        for m in methods {
            maps(
                &serde_json::to_value((m.params)()).unwrap(),
                &format!("{} params", m.name),
                &mut found,
            );
            maps(
                &serde_json::to_value((m.result)()).unwrap(),
                &format!("{} result", m.name),
                &mut found,
            );
        }
        for e in ["view-patch", "view-glyphs", "view-model"] {
            let t = crate::events::event(e).unwrap_or_else(|| panic!("no event {e}"));
            maps(&serde_json::to_value((t.data)()).unwrap(), e, &mut found);
        }
        assert!(found.is_empty(), "maps (ids as keys) at {found:?}");
    }

    /// Every method and event: none carries ids as object keys, but the places listed here, which wait (each a
    /// DEFERRED row: a consumer that is frozen code, or a wire another plan owns).
    #[test]
    fn no_method_or_event_uses_ids_as_object_keys() {
        const WAITING: &[&str] = &[
            // the stored event's own JSON object: a payload, not ids as keys
            "events/since result/$defs/EventRow/properties/data",
            "events/$defs/EventRow/properties/data",
            // keys by provider and by key name: the agent system's gateway and runners wires
            "gateway/keys params/$defs/ProviderKeys",
            "gateway/register params/$defs/ProviderKeys",
            "runners/keys params/$defs/RunnerKeys",
            // cost by unit name: the history wire
            "history/revert/preview result/$defs/Spent/properties/cost_by_unit",
        ];
        let mut found = Vec::new();
        for m in crate::registry::registry() {
            maps(
                &serde_json::to_value((m.params)()).unwrap(),
                &format!("{} params", m.name),
                &mut found,
            );
            maps(
                &serde_json::to_value((m.result)()).unwrap(),
                &format!("{} result", m.name),
                &mut found,
            );
        }
        for e in crate::events::events() {
            maps(
                &serde_json::to_value((e.data)()).unwrap(),
                e.name,
                &mut found,
            );
        }
        let new: Vec<&String> = found
            .iter()
            .filter(|f| !WAITING.iter().any(|w| f.starts_with(w)))
            .collect();
        assert!(new.is_empty(), "maps (ids as keys) at {new:#?}");
    }
}
