//! Landlock rule sets per ABI for the full and reduced tiers, applied as a hard requirement with a minimum ABI
//! (Task 5). The plan and the rule sets are pure; applying them is Linux only.
//!
//! The applying code is gated `#[cfg(target_os = "linux")]` here, with an `Unsupported` stub elsewhere (Android: no
//! backend; apps get no user namespaces; fails closed). The `landlock` crate is a Linux-only dependency; name it
//! `::landlock` in this module.
