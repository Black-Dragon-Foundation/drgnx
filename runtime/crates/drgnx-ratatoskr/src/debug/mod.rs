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
pub mod blocked;
pub mod breakpoints;
pub mod launch;
pub mod ports;
pub mod session;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_adapters;
#[cfg(test)]
mod tests_blocked;
#[cfg(test)]
mod tests_blocked_live;
#[cfg(test)]
mod tests_breakpoints;
#[cfg(test)]
mod tests_launch;
#[cfg(test)]
mod tests_ports;
#[cfg(test)]
mod tests_registry;
pub mod wire;

use breakpoints::Store;
use serde_json::{Value, json};
use session::{End, Handle, Op, Proc, Start, Stop, Update};
use std::collections::BTreeMap;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard};
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
}

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
            }),
        }
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

    fn root_of(&self, id: &str) -> Option<String> {
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
    }

    /// Send session ID PATH's breakpoints again (an edit, a Run to Cursor, one gone at a stop) and show its answer.
    async fn resend(&self, id: &str, path: &str) {
        let Some((h, root, caps)) = lock(&self.inner.state)
            .sessions
            .get(id)
            .map(|e| (e.handle.clone(), e.root.clone(), e.caps.clone()))
        else {
            return;
        };
        // not initialized yet: its configuration sends them
        if caps.is_null() {
            return;
        }
        let bps = self.store(&root, |s| s.send_list(id, path));
        let args = json!({"source": {"path": path}, "breakpoints": breakpoints::fit(&bps, &caps)});
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
        self.start_as(conn, root, start, launcher, None).await
    }

    /// Boxed: a session's updates start its children through here.
    fn start_as(
        &self,
        conn: u64,
        root: &str,
        start: Start,
        launcher: Arc<dyn Launcher>,
        parent: Option<String>,
    ) -> BoxFut<'static, Result<String, String>> {
        let me = self.clone();
        let root = root.to_owned();
        Box::pin(async move { me.start_boxed(conn, root, start, launcher, parent).await })
    }

    async fn start_boxed(
        self,
        conn: u64,
        root: String,
        mut start: Start,
        launcher: Arc<dyn Launcher>,
        parent: Option<String>,
    ) -> Result<String, String> {
        let id = {
            let mut st = lock(&self.inner.state);
            if st.shut {
                return Err("the hub is stopping".into());
            }
            st.next += 1;
            format!("d{}", st.next)
        };
        // the project's breakpoints, as the store has them now
        self.store(&root, |s| {
            start.breakpoints = s
                .paths_for(&id)
                .into_iter()
                .map(|path| session::SourceBps {
                    breakpoints: s.send_list(&id, &path),
                    path,
                })
                .collect();
            start.functions = s.functions();
            start.exception_filters = s.chosen_filters(&start.adapter_id);
        });
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
    pub async fn control(&self, id: &str, op: Op) -> Result<(), String> {
        let h = self
            .handle(id)
            .ok_or_else(|| format!("no debug session {id}"))?;
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

    async fn wait_end(&self, id: &str) {
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
                })
            })
            .collect();
        self.inner
            .sink
            .broadcast("debug-state", json!({ "sessions": sessions }), None);
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
                    if let Some(conn) = conn {
                        self.publish_frame(&id, conn, &stop);
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
                                sink.send(
                                    conn,
                                    "debug-terminal",
                                    json!({"session": sid, "term": o.term, "view": o.view}),
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
                    let me = self.clone();
                    let pid = id.clone();
                    crate::clock::spawn("debug:child", async move {
                        let r = me.start_as(conn, &root, start, launcher, Some(pid)).await;
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
                    if event == "breakpoint"
                        && let Some(root) = self.root_of(&id)
                        && let Some(path) = self.store(&root, |s| s.event(&id, &body))
                    {
                        self.publish_bps(&root, &path);
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
        let e = lock(&self.inner.state).sessions.remove(id);
        self.publish_state();
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
            "line": frame.get("line"),
            "col": frame.get("column"),
            "top": top,
            "reason": stop.reason,
            "exception": (stop.reason == "exception").then(|| stop.description.clone()).flatten(),
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
