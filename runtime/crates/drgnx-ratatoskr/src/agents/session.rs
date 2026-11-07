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

#[cfg(test)]
pub(crate) mod attach_tests;
pub(crate) mod panel;
pub(crate) mod turn_core;

use super::launch;
use super::lock as plock;
use super::queue::{Origin, Queued};
use super::rewind::RestoreLevel;
use super::transcript;
use super::wheel::{self, Wheel};
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
    AgentOp, AgentWheel, ById, DoParams, Entry, EntryType, Mode, MoveParams, Permission,
    PermissionParams, RpcId, SendParams, SessionStatus, Snapshot, StartParams, Started, Transcript,
    Usage, Via, WheelSaved, WheelState,
};
use runstav::methods::hub::{EnvVar, refused_env_name};
use runstav::methods::matrix::{Role, Unit};
use runstav::methods::timeline::{AgentStep, Step, StepClass};
use runstav::registry::Class;
use runstav::types::RequestId;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Map, Value, json};
use std::collections::{BTreeSet, HashMap};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use turn_core::{KillWhy, QueueEdit, TurnCore, TurnEffect, TurnEvent};

/// Events about one session come at most this often.
const EMIT_EVERY: Duration = Duration::from_millis(50);
/// SIGTERM, then SIGKILL after this.
const STOP_GRACE: Duration = Duration::from_secs(3);
/// A Stop that the agent has not answered by then ends its process.
const STOP_ANSWER: Duration = Duration::from_secs(2);
/// A session's network: the provider's alone, through its proxy (`super::net`); `Open` is never granted here.
pub(crate) const SESSION_NET: launch::NetCell = launch::NetCell::ProviderOnly;
/// How long a give waits for the editor's `agents/wheel/saved`.
const WHEEL_SAVE_WAIT: Duration = Duration::from_secs(5);

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn now() -> f64 {
    crate::clock::wall_secs()
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

pub(crate) fn invalid(path: &str, message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

pub(crate) fn internal(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
        path: None,
    }
}

/// A permission request the agent waits on.
struct Pending {
    request: u64,
    /// The matrix card the request waits on: its id is the request's (the user answers the card).
    card: Option<i64>,
    public: Permission,
    options: Vec<(String, String)>,
    resp: hermod::Responder<RequestPermissionResponse>,
}

impl Pending {
    /// Whether the user's answer to ID is for this request: the card's id, or `r<n>` for one without a card.
    fn is(&self, id: &RequestId) -> bool {
        match (self.card, id) {
            (Some(c), RequestId::Num(n)) => i64::try_from(*n) == Ok(c),
            (Some(c), RequestId::Str(s)) => c.to_string() == *s,
            (None, RequestId::Str(s)) => format!("r{}", self.request) == *s,
            (None, RequestId::Num(_)) => false,
        }
    }

    /// The option to answer with: CHOSEN when it was offered and is of the verdict's kind, else the first allowing
    /// (ALLOW) or rejecting one.
    fn option(&self, allow: bool, chosen: Option<&str>) -> Option<String> {
        let kind = if allow { "allow" } else { "reject" };
        chosen
            .filter(|o| {
                self.options
                    .iter()
                    .any(|(id, k)| id == o && k.starts_with(kind))
            })
            .map(str::to_owned)
            .or_else(|| {
                if allow {
                    pick_allow(&self.options)
                } else {
                    pick_reject(&self.options)
                }
            })
    }
}

/// An agent message's Markdown blocks, and what the editors have not been told of them yet.
struct MdMessage {
    entry: usize,
    stream: super::markdown::Stream,
    /// The editors have the whole `blocks` of the message (else the next event carries them, not a patch).
    sent: bool,
    patch: std::collections::BTreeMap<usize, super::markdown::Block>,
}

struct State {
    /// The turn, the queue, the Stop and the permission requests' choices (`turn_core.rs`).
    core: TurnCore,
    seq: u64,
    entries: Vec<Entry>,
    /// Tool call id → index in `entries`.
    tools: HashMap<String, usize>,
    /// Tool call id → the provider's tool name and its parent tool call (`_meta.claudeCode`), kept beside the
    /// entries, whose wire shape stays as it was.
    tool_meta: HashMap<String, ToolMeta>,
    /// The entry the next text chunk of that kind extends.
    open: Option<(EntryType, usize)>,
    /// Entries changed since the last event.
    dirty: BTreeSet<usize>,
    /// The agent message still streaming, as Markdown blocks.
    md: Option<MdMessage>,
    permissions: Vec<Pending>,
    usage: Option<Usage>,
    commands: Vec<Value>,
    exit: Option<i64>,
    stderr: Option<String>,
    /// A tool call completed or failed in the last update: the reader tells the core.
    tool_ended: bool,
    /// Entries before this index are in the transcript file.
    flushed: usize,
    /// The user entry of a turn whose prompt has not reached the agent: it and what follows stay out of the
    /// transcript file until it does (the hub's end puts such a turn back in the queue and drops its entries).
    unsent_at: Option<usize>,
    /// The step running, and the steps closed since the last drain.
    cur: Option<OpenStep>,
    stash: Option<OpenStep>,
    closed: Vec<ClosedStep>,
    /// The tree taken before the running turn's prompt went: the next step that closes (the turn's first) carries it.
    before: Option<String>,
    /// The checkpoints of the edit steps closed since the agent's last served write, which their step's writer may
    /// not have taken yet: the next write takes them first ([`crate::timeline::Snap::before_write`]).
    edits: Vec<crate::timeline::EditCell>,
    /// The message id last seen in an update: the anchor of the steps that have none of their own (tool calls).
    last_mid: Option<String>,
    /// When the agent last sent an update (or its turn began): what the supervisor's `silent` rule reads.
    last_update: f64,
    /// Tool calls started this turn, by title and command, and the most any one was repeated.
    cmd_counts: HashMap<String, u32>,
    max_repeat: u32,
    /// Tokens the finished turns used.
    tokens: u64,
    /// What the budget booked from the agent's cost readings since the last turn ended.
    turn_cost: f64,
    /// Turns started by this hub process (the snapshot's `turns`).
    turns: u64,
    /// The steps begun so far (each step's key).
    steps_begun: i64,
    /// Tool steps of a conclusion's drgnx tool begun since the reader last looked: (key, tool name).
    mcp_begun: Vec<(i64, String)>,
    /// What the updates since the reader last looked tell the presence model, by tool call.
    live_out: Vec<(String, LiveOut)>,
    /// Who drives: the agent, or the user holding (or taking) its wheel ([`super::wheel`]).
    wheel: Wheel,
    /// The step snapshot taken when the hold began: what the give measures the user's changes from.
    wheel_base: Option<String>,
    /// The tool entry the last update changed, for the follow feed ([`crate::editor::follow`]).
    follow_tool: Option<usize>,
    /// The plan's `in_progress` entry, the follow feed's line when the agent sends plans.
    plan_now: Option<String>,
}

/// What a tool call's update tells the presence model's live feed ([`crate::work::presence`]): taken under the state's
/// lock, applied after it.
#[derive(Clone, Debug)]
enum LiveOut {
    /// It runs: its detail as it stands now (the path as the agent gave it), its status, and its content's `diff` items
    /// (path, oldText, newText): an edit's lines, and its `pending` while it has not landed.
    At {
        detail: Box<norn::write::work::StepDetail>,
        status: crate::work::presence::CallStatus,
        diffs: Diffs,
    },
    /// It failed, or it ended with no step of its own open: its live entry goes.
    Gone,
}

/// A tool call's `diff` content items: (path, oldText, newText).
type Diffs = Vec<(String, Option<String>, String)>;

/// A tool call entry's ACP status (absent: pending).
fn call_status(rest: &Map<String, Value>) -> crate::work::presence::CallStatus {
    use crate::work::presence::CallStatus;
    match rest.get("status").and_then(Value::as_str) {
        Some("in_progress") => CallStatus::InProgress,
        Some("completed") => CallStatus::Completed,
        Some("failed") => CallStatus::Failed,
        _ => CallStatus::Pending,
    }
}

/// What a turn core step decided, with the permission requests it took out of the snapshot.
#[derive(Default)]
struct Stepped {
    fx: Vec<TurnEffect>,
    /// To answer with the user's choice.
    answered: Vec<Pending>,
    /// To answer cancelled.
    cancelled: Vec<Pending>,
    /// The turn the take stopped ended: the wheel is held now.
    held: bool,
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
    /// Its place among the steps the session began (a step a wait cut in two keeps it).
    key: i64,
    /// A call of a drgnx tool that records a conclusion ([`crate::work::conclusions`]).
    mcp: bool,
    /// The `Task` tool call of the subagent that made it ([`crate::work::subagents`]).
    parent_tool: Option<String>,
}

impl OpenStep {
    /// A tool call that changes files: its step gets a checkpoint.
    fn is_edit(&self) -> bool {
        self.class == StepClass::Tool
            && matches!(self.tool_kind.as_deref(), Some("edit" | "delete" | "move"))
    }
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
    /// What a tool step read, searched or fetched, taken as the step closed (its `rawInput` is final then).
    detail: Option<norn::write::work::StepDetail>,
    /// A shell step's command, taken then too: the files it names are its presence ([`crate::work::presence`]).
    command: Option<String>,
    /// The session's context size in tokens when the step closed: kept on a turn's last step and on a job wait.
    context: Option<i64>,
    /// On a turn's first step: the tree the worktree held before the prompt went to the agent, its checkpoint.
    before: Option<String>,
    /// A tool step's call had ended when the step closed (completed or failed); none: the step was cut (a wait, the
    /// next call) while the call runs on, and its live presence entry still stands for it.
    call_end: Option<crate::work::presence::CallStatus>,
    /// A tool step's `diff` content items: where an edit's lines are found when the step is written.
    diffs: Diffs,
    /// On an edit step: its checkpoint, taken by the writer or before the agent's next write, whichever is first.
    cell: Option<crate::timeline::EditCell>,
}

/// What a provider says of a tool call beyond ACP's fields: Claude's `_meta.claudeCode`.
#[derive(Clone, Debug, Default)]
struct ToolMeta {
    name: Option<String>,
    parent: Option<String>,
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
            core: TurnCore::new(),
            tool_ended: false,
            flushed: 0,
            unsent_at: None,
            cur: None,
            stash: None,
            last_mid: None,
            last_update: now(),
            cmd_counts: HashMap::new(),
            max_repeat: 0,
            tokens: 0,
            turn_cost: 0.0,
            turns: 0,
            steps_begun: 0,
            mcp_begun: Vec::new(),
            live_out: Vec::new(),
            wheel: Wheel::Free,
            wheel_base: None,
            follow_tool: None,
            plan_now: None,
            closed: Vec::new(),
            before: None,
            edits: Vec::new(),
            seq: 0,
            entries: Vec::new(),
            tools: HashMap::new(),
            tool_meta: HashMap::new(),
            open: None,
            dirty: BTreeSet::new(),
            md: None,
            permissions: Vec::new(),
            usage: None,
            commands: Vec::new(),
            exit: None,
            stderr: None,
        }
    }

    /// The budget booked DELTA of cost; the turn running owns it.
    fn add_turn_cost(&mut self, delta: f64) {
        self.turn_cost += delta;
    }

    /// What the turn that just ended cost: what the budget booked during it.  None when nothing was booked (an agent
    /// that reports no cost, or a total that did not move), never 0.0.
    fn take_turn_cost(&mut self) -> Option<f64> {
        let cost = std::mem::take(&mut self.turn_cost);
        (cost > 0.0).then_some(cost)
    }

    /// Close the step running (if any) at END, carrying USE.
    fn step_close(&mut self, end: f64, turn_use: Option<TurnUse>) {
        if let Some(open) = self.cur.take() {
            let context = (turn_use.is_some() || open.class == StepClass::JobWait)
                .then(|| self.usage.as_ref().and_then(|u| u.used))
                .flatten()
                .map(|used| used as i64);
            let u = turn_use.unwrap_or_default();
            let mut detail = open.tool_id.as_deref().and_then(|id| self.tool_detail(id));
            // a subagent's step keeps its parent, with a detail of its own if it has none
            if let Some(p) = &open.parent_tool {
                let name = open
                    .tool_id
                    .as_deref()
                    .and_then(|id| self.tool_meta.get(id))
                    .and_then(|m| m.name.clone());
                detail
                    .get_or_insert_with(|| norn::write::work::StepDetail {
                        tool: name,
                        origin: "acp".into(),
                        ..Default::default()
                    })
                    .parent_tool = Some(p.clone());
            }
            let command = open.tool_id.as_deref().and_then(|id| self.tool_command(id));
            let call_end = open
                .tool_id
                .as_deref()
                .and_then(|id| self.entries.get(*self.tools.get(id)?))
                .map(|e| call_status(&e.rest))
                .filter(|s| {
                    use crate::work::presence::CallStatus;
                    matches!(s, CallStatus::Completed | CallStatus::Failed)
                });
            let diffs = open
                .tool_id
                .as_deref()
                .map(|id| self.tool_diffs(id))
                .unwrap_or_default();
            let cell = open.is_edit().then(|| {
                let c = crate::timeline::EditCell::default();
                self.edits.retain(|e| !e.is_done());
                self.edits.push(c.clone());
                c
            });
            self.closed.push(ClosedStep {
                cell,
                detail,
                command,
                call_end,
                diffs,
                open,
                end,
                turn_id: u.turn_id,
                tokens_in: u.tokens_in,
                tokens_out: u.tokens_out,
                cache_read: u.cache_read,
                cache_write: u.cache_write,
                cost: u.cost,
                context,
                before: self.before.take(),
            });
        }
    }

    /// The detail of tool call ID from what the entry holds now.
    fn tool_detail(&self, id: &str) -> Option<norn::write::work::StepDetail> {
        let rest = &self.entries.get(*self.tools.get(id)?)?.rest;
        let s = |k: &str| rest.get(k).and_then(Value::as_str);
        let locations = rest
            .get("locations")
            .and_then(Value::as_array)
            .map_or(&[][..], Vec::as_slice);
        crate::work::detail::of(
            self.tool_meta.get(id).and_then(|m| m.name.as_deref()),
            s("kind"),
            s("title"),
            locations,
            rest.get("rawInput"),
        )
    }

    /// The `diff` items of tool call ID's content as the entry holds it now.
    fn tool_diffs(&self, id: &str) -> Diffs {
        self.tools
            .get(id)
            .and_then(|i| self.entries.get(*i))
            .map(|e| crate::work::edit_lines::diffs(e.rest.get("content")))
            .unwrap_or_default()
    }

    /// The command of tool call ID when it is a shell step (kind `execute`, or Claude's `Bash`): `rawInput.command`, a
    /// string or a list of words.
    fn tool_command(&self, id: &str) -> Option<String> {
        let rest = &self.entries.get(*self.tools.get(id)?)?.rest;
        let shell = rest.get("kind").and_then(Value::as_str) == Some("execute")
            || self.tool_meta.get(id).and_then(|m| m.name.as_deref()) == Some("Bash");
        if !shell {
            return None;
        }
        match rest.get("rawInput")?.get("command")? {
            Value::String(s) => Some(s.clone()),
            Value::Array(words) => Some(
                words
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(" "),
            ),
            _ => None,
        }
    }

    /// The running step ends and a step of CLASS begins.
    fn step_begin(&mut self, class: StepClass, tool: Option<(&str, Option<&str>, Option<&str>)>) {
        let at = now();
        self.step_close(at, None);
        self.steps_begun += 1;
        self.cur = Some(OpenStep {
            class,
            start: at,
            tool: tool.map(|t| t.0.to_string()),
            tool_kind: tool.and_then(|t| t.1).map(str::to_string),
            tool_id: tool.and_then(|t| t.2).map(str::to_string),
            message_id: self.last_mid.clone(),
            key: self.steps_begun,
            mcp: false,
            parent_tool: tool
                .and_then(|t| t.2)
                .and_then(|id| self.tool_meta.get(id))
                .and_then(|m| m.parent.clone()),
        });
    }

    /// A step of thinking when none runs (text arriving between tool calls).
    fn step_think(&mut self, message_id: Option<&str>) {
        if self.cur.is_none() {
            self.step_begin(StepClass::Think, None);
        }
        if let Some(c) = self.cur.as_mut()
            && c.class == StepClass::Think
            && message_id.is_some()
        {
            c.message_id = message_id.map(str::to_string);
        }
    }

    /// A permission request makes the step wait for the user; the step it interrupted comes back after.
    fn wait_begin(&mut self) {
        self.stash_begin(StepClass::UserWait);
    }

    /// A wait of CLASS (user, machine queue) cuts into the step running; that step comes back after.
    fn stash_begin(&mut self, class: StepClass) {
        if self.stash.is_none() {
            self.stash = self.cur.clone();
        }
        self.step_begin(class, None);
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

    /// EV through the turn core.  The requests it answers or cancels leave the snapshot here, under the same lock,
    /// and the step the user waited in ends; the shell replies to them ([`Session::perform`]).  A turn that starts
    /// gets its entry and its first step here too.
    fn turn_step(&mut self, ev: TurnEvent) -> Stepped {
        let fx = self.core.step(ev);
        self.stepped(fx)
    }

    /// The next queued prompt's turn, if one can start ([`TurnCore::next`]).
    fn turn_step_next(&mut self) -> Stepped {
        let fx = self.core.next();
        self.stepped(fx)
    }

    fn stepped(&mut self, fx: Vec<TurnEffect>) -> Stepped {
        let mut out = Stepped::default();
        for e in &fx {
            let (request, answered) = match e {
                TurnEffect::Answer { request } => (*request, true),
                TurnEffect::Cancel { request } => (*request, false),
                // no model request until the wake: the step is the wait
                TurnEffect::EndTurn { waiting: true, .. } => {
                    self.step_begin(StepClass::JobWait, None);
                    continue;
                }
                TurnEffect::EndTurn { paused: true, .. } => {
                    self.step_begin(StepClass::Paused, None);
                    continue;
                }
                TurnEffect::StartTurn { item, .. } => {
                    self.unsent_at = Some(self.entries.len());
                    self.turns += 1;
                    self.begin_turn(item);
                    continue;
                }
                TurnEffect::Prompt { .. } => {
                    self.unsent_at = None;
                    continue;
                }
                TurnEffect::PutBack { .. } => {
                    self.turns = self.turns.saturating_sub(1);
                    self.undo_turn();
                    continue;
                }
                _ => continue,
            };
            if let Some(at) = self.permissions.iter().position(|p| p.request == request) {
                let p = self.permissions.remove(at);
                if answered {
                    out.answered.push(p);
                } else {
                    out.cancelled.push(p);
                }
                self.wait_end();
            }
        }
        out.held = wheel::turn_ended(&mut self.wheel, &fx);
        out.fx = fx;
        out
    }

    /// A turn of ITEM began: its user entry, and a step of thinking.
    fn begin_turn(&mut self, item: &Queued) {
        self.last_update = now();
        self.cmd_counts.clear();
        self.max_repeat = 0;
        self.open = None;
        self.text(EntryType::User, &item.text, None);
        if let Some(e) = self.entries.last_mut() {
            if let Some(tag) = item.origin.tag() {
                e.rest.insert("origin".into(), json!(tag));
            }
            if item.steer {
                e.rest.insert("steer".into(), json!(true));
            }
            if let Some(key) = &item.key {
                e.rest.insert("key".into(), json!(key));
            }
        }
        self.open = None;
        self.step_begin(StepClass::Think, None);
    }

    /// The turn whose prompt never reached the agent is undone: its entries (none of them in the transcript file) and
    /// its open step go; the prompt is back in the queue.
    fn undo_turn(&mut self) {
        let Some(at) = self.unsent_at.take() else {
            return;
        };
        self.entries.truncate(at);
        self.dirty.retain(|i| *i < at);
        self.tools.retain(|_, i| *i < at);
        if self.md.as_ref().is_some_and(|m| m.entry >= at) {
            self.md = None;
        }
        self.open = None;
        self.cur = None;
        self.stash = None;
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
            self.md_follow(kind, i);
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
        self.md_follow(kind, i);
    }

    /// Entry I, an agent message, has more text: only its last block is parsed again, and the blocks that changed wait
    /// for the next event.  The message before it is no longer followed.
    fn md_follow(&mut self, kind: EntryType, i: usize) {
        if kind != EntryType::Agent {
            return;
        }
        if self.md.as_ref().is_none_or(|m| m.entry != i) {
            self.md = Some(MdMessage {
                entry: i,
                stream: super::markdown::Stream::default(),
                sent: false,
                patch: Default::default(),
            });
        }
        let text = self.entries[i]
            .rest
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or("");
        if let Some(m) = self.md.as_mut() {
            for b in m.stream.update(text) {
                m.patch.insert(b.block, b);
            }
        }
    }

    /// One `session/update` of the agent (its JSON), as entries, commands and usage.
    fn apply(&mut self, u: &Value) {
        self.seq += 1;
        self.last_update = now();
        let kind = u.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        let text_of = |u: &Value| {
            let c = u.get("content");
            match c.and_then(|c| c.get("text")).and_then(Value::as_str) {
                Some(t) => t.to_string(),
                None => c.map(Value::to_string).unwrap_or_default(),
            }
        };
        let mid = u.get("messageId").and_then(Value::as_str);
        if mid.is_some() {
            self.last_mid = mid.map(str::to_string);
        }
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
                if let Some(cc) = u.pointer("/_meta/claudeCode") {
                    let m = self
                        .tool_meta
                        .entry(
                            u.get("toolCallId")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string(),
                        )
                        .or_default();
                    let s = |k: &str| cc.get(k).and_then(Value::as_str).map(str::to_string);
                    m.name = s("toolName").or(m.name.take());
                    m.parent = s("parentToolUseId").or(m.parent.take());
                }
                self.follow_tool = Some(idx);
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
                        let mut v = v.clone();
                        if k == "content" {
                            // a huge output keeps its head and tail and the whole size
                            match super::tool_output::fold(
                                &mut v,
                                super::tool_output::KEEP_HEAD,
                                super::tool_output::KEEP_TAIL,
                            ) {
                                Some(total) => {
                                    e.rest.insert("outputBytes".into(), json!(total));
                                }
                                None => {
                                    e.rest.remove("outputBytes");
                                }
                            }
                        }
                        e.rest.insert(k.into(), v);
                    }
                }
                self.dirty.insert(idx);
                let (title, tkind, status) = {
                    let r = &self.entries[idx].rest;
                    let s = |k: &str| r.get(k).and_then(Value::as_str).map(str::to_string);
                    (s("title"), s("kind"), s("status"))
                };
                let id = u.get("toolCallId").and_then(Value::as_str).unwrap_or("");
                // the live presence feed: a running call where it is now; one that ended gives way to its step's
                // close, or goes now when no step of its own is open to close (cut by the next call)
                {
                    use crate::work::presence::CallStatus;
                    let step_open = [self.cur.as_ref(), self.stash.as_ref()]
                        .into_iter()
                        .flatten()
                        .any(|c| c.tool_id.as_deref() == Some(id));
                    let out = match call_status(&self.entries[idx].rest) {
                        CallStatus::Failed => Some(LiveOut::Gone),
                        CallStatus::Completed => (!step_open).then_some(LiveOut::Gone),
                        status => self.tool_detail(id).map(|detail| LiveOut::At {
                            detail: Box::new(detail),
                            status,
                            diffs: self.tool_diffs(id),
                        }),
                    };
                    if let Some(out) = out {
                        self.live_out.push((id.to_string(), out));
                    }
                }
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
                    // a call of a tool that records a conclusion: its step is that conclusion's
                    let name = self
                        .tool_meta
                        .get(id)
                        .and_then(|m| m.name.clone())
                        .filter(|n| crate::work::conclusions::mcp_tool_of(n).is_some())
                        .or_else(|| {
                            title
                                .clone()
                                .filter(|t| crate::work::conclusions::mcp_tool_of(t).is_some())
                        });
                    if let (Some(n), Some(c)) = (name, self.cur.as_mut()) {
                        c.mcp = true;
                        self.mcp_begun.push((c.key, n));
                    }
                    let command = self.entries[idx].rest.get("rawInput").map(Value::to_string);
                    let key = format!(
                        "{}\n{}",
                        title.as_deref().unwrap_or(""),
                        command.unwrap_or_default()
                    );
                    let n = self.cmd_counts.entry(key).or_insert(0);
                    *n += 1;
                    self.max_repeat = self.max_repeat.max(*n);
                }
                if matches!(status.as_deref(), Some("completed" | "failed")) {
                    if self.cur.as_ref().and_then(|c| c.tool_id.as_deref()) == Some(id) {
                        self.step_begin(StepClass::Think, None);
                    }
                    self.tool_ended = true;
                }
            }
            "plan" => {
                self.open = None;
                self.plan_now = u
                    .get("entries")
                    .and_then(Value::as_array)
                    .and_then(|a| {
                        a.iter()
                            .find(|e| e.get("status") == Some(&json!("in_progress")))
                    })
                    .and_then(|e| e.get("content"))
                    .and_then(Value::as_str)
                    .map(str::to_string);
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
    /// The provider whose lock this session's mode switches are checked against ([`plock::refused_mode_switch`]),
    /// and whether that lock holds (whatever the sandbox: `enforced` needs both).
    locked_as: Option<crate::settings::profiles::Provider>,
    lock_held: bool,
    enforced_why: Option<String>,
    /// Why its `browser` cell allows the browser but it has none (OD1 (b)).
    browser_why: Option<String>,
    /// The plugins that run for it differ from the ones it started with ([`crate::sessions::Sessions::plugins_flag`]).
    plugins_changed: Arc<AtomicBool>,
    capabilities: Option<Value>,
    conn: Conn,
    acp: SessionId,
    editors: Arc<crate::settings::agents::Editors>,
    /// The pair door: a project chat's writes of the checkout go through the editor ([`crate::pair`]).
    pair: Arc<crate::pair::door::Door>,
    /// The Work map: each snapshot reaches it too ([`crate::work::map`]).
    map: Arc<crate::work::map::Map>,
    /// The presence model: its tool calls feed it as they run ([`Session::feed_live`]).
    presence: Arc<crate::work::presence::Live>,
    /// The follow feed: each tool call's place reaches it ([`crate::editor::follow`]).
    follows: Arc<crate::editor::follow::Follows>,
    /// What the matrix decides at the permission seam: the gate, the settings it reads, the store its cards go to.
    gate: MatrixGate,
    settings: Arc<crate::settings::Settings>,
    writer: crate::coord::Writer,
    /// The plan and project each session works under (the matrix's project and plan layers).
    scopes: crate::runner::Scopes,
    budgets: crate::budget::Budgets,
    /// The token of the session's gateway registration (a gateway profile).
    gateway: Mutex<Option<String>>,
    /// Its provider proxy on `proxy.sock`: dropped when its agent's process ends.
    net: Mutex<Option<super::net::SessionNet>>,
    next_request: AtomicU64,
    /// The hub's running jobs: a session whose turn ends while one of its own runs waits for it.
    live: Arc<crate::exec::Live>,
    /// Waits refused since the turn began (a running job's `job_result`/`job_log`, a sleep loop).
    wait_refusals: AtomicU32,
    /// Closed while idle on a job: its agent process is gone and the hub resumes it at the wake.
    closed: AtomicBool,
    /// The decision-log version the freshness gate last told this session of (Task 24).
    gated: AtomicU64,
    state: Mutex<State>,
    /// Transcripts and the held queue on disk (none in unit tests).
    store: Option<transcript::Store>,
    /// Step snapshots: a turn's tree is taken before its prompt goes, and the tree at a hold on its wheel (none: the
    /// hub has no state folder).
    snap: Option<crate::timeline::Snap>,
    /// Closed steps, in order, to the task that writes them to the `step` table.
    steps: tokio::sync::mpsc::UnboundedSender<ClosedStep>,
    /// The count of those steps sent and written.
    flow: Arc<StepFlow>,
    /// How a turn ended, to the reader task.
    done: tokio::sync::mpsc::UnboundedSender<TurnEnd>,
    /// The user's messages as they reach the agent: its current ask ([`crate::work::asks`]).
    asks: crate::work::asks::AskTx,
    /// Where its conclusions' tool steps go ([`crate::work::conclusions`]).
    stamps: Arc<crate::work::conclusions::Stamps>,
    /// A planning session's turn ends go to Say it ([`crate::say`]).
    say: crate::say::SayTx,
    /// The front, for the hooks before a tool call (none until the front is bound: no hooks run).
    tool_hub: Arc<crate::coord::ToolHub>,
    /// Its Urdr project, resolved from its folder at the first hook run (`None` inside: no project).
    project: std::sync::OnceLock<Option<String>>,
    /// Which tool kinds its `before-tool` hooks see, as its lock made them at launch (and its adapter, when it offers
    /// `before-tool`).
    hooked: Option<runstav::methods::agents::Hooked>,
    /// Its agent's `_drgnx/panel` extension: what it offers, its context breakdown.
    panel: panel::Panel,
    /// The projects' edit histories and the hub's state folder they live under: every write the hub serves for the
    /// agent is recorded there (none: the hub has no state folder).
    history: Option<(Arc<crate::history::wire::Hubs>, PathBuf)>,
    /// The hub's identities: this session holds one from its start until it ends ([`super::identity`]).
    identities: Arc<super::identity::Pool>,
}

