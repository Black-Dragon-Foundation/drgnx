//! `ratatoskr sandbox run` (test-hooks) end to end, in the reduced tier: the spec validated against Ratatoskr's
//! context, `Sandbox::prepare`, the helper spawned through `draugr::spawn_pinned` in a session of its own (GL-T8-1),
//! the status line, the exit and the result file. The full tier's real run is the row `linux/works` (Task 14): the
//! container has no bwrap that works. Fixtures live under /tmp/glp-*, and HOME points there.
// Linux only: the reduced tier is Linux's (Android: no backend; fails closed). The command exists only with test-hooks.
#![cfg(all(target_os = "linux", feature = "test-hooks"))]

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

const RATATOSKR: &str = env!("CARGO_BIN_EXE_ratatoskr");

fn abi_9(test: &str) -> bool {
    let abi = gleipnir::landlock::kernel_abi();
    if abi < 9 {
        eprintln!("SKIP {test}: the kernel's Landlock ABI is {abi}, the reduced tier needs 9");
    }
    abi >= 9
}

struct Fx {
    _dir: tempfile::TempDir,
    b: PathBuf,
}

impl Fx {
    fn new() -> Fx {
        let dir = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/tmp")
            .unwrap();
        let b = dir.path().canonicalize().unwrap();
        for d in ["home", "w", "t", "outside"] {
            std::fs::create_dir(b.join(d)).unwrap();
        }
        Fx { _dir: dir, b }
    }

    fn p(&self, rel: &str) -> PathBuf {
        self.b.join(rel)
    }

    /// A reduced-tier spec writing `write`.
    fn spec(&self, write: &Path) -> PathBuf {
        let spec = serde_json::json!({
            "write": [write],
            "env": [["PATH", "/usr/bin:/bin"]],
            "chdir": write,
            "net": "shared",
            "tmp": self.p("t"),
            "layers": {"landlock_min_abi": 9},
        });
        let f = self.p("spec.json");
        std::fs::write(&f, spec.to_string()).unwrap();
        f
    }

    fn run(&self, spec: &Path, extra: &[&str], cmd: &[&str]) -> (Output, serde_json::Value) {
        let result = self.p("result.json");
        let _ = std::fs::remove_file(&result);
        let out = Command::new(RATATOSKR)
            .args(["sandbox", "run", "--tier", "reduced", "--spec"])
            .arg(spec)
            .arg("--result")
            .arg(&result)
            .args(extra)
            .arg("--")
            .args(cmd)
            .env_clear()
            .env("HOME", self.p("home"))
            .env("PATH", "/usr/bin:/bin")
            .stdin(Stdio::null())
            .output()
            .unwrap();
        let text = std::fs::read_to_string(&result).unwrap_or_else(|e| {
            panic!(
                "no result file ({e}); stderr: {}",
                String::from_utf8_lossy(&out.stderr)
            )
        });
        (out, serde_json::from_str(&text).unwrap())
    }
}

#[test]
fn a_reduced_run_through_sandbox_run() {
    if !abi_9("a_reduced_run_through_sandbox_run") {
        return;
    }
    let fx = Fx::new();
    let spec = fx.spec(&fx.p("w"));
    let script = format!(
        "echo hi; echo in > f; (echo x > {o}/f) 2>/dev/null || echo out-refused; \
         (exec 3<>/dev/udp/127.0.0.1/53) 2>/dev/null || echo udp-refused; \
         read -ra st < /proc/$$/stat; echo \"${{st[5]}}\"; echo $$; exit 7",
        o = fx.p("outside").display()
    );
    let (out, result) = fx.run(&spec, &[], &["/bin/bash", "-c", &script]);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(
        out.status.code(),
        Some(7),
        "the child's code; stderr: {stderr}"
    );
    assert_eq!(result["refused"], serde_json::Value::Null, "{result}");
    assert_eq!(result["exit"], 7);
    let layers = &result["layers"];
    assert_eq!(layers["landlock"], "enforced", "{result}");
    assert_eq!(layers["landlock_abi"], 9);
    assert_eq!(layers["seccomp"], true);
    assert_eq!(layers["new_session"], true);
    let stdout = String::from_utf8_lossy(&out.stdout);
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines[..3], ["hi", "out-refused", "udp-refused"], "{stdout}");
    // The program (the helper, exec'd) leads its own session: draugr started it with setsid (GL-T8-1).
    assert_eq!(lines[3], lines[4], "session id = pid: {stdout}");
    assert_eq!(std::fs::read_to_string(fx.p("w/f")).unwrap(), "in\n");
    assert!(!fx.p("outside/f").exists());
}

/// A program killed by a signal exits 128 + the signal, as a shell reports it; a pause FIFO that cannot be opened is
/// a refusal with nothing spawned.
#[test]
fn a_signal_exit_and_a_bad_pause_fifo() {
    if !abi_9("a_signal_exit_and_a_bad_pause_fifo") {
        return;
    }
    let fx = Fx::new();
    let spec = fx.spec(&fx.p("w"));
    let (out, result) = fx.run(&spec, &[], &["/bin/sh", "-c", "kill -9 $$"]);
    assert_eq!(out.status.code(), Some(137), "{result}");
    assert_eq!(result["exit"], 137);
    assert_eq!(result["refused"], serde_json::Value::Null);
    let marker = fx.p("w/marker");
    let fifo = fx.p("no-dir/fifo");
    let (out, result) = fx.run(
        &spec,
        &["--pause-before-spawn", fifo.to_str().unwrap()],
        &["/bin/sh", "-c", &format!("touch {}", marker.display())],
    );
    assert_eq!(out.status.code(), Some(3));
    assert_eq!(result["refused"]["rule"], "Setup", "{result}");
    assert!(!marker.exists());
}

