//! `ratatoskr browser-host`: Chromium over a pipe, inside the session's sandbox, started and stopped by the hub
//! (docs/develop/hub.md, "The browser host").
//!
//! The inner helper forks it under the browser layer (its own Landlock domain and seccomp filter) with the hub's end
//! of a socketpair at fd 3 and a ready pipe at fd 4. The host makes `DIR/profile` and `DIR/downloads`, says `ready`,
//! and then reads frames (`heimdall::codec`) from the hub:
//! - `{"op":"start"}` starts Chromium with the fixed flags, the CDP pipe at its fds 3 and 4, and only `HOME`,
//!   `XDG_CACHE_HOME` and `TMPDIR` (all `DIR`) in its environment; the host answers `{"ev":"started","pid":N}`;
//! - a CDP frame goes to Chromium's pipe, and each NUL-ended message from the pipe comes back as one;
//! - `{"op":"stop","why":W}` closes the pipe, sends SIGTERM to Chromium's process group, and SIGKILL after 2 s;
//! - Chromium's end, stopped or not, is `{"ev":"exited","code":N|null,"signal":N|null}`, after its process group is
//!   killed, so nothing of it is left;
//! - EOF on the hub's end (the hub is gone) stops Chromium, and the host exits 0.
//!
//! Chromium's stderr lines go out as `{"ev":"stderr","line":S}`, at most one a second, and its last 16 KiB are kept
//! in `DIR/stderr.tail`.
//!
//! The host refuses to run unless it is layered ([`check_layered`]); only a `test-hooks` build has `--unconfined`.
//! There is no async runtime: one thread reads the hub, and each started Chromium gets a writer, a reader, a stderr
//! reader and a waiter thread.

use std::collections::VecDeque;
use std::ffi::{CString, OsString};
use std::fs::File;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use heimdall::codec::{FrameDecoder, HEADER_LEN, KIND_CDP, KIND_CONTROL, Nul};
use serde_json::{Value, json};

/// The largest CDP message by default (`agents-browser-max-message`); the hub passes its setting as `--max-message`.
pub const DEFAULT_MAX_MESSAGE: usize = 64 << 20;
/// A frame from the hub may be this much over the message limit (its control JSON, a CDP message's frame).
pub const FRAME_SLACK: usize = 64;
/// How long a stopped Chromium has between SIGTERM and SIGKILL.
pub const STOP_GRACE: Duration = Duration::from_secs(2);
/// How much of Chromium's stderr `DIR/stderr.tail` keeps.
pub const STDERR_TAIL_MAX: usize = 16 * 1024;
/// At most one `stderr` event per this.
pub const STDERR_EVERY: Duration = Duration::from_secs(1);
/// The file in `DIR` with the tail of Chromium's stderr.
pub const STDERR_TAIL_FILE: &str = "stderr.tail";
/// A longer stderr line is cut into pieces of this size.
const LINE_MAX: usize = 4096;
/// After Chromium's main process ends, how long its pipe's last messages may take to come through.
const DRAIN: Duration = Duration::from_secs(1);
/// Exit: the hub's end closed (the usual way the host ends).
pub const EXIT_OK: i32 = 0;
/// Exit: the host refused to run, or the hub's stream broke.
pub const EXIT_FAILED: i32 = 1;
/// Exit: the arguments do not parse.
pub const EXIT_USAGE: i32 = 2;

/// What the host runs: its arguments but the fds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostCfg {
    /// The Chromium binary (absolute).
    pub program: PathBuf,
    /// The browser's own dir: its profile, downloads, cache and temporary files.
    pub dir: PathBuf,
    /// The web relay's port inside the sandbox: Chromium's proxy.
    pub web_port: u16,
    /// The largest CDP message, either way.
    pub max_message: usize,
    /// `--headless-shell`: the program is `chrome-headless-shell`, which takes no `--headless`.
    pub headless_shell: bool,
}

/// `browser-host`'s arguments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostArgs {
    pub hub_fd: RawFd,
    pub ready_fd: RawFd,
    pub cfg: HostCfg,
    /// `--unconfined` (test-hooks builds only): run without the layer check, for the container tests.
    pub unconfined: bool,
}

