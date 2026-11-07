//! A runner's link session (docs/develop/hub.md, "Runners: attempts"): the protocol over a runner's [`Channels`].
//!
//! [`Session`] reads frames from the control channel and writes the hub's, pings every 10 s, and calls the link lost
//! after 45 s without a frame or at an EOF without `bye`. A `log` frame is appended to the attempt's log at the hub's
//! offset ([`append_at`]), and only for an attempt [`Route`] accepts (placed on that runner, with its nonce); every
//! other frame goes to the hub as a [`LinkEvent`].

use super::transport::{Channels, Reader, Writer};
use sleipnir::proto::{Frame, FrameReader, FrameWriter, JobRef, MAX_CHUNK, MAX_LINE};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use zeroize::Zeroize;

/// A `ping` this often, each way.
pub const PING_EVERY: Duration = Duration::from_secs(10);
/// The link is lost after this long without a frame.
pub const LOST_AFTER: Duration = Duration::from_secs(45);

/// Where a runner's log frames go: the log file of an attempt the hub placed on that runner with that nonce, or
/// `None` (the frame is ignored with a notice).
pub trait Route: Send + Sync {
    fn log_path(&self, runner: &str, r: &JobRef) -> Option<PathBuf>;

    /// Writes BYTES, which start at OFFSET of the runner's log of R, into the hub's copy: the copy's end after it, in
    /// the runner's offsets; `None` when the frame is ignored. The queue's own redacts a keyed job's log first.
    fn write_log(
        &self,
        runner: &str,
        r: &JobRef,
        offset: u64,
        bytes: &[u8],
    ) -> Option<std::io::Result<u64>> {
        let path = self.log_path(runner, r)?;
        Some(append_at(&path, offset, bytes))
    }
}

/// What a session tells the hub.
#[derive(Debug)]
pub enum LinkEvent {
    /// A frame from the runner (not `log`, `ping` or `pong`, which the session handles).
    Frame { runner: String, frame: Frame },
    /// R's log, as the hub holds it, now ends at UPTO.
    Logged {
        runner: String,
        r: JobRef,
        upto: u64,
    },
    /// The runner's clock read AT (seconds since the epoch) when it sent its `ping`: the health check's clock reading.
    Clock { runner: String, at: u64 },
    /// The link is lost (no frame for 45 s, an EOF without `bye`, a channel error): never a job's result.
    Lost { runner: String, why: String },
    /// The runner said `bye`.
    Bye { runner: String },
}

/// One runner's link. Dropping it ends the session (the channels close; the runner's attempts run on).
#[derive(Clone)]
pub struct Session(Arc<Shared>);

struct Shared {
    runner: String,
    out: mpsc::UnboundedSender<Frame>,
    tasks: std::sync::Mutex<Vec<tokio::task::JoinHandle<()>>>,
}

impl Shared {
    fn tasks(&self) -> std::sync::MutexGuard<'_, Vec<tokio::task::JoinHandle<()>>> {
        self.tasks.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Drop for Shared {
    fn drop(&mut self) {
        for t in self.tasks().iter() {
            t.abort();
        }
    }
}

impl Session {
    /// Starts the session on CHANNELS for RUNNER: its events go to EVENTS, its log frames through ROUTE. The bulk
    /// channels are held for the session's life (sync uses them).
    pub fn start(
        runner: &str,
        channels: Channels,
        route: Arc<dyn Route>,
        events: mpsc::UnboundedSender<LinkEvent>,
    ) -> Session {
        let Channels {
            control,
            bulk_in,
            bulk_out,
        } = channels;
        let (out, queued) = mpsc::unbounded_channel();
        let (tx, rx, err, hold) = control.split();
        // the control session's hold lives with the writer: dropping it would end the session under the link
        let writer = crate::clock::spawn(
            "runners:link-write",
            write_loop(tx, queued, (bulk_in, bulk_out, hold)),
        );
        let reader = crate::clock::spawn(
            "runners:link-read",
            read_loop(runner.to_string(), rx, route, events, out.clone()),
        );
        let mut tasks = vec![writer, reader];
        // the runner's standard error is read for as long as the link lives: a pipe nobody reads is closed when it is
        // dropped, and a runner that then writes to it (its log lines) ends
        if let Some(mut err) = err {
            tasks.push(crate::clock::spawn("runners:link-err", async move {
                let _ = tokio::io::copy(&mut err, &mut tokio::io::sink()).await;
            }));
        }
        Session(Arc::new(Shared {
            runner: runner.into(),
            out,
            tasks: std::sync::Mutex::new(tasks),
        }))
    }

