//! ratatoskr-fake-backend: a stand-in for the Lisp backend behind Ratatoskr's front, for the conformance rows
//! (docs/develop/runtime.md).  Ratatoskr starts it as `DRGNX_RATATOSKR_BACKEND`; it
//!
//! - serves `DRGNX_HUB_SERVE_SOCKET` the v0 way (one JSON object per line, no hello), a stale socket file replaced;
//! - as the Lisp backend, takes a connection only when its first line is `{"auth": DRGNX_HUB_SERVE_SECRET}` (which
//!   must be set), else closes it; that line is not logged;
//! - appends every other line it receives to `$XDG_STATE_HOME/drgnx/fake-backend.log` and writes its own environment, as a
//!   JSON object, to `$XDG_STATE_HOME/drgnx/fake-backend.env`;
//! - answers from the script in `DRGNX_FAKE_BACKEND_SCRIPT` (JSON): `{METHOD: ANSWER}`, ANSWER being an object
//!   with `result` or `error` (sent with the request's id), a string (sent as the whole line, `$ID` replaced by the
//!   id), `null` (never answered), `{"exit": CODE}` (it exits at once) or `{"from_file": PATH}` (the answer object
//!   is read from PATH at each call, which a scenario rewrites meanwhile).  Without one: `ping` `{pid}`, `subscribe`
//!   and `coord/notify` `true`, `status` `{pid, gateway_port: 0, registrations: 0}`, anything else an error;
//! - a script entry `{METHOD: {"call_front": {"method": M, "params": P}, "then": ANSWER}}` makes it, on METHOD, call M
//!   on the front's main socket as a proven user (the cap file's HMAC, one connection kept for later calls), wait up
//!   to 10 s, log `front-answer {...}`, and answer METHOD with ANSWER, or with the front's answer when ANSWER is
//!   `"$front"`;
//! - logs `notification {"method", "params"}` for every `coord/notify` and `budget` it receives (its front
//!   connection never subscribes); a line without an id (a notification) gets no answer;
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
    secret: String,
    script: Map<String, Value>,
    log: Mutex<std::fs::File>,
    subscribers: Mutex<Vec<UnixStream>>,
    /// The backend's one connection to the front, as a proven user (opened by the first `call_front`, then kept).
    front: Mutex<Option<Front>>,
}

struct Front {
    w: UnixStream,
    r: BufReader<UnixStream>,
    next_id: u64,
}

fn hmac_hex(key: &str, message: &str) -> String {
    use hmac::{Hmac, KeyInit, Mac};
    let mut mac = <Hmac<sha2::Sha256> as KeyInit>::new_from_slice(key.as_bytes())
        .expect("HMAC takes any key length");
    mac.update(message.as_bytes());
    mac.finalize()
        .into_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

impl Front {
    /// Connect to the main socket and prove the user's capability (`hub-HASH.cap` beside the socket).
    fn open() -> Result<Front, String> {
        let socket = runstav::paths::socket_path(&runstav::paths::Env::process());
        let cap = std::fs::read_to_string(runstav::paths::cap_path(&socket))
            .map_err(|e| format!("cannot read the cap: {e}"))?;
        let cap = cap.trim();
        let w = UnixStream::connect(&socket)
            .map_err(|e| format!("cannot connect to {}: {e}", socket.display()))?;
        let _ = w.set_read_timeout(Some(Duration::from_secs(10)));
        let mut r = BufReader::new(w.try_clone().map_err(|e| e.to_string())?);
        let mut line = String::new();
        r.read_line(&mut line)
            .map_err(|e| format!("no challenge: {e}"))?;
        let challenge: Value = serde_json::from_str(line.trim_end())
            .map_err(|e| format!("bad challenge {line:?}: {e}"))?;
        let hub_nonce = challenge["data"]["nonce"]
            .as_str()
            .ok_or_else(|| format!("no nonce in {challenge}"))?
            .to_string();
        let mut raw = [0u8; 16];
        getrandom::fill(&mut raw).map_err(|e| e.to_string())?;
        let nonce: String = raw.iter().map(|b| format!("{b:02x}")).collect();
        let proof = hmac_hex(cap, &format!("drgnx-hub client {hub_nonce} {nonce}"));
        let mut front = Front { w, r, next_id: 1 };
        let hello = json!({"proto": 1, "nonce": nonce, "client": "fake-backend", "proof": proof});
        let reply = front.call("hello", &hello)?;
        if reply.get("error").is_some() {
            return Err(format!("the front refused hello: {reply}"));
        }
        Ok(front)
    }

    /// Send one request and read lines until its answer (events and other answers are skipped).
    fn call(&mut self, method: &str, params: &Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        let req = json!({"id": id, "method": method, "params": params});
        self.w
            .write_all(format!("{req}\n").as_bytes())
            .map_err(|e| format!("write failed: {e}"))?;
        let _ = self.w.set_read_timeout(Some(Duration::from_secs(10)));
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            if std::time::Instant::now() > deadline {
                return Err(format!("no answer to {method} within 10 s"));
            }
            let mut line = String::new();
            match self.r.read_line(&mut line) {
                Ok(0) => return Err("the front closed the connection".into()),
                Err(e) => return Err(format!("no answer to {method}: {e}")),
                Ok(_) => {}
            }
            if let Ok(v) = serde_json::from_str::<Value>(line.trim_end())
                && v.get("id") == Some(&json!(id))
            {
                return Ok(v);
            }
        }
    }
}

