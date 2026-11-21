//! The state machine's rules on single scenarios (pure, [D]). The every-order tests of both ends together are in
//! `orders.rs`.

use std::net::{IpAddr, Ipv4Addr};

use super::*;
use crate::frame::{Frame, Kind, MAX_DATA, MAX_STREAMS, WINDOW};
use crate::pending::Pending;

fn rx(m: &mut Mux, f: Frame) -> Result<Vec<Out>, StreamViolation> {
    m.step(In::Frame(f))
}

fn ok(m: &mut Mux, ev: In) -> Vec<Out> {
    m.step(ev.clone())
        .unwrap_or_else(|v| panic!("{ev:?}: {v:?}"))
}

fn ready() -> Frame {
    Frame::ready("127.0.0.1:3128".parse().unwrap())
}

/// An owner that has seen `READY` and `n` streams opened (1, 3, …).
fn owner(n: u32) -> Mux {
    let mut m = Mux::new(Side::Owner);
    ok(&mut m, In::Frame(ready()));
    for i in 0..n {
        let s = 2 * i + 1;
        assert_eq!(
            ok(&mut m, In::Frame(open(s))),
            vec![Out::NewStream { stream: s }]
        );
    }
    m
}

/// A sidecar with `n` streams opened locally.
fn sidecar(n: u32) -> Mux {
    let mut m = Mux::new(Side::Sidecar);
    for i in 0..n {
        let s = 2 * i + 1;
        assert_eq!(ok(&mut m, In::LocalOpen), vec![Out::Send(open(s))]);
    }
    m
}

fn open(s: u32) -> Frame {
    Frame::empty(s, Kind::Open)
}

fn fin(s: u32) -> Frame {
    Frame::empty(s, Kind::Fin)
}

fn rst(s: u32) -> Frame {
    Frame::empty(s, Kind::Rst)
}

fn data(s: u32, len: usize) -> Frame {
    Frame::data(s, vec![0; len])
}

fn ip(n: u32) -> IpAddr {
    IpAddr::V4(Ipv4Addr::from(0x0A00_0000 + n))
}

/// [D] Only the sidecar opens streams: an `OPEN` reaching the sidecar, or a local open on the owner, is wrong-side.
#[test]
fn owner_side_opening_a_stream_is_a_violation() {
    let mut s = Mux::new(Side::Sidecar);
    assert_eq!(
        rx(&mut s, open(1)),
        Err(StreamViolation::WrongSide(Kind::Open))
    );
    let mut o = owner(0);
    assert_eq!(
        o.step(In::LocalOpen),
        Err(StreamViolation::WrongSide(Kind::Open))
    );
}

/// [D] `READY` and `EVENT` come from the sidecar only, `BEAT` from the owner only.
#[test]
fn ready_event_from_the_owner_and_beat_from_the_sidecar_are_wrong_side() {
    let mut s = Mux::new(Side::Sidecar);
    assert_eq!(
        rx(&mut s, ready()),
        Err(StreamViolation::WrongSide(Kind::Ready))
    );
    let mut s = Mux::new(Side::Sidecar);
    assert_eq!(
        rx(&mut s, Frame::event(ip(1))),
        Err(StreamViolation::WrongSide(Kind::Event))
    );
    // the sidecar takes a BEAT, before anything else too
    let mut s = Mux::new(Side::Sidecar);
    assert_eq!(rx(&mut s, Frame::empty(0, Kind::Beat)), Ok(vec![]));
    let mut o = owner(0);
    assert_eq!(
        rx(&mut o, Frame::empty(0, Kind::Beat)),
        Err(StreamViolation::WrongSide(Kind::Beat))
    );
}

/// [D] The peer may send `WINDOW` bytes before a `CREDIT`; one more is over credit.
#[test]
fn data_past_the_window_is_over_credit() {
    let mut o = owner(1);
    for _ in 0..(WINDOW as usize / MAX_DATA) {
        ok(&mut o, In::Frame(data(1, MAX_DATA)));
    }
    assert_eq!(rx(&mut o, data(1, 1)), Err(StreamViolation::OverCredit(1)));
    // and the sidecar the same way
    let mut s = sidecar(1);
    for _ in 0..(WINDOW as usize / MAX_DATA) {
        ok(&mut s, In::Frame(data(1, MAX_DATA)));
    }
    assert_eq!(rx(&mut s, data(1, 1)), Err(StreamViolation::OverCredit(1)));
}

