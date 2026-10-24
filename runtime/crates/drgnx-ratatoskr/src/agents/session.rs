//! One session: started on a profile with its lock and sandbox, its permissions answered by the user (or the matrix),
//! its snapshot and entries in records-2 shapes (`runstav::methods::agents::{Snapshot, Entry}`) so the mirror and
//! the cockpit read them unchanged (Task 8a); prompts that queue or steer, never cancel, redacted transcripts and the
//! step stream (Task 8b); `agents/move` (Task 26).
//!
//! The hub is the session's ACP client ([`hermod`]): one reader task per session turns the agent's updates into
//! entries, holds its permission requests until the user answers (`agents/permission`), and serves
//! `fs/read_text_file` and `fs/write_text_file` inside the session's directory only (a brainstorm may write only its
//! design document).  Changes reach the editors as `agent` and `agent-entries` events, at most one pair per session
//! per 50 ms.

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use crate::matrix_gate::Gate;
use crate::settings::AgentProfile;
use crate::settings::profiles::Mode as ProfileMode;
use hermod::schema::v1::{ReadTextFileResponse, RequestPermissionResponse, WriteTextFileResponse};
use hermod::{Conn, ConnOpts, Event, Incoming, SessionId};
use runstav::methods::Empty;
use runstav::methods::agents::{
    AgentOp, ById, DoParams, Entry, EntryType, Mode, MoveParams, Permission, PermissionParams,
    RpcId, SendParams, Sessions, Snapshot, StartParams, Started, Transcript, Usage, Via,
};
use runstav::methods::matrix::Role;
use runstav::registry::Class;
use runstav::types::RequestId;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Map, Value, json};
use std::collections::{BTreeSet, HashMap};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

/// Events about one session come at most this often.
const EMIT_EVERY: Duration = Duration::from_millis(50);
/// SIGTERM, then SIGKILL after this.
const STOP_GRACE: Duration = Duration::from_secs(3);

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

pub(crate) fn refuse(message: &str) -> Error {
    Error {
        code: ErrorCode::NotAllowed,
        message: message.into(),
        path: None,
    }
}

pub(crate) fn no_session(id: &str) -> Error {
    invalid("id", format!("no session {id}"))
}

fn invalid(path: &str, message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

fn internal(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
        path: None,
    }
}

/// A permission request the agent waits on.
struct Pending {
    request: u64,
    public: Permission,
    options: Vec<(String, String)>,
    resp: hermod::Responder<RequestPermissionResponse>,
}

struct State {
    status: runstav::methods::agents::SessionStatus,
    seq: u64,
    entries: Vec<Entry>,
    /// Tool call id → index in `entries`.
    tools: HashMap<String, usize>,
    /// The entry the next text chunk of that kind extends.
    open: Option<(EntryType, usize)>,
    /// Entries changed since the last event.
    dirty: BTreeSet<usize>,
    permissions: Vec<Pending>,
    usage: Option<Usage>,
    commands: Vec<Value>,
    exit: Option<i64>,
    stderr: Option<String>,
}

impl State {
    fn new() -> State {
        State {
            status: runstav::methods::agents::SessionStatus::Starting,
            seq: 0,
            entries: Vec::new(),
            tools: HashMap::new(),
            open: None,
            dirty: BTreeSet::new(),
            permissions: Vec::new(),
            usage: None,
            commands: Vec::new(),
            exit: None,
            stderr: None,
        }
    }

    fn push(&mut self, kind: EntryType, rest: Map<String, Value>) -> usize {
        self.entries.push(Entry { kind, rest });
        let i = self.entries.len() - 1;
        self.dirty.insert(i);
        i
    }

    /// Text of KIND (a user, agent or thought message chunk): joined onto the entry still open.
    fn text(&mut self, kind: EntryType, text: &str, message_id: Option<&str>) {
        if let Some((k, i)) = self.open
            && k == kind
        {
            let e = &mut self.entries[i];
            let old = e.rest.get("text").and_then(Value::as_str).unwrap_or("");
            let joined = format!("{old}{text}");
            e.rest
                .insert("length".into(), json!(joined.chars().count()));
            e.rest.insert("text".into(), json!(joined));
            self.dirty.insert(i);
            return;
        }
        let mut rest = Map::new();
        rest.insert("text".into(), json!(text));
        rest.insert("length".into(), json!(text.chars().count()));
        if let Some(m) = message_id {
            rest.insert("messageId".into(), json!(m));
        }
        let i = self.push(kind, rest);
        self.open = Some((kind, i));
    }

