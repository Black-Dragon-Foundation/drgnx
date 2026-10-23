//! What reaches a provider: the body (an agent step's model, OpenRouter's restrictions), the upstream URL and the
//! forwarded headers with the key, as the Lisp gateway's `drgnx-gateway--body` and `--forward` did.
//!
//! The editor's route passes its body unchanged and never calls [`body`] (the user's answer 2).

use std::fmt;

use bytes::Bytes;
use http::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE};
use http::request::Parts;
use http::{HeaderMap, HeaderName, HeaderValue, Uri};
use secrecy::{ExposeSecret, SecretString};
use serde::de::{self, Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use serde::ser::{Serialize, SerializeMap, SerializeSeq, Serializer};
use zeroize::Zeroizing;

use crate::admit::Refusal;
use crate::{Auth, Provider, Restrictions};

/// The provider whose Messages requests carry the restrictions.
const OPENROUTER: &str = "openrouter";

/// The request's body for one step:
///
/// - `model`, when given, replaces the top-level `"model"` (or is added);
/// - `restrictions`, for provider `openrouter` on `/v1/messages[?query]` only and when they restrict anything, merge
///   into the top-level `"provider"` object, the stricter value winning ([`merge`]);
/// - with neither, or an empty body, the bytes are returned as they came;
/// - a body that is not a JSON object stays as it came, unless restrictions apply: then it is a 400, and nothing is
///   sent that might not honour them.
///
/// The object's key order is kept, as the Lisp's plist round trip kept it. A key the client sent twice that this
/// rewrites is written once, where it first stood; its last value (the one a JSON parser keeps) is the one merged.
pub fn body(
    bytes: Bytes,
    model: Option<&str>,
    restrictions: Option<&Restrictions>,
    path: &str,
    provider: &str,
) -> Result<Bytes, Refusal> {
    let restrictions =
        restrictions.filter(|r| provider == OPENROUTER && messages_path(path) && !r.is_empty());
    if (model.is_none() && restrictions.is_none()) || bytes.is_empty() {
        return Ok(bytes);
    }
    let mut object = match serde_json::from_slice::<Json>(&bytes) {
        Ok(Json::Obj(object)) => object,
        _ if restrictions.is_some() => {
            return Err(bad(
                "the request body is not a JSON object, so drgnx's OpenRouter restrictions cannot be applied",
            ));
        }
        _ => return Ok(bytes),
    };
    if let Some(model) = model {
        set(&mut object, "model", Json::Str(model.to_owned()));
    }
    if let Some(r) = restrictions {
        let client = match last(&object, "provider") {
            None | Some(Json::Null) => Vec::new(),
            Some(Json::Obj(client)) => client.clone(),
            Some(_) => return Err(bad("provider must be an object")),
        };
        set(&mut object, "provider", Json::Obj(merge(client, r)?));
    }
    serde_json::to_vec(&Json::Obj(object))
        .map(Bytes::from)
        .map_err(|e| Refusal::new(500, "api_error", format!("the gateway failed: {e}")))
}

/// `^/v1/messages(\?[^#]*)?$`: the one path that takes OpenRouter's `"provider"` object (the token count and the
/// model list route to no provider).
fn messages_path(path: &str) -> bool {
    match path.strip_prefix("/v1/messages") {
        Some("") => true,
        Some(query) => query.starts_with('?') && !query.contains('#'),
        None => false,
    }
}

/// The client's `"provider"` object with drgnx's restrictions merged in, the stricter value winning: `only` is the
/// intersection in drgnx's order (drgnx's alone when the client sent none), `ignore` the union, `data_collection`
/// `"deny"`, `zdr` true. Every other key of the client's stays. An `only` with nothing in common is a 400.
fn merge(client: Vec<(String, Json)>, r: &Restrictions) -> Result<Vec<(String, Json)>, Refusal> {
    let mut out = client;
    if !r.only().is_empty() {
        let mine = r.only();
        let only = match last(&out, "only") {
            None => mine.to_vec(),
            Some(theirs) => {
                let theirs = client_slugs(theirs, "only")?;
                let common: Vec<String> = mine.iter().filter(|s| theirs.contains(s)).cloned().collect();
                if common.is_empty() {
                    return Err(bad(format!(
                        "no provider in common between the request's provider.only and drgnx's OpenRouter \
                         restrictions ({})",
                        mine.join(", ")
                    )));
                }
                common
            }
        };
        set(&mut out, "only", strings(only));
    }
    if !r.ignore().is_empty() {
        let mut ignore = match last(&out, "ignore") {
            None => Vec::new(),
            Some(theirs) => client_slugs(theirs, "ignore")?,
        };
        ignore.extend(r.ignore().iter().cloned());
        let mut union: Vec<String> = Vec::new();
        for s in ignore {
            if !union.contains(&s) {
                union.push(s);
            }
        }
        set(&mut out, "ignore", strings(union));
    }
    if r.data_collection_deny() {
        set(&mut out, "data_collection", Json::Str("deny".into()));
    }
    if r.zdr() {
        set(&mut out, "zdr", Json::Bool(true));
    }
    Ok(out)
}

/// The strings of the client's `provider.WHAT`, which must be an array of strings.
fn client_slugs(value: &Json, what: &str) -> Result<Vec<String>, Refusal> {
    let not = || bad(format!("provider.{what} must be a list of provider slugs"));
    let Json::Arr(items) = value else {
        return Err(not());
    };
    items
        .iter()
        .map(|i| match i {
            Json::Str(s) => Ok(s.clone()),
            _ => Err(not()),
        })
        .collect()
}

fn strings(v: Vec<String>) -> Json {
    Json::Arr(v.into_iter().map(Json::Str).collect())
}

fn bad(message: impl Into<String>) -> Refusal {
    Refusal::new(400, "invalid_request_error", message)
}

/// The value of `key`'s last occurrence.
fn last<'a>(object: &'a [(String, Json)], key: &str) -> Option<&'a Json> {
    object.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// `key` set to `value` where it first stood (else at the end), and no other occurrence left.
