//! The resource telemetry's words on the wire: what a runner's sampler reports and what a viewer asks for
//! (`docs/develop/sleipnir.md`, "Resource telemetry"). Pure: serde only.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// What a series is about, from the whole machine down to one job.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Level {
    /// The runner and its machine.
    Runner,
    /// One slot instance: the jobs on it and its folder.
    Slot,
    /// A job's reservation: reserved and used memory.
    Reservation,
    /// One job's cgroup.
    Job,
}

impl Level {
    pub const ALL: [Level; 4] = [Level::Runner, Level::Slot, Level::Reservation, Level::Job];

    /// The level's word, as the CLI and the wire write it.
    pub fn word(self) -> &'static str {
        match self {
            Level::Runner => "runner",
            Level::Slot => "slot",
            Level::Reservation => "reservation",
            Level::Job => "job",
        }
    }

    pub fn parse(word: &str) -> Option<Level> {
        Level::ALL.into_iter().find(|l| l.word() == word)
    }

    /// The byte a stored record keeps (1-based).
    pub fn code(self) -> u8 {
        Level::ALL.iter().position(|l| *l == self).unwrap_or(0) as u8 + 1
    }

    pub fn from_code(code: u8) -> Option<Level> {
        Level::ALL.get(usize::from(code).checked_sub(1)?).copied()
    }
}

/// The metrics a series may carry, by name; the position in this list (from 1) is the byte a stored record keeps, so
/// the order is the file format: a new metric goes last.
pub const METRICS: [&str; 19] = [
    "cpu",           // cores busy
    "mem_mib",       // memory in use
    "mem_avail_mib", // the machine's MemAvailable
    "mem_peak_mib",  // a cgroup's high-water mark
    "swap_mib",
    "psi_cpu", // pressure `some avg10`, percent
    "psi_mem",
    "psi_io",
    "io_mibs", // MiB/s read and written
    "net_rx_mibs",
    "net_tx_mibs",
    "disk_free_gb",
    "disk_bytes",
    "reserved_mib", // memory reserved
    "used_mib",     // memory used of the reservation
    "headroom_mib", // admission's `avail − floor − reserved`
    "jobs",
    "gpu_util", // percent
    "gpu_mem_mib",
];

/// The stored byte of metric NAME (1-based), none for a name that is not one.
pub fn metric_code(name: &str) -> Option<u8> {
    METRICS.iter().position(|m| *m == name).map(|i| i as u8 + 1)
}

/// The name of stored byte CODE.
pub fn metric_name(code: u8) -> Option<&'static str> {
    METRICS.get(usize::from(code).checked_sub(1)?).copied()
}

/// One reading: the values of one id at one level at one instant (`at_ms`, epoch milliseconds).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Sample {
    pub at_ms: u64,
    pub level: Level,
    pub id: String,
    /// Metric name to value.
    pub values: BTreeMap<String, f64>,
}

/// A moment on the same timeline as the samples: a job admitted, a wait, a pause, a kill, a stage, a disk eviction.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Marker {
    pub at_ms: u64,
    /// What it is about: a job id, a slot instance or `runner`.
    pub id: String,
    /// `admitted`, `waited`, `paused`, `resumed`, `killed`, `stage-start`, `stage-end` or `evicted`.
    pub kind: String,
    pub detail: String,
}

/// One point of a stored series: the window starting at `t` (epoch ms), with every sample's extremes kept.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub t: u64,
    pub min: f64,
    pub max: f64,
    pub mean: f64,
    pub last: f64,
}

/// One metric of one id over time.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Series {
    pub level: Level,
    pub id: String,
    pub metric: String,
    pub points: Vec<Point>,
}

/// What a viewer asks the stored history for.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Range {
    pub level: Level,
    /// Empty: every id at the level.
    #[serde(default)]
    pub ids: Vec<String>,
    /// Epoch milliseconds, `from` inclusive and `to` exclusive.
    pub from: u64,
    pub to: u64,
    /// The width of a point; 0: the stored width.
    #[serde(default)]
    pub step_ms: u64,
}

/// The history a range found.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Ranged {
    pub series: Vec<Series>,
    pub markers: Vec<Marker>,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D] pure: the stored bytes of levels and metrics round-trip, and a name that is not one has none.
    #[test]
    fn levels_and_metrics_have_stable_codes() {
        for l in Level::ALL {
            assert_eq!(Level::from_code(l.code()), Some(l));
            assert_eq!(Level::parse(l.word()), Some(l));
        }
        assert_eq!(Level::from_code(0), None);
        for (i, m) in METRICS.iter().enumerate() {
            assert_eq!(metric_code(m), Some(i as u8 + 1));
            assert_eq!(metric_name(i as u8 + 1), Some(*m));
        }
        assert_eq!(metric_code("nope"), None);
        assert_eq!(metric_name(0), None);
        assert_eq!(metric_name(METRICS.len() as u8 + 1), None);
    }
}
