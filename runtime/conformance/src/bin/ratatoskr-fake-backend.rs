//! ratatoskr-fake-backend: a stand-in for the Lisp backend behind Ratatoskr's front, for the conformance rows
//! (docs/develop/runtime.md).  Ratatoskr starts it as `DRGNX_RATATOSKR_BACKEND`; it
//!
//! - serves `DRGNX_HUB_SERVE_SOCKET` the v0 way (one JSON object per line, no hello), a stale socket file replaced;
//! - appends every line it receives to `$XDG_STATE_HOME/drgnx/fake-backend.log` and writes its own environment, as a
//!   JSON object, to `$XDG_STATE_HOME/drgnx/fake-backend.env`;
//! - answers from the script in `DRGNX_FAKE_BACKEND_SCRIPT` (JSON): `{METHOD: ANSWER}`, ANSWER being an object
//!   with `result` or `error` (sent with the request's id), a string (sent as the whole line, `$ID` replaced by the
//!   id), `null` (never answered), `{"exit": CODE}` (it exits at once) or `{"from_file": PATH}` (the answer object
//!   is read from PATH at each call, which a scenario rewrites meanwhile).  Without one: `ping` `{pid}`, `subscribe`
//!   and `coord/notify` `true`, `status` `{pid, gateway_port: 0, registrations: 0}`, anything else an error;
//! - when the script's `trigger` method (default `coord/notify`) is called, sends its subscribers the events of the
//!   file `events` (a JSON array of `{event, data}`), then `flood` `card` events of `flood_size` bytes of title;
//! - ends when `DRGNX_HUB_PARENT_PID` is gone (checked each second), unless the script says `ignore_parent: true`.

