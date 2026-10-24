//! MCP hosting (docs/develop/hub.md, "Sessions and their sockets"; design §5.8, K3): the coordination tools
//! (`norn::tools`) on a socket per session, and on the main socket for an outside agent's bridge.
//!
//! - **The socket is the identity.** `mcp/session` mints `mcp.sock` in the session's directory
//!   (`runstav::paths::session_dir`, Gleipnir 13b's: one directory per session, beside its agent `hub.sock` when it
//!   has one). Whoever connects to it is that session's agent: [`Row::identity`], never a tool argument or an
//!   environment variable.
//! - **Its tools** (call 16): the tracker and graph tools (21 tools in all) unless the session's task
//!   (`data.tracker_tools`) or else its profile (`tools.tracker` of `mcp/session`) turns them off (16); the profile
//!   is the identity's too, for grants by `profile:NAME`.  Both are kept in the row.
//! - **Recorded before bound** (design §3.3): the row is in `runtime.db` (`msession`) before the socket exists; a
//!   bind that fails takes the row back.
//! - **A connection:** the peer uid checked (as on every socket), at most [`MAX_CONNECTIONS`] at once (the next is
//!   closed and logged), no challenge: the first byte is MCP (`mimir::serve`).
//! - **Owners:** a session belongs to a pid and its start time.  It is closed when that process is gone (a zombie
//!   counts as gone; a later process with the pid is another one) at each [`TICK`], and at start the rows of live
//!   owners are bound again (a bridge redials the same path) and the others dropped with their directories.
//! - **Closing:** the socket, the connections, the directory (unless the session's agent `hub.sock` is still in it,
//!   which 13b's stop removes) and the row.  A stop unbinds the sockets and keeps the rows.
//! - **The gateway's socket** (Task 22): `gateway/register` with a session's `sid` binds `gateway.sock` in its
//!   directory (0600, once per session; [`Sessions::gateway_socket`]); it closes with the session, its tokens with it
//!   ([`crate::gateway`]).
//! - **Outside agents:** `mcp/attach` on the main socket ([`outside`]): `ext:KIND:PID-HASH` from the bridge's parent
//!   process ([`crate::peer`]); the connection then carries MCP ([`Sessions::serve_outside`]).

use crate::conn::peer_allowed;
use crate::front::Front;
use crate::hello::Session;
use crate::peer;
use mimir::{Limits, ServerInfo, Tool};
use norn::tools::{Coord, Ctx, Identity};
use runstav::methods::hub::McpStatus;
use runstav::methods::mcp::{SessionAnswer, SessionParams};
use runstav::paths::{self, Env};
use runstav::wire::{Error, ErrorCode};
use std::collections::BTreeMap;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::UnixListener;
use tokio_util::sync::CancellationToken;

/// The connections one session socket serves at once.
pub const MAX_CONNECTIONS: usize = 4;

/// How often the owners are looked at.
pub const TICK: Duration = Duration::from_secs(1);

/// A minted session id: this many lowercase hex digits.
const SID_HEX: usize = 12;

/// The coordination tools, shared by every connection.
pub type ToolList = Arc<[Box<dyn Tool<Ctx>>]>;

/// A session as `runtime.db` keeps it.
#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub sid: String,
    pub agent: String,
    pub job: Option<String>,
    pub task: Option<String>,
    pub cwd: Option<String>,
    pub owner: u32,
    /// `draugr::start_time` of the owner when the session was minted.
    pub owner_start: u64,
    pub at: f64,
    /// The drgnx profile the agent runs as (grants by `profile:NAME`).
    pub profile: Option<String>,
    /// The profile's tracker tools on or off (`None`: the profile says nothing).
    pub tracker: Option<bool>,
}

impl Row {
    /// Who the socket's tools act as.  A session minted without a `cwd` has `/`, which the report tools refuse as too
    /// wide.
    pub fn identity(&self) -> Identity {
        Identity::Session {
            agent: self.agent.clone(),
            sid: self.sid.clone(),
            profile: self.profile.clone(),
            job: self.job.clone(),
            task: self.task.clone(),
            home: PathBuf::from(self.cwd.as_deref().unwrap_or("/")),
        }
    }

