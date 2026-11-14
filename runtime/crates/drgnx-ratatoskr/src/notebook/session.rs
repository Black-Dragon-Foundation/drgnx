//! The four sockets of one kernel (design §5.1, §5.2): shell, stdin and control are DEALERs (shell and stdin share one routing
//! identity, or the kernel's `input_request` finds no one), iopub is a SUB.
//!
//! One reader task per socket owns its receive half and never does anything else: it **always drains** the socket, decodes and
//! verifies each message, and queues it. The queue is bounded in **bytes**, not messages (a kernel's flood of small ones is as
//! bad as one big one): past [`Limits::flood_bytes`] unread the reader stops and reports [`Event::Flood`], which the kernel's
//! owner answers by killing the kernel. A writer task per sending socket takes messages from a bounded queue and gives every
//! send a deadline, so a kernel that stopped reading stalls nobody. A message that does not verify is dropped and counted.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use tokio::sync::mpsc;
use zeromq::{DealerSocket, Socket, SocketOptions, SocketRecv, SocketSend, SubSocket, ZmqMessage};

use super::spec::Connection;
use super::wire::{self, Key, Message};

/// A socket of the kernel.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Channel {
    Shell,
    Iopub,
    Stdin,
    Control,
}

impl Channel {
    pub fn name(self) -> &'static str {
        match self {
            Channel::Shell => "shell",
            Channel::Iopub => "iopub",
            Channel::Stdin => "stdin",
            Channel::Control => "control",
        }
    }
}

/// What the readers report.
#[derive(Debug)]
pub enum Event {
    /// A message that verified; BYTES is its size on the wire.
    Message {
        channel: Channel,
        message: Box<Message>,
        bytes: usize,
    },
    /// A socket failed (the kernel is probably gone).
    Closed { channel: Channel, why: String },
    /// More than [`Limits::flood_bytes`] arrived unread: the kernel is to be killed.
    Flood,
}

#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub flood_bytes: usize,
    /// How long one send may take.
    pub send_within: Duration,
    /// Messages waiting to be sent, per socket.
    pub send_queue: usize,
    /// One message, as weighed: past this it is replaced by a note and the kernel carries on (it is not a flood).
    pub message_bytes: usize,
    /// Messages that do not verify, within BAD_WINDOW, before the kernel counts as flooding.
    pub bad_count: usize,
    pub bad_window: Duration,
}

impl Default for Limits {
    fn default() -> Limits {
        Limits {
            flood_bytes: 64 << 20,
            send_within: Duration::from_secs(10),
            send_queue: 64,
            message_bytes: 16 << 20,
            bad_count: 1000,
            bad_window: Duration::from_secs(10),
        }
    }
}

/// Messages dropped, by reason.
#[derive(Debug, Default)]
pub struct Dropped {
    pub bad: AtomicUsize,
}

