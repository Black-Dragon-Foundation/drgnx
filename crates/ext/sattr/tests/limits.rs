//! The limits both hosts put on an extension (`Limits`): a runaway loop and a memory bomb are each stopped, in Luau and in
//! a real component (a tiny guest, wrapped by wit-component against the `drgnx:api` world: guest.rs).

mod common;
#[path = "common/guest.rs"]
mod guest;

use common::{LIMITS, editor, user};
use sattr::editor::Editor;
use sattr::{Limits, wasm};

/// A guest whose `init` asks for memory until it is told no, then gives up.
fn bomb() -> String {
    guest::core_module(
        "",
        "",
        "(loop $l (if (i32.eq (memory.grow (i32.const 16)) (i32.const -1)) (then unreachable)) (br $l))",
    )
}

/// A guest whose `init` grows a table until it is told no, then gives up.
fn table_bomb() -> String {
    guest::core_module(
        "(table 1 funcref)",
        "",
        "(loop $l (if (i32.eq (table.grow (ref.null func) (i32.const 100)) (i32.const -1)) (then unreachable)) (br $l))",
    )
}

/// Run the guest's `init` under LIMITS (with the epoch ticking when TICKS): the error text, and how often a limit said
/// no to growth.
fn init(source: &str, limits: Limits, ticks: bool) -> (Result<(), String>, u32) {
    let (api, ex) = editor();
    let engine = wasm::engine().expect("the engine");
    let _clock = ticks.then(|| wasm::ticker(&ex, engine.clone()));
    let component = guest::component(&engine, source);
    let linker = wasm::linker::<Editor>(&engine).expect("links");
    let mut g = wasm::Guest::instantiate(&engine, &linker, &component, &api, "greedy", limits)
        .expect("instantiates");
    let r = g.init(user()).map_err(|e| format!("{e:?}"));
    (r, g.denied_growths())
}

fn limits(steps: u64, memory_bytes: usize, ticks: u64) -> Limits {
    Limits {
        steps,
        memory_bytes,
        ticks,
        ..LIMITS
    }
}

#[test]
fn a_component_that_never_ends_runs_out_of_fuel() {
    let (r, _) = init(
        &guest::spin(),
        limits(100_000, 1 << 20, u64::MAX / 2),
        false,
    );
    let e = r.expect_err("stopped");
    assert!(e.contains("fuel"), "{e}");
}

#[test]
fn a_component_that_never_ends_is_interrupted_by_the_epoch() {
    let (r, _) = init(&guest::spin(), limits(u64::MAX / 2, 1 << 20, 30), true);
    let e = r.expect_err("stopped");
    assert!(e.contains("interrupt"), "{e}");
}

#[test]
fn a_component_memory_bomb_is_refused_memory() {
    let (r, denied) = init(&bomb(), limits(10_000_000, 1 << 20, u64::MAX / 2), false);
    let e = r.expect_err("the guest gave up when growing failed");
    assert!(
        e.contains("unreachable"),
        "stopped by the refusal, not by the fuel: {e}"
    );
    assert!(denied >= 1, "the limiter said no");
}

#[test]
fn a_component_table_bomb_is_refused_by_the_limit_in_limits() {
    let tight = Limits {
        table_elements: 50,
        ..limits(10_000_000, 1 << 20, u64::MAX / 2)
    };
    let (r, denied) = init(&table_bomb(), tight, false);
    let e = r.expect_err("the guest gave up when growing failed");
    assert!(
        e.contains("unreachable"),
        "stopped by the refusal, not by the fuel: {e}"
    );
    assert!(denied >= 1, "the table limit said no");
    // a roomier limit lets the same guest go on, until its fuel runs out
    let roomy = Limits {
        table_elements: 1_000_000,
        ..limits(10_000, 1 << 20, u64::MAX / 2)
    };
    let (r, denied) = init(&table_bomb(), roomy, false);
    assert!(r.expect_err("fuel").contains("fuel"));
    assert_eq!(denied, 0);
}

#[test]
fn a_luau_loop_and_a_luau_memory_bomb_are_stopped_and_the_host_goes_on() {
    let (api, _ex) = editor();
    let h = sattr::luau::LuauHost::new(&api, "greedy", LIMITS).expect("the host starts");
    let e = h
        .exec(user(), "loop", "while true do end")
        .expect_err("stopped");
    let d = format!("{:?}", e.detail());
    assert!(d.contains("step budget") || d.contains("its time"), "{e:?}");
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

#[test]
fn luau_honours_the_wall_clock_deadline() {
    let (api, _ex) = editor();
    // plenty of steps, little time: the clock stops the script, not the step budget
    let tight = limits(u64::MAX / 4, 8 << 20, 50);
    let h = sattr::luau::LuauHost::new(&api, "slow", tight).expect("the host starts");
    let e = h
        .exec(user(), "spin", "while true do end")
        .expect_err("stopped");
    assert!(format!("{:?}", e.detail()).contains("its time"), "{e:?}");
}
