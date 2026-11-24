//! Starting a child: an explicit environment, its own process group, SIGPIPE ignored, stderr kept as a bounded
//! tail, exactly one exit status. Descriptors: the child gets 0–2 and the [`PassFd`]s at their numbers, nothing
//! else. Sandboxed children start from one long-lived thread ([`spawn_pinned`]).

use std::ffi::OsString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{ExitStatus, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::process::{ChildStdin, ChildStdout, Command};
use tokio::runtime::Handle;
use tokio::sync::oneshot;

/// How much of a child's stderr is kept, in characters.
pub const STDERR_TAIL_CHARS: usize = 8000;

/// What to start. `env` is the child's whole environment (build it with [`crate::env::build`]); `cwd` `None` keeps
/// the hub's. With `stdin_null` the child's stdin is `/dev/null`, otherwise a pipe ([`Child::take_stdin`]).
/// `pass_fds` are the descriptors the child gets beside 0–2, each at its `target` number. With `new_session` the child
/// leads a session of its own (`setsid` before exec) instead of only a process group: gleipnir's reduced-tier helper
/// must call `setsid()` itself, which a process-group leader cannot. Either way the child's pid is its group's.
///
/// [`spawn`] consumes the spec and drops its `PassFd`s once the child is started, so the parent keeps no copy of a
/// pipe end it waits on for EOF. Never keep a clone of a spec that has `pass_fds`.
#[derive(Debug, Clone)]
pub struct Spec {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    pub env: Vec<(OsString, OsString)>,
    pub cwd: Option<PathBuf>,
    pub stdin_null: bool,
    pub pass_fds: Vec<PassFd>,
    pub new_session: bool,
}

/// Where one of a child's output streams goes: by default into a pipe the parent reads ([`Child::take_stdout`], the
/// stderr tail).
#[derive(Debug, Clone, Default)]
pub enum Redirect {
    /// A pipe: stdout is [`Child::take_stdout`]'s, stderr is kept as the tail.
    #[default]
    Pipe,
    /// `/dev/null`.
    Null,
    /// The parent's own stream.
    Inherit,
    /// The file behind this descriptor (a log): the child writes to it directly, the parent reads nothing.
    To(Arc<OwnedFd>),
}

impl Redirect {
    fn stdio(&self) -> io::Result<Stdio> {
        Ok(match self {
            Redirect::Pipe => Stdio::piped(),
            Redirect::Null => Stdio::null(),
            Redirect::Inherit => Stdio::inherit(),
            Redirect::To(fd) => Stdio::from(fd.try_clone()?),
        })
    }
}

/// What a start may ask for beside the [`Spec`] (`Opts::default()` is a plain [`spawn`]).
#[derive(Debug, Clone, Default)]
pub struct Opts {
    /// The terminal (a pty's slave) that becomes the child's controlling terminal (`TIOCSCTTY` after `setsid`): the
    /// spec must have `new_session`. For a shell on a pty, and a harness that tests what a program does on one.
    pub controlling_tty: Option<Arc<OwnedFd>>,
    /// The child's stdin is this descriptor's file (a pty's slave), whatever `Spec::stdin_null` says.
    pub stdin: Option<Arc<OwnedFd>>,
    /// The child's niceness (`setpriority`), for a job that must not slow the editor.
    pub nice: Option<i32>,
    pub stdout: Redirect,
    pub stderr: Redirect,
    /// The child keeps the descriptors it inherits (3 and up are not closed at its exec): only for a harness that tests
    /// what a sandbox does with descriptors it was handed. Everything else gets 0–2 and its `pass_fds`.
    pub inherit_fds: bool,
    /// An outer seccomp filter on the child (after `no_new_privs`) that answers this syscall number with `EPERM` and
    /// allows the rest, with no architecture check: only for a harness that tests what a sandbox does when the
    /// system refuses a call it needs.
    pub deny_syscall: Option<libc::c_long>,
    /// The child stays in the parent's process group (no group of its own, no session unless `new_session`): only for a
    /// harness that tests a helper which must make its own session, since a group leader cannot. Its pid is then not its
    /// group's: never end it with `kill_group`.
    pub inherit_group: bool,
    /// Keep all of the child's stderr, not its tail ([`StderrTail::get_all`]): for a check that must see every byte.
    pub stderr_all: bool,
}

/// A descriptor the child gets at the number `target` (3 or more; each target once). The same `fd` may go to
/// several targets.
#[derive(Debug, Clone)]
pub struct PassFd {
    pub fd: Arc<OwnedFd>,
    pub target: i32,
}

/// How many spawns were tried again because a target number changed hands (`child_fds`); for the test.
static GUARD_RETRIES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// The files no child may be given as a [`PassFd`] (the hub's listening sockets: call 14's invariant), by device and
/// inode; [`never_pass`] adds one.  Checked in debug builds.
static NEVER_PASS: Mutex<Vec<(u64, u64)>> = Mutex::new(Vec::new());

/// The device and inode of FD's file.
#[allow(clippy::useless_conversion, clippy::unnecessary_cast)]
fn file_id(fd: RawFd) -> Option<(u64, u64)> {
    let mut st = std::mem::MaybeUninit::<libc::stat>::zeroed();
    // SAFETY: fstat writes one `stat` into a buffer of that size
    if unsafe { libc::fstat(fd, st.as_mut_ptr()) } != 0 {
        return None;
    }
    // SAFETY: fstat succeeded, so it filled the buffer
    let st = unsafe { st.assume_init() };
    Some((st.st_dev as u64, st.st_ino as u64))
}

/// FD (a hub's listening socket) is never passed to a child: a spawn that tries panics in debug builds.
pub fn never_pass(fd: &impl AsRawFd) {
    if let Some(id) = file_id(fd.as_raw_fd()) {
        saman::lock(&NEVER_PASS).push(id);
    }
}

/// Bytes of stderr kept: enough for [`STDERR_TAIL_CHARS`] characters of up to four bytes each.
const TAIL_BYTES: usize = STDERR_TAIL_CHARS * 4;
/// After the exit, how long [`Child::wait`] lets the stderr reader catch up (a grandchild may hold stderr open).
const TAIL_SETTLE: Duration = Duration::from_millis(200);

/// A running child. Its pid is also its process-group id. Dropped without [`Child::wait`], it keeps running and
/// tokio reaps it when it exits.
pub struct Child {
    inner: tokio::process::Child,
    pid: i32,
    tail: Arc<Mutex<Vec<u8>>>,
    reader: Option<saman::Task<()>>,
    exited: bool,
}

/// Start `spec`'s program in a process group of its own (a session of its own with `new_session`), with exactly
/// `spec.env` as its environment, SIGINT and SIGQUIT at their defaults (a background-job parent ignores them) and SIGPIPE
/// ignored (std resets it to the default in a child; a child writing to a pipe whose reader left gets EPIPE
/// instead of dying). No `PR_SET_PDEATHSIG`: it fires when the forking thread exits, and tokio's threads come and go.
///
/// The child gets 0–2 and each [`PassFd`] at its target, nothing else (`move_above_targets`, `child_fds`). The spec
/// is consumed: its `PassFd`s are dropped once the child is started.
pub async fn spawn(spec: Spec) -> io::Result<Child> {
    start(spec)
}

/// [`spawn`] with OPTS: redirected streams, a controlling terminal, niceness, all of stderr.
pub async fn spawn_with(spec: Spec, opts: &Opts) -> io::Result<Child> {
    start_with(spec, opts, |_| {})
}

/// [`spawn_with`] for a caller with no runtime: the child is a `std::process::Child` (its pipes the std ones, nothing
/// keeps its stderr), its group and descriptors as for [`spawn`]. For a worker whose child is a shell on a pty.
pub fn spawn_std(spec: &Spec, opts: &Opts) -> io::Result<std::process::Child> {
    launch(spec, opts, |_| {}, |mut cmd| hlaup::spawn(|| cmd.spawn()))
}

/// The calling process becomes SPEC's program (`exec`): its environment is exactly `spec.env`, its directory `spec.cwd`,
/// its signals SIGPIPE ignored and SIGINT and SIGQUIT at their defaults. Only returns on a failure, with its error:
/// for a wrapper that must be the traced command itself, not its parent. `pass_fds`, `new_session` and `opts` do not
/// apply (the process keeps the descriptors and session it has).
pub fn exec(spec: &Spec) -> io::Error {
    use std::os::unix::process::CommandExt;
    let mut cmd = std::process::Command::new(&spec.program);
    cmd.args(&spec.args)
        .env_clear()
        .envs(spec.env.iter().map(|(k, v)| (k, v)));
    if let Some(cwd) = &spec.cwd {
        cmd.current_dir(cwd);
    }
    // SAFETY: runs in the forked child before exec; signal(2) is async-signal-safe.
    unsafe {
        cmd.pre_exec(|| {
            if libc::signal(libc::SIGPIPE, libc::SIG_IGN) == libc::SIG_ERR {
                return Err(io::Error::last_os_error());
            }
            for sig in [libc::SIGINT, libc::SIGQUIT] {
                if libc::signal(sig, libc::SIG_DFL) == libc::SIG_ERR {
                    return Err(io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    cmd.exec()
}

/// [`spawn`], forked from one long-lived thread, `draugr-spawner` (started on first use, kept for the process's
/// life), which enters the caller's runtime for the spawn. Every sandboxed child starts here: bwrap's
/// `--die-with-parent` and `PR_SET_PDEATHSIG` fire when the *forking thread* exits, so a child forked from a pool
/// thread would be killed when that thread retires.
pub async fn spawn_pinned(spec: Spec) -> io::Result<Child> {
    let gone = || io::Error::other("the draugr-spawner thread is gone");
    let (reply, answer) = oneshot::channel();
    let job = Job {
        spec,
        runtime: Handle::current(),
        reply,
    };
    spawner()?.send(job).map_err(|_| gone())?;
    answer.await.map_err(|_| gone())?
}

/// A spawn for the `draugr-spawner` thread: the spec, the caller's runtime and where the child goes.
struct Job {
    spec: Spec,
    runtime: Handle,
    reply: oneshot::Sender<io::Result<Child>>,
}

static SPAWNER: Mutex<Option<mpsc::Sender<Job>>> = Mutex::new(None);

/// Held by a test to stall the spawner thread before it starts the next job.
#[cfg(test)]
static SPAWNER_STALL: Mutex<()> = Mutex::new(());

/// The `draugr-spawner` thread's queue, starting the thread on first use. The thread never exits.
fn spawner() -> io::Result<mpsc::Sender<Job>> {
    let mut slot = saman::lock(&SPAWNER);
    if let Some(tx) = &*slot {
        return Ok(tx.clone());
    }
    let (tx, rx) = mpsc::channel::<Job>();
    saman::spawn_thread("draugr-spawner", move || {
        for job in rx {
            // a test holds this to keep the spawner from starting a job it has queued
            #[cfg(test)]
            drop(saman::lock(&SPAWNER_STALL));
            let _rt = job.runtime.enter();
            if let Err(Ok(child)) = job.reply.send(start(job.spec)) {
                // The caller stopped waiting: nobody owns this child, so its group ends now.
                kill_cancelled(-child.pid);
            }
        }
    })
    .map_err(|e| io::Error::other(e.to_string()))?;
    *slot = Some(tx.clone());
    Ok(tx)
}

/// SIGKILL to `target`, the process group of a child whose caller stopped waiting (`start` made the child a group
/// leader, so its pid names the group: a negative `target`).
fn kill_cancelled(target: i32) {
    #[cfg(test)]
    saman::lock(&CANCELLED).push(target);
    // SAFETY: kill(2) has no memory effects; `target` is a child this thread just started.
    unsafe { libc::kill(target, libc::SIGKILL) };
}

/// The targets `kill_cancelled` was given, for the test.
#[cfg(test)]
static CANCELLED: Mutex<Vec<i32>> = Mutex::new(Vec::new());

fn start(spec: Spec) -> io::Result<Child> {
    start_with(spec, &Opts::default(), |_| {})
}

/// [`start`], with `after_move` run once the descriptors are held and before the spawn (a test closes a held number
/// there, as another thread of the process could).
fn start_with(spec: Spec, opts: &Opts, after_move: impl FnOnce(&mut Moved)) -> io::Result<Child> {
    let spawned = launch(&spec, opts, after_move, |cmd| {
        let mut cmd = Command::from(cmd);
        // under hlaup's lock where unshare is refused: a file written meanwhile is never held open by this fork
        hlaup::spawn(|| cmd.spawn())
    });
    drop(spec);
    let mut inner = spawned?;
    let pid = inner
        .id()
        .and_then(|p| i32::try_from(p).ok())
        .ok_or_else(|| io::Error::other("the child has no pid"))?;
    let tail = Arc::new(Mutex::new(Vec::new()));
    let keep = if opts.stderr_all {
        usize::MAX
    } else {
        TAIL_BYTES
    };
    let reader = inner.stderr.take().map(|mut stderr| {
        let tail = Arc::clone(&tail);
        saman::spawn("draugr-stderr-tail", async move {
            let mut buf = [0u8; 4096];
            while let Ok(n @ 1..) = stderr.read(&mut buf).await {
                let mut t = saman::lock(&tail);
                t.extend_from_slice(&buf[..n]);
                let over = t.len().saturating_sub(keep);
                t.drain(..over);
            }
        })
    });
    Ok(Child {
        inner,
        pid,
        tail,
        reader,
        exited: false,
    })
}

/// The spawn both [`spawn_with`] and [`spawn_std`] make: the checks, the descriptors held, the command built, GO run on it.
fn launch<C>(
    spec: &Spec,
    opts: &Opts,
    after_move: impl FnOnce(&mut Moved),
    go: impl Fn(std::process::Command) -> io::Result<C>,
) -> io::Result<C> {
    if opts.controlling_tty.is_some() && !spec.new_session {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "a controlling terminal needs new_session",
        ));
    }
    if cfg!(debug_assertions) {
        let never = saman::lock(&NEVER_PASS);
        debug_assert!(
            spec.pass_fds
                .iter()
                .all(|p| file_id(p.fd.as_raw_fd()).is_none_or(|id| !never.contains(&id))),
            "a hub's listening socket was passed to a child"
        );
    }
    // A target that holds another file in the child than it did in the parent (`child_fds`) is a spawn tried again:
    // the numbers are held anew. A few tries; a process that closes and opens descriptors that fast is refused.
    let mut after_move = Some(after_move);
    let mut tries = 0;
    loop {
        let mut moved = move_above_targets(&spec.pass_fds)?;
        if let Some(f) = after_move.take() {
            f(&mut moved);
        }
        let expect = std::mem::take(&mut moved.expect);
        let mut cmd = std::process::Command::new(&spec.program);
        cmd.args(&spec.args)
            .env_clear()
            .envs(spec.env.iter().map(|(k, v)| (k, v)))
            .stdin(match &opts.stdin {
                Some(fd) => Stdio::from(fd.try_clone()?),
                None if spec.stdin_null => Stdio::null(),
                None => Stdio::piped(),
            })
            .stdout(opts.stdout.stdio()?)
            .stderr(opts.stderr.stdio()?);
        // std's setpgid runs before the pre_exec closure, and a group leader cannot setsid: so one or the other.
        let new_session = spec.new_session;
        if !new_session && !opts.inherit_group {
            cmd.process_group(0);
        }
        if let Some(cwd) = &spec.cwd {
            cmd.current_dir(cwd);
        }
        let pairs = moved.pairs.clone();
        let guarded = !expect.is_empty();
        let inherit = opts.inherit_fds;
        let filter = opts.deny_syscall.map(deny_filter).transpose()?;
        let (nice, tty) = (
            opts.nice,
            opts.controlling_tty.as_ref().map(|f| f.as_raw_fd()),
        );
        // SAFETY: runs in the forked child before exec; setsid(2), signal(2), close_range(2), fcntl(2), getrlimit(2)
        // and dup2(2) are async-signal-safe and nothing here allocates (`pairs` was built in the parent). std runs
        // pre_exec closures after it has reset SIGPIPE to the default and set up 0–2.
        unsafe {
            cmd.pre_exec(move || {
                if new_session && libc::setsid() < 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::signal(libc::SIGPIPE, libc::SIG_IGN) == libc::SIG_ERR {
                    return Err(io::Error::last_os_error());
                }
                // a parent run as a background job ignores these, and exec keeps an ignored signal ignored
                for sig in [libc::SIGINT, libc::SIGQUIT] {
                    if libc::signal(sig, libc::SIG_DFL) == libc::SIG_ERR {
                        return Err(io::Error::last_os_error());
                    }
                }
                child_fds(&pairs, &expect, inherit)?;
                if let Some(n) = nice
                    && libc::setpriority(libc::PRIO_PROCESS, 0, n) < 0
                {
                    return Err(io::Error::last_os_error());
                }
                if let Some(fd) = tty
                    && libc::ioctl(fd, libc::TIOCSCTTY as _, 0) < 0
                {
                    return Err(io::Error::last_os_error());
                }
                if let Some(f) = &filter {
                    install_filter(f)?;
                }
                Ok(())
            });
        }
        let r = go(cmd);
        drop(moved);
        match r {
            Err(e) if guarded && tries < 4 && e.raw_os_error() == Some(libc::EBUSY) => {
                tries += 1;
                GUARD_RETRIES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            }
            r => return r,
        }
    }
}

/// A built [`Opts::deny_syscall`] filter. seccomp is Linux's: elsewhere there is none to build.
#[cfg(any(target_os = "linux", target_os = "android"))]
type Filter = Vec<libc::sock_filter>;
#[cfg(not(any(target_os = "linux", target_os = "android")))]
type Filter = std::convert::Infallible;

/// In the forked child: `no_new_privs`, then the filter. Only async-signal-safe calls (prctl(2)).
#[cfg(any(target_os = "linux", target_os = "android"))]
fn install_filter(f: &Filter) -> io::Result<()> {
    let prog = libc::sock_fprog {
        len: f.len() as libc::c_ushort,
        filter: f.as_ptr().cast_mut(),
    };
    // SAFETY: prctl(2) with a filter that `prog` points at, alive for the call.
    let failed = unsafe {
        libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
            || libc::prctl(
                libc::PR_SET_SECCOMP,
                libc::SECCOMP_MODE_FILTER,
                &prog as *const libc::sock_fprog,
            ) != 0
    };
    if failed {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn install_filter(f: &Filter) -> io::Result<()> {
    match *f {}
}

/// Outside Linux a filter is refused before the fork: the harness asked for something this system cannot do.
#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn deny_filter(_nr: libc::c_long) -> io::Result<Filter> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "a seccomp filter needs Linux",
    ))
}

/// A filter that answers `nr` with EPERM and allows everything else (no architecture check).
#[cfg(any(target_os = "linux", target_os = "android"))]
fn deny_filter(nr: libc::c_long) -> io::Result<Filter> {
    const LD_W_ABS: u16 = 0x20; // BPF_LD | BPF_W | BPF_ABS
    const JEQ_K: u16 = 0x15; // BPF_JMP | BPF_JEQ | BPF_K
    const RET_K: u16 = 0x06; // BPF_RET | BPF_K
    let nr = u32::try_from(nr).map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidInput, "a syscall number out of range")
    })?;
    let f = |code, jt, jf, k| libc::sock_filter { code, jt, jf, k };
    Ok(vec![
        f(LD_W_ABS, 0, 0, 0),
        f(JEQ_K, 0, 1, nr),
        f(RET_K, 0, 0, libc::SECCOMP_RET_ERRNO | libc::EPERM as u32),
        f(RET_K, 0, 0, libc::SECCOMP_RET_ALLOW),
    ])
}

/// The parent's side of passing descriptors: each source moved above the highest target, and the free numbers from
/// 3 to the highest target held, both until the child is started.
struct Moved {
    /// (the moved source, its target), for the child.
    pairs: Vec<(RawFd, RawFd)>,
    held: Vec<OwnedFd>,
    /// Each target number with the device and inode of the file open on it when the fillers were set: a filler, or
    /// a descriptor the process already held there.
    expect: Vec<(RawFd, (u64, u64))>,
}

/// Validates the targets (each 3 or more, each once), then copies every source with `F_DUPFD_CLOEXEC` to a number
/// above the highest target, so no `dup2` in the child overwrites a source not yet copied.
///
/// Then every free number from 3 to the highest target is filled with a close-on-exec copy until the child is
/// started. std opens the socket that reports a failed exec just before it forks, at the lowest free number; on a
/// target, the child's `dup2` would close it, and a failed exec would look like a start.
fn move_above_targets(pass: &[PassFd]) -> io::Result<Moved> {
    let mut targets: Vec<RawFd> = pass.iter().map(|p| p.target).collect();
    targets.sort_unstable();
    let max = targets.last().copied().unwrap_or(2);
    let valid = targets.first().is_none_or(|&t| t >= 3) && targets.windows(2).all(|w| w[0] != w[1]);
    let Some(above) = max.checked_add(1).filter(|_| valid) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "a passed descriptor's target is below 3, too large, or given twice",
        ));
    };
    let mut moved = Moved {
        pairs: Vec::with_capacity(pass.len()),
        held: Vec::with_capacity(pass.len()),
        expect: Vec::new(),
    };
    for p in pass {
        let fd = dup_cloexec(p.fd.as_raw_fd(), above)?;
        moved.pairs.push((fd.as_raw_fd(), p.target));
        moved.held.push(fd);
    }
    if let Some(&(first, _)) = moved.pairs.first() {
        loop {
            let filler = dup_cloexec(first, 3)?;
            if filler.as_raw_fd() > max {
                break;
            }
            moved.held.push(filler);
        }
        moved.expect = pass
            .iter()
            .filter_map(|p| file_id(p.target).map(|id| (p.target, id)))
            .collect();
    }
    Ok(moved)
}

