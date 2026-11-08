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
//!   Every agent connection gets a line tap ([`acp_tap`], hermod's `ConnOpts::tap`), numbered in spawn order: both
//!   directions and the exit into `acp/<n>.jsonl`, the session's MCP calls at its socket ([`mcp`]), and the worktree's
//!   changes at each completed tool call and at the turn's end (`effects/<n>-<seq>/`), noted before the line that
//!   completes it.
//! - **Replay:** one `ratatoskr-mock llm --replay DIR` (beside this binary, or `RATATOSKR_MOCK`) is started with
//!   `--parent` this hub, and every provider's base becomes `/p/ID` on it, keyless ([`replayed`]): the hub runs for
//!   real, only the provider end is the recording.  Every agent profile's command becomes `ratatoskr-mock acp
//!   --replay DIR` ([`replayed_profile`]).  Misses (and the replayers' connection claims) go to
//!   `$DRGNX_RUN_TMP/replay/` (else `$TMPDIR/replay/`); `DRGNX_REPLAY_SPEED` paces the chunks and the agent's actions
//!   (default 0: no waits); `DRGNX_REPLAY_STRICT=1` fails an agent replay that leaves recorded lines unused.

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
    Replay(Replay),
}

/// A replay: the run, the LLM replayer's port, and what an agent profile's ACP replayer is started with.
struct Replay {
    dir: PathBuf,
    port: u16,
    mock: PathBuf,
    /// `$DRGNX_RUN_TMP/replay/`: misses and the connections' claims, never in the recording.
    scratch: PathBuf,
    /// This hub's roots, for the ACP replayer's normalizers (`--roots`).
    roots: String,
    speed: String,
    strict: bool,
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
            // the caps `bin/drgnx record start` was given, for the manifest and the report (the run enforces them)
            if let Some(caps) = var(env, "DRGNX_RECORD_CAPS")
                .and_then(|c| serde_json::from_str::<Value>(c).ok())
                .filter(Value::is_object)
            {
                r.manifest(|m| m["caps"] = caps);
            }
            tracing::info!(dir, provenance, "recording this run (DRGNX_RECORD)");
            let _ = MODE.set(Mode::Record(r));
            Ok(())
        }
        (None, Some(dir)) => {
            let dir = PathBuf::from(dir);
            rec::read_manifest(&dir)?;
            let (d, e) = (dir.clone(), env.clone());
            let (port, mock, scratch) =
                crate::clock::blocking(move || replayer(&d, &e))
                    .await
                    .map_err(|e| format!("the replayer did not start: {e}"))??;
            tracing::info!(dir = %dir.display(), port, "replaying a recorded run (DRGNX_REPLAY)");
            let _ = MODE.set(Mode::Replay(Replay {
                dir,
                port,
                mock,
                scratch,
                roots: Roots::of_env(env).to_json().to_string(),
                speed: var(env, "DRGNX_REPLAY_SPEED").unwrap_or("0").to_owned(),
                strict: var(env, "DRGNX_REPLAY_STRICT") == Some("1"),
            }));
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
        Mode::Replay(r) => RecordingStatus {
            mode: RecordingMode::Replay,
            dir: r.dir.to_string_lossy().into_owned(),
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

/// Whether this hub replays a recording (its providers answer from the recording, so a request nothing recorded is a
/// miss, not a connection refused).
pub fn replaying() -> bool {
    matches!(MODE.get(), Some(Mode::Replay(_)))
}

/// While replaying, provider ID's base on the replayer, keyless; else none (the provider as configured).
pub fn replayed(id: &str) -> Option<(bifrost::Uri, bifrost::Auth)> {
    match MODE.get() {
        Some(Mode::Replay(r)) => format!("http://127.0.0.1:{}/p/{id}", r.port)
            .parse()
            .ok()
            .map(|u| (u, bifrost::Auth::None)),
        _ => None,
    }
}

/// While replaying, PROFILE with its command replaced by the ACP replayer of the run (`ratatoskr-mock acp --replay
/// DIR --as KIND`); else none.  Its provider is kept from the command it had, so the lock and the version-gated
/// behaviour are the live ones; the adapter's name and version come from the recorded `initialize` answer.
pub fn replayed_profile(
    profile: &crate::settings::AgentProfile,
) -> Option<crate::settings::AgentProfile> {
    use crate::settings::profiles::Provider;
    let Some(Mode::Replay(r)) = MODE.get() else {
        return None;
    };
    let mut p = profile.clone();
    p.provider = profile.provider();
    let kind = match p.provider {
        Some(Provider::Codex) => "codex",
        Some(Provider::Gemini) => "gemini",
        _ => "claude",
    };
    p.command = replay_command(r, kind);
    Some(p)
}

/// The command of a replayed agent of KIND.
fn replay_command(r: &Replay, kind: &str) -> Vec<String> {
    let s = |p: &Path| p.to_string_lossy().into_owned();
    let mut command = vec![
        s(&r.mock),
        "acp".into(),
        "--replay".into(),
        s(&r.dir),
        "--as".into(),
        kind.into(),
        "--misses".into(),
        s(&r.scratch.join("misses.jsonl")),
        "--roots".into(),
        r.roots.clone(),
        "--speed".into(),
        r.speed.clone(),
    ];
    if r.strict {
        command.push("--strict".into());
    }
    command
}

/// What a sandboxed replayer needs beside the session's own paths: the recording and its binary's directory to read,
/// the scratch directory (misses, claims) to write.
#[derive(Debug, Clone, PartialEq)]
pub struct ReplayDirs {
    pub read: Vec<PathBuf>,
    pub write: Vec<PathBuf>,
}

fn replay_dirs_of(r: &Replay) -> ReplayDirs {
    let mut read = vec![r.dir.clone()];
    read.extend(r.mock.parent().map(Path::to_path_buf));
    ReplayDirs {
        read,
        write: vec![r.scratch.clone()],
    }
}

/// While replaying, the directories a sandboxed agent launch must reach for the replayer to run; else none.
pub fn replay_dirs() -> Option<ReplayDirs> {
    match MODE.get() {
        Some(Mode::Replay(r)) => Some(replay_dirs_of(r)),
        _ => None,
    }
}

/// Start `ratatoskr-mock llm --replay DIR` and read its port; with it, the mock and the replay's scratch directory
/// (its connection claims cleared: they are this replay's).
fn replayer(dir: &Path, env: &Env) -> Result<(u16, PathBuf, PathBuf), String> {
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
    let _ = std::fs::remove_dir_all(scratch.join("claims"));
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
            Ok((p, mock, scratch))
        }
        None => {
            let _ = child.kill();
            let _ = child.wait();
            Err(format!("the replayer said {:?}, not its port", line.trim()))
        }
    }
}

