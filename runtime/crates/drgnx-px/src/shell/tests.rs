//! The shell's timers as pure functions of elapsed monotonic time ([D]).

use super::*;

/// [D] The sidecar's heartbeat is lost 60 s after the last `BEAT` on its own clock, not before.
#[test]
fn beat_timeout_is_60_s_of_the_sidecars_clock() {
    assert_eq!(BEAT_LIMIT, Duration::from_secs(60));
    assert!(!beat_lost(Duration::ZERO, BEAT_LIMIT));
    assert!(!beat_lost(Duration::from_millis(59_999), BEAT_LIMIT));
    assert!(beat_lost(Duration::from_secs(60), BEAT_LIMIT));
    assert!(beat_lost(Duration::from_secs(3_600), BEAT_LIMIT));
}

/// [D] A write without progress for 60 s is a stall; any progress starts the count again.
#[test]
fn a_write_without_progress_for_60_s_is_a_stall() {
    assert_eq!(STALL, Duration::from_secs(60));
    assert!(!stalled(Duration::from_millis(59_999), STALL));
    assert!(stalled(Duration::from_secs(60), STALL));
    // an injected limit, as the tests of both ends use
    assert!(stalled(
        Duration::from_millis(300),
        Duration::from_millis(300)
    ));
    assert!(!stalled(
        Duration::from_millis(299),
        Duration::from_millis(300)
    ));
}
