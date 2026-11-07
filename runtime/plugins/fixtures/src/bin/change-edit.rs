//! An `after-edit` hook that changes the written content: it appends a `// checked` line.

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
        let content = input["edit"]["content"].as_str().unwrap_or("");
        let changed = serde_json::json!({ "content": format!("{content}// checked\n") });
        Ok(Verdict::Change(changed.to_string()))
    }
}

plugin_fixtures::export!(C with_types_in plugin_fixtures);
