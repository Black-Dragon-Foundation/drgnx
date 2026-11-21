//! A connection to one ACP agent process: spawn, a writer task, a reader task and a watchdog.

use crate::incoming::{Incoming, Responder};
use crate::schema::v1 as acp;
use crate::stamp;
use crate::types::{
    AgentInfo, ClientCaps, ConnOpts, ContentBlock, Dir, Error, Event, ForkInto, LineTap, McpServer,
    PromptOutcome, Proto, SessionId,
};
use crate::v2;
use bytes::BytesMut;
use runstav::jsonrpc::{self, Id, Message};
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc::{self, UnboundedSender, WeakUnboundedSender};
use tokio::sync::{oneshot, watch};
use tokio_util::codec::Decoder;

/// How long the watchdog lets the reader drain after the child exits (a grandchild may hold the pipe open).
const DRAIN: Duration = Duration::from_secs(2);
const EVENT_QUEUE: usize = 1024;

type Answer = Result<Value, Error>;

pub(crate) struct Shared {
    pending: Mutex<HashMap<Id, oneshot::Sender<Answer>>>,
    pub(crate) closed: watch::Sender<bool>,
    next: AtomicI64,
    cwds: Mutex<HashMap<String, PathBuf>>,
    /// The mode each session is in, as the answer that opened it reported it (`modes.currentModeId`).
    modes: Mutex<HashMap<String, String>>,
    /// The model each session uses: the one the answer that opened it reported (`models.currentModelId`), then each
    /// `session/set_model` the agent accepted.
    models: Mutex<HashMap<String, String>>,
    /// 1 or 2: what `initialize` settled.
    proto: AtomicU8,
    /// The id of the config option that holds each session's mode (v2 has no `modes`).
    mode_opts: Mutex<HashMap<String, String>>,
    /// The v2 translation's state (unused on v1).
    v2: Mutex<v2::V2>,
}

impl Shared {
    fn lock_v2(&self) -> std::sync::MutexGuard<'_, v2::V2> {
        self.v2.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn lock_pending(&self) -> std::sync::MutexGuard<'_, HashMap<Id, oneshot::Sender<Answer>>> {
        self.pending.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// Removes a call's pending entry when the call ends or its future is dropped.
struct Forget<'a>(&'a Shared, Id);

impl Drop for Forget<'_> {
    fn drop(&mut self) {
        self.0.lock_pending().remove(&self.1);
    }
}

#[derive(Clone)]
pub struct Conn {
    tx: UnboundedSender<String>,
    shared: Arc<Shared>,
    opts: ConnOpts,
    pid: i32,
    stderr: draugr::StderrTail,
}

