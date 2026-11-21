//! One ability, `echo`: the arguments come back unchanged.

#![no_main]

use plugin_fixtures::prelude::*;

struct C;

impl ability::Guest for C {
    fn call(_tool: String, args_json: String) -> Result<String, String> {
        Ok(args_json)
    }
}

impl hook::Guest for C {
    fn run(_point: Point, _input_json: String) -> Result<Verdict, String> {
        plugin_fixtures::no_hook()
    }
}

plugin_fixtures::export!(C with_types_in plugin_fixtures);
