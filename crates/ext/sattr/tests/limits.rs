//! The limits both hosts put on an extension (`Limits`): a runaway loop and a memory bomb are each stopped, in Luau and in
//! a real component (a tiny guest written as component text). The guests import nothing and export the `init` of
//! `drgnx:api/entry`.

mod common;

use common::{LIMITS, editor, user};
use sattr::editor::Editor;
use sattr::{Limits, wasm};
use wasmtime::component::Component;

/// A component whose `init` is the core function BODY.
fn guest(memory: bool, body: &str) -> String {
    format!(
        r#"(component
  (core module $m {mem} (func (export "init") {body}))
  (core instance $i (instantiate $m))
  (func $init (canon lift (core func $i "init")))
  (instance $e (export "init" (func $init)))
  (export "drgnx:api/entry@0.1.0" (instance $e)))"#,
        mem = if memory { "(memory 1)" } else { "" },
    )
}

fn spin() -> String {
    guest(false, "(loop $l (br $l))")
}

fn bomb() -> String {
    guest(
        true,
        "(loop $l (if (i32.eq (memory.grow (i32.const 16)) (i32.const -1)) (then unreachable)) (br $l))",
    )
}

/// Run the guest's `init` under LIMITS (with the epoch ticking when TICKS): the error text, and how often the memory
/// limit said no.
fn init(source: &str, limits: Limits, ticks: bool) -> (Result<(), String>, u32) {
    let (api, ex) = editor();
    let engine = wasm::engine().expect("the engine");
    let _clock = ticks.then(|| wasm::ticker(&ex, engine.clone()));
    let bytes = wat::parse_str(source).expect("the guest text parses");
    let component = Component::new(&engine, bytes).expect("the guest is a component");
    let linker = wasm::linker::<Editor>(&engine).expect("links");
    let mut store = wasm::new_store(&engine, &api, "guest", limits).expect("a store");
    let instance = linker
        .instantiate(&mut store, &component)
        .expect("instantiates");
    let entry = instance
        .get_export_index(&mut store, None, "drgnx:api/entry@0.1.0")
        .expect("the entry instance");
    let at = instance
        .get_export_index(&mut store, Some(&entry), "init")
        .expect("init");
    let func = instance
        .get_typed_func::<(), ()>(&mut store, &at)
        .expect("typed");
    let r = func.call(&mut store, ()).map_err(|e| format!("{e:?}"));
    (r, store.data().denied_growths())
}

#[test]
fn a_component_that_never_ends_runs_out_of_fuel() {
    let limits = Limits {
        steps: 100_000,
        memory_bytes: 1 << 20,
        ticks: u64::MAX / 2,
    };
    let (r, _) = init(&spin(), limits, false);
    let e = r.expect_err("stopped");
    assert!(e.contains("fuel"), "{e}");
}

#[test]
fn a_component_that_never_ends_is_interrupted_by_the_epoch() {
    let limits = Limits {
        steps: u64::MAX / 2,
        memory_bytes: 1 << 20,
        ticks: 30,
    };
    let (r, _) = init(&spin(), limits, true);
    let e = r.expect_err("stopped");
    assert!(e.contains("interrupt"), "{e}");
}

#[test]
fn a_component_memory_bomb_is_refused_memory() {
    let limits = Limits {
        steps: 10_000_000,
        memory_bytes: 1 << 20,
        ticks: u64::MAX / 2,
    };
    let (r, denied) = init(&bomb(), limits, false);
    let e = r.expect_err("the guest gave up when growing failed");
    assert!(
        e.contains("unreachable"),
        "stopped by the refusal, not by the fuel: {e}"
    );
    assert!(denied >= 1, "the limiter said no");
}

#[test]
fn a_luau_loop_and_a_luau_memory_bomb_are_stopped_and_the_host_goes_on() {
    let (api, _ex) = editor();
    let h = sattr::luau::LuauHost::new(&api, "greedy", LIMITS).expect("the host starts");
    let e = h
        .exec(user(), "loop", "while true do end")
        .expect_err("stopped");
    assert!(format!("{:?}", e.detail()).contains("step budget"), "{e:?}");
    let before = h.used_memory();
    let e = h
        .exec(
            user(),
            "bomb",
            "local t = {} while true do t[#t + 1] = string.rep('x', 1000000) end",
        )
        .expect_err("stopped");
    assert!(format!("{:?}", e.detail()).contains("memory"), "{e:?}");
    assert!(
        h.used_memory() <= before + LIMITS.memory_bytes,
        "the state never held more than its limit"
    );
    h.exec(user(), "after", "assert(1 + 1 == 2)")
        .expect("the state still works");
    assert_eq!(h.limits().memory_bytes, LIMITS.memory_bytes);
}
