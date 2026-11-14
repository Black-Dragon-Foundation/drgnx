//! Both ends' pure parts joined by two in-order pipes, in every order of their inputs (skuld; pattern [A]).
//!
//! A world is the sidecar's and the owner's `Mux` and `Pending`, the two pipes, and each end's shell reduced to what
//! the channel rules depend on: a local side that writes bytes (read up to the stream's credit, then its EOF), a
//! consumer that drains the stream's queue, a writer that writes one frame per step and reports `FIN`s and `RST`s as
//! written, and a reader that steps one frame. The sources are those steps; after each order the world is settled
//! (everything written, read and drained) and checked.
//!
//! Each `DATA` frame carries its offset in the stream and the stream id in its first 12 bytes (shorter ones a byte
//! pattern), so a frame delivered twice, out of order or to another stream is seen without comparing every byte.

use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt::Debug;
use std::marker::PhantomData;

use skuld::{Bound, Core, Events, Partial, every_order};

use crate::frame::{Frame, Kind, MAX_DATA, MAX_STREAMS, WINDOW};
use crate::mux::{In, Mux, Out, Side, StreamViolation};
use crate::pending::Pending;
use crate::shell;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum At {
    S,
    O,
}

/// One step of the world.
#[derive(Clone, Debug)]
enum Ev {
    /// The sidecar accepts a job connection (or waits for `Room`).
    Accept,
    /// The end's local side writes `n` bytes on the stream.
    Send { at: At, s: u32, n: usize },
    /// The end's local side ends its writing (its reading task sends `FIN` once every byte went out).
    Eof { at: At, s: u32 },
    /// The end's local side resets the stream.
    Reset { at: At, s: u32 },
    /// The end's consumer takes what is queued on the stream.
    Drain { at: At, s: u32 },
    /// The end's writer writes one frame (take, write, and what follows the write, at once).
    Write { at: At },
    /// The end's reader steps one frame.
    Read { at: At },
    /// The writer's steps one by one: it takes the next frame (`shell::take_next`) ...
    Take { at: At },
    /// ... `write(2)` takes its last byte, so the peer may read it ...
    Put { at: At },
    /// ... and the writer steps on (where `Wrote` was stepped before it moved to `shell::take_next`).
    Ack { at: At },
    /// The end's output ends (its process is gone): it writes nothing more, and the peer reads the pipe to its end.
    Close { at: At },
}

impl Ev {
    fn name(&self) -> &'static str {
        match self {
            Ev::Accept => "Accept",
            Ev::Send { .. } => "Send",
            Ev::Eof { .. } => "Eof",
            Ev::Reset { .. } => "Reset",
            Ev::Drain { .. } => "Drain",
            Ev::Write { .. } => "Write",
            Ev::Read { .. } => "Read",
            Ev::Take { .. } => "Take",
            Ev::Put { .. } => "Put",
            Ev::Ack { .. } => "Ack",
            Ev::Close { .. } => "Close",
        }
    }
}

/// The kinds one test declares (skuld fails a run that declares a kind no order fed).
trait Kinds: Clone + Debug {
    const KINDS: &'static [&'static str];
}

#[derive(Clone, Debug)]
struct Step<K>(Ev, PhantomData<K>);

impl<K: Kinds> Events for Step<K> {
    const KINDS: &'static [&'static str] = K::KINDS;
    fn kind(&self) -> &'static str {
        self.0.name()
    }
}

fn steps<K>(evs: Vec<Ev>) -> Vec<Step<K>> {
    evs.into_iter().map(|e| Step(e, PhantomData)).collect()
}

fn n_of(ev: Ev, n: usize) -> Vec<Ev> {
    vec![ev; n]
}

fn chunk(s: u32, off: usize, n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    if n >= 12 {
        v[..8].copy_from_slice(&(off as u64).to_be_bytes());
        v[8..12].copy_from_slice(&s.to_be_bytes());
    } else {
        for (i, b) in v.iter_mut().enumerate() {
            *b = (s as usize * 31 + (off + i) * 7) as u8;
        }
    }
    v
}

/// One end: its pure parts and the reduced shell.
#[derive(Clone, Debug)]
struct End {
    side: Side,
    mux: Mux,
    pending: Pending,
    auto_drain: bool,
    /// Streams whose consumer never drains.
    stuck: BTreeSet<u32>,
    /// The output ended (`Ev::Close`): this end writes nothing more.
    closed: bool,
    /// The channel ended here (the peer's output read to its end), and with it every stream still open: the shell's
    /// end, reduced.
    ended: bool,
    /// The streams the end of the channel took down.
    killed: BTreeSet<u32>,
    known: BTreeSet<u32>,
    to_send: BTreeMap<u32, usize>,
    sent: BTreeMap<u32, usize>,
    asked: BTreeMap<u32, usize>,
    eof_wanted: BTreeSet<u32>,
    eof_sent: BTreeSet<u32>,
    reset_wanted: BTreeSet<u32>,
    queued: BTreeMap<u32, usize>,
    got: BTreeMap<u32, usize>,
    closed_write_at: BTreeMap<u32, usize>,
    dropped: BTreeSet<u32>,
    accept_waiting: usize,
    refused: usize,
    max_counted: usize,
    discarded: Vec<(u32, Kind)>,
    violation: Option<String>,
    /// Frames written, in order: (stream, kind).
    wire: Vec<(u32, Kind)>,
    /// Taken by the writer, not yet on the pipe (one at most: the writer writes one frame at a time).
    in_flight: Option<Frame>,
    /// On the pipe, the writer's step after the write not yet done.
    unacked: VecDeque<Frame>,
}

