//! The terminals (docs/develop/terminal.md): one `drgnx-term` worker per terminal, started in a scope of its own so
//! that it outlives the hub, recorded in `<state>/term/<id>.json`, adopted by the next hub. The hub routes between the
//! editor and the workers: a worker's patches and events go to the connection of the editor session that opened it,
//! the editor's input and acknowledgements to the worker.
//!
//! - [`adopt`]: finding the workers a hub before this one left, and their hellos.
//! - [`life`]: when an editor session is gone and its terminals end.

pub mod adopt;
pub mod life;
#[cfg(test)]
mod tests;

use drgnx_term::proto::{In, Out};
use drgnx_term::registry::{self, Record};
use drgnx_term::scope::{self, Limits};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, Weak};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::{mpsc, oneshot};

/// Where the terminals' events go: the editors' connections.
pub trait Sink: Send + Sync {
    /// EVENT with DATA to connection CONN; false when it took nothing.
    fn send(&self, conn: u64, event: &str, data: Value) -> bool;
}

impl Sink for crate::settings::agents::Editors {
    fn send(&self, conn: u64, event: &str, data: Value) -> bool {
        self.send_to(conn, event, data)
    }
}

/// How a terminal starts.
#[derive(Clone, Debug, Default)]
pub struct Spawn {
    pub cwd: String,
    /// The program and its arguments (none: the user's shell, `$SHELL` else `/bin/sh`).
    pub command: Vec<String>,
    /// The program's whole environment.
    pub env: Vec<(String, String)>,
    pub cols: u16,
    pub rows: u16,
    pub cell_px: (u32, u32),
    /// The rows above the screen the editor keeps.
    pub window: usize,
    /// The editor's display class (`gui`, `tty`).
    pub class: String,
    pub limits: Limits,
}

/// What `term/list` tells of a terminal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub id: String,
    pub pid: i32,
    pub running: bool,
    pub cwd: String,
    pub title: String,
    /// From a worker of another major protocol (a hub updated since it started).
    pub old: bool,
}

struct Term {
    rec: Record,
    tx: mpsc::UnboundedSender<String>,
    /// The connection the terminal's patches and events go to (none while its session is away).
    owner: Option<u64>,
    old: bool,
}

#[derive(Default)]
struct State {
    terms: HashMap<String, Term>,
    life: life::Life,
    /// Connection → the editor session it carries.
    sessions: HashMap<u64, String>,
    next_req: u64,
    waiting: HashMap<u64, oneshot::Sender<Out>>,
}

#[derive(Default)]
struct Inner {
    dir: OnceLock<PathBuf>,
    sink: OnceLock<Arc<dyn Sink>>,
    /// The hub instance id the patches carry.
    hub: OnceLock<u64>,
    state: Mutex<State>,
}

/// The hub's terminals.
#[derive(Clone, Default)]
pub struct Terms {
    inner: Arc<Inner>,
}

fn lock(m: &Mutex<State>) -> MutexGuard<'_, State> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

