//! One shared JSON-RPC 2.0 module for ACP and MCP (design §5.1).  Not the hub protocol (`wire`): this one carries
//! `"jsonrpc": "2.0"`, and has no batches.

use crate::line;
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::time::Instant;

pub const PARSE_ERROR: i64 = -32700;
pub const INVALID_REQUEST: i64 = -32600;
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const INVALID_PARAMS: i64 = -32602;
pub const INTERNAL_ERROR: i64 = -32603;
/// MCP 2026-07-28, basic.
pub const UNSUPPORTED_PROTOCOL_VERSION: i64 = -32022;

/// A request's id: a number or a string (`null` only in a parse-error answer, which is `Error { id: None }`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(untagged)]
pub enum Id {
    Num(i64),
    Str(String),
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ErrorObject {
    pub code: i64,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl ErrorObject {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        ErrorObject {
            code,
            message: message.into(),
            data: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Message {
    Request {
        id: Id,
        method: String,
        params: Option<Value>,
    },
    Notification {
        method: String,
        params: Option<Value>,
    },
    Result {
        id: Id,
        result: Value,
    },
    Error {
        id: Option<Id>,
        error: ErrorObject,
    },
}

fn invalid(m: &str) -> ErrorObject {
    ErrorObject::new(INVALID_REQUEST, m)
}

fn id_of(v: &Value) -> Result<Id, ErrorObject> {
    match v {
        Value::String(s) => Ok(Id::Str(s.clone())),
        Value::Number(n) => n
            .as_i64()
            .map(Id::Num)
            .ok_or_else(|| invalid("id is not an integer")),
        _ => Err(invalid("id must be a number or a string")),
    }
}

/// One line as a message.  Invalid JSON is `-32700`; a batch, a duplicate key, a wrong `jsonrpc` or a shape that is
/// none of the four messages is `-32600`.
pub fn parse(line: &str) -> Result<Message, ErrorObject> {
    if line.trim_start().starts_with('[') {
        return Err(invalid("batches are not supported"));
    }
    if serde_json::from_str::<Value>(line).is_err() {
        return Err(ErrorObject::new(PARSE_ERROR, "invalid JSON"));
    }
    let v = line::parse_strict(line).map_err(|e| invalid(&e.message))?;
    let obj = v.as_object().expect("parse_strict returns an object");
    if obj.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return Err(invalid("jsonrpc must be \"2.0\""));
    }
    let id = match obj.get("id") {
        None => None,
        Some(Value::Null) => None,
        Some(v) => Some(id_of(v)?),
    };
    if let Some(m) = obj.get("method") {
        let method = m
            .as_str()
            .ok_or_else(|| invalid("method must be a string"))?
            .to_string();
        if obj.contains_key("result") || obj.contains_key("error") {
            return Err(invalid("a request has no result or error"));
        }
        let params = obj.get("params").cloned();
        if matches!(params, Some(ref p) if !p.is_object() && !p.is_array()) {
            return Err(invalid("params must be an object or an array"));
        }
        if obj.get("id").is_some_and(Value::is_null) {
            return Err(invalid("id must not be null"));
        }
        return Ok(match id {
            Some(id) => Message::Request { id, method, params },
            None => Message::Notification { method, params },
        });
    }
    match (obj.get("result"), obj.get("error")) {
        (Some(result), None) => {
            let id = id.ok_or_else(|| invalid("a result needs an id"))?;
            Ok(Message::Result {
                id,
                result: result.clone(),
            })
        }
        (None, Some(e)) => {
            let e = e
                .as_object()
                .ok_or_else(|| invalid("error must be an object"))?;
            let code = e
                .get("code")
                .and_then(Value::as_i64)
                .ok_or_else(|| invalid("error.code must be an integer"))?;
            let message = e
                .get("message")
                .and_then(Value::as_str)
                .ok_or_else(|| invalid("error.message must be a string"))?
                .to_string();
            let data = e.get("data").cloned();
            Ok(Message::Error {
                id,
                error: ErrorObject {
                    code,
                    message,
                    data,
                },
            })
        }
        _ => Err(invalid("not a request, notification, result or error")),
    }
}

/// Outstanding client requests by id, each with a deadline.  Each entry ends exactly once: by [`Pending::resolve`]
/// or by [`Pending::expire`], never both.
#[derive(Debug)]
pub struct Pending<T> {
    map: HashMap<Id, (Instant, T)>,
}

impl<T> Default for Pending<T> {
    fn default() -> Self {
        Pending {
            map: HashMap::new(),
        }
    }
}

impl<T> Pending<T> {
    pub fn new() -> Self {
        Self::default()
    }

    /// Track ID until DEADLINE.  An id already in flight is refused and the value handed back.
    pub fn insert(&mut self, id: Id, deadline: Instant, value: T) -> Result<(), T> {
        if self.map.contains_key(&id) {
            return Err(value);
        }
        self.map.insert(id, (deadline, value));
        Ok(())
    }

    /// The entry for ID, removed; `None` when it was resolved, expired or never there.
    pub fn resolve(&mut self, id: &Id) -> Option<T> {
        self.map.remove(id).map(|(_, v)| v)
    }

    /// Every entry whose deadline is at or before NOW, removed.
    pub fn expire(&mut self, now: Instant) -> Vec<(Id, T)> {
        let due: Vec<Id> = self
            .map
            .iter()
            .filter(|(_, (d, _))| *d <= now)
            .map(|(i, _)| i.clone())
            .collect();
        due.into_iter()
            .filter_map(|i| self.map.remove(&i).map(|(_, v)| (i, v)))
            .collect()
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::time::Duration;

    #[test]
    fn parse_cases() {
        assert_eq!(
            parse(r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#),
            Ok(Message::Request {
                id: Id::Num(1),
                method: "ping".into(),
                params: None
            })
        );
        assert_eq!(
            parse(r#"{"jsonrpc":"2.0","id":"a","method":"m","params":{"x":1}}"#),
            Ok(Message::Request {
                id: Id::Str("a".into()),
                method: "m".into(),
                params: Some(json!({"x":1}))
            })
        );
        assert_eq!(
            parse(r#"{"jsonrpc":"2.0","method":"n"}"#),
            Ok(Message::Notification {
                method: "n".into(),
                params: None
            })
        );
        assert_eq!(
            parse(r#"{"jsonrpc":"2.0","id":2,"result":{"ok":true}}"#),
            Ok(Message::Result {
                id: Id::Num(2),
                result: json!({"ok":true})
            })
        );
        assert_eq!(
            parse(r#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"bad"}}"#),
            Ok(Message::Error {
                id: None,
                error: ErrorObject::new(PARSE_ERROR, "bad")
            })
        );
        assert_eq!(parse("{nope").unwrap_err().code, PARSE_ERROR);
        for bad in [
            r#"{"id":1,"method":"m"}"#,
            r#"{"jsonrpc":"1.0","id":1,"method":"m"}"#,
            r#"{"jsonrpc":"2.0","id":1.5,"method":"m"}"#,
            r#"{"jsonrpc":"2.0","id":null,"method":"m"}"#,
            r#"{"jsonrpc":"2.0","id":1,"method":"m","params":3}"#,
            r#"{"jsonrpc":"2.0","id":1}"#,
            r#"{"jsonrpc":"2.0","result":1}"#,
            r#"{"jsonrpc":"2.0","id":1,"result":1,"error":{"code":1,"message":"x"}}"#,
            "3",
        ] {
            assert_eq!(parse(bad).unwrap_err().code, INVALID_REQUEST, "{bad}");
        }
    }

    #[test]
    fn a_batch_is_invalid_request() {
        let e = parse(r#"[{"jsonrpc":"2.0","id":1,"method":"m"}]"#).unwrap_err();
        assert_eq!(
            (e.code, e.message.as_str()),
            (INVALID_REQUEST, "batches are not supported")
        );
    }

    #[test]
    fn duplicate_keys_refused() {
        let e = parse(r#"{"jsonrpc":"2.0","id":1,"method":"a","method":"b"}"#).unwrap_err();
        assert_eq!(e.code, INVALID_REQUEST);
    }

    #[test]
    fn pending_ends_once() {
        let t0 = Instant::now();
        let mut p: Pending<&str> = Pending::new();
        assert!(
            p.insert(Id::Num(1), t0 + Duration::from_secs(1), "a")
                .is_ok()
        );
        assert_eq!(p.insert(Id::Num(1), t0, "dup"), Err("dup"));
        assert!(
            p.insert(Id::Str("b".into()), t0 + Duration::from_secs(5), "b")
                .is_ok()
        );
        assert!(
            p.insert(Id::Num(3), t0 + Duration::from_secs(1), "c")
                .is_ok()
        );
        assert_eq!(p.resolve(&Id::Num(3)), Some("c"));
        assert_eq!(p.resolve(&Id::Num(3)), None);
        assert!(p.expire(t0).is_empty());
        let due = p.expire(t0 + Duration::from_secs(2));
        assert_eq!(due, vec![(Id::Num(1), "a")]);
        assert_eq!(p.resolve(&Id::Num(1)), None);
        assert!(p.expire(t0 + Duration::from_secs(2)).is_empty());
        assert_eq!(p.resolve(&Id::Str("b".into())), Some("b"));
        assert!(p.is_empty());
    }
}