/// `--hub-fd N --ready-fd N --program P --dir D --web-port N [--max-message B] [--headless-shell|--full]
/// [--unconfined]`.
pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<HostArgs, String> {
    use lexopt::Arg::Long;
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| e.to_string();
    let (mut hub_fd, mut ready_fd, mut program, mut dir, mut web_port) =
        (None, None, None, None, None);
    let mut max_message = DEFAULT_MAX_MESSAGE;
    let mut kind: Option<bool> = None;
    #[cfg_attr(not(feature = "test-hooks"), allow(unused_mut))]
    let mut unconfined = false;
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("hub-fd") => hub_fd = Some(p.value().map_err(e)?.parse::<RawFd>().map_err(e)?),
            Long("ready-fd") => ready_fd = Some(p.value().map_err(e)?.parse::<RawFd>().map_err(e)?),
            Long("program") => program = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("dir") => dir = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("web-port") => web_port = Some(p.value().map_err(e)?.parse::<u16>().map_err(e)?),
            Long("max-message") => {
                max_message = p.value().map_err(e)?.parse::<usize>().map_err(e)?
            }
            Long("headless-shell") if kind.is_none() => kind = Some(true),
            Long("full") if kind.is_none() => kind = Some(false),
            #[cfg(feature = "test-hooks")]
            Long("unconfined") => unconfined = true,
            other => return Err(other.unexpected().to_string()),
        }
    }
    let need = |what: &str| format!("browser-host needs --{what}");
    let hub_fd = hub_fd.ok_or_else(|| need("hub-fd"))?;
    let ready_fd = ready_fd.ok_or_else(|| need("ready-fd"))?;
    let program = program.ok_or_else(|| need("program"))?;
    let dir = dir.ok_or_else(|| need("dir"))?;
    let web_port = web_port.ok_or_else(|| need("web-port"))?;
    if hub_fd < 3 || ready_fd < 3 || hub_fd == ready_fd {
        return Err(format!(
            "the hub's fd ({hub_fd}) and the ready fd ({ready_fd}) must be two numbers from 3"
        ));
    }
    for (name, path) in [("program", &program), ("dir", &dir)] {
        if !path.is_absolute() || path.to_str().is_none() {
            return Err(format!(
                "--{name} must be an absolute UTF-8 path: {}",
                path.display()
            ));
        }
    }
    if web_port == 0 || max_message == 0 {
        return Err("--web-port and --max-message must be above 0".into());
    }
    Ok(HostArgs {
        hub_fd,
        ready_fd,
        cfg: HostCfg {
            program,
            dir,
            web_port,
            max_message,
            headless_shell: kind.unwrap_or(false),
        },
        unconfined,
    })
}

/// `ratatoskr browser-host …`: parse, check the layer, take the two fds, [`serve`]. Its exit code.
pub fn main(args: Vec<OsString>) -> i32 {
    let a = match parse(args) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("ratatoskr browser-host: {e}");
            return EXIT_USAGE;
        }
    };
    // before anything else: an unlayered host touches no fd and makes no dir
    if !a.unconfined
        && let Err(why) = check_layered()
    {
        eprintln!("ratatoskr browser-host: refusing to run outside the browser layer: {why}");
        return EXIT_FAILED;
    }
    let (hub, ready) = match (take_fd(a.hub_fd), take_fd(a.ready_fd)) {
        (Ok(h), Ok(r)) => (h, r),
        (Err(e), _) | (_, Err(e)) => {
            eprintln!("ratatoskr browser-host: {e}");
            return EXIT_FAILED;
        }
    };
    serve(&a.cfg, hub, ready)
}

/// Whether this process runs under the browser layer: `no_new_privs` is set (`/proc/self/status`), and a TCP bind on
/// loopback is refused. The browser layer binds no port at all; the agent's own layer and an unsandboxed process may.
pub fn check_layered() -> Result<(), String> {
    let status = std::fs::read_to_string("/proc/self/status")
        .map_err(|e| format!("cannot read /proc/self/status: {e}"))?;
    let nnp = status
        .lines()
        .find_map(|l| l.strip_prefix("NoNewPrivs:"))
        .map(str::trim);
    if nnp != Some("1") {
        return Err("no_new_privs is not set".into());
    }
    match std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)) {
        Ok(_) => Err("a TCP bind on loopback was allowed, which the browser layer refuses".into()),
        Err(e) if matches!(e.raw_os_error(), Some(libc::EACCES | libc::EPERM)) => Ok(()),
        Err(e) => Err(format!(
            "a TCP bind on loopback failed, but was not refused: {e}"
        )),
    }
}

/// The fd at `fd`, which must be open.
fn take_fd(fd: RawFd) -> Result<OwnedFd, String> {
    // SAFETY: F_GETFD only asks whether the number is an open descriptor.
    if unsafe { libc::fcntl(fd, libc::F_GETFD) } < 0 {
        return Err(format!("no descriptor at fd {fd}"));
    }
    // SAFETY: the helper passed it at this number for the host alone, and nothing else in this process owns it.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// A duplicate of `fd` at 10 or above, close-on-exec: never at a number a child's `dup2` writes to.
fn high(fd: &OwnedFd) -> io::Result<OwnedFd> {
    // SAFETY: F_DUPFD_CLOEXEC makes a new descriptor, which nothing else owns.
    let n = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 10) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `n` was just made, for this owner alone.
    Ok(unsafe { OwnedFd::from_raw_fd(n) })
}

/// Chromium's argv: the program, then exactly the flags of the design's Global Constraints, `--headless` unless the
/// program is the headless shell, and `about:blank`.
pub fn chromium_argv(cfg: &HostCfg) -> Vec<String> {
    let dir = cfg.dir.to_string_lossy();
    let mut v: Vec<String> = vec![
        cfg.program.to_string_lossy().into_owned(),
        "--remote-debugging-pipe".into(),
        format!("--user-data-dir={dir}/profile"),
        "--no-sandbox".into(),
        "--disable-gpu".into(),
        format!("--proxy-server=http://127.0.0.1:{}", cfg.web_port),
        "--no-first-run".into(),
        "--no-default-browser-check".into(),
        "--disable-background-networking".into(),
        "--disable-component-update".into(),
        "--disable-sync".into(),
        "--disable-crash-reporter".into(),
        "--disable-breakpad".into(),
        "--disk-cache-size=67108864".into(),
        "--renderer-process-limit=4".into(),
    ];
    if !cfg.headless_shell {
        v.push("--headless".into());
    }
    v.push("about:blank".into());
    v
}

