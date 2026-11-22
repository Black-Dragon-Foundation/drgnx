//! Every answer here is known exactly: closed forms (binomials, multinomials) or a brute force over every interleaving
//! that shares no code with the helper.
use std::collections::BTreeSet;
use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::{Bound, Core, Events, Mode, Partial, count, every_order, random_orders, wait_until};

/// An edge: (source, index) before (source, index).
type Edge = ((usize, usize), (usize, usize));

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Two {
    A(u8),
    B(u8),
}
crate::events!(Two { A, B });

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Three {
    A(u8),
    B(u8),
    C(u8),
}
crate::events!(Three { A, B, C });

/// A core that only records what it was fed.
struct Rec<E>(Vec<E>);

impl<E: Events> Core for Rec<E> {
    type Event = E;
    fn step(&mut self, ev: E) -> Vec<E> {
        self.0.push(ev);
        Vec::new()
    }
}

fn rec<E>() -> Rec<E> {
    Rec(Vec::new())
}

/// Two chains: `a` events `A(0..a)` and `b` events `B(0..b)`.
fn two(a: u8, b: u8) -> Partial<Two> {
    let mut p = Partial::new();
    p.source("a", (0..a).map(Two::A).collect());
    p.source("b", (0..b).map(Two::B).collect());
    p
}

fn three(n: u8) -> Partial<Three> {
    let mut p = Partial::new();
    p.source("a", (0..n).map(Three::A).collect());
    p.source("b", (0..n).map(Three::B).collect());
    p.source("c", (0..n).map(Three::C).collect());
    p
}

fn binomial(n: u64, k: u64) -> u64 {
    (0..k).fold(1, |acc, i| acc * (n - i) / (i + 1))
}

fn panic_text(f: impl FnOnce()) -> String {
    let err = catch_unwind(AssertUnwindSafe(f)).expect_err("expected a panic");
    match err.downcast::<String>() {
        Ok(s) => *s,
        Err(err) => err
            .downcast::<&str>()
            .map(|s| s.to_string())
            .unwrap_or_default(),
    }
}

/// Every interleaving of two chains of `a` and `b` events, by brute force over bit masks (bit set: B's next event).
fn all_two(a: u8, b: u8) -> Vec<Vec<Two>> {
    let n = u32::from(a) + u32::from(b);
    (0u32..1 << n)
        .filter(|m| m.count_ones() == u32::from(b))
        .map(|m| {
            let (mut i, mut j) = (0, 0);
            (0..n)
                .map(|bit| {
                    if (m >> bit) & 1 == 1 {
                        j += 1;
                        Two::B(j - 1)
                    } else {
                        i += 1;
                        Two::A(i - 1)
                    }
                })
                .collect()
        })
        .collect()
}

fn position(order: &[Two], ev: &Two) -> usize {
    order.iter().position(|e| e == ev).expect("event in order")
}

/// Every order the helper runs, and its report.
fn run_all<E: Events + Ord>(p: &Partial<E>, bound: Bound) -> (Vec<Vec<E>>, crate::Report) {
    let mut seen = Vec::new();
    let r = every_order(p, bound, rec::<E>, |core, order| {
        if core.0 != order {
            return Err(format!("fed {:?}", core.0));
        }
        seen.push(order.to_vec());
        Ok(())
    });
    (seen, r)
}

#[test]
fn count_matches_the_closed_form() {
    assert_eq!(count(&two(8, 8), u64::MAX), Ok(12_870));
    assert_eq!(count(&three(3), u64::MAX), Ok(1_680));
    let mut p = two(8, 8);
    p.before((0, 7), (1, 0));
    assert_eq!(count(&p, u64::MAX), Ok(1));
    for a in 0..=7 {
        for b in 0..=7 {
            let want = binomial(u64::from(a) + u64::from(b), u64::from(a));
            assert_eq!(count(&two(a, b), u64::MAX), Ok(want), "{a} and {b}");
        }
    }
    // 4!·4!·4!·4! into 16!: 63,063,000
    let mut four = Partial::new();
    for s in 0..4u8 {
        four.source("s", (0..4).map(|i| Three::A(s * 4 + i)).collect());
    }
    assert_eq!(count(&four, u64::MAX), Ok(63_063_000));
    // The cap: exact below it, the cap itself above it.
    assert_eq!(count(&two(8, 8), 20_001), Ok(12_870));
    assert_eq!(count(&two(9, 9), u64::MAX), Ok(48_620));
    assert_eq!(count(&two(9, 9), 20_001), Ok(20_001));
    assert_eq!(count(&four, 20_001), Ok(20_001));
    // An edge's count against the brute force: A1 before B2 in 2×4.
    let mut e = two(4, 4);
    e.before((0, 1), (1, 2));
    let want = all_two(4, 4)
        .iter()
        .filter(|o| position(o, &Two::A(1)) < position(o, &Two::B(2)))
        .count() as u64;
    assert_eq!(count(&e, u64::MAX), Ok(want));
}

