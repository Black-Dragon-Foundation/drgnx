//! What the tests against the real binary share: a hub in its own temporary root (`$TMPDIR`, short names so the
//! socket path stays under 103 bytes) with a clean environment, so nothing reaches `~` or the user's runtime dir, and a
//! line client.  Each test file uses part of it.
#![allow(dead_code)]

use runstav::paths::{self, Env};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

pub const BIN: &str = env!("CARGO_BIN_EXE_ratatoskr");

pub struct Root {
    pub dir: tempfile::TempDir,
}

impl Root {
    pub fn new() -> Root {
        let dir = tempfile::Builder::new().prefix("r").tempdir().unwrap();
        for sub in ["h", "r", "s", "d", "t"] {
            std::fs::create_dir(dir.path().join(sub)).unwrap();
        }
        std::fs::set_permissions(dir.path().join("r"), std::fs::Permissions::from_mode(0o700))
            .unwrap();
        Root { dir }
    }

    pub fn vars(&self) -> Vec<(String, String)> {
        let p = |s: &str| self.dir.path().join(s).to_string_lossy().into_owned();
        let mut v = vec![
            ("HOME".to_string(), p("h")),
            ("XDG_RUNTIME_DIR".into(), p("r")),
            ("XDG_STATE_HOME".into(), p("s")),
            ("XDG_DATA_HOME".into(), p("h/xd")),
            ("XDG_CONFIG_HOME".into(), p("h/xc")),
            ("XDG_CACHE_HOME".into(), p("h/xk")),
            ("DRGNX_DATA_DIR".into(), p("d")),
            ("DRGNX_CONFIG_DIR".into(), p("h/c")),
            ("TMPDIR".into(), p("t")),
            ("RATATOSKR_SUPERVISOR".into(), "none".into()),
        ];
        if let Ok(path) = std::env::var("PATH") {
            v.push(("PATH".into(), path));
        }
        v
    }

    pub fn socket(&self) -> PathBuf {
        let vars = self.vars();
        let pairs: Vec<(&str, &str)> = vars.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        paths::socket_path(&Env::new(&pairs, unsafe { libc::geteuid() }))
    }

    pub fn log_dir(&self) -> PathBuf {
        self.dir.path().join("s/drgnx/hub/log")
    }
}

/// How long a wait for the hub may take before it is called failed. Never what makes anything pass.
pub const FAILED_AFTER: Duration = Duration::from_secs(30);

pub struct Hub {
    pid: u32,
    /// The hub's exit status, sent by a thread that waits for the process (the one place that reaps it).
    ended: std::sync::mpsc::Receiver<ExitStatus>,
    stderr: PathBuf,
    status: Option<ExitStatus>,
}

impl Hub {
    pub fn start(root: &Root, n: usize) -> Hub {
        Hub::start_with(root, n, &[])
    }

    pub fn start_with(root: &Root, n: usize, extra: &[&str]) -> Hub {
        let stderr = root.dir.path().join(format!("hub-{n}.err"));
        let mut child = Command::new(BIN)
            .args([
                "serve",
                "--foreground",
                "--parent-pid",
                &std::process::id().to_string(),
            ])
            .args(extra)
            .env_clear()
            .envs(root.vars())
            .current_dir(root.dir.path())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(std::fs::File::create(&stderr).unwrap())
            .spawn()
            .unwrap();
        let pid = child.id();
        let (tx, ended) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(child.wait().unwrap());
        });
        Hub {
            pid,
            ended,
            stderr,
            status: None,
        }
    }

    pub fn pid(&self) -> u32 {
        self.pid
    }

    pub fn exited(&mut self) -> Option<ExitStatus> {
        if self.status.is_none() {
            self.status = self.ended.try_recv().ok();
        }
        self.status
    }

    /// The hub's exit status, when it has ended: waited for, not looked for.
    pub fn wait_exit(&mut self) -> ExitStatus {
        if self.status.is_none() {
            self.status = Some(
                self.ended
                    .recv_timeout(FAILED_AFTER)
                    .expect("the hub is still running"),
            );
        }
        self.status.unwrap()
    }

    /// Returns when the hub answers a ping. This one is a look repeated (the hub says nothing when it is ready); it
    /// ends at once, with the hub's stderr, when the hub ended, and `FAILED_AFTER` only bounds a failure.
    pub fn wait_ready(&mut self, socket: &Path) {
        skuld::wait_until(
            "the hub answers a ping (its stderr is in the hub's log)",
            FAILED_AFTER.as_secs(),
            || {
                if ping(socket) {
                    return Some(());
                }
                if let Some(s) = self.exited() {
                    panic!("the hub ended with {s}: {}", self.stderr_text());
                }
                None
            },
        );
    }

    pub fn stderr_text(&self) -> String {
        std::fs::read_to_string(&self.stderr).unwrap_or_default()
    }

    pub fn term(&mut self) {
        if self.exited().is_none() {
            unsafe { libc::kill(self.pid() as i32, libc::SIGTERM) };
        }
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.term();
        if self.status.is_none() && self.ended.recv_timeout(FAILED_AFTER).is_err() {
            // it ignored SIGTERM: a failure of its own, and no process is left behind
            unsafe { libc::kill(self.pid() as i32, libc::SIGKILL) };
            let _ = self.ended.recv_timeout(FAILED_AFTER);
        }
    }
}

