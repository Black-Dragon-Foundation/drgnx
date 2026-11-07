//! drgnx's terminal worker (docs/develop/terminal.md): one PTY and one libghostty-vt terminal per process, its screen
//! sent to the editor as `drgnx-rows` patches through the hub. Without the `ghostty` feature only the parts that need
//! no engine build: the frame clock, the row keys, the styles, the key table, the PTY and the wire.

pub mod child;
pub mod frame;
pub mod keys;
pub mod proto;
pub mod pty;
pub mod registry;
pub mod rows;
pub mod scope;
pub mod style;

#[cfg(feature = "ghostty")]
pub mod engine;
#[cfg(feature = "ghostty")]
pub mod run;
#[cfg(feature = "ghostty")]
pub mod worker;
