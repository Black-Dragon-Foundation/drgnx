//! The local engine (MP-8): `llama-server` of a pinned llama.cpp release ([`super::engine_install`]), a process the hub
//! starts when a request needs it and ends after [`IDLE`] without one, like the built-in model's worker.
//!
//! - It is started through `draugr` in a process group of its own, with an allowlisted environment, as `llama-server -m
//!   GGUF --embedding --pooling last -c CTX -b CTX -ub CTX -ngl 999 --host 127.0.0.1 --port 0 --no-webui`: a free port
//!   on the loopback, read from its log line, and the whole model on the GPU. CTX is the longest text of the request
//!   rounded up to 512 (never past the spec's `ctx`); a request that needs more starts it again with more.
//! - It never truncates. A text's tokens are bounded by its bytes (a token is at least one byte) plus the special
//!   tokens; a text whose bound passes the fingerprint's `max_tokens` is counted by the engine (`/tokenize`), and one
//!   over the limit is an error back to the caller (the chunker splits long chunks): no embeddings request is sent.
//! - A request's texts are sent shortest first ([`by_length`]), in batches of at most `ubatch` tokens
//!   ([`Pacer::fixed`]); the vectors come back in the caller's order, L2-normalised.
//! - A process that dies inside a request is started again and the request sent again, once.
//! - After each start, the self-check: the reference text's vector must have a cosine of at least [`SELFCHECK_MIN`] to
//!   the stored F16 reference, or the engine is refused (its process ended) and embeds nothing more: a GGUF or a build
//!   whose vectors are off never writes a vector.
//! - Backend: the asset's own (Vulkan on Linux and Windows, Metal on macOS). With several Vulkan devices ggml takes its
//!   own default (the dedicated GPUs, else the first integrated one); a `GGML_VK_VISIBLE_DEVICES` of the user's is
//!   passed on.

use super::sources::SourceKind;
use hrafn_embed::fingerprint::{FingerprintRecord, Identity};
use hrafn_embed::pace::{Pacer, by_length};
use serde_json::{Value, json};
use std::ffi::{OsStr, OsString};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use urdr::graph::search::{BoxFuture, EmbedError, Embedder};

/// How long the engine runs without a request before it is ended.
pub const IDLE: Duration = Duration::from_secs(300);
/// The context is a multiple of this.
const CTX_STEP: u32 = 512;
/// The least cosine of the self-check's vector to its reference.
pub const SELFCHECK_MIN: f32 = 0.99;
/// The tokens a text gets beyond its own (the end-of-text token that last-token pooling reads, and one spare).
const SPECIAL_TOKENS: usize = 2;
/// How long a start may take, its model loaded (real time: it is the process's own work).
const START_WAIT: Duration = Duration::from_secs(120);
/// How often a start looks for the port line and the loaded model.
const START_POLL: Duration = Duration::from_millis(20);
/// How long one request may take.
const REQUEST_WAIT: Duration = Duration::from_secs(600);
/// After a request broke off, how long the process has to be seen gone before the break counts as the engine's answer.
const REAP_WAIT: Duration = Duration::from_secs(2);
/// The hub's variables the engine gets: the loader's, and the GPU drivers' (Vulkan, Mesa, NVIDIA) and ggml's by prefix.
const ENV: &[&str] = &[
    "PATH",
    stig::HOME_VAR,
    stig::SYSTEM_RUNTIME_VAR,
    "LANG",
    "LC_ALL",
];
const ENV_PREFIXES: &[&str] = &["VK_", "MESA_", "GGML_", "RADV_", "__NV_", "__GLX_"];

/// The text and the reference vector of the engine's self-check (`hrafn-embed/data/*.selfcheck.json`).
#[derive(Clone, Debug, serde::Deserialize)]
pub struct SelfCheck {
    pub text: String,
    pub vector: Vec<f32>,
}

/// What the engine runs.
pub struct EngineSpec {
    /// `llama-server`.
    pub exe: PathBuf,
    pub gguf: PathBuf,
    /// The fingerprint of its vectors.
    pub record: FingerprintRecord,
    /// The name it goes by in a chain's status.
    pub label: String,
    /// The largest context it is started with.
    pub ctx: u32,
    /// The tokens of one request (one batch of texts).
    pub ubatch: u32,
    pub idle: Duration,
    /// None: no check (a test's engine).
    pub selfcheck: Option<SelfCheck>,
}

