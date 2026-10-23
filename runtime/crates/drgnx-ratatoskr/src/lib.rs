//! Ratatoskr, drgnx's agent runtime: the hub protocol's server (docs/develop/hub.md, docs/develop/runtime.md).
//!
//! - [`cli`]: the command line (`serve`, `ensure`, `stop`, `status`, `doctor`, `restart`, `version`, `methods`,
//!   `mcp-bridge`, `store`) and
//!   the exit codes.
//! - [`store_cli`]: `store migrate-check` (a copy migrated to schema 7, counts only) and `store restore-pre7`.
//! - [`supervise`]: `ensure` (a transient systemd unit, launchd or a detached process) and `stop`.
//! - [`client`]: the blocking client those commands use (a raw ping, a proven user connection).
//! - [`idle`]: restart-when-idle: the binary on disk changed, restart between turns.
//! - [`doctor`]: `status`, `doctor --json` and `restart`.
//! - [`lock`]: one hub per data dir (an exclusive `flock`; a Lisp hub's lock directory respected).
//! - [`server`]: the start order (the store opened, or made, or migrated, before anything is served), the accept loops, signals, the parent watch, the schema tick and the stop.
//! - [`conn`]: one connection: the peer-uid check, the challenge, lines, the writer queue that drops a stopped reader.
//! - [`hello`]: a connection's class and `hello` v1 (the challenge, the proofs both ways, at most once).
//! - [`dispatch`]: the contract's checks before any method runs, the refusals, and [`dispatch::Forward`].
//! - [`front`]: what connections share and the methods the front serves itself (the seam rule: the backend's own
//!   connection is held to them).
//! - [`store`]: `work.db`, read-only, on a thread of its own.
//! - [`coord`]: the front's writes to `work.db` (the editor's methods, the seam's `coord/*`), the `events` broadcast,
//!   the `coord/notify` coalescer and the coordination tools' hub.
//! - [`sessions`]: the coordination tools on a socket per session (the socket is the identity) and for outside
//!   agents' bridges (`mcp/session`, `mcp/session-close`, `mcp/attach`), kept in `runtime.db`.
//! - [`peer`]: the process behind a connection: its parent and start time, for an outside agent's identity; the
//!   process listening on a socket, `stop`'s only target.
//! - [`gateway`]: the gateway in the hub: registrations (hashes only) in `runtime.db`, keys in memory, the provider
//!   table, spend from `work.db`, the engine's events.
//! - [`bridge`]: `mcp-bridge`, an agent's stdio MCP server copied to a session's socket or, for an outside agent, to
//!   the main socket as `service`; it redials after a hub restart.
//! - [`log`]: tracing to `<state>/hub/log/hub-YYYY-MM-DD.jsonl` and warnings to stderr.
//! - [`runtime_db`]: `<state>/hub/runtime.db`, the hub's own recovery state.
//! - [`backend`]: the Lisp backend: its command, environment, record, connection and restarts.
//! - [`forward`]: what goes to the backend (re-encoded typed params with the caller) and what comes back (checked).
//! - [`relay`]: the backend's events, checked against the registry, to the front's subscribers.
//! - [`sandbox`]: Gleipnir as Ratatoskr uses it: the context of closed paths, the helper, the spawn, `sandbox run`.
//! - [`shape`]: what a caller of each class may ask and see of a forwarded method.
//! - [`version`]: what `version --json` says.

pub mod backend;
pub mod bridge;
pub mod cli;
pub mod client;
pub mod conn;
pub mod coord;
pub mod dispatch;
pub mod doctor;
pub mod forward;
pub mod front;
pub mod gateway;
pub mod hello;
pub mod idle;
pub mod lock;
pub mod log;
pub mod peer;
pub mod relay;
pub mod runtime_db;
pub mod sandbox;
pub mod server;
pub mod sessions;
pub mod shape;
pub mod store;
pub mod store_cli;
pub mod supervise;
pub mod version;

/// How the process ends (design 3.2): supervisors restart on 75 and never on 1, 2 or 3.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Exit {
    /// Asked to stop (SIGTERM, SIGINT, `shutdown`, the parent gone).
    Stopped = 0,
    /// Cannot start (SQLite too old, a directory that is not private, a socket that does not bind, ...).
    CannotStart = 1,
    /// A command line that does not parse.
    Usage = 2,
    /// Another hub serves this data dir (a Ratatoskr holding the lock, or a Lisp hub from before).
    AnotherHub = 3,
    /// A restart was asked for (an update, restart-when-idle).
    Restart = 75,
}
