//! What waits for the writer, and the order it leaves in (the channel's writer rules; pure).
//!
//! - **What waits.** Per stream: its `DATA` frames (only what its credit allowed, so at most `WINDOW`), one coalesced
//!   `CREDIT` and a `FIN` flag. Per channel: `READY` (once), one `BEAT`, a few `EVENT`s, and `order`, a FIFO of
//!   `OPEN`, `FIN` and `RST` frames.
//! - **Order.** `READY` leaves first. `OPEN`, `FIN` and `RST` leave in `order`'s FIFO order, so `OPEN`s (pushed in id
//!   order) leave in id order and a stream's `OPEN` before anything else of it. A stream's `FIN` joins `order` only
//!   once its last `DATA` is written; until then it is the stream's flag. An `RST` joins at once and drops the
//!   stream's waiting `DATA`, its `CREDIT` and a `FIN` not yet written; an `OPEN` of the stream still in `order` stays
//!   ahead of it, so an instant reset leaves as `OPEN`, then `RST`. A stream's `DATA` leaves only after its `OPEN`.
//!   `CREDIT`, `BEAT` and `EVENT` may overtake anything.
//! - **A pass.** `READY` if it waits; then the control that waited when the pass began (`order`, `CREDIT`s, `BEAT`,
//!   `EVENT`s); then one `DATA` frame for each stream with `DATA` waiting, in id order. What becomes ready during a
//!   pass waits for the next, so a peer causing many `CREDIT`s can't starve the `DATA` round.
//!
//! The writer writes each frame [`Pending::next`] returns in full before asking again, so the order `next` returns
//! is the order on the pipe.

use std::collections::{BTreeMap, BTreeSet, HashSet, VecDeque};

use crate::frame::{Frame, Kind};
use crate::mux::Side;

/// `EVENT`s waiting at most; more are dropped (the owner counts foreign sources anyway).
pub const MAX_EVENTS_WAITING: usize = 16;

#[derive(Clone, Debug)]
enum Phase {
    Idle,
    /// Writing the control frames pushed before `mark`.
    Control {
        mark: u64,
    },
    /// One `DATA` frame for each of these streams.
    Data {
        round: VecDeque<u32>,
    },
}

/// The writer's queue.
#[derive(Clone, Debug)]
pub struct Pending {
    side: Side,
    seq: u64,
    ready: Option<Frame>,
    order: VecDeque<(u64, Frame)>,
    /// Per stream: the seq of its first uncoalesced push, and the sum.
    credits: BTreeMap<u32, (u64, u32)>,
    beat: Option<u64>,
    events: VecDeque<(u64, Frame)>,
    data: BTreeMap<u32, VecDeque<Frame>>,
    fin_after_data: BTreeSet<u32>,
    /// The sidecar's `OPEN`s still in `order`: their streams' `DATA` waits.
    unwritten_open: HashSet<u32>,
    phase: Phase,
}

impl Pending {
    pub fn new(side: Side) -> Self {
        Pending {
            side,
            seq: 0,
            ready: None,
            order: VecDeque::new(),
            credits: BTreeMap::new(),
            beat: None,
            events: VecDeque::new(),
            data: BTreeMap::new(),
            fin_after_data: BTreeSet::new(),
            unwritten_open: HashSet::new(),
            phase: Phase::Idle,
        }
    }

    fn tick(&mut self) -> u64 {
        self.seq += 1;
        self.seq
    }

