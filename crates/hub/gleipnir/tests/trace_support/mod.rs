//! What `trace.rs` and `timing.rs` share: the test binary as its own child, and a supervisor that answers one
//! hand-off at a time.
//!
//! The child is this test binary run again with [`CHILD_ENV`] set, on the test `child` alone: it reads what to do
//! from the variable's JSON, does it, and either execs a command (a "jail": Gleipnir's layers first, then the program)
//! or writes one marker line and exits. Its markers go straight to fd 1 (the harness captures only `print!`).
//!
//! Pattern C (handshake): every traced child announces itself with its hand-off hello and parks on the reply. The test
//! waits on the socket and the child's pidfd together, so a child that dies before it announces fails the test at
//! once, never a wait.
#![allow(dead_code)] // each test file uses part of it

use gleipnir::trace::{self, Handed, ListenOptions, Listener, Offer, Open};
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixListener;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::mpsc;

/// The wrapper, as Claude Code's `CLAUDE_CODE_SHELL_PREFIX` runs it.
pub const WRAPPER: &str = env!("CARGO_BIN_EXE_gleipnir-trace");
/// Set: this process is a child; its value says what to do.
pub const CHILD_ENV: &str = "GLEIPNIR_TRACE_TEST_CHILD";

/// What a child does.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Kid {
    /// `jail`, `io_uring`, `noatime`, `spin`; `opens` (timing.rs's own).
    pub mode: String,
    /// jail: Gleipnir's full-tier deny-list.
    #[serde(default)]
    pub deny: bool,
    /// jail: Landlock with these read roots (and `/dev/null` writable, `unix` connectable).
    #[serde(default)]
    pub landlock: Option<Vec<PathBuf>>,
    #[serde(default)]
    pub unix: Vec<PathBuf>,
    /// jail: a test filter that refuses `openat` with `O_NOATIME` (EPERM), as a deny-list entry would.
    #[serde(default)]
    pub noatime_denied: bool,
    /// jail: a listener of its own first, offered (whole tree) at this socket.
    #[serde(default)]
    pub outer: Option<PathBuf>,
    /// jail: the command to exec.
    #[serde(default)]
    pub exec: Vec<String>,
    /// noatime, opens: the file (opens: a list of paths, one per line).
    #[serde(default)]
    pub file: Option<PathBuf>,
    /// spin, opens: how many.
    #[serde(default)]
    pub n: u64,
}

/// The command line that runs this test binary as a child doing `c`, for a shell.
pub fn child_line(c: &Kid) -> String {
    let exe = std::env::current_exe().unwrap();
    format!(
        "{CHILD_ENV}={} {} --exact child --test-threads 1",
        shell_quote(&serde_json::to_string(c).unwrap()),
        shell_quote(&exe.to_string_lossy())
    )
}

/// The child's argv and environment, to spawn directly.
pub fn child_command(c: &Kid) -> Command {
    let mut cmd = Command::new(std::env::current_exe().unwrap());
    cmd.args(["--exact", "child", "--test-threads", "1"])
        .env(CHILD_ENV, serde_json::to_string(c).unwrap());
    cmd
}

pub fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

fn marker(line: &str) {
    let mut out = std::io::stdout().lock();
    writeln!(out, "{line}").unwrap();
    out.flush().unwrap();
}

/// The child's body: never returns.
pub fn child_main(json: &str) -> ! {
    let c: Kid = serde_json::from_str(json).expect("the child's description");
    match c.mode.as_str() {
        "jail" => jail(&c),
        "io_uring" => {
            let mut params = [0u8; 120];
            // SAFETY: a plain syscall with a buffer the size of `struct io_uring_params`.
            let r = unsafe { libc::syscall(libc::SYS_io_uring_setup, 1u32, params.as_mut_ptr()) };
            let errno = if r < 0 {
                std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
            } else {
                0
            };
            marker(&format!("io_uring: errno {errno}"));
        }
        "noatime" => {
            let f = c.file.as_ref().unwrap();
            let p = std::ffi::CString::new(f.to_string_lossy().as_bytes()).unwrap();
            // SAFETY: a NUL-terminated path; the fds are closed at once.
            let fd = unsafe { libc::open(p.as_ptr(), libc::O_RDONLY | libc::O_NOATIME) };
            let errno = if fd < 0 {
                std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
            } else {
                0
            };
            marker(&format!("noatime: errno {errno}"));
            // SAFETY: as above.
            let fd2 = unsafe { libc::open(p.as_ptr(), libc::O_RDONLY) };
            marker(&format!(
                "plain: {}",
                if fd2 >= 0 { "ok" } else { "failed" }
            ));
        }
        "spin" => {
            // SAFETY: plain syscalls; `st` is a valid buffer.
            let mut st: libc::stat = unsafe { std::mem::zeroed() };
            for _ in 0..c.n {
                unsafe {
                    libc::getppid();
                    libc::fstat(0, &mut st);
                }
            }
            marker("spin: done");
        }
        other => panic!("no child mode {other} (timing.rs runs `opens` itself)"),
    }
    std::process::exit(0)
}

