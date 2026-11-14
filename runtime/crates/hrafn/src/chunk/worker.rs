//! The `hrafn-parse` worker (language packs Task 6b): a fetched pack's grammar is a native library somebody else wrote, so
//! the hub never loads it. A worker process (the hub's own binary, `ratatoskr hrafn-parse`, started under Gleipnir by the
//! hub's launcher) loads it, parses the files the hub sends and answers with the chunks, symbols and references; the tree
//! never leaves the process. A crash, a loop or a bad answer costs the worker, never the hub: the file reads as text.
//!
//! The protocol is length-prefixed JSON frames on the worker's stdin and stdout (nothing else: no files beyond the
//! library, no network, no other descriptor): `u32` big-endian length, then the body. The frame reader refuses a length
//! over its cap before it allocates, and a body that ends early is an error, never a short read.
//!
//! Hub to worker: one [`Init`] (the pack's `chunks.scm`, `tags.scm` and doc rules), then [`Request`]s. Worker to hub:
//! [`Reply::Ready`] once the library loaded and the queries built, then one reply per request.
//!
//! The hub side is [`Worker`] (one process, restarted after a failure; three failures in ten minutes and the pack reads as
//! text until the hub restarts) and the process-wide set of fetched packs ([`install`], [`claims`], [`chunk`]). Starting
//! the process is the [`Launch`] trait's: the hub installs a sandboxed one; there is none by default, so without one a
//! fetched pack's files read as text.

use super::{Chunk, Symbol, refs, refs::Ref, registry, ts};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

/// The longest frame either side accepts.
pub const MAX_FRAME: usize = 32 << 20;
/// The longest file text the hub sends (a larger file reads as text).
pub const MAX_TEXT: usize = 4 << 20;
/// How long the worker may take to answer one request (its loop of a scanner is cut by the hub, not by itself).
pub const REQUEST_DEADLINE: Duration = Duration::from_secs(20);
/// How long the worker may take to start: load the library, build the queries.
pub const START_DEADLINE: Duration = Duration::from_secs(20);
/// Failures within [`WINDOW`] after which the pack reads as text.
pub const MAX_FAILURES: usize = 3;
pub const WINDOW: Duration = Duration::from_secs(600);

/// Why a frame could not be read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FrameError {
    /// The announced length is over the cap (nothing was allocated for it).
    Oversized {
        len: usize,
        max: usize,
    },
    /// The stream ended inside a frame.
    Truncated,
    Io(String),
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FrameError::Oversized { len, max } => {
                write!(f, "a frame of {len} bytes, over the cap of {max}")
            }
            FrameError::Truncated => write!(f, "the stream ended inside a frame"),
            FrameError::Io(e) => write!(f, "{e}"),
        }
    }
}

/// BODY as one frame.
pub fn write_frame(w: &mut (impl Write + ?Sized), body: &[u8]) -> io::Result<()> {
    if body.len() > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("a frame of {} bytes, over the cap", body.len()),
        ));
    }
    w.write_all(&(body.len() as u32).to_be_bytes())?;
    w.write_all(body)?;
    w.flush()
}

/// The next frame of R, at most MAX bytes: none at a clean end of stream (before the first byte of a frame). The cap is
/// checked on the announced length, so a hostile length never allocates; the body is read in pieces, so a short stream
/// costs what it sent, not what it announced.
pub fn read_frame(r: &mut (impl Read + ?Sized), max: usize) -> Result<Option<Vec<u8>>, FrameError> {
    let mut head = [0u8; 4];
    let mut got = 0;
    while got < head.len() {
        match r.read(&mut head[got..]) {
            Ok(0) if got == 0 => return Ok(None),
            Ok(0) => return Err(FrameError::Truncated),
            Ok(n) => got += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(FrameError::Io(e.to_string())),
        }
    }
    let len = u32::from_be_bytes(head) as usize;
    if len > max {
        return Err(FrameError::Oversized { len, max });
    }
    let mut body = Vec::with_capacity(len.min(64 << 10));
    let mut piece = [0u8; 16 << 10];
    while body.len() < len {
        let want = (len - body.len()).min(piece.len());
        match r.read(&mut piece[..want]) {
            Ok(0) => return Err(FrameError::Truncated),
            Ok(n) => body.extend_from_slice(&piece[..n]),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(FrameError::Io(e.to_string())),
        }
    }
    Ok(Some(body))
}

