//! The connection core in every order of its sources (skuld), within the declared events.
//!
//! The test's own bookkeeping plays the shell: it keeps the queued lines' lengths, reports a write only for a line at
//! the front of a queue the core still writes (a `Written` follows its `Push`), and a refused write only while a line
//! is being written.

use super::{ConnCore, ConnEffect, ConnEvent};
use crate::conn::MAX_QUEUED;
use skuld::{Bound, Core, Partial, every_order, random_orders};
use std::collections::VecDeque;

/// The events of a connection that a client, the hub and the writer raise (`LineRead(i)`: the client's i-th line).
#[derive(Clone, Debug, PartialEq, Eq)]
enum Ev {
    LineRead(u8),
    ClientEof,
    Push(usize),
    Close,
    Written,
    WriteRefused,
}
skuld::events!(Ev {
    LineRead,
    ClientEof,
    Push,
    Close,
    Written,
    WriteRefused
});

/// The core under test, and what the shell saw of it.
#[derive(Default)]
struct Conn {
    core: ConnCore,
    /// The shell's queue: lengths of the lines queued and not written.
    lines: VecDeque<usize>,
    served: Vec<u8>,
    skipped: Vec<u8>,
    logs: u32,
    /// A close or a refused write was fed: nothing more may be written.
    stopped: bool,
    /// The first broken invariant, with the step it broke at.
    broken: Option<String>,
}

impl Conn {
    fn feed(&mut self, ev: ConnEvent) {
        for e in self.core.step(ev) {
            match e {
                ConnEffect::Drop => self.lines.clear(),
                ConnEffect::Log => self.logs += 1,
                ConnEffect::Pop => {
                    self.lines.pop_front();
                }
                ConnEffect::Queue | ConnEffect::Refuse | ConnEffect::Serve | ConnEffect::Skip => {}
            }
        }
    }

    fn note(&mut self, what: String) {
        self.broken.get_or_insert(what);
    }
}

impl Core for Conn {
    type Event = Ev;

    fn step(&mut self, ev: Ev) -> Vec<Ev> {
        match ev {
            Ev::LineRead(i) => {
                let effects = self.core.step(ConnEvent::LineRead);
                if effects == [ConnEffect::Serve] {
                    self.served.push(i);
                } else {
                    self.skipped.push(i);
                }
            }
            Ev::ClientEof => self.feed(ConnEvent::ClientEof),
            Ev::Push(len) => {
                let effects = self.core.step(ConnEvent::Push { len });
                if effects.contains(&ConnEffect::Queue) {
                    self.lines.push_back(len);
                }
                for e in effects {
                    match e {
                        ConnEffect::Drop => self.lines.clear(),
                        ConnEffect::Log => self.logs += 1,
                        _ => {}
                    }
                }
            }
            Ev::Close => {
                self.stopped = true;
                self.feed(ConnEvent::Close);
            }
            // the writer writes only a queued line, and only while the core says it writes
            Ev::Written => {
                if let Some(&len) = self.lines.front()
                    && self.core.writing()
                {
                    if self.stopped {
                        self.note(format!(
                            "a line was written after a close or a refused write: {len} bytes"
                        ));
                    }
                    self.feed(ConnEvent::Written { len });
                }
            }
            Ev::WriteRefused => {
                if !self.lines.is_empty() && self.core.writing() {
                    self.stopped = true;
                    self.feed(ConnEvent::WriteRefused);
                }
            }
        }
        // (3) the core's count is the shell's queue, at every step
        let queued: usize = self.lines.iter().sum();
        if self.core.queued_bytes() != queued {
            let have = self.core.queued_bytes();
            self.note(format!(
                "queued_bytes {have} while the queue holds {queued}"
            ));
        }
        // (2) nothing more is written after a close or a refused write
        if self.stopped && self.core.writing() {
            self.note("the writer goes on after a close or a refused write".into());
        }
        Vec::new()
    }
}

