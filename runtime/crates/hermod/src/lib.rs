//! hermod (Hermóðr, the messenger): an ACP client on `agent-client-protocol-schema`'s types and runstav's JSON-RPC
//! line codec, with no SDK role framework (V2 runtime design §5.7; `docs/develop/runtime.md`, "hermod").  Generic:
//! no drgnx type.  Agent system part 1, Task 1 fills it: a watchdog, a stderr tail, deadlines, exactly-once exit,
//! a receipt stamp on every update and the `_meta.jetbrains.air.fork` shape.
//!
//! Task 1's modules: `conn` (spawn, the reader and writer tasks, calls with deadlines), `types` (`ConnOpts`,
//! `AgentInfo`, `PromptOutcome`, `ForkPoint`, `Event`, `Error`), `incoming` (the agent's requests and their
//! responders), `stamp` (receipt stamps).

pub use agent_client_protocol_schema as schema;
