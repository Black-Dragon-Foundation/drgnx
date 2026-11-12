//! Each session's block of loopback ports (spec §21): claimed, probed, released.
use super::ports::{Blocks, MAC_EPHEMERAL, free};

// the blocks' tests probe with their own function: on Linux other tests' outgoing connections take ports anywhere in
// 32768-60999, so a real probe of a fixed range would fail now and then

#[test]
fn the_default_range_is_below_the_ephemeral_ports() {
    let b = Blocks::default();
    assert!(b.range().end <= MAC_EPHEMERAL);
    assert_eq!(b.size(), 8);
}

#[test]
fn a_port_a_listener_holds_is_not_free() {
    let held = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    assert!(!free(held.local_addr().unwrap().port()));
}

#[test]
fn two_sessions_get_disjoint_blocks_and_a_released_block_comes_back() {
    let blocks = Blocks::with_probe(46100..46124, 8, |_| true);
    let a = blocks.claim().unwrap();
    let b = blocks.claim().unwrap();
    assert_eq!(a.ports(), (46100..46108).collect::<Vec<_>>());
    assert_eq!(b.ports(), (46108..46116).collect::<Vec<_>>());
    drop(a);
    let c = blocks.claim().unwrap();
    assert_eq!(c.ports()[0], 46100);
    drop(b);
    drop(c);
}

#[test]
fn a_block_with_a_port_another_process_listens_on_is_passed_over() {
    // the block's fourth port is taken (as the macOS runner's 47610 was)
    let blocks = Blocks::with_probe(46200..46216, 8, |p| p != 46203);
    let b = blocks.claim().unwrap();
    assert_eq!(b.ports()[0], 46208);
}

#[test]
fn when_every_block_is_taken_the_session_is_refused_with_the_range() {
    let blocks = Blocks::with_probe(46300..46316, 8, |p| p != 46310);
    let _a = blocks.claim().unwrap();
    let e = blocks.claim().unwrap_err();
    assert!(e.contains("46300") && e.contains("46315"), "{e}");
}