    /// One `session/update` of the agent (its JSON), as entries, commands and usage.
    fn apply(&mut self, u: &Value) {
        self.seq += 1;
        let kind = u.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        let text_of = |u: &Value| {
            let c = u.get("content");
            match c.and_then(|c| c.get("text")).and_then(Value::as_str) {
                Some(t) => t.to_string(),
                None => c.map(Value::to_string).unwrap_or_default(),
            }
        };
        let mid = u.get("messageId").and_then(Value::as_str);
        match kind {
            "user_message_chunk" => self.text(EntryType::User, &text_of(u), mid),
            "agent_message_chunk" => self.text(EntryType::Agent, &text_of(u), mid),
            "agent_thought_chunk" => self.text(EntryType::Thought, &text_of(u), mid),
            "tool_call" | "tool_call_update" => {
                self.open = None;
                let id = u
                    .get("toolCallId")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let idx = match self.tools.get(&id) {
                    Some(i) => *i,
                    None => {
                        let mut rest = Map::new();
                        rest.insert("id".into(), json!(id));
                        let i = self.push(EntryType::Tool, rest);
                        self.tools.insert(id, i);
                        i
                    }
                };
                let e = &mut self.entries[idx];
                for k in [
                    "title",
                    "kind",
                    "status",
                    "content",
                    "locations",
                    "rawInput",
                ] {
                    if let Some(v) = u.get(k).filter(|v| !v.is_null()) {
                        e.rest.insert(k.into(), v.clone());
                    }
                }
                self.dirty.insert(idx);
            }
            "plan" => {
                self.open = None;
                let mut rest = Map::new();
                rest.insert(
                    "entries".into(),
                    u.get("entries").cloned().unwrap_or(json!([])),
                );
                let last = self.entries.iter().rposition(|e| e.kind == EntryType::Plan);
                match last {
                    Some(i) => {
                        self.entries[i].rest = rest;
                        self.dirty.insert(i);
                    }
                    None => {
                        self.push(EntryType::Plan, rest);
                    }
                }
            }
            "available_commands_update" => {
                self.commands = u
                    .get("availableCommands")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
            }
            "usage_update" => {
                self.usage = Some(Usage {
                    used: u.get("used").and_then(Value::as_f64),
                    size: u.get("size").and_then(Value::as_f64),
                    cost: u.get("cost").filter(|c| !c.is_null()).cloned(),
                });
            }
            "notice" => {
                self.open = None;
                let mut rest = Map::new();
                rest.insert("text".into(), json!(text_of(u)));
                self.push(EntryType::Notice, rest);
            }
            _ => {}
        }
    }
}

/// A session the hub holds.
pub struct Session {
    pub id: String,
    pub started: f64,
    name: String,
    profile: String,
    role: Role,
    cwd: PathBuf,
    task: Option<String>,
    job: Option<String>,
    parent: Option<String>,
    about: Option<String>,
    document: Option<PathBuf>,
    via: Via,
    mode: Option<Mode>,
    provider: Option<String>,
    enforced: bool,
    enforced_why: Option<String>,
    capabilities: Option<Value>,
    conn: Conn,
    acp: SessionId,
    editors: Arc<crate::settings::agents::Editors>,
    scheduled: AtomicBool,
    next_request: AtomicU64,
    state: Mutex<State>,
}

/// Where a path may be read or written: inside the session's directory; a brainstorm writes its document only.
pub(crate) struct Fence {
    pub cwd: PathBuf,
    pub document: Option<PathBuf>,
}

fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// P with its longest existing part resolved (symlinks included), the rest as written.
fn resolve(p: &Path) -> PathBuf {
    let mut cur = normalize(p);
    let mut rest: Vec<std::ffi::OsString> = Vec::new();
    loop {
        if let Ok(mut c) = cur.canonicalize() {
            for r in rest.iter().rev() {
                c.push(r);
            }
            return c;
        }
        match cur.file_name().map(std::ffi::OsStr::to_owned) {
            Some(n) => {
                rest.push(n);
                cur.pop();
            }
            None => return normalize(p),
        }
    }
}

impl Fence {
    fn check(&self, path: &str, write: bool) -> Result<PathBuf, String> {
        let p = Path::new(path);
        if !p.is_absolute() {
            return Err(format!("{path}: not an absolute path"));
        }
        let real = resolve(p);
        if write && let Some(doc) = &self.document {
            return if real == resolve(doc) {
                Ok(real)
            } else {
                Err(format!(
                    "{path}: a brainstorm writes only its design document"
                ))
            };
        }
        if real.starts_with(resolve(&self.cwd))
            || (!write && self.document.as_ref().is_some_and(|d| real == resolve(d)))
        {
            Ok(real)
        } else {
            Err(format!("{path}: outside the session's directory"))
        }
    }
}

