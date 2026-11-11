//! A mock debug adapter for tests (feature `mock`): it plays a [`Script`] of expected requests with canned answers,
//! events and reverse requests, and fails on any request it did not expect. The hub's tests run it on a pipe; the
//! `vor-mock` binary runs it on stdio for ERT.
//!
//! A script is a JSON array of steps, played in order:
//!
//! - `{"expect": CMD, "args"?: A, "ok"?: BODY}`: the next request is CMD, and its arguments contain A (objects by key,
//!   arrays element by element, the rest equal). It is answered with BODY (default `{}`); `"fail": MSG` answers
//!   `success: false`; `"defer": true` answers later at an `answer` step; `"silent": true` never answers.
//! - `{"any": [EXPECT…]}`: those requests in any order.
//! - `{"answer": CMD, "ok"?: BODY}` / `"fail"`: the answer of the deferred request CMD.
//! - `{"event": NAME, "body"?: BODY}`: an event.
//! - `{"reverse": CMD, "arguments": A, "answer"?: B, "wait"?: true}`: a reverse request; its answer must succeed and
//!   contain B. With `wait` the script holds until it is answered, and a request that comes first fails it (a
//!   barrier: "the client sends nothing before this answer").
//! - `{"die": true}`: the adapter goes (the connection closes).
//!
//! The script fails when a request does not match, when one comes after the end, or when the client leaves before the
//! end; [`Mock::finish`] says how, naming what it expected and what came.
use crate::codec::{DapCodec, Frame};
use crate::message::Message;
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::task::JoinHandle;
use tokio_util::bytes::BytesMut;
use tokio_util::codec::{Decoder, Encoder};

/// How an expected request is answered.
#[derive(Debug, Clone, PartialEq)]
pub enum Reply {
    Ok(Value),
    Fail(String),
    Defer,
    Silent,
}

/// One expected request.
#[derive(Debug, Clone, PartialEq)]
pub struct Expect {
    pub command: String,
    pub args: Option<Value>,
    pub reply: Reply,
}

/// One step of a [`Script`].
#[derive(Debug, Clone, PartialEq)]
pub enum Step {
    Expect(Expect),
    Any(Vec<Expect>),
    Answer {
        command: String,
        reply: Reply,
    },
    Event {
        event: String,
        body: Value,
    },
    Reverse {
        command: String,
        arguments: Value,
        answer: Option<Value>,
        wait: bool,
    },
    Die,
}

/// The steps, in order.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Script(pub Vec<Step>);

/// What the mock saw: every request, with its arguments, in order.
#[derive(Debug, Clone, Default)]
pub struct Log {
    pub requests: Vec<(String, Value)>,
}

impl Log {
    pub fn commands(&self) -> Vec<&str> {
        self.requests.iter().map(|(c, _)| c.as_str()).collect()
    }
}

fn reply_of(o: &serde_json::Map<String, Value>) -> Reply {
    if let Some(m) = o.get("fail") {
        Reply::Fail(m.as_str().unwrap_or("failed").to_owned())
    } else if o.get("defer") == Some(&Value::Bool(true)) {
        Reply::Defer
    } else if o.get("silent") == Some(&Value::Bool(true)) {
        Reply::Silent
    } else {
        Reply::Ok(o.get("ok").cloned().unwrap_or_else(|| json!({})))
    }
}

fn expect_of(o: &serde_json::Map<String, Value>) -> Option<Expect> {
    Some(Expect {
        command: o.get("expect")?.as_str()?.to_owned(),
        args: o.get("args").cloned(),
        reply: reply_of(o),
    })
}

fn step_of(v: &Value) -> Result<Step, String> {
    let o = v
        .as_object()
        .ok_or_else(|| format!("a step is an object: {v}"))?;
    let s = |k: &str| o.get(k).and_then(Value::as_str).map(str::to_owned);
    if o.contains_key("expect") {
        expect_of(o)
            .map(Step::Expect)
            .ok_or_else(|| format!("expect needs a command: {v}"))
    } else if let Some(Value::Array(a)) = o.get("any") {
        a.iter()
            .map(|e| {
                e.as_object()
                    .and_then(expect_of)
                    .ok_or_else(|| format!("any holds expect steps: {e}"))
            })
            .collect::<Result<_, _>>()
            .map(Step::Any)
    } else if let Some(command) = s("answer") {
        Ok(Step::Answer {
            command,
            reply: reply_of(o),
        })
    } else if let Some(event) = s("event") {
        Ok(Step::Event {
            event,
            body: o.get("body").cloned().unwrap_or(Value::Null),
        })
    } else if let Some(command) = s("reverse") {
        Ok(Step::Reverse {
            command,
            arguments: o.get("arguments").cloned().unwrap_or_else(|| json!({})),
            answer: o.get("answer").cloned(),
            wait: o.get("wait") == Some(&Value::Bool(true)),
        })
    } else if o.get("die") == Some(&Value::Bool(true)) {
        Ok(Step::Die)
    } else {
        Err(format!("not a step: {v}"))
    }
}

