//! The tools a server serves, and [`typed`], the typed arguments a tool's schema and check come from.

use std::fmt;
use std::future::Future;
use std::marker::PhantomData;
use std::pin::Pin;

use schemars::JsonSchema;
use serde::de::DeserializeOwned;
use serde_json::Value;

/// A boxed, sendable future (no `futures` crate in the workspace).
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// One MCP tool, called with the server's context.
pub trait Tool<Ctx>: Send + Sync {
    /// 1–128 characters of `A-Za-z0-9_-.` (MCP tool-name guidance; [`valid_name`]).
    fn name(&self) -> &'static str;
    fn description(&self) -> &'static str;
    /// From schemars; unknown keys denied ([`Typed::schema`]).
    fn input_schema(&self) -> Value;
    fn output_schema(&self) -> Option<Value> {
        None
    }
    /// The arguments' check, which the server runs before [`Tool::call`]. A failure is answered as a tool error
    /// with its path (`isError`, `_meta["dev.drgnx/error"]`), and `call` never runs. A tool with typed arguments
    /// returns `typed::<Args>().check(args)`; the default accepts anything, so a tool that takes arguments must
    /// override it.
    fn check(&self, args: &Value) -> Result<(), ArgsError> {
        let _ = args;
        Ok(())
    }
    fn call<'a>(&'a self, ctx: &'a Ctx, args: Value) -> BoxFuture<'a, ToolResult>;
}

/// What a tool's call ends with.
pub enum ToolResult {
    Ok {
        text: String,
        structured: Option<Value>,
    },
    Err(String),
}

/// Arguments that do not fit a tool's types: where (`text`, `items[2].name`; `arguments` for the whole) and what is
/// wrong.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArgsError {
    pub path: String,
    pub message: String,
}

impl fmt::Display for ArgsError {
    /// `PATH: what is wrong`, the text of the tool error (design §4.6 item 7).
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.path, self.message)
    }
}

/// The path of an error about the arguments as a whole.
pub const ROOT: &str = "arguments";

/// Whether NAME is a tool name MCP's guidance allows: 1–128 characters of `A-Za-z0-9_-.`.
pub fn valid_name(name: &str) -> bool {
    (1..=128).contains(&name.len())
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
}

/// A tool's typed arguments `A`: their input schema and their decode, which is the check (library evaluation §17:
/// "typed decode *is* the check").
pub struct Typed<A>(PhantomData<fn() -> A>);

impl<A> Clone for Typed<A> {
    fn clone(&self) -> Self {
        *self
    }
}

impl<A> Copy for Typed<A> {}

/// The typed arguments `A` of a tool: `typed::<Args>().schema()` is its `inputSchema`, `.check(args)` its
/// [`Tool::check`] and `.decode(args)` what its `call` starts with.
pub fn typed<A: DeserializeOwned + JsonSchema>() -> Typed<A> {
    Typed(PhantomData)
}

impl<A: DeserializeOwned + JsonSchema> Typed<A> {
    /// `A`'s JSON Schema (2020-12, schemars's default and MCP's since 2025-11-25), closed: every object schema
    /// gets `additionalProperties: false` unless it says otherwise, as the decode refuses unknown
    /// keys. The top's `$schema` and `title` are left out (2020-12 is MCP's default dialect), and so are an empty
    /// `properties` and `required`: a tool with no arguments is `{"type": "object", "additionalProperties": false}`.
    pub fn schema(&self) -> Value {
        let mut schema = Value::from(schemars::schema_for!(A));
        close(&mut schema);
        if let Value::Object(m) = &mut schema {
            m.remove("$schema");
            m.remove("title");
            if m.get("properties")
                .is_some_and(|p| p.as_object().is_some_and(|p| p.is_empty()))
            {
                m.remove("properties");
            }
            if m.get("required")
                .is_some_and(|r| r.as_array().is_some_and(|r| r.is_empty()))
            {
                m.remove("required");
            }
        }
        schema
    }

    /// ARGS as an `A`, through `serde_path_to_error` with unknown keys refused (contract Task 10: "MCP refuses
    /// unknown keys"): an unknown key is `PATH: unknown key`, a missing one `PATH: required, missing`, anything else
    /// serde's message at its path.
    pub fn decode(&self, args: &Value) -> Result<A, ArgsError> {
        match runstav::decode::typed::<A>(args) {
            Ok((a, ignored)) => match ignored.into_iter().min() {
                Some(path) => Err(ArgsError {
                    path,
                    message: "unknown key".into(),
                }),
                None => Ok(a),
            },
            Err(e) => Err(args_error(e.path, &e.message)),
        }
    }

    /// [`Typed::decode`], the value dropped: what [`Tool::check`] returns.
    pub fn check(&self, args: &Value) -> Result<(), ArgsError> {
        self.decode(args).map(drop)
    }
}