fn set(object: &mut Vec<(String, Json)>, key: &str, value: Json) {
    match object.iter().position(|(k, _)| k == key) {
        Some(i) => {
            object[i].1 = value;
            let mut n = 0;
            object.retain(|(k, _)| {
                n += usize::from(k == key);
                k != key || n == 1
            });
        }
        None => object.push((key.to_owned(), value)),
    }
}

/// JSON with every object's keys in the order they came (serde_json's `Value` sorts them without its
/// `preserve_order` feature, which would change the whole workspace's output).
#[derive(Debug, Clone, PartialEq)]
enum Json {
    Null,
    Bool(bool),
    Num(serde_json::Number),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl<'de> Deserialize<'de> for Json {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        d.deserialize_any(JsonVisitor)
    }
}

struct JsonVisitor;

impl<'de> Visitor<'de> for JsonVisitor {
    type Value = Json;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a JSON value")
    }

    fn visit_unit<E>(self) -> Result<Json, E> {
        Ok(Json::Null)
    }

    fn visit_bool<E>(self, b: bool) -> Result<Json, E> {
        Ok(Json::Bool(b))
    }

    fn visit_i64<E>(self, n: i64) -> Result<Json, E> {
        Ok(Json::Num(n.into()))
    }

    fn visit_u64<E>(self, n: u64) -> Result<Json, E> {
        Ok(Json::Num(n.into()))
    }

    fn visit_f64<E: de::Error>(self, n: f64) -> Result<Json, E> {
        serde_json::Number::from_f64(n)
            .map(Json::Num)
            .ok_or_else(|| E::custom("not a finite number"))
    }

    fn visit_str<E>(self, s: &str) -> Result<Json, E> {
        Ok(Json::Str(s.to_owned()))
    }

    fn visit_string<E>(self, s: String) -> Result<Json, E> {
        Ok(Json::Str(s))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Json, A::Error> {
        let mut items = Vec::new();
        while let Some(item) = seq.next_element()? {
            items.push(item);
        }
        Ok(Json::Arr(items))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Json, A::Error> {
        let mut entries = Vec::new();
        while let Some(entry) = map.next_entry::<String, Json>()? {
            entries.push(entry);
        }
        Ok(Json::Obj(entries))
    }
}

impl Serialize for Json {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Null => s.serialize_unit(),
            Self::Bool(b) => s.serialize_bool(*b),
            Self::Num(n) => n.serialize(s),
            Self::Str(x) => s.serialize_str(x),
            Self::Arr(items) => {
                let mut seq = s.serialize_seq(Some(items.len()))?;
                for item in items {
                    seq.serialize_element(item)?;
                }
                seq.end()
            }
            Self::Obj(entries) => {
                let mut map = s.serialize_map(Some(entries.len()))?;
                for (k, v) in entries {
                    map.serialize_entry(k, v)?;
                }
                map.end()
            }
        }
    }
}

