//! One debug session (spec §3.3): the launch sequence, stops and their epochs, controls, restarts, the reverse
//! requests handed up, the stop sequence and one end.
//!
//! A session is one task that owns the adapter's connection ([`vor::Client`]) and its process ([`Proc`]). The hub
//! talks to it through a [`Handle`] and hears from it through [`Update`]s, in order. Its waits read the hub's clock.
//!
//! - **Launch:** `initialize`, then `launch` / `attach` without waiting for its answer; on `initialized` every source's
//!   breakpoints, the exception filters and `configurationDone`. The launch answer may come before or after.
//! - **A stop** opens a new epoch: `threads`, `stackTrace` (20 frames, more on demand), `scopes` of the top frame and
//!   `variables` of each scope that is not `expensive`, published as one [`Stop`]. A `variablesReference` of an older
//!   epoch is refused here and never reaches the adapter. `invalidated` fetches its areas again in the same epoch.
//! - **The stop sequence:** a launch session sends `terminate` (when the adapter has it) and waits 2 s for
//!   `terminated`; then `disconnect` and 2 s; then SIGTERM, 1 s, SIGKILL. An attach session sends `disconnect` with
//!   `terminateDebuggee: false`. The adapter's process is always waited for.
//! - **The end** ([`End`]) comes once: after a stop, `terminated`, `exited`, the adapter's death, a failed launch, or
//!   the last handle dropped.

use crate::clock;
use serde_json::{Value, json};
use std::future::Future;
use std::pin::Pin;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use vor::{Client, Incoming};

/// How long `terminate` and `disconnect` each have before the next step of a stop.
pub const POLITE: Duration = Duration::from_secs(2);
/// How long SIGTERM has before SIGKILL.
pub const TERM_GRACE: Duration = Duration::from_secs(1);
/// Frames per `stackTrace` page.
pub const FRAMES_PAGE: i64 = 20;

/// A signal for the adapter's process (its process group).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sig {
    Term,
    Kill,
}

/// The adapter's process: signals, and its end.
pub trait Proc: Send + Sync + 'static {
    fn signal(&mut self, sig: Sig);
    /// Resolves once the process has exited and was reaped (at once for none). Cancel-safe.
    fn wait(&mut self) -> Pin<Box<dyn Future<Output = ()> + Send + '_>>;
    /// The end of what it wrote to stderr (none: nothing kept).
    fn stderr_tail(&self) -> String {
        String::new()
    }
}

/// No process of ours (a `debugServer` someone else started).
pub struct NoProc;

impl Proc for NoProc {
    fn signal(&mut self, _: Sig) {}
    fn wait(&mut self) -> Pin<Box<dyn Future<Output = ()> + Send + '_>> {
        Box::pin(async {})
    }
}

impl Proc for draugr::Child {
    fn signal(&mut self, sig: Sig) {
        let s = match sig {
            Sig::Term => libc::SIGTERM,
            Sig::Kill => libc::SIGKILL,
        };
        // the adapter's process group (its pid is the group's id)
        let _ = draugr::Signaller::kill(&draugr::RealSignaller, -self.id(), s);
    }
    fn wait(&mut self) -> Pin<Box<dyn Future<Output = ()> + Send + '_>> {
        Box::pin(async move {
            let _ = draugr::Child::wait(self).await;
        })
    }
    fn stderr_tail(&self) -> String {
        draugr::Child::stderr_tail(self)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Request {
    Launch,
    Attach,
}

impl Request {
    fn command(self) -> &'static str {
        match self {
            Request::Launch => "launch",
            Request::Attach => "attach",
        }
    }
}

/// One source's breakpoints, as `setBreakpoints` sends them (`SourceBreakpoint` objects).
#[derive(Clone, Debug, PartialEq)]
pub struct SourceBps {
    pub path: String,
    pub breakpoints: Vec<Value>,
}

