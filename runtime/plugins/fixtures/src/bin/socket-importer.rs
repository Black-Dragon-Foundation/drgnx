//! One ability, `probe`: opens a TCP connection through std, so the component imports `wasi:sockets`. The host
//! does not link it, so this component must fail to load.

#![no_main]

use plugin_fixtures::prelude::*;

struct C;

impl ability::Guest for C {
    fn call(_tool: String, _args_json: String) -> Result<String, String> {
        match std::net::TcpStream::connect("192.0.2.1:9") {
            Ok(_) => Ok("connected".to_string()),
            Err(e) => Err(e.to_string()),
        }
    }
}

impl hook::Guest for C {
    fn run(_point: Point, _input_json: String) -> Result<Verdict, String> {
        plugin_fixtures::no_hook()
    }
}

plugin_fixtures::export!(C with_types_in plugin_fixtures);
