//! The inner helper (Task 8): run between the namespace setup and the program, single-threaded; Landlock, then
//! seccomp, then the relay, a status line, and the exec (docs/develop/gleipnir.md, "The inner helper").
//!
//! The helper is `ratatoskr sandbox-inner --spec-fd 3 -- CMD…`. bwrap runs it as `/run/gleipnir/helper` (the full
//! tier); the reduced tier runs it directly ([`crate::backend::linux::reduced`]). Its spec ([`InnerSpec`]) arrives
//! on a sealed memfd at fd 3, never in argv; its one status line leaves on fd 4 ([`read_status`] reads it).
//!
//! Its body is gated `#[cfg(target_os = "linux")]` here, with an `Unsupported` stub elsewhere (Android: no backend;
//! apps get no user namespaces; fails closed). The wire types and the status reader are plain data and I/O, built
//! everywhere.

use crate::bwrap::BROWSER_FD;
use crate::landlock::{BrowserInputs, LandlockPlan, Tier, browser_plan, plan_for};
use crate::spec::{Net, Trace, ValidSpec};
use crate::validate::{Refusal, Rule};
use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// The inner spec's wire version: 2 adds `browser`.
pub const VERSION: u32 = 2;
/// The version before the browser, still read and run (it never has one).
pub const VERSION_V1: u32 = 1;
/// How long the helper waits for the browser host's `ready` line by default.
pub const BROWSER_READY_TIMEOUT_MS: u32 = 5000;
/// The largest inner spec, in bytes.
pub const SPEC_MAX: usize = 1 << 20;
/// Where the helper's caller puts the spec memfd.
pub const SPEC_FD: i32 = 3;
/// Where the helper writes its one status line.
pub const STATUS_FD: i32 = 4;
/// How long the helper waits for the relay's `ready` line by default.
pub const RELAY_READY_TIMEOUT_MS: u32 = 5000;
/// How long a caller waits for the status line, beside the relay's ready timeout.
pub const SETUP_DEADLINE: Duration = Duration::from_secs(5);
/// The helper's exit code when a setup step failed (nothing was exec'd).
pub const EXIT_SETUP: i32 = 125;
/// The program was found but could not be exec'd.
pub const EXIT_CANNOT_EXEC: i32 = 126;
/// The program was not found.
pub const EXIT_NOT_FOUND: i32 = 127;
/// The longest status line [`read_status`] accepts.
const STATUS_MAX: usize = 4096;

/// What the helper applies before it execs the program. Travels as JSON on a sealed memfd ([`spec_memfd`]).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InnerSpec {
    /// [`VERSION`]; anything else is refused.
    pub version: u32,
    /// The program's whole environment, exactly.
    pub env: Vec<(String, String)>,
    /// Where the program starts (bwrap's `--chdir` sets it too in the full tier).
    pub chdir: Option<PathBuf>,
    /// Never optional: the floors are ABI ≥ 1 (full) and ≥ 9 (reduced). seccomp has no field: it is always installed.
    pub landlock: LandlockPlan,
    /// `setsid()` before Landlock: the reduced tier has no bwrap `--new-session`. A reduced-tier spec without it is
    /// refused.
    pub new_session: bool,
    /// The relay, started after both layers and ready before the program.
    pub relay: Option<RelayPlan>,
    /// Whole-tree tracing ([`crate::Trace::Tree`]): after seccomp and the relay, the helper installs the open
    /// listener on itself, so on everything the program starts, and offers it at this socket
    /// ([`crate::trace::offer`]). A refusal or a supervisor that is not there leaves the program untraced.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trace_tree: Option<PathBuf>,
    /// The browser host (version 2), forked after the relay under a layer of its own and ready before the program.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub browser: Option<BrowserPlan>,
    /// Test hook (Task 15's row `landlock-layer-2`): removed from the write roots.
    #[cfg(feature = "test-hooks")]
    #[serde(default)]
    pub landlock_omit: Vec<PathBuf>,
    /// Test hook (Task 15's row `landlock-below-required-refused`): the kernel's ABI is taken as `min(real, cap)`.
    #[cfg(feature = "test-hooks")]
    #[serde(default)]
    pub abi_cap: Option<u8>,
}

/// The relay the helper starts: `argv` exec'd with an empty environment, stdin and stdout on `/dev/null`, the write
/// end of a ready pipe at fd 3, and nothing else open beyond stderr.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RelayPlan {
    pub argv: Vec<String>,
    pub ready_timeout_ms: u32,
}

/// The browser host the helper forks: in the child, the death signal, `hub_fd` at fd 3 and a ready pipe's write end
/// at fd 4, stdin and stdout on `/dev/null`, nothing else open beyond stderr, then the `landlock` layer and the
/// browser's seccomp filter, then `argv` exec'd with exactly `env`. The helper makes `own_dir` (0700) before the
/// fork, so the layer's write root exists, and waits for `ready\n` within `ready_timeout_ms`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BrowserPlan {
    /// Where the helper has the socketpair end ([`BROWSER_FD`]).
    pub hub_fd: i32,
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub own_dir: PathBuf,
    pub landlock: LandlockPlan,
    pub ready_timeout_ms: u32,
}

/// What the helper's status line says it applied. Every field is checked by [`read_status`]: a line that claims less
/// than Landlock enforced, seccomp and `no_new_privs` is a refusal. On macOS there is no helper and no status line:
/// [`LayersReport::seatbelt`] is the whole report.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LayersReport {
    pub landlock_abi: u8,
    /// `"enforced"` from the helper; `"none"` on macOS.
    pub landlock: String,
    pub seccomp: bool,
    pub no_new_privs: bool,
    pub new_session: bool,
    pub relay: bool,
    /// The run is under a Seatbelt profile (macOS); never set by the helper.
    #[serde(default)]
    pub seatbelt: bool,
    /// The browser host is layered and ready ([`read_status_for`] refuses `false` when one was asked for).
    #[serde(default)]
    pub browser: bool,
}

impl LayersReport {
    /// macOS: `sandbox-exec` applies the profile before the program runs, and nothing else is layered.
    pub fn seatbelt() -> LayersReport {
        LayersReport {
            landlock_abi: 0,
            landlock: "none".into(),
            seccomp: false,
            no_new_privs: false,
            new_session: false,
            relay: false,
            seatbelt: true,
            browser: false,
        }
    }
}

impl InnerSpec {
    /// An inner spec with `landlock`, no environment, no `chdir`, no relay, and a new session for the reduced tier.
    pub fn new(landlock: LandlockPlan) -> InnerSpec {
        InnerSpec {
            version: VERSION,
            env: vec![],
            chdir: None,
            new_session: landlock.tier == Tier::Reduced,
            landlock,
            relay: None,
            trace_tree: None,
            browser: None,
            #[cfg(feature = "test-hooks")]
            landlock_omit: vec![],
            #[cfg(feature = "test-hooks")]
            abi_cap: None,
        }
    }

    /// The inner spec for `spec` in `tier`: its Landlock plan ([`plan_for`]), its environment and `chdir`, and
    /// `relay`. Per-step tracing adds `GLEIPNIR_TRACE_SOCK` (the wrapper's socket) to the environment, last; whole-tree
    /// tracing sets [`InnerSpec::trace_tree`].
    pub fn for_spec(spec: &ValidSpec, tier: Tier, relay: Option<RelayPlan>) -> InnerSpec {
        let s = spec.spec();
        let mut env = s.env.clone();
        let mut trace_tree = None;
        match &s.trace {
            Trace::Off => {}
            Trace::PerStep { socket } => env.push((
                crate::trace::SOCK_ENV.into(),
                socket.to_string_lossy().into_owned(),
            )),
            Trace::Tree { socket } => trace_tree = Some(socket.clone()),
        }
        InnerSpec {
            env,
            chdir: Some(s.chdir.clone()),
            relay,
            trace_tree,
            ..InnerSpec::new(plan_for(spec, tier))
        }
    }
}

