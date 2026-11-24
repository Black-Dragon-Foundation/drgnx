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
        stund::real::sleep_blocking(Duration::from_millis(50));
        assert!(!t.is_finished());
        clock.advance(Duration::from_secs(60));
        t.join().expect("the sleeper returns");
    });
}

#[test]
fn a_blocking_sleep_waits_for_real_with_no_clock() {
    let start = stund::real::instant();
    stund::sleep_blocking(Duration::from_millis(30));
    assert!(start.elapsed() >= Duration::from_millis(30));
}

/// `wall` is the system's time of day when no clock says otherwise, and a clock that does says it.
#[test]
fn the_time_of_day_is_the_systems_unless_a_clock_says_otherwise() {
    let since_epoch = stund::wall().duration_since(std::time::UNIX_EPOCH).unwrap();
    assert!(
        since_epoch > Duration::from_secs(1_700_000_000),
        "{since_epoch:?}"
    );

    struct Fixed;
    impl stund::Provider for Fixed {
        fn sleep(&self, _: Duration) -> std::pin::Pin<Box<dyn Future<Output = ()> + Send>> {
            Box::pin(std::future::pending())
        }
        fn now(&self) -> Duration {
            Duration::ZERO
        }
        fn wall(&self) -> std::time::SystemTime {
            std::time::UNIX_EPOCH + Duration::from_secs(1_000)
        }
    }
    let _on = stund::on_this_thread(std::sync::Arc::new(Fixed));
    assert_eq!(
        stund::wall(),
        std::time::UNIX_EPOCH + Duration::from_secs(1_000)
    );
}

/// `real` is the system's monotonic clock whatever clock is installed: it moves with real time only.
#[test]
fn the_real_clock_ignores_the_installed_one() {
    let clock = stund::Manual::default();
    let _on = clock.on_this_thread();
    let a = stund::real::instant();
    clock.advance(Duration::from_secs(3600));
    stund::real::sleep_blocking(Duration::from_millis(5));
    let spent = a.elapsed();
    assert!(spent >= Duration::from_millis(5) && spent < Duration::from_secs(60));
}

/// `real::wall` is the system's time of day whatever clock is installed: a virtual clock's base is not the virtual time.
#[test]
fn the_real_wall_ignores_the_installed_clock() {
    let clock = stund::Manual::default();
    let _on = clock.on_this_thread();
    clock.advance(Duration::from_secs(3600));
    assert_ne!(
        stund::wall(),
        stund::real::wall(),
        "the installed clock is virtual"
    );
    let since = stund::real::wall()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap();
    assert!(
        since > Duration::from_secs(1_700_000_000),
        "the system's time of day, not the manual clock's"
    );
}

#[test]
fn next_due_is_the_wait_to_the_earliest_timer() {
    let clock = stund::Manual::default();
    let _on = clock.on_this_thread();
    assert_eq!(clock.next_due(), None, "no timer waits");
    let mut cx = Context::from_waker(Waker::noop());
    let mut late = pin!(stund::sleep(Duration::from_secs(9)));
    let mut early = pin!(stund::sleep(Duration::from_secs(4)));
    assert!(late.as_mut().poll(&mut cx).is_pending());
    assert!(early.as_mut().poll(&mut cx).is_pending());
    assert_eq!(clock.next_due(), Some(Duration::from_secs(4)));
    clock.advance(Duration::from_secs(1));
    assert_eq!(clock.next_due(), Some(Duration::from_secs(3)));
    clock.advance(Duration::from_secs(3));
    assert_eq!(early.as_mut().poll(&mut cx), Poll::Ready(()));
    assert_eq!(clock.next_due(), Some(Duration::from_secs(5)));
}

/// `real::tokio_instant` is tokio's clock: a test that pauses and advances it moves it.
#[tokio::test(start_paused = true)]
async fn the_tokio_instant_follows_tokios_paused_clock() {
    let a = stund::real::tokio_instant();
    tokio::time::advance(Duration::from_secs(3600)).await;
    assert!(a.elapsed() >= Duration::from_secs(3600));
}