impl Shared {
    fn log_line(&self, text: &str) {
        let mut log = self.log.lock().unwrap();
        let _ = writeln!(log, "{text}");
        let _ = log.flush();
    }

    /// `{"method": M, "params": P}` called on the front; its answer object, or why there was none.  A broken
    /// connection is dropped, and the next call opens a new one.
    fn call_front(&self, call: &Value) -> Result<Value, String> {
        let method = call["method"]
            .as_str()
            .ok_or("call_front needs a \"method\"")?;
        let params = call.get("params").cloned().unwrap_or_else(|| json!({}));
        let mut guard = self.front.lock().unwrap();
        if guard.is_none() {
            *guard = Some(Front::open()?);
        }
        let result = guard.as_mut().expect("just opened").call(method, &params);
        if result.is_err() {
            *guard = None;
        }
        result
    }
}

fn die(why: &str) -> ! {
    eprintln!("ratatoskr-fake-backend: {why}");
    std::process::exit(1)
}

fn main() {
    let socket = std::env::var("DRGNX_HUB_SERVE_SOCKET")
        .unwrap_or_else(|_| die("DRGNX_HUB_SERVE_SOCKET is not set"));
    let secret = std::env::var("DRGNX_HUB_SERVE_SECRET")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| die("DRGNX_HUB_SERVE_SECRET is not set"));
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
        secret,
        script,
        log: Mutex::new(log),
        subscribers: Mutex::new(Vec::new()),
        front: Mutex::new(None),
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
    // the first line proves the client is Ratatoskr, or the connection ends
    if !matches!(r.read_line(&mut line), Ok(1..))
        || serde_json::from_str::<Value>(line.trim_end())
            .ok()
            .and_then(|v| v.get("auth").and_then(Value::as_str).map(str::to_string))
            .is_none_or(|a| !runstav::proof::verify(&shared.secret, &a))
    {
        eprintln!("ratatoskr-fake-backend: refused a connection without the secret");
        return;
    }
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
        if matches!(method.as_str(), "coord/notify" | "budget") {
            shared.log_line(&format!(
                "notification {}",
                json!({"method": method, "params": req.get("params").cloned().unwrap_or(Value::Null)})
            ));
        }
        let entry = shared.script.get(&method);
        let answer = match entry.and_then(|e| e.get("call_front")) {
            Some(call) => {
                let reply = shared.call_front(call);
                shared.log_line(&format!(
                    "front-answer {}",
                    reply
                        .clone()
                        .unwrap_or_else(|e| json!({"error": {"message": e}}))
                ));
                let then = entry.and_then(|e| e.get("then"));
                let resolved = match (then, reply) {
                    (Some(Value::String(s)), Ok(front)) if s == "$front" => front,
                    (Some(Value::String(s)), Err(e)) if s == "$front" => {
                        json!({"error": {"message": e}})
                    }
                    (Some(t), _) => t.clone(),
                    (None, _) => json!({"result": true}),
                };
                // a string ANSWER is the whole line (as in a plain script entry); `$front` was resolved above
                answer_for(Some(&resolved), &method)
            }
            None => answer(&shared.script, &method),
        };
        match answer {
            // a notification (the front's coalesced `coord/notify`) is never answered
            Answer::Line(_) if id.is_null() => {}
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
    answer_for(script.get(method), method)
}

fn answer_for(entry: Option<&Value>, method: &str) -> Answer {
    match entry {
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