/// The relay for `spec`: `program relay_args… --ready-fd 3 PORT=SOCK…` for each relay port, or `None` when the
/// network is shared. `program` is where the helper binary is seen from inside ([`crate::HELPER_INSIDE`] under
/// bwrap, its own path in the reduced tier).
pub fn relay_plan(
    program: &str,
    relay_args: &[OsString],
    spec: &ValidSpec,
) -> Result<Option<RelayPlan>, Refusal> {
    let Net::Isolated { relay, .. } = &spec.spec().net else {
        return Ok(None);
    };
    if relay.is_empty() {
        return Ok(None);
    }
    let utf8 = |s: &std::ffi::OsStr| {
        s.to_str().map(str::to_owned).ok_or_else(|| Refusal {
            rule: Rule::NotUtf8,
            path: Some(PathBuf::from(s)),
            message: format!("the relay's argv is not UTF-8: {}", s.to_string_lossy()),
        })
    };
    let mut argv = vec![program.to_owned()];
    for a in relay_args {
        argv.push(utf8(a)?);
    }
    argv.extend(["--ready-fd".to_owned(), "3".to_owned()]);
    for r in relay {
        argv.push(format!("{}={}", r.port, utf8(r.socket.as_os_str())?));
    }
    Ok(Some(RelayPlan {
        argv,
        ready_timeout_ms: RELAY_READY_TIMEOUT_MS,
    }))
}

/// The browser host for `spec`, or `None` when it has no browser: `program browser_host_args… --hub-fd 3
/// --ready-fd 4 --program P --dir D --web-port N host_args…` with `HOME`, `XDG_CACHE_HOME` and `TMPDIR` in its own
/// dir and a plain `PATH`, under [`browser_plan`] for `tier`. `program` is where the helper is seen from inside
/// ([`crate::HELPER_INSIDE`] under bwrap); its dir joins the layer's read roots, since the host is exec'd under it.
pub fn browser_plan_for(
    program: &str,
    browser_host_args: &[OsString],
    spec: &ValidSpec,
    tier: Tier,
) -> Result<Option<BrowserPlan>, Refusal> {
    let Some(b) = &spec.spec().browser else {
        return Ok(None);
    };
    let utf8 = |s: &std::ffi::OsStr| {
        s.to_str().map(str::to_owned).ok_or_else(|| Refusal {
            rule: Rule::NotUtf8,
            path: Some(PathBuf::from(s)),
            message: format!(
                "the browser host's argv is not UTF-8: {}",
                s.to_string_lossy()
            ),
        })
    };
    let dir = utf8(b.own_dir.as_os_str())?;
    let mut argv = vec![program.to_owned()];
    for a in browser_host_args {
        argv.push(utf8(a)?);
    }
    argv.extend(
        [
            "--hub-fd",
            "3",
            "--ready-fd",
            "4",
            "--program",
            &utf8(b.program.as_os_str())?,
            "--dir",
            &dir,
            "--web-port",
            &b.web_port.to_string(),
        ]
        .map(str::to_owned),
    );
    argv.extend(b.host_args.iter().cloned());
    let env = ["HOME", "XDG_CACHE_HOME", "TMPDIR"]
        .map(|k| (k.to_owned(), dir.clone()))
        .into_iter()
        .chain([("PATH".to_owned(), "/usr/bin:/bin".to_owned())])
        .collect();
    let landlock = browser_plan(&BrowserInputs {
        tier,
        program_dir: b
            .program
            .parent()
            .map_or_else(|| b.program.clone(), PathBuf::from),
        own_dir: b.own_dir.clone(),
        helper: PathBuf::from(program),
        extra_read: b.extra_read.clone(),
        web_port: b.web_port,
        local_ports: b.local_ports.clone(),
    });
    Ok(Some(BrowserPlan {
        hub_fd: BROWSER_FD,
        argv,
        env,
        own_dir: b.own_dir.clone(),
        landlock,
        ready_timeout_ms: BROWSER_READY_TIMEOUT_MS,
    }))
}

/// How long a caller waits for the status line of `spec`: [`SETUP_DEADLINE`] plus the relay's and the browser
/// host's ready timeouts.
pub fn status_deadline(spec: &InnerSpec) -> Duration {
    let ms = |t: u32| Duration::from_millis(t.into());
    SETUP_DEADLINE
        + spec
            .relay
            .as_ref()
            .map_or(Duration::ZERO, |r| ms(r.ready_timeout_ms))
        + spec
            .browser
            .as_ref()
            .map_or(Duration::ZERO, |b| ms(b.ready_timeout_ms))
}

/// `spec` as JSON in a memfd sealed against every change (`F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK |
/// F_SEAL_SEAL`), its offset at 0, close-on-exec (the spawn moves it to fd 3). At most [`SPEC_MAX`] bytes.
// Linux only: the memfd and the helper. Android: no backend; fails closed.
#[cfg(target_os = "linux")]
pub fn spec_memfd(spec: &InnerSpec) -> io::Result<OwnedFd> {
    use rustix::fs::{MemfdFlags, SealFlags, SeekFrom};
    let json = serde_json::to_vec(spec)?;
    if json.len() > SPEC_MAX {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("the inner spec is {} bytes; at most {SPEC_MAX}", json.len()),
        ));
    }
    let fd = rustix::fs::memfd_create(
        "gleipnir-inner-spec",
        MemfdFlags::CLOEXEC | MemfdFlags::ALLOW_SEALING,
    )?;
    let mut done = 0;
    while done < json.len() {
        done += rustix::io::write(&fd, &json[done..])?;
    }
    rustix::fs::fcntl_add_seals(
        &fd,
        SealFlags::WRITE | SealFlags::GROW | SealFlags::SHRINK | SealFlags::SEAL,
    )?;
    rustix::fs::seek(&fd, SeekFrom::Start(0))?;
    Ok(fd)
}

/// Not Linux: unsupported.
// Android among them: no backend; fails closed.
#[cfg(not(target_os = "linux"))]
pub fn spec_memfd(spec: &InnerSpec) -> io::Result<OwnedFd> {
    let _ = spec;
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "the inner helper is Linux only",
    ))
}

/// The status pipe: `(read end for the parent, write end for fd 4)`, both close-on-exec. The write end moves into
/// the spawn; the parent must keep no copy of it, or [`read_status`] never sees EOF.
// Linux only (pipe2). Android: no backend; fails closed.
#[cfg(target_os = "linux")]
pub fn status_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0; 2];
    // SAFETY: pipe2 writes two fds into the array; each is owned exactly once below.
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: both fds were just made by pipe2 and nothing else owns them.
    Ok(unsafe {
        use std::os::fd::FromRawFd;
        (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1]))
    })
}

/// Not Linux: unsupported.
// Android among them: no backend; fails closed.
#[cfg(not(target_os = "linux"))]
pub fn status_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "the inner helper is Linux only",
    ))
}

fn setup_refusal(message: String) -> Refusal {
    Refusal {
        rule: Rule::Setup,
        path: None,
        message,
    }
}

/// Read the helper's status line from the read end of [`status_pipe`], within `deadline`.
/// - A line with `"ok": true` and every layer → its [`LayersReport`].
/// - `"ok": false` → a refusal with the helper's error.
/// - EOF without a line (the helper, or bwrap before it, failed) → "sandbox setup failed: " and the first line of
///   `stderr_tail()`.
/// - Past `deadline` → "sandbox setup timed out"; the caller then kills the process group.
///
/// For a run that asked for the browser, [`read_status_for`] with `browser` set.
pub fn read_status(
    fd: OwnedFd,
    stderr_tail: &dyn Fn() -> String,
    deadline: Duration,
) -> Result<LayersReport, Refusal> {
    read_status_for(fd, stderr_tail, deadline, false)
}

