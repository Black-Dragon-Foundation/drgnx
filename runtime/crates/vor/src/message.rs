//! A protocol message, as the wire has it: a request, a response or an event, its payload left as JSON.
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

/// One DAP message. `seq` is read from a number or a numeric string (netcoredbg sends strings).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Message {
    Request {
        #[serde(deserialize_with = "de_seq")]
        seq: i64,
        command: String,
        #[serde(default, skip_serializing_if = "Value::is_null")]
        arguments: Value,
    },
    Response {
        #[serde(deserialize_with = "de_seq")]
        seq: i64,
        #[serde(deserialize_with = "de_seq")]
        request_seq: i64,
        success: bool,
        command: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default, skip_serializing_if = "Value::is_null")]
        body: Value,
    },
    Event {
        #[serde(deserialize_with = "de_seq")]
        seq: i64,
        event: String,
        #[serde(default, skip_serializing_if = "Value::is_null")]
        body: Value,
    },
}

fn de_seq<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
    match Value::deserialize(d)? {
        Value::Number(n) => n
            .as_i64()
            .ok_or_else(|| serde::de::Error::custom("seq is not an integer")),
        Value::String(s) => s
            .trim()
            .parse()
            .map_err(|_| serde::de::Error::custom("seq is not a number")),
        _ => Err(serde::de::Error::custom("seq is not a number")),
    }
}
