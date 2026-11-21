//! The types hermod's callers see.

use crate::incoming::Incoming;
use crate::schema::v1;
use serde_json::Value;
use std::fmt;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub use v1::{
    AgentCapabilities, AuthMethod, ClientCapabilities as ClientCaps, ContentBlock, McpServer,
    SessionId, SessionUpdate, StopReason, Usage,
};

/// How a connection behaves.  `deadline` bounds every call but `prompt` (a turn ends by its response, `cancel` or
/// the child's exit); `stderr_tail` is how many characters of the child's stderr [`Event::Exit`] carries; `tap`, when
/// set, is told every line in both directions and the exit ([`LineTap`]).
#[derive(Clone)]
pub struct ConnOpts {
    pub deadline: Duration,
    pub stderr_tail: usize,
    pub tap: Option<Arc<dyn LineTap>>,
    /// Ask the agent for ACP v2 (a draft): an agent that answers 1 gets v1 on the same connection, silently.
    pub v2: bool,
}

impl Default for ConnOpts {
    fn default() -> Self {
        ConnOpts {
            deadline: Duration::from_secs(30),
            stderr_tail: 4000,
            tap: None,
            v2: false,
        }
    }
}

/// The ACP version a connection speaks, as `initialize` settled it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Proto {
    V1,
    V2,
}

impl fmt::Debug for ConnOpts {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConnOpts")
            .field("deadline", &self.deadline)
            .field("stderr_tail", &self.stderr_tail)
            .field("tap", &self.tap.is_some())
            .field("v2", &self.v2)
            .finish()
    }
}

/// Which way a line went: `In` to the agent (written to its stdin), `Out` from it (read from its stdout).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dir {
    In,
    Out,
}

/// Sees a connection's lines as they pass (a recording).  `line` runs on the connection's own writer or reader task,
/// before the line is written or handled, so the order of one direction is the wire's and an answer is never seen
/// before its request; it must not wait long.  `exit` runs once, after the last line, with the child's status and
/// the stderr tail that [`Event::Exit`] carries.
pub trait LineTap: Send + Sync {
    fn line(&self, dir: Dir, line: &str, at: Instant);
    fn exit(&self, code: Option<i32>, signal: Option<i32>, stderr: &str) {
        let _ = (code, signal, stderr);
    }
}

/// What `initialize` answered.
#[derive(Clone, Debug)]
pub struct AgentInfo {
    /// What the agent calls itself (`agentInfo`): its name and version.
    pub name: Option<String>,
    pub version: Option<String>,
    pub caps: AgentCapabilities,
    pub meta: Option<Value>,
    pub auth: Vec<AuthMethod>,
    /// The version the connection speaks from here on.
    pub proto: Proto,
    /// Why a connection that asked for v2 speaks v1: the agent rejected the v2 `initialize` with an error and was
    /// asked again as v1 (its message).  None: no fallback (v1 asked, or the agent answered 1 or 2).
    pub v2_fallback: Option<String>,
}

/// How a turn ended.  `turn_id` is `_meta.turnId` of the answer, when the agent sends one.
#[derive(Clone, Debug)]
pub struct PromptOutcome {
    pub stop: StopReason,
    pub usage: Option<Usage>,
    pub turn_id: Option<String>,
}

/// Where to fork: after the message with this id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ForkPoint {
    pub message_id: String,
}

/// A fork of session SOURCE into a session in CWD with the tools MCP, at AT (none: its end).  META is the caller's
/// `_meta` (a lock's options); the fork point is merged into it.  The connection need not have seen SOURCE: a fresh
/// process forks what the agent kept on disk.
#[derive(Clone, Debug)]
pub struct ForkInto {
    pub source: SessionId,
    pub cwd: std::path::PathBuf,
    pub mcp: Vec<McpServer>,
    pub at: Option<ForkPoint>,
    pub meta: Option<Value>,
}