impl Conn {
    /// Start the agent.  Dropping every clone of the `Conn` closes the child's stdin; the watchdog reports the exit
    /// whenever it comes.  The receiver must be drained: the reader waits when its queue (1024 events) is full.
    ///
    /// The child is forked from draugr's pinned thread (`draugr::spawn_pinned`): an agent runs in a sandbox, whose
    /// `--die-with-parent` (and the helper's `PR_SET_PDEATHSIG`) fires when the forking thread exits, and a runtime's
    /// pool threads come and go.
    pub async fn spawn(
        spec: draugr::Spec,
        opts: ConnOpts,
    ) -> Result<(Conn, mpsc::Receiver<Event>), Error> {
        let program = spec.program.to_string_lossy().into_owned();
        let mut child = draugr::spawn_pinned(spec)
            .await
            .map_err(|e| Error::Spawn(program, e))?;
        let (Some(mut stdin), Some(stdout)) = (child.take_stdin(), child.take_stdout()) else {
            return Err(Error::Closed);
        };
        let pid = child.id();
        let stderr = child.stderr();
        let shared = Arc::new(Shared {
            pending: Mutex::new(HashMap::new()),
            closed: watch::channel(false).0,
            next: AtomicI64::new(1),
            cwds: Mutex::new(HashMap::new()),
            modes: Mutex::new(HashMap::new()),
            models: Mutex::new(HashMap::new()),
            proto: AtomicU8::new(1),
            mode_opts: Mutex::new(HashMap::new()),
            v2: Mutex::new(v2::V2::default()),
        });
        let (tx, mut wrx) = mpsc::unbounded_channel::<String>();
        let (etx, erx) = mpsc::channel(EVENT_QUEUE);

        let wtap = opts.tap.clone();
        tokio::spawn(async move {
            while let Some(mut line) = wrx.recv().await {
                if let Some(t) = &wtap {
                    t.line(Dir::In, &line, std::time::Instant::now());
                }
                line.push('\n');
                if stdin.write_all(line.as_bytes()).await.is_err() || stdin.flush().await.is_err() {
                    break;
                }
            }
        });

        let reader = tokio::spawn(read_loop(
            stdout,
            shared.clone(),
            tx.downgrade(),
            etx.clone(),
            opts.tap.clone(),
        ));

        let sh = shared.clone();
        let (tail_max, xtap) = (opts.stderr_tail, opts.tap.clone());
        tokio::spawn(async move {
            let status = child.wait().await.ok().flatten();
            let mut reader = reader;
            if tokio::time::timeout(DRAIN, &mut reader).await.is_err() {
                reader.abort();
            }
            sh.closed.send_replace(true);
            // a turn waiting for an `idle` that will not come ends with the child
            sh.lock_v2().close_all();
            let waiting: Vec<_> = sh.lock_pending().drain().collect();
            for (_, w) in waiting {
                let _ = w.send(Err(Error::Closed));
            }
            let (code, signal) = status.map_or((None, None), |s| {
                use std::os::unix::process::ExitStatusExt;
                (s.code(), s.signal())
            });
            let tail = child.stderr_tail();
            let skip = tail.chars().count().saturating_sub(tail_max);
            let stderr: String = tail.chars().skip(skip).collect();
            if let Some(t) = &xtap {
                t.exit(code, signal, &stderr);
            }
            let _ = etx
                .send(Event::Exit {
                    code,
                    signal,
                    stderr,
                })
                .await;
        });

        Ok((
            Conn {
                tx,
                shared,
                opts,
                pid,
                stderr,
            },
            erx,
        ))
    }

    /// The child's pid (also its process group).
    pub fn pid(&self) -> i32 {
        self.pid
    }

    /// The child's stderr tail as it is now (a sandbox's own complaint, before the agent ever speaks), as a handle
    /// that can be read from another thread.
    pub fn stderr(&self) -> draugr::StderrTail {
        self.stderr.clone()
    }

    async fn call(&self, method: &str, params: Value, deadline: Option<Duration>) -> Answer {
        self.send_call(method, params)?
            .answer(method, deadline)
            .await
    }

    /// The request's line, on its way to the agent when this returns (ahead of any line sent after), and its answer
    /// to wait for.
    fn send_call(&self, method: &str, params: Value) -> Result<Sent<'_>, Error> {
        self.send_call_as(method, params, None)
    }

    /// As [`Conn::send_call`]; TURN names the session of a v2 prompt, whose wait for the turn's end is registered
    /// before the line goes (the agent's `idle` may come before its answer).
    fn send_call_as(
        &self,
        method: &str,
        params: Value,
        turn: Option<&str>,
    ) -> Result<Sent<'_>, Error> {
        if *self.shared.closed.borrow() {
            return Err(Error::Closed);
        }
        let id = Id::Num(self.shared.next.fetch_add(1, Ordering::Relaxed));
        let (otx, orx) = oneshot::channel();
        self.shared.lock_pending().insert(id.clone(), otx);
        let forget = Forget(&self.shared, id.clone());
        // the watchdog may have drained the table just before our insert
        if *self.shared.closed.borrow() {
            return Err(Error::Closed);
        }
        let turn = turn.map(|sid| {
            let (token, rx) = self.shared.lock_v2().register(sid, id.clone());
            (sid.to_string(), token, rx)
        });
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        if self.tx.send(line.to_string()).is_err() {
            if let Some((sid, token, _)) = &turn {
                self.shared.lock_v2().forget(sid, *token);
            }
            return Err(Error::Closed);
        }
        Ok(Sent {
            answer: orx,
            _forget: forget,
            turn,
        })
    }
}

/// A v2 prompt's wait for its turn's end: the session, the token and the receiver of the outcome.
type Turn = (String, u64, oneshot::Receiver<Result<PromptOutcome, Error>>);

/// A request whose line has gone to the agent; its answer is still to come.
struct Sent<'a> {
    answer: oneshot::Receiver<Answer>,
    _forget: Forget<'a>,
    /// A v2 prompt's session, its token and the receiver of its turn's end.
    turn: Option<Turn>,
}

