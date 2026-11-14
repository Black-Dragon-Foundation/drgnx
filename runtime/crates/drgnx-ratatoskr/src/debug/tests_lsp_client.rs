//! The LSP client of the `lsp-command` start kind: framing with its caps, answers and the messages around them, and every
//! way the server can fail (it goes quiet, it exits, it sends too much or nonsense). Over in-memory pipes; the clock is paused.
use super::lsp_client::{Client, Failure, MAX_FRAME, read_frame};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::io::{AsyncWriteExt, BufReader, DuplexStream, duplex};

fn frame(v: &Value) -> Vec<u8> {
    let body = serde_json::to_vec(v).unwrap();
    let mut out = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
    out.extend(body);
    out
}

/// A client whose server end is `(read what the client sent, write what the server says)`.
fn pair() -> (std::sync::Arc<Client>, DuplexStream, DuplexStream) {
    let (client_out, server_in) = duplex(64 * 1024);
    let (server_out, client_in) = duplex(64 * 1024);
    (Client::new(client_in, client_out), server_in, server_out)
}

/// The next message the client sent.
async fn sent(server_in: &mut DuplexStream) -> Value {
    let mut r = BufReader::new(server_in);
    read_frame(&mut r, MAX_FRAME)
        .await
        .unwrap()
        .expect("a message")
}

#[tokio::test]
async fn frames_read_whole_split_and_with_other_headers_and_a_clean_end_is_none() {
    let msg = json!({"jsonrpc": "2.0", "id": 1, "result": {"a": [1, 2, 3]}});
    let mut bytes = b"Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n".to_vec();
    bytes.extend(frame(&msg));
    // a pipe of 7 bytes: the frame arrives in pieces
    let (mut w, r) = duplex(7);
    let feed = crate::clock::spawn("test:lsp-client", async move {
        w.write_all(&bytes).await.unwrap();
    });
    let mut r = BufReader::new(r);
    assert_eq!(read_frame(&mut r, MAX_FRAME).await.unwrap(), Some(msg));
    feed.await.unwrap();
    assert_eq!(read_frame(&mut r, MAX_FRAME).await.unwrap(), None);
}

#[tokio::test]
async fn an_oversized_a_malformed_or_a_cut_frame_is_a_named_failure_and_no_body_is_read_for_the_first()
 {
    let read = |bytes: Vec<u8>, max: usize| async move {
        let mut r = BufReader::new(std::io::Cursor::new(bytes));
        read_frame(&mut r, max).await
    };
    // the length alone is over the cap: refused before the body (there is none)
    let huge = format!("Content-Length: {}\r\n\r\n", MAX_FRAME + 1).into_bytes();
    assert_eq!(
        read(huge, MAX_FRAME).await,
        Err(Failure::TooLarge(MAX_FRAME + 1))
    );
    // a header block without end, over its cap
    let mut endless = b"X-Fill: ".to_vec();
    endless.extend(std::iter::repeat_n(b'a', 20_000));
    assert!(matches!(
        read(endless, MAX_FRAME).await,
        Err(Failure::TooLarge(_))
    ));
    // no Content-Length, a length that is no number, a body that is no JSON, input that ends inside the body
    assert!(matches!(
        read(b"X: 1\r\n\r\n{}".to_vec(), MAX_FRAME).await,
        Err(Failure::BadFrame(_))
    ));
    assert!(matches!(
        read(b"Content-Length: x\r\n\r\n".to_vec(), MAX_FRAME).await,
        Err(Failure::BadFrame(_))
    ));
    assert!(matches!(
        read(b"Content-Length: 4\r\n\r\nnope".to_vec(), MAX_FRAME).await,
        Err(Failure::BadFrame(_))
    ));
    assert!(matches!(
        read(b"Content-Length: 40\r\n\r\n{}".to_vec(), MAX_FRAME).await,
        Err(Failure::Closed(_))
    ));
    assert!(matches!(
        read(b"Content-Len".to_vec(), MAX_FRAME).await,
        Err(Failure::Closed(_))
    ));
}

