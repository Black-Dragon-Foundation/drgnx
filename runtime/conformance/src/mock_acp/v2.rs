//! The mock's ACP v2 face: `initialize` answers 2 to a client that asks for it (Claude and Codex personalities), then
//! the prompt is acknowledged at insertion and the turn runs between `state_update running` and `state_update idle`.
//! Background work is v2's: a list on every state update, display terminals, tool calls that outlive their turn and
//! child sessions, each stopped by its own cancel request.
//!
//! The words (a turn's program lines, besides the ones `mod.rs` documents):
//!
//! | line | what the turn does |
//! |---|---|
//! | `bg:shell ID CMD` | a display terminal ID that runs CMD (output `started CMD`), listed as background work, cancellable |
//! | `bg:output ID TEXT` | TEXT and a line break appended to terminal ID |
//! | `bg:exit ID CODE` | terminal ID exits with CODE and leaves the list |
//! | `bg:monitor ID TITLE` | a tool call ID (a watcher), in progress and cancellable, listed |
//! | `bg:passive ID TITLE` | as `bg:monitor`, but the item does not advertise cancel |
//! | `bg:settle ID STATUS` | tool call ID ends `completed`, `failed` or `cancelled` and leaves the list |
//! | `bg:progress ID TEXT` | the last line of item ID (a terminal's output line, a watcher's content, a child's `progress`) is TEXT |
//! | `bg:subagent ID TITLE` | a child session ID, running and cancellable, listed; it says one thing in its own transcript |
//!
//! `tool_call/cancel`, `terminal/cancel` and `session/cancel` of a child are answered as the protocol says: an empty
//! result, then the update that confirms it, then the new list.

use super::{Agent, Kind, rpc_error, send};
use serde_json::{Value, json};

/// A background item: its kind (`terminal`, `tool_call`, `subagent`), its id and the update that announced it.
pub(super) struct Item {
    pub kind: &'static str,
    pub id: String,
    pub announce: Value,
}

pub(super) fn answer_init(a: &Agent) -> Value {
    let mut caps = json!({"session": {"prompt": {"embeddedContext": {}}, "mcp": {"stdio": {}}}});
    if let Some(meta) = super::panel::caps_meta(&a.argv) {
        caps["_meta"] = meta;
    }
    json!({"protocolVersion": 2, "authMethods": [],
        "info": {"name": format!("ratatoskr-mock-{}", a.kind_name()), "version": "0.1.0"},
        "capabilities": caps})
}

/// The config options a v2 session opens with (its mode is one of them).
pub(super) fn config_options() -> Value {
    json!([{"configId": "mode", "name": "Mode", "category": "mode", "type": "select",
        "currentValue": "default", "options": [{"value": "default", "name": "Default"}]}])
}

