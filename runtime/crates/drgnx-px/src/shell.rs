//! The channel's runtime around the pure core, the same on both ends:
//!
//! 1. one reader reads the input unconditionally, decodes, and steps the `Mux`; it awaits nothing but the read, and
//!    its effects never block (a queue appended to, a task woken, a hook called that must not block);
//! 2. one writer owns the output and writes what [`Pending::next`] returns, one frame at a time, stepping the `Mux`
//!    with [`In::Wrote`] as it takes each `FIN` and `RST` (`take_next`);
//! 3. two tasks per stream: the queue to the consumer (reporting `LocalDrained` once written), and the consumer to
//!    `LocalData` up to the stream's credit; both aborted when the stream is dropped;
//! 4. the state behind a `std::sync::Mutex`, never held across an `.await`;
//! 5. logs through [`Log`], a bounded buffer that drops lines when full and never blocks;
//! 6. on any end of the channel every stream still there is aborted (on the sidecar its job socket is reset).
//!
//! A write that makes no progress for the stall limit ends the channel; on the sidecar so does the heartbeat's loss.

use std::collections::{HashMap, VecDeque};
use std::io;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use tokio::io::{
    AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, DuplexStream, ReadHalf, WriteHalf,
};
use tokio::sync::Notify;
use tokio::task::AbortHandle;
use tokio::time::Instant;

use crate::frame::{Decoder, Frame, HEADER, Kind, MAX_DATA, MAX_STREAMS, encode};
use crate::mux::{In, Mux, Out, Side, StreamViolation};
use crate::pending::Pending;

/// A channel write without progress for this long ends the channel.
pub const STALL: Duration = Duration::from_secs(60);
/// The sidecar ends after this long without a `BEAT`, on its monotonic clock.
pub const BEAT_LIMIT: Duration = Duration::from_secs(60);
/// The log buffer's size; lines past it are dropped and counted.
pub const LOG_CAP: usize = 16 * 1024;

/// Whether the heartbeat is lost, `since_beat` after the last `BEAT` (or the start).
pub fn beat_lost(since_beat: Duration, limit: Duration) -> bool {
    since_beat >= limit
}

/// Whether a write that has made no progress for `since_progress` is a stall.
pub fn stalled(since_progress: Duration, limit: Duration) -> bool {
    since_progress >= limit
}

/// The writer takes the next frame to write, and what the `Mux` says to that. A `FIN` or `RST` counts as written
/// from here (`In::Wrote`): the one writer writes frames in the order it takes them, each in full, so anything decided
/// after this (an `OPEN` its freed place lets in) is behind it on the pipe. Stepping only once `write(2)` returned
/// would leave a gap in which the peer could read the frame and answer it while this end still counted the stream.
pub(crate) fn take_next(
    mux: &mut Mux,
    pending: &mut Pending,
) -> Result<Option<(Frame, Vec<Out>)>, StreamViolation> {
    let Some(f) = pending.next() else {
        return Ok(None);
    };
    let outs = if matches!(f.kind, Kind::Fin | Kind::Rst) {
        mux.step(In::Wrote {
            stream: f.stream,
            kind: f.kind,
        })?
    } else {
        Vec::new()
    };
    Ok(Some((f, outs)))
}

/// Why the channel ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum End {
    /// The input ended.
    Eof,
    /// A frame or the channel's state broke a rule (or this end's shell did).
    Violation(String),
    /// A write made no progress for the stall limit.
    Stalled,
    /// No `BEAT` for the heartbeat limit.
    BeatLost,
    /// The stream ids are used up.
    IdsUsedUp,
    /// Reading or writing the channel failed.
    Io(String),
}

/// What makes the consumer's far side see a reset; called before the stream's tasks are aborted.
pub type Abort = Box<dyn FnOnce() + Send>;

/// A stream's consumer: the job's socket in the sidecar, the stream's `duplex` in the owner.
pub trait Consumer: Send + 'static {
    type R: AsyncRead + Unpin + Send + 'static;
    type W: AsyncWrite + Unpin + Send + 'static;
    fn split(self) -> (Self::R, Self::W, Abort);
}

/// A `duplex` can't carry a reset: its abort does nothing, and the far side sees the halves close.
impl Consumer for DuplexStream {
    type R = ReadHalf<DuplexStream>;
    type W = WriteHalf<DuplexStream>;
    fn split(self) -> (Self::R, Self::W, Abort) {
        let (r, w) = tokio::io::split(self);
        (r, w, Box::new(|| {}))
    }
}