impl End {
    fn new(side: Side) -> End {
        End {
            side,
            mux: Mux::new(side),
            pending: Pending::new(side),
            auto_drain: true,
            stuck: BTreeSet::new(),
            closed: false,
            ended: false,
            killed: BTreeSet::new(),
            known: BTreeSet::new(),
            to_send: BTreeMap::new(),
            sent: BTreeMap::new(),
            asked: BTreeMap::new(),
            eof_wanted: BTreeSet::new(),
            eof_sent: BTreeSet::new(),
            reset_wanted: BTreeSet::new(),
            queued: BTreeMap::new(),
            got: BTreeMap::new(),
            closed_write_at: BTreeMap::new(),
            dropped: BTreeSet::new(),
            accept_waiting: 0,
            refused: 0,
            max_counted: 0,
            discarded: Vec::new(),
            violation: None,
            wire: Vec::new(),
            in_flight: None,
            unacked: VecDeque::new(),
        }
    }

    fn step(&mut self, ev: In) {
        if self.violation.is_some() {
            return;
        }
        let what = format!("{:?}", short(&ev));
        match self.mux.step(ev) {
            Ok(outs) => self.outs(outs),
            Err(v) => self.violation = Some(format!("{:?} end, {what}: {v:?}", self.side)),
        }
        self.max_counted = self.max_counted.max(self.mux.counted());
    }

    fn outs(&mut self, outs: Vec<Out>) {
        for o in outs {
            match o {
                Out::Send(f) => {
                    if f.kind == Kind::Open {
                        self.known.insert(f.stream);
                    }
                    if f.kind == Kind::Rst && !self.known.contains(&f.stream) {
                        self.refused += 1;
                    }
                    self.pending.push(f);
                }
                Out::NewStream { stream } | Out::NewKeyStream { stream } => {
                    self.known.insert(stream);
                    if self.reset_wanted.remove(&stream) {
                        self.step(In::LocalReset { stream });
                    } else {
                        self.pump(stream);
                    }
                }
                Out::Deliver { stream, bytes } => {
                    let off = self.got.get(&stream).copied().unwrap_or(0);
                    if bytes != chunk(stream, off, bytes.len()) && self.violation.is_none() {
                        self.violation = Some(format!(
                            "{:?} end: stream {stream} delivered {} bytes that aren't the ones at offset {off}",
                            self.side,
                            bytes.len()
                        ));
                    }
                    *self.got.entry(stream).or_default() += bytes.len();
                    *self.queued.entry(stream).or_default() += bytes.len();
                    if self.auto_drain && !self.stuck.contains(&stream) {
                        self.drain(stream);
                    }
                }
                Out::CloseWrite { stream } => {
                    let at = self.got.get(&stream).copied().unwrap_or(0);
                    self.closed_write_at.insert(stream, at);
                }
                Out::Drop { stream } => {
                    self.dropped.insert(stream);
                    self.to_send.remove(&stream);
                    self.queued.remove(&stream);
                }
                Out::CreditFor { stream } => self.pump(stream),
                Out::Discarded { stream, kind } => self.discarded.push((stream, kind)),
                Out::Room => {
                    if self.accept_waiting > 0 {
                        self.accept_waiting -= 1;
                        self.accept();
                    }
                }
                Out::IdsUsedUp | Out::Event(_) | Out::EventsCounted(_) => {}
            }
        }
    }

    /// The stream's reading task: bytes up to the credit, then `FIN` once all went out.
    fn pump(&mut self, s: u32) {
        if !self.known.contains(&s) || self.dropped.contains(&s) {
            return;
        }
        loop {
            let left = self.to_send.get(&s).copied().unwrap_or(0);
            let credit = self.mux.credit(s) as usize;
            if left == 0 || credit == 0 || self.violation.is_some() {
                break;
            }
            let n = left.min(credit).min(MAX_DATA);
            let off = self.sent.get(&s).copied().unwrap_or(0);
            *self.sent.entry(s).or_default() += n;
            *self.to_send.entry(s).or_default() -= n;
            self.step(In::LocalData {
                stream: s,
                bytes: chunk(s, off, n),
            });
        }
        if self.to_send.get(&s).copied().unwrap_or(0) == 0
            && self.eof_wanted.contains(&s)
            && self.eof_sent.insert(s)
        {
            self.step(In::LocalEof { stream: s });
        }
    }

    fn drain(&mut self, s: u32) {
        let n = self.queued.insert(s, 0).unwrap_or(0);
        if n > 0 {
            self.step(In::LocalDrained {
                stream: s,
                n: n as u32,
            });
        }
    }