/// Chromium's whole environment: `HOME`, `XDG_CACHE_HOME` and `TMPDIR`, each the browser's own dir.
pub fn chromium_env(cfg: &HostCfg) -> Vec<(String, String)> {
    let dir = cfg.dir.to_string_lossy().into_owned();
    ["HOME", "XDG_CACHE_HOME", "TMPDIR"]
        .map(|k| (k.to_owned(), dir.clone()))
        .to_vec()
}

/// The host's work after the checks: make the dirs, say `ready` on `ready`, then serve the hub on `hub` until it
/// closes. Its exit code: [`EXIT_OK`] after the hub's EOF, [`EXIT_FAILED`] when the stream broke.
pub fn serve(cfg: &HostCfg, hub: OwnedFd, ready: OwnedFd) -> i32 {
    let fail = |what: String| {
        eprintln!("ratatoskr browser-host: {what}");
        EXIT_FAILED
    };
    // off fd 3, where the inherited end is not close-on-exec
    let moved = high(&hub);
    drop(hub);
    let hub = match moved {
        Ok(h) => h,
        Err(e) => return fail(format!("the hub's fd: {e}")),
    };
    for sub in ["profile", "downloads"] {
        let d = cfg.dir.join(sub);
        let made = std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&d)
            .and_then(|()| std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o700)));
        if let Err(e) = made {
            return fail(format!("{}: {e}", d.display()));
        }
    }
    let mut ready = File::from(ready);
    if let Err(e) = ready.write_all(b"ready\n") {
        return fail(format!("the ready line: {e}"));
    }
    drop(ready);
    let mut input = File::from(hub);
    let out = match input.try_clone() {
        Ok(w) => Out(Arc::new(Mutex::new(w))),
        Err(e) => return fail(format!("the hub's fd: {e}")),
    };
    let sink = Arc::new(StderrSink::new(cfg.dir.join(STDERR_TAIL_FILE), out.clone()));
    let mut decoder = FrameDecoder::new(cfg.max_message + FRAME_SLACK);
    let mut browser: Option<Browser> = None;
    let mut buf = vec![0u8; 64 * 1024];
    let code = loop {
        let n = match input.read(&mut buf) {
            Ok(0) => break EXIT_OK,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => break fail(format!("reading the hub: {e}")),
        };
        let frames = match decoder.push(&buf[..n]) {
            Ok(f) => f,
            Err(e) => break fail(format!("the hub's stream: {e}")),
        };
        for f in frames {
            if browser.as_ref().is_some_and(Browser::ended) {
                browser = None;
            }
            match f.kind {
                KIND_CDP => match &browser {
                    Some(b) => b.send(f.payload),
                    None => eprintln!(
                        "ratatoskr browser-host: a CDP message while no browser runs: dropped"
                    ),
                },
                KIND_CONTROL => control(cfg, &f.payload, &mut browser, &out, &sink),
                k => eprintln!("ratatoskr browser-host: a frame of unknown kind {k}: dropped"),
            }
        }
    };
    if let Some(b) = browser.take() {
        b.stop("hub");
    }
    code
}

/// One control frame from the hub.
fn control(
    cfg: &HostCfg,
    payload: &[u8],
    browser: &mut Option<Browser>,
    out: &Out,
    sink: &Arc<StderrSink>,
) {
    let v: Value = serde_json::from_slice(payload).unwrap_or(Value::Null);
    match v["op"].as_str() {
        Some("start") => match browser {
            // a start that crossed an `exited` on its way gets the running one
            Some(b) => out.control(json!({"ev": "started", "pid": b.pid})),
            None => *browser = Browser::start(cfg, out, sink),
        },
        Some("stop") => {
            if let Some(b) = browser.take() {
                b.stop(v["why"].as_str().unwrap_or("unknown"));
            }
        }
        _ => eprintln!(
            "ratatoskr browser-host: an unknown control frame: {}",
            String::from_utf8_lossy(&payload[..payload.len().min(200)])
        ),
    }
}

/// The writing half of the hub's socket, shared by the threads: one whole frame at a time.
#[derive(Clone)]
struct Out(Arc<Mutex<File>>);

impl Out {
    fn frame(&self, kind: u8, payload: &[u8]) -> io::Result<()> {
        let len =
            u32::try_from(payload.len()).map_err(|_| io::Error::other("a frame over 4 GiB"))?;
        let mut header = [0u8; HEADER_LEN];
        header[0] = kind;
        header[1..].copy_from_slice(&len.to_be_bytes());
        let mut w = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        w.write_all(&header)?;
        w.write_all(payload)
    }

    /// A control event; a hub that is gone is the reading side's to notice.
    fn control(&self, v: Value) {
        let _ = self.frame(KIND_CONTROL, v.to_string().as_bytes());
    }
}

/// Chromium's stderr, for every start: the tail file and the rate-limited events.
struct StderrSink {
    path: PathBuf,
    out: Out,
    state: Mutex<(VecDeque<u8>, Option<Instant>)>,
}

impl StderrSink {
    fn new(path: PathBuf, out: Out) -> StderrSink {
        StderrSink {
            path,
            out,
            state: Mutex::new((VecDeque::new(), None)),
        }
    }

