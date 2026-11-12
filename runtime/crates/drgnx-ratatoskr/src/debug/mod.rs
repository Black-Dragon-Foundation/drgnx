//! Debugging (docs/develop/debugging.md): the hub owns each debug session, speaking the Debug Adapter Protocol to the
//! adapter through `vor`.
//!
//! - [`adapters`]: the adapter table (`etc/debug-adapters.eld`, data only), finding an adapter, its command line.
//! - [`launch`]: launch.json (JSONC), the picker's order, platform sections, `${…}` variables, inputs.
//! - [`session`]: one session's life: the launch sequence, stops and their epochs, controls, the stop sequence.
//! - [`Debug`] (here): the hub's sessions: starting them through a [`Launcher`], children from `startDebugging`,
//!   restarts, `runInTerminal` in a drgnx terminal, the `debug-state` / `debug-frame` / `debug-terminal` events, and
//!   stopping (children before their parent; every session at the hub's end).

pub mod adapters;
pub mod agent;
pub mod bisect;
pub mod bisect_card;
pub mod bisect_wire;
pub mod blocked;
pub mod breakpoints;
pub mod compare;
pub mod console;
pub mod fork;
pub mod fork_hub;
pub mod fork_mux;
pub mod fork_seal;
pub mod fork_wire;
pub mod inline;
pub mod install;
pub mod launch;
pub mod origin;
pub mod origin_wire;
pub mod ports;
pub mod probes;
pub mod record;
pub mod runfile;
pub mod runs_wire;
pub mod session;
pub mod strip;
pub mod tasks;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_adapters;
#[cfg(test)]
mod tests_agent;
#[cfg(test)]
mod tests_bisect;
#[cfg(test)]
mod tests_bisect_wire;
#[cfg(test)]
mod tests_blocked;
#[cfg(test)]
mod tests_blocked_live;
#[cfg(test)]
mod tests_breakpoints;
#[cfg(test)]
mod tests_console;
#[cfg(test)]
mod tests_console_hub;
#[cfg(test)]
mod tests_fork;
#[cfg(test)]
mod tests_fork_hub;
#[cfg(test)]
mod tests_fork_live;
#[cfg(test)]
mod tests_fork_seal;
#[cfg(test)]
mod tests_inline;
#[cfg(test)]
mod tests_install;
#[cfg(test)]
mod tests_launch;
#[cfg(test)]
mod tests_live_adapters;
#[cfg(test)]
mod tests_origin;
#[cfg(test)]
mod tests_ports;
#[cfg(test)]
mod tests_probes;
#[cfg(test)]
mod tests_record;
#[cfg(test)]
mod tests_registry;
#[cfg(test)]
mod tests_tasks;
pub mod wire;

use breakpoints::Store;
use serde_json::{Value, json};
use session::{End, Handle, Op, Proc, Start, Stop, Update};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use tokio::sync::{mpsc, watch};

/// `ratatoskr debug-mock SCRIPT.json` (test-hooks builds): the mock adapter on stdio; exit 1 with the reason on stderr
/// when the script fails, 2 when it cannot be read.
#[cfg(feature = "test-hooks")]
pub fn mock_main(script: &std::ffi::OsStr) -> std::process::ExitCode {
    use std::process::ExitCode;
    let shown = std::path::Path::new(script).display().to_string();
    let script: vor::mock::Script = match std::fs::read(script)
        .map_err(|e| e.to_string())
        .and_then(|b| serde_json::from_slice(&b).map_err(|e| e.to_string()))
    {
        Ok(s) => s,
        Err(e) => {
            eprintln!("debug-mock: {shown}: {e}");
            return ExitCode::from(2);
        }
    };
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("debug-mock: no runtime: {e}");
            return ExitCode::from(2);
        }
    };
    // inside the runtime: the mock starts its tasks at once
    let r = rt.block_on(async {
        vor::mock::Mock::start(script, tokio::io::stdin(), tokio::io::stdout())
            .finish()
            .await
    });
    match r {
        Ok(_) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("debug-mock: {e}");
            ExitCode::from(1)
        }
    }
}

/// A boxed future, for the traits below.
pub type BoxFut<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Where the events go: the editors' connections.
pub trait Sink: Send + Sync {
    /// EVENT with DATA to every editor but EXCEPT.
    fn broadcast(&self, event: &str, data: Value, except: Option<u64>);
    /// EVENT with DATA to connection CONN only.
    fn send(&self, conn: u64, event: &str, data: Value) -> bool;
}

impl Sink for crate::settings::agents::Editors {
    fn broadcast(&self, event: &str, data: Value, except: Option<u64>) {
        self.broadcast_except(event, data, except);
    }
    fn send(&self, conn: u64, event: &str, data: Value) -> bool {
        self.send_to(conn, event, data)
    }
}

/// A connected adapter: its connection, what it sends on its own, and its process.
pub struct Connected {
    pub client: vor::Client,
    pub incoming: mpsc::UnboundedReceiver<vor::Incoming>,
    pub proc: Box<dyn Proc>,
}

/// How a session's adapter is reached: started (stdio, or TCP on a port it was given) or connected to.
pub trait Launcher: Send + Sync {
    /// A new adapter for a session.
    fn connect(&self) -> BoxFut<'_, Result<Connected, String>>;
    /// The adapter for a child session (`startDebugging`): for a TCP adapter a second connection to the same port,
    /// otherwise a new adapter.
    fn child(&self) -> BoxFut<'_, Result<Connected, String>> {
        self.connect()
    }
}