/// A connection, its lines read in order (the challenge first).  A gated one stamps each line it sends with the next
/// `__seq` of a count its connections share, as the delivery gate does.
pub struct Client {
    pub stream: UnixStream,
    pub reader: BufReader<UnixStream>,
    seq: Option<Arc<AtomicU64>>,
}

impl Client {
    pub fn open(socket: &Path) -> Client {
        let stream = UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(FAILED_AFTER)).unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        Client {
            stream,
            reader,
            seq: None,
        }
    }

    /// A connection whose lines carry `__seq` from SEQ.
    pub fn gated(socket: &Path, seq: &Arc<AtomicU64>) -> Client {
        Client {
            seq: Some(seq.clone()),
            ..Client::open(socket)
        }
    }

    pub fn send(&mut self, mut v: Value) {
        if let Some(seq) = &self.seq {
            v["__seq"] = json!(seq.fetch_add(1, Ordering::SeqCst) + 1);
        }
        writeln!(self.stream, "{v}").unwrap();
    }

    pub fn line(&mut self) -> Option<Value> {
        let mut s = String::new();
        match self.reader.read_line(&mut s) {
            Ok(0) | Err(_) => None,
            Ok(_) => Some(serde_json::from_str(&s).unwrap()),
        }
    }

    /// The answer with ID; the lines before it are returned too.
    pub fn answer(&mut self, id: u64) -> (Value, Vec<Value>) {
        let mut before = vec![];
        loop {
            let v = self
                .line()
                .expect("the connection closed before the answer");
            if v["id"] == json!(id) {
                return (v, before);
            }
            before.push(v);
        }
    }

    /// `hello` with a valid proof, as id 0: a user connection.
    pub fn hello(&mut self, socket: &Path) {
        use runstav::proof;
        let challenge = self.line().expect("the challenge");
        let hub_nonce = challenge["data"]["nonce"].as_str().expect("a nonce");
        let cap = proof::Cap::read(&paths::cap_path(socket)).unwrap();
        let mine = proof::nonce().unwrap();
        self.send(json!({"id": 0, "method": "hello", "params": {
            "proto": 1, "nonce": mine, "proof": proof::client_proof(&cap, hub_nonce, &mine)}}));
        let (a, _) = self.answer(0);
        assert_eq!(a["result"]["class"], "user", "{a}");
    }
}

/// `ratatoskr-mock`, beside this test's own directory (`<target dir>/<profile dir>`); built once when it is not there.
pub fn mock_binary() -> PathBuf {
    let exe = std::env::current_exe().unwrap();
    let dir = exe.parent().unwrap().parent().unwrap();
    let bin = dir.join("ratatoskr-mock");
    if !bin.exists() {
        let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
        let profile = dir.file_name().unwrap().to_str().unwrap();
        let profile = if profile == "debug" { "dev" } else { profile };
        let ok = Command::new(cargo)
            .args([
                "build",
                "-p",
                "domr",
                "--bin",
                "ratatoskr-mock",
                "--profile",
                profile,
            ])
            .arg("--target-dir")
            .arg(dir.parent().unwrap())
            .status()
            .unwrap()
            .success();
        assert!(ok && bin.exists(), "ratatoskr-mock is not built");
    }
    bin
}

pub fn ping(socket: &Path) -> bool {
    let Ok(stream) = UnixStream::connect(socket) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let mut c = Client {
        reader: BufReader::new(stream.try_clone().unwrap()),
        stream,
        seq: None,
    };
    if writeln!(c.stream, "{}", json!({"id": 0, "method": "ping"})).is_err() {
        return false;
    }
    for _ in 0..3 {
        match c.line() {
            Some(v) if v["id"] == 0 => return v["result"]["pid"].is_number(),
            Some(_) => {}
            None => return false,
        }
    }
    false
}

/// The end of a child's exec, as a state a test can wait for.  `Command::spawn` can return while the child is still
/// the forked copy of this test binary, so `/proc/PID/exe` names the test until the exec; the child holds a close-on-exec
/// end of a pipe, which closes at the exec.
pub struct ExecHandshake(std::io::PipeReader);

impl ExecHandshake {
    /// Spawn CMD; the handshake ends when the child has exec'd.
    pub fn spawn(cmd: &mut Command) -> std::io::Result<(std::process::Child, ExecHandshake)> {
        let (reader, writer) = std::io::pipe()?;
        let child = cmd.spawn()?;
        drop(writer);
        Ok((child, ExecHandshake(reader)))
    }

    /// Block until the child has exec'd.
    pub fn wait(mut self) {
        let mut sink = Vec::new();
        std::io::Read::read_to_end(&mut self.0, &mut sink).unwrap();
    }
}