    fn accept(&mut self) {
        if self.mux.counted() >= MAX_STREAMS {
            self.accept_waiting += 1;
            return;
        }
        self.step(In::LocalOpen);
    }

    fn local(&mut self, ev: &Ev) {
        match *ev {
            Ev::Accept => self.accept(),
            Ev::Send { s, n, .. } => {
                *self.to_send.entry(s).or_default() += n;
                *self.asked.entry(s).or_default() += n;
                self.pump(s);
            }
            Ev::Eof { s, .. } => {
                self.eof_wanted.insert(s);
                self.pump(s);
            }
            Ev::Reset { s, .. } => {
                if self.known.contains(&s) {
                    self.step(In::LocalReset { stream: s });
                } else {
                    self.reset_wanted.insert(s);
                }
            }
            Ev::Drain { s, .. } => self.drain(s),
            Ev::Write { .. }
            | Ev::Read { .. }
            | Ev::Take { .. }
            | Ev::Put { .. }
            | Ev::Ack { .. }
            | Ev::Close { .. } => unreachable!("the world's"),
        }
    }

    fn result(&mut self, r: Result<Vec<Out>, StreamViolation>, what: &str) {
        match r {
            Ok(outs) => self.outs(outs),
            Err(v) => {
                if self.violation.is_none() {
                    self.violation = Some(format!("{:?} end, {what}: {v:?}", self.side));
                }
            }
        }
        self.max_counted = self.max_counted.max(self.mux.counted());
    }

    /// The writer takes the next frame; false when nothing waits (or one is taken already).
    fn take(&mut self) -> bool {
        if self.violation.is_some() || self.in_flight.is_some() || self.closed || self.ended {
            return false;
        }
        match shell::take_next(&mut self.mux, &mut self.pending) {
            Ok(Some((f, outs))) => {
                self.in_flight = Some(f);
                self.result(Ok(outs), "taking a frame");
                true
            }
            Ok(None) => false,
            Err(v) => {
                self.result(Err(v), "taking a frame");
                false
            }
        }
    }

    /// The taken frame reaches `pipe`.
    fn put(&mut self, pipe: &mut VecDeque<Frame>) -> bool {
        if self.closed {
            return false;
        }
        let Some(f) = self.in_flight.take() else {
            return false;
        };
        self.wire.push((f.stream, f.kind));
        self.unacked.push_back(f.clone());
        pipe.push_back(f);
        true
    }

    /// The writer steps on after the oldest unacked write: nothing reaches the `Mux` there (a `FIN` or `RST` counted as
    /// written when it was taken), so this is only the point at which the shell's old order stepped `Wrote`.
    fn ack(&mut self) -> bool {
        self.unacked.pop_front().is_some()
    }

    /// Writes one frame to `pipe`, all three steps at once; false when nothing waits.
    fn write(&mut self, pipe: &mut VecDeque<Frame>) -> bool {
        let mut moved = self.put(pipe);
        while self.ack() {
            moved = true;
        }
        if moved {
            return true;
        }
        if !self.take() {
            return false;
        }
        self.put(pipe);
        self.ack();
        true
    }

    /// Steps one frame from `pipe`; false when none is there. A pipe whose writer closed it, read to its end, ends the
    /// channel here: every stream still open goes down with it.
    fn read(&mut self, pipe: &mut VecDeque<Frame>, writer_closed: bool) -> bool {
        if self.violation.is_some() || self.ended {
            return false;
        }
        let Some(f) = pipe.pop_front() else {
            if writer_closed {
                self.ended = true;
                self.killed = self
                    .known
                    .iter()
                    .filter(|s| !self.dropped.contains(s))
                    .copied()
                    .collect();
                return true;
            }
            return false;
        };
        self.step(In::Frame(f));
        true
    }
}

/// An `In` without its bytes, for messages.
fn short(ev: &In) -> String {
    match ev {
        In::Frame(f) => format!("{:?} {} ({} bytes)", f.kind, f.stream, f.payload.len()),
        In::LocalData { stream, bytes } => format!("LocalData {stream} ({} bytes)", bytes.len()),
        other => format!("{other:?}"),
    }
}

#[derive(Clone, Debug)]
struct World {
    s: End,
    o: End,
    s2o: VecDeque<Frame>,
    o2s: VecDeque<Frame>,
}

impl World {
    /// A fresh channel: the sidecar's `READY` waits for its writer.
    fn new() -> World {
        let mut s = End::new(Side::Sidecar);
        s.pending
            .push(Frame::ready("127.0.0.1:3128".parse().expect("an address")));
        World {
            s,
            o: End::new(Side::Owner),
            s2o: VecDeque::new(),
            o2s: VecDeque::new(),
        }
    }

    /// A channel with `n` streams open at both ends, settled.
    fn with_streams(n: usize) -> World {
        let mut w = World::new();
        for _ in 0..n {
            w.s.accept();
        }
        w.settle();
        w.s.wire.clear();
        w.o.wire.clear();
        w
    }