/// Gleipnir's layers in the order the inner helper applies them, then the exec.
fn jail(c: &Kid) -> ! {
    // SAFETY: prctl with constant arguments.
    assert_eq!(
        unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) },
        0
    );
    if let Some(roots) = &c.landlock {
        let plan = gleipnir::landlock::LandlockPlan {
            tier: gleipnir::Tier::Full,
            min_abi: 1,
            read_roots: roots.clone(),
            write_roots: vec![],
            dev_write_files: vec!["/dev/null".into()],
            unix_connect_roots: c.unix.clone(),
            tcp_connect_ports: None,
            tcp_bind_ports: None,
        };
        gleipnir::landlock::restrict(&plan, None).expect("Landlock");
    }
    if c.deny {
        let arch = gleipnir::seccomp::native().unwrap();
        let prog = gleipnir::seccomp::compile_for(arch, gleipnir::Tier::Full).unwrap();
        gleipnir::seccomp::install(&prog).expect("Gleipnir's deny-list");
    }
    if c.noatime_denied {
        deny_noatime();
    }
    if let Some(outer) = &c.outer {
        let got = trace::offer(outer, trace::Scope::Tree, "outer");
        assert_eq!(got, trace::Offered::Traced, "the outer listener");
    }
    let err = Command::new(&c.exec[0])
        .args(&c.exec[1..])
        .env_remove(CHILD_ENV)
        .exec();
    panic!("exec {:?}: {err}", c.exec);
}

/// `openat(…, flags & O_NOATIME)` → EPERM; everything else allowed.
fn deny_noatime() {
    let f = |code: u16, jt: u8, jf: u8, k: u32| libc::sock_filter { code, jt, jf, k };
    const LD_W_ABS: u16 = 0x20;
    const JEQ_K: u16 = 0x15;
    const JSET_K: u16 = 0x45;
    const RET_K: u16 = 0x06;
    let openat = libc::SYS_openat as u32;
    let prog = [
        f(LD_W_ABS, 0, 0, 0),                    // nr
        f(JEQ_K, 0, 3, openat),                  // openat?
        f(LD_W_ABS, 0, 0, 32),                   // args[2], low half (little-endian)
        f(JSET_K, 0, 1, libc::O_NOATIME as u32), // O_NOATIME?
        f(RET_K, 0, 0, 0x0005_0000 | libc::EPERM as u32),
        f(RET_K, 0, 0, 0x7fff_0000),
    ];
    let fprog = libc::sock_fprog {
        len: prog.len() as u16,
        filter: prog.as_ptr() as *mut _,
    };
    // SAFETY: a valid program that outlives the call; no_new_privs is set.
    let r = unsafe { libc::syscall(libc::SYS_seccomp, 1u32, 0u32, &fprog) };
    assert_eq!(r, 0, "{}", std::io::Error::last_os_error());
}

/// The rest of the first line of `out` after `prefix`. The marker may follow the harness's own `test child ... `
/// on the same line (the child test never ends, so its line has no `ok`).
pub fn marker_value(out: &[u8], prefix: &str) -> Option<String> {
    String::from_utf8_lossy(out)
        .lines()
        .find_map(|l| l.find(prefix).map(|i| l[i + prefix.len()..].to_owned()))
}

/// A fixture dir (canonical, so paths compare with what `/proc` says) with the supervisor's socket in it.
pub struct Sup {
    pub dir: tempfile::TempDir,
    pub root: PathBuf,
    pub sock: PathBuf,
    listener: UnixListener,
}

