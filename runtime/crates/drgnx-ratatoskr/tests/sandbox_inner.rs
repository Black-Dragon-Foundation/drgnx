//! `ratatoskr sandbox-inner`, the inner helper, run for real without bwrap: fds 3 and 4 passed as the sandbox
//! backends pass them, the status line read with `gleipnir::inner::read_status`. Fixtures live under /tmp/glp-*.
//! Each test skips with the reason when the kernel has no Landlock.
// Linux only: the inner helper is Linux only (Android: no backend; apps get no user namespaces; fails closed).
#![cfg(target_os = "linux")]

use gleipnir::inner::{self, InnerSpec, LayersReport, RelayPlan};
use gleipnir::landlock::{self, LandlockPlan, Tier};
use gleipnir::validate::{Refusal, Rule};
use std::io::{self, Read};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const HELPER: &str = env!("CARGO_BIN_EXE_ratatoskr");
const CANARY: &str = "glp-parent-canary-5b7e";

fn landlock_here(test: &str) -> bool {
    let abi = landlock::kernel_abi();
    if abi == 0 {
        eprintln!("SKIP {test}: the kernel has no Landlock");
    }
    abi > 0
}

fn fixture() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("glp-")
        .tempdir_in("/tmp")
        .unwrap()
}

/// A full-tier plan without bwrap: read everything, write only `dir`.
fn plan(dir: &Path) -> LandlockPlan {
    LandlockPlan {
        tier: Tier::Full,
        min_abi: 1,
        read_roots: vec!["/".into()],
        write_roots: vec![dir.to_owned()],
        dev_write_files: vec!["/dev/null".into()],
        unix_connect_roots: vec![],
        tcp_connect_ports: None,
        tcp_bind_ports: None,
    }
}

fn spec(dir: &Path) -> InnerSpec {
    let mut s = InnerSpec::new(plan(dir));
    s.env = vec![("PATH".into(), "/usr/bin:/bin".into())];
    s.chdir = Some(dir.to_owned());
    s
}

#[derive(Default)]
struct Opts {
    /// Spawn the helper as a process-group leader (`setpgid`), as draugr's `spawn` does.
    pgroup: bool,
    /// Spawn it as a session leader (`setsid` before exec).
    setsid: bool,
    /// Leave a non-CLOEXEC fd 7 open in the helper.
    canary_fd7: bool,
    /// An outer seccomp filter that makes this call fail with EPERM.
    deny: Option<libc::c_long>,
    /// Run the command directly, without the helper (a control).
    bare: bool,
}

