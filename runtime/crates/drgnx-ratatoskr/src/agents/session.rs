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

use super::launch;
use super::lock as plock;
use super::queue::{Origin, Queue, Queued};
use super::transcript;
use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use crate::matrix_gate::{ActionCtx, Gate, MatrixGate};
use crate::settings::AgentProfile;
use crate::settings::profiles::Mode as ProfileMode;
use hermod::schema::v1::{ReadTextFileResponse, RequestPermissionResponse, WriteTextFileResponse};
use hermod::{Conn, ConnOpts, Event, Incoming, SessionId};
use norn::matrix::{Action, Who};
use runstav::methods::Empty;
use runstav::methods::agents::{
    AgentOp, ById, DoParams, Entry, EntryType, Mode, MoveParams, Permission, PermissionParams,
    RpcId, SendParams, SessionStatus, Snapshot, StartParams, Started, Transcript, Usage, Via,
};
use runstav::methods::matrix::Role;
use runstav::methods::timeline::{AgentStep, Step, StepClass};
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
/// A Stop that the agent has not answered by then ends its process.
const STOP_ANSWER: Duration = Duration::from_secs(2);

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
    /// Prompts waiting for the turn to end (or held after a Stop).
    queue: Queue,
    /// The queue is held (a Stop, or the pause after a tool call) until delivered or something new is sent.
    paused: bool,
    /// Cancel once the running tool call completes (`Hub::cancel_after_tool`).
    hold: bool,
    /// The reader should cancel the turn now (a hold met its tool call's end).
    cancel_wanted: bool,
    /// Entries before this index are in the transcript file.
    flushed: usize,
    /// The turn running (counts from 1), so a late timer knows it is the same one.
    turn: u64,
    /// The hub is ending: the turn's end is not the user's Stop, and nothing is held for it.
    ending: bool,
    /// The step running, and the steps closed since the last drain.
    cur: Option<OpenStep>,
    stash: Option<OpenStep>,
    closed: Vec<ClosedStep>,
}

/// A step that has begun.
#[derive(Clone, Debug)]
struct OpenStep {
    class: StepClass,
    start: f64,
    tool: Option<String>,
    tool_kind: Option<String>,
    tool_id: Option<String>,
    message_id: Option<String>,
}

/// A step that ended, waiting to be written to the `step` table and announced.
#[derive(Clone, Debug)]
struct ClosedStep {
    open: OpenStep,
    end: f64,
    /// Set on a turn's last step.
    turn_id: Option<String>,
    tokens_in: i64,
    tokens_out: i64,
    cache_read: i64,
    cache_write: i64,
    cost: Option<f64>,
}

/// What a turn used (the last step carries it).
#[derive(Clone, Debug, Default)]
struct TurnUse {
    turn_id: Option<String>,
    tokens_in: i64,
    tokens_out: i64,
    cache_read: i64,
    cache_write: i64,
    cost: Option<f64>,
}