/// What the worker needs of the pack besides its library: sent once, first.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Init {
    pub chunks_scm: String,
    #[serde(default)]
    pub tags_scm: Option<String>,
    #[serde(default)]
    pub docs: skald::manifest::Docs,
}

/// Hub to worker, after [`Init`].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
pub enum Request {
    Chunk {
        id: u64,
        path: String,
        generated: bool,
        text: String,
        budget: usize,
    },
}

/// Worker to hub.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
pub enum Reply {
    Ready {
        abi: usize,
    },
    Chunked {
        id: u64,
        chunks: Vec<Chunk>,
        symbols: Vec<Symbol>,
        refs: Vec<Ref>,
    },
    Failed {
        id: u64,
        error: String,
    },
}

fn send<T: Serialize>(w: &mut (impl Write + ?Sized), v: &T) -> io::Result<()> {
    let body = serde_json::to_vec(v).map_err(|e| io::Error::other(e.to_string()))?;
    write_frame(w, &body)
}

/// The worker's side: loads the library at LIB (its hash must be SHA256) as the grammar GRAMMAR, reads [`Init`] from R,
/// builds the queries, says [`Reply::Ready`] on W and answers requests until R ends. Returns the process's exit code
/// (0: the hub closed the stream; 2: the library, the init or a frame was refused; the reason is on stderr).
pub fn serve(
    lib: &Path,
    grammar: &str,
    sha256: &str,
    r: &mut impl Read,
    w: &mut impl Write,
) -> i32 {
    match serve_inner(lib, grammar, sha256, r, w) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("hrafn-parse: {e}");
            2
        }
    }
}

fn serve_inner(
    lib: &Path,
    grammar: &str,
    sha256: &str,
    r: &mut impl Read,
    w: &mut impl Write,
) -> Result<(), String> {
    let got = skald::job::file_sha256(lib).map_err(|e| e.to_string())?;
    if got != sha256 {
        return Err(format!("the library's hash is {got}, not {sha256}"));
    }
    // the library stays loaded for the life of the process: the language, the queries and every tree point into it
    let (_library, language) = skald::job::load(lib, grammar).map_err(|e| e.to_string())?;
    let abi = language.abi_version();
    if abi < skald::registry::MIN_ABI {
        return Err(format!(
            "the grammar's ABI is {abi}, below {}",
            skald::registry::MIN_ABI
        ));
    }
    let init: Init = match read_frame(r, MAX_FRAME).map_err(|e| e.to_string())? {
        Some(b) => serde_json::from_slice(&b).map_err(|e| format!("the init: {e}"))?,
        None => return Ok(()),
    };
    let spec = registry::spec_from(&language, &init.chunks_scm, &init.docs)
        .map_err(|e| format!("chunks.scm: {e}"))?;
    let tags = match &init.tags_scm {
        Some(t) => Some(
            refs::compile_tags(&language, t).ok_or_else(|| "tags.scm does not build".to_owned())?,
        ),
        None => None,
    };
    send(w, &Reply::Ready { abi }).map_err(|e| e.to_string())?;
    while let Some(body) = read_frame(r, MAX_FRAME).map_err(|e| e.to_string())? {
        let request: Request =
            serde_json::from_slice(&body).map_err(|e| format!("a request: {e}"))?;
        let Request::Chunk {
            id,
            path,
            generated,
            text,
            budget,
        } = request;
        let reply = if text.len() > MAX_TEXT {
            Reply::Failed {
                id,
                error: format!("a file of {} bytes, over {MAX_TEXT}", text.len()),
            }
        } else {
            let done = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                ts::chunk_with(
                    None,
                    &spec,
                    &language,
                    tags.as_ref(),
                    &path,
                    generated,
                    &text,
                    budget,
                )
            }));
            match done {
                Ok(Some((chunks, symbols, refs))) => Reply::Chunked {
                    id,
                    chunks,
                    symbols,
                    refs,
                },
                Ok(None) => Reply::Failed {
                    id,
                    error: "the file did not parse".into(),
                },
                Err(_) => Reply::Failed {
                    id,
                    error: "the chunker panicked".into(),
                },
            }
        };
        match send(w, &reply) {
            Ok(()) => {}
            // an answer over the frame cap is this file's failure, not the stream's
            Err(e) if e.kind() == io::ErrorKind::InvalidInput => send(
                w,
                &Reply::Failed {
                    id,
                    error: "the answer is over the frame cap".into(),
                },
            )
            .map_err(|e| e.to_string())?,
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(())
}

