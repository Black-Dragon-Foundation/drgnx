//! `sleipnir`, the runner: a library shared by the hub, the runners and jobq, and the `sleipnir` binary.
//!
//! Features (`docs/develop/sleipnir.md`):
//! - `linux`: the machine probe, the reservation files and the executor (`linux`). Blocking, std, rustix and serde
//!   only, never tokio. The pure parts (the podman argv, the shim, the parsers, `result.json`) build on every target;
//!   the parts that talk to systemd and the cgroup files build on `target_os = "linux"` only.
//! - `sync`: a job's inputs frozen at submit, the hardened git (the only way sleipnir runs git), and the checkout
//!   slots, whose git dirs live outside anything a job can write; the runner's mirrors, the origin's credential,
//!   resumable bundles and the blob store; caches by trust and the disk guard. Blocking, never tokio.
//! - `proto`: the hub–runner protocol: the frames and their wire. Pure.
//! - the job helper (`helper`, Linux): a job's keys in locked memory behind its key socket, and its disk watch, with
//!   `linux`; its network proxy (Gleipnir's, on tokio) with `runner`.
//! - `runner` (default): the binary's modes.
//! - `test-hooks`: test-only entry points, compiled away otherwise.

#[cfg(all(feature = "runner", target_os = "linux"))]
pub mod bench;
#[cfg(all(feature = "linux", target_os = "linux"))]
pub mod helper;
#[cfg(feature = "linux")]
pub mod linux;
#[cfg(feature = "proto")]
pub mod proto;
#[cfg(all(feature = "runner", target_os = "linux"))]
pub mod serve;
#[cfg(feature = "sync")]
pub mod sync;