    /// Queues a frame the `Mux` (or the shell) decided to send.
    pub fn push(&mut self, f: Frame) {
        let s = f.stream;
        match f.kind {
            Kind::Ready => self.ready = Some(f),
            Kind::Beat => {
                if self.beat.is_none() {
                    self.beat = Some(self.tick());
                }
            }
            Kind::Event => {
                if self.events.len() < MAX_EVENTS_WAITING {
                    let seq = self.tick();
                    self.events.push_back((seq, f));
                }
            }
            Kind::Open => {
                if self.side == Side::Sidecar {
                    self.unwritten_open.insert(s);
                }
                let seq = self.tick();
                self.order.push_back((seq, f));
            }
            Kind::Data => self.data.entry(s).or_default().push_back(f),
            Kind::Credit => {
                let n = f.credit_value().unwrap_or(0);
                if n == 0 {
                    return;
                }
                let seq = self.tick();
                let e = self.credits.entry(s).or_insert((seq, 0));
                e.1 = e.1.saturating_add(n);
            }
            Kind::Fin => {
                if self.data.contains_key(&s) {
                    self.fin_after_data.insert(s);
                } else {
                    let seq = self.tick();
                    self.order.push_back((seq, f));
                }
            }
            Kind::Rst => {
                self.data.remove(&s);
                self.credits.remove(&s);
                self.fin_after_data.remove(&s);
                self.order
                    .retain(|(_, o)| !(o.stream == s && o.kind == Kind::Fin));
                let seq = self.tick();
                self.order.push_back((seq, f));
            }
        }
    }

    /// Whether nothing waits.
    pub fn is_empty(&self) -> bool {
        self.ready.is_none()
            && self.order.is_empty()
            && self.credits.is_empty()
            && self.beat.is_none()
            && self.events.is_empty()
            && self.data.is_empty()
    }

    /// The next frame to write, or `None` when nothing waits.
    #[allow(
        clippy::should_implement_trait,
        reason = "a queue the writer drains: `None` now, `Some` after the next push; not an iterator"
    )]
    pub fn next(&mut self) -> Option<Frame> {
        if let Some(r) = self.ready.take() {
            return Some(r);
        }
        // a pass that finds nothing ends; two in a row mean nothing can leave
        let mut idle_passes = 0;
        loop {
            match &mut self.phase {
                Phase::Idle => {
                    if self.is_empty() || idle_passes > 1 {
                        return None;
                    }
                    idle_passes += 1;
                    self.phase = Phase::Control { mark: self.seq + 1 };
                }
                Phase::Control { mark } => {
                    let mark = *mark;
                    if let Some(f) = self.control_before(mark) {
                        return Some(f);
                    }
                    let round = self
                        .data
                        .keys()
                        .copied()
                        .filter(|s| !self.unwritten_open.contains(s))
                        .collect();
                    self.phase = Phase::Data { round };
                }
                Phase::Data { round } => {
                    let Some(s) = round.pop_front() else {
                        self.phase = Phase::Idle;
                        continue;
                    };
                    if let Some(f) = self.data_of(s) {
                        return Some(f);
                    }
                }
            }
        }
    }

    /// The next control frame pushed before `mark`: `order` first, then `CREDIT`s, the `BEAT`, `EVENT`s.
    fn control_before(&mut self, mark: u64) -> Option<Frame> {
        if self.order.front().is_some_and(|(seq, _)| *seq < mark) {
            let (_, f) = self.order.pop_front()?;
            if f.kind == Kind::Open {
                self.unwritten_open.remove(&f.stream);
            }
            return Some(f);
        }
        let credit = self
            .credits
            .iter()
            .find(|(_, (seq, _))| *seq < mark)
            .map(|(s, _)| *s);
        if let Some(s) = credit {
            let (_, n) = self.credits.remove(&s)?;
            return Some(Frame::credit(s, n));
        }
        if self.beat.is_some_and(|seq| seq < mark) {
            self.beat = None;
            return Some(Frame::empty(0, Kind::Beat));
        }
        if self.events.front().is_some_and(|(seq, _)| *seq < mark) {
            return self.events.pop_front().map(|(_, f)| f);
        }
        None
    }

    /// One `DATA` frame of stream `s`; its last one lets a held `FIN` into `order`.
    fn data_of(&mut self, s: u32) -> Option<Frame> {
        let q = self.data.get_mut(&s)?;
        let f = q.pop_front()?;
        if q.is_empty() {
            self.data.remove(&s);
            if self.fin_after_data.remove(&s) {
                let seq = self.tick();
                self.order.push_back((seq, Frame::empty(s, Kind::Fin)));
            }
        }
        Some(f)
    }
}

#[cfg(test)]
mod tests;
