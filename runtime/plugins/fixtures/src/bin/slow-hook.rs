//! A hook that never returns: it spins until the host's epoch deadline stops it.

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
        let mut n: u64 = 0;
        loop {
            n = std::hint::black_box(n.wrapping_add(1));
        }
    }
}

plugin_fixtures::export!(C with_types_in plugin_fixtures);
