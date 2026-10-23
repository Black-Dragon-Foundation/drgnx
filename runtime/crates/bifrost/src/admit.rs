//! Request admission: the Host, the token, the path by the token's class, the body's size (design §5.6; the plan's
//! calls 11 and 15).
//!
//! [`head`] runs on the request head alone, before a byte of the body is read, so a request without a valid token
//! is refused at once whatever it says follows (the Lisp's `bad-token-refused-before-body`).

use std::collections::BTreeMap;

use bytes::Bytes;
use http::Uri;
use http::header::{AUTHORIZATION, CONTENT_LENGTH, HOST};
use http::request::Parts;
use sha2::{Digest, Sha256};

use crate::{Class, ListenerId, Provider, Registration};

/// The largest request body the gateway takes (bytes), as the Lisp's `drgnx-http-max-body`.
pub const MAX_BODY: u64 = 32 * 1024 * 1024;

/// The registrations, by the SHA-256 hex of their token ([`token_hash`]).
pub trait Registry: Send + Sync {
    fn find(&self, hash: &str) -> Option<Registration>;
}

/// Where an admitted request goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Route {
    /// An agent's request: along its registration's chain, to the path it asked for.
    Chain,
    /// An editor's request: to provider `id`, at `rest` (the kind's path with the request's query, if any), which
    /// `rewrite::provider_uri` appends to the provider's base.
    Provider { id: String, rest: String },
}

/// An admitted request: its token's hash, its registration and its route.
#[derive(Debug, Clone, PartialEq)]
pub struct Admitted {
    pub hash: String,
    pub registration: Registration,
    pub route: Route,
}

/// A refusal, answered with `status` and the Anthropic-shaped error body the Lisp gateway sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub status: u16,
    /// The error's `type`: `invalid_request_error`, `authentication_error`, `not_found_error`, `budget_exceeded`,
    /// `api_error`.
    pub kind: &'static str,
    pub message: String,
}

impl Refusal {
    pub fn new(status: u16, kind: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            kind,
            message: message.into(),
        }
    }

    /// `{"type":"error","error":{"type":KIND,"message":MESSAGE}}`, in the Lisp's key order.
    pub fn body(&self) -> Bytes {
        let quote = |s: &str| serde_json::Value::from(s).to_string();
        Bytes::from(format!(
            r#"{{"type":"error","error":{{"type":{},"message":{}}}}}"#,
            quote(self.kind),
            quote(&self.message)
        ))
    }
}

