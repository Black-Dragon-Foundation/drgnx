//! heimdall: the CDP broker's pure part (docs/develop/hub.md, "The CDP broker").
//!
//! No I/O and no async runtime: the hub's broker (a websocket server) and the browser host (Chromium's pipe) wrap it.
//! It builds for every target the runtime does, Android included.
//!
//! - `envelope`: one CDP message's envelope (`id`, `method`, `sessionId`, and for `Target.*` the `targetId` and
//!   `sessionId` params), borrowed from the bytes; everything else stays a `RawValue`, never re-encoded.
//! - `route`: the `Router`, which keeps the agent's traffic and the hub's apart on one browser connection by session
//!   owner, refuses `REFUSED_ALWAYS`, answers the agent's download behaviour itself, and cleans up when the agent
//!   goes.
//! - `codec`: Chromium's NUL-delimited pipe messages, and the length-prefixed frames between the hub and the browser
//!   host.

pub mod codec;
pub mod envelope;
pub mod route;

pub use envelope::{Envelope, ParseError, parse};
pub use route::{
    BrokerEvent, DOWNLOAD_DIR, HUB_ID_BASE, Owner, REFUSED_ALWAYS, Router, Step, is_refused,
};
