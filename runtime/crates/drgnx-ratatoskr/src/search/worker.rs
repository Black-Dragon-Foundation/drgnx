//! The embed worker: `ratatoskr embed-worker`, a child process, the only one that opens a GPU; and the hub's side of
//! it, [`WorkerEmbedder`].
//!
//! The child reads JSON lines `{"id", "kind", "texts"[, "instruction"]}` (`kind` is `doc` or `query`) and writes
//! `{"id", "vectors"}` or `{"id", "error"}`. Its first line is `{"ready": {"device", "name", "why"}}`; a fallback to
//! the CPU path after a lost device writes `{"fallback": {"from", "reason"}}`. A `doc` request is tokenised first and
//! split into batches by the pacer's budget; a thread reads stdin, so a query that arrives during a request is
//! answered before that request's next batch. It runs at nice 10, caps its address space at 2 GiB once its model is
//! loaded on the CPU path, and on the GPU path (no cap can stand there) reads its peak resident memory (`VmHWM`) before
//! each batch: over 1.5 GiB it answers the request with the reason and `"exit": true` and exits, and the hub starts
//! a fresh worker for the next request. It exits after `--idle-ms` (300 s) without a request and at the end of its stdin, so a dead hub leaves no worker.
//!
//! Its device: `--device cpu`, or `auto` (`hrafn_embed::device`: a cached choice, the CPU path on battery, otherwise
//! measured, and the choice written to `--device-cache` unless on battery). With the `test-hooks` feature `gpu:NAME`
//! names an adapter and destroys that device after the first batch, `--test-park` announces `{"parked": n}` before
//! each later batch of a request and waits for a line, `--test-crash-once FILE` and `--test-crash-always` abort inside
//! a request, and `--test-power-root DIR` stands for `/sys`.

use super::power;
use hrafn_embed::device::{self, Choice};
use hrafn_embed::pace::Pacer;
use hrafn_embed::{Device, EmbedFail, LocalEmbedder, ModelSpec, adapters};
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::oneshot;
use urdr::graph::search::{BoxFuture, EmbedError, Embedder};

/// How long the worker waits for a request before it exits and frees its model.
pub const IDLE: Duration = Duration::from_secs(300);

/// The address space the worker allows itself once its model is loaded on the CPU path.
const ADDRESS_CAP: u64 = 2 << 30;

/// The peak resident memory the worker allows itself on the GPU path, where no address-space cap can stand.
const RSS_CAP: u64 = 3 << 29;

/// The worker's priority.
const NICE: i32 = 10;

/// `--device`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeviceArg {
    Auto,
    Cpu,
    /// `gpu:NAME` (test-hooks only): that adapter, its device destroyed after the first batch.
    Gpu(String),
}

/// `embed-worker`'s arguments.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkerArgs {
    pub model: String,
    pub dir: PathBuf,
    pub threads: usize,
    pub device: DeviceArg,
    pub device_cache: PathBuf,
    pub idle_ms: Option<u64>,
    pub test: WorkerTest,
}

/// The test-hooks switches (all off in a release build).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct WorkerTest {
    pub park: bool,
    pub crash_once: Option<PathBuf>,
    pub crash_always: bool,
    pub power_root: Option<PathBuf>,
    /// The resident-memory cap in MiB, in place of 1.5 GiB.
    pub rss_cap_mb: Option<u64>,
}

/// Half the cores, at least one: the CPU path's threads.
pub fn threads() -> usize {
    std::thread::available_parallelism().map_or(1, |n| (n.get() / 2).max(1))
}

enum Msg {
    Line(Value),
    Bad(String),
    End,
}

struct Request {
    id: Value,
    query: bool,
    texts: Vec<String>,
    instruction: Option<String>,
}

fn request(v: Value) -> Result<Request, (Value, String)> {
    let id = v.get("id").cloned().unwrap_or(Value::Null);
    let query = match v.get("kind").and_then(Value::as_str) {
        Some("doc") => false,
        Some("query") => true,
        _ => return Err((id, "kind is doc or query".into())),
    };
    let texts = v
        .get("texts")
        .and_then(Value::as_array)
        .and_then(|a| {
            a.iter()
                .map(|t| t.as_str().map(str::to_string))
                .collect::<Option<Vec<_>>>()
        })
        .ok_or((id.clone(), "texts is a list of strings".to_string()))?;
    Ok(Request {
        id,
        query,
        texts,
        instruction: v
            .get("instruction")
            .and_then(Value::as_str)
            .map(str::to_string),
    })
}

