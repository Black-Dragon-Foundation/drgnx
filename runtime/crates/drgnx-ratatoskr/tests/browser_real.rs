//! The agent browser against real browsers: Fedora's Chromium, as its headless shell and as the full browser, in the
//! browser test image (`test/container/browser/Containerfile`). A hub-side broker (`browser::broker`) runs over
//! `ratatoskr browser-host --unconfined` (the host without its layer: the sandbox is the real-start rows' part), and
//! the agent is Playwright MCP, run by `ratatoskr-mock cdp-drive` with the capability URL in its environment, as an
//! agent's own browser tool would be. A raw CDP client of the test's own then checks what Playwright does not show:
//! the refusals, a download, and that the agent's close leaves no paused target.
//!
//! Gated on `DRGNX_TEST_REAL_BROWSER=1`; with it set, a missing Chromium, Node or Playwright MCP fails the test (it is
//! never skipped where it was asked for). `DRGNX_TEST_RECORD_DIR=DIR` writes the browser side of each run to
//! `DIR/real-KIND.jsonl` (heimdall's `tests/data`: the real recordings its tests read).
//!
//! Race-proof pattern C (handshake): every wait is for an answer (the host's ready line, a CDP reply or event, a
//! broker event, a process's end), each under a deadline that only fails the test.
#![cfg(all(target_os = "linux", feature = "test-hooks"))]

use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use drgnx_ratatoskr::browser::Secret;
use drgnx_ratatoskr::browser::broker::{self, BrokerCfg, GateFn};
use drgnx_ratatoskr::matrix_gate::Gate;
use mimir::BoxFuture;
use fastwebsockets::{FragmentCollector, Frame, OpCode, Payload, Role, WebSocket};
use heimdall::BrokerEvent;
use heimdall::codec::{FrameDecoder, KIND_CDP};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, UnixListener, UnixStream};
use tokio::sync::mpsc;
use tokio::time::timeout;

const RATATOSKR: &str = env!("CARGO_BIN_EXE_ratatoskr");
/// Playwright MCP in the image, as `ratatoskr-mock cdp-drive` runs it.
const PW_MCP: &str = "/opt/pw-mcp/node_modules/@playwright/mcp";
/// The browser's own dir: heimdall's `DOWNLOAD_DIR` is under it, as in a sandbox.
const OWN_DIR: &str = "/tmp/drgnx-browser";
const MAX_MESSAGE: usize = 64 << 20;

struct Kind {
    name: &'static str,
    program: &'static str,
    flag: &'static str,
}

const HEADLESS_SHELL: Kind = Kind {
    name: "headless-shell",
    program: "/usr/lib64/chromium-browser/headless_shell",
    flag: "--headless-shell",
};
const FULL: Kind = Kind {
    name: "full",
    program: "/usr/lib64/chromium-browser/chromium-browser",
    flag: "--full",
};

/// One browser at a time: both kinds use the one own dir.
static SERIAL: Mutex<()> = Mutex::new(());

fn mock() -> PathBuf {
    Path::new(RATATOSKR).with_file_name("ratatoskr-mock")
}

/// Asked for (`DRGNX_TEST_REAL_BROWSER=1`), and everything it needs is here; asked for but missing is a failure.
fn wanted(kind: &Kind) -> bool {
    if std::env::var("DRGNX_TEST_REAL_BROWSER").as_deref() != Ok("1") {
        eprintln!(
            "browser_real {}: not run (DRGNX_TEST_REAL_BROWSER is not 1)",
            kind.name
        );
        return false;
    }
    let cli = format!("{PW_MCP}/cli.js");
    let mock = mock();
    for need in [
        Path::new(kind.program),
        Path::new("/usr/bin/node"),
        Path::new(&cli),
        mock.as_path(),
    ] {
        assert!(
            need.exists(),
            "DRGNX_TEST_REAL_BROWSER=1, but {} is missing: run this test in the browser image \
             (test/container/browser/Containerfile), with ratatoskr-mock built beside ratatoskr",
            need.display()
        );
    }
    true
}

