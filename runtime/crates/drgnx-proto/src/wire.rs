//! What crosses the socket, one JSON object per line: requests `{id, method, params}`, answers `{id, result,
//! ignored?}` or `{id, error: {code, message, path?}}`, and events `{event, data}`.  A request without `id` is a
//! notification.  Not JSON-RPC: there is no `jsonrpc` key and error codes are strings.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A request's id: a number or a string, answered as it came.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Id {
    Num(u64),
    Str(String),
}

/// A request; `params` is `{}` when absent, `id` absent makes it a notification.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Request {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<Id>,
    pub method: String,
    #[serde(default = "empty_object")]
    pub params: Value,
}

fn empty_object() -> Value {
    Value::Object(serde_json::Map::new())
}

/// A successful answer; `ignored` (the params' keys the method dropped, as dotted paths) is left out when empty.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Answer {
    pub id: Id,
    pub result: Value,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ignored: Vec<String>,
}

/// A refused or failed request.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ErrorAnswer {
    pub id: Id,
    pub error: Error,
}

/// What went wrong; `path` (where in the params) is left out when there is none.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Error {
    pub code: ErrorCode,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

/// The contract's error codes, in the dispatcher's order (design 4.3), and `internal` for a handler's failure.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ErrorCode {
    NoMethod,
    NotAllowed,
    Proto,
    InvalidParams,
    Schema,
    Internal,
}

/// Something the hub tells a client unasked.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Event {
    pub event: String,
    pub data: Value,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn request_params_default_to_an_empty_object() {
        let r: Request = serde_json::from_value(json!({"id": 1, "method": "ping"})).unwrap();
        assert_eq!(r.id, Some(Id::Num(1)));
        assert_eq!(r.params, json!({}));
        let n: Request =
            serde_json::from_value(json!({"method": "x", "params": {"a": 1}})).unwrap();
        assert_eq!(n.id, None);
        let s: Request = serde_json::from_value(json!({"id": "a7", "method": "x"})).unwrap();
        assert_eq!(s.id, Some(Id::Str("a7".into())));
    }

    #[test]
    fn answers_and_errors_have_the_contract_shape() {
        let a = Answer {
            id: Id::Num(3),
            result: json!(true),
            ignored: vec![],
        };
        assert_eq!(
            serde_json::to_value(&a).unwrap(),
            json!({"id": 3, "result": true})
        );
        let a = Answer {
            ignored: vec!["env[0].x".into()],
            ..a
        };
        assert_eq!(
            serde_json::to_value(&a).unwrap(),
            json!({"id": 3, "result": true, "ignored": ["env[0].x"]})
        );
        let e = ErrorAnswer {
            id: Id::Str("q".into()),
            error: Error {
                code: ErrorCode::InvalidParams,
                message: "m".into(),
                path: None,
            },
        };
        assert_eq!(
            serde_json::to_value(&e).unwrap(),
            json!({"id": "q", "error": {"code": "invalid-params", "message": "m"}})
        );
        let codes: Vec<Value> = [
            ErrorCode::NoMethod,
            ErrorCode::NotAllowed,
            ErrorCode::Proto,
            ErrorCode::InvalidParams,
            ErrorCode::Schema,
            ErrorCode::Internal,
        ]
        .iter()
        .map(|c| serde_json::to_value(c).unwrap())
        .collect();
        assert_eq!(
            codes,
            vec![
                json!("no-method"),
                json!("not-allowed"),
                json!("proto"),
                json!("invalid-params"),
                json!("schema"),
                json!("internal")
            ]
        );
        let ev = Event {
            event: "challenge".into(),
            data: json!({"nonce": "00"}),
        };
        assert_eq!(
            serde_json::to_value(&ev).unwrap(),
            json!({"event": "challenge", "data": {"nonce": "00"}})
        );
    }
}
