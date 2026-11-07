//! The plugins' methods (`docs/guide/plugins.md`, `docs/develop/plugins.md`): which plugins are installed, what each one
//! reaches, and the user's approval of exactly the files they were shown.  Every method is the user's: no agent, and no
//! manager tool, approves or disables a plugin.  Installing is the CLI's (`ratatoskr plugins install PATH`), which copies
//! a folder into the hub's data folder; the hub looks at that folder at every `plugins/list`.  The event `plugin` says
//! that one plugin's state changed.

use super::{Empty, method};
use crate::registry::Method;
use crate::types::{Bounded, Hex64, null_as_empty};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// Where a plugin stands.  Only `approved` runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum PluginState {
    /// Installed, never approved.
    Unapproved,
    /// Approved at the hash on disk now.
    Approved,
    /// The files on disk are not the ones that were approved.
    Changed,
    /// Switched off by the user.
    Disabled,
    /// The manifest does not read; `problem` says why.
    Broken,
}

/// What one hook of a plugin may see and say: the manifest's declaration, as written.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HookReach {
    /// `before-tool`, `after-edit`, `before-commit` or `at-review`.
    pub point: String,
    /// `allow`, `deny`, `change` and `annotate`, those the hook may return.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub verdicts: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub tool_kinds: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub tools: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub paths: Vec<String>,
}

/// Everything a manifest lets a plugin do.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Reach {
    /// The abilities' names (the tools it offers).
    #[serde(default, deserialize_with = "null_as_empty")]
    pub abilities: Vec<String>,
    /// The hosts it may reach over https, `host:port`.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub hosts: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub hooks: Vec<HookReach>,
}

/// One installed plugin.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PluginRow {
    pub name: String,
    /// The manifest's version; none when the manifest does not read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// SHA-256 over the manifest and the component on disk now (the hash `plugins/approve` takes); none when they
    /// cannot be read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hash: Option<Hex64>,
    pub state: PluginState,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub abilities: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub hooks: Vec<HookReach>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub hosts: Vec<String>,
    /// The bytes its key-value store may hold.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kv_bytes: Option<u32>,
    /// With `state` `changed`: the reach the user approved, in the shape of the current entry's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_reach: Option<Reach>,
    /// With `state` `broken`: why.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub problem: Option<String>,
}

/// `plugins/list`'s answer.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PluginList {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub plugins: Vec<PluginRow>,
}

/// `plugins/approve`'s params: the plugin and the hash the user was shown.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ApproveParams {
    pub name: Bounded<String, 32>,
    /// The hash `plugins/list` gave and the editor displayed; a plugin whose files are not these any more is refused.
    pub hash: Hex64,
}

/// `plugins/disable`'s params.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DisableParams {
    pub name: Bounded<String, 32>,
}

/// The event `plugin`: a plugin's state changed.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PluginChanged {
    pub name: String,
    /// A [`PluginState`], or `removed` when its folder is gone.
    pub state: String,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "plugins/list", PluginsList(Empty) -> PluginList,
            classes: [User], writes: false,
            doc: "the installed plugins (the folder is read again): state, hash, what each reaches, and for a changed one the reach that was approved",
        ),
        method!(
            "plugins/approve", PluginsApprove(ApproveParams) -> PluginRow,
            classes: [User], writes: true,
            doc: "approve the plugin whose files hash to hash (the hash the user was shown; a stale one is refused); only the user does",
        ),
        method!(
            "plugins/disable", PluginsDisable(DisableParams) -> PluginRow,
            classes: [User], writes: true,
            doc: "switch a plugin off until the user approves it again",
        ),
    ]
}
