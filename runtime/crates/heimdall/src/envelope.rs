//! One CDP message's envelope, borrowed from its bytes.
//!
//! The broker reads only what it routes by: `id`, `method`, `sessionId`, and for the `Target` domain the `targetId`
//! and `sessionId` params. `params`, `result` and `error` stay `RawValue`s, so a 20 MiB screenshot is never decoded
//! or re-encoded.
//!
//! Strict on purpose, so the broker and Chromium never read one message two ways: the message must be one JSON
//! object; a known key twice is an error; the strings the broker routes by must be plain (a string with an escape is
//! an error, never decoded); `id` is a whole number from 0 up; a message with `method` has neither `result` nor
//! `error`.

use std::fmt;

use serde::Deserialize;
use serde_json::value::RawValue;

/// The envelope of one CDP message. Every `&str` and `RawValue` borrows from the message's bytes.
#[derive(Debug, Clone, Copy)]
pub struct Envelope<'a> {
    pub id: Option<u64>,
    pub method: Option<&'a str>,
    pub session_id: Option<&'a str>,
    pub params: Option<&'a RawValue>,
    /// A reply's `result` (a reply has `result` or `error`).
    pub result: Option<&'a RawValue>,
    pub error: Option<&'a RawValue>,
    /// `result` or `error` is present.
    pub is_reply: bool,
    /// `params.targetId`, read for `Target.*` methods only.
    pub target_id: Option<&'a str>,
    /// `params.sessionId`, read for `Target.*` methods only.
    pub target_session_id: Option<&'a str>,
}

#[derive(Debug)]
pub enum ParseError {
    /// The message is longer than the limit (`agents-browser-max-message`).
    TooLarge { len: usize, max: usize },
    /// Not JSON, a duplicate key, a field of the wrong type, or an escaped string where a plain one is read.
    Json(serde_json::Error),
    /// JSON, but not the shape of a CDP message.
    Shape(&'static str),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::TooLarge { len, max } => {
                write!(f, "the message is {len} bytes, over the limit of {max}")
            }
            ParseError::Json(e) => write!(f, "not a CDP message: {e}"),
            ParseError::Shape(why) => write!(f, "not a CDP message: {why}"),
        }
    }
}

impl std::error::Error for ParseError {}

#[derive(Deserialize)]
struct Wire<'a> {
    id: Option<u64>,
    #[serde(borrow)]
    method: Option<&'a str>,
    #[serde(borrow, rename = "sessionId")]
    session_id: Option<&'a str>,
    #[serde(borrow)]
    params: Option<&'a RawValue>,
    #[serde(borrow)]
    result: Option<&'a RawValue>,
    #[serde(borrow)]
    error: Option<&'a RawValue>,
}

#[derive(Deserialize)]
struct TargetRefs<'a> {
    #[serde(borrow, rename = "targetId")]
    target_id: Option<&'a str>,
    #[serde(borrow, rename = "sessionId")]
    session_id: Option<&'a str>,
}

/// The first byte that is not JSON whitespace is `{`.
pub(crate) fn is_object(text: &[u8]) -> bool {
    text.iter()
        .find(|b| !matches!(b, b' ' | b'\t' | b'\n' | b'\r'))
        == Some(&b'{')
}

/// `raw` decoded as `T`, only when it is a JSON object (serde would also take an array for a struct).
pub(crate) fn object<'a, T: Deserialize<'a>>(raw: &'a RawValue) -> Result<T, ParseError> {
    if !is_object(raw.get().as_bytes()) {
        return Err(ParseError::Shape("params is not an object"));
    }
    serde_json::from_str(raw.get()).map_err(ParseError::Json)
}

