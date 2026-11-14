//! The pacing rule: a batch's worst submit over 8 ms halves the token budget, under 4 ms doubles it, up to
//! `TOKEN_CAP`; one chunk is the smallest batch.
//!
//! test-pattern: pure (D). `Pacer` has no clock: the submit times are values the test gives.

use hrafn_embed::TOKEN_CAP;
use hrafn_embed::pace::{PACE_START, Pacer};
use std::time::Duration;

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

/// Pattern D.
#[test]
fn halves_over_8_ms() {
    let mut p = Pacer::new();
    assert_eq!(p.budget(), PACE_START);
    assert_eq!(PACE_START, 2048);
    p.observe(ms(9));
    assert_eq!(p.budget(), 1024);
    p.observe(Duration::from_micros(8_001));
    assert_eq!(p.budget(), 512);
}

/// Pattern D.
#[test]
fn doubles_under_4_ms_up_to_the_cap() {
    let mut p = Pacer::new();
    p.observe(ms(3));
    assert_eq!(p.budget(), 4096);
    p.observe(ms(1));
    assert_eq!(p.budget(), TOKEN_CAP, "never over the cap");
    p.observe(Duration::ZERO);
    assert_eq!(p.budget(), TOKEN_CAP);
}

/// Pattern D.
#[test]
fn holds_between_4_and_8_ms() {
    let mut p = Pacer::new();
    for t in [ms(4), ms(5), ms(8)] {
        p.observe(t);
        assert_eq!(p.budget(), PACE_START, "{t:?}");
    }
}

/// Pattern D.
#[test]
fn never_below_the_next_chunk() {
    let mut p = Pacer::new();
    for _ in 0..12 {
        p.observe(ms(400));
    }
    // the next chunk alone is the batch, and the budget rises to it
    assert_eq!(p.take(&[700, 10, 10]), 1);
    assert_eq!(p.budget(), 700);
    p.observe(ms(20));
    assert_eq!(p.budget(), 350);
    assert_eq!(p.take(&[300, 300]), 1);
    assert_eq!(p.take(&[100, 100, 100, 100]), 3, "as many as fit");
    assert_eq!(p.take(&[]), 0);
    // a full budget takes what fits, in order
    let mut fresh = Pacer::new();
    assert_eq!(fresh.take(&[1000, 1000, 48, 1]), 3);
}
