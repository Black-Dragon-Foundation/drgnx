//! One running kernel (design §5.2): its process, its connection, its sockets, and how it ends.
//!
//! The process starts with draugr in a group of its own, with an allowlisted environment (the key is in the connection file, never
//! in the environment or the argv) and `JUPYTER_RUNTIME_DIR` pointing into the session's private folder. **`child.wait` is the death
//! signal**; the heartbeat is not used (a busy kernel's heartbeat thread still answers, and a dead one is seen by its exit). Ready
//! means the kernel answered `kernel_info_request` and published its first `status` on iopub; every wait has a deadline and a
//! kernel that misses it is killed, group and all. A kernel whose queue passes the flood limit is killed too.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::json;
use tokio::sync::watch;

use super::session::{Channel, Event, Limits, Session};
use super::spec::{Connection, Interrupt, Kernelspec, Transport, private_folder};
use super::wire::Message;
use crate::debug::ports::Block;

/// The hub's variables a kernel inherits (a kernel is an ordinary session program, like the terminal's shell).
const ENV_ALLOW: &[&str] = &[
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "LANG",
    "LANGUAGE",
    "TERM",
    "TMPDIR",
    "XDG_RUNTIME_DIR",
    "XDG_DATA_HOME",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "XDG_DATA_DIRS",
    "XDG_CONFIG_DIRS",
    "VIRTUAL_ENV",
    "CONDA_PREFIX",
    "CONDA_DEFAULT_ENV",
    "JUPYTER_PATH",
    "JUPYTER_CONFIG_DIR",
    "JUPYTER_DATA_DIR",
];

#[derive(Clone, Copy, Debug)]
pub struct Timeouts {
    /// From the spawn to Ready.
    pub ready: Duration,
    /// How often `kernel_info_request` is sent until the kernel answers.
    pub ping: Duration,
    /// An orderly shutdown's wait, before the group is killed.
    pub grace: Duration,
    pub limits: Limits,
}

impl Default for Timeouts {
    fn default() -> Timeouts {
        Timeouts {
            ready: Duration::from_secs(60),
            ping: Duration::from_secs(1),
            grace: Duration::from_secs(3),
            limits: Limits::default(),
        }
    }
}

/// How the process ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Exit {
    pub code: Option<i32>,
    pub signal: Option<i32>,
    pub stderr: String,
}

impl std::fmt::Display for Exit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match (self.code, self.signal) {
            (Some(c), _) => write!(f, "exited with {c}")?,
            (_, Some(s)) => write!(f, "was killed by signal {s}")?,
            _ => write!(f, "ended")?,
        }
        let tail = self.stderr.trim();
        if tail.is_empty() {
            Ok(())
        } else {
            write!(f, ": {tail}")
        }
    }
}

#[derive(Debug)]
pub enum KernelEvent {
    Message(Channel, Box<Message>),
    /// A socket failed.
    Closed(Channel, String),
    /// The kernel flooded the hub and was killed.
    Flood,
    /// The process is gone (reported again on every later call).
    Exited(Exit),
}

/// A kernel is refused in a sealed session (design §5.6): it runs the user's code unconfined, as a program run from a terminal does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal(pub &'static str);

/// Refuse to start a kernel for a session whose launch is enforced by a sandbox.
pub fn refuse_when_sealed(plan: &crate::agents::lock::LaunchPlan) -> Result<(), Refusal> {
    match plan.enforced {
        crate::agents::lock::Enforced::Yes => Err(Refusal(
            "a notebook kernel runs unconfined and is not started in a sealed session",
        )),
        crate::agents::lock::Enforced::No(_) => Ok(()),
    }
}

pub struct Kernel {
    pub name: String,
    session: Session,
    /// Its drop deletes the connection file.
    _conn: Connection,
    /// The loopback ports a tcp kernel was given: held while it lives, given back with it.
    _block: Option<Block>,
    pid: i32,
    exit: watch::Receiver<Option<Exit>>,
    interrupt: Interrupt,
    session_id: String,
    grace: Duration,
}

