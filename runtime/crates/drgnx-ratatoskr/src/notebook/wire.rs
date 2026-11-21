//! The Jupyter wire protocol: one message as ZeroMQ frames (docs: jupyter-client's "Messaging in Jupyter").
//!
//! ```text
//! idents… | <IDS|MSG> | hmac | header | parent_header | metadata | content | buffers…
//! ```
//!
//! The signature is the HMAC-SHA256 (hex) of the four JSON frames **as received**, keyed by the connection file's key; it is
//! checked with `Mac::verify_slice` (constant time) after the hex is decoded, never compared as strings. Every size is capped
//! before a frame is parsed, so a kernel cannot make the hub allocate or recurse without bound.

use hmac::{Hmac, KeyInit, Mac};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::Sha256;

/// The frame between the routing identities and the signature.
pub const DELIM: &[u8] = b"<IDS|MSG>";
/// The largest header, parent header or metadata frame.
pub const MAX_SMALL: usize = 1 << 20;
/// The largest content frame (a 5 MB image is base64 in it).
pub const MAX_CONTENT: usize = 16 << 20;
/// Binary buffers: how many, and how many bytes in all.
pub const MAX_BUFFERS: usize = 64;
pub const MAX_BUFFER_BYTES: usize = 16 << 20;
/// A header's string fields (msg_id, msg_type, ...): none is longer.
pub const MAX_FIELD: usize = 4096;
/// One routing identity (ZeroMQ's own limit).
pub const MAX_IDENT: usize = 255;
/// Routing identities before the delimiter.
pub const MAX_IDENTS: usize = 8;

/// A connection's secret. It prints nothing, and leaves this module only as the connection file's text.
#[derive(Clone)]
pub struct Key(Vec<u8>);

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The 32 bytes of an HMAC-SHA256 signature written as 64 hex characters: a signature of any other length is refused before anything is
/// decoded or allocated.
pub(crate) fn sig_bytes(sig: &[u8]) -> Option<Vec<u8>> {
    #[cfg(test)]
    SIG_CHECKS.with(|c| c.set(c.get() + 1));
    if sig.len() != 64 {
        return None;
    }
    unhex(sig)
}

#[cfg(test)]
thread_local! {
    /// How many signatures were checked for length on this thread (a test pins that `decode` is the one that does).
    pub(crate) static SIG_CHECKS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

fn unhex(s: &[u8]) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    let d = |c: u8| (c as char).to_digit(16).map(|v| v as u8);
    s.chunks(2)
        .map(|p| Some(d(p[0])? << 4 | d(p[1])?))
        .collect()
}

impl std::fmt::Debug for Key {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Key(..)")
    }
}

impl Key {
    /// 32 bytes from the operating system's random generator, as 64 hex characters (the signing key is that text, as the
    /// protocol's kernels read it).
    pub fn generate() -> Result<Key, String> {
        let mut b = [0u8; 32];
        getrandom::fill(&mut b).map_err(|e| format!("no random bytes for a kernel key: {e}"))?;
        Ok(Key(hex(&b).into_bytes()))
    }

    /// The key as the connection file holds it (the only way out).
    pub fn to_connection_file(&self) -> String {
        String::from_utf8_lossy(&self.0).into_owned()
    }

    /// A key from the connection file's text; hex only, and never empty (an empty key switches signing off).
    pub fn from_connection_file(text: &str) -> Option<Key> {
        let ok = !text.is_empty()
            && text.len().is_multiple_of(2)
            && text.bytes().all(|c| c.is_ascii_hexdigit());
        ok.then(|| Key(text.as_bytes().to_vec()))
    }

    fn mac(&self) -> Hmac<Sha256> {
        Hmac::<Sha256>::new_from_slice(&self.0).expect("HMAC takes a key of any length")
    }
}

/// A message header (extra fields are ignored).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Header {
    pub msg_id: String,
    #[serde(default)]
    pub session: String,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub date: String,
    pub msg_type: String,
    #[serde(default)]
    pub version: String,
}

/// One message.
#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    pub idents: Vec<Vec<u8>>,
    pub header: Header,
    pub parent: Value,
    pub metadata: Value,
    pub content: Value,
    pub buffers: Vec<Vec<u8>>,
}

static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