/// stdout, one JSON line at a time; a write that fails means the hub is gone.
struct Out(std::io::Stdout);

impl Out {
    fn line(&self, v: &Value) -> bool {
        let mut o = self.0.lock();
        writeln!(o, "{v}").and_then(|()| o.flush()).is_ok()
    }
}

fn cap_address_space() {
    let lim = libc::rlimit {
        rlim_cur: ADDRESS_CAP,
        rlim_max: ADDRESS_CAP,
    };
    // SAFETY: setrlimit reads the struct it is given and changes only this process's limit.
    if unsafe { libc::setrlimit(libc::RLIMIT_AS, &lim) } != 0 {
        eprintln!(
            "embed-worker: the address-space cap was refused: {}",
            std::io::Error::last_os_error()
        );
    }
}

/// This process's peak resident memory in bytes (`VmHWM`); none where `/proc` has none.
fn peak_rss() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let kib = status
        .lines()
        .find_map(|l| l.strip_prefix("VmHWM:"))?
        .trim()
        .strip_suffix("kB")?
        .trim()
        .parse::<u64>()
        .ok()?;
    Some(kib << 10)
}

fn lower_priority() {
    // SAFETY: setpriority changes only this process's nice value.
    unsafe {
        libc::setpriority(libc::PRIO_PROCESS, 0, NICE);
    }
}

/// The device `auto` chooses, and the cache written when it was measured.
fn auto(spec: &'static ModelSpec, args: &WorkerArgs) -> Choice {
    let root = args
        .test
        .power_root
        .clone()
        .unwrap_or_else(|| PathBuf::from(power::SYS));
    let battery = power::on_battery(&root);
    let cached = std::fs::read_to_string(&args.device_cache)
        .ok()
        .and_then(|t| Choice::parse(&t));
    let order = device::order(&adapters());
    let mut probe = |d: &Device| device::probe(spec, &args.dir, d);
    let choice = device::choose(
        spec.id,
        battery,
        &order,
        cached.as_ref(),
        &mut probe,
        args.threads,
    );
    let measured = cached.as_ref().is_none_or(|c| c.key != choice.key);
    if !battery && measured {
        let tmp = args.device_cache.with_extension("json.tmp");
        let written = args
            .device_cache
            .parent()
            .map_or(Ok(()), std::fs::create_dir_all)
            .and_then(|()| std::fs::write(&tmp, choice.to_json()))
            .and_then(|()| std::fs::rename(&tmp, &args.device_cache));
        if let Err(e) = written {
            eprintln!("embed-worker: the device choice was not cached: {e}");
        }
    }
    choice
}

fn device_name(d: &Device) -> (&'static str, String) {
    match d {
        Device::Cpu { threads } => ("cpu", format!("CPU, {threads} threads")),
        Device::Gpu { adapter } => ("gpu", adapter.clone()),
    }
}

