//! The writer's order on single scenarios (pure, [D]).

use super::*;
use crate::frame::Frame;

fn drain(p: &mut Pending) -> Vec<Frame> {
    let mut out = Vec::new();
    while let Some(f) = p.next() {
        out.push(f);
    }
    assert!(p.is_empty());
    out
}

fn data(s: u32, tag: u8) -> Frame {
    Frame::data(s, vec![tag])
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

/// [D] A `FIN` pushed while its stream's `DATA` waits leaves after the last of it, even with other streams' control
/// going ahead; a `FIN` with nothing waiting goes into `order` at once.
#[test]
fn pending_holds_a_fin_behind_its_data() {
    let mut p = Pending::new(Side::Owner);
    p.push(data(1, 1));
    p.push(data(1, 2));
    p.push(fin(1));
    p.push(fin(3));
    p.push(rst(5));
    let out = drain(&mut p);
    assert_eq!(
        out,
        vec![fin(3), rst(5), data(1, 1), data(1, 2), fin(1)],
        "FIN 1 waits for both DATA frames"
    );
    // on the sidecar too, behind its OPEN
    let mut p = Pending::new(Side::Sidecar);
    p.push(open(1));
    p.push(data(1, 1));
    p.push(fin(1));
    assert_eq!(drain(&mut p), vec![open(1), data(1, 1), fin(1)]);
}

/// [D] An `RST` drops the stream's waiting `DATA`, its `CREDIT` and its unwritten `FIN` (the flag, or the entry in
/// `order`), but its `OPEN` still in `order` stays ahead of it.
#[test]
fn pending_rst_drops_data_credit_and_fin_but_keeps_open() {
    let mut p = Pending::new(Side::Sidecar);
    p.push(open(1));
    p.push(data(1, 1));
    p.push(Frame::credit(1, 100));
    p.push(fin(1));
    p.push(rst(1));
    assert_eq!(drain(&mut p), vec![open(1), rst(1)]);
    // a FIN already in order (no DATA waited) is dropped too
    let mut p = Pending::new(Side::Sidecar);
    p.push(open(3));
    p.push(fin(3));
    p.push(open(5));
    p.push(rst(3));
    assert_eq!(drain(&mut p), vec![open(3), open(5), rst(3)]);
    // an OPEN already written: only the RST
    let mut p = Pending::new(Side::Sidecar);
    p.push(open(7));
    assert_eq!(p.next(), Some(open(7)));
    p.push(data(7, 1));
    p.push(rst(7));
    assert_eq!(drain(&mut p), vec![rst(7)]);
}

/// [D] Writer fairness: a pass writes the control that waited when it began, then one `DATA` frame per stream with
/// `DATA` waiting; a `CREDIT` pushed during the pass waits for the next one.
#[test]
fn a_pass_sends_one_data_round_after_its_control() {
    let mut p = Pending::new(Side::Owner);
    for tag in 0..3 {
        p.push(data(1, tag));
        p.push(data(3, tag));
    }
    p.push(Frame::credit(5, 10));
    p.push(Frame::empty(0, Kind::Beat));
    assert_eq!(p.next(), Some(Frame::credit(5, 10)));
    // pushed during the pass: after this pass's DATA round
    p.push(Frame::credit(7, 20));
    p.push(rst(9));
    assert_eq!(p.next(), Some(Frame::empty(0, Kind::Beat)));
    assert_eq!(p.next(), Some(data(1, 0)));
    assert_eq!(p.next(), Some(data(3, 0)));
    // the next pass: its control, then one DATA each again
    assert_eq!(p.next(), Some(rst(9)));
    assert_eq!(p.next(), Some(Frame::credit(7, 20)));
    assert_eq!(p.next(), Some(data(1, 1)));
    assert_eq!(p.next(), Some(data(3, 1)));
    assert_eq!(drain(&mut p), vec![data(1, 2), data(3, 2)]);
}

/// [D] `CREDIT` overtakes waiting `DATA`, and two `CREDIT`s for one stream coalesce into one frame.
#[test]
fn credit_may_overtake_data() {
    let mut p = Pending::new(Side::Owner);
    p.push(data(1, 1));
    p.push(Frame::credit(1, 100));
    p.push(Frame::credit(1, 28));
    assert_eq!(drain(&mut p), vec![Frame::credit(1, 128), data(1, 1)]);
}
