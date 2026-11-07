//! The `_drgnx/panel` ACP extension, the hub's side (`docs/develop/hub.md`, "The _drgnx/panel extension").
//!
//! - `initialize` advertises `clientCapabilities._meta["_drgnx/panel"] = {version: 1}` ([`client_meta`]); the agent's
//!   `agentCapabilities._meta["_drgnx/panel"] = {version, features}` becomes the snapshot's `panel.features`
//!   ([`features`]: version 1 only, known names only).
//! - The agent's notification `_drgnx/context` sets `panel.context`, at most 4 times a second ([`Coalesce`]).
//! - The user's `agents/context-drop|pin` and `agents/compact-preview` go to the agent as `_drgnx/context/drop|pin`
//!   and `_drgnx/compact/preview`, with a 10 s deadline ([`forward`]).
//! - The agent's request `_drgnx/before_tool {sessionId, toolCall}` runs the session's `before-tool` hooks at the
//!   adapter site ([`before_tool`]) and is answered `{outcome: "allow" | "deny", reason?}`.
//!
//! Everything the agent sends is untrusted: it is checked against its schema, a method the hub does not take and a
//! payload over [`MAX_PARAMS`] are refused in the hub's words, and nothing in it is a verdict. The answer to
//! `_drgnx/before_tool` is the hooks' outcome; no field the agent sends can say allow, and no request widens what the
//! session's matrix and lock allow (the hooks there run with no matrix cell, so they can only refuse).

use super::{Session, internal, invalid, lock, now, refuse};
use crate::dispatch::Caller;
use crate::front::Front;
use hermod::Responder;
use runstav::jsonrpc;
use runstav::methods::agents::{
    ById, CompactPreview, ConfigParams, Context, ContextDropParams, ContextPinParams,
    ExplainParams, Explained, Panel as Shown,
};
use runstav::wire::Error;
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The extension's key in `_meta`.
pub(crate) const KEY: &str = "_drgnx/panel";
const VERSION: u64 = 1;
/// The features the hub knows, in the order the snapshot lists them.
pub(crate) const FEATURES: [&str; 5] = ["context", "drop", "pin", "compact-preview", "before-tool"];
/// How long the agent has to answer a forwarded user action.
const ANSWER_WITHIN: Duration = Duration::from_secs(10);
/// The most of an extension message the hub reads from an agent (its params, or its answer, as JSON text).
pub(crate) const MAX_PARAMS: usize = 256 * 1024;
/// The least time between two context breakdowns in the snapshot (4 a second).
const CONTEXT_EVERY: f64 = 0.25;

/// What `initialize` adds to the client's capabilities.
pub(crate) fn client_meta() -> Value {
    json!({ KEY: {"version": VERSION} })
}

/// The features the agent advertised in CAPS (its `agentCapabilities`): none unless its `_drgnx/panel` is version 1;
/// names the hub does not know are left out.
pub(crate) fn features(caps: Option<&Value>) -> Vec<String> {
    let Some(p) = caps.and_then(|c| c.get("_meta")).and_then(|m| m.get(KEY)) else {
        return Vec::new();
    };
    if p.get("version").and_then(Value::as_u64) != Some(VERSION) {
        return Vec::new();
    }
    let said: Vec<&str> = p
        .get("features")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    FEATURES
        .iter()
        .filter(|f| said.contains(f))
        .map(|f| (*f).to_owned())
        .collect()
}

/// What to do with a context breakdown that came now.
#[derive(Debug, PartialEq)]
pub(crate) enum Offer {
    /// Show it now.
    Now,
    /// Show the latest one after this long (a timer is armed).
    Arm(Duration),
    /// A timer is armed already: it shows the latest one.
    Wait,
}

/// The ≤ 4/s gate of `_drgnx/context`: the first breakdown shows at once, one in the next quarter second arms a timer
/// that shows the latest when it fires, and more meanwhile only replace the latest. The last one is never lost.
#[derive(Debug, Default)]
pub(crate) struct Coalesce {
    last: Option<f64>,
    armed: bool,
}

