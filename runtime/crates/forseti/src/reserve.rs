//! Two schedulers on one machine: the reservation format.

use serde::{Deserialize, Serialize};

/// One running job's claim on a machine, written by its scheduler (`sleipnir::linux::reserve` keeps them as files).
/// It counts only while its process lives (pid and start time), on the boot it was written in, and until `expires`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reservation {
    pub scheduler: String,
    pub pid: u32,
    pub boot_id: String,
    /// The process's start time (`/proc/<pid>/stat` field 22), so a reused pid isn't taken for it.
    pub start_time: u64,
    pub job: String,
    pub reserve_mib: u64,
    pub current_mib: u64,
    pub expires: u64,
}