/// The worker: what `main` runs for `embed-worker`, before any tokio runtime. Its exit code.
pub fn run(args: WorkerArgs) -> i32 {
    lower_priority();
    let Some(spec) = super::model(&args.model) else {
        eprintln!("embed-worker: no model {:?}", args.model);
        return 2;
    };
    let out = Out(std::io::stdout());
    let cpu = Device::Cpu {
        threads: args.threads.max(1),
    };
    let (mut choice, lose_after_first) = match &args.device {
        DeviceArg::Cpu => (
            Choice {
                device: cpu.clone(),
                key: String::new(),
                why: "the CPU path, as asked".into(),
                usable: true,
            },
            false,
        ),
        DeviceArg::Gpu(name) => (
            Choice {
                device: Device::Gpu {
                    adapter: name.clone(),
                },
                key: String::new(),
                why: "the adapter the test named".into(),
                usable: true,
            },
            true,
        ),
        DeviceArg::Auto => (auto(spec, &args), false),
    };
    let mut embedder = if choice.usable {
        match LocalEmbedder::load(spec, &args.dir, &choice.device) {
            Ok(e) => Some(e),
            Err(e) if choice.device != cpu => {
                choice.why = format!(
                    "{}; {} did not load ({e}): the CPU path",
                    choice.why,
                    device_name(&choice.device).1
                );
                choice.device = cpu.clone();
                LocalEmbedder::load(spec, &args.dir, &cpu)
                    .map_err(|e| {
                        choice.why = format!("{}; the CPU path did not load: {e}", choice.why)
                    })
                    .ok()
            }
            Err(e) => {
                choice.why = format!("{}; the CPU path did not load: {e}", choice.why);
                None
            }
        }
    } else {
        None
    };
    // On the CPU path only: a Vulkan driver maps far more address space than it uses (llvmpipe could not start a
    // thread under the cap), so the GPU path runs uncapped until a measured rule replaces this
    if embedder.is_some() && !matches!(choice.device, Device::Gpu { .. }) {
        cap_address_space();
    }
    let (kind, name) = device_name(&choice.device);
    if !out.line(&json!({"ready": {"device": kind, "name": name, "why": choice.why}})) {
        return 0;
    }

    let (tx, rx) = channel();
    std::thread::spawn(move || {
        for line in BufReader::new(std::io::stdin()).lines() {
            let Ok(line) = line else { break };
            let msg = match serde_json::from_str::<Value>(&line) {
                Ok(v) => Msg::Line(v),
                Err(e) => Msg::Bad(e.to_string()),
            };
            if tx.send(msg).is_err() {
                return;
            }
        }
        let _ = tx.send(Msg::End);
    });

    let mut w = Work {
        spec,
        dir: &args.dir,
        cpu,
        on_gpu: matches!(choice.device, Device::Gpu { .. }),
        lose_after_first,
        lost: false,
        over_cap: false,
        embedder: embedder.take(),
        refusal: choice.why.clone(),
        pacer: Pacer::new(),
        queue: VecDeque::new(),
        rx,
        out,
        test: args.test.clone(),
    };
    let idle = args.idle_ms.map_or(IDLE, Duration::from_millis);
    loop {
        let next = match w.queue.iter().position(|r| r.query) {
            Some(i) => w.queue.remove(i),
            None => w.queue.pop_front(),
        };
        let r = match next {
            Some(r) => r,
            None => match w.rx.recv_timeout(idle) {
                Ok(m) => match w.take(m) {
                    Some(()) => continue,
                    None => return 0,
                },
                Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => return 0,
            },
        };
        if !w.serve(r) {
            return 0;
        }
    }
}

struct Work<'a> {
    spec: &'static ModelSpec,
    dir: &'a Path,
    cpu: Device,
    on_gpu: bool,
    lose_after_first: bool,
    lost: bool,
    /// The GPU path's memory passed its cap: the request in hand is answered with the reason and the worker exits.
    over_cap: bool,
    embedder: Option<LocalEmbedder>,
    /// Why there is no embedder, when there is none.
    refusal: String,
    pacer: Pacer,
    queue: VecDeque<Request>,
    rx: Receiver<Msg>,
    out: Out,
    test: WorkerTest,
}

