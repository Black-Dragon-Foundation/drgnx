//! drgnx-px: the relay between a networked container job and its owner's proxy (docs/develop/drgnx-px.md).
//!
//! The sidecar accepts the job's TCP connections and carries each as a stream of frames over its stdin and stdout to
//! the owner (the hub, or a runner's job helper), which hands each stream to the job's proxy.
//!
//! - [`frame`]: the codec;
//! - [`mux`]: the channel's state machine, pure, on both ends;
//! - [`pending`]: what waits for the writer and the order it leaves in, pure;
//! - [`shell`]: the reader, the writer and the per-stream tasks around them, on both ends;
//! - [`sidecar`]: the listener, the source check and stdio; the `drgnx-px` binary runs it;
//! - [`image`]: the sidecar's scratch image (a tar of the binary), tagged by content, and how it is imported;
//! - [`owner`]: the owner's end, which hands each stream to the job's proxy, and the sidecar's container.

pub mod frame;
pub mod image;
pub mod mux;
pub mod owner;
pub mod pending;
pub mod shell;
pub mod sidecar;

#[cfg(test)]
mod orders;
