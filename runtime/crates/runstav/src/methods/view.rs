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

pub use drgnx_rows::{
    Colour, CursorShape, ImageId, Op, Patch, Row, RowHeight, Style, StyleId, TermMeta,
};

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
    /// The first env of a new buffer for this (view, class): a pair the hub already holds for the connection (no
    /// `view/close` came) is dropped and starts again, so the new buffer gets the rows whole.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub attach: bool,
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

/// `view/glyphs`: the editor's answer to `view-glyphs`, `[role, char, px]` each.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ViewGlyphs {
    pub view: String,
    pub class: String,
    pub glyphs: Vec<(String, String, f32)>,
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

/// `view-glyphs`: the hub asks the editor for advances it cannot read from the font, `[role, char]` each.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ViewGlyphsAsk {
    pub view: String,
    pub class: String,
    pub ask: Vec<(String, String)>,
}

fn check_ids(view: &str, class: Option<&str>) -> Result<(), Error> {
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
        method!(
            "view/glyphs", ViewGlyphs(ViewGlyphs) -> bool,
            classes: [User], writes: false,
            doc: "the editor's advances for the glyphs a view-glyphs asked for, [role, char, px] each",
            check: |p: &ViewGlyphs| check_ids(&p.view, Some(&p.class)),
        ),
        method!(
            "view/measured", ViewMeasured(ViewMeasured) -> bool,
            classes: [User], writes: false,
            doc: "the fit guard's measurements of strings that overflowed, [role, string, px] each: the hub fits by them",
            check: |p: &ViewMeasured| check_ids(&p.view, Some(&p.class)),
        ),
        method!(
            "view/window", ViewWindow(ViewWindow) -> bool,
            classes: [User], writes: false,
            doc: "the editor's replica needs another window of a list of a view's model, from a position in the whole list: the view's builder sends the model with that window",
            check: |p: &ViewWindow| {
                check_ids(&p.view, None)?;
                if p.list.is_empty() || p.list.len() > VIEW_MAX {
                    return Err(invalid("list", "a list name of 1 to 64 bytes"));
                }
                Ok(())
            },
        ),
        method!(
            "view/close", ViewClose(ViewClose) -> bool,
            classes: [User], writes: false,
            doc: "the editor shows a view no more: its envs and rows are forgotten (a connection's views end with it)",
            check: |p: &ViewClose| check_ids(&p.view, None),
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
