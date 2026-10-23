//! The contract's named input types (docs/develop/hub.md, "Types").  Each validates as it decodes: a value that does
//! not fit is refused with its path (`decode::typed`), never rewritten.  Each has a JSON Schema with the same
//! `pattern` / `maxLength`, so `methods.json` says what the hub checks.  Lengths count characters (Unicode scalar
//! values), as JSON Schema's `maxLength` does.

use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use secrecy::{ExposeSecret, SecretString};
use serde::de::{self, Deserializer, MapAccess, Visitor};
use serde::ser::{SerializeMap, Serializer};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt;

/// A JSON `null` (or nothing) where a list is expected, as `[]` (A-17: the job UI and the events still send `null`
/// for an empty list).  On every `Vec` of a result or event type, with `#[serde(default)]`.
pub fn null_as_empty<'de, D, T>(d: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Ok(Option::<Vec<T>>::deserialize(d)?.unwrap_or_default())
}

fn chars(s: &str) -> usize {
    s.chars().count()
}

/// A named string type: a newtype over `String` that checks `$ok` and its length, with the same rule as a schema.
macro_rules! named_string {
    ($(#[$m:meta])* $name:ident, max: $max:expr, pattern: $pattern:expr, ok: $ok:expr, what: $what:literal) => {
        $(#[$m])*
        #[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            /// The longest value, in characters.
            pub const MAX: usize = $max;
            /// What a value must be, as the refusal says it.
            pub const WHAT: &'static str = $what;

            /// `s` when it fits, else what is wrong.
            pub fn new(s: impl Into<String>) -> Result<Self, String> {
                let s = s.into();
                let ok: fn(&str) -> bool = $ok;
                if chars(&s) > Self::MAX || !ok(&s) {
                    return Err(format!("not {}", Self::WHAT));
                }
                Ok(Self(s))
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
                Self::new(String::deserialize(d)?).map_err(de::Error::custom)
            }
        }

        impl JsonSchema for $name {
            fn schema_name() -> Cow<'static, str> {
                stringify!($name).into()
            }

            fn json_schema(_: &mut SchemaGenerator) -> Schema {
                let mut s = json_schema!({"type": "string", "maxLength": $max, "description": $what});
                let p: Option<&str> = $pattern;
                if let Some(p) = p {
                    s.insert("pattern".into(), p.into());
                }
                s
            }
        }
    };
}

fn ascii_alnum(c: char) -> bool {
    c.is_ascii_alphanumeric()
}

