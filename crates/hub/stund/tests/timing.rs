//! The time source's own instants and blocking sleep: timing tests (real time is what the no-clock rows measure; the
//! rest read the virtual clock).

use std::time::Duration;

#[test]
fn an_instant_reads_the_installed_clock() {
    let clock = stund::Manual::default();
    let _on = clock.on_this_thread();
    let t0 = stund::Instant::now();
    clock.advance(Duration::from_secs(3));
    assert_eq!(t0.elapsed(), Duration::from_secs(3));
    assert_eq!(
        stund::Instant::now() - t0,
        Duration::from_secs(3),
        "the difference of two instants"
    );
    assert!(t0 + Duration::from_secs(4) > stund::Instant::now());
    assert_eq!(t0.checked_duration_since(t0 + Duration::from_secs(1)), None);
}

#[test]
fn a_blocking_sleep_ends_when_the_virtual_clock_moves() {
    let clock = stund::Manual::default();
    std::thread::scope(|s| {
        let c = clock.clone();
        let t = s.spawn(move || {
            // the sleeper reads a clock of its own thread: the same one the test moves
            let _on = c.on_this_thread();
            stund::sleep_blocking(Duration::from_secs(60));
        });
        // not due until the clock moves, however long it has really waited
        std::thread::sleep(Duration::from_millis(50));
        assert!(!t.is_finished());
        clock.advance(Duration::from_secs(60));
        t.join().expect("the sleeper returns");
    });
}

#[test]
fn a_blocking_sleep_waits_for_real_with_no_clock() {
    let start = std::time::Instant::now();
    stund::sleep_blocking(Duration::from_millis(30));
    assert!(start.elapsed() >= Duration::from_millis(30));
}

#[test]
fn instants_add_and_subtract_durations_and_each_other() {
    let clock = stund::Manual::default();
    let _on = clock.on_this_thread();
    clock.advance(Duration::from_secs(10));
    let t = stund::Instant::now();
    assert_eq!(
        t - Duration::from_secs(4),
        t.checked_sub(Duration::from_secs(4)).unwrap()
    );
    assert_eq!(
        (t - Duration::from_secs(4)).elapsed(),
        Duration::from_secs(4)
    );
    assert_eq!((t + Duration::from_secs(3)) - t, Duration::from_secs(3));
    assert_eq!(t - (t - Duration::from_secs(4)), Duration::from_secs(4));
    let mut u = t;
    u += Duration::from_secs(1);
    assert_eq!(u - t, Duration::from_secs(1));
}
