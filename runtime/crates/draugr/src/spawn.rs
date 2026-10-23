//! Starting a child: an explicit environment, its own process group, SIGPIPE ignored, stderr kept as a bounded
//! tail, exactly one exit status. Descriptors: the child gets 0–2 and the [`PassFd`]s at their numbers, nothing
//! else. Sandboxed children start from one long-lived thread ([`spawn_pinned`]).

use std::ffi::OsString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::PathBuf;
use std::process::{ExitStatus, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::process::{ChildStdin, ChildStdout, Command};
use tokio::runtime::Handle;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

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

/// A descriptor the child gets at the number `target` (3 or more; each target once). The same `fd` may go to
/// several targets.
#[derive(Debug, Clone)]
pub struct PassFd {
    pub fd: Arc<OwnedFd>,
    pub target: i32,
}

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
        NEVER_PASS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(id);
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
    reader: Option<JoinHandle<()>>,
    exited: bool,
}

/// Start `spec`'s program in a process group of its own (a session of its own with `new_session`), with exactly
/// `spec.env` as its environment and SIGPIPE
/// ignored (std resets it to the default in a child; a child writing to a pipe whose reader left gets EPIPE
/// instead of dying). No `PR_SET_PDEATHSIG`: it fires when the forking thread exits, and tokio's threads come and go.
///
/// The child gets 0–2 and each [`PassFd`] at its target, nothing else (`move_above_targets`, `child_fds`). The spec
/// is consumed: its `PassFd`s are dropped once the child is started.
pub async fn spawn(spec: Spec) -> io::Result<Child> {
    start(spec)
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

/// The `draugr-spawner` thread's queue, starting the thread on first use. The thread never exits.
fn spawner() -> io::Result<mpsc::Sender<Job>> {
    let mut slot = SPAWNER.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(tx) = &*slot {
        return Ok(tx.clone());
    }
    let (tx, rx) = mpsc::channel::<Job>();
    std::thread::Builder::new()
        .name("draugr-spawner".into())
        .spawn(move || {
            for job in rx {
                let _rt = job.runtime.enter();
                if let Err(Ok(child)) = job.reply.send(start(job.spec)) {
                    // The caller stopped waiting: nobody owns this child, so its group ends now.
                    // SAFETY: kill(2) on the child's own process group (its pid; `start` made it a leader).
                    unsafe { libc::kill(-child.pid, libc::SIGKILL) };
                }
            }
        })?;
    *slot = Some(tx.clone());
    Ok(tx)
}

fn start(spec: Spec) -> io::Result<Child> {
    if cfg!(debug_assertions) {
        let never = NEVER_PASS.lock().unwrap_or_else(|e| e.into_inner());
        debug_assert!(
            spec.pass_fds
                .iter()
                .all(|p| file_id(p.fd.as_raw_fd()).is_none_or(|id| !never.contains(&id))),
            "a hub's listening socket was passed to a child"
        );
    }
    let moved = move_above_targets(&spec.pass_fds)?;
    let mut cmd = Command::new(&spec.program);
    cmd.args(&spec.args)
        .env_clear()
        .envs(spec.env.iter().map(|(k, v)| (k, v)))
        .stdin(if spec.stdin_null {
            Stdio::null()
        } else {
            Stdio::piped()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // std's setpgid runs before the pre_exec closure, and a group leader cannot setsid: so one or the other.
    let new_session = spec.new_session;
    if !new_session {
        cmd.process_group(0);
    }
    if let Some(cwd) = &spec.cwd {
        cmd.current_dir(cwd);
    }
    let pairs = moved.pairs.clone();
    // SAFETY: runs in the forked child before exec; setsid(2), signal(2), close_range(2), fcntl(2), getrlimit(2) and
    // dup2(2) are async-signal-safe and nothing here allocates (`pairs` was built in the parent). std runs pre_exec
    // closures after it has reset SIGPIPE to the default and set up 0–2.
    unsafe {
        cmd.pre_exec(move || {
            if new_session && libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::signal(libc::SIGPIPE, libc::SIG_IGN) == libc::SIG_ERR {
                return Err(io::Error::last_os_error());
            }
            child_fds(&pairs)
        });
    }
    let spawned = cmd.spawn();
    drop(moved);
    drop(spec);
    let mut inner = spawned?;
    let pid = inner
        .id()
        .and_then(|p| i32::try_from(p).ok())
        .ok_or_else(|| io::Error::other("the child has no pid"))?;
    let tail = Arc::new(Mutex::new(Vec::new()));
    let reader = inner.stderr.take().map(|mut stderr| {
        let tail = Arc::clone(&tail);
        tokio::spawn(async move {
            let mut buf = [0u8; 4096];
            while let Ok(n @ 1..) = stderr.read(&mut buf).await {
                let mut t = tail.lock().unwrap_or_else(|e| e.into_inner());
                t.extend_from_slice(&buf[..n]);
                let over = t.len().saturating_sub(TAIL_BYTES);
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

/// The parent's side of passing descriptors: each source moved above the highest target, and the free numbers from
/// 3 to the highest target held, both until the child is started.
struct Moved {
    /// (the moved source, its target), for the child.
    pairs: Vec<(RawFd, RawFd)>,
    held: Vec<OwnedFd>,
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
fn child_fds(pairs: &[(RawFd, RawFd)]) -> io::Result<()> {
    cloexec_from(3);
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
            let _ = tokio::time::timeout(TAIL_SETTLE, reader).await;
        }
        Ok(Some(status))
    }

    /// The last [`STDERR_TAIL_CHARS`] characters the child wrote to stderr so far (invalid UTF-8 replaced).
    pub fn stderr_tail(&self) -> String {
        let bytes = self.tail.lock().unwrap_or_else(|e| e.into_inner());
        let text = String::from_utf8_lossy(&bytes);
        let skip = text.chars().count().saturating_sub(STDERR_TAIL_CHARS);
        text.chars().skip(skip).collect()
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

    /// Everything readable from `r` until EOF, or `None` when no EOF came within 5 s (a writer is still open).
    fn read_to_eof(r: OwnedFd) -> Option<String> {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut s = String::new();
            let _ = io::Read::read_to_string(&mut std::fs::File::from(r), &mut s);
            let _ = tx.send(s);
        });
        rx.recv_timeout(Duration::from_secs(5)).ok()
    }

    fn pass(fd: &Arc<OwnedFd>, target: i32) -> PassFd {
        PassFd {
            fd: Arc::clone(fd),
            target,
        }
    }

    #[cfg(debug_assertions)]
    #[tokio::test]
    #[should_panic(expected = "a hub's listening socket was passed to a child")]
    async fn a_hubs_listening_socket_is_never_passed() {
        // kept open for the test binary's life, so its inode is never another file's
        let (sock, _) = std::os::unix::net::UnixStream::pair().unwrap();
        never_pass(&sock);
        let fd = Arc::new(OwnedFd::from(sock.try_clone().unwrap()));
        std::mem::forget(sock);
        let mut spec = sh("exit 0", true);
        spec.pass_fds.push(pass(&fd, 3));
        let _ = spawn(spec).await;
    }

    #[tokio::test]
    async fn passed_fds_arrive_at_their_numbers() {
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
    }

    #[tokio::test]
    async fn nothing_else_leaks() {
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
    }

    #[tokio::test]
    async fn spawn_drops_passed_fds() {
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
    }

    #[tokio::test]
    async fn bad_targets_are_refused() {
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
    }

    // Linux only: PR_SET_PDEATHSIG is a Linux prctl (Android: the same kernel, but the test needs util-linux's
    // setpriv, which Android lacks).
    #[cfg(target_os = "linux")]
    #[test]
    fn pinned_spawn_survives_its_callers_thread() {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_keep_alive(Duration::from_millis(100))
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let spec = Spec {
                program: "/usr/bin/setpriv".into(),
                args: ["--pdeathsig", "KILL", "--", "/bin/sleep", "30"]
                    .map(OsString::from)
                    .to_vec(),
                ..sh("", true)
            };
            let mut child =
                tokio::task::spawn_blocking(|| Handle::current().block_on(spawn_pinned(spec)))
                    .await
                    .unwrap()
                    .unwrap();
            // The blocking thread retires after 100 ms idle; a child forked there would get SIGKILL.
            tokio::time::sleep(Duration::from_millis(1200)).await;
            let status = child.inner.try_wait().unwrap();
            unsafe { libc::kill(-child.id(), libc::SIGKILL) };
            let _ = child.wait().await;
            assert_eq!(status, None, "the child died with its caller's thread");
        });
    }

    #[tokio::test]
    async fn pinned_spawn_passes_fds_too() {
        let (r, w) = pipe();
        let mut spec = sh("echo pinned >&3", true);
        spec.pass_fds.push(PassFd {
            fd: Arc::new(w),
            target: 3,
        });
        let mut child = spawn_pinned(spec).await.unwrap();
        assert!(child.wait().await.unwrap().unwrap().success());
        assert_eq!(read_to_eof(r).as_deref(), Some("pinned\n"));
    }

    #[tokio::test]
    async fn own_process_group_and_sigpipe_ignored() {
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
    }

    /// `new_session`: the child leads a session of its own (so it can never take this process's terminal, and the
    /// reduced-tier helper's own `setsid()` is not refused), and its pid is still its process group's, so the
    /// group can be killed as one.
    #[tokio::test]
    async fn new_session_leads_a_session_and_its_group() {
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
    }

    #[tokio::test]
    async fn exit_reported_once() {
        let mut child = spawn(sh("exit 3", true)).await.unwrap();
        assert_eq!(child.wait().await.unwrap().unwrap().code(), Some(3));
        assert!(child.wait().await.unwrap().is_none());
    }

    #[tokio::test]
    async fn stderr_tail_keeps_the_last_8000_characters() {
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
    }
}
