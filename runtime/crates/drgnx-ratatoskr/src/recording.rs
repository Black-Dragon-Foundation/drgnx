//! Recording a run, and replaying one (docs/develop/recordings.md).
//!
//! `DRGNX_RECORD=DIR` or `DRGNX_REPLAY=DIR` in `serve`'s environment; both at once is refused at start, and so is a
//! replay of a directory that is not a recording this hub reads.  No Lisp setting turns either on: a recording is one
//! run on a fresh state root, never the daily hub.
//!
//! - **Record:** a [`Recorder`] (the run's clock, one `seq` counter, one writer thread, the scrubber) becomes the
//!   gateway's tap: each attempt is one `llm.jsonl` line, written and flushed when it ends.  Provider keys are scrubbed
//!   inside bifrost (`Keys::scrub`); each gateway token is told to the recorder when it is issued ([`secret`]); the
//!   patterns and the header allowlist are `runstav::recording`'s.  `DRGNX_RECORD_PROVENANCE` (`mock` or `live`,
//!   default `live`) says what made the run: only a `mock` one may become a repository fixture.
//! - **Replay:** one `ratatoskr-mock llm --replay DIR` (beside this binary, or `RATATOSKR_MOCK`) is started with
//!   `--parent` this hub, and every provider's base becomes `/p/ID` on it, keyless ([`replayed`]): the hub runs for
//!   real, only the provider end is the recording.  Misses go to `$DRGNX_RUN_TMP/replay/misses.jsonl` (else
//!   `$TMPDIR/replay/`); `DRGNX_REPLAY_SPEED` paces the chunks (default 0: no waits).

use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Instant;

use bifrost::engine::{End, Exchange, Sent, Tap};
use runstav::methods::hub::{RecordingMode, RecordingStatus};
use runstav::paths::Env;
use runstav::recording::{self as rec, Roots, Scrub};
use serde_json::{Map, Value, json};

/// What this hub does with its run.
enum Mode {
    Record(Arc<Recorder>),
    Replay { dir: PathBuf, port: u16 },
}

static MODE: OnceLock<Mode> = OnceLock::new();

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn var<'a>(env: &'a Env, name: &str) -> Option<&'a str> {
    env.vars
        .get(name)
        .map(String::as_str)
        .filter(|v| !v.is_empty())
}

/// At start: what ENV asks for, set up (the recorder, or the replayer started).  Err: the hub does not start.
pub async fn start(env: &Env) -> Result<(), String> {
    match (var(env, "DRGNX_RECORD"), var(env, "DRGNX_REPLAY")) {
        (Some(_), Some(_)) => Err(
            "DRGNX_RECORD and DRGNX_REPLAY cannot both be set: a run is recorded or replayed"
                .into(),
        ),
        (Some(dir), None) => {
            let provenance = var(env, "DRGNX_RECORD_PROVENANCE").unwrap_or("live");
            if !matches!(provenance, "mock" | "live") {
                return Err(format!(
                    "DRGNX_RECORD_PROVENANCE is {provenance:?}: mock or live"
                ));
            }
            let r = Recorder::start(Path::new(dir), Roots::of_env(env), provenance)?;
            tracing::info!(dir, provenance, "recording this run (DRGNX_RECORD)");
            let _ = MODE.set(Mode::Record(r));
            Ok(())
        }
        (None, Some(dir)) => {
            let dir = PathBuf::from(dir);
            rec::read_manifest(&dir)?;
            let (d, e) = (dir.clone(), env.clone());
            let port = crate::clock::blocking(move || replayer(&d, &e))
                .await
                .map_err(|e| format!("the replayer did not start: {e}"))??;
            tracing::info!(dir = %dir.display(), port, "replaying a recorded run (DRGNX_REPLAY)");
            let _ = MODE.set(Mode::Replay { dir, port });
            Ok(())
        }
        (None, None) => Ok(()),
    }
}

/// `status`'s `recording`, when this run records or replays.
pub fn status() -> Option<RecordingStatus> {
    MODE.get().map(|m| match m {
        Mode::Record(r) => RecordingStatus {
            mode: RecordingMode::Record,
            dir: r.dir.to_string_lossy().into_owned(),
        },
        Mode::Replay { dir, .. } => RecordingStatus {
            mode: RecordingMode::Replay,
            dir: dir.to_string_lossy().into_owned(),
        },
    })
}

/// The gateway's tap, while recording.
pub fn tap() -> Option<Arc<Recorder>> {
    match MODE.get() {
        Some(Mode::Record(r)) => Some(r.clone()),
        _ => None,
    }
}

/// A secret the hub issued (a gateway token): never written into the recording.
pub fn secret(s: &str) {
    if let Some(Mode::Record(r)) = MODE.get() {
        lock(&r.scrub).add(s);
    }
}

