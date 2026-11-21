//! One ability, `alloc`: allocates and touches `{"mib": N}` MiB (default 128). Past the host's memory limit the
//! allocation fails and the guest aborts, which is a trap.

#![no_main]

use plugin_fixtures::prelude::*;

struct C;

impl ability::Guest for C {
    fn call(_tool: String, args_json: String) -> Result<String, String> {
        let mib = plugin_fixtures::arg(&args_json, "mib")
            .and_then(|v| v.as_u64())
            .unwrap_or(128) as usize;
        let v = vec![1u8; mib << 20];
        Ok(std::hint::black_box(v).len().to_string())
    }
}

impl hook::Guest for C {
    fn run(_point: Point, _input_json: String) -> Result<Verdict, String> {
        plugin_fixtures::no_hook()
    }
}

plugin_fixtures::export!(C with_types_in plugin_fixtures);
