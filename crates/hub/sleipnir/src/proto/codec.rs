//! The wire: one JSON line per frame. A frame with bytes (`log`, `blob`, `bundle`) adds `"len": N` to its line, and
//! its N bytes follow the line as one chunk: a 4-byte big-endian length, then the bytes, at most [`MAX_CHUNK`]. Any
//! frame may carry a chunk, so a side skips the bytes of a frame it doesn't know and stays in step.

use super::frame::{CodecWrites, Frame};
use serde::Deserialize;
use std::fmt;
use std::io::{self, BufRead, Write};
use zeroize::Zeroize;

/// The most bytes one chunk carries (1 MiB).
pub const MAX_CHUNK: usize = 1 << 20;
/// The longest JSON line read (a `finished` frame carries a whole `result.json`: reports are 16 MiB at most).
pub const MAX_LINE: usize = 16 << 20;

/// Why a frame couldn't be read or written. The reader can't go on after any of them.
#[derive(Debug)]
pub enum CodecError {
    Io(io::Error),
    /// A line or chunk longer than its limit; nothing of it was kept.
    TooLong {
        what: &'static str,
        len: usize,
        max: usize,
    },
    /// A line that isn't a frame.
    Json(serde_json::Error),
}

impl fmt::Display for CodecError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CodecError::Io(e) => write!(f, "{e}"),
            CodecError::TooLong { what, len, max } => {
                write!(f, "a {what} of {len} bytes is over the {max}-byte limit")
            }
            CodecError::Json(e) => write!(f, "not a frame: {e}"),
        }
    }
}

impl std::error::Error for CodecError {}

impl From<io::Error> for CodecError {
    fn from(e: io::Error) -> CodecError {
        CodecError::Io(e)
    }
}

/// The chunk length a line announces; every other field is the frame's.
#[derive(Deserialize)]
struct Header {
    #[serde(default)]
    len: Option<u64>,
}

/// Reads frames from a channel.
pub struct FrameReader<R> {
    inner: R,
    line: Vec<u8>,
}

impl<R: BufRead> FrameReader<R> {
    pub fn new(inner: R) -> FrameReader<R> {
        FrameReader {
            inner,
            line: Vec::new(),
        }
    }

    /// The next frame; `None` at the channel's end between frames. An end inside a frame is an error.
    pub fn read(&mut self) -> Result<Option<Frame>, CodecError> {
        loop {
            if !self.read_line()? {
                return Ok(None);
            }
            // a blank line is a keep-alive a shell or a person may type: skip it
            if self.line.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            let header: Header = serde_json::from_slice(&self.line).map_err(CodecError::Json)?;
            let parsed = serde_json::from_slice::<Frame>(&self.line);
            if matches!(parsed, Ok(Frame::Key(_))) {
                // the line held the value: it doesn't stay in our buffer
                self.line.zeroize();
            }
            let mut frame = parsed.map_err(CodecError::Json)?;
            if header.len.is_some() {
                let bytes = self.read_chunk()?;
                if let Some(p) = frame.payload_mut() {
                    *p = bytes;
                }
            }
            return Ok(Some(frame));
        }
    }

    /// One line into `self.line`, without its newline; false at the end with nothing read.
    fn read_line(&mut self) -> Result<bool, CodecError> {
        self.line.clear();
        loop {
            let buf = match self.inner.fill_buf() {
                Ok(b) => b,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e.into()),
            };
            if buf.is_empty() {
                return if self.line.is_empty() {
                    Ok(false)
                } else {
                    Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "the channel ended inside a frame",
                    )
                    .into())
                };
            }
            let (part, done) = match buf.iter().position(|&b| b == b'\n') {
                Some(i) => (&buf[..i], i + 1),
                None => (buf, buf.len()),
            };
            if self.line.len() + part.len() > MAX_LINE {
                let len = self.line.len() + part.len();
                self.line.clear();
                return Err(CodecError::TooLong {
                    what: "frame line",
                    len,
                    max: MAX_LINE,
                });
            }
            self.line.extend_from_slice(part);
            let ended = done > part.len();
            self.inner.consume(done);
            if ended {
                return Ok(true);
            }
        }
    }

    fn read_chunk(&mut self) -> Result<Vec<u8>, CodecError> {
        let mut len = [0u8; 4];
        self.inner.read_exact(&mut len)?;
        let len = u32::from_be_bytes(len) as usize;
        if len > MAX_CHUNK {
            return Err(CodecError::TooLong {
                what: "chunk",
                len,
                max: MAX_CHUNK,
            });
        }
        let mut bytes = vec![0u8; len];
        self.inner.read_exact(&mut bytes)?;
        Ok(bytes)
    }
}

/// Writes frames to a channel, each whole in one write and flushed.
pub struct FrameWriter<W> {
    inner: W,
    buf: Vec<u8>,
}

impl<W: Write> FrameWriter<W> {
    pub fn new(inner: W) -> FrameWriter<W> {
        FrameWriter {
            inner,
            buf: Vec::new(),
        }
    }

    pub fn write(&mut self, frame: &Frame) -> Result<(), CodecError> {
        let payload = frame.payload();
        if let Some(p) = payload
            && p.len() > MAX_CHUNK
        {
            return Err(CodecError::TooLong {
                what: "chunk",
                len: p.len(),
                max: MAX_CHUNK,
            });
        }
        self.buf.clear();
        {
            let _writes = CodecWrites::begin();
            serde_json::to_writer(&mut self.buf, frame).map_err(CodecError::Json)?;
        }
        if let Some(p) = payload {
            // every frame is a JSON object with its tag: the length joins it as one more field
            let close = self.buf.pop();
            debug_assert_eq!(close, Some(b'}'));
            write!(self.buf, ",\"len\":{}}}", p.len())?;
            self.buf.push(b'\n');
            self.buf.extend_from_slice(&(p.len() as u32).to_be_bytes());
            self.buf.extend_from_slice(p);
        } else {
            self.buf.push(b'\n');
        }
        let sent = self
            .inner
            .write_all(&self.buf)
            .and_then(|()| self.inner.flush());
        if matches!(frame, Frame::Key(_)) {
            // the line held the value: it doesn't stay in our buffer
            self.buf.zeroize();
        }
        sent?;
        Ok(())
    }

    /// The channel, to close it.
    pub fn into_inner(self) -> W {
        self.inner
    }
}
