//! eitri: file access that never follows a link (design 6.2 rule 4; docs/develop/runtime.md, "eitri").
//!
//! Generic: no drgnx type and no drgnx path. Used by gleipnir and draugr, and later by the file service.
//!
//! - `open`: `open_path` and `open_beneath`, which refuse a link in any component and return the fd they checked.
//! - `read`: bounded reads of regular files only (a FIFO is never read).
//! - `write`: writes by a temporary file and a rename, never through a link.
//! - `trusted`: a program that only root can change, found by fixed candidates and never through `PATH`.

// Task 1 re-exports each module's items here (`eitri::open_path`, `eitri::trusted_program`, …).
mod open;
mod read;
mod trusted;
mod write;
