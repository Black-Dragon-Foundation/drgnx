//! The inner helper (Task 8): run between the namespace setup and the program, single-threaded; Landlock, then
//! seccomp, then the relay, a status line, and the exec.
//!
//! Its body is gated `#[cfg(target_os = "linux")]` here, with an `Unsupported` stub elsewhere (Android: no backend;
//! apps get no user namespaces; fails closed).