fn lower_hex(s: &str, n: usize) -> bool {
    s.len() == n
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn no_control(s: &str) -> bool {
    !s.chars().any(|c| c <= '\u{1f}' || c == '\u{7f}')
}

/// `^/[^/:\0]*(/[^\0]*)?$`: absolute, no NUL, and no `:` in the first component (a TRAMP name is refused).
pub fn is_abs_path(s: &str) -> bool {
    let Some(rest) = s.strip_prefix('/') else {
        return false;
    };
    let first = rest.split('/').next().unwrap_or("");
    !first.contains(':') && !s.contains('\0')
}

named_string!(
    /// An id: ASCII letters, digits and `._:+-` (not first), at most 128.
    Id, max: 128, pattern: Some("^[A-Za-z0-9][A-Za-z0-9._:+-]*$"),
    ok: |s| {
        let mut cs = s.chars();
        cs.next().is_some_and(ascii_alnum)
            && cs.all(|c| ascii_alnum(c) || matches!(c, '.' | '_' | ':' | '+' | '-'))
    },
    what: "an id: ASCII letters, digits and ._:+- (not first), at most 128"
);

named_string!(
    /// An absolute local path: no NUL, at most 4096, never a remote (TRAMP) name.
    AbsPath, max: 4096, pattern: Some("^/[^/:\\u0000]*(/[^\\u0000]*)?$"),
    ok: is_abs_path,
    what: "an absolute local path: no NUL, at most 4096, never a remote (TRAMP) name"
);

named_string!(
    /// An environment variable's name.
    EnvName, max: 128, pattern: Some("^[A-Za-z_][A-Za-z0-9_]*$"),
    ok: |s| {
        let mut cs = s.chars();
        cs.next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
            && cs.all(|c| c.is_ascii_alphanumeric() || c == '_')
    },
    what: "an environment variable's name: ASCII letters, digits and _ (not a digit first), at most 128"
);

named_string!(
    /// A prompt or a message: at most 1 MiB.
    Prompt, max: 1_048_576, pattern: None, ok: |_| true,
    what: "a prompt or a message: at most 1 MiB (1048576 characters)"
);

named_string!(
    /// A text of at most 64 KiB.
    Text, max: 65_536, pattern: None, ok: |_| true,
    what: "a text: at most 64 KiB (65536 characters)"
);

named_string!(
    /// 32 lowercase hex digits.
    Nonce, max: 32, pattern: Some("^[0-9a-f]{32}$"), ok: |s| lower_hex(s, 32),
    what: "a nonce: 32 lowercase hex digits"
);

named_string!(
    /// 64 lowercase hex digits (an HMAC-SHA256).
    Hex64, max: 64, pattern: Some("^[0-9a-f]{64}$"), ok: |s| lower_hex(s, 64),
    what: "64 lowercase hex digits"
);

named_string!(
    /// A task: a job's (`JOB#N`) or the work tracker's; no control characters.
    TaskRef, max: 512, pattern: Some("^[^\\u0000-\\u001f\\u007f]+$"),
    ok: |s| !s.is_empty() && no_control(s),
    what: "a task: no control characters, 1 to 512 characters"
);

named_string!(
    /// An agent as the gateway records it (a session's name); no control characters.
    AgentName, max: 256, pattern: Some("^[^\\u0000-\\u001f\\u007f]*$"), ok: no_control,
    what: "an agent's name: no control characters, at most 256"
);

named_string!(
    /// A card's action: a new one needs no schema change.
    CardAction, max: 32, pattern: Some("^[a-z][a-z-]*$"),
    ok: |s| {
        let mut cs = s.chars();
        cs.next().is_some_and(|c| c.is_ascii_lowercase())
            && cs.all(|c| c.is_ascii_lowercase() || c == '-')
    },
    what: "a card's action: lowercase letters and -, a letter first, at most 32"
);

named_string!(
    /// A job's, task's or card's state as the coordination store keeps it (`running`, `needs-input`, `settled`, …).
    Status, max: 32, pattern: Some("^[a-z][a-z-]*$"),
    ok: |s| {
        let mut cs = s.chars();
        cs.next().is_some_and(|c| c.is_ascii_lowercase())
            && cs.all(|c| c.is_ascii_lowercase() || c == '-')
    },
    what: "a status: lowercase letters and -, a letter first, at most 32"
);

/// A JSON object of at most 64 KiB as JSON text (an event's, a card's or a job's `data`).  The store keeps it as the
/// JSON it is; what is inside is the writer's and its reader's business.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(transparent)]
pub struct JsonObject(serde_json::Map<String, Value>);

impl JsonObject {
    /// The most bytes of JSON text.
    pub const MAX: usize = 65_536;

    pub fn into_inner(self) -> serde_json::Map<String, Value> {
        self.0
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.0.get(key)
    }
}

impl<'de> Deserialize<'de> for JsonObject {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let m = serde_json::Map::<String, Value>::deserialize(d)?;
        let n = serde_json::to_string(&m).map_or(usize::MAX, |t| t.len());
        if n > Self::MAX {
            return Err(de::Error::custom(format!(
                "a JSON object of at most 64 KiB (65536 bytes as JSON), not {n}"
            )));
        }
        Ok(JsonObject(m))
    }
}

impl JsonSchema for JsonObject {
    fn schema_name() -> Cow<'static, str> {
        "JsonObject".into()
    }
    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "object",
                      "description": "a JSON object: at most 64 KiB (65536 bytes as JSON)"})
    }
}

/// What `Bounded` bounds: a string's characters or a list's items.
pub trait Bound {
    /// The JSON Schema keyword of the bound (`maxLength`, `maxItems`).
    const KEYWORD: &'static str;
    /// What is counted, for the refusal.
    const UNIT: &'static str;
    fn count(&self) -> usize;
}

impl Bound for String {
    const KEYWORD: &'static str = "maxLength";
    const UNIT: &'static str = "characters";
    fn count(&self) -> usize {
        chars(self)
    }
}

impl<T> Bound for Vec<T> {
    const KEYWORD: &'static str = "maxItems";
    const UNIT: &'static str = "items";
    fn count(&self) -> usize {
        self.len()
    }
}

/// A string or a list of at most `MAX` (every `:max` of the contract's schemas, such as `env/set`'s 16).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(transparent)]
pub struct Bounded<T, const MAX: usize>(pub T);

