//! The hub protocol's contract on the Rust side (docs/develop/runtime.md, "runstav").
//!
//! - [`wire`]: requests, answers, errors and events as they cross the socket (one JSON object per line).
//! - [`line`]: the line limits and the strict parse of one line (duplicate keys and deep nesting refused).
//! - [`decode`]: typed decode of params, with the path of a failure and the keys it dropped.
//! - [`proof`]: the cap, the nonces and the HMAC proofs of `hello`.
//! - [`paths`]: where the data dir, the socket, the cap, the lock and the backend's socket are.
//! - [`registry`]: every method, its classes, schemas and `writes` flag; `methods.json` and the docs table.
//! - [`methods`]: each method's params and result types; [`types`]: the named input types; [`events`]: the event
//!   types.
//! - [`text`]: the one sanitizer for user-visible text; [`url`]: the URL rule and the provider-base rule.
//! - [`secrets`]: the one list of secret patterns, for refusing credentials in stored text.

pub mod decode;
pub mod events;
pub mod jsonrpc;
pub mod line;
pub mod methods;
pub mod paths;
pub mod proof;
pub mod registry;
pub mod secrets;
pub mod text;
pub mod types;
pub mod url;
pub mod wire;
