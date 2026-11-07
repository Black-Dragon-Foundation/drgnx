//! Arbitrary sequences of the relay channel's inputs into both ends' `Mux` and `Pending`, joined by two in-order
//! pipes: each end's local side (opens, bytes within the credit, ends, resets, drains), each writer taking one frame,
//! each reader stepping one, and arbitrary frames injected as if the peer sent them. No panic (a `LocalTooMany` is a
//! returned error like any violation, which ends the run); every `Deliver` stays within what the end credited, never
//! more than `WINDOW` queued on a stream; and `Pending::next` never yields a `FIN` before its stream's last `DATA`, or
//! an `OPEN` out of id order.
#![no_main]

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use drgnx_px::frame::{Decoder, Frame, Kind, MAX_DATA, WINDOW};
use drgnx_px::mux::{In, Mux, Out, Side};
use drgnx_px::pending::Pending;
use libfuzzer_sys::fuzz_target;

struct End {
    mux: Mux,
    pending: Pending,
    open: BTreeSet<u32>,
    /// Delivered, not yet drained.
    queued: BTreeMap<u32, u64>,
    /// Delivered, not yet given back by a `CREDIT` this end's writer took.
    owed: BTreeMap<u32, u64>,
    fin_taken: BTreeSet<u32>,
    last_open: u32,
}

impl End {
    fn new(side: Side) -> End {
        let mut pending = Pending::new(side);
        if side == Side::Sidecar {
            pending.push(Frame::ready("127.0.0.1:3128".parse().expect("an address")));
        }
        End {
            mux: Mux::new(side),
            pending,
            open: BTreeSet::new(),
            queued: BTreeMap::new(),
            owed: BTreeMap::new(),
            fin_taken: BTreeSet::new(),
            last_open: 0,
        }
    }

    /// False once the channel broke a rule (the run ends there).
    fn step(&mut self, ev: In) -> bool {
        let Ok(outs) = self.mux.step(ev) else {
            return false;
        };
        for o in outs {
            match o {
                Out::Send(f) => {
                    if f.kind == Kind::Open {
                        self.open.insert(f.stream);
                    }
                    self.pending.push(f);
                }
                Out::NewStream { stream } => {
                    self.open.insert(stream);
                }
                Out::Deliver { stream, bytes } => {
                    let n = bytes.len() as u64;
                    let q = self.queued.entry(stream).or_default();
                    *q += n;
                    assert!(*q <= u64::from(WINDOW), "more than WINDOW queued on {stream}");
                    let o = self.owed.entry(stream).or_default();
                    *o += n;
                    assert!(*o <= u64::from(WINDOW), "a Deliver past the credit on {stream}");
                }
                Out::Drop { stream } => {
                    self.open.remove(&stream);
                    self.queued.remove(&stream);
                    self.owed.remove(&stream);
                }
                _ => {}
            }
        }
        true
    }

    fn pick(&self, b: u8) -> Option<u32> {
        if self.open.is_empty() {
            return None;
        }
        self.open.iter().nth(usize::from(b) % self.open.len()).copied()
    }

    /// The local side on the stream byte `b` picks: bytes (1, sized by `n`, within the credit), its end (2), a reset
    /// (3), or a drain of what is queued (4).
    fn local(&mut self, op: u8, b: u8, n: u8) -> bool {
        let Some(stream) = self.pick(b) else {
            return true;
        };
        match op {
            1 => {
                let credit = self.mux.credit(stream) as usize;
                let len = (usize::from(n) + 1) * 64;
                let len = len.min(credit).min(MAX_DATA);
                if len == 0 {
                    return true;
                }
                self.step(In::LocalData {
                    stream,
                    bytes: vec![n; len],
                })
            }
            2 => self.step(In::LocalEof { stream }),
            3 => self.step(In::LocalReset { stream }),
            _ => {
                let q = self.queued.insert(stream, 0).unwrap_or(0);
                if q == 0 {
                    return true;
                }
                self.step(In::LocalDrained {
                    stream,
                    n: q as u32,
                })
            }
        }
    }

    /// The writer takes one frame onto `pipe`, checking the order it leaves in.
    fn take(&mut self, pipe: &mut VecDeque<Frame>) -> bool {
        let Some(f) = self.pending.next() else {
            return true;
        };
        match f.kind {
            Kind::Data => assert!(
                !self.fin_taken.contains(&f.stream),
                "DATA {} after its FIN",
                f.stream
            ),
            Kind::Fin => {
                self.fin_taken.insert(f.stream);
            }
            Kind::Open => {
                let want = if self.last_open == 0 { 1 } else { self.last_open + 2 };
                assert_eq!(f.stream, want, "an OPEN out of id order");
                self.last_open = f.stream;
            }
            Kind::Credit => {
                if let (Some(n), Some(o)) = (f.credit_value(), self.owed.get_mut(&f.stream)) {
                    *o = o.saturating_sub(u64::from(n));
                }
            }
            _ => {}
        }
        let ok = if matches!(f.kind, Kind::Fin | Kind::Rst) {
            self.step(In::Wrote {
                stream: f.stream,
                kind: f.kind,
            })
        } else {
            true
        };
        pipe.push_back(f);
        ok
    }
}

/// A frame from the fuzzer's bytes, if the codec takes it.
fn injected(bytes: &[u8]) -> Vec<Frame> {
    Decoder::new().push(bytes).unwrap_or_default()
}

fuzz_target!(|data: &[u8]| {
    let mut s = End::new(Side::Sidecar);
    let mut o = End::new(Side::Owner);
    let (mut s2o, mut o2s) = (VecDeque::new(), VecDeque::new());
    let mut i = 0;
    let byte = |i: &mut usize| -> u8 {
        let b = data.get(*i).copied().unwrap_or(0);
        *i += 1;
        b
    };
    while i < data.len() {
        let op = byte(&mut i) % 16;
        let ok = match op {
            // the sidecar's accept loop opens only below the cap; past it, the returned LocalTooMany ends the run
            0 => s.step(In::LocalOpen),
            1..=4 => {
                let (b, n) = (byte(&mut i), byte(&mut i));
                s.local(op, b, n)
            }
            5..=8 => {
                let (b, n) = (byte(&mut i), byte(&mut i));
                o.local(op - 4, b, n)
            }
            9 => s.take(&mut s2o),
            10 => o.take(&mut o2s),
            11 => match s2o.pop_front() {
                Some(f) => o.step(In::Frame(f)),
                None => true,
            },
            12 => match o2s.pop_front() {
                Some(f) => s.step(In::Frame(f)),
                None => true,
            },
            13 | 14 => {
                // a header and up to 31 payload bytes, as the peer might send them
                let len = usize::from(byte(&mut i) % 32);
                let start = i.min(data.len());
                let end = (i + 9 + len).min(data.len());
                i = end;
                let mut raw = data[start..end].to_vec();
                if raw.len() >= 9 {
                    raw[5..9].copy_from_slice(&(len as u32).to_be_bytes());
                }
                let to = if op == 13 { &mut o } else { &mut s };
                injected(&raw).into_iter().all(|f| to.step(In::Frame(f)))
            }
            _ => true,
        };
        if !ok {
            return;
        }
    }
});