/// [D] `DATA` for a closed stream is discarded but counted against the credit the peer had left; past it, a
/// violation.
#[test]
fn discarded_data_still_counts_against_the_tombstone() {
    let mut o = owner(1);
    for _ in 0..8 {
        ok(&mut o, In::Frame(data(1, MAX_DATA)));
    }
    ok(&mut o, In::LocalReset { stream: 1 });
    for _ in 0..8 {
        assert_eq!(
            ok(&mut o, In::Frame(data(1, MAX_DATA))),
            vec![Out::Discarded {
                stream: 1,
                kind: Kind::Data
            }]
        );
    }
    assert_eq!(rx(&mut o, data(1, 1)), Err(StreamViolation::OverCredit(1)));
}

/// [D] A `CREDIT` may give back what was sent and not yet credited, no more.
#[test]
fn a_credit_above_the_window_is_credit_overflow() {
    let mut o = owner(1);
    assert_eq!(
        rx(&mut o, Frame::credit(1, 1)),
        Err(StreamViolation::CreditOverflow(1))
    );
    let mut o = owner(1);
    ok(
        &mut o,
        In::LocalData {
            stream: 1,
            bytes: vec![0; 100],
        },
    );
    assert_eq!(o.credit(1), WINDOW - 100);
    assert_eq!(
        ok(&mut o, In::Frame(Frame::credit(1, 60))),
        vec![Out::CreditFor { stream: 1 }]
    );
    assert_eq!(
        rx(&mut o, Frame::credit(1, 41)),
        Err(StreamViolation::CreditOverflow(1))
    );
}

/// [D] `DATA`, `CREDIT`, `FIN` and `RST` above the highest opened id are violations; the right `OPEN` there opens.
#[test]
fn an_id_above_the_highest_is_a_violation_unless_a_correct_open() {
    for f in [data(1, 1), Frame::credit(1, 1), fin(1), rst(1)] {
        let kind = f.kind;
        let mut o = owner(0);
        assert_eq!(
            rx(&mut o, f),
            Err(StreamViolation::AboveHighest(1)),
            "{kind:?}"
        );
    }
    let mut o = owner(1);
    assert_eq!(
        rx(&mut o, data(3, 1)),
        Err(StreamViolation::AboveHighest(3))
    );
    let mut s = sidecar(0);
    assert_eq!(
        rx(&mut s, data(1, 1)),
        Err(StreamViolation::AboveHighest(1))
    );
}

/// [D] `OPEN`s come as 1, 3, 5, …: a gap, a repeat or a step back is a violation.
#[test]
fn stream_ids_must_rise_by_two() {
    let mut o = owner(0);
    assert_eq!(rx(&mut o, open(3)), Err(StreamViolation::NotRisingByTwo(3)));
    let mut o = owner(1);
    assert_eq!(rx(&mut o, open(1)), Err(StreamViolation::NotRisingByTwo(1)));
    let mut o = owner(1);
    assert_eq!(rx(&mut o, open(5)), Err(StreamViolation::NotRisingByTwo(5)));
    let mut o = owner(1);
    assert_eq!(
        ok(&mut o, In::Frame(open(3))),
        vec![Out::NewStream { stream: 3 }]
    );
}

/// [D] After the peer's `FIN`, its `DATA` and a second `FIN` are violations while the stream is open.
#[test]
fn data_after_fin_and_a_second_fin_are_violations() {
    let mut o = owner(1);
    assert_eq!(
        ok(&mut o, In::Frame(fin(1))),
        vec![Out::CloseWrite { stream: 1 }]
    );
    assert_eq!(
        rx(&mut o, data(1, 1)),
        Err(StreamViolation::DataAfterFin(1))
    );
    let mut o = owner(1);
    ok(&mut o, In::Frame(fin(1)));
    assert_eq!(rx(&mut o, fin(1)), Err(StreamViolation::SecondFin(1)));
}

/// [D] The sidecar's first frame is its one `READY`.
#[test]
fn ready_must_come_first_and_once() {
    for f in [open(1), Frame::event(ip(1)), data(1, 1)] {
        let mut o = Mux::new(Side::Owner);
        assert_eq!(rx(&mut o, f), Err(StreamViolation::ReadyNotFirst));
    }
    let mut o = owner(0);
    assert_eq!(rx(&mut o, ready()), Err(StreamViolation::ReadyTwice));
}

