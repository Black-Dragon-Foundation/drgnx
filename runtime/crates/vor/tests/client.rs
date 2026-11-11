//! The client against a hand-driven adapter on an in-memory pipe (and one TCP socket): framing, correlation,
//! events, reverse requests and the end of a connection.
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream, ReadHalf, WriteHalf};
use tokio::sync::mpsc::UnboundedReceiver;
use tokio_util::bytes::BytesMut;
use tokio_util::codec::Decoder;
use vor::codec::{DapCodec, Frame};
use vor::types::requests;
use vor::{Client, Error, Incoming, Message};

/// The adapter's side of the pipe: reads the client's messages, writes raw bytes.
struct Adapter {
    r: ReadHalf<DuplexStream>,
    w: WriteHalf<DuplexStream>,
    buf: BytesMut,
    codec: DapCodec,
}

impl Adapter {
    async fn recv(&mut self) -> Message {
        loop {
            if let Some(f) = self.codec.decode(&mut self.buf).unwrap() {
                let Frame::Message(m) = f else {
                    panic!("bad frame from the client")
                };
                return m;
            }
            let n = self.r.read_buf(&mut self.buf).await.unwrap();
            assert!(n > 0, "the client closed the pipe");
        }
    }

    async fn raw(&mut self, bytes: &[u8]) {
        self.w.write_all(bytes).await.unwrap();
        self.w.flush().await.unwrap();
    }

    async fn send(&mut self, v: Value) {
        let b = serde_json::to_vec(&v).unwrap();
        self.raw(format!("Content-Length: {}\r\n\r\n", b.len()).as_bytes())
            .await;
        self.raw(&b).await;
    }

    async fn answer(&mut self, request_seq: i64, command: &str, body: Value) {
        self.send(
            json!({"seq": 100 + request_seq, "type": "response", "request_seq": request_seq,
                         "success": true, "command": command, "body": body}),
        )
        .await;
    }
}

fn pair() -> (Client, UnboundedReceiver<Incoming>, Adapter) {
    let (a, b) = tokio::io::duplex(1 << 20);
    let (cr, cw) = tokio::io::split(a);
    let (ar, aw) = tokio::io::split(b);
    let (client, incoming) = Client::new(cr, cw);
    (
        client,
        incoming,
        Adapter {
            r: ar,
            w: aw,
            buf: BytesMut::new(),
            codec: DapCodec::default(),
        },
    )
}

fn seq_of(m: &Message) -> i64 {
    match m {
        Message::Request { seq, .. } => *seq,
        other => panic!("not a request: {other:?}"),
    }
}

#[tokio::test]
async fn a_header_and_a_body_split_across_reads() {
    let (client, _inc, mut ad) = pair();
    let p = client.request("threads", Value::Null);
    let seq = seq_of(&ad.recv().await);
    let body = json!({"seq": 9, "type": "response", "request_seq": seq, "success": true,
                      "command": "threads", "body": {"threads": [{"id": 1, "name": "main"}]}})
    .to_string();
    let whole = format!("Content-Length: {}\r\n\r\n{body}", body.len());
    for chunk in whole.as_bytes().chunks(7) {
        ad.raw(chunk).await;
        tokio::task::yield_now().await;
    }
    assert_eq!(p.await.unwrap()["threads"][0]["name"], "main");
}

#[tokio::test]
async fn other_headers_are_skipped_and_the_name_is_any_case() {
    let (client, _inc, mut ad) = pair();
    let p = client.request("threads", Value::Null);
    let seq = seq_of(&ad.recv().await);
    let body = json!({"seq": 1, "type": "response", "request_seq": seq, "success": true, "command": "threads"})
        .to_string();
    ad.raw(format!("X-Other: 1\r\ncontent-length: {}\r\n\r\n{body}", body.len()).as_bytes())
        .await;
    assert_eq!(p.await.unwrap(), Value::Null);
}

#[tokio::test]
async fn a_missing_or_bad_content_length_ends_the_connection() {
    for head in [
        "X-Other: 3\r\n\r\n",
        "Content-Length: twelve\r\n\r\n",
        "no colon here\r\n\r\n",
    ] {
        let (client, mut inc, mut ad) = pair();
        let p = client.request("threads", Value::Null);
        let _ = ad.recv().await;
        ad.raw(head.as_bytes()).await;
        assert!(matches!(p.await, Err(Error::Closed(_))), "{head:?}");
        assert!(inc.recv().await.is_none(), "the stream ends: {head:?}");
        assert!(client.is_closed());
    }
}

