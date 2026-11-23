//! The Opus review's findings, run through the generated code (the generator's own halves are in mal-gen's tests).

mod common;

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex};

use common::Model;
use sattr::generated::drgnx_api_v0_1_0::exports::entry;
use sattr::generated::drgnx_api_v0_1_0::types::ErrorKind;
use sattr::luau::LuauHost;

fn host() -> (Arc<Mutex<Model>>, LuauHost) {
    let api = Arc::new(Mutex::new(Model::default()));
    let h = LuauHost::new(&api, 1_000_000).expect("the host starts");
    (api, h)
}

fn run(h: &LuauHost, src: &str) -> villa::Result<()> {
    h.guarded(|lua| lua.load(src).exec())
}

fn refused(h: &LuauHost, src: &str, about: &str) {
    match run(h, src) {
        Ok(()) => panic!("`{src}` must fail"),
        Err(e) => {
            let d = format!("{:?}", e.detail());
            assert!(d.contains(about), "`{src}`: {d} does not say `{about}`");
        }
    }
}

// 1. u64 and s64 refuse values above 2^53 and fractions
#[test]
fn integers_above_two_to_the_53_and_fractions_are_refused() {
    let (api, h) = host();
    refused(&h, "drgnx.notices.dismiss(9007199254740994)", "outside");
    refused(&h, "drgnx.notices.dismiss(1.5)", "whole number");
    refused(&h, "drgnx.notices.dismiss(-1)", "outside");
    refused(
        &h,
        "drgnx.ask.choose('t', 'b', 'x', 'x', 1.5)",
        "whole number",
    );
    refused(
        &h,
        "drgnx.ask.choose('t', 'b', 'x', 'x', 4294967296)",
        "outside",
    );
    refused(&h, "drgnx.notices.dismiss('7')", "expected a number");
    run(&h, "drgnx.notices.dismiss(9007199254740992)").expect("2^53 itself is exact");
    assert_eq!(saman::lock(&api).log, ["dismiss 9007199254740992"]);
    // the result direction: an id above 2^53 is an error, never a rounded number
    saman::lock(&api).next_id = (1 << 53) + 2;
    refused(
        &h,
        "drgnx.notices.post('info', 't', 'b', 'k')",
        "above 2^53",
    );
    saman::lock(&api).next_id = 7;
    run(&h, "assert(drgnx.notices.post('info', 't', 'b', 'k') == 7)").expect("a small id passes");
    // and what the host hands a script's function
    let ext = h
        .load("ext", "return { run = function() return true end }")
        .expect("loads");
    let r = h.guarded(|lua| entry::luau_run(lua, &ext, "x", (1 << 53) + 1));
    assert!(r.is_err(), "a buffer id above 2^53 is refused, not rounded");
    let ok = h.guarded(|lua| entry::luau_run(lua, &ext, "x", 1 << 53));
    assert_eq!(ok.expect("2^53 passes"), Ok(()));
}

// 2. the bound tables are read-only to scripts
#[test]
fn a_script_cannot_replace_the_api() {
    let (api, h) = host();
    for src in [
        "drgnx.commands.register = function() end",
        "drgnx.api_v0_1_0.commands.run = nil",
        "drgnx.commands = nil",
        "drgnx.api_v0_1_0 = nil",
        "drgnx.extra = 1",
    ] {
        refused(&h, src, "readonly");
    }
    run(&h, "assert(drgnx.commands.register('a', 'b', 'c') == true)")
        .expect("the real function still runs");
    assert_eq!(saman::lock(&api).log, ["register a"]);
}

// 4. no `lock().unwrap()`: no poisoning, no re-entry deadlock
#[test]
fn a_panic_in_the_api_does_not_break_later_calls() {
    let (api, h) = host();
    saman::lock(&api).panic_on_register = true;
    let r = catch_unwind(AssertUnwindSafe(|| {
        run(&h, "drgnx.commands.register('a', 'b', 'c')")
    }));
    assert!(r.is_err() || r.is_ok_and(|r| r.is_err()), "the call failed");
    assert!(api.is_poisoned(), "the panic did poison the lock");
    saman::lock(&api).panic_on_register = false;
    let second = LuauHost::new(&api, 1_000_000).expect("a second state");
    run(
        &second,
        "assert(drgnx.commands.register('b', 'b', 'c') == true)",
    )
    .expect("later calls work");
    assert_eq!(saman::lock(&api).log, ["register b"]);
}

#[test]
fn a_call_from_inside_a_call_is_refused_not_deadlocked() {
    let (api, h) = host();
    let held = saman::lock(&api);
    refused(&h, "drgnx.commands.register('a', 'b', 'c')", "busy");
    drop(held);
    run(&h, "drgnx.commands.register('a', 'b', 'c')").expect("free again");
}

