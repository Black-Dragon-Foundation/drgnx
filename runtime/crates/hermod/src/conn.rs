//! A connection to one ACP agent process: spawn, a writer task, a reader task and a watchdog.

use crate::incoming::{Incoming, Responder};
use crate::schema::v1 as acp;
use crate::stamp;
use crate::types::{
    AgentInfo, ClientCaps, ConnOpts, ContentBlock, Error, Event, ForkPoint, McpServer,
    PromptOutcome, SessionId,
};
use bytes::BytesMut;
use runstav::jsonrpc::{self, Id, Message};
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
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
}

impl Shared {
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
}

impl Conn {
    /// Start the agent.  Dropping every clone of the `Conn` closes the child's stdin; the watchdog reports the exit
    /// whenever it comes.  The receiver must be drained: the reader waits when its queue (1024 events) is full.
    pub async fn spawn(
        spec: draugr::Spec,
        opts: ConnOpts,
    ) -> Result<(Conn, mpsc::Receiver<Event>), Error> {
        let mut child = draugr::spawn(spec).await.map_err(Error::Spawn)?;
        let (Some(mut stdin), Some(stdout)) = (child.take_stdin(), child.take_stdout()) else {
            return Err(Error::Closed);
        };
        let pid = child.id();
        let shared = Arc::new(Shared {
            pending: Mutex::new(HashMap::new()),
            closed: watch::channel(false).0,
            next: AtomicI64::new(1),
            cwds: Mutex::new(HashMap::new()),
        });
        let (tx, mut wrx) = mpsc::unbounded_channel::<String>();
        let (etx, erx) = mpsc::channel(EVENT_QUEUE);

        tokio::spawn(async move {
            while let Some(mut line) = wrx.recv().await {
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
        ));

        let sh = shared.clone();
        tokio::spawn(async move {
            let status = child.wait().await.ok().flatten();
            let mut reader = reader;
            if tokio::time::timeout(DRAIN, &mut reader).await.is_err() {
                reader.abort();
            }
            sh.closed.send_replace(true);
            let waiting: Vec<_> = sh.lock_pending().drain().collect();
            for (_, w) in waiting {
                let _ = w.send(Err(Error::Closed));
            }
            let (code, signal) = status.map_or((None, None), |s| {
                use std::os::unix::process::ExitStatusExt;
                (s.code(), s.signal())
            });
            let tail = child.stderr_tail();
            let skip = tail.chars().count().saturating_sub(opts.stderr_tail);
            let stderr = tail.chars().skip(skip).collect();
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
            },
            erx,
        ))
    }

    /// The child's pid (also its process group).
    pub fn pid(&self) -> i32 {
        self.pid
    }

    async fn call(&self, method: &str, params: Value, deadline: Option<Duration>) -> Answer {
        if *self.shared.closed.borrow() {
            return Err(Error::Closed);
        }
        let id = Id::Num(self.shared.next.fetch_add(1, Ordering::Relaxed));
        let (otx, orx) = oneshot::channel();
        self.shared.lock_pending().insert(id.clone(), otx);
        let _forget = Forget(&self.shared, id.clone());
        // the watchdog may have drained the table just before our insert
        if *self.shared.closed.borrow() {
            return Err(Error::Closed);
        }
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.tx.send(line.to_string()).map_err(|_| Error::Closed)?;
        let wait = async { orx.await.unwrap_or(Err(Error::Closed)) };
        match deadline {
            Some(d) => tokio::time::timeout(d, wait)
                .await
                .unwrap_or_else(|_| Err(Error::Deadline(method.to_string()))),
            None => wait.await,
        }
    }

    async fn typed<T: DeserializeOwned>(&self, method: &str, params: Value) -> Result<T, Error> {
        let v = self.call(method, params, Some(self.opts.deadline)).await?;
        decode(v)
    }

    pub async fn initialize(&self, mut caps: ClientCaps) -> Result<AgentInfo, Error> {
        caps.terminal = false;
        let params = json!({
            "protocolVersion": crate::schema::ProtocolVersion::V1,
            "clientCapabilities": caps,
            "clientInfo": {"name": "hermod", "version": env!("CARGO_PKG_VERSION")},
        });
        let r: acp::InitializeResponse = self.typed("initialize", params).await?;
        Ok(AgentInfo {
            caps: r.agent_capabilities,
            meta: r.meta.map(Value::Object),
            auth: r.auth_methods,
        })
    }

