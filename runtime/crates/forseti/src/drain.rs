//! Drains: emptying a machine for a whole-machine run. A timing run that has started is never stopped.

/// A drain gives up when the machine hasn't emptied within this long, and is retried later.
pub const DRAIN_ABANDON_S: u64 = 1800;
/// After this long draining, running P5 restartable jobs may be evicted (once each).
pub const DRAIN_EVICT_P5_S: u64 = 900;

/// A drain starts only when no P1 or P2 work is queued or running for the machine.
pub fn drain_may_start(pending_p12: bool) -> bool {
    !pending_p12
}

/// A P1 arrival pauses the drain: admission reopens until no P1 or P2 work remains.
pub fn drain_paused(p1_arrived: bool) -> bool {
    p1_arrived
}

/// A drain started at `started` that hasn't emptied the machine by `now` is given up after [`DRAIN_ABANDON_S`].
pub fn drain_abandon(started: u64, now: u64) -> bool {
    now.saturating_sub(started) >= DRAIN_ABANDON_S
}

/// Running P5 restartable jobs may be evicted once the drain has gone [`DRAIN_EVICT_P5_S`].
pub fn drain_may_evict_p5(started: u64, now: u64) -> bool {
    now.saturating_sub(started) >= DRAIN_EVICT_P5_S
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drain_rules() {
        // [D] pure
        assert!(drain_may_start(false));
        assert!(!drain_may_start(true));
        assert!(drain_paused(true));
        assert!(!drain_paused(false));
        assert!(!drain_abandon(100, 100 + 1799));
        assert!(drain_abandon(100, 100 + DRAIN_ABANDON_S));
        assert!(!drain_may_evict_p5(100, 100 + 899));
        assert!(drain_may_evict_p5(100, 100 + DRAIN_EVICT_P5_S));
        assert!(
            !drain_abandon(500, 100),
            "a clock behind the start is no time"
        );
    }
}