struct Outcome {
    status: Result<LayersReport, Refusal>,
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

fn high(fd: &OwnedFd) -> OwnedFd {
    rustix::io::fcntl_dupfd_cloexec(fd, 50).unwrap()
}

/// A filter that answers `nr` with EPERM and allows everything else (test-only: no arch check).
fn deny_filter(nr: libc::c_long) -> Vec<libc::sock_filter> {
    const LD_W_ABS: u16 = 0x20; // BPF_LD | BPF_W | BPF_ABS
    const JEQ_K: u16 = 0x15; // BPF_JMP | BPF_JEQ | BPF_K
    const RET_K: u16 = 0x06; // BPF_RET | BPF_K
    let f = |code, jt, jf, k| libc::sock_filter { code, jt, jf, k };
    vec![
        f(LD_W_ABS, 0, 0, 0),
        f(JEQ_K, 0, 1, u32::try_from(nr).unwrap()),
        f(RET_K, 0, 0, libc::SECCOMP_RET_ERRNO | libc::EPERM as u32),
        f(RET_K, 0, 0, libc::SECCOMP_RET_ALLOW),
    ]
}

/// Run the helper with `spec_fd` at 3 and a status pipe at 4, `cmd` after `--`. The process group (if the helper led
/// one) is killed once the helper's process is gone, so a relay left behind does not outlive the test.
fn run_fd(spec_fd: OwnedFd, cmd: &[&str], o: Opts) -> Outcome {
    let (rd, wr) = inner::status_pipe().unwrap();
    let (hs, hw) = (high(&spec_fd), high(&wr));
    drop((spec_fd, wr));
    let mut c = if o.bare {
        let mut c = Command::new(cmd[0]);
        c.args(&cmd[1..]);
        c
    } else {
        let mut c = Command::new(HELPER);
        c.args(["sandbox-inner", "--spec-fd", "3", "--"]).args(cmd);
        c
    };
    c.env_clear()
        .env("GLP_PARENT_CANARY", CANARY)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if o.pgroup {
        c.process_group(0);
    }
    let (s, w, setsid, canary) = (hs.as_raw_fd(), hw.as_raw_fd(), o.setsid, o.canary_fd7);
    let filter = o.deny.map(deny_filter);
    // SAFETY: only async-signal-safe calls (setsid, dup2, prctl) on values made before the fork.
    unsafe {
        c.pre_exec(move || {
            let fail = || Err(io::Error::last_os_error());
            if setsid && libc::setsid() < 0 {
                return fail();
            }
            if libc::dup2(s, 3) < 0 || libc::dup2(w, 4) < 0 {
                return fail();
            }
            if canary && libc::dup2(2, 7) < 0 {
                return fail();
            }
            if let Some(f) = &filter {
                let prog = libc::sock_fprog {
                    len: f.len() as libc::c_ushort,
                    filter: f.as_ptr().cast_mut(),
                };
                if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
                    || libc::prctl(
                        libc::PR_SET_SECCOMP,
                        libc::SECCOMP_MODE_FILTER,
                        &prog as *const libc::sock_fprog,
                    ) != 0
                {
                    return fail();
                }
            }
            Ok(())
        });
    }
    let mut child = c.spawn().unwrap();
    drop((hs, hw));
    let mut out = child.stdout.take().unwrap();
    let out = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = out.read_to_string(&mut s);
        s
    });
    let err_buf = Arc::new(Mutex::new(String::new()));
    let mut err = child.stderr.take().unwrap();
    let eb = Arc::clone(&err_buf);
    let err = std::thread::spawn(move || {
        let mut chunk = [0u8; 4096];
        while let Ok(n @ 1..) = err.read(&mut chunk) {
            eb.lock()
                .unwrap()
                .push_str(&String::from_utf8_lossy(&chunk[..n]));
        }
    });
    let tail = || err_buf.lock().unwrap().clone();
    let status = inner::read_status(rd, &tail, Duration::from_secs(10));
    let code = child.wait().unwrap().code();
    if o.pgroup || o.setsid {
        // SAFETY: a signal to the process group our own child led.
        unsafe { libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL) };
    }
    let stdout = out.join().unwrap();
    err.join().unwrap();
    let stderr = tail();
    Outcome {
        status,
        code,
        stdout,
        stderr,
    }
}

fn run(spec: &InnerSpec, cmd: &[&str], o: Opts) -> Outcome {
    run_fd(inner::spec_memfd(spec).unwrap(), cmd, o)
}

fn refusal(o: &Outcome) -> &Refusal {
    match &o.status {
        Err(r) => r,
        Ok(l) => panic!("the helper reported ok: {l:?}; stderr {}", o.stderr),
    }
}

#[test]
fn status_reports_layers() {
    if !landlock_here("status_reports_layers") {
        return;
    }
    let dir = fixture();
    let o = run(&spec(dir.path()), &["/usr/bin/pwd"], Opts::default());
    let l = o
        .status
        .as_ref()
        .unwrap_or_else(|r| panic!("{r}: {}", o.stderr));
    assert_eq!(
        l,
        &LayersReport {
            landlock_abi: landlock::effective_abi(landlock::kernel_abi(), None),
            landlock: "enforced".into(),
            seccomp: true,
            no_new_privs: true,
            new_session: false,
            relay: false,
        }
    );
    assert_eq!(o.code, Some(0), "{}", o.stderr);
    assert_eq!(o.stdout.trim_end(), dir.path().to_str().unwrap(), "chdir");
}

