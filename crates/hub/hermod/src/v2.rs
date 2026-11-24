//! ACP v2 on the wire, turned into the events the hub already consumes (and four it never had).  Translation only:
//! no I/O.  The updates are read as JSON, not as the schema crate's v2 types, so a draft revision that adds a field
//! costs nothing here, and each v1 result is decoded by the v1 types the hub already uses.
//!
//! The rules (`docs/develop/runtime.md`, "hermod"):
//! - a turn ends at the first `state_update idle` after a prompt the agent has acknowledged (the prompt's own response
//!   only says the user message was inserted); a repeated `idle` (the background list changed) ends nothing;
//! - whole-message upserts are [`Event::Replace`]; the first `tool_call_update` of an id is a v1 `tool_call`;
//! - `background` omitted or `null` is "not reported" (`None`), `[]` is "nothing running", an item of a type this
//!   code does not know is [`BackgroundRef::Other`] and still counts.

use crate::schema::v1 as acp;
use crate::types::{
    BackgroundRef, Error, Event, MessageKind, PromptOutcome, RunState, SessionId, StopReason,
    TerminalEv, Usage,
};
use runstav::jsonrpc::Id;
use serde_json::{Map, Value, json};
use std::collections::{HashMap, HashSet, VecDeque};
use tokio::sync::oneshot;

type Outcome = Result<PromptOutcome, Error>;

/// A prompt waiting for its turn's end.
struct Waiter {
    token: u64,
    /// The request id of its `session/prompt`.
    id: Id,
    /// The agent has answered the prompt: the user message is inserted.
    acked: bool,
    /// The agent has reported work (`running`, `requires_action`) since the prompt was sent: an end that comes before
    /// the answer is this prompt's, not that of work the agent was already doing when it was held.
    started: bool,
    /// The turn ended before the answer came (the two may arrive in either order).
    early: Option<Outcome>,
    tx: oneshot::Sender<Outcome>,
}

/// Per-connection state of the v2 translation.
#[derive(Default)]
pub(crate) struct V2 {
    /// The foreground state each session last reported (none yet: idle, as a new session is).
    last: HashMap<String, RunState>,
    /// Tool calls seen, by session: the first update of an id creates the v1 call.
    tools: HashMap<String, HashSet<String>>,
    /// The content a tool call has accumulated (an update replaces it, a chunk appends), until it ends.
    content: HashMap<(String, String), Vec<Value>>,
    waiters: HashMap<String, VecDeque<Waiter>>,
    next: u64,
}

/// What one update turns into: events to send first, then the end of a turn when it ends one.
pub(crate) struct Out {
    pub events: Vec<Event>,
    pub ended: Option<Outcome>,
}

impl V2 {
    /// A prompt for SID is on its way: its token, and the receiver that gets its turn's end.
    pub(crate) fn register(&mut self, sid: &str, id: Id) -> (u64, oneshot::Receiver<Outcome>) {
        self.next += 1;
        let (tx, rx) = oneshot::channel();
        self.waiters
            .entry(sid.to_string())
            .or_default()
            .push_back(Waiter {
                token: self.next,
                id,
                acked: false,
                started: false,
                early: None,
                tx,
            });
        (self.next, rx)
    }

    /// The agent answered the request ID: when it is a prompt, INSERTED says the user message went in (the prompt is
    /// acknowledged: its turn can end now, or already has) or not (an error: it never will).  Read by the reader,
    /// as the answer arrives, whether or not anyone polls the prompt's future.
    pub(crate) fn answered(&mut self, id: &Id, inserted: bool) {
        for q in self.waiters.values_mut() {
            let Some(i) = q.iter().position(|w| &w.id == id) else {
                continue;
            };
            if !inserted {
                q.remove(i);
            } else if let Some(early) = q[i].early.take() {
                // the turn ended before its answer came
                if let Some(w) = q.remove(i) {
                    saman::delivered(w.tx.send(early), "w.tx receiver");
                }
            } else {
                q[i].acked = true;
            }
            return;
        }
    }

