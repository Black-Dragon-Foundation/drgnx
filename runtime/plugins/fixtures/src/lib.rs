//! The `drgnx:agent-tools` bindings, shared by the fixtures. Each binary implements `ability::Guest` and
//! `hook::Guest` on a type of its own and exports it with `plugin_fixtures::export!`.

wit_bindgen::generate!({
    path: "../../crates/brokkr/wit",
    world: "drgnx:agent-tools/plugin",
    pub_export_macro: true,
    default_bindings_module: "plugin_fixtures",
});

pub mod prelude {
    pub use super::drgnx::agent_tools::host;
    pub use super::drgnx::agent_tools::types::{Header, Level, Point, Verdict};
    pub use super::exports::drgnx::agent_tools::{ability, hook};
}

/// The answer of a fixture that has no abilities (the world has both interfaces).
pub fn no_ability(tool: &str) -> Result<String, String> {
    Err(format!("no ability {tool}"))
}

/// The answer of a fixture that has no hook.
pub fn no_hook() -> Result<prelude::Verdict, String> {
    Ok(prelude::Verdict::Allow)
}

/// An argument of a call, from the JSON the host passed.
pub fn arg(args_json: &str, key: &str) -> Option<serde_json::Value> {
    serde_json::from_str::<serde_json::Value>(args_json)
        .ok()?
        .get(key)
        .cloned()
}