fn dup_cloexec(fd: RawFd, lowest: RawFd) -> io::Result<OwnedFd> {
    // SAFETY: fcntl(2) on a descriptor we hold; on success the new descriptor is ours alone.
    let new = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, lowest) };
    if new < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `new` was just returned by fcntl and is owned by nobody else.
    Ok(unsafe { OwnedFd::from_raw_fd(new) })
}

/// In the forked child: every descriptor from 3 up is marked close-on-exec, then each moved source is `dup2`'d to
/// its target (`dup2` clears close-on-exec on the copy). So the child keeps exactly 0–2 and its targets, also
/// against descriptors the hub inherited without close-on-exec (from systemd, launchd or Emacs). No allocation.
///
/// Before any `dup2`, no target may hold another file than it did when the fillers were set (`Moved::expect`): a
/// number another thread of the parent closed after that can be the one std opened for reporting a failed exec, and
/// a `dup2` onto it would make that failure look like a start (GL-T6-1). Then the child refuses to go on (`EBUSY`),
/// and the failure comes back through the intact report socket. A number that is simply closed now is fine: nothing
/// took it, and the `dup2` fills it.
fn child_fds(
    pairs: &[(RawFd, RawFd)],
    expect: &[(RawFd, (u64, u64))],
    inherit: bool,
) -> io::Result<()> {
    for &(target, id) in expect {
        if file_id(target).is_some_and(|now| now != id) {
            return Err(io::Error::from_raw_os_error(libc::EBUSY));
        }
    }
    if !inherit {
        cloexec_from(3);
    }
    for &(src, target) in pairs {
        // SAFETY: dup2(2) on descriptors this child holds.
        while unsafe { libc::dup2(src, target) } < 0 {
            let e = io::Error::last_os_error();
            if e.kind() != io::ErrorKind::Interrupted {
                return Err(e);
            }
        }
    }
    Ok(())
}