fn find_profile(front: &Front, name: &str) -> Option<AgentProfile> {
    let cur = front.settings.current();
    let v = &cur.loaded.values;
    v.agents_profiles
        .iter()
        .chain(&crate::settings::defaults().profiles)
        .find(|p| p.name == name)
        .cloned()
}

/// The launch of a test session: the profile's command, unsandboxed, with a short allowlisted environment.  Only
/// tests and `test-hooks` builds have it; no shipped path starts a session outside Gleipnir (Task 10 replaces it
/// with `launch::spawn`).
#[cfg(any(test, feature = "test-hooks"))]
fn launch_spec(
    p: &AgentProfile,
    cwd: &Path,
) -> Result<(draugr::Spec, bool, Option<String>), Error> {
    let (prog, args) = p
        .command
        .split_first()
        .ok_or_else(|| invalid("profile", "the profile has no command"))?;
    let pairs: Vec<(String, std::ffi::OsString)> = p
        .env
        .iter()
        .filter_map(|e| e.split_once('='))
        .map(|(k, v)| (k.to_string(), v.into()))
        .collect();
    let set: Vec<(&str, &std::ffi::OsStr)> = pairs
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_os_str()))
        .collect();
    let env = draugr::env::build(&["PATH", "HOME", "LANG", "TMPDIR"], &[], &set);
    let spec = draugr::Spec {
        program: PathBuf::from(prog),
        args: args.iter().map(Into::into).collect(),
        env,
        cwd: Some(cwd.to_path_buf()),
        stdin_null: false,
        pass_fds: Vec::new(),
        new_session: false,
    };
    Ok((
        spec,
        false,
        Some("a test launch: unsandboxed, no provider lock".into()),
    ))
}

#[cfg(not(any(test, feature = "test-hooks")))]
fn launch_spec(_: &AgentProfile, _: &Path) -> Result<(draugr::Spec, bool, Option<String>), Error> {
    Err(internal(
        "agents/start: the sandboxed launch is not there yet (agent system part 1, Task 10)",
    ))
}

pub(crate) async fn open(
    hub: &super::Hub,
    front: &Front,
    p: StartParams,
    caller: &Caller,
) -> Result<Started, Error> {
    if caller.class != Class::User {
        return Err(refuse("only the user starts a session"));
    }
    if p.role == Some(Role::Manager) {
        return Err(invalid(
            "role",
            "a manager is made through agents/role, not at start",
        ));
    }
    let profile = find_profile(front, p.profile.as_str()).ok_or_else(|| {
        invalid(
            "profile",
            format!("no agent profile {:?}", p.profile.as_str()),
        )
    })?;
    if p.about.is_some() != p.document.is_some() {
        return Err(invalid(
            "document",
            "a brainstorm needs both about (its topic note) and document (its design document)",
        ));
    }
    let sid = format!(
        "a{}",
        &runstav::proof::nonce().map_err(|e| internal(format!("no session id: {e}")))?[..12]
    );
    let name = format!("{}-{}", profile.name, &sid[1..5]);
    let role = p.role.unwrap_or(if p.task.is_some() || p.job.is_some() {
        Role::Worker
    } else {
        Role::Chat
    });
    let cwd = match &p.cwd {
        Some(c) => PathBuf::from(c.as_str()),
        None => {
            let hub_dir = front
                .dirs
                .get()
                .map(|d| d.hub.clone())
                .ok_or_else(|| internal("no hub directory"))?;
            let d = hub_dir.join("scratch").join(&sid);
            std::fs::create_dir_all(&d).map_err(|e| internal(format!("scratch directory: {e}")))?;
            d
        }
    };
    let (spec, enforced, enforced_why) = launch_spec(&profile, &cwd)?;
    let (conn, rx) = Conn::spawn(spec, ConnOpts::default())
        .await
        .map_err(|e| internal(e.to_string()))?;
    let init = async {
        let caps =
            serde_json::from_value(json!({"fs": {"readTextFile": true, "writeTextFile": true}}))
                .map_err(|e| hermod::Error::Decode(e.to_string()))?;
        let info = conn.initialize(caps).await?;
        let acp = conn.new_session(&cwd, Vec::new(), None).await?;
        Ok::<_, hermod::Error>((info, acp))
    };
    let (info, acp) = match init.await {
        Ok(x) => x,
        Err(e) => {
            draugr::kill_group(conn.pid(), Duration::ZERO, &draugr::RealSignaller).await;
            return Err(internal(format!("{}: {e}", profile.name)));
        }
    };
    let s = Arc::new(Session {
        id: sid.clone(),
        started: now(),
        name: name.clone(),
        profile: profile.name.clone(),
        role,
        cwd,
        task: p.task.as_ref().map(|t| t.as_str().to_string()),
        job: p.job.as_ref().map(|j| j.as_str().to_string()),
        parent: None,
        about: p.about.as_ref().map(|a| a.to_string()),
        document: p.document.as_ref().map(|d| PathBuf::from(d.as_str())),
        via: if profile.ai.is_some() {
            Via::Gateway
        } else {
            Via::Direct
        },
        mode: profile.mode.map(|m| match m {
            ProfileMode::Queue => Mode::Queue,
            ProfileMode::Steer => Mode::Steer,
            ProfileMode::Interrupt => Mode::Interrupt,
        }),
        provider: profile.ai.clone(),
        enforced,
        enforced_why,
        capabilities: serde_json::to_value(&info.caps).ok(),
        conn,
        acp,
        editors: front.editors.clone(),
        scheduled: AtomicBool::new(false),
        next_request: AtomicU64::new(1),
        state: Mutex::new(State::new()),
    });
    {
        let mut st = lock(&s.state);
        st.status = runstav::methods::agents::SessionStatus::Idle;
        st.seq += 1;
    }
    hub.insert(s.clone());
    tokio::spawn(s.clone().run(rx));
    if let Some(db) = hub.db() {
        insert_row(db, &s).await;
    }
    record_entities(front, caller, &s).await;
    s.changed();
    Ok(Started { id: sid, name })
}

