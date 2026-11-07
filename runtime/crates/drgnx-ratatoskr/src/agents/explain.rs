//! `agents/explain {id, item}` (Task 40): the facts behind each chip of the agent panel. Facts only: a value the hub
//! does not know is left out, never guessed. The session builds [`Inputs`] from its own state; this module words them.

use super::config::{provider_name, why_outside};
use super::lock::allowed_modes;
use crate::settings::profiles::Provider;
use runstav::methods::agents::{Context, ExplainItem, Fact, Usage};

/// What the hub knows of a session, for any chip.
#[derive(Default)]
pub struct Inputs {
    pub role: String,
    pub agent: String,
    pub provider: Option<Provider>,
    pub enforced: bool,
    pub enforced_why: Option<String>,
    /// The mode the adapter reported at the session's start.
    pub mode: Option<String>,
    pub usage: Option<Usage>,
    /// The adapter's own `_drgnx/context` breakdown.
    pub context: Option<Context>,
    pub model: Option<String>,
    pub ai: Option<String>,
    pub status: String,
    pub waiting_on: Option<String>,
    /// The titles of the permission requests waiting for the user.
    pub pending: Vec<String>,
    pub turns: u64,
    pub tokens: u64,
    /// The `mcpCapabilities` the agent advertised.
    pub mcp: Option<serde_json::Value>,
}

fn fact(name: &str, value: impl Into<String>) -> Fact {
    Fact {
        name: name.into(),
        value: value.into(),
    }
}

/// The facts behind ITEM.
pub fn explain(item: ExplainItem, i: &Inputs) -> Vec<Fact> {
    let mut f = Vec::new();
    match item {
        ExplainItem::Context => {
            if let Some(c) = &i.context {
                f.push(fact("source", "the adapter's own count (`_drgnx/context`)"));
                f.push(fact("used", format!("{} of {} tokens", c.used, c.size)));
                for p in c.parts.0.iter() {
                    let kind = serde_json::to_value(p.kind)
                        .ok()
                        .and_then(|v| v.as_str().map(str::to_owned))
                        .unwrap_or_default();
                    f.push(fact(&kind, format!("{} tokens", p.tokens)));
                }
                if let Some(n) = c.compact_frees {
                    f.push(fact("compaction frees", format!("{n} tokens")));
                }
            } else if let Some(u) = &i.usage {
                f.push(fact("source", "the agent's `usage_update`"));
                if let (Some(used), Some(size)) = (u.used, u.size) {
                    f.push(fact("used", format!("{used} of {size} tokens")));
                }
            } else {
                f.push(fact(
                    "source",
                    "none: the agent has not reported its context",
                ));
            }
        }
        ExplainItem::Cost => {
            f.push(fact("turns", i.turns.to_string()));
            f.push(fact("tokens in finished turns", i.tokens.to_string()));
            match i.usage.as_ref().and_then(|u| u.cost.as_ref()) {
                Some(c) => f.push(fact("cost reported", c.to_string())),
                None => f.push(fact("cost reported", "none: the agent reports no cost")),
            }
        }
        ExplainItem::Mode => {
            f.push(fact(
                "mode",
                i.mode.clone().unwrap_or_else(|| "not reported".into()),
            ));
            f.push(fact(
                "row",
                format!(
                    "matrix column: role {}, agent {}, provider {}",
                    i.role,
                    i.agent,
                    i.provider.map_or("none", provider_name)
                ),
            ));
            match i.provider {
                Some(p) => {
                    let lock = if i.enforced {
                        format!("{} lock, enforced", provider_name(p))
                    } else {
                        format!(
                            "{} lock, not enforced ({})",
                            provider_name(p),
                            i.enforced_why.as_deref().unwrap_or("no reason given")
                        )
                    };
                    f.push(fact("lock", lock));
                    let a = allowed_modes(p);
                    f.push(fact(
                        "allowed switches",
                        if a.is_empty() {
                            "none".into()
                        } else {
                            a.join(", ")
                        },
                    ));
                    f.push(fact("other modes are refused because", why_outside(p)));
                }
                None => f.push(fact("lock", "none: this agent has no lock")),
            }
        }
        ExplainItem::Model => {
            f.push(fact(
                "model",
                i.model
                    .clone()
                    .unwrap_or_else(|| "the agent's own default".into()),
            ));
            if let Some(ai) = &i.ai {
                f.push(fact("provider environment", ai.clone()));
            }
            f.push(fact(
                "switching",
                "free within the profile; the agent refuses a model it does not have",
            ));
        }
        ExplainItem::Waiting => {
            f.push(fact("status", i.status.clone()));
            if let Some(w) = &i.waiting_on {
                f.push(fact("waiting on", w.clone()));
            }
            for p in &i.pending {
                f.push(fact("permission waiting", p.clone()));
            }
        }
        ExplainItem::Mcp => {
            f.push(fact(
                "hub server",
                "drgnx (the coordination and tracker tools)",
            ));
            match &i.mcp {
                Some(m) => f.push(fact("agent supports", m.to_string())),
                None => f.push(fact("agent supports", "not reported")),
            }
        }
    }
    f
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inputs() -> Inputs {
        Inputs {
            role: "chat".into(),
            agent: "fork".into(),
            provider: Some(Provider::Claude),
            enforced: true,
            mode: Some("default".into()),
            ..Inputs::default()
        }
    }

    fn get<'a>(f: &'a [Fact], n: &str) -> &'a str {
        &f.iter()
            .find(|x| x.name == n)
            .unwrap_or_else(|| panic!("no fact {n}: {f:?}"))
            .value
    }

    #[test]
    fn mode_names_the_lock_and_the_row() {
        let f = explain(ExplainItem::Mode, &inputs());
        assert_eq!(get(&f, "lock"), "claude lock, enforced");
        assert_eq!(
            get(&f, "row"),
            "matrix column: role chat, agent fork, provider claude"
        );
        assert_eq!(get(&f, "allowed switches"), "default, plan");
        assert!(get(&f, "other modes are refused because").contains("matrix"));
        let mut i = inputs();
        i.provider = Some(Provider::Codex);
        i.enforced = false;
        i.enforced_why = Some("no full sandbox".into());
        let f = explain(ExplainItem::Mode, &i);
        assert_eq!(
            get(&f, "lock"),
            "codex lock, not enforced (no full sandbox)"
        );
        assert_eq!(get(&f, "allowed switches"), "none");
    }
}