/// A terminal `runInTerminal` opened: its id, its view and its program's pid.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Opened {
    pub term: String,
    pub view: String,
    pub pid: i64,
    /// The editor session it belongs to.
    pub editor: Option<String>,
}

/// Terminal DATA (`term`, `view`, `editor`, …) for connection CONN's editor to show (`debug-terminal`): to CONN when
/// it takes events, else to every editor, `editor` saying which one it is for (a start comes on a connection that
/// takes none).
pub fn show_terminal(sink: &dyn Sink, conn: u64, data: Value) {
    if !sink.send(conn, "debug-terminal", data.clone()) {
        sink.broadcast("debug-terminal", data, None);
    }
}

/// The program `runInTerminal` asks for, in a drgnx terminal.
pub trait Terminals: Send + Sync {
    /// Open a terminal for connection CONN running ARGS in CWD with ENV added.
    fn open(
        &self,
        conn: u64,
        cwd: String,
        args: Vec<String>,
        env: Vec<(String, String)>,
    ) -> BoxFut<'_, Result<Opened, String>>;

    /// Let terminal TERM's task run (its wrapper waits for a line, so this waits from before it can end) and give its
    /// exit status (the first command end with one, or its program's exit; none when it is gone) and, when that is not
    /// 0, its text.
    fn run_task(&self, term: String) -> BoxFut<'_, (Option<i32>, String)> {
        let _ = term;
        Box::pin(async { (None, String::new()) })
    }
}

/// The phase a session shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Starting,
    Running,
    Stopped,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Phase::Starting => "starting",
            Phase::Running => "running",
            Phase::Stopped => "stopped",
        }
    }
}

struct Entry {
    handle: Handle,
    name: String,
    parent: Option<String>,
    /// The connection that started it (or its root's): the editor that opens files on a stop.
    conn: u64,
    root: String,
    start: Start,
    launcher: Arc<dyn Launcher>,
    phase: Phase,
    reason: Option<String>,
    caps: Value,
    stop: Option<Stop>,
    /// Closed (`true`) once the session has ended.
    ended: watch::Receiver<bool>,
}

#[derive(Default)]
struct State {
    sessions: BTreeMap<String, Entry>,
    next: u64,
    /// The hub is stopping: no new session.
    shut: bool,
}

struct Inner {
    sink: Arc<dyn Sink>,
    terms: Arc<dyn Terminals>,
    state: Mutex<State>,
    /// Each project's breakpoints, by root (loaded on first use).
    stores: Mutex<BTreeMap<String, Store>>,
    /// Where the stores are saved (none: memory only).
    store_dir: Option<PathBuf>,
    /// The recorded runs and the probes (none: nothing is recorded).
    rec: OnceLock<Arc<record::Records>>,
    /// Told the roots of the live sessions each time they change (a session starts or ends; a recording starts with
    /// its session): the hub gives the agents there the debugger's tools.
    on_state: OnceLock<StateHook>,
    /// The inline values' parse cache and each session's last values.
    inline: inline::Inline,
    /// Told of every change of a session's state or stop, or of breakpoints (the Run and Debug views).
    listeners: Mutex<Vec<Listener>>,
    /// Each session's console output waiting to be sent (`debug-output`), and the sessions whose batch is due.
    consoles: Mutex<HashMap<String, console::Console>>,
    armed: Mutex<HashSet<String>>,
}

/// A function told that a session or breakpoint changed.
pub type Listener = Arc<dyn Fn() + Send + Sync>;

/// One session as the views read it: its id, name, phase, stop, capabilities and adapter type.
#[derive(Clone, Debug)]
pub struct Snap {
    pub id: String,
    pub name: String,
    pub state: &'static str,
    pub stop: Option<Stop>,
    pub caps: Value,
    pub adapter: String,
}

/// What [`Debug::on_state`] calls.
pub type StateHook = Arc<dyn Fn(Vec<String>) + Send + Sync>;

/// The hub's debug sessions.
#[derive(Clone)]
pub struct Debug {
    inner: Arc<Inner>,
}

