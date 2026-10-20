//! Pattern matching for `expect` steps.
//!
//! An object pattern matches an object that has every key of the pattern (extra keys are fine). An array pattern matches
//! an array element by element and in length, unless the pattern is `{"$contains": [...]}` (every element of the
//! list matches some element). Special strings: `"$any"`, `"$string"`, `"$number"`, `"$hex64"`, `"$absent"` (the key
//! must be missing), `"$capture:NAME"` (match anything and remember it) and `"$NAME"` (equal to a value captured earlier).

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

fn at(path: &str, pattern: &Value, actual: &Value, caps: &mut Captures) -> Result<(), String> {
    let here = if path.is_empty() {
        "the line".to_string()
    } else {
        path.to_string()
    };
    match pattern {
        Value::String(s) if s.starts_with('$') => special(&here, s, actual, caps),
        Value::Object(p) => {
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
        _ if pattern == actual => Ok(()),
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
            match caps.0.get(&s[1..]) {
                Some(seen) if seen == actual => Ok(()),
                Some(seen) => Err(format!(
                    "{here}: wanted the captured {s} = {}, got {}",
                    show(seen),
                    show(actual)
                )),
                None if actual.as_str() == Some(s) => Ok(()),
                None => Err(format!("{here}: wanted {s:?}, got {}", show(actual))),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
}