impl Sent<'_> {
    async fn answer(self, method: &str, deadline: Option<Duration>) -> Answer {
        let wait = async { self.answer.await.unwrap_or(Err(Error::Closed)) };
        match deadline {
            Some(d) => tokio::time::timeout(d, wait)
                .await
                .unwrap_or_else(|_| Err(Error::Deadline(method.to_string()))),
            None => wait.await,
        }
    }
}

impl Conn {
    async fn typed<T: DeserializeOwned>(&self, method: &str, params: Value) -> Result<T, Error> {
        let v = self.call(method, params, Some(self.opts.deadline)).await?;
        decode(v)
    }

    /// `initialize`.  With `ConnOpts::v2` the request asks for ACP v2 (`info`, `capabilities`, the panel's `_meta`); an
    /// agent that answers 1 gets the v1 path on this connection, silently.
    pub async fn initialize(&self, mut caps: ClientCaps) -> Result<AgentInfo, Error> {
        caps.terminal = false;
        if !self.opts.v2 {
            return self
                .initialize_v1(caps, json!(crate::schema::ProtocolVersion::V1))
                .await;
        }
        let mut capabilities = json!({});
        if let Some(m) = serde_json::to_value(&caps)
            .ok()
            .and_then(|c| c.get("_meta").cloned())
            .filter(|m| !m.is_null())
        {
            capabilities["_meta"] = m;
        }
        let params = json!({
            "protocolVersion": 2,
            "info": {"name": "hermod", "version": env!("CARGO_PKG_VERSION")},
            "capabilities": capabilities,
        });
        let v: Value = match self.typed("initialize", params).await {
            Ok(v) => v,
            // an agent that refuses the v2 ask with an error is still there: asked again as v1, once, on this connection
            Err(Error::Rpc { message, .. }) => {
                let mut info = self
                    .initialize_v1(caps, json!(crate::schema::ProtocolVersion::V1))
                    .await?;
                info.v2_fallback = Some(message);
                return Ok(info);
            }
            Err(e) => return Err(e),
        };
        if v.get("protocolVersion").and_then(Value::as_u64) != Some(2) {
            // a v1 agent read a v2 request without the v1 fields: what it answered is a v1 answer
            return self.settle_v1(decode(v)?);
        }
        self.shared.proto.store(2, Ordering::SeqCst);
        let caps = v.get("capabilities").cloned().unwrap_or(Value::Null);
        let info = v.get("info");
        let text = |k: &str| {
            info.and_then(|i| i.get(k))
                .and_then(Value::as_str)
                .map(String::from)
        };
        Ok(AgentInfo {
            name: text("name"),
            version: text("version"),
            caps: decode(v2::v1_caps(&caps))?,
            meta: caps.get("_meta").filter(|m| !m.is_null()).cloned(),
            auth: v2::v1_auth(v.get("authMethods").unwrap_or(&Value::Null)),
            proto: Proto::V2,
            v2_fallback: None,
        })
    }

    async fn initialize_v1(&self, caps: ClientCaps, version: Value) -> Result<AgentInfo, Error> {
        let params = json!({
            "protocolVersion": version,
            "clientCapabilities": caps,
            "clientInfo": {"name": "hermod", "version": env!("CARGO_PKG_VERSION")},
        });
        let r: acp::InitializeResponse = self.typed("initialize", params).await?;
        self.settle_v1(r)
    }

    fn settle_v1(&self, r: acp::InitializeResponse) -> Result<AgentInfo, Error> {
        self.shared.proto.store(1, Ordering::SeqCst);
        let (name, version) = match r.agent_info {
            Some(i) => (Some(i.name), Some(i.version)),
            None => (None, None),
        };
        Ok(AgentInfo {
            name,
            version,
            caps: r.agent_capabilities,
            meta: r.meta.map(Value::Object),
            auth: r.auth_methods,
            proto: Proto::V1,
            v2_fallback: None,
        })
    }

    /// The version this connection speaks (V1 until `initialize` settles it).
    pub fn proto(&self) -> Proto {
        if self.shared.proto.load(Ordering::SeqCst) == 2 {
            Proto::V2
        } else {
            Proto::V1
        }
    }

    /// The refusal of a v2-only request on a v1 connection (nothing is written).
    fn v2_only(&self, what: &str) -> Result<(), Error> {
        if self.proto() == Proto::V2 {
            return Ok(());
        }
        Err(Error::Rpc {
            code: -32601,
            message: format!("{what}: ACP v1 has no such request"),
            data: None,
        })
    }