/// What the hub gives a launcher to start one worker.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkerSpec {
    pub pack: String,
    pub lib: PathBuf,
    pub grammar: String,
    pub sha256: String,
}

/// A started worker's ends. `kill` ends the process and everything it started; it may be called twice.
pub struct Started {
    pub stdin: Box<dyn Write + Send>,
    pub stdout: Box<dyn Read + Send>,
    pub kill: Box<dyn FnMut() + Send>,
    /// The end of what the process wrote to stderr (a refusal or a fault says why there): added to a failure's reason.
    pub stderr: Box<dyn Fn() -> String + Send>,
}

/// Starts workers. The hub's implementation puts the process under Gleipnir; there is no default.
pub trait Launch: Send + Sync {
    fn start(&self, spec: &WorkerSpec) -> Result<Started, String>;
}

/// A file's chunks, symbols and references.
pub type Chunked = (Vec<Chunk>, Vec<Symbol>, Vec<Ref>);

/// Why a file was not chunked by the worker.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WorkerError {
    /// The pack reads as text (until the hub restarts): the reason, said once.
    Dead(String),
    /// This file only: it reads as text.
    File(String),
}

impl std::fmt::Display for WorkerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WorkerError::Dead(e) | WorkerError::File(e) => write!(f, "{e}"),
        }
    }
}

struct Live {
    stdin: Box<dyn Write + Send>,
    replies: mpsc::Receiver<Result<Vec<u8>, FrameError>>,
    kill: Box<dyn FnMut() + Send>,
    stderr: Box<dyn Fn() -> String + Send>,
}

impl Live {
    fn end(&mut self) {
        (self.kill)();
    }

    /// WHY with the last lines of the process's stderr, when it said any.
    fn because(&self, why: String) -> String {
        let tail = (self.stderr)();
        let lines: Vec<&str> = tail.lines().filter(|l| !l.trim().is_empty()).collect();
        let last = lines[lines.len().saturating_sub(3)..].join(" / ");
        if last.is_empty() {
            why
        } else {
            format!(
                "{why} (it said: {})",
                last.chars().take(400).collect::<String>()
            )
        }
    }
}

/// One pack's worker: started on first use, restarted after a failure.
pub struct Worker {
    spec: WorkerSpec,
    init: Init,
    launch: Arc<dyn Launch>,
    live: Option<Live>,
    failures: VecDeque<Instant>,
    dead: Option<String>,
    next_id: u64,
    pub request_deadline: Duration,
    pub start_deadline: Duration,
}

impl Worker {
    pub fn new(spec: WorkerSpec, init: Init, launch: Arc<dyn Launch>) -> Worker {
        Worker {
            spec,
            init,
            launch,
            live: None,
            failures: VecDeque::new(),
            dead: None,
            next_id: 1,
            request_deadline: REQUEST_DEADLINE,
            start_deadline: START_DEADLINE,
        }
    }

    /// Why the pack reads as text, once it does.
    pub fn dead(&self) -> Option<&str> {
        self.dead.as_deref()
    }

    /// Whether a process is running.
    pub fn running(&self) -> bool {
        self.live.is_some()
    }

    fn fail(&mut self, why: String) -> WorkerError {
        let mut why = why;
        if let Some(mut l) = self.live.take() {
            why = l.because(why);
            l.end();
        }
        let now = Instant::now();
        self.failures.push_back(now);
        while self
            .failures
            .front()
            .is_some_and(|t| now.duration_since(*t) > WINDOW)
        {
            self.failures.pop_front();
        }
        if self.failures.len() >= MAX_FAILURES {
            let why = format!(
                "the worker failed {MAX_FAILURES} times in {} minutes (last: {why})",
                WINDOW.as_secs() / 60
            );
            self.dead = Some(why.clone());
            return WorkerError::Dead(why);
        }
        WorkerError::File(why)
    }