impl Coalesce {
    pub(crate) fn offer(&mut self, at: f64) -> Offer {
        if self.armed {
            return Offer::Wait;
        }
        match self.last {
            Some(t) if at - t < CONTEXT_EVERY => {
                self.armed = true;
                Offer::Arm(Duration::from_secs_f64(CONTEXT_EVERY - (at - t).max(0.0)))
            }
            _ => {
                self.last = Some(at);
                Offer::Now
            }
        }
    }

    /// The armed timer fired AT: the latest is shown now.
    pub(crate) fn fired(&mut self, at: f64) {
        self.armed = false;
        self.last = Some(at);
    }
}

#[derive(Default)]
struct State {
    latest: Option<Context>,
    shown: Option<Context>,
    gate: Coalesce,
}

/// A session's panel extension: what its agent offers, and its context breakdown.
pub(crate) struct Panel {
    features: Vec<String>,
    state: Mutex<State>,
}

impl Panel {
    /// The panel of an agent whose `initialize` answered CAPS.
    pub(crate) fn new(caps: Option<&Value>) -> Panel {
        Panel {
            features: features(caps),
            state: Mutex::new(State::default()),
        }
    }

    fn offers(&self, feature: &str) -> bool {
        self.features.iter().any(|f| f == feature)
    }

    /// The snapshot's `panel` (none when the agent offers nothing).
    pub(crate) fn snapshot(&self) -> Option<Shown> {
        if self.features.is_empty() {
            return None;
        }
        Some(Shown {
            features: self.features.clone(),
            context: lock(&self.state).shown.clone(),
        })
    }
}

/// Why the hub refuses an agent's extension message: a JSON-RPC code and the hub's words.
type Refusal = (i64, String);

fn refused(code: i64, why: impl std::fmt::Display) -> Refusal {
    (code, format!("drgnx refuses it: {why}"))
}

/// PARAMS as JSON text are within [`MAX_PARAMS`].
fn within_size(params: &Value) -> Result<(), Refusal> {
    let n = params.to_string().len();
    if n > MAX_PARAMS {
        return Err(refused(
            jsonrpc::INVALID_PARAMS,
            format!("the message is {n} bytes, over 256 KiB"),
        ));
    }
    Ok(())
}

/// PARAMS's `sessionId`, taken out, is SID (the agent's own session on this connection).
fn own_session(params: &mut Value, sid: &str) -> Result<(), Refusal> {
    match params.as_object_mut().and_then(|o| o.remove("sessionId")) {
        Some(Value::String(s)) if s == sid => Ok(()),
        Some(_) => Err(refused(
            jsonrpc::INVALID_PARAMS,
            "sessionId: not this agent's session",
        )),
        None => Err(refused(jsonrpc::INVALID_PARAMS, "sessionId: missing")),
    }
}

/// The agent's notification METHOD with PARAMS, from an agent offering FEATURES on its session SID: the context
/// breakdown it sets, or why it is dropped.
pub(crate) fn check_context(
    features: &[String],
    sid: &str,
    method: &str,
    params: Value,
) -> Result<Context, Refusal> {
    let mut params = params;
    if method != "_drgnx/context" {
        return Err(not_ours(method));
    }
    if !features.iter().any(|f| f == "context") {
        return Err(refused(
            jsonrpc::INVALID_PARAMS,
            "the agent did not offer context",
        ));
    }
    within_size(&params)?;
    own_session(&mut params, sid)?;
    serde_json::from_value(params).map_err(|e| refused(jsonrpc::INVALID_PARAMS, e))
}

/// A method the hub does not take from an agent (one it sends, or one it does not know).
fn not_ours(method: &str) -> Refusal {
    refused(
        jsonrpc::METHOD_NOT_FOUND,
        format!("it takes no {method} from an agent"),
    )
}

/// The `_drgnx/before_tool` request's params, as the agent must send them; anything else is refused (an `outcome`
/// or a `verdict` of the agent's own among them).
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct BeforeTool {
    tool_call: hermod::schema::v1::ToolCallUpdate,
}

