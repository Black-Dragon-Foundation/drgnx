//! The registry: every method of the hub protocol with its classes, its params and result types (and so their JSON
//! Schemas), whether it writes work.db, and a line of doc (design 4.3).  `runtime/protocol/methods.json` and the
//! method table in `docs/develop/hub.md` are generated from it, and tests fail when either is out of date
//! (`UPDATE_METHODS_JSON=1 cargo test -p runstav registry` rewrites both).

use crate::decode;
use crate::events::events;
use crate::methods::{self, Params};
use crate::wire::{Error, ErrorCode};
use schemars::generate::SchemaSettings;
use schemars::{JsonSchema, Schema};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::sync::LazyLock;

/// The protocol this hub speaks, and the oldest it still serves.
pub const PROTO: u32 = 1;
pub const PROTO_MIN: u32 = 1;
/// The records layout: 2 is JSON (design 4.5).
pub const RECORDS: u32 = 2;
/// The work.db schema this code knows.
pub const SCHEMA: u32 = 6;

/// What a connection proved (design 4.2): `user` a valid `hello` proof, `agent` the agent socket it came in on,
/// `service` nothing.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Deserialize, Serialize, JsonSchema,
)]
#[serde(rename_all = "lowercase")]
pub enum Class {
    User,
    Agent,
    Service,
}

impl Class {
    pub fn name(self) -> &'static str {
        match self {
            Class::User => "user",
            Class::Agent => "agent",
            Class::Service => "service",
        }
    }
}

/// Which side serves a method, or sends an event (docs/develop/hub.md, "Ratatoskr and the Lisp backend"): the front
/// (Ratatoskr itself) or the Lisp backend behind it.  The backend may call only `Front` methods (the seam rule), so
/// the front never waits on the backend while it serves the backend.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Home {
    Front,
    Backend,
}

impl Home {
    pub fn name(self) -> &'static str {
        match self {
            Home::Front => "front",
            Home::Backend => "backend",
        }
    }
}

/// A method's params, decoded, and the dotted paths of the keys it dropped (the answer's `ignored`).
pub type Decoded = (Params, Vec<String>);

/// One method.
pub struct Method {
    pub name: &'static str,
    /// The classes that may call it.
    pub classes: &'static [Class],
    /// It writes work.db, so a read-only hub refuses it (`schema`).
    pub writes: bool,
    /// Who serves it.
    pub home: Home,
    pub doc: &'static str,
    pub params: fn() -> Schema,
    pub result: fn() -> Schema,
    /// The typed params and the dotted paths of the keys dropped; a bad value is `invalid-params` with its path.
    pub decode: fn(&Value) -> Result<Decoded, Error>,
    /// A result decoded into the result type and encoded again: strict, so an unknown key is an error with its
    /// path (the registry stays complete), and a `null` list comes out `[]`.
    pub check_result: fn(&Value) -> Result<Value, Error>,
}

impl Method {
    pub fn allows(&self, class: Class) -> bool {
        self.classes.contains(&class)
    }
}

static REGISTRY: LazyLock<Vec<Method>> = LazyLock::new(|| {
    let mut v = methods::all();
    v.sort_by_key(|m| m.name);
    v
});

/// Every method, sorted by name.
pub fn registry() -> &'static [Method] {
    &REGISTRY
}

/// The method called `name`.
pub fn find(name: &str) -> Option<&'static Method> {
    let all = registry();
    all.binary_search_by_key(&name, |m| m.name)
        .ok()
        .map(|i| &all[i])
}

/// `T`'s JSON Schema (2020-12), named types under `$defs`.
pub fn schema_of<T: JsonSchema>() -> Schema {
    SchemaSettings::draft2020_12()
        .into_generator()
        .into_root_schema_for::<T>()
}

/// serde names a missing field in its message only (an unknown one is in the path already): put it at the end of
/// the path, so `{}` for a method that needs `id` is refused at `id`.
fn field_in_path(mut e: Error) -> Error {
    if let Some(field) = e
        .message
        .strip_prefix("missing field `")
        .and_then(|r| r.split('`').next())
    {
        e.path = Some(match e.path.take() {
            Some(p) => format!("{p}.{field}"),
            None => field.to_string(),
        });
    }
    e
}