/// Invariants (1), (4) and (5) at the end of ORDER (and the broken ones the steps noted).
fn check(c: &Conn, order: &[Ev]) -> Result<(), String> {
    if let Some(b) = &c.broken {
        return Err(b.clone());
    }
    // (1) a line read before EOF is served unless a close came first; a refused write never stops reading
    let mut closed = false;
    let mut want = Vec::new();
    for ev in order {
        match ev {
            Ev::Close => closed = true,
            Ev::LineRead(i) if !closed => want.push(*i),
            _ => {}
        }
    }
    if c.served != want {
        return Err(format!(
            "served {:?}, skipped {:?}; the lines read before any close are {want:?}",
            c.served, c.skipped
        ));
    }
    // (4) the writer ends exactly when stopped, or when finishing (EOF is in every order) with an empty queue
    let ended = c.stopped || c.lines.is_empty();
    if c.core.writing() == ended {
        return Err(format!(
            "writing() is {} with stopped {} and {} lines left",
            c.core.writing(),
            c.stopped,
            c.lines.len()
        ));
    }
    // (5) whole only when finished and everything written, never after a close or a refused write
    let whole = !c.stopped && c.lines.is_empty();
    if c.core.whole() != whole {
        return Err(format!(
            "whole() is {} with stopped {} and {} lines left",
            c.core.whole(),
            c.stopped,
            c.lines.len()
        ));
    }
    Ok(())
}

/// The hub `[Push×pushes, Close]`, the writer `[Written×writes, WriteRefused]` (push i before write i) and the client
/// `[LineRead×reads, ClientEof]`.  A push more than the writes leaves a line for the refused write to be writing.  The
/// client is the last source: the natural order (the lowest source first) reads after the hub and the writer.
fn sources(pushes: usize, writes: usize, reads: u8) -> Partial<Ev> {
    let mut p = Partial::new();
    let mut hub: Vec<Ev> = (0..pushes).map(|i| Ev::Push(10 * (i + 1))).collect();
    hub.push(Ev::Close);
    let mut writer = vec![Ev::Written; writes];
    writer.push(Ev::WriteRefused);
    let mut client: Vec<Ev> = (0..reads).map(Ev::LineRead).collect();
    client.push(Ev::ClientEof);
    let hub = p.source("hub", hub);
    let writer = p.source("writer", writer);
    p.source("client", client);
    for i in 0..writes {
        p.before((hub, i), (writer, i));
    }
    p
}

#[test]
fn every_order_serves_what_the_client_sent_unless_closed() {
    // every order: 16 of hub and writer (push i before write i) times C(11, 4) places for the client's four
    let r = every_order(&sources(3, 2, 3), Bound::default(), Conn::default, check);
    assert_eq!(r.mode, skuld::Mode::Exhaustive);
    assert_eq!(r.orders, 5280);
}

/// The hub pushes past the limit while the writer has written at most the first line.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Over {
    Push,
    Written,
    Close,
}
skuld::events!(Over {
    Push,
    Written,
    Close
});

/// A line of a little over half the limit: two queued at once close the connection.
const HALF: usize = MAX_QUEUED / 2 + 1;

#[derive(Default)]
struct OverConn {
    core: ConnCore,
    lines: VecDeque<usize>,
    logs: u32,
}

impl Core for OverConn {
    type Event = Over;

    fn step(&mut self, ev: Over) -> Vec<Over> {
        let effects = match ev {
            Over::Push => self.core.step(ConnEvent::Push { len: HALF }),
            Over::Written if self.core.writing() && !self.lines.is_empty() => {
                self.core.step(ConnEvent::Written { len: HALF })
            }
            Over::Written => Vec::new(),
            Over::Close => self.core.step(ConnEvent::Close),
        };
        for e in effects {
            match e {
                ConnEffect::Queue => self.lines.push_back(HALF),
                ConnEffect::Drop => self.lines.clear(),
                ConnEffect::Pop => {
                    self.lines.pop_front();
                }
                ConnEffect::Log => self.logs += 1,
                _ => {}
            }
        }
        Vec::new()
    }
}

#[test]
fn every_order_over_the_queue_limit_closes_once() {
    let mut p = Partial::new();
    let hub = p.source("hub", vec![Over::Push, Over::Push, Over::Push, Over::Close]);
    let writer = p.source("writer", vec![Over::Written]);
    p.before((hub, 0), (writer, 0));
    let r = every_order(&p, Bound::default(), OverConn::default, |c, _| {
        if c.logs != 1 {
            return Err(format!("{} closes logged", c.logs));
        }
        if c.core.reading() || c.core.writing() || c.core.queued_bytes() != 0 {
            return Err(format!("not closed: {:?}", c.core));
        }
        Ok(())
    });
    assert_eq!(r.orders, 4);
}

#[test]
fn random_orders_seeds_1_to_500() {
    // four sources of six: a second hub source pushes too (another task's events)
    let mut p = sources(5, 5, 5);
    p.source("events", (0..6).map(|i| Ev::Push(1000 + i)).collect());
    let r = random_orders(&p, 1..501, Conn::default, check);
    assert_eq!(r.orders, 500);
}
