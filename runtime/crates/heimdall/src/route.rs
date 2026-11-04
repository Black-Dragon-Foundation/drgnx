//! Routing one browser connection between two owners, the agent and the hub.
//!
//! A pipe is one CDP connection, so the agent's traffic and the hub's are kept apart by session, not by connection
//! (docs/develop/hub.md, "The CDP broker"):
//!
//! - The hub attaches to the browser target (`Target.attachToBrowserTarget`, flat mode) and gives the agent that
//!   session. Every agent message without a `sessionId` gets it; replies and events on it lose it again, so the agent
//!   sees what looks like a root connection.
//! - The hub's own commands go on the root session with ids from `HUB_ID_BASE` up. An agent id at or above it is
//!   refused, and a reply with such an id is the hub's whatever its session.
//! - A child session belongs to the owner of the session its `Target.attachedToTarget` arrived on.
//! - An agent command on a session it does not own, or naming one (or the browser target) in `Target.*` params, gets
//!   "not yours". `REFUSED_ALWAYS` gets "refused by drgnx".
//! - The agent's `Browser.setDownloadBehavior` is answered by the router, which sets its own (`allowAndName` into
//!   `DOWNLOAD_DIR`); the download events on the root session go to the agent, and a finished download is a
//!   `BrokerEvent::Download`.
//! - If the attach fails, the agent gets the root session as it is (`BrokerEvent::NoBrowserSession`).
//!
//! The router is created per browser start. Before the attach is answered it is not `ready`: the broker holds the
//! agent's messages until it is, and a message passed anyway gets an error reply.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::json;
use serde_json::value::RawValue;

use crate::envelope::{self, Envelope};

/// Refused from the agent in every mode with `-32601` "refused by drgnx". An entry ending in `.` is a prefix (a whole
/// domain). `Target.sendMessageToTarget` is here because its `message` is a whole CDP message for a non-flat session,
/// which would pass the broker unread.
pub const REFUSED_ALWAYS: &[&str] = &[
    "Target.exposeDevToolsProtocol",
    "Target.setRemoteLocations",
    "Target.sendMessageToTarget",
    "Tethering.",
    "Extensions.",
    "Browser.close",
    "Browser.crash",
    "Browser.crashGpuProcess",
];

/// The hub's first command id. Chromium reads a command's `id` as a 32-bit integer, so the hub's ids run from here
/// to `i32::MAX`, and an agent's must stay below.
pub const HUB_ID_BASE: u64 = 1 << 30;
const HUB_ID_LAST: u64 = i32::MAX as u64;

/// Where the browser saves downloads, named by their guid (the browser host's own dir; the agent can read it).
pub const DOWNLOAD_DIR: &str = "/tmp/drgnx-browser/downloads";