    /// ACP v2: stop one tool call that advertises `capabilities.cancel` (`tool_call/cancel`).  The answer says the
    /// agent accepted it; the tool call's final status says it stopped.
    pub async fn cancel_tool_call(&self, sid: &SessionId, id: &str) -> Result<(), Error> {
        self.v2_only("tool_call/cancel")?;
        self.typed::<Value>(
            "tool_call/cancel",
            json!({"sessionId": sid, "toolCallId": id}),
        )
        .await
        .map(drop)
    }

    /// ACP v2: stop the process of one terminal that advertises `capabilities.cancel` (`terminal/cancel`).
    pub async fn cancel_terminal(&self, sid: &SessionId, id: &str) -> Result<(), Error> {
        self.v2_only("terminal/cancel")?;
        self.typed::<Value>(
            "terminal/cancel",
            json!({"sessionId": sid, "terminalId": id}),
        )
        .await
        .map(drop)
    }

    /// ACP v2: cancel a child session's foreground work (`session/cancel` with the child's id, a notification).  Only
    /// for a child whose announcement advertised `cancel`: the caller checks.
    pub fn cancel_child(&self, child: &SessionId) -> Result<(), Error> {
        self.v2_only("session/cancel of a child")?;
        self.cancel(child)
    }

    /// `authenticate` (v1) or `auth/login` (v2) with the method METHOD_ID.
    pub async fn authenticate(&self, method_id: &str) -> Result<(), Error> {
        let method = if self.proto() == Proto::V2 {
            "auth/login"
        } else {
            "authenticate"
        };
        self.typed::<Value>(method, json!({"methodId": method_id}))
            .await
            .map(drop)
    }

    pub async fn new_session(
        &self,
        cwd: &Path,
        mcp: Vec<McpServer>,
        meta: Option<Value>,
    ) -> Result<SessionId, Error> {
        let v2 = self.proto() == Proto::V2;
        let mut params =
            json!({"cwd": cwd, "mcpServers": if v2 { v2_mcp(&mcp) } else { json!(mcp) }});
        set_meta(&mut params, meta);
        let v: Value = self.typed("session/new", params).await?;
        if v2 {
            let sid = v
                .get("sessionId")
                .and_then(Value::as_str)
                .map(|s| SessionId::new(s.to_string()))
                .ok_or_else(|| Error::Decode("session/new: no sessionId".into()))?;
            self.note_opened(&sid, cwd, &v);
            return Ok(sid);
        }
        let r: acp::NewSessionResponse = decode(v.clone())?;
        self.note_model(&r.session_id, reported_model(&v));
        self.remember(&r.session_id, cwd);
        self.note_mode(
            &r.session_id,
            r.modes.map(|m| m.current_mode_id.to_string()),
        );
        Ok(r.session_id)
    }

    /// Load a stored session; the agent replays its history as updates before this returns.
    pub async fn load_session(
        &self,
        sid: &SessionId,
        cwd: &Path,
        mcp: Vec<McpServer>,
        meta: Option<Value>,
    ) -> Result<(), Error> {
        if self.proto() == Proto::V2 {
            // v2 has no session/load: resume with a replay from the start does both
            return self.resume_v2(sid, cwd, mcp, meta, true).await;
        }
        let mut params = json!({"sessionId": sid, "cwd": cwd, "mcpServers": mcp});
        set_meta(&mut params, meta);
        let r = self.typed::<Value>("session/load", params).await?;
        self.remember(sid, cwd);
        self.note_mode(sid, reported_mode(&r));
        self.note_model(sid, reported_model(&r));
        Ok(())
    }

    /// Resume a stored session without replaying its history.
    pub async fn resume_session(
        &self,
        sid: &SessionId,
        cwd: &Path,
        mcp: Vec<McpServer>,
        meta: Option<Value>,
    ) -> Result<(), Error> {
        if self.proto() == Proto::V2 {
            return self.resume_v2(sid, cwd, mcp, meta, false).await;
        }
        let mut params = json!({"sessionId": sid, "cwd": cwd, "mcpServers": mcp});
        set_meta(&mut params, meta);
        let r = self.typed::<Value>("session/resume", params).await?;
        self.remember(sid, cwd);
        self.note_mode(sid, reported_mode(&r));
        self.note_model(sid, reported_model(&r));
        Ok(())
    }