/// [D] 1024 tombstones are kept, oldest out first: frames for an evicted stream are discarded uncounted, a kept one
/// still counts.
#[test]
fn the_1025th_tombstone_evicts_the_oldest() {
    let mut o = owner(0);
    for i in 0..1025u32 {
        let s = 2 * i + 1;
        ok(&mut o, In::Frame(open(s)));
        ok(&mut o, In::LocalReset { stream: s });
        ok(
            &mut o,
            In::Wrote {
                stream: s,
                kind: Kind::Rst,
            },
        );
    }
    assert_eq!(o.counted(), 0);
    // stream 1 is evicted: more than a window's worth is discarded with no violation
    for _ in 0..=(WINDOW as usize / MAX_DATA) {
        assert_eq!(
            ok(&mut o, In::Frame(data(1, MAX_DATA))),
            vec![Out::Discarded {
                stream: 1,
                kind: Kind::Data
            }]
        );
    }
    // stream 3 is kept: its window counts
    for _ in 0..(WINDOW as usize / MAX_DATA) {
        ok(&mut o, In::Frame(data(3, MAX_DATA)));
    }
    assert_eq!(rx(&mut o, data(3, 1)), Err(StreamViolation::OverCredit(3)));
}

/// [D] The last id is 2³¹−1; the open after it is `IdsUsedUp`, and nothing opens.
#[test]
fn the_last_stream_id_ends_with_ids_used_up() {
    let mut s = Mux::new(Side::Sidecar);
    s.set_highest(LAST_ID - 2);
    assert_eq!(ok(&mut s, In::LocalOpen), vec![Out::Send(open(LAST_ID))]);
    assert_eq!(ok(&mut s, In::LocalOpen), vec![Out::IdsUsedUp]);
    assert_eq!(s.counted(), 1);
    let mut o = owner(0);
    o.set_highest(LAST_ID - 2);
    assert_eq!(
        ok(&mut o, In::Frame(open(LAST_ID))),
        vec![Out::NewStream { stream: LAST_ID }]
    );
}

/// [D] At 64 counted the owner refuses an `OPEN` with `RST` and a tombstone, `H` moves on, and the other 64 streams
/// and the channel stay whole.
#[test]
fn the_65th_open_is_refused_with_rst() {
    let mut o = owner(MAX_STREAMS as u32);
    assert_eq!(ok(&mut o, In::Frame(open(129))), vec![Out::Send(rst(129))]);
    assert_eq!(o.counted(), MAX_STREAMS);
    // the refused stream's in-flight frames are discarded, counted against its window
    assert_eq!(
        ok(&mut o, In::Frame(data(129, 10))),
        vec![Out::Discarded {
            stream: 129,
            kind: Kind::Data
        }]
    );
    assert_eq!(ok(&mut o, In::Frame(open(131))), vec![Out::Send(rst(131))]);
    assert_eq!(
        ok(&mut o, In::Frame(data(127, 5))),
        vec![Out::Deliver {
            stream: 127,
            bytes: vec![0; 5]
        }]
    );
    // writing a refusal frees nothing counted
    assert_eq!(
        ok(
            &mut o,
            In::Wrote {
                stream: 129,
                kind: Kind::Rst
            }
        ),
        vec![]
    );
    assert_eq!(o.counted(), MAX_STREAMS);
}

/// [D] With 64 refusals unwritten, a further `OPEN` at the cap is `TooMany`; once one is written, it is refused
/// again.
#[test]
fn an_open_past_64_unwritten_refusals_is_too_many() {
    let mut o = owner(MAX_STREAMS as u32);
    for i in 0..MAX_STREAMS as u32 {
        let s = 129 + 2 * i;
        assert_eq!(ok(&mut o, In::Frame(open(s))), vec![Out::Send(rst(s))]);
    }
    assert_eq!(rx(&mut o.clone(), open(257)), Err(StreamViolation::TooMany));
    ok(
        &mut o,
        In::Wrote {
            stream: 129,
            kind: Kind::Rst,
        },
    );
    assert_eq!(ok(&mut o, In::Frame(open(257))), vec![Out::Send(rst(257))]);
}

