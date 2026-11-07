//! The owner's end of the channel: the sidecar's stdout in, its stdin out, and each stream the sidecar opens handed to
//! the job's proxy as a [`Relayed`] stream (the proxy's `Listener::Streams`).
//!
//! [`wait_ready`] reads the sidecar's `READY` and checks the address it names; [`run`] then carries the channel on the
//! shell with `Side::Owner` until it ends, sending a `BEAT` every `beat`. Nothing the reader does waits: a new stream
//! goes to the proxy by `try_send` (a full or closed channel resets it), and so does each foreign-source event (a full
//! channel counts it). [`Sidecar`] starts the sidecar's container through podman, drains its stderr as it comes, and
//! stops it.

use std::collections::VecDeque;
use std::ffi::OsString;
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use gleipnir::net::proxy::Relayed;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, DuplexStream, ReadHalf, WriteHalf};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::JoinHandle;

use crate::frame::{Decoder, Frame, HEADER, Kind, MAX_DATA, MAX_STREAMS, Ready};
use crate::mux::{Out, Side};
use crate::shell::{self, Abort, Config, Consumer, Log, Shell};

/// The room [`run`]'s `streams` channel needs: every stream the sidecar may count, twice over.
pub const STREAMS_ROOM: usize = 2 * MAX_STREAMS;
/// How long the sidecar has to send its `READY`.
pub const READY_LIMIT: Duration = Duration::from_secs(10);
/// The owner's `BEAT` interval.
pub const BEAT: Duration = Duration::from_secs(10);
/// How long [`Sidecar::stop`] waits for the sidecar to exit once its stdin is closed.
pub const STOP_LIMIT: Duration = Duration::from_secs(10);
/// The sidecar's stderr kept for refusal texts: its last 4 KiB.
pub const STDERR_KEEP: usize = 4096;

/// Why the owner's end of the channel ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum End {
    /// The sidecar's output ended (mid-frame too, logged as "the relay ended mid-frame"), or its input closed.
    Eof,
    /// The sidecar broke a channel rule.
    Violation(String),
    /// No good `READY` (none in time, the relay gone before it, another frame first, another address): the reason.
    Ready(String),
    /// A write to the sidecar made no progress for the stall limit.
    Stalled,
    /// The sidecar's stream ids are used up.
    IdsUsedUp,
}

/// What the owner hears from the sidecar besides streams.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OwnerEvent {
    /// A connection from an address that isn't the job's (the sidecar closed it).
    ForeignSource(IpAddr),
    /// Foreign-source events dropped since the last one went out, because the events channel was full.
    EventsDropped(u64),
}

/// Reads the sidecar's first frame, which must be a `READY` naming `want`, within `limit`. Reads nothing past it.
pub async fn wait_ready(
    out: &mut (impl AsyncRead + Unpin),
    want: SocketAddr,
    limit: Duration,
) -> Result<(), End> {
    match tokio::time::timeout(limit, read_ready(out)).await {
        Err(_) => Err(End::Ready(format!("no READY within {limit:?}"))),
        Ok(Err(e)) => Err(e),
        Ok(Ok(got)) if got == want => Ok(()),
        Ok(Ok(got)) => Err(End::Ready(format!("READY names {got}, not {want}"))),
    }
}

/// The first frame's address, read exactly: its header, then its payload.
async fn read_ready(out: &mut (impl AsyncRead + Unpin)) -> Result<SocketAddr, End> {
    let gone = |_| End::Ready("the relay ended before its READY".into());
    let bad = |v: crate::frame::Violation| End::Violation(v.to_string());
    let mut head = [0u8; HEADER];
    out.read_exact(&mut head).await.map_err(gone)?;
    let mut dec = Decoder::new();
    let mut frames = dec.push(&head).map_err(bad)?;
    if frames.is_empty() {
        let len = u32::from_be_bytes([head[5], head[6], head[7], head[8]]) as usize;
        let mut payload = vec![0u8; len];
        out.read_exact(&mut payload).await.map_err(gone)?;
        frames = dec.push(&payload).map_err(bad)?;
    }
    let Some(f) = frames.pop() else {
        return Err(End::Violation("the first frame didn't decode".into()));
    };
    if f.kind != Kind::Ready {
        return Err(End::Ready(format!(
            "the first frame is {:?}, not READY",
            f.kind
        )));
    }
    Ready::parse(&f.payload)
        .map(|r| r.listen)
        .ok_or_else(|| End::Violation("READY's payload isn't an address".into()))
}

