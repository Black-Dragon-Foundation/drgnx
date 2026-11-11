//! Debugging (docs/develop/debugging.md): the hub owns each debug session, speaking the Debug Adapter Protocol to the
//! adapter through `vor`.
//!
//! - [`session`]: one session's life: the launch sequence, stops and their epochs, controls, the stop sequence.

pub mod session;
#[cfg(test)]
mod tests;