/// What a session starts with: the resolved configuration.
#[derive(Clone, Debug)]
pub struct Start {
    pub name: String,
    /// The adapter's type (`initialize`'s `adapterID`).
    pub adapter_id: String,
    pub request: Request,
    /// `launch` / `attach`'s arguments.
    pub arguments: Value,
    pub breakpoints: Vec<SourceBps>,
    /// The function breakpoints (`FunctionBreakpoint`s).
    pub functions: Vec<Value>,
    /// The exception filters chosen; none: the adapter's defaults.
    pub exception_filters: Option<Vec<String>>,
}

impl Start {
    /// The next start of a session whose adapter ended it with `terminated {restart: VALUE}`: VALUE goes back as
    /// `__restart` (null: a plain new start).
    pub fn restart_with(&mut self, value: Value) {
        if value.is_null() {
            return;
        }
        if let Value::Object(m) = &mut self.arguments {
            m.insert("__restart".into(), value);
        }
    }
}

/// A control from the toolbar or keys.
#[derive(Clone, Debug, PartialEq)]
pub enum Op {
    Continue {
        thread: Option<i64>,
    },
    Pause {
        thread: Option<i64>,
    },
    Next {
        thread: Option<i64>,
    },
    StepIn {
        thread: Option<i64>,
    },
    StepOut {
        thread: Option<i64>,
    },
    Restart,
    /// Stop: the stop sequence. `kill_debuggee`: an attach session's **Stop and Kill Debuggee** (`Some(true)`).
    Stop {
        kill_debuggee: Option<bool>,
    },
    /// Disconnect: an attach-style end whatever the request (the debuggee keeps running when the adapter allows it).
    Disconnect,
    /// Show FRAME of THREAD: its scopes and variables, same epoch.
    Select {
        thread: Option<i64>,
        frame: i64,
    },
}

/// A scope of the selected frame, with its first page of variables (`None`: expensive, not fetched yet).
#[derive(Clone, Debug, PartialEq)]
pub struct ScopeVars {
    pub scope: Value,
    pub variables: Option<Vec<Value>>,
}

/// A stop, as published: everything the views, the gutter and the toolbar show of it.
#[derive(Clone, Debug, PartialEq)]
pub struct Stop {
    pub epoch: u64,
    pub thread: i64,
    pub reason: String,
    pub description: Option<String>,
    pub all_threads: bool,
    pub threads: Vec<Value>,
    /// The stopped thread's frames fetched so far.
    pub frames: Vec<Value>,
    pub total_frames: Option<i64>,
    /// The selected frame's id.
    pub frame: i64,
    pub scopes: Vec<ScopeVars>,
}

/// How a session ended.
#[derive(Clone, Debug, PartialEq)]
pub struct End {
    pub reason: String,
    pub exit_code: Option<i64>,
    /// Start again: `Some(value)` for `__restart` (null for a plain new start, after a restart without the request).
    pub restart: Option<Value>,
}

/// What a session tells the hub, in order.
#[derive(Debug)]
pub enum Update {
    /// `initialize`'s answer.
    Caps(Value),
    /// Running (after the launch, a `continued`, a step).
    Running {
        thread: Option<i64>,
        all: bool,
    },
    Stopped(Stop),
    /// `setBreakpoints`' answer for PATH: the adapter's `Breakpoint`s, in the order sent.
    Breakpoints {
        path: String,
        breakpoints: Vec<Value>,
    },
    /// An event the session does not handle itself (`output`, `breakpoint`, `module`, `process`, `progress*`, …).
    Event {
        event: String,
        body: Value,
    },
    /// `runInTerminal`: open a terminal; answer its pid.
    RunInTerminal {
        arguments: Value,
        reply: oneshot::Sender<Result<i64, String>>,
    },
    /// `startDebugging`: start a child session.
    StartDebugging {
        arguments: Value,
        reply: oneshot::Sender<Result<(), String>>,
    },
    /// The end, once; nothing follows.
    Ended(End),
}