/// A copy of `fd` at 100 or above, close-on-exec: never at 3 or 4, where the host's are put.
fn high(fd: &impl AsRawFd) -> OwnedFd {
    // SAFETY: F_DUPFD_CLOEXEC makes a new descriptor, which only this owner holds.
    let n = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 100) };
    assert!(n >= 0, "{}", std::io::Error::last_os_error());
    // SAFETY: just made.
    unsafe { OwnedFd::from_raw_fd(n) }
}

/// What went between the broker and the browser host, CDP messages only, in order.
type Recording = Arc<Mutex<Vec<(&'static str, Vec<u8>)>>>;

/// Copy `from` to `to` unchanged, and record each CDP frame's message as `dir`; at EOF, end `to`'s writing side.
fn relay(
    mut from: std::os::unix::net::UnixStream,
    mut to: std::os::unix::net::UnixStream,
    dir: &'static str,
    rec: Recording,
) {
    std::thread::spawn(move || {
        let mut dec = FrameDecoder::new(MAX_MESSAGE + 64);
        let mut buf = vec![0u8; 64 * 1024];
        while let Ok(n) = from.read(&mut buf) {
            if n == 0 || to.write_all(&buf[..n]).is_err() {
                break;
            }
            for f in dec.push(&buf[..n]).unwrap_or_default() {
                if f.kind == KIND_CDP {
                    rec.lock().unwrap().push((dir, f.payload));
                }
            }
        }
        let _ = to.shutdown(std::net::Shutdown::Write);
    });
}

/// The browser host for `kind`, through the recording relay: the host process, the broker's end of the stream.
fn start_host(kind: &Kind, rec: &Recording) -> (std::process::Child, std::os::unix::net::UnixStream) {
    let (broker_end, relay_a) = std::os::unix::net::UnixStream::pair().unwrap();
    let (relay_b, host_end) = std::os::unix::net::UnixStream::pair().unwrap();
    relay(relay_a.try_clone().unwrap(), relay_b.try_clone().unwrap(), "to_browser", rec.clone());
    relay(relay_b, relay_a, "browser", rec.clone());
    let (mut ready_r, ready_w) = std::io::pipe().unwrap();
    let (hub_fd, ready_fd) = (high(&host_end), high(&ready_w));
    drop((host_end, ready_w));
    let (h, r) = (hub_fd.as_raw_fd(), ready_fd.as_raw_fd());
    let mut cmd = Command::new(RATATOSKR);
    cmd.args(["browser-host", "--hub-fd", "3", "--ready-fd", "4", "--program", kind.program])
        .args(["--dir", OWN_DIR, "--web-port", "3130", kind.flag, "--unconfined"])
        .stdin(Stdio::null());
    // SAFETY: only dup2, which is async-signal-safe, between fork and exec.
    unsafe {
        cmd.pre_exec(move || {
            if libc::dup2(h, 3) < 0 || libc::dup2(r, 4) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = cmd.spawn().expect("ratatoskr browser-host");
    drop((hub_fd, ready_fd));
    let mut line = String::new();
    ready_r.read_to_string(&mut line).unwrap();
    assert_eq!(line, "ready\n", "the browser host's ready line");
    (child, broker_end)
}

/// A TCP port on 127.0.0.1 in front of `sock` (the sandbox's CDP relay on 9222 does this for an agent).
async fn tcp_front(sock: PathBuf) -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut tcp, _)) = l.accept().await {
            let sock = sock.clone();
            tokio::spawn(async move {
                if let Ok(mut unix) = UnixStream::connect(&sock).await {
                    let _ = tokio::io::copy_bidirectional(&mut tcp, &mut unix).await;
                }
            });
        }
    });
    port
}

/// `ratatoskr-mock http-serve 0 TEXT`: the process and its port.
fn http_serve(text: &str) -> (std::process::Child, u16) {
    let mut c = Command::new(mock())
        .args(["http-serve", "0", text])
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut out = std::io::BufReader::new(c.stdout.take().unwrap());
    let mut line = String::new();
    std::io::BufRead::read_line(&mut out, &mut line).unwrap();
    let port = line
        .trim()
        .strip_prefix("MOCK-HTTP-PORT ")
        .and_then(|p| p.parse().ok())
        .unwrap_or_else(|| panic!("http-serve said {line:?}"));
    (c, port)
}

