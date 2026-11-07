//! The relay's state machine, pure and shared by both ends: what each received frame and each local event does to
//! the channel's streams, their credit and the count toward [`MAX_STREAMS`].
//!
//! The rules follow RFC 9113 (HTTP/2) where it has the same case. On closed streams, §5.1:
//!
//! > An endpoint that sends a frame with the END_STREAM flag set or a RST_STREAM frame might receive a WINDOW_UPDATE
//! > or RST_STREAM frame from its peer in the time before the peer receives and processes the frame that closes the
//! > stream.
//! >
//! > An endpoint that sends a RST_STREAM frame on a stream that is in the "open" or "half-closed (local)" state could
//! > receive any type of frame. The peer might have sent or enqueued for sending these frames before processing the
//! > RST_STREAM frame. An endpoint MUST minimally process and then discard any frames it receives in this state.
//! >
//! > Flow-controlled frames (i.e., DATA) received after sending RST_STREAM are counted toward the connection
//! > flow-control window.
//!
//! So a frame for a closed stream is [`Out::Discarded`], and its `DATA` still counts against the credit the peer had
//! left on it (the tombstone). On credit overflow, §6.9.1:
//!
//! > A sender MUST NOT allow a flow-control window to exceed 2^31-1 octets. If a sender receives a WINDOW_UPDATE that
//! > causes a flow-control window to exceed this maximum, it MUST terminate either the stream or the connection, as
//! > appropriate.
//!
//! Here the bound is [`WINDOW`]: a `CREDIT` that would raise the sending credit above it closes the channel.
//!
//! A stream is **counted** from its `OPEN` until the peer's `RST` is received, or this end's `RST` is written, or both
//! `FIN`s are in and this end's has been written. "Written" means the one writer took it (it reports each `FIN`
//! and `RST` it takes with [`In::Wrote`]): it writes frames in the order it takes them, so nothing decided after is
//! ahead of it on the pipe. A `FIN` decided but held behind its stream's `DATA` keeps the stream counted. So an `OPEN` that a
//! freed place allows is always behind the frame that freed it on the pipe, and a correct sidecar never sends the
//! owner more than [`MAX_STREAMS`] counted.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::fmt;
use std::net::IpAddr;
use std::time::Duration;

use crate::frame::{ForeignSource, Frame, Kind, MAX_DATA, MAX_STREAMS, WINDOW};

/// The last stream id: ids are 31 bits, odd, so a channel carries at most 2³⁰ streams.
pub const LAST_ID: u32 = 0x7FFF_FFFF;
/// Closed streams remembered, oldest out first; frames for older ones are discarded uncounted.
pub const MAX_TOMBSTONES: usize = 1024;
/// Foreign-source addresses remembered; past them sources are counted, not reported.
pub const MAX_SOURCES: usize = 256;
/// Foreign sources reported per second; past them they are counted.
pub const EVENTS_PER_SECOND: u32 = 10;
/// Uncredited bytes that make a `CREDIT` go out before the stream's queue is empty.
pub const CREDIT_AT: u32 = 65_536;

/// Which end this is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Sidecar,
    Owner,
}

/// What happened: a frame from the peer, or a local event from this end's shell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum In {
    Frame(Frame),
    /// The sidecar accepted a job connection.
    LocalOpen,
    /// Bytes read from the stream's consumer, never more than [`Mux::credit`].
    LocalData {
        stream: u32,
        bytes: Vec<u8>,
    },
    /// The consumer's side ended its writing.
    LocalEof {
        stream: u32,
    },
    /// Bytes that left the stream's queue for its consumer.
    LocalDrained {
        stream: u32,
        n: u32,
    },
    /// The consumer failed or went: reset the stream.
    LocalReset {
        stream: u32,
    },
    /// The writer took this end's `FIN` or `RST` for the stream to write: from here it counts as written, since the
    /// one writer puts it on the pipe ahead of anything decided after.
    Wrote {
        stream: u32,
        kind: Kind,
    },
}