impl Message {
    /// A request for the kernel: a fresh `msg_id` in SESSION, the protocol version the codec was written against.
    pub fn request(session: &str, msg_type: &str, content: Value) -> Message {
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        Message {
            idents: Vec::new(),
            header: Header {
                msg_id: format!("{session}-{n}"),
                session: session.to_string(),
                username: "drgnx".into(),
                date: crate::log::rfc3339(crate::clock::wall_secs() as u64),
                msg_type: msg_type.to_string(),
                version: "5.3".into(),
            },
            parent: Value::Object(Default::default()),
            metadata: Value::Object(Default::default()),
            content,
            buffers: Vec::new(),
        }
    }
}

/// Why frames are not a message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WireError {
    NoDelimiter,
    TooFewFrames,
    TooManyFrames,
    BadSignature,
    TooLarge(&'static str),
    Json(&'static str),
}

fn dump(v: &Value) -> Vec<u8> {
    serde_json::to_vec(v).expect("a JSON value serializes")
}

/// MESSAGE as the frames to send, signed with KEY.
pub fn encode(key: &Key, m: &Message) -> Vec<Vec<u8>> {
    let parts = [
        serde_json::to_vec(&m.header).expect("a header serializes"),
        dump(&m.parent),
        dump(&m.metadata),
        dump(&m.content),
    ];
    let mut mac = key.mac();
    for p in &parts {
        mac.update(p);
    }
    let sig = hex(&mac.finalize().into_bytes());
    let mut out: Vec<Vec<u8>> = m.idents.clone();
    out.push(DELIM.to_vec());
    out.push(sig.into_bytes());
    out.extend(parts);
    out.extend(m.buffers.iter().cloned());
    out
}

fn object(part: &[u8], what: &'static str) -> Result<Value, WireError> {
    match serde_json::from_slice::<Value>(part) {
        Ok(v) if v.is_object() => Ok(v),
        _ => Err(WireError::Json(what)),
    }
}

/// FRAMES (as received) as a message: sizes first, then the signature, then the JSON.
pub fn decode(key: &Key, frames: &[Vec<u8>]) -> Result<Message, WireError> {
    if frames.is_empty() {
        return Err(WireError::TooFewFrames);
    }
    let at = frames
        .iter()
        .position(|f| f == DELIM)
        .ok_or(WireError::NoDelimiter)?;
    if at > MAX_IDENTS {
        return Err(WireError::TooManyFrames);
    }
    if frames[..at].iter().any(|f| f.len() > MAX_IDENT) {
        return Err(WireError::TooLarge("identity"));
    }
    let rest = &frames[at + 1..];
    if rest.len() < 5 {
        return Err(WireError::TooFewFrames);
    }
    let (sig, header, parent, meta, content, buffers) =
        (&rest[0], &rest[1], &rest[2], &rest[3], &rest[4], &rest[5..]);
    if header.len() > MAX_SMALL {
        return Err(WireError::TooLarge("header"));
    }
    if parent.len() > MAX_SMALL {
        return Err(WireError::TooLarge("parent"));
    }
    if meta.len() > MAX_SMALL {
        return Err(WireError::TooLarge("metadata"));
    }
    if content.len() > MAX_CONTENT {
        return Err(WireError::TooLarge("content"));
    }
    if buffers.len() > MAX_BUFFERS || buffers.iter().map(Vec::len).sum::<usize>() > MAX_BUFFER_BYTES
    {
        return Err(WireError::TooLarge("buffers"));
    }
    let want = sig_bytes(sig).ok_or(WireError::BadSignature)?;
    let mut mac = key.mac();
    for p in [header, parent, meta, content] {
        mac.update(p);
    }
    mac.verify_slice(&want)
        .map_err(|_| WireError::BadSignature)?;
    let header: Header = serde_json::from_slice(header).map_err(|_| WireError::Json("header"))?;
    let h = &header;
    if [
        &h.msg_id,
        &h.session,
        &h.username,
        &h.date,
        &h.msg_type,
        &h.version,
    ]
    .iter()
    .any(|f| f.len() > MAX_FIELD)
    {
        return Err(WireError::Json("header"));
    }
    Ok(Message {
        idents: frames[..at].to_vec(),
        header,
        parent: object(parent, "parent")?,
        metadata: object(meta, "metadata")?,
        content: object(content, "content")?,
        buffers: buffers.to_vec(),
    })
}

#[cfg(test)]
mod tests;
