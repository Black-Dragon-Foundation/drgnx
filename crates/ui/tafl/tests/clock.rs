//! Clock cells: a timer only while something reads the time, one aligned tick for readers of the same grain.

mod common;

use std::time::Duration;

use tafl::{Origin, Stage};

const MINUTE: Duration = Duration::from_secs(60);

/// No reader, no timer: the virtual clock has no sleeper once the last reader is gone.
#[test]
fn no_reader_no_timer() {
    let (sb, mut e) = common::engine();
    let clock = e.clock(MINUTE);
    assert_eq!(
        sb.clock().sleepers(),
        0,
        "a clock nobody reads armed a timer"
    );
    let s = e.slab(common::key("status", &[]));
    let ago = e.formula(s, Stage::Items, move |r| {
        format!("{} min", clock.get(r).as_secs() / 60)
    });
    assert_eq!(e.pull(ago), "0 min");
    assert_eq!(sb.clock().sleepers(), 1, "a read clock armed no timer");
    assert_eq!(e.stats().timers, 1);
    sb.advance(MINUTE);
    e.frame(&[ago.id()], Duration::from_millis(4));
    assert_eq!(e.pull(ago), "1 min");
    assert_eq!(sb.clock().sleepers(), 1);
    e.drop_slab(s);
    assert_eq!(
        sb.clock().sleepers(),
        0,
        "the timer outlived the last reader"
    );
    assert_eq!(e.stats().timers, 0);
    // idle: nothing armed, nothing requested
    sb.advance(MINUTE * 10);
    assert_eq!(sb.clock().sleepers(), 0);
}

/// Two one-minute readers share one aligned tick.
#[test]
fn two_minute_readers_share_one_tick() {
    let (sb, mut e) = common::engine();
    sb.advance(Duration::from_secs(25));
    let s = e.slab(common::key("status", &[]));
    let c1 = e.clock(MINUTE);
    let c2 = e.clock(MINUTE);
    let a = e.formula(s, Stage::Items, move |r| c1.get(r));
    let b = e.formula(s, Stage::Items, move |r| c2.get(r));
    assert_eq!(
        e.pull(a),
        Duration::ZERO,
        "the reading is not aligned to the minute"
    );
    assert_eq!(e.pull(b), Duration::ZERO);
    assert_eq!(
        sb.clock().sleepers(),
        1,
        "two readers of one grain armed two timers"
    );
    let ticks = e.stats().ticks;
    sb.advance(Duration::from_secs(35));
    let out = e.frame(&[a.id(), b.id()], Duration::from_millis(4));
    assert_eq!(out.changed_items.len(), 2);
    assert_eq!(
        e.stats().ticks,
        ticks + 1,
        "the readers did not share one tick"
    );
    assert_eq!(e.pull(a), MINUTE);
    assert_eq!(e.pull(b), MINUTE);
    assert_eq!(sb.clock().sleepers(), 1);
    // a write between ticks moves no clock
    let st = e.state(s, 0u8);
    e.write(Origin::User, |w| st.set(w, 1));
    assert_eq!(e.stats().ticks, ticks + 1);
}
