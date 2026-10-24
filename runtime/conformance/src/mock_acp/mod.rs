//! `ratatoskr-mock acp --as claude|codex|gemini [--script FILE] [--log FILE] [--llm URL]`: a scripted ACP agent
//! (JSON-RPC 2.0, one object per line on stdin/stdout) that stands in for the outside agents' CLIs.  Std only.
//! The wire is `agent-client-protocol-schema =1.12.0`'s (camelCase fields, `session/*` methods).
//!
//! A prompt's text is a program, one word-line per step (a port of `test/fixtures/mock-acp.el`'s words):
//!
//! | line | what the turn does |
//! |---|---|
//! | `tool:read PATH` / `tool:edit PATH` / `tool:exec CMD` | a tool call (pending, then completed) that does it in the session's cwd (edit appends a line) |
//! | `ask:permission KIND` | `session/request_permission` for a tool call of KIND (read, edit, execute, ...); says `permission: OPTION` |
//! | `call:TOOL JSON` | calls the hub's MCP tool TOOL through the first stdio server of `mcpServers`; says `call: TEXT` |
//! | `decide TEXT` | `call:record_decision {"text": TEXT}` |
//! | `commit MSG` | `git add -A && git commit -m MSG` in the cwd |
//! | `sleep-loop` | asks permission (execute) to run `sleep 30; pgrep -f ratatoskr-mock-sleep-loop`, runs it when allowed |
//! | `silent N` | N seconds with no output (a `session/cancel` ends the turn, `cancelled`) |
//! | `crash` | exits 3, "mock crashed" on stderr |
//! | anything else | "You said: ..." in two chunks |
//!
//! `--script FILE`: its non-empty lines are programs; the n-th prompt of the process runs line n (a prompt after
//! the last line runs its own words).  `--log FILE`: JSONL of `{"initialize"|"session/new"|"session/fork"|
//! "prompt"|"permission"|"llm"|"claude_options"|"codex_overrides"|"gemini": ...}`.  `--llm URL`: each turn first
//! POSTs a small JSON body to URL (a `ratatoskr-mock llm`), so its log counts one request per turn.
//!
//! Every prompt answer carries `_meta.turnId` ("t1", "t2", ...).  Messages have ids (`messageId` of chunks); a
//! fork's `_meta.jetbrains.air.fork.messageId` cuts the history: Claude after that message, Codex after its turn.
//! The terminal capability is never used (commands run in the agent's own process).

mod claude;
mod codex;
mod gemini;

use serde_json::{Value, json};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::File;
use std::io::{BufRead, Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Claude,
    Codex,
    Gemini,
}

struct Session {
    cwd: PathBuf,
    mcp: Vec<Value>,
    turns: u64,
    /// `(turn, message id)` of every user and agent message.
    history: Vec<(u64, String)>,
}

struct Agent {
    kind: Kind,
    argv: Vec<String>,
    rx: Receiver<Value>,
    queue: VecDeque<Value>,
    cancelled: HashSet<String>,
    sessions: HashMap<String, Session>,
    next_session: u64,
    next_out_id: u64,
    log: Option<File>,
    llm: Option<String>,
    script: Vec<String>,
    prompts: usize,
}

fn flag(args: &[String], name: &str) -> Option<String> {
    let i = args.iter().position(|a| a == name)?;
    match args.get(i + 1) {
        Some(v) => Some(v.clone()),
        None => crate::die(&format!("{name} needs a value")),
    }
}

pub fn run(args: &[String]) -> ! {
    let kind = match flag(args, "--as").as_deref() {
        Some("claude") => Kind::Claude,
        Some("codex") => Kind::Codex,
        Some("gemini") => Kind::Gemini,
        _ => crate::die(
            "usage: ratatoskr-mock acp --as claude|codex|gemini [--script FILE] [--log FILE] [--llm URL]",
        ),
    };
    let script = flag(args, "--script")
        .map(|p| {
            std::fs::read_to_string(&p)
                .unwrap_or_else(|e| crate::die(&format!("cannot read the script {p}: {e}")))
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    let log = flag(args, "--log").map(|p| {
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&p)
            .unwrap_or_else(|e| crate::die(&format!("cannot open the log {p}: {e}")))
    });
    let (tx, rx) = channel();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if let Ok(v) = serde_json::from_str::<Value>(&line)
                && tx.send(v).is_err()
            {
                break;
            }
        }
    });
    let mut a = Agent {
        kind,
        argv: args.to_vec(),
        rx,
        queue: VecDeque::new(),
        cancelled: HashSet::new(),
        sessions: HashMap::new(),
        next_session: 1,
        next_out_id: 1000,
        log,
        llm: flag(args, "--llm"),
        script,
        prompts: 0,
    };
    a.serve();
    std::process::exit(0)
}