fn random_hex(n: usize) -> Result<String, String> {
    let mut b = vec![0u8; n];
    getrandom::fill(&mut b).map_err(|e| format!("no random bytes: {e}"))?;
    Ok(b.iter().map(|x| format!("{x:02x}")).collect())
}

/// Whether PATH is a socket we own (the kernel binds its sockets itself; the hub never connects to anything else).
fn is_our_socket(path: &Path) -> bool {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    // SAFETY: geteuid has no preconditions.
    let me = unsafe { libc::geteuid() };
    std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_socket() && m.uid() == me)
}

/// How long to wait for a killed kernel's process to be reaped.
pub const END_WITHIN: Duration = Duration::from_secs(5);

/// A kernel started and not yet handed over: dropped, it takes the kernel's group down.
struct Spawned(Option<i32>);

impl Drop for Spawned {
    fn drop(&mut self) {
        if let Some(pid) = self.0 {
            kill_group_now(pid);
        }
    }
}

fn kill_group_now(pid: i32) {
    if pid > 1 {
        // SAFETY: kill(2) has no memory effects; a negative pid is the group, and 1 and below are never sent.
        unsafe { libc::kill(-pid, libc::SIGKILL) };
    }
}

/// How one start talks to its kernel.
enum Wire {
    Ipc,
    /// Over loopback ports: the block a test claimed, else one claimed here.
    Tcp(Option<Block>),
}

/// Why a start failed; REFUSED: the kernel's process ended before it made any socket (it could not bind what the connection
/// file asked for), so a start over another transport is worth one try.
struct Fail {
    why: String,
    refused: bool,
}

impl From<String> for Fail {
    fn from(why: String) -> Fail {
        Fail {
            why,
            refused: false,
        }
    }
}

impl Kernel {
    /// Start SPEC's kernel with the connection id ID (a file `kernel-ID.json` in FOLDER, the session's private folder) in CWD, and
    /// return when it is ready, or why it is not (the process and the file are gone then). Over ipc unless the kernelspec says tcp;
    /// an ipc start whose kernel ended before it made a socket is made once more over tcp (the error then names both).
    pub async fn start(
        spec: &Kernelspec,
        folder: &Path,
        id: &str,
        cwd: &Path,
        t: Timeouts,
    ) -> Result<Kernel, String> {
        Self::start_on(spec, folder, id, cwd, t, None).await
    }

    /// [`Kernel::start`], over tcp on CLAIMED (ports a test claimed itself) when given.
    pub(crate) async fn start_on(
        spec: &Kernelspec,
        folder: &Path,
        id: &str,
        cwd: &Path,
        t: Timeouts,
        claimed: Option<Block>,
    ) -> Result<Kernel, String> {
        if claimed.is_some() || spec.transport == Transport::Tcp {
            return Self::attempt(spec, folder, id, cwd, t, Wire::Tcp(claimed))
                .await
                .map_err(|f| f.why);
        }
        match Self::attempt(spec, folder, id, cwd, t, Wire::Ipc).await {
            Ok(k) => Ok(k),
            Err(ipc) if ipc.refused => {
                tracing::info!(target: "drgnx::notebook", "kernel {} refused ipc ({}); trying tcp", spec.name, ipc.why);
                match Self::attempt(spec, folder, id, cwd, t, Wire::Tcp(None)).await {
                    Ok(k) => Ok(k),
                    Err(tcp) => Err(format!("over ipc: {}; over tcp: {}", ipc.why, tcp.why)),
                }
            }
            Err(ipc) => Err(ipc.why),
        }
    }

