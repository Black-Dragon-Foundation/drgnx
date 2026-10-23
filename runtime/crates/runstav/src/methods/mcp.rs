//! MCP hosting (docs/develop/hub.md, "Sessions and their sockets"): the coordination tools on a socket per session,
//! which the front mints, and on the main socket for an outside agent's bridge.  Every method here is the front's own.
//!
//! - `mcp/session`: a session's `mcp.sock` in its directory (`runstav::paths::session_dir`); the socket is the
//!   identity of whoever connects to it.
//! - `mcp/session-close`: that socket and its directory gone.
//! - `mcp/attach`: a bridge for an agent outside drgnx turns its connection to MCP; its identity is the hub's to
//!   compute from the peer process, never a claim.

use super::method;
use crate::registry::Method;
use crate::types::{AbsPath, AgentKind, AgentName, Id, SessionId, TaskRef};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SessionParams {
    /// The agent's id: what every tool on the socket acts as.
    pub agent: AgentName,
    /// The session's directory when it has one already (its agent `hub.sock`); else the hub mints the id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sid: Option<SessionId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<TaskRef>,
    /// The folder the agent works in (the tools' `home`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<AbsPath>,
    /// The pid of the process the session belongs to: the session is closed when it is gone.
    pub owner: u64,
}

/// `mcp/session`'s answer: the session's id and the socket to connect to.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SessionAnswer {
    pub sid: String,
    pub socket: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SessionCloseParams {
    pub sid: SessionId,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct AttachParams {
    pub kind: AgentKind,
}

/// `mcp/attach`'s answer: the identity the connection's tools act as; MCP lines follow it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AttachAnswer {
    pub identity: String,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "mcp/session", McpSession(SessionParams) -> SessionAnswer,
            classes: [User], writes: false, home: Front,
            doc: "the coordination tools on a session's own mcp.sock (the socket is the identity), kept in runtime.db and closed with its owner",
        ),
        method!(
            "mcp/session-close", McpSessionClose(SessionCloseParams) -> bool,
            classes: [User], writes: false, home: Front,
            doc: "a session's mcp.sock and its directory gone (false: no such session)",
        ),
        method!(
            "mcp/attach", McpAttach(AttachParams) -> AttachAnswer,
            classes: [Service], writes: false, home: Front,
            doc: "an outside agent's bridge: the connection carries MCP after the answer, as ext:KIND:PID-HASH from the peer process",
        ),
    ]
}