#[test]
fn env_is_exactly_the_specs() {
    if !landlock_here("env_is_exactly_the_specs") {
        return;
    }
    let dir = fixture();
    let mut s = spec(dir.path());
    s.env.push(("GLP_X".into(), "x y=z".into()));
    let o = run(&s, &["/usr/bin/cat", "/proc/self/environ"], Opts::default());
    assert_eq!(o.code, Some(0), "{}", o.stderr);
    assert_eq!(o.stdout, "PATH=/usr/bin:/bin\0GLP_X=x y=z\0");
    assert!(!o.stdout.contains(CANARY));
    // A bare name is searched in the spec's PATH, and only there.
    let o = run(&s, &["cat", "/proc/self/environ"], Opts::default());
    assert_eq!(o.code, Some(0), "{}", o.stderr);
    s.env = vec![("PATH".into(), "/nonexistent".into())];
    let o = run(&s, &["cat", "/proc/self/environ"], Opts::default());
    assert!(o.status.is_ok());
    assert_eq!(o.code, Some(inner::EXIT_NOT_FOUND), "{}", o.stderr);
}

/// fd numbers above 2 that `ls -l /proc/self/fd` shows, except ls's own handle on that directory.
fn fds_above_2(listing: &str) -> Vec<u32> {
    listing
        .lines()
        .filter_map(|l| {
            let (left, target) = l.split_once(" -> ")?;
            let n: u32 = left.rsplit(' ').next()?.parse().ok()?;
            (n > 2 && !target.starts_with("/proc/")).then_some(n)
        })
        .collect()
}

#[test]
fn fds_above_2_are_closed() {
    if !landlock_here("fds_above_2_are_closed") {
        return;
    }
    let dir = fixture();
    let ls = ["/usr/bin/ls", "-l", "/proc/self/fd/"];
    let control = run(
        &spec(dir.path()),
        &ls,
        Opts {
            canary_fd7: true,
            bare: true,
            ..Opts::default()
        },
    );
    assert!(
        fds_above_2(&control.stdout).contains(&7),
        "control: fd 7 reaches a bare child: {}",
        control.stdout
    );
    let o = run(
        &spec(dir.path()),
        &ls,
        Opts {
            canary_fd7: true,
            ..Opts::default()
        },
    );
    assert_eq!(o.code, Some(0), "{}", o.stderr);
    assert_eq!(fds_above_2(&o.stdout), Vec::<u32>::new(), "{}", o.stdout);
}

fn status_field(status: &str, name: &str) -> Option<u32> {
    status
        .lines()
        .find_map(|l| l.strip_prefix(name))
        .and_then(|v| v.trim().parse().ok())
}

#[test]
fn no_new_privs_and_seccomp_mode_2() {
    if !landlock_here("no_new_privs_and_seccomp_mode_2") {
        return;
    }
    let dir = fixture();
    let cat = ["/usr/bin/cat", "/proc/self/status"];
    let control = run(
        &spec(dir.path()),
        &cat,
        Opts {
            bare: true,
            ..Opts::default()
        },
    );
    let o = run(&spec(dir.path()), &cat, Opts::default());
    assert_eq!(o.code, Some(0), "{}", o.stderr);
    assert_eq!(status_field(&o.stdout, "NoNewPrivs:"), Some(1));
    assert_eq!(status_field(&o.stdout, "Seccomp:"), Some(2));
    // A container already runs under a filter of its own: the helper adds exactly one.
    let filters = |s: &str| status_field(s, "Seccomp_filters:").unwrap();
    assert_eq!(filters(&o.stdout), filters(&control.stdout) + 1);
}

#[test]
fn below_min_abi_exits_125_with_status() {
    if !landlock_here("below_min_abi_exits_125_with_status") {
        return;
    }
    let dir = fixture();
    let marker = dir.path().join("marker");
    let mut s = spec(dir.path());
    s.landlock.min_abi = 99;
    let o = run(
        &s,
        &["/usr/bin/touch", marker.to_str().unwrap()],
        Opts::default(),
    );
    let r = refusal(&o);
    assert_eq!(r.rule, Rule::Setup);
    assert!(
        r.message.contains("Landlock") && r.message.contains("99"),
        "{}",
        r.message
    );
    assert_eq!(o.code, Some(inner::EXIT_SETUP));
    assert!(!marker.exists(), "nothing was exec'd");
}

fn relay(script: &str, timeout_ms: u32) -> Option<RelayPlan> {
    Some(RelayPlan {
        argv: vec!["/bin/sh".into(), "-c".into(), script.into()],
        ready_timeout_ms: timeout_ms,
    })
}