pub struct Session {
    events: mpsc::UnboundedReceiver<Event>,
    queued: Arc<AtomicUsize>,
    dropped: Arc<Dropped>,
    key: Key,
    shell: mpsc::Sender<ZmqMessage>,
    stdin: mpsc::Sender<ZmqMessage>,
    control: mpsc::Sender<ZmqMessage>,
    limits: Limits,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

fn endpoint(prefix: &std::path::Path, n: usize) -> String {
    format!("ipc://{}-{n}", prefix.display())
}

fn dealer(identity: &[u8]) -> Result<DealerSocket, String> {
    let mut o = SocketOptions::default();
    o.peer_identity(
        identity
            .to_vec()
            .try_into()
            .map_err(|_| "a socket identity of 1 to 255 bytes".to_string())?,
    );
    Ok(DealerSocket::with_options(o))
}

pub(crate) fn frames(m: ZmqMessage) -> Vec<Vec<u8>> {
    m.into_vec().into_iter().map(|b| b.to_vec()).collect()
}

impl Session {
    /// Connect to the kernel's four sockets (their files must exist: the kernel binds them).
    pub async fn connect(
        conn: &Connection,
        identity: &str,
        limits: Limits,
    ) -> Result<Session, String> {
        let (events_tx, events) = mpsc::unbounded_channel();
        let queued = Arc::new(AtomicUsize::new(0));
        let dropped = Arc::new(Dropped::default());
        let mut tasks = Vec::new();
        let mut shell = dealer(identity.as_bytes())?;
        let mut stdin = dealer(identity.as_bytes())?;
        let mut control = DealerSocket::new();
        let mut iopub = SubSocket::new();
        let at = |n| endpoint(&conn.prefix, n);
        shell
            .connect(&at(1))
            .await
            .map_err(|e| format!("shell: {e}"))?;
        iopub
            .connect(&at(2))
            .await
            .map_err(|e| format!("iopub: {e}"))?;
        stdin
            .connect(&at(3))
            .await
            .map_err(|e| format!("stdin: {e}"))?;
        control
            .connect(&at(4))
            .await
            .map_err(|e| format!("control: {e}"))?;
        iopub
            .subscribe("")
            .await
            .map_err(|e| format!("iopub subscribe: {e}"))?;
        let mut sender = |sock: DealerSocket, channel: Channel| {
            let (mut send, recv) = sock.split();
            let (tx, mut rx) = mpsc::channel::<ZmqMessage>(limits.send_queue);
            let events_tx2 = events_tx.clone();
            tasks.push(crate::clock::spawn(
                format!("notebook-{}-writer", channel.name()),
                async move {
                    while let Some(m) = rx.recv().await {
                        let sent = crate::clock::timeout(limits.send_within, send.send(m)).await;
                        let why = match sent {
                            Ok(Ok(())) => continue,
                            Ok(Err(e)) => e.to_string(),
                            Err(_) => "a send took too long".to_string(),
                        };
                        let _ = events_tx2.send(Event::Closed { channel, why });
                        return;
                    }
                },
            ));
            tasks.push(reader(
                channel,
                recv,
                events_tx.clone(),
                queued.clone(),
                dropped.clone(),
                conn.key.clone(),
                limits,
            ));
            tx
        };
        let shell_tx = sender(shell, Channel::Shell);
        let stdin_tx = sender(stdin, Channel::Stdin);
        let control_tx = sender(control, Channel::Control);
        tasks.push(reader(
            Channel::Iopub,
            iopub,
            events_tx,
            queued.clone(),
            dropped.clone(),
            conn.key.clone(),
            limits,
        ));
        Ok(Session {
            events,
            queued,
            dropped,
            key: conn.key.clone(),
            shell: shell_tx,
            stdin: stdin_tx,
            control: control_tx,
            limits,
            tasks,
        })
    }

    /// The next event; the bytes of a message leave the flood count when it is taken.
    pub async fn next(&mut self) -> Option<Event> {
        let e = self.events.recv().await?;
        if let Event::Message { bytes, .. } = &e {
            self.queued.fetch_sub(*bytes, Ordering::SeqCst);
        }
        Some(e)
    }

    /// The next event if one is waiting.
    pub fn try_next(&mut self) -> Option<Event> {
        let e = self.events.try_recv().ok()?;
        if let Event::Message { bytes, .. } = &e {
            self.queued.fetch_sub(*bytes, Ordering::SeqCst);
        }
        Some(e)
    }

    /// Queue MESSAGE for CHANNEL (shell, stdin or control); an error when the queue is full or the socket is gone.
    pub fn send(&self, channel: Channel, message: &Message) -> Result<(), String> {
        let tx = match channel {
            Channel::Shell => &self.shell,
            Channel::Stdin => &self.stdin,
            Channel::Control => &self.control,
            Channel::Iopub => return Err("iopub only receives".into()),
        };
        let frames: Vec<bytes::Bytes> = wire::encode(&self.key, message)
            .into_iter()
            .map(bytes::Bytes::from)
            .collect();
        let m =
            ZmqMessage::try_from(frames).map_err(|e| format!("a message of no frames: {e:?}"))?;
        tx.try_send(m)
            .map_err(|e| format!("{} is not taking messages: {e}", channel.name()))
    }

    /// How many messages did not verify or were not messages.
    pub fn bad(&self) -> usize {
        self.dropped.bad.load(Ordering::SeqCst)
    }

    pub fn limits(&self) -> Limits {
        self.limits
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        for t in &self.tasks {
            t.abort();
        }
    }
}

/// A receiving socket (or half of one).
trait Recv: Send + 'static {
    fn next(&mut self) -> impl std::future::Future<Output = Result<Vec<Vec<u8>>, String>> + Send;
}

impl Recv for zeromq::DealerRecvHalf {
    async fn next(&mut self) -> Result<Vec<Vec<u8>>, String> {
        self.recv().await.map(frames).map_err(|e| e.to_string())
    }
}

impl Recv for SubSocket {
    async fn next(&mut self) -> Result<Vec<Vec<u8>>, String> {
        self.recv().await.map(frames).map_err(|e| e.to_string())
    }
}

