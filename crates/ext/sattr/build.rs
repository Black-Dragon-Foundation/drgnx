//! Runs the generator: the WIT in `../mal`, the Rust bindings out. Nothing here names a function of the API.

use std::path::Path;

fn main() -> villa::Result<()> {
    annall::cli_out("cargo::rerun-if-changed=../mal")?;
    let o = mal_gen::Options {
        generated: "crate::generated".into(),
        bindings: "crate::wasm::bindings".into(),
        state: "crate::wasm::State<A>".into(),
        api_field: "api".into(),
        global: "drgnx".into(),
        caller: "crate::Caller".into(),
    };
    let out = mal_gen::generate(Path::new("../mal"), "extension", &o)?;
    let dir = std::env::var("OUT_DIR")
        .map_err(|e| villa::Error::internal("The build has no OUT_DIR.").with_source(e))?;
    eitri::replace_file(&Path::new(&dir).join("api_gen.rs"), out.rust.as_bytes()).map_err(|e| {
        villa::Error::io("The generated bindings could not be written.")
            .with_detail(format!("{e:?}"))
    })?;
    // a second world, for the generator's tests only: nested records and lists (tests/nested.rs)
    annall::cli_out("cargo::rerun-if-changed=tests/wit-nested")?;
    let nested = mal_gen::Options {
        generated: "crate::g".into(),
        bindings: "crate::b".into(),
        state: "crate::S<A>".into(),
        api_field: "api".into(),
        global: "nest".into(),
        caller: "crate::C".into(),
    };
    let out = mal_gen::generate(Path::new("tests/wit-nested"), "w", &nested)?;
    eitri::replace_file(&Path::new(&dir).join("nested_gen.rs"), out.rust.as_bytes()).map_err(
        |e| {
            villa::Error::io("The nested test bindings could not be written.")
                .with_detail(format!("{e:?}"))
        },
    )?;
    Ok(())
}
