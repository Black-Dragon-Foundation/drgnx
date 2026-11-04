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

#[test]
fn a_lost_seq_does_not_stall_the_others() {
    let mut o = Order::new();
    o.read(1, Some(1), "one");
    assert_eq!(served(&mut o), [(1, "one")]);
    // seq 2 was written to connection 1, which holds part of a line; seq 3 is read on connection 2
    o.set_partial(1, true);
    o.read(2, Some(3), "three");
    assert!(served(&mut o).is_empty(), "seq 2 may still come");
    // connection 1 reads EOF (or fails): seq 2 is not coming, and seq 3 is served
    o.ended(1);
    assert_eq!(served(&mut o), [(2, "three")]);
    // with no connection holding part of a line, a gap is not waited on at all
    o.read(2, Some(7), "seven");
    assert_eq!(served(&mut o), [(2, "seven")]);
    // a closed connection's lines are not served
    o.read(4, Some(8), "eight");
    o.drop_conn(4);
    assert!(served(&mut o).is_empty());
}

#[test]
fn off_step_writes_release_in_key_order() {
    let run = |first: (&str, &str), second: (&str, &str)| {
        let mut o: Order<()> = Order::new();
        o.hold(50, Some(first.0.into()), 1, first.1.into());
        o.hold(50, Some(second.0.into()), 1, second.1.into());
        o.hold(10, Some("z:late-name".into()), 2, "earlier".into());
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
        o.hold(5, Some("t".into()), 1, l.into());
    }
    let out: Vec<String> = o
        .release()
        .into_iter()
        .map(|(_, l)| l.to_string())
        .collect();
    assert_eq!(out, ["1", "2", "3"]);
}

#[test]
fn an_unnamed_origin_is_counted() {
    let mut o: Order<()> = Order::new();
    o.hold(0, None, 1, "a".into());
    o.hold(0, Some("t".into()), 1, "b".into());
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