    /// The prompt TOKEN is no longer waited for (answered with an error, cancelled, or dropped).
    pub(crate) fn forget(&mut self, sid: &str, token: u64) {
        if let Some(q) = self.waiters.get_mut(sid) {
            q.retain(|w| w.token != token);
        }
    }

    /// The child is gone: every waiting prompt's receiver sees the channel close.
    pub(crate) fn close_all(&mut self) {
        self.waiters.clear();
    }

    /// A turn of SID ended with RESULT: every acknowledged prompt ends with it (the first carries the usage, so it is
    /// counted once); a prompt not yet acknowledged whose work has begun keeps the outcome for its answer.
    pub(crate) fn finish(&mut self, sid: &str, result: &Outcome) {
        let Some(q) = self.waiters.get_mut(sid) else {
            return;
        };
        let mut first = true;
        let mut keep = VecDeque::new();
        for mut w in std::mem::take(q) {
            if w.acked {
                saman::delivered(w.tx.send(copy(result, first)), "w.tx receiver");
                first = false;
            } else {
                if w.started && w.early.is_none() {
                    w.early = Some(copy(result, first));
                    first = false;
                }
                keep.push_back(w);
            }
        }
        *q = keep;
    }

    /// A v2 `session/request_permission` as the v1 params the hub decodes (`toolCall` from the `subject`, the request's
    /// `title` where the subject has none), and the events that come first: the subject's tool call applied like a
    /// `tool_call_update`, before the prompt is shown.  REQUEST is the request's id (it names a call that has none).
    pub(crate) fn permission(
        &mut self,
        at: f64,
        sid: &SessionId,
        request: &Id,
        params: &Value,
    ) -> (Value, Vec<Event>) {
        let title = params.get("title").and_then(Value::as_str).unwrap_or("");
        let subject = params.get("subject");
        let named = match request {
            Id::Num(n) => n.to_string(),
            Id::Str(s) => s.clone(),
        };
        let mut call = Map::new();
        call.insert("toolCallId".into(), json!(format!("permission-{named}")));
        call.insert("title".into(), json!(title));
        match subject.and_then(|s| s.get("type")).and_then(Value::as_str) {
            Some("tool_call") => {
                if let Some(t) = subject
                    .and_then(|s| s.get("toolCall"))
                    .and_then(Value::as_object)
                    .filter(|t| t.contains_key("toolCallId"))
                {
                    call = t.clone();
                    if !call.get("title").is_some_and(Value::is_string) {
                        call.insert("title".into(), json!(title));
                    }
                }
            }
            Some("command") => {
                let s = subject.expect("a subject");
                if let Some(id) = s.get("toolCallId").and_then(Value::as_str) {
                    call.insert("toolCallId".into(), json!(id));
                }
                call.insert("kind".into(), json!("execute"));
                call.insert(
                    "rawInput".into(),
                    json!({"command": s.get("command"), "cwd": s.get("cwd")}),
                );
            }
            _ => {}
        }
        let mut update = call.clone();
        update.insert("sessionUpdate".into(), json!("tool_call_update"));
        let events = self.translate(at, sid, Value::Object(update)).events;
        let mut v1 = Map::new();
        for k in [
            "toolCallId",
            "title",
            "kind",
            "rawInput",
            "rawOutput",
            "locations",
        ] {
            if let Some(v) = call.get(k).filter(|v| !v.is_null()) {
                v1.insert(k.into(), v.clone());
            }
        }
        if let Some(st) = call.get("status").and_then(Value::as_str) {
            let st = match st {
                "paused" => "in_progress",
                "cancelled" => "failed",
                other => other,
            };
            v1.insert("status".into(), json!(st));
        }
        if let Some(a) = call.get("content").and_then(Value::as_array) {
            let c: Vec<Value> = a.iter().cloned().flat_map(v1_content).collect();
            v1.insert("content".into(), Value::Array(c));
        }
        let mut p = Map::new();
        p.insert(
            "sessionId".into(),
            params.get("sessionId").cloned().unwrap_or(Value::Null),
        );
        p.insert("toolCall".into(), Value::Object(v1));
        p.insert(
            "options".into(),
            params.get("options").cloned().unwrap_or(json!([])),
        );
        if let Some(m) = params.get("_meta") {
            p.insert("_meta".into(), m.clone());
        }
        (Value::Object(p), events)
    }