impl<'de> Deserialize<'de> for Script {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Script, D::Error> {
        let steps = Vec::<Value>::deserialize(d)?;
        steps
            .iter()
            .map(step_of)
            .collect::<Result<_, _>>()
            .map(Script)
            .map_err(serde::de::Error::custom)
    }
}

/// Whether HAVE contains WANT; the error names the path that differs.
pub fn contains(have: &Value, want: &Value) -> Result<(), String> {
    fn go(have: &Value, want: &Value, path: &str) -> Result<(), String> {
        match (have, want) {
            (Value::Object(h), Value::Object(w)) => {
                for (k, wv) in w {
                    let p = if path.is_empty() {
                        k.clone()
                    } else {
                        format!("{path}.{k}")
                    };
                    match h.get(k) {
                        Some(hv) => go(hv, wv, &p)?,
                        None => return Err(format!("{p}: missing, want {wv}")),
                    }
                }
                Ok(())
            }
            (Value::Array(h), Value::Array(w)) if h.len() == w.len() => h
                .iter()
                .zip(w)
                .enumerate()
                .try_for_each(|(i, (hv, wv))| go(hv, wv, &format!("{path}[{i}]"))),
            _ if have == want => Ok(()),
            _ => Err(format!("{path}: want {want}, got {have}")),
        }
    }
    go(have, want, "")
}

/// A running mock.
pub struct Mock {
    task: JoinHandle<Result<Log, String>>,
}

impl Mock {
    /// Play SCRIPT on READ / WRITE (the client's stdin / stdout, or one end of a pipe).
    pub fn start<R, W>(script: Script, read: R, write: W) -> Mock
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        Mock {
            task: tokio::spawn(play(script, read, write)),
        }
    }

    /// Waits for the connection to end: the log, or how the script failed.
    pub async fn finish(self) -> Result<Log, String> {
        self.task
            .await
            .map_err(|e| format!("the mock panicked: {e}"))?
    }
}

struct Player<W> {
    write: W,
    seq: i64,
    log: Log,
    error: Option<String>,
    deferred: HashMap<String, (i64, String)>,
    /// Reverse requests sent and not yet answered: seq → (command, what the answer must contain).
    reverse: HashMap<i64, (String, Option<Value>)>,
    /// A `wait` reverse request not yet answered: (seq, command).
    waiting: Option<(i64, String)>,
}

impl<W: AsyncWrite + Unpin> Player<W> {
    fn fail(&mut self, why: String) {
        self.error.get_or_insert(why);
    }

    async fn send(&mut self, m: Message) -> std::io::Result<()> {
        let mut buf = BytesMut::new();
        DapCodec::default().encode(m, &mut buf)?;
        self.write.write_all(&buf).await?;
        self.write.flush().await
    }

    fn next_seq(&mut self) -> i64 {
        self.seq += 1;
        self.seq
    }

    async fn respond(
        &mut self,
        request_seq: i64,
        command: &str,
        reply: &Reply,
    ) -> std::io::Result<()> {
        let (success, message, body) = match reply {
            Reply::Ok(b) => (true, None, b.clone()),
            Reply::Fail(m) => (false, Some(m.clone()), Value::Null),
            Reply::Defer => {
                self.deferred
                    .insert(command.to_owned(), (request_seq, command.to_owned()));
                return Ok(());
            }
            Reply::Silent => return Ok(()),
        };
        let seq = self.next_seq();
        self.send(Message::Response {
            seq,
            request_seq,
            success,
            command: command.to_owned(),
            message,
            body,
        })
        .await
    }
}

fn describe(e: &Expect) -> String {
    match &e.args {
        Some(a) => format!("{} {a}", e.command),
        None => e.command.clone(),
    }
}

fn describe_step(s: &Step) -> String {
    match s {
        Step::Expect(e) => format!("expected {}", describe(e)),
        Step::Any(es) => format!(
            "expected any of [{}]",
            es.iter().map(describe).collect::<Vec<_>>().join(", ")
        ),
        Step::Answer { command, .. } => format!("the answer to {command}"),
        Step::Event { event, .. } => format!("the event {event}"),
        Step::Reverse { command, .. } => format!("the reverse request {command}"),
        Step::Die => "the end".to_owned(),
    }
}