    fn apply(&mut self, ev: &Ev) {
        match *ev {
            Ev::Write { at: At::S } => {
                self.s.write(&mut self.s2o);
            }
            Ev::Write { at: At::O } => {
                self.o.write(&mut self.o2s);
            }
            Ev::Read { at: At::S } => {
                self.s.read(&mut self.o2s, self.o.closed);
            }
            Ev::Read { at: At::O } => {
                self.o.read(&mut self.s2o, self.s.closed);
            }
            Ev::Close { at: At::S } => self.s.closed = true,
            Ev::Close { at: At::O } => self.o.closed = true,
            Ev::Take { at: At::S } => {
                self.s.take();
            }
            Ev::Take { at: At::O } => {
                self.o.take();
            }
            Ev::Put { at: At::S } => {
                self.s.put(&mut self.s2o);
            }
            Ev::Put { at: At::O } => {
                self.o.put(&mut self.o2s);
            }
            Ev::Ack { at: At::S } => {
                self.s.ack();
            }
            Ev::Ack { at: At::O } => {
                self.o.ack();
            }
            Ev::Accept => self.s.local(ev),
            Ev::Send { at, .. }
            | Ev::Eof { at, .. }
            | Ev::Reset { at, .. }
            | Ev::Drain { at, .. } => match at {
                At::S => self.s.local(ev),
                At::O => self.o.local(ev),
            },
        }
    }

    /// Everything written, read and drained, until nothing moves.
    fn settle(&mut self) {
        loop {
            let mut moved = false;
            while self.s.write(&mut self.s2o) {
                moved = true;
            }
            while self.o.write(&mut self.o2s) {
                moved = true;
            }
            while self.o.read(&mut self.s2o, self.s.closed) {
                moved = true;
            }
            while self.s.read(&mut self.o2s, self.o.closed) {
                moved = true;
            }
            for end in [&mut self.s, &mut self.o] {
                let queued: Vec<u32> = end
                    .queued
                    .iter()
                    .filter(|(s, n)| **n > 0 && !end.stuck.contains(s))
                    .map(|(s, _)| *s)
                    .collect();
                for s in queued {
                    end.drain(s);
                    moved = true;
                }
            }
            if !moved {
                return;
            }
        }
    }

    fn no_violation(&self) -> Result<(), String> {
        for end in [&self.s, &self.o] {
            if let Some(v) = &end.violation {
                return Err(v.clone());
            }
        }
        Ok(())
    }

    /// Stream `s` carried every byte each side wrote, in order, and each `FIN` after the last of them.
    fn whole(&self, s: u32) -> Result<(), String> {
        for (from, to) in [(&self.s, &self.o), (&self.o, &self.s)] {
            let asked = from.asked.get(&s).copied().unwrap_or(0);
            let got = to.got.get(&s).copied().unwrap_or(0);
            if got != asked {
                return Err(format!(
                    "stream {s}: {:?} wrote {asked} bytes, {:?} got {got}",
                    from.side, to.side
                ));
            }
            if from.eof_wanted.contains(&s) && to.closed_write_at.get(&s) != Some(&asked) {
                return Err(format!(
                    "stream {s}: {:?}'s FIN reached {:?} at {:?}, not after its {asked} bytes",
                    from.side,
                    to.side,
                    to.closed_write_at.get(&s)
                ));
            }
        }
        Ok(())
    }

    fn all_closed(&self) -> Result<(), String> {
        for end in [&self.s, &self.o] {
            if end.mux.counted() != 0 {
                return Err(format!(
                    "{:?} still counts {} streams",
                    end.side,
                    end.mux.counted()
                ));
            }
        }
        Ok(())
    }
}

/// The world as a skuld core, for one test's kinds.
struct Run<K> {
    w: World,
    _k: PhantomData<K>,
}

impl<K: Kinds> Core for Run<K> {
    type Event = Step<K>;
    fn step(&mut self, ev: Step<K>) -> Vec<Step<K>> {
        self.w.apply(&ev.0);
        Vec::new()
    }
}

fn run<K: Kinds>(
    sources: Vec<(&'static str, Vec<Ev>)>,
    make: impl Fn() -> World,
    mut check: impl FnMut(&World, &World) -> Result<(), String>,
) -> skuld::Report {
    let mut p = Partial::new();
    for (name, evs) in sources {
        p.source(name, steps::<K>(evs));
    }
    every_order(
        &p,
        Bound::default(),
        || Run::<K> {
            w: make(),
            _k: PhantomData,
        },
        |core, _| {
            let mut settled = core.w.clone();
            settled.settle();
            check(&core.w, &settled)
        },
    )
}

macro_rules! kinds {
    ($name:ident: $($k:literal),+) => {
        #[derive(Clone, Debug)]
        struct $name;
        impl Kinds for $name {
            const KINDS: &'static [&'static str] = &[$($k),+];
        }
    };
}

use At::{O, S};