    /// The entity id of the session's task: a tracker task's own id, a job task's `task:JOB#N` (its `task` that, or
    /// `N` with the job).
    pub fn task_entity(&self) -> Option<String> {
        let task = self.task.as_deref()?;
        if task.starts_with("task:") {
            Some(task.to_owned())
        } else if task.contains('#') {
            Some(norn::write::tasks::entity_id(task))
        } else {
            let job = self.job.as_deref()?;
            Some(norn::write::tasks::entity_id(&format!("{job}#{task}")))
        }
    }
}

/// `msession.tools` of TRACKER.
fn tools_text(tracker: Option<bool>) -> Option<String> {
    tracker.map(|t| serde_json::json!({ "tracker": t }).to_string())
}

/// TEXT of `msession.tools` as the profile's tracker setting (anything else: none).
fn tools_of(text: Option<String>) -> Option<bool> {
    let v: serde_json::Value = serde_json::from_str(text.as_deref()?).ok()?;
    v.get("tracker")?.as_bool()
}

/// Where sessions live: the hub's environment and main socket (for `session_dir`) and `runtime.db`.
struct Store {
    env: Env,
    socket: PathBuf,
    db: urdr::Handle,
}

/// A session whose socket is bound.
struct Live {
    row: Row,
    dir: PathBuf,
    path: PathBuf,
    /// Ends its accept loop and its connections (and the gateway socket's).
    cancel: CancellationToken,
    /// Its `gateway.sock`, once a registration asked for it.
    gateway: Option<PathBuf>,
}

/// The front's MCP hosting.
pub struct Sessions {
    uid: u32,
    tools: Arc<Coord>,
    /// Every tool: an outside bridge's.
    list: ToolList,
    /// A session's, made when first served: without the tracker tools (16), with them (21).
    by_sets: [OnceLock<ToolList>; 2],
    store: OnceLock<Store>,
    live: Mutex<BTreeMap<String, Live>>,
    /// Outside bridges connected now.
    outside: Arc<AtomicUsize>,
    /// One open or close at a time: a row and its socket change together.
    serial: tokio::sync::Mutex<()>,
}

/// Counts one connection while it lives.
struct Counted(Arc<AtomicUsize>);

impl Counted {
    fn new(n: &Arc<AtomicUsize>) -> Counted {
        n.fetch_add(1, Ordering::SeqCst);
        Counted(n.clone())
    }
}

impl Drop for Counted {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

fn error(code: ErrorCode, message: impl Into<String>, path: Option<&str>) -> Error {
    Error {
        code,
        message: message.into(),
        path: path.map(str::to_owned),
    }
}

fn internal(message: impl Into<String>) -> Error {
    error(ErrorCode::Internal, message, None)
}

fn invalid(path: &str, message: impl Into<String>) -> Error {
    error(ErrorCode::InvalidParams, message, Some(path))
}

/// Seconds since the epoch.
fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// PID's start time while it runs (a zombie has ended), else `None`.
pub fn owner_start(pid: i32) -> Option<u64> {
    if pid <= 0 || !draugr::alive(pid) || peer::zombie(pid) {
        return None;
    }
    draugr::start_time(pid).ok()
}

/// Whether ROW's owner still runs: its pid, with the start time the row recorded (a reused pid is another process).
pub fn owner_alive(row: &Row) -> bool {
    i32::try_from(row.owner)
        .ok()
        .and_then(owner_start)
        .is_some_and(|start| start == row.owner_start)
}

/// PATH bound as a session socket: a stale one removed first, then mode 0600 (its directory is 0700 already).
pub fn bind_socket(path: &Path) -> io::Result<UnixListener> {
    match std::fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
        _ => {}
    }
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

/// A session's directory gone with what is in it, unless its agent `hub.sock` is still there (13b's: the stop
/// removes it).
fn remove_dir(dir: &Path) {
    if std::fs::symlink_metadata(dir.join(paths::SESSION_HUB_SOCKET)).is_ok() {
        return;
    }
    match std::fs::remove_dir_all(dir) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => {
            tracing::warn!("cannot remove {}: {e}", dir.display());
        }
        _ => {}
    }
}

fn remove_socket(path: &Path) {
    match std::fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => {
            tracing::warn!("cannot remove {}: {e}", path.display());
        }
        _ => {}
    }
}

async fn insert(db: &urdr::Handle, row: &Row) -> urdr::Result<()> {
    let r = row.clone();
    db.write(move |c| {
        c.execute(
            "insert into msession(sid, agent, job, task, cwd, owner, owner_start, at, profile, tools) \
             values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            (
                r.sid,
                r.agent,
                r.job,
                r.task,
                r.cwd,
                i64::from(r.owner),
                i64::try_from(r.owner_start).unwrap_or(i64::MAX),
                r.at,
                r.profile,
                tools_text(r.tracker),
            ),
        )?;
        Ok(())
    })
    .await
}

