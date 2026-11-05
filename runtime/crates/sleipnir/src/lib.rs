//! `sleipnir`, the runner: a library shared by the hub, the runners and jobq, and the `sleipnir` binary.
//!
//! Features (`docs/develop/sleipnir.md`):
//! - `linux`: the machine probe, the reservation files and the executor (`linux`). Blocking, std, rustix and serde
//!   only, never tokio. The pure parts (the podman argv, the shim, the parsers, `result.json`) build on every target;
//!   the parts that talk to systemd and the cgroup files build on `target_os = "linux"` only.
//! - `sync`: a job's inputs frozen at submit, the hardened git (the only way sleipnir runs git), and the checkout
//!   slots, whose git dirs live outside anything a job can write. Blocking, never tokio.
//! - `proto`: the hub–runner protocol: the frames and their wire. Pure.
//! - `runner` (default): the binary's modes.
//! - `test-hooks`: test-only entry points, compiled away otherwise.

#[cfg(feature = "linux")]
pub mod linux;
#[cfg(feature = "proto")]
pub mod proto;
#[cfg(feature = "sync")]
pub mod sync;
