//! A small blocking client for the commands (`ensure`, `stop`, `status`, `doctor`, `restart`): a raw `ping` as a
//! service connection, and a v1 *user* connection that reads the cap, answers the hub's challenge and checks the
//! hub's proof back before it sends anything (design 4.2).  Lines are read until the answer with the id asked for;
//! events on the way are skipped.

use runstav::paths::{self, Env};
use runstav::proof::{self, Cap};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// A connection that has said `hello` with a valid proof and checked the hub's.
pub struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

/// The longest line read back (a `status` is small; this bounds a hub that never ends a line).
const MAX_LINE: u64 = 1 << 20;

fn read_line(r: &mut BufReader<UnixStream>, deadline: Instant) -> Result<String, String> {
    use std::io::Read;
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() {
        return Err("no answer in time".into());
    }
    r.get_ref()
        .set_read_timeout(Some(left))
        .map_err(|e| e.to_string())?;
    let mut line = String::new();
    match r.by_ref().take(MAX_LINE).read_line(&mut line) {
        Ok(0) => Err("the hub closed the connection".into()),
        Ok(_) => Ok(line),
        Err(e)
            if matches!(
                e.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) =>
        {
            Err("no answer in time".into())
        }
        Err(e) => Err(e.to_string()),
    }
}

fn connect(socket: &Path, within: Duration) -> Result<UnixStream, String> {
    let s = UnixStream::connect(socket).map_err(|e| format!("{}: {e}", socket.display()))?;
    s.set_write_timeout(Some(within))
        .map_err(|e| e.to_string())?;
    Ok(s)
}

/// Does a hub answer `ping` on SOCKET?  Its pid.  (A v1 hub sends its challenge first; a v0 hub answers at once.)
pub fn ping(socket: &Path, within: Duration) -> Option<u32> {
    let deadline = Instant::now() + within;
    let mut s = connect(socket, within).ok()?;
    s.write_all(b"{\"id\":0,\"method\":\"ping\"}\n").ok()?;
    let mut r = BufReader::new(s);
    for _ in 0..4 {
        let line = read_line(&mut r, deadline).ok()?;
        let v: Value = serde_json::from_str(&line).ok()?;
        if v["id"] == 0
            && let Some(pid) = v["result"]["pid"].as_u64()
        {
            return u32::try_from(pid).ok();
        }
    }
    None
}

/// A v0 line to a Lisp hub, which serves it without a hello: METHOD with no params.  Whether it answered.  The
/// connection stays until the answer is read: a Lisp hub that finds its client gone does not carry out a `shutdown`.
pub fn v0_call(socket: &Path, method: &str) -> bool {
    let deadline = Instant::now() + Duration::from_secs(2);
    let Ok(mut s) = connect(socket, Duration::from_secs(2)) else {
        return false;
    };
    let line = json!({"id": 1, "method": method}).to_string();
    if s.write_all(format!("{line}\n").as_bytes()).is_err() {
        return false;
    }
    let mut r = BufReader::new(s);
    while let Ok(text) = read_line(&mut r, deadline) {
        if serde_json::from_str::<Value>(&text).is_ok_and(|v| v["id"] == 1) {
            return true;
        }
    }
    false
}

impl Client {
    /// A user connection to the hub at ENV's socket.  Errors say what failed (no cap, no socket, a wrong proof).
    pub fn user(env: &Env, within: Duration) -> Result<Client, String> {
        let socket = paths::socket_path(env);
        Client::user_at(&socket, within)
    }

    pub fn user_at(socket: &Path, within: Duration) -> Result<Client, String> {
        let deadline = Instant::now() + within;
        let cap_file: PathBuf = paths::cap_path(socket);
        let cap = Cap::read(&cap_file).map_err(|e| format!("cap {}: {e}", cap_file.display()))?;
        let stream = connect(socket, within)?;
        let writer = stream.try_clone().map_err(|e| e.to_string())?;
        let mut reader = BufReader::new(stream);
        // the challenge is the first line
        let hub_nonce = loop {
            let line = read_line(&mut reader, deadline)?;
            let v: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
            if v["event"] == "challenge" {
                break v["data"]["nonce"]
                    .as_str()
                    .ok_or("the challenge has no nonce")?
                    .to_string();
            }
        };
        let mine = proof::nonce().map_err(|e| e.to_string())?;
        let mut c = Client {
            reader,
            writer,
            next: 1,
        };
        let hello = json!({
            "proto": 1,
            "nonce": mine,
            "proof": proof::client_proof(&cap, &hub_nonce, &mine),
        });
        let reply = c.call(
            "hello",
            hello,
            deadline.saturating_duration_since(Instant::now()),
        )?;
        let theirs = reply["proof"].as_str().unwrap_or_default();
        if !proof::verify(&proof::hub_proof(&cap, &mine, &hub_nonce), theirs) {
            return Err("the hub did not prove it holds the cap: not sending it anything".into());
        }
        if reply["class"] != "user" {
            return Err(format!(
                "the hub made this connection {}, not user",
                reply["class"]
            ));
        }
        Ok(c)
    }

    /// METHOD with PARAMS: the result, or the error as "code: message".
    pub fn call(&mut self, method: &str, params: Value, within: Duration) -> Result<Value, String> {
        let deadline = Instant::now() + within;
        let id = self.next;
        self.next += 1;
        let line = json!({"id": id, "method": method, "params": params}).to_string();
        self.writer
            .write_all(format!("{line}\n").as_bytes())
            .map_err(|e| e.to_string())?;
        loop {
            let text = read_line(&mut self.reader, deadline)?;
            let v: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
            if v["id"] != id {
                continue;
            }
            if let Some(e) = v.get("error") {
                return Err(format!(
                    "{}: {}",
                    e["code"].as_str().unwrap_or("error"),
                    e["message"].as_str().unwrap_or("")
                ));
            }
            return Ok(v["result"].clone());
        }
    }
}
