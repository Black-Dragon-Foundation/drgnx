//! The hub's side of the trace supervisor: one hand-off socket per traced session (`trace.sock` in its session dir),
//! the offers it answers, the opens it keeps, and the steps it gives to the presence model and the timeline.

use super::*;
use crate::dispatch::Caller;
use crate::front::Front;
use crate::work::presence::{Live, PresenceEv};
use gleipnir::trace::{self as gt, Handed, ListenOptions, Offer, Scope};
use std::collections::{HashMap, HashSet};
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::time::Instant;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// How a session's shell steps are traced.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TraceMode {
    /// Each Bash call through the wrapper (Claude Code's `CLAUDE_CODE_SHELL_PREFIX`).
    PerStep,
    /// The agent's whole process tree (Codex, Gemini: opt-in, `agents-trace-opens`).
    Tree,
    /// Not traced; its shell steps carry the label, if there is one.
    Off(Option<String>),
}

impl TraceMode {
    /// What a launch asks Gleipnir for.
    pub fn scope(&self) -> Option<Scope> {
        match self {
            TraceMode::PerStep => Some(Scope::Step),
            TraceMode::Tree => Some(Scope::Tree),
            TraceMode::Off(_) => None,
        }
    }

    /// The mode of a session of PROVIDER (`claude`, `codex`, `gemini`, by the profile's kind) when `agents-trace-opens`
    /// lists TRACED: Claude Code per step, the others over their whole tree; off with its label when not listed, and
    /// on macOS (no tracer).
    pub fn of(provider: Option<&str>, traced: &[String], macos: bool) -> TraceMode {
        let Some(p) = provider else {
            return TraceMode::Off(None);
        };
        if macos {
            return TraceMode::Off(Some(LABEL_MACOS.into()));
        }
        if !traced.iter().any(|t| t == p) {
            let name = match p {
                "claude" => "Claude Code",
                "codex" => "Codex",
                "gemini" => "Gemini",
                other => other,
            };
            return TraceMode::Off(Some(label_off(name)));
        }
        if p == "claude" {
            TraceMode::PerStep
        } else {
            TraceMode::Tree
        }
    }
}

/// The real probe: true names from the file system, git's ignore rules from `git check-ignore`, cached per path (at
/// most [`IGNORED_MAX`]; the cache is emptied when full).
#[derive(Default)]
pub struct FsProbe {
    ignored: HashMap<PathBuf, bool>,
}

const IGNORED_MAX: usize = 65_536;
/// The most failed probes one step remembers.
const MISSES_MAX: usize = 65_536;

impl Probe for FsProbe {
    fn real(&mut self, p: &Path) -> Option<PathBuf> {
        std::fs::canonicalize(p).ok()
    }

    fn ignored(&mut self, root: &Path, paths: &[PathBuf]) -> BTreeSet<PathBuf> {
        let ask: Vec<PathBuf> = paths
            .iter()
            .filter(|p| !self.ignored.contains_key(*p))
            .cloned()
            .collect();
        if !ask.is_empty() {
            let yes = check_ignore(root, &ask);
            if self.ignored.len() + ask.len() > IGNORED_MAX {
                self.ignored.clear();
            }
            for p in ask {
                let i = yes.contains(&p);
                self.ignored.insert(p, i);
            }
        }
        paths
            .iter()
            .filter(|p| self.ignored.get(*p) == Some(&true))
            .cloned()
            .collect()
    }
}

/// The PATHS git ignores in ROOT's repository (none when ROOT is not in one, or git fails).
fn check_ignore(root: &Path, paths: &[PathBuf]) -> BTreeSet<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    use std::process::{Command, Stdio};
    let child = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["check-ignore", "-z", "--stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut child) = child else {
        return BTreeSet::new();
    };
    let mut input = Vec::new();
    for p in paths {
        input.extend_from_slice(p.as_os_str().as_bytes());
        input.push(0);
    }
    // written from a thread: git answers as it reads, and a full stdout pipe would stop it
    let stdin = child.stdin.take();
    let writer = std::thread::spawn(move || {
        if let Some(mut s) = stdin {
            let _ = s.write_all(&input);
        }
    });
    let mut out = Vec::new();
    if let Some(mut s) = child.stdout.take() {
        let _ = s.read_to_end(&mut out);
    }
    let _ = writer.join();
    let _ = child.wait();
    out.split(|b| *b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| PathBuf::from(std::ffi::OsStr::from_bytes(s)))
        .collect()
}

