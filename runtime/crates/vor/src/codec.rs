//! The base protocol's framing: `Content-Length: N\r\n\r\n` and N bytes of JSON.
//!
//! A header block is ASCII lines `Name: value` ending in an empty line; only `Content-Length` is read and the others
//! are skipped, as the protocol allows. A header that never ends (more than [`MAX_HEADER`] bytes), a missing or
//! malformed length, or a body over [`MAX_BODY`] breaks the stream: the decoder returns an error and the connection
//! ends. A body that is not a DAP message (bad JSON, not UTF-8, no `type`) is a [`Frame::Bad`]: the stream goes on.
use crate::message::Message;
use std::io;
use tokio_util::bytes::{Buf, BufMut, BytesMut};
use tokio_util::codec::{Decoder, Encoder};

/// The longest header block read before the stream is called broken.
pub const MAX_HEADER: usize = 8 * 1024;
/// The largest body read (a 100,000-element `variables` page is a few MB).
pub const MAX_BODY: usize = 256 * 1024 * 1024;

/// One decoded frame.
#[derive(Debug)]
pub enum Frame {
    Message(Message),
    /// A frame whose body could not be read as a message, with why.
    Bad(String),
}

/// The codec, for `FramedRead` / `FramedWrite`.
#[derive(Debug, Default)]
pub struct DapCodec {
    /// The body length of a header already read.
    want: Option<usize>,
}

fn broken(msg: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.into())
}

fn header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

fn content_length(head: &[u8]) -> Result<usize, io::Error> {
    let head = std::str::from_utf8(head).map_err(|_| broken("a header that is not UTF-8"))?;
    let mut len = None;
    for line in head.split("\r\n") {
        let Some((name, value)) = line.split_once(':') else {
            return Err(broken(format!("a header line without a colon: {line:?}")));
        };
        if name.trim().eq_ignore_ascii_case("content-length") {
            let n: usize = value
                .trim()
                .parse()
                .map_err(|_| broken(format!("a bad Content-Length: {:?}", value.trim())))?;
            len = Some(n);
        }
    }
    let n = len.ok_or_else(|| broken("a header without Content-Length"))?;
    if n > MAX_BODY {
        return Err(broken(format!("a body of {n} bytes (at most {MAX_BODY})")));
    }
    Ok(n)
}

impl Decoder for DapCodec {
    type Item = Frame;
    type Error = io::Error;

    fn decode(&mut self, buf: &mut BytesMut) -> Result<Option<Frame>, io::Error> {
        let n = match self.want {
            Some(n) => n,
            None => {
                let Some(end) = header_end(buf) else {
                    if buf.len() > MAX_HEADER {
                        return Err(broken("a header longer than 8 KiB"));
                    }
                    return Ok(None);
                };
                let n = content_length(&buf[..end])?;
                buf.advance(end + 4);
                self.want = Some(n);
                n
            }
        };
        if buf.len() < n {
            buf.reserve(n - buf.len());
            return Ok(None);
        }
        self.want = None;
        let body = buf.split_to(n);
        Ok(Some(match serde_json::from_slice::<Message>(&body) {
            Ok(m) => Frame::Message(m),
            Err(e) => Frame::Bad(format!(
                "{e}: {}",
                String::from_utf8_lossy(&body[..n.min(200)])
            )),
        }))
    }
}

impl Encoder<Message> for DapCodec {
    type Error = io::Error;

    fn encode(&mut self, msg: Message, buf: &mut BytesMut) -> Result<(), io::Error> {
        let body = serde_json::to_vec(&msg).map_err(io::Error::other)?;
        buf.reserve(body.len() + 32);
        buf.put_slice(format!("Content-Length: {}\r\n\r\n", body.len()).as_bytes());
        buf.put_slice(&body);
        Ok(())
    }
}