impl Work<'_> {
    /// One message into the queue; none at the end of stdin.
    fn take(&mut self, m: Msg) -> Option<()> {
        match m {
            Msg::Line(v) => match request(v) {
                Ok(r) => self.queue.push_back(r),
                Err((id, e)) => {
                    self.out.line(&json!({"id": id, "error": e}));
                }
            },
            Msg::Bad(e) => {
                self.out
                    .line(&json!({"id": null, "error": format!("not JSON: {e}")}));
            }
            Msg::End => return None,
        }
        Some(())
    }

    /// Serves one request; false when the hub is gone.
    fn serve(&mut self, r: Request) -> bool {
        if !r.query {
            self.crash_hooks();
        }
        let answer = match self.vectors(&r) {
            Ok(Some(v)) => json!({"id": r.id, "vectors": v}),
            Ok(None) => return false,
            // "exit": the hub starts the next worker at once, not after this one's pipe closes
            Err(e) if self.over_cap => json!({"id": r.id, "error": e, "exit": true}),
            Err(e) => json!({"id": r.id, "error": e}),
        };
        self.out.line(&answer) && !self.over_cap
    }

    fn crash_hooks(&self) {
        if self.test.crash_always {
            std::process::abort();
        }
        if let Some(marker) = &self.test.crash_once
            && !marker.exists()
        {
            let _ = std::fs::write(marker, b"crashed\n");
            std::process::abort();
        }
    }

    /// R's vectors, in order; `Ok(None)` when the hub went away in between.
    fn vectors(&mut self, r: &Request) -> Result<Option<Vec<Vec<f32>>>, String> {
        let Some(e) = self.embedder.as_ref() else {
            return Err(format!("no device can embed: {}", self.refusal));
        };
        let lists: Vec<Vec<u32>> = r
            .texts
            .iter()
            .map(|t| {
                if r.query {
                    e.encode_query(t, r.instruction.as_deref())
                } else {
                    e.encode_doc(t)
                }
            })
            .collect();
        let mut out = Vec::with_capacity(lists.len());
        let (mut at, mut batch_no) = (0, 0u64);
        while at < lists.len() {
            if !r.query {
                if batch_no > 0 && !self.between_batches(batch_no) {
                    return Ok(None);
                }
                if let Some(msg) = self.rss_over_cap() {
                    self.over_cap = true;
                    return Err(msg);
                }
            }
            let lens: Vec<usize> = lists[at..].iter().map(Vec::len).collect();
            let n = if r.query {
                lens.len()
            } else {
                self.pacer.take(&lens)
            };
            let batch = &lists[at..at + n];
            let e = self.embedder.as_mut().expect("checked above");
            match e.embed_ids(batch) {
                Ok(f) => {
                    self.pacer.observe(f.worst_submit);
                    out.extend(f.vectors);
                    at += n;
                    batch_no += 1;
                    if self.lose_after_first && !self.lost {
                        self.lost = true;
                        e.lose_device();
                    }
                }
                Err(EmbedFail::DeviceLost(reason)) if self.on_gpu => {
                    if !self.fall_back(&reason) {
                        return Err(format!(
                            "the GPU was lost ({reason}) and the CPU path did not load"
                        ));
                    }
                }
                Err(EmbedFail::DeviceLost(m) | EmbedFail::Other(m)) => return Err(m),
            }
        }
        Ok(Some(out))
    }

    /// Between two batches of a doc request: the queries that arrived meanwhile are answered first. False when the hub
    /// went away.
    fn between_batches(&mut self, batch_no: u64) -> bool {
        if self.test.park {
            if !self.out.line(&json!({ "parked": batch_no })) {
                return false;
            }
            match self.rx.recv() {
                Ok(m) => {
                    if self.take(m).is_none() {
                        return false;
                    }
                }
                Err(_) => return false,
            }
        }
        while let Ok(m) = self.rx.try_recv() {
            if self.take(m).is_none() {
                return false;
            }
        }
        while let Some(i) = self.queue.iter().position(|q| q.query) {
            let q = self.queue.remove(i).expect("found");
            if !self.serve(q) {
                return false;
            }
        }
        true
    }

    /// On the GPU path, the reason to stop when the peak resident memory is over the cap.
    fn rss_over_cap(&self) -> Option<String> {
        let cap = self.test.rss_cap_mb.map_or(RSS_CAP, |mb| mb << 20);
        let peak = peak_rss().filter(|p| self.on_gpu && *p > cap)?;
        Some(format!(
            "the embed worker's memory ({} MiB) is over its {} MiB cap on the GPU path; it exits and the next request starts a fresh one",
            peak >> 20,
            cap >> 20
        ))
    }

    /// The GPU is gone: the CPU path from now on, said first.
    fn fall_back(&mut self, reason: &str) -> bool {
        self.on_gpu = false;
        self.embedder = None;
        match LocalEmbedder::load(self.spec, self.dir, &self.cpu) {
            Ok(e) => {
                self.embedder = Some(e);
                self.out
                    .line(&json!({"fallback": {"from": "gpu", "reason": reason}}));
                true
            }
            Err(e) => {
                self.refusal =
                    format!("the GPU was lost ({reason}) and the CPU path did not load: {e}");
                false
            }
        }
    }
}

// ---- the hub's side ----

/// What the hub starts a worker with.
#[derive(Clone, Debug)]
pub struct WorkerSpec {
    /// The `ratatoskr` binary.
    pub exe: PathBuf,
    pub model: String,
    /// The model's directory in the cache.
    pub dir: PathBuf,
    /// `<cache>/models/device.json`.
    pub device_cache: PathBuf,
    pub threads: usize,
    pub idle_ms: Option<u64>,
    /// The sysfs root (`/sys`): on battery the worker starts with `--device cpu`.
    pub power_root: PathBuf,
    /// Arguments after the hub's own (test-hooks switches); the last `--device` counts.
    pub test_args: Vec<String>,
}

/// Which worker a request wants.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    Auto,
    Cpu,
}

impl Mode {
    fn arg(self) -> &'static str {
        match self {
            Mode::Auto => "auto",
            Mode::Cpu => "cpu",
        }
    }
}