    async fn attempt(
        spec: &Kernelspec,
        folder: &Path,
        id: &str,
        cwd: &Path,
        t: Timeouts,
        wire: Wire,
    ) -> Result<Kernel, Fail> {
        use std::os::unix::process::ExitStatusExt;
        // the folder is checked here, not trusted from the caller: a kernel's sockets and key live in it
        let folder = private_folder(folder)?;
        let folder = folder.as_path();
        let session_id = random_hex(8)?;
        let identity = format!("drgnx-{}", random_hex(8)?);
        let (conn, block) = match wire {
            Wire::Ipc => (Connection::create(folder, id, &spec.name)?, None),
            Wire::Tcp(claimed) => {
                // ports nobody else on this machine holds (`debug::ports`' machine-wide locks); each is checked to be the
                // kernel's own before the hub connects to it
                let block = match claimed {
                    Some(b) => b,
                    None => crate::debug::ports::machine().claim()?,
                };
                let p = block.ports();
                let ports = [p[0], p[1], p[2], p[3], p[4]];
                (
                    Connection::create_tcp(folder, id, &spec.name, ports)?,
                    Some(block),
                )
            }
        };
        let argv = spec.argv_for(&conn.path);
        let program = argv
            .first()
            .ok_or_else(|| "the kernelspec has no command".to_string())?;
        let runtime_dir: &OsStr = folder.as_os_str();
        let mut set: Vec<(&str, &OsStr)> = vec![("JUPYTER_RUNTIME_DIR", runtime_dir)];
        for (k, v) in &spec.env {
            set.push((k.as_str(), OsStr::new(v.as_str())));
        }
        let mut child = draugr::spawn(draugr::Spec {
            program: PathBuf::from(program),
            args: argv[1..].iter().map(Into::into).collect(),
            env: draugr::env::build(ENV_ALLOW, &["LC_"], &set),
            cwd: Some(cwd.to_path_buf()),
            stdin_null: true,
            pass_fds: Vec::new(),
            new_session: false,
        })
        .await
        .map_err(|e| format!("cannot start {program}: {e}"))?;
        let pid = child.id();
        // from here the kernel is ours to end: a start dropped part way (the caller gave up) takes it down
        let mut guard = Spawned(Some(pid));
        // a kernel's stdout is noise, but an unread pipe would stop it
        if let Some(mut out) = child.take_stdout() {
            crate::clock::spawn("notebook-kernel-stdout", async move {
                let _ = tokio::io::copy(&mut out, &mut tokio::io::sink()).await;
            });
        }
        let (exit_tx, exit) = watch::channel::<Option<Exit>>(None);
        crate::clock::spawn("notebook-kernel-wait", async move {
            let status = child.wait().await.ok().flatten();
            // the leader is gone: what it forked goes now, before anything can ask for it (the group id is still ours while a
            // member lives, and nothing signals it after the exit is known)
            kill_group_now(pid);
            let _ = exit_tx.send(Some(Exit {
                code: status.and_then(|s| s.code()),
                signal: status.and_then(|s| s.signal()),
                stderr: child.stderr_tail(),
            }));
        });
        let bring_up = async {
            wait_endpoints(&conn, pid, &mut exit.clone()).await?;
            let mut session = Session::connect(&conn, &identity, t.limits).await?;
            ready(&mut session, &session_id, &mut exit.clone(), t.ping).await?;
            Ok::<Session, Fail>(session)
        };
        match crate::clock::timeout(t.ready, bring_up).await {
            Ok(Ok(session)) => {
                guard.0 = None;
                Ok(Kernel {
                    name: spec.name.clone(),
                    session,
                    _conn: conn,
                    _block: block,
                    pid,
                    exit,
                    interrupt: spec.interrupt,
                    session_id,
                    grace: t.grace,
                })
            }
            Ok(Err(e)) => {
                kill_group_now(pid);
                Err(e)
            }
            Err(_) => {
                kill_group_now(pid);
                Err(format!(
                    "the kernel {} was not ready within {} s",
                    spec.name,
                    t.ready.as_secs_f64()
                )
                .into())
            }
        }
    }