    fn ensure(&mut self) -> Result<(), WorkerError> {
        if let Some(d) = &self.dead {
            return Err(WorkerError::Dead(d.clone()));
        }
        if self.live.is_some() {
            return Ok(());
        }
        let started = match self.launch.start(&self.spec) {
            Ok(s) => s,
            // a launcher that cannot start (the reduced tier, no sandbox) is final: nothing here runs unconfined
            Err(e) => {
                self.dead = Some(e.clone());
                return Err(WorkerError::Dead(e));
            }
        };
        let (tx, rx) = mpsc::channel();
        let mut stdout = started.stdout;
        std::thread::Builder::new()
            .name("hrafn-parse-reader".into())
            .spawn(move || {
                loop {
                    match read_frame(&mut stdout, MAX_FRAME) {
                        Ok(Some(b)) => {
                            if tx.send(Ok(b)).is_err() {
                                return;
                            }
                        }
                        Ok(None) => {
                            let _ = tx.send(Err(FrameError::Truncated));
                            return;
                        }
                        Err(e) => {
                            let _ = tx.send(Err(e));
                            return;
                        }
                    }
                }
            })
            .map_err(|e| WorkerError::File(e.to_string()))?;
        let mut live = Live {
            stdin: started.stdin,
            replies: rx,
            kill: started.kill,
            stderr: started.stderr,
        };
        let init = serde_json::to_vec(&self.init).map_err(|e| WorkerError::File(e.to_string()))?;
        if let Err(e) = write_frame(&mut live.stdin, &init) {
            let why = live.because(format!("the worker did not take its init: {e}"));
            live.end();
            return Err(self.fail(why));
        }
        match live.replies.recv_timeout(self.start_deadline) {
            Ok(Ok(b)) => match serde_json::from_slice::<Reply>(&b) {
                Ok(Reply::Ready { .. }) => {
                    self.live = Some(live);
                    Ok(())
                }
                Ok(other) => {
                    let why = live.because(format!("the worker's first word was {other:?}"));
                    live.end();
                    Err(self.fail(why))
                }
                Err(e) => {
                    let why = live.because(format!("the worker's first word did not read: {e}"));
                    live.end();
                    Err(self.fail(why))
                }
            },
            Ok(Err(e)) => {
                let why = live.because(format!("the worker did not start: {e}"));
                live.end();
                Err(self.fail(why))
            }
            Err(_) => {
                let why = live.because(format!(
                    "the worker did not start within {} s",
                    self.start_deadline.as_secs()
                ));
                live.end();
                Err(self.fail(why))
            }
        }
    }

    /// TEXT of PATH chunked by the pack's grammar in the worker.
    pub fn chunk(
        &mut self,
        path: &str,
        generated: bool,
        text: &str,
        budget: usize,
    ) -> Result<Chunked, WorkerError> {
        if text.len() > MAX_TEXT {
            return Err(WorkerError::File(format!(
                "a file of {} bytes, over {MAX_TEXT}",
                text.len()
            )));
        }
        self.ensure()?;
        let id = self.next_id;
        self.next_id += 1;
        let request = Request::Chunk {
            id,
            path: path.to_owned(),
            generated,
            text: text.to_owned(),
            budget,
        };
        let body = serde_json::to_vec(&request).map_err(|e| WorkerError::File(e.to_string()))?;
        let live = self.live.as_mut().expect("ensure started it");
        if let Err(e) = write_frame(&mut live.stdin, &body) {
            return Err(self.fail(format!("the worker did not take a request: {e}")));
        }
        let live = self.live.as_mut().expect("still running");
        match live.replies.recv_timeout(self.request_deadline) {
            Ok(Ok(b)) => match serde_json::from_slice::<Reply>(&b) {
                Ok(Reply::Chunked {
                    id: got,
                    chunks,
                    symbols,
                    refs,
                }) if got == id => {
                    check(text, &chunks, &symbols).map_err(|e| self.fail(e))?;
                    Ok((chunks, symbols, refs))
                }
                // this file failed, the worker is fine
                Ok(Reply::Failed { id: got, error }) if got == id => Err(WorkerError::File(error)),
                Ok(other) => Err(self.fail(format!("an answer out of turn: {other:?}"))),
                Err(e) => Err(self.fail(format!("an answer that does not read: {e}"))),
            },
            Ok(Err(e)) => Err(self.fail(format!("the worker's stream: {e}"))),
            Err(_) => Err(self.fail(format!(
                "no answer within {} s: the worker was killed",
                self.request_deadline.as_secs()
            ))),
        }
    }

    /// Ends the process (the hub is going away, or the pack was removed).
    pub fn stop(&mut self) {
        if let Some(mut l) = self.live.take() {
            l.end();
        }
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        self.stop();
    }
}