enum Cmd {
    Op(Op, oneshot::Sender<Result<(), String>>),
    Variables {
        epoch: u64,
        reference: i64,
        reply: oneshot::Sender<Result<Vec<Value>, String>>,
    },
    MoreFrames {
        epoch: u64,
        thread: i64,
        reply: oneshot::Sender<Result<Vec<Value>, String>>,
    },
    Request {
        command: String,
        arguments: Value,
        reply: oneshot::Sender<Result<Value, String>>,
    },
}

/// The hub's side of a session. Dropping the last one stops it.
#[derive(Clone)]
pub struct Handle {
    tx: mpsc::UnboundedSender<Cmd>,
}

/// What a request to a session that has ended gets.
pub const ENDED: &str = "the session has ended";

impl Handle {
    async fn ask<T>(
        &self,
        make: impl FnOnce(oneshot::Sender<Result<T, String>>) -> Cmd,
    ) -> Result<T, String> {
        let (tx, rx) = oneshot::channel();
        self.tx.send(make(tx)).map_err(|_| ENDED.to_owned())?;
        rx.await.unwrap_or_else(|_| Err(ENDED.to_owned()))
    }

    /// Carry out OP; resolves when the adapter answered (a stop: when the session has ended).
    pub async fn op(&self, op: Op) -> Result<(), String> {
        self.ask(|r| Cmd::Op(op, r)).await
    }

    /// The variables of REFERENCE, from the stop EPOCH (refused unless it is the current one).
    pub async fn variables(&self, epoch: u64, reference: i64) -> Result<Vec<Value>, String> {
        self.ask(|reply| Cmd::Variables {
            epoch,
            reference,
            reply,
        })
        .await
    }

    /// The next page of THREAD's frames in stop EPOCH.
    pub async fn more_frames(&self, epoch: u64, thread: i64) -> Result<Vec<Value>, String> {
        self.ask(|reply| Cmd::MoreFrames {
            epoch,
            thread,
            reply,
        })
        .await
    }

    /// Any other request (`evaluate`, `completions`, `source`, `setBreakpoints` …): its answer's body.
    pub async fn request(&self, command: &str, arguments: Value) -> Result<Value, String> {
        let command = command.to_owned();
        self.ask(|reply| Cmd::Request {
            command,
            arguments,
            reply,
        })
        .await
    }

    pub fn is_ended(&self) -> bool {
        self.tx.is_closed()
    }
}

/// Start a session over CLIENT (already connected; INCOMING is what the adapter sends on its own) with the adapter's
/// process PROC; updates go to UPDATES.
pub fn spawn(
    start: Start,
    client: Client,
    incoming: mpsc::UnboundedReceiver<Incoming>,
    proc: Box<dyn Proc>,
    updates: mpsc::UnboundedSender<Update>,
) -> Handle {
    let (tx, rx) = mpsc::unbounded_channel();
    let s = Session {
        start,
        client,
        incoming,
        proc,
        up: updates,
        caps: Value::Null,
        epoch: 0,
        stop: None,
        exit_code: None,
        stopped_thread: None,
    };
    clock::spawn("debug:session", s.run(rx));
    Handle { tx }
}

struct Session {
    start: Start,
    client: Client,
    incoming: mpsc::UnboundedReceiver<Incoming>,
    proc: Box<dyn Proc>,
    up: mpsc::UnboundedSender<Update>,
    caps: Value,
    epoch: u64,
    stop: Option<Stop>,
    exit_code: Option<i64>,
    stopped_thread: Option<i64>,
}

/// What ended the main loop.
enum Ending {
    /// The protocol is over (the adapter's input is closed): wait for the process, escalating.
    Gone(String),
    /// Run the stop sequence first (from a terminate step, or from disconnect).
    Stop {
        reason: String,
        terminate: bool,
        terminate_debuggee: bool,
        restart: Option<Value>,
        /// The session failed (not a stop anyone asked for): the adapter's stderr says why.
        failed: bool,
    },
}

fn msg(e: vor::Error) -> String {
    match e {
        vor::Error::Failed {
            message, command, ..
        } if !message.is_empty() => format!("{command}: {message}"),
        e => e.to_string(),
    }
}

