//! The two byte codecs of the browser path.
//!
//! - `Nul`: Chromium's `--remote-debugging-pipe` messages, each JSON text ended by one NUL byte.
//! - `Frame` and `FrameDecoder`: the socketpair between the hub and the browser host, `[kind u8][len u32 BE][payload]`.
//!   Kind 1 is one CDP message (without its NUL), kind 2 is control JSON. The largest frame is the message limit plus
//!   64 bytes, which the caller passes as the decoder's `max`.
//!
//! Both scan only the bytes that arrive, never the whole pending input again.

use std::fmt;

/// A frame's kind: one CDP message.
pub const KIND_CDP: u8 = 1;
/// A frame's kind: control JSON (`{"op":…}` from the hub, `{"ev":…}` from the host).
pub const KIND_CONTROL: u8 = 2;
/// A frame's header: the kind and the payload's length.
pub const HEADER_LEN: usize = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodecError {
    /// A NUL-delimited message over `max` bytes. It is dropped up to its NUL, and the next message reads as usual.
    Overlong { max: usize },
    /// A message to encode for the pipe has a NUL in it, which would cut it in two on Chromium's side.
    NulInMessage,
    /// A frame's header names a payload over `max` bytes. The stream cannot resync, so the decoder stays failed.
    FrameTooLarge { len: usize, max: usize },
}

impl fmt::Display for CodecError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CodecError::Overlong { max } => write!(f, "a pipe message over {max} bytes"),
            CodecError::NulInMessage => write!(f, "a NUL inside a pipe message"),
            CodecError::FrameTooLarge { len, max } => {
                write!(f, "a frame of {len} bytes, over the limit of {max}")
            }
        }
    }
}

impl std::error::Error for CodecError {}

/// A splitter for NUL-delimited messages with a size limit.
#[derive(Debug)]
pub struct Nul {
    max: usize,
    buf: Vec<u8>,
    /// Inside an overlong message: drop bytes up to the next NUL.
    skipping: bool,
}

impl Nul {
    pub fn new(max: usize) -> Nul {
        Nul {
            max,
            buf: Vec::new(),
            skipping: false,
        }
    }

    /// `msg` with its NUL, refused when `msg` holds a NUL itself.
    pub fn encode(msg: &[u8]) -> Result<Vec<u8>, CodecError> {
        if msg.contains(&0) {
            return Err(CodecError::NulInMessage);
        }
        let mut out = Vec::with_capacity(msg.len() + 1);
        out.extend_from_slice(msg);
        out.push(0);
        Ok(out)
    }

    /// The messages `data` completes, in order, with one `Overlong` in the place of each message over the limit.
    /// Empty messages (two NULs in a row) are skipped.
    pub fn push(&mut self, mut data: &[u8]) -> Vec<Result<Vec<u8>, CodecError>> {
        let mut out = Vec::new();
        while !data.is_empty() {
            let (piece, ends) = match data.iter().position(|&b| b == 0) {
                Some(i) => {
                    let piece = &data[..i];
                    data = &data[i + 1..];
                    (piece, true)
                }
                None => {
                    let piece = data;
                    data = &[];
                    (piece, false)
                }
            };
            if self.skipping {
                self.skipping = !ends;
                continue;
            }
            if self.buf.len() + piece.len() > self.max {
                out.push(Err(CodecError::Overlong { max: self.max }));
                self.buf = Vec::new();
                self.skipping = !ends;
                continue;
            }
            self.buf.extend_from_slice(piece);
            if ends && !self.buf.is_empty() {
                out.push(Ok(std::mem::take(&mut self.buf)));
            }
        }
        out
    }
}

/// One frame between the hub and the browser host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub kind: u8,
    pub payload: Vec<u8>,
}

impl Frame {
    /// The frame's bytes. `payload` is at most the message limit plus 64 bytes, far below `u32::MAX`.
    pub fn encode(kind: u8, payload: &[u8]) -> Vec<u8> {
        let len = u32::try_from(payload.len()).expect("a frame's payload fits a u32 length");
        let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
        out.push(kind);
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(payload);
        out
    }
}

/// A reader of frames from a byte stream.
#[derive(Debug)]
pub struct FrameDecoder {
    max: usize,
    buf: Vec<u8>,
    failed: Option<CodecError>,
}

impl FrameDecoder {
    pub fn new(max: usize) -> FrameDecoder {
        FrameDecoder {
            max,
            buf: Vec::new(),
            failed: None,
        }
    }