/// Marks every descriptor from `first` up close-on-exec. Linux and Android (the same kernel call):
/// `close_range(first, ~0, CLOSE_RANGE_CLOEXEC)`; a kernel before 5.11 refuses it and the loop does the work.
/// No allocation, so it may run between a fork and an exec (the escape harness's runs without a sandbox use it too).
#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn cloexec_from(first: RawFd) {
    const CLOSE_RANGE_CLOEXEC: libc::c_uint = 1 << 2;
    // SAFETY: a raw system call with integer arguments.
    let r = unsafe {
        libc::syscall(
            libc::SYS_close_range,
            first as libc::c_uint,
            libc::c_uint::MAX,
            CLOSE_RANGE_CLOEXEC,
        )
    };
    if r != 0 {
        cloexec_loop(first);
    }
}

/// Marks every descriptor from `first` up close-on-exec. macOS and the rest: no `close_range` with a close-on-exec
/// flag, so the loop. (Android is the branch above.)
#[cfg(not(any(target_os = "linux", target_os = "android")))]
pub fn cloexec_from(first: RawFd) {
    cloexec_loop(first);
}

/// `fcntl(F_SETFD, FD_CLOEXEC)` on every number from `first` to the descriptor limit (a closed number answers
/// `EBADF`). An unlimited limit is taken as 2^20, Linux's default `nr_open`.
fn cloexec_loop(first: RawFd) {
    let mut lim = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: getrlimit(2) writes into `lim`.
    let end = if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) } == 0 {
        lim.rlim_cur.min(1 << 20) as RawFd
    } else {
        1 << 20
    };
    for fd in first..end {
        // SAFETY: fcntl(2) with an integer argument; FD_CLOEXEC is the only descriptor flag.
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    }
}

