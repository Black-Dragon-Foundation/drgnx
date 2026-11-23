//! The component host: wasmtime's bindings for the world, the store's state, and the engine whose every call is
//! metered by fuel. Every function binding is generated; an import that the guest makes lands in the editor's `Api`
//! through `WasmApi`.

use wasmtime::component::Linker;
use wasmtime::{Config, Engine};

use crate::generated::{Api, WasmApi};

pub mod bindings {
    wasmtime::component::bindgen!({
        path: "../mal",
        world: "extension",
        imports: { default: trappable },
    });
}

/// What a store holds: the API the guest's imports reach.
pub struct State<A> {
    pub api: WasmApi<A>,
}

/// An engine that meters every call by fuel (a loop that never ends runs out of it and traps).
pub fn engine() -> villa::Result<Engine> {
    let mut c = Config::new();
    c.consume_fuel(true);
    Engine::new(&c).map_err(|e| {
        villa::Error::internal("The extension engine could not start.")
            .with_detail(format!("{e:#}"))
    })
}

/// A linker with every interface of the world linked to A.
pub fn linker<A: Api + 'static>(engine: &Engine) -> villa::Result<Linker<State<A>>> {
    let mut linker = Linker::new(engine);
    crate::generated::wasm_link::<A>(&mut linker).map_err(|e| {
        villa::Error::internal("The extension API could not be linked.")
            .with_detail(format!("{e:#}"))
    })?;
    Ok(linker)
}
