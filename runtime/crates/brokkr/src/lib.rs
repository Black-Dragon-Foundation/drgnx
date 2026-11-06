//! brokkr: the plugin host (docs/develop/plugins.md).
//!
//! - [`manifest`]: `plugin.json`, parsed and checked as data, and the hash a user approves.
//! - [`store`]: the installed plugins on disk, read through `eitri`, never following a link.
//!
//! `wit/agent-tools.wit` is the interface a plugin component implements. Nothing here runs a plugin.

pub mod manifest;
pub mod store;

pub use manifest::{
    AbilityDecl, Filter, HookDecl, HostName, Manifest, ManifestError, PluginName, Point, ToolName,
    VerdictKind, parse, plugin_hash,
};
pub use store::{Installed, scan};
