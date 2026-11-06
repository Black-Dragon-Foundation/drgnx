//! The WASM host: loads an approved plugin and runs its abilities and hooks, each call in a fresh instance on the
//! guest runtime (docs/develop/plugins.md, "What a plugin can reach").
//!
//! - [`Host::load`] re-reads the plugin's files and refuses them unless they hash to the approved hash; it compiles a
//!   component once per hash, and refuses one that imports anything the host does not provide or uses a Wasm
//!   proposal that is off.
//! - [`Host::call_ability`] and [`Host::run_hook`] admit the call (the plugin's semaphore, then the global one, by
//!   the call's deadline, else `Busy`), then run it on the guest runtime in a new store: [`Limits`]' memory, table,
//!   instance and handle caps, an epoch deadline that traps, and a timeout around the call. JSON in and out is at
//!   most [`MAX_JSON_BYTES`].

use std::collections::HashMap;
use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;
use wasmtime::component::{Component, InstancePre};
use wasmtime::{Config, Engine, Store, StoreLimitsBuilder};

use crate::guest::Guest;
use crate::imports::bindings::drgnx::agent_tools::types as wit;
use crate::imports::bindings::exports::drgnx::agent_tools::{ability, hook};
use crate::imports::{HostIo, Output, State, flush_output, linker, unprovided_import};
use crate::limits::{ABILITY_DEADLINE, EPOCH_TICK, Limits, MAX_JSON_BYTES};
use crate::manifest::{Manifest, Point, parse, plugin_hash};
use crate::store::{Installed, read_files};

/// What a hook said.
#[derive(Debug, Clone, PartialEq)]
pub enum Verdict {
    /// No objection: the matrix still decides.
    Allow,
    Deny(String),
    /// The point's replacement object: `{arguments}`, `{content}`, `{message}` or `{notes}`.
    Change(Value),
    Annotate(String),
}

impl Verdict {
    /// The verdict's word: `allow`, `deny`, `change`, `annotate`.
    pub fn word(&self) -> &'static str {
        match self {
            Verdict::Allow => "allow",
            Verdict::Deny(_) => "deny",
            Verdict::Change(_) => "change",
            Verdict::Annotate(_) => "annotate",
        }
    }
}

/// Why a plugin was not loaded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostError {
    /// Its files do not hash to the approved hash (changed on disk, or never approved).
    NotApproved(String),
    /// Its files could not be read.
    Io(String),
    /// Not a component the engine accepts (a Wasm proposal that is off, a core module, garbage).
    Invalid(String),
    /// It imports an interface the host does not provide.
    Import(String),
    /// It lacks an export its manifest needs.
    Export(String),
    /// The host itself could not start.
    Engine(String),
}

impl fmt::Display for HostError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HostError::NotApproved(m) => write!(f, "not approved: {m}"),
            HostError::Io(m) => write!(f, "cannot read the plugin: {m}"),
            HostError::Invalid(m) => write!(f, "not a valid plugin component: {m}"),
            HostError::Import(m) => write!(f, "{m}"),
            HostError::Export(m) => write!(f, "{m}"),
            HostError::Engine(m) => write!(f, "the plugin host cannot start: {m}"),
        }
    }
}

impl std::error::Error for HostError {}

/// Why a call gave no answer. Each is a failure: a hook that fails is a deny unless it is advisory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CallError {
    /// It ran past its deadline and was stopped.
    Timeout,
    /// It trapped: an `unreachable`, a memory or handle limit, an abort.
    Trap(String),
    /// The host refused it: input or output too large, not declared, a result that is not JSON.
    Refused(String),
    /// No permit by its deadline: the plugin's calls, or all calls, were all running.
    Busy,
    /// The plugin answered its own error (`Err` of `call` or `run`).
    Plugin(String),
}

impl fmt::Display for CallError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CallError::Timeout => write!(f, "timed out"),
            CallError::Trap(m) => write!(f, "trap: {m}"),
            CallError::Refused(m) => write!(f, "refused: {m}"),
            CallError::Busy => write!(f, "busy"),
            CallError::Plugin(m) => write!(f, "error: {m}"),
        }
    }
}

impl std::error::Error for CallError {}