/// The envelope of `msg`, refused over `max` bytes.
pub fn parse(msg: &[u8], max: usize) -> Result<Envelope<'_>, ParseError> {
    if msg.len() > max {
        return Err(ParseError::TooLarge {
            len: msg.len(),
            max,
        });
    }
    if !is_object(msg) {
        return Err(ParseError::Shape("not a JSON object"));
    }
    let w: Wire<'_> = serde_json::from_slice(msg).map_err(ParseError::Json)?;
    let is_reply = w.result.is_some() || w.error.is_some();
    if is_reply && w.method.is_some() {
        return Err(ParseError::Shape("both a method and a reply"));
    }
    let (mut target_id, mut target_session_id) = (None, None);
    if let (Some(method), Some(params)) = (w.method, w.params)
        && method.starts_with("Target.")
    {
        let refs: TargetRefs<'_> = object(params)?;
        target_id = refs.target_id;
        target_session_id = refs.session_id;
    }
    Ok(Envelope {
        id: w.id,
        method: w.method,
        session_id: w.session_id,
        params: w.params,
        result: w.result,
        error: w.error,
        is_reply,
        target_id,
        target_session_id,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn large_params_are_not_reencoded() {
        // a screenshot-sized reply and command: odd spacing and an escape inside, which a re-encode would change
        let data = "A".repeat(20 << 20);
        let bs = char::from(0x5c);
        let msg = format!(
            r#"{{"id":7,"result":{{ "data" : "{data}{bs}u0041", "n":1.50 }},"sessionId":"S1"}}"#
        );
        assert!(msg.contains(bs));
        let env = parse(msg.as_bytes(), 64 << 20).unwrap();
        let result = env.result.unwrap().get();
        assert_eq!(
            result,
            &msg[msg.find("{ \"data\"").unwrap()..msg.rfind(",\"sessionId\"").unwrap()]
        );
        // borrowed from the message itself, not a copy
        let range = msg.as_bytes().as_ptr_range();
        assert!(range.contains(&result.as_ptr()));
        assert!(env.is_reply);
        assert_eq!((env.id, env.session_id), (Some(7), Some("S1")));

        let cmd = format!(
            r#"{{"id":8,"method":"Page.setDocumentContent","params":{{"frameId":"F","html":"{data}"}}}}"#
        );
        let env = parse(cmd.as_bytes(), 64 << 20).unwrap();
        let params = env.params.unwrap().get();
        assert!(cmd.as_bytes().as_ptr_range().contains(&params.as_ptr()));
        assert_eq!(
            params.len(),
            data.len() + r#"{"frameId":"F","html":""}"#.len()
        );
    }

    #[test]
    fn over_max_is_refused() {
        let msg = br#"{"id":1,"method":"Browser.getVersion"}"#;
        assert!(parse(msg, msg.len()).is_ok());
        match parse(msg, msg.len() - 1) {
            Err(ParseError::TooLarge { len, max }) => {
                assert_eq!((len, max), (msg.len(), msg.len() - 1))
            }
            other => panic!("expected TooLarge, got {other:?}"),
        }
    }

    #[test]
    fn target_params_are_read() {
        let msg = br#"{"id":3,"method":"Target.detachFromTarget","params":{"sessionId":"S2","targetId":"T2"}}"#;
        let env = parse(msg, 1 << 20).unwrap();
        assert_eq!(
            (env.target_id, env.target_session_id),
            (Some("T2"), Some("S2"))
        );
        // the same params on another domain are not read
        let msg =
            br#"{"id":3,"method":"Page.navigate","params":{"sessionId":"S2","targetId":"T2"}}"#;
        let env = parse(msg, 1 << 20).unwrap();
        assert_eq!((env.target_id, env.target_session_id), (None, None));
    }

    #[test]
    fn ambiguous_messages_are_refused() {
        for msg in [
            // a duplicate key: Chromium might read the other one
            r#"{"id":1,"method":"Page.enable","sessionId":"A","sessionId":"B"}"#,
            r#"{"id":1,"method":"Target.closeTarget","params":{"targetId":"A","targetId":"B"}}"#,
            // not an object (serde would read an array as the struct's fields)
            r#"[1,"Browser.close"]"#,
            r#"{"id":1,"method":"Target.closeTarget","params":["A"]}"#,
            // wrong types, and not a CDP id
            r#"{"id":-1,"method":"Page.enable"}"#,
            r#"{"id":1.5,"method":"Page.enable"}"#,
            r#"{"id":"1","method":"Page.enable"}"#,
            // a method and a reply at once
            r#"{"id":1,"method":"Page.enable","result":{}}"#,
            // trailing bytes
            r#"{"id":1,"method":"Page.enable"} {"id":2,"method":"Browser.close"}"#,
            "",
        ] {
            assert!(parse(msg.as_bytes(), 1 << 20).is_err(), "{msg}");
        }
        assert!(parse(b"{\"id\":1,\"method\":\"\xff\"}", 1 << 20).is_err());
        // an escaped string where the broker routes by it (JSON's backslash-u escapes, built at run time)
        let bs = char::from(0x5c);
        for msg in [
            format!(r#"{{"id":1,"method":"Browser.clos{bs}u0065"}}"#),
            format!(r#"{{"id":1,"method":"Page.enable","sessionId":"S{bs}u0031"}}"#),
            format!(
                r#"{{"id":1,"method":"Target.closeTarget","params":{{"targetId":"{bs}u0041"}}}}"#
            ),
        ] {
            assert!(msg.contains(bs));
            assert!(parse(msg.as_bytes(), 1 << 20).is_err(), "{msg}");
        }
    }

    #[test]
    fn replies_and_events() {
        let env = parse(
            br#"{"id":4,"error":{"code":-32000,"message":"x"}}"#,
            1 << 20,
        )
        .unwrap();
        assert!(env.is_reply && env.error.is_some() && env.method.is_none());
        let env = parse(
            br#" {"method":"Page.loadEventFired","params":{"timestamp":1},"sessionId":"S"} "#,
            1 << 20,
        )
        .unwrap();
        assert!(!env.is_reply);
        assert_eq!(
            (env.id, env.method, env.session_id),
            (None, Some("Page.loadEventFired"), Some("S"))
        );
    }
}