use serde_json::{Map, Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Shared {
    script: Map<String, Value>,
    log: Mutex<std::fs::File>,
    subscribers: Mutex<Vec<UnixStream>>,
}

fn die(why: &str) -> ! {
    eprintln!("ratatoskr-fake-backend: {why}");
    std::process::exit(1)
}

fn main() {
    let socket = std::env::var("DRGNX_HUB_SERVE_SOCKET")
        .unwrap_or_else(|_| die("DRGNX_HUB_SERVE_SOCKET is not set"));
    let state = PathBuf::from(
        std::env::var("XDG_STATE_HOME").unwrap_or_else(|_| die("XDG_STATE_HOME is not set")),
    )
    .join("drgnx");
    std::fs::create_dir_all(&state).unwrap_or_else(|e| die(&format!("{}: {e}", state.display())));
    let env: Map<String, Value> = std::env::vars()
        .map(|(k, v)| (k, Value::String(v)))
        .collect();
    std::fs::write(
        state.join("fake-backend.env"),
        Value::Object(env).to_string(),
    )
    .unwrap_or_else(|e| die(&format!("cannot write its environment: {e}")));
    let script = match std::env::var("DRGNX_FAKE_BACKEND_SCRIPT") {
        Ok(s) => match serde_json::from_str::<Value>(&s) {
            Ok(Value::Object(m)) => m,
            _ => die("DRGNX_FAKE_BACKEND_SCRIPT is not a JSON object"),
        },
        Err(_) => Map::new(),
    };
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(state.join("fake-backend.log"))
        .unwrap_or_else(|e| die(&format!("cannot open its log: {e}")));
    if script.get("ignore_parent") != Some(&Value::Bool(true)) {
        let parent: i32 = std::env::var("DRGNX_HUB_PARENT_PID")
            .ok()
            .and_then(|p| p.parse().ok())
            .unwrap_or(0);
        if parent > 0 {
            std::thread::spawn(move || {
                loop {
                    std::thread::sleep(Duration::from_secs(1));
                    if unsafe { libc::kill(parent, 0) } != 0 {
                        std::process::exit(0);
                    }
                }
            });
        }
    }
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(Path::new(&socket))
        .unwrap_or_else(|e| die(&format!("cannot bind {socket}: {e}")));
    let shared = Arc::new(Shared {
        script,
        log: Mutex::new(log),
        subscribers: Mutex::new(Vec::new()),
    });
    for stream in listener.incoming().flatten() {
        let shared = shared.clone();
        std::thread::spawn(move || serve(stream, &shared));
    }
}

fn send(w: &mut UnixStream, line: &str) {
    let _ = w.write_all(format!("{line}\n").as_bytes());
}

fn serve(stream: UnixStream, shared: &Shared) {
    let Ok(mut w) = stream.try_clone() else {
        return;
    };
    let mut r = BufReader::new(stream);
    let mut line = String::new();
    loop {
        line.clear();
        match r.read_line(&mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let text = line.trim_end_matches(['\n', '\r']);
        {
            let mut log = shared.log.lock().unwrap();
            let _ = writeln!(log, "{text}");
            let _ = log.flush();
        }
        let Ok(req) = serde_json::from_str::<Value>(text) else {
            continue;
        };
        let id = req.get("id").cloned().unwrap_or(Value::Null);
        let method = req["method"].as_str().unwrap_or_default().to_string();
        if method == "subscribe"
            && let Ok(c) = w.try_clone()
        {
            shared.subscribers.lock().unwrap().push(c);
        }
        match answer(&shared.script, &method) {
            Answer::Line(v) => {
                let mut obj = match v {
                    Value::Object(o) => o,
                    _ => Map::new(),
                };
                obj.insert("id".into(), id.clone());
                send(&mut w, &Value::Object(obj).to_string());
            }
            Answer::Raw(text) => send(&mut w, &text.replace("$ID", &id.to_string())),
            Answer::Never => {}
            Answer::Exit(code) => std::process::exit(code),
        }
        let trigger = shared
            .script
            .get("trigger")
            .and_then(Value::as_str)
            .unwrap_or("coord/notify");
        if method == trigger {
            broadcast(shared);
        }
    }
}

enum Answer {
    Line(Value),
    Raw(String),
    Never,
    Exit(i32),
}

fn answer(script: &Map<String, Value>, method: &str) -> Answer {
    match script.get(method) {
        Some(Value::Null) => Answer::Never,
        Some(Value::String(s)) => Answer::Raw(s.clone()),
        Some(Value::Object(o)) if o.contains_key("exit") => {
            Answer::Exit(o["exit"].as_i64().unwrap_or(1) as i32)
        }
        // `{"from_file": PATH}`: the answer object is read from PATH at each call (a scenario rewrites it meanwhile)
        Some(Value::Object(o)) if o.contains_key("from_file") => {
            let file = o["from_file"].as_str().unwrap_or_default();
            match std::fs::read_to_string(file)
                .ok()
                .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            {
                Some(v) => Answer::Line(v),
                None => Answer::Never,
            }
        }
        Some(v) => Answer::Line(v.clone()),
        None => Answer::Line(match method {
            "ping" => json!({"result": {"pid": std::process::id()}}),
            "subscribe" | "coord/notify" => json!({"result": true}),
            "status" => {
                json!({"result": {"pid": std::process::id(), "gateway_port": 0, "registrations": 0}})
            }
            m => json!({"error": {"message": format!("the fake backend has no answer for {m}")}}),
        }),
    }
}

/// The script's events and flood, to every subscriber.
fn broadcast(shared: &Shared) {
    let mut lines = Vec::new();
    if let Some(file) = shared.script.get("events").and_then(Value::as_str) {
        match std::fs::read_to_string(file)
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        {
            Some(Value::Array(events)) => lines.extend(events.iter().map(Value::to_string)),
            _ => eprintln!("ratatoskr-fake-backend: {file} is not a JSON array of events"),
        }
    }
    let n = shared
        .script
        .get("flood")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let size = shared
        .script
        .get("flood_size")
        .and_then(Value::as_u64)
        .unwrap_or(65536) as usize;
    let title = "x".repeat(size);
    let mut subs = shared.subscribers.lock().unwrap();
    for l in &lines {
        for s in subs.iter_mut() {
            send(s, l);
        }
    }
    for i in 0..n {
        let l = json!({"event": "card", "data": {"id": i, "title": title}}).to_string();
        for s in subs.iter_mut() {
            send(s, &l);
        }
    }
}