/// One session's tracing.
pub struct SessionTrace {
    sid: String,
    mode: TraceMode,
    core: Mutex<Core>,
    next: AtomicU64,
    rules: Rules,
    probe: Mutex<FsProbe>,
    /// The heads its worktree does not trace any more (they went over the budget).
    learned: Arc<Mutex<BTreeSet<String>>>,
    presence: Arc<Live>,
    writer: crate::coord::Writer,
    front: Weak<Front>,
    socket: Option<PathBuf>,
    server: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

/// Every session's tracing, and each worktree's learned skips.
#[derive(Default)]
pub struct Traces {
    sessions: Mutex<HashMap<String, Arc<SessionTrace>>>,
    learned: Mutex<HashMap<PathBuf, Arc<Mutex<BTreeSet<String>>>>>,
}

impl Traces {
    /// Session SID's tracing in MODE, its opens kept under DIR (the session's folder). A traced mode binds and serves
    /// `trace.sock` in RUN (the session dir) at once, before the agent starts: call it inside the runtime.
    pub fn open(
        &self,
        front: &Front,
        sid: &str,
        dir: &Path,
        run: &Path,
        mode: TraceMode,
    ) -> io::Result<Arc<SessionTrace>> {
        self.end(sid);
        let root = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
        let home = std::env::var_os("HOME").map(PathBuf::from);
        let learned = lock(&self.learned).entry(root.clone()).or_default().clone();
        let socket = mode
            .scope()
            .map(|_| run.join(runstav::paths::SESSION_TRACE_SOCKET));
        let st = Arc::new(SessionTrace {
            sid: sid.to_string(),
            mode,
            core: Mutex::new(Core::new()),
            next: AtomicU64::new(1),
            rules: Rules::new(vec![root], home.as_deref(), &[]),
            probe: Mutex::new(FsProbe::default()),
            learned,
            presence: front.core.presence.clone(),
            writer: front.writer.clone(),
            front: front.tool_hub.front.get().cloned().unwrap_or_default(),
            socket: socket.clone(),
            server: Mutex::new(None),
        });
        if let Some(sock) = &socket {
            let listener = crate::sessions::bind_socket(sock)?;
            let me = st.clone();
            *lock(&st.server) = Some(tokio::spawn(serve(listener, me)));
        }
        lock(&self.sessions).insert(sid.to_string(), st.clone());
        Ok(st)
    }

    pub fn get(&self, sid: &str) -> Option<Arc<SessionTrace>> {
        lock(&self.sessions).get(sid).cloned()
    }

    /// Session SID ended: its socket stops being served and is removed (a command still traced finishes its step).
    pub fn end(&self, sid: &str) {
        if let Some(st) = lock(&self.sessions).remove(sid) {
            if let Some(h) = lock(&st.server).take() {
                h.abort();
            }
            if let Some(s) = &st.socket {
                let _ = std::fs::remove_file(s);
            }
        }
    }

    /// Session SID's shell step STEP (its command COMMAND) closed AT: what its traced command opened goes out once
    /// the trace has ended too; a session not traced labels the step.
    pub async fn step_closed(&self, sid: &str, step: i64, command: String, at: f64) {
        let Some(st) = self.get(sid) else {
            return;
        };
        if let TraceMode::Off(label) = &st.mode {
            if let Some(l) = label {
                st.label(step, l.clone());
            }
            return;
        }
        let _ = tokio::task::spawn_blocking(move || {
            st.apply(TraceEv::StepClosed { step, command, at })
        })
        .await;
    }
}

/// Accept on SESSION's socket until it ends; each offer is answered off the async threads.
async fn serve(listener: tokio::net::UnixListener, st: Arc<SessionTrace>) {
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            return;
        };
        let Ok(stream) = stream.into_std() else {
            continue;
        };
        let open = st.open_command();
        let me = st.clone();
        tokio::task::spawn_blocking(move || {
            if stream.set_nonblocking(false).is_ok() {
                me.offered(stream, open);
            }
        });
    }
}

impl SessionTrace {
    /// The command of the session's shell step running now.
    fn open_command(&self) -> Option<String> {
        let front = self.front.upgrade()?;
        front.core.agents.find(&self.sid).ok()?.open_shell_command()
    }

    fn apply(&self, ev: TraceEv) {
        let out = lock(&self.core).apply(ev);
        for e in out {
            self.emit(e);
        }
    }

    /// A step's opens, after the rules, to the presence model; its label to its step detail.
    fn emit(&self, e: Emit) {
        let files = touches(&e.seen, &self.rules, &mut *lock(&self.probe));
        if !files.is_empty() {
            self.presence.apply(PresenceEv::Step {
                session: self.sid.clone(),
                step: e.step,
                at: e.at,
                files,
            });
        }
        if let Some(l) = e.label {
            self.label(e.step, l);
        }
    }

    /// STEP's detail says LABEL (origin `opened`), unless the step has a detail of its own.
    fn label(&self, step: i64, label: String) {
        let writer = self.writer.clone();
        let Ok(rt) = tokio::runtime::Handle::try_current() else {
            return;
        };
        rt.spawn(async move {
            let caller = Caller {
                class: runstav::registry::Class::Service,
                sid: None,
                job: None,
                conn_id: 0,
            };
            let r = writer
                .write(&caller, "work/trace", move |tx| {
                    let has: i64 = tx.sql().query_row(
                        "select count(*) from step_detail where step = ?1",
                        [step],
                        |r| r.get(0),
                    )?;
                    if has == 0 {
                        norn::write::work::put_step_detail(
                            tx,
                            norn::write::work::StepDetail {
                                step,
                                kind: Some("execute".into()),
                                title: Some(label),
                                origin: "opened".into(),
                                ..Default::default()
                            },
                        )?;
                    }
                    Ok(())
                })
                .await;
            if let Err(e) = r {
                tracing::warn!("a shell step's trace label was not recorded: {e}");
            }
        });
    }

