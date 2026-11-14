//! `ratatoskr-mock acp --replay … --strict`: recorded lines left unused when the hub's end closes are a miss (exit 3,
//! a misses line); without it the replay ends clean.  Pattern C (handshake): the test is the hub, and closes the pipe
//! only after both answers came back.

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

const MOCK: &str = env!("CARGO_BIN_EXE_ratatoskr-mock");

/// A recording of one connection whose last exchange (a prompt and its answer) the replay below never sends.
fn recording(dir: &std::path::Path) {
    std::fs::create_dir_all(dir.join("acp")).unwrap();
    let manifest = json!({"format": "drgnx-recording", "version": 1, "status": "complete",
        "provenance": "mock", "roots": {}, "connections": [{"n": 1}]});
    std::fs::write(dir.join("manifest.json"), manifest.to_string()).unwrap();
    let lines = [
        json!({"seq": 1, "t_ms": 0, "dir": "in", "msg": {"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": 1}}}),
        json!({"seq": 2, "t_ms": 1, "dir": "out", "msg": {"jsonrpc": "2.0", "id": 1,
            "result": {"protocolVersion": 1, "agentInfo": {"name": "mock", "version": "1"}}}}),
        json!({"seq": 3, "t_ms": 2, "dir": "in", "msg": {"jsonrpc": "2.0", "id": 2, "method": "session/new",
            "params": {"cwd": "/work/t", "mcpServers": []}}}),
        json!({"seq": 4, "t_ms": 3, "dir": "out", "msg": {"jsonrpc": "2.0", "id": 2,
            "result": {"sessionId": "s1"}}}),
        json!({"seq": 5, "t_ms": 4, "dir": "in", "msg": {"jsonrpc": "2.0", "id": 3, "method": "session/prompt",
            "params": {"sessionId": "s1", "prompt": [{"type": "text", "text": "never sent"}]}}}),
        json!({"seq": 6, "t_ms": 5, "dir": "out", "msg": {"jsonrpc": "2.0", "id": 3,
            "result": {"stopReason": "end_turn"}}}),
    ];
    let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
    std::fs::write(dir.join("acp/1.jsonl"), text).unwrap();
}

/// Replay DIR, send the first two requests, wait for their answers, close stdin: the exit code, and the misses file.
fn replay(strict: bool) -> (Option<i32>, String) {
    replay_ended(strict, false)
}

/// As [`replay`], but with TERM the end is a SIGTERM with stdin still open, as the hub ends a session's process group
/// (`draugr::kill_group`).
fn replay_ended(strict: bool, term: bool) -> (Option<i32>, String) {
    let root = tempfile::tempdir().unwrap();
    let run = root.path().join("run");
    recording(&run);
    let misses = root.path().join("scratch/misses.jsonl");
    let mut cmd = Command::new(MOCK);
    cmd.args(["acp", "--replay"])
        .arg(&run)
        .args([
            "--as", "claude", "--speed", "0", "--roots", "{}", "--misses",
        ])
        .arg(&misses);
    if strict {
        cmd.arg("--strict");
    }
    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());
    let sends = [
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1}}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": "/work/t", "mcpServers": []}}),
    ];
    for m in sends {
        writeln!(stdin, "{m}").unwrap();
        let mut answer = String::new();
        out.read_line(&mut answer).unwrap();
        let v: Value = serde_json::from_str(&answer).unwrap();
        assert!(v.get("result").is_some(), "{v}");
    }
    if term {
        // SAFETY: a signal to the child this test spawned and has not waited on yet
        assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    } else {
        drop(stdin);
    }
    let code = child.wait().unwrap().code();
    (code, std::fs::read_to_string(&misses).unwrap_or_default())
}

/// A recording made under the root `/rec/base` (an update names a path in it, as a recorded token and as raw text),
/// replayed under `/live/base`: the update arrives with the live root.
#[test]
fn a_replay_under_another_root_sends_its_own_paths() {
    let root = tempfile::tempdir().unwrap();
    let run = root.path().join("run");
    std::fs::create_dir_all(run.join("acp")).unwrap();
    let manifest = json!({"format": "drgnx-recording", "version": 1, "status": "complete",
        "provenance": "mock", "roots": {"$HOME": "/rec/base"}, "connections": [{"n": 1}]});
    std::fs::write(run.join("manifest.json"), manifest.to_string()).unwrap();
    let lines = [
        json!({"seq": 1, "t_ms": 0, "dir": "in", "msg": {"jsonrpc": "2.0", "id": 1, "method": "session/new",
            "params": {"cwd": "/rec/base/work", "mcpServers": []}}}),
        json!({"seq": 2, "t_ms": 1, "dir": "out", "msg": {"jsonrpc": "2.0", "id": 1,
            "result": {"sessionId": "s1"}}}),
        json!({"seq": 3, "t_ms": 2, "dir": "out", "msg": {"jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "s1", "raw": "/rec/base/work/a.txt", "token": "$HOME/work/b.txt"}}}),
    ];
    let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
    std::fs::write(run.join("acp/1.jsonl"), text).unwrap();
    let mut child = Command::new(MOCK)
        .args(["acp", "--replay"])
        .arg(&run)
        .args([
            "--as",
            "claude",
            "--speed",
            "0",
            "--roots",
            r#"{"$HOME":"/live/base"}"#,
        ])
        .arg("--misses")
        .arg(root.path().join("scratch/misses.jsonl"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());
    let open = json!({"jsonrpc": "2.0", "id": 1, "method": "session/new",
        "params": {"cwd": "/live/base/work", "mcpServers": []}});
    writeln!(stdin, "{open}").unwrap();
    let mut seen = String::new();
    for _ in 0..2 {
        out.read_line(&mut seen).unwrap();
    }
    drop(stdin);
    child.wait().unwrap();
    assert!(seen.contains("/live/base/work/a.txt"), "{seen}");
    assert!(seen.contains("/live/base/work/b.txt"), "{seen}");
    assert!(
        !seen.contains("/rec/base") && !seen.contains("$HOME"),
        "{seen}"
    );
}

#[test]
fn strict_fails_a_replay_that_left_recorded_lines_unused() {
    let (code, misses) = replay(true);
    assert_eq!(code, Some(3), "{misses}");
    assert!(misses.contains("never used"), "{misses}");
}

#[test]
fn without_strict_the_same_replay_ends_clean() {
    let (code, misses) = replay(false);
    assert_eq!(code, Some(0), "{misses}");
    assert_eq!(misses, "");
}

/// The hub ends a session with a SIGTERM to its process group, not by closing its stdin: the replay ends as it would
/// at stdin's close, so `--strict` still finds the unused lines (exit 3), and without it the end is clean.
#[test]
fn a_sigterm_ends_the_replay_as_stdin_closing_does() {
    let (code, misses) = replay_ended(true, true);
    assert_eq!(code, Some(3), "{misses}");
    assert!(misses.contains("never used"), "{misses}");
    let (code, misses) = replay_ended(false, true);
    assert_eq!(code, Some(0), "{misses}");
    assert_eq!(misses, "");
}