impl Sup {
    pub fn new() -> Sup {
        let dir = tempfile::Builder::new()
            .prefix("glp-trace-")
            .tempdir_in("/tmp")
            .unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        let sock = root.join("trace.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        Sup {
            dir,
            root,
            sock,
            listener,
        }
    }

    pub fn file(&self, rel: &str, text: &str) -> PathBuf {
        let p = self.root.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, text).unwrap();
        p
    }

    /// `gleipnir-trace CMD` in the fixture dir, with the socket set, stdout and stderr piped.
    pub fn wrapper(&self, cmd: &str) -> Command {
        let mut c = Command::new(WRAPPER);
        c.arg(cmd)
            .current_dir(&self.root)
            .env(trace::SOCK_ENV, &self.sock)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        c
    }

    /// The next hand-off, or the child's exit if it ends before announcing (pattern C: socket and pidfd polled
    /// together, no timeout).
    pub fn next(&self, child: &mut Child) -> Offer {
        // SAFETY: pidfd_open on our own child's pid.
        let pidfd = unsafe { libc::syscall(libc::SYS_pidfd_open, child.id() as libc::pid_t, 0u32) };
        assert!(
            pidfd >= 0,
            "pidfd_open: {}",
            std::io::Error::last_os_error()
        );
        // SAFETY: a fresh fd we own.
        let pidfd = unsafe { OwnedFd::from_raw_fd(pidfd as i32) };
        let mut fds = [
            libc::pollfd {
                fd: self.listener.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: pidfd.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        loop {
            // SAFETY: two valid pollfds.
            let r = unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) };
            if r > 0 {
                break;
            }
        }
        if fds[0].revents & libc::POLLIN == 0 {
            let status = child.wait().unwrap();
            let (mut out, mut err) = (String::new(), String::new());
            if let Some(mut o) = child.stdout.take() {
                let _ = o.read_to_string(&mut out);
            }
            if let Some(mut e) = child.stderr.take() {
                let _ = e.read_to_string(&mut err);
            }
            panic!("the child ended before its hand-off: {status:?}\nstdout: {out}\nstderr: {err}");
        }
        let (stream, _) = self.listener.accept().unwrap();
        trace::accept(stream).expect("the hello")
    }

    /// Answer the next hand-off `trace`, and listen with `opts` if a listener came.
    pub fn trace(&self, child: &mut Child, opts: ListenOptions) -> Traced {
        let offer = self.next(child);
        let hello = offer.hello.clone();
        match offer.trace().expect("the hand-off") {
            Handed::Listener(fd) => {
                let (tx, rx) = mpsc::channel();
                let l = trace::listen(fd, opts, tx).expect("listen");
                Traced {
                    hello,
                    listener: Some(l),
                    opens: rx,
                    handed: "listener",
                }
            }
            Handed::Busy => Traced {
                hello,
                listener: None,
                opens: mpsc::channel().1,
                handed: "busy",
            },
            Handed::Failed(why) => panic!("the wrapper failed: {why}"),
        }
    }
}

/// One answered hand-off.
pub struct Traced {
    pub hello: trace::Hello,
    pub listener: Option<Listener>,
    pub opens: mpsc::Receiver<Open>,
    pub handed: &'static str,
}

/// What a traced run saw: full paths read and written, and the count of notifications.
#[derive(Debug, Default)]
pub struct Seen {
    pub reads: Vec<PathBuf>,
    pub writes: Vec<PathBuf>,
    pub opens: Vec<Open>,
    pub notifications: u64,
}

impl Traced {
    /// After the child is reaped: the listener ends on its own (every traced task gone), and what it saw.
    pub fn finish(self) -> Seen {
        let Some(l) = self.listener else {
            return Seen::default();
        };
        let ended = l.join();
        let opens: Vec<Open> = self.opens.try_iter().collect();
        let mut s = Seen {
            notifications: ended.notifications,
            ..Seen::default()
        };
        for o in &opens {
            if let Some(p) = o.full() {
                if o.writes() {
                    s.writes.push(p);
                } else {
                    s.reads.push(p);
                }
            }
        }
        s.opens = opens;
        s
    }
}

pub fn run(child: Child) -> Output {
    child.wait_with_output().unwrap()
}

pub fn path_list(paths: &[&Path]) -> Vec<PathBuf> {
    paths.iter().map(|p| p.to_path_buf()).collect()
}

pub fn spawn(mut c: Command) -> Child {
    c.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}
