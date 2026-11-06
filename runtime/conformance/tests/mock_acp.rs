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
        Acp::start_env(extra, &[])
    }

    /// As `start`, with ENV set and the lock variables it does not set unset.
    fn start_env(extra: &[&str], env: &[(&str, &str)]) -> Acp {
        let mut cmd = Command::new(MOCK);
        for v in ["CODEX_CONFIG", "INITIAL_AGENT_MODE"] {
            cmd.env_remove(v);
        }
        let mut child = cmd
            .envs(env.iter().copied())
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

// [C] handshake: DeepSeek Harness 0.2.2's `--patch` takes a top-level YAML array of loader patches and refuses
// anything else at boot (`packages/boot/app-boot/src/index.ts:536-545`, `:571-589`); the patches to rows its base
// bundle has (`sandbox-policy`, `approval`: `packages/bundle/base/cordis.patch.yml:243-262`) apply, and the
// inserted ask plugin's `kinds` are what it asks about.
#[test]
fn dsh_boots_only_on_a_patch_list() {
    let d = dir();
    let map = d.path().join("map.yml");
    std::fs::write(
        &map,
        "sandbox:\n  mode: danger-full-access\napproval:\n  policy: ask\nplugins:\n  drgnx-ask:\n    kinds: [execute]\n",
    )
    .unwrap();
    let out = Command::new(MOCK)
        .args(["acp", "--as", "dsh", "--patch", map.to_str().unwrap()])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(1), "{err}");
    assert!(err.contains("must be a top-level YAML array"), "{err}");
    let list = d.path().join("list.yml");
    std::fs::write(
        &list,
        "# x\n- id: sandbox-policy\n  config:\n    mode: danger-full-access\n\n- id: approval\n  config:\n    policy: ask\n\n\
         - insert:\n    - id: drgnx-ask\n      name: '@deepseek-ai/dsh-acp-drgnx-ask'\n      config:\n        kinds: [execute, edit]\n",
    )
    .unwrap();
    let log = d.path().join("log");
    let mut a = Acp::start(&[
        "--as",
        "dsh",
        "--log",
        log.to_str().unwrap(),
        "--patch",
        list.to_str().unwrap(),
    ]);
    a.init();
    a.new_session(d.path().to_str().unwrap(), json!({}));
    let l = log_lines(&log);
    let note = l.iter().find_map(|v| v.get("dsh")).unwrap();
    assert_eq!(
        note,
        &json!({"policy": "ask", "sandbox": "danger-full-access", "kinds": ["execute", "edit"]})
    );
}

// [C] handshake: Gemini CLI 0.67 loads an `--admin-policy` file whose every rule has a toolName, a known decision and
// a priority in 0..=999 (`packages/core/src/policy/toml-loader.ts:39-70`), and drops a file that has not, running on
// without it (`:376-389`); the Gemini personality logs which.
#[test]
fn gemini_loads_or_drops_its_admin_policy() {
    let d = dir();
    let good = "[[rule]]\ntoolName = \"read_file\"\ndecision = \"ask_user\"\npriority = 999\n\n\
                [[rule]]\nmcpName = \"*\"\ntoolName = \"*\"\ndecision = \"ask_user\"\npriority = 999\n";
    let bad = "[[rule]]\ntoolName = \"read_file\"\ndecision = \"ask_user\"\npriority = 999\n\n\
               [[rule]]\nmcpName = \"*\"\ndecision = \"ask_user\"\npriority = 999\n";
    for (name, text, want) in [("good", good, "loaded"), ("bad", bad, "dropped")] {
        let file = d.path().join(format!("{name}.toml"));
        let log = d.path().join(format!("{name}.log"));
        std::fs::write(&file, text).unwrap();
        let mut a = Acp::start(&[
            "--as",
            "gemini",
            "--log",
            log.to_str().unwrap(),
            "--admin-policy",
            file.to_str().unwrap(),
        ]);
        a.init();
        let sid = a.new_session(d.path().to_str().unwrap(), json!({}));
        assert!(!sid.is_empty(), "{name}: the session starts either way");
        let l = log_lines(&log);
        let note = l.iter().find_map(|v| v.get("gemini")).unwrap();
        let got = note["admin_policy"].as_str().unwrap_or_default();
        assert!(got.starts_with(want), "{name}: {note}");
        if want == "dropped" {
            assert!(got.contains("rule 2") && got.contains("toolName"), "{got}");
        }
    }
}