/// `v` as the params type `T` (`decode::typed`), a missing field named in the path.
pub fn decode_params<T: DeserializeOwned>(v: &Value) -> Result<(T, Vec<String>), Error> {
    decode::typed::<T>(v).map_err(field_in_path)
}

/// `v` as the result or event type `T`, encoded again.  What does not fit is `internal` with its path.
pub fn check_as<T: DeserializeOwned + Serialize>(v: &Value) -> Result<Value, Error> {
    let t: T = serde_path_to_error::deserialize(v).map_err(|e| {
        field_in_path(Error {
            code: ErrorCode::Internal,
            message: e.inner().to_string(),
            path: e.path().iter().next().map(|_| e.path().to_string()),
        })
    })?;
    serde_json::to_value(&t).map_err(|e| Error {
        code: ErrorCode::Internal,
        message: e.to_string(),
        path: None,
    })
}

/// The registry as `methods.json` has it: `{proto, proto_min, records, schema, methods, events}`.
pub fn methods_json() -> Value {
    let methods: Vec<Value> = registry()
        .iter()
        .map(|m| {
            json!({
                "name": m.name,
                "classes": m.classes.iter().map(|c| c.name()).collect::<Vec<_>>(),
                "writes": m.writes,
                "home": m.home.name(),
                "doc": m.doc,
                "params": (m.params)().to_value(),
                "result": (m.result)().to_value(),
            })
        })
        .collect();
    let events: Vec<Value> = events()
        .iter()
        .map(|e| {
            json!({"name": e.name, "from": e.from.name(), "doc": e.doc, "data": (e.data)().to_value()})
        })
        .collect();
    sorted(json!({
        "proto": PROTO, "proto_min": PROTO_MIN, "records": RECORDS, "schema": SCHEMA,
        "methods": methods, "events": events,
    }))
}

/// `methods_json()` as the committed file: pretty, keys sorted, a newline at the end.
pub fn methods_json_text() -> String {
    let mut s = serde_json::to_string_pretty(&methods_json()).expect("JSON");
    s.push('\n');
    s
}

/// `v` with every object's keys in order (whatever map serde_json was built with).
fn sorted(v: Value) -> Value {
    match v {
        Value::Object(o) => {
            let mut pairs: Vec<(String, Value)> = o.into_iter().collect();
            pairs.sort_by(|a, b| a.0.cmp(&b.0));
            Value::Object(pairs.into_iter().map(|(k, v)| (k, sorted(v))).collect())
        }
        Value::Array(a) => Value::Array(a.into_iter().map(sorted).collect()),
        other => other,
    }
}

/// The Markdown table of the registry that `docs/develop/hub.md` holds between `<!-- hub-methods:begin -->` and
/// `<!-- hub-methods:end -->`.
pub fn markdown_table() -> String {
    let mut s = String::from(
        "| Method | Class | Params | Result | Writes | Home |\n|---|---|---|---|---|---|\n",
    );
    for m in registry() {
        let classes: Vec<&str> = m.classes.iter().map(|c| c.name()).collect();
        s.push_str(&format!(
            "| `{}` | {} | `{}` | `{}` | {} | {} |\n",
            m.name,
            classes.join(", "),
            cell(&schema_words((m.params)().as_value(), true)),
            cell(&schema_words((m.result)().as_value(), false)),
            if m.writes { "yes" } else { "no" },
            m.home.name()
        ));
    }
    s
}

fn cell(s: &str) -> String {
    s.replace('|', "\\|")
}

/// A root schema in words: `{a: T, b?: T}` an object (`?`: may be absent or null), `[T]` a list, `A | B` either,
/// a name a named type (docs/develop/hub.md, "Types").  Params are spelled out; a result object of more than five
/// keys is its type's name.
fn schema_words(root: &Value, params: bool) -> String {
    let empty = Map::new();
    let defs = root
        .get("$defs")
        .and_then(Value::as_object)
        .unwrap_or(&empty);
    let w = Words { defs, params };
    let props = root
        .get("properties")
        .and_then(Value::as_object)
        .map_or(0, Map::len);
    match root.get("title").and_then(Value::as_str) {
        Some(title) if !params && props > 5 => title.to_string(),
        _ => w.words(root),
    }
}