impl State {
    fn new() -> State {
        State {
            queue: Queue::default(),
            paused: false,
            hold: false,
            cancel_wanted: false,
            flushed: 0,
            turn: 0,
            ending: false,
            cur: None,
            stash: None,
            closed: Vec::new(),
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

    /// Close the step running (if any) at END, carrying USE.
    fn step_close(&mut self, end: f64, turn_use: Option<TurnUse>) {
        if let Some(open) = self.cur.take() {
            let u = turn_use.unwrap_or_default();
            self.closed.push(ClosedStep {
                open,
                end,
                turn_id: u.turn_id,
                tokens_in: u.tokens_in,
                tokens_out: u.tokens_out,
                cache_read: u.cache_read,
                cache_write: u.cache_write,
                cost: u.cost,
            });
        }
    }

    /// The running step ends and a step of CLASS begins.
    fn step_begin(&mut self, class: StepClass, tool: Option<(&str, Option<&str>, Option<&str>)>) {
        let at = now();
        self.step_close(at, None);
        self.cur = Some(OpenStep {
            class,
            start: at,
            tool: tool.map(|t| t.0.to_string()),
            tool_kind: tool.and_then(|t| t.1).map(str::to_string),
            tool_id: tool.and_then(|t| t.2).map(str::to_string),
            message_id: None,
        });
    }

    /// A step of thinking when none runs (text arriving between tool calls).
    fn step_think(&mut self, message_id: Option<&str>) {
        if self.cur.is_none() {
            self.step_begin(StepClass::Think, None);
        }
        if let Some(c) = self.cur.as_mut()
            && c.message_id.is_none()
        {
            c.message_id = message_id.map(str::to_string);
        }
    }

    /// A permission request makes the step wait for the user; the step it interrupted comes back after.
    fn wait_begin(&mut self) {
        if self.stash.is_none() {
            self.stash = self.cur.clone();
        }
        self.step_begin(StepClass::UserWait, None);
    }

    fn wait_end(&mut self) {
        if !self.permissions.is_empty() {
            return;
        }
        let at = now();
        self.step_close(at, None);
        if let Some(mut prev) = self.stash.take() {
            prev.start = at;
            self.cur = Some(prev);
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
            "agent_message_chunk" => {
                self.step_think(mid);
                self.text(EntryType::Agent, &text_of(u), mid);
            }
            "agent_thought_chunk" => {
                self.step_think(mid);
                self.text(EntryType::Thought, &text_of(u), mid);
            }
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
                let (title, tkind, status) = {
                    let r = &self.entries[idx].rest;
                    let s = |k: &str| r.get(k).and_then(Value::as_str).map(str::to_string);
                    (s("title"), s("kind"), s("status"))
                };
                let id = u.get("toolCallId").and_then(Value::as_str).unwrap_or("");
                if self.cur.as_ref().and_then(|c| c.tool_id.as_deref()) != Some(id)
                    && !matches!(status.as_deref(), Some("completed" | "failed"))
                {
                    self.step_begin(
                        StepClass::Tool,
                        Some((
                            title.as_deref().unwrap_or("tool"),
                            tkind.as_deref(),
                            Some(id),
                        )),
                    );
                }
                if matches!(status.as_deref(), Some("completed" | "failed")) {
                    if self.cur.as_ref().and_then(|c| c.tool_id.as_deref()) == Some(id) {
                        self.step_begin(StepClass::Think, None);
                    }
                    if self.hold {
                        self.hold = false;
                        self.paused = true;
                        self.cancel_wanted = true;
                    }
                }
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
    /// What the matrix decides at the permission seam: the gate, the settings it reads, the store its cards go to.
    gate: MatrixGate,
    settings: Arc<crate::settings::Settings>,
    writer: crate::coord::Writer,
    scheduled: AtomicBool,
    next_request: AtomicU64,
    state: Mutex<State>,
    /// Transcripts and the held queue on disk (none in unit tests).
    store: Option<transcript::Store>,
    /// Closed steps, in order, to the task that writes them to the `step` table.
    steps: tokio::sync::mpsc::UnboundedSender<ClosedStep>,
    /// How a turn ended, to the reader task.
    done: tokio::sync::mpsc::UnboundedSender<TurnEnd>,
}

/// What `Conn::prompt` answered.
struct TurnEnd(Result<hermod::PromptOutcome, hermod::Error>);

/// Where a session's steps are written and announced.
#[derive(Clone)]
pub(crate) struct StepSink {
    pub writer: crate::coord::Writer,
    pub editors: Arc<crate::settings::agents::Editors>,
    pub bus: tokio::sync::broadcast::Sender<AgentStep>,
}

/// What `open` and `resume` know of a session before its agent is running.
struct Ident {
    id: String,
    name: String,
    started: f64,
    role: Role,
    cwd: PathBuf,
    task: Option<String>,
    job: Option<String>,
    parent: Option<String>,
    about: Option<String>,
    document: Option<PathBuf>,
}

/// A launched agent with its handshake done.
struct Launched {
    conn: Conn,
    acp: SessionId,
    caps: Option<Value>,
    enforced: bool,
    enforced_why: Option<String>,
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

/// A launch ready to spawn: the process, the sandbox helper's status pipe, and whether the lock is enforced.
struct Prepared {
    spec: draugr::Spec,
    status: Option<std::os::fd::OwnedFd>,
    plan: plock::LaunchPlan,
    enforced: bool,
    enforced_why: Option<String>,
}

/// WHO a session is, for the matrix's columns.
fn who_of(role: Role, profile: &AgentProfile) -> Who {
    Who {
        role: Some(role),
        agent: Some(profile.name.clone()),
        provider: profile.ai.clone(),
    }
}

/// The launch of a test session: the plan's command, unsandboxed, with a short allowlisted environment.  Only tests
/// and `test-hooks` builds have it (the mock agent lives outside any sandbox's reach); a shipped build always goes
/// through `launch::spawn` and Gleipnir.
#[cfg(any(test, feature = "test-hooks"))]
fn spawn_spec(
    p: &AgentProfile,
    plan: &plock::LaunchPlan,
    _: &Path,
    cwd: &Path,
    _: &str,
    _: Role,
) -> Result<
    (
        draugr::Spec,
        Option<std::os::fd::OwnedFd>,
        Option<&'static str>,
    ),
    Error,
> {
    let (prog, args) = plan
        .argv
        .split_first()
        .ok_or_else(|| invalid("profile", "the profile has no command"))?;
    let mut pairs: Vec<(String, std::ffi::OsString)> = p
        .env
        .iter()
        .filter_map(|e| e.split_once('='))
        .map(|(k, v)| (k.to_string(), v.into()))
        .collect();
    pairs.extend(plan.env.iter().map(|(k, v)| (k.clone(), v.into())));
    let set: Vec<(&str, &std::ffi::OsStr)> = pairs
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_os_str()))
        .collect();
    let env = draugr::env::build(&["PATH", "HOME", "LANG", "TMPDIR"], &[], &set);
    let spec = draugr::Spec {
        program: PathBuf::from(prog),
        args: args.to_vec(),
        env,
        cwd: Some(cwd.to_path_buf()),
        stdin_null: false,
        pass_fds: Vec::new(),
        new_session: false,
    };
    Ok((spec, None, Some("a test launch: unsandboxed")))
}

/// The sandboxed launch: a worktree session writes its worktree only; a chat in its own scratch directory
/// (`launch::scratch_dir`) is the plain one.  The network is the provider's alone: `Open` is never granted here.
#[cfg(not(any(test, feature = "test-hooks")))]
fn spawn_spec(
    _: &AgentProfile,
    plan: &plock::LaunchPlan,
    scratch: &Path,
    cwd: &Path,
    sid: &str,
    role: Role,
) -> Result<
    (
        draugr::Spec,
        Option<std::os::fd::OwnedFd>,
        Option<&'static str>,
    ),
    Error,
> {
    let launched = if cwd == scratch {
        launch::spawn_plain(plan, sid)
    } else {
        launch::spawn(
            plan,
            &launch::SandboxReq {
                sid: sid.to_string(),
                worktree: cwd.to_path_buf(),
                read: Vec::new(),
                net: launch::NetCell::ProviderOnly,
                role,
            },
        )
    }
    .map_err(|r| refuse(&format!("the sandbox refused the launch: {}", r.message)))?;
    Ok((launched.spec, launched.status, None))
}

/// Everything before the process: the matrix's cells, the provider's lock plan, the refusal of a lock that is not
/// enforced for a worker or a manager under any preset but the autonomous one, and the spawn spec.
async fn prepare(
    front: &Front,
    profile: &AgentProfile,
    role: Role,
    sid: &str,
    cwd: &Path,
) -> Result<Prepared, Error> {
    let who = who_of(role, profile);
    let eff = front
        .core
        .matrix
        .effective_now(&front.settings, &front.writer, who, ActionCtx::default())
        .await
        .map_err(|e| internal(format!("the matrix: {e:?}")))?;
    let mut plan = plock::plan(profile, role, &eff);
    if profile.provider() == Some(crate::settings::profiles::Provider::Claude)
        && let Some(home) = std::env::var_os("HOME").filter(|h| !h.is_empty())
    {
        let (deny, ask) = plock::claude_deny_ask(&PathBuf::from(home).join(".claude"), cwd);
        plan = plan.with_claude_rules(deny, ask);
    }
    plan = plan.with_codex_untrusted(profile, cwd);
    let why = match plan.enforced {
        plock::Enforced::Yes => None,
        plock::Enforced::No(why) => Some(why),
    };
    if let Some(why) = why
        && matches!(role, Role::Worker | Role::Manager)
        && front.core.matrix.active_preset(now()) != runstav::methods::matrix::Preset::Autonomous
    {
        return Err(refuse(&format!(
            "{}'s lock is not enforced, so it may not work here: {why}",
            profile.name
        )));
    }
    let scratch = launch::scratch_dir(&runstav::paths::Env::process(), sid).unwrap_or_default();
    let (spec, status, unsandboxed) = spawn_spec(profile, &plan, &scratch, cwd, sid, role)?;
    Ok(Prepared {
        spec,
        status,
        enforced: why.is_none() && unsandboxed.is_none(),
        enforced_why: unsandboxed.or(why).map(str::to_string),
        plan,
    })
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
    // a session starts on the settings as the file says now (as `mcp/session` does): a profile added since the last
    // read is found
    front.refresh_settings().await;
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
        None => launch::scratch_dir(&runstav::paths::Env::process(), &sid)
            .map_err(|r| internal(format!("scratch directory: {}", r.message)))?,
    };
    let (l, rx) = launch(front, &profile, role, &sid, &cwd, None).await?;
    let ident = Ident {
        id: sid.clone(),
        name: name.clone(),
        started: now(),
        role,
        cwd,
        task: p.task.as_ref().map(|t| t.as_str().to_string()),
        job: p.job.as_ref().map(|j| j.as_str().to_string()),
        parent: None,
        about: p.about.as_ref().map(|a| a.to_string()),
        document: p.document.as_ref().map(|d| PathBuf::from(d.as_str())),
    };
    let (s, done) = assemble(ident, &profile, l, front, hub.step_bus());
    if let Some(store) = &s.store {
        store.save_meta(&s.id, &json!({"about": s.about, "document": s.document}));
    }
    lock(&s.state).status = SessionStatus::Idle;
    hub.insert(s.clone());
    tokio::spawn(s.clone().run(rx, done));
    if let Some(db) = hub.db() {
        insert_row(db, &s).await;
    }
    record_entities(front, caller, &s).await;
    s.changed();
    Ok(Started { id: sid, name })
}

/// PROFILE's agent in CWD: started in its sandbox, initialized, on a session (a new one, or EXISTING by
/// `session/resume`, else `session/load` when the agent can only load) and its lock verified: a lock that does not
/// hold kills the session.
async fn launch(
    front: &Front,
    profile: &AgentProfile,
    role: Role,
    sid: &str,
    cwd: &Path,
    existing: Option<&str>,
) -> Result<(Launched, tokio::sync::mpsc::Receiver<Event>), Error> {
    let prep = prepare(front, profile, role, sid, cwd).await?;
    let (conn, rx) = Conn::spawn(prep.spec, ConnOpts::default())
        .await
        .map_err(|e| internal(e.to_string()))?;
    let kill = || draugr::kill_group(conn.pid(), Duration::ZERO, &draugr::RealSignaller);
    // The sandbox helper reports on a pipe; a launch whose status is not read hangs (Task 10).
    if let Some(fd) = prep.status {
        let read = tokio::task::spawn_blocking(move || {
            gleipnir::read_status(fd, &String::new, Duration::from_secs(20))
        })
        .await;
        match read {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                kill().await;
                return Err(refuse(&format!("the sandbox did not start: {}", e.message)));
            }
            Err(e) => {
                kill().await;
                return Err(internal(format!("reading the sandbox status: {e}")));
            }
        }
    }
    let meta = prep.plan.session_meta.clone();
    let init = async {
        let caps =
            serde_json::from_value(json!({"fs": {"readTextFile": true, "writeTextFile": true}}))
                .map_err(|e| hermod::Error::Decode(e.to_string()))?;
        let info = conn.initialize(caps).await?;
        let caps = serde_json::to_value(&info.caps).ok();
        let acp = match existing {
            None => conn.new_session(cwd, Vec::new(), meta).await?,
            Some(id) => {
                let sid = SessionId::new(id.to_string());
                let can = |p: &str| {
                    caps.as_ref()
                        .and_then(|c| c.pointer(p))
                        .is_some_and(|v| !v.is_null() && *v != json!(false))
                };
                if can("/sessionCapabilities/resume") {
                    conn.resume_session(&sid, cwd, Vec::new()).await?;
                } else if can("/loadSession") {
                    conn.load_session(&sid, cwd, Vec::new()).await?;
                } else {
                    return Err(hermod::Error::Decode(
                        "the agent can neither resume nor load a session".into(),
                    ));
                }
                sid
            }
        };
        Ok::<_, hermod::Error>((caps, acp))
    };
    let (capabilities, acp) = match init.await {
        Ok(x) => x,
        Err(e) => {
            kill().await;
            return Err(internal(format!("{}: {e}", profile.name)));
        }
    };
    if prep.plan.enforced == plock::Enforced::Yes
        && let Err(e) = plock::verify(&conn, &acp, profile).await
    {
        kill().await;
        return Err(refuse(&format!("{}: {e}", profile.name)));
    }
    Ok((
        Launched {
            conn,
            acp,
            caps: capabilities,
            enforced: prep.enforced,
            enforced_why: prep.enforced_why,
        },
        rx,
    ))
}

/// The session for IDENT on a launched agent: idle state, its step writer running.
fn assemble(
    i: Ident,
    profile: &AgentProfile,
    l: Launched,
    front: &Front,
    bus: tokio::sync::broadcast::Sender<AgentStep>,
) -> (Arc<Session>, tokio::sync::mpsc::UnboundedReceiver<TurnEnd>) {
    let (done, done_rx) = tokio::sync::mpsc::unbounded_channel();
    let (steps, rx) = tokio::sync::mpsc::unbounded_channel();
    let ctx = StepCtx {
        session: i.id.clone(),
        task: i.task.clone(),
        agent: profile.name.clone(),
        provider: profile.ai.clone(),
    };
    tokio::spawn(write_steps(
        rx,
        StepSink {
            writer: front.writer.clone(),
            editors: front.editors.clone(),
            bus,
        },
        ctx,
    ));
    let s = Arc::new(Session {
        id: i.id,
        started: i.started,
        name: i.name,
        profile: profile.name.clone(),
        role: i.role,
        cwd: i.cwd,
        task: i.task,
        job: i.job,
        parent: i.parent,
        about: i.about,
        document: i.document,
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
        enforced: l.enforced,
        enforced_why: l.enforced_why,
        capabilities: l.caps,
        conn: l.conn,
        acp: l.acp,
        editors: front.editors.clone(),
        gate: front.core.matrix.clone(),
        settings: front.settings.clone(),
        writer: front.writer.clone(),
        scheduled: AtomicBool::new(false),
        next_request: AtomicU64::new(1),
        state: Mutex::new(State::new()),
        store: front.dirs.get().map(|d| transcript::Store::new(&d.hub)),
        steps,
        done,
    });
    (s, done_rx)
}

/// The rows `asession` kept, as sessions again after a restart (`session/resume`, else `session/load`): the
/// transcript read back, the held queue restored and its first prompt delivered.  A session whose profile is gone,
/// or whose agent will not resume, stays in the table for the next start.
pub(crate) async fn resume_all(hub: &super::Hub, front: &Front) {
    let Some(db) = hub.db() else { return };
    type Row = (
        String,
        String,
        String,
        String,
        String,
        Option<String>,
        Option<String>,
        String,
        Option<String>,
        f64,
    );
    let rows: Vec<Row> = match db
        .read(|c| {
            let mut q = c.prepare(
                "select sid, name, profile, role, cwd, task, job, acp, parent, at from asession order by at",
            )?;
            let it = q.query_map([], |r| {
                Ok((
                    r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?, r.get(8)?, r.get(9)?,
                ))
            })?;
            it.collect::<Result<Vec<_>, _>>().map_err(Into::into)
        })
        .await
    {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("cannot read the recorded sessions: {e}");
            return;
        }
    };
    for (sid, name, profile_name, role, cwd, task, job, acp, parent, at) in rows {
        if hub.find(&sid).is_ok() {
            continue;
        }
        let Some(profile) = find_profile(front, &profile_name) else {
            tracing::warn!(
                sid,
                "session not resumed: no agent profile {profile_name:?}"
            );
            continue;
        };
        let store = front.dirs.get().map(|d| transcript::Store::new(&d.hub));
        let meta = store
            .as_ref()
            .map(|s| s.load_meta(&sid))
            .unwrap_or(Value::Null);
        let ident = Ident {
            id: sid.clone(),
            name,
            started: at,
            role: serde_json::from_value(json!(role)).unwrap_or(Role::Chat),
            cwd: PathBuf::from(&cwd),
            task,
            job,
            parent,
            about: meta
                .get("about")
                .and_then(Value::as_str)
                .map(str::to_string),
            document: meta
                .get("document")
                .and_then(Value::as_str)
                .map(PathBuf::from),
        };
        let (l, rx) = match launch(
            front,
            &profile,
            serde_json::from_value(json!(role)).unwrap_or(Role::Chat),
            &sid,
            Path::new(&cwd),
            Some(&acp),
        )
        .await
        {
            Ok(x) => x,
            Err(e) => {
                tracing::warn!(sid, "session not resumed: {}", e.message);
                continue;
            }
        };
        let (s, done) = assemble(ident, &profile, l, front, hub.step_bus());
        if let Some(store) = &s.store {
            let entries = store.load(&sid);
            let (queue, paused) = store.load_queue(&sid);
            let mut st = lock(&s.state);
            st.flushed = entries.len();
            st.entries = entries;
            st.queue = queue;
            st.paused = paused;
        }
        lock(&s.state).status = SessionStatus::Idle;
        hub.insert(s.clone());
        tokio::spawn(s.clone().run(rx, done));
        s.changed();
        s.next();
    }
}

