//! The component host: wasmtime's bindings for the world, the store's state, and an engine that meters every call by
//! fuel and by epoch, with a limit on memory and on tables. Every function binding is generated; an import that the
//! guest makes lands in the editor's `Api` through `WasmApi`, with the caller.
//!
//! A guest is run only through [`Guest`], whose every call arms fuel and the epoch, says for whom the call is, and puts
//! the origin back afterwards, as `LuauHost` does. The raw pieces are private.

use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use bod::Origin;
use wasmtime::component::{Component, Linker};
use wasmtime::{Config, Engine, ResourceLimiter, Store};

use crate::generated::drgnx_api_v0_1_0::entry::AnsweredHow;
use crate::generated::drgnx_api_v0_1_0::exports::entry;
use crate::generated::drgnx_api_v0_1_0::types::Error;
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
    pub(crate) api: WasmApi<A>,
    memory_bytes: usize,
    table_elements: usize,
    denied: u32,
}

impl<A> State<A> {
    fn set_origin(&self, origin: Origin) -> Origin {
        let mut c = match self.api.1.write() {
            Ok(c) => c,
            Err(p) => p.into_inner(),
        };
        std::mem::replace(&mut c.origin, origin)
    }

    fn origin(&self) -> Origin {
        match self.api.1.read() {
            Ok(c) => c.origin.clone(),
            Err(p) => p.into_inner().origin.clone(),
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
        if desired > self.table_elements {
            self.denied += 1;
            return Ok(false);
        }
        Ok(true)
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

/// One extension's component, instantiated: its store holds the caller and the limits.
pub struct Guest<A: Send + 'static> {
    store: Store<State<A>>,
    ext: bindings::Extension,
    limits: Limits,
}

fn guest_error(what: &str, e: wasmtime::Error) -> villa::Error {
    villa::Error::invalid(format!("{what} failed.")).with_detail(format!("{e:#}"))
}

impl<A: Api + Send + 'static> Guest<A> {
    /// Instantiate COMPONENT for EXTENSION (whose name must be valid), held to LIMITS.
    pub fn instantiate(
        engine: &Engine,
        linker: &Linker<State<A>>,
        component: &Component,
        api: &Arc<Mutex<A>>,
        extension: &str,
        limits: Limits,
    ) -> villa::Result<Self> {
        crate::valid_extension_name(extension)?;
        let caller = Arc::new(RwLock::new(Caller {
            extension: extension.to_string(),
            origin: Origin::Extension(extension.to_string()),
        }));
        let mut store = Store::new(
            engine,
            State {
                api: WasmApi(Arc::clone(api), caller),
                memory_bytes: limits.memory_bytes,
                table_elements: limits.table_elements,
                denied: 0,
            },
        );
        store.limiter(|s| s);
        // the instantiation itself runs the guest's start code: armed like any call
        arm(&mut store, &limits)?;
        let ext = bindings::Extension::instantiate(&mut store, component, linker)
            .map_err(|e| guest_error("Instantiating the extension", e))?;
        Ok(Guest { store, ext, limits })
    }

    /// F, the guest's call, armed with fuel and the epoch, for ORIGIN; the origin is put back whatever F does.
    fn call<T>(
        &mut self,
        origin: Origin,
        f: impl FnOnce(&mut Store<State<A>>, &bindings::Extension) -> wasmtime::Result<T>,
    ) -> villa::Result<T> {
        arm(&mut self.store, &self.limits)?;
        let before = self.store.data().set_origin(origin);
        let r = f(&mut self.store, &self.ext);
        self.store.data().set_origin(before);
        r.map_err(|e| guest_error("The extension's call", e))
    }

    /// The extension's `init`.
    pub fn init(&mut self, origin: Origin) -> villa::Result<()> {
        self.call(origin, |s, e| entry::wasm_init(s, e))
    }

    /// The extension's `run` of the command NAME.
    pub fn run(&mut self, origin: Origin, name: &str) -> villa::Result<Result<(), Error>> {
        self.call(origin, |s, e| entry::wasm_run(s, e, name))
    }

    /// The extension's `answered`.
    pub fn answered(
        &mut self,
        origin: Origin,
        question: u64,
        choice: &str,
        how: AnsweredHow,
    ) -> villa::Result<()> {
        self.call(origin, |s, e| {
            entry::wasm_answered(s, e, question, choice, how)
        })
    }

    /// For whom the guest's calls into the API are, between calls: always the extension itself.
    pub fn origin(&self) -> Origin {
        self.store.data().origin()
    }

    /// How many times a limit said no to a memory or table growth.
    pub fn denied_growths(&self) -> u32 {
        self.store.data().denied
    }
}

/// Renew the fuel and the epoch deadline: before each call into the guest.
fn arm<A: Send>(store: &mut Store<State<A>>, limits: &Limits) -> villa::Result<()> {
    let fail = |e: wasmtime::Error| {
        villa::Error::internal("The extension's limits could not be set.")
            .with_detail(format!("{e:#}"))
    };
    store.set_fuel(limits.steps).map_err(fail)?;
    store.set_epoch_deadline(limits.ticks);
    Ok(())
}