    /// Translates one `session/update` of SID, UPDATE its `update` object, stamped AT.
    pub(crate) fn translate(&mut self, at: f64, sid: &SessionId, update: Value) -> Out {
        let mut out = Out {
            events: Vec::new(),
            ended: None,
        };
        let Some(u) = update.as_object() else {
            return out;
        };
        let kind = u.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        let key = sid.0.to_string();
        match kind {
            "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk" => {
                out.events.extend(plain(at, sid, update.clone()));
            }
            "user_message" | "agent_message" | "agent_thought" => {
                let (Some(id), Some(content)) =
                    (u.get("messageId").and_then(Value::as_str), u.get("content"))
                else {
                    return out;
                };
                let kind = match kind {
                    "user_message" => MessageKind::User,
                    "agent_message" => MessageKind::Agent,
                    _ => MessageKind::Thought,
                };
                out.events.push(Event::Replace {
                    at,
                    sid: sid.clone(),
                    message_id: id.to_string(),
                    kind,
                    content: content.clone(),
                });
            }
            "tool_call_update" | "tool_call_content_chunk" => {
                if let Some(v) = self.tool_call(&key, u, kind == "tool_call_content_chunk") {
                    out.events.extend(plain(at, sid, v));
                }
            }
            "plan_update" => {
                let plan = u.get("plan");
                if plan.and_then(|p| p.get("type")).and_then(Value::as_str) == Some("items") {
                    let entries: Vec<Value> = plan
                        .and_then(|p| p.get("entries"))
                        .and_then(Value::as_array)
                        .map(|a| a.iter().map(plan_entry).collect())
                        .unwrap_or_default();
                    out.events.extend(plain(
                        at,
                        sid,
                        json!({"sessionUpdate": "plan", "entries": entries}),
                    ));
                }
            }
            "plan_removed" => {
                out.events.extend(plain(
                    at,
                    sid,
                    json!({"sessionUpdate": "plan", "entries": []}),
                ));
            }
            "usage_update" | "available_commands_update" | "notice" | "session_info_update" => {
                out.events.extend(plain(at, sid, without_nulls(&update)));
            }
            "config_option_update" => {
                let mut v = without_nulls(&update);
                if let Some(a) = v.get_mut("configOptions") {
                    rename_options(a);
                }
                out.events.extend(plain(at, sid, v));
            }
            "state_update" => self.state(at, sid, u, &mut out),
            "terminal_update" => {
                if let Some(id) = u.get("terminalId").and_then(Value::as_str) {
                    let snapshot = u
                        .get("output")
                        .and_then(|o| o.get("data"))
                        .and_then(Value::as_str)
                        .and_then(b64);
                    let exit = u.get("exitStatus").filter(|e| e.is_object()).map(|e| {
                        (
                            e.get("exitCode")
                                .and_then(Value::as_i64)
                                .and_then(|c| i32::try_from(c).ok()),
                            e.get("signal").and_then(Value::as_str).map(String::from),
                        )
                    });
                    out.events.push(Event::Terminal {
                        at,
                        sid: sid.clone(),
                        id: id.to_string(),
                        update: TerminalEv::Update {
                            command: str_of(u, "command"),
                            cwd: str_of(u, "cwd"),
                            snapshot,
                            exit,
                            can_cancel: can_cancel(u),
                        },
                    });
                }
            }
            "terminal_output_chunk" => {
                if let (Some(id), Some(bytes)) = (
                    u.get("terminalId").and_then(Value::as_str),
                    u.get("data").and_then(Value::as_str).and_then(b64),
                ) {
                    out.events.push(Event::Terminal {
                        at,
                        sid: sid.clone(),
                        id: id.to_string(),
                        update: TerminalEv::Chunk(bytes),
                    });
                }
            }
            "subagent_update" => {
                if let Some(child) = u.get("sessionId").and_then(Value::as_str) {
                    out.events.push(Event::Subagent {
                        at,
                        sid: sid.clone(),
                        child: SessionId::new(child.to_string()),
                        update: update.clone(),
                    });
                }
            }
            // session messages, compaction, replay_complete, anything newer: nothing the hub reads
            _ => tracing::debug!("hermod: a v2 update the hub does not read: {kind}"),
        }
        out
    }

