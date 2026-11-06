//! brokkr: the plugin host (docs/develop/plugins.md).
//!
//! - [`manifest`]: `plugin.json`, parsed and checked as data, and the hash a user approves.
//! - [`store`]: the installed plugins on disk, read through `eitri`, never following a link.
//! - [`host`]: the WASM host. It loads an approved plugin and runs its abilities and hooks on a runtime of its own,
//!   each call in a fresh instance under [`Limits`], reaching nothing but what [`HostIo`] gives it.
//!
//! `wit/agent-tools.wit` is the interface a plugin component implements.

mod guest;
pub mod host;
mod imports;
pub mod limits;
pub mod manifest;
pub mod schema;
pub mod store;
#[cfg(any(test, feature = "test-support"))]
pub mod test_support;

pub use host::{CallError, Host, HostError, Plugin, Verdict};
pub use imports::{
    BoxFuture, HostIo, HttpReq, HttpResp, Kv, Level, Method, PROVIDED, REFUSED_HEADERS,
};
pub use limits::Limits;
pub use manifest::{
    AbilityDecl, Filter, HookDecl, HostName, Manifest, ManifestError, PluginName, Point,
    TOOL_KINDS, ToolName, VerdictKind, parse, plugin_hash,
};
pub use schema::SchemaError;
pub use store::{Installed, scan};
