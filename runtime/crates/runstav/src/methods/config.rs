//! The editor's runtime settings (unified-settings design §11.1; docs/develop/hub.md, "Settings"):
//!
//! - `config/settings`: the values of the runtime settings the editor holds (its Lisp's, a workspace's), per project
//!   or global.  The hub keeps each set as the last good one and, with `settings.el`, works out what is in effect.
//!   It replaces `config/providers` (the provider table is now the settings').
//! - `config/changed`: `settings.el` may have changed; the hub looks at its stamp now.

use super::tasks::ProjectName;
use super::{Empty, method};
use crate::registry::Method;
use crate::types::Bounded;
use crate::wire::{Error, ErrorCode};
use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::borrow::Cow;

const MAX_VALUE_BYTES: usize = 65536;

fn check_settings(p: &SettingsParams) -> Result<(), Error> {
    for (i, o) in p.overrides.iter().enumerate() {
        if o.value.0.to_string().len() > MAX_VALUE_BYTES {
            return Err(Error {
                code: ErrorCode::InvalidParams,
                message: "a value is at most 64 KiB as JSON".into(),
                path: Some(format!("overrides[{i}].value")),
            });
        }
    }
    Ok(())
}

/// A runtime setting's value: JSON of its runtime type, at most 64 KiB as JSON (the hub checks it against the type).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(transparent)]
pub struct SettingValue(pub Value);

impl JsonSchema for SettingValue {
    fn schema_name() -> Cow<'static, str> {
        "SettingValue".into()
    }
    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": ["object", "array", "string", "number", "boolean", "null"],
                      "description": "JSON of the setting's runtime type (an alist is an object): at most 64 KiB (65536 bytes as JSON)"})
    }
}

/// One runtime setting's value.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SettingOverride {
    /// A runtime setting's name (`drgnx-ai-providers`, …); another name is refused.
    pub name: Bounded<String, 128>,
    /// The value as JSON of the setting's runtime type (an alist is an object, a plist an object).
    pub value: SettingValue,
    /// Where it comes from (a file, `lisp:<file>`, a workspace).
    pub source: Bounded<String, 256>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SettingsParams {
    /// The project these values are for; none for the global ones.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<ProjectName>,
    /// The whole set for that project (it replaces the one before; an empty list clears it).
    pub overrides: Bounded<Vec<SettingOverride>, 64>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SettingsApplied {
    pub applied: u64,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "config/settings", ConfigSettings(SettingsParams) -> SettingsApplied,
            classes: [User], writes: false, home: Front,
            doc: "the editor's runtime settings values per project (or global), each set kept as last good; a bad value is refused with its path; replaces config/providers",
            check: check_settings,
        ),
        method!(
            "config/changed", ConfigChanged(Empty) -> bool,
            classes: [User], writes: false, home: Front,
            doc: "settings.el may have changed: its stamp is checked now",
        ),
    ]
}
