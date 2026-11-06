//! Plugin abilities as MCP tools (`docs/guide/plugins.md`, "Abilities"; `docs/develop/coordination.md`, "The tools"): a
//! session whose plugins have abilities gets a second MCP server, `drgnx-plugins`, on its own `plugins.sock`
//! ([`crate::sessions`]), apart from the hub's own tools. Every connection to it is offered the abilities of the
//! plugins that run for the session's project, minus all of them when the session's `plugin.abilities` cell is Never.
//!
//! - **Offered:** an enabled plugin's abilities, named `PLUGIN_ABILITY`, with the manifest's description and schema
//!   ([`offered`]). A plugin that is not approved and enabled for the project has none. The list is made per connection
//!   from the settings as they are, so a new connection sees a new set; the tools of a set are kept by its hashes.
//! - **A call** runs only within its grants, in this order: the plugin is still enabled for the project and the
//!   arguments fit the schema; the `before-tool` hooks at this server ([`crate::hook_points::at_hub_server`]: they may
//!   refuse the call or change its arguments, which the schema then checks again); the matrix row `plugin.abilities` for the session's columns, on the arguments that will run (Never
//!   refuses; an Ask makes a `matrix` card naming the tool and showing the arguments, and the call waits for the user
//!   with no deadline until the card is answered, the call is cancelled or the session's connection closes: whatever
//!   ends the wait withdraws the card); then [`brokkr::Host::call_ability`] with the session's I/O, whose HTTP reaches
//!   only the hosts the manifest names. The 30 s deadline covers the WASM call alone.

use std::sync::{Arc, Weak};

use brokkr::{AbilityDecl, CallError};
use mimir::{ArgsError, BoxFuture, Tool, ToolResult};
use norn::matrix::{Action, Verdict, Who};
use serde_json::Value;

use crate::agents::launch::NetCell;
use crate::front::Front;
use crate::matrix_gate::{ActionCtx, Gate};
use crate::plugins::io::IoCtx;
use crate::plugins::{Plugin, Plugins};

#[cfg(test)]
mod tests;

/// The tools a connection to `plugins.sock` is served.
pub type AbilityList = Arc<[Box<dyn Tool<AbilityCtx>>]>;

/// What an ability runs as: the hub, and the session whose socket it was called on, for its columns.
pub struct AbilityCtx {
    front: Weak<Front>,
    sid: String,
    who: Who,
}

impl AbilityCtx {
    pub fn new(front: &Arc<Front>, sid: &str, who: Who) -> AbilityCtx {
        AbilityCtx {
            front: Arc::downgrade(front),
            sid: sid.to_owned(),
            who,
        }
    }
}

/// One ability of an approved plugin. Cheap to clone: the plugin and its declaration are shared.
#[derive(Clone)]
pub struct AbilityTool {
    plugin: Arc<Plugin>,
    decl: Arc<AbilityDecl>,
    /// `PLUGIN_ABILITY`.
    name: Arc<str>,
}

impl AbilityTool {
    fn new(plugin: &Arc<Plugin>, decl: &AbilityDecl) -> AbilityTool {
        AbilityTool {
            name: format!("{}_{}", plugin.manifest.name.as_str(), decl.name.as_str()).into(),
            plugin: plugin.clone(),
            decl: Arc::new(decl.clone()),
        }
    }
}

/// The project of session SID's plan run, if it has one.
pub(crate) fn project_of(front: &Front, sid: &str) -> Option<String> {
    front.core.runs.scopes().get(sid).and_then(|(_, p)| p)
}

fn action_ctx(front: &Front, sid: &str) -> ActionCtx {
    ActionCtx::of_session(&front.core.runs.scopes(), sid)
}

/// What a connection of session SID (columns WHO) is offered now: the abilities of the plugins that run for its
/// project, none when its `plugin.abilities` cell is Never.
pub async fn offered(front: &Front, sid: &str, who: &Who) -> AbilityList {
    let none = || -> AbilityList { Vec::<Box<dyn Tool<AbilityCtx>>>::new().into() };
    let plugins = &front.core.plugins;
    let set = plugins.abilities_for(project_of(front, sid).as_deref());
    if set.is_empty() {
        return none();
    }
    let eff = front
        .core
        .matrix
        .effective_now(
            &front.settings,
            &front.writer,
            who.clone(),
            action_ctx(front, sid),
        )
        .await;
    match eff {
        Ok(e) if e.cell(Action::PluginAbilities).verdict != Verdict::Never => {}
        _ => return none(),
    }
    let key = Plugins::set_key(&set);
    let tools = {
        let mut kept = plugins.tools.lock().unwrap_or_else(|e| e.into_inner());
        match kept.get(&key) {
            Some(t) => t.clone(),
            None => {
                let made: Vec<AbilityTool> = set
                    .iter()
                    .flat_map(|p| p.manifest.abilities.iter().map(|a| AbilityTool::new(p, a)))
                    .collect();
                kept.clear();
                let made = Arc::new(made);
                kept.insert(key, made.clone());
                made
            }
        }
    };
    tools
        .iter()
        .map(|t| Box::new(t.clone()) as Box<dyn Tool<AbilityCtx>>)
        .collect::<Vec<_>>()
        .into()
}

/// The `before-tool` hooks of the call of the tool NAME, at this server (kind `drgnx`, `mcp__drgnx-plugins__NAME`; the
/// seam leaves hub tools to their server): the arguments that will run, or the refusal.
async fn before_tool(
    front: &Front,
    ctx: &AbilityCtx,
    name: &str,
    args: Value,
) -> Result<Value, String> {
    crate::hook_points::at_hub_server(front, &ctx.sid, "drgnx-plugins", name, args).await
}