// ------------------------------------------------------------------------------------------ the recorder

/// One run's recorder: its clock, its `seq`, the writer thread and the scrubber; the agent connections (numbered in
/// spawn order) and the manifest that names them.
pub struct Recorder {
    dir: PathBuf,
    started: Instant,
    seq: AtomicU64,
    exchanges: AtomicU64,
    /// The longest a connection's reader thread spent in a worktree look, in microseconds.
    worst_stall_us: AtomicU64,
    scrub: Mutex<Scrub>,
    roots: Roots,
    lines: Mutex<mpsc::Sender<(String, String)>>,
    connections: AtomicU64,
    /// Hub session → its latest connection (its MCP calls go into that stream).
    by_sid: Mutex<HashMap<String, u64>>,
    /// Agent session id → the connection that opened it (a fork's `forked_from`).
    acp_sessions: Mutex<HashMap<String, u64>>,
    manifest: Mutex<Value>,
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
        let (tx, rx) = mpsc::channel::<(String, String)>();
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
            worst_stall_us: AtomicU64::new(0),
            scrub: Mutex::new(Scrub::default()),
            roots,
            lines: Mutex::new(tx),
            connections: AtomicU64::new(0),
            by_sid: Mutex::new(HashMap::new()),
            acp_sessions: Mutex::new(HashMap::new()),
            manifest: Mutex::new(manifest),
        }))
    }

    fn t_ms(&self, at: Instant) -> u64 {
        u64::try_from(at.saturating_duration_since(self.started).as_millis()).unwrap_or(u64::MAX)
    }

    fn next_seq(&self) -> u64 {
        self.seq.fetch_add(1, Ordering::Relaxed) + 1
    }

    /// One `{seq, t_ms, dir, msg}` line of STREAM (`acp/<n>.jsonl`), with SEQ taken already.
    fn write(&self, stream: &str, seq: u64, at: Instant, dir: &str, msg: Value) {
        let line = json!({"seq": seq, "t_ms": self.t_ms(at), "dir": dir, "msg": msg}).to_string();
        // the receiver gone means the hub is stopping: nothing more is written
        let _ = lock(&self.lines).send((stream.to_owned(), line));
    }

    /// A connection's reader thread spent D in the worktree look (git and file reads, on that thread): the worst so
    /// far is in the manifest's `stats.worst_effects_stall_ms`, for the report.
    fn stalled(&self, d: std::time::Duration) {
        let us = u64::try_from(d.as_micros()).unwrap_or(u64::MAX);
        if self.worst_stall_us.fetch_max(us, Ordering::Relaxed) < us {
            self.manifest(|m| m["stats"] = json!({"worst_effects_stall_ms": us as f64 / 1000.0}));
        }
    }

    /// The manifest changed by F, written whole again (to a temporary file, then renamed: never half a manifest).
    fn manifest(&self, f: impl FnOnce(&mut Value)) {
        let mut m = lock(&self.manifest);
        f(&mut m);
        let text = serde_json::to_string_pretty(&*m).unwrap_or_default() + "\n";
        let tmp = self.dir.join("manifest.json.tmp");
        if let Err(e) = std::fs::write(&tmp, text)
            .and_then(|()| std::fs::rename(&tmp, self.dir.join("manifest.json")))
        {
            tracing::error!("the recording's manifest cannot be written: {e}");
        }
    }
}

