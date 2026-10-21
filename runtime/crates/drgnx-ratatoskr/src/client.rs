//! A small blocking client for the commands (`ensure`, `stop`, `status`, `doctor`, `restart`): a raw `ping` as a
//! service connection, and a v1 *user* connection that reads the cap, answers the hub's challenge and checks the
//! hub's proof back before it sends anything (design 4.2).  Lines are read until the answer with the id asked for;
//! events on the way are skipped.  Each one first checks the socket's directory ([`trusted`]), as the Lisp client
//! does, and reads the cap through it.

use runstav::paths::{self, Env};
use runstav::proof::{self, Cap};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::fd::OwnedFd;
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

/// SOCKET's directory, checked ([`paths::trusted_dir`]): every client path goes through it before it reads, connects
/// to or signals anything (a `/tmp` fallback directory could be another user's).
pub fn trusted(socket: &Path) -> std::io::Result<OwnedFd> {
    paths::trusted_dir(socket.parent().unwrap_or(Path::new("/")))
}

/// Why SOCKET's directory is refused, when it is there and fails the check (a missing one is no hub: none).
pub fn refused(socket: &Path) -> Option<String> {
    match trusted(socket) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Some(e.to_string()),
        _ => None,
    }
}

/// The name of SOCKET in its directory.
fn name_of(socket: &Path) -> &Path {
    Path::new(socket.file_name().unwrap_or_default())
}

fn connect(socket: &Path, within: Duration) -> Result<UnixStream, String> {
    let dir = trusted(socket).map_err(|e| e.to_string())?;
    match paths::owned_in_trusted(&dir, name_of(socket)) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.to_string()),
        _ => {}
    }
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
        let dir = trusted(socket).map_err(|e| e.to_string())?;
        let cap = paths::open_in_trusted(&dir, name_of(&cap_file))
            .and_then(|f| Cap::read_from(f, &cap_file))
            .map_err(|e| format!("cap {}: {e}", cap_file.display()))?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;

    /// A stub hub on DIR/hub-x.sock: a challenge, then `ping` answers pid 7 and `hello` a proof of PROOF (`None`: the
    /// right one).  Each connection it takes is counted.
    fn stub(
        dir: &Path,
        proof: Option<&'static str>,
    ) -> (PathBuf, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
        let socket = dir.join("hub-x.sock");
        let cap = "ab".repeat(32);
        std::fs::write(dir.join("hub-x.cap"), &cap).unwrap();
        let listener = UnixListener::bind(&socket).unwrap();
        let taken = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let count = taken.clone();
        std::thread::spawn(move || {
            for s in listener.incoming().flatten() {
                count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let mut w = s.try_clone().unwrap();
                let hub_nonce = "c".repeat(32);
                let _ = writeln!(
                    w,
                    "{}",
                    json!({"event": "challenge", "data": {"nonce": hub_nonce}})
                );
                for line in BufReader::new(s).lines().map_while(Result::ok) {
                    let v: Value = serde_json::from_str(&line).unwrap();
                    let answer = match v["method"].as_str() {
                        Some("hello") => {
                            let theirs = v["params"]["nonce"].as_str().unwrap();
                            let right = proof::hmac_hex(
                                cap.as_bytes(),
                                &format!("drgnx-hub hub {theirs} {hub_nonce}"),
                            );
                            let p = proof.map_or(right, str::to_string);
                            json!({"id": v["id"], "result": {"class": "user", "proof": p}})
                        }
                        _ => json!({"id": v["id"], "result": {"pid": 7}}),
                    };
                    let _ = writeln!(w, "{answer}");
                }
            }
        });
        (socket, taken)
    }

    fn private(dir: &Path) {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn every_client_path_refuses_a_socket_dir_open_to_others_before_it_connects() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("drgnx");
        std::fs::create_dir(&dir).unwrap();
        private(&dir);
        let (socket, taken) = stub(&dir, None);
        // a private directory: served
        assert_eq!(ping(&socket, Duration::from_secs(2)), Some(7));
        assert!(v0_call(&socket, "ping"));
        let mut c = Client::user_at(&socket, Duration::from_secs(2)).unwrap();
        assert_eq!(
            c.call("status", json!({}), Duration::from_secs(2)).unwrap()["pid"],
            7
        );
        assert_eq!(refused(&socket), None);
        let before = taken.load(std::sync::atomic::Ordering::SeqCst);
        // open to others: each path refuses and nothing connects
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(ping(&socket, Duration::from_secs(2)), None);
        assert!(!v0_call(&socket, "shutdown"));
        let e = Client::user_at(&socket, Duration::from_secs(2))
            .err()
            .unwrap();
        assert!(e.contains("is open to other users (mode 755"), "{e}");
        assert!(refused(&socket).is_some_and(|r| r.contains("open to other users")));
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(
            taken.load(std::sync::atomic::Ordering::SeqCst),
            before,
            "a refused path connected"
        );
        // a link to the private directory is refused too
        private(&dir);
        let link = root.path().join("link");
        std::os::unix::fs::symlink(&dir, &link).unwrap();
        let via = link.join("hub-x.sock");
        assert_eq!(ping(&via, Duration::from_secs(2)), None);
        assert!(
            Client::user_at(&via, Duration::from_secs(2))
                .err()
                .unwrap()
                .contains("is not a directory")
        );
        // a missing directory is no hub, not a refusal
        assert_eq!(refused(&root.path().join("gone/hub-x.sock")), None);
        // a socket of another user's in a private directory (only root can make one here): not connected to
        if rustix::process::geteuid().is_root() {
            let before = taken.load(std::sync::atomic::Ordering::SeqCst);
            std::os::unix::fs::lchown(&socket, Some(65534), Some(65534)).unwrap();
            assert_eq!(ping(&socket, Duration::from_secs(2)), None);
            let e = Client::user_at(&socket, Duration::from_secs(2))
                .err()
                .unwrap();
            assert!(e.ends_with("belongs to another user"), "{e}");
            std::thread::sleep(Duration::from_millis(100));
            assert_eq!(taken.load(std::sync::atomic::Ordering::SeqCst), before);
        }
    }

    #[test]
    fn a_cap_that_is_a_link_is_not_read() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("drgnx");
        std::fs::create_dir(&dir).unwrap();
        private(&dir);
        let (socket, taken) = stub(&dir, None);
        let elsewhere = root.path().join("elsewhere.cap");
        std::fs::write(&elsewhere, "ab".repeat(32)).unwrap();
        std::fs::remove_file(dir.join("hub-x.cap")).unwrap();
        std::os::unix::fs::symlink(&elsewhere, dir.join("hub-x.cap")).unwrap();
        assert!(Client::user_at(&socket, Duration::from_secs(2)).is_err());
        assert_eq!(
            taken.load(std::sync::atomic::Ordering::SeqCst),
            0,
            "connected without a cap"
        );
    }

    #[test]
    fn a_wrong_hub_proof_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("drgnx");
        std::fs::create_dir(&dir).unwrap();
        private(&dir);
        let (socket, _) = stub(
            &dir,
            Some("0000000000000000000000000000000000000000000000000000000000000000"),
        );
        let e = Client::user_at(&socket, Duration::from_secs(2))
            .err()
            .unwrap();
        assert!(e.contains("did not prove it holds the cap"), "{e}");
    }
}