// 6 and 7. names are namespaced, and the version is in them
#[test]
fn names_carry_the_package_version_and_each_interface_its_own_enums() {
    let (_api, h) = host();
    run(
        &h,
        "assert(drgnx.api_version == '0.1.0')
         assert(drgnx.commands == drgnx.api_v0_1_0.commands)
         assert(drgnx.notices.post('warning', 't', 'b', 'k') == 0)
         assert(drgnx.settings.set('k', 'v', 'pane') == true)",
    )
    .expect("both enums named `level` work in their own interface");
    refused(&h, "drgnx.settings.set('k', 'v', 'info')", "not one of");
    refused(
        &h,
        "drgnx.notices.post('pane', 't', 'b', 'k')",
        "not one of",
    );
}

// 8. one Luau error contract
#[test]
fn an_api_failure_is_returned_and_a_misuse_is_raised() {
    let (_api, h) = host();
    run(
        &h,
        "local v, e = drgnx.commands.find_source('nope')
         assert(v == nil and e == 'not-found')
         assert(drgnx.commands.find_source('known') == 'a.rs:1')",
    )
    .expect("the contract");
    refused(&h, "drgnx.commands.find_source()", "expected 1 argument");
    refused(&h, "drgnx.commands.find_source(1)", "expected a string");
}

#[test]
fn a_scripts_ambiguous_result_is_refused() {
    let (_api, h) = host();
    let call = |body: &str| {
        let ext = h
            .load(
                "ext",
                &format!("return {{ run = function(name, buffer) {body} end }}"),
            )
            .expect("loads");
        h.guarded(|lua| entry::luau_run(lua, &ext, "x", 1))
    };
    assert_eq!(call("return true").expect("success"), Ok(()));
    assert_eq!(
        call("return nil, 'refused'").expect("a failure"),
        Err(ErrorKind::Refused)
    );
    for bad in [
        "return true, 'refused'",
        "return nil",
        "return",
        "return nil, 'denied'",
        "return false",
        "return 1",
        "return true, true",
    ] {
        let e = call(bad)
            .err()
            .unwrap_or_else(|| panic!("`{bad}` must be refused"));
        assert!(
            format!("{:?}", e.detail()).contains("contract"),
            "`{bad}`: {e:?}"
        );
    }
    let ext = h.load("ext", "return {}").expect("loads");
    assert!(
        h.guarded(|lua| entry::luau_run(lua, &ext, "x", 1)).is_err(),
        "a missing function"
    );
    let init = h
        .load("ext", "return { init = function() return 1 end }")
        .expect("loads");
    assert!(
        h.guarded(|lua| entry::luau_init(lua, &init)).is_err(),
        "init returns nothing"
    );
}

#[test]
fn a_runaway_script_is_stopped_and_the_host_still_works() {
    let api = Arc::new(Mutex::new(Model::default()));
    let h = LuauHost::new(&api, 10_000).expect("starts");
    refused(&h, "while true do end", "step budget");
    run(&h, "drgnx.commands.register('a', 'b', 'c')").expect("the next call has a fresh budget");
}

// the component host
#[test]
fn the_component_host_forwards_recovers_from_a_panic_and_refuses_re_entry() {
    use sattr::generated::WasmApi;
    use sattr::wasm::bindings::drgnx::api::commands::Host;

    let engine = sattr::wasm::engine().expect("the engine starts");
    sattr::wasm::linker::<Model>(&engine).expect("every interface links");

    let api = Arc::new(Mutex::new(Model::default()));
    let mut w = WasmApi(Arc::clone(&api));
    let r = Host::register(&mut w, "a".into(), "b".into(), "c".into()).expect("no trap");
    assert!(r.is_ok());

    saman::lock(&api).panic_on_register = true;
    let p = catch_unwind(AssertUnwindSafe(|| {
        Host::register(
            &mut WasmApi(Arc::clone(&api)),
            "x".into(),
            "b".into(),
            "c".into(),
        )
    }));
    assert!(p.is_err());
    assert!(api.is_poisoned());
    saman::lock(&api).panic_on_register = false;
    assert!(
        Host::register(&mut w, "b".into(), "b".into(), "c".into())
            .expect("recovered")
            .is_ok()
    );

    let held = saman::lock(&api);
    let busy = Host::register(&mut w, "c".into(), "b".into(), "c".into());
    assert!(
        busy.is_err_and(|e| e.to_string().contains("busy")),
        "a trap, not a deadlock"
    );
    drop(held);
}
