//! Outputs as a notebook file has them (nbformat output objects) read into the hub's model, to show a re-opened notebook before
//! any kernel runs (design §5.4: outputs come from the file, marked stale).
//!
//! The file is not trusted: an output is read as far as the caps allow and the rest is skipped as it is read (a traceback of a
//! million empty entries builds two hundred), an output larger than [`MAX_RAW_OUTPUT`] is not read at all, and what is read goes through
//! the same accounting as a kernel's ([`super::CellRun::push_output`]).

use serde::Deserialize;
use serde::de::{self, Deserializer, IgnoredAny, SeqAccess, Visitor};
use serde_json::{Map, Value, json};

use super::mime::Bundle;
use super::terminal::Terminal;
use super::{MAX_NAME, MAX_TEXT, MAX_TRACEBACK, Output};

/// One output's JSON text, at most: a larger one is shown as a line saying so.
pub const MAX_RAW_OUTPUT: usize = 8 << 20;

/// A string, or a list of strings (nbformat's multiline text), kept to MAX_TEXT bytes: what is past it is skipped, not built.
fn capped_text<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    struct V;
    fn cut(s: &mut String) {
        if s.len() > MAX_TEXT {
            let mut at = MAX_TEXT;
            while !s.is_char_boundary(at) {
                at -= 1;
            }
            s.truncate(at);
        }
    }
    impl<'de> Visitor<'de> for V {
        type Value = String;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("a string or a list of strings")
        }
        fn visit_str<E: de::Error>(self, v: &str) -> Result<String, E> {
            let mut s = v.to_owned();
            cut(&mut s);
            Ok(s)
        }
        fn visit_seq<A: SeqAccess<'de>>(self, mut a: A) -> Result<String, A::Error> {
            let mut s = String::new();
            while let Some(part) = a.next_element::<std::borrow::Cow<str>>()? {
                if s.len() < MAX_TEXT {
                    s.push_str(&part);
                }
            }
            cut(&mut s);
            Ok(s)
        }
    }
    d.deserialize_any(V)
}

/// A list of strings, the first MAX_TRACEBACK of them.
fn capped_lines<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<String>, D::Error> {
    struct V;
    impl<'de> Visitor<'de> for V {
        type Value = Vec<String>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("a list of strings")
        }
        fn visit_seq<A: SeqAccess<'de>>(self, mut a: A) -> Result<Vec<String>, A::Error> {
            let mut out = Vec::new();
            while out.len() < MAX_TRACEBACK {
                match a.next_element::<String>()? {
                    Some(s) => out.push(s),
                    None => return Ok(out),
                }
            }
            while a.next_element::<IgnoredAny>()?.is_some() {}
            Ok(out)
        }
    }
    d.deserialize_seq(V)
}

#[derive(Deserialize, Default)]
struct File {
    output_type: String,
    #[serde(default)]
    name: String,
    #[serde(default, deserialize_with = "capped_text")]
    text: String,
    #[serde(default)]
    data: Map<String, Value>,
    #[serde(default)]
    metadata: Value,
    #[serde(default)]
    execution_count: Option<i64>,
    #[serde(default, deserialize_with = "capped_text")]
    ename: String,
    #[serde(default, deserialize_with = "capped_text")]
    evalue: String,
    #[serde(default, deserialize_with = "capped_lines")]
    traceback: Vec<String>,
}

fn note(text: &str) -> Output {
    Output::Display {
        display_id: None,
        bundle: Bundle::from_message(&json!({"data": {"text/plain": text}})),
    }
}

/// One nbformat output object as its JSON text, or None for one that is not an output this version knows.
pub fn from_nbformat_raw(raw: &str) -> Option<Output> {
    if raw.len() > MAX_RAW_OUTPUT {
        return Some(note("[an output too large to load]"));
    }
    let f: File = serde_json::from_str(raw).ok()?;
    match f.output_type.as_str() {
        "stream" => {
            let mut t = Terminal::default();
            t.push(&f.text);
            Some(Output::Stream {
                name: f.name.chars().take(MAX_NAME).collect(),
                text: t,
            })
        }
        "display_data" => Some(Output::Display {
            display_id: None,
            bundle: Bundle::from_message(&json!({"data": f.data, "metadata": f.metadata})),
        }),
        "execute_result" => Some(Output::Result {
            count: f.execution_count,
            bundle: Bundle::from_message(&json!({"data": f.data, "metadata": f.metadata})),
        }),
        "error" => Some(Output::Error {
            ename: f.ename,
            evalue: f.evalue,
            traceback: f
                .traceback
                .iter()
                .map(|l| {
                    let mut t = Terminal::default();
                    t.push(l);
                    t
                })
                .collect(),
        }),
        _ => None,
    }
}