/// What the hub knows of its worker, for `search/status` and the doctor.
#[derive(Clone, Debug, Default)]
pub struct WorkerFacts {
    pub spawns: u32,
    pub crashes: u32,
    /// The `--device` the last worker was started with.
    pub device_arg: Option<String>,
    /// The last worker's `ready` object.
    pub ready: Option<Value>,
    /// The last fallback it reported.
    pub fallback: Option<Value>,
}

enum Reply {
    Vectors(Vec<Vec<f32>>),
    Error(String),
    Crashed,
}

#[derive(Default)]
struct Pending {
    waiting: HashMap<u64, oneshot::Sender<Reply>>,
    dead: bool,
}

/// A running worker: its stdin, and the answers its reader thread hands out.
struct Live {
    stdin: Option<std::process::ChildStdin>,
    pending: Arc<Mutex<Pending>>,
    mode: Mode,
}

impl Live {
    fn dead(&self) -> bool {
        self.pending.lock().map_or(true, |p| p.dead)
    }
}

/// The hub's handle on its embed worker: started on demand, one request line at a time, answers matched by id, so a
/// query can go while a doc request is in flight. A worker that dies inside a request is started again and the request
/// sent again, once.
pub struct WorkerEmbedder {
    spec: WorkerSpec,
    live: tokio::sync::Mutex<Option<Live>>,
    facts: Arc<Mutex<WorkerFacts>>,
    next: AtomicU64,
}

impl WorkerEmbedder {
    pub fn new(spec: WorkerSpec) -> WorkerEmbedder {
        WorkerEmbedder {
            spec,
            live: tokio::sync::Mutex::new(None),
            facts: Arc::new(Mutex::new(WorkerFacts::default())),
            next: AtomicU64::new(1),
        }
    }

    pub fn model(&self) -> &str {
        &self.spec.model
    }

    pub fn facts(&self) -> WorkerFacts {
        self.facts.lock().map(|f| f.clone()).unwrap_or_default()
    }

    fn power_mode(&self) -> Mode {
        if power::on_battery(&self.spec.power_root) {
            Mode::Cpu
        } else {
            Mode::Auto
        }
    }