    fn state(&mut self, at: f64, sid: &SessionId, u: &Map<String, Value>, out: &mut Out) {
        let key = sid.0.to_string();
        let stop = u
            .get("stopReason")
            .and_then(Value::as_str)
            .and_then(|s| serde_json::from_value::<StopReason>(Value::String(s.into())).ok());
        let state = match u.get("state").and_then(Value::as_str) {
            Some("running") => RunState::Running,
            Some("requires_action") => RunState::RequiresAction,
            Some("idle") => RunState::Idle(stop),
            _ => RunState::Unknown,
        };
        let background = match u.get("background") {
            Some(Value::Array(a)) => Some(a.iter().map(background_ref).collect()),
            _ => None,
        };
        let was = self
            .last
            .insert(key.clone(), state.clone())
            .unwrap_or(RunState::Idle(None));
        out.events.push(Event::State {
            at,
            sid: sid.clone(),
            state: state.clone(),
            background,
        });
        match state {
            RunState::Running | RunState::RequiresAction => {
                for w in self.waiters.entry(key).or_default() {
                    w.started = true;
                }
            }
            // only a transition into idle ends a turn: a repeated idle is a changed background list
            RunState::Idle(_) if !matches!(was, RunState::Idle(_)) => {
                out.ended = Some(
                    if u.get("stopReason").and_then(Value::as_str) == Some("error") {
                        let e = u.get("error");
                        Err(Error::Rpc {
                            code: e
                                .and_then(|e| e.get("code"))
                                .and_then(Value::as_i64)
                                .unwrap_or(-32603),
                            message: e
                                .and_then(|e| e.get("message"))
                                .and_then(Value::as_str)
                                .unwrap_or("the agent's turn failed")
                                .to_string(),
                            data: e.and_then(|e| e.get("data")).cloned(),
                        })
                    } else {
                        Ok(PromptOutcome {
                            // an agent that does not say why work stopped still ended it
                            stop: stop.unwrap_or(StopReason::EndTurn),
                            usage: u
                                .get("usage")
                                .and_then(|v| serde_json::from_value::<Usage>(v.clone()).ok()),
                            turn_id: u
                                .get("_meta")
                                .and_then(|m| m.get("turnId"))
                                .and_then(Value::as_str)
                                .map(str::to_string),
                        })
                    },
                );
            }
            _ => {}
        }
    }

    /// The v1 `tool_call` or `tool_call_update` for a v2 tool call update (or a content chunk, CHUNK).
    fn tool_call(&mut self, sid: &str, u: &Map<String, Value>, chunk: bool) -> Option<Value> {
        let id = u.get("toolCallId").and_then(Value::as_str)?;
        let first = self
            .tools
            .entry(sid.to_string())
            .or_default()
            .insert(id.to_string());
        let mut o = Map::new();
        o.insert(
            "sessionUpdate".into(),
            json!(if first {
                "tool_call"
            } else {
                "tool_call_update"
            }),
        );
        o.insert("toolCallId".into(), json!(id));
        let title = str_of(u, "title")
            .or_else(|| first.then(|| str_of(u, "name")).flatten())
            .or_else(|| first.then(String::new));
        if let Some(t) = title {
            o.insert("title".into(), json!(t));
        }
        for k in ["kind", "rawInput", "rawOutput", "locations"] {
            if let Some(v) = u.get(k).filter(|v| !v.is_null()) {
                o.insert(k.into(), v.clone());
            }
        }
        let mut meta = u
            .get("_meta")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        let raw_status = str_of(u, "status");
        if let Some(s) = &raw_status {
            // v1 knows four statuses: a paused call is running, a cancelled one failed; the real one rides in _meta
            let v1 = match s.as_str() {
                "paused" => "in_progress",
                "cancelled" => "failed",
                other => other,
            };
            o.insert("status".into(), json!(v1));
            meta.insert("_hermod/status".into(), json!(s));
        }
        if let Some(c) = can_cancel(u) {
            meta.insert("_hermod/can_cancel".into(), json!(c));
        }
        if !meta.is_empty() {
            o.insert("_meta".into(), Value::Object(meta));
        }
        let ck = (sid.to_string(), id.to_string());
        let items = if chunk {
            let acc = self.content.entry(ck.clone()).or_default();
            acc.extend(u.get("content").cloned().into_iter().flat_map(v1_content));
            Some(acc.clone())
        } else if let Some(a) = u.get("content").and_then(Value::as_array) {
            let v: Vec<Value> = a.iter().cloned().flat_map(v1_content).collect();
            self.content.insert(ck.clone(), v.clone());
            Some(v)
        } else {
            None
        };
        if let Some(items) = items {
            o.insert("content".into(), Value::Array(items));
        }
        if matches!(
            raw_status.as_deref(),
            Some("completed" | "failed" | "cancelled")
        ) {
            self.content.remove(&ck);
        }
        Some(Value::Object(o))
    }
}

