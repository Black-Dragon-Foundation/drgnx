//! The review's findings and the extension API's security claims, run through the hosts: Luau scripts through
//! `LuauHost`, and, for the component host, the generated `Host` impls that a guest's imports run (the limits of the
//! component host, which need a guest, are in limits.rs). Every claim here is a claim about the editor behind the API,
//! so each goes through the code an extension really reaches.

mod common;

use std::panic::{AssertUnwindSafe, catch_unwind};

use std::sync::{Arc, Mutex, RwLock};

use bod::Origin;
use common::{editor, user};
use sattr::Caller;
use sattr::editor::Editor;
use sattr::generated::WasmApi;
use sattr::generated::drgnx_api_v0_1_0::types::ErrorKind;
use sattr::luau::LuauHost;
use sattr::wasm::bindings::drgnx::api::{
    ask::Host as AskHost, commands::Host as CommandsHost, keys::Host as KeysHost,
    notices::Host as NoticesHost, notices::Level, settings::Host as SettingsHost,
    settings::ScopedLevel,
};

/// What a component's imports reach, for EXTENSION acting for ORIGIN: the generated `Host` impls, the code a guest's
/// calls run.
pub fn wasm_api(api: &Arc<Mutex<Editor>>, extension: &str, origin: Origin) -> WasmApi<Editor> {
    WasmApi(
        Arc::clone(api),
        Arc::new(RwLock::new(Caller {
            extension: extension.to_string(),
            origin,
        })),
    )
}

fn luau(api: &Arc<Mutex<Editor>>, extension: &str) -> LuauHost {
    LuauHost::new(api, extension, common::LIMITS).expect("the host starts")
}

fn run(h: &LuauHost, src: &str) -> villa::Result<()> {
    h.exec(user(), "test", src)
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
    let (api, _ex) = editor();
    let h = luau(&api, "num");
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
    // the result direction: an id above 2^53 is an error, never a rounded number
    saman::lock(&api).next_question = 1 << 53;
    refused(
        &h,
        "drgnx.ask.choose('t', 'b', 'x', 'x', 1000)",
        "above 2^53",
    );
    saman::lock(&api).next_question = 6;
    run(
        &h,
        "assert(drgnx.ask.choose('t', 'b', 'x', 'x', 1000) == 7)",
    )
    .expect("a small id passes");
    // and what the host hands a script's function
    let ext = h
        .load(user(), "ext", "return { answered = function() end }")
        .expect("loads");
    assert!(
        h.answered(user(), &ext, (1 << 53) + 1, "x").is_err(),
        "refused, not rounded"
    );
    h.answered(user(), &ext, 1 << 53, "x").expect("2^53 passes");
}

// 2. the bound tables are read-only to scripts
#[test]
fn a_script_cannot_replace_the_api() {
    let (api, _ex) = editor();
    let h = luau(&api, "ro");
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
    assert!(saman::lock(&api).extension_commands.contains_key("ro/a"));
}

// the sandbox: no way out of the script's own world
#[test]
fn the_luau_sandbox_has_no_door_to_files_processes_or_other_code() {
    let (api, _ex) = editor();
    let h = luau(&api, "sbx");
    run(
        &h,
        "assert(io == nil, 'io')
         assert(require == nil, 'require')
         assert(loadstring == nil, 'loadstring')
         assert(dofile == nil, 'dofile')
         assert(loadfile == nil, 'loadfile')
         assert(os.execute == nil, 'os.execute')
         assert(os.getenv == nil, 'os.getenv')
         assert(os.remove == nil, 'os.remove')",
    )
    .expect("the doors are shut");
}

// 1 (caller identity). each call is the caller's: two extensions with the same ids have their own
#[test]
fn the_caller_reaches_the_api_from_both_hosts() {
    let (api, _ex) = editor();
    let a = luau(&api, "a");
    let b = luau(&api, "b");
    run(&a, "assert(drgnx.commands.register('x', 'T', 'D') == true)").expect("a registers");
    run(&b, "assert(drgnx.commands.register('x', 'T', 'D') == true)")
        .expect("b registers its own `x`");
    run(
        &a,
        "local v, e = drgnx.commands.register('x', 'T', 'D'); assert(v == nil and e == 'conflict')",
    )
    .expect("a's `x` is taken");
    let mut w = wasm_api(&api, "c", user());
    let r = CommandsHost::register(&mut w, "x".into(), "T".into(), "D".into()).expect("no trap");
    assert!(r.is_ok());
    let keys: Vec<String> = saman::lock(&api)
        .extension_commands
        .keys()
        .cloned()
        .collect();
    assert_eq!(keys, ["a/x", "b/x", "c/x"]);
}

