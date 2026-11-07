//! How the hub reaches a runner (docs/develop/hub.md, "Runners: the transport").
//!
//! [`Transport`] opens a runner's three sessions (control, bulk in, bulk out), checks the link with a real round trip,
//! replaces a master that fails it and stops one. [`OpensshTransport`] drives the user's own OpenSSH: one master per
//! runner through the `openssh` crate's native mux, with the generated config of [`super::ssh_config`] and strict host
//! keys. The hub never sends `-O exit`: a master is replaced or stopped by stopping its listener (`-O stop`), so
//! sessions on it finish or end through the keep-alive.
//!
//! A lost link is never a job's result: nothing here reads an ssh exit status as anything about a job. ssh's error
//! output is classified ([`classify_stderr`]): a login the user must do at a terminal (Tailscale's additional check,
//! a key's passphrase, a host key not known yet) is [`LinkError::NeedsLogin`]; a changed host key is
//! [`LinkError::HostKeyChanged`] and is never accepted.

use super::RunnerCfg;
use mimir::BoxFuture;
#[cfg(all(unix, not(target_os = "android")))]
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite};

/// The sessions one runner gets: control, bulk in, bulk out.
pub const SESSIONS: u32 = 3;

/// How long a round trip may take before the link counts as lost: what the keep-alive allows
/// (`ServerAliveInterval 15` × `ServerAliveCountMax 4`).
pub const ROUND_TRIP_DEADLINE: Duration = Duration::from_secs(60);

/// What the user must do at a terminal before the hub can reach a runner. The hub shows it on a card ("Log in to
/// desktop: run `ssh desktop true` in a terminal") and does nothing else: it never opens a URL or answers a prompt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Login {
    /// Tailscale SSH wants a fresh login; the URL it printed, if any, is shown and never opened.
    TailscaleCheck { url: Option<String> },
    /// A key wants its passphrase (`BatchMode` never asks).
    Passphrase,
    /// The host's key is not known yet: the user checks and accepts it once in a terminal.
    UnknownHostKey,
    /// The host's key differs from the known one. Never accepted by the hub; [`link_error`] makes it
    /// [`LinkError::HostKeyChanged`].
    HostKeyChanged,
}

impl Login {
    /// The command the card asks the user to run for HOST.
    pub fn command(&self, host: &str) -> String {
        format!("ssh {host} true")
    }
}

/// Why a runner can't be reached. None of these is ever a job's result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkError {
    /// The link is down, or didn't answer within [`ROUND_TRIP_DEADLINE`]: redial with [`Redial::delay`].
    Lost,
    /// The user must log in first; no redial until they have.
    NeedsLogin(Login),
    /// The runner's host key changed. Never accepted automatically.
    HostKeyChanged,
    /// Refused for a reason that a redial won't change, in ssh's or our own words.
    Refused(String),
}

impl std::fmt::Display for LinkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LinkError::Lost => f.write_str("the link is lost"),
            LinkError::NeedsLogin(l) => write!(f, "needs a login: {l:?}"),
            LinkError::HostKeyChanged => f.write_str("the runner's host key changed"),
            LinkError::Refused(why) => write!(f, "refused: {why}"),
        }
    }
}

impl std::error::Error for LinkError {}

/// The login ssh's error output STDERR asks for, if any.
pub fn classify_stderr(stderr: &str) -> Option<Login> {
    if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
        || stderr.contains("has changed and you have requested strict checking")
    {
        return Some(Login::HostKeyChanged);
    }
    if stderr.contains("Tailscale SSH requires an additional check") {
        let url = stderr
            .split_whitespace()
            .find(|w| w.starts_with("https://"))
            .map(|w| w.trim_end_matches(['.', ',', ')', '"', '\'']).to_string());
        return Some(Login::TailscaleCheck { url });
    }
    if stderr.contains("passphrase") {
        return Some(Login::Passphrase);
    }
    if stderr.contains("host key is known for") || stderr.contains("Host key verification failed") {
        return Some(Login::UnknownHostKey);
    }
    None
}

