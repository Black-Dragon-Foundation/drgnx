//! A minimal drgnx plugin.
//!
//! A plugin is a WebAssembly component of the `drgnx:agent-tools/plugin` world. It exports two interfaces:
//!
//! - `ability`: the tools it gives agents. The host calls `call` with an ability's name (as `plugin.json` declares
//!   it) and the arguments as a JSON object, and the plugin answers with a JSON result or an error text.
//! - `hook`: what it says about a step at a point (`before-tool`, `after-edit`, `before-commit`, `at-review`).
//!   The host calls `run` with the point and the event as JSON, and the plugin answers with a verdict: `allow`,
//!   `deny(reason)`, `change(replacement)` or `annotate(note)`. A verdict can only narrow what the user's
//!   permissions allow; an `allow` means "no objection".
//!
//! A plugin reaches nothing else: no files, no sockets, no environment. It may call `host::http_get` and
//! `host::http_post` for the hosts its manifest names, and use its own small key-value store (`host::kv_*`).
//!
//! Point `path` at the WIT directory (`runtime/crates/brokkr/wit` in the drgnx sources; copy it next to your plugin
//! when you build outside the repository).

wit_bindgen::generate!({
    path: "../../crates/brokkr/wit",
    world: "drgnx:agent-tools/plugin",
});

use exports::drgnx::agent_tools::{ability, hook};
use drgnx::agent_tools::types::{Point, Verdict};

struct MyPlugin;

impl ability::Guest for MyPlugin {
    fn call(tool: String, args_json: String) -> Result<String, String> {
        match tool.as_str() {
            "shout" => {
                let args: serde_json::Value = serde_json::from_str(&args_json).map_err(|e| e.to_string())?;
                let text = args["text"].as_str().ok_or("`text` must be a string")?;
                Ok(serde_json::json!({ "text": text.to_uppercase() }).to_string())
            }
            other => Err(format!("no ability {other}")),
        }
    }
}

impl hook::Guest for MyPlugin {
    fn run(point: Point, input_json: String) -> Result<Verdict, String> {
        if !matches!(point, Point::BeforeTool) {
            return Ok(Verdict::Allow);
        }
        let input: serde_json::Value = serde_json::from_str(&input_json).map_err(|e| e.to_string())?;
        let command = input["tool"]["command"].as_str().unwrap_or("");
        if command.contains("rm -rf /") {
            Ok(Verdict::Deny("this plugin refuses `rm -rf /`".to_string()))
        } else {
            Ok(Verdict::Allow)
        }
    }
}

export!(MyPlugin);
