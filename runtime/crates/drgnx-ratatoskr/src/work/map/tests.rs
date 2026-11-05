//! The map's coalescing per view, in every order of its inputs (pattern A): live arrivals fade in and never relayout,
//! field deltas go out at most once per 100 ms, a quiet second reflows once unless the selection's chain would move,
//! and the user's own change relayouts at once.

use super::*;
use skuld::{Bound, Partial, every_order};
use std::collections::{BTreeMap, BTreeSet};
use vegvisir::ItemId;

/// The coalescer's input, for one scenario `S` (each declares the kinds its orders produce).
#[derive(Clone, Debug)]
struct Ev<const S: u8>(CoIn);

fn kind_of(c: &CoIn) -> &'static str {
    match c {
        CoIn::Now(_) => "Now",
        CoIn::Delta(_) => "Delta",
        CoIn::User => "User",
        CoIn::Key => "Key",
        CoIn::Held => "Held",
    }
}

/// Starts and the clock.
impl skuld::Events for Ev<1> {
    const KINDS: &'static [&'static str] = &["Now", "Delta"];
    fn kind(&self) -> &'static str {
        kind_of(&self.0)
    }
}

/// Starts, the clock and the user's filter.
impl skuld::Events for Ev<2> {
    const KINDS: &'static [&'static str] = &["Now", "Delta", "User"];
    fn kind(&self) -> &'static str {
        kind_of(&self.0)
    }
}

/// Starts and the clock, with a selection whose chain the reflow would move.
impl skuld::Events for Ev<3> {
    const KINDS: &'static [&'static str] = &["Now", "Delta", "Held"];
    fn kind(&self) -> &'static str {
        kind_of(&self.0)
    }
}

fn agent(n: u32) -> ItemId {
    ItemId(format!("agent:s{n}"))
}

/// Agent N starts: a new item, a structural change.
fn start(n: u32) -> CoIn {
    CoIn::Delta(Delta {
        changed: vec![agent(n)],
        structural: true,
        ..Delta::default()
    })
}

/// A field of agent N changes (its state, its spend).
fn field(n: u32) -> CoIn {
    CoIn::Delta(Delta {
        changed: vec![agent(n)],
        ..Delta::default()
    })
}

/// The shell, as the harness plays it: what the view shows, and what was sent when.
#[derive(Default)]
struct Harness<const S: u8> {
    co: Coalescer,
    now: u64,
    /// Every item a delta named: what a full frame shows.
    all: BTreeSet<ItemId>,
    shown: BTreeSet<ItemId>,
    fades: BTreeMap<ItemId, u32>,
    sends: Vec<u64>,
    quiet: Vec<u64>,
    user: Vec<u64>,
    /// Quiet reflows the shell held (the chain would move).
    held: u32,
    /// The first delta not yet sent, and the last change or key.
    pending_since: Option<u64>,
    last_change: Option<u64>,
    structural: bool,
    broken: Option<String>,
}

impl<const S: u8> Harness<S> {
    fn fail(&mut self, why: String) {
        if self.broken.is_none() {
            self.broken = Some(why);
        }
    }

    fn reflowed(&mut self) {
        self.shown = self.all.clone();
        self.pending_since = None;
        self.structural = false;
    }
}