impl Child {
    /// The child's pid, which is also its process-group id.
    pub fn id(&self) -> i32 {
        self.pid
    }

    /// The child's stdin (a pipe unless the spec had `stdin_null`). [`Child::wait`] closes it if it was not taken.
    pub fn take_stdin(&mut self) -> Option<ChildStdin> {
        self.inner.stdin.take()
    }

    pub fn take_stdout(&mut self) -> Option<ChildStdout> {
        self.inner.stdout.take()
    }

    /// The exit status, once: `Ok(Some(status))` the first time, `Ok(None)` on every later call.
    pub async fn wait(&mut self) -> io::Result<Option<ExitStatus>> {
        if self.exited {
            return Ok(None);
        }
        let status = self.inner.wait().await?;
        self.exited = true;
        if let Some(reader) = self.reader.take() {
            // real time, whatever clock a test installed: the grandchild holding stderr open is a real process
            tokio::select! {
                _ = reader => {}
                () = stund::real::sleep(TAIL_SETTLE) => {}
            }
        }
        Ok(Some(status))
    }

    /// [`Child::wait`], but once DEADLINE has passed on the installed clock the child's whole process group is killed
    /// (SIGKILL: a grandchild in the group goes too) and its status is the kill's. The processes standard's deadline
    /// (docs/develop/standards/processes.md).
    pub async fn wait_deadline(&mut self, deadline: Duration) -> io::Result<Option<ExitStatus>> {
        if let Ok(done) = stund::timeout(deadline, self.wait()).await {
            return done;
        }
        // SAFETY: kill(2) on the child's own group (its pid is the group's id, never ours: `spawn` makes a new group)
        if unsafe { libc::kill(-self.pid, libc::SIGKILL) } != 0 {
            let e = io::Error::last_os_error();
            if e.raw_os_error() != Some(libc::ESRCH) {
                return Err(e);
            }
        }
        self.wait().await
    }

