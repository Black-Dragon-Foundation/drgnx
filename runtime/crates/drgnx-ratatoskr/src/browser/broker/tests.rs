//! The broker for real: a hub-side broker over the real browser host (`host::serve` on a thread, the stand-in
//! `tests/data/fake-chromium.sh` as Chromium), and a websocket client of the tests' own on `cdp.sock`.

use super::*;
use crate::browser::host::{self, HostCfg};
use fastwebsockets::{FragmentCollector, Role, WebSocket};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const SID: &str = "S1";

fn stand_in() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/fake-chromium.sh")
}

fn hex(secret: &[u8; 32]) -> String {
    secret.iter().map(|b| format!("{b:02x}")).collect()
}

struct Fx {
    dir: tempfile::TempDir,
    sock: PathBuf,
    secret: [u8; 32],
    handle: BrokerHandle,
    events: mpsc::Receiver<BrokerEvent>,
    gate: Arc<Mutex<Gate>>,
}

impl Fx {
    /// A broker with a running browser host behind it, its browser stopped.
    fn new(idle: Duration) -> Fx {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("cdp.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        let (hub, end) = std::os::unix::net::UnixStream::pair().unwrap();
        let (mut ready, ready_w) = std::io::pipe().unwrap();
        let cfg = HostCfg {
            program: stand_in(),
            dir: dir.path().join("browser"),
            web_port: 3130,
            max_message: 1 << 20,
            headless_shell: false,
        };
        std::thread::spawn(move || host::serve(&cfg, end.into(), ready_w.into()));
        let mut line = String::new();
        ready.read_to_string(&mut line).unwrap();
        assert_eq!(line, "ready\n");
        hub.set_nonblocking(true).unwrap();
        let hub = UnixStream::from_std(hub).unwrap();
        Fx::with(dir, sock, listener, Some(hub), idle)
    }

    fn with(
        dir: tempfile::TempDir,
        sock: PathBuf,
        listener: UnixListener,
        hub: Option<UnixStream>,
        idle: Duration,
    ) -> Fx {
        let mut secret = [0u8; 32];
        for (i, b) in secret.iter_mut().enumerate() {
            *b = (i as u8).wrapping_mul(37).wrapping_add(11);
        }
        let gate = Arc::new(Mutex::new(Gate::Allow));
        let g = gate.clone();
        let gate_fn: GateFn = Arc::new(move || {
            let v = g.lock().unwrap().clone();
            Box::pin(async move { v }) as BoxFuture<'static, Gate>
        });
        let (events_tx, events) = mpsc::channel(16);
        let cfg = BrokerCfg {
            sid: SID.into(),
            secret,
            max_message: 1 << 20,
            idle,
            gate: gate_fn,
            events: events_tx,
            stderr: None,
        };
        let handle = match hub {
            Some(h) => start(cfg, listener, h),
            None => start_after_restart(cfg, listener),
        };
        Fx {
            dir,
            sock,
            secret,
            handle,
            events,
            gate,
        }
    }

    fn path(&self) -> String {
        format!("{PATH_PREFIX}{}", hex(&self.secret))
    }

    fn calls(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.path().join("browser/calls"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    async fn event(&mut self) -> BrokerEvent {
        tokio::time::timeout(Duration::from_secs(5), self.events.recv())
            .await
            .expect("an event within 5 s")
            .expect("the channel is open")
    }

    /// An upgrade that must work, retried while the last agent's close is still on its way (409).
    async fn connect(&self) -> Client {
        let path = self.path();
        let (sock, path) = (self.sock.as_path(), path.as_str());
        skuld::wait_until_async("an upgrade, not a 409", 5, move || async move {
            match request(sock, path, true).await {
                Answer::Upgraded(c) => Some(c),
                Answer::Status(409, _) => None,
                Answer::Status(s, b) => panic!("{s} {b}"),
            }
        })
        .await
    }
}

enum Answer {
    Upgraded(Client),
    Status(u16, String),
}

/// One HTTP request on `sock`, with the websocket upgrade's headers when `upgrade`.
async fn request(sock: &Path, path: &str, upgrade: bool) -> Answer {
    let mut s = UnixStream::connect(sock).await.unwrap();
    let mut head = format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:9222\r\n");
    if upgrade {
        head.push_str(
            "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
             Sec-WebSocket-Version: 13\r\n",
        );
    }
    head.push_str("\r\n");
    s.write_all(head.as_bytes()).await.unwrap();
    // byte by byte, so nothing after the head (the first frames) is read here
    let mut got = Vec::new();
    while !got.ends_with(b"\r\n\r\n") {
        let mut b = [0u8; 1];
        let n = tokio::time::timeout(Duration::from_secs(5), s.read(&mut b))
            .await
            .expect("an answer within 5 s")
            .unwrap();
        assert!(
            n == 1,
            "the connection closed in the head: {:?}",
            String::from_utf8_lossy(&got)
        );
        got.push(b[0]);
    }
    let head = String::from_utf8(got).unwrap();
    let code: u16 = head.split(' ').nth(1).unwrap().parse().unwrap();
    if code == 101 {
        let ws = WebSocket::after_handshake(s, Role::Client);
        return Answer::Upgraded(Client {
            ws: FragmentCollector::new(ws),
        });
    }
    let len: usize = head
        .lines()
        .find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.eq_ignore_ascii_case("content-length")
                .then(|| v.trim().parse().ok())?
        })
        .unwrap_or(0);
    let mut body = vec![0u8; len];
    s.read_exact(&mut body).await.unwrap();
    Answer::Status(code, String::from_utf8(body).unwrap())
}

async fn status_of(sock: &Path, path: &str, upgrade: bool) -> (u16, String) {
    match request(sock, path, upgrade).await {
        Answer::Status(s, b) => (s, b),
        Answer::Upgraded(_) => (101, String::new()),
    }
}

struct Client {
    ws: FragmentCollector<UnixStream>,
}

#[derive(Debug)]
enum Got {
    Msg(Value),
    Closed(u16, String),
}

impl Client {
    async fn send(&mut self, msg: &str) {
        self.ws
            .write_frame(Frame::text(Payload::Owned(msg.as_bytes().to_vec())))
            .await
            .unwrap();
    }

