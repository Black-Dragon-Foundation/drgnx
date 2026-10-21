//! bifrost: the gateway (docs/develop/runtime.md, "bifrost").
//!
//! - [`admit`]: request admission, token checks and the two path classes.
//! - [`rewrite`]: body rewrites (model, chain fallback, OpenRouter restrictions).
//! - [`usage`]: the SSE usage scanner; [`budget`]: cost and budget arithmetic.
//! - [`upstream`]: the HTTP/1.1 client over rustls.
//! - [`engine`]: forwarding; [`listen`]: the listeners; [`keys`]: provider keys, memory only.
//!
//! Self-contained: budget and spend go through caller-supplied traits.

pub mod admit;
pub mod budget;
pub mod engine;
pub mod keys;
pub mod listen;
pub mod rewrite;
pub mod upstream;
pub mod usage;
