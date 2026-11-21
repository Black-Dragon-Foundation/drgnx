//! An `after-edit` hook that annotates every edit with its path.

#![no_main]

use plugin_fixtures::prelude::*;

struct C;

impl ability::Guest for C {
    fn call(tool: String, _args_json: String) -> Result<String, String> {
        plugin_fixtures::no_ability(&tool)
    }
}

impl hook::Guest for C {
    fn run(_point: Point, input_json: String) -> Result<Verdict, String> {
        let input: serde_json::Value = serde_json::from_str(&input_json).map_err(|e| e.to_string())?;
        let path = input["edit"]["path"].as_str().unwrap_or("?");
        Ok(Verdict::Annotate(format!("edited {path}")))
    }
}

plugin_fixtures::export!(C with_types_in plugin_fixtures);
