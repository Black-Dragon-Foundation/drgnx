//! The client side of one connection to a debug adapter: requests matched to their answers by `seq`, events and the
//! adapter's own requests (reverse requests) handed out in the order they came, and one end for everyone when the
//! connection goes.
//!
//! The client keeps no timers: a caller that wants a deadline wraps [`Client::request`] in its own (the hub uses its
//! clock). A request future that is dropped forgets its `seq`, so an answer that comes later is ignored.
use crate::codec::{DapCodec, Frame};
use crate::message::Message;
use crate::{Event, Request};
use serde_json::Value;
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot};
use tokio_util::bytes::BytesMut;
use tokio_util::codec::{Decoder, Encoder};

/// Why a request got no answer.
#[derive(Debug, Clone, PartialEq)]
pub enum Error {
    /// The adapter answered `success: false`.
    Failed {
        command: String,
        message: String,
        body: Value,
    },
    /// The connection ended (the adapter exited, closed its end or broke the framing) before the answer.
    Closed(String),
    /// The answer's body did not have the shape the request's type says.
    Shape { command: String, error: String },
}

impl std::error::Error for Error {}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Failed {
                command, message, ..
            } => write!(f, "{command}: {message}"),
            Error::Closed(why) => write!(f, "the debug adapter's connection ended: {why}"),
            Error::Shape { command, error } => {
                write!(f, "{command}: an answer of another shape: {error}")
            }
        }
    }
}

/// What the adapter sends on its own: an event, or a request the client answers.
#[derive(Debug)]
pub enum Incoming {
    Event {
        event: String,
        body: Value,
    },
    Request(ReverseRequest),
    /// A frame that was not a message (logged by the caller; the connection goes on).
    Bad(String),
}

/// An event's body as `E`'s type.
pub fn event_body<E: Event>(body: &Value) -> Result<E::Body, serde_json::Error> {
    serde_json::from_value(if body.is_null() {
        Value::Object(Default::default())
    } else {
        body.clone()
    })
}

/// A request from the adapter (`runInTerminal`, `startDebugging`). Answer it with [`ReverseRequest::ok`] or
/// [`ReverseRequest::err`]; one dropped unanswered is answered `success: false` ("not handled"), so the adapter never
/// waits forever.
#[derive(Debug)]
pub struct ReverseRequest {
    pub seq: i64,
    pub command: String,
    pub arguments: Value,
    client: Client,
    answered: bool,
}

impl ReverseRequest {
    pub fn ok(mut self, body: Value) {
        self.answered = true;
        self.client
            .answer(self.seq, &self.command, true, None, body);
    }

    pub fn err(mut self, message: &str) {
        self.answered = true;
        self.client.answer(
            self.seq,
            &self.command,
            false,
            Some(message.to_owned()),
            Value::Null,
        );
    }
}

impl Drop for ReverseRequest {
    fn drop(&mut self) {
        if !self.answered {
            self.client.answer(
                self.seq,
                &self.command,
                false,
                Some("not handled".to_owned()),
                Value::Null,
            );
        }
    }
}

type Waiter = oneshot::Sender<Result<Value, Error>>;
/// Open requests by `seq` (with their command), or why the connection ended.
type PendingMap = Result<HashMap<i64, (String, Waiter)>, String>;

#[derive(Debug)]
struct Inner {
    out: mpsc::UnboundedSender<Message>,
    seq: AtomicI64,
    /// Requests sent and not yet answered, by `seq`; `Err(why)` once the connection ended.
    pending: Mutex<PendingMap>,
}

/// One connection. Clones share it.
#[derive(Debug, Clone)]
pub struct Client {
    inner: Arc<Inner>,
}

impl Client {
    /// A client over a TCP connection to an adapter's port.
    pub fn tcp(stream: tokio::net::TcpStream) -> (Client, mpsc::UnboundedReceiver<Incoming>) {
        let (r, w) = stream.into_split();
        Client::new(r, w)
    }