/// What ssh says when the machine is down or out of reach: a lost link, redialed.
const LOST: [&str; 12] = [
    "Connection refused",
    "Connection timed out",
    "Operation timed out",
    "No route to host",
    "Network is unreachable",
    "Connection reset",
    "Connection closed",
    "closed by remote host",
    "Broken pipe",
    "Could not resolve hostname",
    "Temporary failure in name resolution",
    "kex_exchange_identification",
];

/// ssh's error output STDERR as a [`LinkError`]: a login, a changed host key, a lost link (the machine down or
/// unreachable), or a refusal in ssh's words.
pub fn link_error(stderr: &str) -> LinkError {
    match classify_stderr(stderr) {
        Some(Login::HostKeyChanged) => LinkError::HostKeyChanged,
        Some(l) => LinkError::NeedsLogin(l),
        None if LOST.iter().any(|p| stderr.contains(p)) => LinkError::Lost,
        None => LinkError::Refused(stderr.trim().to_string()),
    }
}

/// E as it applies to R. A cloud machine has no login a terminal could do: its host keys are pinned from its console,
/// so a key ssh doesn't know is a changed one, never accepted, and any other login ssh asks for is a refusal.
pub fn for_runner(r: &RunnerCfg, e: LinkError) -> LinkError {
    match (&r.cloud, e) {
        (Some(_), LinkError::NeedsLogin(Login::UnknownHostKey | Login::HostKeyChanged)) => {
            LinkError::HostKeyChanged
        }
        (Some(_), LinkError::NeedsLogin(l)) => {
            LinkError::Refused(format!("a cloud machine asked for a login ({l:?})"))
        }
        (_, e) => e,
    }
}

/// Redial with backoff after a lost link.
pub struct Redial;

impl Redial {
    /// The wait before redial N (0 for the first after the loss): 5 s, 15 s, 45 s, then every 120 s.
    pub fn delay(n: u32) -> Duration {
        Duration::from_secs(match n {
            0 => 5,
            1 => 15,
            2 => 45,
            _ => 120,
        })
    }
}

/// When a runner that is out of reach is dialled again: [`Redial::delay`] after the loss, then after each dial that
/// did not bring it back; a runner that is back starts over.
#[derive(Debug, Default)]
pub struct RedialClock {
    tries: u32,
    due: Option<u64>,
}

impl RedialClock {
    /// Whether to dial now (NOW in seconds), given whether the runner is out of reach.
    pub fn tick(&mut self, unreachable: bool, now: u64) -> bool {
        if !unreachable {
            *self = RedialClock::default();
            return false;
        }
        let due = *self
            .due
            .get_or_insert(now + Redial::delay(self.tries).as_secs());
        if now < due {
            return false;
        }
        self.tries = self.tries.saturating_add(1);
        self.due = None;
        true
    }
}

/// What applies to a runner's connection, from `ssh -G` with its generated config: shown at onboarding and in the
/// runner list, so the user sees what reaches the runner.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Effective {
    pub forward_agent: bool,
    /// Each forward as `ssh -G` prints it: `localforward 127.0.0.1:8080 localhost:80`.
    pub forwards: Vec<String>,
    /// The user's `ProxyJump` or `ProxyCommand`, which stay theirs.
    pub proxy: Option<String>,
}

impl Effective {
    /// Reads `ssh -G`'s output.
    pub fn parse(ssh_g: &str) -> Effective {
        let mut e = Effective::default();
        for line in ssh_g.lines() {
            let (k, v) = line.split_once(' ').unwrap_or((line, ""));
            match k {
                "forwardagent" => e.forward_agent = v != "no",
                "localforward" | "remoteforward" | "dynamicforward" => {
                    e.forwards.push(line.to_string())
                }
                "proxyjump" | "proxycommand" if v != "none" && e.proxy.is_none() => {
                    e.proxy = Some(v.to_string())
                }
                _ => {}
            }
        }
        e
    }
}

/// A reader or writer of one session.
pub type Reader = Box<dyn AsyncRead + Send + Unpin>;
pub type Writer = Box<dyn AsyncWrite + Send + Unpin>;