/// A running engine.
struct Running {
    port: u16,
    pid: i32,
    ctx: u32,
    dead: Arc<AtomicBool>,
    /// Turns true once the process has exited and was reaped.
    reaped: tokio::sync::watch::Receiver<bool>,
}

#[derive(Default)]
struct State {
    running: Option<Running>,
    /// Why the engine is refused (its self-check failed): it embeds nothing more.
    refused: Option<String>,
    /// The last self-check's cosine.
    checked: Option<f32>,
}

/// What the idle timer and the requests share.
struct Shared {
    state: tokio::sync::Mutex<State>,
    pid: Mutex<Option<i32>>,
    last_use: Mutex<tokio::time::Instant>,
    busy: AtomicUsize,
}

impl Shared {
    fn touch(&self) {
        *saman::lock(&self.last_use) = crate::clock::now();
    }

    fn set_pid(&self, was: Option<i32>, now: Option<i32>) {
        let mut p = saman::lock(&self.pid);
        if was.is_none() || *p == was {
            *p = now;
        }
    }
}

/// A request in flight: it keeps the idle timer away, and its end counts as the engine's last use.
struct Busy<'a>(&'a Shared);

impl<'a> Busy<'a> {
    fn new(s: &'a Shared) -> Busy<'a> {
        s.busy.fetch_add(1, Ordering::SeqCst);
        Busy(s)
    }
}

impl Drop for Busy<'_> {
    fn drop(&mut self) {
        self.0.touch();
        self.0.busy.fetch_sub(1, Ordering::SeqCst);
    }
}

/// How a request failed.
enum Fail {
    /// The connection broke or never came: the process may have died.
    Broke(String),
    /// The engine answered, with an error or with what is not vectors.
    Answered(String),
}

impl Fail {
    fn text(self) -> String {
        match self {
            Fail::Broke(s) | Fail::Answered(s) => s,
        }
    }
}

/// TOKENS rounded up to a multiple of 512, at most MAX.
fn round_ctx(tokens: usize, max: u32) -> u32 {
    let t = u32::try_from(tokens).unwrap_or(u32::MAX).max(1);
    t.div_ceil(CTX_STEP).saturating_mul(CTX_STEP).min(max)
}

fn normalise(mut v: Vec<f32>) -> Vec<f32> {
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if n > 0.0 {
        v.iter_mut().for_each(|x| *x /= n);
    }
    v
}

/// The cosine of A and B.
fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let (a, b) = (normalise(a.to_vec()), normalise(b.to_vec()));
    a.iter().zip(&b).map(|(x, y)| x * y).sum()
}

/// The port in llama-server's log: `… listening on http://127.0.0.1:PORT …`, or `… HTTP server is listening,
/// hostname: 127.0.0.1, port: PORT, …`.
fn port_in(log: &str) -> Option<u16> {
    log.lines().find_map(|l| {
        if let Some((_, rest)) = l.split_once("listening on http://") {
            let hostport = rest.split_whitespace().next()?;
            return hostport
                .trim_end_matches('/')
                .rsplit_once(':')?
                .1
                .parse()
                .ok();
        }
        let (_, rest) = l.split_once("HTTP server is listening")?;
        let (_, p) = rest.split_once("port: ")?;
        p.split(|c: char| !c.is_ascii_digit()).next()?.parse().ok()
    })
}