/// [A] Two streams open, carry bytes both ways and half-close in every order of the sidecar's local events, both
/// writers and both readers: each stream's bytes arrive once and in order, each `FIN` after its last byte, and both
/// ends end with nothing counted.
#[test]
fn every_order_open_data_fin_reach_the_other_end_once() {
    kinds!(K: "Accept", "Send", "Eof", "Write", "Read");
    let r = run::<K>(
        vec![
            (
                "sidecar's job",
                vec![
                    Ev::Accept,
                    Ev::Accept,
                    Ev::Send {
                        at: S,
                        s: 1,
                        n: 20_000,
                    },
                    Ev::Send {
                        at: S,
                        s: 3,
                        n: 100,
                    },
                    Ev::Eof { at: S, s: 1 },
                    Ev::Eof { at: S, s: 3 },
                ],
            ),
            ("sidecar's writer", n_of(Ev::Write { at: S }, 4)),
            ("owner's reader", n_of(Ev::Read { at: O }, 4)),
            (
                "owner's upstream",
                vec![
                    Ev::Send { at: O, s: 1, n: 30 },
                    Ev::Eof { at: O, s: 1 },
                    Ev::Eof { at: O, s: 3 },
                ],
            ),
            ("owner's writer", n_of(Ev::Write { at: O }, 2)),
            ("sidecar's reader", n_of(Ev::Read { at: S }, 2)),
        ],
        World::new,
        |_, w| {
            w.no_violation()?;
            w.whole(1)?;
            w.whole(3)?;
            w.all_closed()
        },
    );
    assert!(r.orders > 1, "{r:?}");
}

/// [A] A stream reset mid-transfer leaves the other stream whole, in every order.
#[test]
fn every_order_rst_mid_stream_leaves_the_other_stream_whole() {
    kinds!(K: "Accept", "Send", "Eof", "Reset", "Write", "Read");
    run::<K>(
        vec![
            (
                "sidecar's job",
                vec![
                    Ev::Accept,
                    Ev::Accept,
                    Ev::Send {
                        at: S,
                        s: 1,
                        n: 20_000,
                    },
                    Ev::Send {
                        at: S,
                        s: 3,
                        n: 20_000,
                    },
                    Ev::Reset { at: S, s: 1 },
                    Ev::Eof { at: S, s: 3 },
                ],
            ),
            ("sidecar's writer", n_of(Ev::Write { at: S }, 4)),
            ("owner's reader", n_of(Ev::Read { at: O }, 4)),
            (
                "owner's upstream",
                vec![
                    Ev::Send {
                        at: O,
                        s: 3,
                        n: 100,
                    },
                    Ev::Eof { at: O, s: 3 },
                    Ev::Send {
                        at: O,
                        s: 1,
                        n: 100,
                    },
                ],
            ),
            ("owner's writer", n_of(Ev::Write { at: O }, 2)),
            ("sidecar's reader", n_of(Ev::Read { at: S }, 2)),
        ],
        World::new,
        |_, w| {
            w.no_violation()?;
            w.whole(3)?;
            for end in [&w.s, &w.o] {
                if !end.dropped.contains(&1) {
                    return Err(format!("{:?} never dropped stream 1", end.side));
                }
            }
            w.all_closed()
        },
    );
}

/// [A] Both ways: one end resets a stream while the other's `DATA` for it is in flight. The late `DATA` is
/// discarded (in some order, at least), there is no violation, and the other stream finishes.
#[test]
fn every_order_rst_crossing_data_leaves_the_channel_whole() {
    kinds!(K: "Send", "Eof", "Reset", "Write", "Read");
    for (sender, resetter) in [(O, S), (S, O)] {
        let discarded = Cell::new(0usize);
        run::<K>(
            vec![
                (
                    "sender",
                    vec![
                        Ev::Send {
                            at: sender,
                            s: 1,
                            n: 40_000,
                        },
                        Ev::Send {
                            at: sender,
                            s: 3,
                            n: 100,
                        },
                        Ev::Eof { at: sender, s: 3 },
                    ],
                ),
                ("sender's writer", n_of(Ev::Write { at: sender }, 4)),
                ("resetter's reader", n_of(Ev::Read { at: resetter }, 4)),
                (
                    "resetter",
                    vec![
                        Ev::Reset { at: resetter, s: 1 },
                        Ev::Eof { at: resetter, s: 3 },
                    ],
                ),
                ("resetter's writer", n_of(Ev::Write { at: resetter }, 2)),
                ("sender's reader", n_of(Ev::Read { at: sender }, 2)),
            ],
            || World::with_streams(2),
            |_, w| {
                w.no_violation()?;
                w.whole(3)?;
                w.all_closed()?;
                let late = [&w.s, &w.o]
                    .iter()
                    .flat_map(|e| e.discarded.iter())
                    .filter(|(s, k)| *s == 1 && *k == Kind::Data)
                    .count();
                discarded.set(discarded.get() + late);
                Ok(())
            },
        );
        assert!(
            discarded.get() > 0,
            "no order had DATA for stream 1 cross its RST ({sender:?} sends)"
        );
    }
}

