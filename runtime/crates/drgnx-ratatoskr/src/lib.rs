//! Ratatoskr, drgnx's agent runtime: the hub protocol's server (docs/develop/hub.md, docs/develop/runtime.md).
//!
//! - [`cli`]: the command line (`serve`, `version`, `methods`) and the exit codes.
//! - [`lock`]: one hub per data dir (an exclusive `flock`; a Lisp hub's lock directory respected).
//! - [`server`]: the start order, the accept loops, signals, the parent watch, the schema tick and the stop.
//! - [`conn`]: one connection: the peer-uid check, the challenge, lines, the writer queue that drops a stopped reader.
//! - [`hello`]: a connection's class and `hello` v1 (the challenge, the proofs both ways, at most once).
//! - [`dispatch`]: the contract's checks before any method runs, the refusals, and [`dispatch::Forward`].
//! - [`front`]: what connections share and the methods the front serves itself.
//! - [`store`]: `work.db`, read-only, on a thread of its own.
//! - [`log`]: tracing to `<state>/hub/log/hub-YYYY-MM-DD.jsonl` and warnings to stderr.
//! - [`runtime_db`]: `<state>/hub/runtime.db`, the hub's own recovery state.
//! - [`backend`]: the Lisp backend: its command, environment, record, connection and restarts.
//! - [`forward`]: what goes to the backend (re-encoded typed params with the caller) and what comes back (checked).
//! - [`relay`]: the backend's events, checked against the registry, to the front's subscribers.
//! - [`shape`]: what a caller of each class may ask and see of a forwarded method.
//! - [`version`]: what `version --json` says.

pub mod backend;
pub mod cli;
pub mod conn;
pub mod dispatch;
pub mod forward;
pub mod front;
pub mod hello;
pub mod lock;
pub mod log;
pub mod relay;
pub mod runtime_db;
pub mod server;
pub mod shape;
pub mod store;
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
