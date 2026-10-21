//! The server core against the real binary, each hub in its own temporary root (`$TMPDIR`, short names so the socket
//! path stays under 103 bytes) with a clean environment: nothing reaches `~` or the user's runtime dir.

use runstav::paths::{self, Env};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_ratatoskr");

struct Root {
    dir: tempfile::TempDir,
}

impl Root {
    fn new() -> Root {
        let dir = tempfile::Builder::new().prefix("r").tempdir().unwrap();
        for sub in ["h", "r", "s", "d", "t"] {
            std::fs::create_dir(dir.path().join(sub)).unwrap();
        }
        std::fs::set_permissions(dir.path().join("r"), std::fs::Permissions::from_mode(0o700))
            .unwrap();
        Root { dir }
    }

    fn vars(&self) -> Vec<(String, String)> {
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

    fn socket(&self) -> PathBuf {
        let vars = self.vars();
        let pairs: Vec<(&str, &str)> = vars.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        paths::socket_path(&Env::new(&pairs, unsafe { libc::geteuid() }))
    }

    fn log_dir(&self) -> PathBuf {
        self.dir.path().join("s/drgnx/hub/log")
    }
}

struct Hub {
    child: Child,
    stderr: PathBuf,
    status: Option<ExitStatus>,
}

impl Hub {
    fn start(root: &Root, n: usize) -> Hub {
        Hub::start_with(root, n, &[])
    }

    fn start_with(root: &Root, n: usize, extra: &[&str]) -> Hub {
        let stderr = root.dir.path().join(format!("hub-{n}.err"));
        let child = Command::new(BIN)
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
        Hub {
            child,
            stderr,
            status: None,
        }
    }

    fn pid(&self) -> u32 {
        self.child.id()
    }

    fn exited(&mut self) -> Option<ExitStatus> {
        if self.status.is_none() {
            self.status = self.child.try_wait().unwrap();
        }
        self.status
    }

