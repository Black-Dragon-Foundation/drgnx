//! The schema subset: what it checks, what it accepts and ignores, what it refuses at load. Pure (pattern D).

use super::*;
use serde_json::json;

fn bad(schema: Value, value: Value) -> SchemaError {
    check(&schema, &value).unwrap_err()
}

// [D] pure
#[test]
fn types_are_checked_at_their_path() {
    let s = json!({"type": "object", "properties": {
        "url": {"type": "string", "maxLength": 8},
        "n": {"type": "integer"},
        "tags": {"type": "array", "items": {"type": "string"}},
        "mode": {"enum": ["a", "b"]},
    }, "required": ["url"]});
    assert!(
        check(
            &s,
            &json!({"url": "http://a", "n": 3, "tags": ["x"], "mode": "a"})
        )
        .is_ok()
    );
    assert_eq!(bad(s.clone(), json!({})).path, "url");
    assert_eq!(bad(s.clone(), json!({"url": 4})).path, "url");
    assert_eq!(bad(s.clone(), json!({"url": "123456789"})).path, "url");
    assert_eq!(bad(s.clone(), json!({"url": "a", "n": 1.5})).path, "n");
    assert_eq!(
        bad(s.clone(), json!({"url": "a", "tags": ["x", 2]})).path,
        "tags[1]"
    );
    assert_eq!(
        bad(s.clone(), json!({"url": "a", "mode": "c"})).path,
        "mode"
    );
    assert_eq!(bad(s, json!("no")).path, "arguments");
}

// [D] pure
#[test]
fn additional_properties_false_refuses_other_keys() {
    let s = json!({"type": "object", "properties": {"a": {"type": "string"}}, "additionalProperties": false});
    assert!(check(&s, &json!({"a": "x"})).is_ok());
    assert_eq!(bad(s, json!({"a": "x", "b": 1})).path, "b");
    // without it, other keys pass
    assert!(check(&json!({"type": "object"}), &json!({"b": 1})).is_ok());
}

// [D] pure: abilities::tests::annotation_keywords_are_accepted
#[test]
fn annotation_keywords_are_accepted_and_ignored() {
    let s = json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$comment": "c", "title": "t", "description": "d", "default": {}, "examples": [{}],
        "deprecated": false, "readOnly": false, "writeOnly": false,
        "type": "object",
        "properties": {"a": {"type": "string", "description": "the a", "default": "x"}},
    });
    assert_eq!(check_schema(&s), Ok(()));
    assert!(check(&s, &json!({"a": "y"})).is_ok());
}

// [D] pure
#[test]
fn a_keyword_the_checker_does_not_check_is_refused_at_load() {
    for (kw, v) in [
        ("pattern", json!("^a")),
        ("minimum", json!(1)),
        ("oneOf", json!([])),
        ("$ref", json!("#/x")),
        ("format", json!("uri")),
    ] {
        let s = json!({"type": "object", "properties": {"a": {"type": "string", kw: v}}});
        let e = check_schema(&s).unwrap_err();
        assert!(e.message.contains(kw), "{kw}: {e:?}");
        assert_eq!(e.path, "properties.a", "{kw}");
    }
    assert!(check_schema(&json!({"type": "object", "additionalProperties": true})).is_ok());
    assert!(check_schema(&json!({"type": "wat"})).is_err());
}
