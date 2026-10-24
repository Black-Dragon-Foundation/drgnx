//! The nightly backup's schedule (Urdr Task 17; storage §8.1): at 03:00 local time, or at the first idle minute after
//! a missed one, the hub makes a checked copy of `work.db` (`graph::backup_now`: `VACUUM INTO`, check, rotate).
//!
//! [`due`] is pure (the clock is its arguments), so the catch-up is tested without waiting for a night.  The hub's
//! schema tick asks it every 2 s.  What the last copy was stays in a process-wide record that `status.store` shows
//! (`last_backup`, `backup_ok`) and the doctor judges; at start it is read from the newest `work-*.db` in the backup
//! folder, so a restart does not make a second copy the same day.
//!
//! No copy runs while an excise runs ([`excising`]) or the store is not open and ready.

use std::path::Path;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

/// 03:00, in minutes after local midnight.
pub const AT_MINUTE: u32 = 3 * 60;

/// After a failed copy, how long before the next try (seconds).
pub const RETRY_AFTER: u64 = 3600;

/// A local calendar day (a number that differs from every other day's) and the minute in it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Local {
    pub day: i64,
    pub minute: u32,
}

/// Whether a copy is due now: it is 03:00 or later and no good copy was made today, and the last try (if any) is not
/// recent.  A hub that was down at 03:00 therefore copies at its first tick after it starts.
pub fn due(now: Local, last_ok: Option<Local>, since_attempt: Option<u64>) -> bool {
    now.minute >= AT_MINUTE
        && last_ok.is_none_or(|l| l.day != now.day)
        && since_attempt.is_none_or(|s| s >= RETRY_AFTER)
}

/// SECS (unix) in the machine's local time.
pub fn local(secs: u64) -> Local {
    let t = secs as libc::time_t;
    // SAFETY: `tm` is plain data, zeroed is a valid value; localtime_r writes only into it.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let ok = unsafe { !libc::localtime_r(&t, &mut tm).is_null() };
    if !ok {
        return Local {
            day: (secs / 86400) as i64,
            minute: ((secs % 86400) / 60) as u32,
        };
    }
    Local {
        day: i64::from(tm.tm_year) * 366 + i64::from(tm.tm_yday),
        minute: (tm.tm_hour * 60 + tm.tm_min) as u32,
    }
}

/// The last copy made or tried, and the last good one (unix seconds).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Last {
    pub attempt: Option<(u64, bool)>,
    pub ok_at: Option<u64>,
}

static LAST: Mutex<Last> = Mutex::new(Last {
    attempt: None,
    ok_at: None,
});
static RUNNING: AtomicBool = AtomicBool::new(false);
static EXCISING: AtomicUsize = AtomicUsize::new(0);

/// The record, as it is now.
pub fn last() -> Last {
    *LAST.lock().unwrap_or_else(|e| e.into_inner())
}

/// A copy made (or failed) at AT.
pub fn record(at: u64, ok: bool) {
    let mut l = LAST.lock().unwrap_or_else(|e| e.into_inner());
    l.attempt = Some((at, ok));
    if ok {
        l.ok_at = Some(at);
    }
}

/// When the newest dated copy (`work-*.db`, not the pre-migration one) in DIR was made (unix seconds).
fn newest_copy(dir: &Path) -> Option<u64> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| {
            let n = e.file_name();
            let n = n.to_string_lossy();
            n.starts_with("work-") && n.ends_with(".db") && !n.starts_with("work-pre7-")
        })
        .filter_map(|e| e.metadata().ok()?.modified().ok())
        .filter_map(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .max()
}

/// At start: the newest `work-*.db` in DIR is the last good copy (only checked copies are renamed into place).
pub fn seed(dir: &Path) {
    if let Some(at) = newest_copy(dir) {
        let mut l = LAST.lock().unwrap_or_else(|e| e.into_inner());
        if l.attempt.is_none() {
            l.attempt = Some((at, true));
            l.ok_at = Some(at);
        }
    }
}

/// An excise is running while this lives: no copy starts.
pub struct Excising(());

pub fn excising() -> Excising {
    EXCISING.fetch_add(1, Ordering::SeqCst);
    Excising(())
}

impl Drop for Excising {
    fn drop(&mut self) {
        EXCISING.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Take the right to run a copy: false while another runs or an excise does.  Pair with [`finish`].
pub fn begin() -> bool {
    EXCISING.load(Ordering::SeqCst) == 0
        && RUNNING
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
}

pub fn finish() {
    RUNNING.store(false, Ordering::SeqCst);
}

/// Whether the tick at NOW (unix seconds) should start the nightly copy.
pub fn due_at(now: u64) -> bool {
    let l = last();
    due(
        local(now),
        l.ok_at.map(local),
        l.attempt.map(|(at, _)| now.saturating_sub(at)),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(day: i64, hour: u32, minute: u32) -> Local {
        Local {
            day,
            minute: hour * 60 + minute,
        }
    }

    #[test]
    fn backup_timer_catches_up_after_a_missed_night() {
        // a copy was made on day 10 at 03:00; the clock is a number of minutes since then
        let ok = Some(at(10, 3, 0));
        assert!(!due(at(10, 3, 1), ok, Some(60)), "already copied today");
        assert!(!due(at(11, 2, 59), ok, Some(23 * 3600)), "before 03:00");
        assert!(due(at(11, 3, 0), ok, Some(24 * 3600)), "03:00 sharp");
        // the hub was down all of day 11 and starts on day 12 at 09:12: the first tick copies
        assert!(due(at(12, 9, 12), ok, Some(54 * 3600)));
        // never copied: a hub started at 14:00 copies, one started at 01:00 waits for 03:00
        assert!(due(at(5, 14, 0), None, None));
        assert!(!due(at(5, 1, 0), None, None));
        // a failed try is not repeated every tick
        assert!(!due(at(12, 9, 13), ok, Some(60)));
        assert!(due(at(12, 10, 13), ok, Some(RETRY_AFTER)));
    }

    #[test]
    fn local_days_differ_and_minutes_stay_in_a_day() {
        let a = local(1_700_000_000);
        let b = local(1_700_000_000 + 86400);
        assert_eq!(b.day, a.day + 1);
        assert!(a.minute < 1440);
    }

    #[test]
    fn the_newest_copy_skips_the_pre_migration_one() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("work-pre7-1.db"), b"x").unwrap();
        std::fs::write(dir.path().join("notes.txt"), b"x").unwrap();
        assert_eq!(newest_copy(dir.path()), None);
        std::fs::write(dir.path().join("work-20261023.db"), b"x").unwrap();
        assert!(newest_copy(dir.path()).is_some());
    }
}
