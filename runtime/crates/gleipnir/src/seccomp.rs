//! The seccomp deny-list, compiled to BPF per architecture, and its install (Task 4).
//!
//! The compiling and installing code is gated `#[cfg(target_os = "linux")]` here, with an `Unsupported` stub
//! elsewhere (Android: no backend; apps get no user namespaces; fails closed). `seccompiler` is a Linux-only
//! dependency.