    async fn next(&mut self) -> Got {
        let f = tokio::time::timeout(Duration::from_secs(5), self.ws.read_frame())
            .await
            .expect("a frame within 5 s")
            .expect("a frame");
        match f.opcode {
            OpCode::Close => {
                let code = u16::from_be_bytes([f.payload[0], f.payload[1]]);
                Got::Closed(code, String::from_utf8_lossy(&f.payload[2..]).into_owned())
            }
            _ => Got::Msg(serde_json::from_slice(&f.payload).unwrap()),
        }
    }

    async fn msg(&mut self) -> Value {
        match self.next().await {
            Got::Msg(v) => v,
            other => panic!("{other:?}"),
        }
    }

    /// The reply to `id`, skipping events.
    async fn reply(&mut self, id: u64) -> Value {
        loop {
            let v = self.msg().await;
            if v["id"] == id {
                return v;
            }
        }
    }

    async fn closed(&mut self) -> (u16, String) {
        loop {
            match self.next().await {
                Got::Closed(c, w) => return (c, w),
                Got::Msg(_) => {}
            }
        }
    }

    /// Close from the agent's side and wait for the broker's answer.
    async fn close(mut self) {
        self.ws
            .write_frame(Frame::close(1000, b"bye"))
            .await
            .unwrap();
        let _ = tokio::time::timeout(Duration::from_secs(5), self.ws.read_frame()).await;
    }
}

#[tokio::test]
async fn wrong_secret_is_404() {
    let fx = Fx::new(Duration::from_secs(600));
    let zeros = format!("{PATH_PREFIX}{}", "0".repeat(64));
    assert_eq!(
        status_of(&fx.sock, &zeros, true).await,
        (404, String::new())
    );
    // the right secret but no upgrade, a query, the secret cut short, another path
    assert_eq!(
        status_of(&fx.sock, &fx.path(), false).await,
        (404, String::new())
    );
    let q = format!("{}?x=1", fx.path());
    assert_eq!(status_of(&fx.sock, &q, true).await, (404, String::new()));
    let short = &fx.path()[..fx.path().len() - 2];
    assert_eq!(status_of(&fx.sock, short, true).await, (404, String::new()));
    assert_eq!(
        status_of(&fx.sock, "/json/version", true).await,
        (404, String::new())
    );
    // and the right one upgrades
    assert_eq!(status_of(&fx.sock, &fx.path(), true).await.0, 101);
}

#[tokio::test]
async fn ask_is_403_with_the_card() {
    let fx = Fx::new(Duration::from_secs(600));
    *fx.gate.lock().unwrap() = Gate::Ask(7);
    assert_eq!(
        status_of(&fx.sock, &fx.path(), true).await,
        (403, "waiting for the user's yes: card 7".into())
    );
    assert!(fx.calls().is_empty(), "no browser was started");
}

#[tokio::test]
async fn allow_upgrades_and_relays_both_ways() {
    let fx = Fx::new(Duration::from_secs(600));
    let mut c = fx.connect().await;
    assert!(fx.handle.connected());
    // held until the browser started and the router attached, then sent on the agent's browser session
    c.send(r#"{"id":1,"method":"Browser.getVersion"}"#).await;
    let r = c.reply(1).await;
    assert!(
        r.get("sessionId").is_none(),
        "the agent sees a root connection: {r}"
    );
    assert_eq!(r["result"]["echo"]["sessionId"], "browser-1", "{r}");
    // an event from the browser on the agent's session reaches it, without the session
    c.send(r#"{"id":2,"method":"Fake.attach"}"#).await;
    let mut got = vec![c.msg().await, c.msg().await];
    got.sort_by_key(|v| v["id"].is_null());
    assert_eq!(got[0]["id"], 2);
    assert_eq!(got[1]["method"], "Target.attachedToTarget", "{:?}", got);
    assert_eq!(got[1]["params"]["sessionId"], "child-1");
    assert!(got[1].get("sessionId").is_none(), "{:?}", got);
    // a refused method never reaches the browser
    c.send(r#"{"id":3,"method":"Browser.close"}"#).await;
    assert_eq!(c.reply(3).await["error"]["code"], -32601);
    assert!(!fx.calls().iter().any(|l| l.starts_with("Browser.close")));
}

#[tokio::test]
async fn second_connection_is_409() {
    let fx = Fx::new(Duration::from_secs(600));
    let _c = fx.connect().await;
    assert_eq!(
        status_of(&fx.sock, &fx.path(), true).await,
        (409, BUSY.into())
    );
}

#[tokio::test]
async fn idle_stops_the_browser() {
    let mut fx = Fx::new(Duration::from_millis(300));
    let mut c = fx.connect().await;
    c.send(r#"{"id":1,"method":"Browser.getVersion"}"#).await;
    c.reply(1).await;
    c.close().await;
    assert_eq!(
        fx.event().await,
        BrokerEvent::Stopped { why: "idle".into() }
    );
    // the next connection gets a fresh browser: its first attach again
    let mut c = fx.connect().await;
    c.send(r#"{"id":2,"method":"Browser.getVersion"}"#).await;
    assert_eq!(c.reply(2).await["result"]["echo"]["sessionId"], "browser-1");
}

#[tokio::test]
async fn memory_stop_tells_the_agent() {
    let mut fx = Fx::new(Duration::from_secs(600));
    let mut c = fx.connect().await;
    c.send(r#"{"id":1,"method":"Browser.getVersion"}"#).await;
    c.reply(1).await;
    fx.handle.stop("memory");
    assert_eq!(c.closed().await, (1001, MEMORY_STOP.into()));
    assert_eq!(
        fx.event().await,
        BrokerEvent::Stopped {
            why: "memory".into()
        }
    );
    assert!(!fx.handle.connected());
}

/// Review Focus 3: Chromium crashes mid-session.
#[tokio::test]
async fn a_crashed_browser_starts_fresh_on_the_next_connection() {
    let fx = Fx::new(Duration::from_secs(600));
    let mut c = fx.connect().await;
    c.send(r#"{"id":1,"method":"Browser.getVersion"}"#).await;
    c.reply(1).await;
    c.send(r#"{"id":2,"method":"Fake.crash"}"#).await;
    assert_eq!(
        c.closed().await,
        (1011, "the browser exited (signal 9)".into())
    );
    let mut c = fx.connect().await;
    c.send(r#"{"id":3,"method":"Browser.getVersion"}"#).await;
    let r = c.reply(3).await;
    assert_eq!(
        r["result"]["echo"]["sessionId"], "browser-1",
        "a fresh browser: {r}"
    );
}

#[tokio::test]
async fn reconnect_during_detach_resumes_paused_targets() {
    let fx = Fx::new(Duration::from_secs(600));
    let mut a = fx.connect().await;
    // a page attached under the agent's session, paused for the debugger, never resumed by the agent. The reply and
    // the attach event are two messages: the agent leaves only once it has the event, so the broker saw the attach
    // before the close (pattern C, a handshake on the event itself)
    a.send(r#"{"id":1,"method":"Fake.attach"}"#).await;
    let mut got = vec![a.msg().await, a.msg().await];
    got.sort_by_key(|v| v["id"].is_null());
    assert_eq!(got[0]["id"], 1, "{got:?}");
    assert_eq!(got[1]["method"], "Target.attachedToTarget", "{got:?}");
    assert_eq!(got[1]["params"]["sessionId"], "child-1", "{got:?}");
    a.close().await;
    // the next agent at once: its message waits for the router's new attach
    let mut b = fx.connect().await;
    b.send(r#"{"id":1,"method":"Browser.getVersion"}"#).await;
    let r = b.reply(1).await;
    assert_eq!(r["result"]["echo"]["sessionId"], "browser-2", "{r}");
    let calls = fx.calls();
    let at = |what: &str| {
        calls
            .iter()
            .position(|l| l == what)
            .unwrap_or_else(|| panic!("no {what:?} in {calls:?}"))
    };
    let resumed = at("Runtime.runIfWaitingForDebugger child-1");
    let detached = at("Target.detachFromTarget browser-1");
    let get = at("Browser.getVersion browser-2");
    assert!(resumed < detached && detached < get, "{calls:?}");
    let reattached = calls
        .iter()
        .rposition(|l| l == "Target.attachToBrowserTarget -")
        .unwrap();
    assert!(detached < reattached && reattached < get, "{calls:?}");
}

#[tokio::test]
async fn narrowing_to_never_refuses_the_next_connection() {
    let fx = Fx::new(Duration::from_secs(600));
    let mut c = fx.connect().await;
    c.send(r#"{"id":1,"method":"Browser.getVersion"}"#).await;
    c.reply(1).await;
    c.close().await;
    let why = "the browser row is Never for this session";
    *fx.gate.lock().unwrap() = Gate::Never(why.into());
    let path = fx.path();
    let (sock, path) = (fx.sock.as_path(), path.as_str());
    let last = skuld::wait_until_async("an answer, not a 409", 5, move || async move {
        let s = status_of(sock, path, true).await;
        (s.0 != 409).then_some(s)
    })
    .await;
    assert_eq!(last, (403, why.into()));
}

/// Review Focus 1, the broker's side: after the hub's restart the host is gone, and the endpoint says so.
#[tokio::test]
async fn after_a_restart_the_endpoint_is_503() {
    let dir = tempfile::tempdir().unwrap();
    let sock = dir.path().join("cdp.sock");
    let listener = UnixListener::bind(&sock).unwrap();
    let fx = Fx::with(dir, sock, listener, None, Duration::from_secs(600));
    assert_eq!(
        status_of(&fx.sock, &fx.path(), true).await,
        (503, ENDED_BY_RESTART.into())
    );
    // a wrong secret learns nothing more
    let zeros = format!("{PATH_PREFIX}{}", "0".repeat(64));
    assert_eq!(status_of(&fx.sock, &zeros, true).await.0, 404);
}

#[tokio::test]
async fn the_secret_is_never_logged() {
    // this thread's log lines; the test's runtime is this one thread, so every task of the broker logs here
    let logs = crate::dispatch::tests::capture_log();
    let fx = Fx::new(Duration::from_secs(600));
    let zeros = format!("{PATH_PREFIX}{}", "0".repeat(64));
    assert_eq!(status_of(&fx.sock, &zeros, true).await.0, 404);
    let mut c = fx.connect().await;
    c.send(r#"{"id":1,"method":"Browser.getVersion"}"#).await;
    c.reply(1).await;
    fx.handle.stop("memory");
    c.closed().await;
    let text = String::from_utf8(logs.lock().unwrap().clone()).unwrap();
    assert!(text.contains("cdp://S1"), "{text}");
    assert!(text.contains("stopping the browser (memory)"), "{text}");
    assert!(
        !text.contains(&hex(&fx.secret)),
        "the secret is in the log:\n{text}"
    );
}
