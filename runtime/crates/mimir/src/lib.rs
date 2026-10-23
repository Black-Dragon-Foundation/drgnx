//! mimir: a tools-only MCP server for both protocol eras (docs/develop/runtime.md, "mimir").
//!
//! - [`jsonrpc_glue`]: MCP's use of runstav's JSON-RPC 2.0 module.
//! - [`version`]: the protocol versions and the negotiation of `initialize`.
//! - [`tool`]: the [`Tool`] trait a server's tools implement, and [`typed`], their arguments' schema and check.
//! - [`server`]: one connection's loop, newline-delimited JSON-RPC.
//! - [`bridge`]: the bridge's redial state machine, generic over a connector.
//!
//! Self-contained: no drgnx type in its API.

pub mod bridge;
pub mod jsonrpc_glue;
pub mod server;
pub mod tool;
pub mod version;

pub use server::{End, Limits, ServerInfo, serve};
pub use tool::{ArgsError, BoxFuture, Tool, ToolResult, Typed, typed};
