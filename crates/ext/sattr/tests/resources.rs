//! Resource types, generated from a test world (tests/wit-res: the real API has no resource yet) and run in both hosts:
//! a Luau script holding generated userdata, and a real component holding handles. Create, use, drop; a handle after its
//! drop, another extension's handle and another type's handle are refused; the cap; the unload that drains and tells the
//! editor once per handle.

use std::collections::BTreeMap;

use sattr::Limits;
use std::sync::{Arc, Mutex, RwLock};

use wasmtime::component::{Component, Linker, Resource};
use wasmtime::{Engine, Store};
use wit_component::{ComponentEncoder, StringEncoding, embed_component_metadata};
use wit_parser::{Resolve, UnresolvedPackageGroup};

#[allow(dead_code)]
mod common;
#[path = "common/guest.rs"]
mod guest;

use common::{LIMITS, editor};

mod b {
    wasmtime::component::bindgen!({
        path: "tests/wit-res",
        world: "w",
        imports: { default: trappable },
    });
}

#[allow(dead_code)]
mod g {
    include!(concat!(env!("OUT_DIR"), "/res_gen.rs"));
}

use g::acme_res_v1_0_0::r::Oops;

#[derive(Clone, Debug)]
pub struct C;

pub struct S<A> {
    pub api: g::WasmApi<A>,
}

/// The editor behind the fixture: what each rep holds, and what it was told.
#[derive(Default)]
struct Fake {
    next: u64,
    counters: BTreeMap<u64, u32>,
    gauges: BTreeMap<u64, u32>,
    /// every call that reached a method
    calls: u32,
    /// (type, rep) of each `*_dropped`
    dropped: Vec<(&'static str, u64)>,
    /// a rep whose `counter_dropped` panics (what an editor bug does at unload)
    panic_on: Option<u64>,
}

impl g::acme_res_v1_0_0::r::Api for Fake {
    fn counter_new(&mut self, _c: &C, start: u32) -> u64 {
        self.next += 1;
        self.counters.insert(self.next, start);
        self.next
    }

    fn counter_bump(&mut self, _c: &C, rep: u64, by: u32) -> u32 {
        self.calls += 1;
        let v = self.counters.get_mut(&rep).expect("a live counter");
        *v += by;
        *v
    }

    fn counter_value(&mut self, _c: &C, rep: u64) -> u32 {
        self.calls += 1;
        self.counters[&rep]
    }

    fn counter_check(&mut self, _c: &C, rep: u64, limit: u32) -> Result<u32, Oops> {
        self.calls += 1;
        let v = self.counters[&rep];
        if v > limit { Err(Oops::TooBig) } else { Ok(v) }
    }

    fn counter_dropped(&mut self, _c: &C, rep: u64) {
        assert_ne!(self.panic_on, Some(rep), "the editor failed on this one");
        self.counters.remove(&rep);
        self.dropped.push(("counter", rep));
    }

    fn gauge_new(&mut self, _c: &C) -> u64 {
        self.next += 1;
        self.gauges.insert(self.next, 9);
        self.next
    }

    fn gauge_level(&mut self, _c: &C, rep: u64) -> u32 {
        self.calls += 1;
        self.gauges[&rep]
    }

    fn gauge_dropped(&mut self, _c: &C, rep: u64) {
        self.gauges.remove(&rep);
        self.dropped.push(("gauge", rep));
    }
}

type Handles = Arc<Mutex<g::rt::HandleTable>>;

fn handles(cap: usize) -> Handles {
    Arc::new(Mutex::new(g::rt::HandleTable::new(cap)))
}

/// A Luau state with the fixture installed, for one extension.
struct Script {
    lua: mlua::Lua,
    api: Arc<Mutex<Fake>>,
    caller: Arc<RwLock<C>>,
    handles: Handles,
}

impl Script {
    fn new(cap: usize) -> Self {
        let lua = mlua::Lua::new();
        let api = Arc::new(Mutex::new(Fake::default()));
        let caller = Arc::new(RwLock::new(C));
        let handles = handles(cap);
        g::install_luau(&lua, &api, &caller, &handles, 16).expect("installs");
        Script {
            lua,
            api,
            caller,
            handles,
        }
    }