/// [D] A stream closed by this end counts until its closing frame is written; closed by the peer's frame, it stops
/// at once; `Room` goes out as the count falls below 64.
#[test]
fn a_closing_frame_counts_until_written() {
    // our RST
    let mut s = sidecar(1);
    ok(&mut s, In::LocalReset { stream: 1 });
    assert_eq!(s.counted(), 1, "LocalReset alone");
    ok(
        &mut s,
        In::Wrote {
            stream: 1,
            kind: Kind::Rst,
        },
    );
    assert_eq!(s.counted(), 0);
    // our FIN second
    let mut s = sidecar(1);
    ok(&mut s, In::Frame(fin(1)));
    ok(&mut s, In::LocalEof { stream: 1 });
    assert_eq!(s.counted(), 1);
    ok(
        &mut s,
        In::Wrote {
            stream: 1,
            kind: Kind::Fin,
        },
    );
    assert_eq!(s.counted(), 0);
    // our FIN first, still held when the peer's arrives: counted until ours is written
    let mut s = sidecar(1);
    ok(&mut s, In::LocalEof { stream: 1 });
    ok(&mut s, In::Frame(fin(1)));
    assert_eq!(s.counted(), 1);
    ok(
        &mut s,
        In::Wrote {
            stream: 1,
            kind: Kind::Fin,
        },
    );
    assert_eq!(s.counted(), 0);
    // our FIN first and written: the peer's closes it at once
    let mut s = sidecar(1);
    ok(&mut s, In::LocalEof { stream: 1 });
    ok(
        &mut s,
        In::Wrote {
            stream: 1,
            kind: Kind::Fin,
        },
    );
    assert_eq!(s.counted(), 1);
    ok(&mut s, In::Frame(fin(1)));
    assert_eq!(s.counted(), 0);
    // the peer's RST, with our FIN unwritten
    let mut s = sidecar(1);
    ok(&mut s, In::LocalEof { stream: 1 });
    assert_eq!(ok(&mut s, In::Frame(rst(1))), vec![Out::Drop { stream: 1 }]);
    assert_eq!(s.counted(), 0);
    // Room: at the write of the closing frame, not before
    let mut s = sidecar(MAX_STREAMS as u32);
    assert_eq!(
        ok(&mut s, In::LocalReset { stream: 1 }),
        vec![Out::Send(rst(1)), Out::Drop { stream: 1 }]
    );
    assert_eq!(
        ok(
            &mut s,
            In::Wrote {
                stream: 1,
                kind: Kind::Rst
            }
        ),
        vec![Out::Room]
    );
    assert_eq!(ok(&mut s, In::LocalOpen), vec![Out::Send(open(129))]);
    assert_eq!(
        ok(&mut s, In::Frame(rst(3))),
        vec![Out::Drop { stream: 3 }, Out::Room]
    );
}

/// [D] A local open at 64 counted is the shell's bug, returned rather than asserted.
#[test]
fn a_local_open_at_64_is_an_error() {
    let mut s = sidecar(MAX_STREAMS as u32);
    assert_eq!(s.step(In::LocalOpen), Err(StreamViolation::LocalTooMany));
}

/// [D] Local events for a closed (or never opened) stream change nothing and say nothing.
#[test]
fn local_events_for_a_closed_stream_are_no_ops() {
    let mut s = sidecar(1);
    ok(&mut s, In::Frame(rst(1)));
    for stream in [1, 99] {
        for ev in [
            In::LocalData {
                stream,
                bytes: vec![1; 10],
            },
            In::LocalDrained { stream, n: 10 },
            In::LocalEof { stream },
            In::LocalReset { stream },
        ] {
            assert_eq!(ok(&mut s, ev), vec![]);
        }
    }
    assert_eq!(s.counted(), 0);
}