fn copy(r: &Outcome, with_usage: bool) -> Outcome {
    match r {
        Ok(o) => Ok(PromptOutcome {
            stop: o.stop,
            usage: if with_usage { o.usage.clone() } else { None },
            turn_id: o.turn_id.clone(),
        }),
        Err(Error::Rpc {
            code,
            message,
            data,
        }) => Err(Error::Rpc {
            code: *code,
            message: message.clone(),
            data: data.clone(),
        }),
        Err(_) => Err(Error::Closed),
    }
}

/// A v1 `Event::Update` from a value shaped as a v1 update; one the v1 types refuse is dropped, said at warn.
fn plain(at: f64, sid: &SessionId, v: Value) -> Option<Event> {
    match serde_json::from_value::<acp::SessionUpdate>(v) {
        Ok(update) => {
            let message_id = match &update {
                acp::SessionUpdate::UserMessageChunk(c)
                | acp::SessionUpdate::AgentMessageChunk(c)
                | acp::SessionUpdate::AgentThoughtChunk(c) => {
                    c.message_id.as_ref().map(|m| m.0.to_string())
                }
                _ => None,
            };
            Some(Event::Update {
                at,
                sid: sid.clone(),
                update,
                message_id,
            })
        }
        Err(e) => {
            tracing::warn!("hermod: a v2 update that does not fit the hub's types: {e}");
            None
        }
    }
}

fn str_of(u: &Map<String, Value>, k: &str) -> Option<String> {
    u.get(k).and_then(Value::as_str).map(String::from)
}

/// `capabilities.cancel`: none when the update says nothing of capabilities, else whether it advertises cancel.
fn can_cancel(u: &Map<String, Value>) -> Option<bool> {
    let c = u.get("capabilities")?;
    Some(c.get("cancel").is_some_and(|v| !v.is_null()))
}

fn background_ref(v: &Value) -> BackgroundRef {
    let id = |k: &str| v.get(k).and_then(Value::as_str).map(String::from);
    match v.get("type").and_then(Value::as_str) {
        Some("terminal") => id("terminalId").map(BackgroundRef::Terminal),
        Some("tool_call") => id("toolCallId").map(BackgroundRef::ToolCall),
        Some("subagent") => id("sessionId").map(|s| BackgroundRef::Subagent(SessionId::new(s))),
        _ => None,
    }
    .unwrap_or_else(|| BackgroundRef::Other(v.clone()))
}

/// A v2 tool call content item as v1 has it, as a list: `content` and `terminal` items as they are, a diff that already
/// has v1's shape (`oldText`/`newText`) as it is, a v2 diff (structured `changes` plus git patch text) as v1 diff items
/// ([`diff_items`]); a session item has no v1 shape the hub reads.
fn v1_content(v: Value) -> Vec<Value> {
    match v.get("type").and_then(Value::as_str) {
        Some("content" | "terminal") => vec![v],
        Some("diff") if v.get("newText").is_some() => vec![v],
        Some("diff") => diff_items(&v),
        _ => Vec::new(),
    }
}