    fn run(&self, src: &str) -> mlua::Result<()> {
        self.lua.load(src).exec()
    }

    fn unload(&self) -> usize {
        g::drain_handles(&self.api, &self.caller, &self.handles)
    }

    fn fake<R>(&self, f: impl FnOnce(&Fake) -> R) -> R {
        f(&saman::lock(&self.api))
    }
}

fn refused(s: &Script, src: &str, about: &str) {
    let e = s.run(src).expect_err(src);
    assert!(
        e.to_string().contains(about),
        "`{src}`: {e} does not say `{about}`"
    );
}

// ---- Luau

#[test]
fn luau_creates_uses_and_drops_a_resource() {
    let s = Script::new(8);
    s.run(
        r#"
        local c = res.r.counter.new(5)
        assert(c:bump(2) == 7)
        assert(c:value() == 7)
        local v, e = c:check(3)
        assert(v == nil and e == "too-big")
        assert(c:check(10) == 7)
        c:drop()
        "#,
    )
    .expect("the script");
    s.fake(|f| {
        assert_eq!(f.dropped, [("counter", 1)], "the editor was told once");
        assert!(f.counters.is_empty());
    });
    assert_eq!(saman::lock(&s.handles).live(), 0);
}

#[test]
fn luau_refuses_a_handle_after_its_drop_and_a_second_drop() {
    let s = Script::new(8);
    s.run("c = res.r.counter.new(1); c:drop()")
        .expect("created, dropped");
    let calls = s.fake(|f| f.calls);
    refused(&s, "c:bump(1)", "dropped");
    refused(&s, "c:value()", "dropped");
    refused(&s, "c:drop()", "dropped");
    s.fake(|f| {
        assert_eq!(f.calls, calls, "a refused call reaches nothing");
        assert_eq!(
            f.dropped.len(),
            1,
            "a second drop does not tell the editor again"
        );
    });
    // the freed slot is reused by the next handle; the old one stays dead
    s.run("d = res.r.counter.new(2); assert(d:value() == 2)")
        .expect("a new handle");
    refused(&s, "c:value()", "dropped");
}

#[test]
fn luau_does_not_read_a_gauge_as_a_counter() {
    let s = Script::new(8);
    s.run("c = res.r.counter.new(1); g = res.r.gauge.new(); assert(g:level() == 9)")
        .expect("both");
    // the counter's method on the gauge: refused by type, and the gauge is still alive
    refused(&s, "local f = c.bump; f(g, 1)", "");
    s.run("assert(g:level() == 9)").expect("still valid");
    s.run("g:drop(); c:drop()").expect("drops");
    s.fake(|f| {
        assert_eq!(
            f.dropped,
            [("gauge", 2), ("counter", 1)],
            "each dropped as its own type"
        )
    });
}

#[test]
fn luau_refuses_a_handle_of_another_extension() {
    let a = Script::new(8);
    a.run("c = res.r.counter.new(1)").expect("a's handle");
    // a second extension installed in the same state: a's handle is now somebody else's to this API
    let other_api = Arc::new(Mutex::new(Fake::default()));
    let other_handles = handles(8);
    g::install_luau(&a.lua, &other_api, &a.caller, &other_handles, 16).expect("installs");
    refused(&a, "c:bump(1)", "belongs to another extension");
    refused(&a, "c:value()", "belongs to another extension");
    refused(&a, "c:drop()", "belongs to another extension");
    a.fake(|f| {
        assert_eq!(f.calls, 0, "a's editor state was not touched");
        assert!(f.dropped.is_empty());
    });
    assert_eq!(saman::lock(&a.handles).live(), 1, "a still holds it");
    assert_eq!(saman::lock(&other_handles).live(), 0);
    assert_eq!(saman::lock(&other_api).calls, 0);
    // the other extension's own handles work, and a's are unloaded by a's table
    a.run("d = res.r.counter.new(10); assert(d:value() == 10)")
        .expect("its own");
    assert_eq!(saman::lock(&other_handles).live(), 1);
    assert_eq!(a.unload(), 1);
}

#[test]
fn luau_refuses_the_4097th_handle_with_the_number() {
    let s = Script::new(4096);
    s.run("held = {}; for i = 1, 4096 do held[i] = res.r.counter.new(i) end")
        .expect("4096");
    assert_eq!(saman::lock(&s.handles).live(), 4096);
    refused(&s, "res.r.counter.new(0)", "4096 handles");
    refused(&s, "res.r.gauge.new()", "4096 handles");
    s.fake(|f| {
        assert_eq!(
            f.counters.len(),
            4096,
            "the refused one was never made in the editor"
        );
        assert!(
            f.dropped.is_empty(),
            "and the editor was never asked to undo it"
        );
    });
    // dropping one makes room
    s.run("held[1]:drop(); res.r.counter.new(0)")
        .expect("room again");
}

#[test]
fn unload_drains_every_live_handle_and_tells_the_editor_once_each() {
    let s = Script::new(8);
    s.run("a = res.r.counter.new(1); b = res.r.counter.new(2); g = res.r.gauge.new(); a:drop()")
        .expect("three made, one dropped");
    assert_eq!(s.unload(), 2, "the two live ones");
    s.fake(|f| {
        let mut d = f.dropped.clone();
        d.sort_unstable();
        assert_eq!(
            d,
            [("counter", 1), ("counter", 2), ("gauge", 3)],
            "each once"
        );
        assert!(f.counters.is_empty() && f.gauges.is_empty());
    });
    assert_eq!(s.unload(), 0, "a second unload has nothing left");
    refused(&s, "b:value()", "dropped");
    refused(&s, "g:drop()", "dropped");
    // and the state going away afterwards does not tell the editor again
    let api = Arc::clone(&s.api);
    drop(s);
    assert_eq!(saman::lock(&api).dropped.len(), 3);
}

#[test]
fn luau_garbage_collection_drops_a_handle_nothing_holds() {
    let s = Script::new(8);
    s.run("local function make() local c = res.r.counter.new(1); c:bump(1) end make(); collectgarbage('collect'); collectgarbage('collect')")
        .expect("made and let go");
    s.fake(|f| assert_eq!(f.dropped, [("counter", 1)]));
    assert_eq!(saman::lock(&s.handles).live(), 0);
    // a handle still held is not collected
    s.run("keep = res.r.counter.new(1); collectgarbage('collect')")
        .expect("held");
    s.fake(|f| assert_eq!(f.dropped.len(), 1));
}

#[test]
fn luau_a_drop_that_finds_the_api_busy_is_told_later() {
    let s = Script::new(8);
    s.run("c = res.r.counter.new(1)").expect("made");
    {
        // the API is in use (a call in flight): the collector cannot tell the editor now
        let busy = saman::lock(&s.api);
        s.run("c = nil; collectgarbage('collect')")
            .expect("released");
        assert!(busy.dropped.is_empty());
    }
    assert_eq!(
        saman::lock(&s.handles).live(),
        0,
        "the handle is gone at once"
    );
    s.run("res.r.gauge.new()").expect("the next call");
    s.fake(|f| assert_eq!(f.dropped, [("counter", 1)], "told on the next call, once"));
}

// ---- components

/// A guest that imports the resources' canonical ABI and exports `e`: it keeps one handle in a global.
const GUEST: &str = r#"(module
  (import "acme:res/r@1.0.0" "[constructor]counter" (func $new (param i32) (result i32)))
  (import "acme:res/r@1.0.0" "[method]counter.bump" (func $bump (param i32 i32) (result i32)))
  (import "acme:res/r@1.0.0" "[resource-drop]counter" (func $rdrop (param i32)))
  (global $h (mut i32) (i32.const 0))
  (memory (export "memory") 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 256))
  (func (export "acme:res/e@1.0.0#make") (param i32) (global.set $h (call $new (local.get 0))))
  (func (export "acme:res/e@1.0.0#bump") (param i32) (result i32) (call $bump (global.get $h) (local.get 0)))
  (func (export "acme:res/e@1.0.0#drop") (call $rdrop (global.get $h)))
  (func (export "acme:res/e@1.0.0#make-n") (param i32)
    (loop $l
      (if (local.get 0) (then
        (drop (call $new (i32.const 0)))
        (local.set 0 (i32.sub (local.get 0) (i32.const 1)))
        (br $l)))))
  (func (export "acme:res/e@1.0.0#poke") (param i32) (result i32) (call $bump (local.get 0) (i32.const 0))))"#;

