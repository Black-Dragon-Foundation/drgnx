//! The JSON Schema subset an ability's `input_schema` may use (draft 2020-12), and the check of a call's arguments
//! against it.
//!
//! Checked: `type`, `properties`, `required`, `enum`, `items`, `maxLength` and `additionalProperties` (a boolean or a
//! schema). The annotations `description`, `title`, `default`, `examples`, `deprecated`, `readOnly`, `writeOnly`,
//! `$schema` and `$comment` are accepted and ignored. Any other keyword is refused by [`check_schema`], so a schema
//! never promises a check that does not happen.

use serde_json::Value;

#[cfg(test)]
mod tests;

const ANNOTATIONS: &[&str] = &[
    "description",
    "title",
    "default",
    "examples",
    "deprecated",
    "readOnly",
    "writeOnly",
    "$schema",
    "$comment",
];
const CHECKED: &[&str] = &[
    "type",
    "properties",
    "required",
    "enum",
    "items",
    "maxLength",
    "additionalProperties",
];
const TYPES: &[&str] = &[
    "object", "string", "integer", "number", "boolean", "array", "null",
];

/// Where a value fails its schema (`items[2].name`; `arguments` for the whole) and what is wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SchemaError {
    pub path: String,
    pub message: String,
}

fn err(path: &str, message: impl Into<String>) -> SchemaError {
    SchemaError {
        path: path.to_owned(),
        message: message.into(),
    }
}

fn child(path: &str, key: &str) -> String {
    if path.is_empty() {
        key.to_owned()
    } else {
        format!("{path}.{key}")
    }
}

/// Whether SCHEMA only uses what [`check`] checks, or an annotation; the error's path is the subschema at fault.
pub fn check_schema(schema: &Value) -> Result<(), SchemaError> {
    schema_at(schema, "")
}

fn schema_at(schema: &Value, path: &str) -> Result<(), SchemaError> {
    let Value::Object(m) = schema else {
        return Err(err(path, "a schema is an object"));
    };
    for (k, v) in m {
        let k = k.as_str();
        if ANNOTATIONS.contains(&k) {
            continue;
        }
        if !CHECKED.contains(&k) {
            return Err(err(
                path,
                format!(
                    "the keyword `{k}` is not one the checker checks (allowed: {})",
                    CHECKED.join(", ")
                ),
            ));
        }
        match k {
            "type" => match v.as_str() {
                Some(t) if TYPES.contains(&t) => {}
                _ => return Err(err(path, format!("`type` is one of {}", TYPES.join(", ")))),
            },
            "properties" => {
                let Some(props) = v.as_object() else {
                    return Err(err(path, "`properties` is an object"));
                };
                for (name, sub) in props {
                    schema_at(sub, &child(&child(path, "properties"), name))?;
                }
            }
            "required" => {
                if !v.as_array().is_some_and(|a| a.iter().all(Value::is_string)) {
                    return Err(err(path, "`required` is a list of names"));
                }
            }
            "enum" => {
                if !v.is_array() {
                    return Err(err(path, "`enum` is a list"));
                }
            }
            "items" => schema_at(v, &child(path, "items"))?,
            "maxLength" => {
                if v.as_u64().is_none() {
                    return Err(err(path, "`maxLength` is a whole number"));
                }
            }
            _ => {
                if !v.is_boolean() {
                    schema_at(v, &child(path, "additionalProperties"))?;
                }
            }
        }
    }
    Ok(())
}

/// VALUE against SCHEMA (which [`check_schema`] accepted): the first failure, at its path.
pub fn check(schema: &Value, value: &Value) -> Result<(), SchemaError> {
    value_at(schema, value, "", "arguments")
}

/// `path` is the JSON path of VALUE ("" at the root); `shown` is how an error at the root names it.
fn value_at(schema: &Value, value: &Value, path: &str, shown: &str) -> Result<(), SchemaError> {
    let at = if path.is_empty() { shown } else { path };
    let Some(m) = schema.as_object() else {
        return Ok(());
    };
    if let Some(t) = m.get("type").and_then(Value::as_str) {
        let ok = match t {
            "object" => value.is_object(),
            "string" => value.is_string(),
            "boolean" => value.is_boolean(),
            "array" => value.is_array(),
            "null" => value.is_null(),
            "integer" => {
                value.is_i64() || value.is_u64() || value.as_f64().is_some_and(|f| f.fract() == 0.0)
            }
            _ => value.is_number(),
        };
        if !ok {
            return Err(err(at, format!("expected {t}")));
        }
    }
    if let Some(Value::Array(allowed)) = m.get("enum")
        && !allowed.contains(value)
    {
        return Err(err(at, "not one of the allowed values"));
    }
    if let (Some(max), Some(s)) = (m.get("maxLength").and_then(Value::as_u64), value.as_str())
        && s.chars().count() as u64 > max
    {
        return Err(err(at, format!("longer than {max} characters")));
    }
    if let Value::Object(obj) = value {
        if let Some(Value::Array(req)) = m.get("required") {
            for k in req.iter().filter_map(Value::as_str) {
                if !obj.contains_key(k) {
                    return Err(err(&child(path, k), "required, missing"));
                }
            }
        }
        let props = m.get("properties").and_then(Value::as_object);
        for (k, v) in obj {
            let p = child(path, k);
            match (props.and_then(|p| p.get(k)), m.get("additionalProperties")) {
                (Some(sub), _) => value_at(sub, v, &p, shown)?,
                (None, Some(Value::Bool(false))) => return Err(err(&p, "unknown key")),
                (None, Some(sub @ Value::Object(_))) => value_at(sub, v, &p, shown)?,
                _ => {}
            }
        }
    }
    if let (Value::Array(items), Some(sub)) = (value, m.get("items")) {
        for (i, v) in items.iter().enumerate() {
            value_at(sub, v, &format!("{path}[{i}]"), shown)?;
        }
    }
    Ok(())
}
