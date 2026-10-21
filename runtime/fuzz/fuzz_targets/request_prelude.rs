//! A line through the dispatcher's steps 1 to 5 (no handler), for every class and a few protocol states.
#![no_main]

use drgnx_proto::registry::Class;
use drgnx_ratatoskr::dispatch::prelude;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|line: &str| {
    for class in [Class::User, Class::Agent, Class::Service] {
        for (proto, read_only) in [(0, None), (1, None), (1, Some(9)), (u32::MAX, None)] {
            let _ = prelude(class, proto, read_only, line);
        }
    }
});