    fn wait_exit(&mut self, within: Duration) -> ExitStatus {
        let deadline = Instant::now() + within;
        loop {
            if let Some(s) = self.exited() {
                return s;
            }
            assert!(Instant::now() < deadline, "the hub is still running");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn wait_ready(&mut self, socket: &Path) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !ping(socket) {
            if let Some(s) = self.exited() {
                panic!("the hub ended with {s}: {}", self.stderr_text());
            }
            assert!(
                Instant::now() < deadline,
                "no ping answer: {}",
                self.stderr_text()
            );
            std::thread::sleep(Duration::from_millis(30));
        }
    }

    fn stderr_text(&self) -> String {
        std::fs::read_to_string(&self.stderr).unwrap_or_default()
    }

    fn term(&mut self) {
        if self.exited().is_none() {
            unsafe { libc::kill(self.pid() as i32, libc::SIGTERM) };
        }
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.term();
        let deadline = Instant::now() + Duration::from_secs(3);
        while self.exited().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        if self.exited().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

/// A connection, its lines read in order (the challenge first).
struct Client {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
}

// open, send and answer serve the flood test (test-hooks only)
#[cfg_attr(not(feature = "test-hooks"), allow(dead_code))]
impl Client {
    fn open(socket: &Path) -> Client {
        let stream = UnixStream::connect(socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        Client { stream, reader }
    }

    fn send(&mut self, v: Value) {
        writeln!(self.stream, "{v}").unwrap();
    }

    fn line(&mut self) -> Option<Value> {
        let mut s = String::new();
        match self.reader.read_line(&mut s) {
            Ok(0) | Err(_) => None,
            Ok(_) => Some(serde_json::from_str(&s).unwrap()),
        }
    }

    /// The answer with ID; the lines before it are returned too.
    fn answer(&mut self, id: u64) -> (Value, Vec<Value>) {
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
}

fn ping(socket: &Path) -> bool {
    let Ok(stream) = UnixStream::connect(socket) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let mut c = Client {
        reader: BufReader::new(stream.try_clone().unwrap()),
        stream,
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

fn mode(p: &Path) -> u32 {
    std::fs::symlink_metadata(p).unwrap().permissions().mode() & 0o7777
}

#[test]
fn methods_prints_the_committed_registry() {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let run = |flag: &str| {
        let out = Command::new(BIN).args(["methods", flag]).output().unwrap();
        assert!(out.status.success(), "methods {flag}: {out:?}");
        String::from_utf8(out.stdout).unwrap()
    };
    let committed = std::fs::read_to_string(repo.join("runtime/protocol/methods.json")).unwrap();
    assert_eq!(run("--json"), committed);
    let docs = std::fs::read_to_string(repo.join("docs/develop/hub.md")).unwrap();
    let table = run("--markdown");
    assert!(table.starts_with("| Method | Class |"), "{table}");
    assert!(
        docs.contains(&table),
        "hub.md's table is not `methods --markdown`"
    );
    let out = Command::new(BIN).arg("methods").output().unwrap();
    assert_eq!(out.status.code(), Some(2), "neither flag is a usage error");
}

#[test]
fn peer_uid_is_checked() {
    use drgnx_ratatoskr::conn::peer_allowed;
    assert!(peer_allowed(1000, 1000));
    assert!(!peer_allowed(1001, 1000), "another user");
    assert!(!peer_allowed(0, 1000), "root is another uid too");
    assert!(!peer_allowed(1000, 0), "a hub run as root refuses users");
}

#[test]
fn two_hubs_one_lock_second_exits_3() {
    let root = Root::new();
    let socket = root.socket();
    let mut first = Hub::start(&root, 1);
    first.wait_ready(&socket);
    let mut second = Hub::start(&root, 2);
    let status = second.wait_exit(Duration::from_secs(10));
    assert_eq!(status.code(), Some(3), "{}", second.stderr_text());
    assert!(
        second.stderr_text().contains("another hub serves here"),
        "{}",
        second.stderr_text()
    );
    // the first one still serves, its socket untouched
    assert!(ping(&socket));
    assert!(first.exited().is_none());
}

#[test]
fn the_path_is_statted_not_proc_self_exe() {
    use drgnx_ratatoskr::idle::ExeWatch;
    let dir = tempfile::tempdir().unwrap();
    let sleep = ["/usr/bin/sleep", "/bin/sleep"]
        .into_iter()
        .find(|p| Path::new(p).exists())
        .expect("a sleep binary");
    let (live, other) = (dir.path().join("live"), dir.path().join("other"));
    std::fs::copy(sleep, &live).unwrap();
    std::fs::copy(sleep, &other).unwrap();
    // a running process whose image is `live` (a file just written can be busy for a moment while another thread forks)
    let mut child = (0..50)
        .find_map(|_| {
            Command::new(&live)
                .arg("60")
                .spawn()
                .map_err(|_| std::thread::sleep(Duration::from_millis(20)))
                .ok()
        })
        .expect("the copied sleep starts");
    let by_path = ExeWatch::new(&live).unwrap();
    #[cfg(target_os = "linux")]
    let by_link = ExeWatch::new(Path::new(&format!("/proc/{}/exe", child.id()))).unwrap();
    assert!(!by_path.changed());
    // the update: a rename-replace of the file at the path
    std::fs::rename(&other, &live).unwrap();
    assert!(by_path.changed(), "the path now holds another file");
    #[cfg(target_os = "linux")]
    assert!(
        !by_link.changed(),
        "/proc/PID/exe follows the running inode, which a rename leaves alone"
    );
    // a missing file has not changed (it is looked at again later)
    std::fs::remove_file(&live).unwrap();
    assert!(!by_path.changed());
    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn launchd_never_loops_on_exit_3() {
    // launchd restarts on every non-zero exit: under `--supervisor launchd` "another hub serves" ends 0, with the
    // real code and reason in the hub's log and on stderr; without it the same start ends 3 (the test above)
    let root = Root::new();
    let socket = root.socket();
    let mut first = Hub::start(&root, 1);
    first.wait_ready(&socket);
    let mut second = Hub::start_with(&root, 2, &["--supervisor", "launchd"]);
    let status = second.wait_exit(Duration::from_secs(10));
    assert_eq!(status.code(), Some(0), "{}", second.stderr_text());
    assert!(
        second.stderr_text().contains("another hub serves here"),
        "{}",
        second.stderr_text()
    );
    assert!(
        second.stderr_text().contains("exit 3 mapped to 0"),
        "{}",
        second.stderr_text()
    );
    assert!(ping(&socket));
}

#[test]
fn the_stop_command_ends_a_hub_and_signals_nothing_for_a_stale_lock() {
    let root = Root::new();
    let socket = root.socket();
    let stop = |extra: &[&str]| {
        Command::new(BIN)
            .arg("stop")
            .args(extra)
            .env_clear()
            .envs(root.vars())
            .output()
            .unwrap()
    };
    // a stale lock file naming a live process nobody holds: not running, and the process lives
    let mut sleeper = Command::new("sleep").arg("60").spawn().unwrap();
    std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
    std::fs::write(paths::lock_path(&socket), format!("{} 1\n", sleeper.id())).unwrap();
    let out = stop(&[]);
    assert_eq!(out.status.code(), Some(0), "{out:?}");
    assert!(String::from_utf8_lossy(&out.stdout).contains("not running"));
    assert!(
        sleeper.try_wait().unwrap().is_none(),
        "stop signalled a stale lock's pid"
    );
    let _ = sleeper.kill();
    let _ = sleeper.wait();
    // a running hub: stopped by name and pid
    let mut hub = Hub::start(&root, 1);
    hub.wait_ready(&socket);
    let out = stop(&["--timeout", "10"]);
    assert_eq!(out.status.code(), Some(0), "{out:?} {}", hub.stderr_text());
    assert!(
        String::from_utf8_lossy(&out.stdout)
            .contains(&format!("stopped Ratatoskr (pid {})", hub.pid())),
        "{out:?}"
    );
    assert_eq!(hub.wait_exit(Duration::from_secs(10)).code(), Some(0));
}

#[test]
fn cap_is_64_hex_0600_and_gone_after_stop() {
    let root = Root::new();
    let socket = root.socket();
    let cap = paths::cap_path(&socket);
    let mut hub = Hub::start(&root, 1);
    hub.wait_ready(&socket);
    let text = std::fs::read_to_string(&cap).unwrap();
    assert_eq!(text.len(), 64, "{text:?}");
    assert!(
        text.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    );
    assert_eq!(mode(&cap), 0o600);
    assert_eq!(mode(&socket), 0o600);
    assert_eq!(mode(socket.parent().unwrap()), 0o700);
    // no temporary file of the cap's is left beside it
    let names: Vec<String> = std::fs::read_dir(socket.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names.len(), 3, "socket, cap and lock only: {names:?}");
    hub.term();
    let status = hub.wait_exit(Duration::from_secs(5));
    assert_eq!(status.code(), Some(0), "{}", hub.stderr_text());
    assert!(!cap.exists(), "the cap is removed at stop");
    assert!(!socket.exists(), "the socket is removed at stop");
    // the log never holds the cap
    for e in std::fs::read_dir(root.log_dir()).unwrap() {
        let log = std::fs::read_to_string(e.unwrap().path()).unwrap();
        assert!(!log.contains(&text), "the cap is in the log");
    }
}

#[test]
fn the_lock_file_holds_pid_and_start_time() {
    let root = Root::new();
    let socket = root.socket();
    let mut hub = Hub::start(&root, 1);
    hub.wait_ready(&socket);
    let lock = paths::lock_path(&socket);
    assert_eq!(mode(&lock), 0o600);
    let text = std::fs::read_to_string(&lock).unwrap();
    let fields: Vec<&str> = text
        .strip_suffix('\n')
        .expect("one line")
        .split(' ')
        .collect();
    assert_eq!(fields.len(), 2, "{text:?}");
    assert_eq!(fields[0], hub.pid().to_string());
    let start: u64 = fields[1].parse().expect("a number");
    assert!(start > 0);
    if cfg!(target_os = "linux") {
        let stat = std::fs::read_to_string(format!("/proc/{}/stat", hub.pid())).unwrap();
        let field_22 = stat
            .rsplit_once(')')
            .unwrap()
            .1
            .split_whitespace()
            .nth(19)
            .unwrap();
        assert_eq!(fields[1], field_22);
    }
}

#[cfg(feature = "test-hooks")]
#[test]
fn a_stopped_reader_is_dropped_after_16_mib_while_another_keeps_reading() {
    use std::io::Read;
    const LINES: u64 = 512;
    const SIZE: u64 = 64 * 1024; // 32 MiB in all
    let root = Root::new();
    let socket = root.socket();
    let mut hub = Hub::start(&root, 1);
    hub.wait_ready(&socket);
    let flood =
        json!({"id": 1, "method": "__test_flood", "params": {"lines": LINES, "size": SIZE}});

    // the stopped reader: asks for the flood and reads nothing
    let mut stopped = Client::open(&socket);
    stopped.send(flood.clone());

    // the reader that keeps reading gets every line and then the answer
    let mut reading = Client::open(&socket);
    reading.send(flood);
    let (answer, before) = reading.answer(1);
    assert_eq!(answer["result"]["queued"], json!(LINES), "{answer}");
    let floods = before.iter().filter(|v| v["event"] == "flood").count();
    assert_eq!(floods as u64, LINES);

    // the stopped one was dropped: what it reads now ends early, without the answer
    let mut got = 0usize;
    let mut buf = vec![0u8; 1 << 16];
    let mut all = Vec::new();
    loop {
        match stopped.reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                got += n;
                all.extend_from_slice(&buf[..n]);
            }
            Err(e) => panic!("the stopped reader was not closed: {e}"),
        }
    }
    assert!(
        got < (LINES * SIZE) as usize,
        "it got the whole flood ({got} bytes)"
    );
    assert!(
        !String::from_utf8_lossy(&all).contains("\"queued\""),
        "the dropped connection got the answer"
    );
    // the hub serves on, and says why it dropped the reader
    assert!(ping(&socket));
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let log: String = std::fs::read_dir(root.log_dir())
            .unwrap()
            .map(|e| std::fs::read_to_string(e.unwrap().path()).unwrap())
            .collect();
        if log.contains("queued over 16 MiB") {
            break;
        }
        assert!(Instant::now() < deadline, "no drop in the log: {log}");
        std::thread::sleep(Duration::from_millis(50));
    }
}