fn send(v: &Value) {
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(format!("{v}\n").as_bytes());
    let _ = out.flush();
}

fn rpc_error(id: &Value, code: i64, message: &str) {
    send(&json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}));
}

fn text_of(prompt: &Value) -> String {
    prompt
        .as_array()
        .map(|bs| {
            bs.iter()
                .filter(|b| b["type"] == "text")
                .filter_map(|b| b["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

impl Agent {
    fn log(&mut self, key: &str, v: Value) {
        if let Some(f) = &mut self.log {
            let _ = f.write_all(format!("{}\n", json!({ key: v })).as_bytes());
        }
    }

    /// The next message: the queue first, then stdin.  `None` at end of input.
    fn next_message(&mut self) -> Option<Value> {
        self.queue.pop_front().or_else(|| self.rx.recv().ok())
    }

    fn serve(&mut self) {
        while let Some(m) = self.next_message() {
            self.handle(m);
        }
    }

    /// A message seen while a turn waits: cancels are noted, the rest waits its turn.
    fn stash(&mut self, m: Value) {
        if m["method"] == "session/cancel" {
            if let Some(s) = m["params"]["sessionId"].as_str() {
                self.cancelled.insert(s.into());
            }
        } else {
            self.queue.push_back(m);
        }
    }

    /// Wait for the client's answer to our request `id`.
    fn response(&mut self, id: u64) -> Option<Value> {
        let deadline = Instant::now() + Duration::from_secs(30);
        while Instant::now() < deadline {
            match self.rx.recv_timeout(Duration::from_millis(50)) {
                Ok(m) if m["id"] == json!(id) && m.get("method").is_none() => return Some(m),
                Ok(m) => self.stash(m),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return None,
            }
        }
        None
    }

    /// Sleep `d`, watching for a cancel of `sid`; true when cancelled.
    fn sleep(&mut self, sid: &str, d: Duration) -> bool {
        let end = Instant::now() + d;
        while Instant::now() < end {
            if self.cancelled.remove(sid) {
                return true;
            }
            match self.rx.recv_timeout(Duration::from_millis(50)) {
                Ok(m) => self.stash(m),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => break,
            }
        }
        self.cancelled.remove(sid)
    }

    fn request(&mut self, method: &str, params: Value) -> u64 {
        self.next_out_id += 1;
        let id = self.next_out_id;
        send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        id
    }

    fn update(&self, sid: &str, update: Value) {
        send(&json!({"jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": sid, "update": update}}));
    }

    fn session_caps(&self) -> Value {
        match self.kind {
            Kind::Claude => claude::session_caps(),
            Kind::Codex => codex::session_caps(),
            Kind::Gemini => gemini::session_caps(),
        }
    }

    fn open(&mut self, params: &Value) -> String {
        let sid = format!("s{}", self.next_session);
        self.next_session += 1;
        let session = Session {
            cwd: params["cwd"]
                .as_str()
                .map(PathBuf::from)
                .unwrap_or_else(|| ".".into()),
            mcp: params["mcpServers"].as_array().cloned().unwrap_or_default(),
            turns: 0,
            history: Vec::new(),
        };
        self.sessions.insert(sid.clone(), session);
        self.personality_log(params);
        sid
    }

    fn personality_log(&mut self, params: &Value) {
        match self.kind {
            Kind::Claude => self.log("claude_options", claude::options(params)),
            Kind::Codex => {
                let o = codex::overrides(&self.argv);
                self.log("codex_overrides", json!(o));
            }
            Kind::Gemini => self.log("gemini", gemini::note()),
        }
    }

    fn handle(&mut self, m: Value) {
        let Some(method) = m["method"].as_str().map(String::from) else {
            return; // a stray response
        };
        let id = m.get("id").cloned();
        let params = m["params"].clone();
        let Some(id) = id else {
            if method == "session/cancel" {
                self.stash(m);
            }
            return;
        };
        let reply = |result: Value| send(&json!({"jsonrpc": "2.0", "id": id, "result": result}));
        match method.as_str() {
            "initialize" => {
                self.log("initialize", params);
                reply(json!({"protocolVersion": 1, "authMethods": [],
                    "agentInfo": {"name": format!("ratatoskr-mock-{}", self.kind_name()), "version": "0.1.0"},
                    "agentCapabilities": {"loadSession": self.kind == Kind::Gemini,
                        "promptCapabilities": {"image": false, "audio": false, "embeddedContext": true},
                        "mcpCapabilities": {"http": false, "sse": false},
                        "sessionCapabilities": self.session_caps()}}));
            }
            "session/new" => {
                let sid = self.open(&params);
                self.log("session/new", json!({"sessionId": sid, "mcpServers": params["mcpServers"], "cwd": params["cwd"]}));
                reply(json!({"sessionId": sid}));
            }
            "session/load" if self.kind == Kind::Gemini => {
                let sid = params["sessionId"].as_str().unwrap_or("s0").to_string();
                let s = self.open(&params);
                if let Some(v) = self.sessions.remove(&s) {
                    self.sessions.insert(sid, v);
                }
                reply(json!({}));
            }
            "session/list" if self.kind != Kind::Gemini => {
                let mut ids: Vec<&String> = self.sessions.keys().collect();
                ids.sort();
                let list: Vec<Value> = ids
                    .iter()
                    .map(|s| json!({"sessionId": s, "cwd": self.sessions[*s].cwd}))
                    .collect();
                reply(json!({"sessions": list}));
            }
            "session/resume" if self.kind != Kind::Gemini => {
                let sid = params["sessionId"].as_str().unwrap_or("s0").to_string();
                if !self.sessions.contains_key(&sid) {
                    let s = self.open(&params);
                    let v = self.sessions.remove(&s).unwrap();
                    self.sessions.insert(sid, v);
                }
                reply(json!({}));
            }
            "session/close" if self.kind != Kind::Gemini => {
                let gone = params["sessionId"]
                    .as_str()
                    .and_then(|s| self.sessions.remove(s));
                if gone.is_some() {
                    reply(json!({}));
                } else {
                    rpc_error(&id, -32602, "unknown session");
                }
            }
            "session/fork" if self.kind != Kind::Gemini => self.fork(&id, &params),
            "session/prompt" => self.prompt(&id, &params),
            _ => rpc_error(&id, -32601, &format!("method not found: {method}")),
        }
    }

    fn kind_name(&self) -> &'static str {
        match self.kind {
            Kind::Claude => "claude",
            Kind::Codex => "codex",
            Kind::Gemini => "gemini",
        }
    }

    fn fork(&mut self, id: &Value, params: &Value) {
        let Some(src) = params["sessionId"]
            .as_str()
            .and_then(|s| self.sessions.get(s))
        else {
            return rpc_error(id, -32602, "unknown session");
        };
        let at = params
            .pointer("/_meta/jetbrains/air/fork/messageId")
            .and_then(Value::as_str);
        let mut history = src.history.clone();
        let (level, turns) = if self.kind == Kind::Claude {
            ("message", 0)
        } else {
            ("turn", 0)
        };
        let _ = turns;
        if let Some(at) = at {
            match history.iter().position(|(_, m)| m == at) {
                Some(p) if level == "message" => history.truncate(p + 1),
                Some(p) => {
                    let t = history[p].0;
                    history.retain(|(turn, _)| *turn <= t);
                }
                None => return rpc_error(id, -32602, &format!("unknown message {at}")),
            }
        }
        let turns = history.iter().map(|(t, _)| *t).max().unwrap_or(0);
        let mut cwd = params.clone();
        if cwd["cwd"].is_null() {
            cwd["cwd"] = json!(src.cwd);
        }
        let kept = history.len();
        let sid = self.open(&cwd);
        let s = self.sessions.get_mut(&sid).unwrap();
        s.history = history;
        s.turns = turns;
        self.log(
            "session/fork",
            json!({"from": params["sessionId"], "sessionId": sid, "level": level, "messageId": at, "kept": kept, "turns": turns}),
        );
        send(
            &json!({"jsonrpc": "2.0", "id": id, "result": {"sessionId": sid,
            "_meta": {"forkLevel": level, "kept": kept, "turns": turns}}}),
        );
    }

    fn say(&mut self, sid: &str, turn: u64, text: &str) {
        let n = self.sessions[sid].history.len();
        let mid = format!("a-{turn}-{n}");
        self.sessions
            .get_mut(sid)
            .unwrap()
            .history
            .push((turn, mid.clone()));
        self.update(
            sid,
            json!({"sessionUpdate": "agent_message_chunk", "messageId": mid,
            "content": {"type": "text", "text": text}}),
        );
    }

    fn prompt(&mut self, id: &Value, params: &Value) {
        let Some(sid) = params["sessionId"]
            .as_str()
            .map(String::from)
            .filter(|s| self.sessions.contains_key(s))
        else {
            return rpc_error(id, -32602, "unknown session");
        };
        self.cancelled.remove(&sid);
        let text = text_of(&params["prompt"]);
        let program = self
            .script
            .get(self.prompts)
            .cloned()
            .unwrap_or_else(|| text.clone());
        self.prompts += 1;
        let (turn, umid) = {
            let s = self.sessions.get_mut(&sid).unwrap();
            s.turns += 1;
            let umid = params["messageId"]
                .as_str()
                .map(String::from)
                .unwrap_or(format!("u-{}", s.turns));
            s.history.push((s.turns, umid.clone()));
            (s.turns, umid)
        };
        self.log(
            "prompt",
            json!({"sessionId": sid, "turn": turn, "text": text, "messageId": umid}),
        );
        if let Some(url) = self.llm.clone() {
            let status = llm_call(&url, &text);
            self.log("llm", json!({"turn": turn, "status": status}));
        }
        let mut stop = "end_turn";
        for line in program.lines().map(str::trim).filter(|l| !l.is_empty()) {
            if self.cancelled.contains(&sid) {
                stop = "cancelled";
                break;
            }
            if self.word(&sid, turn, line) {
                stop = "cancelled";
                break;
            }
        }
        let extras = match self.kind {
            Kind::Claude => claude::after_turn(&sid, turn, text.len()),
            Kind::Codex => codex::after_turn(&sid, turn, text.len()),
            Kind::Gemini => gemini::after_turn(&sid, turn, text.len()),
        };
        for (method, p) in extras {
            send(&json!({"jsonrpc": "2.0", "method": method, "params": p}));
        }
        send(
            &json!({"jsonrpc": "2.0", "id": id, "result": {"stopReason": stop,
            "usage": {"inputTokens": 10 * turn, "outputTokens": 5 * turn, "totalTokens": 15 * turn},
            "_meta": {"turnId": format!("t{turn}")}}}),
        );
    }

    /// One word-line of a turn; true when the turn was cancelled.
    fn word(&mut self, sid: &str, turn: u64, line: &str) -> bool {
        let (head, rest) = line
            .split_once(char::is_whitespace)
            .map_or((line, ""), |(h, r)| (h, r.trim()));
        let cwd = self.sessions[sid].cwd.clone();
        match head {
            "tool:read" => {
                let path = cwd.join(rest);
                let body =
                    std::fs::read_to_string(&path).unwrap_or_else(|e| format!("cannot read: {e}"));
                self.tool(
                    sid,
                    turn,
                    "read",
                    &format!("Read {rest}"),
                    json!({"path": rest}),
                    &body,
                );
            }
            "tool:edit" => {
                let path = cwd.join(rest);
                let r = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&path)
                    .and_then(|mut f| f.write_all(b"edited by ratatoskr-mock\n"));
                let out = match r {
                    Ok(()) => "edited".to_string(),
                    Err(e) => format!("cannot edit: {e}"),
                };
                self.tool(
                    sid,
                    turn,
                    "edit",
                    &format!("Edit {rest}"),
                    json!({"path": rest}),
                    &out,
                );
            }
            "tool:exec" => {
                let out = sh(&cwd, rest);
                self.tool(sid, turn, "execute", rest, json!({"command": rest}), &out);
            }
            "ask:permission" => {
                let kind = if rest.is_empty() { "execute" } else { rest };
                let answer = self.permission(sid, turn, kind, &format!("{kind} request"));
                self.say(sid, turn, &format!("permission: {answer}"));
            }
            "sleep-loop" => {
                let cmd = "sleep 30; pgrep -f ratatoskr-mock-sleep-loop";
                let answer = self.permission(sid, turn, "execute", cmd);
                if answer.starts_with("allow") {
                    let mut child = Command::new("sh")
                        .arg("-c")
                        .arg(cmd)
                        .current_dir(&cwd)
                        .stdin(Stdio::null())
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .spawn()
                        .ok();
                    let mut cancelled = false;
                    while let Some(c) = child.as_mut() {
                        if matches!(c.try_wait(), Ok(Some(_)) | Err(_)) {
                            break;
                        }
                        if self.sleep(sid, Duration::from_millis(100)) {
                            let _ = c.kill();
                            let _ = c.wait();
                            cancelled = true;
                            break;
                        }
                    }
                    if cancelled {
                        return true;
                    }
                    self.say(sid, turn, "sleep-loop: done");
                } else {
                    self.say(sid, turn, &format!("sleep-loop: {answer}"));
                }
            }
            "decide" => {
                let r = self.mcp(sid, "record_decision", &json!({"text": rest}).to_string());
                self.say(sid, turn, &format!("call: {r}"));
            }
            "commit" => {
                let msg = if rest.is_empty() { "mock work" } else { rest };
                let out = Command::new("git")
                    .args([
                        "-c",
                        "user.name=mock",
                        "-c",
                        "user.email=mock@example.invalid",
                        "add",
                        "-A",
                    ])
                    .current_dir(&cwd)
                    .output()
                    .and_then(|_| {
                        Command::new("git")
                            .args([
                                "-c",
                                "user.name=mock",
                                "-c",
                                "user.email=mock@example.invalid",
                                "commit",
                                "-q",
                                "-m",
                                msg,
                            ])
                            .current_dir(&cwd)
                            .output()
                    });
                let said = match out {
                    Ok(o) if o.status.success() => format!("committed: {msg}"),
                    _ => "commit failed".into(),
                };
                self.say(sid, turn, &said);
            }
            "silent" => {
                let n: f64 = rest.parse().unwrap_or(1.0);
                return self.sleep(sid, Duration::from_secs_f64(n));
            }
            "crash" => {
                eprintln!("mock crashed");
                std::process::exit(3);
            }
            _ if head.starts_with("call:") => {
                let r = self.mcp(sid, &head[5..], if rest.is_empty() { "{}" } else { rest });
                self.say(sid, turn, &format!("call: {r}"));
            }
            _ => {
                let (a, b) = line.split_at(line.len() / 2);
                let (a, b) = if line.is_char_boundary(line.len() / 2) {
                    (a, b)
                } else {
                    (line, "")
                };
                self.say(sid, turn, &format!("You said: {a}"));
                self.say(sid, turn, b);
            }
        }
        false
    }

    fn tool(&mut self, sid: &str, turn: u64, kind: &str, title: &str, input: Value, out: &str) {
        let tid = format!("tc-{turn}-{}", self.next_out_id);
        self.next_out_id += 1;
        self.update(
            sid,
            json!({"sessionUpdate": "tool_call", "toolCallId": tid, "title": title,
            "kind": kind, "status": "pending", "rawInput": input}),
        );
        self.update(
            sid,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": out}}]}),
        );
    }

    /// Ask the client; the chosen option's id, or `cancelled`.
    fn permission(&mut self, sid: &str, turn: u64, kind: &str, title: &str) -> String {
        let tid = format!("tc-{turn}-{}", self.next_out_id);
        self.next_out_id += 1;
        let rid = self.request("session/request_permission", json!({"sessionId": sid,
            "toolCall": {"toolCallId": tid, "title": title, "kind": kind, "status": "pending", "rawInput": {"command": title}},
            "options": [
                {"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"},
                {"optionId": "allow_always", "name": "Always allow", "kind": "allow_always"},
                {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}]}));
        let answer = self.response(rid).map_or("cancelled".to_string(), |r| {
            r["result"]["outcome"]["optionId"]
                .as_str()
                .map(String::from)
                .unwrap_or_else(|| "cancelled".into())
        });
        self.log("permission", json!({"kind": kind, "answer": answer}));
        answer
    }

    /// Call `tool` on the first stdio server of the session's `mcpServers`; its text, or why not.
    fn mcp(&mut self, sid: &str, tool: &str, args: &str) -> String {
        let Some(spec) = self.sessions[sid].mcp.first().cloned() else {
            return "no mcpServers".into();
        };
        let mut cmd = Command::new(spec["command"].as_str().unwrap_or("false"));
        for a in spec["args"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            cmd.arg(a);
        }
        for e in spec["env"].as_array().into_iter().flatten() {
            if let (Some(n), Some(v)) = (e["name"].as_str(), e["value"].as_str()) {
                cmd.env(n, v);
            }
        }
        let Ok(mut child) = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        else {
            return "cannot start the MCP server".into();
        };
        let mut stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            for l in std::io::BufReader::new(stdout)
                .lines()
                .map_while(Result::ok)
            {
                if let Ok(v) = serde_json::from_str::<Value>(&l) {
                    let _ = tx.send(v);
                }
            }
        });
        let args: Value = serde_json::from_str(args).unwrap_or(json!({}));
        let _ = stdin.write_all(format!("{}\n", json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "ratatoskr-mock", "version": "0.1.0"}}})).as_bytes());
        let _ = stdin.write_all(
            format!(
                "{}\n",
                json!({"jsonrpc": "2.0", "method": "notifications/initialized"})
            )
            .as_bytes(),
        );
        let _ = stdin.write_all(
            format!(
                "{}\n",
                json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": tool, "arguments": args}})
            )
            .as_bytes(),
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut out = "no answer".to_string();
        while let Some(left) = deadline.checked_duration_since(Instant::now()) {
            match rx.recv_timeout(left) {
                Ok(v) if v["id"] == 2 => {
                    out = v["result"]["content"][0]["text"]
                        .as_str()
                        .map(String::from)
                        .unwrap_or_else(|| {
                            v["error"]["message"]
                                .as_str()
                                .unwrap_or("no text")
                                .to_string()
                        });
                    break;
                }
                Ok(_) => {}
                Err(_) => break,
            }
        }
        drop(stdin);
        let _ = child.kill();
        let _ = child.wait();
        out
    }
}