fn component(engine: &Engine) -> Component {
    let mut module = wat::parse_str(GUEST).expect("the core module parses");
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/wit-res");
    let group = UnresolvedPackageGroup::parse_dir(&dir).expect("the WIT parses");
    let mut resolve = Resolve::new();
    let pkg = resolve.push_group(group).expect("the WIT resolves");
    let world = resolve.select_world(&[pkg], Some("w")).expect("the world");
    embed_component_metadata(&mut module, &resolve, world, StringEncoding::UTF8).expect("metadata");
    let bytes = ComponentEncoder::default()
        .module(&module)
        .expect("the module")
        .validate(true)
        .encode()
        .expect("encodes");
    Component::new(engine, bytes).expect("a component")
}

/// One instantiated guest, with the pieces an unload needs.
struct Guest {
    store: Store<S<Fake>>,
    ext: b::W,
    api: Arc<Mutex<Fake>>,
    caller: Arc<RwLock<C>>,
    handles: Handles,
}

impl Guest {
    fn new(cap: usize) -> Self {
        Self::sharing(cap, Arc::new(Mutex::new(Fake::default())))
    }

    /// A guest of the same editor as another one (two extensions, one API).
    fn sharing(cap: usize, api: Arc<Mutex<Fake>>) -> Self {
        let engine = Engine::default();
        let component = component(&engine);
        let mut linker = Linker::<S<Fake>>::new(&engine);
        g::wasm_link::<Fake>(&mut linker).expect("links");
        let caller = Arc::new(RwLock::new(C));
        let handles = handles(cap);
        let mut store = Store::new(
            &engine,
            S {
                api: g::WasmApi(
                    Arc::clone(&api),
                    Arc::clone(&caller),
                    16,
                    Arc::clone(&handles),
                ),
            },
        );
        let ext = b::W::instantiate(&mut store, &component, &linker).expect("instantiates");
        Guest {
            store,
            ext,
            api,
            caller,
            handles,
        }
    }