impl Session {
    fn cap(&self, name: &str) -> bool {
        self.caps
            .get(name)
            .and_then(Value::as_bool)
            .unwrap_or(false)
    }

    fn send(&self, u: Update) {
        let _ = self.up.send(u);
    }

    async fn run(mut self, mut cmds: mpsc::UnboundedReceiver<Cmd>) {
        let ending = self.main(&mut cmds).await;
        let mut restart = None;
        let (reason, failed) = match ending {
            Ending::Gone(why) => {
                self.reap().await;
                (why, true)
            }
            Ending::Stop {
                reason,
                terminate,
                terminate_debuggee,
                restart: r,
                failed,
            } => {
                restart = r;
                self.stop_sequence(terminate, terminate_debuggee).await;
                (reason, failed)
            }
        };
        // a session that failed: what the adapter last said says why
        let tail = if failed {
            self.proc.stderr_tail()
        } else {
            String::new()
        };
        let tail = tail.trim();
        let reason = if tail.is_empty() {
            reason
        } else {
            let cut = tail.char_indices().rev().nth(499).map_or(0, |(i, _)| i);
            format!("{reason}; the adapter said: {}", &tail[cut..])
        };
        // every queued control is told
        cmds.close();
        while let Ok(c) = cmds.try_recv() {
            refuse(c);
        }
        let end = End {
            reason,
            exit_code: self.exit_code,
            restart,
        };
        self.send(Update::Ended(end));
    }

    async fn main(&mut self, cmds: &mut mpsc::UnboundedReceiver<Cmd>) -> Ending {
        let init = json!({
            "clientID": "drgnx",
            "clientName": "drgnx",
            "adapterID": self.start.adapter_id,
            "locale": "en",
            "linesStartAt1": true,
            "columnsStartAt1": true,
            "pathFormat": "path",
            "supportsVariableType": true,
            "supportsVariablePaging": true,
            "supportsRunInTerminalRequest": true,
            "supportsStartDebuggingRequest": true,
            "supportsProgressReporting": true,
            "supportsInvalidatedEvent": true,
            "supportsANSIStyling": true,
            "supportsMemoryReferences": false,
        });
        let pending = self.client.request("initialize", init);
        let caps = tokio::select! {
            r = pending => r,
            g = self.until_gone() => return g,
        };
        match caps {
            Ok(c) => {
                self.caps = c.clone();
                self.send(Update::Caps(c));
            }
            Err(e) => return self.fail(format!("the adapter did not start: {}", msg(e))),
        }
        let mut launch = Some(
            self.client
                .request(self.start.request.command(), self.start.arguments.clone()),
        );
        let mut configured = false;
        loop {
            tokio::select! {
                biased;
                m = self.incoming.recv() => match m {
                    None => return Ending::Gone("the debug adapter exited".into()),
                    Some(Incoming::Bad(why)) => tracing::debug!(target: "drgnx::debug", "a bad message: {why}"),
                    Some(Incoming::Request(r)) => self.reverse(r),
                    Some(Incoming::Event { event, body }) => {
                        if event == "initialized" && !configured {
                            configured = true;
                            if let Err(e) = self.configure().await {
                                return self.fail(e);
                            }
                            if launch.is_none() {
                                self.send(Update::Running { thread: None, all: true });
                            }
                        } else if let Some(end) = self.event(&event, body).await {
                            return end;
                        }
                    }
                },
                r = async { launch.as_mut().unwrap().await }, if launch.is_some() => {
                    launch = None;
                    match r {
                        Err(e) => return self.fail(msg(e)),
                        Ok(_) => if configured && self.stop.is_none() {
                            self.send(Update::Running { thread: None, all: true });
                        },
                    }
                }
                c = cmds.recv() => match c {
                    None => return self.stopping("the session was closed".into(), None),
                    Some(c) => if let Some(end) = self.command(c).await {
                        return end;
                    },
                },
            }
        }
    }

