//! sleipnir: the runner (docs/develop/sleipnir.md).
//!
//! - `sync`: a job's inputs frozen at submit, the hardened git (the only way sleipnir runs git), and the checkout
//!   slots, whose git dirs live outside anything a job can write.

#[cfg(feature = "sync")]
pub mod sync;
