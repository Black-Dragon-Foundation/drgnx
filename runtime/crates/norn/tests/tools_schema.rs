//! The 16 coordination tools as a client sees them: their names (the Lisp's), the size of `tools/list` against the
//! 6k-token budget (storage §6.1), and what every tool does with a bad argument (Task 8).

use norn::tools::tools;
use serde_json::{Value, json};

/// The tool names `core/drgnx-coord-mcp.el` defines, in the order it lists them: a line that opens a tool is
/// `("NAME" :description …` (the description may start on the next line), inside the two tool-list functions.
fn lisp_names() -> Vec<String> {
    let src = std::fs::read_to_string(
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../core/drgnx-coord-mcp.el"),
    )
    .unwrap();
    let start = src.find("(defun drgnx-coord-mcp--report-tools").unwrap();
    let end = src.find("(defun drgnx-coord-mcp-main").unwrap();
    let mut names = Vec::new();
    for line in src[start..end].lines() {
        let line = line.trim_start().trim_start_matches("`(");
        let line = line.strip_prefix('(').unwrap_or(line);
        let Some(rest) = line.strip_prefix('"') else {
            continue;
        };
        let (name, tail) = rest.split_once('"').unwrap();
        let tail = tail.trim();
        // a function's docstring opens a line too: a tool name is lower-case letters and underscores
        let is_name = name.bytes().all(|b| b.is_ascii_lowercase() || b == b'_');
        if is_name && (tail.is_empty() || tail.starts_with(":description")) {
            names.push(name.to_owned());
        }
    }
    names
}

#[test]
fn tool_names_are_the_lisp_names() {
    let mut lisp = lisp_names();
    assert_eq!(lisp.len(), 16, "the Lisp defines 16 tools: {lisp:?}");
    let mut rust: Vec<String> = tools().iter().map(|t| t.name().to_owned()).collect();
    lisp.sort();
    rust.sort();
    assert_eq!(rust, lisp);
}

/// `tools/list`'s `tools` as `mimir` serves it: in name order, each with its description and input schema.
fn listing() -> Value {
    let mut all = tools();
    all.sort_by_key(|t| t.name());
    Value::Array(
        all.iter()
            .map(|t| {
                json!({
                    "name": t.name(),
                    "description": t.description(),
                    "inputSchema": t.input_schema(),
                })
            })
            .collect(),
    )
}

/// What `tools/list` may weigh: about 6k tokens at 4 bytes a token.
const BUDGET_BYTES: usize = 24_000;

#[test]
fn the_tool_list_fits_the_budget() {
    let bytes = json!({"tools": listing()}).to_string().len();
    // the number goes in the ledger
    eprintln!("tools/list for the 16 tools: {bytes} bytes (budget {BUDGET_BYTES})");
    assert!(
        bytes <= BUDGET_BYTES,
        "tools/list is {bytes} bytes, over the {BUDGET_BYTES} budget: trim the descriptions"
    );
}

/// The JSON type names of a property's schema (`"type": "string"` or `["string", "null"]`), without `null`.
fn types(prop: &Value) -> Vec<&str> {
    match prop.get("type") {
        Some(Value::String(t)) => vec![t.as_str()],
        Some(Value::Array(ts)) => ts
            .iter()
            .filter_map(Value::as_str)
            .filter(|t| *t != "null")
            .collect(),
        _ => Vec::new(),
    }
}

/// A valid value for a property: by its type, else a list of strings (the tools that take a list or a text).
fn valid_value(prop: &Value) -> Value {
    match types(prop).first().copied() {
        Some("string") => json!("x"),
        Some("integer") => json!(1),
        _ => json!(["x"]),
    }
}

/// A value of the wrong type for a property, when its schema names one type.
fn wrong_value(prop: &Value) -> Option<Value> {
    match types(prop).as_slice() {
        ["string"] => Some(json!(7)),
        ["integer"] => Some(json!("x")),
        _ => None,
    }
}

#[test]
fn a_bad_argument_for_every_tool() {
    for tool in tools() {
        let name = tool.name();
        let schema = tool.input_schema();
        let props = schema
            .get("properties")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        let required: Vec<String> = schema
            .get("required")
            .and_then(Value::as_array)
            .map(|r| {
                r.iter()
                    .filter_map(|k| k.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default();
        let valid: serde_json::Map<String, Value> = required
            .iter()
            .map(|k| (k.clone(), valid_value(&props[k])))
            .collect();
        assert_eq!(
            tool.check(&Value::Object(valid.clone())),
            Ok(()),
            "{name}: the valid arguments"
        );

        // an unknown key
        let mut args = valid.clone();
        args.insert("zzz".into(), json!(1));
        let e = tool.check(&Value::Object(args)).unwrap_err();
        assert_eq!(
            (e.path.as_str(), e.message.as_str()),
            ("zzz", "unknown key"),
            "{name}"
        );

        // a wrong type, on the first property with one type to get wrong
        if let Some((key, wrong)) = props
            .iter()
            .find_map(|(k, p)| wrong_value(p).map(|w| (k, w)))
        {
            let mut args = valid.clone();
            args.insert(key.clone(), wrong);
            let e = tool.check(&Value::Object(args)).unwrap_err();
            assert_eq!(e.path, *key, "{name}: a wrong type for `{key}`: {e}");
        } else {
            assert!(props.is_empty(), "{name}: no property to get wrong");
        }

        // a missing required key
        if let Some(key) = required.first() {
            let mut args = valid.clone();
            args.remove(key);
            let e = tool.check(&Value::Object(args)).unwrap_err();
            assert_eq!(e.path, *key, "{name}: `{key}` missing: {e}");
        }
    }
}