/// The registry key of a token: SHA-256 of its raw bytes, as 64 lower-case hex digits.
pub fn token_hash(token: &[u8]) -> String {
    Sha256::digest(token)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Admit a request by its head, in this order:
///
/// 1. on [`ListenerId::Loopback`], exactly one `Host`, `127.0.0.1:PORT` or `localhost:PORT`, else 400 (the
///    DNS-rebinding class of RUSTSEC-2026-0189);
/// 2. the token (`Authorization: Bearer`, else `x-api-key`) names a registration issued for listener `on`, else 401;
/// 3. the path, by the registration's class, else 404: an agent's are Anthropic's Messages API paths; an editor's are
///    `/p/PROVIDER/REST[?query]`, PROVIDER in `providers` and REST one of its kind's paths;
/// 4. a `Content-Length` over [`MAX_BODY`] is 413.
pub fn head(
    parts: &Parts,
    on: &ListenerId,
    port: u16,
    registry: &dyn Registry,
    providers: &BTreeMap<String, Provider>,
) -> Result<Admitted, Refusal> {
    if *on == ListenerId::Loopback && !host_is_loopback(parts, port) {
        return Err(Refusal::new(
            400,
            "invalid_request_error",
            "this gateway answers on 127.0.0.1 only",
        ));
    }

    let not_ours = || Refusal::new(401, "authentication_error", "not a drgnx gateway token");
    let hash = token_hash(token(parts).ok_or_else(not_ours)?);
    // a token is bound to the listener it was issued for (design §5.6)
    let registration = registry
        .find(&hash)
        .filter(|r| r.listener == *on)
        .ok_or_else(not_ours)?;

    let target = request_target(&parts.uri);
    let route = match registration.class {
        Class::Agent if agent_path_ok(target) => Route::Chain,
        Class::Agent => {
            return Err(Refusal::new(
                404,
                "not_found_error",
                "the gateway forwards Anthropic's Messages API only",
            ));
        }
        Class::Editor => editor_route(target, providers)?,
    };

    if let Some(length) = parts.headers.get(CONTENT_LENGTH) {
        let length = length
            .to_str()
            .ok()
            .and_then(|l| l.parse::<u64>().ok())
            .ok_or_else(|| Refusal::new(400, "invalid_request_error", "the request cannot be taken"))?;
        if length > MAX_BODY {
            return Err(Refusal::new(
                413,
                "invalid_request_error",
                "the request body is over 32 MiB",
            ));
        }
    }

    Ok(Admitted {
        hash,
        registration,
        route,
    })
}

/// Exactly one `Host`, naming the loopback listener with its port.
fn host_is_loopback(parts: &Parts, port: u16) -> bool {
    let mut hosts = parts.headers.get_all(HOST).iter();
    let (Some(host), None) = (hosts.next(), hosts.next()) else {
        return false;
    };
    let Some((name, p)) = host.to_str().ok().and_then(|h| h.rsplit_once(':')) else {
        return false;
    };
    p == port.to_string() && (name == "127.0.0.1" || name.eq_ignore_ascii_case("localhost"))
}

/// The token: `Authorization: Bearer TOKEN` ("Bearer" as written, then spaces), else `x-api-key`.
fn token(parts: &Parts) -> Option<&[u8]> {
    if let Some(auth) = parts.headers.get(AUTHORIZATION)
        && let Some(rest) = auth.as_bytes().strip_prefix(b"Bearer ")
    {
        let start = rest.iter().position(|b| *b != b' ').unwrap_or(rest.len());
        if start < rest.len() {
            return Some(&rest[start..]);
        }
    }
    parts
        .headers
        .get("x-api-key")
        .map(|v| v.as_bytes())
        .filter(|t| !t.is_empty())
}

/// The request target in origin form (`/path?query`); "" for any other form (absolute, authority, `*`), which no
/// path rule takes.
fn request_target(uri: &Uri) -> &str {
    if uri.scheme().is_some() || uri.authority().is_some() {
        return "";
    }
    uri.path_and_query().map_or("", |pq| pq.as_str())
}

/// No `..`, no control or space character, no `#`: nothing that could change where the key goes.
fn clean_target(target: &str) -> bool {
    !target.contains("..") && !target.bytes().any(|b| b <= b' ' || b == 0x7f || b == b'#')
}

/// `^/v1/(messages(/count_tokens)?|models(/[A-Za-z0-9._:-]+)?)(\?[^#]*)?$`, with [`clean_target`].
pub(crate) fn agent_path_ok(target: &str) -> bool {
    if !clean_target(target) {
        return false;
    }
    let path = target.split_once('?').map_or(target, |(p, _)| p);
    match path.strip_prefix("/v1/") {
        Some("messages" | "messages/count_tokens" | "models") => true,
        Some(rest) => rest.strip_prefix("models/").is_some_and(|m| {
            !m.is_empty()
                && m.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'))
        }),
        None => false,
    }
}

/// `/p/PROVIDER/REST[?query]` → [`Route::Provider`].
fn editor_route(target: &str, providers: &BTreeMap<String, Provider>) -> Result<Route, Refusal> {
    let refuse = || {
        Refusal::new(
            404,
            "not_found_error",
            "an editor token reaches a provider's own paths only (/p/PROVIDER/PATH)",
        )
    };
    if !clean_target(target) {
        return Err(refuse());
    }
    let after = target.strip_prefix("/p/").ok_or_else(refuse)?;
    let path = after.split_once('?').map_or(after, |(p, _)| p);
    let (id, rest) = path.find('/').map(|i| path.split_at(i)).ok_or_else(refuse)?;
    let provider = providers
        .get(id)
        .ok_or_else(|| Refusal::new(404, "not_found_error", "no such provider in the drgnx hub"))?;
    if !provider.kind.paths().contains(&rest) {
        return Err(refuse());
    }
    Ok(Route::Provider {
        id: id.to_owned(),
        rest: after[id.len()..].to_owned(),
    })
}

#[cfg(test)]
mod tests {
    use http::HeaderValue;
    use proptest::prelude::*;

    use super::*;
    use crate::{Auth, Caps, Kind, Step};

    const PORT: u16 = 41234;
    const AGENT: &str = "agent-token-0123456789abcdef0123456789abcdef0123456789abcdef0123";
    const SESSION: &str = "session-token-0123456789abcdef0123456789abcdef0123456789abcdef01";
    const EDITOR: &str = "editor-token-0123456789abcdef0123456789abcdef0123456789abcdef012";
    const OTHER: &str = "other-token-0123456789abcdef0123456789abcdef0123456789abcdef0123";

    struct Mem(BTreeMap<String, Registration>);

    impl Registry for Mem {
        fn find(&self, hash: &str) -> Option<Registration> {
            self.0.get(hash).cloned()
        }
    }

    fn agent(listener: ListenerId, agent: &str) -> Registration {
        Registration {
            class: Class::Agent,
            job: Some("j".into()),
            task: Some("t1".into()),
            agent: Some(agent.into()),
            chain: vec![Step {
                provider: "openrouter".into(),
                model: Some("m1".into()),
            }],
            budget: None,
            openrouter: None,
            listener,
        }
    }

    fn registry() -> Mem {
        Mem(BTreeMap::from([
            (token_hash(AGENT.as_bytes()), agent(ListenerId::Loopback, "a1")),
            (token_hash(OTHER.as_bytes()), agent(ListenerId::Loopback, "a2")),
            (
                token_hash(SESSION.as_bytes()),
                agent(ListenerId::Session("s1".into()), "a3"),
            ),
            (token_hash(EDITOR.as_bytes()), Registration::editor()),
        ]))
    }

    fn provider(id: &str, kind: Kind, base: &str, auth: Auth) -> (String, Provider) {
        (
            id.to_owned(),
            Provider {
                id: id.to_owned(),
                kind,
                base: base.parse().unwrap(),
                auth,
                messages: kind == Kind::Anthropic || id == "openrouter",
                caps: Caps::default(),
                price: None,
            },
        )
    }

    fn providers() -> BTreeMap<String, Provider> {
        BTreeMap::from([
            provider("openrouter", Kind::Openai, "https://openrouter.ai/api/v1", Auth::Bearer),
            provider("ollama", Kind::Ollama, "http://127.0.0.1:11434", Auth::None),
            provider("llama", Kind::Llamacpp, "http://127.0.0.1:8080", Auth::None),
            provider("tei", Kind::Tei, "http://127.0.0.1:8081", Auth::None),
            provider("anthropic", Kind::Anthropic, "https://api.anthropic.com", Auth::XApiKey),
        ])
    }

    /// A POST head for `uri` with `Host: 127.0.0.1:PORT` and `headers`.
    fn parts(uri: &str, headers: &[(&str, &str)]) -> Parts {
        let mut b = http::Request::builder()
            .method("POST")
            .uri(uri)
            .header(HOST, format!("127.0.0.1:{PORT}"));
        for (k, v) in headers {
            b = b.header(*k, *v);
        }
        b.body(()).unwrap().into_parts().0
    }

    fn bearer(token: &str) -> String {
        format!("Bearer {token}")
    }

    fn admit(p: &Parts, on: &ListenerId) -> Result<Admitted, Refusal> {
        head(p, on, PORT, &registry(), &providers())
    }

    fn status(r: Result<Admitted, Refusal>) -> u16 {
        r.map_or_else(|e| e.status, |_| 200)
    }

    #[test]
    fn no_token_no_service() {
        let e = admit(&parts("/v1/messages", &[]), &ListenerId::Loopback).unwrap_err();
        assert_eq!((e.status, e.kind), (401, "authentication_error"));
        assert_eq!(e.message, "not a drgnx gateway token");
        assert_eq!(
            e.body(),
            Bytes::from_static(
                br#"{"type":"error","error":{"type":"authentication_error","message":"not a drgnx gateway token"}}"#
            )
        );
        let unknown = parts("/v1/messages", &[("authorization", "Bearer not-registered")]);
        assert_eq!(status(admit(&unknown, &ListenerId::Loopback)), 401);
        let empty = parts("/v1/messages", &[("x-api-key", "")]);
        assert_eq!(status(admit(&empty, &ListenerId::Loopback)), 401);
    }

    #[test]
    fn bad_token_refused_before_body() {
        // the head says 5 MB follow and the token is wrong: refused from the head alone
        let p = parts(
            "/v1/messages",
            &[("authorization", "Bearer nope"), ("content-length", "5000000")],
        );
        assert_eq!(status(admit(&p, &ListenerId::Loopback)), 401);
        // even past the cap: the token is checked first
        let big = (MAX_BODY + 1).to_string();
        let p = parts(
            "/v1/messages",
            &[("authorization", "Bearer nope"), ("content-length", &big)],
        );
        assert_eq!(status(admit(&p, &ListenerId::Loopback)), 401);
        // a good token is admitted on its head; its body is the engine's to read
        let p = parts(
            "/v1/messages",
            &[("authorization", &bearer(AGENT)), ("content-length", "10")],
        );
        let a = admit(&p, &ListenerId::Loopback).unwrap();
        assert_eq!(a.hash, token_hash(AGENT.as_bytes()));
        assert_eq!(a.registration.agent.as_deref(), Some("a1"));
        assert_eq!(a.route, Route::Chain);
    }

    #[test]
    fn a_token_of_another_listener_is_401() {
        let s1 = ListenerId::Session("s1".into());
        let s2 = ListenerId::Session("s2".into());
        let session = parts("/v1/messages", &[("authorization", &bearer(SESSION))]);
        assert_eq!(status(admit(&session, &ListenerId::Loopback)), 401);
        assert_eq!(status(admit(&session, &s2)), 401);
        assert_eq!(admit(&session, &s1).unwrap().registration.agent.as_deref(), Some("a3"));
        let loopback = parts("/v1/messages", &[("authorization", &bearer(AGENT))]);
        assert_eq!(status(admit(&loopback, &s1)), 401);
        // the editor's token is a loopback token
        let editor = parts("/p/openrouter/chat/completions", &[("authorization", &bearer(EDITOR))]);
        assert_eq!(status(admit(&editor, &s1)), 401);
        assert_eq!(status(admit(&editor, &ListenerId::Loopback)), 200);
    }

    #[test]
    fn only_the_messages_api_paths_reach_a_provider() {
        // the Lisp test's paths: a path that could change the provider's host must never be taken
        for bad in [
            ".attacker.example/v1/messages",
            "@attacker.example/v1/messages",
            "/v1/../x",
            "/v2/messages",
            "/v1/messages/../../admin",
            "//attacker.example/v1/messages",
            "/v1/models/../messages",
            "/v1/messages?a=\x01b",
            "/v1/messages?a=\x7f",
            "/v1/messages?a b",
            "/v1/messages#x",
            "/v1/chat/completions",
            "/admin",
            "/v1/models/",
            "/v1/models/a/b",
            "/v1/messagesx",
            "",
        ] {
            assert!(!agent_path_ok(bad), "{bad:?}");
        }
        for good in [
            "/v1/messages",
            "/v1/messages?beta=true",
            "/v1/messages/count_tokens",
            "/v1/models",
            "/v1/models/claude-x.1:2_3",
        ] {
            assert!(agent_path_ok(good), "{good:?}");
        }
        // through `head`, with what an HTTP parser lets through
        let token = bearer(AGENT);
        for bad in [
            "/v2/messages",
            "/v1/messages/../../admin",
            "//attacker.example/v1/messages",
            "/v1/chat/completions",
            "http://attacker.example/v1/messages",
            "*",
        ] {
            let e = admit(&parts(bad, &[("authorization", &token)]), &ListenerId::Loopback).unwrap_err();
            assert_eq!((e.status, e.kind), (404, "not_found_error"), "{bad:?}");
            assert_eq!(e.message, "the gateway forwards Anthropic's Messages API only");
        }
        for good in ["/v1/messages", "/v1/messages?beta=true", "/v1/messages/count_tokens"] {
            let a = admit(&parts(good, &[("authorization", &token)]), &ListenerId::Loopback);
            assert_eq!(a.unwrap().route, Route::Chain, "{good:?}");
        }
    }

    #[test]
    fn host_must_be_loopback_on_tcp() {
        let token = bearer(AGENT);
        let with_host = |hosts: &[&str]| {
            let mut p = parts("/v1/messages", &[("authorization", &token)]);
            p.headers.remove(HOST);
            for h in hosts {
                p.headers.append(HOST, HeaderValue::from_str(h).unwrap());
            }
            p
        };
        for bad in [
            vec![],
            vec!["attacker.example".to_owned()],
            vec![format!("attacker.example:{PORT}")],
            vec!["127.0.0.1".to_owned()],
            vec![format!("127.0.0.1:{}", PORT + 1)],
            vec![format!("127.0.0.2:{PORT}")],
            vec![format!("[::1]:{PORT}")],
            vec![format!("127.0.0.1:{PORT}"), format!("127.0.0.1:{PORT}")],
        ] {
            let hosts: Vec<&str> = bad.iter().map(String::as_str).collect();
            let e = admit(&with_host(hosts.as_slice()), &ListenerId::Loopback).unwrap_err();
            assert_eq!(e.status, 400, "{bad:?}");
            assert_eq!(e.message, "this gateway answers on 127.0.0.1 only");
        }
        for good in [
            format!("127.0.0.1:{PORT}"),
            format!("localhost:{PORT}"),
            format!("LocalHost:{PORT}"),
        ] {
            assert!(admit(&with_host(&[good.as_str()]), &ListenerId::Loopback).is_ok(), "{good}");
        }
        // the Host comes before the token
        let mut p = parts("/v1/messages", &[]);
        p.headers.insert(HOST, HeaderValue::from_static("attacker.example"));
        assert_eq!(status(admit(&p, &ListenerId::Loopback)), 400);
        // a session socket has no DNS name to rebind: any Host
        let mut p = parts("/v1/messages", &[("authorization", &bearer(SESSION))]);
        p.headers.insert(HOST, HeaderValue::from_static("attacker.example"));
        assert!(admit(&p, &ListenerId::Session("s1".into())).is_ok());
    }

    #[test]
    fn a_body_over_32_mib_is_413() {
        let token = bearer(AGENT);
        let over = (MAX_BODY + 1).to_string();
        let at = MAX_BODY.to_string();
        let e = admit(
            &parts("/v1/messages", &[("authorization", &token), ("content-length", &over)]),
            &ListenerId::Loopback,
        )
        .unwrap_err();
        assert_eq!((e.status, e.kind), (413, "invalid_request_error"));
        let at = parts("/v1/messages", &[("authorization", &token), ("content-length", &at)]);
        assert!(admit(&at, &ListenerId::Loopback).is_ok());
        let junk = parts("/v1/messages", &[("authorization", &token), ("content-length", "12x")]);
        assert_eq!(status(admit(&junk, &ListenerId::Loopback)), 400);
    }

    #[test]
    fn bearer_wins_over_x_api_key() {
        let who = |headers: &[(&str, &str)]| {
            admit(&parts("/v1/messages", headers), &ListenerId::Loopback)
                .ok()
                .and_then(|a| a.registration.agent)
        };
        let a = bearer(AGENT);
        assert_eq!(who(&[("authorization", &a), ("x-api-key", OTHER)]).as_deref(), Some("a1"));
        assert_eq!(who(&[("x-api-key", OTHER)]).as_deref(), Some("a2"));
        assert_eq!(who(&[("authorization", &format!("Bearer   {AGENT}"))]).as_deref(), Some("a1"));
        // "Bearer" as written: anything else is no Bearer token, and x-api-key is read
        let lower = format!("bearer {AGENT}");
        assert_eq!(who(&[("authorization", &lower), ("x-api-key", OTHER)]).as_deref(), Some("a2"));
        assert_eq!(who(&[("authorization", &lower)]), None);
        assert_eq!(who(&[("authorization", "Basic eDp5"), ("x-api-key", OTHER)]).as_deref(), Some("a2"));
        // a Bearer that is no registration is refused, not passed over for x-api-key
        assert_eq!(who(&[("authorization", "Bearer nope"), ("x-api-key", OTHER)]), None);
    }

    #[test]
    fn an_editor_token_reaches_only_its_paths() {
        let token = bearer(EDITOR);
        let route = |path: &str| admit(&parts(path, &[("authorization", &token)]), &ListenerId::Loopback);
        let to = |id: &str, rest: &str| Route::Provider {
            id: id.into(),
            rest: rest.into(),
        };
        for (path, id, rest) in [
            ("/p/openrouter/chat/completions", "openrouter", "/chat/completions"),
            ("/p/openrouter/completions", "openrouter", "/completions"),
            ("/p/openrouter/embeddings?x=1", "openrouter", "/embeddings?x=1"),
            ("/p/ollama/api/chat", "ollama", "/api/chat"),
            ("/p/ollama/api/generate", "ollama", "/api/generate"),
            ("/p/ollama/api/embed", "ollama", "/api/embed"),
            ("/p/llama/infill", "llama", "/infill"),
            ("/p/llama/v1/chat/completions", "llama", "/v1/chat/completions"),
            ("/p/llama/v1/embeddings", "llama", "/v1/embeddings"),
            ("/p/tei/embed", "tei", "/embed"),
        ] {
            let a = route(path).unwrap();
            assert_eq!(a.route, to(id, rest), "{path}");
            assert_eq!(a.registration.class, Class::Editor);
        }
        for bad in [
            "/v1/messages",
            "/v1/models",
            "/p/openrouter",
            "/p/openrouter/",
            "/p/openrouter/models",
            "/p/openrouter/chat/completions/../../x",
            "/p/openrouter/chat/completions/",
            "/p/openrouter//chat/completions",
            "/p//chat/completions",
            "/p/openrouter/chat/completions?a=..",
            "/P/openrouter/chat/completions",
        ] {
            let e = route(bad).unwrap_err();
            assert_eq!((e.status, e.kind), (404, "not_found_error"), "{bad}");
        }
    }

    #[test]
    fn an_agent_token_never_reaches_p() {
        let token = bearer(AGENT);
        for path in [
            "/p/openrouter/chat/completions",
            "/p/ollama/api/chat",
            "/p/anthropic/v1/messages",
            "/p/openrouter/v1/messages",
        ] {
            let e = admit(&parts(path, &[("authorization", &token)]), &ListenerId::Loopback).unwrap_err();
            assert_eq!(e.status, 404, "{path}");
        }
        // a session token neither
        let e = admit(
            &parts("/p/openrouter/chat/completions", &[("authorization", &bearer(SESSION))]),
            &ListenerId::Session("s1".into()),
        )
        .unwrap_err();
        assert_eq!(e.status, 404);
    }

    #[test]
    fn an_editor_path_of_another_kind_is_404() {
        let token = bearer(EDITOR);
        for path in [
            "/p/ollama/chat/completions",
            "/p/openrouter/api/chat",
            "/p/openrouter/infill",
            "/p/llama/chat/completions",
            "/p/tei/embeddings",
            "/p/ollama/embed",
            "/p/anthropic/v1/messages",
            "/p/anthropic/chat/completions",
        ] {
            let e = admit(&parts(path, &[("authorization", &token)]), &ListenerId::Loopback).unwrap_err();
            assert_eq!((e.status, e.kind), (404, "not_found_error"), "{path}");
        }
    }

    #[test]
    fn an_unknown_provider_is_404() {
        let token = bearer(EDITOR);
        for path in ["/p/nope/chat/completions", "/p/OpenRouter/chat/completions"] {
            let e = admit(&parts(path, &[("authorization", &token)]), &ListenerId::Loopback).unwrap_err();
            assert_eq!((e.status, e.kind), (404, "not_found_error"), "{path}");
            assert_eq!(e.message, "no such provider in the drgnx hub");
        }
    }

    proptest! {
        #[test]
        fn admit_never_panics(
            uri in "[ -~]{0,48}",
            host in proptest::collection::vec(any::<u8>(), 0..24),
            auth in proptest::collection::vec(any::<u8>(), 0..80),
            api_key in proptest::collection::vec(any::<u8>(), 0..80),
            length in proptest::collection::vec(any::<u8>(), 0..24),
            known in 0usize..4,
            session in any::<bool>(),
        ) {
            let mut p = parts("/", &[]);
            if let Ok(u) = uri.parse::<Uri>() {
                p.uri = u;
            }
            p.headers.remove(HOST);
            for (name, value) in [("host", host), ("authorization", auth), ("x-api-key", api_key), ("content-length", length)] {
                if let Ok(v) = HeaderValue::from_bytes(&value) {
                    p.headers.insert(name, v);
                }
            }
            if known > 0 {
                let token = [AGENT, SESSION, EDITOR][known - 1];
                p.headers.insert(AUTHORIZATION, HeaderValue::from_str(&bearer(token)).unwrap());
            }
            let on = if session { ListenerId::Session("s1".into()) } else { ListenerId::Loopback };
            let _ = admit(&p, &on);
        }
    }
}
