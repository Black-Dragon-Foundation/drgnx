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

use crate::landlock::{LandlockPlan, Tier, plan_for};
use crate::spec::{Net, ValidSpec};
use crate::validate::{Refusal, Rule};
use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// The inner spec's wire version.
pub const VERSION: u32 = 1;
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

/// What the helper's status line says it applied. Every field is checked by [`read_status`]: a line that claims less
/// than Landlock enforced, seccomp and `no_new_privs` is a refusal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LayersReport {
    pub landlock_abi: u8,
    /// Always `"enforced"`.
    pub landlock: String,
    pub seccomp: bool,
    pub no_new_privs: bool,
    pub new_session: bool,
    pub relay: bool,
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
            #[cfg(feature = "test-hooks")]
            landlock_omit: vec![],
            #[cfg(feature = "test-hooks")]
            abi_cap: None,
        }
    }

    /// The inner spec for `spec` in `tier`: its Landlock plan ([`plan_for`]), its environment and `chdir`, and
    /// `relay`.
    pub fn for_spec(spec: &ValidSpec, tier: Tier, relay: Option<RelayPlan>) -> InnerSpec {
        let s = spec.spec();
        InnerSpec {
            env: s.env.clone(),
            chdir: Some(s.chdir.clone()),
            relay,
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

/// How long a caller waits for the status line of `spec`: [`SETUP_DEADLINE`] plus the relay's ready timeout.
pub fn status_deadline(spec: &InnerSpec) -> Duration {
    SETUP_DEADLINE
        + spec.relay.as_ref().map_or(Duration::ZERO, |r| {
            Duration::from_millis(r.ready_timeout_ms.into())
        })
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
pub fn read_status(
    fd: OwnedFd,
    stderr_tail: &dyn Fn() -> String,
    deadline: Duration,
) -> Result<LayersReport, Refusal> {
    let start = Instant::now();
    let mut buf: Vec<u8> = Vec::new();
    loop {
        if let Some(end) = buf.iter().position(|&b| b == b'\n') {
            return parse_status(&buf[..end]);
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

/// One status line, without its newline.
fn parse_status(line: &[u8]) -> Result<LayersReport, Refusal> {
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
    use crate::{landlock, seccomp};
    use rustix::fs::SealFlags;
    use std::ffi::CString;
    use std::os::fd::{BorrowedFd, FromRawFd};
    use std::os::unix::ffi::OsStrExt;

    /// What steps 8 and 9 need, made before anything is restricted. The relay guard rides along: it is dropped (the
    /// relay killed) only when the exec fails.
    pub(super) struct Ready {
        candidates: Vec<CString>,
        argv: Vec<CString>,
        envp: Vec<CString>,
        chdir: Option<CString>,
        _relay: Option<RelayGuard>,
    }

    /// A started relay, killed and reaped when dropped.
    struct RelayGuard(libc::pid_t);

    impl Drop for RelayGuard {
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
        if spec.version != VERSION {
            return Err(format!(
                "inner spec version {} is not {VERSION}",
                spec.version
            ));
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
        // 5. seccomp.
        let arch = seccomp::native().ok_or("seccomp: no filter for this architecture")?;
        let prog = seccomp::compile(arch).map_err(|e| format!("seccomp: {e}"))?;
        seccomp::install(&prog).map_err(|e| format!("seccomp: {e}"))?;
        // 6. The relay, under both layers; then no TCP bind for anything after it (the reduced tier).
        let relay = spec.relay.as_ref().map(start_relay).transpose()?;
        if plan.tcp_bind_ports.is_some() {
            landlock::forbid_tcp_bind().map_err(|e| format!("Landlock (no TCP bind): {e}"))?;
        }
        // 7. The status line.
        let report = LayersReport {
            landlock_abi: applied.abi,
            landlock: "enforced".into(),
            seccomp: true,
            no_new_privs: true,
            new_session: spec.new_session,
            relay: relay.is_some(),
        };
        write_all(STATUS_FD, status_ok_line(&report).as_bytes())
            .map_err(|e| format!("the status line: {e}"))?;
        // SAFETY: fd 4 is ours to close; nothing else uses it after the line.
        unsafe { libc::close(STATUS_FD) };
        Ok(Ready {
            _relay: relay,
            ..exec
        })
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
    /// write end at fd 3, every other fd above 2 closed, an empty environment.
    fn start_relay(r: &RelayPlan) -> Result<RelayGuard, String> {
        if r.argv.first().is_none_or(|p| !p.starts_with('/')) {
            return Err("the relay's program must be an absolute path".into());
        }
        let argv = r
            .argv
            .iter()
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
        let guard = RelayGuard(pid);
        drop((wr, devnull));
        wait_ready(rd, r.ready_timeout_ms)?;
        Ok(guard)
    }

    /// Wait for exactly `ready\n` on `rd` within `timeout_ms`.
    fn wait_ready(rd: OwnedFd, timeout_ms: u32) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_millis(timeout_ms.into());
        let mut buf = Vec::new();
        loop {
            if let Some(end) = buf.iter().position(|&b| b == b'\n') {
                return if &buf[..end] == b"ready" {
                    Ok(())
                } else {
                    Err(format!(
                        "the relay said {:?}, not ready",
                        String::from_utf8_lossy(&buf[..end])
                    ))
                };
            }
            if buf.len() > 64 {
                return Err("the relay's ready line is too long".into());
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(format!("the relay was not ready within {timeout_ms} ms"));
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
                    return Err(format!("the relay's ready pipe: {e}"));
                }
                _ => {}
            }
            let mut chunk = [0u8; 64];
            match rustix::io::read(&rd, &mut chunk) {
                Ok(0) => return Err("the relay exited before it was ready".into()),
                Ok(k) => buf.extend_from_slice(&chunk[..k]),
                Err(rustix::io::Errno::INTR | rustix::io::Errno::AGAIN) => {}
                Err(e) => return Err(format!("the relay's ready pipe: {e}")),
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
        }
    }

    #[test]
    fn status_lines_table() {
        let ok = status_ok_line(&report());
        assert!(ok.ends_with('\n') && ok.contains("\"ok\":true"), "{ok}");
        assert_eq!(parse_status(ok.trim_end().as_bytes()), Ok(report()));
        let err = status_err_line("Landlock: too old");
        let r = parse_status(err.trim_end().as_bytes()).unwrap_err();
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
            let r = parse_status(bad.as_bytes()).unwrap_err();
            assert_eq!(r.rule, Rule::Setup, "{bad}");
        }
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
            let start = Instant::now();
            let r = read_status(rd, &String::new, Duration::from_secs(1)).unwrap_err();
            let took = start.elapsed();
            assert_eq!(r.rule, Rule::Setup);
            assert_eq!(r.message, "sandbox setup timed out");
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