    pub async fn new_session(
        &self,
        cwd: &Path,
        mcp: Vec<McpServer>,
        meta: Option<Value>,
    ) -> Result<SessionId, Error> {
        let mut params = json!({"cwd": cwd, "mcpServers": mcp});
        set_meta(&mut params, meta);
        let r: acp::NewSessionResponse = self.typed("session/new", params).await?;
        self.remember(&r.session_id, cwd);
        Ok(r.session_id)
    }

    /// Load a stored session; the agent replays its history as updates before this returns.
    pub async fn load_session(
        &self,
        sid: &SessionId,
        cwd: &Path,
        mcp: Vec<McpServer>,
    ) -> Result<(), Error> {
        let params = json!({"sessionId": sid, "cwd": cwd, "mcpServers": mcp});
        self.typed::<Value>("session/load", params).await?;
        self.remember(sid, cwd);
        Ok(())
    }

    /// Resume a stored session without replaying its history.
    pub async fn resume_session(
        &self,
        sid: &SessionId,
        cwd: &Path,
        mcp: Vec<McpServer>,
    ) -> Result<(), Error> {
        let params = json!({"sessionId": sid, "cwd": cwd, "mcpServers": mcp});
        self.typed::<Value>("session/resume", params).await?;
        self.remember(sid, cwd);
        Ok(())
    }

    pub async fn close_session(&self, sid: &SessionId) -> Result<(), Error> {
        self.typed::<Value>("session/close", json!({"sessionId": sid}))
            .await?;
        self.shared
            .cwds
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&*sid.0);
        Ok(())
    }

    pub async fn set_mode(&self, sid: &SessionId, mode: &str) -> Result<(), Error> {
        self.typed::<Value>(
            "session/set_mode",
            json!({"sessionId": sid, "modeId": mode}),
        )
        .await
        .map(drop)
    }

    /// Run one turn.  No deadline: the turn ends by the agent's answer, [`Conn::cancel`] or the child's exit.
    pub async fn prompt(
        &self,
        sid: &SessionId,
        blocks: Vec<ContentBlock>,
        meta: Option<Value>,
    ) -> Result<PromptOutcome, Error> {
        let mut params = json!({"sessionId": sid, "prompt": blocks});
        set_meta(&mut params, meta);
        let r: acp::PromptResponse = decode(self.call("session/prompt", params, None).await?)?;
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

    /// Ask the agent to stop the session's turn (a notification; the turn's `prompt` then answers `cancelled`).
    pub fn cancel(&self, sid: &SessionId) -> Result<(), Error> {
        let line =
            json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": sid}});
        self.tx.send(line.to_string()).map_err(|_| Error::Closed)
    }

    /// Fork a session, at a message when given (`_meta.jetbrains.air.fork {version: 1, messageId}`).  The new
    /// session starts in the directory of the one it forks, which this connection must have opened.
    pub async fn fork(&self, sid: &SessionId, at: Option<ForkPoint>) -> Result<SessionId, Error> {
        let cwd = self
            .shared
            .cwds
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&*sid.0)
            .cloned()
            .ok_or_else(|| Error::UnknownSession(sid.0.to_string()))?;
        let mut params = json!({"sessionId": sid, "cwd": cwd});
        let meta = at.map(
            |p| json!({"jetbrains": {"air": {"fork": {"version": 1, "messageId": p.message_id}}}}),
        );
        set_meta(&mut params, meta);
        let r: acp::ForkSessionResponse = self.typed("session/fork", params).await?;
        self.remember(&r.session_id, &cwd);
        Ok(r.session_id)
    }

    fn remember(&self, sid: &SessionId, cwd: &Path) {
        self.shared
            .cwds
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(sid.0.to_string(), cwd.to_path_buf());
    }
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
) {
    let mut codec = runstav::line::codec();
    let mut buf = BytesMut::with_capacity(8192);
    loop {
        loop {
            match codec.decode(&mut buf) {
                Ok(Some(line)) => handle(&line, &shared, &wtx, &etx).await,
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
            if let Some(w) = shared.lock_pending().remove(&id) {
                let _ = w.send(Ok(result));
            }
        }
        Message::Error {
            id: Some(id),
            error,
        } => {
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
            let params = params.unwrap_or(Value::Null);
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
