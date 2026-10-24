//! `ratatoskr-mock acp`: one test per prompt word and personality, over its stdio.

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, channel};
use std::time::Duration;

const MOCK: &str = env!("CARGO_BIN_EXE_ratatoskr-mock");

struct Acp {
    child: Child,
    stdin: ChildStdin,
    rx: Receiver<Value>,
    next: u64,
    /// Everything that is not the answer to a call: notifications and agent requests, in order.
    seen: Vec<Value>,
    /// The option an agent request for permission gets.
    allow: &'static str,
}

impl Acp {
    fn start(extra: &[&str]) -> Acp {
        let mut child = Command::new(MOCK)
            .arg("acp")
            .args(extra)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let out = child.stdout.take().unwrap();
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            for l in BufReader::new(out).lines().map_while(Result::ok) {
                let _ = tx.send(serde_json::from_str::<Value>(&l).unwrap());
            }
        });
        let stdin = child.stdin.take().unwrap();
        Acp {
            child,
            stdin,
            rx,
            next: 0,
            seen: vec![],
            allow: "allow_once",
        }
    }

    fn write(&mut self, v: Value) {
        writeln!(self.stdin, "{v}").unwrap();
    }

    /// Send a request and return the whole answer object (result or error).
    fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        self.write(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        loop {
            let m = self
                .rx
                .recv_timeout(Duration::from_secs(20))
                .expect("an answer in time");
            if m["id"] == id && m.get("method").is_none() {
                return m;
            }
            if m.get("method").is_some() && m.get("id").is_some() {
                let answer = if self.allow == "cancelled" {
                    json!({"outcome": "cancelled"})
                } else {
                    json!({"outcome": "selected", "optionId": self.allow})
                };
                self.write(json!({"jsonrpc": "2.0", "id": m["id"], "result": {"outcome": answer}}));
            }
            self.seen.push(m);
        }
    }

    fn init(&mut self) -> Value {
        self.call("initialize", json!({"protocolVersion": 1,
            "clientCapabilities": {"fs": {"readTextFile": false, "writeTextFile": false}, "terminal": false}}))
    }

    fn new_session(&mut self, cwd: &str, extra: Value) -> String {
        let mut p = json!({"cwd": cwd, "mcpServers": []});
        for (k, v) in extra.as_object().cloned().unwrap_or_default() {
            p[k] = v;
        }
        let r = self.call("session/new", p);
        r["result"]["sessionId"].as_str().unwrap().to_string()
    }

    fn prompt(&mut self, sid: &str, text: &str) -> Value {
        self.call(
            "session/prompt",
            json!({"sessionId": sid, "prompt": [{"type": "text", "text": text}]}),
        )
    }

    /// The agent's message text so far.
    fn said(&self) -> String {
        self.seen
            .iter()
            .filter(|m| m["params"]["update"]["sessionUpdate"] == "agent_message_chunk")
            .filter_map(|m| m["params"]["update"]["content"]["text"].as_str())
            .collect()
    }

    fn updates(&self, kind: &str) -> Vec<Value> {
        self.seen
            .iter()
            .filter(|m| m["params"]["update"]["sessionUpdate"] == kind)
            .map(|m| m["params"]["update"].clone())
            .collect()
    }
}