    /// `session/resume` on v2, REPLAY from the start or not; the agent's current-state snapshot comes before the answer.
    async fn resume_v2(
        &self,
        sid: &SessionId,
        cwd: &Path,
        mcp: Vec<McpServer>,
        meta: Option<Value>,
        replay: bool,
    ) -> Result<(), Error> {
        let mut params = json!({"sessionId": sid, "cwd": cwd, "mcpServers": v2_mcp(&mcp)});
        if replay {
            params["replayFrom"] = json!({"type": "start"});
        }
        set_meta(&mut params, meta);
        let v = self.typed::<Value>("session/resume", params).await?;
        self.note_opened(sid, cwd, &v);
        Ok(())
    }

    /// What a v2 answer that opened session SID reports: its directory, its mode (and the option that holds it), its model.
    fn note_opened(&self, sid: &SessionId, cwd: &Path, answer: &Value) {
        let (mode, model, opt) = v2::reported(answer);
        self.remember(sid, cwd);
        self.note_mode(sid, mode);
        self.note_model(sid, model);
        let mut opts = self
            .shared
            .mode_opts
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        match opt {
            Some(o) => opts.insert(sid.0.to_string(), o),
            None => opts.remove(&*sid.0),
        };
    }

    /// The model session SID uses: the one the answer that opened it on this connection reported, then each
    /// `session/set_model` (or `model` config option) the agent accepted; `None` when it reported none.
    pub fn reported_model(&self, sid: &SessionId) -> Option<String> {
        self.shared
            .models
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&*sid.0)
            .cloned()
    }

    /// The mode session SID is in, as the agent's answer that opened it on this connection (`session/new`,
    /// `session/load`, `session/resume` or `session/fork`) reported it; `None` when it reported none.
    pub fn reported_mode(&self, sid: &SessionId) -> Option<String> {
        self.shared
            .modes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&*sid.0)
            .cloned()
    }

    pub async fn close_session(&self, sid: &SessionId) -> Result<(), Error> {
        self.typed::<Value>("session/close", json!({"sessionId": sid}))
            .await?;
        self.shared
            .cwds
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&*sid.0);
        self.note_mode(sid, None);
        Ok(())
    }

    pub async fn set_mode(&self, sid: &SessionId, mode: &str) -> Result<(), Error> {
        if self.proto() == Proto::V2 {
            // v2 has no modes: the mode is a config option, the one the agent reported
            let opt = self
                .shared
                .mode_opts
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&*sid.0)
                .cloned();
            return match opt {
                Some(o) => self.set_config_option(sid, &o, mode).await,
                None => Err(Error::Rpc {
                    code: -32601,
                    message: "the agent reports no mode option".into(),
                    data: None,
                }),
            };
        }
        self.typed::<Value>(
            "session/set_mode",
            json!({"sessionId": sid, "modeId": mode}),
        )
        .await
        .map(drop)
    }

    /// Set the session's config option CONFIG_ID (`mode`, `model`, …) to VALUE.  An agent without the method answers
    /// `-32601` ([`Error::Rpc`]); the caller falls back to [`Conn::set_mode`] or [`Conn::set_model`].
    pub async fn set_config_option(
        &self,
        sid: &SessionId,
        config_id: &str,
        value: &str,
    ) -> Result<(), Error> {
        self.typed::<Value>(
            "session/set_config_option",
            if self.proto() == Proto::V2 {
                json!({"sessionId": sid, "configId": config_id, "type": "id", "value": value})
            } else {
                json!({"sessionId": sid, "configId": config_id, "value": value})
            },
        )
        .await
        .map(|_| {
            if config_id == "model" {
                self.note_model(sid, Some(value.to_owned()));
            }
        })
    }

    /// Switch the session's model (`session/set_model`).
    pub async fn set_model(&self, sid: &SessionId, model: &str) -> Result<(), Error> {
        if self.proto() == Proto::V2 {
            return self.set_config_option(sid, "model", model).await;
        }
        self.typed::<Value>(
            "session/set_model",
            json!({"sessionId": sid, "modelId": model}),
        )
        .await
        .map(|_| self.note_model(sid, Some(model.to_owned())))
    }

    /// Run one turn.  No deadline: the turn ends by the agent's answer, [`Conn::cancel`] or the child's exit.
    pub async fn prompt(
        &self,
        sid: &SessionId,
        blocks: Vec<ContentBlock>,
        meta: Option<Value>,
    ) -> Result<PromptOutcome, Error> {
        self.send_prompt(sid, blocks, meta)?.await
    }

    /// As [`Conn::prompt`], with the prompt's line already on its way to the agent when this returns: a
    /// [`Conn::cancel`] after it reaches the agent after the prompt.  The future is the turn's answer.
    pub fn send_prompt(
        &self,
        sid: &SessionId,
        blocks: Vec<ContentBlock>,
        meta: Option<Value>,
    ) -> Result<impl Future<Output = Result<PromptOutcome, Error>> + '_, Error> {
        let mut params = json!({"sessionId": sid, "prompt": blocks});
        set_meta(&mut params, meta);
        // v2: the answer only says the message was inserted; the turn ends at the agent's `idle`, which may come
        // first, so its wait is registered before the line goes and the reader marks the answer as it arrives
        let sent = self.send_call_as(
            "session/prompt",
            params,
            (self.proto() == Proto::V2).then_some(&*sid.0),
        )?;
        let shared = self.shared.clone();
        Ok(async move {
            let mut sent = sent;
            let turn = sent.turn.take();
            let answer = sent.answer("session/prompt", None).await;
            let Some((key, token, rx)) = turn else {
                return prompt_outcome(answer?);
            };
            let _forget = ForgetTurn(&shared, &key, token);
            match answer {
                // dropped before it was inserted (`session/cancel`, `session/close`): the work never began
                Err(Error::Rpc { code: -32800, .. }) => {
                    return Ok(PromptOutcome {
                        stop: crate::types::StopReason::Cancelled,
                        usage: None,
                        turn_id: None,
                    });
                }
                Err(e) => return Err(e),
                Ok(_) => {}
            }
            rx.await.unwrap_or(Err(Error::Closed))
        })
    }
}