/// The agent's request METHOD with PARAMS, from an agent offering FEATURES on its session SID: the tool call
/// (`toolCall`, as the schema reads it) of a `_drgnx/before_tool`, or the refusal it is answered with.
pub(crate) fn check_before_tool(
    features: &[String],
    sid: &str,
    method: &str,
    params: Value,
) -> Result<Value, Refusal> {
    let mut params = params;
    if method != "_drgnx/before_tool" {
        return Err(not_ours(method));
    }
    if !features.iter().any(|f| f == "before-tool") {
        return Err(refused(
            jsonrpc::INVALID_PARAMS,
            "the agent did not offer before-tool",
        ));
    }
    within_size(&params)?;
    own_session(&mut params, sid)?;
    let req: BeforeTool =
        serde_json::from_value(params).map_err(|e| refused(jsonrpc::INVALID_PARAMS, e))?;
    serde_json::to_value(&req.tool_call).map_err(|e| refused(jsonrpc::INTERNAL_ERROR, e))
}

/// An agent's `_drgnx/*` notification: a context breakdown is shown (coalesced); anything else, or one that does not
/// fit, is dropped with a warning (a notification has no answer).
pub(super) fn notification(s: &Arc<Session>, method: &str, params: Value) {
    match check_context(&s.panel.features, &s.acp.0, method, params) {
        Ok(ctx) => context_in(s, ctx),
        Err((_, why)) => tracing::warn!(session = s.id, method, "agent notification: {why}"),
    }
}

fn context_in(s: &Arc<Session>, ctx: Context) {
    let offer = {
        let mut st = lock(&s.panel.state);
        st.latest = Some(ctx);
        st.gate.offer(now())
    };
    match offer {
        Offer::Now => show(s),
        Offer::Arm(d) => {
            let me = s.clone();
            crate::clock::spawn("session:panel-context", async move {
                crate::clock::sleep(d).await;
                lock(&me.panel.state).gate.fired(now());
                show(&me);
            });
        }
        Offer::Wait => {}
    }
}

fn show(s: &Arc<Session>) {
    {
        let mut st = lock(&s.panel.state);
        st.shown = st.latest.clone();
    }
    s.changed();
}

/// An agent's extension request: `_drgnx/before_tool` runs the hooks (in a task of its own: they may take their
/// budget); anything else is refused.
pub(super) fn request(s: Arc<Session>, method: String, params: Value, resp: Responder<Value>) {
    crate::clock::spawn("session:panel-request", async move {
        let answer = match check_before_tool(&s.panel.features, &s.acp.0, &method, params) {
            Ok(tool) => Ok(before_tool(&s, tool).await),
            Err(r) => Err(r),
        };
        let _ = match answer {
            Ok(v) => resp.respond(v),
            Err((code, why)) => resp.fail(code, &why),
        };
    });
}

/// The `before-tool` hooks on the adapter's step TOOL: `{outcome: "allow"}` unless one refuses, then
/// `{outcome: "deny", reason}` in the hub's words. A change is not taken here, and with no matrix cell the hooks can
/// only refuse. A hub tool's step is hooked at its server, not here.
async fn before_tool(s: &Arc<Session>, tool: Value) -> Value {
    use crate::hook_points::{self as points, At};
    let allow = json!({"outcome": "allow"});
    let Some(front) = s.front() else {
        return allow;
    };
    let call = s.tool_call_info(Some(&tool));
    if call.kind == "other" && points::hub_tool_name(call.name.as_deref()) {
        return allow;
    }
    let site = s.hook_site(At::Adapter).await;
    let out = points::before_tool(&front, &site, &call, None).await;
    match points::refusal(call.step_name(), &out) {
        Some(reason) => json!({"outcome": "deny", "reason": reason}),
        None => allow,
    }
}

/// The user's action FEATURE on session S: METHOD with PARAMS (the session's id added) to the agent, its answer
/// within 10 s. An agent that does not offer FEATURE: invalid-params (an editor hides the action).
async fn forward(
    s: &Session,
    feature: &str,
    method: &str,
    mut params: Value,
) -> Result<Value, Error> {
    if !s.panel.offers(feature) {
        return Err(invalid("id", "this agent does not offer it"));
    }
    if let Some(o) = params.as_object_mut() {
        o.insert("sessionId".into(), json!(&*s.acp.0));
    }
    match s.conn.ext_request(method, params, ANSWER_WITHIN).await {
        Ok(v) => match within_size(&v) {
            Ok(()) => Ok(v),
            Err((_, why)) => Err(internal(format!("the agent's answer to {method}: {why}"))),
        },
        Err(hermod::Error::Deadline(_)) => Err(internal(format!(
            "the agent did not answer {method} within 10 s"
        ))),
        Err(hermod::Error::Rpc { message, .. }) => {
            Err(refuse(&format!("the agent refused {method}: «{message}»")))
        }
        Err(e) => Err(internal(format!("{method}: {e}"))),
    }
}

