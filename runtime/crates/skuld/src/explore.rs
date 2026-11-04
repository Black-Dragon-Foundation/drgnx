//! Running a core in every order within the bound, or in one uniformly drawn order per seed.

use std::collections::{BTreeSet, HashMap};
use std::fmt;
use std::ops::Range;

use proptest::prelude::Rng as _;
use proptest::test_runner::{RngAlgorithm, TestRng};

use crate::count::{At, Graph};
use crate::{Core, Events, Partial};

/// How far [`every_order`] explores.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bound {
    /// Every order runs while there are at most this many.
    pub exhaustive_max: u64,
    /// Above `exhaustive_max`, every order within this many delays of the natural one runs.
    pub delays: u32,
    /// Events a step raises may raise events in turn, this deep at most.
    pub reentry_depth: u32,
}

impl Default for Bound {
    fn default() -> Self {
        Self {
            exhaustive_max: 20_000,
            delays: 2,
            reentry_depth: 64,
        }
    }
}

/// Which orders a run covered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Every order of the partial order.
    Exhaustive,
    /// Every order within this many delays of the natural one.
    DelayBounded(u32),
    /// One uniformly drawn order per seed ([`random_orders`]).
    Random,
}

impl fmt::Display for Mode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Mode::Exhaustive => f.write_str("exhaustive"),
            Mode::DelayBounded(k) => write!(f, "delay-bounded, {k} delays"),
            Mode::Random => f.write_str("random"),
        }
    }
}

/// What a passing run covered.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Report {
    /// The orders run.
    pub orders: u64,
    pub mode: Mode,
    /// Every event kind fed to the core, external or re-entrant.
    pub kinds_seen: BTreeSet<&'static str>,
}

/// Runs a fresh core (`make`) in every order consistent with `p` within `bound`, feeding each event and, depth first,
/// the events its step raises, then calls `check` with the core and the external order.
///
/// Panics with `order I of N (MODE): [events…], fed: [incl. re-entrant…]: MESSAGE` on the first failing check, and
/// on a vacuous run: a cycle in the edges, no events, a kind in `KINDS` no order produced, or re-entry deeper than
/// `bound.reentry_depth`.
pub fn every_order<C: Core>(
    p: &Partial<C::Event>,
    bound: Bound,
    mut make: impl FnMut() -> C,
    mut check: impl FnMut(&C, &[C::Event]) -> Result<(), String>,
) -> Report {
    let g = graph(p);
    let all = g.count(None, bound.exhaustive_max.saturating_add(1));
    let (mode, budget) = if all <= bound.exhaustive_max {
        (Mode::Exhaustive, None)
    } else {
        (Mode::DelayBounded(bound.delays), Some(bound.delays))
    };
    let of = if budget.is_none() {
        all
    } else {
        g.count(budget, u64::MAX)
    };
    let mut run = Runner {
        p,
        make: &mut make,
        check: &mut check,
        reentry_depth: bound.reentry_depth,
        of,
        mode,
        ran: 0,
        seen: BTreeSet::new(),
    };
    let mut pos = vec![0; g.sources()];
    let mut order = Vec::with_capacity(g.total());
    walk(&g, &mut pos, &mut order, budget, &mut |order| {
        run.run(order, None)
    });
    assert_eq!(
        run.ran, of,
        "skuld: the walk ran {} of the {of} orders it counted",
        run.ran
    );
    run.report()
}

/// Runs a fresh core in one order per seed, each drawn uniformly from every order consistent with `p` by a ChaCha
/// `TestRng` seeded from the number: the same seed gives the same order. Re-entry is bounded at the default depth,
/// and the panics are [`every_order`]'s.
pub fn random_orders<C: Core>(
    p: &Partial<C::Event>,
    seeds: Range<u64>,
    mut make: impl FnMut() -> C,
    mut check: impl FnMut(&C, &[C::Event]) -> Result<(), String>,
) -> Report {
    let g = graph(p);
    if seeds.is_empty() {
        panic!("skuld: no order to run: the seed range {seeds:?} is empty");
    }
    let of = seeds.end - seeds.start;
    let reentry_depth = Bound::default().reentry_depth;
    let mut run = Runner {
        p,
        make: &mut make,
        check: &mut check,
        reentry_depth,
        of,
        mode: Mode::Random,
        ran: 0,
        seen: BTreeSet::new(),
    };
    let mut weights = HashMap::new();
    for seed in seeds {
        let mut bytes = [0u8; 32];
        bytes[..8].copy_from_slice(&seed.to_le_bytes());
        let mut rng = TestRng::from_seed(RngAlgorithm::ChaCha, &bytes);
        let order = draw(&g, &mut weights, &mut rng).unwrap_or_else(|e| panic!("skuld: {e}"));
        run.run(&order, Some(seed));
    }
    run.report()
}