/// What a card shows of the call: the full tool name and the arguments, as compact JSON, cut at 400 bytes.
fn what(name: &str, args: &Value) -> serde_json::Value {
    let mut text = format!("{name} {args}");
    if text.len() > 400 {
        let mut cut = 400;
        while !text.is_char_boundary(cut) {
            cut -= 1;
        }
        text.truncate(cut);
        text.push_str(" …");
    }
    serde_json::json!({ "command": text })
}

/// A waiting call's card, withdrawn when the call ends (it answered, was cancelled, or its connection closed): the
/// card of a call that is gone asks nothing of the user. A card the user settled first stays settled.
struct Withdraw {
    front: Arc<Front>,
    card: i64,
}

impl Drop for Withdraw {
    fn drop(&mut self) {
        let (front, card) = (self.front.clone(), self.card);
        crate::clock::spawn("abilities:card-withdraw", async move {
            let hub = crate::dispatch::Caller {
                class: runstav::registry::Class::Service,
                sid: None,
                job: None,
                conn_id: 0,
            };
            let at = crate::clock::wall_secs();
            let r = front
                .writer
                .write(&hub, "cards/withdraw", move |tx| {
                    norn::write::cards::card_withdraw(tx, card, at)?;
                    Ok(())
                })
                .await;
            if let Err(e) = r {
                tracing::warn!("an ability's card was not withdrawn: {e:?}");
            }
            front.core.plugins.note_withdrawn();
        });
    }
}

/// The matrix's answer to this call: through, or why not. An Ask waits for the card's answer.
async fn gate(
    front: &Arc<Front>,
    ctx: &AbilityCtx,
    name: &str,
    args: &Value,
) -> Result<(), String> {
    let facts = serde_json::from_value(what(name, args)).unwrap_or_default();
    let action = ActionCtx {
        facts,
        ..action_ctx(front, &ctx.sid)
    };
    let first = front
        .core
        .matrix
        .decide(
            &front.settings,
            &front.writer,
            ctx.who.clone(),
            Action::PluginAbilities,
            action,
        )
        .await;
    let card = match first {
        Gate::Allow => return Ok(()),
        Gate::Never(why) => return Err(why),
        Gate::Ask(card) if card > 0 => card,
        Gate::Ask(_) => {
            return Err("plugin.abilities needs the user's yes and no card could be made".into());
        }
    };
    let _withdraw = Withdraw {
        front: front.clone(),
        card,
    };
    loop {
        // registered before the card is read, so an answer in between is not missed
        let mut wait = front.core.plugins.wait_card(card);
        let (gate, at) = (front.core.matrix.clone(), crate::clock::wall_secs());
        let now = front
            .writer
            .db
            .read(move |c| Ok(gate.recheck(c, card, at)))
            .await
            .map_err(|e| format!("{e:?}"))?;
        match now {
            Gate::Allow => return Ok(()),
            Gate::Never(why) => return Err(why),
            Gate::Ask(_) => {
                let _ = (&mut wait.settled).await;
            }
        }
    }
}

impl AbilityTool {
    async fn run(&self, ctx: &AbilityCtx, args: Value) -> Result<Value, String> {
        let front = ctx.front.upgrade().ok_or("the hub is ending")?;
        let project = project_of(&front, &ctx.sid);
        let enabled = front.core.plugins.abilities_for(project.as_deref());
        if !enabled.iter().any(|p| p.hash == self.plugin.hash) {
            return Err(format!(
                "{} is not enabled for this project",
                self.plugin.manifest.name.as_str()
            ));
        }
        let args = before_tool(&front, ctx, &self.name, args).await?;
        brokkr::schema::check(&self.decl.input_schema, &args)
            .map_err(|e| format!("{}: {}", e.path, e.message))?;
        gate(&front, ctx, &self.name, &args).await?;
        // the hub's one host, and the plugin as loaded for its approved hash
        let plugins = &front.core.plugins;
        let (loaded, failed) = crate::hook_points::load(plugins, std::slice::from_ref(&self.plugin));
        let Some(loaded) = loaded.into_iter().next() else {
            return Err(failed.into_iter().next().map(|(_, why)| why).unwrap_or_default());
        };
        let host = plugins.host()?;
        let io = crate::plugins::host_io(
            &front,
            Some((IoCtx::Session(ctx.sid.clone()), NetCell::ProviderOnly)),
            &[&self.plugin.manifest],
        )
        .map_err(|e| e.message)?;
        host.call_ability(&loaded, self.decl.name.as_str(), args, io)
            .await
            .map_err(|e| match e {
                CallError::Plugin(m) => m,
                other => other.to_string(),
            })
    }
}

impl Tool<AbilityCtx> for AbilityTool {
    fn name(&self) -> &str {
        &self.name
    }

    fn description(&self) -> &str {
        &self.decl.description
    }

    fn input_schema(&self) -> Value {
        self.decl.input_schema.clone()
    }

    fn check(&self, args: &Value) -> Result<(), ArgsError> {
        brokkr::schema::check(&self.decl.input_schema, args).map_err(|e| ArgsError {
            path: e.path,
            message: e.message,
        })
    }

    fn call<'a>(&'a self, ctx: &'a AbilityCtx, args: Value) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            match self.run(ctx, args).await {
                Ok(v) => ToolResult::Ok {
                    text: v.to_string(),
                    structured: v.is_object().then_some(v),
                },
                Err(e) => ToolResult::Err(e),
            }
        })
    }
}