/// A compiled component and the export lookups its manifest needs.
struct Compiled {
    pre: InstancePre<State>,
    ability: Option<ability::GuestIndices>,
    hook: Option<hook::GuestIndices>,
}

/// A loaded plugin: what the host checked, under the name it was approved as. Cheap to clone.
#[derive(Clone)]
pub struct Plugin {
    name: Arc<str>,
    manifest: Arc<Manifest>,
    hosts: Arc<[crate::manifest::HostName]>,
    hash: [u8; 32],
    compiled: Arc<Compiled>,
}

impl fmt::Debug for Plugin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Plugin")
            .field("name", &self.name)
            .finish_non_exhaustive()
    }
}

impl Plugin {
    pub fn name(&self) -> &str {
        &self.name
    }
    pub fn manifest(&self) -> &Manifest {
        &self.manifest
    }
    pub fn hash(&self) -> [u8; 32] {
        self.hash
    }
}

/// The plugin host. One per hub; dropping it never blocks.
pub struct Host {
    engine: Engine,
    linker: wasmtime::component::Linker<State>,
    limits: Limits,
    compiled: Mutex<HashMap<[u8; 32], Arc<Compiled>>>,
    // last, so the runtime goes after the engine's users above
    guest: Guest,
}

/// The engine's configuration: epoch interruption, the component model, and every Wasm proposal off that Rust's
/// `wasm32-wasip2` does not emit (bulk memory, sign extension, non-trapping conversions, multi-value, reference
/// types and SIMD stay on; with the `gc` feature off, GC, exceptions and function references are off already).
fn config() -> Config {
    let mut c = Config::new();
    c.epoch_interruption(true)
        .wasm_component_model(true)
        .wasm_tail_call(false)
        .wasm_memory64(false)
        .wasm_multi_memory(false)
        .wasm_relaxed_simd(false)
        .wasm_wide_arithmetic(false)
        .wasm_custom_page_sizes(false)
        .wasm_stack_switching(false)
        .wasm_shared_everything_threads(false)
        .wasm_gc(false);
    c
}

/// The root of a wasmtime error, short enough for a record.
fn short(e: &wasmtime::Error) -> String {
    let mut s = match e.downcast_ref::<wasmtime::Trap>() {
        Some(t) => t.to_string(),
        None => format!("{:#}", e.root_cause()),
    };
    if s.len() > 512 {
        let mut end = 512;
        while !s.is_char_boundary(end) {
            end -= 1;
        }
        s.truncate(end);
    }
    s
}

fn trap(e: wasmtime::Error) -> CallError {
    if e.downcast_ref::<wasmtime::Trap>() == Some(&wasmtime::Trap::Interrupt) {
        CallError::Timeout
    } else {
        CallError::Trap(short(&e))
    }
}

/// A JSON text of at most [`MAX_JSON_BYTES`], parsed.
fn json_out(text: &str, what: &str) -> Result<Value, CallError> {
    if text.len() > MAX_JSON_BYTES {
        return Err(CallError::Refused(format!(
            "the {what} is larger than {} KiB",
            MAX_JSON_BYTES / 1024
        )));
    }
    serde_json::from_str(text)
        .map_err(|e| CallError::Refused(format!("the {what} is not JSON: {e}")))
}

fn json_in(v: &Value, what: &str) -> Result<String, CallError> {
    let text = v.to_string();
    if text.len() > MAX_JSON_BYTES {
        return Err(CallError::Refused(format!(
            "the {what} is larger than {} KiB",
            MAX_JSON_BYTES / 1024
        )));
    }
    Ok(text)
}

fn string_out(s: String, what: &str) -> Result<String, CallError> {
    if s.len() > MAX_JSON_BYTES {
        return Err(CallError::Refused(format!(
            "the {what} is larger than {} KiB",
            MAX_JSON_BYTES / 1024
        )));
    }
    Ok(s)
}

impl Host {
    /// Starts the engine, the guest runtime (`limits.guest_calls` threads named `brokkr-guest`) and the epoch ticker.
    pub fn new(limits: Limits) -> Result<Host, HostError> {
        let engine = Engine::new(&config()).map_err(|e| HostError::Engine(short(&e)))?;
        let linker = linker(&engine).map_err(|e| HostError::Engine(short(&e)))?;
        let guest = Guest::new(&limits, &engine).map_err(|e| HostError::Engine(e.to_string()))?;
        Ok(Host {
            engine,
            linker,
            limits,
            compiled: Mutex::new(HashMap::new()),
            guest,
        })
    }