struct Words<'a> {
    defs: &'a Map<String, Value>,
    params: bool,
}

impl Words<'_> {
    fn words(&self, s: &Value) -> String {
        let Some(o) = s.as_object() else {
            return if s == &Value::Bool(false) {
                "never"
            } else {
                "any"
            }
            .into();
        };
        if let Some(r) = o.get("$ref").and_then(Value::as_str) {
            let name = r.trim_start_matches("#/$defs/");
            let def = self.defs.get(name).unwrap_or(&Value::Null);
            let is_enum = def.get("enum").is_some() || def.get("oneOf").is_some();
            let is_object = def.get("properties").is_some();
            return if is_enum || (self.params && is_object) {
                self.words(def)
            } else {
                name.to_string()
            };
        }
        if let Some(e) = o.get("enum").and_then(Value::as_array) {
            return e
                .iter()
                .map(Value::to_string)
                .collect::<Vec<_>>()
                .join(" | ");
        }
        if let Some(c) = o.get("const") {
            return c.to_string();
        }
        for k in ["anyOf", "oneOf"] {
            if let Some(alts) = o.get(k).and_then(Value::as_array) {
                return alts
                    .iter()
                    .map(|a| self.words(a))
                    .collect::<Vec<_>>()
                    .join(" | ");
            }
        }
        match o.get("type") {
            Some(Value::Array(types)) => types
                .iter()
                .filter_map(Value::as_str)
                .map(|t| self.typed(t, o))
                .collect::<Vec<_>>()
                .join(" | "),
            Some(Value::String(t)) => self.typed(t, o),
            _ => "any".into(),
        }
    }

    fn typed(&self, t: &str, o: &Map<String, Value>) -> String {
        match t {
            "object" => match o.get("properties").and_then(Value::as_object) {
                Some(props) => {
                    let required: Vec<&str> = o
                        .get("required")
                        .and_then(Value::as_array)
                        .map(|r| r.iter().filter_map(Value::as_str).collect())
                        .unwrap_or_default();
                    let fields: Vec<String> = props
                        .iter()
                        .map(|(k, v)| {
                            if required.contains(&k.as_str()) {
                                format!("{k}: {}", self.words(v))
                            } else {
                                format!("{k}?: {}", self.words(&without_null(v)))
                            }
                        })
                        .collect();
                    format!("{{{}}}", fields.join(", "))
                }
                // a struct with no fields (no params) is `{}`; a map of anything an object
                None if o.get("additionalProperties").is_none() => "{}".into(),
                None => "object".into(),
            },
            "array" => {
                if let Some(items) = o.get("prefixItems").and_then(Value::as_array) {
                    let parts: Vec<String> = items.iter().map(|i| self.words(i)).collect();
                    format!("[{}]", parts.join(", "))
                } else {
                    format!(
                        "[{}]",
                        o.get("items").map_or("any".into(), |i| self.words(i))
                    )
                }
            }
            "integer" if o.get("minimum").and_then(Value::as_f64) == Some(0.0) => "natnum".into(),
            other => other.into(),
        }
    }
}

