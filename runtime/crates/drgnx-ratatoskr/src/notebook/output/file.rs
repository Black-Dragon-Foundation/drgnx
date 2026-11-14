//! Outputs as a notebook file has them (nbformat output objects) read into the hub's model, to show a re-opened notebook before
//! any kernel runs (design §5.4: outputs come from the file, marked stale).

use serde_json::Value;

use super::Output;
use super::mime::Bundle;
use super::terminal::Terminal;

/// nbformat allows a string or a list of strings for a multiline text.
fn text(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(a)) => a.iter().filter_map(Value::as_str).collect(),
        _ => String::new(),
    }
}

/// One nbformat output object, or None for one this version does not know.
pub fn from_nbformat(o: &Value) -> Option<Output> {
    match o.get("output_type")?.as_str()? {
        "stream" => {
            let mut t = Terminal::default();
            t.push(&text(o.get("text")));
            Some(Output::Stream {
                name: o.get("name")?.as_str()?.to_string(),
                text: t,
            })
        }
        "display_data" => Some(Output::Display {
            display_id: None,
            bundle: Bundle::from_message(o),
        }),
        "execute_result" => Some(Output::Result {
            count: o.get("execution_count").and_then(Value::as_i64),
            bundle: Bundle::from_message(o),
        }),
        "error" => {
            let traceback = o
                .get("traceback")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .map(|l| {
                            let mut t = Terminal::default();
                            t.push(l);
                            t
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(Output::Error {
                ename: text(o.get("ename")),
                evalue: text(o.get("evalue")),
                traceback,
            })
        }
        _ => None,
    }
}