/// What a session's step rows say of it.
struct StepCtx {
    session: String,
    task: Option<String>,
    agent: String,
    provider: Option<String>,
}

/// Write a session's closed steps to the `step` table in order, and announce each as an `agent-step` event (editors)
/// and on the hub's step channel.  Best effort: a store that is not ready loses the row, not the announcement.
async fn write_steps(
    mut rx: tokio::sync::mpsc::UnboundedReceiver<ClosedStep>,
    sink: StepSink,
    ctx: StepCtx,
) {
    use norn::write::steps as table;
    let caller = Caller {
        class: Class::Service,
        sid: None,
        job: None,
        conn_id: 0,
        backend: false,
    };
    let mut local = 0u64;
    while let Some(c) = rx.recv().await {
        local += 1;
        let class_name = serde_json::to_value(c.open.class)
            .ok()
            .and_then(|v| v.as_str().map(str::to_string))
            .unwrap_or_default();
        let new = table::StepNew {
            session: format!("session:{}", ctx.session),
            task: ctx.task.clone(),
            plan: None,
            project: None,
            agent: Some(format!("agent:{}", ctx.agent)),
            provider: ctx.provider.clone(),
            class: table::StepClass::parse(&class_name).unwrap_or(table::StepClass::Think),
            start: c.open.start,
            tool: c.open.tool.clone(),
            tool_kind: c.open.tool_kind.clone(),
            message_id: c.open.message_id.clone(),
            turn_id: c.turn_id.clone(),
            snapshot: None,
            log_version: None,
        };
        let end = table::StepEnd {
            end: c.end,
            tokens_in: c.tokens_in,
            tokens_out: c.tokens_out,
            cache_read: c.cache_read,
            cache_write: c.cache_write,
            cost: c.cost,
            cost_unit: c.cost.map(|_| "usd".to_string()),
            snapshot: None,
            log_version: None,
        };
        let (id, seq) = match sink
            .writer
            .write(&caller, "agents/step", move |tx| {
                let id = table::open(tx, new)?;
                table::close(tx, id, end)?;
                let seq: i64 =
                    tx.sql()
                        .query_row("select seq from step where id = ?1", [id], |r| r.get(0))?;
                Ok((id, seq))
            })
            .await
        {
            Ok(x) => x,
            Err(e) => {
                tracing::warn!(sid = ctx.session, "step not recorded: {e}");
                (0, local as i64)
            }
        };
        let step = Step {
            id,
            session: ctx.session.clone(),
            task: ctx.task.clone(),
            plan: None,
            project: None,
            agent: Some(ctx.agent.clone()),
            provider: ctx.provider.clone(),
            seq: seq as u64,
            class: c.open.class,
            start: c.open.start,
            end: Some(c.end),
            tool: c.open.tool,
            tool_kind: c.open.tool_kind,
            message_id: c.open.message_id,
            turn_id: c.turn_id,
            snapshot: None,
            log_version: None,
            tokens_in: Some(c.tokens_in as u64),
            tokens_out: Some(c.tokens_out as u64),
            cache_read: Some(c.cache_read as u64),
            cache_write: Some(c.cache_write as u64),
            cost: c.cost,
            cost_unit: None,
        };
        let ev = AgentStep {
            session: ctx.session.clone(),
            step,
        };
        sink.editors.broadcast("agent-step", json!(ev));
        let _ = sink.bus.send(ev);
    }
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
    /// Who this session is, for the matrix's columns.
    pub(crate) fn who(&self) -> Who {
        Who {
            role: Some(self.role),
            agent: Some(self.profile.clone()),
            provider: self.provider.clone(),
        }
    }

    /// The change number up by one, and an event pair scheduled (at most one per [`EMIT_EVERY`]).
    fn changed(self: &Arc<Self>) {
        lock(&self.state).seq += 1;
        self.drain_steps();
        self.schedule();
    }

    /// The steps that closed go to the writer task, in order.
    fn drain_steps(&self) {
        let closed = std::mem::take(&mut lock(&self.state).closed);
        for c in closed {
            let _ = self.steps.send(c);
        }
    }

    /// The entries not yet in the transcript file, written (redacted) now.
    fn flush_transcript(&self) {
        let Some(store) = &self.store else { return };
        let fresh: Vec<(u64, Entry)> = {
            let mut st = lock(&self.state);
            let from = st.flushed.min(st.entries.len());
            st.flushed = st.entries.len();
            st.entries[from..]
                .iter()
                .enumerate()
                .map(|(i, e)| ((from + i) as u64, e.clone()))
                .collect()
        };
        if let Err(e) = store.append(&self.id, &fresh) {
            tracing::warn!(sid = self.id, "transcript not written: {e}");
        }
    }

    /// The held queue and the pause, kept for a restart.
    fn persist_queue(&self) {
        let Some(store) = &self.store else { return };
        let (q, paused) = {
            let st = lock(&self.state);
            (st.queue.clone(), st.paused)
        };
        if let Err(e) = store.save_queue(&self.id, &q, paused) {
            tracing::warn!(sid = self.id, "queue not kept: {e}");
        }
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
            queue: st.queue.texts(),
            paused: st.paused.then_some(true),
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
    async fn run(
        self: Arc<Self>,
        mut rx: tokio::sync::mpsc::Receiver<Event>,
        mut done: tokio::sync::mpsc::UnboundedReceiver<TurnEnd>,
    ) {
        loop {
            let ev = tokio::select! {
                biased;
                Some(end) = done.recv() => {
                    // the agent queued every update of that turn before it answered: handle them first
                    while let Ok(ev) = rx.try_recv() {
                        self.handle(ev).await;
                    }
                    self.finish_turn(end);
                    continue;
                }
                ev = rx.recv() => ev,
            };
            let Some(ev) = ev else { break };
            self.handle(ev).await;
        }
    }

    async fn handle(self: &Arc<Self>, ev: Event) {
        {
            match ev {
                Event::Update { update, .. } => {
                    if let Ok(v) = serde_json::to_value(&update) {
                        let cancel = {
                            let mut st = lock(&self.state);
                            st.apply(&v);
                            std::mem::take(&mut st.cancel_wanted)
                        };
                        self.drain_steps();
                        if cancel {
                            // the pause after a tool call: the turn ends here, the queue waits
                            let _ = self.conn.cancel(&self.acp);
                            self.persist_queue();
                        }
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
                        st.stash = None;
                        st.step_close(now(), None);
                        st.seq += 1;
                    }
                    self.drain_steps();
                    self.flush_transcript();
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
        // The matrix decides first: allowed answers at once, never refuses at once, an ask waits for the user.
        let s = self.clone();
        tokio::spawn(async move {
            let (action, facts) = classify(req.get("toolCall"));
            let ctx = ActionCtx {
                session: Some(s.id.clone()),
                facts,
                ..ActionCtx::default()
            };
            let gate = s
                .gate
                .decide(&s.settings, &s.writer, s.who(), action, ctx)
                .await;
            match gate {
                Gate::Never(_) => reply(resp, pick_reject(&options)),
                Gate::Allow if pick_allow(&options).is_some() => reply(resp, pick_allow(&options)),
                _ => s.hold_permission(&req, options, resp),
            }
        });
    }

    /// A request the user answers: it waits in the snapshot.
    fn hold_permission(
        self: &Arc<Self>,
        req: &Value,
        options: Vec<(String, String)>,
        resp: hermod::Responder<RequestPermissionResponse>,
    ) {
        let tool = req.get("toolCall").cloned();
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
        {
            let mut st = lock(&self.state);
            st.permissions.push(Pending {
                request,
                public,
                options,
                resp,
            });
            st.wait_begin();
        }
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
        st.wait_end();
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
        let nth = |what: &str| {
            p.n.ok_or_else(|| invalid("n", format!("{what} needs n, the queued message's place")))
        };
        match p.op {
            AgentOp::Review => Err(invalid(
                "item",
                "no such review (no write is held for review)",
            )),
            AgentOp::DeliverQueue => {
                lock(&self.state).paused = false;
                self.persist_queue();
                self.next();
                self.changed();
                Ok(true)
            }
            AgentOp::Unqueue => {
                let n = nth("unqueue")?;
                let gone = lock(&self.state).queue.remove(n as usize);
                self.queue_edited(gone.is_some(), n)
            }
            AgentOp::Requeue => {
                let n = nth("requeue")?;
                let text = p.text.as_ref().map_or("", |t| t.as_str());
                let done = if text.trim().is_empty() {
                    lock(&self.state).queue.remove(n as usize).is_some()
                } else {
                    lock(&self.state)
                        .queue
                        .replace(n as usize, text.to_string())
                };
                self.queue_edited(done, n)
            }
        }
    }

    fn queue_edited(self: &Arc<Self>, done: bool, n: u64) -> Result<bool, Error> {
        if !done {
            return Err(invalid("n", format!("no queued message {n}")));
        }
        self.persist_queue();
        self.changed();
        Ok(true)
    }

    /// The running turn, if any, is the only thing Stop cancels: the permission requests it waits on are answered
    /// cancelled, the queue is held, and an agent that has not ended the turn after STOP_ANSWER loses its process.
    pub(crate) fn stop_turn(self: &Arc<Self>) -> bool {
        let (turn, pending) = {
            let mut st = lock(&self.state);
            if st.status != SessionStatus::Busy {
                return false;
            }
            st.paused = true;
            st.hold = false;
            let pending: Vec<Pending> = st.permissions.drain(..).collect();
            st.wait_end();
            (st.turn, pending)
        };
        for p in pending {
            reply(p.resp, None);
        }
        let _ = self.conn.cancel(&self.acp);
        self.persist_queue();
        self.changed();
        let me = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(STOP_ANSWER).await;
            let same = {
                let st = lock(&me.state);
                st.status == SessionStatus::Busy && st.turn == turn
            };
            if same {
                draugr::kill_group(me.conn.pid(), STOP_GRACE, &draugr::RealSignaller).await;
            }
        });
        true
    }

    /// Pause: cancel once the tool call running now completes and hold the queue; with no turn running, hold the
    /// queue.
    pub(crate) fn pause_after_tool(self: &Arc<Self>) -> Result<(), Error> {
        {
            let mut st = lock(&self.state);
            match st.status {
                SessionStatus::Exited => return Err(invalid("id", "the session has exited")),
                SessionStatus::Busy => st.hold = true,
                _ => st.paused = true,
            }
        }
        self.persist_queue();
        self.changed();
        Ok(())
    }

    pub(crate) fn status(&self) -> SessionStatus {
        lock(&self.state).status
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

    /// A prompt from ORIGIN.  Idle, it goes behind whatever a Stop held back and the queue is delivered; during a
    /// turn it waits in the queue (ahead of the ordinary ones when the profile's mode is `steer`).  It never
    /// cancels: `interrupt` mode queues too, and only Stop cancels.
    pub(crate) fn prompt(self: &Arc<Self>, text: String, origin: Origin) -> Result<(), Error> {
        let idle = {
            let mut st = lock(&self.state);
            if st.status == SessionStatus::Exited {
                return Err(invalid("id", "the session has exited"));
            }
            let idle = st.status == SessionStatus::Idle;
            let steer = !idle && self.mode == Some(Mode::Steer);
            st.queue.push(text, origin, steer);
            if idle {
                st.paused = false;
            }
            idle
        };
        self.persist_queue();
        if idle {
            self.next();
        }
        self.changed();
        Ok(())
    }

    /// Start the next queued prompt when the session is idle and the queue is not held.
    fn next(self: &Arc<Self>) {
        let item = {
            let mut st = lock(&self.state);
            if st.status != SessionStatus::Idle || st.paused {
                return;
            }
            let Some(item) = st.queue.pop() else { return };
            st.status = SessionStatus::Busy;
            st.turn += 1;
            st.open = None;
            st.text(EntryType::User, &item.text, None);
            if let Some(e) = st.entries.last_mut() {
                if let Some(tag) = item.origin.tag() {
                    e.rest.insert("origin".into(), json!(tag));
                }
                if item.steer {
                    e.rest.insert("steer".into(), json!(true));
                }
            }
            st.open = None;
            st.step_begin(StepClass::Think, None);
            item
        };
        self.persist_queue();
        self.flush_transcript();
        self.changed();
        tokio::spawn(self.clone().turn(item));
    }

    /// One turn of ITEM, and what follows it: the stop entry, the steps closed, the transcript written, the next
    /// queued prompt unless a Stop or a pause holds it.
    async fn turn(self: Arc<Self>, item: Queued) {
        let block = json!({"type": "text", "text": item.origin.frame(&item.text)});
        let blocks = serde_json::from_value(json!([block])).unwrap_or_default();
        let out = self.conn.prompt(&self.acp, blocks, None).await;
        // the reader task ends the turn, after the updates the agent sent before its answer
        let _ = self.done.send(TurnEnd(out));
    }

    fn finish_turn(self: &Arc<Self>, end: TurnEnd) {
        let out = end.0;
        {
            let mut st = lock(&self.state);
            st.open = None;
            st.hold = false;
            let mut rest = Map::new();
            let mut used = TurnUse::default();
            match &out {
                Ok(o) => {
                    rest.insert("stop".into(), json!(format!("{:?}", o.stop)));
                    st.push(EntryType::Stop, rest);
                    if serde_json::to_value(o.stop).ok() == Some(json!("cancelled")) && !st.ending {
                        st.paused = true;
                    }
                    used = turn_use(o);
                }
                Err(hermod::Error::Closed) => {}
                Err(e) => {
                    rest.insert("text".into(), json!(e.to_string()));
                    st.push(EntryType::Error, rest);
                    st.paused = !st.ending;
                }
            }
            st.stash = None;
            st.step_close(now(), Some(used));
            if st.status == SessionStatus::Busy {
                st.status = SessionStatus::Idle;
                if st.paused {
                    st.step_begin(StepClass::Paused, None);
                }
            }
        }
        if lock(&self.state).ending {
            self.drain_steps();
            self.flush_transcript();
            return;
        }
        self.persist_queue();
        self.flush_transcript();
        self.changed();
        self.next();
    }

    /// The hub ends: the transcript written, the agent's process group ended, the queue left as it is on disk for
    /// the next start.
    pub(crate) async fn shutdown(&self) {
        lock(&self.state).ending = true;
        self.flush_transcript();
        draugr::kill_group(
            self.conn.pid(),
            Duration::from_secs(1),
            &draugr::RealSignaller,
        )
        .await;
    }
}

/// What a finished turn used, from ACP's `usage` and `_meta.turnId`.
fn turn_use(o: &hermod::PromptOutcome) -> TurnUse {
    let u = serde_json::to_value(&o.usage).unwrap_or(Value::Null);
    let n = |k: &str| u.get(k).and_then(Value::as_i64).unwrap_or(0);
    TurnUse {
        turn_id: o.turn_id.clone(),
        tokens_in: n("inputTokens"),
        tokens_out: n("outputTokens"),
        cache_read: n("cachedReadTokens"),
        cache_write: n("cachedWriteTokens"),
        cost: None,
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

/// The option that allows once (else any allowing one); none when the agent offered no way to say yes.
fn pick_allow(options: &[(String, String)]) -> Option<String> {
    options
        .iter()
        .find(|(_, k)| k == "allow_once")
        .or_else(|| options.iter().find(|(_, k)| k.starts_with("allow")))
        .map(|(id, _)| id.clone())
}

/// What a tool call is in the matrix's words, and the facts a card shows (the hub's own reading of it).
fn classify(tool: Option<&Value>) -> (Action, runstav::methods::matrix::Facts) {
    let kind = tool
        .and_then(|t| t.get("kind"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let command = tool
        .and_then(|t| t.pointer("/rawInput/command").or_else(|| t.get("title")))
        .and_then(Value::as_str)
        .map(str::to_string);
    let paths: Vec<&str> = tool
        .and_then(|t| t.get("locations"))
        .and_then(Value::as_array)
        .map(|l| {
            l.iter()
                .filter_map(|p| p.get("path").and_then(Value::as_str))
                .filter(|p| p.starts_with('/'))
                .collect()
        })
        .unwrap_or_default();
    let action = match kind {
        "read" | "search" | "think" | "switch_mode" => Action::CodeRead,
        "fetch" => Action::Network,
        "execute" => {
            let c = command.as_deref().unwrap_or("");
            if c.contains("git push") {
                if c.contains("main") || c.contains("master") {
                    Action::PushMain
                } else {
                    Action::PushCi
                }
            } else if c.contains("git commit") {
                Action::Commit
            } else {
                Action::CodeEdit
            }
        }
        _ => Action::CodeEdit,
    };
    let facts =
        serde_json::from_value(json!({"command": command, "paths": paths})).unwrap_or_default();
    (action, facts)
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

pub async fn list(f: &Front, c: &Caller, _: Empty) -> Result<serde_json::Value, Error> {
    Ok(f.core.agents.list(c))
}

pub async fn start(f: &Front, c: &Caller, p: StartParams) -> Result<Started, Error> {
    f.core.agents.start(f, p, c).await
}

pub async fn get(f: &Front, _: &Caller, p: ById) -> Result<Transcript, Error> {
    f.core.agents.get(p.id.as_str())
}

/// The user's prompt: a turn while idle, else queued (or steered); it never cancels.
pub async fn send(f: &Front, c: &Caller, p: SendParams) -> Result<bool, Error> {
    if c.class != Class::User {
        return Err(refuse("only the user sends a message here"));
    }
    f.core
        .agents
        .send(p.id.as_str(), p.text.as_str().to_string())?;
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
    fn a_turn_is_think_tool_think_and_a_wait_is_split_out() {
        let mut st = State::new();
        st.step_begin(StepClass::Think, None);
        st.apply(&upd(
            json!({"sessionUpdate": "tool_call", "toolCallId": "t1",
            "title": "Read x", "kind": "read", "status": "pending"}),
        ));
        st.wait_begin();
        st.wait_end();
        st.apply(&upd(
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1",
            "status": "completed"}),
        ));
        st.step_close(
            now(),
            Some(TurnUse {
                tokens_out: 7,
                ..TurnUse::default()
            }),
        );
        let got: Vec<(StepClass, Option<&str>)> = st
            .closed
            .iter()
            .map(|c| (c.open.class, c.open.tool.as_deref()))
            .collect();
        assert_eq!(
            got,
            [
                (StepClass::Think, None),
                (StepClass::Tool, Some("Read x")),
                (StepClass::UserWait, None),
                (StepClass::Tool, Some("Read x")),
                (StepClass::Think, None),
            ]
        );
        assert_eq!(st.closed.last().unwrap().tokens_out, 7);
        assert_eq!(st.closed[1].open.tool_kind.as_deref(), Some("read"));
    }

    #[tokio::test]
    async fn closed_steps_reach_the_step_table_in_order_and_are_announced() {
        let dir = tempfile::tempdir().unwrap();
        let writer = crate::coord::Writer {
            db: norn::store::CoordDb::spawn(dir.path().join("work.db")),
            signals: Arc::new(crate::coord::Signals::default()),
        };
        let editors = Arc::new(crate::settings::agents::Editors::default());
        let (bus, mut seen) = tokio::sync::broadcast::channel(16);
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let ctx = StepCtx {
            session: "a1".into(),
            task: Some("task:7".into()),
            agent: "mock".into(),
            provider: None,
        };
        let sink = StepSink {
            writer: writer.clone(),
            editors,
            bus,
        };
        tokio::spawn(write_steps(rx, sink, ctx));
        let open = |class, tool: Option<&str>| OpenStep {
            class,
            start: 10.0,
            tool: tool.map(str::to_string),
            tool_kind: None,
            tool_id: None,
            message_id: None,
        };
        for (class, tool, turn) in [
            (StepClass::Think, None, None),
            (StepClass::Tool, Some("Read x"), Some("t1".to_string())),
        ] {
            tx.send(ClosedStep {
                open: open(class, tool),
                end: 11.0,
                turn_id: turn,
                tokens_in: 10,
                tokens_out: 5,
                cache_read: 0,
                cache_write: 0,
                cost: None,
            })
            .unwrap();
        }
        let first = seen.recv().await.unwrap();
        let second = seen.recv().await.unwrap();
        assert_eq!((first.step.seq, first.step.class), (1, StepClass::Think));
        assert_eq!((second.step.seq, second.step.class), (2, StepClass::Tool));
        assert_eq!(second.step.turn_id.as_deref(), Some("t1"));
        assert_eq!(second.step.tokens_out, Some(5));
        let caller = Caller {
            class: Class::Service,
            sid: None,
            job: None,
            conn_id: 0,
            backend: false,
        };
        let rows: Vec<(String, i64, String, Option<String>)> = writer
            .write(&caller, "agents/step", |tx| {
                let mut q = tx
                    .sql()
                    .prepare("select session, seq, class, tool from step order by seq")?;
                let it = q.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
                Ok(it.collect::<Result<Vec<_>, _>>()?)
            })
            .await
            .unwrap();
        assert_eq!(
            rows,
            [
                ("session:a1".to_string(), 1, "think".to_string(), None),
                (
                    "session:a1".to_string(),
                    2,
                    "tool".to_string(),
                    Some("Read x".to_string())
                ),
            ]
        );
    }

    #[test]
    fn a_hold_cancels_when_the_tool_call_completes_and_holds_the_queue() {
        let mut st = State::new();
        st.hold = true;
        st.apply(&upd(
            json!({"sessionUpdate": "tool_call", "toolCallId": "t1",
            "title": "Run", "kind": "execute", "status": "in_progress"}),
        ));
        assert!(!st.cancel_wanted && st.hold);
        st.apply(&upd(
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1",
            "status": "completed"}),
        ));
        assert!(st.cancel_wanted && st.paused && !st.hold);
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