/// One session: what the hub writes to the remote command and what it reads back. Dropping it ends the session.
pub struct Channel {
    pub tx: Writer,
    pub rx: Reader,
    /// What the remote command writes to its stderr (`None` for a channel made with [`Channel::new`]).
    pub err: Option<Reader>,
    /// What keeps the session open: its process on the master and its place in the runner's session budget.
    _hold: Option<Box<dyn std::any::Any + Send>>,
}

/// What keeps a session open (its process on the master and its place in the runner's session budget): drop it and
/// the session ends.
pub type Hold = Option<Box<dyn std::any::Any + Send>>;

impl Channel {
    /// The channel in pieces: its writer, reader, standard error and what keeps the session open, which the caller
    /// must keep for as long as it uses the others.
    pub fn split(self) -> (Writer, Reader, Option<Reader>, Hold) {
        (self.tx, self.rx, self.err, self._hold)
    }

    /// A channel over any reader and writer: a link test's in-memory pipe, or another transport's.
    pub fn new(tx: Writer, rx: Reader) -> Channel {
        Channel {
            tx,
            rx,
            err: None,
            _hold: None,
        }
    }
}

/// A runner's three sessions.
pub struct Channels {
    pub control: Channel,
    pub bulk_in: Channel,
    pub bulk_out: Channel,
}

/// How the hub reaches runners. Every runner is named by its [`RunnerCfg::name`].
pub trait Transport: Send + Sync {
    /// Dials R's master if it has none (or resumes the one a previous hub left), checks the link with a no-op
    /// command, and opens R's three sessions. A second `open` while R's sessions are open is refused.
    fn open<'a>(&'a self, r: &'a RunnerCfg) -> BoxFuture<'a, Result<Channels, LinkError>>;
    /// A real round trip to R, within [`ROUND_TRIP_DEADLINE`]: a no-op command while a session is free, else the
    /// next bytes on R's control channel (both ends ping every 10 s). A master that answers only its local socket
    /// (`-O check`) says nothing about the link and is not enough.
    fn round_trip<'a>(&'a self, r: &'a str) -> BoxFuture<'a, Result<Duration, LinkError>>;
    /// Stops R's master listening (`-O stop`, never `-O exit`: its open sessions finish or end through the
    /// keep-alive) and dials a new one.
    fn replace_master<'a>(&'a self, r: &'a str) -> BoxFuture<'a, Result<(), LinkError>>;
    /// Stops R's master listening and forgets R.
    fn stop<'a>(&'a self, r: &'a str) -> BoxFuture<'a, ()>;
}

#[cfg(all(unix, not(target_os = "android")))]
pub use openssh_impl::{OpensshTransport, effective};

#[cfg(all(unix, not(target_os = "android")))]
mod openssh_impl {
    use super::*;
    use crate::clock;
    use crate::runners::ssh_config;
    use openssh::{ControlPersist, KnownHosts, Session, SessionBuilder, Stdio};
    use std::collections::HashMap;
    use std::num::NonZeroUsize;
    use std::path::PathBuf;
    use std::pin::Pin;
    use std::sync::{Arc, Weak};
    use std::task::{Context, Poll};
    use tokio::io::ReadBuf;
    use tokio::sync::{Mutex, Notify, OwnedSemaphorePermit, Semaphore};

    /// The prefix of the folder the `openssh` crate makes for a master (its socket `master` and its log `log`).
    const MASTER_DIR_PREFIX: &str = ".ssh-connection";

    /// [`Transport`] over the user's OpenSSH: a master per runner with its control socket in the runner's folder
    /// under `$XDG_RUNTIME_DIR/drgnx-runners/`, which a later hub resumes ([`openssh::Session::resume_mux`]). Dropping
    /// it leaves the masters running (`ControlPersist 10m`) for the next hub.
    pub struct OpensshTransport {
        runtime_dir: PathBuf,
        links: std::sync::Mutex<HashMap<String, Arc<Mutex<Link>>>>,
    }