/// A raw CDP client on `cdp.sock`: the test's own, not Playwright.
struct Client {
    ws: FragmentCollector<UnixStream>,
    backlog: Vec<Value>,
    next: u64,
}

/// Upgrade on `sock`; `Err(status)` when the broker answers otherwise.
async fn upgrade(sock: &Path, path: &str) -> Result<Client, u16> {
    let mut s = UnixStream::connect(sock).await.unwrap();
    let head = format!(
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:9222\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
         Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    );
    s.write_all(head.as_bytes()).await.unwrap();
    // byte by byte, so no frame after the head is read here
    let mut got = Vec::new();
    while !got.ends_with(b"\r\n\r\n") {
        let mut b = [0u8; 1];
        assert_eq!(s.read(&mut b).await.unwrap(), 1, "the head ended early");
        got.push(b[0]);
    }
    let head = String::from_utf8(got).unwrap();
    let code: u16 = head.split(' ').nth(1).unwrap().parse().unwrap();
    if code != 101 {
        return Err(code);
    }
    Ok(Client {
        ws: FragmentCollector::new(WebSocket::after_handshake(s, Role::Client)),
        backlog: vec![],
        next: 0,
    })
}

/// Connect once the last agent's websocket is gone (409 until the broker has seen it go).
async fn connect(sock: &Path, path: &str) -> Client {
    timeout(Duration::from_secs(10), async {
        loop {
            match upgrade(sock, path).await {
                Ok(c) => return c,
                Err(409) => tokio::task::yield_now().await,
                Err(s) => panic!("the upgrade got {s}"),
            }
        }
    })
    .await
    .expect("the agent's slot is free within 10 s")
}

impl Client {
    async fn read(&mut self) -> Value {
        let f = timeout(Duration::from_secs(30), self.ws.read_frame())
            .await
            .expect("a CDP message within 30 s")
            .expect("a frame");
        assert!(
            !matches!(f.opcode, OpCode::Close),
            "the broker closed the websocket"
        );
        serde_json::from_slice(&f.payload).unwrap()
    }

    /// Send a command; its reply (events that came before it are kept).
    async fn call(&mut self, session: Option<&str>, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let mut msg = json!({"id": id, "method": method, "params": params});
        if let Some(s) = session {
            msg["sessionId"] = json!(s);
        }
        self.ws
            .write_frame(Frame::text(Payload::Owned(msg.to_string().into_bytes())))
            .await
            .unwrap();
        loop {
            let v = self.read().await;
            if v["id"] == id {
                return v;
            }
            self.backlog.push(v);
        }
    }

    /// The first event `method` that `want` takes, kept or still to come.
    async fn event(&mut self, method: &str, want: impl Fn(&Value) -> bool) -> Value {
        if let Some(i) = self
            .backlog
            .iter()
            .position(|v| v["method"] == method && want(v))
        {
            return self.backlog.remove(i);
        }
        loop {
            let v = self.read().await;
            if v["method"] == method && want(&v) {
                return v;
            }
            self.backlog.push(v);
        }
    }

    /// The agent's close, answered.
    async fn close(mut self) {
        self.ws
            .write_frame(Frame::close(1000, b"done"))
            .await
            .unwrap();
        timeout(Duration::from_secs(10), async {
            while let Ok(f) = self.ws.read_frame().await {
                if matches!(f.opcode, OpCode::Close) {
                    break;
                }
            }
        })
        .await
        .expect("the broker answers the close within 10 s");
    }
}

/// Long strings (scripts, snapshots, screenshots) as their length: the recordings keep the protocol's shape.
fn elide(v: &mut Value) {
    match v {
        Value::String(s) if s.len() > 300 => *v = json!(format!("<{} bytes elided>", s.len())),
        Value::Array(a) => a.iter_mut().for_each(elide),
        Value::Object(o) => o.values_mut().for_each(elide),
        _ => {}
    }
}