    pub fn runner(&self) -> &str {
        &self.0.runner
    }

    /// Whether the link has ended (lost, or closed): nothing more will arrive on it.
    pub fn ended(&self) -> bool {
        self.0.tasks().get(1).is_none_or(|t| t.is_finished())
    }

    /// Queues F for the runner; false once the link has ended.
    pub fn send(&self, f: Frame) -> bool {
        let ended = self.0.tasks().first().is_none_or(|t| t.is_finished());
        !ended && self.0.out.send(f).is_ok()
    }

    /// Ends the session now and returns once its tasks are gone, so the channels they held (and a transport's
    /// sessions with them) are free for a new link. Every copy of the session is ended; one that is ended is left as
    /// it is.
    pub async fn close(&self) {
        let tasks = std::mem::take(&mut *self.0.tasks());
        for t in &tasks {
            t.abort();
        }
        for t in tasks {
            let _ = t.await;
        }
    }
}

/// Writes the queued frames, and a `ping` every [`PING_EVERY`], until the queue or the channel ends.
async fn write_loop(
    mut tx: Writer,
    mut queued: mpsc::UnboundedReceiver<Frame>,
    _held: (
        super::transport::Channel,
        super::transport::Channel,
        super::transport::Hold,
    ),
) {
    let mut ping = crate::clock::interval(PING_EVERY);
    loop {
        let f = tokio::select! {
            f = queued.recv() => match f {
                Some(f) => f,
                None => break,
            },
            _ = ping.tick() => Frame::Ping { at: crate::clock::wall_secs() as u64 },
        };
        let mut w = FrameWriter::new(Vec::new());
        if let Err(e) = w.write(&f) {
            tracing::warn!("runners: a frame not written: {e}");
            continue;
        }
        let mut bytes = w.into_inner();
        let sent = async {
            tx.write_all(&bytes).await?;
            tx.flush().await
        }
        .await;
        if matches!(f, Frame::Key(_)) {
            bytes.zeroize();
        }
        if sent.is_err() || matches!(f, Frame::Bye { .. }) {
            break;
        }
    }
    let _ = tx.shutdown().await;
}

/// Reads frames until the channel ends: pings answered, logs appended, the rest passed on; the link lost after
/// [`LOST_AFTER`] without a frame or at an end without `bye`.
async fn read_loop(
    runner: String,
    rx: Reader,
    route: Arc<dyn Route>,
    events: mpsc::UnboundedSender<LinkEvent>,
    out: mpsc::UnboundedSender<Frame>,
) {
    let mut rx = BufReader::new(rx);
    let why = loop {
        let f = match crate::clock::timeout(LOST_AFTER, read_frame(&mut rx)).await {
            Err(_) => break format!("no frame for {} s", LOST_AFTER.as_secs()),
            Ok(Ok(None)) => break "the channel ended without bye".to_string(),
            Ok(Err(e)) => break format!("the channel: {e}"),
            Ok(Ok(Some(f))) => f,
        };
        match f {
            Frame::Ping { at } => {
                let _ = out.send(Frame::Pong { at });
                if at > 0 {
                    let _ = events.send(LinkEvent::Clock {
                        runner: runner.clone(),
                        at,
                    });
                }
            }
            Frame::Pong { .. } | Frame::Unknown => {}
            Frame::Bye { .. } => {
                let _ = events.send(LinkEvent::Bye { runner });
                return;
            }
            Frame::Log { r, offset, bytes } => match route.write_log(&runner, &r, offset, &bytes) {
                None => tracing::info!(
                    "runners: {runner}: a log frame about {} attempt {} ({:?}), which the hub never gave it: ignored",
                    r.job,
                    r.attempt,
                    r.nonce
                ),
                Some(Ok(upto)) => {
                    let _ = events.send(LinkEvent::Logged {
                        runner: runner.clone(),
                        r,
                        upto,
                    });
                }
                Some(Err(e)) => tracing::warn!("runners: {runner}: {} log: {e}", r.job),
            },
            frame => {
                let _ = events.send(LinkEvent::Frame {
                    runner: runner.clone(),
                    frame,
                });
            }
        }
    };
    let _ = events.send(LinkEvent::Lost { runner, why });
}

/// One frame from RX, through the protocol's codec: its line, then the chunk its `len` announces.
pub(crate) async fn read_frame(rx: &mut BufReader<Reader>) -> std::io::Result<Option<Frame>> {
    use std::io::{Error, ErrorKind};
    loop {
        let mut line = Vec::new();
        let n = (&mut *rx)
            .take(MAX_LINE as u64 + 1)
            .read_until(b'\n', &mut line)
            .await?;
        if n == 0 {
            return Ok(None);
        }
        if line.len() > MAX_LINE {
            return Err(Error::new(
                ErrorKind::InvalidData,
                "a frame line over its limit",
            ));
        }
        if !line.ends_with(b"\n") {
            return Err(Error::new(
                ErrorKind::UnexpectedEof,
                "the channel ended inside a frame",
            ));
        }
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        #[derive(serde::Deserialize)]
        struct Header {
            #[serde(default)]
            len: Option<u64>,
        }
        let header: Header = serde_json::from_slice(&line)
            .map_err(|e| Error::new(ErrorKind::InvalidData, format!("not a frame: {e}")))?;
        if header.len.is_some() {
            let mut len = [0u8; 4];
            rx.read_exact(&mut len).await?;
            let n = u32::from_be_bytes(len) as usize;
            if n > MAX_CHUNK {
                return Err(Error::new(ErrorKind::InvalidData, "a chunk over 1 MiB"));
            }
            line.extend_from_slice(&len);
            let at = line.len();
            line.resize(at + n, 0);
            rx.read_exact(&mut line[at..]).await?;
        }
        let parsed = FrameReader::new(&line[..])
            .read()
            .map_err(|e| Error::new(ErrorKind::InvalidData, e.to_string()));
        line.zeroize();
        return parsed;
    }
}

/// Appends BYTES, which start at OFFSET of the runner's log, to the hub's copy at PATH: only what the copy lacks, so
/// a chunk sent again after a reconnect is never doubled. A chunk past the copy's end (a gap) is refused. The copy's
/// length after it.
pub fn append_at(path: &Path, offset: u64, bytes: &[u8]) -> std::io::Result<u64> {
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    let len = f.metadata()?.len();
    if offset > len {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("a log chunk at {offset}, past the copy's end at {len}"),
        ));
    }
    let skip = (len - offset) as usize;
    if skip < bytes.len() {
        f.write_all(&bytes[skip..])?;
    }
    Ok(len.max(offset + bytes.len() as u64))
}

#[cfg(test)]
mod tests {
    use super::*;

    // [D] pure (a file): a chunk sent again is not doubled, a gap is refused, the rest is appended
    #[test]
    fn append_at_writes_only_what_the_copy_lacks() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("log");
        assert_eq!(append_at(&log, 0, b"hello ").unwrap(), 6);
        assert_eq!(append_at(&log, 0, b"hello ").unwrap(), 6);
        assert_eq!(append_at(&log, 3, b"lo world").unwrap(), 11);
        assert!(append_at(&log, 20, b"gap").is_err());
        assert_eq!(std::fs::read(&log).unwrap(), b"hello world");
    }
}