/// `agents/context-drop`.
pub async fn context_drop(f: &Front, _: &Caller, p: ContextDropParams) -> Result<bool, Error> {
    let s = f.core.agents.find(p.id.as_str())?;
    forward(&s, "drop", "_drgnx/context/drop", json!({"item": p.item.0})).await?;
    Ok(true)
}

/// `agents/context-pin`.
pub async fn context_pin(f: &Front, _: &Caller, p: ContextPinParams) -> Result<bool, Error> {
    let s = f.core.agents.find(p.id.as_str())?;
    forward(
        &s,
        "pin",
        "_drgnx/context/pin",
        json!({"item": p.item.0, "pinned": p.pinned}),
    )
    .await?;
    Ok(true)
}

/// `agents/compact-preview`: the agent's answer, checked against its schema.
pub async fn compact_preview(f: &Front, _: &Caller, p: ById) -> Result<CompactPreview, Error> {
    let s = f.core.agents.find(p.id.as_str())?;
    let v = forward(&s, "compact-preview", "_drgnx/compact/preview", json!({})).await?;
    serde_json::from_value(v).map_err(|e| {
        internal(format!(
            "the agent's compaction preview does not fit its schema: {e}"
        ))
    })
}

/// `agents/config`: a mode only inside the provider's lock ([`crate::agents::config::check`]), a model within the
/// profile; the agent is asked by `session/set_config_option`, with the older methods as the fallback.
pub async fn config(f: &Front, _: &Caller, p: ConfigParams) -> Result<bool, Error> {
    use crate::agents::config;
    let s = f.core.agents.find(p.id.as_str())?;
    config::check(s.locked_as, &p.option.0, &p.value.0).map_err(|why| refuse(&why))?;
    match config::apply(&s.conn, &s.acp, &p.option.0, &p.value.0).await {
        Ok(()) => Ok(true),
        Err(hermod::Error::Rpc { message, .. }) => Err(refuse(&format!(
            "the agent refused {} `{}`: «{message}»",
            p.option.0, p.value.0
        ))),
        Err(e) => Err(internal(format!("switching the {}: {e}", p.option.0))),
    }
}

/// `agents/explain`: the facts behind a chip, from the session's state and the adapter's last report.
pub async fn explain(f: &Front, _: &Caller, p: ExplainParams) -> Result<Explained, Error> {
    use crate::agents::explain::{Inputs, McpServerFacts, explain};
    let s = f.core.agents.find(p.id.as_str())?;
    let profile = super::find_profile(f, &s.profile);
    let snap = s.snapshot();
    let (up, failed) = f.mcp.served(p.id.as_str());
    let inputs = Inputs {
        role: serde_json::to_value(s.role)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default(),
        agent: s.profile.clone(),
        provider: s.locked_as,
        enforced: s.enforced,
        enforced_why: s.enforced_why.clone(),
        mode: s.conn.reported_mode(&s.acp),
        usage: snap.usage,
        context: snap.panel.and_then(|p| p.context),
        model: profile.as_ref().and_then(|p| p.model.clone()),
        ai: profile.and_then(|p| p.ai),
        status: serde_json::to_value(snap.status)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default(),
        waiting_on: snap.waiting_on.filter(|w| !w.is_empty()),
        pending: snap
            .permissions
            .iter()
            .filter_map(|x| x.title.clone())
            .collect(),
        turns: snap.turns.unwrap_or(0),
        tokens: lock(&s.state).tokens,
        mcp: s
            .capabilities
            .as_ref()
            .and_then(|c| c.get("mcpCapabilities").cloned()),
        mcp_servers: up
            .into_iter()
            .map(|(name, tools)| McpServerFacts { name, tools })
            .collect(),
        mcp_failed: failed,
    };
    Ok(Explained {
        item: p.item,
        facts: explain(p.item, &inputs),
    })
}

#[cfg(test)]
mod tests;