/// [A] A `CREDIT` the owner wrote after its `FIN` reaches a sidecar that already closed the stream: discarded, in
/// every order, and never a violation.
#[test]
fn every_order_credit_after_both_fins_is_discarded() {
    kinds!(K: "Send", "Eof", "Drain", "Write", "Read");
    let late = Cell::new(0usize);
    run::<K>(
        vec![
            (
                "sidecar's job",
                vec![
                    Ev::Send {
                        at: S,
                        s: 1,
                        n: 30_000,
                    },
                    Ev::Eof { at: S, s: 1 },
                ],
            ),
            ("sidecar's writer", n_of(Ev::Write { at: S }, 3)),
            ("owner's reader", n_of(Ev::Read { at: O }, 3)),
            ("owner's consumer", n_of(Ev::Drain { at: O, s: 1 }, 2)),
            ("owner's upstream", vec![Ev::Eof { at: O, s: 1 }]),
            ("owner's writer", n_of(Ev::Write { at: O }, 3)),
            ("sidecar's reader", n_of(Ev::Read { at: S }, 3)),
        ],
        || {
            let mut w = World::with_streams(1);
            w.o.auto_drain = false;
            w
        },
        |_, w| {
            w.no_violation()?;
            w.whole(1)?;
            w.all_closed()?;
            late.set(
                late.get()
                    + w.s
                        .discarded
                        .iter()
                        .filter(|(_, k)| *k == Kind::Credit)
                        .count(),
            );
            Ok(())
        },
    );
    assert!(
        late.get() > 0,
        "no order had a CREDIT arrive after both FINs"
    );
}

/// [A] A `FIN` and an `RST` for one stream cross: the `FIN` is discarded, in every order, and never a violation.
#[test]
fn every_order_fin_crossing_rst_is_discarded() {
    kinds!(K: "Eof", "Reset", "Write", "Read");
    let late = Cell::new(0usize);
    run::<K>(
        vec![
            ("sidecar's job", vec![Ev::Eof { at: S, s: 1 }]),
            ("sidecar's writer", n_of(Ev::Write { at: S }, 2)),
            ("owner's reader", n_of(Ev::Read { at: O }, 2)),
            ("owner's upstream", vec![Ev::Reset { at: O, s: 1 }]),
            ("owner's writer", n_of(Ev::Write { at: O }, 2)),
            ("sidecar's reader", n_of(Ev::Read { at: S }, 2)),
        ],
        || World::with_streams(1),
        |_, w| {
            w.no_violation()?;
            w.all_closed()?;
            late.set(
                late.get()
                    + w.o
                        .discarded
                        .iter()
                        .filter(|(_, k)| *k == Kind::Fin)
                        .count(),
            );
            Ok(())
        },
    );
    assert!(late.get() > 0, "no order had the FIN cross the RST");
}

/// [A] Both ways: a stream's last 256 KiB and more (a full window, then what waits for credit) and its local EOF,
/// against the writer's frames and the peer's `CREDIT`s, with a second stream's traffic interleaved. On the wire every
/// `FIN` comes after its stream's last `DATA`, and the peer's `Mux` takes it all with no `DataAfterFin`.
#[test]
fn every_order_fin_follows_its_last_data() {
    kinds!(K: "Send", "Eof", "Drain", "Write", "Read");
    for (big, peer) in [(S, O), (O, S)] {
        let total = WINDOW as usize + 20_000;
        run::<K>(
            vec![
                (
                    "the big stream",
                    vec![
                        Ev::Send {
                            at: big,
                            s: 1,
                            n: total,
                        },
                        Ev::Eof { at: big, s: 1 },
                    ],
                ),
                ("its writer", n_of(Ev::Write { at: big }, 8)),
                ("the peer's reader", n_of(Ev::Read { at: peer }, 8)),
                ("the peer's consumer", n_of(Ev::Drain { at: peer, s: 1 }, 2)),
                ("the peer's writer", n_of(Ev::Write { at: peer }, 2)),
                ("its reader", n_of(Ev::Read { at: big }, 2)),
                (
                    "the second stream",
                    vec![
                        Ev::Send {
                            at: big,
                            s: 3,
                            n: 100,
                        },
                        Ev::Send {
                            at: peer,
                            s: 3,
                            n: 100,
                        },
                        Ev::Eof { at: big, s: 3 },
                        Ev::Eof { at: peer, s: 3 },
                        Ev::Eof { at: peer, s: 1 },
                    ],
                ),
            ],
            || {
                let mut w = World::with_streams(2);
                match peer {
                    S => w.s.auto_drain = false,
                    O => w.o.auto_drain = false,
                }
                w
            },
            |_, w| {
                w.no_violation()?;
                for end in [&w.s, &w.o] {
                    for (i, (s, k)) in end.wire.iter().enumerate() {
                        if *k == Kind::Fin
                            && let Some(j) = end.wire[i..]
                                .iter()
                                .position(|(t, k)| t == s && *k == Kind::Data)
                        {
                            return Err(format!(
                                "{:?} wrote DATA {s} {j} frames after its FIN",
                                end.side
                            ));
                        }
                    }
                }
                w.whole(1)?;
                w.whole(3)?;
                w.all_closed()
            },
        );
    }
}

