//! The macOS side of a runner (a Mac with Apple silicon, in a standard account of its own): the machine probe and its
//! contract ([`probe`]), an attempt's process ([`attempt`]: its own session, a pid file) and job-exec ([`jobexec`]:
//! the command under `sandbox-exec`, its timeout on `CLOCK_MONOTONIC`, its memory cap by [`memwatch`]). The parsers, the contract, the attempt's
//! process and job-exec are plain and build on Linux too, so Linux tests run them; reading the machine (`sysctl`,
//! `sw_vers`, `brew`) is `target_os = "macos"` only. `docs/develop/sleipnir.md`, "A Mac runner".

#[cfg(any(target_os = "linux", target_os = "macos"))]
pub mod attempt;
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub mod jobexec;
pub mod memwatch;
pub mod probe;
#[cfg(feature = "runner")]
pub mod sandbox;
