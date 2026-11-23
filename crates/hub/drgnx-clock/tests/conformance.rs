//! The time standard (docs/develop/standards/time.md): every timer waits on the installed clock, so a test's virtual
//! clock decides when it fires.

use std::future::Future;
use std::pin::pin;
use std::task::{Context, Poll, Waker};
use std::time::Duration;

#[test]
fn timers_wait_on_the_installed_clock() {
    let clock = drgnx_clock::Manual::default();
    let _on = clock.on_this_thread();
    let mut cx = Context::from_waker(Waker::noop());
    let mut timer = pin!(drgnx_clock::sleep(Duration::from_secs(5)));
    assert!(timer.as_mut().poll(&mut cx).is_pending());
    clock.advance(Duration::from_secs(5));
    assert_eq!(timer.as_mut().poll(&mut cx), Poll::Ready(()));
    assert_eq!(drgnx_clock::now(), Duration::from_secs(5));
}

#[test]
fn timeout_elapses_on_virtual_time() {
    let clock = drgnx_clock::Manual::default();
    let _on = clock.on_this_thread();
    let mut cx = Context::from_waker(Waker::noop());
    let mut t = pin!(drgnx_clock::timeout(
        Duration::from_secs(1),
        std::future::pending::<()>()
    ));
    assert!(t.as_mut().poll(&mut cx).is_pending());
    clock.advance(Duration::from_secs(1));
    assert_eq!(
        t.as_mut().poll(&mut cx),
        Poll::Ready(Err(drgnx_clock::Elapsed))
    );
}
