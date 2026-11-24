//! Eykt, the hub's clock and what is bound to time: the clock (virtual in a test build), the stall watchdog, stage
//! timestamps, the ordered disk writer, the step snapshots, and the project of a folder (docs/develop/hub.md,
//! "Crates of the hub").  It sits on `stofn` and under every crate that waits, so the one process-wide virtual clock
//! lives here, and every crate reaches it as `eykt::clock`.

pub use stofn::{fsio, proc, soft};

pub mod clock;
pub mod disk;
pub mod project;
pub mod snapshot;
pub mod stages;
pub mod stall;