    /// One line (without its newline). It is sent when no line was sent in the last [`STDERR_EVERY`], and the tail
    /// file is written then.
    fn line(&self, line: &[u8]) {
        let mut st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let (tail, last) = &mut *st;
        tail.extend(line);
        tail.push_back(b'\n');
        let over = tail.len().saturating_sub(STDERR_TAIL_MAX);
        tail.drain(..over);
        if last.is_none_or(|t| t.elapsed() >= STDERR_EVERY) {
            // the browser host is its own process, outside the hub's clock
            *last = Some(crate::clock::real_now());
            // the file first: whoever reads the event finds the line in it
            write_tail(&self.path, tail);
            self.out
                .control(json!({"ev": "stderr", "line": String::from_utf8_lossy(line)}));
        }
    }

    /// At the end of a stderr: the tail file holds every line.
    fn flush(&self) {
        let mut st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        write_tail(&self.path, &mut st.0);
    }
}

fn write_tail(path: &Path, tail: &mut VecDeque<u8>) {
    if let Err(e) = std::fs::write(path, tail.make_contiguous()) {
        eprintln!("ratatoskr browser-host: {}: {e}", path.display());
    }
}

/// A started Chromium.
struct Browser {
    pid: libc::pid_t,
    /// Chromium leads its own process group (it may not, where a filter refuses `setpgid`).
    group: bool,
    /// Messages for the writer thread; dropping it closes the pipe.
    to_chrome: Option<Sender<Vec<u8>>>,
    /// Sent once by the waiter, after `exited`.
    done: Receiver<()>,
}

impl Browser {
    /// Start Chromium and its threads; on failure, `exited` with `error` (and the exec's code), and `None`.
    fn start(cfg: &HostCfg, out: &Out, sink: &Arc<StderrSink>) -> Option<Browser> {
        match spawn(cfg) {
            Ok(s) => Some(Browser::run(cfg, s, out, sink)),
            Err((code, e)) => {
                eprintln!("ratatoskr browser-host: cannot start the browser: {e}");
                out.control(json!({
                    "ev": "exited", "code": code, "signal": null,
                    "error": format!("cannot start {}: {e}", cfg.program.display()),
                }));
                None
            }
        }
    }

    fn run(cfg: &HostCfg, s: Spawned, out: &Out, sink: &Arc<StderrSink>) -> Browser {
        let pid = s.pid;
        // the group exists once the exec happened: the child joined its own before it
        // SAFETY: getpgid only reads.
        let group = unsafe { libc::getpgid(pid) } == pid;
        out.control(json!({"ev": "started", "pid": pid}));
        let live = Arc::new(AtomicBool::new(true));
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let mut to = File::from(s.to_chrome);
        std::thread::spawn(move || {
            for msg in rx {
                if let Err(e) = to.write_all(&msg) {
                    eprintln!("ratatoskr browser-host: writing to the browser: {e}");
                    break;
                }
            }
        });
        let (drained_tx, drained) = mpsc::channel::<()>();
        let (mut from, max) = (File::from(s.from_chrome), cfg.max_message);
        let (o, l) = (out.clone(), live.clone());
        std::thread::spawn(move || {
            let mut nul = Nul::new(max);
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                let n = match from.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                for m in nul.push(&buf[..n]) {
                    match m {
                        Ok(m) if l.load(Ordering::Acquire) => {
                            let _ = o.frame(KIND_CDP, &m);
                        }
                        Ok(_) => {}
                        Err(e) => {
                            eprintln!("ratatoskr browser-host: from the browser: {e}: dropped")
                        }
                    }
                }
            }
            let _ = drained_tx.send(());
        });
        let err = File::from(s.stderr);
        let sk = sink.clone();
        std::thread::spawn(move || {
            let mut r = BufReader::new(err);
            let mut line = Vec::new();
            loop {
                line.clear();
                match r
                    .by_ref()
                    .take(LINE_MAX as u64)
                    .read_until(b'\n', &mut line)
                {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        if line.last() == Some(&b'\n') {
                            line.pop();
                        }
                        sk.line(&line);
                    }
                }
            }
            sk.flush();
        });
        let (done_tx, done) = mpsc::channel::<()>();
        let o = out.clone();
        std::thread::spawn(move || {
            let (code, signal) = wait_and_clear(pid, group);
            let _ = drained.recv_timeout(DRAIN);
            live.store(false, Ordering::Release);
            eprintln!(
                "ratatoskr browser-host: the browser exited (code {code:?}, signal {signal:?})"
            );
            o.control(json!({"ev": "exited", "code": code, "signal": signal}));
            let _ = done_tx.send(());
        });
        Browser {
            pid,
            group,
            to_chrome: Some(tx),
            done,
        }
    }

    /// The waiter has sent `exited`.
    fn ended(&self) -> bool {
        !matches!(self.done.try_recv(), Err(mpsc::TryRecvError::Empty))
    }

    fn send(&self, msg: Vec<u8>) {
        if msg.contains(&0) {
            eprintln!("ratatoskr browser-host: a CDP message with a NUL in it: dropped");
            return;
        }
        let mut msg = msg;
        msg.push(0);
        if let Some(tx) = &self.to_chrome {
            let _ = tx.send(msg);
        }
    }

    /// Close the pipe, SIGTERM, SIGKILL after [`STOP_GRACE`]; returns once `exited` is sent.
    fn stop(mut self, why: &str) {
        eprintln!("ratatoskr browser-host: stopping the browser ({why})");
        drop(self.to_chrome.take());
        self.signal(libc::SIGTERM);
        if let Err(RecvTimeoutError::Timeout) = self.done.recv_timeout(STOP_GRACE) {
            self.signal(libc::SIGKILL);
            let _ = self.done.recv_timeout(Duration::from_secs(5));
        }
    }

    fn signal(&self, sig: libc::c_int) {
        if self.ended() {
            return;
        }
        let target = if self.group { -self.pid } else { self.pid };
        // SAFETY: a signal to the browser's own process (group), which is not reaped yet: `ended` is false.
        unsafe { libc::kill(target, sig) };
    }
}