async fn insert_row(db: &urdr::Handle, s: &Session) {
    let (sid, name, profile, role) = (
        s.id.clone(),
        s.name.clone(),
        s.profile.clone(),
        format!("{:?}", s.role).to_lowercase(),
    );
    let (cwd, task, job, acp) = (
        s.cwd.to_string_lossy().into_owned(),
        s.task.clone(),
        s.job.clone(),
        s.acp.0.to_string(),
    );
    let (enforced, parent, at) = (s.enforced, s.parent.clone(), s.started);
    let r = db
        .write(move |c| {
            c.execute(
                "insert or replace into asession(sid, name, profile, role, cwd, task, job, acp, enforced, parent, at) \
                 values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                (sid, name, profile, role, cwd, task, job, acp, i64::from(enforced), parent, at),
            )?;
            Ok(())
        })
        .await;
    if let Err(e) = r {
        tracing::warn!(sid = s.id, "cannot record a session in runtime.db: {e}");
    }
}

pub(crate) async fn delete_row(db: &urdr::Handle, sid: &str) {
    let s = sid.to_owned();
    if let Err(e) = db
        .write(move |c| Ok(c.execute("delete from asession where sid = ?1", [s])?))
        .await
    {
        tracing::warn!(sid, "cannot remove a session from runtime.db: {e}");
    }
}

/// The `session` entity (`run_by` its agent, `works_on` its task); best effort: a store that is not ready, or a task
/// the graph does not know, leaves the session running.
async fn record_entities(front: &Front, caller: &Caller, s: &Session) {
    use urdr::graph::entity::{self, EntityNew, Origin};
    use urdr::graph::link;
    let (sid, name, profile, task) = (
        s.id.clone(),
        s.name.clone(),
        s.profile.clone(),
        s.task.clone(),
    );
    let data = json!({
        "profile": s.profile, "role": format!("{:?}", s.role).to_lowercase(), "cwd": s.cwd,
        "job": s.job, "about": s.about, "brainstorm": s.document.is_some(),
    });
    let new = |id: String, kind: &str, title: String, data: Value| EntityNew {
        id,
        kind: kind.into(),
        project: None,
        title: Some(title),
        status: None,
        body: None,
        priority: None,
        assignee: None,
        data,
        origin: Origin::Recorded,
        source: None,
    };
    let r = front
        .writer
        .write(caller, "agents/start", move |tx| {
            let refused =
                |e: urdr::graph::WriteError| norn::store::CoordError::Refused(e.to_string());
            let agent_id = format!("agent:{profile}");
            let agent = match entity::by_id(tx.sql(), &agent_id)
                .map_err(|e| norn::store::CoordError::Refused(e.to_string()))?
            {
                Some(a) => a.n,
                None => {
                    entity::create(tx, new(agent_id, "agent", profile.clone(), json!({})))
                        .map_err(refused)?
                        .n
                }
            };
            let ses = entity::create(tx, new(format!("session:{sid}"), "session", name, data))
                .map_err(refused)?;
            link::add(tx, ses.n, "run_by", agent, None, Origin::Recorded, None).map_err(refused)?;
            if let Some(t) = task
                && let Some(te) = entity::by_id(tx.sql(), &t)
                    .map_err(|e| norn::store::CoordError::Refused(e.to_string()))?
            {
                link::add(tx, ses.n, "works_on", te.n, None, Origin::Recorded, None)
                    .map_err(refused)?;
            }
            Ok(())
        })
        .await;
    if let Err(e) = r {
        tracing::warn!(sid = s.id, "session entity not recorded: {e}");
    }
}

