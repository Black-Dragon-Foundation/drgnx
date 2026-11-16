//! Pattern matching for `expect` steps.
//!
//! An object pattern matches an object that has every key of the pattern (extra keys are fine). An array pattern matches
//! an array element by element and in length, unless the pattern is `{"$contains": [...]}` (every element of the
//! list matches some element). Special strings: `"$any"`, `"$string"`, `"$number"`, `"$hex64"`, `"$absent"` (the key
//! must be missing), `"$capture:NAME"` (match anything and remember it), `"$NAME"` (equal to a value captured earlier) and `"$not:NAME"` (any
//! value but the one captured as NAME);
//! `"$NAME#1"` (a captured string followed by more text, such as a task id `JOB#1`) matches the capture and that text.
//! `{"$text": "needle"}` (or a list of needles, each of which must be held) matches any value with a string inside it (at any depth) that holds `needle`: a patch's rows by
//! what they say, whatever the ops around them are. JSON numbers of equal value match, however they are spelled
//! (`0` and `0.0`).

use serde_json::Value;
use std::collections::BTreeMap;

/// Values captured by `$capture:NAME` (and by steps such as `spawn`), usable later as `$NAME`.
#[derive(Default, Debug, Clone)]
pub struct Captures(pub BTreeMap<String, Value>);

fn kind(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "an array",
        Value::Object(_) => "an object",
    }
}

fn show(v: &Value) -> String {
    let s = v.to_string();
    if s.len() > 200 {
        format!("{}...", s.chars().take(200).collect::<String>())
    } else {
        s
    }
}

pub fn matches(pattern: &Value, actual: &Value, caps: &mut Captures) -> Result<(), String> {
    at("", pattern, actual, caps)
}

/// Whether the numbers A and B are the same value: whole numbers exactly, anything else as floats (so `0` and `0.0`).
fn same_number(a: &serde_json::Number, b: &serde_json::Number) -> bool {
    match (a.as_i64(), b.as_i64(), a.as_u64(), b.as_u64()) {
        (Some(x), Some(y), _, _) => x == y,
        (_, _, Some(x), Some(y)) => x == y,
        _ => a.as_f64() == b.as_f64(),
    }
}

/// Whether PATTERN equals ACTUAL as JSON values, numbers by value.
fn same(pattern: &Value, actual: &Value) -> bool {
    match (pattern, actual) {
        (Value::Number(a), Value::Number(b)) => same_number(a, b),
        _ => pattern == actual,
    }
}

/// Whether a string holding NEEDLE is anywhere inside V.
fn holds_text(v: &Value, needle: &str) -> bool {
    match v {
        Value::String(s) => s.contains(needle),
        Value::Array(items) => items.iter().any(|i| holds_text(i, needle)),
        Value::Object(o) => o.values().any(|i| holds_text(i, needle)),
        _ => false,
    }
}

fn at(path: &str, pattern: &Value, actual: &Value, caps: &mut Captures) -> Result<(), String> {
    let here = if path.is_empty() {
        "the line".to_string()
    } else {
        path.to_string()
    };
    match pattern {
        Value::String(s) if s.starts_with('$') => special(&here, s, actual, caps),
        Value::Object(p) => {
            if let (1, Some(wanted)) = (p.len(), p.get("$text")) {
                let needles: Vec<&str> = match wanted {
                    Value::String(s) => vec![s.as_str()],
                    Value::Array(l) => l.iter().filter_map(Value::as_str).collect(),
                    _ => {
                        return Err(format!(
                            "{here}: \"$text\" takes a string or a list of strings"
                        ));
                    }
                };
                return match needles.iter().find(|n| !holds_text(actual, n)) {
                    None => Ok(()),
                    Some(n) => Err(format!("{here}: no text holds {n:?} in {}", show(actual))),
                };
            }
            if let (1, Some(Value::Array(wanted))) = (p.len(), p.get("$contains")) {
                let Value::Array(items) = actual else {
                    return Err(format!(
                        "{here}: wanted an array to look in, got {} ({})",
                        kind(actual),
                        show(actual)
                    ));
                };
                for w in wanted {
                    let mut found = None;
                    for item in items {
                        let mut trial = caps.clone();
                        if at(path, w, item, &mut trial).is_ok() {
                            found = Some(trial);
                            break;
                        }
                    }
                    match found {
                        Some(trial) => *caps = trial,
                        None => {
                            return Err(format!(
                                "{here}: no element matches {} in {}",
                                show(w),
                                show(actual)
                            ));
                        }
                    }
                }
                return Ok(());
            }
            let Value::Object(a) = actual else {
                return Err(format!(
                    "{here}: wanted an object, got {} ({})",
                    kind(actual),
                    show(actual)
                ));
            };
            for (k, pv) in p {
                let child = if path.is_empty() {
                    k.clone()
                } else {
                    format!("{path}.{k}")
                };
                if pv == "$absent" {
                    if a.contains_key(k) {
                        return Err(format!("{child}: must be absent, is {}", show(&a[k])));
                    }
                    continue;
                }
                match a.get(k) {
                    Some(av) => at(&child, pv, av, caps)?,
                    None => return Err(format!("{child}: missing (the line is {})", show(actual))),
                }
            }
            Ok(())
        }
        Value::Array(p) => {
            let Value::Array(a) = actual else {
                return Err(format!(
                    "{here}: wanted an array, got {} ({})",
                    kind(actual),
                    show(actual)
                ));
            };
            if p.len() != a.len() {
                return Err(format!(
                    "{here}: wanted {} elements, got {} ({})",
                    p.len(),
                    a.len(),
                    show(actual)
                ));
            }
            for (i, (pv, av)) in p.iter().zip(a).enumerate() {
                at(&format!("{path}[{i}]"), pv, av, caps)?;
            }
            Ok(())
        }
        _ if same(pattern, actual) => Ok(()),
        _ => Err(format!(
            "{here}: wanted {}, got {}",
            show(pattern),
            show(actual)
        )),
    }
}

