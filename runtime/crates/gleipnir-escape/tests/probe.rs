//! The probe binary on its own (Task 14): its lines are valid, it separates probes with `--and`, it reports
//! errnos by name, it never prints file contents, and every `syscall` name runs to a result.

use gleipnir_escape::ProbeLine;
use std::process::Command;

const PROBE: &str = env!("CARGO_BIN_EXE_gleipnir-probe");

/// The probe with 0–2 only, whatever this test inherited (a GitHub runner's pipes: `fds` would list them).
fn probe(args: &[&str]) -> (Vec<ProbeLine>, i32) {
    let mut cmd = Command::new(PROBE);
    gleipnir_escape::only_stdio(cmd.args(args));
    let out = cmd.output().unwrap();
    let lines = String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("{l:?}: {e}")))
        .collect();
    (lines, out.status.code().unwrap())
}

#[test]
fn one_line_per_probe_and_errnos_by_name() {
    let dir = tempfile::tempdir().unwrap();
    let f = dir.path().join("f");
    std::fs::write(&f, "SECRET-CONTENT").unwrap();
    let f = f.to_str().unwrap();
    let missing = dir.path().join("missing");
    let missing = missing.to_str().unwrap();
    let (lines, code) = probe(&[
        "read", f, "--and", "read", missing, "--and", "stat", f, "--and", "fds",
    ]);
    assert_eq!(code, 0);
    assert_eq!(lines.len(), 4);
    assert_eq!(
        (lines[0].result.as_str(), lines[0].detail.as_deref()),
        ("reached", Some("14"))
    );
    assert_eq!(
        (lines[1].result.as_str(), lines[1].errno.as_deref()),
        ("blocked", Some("ENOENT"))
    );
    assert_eq!(lines[2].detail.as_deref(), Some("14"));
    assert_eq!(lines[3].detail.as_deref(), Some("0,1,2"));
    let raw = Command::new(PROBE).args(["read", f]).output().unwrap();
    assert!(
        !String::from_utf8_lossy(&raw.stdout).contains("SECRET"),
        "read reports the size only"
    );
}

#[test]
fn files_sockets_and_environment() {
    let dir = tempfile::tempdir().unwrap();
    let p = |n: &str| dir.path().join(n).to_string_lossy().into_owned();
    let (a, b, sock) = (p("a"), p("b"), p("s"));
    let (lines, _) = probe(&[
        "create",
        &a,
        "--and",
        "rename",
        &a,
        &b,
        "--and",
        "link",
        &b,
        &a,
        "--and",
        "list",
        dir.path().to_str().unwrap(),
        "--and",
        "unix-self",
        &sock,
        "--and",
        "connect-unix",
        &sock,
        "--and",
        "write",
        &b,
    ]);
    let r: Vec<&str> = lines.iter().map(|l| l.result.as_str()).collect();
    assert_eq!(
        r,
        [
            "reached", "reached", "reached", "reached", "reached", "blocked", "reached"
        ],
        "{lines:?}"
    );
    assert_eq!(lines[3].detail.as_deref(), Some("a,b"));
    assert_eq!(
        lines[5].errno.as_deref(),
        Some("ENOENT"),
        "unix-self removes its socket"
    );
    let out = Command::new(PROBE)
        .args(["env-has", "GLP_SET", "GLP_UNSET"])
        .env("GLP_SET", "v")
        .output()
        .unwrap();
    let l: ProbeLine = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(
        (l.result.as_str(), l.detail.as_deref()),
        ("reached", Some("GLP_SET")),
        "names, never values"
    );
    let (l, _) = probe(&["env-has", "GLP_UNSET_X"]);
    assert_eq!(
        (l[0].result.as_str(), l[0].detail.as_deref()),
        ("blocked", Some("none present"))
    );
}

#[test]
fn run_counts_output_and_reports_the_exit() {
    let (l, _) = probe(&[
        "run",
        "sh",
        "-c",
        "echo hello",
        "--and",
        "run",
        "sh",
        "-c",
        "exit 4",
        "--and",
        "run",
        "/nonexistent-glp",
    ]);
    assert_eq!(
        (l[0].result.as_str(), l[0].detail.as_deref(), l[0].out_bytes),
        ("reached", Some("0"), Some(6))
    );
    assert_eq!(
        (l[1].result.as_str(), l[1].detail.as_deref()),
        ("blocked", Some("4"))
    );
    assert_eq!(
        (l[2].result.as_str(), l[2].errno.as_deref()),
        ("blocked", Some("ENOENT"))
    );
}

#[test]
fn spawn_sleep_leaves_a_child_and_kill_reaches_it() {
    let (l, _) = probe(&["spawn-sleep", "30"]);
    let pid = l[0].detail.clone().unwrap();
    let (l, _) = probe(&[
        "kill",
        &pid,
        "0",
        "--and",
        "kill",
        &pid,
        "KILL",
        "--and",
        "kill",
        "999999999",
        "0",
    ]);
    assert_eq!(l[0].result, "reached");
    assert_eq!(l[1].result, "reached");
    assert_eq!(l[2].errno.as_deref(), Some("ESRCH"));
}