fn write_recording(kind: &Kind, product: &str, rec: &Recording) {
    let Some(dir) = std::env::var_os("DRGNX_TEST_RECORD_DIR") else {
        return;
    };
    let pw: Value = serde_json::from_str(
        &std::fs::read_to_string(format!("{PW_MCP}/package.json")).unwrap(),
    )
    .unwrap();
    let mut out = json!({"note": format!(
        "Recorded by drgnx-ratatoskr's tests/browser_real.rs: {product} ({}) with Playwright MCP {} as the agent; \
         the browser side only (what the broker sent, what the browser answered), strings over 300 bytes elided",
        kind.name, pw["version"].as_str().unwrap_or("?"))})
    .to_string();
    out.push('\n');
    for (dir, msg) in rec.lock().unwrap().iter() {
        let mut v: Value = serde_json::from_slice(msg).unwrap();
        elide(&mut v);
        let mut line = serde_json::Map::new();
        line.insert((*dir).to_owned(), v);
        out.push_str(&Value::Object(line).to_string());
        out.push('\n');
    }
    let path = Path::new(&dir).join(format!("real-{}.jsonl", kind.name));
    std::fs::write(&path, out).unwrap();
    eprintln!("browser_real {}: recorded {}", kind.name, path.display());
}

fn run(kind: &Kind) {
    if !wanted(kind) {
        return;
    }
    let _one = SERIAL.lock().unwrap_or_else(|p| p.into_inner());
    let _ = std::fs::remove_dir_all(OWN_DIR);
    let tmp = tempfile::tempdir().unwrap();
    let sock = tmp.path().join("cdp.sock");
    let rec: Recording = Arc::default();
    let (mut host, broker_end) = start_host(kind, &rec);
    let text = format!("{}-page", kind.name);
    let (mut site, site_port) = http_serve(&text);
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let product = rt.block_on(async {
        let secret = Secret::new().unwrap();
        let path = format!("{}{}", broker::PATH_PREFIX, secret.hex());
        let secret = secret.0;
        let gate: GateFn = Arc::new(|| Box::pin(async { Gate::Allow }) as BoxFuture<'static, Gate>);
        let (events_tx, mut events) = mpsc::channel(64);
        broker_end.set_nonblocking(true).unwrap();
        let handle = broker::start(
            BrokerCfg {
                sid: "S1".into(),
                secret,
                max_message: MAX_MESSAGE,
                idle: Duration::from_secs(600),
                gate,
                events: events_tx,
                stderr: None,
            },
            UnixListener::bind(&sock).unwrap(),
            UnixStream::from_std(broker_end).unwrap(),
        );
        let port = tcp_front(sock.clone()).await;

        // the agent: Playwright MCP with the capability URL in its environment (never in its argv)
        let data_url = "data:text/html,%3Ctitle%3Edata-ok%3C%2Ftitle%3E%3Cp%3Edata-ok";
        let site_url = format!("http://127.0.0.1:{site_port}/");
        let mut drive = Command::new(mock());
        drive
            .args(["cdp-drive", data_url, &site_url])
            .env(
                "PLAYWRIGHT_MCP_CDP_ENDPOINT",
                format!("ws://127.0.0.1:{port}{path}"),
            )
            .stdin(Stdio::null());
        let out = timeout(
            Duration::from_secs(240),
            tokio::task::spawn_blocking(move || drive.output().unwrap()),
        )
        .await
        .expect("cdp-drive ends within 240 s")
        .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        eprintln!(
            "browser_real {}: cdp-drive said:\n{stdout}{}",
            kind.name,
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(out.status.success(), "cdp-drive failed: {}", out.status);
        assert!(stdout.contains("TITLE data-ok\n"), "{stdout}");
        assert!(stdout.contains(&format!("TITLE {text}\n")), "{stdout}");

        // the test's own client, once Playwright's websocket is gone
        let mut c = connect(&sock, &path).await;
        let version = c.call(None, "Browser.getVersion", json!({})).await;
        let product = version["result"]["product"]
            .as_str()
            .unwrap_or_else(|| panic!("{version}"))
            .to_owned();
        let refused = c
            .call(None, "Target.exposeDevToolsProtocol", json!({"targetId": "x"}))
            .await;
        assert_eq!(
            refused["error"],
            json!({"code": -32601, "message": "refused by drgnx"}),
            "{refused}"
        );

        // a download: the broker sets its own behaviour, the file lands in the own dir's downloads
        let set = c
            .call(
                None,
                "Browser.setDownloadBehavior",
                json!({"behavior": "allow", "downloadPath": "/nowhere", "eventsEnabled": true}),
            )
            .await;
        assert_eq!(set["result"], json!({}), "{set}");
        let made = c
            .call(
                None,
                "Target.createTarget",
                json!({"url": format!("http://127.0.0.1:{site_port}/download")}),
            )
            .await;
        assert!(made["result"]["targetId"].is_string(), "{made}");
        let done = c
            .event("Browser.downloadProgress", |v| {
                v["params"]["state"] == "completed"
            })
            .await;
        let guid = done["params"]["guid"].as_str().unwrap().to_owned();
        let event = timeout(Duration::from_secs(10), async {
            loop {
                match events.recv().await.expect("the broker's events") {
                    BrokerEvent::Download { guid: g, path } if g == guid => return path,
                    other => eprintln!("browser_real {}: broker event {other:?}", kind.name),
                }
            }
        })
        .await
        .expect("the download's broker event within 10 s");
        assert_eq!(event, format!("{}/{guid}", heimdall::DOWNLOAD_DIR));
        assert_eq!(
            std::fs::read_to_string(format!("{OWN_DIR}/downloads/{guid}")).unwrap(),
            text
        );

        // a page the agent left paused: its close resumes and detaches it
        let auto = c
            .call(
                None,
                "Target.setAutoAttach",
                json!({"autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true}),
            )
            .await;
        assert!(auto["error"].is_null(), "{auto}");
        let made = c
            .call(None, "Target.createTarget", json!({"url": "about:blank"}))
            .await;
        let target = made["result"]["targetId"].as_str().unwrap().to_owned();
        let attached = c
            .event("Target.attachedToTarget", |v| {
                v["params"]["targetInfo"]["targetId"] == target.as_str()
            })
            .await;
        assert_eq!(attached["params"]["waitingForDebugger"], true, "{attached}");
        c.close().await;
        let mut c = connect(&sock, &path).await;
        let a = c
            .call(
                None,
                "Target.attachToTarget",
                json!({"targetId": target, "flatten": true}),
            )
            .await;
        let s = a["result"]["sessionId"]
            .as_str()
            .unwrap_or_else(|| panic!("{a}"))
            .to_owned();
        let enabled = c.call(Some(&s), "Page.enable", json!({})).await;
        assert!(enabled["error"].is_null(), "{enabled}");
        let nav = c
            .call(
                Some(&s),
                "Page.navigate",
                json!({"url": "data:text/html,%3Ctitle%3Eresumed%3C%2Ftitle%3E"}),
            )
            .await;
        assert!(nav["error"].is_null(), "{nav}");
        c.event("Page.loadEventFired", |v| v["sessionId"] == s.as_str())
            .await;
        c.close().await;

        // the hub's own attach worked on this build, or the broker fell back (recorded, not a failure)
        let mut fallback = false;
        while let Ok(e) = events.try_recv() {
            fallback |= e == BrokerEvent::NoBrowserSession;
        }
        eprintln!(
            "browser_real {}: {product}: Target.attachToBrowserTarget {}",
            kind.name,
            if fallback { "failed: the root-session fallback ran" } else { "worked" }
        );
        handle.close();
        product
    });
    // the broker's end closed: the host stops Chromium and exits 0, and nothing of Chromium is left
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || tx.send(host.wait().unwrap()));
    let status = rx
        .recv_timeout(Duration::from_secs(20))
        .expect("the browser host exits within 20 s of the broker's close");
    assert_eq!(status.code(), Some(0), "the browser host's exit");
    let left = Command::new("pgrep")
        .args(["-f", "--", &format!("--user-data-dir={OWN_DIR}/profile")])
        .output()
        .unwrap();
    assert!(
        !left.status.success(),
        "Chromium processes are left: {}",
        String::from_utf8_lossy(&left.stdout)
    );
    let _ = site.kill();
    let _ = site.wait();
    write_recording(kind, &product, &rec);
}

#[test]
fn the_headless_shell_is_driven_by_playwright_mcp() {
    run(&HEADLESS_SHELL);
}

#[test]
fn the_full_chromium_is_driven_by_playwright_mcp() {
    run(&FULL);
}