/// One HTTP/1.1 request to the engine on PORT: its status and body; an error when the connection broke.
async fn http(
    port: u16,
    method: &str,
    path: &str,
    body: Option<&Value>,
) -> Result<(u16, Vec<u8>), String> {
    let body = body.map(Value::to_string).unwrap_or_default();
    let head = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let asked = async {
        let mut s = TcpStream::connect(("127.0.0.1", port))
            .await
            .map_err(|e| format!("the engine does not answer: {e}"))?;
        s.write_all(head.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        s.write_all(body.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        let mut raw = Vec::new();
        s.read_to_end(&mut raw).await.map_err(|e| e.to_string())?;
        crate::embed::split_response(&raw)
    };
    crate::clock::timeout(REQUEST_WAIT, crate::clock::real(asked))
        .await
        .unwrap_or_else(|_| Err("the engine did not answer in time".into()))
}

/// The hub's handle on its llama.cpp engine (the module's doc).
pub struct LocalEngine {
    spec: EngineSpec,
    shared: Arc<Shared>,
    identity: Identity,
}

impl LocalEngine {
    pub fn new(spec: EngineSpec) -> LocalEngine {
        let identity = Identity::new(spec.record.clone(), spec.label.as_str());
        LocalEngine {
            spec,
            shared: Arc::new(Shared {
                state: tokio::sync::Mutex::new(State::default()),
                pid: Mutex::new(None),
                last_use: Mutex::new(crate::clock::now()),
                busy: AtomicUsize::new(0),
            }),
            identity,
        }
    }

    /// The running process's pid; none while none runs.
    pub fn pid(&self) -> Option<i32> {
        *saman::lock(&self.shared.pid)
    }

    /// The fingerprint of its vectors, which it knows without a start.
    pub fn identity(&self) -> Identity {
        self.identity.clone()
    }

    /// The process with a context of at least CTX: the running one, or a new one whose self-check passed.
    async fn ensure(&self, ctx: u32) -> Result<u16, EmbedError> {
        let mut st = self.shared.state.lock().await;
        if let Some(why) = &st.refused {
            return Err(EmbedError(why.clone()));
        }
        if st
            .running
            .as_ref()
            .is_some_and(|r| r.dead.load(Ordering::SeqCst) || r.ctx < ctx)
            && let Some(r) = st.running.take()
        {
            end(&self.shared, r).await;
        }
        if let Some(r) = &st.running {
            return Ok(r.port);
        }
        let r = self.start(ctx).await?;
        let port = r.port;
        self.shared.set_pid(None, Some(r.pid));
        st.running = Some(r);
        if let Some(check) = &self.spec.selfcheck {
            let refused = match self
                .post_embeddings(port, std::slice::from_ref(&check.text))
                .await
            {
                Ok(mut v) => {
                    let c = cosine(&v.remove(0), &check.vector);
                    st.checked = Some(c);
                    (c < SELFCHECK_MIN).then(|| {
                        format!(
                            "the engine's self-check: its vector has a cosine of {c:.4} to the reference, under \
                             {SELFCHECK_MIN}; the engine is not used"
                        )
                    })
                }
                Err(e) => Some(format!(
                    "the engine's self-check did not answer: {}",
                    e.text()
                )),
            };
            if let Some(why) = refused {
                tracing::warn!("search: {why}");
                st.refused = Some(why.clone());
                if let Some(r) = st.running.take() {
                    end(&self.shared, r).await;
                }
                return Err(EmbedError(why));
            }
        }
        Ok(port)
    }

    /// A new process with context CTX, its port read and its model loaded, and its idle timer started.
    async fn start(&self, ctx: u32) -> Result<Running, EmbedError> {
        let s = &self.spec;
        let ctx_arg = ctx.to_string();
        let args: Vec<OsString> = [
            OsStr::new("-m"),
            s.gguf.as_os_str(),
            OsStr::new("--embedding"),
            OsStr::new("--pooling"),
            OsStr::new("last"),
            OsStr::new("-c"),
            OsStr::new(&ctx_arg),
            OsStr::new("-b"),
            OsStr::new(&ctx_arg),
            OsStr::new("-ub"),
            OsStr::new(&ctx_arg),
            OsStr::new("-ngl"),
            OsStr::new("999"),
            OsStr::new("--host"),
            OsStr::new("127.0.0.1"),
            OsStr::new("--port"),
            OsStr::new("0"),
            OsStr::new("--no-webui"),
        ]
        .iter()
        .map(|a| a.to_os_string())
        .collect();
        let folder = s.exe.parent().map(PathBuf::from).unwrap_or_default();
        let spec = draugr::Spec {
            program: s.exe.clone(),
            args,
            // the release's libraries sit beside its server
            env: draugr::env::build(
                ENV,
                ENV_PREFIXES,
                &[("LD_LIBRARY_PATH", folder.as_os_str())],
            ),
            cwd: Some(folder),
            stdin_null: true,
            pass_fds: Vec::new(),
            new_session: false,
        };
        let mut child = draugr::spawn(spec)
            .await
            .map_err(|e| EmbedError(format!("the engine did not start: {e}")))?;
        let pid = child.id();
        let tail = child.stderr();
        let dead = Arc::new(AtomicBool::new(false));
        let (reaped_tx, reaped) = tokio::sync::watch::channel(false);
        let gone = dead.clone();
        // its exit marks it dead, so the next request starts another
        crate::clock::spawn("search:engine-exit", async move {
            let status = child.wait().await;
            gone.store(true, Ordering::SeqCst);
            tracing::debug!("search: the engine (pid {pid}) exited: {status:?}");
            crate::soft::done(reaped_tx.send(true), "reaped_tx send");
        });
        let r = Running {
            port: 0,
            pid,
            ctx,
            dead,
            reaped,
        };
        let waited = crate::clock::real(async {
            let begun = crate::clock::real_now();
            let mut tick = crate::clock::real_interval(START_POLL);
            let mut port = None;
            loop {
                tick.tick().await;
                if r.dead.load(Ordering::SeqCst) {
                    return Err(format!(
                        "the engine exited while it started: {}",
                        tail.get()
                    ));
                }
                if begun.elapsed() > START_WAIT {
                    return Err(format!(
                        "the engine did not start within {} s: {}",
                        START_WAIT.as_secs(),
                        tail.get()
                    ));
                }
                if port.is_none() {
                    port = port_in(&tail.get());
                }
                if let Some(p) = port
                    && matches!(http(p, "GET", "/health", None).await, Ok((200, _)))
                {
                    return Ok(p);
                }
            }
        })
        .await;
        let port = match waited {
            Ok(p) => p,
            Err(why) => {
                end(&self.shared, r).await;
                return Err(EmbedError(why));
            }
        };
        tracing::info!("search: the engine started (pid {pid}, port {port}, context {ctx})");
        self.shared.touch();
        self.idle_timer(pid);
        Ok(Running { port, ..r })
    }

    /// Ends process PID once it has had no request for the spec's idle time, on the hub's clock.
    fn idle_timer(&self, pid: i32) {
        let (shared, idle) = (Arc::downgrade(&self.shared), self.spec.idle);
        crate::clock::spawn("search:engine-idle", async move {
            loop {
                let wait = {
                    let Some(s) = shared.upgrade() else { return };
                    if s.busy.load(Ordering::SeqCst) > 0 {
                        idle
                    } else {
                        let last = *saman::lock(&s.last_use);
                        (last + idle).saturating_duration_since(crate::clock::now())
                    }
                };
                if !wait.is_zero() {
                    crate::clock::sleep(wait).await;
                    continue;
                }
                let Some(s) = shared.upgrade() else { return };
                let mut st = s.state.lock().await;
                if !st.running.as_ref().is_some_and(|r| r.pid == pid) {
                    return; // another process, or none: its own timer runs
                }
                if let Some(r) = st.running.take() {
                    tracing::info!(
                        "search: the engine (pid {pid}) ends after {} s without a request",
                        idle.as_secs()
                    );
                    end(&s, r).await;
                }
                return;
            }
        });
    }

    /// The vectors of TEXTS from the engine on PORT, in one request, normalised.
    async fn post_embeddings(&self, port: u16, texts: &[String]) -> Result<Vec<Vec<f32>>, Fail> {
        let (status, body) = http(
            port,
            "POST",
            "/v1/embeddings",
            Some(&json!({"input": texts})),
        )
        .await
        .map_err(Fail::Broke)?;
        if status != 200 {
            return Err(Fail::Answered(format!(
                "the engine answered {status}: {}",
                String::from_utf8_lossy(&body)
                    .chars()
                    .take(200)
                    .collect::<String>()
            )));
        }
        #[derive(serde::Deserialize)]
        struct Row {
            index: usize,
            embedding: Vec<f32>,
        }
        #[derive(serde::Deserialize)]
        struct Answer {
            data: Vec<Row>,
        }
        let a: Answer = serde_json::from_slice(&body)
            .map_err(|e| Fail::Answered(format!("the engine answered what is not vectors: {e}")))?;
        if a.data.len() != texts.len() {
            return Err(Fail::Answered(format!(
                "the engine answered {} vectors for {} texts",
                a.data.len(),
                texts.len()
            )));
        }
        let mut out = vec![Vec::new(); texts.len()];
        for row in a.data {
            let slot = out.get_mut(row.index).ok_or_else(|| {
                Fail::Answered(format!(
                    "the engine answered a vector for text {}",
                    row.index
                ))
            })?;
            *slot = normalise(row.embedding);
        }
        Ok(out)
    }

    /// The tokens of TEXT as the engine on PORT counts them, with the special tokens.
    async fn count(&self, port: u16, text: &str) -> Result<usize, EmbedError> {
        let (status, body) = http(port, "POST", "/tokenize", Some(&json!({"content": text})))
            .await
            .map_err(EmbedError)?;
        let v: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        match (status, v["tokens"].as_array()) {
            (200, Some(t)) => Ok(t.len() + SPECIAL_TOKENS),
            _ => Err(EmbedError(format!(
                "the engine did not count a text's tokens (it answered {status})"
            ))),
        }
    }

    /// Whether the process on PORT is gone (reaped within [`REAP_WAIT`]), after a request to it broke off.
    async fn died(&self, port: u16) -> bool {
        let reaped = {
            let st = self.shared.state.lock().await;
            match &st.running {
                Some(r) if r.port == port => r.reaped.clone(),
                _ => return true,
            }
        };
        let mut reaped = reaped;
        crate::clock::timeout(
            REAP_WAIT,
            crate::clock::real(async move { reaped.wait_for(|d| *d).await.is_ok() }),
        )
        .await
        .unwrap_or(false)
    }

    /// One batch, its process started first: a process that dies inside it is started again and the batch sent again,
    /// once.
    async fn batch(&self, ctx: u32, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedError> {
        for attempt in 0..2 {
            let port = self.ensure(ctx).await?;
            match self.post_embeddings(port, texts).await {
                Ok(v) => return Ok(v),
                Err(Fail::Answered(e)) => return Err(EmbedError(e)),
                Err(Fail::Broke(e)) => {
                    if !self.died(port).await {
                        return Err(EmbedError(e));
                    }
                    if attempt == 0 {
                        tracing::warn!(
                            "search: the engine died in a request; starting it again: {e}"
                        );
                    }
                }
            }
        }
        Err(EmbedError("the engine died twice in one request".into()))
    }

    /// Vectors for TEXTS, in their order (the module's doc: never truncated, shortest first, one restart).
    pub async fn embed_docs(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedError> {
        if texts.is_empty() {
            return Ok(Vec::new());
        }
        let _busy = Busy::new(&self.shared);
        let max = self.spec.record.max_tokens as usize;
        let fits = |n: usize| round_ctx(n, self.spec.ctx);
        let mut tokens: Vec<usize> = texts.iter().map(|t| t.len() + SPECIAL_TOKENS).collect();
        for i in 0..texts.len() {
            if tokens[i] <= max {
                continue;
            }
            let known = tokens.iter().copied().filter(|&n| n <= max).max();
            let port = self.ensure(fits(known.unwrap_or(1))).await?;
            tokens[i] = self.count(port, &texts[i]).await?;
            if tokens[i] > max {
                return Err(EmbedError(format!(
                    "a text of {} tokens is over the model's {max} tokens: the engine never cuts one (the chunker \
                     splits it)",
                    tokens[i]
                )));
            }
        }
        let ctx = fits(tokens.iter().copied().max().unwrap_or(1));
        let order = by_length(&tokens);
        let mut pacer = Pacer::fixed(self.spec.ubatch as usize);
        let mut out = vec![Vec::new(); texts.len()];
        let mut at = 0;
        while at < order.len() {
            let lengths: Vec<usize> = order[at..].iter().map(|&i| tokens[i]).collect();
            let ids = &order[at..at + pacer.take(&lengths)];
            let batch: Vec<String> = ids.iter().map(|&i| texts[i].clone()).collect();
            for (&i, v) in ids.iter().zip(self.batch(ctx, &batch).await?) {
                out[i] = v;
            }
            at += ids.len();
        }
        Ok(out)
    }

    /// The vector of query Q: with an INSTRUCTION, `Instruct: <instruction>\nQuery:<q>` (the Qwen3 embedding models'
    /// query form); documents go plain.
    pub async fn embed_query(
        &self,
        q: &str,
        instruction: Option<&str>,
    ) -> Result<Vec<f32>, EmbedError> {
        let text = match instruction {
            Some(i) => format!("Instruct: {i}\nQuery:{q}"),
            None => q.to_owned(),
        };
        let mut v = self.embed_docs(&[text]).await?;
        v.pop()
            .ok_or_else(|| EmbedError("the engine answered no vector".into()))
    }

    /// The self-check's cosine: the engine started (or running) and its check passed; an error says why it was refused.
    pub async fn selfcheck(&self) -> Result<f32, EmbedError> {
        let _busy = Busy::new(&self.shared);
        self.ensure(1).await?;
        let st = self.shared.state.lock().await;
        st.checked
            .ok_or_else(|| EmbedError("the engine has no self-check".into()))
    }

    /// Ends the process, if one runs.
    pub async fn close(&self) {
        let mut st = self.shared.state.lock().await;
        if let Some(r) = st.running.take() {
            end(&self.shared, r).await;
        }
    }
}

/// Ends R's process group and waits until it was reaped.
async fn end(shared: &Shared, mut r: Running) {
    // SAFETY: kill(2) on the engine's own process group (draugr made the engine the leader of a new one)
    unsafe { libc::kill(-r.pid, libc::SIGKILL) };
    crate::soft::done(
        crate::clock::real(r.reaped.wait_for(|done| *done)).await,
        "crate::clock::real",
    );
    shared.set_pid(Some(r.pid), None);
}

impl Drop for LocalEngine {
    fn drop(&mut self) {
        if let Some(pid) = self.pid() {
            // SAFETY: kill(2) on the engine's own process group; its exit task reaps it
            unsafe { libc::kill(-pid, libc::SIGKILL) };
        }
    }
}

impl super::DocEmbedder for LocalEngine {
    fn identity(&self) -> Option<Identity> {
        Some(self.identity.clone())
    }

    /// The engine knows its model from its table row: no start.
    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>> {
        Box::pin(async move { Ok(self.identity.clone()) })
    }

    fn source_id(&self) -> String {
        "llama".into()
    }

    fn source_kind(&self) -> SourceKind {
        SourceKind::LocalEngine
    }

    fn embed_docs<'a>(
        &'a self,
        texts: &'a [String],
        _overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        Box::pin(LocalEngine::embed_docs(self, texts))
    }
}

impl Embedder for LocalEngine {
    fn embed<'a>(
        &'a self,
        texts: &'a [String],
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        Box::pin(LocalEngine::embed_docs(self, texts))
    }

    /// The fingerprint's hex: the key of the entity vectors it makes.
    fn model(&self) -> String {
        self.identity.fp.hex()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_port_comes_from_either_log_line() {
        assert_eq!(
            port_in(
                "x\nmain: server is listening on http://127.0.0.1:41234 - starting the main loop\n"
            ),
            Some(41234)
        );
        assert_eq!(
            port_in(
                "main: HTTP server is listening, hostname: 127.0.0.1, port: 40001, http threads: 7\n"
            ),
            Some(40001)
        );
        assert_eq!(port_in("srv  load_model: loading model\n"), None);
    }

    #[test]
    fn the_context_is_the_longest_text_rounded_up_to_512() {
        assert_eq!(round_ctx(13, 8192), 512);
        assert_eq!(round_ctx(512, 8192), 512);
        assert_eq!(round_ctx(513, 8192), 1024);
        assert_eq!(round_ctx(9000, 8192), 8192);
    }
}