#[test]
fn http_connect_reads_the_status_code() {
    use std::io::{Read, Write};
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    let t = std::thread::spawn(move || {
        for status in ["200 Connection established", "403 Forbidden"] {
            let (mut s, _) = l.accept().unwrap();
            let mut buf = [0u8; 512];
            let _ = s.read(&mut buf);
            write!(s, "HTTP/1.1 {status}\r\n\r\n").unwrap();
        }
    });
    let run = |target: &str| {
        let out = Command::new(PROBE)
            .args(["http-connect", target])
            .env("HTTPS_PROXY", format!("http://{addr}"))
            .output()
            .unwrap();
        serde_json::from_slice::<ProbeLine>(&out.stdout).unwrap()
    };
    let (ok, no) = (run("a.test:443"), run("b.test:443"));
    assert_eq!(
        (ok.result.as_str(), ok.detail.as_deref()),
        ("reached", Some("200"))
    );
    assert_eq!(
        (no.result.as_str(), no.detail.as_deref()),
        ("blocked", Some("403"))
    );
    t.join().unwrap();
    let out = Command::new(PROBE)
        .args(["http-connect", "x:1"])
        .env_remove("HTTPS_PROXY")
        .env_remove("https_proxy")
        .output()
        .unwrap();
    assert_eq!(
        serde_json::from_slice::<ProbeLine>(&out.stdout)
            .unwrap()
            .result,
        "blocked"
    );
}

#[test]
fn every_syscall_name_runs_to_a_result() {
    for name in [
        "unshare-user",
        "io-uring",
        "keyctl",
        "add-key",
        "vsock",
        "clone3",
        "clone-newuser",
        "mount-missing",
        "tiocsti-own-pty",
        "tiocsti-high-own-pty",
        "ptrace-own-child",
        "x32-getpid",
        "i386-int80",
    ] {
        let (l, code) = probe(&["syscall", name]);
        assert_eq!(code, 0, "{name}");
        assert_eq!(l.len(), 1, "{name}");
        // Whatever the host's own filter does, the line is well formed and says why.
        assert!(
            l[0].result == "reached" || l[0].errno.is_some() || l[0].detail.is_some(),
            "{name}: {:?}",
            l[0]
        );
    }
    // mount on a path that does not exist: ENOENT unfiltered, EPERM under the sandbox's filter.
    let (l, _) = probe(&["syscall", "mount-missing"]);
    assert!(
        matches!(l[0].errno.as_deref(), Some("ENOENT" | "EPERM")),
        "{:?}",
        l[0]
    );
}

/// `bind-tcp` and `socket` (Task 15, for the reduced tier's network rows).
#[cfg(target_os = "linux")]
#[test]
fn bind_and_socket_probes() {
    let (l, code) = probe(&[
        "bind-tcp",
        "127.0.0.1:0",
        "--and",
        "socket",
        "unix",
        "stream",
        "--and",
        "socket",
        "inet",
        "stream",
        "tcp",
        "--and",
        "socket",
        "inet6",
        "dgram",
        "--and",
        "socket",
        "inet",
        "stream",
        "200",
    ]);
    assert_eq!(code, 0);
    let got: Vec<&str> = l.iter().map(|l| l.result.as_str()).collect();
    assert_eq!(got[..3], ["reached", "reached", "reached"], "{l:?}");
    // IPv6 may be off in a container: reached, or a refusal by errno, never a bad line.
    assert!(
        l[3].result == "reached" || l[3].errno.is_some(),
        "{:?}",
        l[3]
    );
    assert_eq!(
        (l[4].result.as_str(), l[4].errno.as_deref()),
        ("blocked", Some("EPROTONOSUPPORT"))
    );
    for args in [&["socket", "nope", "stream"][..], &["socket", "inet"]] {
        let out = Command::new(PROBE).args(args).output().unwrap();
        assert_eq!(out.status.code(), Some(2), "{args:?}");
    }
}

#[test]
fn bad_usage_exits_2() {
    for args in [
        &[][..],
        &["nonsense"],
        &["read"],
        &["read", "/x", "--and"],
        &["syscall", "nope"],
    ] {
        let out = Command::new(PROBE).args(args).output().unwrap();
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        assert!(
            out.stdout.is_empty(),
            "{args:?}: no probe line on a usage error"
        );
    }
}

#[test]
fn the_landlock_probe_reports_a_version_or_why_not() {
    let (l, _) = probe(&["landlock-abi"]);
    if l[0].result == "reached" {
        assert!(l[0].detail.as_deref().unwrap().parse::<u32>().unwrap() >= 1);
    } else {
        assert!(l[0].errno.is_some());
    }
}

#[test]
fn mkdir_unlink_and_swap() {
    let dir = tempfile::tempdir().unwrap();
    let p = |n: &str| dir.path().join(n).to_string_lossy().into_owned();
    let (d, a, b) = (p("d"), p("a"), p("b"));
    std::fs::write(&a, "A").unwrap();
    std::fs::create_dir(&b).unwrap();
    let (l, _) = probe(&[
        "mkdir", &d, "--and", "mkdir", &d, "--and", "unlink", &a, "--and", "unlink", &a,
    ]);
    let r: Vec<(&str, Option<&str>)> = l
        .iter()
        .map(|x| (x.result.as_str(), x.errno.as_deref()))
        .collect();
    assert_eq!(
        r,
        [
            ("reached", None),
            ("blocked", Some("EEXIST")),
            ("reached", None),
            ("blocked", Some("ENOENT"))
        ]
    );
    // swap exchanges a file and a directory in place; both names keep existing (Linux renameat2, macOS renamex_np).
    std::fs::write(&a, "A").unwrap();
    let (l, _) = probe(&["swap", &a, &b]);
    assert_eq!(l[0].result, "reached", "{l:?}");
    assert!(std::fs::metadata(&a).unwrap().is_dir());
    assert_eq!(std::fs::read_to_string(&b).unwrap(), "A");
}
