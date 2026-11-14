//! A scripted peer plays the kernel: it binds the four sockets at the connection's ipc paths and sends what a kernel would.

use bytes::Bytes;
use serde_json::{Value, json};
use tokio::sync::Mutex;
use zeromq::{PubSocket, RouterSocket, Socket, SocketRecv, SocketSend, ZmqMessage};

use super::*;
use crate::notebook::spec::{Connection, private_folder};
use crate::notebook::wire::Header;

struct Peer {
    shell: RouterSocket,
    iopub: PubSocket,
    stdin: RouterSocket,
    control: RouterSocket,
    conn: Connection,
    _dir: tempfile::TempDir,
}

async fn peer() -> Peer {
    let dir = tempfile::Builder::new()
        .prefix("nb")
        .tempdir_in("/tmp")
        .unwrap();
    let folder = private_folder(&dir.path().join("s")).unwrap();
    let conn = Connection::create(&folder, "t", "python3").unwrap();
    let ep = |n| endpoint(&conn.prefix, n);
    let (mut shell, mut iopub, mut stdin, mut control) = (
        RouterSocket::new(),
        PubSocket::new(),
        RouterSocket::new(),
        RouterSocket::new(),
    );
    shell.bind(&ep(1)).await.unwrap();
    iopub.bind(&ep(2)).await.unwrap();
    stdin.bind(&ep(3)).await.unwrap();
    control.bind(&ep(4)).await.unwrap();
    Peer {
        shell,
        iopub,
        stdin,
        control,
        conn,
        _dir: dir,
    }
}

fn zmq(key: &Key, m: &Message) -> ZmqMessage {
    let frames: Vec<Bytes> = wire::encode(key, m).into_iter().map(Bytes::from).collect();
    ZmqMessage::try_from(frames).unwrap()
}

fn reply(to: &Header, msg_type: &str, content: serde_json::Value) -> Message {
    let mut m = Message::request("kernel", msg_type, content);
    m.parent = serde_json::to_value(to).unwrap();
    m
}

async fn recv_decoded(sock: &mut RouterSocket, key: &Key) -> (Vec<u8>, Message) {
    let f = frames(sock.recv().await.unwrap());
    let identity = f[0].clone();
    (identity, wire::decode(key, &f).unwrap())
}

