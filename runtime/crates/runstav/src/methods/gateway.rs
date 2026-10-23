//! The gateway: registrations, keys, the provider table and spend.  Every method here is the front's own (Task 22):
//! the registrations live in `runtime.db` (hashes only), the keys in the hub's memory, and spend is read from
//! `work.db`; nothing of it is forwarded to the Lisp backend.  None writes work.db (the engine's spend rows are its
//! own), so a read-only hub still registers.

use super::{Empty, method};
use crate::registry::Method;
use crate::types::{AgentName, Bounded, Id, ProviderKeys, SessionId, TaskRef, Usd, null_as_empty};
use crate::url::{ProviderBase, UrlRefusal, provider_base};
use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::de::{self, Deserializer};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::borrow::Cow;

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SpendParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<TaskRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<AgentName>,
}

/// What the requests came to.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Spend {
    pub input: u64,
    pub output: u64,
    /// US dollars: a JSON number, which a whole amount may spell `2.0` (R-T18-2).
    pub cost: f64,
    pub requests: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum DataCollection {
    Deny,
    Allow,
}

/// OpenRouter restrictions (agents.eld's `:openrouter`): an unknown one is refused, and so is a slug that is not one
/// (`^[A-Za-z0-9][A-Za-z0-9._/-]*$`, the Lisp's strict rule; the front checks it at registration).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct OpenrouterRestrictions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub only: Option<Bounded<Vec<Bounded<String, 128>>, 64>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ignore: Option<Bounded<Vec<Bounded<String, 128>>, 64>>,
    #[serde(
        rename = "data-collection",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub data_collection: Option<DataCollection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zdr: Option<bool>,
}

/// One step of a chain: `[provider, model-or-null]`.
pub type ChainStep = Bounded<Vec<Option<Bounded<String, 128>>>, 2>;

/// No `Debug`: it may hold keys.
#[derive(Deserialize, Serialize, JsonSchema)]
pub struct RegisterParams {
    /// The providers to try in turn: `[[provider, model-or-null]…]`, at most 16.  At least one must be usable now (a
    /// provider of the table that speaks Messages and whose key the hub holds), or the registration is refused.
    pub chain: Bounded<Vec<ChainStep>, 16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<TaskRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<AgentName>,
    /// USD for the whole job; absent: the job's `data.budget` in work.db.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget: Option<Usd>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub openrouter: Option<OpenrouterRestrictions>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keys: Option<ProviderKeys>,
    /// The pid of the Emacs whose agent it is: its registrations go when it does (absent: the caller's pid).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<u64>,
    /// A live session (`mcp/session`): the token is issued for its own `gateway.sock`, and good only there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sid: Option<SessionId>,
}

/// A registration's token and where it is good: the loopback listener's `url`, or a session's `socket`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Registration {
    pub token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub socket: Option<String>,
    /// The restrictions kept; absent when none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub openrouter: Option<Value>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct UnregisterParams {
    pub token: Bounded<String, 128>,
}

/// No `Debug`: it holds keys.
#[derive(Deserialize, Serialize, JsonSchema)]
pub struct KeysParams {
    pub keys: ProviderKeys,
}

/// The ids of the providers whose key the hub holds, never a key: `gateway/keys-held`'s answer, and the data of the
/// event `gateway/keys-changed`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct KeysHeld {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub providers: Vec<Id>,
}

/// The editor's token (class `editor`: the `/p/PROVIDER/…` paths only) and the loopback URL it is good on.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditorToken {
    pub token: String,
    pub url: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SetBudgetParams {
    pub job: Id,
    pub budget: Usd,
}

/// A provider's API family: it decides the paths an editor token reaches (`/p/PROVIDER/…`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ProviderKind {
    Openai,
    Ollama,
    Llamacpp,
    Tei,
    Anthropic,
}

/// How a provider takes its key; `none` is a keyless (local) provider.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderAuth {
    Bearer,
    XApiKey,
    None,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ProviderCap {
    Chat,
    Fim,
    Embed,
}

/// A provider's price, US dollars per million tokens.
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ProviderPrice {
    pub input: Usd,
    pub output: Usd,
}

/// A provider's base URL: `https`, or `http` for any host (`url::provider_base`); `http` off loopback is clear text,
/// allowed with a warning for a keyed provider (the user's answer 4).  A bad one is refused with its path.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct ProviderUrl(String);

impl ProviderUrl {
    /// The longest URL, in characters.
    pub const MAX: usize = 2048;

    pub fn new(s: impl Into<String>) -> Result<Self, String> {
        let s = s.into();
        if s.chars().count() > Self::MAX {
            return Err(format!(
                "not a provider's URL: at most {} characters",
                Self::MAX
            ));
        }
        provider_base(&s).map_err(|r| {
            match r {
                UrlRefusal::Scheme => "not a provider's URL: https, or http for any host",
                UrlRefusal::Transport | UrlRefusal::Malformed => {
                    "not a provider's URL: a host, and no user, password, fragment or control character"
                }
            }
            .to_string()
        })?;
        Ok(Self(s))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The URL as the rule reads it (its host, and whether it is clear text).
    pub fn base(&self) -> ProviderBase {
        provider_base(&self.0).expect("checked when it was made")
    }
}

impl<'de> Deserialize<'de> for ProviderUrl {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Self::new(String::deserialize(d)?).map_err(de::Error::custom)
    }
}

