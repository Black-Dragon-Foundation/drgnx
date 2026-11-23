//! The review's findings and the extension API's security claims, run through the hosts: Luau scripts through
//! `LuauHost`, and the component host through the generated `Host` impls that a guest's imports run, and through real
//! guests (guest.rs). Every claim here is a claim about the editor behind the API, so each goes through the code an
//! extension really reaches.

mod common;
#[path = "common/guest.rs"]
mod guest;

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex, RwLock};

use bod::Origin;
use common::{LIMITS, editor, user};
use sattr::editor::Editor;
use sattr::generated::WasmApi;
use sattr::generated::drgnx_api_v0_1_0::entry::AnsweredHow;
use sattr::generated::rt::HandleTable;
use sattr::luau::LuauHost;
use sattr::wasm::bindings::drgnx::api::{
    ask::Host as AskHost,
    commands::{ArgKind, ArgSpec, CommandSpec, Exposure, Host as CommandsHost},
    keys::Host as KeysHost,
    notices::Host as NoticesHost,
    notices::Level,
    settings::Host as SettingsHost,
    settings::ScopedLevel,
    types::ErrorKind,
};
use sattr::{Caller, wasm};

/// What a component's imports reach, for EXTENSION acting for ORIGIN: the generated `Host` impls, the code a guest's
/// calls run.
fn wasm_api(api: &Arc<Mutex<Editor>>, extension: &str, origin: Origin) -> WasmApi<Editor> {
    WasmApi(
        Arc::clone(api),
        Arc::new(RwLock::new(Caller {
            extension: extension.to_string(),
            origin,
        })),
        LIMITS.max_list,
        Arc::new(Mutex::new(HandleTable::new(LIMITS.handles))),
    )
}

fn luau(api: &Arc<Mutex<Editor>>, extension: &str) -> LuauHost {
    LuauHost::new(api, extension, LIMITS).expect("the host starts")
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

/// A guest whose `init` calls `keys.bind("C-g", "ext.ping", "")` and traps unless the answer is the error `refused`.
fn binds_a_reserved_key() -> String {
    guest::core_module(
        r#"(import "drgnx:api/keys@0.1.0" "bind" (func $bind (param i32 i32 i32 i32 i32 i32 i32)))"#,
        r#"(data (i32.const 16) "C-g") (data (i32.const 32) "ext.ping")"#,
        // the result<_, error> lands at 64: the tag (1 = error), then the error's kind (3 = refused)
        r#"(call $bind (i32.const 16) (i32.const 3) (i32.const 32) (i32.const 8) (i32.const 48) (i32.const 0) (i32.const 64))
           (if (i32.ne (i32.load8_u (i32.const 64)) (i32.const 1)) (then unreachable))
           (if (i32.ne (i32.load8_u (i32.const 68)) (i32.const 3)) (then unreachable))"#,
    )
}

fn spec(id: &str, exposure: Exposure) -> CommandSpec {
    CommandSpec {
        id: id.into(),
        title: "Title".into(),
        doc: "Doc.".into(),
        args: vec![
            ArgSpec {
                name: "file".into(),
                kind: ArgKind::Path,
                required: true,
                doc: "the file".into(),
            },
            ArgSpec {
                name: "line".into(),
                kind: ArgKind::Number,
                required: false,
                doc: "the line".into(),
            },
        ],
        exposure,
    }
}

const REGISTER: &str = "drgnx.commands.register({ id = 'x', title = 'T', doc = 'D', args = {}, exposure = 'palette' })";

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
        "drgnx.ask.choose('t', 'b', {'x'}, 'x', 1.5)",
        "whole number",
    );
    refused(
        &h,
        "drgnx.ask.choose('t', 'b', {'x'}, 'x', 4294967296)",
        "outside",
    );
    refused(&h, "drgnx.notices.dismiss('7')", "expected a number");
    run(&h, "drgnx.notices.dismiss(9007199254740992)").expect("2^53 itself is exact");
    // the result direction: an id above 2^53 is an error, never a rounded number
    saman::lock(&api).next_question = 1 << 53;
    refused(
        &h,
        "drgnx.ask.choose('t', 'b', {'x'}, 'x', 1000)",
        "above 2^53",
    );
    saman::lock(&api).next_question = 6;
    run(
        &h,
        "assert(drgnx.ask.choose('t', 'b', {'x'}, 'x', 1000) == 7)",
    )
    .expect("a small id passes");
    // and what the host hands a script's function
    let ext = h
        .load(user(), "ext", "return { answered = function() end }")
        .expect("loads");
    let how = AnsweredHow::User;
    assert!(
        h.answered(user(), &ext, (1 << 53) + 1, "x", how).is_err(),
        "refused, not rounded"
    );
    h.answered(user(), &ext, 1 << 53, "x", how)
        .expect("2^53 passes");
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
    run(&h, &format!("assert({REGISTER} == true)")).expect("the real function still runs");
    assert!(saman::lock(&api).registry.get("ext/ro/x").is_some());
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

