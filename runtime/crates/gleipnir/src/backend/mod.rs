//! The one platform boundary: which backend runs a spec on this host (docs/develop/gleipnir.md, "Platforms").
//! Task 2 names the kinds; detecting and running them is Task 13's.
//!
//! Which file holds what:
//!
//! | Item | File | Gate | Android |
//! |---|---|---|---|
//! | the spec, validation, the bwrap argv, the SBPL text, hosts, relay, proxy | `spec`, `validate`, `bwrap`, `sbpl`, `net` | none: pure, built and tested on every target | builds; nothing runs it |
//! | bwrap, the reduced tier | `backend::linux::{bwrap, reduced}` | `target_os = "linux"` | no backend; apps get no user namespaces; fails closed |
//! | the inner helper, Landlock, seccomp | `inner`, `landlock`, `seccomp` | body `target_os = "linux"`, an `Unsupported` stub elsewhere | the stub: fails closed |
//! | Seatbelt | `backend::macos` | `target_os = "macos"` (and `test`, so its tests run on Linux) | not applicable (no Seatbelt) |
//! | everything else | `backend::none` | always built | the answer there: a refusal |
//! | no-link opens (`openat2`), `/proc` | `eitri`, `draugr` | `any(target_os = "linux", target_os = "android")` | a kernel fact: Android has them |
//!
//! Every chain of `cfg`s ends in [`BackendKind::None`] or an `Unsupported` refusal, never in a missing item and
//! never in an unconfined run. Outside `backend`, only `inner`, `landlock` and `seccomp` name a `target_os`.

// bwrap and the reduced tier (Landlock + seccomp through the inner helper). A desktop-distro fact, so `linux` alone.
// Android: no backend; apps get no user namespaces; fails closed (`none`).
#[cfg(target_os = "linux")]
pub mod linux;

// Seatbelt through /usr/bin/sandbox-exec. Android: not applicable (no Seatbelt). Built in tests on every target too:
// its code is plain Unix (a file and an argv), so where the profile goes is tested on Linux; only macOS runs it.
#[cfg(any(target_os = "macos", test))]
pub mod macos;

// Every other target, Android among them: a refusal, never an unconfined run.
pub mod none;

/// The backend that runs a spec. Which one a host gets is Task 13's detection; a host where none works gets
/// [`BackendKind::None`], and every run there is refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    /// The full tier (Linux): bubblewrap ≥ 0.12.0, then the inner helper with Landlock (ABI ≥ 1) and seccomp.
    Bwrap,
    /// The reduced tier (Linux): the inner helper alone, Landlock ABI ≥ 9 and seccomp, no namespaces.
    Reduced,
    /// macOS: Seatbelt through a root-owned `/usr/bin/sandbox-exec`.
    Seatbelt,
    /// No backend here (Android, other systems, or a host that fails the check): refuse, never run unconfined.
    None,
}