/// [D] `CREDIT` goes out when the queue empties or 64 KiB are uncredited, and the writer holds at most one per
/// stream.
#[test]
fn credit_is_coalesced() {
    let mut o = owner(1);
    for _ in 0..3 {
        ok(&mut o, In::Frame(data(1, MAX_DATA)));
    }
    let n = MAX_DATA as u32;
    assert_eq!(ok(&mut o, In::LocalDrained { stream: 1, n }), vec![]);
    assert_eq!(ok(&mut o, In::LocalDrained { stream: 1, n }), vec![]);
    assert_eq!(
        ok(&mut o, In::LocalDrained { stream: 1, n }),
        vec![Out::Send(Frame::credit(1, 3 * n))],
        "the queue emptied"
    );
    for _ in 0..5 {
        ok(&mut o, In::Frame(data(1, MAX_DATA)));
    }
    for _ in 0..3 {
        assert_eq!(ok(&mut o, In::LocalDrained { stream: 1, n }), vec![]);
    }
    let fourth = ok(&mut o, In::LocalDrained { stream: 1, n });
    assert_eq!(
        fourth,
        vec![Out::Send(Frame::credit(1, CREDIT_AT))],
        "64 KiB uncredited"
    );
    // two CREDITs waiting for the writer leave as one
    let mut p = Pending::new(Side::Owner);
    p.push(Frame::credit(1, 3 * n));
    for o in fourth {
        let Out::Send(f) = o else { unreachable!() };
        p.push(f);
    }
    assert_eq!(p.next(), Some(Frame::credit(1, 3 * n + CREDIT_AT)));
    assert_eq!(p.next(), None);
}

/// [D] A foreign source is reported once per address, at most 10 a second by the given clock; the rest are counted,
/// with one `EventsCounted` a second.
#[test]
fn events_are_once_per_address_and_capped_at_10_a_second() {
    let mut o = owner(0);
    o.set_now(Duration::from_millis(100));
    let mut reported = 0;
    for i in 0..12 {
        let outs = ok(&mut o, In::Frame(Frame::event(ip(i))));
        match i {
            0..10 => assert_eq!(outs, vec![Out::Event(ForeignSource(ip(i)))]),
            10 => assert_eq!(outs, vec![Out::EventsCounted(1)]),
            _ => assert_eq!(outs, vec![], "counted, not said again this second"),
        }
        reported += outs.iter().filter(|o| matches!(o, Out::Event(_))).count();
    }
    assert_eq!(reported, 10);
    assert_eq!(ok(&mut o, In::Frame(Frame::event(ip(0)))), vec![], "seen");
    o.set_now(Duration::from_millis(1_000));
    assert_eq!(
        ok(&mut o, In::Frame(Frame::event(ip(10)))),
        vec![Out::Event(ForeignSource(ip(10)))],
        "a new second"
    );
}

/// [D] At most 256 addresses are remembered: the 257th distinct one is counted, not reported.
#[test]
fn the_seen_set_holds_256_then_counts() {
    let mut o = owner(0);
    for i in 0..256u32 {
        o.set_now(Duration::from_secs(u64::from(i / 10)));
        assert_eq!(
            ok(&mut o, In::Frame(Frame::event(ip(i)))),
            vec![Out::Event(ForeignSource(ip(i)))]
        );
    }
    o.set_now(Duration::from_secs(100));
    assert_eq!(
        ok(&mut o, In::Frame(Frame::event(ip(256)))),
        vec![Out::EventsCounted(1)]
    );
    assert_eq!(
        ok(&mut o, In::Frame(Frame::event(ip(5)))),
        vec![],
        "still seen"
    );
}

/// [D] A key stream (an `OPEN` with the key mark) on an owner whose job has no keys is a violation, which ends the
/// channel; on a keyed owner it is a key stream, never one for the proxy, and a plain `OPEN` stays the proxy's. The
/// sidecar opens a key stream only when it is keyed itself.
#[test]
fn a_key_stream_needs_a_keyed_channel() {
    let mut m = Mux::new(Side::Owner);
    ok(&mut m, In::Frame(ready()));
    assert_eq!(
        rx(&mut m, Frame::open_key(1)),
        Err(StreamViolation::KeyStreamUnkeyed(1))
    );
    let mut m = Mux::new(Side::Owner);
    m.allow_keys();
    ok(&mut m, In::Frame(ready()));
    assert_eq!(
        ok(&mut m, In::Frame(Frame::open_key(1))),
        vec![Out::NewKeyStream { stream: 1 }]
    );
    assert_eq!(
        ok(&mut m, In::Frame(open(3))),
        vec![Out::NewStream { stream: 3 }]
    );
    let mut s = Mux::new(Side::Sidecar);
    assert_eq!(
        s.step(In::LocalOpenKey),
        Err(StreamViolation::KeyStreamUnkeyed(1))
    );
    let mut s = Mux::new(Side::Sidecar);
    s.allow_keys();
    assert_eq!(
        ok(&mut s, In::LocalOpenKey),
        vec![Out::Send(Frame::open_key(1))]
    );
    assert_eq!(ok(&mut s, In::LocalOpen), vec![Out::Send(open(3))]);
}