/// What the shell does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Out {
    /// Hand the frame to the writer.
    Send(Frame),
    /// The peer opened a stream (owner).
    NewStream { stream: u32 },
    /// Append to the stream's queue; never awaited.
    Deliver { stream: u32, bytes: Vec<u8> },
    /// The peer's half-close: end the consumer's writing once the queue is drained.
    CloseWrite { stream: u32 },
    /// The stream is gone: abort its tasks.
    Drop { stream: u32 },
    /// The stream's sending credit grew: wake its reading task.
    CreditFor { stream: u32 },
    /// A frame for a closed stream, discarded.
    Discarded { stream: u32, kind: Kind },
    /// The counted streams fell below [`MAX_STREAMS`]: wake the accept loop.
    Room,
    /// The next stream id would pass [`LAST_ID`] (sidecar).
    IdsUsedUp,
    /// A foreign source to report (owner).
    Event(ForeignSource),
    /// Foreign sources not reported so far (past the address set or the rate cap); once a second at most.
    EventsCounted(u64),
}

/// What the channel's state shows is wrong. Any of them closes the channel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StreamViolation {
    /// `DATA`, `CREDIT`, `FIN` or `RST` for a stream above the highest opened.
    AboveHighest(u32),
    /// An `OPEN` whose id isn't the highest plus 2 (1 first).
    NotRisingByTwo(u32),
    /// A kind from the side that doesn't send it.
    WrongSide(Kind),
    /// `DATA` past the stream's credit.
    OverCredit(u32),
    /// A `CREDIT` that would raise the sending credit above the window.
    CreditOverflow(u32),
    DataAfterFin(u32),
    SecondFin(u32),
    /// A sidecar frame before its `READY`.
    ReadyNotFirst,
    ReadyTwice,
    /// An `OPEN` at the cap while the cap's worth of refusals is unwritten.
    TooMany,
    /// A local open at the cap: a bug of the shell.
    LocalTooMany,
}

impl fmt::Display for StreamViolation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StreamViolation::AboveHighest(s) => {
                write!(f, "a frame for stream {s}, above the highest opened")
            }
            StreamViolation::NotRisingByTwo(s) => {
                write!(f, "OPEN of stream {s}, not the highest plus 2")
            }
            StreamViolation::WrongSide(k) => write!(f, "{k:?} from the wrong side"),
            StreamViolation::OverCredit(s) => write!(f, "DATA past the credit of stream {s}"),
            StreamViolation::CreditOverflow(s) => {
                write!(f, "CREDIT above the window on stream {s}")
            }
            StreamViolation::DataAfterFin(s) => write!(f, "DATA after FIN on stream {s}"),
            StreamViolation::SecondFin(s) => write!(f, "a second FIN on stream {s}"),
            StreamViolation::ReadyNotFirst => write!(f, "a frame before READY"),
            StreamViolation::ReadyTwice => write!(f, "a second READY"),
            StreamViolation::TooMany => write!(f, "OPEN past {MAX_STREAMS} unwritten refusals"),
            StreamViolation::LocalTooMany => {
                write!(f, "a local open at {MAX_STREAMS} counted streams")
            }
        }
    }
}

impl std::error::Error for StreamViolation {}

/// An open stream (both halves, or one).
#[derive(Clone, Debug)]
struct Stream {
    /// Bytes this end may still send.
    send_credit: u32,
    /// Bytes the peer may still send.
    recv_credit: u32,
    /// Delivered, not yet drained.
    queued: u32,
    /// Drained, not yet credited.
    uncredited: u32,
    local_fin: bool,
    fin_written: bool,
    peer_fin: bool,
}

impl Stream {
    fn new() -> Self {
        Stream {
            send_credit: WINDOW,
            recv_credit: WINDOW,
            queued: 0,
            uncredited: 0,
            local_fin: false,
            fin_written: false,
            peer_fin: false,
        }
    }
}

/// What a foreign source does, given the time.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Admit {
    Report,
    Seen,
    Counted { first_this_second: bool },
}

/// The foreign-source cap: once per address, at most [`EVENTS_PER_SECOND`], at most [`MAX_SOURCES`] remembered.
#[derive(Clone, Debug, Default)]
struct EventGate {
    seen: HashSet<IpAddr>,
    second: u64,
    in_second: u32,
    counted: u64,
    counted_second: Option<u64>,
}