/// The checked graph of a partial order with at least one event.
fn graph<E>(p: &Partial<E>) -> Graph {
    let g = Graph::new(p).unwrap_or_else(|e| panic!("skuld: {e}"));
    if g.total() == 0 {
        panic!("skuld: no order to run: the sources hold no events");
    }
    g
}

/// Depth first over the enabled sources, lowest first; with a budget, choosing the r-th enabled source spends r.
fn walk(
    g: &Graph,
    pos: &mut [usize],
    order: &mut Vec<At>,
    budget: Option<u32>,
    visit: &mut dyn FnMut(&[At]),
) {
    if order.len() == g.total() {
        visit(order);
        return;
    }
    for (rank, s) in g.enabled(pos).into_iter().enumerate() {
        let rest = match budget {
            None => None,
            Some(b) => match u32::try_from(rank).ok().and_then(|r| b.checked_sub(r)) {
                Some(r) => Some(r),
                None => break,
            },
        };
        order.push((s, pos[s]));
        pos[s] += 1;
        walk(g, pos, order, rest, visit);
        pos[s] -= 1;
        order.pop();
    }
}

/// One order, uniform over every order: each enabled source is taken in proportion to the orders that follow it.
fn draw(
    g: &Graph,
    weights: &mut HashMap<Vec<usize>, f64>,
    rng: &mut TestRng,
) -> Result<Vec<At>, String> {
    let mut pos = vec![0; g.sources()];
    let mut order = Vec::with_capacity(g.total());
    while !g.done(&pos) {
        let enabled = g.enabled(&pos);
        let mut ws = Vec::with_capacity(enabled.len());
        for &s in &enabled {
            pos[s] += 1;
            ws.push(g.weight(&mut pos, weights)?);
            pos[s] -= 1;
        }
        // 53 random bits: a uniform float in [0, 1)
        let unit = (rng.next_u64() >> 11) as f64 / (1u64 << 53) as f64;
        let mut x = unit * ws.iter().sum::<f64>();
        let mut pick = *enabled
            .last()
            .expect("an acyclic partial order always has an enabled source");
        for (&s, &w) in enabled.iter().zip(&ws) {
            if x < w {
                pick = s;
                break;
            }
            x -= w;
        }
        order.push((pick, pos[pick]));
        pos[pick] += 1;
    }
    Ok(order)
}

/// A test's check: the core after an order, and the external order.
type Check<'a, C> = dyn FnMut(&C, &[<C as Core>::Event]) -> Result<(), String> + 'a;

struct Runner<'a, C: Core> {
    p: &'a Partial<C::Event>,
    make: &'a mut dyn FnMut() -> C,
    check: &'a mut Check<'a, C>,
    reentry_depth: u32,
    of: u64,
    mode: Mode,
    ran: u64,
    seen: BTreeSet<&'static str>,
}

impl<C: Core> Runner<'_, C> {
    fn run(&mut self, order: &[At], seed: Option<u64>) {
        self.ran += 1;
        let events: Vec<C::Event> = order
            .iter()
            .map(|&(s, i)| self.p.sources[s].events[i].clone())
            .collect();
        let mut core = (self.make)();
        let mut fed = Vec::new();
        for ev in &events {
            let mut stack = vec![(ev.clone(), 0u32)];
            while let Some((ev, depth)) = stack.pop() {
                if depth > self.reentry_depth {
                    self.fail(
                        &events,
                        &fed,
                        seed,
                        &format!("re-entry deeper than {}", self.reentry_depth),
                    );
                }
                self.seen.insert(ev.kind());
                fed.push(ev.clone());
                let raised = core.step(ev);
                stack.extend(raised.into_iter().rev().map(|e| (e, depth + 1)));
            }
        }
        if let Err(message) = (self.check)(&core, &events) {
            self.fail(&events, &fed, seed, &message);
        }
    }

    fn fail(&self, events: &[C::Event], fed: &[C::Event], seed: Option<u64>, message: &str) -> ! {
        let mode = match seed {
            Some(seed) => format!("{}, seed {seed}", self.mode),
            None => self.mode.to_string(),
        };
        panic!(
            "skuld: order {} of {} ({mode}): {events:?}, fed: {fed:?}: {message}",
            self.ran, self.of
        )
    }

    fn report(self) -> Report {
        let unseen: Vec<&str> = <C::Event as Events>::KINDS
            .iter()
            .copied()
            .filter(|k| !self.seen.contains(k))
            .collect();
        if !unseen.is_empty() {
            panic!(
                "skuld: no order produced the declared event kind(s) {} ({} orders, {}): a source or a step must \
                 make each one",
                unseen.join(", "),
                self.ran,
                self.mode
            );
        }
        Report {
            orders: self.ran,
            mode: self.mode,
            kinds_seen: self.seen,
        }
    }
}
