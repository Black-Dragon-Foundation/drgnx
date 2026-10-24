//! The agents' runtime settings (agents.eld folded into settings.el): profiles, routes, the MCP servers and
//! OpenRouter's restrictions, decoded as the Lisp schema `drgnx-agents-config-schema` (core/drgnx-agents.el) has
//! them.  The Lisp schema is the oracle (call 6): a key it does not name is ignored there and here.

use std::marker::PhantomData;

use huginn::value::Node;
use runstav::methods::gateway::DataCollection;
use serde::de::{MapAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize};

use super::{Bad, de};

/// What a message to a busy agent does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Queue,
    Steer,
    Interrupt,
}

/// The five tracker tools: on by default.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TrackerTools {
    On,
    Off,
}

/// An agent profile (call 6): a name → `(:command LIST :env ("NAME=value"…) :mode M :ai ENV :model M
/// :tracker-tools on|off :doc LINE)`, and the built-in profiles' `:job-safe`.  Consumed by phases 5 and 6.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct AgentProfile {
    /// The alist key.
    #[serde(skip_deserializing)]
    pub name: String,
    /// The program and its arguments.
    pub command: Vec<String>,
    /// `NAME=value` pairs added to its environment.
    #[serde(default)]
    pub env: Vec<String>,
    pub mode: Option<Mode>,
    /// The provider environment it gets (`claude-openrouter`, …).
    pub ai: Option<String>,
    pub model: Option<String>,
    pub tracker_tools: Option<TrackerTools>,
    pub doc: Option<String>,
    /// A job may run it (the built-in Claude profiles).
    #[serde(default)]
    pub job_safe: bool,
}

/// Which profiles do a job role: `(ROLE . "name")` or `(ROLE "a" "b")`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct AgentRoute {
    pub role: String,
    pub profiles: Vec<String>,
}

/// Which providers OpenRouter may use for the agents' requests: `(:only SLUGS :ignore SLUGS :data-collection
/// deny|allow :zdr t)`.  Any other key is refused, as `drgnx-gateway--restrictions-check` refuses it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct OpenRouterRestrictions {
    pub only: Option<Vec<String>>,
    pub ignore: Option<Vec<String>>,
    pub data_collection: Option<DataCollection>,
    pub zdr: Option<bool>,
}

/// An alist `((KEY . VALUE)…)` in its order (a map would sort it).
pub(crate) struct Alist<V>(pub Vec<(String, V)>);

impl<'de, V: Deserialize<'de>> Deserialize<'de> for Alist<V> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V2<V>(PhantomData<V>);
        impl<'de, V: Deserialize<'de>> Visitor<'de> for V2<V> {
            type Value = Alist<V>;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("an alist ((KEY . VALUE) …)")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Alist<V>, A::Error> {
                let mut out = Vec::new();
                while let Some(k) = map.next_key::<String>()? {
                    out.push((k, map.next_value()?));
                }
                Ok(Alist(out))
            }
        }
        d.deserialize_map(V2(PhantomData))
    }
}

/// `drgnx-agents-profiles` (and the built-in ones): an alist NAME → plist.
pub fn profiles(node: &Node) -> Result<Vec<AgentProfile>, Bad> {
    let Alist(pairs) = de::<Alist<AgentProfile>>(node)?;
    Ok(pairs
        .into_iter()
        .map(|(name, mut p)| {
            p.name = name;
            p
        })
        .collect())
}

/// `drgnx-agents-mcp`: `coordination` and `search`.
pub fn mcp(node: &Node) -> Result<Vec<String>, Bad> {
    #[derive(Deserialize)]
    #[serde(rename_all = "lowercase")]
    enum Server {
        Coordination,
        Search,
    }
    let servers: Vec<Server> = de(node)?;
    Ok(servers
        .into_iter()
        .map(|s| match s {
            Server::Coordination => "coordination".to_string(),
            Server::Search => "search".to_string(),
        })
        .collect())
}

/// `drgnx-agents-routes`: an alist ROLE → a profile's name, or a list of names.
pub fn routes(node: &Node) -> Result<Vec<AgentRoute>, Bad> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum OneOrMany {
        One(String),
        Many(Vec<String>),
    }
    let Alist(pairs) = de::<Alist<OneOrMany>>(node)?;
    Ok(pairs
        .into_iter()
        .map(|(role, p)| AgentRoute {
            role,
            profiles: match p {
                OneOrMany::One(name) => vec![name],
                OneOrMany::Many(names) => names,
            },
        })
        .collect())
}

/// `drgnx-agents-openrouter`: none when nil; a slug that is not one is refused (`^[A-Za-z0-9][A-Za-z0-9._/-]*$`,
/// the Lisp's rule).
pub fn openrouter(node: &Node) -> Result<Option<OpenRouterRestrictions>, Bad> {
    let r: Option<OpenRouterRestrictions> = de(node)?;
    if let Some(r) = &r {
        for (key, slugs) in [("only", &r.only), ("ignore", &r.ignore)] {
            if let Some(bad) = slugs.iter().flatten().find(|s| !slug(s)) {
                return Err(Bad::at(
                    node,
                    Some(key.to_string()),
                    format!("{bad:?} is not a provider slug (like \"anthropic\")"),
                ));
            }
        }
    }
    Ok(r)
}

fn slug(s: &str) -> bool {
    let mut chars = s.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '/' | '-'))
}