/// A stream's owner side: its end of the `duplex` whose other end the proxy holds, and the sender of the proxy's
/// `gone`.
struct Stream {
    io: DuplexStream,
    alive: Alive,
}

/// The sender of a stream's `gone`, which lives in the shell's abort. An abort (a reset either way, the channel's end)
/// drops it at once, and the proxy drops the connection wherever it is. A stream closed by both `FIN`s drops its abort
/// unused; the sender then waits until the proxy lets go of the stream or the channel ends, since the proxy may still
/// be copying what the stream left in its `duplex`, and a `gone` then would cut those bytes off.
struct Alive {
    tx: Option<oneshot::Sender<()>>,
    ended: watch::Receiver<()>,
}

impl Drop for Alive {
    fn drop(&mut self) {
        let (Some(mut tx), Ok(rt)) = (self.tx.take(), tokio::runtime::Handle::try_current()) else {
            return;
        };
        let mut ended = self.ended.clone();
        rt.spawn(async move {
            tokio::select! {
                () = tx.closed() => {}
                _ = ended.changed() => {}
            }
        });
    }
}

impl Consumer for Stream {
    type R = ReadHalf<DuplexStream>;
    type W = WriteHalf<DuplexStream>;
    fn split(self) -> (Self::R, Self::W, Abort) {
        let (r, w) = tokio::io::split(self.io);
        let mut alive = self.alive;
        (r, w, Box::new(move || drop(alive.tx.take())))
    }
}

/// Carries the channel after [`wait_ready`]: `out` is the sidecar's stdout, `inp` its stdin. Each stream the sidecar
/// opens goes on `streams` (which needs room for [`STREAMS_ROOM`]); foreign sources go on `events`; a `BEAT` goes out
/// every `beat` ([`BEAT`] in production), and a write that makes no progress for `stall` ([`shell::STALL`]) ends the
/// channel. Returns how it ended, with `out` and `inp` dropped and every stream gone.
pub async fn run(
    out: impl AsyncRead + Unpin,
    inp: impl AsyncWrite + Unpin,
    streams: mpsc::Sender<Relayed>,
    events: mpsc::Sender<OwnerEvent>,
    beat: Duration,
    stall: Duration,
    log: Log,
) -> End {
    let mut cfg = Config::new(Side::Owner);
    cfg.stall = stall;
    let shell: Shell<Stream> = Shell::new(cfg, log.clone());
    shell.ready_read();
    // dropped when `run` returns: every `gone` still held after a graceful close fires then
    let (ended_tx, ended) = watch::channel(());
    shell.on_new_stream(move |_| {
        let (ours, theirs) = tokio::io::duplex(MAX_DATA);
        let (tx, gone) = oneshot::channel();
        // never awaited: the receiver is the proxy's accept loop
        streams.try_send(Relayed { io: theirs, gone }).ok()?;
        let alive = Alive {
            tx: Some(tx),
            ended: ended.clone(),
        };
        Some(Stream { io: ours, alive })
    });
    let dropped = Arc::new(AtomicU64::new(0));
    let held = dropped.clone();
    let hook_log = log.clone();
    shell.on_event(move |o| match o {
        Out::Event(src) => {
            let n = held.load(Ordering::Relaxed);
            if n > 0 && events.try_send(OwnerEvent::EventsDropped(n)).is_ok() {
                held.store(0, Ordering::Relaxed);
            }
            if events.try_send(OwnerEvent::ForeignSource(src.0)).is_err() {
                held.fetch_add(1, Ordering::Relaxed);
            }
        }
        Out::EventsCounted(n) => {
            hook_log.line(&format!("{n} foreign sources not reported (past the cap)"));
        }
        _ => {}
    });
    let end = tokio::select! {
        e = shell.run(out, inp) => e,
        () = beats(&shell, beat) => unreachable!("the beats never end"),
    };
    drop(ended_tx);
    let n = dropped.load(Ordering::Relaxed);
    if n > 0 {
        log.line(&format!(
            "{n} foreign-source events dropped: the events channel was full"
        ));
    }
    match end {
        shell::End::Eof => End::Eof,
        shell::End::Io(e) => {
            log.line(&e);
            End::Eof
        }
        shell::End::Violation(v) => End::Violation(v),
        shell::End::Stalled => End::Stalled,
        shell::End::IdsUsedUp => End::IdsUsedUp,
        // the owner sends the beats and checks none
        shell::End::BeatLost => End::Violation("a heartbeat limit on the owner".into()),
    }
}