/// What `Conn::prompt` answered for a turn.
struct TurnEnd(u64, Result<hermod::PromptOutcome, hermod::Error>);

/// Where a session's steps are written and announced.
#[derive(Clone)]
pub(crate) struct StepSink {
    pub writer: crate::coord::Writer,
    pub editors: Arc<crate::settings::agents::Editors>,
    pub bus: tokio::sync::broadcast::Sender<AgentStep>,
    /// Step snapshots (none: the hub has no state folder, or a test).
    pub snap: Option<crate::timeline::Snap>,
    /// The plan and project a plan run's session works under (none: not a plan run, or a test).
    pub scopes: Option<crate::runner::Scopes>,
    /// The graph store a spec an edit step wrote is stored in (none: a test).
    pub tools: Option<Arc<norn::tools::Coord>>,
    /// Where a spec it wrote is linked to the session's current ask (none: a test).
    pub asks: Option<crate::work::asks::AskTx>,
    /// The conclusions' stamps: a conclusion's tool step written, a turn ended (none: a test).
    pub stamps: Option<Arc<crate::work::conclusions::Stamps>>,
    /// The presence model: the files each step was in (none: a test).
    pub presence: Option<Arc<crate::work::presence::Live>>,
    /// The Work map: each closed step, and the presence it changed (none: a test).
    pub map: Option<Arc<crate::work::map::Map>>,
    /// The trace supervisor: a shell step's close takes what its command opened (none: a test).
    pub traces: Option<Arc<crate::work::trace::Traces>>,
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

/// How a launched agent gets its conversation: a new one, the recorded one again (`session/resume`, else
/// `session/load`), or a fork of SOURCE at AT expected to restore LEVEL (`session/fork` in this new process).
#[derive(Clone, Debug)]
pub(crate) enum Attach {
    New,
    Resume(String),
    #[cfg_attr(
        not(test),
        allow(dead_code, reason = "made by the rewind and the fork")
    )]
    Fork {
        source: String,
        at: Option<hermod::ForkPoint>,
        level: RestoreLevel,
    },
}

/// A launched agent with its handshake done.
struct Launched {
    conn: Conn,
    acp: SessionId,
    /// The level an attach by fork really restored: its own, or `Summary` when the agent cannot fork or the fork failed
    /// (a new conversation, LEVEL_WHY saying why).  None for a new or resumed conversation.
    level: Option<RestoreLevel>,
    level_why: Option<String>,
    caps: Option<Value>,
    enforced: bool,
    /// Whether the provider's lock holds (`lock::plan`'s verdict, whatever the sandbox).
    lock_held: bool,
    enforced_why: Option<String>,
    /// The token of the gateway registration this launch made (a gateway profile).
    gateway: Option<String>,
    /// Its provider proxy, bound before the spawn (and its browser's web proxy and CDP broker).
    net: Option<super::net::SessionNet>,
    browser_why: Option<String>,
    hooked: Option<runstav::methods::agents::Hooked>,
}

/// Where a path may be read or written: inside the session's directory; a brainstorm writes its document only, and a
/// chat in a project writes nothing (the hub serves `fs/write_text_file` outside the sandbox, which binds the project
/// read-only).  While the user holds the session's wheel it writes nothing at all.
pub(crate) struct Fence {
    pub cwd: PathBuf,
    pub document: Option<PathBuf>,
    pub read_only: bool,
    /// The user holds the wheel ([`Fence::held`]).
    pub held: bool,
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
    /// Whether the user holds SESSION's wheel (the turn the take stopped has ended): every write of it is refused,
    /// by this fence and by the pair door alike.
    pub(crate) fn held(session: &Session) -> bool {
        lock(&session.state).wheel == Wheel::Held
    }