impl Drop for Acp {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn dir() -> tempfile::TempDir {
    tempfile::tempdir().unwrap()
}

fn log_lines(path: &std::path::Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

#[test]
fn capabilities_differ_by_personality() {
    for (who, load, sessions) in [
        ("claude", false, vec!["close", "fork", "list", "resume"]),
        ("codex", false, vec!["close", "fork", "list", "resume"]),
        ("gemini", true, vec![]),
    ] {
        let mut a = Acp::start(&["--as", who]);
        let r = a.init();
        let caps = &r["result"]["agentCapabilities"];
        assert_eq!(caps["loadSession"], load, "{who}");
        let mut got: Vec<&str> = caps["sessionCapabilities"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        got.sort();
        assert_eq!(got, sessions, "{who}");
        assert_eq!(r["result"]["protocolVersion"], 1);
    }
}

#[test]
fn gemini_has_no_fork_list_resume_or_close() {
    let d = dir();
    let mut a = Acp::start(&["--as", "gemini"]);
    a.init();
    let sid = a.new_session(d.path().to_str().unwrap(), json!({}));
    for m in [
        "session/fork",
        "session/list",
        "session/resume",
        "session/close",
    ] {
        let r = a.call(m, json!({"sessionId": sid, "cwd": "/"}));
        assert_eq!(r["error"]["code"], -32601, "{m}");
    }
    let r = a.call(
        "session/load",
        json!({"sessionId": "old", "cwd": "/", "mcpServers": []}),
    );
    assert!(r["result"].is_object());
}

#[test]
fn claude_logs_its_options_and_sends_usage_and_a_rate_limit() {
    let d = dir();
    let log = d.path().join("log");
    let mut a = Acp::start(&["--as", "claude", "--log", log.to_str().unwrap()]);
    a.init();
    let sid = a.new_session(
        d.path().to_str().unwrap(),
        json!({"_meta": {"claudeCode": {"options": {"permissionMode": "default", "settingSources": []}}}}),
    );
    let r = a.prompt(&sid, "hello");
    assert_eq!(r["result"]["stopReason"], "end_turn");
    assert_eq!(r["result"]["_meta"]["turnId"], "t1");
    assert!(a.said().contains("You said: hello"));
    let u = &a.updates("usage_update")[0];
    assert_eq!(u["size"], 200_000);
    assert_eq!(u["cost"]["currency"], "USD");
    assert!(a.seen.iter().any(|m| m["method"] == "_claude/rateLimit"));
    let l = log_lines(&log);
    assert!(
        l.iter()
            .any(|v| v["claude_options"]["permissionMode"] == "default")
    );
}

#[test]
fn codex_reads_overrides_from_argv_and_sends_usage_and_a_window() {
    let d = dir();
    let log = d.path().join("log");
    let mut a = Acp::start(&[
        "--as",
        "codex",
        "--log",
        log.to_str().unwrap(),
        "-c",
        "approval_policy=never",
        "-c",
        "model=x",
    ]);
    a.init();
    let sid = a.new_session(d.path().to_str().unwrap(), json!({}));
    a.prompt(&sid, "hi");
    let u = &a.updates("usage_update")[0];
    assert!(u.get("cost").is_none());
    assert!(
        a.seen.iter().any(|m| m["method"] == "_codex/rateLimits"
            && m["params"]["primary"]["windowMinutes"] == 300)
    );
    let l = log_lines(&log);
    let o = l.iter().find_map(|v| v.get("codex_overrides")).unwrap();
    assert_eq!(o, &json!(["approval_policy=never", "model=x"]));
}

fn fork_at(who: &str, msg: &str) -> Value {
    let d = dir();
    let mut a = Acp::start(&["--as", who]);
    a.init();
    let sid = a.new_session(d.path().to_str().unwrap(), json!({}));
    a.prompt(&sid, "one");
    a.prompt(&sid, "two");
    let r = a.call(
        "session/fork",
        json!({"sessionId": sid, "cwd": d.path(), "mcpServers": [],
            "_meta": {"jetbrains": {"air": {"fork": {"version": 1, "messageId": msg}}}}}),
    );
    r["result"].clone()
}

#[test]
fn claude_forks_at_a_message_codex_at_a_turn() {
    // history: u-1, a-1-1, a-1-2, u-2, a-2-4, a-2-5 (turn 1's user message is index 0)
    let c = fork_at("claude", "a-1-1");
    assert_eq!(c["_meta"]["forkLevel"], "message");
    assert_eq!(c["_meta"]["kept"], 2);
    let x = fork_at("codex", "a-1-1");
    assert_eq!(x["_meta"]["forkLevel"], "turn");
    assert_eq!(x["_meta"]["kept"], 3);
    assert_eq!(x["_meta"]["turns"], 1);
    assert!(c["sessionId"].is_string());
}

#[test]
fn tool_words_read_edit_exec() {
    let d = dir();
    std::fs::write(d.path().join("f.txt"), "content here\n").unwrap();
    let mut a = Acp::start(&["--as", "claude"]);
    a.init();
    let sid = a.new_session(d.path().to_str().unwrap(), json!({}));
    a.prompt(&sid, "tool:read f.txt\ntool:edit f.txt\ntool:exec echo hi");
    let calls = a.updates("tool_call");
    let kinds: Vec<&str> = calls.iter().map(|c| c["kind"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["read", "edit", "execute"]);
    let done = a.updates("tool_call_update");
    assert_eq!(done.len(), 3);
    assert!(
        done[0]["content"][0]["content"]["text"]
            .as_str()
            .unwrap()
            .contains("content here")
    );
    assert!(
        done[2]["content"][0]["content"]["text"]
            .as_str()
            .unwrap()
            .contains("hi")
    );
    assert!(
        std::fs::read_to_string(d.path().join("f.txt"))
            .unwrap()
            .contains("edited by ratatoskr-mock")
    );
}

#[test]
fn ask_permission_says_the_option_it_got() {
    let d = dir();
    let mut a = Acp::start(&["--as", "codex"]);
    a.init();
    let sid = a.new_session(d.path().to_str().unwrap(), json!({}));
    a.allow = "reject_once";
    a.prompt(&sid, "ask:permission edit");
    let req = a
        .seen
        .iter()
        .find(|m| m["method"] == "session/request_permission")
        .unwrap();
    assert_eq!(req["params"]["toolCall"]["kind"], "edit");
    assert_eq!(req["params"]["options"].as_array().unwrap().len(), 3);
    assert!(a.said().contains("permission: reject_once"));
    a.allow = "cancelled";
    a.prompt(&sid, "ask:permission read");
    assert!(a.said().contains("permission: cancelled"));
}

/// An MCP server that answers `tools/call` with the tool's name and arguments echoed.
const MCP: &str = r#"while read l; do case "$l" in *tools/call*) echo '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"ok:seen"}]}}';; *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{}}';; esac; done"#;

#[test]
fn call_and_decide_go_through_the_mcp_bridge() {
    let d = dir();
    let mut a = Acp::start(&["--as", "gemini"]);
    a.init();
    let sid = a.new_session(
        d.path().to_str().unwrap(),
        json!({"mcpServers": [{"name": "hub", "command": "sh", "args": ["-c", MCP], "env": []}]}),
    );
    a.prompt(&sid, "call:read_decisions {\"since\":0}\ndecide use sqlite");
    let said = a.said();
    assert_eq!(said.matches("call: ok:seen").count(), 2, "{said}");
    // with no server configured it says so
    let sid2 = a.new_session(d.path().to_str().unwrap(), json!({}));
    a.prompt(&sid2, "call:x");
    assert!(a.said().contains("call: no mcpServers"));
}

#[test]
fn commit_commits_in_the_cwd() {
    let d = dir();
    let p = d.path();
    let git = |args: &[&str]| {
        assert!(
            Command::new("git")
                .args(args)
                .current_dir(p)
                .output()
                .unwrap()
                .status
                .success()
        );
    };
    git(&["init", "-q"]);
    std::fs::write(p.join("a.txt"), "x").unwrap();
    let mut a = Acp::start(&["--as", "claude"]);
    a.init();
    let sid = a.new_session(p.to_str().unwrap(), json!({}));
    a.prompt(&sid, "commit agent work");
    let out = Command::new("git")
        .args(["log", "--format=%s"])
        .current_dir(p)
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "agent work");
}

#[test]
fn sleep_loop_asks_for_the_sleep_and_a_refusal_ends_it() {
    let d = dir();
    let mut a = Acp::start(&["--as", "codex"]);
    a.init();
    let sid = a.new_session(d.path().to_str().unwrap(), json!({}));
    a.allow = "reject_once";
    a.prompt(&sid, "sleep-loop");
    let req = a
        .seen
        .iter()
        .find(|m| m["method"] == "session/request_permission")
        .unwrap();
    assert_eq!(req["params"]["toolCall"]["kind"], "execute");
    assert!(
        req["params"]["toolCall"]["title"]
            .as_str()
            .unwrap()
            .starts_with("sleep 30; pgrep")
    );
    assert!(a.said().contains("sleep-loop: reject_once"));
}

#[test]
fn silent_runs_until_cancelled() {
    let d = dir();
    let mut a = Acp::start(&["--as", "claude"]);
    a.init();
    let sid = a.new_session(d.path().to_str().unwrap(), json!({}));
    a.next += 1;
    let id = a.next;
    a.write(
        json!({"jsonrpc": "2.0", "id": id, "method": "session/prompt",
        "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "silent 30"}]}}),
    );
    std::thread::sleep(Duration::from_millis(300));
    a.write(json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": sid}}));
    loop {
        let m =
            a.rx.recv_timeout(Duration::from_secs(10))
                .expect("the cancelled turn ends");
        if m["id"] == id {
            assert_eq!(m["result"]["stopReason"], "cancelled");
            break;
        }
    }
}

#[test]
fn crash_exits_three() {
    let d = dir();
    let mut a = Acp::start(&["--as", "claude"]);
    a.init();
    let sid = a.new_session(d.path().to_str().unwrap(), json!({}));
    a.next += 1;
    let id = a.next;
    a.write(
        json!({"jsonrpc": "2.0", "id": id, "method": "session/prompt",
        "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "crash"}]}}),
    );
    let status = a.child.wait().unwrap();
    assert_eq!(status.code(), Some(3));
}

#[test]
fn a_script_gives_each_turn_its_line() {
    let d = dir();
    let script = d.path().join("script");
    std::fs::write(&script, "tool:exec echo first\n\ntool:exec echo second\n").unwrap();
    let mut a = Acp::start(&["--as", "gemini", "--script", script.to_str().unwrap()]);
    a.init();
    let sid = a.new_session(d.path().to_str().unwrap(), json!({}));
    a.prompt(&sid, "ignored");
    a.prompt(&sid, "ignored");
    let done = a.updates("tool_call_update");
    assert!(
        done[0]["content"][0]["content"]["text"]
            .as_str()
            .unwrap()
            .contains("first")
    );
    assert!(
        done[1]["content"][0]["content"]["text"]
            .as_str()
            .unwrap()
            .contains("second")
    );
}

#[test]
fn llm_gets_one_request_per_turn() {
    let d = dir();
    let llm_log = d.path().join("llm.jsonl");
    let script = d.path().join("llm.json");
    std::fs::write(&script, r#"[{"path": "/", "status": 200, "body": "{}"}]"#).unwrap();
    let mut llm = Command::new(MOCK)
        .args([
            "llm",
            "--script",
            script.to_str().unwrap(),
            "--log",
            llm_log.to_str().unwrap(),
        ])
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(llm.stdout.as_mut().unwrap())
        .read_line(&mut line)
        .unwrap();
    let port = line
        .trim()
        .strip_prefix("MOCK-LLM-PORT ")
        .unwrap()
        .to_string();
    let url = format!("http://127.0.0.1:{port}/v1/messages");
    let mut a = Acp::start(&["--as", "claude", "--llm", &url]);
    a.init();
    let sid = a.new_session(d.path().to_str().unwrap(), json!({}));
    a.prompt(&sid, "one");
    a.prompt(&sid, "two");
    let n = log_lines(&llm_log)
        .iter()
        .filter(|v| v.get("request").is_some())
        .count();
    let _ = llm.kill();
    let _ = llm.wait();
    assert_eq!(n, 2);
}