/// An agent's upstream URL: the provider's base without a trailing `/` and then a trailing `/v1` (OpenRouter's
/// `…/api/v1` becomes `…/api`), plus the request's path and query. Refused when the result would leave the base's
/// scheme, host and port.
pub fn upstream_uri(base: &Uri, path_and_query: &str) -> Result<Uri, String> {
    let prefix = base_path(base)?;
    join(base, prefix.strip_suffix("/v1").unwrap_or(prefix), path_and_query)
}

/// An editor's upstream URL: the provider's base without a trailing `/`, plus REST and its query, with **no** `/v1`
/// stripping (OpenRouter's base is `…/api/v1` and its paths follow it). Refused as [`upstream_uri`].
pub fn provider_uri(base: &Uri, rest_and_query: &str) -> Result<Uri, String> {
    join(base, base_path(base)?, rest_and_query)
}

/// The base's path without a trailing `/` ("" for none).
fn base_path(base: &Uri) -> Result<&str, String> {
    if base.query().is_some() {
        return Err("the provider's URL has a query".into());
    }
    let path = base.path();
    Ok(path.strip_suffix('/').unwrap_or(path))
}

fn join(base: &Uri, prefix: &str, tail: &str) -> Result<Uri, String> {
    let (Some(scheme), Some(authority)) = (base.scheme(), base.authority()) else {
        return Err("the provider's URL is not absolute".into());
    };
    let leaves = || format!("the request would leave {}", authority.host());
    if !tail.starts_with('/') {
        return Err(leaves());
    }
    let uri: Uri = format!("{scheme}://{authority}{prefix}{tail}")
        .parse()
        .map_err(|e| format!("not a URL: {e}"))?;
    if uri.scheme() != base.scheme() || uri.authority() != base.authority() {
        return Err(leaves());
    }
    Ok(uri)
}

/// The upstream request's headers: the client's `content-type`, `accept`, `anthropic-version` and `anthropic-beta`
/// (each first value, control characters removed), and the provider's auth header with `key` (`x-api-key` for
/// [`Auth::XApiKey`], else `Authorization: Bearer`; none for a keyless provider or without a key). The key is exposed
/// only into that header's value, which is marked sensitive (hyper's and http's `Debug` print it as `Sensitive`).
pub fn headers(parts: &Parts, provider: &Provider, key: Option<&SecretString>) -> HeaderMap {
    let mut out = HeaderMap::new();
    for name in [
        CONTENT_TYPE,
        ACCEPT,
        HeaderName::from_static("anthropic-version"),
        HeaderName::from_static("anthropic-beta"),
    ] {
        if let Some(value) = parts.headers.get(&name)
            && let Ok(value) = HeaderValue::from_bytes(&clean(value.as_bytes()))
        {
            out.insert(name, value);
        }
    }
    let auth = match provider.auth {
        Auth::Bearer => Some((AUTHORIZATION, "Bearer ")),
        Auth::XApiKey => Some((HeaderName::from_static("x-api-key"), "")),
        Auth::None => None,
    };
    if let (Some((name, prefix)), Some(key)) = (auth, key) {
        let mut value = Zeroizing::new(Vec::with_capacity(prefix.len() + key.expose_secret().len()));
        value.extend_from_slice(prefix.as_bytes());
        value.extend(key.expose_secret().bytes().filter(|b| keep(*b)));
        if let Ok(mut value) = HeaderValue::from_bytes(&value) {
            value.set_sensitive(true);
            out.insert(name, value);
        }
    }
    out
}