    /// The last [`STDERR_TAIL_CHARS`] characters the child wrote to stderr so far (invalid UTF-8 replaced).
    pub fn stderr_tail(&self) -> String {
        self.stderr().get()
    }

    /// The same tail as a handle that outlives a move of the child (into a task that waits for it).
    pub fn stderr(&self) -> StderrTail {
        StderrTail(self.tail.clone())
    }
}

/// A child's stderr tail, readable from anywhere while the child runs and after ([`Child::stderr`]).
#[derive(Clone, Debug)]
pub struct StderrTail(Arc<Mutex<Vec<u8>>>);

impl StderrTail {
    /// [`Child::stderr_tail`].
    pub fn get(&self) -> String {
        let bytes = saman::lock(&self.0);
        let text = String::from_utf8_lossy(&bytes);
        let skip = text.chars().count().saturating_sub(STDERR_TAIL_CHARS);
        text.chars().skip(skip).collect()
    }

    /// Everything kept: all of stderr when the child was started with `Opts::stderr_all`, else the tail's bytes.
    pub fn get_all(&self) -> String {
        String::from_utf8_lossy(&saman::lock(&self.0)).into_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, BufReader};

    fn sh(script: &str, stdin_null: bool) -> Spec {
        Spec {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), script.into()],
            env: crate::env::build(&["PATH"], &[], &[]),
            cwd: None,
            stdin_null,
            pass_fds: vec![],
            new_session: false,
        }
    }

    fn pipe() -> (OwnedFd, OwnedFd) {
        let mut fds = [0; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        // SAFETY: pipe(2) just returned these two descriptors, owned by nobody else.
        let (r, w) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        for fd in [&r, &w] {
            assert_eq!(
                unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) },
                0
            );
        }
        (r, w)
    }

    /// Everything readable from `r` until EOF, or `None` when no EOF came within 30 s (a writer is still open; the
    /// deadline only bounds a failure).
    fn read_to_eof(r: OwnedFd) -> Option<String> {
        let (tx, rx) = std::sync::mpsc::channel();
        saman::spawn_thread("read-to-eof", move || {
            let mut s = String::new();
            if let Err(e) = io::Read::read_to_string(&mut std::fs::File::from(r), &mut s) {
                tracing::debug!(error = %e, "the read ended early");
            }
            if tx.send(s).is_err() {
                tracing::debug!("the reader gave up first");
            }
        })
        .unwrap();
        rx.recv_timeout(Duration::from_secs(30)).ok()
    }

    fn pass(fd: &Arc<OwnedFd>, target: i32) -> PassFd {
        PassFd {
            fd: Arc::clone(fd),
            target,
        }
    }

    #[cfg(debug_assertions)]
    #[test]
    #[should_panic(expected = "a hub's listening socket was passed to a child")]
    fn a_hubs_listening_socket_is_never_passed() {
        saman::block_on_current(async {
            // kept open for the test binary's life, so its inode is never another file's
            let (sock, _) = std::os::unix::net::UnixStream::pair().unwrap();
            never_pass(&sock);
            let fd = Arc::new(OwnedFd::from(sock.try_clone().unwrap()));
            std::mem::forget(sock);
            let mut spec = sh("exit 0", true);
            spec.pass_fds.push(pass(&fd, 3));
            assert!(spawn(spec).await.is_err());
        })
    }

    #[test]
    fn passed_fds_arrive_at_their_numbers() {
        saman::block_on_current(async {
            // Targets 3, 4, 5, listed out of order.
            let pipes: Vec<_> = (0..3).map(|_| pipe()).collect();
            let mut spec = sh(
                "for n in 3 4 5; do echo fd$n > /dev/fd/$n; done; exit 0",
                true,
            );
            for (i, target) in [(0, 5), (1, 3), (2, 4)] {
                spec.pass_fds.push(PassFd {
                    fd: Arc::new(pipes[i].1.try_clone().unwrap()),
                    target,
                });
            }
            let reads: Vec<OwnedFd> = pipes.into_iter().map(|(r, _)| r).collect();
            let mut child = spawn(spec).await.unwrap();
            assert!(child.wait().await.unwrap().unwrap().success());
            let got: Vec<_> = reads.into_iter().map(read_to_eof).collect();
            assert_eq!(
                got,
                [
                    Some("fd5\n".into()),
                    Some("fd3\n".into()),
                    Some("fd4\n".into())
                ]
            );

            // Targets that are the sources' own numbers, rotated: a dup2 in list order would overwrite a source
            // before it is moved.
            let pipes: Vec<_> = (0..3).map(|_| pipe()).collect();
            let nums: Vec<i32> = pipes.iter().map(|(_, w)| w.as_raw_fd()).collect();
            let script = format!(
                "for n in {} {} {}; do echo fd$n > /dev/fd/$n; done; exit 0",
                nums[0], nums[1], nums[2]
            );
            let mut spec = sh(&script, true);
            let (reads, writes): (Vec<OwnedFd>, Vec<OwnedFd>) = pipes.into_iter().unzip();
            let writes: Vec<Arc<OwnedFd>> = writes.into_iter().map(Arc::new).collect();
            for i in 0..3 {
                spec.pass_fds.push(pass(&writes[i], nums[(i + 1) % 3]));
            }
            drop(writes);
            let mut child = spawn(spec).await.unwrap();
            assert!(child.wait().await.unwrap().unwrap().success());
            let got: Vec<_> = reads.into_iter().map(read_to_eof).collect();
            let want: Vec<_> = (0..3)
                .map(|i| Some(format!("fd{}\n", nums[(i + 1) % 3])))
                .collect();
            assert_eq!(got, want);
        })
    }

    #[test]
    fn nothing_else_leaks() {
        saman::block_on_current(async {
            // The parent holds a descriptor without close-on-exec, above the targets.
            let (_r, w) = pipe();
            let leaky = unsafe { libc::fcntl(w.as_raw_fd(), libc::F_DUPFD, 100) };
            assert!(leaky >= 100);
            // SAFETY: fcntl just returned this descriptor.
            let leaky = unsafe { OwnedFd::from_raw_fd(leaky) };
            assert_eq!(
                unsafe { libc::fcntl(leaky.as_raw_fd(), libc::F_SETFD, 0) },
                0
            );
            assert_eq!(unsafe { libc::fcntl(leaky.as_raw_fd(), libc::F_GETFD) }, 0);
            let pipes: Vec<_> = (0..3).map(|_| pipe()).collect();
            // The shell's own descriptors, tested by `[ -e /dev/fd/N ]` (a stat; the shell opens nothing for it).
            let mut spec = sh(
                "i=0; while [ $i -lt 512 ]; do [ -e /dev/fd/$i ] && printf '%s ' $i; i=$((i+1)); done",
                true,
            );
            for (i, (_, w)) in pipes.iter().enumerate() {
                spec.pass_fds
                    .push(pass(&Arc::new(w.try_clone().unwrap()), 3 + i as i32));
            }
            let mut child = spawn(spec).await.unwrap();
            let mut out = String::new();
            child
                .take_stdout()
                .unwrap()
                .read_to_string(&mut out)
                .await
                .unwrap();
            assert!(child.wait().await.unwrap().unwrap().success());
            assert_eq!(
                out.trim_end(),
                "0 1 2 3 4 5",
                "leaky fd {}",
                leaky.as_raw_fd()
            );
        })
    }

    #[test]
    fn spawn_drops_passed_fds() {
        saman::block_on_current(async {
            let (r, w) = pipe();
            let mut spec = sh("exit 0", true);
            spec.pass_fds.push(PassFd {
                fd: Arc::new(w),
                target: 3,
            });
            let mut child = spawn(spec).await.unwrap();
            assert!(child.wait().await.unwrap().unwrap().success());
            assert_eq!(
                read_to_eof(r).as_deref(),
                Some(""),
                "a copy of the write end is still open"
            );
        })
    }

    /// GL-T6-1: another thread closes a held number that is a target; std's exec-report socket may take it, and the
    /// child's `dup2` onto it must not make a failed exec look like a start: the child stops (`EBUSY`), the spawn is
    /// tried again, and the exec failure is then reported as it is.
    ///
    /// Fd numbers are the process's: under `cargo test` the other tests' threads open files meanwhile and can take the
    /// numbers this test frees before std's report pipe does, so the guard never fires (the escape lane, 2026-11-22).
    /// The test therefore runs itself again as the only test of a process of its own (nextest gives each test one).
    #[test]
    fn a_failed_exec_is_reported_when_a_held_number_was_closed() {
        saman::block_on_current(async {
            const NAME: &str =
                "spawn::tests::a_failed_exec_is_reported_when_a_held_number_was_closed";
            if std::env::var_os("DRAUGR_TEST_ALONE").is_none() {
                let out = std::process::Command::new(std::env::current_exe().unwrap())
                    .args(["--exact", NAME, "--test-threads", "1", "--nocapture"])
                    .env("DRAUGR_TEST_ALONE", "1")
                    .output()
                    .unwrap();
                let text = format!(
                    "{}{}",
                    String::from_utf8_lossy(&out.stdout),
                    String::from_utf8_lossy(&out.stderr)
                );
                assert!(out.status.success(), "the test alone failed:\n{text}");
                assert!(
                    text.contains("1 passed"),
                    "the test alone did not run:\n{text}"
                );
                return;
            }
            let (_r, w) = pipe();
            let w = Arc::new(w);
            let mut spec = sh("exit 0", true);
            spec.program = "/nonexistent/glp-no-such-program".into();
            // targets 3..=40, every filler gone: std opens /dev/null, two pipes for stdout and stderr, then its report pipe,
            // on the lowest free numbers (the test process holds most of 3..22), so the report pipe's write end (the
            // child's) lands on a target
            spec.pass_fds = (3..=40).map(|t| pass(&w, t)).collect();
            let before = GUARD_RETRIES.load(std::sync::atomic::Ordering::Relaxed);
            let err = start_with(spec, &Opts::default(), |moved| {
                moved.held.retain(|f| f.as_raw_fd() > 40)
            })
            .err()
            .expect("a failed exec is an error");
            // the guard stopped the first try (EBUSY), the second try held the numbers again and std reported the exec
            assert!(
                GUARD_RETRIES.load(std::sync::atomic::Ordering::Relaxed) > before,
                "the guard never fired"
            );
            assert_eq!(err.raw_os_error(), Some(libc::ENOENT), "{err}");
        })
    }

    #[test]
    fn bad_targets_are_refused() {
        saman::block_on_current(async {
            // 2_000_000: above any descriptor limit (Linux's nr_open is at most 2^20 by default), so the parent's
            // F_DUPFD_CLOEXEC refuses it (EINVAL).
            for targets in [vec![2], vec![-1], vec![3, 3], vec![2_000_000]] {
                let (_r, w) = pipe();
                let w = Arc::new(w);
                let mut spec = sh("exit 0", true);
                spec.pass_fds = targets.iter().map(|&t| pass(&w, t)).collect();
                let err = spawn(spec).await.err().expect("refused");
                assert_eq!(err.kind(), io::ErrorKind::InvalidInput, "{targets:?}");
            }
        })
    }

    // Linux only: PR_SET_PDEATHSIG is a Linux prctl (Android: the same kernel, but the test needs util-linux's
    // setpriv, which Android lacks).
    #[cfg(target_os = "linux")]
    #[test]
    fn pinned_spawn_survives_its_callers_thread() {
        use tokio::io::AsyncWriteExt;
        // The runtime reports each thread that retires (its tid, from the thread itself).
        let (stopped_tx, mut stopped) = tokio::sync::mpsc::unbounded_channel();
        let rt = saman::Executor::tuned(1, |b| {
            b.thread_keep_alive(Duration::from_millis(100))
                .on_thread_stop(move || {
                    // a closed channel means the test ended first
                    stopped_tx
                        .send(unsafe { libc::gettid() })
                        .unwrap_or_default();
                });
        })
        .unwrap();
        rt.block_on(async {
            let spec = Spec {
                program: "/usr/bin/setpriv".into(),
                args: [
                    "--pdeathsig",
                    "KILL",
                    "--",
                    "/bin/sh",
                    "-c",
                    "read x; echo alive",
                ]
                .map(OsString::from)
                .to_vec(),
                ..sh("", false)
            };
            let mut child = saman::spawn_blocking("pinned-spawn", || {
                Handle::current().block_on(spawn_pinned(spec))
            })
            .await
            .unwrap()
            .unwrap();
            // The blocking thread retires after 100 ms idle; a child forked there would get SIGKILL as the thread
            // exits. Wait for the retirement itself: the runtime says it is stopping, and its /proc entry goes after
            // the kernel has sent the signals of its exit. (The deadline only bounds a failure.)
            let tid = tokio::time::timeout(Duration::from_secs(30), stopped.recv())
                .await
                .expect("the blocking thread retired within 30 s")
                .expect("the runtime is running");
            let entry = format!("/proc/self/task/{tid}");
            tokio::time::timeout(Duration::from_secs(30), async {
                while std::path::Path::new(&entry).exists() {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .expect("the retired thread exited within 30 s");
            // Alive now means alive for good: the child answers, and a SIGKILL sent before this would have ended it.
            let mut stdin = child.take_stdin().unwrap();
            stdin.write_all(b"\n").await.unwrap();
            let mut lines = BufReader::new(child.take_stdout().unwrap()).lines();
            let said = lines.next_line().await.unwrap();
            if said.is_none() {
                unsafe { libc::kill(-child.id(), libc::SIGKILL) };
            }
            assert_eq!(
                said.as_deref(),
                Some("alive"),
                "the child died with its caller's thread"
            );
            assert!(child.wait().await.unwrap().unwrap().success());
        });
    }

    /// GL-T6-3: a caller that stopped waiting leaves a child nobody owns; the spawner kills its whole group (a
    /// negative target), not only its leader.
    #[test]
    fn a_cancelled_pinned_spawn_kills_the_group() {
        saman::block_on_current(async {
            use std::future::Future;
            let stall = saman::lock(&SPAWNER_STALL);
            let before = saman::lock(&CANCELLED).len();
            // queue the job, then drop the caller before the spawner may start it
            let mut fut = Box::pin(spawn_pinned(sh("sleep 30", true)));
            let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
            assert!(
                fut.as_mut().poll(&mut cx).is_pending(),
                "the spawner was stalled"
            );
            drop(fut);
            drop(stall);
            let sent =
                skuld::wait_until_async("the spawner killed the cancelled child", 10, || async {
                    let fresh: Vec<i32> = saman::lock(&CANCELLED)[before..].to_vec();
                    (!fresh.is_empty()).then_some(fresh)
                })
                .await;
            assert!(
                sent.iter().all(|&t| t < -1),
                "the group is killed (a negative pid), not the leader alone: {sent:?}"
            );
        })
    }

    #[test]
    fn pinned_spawn_passes_fds_too() {
        saman::block_on_current(async {
            let (r, w) = pipe();
            let mut spec = sh("echo pinned >&3", true);
            spec.pass_fds.push(PassFd {
                fd: Arc::new(w),
                target: 3,
            });
            let mut child = spawn_pinned(spec).await.unwrap();
            assert!(child.wait().await.unwrap().unwrap().success());
            assert_eq!(read_to_eof(r).as_deref(), Some("pinned\n"));
        })
    }

    #[test]
    fn own_process_group_and_sigpipe_ignored() {
        saman::block_on_current(async {
            // The shell sends itself SIGPIPE and lives to say so only if it started with SIGPIPE ignored. (Reading the
            // disposition back is not portable: macOS's /bin/sh, bash 3.2, leaves a signal ignored at entry out of `trap`.)
            let mut child = spawn(sh("kill -s PIPE $$; echo alive; read x; exit 0", false))
                .await
                .unwrap();
            let pid = child.id();
            let mut lines = BufReader::new(child.take_stdout().unwrap()).lines();
            let first = lines.next_line().await.unwrap();
            assert_eq!(first.as_deref(), Some("alive"), "the child died of SIGPIPE");
            // While the child waits on its stdin: it leads its own group, not ours.
            assert_eq!(unsafe { libc::getpgid(pid) }, pid);
            assert_ne!(pid, unsafe { libc::getpgrp() });
            drop(child.take_stdin());
            assert!(child.wait().await.unwrap().unwrap().success());
        })
    }

    /// A parent started as a background job (`nohup`, a script's `&`) has SIGINT and SIGQUIT ignored, and a child
    /// inherits that: a shell then cannot trap SIGINT and a kernel's interrupt would do nothing. The child gets both
    /// at their defaults.
    #[test]
    fn a_child_gets_sigint_and_sigquit_at_their_defaults_whatever_the_parent_ignores() {
        saman::block_on_current(async {
            // SAFETY: signal(2) on our own disposition, restored right after the spawn (the child has forked by then).
            let (int, quit) = unsafe {
                (
                    libc::signal(libc::SIGINT, libc::SIG_IGN),
                    libc::signal(libc::SIGQUIT, libc::SIG_IGN),
                )
            };
            let child = spawn(sh(
            "trap 'echo got-int' INT; trap 'echo got-quit' QUIT; kill -INT $$; kill -QUIT $$; echo done",
            true,
        ))
        .await;
            // SAFETY: as above
            unsafe {
                libc::signal(libc::SIGINT, int);
                libc::signal(libc::SIGQUIT, quit);
            }
            let mut child = child.unwrap();
            let mut lines = BufReader::new(child.take_stdout().unwrap()).lines();
            let mut said = Vec::new();
            while let Some(l) = lines.next_line().await.unwrap() {
                said.push(l);
            }
            assert_eq!(said, ["got-int", "got-quit", "done"]);
        })
    }

    /// `new_session`: the child leads a session of its own (so it can never take this process's terminal, and the
    /// reduced-tier helper's own `setsid()` is not refused), and its pid is still its process group's, so the
    /// group can be killed as one.
    #[test]
    fn new_session_leads_a_session_and_its_group() {
        saman::block_on_current(async {
            for new_session in [false, true] {
                let mut spec = sh("read x; exit 0", false);
                spec.new_session = new_session;
                let mut child = spawn_pinned(spec).await.unwrap();
                let pid = child.id();
                // SAFETY: plain queries about our own child.
                let (pgid, sid) = unsafe { (libc::getpgid(pid), libc::getsid(pid)) };
                drop(child.take_stdin());
                assert!(child.wait().await.unwrap().unwrap().success());
                assert_eq!(pgid, pid, "new_session {new_session}: leads its group");
                if new_session {
                    assert_eq!(sid, pid, "leads a session of its own");
                } else {
                    assert_eq!(sid, unsafe { libc::getsid(0) }, "stays in ours");
                }
            }
        })
    }

    #[test]
    fn exit_reported_once() {
        saman::block_on_current(async {
            let mut child = spawn(sh("exit 3", true)).await.unwrap();
            assert_eq!(child.wait().await.unwrap().unwrap().code(), Some(3));
            assert!(child.wait().await.unwrap().is_none());
        })
    }

    #[test]
    fn stderr_tail_keeps_the_last_8000_characters() {
        saman::block_on_current(async {
            let mut child = spawn(sh(
                "head -c 9000 /dev/zero | tr '\\0' a >&2; printf b >&2",
                true,
            ))
            .await
            .unwrap();
            assert!(child.wait().await.unwrap().unwrap().success());
            let tail = child.stderr_tail();
            assert_eq!(tail.chars().count(), STDERR_TAIL_CHARS);
            assert!(tail.ends_with("ab"), "{}", &tail[tail.len() - 10..]);
        })
    }

    fn opts(f: impl FnOnce(&mut Opts)) -> Opts {
        let mut o = Opts::default();
        f(&mut o);
        o
    }

    #[test]
    fn a_stream_sent_to_a_file_is_written_there_and_not_piped() {
        saman::block_on_current(async {
            let dir = tempfile::tempdir().unwrap();
            let log = eitri::open_append(&dir.path().join("log"), Some(0o600)).unwrap();
            let fd: OwnedFd = log.into();
            let to = Redirect::To(Arc::new(fd));
            let o = opts(|o| {
                o.stdout = to.clone();
                o.stderr = to.clone();
            });
            let mut child = spawn_with(sh("echo out; echo err >&2", true), &o)
                .await
                .unwrap();
            assert!(child.take_stdout().is_none(), "stdout is not a pipe");
            assert!(child.wait().await.unwrap().unwrap().success());
            assert_eq!(child.stderr_tail(), "", "stderr is not kept");
            let text = eitri::read_string(&dir.path().join("log"), 1 << 20).unwrap();
            assert!(text.contains("out") && text.contains("err"), "{text}");
        })
    }

    #[test]
    fn a_null_stream_is_empty_and_all_of_stderr_can_be_kept() {
        saman::block_on_current(async {
            let o = opts(|o| o.stdout = Redirect::Null);
            let mut child = spawn_with(sh("echo gone", true), &o).await.unwrap();
            assert!(child.take_stdout().is_none());
            assert!(child.wait().await.unwrap().unwrap().success());
            let all = opts(|o| o.stderr_all = true);
            let mut child = spawn_with(
                sh(
                    "head -c 40000 /dev/zero | tr '\\0' a >&2; printf z >&2",
                    true,
                ),
                &all,
            )
            .await
            .unwrap();
            assert!(child.wait().await.unwrap().unwrap().success());
            let kept = child.stderr().get_all();
            assert_eq!(kept.len(), 40001, "all of stderr, not a tail");
            assert!(kept.starts_with('a') && kept.ends_with('z'));
        })
    }

    #[test]
    fn a_niced_child_runs_at_that_niceness() {
        saman::block_on_current(async {
            let o = opts(|o| o.nice = Some(7));
            let mut child = spawn_with(sh("nice", true), &o).await.unwrap();
            let mut out = String::new();
            child
                .take_stdout()
                .unwrap()
                .read_to_string(&mut out)
                .await
                .unwrap();
            assert!(child.wait().await.unwrap().unwrap().success());
            let base: i32 = {
                let mut plain = spawn(sh("nice", true)).await.unwrap();
                let mut o = String::new();
                plain
                    .take_stdout()
                    .unwrap()
                    .read_to_string(&mut o)
                    .await
                    .unwrap();
                plain.wait().await.unwrap();
                o.trim().parse().unwrap()
            };
            assert_eq!(out.trim().parse::<i32>().unwrap(), base + 7);
        })
    }

    #[test]
    fn a_controlling_terminal_is_the_childs_and_needs_a_session() {
        saman::block_on_current(async {
            // field 7 of /proc/self/stat is the controlling terminal's number: 0 without one
            let probe = "cut -d' ' -f7 /proc/self/stat";
            // SAFETY: posix_openpt and friends on descriptors this test owns
            let (master, slave) = unsafe {
                let m = libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY);
                assert!(m >= 0 && libc::grantpt(m) == 0 && libc::unlockpt(m) == 0);
                let name = libc::ptsname(m);
                let s = libc::open(name, libc::O_RDWR | libc::O_NOCTTY);
                assert!(s >= 0);
                (OwnedFd::from_raw_fd(m), OwnedFd::from_raw_fd(s))
            };
            let slave = Arc::new(slave);
            let mut spec = sh(probe, true);
            spec.new_session = true;
            let o = opts(|o| o.controlling_tty = Some(slave.clone()));
            let mut child = spawn_with(spec, &o).await.unwrap();
            let mut out = String::new();
            child
                .take_stdout()
                .unwrap()
                .read_to_string(&mut out)
                .await
                .unwrap();
            assert!(child.wait().await.unwrap().unwrap().success());
            assert_ne!(out.trim(), "0", "the child has a controlling terminal");
            let no_session = sh(probe, true);
            let err = spawn_with(no_session, &o).await.err().expect("refused");
            assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
            drop(master);
        })
    }

    #[test]
    fn exec_replaces_the_process_with_the_program() {
        if std::env::var_os("DRAUGR_EXEC_CHILD").is_some() {
            let mut spec = sh("exit 7", true);
            spec.env = crate::env::build(&["PATH"], &[], &[]);
            let e = exec(&spec);
            panic!("exec returned: {e}");
        }
        let spec = Spec {
            program: std::env::current_exe().unwrap(),
            args: [
                "--exact",
                "spawn::tests::exec_replaces_the_process_with_the_program",
                "--nocapture",
                "--test-threads",
                "1",
            ]
            .map(Into::into)
            .into(),
            env: crate::env::build(&["PATH"], &[], &[("DRAUGR_EXEC_CHILD", "1".as_ref())]),
            cwd: None,
            stdin_null: true,
            pass_fds: vec![],
            new_session: false,
        };
        let out = crate::run::run(spec, Duration::from_secs(60)).unwrap();
        assert_eq!(out.status.code(), Some(7), "{}", out.stderr);
        let said = String::from_utf8_lossy(&out.stdout);
        assert!(
            !said.contains("test result"),
            "the test harness ended itself: {said}"
        );
    }

    #[test]
    fn a_std_child_leads_its_group_and_writes_where_it_was_sent() {
        let dir = tempfile::tempdir().unwrap();
        let log: OwnedFd = eitri::open_append(&dir.path().join("log"), Some(0o600))
            .unwrap()
            .into();
        let to = Redirect::To(Arc::new(log));
        let o = opts(|o| {
            o.stdout = to.clone();
            o.stderr = to.clone();
            o.stdin = Some(Arc::new(std::fs::File::open("/dev/null").unwrap().into()));
        });
        let mut child = spawn_std(&sh("echo std-child; ps -o pgid= -p $$", true), &o).unwrap();
        assert!(child.wait().unwrap().success());
        let text = eitri::read_string(&dir.path().join("log"), 1 << 20).unwrap();
        assert!(text.contains("std-child"), "{text}");
        let pgid: i32 = text.lines().last().unwrap().trim().parse().unwrap();
        assert_eq!(pgid, child.id() as i32, "the child leads its group");
    }

    #[test]
    fn an_inherited_descriptor_reaches_the_child_only_when_asked_for() {
        saman::block_on_current(async {
            let mut fds = [0 as libc::c_int; 2];
            // SAFETY: pipe(2) fills two descriptors, which this test owns and does not mark close-on-exec
            let (keep, other) = unsafe {
                assert_eq!(libc::pipe(fds.as_mut_ptr()), 0);
                (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1]))
            };
            let n = keep.as_raw_fd();
            let probe =
                format!("if [ -e /proc/self/fd/{n} ]; then echo held; else echo closed; fi");
            let ask = |o: &Opts| {
                let (o, probe) = (o.clone(), probe.clone());
                async move {
                    let mut child = spawn_with(sh(&probe, true), &o).await.unwrap();
                    let mut out = String::new();
                    child
                        .take_stdout()
                        .unwrap()
                        .read_to_string(&mut out)
                        .await
                        .unwrap();
                    child.wait().await.unwrap();
                    out.trim().to_owned()
                }
            };
            assert_eq!(
                ask(&Opts::default()).await,
                "closed",
                "a plain spawn gives 0-2 only"
            );
            assert_eq!(ask(&opts(|o| o.inherit_fds = true)).await, "held");
            drop((keep, other));
        })
    }
}
