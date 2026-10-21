//! The gateway: registrations, keys and spend.

use super::method;
use crate::registry::Method;
use crate::types::{AgentName, Bounded, Id, ProviderKeys, TaskRef, Usd};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

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
    /// US dollars.
    pub cost: f64,
    pub requests: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum DataCollection {
    Deny,
    Allow,
}

/// OpenRouter restrictions (agents.eld's `:openrouter`): an unknown one is refused.
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
    /// The providers to try in turn: `[[provider, model-or-null]…]`, at most 16.
    pub chain: Bounded<Vec<ChainStep>, 16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<TaskRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<AgentName>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget: Option<Usd>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub openrouter: Option<OpenrouterRestrictions>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keys: Option<ProviderKeys>,
    /// The pid of the Emacs whose agent it is: its registrations go when it does.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Registration {
    pub token: String,
    pub url: String,
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

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "spend", Spend(SpendParams) -> Spend,
            classes: [User, Agent, Service], writes: false,
            doc: "what a job's, task's or agent's requests came to (an agent: its own job's)",
        ),
        method!(
            "gateway/register", GatewayRegister(RegisterParams) -> Registration,
            classes: [User], writes: true,
            doc: "an agent's token and the gateway's URL; its keys go to the gateway's memory",
        ),
        method!(
            "gateway/unregister", GatewayUnregister(UnregisterParams) -> bool,
            classes: [User], writes: true,
            doc: "the token no longer forwards",
        ),
        method!(
            "gateway/keys", GatewayKeys(KeysParams) -> bool,
            classes: [User], writes: false,
            doc: "provider keys to the gateway's memory (never a file)",
        ),
    ]
}
