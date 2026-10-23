//! The hub's own methods: `hello`, `ping`, `status`, the subscription, the event log, `env/set`, ending and
//! restarting.

use super::gateway::ProviderWarning;
use super::{Empty, method};
use crate::registry::{Class, Method};
use crate::types::{AbsPath, Bounded, EnvName, Hex64, Nonce, null_as_empty};
use crate::wire::{Error, ErrorCode};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct HelloParams {
    /// The newest protocol the client speaks.
    pub proto: u64,
    /// The client's nonce for the proofs.
    pub nonce: Nonce,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drgnx_version: Option<Bounded<String, 64>>,
    /// The work.db schema the client's code knows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub schema: Option<u64>,
    /// The records layout the client reads.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub records: Option<u64>,
    /// `editor`, `cli`, `mcp-bridge`, …
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client: Option<Bounded<String, 32>>,
    /// HMAC-SHA256 with the cap of `"drgnx-hub client " + hub nonce + " " + nonce`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proof: Option<Hex64>,
    /// The folder the client started in: an outside agent's bridge sends it, and `mcp/attach` makes it the tools'
    /// home.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<AbsPath>,
}

/// The binary that serves: its version and build commit.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Runtime {
    pub version: String,
    pub commit: String,
}

/// The hub's answer to `hello`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HelloReply {
    pub proto: u64,
    pub proto_min: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drgnx_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub schema: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub records: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class: Option<Class>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub methods: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<Runtime>,
    /// The hub's own proof, only after a valid client proof.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proof: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PingResult {
    pub pid: u64,
}

/// The refusals the hub counted, and the last ones (method, code, class, path; never params).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Refusals {
    pub count: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub last: Vec<Value>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum BackendState {
    Running,
    Starting,
    Missing,
    Failed,
}

/// The Lisp backend behind the front (phases 1–6).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Backend {
    pub state: BackendState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u64>,
}

/// Whether the front's writer can write work.db: a schema-7 file the hub made or migrated (`not-ready` while the
/// migration waits or after it failed, `read-only` for a newer file).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum WriterState {
    Ready,
    NotReady,
    ReadOnly,
}

/// work.db as the front's writer has it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct StoreStatus {
    /// `meta.schema` at the last look (0: no file).
    pub schema: u64,
    pub writer: WriterState,
    /// The transactions the front's methods committed since the hub started.
    pub writes: u64,
    /// When the move from schema 6 committed (unix seconds; none for a file made at schema 7).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub migrated_at: Option<f64>,
    /// Why the move from schema 6 failed (it is not tried again until the hub restarts; `work.db` is still schema 6).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failed: Option<String>,
    /// The size of `work.db-wal` (0 without one).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wal_bytes: Option<u64>,
    /// The newest backup copy (Task 17's daily ones).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_backup: Option<String>,
    /// Whether that copy passed its check.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backup_ok: Option<bool>,
    /// The copies that still hold what the migration's deny-list kept out of work.db (the pre-migration copy,
    /// `work.db.schema5`): the doctor offers removing them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub denied_in: Vec<String>,
    /// The graph writer's batches (group commits) since the hub started.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batches: Option<u64>,
    /// Keyed requests answered from their stored first answer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replays: Option<u64>,
    /// The read pool's connections in use now.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub readers: Option<u64>,
}

/// The coordination tools the front serves: the sessions' sockets, and the outside bridges connected now.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct McpStatus {
    pub sessions: u64,
    pub outside: u64,
}

/// The hub's status: the Lisp hub's keys and the front's.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HubStatus {
    pub pid: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub socket: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proto: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proto_min: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub records: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drgnx_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub schema: Option<u64>,
    /// work.db's schema, when it is newer than the hub's and so the hub is read-only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_only: Option<u64>,
    /// The front's writer (none from a Lisp hub).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub store: Option<StoreStatus>,
    /// The front's MCP hosting (none from a Lisp hub).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mcp: Option<McpStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<Runtime>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refusals: Option<Refusals>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job_agents: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backend: Option<Backend>,
    /// The gateway the front serves (none from a Lisp hub).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gateway: Option<GatewayStatus>,
    /// A Lisp hub's gateway port (Ratatoskr says `gateway.port`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gateway_port: Option<u64>,
    /// A Lisp hub's registrations (Ratatoskr says `gateway.registrations`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registrations: Option<u64>,
}

