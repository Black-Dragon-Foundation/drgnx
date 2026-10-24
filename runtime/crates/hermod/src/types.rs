//! The types hermod's callers see.

use crate::incoming::Incoming;
use crate::schema::v1;
use serde_json::Value;
use std::fmt;
use std::time::Duration;

pub use v1::{
    AgentCapabilities, AuthMethod, ClientCapabilities as ClientCaps, ContentBlock, McpServer,
    SessionId, SessionUpdate, StopReason, Usage,
};

/// How a connection behaves.  `deadline` bounds every call but `prompt` (a turn ends by its response, `cancel` or
/// the child's exit); `stderr_tail` is how many characters of the child's stderr [`Event::Exit`] carries.
#[derive(Clone, Copy, Debug)]
pub struct ConnOpts {
    pub deadline: Duration,
    pub stderr_tail: usize,
}

impl Default for ConnOpts {
    fn default() -> Self {
        ConnOpts {
            deadline: Duration::from_secs(30),
            stderr_tail: 4000,
        }
    }
}

/// What `initialize` answered.
#[derive(Clone, Debug)]
pub struct AgentInfo {
    pub caps: AgentCapabilities,
    pub meta: Option<Value>,
    pub auth: Vec<AuthMethod>,
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

#[derive(Debug)]
pub enum Error {
    Spawn(std::io::Error),
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
    /// `fork` or a call needing a session's directory named one this connection never opened.
    UnknownSession(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Spawn(e) => write!(f, "cannot start the agent: {e}"),
            Error::Closed => write!(f, "the agent has exited"),
            Error::Deadline(m) => write!(f, "{m}: no answer in time"),
            Error::Rpc { code, message, .. } => write!(f, "agent error {code}: {message}"),
            Error::Decode(m) => write!(f, "undecodable answer: {m}"),
            Error::UnknownSession(s) => write!(f, "unknown session {s}"),
        }
    }
}

impl std::error::Error for Error {}