impl JsonSchema for ProviderUrl {
    fn schema_name() -> Cow<'static, str> {
        "ProviderUrl".into()
    }
    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "string", "maxLength": 2048,
                      "description": "a provider's base URL: https, or http for any host (clear text off loopback)"})
    }
}

/// One provider of the table the editor hands over (no key: keys come by `gateway/keys`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ProviderConfig {
    pub id: Id,
    pub kind: ProviderKind,
    pub base: ProviderUrl,
    pub auth: ProviderAuth,
    /// It speaks Anthropic's Messages API, so an agent's chain may use it.
    pub messages: bool,
    pub caps: Bounded<Vec<ProviderCap>, 3>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub price: Option<ProviderPrice>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ProvidersParams {
    /// The whole table: it replaces the one before.
    pub providers: Bounded<Vec<ProviderConfig>, 64>,
}

/// A warning about one provider (a keyed one whose key travels in clear text).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProviderWarning {
    pub provider: String,
    pub text: String,
}

/// `config/providers`' answer: how many providers the table now has, and the warnings.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProvidersApplied {
    pub applied: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub warnings: Vec<ProviderWarning>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "spend", Spend(SpendParams) -> Spend,
            classes: [User, Agent, Service], writes: false, home: Front,
            doc: "what a job's, task's or agent's requests came to (an agent: its own job's)",
        ),
        method!(
            "gateway/register", GatewayRegister(RegisterParams) -> Registration,
            classes: [User], writes: false, home: Front,
            doc: "an agent's token and where it is good (the URL, or a session's socket); its keys go to the hub's memory",
        ),
        method!(
            "gateway/unregister", GatewayUnregister(UnregisterParams) -> bool,
            classes: [User], writes: false, home: Front,
            doc: "the token no longer forwards",
        ),
        method!(
            "gateway/keys", GatewayKeys(KeysParams) -> bool,
            classes: [User], writes: false, home: Front,
            doc: "provider keys to the hub's memory (never a file, never the backend)",
        ),
        method!(
            "gateway/set-budget", GatewaySetBudget(SetBudgetParams) -> bool,
            classes: [User], writes: false, home: Front,
            doc: "seam: every registration of the job gets the budget (drgnx-gateway-set-budget)",
        ),
        method!(
            "config/providers", ConfigProviders(ProvidersParams) -> ProvidersApplied,
            classes: [User], writes: false, home: Front,
            doc: "the gateway's provider table (no keys), replaced; a keyed provider over clear text is warned about",
        ),
        method!(
            "gateway/editor-token", GatewayEditorToken(Empty) -> EditorToken,
            classes: [User], writes: false, home: Front,
            doc: "the caller's editor token (loopback only, the /p/PROVIDER/… paths; one per owner, kept across a restart)",
        ),
        method!(
            "gateway/keys-held", GatewayKeysHeld(Empty) -> KeysHeld,
            classes: [User], writes: false, home: Front,
            doc: "the providers whose key the hub holds (ids only)",
        ),
    ]
}

#[cfg(test)]
mod tests {
    use crate::registry::find;
    use serde_json::json;

    #[test]
    fn a_bad_provider_url_is_refused_with_its_path() {
        let m = find("config/providers").unwrap();
        let one = |base: &str| {
            json!({"providers": [{"id": "p", "kind": "openai", "base": base, "auth": "bearer",
                                  "messages": false, "caps": ["chat"]}]})
        };
        for bad in [
            "ftp://example.com",
            "http://user@host",
            "https://h/x#f",
            "/srv/x",
        ] {
            let e = (m.decode)(&one(bad)).err().unwrap();
            assert_eq!(e.path.as_deref(), Some("providers[0].base"), "{bad}: {e:?}");
        }
        for good in [
            "https://openrouter.ai/api/v1",
            "http://127.0.0.1:11434",
            "http://192.0.2.10:8080",
        ] {
            assert!((m.decode)(&one(good)).is_ok(), "{good}");
        }
    }

    #[test]
    fn a_budget_reads_as_a_whole_number_or_not() {
        // R-T18-2: `2` and `2.0` are the same amount
        let m = find("gateway/set-budget").unwrap();
        for b in [json!(2), json!(2.0), json!(0.25)] {
            assert!((m.decode)(&json!({"job": "j", "budget": b})).is_ok(), "{b}");
        }
        let e = (m.decode)(&json!({"job": "j", "budget": -1}))
            .err()
            .unwrap();
        assert_eq!(e.path.as_deref(), Some("budget"));
        let spend = find("spend").unwrap();
        for cost in [json!(2), json!(2.0)] {
            let v = json!({"input": 1, "output": 2, "cost": cost, "requests": 1});
            assert_eq!((spend.check_result)(&v).unwrap()["cost"], json!(2.0));
        }
    }
}