/// A v2 diff as the items the hub reads (`path`, `oldText`, `newText`): one per hunk of the patch for each file of
/// `changes` that the patch covers, the hunk's context kept, so a fragment is found once in the file as a Codex hunk is;
/// a file with no usable patch (none, a format this code does not know, a move or a copy) is named with no text.
fn diff_items(d: &Value) -> Vec<Value> {
    let patch = d
        .get("patch")
        .filter(|p| p.get("format").and_then(Value::as_str) == Some("git_patch"))
        .and_then(|p| p.get("text"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let sections = patch_sections(patch);
    let mut out = Vec::new();
    for c in d
        .get("changes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(path) = c.get("path").and_then(Value::as_str) else {
            continue;
        };
        let text_op = matches!(
            c.get("operation").and_then(Value::as_str),
            Some("add" | "delete" | "modify")
        );
        let hunks: Vec<&(String, String)> = sections
            .iter()
            .filter(|(p, _)| text_op && same_path(p, path))
            .flat_map(|(_, h)| h.iter())
            .collect();
        if hunks.is_empty() {
            out.push(json!({"type": "diff", "path": path, "oldText": null, "newText": ""}));
        }
        for (old, new) in hunks {
            let old = if old.is_empty() {
                Value::Null
            } else {
                json!(old)
            };
            out.push(json!({"type": "diff", "path": path, "oldText": old, "newText": new}));
        }
    }
    out
}

/// Whether a patch's path P names the change's path CHANGE (a client may strip Git's `a/` and `b/`).
fn same_path(p: &str, change: &str) -> bool {
    p == change
        || p.strip_prefix("a/") == Some(change.trim_start_matches('/'))
        || p.strip_prefix("b/") == Some(change.trim_start_matches('/'))
}

/// A git patch as (file path, hunks): each hunk the old text and the new text of its lines, context in both.
fn patch_sections(text: &str) -> Vec<(String, Vec<(String, String)>)> {
    let mut out: Vec<(String, Vec<(String, String)>)> = Vec::new();
    let mut old_path: Option<String> = None;
    // the lines the open hunk still has to read: old, new
    let mut left = (0usize, 0usize);
    for line in text.lines() {
        if left != (0, 0) {
            let Some(hunk) = out.last_mut().and_then(|s| s.1.last_mut()) else {
                break;
            };
            let (body, nl) = (line.get(1..).unwrap_or(""), "\n");
            match line.as_bytes().first() {
                Some(b' ') => {
                    hunk.0.push_str(body);
                    hunk.0.push_str(nl);
                    hunk.1.push_str(body);
                    hunk.1.push_str(nl);
                    left = (left.0.saturating_sub(1), left.1.saturating_sub(1));
                }
                Some(b'-') => {
                    hunk.0.push_str(body);
                    hunk.0.push_str(nl);
                    left.0 = left.0.saturating_sub(1);
                }
                Some(b'+') => {
                    hunk.1.push_str(body);
                    hunk.1.push_str(nl);
                    left.1 = left.1.saturating_sub(1);
                }
                _ => {}
            }
            continue;
        }
        if line.starts_with("diff --git ") {
            old_path = None;
        } else if let Some(p) = line.strip_prefix("--- ") {
            old_path = Some(patch_path(p));
        } else if let Some(p) = line.strip_prefix("+++ ") {
            let new = patch_path(p);
            let path = if new == "/dev/null" {
                old_path.take().unwrap_or(new)
            } else {
                new
            };
            out.push((path, Vec::new()));
        } else if let Some(h) = line.strip_prefix("@@ ") {
            let count = |sign: char| {
                h.split_whitespace()
                    .find(|w| w.starts_with(sign))
                    .map(|w| {
                        w[1..]
                            .split_once(',')
                            .map_or(1, |(_, n)| n.parse().unwrap_or(1))
                    })
                    .unwrap_or(1)
            };
            left = (count('-'), count('+'));
            if let Some(s) = out.last_mut() {
                s.1.push((String::new(), String::new()));
            }
        }
    }
    out
}

/// A path of a `---` or `+++` line: before a tab, unquoted when Git quoted it.
fn patch_path(p: &str) -> String {
    let p = p.split('\t').next().unwrap_or(p);
    p.strip_prefix('"')
        .and_then(|q| q.strip_suffix('"'))
        .unwrap_or(p)
        .to_string()
}

fn plan_entry(e: &Value) -> Value {
    let mut e = e.clone();
    if let Some(o) = e.as_object_mut() {
        let ok = |k: &str, set: &[&str], o: &Map<String, Value>| {
            o.get(k)
                .and_then(Value::as_str)
                .is_some_and(|s| set.contains(&s))
        };
        if !ok("status", &["pending", "in_progress", "completed"], o) {
            o.insert("status".into(), json!("pending"));
        }
        if !ok("priority", &["high", "medium", "low"], o) {
            o.insert("priority".into(), json!("medium"));
        }
    }
    e
}

fn without_nulls(v: &Value) -> Value {
    match v {
        Value::Object(o) => Value::Object(
            o.iter()
                .filter(|(_, v)| !v.is_null())
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect(),
        ),
        other => other.clone(),
    }
}

/// v2's config options name their id `configId` (v1: `id`) and a group `groupId` (v1: `group`).
pub(crate) fn rename_options(v: &mut Value) {
    match v {
        Value::Array(a) => a.iter_mut().for_each(rename_options),
        Value::Object(o) => {
            for (from, to) in [("configId", "id"), ("groupId", "group")] {
                if let Some(x) = o.remove(from) {
                    o.insert(to.into(), x);
                }
            }
            o.values_mut().for_each(rename_options);
        }
        _ => {}
    }
}

/// RFC 4648 base64 (padded or not), or none when it is not.
pub(crate) fn b64(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for c in s.bytes().take_while(|&c| c != b'=') {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

/// The v1-shaped `agentCapabilities` of a v2 answer's `capabilities`, which is what the hub reads (a v2 agent resumes
/// and loads through `session/resume`).
pub(crate) fn v1_caps(caps: &Value) -> Value {
    let has = |p: &str| caps.pointer(p).is_some_and(|v| !v.is_null());
    let mut o = json!({
        "loadSession": true,
        "promptCapabilities": {
            "image": has("/session/prompt/image"),
            "audio": has("/session/prompt/audio"),
            "embeddedContext": has("/session/prompt/embeddedContext"),
        },
        "mcpCapabilities": {"http": has("/session/mcp/http"), "sse": false},
        "sessionCapabilities": {"list": {}, "resume": {}, "close": {}},
    });
    if has("/session/fork") {
        o["sessionCapabilities"]["fork"] = json!({});
    }
    if let Some(m) = caps.get("_meta").filter(|m| !m.is_null()) {
        o["_meta"] = m.clone();
    }
    o
}

/// The v1 shape of an auth method of a v2 answer (`methodId` is v1's `id`); one that does not fit is left out.
pub(crate) fn v1_auth(methods: &Value) -> Vec<crate::types::AuthMethod> {
    methods
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| {
            let mut m = m.clone();
            if let Some(o) = m.as_object_mut() {
                if let Some(id) = o.remove("methodId") {
                    o.insert("id".into(), id);
                }
                if !o.contains_key("name") {
                    let id = o.get("id").cloned().unwrap_or(Value::Null);
                    o.insert("name".into(), id);
                }
            }
            serde_json::from_value(m).ok()
        })
        .collect()
}

/// The mode, the model and the id of the mode option that a v2 answer's `configOptions` report.
pub(crate) fn reported(answer: &Value) -> (Option<String>, Option<String>, Option<String>) {
    let mut mode = (None, None);
    let mut model = None;
    for o in answer
        .get("configOptions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let id = o.get("configId").and_then(Value::as_str);
        let cat = o.get("category").and_then(Value::as_str);
        let cur = o
            .get("currentValue")
            .and_then(Value::as_str)
            .map(String::from);
        if cat == Some("mode") || id == Some("mode") {
            mode = (cur, id.map(String::from));
        } else if cat == Some("model") || id == Some("model") {
            model = cur;
        }
    }
    (mode.0, model, mode.1)
}