// 2. settings.set takes the scoped levels only, and the provenance names the extension
#[test]
fn an_extension_sets_scoped_settings_only_through_either_host() {
    let (api, _ex) = editor();
    let h = luau(&api, "vim");
    run(
        &h,
        "assert(drgnx.settings.set('editor.theme', '\"night\"', 'language', 'rust') == true)",
    )
    .expect("sets");
    // a file level is not a level the API names: refused at the host's door
    for level in ["user", "machine", "project", "built-in"] {
        refused(
            &h,
            &format!("drgnx.settings.set('editor.theme', '\"x\"', '{level}', 'x')"),
            "not one of",
        );
    }
    run(&h, "local v, e = drgnx.settings.set('editor.theme', '\"x\"', 'language', ''); assert(v == nil and e == 'invalid')")
        .expect("an empty scope id");
    run(&h, "local v, e = drgnx.settings.set('nope', '1', 'pane', 'p'); assert(v == nil and e == 'not-found')")
        .expect("an unknown key");
    let rust = skipan::Scope {
        language: Some("rust".into()),
        ..skipan::Scope::default()
    };
    let source = saman::lock(&api)
        .settings
        .snapshot()
        .provenance_in("editor.theme", &rust)
        .expect("provenance")
        .source;
    assert_eq!(source, skipan::Source::Extension("vim".into()));
    run(
        &h,
        "assert(drgnx.settings.get('editor.theme') == '\"light\"')",
    )
    .expect("other scopes do not see it");
    // the component host's door: the same call
    let mut w = wasm_api(&api, "wasm-ext", user());
    let r = SettingsHost::set(
        &mut w,
        "editor.theme".into(),
        "\"dusk\"".into(),
        ScopedLevel::Pane,
        "p1".into(),
    )
    .expect("no trap");
    assert!(r.is_ok());
    let pane = skipan::Scope {
        pane: Some("p1".into()),
        ..skipan::Scope::default()
    };
    let source = saman::lock(&api)
        .settings
        .snapshot()
        .provenance_in("editor.theme", &pane)
        .expect("provenance")
        .source;
    assert_eq!(source, skipan::Source::Extension("wasm-ext".into()));
}

// 3. ask.choose never waits
#[test]
fn a_question_returns_at_once_has_a_capped_timeout_and_its_answer_comes_later() {
    let (api, ex) = editor();
    let h = luau(&api, "asker");
    // the longest allowed wait is five minutes, and the call does not wait for any of it
    run(
        &h,
        "assert(drgnx.ask.choose('t', 'b', 'a\\nb', 'a', 300000) == 1)",
    )
    .expect("returns the id");
    run(
        &h,
        "local v, e = drgnx.ask.choose('t', 'b', 'a', 'a', 0); assert(v == nil and e == 'invalid')",
    )
    .expect("zero");
    run(&h, "local v, e = drgnx.ask.choose('t', 'b', 'a', 'a', 300001); assert(v == nil and e == 'invalid')").expect("long");
    run(&h, "local v, e = drgnx.ask.choose('t', 'b', 'a', 'z', 1000); assert(v == nil and e == 'invalid')")
        .expect("a default that is no choice");
    // the answer (a headless editor answers the default) arrives through `answered`
    let ext = h
        .load(
            user(),
            "ext",
            "local E = {}; E.answered = function(q, c) E.last = q .. ':' .. c end; return E",
        )
        .expect("loads");
    let mut got = Vec::new();
    ex.block_on(async {
        for _ in 0..100_000 {
            got = saman::lock(&api).poll_answers();
            if !got.is_empty() {
                break;
            }
            tokio::task::yield_now().await;
        }
    });
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(
        (
            got[0].extension.as_str(),
            got[0].question,
            got[0].choice.as_str()
        ),
        ("asker", 1, "a")
    );
    h.answered(user(), &ext, got[0].question, &got[0].choice)
        .expect("delivers");
    assert_eq!(ext.get::<String>("last").expect("recorded"), "1:a");
    // an extension holds only a few questions at once
    for _ in 0..20 {
        run(&h, "assert(drgnx.ask.choose('t', 'b', 'a', 'a', 1000))").expect("within the cap");
    }
    run(&h, "local v, e = drgnx.ask.choose('t', 'b', 'a', 'a', 1000); assert(v == nil and e == 'refused')").expect("over");
    // the component host's door
    let mut w = wasm_api(&api, "wasm-asker", user());
    let r = AskHost::choose(&mut w, "t".into(), "b".into(), "a".into(), "a".into(), 0)
        .expect("no trap");
    assert!(r.is_err(), "zero is refused here too");
    let r = AskHost::choose(
        &mut w,
        "t".into(),
        "b".into(),
        "a".into(),
        "a".into(),
        300_000,
    )
    .expect("no trap");
    assert!(r.is_ok());
}