    /// The ending for an error before or during the launch: disconnect, as after any end.
    fn fail(&self, why: String) -> Ending {
        Ending::Stop {
            reason: why,
            terminate: false,
            terminate_debuggee: self.start.request == Request::Launch,
            restart: None,
            failed: true,
        }
    }

    /// The ending for a stop the user asked for.
    fn stopping(&self, reason: String, kill_debuggee: Option<bool>) -> Ending {
        let launch = self.start.request == Request::Launch;
        Ending::Stop {
            reason,
            terminate: launch && self.cap("supportsTerminateRequest"),
            terminate_debuggee: kill_debuggee.unwrap_or(launch),
            restart: None,
            failed: false,
        }
    }

    /// Waits for the connection to end (used where a request could otherwise wait forever).
    async fn until_gone(&mut self) -> Ending {
        loop {
            match self.incoming.recv().await {
                None => return Ending::Gone("the debug adapter exited".into()),
                Some(Incoming::Request(r)) => drop(r),
                Some(_) => {}
            }
        }
    }

    async fn configure(&mut self) -> Result<(), String> {
        for s in self.start.breakpoints.clone() {
            let r = self
                .client
                .request(
                    "setBreakpoints",
                    json!({"source": {"path": s.path},
                           "breakpoints": super::breakpoints::fit(&s.breakpoints, &self.caps)}),
                )
                .await;
            match r {
                Ok(body) => self.send(Update::Breakpoints {
                    path: s.path,
                    breakpoints: arr(&body, "breakpoints"),
                }),
                Err(vor::Error::Closed(why)) => return Err(why),
                Err(e) => {
                    tracing::debug!(target: "drgnx::debug", "setBreakpoints {}: {}", s.path, msg(e))
                }
            }
        }
        if !self.start.functions.is_empty()
            && self.cap("supportsFunctionBreakpoints")
            && let Err(vor::Error::Closed(why)) = self
                .client
                .request(
                    "setFunctionBreakpoints",
                    json!({"breakpoints": super::breakpoints::fit(&self.start.functions, &self.caps)}),
                )
                .await
        {
            return Err(why);
        }
        let has_filters = self
            .caps
            .get("exceptionBreakpointFilters")
            .and_then(Value::as_array)
            .is_some_and(|a| !a.is_empty());
        if has_filters {
            let filters = (self.start.exception_filters.clone())
                .unwrap_or_else(|| super::breakpoints::default_filters(&self.caps));
            if let Err(vor::Error::Closed(why)) = self
                .client
                .request("setExceptionBreakpoints", json!({"filters": filters}))
                .await
            {
                return Err(why);
            }
        }
        if self.cap("supportsConfigurationDoneRequest")
            && let Err(vor::Error::Closed(why)) =
                self.client.request("configurationDone", Value::Null).await
        {
            return Err(why);
        }
        Ok(())
    }

    fn reverse(&mut self, r: vor::ReverseRequest) {
        match r.command.as_str() {
            "runInTerminal" => {
                let (tx, rx) = oneshot::channel();
                self.send(Update::RunInTerminal {
                    arguments: r.arguments.clone(),
                    reply: tx,
                });
                clock::spawn("debug:run-in-terminal", async move {
                    match rx.await {
                        Ok(Ok(pid)) => r.ok(json!({"processId": pid})),
                        Ok(Err(e)) => r.err(&e),
                        Err(_) => r.err("no terminal"),
                    }
                });
            }
            "startDebugging" => {
                let (tx, rx) = oneshot::channel();
                self.send(Update::StartDebugging {
                    arguments: r.arguments.clone(),
                    reply: tx,
                });
                clock::spawn("debug:start-debugging", async move {
                    match rx.await {
                        Ok(Ok(())) => r.ok(json!({})),
                        Ok(Err(e)) => r.err(&e),
                        Err(_) => r.err("no child session"),
                    }
                });
            }
            _ => drop(r),
        }
    }