    fn check(&self, path: &str, write: bool) -> Result<PathBuf, String> {
        let p = Path::new(path);
        if !p.is_absolute() {
            return Err(format!("{path}: not an absolute path"));
        }
        if write && self.held {
            return Err(format!("{path}: {}", wheel::HELD));
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
        if write && self.read_only {
            return Err(format!(
                "{path}: a chat reads its project and writes nothing in it"
            ));
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

/// Whether a session in ROLE (a BRAINSTORM, working in its SCRATCH folder) is a chat in a project, whose `fs/*` calls
/// in the project go to the pair door: every other session keeps the fence and the inline write.
fn is_project_chat(role: Role, brainstorm: bool, scratch: bool) -> bool {
    role == Role::Chat && !brainstorm && !scratch
}

/// An ACP `fs/*` request's `path`.
fn path_of(req: &Value) -> String {
    req.get("path")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

/// TEXT from the request's `line` (1-based), at most `limit` lines.
fn slice_lines(text: String, req: &Value) -> String {
    let line = req.get("line").and_then(Value::as_u64).unwrap_or(1).max(1) as usize;
    let limit = req.get("limit").and_then(Value::as_u64);
    if line == 1 && limit.is_none() {
        return text;
    }
    let it = text.split_inclusive('\n').skip(line - 1);
    match limit {
        Some(n) => it.take(n as usize).collect(),
        None => it.collect(),
    }
}

/// The answer to an `fs/read_text_file`: GOT's text, or its error.
fn answer_read(resp: hermod::Responder<ReadTextFileResponse>, got: Result<String, String>) {
    match got {
        Ok(content) => {
            if let Ok(r) =
                serde_json::from_value::<ReadTextFileResponse>(json!({"content": content}))
            {
                let _ = resp.respond(r);
            }
        }
        Err(m) => {
            let _ = resp.fail(-32602, &m);
        }
    }
}

pub(crate) fn find_profile(front: &Front, name: &str) -> Option<AgentProfile> {
    let cur = front.settings.current();
    let v = &cur.loaded.values;
    v.agents_profiles
        .iter()
        .chain(&crate::settings::defaults().profiles)
        .find(|p| p.name == name)
        .cloned()
}

/// A launch ready to spawn: the process, the sandbox helper's status pipe, and whether the lock is enforced.
pub(super) struct Prepared {
    pub(super) spec: draugr::Spec,
    pub(super) status: Option<std::os::fd::OwnedFd>,
    plan: plock::LaunchPlan,
    enforced: bool,
    enforced_why: Option<String>,
    gateway: Option<String>,
    /// How its shell steps' opens are seen (`work::trace`).
    trace: crate::work::trace::TraceMode,
    browser: BrowserLaunch,
    hooked: Option<runstav::methods::agents::Hooked>,
}

/// What a session's browser came to at its launch: the hub's side of it (the session has one), or why it has none
/// though its `browser` cell allows it (OD1 (b)).
#[derive(Default)]
pub(super) struct BrowserLaunch {
    hub: Option<super::net::BrowserHub>,
    why: Option<String>,
}

/// How PROFILE's sessions are traced: by its CLI's kind and `agents-trace-opens`; never on macOS (a test hub takes
/// `DRGNX_TEST_TRACE_PLATFORM=macos` as macOS).
fn trace_mode(front: &Front, profile: &AgentProfile) -> crate::work::trace::TraceMode {
    let provider = profile.provider().and_then(|p| {
        serde_json::to_value(p)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
    });
    let traced = front
        .settings
        .current()
        .loaded
        .values
        .agents_trace_opens
        .clone();
    #[cfg(feature = "test-hooks")]
    let macos = cfg!(target_os = "macos")
        || std::env::var("DRGNX_TEST_TRACE_PLATFORM").is_ok_and(|v| v == "macos");
    #[cfg(not(feature = "test-hooks"))]
    let macos = cfg!(target_os = "macos");
    crate::work::trace::TraceMode::of(provider.as_deref(), &traced, macos)
}

/// WHO a session is, for the matrix's columns.
fn who_of(role: Role, profile: &AgentProfile) -> Who {
    Who {
        role: Some(role),
        agent: Some(profile.name.clone()),
        provider: profile.ai.clone(),
    }
}

/// The provider a session's step rows name: the gateway's provider environment (`:ai`) when it has one, else whose
/// CLI it starts (`claude`, `codex`, `gemini`), so a subscription session's steps still say where they ran.
fn step_provider(profile: &AgentProfile) -> Option<String> {
    profile.ai.clone().or_else(|| {
        profile.provider().and_then(|p| {
            serde_json::to_value(p)
                .ok()
                .and_then(|v| v.as_str().map(str::to_owned))
        })
    })
}

/// The role of a session `agents/start` makes: the one asked for, else a worker on a task or job, else a chat.
fn start_role(asked: Option<Role>, task_or_job: bool) -> Role {
    asked.unwrap_or(if task_or_job {
        Role::Worker
    } else {
        Role::Chat
    })
}

/// A chat in a project (`launch::Kind::Chat`) has the project bound read-only: refused when the matrix's
/// `chat.project-read` is never for this session (its profile, its preset), rather than started without it.
fn project_read_allowed(kind: launch::Kind, eff: &norn::matrix::Effective) -> Result<(), Error> {
    if kind == launch::Kind::Chat
        && eff.cell(Action::ChatProjectRead).verdict == norn::matrix::Verdict::Never
    {
        return Err(refuse(
            "this chat may not read the project (chat.project-read is never): start it without a project",
        ));
    }
    Ok(())
}

/// What a launch is ready to spawn: the process, the helper's status pipe, why it is unsandboxed (a test launch),
/// and its browser.
type Spawn = (
    draugr::Spec,
    Option<std::os::fd::OwnedFd>,
    Option<&'static str>,
    BrowserLaunch,
);

/// The launch of a test session: the plan's command, unsandboxed, with a short allowlisted environment.  Only tests
/// and `test-hooks` builds have it (the mock agent lives outside any sandbox's reach); a shipped build always goes
/// through `launch::spawn` and Gleipnir.  It has no browser host: with `DRGNX_TEST_BROWSER` set and a `browser` cell
/// that is not Never, the hub's side of the browser starts anyway (the web proxy, the broker with the far end of its
/// socketpair held), so the rows reach it.
#[cfg(any(test, feature = "test-hooks"))]
#[allow(clippy::too_many_arguments)]
async fn spawn_spec(
    front: &Front,
    p: &AgentProfile,
    plan: &plock::LaunchPlan,
    _: &Path,
    cwd: &Path,
    sid: &str,
    _: Role,
    cell: norn::matrix::Verdict,
) -> Result<Spawn, Error> {
    let shell = &front.shell_env;
    let (prog, args) = plan
        .argv
        .split_first()
        .ok_or_else(|| invalid("profile", "the profile has no command"))?;
    // the lock's files where the sandbox would show them; Codex's /etc ones have no place outside a sandbox
    for (path, bytes) in plan.ro_files.iter().filter(|(p, _)| !p.starts_with("/etc")) {
        if let Some(d) = path.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        std::fs::write(path, bytes).map_err(|e| internal(format!("{}: {e}", path.display())))?;
    }
    let mut pairs: Vec<(String, std::ffi::OsString)> = p
        .env
        .iter()
        .filter_map(|e| e.split_once('='))
        .map(|(k, v)| (k.to_string(), v.into()))
        .collect();
    pairs.extend(plan.env.iter().map(|(k, v)| (k.clone(), v.into())));
    // per-step tracing without the sandbox: the wrapper is this binary by its name, linked in the session dir
    if plan.trace == Some(gleipnir::trace::Scope::Step) {
        let env = runstav::paths::Env::process();
        let run = runstav::paths::make_session_dir(&env, &runstav::paths::socket_path(&env), sid)
            .map_err(|e| internal(format!("session dir: {e}")))?;
        let link = run.join(gleipnir::trace::WRAPPER_NAME);
        let exe = std::env::current_exe().map_err(|e| internal(e.to_string()))?;
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(&exe, &link)
            .map_err(|e| internal(format!("{}: {e}", link.display())))?;
        pairs.push(("CLAUDE_CODE_SHELL_PREFIX".into(), link.into()));
        pairs.push((
            gleipnir::trace::SOCK_ENV.into(),
            run.join(runstav::paths::SESSION_TRACE_SOCKET).into(),
        ));
    }
    let set: Vec<(&str, &std::ffi::OsStr)> = pairs
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_os_str()))
        .collect();
    let env = shell.build(&["PATH", "HOME", "LANG", "TMPDIR"], &[], &set);
    let spec = draugr::Spec {
        program: PathBuf::from(prog),
        args: args.to_vec(),
        env,
        cwd: Some(cwd.to_path_buf()),
        stdin_null: false,
        pass_fds: Vec::new(),
        new_session: false,
    };
    let mut browser = BrowserLaunch::default();
    if cell != norn::matrix::Verdict::Never && std::env::var_os("DRGNX_TEST_BROWSER").is_some() {
        let (hub, far) = std::os::unix::net::UnixStream::pair()
            .map_err(|e| internal(format!("the browser's socketpair: {e}")))?;
        let secret = crate::browser::Secret::new()
            .map_err(|e| internal(format!("the browser's secret: {e}")))?;
        browser.hub = Some(super::net::BrowserHub {
            hub,
            secret,
            unit: None,
            held: Some(far),
        });
    }
    Ok((spec, None, Some("a test launch: unsandboxed"), browser))
}

/// The sandboxed launch (`launch::kind`): a worktree session writes its worktree only; a chat in its own scratch
/// directory (`launch::scratch_dir`) is the plain one; a chat in a project reads the project and writes its scratch
/// directory only.  The network is the provider's alone: `Open` is never granted here.  With the browser
/// ([`browser_shape`]) the launch holds the hub's end of its socketpair, and where a user systemd answers, the
/// sandbox runs in a scope of its own with the session's memory cap (`exec::unit::session_scope`).
#[cfg(not(any(test, feature = "test-hooks")))]
#[allow(clippy::too_many_arguments)]
async fn spawn_spec(
    front: &Front,
    _: &AgentProfile,
    plan: &plock::LaunchPlan,
    scratch: &Path,
    cwd: &Path,
    sid: &str,
    role: Role,
    cell: norn::matrix::Verdict,
) -> Result<Spawn, Error> {
    let env = front.shell_env.paths_env();
    let (shape, why) = browser_shape(front, cell).await;
    let secret = shape.as_ref().map(|s| s.secret.clone());
    let launched = match launch::kind(role, cwd, scratch) {
        launch::Kind::Plain => launch::spawn_plain(&env, plan, sid, shape).await,
        launch::Kind::Chat => launch::spawn_chat(&env, plan, sid, cwd, shape).await,
        launch::Kind::Worktree => {
            launch::spawn(
                &env,
                plan,
                &launch::SandboxReq {
                    sid: sid.to_string(),
                    worktree: cwd.to_path_buf(),
                    read: Vec::new(),
                    net: SESSION_NET,
                    role,
                },
                shape,
            )
            .await
        }
    }
    .map_err(|r| refuse(&format!("the sandbox refused the launch: {}", r.message)))?;
    let mut spec = launched.spec;
    let mut browser = BrowserLaunch { hub: None, why };
    if let (Some(hub), Some(secret)) = (launched.browser, secret) {
        let unit =
            crate::exec::unit::systemd_user().then(|| crate::exec::unit::session_unit_name(sid));
        if unit.is_some() {
            let memory = front
                .settings
                .current()
                .loaded
                .values
                .agents_session_memory
                .clone();
            spec = crate::exec::unit::session_scope(spec, sid, &memory);
        }
        browser.hub = Some(super::net::BrowserHub {
            hub,
            secret,
            unit,
            held: None,
        });
    }
    Ok((spec, launched.status, None, browser))
}

/// The browser a sandboxed session gets under its `browser` cell CELL (`sandbox::browser_for`): the sandbox the
/// launch takes, the kernel's Landlock ABI, the program `browser::resolve` finds (read on a blocking thread: the
/// setting's program is asked its version), the local ports, the message cap and a fresh secret.  Otherwise none, and
/// for a cell that allows it, why (with the hub's notice, once per reason per hub run).
#[cfg(not(any(test, feature = "test-hooks")))]
async fn browser_shape(
    front: &Front,
    cell: norn::matrix::Verdict,
) -> (Option<crate::sandbox::BrowserShape>, Option<String>) {
    if cell == norn::matrix::Verdict::Never {
        return (None, None);
    }
    let backend = launch::detect().await.ok().map(|s| s.kind());
    let cur = front.settings.current();
    let data = runstav::paths::data_dir(&runstav::paths::Env::process());
    let looked = cur.clone();
    let found = crate::clock::blocking(move || {
        crate::browser::resolve::resolve(&looked.loaded.values, &data)
    })
    .await
    .unwrap_or_else(|e| {
        Err(crate::browser::resolve::NotFound {
            fix: format!("the browser lookup failed: {e}"),
        })
    });
    let secret = match crate::browser::Secret::new() {
        Ok(s) => s,
        Err(e) => {
            return (
                None,
                Some(format!("no random bytes for the CDP secret: {e}")),
            );
        }
    };
    let v = &cur.loaded.values;
    match crate::sandbox::browser_for(
        cell,
        backend,
        gleipnir::landlock::kernel_abi(),
        found,
        v.agents_browser_local_ports.clone(),
        v.agents_browser_max_message,
        secret,
    ) {
        Ok(shape) => (shape, None),
        Err(n) => {
            super::net::no_browser_notice(front, &n);
            (None, Some(format!("{}; fix: {}", n.why, n.fix)))
        }
    }
}

/// The variables an editor module asked to add to a new session's environment (`agents/start`'s `env`).  A name must be
/// on `drgnx-agents-start-env-names` and must not look like a credential or be a provider's key variable, whatever
/// that setting lists.  The browser's endpoint names (`browser::ENDPOINT_ENV`) are the hub's alone: an editor's value
/// is dropped for every session (the log names the name, never the value).
fn module_env(front: &Front, env: Option<&[EnvVar]>) -> Result<Vec<(String, String)>, Error> {
    let Some(env) = env.filter(|e| !e.is_empty()) else {
        return Ok(Vec::new());
    };
    let current = front.settings.current();
    let allowed = &current.loaded.values.agents_start_env_names;
    let key_envs = front.provider_key_envs();
    let mut out = Vec::with_capacity(env.len());
    for (i, var) in env.iter().enumerate() {
        let name = var.name.as_str();
        if crate::browser::ENDPOINT_ENV.contains(&name) {
            tracing::info!(
                name,
                "an editor's value for {name} is dropped: the hub sets it"
            );
            continue;
        }
        if refused_env_name(name) || key_envs.iter().any(|k| k == name) {
            return Err(invalid(
                &format!("env[{i}].name"),
                format!("{name} looks like a credential and is never passed on"),
            ));
        }
        if !allowed.iter().any(|a| a == name) {
            return Err(invalid(
                &format!("env[{i}].name"),
                format!("{name} is not on drgnx-agents-start-env-names"),
            ));
        }
        if var.value.contains('\0') {
            return Err(invalid(
                &format!("env[{i}].value"),
                "a value cannot hold a NUL",
            ));
        }
        out.push((name.to_string(), var.value.as_str().to_string()));
    }
    Ok(out)
}

/// The module env session SID was started with, from its notes META, as the settings allow it now: a name taken off
/// `drgnx-agents-start-env-names` since, or one that is now a provider's key variable, is left out (and logged).
fn kept_env(front: &Front, sid: &str, meta: &Value) -> Vec<(String, String)> {
    let vars: Vec<EnvVar> = meta
        .get("env")
        .cloned()
        .and_then(|v| serde_json::from_value(v).ok())
        .unwrap_or_default();
    vars.iter()
        .filter_map(
            |var| match module_env(front, Some(std::slice::from_ref(var))) {
                Ok(mut one) => one.pop(),
                Err(e) => {
                    tracing::warn!(
                        sid,
                        "a kept module variable is not passed on: {}",
                        e.message
                    );
                    None
                }
            },
        )
        .collect()
}

/// Everything before the process: the matrix's cells, the provider's lock plan, the refusal of a lock that is not
/// enforced for a worker or a manager under any preset but the autonomous one, and the spawn spec.
pub(super) async fn prepare(
    front: &Front,
    profile: &AgentProfile,
    role: Role,
    sid: &str,
    cwd: &Path,
    job: Option<&str>,
    module_env: &[(String, String)],
) -> Result<Prepared, Error> {
    // while replaying a run, the agent is the ACP replayer of the recording (the rest of the launch is as live)
    let replayed = crate::recording::replayed_profile(profile);
    let profile = replayed.as_ref().unwrap_or(profile);
    // a gateway profile's agent reaches its provider only through the hub's gateway, with a token of its own
    let (profile, gateway, relayed) = match gateway_env(front, profile, role, sid, job).await? {
        Some((env, token, relayed)) => {
            let mut p = profile.clone();
            p.env.extend(env);
            (p, Some(token), relayed)
        }
        None => (profile.clone(), None, false),
    };
    let profile = &profile;
    let who = who_of(role, profile);
    let eff = front
        .core
        .matrix
        .effective_now(
            &front.settings,
            &front.writer,
            who,
            ActionCtx::of_session(&front.core.runs.scopes(), sid),
        )
        .await
        .map_err(|e| internal(format!("the matrix: {e:?}")))?;
    let mut plan = plock::plan(profile, role, &eff);
    if profile.provider() == Some(crate::settings::profiles::Provider::Claude)
        && let Some(home) = std::env::var_os("HOME").filter(|h| !h.is_empty())
    {
        let (deny, ask) = plock::claude_deny_ask(&PathBuf::from(home).join(".claude"), cwd);
        plan = plan.with_claude_rules(deny, ask);
    }
    // the kinds the before-tool hooks and rules of its plugin set at launch subscribe to: the lock makes the agent
    // ask about them, so they reach the seam; a fork's lock `_meta` is its parent's
    let project = session_project(front, sid, cwd).await;
    let kinds = crate::hook_points::subscribed_kinds(&front.core.plugins, project.as_deref());
    let env = runstav::paths::Env::process();
    let run = runstav::paths::make_session_dir(&env, &runstav::paths::socket_path(&env), sid)
        .map_err(|e| internal(format!("session dir: {e}")))?;
    plan = plan
        .with_hook_asks(&kinds)
        .with_locks(profile, &kinds, &plock::LockAt::new(cwd, &run))
        .with_gateway_env(profile);
    plan.make_home()
        .map_err(|e| internal(format!("{}'s home: {e}", profile.name)))?;
    let hooked = plock::hooked(profile, &kinds, &plan);
    // a subscribed kind the agent would run unhooked: never started, whatever the role or preset
    if let Some(why) = plock::unhooked_refusal(profile, hooked.as_ref()) {
        return Err(refuse(&why));
    }
    if gateway.is_some() {
        // the process gets the same variables the Claude options carry
        let extra: Vec<(String, String)> = profile
            .env
            .iter()
            .filter(|e| e.starts_with("ANTHROPIC_"))
            .filter_map(|e| {
                e.split_once('=')
                    .map(|(k, v)| (k.to_string(), v.to_string()))
            })
            .collect();
        plan.env.extend(extra);
    }
    // the spec relays a port to the session's gateway.sock and points ANTHROPIC_BASE_URL at it
    plan.gateway = relayed;
    // and gives it the trace supervisor's socket when its shell steps' opens are seen
    let trace = trace_mode(front, profile);
    plan.trace = trace.scope();
    // what an editor module added comes last, so it wins over the profile's and the lock's
    plan.env.extend(module_env.iter().cloned());
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
    project_read_allowed(launch::kind(role, cwd, &scratch), &eff)?;
    if launch::kind(role, cwd, &scratch) == launch::Kind::Chat {
        // its edits of the checkout go through the pair door only: Claude's own edit tools are off from the start
        plan = plan.with_project_chat();
        // paired from the start when the cell allows it; the user's toggle decides under an ask
        front.pair.started(
            sid,
            norn::matrix::decide(&eff, Action::ChatProjectEdit, None),
        );
    }
    // the `browser` cell decides whether the session gets the browser (Allow or Ask: at first use, the broker asks)
    let cell = eff.cell(Action::Browser).verdict;
    let (spec, status, unsandboxed, browser) =
        spawn_spec(front, profile, &plan, &scratch, cwd, sid, role, cell).await?;
    Ok(Prepared {
        spec,
        status,
        enforced: why.is_none() && unsandboxed.is_none(),
        enforced_why: unsandboxed.or(why).map(str::to_string),
        plan,
        gateway,
        trace,
        browser,
        hooked,
    })
}

/// Session SID's Urdr project: its plan's when a plan runs it, else the repository of CWD (`None` outside one). Runs
/// git, off the hub's workers.
async fn session_project(front: &Front, sid: &str, cwd: &Path) -> Option<String> {
    if let Some(p) = ActionCtx::of_session(&front.core.runs.scopes(), sid).project {
        return Some(p);
    }
    let cwd = cwd.to_path_buf();
    crate::clock::blocking(move || norn::project::resolve(&cwd).map(|r| r.id))
        .await
        .ok()
        .flatten()
}

/// The chain of a gateway profile kind (`drgnx-ai-agent-gateway-chain`): its provider, with the profile's model;
/// `claude-openrouter` without a model follows the `agent` role; `kimi-moonshot` and `dsh-deepseek` (Kimi Code's and
/// DeepSeek Harness's own agents) go to Moonshot and DeepSeek.
pub(crate) fn gateway_chain(front: &Front, p: &AgentProfile) -> Vec<(String, Option<String>)> {
    let kind = p.ai.as_deref().unwrap_or_default();
    let one = |id: &str, m: Option<String>| vec![(id.to_string(), m)];
    match kind {
        "claude-openrouter" if p.model.is_none() => {
            let cur = front.settings.current();
            let roles = &cur.loaded.values.ai_roles;
            let defaults = &crate::settings::defaults().roles;
            roles
                .iter()
                .chain(defaults.iter())
                .find(|r| r.role == "agent")
                .map(|r| {
                    r.chain
                        .iter()
                        .map(|s| (s.provider.clone(), s.model.clone()))
                        .collect()
                })
                .unwrap_or_else(|| one("openrouter", None))
        }
        "claude-openrouter" => one("openrouter", p.model.clone()),
        "claude-ollama" => one("ollama", None),
        "claude-anthropic" => one("anthropic", None),
        // Kimi Code and DeepSeek Harness on their vendors' Messages APIs; the retired Claude kinds still run
        "kimi-moonshot" | "claude-moonshot" => one("moonshot", p.model.clone()),
        "dsh-deepseek" | "claude-deepseek" => one("deepseek", p.model.clone()),
        _ => Vec::new(),
    }
}

/// Whether a session's launch is sandboxed: always in a shipped build; a test build's launch is the unsandboxed
/// test one (the test `spawn_spec`), which reaches the gateway on its loopback port.
const SANDBOXED_LAUNCH: bool = cfg!(not(any(test, feature = "test-hooks")));

/// A gateway profile's environment and its token, registered for this session (booked under JOB, else the session
/// id), never a key; and whether the token is good on the session's `gateway.sock` (a sandboxed launch: the spec
/// relays a port to it and sets `ANTHROPIC_BASE_URL` there, `LaunchPlan::gateway`) rather than on the loopback
/// port (the URL is in the environment then).  None for a profile with no gateway.
async fn gateway_env(
    front: &Front,
    profile: &AgentProfile,
    role: Role,
    sid: &str,
    job: Option<&str>,
) -> Result<Option<(Vec<String>, String, bool)>, Error> {
    if profile.ai.is_none() {
        return Ok(None);
    }
    let chain = gateway_chain(front, profile);
    if chain.is_empty() {
        return Ok(None);
    }
    let scope = scope_of(role, sid);
    let r = front
        .gate
        .register_session(
            chain,
            job.unwrap_or(sid),
            &profile.name,
            &scope,
            &front.mcp,
            SANDBOXED_LAUNCH.then_some(sid),
        )
        .await?;
    let mut env = Vec::new();
    let relayed = match (&r.url, &r.socket) {
        (_, Some(_)) => true,
        (Some(url), None) => {
            env.push(format!("ANTHROPIC_BASE_URL={url}"));
            false
        }
        (None, None) => return Err(internal("the gateway gave neither a URL nor a socket")),
    };
    env.extend([
        format!("ANTHROPIC_AUTH_TOKEN={}", r.token),
        "ANTHROPIC_API_KEY=".to_string(),
    ]);
    if let Some(m) = &profile.model {
        env.extend(
            [
                "ANTHROPIC_MODEL",
                "ANTHROPIC_DEFAULT_SONNET_MODEL",
                "ANTHROPIC_DEFAULT_OPUS_MODEL",
                "CLAUDE_CODE_SUBAGENT_MODEL",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            ]
            .map(|n| format!("{n}={m}")),
        );
    }
    Ok(Some((env, r.token, relayed)))
}

/// The budget scope of a session.
pub(crate) fn scope_of(role: Role, sid: &str) -> runstav::methods::timeline::BudgetScope {
    use runstav::methods::timeline::BudgetScope;
    let id = runstav::types::Id::new(sid).expect("a session id is an id");
    if role == Role::Manager {
        BudgetScope::Manager(id)
    } else {
        BudgetScope::Worker(id)
    }
}

pub(crate) async fn open(
    hub: &super::Hub,
    front: &Front,
    p: StartParams,
    caller: &Caller,
) -> Result<Started, Error> {
    open_as(hub, front, p, caller, None, None).await
}

/// A new session id.
pub(crate) fn new_sid() -> Result<String, Error> {
    Ok(format!(
        "a{}",
        &runstav::proof::nonce().map_err(|e| internal(format!("no session id: {e}")))?[..12]
    ))
}

/// [`open`] for a worker a manager started (Task 25): PARENT is the manager's session id, so the worker's budget comes
/// out of the manager's; SID, when given, is the id the caller made (and recorded the worker's delegation under) first.
pub(crate) async fn open_as(
    hub: &super::Hub,
    front: &Front,
    p: StartParams,
    caller: &Caller,
    parent: Option<String>,
    sid: Option<String>,
) -> Result<Started, Error> {
    open_with(hub, front, p, caller, parent, sid, &Attach::New)
        .await
        .map(|(started, _)| started)
}

/// [`open_as`] on the conversation ATTACH names (a fork from a step): the session, and the level a fork landed at.
pub(crate) async fn open_with(
    hub: &super::Hub,
    front: &Front,
    p: StartParams,
    caller: &Caller,
    parent: Option<String>,
    sid: Option<String>,
    attach: &Attach,
) -> Result<(Started, Option<RestoreLevel>), Error> {
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
    let module_env = module_env(front, p.env.as_deref().map(Vec::as_slice))?;
    let sid = match sid {
        Some(s) => s,
        None => new_sid()?,
    };
    let name = format!("{}-{}", profile.name, &sid[1..5]);
    let role = start_role(p.role, p.task.is_some() || p.job.is_some());
    let cwd = match &p.cwd {
        Some(c) => PathBuf::from(c.as_str()),
        None => launch::scratch_dir(&runstav::paths::Env::process(), &sid)
            .map_err(|r| internal(format!("scratch directory: {}", r.message)))?,
    };
    // a session on a task acts under the task's plan and project (the matrix's layers) from its first step
    if let Some(t) = &p.task
        && front.core.runs.scope_of(&sid).is_none()
        && let Some((plan, project)) = crate::brief::task_scope(front, t.as_str()).await
    {
        front.core.runs.set_scope(&sid, plan, project);
    }
    let (l, rx) = launch(
        front,
        &profile,
        role,
        &sid,
        &cwd,
        attach,
        (
            p.task.as_ref().map(|t| t.as_str()),
            p.job.as_ref().map(|j| j.as_str()),
            &module_env,
        ),
    )
    .await?;
    let ident = Ident {
        id: sid.clone(),
        name: name.clone(),
        started: now(),
        role,
        cwd,
        task: p.task.as_ref().map(|t| t.as_str().to_string()),
        job: p.job.as_ref().map(|j| j.as_str().to_string()),
        parent,
        about: p.about.as_ref().map(|a| a.to_string()),
        document: p.document.as_ref().map(|d| PathBuf::from(d.as_str())),
    };
    let level = l.level;
    let (s, done) = assemble(ident, &profile, l, front, hub.step_bus());
    if let Some(store) = &s.store {
        // the module env too: a restart or resume of the session passes it again (`kept_env`)
        let env: Vec<Value> = module_env
            .iter()
            .map(|(name, value)| json!({"name": name, "value": value}))
            .collect();
        store.save_meta(
            &s.id,
            &json!({"about": s.about, "document": s.document, "env": env}),
        );
    }
    lock(&s.state).core.ready(false);
    hub.insert(s.clone());
    tokio::spawn(s.clone().run(rx, done));
    if let Some(db) = hub.db() {
        insert_row(db, &s).await;
    }
    record_entities(front, caller, &s).await;
    // its starter's ask is its own: the manager that started it, or the session that made its plan run
    s.asks.started(&s.id, s.parent.as_deref(), s.job.as_deref());
    s.changed();
    Ok((Started { id: sid, name }, level))
}

/// The `mcpServers` entry that gives the session SID the coordination tools (`job_start` among them): Ratatoskr's
/// `mcp-bridge` to the session's own socket, minted here (or the one a closed session left).  None when the hub has no
/// store yet (the unit tests): the session then has no tools.
async fn bridge(
    front: &Front,
    profile: &AgentProfile,
    who: Who,
    sid: &str,
    cwd: &Path,
    task: Option<&str>,
    job: Option<&str>,
) -> Vec<hermod::McpServer> {
    let socket = match front.mcp.socket_of(sid) {
        Some(path) => path,
        None => {
            // the columns its abilities run as, before the session opens (a `plugins.sock` is bound with it)
            front.mcp.note_who(sid, who);
            // the tools act as the session id: the id a plan run claims its task for (`runner::tick::start`)
            let params = serde_json::from_value(json!({
                "agent": sid,
                "sid": sid,
                "cwd": cwd,
                "owner": std::process::id(),
                "profile": profile.name,
                "task": task,
                "job": job,
            }));
            let Ok(params) = params else {
                return Vec::new();
            };
            match front.mcp.open(params).await {
                Ok(a) => PathBuf::from(a.socket),
                Err(e) => {
                    tracing::warn!(sid, "no coordination tools for the session: {}", e.message);
                    return Vec::new();
                }
            }
        }
    };
    let env = runstav::paths::Env::process();
    let installed = runstav::paths::data_dir(&env).join("bin").join("ratatoskr");
    let command = if installed.exists() {
        installed
    } else {
        std::env::current_exe().unwrap_or(installed)
    };
    // the search tool too, when `drgnx-agents-mcp` holds `search` (the session's `search.sock`, pinned to its folder)
    let mut servers = vec![("drgnx", socket)];
    if let Some(search) = front.mcp.search_socket_of(sid) {
        servers.push(("drgnx-search", search));
    }
    // the plugins' abilities, a server of their own: only for a session that starts with an enabled ability
    // (`mcpServers` are fixed at `session/new`)
    if let Some(plugins) = front.mcp.plugins_socket_of(sid) {
        servers.push(("drgnx-plugins", plugins));
    }
    servers
        .into_iter()
        .filter_map(|(name, socket)| {
            serde_json::from_value(json!({
                "name": name,
                "command": command,
                "args": ["mcp-bridge", "--socket", socket],
                "env": [],
            }))
            .ok()
        })
        .collect()
}

/// PROFILE's agent in CWD: started in its sandbox, initialized, on a conversation ATTACH names (a new one; the
/// recorded one by `session/resume`, else `session/load` when the agent can only load; or a fork, which falls back to a
/// new conversation at Summary level when the agent cannot fork or the fork fails) and its lock verified, after a fork
/// as after `session/new`: a lock that does not hold kills the session.
async fn launch(
    front: &Front,
    profile: &AgentProfile,
    role: Role,
    sid: &str,
    cwd: &Path,
    attach: &Attach,
    (task, job, module_env): (Option<&str>, Option<&str>, &[(String, String)]),
) -> Result<(Launched, tokio::sync::mpsc::Receiver<Event>), Error> {
    // the session's MCP session first: a sandboxed gateway profile's token is registered on its gateway.sock, which
    // needs it.  A launch refused before the spawn closes the one it opened (its socket and dir go with it)
    let opened = front.mcp.socket_of(sid).is_none();
    // a Codex session whose hooks subscribe to a kind: its socket serves `before_tool`, which its lock's managed hook
    // calls
    if opened && profile.provider() == Some(crate::settings::profiles::Provider::Codex) {
        let project = session_project(front, sid, cwd).await;
        if crate::hook_points::subscribed_kinds(&front.core.plugins, project.as_deref())
            .iter()
            .any(|k| k != "drgnx")
        {
            front.mcp.mark_before_tool(sid);
        }
    }
    // a chat in a project gets the pair tools from its start (read_file, edit_file, write_file), paired or not
    let scratch = launch::scratch_path(&runstav::paths::Env::process(), sid);
    if launch::kind(role, cwd, &scratch) == launch::Kind::Chat {
        front.mcp.mark_project_chat(sid);
    }
    let mcp = bridge(front, profile, who_of(role, profile), sid, cwd, task, job).await;
    let prep = match prepare(front, profile, role, sid, cwd, job, module_env).await {
        Ok(p) => p,
        Err(e) => {
            if opened && !mcp.is_empty() {
                let _ = front.mcp.close(sid).await;
            }
            return Err(e);
        }
    };
    // the provider proxy the spec's relay reaches, bound before the spawn; a start that fails below drops it, and its
    // socket with it.  So are the browser's web proxy and CDP broker, for a session with the browser
    let mut net = super::net::start_session(front, profile, sid, SESSION_NET)
        .map_err(|e| internal(format!("the session's provider proxy: {e}")))?;
    let with_browser = prep.browser.hub.is_some();
    if let Some(hub) = prep.browser.hub {
        let n = net
            .as_mut()
            .ok_or_else(|| internal("a session with the browser needs its network"))?;
        super::net::start_browser(front, n, sid, who_of(role, profile), hub)
            .await
            .map_err(|e| internal(format!("the session's browser: {e}")))?;
    }
    // the trace supervisor's socket, served before the spawn too (a traced session); an untraced one labels its steps
    let env = runstav::paths::Env::process();
    let run = runstav::paths::make_session_dir(&env, &runstav::paths::socket_path(&env), sid)
        .map_err(|e| internal(format!("session dir: {e}")))?;
    front
        .core
        .traces
        .open(front, sid, cwd, &run, prep.trace.clone())
        .map_err(|e| internal(format!("the session's trace socket: {e}")))?;
    // while recording, the connection's lines, MCP calls and worktree changes go into the run (in spawn order)
    let opts = ConnOpts {
        tap: crate::recording::acp_tap(sid, job, &profile.name, &prep.spec, cwd),
        ..ConnOpts::default()
    };
    let (conn, rx) = Conn::spawn(prep.spec, opts)
        .await
        .map_err(|e| internal(e.to_string()))?;
    let kill = || draugr::kill_group(conn.pid(), Duration::ZERO, &draugr::RealSignaller);
    // The sandbox helper reports on a pipe; a launch whose status is not read hangs (Task 10).  A start that fails
    // before the helper speaks says why on stderr (bwrap's own message).  With the browser, the line must say its
    // host is layered and ready.
    if let Some(fd) = prep.status {
        let stderr = conn.stderr();
        let read = crate::clock::blocking(move || {
            gleipnir::inner::read_status_for(
                fd,
                &|| stderr.get(),
                Duration::from_secs(20),
                with_browser,
            )
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
            serde_json::from_value(json!({"fs": {"readTextFile": true, "writeTextFile": true},
                                                 "_meta": panel::client_meta()}))
            .map_err(|e| hermod::Error::Decode(e.to_string()))?;
        let info = conn.initialize(caps).await?;
        let caps = serde_json::to_value(&info.caps).ok();
        let mut landed = (None, None);
        let acp = match attach {
            Attach::New => conn.new_session(cwd, mcp.clone(), meta).await?,
            Attach::Fork { source, at, level } => {
                let fork = if super::rewind::can_fork(caps.as_ref()) {
                    conn.fork_into(hermod::ForkInto {
                        source: SessionId::new(source.clone()),
                        cwd: cwd.to_path_buf(),
                        mcp: mcp.clone(),
                        at: at.clone(),
                        meta: meta.clone(),
                    })
                    .await
                    .map_err(|e| format!("the fork failed: {e}"))
                } else {
                    Err("the agent cannot fork a session".to_string())
                };
                match fork {
                    Ok(id) => {
                        landed = (Some(*level), None);
                        id
                    }
                    Err(why) => {
                        tracing::warn!(sid, "{why}: a new conversation, restored by a summary");
                        landed = (Some(RestoreLevel::Summary), Some(why));
                        conn.new_session(cwd, mcp.clone(), meta).await?
                    }
                }
            }
            Attach::Resume(id) => {
                let sid = SessionId::new(id.to_string());
                let can = |p: &str| {
                    caps.as_ref()
                        .and_then(|c| c.pointer(p))
                        .is_some_and(|v| !v.is_null() && *v != json!(false))
                };
                if can("/sessionCapabilities/resume") {
                    conn.resume_session(&sid, cwd, mcp.clone(), meta.clone())
                        .await?;
                } else if can("/loadSession") {
                    conn.load_session(&sid, cwd, mcp.clone(), meta.clone())
                        .await?;
                } else {
                    return Err(hermod::Error::Decode(
                        "the agent can neither resume nor load a session".into(),
                    ));
                }
                sid
            }
        };
        Ok::<_, hermod::Error>((caps, acp, landed))
    };
    let (capabilities, acp, (level, level_why)) = match init.await {
        Ok(x) => x,
        Err(e) => {
            kill().await;
            // an agent that never answered (its program not found inside the sandbox, a crash) says why on stderr
            let last = conn.stderr().get();
            let why = last
                .lines()
                .map(str::trim)
                .rfind(|l| !l.is_empty())
                .map(|l| format!(" ({})", super::transcript::redact(l)))
                .unwrap_or_default();
            return Err(internal(format!("{}: {e}{why}", profile.name)));
        }
    };
    if let Err(e) = plock::verify(&conn, &acp, profile, &prep.plan, capabilities.as_ref()).await {
        kill().await;
        return Err(refuse(&format!("{}: {e}", profile.name)));
    }
    Ok((
        Launched {
            conn,
            acp,
            level,
            level_why,
            caps: capabilities,
            enforced: prep.enforced,
            lock_held: prep.plan.enforced == plock::Enforced::Yes,
            enforced_why: prep.enforced_why,
            gateway: prep.gateway,
            net,
            browser_why: prep.browser.why,
            hooked: prep.hooked,
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
    if let Some(level) = l.level {
        tracing::info!(
            sid = i.id,
            ?level,
            why = l.level_why.as_deref(),
            "attached by fork"
        );
    }
    let (done, done_rx) = tokio::sync::mpsc::unbounded_channel();
    let (steps, rx) = tokio::sync::mpsc::unbounded_channel();
    let flow = Arc::new(StepFlow::default());
    let ctx = StepCtx {
        flow: flow.clone(),
        session: i.id.clone(),
        task: i.task.clone(),
        agent: profile.name.clone(),
        provider: step_provider(profile),
        cwd: i.cwd.clone(),
        acp: Some(l.acp.0.to_string()),
        history: front
            .dirs
            .get()
            .map(|d| (front.core.history.clone(), d.hub.clone())),
    };
    tokio::spawn(write_steps(
        rx,
        StepSink {
            writer: front.writer.clone(),
            editors: front.editors.clone(),
            bus,
            snap: crate::timeline::Snap::of(front),
            scopes: Some(front.core.runs.scopes()),
            tools: Some(front.tools.clone()),
            asks: Some(front.core.asks.handle()),
            stamps: Some(front.core.stamps.clone()),
            presence: Some(front.core.presence.clone()),
            map: Some(front.core.map.clone()),
            traces: Some(front.core.traces.clone()),
        },
        ctx,
    ));
    // a folder the hub made no tree for is measured from its head now (a docs agent in the org folder)
    if let Some(d) = front.dirs.get() {
        crate::clock::spawn(
            "session:bases",
            crate::work::bases::session_started(
                front.writer.clone(),
                d.hub.clone(),
                i.id.clone(),
                i.cwd.clone(),
            ),
        );
    }
    // its identity: the lowest free ordinal of its workspace, and a handle unique there
    let identities = front.core.agents.identities.clone();
    let provider = profile.provider().and_then(|p| {
        serde_json::to_value(p)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
    });
    identities.take(
        &super::identity::workspace_of(&i.cwd),
        &i.id,
        &super::identity::model_short(profile.model.as_deref(), provider.as_deref()),
    );
    let scope = scope_of(i.role, &i.id);
    front.core.budgets.enroll(&scope);
    if let Some(m) = &i.parent {
        front.core.budgets.link(&scope, &scope_of(Role::Manager, m));
    }
    let plugins_changed = front.mcp.plugins_flag(&i.id);
    let panel = panel::Panel::new(l.caps.as_ref());
    let hooked = l.hooked;
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
        locked_as: profile.provider(),
        lock_held: l.lock_held,
        enforced_why: l.enforced_why,
        browser_why: l.browser_why,
        plugins_changed,
        capabilities: l.caps,
        conn: l.conn,
        acp: l.acp,
        editors: front.editors.clone(),
        pair: front.pair.clone(),
        map: front.core.map.clone(),
        presence: front.core.presence.clone(),
        follows: front.follows.clone(),
        gate: front.core.matrix.clone(),
        settings: front.settings.clone(),
        writer: front.writer.clone(),
        scopes: front.core.runs.scopes(),
        budgets: front.core.budgets.clone(),
        gateway: Mutex::new(l.gateway.clone()),
        net: Mutex::new(l.net),
        next_request: AtomicU64::new(1),
        live: front.core.exec.live(),
        wait_refusals: AtomicU32::new(0),
        closed: AtomicBool::new(false),
        gated: AtomicU64::new(0),
        state: Mutex::new(State::new()),
        store: front.dirs.get().map(|d| transcript::Store::new(&d.hub)),
        snap: crate::timeline::Snap::of(front),
        steps,
        flow,
        done,
        asks: front.core.asks.handle(),
        stamps: front.core.stamps.clone(),
        say: front.core.say.handle(),
        tool_hub: front.tool_hub.clone(),
        project: std::sync::OnceLock::new(),
        hooked,
        panel,
        history: front
            .dirs
            .get()
            .map(|d| (front.core.history.clone(), d.hub.clone())),
        identities,
    });
    (s, done_rx)
}

/// The rows `asession` kept, as sessions again after a restart (`session/resume`, else `session/load`): the
/// transcript read back, the held queue restored and its first prompt delivered.  A session whose profile is gone,
/// or whose agent will not resume, stays in the table for the next start.
pub(crate) async fn resume_all(hub: &super::Hub, front: &Front) {
    for row in read_rows(hub, None).await {
        if hub.find(&row.0).is_ok() {
            continue;
        }
        if row.3 == "manager" && restart_manager_from_graph(hub, front, &row).await {
            continue;
        }
        resume_row(hub, front, row).await;
    }
}

/// A recorded session: sid, name, profile, role, cwd, task, job, acp id, parent, started.
pub(crate) type Row = (
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

/// The recorded sessions (only ONLY when given), oldest first.
pub(crate) async fn read_rows(hub: &super::Hub, only: Option<&str>) -> Vec<Row> {
    let Some(db) = hub.db() else {
        return Vec::new();
    };
    let only = only.map(str::to_string);
    match db
        .read(move |c| {
            let mut q = c.prepare(
                "select sid, name, profile, role, cwd, task, job, acp, parent, at from asession order by at",
            )?;
            let it = q.query_map([], |r| {
                Ok((
                    r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?, r.get(8)?, r.get(9)?,
                ))
            })?;
            let all = it.collect::<Result<Vec<Row>, _>>()?;
            Ok(all
                .into_iter()
                .filter(|r| only.as_deref().is_none_or(|o| r.0 == o))
                .collect::<Vec<_>>())
        })
        .await
    {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("cannot read the recorded sessions: {e}");
            Vec::new()
        }
    }
}

/// What a session that could be neither resumed nor loaded is told (it is a new session on the same transcript).
const RESTART_NOTICE: &str = "[the hub restarted and your earlier conversation could not be restored: you are a new session in the same directory; the earlier transcript is kept. Check the task and the repository before you go on.]";

/// A manager restarted from the graph (Task 25): a new agent session in the same hub session, told its digest and open
/// decisions read back from Urdr instead of its conversation.  False (no profile, no launch): it resumes like any
/// session.
async fn restart_manager_from_graph(hub: &super::Hub, front: &Front, row: &Row) -> bool {
    front.mcp.mark_manager(&row.0);
    let first = crate::manager::restart_prompt(front, &row.0).await;
    // an open socket from before has the plain tool list
    let _ = front.mcp.close(&row.0).await;
    resume_row_with(hub, front, row.clone(), Some(first)).await
}

/// Manager SID closed and started afresh with FIRST (its digest and open decisions): the rotation past
/// `agents-manager-context` and the restart of a manager made one.  The hub session, its row, workers and budget stay.
pub(crate) async fn rotate(hub: &super::Hub, front: &Front, sid: &str, first: String) -> bool {
    let Ok(old) = hub.find(sid) else {
        return false;
    };
    close_for_swap(front, &old).await;
    let Some(row) = read_rows(hub, Some(sid)).await.into_iter().next() else {
        return false;
    };
    resume_row_with(hub, front, row, Some(first)).await
}

/// OLD's agent ends so another conversation can take its hub session (a rotation, a rewind): its transcript and queue
/// kept on disk, its gateway registration and MCP session closed.  Its row stays.
pub(crate) async fn close_for_swap(front: &Front, old: &Session) {
    old.close_now().await;
    gateway_gone(front, &old.id).await;
    let _ = front.mcp.close(&old.id).await;
}

/// Session SID's recorded role is now ROLE (the user made it a manager).
pub(crate) async fn record_role(hub: &super::Hub, sid: &str, role: &str) {
    let (s, r) = (sid.to_owned(), role.to_owned());
    if let Some(db) = hub.db()
        && let Err(e) = db
            .write(move |c| Ok(c.execute("update asession set role = ?2 where sid = ?1", (s, r))?))
            .await
    {
        tracing::warn!(sid, "cannot record a session's role: {e}");
    }
}

impl Session {
    pub(crate) fn role(&self) -> Role {
        self.role
    }
    pub(crate) fn parent(&self) -> Option<&str> {
        self.parent.as_deref()
    }
    pub(crate) fn cwd(&self) -> &Path {
        &self.cwd
    }

    /// The subagents this session ran (Claude Code's `Task` tool), from its tool calls so far.
    pub fn subagents(&self) -> Vec<crate::work::subagents::Child> {
        let st = lock(&self.state);
        let calls: Vec<crate::work::subagents::ToolCall> = st
            .entries
            .iter()
            .filter(|e| e.kind == EntryType::Tool)
            .filter_map(|e| {
                let id = e.rest.get("id").and_then(Value::as_str)?.to_string();
                let meta = st.tool_meta.get(&id);
                Some(crate::work::subagents::ToolCall {
                    name: meta.and_then(|m| m.name.clone()),
                    parent: meta.and_then(|m| m.parent.clone()),
                    raw_input: e.rest.get("rawInput").cloned(),
                    id,
                })
            })
            .collect();
        crate::work::subagents::group(&self.id, &calls)
    }

    /// The command of the shell step running now (one a permission wait cut into counts), if one is: the trace
    /// supervisor traces a wrapper's offer only when it is this command ([`crate::work::trace`]).
    pub(crate) fn open_shell_command(&self) -> Option<String> {
        let st = lock(&self.state);
        [st.cur.as_ref(), st.stash.as_ref()]
            .into_iter()
            .flatten()
            .find_map(|s| s.tool_id.as_deref().and_then(|id| st.tool_command(id)))
    }

    /// Where the user's messages to this session come from, as an ask records it.
    fn ask_channel(&self) -> &'static str {
        match (self.role, &self.document) {
            (Role::Manager, _) => "manager",
            (_, Some(_)) => "brainstorm",
            _ => "chat",
        }
    }

    /// The transcript entries that carry one of MIDS as their `messageId`, at most CAP.
    pub(crate) fn entries_for(
        &self,
        mids: &std::collections::HashSet<String>,
        cap: usize,
    ) -> Vec<(u64, runstav::methods::agents::Entry)> {
        lock(&self.state)
            .entries
            .iter()
            .enumerate()
            .filter(|(_, e)| {
                e.rest
                    .get("messageId")
                    .and_then(Value::as_str)
                    .is_some_and(|m| mids.contains(m))
            })
            .take(cap)
            .map(|(i, e)| (i as u64, super::wire::with_blocks(e.clone())))
            .collect()
    }
}

/// ROW as a running session again: `session/resume`, else `session/load`; its transcript and held queue read back
/// and its first prompt delivered.  A session whose profile is gone or whose agent will not resume stays in the table.
async fn resume_row(hub: &super::Hub, front: &Front, row: Row) -> bool {
    resume_row_with(hub, front, row, None).await
}

/// [`resume_row`], or with FIRST (a manager's restart or rotation, Task 25): a new agent session in the same hub
/// session, no `session/resume`, that is told FIRST (its digest and open decisions) instead of [`RESTART_NOTICE`].
async fn resume_row_with(hub: &super::Hub, front: &Front, row: Row, first: Option<String>) -> bool {
    let again = match first {
        Some(f) => Again::Fresh(f),
        None => Again::Resume,
    };
    relaunch(hub, front, row, again).await.is_ok()
}

/// How [`relaunch`] brings a recorded session back.
pub(crate) enum Again {
    /// Its recorded conversation (`session/resume`, else `session/load`), else a fresh one told what happened.
    Resume,
    /// A fresh conversation told this first (a manager's restart or rotation).
    Fresh(String),
    /// A fork (a rewind): ATTACH, its new conversation told TOLD first when the fork lands at its own level.  When it
    /// lands at Summary instead (the agent cannot fork, or the fork failed), it is told SUMMARY and the user's
    /// MESSAGE; with no message the summary waits, held, at the queue's front, so no turn starts unasked.
    #[cfg_attr(not(test), allow(dead_code, reason = "made by the rewind"))]
    Fork {
        attach: Attach,
        told: Option<String>,
        summary: String,
        message: Option<String>,
    },
}

/// ROW's session running again as AGAIN says, under its own id, row, transcript and queue: the level a fork landed at
/// (none for any other way back), or why it is not running.  The row's conversation is written only once the launch
/// has landed, so a launch that fails leaves the row as it was, resumable.
pub(crate) async fn relaunch(
    hub: &super::Hub,
    front: &Front,
    row: Row,
    again_how: Again,
) -> Result<Option<RestoreLevel>, Error> {
    let (sid, name, profile_name, role, cwd, task, job, acp, parent, at) = row;
    // a worker a manager started gets back what the manager delegated, before its first tool call
    if parent.is_some() {
        crate::manager::restore_delegation(front, &sid).await;
    }
    let Some(profile) = find_profile(front, &profile_name) else {
        tracing::warn!(
            sid,
            "session not resumed: no agent profile {profile_name:?}"
        );
        return Err(invalid(
            "profile",
            format!("no agent profile {profile_name:?}"),
        ));
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
        task: task.clone(),
        job: job.clone(),
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
    let role_of = serde_json::from_value(json!(role)).unwrap_or(Role::Chat);
    // what the editor's modules added at its start goes again
    let env = kept_env(front, &sid, &meta);
    let again = |attach: Attach| {
        let (front, profile, sid, cwd, task, job, env) = (
            front,
            profile.clone(),
            sid.clone(),
            cwd.clone(),
            task.clone(),
            job.clone(),
            env.clone(),
        );
        async move {
            launch(
                front,
                &profile,
                role_of,
                &sid,
                Path::new(&cwd),
                &attach,
                (task.as_deref(), job.as_deref(), &env),
            )
            .await
        }
    };
    // `session/resume`, else `session/load` (both inside `launch`), else the summary handoff of Task 26, else a fresh
    // session that is told what happened (its transcript stays)
    let mut handoff: Option<String> = None;
    let tried = match &again_how {
        Again::Resume => Some(again(Attach::Resume(acp.clone())).await),
        Again::Fresh(_) | Again::Fork { .. } => None,
    };
    let (l, rx, fresh) = match tried {
        None => {
            let attach = match &again_how {
                Again::Fork { attach, .. } => attach.clone(),
                _ => Attach::New,
            };
            match again(attach).await {
                Ok((l, rx)) => (l, rx, true),
                Err(e) => {
                    tracing::warn!(sid, "session not started afresh: {}", e.message);
                    return Err(e);
                }
            }
        }
        Some(Ok((l, rx))) => (l, rx, false),
        Some(Err(e)) if e.code == ErrorCode::Internal => {
            tracing::warn!(
                sid,
                "session cannot be resumed ({}); starting it afresh",
                e.message
            );
            // the summary handoff (Task 26): a new session on the same hub id, told what the old one left
            handoff = Some(
                super::handoff::summary(front, &sid, Path::new(&cwd), task.as_deref(), None).await,
            );
            match again(Attach::New).await {
                Ok((l, rx)) => (l, rx, true),
                Err(e) => {
                    tracing::warn!(sid, "session not resumed: {}", e.message);
                    return Err(e);
                }
            }
        }
        Some(Err(e)) => {
            tracing::warn!(sid, "session not resumed: {}", e.message);
            return Err(e);
        }
    };
    let level = l.level;
    let (s, done) = assemble(ident, &profile, l, front, hub.step_bus());
    // a manager's restart or rotation is told FIRST; a fork what its level needs; any other fresh start the notice
    // and the summary handoff
    let (told, hold, reattach) = match again_how {
        Again::Fork {
            attach,
            told,
            summary,
            message,
        } => {
            let wanted = match attach {
                Attach::Fork { level, .. } => Some(level),
                _ => Some(RestoreLevel::Summary),
            };
            if level == wanted {
                (told, false, true)
            } else {
                match message {
                    Some(m) => (Some(format!("{summary}\n\n{m}")), false, true),
                    None => (Some(summary), true, true),
                }
            }
        }
        Again::Fresh(f) => (fresh.then_some(f), false, false),
        Again::Resume => (
            fresh.then(|| match handoff {
                Some(h) => format!("{RESTART_NOTICE}\n\n{h}"),
                None => RESTART_NOTICE.to_string(),
            }),
            false,
            false,
        ),
    };
    if fresh && let Some(db) = hub.db() {
        insert_row(db, &s).await;
    }
    // the queue on disk as it was, with what the agent is told at its front
    let (queue, paused) = match &s.store {
        Some(store) => {
            let entries = store.load(&sid);
            let mut st = lock(&s.state);
            st.flushed = entries.len();
            st.entries = entries;
            drop(st);
            store.load_queue(&sid)
        }
        None => Default::default(),
    };
    // a fork's first words come through the core's reattach, after the queue the swap kept
    let (resume_told, reattach_told) = if reattach {
        (None, Some(told))
    } else {
        (told, None)
    };
    lock(&s.state)
        .core
        .resume(queue, paused || hold, resume_told);
    // the user held its wheel when the hub ended: still held, from the same snapshot
    if let Some(store) = &s.store
        && let (true, base) = store.load_wheel(&sid)
    {
        let mut st = lock(&s.state);
        st.wheel = Wheel::Held;
        st.wheel_base = base;
        st.core.set_wheel(true);
        drop(st);
        s.pair.hold(&sid, true);
    }
    // a job it started still runs (re-attached before the sessions): it waits for it as before the restart
    let waiting = s.has_jobs();
    {
        let mut st = lock(&s.state);
        st.core.ready(waiting);
        if waiting {
            st.step_begin(StepClass::JobWait, None);
        }
    }
    hub.insert(s.clone());
    tokio::spawn(s.clone().run(rx, done));
    s.changed();
    if waiting {
        s.close_when_idle();
    }
    match reattach_told {
        Some(told) => s.reattach(told),
        None => s.next(),
    }
    Ok(level)
}

/// The session SID if it was closed while it waited on a job: resumed now (its agent started again on the same
/// ACP session) and the session in the hub is the new one.
pub(crate) async fn resume_closed(
    hub: &super::Hub,
    front: &Front,
    sid: &str,
) -> Result<Arc<Session>, Error> {
    let old = hub.find(sid)?;
    if !old.is_closed() {
        return Ok(old);
    }
    let rows = read_rows(hub, Some(sid)).await;
    let Some(row) = rows.into_iter().next() else {
        return Err(internal(format!(
            "session {sid} is closed and not recorded"
        )));
    };
    if !resume_row(hub, front, row).await {
        return Err(internal(format!("session {sid} cannot be resumed")));
    }
    hub.find(sid)
}

/// How many of a session's closed steps went to its writer task and how many rows that task has written.  A reader
/// of the `step` table that must see every step the session closed so far waits on it ([`Session::steps_written`]):
/// the row is written after the session already says it is idle.
pub(crate) struct StepFlow {
    sent: AtomicU64,
    written: tokio::sync::watch::Sender<u64>,
}

impl Default for StepFlow {
    fn default() -> Self {
        StepFlow {
            sent: AtomicU64::new(0),
            written: tokio::sync::watch::channel(0).0,
        }
    }
}

/// What a session's step rows say of it.
struct StepCtx {
    /// Counts the rows written, for [`StepFlow`].
    flow: Arc<StepFlow>,
    session: String,
    task: Option<String>,
    agent: String,
    provider: Option<String>,
    /// The worktree its edits are snapshotted from.
    cwd: PathBuf,
    /// The agent conversation its steps run in.
    acp: Option<String>,
    /// The projects' edit histories and the hub's state folder, to name the record a step anchors (none: a test).
    history: Option<(Arc<crate::history::wire::Hubs>, PathBuf)>,
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
    };
    let mut local = 0u64;
    let mut turn_start = true;
    while let Some(mut c) = rx.recv().await {
        local += 1;
        // an edit's lines: where its diff content is in the file now (off the async threads)
        let mut edit_col = None;
        if !c.diffs.is_empty()
            && let Some(d) = c.detail.clone()
        {
            let (dir, diffs) = (ctx.cwd.clone(), std::mem::take(&mut c.diffs));
            if let Ok((d, r)) = crate::clock::blocking(move || {
                let mut d = d;
                let r = crate::work::detail::edit_lines_now(&mut d, &dir, diffs);
                (d, r)
            })
            .await
            {
                c.detail = Some(d);
                edit_col = r.map(|r| r.col);
            }
        }
        let class_name = serde_json::to_value(c.open.class)
            .ok()
            .and_then(|v| v.as_str().map(str::to_string))
            .unwrap_or_default();
        let (plan, project) = sink
            .scopes
            .as_ref()
            .and_then(|s| s.get(&ctx.session))
            .map_or((None, None), |(p, j)| (Some(p), j));
        let new = table::StepNew {
            session: format!("session:{}", ctx.session),
            task: ctx.task.clone(),
            plan,
            project,
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
            acp: ctx.acp.clone(),
        };
        let mut end = table::StepEnd {
            end: c.end,
            tokens_in: c.tokens_in,
            tokens_out: c.tokens_out,
            cache_read: c.cache_read,
            cache_write: c.cache_write,
            cost: c.cost,
            cost_unit: c.cost.map(|_| "usd-est".to_string()),
            snapshot: None,
            log_version: None,
            context: c.context,
        };
        let detail = c.detail.clone();
        let (id, seq, log_version) = match sink
            .writer
            .write(&caller, "agents/step", move |tx| {
                let id = table::open(tx, new)?;
                end.log_version = Some(norn::write::meta::version(tx.sql())? as i64);
                let log_version = end.log_version;
                table::close(tx, id, end)?;
                if let Some(mut d) = detail {
                    d.step = id;
                    norn::write::work::put_step_detail(tx, d)?;
                }
                let seq: i64 =
                    tx.sql()
                        .query_row("select seq from step where id = ?1", [id], |r| r.get(0))?;
                Ok((id, seq, log_version))
            })
            .await
        {
            Ok(x) => x,
            Err(e) => {
                tracing::warn!(sid = ctx.session, "step not recorded: {e}");
                (0, local as i64, None)
            }
        };
        ctx.flow.written.send_modify(|w| *w += 1);
        let (snapshot, head, history_op) = anchor(
            &sink,
            &ctx,
            &caller,
            id,
            seq,
            c.turn_id.as_deref(),
            &c.open,
            (turn_start, c.before.as_deref(), c.cell.as_ref()),
            c.end,
        )
        .await;
        turn_start = c.turn_id.is_some();
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
            snapshot,
            log_version: log_version.map(|v| v as u64),
            tokens_in: Some(c.tokens_in as u64),
            tokens_out: Some(c.tokens_out as u64),
            cache_read: Some(c.cache_read as u64),
            cache_write: Some(c.cache_write as u64),
            cost: c.cost,
            cost_unit: c.cost.map(|_| Unit::UsdEst),
            detail: c.detail.as_ref().map(crate::work::detail::wire),
            acp: ctx.acp.clone(),
            head,
            history_op: history_op.map(|op| op as u64),
            undone_by: None,
            revertible: history_op.is_some(),
            hooks: Vec::new(),
        };
        // the files the step was in: the presence model (a shell step's command looked up off the async threads).  A
        // tool call's own file is its live entry while it runs: the call's end replaces that with the step's entry
        // (none when it failed), and a step cut while its call runs on leaves it standing.
        if let Some(live) = &sink.presence
            && (c.detail.is_some() || c.command.is_some() || c.open.tool_id.is_some())
        {
            use crate::work::presence::{self as presence, CallStatus};
            let (d, cmd, dir) = (c.detail.clone(), c.command.clone(), ctx.cwd.clone());
            let (mine, mut files) = crate::clock::blocking(move || {
                (
                    d.as_ref()
                        .map(|d| presence::touches_of_detail(d, &dir))
                        .unwrap_or_default(),
                    presence::touches_of_step(None, cmd.as_deref(), &dir),
                )
            })
            .await
            .unwrap_or_default();
            let mut changed = Vec::new();
            match (&c.open.tool_id, c.call_end) {
                (Some(call), Some(end)) => {
                    let closed = mine
                        .into_iter()
                        .next()
                        .filter(|_| end == CallStatus::Completed && id != 0)
                        .map(|t| presence::Entry {
                            session: ctx.session.clone(),
                            file: t.file,
                            mode: t.mode,
                            line: t.line,
                            line_end: c
                                .detail
                                .as_ref()
                                .and_then(|d| d.line_end)
                                .and_then(|l| u32::try_from(l).ok()),
                            col: edit_col,
                            source: t.source,
                            step: id,
                            at: step.start,
                            live: false,
                            tool_call: None,
                        });
                    changed.extend(live.close_live(&ctx.session, call, closed));
                }
                (Some(_), None) => {}
                (None, _) => files.extend(mine),
            }
            if id != 0 && !files.is_empty() {
                changed.extend(live.apply(presence::PresenceEv::Step {
                    session: ctx.session.clone(),
                    step: id,
                    at: step.start,
                    files,
                }));
            }
            if !changed.is_empty()
                && let Some(map) = &sink.map
            {
                map.presence(&live.now_in(&changed));
            }
        }
        // the step's class is the agent card's activity
        if let Some(map) = &sink.map
            && id != 0
        {
            map.step(&ctx.session, id, &step.class, step.start);
        }
        // a snapshot was taken (an edit, or the turn's first step): the worktree's changed files reach the map's
        // overlaps, also once the edit is no longer in flight
        if let Some(map) = &sink.map
            && step.snapshot.is_some()
        {
            map.edited(&ctx.session).await;
        }
        // a shell step closed: what its traced command opened goes out once its listener ended too
        if let (Some(traces), Some(cmd)) = (&sink.traces, &c.command)
            && id != 0
        {
            traces
                .step_closed(&ctx.session, id, cmd.clone(), step.start)
                .await;
        }
        // a conclusion's tool step is written, or the turn ended: the stamps that are due
        if let Some(stamps) = &sink.stamps {
            use crate::work::conclusions::StampEv;
            let mut due = Vec::new();
            if c.open.mcp && id != 0 {
                due.extend(stamps.step(StampEv::StepClosed {
                    session: ctx.session.clone(),
                    step: c.open.key,
                    id,
                }));
            }
            if step.turn_id.is_some() {
                due.extend(stamps.step(StampEv::TurnEnd {
                    session: ctx.session.clone(),
                }));
            }
            crate::work::conclusions::put(&sink.writer, due).await;
        }
        // a spec an agent just wrote is stored at once, not at the next scan
        if let (Some(tools), Some(d)) = (&sink.tools, &c.detail)
            && d.kind.as_deref() == Some("edit")
            && let Some(p) = &d.path
        {
            crate::work::specs::on_written(
                &sink.writer,
                tools,
                sink.asks.as_ref(),
                &ctx.session,
                &ctx.cwd.join(p),
            )
            .await;
        }
        // a shell step may have committed: link the new commits to the decisions this session recorded
        if step.class == StepClass::Tool
            && matches!(step.tool_kind.as_deref(), None | Some("execute"))
        {
            crate::runner::effects::link_new_commits(
                &sink.writer,
                &ctx.session,
                ctx.task.as_deref(),
                &ctx.cwd,
            )
            .await;
        }
        let ev = AgentStep {
            session: ctx.session.clone(),
            step,
        };
        sink.editors.broadcast("agent-step", json!(ev));
        let _ = sink.bus.send(ev);
    }
    // no more rows will come: whoever waits for one stops waiting
    ctx.flow.written.send_replace(u64::MAX);
}

/// The anchors a step gets once it is written: the turn id on the turn's earlier steps (it arrives with the turn's
/// last), and a snapshot of the worktree after a completed edit and at the turn's first step (BEFORE: the tree taken
/// before the turn's prompt went, else the worktree now; CELL: an edit's, the tree taken before the agent's next write
/// when the session served one first), with the worktree's commit then (from its ref files).  Best effort; answers the
/// snapshot and the commit.
#[allow(clippy::too_many_arguments)]
async fn anchor(
    sink: &StepSink,
    ctx: &StepCtx,
    caller: &Caller,
    id: i64,
    seq: i64,
    turn: Option<&str>,
    open: &OpenStep,
    (turn_start, before, cell): (bool, Option<&str>, Option<&crate::timeline::EditCell>),
    end: f64,
) -> (Option<String>, Option<String>, Option<i64>) {
    if id == 0 {
        // the row is lost: an edit's checkpoint would be a tree no step keeps, so the agent's next write takes none
        if let Some(c) = cell {
            c.close().await;
        }
        return (None, None, None);
    }
    let edit = open.is_edit();
    let turn_start = turn_start || before.is_some();
    let history_op = if edit || turn_start {
        newest_record(ctx, end).await
    } else {
        None
    };
    let snapshot = match (&sink.snap, edit || turn_start) {
        (Some(s), true) => {
            let before = before.filter(|_| !edit);
            s.after_edit(
                &ctx.session,
                &ctx.cwd,
                seq as u64,
                (before, cell),
                &sink.editors,
            )
            .await
        }
        _ => None,
    };
    if snapshot.is_none() && turn.is_none() && history_op.is_none() {
        return (None, None, None);
    }
    let head = match &snapshot {
        Some(_) => {
            let wt = ctx.cwd.clone();
            crate::clock::blocking(move || crate::timeline::snapshot::head_of(&wt))
                .await
                .ok()
                .flatten()
        }
        None => None,
    };
    let (turn, tree, sid, head_) = (
        turn.map(str::to_string),
        snapshot.clone(),
        format!("session:{}", ctx.session),
        head.clone(),
    );
    let r = sink
        .writer
        .write(caller, "agents/step", move |tx| {
            if let Some(t) = &tree {
                tx.sql().execute("update step set snapshot = ?2 where id = ?1", (id, t))?;
            }
            if let Some(h) = &head_ {
                norn::write::steps::set_head(tx, id, h)?;
            }
            if let Some(op) = history_op {
                norn::write::steps::set_history_op(tx, id, op)?;
            }
            if let Some(t) = &turn {
                tx.sql().execute(
                    "update step set turn_id = ?2 where session = ?1 and turn_id is null and id <= ?3",
                    (&sid, t, id),
                )?;
            }
            Ok(())
        })
        .await;
    if let Err(e) = r {
        tracing::warn!(sid = ctx.session, "step anchors not recorded: {e}");
    }
    (snapshot, head, history_op)
}

/// The newest record of the edit history this session caused at or before END: what a revert to the step restores the
/// text to.  None when the session has no history (a folder that is no git worktree, a test, a history that fails).
async fn newest_record(ctx: &StepCtx, end: f64) -> Option<i64> {
    let (hubs, state) = ctx.history.clone()?;
    let (cwd, sid) = (ctx.cwd.clone(), ctx.session.clone());
    crate::clock::blocking(move || {
        let (hub, _) = hubs.of_tree(&state, &cwd).ok()?;
        hub.with(|h| h.last_caused_by(&sid, end))
            .ok()
            .flatten()
            .map(|op| op.0)
    })
    .await
    .ok()
    .flatten()
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
        .write(move |c| {
            c.execute("delete from delegation where sid = ?1", [&s])?;
            Ok(c.execute("delete from asession where sid = ?1", [&s])?)
        })
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
    // the session's `start` event, for `events/since`
    let (job, started_name) = (s.job.clone(), name.clone());
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
            norn::write::event::event(
                tx,
                norn::write::event::Event {
                    at: now(),
                    agent: Some(sid.clone()),
                    job: job.clone(),
                    task: task.clone(),
                    kind: norn::write::event::EventKind::Start,
                    summary: format!("started {started_name}"),
                    data: None,
                    turn: false,
                },
            )?;
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
    /// The budget scope of this session.
    /// The project its plan run works under: the plugins and rules of that project apply.
    pub(crate) fn project(&self) -> Option<String> {
        self.scopes.get(&self.id).and_then(|(_, project)| project)
    }

    pub(crate) fn scope(&self) -> runstav::methods::timeline::BudgetScope {
        scope_of(self.role, &self.id)
    }

    /// AMOUNTS spent by this session, in their units.
    fn spend(&self, amounts: Vec<(Unit, f64)>) {
        for (unit, amount) in amounts {
            let hits = self.budgets.spend(&self.scope(), unit, amount);
            self.budgets.notify(hits);
        }
    }

    /// The token of the gateway registration, taken (the session is going).
    pub(crate) fn take_gateway(&self) -> Option<String> {
        lock(&self.gateway).take()
    }

    /// Remove the empty `.envrc`-style stubs the hub made in the worktree to pin them (see `sandbox::remove_stubs`).
    fn remove_stubs(&self) {
        let env = runstav::paths::Env::process();
        let scratch = launch::scratch_path(&env, &self.id);
        crate::sandbox::remove_stubs(&scratch, &self.cwd);
    }

    /// The folder the session works in.
    pub(crate) fn worktree(&self) -> PathBuf {
        self.cwd.clone()
    }

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
            self.flow.sent.fetch_add(1, Ordering::SeqCst);
            let _ = self.steps.send(c);
        }
    }

    /// Returns once every step this session has closed so far is a row of the `step` table.
    pub(crate) async fn steps_written(&self) {
        self.drain_steps();
        let target = self.flow.sent.load(Ordering::SeqCst);
        let _ = self
            .flow
            .written
            .subscribe()
            .wait_for(|w| *w >= target)
            .await;
    }

    /// The entries not yet in the transcript file, written (redacted) now; a turn not yet sent to the agent waits.
    fn flush_transcript(&self) {
        let Some(store) = &self.store else { return };
        let fresh: Vec<(u64, Entry)> = {
            let mut st = lock(&self.state);
            let to = st
                .unsent_at
                .unwrap_or(st.entries.len())
                .min(st.entries.len());
            let from = st.flushed.min(to);
            st.flushed = to;
            st.entries[from..to]
                .iter()
                .enumerate()
                .map(|(i, e)| ((from + i) as u64, e.clone()))
                .collect()
        };
        if let Err(e) = store.append(&self.id, &fresh) {
            tracing::warn!(sid = self.id, "transcript not written: {e}");
        }
    }

    /// The held queue and the pause, kept for a restart, with a turn's prompt that has not reached the agent at its
    /// front ([`TurnCore::kept`]).  Written under the state's lock: two writes from different tasks (a turn's end, the
    /// hub's end) land in the order of the states they read, so the file ends as the last.
    fn persist_queue(&self) {
        let Some(store) = &self.store else { return };
        let st = lock(&self.state);
        if let Err(e) = store.save_queue(&self.id, &st.core.kept(), st.core.paused()) {
            tracing::warn!(sid = self.id, "queue not kept: {e}");
        }
    }

    fn schedule(self: &Arc<Self>) {
        let fx = lock(&self.state).core.step(TurnEvent::Changed);
        if !fx.contains(&TurnEffect::ArmEmit) {
            return;
        }
        let me = self.clone();
        crate::clock::spawn("session:emit", async move {
            crate::clock::sleep(EMIT_EVERY).await;
            let fx = lock(&me.state).core.step(TurnEvent::EmitTick);
            if fx.contains(&TurnEffect::Emit) {
                me.emit();
            }
        });
    }

    /// What a turn core step decided, done: the requests it took answered cancelled, then each effect the shell
    /// performs the same way wherever it comes from.  The rest (refusals, holds, the user's answers) are the
    /// caller's.
    fn perform(self: &Arc<Self>, s: Stepped) {
        for p in s.cancelled {
            self.settle(p, None);
        }
        if s.held {
            self.wheel_held();
        }
        for e in s.fx {
            match e {
                TurnEffect::StartTurn { turn, item } => self.start_turn(turn, item),
                TurnEffect::CancelTurn => {
                    let _ = self.conn.cancel(&self.acp);
                }
                TurnEffect::ArmStopDeadline { turn } => self.stop_deadline(turn),
                TurnEffect::EndTurn { waiting: true, .. } => self.close_when_idle(),
                TurnEffect::Persist => self.persist_queue(),
                TurnEffect::Announce => self.changed(),
                TurnEffect::Withdraw { card } => self.withdraw_later(vec![card]),
                _ => {}
            }
        }
    }

    /// The matrix cards a step withdraws.
    fn withdrawn(fx: &[TurnEffect]) -> Vec<i64> {
        fx.iter()
            .filter_map(|e| match e {
                TurnEffect::Withdraw { card } => Some(*card),
                _ => None,
            })
            .collect()
    }

    /// CARDS leave the open cards (and so the needs-you lists): every request that waited on them was answered
    /// cancelled.  A card the user settled first stays settled.
    async fn withdraw_cards(&self, cards: Vec<i64>) {
        if cards.is_empty() {
            return;
        }
        let hub = Caller {
            class: Class::Service,
            sid: None,
            job: None,
            conn_id: 0,
        };
        let at = now();
        let r = self
            .writer
            .write(&hub, "cards/withdraw", move |tx| {
                for card in &cards {
                    norn::write::cards::card_withdraw(tx, *card, at)?;
                }
                Ok(())
            })
            .await;
        if let Err(e) = r {
            tracing::warn!(session = %self.id, "matrix cards not withdrawn: {e:?}");
        }
    }

    /// [`Session::withdraw_cards`] in a task of its own, for a step taken where nothing waits.
    fn withdraw_later(self: &Arc<Self>, cards: Vec<i64>) {
        if cards.is_empty() {
            return;
        }
        let me = self.clone();
        crate::clock::spawn("session:card-withdraw", async move {
            me.withdraw_cards(cards).await;
        });
    }

    fn emit(&self) {
        let (seq, entries) = {
            let mut st = lock(&self.state);
            let idx: Vec<usize> = std::mem::take(&mut st.dirty).into_iter().collect();
            let mut entries: Vec<(u64, Entry)> = idx
                .into_iter()
                .filter_map(|i| st.entries.get(i).map(|e| (i as u64, e.clone())))
                .collect();
            // an agent message arrives as Markdown blocks: all of them the first time (and for a new subscriber), after
            // that the patch of the ones that changed
            if let Some(m) = st.md.as_mut()
                && let Some((_, e)) = entries.iter_mut().find(|(i, _)| *i == m.entry as u64)
            {
                if !m.sent {
                    e.rest.insert("blocks".into(), json!(m.stream.blocks()));
                    m.sent = true;
                } else if !m.patch.is_empty() {
                    let patch: Vec<_> = m.patch.values().collect();
                    e.rest.insert("patch".into(), json!(patch));
                }
                m.patch.clear();
            }
            (st.seq, entries)
        };
        let snapshot = self.snapshot();
        if self.map.open() {
            self.map.session(&snapshot, &self.subagents());
        }
        self.editors.broadcast_agent(
            &self.id,
            json!({"id": self.id, "seq": seq, "session": snapshot}),
        );
        if entries.is_empty() {
            return;
        }
        let subscribers = self.editors.entry_subscribers(&self.id);
        if subscribers.is_empty() {
            return;
        }
        let entries: Vec<(u64, Entry)> = entries
            .iter()
            .map(|(i, e)| (*i, super::wire::public_entry(e)))
            .collect();
        let data = json!({"id": self.id, "seq": seq, "entries": entries});
        for conn in subscribers {
            self.editors.send_to(conn, "agent-entries", data.clone());
        }
    }

    /// Connection CONN gets this session's entries from now on; the change number they continue from.
    pub(crate) fn subscribe_entries(&self, conn: u64) -> u64 {
        // the number is read under the same lock the dirty set is drained under, so no entry falls between
        let mut st = lock(&self.state);
        self.editors.subscribe_entries(&self.id, conn);
        // the next event of the message streaming now carries all its blocks, whoever had the earlier ones
        if let Some(m) = st.md.as_mut() {
            m.sent = false;
        }
        st.seq
    }

    /// Bytes FROM..TO of tool call TOOL_CALL's output, at most a page of them.
    pub(crate) fn tool_output(
        &self,
        tool_call: &str,
        from: u64,
        to: u64,
    ) -> Option<super::tool_output::Page> {
        let st = lock(&self.state);
        let idx = *st.tools.get(tool_call)?;
        let rest = &st.entries.get(idx)?.rest;
        let parts = rest
            .get("content")
            .map(super::tool_output::text_parts)
            .unwrap_or_default();
        let kept: u64 = parts.iter().map(|p| p.len() as u64).sum();
        let total = rest
            .get("outputBytes")
            .and_then(Value::as_u64)
            .unwrap_or(kept);
        Some(super::tool_output::page(&parts, total, from, to))
    }

    /// The raw input of tool call TOOL_CALL, capped.
    pub(crate) fn tool_input(&self, tool_call: &str) -> Option<(Value, bool)> {
        let st = lock(&self.state);
        let idx = *st.tools.get(tool_call)?;
        let raw = st.entries.get(idx)?.rest.get("rawInput")?;
        Some(super::wire::capped_tool_input(raw))
    }

    /// Its running step's title (none between steps).
    pub fn doing(&self) -> Option<String> {
        lock(&self.state).cur.as_ref().and_then(|c| c.tool.clone())
    }

    pub fn snapshot(&self) -> Snapshot {
        let identity = self.identities.get(&self.id);
        let st = lock(&self.state);
        Snapshot {
            ordinal: identity.as_ref().map(|i| i.ordinal),
            handle: identity.as_ref().map(|i| i.handle.clone()),
            monogram: identity.map(|i| i.monogram),
            last_active: Some(st.last_update),
            id: self.id.clone(),
            name: Some(self.name.clone()),
            profile: Some(self.profile.clone()),
            cwd: Some(self.cwd.to_string_lossy().into_owned()),
            task: self.task.clone(),
            job: self.job.clone(),
            status: Some(st.core.status()),
            via: Some(self.via),
            mode: self.mode,
            queue: st.core.queue().texts(),
            // a take holds the queue at once, though the turn it stops ends after its tool call
            paused: (st.core.paused() || st.wheel != Wheel::Free).then_some(true),
            permissions: st.permissions.iter().map(|p| p.public.clone()).collect(),
            reviews: Vec::new(),
            usage: st.usage.clone(),
            commands: st.commands.clone(),
            capabilities: self.capabilities.clone(),
            exit: st.exit,
            stderr: st.stderr.clone(),
            entries_count: Some(st.entries.len() as u64),
            turns: Some(st.turns),
            enforced: Some(self.enforced),
            enforced_why: self.enforced_why.clone(),
            browser_why: self.browser_why.clone(),
            plugins_changed: self.plugins_changed.load(Ordering::SeqCst),
            role: Some(self.role),
            provider: self.provider.clone(),
            parent: self.parent.clone(),
            about: self.about.clone(),
            waiting_on: if st.cur.as_ref().map(|c| c.class) == Some(StepClass::MachineQueue) {
                Some("machine".to_string())
            } else {
                Some(self.live.ids(&self.id).join(","))
                    .filter(|j| st.core.status() == SessionStatus::Waiting && !j.is_empty())
            },
            hooked: self.hooked.clone(),
            panel: self.panel.snapshot(),
            waiting: self.pair.waiting(&self.id),
            paired: self.pair.paired_now(&self.id),
            held_by: (st.wheel != Wheel::Free).then(|| "user".to_string()),
        }
    }

    pub fn transcript(&self) -> Transcript {
        let snap = self.snapshot();
        let st = lock(&self.state);
        Transcript {
            session: snap,
            entries: st
                .entries
                .iter()
                .cloned()
                .map(super::wire::with_blocks)
                .collect(),
            seq: st.seq,
        }
    }

    fn fence(&self) -> Fence {
        Fence {
            cwd: self.cwd.clone(),
            document: self.document.clone(),
            read_only: self.role == Role::Chat
                && self.cwd != launch::scratch_path(&runstav::paths::Env::process(), &self.id),
            held: Fence::held(self),
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
        // the agent is gone: a follow view keeps where it was, a new follow starts from nothing
        self.follows.session_gone(&self.id);
    }

    async fn handle(self: &Arc<Self>, ev: Event) {
        {
            match ev {
                Event::Ext { method, params } if method.starts_with("_drgnx/") => {
                    panel::notification(self, &method, params);
                }
                Event::Request(Incoming::Ext {
                    method,
                    params,
                    resp,
                }) => panel::request(self.clone(), method, params, resp),
                Event::Ext { method, params } => {
                    if let Some((provider, share, resets)) =
                        crate::budget::meter_of(&method, &params)
                    {
                        let hits =
                            self.budgets
                                .reading(&self.scope(), provider, share, resets, now());
                        self.budgets.notify(hits);
                    }
                }
                Event::Update { update, .. } => {
                    if let Ok(v) = serde_json::to_value(&update) {
                        // a switch to a mode the lock refuses ends the session, as one reported at its start does
                        if let Some(plock::LockBroken(why)) =
                            plock::refused_mode_switch(self.locked_as, self.lock_held, &v)
                        {
                            tracing::warn!(sid = %self.id, "session ended, its lock broken: {why}");
                            let s = self.clone();
                            crate::clock::spawn(
                                "session:lock-broken",
                                async move { s.end(true).await },
                            );
                            return;
                        }
                        if let Some(total) = v
                            .pointer("/cost/amount")
                            .and_then(Value::as_f64)
                            .filter(|_| v.get("sessionUpdate") == Some(&json!("usage_update")))
                        {
                            let booked = self.budgets.spend_total_in(
                                &self.scope(),
                                "usd-est",
                                &self.acp.0,
                                Unit::UsdEst,
                                total,
                            );
                            lock(&self.state).add_turn_cost(booked.delta);
                            self.budgets.notify(booked.hits);
                        }
                        let (stepped, begun, live_out, moved) = {
                            let mut st = lock(&self.state);
                            st.apply(&v);
                            let begun = std::mem::take(&mut st.mcp_begun);
                            let live_out = std::mem::take(&mut st.live_out);
                            let moved = st.follow_tool.take().and_then(|i| {
                                crate::editor::follow::of_tool(
                                    &self.id,
                                    &self.cwd,
                                    &st.entries[i].rest,
                                    st.plan_now.as_deref(),
                                )
                            });
                            (
                                std::mem::take(&mut st.tool_ended)
                                    .then(|| st.turn_step(TurnEvent::ToolCompleted)),
                                begun,
                                live_out,
                                moved,
                            )
                        };
                        self.hook_own_edits(&v);
                        // the cursor moves as the call runs, before its step closes
                        self.feed_live(live_out).await;
                        if let Some(m) = moved {
                            self.follows.moved(m);
                        }
                        // a conclusion's tool step began: the stamp core pairs it with its MCP call
                        for (key, tool_name) in begun {
                            let s = self
                                .stamps
                                .step(crate::work::conclusions::StampEv::ToolStep {
                                    session: self.id.clone(),
                                    step: key,
                                    tool_name,
                                    at: now(),
                                });
                            if !s.is_empty() {
                                let w = self.writer.clone();
                                crate::clock::spawn("session:conclusions", async move {
                                    crate::work::conclusions::put(&w, s).await
                                });
                            }
                        }
                        self.drain_steps();
                        if let Some(s) = stepped {
                            // the pause after a tool call: the turn ends here, the queue waits
                            self.perform(s);
                        }
                        self.schedule();
                    }
                }
                Event::Request(Incoming::Permission(req, resp)) => {
                    let turn = lock(&self.state).core.turn();
                    self.permission_request(
                        serde_json::to_value(&req).unwrap_or_default(),
                        resp,
                        turn,
                    );
                }
                Event::Request(Incoming::ReadFile(req, resp)) => {
                    let v = serde_json::to_value(&req).unwrap_or_default();
                    let path = v.get("path").and_then(Value::as_str).unwrap_or("");
                    if self.project_chat() && self.in_project(path) {
                        // the pair door asks the editor: on a task of its own, so this loop never waits on one
                        let me = self.clone();
                        crate::clock::spawn("session:pair-read", async move {
                            let got = match me.pair_read(path_of(&v)).await {
                                Ok(text) => Ok(slice_lines(text, &v)),
                                Err(m) => Err(m),
                            };
                            answer_read(resp, got);
                        });
                        return;
                    }
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
                    let path = v.get("path").and_then(Value::as_str).unwrap_or("");
                    if self.project_chat() && self.in_project(path) {
                        // a chat's write of its project goes through the pair door, on a task of its own
                        let me = self.clone();
                        crate::clock::spawn("session:pair-write", async move {
                            let w = norn::tools::pair::PairWrite::Whole {
                                path: path_of(&v),
                                content: v
                                    .get("content")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_string(),
                            };
                            let r = me.pair_write(w).await;
                            match r {
                                Ok(_) => {
                                    if let Ok(ok) =
                                        serde_json::from_value::<WriteTextFileResponse>(json!({}))
                                    {
                                        let _ = resp.respond(ok);
                                    }
                                }
                                Err(m) => {
                                    let _ = resp.fail(-32602, &m);
                                }
                            }
                        });
                        return;
                    }
                    // in a task of its own: the after-edit hooks may take their whole budget, and this loop
                    // must keep serving the agent's other events meanwhile
                    let me = self.clone();
                    crate::clock::spawn("session:write", async move {
                        match me.write_file(&v).await {
                            Ok(()) => {
                                if let Ok(r) =
                                    serde_json::from_value::<WriteTextFileResponse>(json!({}))
                                {
                                    let _ = resp.respond(r);
                                }
                            }
                            Err((code, m)) => {
                                let _ = resp.fail(code, &m);
                            }
                        }
                    });
                }
                Event::Exit {
                    code,
                    signal,
                    stderr,
                } => {
                    self.remove_stubs();
                    // its process is gone, and its provider proxy with it (a resume binds a new one)
                    drop(lock(&self.net).take());
                    if self.closed.load(Ordering::SeqCst) {
                        // closed on purpose while it waited on a job: still waiting; the wake resumes it
                        {
                            let mut st = lock(&self.state);
                            st.exit = Some(code.map_or_else(
                                || signal.map_or(-1, |s| 128 + i64::from(s)),
                                i64::from,
                            ));
                            st.seq += 1;
                        }
                        self.schedule();
                        return;
                    }
                    // it is no longer live: its ordinal and handle are free
                    self.identities.free(&self.id);
                    let stepped = {
                        let mut st = lock(&self.state);
                        st.exit =
                            Some(code.map_or_else(
                                || signal.map_or(-1, |s| 128 + i64::from(s)),
                                i64::from,
                            ));
                        st.stderr = Some(stderr).filter(|s| !s.is_empty());
                        st.stash = None;
                        let stepped = st.turn_step(TurnEvent::Exited);
                        st.step_close(now(), None);
                        st.seq += 1;
                        stepped
                    };
                    self.perform(stepped);
                    self.drain_steps();
                    self.flush_transcript();
                    self.schedule();
                }
            }
        }
    }

    /// What the updates said of the running tool calls, into the presence model's live feed (and the map's presence).
    async fn feed_live(&self, outs: Vec<(String, LiveOut)>) {
        use crate::work::presence::CallStatus;
        use runstav::methods::work::PresenceMode as Mode;
        let mut changed = Vec::new();
        for (call, out) in outs {
            match out {
                LiveOut::At {
                    detail,
                    status,
                    diffs,
                } => {
                    // an edit with diff content that has not landed is pending, on the lines it will change
                    let pending = !diffs.is_empty()
                        && matches!(status, CallStatus::Pending | CallStatus::InProgress);
                    let Some(mut update) = self.live_update(*detail, diffs, status).await else {
                        continue;
                    };
                    if pending && update.mode == Mode::Edit {
                        update.mode = Mode::Pending;
                    }
                    changed.extend(self.presence.apply_live(&self.id, &call, update));
                }
                LiveOut::Gone => changed.extend(self.presence.close_live(&self.id, &call, None)),
            }
        }
        if !changed.is_empty() {
            self.map.presence(&self.presence.now_in(&changed));
        }
    }

    /// A running call's presence from its DETAIL: its file and line, and for an edit with DIFFS the lines they change
    /// in the file now (found off the async threads); none when it names no file.
    async fn live_update(
        &self,
        detail: norn::write::work::StepDetail,
        diffs: Diffs,
        status: crate::work::presence::CallStatus,
    ) -> Option<crate::work::presence::LiveUpdate> {
        let dir = self.cwd.clone();
        let (detail, range) = if diffs.is_empty() {
            (detail, None)
        } else {
            let (dir, fallback) = (dir.clone(), detail.clone());
            crate::clock::blocking(move || {
                let mut d = detail;
                let r = crate::work::detail::edit_lines_now(&mut d, &dir, diffs);
                (d, r)
            })
            .await
            .unwrap_or((fallback, None))
        };
        let t = crate::work::presence::touches_of_detail(&detail, &dir)
            .into_iter()
            .next()?;
        Some(crate::work::presence::LiveUpdate {
            path: t.file,
            mode: t.mode,
            line: t.line,
            line_end: detail.line_end.and_then(|l| u32::try_from(l).ok()),
            col: range.map(|r| r.col),
            status,
            source: t.source,
            at: crate::clock::wall_secs(),
        })
    }

    /// A permission request whose tool call carries `diff` content: the edit it asks for shows as pending on its lines
    /// from now until the request is answered ([`Session::settle`]).
    async fn feed_pending(&self, req: &Value) {
        use crate::work::presence::CallStatus;
        use runstav::methods::work::PresenceMode as Mode;
        let Some(tool) = req.get("toolCall") else {
            return;
        };
        let Some(call) = tool.get("toolCallId").and_then(Value::as_str) else {
            return;
        };
        let diffs = crate::work::edit_lines::diffs(tool.get("content"));
        let Some(path) = tool
            .pointer("/locations/0/path")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| diffs.first().map(|d| d.0.clone()))
        else {
            return;
        };
        let detail = norn::write::work::StepDetail {
            kind: Some("edit".into()),
            path: Some(path),
            origin: "acp".into(),
            ..Default::default()
        };
        let Some(mut update) = self.live_update(detail, diffs, CallStatus::Pending).await else {
            return;
        };
        update.mode = Mode::Pending;
        let changed = self.presence.apply_live(&self.id, call, update);
        if !changed.is_empty() {
            self.map.presence(&self.presence.now_in(&changed));
        }
    }

    /// Permission request P answered with ANSWER (none: cancelled), and its pending presence settled: refused, the call
    /// will not run and its entry goes; allowed, the call's own updates carry it on (an id the agent has not reported
    /// is the request's own: its entry goes, the call left open).
    fn settle(&self, p: Pending, answer: Option<String>) {
        let allowed = answer.as_deref().is_some_and(|a| {
            p.options
                .iter()
                .any(|(id, k)| id == a && k.starts_with("allow"))
        });
        let call = p
            .public
            .tool
            .as_ref()
            .and_then(|t| t.get("toolCallId"))
            .and_then(Value::as_str)
            .map(str::to_string);
        reply(p.resp, answer);
        let Some(call) = call else { return };
        let changed = if !allowed {
            self.presence.close_live(&self.id, &call, None)
        } else if lock(&self.state).tools.contains_key(&call) {
            Vec::new()
        } else {
            self.presence.withdraw_live(&self.id, &call)
        };
        if !changed.is_empty() {
            self.map.presence(&self.presence.now_in(&changed));
        }
    }

    /// The agent's permission request, received during TURN.
    fn permission_request(
        self: &Arc<Self>,
        req: Value,
        resp: hermod::Responder<RequestPermissionResponse>,
        turn: u64,
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
        // The matrix decides, after the before-tool hooks where any subscribe: allowed answers at once, never refuses
        // at once, an ask waits for the user.
        let s = self.clone();
        tokio::spawn(async move {
            if s.has_jobs() && is_wait_loop(req.get("toolCall")) {
                let n = s.refuse_wait();
                {
                    let mut st = lock(&s.state);
                    let mut rest = Map::new();
                    rest.insert("text".into(), json!(WAIT_REFUSED));
                    st.push(EntryType::Error, rest);
                }
                s.changed();
                tracing::debug!(session = s.id, refusals = n, "a wait loop refused");
                reply(resp, pick_reject(&options));
                return;
            }
            if super::deliver::gate(&s, req.get("toolCall")).await {
                reply(resp, pick_reject(&options));
                return;
            }
            let (action, facts) = classify(req.get("toolCall"));
            match s
                .seam_hooks(req.get("toolCall"), action, &facts, &options, turn)
                .await
            {
                SeamHooks::Answer(option) => {
                    reply(resp, option);
                    return;
                }
                SeamHooks::Today | SeamHooks::Decide => {}
            }
            let ctx = ActionCtx {
                facts,
                ..ActionCtx::of_session(&s.scopes, &s.id)
            };
            let gate = s
                .gate
                .decide(&s.settings, &s.writer, s.who(), action, ctx)
                .await;
            match gate {
                Gate::Never(_) => reply(resp, pick_reject(&options)),
                Gate::Allow if pick_allow(&options).is_some() => reply(resp, pick_allow(&options)),
                gate => {
                    // held for the user: an edit it asks for is pending meanwhile
                    s.feed_pending(&req).await;
                    let card = match gate {
                        Gate::Ask(card) if card > 0 => Some(card),
                        _ => None,
                    };
                    s.hold_permission(&req, options, resp, card, turn)
                }
            }
        });
    }

    /// A request the user answers: it waits in the snapshot, under CARD's id when the matrix asked through one.  When
    /// TURN, the turn it came in, was cancelled or is over by now, nobody would answer it: it is answered cancelled.
    fn hold_permission(
        self: &Arc<Self>,
        req: &Value,
        options: Vec<(String, String)>,
        resp: hermod::Responder<RequestPermissionResponse>,
        card: Option<i64>,
        turn: u64,
    ) {
        // an editor never gets a tool call's raw input (a Write carries the file)
        let tool = req.get("toolCall").cloned().map(|mut t| {
            if let Some(o) = t.as_object_mut() {
                o.remove("rawInput");
            }
            t
        });
        let request = self.next_request.fetch_add(1, Ordering::Relaxed);
        let public = Permission {
            id: Some(match card {
                Some(c) => RpcId::Int(c),
                None => RpcId::Str(format!("r{request}")),
            }),
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
        let pending = Pending {
            request,
            card,
            public,
            options,
            resp,
        };
        {
            let mut st = lock(&self.state);
            let fx = st.core.step(TurnEvent::PermissionAsked {
                request,
                turn,
                card,
            });
            if !fx.contains(&TurnEffect::Hold { request }) {
                drop(st);
                self.settle(pending, None);
                // nobody answers its card either
                self.withdraw_later(Self::withdrawn(&fx));
                return;
            }
            st.permissions.push(pending);
            st.wait_begin();
        }
        self.changed();
    }

    /// The user's answer to a request: OPTION (one the agent offered), or none to reject.  A request the matrix asked
    /// through a card is answered through that card: it is settled, the matrix is checked again (a cell that has
    /// become Never refuses whatever the answer), and every request waiting on it goes on.
    pub(crate) async fn answer_permission(
        self: &Arc<Self>,
        request: &RequestId,
        option: Option<&str>,
    ) -> Result<bool, Error> {
        let (card, allow) = {
            let mut st = lock(&self.state);
            let at = st
                .permissions
                .iter()
                .position(|p| p.is(request))
                .ok_or_else(|| {
                    invalid("request", "no such permission request (answered already?)")
                })?;
            let p = &st.permissions[at];
            if let Some(o) = option
                && !p.options.iter().any(|(id, _)| id == o)
            {
                return Err(invalid(
                    "option",
                    "not one of the options the agent offered",
                ));
            }
            let allow = option.is_some_and(|o| {
                p.options
                    .iter()
                    .any(|(id, k)| id == o && k.starts_with("allow"))
            });
            match p.card {
                Some(c) => (c, allow),
                None => {
                    // no card to answer (the store made none): the answer goes as it is
                    let request = p.request;
                    let mut stepped = st.turn_step(TurnEvent::PermissionAnswered { request });
                    drop(st);
                    for p in std::mem::take(&mut stepped.answered) {
                        let answer = p.option(allow, option);
                        self.settle(p, answer);
                    }
                    self.perform(stepped);
                    self.changed();
                    return Ok(true);
                }
            }
        };
        let (choice, at) = (if allow { "allow" } else { "deny" }, now());
        let settled = self
            .writer
            .write(&crate::runner::user(), "cards/settle", move |tx| {
                norn::write::cards::card_settle(tx, card, choice, at)
            })
            .await;
        if let Err(e) = settled {
            tracing::warn!(session = %self.id, card, "matrix card not settled: {e:?}");
        }
        self.release_card(card, option).await;
        Ok(true)
    }

    /// Matrix card CARD was settled (here, or in the cockpit): each request waiting on it goes on as the matrix says
    /// now ([`MatrixGate::recheck`]): the user's yes where it still holds, else refused.  CHOSEN is the option the
    /// user picked here.
    pub(crate) async fn release_card(self: &Arc<Self>, card: i64, chosen: Option<&str>) {
        let waiting: Vec<Pending> = {
            let mut st = lock(&self.state);
            let mine: Vec<u64> = st
                .permissions
                .iter()
                .filter(|p| p.card == Some(card))
                .map(|p| p.request)
                .collect();
            if mine.is_empty() {
                return;
            }
            let mut taken = Vec::new();
            for request in mine {
                taken.extend(
                    st.turn_step(TurnEvent::PermissionAnswered { request })
                        .answered,
                );
            }
            taken
        };
        self.gate.refresh_from(&self.settings);
        let (g, at) = (self.gate.clone(), now());
        let gate = self
            .writer
            .db
            .read(move |c| Ok(g.recheck(c, card, at)))
            .await
            .unwrap_or_else(|e| Gate::Never(format!("the store did not answer: {e:?}")));
        let allow = gate == Gate::Allow;
        for p in waiting {
            let answer = p.option(allow, chosen);
            self.settle(p, answer);
        }
        self.changed();
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
                self.turn_event(TurnEvent::QueueEdited(QueueEdit::Deliver));
                Ok(true)
            }
            AgentOp::Unqueue => {
                let n = nth("unqueue")?;
                self.queue_edited(QueueEdit::Unqueue(n as usize), n)
            }
            AgentOp::Requeue => {
                let n = nth("requeue")?;
                let text = p.text.as_ref().map_or("", |t| t.as_str());
                self.queue_edited(QueueEdit::Requeue(n as usize, text.to_string()), n)
            }
        }
    }

    fn queue_edited(self: &Arc<Self>, edit: QueueEdit, n: u64) -> Result<bool, Error> {
        if self
            .turn_event(TurnEvent::QueueEdited(edit))
            .contains(&TurnEffect::NoSuchItem)
        {
            return Err(invalid("n", format!("no queued message {n}")));
        }
        Ok(true)
    }

    /// EV through the turn core, and what it decided done ([`Session::perform`]); its effects, for the caller's own.
    fn turn_event(self: &Arc<Self>, ev: TurnEvent) -> Vec<TurnEffect> {
        let stepped = lock(&self.state).turn_step(ev);
        let fx = stepped.fx.clone();
        self.perform(stepped);
        fx
    }

    /// The running turn, if any, is the only thing Stop cancels: the permission requests it waits on are answered
    /// cancelled, the queue is held, and an agent that has not ended the turn after STOP_ANSWER loses its process.  A
    /// second Stop of the same turn changes nothing.  A turn whose prompt has not reached the agent yet is put back
    /// instead: the prompt waits at the front of the held queue, and nothing is sent.
    pub(crate) fn stop_turn(self: &Arc<Self>) -> bool {
        !self
            .turn_event(TurnEvent::Stop { after_tool: false })
            .contains(&TurnEffect::NotRunning)
    }

    /// The Stop's deadline for TURN: its process group ends if that turn still runs then.
    fn stop_deadline(self: &Arc<Self>, turn: u64) {
        let me = self.clone();
        crate::clock::spawn("session:stop-answer", async move {
            crate::clock::sleep(STOP_ANSWER).await;
            let fx = lock(&me.state).core.step(TurnEvent::Kill {
                why: KillWhy::StopDue { turn },
            });
            if fx.contains(&TurnEffect::KillProcess) {
                draugr::kill_group(me.conn.pid(), STOP_GRACE, &draugr::RealSignaller).await;
            }
        });
    }

    /// Pause: cancel once the tool call running now completes and hold the queue; with no turn running, hold the
    /// queue.
    pub(crate) fn pause_after_tool(self: &Arc<Self>) -> Result<(), Error> {
        if self
            .turn_event(TurnEvent::Stop { after_tool: true })
            .contains(&TurnEffect::Exited)
        {
            return Err(invalid("id", "the session has exited"));
        }
        Ok(())
    }

    /// The user takes the wheel ([`super::wheel`]): the turn running stops after its tool call, no turn starts until
    /// the give, and once no turn runs the wheel is held.  A second take changes nothing.
    pub(crate) fn wheel_take(self: &Arc<Self>) -> Result<(), Error> {
        let stepped = {
            let mut st = lock(&self.state);
            let st = &mut *st;
            let (taken, fx) =
                wheel::take(&mut st.wheel, &mut st.core).map_err(|m| invalid("id", m))?;
            if taken == wheel::Taken::Already {
                return Ok(());
            }
            let mut stepped = st.stepped(fx);
            stepped.held |= taken == wheel::Taken::Held;
            stepped
        };
        // a paired chat's door closes at the take: its writes still queued in an editor are dropped
        self.pair.hold(&self.id, true);
        self.persist_wheel();
        self.perform(stepped);
        self.changed();
        Ok(())
    }

    /// The wheel is held (the turn the take stopped has ended, or none ran): the step snapshot first, kept with the
    /// hold for a restart, then `agent-wheel held`.
    fn wheel_held(self: &Arc<Self>) {
        let me = self.clone();
        crate::clock::spawn("session:wheel-held", async move {
            let base = match &me.snap {
                Some(s) => s.wheel_held(&me.id, &me.cwd).await,
                None => None,
            };
            lock(&me.state).wheel_base = base;
            me.persist_wheel();
            me.changed();
            me.editors.broadcast(
                "agent-wheel",
                json!(AgentWheel {
                    id: me.id.clone(),
                    state: WheelState::Held,
                }),
            );
        });
    }

    /// The user gives the wheel back: refused until held.  A session in a worktree of its own has the editor save
    /// its buffers there first (refused while one stays unsaved); then the user's changes since the hold go to the
    /// agent first ([`wheel::give_text`]), its queue after, and `agent-wheel free`.
    pub(crate) async fn wheel_give(self: &Arc<Self>) -> Result<(), Error> {
        let base = {
            let st = lock(&self.state);
            wheel::can_give(st.wheel).map_err(refuse)?;
            st.wheel_base.clone()
        };
        let diff = if wheel::saves_on_give(self.role) {
            let cwd = self.cwd.to_string_lossy().into_owned();
            let unsaved = self
                .editors
                .wheel_save(&self.id, &cwd, WHEEL_SAVE_WAIT)
                .await;
            if !unsaved.is_empty() {
                return Err(refuse(&format!(
                    "not given back: save these files first: {}",
                    unsaved.join(", ")
                )));
            }
            match (&self.snap, base) {
                (Some(s), Some(b)) => s
                    .changes_since(&self.id, &self.cwd, &b)
                    .await
                    .unwrap_or_default(),
                _ => String::new(),
            }
        } else {
            // a chat works in the user's checkout: its edits there reach it from the edit history, not from here
            String::new()
        };
        let stepped = {
            let mut st = lock(&self.state);
            let st = &mut *st;
            let fx = wheel::give(&mut st.wheel, &mut st.core, wheel::give_text(&diff))
                .map_err(refuse)?;
            st.wheel_base = None;
            st.stepped(fx)
        };
        self.pair.hold(&self.id, false);
        self.persist_wheel();
        self.perform(stepped);
        self.editors.broadcast(
            "agent-wheel",
            json!(AgentWheel {
                id: self.id.clone(),
                state: WheelState::Free,
            }),
        );
        Ok(())
    }

    /// The hold on the wheel, kept for a restart.
    fn persist_wheel(&self) {
        let Some(store) = &self.store else { return };
        let st = lock(&self.state);
        let held = st.wheel != Wheel::Free;
        if let Err(e) = store.save_wheel(&self.id, held, st.wheel_base.as_deref()) {
            tracing::warn!(sid = self.id, "the wheel's hold not kept: {e}");
        }
    }

    /// What the supervisor reads of this session.
    pub(crate) fn observe(&self) -> crate::supervisor::Obs {
        let st = lock(&self.state);
        crate::supervisor::Obs {
            sid: self.id.clone(),
            task: self.task.clone(),
            role: self.role,
            cwd: self.cwd.clone(),
            status: st.core.status(),
            last_update: st.last_update,
            busy_elsewhere: !st.permissions.is_empty()
                || st.cur.as_ref().map(|c| c.class) == Some(StepClass::MachineQueue),
            max_repeat: st.max_repeat,
            tokens: st.tokens,
            refusals: self.wait_refusals.load(Ordering::Relaxed),
            context: st
                .usage
                .as_ref()
                .and_then(|u| Some(u.used? / u.size.filter(|s| *s > 0.0)?)),
            jobs: self.live.ids(&self.id),
            held: st.wheel != Wheel::Free,
        }
    }

    /// The supervisor found this busy session silent: the time until its turn ends is a `stalled` step.
    pub(crate) fn mark_stalled(self: &Arc<Self>) {
        {
            let mut st = lock(&self.state);
            if st.core.status() != SessionStatus::Busy
                || st.cur.as_ref().map(|c| c.class) == Some(StepClass::Stalled)
            {
                return;
            }
            st.stash_begin(StepClass::Stalled);
        }
        self.changed();
    }

    pub(crate) fn status(&self) -> SessionStatus {
        lock(&self.state).core.status()
    }

    /// The job this session works for.
    pub(crate) fn job_id(&self) -> Option<&str> {
        self.job.as_deref()
    }

    /// The coordination store this session's decisions and messages live in.
    pub(crate) fn coord(&self) -> &crate::coord::Writer {
        &self.writer
    }

    /// Is WHO this session (its id, or its name)?
    pub(crate) fn is_for(&self, who: &str) -> bool {
        who == self.id || who == self.name
    }

    /// Free for a delivery: idle, not held by a Stop, nothing waiting (`drgnx-agents-free-p`).  A delivery is a new
    /// turn, never an interruption.
    pub(crate) fn is_free(&self) -> bool {
        lock(&self.state).core.is_free() && !self.closed.load(Ordering::SeqCst)
    }

    /// Does the prompt the hub keyed KEY (`message:ID`, `wake:JOB`) wait in the queue or stand in the transcript?  (A
    /// wake that was delivered before a restart is not delivered again.)  The key is set by the hub that delivers
    /// the prompt, so a peer's message that quotes a header never matches.
    pub(crate) fn holds_key(&self, key: &str) -> bool {
        let st = lock(&self.state);
        st.core.queue().has_key(key)
            || st.entries.iter().any(|e| {
                e.kind == EntryType::User && e.rest.get("key").and_then(Value::as_str) == Some(key)
            })
    }

    /// TEXT goes ahead of the ordinary queued prompts (the freshness gate's notice: the agent reads it at its next
    /// turn; hermod cannot inject into a running one).
    pub(crate) fn steer_in(self: &Arc<Self>, text: String) {
        self.turn_event(TurnEvent::QueueEdited(QueueEdit::SteerIn(text)));
    }

    /// The front, once bound and while it lives (the hooks before a tool call reach the plugins through it).
    pub(crate) fn front(&self) -> Option<Arc<Front>> {
        self.tool_hub.front()
    }

    /// Where a `before-tool` point of this session runs AT: its project, folder, role, profile, job and task.
    pub(crate) async fn hook_site(&self, at: crate::hook_points::At) -> crate::hook_points::Site {
        let project = match self.project.get() {
            Some(p) => p.clone(),
            None => {
                let p = match ActionCtx::of_session(&self.scopes, &self.id).project {
                    Some(p) => Some(p),
                    None => {
                        let cwd = self.cwd.clone();
                        crate::clock::blocking(move || norn::project::resolve(&cwd).map(|r| r.id))
                            .await
                            .ok()
                            .flatten()
                    }
                };
                let _ = self.project.set(p.clone());
                p
            }
        };
        crate::hook_points::Site {
            at,
            session: self.id.clone(),
            project,
            root: Some(self.cwd.clone()),
            role: serde_json::to_value(self.role)
                .ok()
                .and_then(|v| v.as_str().map(str::to_owned)),
            profile: Some(self.profile.clone()),
            job: self.job.clone(),
            task: self.task.clone(),
        }
    }

    /// The tool call TOOL of a permission request as the hooks see it, with what this session folded of the same
    /// `toolCallId` (its kind, when the request has none; the adapter's tool name, else, for a request with no title
    /// of its own (DeepSeek Harness sends the id only), the folded call's one-word title) and its step.
    pub(crate) fn tool_call_info(&self, tool: Option<&Value>) -> crate::hook_points::ToolCallInfo {
        let id = tool
            .and_then(|t| t.get("toolCallId"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let untitled = tool.and_then(|t| t.get("title")).is_none();
        let (kind, name, step) = {
            let st = lock(&self.state);
            let folded = st.tools.get(id).and_then(|i| st.entries.get(*i));
            let kind = folded
                .and_then(|e| e.rest.get("kind"))
                .and_then(Value::as_str)
                .map(str::to_owned);
            let title = folded
                .filter(|_| untitled)
                .and_then(|e| e.rest.get("title"))
                .and_then(Value::as_str)
                .filter(|t| !t.is_empty() && !t.contains(char::is_whitespace))
                .map(str::to_owned);
            let name = st.tool_meta.get(id).and_then(|m| m.name.clone()).or(title);
            let step = st
                .cur
                .as_ref()
                .filter(|c| !id.is_empty() && c.tool_id.as_deref() == Some(id))
                .map(|c| c.key);
            (kind, name, step)
        };
        crate::hook_points::ToolCallInfo::from_acp(tool, kind.as_deref(), name.as_deref(), step)
    }

    /// The step running now (`step.seq`), if any.
    pub(crate) fn current_step(&self) -> Option<i64> {
        lock(&self.state).cur.as_ref().map(|c| c.key)
    }

    /// A hook's note TEXT (from SOURCE, `rule:ID` or `plugin:NAME@…`) under STEP: a `note` entry of the transcript.
    pub(crate) fn hook_note(
        self: &Arc<Self>,
        step: Option<i64>,
        source: Option<String>,
        text: String,
    ) {
        let mut rest = Map::new();
        rest.insert("text".into(), json!(text));
        if let Some(s) = step {
            rest.insert("step".into(), json!(s));
        }
        if let Some(s) = source {
            rest.insert("source".into(), json!(s));
        }
        lock(&self.state).push(EntryType::Note, rest);
        self.changed();
    }

    /// The `before-tool` hooks at the seam, for the request TOOL that `classify` read as ACTION with FACTS during
    /// TURN (design addendum §4.1, "The seam, step by step"):
    /// - a hub tool's step is hooked at its server, not here (its row says so);
    /// - nothing subscribed: today's seam ([`SeamHooks::Today`]: no `dry`, no row);
    /// - else the matrix's `dry` (the settings read again first): Never refuses with no hook run; on Allow or Ask
    ///   the hooks run. A deny answers the reject option and makes no card; a turn cancelled meanwhile answers
    ///   `cancelled`; a `dry` Allow answers Allow with no `decide`; a `dry` Ask goes to `decide`.
    async fn seam_hooks(
        self: &Arc<Self>,
        tool: Option<&Value>,
        action: Action,
        facts: &runstav::methods::matrix::Facts,
        options: &[(String, String)],
        turn: u64,
    ) -> SeamHooks {
        use crate::hook_points::{self as points, At};
        let Some(front) = self.front() else {
            return SeamHooks::Today;
        };
        let call = self.tool_call_info(tool);
        if call.kind == "other" && points::hub_tool_name(call.name.as_deref()) {
            let site = self.hook_site(At::Seam).await;
            points::hub_tool_at_the_seam(&front, &site, &call).await;
            return SeamHooks::Today;
        }
        let site = self.hook_site(At::Seam).await;
        let Some(prepared) = points::prepare(&front.core.plugins, &site, &call) else {
            return SeamHooks::Today;
        };
        self.gate.refresh_from(&self.settings);
        let ctx = ActionCtx {
            facts: facts.clone(),
            ..ActionCtx::of_session(&self.scopes, &self.id)
        };
        let (g, who, at) = (self.gate.clone(), self.who(), now());
        // a store that fails asks the user, as `decide` does
        let verdict = self
            .writer
            .db
            .read(move |c| Ok(g.dry(c, &who, action, &ctx, at).verdict))
            .await
            .unwrap_or(runstav::methods::matrix::Verdict::Ask);
        if verdict == runstav::methods::matrix::Verdict::Never {
            return SeamHooks::Answer(pick_reject(options));
        }
        let cell = norn::matrix::Cell {
            verdict,
            limit: None,
        };
        let out = points::run(&front, &site, &call, prepared, Some(cell)).await;
        if !lock(&self.state).core.asks_in(turn) {
            return SeamHooks::Answer(None);
        }
        match out.decision {
            norn::hooks::Decision::Deny(_) => SeamHooks::Answer(pick_reject(options)),
            norn::hooks::Decision::Proceed { .. } if pick_allow(options).is_some() => {
                SeamHooks::Answer(pick_allow(options))
            }
            _ => SeamHooks::Decide,
        }
    }

    /// First call for decision-log version V: true (the gate tells the agent once per version).
    pub(crate) fn gate_told(&self, v: u64) -> bool {
        self.gated.swap(v, Ordering::AcqRel) != v
    }

    /// A job this session started runs: when its turn ends the session waits for it (no model request).
    pub(crate) fn has_jobs(&self) -> bool {
        !self.live.ids(&self.id).is_empty()
    }

    /// Closed while it waited on a job: the agent's process is gone.
    pub(crate) fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    fn setting_u64(&self, name: &str, default: u64) -> u64 {
        self.settings
            .effective(name, None)
            .and_then(|(v, _)| v.as_u64())
            .unwrap_or(default)
    }

    /// The agent waited on a running job (a `job_result` or `job_log` of it, a sleep loop): refused.  After
    /// `agents-wait-refusals` of them in one turn the turn is cancelled; the wake prompts the session again.
    pub(crate) fn refuse_wait(self: &Arc<Self>) -> u32 {
        let n = self.wait_refusals.fetch_add(1, Ordering::Relaxed) + 1;
        if u64::from(n) >= self.setting_u64("drgnx-agents-wait-refusals", 3) {
            self.stop_turn();
        }
        n
    }

    /// The session's job waits for a machine (ON), or got one.
    pub(crate) fn queue_wait(self: &Arc<Self>, on: bool) {
        {
            let mut st = lock(&self.state);
            if on {
                if st.core.status() == SessionStatus::Busy {
                    st.stash_begin(StepClass::MachineQueue);
                }
            } else if st.cur.as_ref().map(|c| c.class) == Some(StepClass::MachineQueue) {
                st.wait_end();
            }
        }
        self.changed();
    }

    /// After `agents-close-idle-after` seconds of waiting on a job the agent's process ends (`session/close` where the
    /// agent has it); the wake resumes the session.  0: never.
    fn close_when_idle(self: &Arc<Self>) {
        let after = self.setting_u64("drgnx-agents-close-idle-after", 1800);
        if after == 0 {
            return;
        }
        let me = self.clone();
        let turn = lock(&self.state).core.turn();
        crate::clock::spawn("session:close-idle", async move {
            crate::clock::sleep(Duration::from_secs(after)).await;
            let still = {
                let st = lock(&me.state);
                st.core.status() == SessionStatus::Waiting && st.core.turn() == turn
            };
            if still && me.has_jobs() {
                me.close_now().await;
            }
        });
    }

    /// What its agent answered to `initialize` (`agentCapabilities`).
    #[cfg_attr(not(test), allow(dead_code, reason = "read by the rewind"))]
    pub(crate) fn capabilities(&self) -> Option<&Value> {
        self.capabilities.as_ref()
    }

    /// Its conversation is about to be swapped (a rewind): the running turn is cancelled and cut off, a prompt that
    /// has not reached the agent goes back to the queue, and the queue is kept on disk for the session that follows.
    #[cfg_attr(not(test), allow(dead_code, reason = "called by the rewind"))]
    pub(crate) fn detach(self: &Arc<Self>) {
        let fx = lock(&self.state).turn_step(TurnEvent::Detach);
        self.perform(fx);
    }

    /// Its new conversation is live (a rewind's): TOLD first, then the queue as the swap kept it.  Also a revert's
    /// that stopped before anything changed: the same conversation goes on.
    pub(crate) fn reattach(self: &Arc<Self>, told: Option<String>) {
        let fx = lock(&self.state).turn_step(TurnEvent::Reattach { told });
        self.perform(fx);
    }

    pub(crate) async fn close_now(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.flush_transcript();
        self.persist_queue();
        let _ = self.conn.close_session(&self.acp).await;
        draugr::kill_group(self.conn.pid(), STOP_GRACE, &draugr::RealSignaller).await;
    }

    async fn read_file(&self, req: &Value) -> Result<String, String> {
        let path = req.get("path").and_then(Value::as_str).unwrap_or("");
        let real = self.fence().check(path, false)?;
        let text = tokio::fs::read_to_string(&real)
            .await
            .map_err(|e| format!("{path}: {e}"))?;
        Ok(slice_lines(text, req))
    }

    /// A chat in a project (not its scratch folder, not a brainstorm): its edits of the checkout go through the pair
    /// door, its own tools see the checkout read-only.
    pub(crate) fn project_chat(&self) -> bool {
        is_project_chat(
            self.role,
            self.document.is_some(),
            self.cwd == launch::scratch_path(&runstav::paths::Env::process(), &self.id),
        )
    }

    /// Whether PATH (absolute) is inside the session's project: a chat's `fs/*` call there goes to the pair door.
    fn in_project(&self, path: &str) -> bool {
        let p = Path::new(path);
        p.is_absolute() && resolve(p).starts_with(resolve(&self.cwd))
    }

    /// The session's matrix cells now.
    async fn cells_now(&self) -> Result<norn::matrix::Effective, String> {
        let who = Who {
            role: Some(self.role),
            agent: Some(self.profile.clone()),
            provider: self.provider.clone(),
        };
        self.gate
            .effective_now(
                &self.settings,
                &self.writer,
                who,
                ActionCtx::of_session(&self.scopes, &self.id),
            )
            .await
            .map_err(|e| format!("the matrix: {e:?}"))
    }

    /// The chat's read of PATH through the pair door (`read_file`, `fs/read_text_file` in the project).
    pub(crate) async fn pair_read(&self, path: String) -> Result<String, String> {
        if !self.project_chat() {
            return Err(
                "read_file is a chat's in a project; read the file with your own tools".into(),
            );
        }
        let eff = self.cells_now().await?;
        self.pair
            .read(&self.id, &self.cwd, &eff, &path)
            .await
            .map(|s| s.text)
            .map_err(|r| r.0)
    }

    /// The chat's write W through the pair door (`edit_file`, `write_file`, `fs/write_text_file` in the project).
    pub(crate) async fn pair_write(
        &self,
        w: norn::tools::pair::PairWrite,
    ) -> Result<String, String> {
        use crate::pair::door::WriteKind;
        use norn::tools::pair::PairWrite;
        if !self.project_chat() {
            return Err("only a chat in your project edits your checkout through drgnx".into());
        }
        let eff = self.cells_now().await?;
        // the step the write is made in: the editor's change, and the disk's record, carry it into the history
        let step = self.current_step().unwrap_or(0);
        let (path, kind) = match w {
            PairWrite::Edit { path, old, new } => (path, WriteKind::Edit { old, new }),
            PairWrite::Whole { path, content } => (path, WriteKind::Whole { content }),
        };
        self.pair
            .write_with(
                &self.id,
                step,
                &self.cwd,
                &eff,
                &path,
                kind,
                self.disk_record(step),
            )
            .await
            .map_err(|r| r.0)
    }

    /// The record of a pair write to a file open nowhere, before it lands on disk: the agent's operations in its
    /// project's history, as [`Self::record_write`] makes them, caused by STEP (best effort: no history, no record).
    fn disk_record(&self, step: i64) -> Option<crate::pair::disk::Record> {
        let (hubs, state) = self.history.clone()?;
        let (cwd, sid) = (self.cwd.clone(), self.id.clone());
        Some(Box::new(move |real: &Path, bytes: &[u8]| {
            let Some(rel) = real
                .strip_prefix(resolve(&cwd))
                .ok()
                .and_then(|r| r.to_str())
                .filter(|r| !r.is_empty())
            else {
                return;
            };
            let Ok((hub, tree)) = hubs.of_tree(&state, &cwd) else {
                return;
            };
            let cause = verdandi::Cause {
                session: Some(sid.clone()),
                step: Some(step.to_string()),
                ..Default::default()
            };
            if let Err(e) =
                hub.on_agent_write(&tree, rel, bytes, &sid, cause, crate::clock::wall_secs())
            {
                tracing::info!(sid, "the agent's write is not in the history: {e}");
            }
        }))
    }

    /// The user's pair toggle ON for this chat: on needs `chat.project-edit` not never; off closes the door at once
    /// and queues a note to the agent, cancelling nothing.
    pub(crate) async fn pair_toggle(self: &Arc<Self>, on: bool) -> Result<(), Error> {
        if !self.project_chat() {
            return Err(refuse("pair mode is a chat's in a project"));
        }
        let eff = self.cells_now().await.map_err(|e| refuse(&e))?;
        self.pair
            .toggle(&self.id, on, &eff)
            .map_err(|r| refuse(&r.0))?;
        if !on {
            self.prompt(crate::pair::door::OFF_NOTE.to_string(), Origin::Hub)?;
        }
        self.changed();
        Ok(())
    }

    /// The matrix may have changed: this chat's `chat.project-edit` decided again; one that became never closes its
    /// pair door now ([`crate::pair::door::Door::recheck`]), cancelling nothing.
    pub(crate) async fn pair_recheck(self: &Arc<Self>) {
        if !self.project_chat() {
            return;
        }
        let Ok(eff) = self.cells_now().await else {
            return;
        };
        if self.pair.recheck(&self.id, &eff) {
            self.changed();
        }
    }

    /// The agent's `fs/write_text_file`: the after-edit hooks see the content first. A deny refuses the write (-32000),
    /// a change is what gets written (and the agent is told), a note goes under the step. What is written goes to the
    /// project's edit history first ([`Self::record_write`]).
    async fn write_file(self: &Arc<Self>, req: &Value) -> Result<(), (i64, String)> {
        let path = req.get("path").and_then(Value::as_str).unwrap_or("");
        let mut content = req
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let real = self.fence().check(path, true).map_err(|m| (-32602, m))?;
        if let Some(front) = self.front() {
            let old = tokio::fs::read_to_string(&real).await.unwrap_or_default();
            let diff = similar::TextDiff::from_lines(old.as_str(), content.as_str())
                .unified_diff()
                .to_string();
            let edit = crate::hook_points::EditInfo {
                path: real.clone(),
                diff: Some(diff),
                content: Some(content.clone()),
                step: None,
            };
            let out = crate::hook_points::after_edit(&front, self, &edit).await;
            self.note_all(&out.annotations);
            if let Some((_, reason)) = crate::hook_points::refusal_of(&out) {
                return Err((-32000, crate::hook_points::refusal_message(&reason)));
            }
            if let Some((new, hook)) = crate::hook_points::changed_content(&out) {
                content = new;
                self.steer_in(crate::hook_points::change_notice(&hook, path));
            }
        }
        // the edit steps closed since the last write hold the tree as it is now, before this one (after the hooks:
        // a refused write leaves them for the next)
        let cells = std::mem::take(&mut lock(&self.state).edits);
        if let Some(s) = &self.snap
            && !cells.is_empty()
        {
            s.before_write(&self.id, &self.cwd, cells).await;
        }
        // the edit history records what is written: the content after the hooks' change, never a refused write
        self.record_write(&real, &content).await;
        tokio::fs::write(&real, content)
            .await
            .map_err(|e| (-32602, format!("{path}: {e}")))
    }

    /// Notes from the hooks, shown in the transcript under the step.
    fn note_all(self: &Arc<Self>, notes: &[String]) {
        if notes.is_empty() {
            return;
        }
        {
            let mut st = lock(&self.state);
            for n in notes {
                let mut rest = Map::new();
                rest.insert("text".into(), json!(n));
                st.push(EntryType::Notice, rest);
            }
        }
        self.changed();
    }

    /// An edit the agent made itself just completed: the hooks may only note or deny it. Off the turn, in a task of
    /// its own. A deny is steered to the agent and marks the step refused; the file stays.
    fn hook_own_edits(self: &Arc<Self>, update: &Value) {
        if update.get("sessionUpdate") != Some(&json!("tool_call_update"))
            || update.get("status") != Some(&json!("completed"))
            || self.front().is_none()
        {
            return;
        }
        let id = update
            .get("toolCallId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let edits: Vec<(PathBuf, String)> = update
            .get("content")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|c| c.get("type") == Some(&json!("diff")))
            .filter_map(|c| {
                let path = c.get("path")?.as_str()?;
                let new = c.get("newText").and_then(Value::as_str).unwrap_or("");
                let old = c.get("oldText").and_then(Value::as_str).unwrap_or("");
                let diff = similar::TextDiff::from_lines(old, new)
                    .unified_diff()
                    .to_string();
                Some((PathBuf::from(path), diff))
            })
            .collect();
        if edits.is_empty() {
            return;
        }
        let me = self.clone();
        crate::clock::spawn("session:after-edit", async move {
            let Some(front) = me.front() else {
                return;
            };
            for (path, diff) in edits {
                let shown = path.display().to_string();
                let edit = crate::hook_points::EditInfo {
                    path,
                    diff: Some(diff),
                    content: None,
                    step: None,
                };
                let out = crate::hook_points::after_edit(&front, &me, &edit).await;
                me.note_all(&out.annotations);
                if let Some((hook, reason)) = crate::hook_points::refusal_of(&out) {
                    me.mark_refused(&id, &hook, &reason);
                    me.steer_in(format!(
                        "drgnx refused your edit of {shown}; the hook {hook} said: «{reason}»"
                    ));
                }
            }
        });
    }

    /// The step of TOOL_ID is marked refused by hook HOOK (the timeline and the edits ledger read it).
    fn mark_refused(self: &Arc<Self>, tool_id: &str, hook: &str, reason: &str) {
        {
            let mut st = lock(&self.state);
            if let Some(i) = st.tools.get(tool_id).copied() {
                st.entries[i].rest.insert(
                    "refused_by_hook".into(),
                    json!({"hook": hook, "reason": reason}),
                );
                st.dirty.insert(i);
            }
        }
        self.changed();
    }

    /// The agent's write of CONTENT to REAL (a path the fence allowed), recorded in its project's history before the
    /// file is written, so the watcher's event about it finds the version known: operations by the agent's peer on its
    /// worktree's branch, one `agent_step` record caused by this session.  A folder that is no git worktree, a path
    /// outside it (a brainstorm's document) or a history that fails leave the write as it is: best effort.
    async fn record_write(&self, real: &Path, content: &str) {
        let Some((hubs, state)) = &self.history else {
            return;
        };
        let Some(rel) = real
            .strip_prefix(resolve(&self.cwd))
            .ok()
            .and_then(|r| r.to_str())
            .filter(|r| !r.is_empty())
            .map(str::to_owned)
        else {
            return;
        };
        let Ok((hub, tree)) = hubs.of_tree(state, &self.cwd) else {
            return;
        };
        let cause = verdandi::Cause {
            session: Some(self.id.clone()),
            ..Default::default()
        };
        let (sid, bytes, now) = (
            self.id.clone(),
            content.as_bytes().to_vec(),
            crate::clock::wall_secs(),
        );
        let r = crate::clock::blocking(move || {
            hub.on_agent_write(&tree, &rel, &bytes, &sid, cause, now)
        })
        .await;
        if let Ok(Err(e)) = r {
            tracing::info!(
                sid = self.id,
                "the agent's write is not in the history: {e}"
            );
        }
    }

    /// Cancel the turn and end the process group.
    pub(crate) async fn end(self: &Arc<Self>, kill: bool) {
        // no turn starts now, and nobody answers what it asked
        let stepped = lock(&self.state).turn_step(TurnEvent::Kill { why: KillWhy::User });
        let dropped: Vec<Queued> = stepped
            .fx
            .iter()
            .filter_map(|e| match e {
                TurnEffect::Discard(items) => Some(items.clone()),
                _ => None,
            })
            .flatten()
            .collect();
        let cards = Self::withdrawn(&stepped.fx);
        self.reply_cancelled(stepped);
        self.withdraw_cards(cards).await;
        // a message the store gave this session and that never ran waits in the store again, for its next session
        super::deliver::put_back(&self.writer, &dropped).await;
        let _ = self.conn.cancel(&self.acp);
        let grace = if kill { Duration::ZERO } else { STOP_GRACE };
        draugr::kill_group(self.conn.pid(), grace, &draugr::RealSignaller).await;
        // the session is gone for good (its runtime.db rows go next): so is what a manager delegated to it
        self.gate.drop_delegation(&self.id);
    }

    /// A prompt from ORIGIN.  Idle, it goes behind whatever a Stop held back and the queue is delivered; during a
    /// turn it waits in the queue (ahead of the ordinary ones when the profile's mode is `steer`).  It never
    /// cancels: `interrupt` mode queues too, and only Stop cancels.
    pub(crate) fn prompt(self: &Arc<Self>, text: String, origin: Origin) -> Result<(), Error> {
        self.prompt_keyed(text, origin, None)
    }

    /// [`Session::prompt`] for a prompt the hub knows by KEY ([`Session::holds_key`]).
    pub(crate) fn prompt_keyed(
        self: &Arc<Self>,
        text: String,
        origin: Origin,
        key: Option<String>,
    ) -> Result<(), Error> {
        self.prompt_with(text, origin, key, false).map(|_| ())
    }

    /// [`Session::prompt`] only when the session is free ([`TurnCore::is_free`]): `false`, and nothing queued, steered or
    /// sent, when it is not.  Checked and taken under one lock, so a turn cannot start in between.
    pub(crate) fn prompt_if_free(
        self: &Arc<Self>,
        text: String,
        origin: Origin,
    ) -> Result<bool, Error> {
        self.prompt_with(text, origin, None, true)
    }

    fn prompt_with(
        self: &Arc<Self>,
        text: String,
        origin: Origin,
        key: Option<String>,
        only_free: bool,
    ) -> Result<bool, Error> {
        let fx = self.turn_event(TurnEvent::Send {
            item: Queued {
                text,
                origin,
                steer: false,
                key,
            },
            steer_mode: self.mode == Some(Mode::Steer),
            if_free: only_free,
        });
        match fx.first() {
            Some(TurnEffect::Exited) => Err(invalid("id", "the session has exited")),
            Some(TurnEffect::NotFree) => Ok(false),
            _ => Ok(true),
        }
    }

    /// Start the next queued prompt when the session is idle and the queue is not held.
    fn next(self: &Arc<Self>) {
        let fx = lock(&self.state).turn_step_next();
        self.perform(fx);
    }

    /// Turn TURN of ITEM began (its entry and step are in the state): its prompt goes to the agent.
    fn start_turn(self: &Arc<Self>, turn: u64, item: Queued) {
        self.wait_refusals.store(0, Ordering::Relaxed);
        self.persist_queue();
        self.flush_transcript();
        self.changed();
        tokio::spawn(self.clone().turn(turn, item));
    }

    /// One turn of ITEM, and what follows it: the stop entry, the steps closed, the transcript written, the next
    /// queued prompt unless a Stop or a pause holds it.  The prompt goes only if the turn is still to send (the core's
    /// `Sending` step, under the state's lock): the hub's end may have put it back in the queue since it began.
    async fn turn(self: Arc<Self>, turn: u64, item: Queued) {
        let send = lock(&self.state)
            .turn_step(TurnEvent::Sending { turn })
            .fx
            .contains(&TurnEffect::Prompt { turn });
        if !send {
            return;
        }
        // the turn's first step holds the tree as it is before the agent hears of the turn: taken by the step writer
        // once that step is written, it could already hold the turn's first write
        if let Some(s) = &self.snap {
            let tree = s.before_turn(&self.id, &self.cwd).await;
            lock(&self.state).before = tree;
        }
        // its entry is the agent's now: in the transcript file first, then off the queue on disk (a hub that dies
        // between the two runs the prompt again at the next start; it never loses it)
        self.flush_transcript();
        self.persist_queue();
        // the user's words reach the agent: its current ask from here on (told before the agent can write)
        if item.origin == Origin::User {
            let (session, text, at) = (self.id.clone(), item.text.clone(), now());
            self.asks.send(if item.steer {
                crate::work::asks::AskEv::SteerDelivered { session, text, at }
            } else {
                crate::work::asks::AskEv::UserMessage {
                    session,
                    text,
                    channel: self.ask_channel().into(),
                    message_id: item.key.clone(),
                    at,
                }
            });
        }
        let block = json!({"type": "text", "text": item.origin.frame(&item.text)});
        let blocks = serde_json::from_value(json!([block])).unwrap_or_default();
        let out = self.conn.prompt(&self.acp, blocks, None).await;
        // the reader task ends the turn, after the updates the agent sent before its answer
        let _ = self.done.send(TurnEnd(turn, out));
    }

    fn finish_turn(self: &Arc<Self>, end: TurnEnd) {
        let TurnEnd(turn, out) = end;
        let mut message: Option<String> = None;
        let jobs = self.has_jobs();
        // ENDING as the step saw it, under its lock: a hub that begins ending after the step ends what it started
        let (stepped, ending) = {
            let mut st = lock(&self.state);
            st.open = None;
            let mut rest = Map::new();
            let mut used = TurnUse::default();
            // the turn's last message: an agent without drgnx's tools ends with a `drgnx-report` block in it
            for e in st.entries.iter().rev() {
                match e.kind {
                    EntryType::User => break,
                    EntryType::Agent => {
                        message = e
                            .rest
                            .get("text")
                            .and_then(Value::as_str)
                            .map(str::to_owned);
                        break;
                    }
                    _ => {}
                }
            }
            let ev = match &out {
                Ok(o) => {
                    rest.insert("stop".into(), json!(format!("{:?}", o.stop)));
                    st.push(EntryType::Stop, rest);
                    used = turn_use(o);
                    used.cost = st.take_turn_cost();
                    let tokens = (used.tokens_in + used.tokens_out) as f64;
                    st.tokens += tokens as u64;
                    self.spend(vec![(Unit::Tokens, tokens)]);
                    TurnEvent::PromptDone {
                        turn,
                        cancelled: serde_json::to_value(o.stop).ok() == Some(json!("cancelled")),
                        jobs,
                    }
                }
                Err(hermod::Error::Closed) => TurnEvent::PromptFailed {
                    turn,
                    closed: true,
                    jobs,
                },
                Err(e) => {
                    rest.insert("text".into(), json!(e.to_string()));
                    // the editor tells this error, which ends the turn, from one inside a turn (a refused wait)
                    rest.insert("stop".into(), json!("Error"));
                    st.push(EntryType::Error, rest);
                    TurnEvent::PromptFailed {
                        turn,
                        closed: false,
                        jobs,
                    }
                }
            };
            st.stash = None;
            st.step_close(now(), Some(used));
            let stepped = st.turn_step(ev);
            (stepped, st.core.ending())
        };
        // a planning session's answer (empty when the turn failed) goes to Say it; any other chat pays one lookup
        self.say
            .turn_ended(&self.id, message.as_deref().unwrap_or(""));
        if let Some(m) = message.filter(|m| {
            (m.contains("drgnx-report") || m.contains("drgnx-conclusion")) && self.task.is_some()
        }) {
            let (w, sid, task, job) = (
                self.writer.clone(),
                self.id.clone(),
                self.task.clone(),
                self.job.clone(),
            );
            tokio::spawn(async move {
                if let Some(Err(e)) = crate::runner::effects::submit_fallback(
                    &w,
                    &sid,
                    task.as_deref(),
                    job.as_deref(),
                    &m,
                )
                .await
                {
                    tracing::warn!(sid, "fallback report not submitted: {e}");
                }
                if let Some(Err(e)) = crate::runner::effects::record_conclusion_fallback(
                    &w,
                    &sid,
                    task.as_deref(),
                    job.as_deref(),
                    &m,
                )
                .await
                {
                    tracing::warn!(sid, "fallback conclusion not recorded: {e}");
                }
            });
        }
        if ending {
            self.perform(stepped);
            self.drain_steps();
            self.flush_transcript();
            return;
        }
        // the transcript, then the queue kept, the event pair, and the next prompt
        self.flush_transcript();
        self.perform(stepped);
    }

    /// A kill's step: the requests it took answered cancelled, and their cards gone from the snapshot at once (not at
    /// the exit).
    fn reply_cancelled(self: &Arc<Self>, stepped: Stepped) {
        if stepped.cancelled.is_empty() {
            return;
        }
        for p in stepped.cancelled {
            self.settle(p, None);
        }
        self.changed();
    }

    /// The hub ends: the transcript written, the agent's process group ended, the queue left as it is on disk for
    /// the next start, with a turn whose prompt has not reached the agent back at its front.
    pub(crate) async fn shutdown(self: &Arc<Self>) {
        let stepped = lock(&self.state).turn_step(TurnEvent::Kill {
            why: KillWhy::HubEnding,
        });
        let put_back = stepped.fx.contains(&TurnEffect::Persist);
        let cards = Self::withdrawn(&stepped.fx);
        self.reply_cancelled(stepped);
        // before the store ends: the agent that asked is going, and its requests with it
        self.withdraw_cards(cards).await;
        if put_back {
            self.persist_queue();
        }
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

/// What an agent is told when it waits on a job it started.
pub(crate) const WAIT_REFUSED: &str =
    "your job runs: end your turn, you are woken with its result (no waiting, polling or sleeping)";

/// A shell command that waits or polls (`sleep`, `pgrep`, `watch`, `until`, `tail -f`), as an `execute` tool call.
fn is_wait_loop(tool: Option<&Value>) -> bool {
    let Some(t) = tool else { return false };
    if t.get("kind").and_then(Value::as_str) != Some("execute") {
        return false;
    }
    let command = t
        .pointer("/rawInput/command")
        .or_else(|| t.get("title"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let words: Vec<&str> = command
        .split(|c: char| !(c.is_alphanumeric() || c == '-' || c == '_'))
        .filter(|w| !w.is_empty())
        .collect();
    words
        .iter()
        .any(|w| matches!(*w, "sleep" | "pgrep" | "watch" | "until"))
        || words
            .windows(2)
            .any(|p| p[0] == "tail" && matches!(p[1], "-f" | "-F" | "--follow"))
}

/// What the `before-tool` hooks at the seam left to do ([`Session::seam_hooks`]).
enum SeamHooks {
    /// Nothing subscribed: the seam as it was before hooks (`decide`).
    Today,
    /// The hooks ran and none denied, and the matrix asks: `decide` makes the card (or a grant allows).
    Decide,
    /// The answer is decided: the option, or none ("cancelled").
    Answer(Option<String>),
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

/// The user's prompt: a turn while idle, else queued (or steered); it never cancels.  With `if_free` it is a turn or
/// nothing: a session that is busy, paused, holding a queue or closed on a job answers `false` and is left as it was.
pub async fn send(f: &Front, c: &Caller, p: SendParams) -> Result<bool, Error> {
    if c.class != Class::User {
        return Err(refuse("only the user sends a message here"));
    }
    if p.if_free == Some(true) {
        return f
            .core
            .agents
            .find(p.id.as_str())?
            .prompt_if_free(p.text.as_str().to_string(), Origin::User);
    }
    // a session closed on a job is resumed first: the message must reach a running agent
    resume_closed(&f.core.agents, f, p.id.as_str()).await?;
    f.core
        .agents
        .send(p.id.as_str(), p.text.as_str().to_string())?;
    Ok(true)
}

pub async fn stop(f: &Front, _: &Caller, p: ById) -> Result<bool, Error> {
    // a planning session's planning stops with it (Say it)
    f.core.say.stopped(p.id.as_str());
    // a turn running is cancelled (the session stays); an idle or starting session is ended: its token and socket go
    let ends = f
        .core
        .agents
        .find(p.id.as_str())
        .is_ok_and(|s| s.status() != SessionStatus::Busy);
    let r = f.core.agents.stop(p.id.as_str()).await;
    if r.is_ok() && ends {
        gateway_gone(f, p.id.as_str()).await;
        let _ = f.mcp.close(p.id.as_str()).await;
        asks_gone(f, p.id.as_str());
    }
    r
}

/// `agents/entries/subscribe`: the caller's connection gets the session's entries from now on.
pub fn entries_subscribe(
    f: &Front,
    c: &Caller,
    p: runstav::methods::agents::SessionRef,
) -> Result<runstav::methods::agents::EntriesSubscribed, Error> {
    let s = f.core.agents.find(p.session.as_str())?;
    Ok(runstav::methods::agents::EntriesSubscribed {
        seq: s.subscribe_entries(c.conn_id),
    })
}

/// `agents/entries/unsubscribe`.
pub fn entries_unsubscribe(
    f: &Front,
    c: &Caller,
    p: runstav::methods::agents::SessionRef,
) -> Result<bool, Error> {
    f.editors.unsubscribe_entries(p.session.as_str(), c.conn_id);
    Ok(true)
}

/// `agents/tool-input`: a tool call's raw input, capped.
pub fn tool_input(
    f: &Front,
    _: &Caller,
    p: runstav::methods::agents::ToolInputParams,
) -> Result<runstav::methods::agents::ToolInput, Error> {
    let s = f.core.agents.find(p.session.as_str())?;
    let (raw_input, truncated) = s
        .tool_input(&p.tool_call)
        .ok_or_else(|| invalid("tool_call", "a tool call of this session with a raw input"))?;
    Ok(runstav::methods::agents::ToolInput {
        raw_input,
        truncated,
    })
}

/// `agents/wheel/take`: the user takes the session's wheel.
pub fn wheel_take(f: &Front, c: &Caller, p: ById) -> Result<bool, Error> {
    if c.class != Class::User {
        return Err(refuse("only the user takes an agent's wheel"));
    }
    f.core.agents.find(p.id.as_str())?.wheel_take()?;
    Ok(true)
}

/// `agents/wheel/give`: the user gives the session's wheel back.
pub async fn wheel_give(f: &Front, c: &Caller, p: ById) -> Result<bool, Error> {
    if c.class != Class::User {
        return Err(refuse("only the user gives an agent's wheel back"));
    }
    f.core.agents.find(p.id.as_str())?.wheel_give().await?;
    Ok(true)
}

/// `agents/wheel/saved`: the editor's answer to `wheel-save`.
pub fn wheel_saved(f: &Front, _: &Caller, p: WheelSaved) -> Result<bool, Error> {
    let unsaved = p.unsaved.iter().map(|a| a.as_str().to_string()).collect();
    Ok(f.editors.wheel_saved(p.req, unsaved))
}

/// `agents/pair`: the user turns pair mode on or off for a chat in a project.
pub async fn pair(
    f: &Front,
    c: &Caller,
    p: runstav::methods::pair::PairToggle,
) -> Result<bool, Error> {
    if c.class != Class::User {
        return Err(refuse("only the user turns pair mode on or off"));
    }
    f.core.agents.find(p.id.as_str())?.pair_toggle(p.on).await?;
    Ok(true)
}

/// `agents/tool-output`: a range of a tool call's output, at most a page.
pub fn tool_output(
    f: &Front,
    _: &Caller,
    p: runstav::methods::agents::ToolOutputParams,
) -> Result<runstav::methods::agents::ToolOutput, Error> {
    let s = f.core.agents.find(p.id.as_str())?;
    let page = s
        .tool_output(&p.tool_call, p.from, p.to)
        .ok_or_else(|| invalid("tool_call", "a tool call of this session"))?;
    Ok(runstav::methods::agents::ToolOutput {
        text: page.text,
        total_bytes: page.total_bytes,
        truncated: page.truncated,
    })
}

/// `agents/pause`: the turn is cancelled once the tool call running now completes.
pub fn pause(f: &Front, _: &Caller, p: ById) -> Result<bool, Error> {
    f.core.agents.cancel_after_tool(p.id.as_str())?;
    Ok(true)
}

pub async fn kill(f: &Front, _: &Caller, p: ById) -> Result<bool, Error> {
    f.core.say.stopped(p.id.as_str());
    let r = f.core.agents.kill(p.id.as_str()).await;
    if r.is_ok() {
        gateway_gone(f, p.id.as_str()).await;
        asks_gone(f, p.id.as_str());
    }
    let _ = f.mcp.close(p.id.as_str()).await;
    r
}

/// Session SID ended: it has no current ask any more (the workers it started keep theirs), and it is in no file now.
fn asks_gone(f: &Front, sid: &str) {
    f.core
        .asks
        .handle()
        .send(crate::work::asks::AskEv::SessionGone {
            session: sid.to_string(),
        });
    let changed = f
        .core
        .presence
        .apply(crate::work::presence::PresenceEv::SessionEnd {
            session: sid.to_string(),
        });
    f.core.map.presence(&f.core.presence.now_in(&changed));
    f.core.traces.end(sid);
}

/// The sessions the hub recorded, with their folders (the presence model's rebuild at start).
pub(crate) async fn recorded(hub: &super::Hub) -> Vec<(String, PathBuf)> {
    read_rows(hub, None)
        .await
        .into_iter()
        .map(|r| (r.0, PathBuf::from(r.4)))
        .collect()
}

/// Session SID is gone: its gateway token no longer forwards and its jobs are no longer booked.
pub(crate) async fn gateway_gone(f: &Front, sid: &str) {
    for j in f.core.budgets.job_of(sid) {
        f.core.budgets.unbind_job(&j);
    }
    if let Some(t) = f.core.agents.take_gateway(sid) {
        let _ = f.gate.unregister(&t).await;
    }
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

/// How long a move waits for the tool running now to finish before it cancels the turn.
const MOVE_WAIT: Duration = Duration::from_secs(60);

pub async fn move_to(f: &Front, c: &Caller, p: MoveParams) -> Result<Started, Error> {
    if c.class != Class::User {
        return Err(refuse("only the user moves a session here"));
    }
    move_session(f, c, p.id.as_str(), p.profile.as_str()).await
}

/// What is keyed by a worker's session id follows it to NEW: the runner's scope (plan, project) for timeline steps, the
/// budget chain and the gateway's job binding, and the task claim (so the runner sees a live agent on the task and
/// starts no second worker).  The gateway registration itself is made by the new session's launch (an `:ai` profile).
/// Called with both sessions running, before the old one stops.
pub(crate) async fn rekey(front: &Front, old: &Session, new: &str) {
    let scope = front.core.runs.scope_of(&old.id);
    if let Some((plan, project)) = &scope {
        front
            .core
            .runs
            .set_scope(new, plan.clone(), project.clone());
    }
    let worker = scope_of(old.role, new);
    if let Some((plan, _)) = &scope {
        let plan_scope =
            runstav::methods::timeline::BudgetScope::Plan(runstav::types::Bounded(plan.clone()));
        front.core.budgets.link(&worker, &plan_scope);
    }
    if let Some(job) = &old.job {
        front.core.budgets.bind_job(job, &worker);
    }
    if let Some(task) = old.task.clone() {
        let (tid, new) = (task, new.to_owned());
        let r = front
            .writer
            .write(&crate::runner::service(), "agents/move", move |tx| {
                use norn::write::tasks::{entity_id, force_status};
                let missing =
                    |e: urdr::SqliteError| norn::store::CoordError::Refused(e.to_string());
                let status = urdr::graph::entity::by_id(tx.sql(), &entity_id(&tid))
                    .map_err(missing)?
                    .and_then(|e| e.status);
                match status.as_deref() {
                    Some(st @ ("claimed" | "running" | "needs-input")) => {
                        force_status(tx, &tid, st, Some(&new), now()).map(|_| ())
                    }
                    _ => Ok(()),
                }
            })
            .await;
        if let Err(e) = r {
            tracing::warn!(sid = old.id, "task claim not moved: {e}");
        }
    }
}

/// Run REKEY to its end, then FIRST: a moved worker's first prompt waits for its re-keying (grants, claim, scope).
async fn rekey_then<T>(
    rekey: impl std::future::Future<Output = ()>,
    first: impl FnOnce() -> T,
) -> T {
    rekey.await;
    first()
}

/// Session ID continues on PROFILE (Task 26): the old one stops after the tool running now, a new one starts in the
/// same worktree and is prompted with the summary handoff, the old one's entity `relates` to the new one and the
/// old one ends.  Who may call it is the caller's to decide (the user's `agents/move`; a manager's `agent_move`
/// through the matrix).
pub async fn move_session(
    front: &Front,
    caller: &Caller,
    id: &str,
    profile: &str,
) -> Result<Started, Error> {
    let hub = &front.core.agents;
    let old = hub.find(id)?;
    front.refresh_settings().await;
    if find_profile(front, profile).is_none() {
        return Err(invalid("profile", format!("no agent profile {profile:?}")));
    }
    if old.role == Role::Manager {
        return Err(refuse("a manager is not moved; it is rotated"));
    }
    // stop after the current tool, then wait for the turn to end (a turn that will not is cancelled)
    hub.cancel_after_tool(id)?;
    let end = crate::clock::now() + MOVE_WAIT;
    while old.status() == SessionStatus::Busy {
        if crate::clock::now() >= end {
            old.stop_turn();
            crate::clock::sleep(Duration::from_millis(500)).await;
            break;
        }
        crate::clock::sleep(Duration::from_millis(50)).await;
    }
    let text = super::handoff::summary(front, id, &old.cwd, old.task.as_deref(), None).await;
    let start: StartParams = serde_json::from_value(json!({
        "profile": profile,
        "cwd": old.cwd,
        "task": old.task,
        "job": old.job,
        "role": old.role,
    }))
    .map_err(|e| invalid("profile", e.to_string()))?;
    let user = Caller {
        class: Class::User,
        ..caller.clone()
    };
    // the new session keeps the old one's manager: its budget chain, and its delegation, which is on the new id
    // before the new session starts (a manager's worker stays under it, whatever the new profile's defaults are)
    let new = new_sid()?;
    if old.parent().is_some() {
        crate::manager::move_delegation(front, &old.id, &new).await;
    }
    let parent = old.parent().map(str::to_owned);
    let started = match open_as(hub, front, start, &user, parent, Some(new.clone())).await {
        Ok(s) => s,
        Err(e) => {
            front.core.matrix.drop_delegation(&new);
            if let Some(db) = hub.db() {
                delete_row(db, &new).await;
            }
            return Err(e);
        }
    };
    // nothing prompts the new session before everything keyed by the old sid is on the new one
    rekey_then(rekey(front, &old, &started.id), || {
        hub.prompt(&started.id, text, Origin::Hub)
    })
    .await?;
    let (from, to) = (format!("session:{id}"), format!("session:{}", started.id));
    let linked = front
        .writer
        .write(caller, "agents/move", move |tx| {
            use urdr::graph::{entity, link};
            let refused =
                |e: urdr::graph::WriteError| norn::store::CoordError::Refused(e.to_string());
            let missing = |e: urdr::SqliteError| norn::store::CoordError::Refused(e.to_string());
            let a = entity::by_id(tx.sql(), &from).map_err(missing)?;
            let b = entity::by_id(tx.sql(), &to).map_err(missing)?;
            if let (Some(a), Some(b)) = (a, b) {
                link::add(
                    tx,
                    a.n,
                    "relates",
                    b.n,
                    None,
                    entity::Origin::Recorded,
                    None,
                )
                .map_err(refused)?;
            }
            Ok(())
        })
        .await;
    if let Err(e) = linked {
        tracing::warn!(id, "moved session not linked: {e}");
    }
    stop(
        front,
        caller,
        ById {
            id: runstav::types::Id::new(id).map_err(|_| invalid("id", "bad id"))?,
        },
    )
    .await?;
    Ok(started)
}

/// The fuzz target `acp_update`'s entry (feature `fuzzing`): every one of UPDATES, in order, through the session's
/// reducer as the agent's `session/update` JSON; each counts once, and nothing may panic.
#[cfg(feature = "fuzzing")]
pub fn fuzz_apply(updates: &[Value]) {
    let mut st = State::new();
    for u in updates {
        st.apply(u);
    }
    assert_eq!(st.seq, updates.len() as u64);
}

/// The fuzz target `drgnx_context`'s entry (feature `fuzzing`): PARAMS as an agent's `_drgnx/context` notification
/// and as its `_drgnx/before_tool` request, from a session `s1` that offers both features. Nothing may panic; a
/// breakdown that is taken respects the bounds (at most 8 parts, 200 items each, a message within 256 KiB) and
/// survives a round trip; a message from another session is never taken.
#[cfg(feature = "fuzzing")]
pub fn fuzz_context(params: &Value) {
    let features = ["context".to_owned(), "before-tool".to_owned()];
    if let Ok(ctx) = panel::check_context(&features, "s1", "_drgnx/context", params.clone()) {
        assert!(params.to_string().len() <= 256 * 1024);
        assert_eq!(params.get("sessionId"), Some(&Value::from("s1")));
        assert!(ctx.parts.len() <= 8);
        let again = serde_json::to_value(&ctx).expect("a taken breakdown encodes");
        let mut back = again.clone();
        back["sessionId"] = Value::from("s1");
        assert_eq!(
            panel::check_context(&features, "s1", "_drgnx/context", back).ok(),
            Some(ctx)
        );
    }
    if let Ok(call) =
        panel::check_before_tool(&features, "s1", "_drgnx/before_tool", params.clone())
    {
        assert_eq!(params.get("sessionId"), Some(&Value::from("s1")));
        assert!(call.is_object());
    }
    if params.get("sessionId") != Some(&Value::from("s2")) {
        assert!(panel::check_context(&features, "s2", "_drgnx/context", params.clone()).is_err());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::budget::Budgets;
    use runstav::methods::agents::SessionStatus;
    use runstav::methods::timeline::BudgetScope;

    #[tokio::test]
    async fn rekey_runs_before_the_first_prompt() {
        let log = std::sync::Mutex::new(Vec::new());
        rekey_then(
            async {
                tokio::task::yield_now().await;
                log.lock().unwrap().push("rekey");
            },
            || log.lock().unwrap().push("prompt"),
        )
        .await;
        assert_eq!(*log.lock().unwrap(), ["rekey", "prompt"]);
    }

    #[tokio::test]
    async fn editor_endpoint_is_dropped() {
        let dir = tempfile::tempdir().unwrap();
        let f = Front::new(
            runstav::proof::Cap::generate().unwrap(),
            dir.path().join("hub-x.sock"),
            crate::store::WorkDb::spawn(dir.path().join("work.db")).unwrap(),
            norn::store::CoordDb::spawn(dir.path().join("work.db")),
        );
        let fr = &f;
        let names = move |list: Value| async move {
            fr.settings
                .set_overrides(
                    None,
                    vec![crate::settings::overrides::Override {
                        name: "drgnx-agents-start-env-names".into(),
                        value: list,
                        source: "test".into(),
                    }],
                )
                .await
                .unwrap();
        };
        let vars = |v: Value| -> Vec<EnvVar> { serde_json::from_value(v).unwrap() };
        // listed or not, the endpoint's two names are the hub's: an editor's values are dropped, the rest goes on
        names(json!([
            "PLAYWRIGHT_MCP_CDP_ENDPOINT",
            "DRGNX_BROWSER_CDP",
            "FOO"
        ]))
        .await;
        let env = vars(json!([
            {"name": "PLAYWRIGHT_MCP_CDP_ENDPOINT", "value": "ws://127.0.0.1:1/devtools/browser/x"},
            {"name": "DRGNX_BROWSER_CDP", "value": "ws://elsewhere"},
            {"name": "FOO", "value": "1"}
        ]));
        assert_eq!(
            module_env(&f, Some(env.as_slice())).unwrap(),
            [("FOO".to_string(), "1".to_string())]
        );
        names(json!([])).await;
        let env = vars(json!([{"name": "DRGNX_BROWSER_CDP", "value": "ws://elsewhere"}]));
        assert!(module_env(&f, Some(env.as_slice())).unwrap().is_empty());
    }

    #[test]
    fn a_subscription_sessions_steps_name_its_cli() {
        use crate::settings::profiles::Provider;
        let p = |ai: Option<&str>, provider: Option<Provider>, cmd: &str| AgentProfile {
            name: "t".into(),
            command: vec![cmd.into()],
            env: vec![],
            mode: None,
            ai: ai.map(String::from),
            model: None,
            tracker_tools: None,
            doc: None,
            provider,
            job_safe: false,
        };
        let gemini = p(None, Some(Provider::Gemini), "/bin/mock");
        assert_eq!(step_provider(&gemini).as_deref(), Some("gemini"));
        assert_eq!(
            step_provider(&p(None, None, "/usr/bin/claude")).as_deref(),
            Some("claude")
        );
        let gw = p(
            Some("claude-openrouter"),
            Some(Provider::Claude),
            "/bin/mock",
        );
        assert_eq!(step_provider(&gw).as_deref(), Some("claude-openrouter"));
        assert_eq!(step_provider(&p(None, None, "/bin/other")), None);
        // the matrix column stays the gateway environment only
        assert_eq!(who_of(Role::Worker, &gemini).provider, None);
    }

    fn upd(v: Value) -> Value {
        v
    }

    /// A cost reading TOTAL of conversation CONV, as `Session::handle` books it: the budget's delta is also the turn's.
    fn read_cost(b: &Budgets, st: &mut State, conv: &str, total: f64) {
        let scope: BudgetScope = serde_json::from_value(json!({"worker": "w1"})).unwrap();
        let booked = b.spend_total_in(&scope, "usd-est", conv, Unit::UsdEst, total);
        st.add_turn_cost(booked.delta);
    }

    fn spent_est(b: &Budgets) -> f64 {
        let scope: BudgetScope = serde_json::from_value(json!({"worker": "w1"})).unwrap();
        b.view(&scope)
            .spent
            .into_iter()
            .find(|l| l.unit == Unit::UsdEst)
            .map_or(0.0, |l| l.amount)
    }

    // test-pattern: D
    #[test]
    fn a_turns_cost_is_what_the_budget_booked_in_it() {
        let (b, mut st) = (Budgets::default(), State::new());
        read_cost(&b, &mut st, "c1", 0.10);
        let first = st.take_turn_cost().unwrap();
        assert!((first - 0.10).abs() < 1e-9, "{first}");
        read_cost(&b, &mut st, "c1", 0.25);
        let second = st.take_turn_cost().unwrap();
        assert!((second - 0.15).abs() < 1e-9, "{second}");
    }

    // test-pattern: D
    #[test]
    fn a_step_keeps_the_context_at_its_close() {
        let mut st = State::new();
        st.step_begin(StepClass::Think, None);
        st.step_close(now(), None);
        st.apply(&upd(
            json!({"sessionUpdate": "usage_update", "used": 300000, "size": 1000000}),
        ));
        st.step_begin(StepClass::Think, None);
        st.step_close(now(), Some(TurnUse::default()));
        st.step_begin(StepClass::JobWait, None);
        st.step_close(now(), None);
        st.step_begin(StepClass::Tool, None);
        st.step_close(now(), None);
        let got: Vec<Option<i64>> = st.closed.iter().map(|c| c.context).collect();
        assert_eq!(got, [None, Some(300000), Some(300000), None]);
    }

    // test-pattern: D
    #[test]
    fn no_cost_reported_leaves_the_step_unpriced() {
        let mut st = State::new();
        st.apply(&upd(
            json!({"sessionUpdate": "usage_update", "used": 10, "size": 100}),
        ));
        assert_eq!(st.take_turn_cost(), None);
        let b = Budgets::default();
        read_cost(&b, &mut st, "c1", 0.10);
        st.take_turn_cost();
        // a turn in which the total did not move has no cost, not 0.0
        read_cost(&b, &mut st, "c1", 0.10);
        assert_eq!(st.take_turn_cost(), None);
    }

    // test-pattern: D
    #[test]
    fn the_step_and_the_budget_book_the_same_delta() {
        let (b, mut st) = (Budgets::default(), State::new());
        read_cost(&b, &mut st, "a", 0.10);
        let one = st.take_turn_cost().unwrap();
        // a new conversation starts at its own first reading, even above the old total
        read_cost(&b, &mut st, "b", 0.30);
        let two = st.take_turn_cost().unwrap();
        assert!((two - 0.30).abs() < 1e-9, "{two}");
        assert!((spent_est(&b) - (one + two)).abs() < 1e-9);
    }

    // test-pattern: D
    #[test]
    fn a_fork_that_reports_its_parents_total_is_booked_alike() {
        let (b, mut st) = (Budgets::default(), State::new());
        read_cost(&b, &mut st, "a", 0.10);
        let one = st.take_turn_cost().unwrap();
        read_cost(&b, &mut st, "b", 0.15);
        let two = st.take_turn_cost().unwrap();
        assert!((two - 0.15).abs() < 1e-9, "{two}");
        assert!((spent_est(&b) - (one + two)).abs() < 1e-9);
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
            flow: Arc::default(),
            session: "a1".into(),
            task: Some("task:7".into()),
            agent: "mock".into(),
            provider: None,
            cwd: PathBuf::new(),
            acp: None,
            history: None,
        };
        let sink = StepSink {
            writer: writer.clone(),
            editors,
            bus,
            snap: None,
            scopes: None,
            tools: None,
            asks: None,
            stamps: None,
            presence: None,
            map: None,
            traces: None,
        };
        tokio::spawn(write_steps(rx, sink, ctx));
        let open = |class, tool: Option<&str>| OpenStep {
            class,
            start: 10.0,
            tool: tool.map(str::to_string),
            tool_kind: None,
            tool_id: None,
            message_id: None,
            key: 0,
            mcp: false,
            parent_tool: None,
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
                detail: None,
                command: None,
                context: None,
                before: None,
                call_end: None,
                diffs: Vec::new(),
                cell: None,
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

    // test-pattern: D
    #[tokio::test]
    async fn the_step_event_carries_the_unit() {
        let dir = tempfile::tempdir().unwrap();
        let writer = crate::coord::Writer {
            db: norn::store::CoordDb::spawn(dir.path().join("work.db")),
            signals: Arc::new(crate::coord::Signals::default()),
        };
        let (bus, mut seen) = tokio::sync::broadcast::channel(16);
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let ctx = StepCtx {
            flow: Arc::default(),
            session: "a1".into(),
            task: Some("task:7".into()),
            agent: "mock".into(),
            provider: None,
            cwd: PathBuf::new(),
            acp: None,
            history: None,
        };
        let sink = StepSink {
            writer: writer.clone(),
            editors: Arc::new(crate::settings::agents::Editors::default()),
            bus,
            snap: None,
            scopes: None,
            tools: None,
            asks: None,
            stamps: None,
            presence: None,
            map: None,
            traces: None,
        };
        tokio::spawn(write_steps(rx, sink, ctx));
        for cost in [Some(0.15), None] {
            tx.send(ClosedStep {
                open: OpenStep {
                    class: StepClass::Think,
                    start: 10.0,
                    tool: None,
                    tool_kind: None,
                    tool_id: None,
                    message_id: None,
                    key: 0,
                    mcp: false,
                    parent_tool: None,
                },
                end: 11.0,
                turn_id: None,
                tokens_in: 1,
                tokens_out: 1,
                cache_read: 0,
                cache_write: 0,
                cost,
                detail: None,
                command: None,
                context: None,
                before: None,
                call_end: None,
                diffs: Vec::new(),
                cell: None,
            })
            .unwrap();
        }
        let priced = seen.recv().await.unwrap().step;
        let unpriced = seen.recv().await.unwrap().step;
        assert_eq!(priced.cost_unit, Some(Unit::UsdEst));
        assert_eq!(unpriced.cost_unit, None);
    }

    // test-pattern: D
    #[tokio::test]
    async fn an_edit_step_anchors_the_history_record_of_its_write() {
        let dir = tempfile::tempdir().unwrap();
        let work = dir.path().join("work");
        std::fs::create_dir_all(&work).unwrap();
        std::fs::create_dir_all(dir.path().join("state")).unwrap();
        let git = |args: &[&str]| {
            assert!(
                std::process::Command::new("git")
                    .args(["-c", "user.name=t", "-c", "user.email=t@t"])
                    .args(["-c", "commit.gpgsign=false"])
                    .args(args)
                    .current_dir(&work)
                    .env("GIT_CONFIG_GLOBAL", "/dev/null")
                    .env("GIT_CONFIG_NOSYSTEM", "1")
                    .status()
                    .unwrap()
                    .success()
            )
        };
        git(&["init", "-q", "-b", "main"]);
        std::fs::write(work.join("a.txt"), "one\n").unwrap();
        git(&["add", "."]);
        git(&["commit", "-q", "-m", "base"]);
        let hubs = Arc::new(crate::history::wire::Hubs::default());
        let state = dir.path().join("state");
        let (hub, tree) = hubs.of_tree(&state, &work).unwrap();
        let cause = verdandi::Cause {
            session: Some("a1".into()),
            ..Default::default()
        };
        let made = hub
            .on_agent_write(&tree, "a.txt", b"one\ntwo\n", "a1", cause, 10.5)
            .unwrap();
        let writer = crate::coord::Writer {
            db: norn::store::CoordDb::spawn(dir.path().join("work.db")),
            signals: Arc::new(crate::coord::Signals::default()),
        };
        let (bus, mut seen) = tokio::sync::broadcast::channel(16);
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let ctx = StepCtx {
            flow: Arc::default(),
            session: "a1".into(),
            task: None,
            agent: "mock".into(),
            provider: None,
            cwd: work.clone(),
            acp: None,
            history: Some((hubs.clone(), state)),
        };
        let sink = StepSink {
            writer,
            editors: Arc::new(crate::settings::agents::Editors::default()),
            bus,
            snap: None,
            scopes: None,
            tools: None,
            asks: None,
            stamps: None,
            presence: None,
            map: None,
            traces: None,
        };
        tokio::spawn(write_steps(rx, sink, ctx));
        for (kind, end) in [("edit", 11.0), ("read", 12.0)] {
            tx.send(ClosedStep {
                open: OpenStep {
                    class: StepClass::Tool,
                    start: end - 0.5,
                    tool: Some(format!("{kind} a.txt")),
                    tool_kind: Some(kind.into()),
                    tool_id: None,
                    message_id: None,
                    key: 0,
                    mcp: false,
                    parent_tool: None,
                },
                end,
                turn_id: None,
                tokens_in: 1,
                tokens_out: 1,
                cache_read: 0,
                cache_write: 0,
                cost: None,
                detail: None,
                command: None,
                context: None,
                before: None,
                call_end: None,
                diffs: Vec::new(),
                cell: None,
            })
            .unwrap();
        }
        let edit = seen.recv().await.unwrap().step;
        let read = seen.recv().await.unwrap().step;
        assert_eq!(edit.history_op, Some(made[0].op as u64));
        assert!(edit.revertible);
        assert_eq!(read.history_op, None, "a read step anchors no record");
    }

    // test-pattern: D (the step's row cannot be written: its store's folder is a file)
    #[tokio::test]
    async fn an_edit_step_whose_row_is_lost_closes_its_checkpoint() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("not-a-folder"), "").unwrap();
        let writer = crate::coord::Writer {
            db: norn::store::CoordDb::spawn(dir.path().join("not-a-folder/work.db")),
            signals: Arc::new(crate::coord::Signals::default()),
        };
        let wt = dir.path().join("wt");
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join("a.txt"), "edited").unwrap();
        let snap = crate::timeline::Snap::for_test(
            dir.path().join("cp"),
            Arc::new(crate::settings::Settings::new()),
        );
        let (bus, mut seen) = tokio::sync::broadcast::channel(16);
        let sink = StepSink {
            writer,
            editors: Arc::new(crate::settings::agents::Editors::default()),
            bus,
            snap: Some(snap.clone()),
            scopes: None,
            tools: None,
            asks: None,
            stamps: None,
            presence: None,
            map: None,
            traces: None,
        };
        let ctx = StepCtx {
            flow: Arc::default(),
            session: "a1".into(),
            task: None,
            agent: "mock".into(),
            provider: None,
            cwd: wt.clone(),
            acp: None,
            history: None,
        };
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        tokio::spawn(write_steps(rx, sink, ctx));
        let cell = crate::timeline::EditCell::default();
        tx.send(ClosedStep {
            open: OpenStep {
                class: StepClass::Tool,
                start: 1.0,
                tool: Some("Edit a.txt".into()),
                tool_kind: Some("edit".into()),
                tool_id: None,
                message_id: None,
                key: 0,
                mcp: false,
                parent_tool: None,
            },
            end: 2.0,
            turn_id: None,
            tokens_in: 1,
            tokens_out: 1,
            cache_read: 0,
            cache_write: 0,
            cost: None,
            detail: None,
            command: None,
            context: None,
            call_end: None,
            diffs: Vec::new(),
            cell: Some(cell.clone()),
            before: None,
        })
        .unwrap();
        // the step is announced though its row is lost
        seen.recv().await.unwrap();
        assert!(cell.is_done(), "the lost step's checkpoint is closed");
        // so the agent's next write takes no tree for it
        snap.before_write("a1", &wt, vec![cell]).await;
        let repo = crate::timeline::snapshot::repo_of(&dir.path().join("cp"), &wt);
        let refs = if repo.exists() {
            let out = std::process::Command::new("git")
                .arg("--git-dir")
                .arg(&repo)
                .args(["for-each-ref", "--format=%(refname)"])
                .output()
                .unwrap();
            String::from_utf8_lossy(&out.stdout).trim().to_owned()
        } else {
            String::new()
        };
        assert_eq!(refs, "", "no tree is held for a step nobody keeps");
    }

    /// Three steps of a turn through the writer: a think, an edit tool call, the turn's last think (with the turn id).
    async fn written_turn(
        dir: &Path,
    ) -> (crate::coord::Writer, Vec<norn::read::steps::Step>, PathBuf) {
        let writer = crate::coord::Writer {
            db: norn::store::CoordDb::spawn(dir.join("work.db")),
            signals: Arc::new(crate::coord::Signals::default()),
        };
        let wt = dir.join("wt");
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join("a.txt"), "edited").unwrap();
        std::fs::write(wt.join(".env"), "KEY=1").unwrap();
        let settings = Arc::new(crate::settings::Settings::new());
        let sink = StepSink {
            writer: writer.clone(),
            editors: Arc::new(crate::settings::agents::Editors::default()),
            bus: tokio::sync::broadcast::channel(16).0,
            snap: Some(crate::timeline::Snap::for_test(dir.join("cp"), settings)),
            scopes: None,
            tools: None,
            asks: None,
            stamps: None,
            presence: None,
            map: None,
            traces: None,
        };
        let ctx = StepCtx {
            flow: Arc::default(),
            session: "a1".into(),
            task: Some("task:7".into()),
            agent: "mock".into(),
            provider: None,
            cwd: wt.clone(),
            acp: None,
            history: None,
        };
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let done = tokio::spawn(write_steps(rx, sink, ctx));
        let open = |class, kind: Option<&str>, start| OpenStep {
            class,
            start,
            tool: kind.map(|_| "Edit a.txt".to_string()),
            tool_kind: kind.map(str::to_string),
            tool_id: None,
            message_id: Some("m1".into()),
            key: 0,
            mcp: false,
            parent_tool: None,
        };
        for (o, end, turn) in [
            (open(StepClass::Think, None, 1.0), 2.0, None),
            (open(StepClass::Tool, Some("edit"), 2.0), 5.0, None),
            (open(StepClass::Think, None, 5.0), 6.0, Some("turn-1")),
        ] {
            tx.send(ClosedStep {
                open: o,
                end,
                turn_id: turn.map(str::to_string),
                tokens_in: 1,
                tokens_out: 2,
                cache_read: 0,
                cache_write: 0,
                cost: None,
                detail: None,
                command: None,
                context: None,
                before: None,
                call_end: None,
                diffs: Vec::new(),
                cell: None,
            })
            .unwrap();
        }
        drop(tx);
        done.await.unwrap();
        let steps = writer
            .db
            .read(|c| norn::read::steps::for_session(c, "session:a1", 0))
            .await
            .unwrap();
        (writer, steps, wt)
    }

    #[tokio::test]
    async fn timeline_every_step_has_its_anchors() {
        let dir = tempfile::tempdir().unwrap();
        let (_, steps, _) = written_turn(dir.path()).await;
        assert_eq!(steps.len(), 3);
        for s in &steps {
            assert_eq!(s.message_id.as_deref(), Some("m1"), "{s:?}");
            assert_eq!(s.turn_id.as_deref(), Some("turn-1"), "{s:?}");
            assert_eq!(s.log_version, Some(0), "{s:?}");
        }
        // a snapshot at the turn's first step and after the completed edit, not after the last think
        assert!(steps[0].snapshot.is_some() && steps[2].snapshot.is_none());
        let tree = steps[1].snapshot.clone().expect("the edit's snapshot");
        let repo =
            crate::timeline::snapshot::repo_of(&dir.path().join("cp"), &dir.path().join("wt"));
        let out = std::process::Command::new("git")
            .args(["--git-dir"])
            .arg(&repo)
            .args(["ls-tree", "-r", "--name-only", &tree])
            .output()
            .unwrap();
        assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "a.txt");
    }

    #[tokio::test]
    async fn timeline_rollup_matches_steps() {
        let dir = tempfile::tempdir().unwrap();
        let (writer, steps, _) = written_turn(dir.path()).await;
        let roll = writer
            .db
            .read(|c| norn::read::steps::rollup(c, norn::read::steps::Scope::Session, "session:a1"))
            .await
            .unwrap();
        let sum = |class: &str| -> f64 {
            steps
                .iter()
                .filter(|s| s.class.as_str() == class)
                .map(|s| s.end.unwrap() - s.start)
                .sum()
        };
        assert_eq!(roll.secs_by_class["think"], sum("think"));
        assert_eq!(roll.secs_by_class["tool"], sum("tool"));
        assert_eq!(roll.tokens.input, 3);
        assert_eq!(roll.tokens.output, 6);
    }

    #[test]
    fn timeline_permission_wait_is_user_wait() {
        let mut st = State::new();
        st.apply(&upd(
            json!({"sessionUpdate": "agent_message_chunk", "messageId": "m9",
            "content": {"type": "text", "text": "go"}}),
        ));
        st.apply(&upd(
            json!({"sessionUpdate": "tool_call", "toolCallId": "t1",
            "title": "Edit x", "kind": "edit", "status": "in_progress"}),
        ));
        st.wait_begin();
        st.permissions.clear();
        st.wait_end();
        st.step_close(now(), None);
        let got: Vec<(StepClass, Option<&str>)> = st
            .closed
            .iter()
            .map(|c| (c.open.class, c.open.message_id.as_deref()))
            .collect();
        assert_eq!(
            got,
            [
                (StepClass::Think, Some("m9")),
                (StepClass::Tool, Some("m9")),
                (StepClass::UserWait, Some("m9")),
                (StepClass::Tool, Some("m9")),
            ]
        );
    }

    #[test]
    fn a_hold_cancels_when_the_tool_call_completes_and_holds_the_queue() {
        let mut st = State::new();
        st.core.ready(false);
        st.turn_step(TurnEvent::Send {
            item: Queued {
                text: "go".into(),
                origin: Origin::User,
                steer: false,
                key: None,
            },
            steer_mode: false,
            if_free: false,
        });
        st.turn_step(TurnEvent::Stop { after_tool: true });
        st.apply(&upd(
            json!({"sessionUpdate": "tool_call", "toolCallId": "t1",
            "title": "Run", "kind": "execute", "status": "in_progress"}),
        ));
        assert!(!st.tool_ended && !st.core.paused());
        st.apply(&upd(
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1",
            "status": "completed"}),
        ));
        assert!(std::mem::take(&mut st.tool_ended));
        let s = st.turn_step(TurnEvent::ToolCompleted);
        assert!(s.fx.contains(&TurnEffect::CancelTurn) && st.core.paused());
        let again = st.turn_step(TurnEvent::ToolCompleted);
        assert!(again.fx.is_empty(), "the hold cancels once");
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
        assert_eq!(st.core.status(), SessionStatus::Starting);
    }

    /// [D] Only a chat in a project goes to the pair door: a worker's or a manager's `fs/write_text_file` keeps the
    /// session fence and its inline write, as do a chat in its scratch folder and a brainstorm.
    #[test]
    fn a_workers_fs_write_keeps_the_fence() {
        for role in [Role::Worker, Role::Manager] {
            assert!(!is_project_chat(role, false, false), "{role:?}");
        }
        assert!(!is_project_chat(Role::Chat, false, true), "a scratch chat");
        assert!(!is_project_chat(Role::Chat, true, false), "a brainstorm");
        assert!(is_project_chat(Role::Chat, false, false));
        // the fence still writes a worker's own worktree inline
        let dir = tempfile::tempdir().unwrap();
        let f = Fence {
            cwd: dir.path().to_path_buf(),
            document: None,
            read_only: false,
            held: false,
        };
        assert!(
            f.check(&dir.path().join("a.rs").to_string_lossy(), true)
                .is_ok()
        );
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
            read_only: false,
            held: false,
        };
        let s = |p: &Path| p.to_string_lossy().into_owned();
        assert!(f.check(&s(&cwd.join("a.txt")), true).is_ok());
        assert!(f.check(&s(&cwd.join("sub/new.txt")), true).is_ok());
        assert!(f.check(&s(&dir.path().join("secret")), false).is_err());
        assert!(f.check(&s(&cwd.join("../secret")), false).is_err());
        assert!(f.check(&s(&cwd.join("link")), false).is_err());
        assert!(f.check("relative.txt", false).is_err());
        // while the user holds the wheel nothing is written; reads stay
        let held = Fence {
            cwd: cwd.clone(),
            document: None,
            read_only: false,
            held: true,
        };
        let refused = held.check(&s(&cwd.join("a.txt")), true).unwrap_err();
        assert!(refused.contains(wheel::HELD), "{refused}");
        assert!(held.check(&s(&cwd.join("a.txt")), false).is_ok());
    }

    #[test]
    fn a_brainstorm_writes_only_its_document() {
        let dir = tempfile::tempdir().unwrap();
        let doc = dir.path().join("design.md");
        let f = Fence {
            cwd: dir.path().to_path_buf(),
            document: Some(doc.clone()),
            read_only: true,
            held: false,
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
    fn a_chat_in_a_project_reads_it_and_writes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let f = Fence {
            cwd: dir.path().to_path_buf(),
            document: None,
            read_only: true,
            held: false,
        };
        let src = dir.path().join("src.rs");
        assert!(f.check(&src.to_string_lossy(), false).is_ok());
        let refused = f.check(&src.to_string_lossy(), true).unwrap_err();
        assert!(refused.contains("writes nothing"), "{refused}");
    }

    /// The editor's agents panel and review start a session with a profile and a project cwd and nothing else: that
    /// is a chat, and it goes to the project chat's launch, never to `launch::spawn` (which refuses a chat).
    #[test]
    fn a_start_with_a_project_and_no_task_is_a_project_chat() {
        use launch::Kind;
        let (project, scratch) = (Path::new("/p/proj"), Path::new("/t/scratch/S1"));
        let role = start_role(None, false);
        assert_eq!(role, Role::Chat);
        assert_eq!(launch::kind(role, project, scratch), Kind::Chat);
        assert_eq!(launch::kind(role, scratch, scratch), Kind::Plain);
        let worker = start_role(None, true);
        assert_eq!(worker, Role::Worker);
        assert_eq!(launch::kind(worker, project, scratch), Kind::Worktree);
        assert_eq!(
            launch::kind(start_role(Some(Role::Chat), true), project, scratch),
            Kind::Chat
        );
    }

    /// A chat in a project starts under the shipped presets (`chat.project-read` asks) and is refused, naming the row,
    /// when your matrix says never for it; the row does not apply to a plain chat or a worker.
    #[test]
    fn a_project_chat_is_refused_when_chat_project_read_is_never() {
        use launch::Kind;
        use norn::matrix::{Cell, Column, Matrix, Preset, Verdict, effective, preset};
        let who = Who {
            role: Some(Role::Chat),
            agent: Some("claude".into()),
            provider: None,
        };
        for p in [Preset::Cautious, Preset::Balanced, Preset::Autonomous] {
            let eff = effective(&[&preset(p)], &who);
            assert!(project_read_allowed(Kind::Chat, &eff).is_ok(), "{p:?}");
        }
        let mut mine = Matrix::default();
        let never = Cell {
            verdict: Verdict::Never,
            limit: None,
        };
        // your matrix's chat column, over the preset's
        mine.set(Action::ChatProjectRead, Column::Role(Role::Chat), never);
        let eff = effective(&[&preset(Preset::Balanced), &mine], &who);
        let refused = project_read_allowed(Kind::Chat, &eff).unwrap_err();
        assert!(
            refused.message.contains("chat.project-read is never")
                && refused.message.contains("start it without a project"),
            "{}",
            refused.message
        );
        assert!(project_read_allowed(Kind::Plain, &eff).is_ok());
        assert!(project_read_allowed(Kind::Worktree, &eff).is_ok());
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

#[cfg(test)]
mod wait_tests {
    use super::*;

    fn exec(command: &str) -> Value {
        json!({"kind": "execute", "title": command, "rawInput": {"command": command}})
    }

    #[test]
    fn waits_and_polls_are_wait_loops_other_commands_are_not() {
        for c in [
            "sleep 30; pgrep -f x",
            "until test -f done; do :; done",
            "tail -f build.log",
            "watch -n1 ls",
            "cargo test && sleep 5",
        ] {
            assert!(is_wait_loop(Some(&exec(c))), "{c}");
        }
        for c in [
            "cargo test",
            "git status",
            "tail -n 5 build.log",
            "echo sleepy",
        ] {
            assert!(!is_wait_loop(Some(&exec(c))), "{c}");
        }
        let read = json!({"kind": "read", "title": "sleep.txt"});
        assert!(!is_wait_loop(Some(&read)) && !is_wait_loop(None));
    }
}