/// Removes a v2 prompt's wait when its future ends or is dropped.
struct ForgetTurn<'a>(&'a Shared, &'a str, u64);

impl Drop for ForgetTurn<'_> {
    fn drop(&mut self) {
        self.0.lock_v2().forget(self.1, self.2);
    }
}

/// The turn's answer, read.
fn prompt_outcome(answer: Value) -> Result<PromptOutcome, Error> {
    let r: acp::PromptResponse = decode(answer)?;
    let turn_id = r
        .meta
        .as_ref()
        .and_then(|m| m.get("turnId"))
        .and_then(Value::as_str)
        .map(str::to_string);
    Ok(PromptOutcome {
        stop: r.stop_reason,
        usage: r.usage,
        turn_id,
    })
}

impl Conn {
    /// Ask the agent to stop the session's turn (a notification; the turn's `prompt` then answers `cancelled`).
    pub fn cancel(&self, sid: &SessionId) -> Result<(), Error> {
        let line =
            json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": sid}});
        self.tx.send(line.to_string()).map_err(|_| Error::Closed)
    }

    /// Fork F's source into a new session in F's directory, with F's tools and `_meta` (a lock's options), at a
    /// message when given (`_meta.jetbrains.air.fork {version: 1, messageId}`, merged into F's `_meta`).  The source
    /// need not be one this connection opened: the agent reads it from its own store.
    pub async fn fork_into(&self, f: ForkInto) -> Result<SessionId, Error> {
        let mut meta = f.meta;
        if let Some(p) = f.at {
            let point =
                json!({"jetbrains": {"air": {"fork": {"version": 1, "messageId": p.message_id}}}});
            merge(meta.get_or_insert_with(|| json!({})), point);
        }
        let mut params = json!({"sessionId": f.source, "cwd": f.cwd, "mcpServers": f.mcp});
        set_meta(&mut params, meta);
        let v: Value = self.typed("session/fork", params).await?;
        let r: acp::ForkSessionResponse = decode(v.clone())?;
        self.note_model(&r.session_id, reported_model(&v));
        self.remember(&r.session_id, &f.cwd);
        self.note_mode(
            &r.session_id,
            r.modes.map(|m| m.current_mode_id.to_string()),
        );
        Ok(r.session_id)
    }

    /// An extension request METHOD (a `_`-prefixed method the agent advertised, e.g. `_drgnx/context/drop`) with
    /// PARAMS, answered within DEADLINE: the agent's result as it sent it, for the caller to check.
    pub async fn ext_request(
        &self,
        method: &str,
        params: Value,
        deadline: Duration,
    ) -> Result<Value, Error> {
        self.call(method, params, Some(deadline)).await
    }

