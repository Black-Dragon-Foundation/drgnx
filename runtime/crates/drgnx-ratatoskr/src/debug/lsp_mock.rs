//! `ratatoskr debug-lsp-mock MODE [ARG]` (test-hooks only): a language server that opens a DAP server, for the
//! `lsp-command` tests. It speaks just enough LSP on stdio (`initialize`, `language/status`, `workspace/executeCommand`),
//! and fails the ways a real one can, one mode each:
//!
//! - `ok`: ready after `initialized`; `vscode.java.startDebugSession` opens a listener on a free port, answers it, and
//!   the listener answers one DAP request;
//! - `no-port`: never answers the debug command;
//! - `stranger PORT`: answers PORT, which another process holds;
//! - `bad-port`: answers a string;
//! - `oversized`: after `initialize` writes the header of a frame of 20 MiB and stops;
//! - `exit-init`: exits on `initialize`, with a word on stderr;
//! - `never-ready`: answers `initialize` and never says it is ready;
//! - `hostile`: as `ok`, but the `resolve*` commands answer nested objects, a variable and a list in a list.
//!
//! ARG after the mode (or after PORT) is the file `resolveMainClass` reports.

use serde_json::{Value, json};
use std::io::{BufRead, Write};

fn read_frame(r: &mut impl BufRead) -> Option<Value> {
    let mut len = None;
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let l = line.trim_end();
        if l.is_empty() {
            break;
        }
        if let Some(v) = l.strip_prefix("Content-Length:") {
            len = v.trim().parse::<usize>().ok();
        }
    }
    let mut body = vec![0u8; len?];
    r.read_exact(&mut body).ok()?;
    serde_json::from_slice(&body).ok()
}

fn write_frame(w: &mut impl Write, v: &Value) {
    let body = serde_json::to_vec(v).expect("json");
    let _ = write!(w, "Content-Length: {}\r\n\r\n", body.len());
    let _ = w.write_all(&body);
    let _ = w.flush();
}

/// The DAP server on LISTENER: every connection (a child session is a second one) gets a thread that answers each request
/// with an empty success.
fn serve_dap(listener: std::net::TcpListener) {
    for conn in listener.incoming() {
        let Ok(s) = conn else { return };
        std::thread::spawn(move || {
            let mut r = std::io::BufReader::new(s.try_clone().expect("clone"));
            let mut w = s;
            while let Some(req) = read_frame(&mut r) {
                let reply = json!({"seq": 1, "type": "response", "request_seq": req["seq"], "success": true,
                                   "command": req["command"], "body": {"supportsConfigurationDoneRequest": true}});
                write_frame(&mut w, &reply);
            }
        });
    }
}

pub fn main(mode: &str, arg: Option<&str>) -> i32 {
    let (mode, port_arg, file) = match (mode, arg) {
        ("stranger", Some(a)) => match a.split_once(' ') {
            Some((port, file)) => (mode, port.parse::<u64>().ok(), Some(file)),
            None => (mode, a.parse::<u64>().ok(), None),
        },
        _ => (mode, None, arg),
    };
    let stdin = std::io::stdin();
    let mut input = std::io::BufReader::new(stdin.lock());
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    while let Some(msg) = read_frame(&mut input) {
        let method = msg["method"].as_str().unwrap_or_default().to_owned();
        let id = msg.get("id").cloned();
        match method.as_str() {
            "initialize" => {
                if mode == "exit-init" {
                    eprintln!("the mock server cannot start");
                    return 3;
                }
                if mode == "oversized" {
                    let _ = write!(out, "Content-Length: {}\r\n\r\n", 20 << 20);
                    let _ = out.flush();
                    std::thread::sleep(std::time::Duration::from_secs(120));
                    return 0;
                }
                write_frame(
                    &mut out,
                    &json!({"jsonrpc": "2.0", "id": id, "result": {"capabilities": {}}}),
                );
            }
            "initialized" => {
                if mode != "never-ready" {
                    write_frame(
                        &mut out,
                        &json!({"jsonrpc": "2.0", "method": "language/status", "params": {"type": "ServiceReady", "message": "ServiceReady"}}),
                    );
                }
            }
            "workspace/executeCommand" => {
                let command = msg["params"]["command"].as_str().unwrap_or_default();
                let hostile = mode == "hostile";
                let result = match command {
                    "vscode.java.startDebugSession" => match mode {
                        "no-port" => continue,
                        "stranger" => json!(port_arg.unwrap_or(1)),
                        "bad-port" => json!("not a port"),
                        _ => {
                            let l = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind");
                            let port = l.local_addr().expect("addr").port();
                            std::thread::spawn(move || serve_dap(l));
                            json!(port)
                        }
                    },
                    "vscode.java.resolveMainClass" if hostile => {
                        json!([{"mainClass": {"nested": 1}, "projectName": "p", "filePath": file}])
                    }
                    "vscode.java.resolveMainClass" => {
                        json!([{"mainClass": "app.Main", "projectName": "app", "filePath": file},
                               {"mainClass": "app.Other", "projectName": "app", "filePath": "/other/Other.java"}])
                    }
                    "vscode.java.resolveClasspath" if hostile => json!([[], [["x"]]]),
                    "vscode.java.resolveClasspath" => json!([["/mp/a"], ["/cp/a", "/cp/b"]]),
                    "vscode.java.resolveJavaExecutable" if hostile => json!("${env:HOME}/bin/java"),
                    "vscode.java.resolveJavaExecutable" => json!("/jdk/bin/java"),
                    _ => Value::Null,
                };
                write_frame(
                    &mut out,
                    &json!({"jsonrpc": "2.0", "id": id, "result": result}),
                );
            }
            "shutdown" => write_frame(
                &mut out,
                &json!({"jsonrpc": "2.0", "id": id, "result": Value::Null}),
            ),
            "exit" => return 0,
            _ => {
                if let Some(id) = id {
                    write_frame(
                        &mut out,
                        &json!({"jsonrpc": "2.0", "id": id, "result": Value::Null}),
                    );
                }
            }
        }
    }
    0
}
