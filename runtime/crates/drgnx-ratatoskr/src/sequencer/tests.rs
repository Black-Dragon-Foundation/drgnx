//! The order the sequencer serves in and releases held writes in (its I/O is `tests/gated.rs`'s).

use super::*;

/// Every line the order gives now, as (connection, line).
fn served(o: &mut Order<&'static str>) -> Vec<(u64, &'static str)> {
    std::iter::from_fn(|| o.next()).collect()
}

#[test]
fn serves_in_seq_order_across_connections() {
    let mut o = Order::new();
    // seq 2 read (on connection 2) before seq 1 (on connection 1); an unsequenced line read first of all
    o.read(3, None, "other");
    o.read(2, Some(2), "two");
    o.read(1, Some(1), "one");
    assert_eq!(served(&mut o), [(1, "one"), (2, "two"), (3, "other")]);
    // the stamp comes off before the line is served, and the id and kind are read
    let l = Line::read(r#"{"id":4,"method":"__test_barrier","__seq":9}"#.into());
    assert_eq!((l.seq, l.id, l.barrier), (Some(9), Some(Id::Num(4)), true));
    assert_eq!(l.text, r#"{"id":4,"method":"__test_barrier"}"#);
    let l = Line::read(r#"{"id":5,"method":"ping","__seq":"x"}"#.into());
    assert_eq!(l.seq, None, "no number: not a stamp");
    assert!(l.text.contains("__seq"));
}

/// One full drain: READS (connection, N, line) in the order the drain reads them.
fn drain(o: &mut Order<&'static str>, reads: &[(u64, Option<u64>, &'static str)]) {
    o.begin_drain();
    for &(conn, seq, line) in reads {
        o.read(conn, seq, line);
    }
    o.end_drain();
}

#[test]
fn a_lost_seq_does_not_stall_the_others() {
    let mut o = Order::new();
    drain(&mut o, &[(1, Some(1), "one")]);
    assert_eq!(served(&mut o), [(1, "one")]);
    // seq 2 was written to connection 1, which holds part of a line; seq 3 is read on connection 2
    o.set_partial(1, true);
    drain(&mut o, &[(2, Some(3), "three")]);
    drain(&mut o, &[]);
    assert!(served(&mut o).is_empty(), "seq 2 may still come");
    // connection 1 reads EOF (or fails): seq 2 is not coming, and seq 3 is served
    o.ended(1);
    assert_eq!(served(&mut o), [(2, "three")]);
    // with no connection holding part of a line, a gap waits for one more drain only
    drain(&mut o, &[(2, Some(7), "seven")]);
    assert!(o.wants_drain());
    drain(&mut o, &[]);
    assert!(!o.wants_drain());
    assert_eq!(served(&mut o), [(2, "seven")]);
    // a closed connection's lines are not served
    drain(&mut o, &[(4, Some(8), "eight")]);
    o.drop_conn(4);
    assert!(served(&mut o).is_empty());
}

#[test]
fn a_gap_waits_for_a_drain_begun_after_the_higher_seq_was_read() {
    // one drain reads connection 1 (empty), then the client writes seq 1 on connection 1 and seq 2 on connection 2,
    // then the drain reads connection 2: seq 2 is read above a gap, and no socket holds part of a line
    let mut o = Order::new();
    drain(&mut o, &[(2, Some(2), "two")]);
    assert!(served(&mut o).is_empty(), "seq 1 may be in connection 1");
    assert!(o.wants_drain(), "the sequencer drains again at once");
    // the next drain begins after seq 2 was read, so seq 1, written before it, is in connection 1's socket
    drain(&mut o, &[(1, Some(1), "one")]);
    assert!(!o.wants_drain());
    assert_eq!(served(&mut o), [(1, "one"), (2, "two")]);
}

#[test]
fn off_step_writes_release_in_key_order() {
    let run = |first: (&str, &str), second: (&str, &str)| {
        let mut o: Order<()> = Order::new();
        o.hold(50, Some((first.0.into(), 1)), 1, first.1.into());
        o.hold(50, Some((second.0.into(), 2)), 1, second.1.into());
        o.hold(10, Some(("z:late-name".into(), 3)), 2, "earlier".into());
        let out: Vec<String> = o
            .release()
            .into_iter()
            .map(|(_, l)| l.to_string())
            .collect();
        assert!(o.release().is_empty(), "released once");
        out
    };
    // two origins at one virtual ms, pushed in either real order: one release order
    let a = run(("session:emit", "e"), ("exec:watch", "w"));
    let b = run(("exec:watch", "w"), ("session:emit", "e"));
    assert_eq!(a, b);
    assert_eq!(a, ["earlier", "w", "e"]);
    // one origin keeps its own order
    let mut o: Order<()> = Order::new();
    for l in ["1", "2", "3"] {
        o.hold(5, Some(("t".into(), 1)), 1, l.into());
    }
    let out: Vec<String> = o
        .release()
        .into_iter()
        .map(|(_, l)| l.to_string())
        .collect();
    assert_eq!(out, ["1", "2", "3"]);
}

#[test]
fn same_named_tasks_release_in_spawn_order() {
    // two jobs' watchers (one origin; spawned 4th and 9th) write at one virtual ms, in two real orders
    let run = |writes: [(u64, &'static str); 3]| {
        let mut o: Order<()> = Order::new();
        for (task, l) in writes {
            o.hold(7, Some(("exec:watch".into(), task)), 1, l.into());
        }
        o.release()
            .into_iter()
            .map(|(_, l)| l.to_string())
            .collect::<Vec<String>>()
    };
    let a = run([(4, "a1"), (9, "b1"), (4, "a2")]);
    let b = run([(9, "b1"), (4, "a1"), (4, "a2")]);
    assert_eq!(a, ["a1", "a2", "b1"]);
    assert_eq!(a, b);
}

#[test]
fn an_unnamed_origin_is_counted() {
    let mut o: Order<()> = Order::new();
    o.hold(0, None, 1, "a".into());
    o.hold(0, Some(("t".into(), 1)), 1, "b".into());
    o.hold(3, None, 1, "c".into());
    assert_eq!(o.take_unnamed(), 2);
    assert_eq!(o.take_unnamed(), 0, "counted since the last time");
    // they are still held and released, the unnamed first at one ms
    let out: Vec<String> = o
        .release()
        .into_iter()
        .map(|(_, l)| l.to_string())
        .collect();
    assert_eq!(out, ["a", "b", "c"]);
}