impl EventGate {
    fn admit(&mut self, ip: IpAddr, now: Duration) -> Admit {
        if self.seen.contains(&ip) {
            return Admit::Seen;
        }
        let second = now.as_secs();
        if second != self.second {
            self.second = second;
            self.in_second = 0;
        }
        if self.seen.len() >= MAX_SOURCES || self.in_second >= EVENTS_PER_SECOND {
            self.counted += 1;
            let first = self.counted_second != Some(second);
            self.counted_second = Some(second);
            return Admit::Counted {
                first_this_second: first,
            };
        }
        self.in_second += 1;
        self.seen.insert(ip);
        Admit::Report
    }
}

/// One end's channel state.
#[derive(Clone, Debug)]
pub struct Mux {
    side: Side,
    ready: bool,
    /// `H`, the highest opened id (0 before the first).
    highest: u32,
    open: BTreeMap<u32, Stream>,
    /// Closed by this end's frame, which isn't written yet: still counted.
    closing: HashMap<u32, Kind>,
    /// Closed streams and the credit the peer had left on each.
    tombs: HashMap<u32, u32>,
    tomb_order: VecDeque<u32>,
    /// The owner's refusals (`RST` of an `OPEN` at the cap) not yet written.
    refusing: HashSet<u32>,
    events: EventGate,
    now: Duration,
}

impl Mux {
    pub fn new(side: Side) -> Self {
        Mux {
            side,
            ready: false,
            highest: 0,
            open: BTreeMap::new(),
            closing: HashMap::new(),
            tombs: HashMap::new(),
            tomb_order: VecDeque::new(),
            refusing: HashSet::new(),
            events: EventGate::default(),
            now: Duration::ZERO,
        }
    }

    /// The monotonic time the foreign-source rate cap reads; the shell sets it before stepping.
    pub fn set_now(&mut self, now: Duration) {
        self.now = now;
    }

    /// The owner read the sidecar's `READY` itself, before stepping any frame: what follows is the channel, and
    /// another `READY` is a violation.
    pub fn ready_read(&mut self) {
        self.ready = true;
    }

    /// The stream's sending credit (0 for a stream that isn't open).
    pub fn credit(&self, stream: u32) -> u32 {
        self.open.get(&stream).map_or(0, |s| s.send_credit)
    }

    /// Streams counted toward [`MAX_STREAMS`].
    pub fn counted(&self) -> usize {
        self.open.len() + self.closing.len()
    }

    /// Steps the state with one event.
    pub fn step(&mut self, ev: In) -> Result<Vec<Out>, StreamViolation> {
        let mut out = Vec::new();
        match ev {
            In::Frame(f) => self.frame(f, &mut out)?,
            In::LocalOpen => self.local_open(&mut out)?,
            In::LocalData { stream, bytes } => self.local_data(stream, bytes, &mut out)?,
            In::LocalEof { stream } => self.local_eof(stream, &mut out),
            In::LocalDrained { stream, n } => self.local_drained(stream, n, &mut out),
            In::LocalReset { stream } => self.local_reset(stream, &mut out),
            In::Wrote { stream, kind } => self.wrote(stream, kind, &mut out),
        }
        Ok(out)
    }

    fn frame(&mut self, f: Frame, out: &mut Vec<Out>) -> Result<(), StreamViolation> {
        let from_sidecar = self.side == Side::Owner;
        let wrong_side = match f.kind {
            Kind::Ready | Kind::Open | Kind::Event => !from_sidecar,
            Kind::Beat => from_sidecar,
            Kind::Data | Kind::Credit | Kind::Fin | Kind::Rst => false,
        };
        if wrong_side {
            return Err(StreamViolation::WrongSide(f.kind));
        }
        if from_sidecar && !self.ready && f.kind != Kind::Ready {
            return Err(StreamViolation::ReadyNotFirst);
        }
        match f.kind {
            Kind::Ready => {
                if self.ready {
                    return Err(StreamViolation::ReadyTwice);
                }
                self.ready = true;
            }
            Kind::Beat => {}
            Kind::Event => {
                // the codec checked the payload; a frame built by hand that isn't an address is ignored
                if let Some(src) = ForeignSource::parse(&f.payload) {
                    match self.events.admit(src.0, self.now) {
                        Admit::Report => out.push(Out::Event(src)),
                        Admit::Counted {
                            first_this_second: true,
                        } => out.push(Out::EventsCounted(self.events.counted)),
                        Admit::Counted { .. } | Admit::Seen => {}
                    }
                }
            }
            Kind::Open => self.peer_open(f.stream, out)?,
            Kind::Data | Kind::Credit | Kind::Fin | Kind::Rst => self.peer_stream(f, out)?,
        }
        Ok(())
    }