#[test]
fn relay_ready_before_exec() {
    if !landlock_here("relay_ready_before_exec") {
        return;
    }
    let dir = fixture();
    let d = dir.path().to_str().unwrap();
    let mut s = spec(dir.path());
    s.relay = relay(
        &format!("sleep 0.3; : > {d}/relay-was-here; echo ready >&3; exec sleep 30"),
        5000,
    );
    let check = format!("test -e {d}/relay-was-here && echo after");
    let pg = || Opts {
        pgroup: true,
        ..Opts::default()
    };
    let o = run(&s, &["/bin/sh", "-c", &check], pg());
    assert!(o.status.as_ref().is_ok_and(|l| l.relay), "{}", o.stderr);
    assert_eq!(o.stdout, "after\n");
    // A relay that exits without `ready`, or is not ready in time: 125, and the program never runs.
    let marker = dir.path().join("marker");
    let touch = ["/usr/bin/touch", marker.to_str().unwrap()];
    for (script, timeout, why) in [
        ("exit 0", 5000, "exited before it was ready"),
        ("echo nope >&3; exec sleep 30", 5000, "not ready"),
        ("exec sleep 30", 300, "not ready within 300 ms"),
    ] {
        s.relay = relay(script, timeout);
        let o = run(&s, &touch, pg());
        let r = refusal(&o);
        assert!(r.message.contains(why), "{script}: {}", r.message);
        assert_eq!(o.code, Some(inner::EXIT_SETUP), "{script}");
        assert!(!marker.exists(), "{script}");
    }
}

#[test]
fn an_unsealed_spec_is_refused() {
    if !landlock_here("an_unsealed_spec_is_refused") {
        return;
    }
    let dir = fixture();
    let fd = rustix::fs::memfd_create("unsealed", rustix::fs::MemfdFlags::CLOEXEC).unwrap();
    rustix::io::write(&fd, &serde_json::to_vec(&spec(dir.path())).unwrap()).unwrap();
    let o = run_fd(fd, &["/usr/bin/true"], Opts::default());
    assert!(
        refusal(&o).message.contains("sealed"),
        "{}",
        refusal(&o).message
    );
    assert_eq!(o.code, Some(inner::EXIT_SETUP));
}

/// The session id of the process whose `/proc/PID/stat` is `stat`, and its pid.
fn pid_and_session(stat: &str) -> (u32, u32) {
    let (pid, rest) = stat.split_once(" (").unwrap();
    let fields: Vec<&str> = rest.rsplit_once(") ").unwrap().1.split(' ').collect();
    // state ppid pgrp session …
    (pid.parse().unwrap(), fields[3].parse().unwrap())
}

#[test]
fn reduced_starts_a_new_session() {
    if !landlock_here("reduced_starts_a_new_session") {
        return;
    }
    let dir = fixture();
    let mut s = spec(dir.path());
    s.new_session = true;
    let cat = ["/usr/bin/cat", "/proc/self/stat"];
    // The helper calls setsid itself; and a helper its spawner already made a session leader is accepted.
    for (o, how) in [
        (run(&s, &cat, Opts::default()), "plain"),
        (
            run(
                &s,
                &cat,
                Opts {
                    setsid: true,
                    ..Opts::default()
                },
            ),
            "setsid",
        ),
    ] {
        assert!(
            o.status.as_ref().is_ok_and(|l| l.new_session),
            "{how}: {}",
            o.stderr
        );
        let (pid, sid) = pid_and_session(&o.stdout);
        assert_eq!(sid, pid, "{how}: getsid(0) == getpid()");
    }
    // A process-group leader cannot start a session: refused, never run without one.
    let o = run(
        &s,
        &cat,
        Opts {
            pgroup: true,
            ..Opts::default()
        },
    );
    assert!(
        refusal(&o).message.contains("new session"),
        "{}",
        refusal(&o).message
    );
    assert_eq!(o.code, Some(inner::EXIT_SETUP));
}

/// A wrapper's outer filter makes one setup call fail: exit 125, `ok: false`, and the program never runs.
fn install_failure(nr: libc::c_long, name: &str, want: &str) {
    if !landlock_here(name) {
        return;
    }
    let dir = fixture();
    let marker = dir.path().join("marker");
    let o = run(
        &spec(dir.path()),
        &["/usr/bin/touch", marker.to_str().unwrap()],
        Opts {
            deny: Some(nr),
            ..Opts::default()
        },
    );
    let r = refusal(&o);
    assert_eq!(r.rule, Rule::Setup);
    assert!(r.message.contains(want), "{}", r.message);
    assert_eq!(o.code, Some(inner::EXIT_SETUP));
    assert!(!marker.exists());
}