fn special(here: &str, s: &str, actual: &Value, caps: &mut Captures) -> Result<(), String> {
    match s {
        "$any" => Ok(()),
        "$string" if actual.is_string() => Ok(()),
        "$string" => Err(format!(
            "{here}: wanted a string, got {} ({})",
            kind(actual),
            show(actual)
        )),
        "$number" if actual.is_number() => Ok(()),
        "$number" => Err(format!(
            "{here}: wanted a number, got {} ({})",
            kind(actual),
            show(actual)
        )),
        "$hex64"
            if actual
                .as_str()
                .is_some_and(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit())) =>
        {
            Ok(())
        }
        "$hex64" => Err(format!(
            "{here}: wanted 64 hex digits, got {}",
            show(actual)
        )),
        "$absent" => Err(format!(
            "{here}: \"$absent\" only means something as an object's value"
        )),
        _ => {
            if let Some(name) = s.strip_prefix("$capture:") {
                caps.0.insert(name.to_string(), actual.clone());
                return Ok(());
            }
            if let Some(name) = s.strip_prefix("$not:") {
                return match caps.0.get(name) {
                    Some(seen) if same(seen, actual) => Err(format!(
                        "{here}: wanted anything but the captured ${name}, got {}",
                        show(actual)
                    )),
                    Some(_) => Ok(()),
                    None => Err(format!("{here}: {s}: nothing was captured as {name}")),
                };
            }
            match caps.0.get(&s[1..]) {
                Some(seen) if same(seen, actual) => Ok(()),
                Some(seen) => Err(format!(
                    "{here}: wanted the captured {s} = {}, got {}",
                    show(seen),
                    show(actual)
                )),
                None if actual.as_str() == Some(s) => Ok(()),
                None => match captured_then_text(s, caps) {
                    Some(want) if actual.as_str() == Some(want.as_str()) => Ok(()),
                    Some(want) => Err(format!(
                        "{here}: wanted {s:?} = {want:?}, got {}",
                        show(actual)
                    )),
                    None => Err(format!("{here}: wanted {s:?}, got {}", show(actual))),
                },
            }
        }
    }
}

