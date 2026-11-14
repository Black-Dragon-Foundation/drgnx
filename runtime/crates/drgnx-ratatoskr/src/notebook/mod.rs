//! Jupyter notebooks in the hub (language packs Task 11b, docs/specs/drgnx/2026-11-14-jupyter-tier1-design.md §5): the
//! kernels. The notebook file model is `hrafn::notebook` (T11a).
//!
//! - [`wire`]: a message of the Jupyter protocol as ZeroMQ frames: encoding, the signature checked in constant time, size caps.
//! - [`book`]: one open notebook: the file's model, what each cell shows, sync with the buffer, save.
//! - [`hub`]: the notebooks open for an editor and their kernels' tasks, and the events they send.
//! - [`rpc`]: the `notebook/*` methods, each a call on the hub's notebooks.
//! - [`kernel`]: one kernel's process (draugr, own group), its connection, ready, interrupt, shutdown.
//! - [`output`]: the outputs of a cell as the hub holds them: terminal text, MIME choice and image checks, the router.
//! - [`session`]: a kernel's four sockets, one reader task each that always drains, bounded in bytes.
//! - [`tail`]: the string put after a cell: text, style runs, images, capped to a window.
//! - [`spec`]: the installed kernelspecs, and a kernel's connection file (0600, in a 0700 folder, deleted when the kernel ends).

pub mod book;
pub mod hub;
pub mod kernel;
pub mod output;
pub mod rpc;
pub mod session;
pub mod spec;
pub mod tail;
pub mod wire;