/// While replaying, provider ID's base on the replayer, keyless; else none (the provider as configured).
pub fn replayed(id: &str) -> Option<(bifrost::Uri, bifrost::Auth)> {
    match MODE.get() {
        Some(Mode::Replay { port, .. }) => format!("http://127.0.0.1:{port}/p/{id}")
            .parse()
            .ok()
            .map(|u| (u, bifrost::Auth::None)),
        _ => None,
    }
}

/// Start `ratatoskr-mock llm --replay DIR` and read its port.
fn replayer(dir: &Path, env: &Env) -> Result<u16, String> {
    let mock = var(env, "RATATOSKR_MOCK")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::current_exe()
                .ok()?
                .parent()
                .map(|p| p.join("ratatoskr-mock"))
        })
        .filter(|p| p.is_file())
        .ok_or("no ratatoskr-mock beside this binary (or at RATATOSKR_MOCK) to replay with")?;
    let scratch = PathBuf::from(
        var(env, "DRGNX_RUN_TMP")
            .or_else(|| var(env, "TMPDIR"))
            .unwrap_or("/tmp"),
    )
    .join("replay");
    std::fs::create_dir_all(&scratch)
        .map_err(|e| format!("cannot make {}: {e}", scratch.display()))?;
    let speed = var(env, "DRGNX_REPLAY_SPEED").unwrap_or("0");
    let mut child = std::process::Command::new(&mock)
        .arg("llm")
        .arg("--replay")
        .arg(dir)
        .arg("--speed")
        .arg(speed)
        .arg("--misses")
        .arg(scratch.join("misses.jsonl"))
        .arg("--parent")
        .arg(std::process::id().to_string())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot run {}: {e}", mock.display()))?;
    let mut line = String::new();
    let out = child.stdout.take().ok_or("the replayer has no stdout")?;
    BufReader::new(out)
        .read_line(&mut line)
        .map_err(|e| format!("the replayer said nothing: {e}"))?;
    let port = line
        .trim()
        .strip_prefix("MOCK-LLM-PORT ")
        .and_then(|p| p.parse().ok());
    match port {
        Some(p) => {
            // it ends with this hub (`--parent`); its status is read when it does, so it leaves no zombie
            std::thread::spawn(move || {
                let _ = child.wait();
            });
            Ok(p)
        }
        None => {
            let _ = child.kill();
            let _ = child.wait();
            Err(format!("the replayer said {:?}, not its port", line.trim()))
        }
    }
}

// ------------------------------------------------------------------------------------------ the recorder

