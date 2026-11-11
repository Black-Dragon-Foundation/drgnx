//! Debugging (docs/develop/debugging.md): the hub owns each debug session, speaking the Debug Adapter Protocol to the
//! adapter through `vor`.
//!
//! - [`session`]: one session's life: the launch sequence, stops and their epochs, controls, the stop sequence.
//! - [`Debug`] (here): the hub's sessions: starting them through a [`Launcher`], children from `startDebugging`,
//!   restarts, `runInTerminal` in a drgnx terminal, the `debug-state` / `debug-frame` / `debug-terminal` events, and
//!   stopping (children before their parent; every session at the hub's end).

pub mod session;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_registry;

use serde_json::{Value, json};
use session::{End, Handle, Op, Proc, Start, Stop, Update};
use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard};
use tokio::sync::{mpsc, watch};

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

/// The program `runInTerminal` asks for, in a drgnx terminal.
pub trait Terminals: Send + Sync {
    /// Open a terminal for connection CONN running ARGS in CWD with ENV added: its id and the program's pid.
    fn open(
        &self,
        conn: u64,
        cwd: String,
        args: Vec<String>,
        env: Vec<(String, String)>,
    ) -> BoxFut<'_, Result<(String, i64), String>>;
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
        Debug {
            inner: Arc::new(Inner {
                sink,
                terms,
                state: Mutex::new(State::default()),
            }),
        }
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
        start: Start,
        launcher: Arc<dyn Launcher>,
        parent: Option<String>,
    ) -> Result<String, String> {
        if lock(&self.inner.state).shut {
            return Err("the hub is stopping".into());
        }
        let c = if parent.is_some() {
            launcher.child().await?
        } else {
            launcher.connect().await?
        };
        let (tx, rx) = mpsc::unbounded_channel();
        let handle = session::spawn(start.clone(), c.client, c.incoming, c.proc, tx);
        let (ended_tx, ended) = watch::channel(false);
        let id = {
            let mut st = lock(&self.inner.state);
            st.next += 1;
            let id = format!("d{}", st.next);
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
            id
        };
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
            h.op(op).await?;
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
                    if let Some(e) = lock(&self.inner.state).sessions.get_mut(&id) {
                        e.caps = c;
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
                            Ok((term, pid)) => {
                                sink.send(
                                    conn,
                                    "debug-terminal",
                                    json!({"session": sid, "term": term}),
                                );
                                let _ = reply.send(Ok(pid));
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
                Update::Breakpoints { .. } | Update::Event { .. } => {}
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
