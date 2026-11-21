//! The channel's frames: `u32 stream id (big-endian, high bit 0) | u8 kind | u32 payload length (big-endian) |
//! payload`, and a decoder that joins frames split across reads.
//!
//! The decoder checks what one frame can show on its own: the kind, the length for the kind, the payload's form, the
//! stream id's high bit and parity, and which kinds belong on stream 0. What depends on the channel's state (which
//! streams are open, credit, who may send what) is the relay core's (`mux`).

use std::fmt;
use std::net::{IpAddr, SocketAddr};

/// The largest `DATA` payload.
pub const MAX_DATA: usize = 16_384;
/// The largest control payload (`READY`'s and `EVENT`'s JSON).
pub const MAX_CONTROL: usize = 4_096;
/// The credit window per stream and direction.
pub const WINDOW: u32 = 262_144;
/// The most streams counted at once.
pub const MAX_STREAMS: usize = 64;
/// The header's length: stream id, kind, payload length.
pub const HEADER: usize = 9;
/// An `OPEN`'s whole payload when the stream is a key stream (a connection to the sidecar's `@drgnx-key`); a stream
/// for the proxy's `OPEN` carries nothing. Any other payload is a violation.
pub const KEY_MARK: u8 = 0x4b;

/// A frame's kind, its byte on the wire.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum Kind {
    Ready = 0,
    Open = 1,
    Data = 2,
    Credit = 3,
    Fin = 4,
    Rst = 5,
    Beat = 6,
    Event = 7,
}

impl Kind {
    /// The kind of a byte, if it names one.
    pub fn from_u8(b: u8) -> Option<Kind> {
        Some(match b {
            0 => Kind::Ready,
            1 => Kind::Open,
            2 => Kind::Data,
            3 => Kind::Credit,
            4 => Kind::Fin,
            5 => Kind::Rst,
            6 => Kind::Beat,
            7 => Kind::Event,
            _ => return None,
        })
    }

    /// Whether the kind lives on stream 0.
    fn on_stream_0(self) -> bool {
        matches!(self, Kind::Ready | Kind::Beat | Kind::Event)
    }

    /// Whether a payload of `len` bytes may follow a header of this kind.
    fn allows(self, len: u32) -> bool {
        match self {
            Kind::Data => (1..=MAX_DATA as u32).contains(&len),
            Kind::Credit => len == 4,
            Kind::Ready | Kind::Event => len <= MAX_CONTROL as u32,
            Kind::Open => len <= 1,
            Kind::Fin | Kind::Rst | Kind::Beat => len == 0,
        }
    }
}

/// One frame.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
    pub stream: u32,
    pub kind: Kind,
    pub payload: Vec<u8>,
}

impl Frame {
    /// A frame with no payload (`OPEN`, `FIN`, `RST`, `BEAT`).
    pub fn empty(stream: u32, kind: Kind) -> Frame {
        Frame {
            stream,
            kind,
            payload: Vec::new(),
        }
    }

    /// A key stream's `OPEN`: the payload is [`KEY_MARK`].
    pub fn open_key(stream: u32) -> Frame {
        Frame {
            stream,
            kind: Kind::Open,
            payload: vec![KEY_MARK],
        }
    }

    /// Whether this is a key stream's `OPEN`.
    pub fn is_key_open(&self) -> bool {
        self.kind == Kind::Open && self.payload == [KEY_MARK]
    }

    /// A `DATA` frame.
    pub fn data(stream: u32, bytes: Vec<u8>) -> Frame {
        Frame {
            stream,
            kind: Kind::Data,
            payload: bytes,
        }
    }

    /// A `CREDIT` frame granting `n` more bytes.
    pub fn credit(stream: u32, n: u32) -> Frame {
        Frame {
            stream,
            kind: Kind::Credit,
            payload: n.to_be_bytes().to_vec(),
        }
    }

    /// The sidecar's `READY`, naming the address it bound.
    pub fn ready(listen: SocketAddr) -> Frame {
        Frame {
            stream: 0,
            kind: Kind::Ready,
            payload: Ready { listen }.payload(),
        }
    }

    /// An `EVENT` naming a foreign source.
    pub fn event(source: IpAddr) -> Frame {
        Frame {
            stream: 0,
            kind: Kind::Event,
            payload: ForeignSource(source).payload(),
        }
    }

    /// A `CREDIT` frame's increment (`None` for another kind or a payload that is not four bytes).
    pub fn credit_value(&self) -> Option<u32> {
        match (self.kind, <[u8; 4]>::try_from(self.payload.as_slice())) {
            (Kind::Credit, Ok(b)) => Some(u32::from_be_bytes(b)),
            _ => None,
        }
    }
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadyJson {
    version: u32,
    listen: String,
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct EventJson {
    foreign_source: String,
}

/// `READY`'s payload: `{"version":1,"listen":"<ip:port>"}`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ready {
    pub listen: SocketAddr,
}

impl Ready {
    /// The JSON payload.
    pub fn payload(&self) -> Vec<u8> {
        let json = ReadyJson {
            version: 1,
            listen: self.listen.to_string(),
        };
        serde_json::to_vec(&json).expect("a struct of a number and a string serialises")
    }