/// The writer thread: each line appended to its stream and flushed, so a killed run leaves a usable prefix.
fn write_lines(dir: &Path, rx: &mpsc::Receiver<(String, String)>) {
    let mut files: HashMap<String, File> = HashMap::new();
    for (stream, line) in rx {
        if !files.contains_key(&stream) {
            let path = dir.join(&stream);
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            match std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
            {
                Ok(f) => {
                    files.insert(stream.clone(), f);
                }
                Err(e) => {
                    tracing::error!(stream = %stream, "the recording cannot write: {e}");
                    continue;
                }
            }
        }
        if let Some(f) = files.get_mut(&stream)
            && let Err(e) = f
                .write_all(line.as_bytes())
                .and_then(|()| f.write_all(b"\n"))
                .and_then(|()| f.flush())
        {
            tracing::error!(stream = %stream, "the recording cannot write: {e}");
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
        let seq = self.next_seq();
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
    lines: mpsc::Sender<(String, String)>,
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
        let _ = self.lines.send(("llm.jsonl".into(), text));
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

// ------------------------------------------------------------------------------------------ the ACP pipe

/// The requests that open a connection's session.
const OPENERS: [&str; 4] = [
    "session/new",
    "session/fork",
    "session/load",
    "session/resume",
];

/// A worktree that is not a repository is walked, at most this many files.
const WALK_MAX: usize = 20_000;

/// Whether this run is recorded (the hub's MCP calls are noted then, [`mcp`]).
pub fn is_recording() -> bool {
    matches!(MODE.get(), Some(Mode::Record(_)))
}

/// While recording, the line tap of a new agent connection, numbered in spawn order: hub session SID (on JOB), started
/// for PROFILE with SPEC, in the worktree CWD.  Its lines go into `acp/<n>.jsonl`, the manifest names it, and the
/// session's MCP calls and its worktree's changes are noted in that stream from now on.  None when not recording.
pub fn acp_tap(
    sid: &str,
    job: Option<&str>,
    profile: &str,
    spec: &draugr::Spec,
    cwd: &Path,
) -> Option<Arc<dyn hermod::LineTap>> {
    let Some(Mode::Record(r)) = MODE.get() else {
        return None;
    };
    let n = r.connections.fetch_add(1, Ordering::Relaxed) + 1;
    lock(&r.by_sid).insert(sid.to_owned(), n);
    let argv: Vec<String> = std::iter::once(spec.program.as_os_str())
        .chain(spec.args.iter().map(|a| a.as_os_str()))
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let argv = lock(&r.scrub).argv(&argv);
    let entry = json!({"n": n, "profile": profile, "argv": argv, "spawned_ms": r.t_ms(crate::clock::real_now()),
        "sid": sid, "job": job, "opens_with": null});
    r.manifest(|m| {
        if let Some(c) = m["connections"].as_array_mut() {
            c.push(entry);
        }
    });
    Some(Arc::new(AcpTap {
        rec: r.clone(),
        n,
        stream: format!("acp/{n}.jsonl"),
        state: Mutex::new(TapState {
            pending: HashMap::new(),
            opened: false,
            tree: Tree::of(cwd),
        }),
    }))
}

/// While recording, hub session SID's call of its MCP tool TOOL with ARGS and its RESULT, into the session's latest
/// connection's stream (`mcp` `{tool, args, result}`): the replayer makes the same call at the same point.
pub fn mcp(sid: &str, tool: &str, args: &Value, result: &mimir::ToolResult) {
    let Some(Mode::Record(r)) = MODE.get() else {
        return;
    };
    let Some(n) = lock(&r.by_sid).get(sid).copied() else {
        return;
    };
    let result = match result {
        mimir::ToolResult::Ok { text, structured }
        | mimir::ToolResult::Rich {
            text, structured, ..
        } => json!({"text": text, "structured": structured}),
        mimir::ToolResult::Err(e) => json!({"error": e}),
    };
    let msg = lock(&r.scrub).value(&json!({"tool": tool, "args": args, "result": result}));
    let seq = r.next_seq();
    r.write(
        &format!("acp/{n}.jsonl"),
        seq,
        crate::clock::real_now(),
        "mcp",
        msg,
    );
}

/// One connection's tap: its lines, its exit and its worktree's changes.
struct AcpTap {
    rec: Arc<Recorder>,
    n: u64,
    stream: String,
    /// Held while a line is noted, so the connection's lines take their `seq` in the order they passed.
    state: Mutex<TapState>,
}

struct TapState {
    /// The hub's requests not answered yet: id → (method, the agent session it names).
    pending: HashMap<String, (String, Option<String>)>,
    /// The connection's first session request was seen (the manifest's `opens_with`).
    opened: bool,
    tree: Tree,
}

impl AcpTap {
    /// The manifest's `opens_with` (and a fork's `forked_from`: the connection that opened its source).
    fn opened(&self, method: &str, named: Option<&str>) {
        let from = named.and_then(|s| {
            lock(&self.rec.acp_sessions)
                .get(s)
                .map(|n| json!({"n": n, "session": s}))
        });
        let n = self.n;
        self.rec.manifest(|m| {
            let Some(c) = m["connections"]
                .as_array_mut()
                .and_then(|cs| cs.iter_mut().find(|c| c["n"] == n))
            else {
                return;
            };
            c["opens_with"] = json!(method);
            if method == "session/fork"
                && let Some(f) = from
            {
                c["forked_from"] = f;
            }
        });
    }

    /// The adapter an `initialize` answer names, once in the manifest's `adapters`.
    fn adapter(&self, answer: &Value) {
        let Some(info) = answer.pointer("/result/agentInfo") else {
            return;
        };
        let a = json!({"name": info["name"], "version": info["version"]});
        self.rec.manifest(|m| {
            if let Some(list) = m["adapters"].as_array_mut()
                && !list.contains(&a)
            {
                list.push(a);
            }
        });
    }

    /// The worktree's changes since the last look, as `effects/<n>-<seq>/` (`files/…` scrubbed, `deleted.txt`,
    /// `commits.bundle` of the new commits) and an `effect` line, written before the line that completes the tool call
    /// or the turn: the replayer lands them before it sends that line.  Nothing changed: nothing written.
    fn effects(&self, tree: &mut Tree, at: Instant) {
        let (files, head) = scan(&tree.cwd);
        let changed: Vec<&String> = files
            .iter()
            .filter(|(k, v)| tree.files.get(*k) != Some(*v))
            .map(|(k, _)| k)
            .collect();
        let mut deleted: Vec<&String> = tree
            .files
            .keys()
            .filter(|k| !files.contains_key(*k))
            .collect();
        let moved = head.is_some() && head != tree.head;
        if changed.is_empty() && deleted.is_empty() && !moved {
            return;
        }
        let seq = self.rec.next_seq();
        let rel = format!("effects/{}-{seq}", self.n);
        let out = self.rec.dir.join(&rel);
        if let Err(e) = std::fs::create_dir_all(&out) {
            tracing::error!("the recording cannot write {rel}: {e}");
        }
        let scrub = lock(&self.rec.scrub).clone();
        for f in &changed {
            let Ok(bytes) = std::fs::read(tree.cwd.join(f)) else {
                continue;
            };
            let bytes = match std::str::from_utf8(&bytes) {
                Ok(s) => scrub.text(s).into_owned().into_bytes(),
                Err(_) => bytes,
            };
            let to = out.join("files").join(f);
            if let Some(p) = to.parent() {
                let _ = std::fs::create_dir_all(p);
            }
            if let Err(e) = std::fs::write(&to, bytes) {
                tracing::error!("the recording cannot write {}: {e}", to.display());
            }
        }
        if !deleted.is_empty() {
            deleted.sort();
            let list: String = deleted.iter().map(|d| format!("{d}\n")).collect();
            let _ = std::fs::write(out.join("deleted.txt"), list);
        }
        let mut msg = json!({"path": rel});
        if moved {
            let bundle = out.join("commits.bundle").to_string_lossy().into_owned();
            let not = tree.head.as_ref().map(|h| format!("^{h}"));
            let mut args = vec!["bundle", "create", bundle.as_str(), "HEAD"];
            args.extend(not.as_deref());
            // a head that moved back has no new commits: the replayer moves it only
            if git(&tree.cwd, &args).is_none() {
                tracing::info!(effect = %rel, "no commits bundled: the head has no new commits");
            }
            msg["head"] = json!(head);
        }
        tree.files = files;
        tree.head = head;
        self.rec.write(&self.stream, seq, at, "effect", msg);
    }
}

/// A completed (or failed) tool call's last update: the agent's own tools may have changed the worktree.
fn ends_a_tool_call(msg: &Value) -> bool {
    msg["method"] == "session/update"
        && msg.pointer("/params/update/sessionUpdate") == Some(&json!("tool_call_update"))
        && matches!(
            msg.pointer("/params/update/status").and_then(Value::as_str),
            Some("completed" | "failed")
        )
}

impl hermod::LineTap for AcpTap {
    fn line(&self, dir: hermod::Dir, line: &str, at: Instant) {
        let msg: Value = serde_json::from_str(line).unwrap_or_else(|_| json!(line));
        let mut st = lock(&self.state);
        let mut effects = false;
        match dir {
            hermod::Dir::In => {
                if let (Some(id), Some(m)) = (msg.get("id"), msg["method"].as_str()) {
                    let named = msg
                        .pointer("/params/sessionId")
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    if OPENERS.contains(&m) && !st.opened {
                        st.opened = true;
                        self.opened(m, named.as_deref());
                    }
                    st.pending.insert(id.to_string(), (m.to_owned(), named));
                }
            }
            hermod::Dir::Out => {
                let answered = match (msg.get("method"), msg.get("id")) {
                    (None, Some(id)) => st.pending.remove(&id.to_string()),
                    _ => None,
                };
                if let Some((m, named)) = answered {
                    if OPENERS.contains(&m.as_str())
                        && let Some(s) = msg
                            .pointer("/result/sessionId")
                            .and_then(Value::as_str)
                            .map(str::to_owned)
                            .or(named)
                    {
                        lock(&self.rec.acp_sessions).insert(s, self.n);
                    }
                    if m == "initialize" {
                        self.adapter(&msg);
                    }
                    // the turn ended
                    effects = m == "session/prompt";
                }
                effects |= ends_a_tool_call(&msg);
            }
        }
        if effects {
            let began = crate::clock::real_now();
            self.effects(&mut st.tree, at);
            self.rec
                .stalled(crate::clock::real_now().saturating_duration_since(began));
        }
        let msg = lock(&self.rec.scrub).value(&msg);
        let seq = self.rec.next_seq();
        let d = match dir {
            hermod::Dir::In => "in",
            hermod::Dir::Out => "out",
        };
        self.rec.write(&self.stream, seq, at, d, msg);
    }

    fn exit(&self, code: Option<i32>, signal: Option<i32>, stderr: &str) {
        let _st = lock(&self.state);
        let stderr = lock(&self.rec.scrub).text(stderr).into_owned();
        let seq = self.rec.next_seq();
        self.rec.write(
            &self.stream,
            seq,
            crate::clock::real_now(),
            "exit",
            json!({"code": code, "signal": signal, "stderr": stderr}),
        );
    }
}

/// A worktree as last seen: each file's size and modification time, and the head commit.
struct Tree {
    cwd: PathBuf,
    files: HashMap<String, (u64, Option<std::time::SystemTime>)>,
    head: Option<String>,
}

impl Tree {
    fn of(cwd: &Path) -> Tree {
        let (files, head) = scan(cwd);
        Tree {
            cwd: cwd.to_path_buf(),
            files,
            head,
        }
    }
}

/// `git -C CWD ARGS…`'s output, when it succeeds.
fn git(cwd: &Path, args: &[&str]) -> Option<Vec<u8>> {
    std::process::Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| o.stdout)
}

/// CWD's files (a repository's tracked and unignored ones, else every file but `.git`'s) and its head commit.
#[allow(clippy::type_complexity)]
fn scan(
    cwd: &Path,
) -> (
    HashMap<String, (u64, Option<std::time::SystemTime>)>,
    Option<String>,
) {
    let names: Vec<String> = match git(
        cwd,
        &[
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
    ) {
        Some(out) => out
            .split(|b| *b == 0)
            .filter(|n| !n.is_empty())
            .map(|n| String::from_utf8_lossy(n).into_owned())
            .collect(),
        None => walk(cwd),
    };
    let files = names
        .into_iter()
        .filter_map(|n| {
            let m = std::fs::symlink_metadata(cwd.join(&n)).ok()?;
            m.is_file().then(|| (n, (m.len(), m.modified().ok())))
        })
        .collect();
    let head = git(cwd, &["rev-parse", "-q", "--verify", "HEAD"])
        .map(|o| String::from_utf8_lossy(&o).trim().to_owned())
        .filter(|h| !h.is_empty());
    (files, head)
}

/// Every file under ROOT but `.git`'s, relative, at most [`WALK_MAX`].
fn walk(root: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let mut dirs = vec![root.to_path_buf()];
    while let Some(d) = dirs.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            if out.len() >= WALK_MAX {
                return out;
            }
            let p = e.path();
            match e.file_type() {
                Ok(t) if t.is_dir() && e.file_name() != ".git" => dirs.push(p),
                Ok(t) if t.is_file() => {
                    if let Ok(rel) = p.strip_prefix(root) {
                        out.push(rel.to_string_lossy().into_owned());
                    }
                }
                _ => {}
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn replay(strict: bool) -> Replay {
        Replay {
            dir: "/rec/run".into(),
            port: 1,
            mock: "/bin/dir/ratatoskr-mock".into(),
            scratch: "/scratch/replay".into(),
            roots: "{}".into(),
            speed: "0".into(),
            strict,
        }
    }

    // Pattern D (pure): `DRGNX_REPLAY_STRICT=1` puts `--strict` on every replayed agent's command, and only then.
    #[test]
    fn strict_reaches_the_replayed_agents_command() {
        assert!(replay_command(&replay(true), "claude").contains(&"--strict".to_owned()));
        assert!(!replay_command(&replay(false), "claude").contains(&"--strict".to_owned()));
    }

    // Pattern D (pure): the sandboxed replayer reads the recording and its own binary's dir, and writes its scratch.
    #[test]
    fn the_replayer_needs_the_recording_and_scratch_dirs() {
        let d = replay_dirs_of(&replay(false));
        assert_eq!(
            d.read,
            [PathBuf::from("/rec/run"), PathBuf::from("/bin/dir")]
        );
        assert_eq!(d.write, [PathBuf::from("/scratch/replay")]);
    }
}
