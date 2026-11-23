//! The component host: wasmtime's bindings for the world, the store's state, and an engine that meters every call by
//! fuel and by epoch, with a limit on memory. Every function binding is generated; an import that the guest makes lands
//! in the editor's `Api` through `WasmApi`, with the caller.

use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use bod::Origin;
use wasmtime::component::Linker;
use wasmtime::{Config, Engine, ResourceLimiter, Store};

use crate::generated::{Api, WasmApi};
use crate::{Caller, Limits};

pub mod bindings {
    wasmtime::component::bindgen!({
        path: "../mal",
        world: "extension",
        imports: { default: trappable },
    });
}

/// What a store holds: the API the guest's imports reach, and what it may use.
pub struct State<A> {
    pub api: WasmApi<A>,
    memory_bytes: usize,
    denied: u32,
}

impl<A> State<A> {
    /// How many times the memory limit refused the guest more memory.
    pub fn denied_growths(&self) -> u32 {
        self.denied
    }

    /// For whom the guest's next calls into the API are (see [`Caller`]).
    pub fn set_origin(&self, origin: Origin) {
        match self.api.1.write() {
            Ok(mut c) => c.origin = origin,
            Err(p) => p.into_inner().origin = origin,
        }
    }
}

impl<A: Send> ResourceLimiter for State<A> {
    fn memory_growing(
        &mut self,
        _current: usize,
        desired: usize,
        _maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        if desired > self.memory_bytes {
            self.denied += 1;
            return Ok(false);
        }
        Ok(true)
    }

    fn table_growing(
        &mut self,
        _current: usize,
        desired: usize,
        _maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        Ok(desired <= 10_000)
    }
}

/// An engine that meters every call by fuel and by epoch.
pub fn engine() -> villa::Result<Engine> {
    let mut c = Config::new();
    c.consume_fuel(true).epoch_interruption(true);
    Engine::new(&c).map_err(|e| {
        villa::Error::internal("The extension engine could not start.")
            .with_detail(format!("{e:#}"))
    })
}

/// A store for EXTENSION, held to LIMITS: fuel for the first call, a memory limit, an epoch deadline.
pub fn new_store<A: Api + Send + 'static>(
    engine: &Engine,
    api: &Arc<Mutex<A>>,
    extension: &str,
    limits: Limits,
) -> villa::Result<Store<State<A>>> {
    let caller = Arc::new(RwLock::new(Caller {
        extension: extension.to_string(),
        origin: Origin::Extension(extension.to_string()),
    }));
    let mut store = Store::new(
        engine,
        State {
            api: WasmApi(Arc::clone(api), caller),
            memory_bytes: limits.memory_bytes,
            denied: 0,
        },
    );
    store.limiter(|s| s);
    arm(&mut store, &limits)?;
    Ok(store)
}

/// Renew the fuel and the epoch deadline: call it before each call into the guest.
pub fn arm<A: Send>(store: &mut Store<State<A>>, limits: &Limits) -> villa::Result<()> {
    let fail = |e: wasmtime::Error| {
        villa::Error::internal("The extension's limits could not be set.")
            .with_detail(format!("{e:#}"))
    };
    store.set_fuel(limits.steps).map_err(fail)?;
    store.set_epoch_deadline(limits.ticks);
    Ok(())
}

/// A linker with every interface of the world linked to A.
pub fn linker<A: Api + Send + 'static>(engine: &Engine) -> villa::Result<Linker<State<A>>> {
    let mut linker = Linker::new(engine);
    crate::generated::wasm_link::<A>(&mut linker).map_err(|e| {
        villa::Error::internal("The extension API could not be linked.")
            .with_detail(format!("{e:#}"))
    })?;
    Ok(linker)
}

/// The epoch's clock: one tick a millisecond for as long as the task lives (dropping it stops the ticks).
pub fn ticker(executor: &saman::Executor, engine: Engine) -> saman::Task<()> {
    executor.spawn("epoch-ticker", async move {
        for _ in 0..u64::MAX {
            stund::sleep(Duration::from_millis(1)).await;
            engine.increment_epoch();
        }
    })
}
