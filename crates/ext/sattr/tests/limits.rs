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

/// Run the guest's `init` under LIMITS (the epoch always ticking: the guest holds the clock): the error text, and how often a limit said
/// no to growth.
fn init(source: &str, limits: Limits) -> (Result<(), String>, u32) {
    let (api, ex) = editor();
    let engine = wasm::engine().expect("the engine");
    let component = guest::component(&engine, source);
    let linker = wasm::linker::<Editor>(&engine).expect("links");
    let clock = wasm::ticker(&ex, engine.clone());
    let mut g =
        wasm::Guest::instantiate(&engine, &linker, &component, &api, "greedy", limits, &clock)
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
    // the epoch (5 s, ticking) is the backstop: if the fuel limit were broken the guest would end in seconds as an
    // interrupt, and this assertion would fail instead of the test hanging
    let (r, _) = init(&guest::spin(), limits(100_000, 1 << 20, 5_000));
    let e = r.expect_err("stopped");
    assert!(e.contains("fuel"), "{e}");
}

#[test]
fn a_component_that_never_ends_is_interrupted_by_the_epoch() {
    // the fuel (a few seconds of work) is the backstop: if the epoch did not fire the guest would end as `fuel`, and
    // this assertion would fail instead of the test hanging
    let (r, _) = init(&guest::spin(), limits(3_000_000_000, 1 << 20, 30));
    let e = r.expect_err("stopped");
    assert!(e.contains("interrupt"), "{e}");
}

#[test]
fn a_component_memory_bomb_is_refused_memory() {
    let (r, denied) = init(&bomb(), limits(10_000_000, 1 << 20, u64::MAX / 2));
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
    let (r, denied) = init(&table_bomb(), tight);
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
    let (r, denied) = init(&table_bomb(), roomy);
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
    // (the step budget is a backstop of a few seconds, so a broken clock fails the assertion rather than hanging)
    let tight = limits(200_000_000, 8 << 20, 50);
    let h = sattr::luau::LuauHost::new(&api, "slow", tight).expect("the host starts");
    let e = h
        .exec(user(), "spin", "while true do end")
        .expect_err("stopped");
    assert!(format!("{:?}", e.detail()).contains("its time"), "{e:?}");
}

#[test]
fn luau_stops_a_loop_by_its_step_budget_before_the_clock() {
    let (api, _ex) = editor();
    // a roomy clock (5 s): only the step budget can stop it at once, and without it the clock ends the loop as `its time`
    let h = sattr::luau::LuauHost::new(&api, "steps", limits(10_000, 8 << 20, 5_000))
        .expect("the host starts");
    let e = h
        .exec(user(), "spin", "while true do end")
        .expect_err("stopped");
    assert!(format!("{:?}", e.detail()).contains("step budget"), "{e:?}");
}