    fn remember(&self, sid: &SessionId, cwd: &Path) {
        self.shared
            .cwds
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(sid.0.to_string(), cwd.to_path_buf());
    }

    /// SID's reported MODE (none: forgotten, so an earlier answer's mode is never taken for this one's).
    fn note_mode(&self, sid: &SessionId, mode: Option<String>) {
        let mut modes = self.shared.modes.lock().unwrap_or_else(|e| e.into_inner());
        match mode {
            Some(m) => modes.insert(sid.0.to_string(), m),
            None => modes.remove(&*sid.0),
        };
    }
}

impl Conn {
    /// SID's reported MODEL (none: forgotten, as [`Conn::note_mode`] forgets a mode).
    fn note_model(&self, sid: &SessionId, model: Option<String>) {
        let mut models = self.shared.models.lock().unwrap_or_else(|e| e.into_inner());
        match model {
            Some(m) => models.insert(sid.0.to_string(), m),
            None => models.remove(&*sid.0),
        };
    }
}

/// `models.currentModelId` of an answer that opened a session.
fn reported_model(answer: &Value) -> Option<String> {
    answer
        .pointer("/models/currentModelId")
        .and_then(Value::as_str)
        .map(String::from)
}

/// `modes.currentModeId` of an answer that opened a session.
fn reported_mode(answer: &Value) -> Option<String> {
    answer
        .pointer("/modes/currentModeId")
        .and_then(Value::as_str)
        .map(String::from)
}

/// FROM's keys into INTO, objects merged key by key; anything else in FROM replaces what INTO has.
fn merge(into: &mut Value, from: Value) {
    match (into, from) {
        (Value::Object(a), Value::Object(b)) => {
            for (k, v) in b {
                merge(a.entry(k).or_insert(Value::Null), v);
            }
        }
        (slot, v) => *slot = v,
    }
}

/// The MCP servers as v2 wants them: every config carries its `type` (a v1 stdio server has none).
fn v2_mcp(mcp: &[McpServer]) -> Value {
    Value::Array(
        mcp.iter()
            .filter_map(|m| serde_json::to_value(m).ok())
            .map(|mut v| {
                if let Some(o) = v.as_object_mut()
                    && !o.contains_key("type")
                    && o.contains_key("command")
                {
                    o.insert("type".into(), json!("stdio"));
                }
                v
            })
            .collect(),
    )
}

fn set_meta(params: &mut Value, meta: Option<Value>) {
    if let (Some(m), Some(o)) = (meta, params.as_object_mut()) {
        o.insert("_meta".into(), m);
    }
}

fn decode<T: DeserializeOwned>(v: Value) -> Result<T, Error> {
    serde_json::from_value(v).map_err(|e| Error::Decode(e.to_string()))
}

async fn read_loop(
    mut out: tokio::process::ChildStdout,
    shared: Arc<Shared>,
    wtx: WeakUnboundedSender<String>,
    etx: mpsc::Sender<Event>,
    tap: Option<Arc<dyn LineTap>>,
) {
    let mut codec = runstav::line::codec();
    let mut buf = BytesMut::with_capacity(8192);
    let seen = |line: &str| {
        if let Some(t) = &tap {
            t.line(Dir::Out, line, std::time::Instant::now());
        }
    };
    loop {
        loop {
            match codec.decode(&mut buf) {
                Ok(Some(line)) => {
                    seen(&line);
                    handle(&line, &shared, &wtx, &etx).await;
                }
                Ok(None) => break,
                Err(e) => tracing::warn!("hermod: dropped a line from the agent: {e}"),
            }
        }
        match out.read_buf(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
    }
    if let Ok(Some(line)) = codec.decode_eof(&mut buf) {
        seen(&line);
        handle(&line, &shared, &wtx, &etx).await;
    }
}

fn reply_error(wtx: &WeakUnboundedSender<String>, id: &Id, code: i64, message: &str) {
    if let Some(tx) = wtx.upgrade() {
        let line = json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}});
        let _ = tx.send(line.to_string());
    }
}