    /// An event outside the launch; `Some` ends the session.
    async fn event(&mut self, event: &str, body: Value) -> Option<Ending> {
        match event {
            "stopped" => {
                let thread = body
                    .get("threadId")
                    .and_then(Value::as_i64)
                    .or(self.stopped_thread)
                    .unwrap_or(0);
                self.stopped_thread = Some(thread);
                self.epoch += 1;
                let stop = Stop {
                    epoch: self.epoch,
                    thread,
                    reason: body
                        .get("reason")
                        .and_then(Value::as_str)
                        .unwrap_or("pause")
                        .to_owned(),
                    description: body
                        .get("description")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    all_threads: body
                        .get("allThreadsStopped")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    threads: vec![],
                    frames: vec![],
                    total_frames: None,
                    frame: 0,
                    scopes: vec![],
                };
                self.stop = Some(stop);
                self.fetch(true, true, true).await;
                self.publish();
            }
            "continued" => {
                let thread = body.get("threadId").and_then(Value::as_i64);
                let all = body
                    .get("allThreadsContinued")
                    .and_then(Value::as_bool)
                    .unwrap_or(true);
                self.running(thread, all);
            }
            "invalidated" if self.stop.is_some() => {
                let areas: Vec<String> = body
                    .get("areas")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect()
                    })
                    .unwrap_or_default();
                let all = areas.is_empty() || areas.iter().any(|a| a == "all");
                let has = |x: &str| all || areas.iter().any(|a| a == x);
                self.fetch(
                    has("threads"),
                    has("stacks"),
                    has("variables") || has("stacks"),
                )
                .await;
                self.publish();
            }
            "terminated" => {
                let restart = body.get("restart").cloned().filter(|v| !v.is_null());
                return Some(Ending::Stop {
                    reason: "the program ended".into(),
                    terminate: false,
                    terminate_debuggee: self.start.request == Request::Launch,
                    restart,
                    failed: false,
                });
            }
            "exited" => {
                self.exit_code = body.get("exitCode").and_then(Value::as_i64);
                return Some(Ending::Stop {
                    reason: format!(
                        "the program exited with code {}",
                        self.exit_code.unwrap_or(0)
                    ),
                    terminate: false,
                    terminate_debuggee: self.start.request == Request::Launch,
                    restart: None,
                    failed: false,
                });
            }
            _ => self.send(Update::Event {
                event: event.to_owned(),
                body,
            }),
        }
        None
    }

    fn running(&mut self, thread: Option<i64>, all: bool) {
        if all || thread == self.stop.as_ref().map(|s| s.thread) {
            self.stop = None;
        }
        self.send(Update::Running { thread, all });
    }

    fn publish(&self) {
        if let Some(s) = &self.stop {
            self.send(Update::Stopped(s.clone()));
        }
    }

    /// Fetch the current stop's parts again: THREADS, the stack (STACK) and the selected frame's scopes and variables
    /// (VARS).
    async fn fetch(&mut self, threads: bool, stack: bool, vars: bool) {
        let Some(mut s) = self.stop.take() else {
            return;
        };
        if threads && let Ok(b) = self.client.request("threads", Value::Null).await {
            s.threads = arr(&b, "threads");
        }
        if stack {
            let r = self
                .client
                .request(
                    "stackTrace",
                    json!({"threadId": s.thread, "startFrame": 0, "levels": FRAMES_PAGE}),
                )
                .await;
            if let Ok(b) = r {
                s.frames = arr(&b, "stackFrames");
                s.total_frames = b.get("totalFrames").and_then(Value::as_i64);
                s.frame = s
                    .frames
                    .first()
                    .and_then(|f| f.get("id"))
                    .and_then(Value::as_i64)
                    .unwrap_or(0);
            }
        }
        if vars && !s.frames.is_empty() {
            s.scopes = self.scopes(s.frame).await;
        }
        self.stop = Some(s);
    }

    async fn scopes(&self, frame: i64) -> Vec<ScopeVars> {
        let Ok(b) = self
            .client
            .request("scopes", json!({"frameId": frame}))
            .await
        else {
            return vec![];
        };
        let mut out = vec![];
        for scope in arr(&b, "scopes") {
            let expensive = scope
                .get("expensive")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let reference = scope
                .get("variablesReference")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            let variables = if expensive || reference == 0 {
                None
            } else {
                match self
                    .client
                    .request("variables", json!({"variablesReference": reference}))
                    .await
                {
                    Ok(v) => Some(arr(&v, "variables")),
                    Err(_) => Some(vec![]),
                }
            };
            out.push(ScopeVars { scope, variables });
        }
        out
    }

    /// A command from the hub; `Some` ends the session.
    async fn command(&mut self, c: Cmd) -> Option<Ending> {
        match c {
            Cmd::Op(op, reply) => self.op(op, reply).await,
            Cmd::Variables {
                epoch,
                reference,
                reply,
            } => {
                let r = if self.stop.as_ref().is_some_and(|s| s.epoch == epoch) {
                    self.client
                        .request("variables", json!({"variablesReference": reference}))
                        .await
                        .map(|b| arr(&b, "variables"))
                        .map_err(msg)
                } else {
                    Err(format!("stop {epoch} is over; its variables are gone"))
                };
                let _ = reply.send(r);
                None
            }
            Cmd::MoreFrames {
                epoch,
                thread,
                reply,
            } => {
                let r = match self.stop.as_mut() {
                    Some(s) if s.epoch == epoch && s.thread == thread => {
                        let start = s.frames.len() as i64;
                        let args =
                            json!({"threadId": thread, "startFrame": start, "levels": FRAMES_PAGE});
                        match self.client.request("stackTrace", args).await {
                            Ok(b) => {
                                let more = arr(&b, "stackFrames");
                                if let Some(s) = self.stop.as_mut() {
                                    s.frames.extend(more.iter().cloned());
                                    s.total_frames = b
                                        .get("totalFrames")
                                        .and_then(Value::as_i64)
                                        .or(s.total_frames);
                                }
                                Ok(more)
                            }
                            Err(e) => Err(msg(e)),
                        }
                    }
                    _ => Err(format!("stop {epoch} is over")),
                };
                let _ = reply.send(r);
                None
            }
            Cmd::Request {
                command,
                arguments,
                reply,
            } => {
                let _ = reply.send(self.client.request(&command, arguments).await.map_err(msg));
                None
            }
        }
    }

    async fn op(&mut self, op: Op, reply: oneshot::Sender<Result<(), String>>) -> Option<Ending> {
        let thread = |t: Option<i64>, s: &Session| {
            t.or(s.stop.as_ref().map(|s| s.thread))
                .or(s.stopped_thread)
                .unwrap_or(0)
        };
        let step = |command: &str, t: i64| (command.to_owned(), json!({"threadId": t}));
        let (command, args) = match op {
            Op::Continue { thread: t } => step("continue", thread(t, self)),
            Op::Pause { thread: t } => step("pause", thread(t, self)),
            Op::Next { thread: t } => step("next", thread(t, self)),
            Op::StepIn { thread: t } => step("stepIn", thread(t, self)),
            Op::StepOut { thread: t } => step("stepOut", thread(t, self)),
            Op::Restart => {
                if self.cap("supportsRestartRequest") {
                    let r = self
                        .client
                        .request("restart", json!({"arguments": self.start.arguments}))
                        .await;
                    self.stop = None;
                    let _ = reply.send(r.map(|_| ()).map_err(msg));
                    return None;
                }
                let mut e = self.stopping("restarting".into(), None);
                if let Ending::Stop { restart, .. } = &mut e {
                    *restart = Some(Value::Null);
                }
                let _ = reply.send(Ok(()));
                return Some(e);
            }
            Op::Stop { kill_debuggee } => {
                let _ = reply.send(Ok(()));
                return Some(self.stopping("stopped".into(), kill_debuggee));
            }
            Op::Disconnect => {
                let _ = reply.send(Ok(()));
                return Some(Ending::Stop {
                    reason: "disconnected".into(),
                    terminate: false,
                    terminate_debuggee: false,
                    restart: None,
                    failed: false,
                });
            }
            Op::Select { thread: t, frame } => {
                let ok = self
                    .stop
                    .as_ref()
                    .is_some_and(|s| t.is_none_or(|t| t == s.thread));
                if !ok {
                    let _ = reply.send(Err("not stopped there".into()));
                    return None;
                }
                let scopes = self.scopes(frame).await;
                if let Some(s) = self.stop.as_mut() {
                    s.frame = frame;
                    s.scopes = scopes;
                }
                self.publish();
                let _ = reply.send(Ok(()));
                return None;
            }
        };
        let r = self.client.request(&command, args.clone()).await;
        match r {
            Ok(b) => {
                if command != "pause" {
                    let t = args["threadId"].as_i64();
                    let all = command == "continue"
                        && b.get("allThreadsContinued")
                            .and_then(Value::as_bool)
                            .unwrap_or(true);
                    self.running(t, all);
                }
                let _ = reply.send(Ok(()));
            }
            Err(e) => {
                let _ = reply.send(Err(msg(e)));
            }
        }
        None
    }

    /// terminate (when TERMINATE) → 2 s for `terminated`; disconnect → 2 s; then the process: SIGTERM, 1 s, SIGKILL.
    async fn stop_sequence(&mut self, terminate: bool, terminate_debuggee: bool) {
        if terminate && !self.client.is_closed() {
            let t = self.client.request("terminate", json!({}));
            let wait = async {
                loop {
                    match self.incoming.recv().await {
                        None => return,
                        Some(Incoming::Event { event, .. }) if event == "terminated" => return,
                        Some(Incoming::Event { event, body }) => {
                            if event == "exited" {
                                self.exit_code = body.get("exitCode").and_then(Value::as_i64);
                            }
                        }
                        Some(Incoming::Request(r)) => drop(r),
                        Some(Incoming::Bad(_)) => {}
                    }
                }
            };
            let _ = clock::timeout(POLITE, wait).await;
            drop(t);
        }
        // disconnect, and 2 s for its answer and the process's exit; then SIGTERM, 1 s, SIGKILL
        let d = (!self.client.is_closed()).then(|| {
            self.client.request(
                "disconnect",
                json!({"restart": false, "terminateDebuggee": terminate_debuggee}),
            )
        });
        let Session {
            client,
            incoming,
            proc,
            ..
        } = &mut *self;
        let polite = async {
            if let Some(d) = d {
                let gone = async {
                    while let Some(m) = incoming.recv().await {
                        drop(m);
                    }
                };
                tokio::select! {
                    _ = d => {},
                    _ = gone => {},
                }
            }
            client.close("the session has ended");
            proc.wait().await;
        };
        if clock::timeout(POLITE, polite).await.is_ok() {
            return;
        }
        self.client.close("the session has ended");
        self.kill().await;
    }

    /// SIGTERM, 1 s, SIGKILL, and the process's end.
    async fn kill(&mut self) {
        self.proc.signal(Sig::Term);
        if clock::timeout(TERM_GRACE, self.proc.wait()).await.is_ok() {
            return;
        }
        self.proc.signal(Sig::Kill);
        self.proc.wait().await;
    }

    /// Wait for the adapter's process: 2 s on its own, then SIGTERM, 1 s, SIGKILL, and its end.
    async fn reap(&mut self) {
        self.client.close("the session has ended");
        if clock::timeout(POLITE, self.proc.wait()).await.is_ok() {
            return;
        }
        self.kill().await;
    }
}

fn refuse(c: Cmd) {
    match c {
        Cmd::Op(_, r) => drop(r.send(Err(ENDED.into()))),
        Cmd::Variables { reply, .. } | Cmd::MoreFrames { reply, .. } => {
            drop(reply.send(Err(ENDED.into())))
        }
        Cmd::Request { reply, .. } => drop(reply.send(Err(ENDED.into()))),
    }
}

fn arr(v: &Value, key: &str) -> Vec<Value> {
    v.get(key)
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}