fn sh(cwd: &PathBuf, cmd: &str) -> String {
    match Command::new("sh")
        .arg("-c")
        .arg(cmd)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .output()
    {
        Ok(o) => format!(
            "{}{}",
            String::from_utf8_lossy(&o.stdout),
            String::from_utf8_lossy(&o.stderr)
        ),
        Err(e) => format!("cannot run: {e}"),
    }
}

/// POST a small body to URL (`http://HOST:PORT/PATH`); the status line's code, or 0.
fn llm_call(url: &str, prompt: &str) -> u16 {
    let rest = url.strip_prefix("http://").unwrap_or(url);
    let (hostport, path) = match rest.split_once('/') {
        Some((h, p)) => (h, format!("/{p}")),
        None => (rest, "/".to_string()),
    };
    let body =
        json!({"model": "mock", "messages": [{"role": "user", "content": prompt}]}).to_string();
    let Ok(mut s) = std::net::TcpStream::connect(hostport) else {
        return 0;
    };
    let _ = s.set_read_timeout(Some(Duration::from_secs(10)));
    let req = format!(
        "POST {path} HTTP/1.1\r\nHost: {hostport}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    if s.write_all(req.as_bytes()).is_err() {
        return 0;
    }
    let mut resp = String::new();
    let _ = s.read_to_string(&mut resp);
    resp.split_whitespace()
        .nth(1)
        .and_then(|c| c.parse().ok())
        .unwrap_or(0)
}
