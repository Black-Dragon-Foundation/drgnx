//! One ability, `probe`: sends a request through `wasi:http` directly, so the component imports it. The host does
//! not link it, so this component must fail to load.

#![no_main]

use plugin_fixtures::prelude::*;
use wasip2::http::{outgoing_handler, types};

struct C;

impl ability::Guest for C {
    fn call(_tool: String, _args_json: String) -> Result<String, String> {
        let request = types::OutgoingRequest::new(types::Fields::new());
        match outgoing_handler::handle(request, None) {
            Ok(_) => Ok("sent".to_string()),
            Err(e) => Err(format!("{e:?}")),
        }
    }
}

impl hook::Guest for C {
    fn run(_point: Point, _input_json: String) -> Result<Verdict, String> {
        plugin_fixtures::no_hook()
    }
}

plugin_fixtures::export!(C with_types_in plugin_fixtures);