/// `"$NAME#1"`: the string captured as NAME with the text after the name (`#1`) appended; none when NAME is not a
/// captured string or nothing follows it.
fn captured_then_text(s: &str, caps: &Captures) -> Option<String> {
    let rest = s.strip_prefix('$')?;
    let end = rest
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .filter(|e| *e > 0)?;
    let (name, tail) = rest.split_at(end);
    Some(format!("{}{tail}", caps.0.get(name)?.as_str()?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_capture_followed_by_text_expands() {
        let mut caps = Captures::default();
        matches(&json!("$capture:job"), &json!("job-7"), &mut caps).unwrap();
        assert!(
            matches(
                &json!({"id": "$job#1"}),
                &json!({"id": "job-7#1"}),
                &mut caps
            )
            .is_ok()
        );
        assert!(matches(&json!("$job#1"), &json!("job-7#2"), &mut caps).is_err());
        // a name that was never captured stays a literal
        assert!(matches(&json!("$nope#1"), &json!("$nope#1"), &mut caps).is_ok());
        assert!(matches(&json!("$job"), &json!("job-7"), &mut caps).is_ok());
        assert!(matches(&json!("$not:job"), &json!("job-8"), &mut caps).is_ok());
        assert!(matches(&json!("$not:job"), &json!("job-7"), &mut caps).is_err());
        assert!(matches(&json!("$not:nope"), &json!("job-7"), &mut caps).is_err());
    }

    fn ok(p: Value, a: Value) -> bool {
        matches(&p, &a, &mut Captures::default()).is_ok()
    }

    #[test]
    fn object_subset_and_specials() {
        let actual = json!({"a": 1, "b": "x"});
        assert!(ok(json!({"a": "$number"}), actual.clone()));
        assert!(ok(json!({"b": "$string", "a": "$any"}), actual.clone()));
        assert!(
            !ok(json!({"a": "$absent"}), actual.clone()),
            "$absent fails on a present key"
        );
        assert!(ok(json!({"c": "$absent"}), actual.clone()));
        assert!(!ok(json!({"c": 1}), actual.clone()), "a missing key fails");
        assert!(!ok(json!({"a": "$string"}), actual.clone()));
        assert!(ok(json!({"h": "$hex64"}), json!({"h": "0".repeat(64)})));
        assert!(!ok(json!({"h": "$hex64"}), json!({"h": "0".repeat(63)})));
        // a capture, then a reuse
        let mut caps = Captures::default();
        matches(
            &json!({"pid": "$capture:p"}),
            &json!({"pid": 77}),
            &mut caps,
        )
        .unwrap();
        assert_eq!(caps.0["p"], json!(77));
        assert!(matches(&json!({"again": "$p"}), &json!({"again": 77}), &mut caps).is_ok());
        assert!(matches(&json!({"again": "$p"}), &json!({"again": 78}), &mut caps).is_err());
    }

    #[test]
    fn arrays_exact_unless_contains() {
        assert!(ok(json!([1, "$number"]), json!([1, 2])));
        assert!(!ok(json!([1]), json!([1, 2])), "length must agree");
        assert!(!ok(json!([2, 1]), json!([1, 2])), "order counts");
        assert!(ok(json!({"$contains": [2]}), json!([1, 2, 3])));
        assert!(ok(
            json!({"$contains": [{"k": "$string"}]}),
            json!([1, {"k": "v", "extra": 1}])
        ));
        assert!(!ok(json!({"$contains": [9]}), json!([1, 2, 3])));
    }

    #[test]
    fn numbers_of_equal_value_match_whatever_their_spelling() {
        assert!(
            ok(json!(0), json!(0.0)),
            "an integer pattern, a float actual"
        );
        assert!(
            ok(json!(0.0), json!(0)),
            "a float pattern, an integer actual"
        );
        assert!(ok(json!({"n": 2}), json!({"n": 2.0})));
        assert!(ok(json!([1.5, 3]), json!([1.5, 3.0])));
        assert!(!ok(json!(0), json!(0.5)), "different values still differ");
        assert!(!ok(json!(1), json!("1")), "a number is no string");
        // a captured number is equal to the same value spelled another way
        let mut caps = Captures::default();
        matches(&json!({"v": "$capture:v"}), &json!({"v": 3}), &mut caps).unwrap();
        assert!(matches(&json!({"v": "$v"}), &json!({"v": 3.0}), &mut caps).is_ok());
    }

    #[test]
    fn text_finds_a_string_anywhere_in_the_value() {
        // a view-patch's rows: the text is somewhere inside the ops
        let patch = json!({"ops": [{"insert": [0, [{"key": "list:3", "text": "  ○ do it  not started"}]]}]});
        assert!(ok(json!({"ops": {"$text": "not started"}}), patch.clone()));
        assert!(ok(json!({"$text": "do it"}), patch.clone()));
        assert!(!ok(json!({"ops": {"$text": "needs you"}}), patch.clone()));
        assert!(ok(
            json!({"$contains": [{"insert": {"$text": "list:3"}}]}),
            patch["ops"].clone()
        ));
        assert!(
            !ok(json!({"$text": "x"}), json!(5)),
            "a number holds no text"
        );
        assert!(
            ok(json!({"$text": ["list:3", "not started"]}), patch.clone()),
            "every needle"
        );
        assert!(
            !ok(json!({"$text": ["list:3", "nope"]}), patch),
            "one missing needle fails"
        );
    }
}
