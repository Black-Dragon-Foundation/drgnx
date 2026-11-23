//! The test-harness standard (docs/develop/standards/test-harness.md). The sentinel-HOME run (`cargo xtask
//! test-sandbox`) runs these with HOME pointed at an empty directory and fails if anything lands there.

use std::future::Future;
use std::pin::pin;
use std::task::{Context, Poll, Waker};
use std::time::Duration;

#[test]
fn sandbox_home_is_not_real_home() {
    let sb = raun::Sandbox::new();
    // a test writes where the paths say: inside the sandbox (were the sandbox's paths skipped, this would land in the
    // sentinel HOME of `cargo xtask test-sandbox`)
    std::fs::create_dir_all(stig::state()).unwrap();
    eitri::replace_file(&stig::state().join("probe"), b"x").unwrap();
    assert_eq!(std::fs::read(stig::state().join("probe")).unwrap(), b"x");
    assert_eq!(stig::profile(), stig::Profile::Test);
    for d in [
        stig::config(),
        stig::state(),
        stig::cache(),
        stig::data(),
        stig::runtime(),
    ] {
        assert!(
            d.starts_with(sb.home()),
            "{d:?} is outside the sandbox {:?}",
            sb.home()
        );
    }
}

#[test]
fn virtual_clock_advances_timers() {
    let sb = raun::Sandbox::new();
    let mut timer = pin!(stund::sleep(Duration::from_secs(10)));
    let mut cx = Context::from_waker(Waker::noop());
    assert!(timer.as_mut().poll(&mut cx).is_pending());
    sb.advance(Duration::from_secs(9));
    assert!(
        timer.as_mut().poll(&mut cx).is_pending(),
        "fired a second early"
    );
    sb.advance(Duration::from_secs(1));
    assert_eq!(timer.as_mut().poll(&mut cx), Poll::Ready(()));
    assert_eq!(sb.clock().elapsed(), Duration::from_secs(10));
}

#[test]
fn a_dropped_sandbox_leaves_nothing_installed() {
    let home = {
        let sb = raun::Sandbox::new();
        sb.home().to_path_buf()
    };
    assert!(!home.exists(), "the temp HOME is removed with the sandbox");
    // the clock is tokio's again: no virtual clock answers
    let sb = raun::Sandbox::new();
    assert_eq!(sb.clock().elapsed(), Duration::ZERO);
}