/// How a shell runs.
#[derive(Clone, Debug)]
pub struct Config {
    pub side: Side,
    /// The write-stall limit ([`STALL`] in production).
    pub stall: Duration,
    /// The heartbeat limit (the sidecar's [`BEAT_LIMIT`]; none on the owner, which sends the beats).
    pub beat_limit: Option<Duration>,
    /// Test only: log every frame read and written.
    #[cfg(feature = "test-hooks")]
    pub log_frames: bool,
    /// Test only: panic at the first `BEAT`.
    #[cfg(feature = "test-hooks")]
    pub panic_on_beat: bool,
}

impl Config {
    pub fn new(side: Side) -> Self {
        Config {
            side,
            stall: STALL,
            beat_limit: None,
            #[cfg(feature = "test-hooks")]
            log_frames: false,
            #[cfg(feature = "test-hooks")]
            panic_on_beat: false,
        }
    }
}

/// A bounded log that never blocks its caller: lines past [`LOG_CAP`] are dropped, and one line with their count
/// goes in once there is room.
#[derive(Clone, Default)]
pub struct Log {
    inner: Arc<LogInner>,
}

#[derive(Default)]
struct LogInner {
    buf: Mutex<LogBuf>,
    wake: Notify,
}

#[derive(Default)]
struct LogBuf {
    bytes: VecDeque<u8>,
    dropped: u64,
}

impl Log {
    fn buf(&self) -> MutexGuard<'_, LogBuf> {
        self.inner.buf.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Adds `drgnx-px: LINE\n`, or counts it as dropped.
    pub fn line(&self, line: &str) {
        let mut b = self.buf();
        if b.dropped > 0 {
            let note = format!("drgnx-px: {} log lines dropped\n", b.dropped);
            if b.bytes.len() + note.len() <= LOG_CAP {
                b.bytes.extend(note.as_bytes());
                b.dropped = 0;
            }
        }
        let text = format!("drgnx-px: {line}\n");
        if b.dropped > 0 || b.bytes.len() + text.len() > LOG_CAP {
            b.dropped += 1;
            return;
        }
        b.bytes.extend(text.as_bytes());
        drop(b);
        self.inner.wake.notify_one();
    }

    /// Takes everything buffered.
    pub fn take(&self) -> Vec<u8> {
        self.buf().bytes.drain(..).collect()
    }

    /// Writes the buffer to `w` as it fills; returns only when `w` fails.
    pub async fn drain_to(&self, mut w: impl AsyncWrite + Unpin) {
        let mut chunk = Vec::with_capacity(4096);
        loop {
            chunk.clear();
            chunk.extend(self.buf().bytes.iter().take(4096));
            if chunk.is_empty() {
                self.inner.wake.notified().await;
                continue;
            }
            match w.write(&chunk).await {
                Ok(0) | Err(_) => return,
                Ok(n) => {
                    self.buf().bytes.drain(..n);
                }
            }
        }
    }
}

type NewStream<C> = Box<dyn FnMut(u32) -> Option<C> + Send>;
type OnEvent = Box<dyn FnMut(&Out) + Send>;

/// One end of the channel.
pub struct Shell<C: Consumer> {
    inner: Arc<Inner<C>>,
}

impl<C: Consumer> Clone for Shell<C> {
    fn clone(&self) -> Self {
        Shell {
            inner: self.inner.clone(),
        }
    }
}

struct Inner<C: Consumer> {
    cfg: Config,
    log: Log,
    started: Instant,
    state: Mutex<State<C>>,
    writer: Notify,
    room: Notify,
    ended: Notify,
}

struct State<C> {
    mux: Mux,
    pending: Pending,
    streams: HashMap<u32, Ctl>,
    end: Option<End>,
    last_beat: Instant,
    writing_since: Option<Instant>,
    new_stream: Option<NewStream<C>>,
    on_event: Option<OnEvent>,
}

/// A stream's shell side: its queue toward the consumer, and its tasks.
struct Ctl {
    queue: VecDeque<Vec<u8>>,
    eof: bool,
    down: Arc<Notify>,
    up: Arc<Notify>,
    tasks: Vec<AbortHandle>,
    abort: Option<Abort>,
    alive: u8,
}

