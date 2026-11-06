//! drgnx-px: the relay between a networked container job and its owner's proxy (docs/develop/drgnx-px.md).
//!
//! The sidecar accepts the job's TCP connections and carries each as a stream of frames over its stdin and stdout to
//! the owner (the hub, or a runner's job helper), which hands each stream to the job's proxy. This crate holds the
//! frame codec; the relay's state machine and its two ends build on it.

pub mod frame;