#[test]
fn exhaustive_visits_each_order_once() {
    let (seen, r) = run_all(&two(4, 4), Bound::default());
    assert_eq!(r.mode, Mode::Exhaustive);
    assert_eq!(r.orders, 70);
    assert_eq!(seen.len(), 70);
    let distinct: BTreeSet<_> = seen.iter().cloned().collect();
    assert_eq!(distinct, all_two(4, 4).into_iter().collect::<BTreeSet<_>>());
    assert_eq!(seen[0], two_natural(4, 4), "the natural order comes first");

    // With an edge: exactly the interleavings that keep it.
    let mut p = two(4, 4);
    p.before((0, 1), (1, 2)).before((1, 0), (0, 3));
    let (seen, r) = run_all(&p, Bound::default());
    let want: BTreeSet<_> = all_two(4, 4)
        .into_iter()
        .filter(|o| {
            position(o, &Two::A(1)) < position(o, &Two::B(2))
                && position(o, &Two::B(0)) < position(o, &Two::A(3))
        })
        .collect();
    assert_eq!(r.orders, want.len() as u64);
    assert_eq!(seen.len(), want.len());
    assert_eq!(seen.into_iter().collect::<BTreeSet<_>>(), want);
}

fn two_natural(a: u8, b: u8) -> Vec<Two> {
    (0..a).map(Two::A).chain((0..b).map(Two::B)).collect()
}

/// The delays an order takes, by the definition: at each step the natural scheduler takes the lowest-numbered source
/// whose next event is enabled; choosing the r-th enabled source (from 0) costs r delays.
fn delays_of(order: &[usize], lens: &[usize], edges: &[Edge]) -> u32 {
    let mut pos = vec![0; lens.len()];
    let mut cost = 0;
    for &s in order {
        let enabled: Vec<usize> = (0..lens.len())
            .filter(|&t| {
                pos[t] < lens[t]
                    && edges
                        .iter()
                        .all(|&(a, b)| b != (t, pos[t]) || pos[a.0] > a.1)
            })
            .collect();
        cost += enabled
            .iter()
            .position(|&t| t == s)
            .expect("an enabled source") as u32;
        pos[s] += 1;
    }
    cost
}

/// Every sequence of source numbers with `lens[s]` copies of `s` (every interleaving, edges ignored).
fn all_sequences(lens: &[usize]) -> Vec<Vec<usize>> {
    fn go(left: &mut [usize], cur: &mut Vec<usize>, out: &mut Vec<Vec<usize>>) {
        if left.iter().all(|&n| n == 0) {
            out.push(cur.clone());
            return;
        }
        for s in 0..left.len() {
            if left[s] > 0 {
                left[s] -= 1;
                cur.push(s);
                go(left, cur, out);
                cur.pop();
                left[s] += 1;
            }
        }
    }
    let mut out = Vec::new();
    go(&mut lens.to_vec(), &mut Vec::new(), &mut out);
    out
}

/// Respects every edge: event a.1 of source a.0 comes before event b.1 of source b.0.
fn keeps(order: &[usize], edges: &[Edge]) -> bool {
    let at = |(s, i): (usize, usize)| {
        order
            .iter()
            .enumerate()
            .filter(|&(_, &t)| t == s)
            .nth(i)
            .map(|(k, _)| k)
            .expect("event in order")
    };
    edges.iter().all(|&(a, b)| at(a) < at(b))
}

fn sources_of_two(order: &[Two]) -> Vec<usize> {
    order
        .iter()
        .map(|e| usize::from(matches!(e, Two::B(_))))
        .collect()
}