/// What the hub does not take on trust from a worker: the chunks lie inside the text, on character boundaries, in order,
/// and the symbols point at chunks that exist. The index stores these offsets and slices the file with them.
fn check(text: &str, chunks: &[Chunk], symbols: &[Symbol]) -> Result<(), String> {
    if chunks.len() > text.len().max(1) {
        return Err("more chunks than bytes".into());
    }
    let mut at = 0usize;
    for c in chunks {
        let (s, e) = (c.start as usize, c.end as usize);
        if s < at
            || s > e
            || e > text.len()
            || !text.is_char_boundary(s)
            || !text.is_char_boundary(e)
        {
            return Err(format!("a chunk {s}..{e} outside the file or out of order"));
        }
        at = e;
    }
    for s in symbols {
        if s.chunk as usize >= chunks.len() {
            return Err("a symbol of a chunk that does not exist".into());
        }
        if s.start > s.end || s.end as usize > text.len() {
            return Err("a symbol outside the file".into());
        }
    }
    Ok(())
}

/// A fetched pack the hub chunks through a worker.
pub struct Fetched {
    pub spec: WorkerSpec,
    pub init: Init,
    /// Extensions (no dot) its files have.
    pub extensions: Vec<String>,
}

struct Entry {
    pack: String,
    extensions: Vec<String>,
    /// What the pack's results depend on: its library's hash, extensions and queries.
    digest: String,
    worker: Mutex<Worker>,
}

static PACKS: Mutex<Vec<Arc<Entry>>> = Mutex::new(Vec::new());

/// The fetched packs the hub chunks (replacing the earlier set, whose workers end), each started on first use by LAUNCH.
pub fn install(packs: Vec<Fetched>, launch: Arc<dyn Launch>) {
    let entries: Vec<Arc<Entry>> = packs
        .into_iter()
        .map(|f| {
            use sha2::{Digest, Sha256};
            let mut h = Sha256::new();
            for part in [
                f.spec.pack.as_str(),
                f.spec.sha256.as_str(),
                &f.extensions.join(","),
                &f.init.chunks_scm,
                f.init.tags_scm.as_deref().unwrap_or(""),
                &serde_json::to_string(&f.init.docs).unwrap_or_default(),
            ] {
                h.update(part.as_bytes());
                h.update([0]);
            }
            let digest = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
            Arc::new(Entry {
                pack: f.spec.pack.clone(),
                extensions: f.extensions,
                digest,
                worker: Mutex::new(Worker::new(f.spec, f.init, launch.clone())),
            })
        })
        .collect();
    let old = std::mem::replace(
        &mut *PACKS.lock().unwrap_or_else(PoisonError::into_inner),
        entries,
    );
    drop(old);
}

/// A string that changes when the set of fetched packs, or any pack's library or queries, does: part of the language
/// stamp, so the index parses a project's files again when a pack is installed, updated or removed.
pub fn stamp_part() -> String {
    PACKS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .map(|e| format!("{}={}", e.pack, e.digest))
        .collect::<Vec<_>>()
        .join(";")
}

/// The fetched pack whose files have PATH's extension.
pub fn claims(path: &str) -> Option<String> {
    let ext = path.rsplit('/').next()?.rsplit_once('.')?.1;
    PACKS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .find(|e| e.extensions.iter().any(|x| x == ext))
        .map(|e| e.pack.clone())
}

/// PATH's file chunked by PACK's worker; none when the pack reads as text or the file did not chunk (the reason is
/// returned for the log: `Err`).
pub fn chunk(
    pack: &str,
    path: &str,
    generated: bool,
    text: &str,
    budget: usize,
) -> Result<Chunked, WorkerError> {
    let entry = PACKS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .find(|e| e.pack == pack)
        .cloned()
        .ok_or_else(|| WorkerError::Dead(format!("pack {pack} is not installed")))?;
    let mut w = entry.worker.lock().unwrap_or_else(PoisonError::into_inner);
    w.chunk(path, generated, text, budget)
}

