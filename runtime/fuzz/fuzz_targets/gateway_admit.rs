//! Arbitrary request heads through `admit::head`, for both token classes. Byte 0 is flags (bits 0-1 the token: agent,
//! editor, a session's agent, none; bit 2 the session listener, else loopback; bit 3 `x-api-key` instead of
//! `Authorization: Bearer`; bit 4 no `Host` of ours; bit 5 `localhost` as the host name). The rest is lines: the
//! request target, then `name: value` headers. A head that does not build into `Parts` is skipped. An admission
//! must belong to its listener, take a path of its class, and stay inside the body cap; a refusal is a 4xx whose
//! body is JSON. Nothing may panic.
#![no_main]

use std::collections::BTreeMap;

use bifrost::admit::{self, MAX_BODY, Registry, Route, token_hash};
use bifrost::{Auth, Caps, Class, Kind, ListenerId, Provider, Registration, Step};
use http::header::{AUTHORIZATION, CONTENT_LENGTH, HOST};
use http::{HeaderName, HeaderValue};
use libfuzzer_sys::fuzz_target;

const PORT: u16 = 41234;
const TOKENS: [&str; 3] = ["agent-token-a", "editor-token-e", "session-token-s"];

struct Mem(BTreeMap<String, Registration>);

impl Registry for Mem {
    fn find(&self, hash: &str) -> Option<Registration> {
        self.0.get(hash).cloned()
    }
}

fn agent(listener: ListenerId) -> Registration {
    Registration {
        class: Class::Agent,
        job: Some("j".into()),
        task: None,
        agent: Some("a".into()),
        chain: vec![Step {
            provider: "openrouter".into(),
            model: None,
        }],
        budget: None,
        openrouter: None,
        listener,
    }
}

fn provider(id: &str, kind: Kind, base: &str) -> (String, Provider) {
    (
        id.to_owned(),
        Provider {
            id: id.to_owned(),
            kind,
            base: base.parse().unwrap(),
            auth: Auth::None,
            messages: false,
            caps: Caps::default(),
            price: None,
        },
    )
}

fuzz_target!(|data: &[u8]| {
    let [flags, rest @ ..] = data else {
        return;
    };
    let registry = Mem(BTreeMap::from([
        (token_hash(TOKENS[0].as_bytes()), agent(ListenerId::Loopback)),
        (token_hash(TOKENS[1].as_bytes()), Registration::editor()),
        (
            token_hash(TOKENS[2].as_bytes()),
            agent(ListenerId::Session("s1".into())),
        ),
    ]));
    let providers = BTreeMap::from([
        provider("openrouter", Kind::Openai, "https://openrouter.ai/api/v1"),
        provider("ollama", Kind::Ollama, "http://127.0.0.1:11434"),
        provider("llama", Kind::Llamacpp, "http://127.0.0.1:8080"),
        provider("tei", Kind::Tei, "http://127.0.0.1:8081"),
        provider("anthropic", Kind::Anthropic, "https://api.anthropic.com"),
    ]);
    let on = if flags & 4 != 0 {
        ListenerId::Session("s1".into())
    } else {
        ListenerId::Loopback
    };

    let text = String::from_utf8_lossy(rest);
    let mut lines = text.lines();
    let Ok(uri) = lines.next().unwrap_or_default().parse::<http::Uri>() else {
        return;
    };
    let mut req = http::Request::builder().method("POST").uri(uri);
    if flags & 16 == 0 {
        let name = if flags & 32 != 0 { "localhost" } else { "127.0.0.1" };
        req = req.header(HOST, format!("{name}:{PORT}"));
    }
    if let Some(token) = TOKENS.get(usize::from(flags & 3)) {
        req = if flags & 8 != 0 {
            req.header("x-api-key", *token)
        } else {
            req.header(AUTHORIZATION, format!("Bearer {token}"))
        };
    }
    let Ok(mut req) = req.body(()) else {
        return;
    };
    for line in lines.take(16) {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if let (Ok(name), Ok(value)) = (
            HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(value.trim()),
        ) {
            req.headers_mut().append(name, value);
        }
    }
    let (parts, ()) = req.into_parts();

    match admit::head(&parts, &on, PORT, &registry, &providers) {
        Ok(a) => {
            assert_eq!(a.registration.listener, on, "a token is good on its own listener only");
            match (a.registration.class, &a.route) {
                (Class::Agent, Route::Chain) => {}
                (Class::Editor, Route::Provider { id, rest }) => {
                    let p = providers.get(id).expect("a known provider");
                    let path = rest.split_once('?').map_or(rest.as_str(), |(p, _)| p);
                    assert!(p.kind.paths().contains(&path), "{id} {rest}");
                    assert!(!rest.contains("..") && !rest.contains('#'));
                }
                (class, route) => panic!("{class:?} was given {route:?}"),
            }
            if on == ListenerId::Loopback {
                assert_eq!(parts.headers.get_all(HOST).iter().count(), 1);
            }
            if let Some(n) = parts
                .headers
                .get(CONTENT_LENGTH)
                .and_then(|l| l.to_str().ok()?.parse::<u64>().ok())
            {
                assert!(n <= MAX_BODY);
            }
        }
        Err(r) => {
            assert!(matches!(r.status, 400 | 401 | 404 | 413), "{}", r.status);
            serde_json::from_slice::<serde_json::Value>(&r.body()).expect("a JSON error body");
        }
    }
});