    pub fn limits(&self) -> &Limits {
        &self.limits
    }

    /// How many calls are admitted and not yet ended (they hold a global permit).
    pub fn calls_running(&self) -> usize {
        self.guest.running()
    }

    /// Loads `p` if its files, read again now, hash to `approved`. Nothing of a refused plugin is compiled.
    pub fn load(&self, p: &Installed, approved: [u8; 32]) -> Result<Plugin, HostError> {
        if p.hash != approved {
            return Err(HostError::NotApproved(format!(
                "{} is not the plugin that was approved",
                p.manifest.name.as_str()
            )));
        }
        let (manifest_bytes, wasm) =
            read_files(&p.dir).map_err(|e| HostError::Io(e.to_string()))?;
        if plugin_hash(&manifest_bytes, &wasm) != approved {
            return Err(HostError::NotApproved(format!(
                "{} changed on disk since it was approved",
                p.manifest.name.as_str()
            )));
        }
        let manifest = parse(&manifest_bytes).map_err(|e| HostError::Invalid(e.to_string()))?;
        let compiled = self.compile(&manifest, &wasm, approved)?;
        Ok(Plugin {
            name: manifest.name.as_str().into(),
            hosts: manifest.hosts.clone().into(),
            manifest: Arc::new(manifest),
            hash: approved,
            compiled,
        })
    }

