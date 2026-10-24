//! hermod (Hermóðr, the messenger): an ACP client on `agent-client-protocol-schema`'s types and runstav's JSON-RPC
//! line codec, with no SDK role framework (V2 runtime design §5.7; `docs/develop/runtime.md`, "hermod").  Generic:
//! no drgnx type.  One reader task and one writer task per connection; a watchdog task that waits for the child,
//! drains what it wrote and sends [`Event::Exit`] exactly once; a receipt stamp on every update; the
//! `_meta.jetbrains.air.fork` shape for forking at a message.
//!
//! Modules: `conn` (spawn, the tasks, calls with deadlines), `types` (`ConnOpts`, `AgentInfo`, `PromptOutcome`,
//! `ForkPoint`, `Event`, `Error`), `incoming` (the agent's requests and their responders), `stamp` (receipt stamps).

pub mod conn;
pub mod incoming;
pub mod stamp;
pub mod types;

pub use agent_client_protocol_schema as schema;
pub use conn::Conn;
pub use incoming::{Incoming, Responder};
pub use types::*;