    /// One hand-off (blocking): answered by scope and mode; an offer of the wrong kind is skipped.
    fn offered(&self, stream: std::os::unix::net::UnixStream, open: Option<String>) {
        let Ok(offer) = gt::accept(stream) else {
            return;
        };
        match (offer.hello.scope, &self.mode) {
            (Scope::Step, TraceMode::PerStep) => self.per_step(offer, open),
            (Scope::Tree, TraceMode::Tree) => self.tree(offer),
            _ => {
                let _ = offer.skip();
            }
        }
    }

    /// Claude Code's Bash call: traced unless another shell step is open (a hook or a status line through the prefix
    /// while a step runs) or its heads are skipped. The hub may not have read the step's tool call yet when the wrapper
    /// offers, so with no step open the offer is traced as given and matched to its step when that closes.
    fn per_step(&self, offer: Offer, open: Option<String>) {
        let command = match open {
            Some(c) if command_matches(&offer.hello.command, &c) => c,
            Some(_) => {
                let _ = offer.skip();
                return;
            }
            None => offer.hello.command.clone(),
        };
        let trace = self.next.fetch_add(1, Ordering::Relaxed);
        if skip_head(&command, &lock(&self.learned)).is_some() {
            self.apply(TraceEv::Started {
                trace,
                command,
                tree: false,
                label: Some(LABEL_BUILD.into()),
            });
            let _ = offer.skip();
            return;
        }
        self.apply(TraceEv::Started {
            trace,
            command: command.clone(),
            tree: false,
            label: None,
        });
        let fd = match offer.trace() {
            Ok(Handed::Listener(fd)) => fd,
            _ => return self.apply(TraceEv::Ended { trace }),
        };
        let (tx, rx) = std::sync::mpsc::channel();
        let Ok(listener) = gt::listen(fd, ListenOptions::default(), tx) else {
            return self.apply(TraceEv::Ended { trace });
        };
        let begun = Instant::now();
        let mut misses = HashSet::new();
        let mut over = false;
        // the channel ends with the answering thread: every process of the command is gone
        for o in rx.iter() {
            if over {
                continue;
            }
            let elapsed = u64::try_from(begun.elapsed().as_nanos()).unwrap_or(u64::MAX);
            if over_budget(elapsed, listener.notifications(), listener.answering_ns()) {
                over = true;
                listener.set_reading(false);
                lock(&self.learned).extend(heads(&command));
                self.apply(TraceEv::Over { trace });
                continue;
            }
            if let Some(path) = self.worth_keeping(&o, &mut misses) {
                self.apply(TraceEv::Opened {
                    trace,
                    path,
                    write: o.writes(),
                    parallel: 1,
                });
            }
        }
        let _ = listener.join();
        self.apply(TraceEv::Ended { trace });
    }

    /// Codex's or Gemini's whole tree: every open but the CLI's own goes to the shell step open when it arrives.
    fn tree(&self, offer: Offer) {
        let cli = offer.peer_pid.and_then(|p| u32::try_from(p).ok());
        let fd = match offer.trace() {
            Ok(Handed::Listener(fd)) => fd,
            _ => return,
        };
        let (tx, rx) = std::sync::mpsc::channel();
        let opts = ListenOptions {
            ignore_tgid: cli,
            ..ListenOptions::default()
        };
        let Ok(listener) = gt::listen(fd, opts, tx) else {
            return;
        };
        let mut misses = HashSet::new();
        for o in rx.iter() {
            // the session runs one shell step at a time as the hub sees it; several would each be labelled
            let open: Vec<String> = self.open_command().into_iter().collect();
            let Some(path) = self.worth_keeping(&o, &mut misses) else {
                continue;
            };
            for command in &open {
                let found = lock(&self.core).tree_trace(command);
                let trace = match found {
                    Some(t) => t,
                    None => {
                        let t = self.next.fetch_add(1, Ordering::Relaxed);
                        self.apply(TraceEv::Started {
                            trace: t,
                            command: command.clone(),
                            tree: true,
                            label: None,
                        });
                        t
                    }
                };
                self.apply(TraceEv::Opened {
                    trace,
                    path: path.clone(),
                    write: o.writes(),
                    parallel: open.len(),
                });
            }
        }
        let _ = listener.join();
    }

    /// O's path, unless it can be dropped now: a system or toolchain path, or a read of a file that is not there (a
    /// failed probe, remembered for the step). Writes are looked at when their step closes.
    fn worth_keeping(&self, o: &gt::Open, misses: &mut HashSet<PathBuf>) -> Option<PathBuf> {
        let p = clean(&o.full()?);
        if self.rules.never.iter().any(|n| p.starts_with(n)) {
            return None;
        }
        if !o.writes() {
            if misses.contains(&p) {
                return None;
            }
            if std::fs::symlink_metadata(&p).is_err() {
                if misses.len() < MISSES_MAX {
                    misses.insert(p);
                }
                return None;
            }
        }
        Some(p)
    }
}