/// [`read_status`], and with `browser` (the run's spec asked for one, `Prepared::browser`) a line that does not say
/// `"browser": true` is refused too.
pub fn read_status_for(
    fd: OwnedFd,
    stderr_tail: &dyn Fn() -> String,
    deadline: Duration,
    browser: bool,
) -> Result<LayersReport, Refusal> {
    let start = Instant::now();
    let mut buf: Vec<u8> = Vec::new();
    loop {
        if let Some(end) = buf.iter().position(|&b| b == b'\n') {
            return parse_status(&buf[..end], browser);
        }
        if buf.len() > STATUS_MAX {
            return Err(setup_refusal(
                "sandbox setup failed: the helper's status line is too long".into(),
            ));
        }
        let left = deadline.saturating_sub(start.elapsed());
        if left.is_zero() {
            return Err(setup_refusal("sandbox setup timed out".into()));
        }
        let mut pfd = libc::pollfd {
            fd: fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let ms = libc::c_int::try_from(left.as_millis().max(1)).unwrap_or(libc::c_int::MAX);
        // SAFETY: one valid pollfd for an fd we own.
        let n = unsafe { libc::poll(&mut pfd, 1, ms) };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(setup_refusal(format!(
                "sandbox setup failed: the status pipe: {e}"
            )));
        }
        if n == 0 {
            continue;
        }
        let mut chunk = [0u8; 512];
        match rustix::io::read(&fd, &mut chunk) {
            Ok(0) => {
                return Err(setup_refusal(format!(
                    "sandbox setup failed: {}",
                    first_stderr_line(stderr_tail)
                )));
            }
            Ok(k) => buf.extend_from_slice(&chunk[..k]),
            Err(rustix::io::Errno::INTR | rustix::io::Errno::AGAIN) => {}
            Err(e) => {
                return Err(setup_refusal(format!(
                    "sandbox setup failed: the status pipe: {e}"
                )));
            }
        }
    }
}

/// The first non-empty line of the child's stderr. The caller's reader may lag the status pipe's EOF, so an empty
/// tail is asked for again for up to 200 ms.
fn first_stderr_line(stderr_tail: &dyn Fn() -> String) -> String {
    let start = Instant::now();
    loop {
        let tail = stderr_tail();
        if let Some(line) = tail.lines().map(str::trim).find(|l| !l.is_empty()) {
            return line.to_owned();
        }
        if start.elapsed() >= Duration::from_millis(200) {
            return "the helper sent no status".into();
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// One status line, without its newline; with `browser`, it must report the browser host.
fn parse_status(line: &[u8], browser: bool) -> Result<LayersReport, Refusal> {
    let bad =
        || setup_refusal("sandbox setup failed: the helper's status line is malformed".into());
    let serde_json::Value::Object(mut obj) =
        serde_json::from_slice::<serde_json::Value>(line).map_err(|_| bad())?
    else {
        return Err(bad());
    };
    match obj.remove("ok") {
        Some(serde_json::Value::Bool(true)) => {}
        Some(serde_json::Value::Bool(false)) => {
            let why = obj
                .get("error")
                .and_then(|e| e.as_str())
                .unwrap_or("no reason given");
            return Err(setup_refusal(format!("sandbox setup failed: {why}")));
        }
        _ => return Err(bad()),
    }
    let report: LayersReport =
        serde_json::from_value(serde_json::Value::Object(obj)).map_err(|_| bad())?;
    if report.landlock != "enforced" || !report.seccomp || !report.no_new_privs {
        return Err(setup_refusal(format!(
            "sandbox setup failed: the helper reported an incomplete sandbox: {}",
            String::from_utf8_lossy(line)
        )));
    }
    if browser && !report.browser {
        return Err(setup_refusal(
            "sandbox setup failed: the browser was asked for, and the helper reported none".into(),
        ));
    }
    Ok(report)
}

// The helpers below serve the Linux body and the tests; elsewhere (Android among them) nothing calls them.

/// The status line for a run that applied `report`.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn status_ok_line(report: &LayersReport) -> String {
    let mut v = serde_json::to_value(report).unwrap_or_default();
    if let serde_json::Value::Object(obj) = &mut v {
        obj.insert("ok".into(), true.into());
    }
    format!("{v}\n")
}

/// The status line for a setup step that failed.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn status_err_line(error: &str) -> String {
    format!("{}\n", serde_json::json!({ "ok": false, "error": error }))
}

/// `--spec-fd N -- CMD…`: the spec fd (3 or above, never the status fd) and the command (at least its program).
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn parse_args(args: Vec<OsString>) -> Result<(i32, Vec<OsString>), String> {
    use std::ffi::OsStr;
    let usage = "usage: sandbox-inner --spec-fd N -- CMD…";
    let mut it = args.into_iter();
    if it.next().as_deref() != Some(OsStr::new("--spec-fd")) {
        return Err(usage.into());
    }
    let fd: i32 = it
        .next()
        .and_then(|v| v.to_str().and_then(|s| s.parse().ok()))
        .ok_or(usage)?;
    if fd < 3 || fd == STATUS_FD {
        return Err(format!(
            "--spec-fd takes 3 or above, never {STATUS_FD}: not {fd}"
        ));
    }
    if it.next().as_deref() != Some(OsStr::new("--")) {
        return Err(usage.into());
    }
    let cmd: Vec<OsString> = it.collect();
    if cmd.is_empty() || cmd[0].is_empty() {
        return Err(usage.into());
    }
    Ok((fd, cmd))
}

/// The `Threads:` count of a `/proc/PID/status` text.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn threads_in(status: &str) -> Option<u32> {
    status
        .lines()
        .find_map(|l| l.strip_prefix("Threads:"))
        .and_then(|n| n.trim().parse().ok())
}

/// The helper runs single-threaded: Landlock restricts the calling thread only, and a second thread would keep the
/// rights the first gave up.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn single_thread() -> Result<(), String> {
    let status = std::fs::read_to_string("/proc/self/status")
        .map_err(|e| format!("cannot count this process's threads (/proc/self/status: {e})"))?;
    match threads_in(&status) {
        Some(1) => Ok(()),
        Some(n) => Err(format!(
            "the inner helper must be single-threaded; it has {n} threads"
        )),
        None => Err("cannot count this process's threads (no Threads: line)".into()),
    }
}

/// `ratatoskr sandbox-inner --spec-fd 3 -- CMD…`. Never returns when the program is exec'd; otherwise the exit
/// code: [`EXIT_SETUP`] when a setup step failed (the status line says why, and nothing ran), [`EXIT_NOT_FOUND`] or
/// [`EXIT_CANNOT_EXEC`]. It must run before any thread or runtime exists.
// Linux only. Android: no backend; apps get no user namespaces; fails closed.
#[cfg(target_os = "linux")]
pub fn inner_main(args: impl Iterator<Item = OsString>) -> i32 {
    linux::main(args.collect())
}

/// Not Linux: exits [`EXIT_SETUP`] at once.
// Android among them: no backend; apps get no user namespaces; fails closed.
#[cfg(not(target_os = "linux"))]
pub fn inner_main(args: impl Iterator<Item = OsString>) -> i32 {
    drop(args);
    eprintln!("ratatoskr sandbox-inner: the inner helper is Linux only");
    EXIT_SETUP
}