impl<T, const MAX: usize> Bounded<T, MAX> {
    pub fn into_inner(self) -> T {
        self.0
    }
}

impl<T, const MAX: usize> std::ops::Deref for Bounded<T, MAX> {
    type Target = T;
    fn deref(&self) -> &T {
        &self.0
    }
}

impl<'de, T: Deserialize<'de> + Bound, const MAX: usize> Deserialize<'de> for Bounded<T, MAX> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let t = T::deserialize(d)?;
        let n = t.count();
        if n > MAX {
            return Err(de::Error::custom(format!(
                "at most {MAX} {}, not {n}",
                T::UNIT
            )));
        }
        Ok(Bounded(t))
    }
}

impl<T: JsonSchema + Bound, const MAX: usize> JsonSchema for Bounded<T, MAX> {
    fn inline_schema() -> bool {
        true
    }

    fn schema_name() -> Cow<'static, str> {
        format!("{}_at_most_{MAX}", T::schema_name()).into()
    }

    fn json_schema(g: &mut SchemaGenerator) -> Schema {
        let mut s = T::json_schema(g);
        s.insert(T::KEYWORD.into(), MAX.into());
        s
    }
}

/// An amount of US dollars: a number in 0..=1000000.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(transparent)]
pub struct Usd(f64);

impl Usd {
    pub const MAX: f64 = 1_000_000.0;
    pub fn get(self) -> f64 {
        self.0
    }
}

impl<'de> Deserialize<'de> for Usd {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = f64::deserialize(d)?;
        if !(0.0..=Self::MAX).contains(&v) {
            return Err(de::Error::custom(
                "not an amount of US dollars: a number in 0..=1000000",
            ));
        }
        Ok(Usd(v))
    }
}

impl JsonSchema for Usd {
    fn schema_name() -> Cow<'static, str> {
        "Usd".into()
    }
    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "number", "minimum": 0, "maximum": 1_000_000,
                      "description": "an amount of US dollars"})
    }
}

/// A job's run-order change: an integer in -1000..=1000.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct Delta(i64);

impl Delta {
    pub fn get(self) -> i64 {
        self.0
    }
}

impl<'de> Deserialize<'de> for Delta {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = i64::deserialize(d)?;
        if !(-1000..=1000).contains(&v) {
            return Err(de::Error::custom("not a delta: an integer in -1000..=1000"));
        }
        Ok(Delta(v))
    }
}

impl JsonSchema for Delta {
    fn schema_name() -> Cow<'static, str> {
        "Delta".into()
    }
    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "integer", "minimum": -1000, "maximum": 1000,
                      "description": "a move in a job's run order"})
    }
}

/// A permission request's or a review's id: a natural number or a string of at most 128.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum RequestId {
    Num(u64),
    Str(String),
}

impl<'de> Deserialize<'de> for RequestId {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        match Value::deserialize(d)? {
            Value::Number(n) if n.as_u64().is_some() => Ok(RequestId::Num(n.as_u64().unwrap())),
            Value::String(s) if chars(&s) <= 128 => Ok(RequestId::Str(s)),
            _ => Err(de::Error::custom(
                "not a request id: a natural number or a string of at most 128",
            )),
        }
    }
}

impl JsonSchema for RequestId {
    fn schema_name() -> Cow<'static, str> {
        "RequestId".into()
    }
    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"anyOf": [{"type": "integer", "minimum": 0}, {"type": "string", "maxLength": 128}],
                      "description": "a permission request's or a review's id"})
    }
}

/// `job/card`'s `arg`: a string of at most 4096 or a number.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(untagged)]
pub enum StringOrNumber {
    Str(String),
    Num(serde_json::Number),
}

impl<'de> Deserialize<'de> for StringOrNumber {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        match Value::deserialize(d)? {
            Value::Number(n) => Ok(StringOrNumber::Num(n)),
            Value::String(s) if chars(&s) <= 4096 => Ok(StringOrNumber::Str(s)),
            _ => Err(de::Error::custom(
                "not a card's argument: a string of at most 4096 or a number",
            )),
        }
    }
}

impl JsonSchema for StringOrNumber {
    fn schema_name() -> Cow<'static, str> {
        "StringOrNumber".into()
    }
    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"anyOf": [{"type": "string", "maxLength": 4096}, {"type": "number"}]})
    }
}