    fn make(&mut self, start: u32) -> wasmtime::Result<()> {
        g::acme_res_v1_0_0::exports::e::wasm_make(&mut self.store, &self.ext, start)
    }

    fn bump(&mut self, by: u32) -> wasmtime::Result<u32> {
        g::acme_res_v1_0_0::exports::e::wasm_bump(&mut self.store, &self.ext, by)
    }

    fn drop_it(&mut self) -> wasmtime::Result<()> {
        g::acme_res_v1_0_0::exports::e::wasm_drop(&mut self.store, &self.ext)
    }

    fn make_n(&mut self, n: u32) -> wasmtime::Result<()> {
        g::acme_res_v1_0_0::exports::e::wasm_make_n(&mut self.store, &self.ext, n)
    }

    fn poke(&mut self, h: u32) -> wasmtime::Result<u32> {
        g::acme_res_v1_0_0::exports::e::wasm_poke(&mut self.store, &self.ext, h)
    }

    fn unload(&self) -> usize {
        g::drain_handles(&self.api, &self.caller, &self.handles)
    }

    fn fake<R>(&self, f: impl FnOnce(&Fake) -> R) -> R {
        f(&saman::lock(&self.api))
    }
}

#[test]
fn a_component_creates_uses_and_drops_a_resource() {
    let mut g = Guest::new(8);
    g.make(5).expect("created");
    assert_eq!(g.bump(2).expect("used"), 7);
    assert_eq!(saman::lock(&g.handles).live(), 1);
    g.drop_it().expect("dropped");
    g.fake(|f| {
        assert_eq!(f.dropped, [("counter", 1)], "the editor was told once");
        assert!(f.counters.is_empty());
    });
    assert_eq!(saman::lock(&g.handles).live(), 0);
}

