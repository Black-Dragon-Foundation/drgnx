//! Jupyter notebooks in the hub (language packs Task 11b, docs/specs/drgnx/2026-11-14-jupyter-tier1-design.md §5): the
//! kernels. The notebook file model is `hrafn::notebook` (T11a).
//!
//! - [`wire`]: a message of the Jupyter protocol as ZeroMQ frames: encoding, the signature checked in constant time, size caps.
//! - [`spec`]: the installed kernelspecs, and a kernel's connection file (0600, in a 0700 folder, deleted when the kernel ends).

pub mod spec;
pub mod wire;