impl Ctl {
    fn kill(mut self) {
        if let Some(abort) = self.abort.take() {
            abort();
        }
        for t in &self.tasks {
            t.abort();
        }
    }
}

enum Next {
    Chunk(Vec<u8>),
    Eof,
    Wait,
    Gone,
}

impl<C: Consumer> Shell<C> {
    pub fn new(cfg: Config, log: Log) -> Self {
        let now = Instant::now();
        let side = cfg.side;
        Shell {
            inner: Arc::new(Inner {
                cfg,
                log,
                started: now,
                state: Mutex::new(State {
                    mux: Mux::new(side),
                    pending: Pending::new(side),
                    streams: HashMap::new(),
                    end: None,
                    last_beat: now,
                    writing_since: None,
                    new_stream: None,
                    on_event: None,
                }),
                writer: Notify::new(),
                room: Notify::new(),
                ended: Notify::new(),
            }),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State<C>> {
        self.inner.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The owner's hook for a stream the peer opened: its consumer, or `None` to reset it. Called by the reader:
    /// it must not block.
    pub fn on_new_stream(&self, f: impl FnMut(u32) -> Option<C> + Send + 'static) {
        self.lock().new_stream = Some(Box::new(f));
    }

    /// The hook for `Out::Event` and `Out::EventsCounted`. Called by the reader: it must not block.
    pub fn on_event(&self, f: impl FnMut(&Out) + Send + 'static) {
        self.lock().on_event = Some(Box::new(f));
    }

    pub fn log(&self) -> &Log {
        &self.inner.log
    }

    /// Queues a frame of this end's own (`READY`, `BEAT`, `EVENT`) for the writer.
    pub fn send(&self, f: Frame) {
        self.lock().pending.push(f);
        self.inner.writer.notify_one();
    }

    /// Streams counted toward [`MAX_STREAMS`].
    pub fn counted(&self) -> usize {
        self.lock().mux.counted()
    }

    /// Returns once fewer than [`MAX_STREAMS`] streams are counted.
    pub async fn room(&self) {
        loop {
            if self.counted() < MAX_STREAMS {
                return;
            }
            self.inner.room.notified().await;
        }
    }

    /// Opens a stream for a consumer this end accepted (the sidecar): its id, or `None` when the ids are used up
    /// (the channel then ends with [`End::IdsUsedUp`]).
    pub fn open_local(&self, c: C) -> Result<Option<u32>, End> {
        let mut st = self.lock();
        if let Some(e) = &st.end {
            return Err(e.clone());
        }
        let outs = match st.mux.step(In::LocalOpen) {
            Ok(outs) => outs,
            Err(v) => {
                let e = End::Violation(v.to_string());
                self.set_end(&mut st, e.clone());
                return Err(e);
            }
        };
        if outs.contains(&Out::IdsUsedUp) {
            self.set_end(&mut st, End::IdsUsedUp);
            return Ok(None);
        }
        let id = outs.iter().find_map(|o| match o {
            Out::Send(f) if f.kind == Kind::Open => Some(f.stream),
            _ => None,
        });
        let Some(id) = id else {
            let e = End::Violation("a local open gave no stream".into());
            self.set_end(&mut st, e.clone());
            return Err(e);
        };
        self.attach(&mut st, id, c);
        self.apply(&mut st, outs);
        Ok(Some(id))
    }

    /// Ends the channel (the first end wins).
    pub fn finish(&self, end: End) {
        let mut st = self.lock();
        self.set_end(&mut st, end);
    }

    fn set_end(&self, st: &mut State<C>, end: End) {
        if st.end.is_none() {
            st.end = Some(end);
            self.inner.ended.notify_one();
        }
    }

    /// Runs the channel over `input` and `output` until it ends; then every stream still there is aborted.
    pub async fn run(&self, input: impl AsyncRead + Unpin, output: impl AsyncWrite + Unpin) -> End {
        let end = tokio::select! {
            e = self.reader(input) => e,
            e = self.writer(output) => e,
            e = self.watchdog() => e,
            e = self.ended() => e,
        };
        let end = {
            let mut st = self.lock();
            self.set_end(&mut st, end);
            st.end.clone().expect("just set")
        };
        let streams = std::mem::take(&mut self.lock().streams);
        for ctl in streams.into_values() {
            ctl.kill();
        }
        end
    }

    async fn ended(&self) -> End {
        loop {
            if let Some(e) = self.lock().end.clone() {
                return e;
            }
            self.inner.ended.notified().await;
        }
    }

    async fn reader(&self, mut input: impl AsyncRead + Unpin) -> End {
        let mut dec = Decoder::new();
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = match input.read(&mut buf).await {
                Ok(0) => {
                    if dec.buffered() > 0 {
                        self.inner.log.line("the relay ended mid-frame");
                    }
                    return End::Eof;
                }
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return End::Io(format!("reading the channel: {e}")),
            };
            let frames = match dec.push(&buf[..n]) {
                Ok(frames) => frames,
                Err(v) => return End::Violation(v.to_string()),
            };
            if frames.is_empty() {
                continue;
            }
            let now = Instant::now();
            let mut st = self.lock();
            st.mux.set_now(now - self.inner.started);
            for f in frames {
                #[cfg(feature = "test-hooks")]
                {
                    if self.inner.cfg.log_frames {
                        self.inner.log.line(&format!(
                            "in {:?} {} {}",
                            f.kind,
                            f.stream,
                            f.payload.len()
                        ));
                    }
                    if self.inner.cfg.panic_on_beat && f.kind == Kind::Beat {
                        panic!("drgnx-px: the test hook's panic at a BEAT");
                    }
                }
                if f.kind == Kind::Beat {
                    st.last_beat = now;
                }
                match st.mux.step(In::Frame(f)) {
                    Ok(outs) => self.apply(&mut st, outs),
                    Err(v) => return End::Violation(v.to_string()),
                }
            }
        }
    }

    async fn writer(&self, mut output: impl AsyncWrite + Unpin) -> End {
        let mut buf = Vec::with_capacity(HEADER + MAX_DATA);
        loop {
            let next = {
                let mut st = self.lock();
                let st = &mut *st;
                match take_next(&mut st.mux, &mut st.pending) {
                    Ok(Some((f, outs))) => {
                        self.apply(st, outs);
                        Some(f)
                    }
                    Ok(None) => None,
                    Err(v) => return End::Violation(v.to_string()),
                }
            };
            let Some(f) = next else {
                if let Err(e) = output.flush().await {
                    return End::Io(format!("writing the channel: {e}"));
                }
                self.inner.writer.notified().await;
                continue;
            };
            buf.clear();
            encode(&f, &mut buf);
            #[cfg(feature = "test-hooks")]
            if self.inner.cfg.log_frames {
                self.inner.log.line(&format!(
                    "out {:?} {} {}",
                    f.kind,
                    f.stream,
                    f.payload.len()
                ));
            }
            let mut off = 0;
            while off < buf.len() {
                self.lock().writing_since = Some(Instant::now());
                match output.write(&buf[off..]).await {
                    Ok(0) => return End::Io("the channel's output closed".into()),
                    Ok(n) => off += n,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                    Err(e) => return End::Io(format!("writing the channel: {e}")),
                }
            }
            self.lock().writing_since = None;
        }
    }

    async fn watchdog(&self) -> End {
        let limit = self.inner.cfg.stall;
        let tick = (limit / 4)
            .min(Duration::from_secs(1))
            .max(Duration::from_millis(1));
        let mut every = tokio::time::interval(tick);
        loop {
            every.tick().await;
            let now = Instant::now();
            let st = self.lock();
            if let Some(since) = st.writing_since
                && stalled(now - since, limit)
            {
                return End::Stalled;
            }
            if let Some(beat) = self.inner.cfg.beat_limit
                && beat_lost(now - st.last_beat, beat)
            {
                return End::BeatLost;
            }
        }
    }

    /// Steps a local event of a stream's task.
    fn local(&self, ev: In) {
        let mut st = self.lock();
        match st.mux.step(ev) {
            Ok(outs) => self.apply(&mut st, outs),
            Err(v) => self.set_end(&mut st, End::Violation(v.to_string())),
        }
    }

    /// Does what the `Mux` said; nothing here blocks.
    fn apply(&self, st: &mut State<C>, outs: Vec<Out>) {
        let mut work: VecDeque<Out> = outs.into();
        while let Some(o) = work.pop_front() {
            match o {
                Out::Send(f) => {
                    st.pending.push(f);
                    self.inner.writer.notify_one();
                }
                Out::NewStream { stream } => {
                    let c = st.new_stream.as_mut().and_then(|hook| hook(stream));
                    match c {
                        Some(c) => self.attach(st, stream, c),
                        None => match st.mux.step(In::LocalReset { stream }) {
                            Ok(more) => work.extend(more),
                            Err(v) => self.set_end(st, End::Violation(v.to_string())),
                        },
                    }
                }
                Out::Deliver { stream, bytes } => {
                    if let Some(ctl) = st.streams.get_mut(&stream) {
                        ctl.queue.push_back(bytes);
                        ctl.down.notify_one();
                    }
                }
                Out::CloseWrite { stream } => {
                    if let Some(ctl) = st.streams.get_mut(&stream) {
                        ctl.eof = true;
                        ctl.down.notify_one();
                    }
                }
                Out::Drop { stream } => {
                    if let Some(ctl) = st.streams.remove(&stream) {
                        ctl.kill();
                    }
                }
                Out::CreditFor { stream } => {
                    if let Some(ctl) = st.streams.get(&stream) {
                        ctl.up.notify_one();
                    }
                }
                Out::Discarded { .. } => {}
                Out::Room => self.inner.room.notify_one(),
                Out::IdsUsedUp => self.set_end(st, End::IdsUsedUp),
                Out::Event(_) | Out::EventsCounted(_) => {
                    if let Some(hook) = st.on_event.as_mut() {
                        hook(&o);
                    }
                }
            }
        }
    }

    /// Starts a stream's two tasks over its consumer.
    fn attach(&self, st: &mut State<C>, id: u32, c: C) {
        let (r, w, abort) = c.split();
        let down = Arc::new(Notify::new());
        let up = Arc::new(Notify::new());
        let t_down = tokio::spawn(down_task(self.clone(), id, w, down.clone()));
        let t_up = tokio::spawn(up_task(self.clone(), id, r, up.clone()));
        st.streams.insert(
            id,
            Ctl {
                queue: VecDeque::new(),
                eof: false,
                down,
                up,
                tasks: vec![t_down.abort_handle(), t_up.abort_handle()],
                abort: Some(abort),
                alive: 2,
            },
        );
    }

    /// One of a stream's tasks finished normally; the second one lets the stream's shell side go.
    fn task_done(&self, id: u32) {
        let mut st = self.lock();
        if let Some(ctl) = st.streams.get_mut(&id) {
            ctl.alive = ctl.alive.saturating_sub(1);
            if ctl.alive == 0 {
                st.streams.remove(&id);
            }
        }
    }
}

/// The stream's queue to its consumer; `CREDIT` counts what was written.
async fn down_task<C: Consumer>(shell: Shell<C>, id: u32, mut w: C::W, wake: Arc<Notify>) {
    loop {
        let next = {
            let mut st = shell.lock();
            match st.streams.get_mut(&id) {
                None => Next::Gone,
                Some(ctl) => match ctl.queue.pop_front() {
                    Some(b) => Next::Chunk(b),
                    None if ctl.eof => Next::Eof,
                    None => Next::Wait,
                },
            }
        };
        match next {
            Next::Gone => return,
            Next::Wait => wake.notified().await,
            Next::Eof => {
                let _ = w.shutdown().await;
                shell.task_done(id);
                return;
            }
            Next::Chunk(b) => {
                let n = b.len() as u32;
                if w.write_all(&b).await.is_err() {
                    shell.local(In::LocalReset { stream: id });
                    return;
                }
                shell.local(In::LocalDrained { stream: id, n });
            }
        }
    }
}

/// The stream's consumer to `LocalData`, never past the stream's credit.
async fn up_task<C: Consumer>(shell: Shell<C>, id: u32, mut r: C::R, wake: Arc<Notify>) {
    let mut buf = vec![0u8; MAX_DATA];
    loop {
        let credit = {
            let st = shell.lock();
            if !st.streams.contains_key(&id) {
                return;
            }
            st.mux.credit(id) as usize
        };
        if credit == 0 {
            wake.notified().await;
            continue;
        }
        match r.read(&mut buf[..credit.min(MAX_DATA)]).await {
            Ok(0) => {
                shell.local(In::LocalEof { stream: id });
                shell.task_done(id);
                return;
            }
            Ok(n) => shell.local(In::LocalData {
                stream: id,
                bytes: buf[..n].to_vec(),
            }),
            Err(_) => {
                shell.local(In::LocalReset { stream: id });
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests;