/// Provider id → key: at most 32, each at most 4096.  Kept secret: no `Debug`, and the only serialisation is the
/// re-encode of a method's params for the backend link (Task 15), which must carry the keys.
pub struct ProviderKeys(BTreeMap<Id, SecretString>);

impl ProviderKeys {
    pub const MAX_KEYS: usize = 32;
    pub const MAX_KEY: usize = 4096;

    /// The providers named (not their keys).
    pub fn providers(&self) -> impl Iterator<Item = &Id> {
        self.0.keys()
    }

    /// Provider → key.
    pub fn iter(&self) -> impl Iterator<Item = (&Id, &SecretString)> {
        self.0.iter()
    }
}

impl Serialize for ProviderKeys {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut m = s.serialize_map(Some(self.0.len()))?;
        for (k, v) in &self.0 {
            m.serialize_entry(k, v.expose_secret())?;
        }
        m.end()
    }
}

impl<'de> Deserialize<'de> for ProviderKeys {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = ProviderKeys;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("an object of provider id → key")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut a: A) -> Result<ProviderKeys, A::Error> {
                let mut out = BTreeMap::new();
                while let Some(k) = a.next_key::<Id>()? {
                    let v: String = a.next_value()?;
                    if chars(&v) > ProviderKeys::MAX_KEY {
                        return Err(de::Error::custom("a key is at most 4096 characters"));
                    }
                    if out.insert(k, SecretString::from(v)).is_some() {
                        return Err(de::Error::custom("a provider is named twice"));
                    }
                    if out.len() > ProviderKeys::MAX_KEYS {
                        return Err(de::Error::custom("at most 32 keys"));
                    }
                }
                Ok(ProviderKeys(out))
            }
        }
        d.deserialize_map(V)
    }
}

