//! Arbitrary JSON as `task_write`'s arguments over a schema-7 store: the check, the typed decode and the run of every
//! op. `@T` in the input stands for an existing task's id. A refusal is an answer; nothing may panic or hang.
#![no_main]

#[path = "common/tools_world.rs"]
mod tools_world;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| tools_world::run("task_write", data));