    fn next_id(&self) -> u64 {
        if self.highest == 0 {
            1
        } else {
            u64::from(self.highest) + 2
        }
    }

    fn peer_open(&mut self, s: u32, out: &mut Vec<Out>) -> Result<(), StreamViolation> {
        if u64::from(s) != self.next_id() {
            return Err(StreamViolation::NotRisingByTwo(s));
        }
        if self.counted() >= MAX_STREAMS {
            if self.refusing.len() >= MAX_STREAMS {
                return Err(StreamViolation::TooMany);
            }
            // refused (RFC 9113 §5.1.2, REFUSED_STREAM): the peer may still send up to its window on it
            self.highest = s;
            self.refusing.insert(s);
            self.tomb(s, WINDOW);
            out.push(Out::Send(Frame::empty(s, Kind::Rst)));
            return Ok(());
        }
        self.highest = s;
        self.open.insert(s, Stream::new());
        out.push(Out::NewStream { stream: s });
        Ok(())
    }

    fn peer_stream(&mut self, f: Frame, out: &mut Vec<Out>) -> Result<(), StreamViolation> {
        let s = f.stream;
        if s > self.highest {
            return Err(StreamViolation::AboveHighest(s));
        }
        let Some(st) = self.open.get_mut(&s) else {
            // closed: discarded, and DATA counted against what the peer had left
            if f.kind == Kind::Data
                && let Some(left) = self.tombs.get_mut(&s)
            {
                let len = f.payload.len() as u32;
                if len > *left {
                    return Err(StreamViolation::OverCredit(s));
                }
                *left -= len;
            }
            out.push(Out::Discarded {
                stream: s,
                kind: f.kind,
            });
            return Ok(());
        };
        match f.kind {
            Kind::Data => {
                let len = f.payload.len() as u32;
                if st.peer_fin {
                    return Err(StreamViolation::DataAfterFin(s));
                }
                if len > st.recv_credit {
                    return Err(StreamViolation::OverCredit(s));
                }
                st.recv_credit -= len;
                st.queued += len;
                out.push(Out::Deliver {
                    stream: s,
                    bytes: f.payload,
                });
            }
            Kind::Credit => {
                let Some(n) = f.credit_value() else {
                    return Ok(());
                };
                if u64::from(st.send_credit) + u64::from(n) > u64::from(WINDOW) {
                    return Err(StreamViolation::CreditOverflow(s));
                }
                st.send_credit += n;
                out.push(Out::CreditFor { stream: s });
            }
            Kind::Fin => {
                if st.peer_fin {
                    return Err(StreamViolation::SecondFin(s));
                }
                st.peer_fin = true;
                out.push(Out::CloseWrite { stream: s });
                if st.local_fin {
                    // ours went first; counted until it is written, if it isn't yet
                    let awaiting = (!st.fin_written).then_some(Kind::Fin);
                    self.close(s, awaiting, out);
                }
            }
            Kind::Rst => {
                out.push(Out::Drop { stream: s });
                self.close(s, None, out);
            }
            Kind::Ready | Kind::Open | Kind::Beat | Kind::Event => {
                unreachable!("stream frames only")
            }
        }
        Ok(())
    }

    /// Closes an open stream: a tombstone, and counted on until `awaiting` (this end's closing frame) is written.
    fn close(&mut self, s: u32, awaiting: Option<Kind>, out: &mut Vec<Out>) {
        let before = self.counted();
        let st = self.open.remove(&s).expect("closing an open stream");
        self.tomb(s, st.recv_credit);
        match awaiting {
            Some(kind) => {
                self.closing.insert(s, kind);
            }
            None => self.room(before, out),
        }
    }

