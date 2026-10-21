//! Hubs under test (a process in its own temporary root) and the connections to them.

use crate::matcher::{self, Captures};
use crate::paths::{self, Env};
use hmac::{Hmac, KeyInit, Mac};
use serde_json::Value;
use sha2::Sha256;
use std::collections::{BTreeMap, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------- proofs (an implementation independent of any hub)

fn hmac_hex(key: &str, message: &str) -> String {
    let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(key.as_bytes())
        .expect("HMAC takes any key length");
    mac.update(message.as_bytes());
    mac.finalize()
        .into_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The client's proof: HMAC-SHA256 keyed with the cap's 64 hex digits as ASCII, over both nonces.
pub fn client_proof(cap: &str, hub_nonce: &str, client_nonce: &str) -> String {
    hmac_hex(cap, &format!("drgnx-hub client {hub_nonce} {client_nonce}"))
}

/// The hub's proof back, which it sends only after a valid client proof.
pub fn hub_proof(cap: &str, client_nonce: &str, hub_nonce: &str) -> String {
    hmac_hex(cap, &format!("drgnx-hub hub {client_nonce} {hub_nonce}"))
}

pub fn random_hex(bytes: usize) -> String {
    let mut b = vec![0u8; bytes];
    getrandom::fill(&mut b).expect("the OS random source");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

// ---------------------------------------------------------------- the root every hub lives in

/// `/tmp/rtsk-XXXXXX/` with `home run state data config cache tmp`: `/tmp`, not `$TMPDIR`, so macOS socket paths stay short.
/// `DRGNX_CONFORMANCE_ROOTS=DIR/PREFIX` makes them `DIR/PREFIXXXXXXX/` instead (a short DIR: the socket path must stay
/// within 103 bytes).
pub struct Root {
    dir: tempfile::TempDir,
}

impl Root {
    pub fn new() -> Result<Arc<Root>, String> {
        let roots = std::env::var_os("DRGNX_CONFORMANCE_ROOTS").map(PathBuf::from);
        let (parent, prefix) = match &roots {
            Some(r) => (
                r.parent().unwrap_or(Path::new("/")),
                r.file_name().unwrap_or_default(),
            ),
            None => (Path::new("/tmp"), std::ffi::OsStr::new("rtsk-")),
        };
        let dir = tempfile::Builder::new()
            .prefix(prefix)
            .tempdir_in(parent)
            .map_err(|e| format!("cannot make a root in {}: {e}", parent.display()))?;
        for sub in ["home", "run", "state", "data", "config", "cache", "tmp"] {
            std::fs::create_dir(dir.path().join(sub))
                .map_err(|e| format!("cannot make {sub} in the root: {e}"))?;
        }
        std::fs::set_permissions(
            dir.path().join("run"),
            std::fs::Permissions::from_mode(0o700),
        )
        .map_err(|e| e.to_string())?;
        Ok(Arc::new(Root { dir }))
    }

    pub fn path(&self) -> &Path {
        self.dir.path()
    }

    /// The whole environment a hub or a CLI run gets (nothing else is inherited but `PATH` and `DRGNX_EMACS`): every
    /// directory points into this root, so nothing reaches `~`.  `extra` wins.
    pub fn base_env(&self, extra: Vec<(String, String)>) -> BTreeMap<String, String> {
        let dir = |s: &str| self.path().join(s).to_string_lossy().into_owned();
        let mut vars: BTreeMap<String, String> = BTreeMap::new();
        for k in ["PATH", "DRGNX_EMACS"] {
            if let Ok(v) = std::env::var(k) {
                vars.insert(k.into(), v);
            }
        }
        for (k, v) in [
            ("HOME", dir("home")),
            ("XDG_RUNTIME_DIR", dir("run")),
            ("XDG_STATE_HOME", dir("state")),
            ("XDG_CACHE_HOME", dir("cache")),
            ("XDG_DATA_HOME", dir("xdg-data")),
            ("XDG_CONFIG_HOME", dir("xdg-config")),
            ("DRGNX_DATA_DIR", dir("data")),
            ("DRGNX_CONFIG_DIR", dir("config")),
            ("TMPDIR", dir("tmp")),
            ("RATATOSKR_SUPERVISOR", "none".to_string()),
        ] {
            vars.insert(k.into(), v);
        }
        vars.extend(extra);
        vars
    }
}

// ---------------------------------------------------------------- hubs

pub struct Hub {
    pub name: String,
    pub root: Arc<Root>,
    pub env: Env,
    pub child: Child,
    pub pid: u32,
    pub log: PathBuf,
    pub socket: PathBuf,
    exit: Option<std::process::ExitStatus>,
}

pub struct StartSpec<'a> {
    pub name: &'a str,
    pub root: Arc<Root>,
    pub bin: &'a Path,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub parent_pid: u32,
    pub index: usize,
}

impl Hub {
    pub fn start(spec: StartSpec) -> Result<Hub, String> {
        let r = spec.root.path();
        let vars = spec.root.base_env(spec.env);
        let env = Env {
            vars: vars.clone(),
            uid: unsafe { libc::geteuid() },
        };
        let log = r.join(format!("{}-{}.log", spec.name, spec.index));
        let out =
            std::fs::File::create(&log).map_err(|e| format!("cannot make the hub's log: {e}"))?;
        let child = Command::new(spec.bin)
            .args([
                "serve",
                "--foreground",
                "--parent-pid",
                &spec.parent_pid.to_string(),
            ])
            .args(&spec.args)
            .env_clear()
            .envs(&vars)
            .current_dir(r)
            .stdin(Stdio::null())
            .stdout(out.try_clone().map_err(|e| e.to_string())?)
            .stderr(out)
            .spawn()
            .map_err(|e| format!("cannot start {}: {e}", spec.bin.display()))?;
        let pid = child.id();
        let socket = paths::socket_path(&env);
        Ok(Hub {
            name: spec.name.to_string(),
            root: spec.root,
            env,
            child,
            pid,
            log,
            socket,
            exit: None,
        })
    }

    pub fn socket_dir(&self) -> PathBuf {
        self.socket
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default()
    }

    pub fn cap(&self) -> PathBuf {
        self.socket.with_extension("cap")
    }

    pub fn lock(&self) -> PathBuf {
        let mut s = self.socket.clone().into_os_string();
        s.push(".lock");
        PathBuf::from(s)
    }

    pub fn state_dir(&self) -> PathBuf {
        self.root.path().join("state").join("drgnx")
    }

    /// The variables a step can use in its strings (`$PID(name)` and `$HARNESS_PID` are the executor's).
    pub fn vars(&self) -> BTreeMap<&'static str, String> {
        let s = |p: &Path| p.to_string_lossy().into_owned();
        let data = s(&paths::data_dir(&self.env));
        BTreeMap::from([
            ("ROOT", s(self.root.path())),
            ("HOME", s(&self.root.path().join("home"))),
            ("RUN", s(&self.root.path().join("run"))),
            ("STATE", s(&self.state_dir())),
            ("DATA", data.trim_end_matches('/').to_string()),
            ("CONFIG", s(&self.root.path().join("config"))),
            ("SOCKET", s(&self.socket)),
            ("SOCKET_DIR", s(&self.socket_dir())),
            ("CAP", s(&self.cap())),
            ("LOCK", s(&self.lock())),
        ])
    }

    /// Has the process ended?  (Reaps it.)
    pub fn exited(&mut self) -> Option<std::process::ExitStatus> {
        if self.exit.is_none() {
            self.exit = self.child.try_wait().ok().flatten();
        }
        self.exit
    }

    pub fn log_tail(&self) -> String {
        let text = std::fs::read_to_string(&self.log).unwrap_or_default();
        let lines: Vec<&str> = text.lines().collect();
        let from = lines.len().saturating_sub(15);
        lines[from..].join("\n")
    }

    /// Wait until `ping` is answered on the socket.
    pub fn wait_ready(&mut self, within: Duration) -> Result<(), String> {
        let deadline = Instant::now() + within;
        loop {
            if let Some(status) = self.exited() {
                return Err(format!(
                    "the hub ended with {} before it answered ping; its log:\n{}",
                    describe(status),
                    self.log_tail()
                ));
            }
            if ping(&self.socket) {
                return Ok(());
            }
            if Instant::now() > deadline {
                return Err(format!(
                    "no ping answer on {} within {} ms; the hub's log:\n{}",
                    self.socket.display(),
                    within.as_millis(),
                    self.log_tail()
                ));
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// SIGTERM, then SIGKILL after three seconds.
    pub fn terminate(&mut self) {
        if self.exited().is_some() {
            return;
        }
        unsafe { libc::kill(self.pid as i32, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(3);
        while self.exited().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(25));
        }
        if self.exited().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

pub fn describe(status: std::process::ExitStatus) -> String {
    use std::os::unix::process::ExitStatusExt;
    match (status.code(), status.signal()) {
        (Some(c), _) => format!("exit code {c}"),
        (_, Some(s)) => format!("signal {s}"),
        _ => "an unknown status".into(),
    }
}

/// Does a hub answer `ping` here?  (On a v1 hub the first line is its challenge: lines are read until the answer.)
pub fn ping(socket: &Path) -> bool {
    let Ok(mut s) = UnixStream::connect(socket) else {
        return false;
    };
    let _ = s.set_read_timeout(Some(Duration::from_millis(500)));
    if s.write_all(b"{\"id\":0,\"method\":\"ping\"}\n").is_err() {
        return false;
    }
    let mut r = BufReader::new(s);
    for _ in 0..4 {
        let mut line = String::new();
        if r.read_line(&mut line).unwrap_or(0) == 0 {
            return false;
        }
        if serde_json::from_str::<Value>(&line)
            .is_ok_and(|v| v["id"] == 0 && v.get("result").is_some())
        {
            return true;
        }
    }
    false
}

// ---------------------------------------------------------------- connections

enum Msg {
    Line(String),
    Eof,
}

pub struct Conn {
    writer: Box<dyn Write + Send>,
    /// The socket itself, for `close_write` (none for the other uid's relay, whose stdin is closed instead).
    socket: Option<UnixStream>,
    rx: Receiver<Msg>,
    /// Lines read but not yet consumed by an `expect` (earlier non-matching lines stay here).
    buf: VecDeque<String>,
    eof: bool,
    helper: Option<Child>,
    /// The hub's challenge nonce, once read.
    hub_nonce: Option<String>,
    pub next_id: u64,
}

fn spawn_reader(r: impl Read + Send + 'static) -> Receiver<Msg> {
    let (tx, rx) = channel();
    std::thread::spawn(move || {
        let mut r = BufReader::new(r);
        let mut raw = Vec::new();
        loop {
            raw.clear();
            match r.read_until(b'\n', &mut raw) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    while matches!(raw.last(), Some(b'\n' | b'\r')) {
                        raw.pop();
                    }
                    if tx
                        .send(Msg::Line(String::from_utf8_lossy(&raw).into_owned()))
                        .is_err()
                    {
                        return;
                    }
                }
            }
        }
        let _ = tx.send(Msg::Eof);
    });
    rx
}

fn as_json(line: &str) -> Value {
    serde_json::from_str(line).unwrap_or_else(|_| Value::String(line.to_string()))
}

impl Conn {
    /// Connect to a Unix socket, retrying for up to `retry` (agent sockets appear a moment after the hub).
    pub fn open(path: &Path, retry: Duration) -> Result<Conn, String> {
        let deadline = Instant::now() + retry;
        let stream = loop {
            match UnixStream::connect(path) {
                Ok(s) => break s,
                Err(e) if Instant::now() > deadline => {
                    return Err(format!("cannot connect to {}: {e}", path.display()));
                }
                Err(_) => std::thread::sleep(Duration::from_millis(50)),
            }
        };
        let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
        let reader = stream.try_clone().map_err(|e| e.to_string())?;
        let socket = stream.try_clone().map_err(|e| e.to_string())?;
        Ok(Conn {
            writer: Box::new(stream),
            socket: Some(socket),
            rx: spawn_reader(reader),
            buf: VecDeque::new(),
            eof: false,
            helper: None,
            hub_nonce: None,
            next_id: 1,
        })
    }

    /// Connect as another uid: `connect-as` of this program, run as `nobody` (setpriv as root, else `sudo -n -u nobody`),
    /// relays the connection over its stdio.  The program is copied into `dir` first, which must be reachable by that uid.
    pub fn open_as_other_uid(path: &Path, dir: &Path) -> Result<Conn, String> {
        let me = std::env::current_exe().map_err(|e| e.to_string())?;
        let copy = dir.join("connect-as");
        std::fs::copy(&me, &copy)
            .map_err(|e| format!("cannot copy the harness for connect-as: {e}"))?;
        std::fs::set_permissions(&copy, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| e.to_string())?;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o711))
            .map_err(|e| e.to_string())?;
        // setpriv is util-linux's (Fedora's util-linux-core has none): without it root goes through sudo too
        let setpriv = Command::new("setpriv")
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        let mut cmd = if unsafe { libc::geteuid() } == 0 && setpriv {
            let mut c = Command::new("setpriv");
            c.args(["--reuid", "65534", "--regid", "65534", "--clear-groups"]);
            c
        } else {
            let mut c = Command::new(std::env::var("SUDO").unwrap_or_else(|_| "sudo".into()));
            c.args(["-n", "-u", "nobody"]);
            c
        };
        let mut child = cmd
            .arg(&copy)
            .args(["connect-as", "--socket"])
            .arg(path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| format!("cannot start connect-as: {e}"))?;
        let writer = child.stdin.take().expect("piped");
        let reader = child.stdout.take().expect("piped");
        Ok(Conn {
            writer: Box::new(writer),
            socket: None,
            rx: spawn_reader(reader),
            buf: VecDeque::new(),
            eof: false,
            helper: Some(child),
            hub_nonce: None,
            next_id: 1,
        })
    }

    /// Write one line.  A hub that closed the connection meanwhile is not an error here: the next `expect_closed` says so.
    pub fn send_line(&mut self, text: &str, newline: bool) -> Result<(), String> {
        let mut data = text.as_bytes().to_vec();
        if newline {
            data.push(b'\n');
        }
        self.send_bytes(&data)
    }

    pub fn send_bytes(&mut self, data: &[u8]) -> Result<(), String> {
        match self
            .writer
            .write_all(data)
            .and_then(|()| self.writer.flush())
        {
            Ok(()) => Ok(()),
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::ConnectionReset
                ) =>
            {
                Ok(())
            }
            Err(e) => Err(format!("write failed: {e}")),
        }
    }

    /// End what this side sends (the hub reads EOF; the connection still reads): a client that vanished mid-line.
    pub fn close_write(&mut self) -> Result<(), String> {
        match &self.socket {
            Some(s) => s
                .shutdown(std::net::Shutdown::Write)
                .map_err(|e| format!("shutdown failed: {e}")),
            None => {
                // the relay's stdin closed: it shuts its socket's write side
                self.writer = Box::new(std::io::sink());
                Ok(())
            }
        }
    }

    fn pull(&mut self, wait: Duration) -> Result<Option<String>, RecvTimeoutError> {
        if let Some(l) = self.buf.pop_front() {
            return Ok(Some(l));
        }
        self.fetch(wait)
    }

    /// The next line from the wire; `Ok(None)` at EOF.
    fn fetch(&mut self, wait: Duration) -> Result<Option<String>, RecvTimeoutError> {
        if self.eof {
            return Ok(None);
        }
        match self.rx.recv_timeout(wait)? {
            Msg::Line(l) => Ok(Some(l)),
            Msg::Eof => {
                self.eof = true;
                Ok(None)
            }
        }
    }

    fn recent(&self, seen: &[String]) -> String {
        if seen.is_empty() {
            "nothing arrived".into()
        } else {
            format!("lines seen: {}", seen.join(" | "))
        }
    }

    /// The first buffered or arriving line that matches; earlier non-matching lines stay buffered.
    pub fn expect(
        &mut self,
        pattern: &Value,
        within: Duration,
        caps: &mut Captures,
    ) -> Result<Value, String> {
        let mut why = String::new();
        let mut i = 0;
        while i < self.buf.len() {
            let v = as_json(&self.buf[i]);
            let mut trial = caps.clone();
            match matcher::matches(pattern, &v, &mut trial) {
                Ok(()) => {
                    self.buf.remove(i);
                    *caps = trial;
                    return Ok(v);
                }
                Err(e) => why = e,
            }
            i += 1;
        }
        let deadline = Instant::now() + within;
        let mut seen: Vec<String> = Vec::new();
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.fetch(left) {
                Ok(Some(line)) => {
                    let v = as_json(&line);
                    let mut trial = caps.clone();
                    match matcher::matches(pattern, &v, &mut trial) {
                        Ok(()) => {
                            *caps = trial;
                            return Ok(v);
                        }
                        Err(e) => why = e,
                    }
                    seen.push(line.clone());
                    self.buf.push_back(line);
                }
                Ok(None) => {
                    return Err(format!(
                        "the connection closed before a line matched {pattern} ({why}); {}",
                        self.recent(&seen)
                    ));
                }
                Err(_) => {
                    let buffered: Vec<String> = self.buf.iter().cloned().collect();
                    return Err(format!(
                        "no line matched {pattern} within {} ms ({why}); {}",
                        within.as_millis(),
                        self.recent(&buffered)
                    ));
                }
            }
        }
    }

    /// The very next line must match.
    pub fn expect_next(
        &mut self,
        pattern: &Value,
        within: Duration,
        caps: &mut Captures,
    ) -> Result<Value, String> {
        match self.pull(within) {
            Ok(Some(line)) => {
                let v = as_json(&line);
                matcher::matches(pattern, &v, caps)
                    .map(|()| v)
                    .map_err(|e| format!("the next line {line} does not match {pattern}: {e}"))
            }
            Ok(None) => Err(format!(
                "the connection closed; wanted a line matching {pattern}"
            )),
            Err(_) => Err(format!(
                "no line within {} ms; wanted one matching {pattern}",
                within.as_millis()
            )),
        }
    }

    pub fn expect_closed(&mut self, within: Duration) -> Result<(), String> {
        let deadline = Instant::now() + within;
        loop {
            match self.fetch(deadline.saturating_duration_since(Instant::now())) {
                Ok(None) => return Ok(()),
                Ok(Some(line)) => self.buf.push_back(line),
                Err(_) => {
                    return Err(format!(
                        "the hub did not close the connection within {} ms",
                        within.as_millis()
                    ));
                }
            }
        }
    }

    pub fn expect_silent(&mut self, quiet: Duration) -> Result<(), String> {
        match self.fetch(quiet) {
            Err(_) => Ok(()),
            Ok(Some(line)) => {
                self.buf.push_back(line.clone());
                Err(format!(
                    "a line arrived within {} ms: {line}",
                    quiet.as_millis()
                ))
            }
            Ok(None) => Err("the connection closed (expected silence)".into()),
        }
    }

    /// Wait for the `challenge` event and return the hub's nonce (earlier lines stay buffered).  A connection is
    /// challenged once: a second hello on it uses the nonce the first one read.
    pub fn challenge(&mut self, within: Duration) -> Result<String, String> {
        if let Some(n) = &self.hub_nonce {
            return Ok(n.clone());
        }
        let mut caps = Captures::default();
        let v = self.expect(
            &serde_json::json!({"event": "challenge", "data": {"nonce": "$capture:n"}}),
            within,
            &mut caps,
        )?;
        let n = v["data"]["nonce"].as_str().unwrap_or_default().to_string();
        self.hub_nonce = Some(n.clone());
        Ok(n)
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        if let Some(mut c) = self.helper.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // HMAC-SHA256 computed with `openssl dgst -sha256 -hmac` (a separate implementation) over the same texts.
    const CAP: &str = "abababababababababababababababababababababababababababababababab";
    const HUB: &str = "00112233445566778899aabbccddeeff";
    const CLIENT: &str = "000102030405060708090a0b0c0d0e0f";

    #[test]
    fn proofs_match_an_independent_implementation() {
        assert_eq!(
            client_proof(CAP, HUB, CLIENT),
            "31b63f04bde8492a0cba48c28c35d938788d32050786abdd3f5afad3910f36d2"
        );
        assert_eq!(
            hub_proof(CAP, CLIENT, HUB),
            "6ebe405282bef89733779e7b41ed4c5ad4577e185df620c5a734bec2dc9a5e2e"
        );
        assert_ne!(
            client_proof(CAP, HUB, CLIENT),
            client_proof(CAP, CLIENT, HUB),
            "the order of the nonces counts"
        );
    }
}