/// Not a control character (`[\x00-\x1f\x7f]`): a CR or LF must never end a header line upstream.
fn keep(b: u8) -> bool {
    b >= 0x20 && b != 0x7f
}

fn clean(bytes: &[u8]) -> Vec<u8> {
    bytes.iter().copied().filter(|b| keep(*b)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Caps, Kind};

    fn full() -> Restrictions {
        Restrictions::new(
            vec!["anthropic".into(), "google-vertex".into()],
            vec!["azure".into()],
            true,
            true,
        )
        .unwrap()
    }

    fn zdr() -> Restrictions {
        Restrictions::new(vec![], vec![], false, true).unwrap()
    }

    fn rewrite(text: &str, model: Option<&str>, r: Option<&Restrictions>) -> Result<String, Refusal> {
        body(Bytes::from(text.to_owned()), model, r, "/v1/messages", "openrouter")
            .map(|b| String::from_utf8(b.to_vec()).unwrap())
    }

    /// The `"provider"` object sent for a client's `provider` (JSON text) under `r`.
    fn provider_object(client: &str, r: &Restrictions) -> serde_json::Value {
        let sent = rewrite(&format!(r#"{{"model":"x","provider":{client}}}"#), None, Some(r)).unwrap();
        serde_json::from_str::<serde_json::Value>(&sent).unwrap()["provider"].clone()
    }

    fn openrouter(auth: Auth) -> Provider {
        Provider {
            id: "openrouter".into(),
            kind: Kind::Openai,
            base: Uri::from_static("https://openrouter.ai/api/v1"),
            auth,
            messages: true,
            caps: Caps::default(),
            price: None,
        }
    }

    fn uri(base: &str, f: fn(&Uri, &str) -> Result<Uri, String>, tail: &str) -> Result<String, String> {
        f(&base.parse().unwrap(), tail).map(|u| u.to_string())
    }

    #[test]
    fn model_replaced() {
        assert_eq!(rewrite(r#"{"model":"x","a":1}"#, Some("m1"), None).unwrap(), r#"{"model":"m1","a":1}"#);
        assert_eq!(rewrite(r#"{"a":1}"#, Some("m1"), None).unwrap(), r#"{"a":1,"model":"m1"}"#);
        // the key order of every object stays, and a key sent twice is written once, where it first stood
        assert_eq!(
            rewrite(r#"{"z":{"b":1,"a":[2,{"d":null,"c":true}]},"model":"x","model":"y","y":1.5}"#, Some("m1"), None)
                .unwrap(),
            r#"{"z":{"b":1,"a":[2,{"d":null,"c":true}]},"model":"m1","y":1.5}"#
        );
        // a body that is not an object, without restrictions, goes as it came
        for text in ["this is not json", "[1,2]", "\"x\"", "{\"a\":"] {
            assert_eq!(rewrite(text, Some("m1"), None).unwrap(), text);
        }
    }

    #[test]
    fn the_body_is_untouched_without_model_or_restrictions() {
        let text = "{ \"model\" : \"x\" ,\n \"provider\": {\"only\":[\"x\"]} }";
        assert_eq!(rewrite(text, None, None).unwrap(), text);
        // restrictions that restrict nothing, another provider, another path: untouched
        let nothing = Restrictions::default();
        assert_eq!(rewrite(text, None, Some(&nothing)).unwrap(), text);
        let other = body(Bytes::from(text), None, Some(&full()), "/v1/messages", "anthropic").unwrap();
        assert_eq!(other, Bytes::from(text));
        let count = body(Bytes::from(text), None, Some(&full()), "/v1/messages/count_tokens", "openrouter");
        assert_eq!(count.unwrap(), Bytes::from(text));
        // an empty body is a body with nothing to rewrite
        assert_eq!(rewrite("", Some("m1"), Some(&full())).unwrap(), "");
    }

    #[test]
    fn restrictions_reach_the_body() {
        assert_eq!(
            rewrite(r#"{"model":"x","max_tokens":5}"#, Some("m1"), Some(&full())).unwrap(),
            r#"{"model":"m1","max_tokens":5,"provider":{"only":["anthropic","google-vertex"],"ignore":["azure"],"data_collection":"deny","zdr":true}}"#
        );
        // the request's model stays when the step names none
        assert_eq!(rewrite(r#"{"model":"x"}"#, None, Some(&zdr())).unwrap(), r#"{"model":"x","provider":{"zdr":true}}"#);
        // an empty object is a body: the restrictions are added to it; a null provider is none
        assert_eq!(rewrite("{}", None, Some(&zdr())).unwrap(), r#"{"provider":{"zdr":true}}"#);
        assert_eq!(
            rewrite(r#"{"provider":null,"a":1}"#, None, Some(&zdr())).unwrap(),
            r#"{"provider":{"zdr":true},"a":1}"#
        );
        // allow is OpenRouter's default and is not sent
        let allow = Restrictions::new(vec!["a".into()], vec![], false, false).unwrap();
        assert_eq!(rewrite("{}", None, Some(&allow)).unwrap(), r#"{"provider":{"only":["a"]}}"#);
    }

    #[test]
    fn the_clients_provider_object_is_merged_stricter_wins() {
        let mine = full();
        let only_a = Restrictions::new(vec!["a".into()], vec![], false, false).unwrap();
        // only: the intersection (drgnx's order); one side alone is kept
        assert_eq!(
            provider_object(r#"{"only":["google-vertex","openai"]}"#, &mine)["only"],
            serde_json::json!(["google-vertex"])
        );
        assert_eq!(
            provider_object(r#"{"order":["openai"]}"#, &mine)["only"],
            serde_json::json!(["anthropic", "google-vertex"])
        );
        assert_eq!(provider_object(r#"{"only":["openai"]}"#, &zdr())["only"], serde_json::json!(["openai"]));
        // ignore: the union
        assert_eq!(
            provider_object(r#"{"ignore":["openai","azure"]}"#, &mine)["ignore"],
            serde_json::json!(["openai", "azure"])
        );
        // data_collection: deny wins, from either side
        assert_eq!(provider_object(r#"{"data_collection":"allow"}"#, &mine)["data_collection"], "deny");
        assert_eq!(provider_object(r#"{"data_collection":"deny"}"#, &zdr())["data_collection"], "deny");
        // zdr: either asks for it
        assert_eq!(provider_object(r#"{"zdr":false}"#, &mine)["zdr"], true);
        assert_eq!(provider_object(r#"{"zdr":true}"#, &only_a)["zdr"], true);
        assert_eq!(provider_object(r#"{"zdr":false}"#, &only_a)["zdr"], false);
        // every other key passes through
        let p = provider_object(
            r#"{"order":["openai"],"sort":"price","require_parameters":true,"allow_fallbacks":false}"#,
            &mine,
        );
        assert_eq!(p["order"], serde_json::json!(["openai"]));
        assert_eq!(p["sort"], "price");
        assert_eq!(p["require_parameters"], true);
        assert_eq!(p["allow_fallbacks"], false);
        // a provider object sent twice: one merged object goes, restricted
        let sent = rewrite(
            r#"{"provider":{"only":["anthropic"]},"model":"x","provider":{"only":["openai","anthropic"]}}"#,
            None,
            Some(&mine),
        )
        .unwrap();
        assert_eq!(
            sent,
            r#"{"provider":{"only":["anthropic"],"ignore":["azure"],"data_collection":"deny","zdr":true},"model":"x"}"#
        );
    }

    #[test]
    fn no_common_only_is_400_and_nothing_is_sent() {
        let anthropic = Restrictions::new(vec!["anthropic".into()], vec![], false, false).unwrap();
        let e = rewrite(r#"{"model":"x","provider":{"only":["openai"]}}"#, None, Some(&anthropic)).unwrap_err();
        assert_eq!((e.status, e.kind), (400, "invalid_request_error"));
        assert_eq!(
            e.message,
            "no provider in common between the request's provider.only and drgnx's OpenRouter restrictions (anthropic)"
        );
        // a client's only that is not a list of slugs is no list to intersect
        for only in ["null", "\"openai\"", "[1]"] {
            let e = rewrite(&format!(r#"{{"provider":{{"only":{only}}}}}"#), None, Some(&anthropic)).unwrap_err();
            assert_eq!(e.message, "provider.only must be a list of provider slugs");
        }
        let e = rewrite(r#"{"provider":{"ignore":"x"}}"#, None, Some(&full())).unwrap_err();
        assert_eq!(e.message, "provider.ignore must be a list of provider slugs");
    }

    #[test]
    fn an_unreadable_body_with_restrictions_is_refused() {
        let r = full();
        for text in ["this is not json", "[1,2]", "\"x\"", "{\"a\":", "{\"a\":1} x"] {
            let e = rewrite(text, Some("m1"), Some(&r)).unwrap_err();
            assert_eq!((e.status, e.kind), (400, "invalid_request_error"), "{text}");
        }
        let e = rewrite(r#"{"model":"x","provider":"anthropic"}"#, None, Some(&r)).unwrap_err();
        assert_eq!(e.message, "provider must be an object");
        let bad_utf8 = body(Bytes::from_static(b"{\"a\":\"\xff\"}"), None, Some(&r), "/v1/messages", "openrouter");
        assert_eq!(bad_utf8.unwrap_err().status, 400);
        // no restrictions, nothing to fail closed on: the bytes go as they were
        assert_eq!(rewrite("this is not json", None, None).unwrap(), "this is not json");
    }

    #[test]
    fn only_v1_messages_gets_the_provider_object() {
        let r = full();
        let on = |path: &str| {
            let b = body(Bytes::from_static(br#"{"model":"x","messages":[]}"#), Some("m1"), Some(&r), path, "openrouter");
            String::from_utf8(b.unwrap().to_vec()).unwrap()
        };
        for path in ["/v1/messages/count_tokens", "/v1/models", "/v1/models/x", "/v1/messagesx"] {
            let sent = on(path);
            assert!(!sent.contains("provider") && !sent.contains("zdr"), "{path}: {sent}");
            assert!(sent.contains(r#""model":"m1""#), "{path}");
        }
        for path in ["/v1/messages", "/v1/messages?beta=true"] {
            assert!(on(path).contains(r#""zdr":true"#), "{path}");
        }
    }

    #[test]
    fn header_control_chars_stripped() {
        assert_eq!(clean(b"a\rX-Evil: 1\x01b\x7fc\td\n"), b"aX-Evil: 1bcd");
        // what an HTTP parser lets into a value (a tab, obs-text) is cleaned on the way too
        let parts = http::Request::builder()
            .header(CONTENT_TYPE, "application/json")
            .header(ACCEPT, "a\tb")
            .header("anthropic-version", "2023-06-01")
            .header("anthropic-beta", "x\ty")
            .header("anthropic-beta", "second")
            .header(AUTHORIZATION, "Bearer the-gateway-token")
            .header("x-api-key", "the-gateway-token")
            .header("cookie", "c=1")
            .header("x-other", "1")
            .body(())
            .unwrap()
            .into_parts()
            .0;
        let h = headers(&parts, &openrouter(Auth::Bearer), None);
        assert_eq!(h.len(), 4);
        assert_eq!(h[CONTENT_TYPE], "application/json");
        assert_eq!(h[ACCEPT], "ab");
        assert_eq!(h["anthropic-version"], "2023-06-01");
        assert_eq!(h["anthropic-beta"], "xy");
        // the client's token never goes upstream
        assert!(h.get(AUTHORIZATION).is_none() && h.get("x-api-key").is_none());
    }

    #[test]
    fn a_url_that_leaves_the_host_is_refused() {
        let base = "https://openrouter.ai/api/v1";
        for tail in [
            ".attacker.example/v1/messages",
            "@attacker.example/v1/messages",
            "attacker.example/v1/messages",
            ":1/v1/messages",
            "",
        ] {
            let e = uri(base, upstream_uri, tail).unwrap_err();
            assert_eq!(e, "the request would leave openrouter.ai", "{tail}");
        }
        // a path that only looks like a host stays on the provider's
        let u: Uri = upstream_uri(&base.parse().unwrap(), "//attacker.example/v1/messages").unwrap();
        assert_eq!(u.host(), Some("openrouter.ai"));
        // the base without its trailing /v1 (or /v1/), plus the request's path and query
        assert_eq!(uri(base, upstream_uri, "/v1/messages").unwrap(), "https://openrouter.ai/api/v1/messages");
        assert_eq!(
            uri("https://openrouter.ai/api/v1/", upstream_uri, "/v1/messages?beta=true").unwrap(),
            "https://openrouter.ai/api/v1/messages?beta=true"
        );
        assert_eq!(uri("https://api.anthropic.com", upstream_uri, "/v1/messages").unwrap(), "https://api.anthropic.com/v1/messages");
        assert_eq!(
            uri("http://127.0.0.1:11434", upstream_uri, "/v1/messages/count_tokens").unwrap(),
            "http://127.0.0.1:11434/v1/messages/count_tokens"
        );
        assert!(uri("https://h.example/x?y=1", upstream_uri, "/v1/messages").is_err());
    }

    #[test]
    fn the_key_header_is_sensitive() {
        let parts = http::Request::builder().body(()).unwrap().into_parts().0;
        let key = SecretString::from("sk-or-test\r\nX: y");
        let h = headers(&parts, &openrouter(Auth::Bearer), Some(&key));
        assert_eq!(h[AUTHORIZATION], "Bearer sk-or-testX: y");
        assert!(h[AUTHORIZATION].is_sensitive());
        assert!(!format!("{h:?}").contains("sk-or-test"));
        assert!(h.get("x-api-key").is_none());

        let h = headers(&parts, &openrouter(Auth::XApiKey), Some(&key));
        assert_eq!(h["x-api-key"], "sk-or-testX: y");
        assert!(h["x-api-key"].is_sensitive());
        assert!(h.get(AUTHORIZATION).is_none());

        // a keyless provider, or no key: no auth header
        assert!(headers(&parts, &openrouter(Auth::None), Some(&key)).is_empty());
        assert!(headers(&parts, &openrouter(Auth::Bearer), None).is_empty());
    }

    #[test]
    fn provider_uri_keeps_v1() {
        assert_eq!(
            uri("https://openrouter.ai/api/v1", provider_uri, "/chat/completions?x=1").unwrap(),
            "https://openrouter.ai/api/v1/chat/completions?x=1"
        );
        assert_eq!(
            uri("https://openrouter.ai/api/v1/", provider_uri, "/embeddings").unwrap(),
            "https://openrouter.ai/api/v1/embeddings"
        );
        assert_eq!(
            uri("http://127.0.0.1:8080", provider_uri, "/v1/chat/completions").unwrap(),
            "http://127.0.0.1:8080/v1/chat/completions"
        );
        assert_eq!(uri("http://192.168.1.5:11434/", provider_uri, "/api/chat").unwrap(), "http://192.168.1.5:11434/api/chat");
    }

    #[test]
    fn provider_uri_never_leaves_the_host() {
        for tail in ["@attacker.example/embed", ".attacker.example/embed", "attacker.example", ":9/embed", ""] {
            let e = uri("http://127.0.0.1:8081", provider_uri, tail).unwrap_err();
            assert_eq!(e, "the request would leave 127.0.0.1", "{tail}");
        }
        let u = provider_uri(&"https://openrouter.ai/api/v1".parse().unwrap(), "//attacker.example/x").unwrap();
        assert_eq!(u.host(), Some("openrouter.ai"));
    }
}
