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
//! - [`dispatch`]: the contract's checks before any method runs, and the refusals.
//! - [`front`]: what connections share, and every method's handler (one `match` with no catch-all arm).
//! - [`store`]: `work.db`, read-only, on a thread of its own.
//! - [`coord`]: the front's writes to `work.db` (the editor's methods, `coord/*`), the `events` broadcast and the
//!   coordination tools' hub.
//! - [`graph`]: the graph store's methods the front serves: `graph/put-parsed` (the tracker scan's door) and
//!   `graph/record`.
//! - [`backup_timer`]: the nightly checked backup's schedule (03:00, or the first tick after a missed night).
//! - [`graph_cli`]: `ratatoskr graph …`, the store's commands from a terminal (export, import, backup, revert,
//!   excise, scrub, grants, sql, compact, proposed), a client of the running hub.
//! - [`job_cli`]: `ratatoskr job …`, plan runs from a terminal (propose, approve, status, stop, resume), a client of
//!   the running hub.
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
//! - [`sandbox`]: Gleipnir as Ratatoskr uses it: the context of closed paths, the helper, the spawn, `sandbox run`.
//! - [`settings`]: `settings.el` and the shipped `runtime-defaults.el`, read as data with `huginn`: the runtime
//!   settings only, their fallbacks, `status.settings`.
//! - [`shape`]: what a caller of each class may ask and see of `agents/list` and `spend`.
//! - [`shell_env`]: `env/set`: the login shell's variables, an overlay on the environment of what the hub starts.
//! - [`version`]: what `version --json` says.
//!
//! The agent core (agent system part 1; [`agent_core`] routes its methods to these):
//!
//! - [`agents`]: sessions in the hub (lifecycle, permissions, prompts, delivery, locks, the sandboxed launch).
//! - [`exec`]: jobs (`exec/*`), each a unit of its own in its starter's sandbox.
//! - [`runner`]: plan runs (`job/*`): the tick, git and the merge gate, clashes, plans and reports.
//! - [`matrix_gate`]: the permissions matrix checked on every action.
//! - [`timeline`]: every step timed, classified and anchored.
//! - [`budget`]: budgets in named units, nested; the subscriptions' pace.
//! - [`supervisor`]: stuck agents paused with a card.
//! - [`brief`]: briefs built from the graph.
//! - [`manager`]: the manager role.
//! - [`records`]: the records importer and their views.

pub mod agent_core;
pub mod agents;
pub mod backup_timer;
pub mod bridge;
pub mod brief;
pub mod budget;
pub mod cli;
pub mod client;
pub mod conn;
pub mod coord;
pub mod dispatch;
pub mod doctor;
pub mod embed;
pub mod exec;
pub mod front;
pub mod gateway;
pub mod graph;
pub mod graph_cli;
pub mod hello;
pub mod idle;
pub mod job_cli;
pub mod lock;
pub mod log;
pub mod manager;
pub mod matrix_gate;
pub mod peer;
pub mod records;
pub mod runner;
pub mod runtime_db;
pub mod sandbox;
pub mod sandbox_settings;
pub mod server;
pub mod sessions;
pub mod settings;
pub mod shape;
pub mod shell_env;
pub mod store;
pub mod store_cli;
pub mod supervise;
pub mod supervisor;
pub mod timeline;
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
