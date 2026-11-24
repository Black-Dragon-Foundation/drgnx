//! The probe binary on its own (Task 14): its lines are valid, it separates probes with `--and`, it reports
//! errnos by name, it never prints file contents, and every `syscall` name runs to a result.

use gleipnir_escape::ProbeLine;
use std::ffi::{OsStr, OsString};
use std::path::Path;
use std::time::Duration;

const PROBE: &str = env!("CARGO_BIN_EXE_gleipnir-probe");

/// How long a probe run may take before its process group is ended.
const DEADLINE: Duration = Duration::from_secs(120);

/// The probe run to its end with 0–2 only (draugr passes nothing else: a GitHub runner's pipes would be listed by
/// `fds`), and as its environment `PATH`, `TMPDIR`, `RUST_BACKTRACE` and EXTRA.
fn run_probe(args: &[&str], extra: &[(&str, &str)]) -> draugr::Output {
    let set: Vec<(&str, &OsStr)> = extra.iter().map(|(k, v)| (*k, OsStr::new(v))).collect();
    let spec = draugr::Spec {
        program: PROBE.into(),
        args: args.iter().map(OsString::from).collect(),
        env: draugr::env::build(&["PATH", "TMPDIR", "RUST_BACKTRACE"], &[], &set),
        cwd: None,
        stdin_null: true,
        pass_fds: Vec::new(),
        new_session: false,
    };
    draugr::run(spec, DEADLINE).unwrap()
}

/// The probe's lines and its exit code.
fn probe(args: &[&str]) -> (Vec<ProbeLine>, i32) {
    let out = run_probe(args, &[]);
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
    // a true name: eitri refuses a link in a path
    let root = dir.path().canonicalize().unwrap();
    let f = root.join("f");
    eitri::replace_file(&f, b"SECRET-CONTENT").unwrap();
    let f = f.to_str().unwrap();
    let missing = root.join("missing");
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
    let raw = run_probe(&["read", f], &[]);
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
        "--and",
        "tcp-self",
        "127.0.0.1:0",
    ]);
    let r: Vec<&str> = lines.iter().map(|l| l.result.as_str()).collect();
    assert_eq!(
        r,
        [
            "reached", "reached", "reached", "reached", "reached", "blocked", "reached", "reached"
        ],
        "{lines:?}"
    );
    assert_eq!(lines[3].detail.as_deref(), Some("a,b"));
    assert_eq!(
        lines[5].errno.as_deref(),
        Some("ENOENT"),
        "unix-self removes its socket"
    );
    let out = run_probe(&["env-has", "GLP_SET", "GLP_UNSET"], &[("GLP_SET", "v")]);
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
    let t = saman::spawn_thread("connect-server", move || {
        for status in ["200 Connection established", "403 Forbidden"] {
            let (mut s, _) = l.accept().unwrap();
            // The whole request head before the answer: the probe sends it in several writes, and closing with
            // some of it unread resets the connection (Linux), which fails the probe's next write.
            let (mut head, mut b) = (Vec::new(), [0u8; 1]);
            while !head.ends_with(b"\r\n\r\n") && s.read(&mut b).unwrap() == 1 {
                head.push(b[0]);
            }
            write!(s, "HTTP/1.1 {status}\r\n\r\n").unwrap();
        }
    })
    .unwrap();
    let run = |target: &str| {
        let out = run_probe(
            &["http-connect", target],
            &[("HTTPS_PROXY", &format!("http://{addr}"))],
        );
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
    // the probe's environment is its own: no proxy variable in it
    let out = run_probe(&["http-connect", "x:1"], &[]);
    assert_eq!(
        serde_json::from_slice::<ProbeLine>(&out.stdout)
            .unwrap()
            .result,
        "blocked"
    );
}

#[test]
fn http_get_sends_absolute_form_and_reads_the_answer() {
    use std::io::{Read, Write};
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    let t = saman::spawn_thread("get-server", move || {
        let mut heads = Vec::new();
        for answer in [
            "200 OK\r\nX-Glp-Host: a.test\r\nOther: x",
            "400 Bad Request",
        ] {
            let (mut s, _) = l.accept().unwrap();
            let (mut head, mut b) = (Vec::new(), [0u8; 1]);
            while !head.ends_with(b"\r\n\r\n") && s.read(&mut b).unwrap() == 1 {
                head.push(b[0]);
            }
            heads.push(String::from_utf8(head).unwrap());
            write!(s, "HTTP/1.1 {answer}\r\n\r\n").unwrap();
        }
        heads
    })
    .unwrap();
    let run = |url: &str| {
        let out = run_probe(
            &["http-get", url],
            &[("HTTPS_PROXY", &format!("http://{addr}"))],
        );
        serde_json::from_slice::<ProbeLine>(&out.stdout).unwrap()
    };
    let (ok, no) = (run("http://a.test/x?q=1"), run("http://u:p@b.test:8080/"));
    assert_eq!(
        (ok.result.as_str(), ok.detail.as_deref()),
        ("reached", Some("200 host=a.test"))
    );
    assert_eq!(
        (no.result.as_str(), no.detail.as_deref()),
        ("blocked", Some("400"))
    );
    let heads = t.join().unwrap();
    assert!(
        heads[0].starts_with("GET http://a.test/x?q=1 HTTP/1.1\r\nHost: a.test\r\n"),
        "{:?}",
        heads[0]
    );
    for h in [
        "Proxy-Authorization:",
        "Keep-Alive:",
        "TE:",
        "Upgrade:",
        "X-Glp-Hop:",
        "X-Glp-End:",
    ] {
        assert!(heads[0].contains(h), "{h} is not sent: {:?}", heads[0]);
    }
    assert!(
        heads[1].contains("\r\nHost: b.test:8080\r\n"),
        "{:?}",
        heads[1]
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
        "pidfd-getfd",
        "process-vm-readv",
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
    // mount on a path that does not exist: ENOENT unfiltered, EPERM under the sandbox's filter. These are Linux
    // syscalls; off Linux (macOS, Android) the probe makes none of them and says ENOSYS, and only Linux rows use them.
    let (l, _) = probe(&["syscall", "mount-missing"]);
    let want: &[&str] = if cfg!(target_os = "linux") {
        &["ENOENT", "EPERM"]
    } else {
        &["ENOSYS"]
    };
    assert!(
        l[0].errno.as_deref().is_some_and(|e| want.contains(&e)),
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
        let out = run_probe(args, &[]);
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
        &["--as-browser"],
        &["--stand-in", "/d", "@x"],
        &["--stand-in", "/d", "@x", "port"],
    ] {
        let out = run_probe(args, &[]);
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
    // a true name: eitri refuses a link in a path
    let root = dir.path().canonicalize().unwrap();
    let p = |n: &str| root.join(n).to_string_lossy().into_owned();
    let (d, a, b) = (p("d"), p("a"), p("b"));
    eitri::replace_file(Path::new(&a), b"A").unwrap();
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
    eitri::replace_file(Path::new(&a), b"A").unwrap();
    let (l, _) = probe(&["swap", &a, &b]);
    assert_eq!(l[0].result, "reached", "{l:?}");
    assert!(std::fs::metadata(&a).unwrap().is_dir());
    assert_eq!(eitri::read_string(Path::new(&b), 16).unwrap(), "A");
}