/// An optional key's schema without its `null` alternative (the `?` says it).
fn without_null(v: &Value) -> Value {
    let mut v = v.clone();
    if let Some(o) = v.as_object_mut() {
        if let Some(Value::Array(types)) = o.get_mut("type") {
            types.retain(|t| t != "null");
            if types.len() == 1 {
                let t = types.remove(0);
                o.insert("type".into(), t);
            }
        }
        for k in ["anyOf", "oneOf"] {
            if let Some(Value::Array(alts)) = o.get_mut(k) {
                alts.retain(|a| a.get("type") != Some(&json!("null")));
                if alts.len() == 1 {
                    return alts.remove(0);
                }
            }
        }
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::path::{Path, PathBuf};

    fn repo(rel: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../..")
            .join(rel)
    }

    fn update() -> bool {
        std::env::var_os("UPDATE_METHODS_JSON").is_some_and(|v| v == "1")
    }

    #[test]
    fn the_registry_is_sorted_and_complete() {
        let names: Vec<&str> = registry().iter().map(|m| m.name).collect();
        let mut sorted = names.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(names, sorted);
        assert_eq!(names.len(), 56, "{names:?}");
        assert!(find("job/start-task").is_some_and(|m| m.writes));
        assert!(find("job/status").is_some_and(|m| !m.writes));
        assert!(find("sandbox/global").is_none());
        let writes: Vec<&str> = registry()
            .iter()
            .filter(|m| m.writes)
            .map(|m| m.name)
            .collect();
        let mut want = vec![
            "agents/do",
            "agents/kill",
            "agents/permission",
            "agents/send",
            "agents/start",
            "agents/stop",
        ];
        want.extend(FRONT_WRITES);
        want.extend(
            registry()
                .iter()
                .map(|m| m.name)
                .filter(|n| n.starts_with("job/") && *n != "job/status"),
        );
        want.sort();
        assert_eq!(writes, want);
    }

    /// The methods the front writes work.db for: the editor's five and the Lisp job runner's seam (Task 9).
    const FRONT_WRITES: [&str; 15] = [
        "cards/settle",
        "messages/send",
        "messages/mark",
        "events/add",
        "review/mark",
        "coord/job-create",
        "coord/job-set",
        "coord/task-status",
        "coord/leases",
        "coord/decide",
        "coord/agent",
        "coord/card-create",
        "coord/card-set",
        "coord/held",
        "coord/prune",
    ];

    #[test]
    fn every_method_has_a_home() {
        let front: Vec<&str> = registry()
            .iter()
            .filter(|m| m.home == Home::Front)
            .map(|m| m.name)
            .collect();
        let mut want = vec![
            "hello",
            "ping",
            "status",
            "subscribe",
            "shutdown",
            "restart",
            "events/since",
            "coord/notify",
            "mcp/session",
            "mcp/session-close",
            "mcp/attach",
            // the gateway (Task 22): registrations, keys, the provider table and spend
            "spend",
            "gateway/register",
            "gateway/unregister",
            "gateway/keys",
            "gateway/set-budget",
            "config/providers",
            // the editor's token and the held keys' ids (Task 22b)
            "gateway/editor-token",
            "gateway/keys-held",
        ];
        want.extend(FRONT_WRITES);
        want.sort();
        assert_eq!(front, want, "the methods the front serves itself");
        // an outside agent's bridge attaches without a proof; minting a session's socket is the user's
        assert_eq!(
            find("mcp/attach").map(|m| m.classes),
            Some(&[Class::Service][..])
        );
        assert_eq!(
            find("mcp/session").map(|m| m.classes),
            Some(&[Class::User][..])
        );
        // every other method is the backend's, and each event names the side that sends it
        assert!(
            registry()
                .iter()
                .filter(|m| !want.contains(&m.name))
                .all(|m| m.home == Home::Backend)
        );
        let from = |name| events().iter().find(|e| e.name == name).map(|e| e.from);
        assert_eq!(from("events"), Some(Home::Front));
        assert_eq!(from("challenge"), Some(Home::Front));
        assert_eq!(from("job"), Some(Home::Backend));
        assert_eq!(from("budget"), Some(Home::Front));
        let methods = methods_json();
        assert_eq!(
            methods["methods"][0]["home"],
            json!("backend"),
            "{}",
            methods["methods"][0]
        );
    }

    #[test]
    fn the_docs_table_has_the_home_column() {
        let t = markdown_table();
        assert!(
            t.starts_with("| Method | Class | Params | Result | Writes | Home |\n"),
            "{t}"
        );
        assert!(
            t.contains("| `cards/settle` | user | `{card: natnum, choice: Text}` | `{settled: boolean}` | yes | front |"),
            "{t}"
        );
        assert!(
            t.contains("| `coord/notify` | user, agent, service | `{}` | `boolean` | no | front |"),
            "{t}"
        );
    }

    #[test]
    fn methods_json_is_the_registry() {
        let path = repo("runtime/protocol/methods.json");
        let now = methods_json_text();
        if update() {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, &now).unwrap();
        }
        let committed = std::fs::read_to_string(&path).unwrap_or_default();
        assert!(
            committed == now,
            "{} is out of date: UPDATE_METHODS_JSON=1 cargo test -p runstav registry",
            path.display()
        );
    }

    #[test]
    fn the_docs_table_is_the_registry() {
        let path = repo("docs/develop/hub.md");
        let (begin, end) = ("<!-- hub-methods:begin -->\n", "<!-- hub-methods:end -->");
        let text = std::fs::read_to_string(&path).unwrap();
        let (b, e) = (text.find(begin), text.find(end));
        assert!(
            b.is_some() && e.is_some(),
            "hub.md has no {begin:?} … {end:?}"
        );
        let (b, e) = (b.unwrap() + begin.len(), e.unwrap());
        let table = markdown_table();
        if update() && text[b..e] != table {
            std::fs::write(&path, format!("{}{table}{}", &text[..b], &text[e..])).unwrap();
            return;
        }
        assert!(
            text[b..e] == table,
            "the table in {} is out of date: UPDATE_METHODS_JSON=1 cargo test -p runstav registry\n{table}",
            path.display()
        );
    }

    #[test]
    fn classes_match_the_hand_written_matrix() {
        let text = std::fs::read_to_string(repo("test/conformance/class-matrix.json")).unwrap();
        let matrix: BTreeMap<String, Vec<Class>> = serde_json::from_str(&text).unwrap();
        let ours: BTreeMap<String, Vec<Class>> = registry()
            .iter()
            .map(|m| {
                let mut c = m.classes.to_vec();
                c.sort();
                (m.name.to_string(), c)
            })
            .collect();
        let matrix: BTreeMap<String, Vec<Class>> = matrix
            .into_iter()
            .map(|(k, mut v)| {
                v.sort();
                (k, v)
            })
            .collect();
        assert_eq!(ours, matrix);
    }

    fn required(schema: &Value) -> Vec<String> {
        schema
            .get("required")
            .and_then(Value::as_array)
            .map(|r| {
                r.iter()
                    .filter_map(|x| x.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    }

    #[test]
    fn every_method_with_required_params_refuses_empty() {
        let mut with = 0;
        for m in registry() {
            let schema = (m.params)().to_value();
            let req = required(&schema);
            if m.name == "coord/agent" {
                // one of two keys, neither required on its own: its check refuses `{}`
                assert!((m.decode)(&json!({})).is_err());
                continue;
            }
            match (m.decode)(&json!({})) {
                Ok(_) => assert!(req.is_empty(), "{} took {{}} but needs {req:?}", m.name),
                Err(e) => {
                    with += 1;
                    assert!(!req.is_empty(), "{} refused {{}}: {e:?}", m.name);
                    assert_eq!(e.code, ErrorCode::InvalidParams, "{}", m.name);
                    let path = e.path.unwrap_or_default();
                    assert!(
                        req.contains(&path),
                        "{}: path {path:?} is not one of {req:?}",
                        m.name
                    );
                }
            }
        }
        assert_eq!(with, 40);
    }

    #[test]
    fn empty_lists_encode_as_arrays() {
        let m = find("job/stop").unwrap();
        let out =
            (m.check_result)(&json!({"id": "j1", "title": null, "status": "running"})).unwrap();
        assert_eq!(out["cards"], json!([]));
        assert_eq!(out["tasks"], json!([]));
        assert_eq!(
            out.get("title"),
            None,
            "an absent optional value is left out"
        );
        let s = serde_json::to_string(&out).unwrap();
        assert!(s.contains("\"cards\":[]"), "{s}");
    }

    #[test]
    fn a_null_list_in_a_result_becomes_empty() {
        let m = find("job/status").unwrap();
        assert_eq!(
            (m.check_result)(&json!({"jobs": null})).unwrap(),
            json!({"jobs": []})
        );
        let one = (m.check_result)(&json!({"id": "j", "cards": null})).unwrap();
        assert_eq!(one["cards"], json!([]));
        let e = (m.check_result)(&json!({"id": "j", "extra": 1})).unwrap_err();
        assert!(e.message.contains("extra"), "{e:?}");
        let m = find("agents/list").unwrap();
        assert_eq!(
            (m.check_result)(&json!({"sessions": [{"id": "s", "queue": null, "status": "busy"}]}))
                .unwrap(),
            json!({"sessions": [{"id": "s", "queue": [], "permissions": [], "reviews": [], "commands": [], "status": "busy"}]})
        );
    }

    #[test]
    fn a_result_key_the_registry_does_not_know_is_an_error_with_its_path() {
        let m = find("agents/get").unwrap();
        let e = (m.check_result)(
            &json!({"session": {"id": "s", "colour": "red"}, "entries": [], "seq": 1}),
        )
        .unwrap_err();
        assert_eq!(e.code, ErrorCode::Internal);
        assert_eq!(e.path.as_deref(), Some("session.colour"), "{e:?}");
        let e = (m.check_result)(&json!({"session": {"id": "s", "status": "dancing"}, "seq": 1}))
            .unwrap_err();
        assert_eq!(e.path.as_deref(), Some("session.status"), "{e:?}");
    }

    /// Every schema an object or list of `s` holds, walked: `true`/`{}` (or annotations only) is unconstrained.
    fn unconstrained(s: &Value, at: &str, out: &mut Vec<String>) {
        const NOTES: [&str; 8] = [
            "description",
            "title",
            "default",
            "examples",
            "$comment",
            "deprecated",
            "readOnly",
            "writeOnly",
        ];
        match s {
            Value::Bool(true) => out.push(at.to_string()),
            Value::Object(o) => {
                if o.keys().all(|k| NOTES.contains(&k.as_str())) {
                    out.push(at.to_string());
                }
                for k in [
                    "items",
                    "additionalProperties",
                    "propertyNames",
                    "not",
                    "contains",
                ] {
                    if let Some(sub) = o.get(k) {
                        unconstrained(sub, &format!("{at}/{k}"), out);
                    }
                }
                for k in ["prefixItems", "anyOf", "oneOf", "allOf"] {
                    for (i, sub) in o
                        .get(k)
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .enumerate()
                    {
                        unconstrained(sub, &format!("{at}/{k}/{i}"), out);
                    }
                }
                for k in ["properties", "$defs"] {
                    for (name, sub) in o.get(k).and_then(Value::as_object).into_iter().flatten() {
                        unconstrained(sub, &format!("{at}/{k}/{name}"), out);
                    }
                }
            }
            _ => {}
        }
    }

    #[test]
    fn no_any_in_params() {
        let mut found = Vec::new();
        for m in registry() {
            unconstrained(&(m.params)().to_value(), m.name, &mut found);
        }
        assert!(found.is_empty(), "unconstrained params: {found:?}");
        // the walk finds what it looks for: a result may hold `any` (Entry's ACP rest, a job's tasks)
        let mut results = Vec::new();
        unconstrained(
            &(find("agents/get").unwrap().result)().to_value(),
            "agents/get",
            &mut results,
        );
        assert!(!results.is_empty());
    }

    #[test]
    fn params_reencode_without_absent_values() {
        let m = find("agents/start").unwrap();
        let (p, ignored) =
            (m.decode)(&json!({"profile": "p", "cwd": null, "task": "T#1", "x": 1})).unwrap();
        assert_eq!(ignored, ["x"]);
        assert!(matches!(p, Params::AgentsStart(_)));
        assert_eq!(p.to_value(), json!({"profile": "p", "task": "T#1"}));
    }

    #[test]
    fn a_wrong_type_has_its_path() {
        let refusal = |m: &str, v: Value| (find(m).unwrap().decode)(&v).err().unwrap();
        let e = refusal("env/set", json!({"env": [{"name": "A", "value": 7}]}));
        assert_eq!(e.path.as_deref(), Some("env[0].value"));
        let e = refusal("env/set", json!({"env": [{"name": "A"}]}));
        assert_eq!(e.path.as_deref(), Some("env[0].value"), "{e:?}");
        let e = refusal(
            "gateway/register",
            json!({"chain": [], "openrouter": {"zdr": true, "mystery": 1}}),
        );
        assert_eq!(e.path.as_deref(), Some("openrouter.mystery"), "{e:?}");
    }

    #[test]
    fn the_table_spells_out_params() {
        let t = markdown_table();
        assert!(
            t.contains("| `ping` | user, agent, service | `{}` | `{pid: natnum}` | no | front |"),
            "{t}"
        );
        assert!(
            t.contains("| `job/stop` | user | `{id: Id}` | `JobSummary` | yes | backend |"),
            "{t}"
        );
        assert!(
            t.contains("`{env: [{name: EnvName, value: string}]}`"),
            "{t}"
        );
    }
}
