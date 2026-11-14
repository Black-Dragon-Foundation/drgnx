//! An `after-edit` hook that denies an edit of a `.lock` file.

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
        let path = input["edit"]["path"].as_str().unwrap_or("");
        if path.ends_with(".lock") {
            Ok(Verdict::Deny("lock files are generated".to_string()))
        } else {
            Ok(Verdict::Allow)
        }
    }
}

plugin_fixtures::export!(C with_types_in plugin_fixtures);