// 10. notices belong to the extension that posted them
#[test]
fn notices_are_namespaced_owned_and_capped_through_either_host() {
    let (api, _ex) = editor();
    let a = luau(&api, "a");
    let b = luau(&api, "b");
    // the same key, two extensions: two notices
    run(
        &a,
        "assert(drgnx.notices.post('info', 'A', 'x', 'disk') == 1)",
    )
    .expect("a posts");
    run(
        &b,
        "assert(drgnx.notices.post('info', 'B', 'x', 'disk') == 2)",
    )
    .expect("b posts its own");
    run(
        &a,
        "assert(drgnx.notices.post('warning', 'A again', 'x', 'disk') == 1)",
    )
    .expect("a's key updates a's notice");
    assert_eq!(saman::lock(&api).notices.len(), 2);
    // b cannot touch a's notice
    run(
        &b,
        "local v, e = drgnx.notices.dismiss(1); assert(v == nil and e == 'refused')",
    )
    .expect("not b's");
    assert_eq!(saman::lock(&api).notices.len(), 2);
    run(&a, "assert(drgnx.notices.dismiss(1) == true)").expect("a's own");
    assert_eq!(saman::lock(&api).notices.len(), 1);
    // the cap: a holds twenty, the next is refused, and b is not affected
    for _ in 0..20 {
        run(&a, "assert(drgnx.notices.post('info', 'n', 'x', ''))").expect("within the cap");
    }
    run(&a, "local v, e = drgnx.notices.post('info', 'n', 'x', ''); assert(v == nil and e == 'refused')").expect("over");
    run(&b, "assert(drgnx.notices.post('info', 'n', 'x', ''))").expect("b is its own");
    // the component host's door: another extension's id is not its to dismiss
    let mut w = wasm_api(&api, "c", user());
    let theirs = saman::lock(&api).notices.len();
    let r = NoticesHost::dismiss(&mut w, 2).expect("no trap");
    assert!(r.is_err());
    assert_eq!(saman::lock(&api).notices.len(), theirs);
    let r = NoticesHost::post(&mut w, Level::Info, "T".into(), "B".into(), "k".into())
        .expect("no trap");
    assert!(r.is_ok());
}

// 7. commands.run: the extension's door, and the origin that started the chain
#[test]
fn an_extension_runs_only_extension_commands_and_an_agent_cannot_borrow_it() {
    let (api, _ex) = editor();
    let h = luau(&api, "e");
    // for the user: the extension's own command only
    h.exec(
        user(),
        "t",
        "assert(drgnx.commands.run('ext.ping', '') == '\"ran\"')
         for _, id in ipairs({'buffer.save', 'agent.echo'}) do
           local v, e = drgnx.commands.run(id, '')
           assert(v == nil and e == 'refused', id)
         end",
    )
    .expect("the extension's door");
    // an agent has the extension run something: the agent's origin goes through, and no command opens both doors
    h.exec(
        Origin::Agent("a1".into()),
        "t",
        "for _, id in ipairs({'ext.ping', 'buffer.save', 'agent.echo'}) do
           local v, e = drgnx.commands.run(id, '')
           assert(v == nil and e == 'refused', id)
         end",
    )
    .expect("the confused deputy is refused");
    // the component host's door: the same
    let mut w = wasm_api(&api, "c", user());
    assert!(
        CommandsHost::run(&mut w, "ext.ping".into(), String::new())
            .expect("no trap")
            .is_ok()
    );
    assert!(
        CommandsHost::run(&mut w, "buffer.save".into(), String::new())
            .expect("no trap")
            .is_err()
    );
    let mut agent = wasm_api(&api, "c", Origin::Agent("a1".into()));
    assert!(
        CommandsHost::run(&mut agent, "ext.ping".into(), String::new())
            .expect("no trap")
            .is_err()
    );
}

// 9. an extension binds no reserved key
#[test]
fn an_extension_cannot_bind_a_reserved_key_through_either_host() {
    let (api, _ex) = editor();
    let h = luau(&api, "keys");
    run(
        &h,
        "for _, c in ipairs({'C-g', 'C-g C-x', 'M-x', 'ctrl+shift+p', 'f1'}) do
           local v, e = drgnx.keys.bind(c, 'evil', '')
           assert(v == nil and e == 'refused', c)
         end
         assert(drgnx.keys.bind('C-x C-v', 'vim-visit', '') == true)
         assert(drgnx.keys.resolve('C-x C-v', '') == 'vim-visit')",
    )
    .expect("reserved keys are refused");
    let mut w = wasm_api(&api, "wasm-keys", user());
    assert!(
        KeysHost::bind(&mut w, "C-g".into(), "evil".into(), String::new())
            .expect("no trap")
            .is_err()
    );
    assert!(
        KeysHost::bind(&mut w, "C-c C-v".into(), "ok".into(), String::new())
            .expect("no trap")
            .is_ok()
    );
}