impl Session {
    /// The change number up by one, and an event pair scheduled (at most one per [`EMIT_EVERY`]).
    fn changed(self: &Arc<Self>) {
        lock(&self.state).seq += 1;
        self.schedule();
    }

    fn schedule(self: &Arc<Self>) {
        if self.scheduled.swap(true, Ordering::AcqRel) {
            return;
        }
        let me = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(EMIT_EVERY).await;
            me.scheduled.store(false, Ordering::Release);
            me.emit();
        });
    }

    fn emit(&self) {
        let (seq, entries) = {
            let mut st = lock(&self.state);
            let idx: Vec<usize> = std::mem::take(&mut st.dirty).into_iter().collect();
            let entries: Vec<(u64, Entry)> = idx
                .into_iter()
                .filter_map(|i| st.entries.get(i).map(|e| (i as u64, e.clone())))
                .collect();
            (st.seq, entries)
        };
        self.editors.broadcast(
            "agent",
            json!({"id": self.id, "seq": seq, "session": self.snapshot()}),
        );
        if !entries.is_empty() {
            self.editors.broadcast(
                "agent-entries",
                json!({"id": self.id, "seq": seq, "entries": entries}),
            );
        }
    }

    pub fn snapshot(&self) -> Snapshot {
        let st = lock(&self.state);
        Snapshot {
            id: self.id.clone(),
            name: Some(self.name.clone()),
            profile: Some(self.profile.clone()),
            cwd: Some(self.cwd.to_string_lossy().into_owned()),
            task: self.task.clone(),
            job: self.job.clone(),
            status: Some(st.status),
            via: Some(self.via),
            mode: self.mode,
            queue: Vec::new(),
            paused: None,
            permissions: st.permissions.iter().map(|p| p.public.clone()).collect(),
            reviews: Vec::new(),
            usage: st.usage.clone(),
            commands: st.commands.clone(),
            capabilities: self.capabilities.clone(),
            exit: st.exit,
            stderr: st.stderr.clone(),
            entries_count: Some(st.entries.len() as u64),
            enforced: Some(self.enforced),
            enforced_why: self.enforced_why.clone(),
            role: Some(self.role),
            provider: self.provider.clone(),
            parent: self.parent.clone(),
            about: self.about.clone(),
            waiting_on: None,
        }
    }

    pub fn transcript(&self) -> Transcript {
        let snap = self.snapshot();
        let st = lock(&self.state);
        Transcript {
            session: snap,
            entries: st.entries.clone(),
            seq: st.seq,
        }
    }

    fn fence(&self) -> Fence {
        Fence {
            cwd: self.cwd.clone(),
            document: self.document.clone(),
        }
    }

    /// The reader task: the agent's updates, requests and exit.
    async fn run(self: Arc<Self>, mut rx: tokio::sync::mpsc::Receiver<Event>) {
        while let Some(ev) = rx.recv().await {
            match ev {
                Event::Update { update, .. } => {
                    if let Ok(v) = serde_json::to_value(&update) {
                        lock(&self.state).apply(&v);
                        self.schedule();
                    }
                }
                Event::Request(Incoming::Permission(req, resp)) => {
                    self.permission_request(serde_json::to_value(&req).unwrap_or_default(), resp);
                }
                Event::Request(Incoming::ReadFile(req, resp)) => {
                    let v = serde_json::to_value(&req).unwrap_or_default();
                    match self.read_file(&v).await {
                        Ok(content) => {
                            if let Ok(r) = serde_json::from_value::<ReadTextFileResponse>(
                                json!({"content": content}),
                            ) {
                                let _ = resp.respond(r);
                            }
                        }
                        Err(m) => {
                            let _ = resp.fail(-32602, &m);
                        }
                    }
                }
                Event::Request(Incoming::WriteFile(req, resp)) => {
                    let v = serde_json::to_value(&req).unwrap_or_default();
                    match self.write_file(&v).await {
                        Ok(()) => {
                            if let Ok(r) =
                                serde_json::from_value::<WriteTextFileResponse>(json!({}))
                            {
                                let _ = resp.respond(r);
                            }
                        }
                        Err(m) => {
                            let _ = resp.fail(-32602, &m);
                        }
                    }
                }
                Event::Exit {
                    code,
                    signal,
                    stderr,
                } => {
                    {
                        let mut st = lock(&self.state);
                        st.status = runstav::methods::agents::SessionStatus::Exited;
                        st.exit =
                            Some(code.map_or_else(
                                || signal.map_or(-1, |s| 128 + i64::from(s)),
                                i64::from,
                            ));
                        st.stderr = Some(stderr).filter(|s| !s.is_empty());
                        st.permissions.clear();
                        st.seq += 1;
                    }
                    self.schedule();
                }
            }
        }
    }

    fn permission_request(
        self: &Arc<Self>,
        req: Value,
        resp: hermod::Responder<RequestPermissionResponse>,
    ) {
        // the matrix (Task 12) decides first: a no-op Allow until then
        let gate = Gate::Allow;
        let tool = req.get("toolCall").cloned();
        let options: Vec<(String, String)> = req
            .get("options")
            .and_then(Value::as_array)
            .map(|o| {
                o.iter()
                    .filter_map(|o| {
                        Some((
                            o.get("optionId")?.as_str()?.to_string(),
                            o.get("kind")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string(),
                        ))
                    })
                    .collect()
            })
            .unwrap_or_default();
        if let Gate::Never(_) = gate {
            reply(resp, pick_reject(&options));
            return;
        }
        let request = self.next_request.fetch_add(1, Ordering::Relaxed);
        let public = Permission {
            id: Some(RpcId::Int(request as i64)),
            title: tool
                .as_ref()
                .and_then(|t| t.get("title"))
                .and_then(Value::as_str)
                .map(str::to_string),
            tool,
            options: req
                .get("options")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default(),
        };
        lock(&self.state).permissions.push(Pending {
            request,
            public,
            options,
            resp,
        });
        self.changed();
    }

    /// The user's answer to a request: OPTION (one the agent offered), or none to reject.
    pub(crate) fn answer_permission(
        self: &Arc<Self>,
        request: &RequestId,
        option: Option<&str>,
    ) -> Result<bool, Error> {
        let mut st = lock(&self.state);
        let at = st
            .permissions
            .iter()
            .position(|p| match request {
                RequestId::Num(n) => p.request == *n,
                RequestId::Str(s) => p.request.to_string() == *s,
            })
            .ok_or_else(|| invalid("request", "no such permission request (answered already?)"))?;
        if let Some(o) = option
            && !st.permissions[at].options.iter().any(|(id, _)| id == o)
        {
            return Err(invalid(
                "option",
                "not one of the options the agent offered",
            ));
        }
        let p = st.permissions.remove(at);
        drop(st);
        let chosen = match option {
            Some(o) => Some(o.to_string()),
            None => pick_reject(&p.options),
        };
        reply(p.resp, chosen);
        self.changed();
        Ok(true)
    }

    pub(crate) fn do_op(self: &Arc<Self>, p: DoParams) -> Result<bool, Error> {
        match p.op {
            AgentOp::Review => Err(invalid(
                "item",
                "no such review (no write is held for review)",
            )),
            _ => Err(not_yet("agents/do", "8b")),
        }
    }

    async fn read_file(&self, req: &Value) -> Result<String, String> {
        let path = req.get("path").and_then(Value::as_str).unwrap_or("");
        let real = self.fence().check(path, false)?;
        let text = tokio::fs::read_to_string(&real)
            .await
            .map_err(|e| format!("{path}: {e}"))?;
        let line = req.get("line").and_then(Value::as_u64).unwrap_or(1).max(1) as usize;
        let limit = req.get("limit").and_then(Value::as_u64);
        if line == 1 && limit.is_none() {
            return Ok(text);
        }
        let it = text.split_inclusive('\n').skip(line - 1);
        Ok(match limit {
            Some(n) => it.take(n as usize).collect(),
            None => it.collect(),
        })
    }

    async fn write_file(&self, req: &Value) -> Result<(), String> {
        let path = req.get("path").and_then(Value::as_str).unwrap_or("");
        let content = req.get("content").and_then(Value::as_str).unwrap_or("");
        let real = self.fence().check(path, true)?;
        tokio::fs::write(&real, content)
            .await
            .map_err(|e| format!("{path}: {e}"))
    }

    /// Cancel the turn and end the process group.
    pub(crate) async fn end(&self, kill: bool) {
        let _ = self.conn.cancel(&self.acp);
        let grace = if kill { Duration::ZERO } else { STOP_GRACE };
        draugr::kill_group(self.conn.pid(), grace, &draugr::RealSignaller).await;
    }

    /// One turn of TEXT while idle.  The queue, steering and the other origins are Task 8b's.
    pub(crate) fn begin_turn(self: &Arc<Self>, text: String) -> Result<(), Error> {
        {
            let mut st = lock(&self.state);
            use runstav::methods::agents::SessionStatus as S;
            match st.status {
                S::Idle => {}
                S::Exited => return Err(invalid("id", "the session has exited")),
                _ => {
                    return Err(invalid(
                        "id",
                        "the session is busy (queued prompts arrive with agent system part 1, Task 8b)",
                    ));
                }
            }
            st.status = S::Busy;
            st.open = None;
            st.text(EntryType::User, &text, None);
            st.open = None;
        }
        self.changed();
        let me = self.clone();
        tokio::spawn(async move {
            let block = json!({"type": "text", "text": text});
            let blocks = serde_json::from_value(json!([block])).unwrap_or_default();
            let out = me.conn.prompt(&me.acp, blocks, None).await;
            {
                let mut st = lock(&me.state);
                st.open = None;
                let mut rest = Map::new();
                match &out {
                    Ok(o) => {
                        rest.insert("stop".into(), json!(format!("{:?}", o.stop)));
                        st.push(EntryType::Stop, rest);
                    }
                    Err(hermod::Error::Closed) => {}
                    Err(e) => {
                        rest.insert("text".into(), json!(e.to_string()));
                        st.push(EntryType::Error, rest);
                    }
                }
                if st.status == runstav::methods::agents::SessionStatus::Busy {
                    st.status = runstav::methods::agents::SessionStatus::Idle;
                }
            }
            me.changed();
        });
        Ok(())
    }
}