// [C] handshake: drgnx's Gemini fork (`--panel-policy`) answers an `initialize` that offers `_drgnx/panel` version 1
// with `agentCapabilities._meta["_drgnx/panel"].adminPolicy {loaded, rules}`, the rules Gemini holds from the
// `--admin-policy` files by their names (`packages/cli/src/acp/acpRpcDispatcher.ts:94-123`, `acpDrgnxPanel.ts:52-106`):
// none when the file was dropped; `--panel-policy short` reports one rule fewer.  The stock adapter (no flag) and a
// client that offers nothing get no report.
#[test]
fn gemini_fork_reports_its_admin_policy() {
    let d = dir();
    let good = d.path().join("good.toml");
    std::fs::write(
        &good,
        "[[rule]]\ntoolName = \"read_file\"\ndecision = \"ask_user\"\npriority = 999\n\n\
         [[rule]]\nmcpName = \"*\"\ntoolName = \"*\"\ndecision = \"ask_user\"\npriority = 999\n",
    )
    .unwrap();
    let bad = d.path().join("bad.toml");
    std::fs::write(
        &bad,
        "[[rule]]\nmcpName = \"*\"\ndecision = \"ask_user\"\npriority = 999\n",
    )
    .unwrap();
    let offer = json!({"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": false,
        "writeTextFile": false}, "terminal": false, "_meta": {"_drgnx/panel": {"version": 1}}}});
    let report = |extra: &[&str], file: &std::path::Path, offered: bool| {
        let mut args = vec!["--as", "gemini", "--admin-policy", file.to_str().unwrap()];
        args.extend_from_slice(extra);
        let mut a = Acp::start(&args);
        let r = if offered {
            a.call("initialize", offer.clone())
        } else {
            a.init()
        };
        r["result"]["agentCapabilities"]["_meta"]["_drgnx/panel"]["adminPolicy"].clone()
    };
    assert_eq!(
        report(&["--panel-policy", "engine"], &good, true),
        json!({"loaded": true, "rules": 2})
    );
    assert_eq!(
        report(&["--panel-policy", "engine"], &bad, true),
        json!({"loaded": false, "rules": 0})
    );
    assert_eq!(
        report(&["--panel-policy", "short"], &good, true),
        json!({"loaded": true, "rules": 1})
    );
    assert_eq!(
        report(&["--panel-policy", "engine"], &good, false),
        Value::Null
    );
    assert_eq!(report(&[], &good, true), Value::Null);
}