    /// The frames `data` completes, in order. A header over the limit fails the decoder at once (before its payload
    /// is buffered), and every later call returns the same error.
    pub fn push(&mut self, data: &[u8]) -> Result<Vec<Frame>, CodecError> {
        if let Some(e) = &self.failed {
            return Err(e.clone());
        }
        self.buf.extend_from_slice(data);
        let mut out = Vec::new();
        let mut at = 0;
        while self.buf.len() - at >= HEADER_LEN {
            let h = &self.buf[at..at + HEADER_LEN];
            let len = u32::from_be_bytes([h[1], h[2], h[3], h[4]]) as usize;
            if len > self.max {
                let e = CodecError::FrameTooLarge { len, max: self.max };
                self.failed = Some(e.clone());
                self.buf = Vec::new();
                return Err(e);
            }
            if self.buf.len() - at - HEADER_LEN < len {
                break;
            }
            let start = at + HEADER_LEN;
            out.push(Frame {
                kind: h[0],
                payload: self.buf[start..start + len].to_vec(),
            });
            at = start + len;
        }
        self.buf.drain(..at);
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn oks(v: Vec<Result<Vec<u8>, CodecError>>) -> Vec<Vec<u8>> {
        v.into_iter().map(Result::unwrap).collect()
    }

    #[test]
    fn nul_split_in_pieces() {
        let stream = b"{\"id\":1}\0{\"id\":2,\"method\":\"x\"}\0\0{\"id\":3}\0";
        let want: Vec<Vec<u8>> = vec![
            b"{\"id\":1}".to_vec(),
            b"{\"id\":2,\"method\":\"x\"}".to_vec(),
            b"{\"id\":3}".to_vec(),
        ];
        // whole, byte by byte, and in every two-piece cut
        assert_eq!(oks(Nul::new(64).push(stream)), want);
        let mut nul = Nul::new(64);
        let mut got = Vec::new();
        for b in stream {
            got.extend(oks(nul.push(std::slice::from_ref(b))));
        }
        assert_eq!(got, want);
        for cut in 0..=stream.len() {
            let mut nul = Nul::new(64);
            let mut got = oks(nul.push(&stream[..cut]));
            got.extend(oks(nul.push(&stream[cut..])));
            assert_eq!(got, want, "cut at {cut}");
        }
        // a message without its NUL yet is held
        let mut nul = Nul::new(64);
        assert!(nul.push(b"{\"id\":4").is_empty());
        assert_eq!(oks(nul.push(b"}\0")), vec![b"{\"id\":4}".to_vec()]);
        // exactly the limit passes
        assert_eq!(
            oks(Nul::new(8).push(b"12345678\0")),
            vec![b"12345678".to_vec()]
        );
    }

    #[test]
    fn nul_overlong_resyncs() {
        // over the limit in one piece, then the next message is whole
        let mut nul = Nul::new(8);
        assert_eq!(
            nul.push(b"123456789\0ok\0"),
            vec![Err(CodecError::Overlong { max: 8 }), Ok(b"ok".to_vec())]
        );
        // over the limit across pieces: one error, the rest dropped up to the NUL, then the next message
        let mut nul = Nul::new(8);
        assert!(nul.push(b"12345").is_empty());
        assert_eq!(
            nul.push(b"6789"),
            vec![Err(CodecError::Overlong { max: 8 })]
        );
        assert!(nul.push(b"more and more").is_empty());
        assert_eq!(nul.push(b"tail\0next\0"), vec![Ok(b"next".to_vec())]);
        // encoding refuses a NUL inside
        assert_eq!(Nul::encode(b"a\0b"), Err(CodecError::NulInMessage));
        assert_eq!(Nul::encode(b"ab").unwrap(), b"ab\0".to_vec());
    }

    #[test]
    fn frame_roundtrip() {
        let frames = [
            Frame {
                kind: KIND_CDP,
                payload: br#"{"id":1,"method":"Browser.getVersion"}"#.to_vec(),
            },
            Frame {
                kind: KIND_CONTROL,
                payload: br#"{"op":"start"}"#.to_vec(),
            },
            Frame {
                kind: KIND_CDP,
                payload: Vec::new(),
            },
            Frame {
                kind: KIND_CDP,
                payload: vec![0u8; 300],
            },
        ];
        let stream: Vec<u8> = frames
            .iter()
            .flat_map(|f| Frame::encode(f.kind, &f.payload))
            .collect();
        assert_eq!(&stream[..HEADER_LEN], &[1, 0, 0, 0, 38]);
        assert_eq!(
            FrameDecoder::new(300).push(&stream).unwrap(),
            frames.to_vec()
        );
        for cut in 0..=stream.len() {
            let mut d = FrameDecoder::new(300);
            let mut got = d.push(&stream[..cut]).unwrap();
            got.extend(d.push(&stream[cut..]).unwrap());
            assert_eq!(got, frames.to_vec(), "cut at {cut}");
        }
        let mut d = FrameDecoder::new(300);
        let mut got = Vec::new();
        for b in &stream {
            got.extend(d.push(std::slice::from_ref(b)).unwrap());
        }
        assert_eq!(got, frames.to_vec());
    }

    #[test]
    fn frame_over_max() {
        let mut d = FrameDecoder::new(16);
        assert_eq!(
            d.push(&Frame::encode(KIND_CDP, &[b'x'; 16])).unwrap().len(),
            1
        );
        // the header alone fails it, before any payload arrives
        let big = Frame::encode(KIND_CDP, &[b'x'; 17]);
        assert_eq!(
            d.push(&big[..HEADER_LEN]),
            Err(CodecError::FrameTooLarge { len: 17, max: 16 })
        );
        // and it stays failed
        assert_eq!(
            d.push(&Frame::encode(KIND_CDP, b"ok")),
            Err(CodecError::FrameTooLarge { len: 17, max: 16 })
        );
    }
}
