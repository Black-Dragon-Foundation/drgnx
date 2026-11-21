//! A `before-commit` hook that asks `https://api.example.com/` through the host's HTTP: a refusal of the request is a
//! deny with the host's words, an answer is an annotation with its status.

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
        Ok(match host::http_get("https://api.example.com/", &[]) {
            Ok(r) => Verdict::Annotate(format!("api answered {}", r.status)),
            Err(e) => Verdict::Deny(e),
        })
    }
}

plugin_fixtures::export!(C with_types_in plugin_fixtures);
