//! Vör: a client for the Debug Adapter Protocol (DAP), on tokio.
//!
//! - [`codec`]: the base protocol's `Content-Length` framing.
//! - [`Client`]: one connection: requests matched to answers, events and reverse requests in order, one end for all.
//! - `mock` (feature `mock`): a scripted adapter for tests, also the `vor-mock` binary.
//! - [`types`]: the protocol's types, generated from its JSON schema (`examples/gen_types.rs`); unknown fields are kept.
//!
//! It knows nothing of drgnx: sessions, adapters and timeouts are the caller's (docs/develop/debugging.md).
pub mod client;
pub mod codec;
pub mod message;
#[cfg(feature = "mock")]
pub mod mock;
pub mod types;

pub use client::{Client, Error, Incoming, Pending, ReverseRequest, event_body};
pub use message::Message;

use serde::Serialize;
use serde::de::DeserializeOwned;

/// A request: its command name, what it takes and what its answer's body holds.
pub trait Request {
    const COMMAND: &'static str;
    type Arguments: Serialize;
    type Body: DeserializeOwned;
}

/// An event: its name and its body.
pub trait Event {
    const EVENT: &'static str;
    type Body: DeserializeOwned;
}
