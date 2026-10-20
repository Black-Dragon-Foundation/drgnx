//! The hub protocol's contract on the Rust side (docs/develop/runtime.md, "drgnx-proto").
//!
//! - [`wire`]: requests, answers, errors and events as they cross the socket (one JSON object per line).
//! - [`line`]: the line limits and the strict parse of one line (duplicate keys and deep nesting refused).
//! - [`decode`]: typed decode of params, with the path of a failure and the keys it dropped.
//! - [`proof`]: the cap, the nonces and the HMAC proofs of `hello`.
//! - [`paths`]: where the data dir, the socket, the cap, the lock and the backend's socket are.

pub mod decode;
pub mod line;
pub mod paths;
pub mod proof;
pub mod wire;