    pub fn pid(&self) -> i32 {
        self.pid
    }

    /// The next thing that happened: messages first, then the process's end.
    pub async fn next(&mut self) -> KernelEvent {
        let mut exit = self.exit.clone();
        tokio::select! {
            biased;
            e = self.session.next() => match e {
                Some(Event::Message { channel, message, .. }) => KernelEvent::Message(channel, message),
                Some(Event::Closed { channel, why }) => KernelEvent::Closed(channel, why),
                Some(Event::Flood) => {
                    if self.exit.borrow().is_none() {
                        kill_group_now(self.pid);
                    }
                    KernelEvent::Flood
                }
                None => KernelEvent::Exited(self.wait_exit().await),
            },
            e = exited(&mut exit) => KernelEvent::Exited(e),
        }
    }

    async fn wait_exit(&self) -> Exit {
        self.bounded_exit().await
    }

    /// Send a request on CHANNEL; its `msg_id`.
    pub fn request(
        &self,
        channel: Channel,
        msg_type: &str,
        content: serde_json::Value,
    ) -> Result<String, String> {
        let m = Message::request(&self.session_id, msg_type, content);
        self.session.send(channel, &m)?;
        Ok(m.header.msg_id)
    }

    /// Send MESSAGE (a reply built by the caller, e.g. `input_reply`) on CHANNEL.
    pub fn send(&self, channel: Channel, message: &Message) -> Result<(), String> {
        self.session.send(channel, message)
    }

    /// Interrupt what is running: SIGINT to the kernel's group, or an `interrupt_request` on control for a kernelspec that asks
    /// for it.
    pub fn interrupt(&self) -> Result<(), String> {
        match self.interrupt {
            Interrupt::Message => self
                .request(Channel::Control, "interrupt_request", json!({}))
                .map(|_| ()),
            Interrupt::Signal => {
                if self.pid <= 1 {
                    return Err("no kernel process".into());
                }
                // once the leader is reaped its group id is not ours to signal
                if self.exit.borrow().is_some() {
                    return Err("the kernel has ended".into());
                }
                // SAFETY: kill(2) has no memory effects; the group of a kernel this hub started.
                if unsafe { libc::kill(-self.pid, libc::SIGINT) } == 0 {
                    Ok(())
                } else {
                    Err(format!(
                        "cannot interrupt the kernel: {}",
                        std::io::Error::last_os_error()
                    ))
                }
            }
        }
    }

    /// End the kernel: ask it to shut down, give it the grace, then kill its group. The connection file goes with `self`.
    pub async fn shutdown(self) -> Exit {
        let mut exit = self.exit.clone();
        if let Some(e) = exit.borrow().clone() {
            return e;
        }
        let _ = self.request(
            Channel::Control,
            "shutdown_request",
            json!({"restart": false}),
        );
        if let Ok(e) = crate::clock::timeout(self.grace, exited(&mut exit)).await {
            // it went by itself, and the group went with it (see the wait task)
            return e;
        }
        // the leader is still there: the group is ours to take down
        let _ = draugr::kill_group(self.pid, Duration::ZERO, &draugr::RealSignaller).await;
        self.bounded_exit().await
    }

    /// The exit, waited for no longer than [`END_WITHIN`].
    async fn bounded_exit(&self) -> Exit {
        let mut exit = self.exit.clone();
        exited_within(&mut exit, END_WITHIN)
            .await
            .unwrap_or_else(|| Exit {
                code: None,
                signal: None,
                stderr: "the kernel did not end".into(),
            })
    }

    /// Kill the group now and wait for the process.
    pub async fn kill(self) -> Exit {
        if self.exit.borrow().is_none() {
            kill_group_now(self.pid);
        }
        self.bounded_exit().await
    }
}

impl Drop for Kernel {
    fn drop(&mut self) {
        if self.exit.borrow().is_none() {
            kill_group_now(self.pid);
        }
    }
}