#[test]
fn seccomp_install_failure_exits_125() {
    install_failure(
        libc::SYS_seccomp,
        "seccomp_install_failure_exits_125",
        "seccomp",
    );
}

#[test]
fn landlock_restrict_failure_exits_125() {
    install_failure(
        libc::SYS_landlock_restrict_self,
        "landlock_restrict_failure_exits_125",
        "Landlock",
    );
}

/// The reduced run path end to end (ABI 9): a validated reduced spec, `reduced::inner_spec` and `prepare`, the
/// helper spawned as a session leader. The program writes its write root and nothing else, and reaches no TCP port.
#[test]
fn a_reduced_run_end_to_end() {
    let abi = landlock::kernel_abi();
    if abi < 9 {
        eprintln!(
            "SKIP a_reduced_run_end_to_end: the kernel's Landlock ABI is {abi}, this needs 9"
        );
        return;
    }
    use gleipnir::backend::linux::reduced;
    use gleipnir::{Layers, Net, Spec, Target};
    let dir = fixture();
    let root = dir.path().canonicalize().unwrap();
    for d in ["home", "w", "t", "out"] {
        std::fs::create_dir(root.join(d)).unwrap();
    }
    let ctx = gleipnir::validate::Context {
        home: root.join("home"),
        ..Default::default()
    };
    let s = Spec {
        read: vec![],
        write: vec![root.join("w")],
        hide: vec![],
        sockets: vec![],
        binds: vec![],
        home: None,
        run: None,
        env: vec![("PATH".into(), "/usr/bin".into())],
        chdir: root.join("w"),
        net: Net::Shared,
        tmp: Some(root.join("t")),
        layers: Layers::for_target(Target::LinuxReduced),
        extra_tcp_ports: vec![],
    };
    let valid = gleipnir::validate::validate(s, &ctx, Target::LinuxReduced).unwrap();
    let inner = reduced::inner_spec(&valid, Path::new(HELPER), &["relay".into()]).unwrap();
    let out = root.join("out");
    // A listener made outside: unconfined, the connect would complete (the backlog takes it).
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let script = format!(
        "echo in > f && pwd && (echo x > {o}/f) 2>/dev/null || echo out-refused; \
         (exec 3<>/dev/tcp/127.0.0.1/{p}) 2>/dev/null || echo tcp-refused",
        o = out.display(),
        p = listener.local_addr().unwrap().port()
    );
    let run = reduced::prepare(
        &inner,
        Path::new(HELPER),
        &["sandbox-inner".into()],
        &["/bin/bash".into(), "-c".into(), script],
    )
    .unwrap();
    assert_eq!(run.fds.len(), 2);
    let mut fds = run.fds.into_iter();
    let (spec_fd, _) = fds.next().unwrap();
    // The prepared argv is what run_fd passes; run it the way Task 13 will (setsid before exec).
    let args: Vec<String> = run
        .args
        .iter()
        .map(|a| a.to_str().unwrap().to_owned())
        .collect();
    assert_eq!(&args[..4], ["sandbox-inner", "--spec-fd", "3", "--"]);
    let cmd: Vec<&str> = args[4..].iter().map(String::as_str).collect();
    drop((fds, run.status));
    let o = run_fd(
        spec_fd,
        &cmd,
        Opts {
            setsid: true,
            ..Opts::default()
        },
    );
    let l = o
        .status
        .as_ref()
        .unwrap_or_else(|r| panic!("{r}: {}", o.stderr));
    assert_eq!((l.landlock_abi, l.new_session, l.relay), (9, true, false));
    assert_eq!(o.code, Some(0), "{}", o.stderr);
    assert_eq!(
        o.stdout,
        format!("{}\nout-refused\ntcp-refused\n", root.join("w").display())
    );
    assert_eq!(std::fs::read_to_string(root.join("w/f")).unwrap(), "in\n");
    assert!(!out.join("f").exists());
}
