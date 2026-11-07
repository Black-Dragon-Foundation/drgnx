//! skuld: every order of a pure core, for tests.
//!
//! Code whose correctness depends on the order of its inputs is split into a pure core (`step(state, event) ->
//! effects`: no I/O, clock or threads) and a thin shell that does the I/O. A test declares the core's inputs as a
//! partial order ([`Partial`]: sources, each in its own order, plus happens-before edges across them) and
//! [`every_order`] runs the core in each order consistent with it:
//!
//! - **exhaustively** while there are at most [`Bound::exhaustive_max`] orders (20,000; two sources of 8 events give
//!   C(16,8) = 12,870);
//! - above that, every order within [`Bound::delays`] delays (2) of the natural one. The natural scheduler always
//!   takes the lowest-numbered source whose next event is enabled; a delay skips the source it would take, once
//!   (Emmi, Qadeer and Rakamarić's delay-bounded scheduling).
//!
//! [`random_orders`] draws one order per seed, uniformly over every order, for long runs on top of the bound.
//!
//! A run never passes vacuously: a cycle in the edges, no events, a declared event kind that no order produced and
//! re-entry deeper than [`Bound::reentry_depth`] each panic, naming the cause. The certainty a pass gives is "within
//! the declared events and this bound".
//!
//! [`wait_until`] (and [`wait_until_async`]) is the one real-time wait Rust tests may use: its deadline only bounds a
//! failure. [`window`] is a window in which nothing may happen; [`origin`] and [`host_now`] give a clock reading as a
//! value, never to wait with. `tests/real_time_in_tests.rs` keeps every other real-time call out of test code.
//!
//! [`while_running`] waits beside a spawned call: a panic only ends its task, so a test that waits for what the task
//! would have done fails when the task ends first instead of waiting forever.
//!
//! The crate is test support: other crates name it under `[dev-dependencies]` only.

mod count;
mod explore;
mod task;
mod wait;

#[cfg(test)]
mod tests;

pub use count::count;
pub use explore::{Bound, Mode, Report, every_order, random_orders};
pub use task::while_running;
pub use wait::{host_now, origin, wait_until, wait_until_async, window};

/// A core's event type: every kind it declares must be produced by some order, or the run fails.
///
/// Implement it for an enum with [`events!`].
pub trait Events: Clone + std::fmt::Debug {
    /// The declared kinds: one per variant.
    const KINDS: &'static [&'static str];
    /// This event's kind, one of [`Events::KINDS`].
    fn kind(&self) -> &'static str;
}

/// Implements [`Events`] for an enum: `events!(Ev { Open, Data, Eof });`. Every variant must be listed (the `match`
/// it writes is exhaustive), and each may be a unit, tuple or struct variant.
#[macro_export]
macro_rules! events {
    ($t:ty { $($v:ident),+ $(,)? }) => {
        impl $crate::Events for $t {
            const KINDS: &'static [&'static str] = &[$(stringify!($v)),+];
            fn kind(&self) -> &'static str {
                match self {
                    $(Self::$v { .. } => stringify!($v),)+
                }
            }
        }
    };
}

/// A pure core: it takes one event at a time and returns the events its effects raise.
pub trait Core {
    type Event: Events;
    /// Steps the core. The returned events re-enter: the helper feeds them, depth first, before the next external
    /// event (an effect that runs a handler at once, such as a sentinel run by `delete-process`).
    fn step(&mut self, ev: Self::Event) -> Vec<Self::Event>;
}

pub(crate) struct Source<E> {
    pub(crate) name: &'static str,
    pub(crate) events: Vec<E>,
}

/// The core's inputs as a partial order: sources, each in its own order, and happens-before edges across them. Each
/// edge is a claim the shell must keep; write it next to the test, and test it in the shell's tests.
pub struct Partial<E> {
    pub(crate) sources: Vec<Source<E>>,
    pub(crate) edges: Vec<((usize, usize), (usize, usize))>,
}

impl<E> Default for Partial<E> {
    fn default() -> Self {
        Self {
            sources: Vec::new(),
            edges: Vec::new(),
        }
    }
}

impl<E> Partial<E> {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds a source whose events happen in this order; returns its number (0, 1, …).
    pub fn source(&mut self, name: &'static str, events: Vec<E>) -> usize {
        self.sources.push(Source { name, events });
        self.sources.len() - 1
    }

    /// Event `a.1` of source `a.0` happens before event `b.1` of source `b.0`. Panics when either names a missing
    /// event.
    pub fn before(&mut self, a: (usize, usize), b: (usize, usize)) -> &mut Self {
        for (s, i) in [a, b] {
            let src = self.sources.get(s).unwrap_or_else(|| {
                panic!(
                    "skuld: an edge names source {s}, but there are {} sources",
                    self.sources.len()
                )
            });
            assert!(
                i < src.events.len(),
                "skuld: an edge names event {i} of source {s} ({}), but source {s} ({}) has {} events",
                src.name,
                src.name,
                src.events.len()
            );
        }
        self.edges.push((a, b));
        self
    }
}