#[test]
fn a_component_handle_after_its_drop_is_refused() {
    let mut g = Guest::new(8);
    g.make(5).expect("created");
    g.drop_it().expect("dropped");
    let calls = g.fake(|f| f.calls);
    g.bump(1).expect_err("the dropped handle");
    g.fake(|f| {
        assert_eq!(f.calls, calls, "a refused call reaches nothing");
        assert_eq!(f.dropped.len(), 1);
    });
}

#[test]
fn a_component_cannot_name_a_handle_it_was_never_given() {
    // one editor, two extensions: A holds a handle, B calls with raw numbers
    let api = Arc::new(Mutex::new(Fake::default()));
    let mut ga = Guest::sharing(8, Arc::clone(&api));
    let mut gb = Guest::sharing(8, Arc::clone(&api));
    ga.make(5).expect("a's handle");
    let calls = ga.fake(|f| f.calls);
    for raw in [0, 1, 2, 4096, u32::MAX] {
        // each probe traps its guest, so each gets a fresh one
        let mut probe = Guest::sharing(8, Arc::clone(&api));
        probe
            .poke(raw)
            .expect_err("a number the guest was never given");
    }
    gb.poke(1).expect_err("b has no handle 1 even though a has");
    ga.fake(|f| assert_eq!(f.calls, calls, "a's counter was never reached"));
    // the generated host itself, asked for a's slot in b's empty table
    use b::acme::res::r::{Counter, Gauge, HostCounter, HostGauge};
    let mut w = g::WasmApi(Arc::clone(&api), Arc::new(RwLock::new(C)), 16, handles(8));
    let e =
        HostCounter::bump(&mut w, Resource::<Counter>::new_borrow(0), 1).expect_err("empty table");
    assert!(e.to_string().contains("dropped"), "{e}");
    // and a handle of the other type, in a table that does hold it
    let mut w = g::WasmApi(Arc::clone(&api), Arc::new(RwLock::new(C)), 16, handles(8));
    let own = HostCounter::new(&mut w, 3).expect("made");
    let e = HostGauge::level(&mut w, Resource::<Gauge>::new_borrow(own.rep()))
        .expect_err("a counter is no gauge");
    assert!(e.to_string().contains("another resource type"), "{e}");
    assert_eq!(
        HostCounter::bump(&mut w, Resource::new_borrow(own.rep()), 1).expect("still valid"),
        4
    );
}

#[test]
fn a_component_may_hold_4096_handles_and_the_4097th_is_refused_with_the_number() {
    let mut g = Guest::new(4096);
    g.make_n(4096).expect("4096");
    assert_eq!(saman::lock(&g.handles).live(), 4096);
    let e = g.make_n(1).expect_err("the 4097th");
    assert!(format!("{e:#}").contains("4096 handles"), "{e:#}");
    g.fake(|f| {
        assert_eq!(
            f.counters.len(),
            4096,
            "the refused one was never made in the editor"
        );
        assert!(
            f.dropped.is_empty(),
            "and the editor was never asked to undo it"
        );
    });
}

#[test]
fn a_component_unload_drains_every_live_handle_and_tells_the_editor_once_each() {
    let mut g = Guest::new(8);
    g.make_n(2).expect("two leaked");
    g.make(5).expect("one kept");
    assert_eq!(g.unload(), 3);
    g.fake(|f| {
        let mut d = f.dropped.clone();
        d.sort_unstable();
        assert_eq!(
            d,
            [("counter", 1), ("counter", 2), ("counter", 3)],
            "each once"
        );
        assert!(f.counters.is_empty());
    });
    assert_eq!(g.unload(), 0);
    assert_eq!(saman::lock(&g.handles).live(), 0);
}

// ---- what the setups hub builds on (docs/specs/drgnx/2026-11-23-setups-hub-design.md section 0)