fn new_id() -> String {
    let mut b = [0u8; 6];
    let _ = getrandom::fill(&mut b);
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// The `drgnx-term` binary: `DRGNX_TERM_BIN`, else beside the hub's binary (or one folder up, for a test binary in
/// `target/debug/deps`).
pub fn worker_bin() -> PathBuf {
    if let Some(p) = std::env::var_os("DRGNX_TERM_BIN") {
        return PathBuf::from(p);
    }
    let exe = std::env::current_exe().unwrap_or_default();
    let dir = exe.parent().map(Path::to_path_buf).unwrap_or_default();
    [dir.join("drgnx-term"), dir.join("../drgnx-term")]
        .into_iter()
        .find(|p| p.is_file())
        .unwrap_or_else(|| dir.join("drgnx-term"))
}

impl Terms {
    /// Serve terminals from DIR (`<state>/term`) with events to SINK, patches stamped with HUB, and adopt the workers a
    /// hub before this one left. Runs inside a tokio runtime; a second call changes nothing.
    pub async fn open(&self, dir: PathBuf, sink: Arc<dyn Sink>, hub: u64) {
        if self.inner.dir.set(dir).is_err() {
            return;
        }
        let _ = self.inner.sink.set(sink);
        let _ = self.inner.hub.set(hub);
        self.adopt().await;
        let weak = Arc::downgrade(&self.inner);
        crate::clock::spawn("term:sessions", Terms::watch_sessions(weak));
    }

    fn dir(&self) -> Option<&Path> {
        self.inner.dir.get().map(PathBuf::as_path)
    }

    fn send_event(&self, conn: Option<u64>, event: &str, data: Value) {
        if let (Some(c), Some(s)) = (conn, self.inner.sink.get()) {
            s.send(c, event, data);
        }
    }

    /// Start a terminal for the editor session SESSION on connection CONN; its view is `term:<id>`. With a user
    /// systemd the worker runs in its own scope.
    pub async fn spawn(
        &self,
        conn: u64,
        session: Option<String>,
        s: Spawn,
    ) -> Result<Record, String> {
        self.spawn_as(conn, session, s, crate::exec::unit::systemd_user())
            .await
    }

    /// [`Terms::spawn`], in a scope or not (SYSTEMD).
    pub async fn spawn_as(
        &self,
        conn: u64,
        session: Option<String>,
        s: Spawn,
        systemd: bool,
    ) -> Result<Record, String> {
        let dir = self
            .dir()
            .ok_or("terminals: the store is not open yet")?
            .to_path_buf();
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let id = new_id();
        let socket = dir.join(format!("{id}.sock"));
        let mut command = s.command.clone();
        if command.is_empty() {
            command.push(
                s.env
                    .iter()
                    .find(|(k, _)| k == "SHELL")
                    .map(|(_, v)| v.clone())
                    .unwrap_or_else(|| "/bin/sh".into()),
            );
        }
        let mut worker = vec![
            worker_bin().to_string_lossy().into_owned(),
            "--socket".into(),
            socket.to_string_lossy().into_owned(),
            "--cols".into(),
            s.cols.max(1).to_string(),
            "--rows".into(),
            s.rows.max(1).to_string(),
            "--cell".into(),
            format!("{},{}", s.cell_px.0, s.cell_px.1),
            "--window".into(),
            s.window.to_string(),
            "--dir".into(),
            s.cwd.clone(),
            "--".into(),
        ];
        worker.extend(command);
        let (program, args) = scope::command(&id, &worker, systemd, &s.limits);
        let log =
            std::fs::File::create(dir.join(format!("{id}.log"))).map_err(|e| e.to_string())?;
        let mut cmd = std::process::Command::new(&program);
        cmd.args(&args)
            .env_clear()
            .envs(s.env.iter().map(|(k, v)| (k, v)))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(log);
        if systemd {
            // systemd-run reaches the user manager through these
            for k in ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"] {
                if !s.env.iter().any(|(n, _)| n == k)
                    && let Some(v) = std::env::var_os(k)
                {
                    cmd.env(k, v);
                }
            }
        }
        {
            use std::os::unix::process::CommandExt;
            // its own session: the hub's signals and its process group never reach it
            cmd.process_group(0);
        }
        let mut child = cmd.spawn().map_err(|e| format!("{program}: {e}"))?;
        let pid = child.id() as i32;
        // reaped by a thread of its own while this hub lives; after a restart, by init
        std::thread::spawn(move || {
            let _ = child.wait();
        });
        let start_time = draugr::start_time(pid).unwrap_or(0);
        let mut rec = Record {
            id: id.clone(),
            unit: systemd.then(|| scope::unit_name(&id)),
            pid,
            start_time,
            shell_pid: None,
            socket: socket.clone(),
            view: format!("term:{id}"),
            class: s.class.clone(),
            cwd: s.cwd.clone(),
            session: session.clone(),
        };
        rec.write(&dir).map_err(|e| e.to_string())?;
        // the worker binds its socket once it runs
        let mut tries = 0;
        let (r, w, hello) = loop {
            match adopt::connect(&socket, Duration::from_secs(5)).await {
                Ok(c) => break c,
                Err(e) if tries >= 100 => {
                    Record::remove(&dir, &id);
                    return Err(format!("the terminal worker did not answer: {e}"));
                }
                Err(_) => {
                    tries += 1;
                    crate::clock::sleep(Duration::from_millis(50)).await;
                }
            }
        };
        rec.shell_pid = Some(hello.shell_pid);
        let _ = rec.write(&dir);
        if let Some(sess) = &session {
            lock(&self.inner.state).sessions.insert(conn, sess.clone());
        }
        self.serve(rec.clone(), r, w, Some(conn), hello.old());
        self.attach(&id);
        Ok(rec)
    }

    /// Start serving the worker of REC on its connection.
    fn serve(
        &self,
        rec: Record,
        r: BufReader<OwnedReadHalf>,
        mut w: OwnedWriteHalf,
        owner: Option<u64>,
        old: bool,
    ) {
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let id = rec.id.clone();
        lock(&self.inner.state).terms.insert(
            id.clone(),
            Term {
                rec,
                tx,
                owner,
                old,
            },
        );
        crate::clock::spawn("term:write", async move {
            while let Some(line) = rx.recv().await {
                if w.write_all(line.as_bytes()).await.is_err() {
                    break;
                }
            }
        });
        let weak = Arc::downgrade(&self.inner);
        crate::clock::spawn("term:read", Terms::read(weak, id, r));
    }

    async fn read(weak: Weak<Inner>, id: String, mut r: BufReader<OwnedReadHalf>) {
        let mut line = String::new();
        loop {
            line.clear();
            let n = r.read_line(&mut line).await.unwrap_or(0);
            let Some(inner) = weak.upgrade() else { return };
            let t = Terms { inner };
            if n == 0 {
                // the worker went away without saying how the program ended
                t.ended(&id, json!({"id": id, "code": null, "signal": null}));
                return;
            }
            let Ok(out) = serde_json::from_str::<Out>(&line) else {
                continue;
            };
            if t.on_line(&id, out) {
                return;
            }
        }
    }

    /// A line from worker ID; true when it ended.
    fn on_line(&self, id: &str, out: Out) -> bool {
        let owner = lock(&self.inner.state).terms.get(id).and_then(|t| t.owner);
        let ev = |name: &str, mut data: Value| {
            data["id"] = json!(id);
            self.send_event(owner, name, data);
        };
        match out {
            Out::Patch { patch } => self.send_event(owner, "view-patch", json!(patch)),
            Out::Title { title } => ev("term/title", json!({"title": title})),
            Out::Cwd { cwd } => {
                if let Some(t) = lock(&self.inner.state).terms.get_mut(id) {
                    t.rec.cwd = cwd.clone();
                }
                ev("term/cwd", json!({"cwd": cwd}));
            }
            Out::Bell => ev("term/bell", json!({})),
            Out::Notify { title, body } => ev("term/notify", json!({"title": title, "body": body})),
            Out::Progress { state, value } => {
                ev("term/progress", json!({"state": state, "value": value}))
            }
            Out::ClipboardWrite {
                primary,
                mime,
                data,
            } => ev(
                "term/clipboard-write",
                json!({"primary": primary, "mime": mime, "data": data}),
            ),
            Out::Prompt { kind, exit } => ev("term/prompt", json!({"kind": kind, "exit": exit})),
            Out::Status { req, .. } => {
                if let Some(w) = lock(&self.inner.state).waiting.remove(&req) {
                    let _ = w.send(out);
                }
            }
            Out::Hello { proto, .. } => {
                if let Some(t) = lock(&self.inner.state).terms.get_mut(id) {
                    t.old = proto.0 != drgnx_term::proto::PROTO.0;
                }
            }
            Out::Exit { code, signal } => {
                self.ended(id, json!({"id": id, "code": code, "signal": signal}));
                return true;
            }
        }
        false
    }

    /// Terminal ID ended: `term/exit` to its editor, its record and socket gone.
    fn ended(&self, id: &str, data: Value) {
        let t = lock(&self.inner.state).terms.remove(id);
        let Some(t) = t else { return };
        self.send_event(t.owner, "term/exit", data);
        if let Some(dir) = self.dir() {
            Record::remove(dir, id);
            let _ = std::fs::remove_file(&t.rec.socket);
        }
    }

    /// Send MSG to worker ID; false when there is no such terminal (or it is from before the update and MSG is not
    /// `close`).
    pub fn send(&self, id: &str, msg: &In) -> bool {
        let st = lock(&self.inner.state);
        let Some(t) = st.terms.get(id) else {
            return false;
        };
        if t.old && !matches!(msg, In::Close { .. }) {
            return false;
        }
        let Ok(mut line) = serde_json::to_string(msg) else {
            return false;
        };
        line.push('\n');
        t.tx.send(line).is_ok()
    }

    /// Terminal ID draws for its view again: the next patch is a reset.
    fn attach(&self, id: &str) {
        let (view, class) = {
            let st = lock(&self.inner.state);
            let Some(t) = st.terms.get(id) else { return };
            (t.rec.view.clone(), t.rec.class.clone())
        };
        let hub = self.inner.hub.get().copied().unwrap_or(0);
        self.send(
            id,
            &In::Attach {
                view,
                class,
                hub,
                env_epoch: 0,
            },
        );
    }

    /// Adopt the workers in the store's folder (at the hub's start).
    async fn adopt(&self) {
        let Some(dir) = self.dir().map(Path::to_path_buf) else {
            return;
        };
        for rec in registry::read_all(&dir) {
            if !adopt::alive(&rec) {
                tracing::info!(id = %rec.id, "terminal gone while no hub ran: its record goes");
                Record::remove(&dir, &rec.id);
                let _ = std::fs::remove_file(&rec.socket);
                continue;
            }
            match adopt::connect(&rec.socket, Duration::from_secs(5)).await {
                Ok((r, w, hello)) => {
                    let old = hello.old();
                    if old {
                        tracing::warn!(id = %rec.id, proto = ?hello.proto, "terminal from before the update");
                    }
                    let mut st = lock(&self.inner.state);
                    // until its session says hello: then it draws again, from a reset
                    if let Some(s) = &rec.session {
                        st.life.closed(s, mono_ms());
                    }
                    drop(st);
                    self.serve(rec, r, w, None, old);
                }
                Err(e) => tracing::warn!(id = %rec.id, error = %e, "terminal not adopted"),
            }
        }
    }

    /// Connection CONN said hello as editor session SESSION: its terminals draw there again (a reset each).
    pub fn hello(&self, conn: u64, session: &str) {
        let ids: Vec<String> = {
            let mut st = lock(&self.inner.state);
            st.life.hello(session);
            st.sessions.insert(conn, session.to_owned());
            st.terms
                .iter_mut()
                .filter(|(_, t)| t.rec.session.as_deref() == Some(session))
                .map(|(id, t)| {
                    t.owner = Some(conn);
                    id.clone()
                })
                .collect()
        };
        for id in ids {
            self.attach(&id);
        }
    }

    /// Connection CONN is gone at NOW_MS: its terminals draw nowhere; its session's grace starts.
    pub fn gone_at(&self, conn: u64, now_ms: u64) {
        let mut st = lock(&self.inner.state);
        let session = st.sessions.remove(&conn);
        for t in st.terms.values_mut() {
            if t.owner == Some(conn) {
                t.owner = None;
            }
        }
        if let Some(s) = session
            && !st.sessions.values().any(|o| *o == s)
            && st
                .terms
                .values()
                .any(|t| t.rec.session.as_deref() == Some(s.as_str()))
        {
            st.life.closed(&s, now_ms);
        }
    }

    /// Connection CONN is gone.
    pub fn gone(&self, conn: u64) {
        self.gone_at(conn, mono_ms());
    }

    /// End the terminals of the sessions gone at NOW_MS.
    pub fn tick(&self, now_ms: u64) {
        let gone = lock(&self.inner.state).life.due(now_ms);
        for s in gone {
            tracing::info!(session = %s, "editor session gone: its terminals end");
            self.end_session(&s);
        }
    }

    /// End every terminal of editor session SESSION now (a clean exit, or the grace ran out).
    pub fn end_session(&self, session: &str) {
        let ids: Vec<String> = lock(&self.inner.state)
            .terms
            .iter()
            .filter(|(_, t)| t.rec.session.as_deref() == Some(session))
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            self.send(&id, &In::Close { signal: None });
        }
    }

    async fn watch_sessions(weak: Weak<Inner>) {
        let mut tick = crate::clock::interval(Duration::from_secs(1));
        loop {
            tick.tick().await;
            let Some(inner) = weak.upgrade() else { return };
            Terms { inner }.tick(mono_ms());
        }
    }

    /// Every terminal's status, asked of its worker; one that does not answer within DEADLINE counts as running.
    pub async fn list(&self, deadline: Duration) -> Vec<Status> {
        // (id, pid, old, cwd, the answer when asked)
        type Ask = (String, i32, bool, String, Option<oneshot::Receiver<Out>>);
        let asks: Vec<Ask> = {
            let mut st = lock(&self.inner.state);
            let ids: Vec<String> = st.terms.keys().cloned().collect();
            let mut asks = Vec::new();
            for id in ids {
                st.next_req += 1;
                let req = st.next_req;
                let (tx, rx) = oneshot::channel();
                st.waiting.insert(req, tx);
                let t = &st.terms[&id];
                let line = serde_json::to_string(&In::Status { req }).unwrap_or_default() + "\n";
                let sent = !t.old && t.tx.send(line).is_ok();
                asks.push((id, t.rec.pid, t.old, t.rec.cwd.clone(), sent.then_some(rx)));
            }
            asks
        };
        let mut out = Vec::new();
        for (id, pid, old, cwd, rx) in asks {
            let answer = match rx {
                Some(rx) => crate::clock::timeout(deadline, rx)
                    .await
                    .ok()
                    .and_then(Result::ok),
                None => None,
            };
            out.push(match answer {
                Some(Out::Status {
                    running,
                    cwd,
                    title,
                    ..
                }) => Status {
                    id,
                    pid,
                    running,
                    cwd,
                    title,
                    old,
                },
                _ => Status {
                    id,
                    pid,
                    running: true,
                    cwd,
                    title: String::new(),
                    old,
                },
            });
        }
        out.sort_by(|a, b| a.id.cmp(&b.id));
        out
    }

    /// The record of terminal ID.
    pub fn record(&self, id: &str) -> Option<Record> {
        lock(&self.inner.state).terms.get(id).map(|t| t.rec.clone())
    }

    /// Whether terminal ID is from before the update.
    pub fn is_old(&self, id: &str) -> Option<bool> {
        lock(&self.inner.state).terms.get(id).map(|t| t.old)
    }
}

/// Open the hub's terminals (`<state>/term`) and adopt the workers a hub before this one left, in the background.
pub fn start(f: &crate::front::Front) {
    let Some(dirs) = f.dirs.get() else { return };
    let dir = dirs
        .hub
        .parent()
        .map(|p| p.join("term"))
        .unwrap_or_else(|| dirs.hub.join("term"));
    let terms = f.core.terms.clone();
    let sink: Arc<dyn Sink> = f.editors.clone();
    let hub = f.core.views.hub_id();
    crate::clock::spawn("term:open", async move { terms.open(dir, sink, hub).await });
}

/// Milliseconds on the hub's clock.
fn mono_ms() -> u64 {
    static START: OnceLock<tokio::time::Instant> = OnceLock::new();
    let start = *START.get_or_init(crate::clock::now);
    crate::clock::now().duration_since(start).as_millis() as u64
}
