//! A `before-tool` hook that changes the arguments of the hub tool call it sees to `{"changed": true}`.

#![no_main]

use plugin_fixtures::prelude::*;

struct C;

impl ability::Guest for C {
    fn call(tool: String, _args_json: String) -> Result<String, String> {
        plugin_fixtures::no_ability(&tool)
    }
}

impl hook::Guest for C {
    fn run(_point: Point, _input_json: String) -> Result<Verdict, String> {
        let changed = serde_json::json!({ "arguments": { "changed": true } });
        Ok(Verdict::Change(changed.to_string()))
    }
}

plugin_fixtures::export!(C with_types_in plugin_fixtures);