/// The reject option of OPTIONS (once preferred), else none (the answer is "cancelled").
fn pick_reject(options: &[(String, String)]) -> Option<String> {
    options
        .iter()
        .find(|(_, k)| k == "reject_once")
        .or_else(|| options.iter().find(|(_, k)| k.starts_with("reject")))
        .map(|(id, _)| id.clone())
}

fn reply(resp: hermod::Responder<RequestPermissionResponse>, option: Option<String>) {
    let outcome = match option {
        Some(id) => json!({"outcome": {"outcome": "selected", "optionId": id}}),
        None => json!({"outcome": {"outcome": "cancelled"}}),
    };
    if let Ok(r) = serde_json::from_value::<RequestPermissionResponse>(outcome) {
        let _ = resp.respond(r);
    }
}

pub async fn list(f: &Front, c: &Caller, _: Empty) -> Result<Sessions, Error> {
    Ok(f.core.agents.list(c))
}

pub async fn start(f: &Front, c: &Caller, p: StartParams) -> Result<Started, Error> {
    f.core.agents.start(f, p, c).await
}

pub async fn get(f: &Front, _: &Caller, p: ById) -> Result<Transcript, Error> {
    f.core.agents.get(p.id.as_str())
}

/// A prompt while idle starts a turn; the queue, steering and origins arrive with Task 8b.
pub async fn send(f: &Front, c: &Caller, p: SendParams) -> Result<bool, Error> {
    if c.class != Class::User {
        return Err(refuse("only the user sends a message here"));
    }
    f.core
        .agents
        .find(p.id.as_str())?
        .begin_turn(p.text.as_str().to_string())?;
    Ok(true)
}