/// [A] 64 counted streams: one closed by a local `RST`, one by both `FIN`s with the sidecar's held behind a full
/// window, and a 65th and a 66th client waiting for `Room`, against the sidecar's writes and the owner's frames. The
/// owner never counts a 65th and never refuses one; both clients open in the end.
#[test]
fn every_order_close_then_open_never_exceeds_64() {
    kinds!(K: "Send", "Eof", "Reset", "Accept", "Write", "Read");
    run::<K>(
        vec![
            (
                "sidecar's jobs",
                vec![
                    Ev::Send {
                        at: S,
                        s: 3,
                        n: WINDOW as usize,
                    },
                    Ev::Eof { at: S, s: 3 },
                    Ev::Reset { at: S, s: 1 },
                    Ev::Accept,
                    Ev::Accept,
                ],
            ),
            ("sidecar's writer", n_of(Ev::Write { at: S }, 6)),
            ("owner's reader", n_of(Ev::Read { at: O }, 6)),
            ("owner's upstream", vec![Ev::Eof { at: O, s: 3 }]),
            ("owner's writer", n_of(Ev::Write { at: O }, 2)),
            ("sidecar's reader", n_of(Ev::Read { at: S }, 2)),
        ],
        || World::with_streams(MAX_STREAMS),
        |_, w| {
            w.no_violation()?;
            if w.o.max_counted > MAX_STREAMS || w.o.refused > 0 {
                return Err(format!(
                    "the owner counted up to {} and refused {}",
                    w.o.max_counted, w.o.refused
                ));
            }
            w.whole(3)?;
            // the 65th and 66th clients, each let in by one of the two closes
            for s in [2 * MAX_STREAMS as u32 + 1, 2 * MAX_STREAMS as u32 + 3] {
                if !w.o.known.contains(&s) {
                    return Err(format!("stream {s} never opened"));
                }
            }
            Ok(())
        },
    );
}

/// [A] 64 counted streams; the owner resets one (its proxy dropped it) while a 65th client waits at the sidecar. The
/// owner's writer takes the `RST`, `write(2)` takes it, and the writer steps on, each a step of its own: the sidecar
/// may read the `RST`, accept the 65th and write its `OPEN` before the owner's writer has stepped on after the write.
/// The owner still never counts a 65th and never refuses it: its `RST` counts as written from the moment the writer
/// took it.
#[test]
fn every_order_the_owners_rst_frees_its_place_before_the_sidecar_answers() {
    kinds!(K: "Reset", "Take", "Put", "Ack", "Accept", "Write", "Read");
    run::<K>(
        vec![
            ("owner's upstream", vec![Ev::Reset { at: O, s: 1 }]),
            (
                "owner's writer",
                vec![Ev::Take { at: O }, Ev::Put { at: O }, Ev::Ack { at: O }],
            ),
            ("sidecar's reader", n_of(Ev::Read { at: S }, 1)),
            ("the 65th client", vec![Ev::Accept]),
            ("sidecar's writer", n_of(Ev::Write { at: S }, 1)),
            ("owner's reader", n_of(Ev::Read { at: O }, 1)),
        ],
        || World::with_streams(MAX_STREAMS),
        |_, w| {
            w.no_violation()?;
            if w.o.max_counted > MAX_STREAMS || w.o.refused > 0 {
                return Err(format!(
                    "the owner counted up to {} and refused {}",
                    w.o.max_counted, w.o.refused
                ));
            }
            let s65 = 2 * MAX_STREAMS as u32 + 1;
            if !w.o.known.contains(&s65) {
                return Err(format!("stream {s65} never opened at the owner"));
            }
            Ok(())
        },
    );
}

/// [A] Three clients accepted back to back, the writer's passes interleaved with `DATA` and `CREDIT`s: the `OPEN`s on
/// the wire rise by 2, and the owner sees no `NotRisingByTwo`.
#[test]
fn every_order_opens_leave_in_id_order() {
    kinds!(K: "Accept", "Send", "Write", "Read");
    run::<K>(
        vec![
            (
                "sidecar's jobs",
                vec![
                    Ev::Accept,
                    Ev::Send {
                        at: S,
                        s: 1,
                        n: 20_000,
                    },
                    Ev::Accept,
                    Ev::Send {
                        at: S,
                        s: 3,
                        n: 100,
                    },
                    Ev::Accept,
                ],
            ),
            ("sidecar's writer", n_of(Ev::Write { at: S }, 5)),
            ("owner's reader", n_of(Ev::Read { at: O }, 5)),
            ("owner's writer", n_of(Ev::Write { at: O }, 2)),
            ("sidecar's reader", n_of(Ev::Read { at: S }, 2)),
        ],
        World::new,
        |_, w| {
            w.no_violation()?;
            let opens: Vec<u32> =
                w.s.wire
                    .iter()
                    .filter(|(_, k)| *k == Kind::Open)
                    .map(|(s, _)| *s)
                    .collect();
            if opens != [1, 3, 5] {
                return Err(format!("OPENs on the wire: {opens:?}"));
            }
            Ok(())
        },
    );
}