/// `method` is on `REFUSED_ALWAYS`.
pub fn is_refused(method: &str) -> bool {
    REFUSED_ALWAYS.iter().any(|r| {
        if r.ends_with('.') {
            method.starts_with(r)
        } else {
            method == *r
        }
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Owner {
    Agent,
    Hub,
}

/// What the broker reports, besides the messages.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BrokerEvent {
    /// A download finished: `path` is `DOWNLOAD_DIR/guid`.
    Download { guid: String, path: String },
    /// `Target.attachToBrowserTarget` failed: the agent has the root session, and the hub cannot watch (Mode B is
    /// unavailable for this browser).
    NoBrowserSession,
}

/// Where one message goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    ToBrowser(Vec<u8>),
    ToAgent(Vec<u8>),
    Both {
        browser: Vec<u8>,
        agent: Vec<u8>,
    },
    Drop,
    Event(BrokerEvent),
    /// A message for the agent that is also an event (a finished download).
    ToAgentAndEvent {
        agent: Vec<u8>,
        event: BrokerEvent,
    },
}

#[derive(Debug)]
struct Session {
    owner: Owner,
    /// The session its `attachedToTarget` arrived on; `None` is the root.
    parent: Option<String>,
    target: Option<String>,
    /// Attached with `waitingForDebugger` and not yet resumed by its owner.
    waiting: bool,
    /// Its owner has gone: its messages are dropped until Chromium reports it detached.
    closing: bool,
}

/// Where a message on a session goes.
enum Dest {
    /// To the agent; `strip` when the session is the agent's browser session.
    Agent {
        strip: bool,
    },
    Hub,
    /// An unknown or closing session.
    Nobody,
}

/// The router of one browser connection. See the module's documentation.
#[derive(Debug)]
pub struct Router {
    sessions: BTreeMap<String, Session>,
    /// The session the agent sees as its root.
    agent_session: Option<String>,
    /// The attach failed: the agent owns the root session.
    fallback: bool,
    ready: bool,
    /// The id of the hub's `attachToBrowserTarget` in flight.
    attach_id: Option<u64>,
    browser_target: Option<String>,
    next_id: u64,
}

#[derive(Serialize)]
struct Out<'a, P: Serialize> {
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    method: Option<&'a str>,
    #[serde(rename = "sessionId", skip_serializing_if = "Option::is_none")]
    session_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    params: Option<P>,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<&'a RawValue>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<&'a RawValue>,
}

fn bytes(v: &impl Serialize) -> Vec<u8> {
    // a struct of strings, numbers, RawValues and json! values: serializing cannot fail
    serde_json::to_vec(v).expect("a CDP message serializes")
}

fn command<P: Serialize>(
    id: u64,
    method: &str,
    session_id: Option<&str>,
    params: Option<P>,
) -> Vec<u8> {
    bytes(&Out {
        id: Some(id),
        method: Some(method),
        session_id,
        params,
        result: None,
        error: None,
    })
}

fn error_reply(id: u64, session_id: Option<&str>, code: i64, message: &str) -> Vec<u8> {
    let mut v = json!({"id": id, "error": {"code": code, "message": message}});
    if let Some(s) = session_id {
        v["sessionId"] = json!(s);
    }
    bytes(&v)
}

fn ok_reply(id: u64, session_id: Option<&str>) -> Vec<u8> {
    let mut v = json!({"id": id, "result": {}});
    if let Some(s) = session_id {
        v["sessionId"] = json!(s);
    }
    bytes(&v)
}

/// `env` as it was, less its `sessionId`.
fn without_session(env: &Envelope<'_>) -> Vec<u8> {
    bytes(&Out {
        id: env.id,
        method: env.method,
        session_id: None,
        params: env.params,
        result: env.result,
        error: env.error,
    })
}

/// A download guid names a file in `DOWNLOAD_DIR`: letters, digits and dashes only.
fn plain_guid(guid: &str) -> bool {
    !guid.is_empty()
        && guid.len() <= 64
        && guid.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

#[derive(Deserialize)]
struct AttachResult<'a> {
    #[serde(borrow, rename = "sessionId")]
    session_id: Option<&'a str>,
}

#[derive(Deserialize)]
struct Attached<'a> {
    #[serde(borrow, rename = "targetInfo")]
    target_info: Option<TargetInfo<'a>>,
    #[serde(rename = "waitingForDebugger")]
    waiting: Option<bool>,
}

#[derive(Deserialize)]
struct TargetInfo<'a> {
    #[serde(borrow, rename = "targetId")]
    target_id: Option<&'a str>,
    #[serde(borrow, rename = "type")]
    kind: Option<&'a str>,
}

#[derive(Deserialize)]
struct DownloadBehavior<'a> {
    #[serde(borrow, rename = "browserContextId")]
    context: Option<&'a str>,
}

#[derive(Deserialize)]
struct DownloadProgress<'a> {
    #[serde(borrow)]
    guid: Option<&'a str>,
    #[serde(borrow)]
    state: Option<&'a str>,
}