// [C] handshake: Kimi Code's ACP server reports its four modes and `default` when a session opens
// (`packages/acp-server/src/modes.ts:22-46`), refuses a mode id it does not know (`:52-54`), and tells the client a
// switch with `current_mode_update` (`session.ts:1138-1156`); the personality's `--start-mode MODE` opens in MODE (a
// Kimi the lock must refuse), and the word `mode MODE` switches during a turn.
#[test]
fn kimi_reports_its_modes_and_switches() {
    let d = dir();
    let opened = |extra: &[&str]| {
        let mut args = vec!["--as", "kimi"];
        args.extend_from_slice(extra);
        let mut a = Acp::start(&args);
        a.init();
        let r = a.call("session/new", json!({"cwd": d.path(), "mcpServers": []}));
        (a, r)
    };
    let (mut a, r) = opened(&[]);
    let modes = &r["result"]["modes"];
    assert_eq!(modes["currentModeId"], "default", "{r}");
    let ids: Vec<&str> = modes["availableModes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["default", "plan", "auto", "yolo"]);
    let sid = r["result"]["sessionId"].as_str().unwrap().to_string();
    let bad = a.call(
        "session/set_mode",
        json!({"sessionId": sid, "modeId": "read-only"}),
    );
    assert_eq!(bad["error"]["code"], -32602, "{bad}");
    a.prompt(&sid, "mode plan");
    let switched = a.updates("current_mode_update");
    assert_eq!(
        switched.last().map(|u| u["currentModeId"].clone()),
        Some(json!("plan")),
        "{switched:?}"
    );
    let (_, r) = opened(&["--start-mode", "plan"]);
    assert_eq!(r["result"]["modes"]["currentModeId"], "plan", "{r}");
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
fn codex_logs_its_lock_and_sends_usage_and_a_window() {
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
    // what codex-acp 2.x reads is its environment (unset here); the argv overrides it ignores are logged beside it
    let o = l.iter().find_map(|v| v.get("codex_config")).unwrap();
    assert_eq!(
        o["argv_overrides"],
        json!(["approval_policy=never", "model=x"])
    );
    assert!(o["config"].is_null() && o["mode"].is_null(), "{o}");
}

// [C] handshake: codex-acp 2.5.0 answers `session/new` with the session's mode and knows four ids
// (`src/AgentMode.ts:135-142`); an unset or unknown `INITIAL_AGENT_MODE` is its default, `agent` (`:95`,
// `:144-151`), and `session/set_mode` to an unknown id is invalid params (`src/CodexAcpServer.ts:2752-2756`).
#[test]
fn codex_reports_its_mode_as_codex_acp_picks_it() {
    let d = dir();
    for (asked, got) in [
        (None, "agent"),
        (Some(""), "agent"),
        (Some("permission-profile:drgnx"), "agent"),
        (Some("read-only"), "read-only"),
        (Some("agent-full-access"), "agent-full-access"),
    ] {
        let env: Vec<(&str, &str)> = asked
            .map(|m| ("INITIAL_AGENT_MODE", m))
            .into_iter()
            .collect();
        let mut a = Acp::start_env(&["--as", "codex"], &env);
        a.init();
        let r = a.call("session/new", json!({"cwd": d.path(), "mcpServers": []}));
        let modes = &r["result"]["modes"];
        assert_eq!(modes["currentModeId"], got, "{asked:?}: {r}");
        let ids: Vec<&str> = modes["availableModes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["id"].as_str().unwrap())
            .collect();
        assert_eq!(
            ids,
            ["read-only", "workspace-write", "agent", "agent-full-access"]
        );
        let sid = r["result"]["sessionId"].clone();
        let bad = a.call(
            "session/set_mode",
            json!({"sessionId": sid, "modeId": "permission-profile:drgnx"}),
        );
        assert_eq!(bad["error"]["code"], -32602, "{bad}");
        let ok = a.call(
            "session/set_mode",
            json!({"sessionId": sid, "modeId": "read-only"}),
        );
        assert!(ok["result"].is_object(), "{ok}");
    }
}

// [C] handshake: Codex 0.165 refuses a config whose `approval_policy` is `untrusted`
// (`core/src/config/mod.rs:3898-3903`), so no session starts on it.
#[test]
fn codex_refuses_the_retired_untrusted_policy() {
    let d = dir();
    let mut a = Acp::start_env(
        &["--as", "codex"],
        &[("CODEX_CONFIG", r#"{"approval_policy":"untrusted"}"#)],
    );
    a.init();
    let r = a.call("session/new", json!({"cwd": d.path(), "mcpServers": []}));
    assert!(
        r["error"]["message"]
            .as_str()
            .is_some_and(|m| m.contains("no longer supported")),
        "{r}"
    );
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
    // No wait before the cancel: the mock takes stdin in order, so the cancel is read after the prompt, by the `silent`
    // turn it is in (it watches for it while it sleeps), whenever it arrives.
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