/// The gateway the front serves: its loopback port (none until it listens), the registrations held, and what it
/// carried since the hub started (requests answered, those that failed, fallbacks, request and answer bytes); the
/// provider table's size, the ids whose key the hub holds (never a key) and the clear-text warnings.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GatewayStatus {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u64>,
    pub registrations: u64,
    pub requests: u64,
    /// Requests whose provider answered 4xx or 5xx, or none at all.
    pub errors: u64,
    pub fallbacks: u64,
    pub bytes_in: u64,
    pub bytes_out: u64,
    pub providers: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub keys_held: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub warnings: Vec<ProviderWarning>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct EventsSinceParams {
    /// The events after this id (default 0).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<u64>,
    /// At most this many (default 200, at most 1000).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u64>,
}

/// One row of the store's event log; `data` is the stored JSON object, absent when there is none.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EventRow {
    pub id: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Map<String, Value>>,
}

/// Events oldest first: those after `since`, up to `last`.  `events/since`'s answer and the `events` event.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EventsPage {
    pub since: u64,
    pub last: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub events: Vec<EventRow>,
}

/// One variable from the user's login shell.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct EnvVar {
    pub name: EnvName,
    pub value: Bounded<String, 32768>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct EnvSetParams {
    /// At most 16; the `{NAME: value}` object form is refused.
    pub env: Bounded<Vec<EnvVar>, 16>,
}

/// The variables whose value is a `:`-separated list of directories.
pub const DIR_LISTS: [&str; 3] = ["PATH", "MANPATH", "INFOPATH"];

/// `PATH`, `MANPATH` and `INFOPATH` must be `:`-separated absolute directories (SB-T12-7): no empty, relative, `~`
/// or remote entry.  Whether each exists is the backend's check.
fn check_env(p: &EnvSetParams) -> Result<(), Error> {
    for (i, var) in p.env.iter().enumerate() {
        if DIR_LISTS.contains(&var.name.as_str())
            && !var
                .value
                .split(':')
                .all(|d| d.starts_with('/') && !d.contains('\0'))
        {
            return Err(Error {
                code: ErrorCode::InvalidParams,
                message: format!(
                    "{} is a `:`-separated list of absolute directories",
                    var.name.as_str()
                ),
                path: Some(format!("env[{i}].value")),
            });
        }
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EnvSetResult {
    /// The names the hub allowed and applied.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub applied: Vec<String>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "hello", Hello(HelloParams) -> HelloReply,
            classes: [User, Agent, Service], writes: false, home: Front,
            doc: "a connection's first line: versions, and the proofs that make it a user connection",
        ),
        method!(
            "ping", Ping(Empty) -> PingResult,
            classes: [User, Agent, Service], writes: false, home: Front,
            doc: "the hub's pid",
        ),
        method!(
            "status", Status(Empty) -> HubStatus,
            classes: [User, Agent, Service], writes: false, home: Front,
            doc: "the hub's state: versions, refusals, read-only, the backend, the gateway",
        ),
        method!(
            "restart", Restart(Empty) -> bool,
            classes: [User], writes: false, home: Front,
            doc: "answers true, then the hub exits 75 for its supervisor to start it again",
        ),
        method!(
            "shutdown", Shutdown(Empty) -> bool,
            classes: [User], writes: false, home: Front,
            doc: "answers true, then the hub exits",
        ),
        method!(
            "subscribe", Subscribe(Empty) -> bool,
            classes: [User], writes: false, home: Front,
            doc: "this connection receives the events from now on",
        ),
        method!(
            "events/since", EventsSince(EventsSinceParams) -> EventsPage,
            classes: [User], writes: false, home: Front,
            doc: "the event log after since (0), oldest first, at most limit (200; at most 1000)",
        ),
        method!(
            "env/set", EnvSet(EnvSetParams) -> EnvSetResult,
            classes: [User], writes: false,
            doc: "the user's login-shell variables the hub allows, for the agents and jobs it starts next",
            check: check_env,
        ),
    ]
}