    /// Connects to ADDR, the port an adapter was told to listen on, trying again every 50 ms for WITHIN (adapters open
    /// their port a moment after they start). The error names the address and the last refusal.
    pub async fn connect_tcp(
        addr: std::net::SocketAddr,
        within: std::time::Duration,
    ) -> std::io::Result<(Client, mpsc::UnboundedReceiver<Incoming>)> {
        let deadline = tokio::time::Instant::now() + within;
        loop {
            match tokio::net::TcpStream::connect(addr).await {
                Ok(s) => return Ok(Client::tcp(s)),
                Err(e) if tokio::time::Instant::now() >= deadline => {
                    return Err(std::io::Error::new(
                        e.kind(),
                        format!("no debug adapter on {addr} after {within:?}: {e}"),
                    ));
                }
                Err(_) => tokio::time::sleep(std::time::Duration::from_millis(50)).await,
            }
        }
    }

    /// A client over a child's stdout and stdin (taken from it), or `None` when they were not piped.
    pub fn stdio(
        child: &mut tokio::process::Child,
    ) -> Option<(Client, mpsc::UnboundedReceiver<Incoming>)> {
        let out = child.stdout.take()?;
        let inp = child.stdin.take()?;
        Some(Client::new(out, inp))
    }

    /// `cancel` of the request with `seq` REQUEST_SEQ (only when the adapter has `supportsCancelRequest`; the
    /// cancelled request still gets an answer, usually `success: false` with `cancelled`).
    pub fn cancel(&self, request_seq: i64) -> Pending {
        self.request("cancel", serde_json::json!({ "requestId": request_seq }))
    }

    /// A client over READ / WRITE (an adapter's stdout / stdin, or the two halves of a socket), and the stream of what
    /// the adapter sends on its own. The stream ends after the connection does, once every waiter got its error.
    pub fn new<R, W>(read: R, write: W) -> (Client, mpsc::UnboundedReceiver<Incoming>)
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();
        let (in_tx, in_rx) = mpsc::unbounded_channel();
        let inner = Arc::new(Inner {
            out: out_tx,
            seq: AtomicI64::new(0),
            pending: Mutex::new(Ok(HashMap::new())),
        });
        let client = Client { inner };
        // the writer: ends when every sender is gone or a write fails (the reader then sees the end too)
        let weak = Arc::downgrade(&client.inner);
        tokio::spawn(async move {
            let mut write = write;
            let mut codec = DapCodec::default();
            let mut buf = BytesMut::new();
            while let Some(m) = out_rx.recv().await {
                buf.clear();
                let r = match codec.encode(m, &mut buf) {
                    Ok(()) => write.write_all(&buf).await.and(write.flush().await),
                    Err(e) => Err(e),
                };
                if let Err(e) = r {
                    if let Some(inner) = weak.upgrade() {
                        close(&inner, &format!("a write failed: {e}"));
                    }
                    return;
                }
            }
        });
        // the reader: frames in the order they came, then one end
        let weak = Arc::downgrade(&client.inner);
        tokio::spawn(async move {
            let mut read = read;
            let mut codec = DapCodec::default();
            let mut buf = BytesMut::with_capacity(16 * 1024);
            let why = 'read: loop {
                loop {
                    match codec.decode(&mut buf) {
                        Ok(None) => break,
                        Err(e) => break 'read format!("a framing error: {e}"),
                        Ok(Some(Frame::Bad(why))) => {
                            let _ = in_tx.send(Incoming::Bad(why));
                        }
                        Ok(Some(Frame::Message(m))) => {
                            let Some(inner) = weak.upgrade() else { return };
                            dispatch(&inner, m, &in_tx);
                        }
                    }
                }
                match read.read_buf(&mut buf).await {
                    Ok(0) => break "the adapter closed its output".to_owned(),
                    Ok(_) => {}
                    Err(e) => break format!("a read failed: {e}"),
                }
            };
            if let Some(inner) = weak.upgrade() {
                close(&inner, &why);
            }
        });
        (client, in_rx)
    }

    /// The next `seq`.
    fn next_seq(&self) -> i64 {
        self.inner.seq.fetch_add(1, Ordering::Relaxed) + 1
    }

    fn answer(
        &self,
        request_seq: i64,
        command: &str,
        success: bool,
        message: Option<String>,
        body: Value,
    ) {
        let seq = self.next_seq();
        let _ = self.inner.out.send(Message::Response {
            seq,
            request_seq,
            success,
            command: command.to_owned(),
            message,
            body,
        });
    }

    /// Sends COMMAND with ARGUMENTS; the future answers the response's body (or why there is none). Its `seq` is
    /// [`Pending::seq`], for a `cancel`.
    pub fn request(&self, command: &str, arguments: Value) -> Pending {
        let seq = self.next_seq();
        let (tx, rx) = oneshot::channel();
        {
            let mut p = self.inner.pending.lock().unwrap();
            match &mut *p {
                Ok(map) => {
                    map.insert(seq, (command.to_owned(), tx));
                }
                Err(why) => {
                    let _ = tx.send(Err(Error::Closed(why.clone())));
                }
            }
        }
        let _ = self.inner.out.send(Message::Request {
            seq,
            command: command.to_owned(),
            arguments,
        });
        Pending {
            seq,
            rx,
            inner: Arc::downgrade(&self.inner),
        }
    }

    /// `R` with ARGS, its answer as `R`'s body type.
    pub async fn send<R: Request>(&self, args: &R::Arguments) -> Result<R::Body, Error> {
        let args = serde_json::to_value(args).map_err(|e| Error::Shape {
            command: R::COMMAND.to_owned(),
            error: e.to_string(),
        })?;
        let body = self.request(R::COMMAND, args).await?;
        let body = if body.is_null() {
            Value::Object(Default::default())
        } else {
            body
        };
        serde_json::from_value(body).map_err(|e| Error::Shape {
            command: R::COMMAND.to_owned(),
            error: e.to_string(),
        })
    }

    /// Whether the connection has ended.
    pub fn is_closed(&self) -> bool {
        self.inner.pending.lock().unwrap().is_err()
    }

    /// Ends the connection from this side: every waiter gets [`Error::Closed`] with WHY.
    pub fn close(&self, why: &str) {
        close(&self.inner, why);
    }
}