#[tokio::test]
async fn a_body_that_is_not_a_message_is_reported_and_the_stream_goes_on() {
    let (client, mut inc, mut ad) = pair();
    ad.raw(b"Content-Length: 4\r\n\r\n\xff\xfe{}").await;
    ad.raw(b"Content-Length: 2\r\n\r\n{}").await;
    assert!(matches!(inc.recv().await, Some(Incoming::Bad(_))));
    assert!(matches!(inc.recv().await, Some(Incoming::Bad(_))));
    let p = client.request("threads", Value::Null);
    let seq = seq_of(&ad.recv().await);
    ad.answer(seq, "threads", json!({"threads": []})).await;
    assert!(p.await.is_ok());
}

#[tokio::test]
async fn answers_out_of_order_reach_their_requests() {
    let (client, _inc, mut ad) = pair();
    let a = client.request("threads", Value::Null);
    let b = client.request("scopes", json!({"frameId": 1}));
    let sa = seq_of(&ad.recv().await);
    let sb = seq_of(&ad.recv().await);
    assert_ne!(sa, sb);
    ad.answer(sb, "scopes", json!({"scopes": [{"name": "Locals"}]}))
        .await;
    ad.answer(sa, "threads", json!({"threads": []})).await;
    assert_eq!(b.await.unwrap()["scopes"][0]["name"], "Locals");
    assert_eq!(a.await.unwrap()["threads"], json!([]));
}