/// Wait for Chromium's main process to end, kill what is left of its group while the group's id is still held (the
/// main process is not reaped until then), then reap it. Its exit code or signal.
fn wait_and_clear(pid: libc::pid_t, group: bool) -> (Option<i32>, Option<i32>) {
    loop {
        // SAFETY: a zeroed siginfo_t is a valid out-parameter for waitid.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: waits on our own child, without reaping it (WNOWAIT).
        let r = unsafe {
            libc::waitid(
                libc::P_PID,
                pid as libc::id_t,
                &mut info,
                libc::WEXITED | libc::WNOWAIT,
            )
        };
        if r == 0 || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            break;
        }
    }
    if group {
        // SAFETY: the group's leader is a zombie we have not reaped, so its id names only this group.
        unsafe { libc::kill(-pid, libc::SIGKILL) };
    }
    let mut status = 0;
    loop {
        // SAFETY: reaps our own child.
        let r = unsafe { libc::waitpid(pid, &mut status, 0) };
        if r == pid {
            break;
        }
        if r < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return (None, None);
        }
    }
    if libc::WIFEXITED(status) {
        (Some(libc::WEXITSTATUS(status)), None)
    } else if libc::WIFSIGNALED(status) {
        (None, Some(libc::WTERMSIG(status)))
    } else {
        (None, None)
    }
}

/// A Chromium that exec'd, and the host's ends of its pipes.
struct Spawned {
    pid: libc::pid_t,
    to_chrome: OwnedFd,
    from_chrome: OwnedFd,
    stderr: OwnedFd,
}

/// A close-on-exec pipe: (read end, write end).
fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0; 2];
    // SAFETY: pipe2 fills both entries with new descriptors when it returns 0.
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: both were just made, for this owner alone.
    Ok(unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) })
}

fn cstring(s: &str) -> Result<CString, String> {
    CString::new(s).map_err(|_| format!("a NUL in {s:?}"))
}