/// [A] An accept and its reset before the writer's next pass, against every position of a pass busy with another
/// stream's `DATA` and `CREDIT`s: `OPEN` 3, then `RST` 3, and no `DATA` of 3 at all; the owner sees no
/// `AboveHighest`.
#[test]
fn every_order_instant_reset_sends_open_first() {
    kinds!(K: "Accept", "Reset", "Send", "Write", "Read");
    run::<K>(
        vec![
            (
                "the instant client",
                vec![Ev::Accept, Ev::Reset { at: S, s: 3 }],
            ),
            (
                "stream 1's job",
                vec![Ev::Send {
                    at: S,
                    s: 1,
                    n: 40_000,
                }],
            ),
            ("sidecar's writer", n_of(Ev::Write { at: S }, 5)),
            ("owner's reader", n_of(Ev::Read { at: O }, 5)),
            (
                "owner's upstream",
                vec![Ev::Send {
                    at: O,
                    s: 1,
                    n: 100,
                }],
            ),
            ("owner's writer", n_of(Ev::Write { at: O }, 1)),
            ("sidecar's reader", n_of(Ev::Read { at: S }, 1)),
        ],
        || World::with_streams(1),
        |_, w| {
            w.no_violation()?;
            let of3: Vec<Kind> =
                w.s.wire
                    .iter()
                    .filter(|(s, _)| *s == 3)
                    .map(|(_, k)| *k)
                    .collect();
            if of3 != [Kind::Open, Kind::Rst] {
                return Err(format!("stream 3 on the wire: {of3:?}"));
            }
            // stream 1 stays open; stream 3 counts nowhere
            if w.s.mux.counted() != 1 || w.o.mux.counted() != 1 {
                return Err(format!(
                    "counted: sidecar {}, owner {}",
                    w.s.mux.counted(),
                    w.o.mux.counted()
                ));
            }
            Ok(())
        },
    );
}

/// [A] Two streams; the owner's consumer of stream 1 never drains. Stream 1 stops at its window and waits; stream 3's
/// 1 MiB arrives whole and drains, in every order of the sidecar's writes, the owner's reads and their `CREDIT`s.
#[test]
fn every_order_a_full_window_stalls_only_its_stream() {
    kinds!(K: "Send", "Eof", "Write", "Read");
    const MIB: usize = 1 << 20;
    let over = 30_000;
    run::<K>(
        vec![
            (
                "stream 1's job",
                vec![Ev::Send {
                    at: S,
                    s: 1,
                    n: WINDOW as usize + over,
                }],
            ),
            (
                "stream 3's job",
                vec![
                    Ev::Send {
                        at: S,
                        s: 3,
                        n: MIB,
                    },
                    Ev::Eof { at: S, s: 3 },
                ],
            ),
            ("sidecar's writer", n_of(Ev::Write { at: S }, 6)),
            ("owner's reader", n_of(Ev::Read { at: O }, 6)),
            ("owner's writer", n_of(Ev::Write { at: O }, 2)),
            ("sidecar's reader", n_of(Ev::Read { at: S }, 2)),
        ],
        || {
            let mut w = World::with_streams(2);
            w.o.stuck.insert(1);
            w
        },
        |_, w| {
            w.no_violation()?;
            w.whole(3)?;
            if w.o.queued.get(&3).copied().unwrap_or(0) != 0 {
                return Err("stream 3 isn't drained".into());
            }
            let got1 = w.o.got.get(&1).copied().unwrap_or(0);
            let left1 = w.s.to_send.get(&1).copied().unwrap_or(0);
            if got1 != WINDOW as usize || left1 != over || w.s.mux.credit(1) != 0 {
                return Err(format!(
                    "stream 1: the owner got {got1}, the sidecar has {left1} left and {} credit",
                    w.s.mux.credit(1)
                ));
            }
            Ok(())
        },
    );
}

/// [A] The sidecar's output ends (its process is gone) while two streams carry bytes both ways, in every order of
/// the writes and reads before it: the owner reads what reached the pipe, then its channel ends with `Eof`, and every
/// stream it knew went down, by its own close or with the channel. Nothing breaks a rule on the way.
#[test]
fn every_order_sidecar_eof_ends_every_stream_and_returns_eof() {
    kinds!(K: "Accept", "Send", "Close", "Write", "Read");
    run::<K>(
        vec![
            (
                "sidecar's jobs",
                vec![
                    Ev::Accept,
                    Ev::Send {
                        at: S,
                        s: 1,
                        n: 20_000,
                    },
                    Ev::Accept,
                    Ev::Send {
                        at: S,
                        s: 3,
                        n: 100,
                    },
                    Ev::Close { at: S },
                ],
            ),
            ("sidecar's writer", n_of(Ev::Write { at: S }, 4)),
            ("owner's reader", n_of(Ev::Read { at: O }, 5)),
            ("owner's upstream", vec![Ev::Send { at: O, s: 1, n: 50 }]),
            ("owner's writer", n_of(Ev::Write { at: O }, 1)),
            ("sidecar's reader", n_of(Ev::Read { at: S }, 1)),
        ],
        World::new,
        |_, w| {
            w.no_violation()?;
            if !w.o.ended {
                return Err("the owner's channel never ended".into());
            }
            for s in &w.o.known {
                if !w.o.dropped.contains(s) && !w.o.killed.contains(s) {
                    return Err(format!("stream {s} outlived the channel"));
                }
            }
            Ok(())
        },
    );
}
