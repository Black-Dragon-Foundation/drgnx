//! The canonical dump of test/fixtures/huginn/README.md, shared by the differential and property tests and by
//! `examples/dump.rs` (which the editor's differential test runs). Each user compiles it on its own.
#![allow(dead_code)]

use huginn::value::{Datum, Node};
use serde_json::{Value, json};

/// The dump of one datum.
pub fn dump(node: &Node) -> Value {
    let all = |items: &[Node]| Value::Array(items.iter().map(dump).collect());
    match &node.datum {
        Datum::Int(i) => json!(["int", i.to_string()]),
        Datum::Float(f) => json!(["float", float_text(*f)]),
        Datum::Str(s) => json!(["str", s]),
        Datum::Sym(s) => json!(["sym", s]),
        Datum::List(items) => json!(["list", all(items)]),
        Datum::Cons(items, tail) => json!(["cons", all(items), dump(tail)]),
        Datum::Vec(items) => json!(["vec", all(items)]),
    }
}

/// The dumps of top-level data, as one array.
pub fn dump_all(nodes: &[Node]) -> Value {
    Value::Array(nodes.iter().map(dump).collect())
}

/// A float as Emacs prints it, for the cases that differ from Rust's text: infinities and NaNs.
pub fn float_text(f: f64) -> String {
    let sign = if f.is_sign_negative() { "-" } else { "" };
    if f.is_nan() {
        format!("{sign}0.0e+NaN")
    } else if f.is_infinite() {
        format!("{sign}1.0e+INF")
    } else {
        format!("{f:?}")
    }
}

/// The value of a dumped float's text (Emacs's or Rust's).
pub fn float_value(text: &str) -> f64 {
    if text.ends_with("e+NaN") {
        f64::NAN
    } else if text.ends_with("e+INF") {
        if text.starts_with('-') {
            f64::NEG_INFINITY
        } else {
            f64::INFINITY
        }
    } else {
        text.parse()
            .unwrap_or_else(|_| panic!("not a float: {text}"))
    }
}

/// Equal dumps; floats by value (any NaN equals any NaN, `-0.0` is not `0.0`).
pub fn same(expected: &Value, actual: &Value) -> bool {
    match (expected, actual) {
        (Value::Array(e), Value::Array(a)) if e.len() == a.len() => {
            if e.len() == 2 && e[0] == "float" && a[0] == "float" {
                let (x, y) = (
                    float_value(e[1].as_str().unwrap_or_default()),
                    float_value(a[1].as_str().unwrap_or_default()),
                );
                return (x.is_nan() && y.is_nan()) || x.to_bits() == y.to_bits();
            }
            e.iter().zip(a).all(|(x, y)| same(x, y))
        }
        _ => expected == actual,
    }
}
