//! One ability, `probe`: tries to open files and list directories through std. It imports `wasi:filesystem`; the
//! host grants no preopened directory, so every attempt fails and the answer says so.

#![no_main]

use plugin_fixtures::prelude::*;

struct C;

impl ability::Guest for C {
    fn call(_tool: String, _args_json: String) -> Result<String, String> {
        let opened = std::fs::File::open("/etc/hostname").is_ok();
        let listed = std::fs::read_dir("/").map(|d| d.count()).ok();
        let cwd = std::fs::read_dir(".").map(|d| d.count()).ok();
        Ok(serde_json::json!({ "opened": opened, "root_entries": listed, "cwd_entries": cwd }).to_string())
    }
}

impl hook::Guest for C {
    fn run(_point: Point, _input_json: String) -> Result<Verdict, String> {
        plugin_fixtures::no_hook()
    }
}

plugin_fixtures::export!(C with_types_in plugin_fixtures);