/// How many bounded waits were made (a test pins that `kill` and `bounded_exit` make theirs through `exited_within`).
#[cfg(test)]
pub(crate) static BOUNDED_WAITS: std::sync::atomic::AtomicUsize =
    std::sync::atomic::AtomicUsize::new(0);

/// The exit if it happens within D (on the hub's clock), else None.
pub(crate) async fn exited_within(
    rx: &mut watch::Receiver<Option<Exit>>,
    d: Duration,
) -> Option<Exit> {
    #[cfg(test)]
    BOUNDED_WAITS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    crate::clock::timeout(d, exited(rx)).await.ok()
}

/// The exit, whenever it has happened.
async fn exited(rx: &mut watch::Receiver<Option<Exit>>) -> Exit {
    loop {
        if let Some(e) = rx.borrow_and_update().clone() {
            return e;
        }
        if rx.changed().await.is_err() {
            return rx.borrow().clone().unwrap_or(Exit {
                code: None,
                signal: None,
                stderr: String::new(),
            });
        }
    }
}

/// Wait until the kernel's four sockets are there, or the process has ended (a refusal: it made none). Over ipc they are files that
/// are sockets of ours. Over tcp they are loopback ports whose every listener is in the kernel's process group
/// (`debug::ports::owned`): the hub never connects to a port on a probe, because the port the hub claimed and the bind the
/// kernel makes are apart, and a listener that is not the kernel's is an error naming the port, never connected to.
async fn wait_endpoints(
    conn: &Connection,
    pid: i32,
    exit: &mut watch::Receiver<Option<Exit>>,
) -> Result<(), Fail> {
    loop {
        let all = match conn.ports {
            None => ["shell", "iopub", "stdin", "control"]
                .iter()
                .all(|c| conn.socket(c).is_some_and(|p| is_our_socket(&p))),
            Some(ports) => {
                let four = [ports[0], ports[1], ports[2], ports[3]];
                let owned = crate::clock::blocking(move || {
                    let mut all = true;
                    for p in four {
                        match crate::debug::ports::owned(p, &[pid]) {
                            Ok(true) => {}
                            Ok(false) => all = false,
                            Err(e) => return Err(e),
                        }
                    }
                    Ok(all)
                })
                .await
                .map_err(|e| format!("the port check failed: {e}"))?;
                owned?
            }
        };
        if all {
            return Ok(());
        }
        if let Some(e) = exit.borrow().clone() {
            return Err(Fail {
                why: format!("the kernel {e} before it was ready"),
                refused: true,
            });
        }
        crate::clock::sleep(Duration::from_millis(25)).await;
    }
}

/// Ready: `kernel_info_reply` on shell and the first `status` on iopub (the SUB's subscription has taken hold then), asking again
/// every PING until the kernel answers.
async fn ready(
    session: &mut Session,
    session_id: &str,
    exit: &mut watch::Receiver<Option<Exit>>,
    ping: Duration,
) -> Result<(), String> {
    let (mut info, mut status) = (false, false);
    let mut tick = crate::clock::interval(ping);
    while !(info && status) {
        tokio::select! {
            biased;
            e = session.next() => match e {
                Some(Event::Message { channel: Channel::Shell, message, .. }) if message.header.msg_type == "kernel_info_reply" => info = true,
                Some(Event::Message { channel: Channel::Iopub, message, .. }) if message.header.msg_type == "status" => status = true,
                Some(Event::Message { .. }) => {}
                Some(Event::Closed { channel, why }) => return Err(format!("the kernel's {} socket failed: {why}", channel.name())),
                Some(Event::Flood) => return Err("the kernel flooded the hub while starting".into()),
                None => return Err("the kernel's sockets ended".into()),
            },
            e = exited(exit) => return Err(format!("the kernel {e} before it was ready")),
            _ = tick.tick() => {
                if !info {
                    session.send(Channel::Shell, &Message::request(session_id, "kernel_info_request", json!({})))?;
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