    /// One runner's state: its config, its master, its session budget and, while its sessions are open, what the
    /// control channel has heard.
    struct Link {
        cfg: RunnerCfg,
        master: Option<Master>,
        budget: Arc<Semaphore>,
        heard: Weak<Heard>,
    }

    /// A master: the session that owns it (stopping it stops the master listening), the handle sessions are opened
    /// from (dropping it does nothing), and its folder.
    struct Master {
        owner: Session,
        handle: Arc<Session>,
        folder: PathBuf,
    }

    impl Master {
        fn new(owner: Session) -> Master {
            let ctl: Box<Path> = owner.control_socket().into();
            let folder = ctl.parent().map(Path::to_path_buf).unwrap_or_default();
            Master {
                handle: Arc::new(Session::resume_mux(ctl, None)),
                owner,
                folder,
            }
        }

        /// Stops the master listening (`-O stop`): its open sessions finish, then it exits. Never `-O exit`.
        async fn stop_listening(self) {
            let Master { owner, folder, .. } = self;
            if let Err(e) = owner.close().await {
                tracing::debug!(error = %e, "runners: stopping a master that had gone");
            }
            match std::fs::remove_dir_all(&folder) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => {
                    tracing::warn!(folder = %folder.display(), error = %e, "runners: a master's folder stays")
                }
            }
        }
    }

    /// Wakes a round trip waiting on the control channel when bytes arrive on it.
    #[derive(Default)]
    struct Heard {
        notify: Notify,
    }

    /// The control channel's reader, which tells [`Heard`] about every read that brought bytes.
    struct Tapped {
        inner: openssh::ChildStdout,
        heard: Arc<Heard>,
    }

    impl AsyncRead for Tapped {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<std::io::Result<()>> {
            let before = buf.filled().len();
            let r = Pin::new(&mut self.inner).poll_read(cx, buf);
            if matches!(r, Poll::Ready(Ok(()))) && buf.filled().len() > before {
                self.heard.notify.notify_waiters();
            }
            r
        }
    }

    impl OpensshTransport {
        /// A transport whose runner folders live in RUNTIME_DIR (the hub's `$XDG_RUNTIME_DIR`).
        pub fn new(runtime_dir: impl Into<PathBuf>) -> OpensshTransport {
            OpensshTransport {
                runtime_dir: runtime_dir.into(),
                links: std::sync::Mutex::new(HashMap::new()),
            }
        }

        /// The master's local socket answers (`-O check`). Says nothing about the link: a master whose link died
        /// still answers it.
        pub async fn check_master(&self, r: &str) -> Result<(), LinkError> {
            let link = self.link(r).ok_or(LinkError::Lost)?;
            let handle = match &link.lock().await.master {
                Some(m) => m.handle.clone(),
                None => return Err(LinkError::Lost),
            };
            handle.check().await.map_err(from_ssh)
        }

        fn link(&self, name: &str) -> Option<Arc<Mutex<Link>>> {
            self.links
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(name)
                .cloned()
        }

        fn link_for(&self, r: &RunnerCfg) -> Arc<Mutex<Link>> {
            self.links
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .entry(r.name.clone())
                .or_insert_with(|| {
                    Arc::new(Mutex::new(Link {
                        cfg: r.clone(),
                        master: None,
                        budget: Arc::new(Semaphore::new(SESSIONS as usize)),
                        heard: Weak::new(),
                    }))
                })
                .clone()
        }

        /// L's master: the one it has if its socket answers, else the one a previous hub left, else a new one.
        async fn master(&self, l: &mut Link) -> Result<Arc<Session>, LinkError> {
            if let Some(m) = &l.master {
                if m.handle.check().await.is_ok() {
                    return Ok(m.handle.clone());
                }
                if let Some(m) = l.master.take() {
                    m.stop_listening().await;
                }
            }
            let dir = ssh_config::dir(&self.runtime_dir, &l.cfg.name);
            let m = match resume(&dir).await {
                Some(m) => m,
                None => {
                    let config = ssh_config::path(&self.runtime_dir, &l.cfg.name);
                    let owner = builder(&config, &dir)
                        .connect_mux(&l.cfg.host)
                        .await
                        .map_err(from_ssh)?;
                    Master::new(owner)
                }
            };
            let handle = m.handle.clone();
            l.master = Some(m);
            Ok(handle)
        }
    }

    impl Drop for OpensshTransport {
        /// The masters stay for the next hub (`ControlPersist 10m`): each is detached, never stopped.
        fn drop(&mut self) {
            let links = std::mem::take(self.links.get_mut().unwrap_or_else(|e| e.into_inner()));
            for (_, link) in links {
                if let Ok(mut l) = link.try_lock()
                    && let Some(m) = l.master.take()
                {
                    let _ = m.owner.detach();
                }
            }
        }
    }

    /// A master a previous hub left in DIR whose socket still answers. The folders of masters that have gone are
    /// removed; a second live one is stopped.
    async fn resume(dir: &Path) -> Option<Master> {
        let entries = std::fs::read_dir(dir).ok()?;
        let mut found = None;
        for e in entries.flatten() {
            let ours = e
                .file_name()
                .to_string_lossy()
                .starts_with(MASTER_DIR_PREFIX)
                && e.file_type().is_ok_and(|t| t.is_dir());
            if !ours {
                continue;
            }
            let folder = e.path();
            let owner = Session::resume_mux(
                folder.join("master").into_boxed_path(),
                Some(folder.join("log").into_boxed_path()),
            );
            let alive = owner.check().await.is_ok();
            let m = Master {
                handle: Arc::new(Session::resume_mux(owner.control_socket().into(), None)),
                owner,
                folder,
            };
            if alive && found.is_none() {
                found = Some(m);
            } else {
                m.stop_listening().await;
            }
        }
        found
    }

    /// `true` on HANDLE's master within [`ROUND_TRIP_DEADLINE`]: a real trip to the runner and back.
    async fn noop(handle: &Arc<Session>) -> Result<Duration, LinkError> {
        let start = clock::real_now();
        let mut cmd = Session::to_command(handle.clone(), "true");
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        let out = clock::timeout(ROUND_TRIP_DEADLINE, cmd.output())
            .await
            .map_err(|_| LinkError::Lost)?
            .map_err(from_ssh)?;
        if out.status.success() {
            return Ok(start.elapsed());
        }
        let stderr = String::from_utf8_lossy(&out.stderr);
        Err(match link_error(&stderr) {
            // a failed `true` that ssh says nothing about is the runner's shell refusing us
            LinkError::Refused(s) if s.is_empty() => {
                LinkError::Refused(format!("`true` exited with {}", out.status))
            }
            e => e,
        })
    }

    /// One session on HANDLE's master running ARGV, holding PERMIT until it is dropped. HEARD taps its stdout.
    async fn session(
        handle: &Arc<Session>,
        argv: &[String],
        heard: Option<Arc<Heard>>,
        permit: OwnedSemaphorePermit,
    ) -> Result<Channel, LinkError> {
        let mut cmd = Session::to_command(handle.clone(), argv[0].as_str());
        cmd.args(&argv[1..])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = cmd.spawn().await.map_err(from_ssh)?;
        let lost = || LinkError::Refused("a session came without its pipes".into());
        let tx = child.stdin().take().ok_or_else(lost)?;
        let rx = child.stdout().take().ok_or_else(lost)?;
        let err = child.stderr().take().ok_or_else(lost)?;
        let rx: Reader = match heard {
            Some(heard) => Box::new(Tapped { inner: rx, heard }),
            None => Box::new(rx),
        };
        Ok(Channel {
            tx: Box::new(tx),
            rx,
            err: Some(Box::new(err)),
            _hold: Some(Box::new((child, permit))),
        })
    }

    /// The `openssh` crate's error as a link error: a failed connect is classified from ssh's output; a broken mux
    /// connection is a lost link.
    fn from_ssh(e: openssh::Error) -> LinkError {
        match e {
            openssh::Error::Connect(io) => link_error(&io.to_string()),
            openssh::Error::Disconnected
            | openssh::Error::RemoteProcessTerminated
            | openssh::Error::SshMux(_)
            | openssh::Error::ChildIo(_) => LinkError::Lost,
            e => LinkError::Refused(e.to_string()),
        }
    }

    impl Transport for OpensshTransport {
        fn open<'a>(&'a self, r: &'a RunnerCfg) -> BoxFuture<'a, Result<Channels, LinkError>> {
            Box::pin(async move {
                r.check().map_err(LinkError::Refused)?;
                let link = self.link_for(r);
                let mut l = link.lock().await;
                let mut permits =
                    l.budget
                        .clone()
                        .try_acquire_many_owned(SESSIONS)
                        .map_err(|_| {
                            LinkError::Refused(format!("{}'s sessions are open already", r.name))
                        })?;
                l.cfg = r.clone();
                ssh_config::write(&self.runtime_dir, &r.name, &ssh_config::render(r)).map_err(
                    |e| LinkError::Refused(format!("writing {}'s ssh config: {e}", r.name)),
                )?;
                let handle = self.master(&mut l).await.map_err(|e| for_runner(r, e))?;
                // the link answers, and no login stands in the way, before any session of ours starts
                noop(&handle).await.map_err(|e| for_runner(r, e))?;
                let heard = Arc::new(Heard::default());
                let (p1, p2) = (permits.split(1), permits.split(1));
                let (Some(p1), Some(p2)) = (p1, p2) else {
                    unreachable!("three permits were taken")
                };
                let control = session(&handle, &r.remote.control, Some(heard.clone()), p1).await?;
                let bulk_in = session(&handle, &r.remote.bulk_in, None, p2).await?;
                let bulk_out = session(&handle, &r.remote.bulk_out, None, permits).await?;
                l.heard = Arc::downgrade(&heard);
                Ok(Channels {
                    control,
                    bulk_in,
                    bulk_out,
                })
            })
        }

        fn round_trip<'a>(&'a self, r: &'a str) -> BoxFuture<'a, Result<Duration, LinkError>> {
            Box::pin(async move {
                let link = self.link(r).ok_or(LinkError::Lost)?;
                let (handle, permit, heard) = {
                    let mut l = link.lock().await;
                    let handle = self.master(&mut l).await?;
                    let permit = l.budget.clone().try_acquire_owned().ok();
                    (handle, permit, l.heard.upgrade())
                };
                match (permit, heard) {
                    (Some(_permit), _) => noop(&handle).await,
                    (None, Some(heard)) => {
                        let start = clock::real_now();
                        clock::timeout(ROUND_TRIP_DEADLINE, heard.notify.notified())
                            .await
                            .map_err(|_| LinkError::Lost)?;
                        Ok(start.elapsed())
                    }
                    (None, None) => Err(LinkError::Refused(format!(
                        "{r}'s sessions are all taken and none is a control channel"
                    ))),
                }
            })
        }

        fn replace_master<'a>(&'a self, r: &'a str) -> BoxFuture<'a, Result<(), LinkError>> {
            Box::pin(async move {
                let link = self.link(r).ok_or(LinkError::Lost)?;
                let mut l = link.lock().await;
                if let Some(m) = l.master.take() {
                    m.stop_listening().await;
                }
                let dir = ssh_config::dir(&self.runtime_dir, r);
                let config = ssh_config::path(&self.runtime_dir, r);
                let owner = builder(&config, &dir)
                    .connect_mux(&l.cfg.host)
                    .await
                    .map_err(|e| for_runner(&l.cfg, from_ssh(e)))?;
                l.master = Some(Master::new(owner));
                Ok(())
            })
        }

        fn stop<'a>(&'a self, r: &'a str) -> BoxFuture<'a, ()> {
            Box::pin(async move {
                let link = self
                    .links
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .remove(r);
                let master = match link {
                    Some(link) => link.lock().await.master.take(),
                    None => None,
                };
                if let Some(m) = master {
                    m.stop_listening().await;
                }
            })
        }
    }

    /// What applies to HOST's connection under the generated CONFIG: `ssh -G -F CONFIG HOST`, which reads the configs
    /// and connects nowhere.
    pub async fn effective(config: &Path, host: &str) -> Result<Effective, LinkError> {
        if host.starts_with('-') {
            return Err(LinkError::Refused(format!(
                "the host {host:?} reads as an option"
            )));
        }
        let out = tokio::process::Command::new("ssh")
            .arg("-G")
            .arg("-F")
            .arg(config)
            .arg(host)
            .stdin(std::process::Stdio::null())
            .output()
            .await
            .map_err(|e| LinkError::Refused(format!("ssh -G: {e}")))?;
        if !out.status.success() {
            return Err(LinkError::Refused(format!(
                "ssh -G: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(Effective::parse(&String::from_utf8_lossy(&out.stdout)))
    }

    /// The master's builder with its generated CONFIG and its socket in CONTROL_DIR: strict host keys and the
    /// design's persistence on its command line as well (the crate's defaults, accept-new and forever, would win
    /// over the file there).
    pub(super) fn builder(config: &Path, control_dir: &Path) -> SessionBuilder {
        let mut b = SessionBuilder::default();
        b.config_file(config)
            .known_hosts_check(KnownHosts::Strict)
            .control_directory(control_dir)
            .control_persist(ControlPersist::IdleFor(
                NonZeroUsize::new(600).expect("600 is not zero"),
            ));
        b
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TAILSCALE: &str = "# Tailscale SSH requires an additional check.\n\
                             # To authenticate, visit: https://login.tailscale.com/a/1a2b3c4d5e\n";

    // [D] pure
    #[test]
    fn classify_tailscale_check_is_needs_login_with_url() {
        let want = Login::TailscaleCheck {
            url: Some("https://login.tailscale.com/a/1a2b3c4d5e".into()),
        };
        assert_eq!(classify_stderr(TAILSCALE), Some(want.clone()));
        assert_eq!(link_error(TAILSCALE), LinkError::NeedsLogin(want));
        // without a URL it is still a login, never a lost link
        assert_eq!(
            classify_stderr("Tailscale SSH requires an additional check.\n"),
            Some(Login::TailscaleCheck { url: None })
        );
        assert_eq!(
            classify_stderr("Enter passphrase for key 'id_ed25519':"),
            Some(Login::Passphrase)
        );
        assert_eq!(
            classify_stderr(
                "No ED25519 host key is known for desktop and you have requested strict checking.\n\
                 Host key verification failed.\n"
            ),
            Some(Login::UnknownHostKey)
        );
        assert_eq!(
            Login::Passphrase.command("desktop"),
            "ssh desktop true".to_string()
        );
        // the machine down is a lost link, a key the runner refuses is a refusal, neither a login
        for down in [
            "ssh: connect to host desktop port 22: Connection refused",
            "ssh: connect to host desktop port 22: Connection timed out",
            "ssh: Could not resolve hostname desktop: Name or service not known",
            "Connection closed by 10.0.0.7 port 22",
        ] {
            assert_eq!(classify_stderr(down), None, "{down}");
            assert_eq!(link_error(down), LinkError::Lost, "{down}");
        }
        let denied = "runner@desktop: Permission denied (publickey).";
        assert_eq!(classify_stderr(denied), None);
        assert_eq!(link_error(denied), LinkError::Refused(denied.into()));
    }

    // [D] pure
    #[test]
    fn a_host_key_change_is_never_accepted() {
        let changed = "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n\
                       @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n\
                       @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n\
                       IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!\n\
                       Host key for desktop has changed and you have requested strict checking.\n\
                       Host key verification failed.\n";
        assert_eq!(classify_stderr(changed), Some(Login::HostKeyChanged));
        assert_eq!(link_error(changed), LinkError::HostKeyChanged);
        // a cloud machine's keys are pinned: one ssh doesn't know is a changed one, and no login is ever asked for
        let mut cloud = crate::runners::tests::ssh_runner("c1", "runner@10.0.0.9");
        cloud.cloud = Some(crate::runners::CloudSsh {
            identity_agent: "/r/agent.sock".into(),
            identity_file: "/r/id.pub".into(),
            certificate: "/r/id-cert.pub".into(),
            known_hosts: "/r/known_hosts".into(),
        });
        let unknown = LinkError::NeedsLogin(Login::UnknownHostKey);
        assert_eq!(
            for_runner(&cloud, unknown.clone()),
            LinkError::HostKeyChanged
        );
        assert!(matches!(
            for_runner(&cloud, LinkError::NeedsLogin(Login::Passphrase)),
            LinkError::Refused(_)
        ));
        let ssh = crate::runners::tests::ssh_runner("desktop", "desktop");
        assert_eq!(for_runner(&ssh, unknown.clone()), unknown);
        // the file never lets ssh learn or replace a key on its own
        let text = super::super::ssh_config::render(&crate::runners::tests::ssh_runner(
            "desktop", "desktop",
        ));
        assert!(text.contains("\nStrictHostKeyChecking yes\n"));
        assert!(text.contains("\nUpdateHostKeys no\n"));
        // and the master is started with strict checking on its command line too
        #[cfg(all(unix, not(target_os = "android")))]
        {
            let b = format!(
                "{:?}",
                openssh_impl::builder(Path::new("/r/ssh_config"), Path::new("/r"))
            );
            assert!(b.contains("known_hosts_check: Strict"), "{b}");
            assert!(b.contains("control_persist: IdleFor(600)"), "{b}");
            assert!(b.contains("config_file: Some(\"/r/ssh_config\")"), "{b}");
            assert!(b.contains("control_dir: Some(\"/r\")"), "{b}");
        }
    }

    // [D] pure
    #[test]
    fn redial_backoff_is_the_designs() {
        let secs: Vec<u64> = (0..7).map(|n| Redial::delay(n).as_secs()).collect();
        assert_eq!(secs, [5, 15, 45, 120, 120, 120, 120]);
        assert_eq!(Redial::delay(u32::MAX), Duration::from_secs(120));
    }

    // [D] pure
    #[test]
    fn a_lost_runner_is_dialled_again_on_the_backoff_and_a_returned_one_starts_over() {
        let mut c = RedialClock::default();
        assert!(!c.tick(false, 100), "a runner in reach is not dialled");
        assert!(!c.tick(true, 100), "the loss is seen: wait 5 s");
        assert!(!c.tick(true, 104));
        assert!(c.tick(true, 105), "the first redial");
        assert!(!c.tick(true, 106) && !c.tick(true, 119), "then 15 s");
        assert!(c.tick(true, 121), "the second redial");
        assert!(!c.tick(true, 122) && !c.tick(true, 166), "then 45 s");
        assert!(c.tick(true, 167), "the third redial");
        assert!(!c.tick(true, 168) && !c.tick(true, 287), "then every 120 s");
        assert!(c.tick(true, 288), "the fourth redial");
        assert!(!c.tick(false, 500), "back in reach");
        assert!(
            !c.tick(true, 600) && c.tick(true, 605),
            "a new loss starts at 5 s again"
        );
    }

    // [D] pure
    #[test]
    fn effective_reads_ssh_g() {
        let out = "host desktop\nuser runner\nforwardagent no\nclearallforwardings yes\n\
                   localforward 127.0.0.1:8080 localhost:80\nremoteforward [::1]:9000 [127.0.0.1]:9000\n\
                   dynamicforward 127.0.0.1:1080\nproxyjump bastion\n";
        assert_eq!(
            Effective::parse(out),
            Effective {
                forward_agent: false,
                forwards: vec![
                    "localforward 127.0.0.1:8080 localhost:80".into(),
                    "remoteforward [::1]:9000 [127.0.0.1]:9000".into(),
                    "dynamicforward 127.0.0.1:1080".into(),
                ],
                proxy: Some("bastion".into()),
            }
        );
        // an agent socket path is forwarding too; `none` is no proxy
        let e = Effective::parse("forwardagent /run/agent.sock\nproxycommand none\n");
        assert!(e.forward_agent);
        assert_eq!(e.proxy, None);
        assert_eq!(
            Effective::parse("forwardagent no\nproxycommand nc %h %p\n").proxy,
            Some("nc %h %p".into())
        );
    }
}