async fn play<R, W>(script: Script, mut read: R, write: W) -> Result<Log, String>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut steps: VecDeque<Step> = script.0.into();
    let mut p = Player {
        write,
        seq: 0,
        log: Log::default(),
        error: None,
        deferred: HashMap::new(),
        reverse: HashMap::new(),
        waiting: None,
    };
    let mut codec = DapCodec::default();
    let mut buf = BytesMut::new();
    'outer: loop {
        // the steps that need no request
        while let Some(step) = steps.front() {
            if p.waiting.is_some() {
                break;
            }
            match step.clone() {
                Step::Expect(_) | Step::Any(_) => break,
                Step::Event { event, body } => {
                    let seq = p.next_seq();
                    let _ = p.send(Message::Event { seq, event, body }).await;
                }
                Step::Answer { command, reply } => match p.deferred.remove(&command) {
                    Some((request_seq, cmd)) => {
                        let _ = p.respond(request_seq, &cmd, &reply).await;
                    }
                    None => p.fail(format!("no deferred {command} to answer")),
                },
                Step::Reverse {
                    command,
                    arguments,
                    answer,
                    wait,
                } => {
                    let seq = p.next_seq();
                    p.reverse.insert(seq, (command.clone(), answer));
                    if wait {
                        p.waiting = Some((seq, command.clone()));
                    }
                    let _ = p
                        .send(Message::Request {
                            seq,
                            command,
                            arguments,
                        })
                        .await;
                }
                Step::Die => {
                    steps.pop_front();
                    break 'outer;
                }
            }
            steps.pop_front();
        }
        // the next message from the client
        let msg = loop {
            match codec.decode(&mut buf) {
                Ok(Some(Frame::Message(m))) => break Some(m),
                Ok(Some(Frame::Bad(why))) => {
                    p.fail(format!("a bad message from the client: {why}"))
                }
                Ok(None) => match read.read_buf(&mut buf).await {
                    Ok(0) | Err(_) => break None,
                    Ok(_) => {}
                },
                Err(e) => {
                    p.fail(format!("a broken frame from the client: {e}"));
                    break None;
                }
            }
        };
        let Some(msg) = msg else {
            if let Some(s) = steps.front() {
                let why = format!(
                    "the client left before the script's end ({})",
                    describe_step(s)
                );
                p.fail(why);
            }
            break;
        };
        match msg {
            Message::Request {
                seq,
                command,
                arguments,
            } => {
                p.log.requests.push((command.clone(), arguments.clone()));
                let found = match (&p.waiting, steps.front_mut()) {
                    (Some((_, w)), _) => Err(format!(
                        "got {command} {arguments} before the answer to the reverse request {w}"
                    )),
                    (None, s) => match s {
                        Some(Step::Expect(e)) => {
                            let r = match_one(e, &command, &arguments).map(|()| e.reply.clone());
                            if r.is_ok() {
                                steps.pop_front();
                            }
                            r
                        }
                        Some(Step::Any(es)) => {
                            let hit = es
                                .iter()
                                .position(|e| match_one(e, &command, &arguments).is_ok());
                            match hit {
                                Some(i) => {
                                    let r = es.remove(i).reply;
                                    if es.is_empty() {
                                        steps.pop_front();
                                    }
                                    Ok(r)
                                }
                                None => Err(format!(
                                    "{}, got {command} {arguments}",
                                    describe_step(&Step::Any(es.clone()))
                                )),
                            }
                        }
                        _ => Err(format!("got {command} {arguments} after the script's end")),
                    },
                };
                match found {
                    Ok(reply) => {
                        let _ = p.respond(seq, &command, &reply).await;
                    }
                    Err(why) => {
                        p.fail(why);
                        let _ = p
                            .respond(seq, &command, &Reply::Fail("mock: not expected".to_owned()))
                            .await;
                    }
                }
            }
            Message::Response {
                request_seq,
                success,
                body,
                message,
                ..
            } => {
                if p.waiting.as_ref().is_some_and(|(s, _)| *s == request_seq) {
                    p.waiting = None;
                }
                match p.reverse.remove(&request_seq) {
                    Some((command, _)) if !success => p.fail(format!(
                        "the reverse request {command} was refused: {}",
                        message.unwrap_or_default()
                    )),
                    Some((command, Some(want))) => {
                        if let Err(e) = contains(&body, &want) {
                            p.fail(format!("the answer to {command}: {e}"));
                        }
                    }
                    Some(_) => {}
                    None => p.fail(format!("an answer to no request ({request_seq})")),
                }
            }
            Message::Event { event, .. } => p.fail(format!("a client sent an event ({event})")),
        }
    }
    for (command, _) in p.reverse.values() {
        p.error
            .get_or_insert(format!("the reverse request {command} was never answered"));
    }
    match p.error {
        Some(e) => Err(e),
        None => Ok(p.log),
    }
}

fn match_one(e: &Expect, command: &str, arguments: &Value) -> Result<(), String> {
    if e.command != command {
        return Err(format!(
            "expected {}, got {command} {arguments}",
            describe(e)
        ));
    }
    match &e.args {
        Some(want) => {
            contains(arguments, want).map_err(|why| format!("{command}'s arguments: {why}"))
        }
        None => Ok(()),
    }
}