impl Router {
    /// A router for a browser that has just started, and the hub's first commands to it.
    pub fn new() -> (Router, Vec<Vec<u8>>) {
        let mut r = Router {
            sessions: BTreeMap::new(),
            agent_session: None,
            fallback: false,
            ready: false,
            attach_id: None,
            browser_target: None,
            next_id: HUB_ID_BASE,
        };
        let attach = r.attach();
        (r, vec![attach])
    }

    /// The agent's messages can be routed: the hub's attach has been answered (either way).
    pub fn ready(&self) -> bool {
        self.ready
    }

    fn hub_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id = if id >= HUB_ID_LAST {
            HUB_ID_BASE
        } else {
            id + 1
        };
        id
    }

    fn attach(&mut self) -> Vec<u8> {
        let id = self.hub_id();
        self.attach_id = Some(id);
        command::<()>(id, "Target.attachToBrowserTarget", None, None)
    }

    fn hub_command(
        &mut self,
        method: &str,
        session_id: Option<&str>,
        params: serde_json::Value,
    ) -> Vec<u8> {
        let id = self.hub_id();
        command(id, method, session_id, Some(params))
    }

    fn root_owner(&self) -> Owner {
        if self.fallback {
            Owner::Agent
        } else {
            Owner::Hub
        }
    }

    fn agent_owns(&self, session: &str) -> bool {
        self.sessions
            .get(session)
            .is_some_and(|s| s.owner == Owner::Agent && !s.closing)
    }

    fn dest(&self, session: Option<&str>) -> Dest {
        let owner = match session {
            None => self.root_owner(),
            Some(s) => match self.sessions.get(s) {
                Some(x) if !x.closing => x.owner,
                _ => return Dest::Nobody,
            },
        };
        match owner {
            Owner::Hub => Dest::Hub,
            Owner::Agent => Dest::Agent {
                strip: session.is_some() && session == self.agent_session.as_deref(),
            },
        }
    }

    /// One message from the agent's websocket.
    #[allow(clippy::wrong_self_convention)] // named for where the message comes from; not a conversion
    pub fn from_agent(&mut self, msg: &[u8]) -> Step {
        let Ok(env) = envelope::parse(msg, usize::MAX) else {
            return Step::Drop;
        };
        if env.is_reply {
            return Step::Drop;
        }
        let (Some(id), Some(method)) = (env.id, env.method) else {
            return Step::Drop;
        };
        let refuse =
            |code: i64, text: &str| Step::ToAgent(error_reply(id, env.session_id, code, text));
        if id >= HUB_ID_BASE {
            return refuse(-32600, "the id is out of range");
        }
        if !self.ready {
            return refuse(-32000, "the browser is starting");
        }
        if is_refused(method) {
            return refuse(-32601, "refused by drgnx");
        }
        let session: Option<String> = match env.session_id {
            Some(s) if self.agent_owns(s) => Some(s.to_owned()),
            Some(_) => return refuse(-32000, "not yours"),
            None if self.fallback => None,
            None => match &self.agent_session {
                Some(s) => Some(s.clone()),
                None => return refuse(-32000, "the agent's browser session is gone"),
            },
        };
        if method.starts_with("Target.") {
            let names_hub_session = env.target_session_id.is_some_and(|s| !self.agent_owns(s));
            let names_browser =
                env.target_id.is_some() && env.target_id == self.browser_target.as_deref();
            if names_hub_session || names_browser {
                return refuse(-32000, "not yours");
            }
        }
        if method == "Browser.setDownloadBehavior" {
            let context = match env.params.map(envelope::object::<DownloadBehavior<'_>>) {
                None => None,
                Some(Ok(p)) => p.context,
                Some(Err(_)) => return refuse(-32602, "invalid params"),
            };
            let mut params = json!({"behavior": "allowAndName", "downloadPath": DOWNLOAD_DIR, "eventsEnabled": true});
            if let Some(c) = context {
                params["browserContextId"] = json!(c);
            }
            let browser = self.hub_command("Browser.setDownloadBehavior", None, params);
            return Step::Both {
                browser,
                agent: ok_reply(id, env.session_id),
            };
        }
        if method == "Runtime.runIfWaitingForDebugger"
            && let Some(s) = session.as_deref().and_then(|s| self.sessions.get_mut(s))
        {
            s.waiting = false;
        }
        Step::ToBrowser(command(id, method, session.as_deref(), env.params))
    }

    /// One message from the browser.
    #[allow(clippy::wrong_self_convention)] // named for where the message comes from; not a conversion
    pub fn from_browser(&mut self, msg: &[u8]) -> Step {
        let Ok(env) = envelope::parse(msg, usize::MAX) else {
            return Step::Drop;
        };
        if env.is_reply {
            if let Some(id) = env.id
                && id >= HUB_ID_BASE
            {
                return self.hub_reply(id, &env);
            }
            return self.route(&env, msg);
        }
        match env.method {
            Some("Target.attachedToTarget") => self.attached(&env, msg),
            Some("Target.detachedFromTarget") => {
                let step = self.route(&env, msg);
                if let Some(s) = env.target_session_id {
                    self.remove(s);
                }
                step
            }
            Some("Browser.downloadWillBegin" | "Browser.downloadProgress")
                if env.session_id.is_none() =>
            {
                self.download(&env, msg)
            }
            Some(_) => self.route(&env, msg),
            None => Step::Drop,
        }
    }

    /// The agent's websocket closed: resume what the agent left paused, detach every session it owns (children
    /// first), and get a fresh browser session for the next agent.
    pub fn agent_closed(&mut self) -> Vec<Vec<u8>> {
        let mine: Vec<String> = self
            .sessions
            .iter()
            .filter(|(_, s)| s.owner == Owner::Agent && !s.closing)
            .map(|(id, _)| id.clone())
            .collect();
        let mut out = Vec::new();
        for id in &mine {
            let s = &self.sessions[id];
            let hub_holds = s.target.is_some()
                && self
                    .sessions
                    .values()
                    .any(|o| o.owner == Owner::Hub && !o.closing && o.target == s.target);
            if s.waiting && !hub_holds {
                let cmd = self.hub_command(
                    "Runtime.runIfWaitingForDebugger",
                    Some(id.as_str()),
                    json!({}),
                );
                out.push(cmd);
            }
        }
        let mut by_depth: Vec<(usize, String)> =
            mine.iter().map(|id| (self.depth(id), id.clone())).collect();
        by_depth.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        for (_, id) in &by_depth {
            let parent = self.sessions[id].parent.clone();
            let cmd = self.hub_command(
                "Target.detachFromTarget",
                parent.as_deref(),
                json!({"sessionId": id}),
            );
            out.push(cmd);
        }
        for id in &mine {
            if let Some(s) = self.sessions.get_mut(id) {
                s.closing = true;
            }
        }
        if self.fallback {
            // the agent's protocol state on the root stays with the connection: turn off what would pause new targets
            let off =
                json!({"autoAttach": false, "waitForDebuggerOnStart": false, "flatten": true});
            out.push(self.hub_command("Target.setAutoAttach", None, off));
            out.push(self.hub_command(
                "Target.setDiscoverTargets",
                None,
                json!({"discover": false}),
            ));
        } else {
            self.agent_session = None;
            if self.attach_id.is_none() {
                self.ready = false;
                out.push(self.attach());
            }
        }
        out
    }

    /// How many parents up to the root.
    fn depth(&self, id: &str) -> usize {
        let mut depth = 0;
        let mut at = self.sessions.get(id).and_then(|s| s.parent.as_deref());
        while let Some(p) = at {
            depth += 1;
            if depth > self.sessions.len() {
                break;
            }
            at = self.sessions.get(p).and_then(|s| s.parent.as_deref());
        }
        depth
    }

    fn route(&self, env: &Envelope<'_>, msg: &[u8]) -> Step {
        match self.dest(env.session_id) {
            Dest::Agent { strip: true } => Step::ToAgent(without_session(env)),
            Dest::Agent { strip: false } => Step::ToAgent(msg.to_vec()),
            Dest::Hub | Dest::Nobody => Step::Drop,
        }
    }

    fn hub_reply(&mut self, id: u64, env: &Envelope<'_>) -> Step {
        if self.attach_id != Some(id) {
            return Step::Drop;
        }
        self.attach_id = None;
        self.ready = true;
        let session = env
            .result
            .and_then(|r| envelope::object::<AttachResult<'_>>(r).ok())
            .and_then(|r| r.session_id);
        match session {
            Some(s) if env.error.is_none() => {
                let target = self.browser_target.clone();
                let entry = self.sessions.entry(s.to_owned()).or_insert(Session {
                    owner: Owner::Agent,
                    parent: None,
                    target,
                    waiting: false,
                    closing: false,
                });
                // the hub's own attach: its attachedToTarget (on the root) made it the hub's
                entry.owner = Owner::Agent;
                self.agent_session = Some(s.to_owned());
                Step::Drop
            }
            _ => {
                self.fallback = true;
                self.agent_session = None;
                Step::Event(BrokerEvent::NoBrowserSession)
            }
        }
    }

    fn attached(&mut self, env: &Envelope<'_>, msg: &[u8]) -> Step {
        let (Some(child), Some(params)) = (env.target_session_id, env.params) else {
            return Step::Drop;
        };
        let Ok(info) = envelope::object::<Attached<'_>>(params) else {
            return Step::Drop;
        };
        let (owner, closing) = match env.session_id {
            None => (self.root_owner(), false),
            Some(p) => match self.sessions.get(p) {
                Some(s) => (s.owner, s.closing),
                None => return Step::Drop,
            },
        };
        let target = info.target_info.as_ref().and_then(|t| t.target_id);
        if info.target_info.as_ref().and_then(|t| t.kind) == Some("browser")
            && self.browser_target.is_none()
        {
            self.browser_target = target.map(str::to_owned);
        }
        self.sessions.entry(child.to_owned()).or_insert(Session {
            owner,
            parent: env.session_id.map(str::to_owned),
            target: target.map(str::to_owned),
            waiting: info.waiting.unwrap_or(false),
            closing,
        });
        self.route(env, msg)
    }

    /// `id` and every session below it are gone.
    fn remove(&mut self, id: &str) {
        let mut gone = vec![id.to_owned()];
        let mut i = 0;
        while i < gone.len() {
            let children: Vec<String> = self
                .sessions
                .iter()
                .filter(|(k, s)| s.parent.as_deref() == Some(gone[i].as_str()) && !gone.contains(k))
                .map(|(k, _)| k.clone())
                .collect();
            gone.extend(children);
            i += 1;
        }
        for g in &gone {
            self.sessions.remove(g);
            if self.agent_session.as_deref() == Some(g.as_str()) {
                self.agent_session = None;
            }
        }
    }

    /// A download event on the root session, where the hub's own `setDownloadBehavior` sends them: the agent asked
    /// for them, so it gets them, and a finished download is reported.
    fn download(&self, env: &Envelope<'_>, msg: &[u8]) -> Step {
        let agent = msg.to_vec();
        if env.method == Some("Browser.downloadProgress")
            && let Some(Ok(p)) = env.params.map(envelope::object::<DownloadProgress<'_>>)
            && p.state == Some("completed")
            && let Some(guid) = p.guid.filter(|g| plain_guid(g))
        {
            let event = BrokerEvent::Download {
                guid: guid.to_owned(),
                path: format!("{DOWNLOAD_DIR}/{guid}"),
            };
            return Step::ToAgentAndEvent { agent, event };
        }
        Step::ToAgent(agent)
    }
}

#[cfg(test)]
mod tests;