async fn delete(db: &urdr::Handle, sid: &str) {
    let s = sid.to_owned();
    if let Err(e) = db
        .write(move |c| Ok(c.execute("delete from msession where sid = ?1", [s])?))
        .await
    {
        tracing::warn!(sid, "cannot remove a session from runtime.db: {e}");
    }
}

async fn rows(db: &urdr::Handle) -> urdr::Result<Vec<Row>> {
    db.read(|c| {
        let mut st = c.prepare(
            "select sid, agent, job, task, cwd, owner, owner_start, at, profile, tools from msession order by at",
        )?;
        let rows = st
            .query_map([], |r| {
                Ok(Row {
                    sid: r.get(0)?,
                    agent: r.get(1)?,
                    job: r.get(2)?,
                    task: r.get(3)?,
                    cwd: r.get(4)?,
                    owner: u32::try_from(r.get::<_, i64>(5)?).unwrap_or(0),
                    owner_start: u64::try_from(r.get::<_, i64>(6)?).unwrap_or(0),
                    at: r.get(7)?,
                    profile: r.get(8)?,
                    tracker: tools_of(r.get(9)?),
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    })
    .await
}

/// Accept on a session's socket until CANCEL: each connection serves the tools as WHO.
async fn accept(
    listener: UnixListener,
    sid: String,
    who: Identity,
    cancel: CancellationToken,
    uid: u32,
    tools: Arc<Coord>,
    list: ToolList,
) {
    let ctx: Arc<Ctx> = Arc::new((tools, who));
    let open = Arc::new(AtomicUsize::new(0));
    loop {
        let stream = tokio::select! {
            () = cancel.cancelled() => return,
            a = listener.accept() => match a {
                Ok((s, _)) => s,
                Err(e) => {
                    // out of descriptors, for example: never a hot loop
                    tracing::warn!(sid, "accept failed: {e}");
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    continue;
                }
            },
        };
        match stream.peer_cred() {
            Ok(c) if peer_allowed(c.uid(), uid) => {}
            Ok(c) => {
                tracing::warn!(
                    sid,
                    peer_pid = c.pid(),
                    peer_uid = c.uid(),
                    "refused a connection from another uid"
                );
                continue;
            }
            Err(e) => {
                tracing::warn!(sid, "refused a connection whose peer cannot be read: {e}");
                continue;
            }
        }
        if open.load(Ordering::SeqCst) >= MAX_CONNECTIONS {
            tracing::warn!(
                sid,
                "closed a connection to a session's mcp.sock: it serves at most {MAX_CONNECTIONS} at once"
            );
            continue;
        }
        let counted = Counted::new(&open);
        let (ctx, list, cancel, sid) = (ctx.clone(), list.clone(), cancel.clone(), sid.clone());
        tokio::spawn(async move {
            let _counted = counted;
            let (r, w) = stream.into_split();
            tokio::select! {
                () = cancel.cancelled() => {}
                end = mimir::serve(ctx, list, ServerInfo::default(), r, w, Limits::default()) => {
                    tracing::debug!(sid, ?end, "an MCP connection ended");
                }
            }
        });
    }
}

impl Sessions {
    /// No session yet, and none until [`Sessions::open_store`] gives it `runtime.db`.
    pub fn new(uid: u32, tools: Arc<Coord>, list: ToolList) -> Sessions {
        Sessions {
            uid,
            tools,
            list,
            by_sets: [OnceLock::new(), OnceLock::new()],
            store: OnceLock::new(),
            live: Mutex::new(BTreeMap::new()),
            outside: Arc::new(AtomicUsize::new(0)),
            serial: tokio::sync::Mutex::new(()),
        }
    }

    /// Sessions are kept in DB, their directories made for the hub's main SOCKET under ENV (once; at start).
    pub fn open_store(&self, env: Env, socket: PathBuf, db: urdr::Handle) {
        if self.store.set(Store { env, socket, db }).is_err() {
            tracing::warn!("the sessions' store was given twice: the first is kept");
        }
    }

    fn store(&self) -> Result<&Store, Error> {
        self.store
            .get()
            .ok_or_else(|| internal("runtime.db is not open: no session sockets"))
    }

    /// `status`'s `mcp`.
    pub fn status(&self) -> McpStatus {
        McpStatus {
            sessions: self.live.lock().expect("sessions").len() as u64,
            outside: self.outside.load(Ordering::SeqCst) as u64,
        }
    }

    /// `mcp/session`.
    pub async fn open(&self, p: SessionParams) -> Result<SessionAnswer, Error> {
        self.open_with(p, bind_socket).await
    }

    /// [`Sessions::open`] with the socket bound by BIND (the tests look between the row and the bind).
    pub async fn open_with<B>(&self, p: SessionParams, bind: B) -> Result<SessionAnswer, Error>
    where
        B: FnOnce(&Path) -> io::Result<UnixListener>,
    {
        let store = self.store()?;
        let agent = p.agent.as_str().to_owned();
        if agent.trim().eq_ignore_ascii_case("user") || !norn::tools::identity::plain_id(&agent) {
            return Err(invalid(
                "agent",
                format!(
                    "not an agent's id (letters, digits and . _ : - only, at most 64; never user): {agent:?}"
                ),
            ));
        }
        let owner = i32::try_from(p.owner)
            .ok()
            .filter(|o| *o > 0)
            .ok_or_else(|| invalid("owner", "not a process id"))?;
        let owner_start = owner_start(owner)
            .ok_or_else(|| invalid("owner", format!("process {owner} is not running")))?;
        let _one = self.serial.lock().await;
        let sid = match &p.sid {
            Some(s) => s.as_str().to_owned(),
            None => runstav::proof::nonce().map_err(|e| internal(format!("no session id: {e}")))?
                [..SID_HEX]
                .to_owned(),
        };
        let taken = self.live.lock().expect("sessions").contains_key(&sid);
        if taken {
            return Err(invalid(
                "sid",
                format!("session {sid} has its mcp.sock already"),
            ));
        }
        let dir = paths::make_session_dir(&store.env, &store.socket, &sid)
            .map_err(|e| internal(format!("session {sid}'s directory: {e}")))?;
        let row = Row {
            sid: sid.clone(),
            agent,
            job: p.job.map(|j| j.as_str().to_owned()),
            task: p.task.map(|t| t.as_str().to_owned()),
            cwd: p.cwd.map(|c| c.as_str().to_owned()),
            owner: owner as u32,
            owner_start,
            at: now(),
            profile: p.profile.map(|n| n.as_str().to_owned()),
            tracker: p.tools.map(|t| t.tracker),
        };
        // recorded before bound: a hub that dies in between leaves a row whose socket the next start binds
        insert(&store.db, &row)
            .await
            .map_err(|e| internal(format!("cannot record session {sid} in runtime.db: {e}")))?;
        let path = dir.join(paths::SESSION_MCP_SOCKET);
        let listener = match bind(&path) {
            Ok(l) => l,
            Err(e) => {
                delete(&store.db, &sid).await;
                if p.sid.is_none() {
                    remove_dir(&dir);
                }
                return Err(internal(format!("cannot bind {}: {e}", path.display())));
            }
        };
        let list = self.list_for(&row).await;
        self.listen(row, dir, path.clone(), listener, list);
        Ok(SessionAnswer {
            sid,
            socket: path.to_string_lossy().into_owned(),
        })
    }

    /// The tools ROW's socket serves (call 16): the tracker tools as its task says, else as its profile says, else on.
    async fn list_for(&self, row: &Row) -> ToolList {
        let task = match row.task_entity() {
            Some(id) => crate::graph::task_tools(&self.tools, id).await,
            None => None,
        };
        let sets = crate::graph::tool_sets(task, row.tracker);
        self.by_sets[usize::from(sets.tracker)]
            .get_or_init(|| norn::tools::tools_for(sets).into())
            .clone()
    }

    /// Serve ROW's socket PATH (in DIR) from LISTENER, with the tools LIST.
    fn listen(
        &self,
        row: Row,
        dir: PathBuf,
        path: PathBuf,
        listener: UnixListener,
        list: ToolList,
    ) {
        let cancel = CancellationToken::new();
        tokio::spawn(accept(
            listener,
            row.sid.clone(),
            row.identity(),
            cancel.clone(),
            self.uid,
            self.tools.clone(),
            list,
        ));
        tracing::info!(
            sid = row.sid,
            agent = row.agent,
            owner = row.owner,
            "the coordination tools on {}",
            path.display()
        );
        self.live.lock().expect("sessions").insert(
            row.sid.clone(),
            Live {
                row,
                dir,
                path,
                cancel,
                gateway: None,
            },
        );
    }

    /// Session SID's `mcp.sock`, while it is bound.
    pub fn socket_of(&self, sid: &str) -> Option<PathBuf> {
        self.live
            .lock()
            .expect("sessions")
            .get(sid)
            .map(|l| l.path.clone())
    }

    /// Whether session SID's socket is bound now.
    pub fn is_live(&self, sid: &str) -> bool {
        self.live.lock().expect("sessions").contains_key(sid)
    }

    /// Session SID's `gateway.sock`: bound (0600) and handed to SERVE with a token that ends with the session, the
    /// first time; its path every time.  No such session is `invalid-params` (path `sid`).
    pub fn gateway_socket(
        &self,
        sid: &str,
        serve: impl FnOnce(UnixListener, CancellationToken),
    ) -> Result<PathBuf, Error> {
        let mut live = self.live.lock().expect("sessions");
        let Some(l) = live.get_mut(sid) else {
            return Err(invalid(
                "sid",
                format!("no session {sid} in this hub: mcp/session opens one"),
            ));
        };
        if let Some(path) = &l.gateway {
            return Ok(path.clone());
        }
        let path = l.dir.join(paths::SESSION_GATEWAY_SOCKET);
        let listener = bind_socket(&path)
            .map_err(|e| internal(format!("cannot bind {}: {e}", path.display())))?;
        serve(listener, l.cancel.child_token());
        tracing::info!(sid, "the gateway on {}", path.display());
        l.gateway = Some(path.clone());
        Ok(path)
    }

    /// `mcp/session-close`: false when there is no such session.
    pub async fn close(&self, sid: &str) -> Result<bool, Error> {
        let store = self.store()?;
        let _one = self.serial.lock().await;
        Ok(self.end(store, sid, "closed").await)
    }

    /// SID's socket, connections, directory and row gone (WHY logged); false when it was not live.  The caller holds
    /// `serial`.
    async fn end(&self, store: &Store, sid: &str, why: &str) -> bool {
        let live = self.live.lock().expect("sessions").remove(sid);
        let Some(live) = live else {
            return false;
        };
        remove_socket(&live.path);
        if let Some(g) = &live.gateway {
            remove_socket(g);
        }
        remove_dir(&live.dir);
        delete(&store.db, sid).await;
        tracing::info!(
            sid,
            agent = live.row.agent,
            "a session's mcp.sock is gone: {why}"
        );
        // its connections last: a client that sees its connection close finds the socket, directory and row gone
        live.cancel.cancel();
        true
    }

    /// Close the sessions whose owner is gone (each tick).
    pub async fn prune(&self) {
        let gone: Vec<String> = self
            .live
            .lock()
            .expect("sessions")
            .iter()
            .filter(|(_, l)| !owner_alive(&l.row))
            .map(|(sid, _)| sid.clone())
            .collect();
        self.close_all(&gone, "its owner is gone").await;
    }

    /// Close the sessions OWNER owns, as if it had died (`__test_owner_gone`): how many.
    pub async fn owner_gone(&self, owner: u32) -> usize {
        let theirs: Vec<String> = self
            .live
            .lock()
            .expect("sessions")
            .iter()
            .filter(|(_, l)| l.row.owner == owner)
            .map(|(sid, _)| sid.clone())
            .collect();
        self.close_all(&theirs, "its owner is gone (test hook)")
            .await
    }

    async fn close_all(&self, sids: &[String], why: &str) -> usize {
        let Ok(store) = self.store() else { return 0 };
        let _one = self.serial.lock().await;
        let mut n = 0;
        for sid in sids {
            n += usize::from(self.end(store, sid, why).await);
        }
        n
    }

    /// At start, after the reaper and before serving: the rows of live owners bound again at their paths, the others
    /// dropped with their directories.
    pub async fn restore(&self) {
        let Ok(store) = self.store() else { return };
        let all = match rows(&store.db).await {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("cannot read runtime.db's sessions: {e}");
                return;
            }
        };
        let _one = self.serial.lock().await;
        for row in all {
            if !owner_alive(&row) {
                if let Ok(dir) = paths::session_dir(&store.env, &store.socket, &row.sid) {
                    remove_dir(&dir);
                }
                delete(&store.db, &row.sid).await;
                tracing::info!(
                    sid = row.sid,
                    owner = row.owner,
                    "dropped a session whose owner is gone"
                );
                continue;
            }
            let bound =
                paths::make_session_dir(&store.env, &store.socket, &row.sid).and_then(|dir| {
                    let path = dir.join(paths::SESSION_MCP_SOCKET);
                    bind_socket(&path).map(|l| (dir, path, l))
                });
            match bound {
                Ok((dir, path, listener)) => {
                    let list = self.list_for(&row).await;
                    self.listen(row, dir, path, listener, list)
                }
                Err(e) => {
                    tracing::warn!(sid = row.sid, "cannot bind a session's mcp.sock again: {e}");
                    delete(&store.db, &row.sid).await;
                }
            }
        }
    }

    /// At the stop, under the lock: every socket unbound and its connections ended.  Rows and directories stay: the
    /// next start binds them again.
    pub fn unbind_all(&self) {
        for live in self.live.lock().expect("sessions").values() {
            live.cancel.cancel();
            remove_socket(&live.path);
            if let Some(g) = &live.gateway {
                remove_socket(g);
            }
        }
    }

    /// An outside bridge's connection, after `mcp/attach`'s answer: the tools as WHO until it closes.
    pub async fn serve_outside<R, W>(&self, who: Identity, r: R, w: W)
    where
        R: AsyncRead + Unpin,
        W: AsyncWrite + Unpin,
    {
        let _counted = Counted::new(&self.outside);
        let id = who.id().unwrap_or_default().to_owned();
        tracing::info!(identity = id, "an outside agent's bridge attached");
        let ctx: Arc<Ctx> = Arc::new((self.tools.clone(), who));
        let end = mimir::serve(
            ctx,
            self.list.clone(),
            ServerInfo::default(),
            r,
            w,
            Limits::default(),
        )
        .await;
        tracing::info!(identity = id, ?end, "an outside agent's bridge ended");
    }
}

/// `mcp/attach {kind}` on connection S: the identity of the agent that started the bridge (the peer's parent),
/// `ext:KIND:PID-HASH`, its home the folder S's hello named.  Never from a claim.
pub fn outside(s: &Session, kind: &str) -> Result<Identity, Error> {
    let pid = s
        .peer_pid
        .ok_or_else(|| internal("the bridge's process cannot be read from its connection"))?;
    let parent = peer::parent_of(pid)
        .map_err(|e| internal(format!("the bridge's parent process cannot be read: {e}")))?;
    if parent.pid <= 1 {
        return Err(error(
            ErrorCode::NotAllowed,
            "an outside agent needs a parent process",
            None,
        ));
    }
    Identity::outside(kind, parent.pid, parent.start, s.cwd.clone()).map_err(|e| invalid("kind", e))
}

/// Close the sessions of gone owners each [`TICK`], for as long as the hub serves.
pub async fn watch(front: Arc<Front>) {
    let mut every = tokio::time::interval(TICK);
    every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        every.tick().await;
        front.mcp.prune().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dispatch::NoBackend;
    use crate::store::WorkDb;
    use runstav::proof::Cap;
    use serde_json::{Value, json};

    struct Hub {
        dir: tempfile::TempDir,
        front: Front,
        env: Env,
        socket: PathBuf,
        db: urdr::Handle,
        _store: urdr::Store,
    }

    fn hub() -> Hub {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("hub-x.sock");
        let (store, db) = crate::runtime_db::open(dir.path()).unwrap();
        let front = front(dir.path(), &socket);
        let env = Env::new(&[("TMPDIR", dir.path().to_str().unwrap())], front.uid);
        front
            .mcp
            .open_store(env.clone(), socket.clone(), db.clone());
        Hub {
            dir,
            front,
            env,
            socket,
            db,
            _store: store,
        }
    }

    fn front(dir: &Path, socket: &Path) -> Front {
        Front::new(
            Cap::generate().unwrap(),
            socket.to_path_buf(),
            WorkDb::spawn(dir.join("work.db")).unwrap(),
            norn::store::CoordDb::spawn(dir.join("work.db")),
            Arc::new(NoBackend),
        )
    }

    fn params(v: Value) -> SessionParams {
        runstav::decode::typed::<SessionParams>(&v).unwrap().0
    }

    fn me() -> u32 {
        std::process::id()
    }

    fn mode(p: &Path) -> u32 {
        std::fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    fn count(db: &Path, sql: &str) -> i64 {
        urdr::open_readonly(db)
            .unwrap()
            .query_row(sql, [], |r| r.get(0))
            .unwrap()
    }

    #[tokio::test]
    async fn the_row_is_written_before_the_bind() {
        let h = hub();
        let db = h.dir.path().join("runtime.db");
        let at_bind = Arc::new(Mutex::new(None));
        let (seen, file) = (at_bind.clone(), db.clone());
        let a = h
            .front
            .mcp
            .open_with(
                params(json!({"agent": "s-0000000a", "job": "j1", "cwd": "/w", "owner": me()})),
                move |path| {
                    let n = count(
                        &file,
                        "select count(*) from msession where agent = 's-0000000a'",
                    );
                    *seen.lock().unwrap() = Some(n);
                    bind_socket(path)
                },
            )
            .await
            .unwrap();
        assert_eq!(
            *at_bind.lock().unwrap(),
            Some(1),
            "the row is there when the socket is bound"
        );
        assert!(
            a.sid.len() == SID_HEX
                && a.sid
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "{}",
            a.sid
        );
        let path = PathBuf::from(&a.socket);
        assert_eq!(path.file_name().unwrap(), paths::SESSION_MCP_SOCKET);
        assert_eq!(
            path.parent().unwrap(),
            paths::session_dir(&h.env, &h.socket, &a.sid).unwrap()
        );
        assert_eq!((mode(path.parent().unwrap()), mode(&path)), (0o700, 0o600));
        assert_eq!(h.front.mcp.status().sessions, 1);
        // a bind that fails takes its row (and the directory it made) back
        let e = h
            .front
            .mcp
            .open_with(params(json!({"agent": "s-b", "owner": me()})), |_| {
                Err(io::Error::other("no"))
            })
            .await
            .unwrap_err();
        assert_eq!(e.code, ErrorCode::Internal);
        assert_eq!(count(&db, "select count(*) from msession"), 1);
        assert_eq!(h.front.mcp.status().sessions, 1);
        // what the socket's tools act as is the row's
        {
            let live = h.front.mcp.live.lock().unwrap();
            assert_eq!(
                live[&a.sid].row.identity(),
                Identity::Session {
                    agent: "s-0000000a".into(),
                    sid: a.sid.clone(),
                    profile: None,
                    job: Some("j1".into()),
                    task: None,
                    home: PathBuf::from("/w"),
                }
            );
        }
        // a profile and its tool sets are kept with the row, and the profile is the identity's
        let p = h
            .front
            .mcp
            .open(params(
                json!({"agent": "s-c", "owner": me(), "job": "j2", "task": "3",
                                "profile": "p1", "tools": {"tracker": false}}),
            ))
            .await
            .unwrap();
        let kept = rows(&h.db).await.unwrap();
        let row = kept.iter().find(|r| r.sid == p.sid).unwrap();
        assert_eq!(
            (row.profile.as_deref(), row.tracker),
            (Some("p1"), Some(false))
        );
        assert_eq!(row.task_entity().as_deref(), Some("task:j2#3"));
        assert!(matches!(
            row.identity(),
            Identity::Session { profile: Some(ref n), .. } if n == "p1"
        ));
    }

    #[tokio::test]
    async fn a_bad_agent_or_owner_is_refused_before_anything_is_made() {
        let h = hub();
        for (v, at) in [
            (json!({"agent": "user", "owner": me()}), "agent"),
            (json!({"agent": "a]b", "owner": me()}), "agent"),
            (json!({"agent": "s-1", "owner": 0}), "owner"),
            (
                json!({"agent": "s-1", "owner": u64::from(u32::MAX) + 1}),
                "owner",
            ),
        ] {
            let e = h.front.mcp.open(params(v.clone())).await.unwrap_err();
            assert_eq!(
                (e.code, e.path.as_deref()),
                (ErrorCode::InvalidParams, Some(at)),
                "{v}"
            );
        }
        assert_eq!(
            count(
                &h.dir.path().join("runtime.db"),
                "select count(*) from msession"
            ),
            0
        );
    }

    #[test]
    fn a_reused_owner_pid_is_gone() {
        let row = |owner, owner_start| Row {
            sid: "s".into(),
            agent: "a".into(),
            job: None,
            task: None,
            cwd: None,
            owner,
            owner_start,
            at: 0.0,
            profile: None,
            tracker: None,
        };
        let start = draugr::start_time(me() as i32).unwrap();
        assert!(owner_alive(&row(me(), start)));
        assert!(
            !owner_alive(&row(me(), start + 1)),
            "the same pid with another start time is another process"
        );
        assert!(!owner_alive(&row(0, start)));
        // a process that ended: a zombie until it is reaped, then nothing; gone either way
        let mut child = std::process::Command::new("sleep")
            .arg("60")
            .spawn()
            .unwrap();
        let pid = child.id();
        let start = draugr::start_time(pid as i32).unwrap();
        assert!(owner_alive(&row(pid, start)));
        child.kill().unwrap();
        for _ in 0..200 {
            if peer::zombie(pid as i32) {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!owner_alive(&row(pid, start)), "a zombie is gone");
        child.wait().unwrap();
        assert!(!owner_alive(&row(pid, start)));
    }

    #[tokio::test]
    async fn mcp_sock_goes_beside_an_existing_hub_sock() {
        let h = hub();
        let dir = paths::make_session_dir(&h.env, &h.socket, "s1").unwrap();
        let _agent =
            std::os::unix::net::UnixListener::bind(dir.join(paths::SESSION_HUB_SOCKET)).unwrap();
        let a = h
            .front
            .mcp
            .open(params(json!({"agent": "s-1", "sid": "s1", "owner": me()})))
            .await
            .unwrap();
        assert_eq!(
            (a.sid.as_str(), PathBuf::from(&a.socket)),
            ("s1", dir.join(paths::SESSION_MCP_SOCKET))
        );
        // one socket per session
        let e = h
            .front
            .mcp
            .open(params(json!({"agent": "s-1", "sid": "s1", "owner": me()})))
            .await
            .unwrap_err();
        assert_eq!(e.path.as_deref(), Some("sid"));
        assert!(h.front.mcp.close("s1").await.unwrap());
        assert!(!dir.join(paths::SESSION_MCP_SOCKET).exists());
        assert!(
            dir.join(paths::SESSION_HUB_SOCKET).exists(),
            "the agent socket's directory stays"
        );
        assert!(!h.front.mcp.close("s1").await.unwrap());
        // a session of its own: its directory goes with it
        let b = h
            .front
            .mcp
            .open(params(json!({"agent": "s-2", "owner": me()})))
            .await
            .unwrap();
        let bdir = PathBuf::from(&b.socket).parent().unwrap().to_path_buf();
        assert!(h.front.mcp.close(&b.sid).await.unwrap());
        assert!(!bdir.exists());
        assert_eq!(
            count(
                &h.dir.path().join("runtime.db"),
                "select count(*) from msession"
            ),
            0
        );
    }

    #[tokio::test]
    async fn a_restart_binds_live_owners_again_and_drops_the_rest() {
        let h = hub();
        let a = h
            .front
            .mcp
            .open(params(json!({"agent": "s-1", "owner": me()})))
            .await
            .unwrap();
        // a session whose owner was another process with this pid
        let gone = Row {
            sid: "0123456789ab".into(),
            agent: "s-2".into(),
            job: None,
            task: None,
            cwd: None,
            owner: me(),
            owner_start: draugr::start_time(me() as i32).unwrap() + 1,
            at: 1.0,
            profile: None,
            tracker: None,
        };
        insert(&h.db, &gone).await.unwrap();
        let gone_dir = paths::make_session_dir(&h.env, &h.socket, &gone.sid).unwrap();
        // the stop
        h.front.mcp.unbind_all();
        assert!(!Path::new(&a.socket).exists());
        // the next start
        let next = front(h.dir.path(), &h.socket);
        next.mcp
            .open_store(h.env.clone(), h.socket.clone(), h.db.clone());
        next.mcp.restore().await;
        assert_eq!(next.mcp.status().sessions, 1);
        assert!(Path::new(&a.socket).exists(), "bound again at its path");
        assert!(!gone_dir.exists());
        let sids: Vec<String> = rows(&h.db)
            .await
            .unwrap()
            .into_iter()
            .map(|r| r.sid)
            .collect();
        assert_eq!(sids, std::slice::from_ref(&a.sid));
        // the socket answers MCP at once (no challenge)
        let c = tokio::net::UnixStream::connect(&a.socket).await.unwrap();
        let (r, mut w) = c.into_split();
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
        w.write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n")
            .await
            .unwrap();
        let mut line = String::new();
        tokio::io::BufReader::new(r)
            .read_line(&mut line)
            .await
            .unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(v, json!({"jsonrpc": "2.0", "id": 1, "result": {}}));
    }
}