#[tokio::test]
async fn a_failed_answer_carries_its_message() {
    let (client, _inc, mut ad) = pair();
    let p = client.request("evaluate", json!({"expression": "x"}));
    let seq = seq_of(&ad.recv().await);
    ad.send(
        json!({"seq": 5, "type": "response", "request_seq": seq, "success": false,
                   "command": "evaluate", "message": "name 'x' is not defined"}),
    )
    .await;
    match p.await {
        Err(Error::Failed {
            command, message, ..
        }) => {
            assert_eq!(command, "evaluate");
            assert_eq!(message, "name 'x' is not defined");
        }
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
async fn events_between_a_request_and_its_answer_come_first_and_in_order() {
    let (client, mut inc, mut ad) = pair();
    let p = client.request("launch", json!({"program": "x"}));
    let seq = seq_of(&ad.recv().await);
    ad.send(json!({"seq": 1, "type": "event", "event": "initialized"}))
        .await;
    ad.send(json!({"seq": 2, "type": "event", "event": "output", "body": {"output": "hi"}}))
        .await;
    ad.answer(seq, "launch", Value::Null).await;
    p.await.unwrap();
    let names: Vec<String> = [inc.recv().await, inc.recv().await]
        .into_iter()
        .map(|i| match i {
            Some(Incoming::Event { event, .. }) => event,
            other => panic!("{other:?}"),
        })
        .collect();
    assert_eq!(names, ["initialized", "output"]);
}

#[tokio::test]
async fn a_reverse_request_is_answered_through_its_handle() {
    let (_client, mut inc, mut ad) = pair();
    ad.send(
        json!({"seq": 7, "type": "request", "command": "runInTerminal",
                   "arguments": {"kind": "integrated", "cwd": "/w", "args": ["prog"]}}),
    )
    .await;
    let Some(Incoming::Request(r)) = inc.recv().await else {
        panic!()
    };
    assert_eq!(r.command, "runInTerminal");
    assert_eq!(r.arguments["args"][0], "prog");
    r.ok(json!({"processId": 42}));
    match ad.recv().await {
        Message::Response {
            request_seq,
            success,
            command,
            body,
            ..
        } => {
            assert_eq!(
                (request_seq, success, command.as_str()),
                (7, true, "runInTerminal")
            );
            assert_eq!(body["processId"], 42);
        }
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
async fn a_reverse_request_dropped_unanswered_is_refused() {
    let (_client, mut inc, mut ad) = pair();
    ad.send(json!({"seq": "8", "type": "request", "command": "startDebugging", "arguments": {}}))
        .await;
    let Some(Incoming::Request(r)) = inc.recv().await else {
        panic!()
    };
    assert_eq!(r.seq, 8, "a string seq is read as a number");
    drop(r);
    match ad.recv().await {
        Message::Response {
            request_seq,
            success,
            message,
            ..
        } => {
            assert_eq!((request_seq, success), (8, false));
            assert_eq!(message.as_deref(), Some("not handled"));
        }
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
async fn an_adapter_that_dies_mid_request_fails_every_waiter_once() {
    let (client, mut inc, ad) = pair();
    let a = client.request("threads", Value::Null);
    let b = client.request("stackTrace", json!({"threadId": 1}));
    drop(ad);
    let Err(Error::Closed(first)) = a.await else {
        panic!("the first waiter is told the connection ended")
    };
    assert!(matches!(b.await, Err(Error::Closed(_))));
    assert!(inc.recv().await.is_none());
    // a request after the end fails at once, with the same reason (the reader's end or the
    // writer's broken pipe, whichever saw it first)
    match client.request("threads", Value::Null).await {
        Err(Error::Closed(why)) => assert_eq!(why, first),
        other => panic!("{other:?}"),
    }
}

#[tokio::test(start_paused = true)]
async fn a_request_given_up_on_ignores_its_late_answer() {
    let (client, _inc, mut ad) = pair();
    let p = client.request("threads", Value::Null);
    let seq = p.seq();
    let r = tokio::time::timeout(std::time::Duration::from_secs(5), p).await;
    assert!(r.is_err(), "the caller's deadline ran out");
    let _ = ad.recv().await;
    ad.answer(seq, "threads", json!({})).await;
    let q = client.request("threads", Value::Null);
    let s2 = seq_of(&ad.recv().await);
    ad.answer(s2, "threads", json!({"threads": [{"id": 2, "name": "t"}]}))
        .await;
    assert_eq!(q.await.unwrap()["threads"][0]["id"], 2);
}

#[tokio::test]
async fn cancel_names_the_request() {
    let (client, _inc, mut ad) = pair();
    let p = client.request("evaluate", json!({"expression": "slow()"}));
    let _ = ad.recv().await;
    let c = client.cancel(p.seq());
    match ad.recv().await {
        Message::Request {
            command,
            arguments,
            seq,
        } => {
            assert_eq!(command, "cancel");
            assert_eq!(arguments["requestId"], p.seq());
            ad.answer(seq, "cancel", Value::Null).await;
        }
        other => panic!("{other:?}"),
    }
    c.await.unwrap();
}

#[tokio::test]
async fn typed_requests_and_bodies() {
    let (client, _inc, mut ad) = pair();
    let task = tokio::spawn({
        let client = client.clone();
        async move {
            client
                .send::<requests::StackTrace>(&vor::types::StackTraceArguments {
                    thread_id: 3,
                    levels: Some(20),
                    ..Default::default()
                })
                .await
        }
    });
    match ad.recv().await {
        Message::Request {
            command,
            arguments,
            seq,
        } => {
            assert_eq!(command, "stackTrace");
            assert_eq!(arguments, json!({"threadId": 3, "levels": 20}));
            ad.answer(seq, "stackTrace", json!({"stackFrames": [
                {"id": 1, "name": "main", "line": 9, "column": 1, "vendorField": true}], "totalFrames": 1}))
                .await;
        }
        other => panic!("{other:?}"),
    }
    let body = task.await.unwrap().unwrap();
    assert_eq!(body.total_frames, Some(1));
    assert_eq!(body.stack_frames[0].name, "main");
    assert_eq!(
        body.stack_frames[0].extra["vendorField"], true,
        "an adapter's own field is kept"
    );
}

#[tokio::test]
async fn over_tcp() {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    let srv = tokio::spawn(async move {
        let (mut s, _) = l.accept().await.unwrap();
        let mut buf = BytesMut::new();
        let mut codec = DapCodec::default();
        let seq = loop {
            if let Some(Frame::Message(m)) = codec.decode(&mut buf).unwrap() {
                break seq_of(&m);
            }
            s.read_buf(&mut buf).await.unwrap();
        };
        let b = json!({"seq": 1, "type": "response", "request_seq": seq, "success": true, "command": "threads",
                       "body": {"threads": []}})
        .to_string();
        s.write_all(format!("Content-Length: {}\r\n\r\n{b}", b.len()).as_bytes())
            .await
            .unwrap();
        s
    });
    let stream = tokio::net::TcpStream::connect(addr).await.unwrap();
    let (client, _inc) = Client::tcp(stream);
    assert!(client.request("threads", Value::Null).await.is_ok());
    drop(srv.await.unwrap());
}

#[tokio::test(start_paused = true)]
async fn connect_waits_for_a_port_that_opens_late() {
    // a port the adapter will listen on, picked by binding and letting go (as the hub picks one)
    let addr = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap();
    let late = tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(700)).await;
        let l = tokio::net::TcpListener::bind(addr).await.unwrap();
        l.accept().await.unwrap().0
    });
    let (client, _inc) = Client::connect_tcp(addr, std::time::Duration::from_secs(5))
        .await
        .unwrap();
    assert!(!client.is_closed());
    drop(late.await.unwrap());
}

#[tokio::test(start_paused = true)]
async fn connect_gives_up_when_the_port_never_opens() {
    let addr = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap();
    let t0 = tokio::time::Instant::now();
    let err = Client::connect_tcp(addr, std::time::Duration::from_secs(5))
        .await
        .unwrap_err();
    assert!(
        t0.elapsed() >= std::time::Duration::from_secs(5),
        "it kept trying for the whole 5 s"
    );
    assert!(err.to_string().contains(&addr.to_string()), "{err}");
}