fn close(inner: &Inner, why: &str) {
    let waiters = {
        let mut p = inner.pending.lock().unwrap();
        match std::mem::replace(&mut *p, Err(why.to_owned())) {
            Ok(map) => map,
            Err(old) => {
                *p = Err(old);
                return;
            }
        }
    };
    for (_, (_, tx)) in waiters {
        let _ = tx.send(Err(Error::Closed(why.to_owned())));
    }
}

fn dispatch(inner: &Arc<Inner>, m: Message, in_tx: &mpsc::UnboundedSender<Incoming>) {
    match m {
        Message::Response {
            request_seq,
            success,
            command,
            message,
            body,
            ..
        } => {
            let waiter = match &mut *inner.pending.lock().unwrap() {
                Ok(map) => map.remove(&request_seq),
                Err(_) => None,
            };
            if let Some((_, tx)) = waiter {
                let r = if success {
                    Ok(body)
                } else {
                    Err(Error::Failed {
                        command,
                        message: message.unwrap_or_default(),
                        body,
                    })
                };
                let _ = tx.send(r);
            }
        }
        Message::Event { event, body, .. } => {
            let _ = in_tx.send(Incoming::Event { event, body });
        }
        Message::Request {
            seq,
            command,
            arguments,
        } => {
            let _ = in_tx.send(Incoming::Request(ReverseRequest {
                seq,
                command,
                arguments,
                client: Client {
                    inner: inner.clone(),
                },
                answered: false,
            }));
        }
    }
}

/// A request's answer to come. Dropping it forgets the request.
#[derive(Debug)]
pub struct Pending {
    seq: i64,
    rx: oneshot::Receiver<Result<Value, Error>>,
    inner: std::sync::Weak<Inner>,
}

impl Pending {
    pub fn seq(&self) -> i64 {
        self.seq
    }
}

impl Future for Pending {
    type Output = Result<Value, Error>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        match Pin::new(&mut self.rx).poll(cx) {
            Poll::Ready(Ok(r)) => Poll::Ready(r),
            Poll::Ready(Err(_)) => Poll::Ready(Err(Error::Closed("the client is gone".to_owned()))),
            Poll::Pending => Poll::Pending,
        }
    }
}

impl Drop for Pending {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.upgrade()
            && let Ok(map) = &mut *inner.pending.lock().unwrap()
        {
            map.remove(&self.seq);
        }
    }
}