#[test]
fn unload_tells_every_handle_even_when_the_editor_fails_on_one() {
    let s = Script::new(8);
    s.run("a = res.r.counter.new(1); b = res.r.counter.new(2); c = res.r.counter.new(3)")
        .expect("three");
    saman::lock(&s.api).panic_on = Some(2);
    // the panic is the editor's: unload still tells the others, and nothing is left in the table
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| s.unload()));
    assert_eq!(r.expect("the unload itself does not panic"), 3);
    assert_eq!(saman::lock(&s.handles).live(), 0);
    s.fake(|f| {
        let mut d = f.dropped.clone();
        d.sort_unstable();
        assert_eq!(
            d,
            [("counter", 1), ("counter", 3)],
            "the two that did not fail"
        );
    });
}

#[test]
fn dropping_a_host_unloads_it_and_two_hosts_of_one_name_never_share_handles() {
    use sattr::luau::LuauHost;
    let (api, _ex) = editor();
    let one = LuauHost::new(&api, "same-name", LIMITS).expect("starts");
    let two = LuauHost::new(&api, "same-name", LIMITS).expect("starts");
    assert!(
        !Arc::ptr_eq(one.handles(), two.handles()),
        "each instance has its own table, whatever its name"
    );
    saman::lock(one.handles()).insert(0, 7).expect("room");
    assert_eq!(
        saman::lock(two.handles()).live(),
        0,
        "the other instance does not see it"
    );
    assert_eq!(two.unload(), 0);
    assert_eq!(
        saman::lock(one.handles()).live(),
        1,
        "and its unload does not touch it"
    );
    let held = Arc::clone(one.handles());
    drop(one);
    assert_eq!(
        saman::lock(&held).live(),
        0,
        "dropping the host drains its table"
    );
}

#[test]
fn the_cap_is_the_hosts_limit_and_no_wit_function_can_change_it_or_install_anything() {
    use sattr::luau::LuauHost;
    let (api, _ex) = editor();
    let tight = Limits {
        handles: 2,
        ..LIMITS
    };
    let h = LuauHost::new(&api, "tight", tight).expect("starts");
    assert_eq!(
        saman::lock(h.handles()).cap(),
        2,
        "the table is held to Limits.handles"
    );
    // the API an extension reaches has no function that touches limits, installs, or reads trust
    let wit = eitri::read_string(
        &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../mal/drgnx.wit"),
        1 << 20,
    )
    .expect("the WIT");
    for word in [
        "limit",
        "handles",
        "install",
        "trust",
        "grant",
        "permission",
    ] {
        assert!(
            !wit.lines()
                .filter(|l| !l.trim_start().starts_with("//"))
                .any(|l| l.to_lowercase().contains(word)),
            "the API's WIT must not offer `{word}`"
        );
    }
}

#[test]
fn the_real_component_host_holds_the_cap_and_drains_when_dropped() {
    let (api, ex) = editor();
    let engine = sattr::wasm::engine().expect("the engine");
    let component = guest::component(&engine, &guest::spin());
    let linker = sattr::wasm::linker::<sattr::editor::Editor>(&engine).expect("links");
    let clock = sattr::wasm::ticker(&ex, engine.clone());
    let limits = Limits {
        handles: 2,
        ..LIMITS
    };
    let g = sattr::wasm::Guest::instantiate(
        &engine, &linker, &component, &api, "holder", limits, &clock,
    )
    .expect("instantiates");
    let table = Arc::clone(g.handles());
    assert_eq!(
        saman::lock(&table).cap(),
        2,
        "the table is held to Limits.handles"
    );
    saman::lock(&table).insert(0, 1).expect("room");
    saman::lock(&table).insert(0, 2).expect("room");
    saman::lock(&table).insert(0, 3).expect_err("a third");
    assert_eq!(g.unload(), 2);
    saman::lock(&table).insert(0, 4).expect("room again");
    drop(g);
    assert_eq!(
        saman::lock(&table).live(),
        0,
        "dropping the guest drains its table"
    );
}