/// Fork and exec Chromium. Everything the child needs is made before the fork, so the child (of a process with
/// threads) only makes syscalls: its own process group, the death signal (and a check that the host is still its
/// parent), SIGPIPE back to default and no signal blocked, stdin and stdout on `/dev/null`, stderr on a pipe, the CDP
/// pipe at fds 3 (in) and 4 (out), every other fd close-on-exec, then `execve` with exactly [`chromium_env`]. A
/// failed exec reports its errno on a close-on-exec pipe. The error is `(exit code, text)`: 127 not found, else 126.
fn spawn(cfg: &HostCfg) -> Result<Spawned, (i32, String)> {
    let setup = |e: String| (126, e);
    let argv = chromium_argv(cfg)
        .iter()
        .map(|a| cstring(a))
        .collect::<Result<Vec<_>, _>>()
        .map_err(setup)?;
    let envp = chromium_env(cfg)
        .iter()
        .map(|(k, v)| cstring(&format!("{k}={v}")))
        .collect::<Result<Vec<_>, _>>()
        .map_err(setup)?;
    let ptrs = |v: &[CString]| -> Vec<*const libc::c_char> {
        v.iter()
            .map(|c| c.as_ptr())
            .chain([std::ptr::null()])
            .collect()
    };
    let (argv_p, envp_p) = (ptrs(&argv), ptrs(&envp));
    fn io(what: &'static str) -> impl Fn(io::Error) -> (i32, String) {
        move |e| (126, format!("{what}: {e}"))
    }
    let (in_r, in_w) = pipe().map_err(io("the CDP pipe"))?;
    let (out_r, out_w) = pipe().map_err(io("the CDP pipe"))?;
    let (err_r, err_w) = pipe().map_err(io("the stderr pipe"))?;
    let (exec_r, exec_w) = pipe().map_err(io("the exec pipe"))?;
    let null = File::options()
        .read(true)
        .write(true)
        .open("/dev/null")
        .map(OwnedFd::from)
        .map_err(io("/dev/null"))?;
    // above every number the child moves them to, so no dup2 there overwrites one before it is used
    let moved = [&in_r, &out_w, &err_w, &null, &exec_w]
        .map(high)
        .into_iter()
        .collect::<io::Result<Vec<_>>>()
        .map_err(io("the browser's fds"))?;
    let [c_in, c_out, c_err, c_null, exec_fd] = [0, 1, 2, 3, 4].map(|i| moved[i].as_raw_fd());
    // SAFETY: getpid only reads.
    let me = unsafe { libc::getpid() };
    // SAFETY: the child runs only syscalls on values made above (no allocation, no lock), then execs or exits.
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        return Err((126, format!("fork: {}", io::Error::last_os_error())));
    }
    if pid == 0 {
        // SAFETY: the child's own state; it never returns into the host.
        unsafe {
            // refused under a filter that forbids it (the reduced tier's): the host then signals the process alone
            libc::setpgid(0, 0);
            let mut none: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut none);
            let ok = libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) == 0
                && libc::getppid() == me
                && libc::signal(libc::SIGPIPE, libc::SIG_DFL) != libc::SIG_ERR
                && libc::sigprocmask(libc::SIG_SETMASK, &none, std::ptr::null_mut()) == 0
                && libc::dup2(c_null, 0) >= 0
                && libc::dup2(c_null, 1) >= 0
                && libc::dup2(c_err, 2) >= 0
                && libc::dup2(c_in, 3) >= 0
                && libc::dup2(c_out, 4) >= 0
                && libc::syscall(
                    libc::SYS_close_range,
                    5u32,
                    u32::MAX,
                    libc::CLOSE_RANGE_CLOEXEC,
                ) == 0;
            if ok {
                libc::execve(argv_p[0], argv_p.as_ptr(), envp_p.as_ptr());
            }
            let errno = io::Error::last_os_error().raw_os_error().unwrap_or(0);
            libc::write(exec_fd, (&errno as *const i32).cast(), 4);
            libc::_exit(127);
        }
    }
    // the parent: the same group from this side too, so no signal can come before the child joined it
    // SAFETY: setpgid on our own child; EACCES once it exec'd, which is fine (it joined its group first).
    unsafe { libc::setpgid(pid, pid) };
    drop((moved, in_r, out_w, err_w, null, exec_w));
    let mut got = [0u8; 4];
    let mut exec_r = File::from(exec_r);
    let n = loop {
        match exec_r.read(&mut got) {
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            r => break r.unwrap_or(0),
        }
    };
    if n == 0 {
        return Ok(Spawned {
            pid,
            to_chrome: in_w,
            from_chrome: out_r,
            stderr: err_r,
        });
    }
    let errno = i32::from_ne_bytes(got);
    let mut status = 0;
    // SAFETY: reaps the child that failed to exec.
    unsafe { libc::waitpid(pid, &mut status, 0) };
    let code = if errno == libc::ENOENT { 127 } else { 126 };
    Err((code, io::Error::from_raw_os_error(errno).to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use heimdall::codec::Frame;
    use std::os::unix::net::UnixStream;
    use std::thread::JoinHandle;

    fn stand_in() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/fake-chromium.sh")
    }

    /// A host on a thread, with the test as its hub.
    struct Fx {
        dir: tempfile::TempDir,
        hub: UnixStream,
        dec: FrameDecoder,
        backlog: Vec<Frame>,
        host: Option<JoinHandle<i32>>,
        ready: std::io::PipeReader,
    }

    impl Fx {
        fn new() -> Fx {
            let dir = tempfile::tempdir().unwrap();
            let cfg = HostCfg {
                program: stand_in(),
                dir: dir.path().join("browser"),
                web_port: 3130,
                max_message: 1 << 20,
                headless_shell: false,
            };
            let (hub, end) = UnixStream::pair().unwrap();
            let (ready, ready_w) = std::io::pipe().unwrap();
            let host = std::thread::spawn(move || serve(&cfg, end.into(), ready_w.into()));
            Fx {
                dir,
                hub,
                dec: FrameDecoder::new((1 << 20) + FRAME_SLACK),
                backlog: vec![],
                host: Some(host),
                ready,
            }
        }

        fn bdir(&self) -> PathBuf {
            self.dir.path().join("browser")
        }

        fn control(&mut self, v: Value) {
            let f = Frame::encode(KIND_CONTROL, v.to_string().as_bytes());
            self.hub.write_all(&f).unwrap();
        }

        fn cdp(&mut self, msg: &str) {
            let f = Frame::encode(KIND_CDP, msg.as_bytes());
            self.hub.write_all(&f).unwrap();
        }

        /// The first frame `want` takes, from what came already or within `within`; the others stay for later.
        fn wait(&mut self, what: &str, within: Duration, want: impl Fn(&Frame) -> bool) -> Frame {
            if let Some(i) = self.backlog.iter().position(&want) {
                return self.backlog.remove(i);
            }
            // a short read timeout, so each look returns; skuld's wait bounds the whole
            self.hub
                .set_read_timeout(Some(Duration::from_millis(10)))
                .unwrap();
            let mut buf = [0u8; 65536];
            let secs = within.as_secs().max(1);
            skuld::wait_until(what, secs, || {
                match self.hub.read(&mut buf) {
                    Ok(0) => panic!("the host closed before {what}; got {:?}", self.backlog),
                    Ok(n) => {
                        for f in self.dec.push(&buf[..n]).unwrap() {
                            self.backlog.push(f);
                        }
                    }
                    Err(e)
                        if matches!(
                            e.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                        ) => {}
                    Err(e) => panic!("{e}"),
                }
                let i = self.backlog.iter().position(&want)?;
                Some(self.backlog.remove(i))
            })
        }

        fn event(&mut self, ev: &str, within: Duration) -> Value {
            let f = self.wait(ev, within, |f| control_ev(f).is_some_and(|v| v["ev"] == ev));
            control_ev(&f).unwrap()
        }

        fn reply(&mut self, id: u64) -> Value {
            let f = self.wait(&format!("the reply {id}"), Duration::from_secs(5), |f| {
                f.kind == KIND_CDP
                    && serde_json::from_slice::<Value>(&f.payload).is_ok_and(|v| v["id"] == id)
            });
            serde_json::from_slice(&f.payload).unwrap()
        }

        fn start(&mut self) -> libc::pid_t {
            self.control(json!({"op": "start"}));
            let v = self.event("started", Duration::from_secs(5));
            v["pid"].as_i64().unwrap() as libc::pid_t
        }

        /// The host's exit code, within `within`.
        fn host_exit(&mut self, within: Duration) -> i32 {
            let h = self.host.take().unwrap();
            skuld::wait_until("the host's exit", within.as_secs().max(1), || {
                h.is_finished().then_some(())
            });
            h.join().unwrap()
        }
    }

    fn control_ev(f: &Frame) -> Option<Value> {
        (f.kind == KIND_CONTROL).then(|| serde_json::from_slice(&f.payload).ok())?
    }

    /// No live process is left in `pid`'s group, within 2 s (it panics otherwise). Read from `/proc`, since a killed
    /// orphan stays a zombie in the group until the namespace's init reaps it, and a container's may never.
    fn group_gone(pid: libc::pid_t) -> bool {
        let pgrp = pid.to_string();
        skuld::wait_until("no live process in the group", 2, || {
            let alive = std::fs::read_dir("/proc")
                .unwrap()
                .filter_map(Result::ok)
                .any(|e| {
                    let Ok(stat) = std::fs::read_to_string(e.path().join("stat")) else {
                        return false;
                    };
                    // after the command's ")": state ppid pgrp …
                    let f: Vec<&str> = stat
                        .rsplit_once(')')
                        .map_or(vec![], |(_, r)| r.split_whitespace().collect());
                    f.len() > 2 && !matches!(f[0], "Z" | "X") && f[2] == pgrp
                });
            (!alive).then_some(true)
        })
    }

    #[test]
    fn ready_then_start_then_relay() {
        let mut fx = Fx::new();
        let mut line = String::new();
        fx.ready.read_to_string(&mut line).unwrap();
        assert_eq!(line, "ready\n", "ready, then the pipe closed");
        for sub in ["profile", "downloads"] {
            let m = std::fs::metadata(fx.bdir().join(sub)).unwrap();
            assert!(m.is_dir());
            assert_eq!(m.permissions().mode() & 0o777, 0o700, "{sub}");
        }
        let pid = fx.start();
        assert!(pid > 0);
        fx.cdp(r#"{"id":1,"method":"Browser.getVersion"}"#);
        let r = fx.reply(1);
        assert_eq!(r["result"]["echo"]["method"], "Browser.getVersion", "{r}");
        let e = fx.event("stderr", Duration::from_secs(5));
        assert_eq!(e["line"], "fake-chromium: up");
        let tail = std::fs::read_to_string(fx.bdir().join(STDERR_TAIL_FILE)).unwrap();
        assert!(tail.contains("fake-chromium: up"), "{tail:?}");
        let argv = std::fs::read(fx.bdir().join("argv")).unwrap();
        let argv: Vec<String> = argv
            .split(|&b| b == 0)
            .filter(|a| !a.is_empty())
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect();
        let cfg = HostCfg {
            program: stand_in(),
            dir: fx.bdir(),
            web_port: 3130,
            max_message: 1,
            headless_shell: false,
        };
        assert_eq!(argv, chromium_argv(&cfg)[1..], "the flags, exactly");
        fx.control(json!({"op": "stop", "why": "idle"}));
        fx.event("exited", Duration::from_secs(3));
        assert!(group_gone(pid));
        drop(fx.hub);
    }

    #[test]
    fn chromium_flags_are_the_constraints() {
        let mut cfg = HostCfg {
            program: "/usr/lib64/chromium-browser/headless_shell".into(),
            dir: "/tmp/drgnx-browser".into(),
            web_port: 3130,
            max_message: DEFAULT_MAX_MESSAGE,
            headless_shell: true,
        };
        let want = "/usr/lib64/chromium-browser/headless_shell --remote-debugging-pipe \
            --user-data-dir=/tmp/drgnx-browser/profile --no-sandbox --disable-gpu \
            --proxy-server=http://127.0.0.1:3130 --no-first-run --no-default-browser-check \
            --disable-background-networking --disable-component-update --disable-sync --disable-crash-reporter \
            --disable-breakpad --disk-cache-size=67108864 --renderer-process-limit=4 about:blank";
        assert_eq!(chromium_argv(&cfg).join(" "), want);
        cfg.headless_shell = false;
        let full = chromium_argv(&cfg);
        assert_eq!(full[full.len() - 2..], ["--headless", "about:blank"]);
        assert!(!full.iter().any(|a| a.contains("swiftshader")));
    }

    #[test]
    fn stop_kills_the_browser_within_3s() {
        let mut fx = Fx::new();
        let pid = fx.start();
        // it ignores SIGTERM and the pipe's end from here on: only the SIGKILL after the grace ends it
        fx.cdp(r#"{"id":1,"method":"Fake.stubborn"}"#);
        fx.reply(1);
        fx.control(json!({"op": "stop", "why": "idle"}));
        // within 3 s (the wait's bound), and by the SIGKILL after the grace: a SIGTERM did not end it
        let e = fx.event("exited", Duration::from_secs(3));
        assert_eq!(e["signal"], libc::SIGKILL, "{e}");
        assert!(group_gone(pid), "nothing of its group is left");
        // a stopped browser starts again
        let again = fx.start();
        assert_ne!(again, pid);
        fx.cdp(r#"{"id":2,"method":"Page.enable"}"#);
        fx.reply(2);
    }

    #[test]
    fn eof_on_the_hub_fd_ends_everything() {
        let mut fx = Fx::new();
        let pid = fx.start();
        fx.cdp(r#"{"id":1,"method":"Fake.stubborn"}"#);
        fx.reply(1);
        // the hub is gone
        fx.hub.shutdown(std::net::Shutdown::Both).unwrap();
        assert_eq!(fx.host_exit(Duration::from_secs(4)), EXIT_OK);
        assert!(group_gone(pid), "no browser process is left");
    }

    #[test]
    fn crash_is_reported_as_exited() {
        let mut fx = Fx::new();
        let pid = fx.start();
        fx.cdp(r#"{"id":1,"method":"Fake.crash"}"#);
        let e = fx.event("exited", Duration::from_secs(3));
        assert_eq!(e["signal"], libc::SIGKILL, "{e}");
        assert_eq!(e["code"], Value::Null, "{e}");
        assert!(group_gone(pid));
        // the next start is a fresh browser through the same host
        let again = fx.start();
        assert_ne!(again, pid);
        fx.cdp(r#"{"id":2,"method":"Browser.getVersion"}"#);
        fx.reply(2);
    }

    #[test]
    fn env_is_only_its_own() {
        let mut fx = Fx::new();
        fx.start();
        fx.cdp(r#"{"id":1,"method":"Browser.getVersion"}"#);
        fx.reply(1);
        let raw = std::fs::read(fx.bdir().join("environ")).unwrap();
        let mut env: Vec<String> = raw
            .split(|&b| b == 0)
            .filter(|a| !a.is_empty())
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect();
        env.sort();
        let d = fx.bdir().to_string_lossy().into_owned();
        assert_eq!(
            env,
            [
                format!("HOME={d}"),
                format!("TMPDIR={d}"),
                format!("XDG_CACHE_HOME={d}")
            ]
        );
    }

    #[test]
    fn a_program_that_cannot_start_is_exited_with_its_error() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = HostCfg {
            program: dir.path().join("no-such-chromium"),
            dir: dir.path().join("browser"),
            web_port: 3130,
            max_message: 1 << 20,
            headless_shell: false,
        };
        let (out, mut hub) = UnixStream::pair().unwrap();
        let sink = Arc::new(StderrSink::new(
            dir.path().join("t"),
            Out(Arc::new(Mutex::new(File::from(OwnedFd::from(out))))),
        ));
        let o = sink.out.clone();
        assert!(Browser::start(&cfg, &o, &sink).is_none());
        drop((o, sink));
        let mut bytes = vec![];
        hub.read_to_end(&mut bytes).unwrap();
        let f = FrameDecoder::new(1 << 20).push(&bytes).unwrap();
        let v = control_ev(&f[0]).unwrap();
        assert_eq!(v["ev"], "exited");
        assert_eq!(v["code"], 127);
        assert!(
            v["error"].as_str().unwrap().contains("no-such-chromium"),
            "{v}"
        );
    }

    #[test]
    fn refuses_to_run_unlayered_without_the_flag() {
        let why = check_layered().expect_err("a test process holds no browser layer");
        assert!(
            why.contains("no_new_privs") || why.contains("allowed"),
            "{why}"
        );
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().join("browser");
        let args = [
            "--hub-fd",
            "3",
            "--ready-fd",
            "4",
            "--program",
            "/usr/bin/true",
            "--dir",
            d.to_str().unwrap(),
            "--web-port",
            "3130",
        ];
        assert_eq!(main(args.map(OsString::from).to_vec()), EXIT_FAILED);
        assert!(!d.exists(), "refused before it made anything");
    }

    #[test]
    fn unconfined_only_with_test_hooks() {
        let args = |more: &[&str]| {
            [
                "--hub-fd",
                "3",
                "--ready-fd",
                "4",
                "--program",
                "/usr/bin/chromium",
                "--dir",
                "/tmp/drgnx-browser",
                "--web-port",
                "3130",
            ]
            .iter()
            .chain(more)
            .map(OsString::from)
            .collect::<Vec<_>>()
        };
        let a = parse(args(&["--headless-shell", "--max-message", "1024"])).unwrap();
        assert!(a.cfg.headless_shell && a.cfg.max_message == 1024 && !a.unconfined);
        assert!(parse(args(&["--headless-shell", "--full"])).is_err());
        assert!(parse(args(&["--hub-fd", "2"])).is_err());
        let u = parse(args(&["--unconfined"]));
        #[cfg(feature = "test-hooks")]
        assert!(u.unwrap().unconfined);
        #[cfg(not(feature = "test-hooks"))]
        assert!(u.is_err());
    }
}
