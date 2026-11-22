//! Receipt stamps: seconds since the Unix epoch, taken when a line is read, never going backwards (a clock step
//! cannot reorder a connection's timeline).

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static LAST: AtomicU64 = AtomicU64::new(0);

/// Now, as seconds since the epoch; each call returns at least what the previous one did.
pub fn now() -> f64 {
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64());
    // positive f64 bit patterns order like the numbers
    let prev = LAST.fetch_max(t.to_bits(), Ordering::AcqRel);
    f64::from_bits(prev).max(t)
}