impl JsonSchema for ProviderKeys {
    fn schema_name() -> Cow<'static, str> {
        "ProviderKeys".into()
    }
    fn json_schema(g: &mut SchemaGenerator) -> Schema {
        let id = g.subschema_for::<Id>();
        json_schema!({"type": "object", "maxProperties": 32, "propertyNames": id,
                      "additionalProperties": {"type": "string", "maxLength": 4096},
                      "description": "provider id → key"})
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn path_of<T: serde::de::DeserializeOwned>(v: Value) -> Option<String> {
        crate::decode::typed::<T>(&v).err().and_then(|e| e.path)
    }

    #[derive(Debug, Deserialize)]
    #[allow(dead_code)]
    struct One<T> {
        x: T,
    }

    /// `{"x": v}` as a `T` fails at `x` (or inside it: a provider's bad id is `x.a b`); `good` passes.
    fn refuses<T: serde::de::DeserializeOwned>(bad: Value, good: Value) {
        let path = path_of::<One<T>>(json!({ "x": bad.clone() })).unwrap_or_default();
        assert!(
            path == "x" || path.starts_with("x."),
            "{bad} should be refused at x, not at {path:?}"
        );
        assert!(
            crate::decode::typed::<One<T>>(&json!({ "x": good.clone() })).is_ok(),
            "{good} should pass"
        );
    }

    #[test]
    fn named_types_refuse() {
        let long_id = "a".repeat(129);
        refuses::<Id>(json!("a b"), json!("a.b"));
        refuses::<Id>(json!(long_id), json!("a".repeat(128)));
        refuses::<Id>(json!("-x"), json!("x-"));
        refuses::<AbsPath>(json!("x/y"), json!("/x/y"));
        refuses::<AbsPath>(json!("/ssh:canary:/x"), json!("/a/b:c"));
        refuses::<AbsPath>(json!("/a\u{0}b"), json!("/ab"));
        refuses::<EnvName>(json!("1X"), json!("_X1"));
        refuses::<Nonce>(
            json!("0123456789ABCDEF0123456789abcdef"),
            json!("0123456789abcdef0123456789abcdef"),
        );
        refuses::<Nonce>(
            json!("0123456789abcdef0123456789abcde"),
            json!("0123456789abcdef0123456789abcdef"),
        );
        refuses::<Hex64>(json!("0".repeat(63)), json!("0".repeat(64)));
        refuses::<Prompt>(json!("p".repeat(1_048_577)), json!("p".repeat(1_048_576)));
        refuses::<Text>(json!("t".repeat(65_537)), json!("t".repeat(65_536)));
        refuses::<TaskRef>(json!("a\nb"), json!("JOB-1#2"));
        refuses::<TaskRef>(json!(""), json!("t"));
        refuses::<AgentName>(json!("a\u{7f}"), json!("Agent 7"));
        refuses::<CardAction>(json!("Approve"), json!("approve-all"));
        refuses::<Status>(json!("In-review"), json!("needs-input"));
        refuses::<JsonObject>(json!([1]), json!({"a": [1, {"b": null}]}));
        refuses::<JsonObject>(
            json!({"t": "x".repeat(65_536)}),
            json!({"t": "x".repeat(65_000)}),
        );
        refuses::<RequestId>(json!(-1), json!(3));
        refuses::<RequestId>(json!("r".repeat(129)), json!("r1"));
        refuses::<Usd>(json!(1_000_001), json!(0.5));
        refuses::<Usd>(json!(-0.01), json!(1_000_000));
        refuses::<Delta>(json!(1001), json!(-1000));
        refuses::<StringOrNumber>(json!(true), json!(2));
        refuses::<Bounded<String, 3>>(json!("abcd"), json!("abc"));
        refuses::<Bounded<Vec<u8>, 2>>(json!([1, 2, 3]), json!([1, 2]));
        refuses::<ProviderKeys>(json!({"a b": "k"}), json!({"openrouter": "k"}));
        refuses::<ProviderKeys>(
            json!({"p": "k".repeat(4097)}),
            json!({"p": "k".repeat(4096)}),
        );
        let many: serde_json::Map<String, Value> =
            (0..33).map(|i| (format!("p{i}"), json!("k"))).collect();
        refuses::<ProviderKeys>(Value::Object(many), json!({}));

        // env/set: at most 16, and PATH a list of absolute directories (the method's own check)
        let env_set = crate::registry::find("env/set").unwrap();
        let var = |name: &str, value: &str| json!({"name": name, "value": value});
        let at = |v: Value| (env_set.decode)(&v).err().and_then(|e| e.path);
        assert_eq!(
            at(json!({"env": vec![var("A", "1"); 17]})).as_deref(),
            Some("env")
        );
        assert_eq!(at(json!({"env": vec![var("A", "1"); 16]})), None);
        assert_eq!(
            at(json!({"env": [var("A", "1"), var("PATH", "bin:/usr/bin")]})).as_deref(),
            Some("env[1].value")
        );
        assert_eq!(
            at(json!({"env": [var("MANPATH", "/a::/b")]})).as_deref(),
            Some("env[0].value")
        );
        assert_eq!(
            at(json!({"env": [var("PATH", "/usr/local/bin:/usr/bin")]})),
            None
        );
        assert_eq!(at(json!({"env": [var("LANG", "C:x")]})), None);
        assert_eq!(
            at(json!({"env": [var("1X", "v")]})).as_deref(),
            Some("env[0].name")
        );
    }

    #[test]
    fn a_refusal_names_the_rule() {
        let e = crate::decode::typed::<One<Id>>(&json!({"x": "a b"})).unwrap_err();
        assert!(e.message.contains("an id"), "{e:?}");
        let e =
            crate::decode::typed::<One<Bounded<Vec<u8>, 2>>>(&json!({"x": [1, 2, 3]})).unwrap_err();
        assert!(e.message.contains("at most 2 items, not 3"), "{e:?}");
    }

    #[test]
    fn provider_keys_serialise_only_their_keys() {
        let (k, _) =
            crate::decode::typed::<ProviderKeys>(&json!({"openrouter": "sk-canary"})).unwrap();
        assert_eq!(
            k.providers().map(Id::as_str).collect::<Vec<_>>(),
            ["openrouter"]
        );
        // the backend link's re-encode carries the key as it came
        assert_eq!(
            serde_json::to_value(&k).unwrap(),
            json!({"openrouter": "sk-canary"})
        );
    }

    #[test]
    fn null_lists_decode_as_empty() {
        #[derive(Deserialize)]
        struct L {
            #[serde(default, deserialize_with = "null_as_empty")]
            v: Vec<u8>,
        }
        let l: L = serde_json::from_value(json!({"v": null})).unwrap();
        assert!(l.v.is_empty());
        let l: L = serde_json::from_value(json!({})).unwrap();
        assert!(l.v.is_empty());
        let l: L = serde_json::from_value(json!({"v": [1]})).unwrap();
        assert_eq!(l.v, [1]);
    }
}