/// serde's error AT (the part being decoded) as an [`ArgsError`]; a missing or unknown field (with
/// `deny_unknown_fields`) gets the field's own path.
fn args_error(at: Option<String>, message: &str) -> ArgsError {
    let field = |prefix: &str| {
        message
            .strip_prefix(prefix)
            .and_then(|rest| rest.split('`').next())
            .map(|k| match &at {
                Some(p) => format!("{p}.{k}"),
                None => k.to_string(),
            })
    };
    if let Some(path) = field("missing field `") {
        return ArgsError {
            path,
            message: "required, missing".into(),
        };
    }
    // serde_path_to_error's path to an unknown field already ends at the field itself
    if let Some(path) = field("unknown field `") {
        let ends_at_key = |p: &String, k: &str| p == k || p.ends_with(&format!(".{k}"));
        let path = match (&at, path.rsplit_once('.')) {
            (Some(p), Some((_, k))) if ends_at_key(p, k) => p.clone(),
            _ => path,
        };
        return ArgsError {
            path,
            message: "unknown key".into(),
        };
    }
    ArgsError {
        path: at.unwrap_or_else(|| ROOT.into()),
        message: message.to_string(),
    }
}

/// Close every object schema (`properties`, or `type: object`) that does not say whether it takes other keys (a
/// map's schema does: its `additionalProperties` is the value's schema), walking only the
/// places a JSON Schema holds subschemas (so a property named `properties` is never taken for a keyword).
fn close(schema: &mut Value) {
    let Value::Object(m) = schema else { return };
    let object = m.contains_key("properties") || m.get("type").is_some_and(|t| t == "object");
    if object && !m.contains_key("additionalProperties") {
        m.insert("additionalProperties".into(), Value::Bool(false));
    }
    for key in ["properties", "patternProperties", "$defs", "definitions"] {
        if let Some(Value::Object(subs)) = m.get_mut(key) {
            subs.values_mut().for_each(close);
        }
    }
    for key in ["anyOf", "oneOf", "allOf", "prefixItems"] {
        if let Some(Value::Array(subs)) = m.get_mut(key) {
            subs.iter_mut().for_each(close);
        }
    }
    for key in ["items", "additionalProperties", "not", "if", "then", "else"] {
        if let Some(sub) = m.get_mut(key) {
            close(sub);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use serde_json::json;

    #[derive(Deserialize, JsonSchema)]
    #[allow(dead_code)]
    struct Item {
        name: String,
    }

    #[derive(Deserialize, JsonSchema)]
    #[allow(dead_code)]
    struct Args {
        text: String,
        #[serde(default)]
        items: Vec<Item>,
    }

    #[derive(Deserialize, JsonSchema)]
    #[serde(deny_unknown_fields)]
    #[allow(dead_code)]
    struct Strict {
        n: u32,
    }

    #[derive(Deserialize, JsonSchema)]
    struct NoArgs {}

    #[test]
    fn names_follow_the_guidance() {
        assert!(valid_name("report_edit"));
        assert!(valid_name("a.b-c_9"));
        assert!(valid_name(&"x".repeat(128)));
        assert!(!valid_name(""));
        assert!(!valid_name(&"x".repeat(129)));
        assert!(!valid_name("no spaces"));
        assert!(!valid_name("mcp/slash"));
    }

    #[test]
    fn the_schema_is_closed_at_every_object() {
        let s = typed::<Args>().schema();
        assert_eq!(s["type"], "object");
        assert_eq!(s["additionalProperties"], false);
        assert_eq!(s["properties"]["text"]["type"], "string");
        assert_eq!(s["required"], json!(["text"]));
        assert!(s.get("$schema").is_none() && s.get("title").is_none());
        // Item is a definition or inline; either way it is closed
        let item = s["$defs"]
            .get("Item")
            .unwrap_or(&s["properties"]["items"]["items"]);
        assert_eq!(item["additionalProperties"], false, "{s}");
        assert_eq!(
            typed::<NoArgs>().schema(),
            json!({"type": "object", "additionalProperties": false})
        );
    }

    #[test]
    fn decode_gives_the_path_of_what_is_wrong() {
        let t = typed::<Args>();
        assert!(t.check(&json!({"text": "hi"})).is_ok());
        let e = |v: Value| t.check(&v).unwrap_err();
        assert_eq!(
            e(json!({"text": 3})).path,
            "text",
            "a wrong type is at its key"
        );
        assert_eq!(
            e(json!({})),
            ArgsError {
                path: "text".into(),
                message: "required, missing".into()
            }
        );
        assert_eq!(
            e(json!({"text": "a", "extra": 1})),
            ArgsError {
                path: "extra".into(),
                message: "unknown key".into()
            }
        );
        assert_eq!(
            e(json!({"text": "a", "items": [{"name": "x"}, {}]})).path,
            "items[1].name"
        );
        assert_eq!(
            e(json!({"text": "a", "items": [{"name": "x", "q": 1}]})).path,
            "items[0].q"
        );
        assert_eq!(
            typed::<Strict>()
                .check(&json!({"n": 1, "m": 2}))
                .unwrap_err(),
            ArgsError {
                path: "m".into(),
                message: "unknown key".into()
            }
        );
        assert_eq!(e(json!("not an object")).path, ROOT);
        assert_eq!(
            e(json!({"text": 3})).to_string(),
            "text: invalid type: integer `3`, expected a string"
        );
    }
}