/// MESSAGE of WEIGHT (over LIMIT) as a note of the same kind, so the cell it belongs to says what happened; None for a kind of message
/// that shows nothing.
fn stub(m: Message, weight: usize, limit: usize) -> Option<Message> {
    let note = format!(
        "[a {} MiB message from the kernel was not shown: over the {} MiB limit]",
        weight >> 20,
        limit >> 20
    );
    let keep = |k: &str| m.content.get(k).cloned();
    let content = match m.header.msg_type.as_str() {
        "stream" => {
            serde_json::json!({"name": keep("name").unwrap_or_else(|| "stdout".into()), "text": note})
        }
        "display_data" | "update_display_data" | "execute_result" => serde_json::json!({
            "data": {"text/plain": note}, "metadata": {},
            "transient": keep("transient").unwrap_or(serde_json::json!({})),
            "execution_count": keep("execution_count").unwrap_or(serde_json::Value::Null),
        }),
        "error" => serde_json::json!({"ename": "OutputTooLarge", "evalue": note, "traceback": []}),
        _ => return None,
    };
    Some(Message {
        idents: m.idents,
        header: m.header,
        parent: m.parent,
        metadata: serde_json::json!({}),
        content,
        buffers: Vec::new(),
    })
}

/// What a value holds in memory, about: a node costs a few words however short its text.
fn weigh(v: &serde_json::Value) -> usize {
    use serde_json::Value;
    const NODE: usize = 32;
    match v {
        Value::String(s) => NODE + s.len(),
        Value::Array(a) => NODE + a.iter().map(weigh).sum::<usize>(),
        Value::Object(o) => {
            NODE + o
                .iter()
                .map(|(k, v)| NODE + k.len() + weigh(v))
                .sum::<usize>()
        }
        _ => NODE,
    }
}

fn weight(m: &Message) -> usize {
    weigh(&m.content)
        + weigh(&m.parent)
        + weigh(&m.metadata)
        + m.buffers.iter().map(Vec::len).sum::<usize>()
}

/// A reader task: RECV is asked for one message at a time and nothing else happens in the task.
fn reader<R: Recv>(
    channel: Channel,
    mut socket: R,
    events: mpsc::UnboundedSender<Event>,
    queued: Arc<AtomicUsize>,
    dropped: Arc<Dropped>,
    key: Key,
    limits: Limits,
) -> tokio::task::JoinHandle<()> {
    crate::clock::spawn(format!("notebook-{}-reader", channel.name()), async move {
        // the start of the window, the messages that did not verify in it, their bytes
        let mut bad = (crate::clock::now(), 0usize, 0usize);
        loop {
            let frames = match socket.next().await {
                Ok(f) => f,
                Err(why) => {
                    let _ = events.send(Event::Closed { channel, why });
                    return;
                }
            };
            let wire_bytes: usize = frames.iter().map(Vec::len).sum();
            let mut bytes = wire_bytes;
            match wire::decode(&key, &frames) {
                Ok(message) => {
                    // what it holds decoded, not what it took on the wire: a small message can be a large value
                    bytes = bytes.max(weight(&message));
                    // one large message is a large message, not a flood: shown as a note, the rest of the kernel's output goes on
                    let message = if bytes > limits.message_bytes {
                        match stub(message, bytes, limits.message_bytes) {
                            Some(m) => {
                                bytes = weight(&m);
                                m
                            }
                            None => continue,
                        }
                    } else {
                        message
                    };
                    if queued.fetch_add(bytes, Ordering::SeqCst) + bytes > limits.flood_bytes {
                        let _ = events.send(Event::Flood);
                        return;
                    }
                    if events
                        .send(Event::Message {
                            channel,
                            message: Box::new(message),
                            bytes,
                        })
                        .is_err()
                    {
                        return;
                    }
                }
                Err(_) => {
                    dropped.bad.fetch_add(1, Ordering::SeqCst);
                    // a flood of garbage is a flood too: too many within a window, or too many bytes
                    let now = crate::clock::now();
                    if now.duration_since(bad.0) > limits.bad_window {
                        bad = (now, 0, 0);
                    }
                    bad.1 += 1;
                    bad.2 += bytes;
                    if bad.1 > limits.bad_count || bad.2 > limits.flood_bytes {
                        let _ = events.send(Event::Flood);
                        return;
                    }
                }
            }
        }
    })
}

#[cfg(test)]
mod tests;
