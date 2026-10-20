//! Ratatoskr, drgnx's agent runtime: the hub protocol's server (docs/develop/hub.md, docs/develop/runtime.md).
//!
//! - [`cli`]: the command line (`serve`, `version`) and the exit codes.
//! - [`lock`]: one hub per data dir (an exclusive `flock`; a Lisp hub's lock directory respected).
//! - [`server`]: the start order, the accept loop, signals, the parent watch and the stop.
//! - [`conn`]: one connection: the peer-uid check, lines, the writer queue that drops a stopped reader.
//! - [`log`]: tracing to `<state>/hub/log/hub-YYYY-MM-DD.jsonl` and warnings to stderr.
//! - [`runtime_db`]: `<state>/hub/runtime.db`, the hub's own recovery state.
//! - [`version`]: what `version --json` says.

pub mod cli;
pub mod conn;
pub mod lock;
pub mod log;
pub mod runtime_db;
pub mod server;
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
