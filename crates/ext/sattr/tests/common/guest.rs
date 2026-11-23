//! Real guests for the tests: a core module written as text, wrapped into a component against the `drgnx:api` world
//! with wit-component (the same step a guest toolchain takes), so that it imports and exports exactly what the WIT says.

use std::path::Path;

use wasmtime::Engine;
use wasmtime::component::Component;
use wit_component::{ComponentEncoder, StringEncoding, embed_component_metadata};
use wit_parser::{Resolve, UnresolvedPackageGroup};

/// A core module whose `init` runs BODY (and whose other exports do nothing). IMPORTS are extra core imports.
pub fn core_module(imports: &str, data: &str, init: &str) -> String {
    format!(
        r#"(module
  {imports}
  (memory (export "memory") 1)
  {data}
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 256))
  (func (export "drgnx:api/entry@0.1.0#init") {init})
  (func (export "drgnx:api/entry@0.1.0#run") (param i32 i32) (result i32) (i32.const 512))
  (func (export "drgnx:api/entry@0.1.0#answered") (param i64 i32 i32 i32)))"#
    )
}

/// The component of CORE_WAT.
pub fn component(engine: &Engine, core_wat: &str) -> Component {
    let mut module = wat::parse_str(core_wat).expect("the core module parses");
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../mal");
    let group = UnresolvedPackageGroup::parse_dir(&dir).expect("the WIT parses");
    let mut resolve = Resolve::new();
    let pkg = resolve.push_group(group).expect("the WIT resolves");
    let world = resolve
        .select_world(&[pkg], Some("extension"))
        .expect("the world");
    embed_component_metadata(&mut module, &resolve, world, StringEncoding::UTF8).expect("metadata");
    let bytes = ComponentEncoder::default()
        .module(&module)
        .expect("the module")
        .validate(true)
        .encode()
        .expect("encodes");
    Component::new(engine, bytes).expect("the guest is a component")
}

/// A guest whose `init` never ends.
pub fn spin() -> String {
    core_module("", "", "(loop $l (br $l))")
}
