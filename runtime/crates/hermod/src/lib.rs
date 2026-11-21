//! hermod (Hermóðr, the messenger): an ACP client on `agent-client-protocol-schema`'s types and runstav's JSON-RPC
//! line codec, with no SDK role framework (V2 runtime design §5.7; `docs/develop/runtime.md`, "hermod").  Generic:
//! no drgnx type.  One reader task and one writer task per connection; a watchdog task that waits for the child,
//! drains what it wrote and sends [`Event::Exit`] exactly once; a receipt stamp on every update; the
//! `_meta.jetbrains.air.fork` shape for forking at a message; an optional line tap that sees both directions (a
//! recording).
//!
//! Modules: `conn` (spawn, the tasks, calls with deadlines), `types` (`ConnOpts`, `LineTap`, `Dir`, `AgentInfo`,
//! `PromptOutcome`, `ForkPoint`, `ForkInto`, `Event`, `Error`, and v2's `Proto`, `RunState`, `BackgroundRef`, `TerminalEv`),
//! `incoming` (the agent's requests and their responders), `stamp` (receipt stamps), `v2` (ACP v2 turned into the
//! events above: a turn ends at the agent's `idle`, upserts replace, background work and terminals arrive as events).

pub mod conn;
pub mod incoming;
pub mod stamp;
pub mod types;
pub(crate) mod v2;

pub use agent_client_protocol_schema as schema;
pub use conn::Conn;
pub use incoming::{Incoming, Responder};
pub use types::*;