pub async fn stop(f: &Front, _: &Caller, p: ById) -> Result<bool, Error> {
    f.core.agents.stop(p.id.as_str()).await
}

pub async fn kill(f: &Front, _: &Caller, p: ById) -> Result<bool, Error> {
    f.core.agents.kill(p.id.as_str()).await
}

pub async fn permission(f: &Front, c: &Caller, p: PermissionParams) -> Result<bool, Error> {
    f.core
        .agents
        .permission(
            c,
            p.id.as_str(),
            &p.request,
            p.option.as_ref().map(|o| o.as_str()),
        )
        .await
}

pub async fn do_op(f: &Front, c: &Caller, p: DoParams) -> Result<bool, Error> {
    f.core.agents.do_op(c, p).await
}

pub async fn move_to(_: &Front, _: &Caller, _: MoveParams) -> Result<Started, Error> {
    Err(not_yet("agents/move", "26"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use runstav::methods::agents::SessionStatus;

    fn upd(v: Value) -> Value {
        v
    }

    #[test]
    fn chunks_of_one_message_join_into_one_entry() {
        let mut st = State::new();
        for t in ["Hel", "lo"] {
            st.apply(&upd(json!({"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": t}, "messageId": "m1"})));
        }
        assert_eq!(st.entries.len(), 1);
        assert_eq!(st.entries[0].kind, EntryType::Agent);
        assert_eq!(st.entries[0].rest["text"], "Hello");
        assert_eq!(st.entries[0].rest["length"], 5);
        st.apply(&upd(json!({"sessionUpdate": "agent_thought_chunk",
            "content": {"type": "text", "text": "hm"}})));
        assert_eq!(st.entries.len(), 2);
        assert_eq!(st.entries[1].kind, EntryType::Thought);
    }

    #[test]
    fn a_tool_call_update_changes_its_entry() {
        let mut st = State::new();
        st.apply(&upd(
            json!({"sessionUpdate": "tool_call", "toolCallId": "t1",
            "title": "Read x", "kind": "read", "status": "pending"}),
        ));
        st.apply(&upd(
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1",
            "status": "completed"}),
        ));
        assert_eq!(st.entries.len(), 1);
        assert_eq!(st.entries[0].kind, EntryType::Tool);
        assert_eq!(st.entries[0].rest["status"], "completed");
        assert_eq!(st.entries[0].rest["title"], "Read x");
        assert_eq!(st.entries[0].rest["id"], "t1");
    }

    #[test]
    fn a_plan_is_replaced_not_repeated() {
        let mut st = State::new();
        st.apply(&upd(
            json!({"sessionUpdate": "plan", "entries": [{"content": "a"}]}),
        ));
        st.apply(&upd(
            json!({"sessionUpdate": "plan", "entries": [{"content": "b"}]}),
        ));
        assert_eq!(st.entries.len(), 1);
        assert_eq!(st.entries[0].rest["entries"][0]["content"], "b");
    }

    #[test]
    fn commands_and_usage_are_state_not_entries() {
        let mut st = State::new();
        st.apply(&upd(json!({"sessionUpdate": "available_commands_update",
            "availableCommands": [{"name": "compact"}]})));
        st.apply(&upd(
            json!({"sessionUpdate": "usage_update", "used": 10, "size": 100}),
        ));
        assert!(st.entries.is_empty());
        assert_eq!(st.commands.len(), 1);
        assert_eq!(st.usage.as_ref().unwrap().used, Some(10.0));
        assert_eq!(st.status, SessionStatus::Starting);
    }

    #[test]
    fn the_fence_keeps_files_inside_the_directory() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path().join("work");
        std::fs::create_dir(&cwd).unwrap();
        std::fs::write(dir.path().join("secret"), "x").unwrap();
        std::os::unix::fs::symlink(dir.path().join("secret"), cwd.join("link")).unwrap();
        let f = Fence {
            cwd: cwd.clone(),
            document: None,
        };
        let s = |p: &Path| p.to_string_lossy().into_owned();
        assert!(f.check(&s(&cwd.join("a.txt")), true).is_ok());
        assert!(f.check(&s(&cwd.join("sub/new.txt")), true).is_ok());
        assert!(f.check(&s(&dir.path().join("secret")), false).is_err());
        assert!(f.check(&s(&cwd.join("../secret")), false).is_err());
        assert!(f.check(&s(&cwd.join("link")), false).is_err());
        assert!(f.check("relative.txt", false).is_err());
    }

    #[test]
    fn a_brainstorm_writes_only_its_document() {
        let dir = tempfile::tempdir().unwrap();
        let doc = dir.path().join("design.md");
        let f = Fence {
            cwd: dir.path().to_path_buf(),
            document: Some(doc.clone()),
        };
        assert!(f.check(&doc.to_string_lossy(), true).is_ok());
        assert!(
            f.check(&dir.path().join("src.rs").to_string_lossy(), true)
                .is_err()
        );
        // the project stays readable
        assert!(
            f.check(&dir.path().join("src.rs").to_string_lossy(), false)
                .is_ok()
        );
    }

    #[test]
    fn a_rejection_prefers_reject_once() {
        let o = |a: &str, b: &str| (a.to_string(), b.to_string());
        let opts = [
            o("a", "allow_once"),
            o("ra", "reject_always"),
            o("r", "reject_once"),
        ];
        assert_eq!(pick_reject(&opts).as_deref(), Some("r"));
        assert_eq!(pick_reject(&opts[..2]).as_deref(), Some("ra"));
        assert_eq!(pick_reject(&opts[..1]), None);
    }
}
