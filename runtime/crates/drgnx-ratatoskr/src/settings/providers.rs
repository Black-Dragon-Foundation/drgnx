//! The AI runtime settings (ai.eld folded into settings.el): provider entries, role chains, and the provider table
//! the gateway takes (design §11.1's table), as core/drgnx-ai.el and `drgnx-hub--provider-json`
//! (core/drgnx-hub-client.el) have them.

use huginn::value::{Datum, Node};
use runstav::methods::gateway::{ProviderConfig, ProviderKind};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::profiles::Alist;
use super::{Bad, de};

/// A provider: an id → `(:name :kind :url :key-env :caps :price :messages :auth)`, as `drgnx-ai-presets` and
/// `drgnx-ai-providers` hold it.  Never a key (`:key-env` names the variable that holds it).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct ProviderEntry {
    /// The alist key.
    #[serde(skip_deserializing)]
    pub id: String,
    pub name: Option<String>,
    pub kind: Option<ProviderKind>,
    pub url: Option<String>,
    pub key_env: Option<String>,
    #[serde(default)]
    pub caps: Vec<String>,
    /// `(IN . OUT)`, US dollars per million tokens.
    pub price: Option<(f64, f64)>,
    #[serde(default)]
    pub messages: bool,
    /// `x-api-key`: the key goes in that header (else `Authorization: Bearer`).
    pub auth: Option<String>,
}

/// A role's chain: `(ROLE (PROVIDER . MODEL)…)`, tried in order.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct RoleChain {
    pub role: String,
    pub chain: Vec<ChainStep>,
}

/// `(PROVIDER . MODEL)`; `(PROVIDER)` is the provider's own model.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct ChainStep {
    pub provider: String,
    pub model: Option<String>,
}

/// `drgnx-ai-providers` (and `drgnx-ai-presets`): an alist ID → plist.  A price that is not two amounts is a mistake.
pub fn entries(node: &Node) -> Result<Vec<ProviderEntry>, Bad> {
    let Alist(pairs) = de::<Alist<ProviderEntry>>(node)?;
    let mut out = Vec::with_capacity(pairs.len());
    for (id, mut p) in pairs {
        if let Some((i, o)) = p.price
            && !(i >= 0.0 && o >= 0.0)
        {
            return Err(Bad::at(
                node,
                Some(format!("{id}.price")),
                "(IN . OUT) dollars per million tokens, two numbers of 0 or more",
            ));
        }
        p.id = id;
        out.push(p);
    }
    Ok(out)
}

/// `drgnx-ai-roles` (and `drgnx-ai-default-roles`): `((ROLE (PROVIDER . MODEL)…)…)`, a MODEL a string or nil.
pub fn roles(node: &Node) -> Result<Vec<RoleChain>, Bad> {
    let mut out = Vec::new();
    for (i, item) in list(node)
        .ok_or_else(|| Bad::at(node, None, "expected ((ROLE (PROVIDER . MODEL)…)…)"))?
        .iter()
        .enumerate()
    {
        let Datum::List(parts) = &item.datum else {
            return Err(Bad::at(
                item,
                Some(format!("[{i}]")),
                "expected (ROLE (PROVIDER . MODEL)…)",
            ));
        };
        let role = symbol(&parts[0])
            .ok_or_else(|| Bad::at(&parts[0], Some(format!("[{i}]")), "a role is a symbol"))?;
        let mut chain = Vec::new();
        for (j, step) in parts[1..].iter().enumerate() {
            let at = || Some(format!("{role}[{j}]"));
            let (provider, model) = match &step.datum {
                Datum::List(p) if p.len() == 1 => (&p[0], None),
                Datum::Cons(p, tail) if p.len() == 1 => match &tail.datum {
                    Datum::Str(m) => (&p[0], Some(m.clone())),
                    _ => {
                        return Err(Bad::at(
                            tail,
                            at(),
                            "a model is a string, or nil for the provider's own",
                        ));
                    }
                },
                _ => {
                    return Err(Bad::at(
                        step,
                        at(),
                        "expected (PROVIDER . MODEL) or (PROVIDER)",
                    ));
                }
            };
            let provider = symbol(provider)
                .ok_or_else(|| Bad::at(provider, at(), "a provider is a symbol"))?;
            chain.push(ChainStep {
                provider: provider.to_string(),
                model,
            });
        }
        out.push(RoleChain {
            role: role.to_string(),
            chain,
        });
    }
    Ok(out)
}

/// The elements of a proper list (`nil` is empty).
fn list(node: &Node) -> Option<&[Node]> {
    match &node.datum {
        Datum::List(items) => Some(items),
        Datum::Sym(s) if s == "nil" => Some(&[]),
        _ => None,
    }
}

/// A symbol's name; not `nil`, `t` or a keyword.
fn symbol(node: &Node) -> Option<&str> {
    match &node.datum {
        Datum::Sym(s) if s != "nil" && s != "t" && !s.starts_with(':') => Some(s),
        _ => None,
    }
}

/// The providers in effect: the PRESETS, with each of the USER's entries replacing the preset of its id and going
/// first, as `drgnx-ai-providers' (core/drgnx-ai.el) orders them.
pub fn effective<'a>(
    presets: &'a [ProviderEntry],
    user: &'a [ProviderEntry],
) -> Vec<&'a ProviderEntry> {
    let mut all: Vec<&ProviderEntry> = presets.iter().collect();
    for p in user {
        all.retain(|q| q.id != p.id);
        all.insert(0, p);
    }
    all
}

/// The provider table: each provider in effect as `config/providers` takes it, and the ones left out because the
/// hub would refuse them (a URL that is not a provider's), each with why.  A provider with no URL or kind is left
/// out silently, as the editor's encoder leaves it out.
pub fn table(
    presets: &[ProviderEntry],
    user: &[ProviderEntry],
) -> (Vec<ProviderConfig>, Vec<String>) {
    let (mut table, mut skipped) = (Vec::new(), Vec::new());
    for p in effective(presets, user) {
        let Some(json) = wire(p) else { continue };
        match serde_json::from_value::<ProviderConfig>(json) {
            Ok(c) => table.push(c),
            Err(e) => skipped.push(format!("{}: {e}", p.id)),
        }
    }
    (table, skipped)
}

/// P as `config/providers`' JSON (design §11.1's table), or none when it cannot be a provider.
fn wire(p: &ProviderEntry) -> Option<Value> {
    let (kind, url) = (p.kind?, p.url.as_ref()?);
    let auth = match (&p.key_env, p.auth.as_deref()) {
        (None, _) => "none",
        (Some(_), Some("x-api-key")) => "x-api-key",
        (Some(_), _) => "bearer",
    };
    let mut caps: Vec<&str> = Vec::new();
    for c in &p.caps {
        if matches!(c.as_str(), "chat" | "fim" | "embed") && !caps.contains(&c.as_str()) {
            caps.push(c);
        }
    }
    let mut v = json!({"id": p.id, "kind": kind, "base": url, "auth": auth, "messages": p.messages, "caps": caps});
    if let Some((input, output)) = p.price {
        v["price"] = json!({"input": input, "output": output});
    }
    Some(v)
}