// a poisoned lock fails the extension; it does not continue
#[test]
fn a_panic_in_the_api_fails_the_extension_and_every_later_call() {
    let (api, _ex) = editor();
    saman::lock(&api)
        .registry
        .register(
            bod::Command {
                id: bod::CommandId("ext.boom"),
                title: "Boom",
                doc: "Panics.",
                args: bod::ArgSpec::NONE,
                source: bod::SourceLoc {
                    file: file!(),
                    line: line!(),
                },
                exposure: bod::Exposure::Extension,
            },
            bod::handler(|_, _| panic!("a bug in a command")),
        )
        .expect("registers");
    let h = luau(&api, "victim");
    let r = catch_unwind(AssertUnwindSafe(|| {
        run(&h, "drgnx.commands.run('ext.boom', '')")
    }));
    assert!(r.is_err() || r.is_ok_and(|r| r.is_err()), "the call failed");
    assert!(api.is_poisoned(), "the panic did poison the lock");
    // nothing recovers it: a new call, in any host, is an error
    let again = luau(&api, "another");
    refused(
        &again,
        "drgnx.commands.register('a', 'b', 'c')",
        "failed earlier",
    );
    refused(
        &h,
        "drgnx.notices.post('info', 'x', 'y', '')",
        "failed earlier",
    );
    let mut w = wasm_api(&api, "c", user());
    let e = CommandsHost::register(&mut w, "a".into(), "b".into(), "c".into()).expect_err("a trap");
    assert!(e.to_string().contains("failed earlier"), "{e}");
}

#[test]
fn a_call_from_inside_a_call_is_refused_not_deadlocked() {
    let (api, _ex) = editor();
    let h = luau(&api, "busy");
    let held = saman::lock(&api);
    refused(&h, "drgnx.commands.register('a', 'b', 'c')", "busy");
    drop(held);
    run(&h, "drgnx.commands.register('a', 'b', 'c')").expect("free again");
}

// 6 and 7. names are namespaced, and the version is in them
#[test]
fn names_carry_the_package_version() {
    let (api, _ex) = editor();
    let h = luau(&api, "names");
    run(
        &h,
        "assert(drgnx.api_version == '0.1.0')
         assert(drgnx.commands == drgnx.api_v0_1_0.commands)
         assert(drgnx.notices.post('warning', 't', 'b', 'k') == 1)",
    )
    .expect("the names");
    refused(
        &h,
        "drgnx.notices.post('pane', 't', 'b', 'k')",
        "not one of",
    );
}

// 8. one Luau error contract
#[test]
fn an_api_failure_is_returned_and_a_misuse_is_raised() {
    let (api, _ex) = editor();
    let h = luau(&api, "contract");
    run(
        &h,
        "local v, e = drgnx.commands.find_source('nope')
         assert(v == nil and e == 'not-found')
         assert(type(drgnx.commands.find_source('buffer.save')) == 'string')",
    )
    .expect("the contract");
    refused(&h, "drgnx.commands.find_source()", "expected 1 argument");
    refused(&h, "drgnx.commands.find_source(1)", "expected a string");
}

#[test]
fn a_scripts_ambiguous_result_is_refused() {
    let (api, _ex) = editor();
    let h = luau(&api, "script");
    let call = |body: &str| {
        let ext = h
            .load(
                user(),
                "ext",
                &format!("return {{ run = function(name) {body} end }}"),
            )
            .expect("loads");
        h.run(user(), &ext, "x")
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
    let empty = h.load(user(), "ext", "return {}").expect("loads");
    assert!(h.run(user(), &empty, "x").is_err(), "a missing function");
    let init = h
        .load(user(), "ext", "return { init = function() return 1 end }")
        .expect("loads");
    assert!(h.init(user(), &init).is_err(), "init returns nothing");
}

#[test]
fn the_extension_runs_for_the_origin_it_is_given() {
    let (api, _ex) = editor();
    let h = luau(&api, "who");
    let ext = h
        .load(
            user(),
            "ext",
            "return { init = function() local v, e = drgnx.commands.run('ext.ping', ''); assert(v == '\"ran\"', e) end }",
        )
        .expect("loads");
    h.init(user(), &ext).expect("for the user: runs");
    assert!(
        h.init(Origin::Agent("a1".into()), &ext).is_err(),
        "for an agent: refused, and the assert raises"
    );
    h.init(user(), &ext).expect("the origin was restored");
}