    /// Parses a payload: version 1 and an address, nothing else.
    pub fn parse(payload: &[u8]) -> Option<Ready> {
        let json: ReadyJson = serde_json::from_slice(payload).ok()?;
        if json.version != 1 {
            return None;
        }
        Some(Ready {
            listen: json.listen.parse().ok()?,
        })
    }
}

/// `EVENT`'s payload, `{"foreign_source":"<addr>"}`: a connection to the relay came from another address than the
/// job's. It is only ever an address, never passed on as text.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ForeignSource(pub IpAddr);

impl ForeignSource {
    /// The JSON payload.
    pub fn payload(&self) -> Vec<u8> {
        let json = EventJson {
            foreign_source: self.0.to_string(),
        };
        serde_json::to_vec(&json).expect("a struct of a string serialises")
    }

    /// Parses a payload: one field, an address.
    pub fn parse(payload: &[u8]) -> Option<ForeignSource> {
        let json: EventJson = serde_json::from_slice(payload).ok()?;
        Some(ForeignSource(json.foreign_source.parse().ok()?))
    }
}

/// What a frame alone can show is wrong. Any of them closes the channel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Violation {
    /// A kind byte above 7.
    UnknownKind(u8),
    /// A payload length the kind doesn't allow.
    Length { kind: Kind, len: u32 },
    /// A payload of the right length but the wrong form.
    BadPayload(Kind),
    /// A stream id with the high bit set.
    HighBit(u32),
    /// An even stream id other than 0 (only the sidecar opens streams, with odd ids).
    EvenId(u32),
    /// `READY`, `BEAT` or `EVENT` off stream 0, or another kind on it.
    WrongStream(Kind),
}

impl fmt::Display for Violation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Violation::UnknownKind(b) => write!(f, "unknown frame kind {b}"),
            Violation::Length { kind, len } => write!(f, "a {kind:?} frame of {len} bytes"),
            Violation::BadPayload(kind) => write!(f, "a malformed {kind:?} payload"),
            Violation::HighBit(id) => write!(f, "stream id {id:#x} has the high bit set"),
            Violation::EvenId(id) => write!(f, "even stream id {id}"),
            Violation::WrongStream(kind) => write!(f, "a {kind:?} frame on the wrong stream"),
        }
    }
}

impl std::error::Error for Violation {}

/// Appends `f`'s bytes to `out`.
pub fn encode(f: &Frame, out: &mut Vec<u8>) {
    out.reserve(HEADER + f.payload.len());
    out.extend_from_slice(&f.stream.to_be_bytes());
    out.push(f.kind as u8);
    out.extend_from_slice(&(f.payload.len() as u32).to_be_bytes());
    out.extend_from_slice(&f.payload);
}

/// Checks a complete header: its stream id, kind and length, in that order.
fn header(h: &[u8]) -> Result<(u32, Kind, u32), Violation> {
    let stream = u32::from_be_bytes([h[0], h[1], h[2], h[3]]);
    let len = u32::from_be_bytes([h[5], h[6], h[7], h[8]]);
    if stream & 0x8000_0000 != 0 {
        return Err(Violation::HighBit(stream));
    }
    let kind = Kind::from_u8(h[4]).ok_or(Violation::UnknownKind(h[4]))?;
    if stream != 0 && stream.is_multiple_of(2) {
        return Err(Violation::EvenId(stream));
    }
    if kind.on_stream_0() != (stream == 0) {
        return Err(Violation::WrongStream(kind));
    }
    if !kind.allows(len) {
        return Err(Violation::Length { kind, len });
    }
    Ok((stream, kind, len))
}

/// Checks a complete frame's payload form.
fn payload_ok(kind: Kind, payload: &[u8]) -> bool {
    match kind {
        Kind::Credit => payload != [0, 0, 0, 0],
        Kind::Ready => Ready::parse(payload).is_some(),
        Kind::Event => ForeignSource::parse(payload).is_some(),
        Kind::Open => payload.is_empty() || payload == [KEY_MARK],
        Kind::Data | Kind::Fin | Kind::Rst | Kind::Beat => true,
    }
}

/// Joins bytes into frames. A frame split across pushes waits; it never holds more than one frame's bytes
/// (`HEADER + MAX_DATA`).
#[derive(Clone, Debug, Default)]
pub struct Decoder {
    buf: Vec<u8>,
}

impl Decoder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Decodes what `bytes` completes. After a violation the decoder is spent: the channel closes.
    pub fn push(&mut self, mut bytes: &[u8]) -> Result<Vec<Frame>, Violation> {
        let mut out = Vec::new();
        loop {
            // the header first, so its length is judged before any payload is held
            if self.buf.len() < HEADER {
                let take = (HEADER - self.buf.len()).min(bytes.len());
                self.buf.extend_from_slice(&bytes[..take]);
                bytes = &bytes[take..];
                if self.buf.len() < HEADER {
                    return Ok(out);
                }
            }
            let (stream, kind, len) = header(&self.buf[..HEADER])?;
            let total = HEADER + len as usize;
            let take = (total - self.buf.len()).min(bytes.len());
            self.buf.extend_from_slice(&bytes[..take]);
            bytes = &bytes[take..];
            if self.buf.len() < total {
                return Ok(out);
            }
            let payload = self.buf[HEADER..].to_vec();
            zeroize::Zeroize::zeroize(&mut self.buf);
            if !payload_ok(kind, &payload) {
                return Err(Violation::BadPayload(kind));
            }
            out.push(Frame {
                stream,
                kind,
                payload,
            });
        }
    }

    /// The bytes held of a frame not yet complete (0 between frames).
    pub fn buffered(&self) -> usize {
        self.buf.len()
    }
}

#[cfg(test)]
mod tests;
