//! MCP's use of runstav's JSON-RPC 2.0 module: the answers a server writes.

use runstav::jsonrpc::{ErrorObject, Id};
use serde_json::{Value, json};

/// A result answer to ID.
pub fn result(id: &Id, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

/// An error answer; `id` is `null` when the request's id could not be read (a parse error).
pub fn error(id: Option<&Id>, error: &ErrorObject) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": error})
}

/// The `id` of a line that is JSON but not a valid request, when it is a usable one, so the sender of an invalid
/// request is answered on its own id (JSON-RPC 2.0: `null` only when it cannot be read).
pub fn lenient_id(line: &str) -> Option<Id> {
    let v: Value = serde_json::from_str(line).ok()?;
    match v.get("id")? {
        Value::Number(n) => n.as_i64().map(Id::Num),
        Value::String(s) => Some(Id::Str(s.clone())),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use runstav::jsonrpc::PARSE_ERROR;

    #[test]
    fn answers_have_their_shape() {
        assert_eq!(
            result(&Id::Num(3), json!({})),
            json!({"jsonrpc": "2.0", "id": 3, "result": {}})
        );
        assert_eq!(
            error(None, &ErrorObject::new(PARSE_ERROR, "invalid JSON")),
            json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "invalid JSON"}})
        );
        assert_eq!(
            lenient_id(r#"{"jsonrpc":"1.0","id":"a","method":"m"}"#),
            Some(Id::Str("a".into()))
        );
        assert_eq!(lenient_id(r#"{"id":1.5}"#), None);
        assert_eq!(lenient_id("[1]"), None);
    }
}