/// One run's recorder: its clock, its `seq`, the writer thread and the scrubber.
pub struct Recorder {
    dir: PathBuf,
    started: Instant,
    seq: AtomicU64,
    exchanges: AtomicU64,
    scrub: Mutex<Scrub>,
    roots: Roots,
    lines: Mutex<mpsc::Sender<(&'static str, String)>>,
}

impl Recorder {
    /// A new run in DIR (made; one that holds a recording already is refused): its manifest, then the writer.
    fn start(dir: &Path, roots: Roots, provenance: &str) -> Result<Arc<Recorder>, String> {
        if dir.join("manifest.json").exists() {
            return Err(format!(
                "{} holds a recording already: record into a new directory",
                dir.display()
            ));
        }
        std::fs::create_dir_all(dir).map_err(|e| format!("cannot make {}: {e}", dir.display()))?;
        let build = if cfg!(feature = "test-hooks") {
            "test"
        } else {
            "release"
        };
        let started = crate::log::rfc3339(crate::clock::wall_secs() as u64);
        let manifest = rec::manifest(provenance, &started, crate::version::COMMIT, build, &roots);
        let text = serde_json::to_string_pretty(&manifest).map_err(|e| e.to_string())?;
        std::fs::write(dir.join("manifest.json"), text + "\n")
            .map_err(|e| format!("cannot write {}/manifest.json: {e}", dir.display()))?;
        let (tx, rx) = mpsc::channel::<(&'static str, String)>();
        let into = dir.to_path_buf();
        std::thread::Builder::new()
            .name("recording".into())
            .spawn(move || write_lines(&into, &rx))
            .map_err(|e| format!("no writer thread: {e}"))?;
        Ok(Arc::new(Recorder {
            dir: dir.to_path_buf(),
            started: crate::clock::real_now(),
            seq: AtomicU64::new(0),
            exchanges: AtomicU64::new(0),
            scrub: Mutex::new(Scrub::default()),
            roots,
            lines: Mutex::new(tx),
        }))
    }

    fn t_ms(&self, at: Instant) -> u64 {
        u64::try_from(at.saturating_duration_since(self.started).as_millis()).unwrap_or(u64::MAX)
    }
}

/// The writer thread: each line appended to its stream and flushed, so a killed run leaves a usable prefix.
fn write_lines(dir: &Path, rx: &mpsc::Receiver<(&'static str, String)>) {
    let mut files: HashMap<&'static str, File> = HashMap::new();
    for (stream, line) in rx {
        if !files.contains_key(stream) {
            match std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join(stream))
            {
                Ok(f) => {
                    files.insert(stream, f);
                }
                Err(e) => {
                    tracing::error!(stream, "the recording cannot write: {e}");
                    continue;
                }
            }
        }
        if let Some(f) = files.get_mut(stream)
            && let Err(e) = f
                .write_all(line.as_bytes())
                .and_then(|()| f.write_all(b"\n"))
                .and_then(|()| f.flush())
        {
            tracing::error!(stream, "the recording cannot write: {e}");
        }
    }
}

/// Bytes stored scrubbed: text through the scrub, else as base64 (no pattern can be read in them).
fn stored(scrub: &Scrub, bytes: &[u8]) -> Value {
    match std::str::from_utf8(bytes) {
        Ok(s) => json!(scrub.text(s)),
        Err(_) => rec::body_value(bytes),
    }
}

impl Tap for Recorder {
    fn begin(&self, sent: Sent<'_>) -> Box<dyn Exchange> {
        let scrub = lock(&self.scrub).clone();
        let seq = self.seq.fetch_add(1, Ordering::Relaxed) + 1;
        let id = self.exchanges.fetch_add(1, Ordering::Relaxed) + 1;
        let body = stored(&scrub, sent.body);
        let text = body.as_str().unwrap_or_default();
        let model = serde_json::from_str::<Value>(text)
            .ok()
            .and_then(|v| v.get("model").cloned())
            .unwrap_or(Value::Null);
        let mut line = Map::new();
        line.insert("seq".into(), json!(seq));
        line.insert("t_ms".into(), json!(self.t_ms(sent.at)));
        line.insert("id".into(), json!(format!("x{id}")));
        if let Some(s) = sent.session {
            line.insert("session".into(), json!(s));
        }
        line.insert("provider".into(), json!(sent.provider));
        line.insert("model".into(), model);
        line.insert("path".into(), json!(sent.path));
        line.insert("attempt".into(), json!(sent.attempt));
        line.insert("of".into(), json!(sent.of));
        line.insert(
            "key".into(),
            json!(rec::key(sent.provider, sent.path, text, &self.roots)),
        );
        let headers = scrub.headers(sent.headers.iter().map(|(n, v)| (n.as_str(), v.as_str())));
        line.insert("request".into(), json!({"headers": headers, "body": body}));
        if let Some(c) = sent.client {
            line.insert("client".into(), json!({"body": stored(&scrub, c)}));
        }
        Box::new(Line {
            line,
            response: Map::new(),
            chunks: Vec::new(),
            begun: sent.at,
            last: sent.at,
            scrub,
            lines: lock(&self.lines).clone(),
            written: false,
        })
    }
}

/// One attempt's line, written when it ends (or, never ended, when the hub drops it: no `end`).
struct Line {
    line: Map<String, Value>,
    response: Map<String, Value>,
    chunks: Vec<Value>,
    begun: Instant,
    last: Instant,
    scrub: Scrub,
    lines: mpsc::Sender<(&'static str, String)>,
    written: bool,
}

fn ms(from: Instant, to: Instant) -> u64 {
    u64::try_from(to.saturating_duration_since(from).as_millis()).unwrap_or(u64::MAX)
}

impl Line {
    fn write(&mut self, end: Option<Value>) {
        if self.written {
            return;
        }
        self.written = true;
        let mut response = std::mem::take(&mut self.response);
        response.entry("status").or_insert(json!(0));
        response.insert(
            "chunks".into(),
            Value::Array(std::mem::take(&mut self.chunks)),
        );
        if let Some(end) = end {
            response.extend(end.as_object().cloned().unwrap_or_default());
        }
        self.line.insert("response".into(), Value::Object(response));
        let text = Value::Object(std::mem::take(&mut self.line)).to_string();
        // the receiver gone means the hub is stopping: nothing more is written
        let _ = self.lines.send(("llm.jsonl", text));
    }
}

impl Exchange for Line {
    fn head(&mut self, at: Instant, status: u16, headers: &http::HeaderMap) {
        let pairs: Vec<(&str, &str)> = headers
            .iter()
            .filter_map(|(n, v)| Some((n.as_str(), v.to_str().ok()?)))
            .collect();
        self.response.insert("status".into(), json!(status));
        self.response
            .insert("headers".into(), Value::Object(self.scrub.headers(pairs)));
        self.response
            .insert("head_ms".into(), json!(ms(self.begun, at)));
        self.last = at;
    }

    fn chunk(&mut self, at: Instant, data: &[u8]) {
        self.chunks
            .push(json!([ms(self.last, at), stored(&self.scrub, data)]));
        self.last = at;
    }

    fn end(mut self: Box<Self>, _at: Instant, end: End) {
        let end = match end {
            End::Complete => json!({"end": "complete"}),
            End::Dropped => json!({"end": "dropped"}),
            End::ClientLeft { chunk } => json!({"end": "client-left", "at_chunk": chunk}),
        };
        self.write(Some(end));
    }
}

impl Drop for Line {
    fn drop(&mut self) {
        self.write(None);
    }
}