/// RFC 4648 base64 of BYTES.
pub(super) fn b64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for c in bytes.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= c.len() {
                out.push(T[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

impl Agent {
    fn bg_list(&self, sid: &str) -> Value {
        Value::Array(
            self.sessions[sid]
                .bg
                .iter()
                .map(|i| match i.kind {
                    "terminal" => json!({"type": "terminal", "terminalId": i.id}),
                    "tool_call" => json!({"type": "tool_call", "toolCallId": i.id}),
                    _ => json!({"type": "subagent", "sessionId": i.id}),
                })
                .collect(),
        )
    }

    /// A `state_update` of SID (BODY has `state` and what goes with it), with the background list.
    pub(super) fn state_v2(&self, sid: &str, mut body: Value) {
        body["sessionUpdate"] = json!("state_update");
        body["background"] = self.bg_list(sid);
        self.update(sid, body);
    }

    /// The repeated snapshot an Agent sends when the list changes.
    fn relist(&self, sid: &str, state: &str) {
        self.state_v2(sid, json!({"state": state}));
    }

    fn bg_add(&mut self, sid: &str, kind: &'static str, id: &str, announce: Value) {
        let bg = &mut self.sessions.get_mut(sid).unwrap().bg;
        bg.retain(|i| !(i.kind == kind && i.id == id));
        bg.push(Item {
            kind,
            id: id.into(),
            announce,
        });
    }

    fn bg_remove(&mut self, sid: &str, kind: &str, id: &str) {
        self.sessions
            .get_mut(sid)
            .unwrap()
            .bg
            .retain(|i| !(i.kind == kind && i.id == id));
    }

    /// One `bg:` word; true when the line was one.
    pub(super) fn bg_word(&mut self, sid: &str, head: &str, rest: &str) -> bool {
        let (id, arg) = rest
            .split_once(char::is_whitespace)
            .map_or((rest, ""), |(i, a)| (i, a.trim()));
        let cwd = self.sessions[sid].cwd.to_string_lossy().into_owned();
        match head {
            "bg:shell" => {
                let announce = json!({"sessionUpdate": "terminal_update", "terminalId": id, "command": arg,
                    "cwd": cwd, "capabilities": {"cancel": {}}});
                self.update(sid, announce.clone());
                self.update(
                    sid,
                    json!({"sessionUpdate": "terminal_output_chunk", "terminalId": id,
                        "data": b64(format!("started {arg}\n").as_bytes())}),
                );
                // the call that started it returned control to the model: final, and it shows the terminal
                self.update(
                    sid,
                    json!({"sessionUpdate": "tool_call_update", "toolCallId": format!("call-{id}"),
                        "title": format!("Bash: {arg}"), "kind": "execute", "status": "completed",
                        "content": [{"type": "terminal", "terminalId": id}]}),
                );
                self.bg_add(sid, "terminal", id, announce);
                self.relist(sid, "running");
            }
            "bg:progress" => {
                let kind = self.sessions[sid]
                    .bg
                    .iter()
                    .find(|i| i.id == id)
                    .map_or("", |i| i.kind);
                match kind {
                    "terminal" => self.update(
                        sid,
                        json!({"sessionUpdate": "terminal_output_chunk", "terminalId": id,
                            "data": b64(format!("{arg}\n").as_bytes())}),
                    ),
                    "tool_call" => self.update(
                        sid,
                        json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "in_progress",
                            "content": [{"type": "content", "content": {"type": "text", "text": arg}}]}),
                    ),
                    "subagent" => self.update(
                        sid,
                        json!({"sessionUpdate": "subagent_update", "sessionId": id, "progress": arg}),
                    ),
                    _ => {}
                }
            }
            "bg:output" => self.update(
                sid,
                json!({"sessionUpdate": "terminal_output_chunk", "terminalId": id,
                    "data": b64(format!("{arg}\n").as_bytes())}),
            ),
            "bg:exit" => {
                let code: i64 = arg.parse().unwrap_or(0);
                self.update(
                    sid,
                    json!({"sessionUpdate": "terminal_update", "terminalId": id,
                        "exitStatus": {"exitCode": code}, "capabilities": null}),
                );
                self.bg_remove(sid, "terminal", id);
                self.relist(sid, "running");
            }
            "bg:monitor" => {
                let announce = json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "title": arg,
                    "kind": "other", "status": "in_progress", "capabilities": {"cancel": {}},
                    "content": [{"type": "content", "content": {"type": "text", "text": "watching"}}]});
                self.update(sid, announce.clone());
                self.bg_add(sid, "tool_call", id, announce);
                self.relist(sid, "running");
            }
            "bg:passive" => {
                let announce = json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "title": arg,
                    "kind": "other", "status": "in_progress"});
                self.update(sid, announce.clone());
                self.bg_add(sid, "tool_call", id, announce);
                self.relist(sid, "running");
            }
            "bg:settle" => {
                let status = if arg.is_empty() { "completed" } else { arg };
                self.update(
                    sid,
                    json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": status,
                        "capabilities": null}),
                );
                self.bg_remove(sid, "tool_call", id);
                self.relist(sid, "running");
            }
            "bg:subagent" => {
                let announce = json!({"sessionUpdate": "subagent_update", "sessionId": id, "title": arg,
                    "capabilities": {"cancel": {}}, "state": {"state": "running"}});
                self.update(sid, announce.clone());
                self.update(
                    id,
                    json!({"sessionUpdate": "state_update", "state": "running"}),
                );
                self.update(
                    id,
                    json!({"sessionUpdate": "agent_message_chunk", "messageId": format!("{id}-m1"),
                        "content": {"type": "text", "text": "child at work"}}),
                );
                self.bg_add(sid, "subagent", id, announce);
                self.relist(sid, "running");
            }
            _ => return false,
        }
        true
    }

    /// A v2 turn: the prompt is acknowledged at insertion, the work runs between `running` and `idle`.
    pub(super) fn prompt_v2(&mut self, id: &Value, params: &Value) {
        let Some(sid) = params["sessionId"]
            .as_str()
            .map(String::from)
            .filter(|s| self.sessions.contains_key(s))
        else {
            return rpc_error(id, -32602, "unknown session");
        };
        self.cancelled.remove(&sid);
        let text = super::text_of(&params["prompt"]);
        let program = self
            .script
            .get(self.prompts)
            .cloned()
            .unwrap_or_else(|| text.clone());
        self.prompts += 1;
        let (turn, umid) = {
            let s = self.sessions.get_mut(&sid).unwrap();
            s.turns += 1;
            let umid = format!("u-{}", s.turns);
            s.history.push((s.turns, umid.clone()));
            (s.turns, umid)
        };
        self.log(
            "prompt",
            json!({"sessionId": sid, "turn": turn, "text": text, "messageId": umid}),
        );
        send(&json!({"jsonrpc": "2.0", "id": id, "result": {"messageId": umid}}));
        self.update(
            &sid,
            json!({"sessionUpdate": "user_message", "messageId": umid,
                "content": [{"type": "text", "text": text}]}),
        );
        self.state_v2(&sid, json!({"state": "running"}));
        let mut stop = "end_turn";
        for line in program.lines().map(str::trim).filter(|l| !l.is_empty()) {
            if self.cancelled.contains(&sid) {
                stop = "cancelled";
                break;
            }
            let (head, rest) = line
                .split_once(char::is_whitespace)
                .map_or((line, ""), |(h, r)| (h, r.trim()));
            if head.starts_with("bg:") && self.bg_word(&sid, head, rest) {
                continue;
            }
            if self.word(&sid, turn, line) {
                stop = "cancelled";
                break;
            }
        }
        let extras = match self.kind {
            Kind::Claude => super::claude::after_turn(&sid, turn, text.len()),
            Kind::Codex => super::codex::after_turn(&sid, turn, text.len()),
            _ => Vec::new(),
        };
        for (method, p) in extras {
            send(&json!({"jsonrpc": "2.0", "method": method, "params": p}));
        }
        self.save(&sid);
        let mut idle = json!({"state": "idle", "stopReason": stop,
            "usage": {"inputTokens": 10 * turn, "outputTokens": 5 * turn, "totalTokens": 15 * turn},
            "_meta": {"turnId": format!("t{turn}")}});
        if let Some((code, message)) = self.fail.take() {
            idle["stopReason"] = json!("error");
            idle["error"] = json!({"code": code, "message": message});
        }
        self.state_v2(&sid, idle);
    }

    /// `session/resume` on v2: what runs is announced again, then the current state, then the answer.
    pub(super) fn resume_v2(&mut self, id: &Value, sid: &str) {
        let announces: Vec<Value> = self.sessions[sid]
            .bg
            .iter()
            .map(|i| i.announce.clone())
            .collect();
        for a in announces {
            self.update(sid, a);
        }
        self.state_v2(sid, json!({"state": "idle"}));
        send(&json!({"jsonrpc": "2.0", "id": id, "result": {"configOptions": config_options()}}));
    }

    /// `tool_call/cancel` and `terminal/cancel`: answered at once, confirmed by the update, then the new list.
    pub(super) fn cancel_item(&mut self, id: &Value, params: &Value, kind: &'static str) {
        let (key, what) = if kind == "terminal" {
            ("terminalId", "terminal")
        } else {
            ("toolCallId", "tool call")
        };
        let (Some(sid), Some(item)) = (params["sessionId"].as_str(), params[key].as_str()) else {
            return rpc_error(id, -32602, "sessionId and an id are required");
        };
        let known = self
            .sessions
            .get(sid)
            .is_some_and(|s| s.bg.iter().any(|i| i.kind == kind && i.id == item));
        if !known {
            return rpc_error(id, -32602, &format!("unknown or not cancellable {what}"));
        }
        let sid = sid.to_string();
        self.log("cancel", json!({"kind": kind, "id": item}));
        send(&json!({"jsonrpc": "2.0", "id": id, "result": {}}));
        let confirm = if kind == "terminal" {
            json!({"sessionUpdate": "terminal_update", "terminalId": item,
                "exitStatus": {"signal": "SIGTERM"}, "capabilities": null})
        } else {
            json!({"sessionUpdate": "tool_call_update", "toolCallId": item, "status": "cancelled",
                "capabilities": null})
        };
        self.update(&sid, confirm);
        self.bg_remove(&sid, kind, item);
        self.relist(&sid, "idle");
    }

    /// `session/cancel` for a child session of a session this process holds: its work stops, the parent hears it.
    /// True when SID was such a child.
    pub(super) fn cancel_child(&mut self, child: &str) -> bool {
        let Some(parent) = self
            .sessions
            .iter()
            .find(|(_, s)| s.bg.iter().any(|i| i.kind == "subagent" && i.id == child))
            .map(|(p, _)| p.clone())
        else {
            return false;
        };
        self.log("cancel", json!({"kind": "subagent", "id": child}));
        let idle = json!({"state": "idle", "stopReason": "cancelled"});
        self.update(child, {
            let mut u = idle.clone();
            u["sessionUpdate"] = json!("state_update");
            u
        });
        self.update(
            &parent,
            json!({"sessionUpdate": "subagent_update", "sessionId": child, "state": idle}),
        );
        self.bg_remove(&parent, "subagent", child);
        self.relist(&parent, "idle");
        true
    }
}