/// What a connection tells its owner.  `Exit` comes exactly once, after every update the child wrote.
pub enum Event {
    Update {
        /// Seconds since the epoch, stamped when the line was read.
        at: f64,
        sid: SessionId,
        update: SessionUpdate,
        /// The `messageId` of a message chunk.
        message_id: Option<String>,
    },
    Request(Incoming),
    /// ACP v2: a whole-message upsert (`user_message`, `agent_message`, `agent_thought`): the message MESSAGE_ID has
    /// exactly this content now (`null`: none), whatever chunks it had.
    Replace {
        at: f64,
        sid: SessionId,
        message_id: String,
        kind: MessageKind,
        content: Value,
    },
    /// ACP v2: a session's foreground state, with its background list when the agent reports one (`None`: it does
    /// not; `Some(vec![])`: nothing runs).  The turn's end is the prompt's answer, not this.
    State {
        at: f64,
        sid: SessionId,
        state: RunState,
        background: Option<Vec<BackgroundRef>>,
    },
    /// ACP v2: a display terminal's update or output bytes.
    Terminal {
        at: f64,
        sid: SessionId,
        id: String,
        update: TerminalEv,
    },
    /// ACP v2: a child session announced or updated (the raw `subagent_update`).
    Subagent {
        at: f64,
        sid: SessionId,
        child: SessionId,
        update: Value,
    },
    /// A notification outside the schema whose method starts with `_` (an agent's own extension, e.g.
    /// `_claude/rateLimit`, `_codex/rateLimits`); anything else the schema does not know is dropped.
    Ext {
        method: String,
        params: Value,
    },
    Exit {
        code: Option<i32>,
        signal: Option<i32>,
        stderr: String,
    },
}

/// Which kind of message a whole-message upsert is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MessageKind {
    User,
    Agent,
    Thought,
}

/// ACP v2's foreground state.  `Unknown`: the agent cannot tell (never taken for idle or done).
#[derive(Clone, Debug, PartialEq)]
pub enum RunState {
    Running,
    RequiresAction,
    Idle(Option<StopReason>),
    Unknown,
}

/// One item of a v2 background list.  `Other` is a type this code does not know: it still counts as running work.
#[derive(Clone, Debug, PartialEq)]
pub enum BackgroundRef {
    Terminal(String),
    ToolCall(String),
    Subagent(SessionId),
    Other(Value),
}

/// A display terminal's news: fields the agent sent (a `None` is "not sent", not "cleared"), or bytes appended.
#[derive(Clone, Debug, PartialEq)]
pub enum TerminalEv {
    Update {
        command: Option<String>,
        cwd: Option<String>,
        /// The whole output so far, replacing what was kept.
        snapshot: Option<Vec<u8>>,
        /// Exit code and signal.
        exit: Option<(Option<i32>, Option<String>)>,
        can_cancel: Option<bool>,
    },
    /// Bytes appended, decoded per chunk.
    Chunk(Vec<u8>),
}

#[derive(Debug)]
pub enum Error {
    /// The program that would not start (its name, as the profile gives it), and why.
    Spawn(String, std::io::Error),
    /// The child is gone or its stdin is closed.
    Closed,
    /// The call got no answer within `ConnOpts::deadline` (the method).  The connection is unharmed.
    Deadline(String),
    /// The agent answered with a JSON-RPC error.
    Rpc {
        code: i64,
        message: String,
        data: Option<Value>,
    },
    /// An answer that does not fit the schema.
    Decode(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Spawn(program, e) if e.kind() == std::io::ErrorKind::NotFound => write!(
                f,
                "cannot start the agent: {program} is not installed (run \"Onboarding: Agents\" to set it up)"
            ),
            Error::Spawn(program, e) => write!(f, "cannot start the agent {program}: {e}"),
            Error::Closed => write!(f, "the agent has exited"),
            Error::Deadline(m) => write!(f, "{m}: no answer in time"),
            Error::Rpc { code, message, .. } => write!(f, "agent error {code}: {message}"),
            Error::Decode(m) => write!(f, "undecodable answer: {m}"),
        }
    }
}

impl std::error::Error for Error {}