    fn room(&self, before: usize, out: &mut Vec<Out>) {
        if before >= MAX_STREAMS && self.counted() < MAX_STREAMS {
            out.push(Out::Room);
        }
    }

    fn tomb(&mut self, s: u32, left: u32) {
        self.tombs.insert(s, left);
        self.tomb_order.push_back(s);
        if self.tomb_order.len() > MAX_TOMBSTONES
            && let Some(old) = self.tomb_order.pop_front()
        {
            self.tombs.remove(&old);
        }
    }

    fn local_open(&mut self, out: &mut Vec<Out>) -> Result<(), StreamViolation> {
        if self.side != Side::Sidecar {
            return Err(StreamViolation::WrongSide(Kind::Open));
        }
        if self.counted() >= MAX_STREAMS {
            return Err(StreamViolation::LocalTooMany);
        }
        let next = self.next_id();
        if next > u64::from(LAST_ID) {
            out.push(Out::IdsUsedUp);
            return Ok(());
        }
        let s = next as u32;
        self.highest = s;
        self.open.insert(s, Stream::new());
        out.push(Out::Send(Frame::empty(s, Kind::Open)));
        Ok(())
    }

    fn local_data(
        &mut self,
        s: u32,
        bytes: Vec<u8>,
        out: &mut Vec<Out>,
    ) -> Result<(), StreamViolation> {
        let Some(st) = self.open.get_mut(&s) else {
            return Ok(());
        };
        if bytes.is_empty() {
            return Ok(());
        }
        if st.local_fin {
            return Err(StreamViolation::DataAfterFin(s));
        }
        let len = u32::try_from(bytes.len()).unwrap_or(u32::MAX);
        if len > st.send_credit {
            return Err(StreamViolation::OverCredit(s));
        }
        st.send_credit -= len;
        if bytes.len() <= MAX_DATA {
            out.push(Out::Send(Frame::data(s, bytes)));
        } else {
            for chunk in bytes.chunks(MAX_DATA) {
                out.push(Out::Send(Frame::data(s, chunk.to_vec())));
            }
        }
        Ok(())
    }

    fn local_eof(&mut self, s: u32, out: &mut Vec<Out>) {
        let Some(st) = self.open.get_mut(&s) else {
            return;
        };
        if st.local_fin {
            return;
        }
        st.local_fin = true;
        out.push(Out::Send(Frame::empty(s, Kind::Fin)));
        if st.peer_fin {
            self.close(s, Some(Kind::Fin), out);
        }
    }

    fn local_drained(&mut self, s: u32, n: u32, out: &mut Vec<Out>) {
        let Some(st) = self.open.get_mut(&s) else {
            return;
        };
        st.queued = st.queued.saturating_sub(n);
        if st.peer_fin {
            // the peer sends no more on it
            return;
        }
        st.uncredited = st.uncredited.saturating_add(n);
        if st.uncredited > 0 && (st.queued == 0 || st.uncredited >= CREDIT_AT) {
            let n = st.uncredited;
            st.uncredited = 0;
            st.recv_credit = st.recv_credit.saturating_add(n);
            out.push(Out::Send(Frame::credit(s, n)));
        }
    }

    fn local_reset(&mut self, s: u32, out: &mut Vec<Out>) {
        if !self.open.contains_key(&s) {
            return;
        }
        out.push(Out::Send(Frame::empty(s, Kind::Rst)));
        out.push(Out::Drop { stream: s });
        self.close(s, Some(Kind::Rst), out);
    }

    fn wrote(&mut self, s: u32, kind: Kind, out: &mut Vec<Out>) {
        let before = self.counted();
        if kind == Kind::Rst && self.refusing.remove(&s) {
            return;
        }
        if kind == Kind::Fin
            && let Some(st) = self.open.get_mut(&s)
        {
            st.fin_written = true;
            return;
        }
        if self.closing.get(&s) == Some(&kind) {
            self.closing.remove(&s);
            self.room(before, out);
        }
    }
}

#[cfg(test)]
impl Mux {
    /// Test only: as if `highest` were the last id opened, so the end of the id space is reachable.
    pub(crate) fn set_highest(&mut self, highest: u32) {
        self.highest = highest;
    }
}

#[cfg(test)]
mod tests;
