//! The one platform boundary: which backend runs a spec on this host (Tasks 2 and 13).

// bwrap and the reduced tier (Landlock + seccomp through the inner helper). A desktop-distro fact, so `linux` alone.
// Android: no backend; apps get no user namespaces; fails closed (`none`).
#[cfg(target_os = "linux")]
pub mod linux;

// Seatbelt through /usr/bin/sandbox-exec. Android: not applicable (no Seatbelt).
#[cfg(target_os = "macos")]
pub mod macos;

// Every other target, Android among them: a refusal, never an unconfined run.
pub mod none;