#[tokio::test(flavor = "multi_thread")]
async fn a_shell_request_reaches_the_kernel_signed_and_its_reply_comes_back() {
    let mut p = peer().await;
    let mut s = Session::connect(&p.conn, "ident-1", Limits::default())
        .await
        .unwrap();
    let req = Message::request("sess", "kernel_info_request", json!({}));
    s.send(Channel::Shell, &req).unwrap();
    let (id, got) = recv_decoded(&mut p.shell, &p.conn.key).await;
    assert_eq!(id, b"ident-1");
    assert_eq!(got.header.msg_type, "kernel_info_request");
    assert_eq!(got.header.msg_id, req.header.msg_id);
    let mut rep = reply(&got.header, "kernel_info_reply", json!({"status": "ok"}));
    rep.idents = vec![id];
    p.shell.send(zmq(&p.conn.key, &rep)).await.unwrap();
    let Some(Event::Message {
        channel,
        message,
        bytes,
    }) = s.next().await
    else {
        panic!("no message")
    };
    assert_eq!(channel, Channel::Shell);
    assert_eq!(message.header.msg_type, "kernel_info_reply");
    assert_eq!(message.parent["msg_id"], req.header.msg_id);
    assert!(bytes > 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn stdin_and_shell_share_one_routing_identity_and_control_is_its_own() {
    let mut p = peer().await;
    let s = Session::connect(&p.conn, "ident-2", Limits::default())
        .await
        .unwrap();
    s.send(
        Channel::Shell,
        &Message::request("sess", "execute_request", json!({})),
    )
    .unwrap();
    s.send(
        Channel::Stdin,
        &Message::request("sess", "input_reply", json!({"value": "x"})),
    )
    .unwrap();
    s.send(
        Channel::Control,
        &Message::request("sess", "interrupt_request", json!({})),
    )
    .unwrap();
    let (shell_id, _) = recv_decoded(&mut p.shell, &p.conn.key).await;
    let (stdin_id, m) = recv_decoded(&mut p.stdin, &p.conn.key).await;
    assert_eq!(shell_id, b"ident-2");
    assert_eq!(
        stdin_id, shell_id,
        "the kernel finds the stdin peer by the shell's identity"
    );
    assert_eq!(m.content["value"], "x");
    let (control_id, m) = recv_decoded(&mut p.control, &p.conn.key).await;
    assert_ne!(control_id, shell_id);
    assert_eq!(m.header.msg_type, "interrupt_request");
    assert!(
        s.send(Channel::Iopub, &Message::request("s", "x", json!({})))
            .is_err()
    );
}

/// Publish until the subscription has taken hold (a PUB drops what it sends before the SUB's subscription arrives): the
/// peer sends each round, the test takes what came.
async fn until_iopub(
    p: &Mutex<Peer>,
    s: &Mutex<Session>,
    msgs: impl Fn() -> Vec<ZmqMessage>,
) -> Event {
    skuld::wait_until_async("an iopub message", 30, || async {
        let mut p = p.lock().await;
        for m in msgs() {
            p.iopub.send(m).await.unwrap();
        }
        s.lock().await.try_next()
    })
    .await
}

#[tokio::test(flavor = "multi_thread")]
async fn iopub_messages_arrive_and_one_that_does_not_verify_is_dropped_and_counted() {
    let p = peer().await;
    let s = Session::connect(&p.conn, "ident-3", Limits::default())
        .await
        .unwrap();
    let (good_key, other) = (p.conn.key.clone(), Key::generate().unwrap());
    let (p, s) = (Mutex::new(p), Mutex::new(s));
    let msgs = || {
        let st = Message::request("kernel", "status", json!({"execution_state": "idle"}));
        vec![zmq(&other, &st), zmq(&good_key, &st)]
    };
    let Event::Message {
        channel, message, ..
    } = until_iopub(&p, &s, msgs).await
    else {
        panic!("not a message")
    };
    assert_eq!(channel, Channel::Iopub);
    assert_eq!(message.content["execution_state"], "idle");
    assert!(
        s.lock().await.bad() >= 1,
        "the badly signed one was counted"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_flood_unread_stops_the_reader_and_is_reported() {
    let p = peer().await;
    let limits = Limits {
        flood_bytes: 200_000,
        ..Limits::default()
    };
    let s = Session::connect(&p.conn, "ident-4", limits).await.unwrap();
    let key = p.conn.key.clone();
    let (p, s) = (Mutex::new(p), Mutex::new(s));
    let big = json!({"name": "stdout", "text": "x".repeat(60_000)});
    // nothing is taken by the test until the flood has been seen: the queue only grows
    // a reader that has said so has returned: it is the only task that ends by itself
    skuld::wait_until_async("the flood", 30, || async {
        let mut pp = p.lock().await;
        for _ in 0..4 {
            pp.iopub
                .send(zmq(
                    &key,
                    &Message::request("kernel", "stream", big.clone()),
                ))
                .await
                .unwrap();
        }
        drop(pp);
        s.lock()
            .await
            .tasks
            .iter()
            .any(|t| t.is_finished())
            .then_some(())
    })
    .await;
    let mut ss = s.lock().await;
    let mut flooded = false;
    while let Some(e) = ss.try_next() {
        flooded |= matches!(e, Event::Flood);
    }
    assert!(flooded, "the reader said so");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_flood_of_badly_signed_messages_is_a_flood_too() {
    let p = peer().await;
    let limits = Limits {
        bad_count: 20,
        ..Limits::default()
    };
    let s = Session::connect(&p.conn, "ident-5", limits).await.unwrap();
    let other = Key::generate().unwrap();
    let (p, s) = (Mutex::new(p), Mutex::new(s));
    skuld::wait_until_async("the flood of bad messages", 30, || async {
        let mut pp = p.lock().await;
        for _ in 0..30 {
            pp.iopub
                .send(zmq(
                    &other,
                    &Message::request("kernel", "status", json!({})),
                ))
                .await
                .unwrap();
        }
        drop(pp);
        s.lock()
            .await
            .tasks
            .iter()
            .any(|t| t.is_finished())
            .then_some(())
    })
    .await;
    let mut ss = s.lock().await;
    let mut flooded = false;
    while let Some(e) = ss.try_next() {
        flooded |= matches!(e, Event::Flood);
    }
    assert!(flooded);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_message_small_on_the_wire_but_large_decoded_is_counted_by_what_it_holds() {
    let p = peer().await;
    // 450 KB on the wire each: 37 of them would pass 16 MiB by wire bytes alone, four by what they hold
    let limits = Limits {
        flood_bytes: 16 << 20,
        ..Limits::default()
    };
    let s = Session::connect(&p.conn, "ident-6", limits).await.unwrap();
    let sent = std::sync::atomic::AtomicUsize::new(0);
    let key = p.conn.key.clone();
    let (p, s) = (Mutex::new(p), Mutex::new(s));
    // `[],` is three bytes on the wire and a value of its own in memory
    let content = json!({"a": vec![json!([]); 150_000]});
    skuld::wait_until_async("the weighted flood", 30, || async {
        sent.fetch_add(1, Ordering::SeqCst);
        let mut pp = p.lock().await;
        pp.iopub
            .send(zmq(
                &key,
                &Message::request("kernel", "stream", content.clone()),
            ))
            .await
            .unwrap();
        drop(pp);
        s.lock()
            .await
            .tasks
            .iter()
            .any(|t| t.is_finished())
            .then_some(())
    })
    .await;
    assert!(
        sent.load(Ordering::SeqCst) <= 30,
        "flooded by what it holds, not by wire bytes: {} sent",
        sent.load(Ordering::SeqCst)
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn one_large_message_is_shown_as_a_note_and_the_kernel_carries_on() {
    let p = peer().await;
    let limits = Limits {
        flood_bytes: 1 << 20,
        message_bytes: 512 << 10,
        ..Limits::default()
    };
    let s = Session::connect(&p.conn, "ident-7", limits).await.unwrap();
    let key = p.conn.key.clone();
    let (p, s) = (Mutex::new(p), Mutex::new(s));
    let big = json!({"data": {"text/plain": "x".repeat(800_000)}, "metadata": {}, "transient": {"display_id": "d"}});
    let small = json!({"data": {"text/plain": "after"}, "metadata": {}});
    let mut got: Vec<Value> = Vec::new();
    let got_ref = Mutex::new(&mut got);
    skuld::wait_until_async("the note and the message after it", 30, || async {
        let mut pp = p.lock().await;
        pp.iopub
            .send(zmq(
                &key,
                &Message::request("kernel", "display_data", big.clone()),
            ))
            .await
            .unwrap();
        pp.iopub
            .send(zmq(
                &key,
                &Message::request("kernel", "display_data", small.clone()),
            ))
            .await
            .unwrap();
        drop(pp);
        let mut ss = s.lock().await;
        let mut g = got_ref.lock().await;
        while let Some(e) = ss.try_next() {
            match e {
                Event::Message { message, .. } => g.push(message.content),
                Event::Flood => panic!("a large message is not a flood"),
                _ => {}
            }
        }
        g.iter()
            .any(|c| c["data"]["text/plain"] == "after")
            .then_some(())
    })
    .await;
    let note = got
        .iter()
        .find(|c| {
            c["data"]["text/plain"]
                .as_str()
                .is_some_and(|t| t.contains("not shown"))
        })
        .unwrap();
    assert_eq!(
        note["transient"]["display_id"], "d",
        "the note belongs where the output would have"
    );
    assert!(
        !s.lock().await.tasks.iter().any(|t| t.is_finished()),
        "no reader stopped"
    );
}