// 1 (caller identity), and 8: an extension's commands live in the registry, under its own name
#[test]
fn an_extensions_commands_are_namespaced_listed_and_cannot_clash_through_either_host() {
    let (api, _ex) = editor();
    let a = luau(&api, "a");
    let b = luau(&api, "b");
    run(&a, &format!("assert({REGISTER} == true)")).expect("a registers");
    run(&b, &format!("assert({REGISTER} == true)")).expect("b registers its own `x`");
    run(
        &a,
        &format!("local v, e = {REGISTER}; assert(v == nil and e.kind == 'conflict')"),
    )
    .expect("a's `x` is taken");
    let mut w = wasm_api(&api, "c", user());
    let r = CommandsHost::register(&mut w, spec("x", Exposure::Palette)).expect("no trap");
    assert!(r.is_ok());
    {
        let ed = saman::lock(&api);
        let ids: Vec<&str> = ed
            .registry
            .list()
            .filter(|c| c.id.0.starts_with("ext/"))
            .map(|c| c.id.0.as_str())
            .collect();
        assert_eq!(ids, ["ext/a/x", "ext/b/x", "ext/c/x"]);
    }
    // it lists with its args and exposure, as a record, in both hosts
    let r = CommandsHost::register(&mut w, spec("visit", Exposure::Extension)).expect("no trap");
    assert!(r.is_ok());
    let d = CommandsHost::describe(&mut w, "ext/c/visit".into())
        .expect("no trap")
        .expect("known");
    assert_eq!((d.id.as_str(), d.title.as_str()), ("ext/c/visit", "Title"));
    assert_eq!(d.args.len(), 2, "the list came back as it went in");
    assert_eq!(
        (d.args[0].name.as_str(), d.args[0].required),
        ("file", true)
    );
    assert!(matches!(d.exposure, Exposure::Extension));
    run(
        &a,
        "local d = drgnx.commands.describe('ext/a/x')
         assert(d.id == 'ext/a/x' and d.exposure == 'palette' and d.title == 'T' and d.doc == 'D')
         assert(type(d.args) == 'table' and #d.args == 0)",
    )
    .expect("a record comes back to Luau as a table");
    // a record that is not a record, or has a field of the wrong kind, is refused
    refused(&a, "drgnx.commands.register('x')", "expected a table");
    refused(
        &a,
        "drgnx.commands.register({ id = 'y', title = 'T', doc = 'D', args = {}, exposure = 'public' })",
        "not one of",
    );
    refused(
        &a,
        "drgnx.commands.register({ id = 'y', title = 1, doc = 'D', args = {}, exposure = 'palette' })",
        "expected a string",
    );
    // an argument line that is not `name: what it is`
    run(&a, "local v, e = drgnx.commands.register({ id = 'z', title = 'T', doc = 'D', args = { { name = '', kind = 'string', required = true, doc = 'd' } }, exposure = 'palette' }); assert(v == nil and e.kind == 'invalid' and e.message:find('name'))")
        .expect("a bad argument line");
}

// extension names: `a/b` + `x` and `a` + `b/x` cannot meet
#[test]
fn an_extension_name_that_could_collide_is_refused_by_both_hosts() {
    let (api, ex) = editor();
    for bad in ["a/b", "A", "a b", "", "a.b"] {
        assert!(LuauHost::new(&api, bad, LIMITS).is_err(), "`{bad}`");
    }
    let engine = wasm::engine().expect("engine");
    let linker = wasm::linker::<Editor>(&engine).expect("links");
    let clock = wasm::ticker(&ex, engine.clone());
    let component = guest::component(&engine, &guest::spin());
    let e =
        wasm::Guest::instantiate(&engine, &linker, &component, &api, "a/b", LIMITS, &clock).err();
    assert!(e.is_some(), "the component host refuses it too");
    // so an id with a slash in it is `ext/a/b/x`, the one command of `a`
    let a = luau(&api, "a");
    run(&a, "assert(drgnx.commands.register({ id = 'b/x', title = 'T', doc = 'D', args = {}, exposure = 'palette' }) == true)").expect("registers");
    assert!(saman::lock(&api).registry.get("ext/a/b/x").is_some());
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
    run(&h, "local v, e = drgnx.settings.set('editor.theme', '\"x\"', 'language', ''); assert(v == nil and e.kind == 'invalid')")
        .expect("an empty scope id");
    run(&h, "local v, e = drgnx.settings.set('nope', '1', 'pane', 'p'); assert(v == nil and e.kind == 'not-found' and e.message ~= '')")
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

// 8. an extension is told the level of a value, not the file it came from
#[test]
fn provenance_gives_an_extension_the_level_and_never_a_path() {
    let sb = raun::Sandbox::new();
    let (api, _ex) = editor();
    let path = sb.home().join("user.eld");
    eitri::replace_file(
        &path,
        b"(drgnx-settings :version 1\n (editor.theme \"dark\"))\n",
    )
    .expect("written");
    {
        let ed = saman::lock(&api);
        ed.settings
            .attach(skipan::Level::User, &path)
            .expect("attaches");
        ed.settings.reload().expect("reloads");
    }
    let h = luau(&api, "peek");
    run(
        &h,
        "assert(drgnx.settings.provenance('editor.theme') == 'user')",
    )
    .expect("the level, nothing else");
    let mut w = wasm_api(&api, "peek-wasm", user());
    let got = SettingsHost::provenance(&mut w, "editor.theme".into())
        .expect("no trap")
        .expect("known");
    assert_eq!(got, "user");
    assert!(!got.contains(path.to_string_lossy().as_ref()));
}

// 3. ask.choose never waits
#[test]
fn a_question_returns_at_once_has_a_capped_timeout_and_its_answer_comes_later() {
    let (api, ex) = editor();
    let h = luau(&api, "asker");
    // the longest allowed wait is five minutes, and the call does not wait for any of it
    run(
        &h,
        "assert(drgnx.ask.choose('t', 'b', {'a', 'b'}, 'a', 300000) == 1)",
    )
    .expect("returns the id");
    run(&h, "local v, e = drgnx.ask.choose('t', 'b', {'a'}, 'a', 0); assert(v == nil and e.kind == 'invalid')").expect("zero");
    run(&h, "local v, e = drgnx.ask.choose('t', 'b', {'a'}, 'a', 300001); assert(v == nil and e.kind == 'invalid')").expect("long");
    run(&h, "local v, e = drgnx.ask.choose('t', 'b', {'a'}, 'z', 1000); assert(v == nil and e.kind == 'invalid')").expect("a default that is no choice");
    // the answer (a headless editor answers the default) arrives through `answered`
    let ext = h
        .load(user(), "ext", "local E = {}; E.answered = function(q, c, how) E.last = q .. ':' .. c .. ':' .. how end; return E")
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
    assert_eq!(got[0].how, AnsweredHow::Default);
    h.answered(user(), &ext, got[0].question, &got[0].choice, got[0].how)
        .expect("delivers");
    assert_eq!(ext.get::<String>("last").expect("recorded"), "1:a:default");
    // an extension holds only a few questions at once
    for _ in 0..20 {
        run(&h, "assert(drgnx.ask.choose('t', 'b', {'a'}, 'a', 1000))").expect("within the cap");
    }
    run(&h, "local v, e = drgnx.ask.choose('t', 'b', {'a'}, 'a', 1000); assert(v == nil and e.kind == 'refused')").expect("over");
    // the component host's door
    let mut w = wasm_api(&api, "wasm-asker", user());
    let r = AskHost::choose(
        &mut w,
        "t".into(),
        "b".into(),
        vec!["a".into()],
        "a".into(),
        0,
    )
    .expect("no trap");
    assert!(r.is_err(), "zero is refused here too");
    let r = AskHost::choose(
        &mut w,
        "t".into(),
        "b".into(),
        vec!["a".into()],
        "a".into(),
        300_000,
    )
    .expect("no trap");
    assert!(r.is_ok());
}

// 7. a question that failed still tells the extension
#[test]
fn a_question_that_failed_is_delivered_as_cancelled() {
    struct Panics;
    impl spurn::Presenter for Panics {
        fn present(&self, _q: &spurn::Question, _reply: tokio::sync::oneshot::Sender<String>) {
            panic!("the UI broke while showing the question");
        }
    }
    let ex = Arc::new(saman::Executor::new(1).expect("a pool"));
    let api = Arc::new(Mutex::new(Editor::new(
        Arc::clone(&ex),
        Some(Arc::new(Panics)),
    )));
    let h = luau(&api, "asker");
    run(
        &h,
        "assert(drgnx.ask.choose('t', 'b', {'a'}, 'a', 1000) == 1)",
    )
    .expect("asks");
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
        (got[0].question, got[0].choice.as_str(), got[0].how),
        (1, "", AnsweredHow::Cancelled)
    );
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
    // b cannot touch a's notice, and is told why
    run(&b, "local v, e = drgnx.notices.dismiss(1); assert(v == nil and e.kind == 'refused' and e.message:find('not yours'))").expect("not b's");
    assert_eq!(saman::lock(&api).notices.len(), 2);
    run(&a, "assert(drgnx.notices.dismiss(1) == true)").expect("a's own");
    assert_eq!(saman::lock(&api).notices.len(), 1);
    // the cap: a holds twenty, the next is refused, and b is not affected
    for _ in 0..20 {
        run(&a, "assert(drgnx.notices.post('info', 'n', 'x', ''))").expect("within the cap");
    }
    run(&a, "local v, e = drgnx.notices.post('info', 'n', 'x', ''); assert(v == nil and e.kind == 'refused')").expect("over");
    run(&b, "assert(drgnx.notices.post('info', 'n', 'x', ''))").expect("b is its own");
    // the component host's door: another extension's id is not its to dismiss, and the message says so
    let mut w = wasm_api(&api, "c", user());
    let theirs = saman::lock(&api).notices.len();
    let e = NoticesHost::dismiss(&mut w, 2)
        .expect("no trap")
        .expect_err("refused");
    assert!(matches!(e.kind, ErrorKind::Refused));
    assert!(e.message.contains("not yours"), "{}", e.message);
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
           assert(v == nil and e.kind == 'refused', id)
         end",
    )
    .expect("the extension's door");
    // an agent has the extension run something: the agent's origin goes through, and no command opens both doors
    h.exec(
        Origin::Agent("a1".into()),
        "t",
        "for _, id in ipairs({'ext.ping', 'buffer.save', 'agent.echo'}) do
           local v, e = drgnx.commands.run(id, '')
           assert(v == nil and e.kind == 'refused', id)
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

// 8. an extension's command is in the registry: an agent cannot run it unless it is exposed to agents
#[test]
fn an_extension_cannot_open_a_command_to_agents_and_an_agent_cannot_run_the_others() {
    let (api, _ex) = editor();
    let h = luau(&api, "ext");
    for (id, exposure) in [("p", "palette"), ("e", "extension")] {
        run(&h, &format!("assert(drgnx.commands.register({{ id = '{id}', title = 'T', doc = 'D', args = {{ {{ name = 'q', kind = 'string', required = true, doc = 'a query' }} }}, exposure = '{exposure}' }}) == true)")).expect("registers");
    }
    // the user's approval, per extension, is what would open a command to agents: it does not exist yet, so it is refused
    run(
        &h,
        "local v, e = drgnx.commands.register({ id = 'a', title = 'T', doc = 'D', args = {}, exposure = 'agent' })
         assert(v == nil and e.kind == 'refused' and e.message:find('approval'), e.message)",
    )
    .expect("refused, naming the permission");
    let mut w = wasm_api(&api, "wasm-ext", user());
    let e = CommandsHost::register(&mut w, spec("a", Exposure::Agent))
        .expect("no trap")
        .expect_err("refused");
    assert!(matches!(e.kind, ErrorKind::Refused));
    assert!(e.message.contains("approval"), "{}", e.message);
    let mut ed = saman::lock(&api);
    assert!(ed.registry.get("ext/ext/a").is_none() && ed.registry.get("ext/wasm-ext/a").is_none());
    let by_agent = |ed: &Editor, id: &str| {
        ed.registry
            .run(id, serde_json::Value::Null, &mut bod::Cx::agent("a1"))
    };
    assert_eq!(
        by_agent(&ed, "ext/ext/p").expect_err("palette").kind(),
        villa::Kind::Refused
    );
    assert_eq!(
        by_agent(&ed, "ext/ext/e").expect_err("extension").kind(),
        villa::Kind::Refused
    );
    // no extension command is a tool; a running one queues a call for the extension's own host
    assert!(
        bod::tool_specs(&ed.registry)
            .iter()
            .all(|t| !t.name.starts_with("ext/"))
    );
    let mut by_ext = bod::Cx::through_extension(bod::Origin::User, "other");
    ed.registry
        .run("ext/ext/e", serde_json::Value::Null, &mut by_ext)
        .expect("runs for an extension");
    let calls = ed.take_invocations();
    assert_eq!(calls.len(), 1);
    assert_eq!(
        (calls[0].extension.as_str(), calls[0].id.as_str()),
        ("ext", "e")
    );
}

// 9 and 4. an extension binds no reserved key, shadows no prefix, and binds only commands it may
#[test]
fn keys_bind_only_what_the_extension_may_through_either_host() {
    let (api, _ex) = editor();
    saman::lock(&api)
        .keymap
        .bind("C-x C-f", "buffer.save", "")
        .expect("the user's chord");
    let h = luau(&api, "keys");
    let visit = REGISTER.replace("'x'", "'visit'");
    run(&h, &format!("assert({visit} == true)")).expect("a command of its own");
    run(
        &h,
        "for _, c in ipairs({'C-g', 'C-g C-x', 'M-x', 'ctrl+shift+p', 'f1'}) do
           local v, e = drgnx.keys.bind(c, 'ext.ping', '')
           assert(v == nil and e.kind == 'refused', c)
         end
         -- a prefix of a bound chord would shadow it
         local v, e = drgnx.keys.bind('C-x', 'ext.ping', ''); assert(v == nil and e.kind == 'refused')
         -- the editor's own command, and one that does not exist
         v, e = drgnx.keys.bind('C-c C-a', 'buffer.save', ''); assert(v == nil and e.kind == 'refused')
         v, e = drgnx.keys.bind('C-c C-b', 'nope', ''); assert(v == nil and e.kind == 'not-found')
         -- its own command, and one open to extensions
         assert(drgnx.keys.bind('C-c C-v', 'ext/keys/visit', '') == true)
         assert(drgnx.keys.bind('C-c C-p', 'ext.ping', '') == true)
         assert(drgnx.keys.resolve('C-c C-v', '') == 'ext/keys/visit')",
    )
    .expect("the rules");
    let mut w = wasm_api(&api, "wasm-keys", user());
    assert!(
        KeysHost::bind(&mut w, "C-g".into(), "ext.ping".into(), String::new())
            .expect("no trap")
            .is_err()
    );
    assert!(
        KeysHost::bind(&mut w, "C-x".into(), "ext.ping".into(), String::new())
            .expect("no trap")
            .is_err()
    );
    assert!(
        KeysHost::bind(
            &mut w,
            "C-c C-w".into(),
            "buffer.save".into(),
            String::new()
        )
        .expect("no trap")
        .is_err()
    );
    assert!(
        KeysHost::bind(&mut w, "C-c C-w".into(), "ext.ping".into(), String::new())
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
                id: bod::CommandId::from("ext.boom"),
                title: "Boom".to_string(),
                doc: "Panics.".to_string(),
                args: bod::ArgSpec::NONE,
                source: bod::SourceLoc {
                    file: file!().to_string(),
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
        "drgnx.commands.run('ext.ping', '')",
        "failed earlier",
    );
    refused(
        &h,
        "drgnx.notices.post('info', 'x', 'y', '')",
        "failed earlier",
    );
    let mut w = wasm_api(&api, "c", user());
    let e = CommandsHost::run(&mut w, "ext.ping".into(), String::new()).expect_err("a trap");
    assert!(e.to_string().contains("failed earlier"), "{e}");
}

#[test]
fn a_call_from_inside_a_call_is_refused_not_deadlocked() {
    let (api, _ex) = editor();
    let h = luau(&api, "busy");
    let held = saman::lock(&api);
    refused(&h, REGISTER, "busy");
    drop(held);
    run(&h, REGISTER).expect("free again");
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

// 11. an API failure is a record, with its message, in both hosts
#[test]
fn an_api_failure_is_a_record_with_a_message_and_a_misuse_is_raised() {
    let (api, _ex) = editor();
    let h = luau(&api, "contract");
    run(
        &h,
        "local v, e = drgnx.commands.find_source('nope')
         assert(v == nil and type(e) == 'table')
         assert(e.kind == 'not-found' and e.message ~= '', e.message)
         assert(type(drgnx.commands.find_source('buffer.save')) == 'string')",
    )
    .expect("the contract");
    refused(&h, "drgnx.commands.find_source()", "expected 1 argument");
    refused(&h, "drgnx.commands.find_source(1)", "expected a string");
    let mut w = wasm_api(&api, "c", user());
    let e = CommandsHost::find_source(&mut w, "nope".into())
        .expect("no trap")
        .expect_err("unknown");
    assert!(matches!(e.kind, ErrorKind::NotFound));
    assert!(!e.message.is_empty());
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
    let failure = call("return nil, { kind = 'refused', message = 'no thanks' }")
        .expect("a failure")
        .expect_err("is the error");
    assert_eq!(
        (failure.kind, failure.message.as_str()),
        (
            sattr::generated::drgnx_api_v0_1_0::types::ErrorKind::Refused,
            "no thanks"
        )
    );
    for bad in [
        "return true, 'refused'",
        "return nil",
        "return",
        "return nil, 'denied'",
        "return nil, { kind = 'nonsense', message = 'm' }",
        "return nil, { kind = 'refused' }",
        "return false",
        "return 1",
        "return true, true",
    ] {
        let e = call(bad)
            .err()
            .unwrap_or_else(|| panic!("`{bad}` must be refused"));
        let d = format!("{:?}", e.detail());
        assert!(
            d.contains("contract") || d.contains("expected") || d.contains("not one of"),
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
            "return { init = function() local v, e = drgnx.commands.run('ext.ping', ''); assert(v == '\"ran\"', e and e.message) end }",
        )
        .expect("loads");
    h.init(user(), &ext).expect("for the user: runs");
    assert!(
        h.init(Origin::Agent("a1".into()), &ext).is_err(),
        "for an agent: refused, and the assert raises"
    );
    h.init(user(), &ext).expect("the origin was restored");
}

// 3. a real guest calls an import: the linker routes it to the store's `WasmApi`, with the store's caller
#[test]
fn a_real_guest_is_refused_a_reserved_key_through_the_linker() {
    let (api, ex) = editor();
    let engine = wasm::engine().expect("engine");
    let linker = wasm::linker::<Editor>(&engine).expect("links");
    let clock = wasm::ticker(&ex, engine.clone());
    let component = guest::component(&engine, &binds_a_reserved_key());
    let mut g =
        wasm::Guest::instantiate(&engine, &linker, &component, &api, "guest", LIMITS, &clock)
            .expect("instantiates");
    // the guest traps unless `keys.bind("C-g", …)` answered with the error `refused`
    g.init(user())
        .expect("the import routed to the editor, which refused the key");
    assert!(
        saman::lock(&api).keymap.bindings().is_empty(),
        "nothing was bound"
    );
}

// 2. an origin from one call never reaches the next
#[test]
fn a_guests_origin_is_put_back_after_every_call_even_a_trapped_one() {
    let (api, ex) = editor();
    let engine = wasm::engine().expect("engine");
    let linker = wasm::linker::<Editor>(&engine).expect("links");
    let clock = wasm::ticker(&ex, engine.clone());
    let limits = sattr::Limits {
        steps: 50_000,
        ..LIMITS
    };
    let mut ok = wasm::Guest::instantiate(
        &engine,
        &linker,
        &guest::component(&engine, &binds_a_reserved_key()),
        &api,
        "first",
        limits,
        &clock,
    )
    .expect("instantiates");
    assert_eq!(ok.origin(), Origin::Extension("first".into()));
    ok.init(Origin::Agent("a1".into())).expect("runs");
    assert_eq!(
        ok.origin(),
        Origin::Extension("first".into()),
        "the agent's origin did not stay"
    );
    let mut stuck = wasm::Guest::instantiate(
        &engine,
        &linker,
        &guest::component(&engine, &guest::spin()),
        &api,
        "second",
        limits,
        &clock,
    )
    .expect("instantiates");
    assert!(
        stuck.init(Origin::Agent("a2".into())).is_err(),
        "out of fuel"
    );
    assert_eq!(
        stuck.origin(),
        Origin::Extension("second".into()),
        "restored after a trap too"
    );
    // and the fuel was renewed for the next call: the same guest runs out again, it does not start empty
    assert!(stuck.init(user()).is_err());
}

// 2. the fuel is renewed for every call: a guest that is cheap per call can be called again and again
#[test]
fn a_guests_fuel_is_renewed_for_each_call() {
    let (api, ex) = editor();
    let engine = wasm::engine().expect("engine");
    let linker = wasm::linker::<Editor>(&engine).expect("links");
    let clock = wasm::ticker(&ex, engine.clone());
    // enough for one call, far too little for two hundred if it were spent for good
    let limits = sattr::Limits {
        steps: 5_000,
        ..LIMITS
    };
    let component = guest::component(&engine, &binds_a_reserved_key());
    let mut g = wasm::Guest::instantiate(
        &engine, &linker, &component, &api, "thrifty", limits, &clock,
    )
    .expect("instantiates");
    for n in 0..200 {
        g.init(user()).unwrap_or_else(|e| panic!("call {n}: {e:?}"));
    }
}

// lists: a round trip, an empty list, and a list over the limit, in both hosts
#[test]
fn a_list_of_records_round_trips_may_be_empty_and_is_refused_over_the_limit_in_both_hosts() {
    let (api, _ex) = editor();
    let h = luau(&api, "lists");
    run(
        &h,
        "local args = { { name = 'file', kind = 'path', required = true, doc = 'the file' }, { name = 'line', kind = 'number', required = false, doc = 'the line' } }
         assert(drgnx.commands.register({ id = 'two', title = 'T', doc = 'D', args = args, exposure = 'palette' }) == true)
         local d = drgnx.commands.describe('ext/lists/two')
         assert(#d.args == 2)
         assert(d.args[1].name == 'file' and d.args[1].kind == 'path' and d.args[1].required == true and d.args[1].doc == 'the file')
         assert(d.args[2].name == 'line' and d.args[2].kind == 'number' and d.args[2].required == false)
         assert(drgnx.commands.register({ id = 'none', title = 'T', doc = 'D', args = {}, exposure = 'palette' }) == true)
         assert(#drgnx.commands.describe('ext/lists/none').args == 0)",
    )
    .expect("a list of records goes in and comes back, empty or not");
    // exactly the limit is fine, one more is not
    let many = |n: usize| {
        format!(
            "(function() local t = {{}} for i = 1, {n} do t[i] = {{ name = 'a' .. i, kind = 'string', required = true, doc = 'd' }} end return t end)()"
        )
    };
    let at = LIMITS.max_list;
    run(&h, &format!("assert(drgnx.commands.register({{ id = 'full', title = 'T', doc = 'D', args = {}, exposure = 'palette' }}) == true)", many(at))).expect("at the limit");
    refused(
        &h,
        &format!(
            "drgnx.commands.register({{ id = 'over', title = 'T', doc = 'D', args = {}, exposure = 'palette' }})",
            many(at + 1)
        ),
        "longer than",
    );
    refused(
        &h,
        "drgnx.commands.register({ id = 'bad', title = 'T', doc = 'D', args = 'a: b', exposure = 'palette' })",
        "expected a list",
    );
    refused(
        &h,
        "drgnx.commands.register({ id = 'bad', title = 'T', doc = 'D', args = { 1 }, exposure = 'palette' })",
        "expected a table",
    );
    refused(
        &h,
        "drgnx.commands.register({ id = 'bad', title = 'T', doc = 'D', args = { { name = 'a', kind = 'text', required = true, doc = '' } }, exposure = 'palette' })",
        "not one of",
    );
    run(&h, "local v, e = drgnx.commands.register({ id = 'nameless', title = 'T', doc = 'D', args = { { name = '', kind = 'string', required = true, doc = 'd' } }, exposure = 'palette' }); assert(v == nil and e.kind == 'invalid' and e.message:find('name'))")
        .expect("an argument needs a name");
    // the component host's door: the same round trip, the empty list, and a long list is refused
    let mut w = wasm_api(&api, "wasm-lists", user());
    let mut c = spec("two", Exposure::Palette);
    assert!(
        CommandsHost::register(&mut w, c.clone())
            .expect("no trap")
            .is_ok()
    );
    let d = CommandsHost::describe(&mut w, "ext/wasm-lists/two".into())
        .expect("no trap")
        .expect("known");
    assert_eq!(d.args.len(), c.args.len());
    for (got, sent) in d.args.iter().zip(&c.args) {
        assert_eq!(
            (got.name.as_str(), got.required, got.doc.as_str()),
            (sent.name.as_str(), sent.required, sent.doc.as_str())
        );
        assert_eq!(format!("{:?}", got.kind), format!("{:?}", sent.kind));
    }
    c.id = "none".into();
    c.args = Vec::new();
    assert!(
        CommandsHost::register(&mut w, c.clone())
            .expect("no trap")
            .is_ok()
    );
    assert!(
        CommandsHost::describe(&mut w, "ext/wasm-lists/none".into())
            .expect("no trap")
            .expect("known")
            .args
            .is_empty()
    );
    c.id = "huge".into();
    c.args = (0..10_000)
        .map(|i| ArgSpec {
            name: format!("a{i}"),
            kind: ArgKind::String,
            required: true,
            doc: "d".into(),
        })
        .collect();
    let e = CommandsHost::register(&mut w, c).expect_err("a trap");
    assert!(e.to_string().contains("longer than"), "{e}");
    assert!(
        saman::lock(&api)
            .registry
            .get("ext/wasm-lists/huge")
            .is_none()
    );
}

/// A guest whose `init` calls `commands.register` with N arguments, written into its own memory.
fn registers_n_arguments(n: u32) -> String {
    guest::core_module(
        r#"(import "drgnx:api/commands@0.1.0" "register" (func $register (param i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)))"#,
        r#"(data (i32.const 32) "x") (data (i32.const 40) "T") (data (i32.const 48) "D") (data (i32.const 56) "n") (data (i32.const 64) "d")"#,
        &format!(
            r#"(local $i i32)
           (loop $fill
             ;; an arg-spec is 20 bytes: name (ptr, len), kind (u8), required (u8), doc (ptr, len)
             (i32.store (i32.add (i32.const 1024) (i32.mul (local.get $i) (i32.const 20))) (i32.const 56))
             (i32.store (i32.add (i32.const 1028) (i32.mul (local.get $i) (i32.const 20))) (i32.const 1))
             (i32.store8 (i32.add (i32.const 1032) (i32.mul (local.get $i) (i32.const 20))) (i32.const 0))
             (i32.store8 (i32.add (i32.const 1033) (i32.mul (local.get $i) (i32.const 20))) (i32.const 1))
             (i32.store (i32.add (i32.const 1036) (i32.mul (local.get $i) (i32.const 20))) (i32.const 64))
             (i32.store (i32.add (i32.const 1040) (i32.mul (local.get $i) (i32.const 20))) (i32.const 1))
             (local.set $i (i32.add (local.get $i) (i32.const 1)))
             (br_if $fill (i32.lt_u (local.get $i) (i32.const {n}))))
           (call $register (i32.const 32) (i32.const 1) (i32.const 40) (i32.const 1) (i32.const 48) (i32.const 1)
                           (i32.const 1024) (i32.const {n}) (i32.const 0) (i32.const 4096))
           ;; the result<_, error> at 4096: its tag must be `ok`
           (if (i32.ne (i32.load8_u (i32.const 4096)) (i32.const 0)) (then unreachable))"#
        ),
    )
}

// 2. a real guest lowers a list of records: up to the limit it registers, beyond it the import traps
#[test]
fn a_real_guest_sends_a_list_of_records_up_to_the_limit_and_no_further() {
    let (api, ex) = editor();
    let engine = wasm::engine().expect("engine");
    let linker = wasm::linker::<Editor>(&engine).expect("links");
    let clock = wasm::ticker(&ex, engine.clone());
    let at = LIMITS.max_list as u32;
    let mut ok = wasm::Guest::instantiate(
        &engine,
        &linker,
        &guest::component(&engine, &registers_n_arguments(at)),
        &api,
        "list-ok",
        LIMITS,
        &clock,
    )
    .expect("instantiates");
    ok.init(user())
        .expect("the guest's own call registered the command");
    let n = saman::lock(&api)
        .registry
        .get("ext/list-ok/x")
        .map(|c| c.args.args.len());
    assert_eq!(n, Some(at as usize));
    let mut big = wasm::Guest::instantiate(
        &engine,
        &linker,
        &guest::component(&engine, &registers_n_arguments(at + 1)),
        &api,
        "list-big",
        LIMITS,
        &clock,
    )
    .expect("instantiates");
    let e = big.init(user()).expect_err("the import trapped");
    assert!(format!("{:?}", e.detail()).contains("longer than"), "{e:?}");
    assert!(saman::lock(&api).registry.get("ext/list-big/x").is_none());
}

// 4. a profile layered after an extension's binding: the binding that would now shadow a prefix is dropped, with a notice
#[test]
fn a_profile_layered_later_drops_an_extension_binding_that_would_shadow_it_and_says_so() {
    let (api, _ex) = editor();
    let h = luau(&api, "vimm");
    run(
        &h,
        "assert(drgnx.commands.register({ id = 'yank', title = 'T', doc = 'D', args = {}, exposure = 'palette' }) == true)
         assert(drgnx.keys.bind('C-y', 'ext/vimm/yank', '') == true)
         assert(drgnx.keys.resolve('C-y', '') == 'ext/vimm/yank')",
    )
    .expect("the binding is allowed when it is made");
    let (profile, problems) =
        lykill::Profile::parse("mine", b"(drgnx-keys :version 1\n (paste \"C-y C-z\"))\n")
            .expect("parses");
    assert!(problems.is_empty());
    saman::lock(&api).layer_profile(&profile);
    run(
        &h,
        "assert(drgnx.keys.resolve('C-y', '') == 'prefix', 'C-y now waits for C-z')
             assert(drgnx.keys.resolve('C-y C-z', '') == 'paste')",
    )
    .expect("the profile won");
    let ed = saman::lock(&api);
    let rows = ed.notices.rows();
    assert_eq!(rows.len(), 1, "the user was told");
    assert!(
        rows[0].text.contains("dropped") && rows[0].text.contains("vimm"),
        "{}",
        rows[0].text
    );
}

// Wave 7: a refused binding is kept and offered another key; the user's choice goes to the user's level, not the extension
struct Types(&'static str);
impl sattr::editor::ChordPrompt for Types {
    fn chord(&self, _command: &str) -> Option<String> {
        Some(self.0.to_string())
    }
}

#[test]
fn a_refused_binding_is_rebound_by_the_user_without_changing_the_extension() {
    let (api, _ex) = editor();
    let a = luau(&api, "aa");
    let b = luau(&api, "bb");
    run(
        &a,
        "assert(drgnx.commands.register({ id = 'yank', title = 'T', doc = 'D', args = {}, exposure = 'palette' }))
         assert(drgnx.keys.bind('C-y', 'ext/aa/yank', '') == true)",
    )
    .expect("A binds");
    let bind_clash = "assert(drgnx.commands.register({ id = 'zap', title = 'T', doc = 'D', args = {}, exposure = 'palette' }))
         local v, e = drgnx.keys.bind('C-y C-z', 'ext/bb/zap', '')
         assert(v == nil and e.kind == 'refused')";
    run(&b, bind_clash).expect("B's clash is refused");
    // the notice offers "Bind to another key…"
    let (id, label) = {
        let ed = saman::lock(&api);
        assert_eq!(ed.notices.len(), 1);
        let id = tidindi::NoticeId(1);
        let n = ed.notices.get(id).expect("the notice");
        (id, n.actions[0].label.clone())
    };
    assert_eq!(label, "Bind to another key…");
    saman::lock(&api)
        .run_notice_action(id, sattr::editor::REBIND_ACTION, &Types("C-c z"))
        .expect("the user rebinds");
    run(
        &b,
        "assert(drgnx.keys.resolve('C-c z', '') == 'ext/bb/zap')
         assert(drgnx.keys.resolve('C-y C-z', '') == '')
         assert(drgnx.keys.resolve('C-y', '') == 'ext/aa/yank')",
    )
    .expect("the command runs on the new chord");
    assert!(saman::lock(&api).notices.is_empty(), "the notice is done");
    // B reloads: the same request meets the override, and nothing is refused
    saman::lock(&api).keymap.unload_extension("bb");
    run(
        &b,
        "assert(drgnx.keys.bind('C-y C-z', 'ext/bb/zap', '') == true)
         assert(drgnx.keys.resolve('C-c z', '') == 'ext/bb/zap')",
    )
    .expect("the override survives the reload");
    assert!(
        saman::lock(&api)
            .keymap
            .bindings()
            .iter()
            .all(|b| !matches!(&b.by, Some(Origin::Extension(e)) if e == "bb")),
        "nothing of the extension's own is in force: the choice is the user's"
    );
}