    fn compile(
        &self,
        m: &Manifest,
        wasm: &[u8],
        hash: [u8; 32],
    ) -> Result<Arc<Compiled>, HostError> {
        if let Some(c) = self
            .compiled
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&hash)
        {
            return Ok(c.clone());
        }
        let component =
            Component::new(&self.engine, wasm).map_err(|e| HostError::Invalid(format!("{e:#}")))?;
        if let Some(name) = unprovided_import(&self.engine, &component) {
            return Err(HostError::Import(format!(
                "{} imports {name}, which drgnx does not provide",
                m.name.as_str()
            )));
        }
        let pre = self
            .linker
            .instantiate_pre(&component)
            .map_err(|e| HostError::Import(format!("{}: {:#}", m.name.as_str(), e)))?;
        let export = |e: wasmtime::Error| HostError::Export(format!("{}: {e:#}", m.name.as_str()));
        let ability = if m.abilities.is_empty() {
            None
        } else {
            Some(ability::GuestIndices::new(&pre).map_err(export)?)
        };
        let hook = if m.hooks.is_empty() {
            None
        } else {
            Some(hook::GuestIndices::new(&pre).map_err(export)?)
        };
        let c = Arc::new(Compiled { pre, ability, hook });
        self.compiled
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(hash, c.clone());
        Ok(c)
    }

    /// A fresh store for one call of `p`, with the limits, the handle cap and an epoch deadline `left` from now.
    fn store(
        &self,
        p: &Plugin,
        io: Arc<dyn HostIo>,
        left: Duration,
        out: Arc<Mutex<Output>>,
    ) -> Result<Store<State>, CallError> {
        let hub = tokio::runtime::Handle::try_current()
            .map_err(|_| CallError::Refused("no runtime to run the call's I/O on".into()))?;
        let limits = StoreLimitsBuilder::new()
            .memory_size(self.limits.memory_bytes)
            .table_elements(self.limits.table_elements)
            .instances(self.limits.instances_per_store)
            .trap_on_grow_failure(true)
            .build();
        let state = State::new(limits, p.name.clone(), p.hosts.clone(), io, hub, out);
        let mut store = Store::new(&self.engine, state);
        store.limiter(|s| &mut s.limits);
        store.set_max_component_handles(self.limits.component_handles);
        let ticks = left.as_millis() / EPOCH_TICK.as_millis() + 1;
        store.set_epoch_deadline(u64::try_from(ticks).unwrap_or(u64::MAX));
        store.epoch_deadline_trap();
        Ok(store)
    }

    /// Admits a call of `p` by `deadline` from now, then runs `work` on the guest runtime with what is left.
    async fn call<T, F, Fut>(
        &self,
        p: &Plugin,
        deadline: Duration,
        io: Arc<dyn HostIo>,
        work: F,
    ) -> Result<T, CallError>
    where
        T: Send + 'static,
        F: FnOnce(Store<State>, Arc<Compiled>) -> Fut,
        Fut: std::future::Future<Output = Result<T, CallError>> + Send + 'static,
    {
        let until = tokio::time::Instant::now() + deadline;
        let permits = self.guest.admit(&p.name, until).await?;
        let left = until.saturating_duration_since(tokio::time::Instant::now());
        if left.is_zero() {
            return Err(CallError::Busy);
        }
        let out = Arc::new(Mutex::new(Output::default()));
        let store = self.store(p, io.clone(), left, out.clone())?;
        let fut = work(store, p.compiled.clone());
        let name = p.name.clone();
        self.guest
            .run(permits, left, async move {
                let r = fut.await;
                flush_output(&out, &*io, &name);
                r
            })
            .await
    }

    /// Runs `p`'s ability `tool` on `args` within [`ABILITY_DEADLINE`]; the result is the tool's JSON result.
    pub async fn call_ability(
        &self,
        p: &Plugin,
        tool: &str,
        args: Value,
        io: Arc<dyn HostIo>,
    ) -> Result<Value, CallError> {
        if !p.manifest.abilities.iter().any(|a| a.name.as_str() == tool) {
            return Err(CallError::Refused(format!(
                "{} has no ability {tool}",
                p.name
            )));
        }
        let args = json_in(&args, "arguments")?;
        let tool = tool.to_string();
        let text = self
            .call(p, ABILITY_DEADLINE, io, move |mut store, c| async move {
                let Some(indices) = c.ability.as_ref() else {
                    return Err(CallError::Refused("no ability export".into()));
                };
                let instance = c.pre.instantiate_async(&mut store).await.map_err(trap)?;
                let guest = indices
                    .load(&mut store, &instance)
                    .map_err(|e| CallError::Refused(short(&e)))?;
                guest
                    .call_call(&mut store, &tool, &args)
                    .await
                    .map_err(trap)?
                    .map_err(CallError::Plugin)
            })
            .await?;
        json_out(&text, "result")
    }

    /// Runs `p`'s hook at `point` on `input`, stopped at `deadline` (what is left of the point's budget). Waiting
    /// for a permit counts against it.
    pub async fn run_hook(
        &self,
        p: &Plugin,
        point: Point,
        input: Value,
        deadline: Duration,
        io: Arc<dyn HostIo>,
    ) -> Result<Verdict, CallError> {
        if !p.manifest.hooks.iter().any(|h| h.point == point) {
            return Err(CallError::Refused(format!(
                "{} has no hook at this point",
                p.name
            )));
        }
        let input = json_in(&input, "input")?;
        let at = match point {
            Point::BeforeTool => wit::Point::BeforeTool,
            Point::AfterEdit => wit::Point::AfterEdit,
            Point::BeforeCommit => wit::Point::BeforeCommit,
            Point::AtReview => wit::Point::AtReview,
        };
        let verdict = self
            .call(p, deadline, io, move |mut store, c| async move {
                let Some(indices) = c.hook.as_ref() else {
                    return Err(CallError::Refused("no hook export".into()));
                };
                let instance = c.pre.instantiate_async(&mut store).await.map_err(trap)?;
                let guest = indices
                    .load(&mut store, &instance)
                    .map_err(|e| CallError::Refused(short(&e)))?;
                guest
                    .call_run(&mut store, at, &input)
                    .await
                    .map_err(trap)?
                    .map_err(CallError::Plugin)
            })
            .await?;
        Ok(match verdict {
            wit::Verdict::Allow => Verdict::Allow,
            wit::Verdict::Deny(s) => Verdict::Deny(string_out(s, "reason")?),
            wit::Verdict::Annotate(s) => Verdict::Annotate(string_out(s, "note")?),
            wit::Verdict::Change(s) => Verdict::Change(json_out(&s, "change")?),
        })
    }
}