#[tokio::test(start_paused = true)]
async fn a_request_is_answered_with_notifications_and_server_requests_around_it() {
    let (client, mut server_in, mut server_out) = pair();
    let ask = crate::clock::spawn("test:lsp-client", {
        let c = client.clone();
        async move {
            c.request(
                "workspace/executeCommand",
                json!({"command": "x"}),
                Duration::from_secs(5),
            )
            .await
        }
    });
    let req = sent(&mut server_in).await;
    assert_eq!(req["method"], "workspace/executeCommand");
    let id = req["id"].clone();
    // a notification, a request of the server's (answered null by the client), then the answer
    server_out.write_all(&frame(&json!({"jsonrpc": "2.0", "method": "window/logMessage", "params": {"message": "importing"}}))).await.unwrap();
    server_out
        .write_all(&frame(
            &json!({"jsonrpc": "2.0", "id": 77, "method": "workspace/configuration", "params": {}}),
        ))
        .await
        .unwrap();
    let reply = sent(&mut server_in).await;
    assert_eq!((&reply["id"], &reply["result"]), (&json!(77), &Value::Null));
    server_out
        .write_all(&frame(
            &json!({"jsonrpc": "2.0", "id": id, "result": 54321}),
        ))
        .await
        .unwrap();
    assert_eq!(ask.await.unwrap().unwrap(), json!(54321));
    assert_eq!(client.log_tail(), ["importing"]);
}

#[tokio::test(start_paused = true)]
async fn an_error_answer_a_silent_server_and_a_server_that_exits_each_end_the_request_with_a_name()
{
    // the server refuses
    let (client, mut server_in, mut server_out) = pair();
    let c = client.clone();
    let ask = crate::clock::spawn("test:lsp-client", async move {
        c.request("m", json!({}), Duration::from_secs(5)).await
    });
    let id = sent(&mut server_in).await["id"].clone();
    server_out
        .write_all(&frame(&json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "no such command"}})))
        .await
        .unwrap();
    assert_eq!(
        ask.await.unwrap(),
        Err(Failure::Server {
            code: -32601,
            message: "no such command".into()
        })
    );
    // the server never answers: the deadline, with the method's name
    let r = client
        .request(
            "vscode.java.startDebugSession",
            json!({}),
            Duration::from_secs(30),
        )
        .await;
    assert_eq!(
        r,
        Err(Failure::Deadline {
            what: "vscode.java.startDebugSession".into(),
            secs: 30
        })
    );
    // the server exits while a request waits: every waiting request fails at once, later ones at once too
    let c = client.clone();
    let waiting = crate::clock::spawn("test:lsp-client", async move {
        c.request("initialize", json!({}), Duration::from_secs(60))
            .await
    });
    let _ = sent(&mut server_in).await; // the abandoned request above, then this one
    drop(server_out);
    let got = waiting.await.unwrap();
    assert!(matches!(got, Err(Failure::Closed(_))), "{got:?}");
    assert!(matches!(
        client
            .request("again", json!({}), Duration::from_secs(1))
            .await,
        Err(Failure::Closed(_))
    ));
}

#[tokio::test(start_paused = true)]
async fn an_oversized_frame_in_the_middle_fails_the_waiting_request_without_reading_it() {
    let (client, mut server_in, mut server_out) = pair();
    let c = client.clone();
    let ask = crate::clock::spawn("test:lsp-client", async move {
        c.request("m", json!({}), Duration::from_secs(60)).await
    });
    let _ = sent(&mut server_in).await;
    server_out
        .write_all(format!("Content-Length: {}\r\n\r\n", MAX_FRAME + 5).as_bytes())
        .await
        .unwrap();
    assert_eq!(ask.await.unwrap(), Err(Failure::TooLarge(MAX_FRAME + 5)));
}

#[tokio::test(start_paused = true)]
async fn ready_comes_from_language_status_and_fails_when_the_server_ends_or_never_says_it() {
    let (client, _server_in, mut server_out) = pair();
    let c = client.clone();
    let waiting = crate::clock::spawn("test:lsp-client", async move {
        c.wait_ready(Duration::from_secs(120)).await
    });
    server_out
        .write_all(&frame(&json!({"jsonrpc": "2.0", "method": "language/status", "params": {"type": "Starting", "message": "x"}})))
        .await
        .unwrap();
    server_out
        .write_all(&frame(&json!({"jsonrpc": "2.0", "method": "language/status", "params": {"type": "ServiceReady", "message": "ServiceReady"}})))
        .await
        .unwrap();
    waiting.await.unwrap().unwrap();
    // never ready: the deadline names the start
    let (client, _server_in, _keep) = pair();
    assert_eq!(
        client.wait_ready(Duration::from_secs(120)).await,
        Err(Failure::Deadline {
            what: "the start (ServiceReady)".into(),
            secs: 120
        })
    );
    // the server ends before it is ready
    let (client, _server_in, server_out) = pair();
    let c = client.clone();
    let waiting = crate::clock::spawn("test:lsp-client", async move {
        c.wait_ready(Duration::from_secs(120)).await
    });
    drop(server_out);
    assert!(matches!(waiting.await.unwrap(), Err(Failure::Closed(_))));
}
