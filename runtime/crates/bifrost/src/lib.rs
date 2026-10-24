//! bifrost: the gateway (docs/develop/runtime.md, "bifrost").
//!
//! - [`admit`]: request admission, token checks and the two path classes.
//! - [`rewrite`]: body rewrites (model, chain fallback, OpenRouter restrictions).
//! - [`usage`]: the SSE usage scanner; [`budget`]: cost and budget arithmetic.
//! - [`upstream`]: the HTTP/1.1 client over rustls.
//! - [`engine`]: forwarding; [`listen`]: the listeners; [`keys`]: provider keys, memory only.
//!
//! Self-contained: budget and spend go through caller-supplied traits. Provider ids, URLs and listener ids come from
//! the caller; the types below are what it hands in.

pub mod admit;
pub mod budget;
pub mod engine;
pub mod keys;
pub mod listen;
pub mod rewrite;
pub mod upstream;
pub mod usage;

use crate::budget::Price;

/// The URL type of [`Provider::base`], so a caller builds one without naming `http` itself.
pub use http::Uri;

/// A provider's API family: it decides the paths an editor token may reach ([`Kind::paths`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Openai,
    Ollama,
    Llamacpp,
    Tei,
    Anthropic,
}

impl Kind {
    /// The paths an editor token reaches under `/p/PROVIDER` for a provider of this kind (the requests the editor's
    /// `drgnx-ai--endpoint` builds). Anthropic's Messages API is the agents' class only, so it has none.
    pub fn paths(self) -> &'static [&'static str] {
        match self {
            Self::Openai => &["/chat/completions", "/completions", "/embeddings"],
            Self::Ollama => &["/api/chat", "/api/generate", "/api/embed"],
            Self::Llamacpp => &["/infill", "/v1/chat/completions", "/v1/embeddings"],
            Self::Tei => &["/embed"],
            Self::Anthropic => &[],
        }
    }
}

/// How a provider takes its key. `None` is a keyless provider (a local server): no key is needed and none is sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Auth {
    /// `Authorization: Bearer KEY`.
    Bearer,
    /// `x-api-key: KEY`.
    XApiKey,
    None,
}

/// What a provider serves.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Caps {
    pub chat: bool,
    pub fim: bool,
    pub embed: bool,
}

/// One provider of the provider table.
#[derive(Debug, Clone, PartialEq)]
pub struct Provider {
    pub id: String,
    pub kind: Kind,
    /// The provider's URL, already checked by `runstav::url::provider_base`.
    pub base: http::Uri,
    pub auth: Auth,
    /// Whether it speaks Anthropic's Messages API, so an agent's chain may use it.
    pub messages: bool,
    pub caps: Caps,
    pub price: Option<Price>,
}

impl Provider {
    /// Whether a request to it needs a key (the Lisp's `:key-env`): every provider but a keyless one.
    pub fn needs_key(&self) -> bool {
        self.auth != Auth::None
    }
}

/// One step of an agent's chain: a provider, and the model to put in the body (none: the request's own).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub provider: String,
    pub model: Option<String>,
}

/// A registration's path class (the plan's call 15).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Class {
    /// An agent: Anthropic's Messages API paths, along its chain.
    Agent,
    /// The editor: `/p/PROVIDER/REST`, one provider's own paths, passed through.
    Editor,
}

/// Where a token was issued, and so the only listener it is good on.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ListenerId {
    /// The TCP listener on 127.0.0.1.
    Loopback,
    /// A session's own Unix socket, by session id.
    Session(String),
}

/// OpenRouter's provider restrictions for an agent (agents.eld's `:openrouter`), sent on its Messages requests only.
/// Built with [`Restrictions::new`], which checks every slug.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Restrictions {
    only: Vec<String>,
    ignore: Vec<String>,
    data_collection_deny: bool,
    zdr: bool,
}

impl Restrictions {
    /// The restrictions, or the first slug that is not one: a slug matches `^[A-Za-z0-9][A-Za-z0-9._/-]*$` (the
    /// Lisp's strict rule; anything else is refused, never read as "no restriction").
    pub fn new(
        only: Vec<String>,
        ignore: Vec<String>,
        data_collection_deny: bool,
        zdr: bool,
    ) -> Result<Self, String> {
        if let Some(bad) = only.iter().chain(&ignore).find(|s| !is_slug(s)) {
            return Err(format!(
                "OpenRouter restrictions: {bad:?} is not a provider slug (like \"anthropic\")"
            ));
        }
        Ok(Self {
            only,
            ignore,
            data_collection_deny,
            zdr,
        })
    }

    pub fn only(&self) -> &[String] {
        &self.only
    }

    pub fn ignore(&self) -> &[String] {
        &self.ignore
    }

    pub fn data_collection_deny(&self) -> bool {
        self.data_collection_deny
    }

    pub fn zdr(&self) -> bool {
        self.zdr
    }

    /// Whether nothing is restricted (then a body is not touched for them).
    pub fn is_empty(&self) -> bool {
        self.only.is_empty() && self.ignore.is_empty() && !self.data_collection_deny && !self.zdr
    }
}

/// `^[A-Za-z0-9][A-Za-z0-9._/-]*$`.
fn is_slug(s: &str) -> bool {
    let mut bytes = s.bytes();
    bytes.next().is_some_and(|b| b.is_ascii_alphanumeric())
        && bytes.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'/' | b'-'))
}

/// What a token stands for. Only the token's hash is the registry's key; the token itself is never kept.
#[derive(Debug, Clone, PartialEq)]
pub struct Registration {
    pub class: Class,
    pub job: Option<String>,
    pub task: Option<String>,
    pub agent: Option<String>,
    /// The agent's providers in order; empty for the editor.
    pub chain: Vec<Step>,
    /// USD for the whole job; none for the editor.
    pub budget: Option<f64>,
    /// None for the editor.
    pub openrouter: Option<Restrictions>,
    pub listener: ListenerId,
}

impl Registration {
    /// The editor's registration: no job, agent `editor` (its spend rows), no chain, budget or restrictions, on the
    /// loopback listener.
    pub fn editor() -> Self {
        Self {
            class: Class::Editor,
            job: None,
            task: None,
            agent: Some("editor".into()),
            chain: Vec::new(),
            budget: None,
            openrouter: None,
            listener: ListenerId::Loopback,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restrictions_take_slugs_only() {
        assert!(
            Restrictions::new(
                vec!["anthropic".into(), "google-vertex".into()],
                vec![],
                true,
                false
            )
            .is_ok()
        );
        assert!(
            Restrictions::new(vec!["a/b.c_d".into()], vec!["azure".into()], false, true).is_ok()
        );
        for bad in ["", "-x", "a b", "a\"b", "é", ".x"] {
            assert!(
                Restrictions::new(vec![], vec![bad.into()], false, false).is_err(),
                "{bad:?}"
            );
        }
        assert!(Restrictions::default().is_empty());
    }
}
