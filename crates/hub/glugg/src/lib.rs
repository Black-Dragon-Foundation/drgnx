//! drgnx's terminal worker (docs/develop/terminal.md): one PTY and one libghostty-vt terminal per process, its screen
//! sent to the editor as `rodd` patches through the hub. Without the `ghostty` feature only the parts that need
//! no engine build: the frame clock, the row keys, the styles, the key table, the PTY and the wire.

/// R, the result of a removal nobody can act on (a socket, a canvas, a record): a file that is already gone is the
/// wanted end; any other failure is logged under WHAT.
pub fn removed(r: std::io::Result<()>, what: &str) {
    if let Err(e) = r
        && e.kind() != std::io::ErrorKind::NotFound
    {
        tracing::warn!(error = %e, what, "a removal failed");
    }
}

pub mod ask;
pub mod child;
pub mod frame;
pub mod image;
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
pub mod gallery;
#[cfg(feature = "ghostty")]
pub mod run;
#[cfg(feature = "ghostty")]
pub mod worker;
