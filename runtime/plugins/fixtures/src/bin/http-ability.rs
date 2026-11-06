//! Three abilities that use the host's imports.
//!
//! - `fetch`: `{"url", "method": "get" | "post", "body"? | "body_bytes"?, "headers"?: [[name, value]]}`; answers
//!   `{"status", "body"}`, or the import's error.
//! - `kv`: `{"op": "get" | "put" | "delete", "key", "value"?, "repeat"?}`; `repeat` N makes N writes with the keys
//!   `key0`, `key1`, ... and answers how many succeeded and the first error.
//! - `chatter`: `{"log_bytes"?, "stdout_bytes"?}`; writes that much through `host.log` and through stdout.

#![no_main]

use plugin_fixtures::arg;
use plugin_fixtures::prelude::*;
use serde_json::{Value, json};

struct C;

fn text(args: &str, key: &str) -> String {
    arg(args, key)
        .and_then(|v| v.as_str().map(str::to_string))
        .unwrap_or_default()
}

fn fetch(args: &str) -> Result<String, String> {
    let headers: Vec<Header> = arg(args, "headers")
        .and_then(|v| v.as_array().cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|h| {
            Some(Header {
                name: h.get(0)?.as_str()?.to_string(),
                value: h.get(1)?.as_str()?.to_string(),
            })
        })
        .collect();
    let url = text(args, "url");
    // `body_bytes` N: a body of N bytes made here, past what the arguments may carry
    let body = match arg(args, "body_bytes").and_then(|v| v.as_u64()) {
        Some(n) => vec![b'b'; n as usize],
        None => text(args, "body").into_bytes(),
    };
    let response = if text(args, "method") == "post" {
        host::http_post(&url, &headers, &body)
    } else {
        host::http_get(&url, &headers)
    }?;
    Ok(json!({
        "status": response.status,
        "body": String::from_utf8_lossy(&response.body),
    })
    .to_string())
}

fn kv(args: &str) -> Result<String, String> {
    let key = text(args, "key");
    let value = text(args, "value");
    let repeat = arg(args, "repeat").and_then(|v| v.as_u64());
    let op = text(args, "op");
    let write = |k: &str| match op.as_str() {
        "put" => host::kv_put(k, value.as_bytes()),
        _ => host::kv_delete(k),
    };
    match (op.as_str(), repeat) {
        ("get", _) => Ok(match host::kv_get(&key) {
            Some(v) => Value::String(String::from_utf8_lossy(&v).into_owned()),
            None => Value::Null,
        }
        .to_string()),
        ("put" | "delete", None) => write(&key).map(|()| "{}".to_string()),
        ("put" | "delete", Some(n)) => {
            let mut done = 0;
            let mut error = Value::Null;
            for i in 0..n {
                match write(&format!("{key}{i}")) {
                    Ok(()) => done += 1,
                    Err(e) => {
                        error = Value::String(e);
                        break;
                    }
                }
            }
            Ok(json!({ "done": done, "error": error }).to_string())
        }
        (other, _) => Err(format!("no op {other}")),
    }
}

fn chatter(args: &str) -> Result<String, String> {
    let n = |k: &str| arg(args, k).and_then(|v| v.as_u64()).unwrap_or(0) as usize;
    host::log(Level::Info, &"l".repeat(n("log_bytes")));
    print!("{}", "o".repeat(n("stdout_bytes")));
    Ok("{}".to_string())
}

impl ability::Guest for C {
    fn call(tool: String, args_json: String) -> Result<String, String> {
        match tool.as_str() {
            "fetch" => fetch(&args_json),
            "kv" => kv(&args_json),
            "chatter" => chatter(&args_json),
            other => plugin_fixtures::no_ability(other),
        }
    }
}

impl hook::Guest for C {
    fn run(_point: Point, _input_json: String) -> Result<Verdict, String> {
        plugin_fixtures::no_hook()
    }
}

plugin_fixtures::export!(C with_types_in plugin_fixtures);
