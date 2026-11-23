//! The engine's counters.

/// Counters since the engine was made (`cells`, `edges`, `bytes` and `timers` are current figures).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    /// Live cells.
    pub cells: u64,
    /// Live edges (one per source a cell reads).
    pub edges: u64,
    /// The engine's own estimate of its bytes (cell columns, nodes, spilled edges, lists).
    pub bytes: u64,
    /// Formula runs.
    pub runs: u64,
    /// Cells marked dirty or check.
    pub marks: u64,
    /// Marking passes (one per transaction that changed something).
    pub mark_passes: u64,
    /// Check cells whose sources were verified.
    pub verifies: u64,
    /// Frames requested.
    pub frame_requests: u64,
    /// Collection readers that started over (a trimmed log, a reset, a changed outside source).
    pub resets: u64,
    /// List items visited by operators and reads.
    pub item_visits: u64,
    /// Timers armed now (0 or 1: the clock cells share one).
    pub timers: u64,
    /// Clock ticks applied.
    pub ticks: u64,
    /// Jobs on the pool now.
    pub jobs: u64,
    /// Time spent in the engine's own bookkeeping, and in formulas, when timing is on.
    pub bookkeeping_ns: u64,
    pub work_ns: u64,
}