async fn beats(shell: &Shell<Stream>, every: Duration) {
    let mut tick = tokio::time::interval(every);
    loop {
        tick.tick().await;
        shell.send(Frame::empty(0, Kind::Beat));
    }
}

/// The sidecar's container, run by podman with its stdio piped.
pub struct Sidecar {
    child: Child,
    io: Option<(ChildStdin, ChildStdout)>,
    stderr: Arc<Mutex<VecDeque<u8>>>,
    drain: JoinHandle<()>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Sidecar {
    /// Runs `podman` with `argv` (the caller's, `--detach-keys=` among them) and `env` added to this process's. A task
    /// reads its stderr as it comes, keeping the last [`STDERR_KEEP`] bytes, so the sidecar never blocks on it.
    pub async fn start(
        podman: &Path,
        argv: Vec<OsString>,
        env: &[(OsString, OsString)],
    ) -> Result<Sidecar, String> {
        let mut child = Command::new(podman)
            .args(argv)
            .envs(env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("starting {}: {e}", podman.display()))?;
        let (Some(inp), Some(out), Some(mut err)) =
            (child.stdin.take(), child.stdout.take(), child.stderr.take())
        else {
            return Err("the sidecar's stdio isn't piped".into());
        };
        let stderr = Arc::new(Mutex::new(VecDeque::with_capacity(STDERR_KEEP)));
        let ring = stderr.clone();
        let drain = tokio::spawn(async move {
            let mut buf = vec![0u8; 4096];
            loop {
                match err.read(&mut buf).await {
                    Ok(0) | Err(_) => return,
                    Ok(n) => {
                        let mut r = lock(&ring);
                        r.extend(&buf[..n]);
                        let over = r.len().saturating_sub(STDERR_KEEP);
                        r.drain(..over);
                    }
                }
            }
        });
        Ok(Sidecar {
            child,
            io: Some((inp, out)),
            stderr,
            drain,
        })
    }

    /// The sidecar's stdin and stdout, for [`wait_ready`] and [`run`]; `None` once taken.
    pub fn take_io(&mut self) -> Option<(ChildStdin, ChildStdout)> {
        self.io.take()
    }

    /// The last [`STDERR_KEEP`] bytes the sidecar (or podman) wrote to stderr: a refusal's text, the sidecar's log.
    pub fn stderr(&self) -> String {
        let r = lock(&self.stderr);
        let (a, b) = r.as_slices();
        String::from_utf8_lossy(&[a, b].concat()).into_owned()
    }

    /// Closes the sidecar's stdin (and stdout, if never taken), waits up to [`STOP_LIMIT`] for it to exit, then runs
    /// `podman rm -f name` and kills what is still running. Answers the sidecar's exit code (a signal `n` as `128 + n`),
    /// or `None` when it did not exit within the limit.
    pub async fn stop(
        mut self,
        podman: &Path,
        name: &str,
        env: &[(OsString, OsString)],
    ) -> Option<i32> {
        use std::os::unix::process::ExitStatusExt;
        self.io = None;
        let code = tokio::time::timeout(STOP_LIMIT, self.child.wait())
            .await
            .ok()
            .and_then(Result::ok)
            .and_then(|s| s.code().or_else(|| s.signal().map(|n| 128 + n)));
        let exited = code.is_some();
        let _ = Command::new(podman)
            .args(["rm", "-f", name])
            .envs(env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;
        if !exited {
            let _ = self.child.kill().await;
        }
        self.drain.abort();
        code
    }
}

#[cfg(test)]
mod tests;