fn lock(m: &Mutex<State>) -> MutexGuard<'_, State> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Debug {
    pub fn new(sink: Arc<dyn Sink>, terms: Arc<dyn Terminals>) -> Debug {
        Debug::with_store(sink, terms, None)
    }

    /// The sessions, with each project's breakpoints saved in STORE_DIR (one file per root).
    pub fn with_store(
        sink: Arc<dyn Sink>,
        terms: Arc<dyn Terminals>,
        store_dir: Option<PathBuf>,
    ) -> Debug {
        Debug {
            inner: Arc::new(Inner {
                sink,
                terms,
                state: Mutex::new(State::default()),
                stores: Mutex::new(BTreeMap::new()),
                store_dir,
                rec: OnceLock::new(),
                on_state: OnceLock::new(),
                inline: inline::Inline::new(),
                listeners: Mutex::new(Vec::new()),
                consoles: Mutex::new(HashMap::new()),
                armed: Mutex::new(HashSet::new()),
            }),
        }
    }

    /// Call HOOK with the live sessions' roots whenever they change (once; a later hook is ignored).
    pub fn on_state(&self, hook: StateHook) {
        let _ = self.inner.on_state.set(hook);
    }

    /// The roots that debug: a live session's, or a recorded run's.
    pub fn debugged_roots(&self) -> Vec<String> {
        let mut roots: Vec<String> = lock(&self.inner.state)
            .sessions
            .values()
            .map(|e| e.root.clone())
            .collect();
        if let Some(rec) = self.records() {
            roots.extend(rec.list("").into_iter().map(|m| m.root));
        }
        roots.sort();
        roots.dedup();
        roots
    }

    /// Record every session from now on, as OPTS says (once; later calls answer the first records).
    pub fn record_into(&self, opts: record::Opts) -> Arc<record::Records> {
        self.inner
            .rec
            .get_or_init(|| record::Records::new(opts, self.inner.sink.clone()))
            .clone()
    }

    /// The recorded runs, when sessions are recorded.
    pub fn records(&self) -> Option<Arc<record::Records>> {
        self.inner.rec.get().cloned()
    }

    /// PATH's probes as `SourceBreakpoint`s for a session of ADAPTER_ID in ROOT with CAPS (null: not known yet, the
    /// adapter is taken to have logpoints and `breakpoints::fit` drops them if not), past the lines BPS take.
    fn probe_bps(
        &self,
        root: &str,
        path: &str,
        adapter_id: &str,
        caps: &Value,
        bps: &[Value],
    ) -> Vec<Value> {
        let Some(rec) = self.records() else {
            return vec![];
        };
        let taken: Vec<u32> = bps
            .iter()
            .filter_map(|b| b.get("line").and_then(Value::as_u64))
            .filter_map(|l| u32::try_from(l).ok())
            .collect();
        let caps = if caps.is_null() {
            json!({"supportsLogPoints": true})
        } else {
            caps.clone()
        };
        rec.probes(root, |p| p.source_bps(path, adapter_id, &caps, &taken))
    }

    /// ROOT's probes on PATH changed: its sessions get PATH's breakpoints again.
    pub async fn probes_changed(&self, root: &str, path: &str) {
        for id in self.sessions_in(root) {
            self.resend(&id, path).await;
        }
    }

    /// ROOT's breakpoint ID is agent session AGENT's (D4): the editors see it ringed.
    pub fn mark_breakpoint(&self, root: &str, id: u64, agent: &str) {
        if let Some(path) = self.store(root, |s| s.mark(id, agent)) {
            self.publish_bps(root, &path);
        }
    }

    /// The agent session ROOT's breakpoint ID is of (none: the user's, or no such breakpoint).
    pub fn breakpoint_owner(&self, root: &str, id: u64) -> Option<String> {
        self.store(root, |s| s.owner(id))
    }

    /// F on ROOT's breakpoint store.
    fn store<R>(&self, root: &str, f: impl FnOnce(&mut Store) -> R) -> R {
        let mut stores = self
            .inner
            .stores
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let s = stores.entry(root.to_owned()).or_insert_with(|| {
            let file = self.inner.store_dir.as_ref().map(|d| {
                d.join(format!(
                    "{:016x}.json",
                    xxhash_rust::xxh3::xxh3_64(root.as_bytes())
                ))
            });
            Store::open(file)
        });
        f(s)
    }

    /// The project session ID debugs.
    pub fn root_of(&self, id: &str) -> Option<String> {
        lock(&self.inner.state)
            .sessions
            .get(id)
            .map(|e| e.root.clone())
    }

    /// Tell the editors PATH's breakpoints in ROOT.
    fn publish_bps(&self, root: &str, path: &str) {
        let mut v = self.store(root, |s| s.view(path));
        v["root"] = json!(root);
        self.inner.sink.broadcast("debug-breakpoints", v, None);
        self.changed();
    }

    /// An `output` event's BODY into ID's console: sent at once past [`console::BATCH_BYTES`], else with what comes in
    /// the next [`console::BATCH`].
    fn console_output(&self, id: &str, body: &Value) {
        let ansi = lock(&self.inner.state).sessions.get(id).is_some_and(|e| {
            e.caps.get("supportsANSIStyling").and_then(Value::as_bool) == Some(true)
        });
        let full = {
            let mut c = self
                .inner
                .consoles
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let con = c.entry(id.to_owned()).or_default();
            con.output(body, ansi);
            con.full()
        };
        if full {
            self.console_flush(id, false);
        } else if self
            .inner
            .armed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(id.to_owned())
        {
            let d = self.clone();
            let id = id.to_owned();
            crate::clock::spawn("debug:console", async move {
                crate::clock::sleep(console::BATCH).await;
                d.console_flush(&id, false);
            });
        }
    }

    /// Send ID's console batch (`debug-output {session, lines, skipped?}`) to every editor; END: the session is over
    /// (its last line goes without its newline, and its console with it).
    pub fn console_flush(&self, id: &str, end: bool) {
        self.inner
            .armed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(id);
        let batch = {
            let mut c = self
                .inner
                .consoles
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let b = c.get_mut(id).and_then(|con| con.take(end));
            if end {
                c.remove(id);
            }
            b
        };
        if let Some(mut b) = batch {
            b["session"] = json!(id);
            self.inner.sink.broadcast("debug-output", b, None);
        }
    }

    /// TEXT in ID's console in CATEGORY, sent at once (a task's failure after the session ended).
    pub fn console_say(&self, id: &str, text: &str, category: &str) {
        let batch = {
            let mut con = console::Console::default();
            con.say(text, category, None);
            con.take(true)
        };
        if let Some(mut b) = batch {
            b["session"] = json!(id);
            self.inner.sink.broadcast("debug-output", b, None);
        }
    }

    /// Tell F of every change of a session or a breakpoint from now on.
    pub fn on_change(&self, f: Listener) {
        self.inner
            .listeners
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(f);
    }

    fn changed(&self) {
        let ls = self
            .inner
            .listeners
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        for f in ls {
            f();
        }
    }

    /// ROOT's sessions (children too), in id order.
    pub fn snapshot(&self, root: &str) -> Vec<Snap> {
        lock(&self.inner.state)
            .sessions
            .iter()
            .filter(|(_, e)| e.root == root)
            .map(|(id, e)| Snap {
                id: id.clone(),
                name: e.name.clone(),
                state: e.phase.name(),
                stop: e.stop.clone(),
                caps: e.caps.clone(),
                adapter: e.start.adapter_id.clone(),
            })
            .collect()
    }

    /// ROOT's function breakpoints, and each file's breakpoints as the gutter has them (files in path order).
    pub fn bp_lists(&self, root: &str) -> (Vec<Value>, Vec<(String, Vec<Value>)>) {
        self.store(root, |s| {
            let files = s
                .paths()
                .into_iter()
                .filter_map(|p| {
                    let v = s.view(&p);
                    let list = v["breakpoints"].as_array().cloned().unwrap_or_default();
                    (!list.is_empty()).then_some((p, list))
                })
                .collect();
            (s.functions(), files)
        })
    }

    /// The exception filters on for adapters of type ADAPTER with CAPS in ROOT.
    pub fn filters_on(&self, root: &str, adapter: &str, caps: &Value) -> Vec<String> {
        self.store(root, |s| s.filters(adapter, caps))
    }

    /// ROOT's watch expressions, in order.
    pub fn watches(&self, root: &str) -> Vec<String> {
        self.store(root, |s| s.watches())
    }

    /// ROOT's watch expressions are now LIST (kept with its breakpoints).
    pub fn set_watches(&self, root: &str, list: Vec<String>) {
        self.store(root, |s| s.set_watches(list));
        self.changed();
    }

    /// The exception filter FILTER of adapters of type ADAPTER in ROOT turned ON or off: kept for the type, and sent
    /// to its sessions at once.
    pub async fn set_filter(&self, root: &str, adapter: &str, filter: &str, on: bool) {
        let caps = self
            .snapshot(root)
            .into_iter()
            .find(|s| s.adapter == adapter)
            .map(|s| s.caps)
            .unwrap_or(Value::Null);
        let mut list = self.filters_on(root, adapter, &caps);
        list.retain(|f| f != filter);
        if on {
            list.push(filter.to_owned());
        }
        self.store(root, |s| s.set_filters(adapter, list.clone()));
        for snap in self.snapshot(root) {
            if snap.adapter != adapter {
                continue;
            }
            if let Some(h) = self.handle(&snap.id)
                && let Err(e) = h
                    .request("setExceptionBreakpoints", json!({"filters": list}))
                    .await
            {
                tracing::debug!(target: "drgnx::debug", "setExceptionBreakpoints: {e}");
            }
        }
        self.changed();
    }

    /// Every breakpoint of ROOT removed (REMOVE), or enabled or disabled (ENABLED): each file changed is published
    /// and sent to ROOT's sessions.
    /// Toggle All Breakpoints: every breakpoint of ROOT off when any is on, else all on; the state it leaves.
    pub async fn toggle_all_breakpoints(&self, root: &str) -> bool {
        let any_on = self.store(root, |s| {
            s.paths().iter().any(|p| {
                s.view(p)["breakpoints"]
                    .as_array()
                    .is_some_and(|bs| bs.iter().any(|b| b["enabled"] == true))
            })
        });
        self.all_breakpoints(root, false, !any_on).await;
        !any_on
    }

    pub async fn all_breakpoints(&self, root: &str, remove: bool, enabled: bool) {
        let ops: Vec<breakpoints::Op> = self.store(root, |s| {
            let mut ops = vec![];
            for p in s.paths() {
                for b in s.view(&p)["breakpoints"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                {
                    let Some(id) = b["id"].as_u64() else { continue };
                    ops.push(if remove {
                        breakpoints::Op::Remove { id }
                    } else {
                        breakpoints::Op::Edit {
                            id,
                            enabled: Some(enabled),
                            condition: None,
                            hit: None,
                            log: None,
                        }
                    });
                }
            }
            if remove {
                for f in s.functions() {
                    let name = f["name"].as_str().unwrap_or_default().to_owned();
                    ops.push(breakpoints::Op::RemoveFunction { name });
                }
            }
            ops
        });
        let mut paths = std::collections::BTreeSet::new();
        let mut functions = false;
        for op in ops {
            if let Some(c) = self.store(root, |s| s.apply(op)) {
                if c.path.is_empty() {
                    functions = true;
                } else {
                    paths.insert(c.path);
                }
            }
        }
        for path in &paths {
            self.publish_bps(root, path);
        }
        for id in self.sessions_in(root) {
            for path in &paths {
                self.resend(&id, path).await;
            }
            if functions {
                self.resend_functions(&id).await;
            }
        }
        self.changed();
    }

    /// Send session ID PATH's breakpoints again (an edit, a Run to Cursor, one gone at a stop) and show its answer.
    async fn resend(&self, id: &str, path: &str) {
        let Some((h, root, caps, adapter)) = lock(&self.inner.state).sessions.get(id).map(|e| {
            (
                e.handle.clone(),
                e.root.clone(),
                e.caps.clone(),
                e.start.adapter_id.clone(),
            )
        }) else {
            return;
        };
        // not initialized yet: its configuration sends them
        if caps.is_null() {
            return;
        }
        let bps = self.store(&root, |s| s.send_list(id, path));
        let mut sent = breakpoints::fit(&bps, &caps);
        // the probes after the user's breakpoints: `answer` takes the answers in the order sent
        sent.extend(self.probe_bps(&root, path, &adapter, &caps, &bps));
        let args = json!({"source": {"path": path}, "breakpoints": sent});
        match h.request("setBreakpoints", args).await {
            Ok(body) => {
                let got = body
                    .get("breakpoints")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                self.store(&root, |s| s.answer(id, path, &got));
                self.publish_bps(&root, path);
            }
            Err(e) => tracing::debug!(target: "drgnx::debug", "setBreakpoints {path}: {e}"),
        }
    }

    async fn resend_functions(&self, id: &str) {
        let Some((h, root, caps)) = lock(&self.inner.state)
            .sessions
            .get(id)
            .map(|e| (e.handle.clone(), e.root.clone(), e.caps.clone()))
        else {
            return;
        };
        if caps
            .get("supportsFunctionBreakpoints")
            .and_then(Value::as_bool)
            != Some(true)
        {
            return;
        }
        let fns = self.store(&root, |s| s.functions());
        let args = json!({"breakpoints": breakpoints::fit(&fns, &caps)});
        if let Err(e) = h.request("setFunctionBreakpoints", args).await {
            tracing::debug!(target: "drgnx::debug", "setFunctionBreakpoints: {e}");
        }
    }

    /// The sessions of ROOT, children too.
    fn sessions_in(&self, root: &str) -> Vec<String> {
        lock(&self.inner.state)
            .sessions
            .iter()
            .filter(|(_, e)| e.root == root)
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// ROOT's breakpoints: OP applied (it reaches ROOT's sessions at once), then the view of the path it changed,
    /// else of PATH, with the function breakpoints.
    pub async fn breakpoints(
        &self,
        root: &str,
        op: Option<breakpoints::Op>,
        path: Option<&str>,
    ) -> Value {
        let change = op.and_then(|op| self.store(root, |s| s.apply(op)));
        let shown = match &change {
            Some(c) if !c.path.is_empty() => c.path.clone(),
            _ => path.unwrap_or_default().to_owned(),
        };
        if let Some(c) = &change {
            if c.path.is_empty() {
                for id in self.sessions_in(root) {
                    self.resend_functions(&id).await;
                }
                self.changed();
            } else {
                self.publish_bps(root, &c.path);
                for id in self.sessions_in(root) {
                    self.resend(&id, &c.path).await;
                }
            }
        }
        let mut v = self.store(root, |s| s.view(&shown));
        v["root"] = json!(root);
        v["functions"] = json!(self.store(root, |s| s.functions()));
        if let Some(id) = change.and_then(|c| c.id) {
            v["added"] = json!(id);
        }
        v
    }

    /// Run to Cursor: session ID stops at PATH's LINE once (a breakpoint for it alone, gone at its next stop or end),
    /// continuing it when it is stopped.
    pub async fn run_to_cursor(&self, id: &str, path: &str, line: u32) -> Result<(), String> {
        let root = self
            .root_of(id)
            .ok_or_else(|| format!("no debug session {id}"))?;
        self.store(&root, |s| s.add_temp(id, path, line));
        self.resend(id, path).await;
        if let Some(stop) = self.stop_of(id) {
            self.control(
                id,
                Op::Continue {
                    thread: Some(stop.thread),
                },
            )
            .await?;
        }
        Ok(())
    }

    /// Start START for connection CONN in project ROOT through LAUNCHER; its id.
    pub async fn start(
        &self,
        conn: u64,
        root: &str,
        start: Start,
        launcher: Arc<dyn Launcher>,
    ) -> Result<String, String> {
        self.start_with(conn, root, start, launcher, record::Launch::default())
            .await
    }

    /// [`Debug::start`], with what the launch adds to its recorded run.
    pub async fn start_with(
        &self,
        conn: u64,
        root: &str,
        start: Start,
        launcher: Arc<dyn Launcher>,
        launch: record::Launch,
    ) -> Result<String, String> {
        self.start_as(conn, root, start, launcher, None, launch)
            .await
    }

    /// Boxed: a session's updates start its children through here.
    fn start_as(
        &self,
        conn: u64,
        root: &str,
        start: Start,
        launcher: Arc<dyn Launcher>,
        parent: Option<String>,
        launch: record::Launch,
    ) -> BoxFut<'static, Result<String, String>> {
        let me = self.clone();
        let root = root.to_owned();
        Box::pin(async move {
            me.start_boxed(conn, root, start, launcher, parent, launch)
                .await
        })
    }

    async fn start_boxed(
        self,
        conn: u64,
        root: String,
        mut start: Start,
        launcher: Arc<dyn Launcher>,
        parent: Option<String>,
        launch: record::Launch,
    ) -> Result<String, String> {
        let id = {
            let mut st = lock(&self.inner.state);
            if st.shut {
                return Err("the hub is stopping".into());
            }
            st.next += 1;
            format!("d{}", st.next)
        };
        self.fill(&root, &id, &mut start);
        if let Some(rec) = self.records() {
            match &parent {
                Some(p) => rec.attach(&id, p),
                None => {
                    rec.begin(&id, &root, &mut start, launch).await;
                }
            }
            self.add_probes(&root, &mut start);
        }
        let c = if parent.is_some() {
            launcher.child().await?
        } else {
            launcher.connect().await?
        };
        let (tx, rx) = mpsc::unbounded_channel();
        let handle = session::spawn(start.clone(), c.client, c.incoming, c.proc, tx);
        let (ended_tx, ended) = watch::channel(false);
        {
            let mut st = lock(&self.inner.state);
            st.sessions.insert(
                id.clone(),
                Entry {
                    handle,
                    name: start.name.clone(),
                    parent,
                    conn,
                    root,
                    start,
                    launcher,
                    phase: Phase::Starting,
                    reason: None,
                    caps: Value::Null,
                    stop: None,
                    ended,
                },
            );
        }
        self.publish_state();
        let me = self.clone();
        let sid = id.clone();
        crate::clock::spawn("debug:updates", async move {
            me.updates(sid, rx).await;
            let _ = ended_tx.send(true);
        });
        Ok(id)
    }

    /// START's breakpoints, functions and exception filters for session ID: ROOT's, as the store has them now.
    fn fill(&self, root: &str, id: &str, start: &mut Start) {
        self.store(root, |s| {
            start.breakpoints = s
                .paths_for(id)
                .into_iter()
                .map(|path| session::SourceBps {
                    breakpoints: s.send_list(id, &path),
                    path,
                })
                .collect();
            start.functions = s.functions();
            start.exception_filters = s.chosen_filters(&start.adapter_id);
        });
    }

    /// START's breakpoints with ROOT's probes added (a path with only probes gets its own entry).
    fn add_probes(&self, root: &str, start: &mut Start) {
        let Some(rec) = self.records() else { return };
        for path in rec.probes(root, |p| p.paths()) {
            if !start.breakpoints.iter().any(|s| s.path == path) {
                start.breakpoints.push(session::SourceBps {
                    path: path.clone(),
                    breakpoints: vec![],
                });
            }
        }
        for s in &mut start.breakpoints {
            let extra = self.probe_bps(
                root,
                &s.path,
                &start.adapter_id,
                &Value::Null,
                &s.breakpoints,
            );
            s.breakpoints.extend(extra);
        }
    }

    fn handle(&self, id: &str) -> Option<Handle> {
        lock(&self.inner.state)
            .sessions
            .get(id)
            .map(|e| e.handle.clone())
    }

    /// The sessions started in ROOT that have no parent.
    pub fn in_root(&self, root: &str) -> Vec<String> {
        lock(&self.inner.state)
            .sessions
            .iter()
            .filter(|(_, e)| e.root == root && e.parent.is_none())
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// The session ids, with their parents.
    pub fn list(&self) -> Vec<(String, Option<String>)> {
        lock(&self.inner.state)
            .sessions
            .iter()
            .map(|(id, e)| (id.clone(), e.parent.clone()))
            .collect()
    }

    /// The current stop of session ID.
    pub fn stop_of(&self, id: &str) -> Option<Stop> {
        lock(&self.inner.state)
            .sessions
            .get(id)
            .and_then(|e| e.stop.clone())
    }

    /// The handle of session ID, for the views' requests (variables, evaluate …).
    pub fn session(&self, id: &str) -> Option<Handle> {
        self.handle(id)
    }

    /// OP on session ID. A stop or disconnect stops its children first and resolves once all have ended.
    /// The text of SESSION's source REFERENCE (a frame with no file): `{text, mime?}`.
    pub async fn source(&self, id: &str, reference: i64) -> Result<Value, String> {
        let h = self
            .handle(id)
            .ok_or_else(|| format!("no debug session {id}"))?;
        let b = h
            .request(
                "source",
                json!({"sourceReference": reference, "source": {"sourceReference": reference}}),
            )
            .await?;
        let mut out = json!({"text": b.get("content").and_then(Value::as_str).unwrap_or("")});
        if let Some(m) = b.get("mimeType").filter(|m| m.is_string()) {
            out["mime"] = m.clone();
        }
        Ok(out)
    }

    pub async fn control(&self, id: &str, op: Op) -> Result<(), String> {
        let h = self
            .handle(id)
            .ok_or_else(|| format!("no debug session {id}"))?;
        if let Some(rec) = self.records() {
            rec.op(id, &op);
        }
        if matches!(op, Op::Stop { .. } | Op::Disconnect) {
            for child in self.children(id) {
                Box::pin(self.control(&child, op.clone())).await.ok();
            }
            match h.op(op).await {
                // it ended while its children stopped (js-debug ends its root session once the program is gone)
                Err(e) if e == session::ENDED => {}
                r => r?,
            }
            self.wait_end(id).await;
            return Ok(());
        }
        h.op(op).await
    }

    fn children(&self, id: &str) -> Vec<String> {
        lock(&self.inner.state)
            .sessions
            .iter()
            .filter(|(_, e)| e.parent.as_deref() == Some(id))
            .map(|(c, _)| c.clone())
            .collect()
    }

    /// Resolves once session ID has ended (at once if there is no such session).
    pub(crate) async fn wait_end(&self, id: &str) {
        let rx = lock(&self.inner.state)
            .sessions
            .get(id)
            .map(|e| e.ended.clone());
        if let Some(mut rx) = rx {
            let _ = rx.wait_for(|e| *e).await;
        }
    }

    /// The hub is stopping: no new session, and every session stops (children first); resolves when all have ended.
    pub async fn shutdown(&self) {
        let roots: Vec<String> = {
            let mut st = lock(&self.inner.state);
            st.shut = true;
            st.sessions
                .iter()
                .filter(|(_, e)| e.parent.is_none())
                .map(|(id, _)| id.clone())
                .collect()
        };
        for id in roots {
            let _ = self
                .control(
                    &id,
                    Op::Stop {
                        kill_debuggee: None,
                    },
                )
                .await;
        }
    }

    fn publish_state(&self) {
        let sessions: Vec<Value> = lock(&self.inner.state)
            .sessions
            .iter()
            .map(|(id, e)| {
                json!({
                    "id": id,
                    "name": e.name,
                    "parent": e.parent,
                    "root": e.root,
                    "state": e.phase.name(),
                    "reason": e.reason,
                    "caps": e.caps,
                    // the toolbar's Disconnect in place of Stop
                    "attach": e.start.request == session::Request::Attach,
                })
            })
            .collect();
        if let Some(hook) = self.inner.on_state.get() {
            let mut roots: Vec<String> = sessions
                .iter()
                .filter_map(|s| s["root"].as_str().map(str::to_owned))
                .collect();
            roots.dedup();
            hook(roots);
        }
        self.inner
            .sink
            .broadcast("debug-state", json!({ "sessions": sessions }), None);
        self.changed();
    }

    async fn updates(&self, id: String, mut rx: mpsc::UnboundedReceiver<Update>) {
        while let Some(u) = rx.recv().await {
            match u {
                Update::Caps(c) => {
                    let root = lock(&self.inner.state).sessions.get_mut(&id).map(|e| {
                        e.caps = c.clone();
                        e.root.clone()
                    });
                    if let Some(root) = root {
                        self.store(&root, |s| s.set_caps(&id, c));
                    }
                }
                Update::Running { all, thread } => {
                    let changed = {
                        let mut st = lock(&self.inner.state);
                        st.sessions.get_mut(&id).map(|e| {
                            let whole = all
                                || e.stop
                                    .as_ref()
                                    .map(|s| Some(s.thread) == thread)
                                    .unwrap_or(true);
                            if whole {
                                e.stop = None;
                                e.phase = Phase::Running;
                                e.reason = None;
                            }
                            whole
                        })
                    };
                    if changed == Some(true) {
                        self.publish_state();
                    }
                }
                Update::Stopped(stop) => {
                    let conn = {
                        let mut st = lock(&self.inner.state);
                        st.sessions.get_mut(&id).map(|e| {
                            e.phase = Phase::Stopped;
                            e.reason = Some(stop.reason.clone());
                            e.stop = Some(stop.clone());
                            e.conn
                        })
                    };
                    self.publish_state();
                    if let Some(rec) = self.records() {
                        rec.stop(&id, &stop);
                    }
                    if let Some(conn) = conn {
                        self.publish_frame(&id, conn, &stop);
                        let values = self.inner.inline.at_stop(&id, &stop);
                        self.inner.sink.broadcast("debug-inline", values, None);
                    }
                    // Run to Cursor's breakpoint goes at the next stop
                    if let Some(root) = self.root_of(&id) {
                        let gone = self.store(&root, |s| s.stopped(&id));
                        if !gone.is_empty() {
                            let me = self.clone();
                            let sid = id.clone();
                            crate::clock::spawn("debug:run-to-cursor-gone", async move {
                                for path in gone {
                                    me.resend(&sid, &path).await;
                                }
                            });
                        }
                    }
                }
                Update::RunInTerminal { arguments, reply } => {
                    let conn = lock(&self.inner.state).sessions.get(&id).map(|e| e.conn);
                    let Some(conn) = conn else {
                        let _ = reply.send(Err("the session has ended".into()));
                        continue;
                    };
                    let terms = self.inner.terms.clone();
                    let sink = self.inner.sink.clone();
                    let sid = id.clone();
                    crate::clock::spawn("debug:run-in-terminal", async move {
                        let (cwd, args, env) = terminal_args(&arguments);
                        match terms.open(conn, cwd, args, env).await {
                            Ok(o) => {
                                show_terminal(
                                    &*sink,
                                    conn,
                                    json!({"session": sid, "term": o.term, "view": o.view, "editor": o.editor}),
                                );
                                let _ = reply.send(Ok(o.pid));
                            }
                            Err(e) => {
                                let _ = reply.send(Err(e));
                            }
                        }
                    });
                }
                Update::StartDebugging { arguments, reply } => {
                    let parent = lock(&self.inner.state)
                        .sessions
                        .get(&id)
                        .map(|e| (e.conn, e.root.clone(), e.start.clone(), e.launcher.clone()));
                    let Some((conn, root, mut start, launcher)) = parent else {
                        let _ = reply.send(Err("the session has ended".into()));
                        continue;
                    };
                    start.arguments = arguments
                        .get("configuration")
                        .cloned()
                        .unwrap_or_else(|| json!({}));
                    start.request =
                        if arguments.get("request").and_then(Value::as_str) == Some("attach") {
                            session::Request::Attach
                        } else {
                            session::Request::Launch
                        };
                    if let Some(n) = start.arguments.get("name").and_then(Value::as_str) {
                        start.name = n.to_owned();
                    }
                    // debugpy's child: its parent adapter's own listener
                    let launcher: Arc<dyn Launcher> =
                        match launch::child_server(&start.adapter_id, &arguments) {
                            Some(addr) => Arc::new(wire::Server { addr }),
                            None => launcher,
                        };
                    let me = self.clone();
                    let pid = id.clone();
                    crate::clock::spawn("debug:child", async move {
                        let r = me
                            .start_as(
                                conn,
                                &root,
                                start,
                                launcher,
                                Some(pid),
                                record::Launch::default(),
                            )
                            .await;
                        let _ = reply.send(r.map(|_| ()));
                    });
                }
                Update::Breakpoints { path, breakpoints } => {
                    if let Some(root) = self.root_of(&id) {
                        self.store(&root, |s| s.answer(&id, &path, &breakpoints));
                        self.publish_bps(&root, &path);
                    }
                }
                Update::Event { event, body } => {
                    // a probe's hits are recorded and stay out of the console
                    let body = match (event.as_str(), self.records()) {
                        ("output", Some(rec)) => match rec.output(&id, &body) {
                            Some(b) => b,
                            None => continue,
                        },
                        _ => body,
                    };
                    if event == "output" {
                        self.console_output(&id, &body);
                    }
                    if event == "breakpoint"
                        && let Some(root) = self.root_of(&id)
                        && let Some(path) = self.store(&root, |s| s.event(&id, &body))
                    {
                        self.publish_bps(&root, &path);
                    }
                }
                Update::Configure { reply } => {
                    let entry = lock(&self.inner.state)
                        .sessions
                        .get(&id)
                        .map(|e| (e.root.clone(), e.start.clone()));
                    if let Some((root, mut start)) = entry {
                        self.fill(&root, &id, &mut start);
                        self.add_probes(&root, &mut start);
                        let _ = reply.send(start);
                    }
                }
                Update::Ended(end) => {
                    self.ended(&id, end).await;
                    return;
                }
            }
        }
    }

    async fn ended(&self, id: &str, end: End) {
        if let Some(rec) = self.records() {
            rec.end(id, &end);
        }
        self.inner.inline.forget(id);
        let e = lock(&self.inner.state).sessions.remove(id);
        self.publish_state();
        // the console keeps what it printed: the line that waited for its newline goes too
        self.console_flush(id, true);
        let Some(e) = e else { return };
        // what it made of the breakpoints goes with it
        let paths = self.store(&e.root, |s| {
            let paths = s.sent_paths(id);
            s.ended(id);
            paths
        });
        for path in paths {
            self.publish_bps(&e.root, &path);
        }
        self.inner.sink.broadcast(
            "debug-ended",
            json!({"session": id, "name": e.name, "reason": end.reason, "exit_code": end.exit_code}),
            None,
        );
        // a restart: the same configuration again (with `__restart` when the adapter gave one)
        if let Some(value) = end.restart
            && e.parent.is_none()
            && !lock(&self.inner.state).shut
        {
            let mut start = e.start.clone();
            start.restart_with(value);
            let me = self.clone();
            crate::clock::spawn("debug:restart", async move {
                let _ = me.start(e.conn, &e.root, start, e.launcher).await;
            });
        }
    }

    fn publish_frame(&self, id: &str, conn: u64, stop: &Stop) {
        let Some(frame) = stop
            .frames
            .iter()
            .find(|f| f.get("id").and_then(Value::as_i64) == Some(stop.frame))
        else {
            return;
        };
        let source = frame.get("source").cloned().unwrap_or(Value::Null);
        let top = stop.frames.first().map(|f| f.get("id")) == Some(frame.get("id"));
        let mut data = json!({
            "session": id,
            "epoch": stop.epoch,
            "thread": stop.thread,
            "path": source.get("path"),
            "ref": source.get("sourceReference").filter(|r| r.as_i64().unwrap_or(0) > 0),
            "name": frame.get("name"),
            "source_name": source.get("name"),
            "line": frame.get("line"),
            "col": frame.get("column"),
            "top": top,
            "reason": stop.reason,
            "exception": (stop.reason == "exception").then(|| exception_card(stop)),
            "open": false,
        });
        // the editor that started the session opens the file; the others draw it where it is already shown
        self.inner
            .sink
            .broadcast("debug-frame", data.clone(), Some(conn));
        data["open"] = json!(true);
        self.inner.sink.send(conn, "debug-frame", data);
    }
}

/// An exception stop's card: `exceptionInfo`'s id, message, break mode, type and trace, else the stop's description.
fn exception_card(stop: &Stop) -> Value {
    let Some(info) = &stop.exception else {
        return json!({"message": stop.description});
    };
    let mut card = serde_json::Map::new();
    for (to, v) in [
        ("id", info.get("exceptionId")),
        ("message", info.get("description")),
        ("break_mode", info.get("breakMode")),
        ("type", info.pointer("/details/typeName")),
        ("trace", info.pointer("/details/stackTrace")),
    ] {
        if let Some(v) = v.filter(|v| !v.is_null()) {
            card.insert(to.into(), v.clone());
        }
    }
    if !card.contains_key("message") {
        card.insert("message".into(), json!(stop.description));
    }
    Value::Object(card)
}

/// `runInTerminal`'s cwd, args and env (null values unset nothing here: they are left out).
fn terminal_args(a: &Value) -> (String, Vec<String>, Vec<(String, String)>) {
    let cwd = a
        .get("cwd")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let args = a
        .get("args")
        .and_then(Value::as_array)
        .map(|v| {
            v.iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    let env = a
        .get("env")
        .and_then(Value::as_object)
        .map(|m| {
            m.iter()
                .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned())))
                .collect()
        })
        .unwrap_or_default();
    (cwd, args, env)
}