/// (pack, reason) of each fetched pack that reads as text now: what the doctor prints.
pub fn dead() -> Vec<(String, String)> {
    PACKS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .filter_map(|e| {
            let w = e.worker.lock().unwrap_or_else(PoisonError::into_inner);
            w.dead().map(|d| (e.pack.clone(), d.to_owned()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(body: &[u8]) -> Vec<u8> {
        let mut v = (body.len() as u32).to_be_bytes().to_vec();
        v.extend_from_slice(body);
        v
    }

    #[test]
    fn a_frame_round_trips_and_a_clean_end_is_none() {
        let mut bytes = frame(b"one");
        bytes.extend(frame(b""));
        let mut r = &bytes[..];
        assert_eq!(read_frame(&mut r, 100), Ok(Some(b"one".to_vec())));
        assert_eq!(read_frame(&mut r, 100), Ok(Some(Vec::new())));
        assert_eq!(read_frame(&mut r, 100), Ok(None));
    }

    #[test]
    fn a_length_over_the_cap_is_refused_before_anything_is_allocated() {
        // a hostile 4 GiB length with no body: refused on the length alone
        let mut r = &[0xff, 0xff, 0xff, 0xff][..];
        assert_eq!(
            read_frame(&mut r, MAX_FRAME),
            Err(FrameError::Oversized {
                len: u32::MAX as usize,
                max: MAX_FRAME
            })
        );
        let mut r = &frame(&[0u8; 11])[..];
        assert!(matches!(
            read_frame(&mut r, 10),
            Err(FrameError::Oversized { len: 11, max: 10 })
        ));
    }

    #[test]
    fn a_stream_that_ends_inside_a_frame_is_truncated_never_a_short_read() {
        for cut in [1, 2, 3, 5, 9] {
            let full = frame(b"0123456789");
            let mut r = &full[..cut];
            assert_eq!(read_frame(&mut r, 100), Err(FrameError::Truncated), "{cut}");
        }
    }

    /// A reader that gives one byte at a time (a pipe may).
    struct Trickle<'a>(&'a [u8]);
    impl Read for Trickle<'_> {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if self.0.is_empty() || buf.is_empty() {
                return Ok(0);
            }
            buf[0] = self.0[0];
            self.0 = &self.0[1..];
            Ok(1)
        }
    }

    #[test]
    fn a_frame_arriving_a_byte_at_a_time_reads_whole() {
        let bytes = frame(b"hello world");
        assert_eq!(
            read_frame(&mut Trickle(&bytes), 100),
            Ok(Some(b"hello world".to_vec()))
        );
    }

    /// Whatever the bytes, the reader returns (a frame, none or an error), never panics, and never keeps more than it
    /// was sent plus its piece buffer.
    #[test]
    fn fuzzed_streams_never_panic_or_over_allocate() {
        let mut state = 0x9e37_79b9_7f4a_7c15_u64;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        for round in 0..4000 {
            let n = (next() % 64) as usize;
            let mut bytes: Vec<u8> = (0..n).map(|_| next() as u8).collect();
            // half the rounds start with a plausible small length so bodies get exercised
            if round % 2 == 0 && bytes.len() >= 4 {
                let len = (next() % 40) as u32;
                bytes[..4].copy_from_slice(&len.to_be_bytes());
            }
            let mut r = &bytes[..];
            let mut frames = 0;
            while let Ok(Some(f)) = read_frame(&mut r, 1 << 10) {
                assert!(f.len() <= bytes.len());
                frames += 1;
                assert!(frames <= bytes.len());
            }
        }
    }

    #[test]
    fn the_hub_does_not_take_a_workers_offsets_on_trust() {
        let text = "héllo";
        let chunk = |s: u32, e: u32| Chunk {
            start: s,
            end: e,
            line_start: 1,
            line_end: 1,
            symbol: None,
            header: String::new(),
            embed_text: String::new(),
            fts: super::super::FtsCols::default(),
            embed: false,
        };
        assert!(check(text, &[chunk(0, 6)], &[]).is_ok());
        // past the end, inside a multi-byte character, backwards, overlapping
        assert!(check(text, &[chunk(0, 7)], &[]).is_err());
        assert!(check(text, &[chunk(0, 2)], &[]).is_err());
        assert!(check(text, &[chunk(3, 2)], &[]).is_err());
        assert!(check(text, &[chunk(0, 3), chunk(2, 6)], &[]).is_err());
    }

    // ---- the hub side against hostile or broken workers (no process: two pipes and a thread) ----

    use std::sync::atomic::{AtomicUsize, Ordering};

    type Script = dyn Fn(&mut dyn Read, &mut dyn Write) + Send + Sync;

    /// A launcher whose "worker" is SCRIPT on the far ends of two pipes; `kills` counts how often the hub ended it.
    struct Stub {
        script: Arc<Script>,
        starts: Arc<AtomicUsize>,
        kills: Arc<AtomicUsize>,
    }

    impl Launch for Stub {
        fn start(&self, _: &WorkerSpec) -> Result<Started, String> {
            self.starts.fetch_add(1, Ordering::SeqCst);
            let (req_r, req_w) = io::pipe().map_err(|e| e.to_string())?;
            let (rep_r, rep_w) = io::pipe().map_err(|e| e.to_string())?;
            let script = self.script.clone();
            std::thread::spawn(move || {
                let (mut r, mut w) = (req_r, rep_w);
                script(&mut r, &mut w);
            });
            let kills = self.kills.clone();
            Ok(Started {
                stdin: Box::new(req_w),
                stdout: Box::new(rep_r),
                kill: Box::new(move || {
                    kills.fetch_add(1, Ordering::SeqCst);
                }),
                stderr: Box::new(String::new),
            })
        }
    }

    fn worker_with(
        script: impl Fn(&mut dyn Read, &mut dyn Write) + Send + Sync + 'static,
    ) -> (Worker, Arc<AtomicUsize>, Arc<AtomicUsize>) {
        let (starts, kills) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
        let launch = Arc::new(Stub {
            script: Arc::new(script),
            starts: starts.clone(),
            kills: kills.clone(),
        });
        let spec = WorkerSpec {
            pack: "fixture".into(),
            lib: "/nowhere.so".into(),
            grammar: "fixture".into(),
            sha256: "0".repeat(64),
        };
        let init = Init {
            chunks_scm: String::new(),
            tags_scm: None,
            docs: skald::manifest::Docs::default(),
        };
        let mut w = Worker::new(spec, init, launch);
        // a worker that never answers is cut at this deadline: short, so the test is (the only real wait here)
        w.request_deadline = Duration::from_millis(150);
        w.start_deadline = Duration::from_millis(150);
        (w, starts, kills)
    }

    /// The worker's part up to [`Reply::Ready`]: reads the init, says ready.
    fn ready(r: &mut dyn Read, w: &mut dyn Write) -> bool {
        if read_frame(r, MAX_FRAME).ok().flatten().is_none() {
            return false;
        }
        send(w, &Reply::Ready { abi: 15 }).is_ok()
    }

    fn id_of(r: &mut dyn Read) -> Option<u64> {
        let body = read_frame(r, MAX_FRAME).ok()??;
        match serde_json::from_slice::<Request>(&body).ok()? {
            Request::Chunk { id, .. } => Some(id),
        }
    }

    #[test]
    fn a_worker_that_answers_is_used_again_and_a_failed_file_costs_only_the_file() {
        let (mut w, starts, kills) = worker_with(|r, wr| {
            if !ready(r, wr) {
                return;
            }
            while let Some(id) = id_of(r) {
                let reply = if id == 1 {
                    Reply::Failed {
                        id,
                        error: "the file did not parse".into(),
                    }
                } else {
                    Reply::Chunked {
                        id,
                        chunks: vec![],
                        symbols: vec![],
                        refs: vec![],
                    }
                };
                if send(wr, &reply).is_err() {
                    return;
                }
            }
        });
        assert_eq!(
            w.chunk("a.x", false, "text", 100),
            Err(WorkerError::File("the file did not parse".into()))
        );
        assert!(w.chunk("b.x", false, "", 100).is_ok());
        assert!(w.chunk("c.x", false, "", 100).is_ok());
        // one process served all three; nothing was killed; the pack is not dead
        assert_eq!(
            (starts.load(Ordering::SeqCst), kills.load(Ordering::SeqCst)),
            (1, 0)
        );
        assert!(w.dead().is_none());
    }

    /// Each of these workers is broken in its own way on the first request: the hub reports this file as failed, ends the
    /// process, and the next file gets a fresh one. None may hang the caller.
    #[test]
    fn a_broken_worker_fails_the_file_ends_the_process_and_the_next_file_starts_another() {
        type Break = fn(&mut dyn Write);
        let breaks: Vec<(&str, Break)> = vec![
            ("an oversized frame", |w| {
                let _ = w.write_all(&[0xff, 0xff, 0xff, 0xff]);
            }),
            ("a frame that stops short", |w| {
                let _ = w.write_all(&[0, 0, 0, 100, b'x', b'y']);
            }),
            ("a frame that is not JSON", |w| {
                let _ = write_frame(w, b"not json at all");
            }),
            ("an answer of another id", |w| {
                let _ = send(
                    w,
                    &Reply::Chunked {
                        id: 999,
                        chunks: vec![],
                        symbols: vec![],
                        refs: vec![],
                    },
                );
            }),
            ("a chunk outside the file", |w| {
                let _ = send(
                    w,
                    &Reply::Chunked {
                        id: 1,
                        chunks: vec![Chunk {
                            start: 0,
                            end: 9999,
                            line_start: 1,
                            line_end: 1,
                            symbol: None,
                            header: String::new(),
                            embed_text: String::new(),
                            fts: super::super::FtsCols::default(),
                            embed: false,
                        }],
                        symbols: vec![],
                        refs: vec![],
                    },
                );
            }),
            ("a reply that is the wrong kind", |w| {
                let _ = send(w, &Reply::Ready { abi: 15 });
            }),
        ];
        for (what, brk) in breaks {
            let (mut w, starts, kills) = worker_with(move |r, wr| {
                if !ready(r, wr) {
                    return;
                }
                if id_of(r).is_some() {
                    brk(wr);
                }
                // then it just stays up: only the hub's kill ends it (the pipe closes with the thread)
            });
            let e = w.chunk("a.x", false, "text", 100).unwrap_err();
            assert!(matches!(e, WorkerError::File(_)), "{what}: {e:?}");
            assert_eq!(
                kills.load(Ordering::SeqCst),
                1,
                "{what}: the process is ended"
            );
            assert!(!w.running(), "{what}");
            // the next file starts a new one (and fails the same way: this is about the restart)
            let _ = w.chunk("b.x", false, "text", 100);
            assert_eq!(starts.load(Ordering::SeqCst), 2, "{what}");
        }
    }

    #[test]
    fn a_worker_that_never_answers_is_cut_at_the_deadline_never_waited_for() {
        let (mut w, _, kills) = worker_with(|r, wr| {
            if !ready(r, wr) {
                return;
            }
            // reads its requests and says nothing, until the hub closes the pipe
            while read_frame(r, MAX_FRAME).ok().flatten().is_some() {}
        });
        let t = Instant::now();
        let e = w.chunk("a.x", false, "text", 100).unwrap_err();
        assert!(
            matches!(&e, WorkerError::File(m) if m.contains("no answer")),
            "{e:?}"
        );
        assert!(t.elapsed() < Duration::from_secs(5));
        assert_eq!(kills.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_worker_that_never_says_ready_is_cut_at_the_start_deadline() {
        let (mut w, _, kills) =
            worker_with(
                |r, _| {
                    while read_frame(r, MAX_FRAME).ok().flatten().is_some() {}
                },
            );
        let e = w.chunk("a.x", false, "text", 100).unwrap_err();
        assert!(
            matches!(&e, WorkerError::File(m) if m.contains("did not start")),
            "{e:?}"
        );
        assert_eq!(kills.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn three_failures_make_the_pack_text_and_it_is_not_started_again() {
        let (mut w, starts, _) = worker_with(|r, _| {
            // exits at once: the hub's init write or its wait fails
            let _ = read_frame(r, MAX_FRAME);
        });
        for _ in 0..2 {
            assert!(matches!(
                w.chunk("a.x", false, "text", 100),
                Err(WorkerError::File(_))
            ));
        }
        assert!(matches!(
            w.chunk("a.x", false, "text", 100),
            Err(WorkerError::Dead(_))
        ));
        assert!(w.dead().is_some());
        let n = starts.load(Ordering::SeqCst);
        // dead stays dead: no start, no wait
        for _ in 0..5 {
            assert!(matches!(
                w.chunk("a.x", false, "text", 100),
                Err(WorkerError::Dead(_))
            ));
        }
        assert_eq!(starts.load(Ordering::SeqCst), n);
    }

    #[test]
    fn a_launcher_that_cannot_start_a_worker_makes_the_pack_text_at_once() {
        struct Refuses;
        impl Launch for Refuses {
            fn start(&self, _: &WorkerSpec) -> Result<Started, String> {
                Err("the sandbox is on its reduced tier".into())
            }
        }
        let spec = WorkerSpec {
            pack: "fixture".into(),
            lib: "/x".into(),
            grammar: "g".into(),
            sha256: String::new(),
        };
        let init = Init {
            chunks_scm: String::new(),
            tags_scm: None,
            docs: skald::manifest::Docs::default(),
        };
        let mut w = Worker::new(spec, init, Arc::new(Refuses));
        let e = w.chunk("a.x", false, "t", 10).unwrap_err();
        assert_eq!(
            e,
            WorkerError::Dead("the sandbox is on its reduced tier".into())
        );
        assert!(w.dead().is_some());
    }

    #[test]
    fn a_file_over_the_text_cap_never_reaches_the_worker() {
        let (mut w, starts, _) = worker_with(|r, wr| {
            ready(r, wr);
        });
        let big = "x".repeat(MAX_TEXT + 1);
        assert!(matches!(
            w.chunk("a.x", false, &big, 100),
            Err(WorkerError::File(_))
        ));
        assert_eq!(starts.load(Ordering::SeqCst), 0);
    }
}
