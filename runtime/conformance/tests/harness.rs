//! The harness against a scripted hub: a tiny hub in this test binary (re-run as `scripted_hub`, started through a
//! wrapper script) that answers `ping` and, with RTSK_SCRIPTED_V1=1, speaks the v1 challenge and `hello`.

use hmac::{Hmac, KeyInit, Mac};
use runstav::paths;
use serde_json::{Value, json};
use sha2::Sha256;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Command;

const CONFORMANCE: &str = env!("CARGO_BIN_EXE_domr");
const HUB_NONCE: &str = "00112233445566778899aabbccddeeff";
const CAP: &str = "abababababababababababababababababababababababababababababababab";

fn hmac_hex(message: &str) -> String {
    let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(CAP.as_bytes()).unwrap();
    mac.update(message.as_bytes());
    mac.finalize()
        .into_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Not a test: with RTSK_SCRIPTED_HUB set (by the wrapper script) this process is the scripted hub.
#[test]
fn scripted_hub() {
    if std::env::var_os("RTSK_SCRIPTED_HUB").is_none() {
        return;
    }
    let v1 = std::env::var("RTSK_SCRIPTED_V1").is_ok_and(|v| v == "1");
    let socket = paths::socket_path(&paths::Env::process());
    let dir = socket.parent().unwrap();
    std::fs::create_dir_all(dir).unwrap();
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let _ = std::fs::remove_file(&socket);
    if v1 {
        std::fs::write(socket.with_extension("cap"), CAP).unwrap();
    }
    let listener = UnixListener::bind(&socket).unwrap();
    for stream in listener.incoming().flatten() {
        std::thread::spawn(move || serve(stream, v1));
    }
}

fn serve(stream: UnixStream, v1: bool) {
    let mut out = stream.try_clone().unwrap();
    let mut send = move |v: Value| {
        let _ = writeln!(out, "{v}");
    };
    if v1 {
        send(json!({"event": "challenge", "data": {"nonce": HUB_NONCE}}));
    }
    let (mut first, mut proven) = (true, false);
    for line in BufReader::new(stream).lines().map_while(Result::ok) {
        let Ok(req) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let id = req["id"].clone();
        match req["method"].as_str() {
            Some("ping") => send(json!({"id": id, "result": {"pid": std::process::id()}})),
            Some("hello") if v1 => {
                let nonce = req["params"]["nonce"].as_str().unwrap_or("");
                let want = hmac_hex(&format!("drgnx-hub client {HUB_NONCE} {nonce}"));
                if first && req["params"]["proof"] == json!(want) {
                    proven = true;
                    let proof = hmac_hex(&format!("drgnx-hub hub {nonce} {HUB_NONCE}"));
                    send(
                        json!({"id": id, "result": {"proto": 1, "class": "user", "proof": proof}}),
                    );
                } else {
                    send(
                        json!({"id": id, "error": {"code": "not-allowed", "message": "wrong proof, or hello was not the first line"}}),
                    );
                }
            }
            // for bad_params: `t/need` wants a string `a` and says where it is wrong; `t/broken` never says where
            Some("t/need") => match req["params"].get("a") {
                Some(Value::String(_)) => send(json!({"id": id, "result": true})),
                _ => send(
                    json!({"id": id, "error": {"code": "invalid-params", "message": "a is a string", "path": "a"}}),
                ),
            },
            Some("t/broken") => {
                send(json!({"id": id, "error": {"code": "invalid-params", "message": "somewhere"}}))
            }
            // for class_matrix: `t/user` and `t/end` only after a valid hello; `t/end` then ends the hub
            Some("t/user" | "t/end") if !proven => send(
                json!({"id": id, "error": {"code": "not-allowed", "message": "t/user needs the user's capability"}}),
            ),
            Some("t/user") => send(json!({"id": id, "result": true})),
            Some("t/end") => {
                send(json!({"id": id, "result": true}));
                std::process::exit(0);
            }
            _ => send(json!({"id": id, "error": {"code": "no-method", "message": "scripted hub"}})),
        }
        first = false;
    }
}

fn wrapper(dir: &Path) -> PathBuf {
    let path = dir.join("scripted-hub.sh");
    let exe = std::env::current_exe().unwrap();
    std::fs::write(
        &path,
        format!(
            "#!/bin/sh\nRTSK_SCRIPTED_HUB=1 exec '{}' --exact scripted_hub --nocapture\n",
            exe.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn run(target: &str, hub: &Path, scenarios: &Path) -> (String, i32) {
    let out = Command::new(CONFORMANCE)
        .args(["--target", target, "--hub-bin"])
        .arg(hub)
        .arg("--scenarios")
        .arg(scenarios)
        .output()
        .unwrap();
    (
        String::from_utf8_lossy(&out.stdout).into_owned(),
        out.status.code().unwrap_or(-1),
    )
}

fn rows(dir: &Path, files: &[(&str, &str)]) {
    for (name, text) in files {
        let path = dir.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
}

const PING_ROW: &str = r#"{"scenario": "ok/ping", "requires": ["v0"], "doc": "a hub answers ping with its pid"}
{"do": "start", "hub": "h"}
{"do": "connect", "conn": "c", "hub": "h"}
{"do": "send", "conn": "c", "json": {"id": 1, "method": "ping"}}
{"do": "expect", "conn": "c", "json": {"id": 1, "result": {"pid": "$PID(h)"}}}
"#;

#[test]
fn a_scenario_against_a_scripted_hub() {
    let dir = tempfile::tempdir().unwrap();
    let hub = wrapper(dir.path());
    let good = dir.path().join("good");
    rows(&good, &[("ok/ping.jsonl", PING_ROW)]);
    let (out, code) = run("lisp", &hub, &good);
    assert_eq!(code, 0, "{out}");
    assert!(out.contains("PASS ok/ping"), "{out}");
    assert!(out.contains("1 passed, 0 skipped, 0 failed"), "{out}");

    // the committed rows for the harness itself pass against the same hub
    let committed = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/conformance/self");
    let (out, code) = run("lisp", &hub, &committed);
    assert_eq!(code, 0, "{out}");
    assert!(out.contains("PASS self/ping"), "{out}");

    // a wrong pattern: one FAIL naming the step and its verb, exit 1
    let bad = dir.path().join("bad");
    rows(
        &bad,
        &[(
            "bad/wrong.jsonl",
            &PING_ROW
                .replace("ok/ping", "bad/wrong")
                .replace("\"$PID(h)\"", "\"$string\""),
        )],
    );
    let (out, code) = run("lisp", &hub, &bad);
    assert_eq!(code, 1, "{out}");
    assert_eq!(out.matches("FAIL ").count(), 1, "{out}");
    assert!(out.contains("FAIL bad/wrong: step 4 (expect)"), "{out}");
    assert!(out.contains("0 passed, 0 skipped, 1 failed"), "{out}");
}

const FILES_ROW: &str = r#"{"scenario": "ok/files-and-eof", "requires": ["v0"], "doc": "file globs and contains; send with eof"}
{"do": "start", "hub": "h"}
{"do": "write_file", "path": "$ROOT/x/a-1.txt", "text": "hello $PID(h)"}
{"do": "file", "path": "$ROOT/x/a-*.txt", "contains": "WANT"}
{"do": "file", "path": "$ROOT/x/b-*.txt", "exists": false}
{"do": "connect", "conn": "c", "hub": "h"}
{"do": "send", "conn": "c", "raw": "{\"id\":1", "no_newline": true, "eof": true}
{"do": "expect_closed", "conn": "c"}
"#;

#[test]
fn file_globs_contains_and_a_send_with_eof() {
    let dir = tempfile::tempdir().unwrap();
    let hub = wrapper(dir.path());
    let good = dir.path().join("good");
    rows(
        &good,
        &[(
            "ok/files-and-eof.jsonl",
            &FILES_ROW.replace("WANT", "$PID(h)"),
        )],
    );
    let (out, code) = run("lisp", &hub, &good);
    assert_eq!(code, 0, "{out}");
    assert!(out.contains("PASS ok/files-and-eof"), "{out}");

    // text that is not there fails the step, after its wait
    let bad = dir.path().join("bad");
    let row = FILES_ROW
        .replace("\"WANT\"", "\"nowhere\", \"within_ms\": 100")
        .replace("ok/files-and-eof", "bad/files");
    rows(&bad, &[("bad/files.jsonl", &row)]);
    let (out, code) = run("lisp", &hub, &bad);
    assert_eq!(code, 1, "{out}");
    assert!(out.contains("FAIL bad/files: step 3 (file)"), "{out}");
}

const TASK15_ROW: &str = r#"{"scenario": "ok/task15-verbs", "requires": ["v0"], "doc": "$repeat, pause, file lacks, sqlite query, $SCENARIOS"}
{"do": "start", "hub": "h"}
{"do": "write_file", "path": "$ROOT/a.txt", "text": "abc $SCENARIOS"}
{"do": "file", "path": "$ROOT/a.txt", "lacks": "LACKS", "contains": "abc /"}
{"do": "sqlite", "path": "$ROOT/t.db", "sql": ["create table t (a, b, c)", "insert into t values (1, 'x', null)"], "query": "select a, b, c from t", "expect": [[1, "x", null]]}
{"do": "connect", "conn": "c", "hub": "h"}
{"do": "pause", "conn": "c"}
{"do": "send", "conn": "c", "json": {"id": 1, "method": "t/need", "params": {"a": {"$repeat": "xy", "times": 3}}}}
{"do": "expect", "conn": "c", "json": {"id": 1, "result": true}}
"#;

#[test]
fn repeat_pause_lacks_and_sqlite_queries() {
    let dir = tempfile::tempdir().unwrap();
    let hub = wrapper(dir.path());
    let good = dir.path().join("good");
    rows(
        &good,
        &[("ok/task15-verbs.jsonl", &TASK15_ROW.replace("LACKS", "zzz"))],
    );
    let (out, code) = run("lisp", &hub, &good);
    assert_eq!(code, 0, "{out}");
    assert!(out.contains("PASS ok/task15-verbs"), "{out}");

    // text the file has fails `lacks`; a row the query does not match fails the step
    let bad = dir.path().join("bad");
    rows(
        &bad,
        &[
            (
                "bad/lacks.jsonl",
                &TASK15_ROW
                    .replace("LACKS", "abc")
                    .replace("ok/task15-verbs", "bad/lacks"),
            ),
            (
                "bad/query.jsonl",
                &TASK15_ROW
                    .replace("LACKS", "zzz")
                    .replace("[[1, \"x\", null]]", "[[2, \"x\", null]]")
                    .replace("ok/task15-verbs", "bad/query"),
            ),
        ],
    );
    let (out, code) = run("lisp", &hub, &bad);
    assert_eq!(code, 1, "{out}");
    assert!(out.contains("FAIL bad/lacks: step 3 (file)"), "{out}");
    assert!(out.contains("FAIL bad/query: step 4 (sqlite)"), "{out}");
}

const USER_ROW: &str = r#"{"scenario": "hello/user-connect", "requires": ["REQ"], "doc": "a user connect, then ping"}
{"do": "start", "hub": "h", "env": {"RTSK_SCRIPTED_V1": "V1"}}
{"do": "connect", "conn": "c", "hub": "h", "as": "user"}
{"do": "send", "conn": "c", "json": {"id": 5, "method": "ping"}}
{"do": "expect_next", "conn": "c", "json": {"id": 5, "result": {"pid": "$number"}}}
"#;

#[test]
fn a_user_connect_on_a_v1_target_does_the_hello() {
    let dir = tempfile::tempdir().unwrap();
    let hub = wrapper(dir.path());
    // v1: the hub challenges, the harness answers with a proof the scripted hub checks on its own; the first line the
    // test sees after the connect is the ping answer, not the challenge
    let v1 = dir.path().join("v1");
    rows(
        &v1,
        &[(
            "hello/user-connect.jsonl",
            &USER_ROW.replace("REQ", "v1").replace("\"V1\"", "\"1\""),
        )],
    );
    let (out, code) = run("ratatoskr", &hub, &v1);
    assert_eq!(code, 0, "{out}");
    assert!(out.contains("PASS hello/user-connect"), "{out}");

    // lisp: the same connect sends no hello (a hub that does not know it would answer with an error first)
    let v0 = dir.path().join("v0");
    rows(
        &v0,
        &[(
            "hello/user-connect.jsonl",
            &USER_ROW.replace("REQ", "v0").replace("\"V1\"", "\"\""),
        )],
    );
    let (out, code) = run("lisp", &hub, &v0);
    assert_eq!(code, 0, "{out}");
    assert!(out.contains("PASS hello/user-connect"), "{out}");
}

const BAD_PARAMS_ROW: &str = r#"{"scenario": "params/bad", "requires": ["v0"], "doc": "bad_params over a registry"}
{"do": "start", "hub": "h"}
{"do": "connect", "conn": "c", "hub": "h"}
{"do": "bad_params", "conn": "c", "registry": "REGISTRY"}
"#;

fn registry(dir: &Path, methods: Value) -> PathBuf {
    let path = dir.join("methods.json");
    std::fs::write(&path, json!({"proto": 1, "methods": methods}).to_string()).unwrap();
    path
}

#[test]
fn bad_params_sends_empty_and_a_wrong_type_to_every_method_with_required_params() {
    let dir = tempfile::tempdir().unwrap();
    let hub = wrapper(dir.path());
    let need = json!({"name": "t/need", "params": {"type": "object", "required": ["a"],
                      "properties": {"a": {"$ref": "#/$defs/A"}}, "$defs": {"A": {"type": "string"}}}});
    let none = json!({"name": "t/none", "params": {"type": "object"}});
    let good = registry(dir.path(), json!([need, none]));
    let rows_dir = dir.path().join("good");
    rows(
        &rows_dir,
        &[(
            "params/bad.jsonl",
            &BAD_PARAMS_ROW.replace("REGISTRY", good.to_str().unwrap()),
        )],
    );
    let (out, code) = run("lisp", &hub, &rows_dir);
    assert_eq!(code, 0, "{out}");
    assert!(out.contains("PASS params/bad"), "{out}");

    // a refusal without a path fails the row, naming the method
    let broken = json!({"name": "t/broken", "params": {"type": "object", "required": ["b"],
                        "properties": {"b": {"type": "array"}}}});
    let bad = dir.path().join("bad");
    std::fs::create_dir_all(&bad).unwrap();
    let reg = registry(&bad, json!([need, broken]));
    rows(
        &bad,
        &[(
            "params/bad.jsonl",
            &BAD_PARAMS_ROW.replace("REGISTRY", reg.to_str().unwrap()),
        )],
    );
    let (out, code) = run("lisp", &hub, &bad);
    assert_eq!(code, 1, "{out}");
    assert!(
        out.contains("FAIL params/bad: step 3 (bad_params)"),
        "{out}"
    );
    assert!(out.contains("t/broken {}"), "{out}");
    assert!(
        out.contains("t/broken {\"b\":true}"),
        "the wrong type for a list is true: {out}"
    );
    assert!(!out.contains("t/need"), "{out}");
}

const MATRIX_ROW: &str = r#"{"scenario": "class/m", "requires": ["v1"], "doc": "class_matrix over a table"}
{"do": "class_matrix", "table": "TABLE", "last": ["t/end"], "env": {"RTSK_SCRIPTED_V1": "1"}}
"#;

#[test]
fn class_matrix_calls_every_method_from_every_class_and_the_ending_ones_last() {
    let dir = tempfile::tempdir().unwrap();
    let hub = wrapper(dir.path());
    let table = |name: &str, t: Value| {
        let path = dir.path().join(name);
        std::fs::write(&path, t.to_string()).unwrap();
        path
    };
    // t/end ends the hub when a user calls it: sent last, in a hub of its own, or t/user after it would fail
    let good = table(
        "good.json",
        json!({"ping": ["user", "service"], "t/user": ["user"], "t/end": ["user"]}),
    );
    let rows_dir = dir.path().join("good");
    rows(
        &rows_dir,
        &[(
            "class/m.jsonl",
            &MATRIX_ROW.replace("TABLE", good.to_str().unwrap()),
        )],
    );
    let (out, code) = run("ratatoskr", &hub, &rows_dir);
    assert_eq!(code, 0, "{out}");
    assert!(out.contains("PASS class/m"), "{out}");

    // a table that allows more than the hub does, or less: each call that disagrees is named
    let bad = table(
        "bad.json",
        json!({"ping": ["user"], "t/user": ["user", "service"], "t/end": ["user"]}),
    );
    let rows_dir = dir.path().join("bad");
    rows(
        &rows_dir,
        &[(
            "class/m.jsonl",
            &MATRIX_ROW.replace("TABLE", bad.to_str().unwrap()),
        )],
    );
    let (out, code) = run("ratatoskr", &hub, &rows_dir);
    assert_eq!(code, 1, "{out}");
    assert!(out.contains("FAIL class/m: step 1 (class_matrix)"), "{out}");
    assert!(
        out.contains("t/user as service: allowed, but refused"),
        "{out}"
    );
    assert!(
        out.contains("ping as service: not allowed, but got"),
        "{out}"
    );
    assert!(!out.contains("t/end as"), "{out}");
}

const FAKE_BACKEND: &str = env!("CARGO_BIN_EXE_ratatoskr-fake-backend");

/// A scripted front: one connection, a challenge, a `hello` whose proof is checked, then `n` requests answered
/// `{"ok": true}`; what it saw goes down the channel as `(method, params)`.
fn scripted_front(
    socket: &Path,
    n: usize,
) -> std::sync::mpsc::Receiver<Result<(String, Value), String>> {
    let (tx, rx) = std::sync::mpsc::channel();
    let listener = UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut out = stream.try_clone().unwrap();
        let mut lines = BufReader::new(stream).lines();
        writeln!(
            out,
            "{}",
            json!({"event": "challenge", "data": {"nonce": HUB_NONCE}})
        )
        .unwrap();
        let hello: Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
        let nonce = hello["params"]["nonce"].as_str().unwrap_or("").to_string();
        let want = hmac_hex(&format!("drgnx-hub client {HUB_NONCE} {nonce}"));
        if hello["method"] != "hello" || hello["params"]["proof"] != json!(want) {
            let _ = tx.send(Err(format!("bad hello: {hello}")));
            return;
        }
        let proof = hmac_hex(&format!("drgnx-hub hub {nonce} {HUB_NONCE}"));
        writeln!(
            out,
            "{}",
            json!({"id": hello["id"], "result": {"proto": 1, "class": "user", "proof": proof}})
        )
        .unwrap();
        for _ in 0..n {
            let Some(Ok(line)) = lines.next() else { return };
            let req: Value = serde_json::from_str(&line).unwrap();
            writeln!(out, "{}", json!({"id": req["id"], "result": {"ok": true}})).unwrap();
            let _ = tx.send(Ok((
                req["method"].as_str().unwrap_or("").to_string(),
                req["params"].clone(),
            )));
        }
    });
    rx
}

#[test]
fn fake_backend_calls_the_front() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let (run, state) = (root.join("run"), root.join("state"));
    std::fs::create_dir_all(&run).unwrap();
    let vars = [
        ("HOME", root.join("home")),
        ("XDG_RUNTIME_DIR", run.clone()),
        ("XDG_DATA_HOME", root.join("data")),
        ("XDG_STATE_HOME", state.clone()),
    ];
    let var_strs: Vec<(&str, String)> = vars
        .iter()
        .map(|(k, v)| (*k, v.to_string_lossy().into_owned()))
        .collect();
    let env = paths::Env::new(
        &var_strs
            .iter()
            .map(|(k, v)| (*k, v.as_str()))
            .collect::<Vec<_>>(),
        unsafe { libc::geteuid() },
    );
    let front_socket = paths::socket_path(&env);
    std::fs::create_dir_all(front_socket.parent().unwrap()).unwrap();
    std::fs::write(paths::cap_path(&front_socket), CAP).unwrap();
    let seen = scripted_front(&front_socket, 2);

    let secret = "cd".repeat(32);
    let serve = root.join("serve.sock");
    let script = json!({
        "m/x": {"call_front": {"method": "t/front", "params": {"a": 1}}, "then": "$front"},
        "m/y": {"call_front": {"method": "t/front", "params": {}}, "then": {"result": "fixed"}},
    });
    let mut child = Command::new(FAKE_BACKEND)
        .env_clear()
        .envs(var_strs.iter().map(|(k, v)| (*k, v.as_str())))
        .env("DRGNX_HUB_SERVE_SOCKET", &serve)
        .env("DRGNX_HUB_SERVE_SECRET", &secret)
        .env("DRGNX_FAKE_BACKEND_SCRIPT", script.to_string())
        .spawn()
        .unwrap();

    let mut stream = None;
    for _ in 0..100 {
        if let Ok(s) = UnixStream::connect(&serve) {
            stream = Some(s);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    let mut out = stream.expect("the fake backend serves its socket");
    let mut lines = BufReader::new(out.try_clone().unwrap()).lines();
    writeln!(out, "{}", json!({"auth": secret})).unwrap();
    writeln!(out, "{}", json!({"id": 1, "method": "m/x"})).unwrap();
    let a: Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
    writeln!(out, "{}", json!({"id": 2, "method": "m/y"})).unwrap();
    let b: Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
    writeln!(
        out,
        "{}",
        json!({"id": 3, "method": "coord/notify", "params": {"k": 1}})
    )
    .unwrap();
    let log = state.join("drgnx/fake-backend.log");
    let mut text = String::new();
    for _ in 0..100 {
        text = std::fs::read_to_string(&log).unwrap_or_default();
        if text.contains("notification ") {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    let _ = child.kill();
    let _ = child.wait();

    // the front saw both calls, on one connection, after a valid proof
    let first = seen.recv().unwrap().unwrap();
    assert_eq!(first, ("t/front".to_string(), json!({"a": 1})));
    assert_eq!(seen.recv().unwrap().unwrap().0, "t/front");
    assert_eq!(
        a,
        json!({"id": 1, "result": {"ok": true}}),
        "$front passes the front's answer"
    );
    assert_eq!(b, json!({"id": 2, "result": "fixed"}));
    assert!(text.contains("front-answer {"), "{text}");
    assert!(
        text.contains(r#"notification {"method":"coord/notify","params":{"k":1}}"#),
        "{text}"
    );
}