    fn spawn(&self, mode: Mode) -> Result<Live, EmbedError> {
        let s = &self.spec;
        let mut cmd = Command::new(&s.exe);
        cmd.arg("embed-worker")
            .args(["--model", &s.model, "--device", mode.arg()])
            .arg("--dir")
            .arg(&s.dir)
            .arg("--threads")
            .arg(s.threads.to_string())
            .arg("--device-cache")
            .arg(&s.device_cache);
        if let Some(ms) = s.idle_ms {
            cmd.arg("--idle-ms").arg(ms.to_string());
        }
        #[cfg(feature = "test-hooks")]
        cmd.arg("--test-power-root").arg(&s.power_root);
        cmd.args(&s.test_args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        let mut child = cmd
            .spawn()
            .map_err(|e| EmbedError(format!("the embed worker did not start: {e}")))?;
        if let Ok(mut f) = self.facts.lock() {
            f.spawns += 1;
            f.device_arg = Some(mode.arg().into());
            f.ready = None;
        }
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().expect("piped");
        let pending = Arc::new(Mutex::new(Pending::default()));
        let (theirs, facts) = (pending.clone(), self.facts.clone());
        // A thread, not a task: it waits on the child's pipe, outside the hub's clock, and ends with the child.
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let Ok(v) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                answer(&theirs, &facts, v);
            }
            if let Ok(mut p) = theirs.lock() {
                p.dead = true;
                for (_, w) in p.waiting.drain() {
                    let _ = w.send(Reply::Crashed);
                }
            }
            let _ = child.wait();
        });
        Ok(Live {
            stdin,
            pending,
            mode,
        })
    }

    /// One request, its worker started first when none runs or the running one is of another mode (MODE none: any
    /// running worker will do). A crash inside the request starts another worker and sends it again, once.
    async fn call(
        &self,
        query: bool,
        texts: &[String],
        instruction: Option<&str>,
        mode: Option<Mode>,
    ) -> Result<Vec<Vec<f32>>, EmbedError> {
        let id = self.next.fetch_add(1, Ordering::SeqCst);
        let line = json!({"id": id, "kind": if query { "query" } else { "doc" }, "texts": texts, "instruction": instruction})
            .to_string()
            + "\n";
        for _ in 0..2 {
            let reply = {
                let mut live = self.live.lock().await;
                if live
                    .as_ref()
                    .is_some_and(|l| l.dead() || mode.is_some_and(|m| m != l.mode))
                {
                    *live = None; // its stdin closes: that worker exits after what it is doing
                }
                if live.is_none() {
                    *live = Some(self.spawn(mode.unwrap_or_else(|| self.power_mode()))?);
                }
                let l = live.as_mut().expect("started");
                let (tx, rx) = oneshot::channel();
                if let Ok(mut p) = l.pending.lock() {
                    p.waiting.insert(id, tx);
                }
                let sent = l.stdin.as_mut().is_some_and(|s| {
                    s.write_all(line.as_bytes())
                        .and_then(|()| s.flush())
                        .is_ok()
                });
                if !sent && let Ok(mut p) = l.pending.lock() {
                    p.dead = true;
                    if let Some(w) = p.waiting.remove(&id) {
                        let _ = w.send(Reply::Crashed);
                    }
                }
                rx
            };
            match crate::clock::real(reply).await {
                Ok(Reply::Vectors(v)) => return Ok(v),
                Ok(Reply::Error(e)) => return Err(EmbedError(e)),
                Ok(Reply::Crashed) | Err(_) => {
                    if let Ok(mut f) = self.facts.lock() {
                        f.crashes += 1;
                    }
                    tracing::warn!(
                        "search: the embed worker of {} crashed in a request",
                        self.spec.model
                    );
                }
            }
        }
        Err(EmbedError(format!(
            "the embed worker of {} crashed twice in one request",
            self.spec.model
        )))
    }

    /// Document vectors. On battery the worker is the CPU path's, unless OVERRIDING (`search/index` with `now`), which
    /// takes `--device auto`, so the cached device.
    pub async fn embed_docs(
        &self,
        texts: &[String],
        overriding: bool,
    ) -> Result<Vec<Vec<f32>>, EmbedError> {
        let mode = if overriding {
            Mode::Auto
        } else {
            self.power_mode()
        };
        self.call(false, texts, None, Some(mode)).await
    }

    /// A query's vector: a running worker answers it, whatever its device; otherwise one is started by the power rule
    /// (on battery the CPU path, so a sleeping dGPU stays asleep).
    pub async fn embed_query(
        &self,
        q: &str,
        instruction: Option<&str>,
    ) -> Result<Vec<f32>, EmbedError> {
        let mut v = self.call(true, &[q.to_string()], instruction, None).await?;
        v.pop()
            .ok_or_else(|| EmbedError("the worker gave no vector".into()))
    }

    /// Ends the worker (its stdin closes): a power change, or the project's end.
    pub async fn close(&self) {
        *self.live.lock().await = None;
    }
}

fn answer(pending: &Mutex<Pending>, facts: &Mutex<WorkerFacts>, v: Value) {
    if let Some(r) = v.get("ready") {
        if let Ok(mut f) = facts.lock() {
            f.ready = Some(r.clone());
        }
        return;
    }
    if let Some(fb) = v.get("fallback") {
        tracing::warn!("search: the embed worker fell back to the CPU path: {fb}");
        if let Ok(mut f) = facts.lock() {
            f.fallback = Some(fb.clone());
        }
        return;
    }
    let Some(id) = v.get("id").and_then(Value::as_u64) else {
        return;
    };
    if v.get("exit").and_then(Value::as_bool) == Some(true)
        && let Ok(mut p) = pending.lock()
    {
        p.dead = true; // the worker is leaving: the next request starts another
    }
    let reply = match (v.get("vectors"), v.get("error")) {
        (Some(vs), _) => serde_json::from_value::<Vec<Vec<f32>>>(vs.clone()).map_or_else(
            |e| Reply::Error(format!("bad vectors: {e}")),
            Reply::Vectors,
        ),
        (None, Some(e)) => Reply::Error(e.as_str().unwrap_or("error").to_string()),
        (None, None) => Reply::Error("an answer with neither vectors nor error".into()),
    };
    if let Ok(mut p) = pending.lock()
        && let Some(w) = p.waiting.remove(&id)
    {
        let _ = w.send(reply);
    }
}

impl Embedder for WorkerEmbedder {
    fn embed<'a>(
        &'a self,
        texts: &'a [String],
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        Box::pin(self.embed_docs(texts, false))
    }

    fn model(&self) -> &str {
        &self.spec.model
    }
}