/// The reduced tier's isolated network end to end: a free relay port from `relay_ports` (GL-T8-3), `ratatoskr relay`
/// started by the helper with `--parent-pid` (Gleipnir T11-1), the program reaching the session's socket through it
/// and nothing else, and the relay gone once the program has exited (its parent-death signal).
#[test]
fn the_relay_carries_the_program_to_the_session_socket() {
    use std::io::{BufRead, BufReader, Write};
    if !abi_9("the_relay_carries_the_program_to_the_session_socket") {
        return;
    }
    let fx = Fx::new();
    // The session dir: a direct child of the context's run parent, `<state>/hub/s` (no XDG_RUNTIME_DIR here).
    let s1 = fx.p("home/.local/state/drgnx/hub/s/S1");
    std::fs::create_dir_all(&s1).unwrap();
    let sock = s1.join("proxy.sock");
    let listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
    let server = std::thread::spawn(move || {
        let (mut c, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(&c).read_line(&mut line).unwrap();
        c.write_all(format!("pong {line}").as_bytes()).unwrap();
    });
    let port = gleipnir::backend::relay_ports(gleipnir::Tier::Reduced, &[3128]).unwrap()[0];
    let spec = serde_json::json!({
        "write": [fx.p("w")],
        "sockets": [sock],
        "run": {"mode": "ro", "source": s1, "dest": s1},
        "env": [["PATH", "/usr/bin:/bin"]],
        "chdir": fx.p("w"),
        "net": {"isolated": {"relay": [{"port": port, "socket": sock}]}},
        "tmp": fx.p("t"),
        "layers": {"landlock_min_abi": 9},
    });
    let spec_file = fx.p("spec.json");
    std::fs::write(&spec_file, spec.to_string()).unwrap();
    // A live listener outside: unconfined, a connect to it would complete.
    let other = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let script = format!(
        "exec 3<>/dev/tcp/127.0.0.1/{port} || exit 9; echo ping >&3; read -r l <&3; echo \"$l\"; \
         (exec 4<>/dev/tcp/127.0.0.1/{other}) 2>/dev/null || echo other-refused",
        other = other.local_addr().unwrap().port()
    );
    let (out, result) = fx.run(&spec_file, &[], &["/bin/bash", "-c", &script]);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(0), "{result}; stderr: {stderr}");
    assert_eq!(result["layers"]["relay"], true, "{result}");
    assert_eq!(
        String::from_utf8_lossy(&out.stdout),
        "pong ping\nother-refused\n"
    );
    server.join().unwrap();
    // The program is gone, so the relay is too: its port is free again within a few seconds.
    let gone = (0..60).any(|_| {
        std::thread::sleep(std::time::Duration::from_millis(50));
        std::net::TcpListener::bind(("127.0.0.1", port)).is_ok()
    });
    assert!(gone, "the relay outlived the program");
}

/// A spec the context refuses: exit 3, the rule in the result file, nothing spawned.
#[test]
fn a_refused_spec_spawns_nothing() {
    let fx = Fx::new();
    let spec = fx.spec(&fx.p("home"));
    let marker = fx.p("w/marker");
    let (out, result) = fx.run(
        &spec,
        &[],
        &["/bin/sh", "-c", &format!("touch {}", marker.display())],
    );
    assert_eq!(out.status.code(), Some(3));
    assert_eq!(result["refused"]["rule"], "ExposesUser", "{result}");
    assert_eq!(result["exit"], serde_json::Value::Null);
    assert!(!marker.exists());
}

/// The full tier never falls back to the reduced one: without a bwrap it can trust, it is refused.
#[test]
fn the_full_tier_without_bwrap_is_refused() {
    let fx = Fx::new();
    let spec = fx.spec(&fx.p("w"));
    let result = fx.p("result.json");
    let out = Command::new(RATATOSKR)
        .args(["sandbox", "run", "--tier", "full", "--bwrap"])
        .arg(fx.p("no-bwrap"))
        .arg("--spec")
        .arg(&spec)
        .arg("--result")
        .arg(&result)
        .args(["--", "/bin/true"])
        .env_clear()
        .env("HOME", fx.p("home"))
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(3));
    let r: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&result).unwrap()).unwrap();
    assert_eq!(r["refused"]["rule"], "Malformed", "{r}");
    assert!(
        r["refused"]["message"]
            .as_str()
            .unwrap()
            .contains("bubblewrap")
    );
}

/// `--pause-before-spawn`: `opened` once the sources are open, and nothing runs until a line comes back.
#[test]
fn pause_before_spawn_waits_for_a_line() {
    if !abi_9("pause_before_spawn_waits_for_a_line") {
        return;
    }
    let fx = Fx::new();
    let spec = fx.spec(&fx.p("w"));
    let fifo = fx.p("fifo");
    let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    let marker = fx.p("w/ran");
    let child = Command::new(RATATOSKR)
        .args(["sandbox", "run", "--tier", "reduced", "--spec"])
        .arg(&spec)
        .arg("--result")
        .arg(fx.p("result.json"))
        .arg("--pause-before-spawn")
        .arg(&fifo)
        .args(["--", "/bin/sh", "-c"])
        .arg(format!("touch {}", marker.display()))
        .env_clear()
        .env("HOME", fx.p("home"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    let said = std::fs::read_to_string(&fifo).unwrap();
    assert_eq!(said, "opened\n");
    std::thread::sleep(std::time::Duration::from_millis(300));
    assert!(!marker.exists(), "ran before the line came back");
    std::fs::write(&fifo, "go\n").unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    assert!(marker.exists());
}
