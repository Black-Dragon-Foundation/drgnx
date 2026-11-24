//! Stofn: the foundation the hub's other crates stand on. The standards shims over `annall`, `eitri` and `draugr`
//! ([`soft`], [`fsio`], [`proc`]), the shell environment, and the helpers that need no clock: the wire errors, who a
//! prompt is from, who calls, a checkout's git folders, the running executable's path, a debug session's ports and the
//! archive unpacker.  It depends on no crate above it (`standards.toml`, `[[layer]]`).

pub mod caller;
pub mod errors;
pub mod exe;
pub mod fsio;
pub mod gitdirs;
pub mod origin;
pub mod ports;
pub mod proc;
pub mod shell_env;
pub mod soft;
pub mod unpack;