impl<const S: u8> skuld::Core for Harness<S>
where
    Ev<S>: skuld::Events,
{
    type Event = Ev<S>;
    fn step(&mut self, ev: Ev<S>) -> Vec<Ev<S>> {
        let what = format!("{:?} at {}", ev.0, self.now);
        match &ev.0 {
            CoIn::Now(t) => self.now = *t,
            CoIn::Delta(d) => {
                self.all.extend(d.changed.iter().cloned());
                self.pending_since.get_or_insert(self.now);
                self.last_change = Some(self.now);
                self.structural |= d.structural;
            }
            _ => {}
        }
        let input = ev.0.clone();
        let outs = self.co.step(ev.0);
        let mut again = Vec::new();
        let mut reflowed_by_user = false;
        for o in outs {
            match o {
                CoOut::Wake(at) => {
                    if at < self.now {
                        self.fail(format!("{what}: a wake in the past, at {at}"));
                    }
                }
                CoOut::Send { delta } => {
                    if let Some(&last) = self.sends.last()
                        && self.now < last + 100
                    {
                        self.fail(format!(
                            "{what}: a delta {} ms after the last",
                            self.now - last
                        ));
                    }
                    match self.pending_since {
                        Some(p) if self.now >= p + 100 => {}
                        p => self.fail(format!("{what}: sent early, pending since {p:?}")),
                    }
                    for id in &delta.changed {
                        if self.shown.insert(id.clone()) {
                            *self.fades.entry(id.clone()).or_default() += 1;
                        }
                    }
                    self.sends.push(self.now);
                    self.pending_since = None;
                }
                CoOut::Reflow { user: true } => {
                    if input != CoIn::User {
                        self.fail(format!("{what}: a user reflow without the user"));
                    }
                    reflowed_by_user = true;
                    self.user.push(self.now);
                    self.reflowed();
                }
                CoOut::Reflow { user: false } => {
                    if !matches!(input, CoIn::Now(_)) {
                        self.fail(format!("{what}: a live event relayouts"));
                    }
                    if !self.structural {
                        self.fail(format!("{what}: a reflow with nothing to reflow"));
                    }
                    if self.last_change.is_some_and(|c| self.now < c + 1000) {
                        self.fail(format!("{what}: a reflow before a quiet second"));
                    }
                    if S == 3 {
                        self.held += 1;
                        again.push(Ev(CoIn::Held));
                    } else {
                        self.quiet.push(self.now);
                        self.reflowed();
                    }
                }
            }
        }
        if input == CoIn::User && !reflowed_by_user {
            self.fail(format!(
                "{what}: the user's change did not relayout at once"
            ));
        }
        again
    }
}

/// Five agents start while the clock runs to 2.5 s, and agent 1's fields change twice after it started.
fn partial<const S: u8>(user: bool) -> Partial<Ev<S>> {
    let mut p = Partial::new();
    let starts = p.source("starts", (1..=5).map(|n| Ev(start(n))).collect());
    let clock = p.source(
        "clock",
        [50, 150, 300, 1300, 2500]
            .into_iter()
            .map(|t| Ev(CoIn::Now(t)))
            .collect(),
    );
    let fields = p.source("fields", vec![Ev(field(1)), Ev(field(1))]);
    // agent 1's fields change once it is there; everything happens before the clock's last reading
    p.before((starts, 0), (fields, 0));
    p.before((starts, 4), (clock, 4));
    p.before((fields, 1), (clock, 4));
    if user {
        p.source("user", vec![Ev(CoIn::User)]);
    }
    p
}

fn check_common<const S: u8>(h: &Harness<S>) -> Result<(), String> {
    if let Some(b) = &h.broken {
        return Err(b.clone());
    }
    if h.shown != h.all {
        return Err(format!("not delivered: {:?}", h.all.difference(&h.shown)));
    }
    if let Some((id, n)) = h.fades.iter().find(|(_, n)| **n > 1) {
        return Err(format!("{id} faded in {n} times"));
    }
    Ok(())
}

#[test]
fn coalescing_in_every_order() {
    // five starts: no relayout of their own, five fades; then a quiet second reflows once
    let r = every_order(
        &partial::<1>(false),
        Bound::default(),
        Harness::<1>::default,
        |h, _| {
            check_common(h)?;
            if h.fades.len() != 5 {
                return Err(format!("{} fades, not 5: {:?}", h.fades.len(), h.fades));
            }
            if h.quiet.is_empty() || h.structural {
                return Err(format!("no quiet reflow at the end: {:?}", h.quiet));
            }
            Ok(())
        },
    );
    assert_eq!(r.mode, skuld::Mode::Exhaustive);

    // the user's filter relayouts at once, whatever is pending
    every_order(
        &partial::<2>(true),
        Bound::default(),
        Harness::<2>::default,
        |h, _| {
            check_common(h)?;
            if h.user.len() != 1 {
                return Err(format!("{} user reflows", h.user.len()));
            }
            Ok(())
        },
    );

    // the selection's chain would move: the quiet reflow is asked once and waits for the user; arrivals still fade
    every_order(
        &partial::<3>(false),
        Bound::default(),
        Harness::<3>::default,
        |h, _| {
            if let Some(b) = &h.broken {
                return Err(b.clone());
            }
            if h.held != 1 || !h.quiet.is_empty() {
                return Err(format!("held {}, reflowed {:?}", h.held, h.quiet));
            }
            if h.fades.len() != 5 {
                return Err(format!("{} fades, not 5", h.fades.len()));
            }
            Ok(())
        },
    );
}