async fn handle(
    line: &str,
    shared: &Arc<Shared>,
    wtx: &WeakUnboundedSender<String>,
    etx: &mpsc::Sender<Event>,
) {
    let at = stamp::now();
    let msg = match jsonrpc::parse(line) {
        Ok(m) => m,
        Err(e) => {
            tracing::warn!("hermod: unparseable line from the agent: {}", e.message);
            return;
        }
    };
    match msg {
        Message::Result { id, result } => {
            shared.lock_v2().answered(&id, true);
            if let Some(w) = shared.lock_pending().remove(&id) {
                let _ = w.send(Ok(result));
            }
        }
        Message::Error {
            id: Some(id),
            error,
        } => {
            shared.lock_v2().answered(&id, false);
            if let Some(w) = shared.lock_pending().remove(&id) {
                let _ = w.send(Err(Error::Rpc {
                    code: error.code,
                    message: error.message,
                    data: error.data,
                }));
            }
        }
        Message::Error { id: None, .. } => {}
        Message::Notification { method, params } => {
            if method != "session/update" {
                if method.starts_with('_') {
                    let params = params.unwrap_or(Value::Null);
                    let _ = etx.send(Event::Ext { method, params }).await;
                }
                return;
            }
            if shared.proto.load(Ordering::SeqCst) == 2 {
                let Some((sid, update)) = params.as_ref().and_then(|p| {
                    Some((
                        p.get("sessionId")?.as_str()?.to_string(),
                        p.get("update")?.clone(),
                    ))
                }) else {
                    tracing::warn!("hermod: a session/update without a session or an update");
                    return;
                };
                let out = shared
                    .lock_v2()
                    .translate(at, &SessionId::new(sid.clone()), update);
                for ev in out.events {
                    let _ = etx.send(ev).await;
                }
                // the turn ends after every update it has had: the owner reads those first
                if let Some(result) = out.ended {
                    shared.lock_v2().finish(&sid, &result);
                }
                return;
            }
            let Some(n) =
                params.and_then(|p| serde_json::from_value::<acp::SessionNotification>(p).ok())
            else {
                tracing::warn!("hermod: a session/update that does not fit the schema");
                return;
            };
            let message_id = match &n.update {
                acp::SessionUpdate::UserMessageChunk(c)
                | acp::SessionUpdate::AgentMessageChunk(c)
                | acp::SessionUpdate::AgentThoughtChunk(c) => {
                    c.message_id.as_ref().map(|m| m.0.to_string())
                }
                _ => None,
            };
            let _ = etx
                .send(Event::Update {
                    at,
                    sid: n.session_id,
                    update: n.update,
                    message_id,
                })
                .await;
        }
        Message::Request { id, method, params } => {
            let mut params = params.unwrap_or(Value::Null);
            // v2's permission request (`title`, `subject`) is the v1 one the hub decodes (`toolCall`), after the
            // subject's tool call has been applied like an update
            if method == "session/request_permission" && shared.proto.load(Ordering::SeqCst) == 2 {
                let sid = SessionId::new(
                    params
                        .get("sessionId")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                );
                let (v1, events) = shared.lock_v2().permission(at, &sid, &id, &params);
                for ev in events {
                    let _ = etx.send(ev).await;
                }
                params = v1;
            }
            let incoming = match method.as_str() {
                "session/request_permission" => decode_req(params).map(|r| {
                    Incoming::Permission(r, Responder::new(id.clone(), wtx.clone(), shared))
                }),
                "fs/read_text_file" => decode_req(params).map(|r| {
                    Incoming::ReadFile(r, Responder::new(id.clone(), wtx.clone(), shared))
                }),
                "fs/write_text_file" => decode_req(params).map(|r| {
                    Incoming::WriteFile(r, Responder::new(id.clone(), wtx.clone(), shared))
                }),
                m if m.starts_with('_') => Ok(Incoming::Ext {
                    method: method.clone(),
                    params,
                    resp: Responder::new(id.clone(), wtx.clone(), shared),
                }),
                _ => {
                    reply_error(wtx, &id, jsonrpc::METHOD_NOT_FOUND, "method not found");
                    return;
                }
            };
            match incoming {
                Ok(i) => {
                    let _ = etx.send(Event::Request(i)).await;
                }
                Err(m) => reply_error(wtx, &id, jsonrpc::INVALID_PARAMS, &m),
            }
        }
    }
}

fn decode_req<T: DeserializeOwned>(params: Value) -> Result<T, String> {
    serde_json::from_value(params).map_err(|e| e.to_string())
}