fn sources_of_three(order: &[Three]) -> Vec<usize> {
    order
        .iter()
        .map(|e| match e {
            Three::A(_) => 0,
            Three::B(_) => 1,
            Three::C(_) => 2,
        })
        .collect()
}

#[test]
fn above_the_bound_is_delay_bounded() {
    // 2×9: 48,620 orders, so two delays.  For two chains an order's delays are the B events taken while A still
    // has one: 1 + 9 + C(10,2) = 55 orders.
    let all = all_sequences(&[9, 9]);
    assert_eq!(all.len(), 48_620);
    let want: BTreeSet<Vec<usize>> = all
        .into_iter()
        .filter(|o| delays_of(o, &[9, 9], &[]) <= 2)
        .collect();
    assert_eq!(want.len(), 55);
    let (seen, r) = run_all(&two(9, 9), Bound::default());
    assert_eq!(r.mode, Mode::DelayBounded(2));
    assert_eq!(r.orders, 55);
    assert_eq!(
        seen[0],
        two_natural(9, 9),
        "the natural order is source 0 first"
    );
    let got: Vec<Vec<usize>> = seen.iter().map(|o| sources_of_two(o.as_slice())).collect();
    assert_eq!(got.len(), 55, "each order once");
    assert_eq!(got.into_iter().collect::<BTreeSet<_>>(), want);

    // Three chains of 4 (34,650 orders): one step may spend both delays on the third source.
    let all = all_sequences(&[4, 4, 4]);
    assert_eq!(all.len(), 34_650);
    let want: BTreeSet<Vec<usize>> = all
        .into_iter()
        .filter(|o| delays_of(o, &[4, 4, 4], &[]) <= 2)
        .collect();
    let (seen, r) = run_all(&three(4), Bound::default());
    assert_eq!(r.mode, Mode::DelayBounded(2));
    assert_eq!(r.orders, want.len() as u64);
    let got: Vec<Vec<usize>> = seen
        .iter()
        .map(|o| sources_of_three(o.as_slice()))
        .collect();
    assert_eq!(got.len(), want.len(), "each order once");
    assert_eq!(got.into_iter().collect::<BTreeSet<_>>(), want);

    // With edges a delay counts against the enabled sources only, and a lower bound is honoured.
    let edges = [((1, 0), (0, 2)), ((0, 4), (1, 3))];
    let mut p = two(6, 6);
    for &(a, b) in &edges {
        p.before(a, b);
    }
    let bound = Bound {
        exhaustive_max: 10,
        delays: 1,
        ..Bound::default()
    };
    let want: BTreeSet<Vec<usize>> = all_sequences(&[6, 6])
        .into_iter()
        .filter(|o| keeps(o, &edges) && delays_of(o, &[6, 6], &edges) <= 1)
        .collect();
    let (seen, r) = run_all(&p, bound);
    assert_eq!(r.mode, Mode::DelayBounded(1));
    assert_eq!(r.orders, want.len() as u64);
    let got: Vec<Vec<usize>> = seen.iter().map(|o| sources_of_two(o.as_slice())).collect();
    assert_eq!(got.len(), want.len(), "each order once");
    assert_eq!(got.into_iter().collect::<BTreeSet<_>>(), want);
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Life {
    Close,
    Closed,
    Next,
}
crate::events!(Life {
    Close,
    Closed,
    Next
});

struct Raises(Vec<Life>);

impl Core for Raises {
    type Event = Life;
    fn step(&mut self, ev: Life) -> Vec<Life> {
        let out = if ev == Life::Close {
            vec![Life::Closed]
        } else {
            Vec::new()
        };
        self.0.push(ev);
        out
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Tree {
    Root,
    Left,
    LeftChild,
    Right,
    Next,
}
crate::events!(Tree {
    Root,
    Left,
    LeftChild,
    Right,
    Next
});

struct Nested(Vec<Tree>);

impl Core for Nested {
    type Event = Tree;
    fn step(&mut self, ev: Tree) -> Vec<Tree> {
        let out = match ev {
            Tree::Root => vec![Tree::Left, Tree::Right],
            Tree::Left => vec![Tree::LeftChild],
            _ => Vec::new(),
        };
        self.0.push(ev);
        out
    }
}

#[test]
fn reentrant_events_run_before_the_next_external() {
    let mut p = Partial::new();
    p.source("client", vec![Life::Close, Life::Next]);
    let r = every_order(
        &p,
        Bound::default(),
        || Raises(Vec::new()),
        |core, order| {
            assert_eq!(
                order,
                [Life::Close, Life::Next],
                "the check gets the external order"
            );
            if core.0 == [Life::Close, Life::Closed, Life::Next] {
                Ok(())
            } else {
                Err(format!("saw {:?}", core.0))
            }
        },
    );
    assert_eq!(r.orders, 1);
    assert_eq!(
        r.kinds_seen,
        ["Close", "Closed", "Next"]
            .into_iter()
            .collect::<BTreeSet<_>>()
    );

    // Depth first: a raised event's own events run before its next sibling.
    let mut p = Partial::new();
    p.source("a", vec![Tree::Root]);
    p.source("b", vec![Tree::Next]);
    let mut fed = Vec::new();
    let r = every_order(
        &p,
        Bound::default(),
        || Nested(Vec::new()),
        |core, order| {
            fed.push((order.to_vec(), core.0.clone()));
            Ok(())
        },
    );
    assert_eq!(r.orders, 2);
    use Tree::*;
    assert_eq!(
        fed,
        [
            (vec![Root, Next], vec![Root, Left, LeftChild, Right, Next]),
            (vec![Next, Root], vec![Next, Root, Left, LeftChild, Right]),
        ]
    );
}

#[derive(Clone, Debug)]
enum Conn {
    Data,
    #[expect(dead_code, reason = "the declared kind no source makes")]
    Eof,
}
crate::events!(Conn { Data, Eof });

struct Forever;

impl Core for Forever {
    type Event = Two;
    fn step(&mut self, ev: Two) -> Vec<Two> {
        vec![ev]
    }
}

#[test]
fn vacuous_runs_fail() {
    // Contradictory edges.
    let mut p = two(2, 2);
    p.before((0, 1), (1, 0)).before((1, 0), (0, 1));
    let msg = panic_text(|| {
        every_order(&p, Bound::default(), rec::<Two>, |_, _| Ok(()));
    });
    assert!(msg.contains("the edges form a cycle"), "{msg}");
    assert!(
        count(&p, u64::MAX)
            .expect_err("a cycle")
            .contains("the edges form a cycle")
    );
    // An edge against its own source's order is a cycle too.
    let mut p = two(3, 0);
    p.before((0, 2), (0, 0));
    assert!(
        count(&p, u64::MAX)
            .expect_err("a cycle")
            .contains("the edges form a cycle")
    );

    // No events at all, or no seeds.
    let msg = panic_text(|| {
        every_order(
            &Partial::<Two>::new(),
            Bound::default(),
            rec::<Two>,
            |_, _| Ok(()),
        );
    });
    assert!(msg.contains("no order to run"), "{msg}");
    let msg = panic_text(|| {
        every_order(&two(0, 0), Bound::default(), rec::<Two>, |_, _| Ok(()));
    });
    assert!(msg.contains("no order to run"), "{msg}");
    let msg = panic_text(|| {
        random_orders(&two(2, 2), 5..5, rec::<Two>, |_, _| Ok(()));
    });
    assert!(msg.contains("no order to run"), "{msg}");

    // A declared kind no order produced, exhaustive or random.
    let mut p = Partial::new();
    p.source("socket", vec![Conn::Data, Conn::Data]);
    let msg = panic_text(|| {
        every_order(&p, Bound::default(), rec::<Conn>, |_, _| Ok(()));
    });
    assert!(msg.contains("Eof") && !msg.contains("Data"), "{msg}");
    let msg = panic_text(|| {
        random_orders(&p, 0..3, rec::<Conn>, |_, _| Ok(()));
    });
    assert!(msg.contains("Eof"), "{msg}");

    // Re-entry that never ends.
    let msg = panic_text(|| {
        every_order(&two(1, 1), Bound::default(), || Forever, |_, _| Ok(()));
    });
    assert!(msg.contains("re-entry deeper than 64"), "{msg}");

    // An edge that names a missing event.
    let msg = panic_text(|| {
        two(2, 2).before((0, 2), (1, 0));
    });
    assert!(msg.contains("source 0 (a) has 2 events"), "{msg}");
}

/// A hand-written `Events` whose `kind` names a variant `KINDS` does not declare.
#[derive(Clone, Debug)]
enum Lax {
    Declared,
    Stray,
}

impl Events for Lax {
    const KINDS: &'static [&'static str] = &["Declared"];
    fn kind(&self) -> &'static str {
        match self {
            Lax::Declared => "Declared",
            Lax::Stray => "Stray",
        }
    }
}

#[test]
fn a_fed_kind_must_be_declared() {
    let mut p = Partial::new();
    p.source("a", vec![Lax::Declared, Lax::Stray]);
    let msg = panic_text(|| {
        every_order(&p, Bound::default(), rec::<Lax>, |_, _| Ok(()));
    });
    assert!(msg.contains("\"Stray\" is not declared"), "{msg}");
    let msg = panic_text(|| {
        random_orders(&p, 0..3, rec::<Lax>, |_, _| Ok(()));
    });
    assert!(msg.contains("\"Stray\" is not declared"), "{msg}");
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Ab {
    A,
    B,
}
crate::events!(Ab { A, B });

#[test]
fn a_found_order_is_printed_whole() {
    let mut p = Partial::new();
    p.source("a", vec![Ab::A]);
    p.source("b", vec![Ab::B]);
    let msg = panic_text(|| {
        every_order(&p, Bound::default(), rec::<Ab>, |_, order| {
            if order == [Ab::B, Ab::A] {
                Err("B overtook A".to_string())
            } else {
                Ok(())
            }
        });
    });
    assert!(
        msg.contains("order 2 of 2 (exhaustive): [B, A], fed: [B, A]: B overtook A"),
        "{msg}"
    );

    let msg = panic_text(|| {
        random_orders(&p, 0..64, rec::<Ab>, |_, order| {
            if order == [Ab::B, Ab::A] {
                Err("B overtook A".to_string())
            } else {
                Ok(())
            }
        });
    });
    assert!(
        msg.contains("(random, seed ") && msg.contains("[B, A], fed: [B, A]: B overtook A"),
        "{msg}"
    );
}

fn draw(p: &Partial<Two>, seeds: std::ops::Range<u64>) -> (Vec<Vec<Two>>, crate::Report) {
    let mut seen = Vec::new();
    let r = random_orders(p, seeds, rec::<Two>, |core, order| {
        if core.0 != order {
            return Err(format!("fed {:?}", core.0));
        }
        seen.push(order.to_vec());
        Ok(())
    });
    (seen, r)
}

#[test]
fn random_orders_repeat_per_seed() {
    let mut p = two(8, 8);
    p.before((1, 2), (0, 5));
    let (first, r) = draw(&p, 1..20);
    let (second, _) = draw(&p, 1..20);
    assert_eq!(r.orders, 19);
    assert_eq!(r.mode, Mode::Random);
    assert_eq!(first.len(), 19);
    assert_eq!(first, second);
    assert!(
        first.iter().collect::<BTreeSet<_>>().len() > 1,
        "seeds differ"
    );
    for o in &first {
        assert!(keeps(&sources_of_two(o), &[((1, 2), (0, 5))]), "{o:?}");
        let a: Vec<_> = o.iter().filter(|e| matches!(e, Two::A(_))).collect();
        assert!(a.windows(2).all(|w| w[0] < w[1]), "{o:?}");
    }
}

#[test]
fn random_orders_are_uniform() {
    // A0 A1 A2 and B0: four orders, B at each place.  Choosing a source at random would put B first half the time;
    // a uniform draw puts it at each place a quarter of the time.  4,000 seeds: 1,000 ± 150 each.
    let (seen, _) = draw(&two(3, 1), 0..4_000);
    let mut at = [0; 4];
    for o in &seen {
        at[position(o, &Two::B(0))] += 1;
    }
    assert!(at.iter().all(|&n| (850..=1_150).contains(&n)), "{at:?}");
}

#[test]
fn wait_until_returns_the_first_value() {
    let mut calls = 0;
    let v = wait_until("the third call", 5, || {
        calls += 1;
        (calls == 3).then_some(calls)
    });
    assert_eq!(v, 3);
}

#[test]
fn wait_until_names_what_it_waited_for() {
    let msg = panic_text(|| {
        wait_until::<()>("the socket", 0, || None);
    });
    assert!(msg.contains("the socket"), "{msg}");
}
