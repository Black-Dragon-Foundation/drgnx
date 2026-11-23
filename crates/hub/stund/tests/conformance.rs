//! The time standard (docs/develop/standards/time.md): every timer waits on the installed clock, so a test's virtual
//! clock decides when it fires.

use std::future::Future;
use std::pin::pin;
use std::task::{Context, Poll, Waker};
use std::time::Duration;

#[test]
fn timers_wait_on_the_installed_clock() {
    let clock = stund::Manual::default();
    let _on = clock.on_this_thread();
    let mut cx = Context::from_waker(Waker::noop());
    let mut timer = pin!(stund::sleep(Duration::from_secs(5)));
    assert!(timer.as_mut().poll(&mut cx).is_pending());
    clock.advance(Duration::from_secs(5));
    assert_eq!(timer.as_mut().poll(&mut cx), Poll::Ready(()));
    assert_eq!(stund::now(), Duration::from_secs(5));
}

#[test]
fn timeout_elapses_on_virtual_time() {
    let clock = stund::Manual::default();
    let _on = clock.on_this_thread();
    let mut cx = Context::from_waker(Waker::noop());
    let mut t = pin!(stund::timeout(
        Duration::from_secs(1),
        std::future::pending::<()>()
    ));
    assert!(t.as_mut().poll(&mut cx).is_pending());
    clock.advance(Duration::from_secs(1));
    assert_eq!(t.as_mut().poll(&mut cx), Poll::Ready(Err(stund::Elapsed)));
}

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