// Linux only: the helper's body. Android: no backend; apps get no user namespaces; fails closed.
#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use crate::net::relay::PARENT_PID_ARG;
    use crate::{landlock, seccomp};
    use rustix::fs::SealFlags;
    use std::ffi::CString;
    use std::os::fd::{BorrowedFd, FromRawFd};
    use std::os::unix::ffi::OsStrExt;

    /// What steps 8 and 9 need, made before anything is restricted. The relay's and the browser host's guards ride
    /// along: they are dropped (the children killed) only when the exec fails.
    pub(super) struct Ready {
        candidates: Vec<CString>,
        argv: Vec<CString>,
        envp: Vec<CString>,
        chdir: Option<CString>,
        _relay: Option<ChildGuard>,
        _browser: Option<ChildGuard>,
    }

    /// A started child (the relay, the browser host), killed and reaped when dropped.
    struct ChildGuard(libc::pid_t);

    impl Drop for ChildGuard {
        fn drop(&mut self) {
            // SAFETY: plain syscalls on the pid of our own child.
            unsafe {
                libc::kill(self.0, libc::SIGKILL);
                libc::waitpid(self.0, std::ptr::null_mut(), 0);
            }
        }
    }

    pub(super) fn main(args: Vec<OsString>) -> i32 {
        // SAFETY: getppid has no failure mode.
        let ppid = unsafe { libc::getppid() };
        match setup(args, ppid) {
            Ok(ready) => run(ready),
            Err(e) => {
                eprintln!("ratatoskr sandbox-inner: {e}");
                let _ = write_all(STATUS_FD, status_err_line(&e).as_bytes());
                EXIT_SETUP
            }
        }
    }

    /// Steps 1–7. Every `Err` becomes a status line with `"ok": false` and exit 125; nothing has been exec'd.
    fn setup(args: Vec<OsString>, ppid: libc::pid_t) -> Result<Ready, String> {
        let (spec_fd, cmd) = parse_args(args)?;
        // 1. The spec, from a sealed memfd; closed after.
        let spec = read_spec(spec_fd)?;
        if spec.version != VERSION && spec.version != VERSION_V1 {
            return Err(format!(
                "inner spec version {} is neither {VERSION} nor {VERSION_V1}",
                spec.version
            ));
        }
        if spec.version == VERSION_V1 && spec.browser.is_some() {
            return Err(format!("a browser needs inner spec version {VERSION}"));
        }
        if spec.landlock.tier == Tier::Reduced && !spec.new_session {
            return Err("a reduced-tier spec must start a new session".into());
        }
        #[cfg(feature = "test-hooks")]
        let (plan, abi_cap) = {
            let mut plan = spec.landlock.clone();
            plan.write_roots.retain(|p| !spec.landlock_omit.contains(p));
            (plan, spec.abi_cap)
        };
        #[cfg(not(feature = "test-hooks"))]
        let (plan, abi_cap) = (spec.landlock.clone(), None);
        let exec = prepare_exec(&spec, &cmd)?;
        // 2. One thread.
        single_thread()?;
        // 3. no_new_privs; die with the parent, which must still be the one we started with.
        rustix::thread::set_no_new_privs(true).map_err(|e| format!("no_new_privs: {e}"))?;
        rustix::process::set_parent_process_death_signal(Some(rustix::process::Signal::KILL))
            .map_err(|e| format!("PR_SET_PDEATHSIG: {e}"))?;
        // SAFETY: getppid has no failure mode.
        if unsafe { libc::getppid() } != ppid {
            return Err("the parent exited during setup".into());
        }
        // 3a. A session of its own (the reduced tier).
        if spec.new_session {
            new_session()?;
        }
        // 4. Landlock.
        let applied = landlock::restrict(&plan, abi_cap).map_err(|e| format!("Landlock: {e}"))?;
        // 5. seccomp: the reduced tier's filter also refuses every socket but TCP that reaches past the host.
        let arch = seccomp::native().ok_or("seccomp: no filter for this architecture")?;
        let prog = seccomp::compile_for(arch, plan.tier).map_err(|e| format!("seccomp: {e}"))?;
        seccomp::install(&prog).map_err(|e| format!("seccomp: {e}"))?;
        // 6. The relay, under both layers; then no TCP bind for anything after it (the reduced tier).
        let relay = spec.relay.as_ref().map(start_relay).transpose()?;
        if plan.tcp_bind_ports.is_some() {
            landlock::forbid_tcp_bind().map_err(|e| format!("Landlock (no TCP bind): {e}"))?;
        }
        // 6b. The browser host, under its own layer and filter on top of both, ready before the status line.
        let browser = spec
            .browser
            .as_ref()
            .map(|b| start_browser(b, abi_cap))
            .transpose()?;
        // 6c. Whole-tree tracing: the listener after Gleipnir's own filter, the relay and the browser host (which it
        // must not cover: a forked child inherits the listener), offered to the supervisor. Whatever the answer, the
        // program runs, traced or not; only a listener that is installed but never reached the supervisor (every open
        // would then fail) stops the setup.
        if let Some(sock) = &spec.trace_tree {
            let words: Vec<String> = cmd
                .iter()
                .map(|w| w.to_string_lossy().into_owned())
                .collect();
            let scope = crate::trace::Scope::Tree;
            if let crate::trace::Offered::Lost(why) =
                crate::trace::offer(sock, scope, &words.join(" "))
            {
                return Err(format!("trace: {why}"));
            }
        }
        // 7. The status line.
        let report = LayersReport {
            landlock_abi: applied.abi,
            landlock: "enforced".into(),
            seccomp: true,
            no_new_privs: true,
            new_session: spec.new_session,
            relay: relay.is_some(),
            seatbelt: false,
            browser: browser.is_some(),
        };
        write_all(STATUS_FD, status_ok_line(&report).as_bytes())
            .map_err(|e| format!("the status line: {e}"))?;
        // SAFETY: fd 4 is ours to close; nothing else uses it after the line.
        unsafe { libc::close(STATUS_FD) };
        Ok(Ready {
            _relay: relay,
            _browser: browser,
            ..exec
        })
    }

    /// Step 6b: fork the browser host and wait for its `ready` line. Everything the child needs is made first (its
    /// strings, the BPF program, its dir, the fds moved above 9), so after the fork it only makes syscalls, applies
    /// the layer (the helper is single-threaded, step 2, so that is safe) and execs. In the child: the death signal
    /// (and a check that the helper is still its parent), stdin and stdout on `/dev/null`, the hub's end at fd 3 and
    /// the ready pipe at fd 4, every fd from 5 closed, then Landlock (the plan's layer, floor
    /// [`crate::LANDLOCK_FLOOR_BROWSER`]) and the browser filter ([`seccomp::compile_browser`]). The parent closes its
    /// copy of the hub's end, so only the host holds it, and waits.
    fn start_browser(b: &BrowserPlan, abi_cap: Option<u8>) -> Result<ChildGuard, String> {
        if b.argv.first().is_none_or(|p| !p.starts_with('/')) {
            return Err("the browser host's program must be an absolute path".into());
        }
        if b.landlock.min_abi < crate::spec::LANDLOCK_FLOOR_BROWSER {
            return Err(format!(
                "the browser layer asks for Landlock ABI {}; the browser needs {}",
                b.landlock.min_abi,
                crate::spec::LANDLOCK_FLOOR_BROWSER
            ));
        }
        // The floor first, so a kernel below it is named here and no host is started.
        landlock::gate(&b.landlock, landlock::kernel_abi(), abi_cap)
            .map_err(|e| format!("the browser layer: Landlock: {e}"))?;
        if b.hub_fd < 3 || b.hub_fd == STATUS_FD {
            return Err(format!("the browser's hub end cannot be fd {}", b.hub_fd));
        }
        // SAFETY: F_GETFD only asks whether the number is an open descriptor.
        if unsafe { libc::fcntl(b.hub_fd, libc::F_GETFD) } < 0 {
            return Err(format!("no browser hub end at fd {}", b.hub_fd));
        }
        // SAFETY: the caller passed the hub's end at this number for the browser host alone; the helper takes it, and
        // it is closed here (the child has its own copy at fd 3).
        let hub = unsafe { OwnedFd::from_raw_fd(b.hub_fd) };
        let argv = b
            .argv
            .iter()
            .map(|a| cstring(a.as_bytes(), "the browser host's argv"))
            .collect::<Result<Vec<_>, _>>()?;
        let mut envp = Vec::with_capacity(b.env.len());
        for (k, v) in &b.env {
            if k.is_empty() || k.contains('=') {
                return Err(format!("the browser's environment name {k:?} is malformed"));
            }
            envp.push(cstring(
                format!("{k}={v}").as_bytes(),
                "the browser's environment",
            )?);
        }
        let argv_p = nul_terminated(&argv);
        let envp_p = nul_terminated(&envp);
        let arch = seccomp::native().ok_or("seccomp: no filter for this architecture")?;
        let prog =
            seccomp::compile_browser(arch).map_err(|e| format!("the browser's seccomp: {e}"))?;
        own_dir(&b.own_dir)?;
        let (rd, wr) = status_pipe().map_err(|e| format!("the browser's ready pipe: {e}"))?;
        let devnull = rustix::fs::open(
            "/dev/null",
            rustix::fs::OFlags::RDWR | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .map_err(|e| format!("/dev/null: {e}"))?;
        // Above every number the child moves them to, so no dup2 below overwrites one before it is used.
        let high = |fd: &OwnedFd| {
            rustix::io::fcntl_dupfd_cloexec(fd, 10).map_err(|e| format!("the browser's fds: {e}"))
        };
        let (hub_hi, wr_hi, null_hi) = (high(&hub)?, high(&wr)?, high(&devnull)?);
        drop((hub, wr, devnull));
        let (h, w, n) = (hub_hi.as_raw_fd(), wr_hi.as_raw_fd(), null_hi.as_raw_fd());
        let me = rustix::process::getpid().as_raw_nonzero().get();
        // SAFETY: this process is single-threaded (step 2), so the child may run any code; it runs syscalls on values
        // made above, the Landlock layer and the filter install, then execs or exits.
        let pid = unsafe { libc::fork() };
        if pid < 0 {
            return Err(format!(
                "cannot start the browser host: {}",
                io::Error::last_os_error()
            ));
        }
        if pid == 0 {
            // SAFETY: the child's own descriptors and state; it never returns into the helper.
            unsafe {
                let ok = libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) == 0
                    && libc::getppid() == me
                    && libc::dup2(n, 0) >= 0
                    && libc::dup2(n, 1) >= 0
                    && libc::dup2(h, 3) >= 0
                    && libc::dup2(w, 4) >= 0
                    && libc::syscall(libc::SYS_close_range, 5u32, u32::MAX, 0u32) == 0;
                if !ok {
                    libc::_exit(EXIT_SETUP);
                }
                if let Err(e) = landlock::restrict(&b.landlock, abi_cap) {
                    eprintln!("ratatoskr sandbox-inner: the browser layer: Landlock: {e}");
                    libc::_exit(EXIT_SETUP);
                }
                if let Err(e) = seccomp::install(&prog) {
                    eprintln!("ratatoskr sandbox-inner: the browser's seccomp: {e}");
                    libc::_exit(EXIT_SETUP);
                }
                libc::execve(argv_p[0], argv_p.as_ptr(), envp_p.as_ptr());
                libc::_exit(EXIT_NOT_FOUND);
            }
        }
        let guard = ChildGuard(pid);
        drop((hub_hi, wr_hi, null_hi));
        wait_ready(rd, b.ready_timeout_ms, "the browser host")?;
        Ok(guard)
    }

    /// The browser's own dir, made 0700 before its layer exists (a write root that does not exist is skipped). One
    /// that is there already must be a directory of this user's, not a link.
    fn own_dir(dir: &std::path::Path) -> Result<(), String> {
        use rustix::fs::{AtFlags, FileType, Mode};
        let shown = dir.display();
        match rustix::fs::mkdir(dir, Mode::RWXU) {
            Ok(()) => return Ok(()),
            Err(rustix::io::Errno::EXIST) => {}
            Err(e) => return Err(format!("the browser's dir {shown}: {e}")),
        }
        let st = rustix::fs::statat(rustix::fs::CWD, dir, AtFlags::SYMLINK_NOFOLLOW)
            .map_err(|e| format!("the browser's dir {shown}: {e}"))?;
        if FileType::from_raw_mode(st.st_mode) != FileType::Directory
            || st.st_uid != rustix::process::geteuid().as_raw()
        {
            return Err(format!(
                "the browser's dir {shown} is there already and is not a directory of this user's"
            ));
        }
        Ok(())
    }

    /// Steps 8 and 9: only stdio left, `chdir`, then the exec with exactly the spec's environment.
    fn run(ready: Ready) -> i32 {
        // SAFETY: close_range only closes descriptors; Landlock needs Linux 5.13, close_range 5.9.
        if unsafe { libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) } != 0 {
            eprintln!(
                "ratatoskr sandbox-inner: cannot close descriptors: {}",
                io::Error::last_os_error()
            );
            return EXIT_SETUP;
        }
        if let Some(dir) = &ready.chdir {
            // SAFETY: a NUL-terminated path.
            if unsafe { libc::chdir(dir.as_ptr()) } != 0 {
                eprintln!(
                    "ratatoskr sandbox-inner: cannot enter {}: {}",
                    dir.to_string_lossy(),
                    io::Error::last_os_error()
                );
                return EXIT_SETUP;
            }
        }
        let argv = nul_terminated(&ready.argv);
        let envp = nul_terminated(&ready.envp);
        let mut cannot = None;
        for path in &ready.candidates {
            // SAFETY: NUL-terminated strings and NULL-terminated arrays that outlive the call.
            unsafe { libc::execve(path.as_ptr(), argv.as_ptr(), envp.as_ptr()) };
            let e = io::Error::last_os_error();
            if !matches!(e.raw_os_error(), Some(libc::ENOENT | libc::ENOTDIR)) {
                cannot = Some((path, e));
            }
        }
        let program = ready.argv[0].to_string_lossy();
        match cannot {
            Some((path, e)) => {
                eprintln!(
                    "ratatoskr sandbox-inner: cannot run {}: {e}",
                    path.to_string_lossy()
                );
                EXIT_CANNOT_EXEC
            }
            None => {
                eprintln!("ratatoskr sandbox-inner: {program}: not found");
                EXIT_NOT_FOUND
            }
        }
    }

    fn nul_terminated(v: &[CString]) -> Vec<*const libc::c_char> {
        v.iter()
            .map(|c| c.as_ptr())
            .chain(std::iter::once(std::ptr::null()))
            .collect()
    }

    fn cstring(bytes: &[u8], what: &str) -> Result<CString, String> {
        CString::new(bytes).map_err(|_| format!("{what} holds a NUL byte"))
    }

    /// The exec's strings, made while allocating is still harmless. A program with a `/` is run as given; a bare
    /// name is searched in the spec environment's `PATH` (absolute entries only).
    fn prepare_exec(spec: &InnerSpec, cmd: &[OsString]) -> Result<Ready, String> {
        let argv = cmd
            .iter()
            .map(|a| cstring(a.as_bytes(), "the command"))
            .collect::<Result<Vec<_>, _>>()?;
        let mut envp = Vec::with_capacity(spec.env.len());
        for (k, v) in &spec.env {
            if k.is_empty() || k.contains('=') {
                return Err(format!("the environment name {k:?} is malformed"));
            }
            envp.push(cstring(format!("{k}={v}").as_bytes(), "the environment")?);
        }
        let program = cmd[0].as_bytes();
        let candidates = if program.contains(&b'/') {
            vec![argv[0].clone()]
        } else {
            let path = spec
                .env
                .iter()
                .rev()
                .find(|(k, _)| k == "PATH")
                .map_or("", |(_, v)| v.as_str());
            path.split(':')
                .filter(|d| d.starts_with('/'))
                .map(|d| {
                    let mut p = d.trim_end_matches('/').as_bytes().to_vec();
                    p.push(b'/');
                    p.extend_from_slice(program);
                    cstring(&p, "the command")
                })
                .collect::<Result<Vec<_>, _>>()?
        };
        let chdir = spec
            .chdir
            .as_ref()
            .map(|d| cstring(d.as_os_str().as_bytes(), "chdir"))
            .transpose()?;
        Ok(Ready {
            candidates,
            argv,
            envp,
            chdir,
            _relay: None,
            _browser: None,
        })
    }

    /// The spec at `fd`: a memfd sealed against every change, at most [`SPEC_MAX`] bytes, read from offset 0.
    /// The fd is closed whatever happens.
    fn read_spec(fd: i32) -> Result<InnerSpec, String> {
        // SAFETY: F_GETFD only asks whether the number is an open descriptor.
        if unsafe { libc::fcntl(fd, libc::F_GETFD) } < 0 {
            return Err(format!("no spec at fd {fd}"));
        }
        // SAFETY: fd is open (checked above) and handed to us by our caller; we take it and close it.
        let owned = unsafe { OwnedFd::from_raw_fd(fd) };
        let fd: BorrowedFd<'_> = std::os::fd::AsFd::as_fd(&owned);
        let need = SealFlags::WRITE | SealFlags::GROW | SealFlags::SHRINK | SealFlags::SEAL;
        match rustix::fs::fcntl_get_seals(fd) {
            Ok(seals) if seals.contains(need) => {}
            _ => return Err("the spec fd is not a sealed memfd".into()),
        }
        let size = rustix::fs::fstat(fd)
            .map_err(|e| format!("the spec fd: {e}"))?
            .st_size;
        let size = usize::try_from(size).unwrap_or(usize::MAX);
        if size > SPEC_MAX {
            return Err(format!("the spec is {size} bytes; at most {SPEC_MAX}"));
        }
        let mut buf = vec![0u8; size];
        let mut done = 0;
        while done < size {
            match rustix::io::pread(fd, &mut buf[done..], done as u64) {
                Ok(0) => return Err("the spec ended early".into()),
                Ok(n) => done += n,
                Err(rustix::io::Errno::INTR) => {}
                Err(e) => return Err(format!("the spec fd: {e}")),
            }
        }
        drop(owned);
        serde_json::from_slice(&buf).map_err(|e| format!("the inner spec: {e}"))
    }

    /// `setsid()`. A helper its spawner already made a session leader (setsid before exec) is accepted; one that
    /// leads only a process group cannot start a session, and is refused.
    fn new_session() -> Result<(), String> {
        match rustix::process::setsid() {
            Ok(_) => Ok(()),
            Err(_) if rustix::process::getsid(None).ok() == Some(rustix::process::getpid()) => {
                Ok(())
            }
            Err(e) => Err(format!(
                "cannot start a new session ({e}): the helper leads a process group; spawn it with setsid"
            )),
        }
    }

    /// Fork the relay and wait for its `ready` line. In the child: stdin and stdout on `/dev/null`, the ready pipe's
    /// write end at fd 3, every other fd above 2 closed, an empty environment. Its argv gets `--parent-pid` and this
    /// process's pid last: the relay refuses to start under any other parent, so one whose parent died before it
    /// ran ends at once (Gleipnir T11-1).
    fn start_relay(r: &RelayPlan) -> Result<ChildGuard, String> {
        if r.argv.first().is_none_or(|p| !p.starts_with('/')) {
            return Err("the relay's program must be an absolute path".into());
        }
        let me = rustix::process::getpid().as_raw_nonzero().to_string();
        let argv = r
            .argv
            .iter()
            .map(String::as_str)
            .chain([PARENT_PID_ARG, me.as_str()])
            .map(|a| cstring(a.as_bytes(), "the relay's argv"))
            .collect::<Result<Vec<_>, _>>()?;
        let argv_p = nul_terminated(&argv);
        let envp_p: [*const libc::c_char; 1] = [std::ptr::null()];
        let (rd, wr) = status_pipe().map_err(|e| format!("the relay's ready pipe: {e}"))?;
        let devnull = rustix::fs::open(
            "/dev/null",
            rustix::fs::OFlags::RDWR | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .map_err(|e| format!("/dev/null: {e}"))?;
        let (w, n) = (wr.as_raw_fd(), devnull.as_raw_fd());
        // SAFETY: this process is single-threaded (step 2), so the child may run any code; it runs only syscalls on
        // values made above, then execs or exits.
        let pid = unsafe { libc::fork() };
        if pid < 0 {
            return Err(format!(
                "cannot start the relay: {}",
                io::Error::last_os_error()
            ));
        }
        if pid == 0 {
            // SAFETY: the child's own descriptors; dup2 clears close-on-exec on its target, and F_SETFD does when
            // the write end already is fd 3.
            unsafe {
                let ok = libc::dup2(n, 0) >= 0
                    && libc::dup2(n, 1) >= 0
                    && if w == 3 {
                        libc::fcntl(3, libc::F_SETFD, 0) >= 0
                    } else {
                        libc::dup2(w, 3) >= 0
                    }
                    && libc::syscall(libc::SYS_close_range, 4u32, u32::MAX, 0u32) == 0;
                if ok {
                    libc::execve(argv_p[0], argv_p.as_ptr(), envp_p.as_ptr());
                }
                libc::_exit(EXIT_NOT_FOUND);
            }
        }
        let guard = ChildGuard(pid);
        drop((wr, devnull));
        wait_ready(rd, r.ready_timeout_ms, "the relay")?;
        Ok(guard)
    }

    /// Wait for exactly `ready\n` on `rd` within `timeout_ms`; `what` names the child in the errors.
    fn wait_ready(rd: OwnedFd, timeout_ms: u32, what: &str) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_millis(timeout_ms.into());
        let mut buf = Vec::new();
        loop {
            if let Some(end) = buf.iter().position(|&b| b == b'\n') {
                return if &buf[..end] == b"ready" {
                    Ok(())
                } else {
                    Err(format!(
                        "{what} said {:?}, not ready",
                        String::from_utf8_lossy(&buf[..end])
                    ))
                };
            }
            if buf.len() > 64 {
                return Err(format!("{what}'s ready line is too long"));
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(format!("{what} was not ready within {timeout_ms} ms"));
            }
            let mut pfd = libc::pollfd {
                fd: rd.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            let ms = libc::c_int::try_from(left.as_millis().max(1)).unwrap_or(libc::c_int::MAX);
            // SAFETY: one valid pollfd for an fd we own.
            match unsafe { libc::poll(&mut pfd, 1, ms) } {
                0 => continue,
                n if n < 0 => {
                    let e = io::Error::last_os_error();
                    if e.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(format!("{what}'s ready pipe: {e}"));
                }
                _ => {}
            }
            let mut chunk = [0u8; 64];
            match rustix::io::read(&rd, &mut chunk) {
                Ok(0) => return Err(format!("{what} exited before it was ready")),
                Ok(k) => buf.extend_from_slice(&chunk[..k]),
                Err(rustix::io::Errno::INTR | rustix::io::Errno::AGAIN) => {}
                Err(e) => return Err(format!("{what}'s ready pipe: {e}")),
            }
        }
    }

    fn write_all(fd: i32, mut bytes: &[u8]) -> io::Result<()> {
        // SAFETY: the number is only borrowed for these writes; a closed fd gives EBADF.
        let fd = unsafe { BorrowedFd::borrow_raw(fd) };
        while !bytes.is_empty() {
            match rustix::io::write(fd, bytes) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(n) => bytes = &bytes[n..],
                Err(rustix::io::Errno::INTR) => {}
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn os(v: &[&str]) -> Vec<OsString> {
        v.iter().map(OsString::from).collect()
    }

    fn plan(tier: Tier) -> LandlockPlan {
        LandlockPlan {
            tier,
            min_abi: tier.floor(),
            read_roots: vec!["/".into()],
            write_roots: vec!["/w".into()],
            dev_write_files: vec![],
            unix_connect_roots: vec![],
            tcp_connect_ports: None,
            tcp_bind_ports: None,
        }
    }

    #[test]
    fn args_are_spec_fd_then_the_command() {
        assert_eq!(
            parse_args(os(&[
                "--spec-fd",
                "3",
                "--",
                "/bin/sh",
                "-c",
                "x --spec-fd"
            ])),
            Ok((3, os(&["/bin/sh", "-c", "x --spec-fd"])))
        );
        assert_eq!(
            parse_args(os(&["--spec-fd", "9", "--", "cat"])),
            Ok((9, os(&["cat"])))
        );
        for bad in [
            &[][..],
            &["--spec-fd", "3", "--"],
            &["--spec-fd", "3", "/bin/true"],
            &["--spec-fd", "x", "--", "/bin/true"],
            &["--spec-fd", "2", "--", "/bin/true"],
            &["--spec-fd", "4", "--", "/bin/true"],
            &["--spec-fd", "-1", "--", "/bin/true"],
            &["--", "/bin/true"],
            &["--spec-fd", "3", "--", ""],
        ] {
            assert!(parse_args(os(bad)).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn threads_are_counted() {
        assert_eq!(threads_in("Name:\tx\nThreads:\t1\nSigQ:\t0/1\n"), Some(1));
        assert_eq!(threads_in("Threads:\t12\n"), Some(12));
        assert_eq!(threads_in("Name:\tx\n"), None);
    }

    /// The real check, in this (threaded) test process: a second thread is refused, and the error names the count.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    fn a_second_thread_is_refused() {
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        let t = std::thread::spawn(move || rx.recv());
        let e = single_thread().unwrap_err();
        let n: u32 = e
            .strip_prefix("the inner helper must be single-threaded; it has ")
            .and_then(|r| r.strip_suffix(" threads"))
            .and_then(|n| n.parse().ok())
            .unwrap_or_else(|| panic!("{e}"));
        assert!(n >= 2, "{e}");
        tx.send(()).unwrap();
        t.join().unwrap().unwrap();
    }

    fn report() -> LayersReport {
        LayersReport {
            landlock_abi: 9,
            landlock: "enforced".into(),
            seccomp: true,
            no_new_privs: true,
            new_session: true,
            relay: false,
            seatbelt: false,
            browser: false,
        }
    }

    #[test]
    fn status_lines_table() {
        let ok = status_ok_line(&report());
        assert!(ok.ends_with('\n') && ok.contains("\"ok\":true"), "{ok}");
        assert_eq!(parse_status(ok.trim_end().as_bytes(), false), Ok(report()));
        let err = status_err_line("Landlock: too old");
        let r = parse_status(err.trim_end().as_bytes(), false).unwrap_err();
        assert_eq!(r.rule, Rule::Setup);
        assert_eq!(r.message, "sandbox setup failed: Landlock: too old");
        for bad in [
            r#"{"ok":true,"landlock_abi":9,"landlock":"enforced","seccomp":false,"no_new_privs":true,"new_session":true,"relay":false}"#,
            r#"{"ok":true,"landlock_abi":9,"landlock":"partial","seccomp":true,"no_new_privs":true,"new_session":true,"relay":false}"#,
            r#"{"ok":true,"landlock_abi":9,"landlock":"enforced","seccomp":true,"no_new_privs":false,"new_session":true,"relay":false}"#,
            r#"{"ok":true,"landlock_abi":9,"landlock":"enforced","seccomp":true,"no_new_privs":true,"new_session":true,"relay":false,"extra":1}"#,
            r#"{"ok":true}"#,
            r#"{"ok":"yes"}"#,
            r#"[true]"#,
            "ready",
            "",
        ] {
            let r = parse_status(bad.as_bytes(), false).unwrap_err();
            assert_eq!(r.rule, Rule::Setup, "{bad}");
        }
    }

    /// A run that asked for the browser accepts only a line that reports it; one that did not ask accepts either, and
    /// an older line without the key reads as `browser: false`.
    #[test]
    fn status_without_browser_is_refused_when_asked() {
        let without = status_ok_line(&report());
        let with = status_ok_line(&LayersReport {
            browser: true,
            ..report()
        });
        let r = parse_status(without.trim_end().as_bytes(), true).unwrap_err();
        assert_eq!(r.rule, Rule::Setup);
        assert!(r.message.contains("browser"), "{}", r.message);
        assert!(parse_status(with.trim_end().as_bytes(), true).is_ok_and(|l| l.browser));
        assert!(parse_status(with.trim_end().as_bytes(), false).is_ok());
        let old = r#"{"ok":true,"landlock_abi":9,"landlock":"enforced","seccomp":true,"no_new_privs":true,"new_session":true,"relay":false}"#;
        assert_eq!(parse_status(old.as_bytes(), false), Ok(report()));
        assert!(parse_status(old.as_bytes(), true).is_err());
    }

    fn browser_plan_fixture() -> BrowserPlan {
        BrowserPlan {
            hub_fd: BROWSER_FD,
            argv: vec![
                crate::HELPER_INSIDE.into(),
                "browser-host".into(),
                "--hub-fd".into(),
                "3".into(),
            ],
            env: vec![("HOME".into(), "/tmp/drgnx-browser".into())],
            own_dir: "/tmp/drgnx-browser".into(),
            landlock: plan(Tier::Full),
            ready_timeout_ms: BROWSER_READY_TIMEOUT_MS,
        }
    }

    /// A version-1 spec (what the helper read before the browser) still parses, has no browser, and is accepted.
    #[test]
    fn v1_spec_still_parses() {
        let mut v = serde_json::to_value(InnerSpec::new(plan(Tier::Full))).unwrap();
        assert!(
            v.get("browser").is_none(),
            "no browser key unless there is one"
        );
        v["version"] = VERSION_V1.into();
        let s: InnerSpec = serde_json::from_value(v.clone()).unwrap();
        assert_eq!((s.version, s.browser), (1, None));
        assert_eq!(VERSION, 2);
        v["unknown"] = true.into();
        assert!(
            serde_json::from_value::<InnerSpec>(v).is_err(),
            "deny_unknown_fields stays"
        );
    }

    /// A version-2 spec with the browser round-trips, refuses unknown keys in the browser too, and its deadline
    /// counts the browser's ready timeout.
    #[test]
    fn v2_browser_roundtrip() {
        let mut s = InnerSpec::new(plan(Tier::Full));
        s.browser = Some(browser_plan_fixture());
        let v = serde_json::to_value(&s).unwrap();
        assert_eq!(v["version"], 2);
        assert_eq!(v["browser"]["hub_fd"], 5);
        assert_eq!(serde_json::from_value::<InnerSpec>(v.clone()).unwrap(), s);
        let mut w = v.clone();
        w["browser"]["allow_all"] = true.into();
        assert!(serde_json::from_value::<InnerSpec>(w).is_err());
        assert_eq!(status_deadline(&s), SETUP_DEADLINE + Duration::from_secs(5));
    }

    /// The browser host's plan as `Sandbox::prepare` makes it for a full-tier spec: the helper inside with the host's
    /// args, the fixed flags, the spec's own, its own dir as HOME, XDG_CACHE_HOME and TMPDIR, and the browser layer.
    #[test]
    fn browser_plan_for_a_full_spec() {
        use crate::spec::{Layers, RelayPort, Spec, SpecBrowser, Target};
        let spec = Spec {
            read: vec![],
            write: vec!["/w".into()],
            hide: vec![],
            sockets: vec![],
            binds: vec![],
            home: None,
            run: None,
            env: vec![("PATH".into(), "/usr/bin".into())],
            chdir: "/w".into(),
            net: Net::Isolated {
                relay: vec![RelayPort {
                    port: 3130,
                    socket: "/run/drgnx/web.sock".into(),
                }],
                mac_tcp_ports: vec![],
            },
            tmp: None,
            layers: Layers::for_target(Target::LinuxBwrap),
            extra_tcp_ports: vec![5173],
            browser: Some(SpecBrowser {
                program: "/usr/lib64/chromium-browser/headless_shell".into(),
                own_dir: "/tmp/drgnx-browser".into(),
                web_port: 3130,
                local_ports: vec![5173],
                extra_read: vec!["/var/cache/fontconfig".into()],
                host_args: vec!["--headless-shell".into()],
            }),
        };
        let valid = ValidSpec::assume_valid(spec.clone(), Target::LinuxBwrap);
        let b = browser_plan_for(
            crate::HELPER_INSIDE,
            &["browser-host".into()],
            &valid,
            Tier::Full,
        )
        .unwrap()
        .unwrap();
        assert_eq!(b.hub_fd, 5);
        assert_eq!(
            b.argv,
            [
                crate::HELPER_INSIDE,
                "browser-host",
                "--hub-fd",
                "3",
                "--ready-fd",
                "4",
                "--program",
                "/usr/lib64/chromium-browser/headless_shell",
                "--dir",
                "/tmp/drgnx-browser",
                "--web-port",
                "3130",
                "--headless-shell"
            ]
        );
        let env: Vec<(&str, &str)> = b
            .env
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        assert_eq!(
            env,
            [
                ("HOME", "/tmp/drgnx-browser"),
                ("XDG_CACHE_HOME", "/tmp/drgnx-browser"),
                ("TMPDIR", "/tmp/drgnx-browser"),
                ("PATH", "/usr/bin:/bin")
            ]
        );
        assert_eq!(b.own_dir, PathBuf::from("/tmp/drgnx-browser"));
        assert_eq!(b.ready_timeout_ms, 5000);
        assert_eq!(b.landlock.min_abi, 9);
        assert_eq!(b.landlock.tcp_connect_ports, Some(vec![3130, 5173]));
        assert!(b.landlock.read_roots.contains(&"/run/gleipnir".into()));
        assert!(
            b.landlock
                .read_roots
                .contains(&"/usr/lib64/chromium-browser".into())
        );
        // No browser, no plan.
        let none = ValidSpec::assume_valid(
            Spec {
                browser: None,
                ..spec
            },
            Target::LinuxBwrap,
        );
        assert_eq!(
            browser_plan_for(crate::HELPER_INSIDE, &[], &none, Tier::Full).unwrap(),
            None
        );
    }

    /// Release builds decode no test hook: a spec carrying one is refused as an unknown field.
    #[cfg(not(feature = "test-hooks"))]
    #[test]
    fn test_fields_absent_without_the_feature() {
        let mut v = serde_json::to_value(InnerSpec::new(plan(Tier::Full))).unwrap();
        assert!(serde_json::from_value::<InnerSpec>(v.clone()).is_ok());
        for (k, val) in [
            ("landlock_omit", serde_json::json!(["/w"])),
            ("abi_cap", serde_json::json!(8)),
        ] {
            let mut w = v.clone();
            w[k] = val;
            let e = serde_json::from_value::<InnerSpec>(w).unwrap_err();
            assert!(e.to_string().contains("unknown field"), "{k}: {e}");
        }
        v["allow_all"] = serde_json::json!(true);
        assert!(serde_json::from_value::<InnerSpec>(v).is_err());
    }

    #[cfg(feature = "test-hooks")]
    #[test]
    fn test_fields_present_with_the_feature() {
        let mut v = serde_json::to_value(InnerSpec::new(plan(Tier::Full))).unwrap();
        v["landlock_omit"] = serde_json::json!(["/w"]);
        v["abi_cap"] = serde_json::json!(8);
        let s: InnerSpec = serde_json::from_value(v).unwrap();
        assert_eq!(s.landlock_omit, vec![PathBuf::from("/w")]);
        assert_eq!(s.abi_cap, Some(8));
    }

    #[test]
    fn new_session_follows_the_tier_and_the_deadline_the_relay() {
        assert!(InnerSpec::new(plan(Tier::Reduced)).new_session);
        let mut s = InnerSpec::new(plan(Tier::Full));
        assert!(!s.new_session);
        assert_eq!(status_deadline(&s), SETUP_DEADLINE);
        s.relay = Some(RelayPlan {
            argv: vec!["/r".into()],
            ready_timeout_ms: 5000,
        });
        assert_eq!(status_deadline(&s), Duration::from_secs(10));
    }

    #[cfg(target_os = "linux")]
    mod linux_io {
        use super::*;
        use std::os::unix::process::CommandExt;
        use std::process::{Command, Stdio};
        use std::sync::{Arc, Mutex};

        #[test]
        fn spec_fd_is_sealed() {
            use rustix::fs::SealFlags;
            let mut spec = InnerSpec::new(plan(Tier::Full));
            spec.env = vec![("PATH".into(), "/usr/bin".into())];
            let fd = spec_memfd(&spec).unwrap();
            let seals = rustix::fs::fcntl_get_seals(&fd).unwrap();
            assert!(seals.contains(
                SealFlags::WRITE | SealFlags::GROW | SealFlags::SHRINK | SealFlags::SEAL
            ));
            assert_eq!(
                rustix::io::pwrite(&fd, b"{", 0).unwrap_err(),
                rustix::io::Errno::PERM
            );
            assert!(rustix::fs::fcntl_add_seals(&fd, SealFlags::empty()).is_err());
            // The offset is 0: a plain read gets the whole spec.
            let mut f = std::fs::File::from(fd);
            let mut s = String::new();
            std::io::Read::read_to_string(&mut f, &mut s).unwrap();
            assert_eq!(serde_json::from_str::<InnerSpec>(&s).unwrap(), spec);
            // Too big is refused before a memfd exists.
            spec.env = vec![("X".into(), "x".repeat(SPEC_MAX))];
            assert_eq!(
                spec_memfd(&spec).unwrap_err().kind(),
                io::ErrorKind::InvalidInput
            );
        }

        /// `sh -c SCRIPT` with the status pipe's write end at fd 4 and stderr collected.
        fn spawn_with_status(script: &str) -> (std::process::Child, OwnedFd, Arc<Mutex<String>>) {
            let (rd, wr) = status_pipe().unwrap();
            let hi = rustix::io::fcntl_dupfd_cloexec(&wr, 50).unwrap();
            drop(wr);
            let w = hi.as_raw_fd();
            let mut cmd = Command::new("/bin/sh");
            cmd.args(["-c", script])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::piped());
            // SAFETY: dup2 is async-signal-safe.
            unsafe {
                cmd.pre_exec(move || {
                    if libc::dup2(w, STATUS_FD) < 0 {
                        return Err(io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
            let mut child = cmd.spawn().unwrap();
            drop(hi);
            let tail = Arc::new(Mutex::new(String::new()));
            let mut stderr = child.stderr.take().unwrap();
            let t = Arc::clone(&tail);
            std::thread::spawn(move || {
                let mut s = String::new();
                let _ = std::io::Read::read_to_string(&mut stderr, &mut s);
                *t.lock().unwrap() = s;
            });
            (child, rd, tail)
        }

        /// EOF with no line (bwrap failing before the helper runs, say) is a refusal naming stderr's first line.
        #[test]
        fn missing_status_is_a_refusal_with_stderr() {
            let (mut child, rd, tail) = spawn_with_status(
                "echo 'bwrap: setting up uid map: Permission denied' >&2; echo more >&2; exit 1",
            );
            let r = read_status(rd, &|| tail.lock().unwrap().clone(), Duration::from_secs(5))
                .unwrap_err();
            assert_eq!(r.rule, Rule::Setup);
            assert_eq!(
                r.message,
                "sandbox setup failed: bwrap: setting up uid map: Permission denied"
            );
            child.wait().unwrap();
            let (mut child, rd, _) = spawn_with_status("exit 1");
            let r = read_status(rd, &String::new, Duration::from_secs(5)).unwrap_err();
            assert_eq!(r.message, "sandbox setup failed: the helper sent no status");
            child.wait().unwrap();
        }

        /// A helper that never writes is refused at the deadline, not waited for.
        #[test]
        fn a_helper_that_hangs_is_refused_at_the_deadline() {
            let (mut child, rd, _) = spawn_with_status("exec sleep 60");
            let r = read_status(rd, &String::new, Duration::from_secs(1)).unwrap_err();
            assert_eq!(r.rule, Rule::Setup);
            assert_eq!(r.message, "sandbox setup timed out");
            child.kill().unwrap();
            child.wait().unwrap();
        }

        /// The refusal comes at the deadline, not before and not long after: a timing test.
        #[test]
        #[ignore = "timing: the helper's deadline is kept"]
        fn the_hung_helper_is_refused_at_the_deadline_not_before_or_long_after() {
            let (mut child, rd, _) = spawn_with_status("exec sleep 60");
            let start = Instant::now();
            let _ = read_status(rd, &String::new, Duration::from_secs(1)).unwrap_err();
            let took = start.elapsed();
            assert!(
                took >= Duration::from_secs(1) && took < Duration::from_secs(3),
                "{took:?}"
            );
            child.kill().unwrap();
            child.wait().unwrap();
        }

        /// A line that arrives in pieces is still one line.
        #[test]
        fn a_status_line_in_pieces() {
            let line = status_ok_line(&report());
            let (a, b) = line.split_at(10);
            let script =
                format!("printf '%s' '{a}' >&4; sleep 0.2; printf '%s' '{b}' >&4; exec sleep 5");
            let (mut child, rd, _) = spawn_with_status(&script);
            assert_eq!(
                read_status(rd, &String::new, Duration::from_secs(3)),
                Ok(report())
            );
            child.kill().unwrap();
            child.wait().unwrap();
        }
    }
}
