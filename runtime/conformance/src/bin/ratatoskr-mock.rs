//! ratatoskr-mock: stand-ins for the network, for the conformance rows (docs/develop/runtime.md).  Std only, threads.
//!
//! - `llm --script FILE [--log FILE] [--tls CA_FILE] [--parent PID]` prints `MOCK-LLM-PORT N` and serves a scripted
//!   provider on 127.0.0.1.  With `--tls` it makes a certificate authority and a leaf for `localhost` and 127.0.0.1
//!   at start, writes the CA's certificate (PEM, no key) to CA_FILE, prints `MOCK-LLM-CA CA_FILE` before the port
//!   line and serves TLS; the keys stay in memory.  Else plain.  A port of `test/fixtures/mock-llm.el`.  The
//!   script is a JSON array of answers `{path, match?, status, delay_ms, body, headers, once, chunks, content_type,
//!   no_end}`; the first whose `path` is a prefix of the request path and whose `match` occurs in the body answers,
//!   else 404 `{}`.  `once` answers once and goes; `status` 0 never answers; `chunks` `[[delay_ms, text]…]` streams
//!   (the head at once, no length, each text after its delay, then the close; with `no_end` the connection is dropped
//!   instead).  The log is JSONL: `{"request": {method, path, headers (lower-case names), body}}` per request, then
//!   `{"closed": true}` when the client hangs up before it was answered to the end.
//! - `proxy [--log FILE]` prints `MOCK-PROXY-PORT N`; `CONNECT host:port` is logged (`{"connect": "host:port"}`) and
//!   tunnelled, anything else gets 405 (logged as `{"refused": "METHOD TARGET"}`).
//!
//! `llm` ends when `--parent` is gone.

use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use serde_json::{Value, json};
use std::fs::File;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn die(why: &str) -> ! {
    eprintln!("ratatoskr-mock: {why}");
    std::process::exit(1)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("llm") => llm(&args[1..]),
        Some("proxy") => proxy(&args[1..]),
        _ => die(
            "usage: ratatoskr-mock llm --script FILE [--log FILE] [--tls CA_FILE] [--parent PID] | proxy [--log FILE]",
        ),
    }
}

/// The value after `flag` (n of them), or none when the flag is absent.
fn flag<'a>(args: &'a [String], name: &str, n: usize) -> Option<&'a [String]> {
    let i = args.iter().position(|a| a == name)?;
    args.get(i + 1..i + 1 + n)
        .or_else(|| die(&format!("{name} needs {n} value(s)")))
}

fn open_log(args: &[String]) -> Option<Mutex<File>> {
    flag(args, "--log", 1).map(|p| {
        Mutex::new(
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&p[0])
                .unwrap_or_else(|e| die(&format!("cannot open the log {}: {e}", p[0]))),
        )
    })
}

fn log_line(log: &Option<Mutex<File>>, v: &Value) {
    if let Some(f) = log {
        let mut f = f.lock().unwrap();
        let _ = f.write_all(format!("{v}\n").as_bytes());
    }
}

fn announce(what: &str, listener: &TcpListener) {
    let port = listener.local_addr().map(|a| a.port()).unwrap_or(0);
    println!("{what} {port}");
    let _ = std::io::stdout().flush();
}

fn parent_gone(pid: i32) -> bool {
    if unsafe { libc::kill(pid, 0) } != 0 {
        return true;
    }
    // a zombie still answers kill 0: its parent has not reaped it
    std::fs::read_to_string(format!("/proc/{pid}/stat")).is_ok_and(|s| s.contains(") Z"))
}

// ------------------------------------------------------------------------------------------ llm

#[derive(Clone)]
struct Entry {
    path: String,
    needle: Option<String>,
    status: u16,
    delay_ms: u64,
    body: String,
    headers: Vec<(String, String)>,
    once: bool,
    chunks: Option<Vec<(u64, String)>>,
    content_type: Option<String>,
    no_end: bool,
}

fn parse_entry(v: &Value) -> Result<Entry, String> {
    let o = v.as_object().ok_or("an answer is an object")?;
    let s = |k: &str| o.get(k).and_then(Value::as_str).map(str::to_string);
    let n = |k: &str| o.get(k).and_then(Value::as_u64);
    let headers = match o.get("headers") {
        None | Some(Value::Null) => vec![],
        Some(Value::Object(h)) => h
            .iter()
            .map(|(k, v)| (k.clone(), v.as_str().unwrap_or_default().to_string()))
            .collect(),
        Some(_) => return Err("\"headers\" is an object".into()),
    };
    let chunks = match o.get("chunks") {
        None | Some(Value::Null) => None,
        Some(Value::Array(a)) => Some(
            a.iter()
                .map(|c| match c.as_array().map(Vec::as_slice) {
                    Some([d, t]) => Ok((
                        d.as_u64().ok_or("a chunk delay is a number of ms")?,
                        t.as_str().ok_or("a chunk text is a string")?.to_string(),
                    )),
                    _ => Err("a chunk is [delay_ms, text]"),
                })
                .collect::<Result<Vec<_>, _>>()?,
        ),
        Some(_) => return Err("\"chunks\" is an array".into()),
    };
    Ok(Entry {
        path: s("path").ok_or("an answer needs \"path\"")?,
        needle: s("match"),
        status: n("status").unwrap_or(200) as u16,
        delay_ms: n("delay_ms").unwrap_or(0),
        body: s("body").unwrap_or_else(|| "{}".into()),
        headers,
        once: o.get("once").and_then(Value::as_bool).unwrap_or(false),
        chunks,
        content_type: s("content_type"),
        no_end: o.get("no_end").and_then(Value::as_bool).unwrap_or(false),
    })
}

struct Shared {
    script: Mutex<Vec<Entry>>,
    log: Option<Mutex<File>>,
}

/// A client connection, plain or TLS.
trait Wire: Read + Write {
    fn fd(&self) -> i32;
    /// A clean end of the answer.
    fn finish(&mut self);
}

impl Wire for TcpStream {
    fn fd(&self) -> i32 {
        self.as_raw_fd()
    }
    fn finish(&mut self) {
        let _ = self.shutdown(Shutdown::Write);
    }
}

impl Wire for rustls::StreamOwned<rustls::ServerConnection, TcpStream> {
    fn fd(&self) -> i32 {
        self.sock.as_raw_fd()
    }
    fn finish(&mut self) {
        self.conn.send_close_notify();
        let _ = self.flush();
        let _ = self.sock.shutdown(Shutdown::Write);
    }
}

/// Wait up to MS for the client to speak or go: after the request nothing more is expected, so readable = hung up.
fn hung_up_within(fd: i32, ms: u64) -> bool {
    let mut p = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    unsafe { libc::poll(&mut p, 1, ms.min(i32::MAX as u64) as i32) > 0 }
}

struct Request {
    method: String,
    path: String,
    headers: serde_json::Map<String, Value>,
    body: Vec<u8>,
}

fn read_request(w: &mut dyn Wire) -> Option<Request> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    let head_end = loop {
        if let Some(i) = buf.windows(4).position(|x| x == b"\r\n\r\n") {
            break i + 4;
        }
        if buf.len() > 65536 {
            return None;
        }
        match w.read(&mut chunk) {
            Ok(0) | Err(_) => return None,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).into_owned();
    let mut lines = head.split("\r\n");
    let mut start = lines.next()?.split(' ');
    let (method, path) = (start.next()?.to_string(), start.next()?.to_string());
    let mut headers = serde_json::Map::new();
    for l in lines {
        if let Some((k, v)) = l.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), json!(v.trim()));
        }
    }
    let len: usize = headers
        .get("content-length")
        .and_then(Value::as_str)
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    while buf.len() < head_end + len {
        match w.read(&mut chunk) {
            Ok(0) | Err(_) => return None,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    }
    Some(Request {
        method,
        path,
        headers,
        body: buf[head_end..head_end + len].to_vec(),
    })
}

fn head(
    status: u16,
    content_type: &str,
    length: Option<usize>,
    extra: &[(String, String)],
) -> String {
    let mut h = format!("HTTP/1.1 {status} X\r\nContent-Type: {content_type}\r\n");
    if let Some(n) = length {
        h.push_str(&format!("Content-Length: {n}\r\n"));
    }
    h.push_str("Connection: close\r\n");
    for (k, v) in extra {
        h.push_str(&format!("{k}: {v}\r\n"));
    }
    h.push_str("\r\n");
    h
}

/// Answer from ENTRY (none: 404).  True when the client hung up first.
fn answer(w: &mut dyn Wire, entry: Option<&Entry>) -> bool {
    let fd = w.fd();
    let Some(e) = entry else {
        let ok = w
            .write_all(head(404, "application/json", Some(2), &[]).as_bytes())
            .and_then(|()| w.write_all(b"{}"))
            .is_ok();
        w.finish();
        return !ok;
    };
    if e.status == 0 {
        // a hanging provider: never answers; ends when the client goes (or the process does)
        while !hung_up_within(fd, 1000) {}
        return true;
    }
    if let Some(chunks) = &e.chunks {
        let ct = e.content_type.as_deref().unwrap_or("text/event-stream");
        if w.write_all(head(e.status, ct, None, &e.headers).as_bytes())
            .and_then(|()| w.flush())
            .is_err()
        {
            return true;
        }
        for (delay, text) in chunks {
            if hung_up_within(fd, *delay) {
                return true;
            }
            if w.write_all(text.as_bytes())
                .and_then(|()| w.flush())
                .is_err()
            {
                return true;
            }
        }
        if e.no_end {
            // the stream stops, then the connection drops (no clean end)
            return hung_up_within(fd, 50);
        }
        w.finish();
        return false;
    }
    if hung_up_within(fd, e.delay_ms) {
        return true;
    }
    let ct = e.content_type.as_deref().unwrap_or("application/json");
    let ok = w
        .write_all(head(e.status, ct, Some(e.body.len()), &e.headers).as_bytes())
        .and_then(|()| w.write_all(e.body.as_bytes()))
        .and_then(|()| w.flush())
        .is_ok();
    w.finish();
    !ok
}

fn serve(mut w: Box<dyn Wire>, shared: &Shared) {
    let Some(req) = read_request(&mut *w) else {
        return;
    };
    let body = String::from_utf8_lossy(&req.body).into_owned();
    let entry = {
        let mut script = shared.script.lock().unwrap();
        script
            .iter()
            .position(|e| {
                req.path.starts_with(&e.path) && e.needle.as_ref().is_none_or(|n| body.contains(n))
            })
            .map(|i| {
                if script[i].once {
                    script.remove(i)
                } else {
                    script[i].clone()
                }
            })
    };
    log_line(
        &shared.log,
        &json!({"request": {"method": req.method, "path": req.path, "headers": req.headers, "body": body}}),
    );
    if answer(&mut *w, entry.as_ref()) {
        log_line(&shared.log, &json!({"closed": true}));
    }
}

/// A CA and a leaf for `localhost` and 127.0.0.1, made now (test keys are made at run time, never committed). The CA's
/// certificate goes to CA_FILE for the hub's `SSL_CERT_FILE`; neither key leaves this process.
fn tls_config(ca_file: &str) -> Arc<rustls::ServerConfig> {
    use rcgen::{
        BasicConstraints, CertificateParams, DnType, ExtendedKeyUsagePurpose, IsCa, Issuer,
        KeyPair, KeyUsagePurpose, SanType,
    };
    let fail = |e: rcgen::Error| -> ! { die(&format!("cannot make the test certificates: {e}")) };
    let ca_key = KeyPair::generate().unwrap_or_else(|e| fail(e));
    let mut ca = CertificateParams::new(Vec::<String>::new()).unwrap_or_else(|e| fail(e));
    ca.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    ca.distinguished_name
        .push(DnType::CommonName, "ratatoskr-mock test CA");
    let ca_pem = ca.self_signed(&ca_key).unwrap_or_else(|e| fail(e)).pem();
    let issuer = Issuer::new(ca, ca_key);
    let leaf_key = KeyPair::generate().unwrap_or_else(|e| fail(e));
    let mut leaf =
        CertificateParams::new(vec!["localhost".to_string()]).unwrap_or_else(|e| fail(e));
    leaf.subject_alt_names
        .push(SanType::IpAddress(std::net::IpAddr::from([127, 0, 0, 1])));
    leaf.distinguished_name
        .push(DnType::CommonName, "localhost");
    leaf.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    let cert = leaf
        .signed_by(&leaf_key, &issuer)
        .unwrap_or_else(|e| fail(e));
    std::fs::write(ca_file, ca_pem)
        .unwrap_or_else(|e| die(&format!("cannot write the CA to {ca_file}: {e}")));
    println!("MOCK-LLM-CA {ca_file}");
    let certs = vec![CertificateDer::from(cert.der().to_vec())];
    let key = PrivateKeyDer::Pkcs8(leaf_key.serialize_der().into());
    let cfg = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap_or_else(|e| die(&format!("TLS versions: {e}")))
    .with_no_client_auth()
    .with_single_cert(certs, key)
    .unwrap_or_else(|e| die(&format!("the certificate and key do not fit: {e}")));
    Arc::new(cfg)
}

fn llm(args: &[String]) {
    let script_path =
        flag(args, "--script", 1).map_or_else(|| die("llm needs --script FILE"), |s| &s[0]);
    let script: Vec<Entry> = std::fs::read_to_string(script_path)
        .map_err(|e| e.to_string())
        .and_then(|t| serde_json::from_str::<Vec<Value>>(&t).map_err(|e| e.to_string()))
        .and_then(|a| a.iter().map(parse_entry).collect())
        .unwrap_or_else(|e| die(&format!("script {script_path}: {e}")));
    let tls = flag(args, "--tls", 1).map(|t| tls_config(&t[0]));
    if let Some(p) = flag(args, "--parent", 1) {
        let pid: i32 = p[0].parse().unwrap_or_else(|_| die("--parent is a pid"));
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(Duration::from_secs(1));
                if parent_gone(pid) {
                    std::process::exit(0);
                }
            }
        });
    }
    let shared = Arc::new(Shared {
        script: Mutex::new(script),
        log: open_log(args),
    });
    let listener =
        TcpListener::bind("127.0.0.1:0").unwrap_or_else(|e| die(&format!("cannot listen: {e}")));
    announce("MOCK-LLM-PORT", &listener);
    for sock in listener.incoming().flatten() {
        let shared = shared.clone();
        let tls = tls.clone();
        std::thread::spawn(move || {
            let w: Box<dyn Wire> = match tls {
                Some(cfg) => match rustls::ServerConnection::new(cfg) {
                    Ok(c) => Box::new(rustls::StreamOwned::new(c, sock)),
                    Err(_) => return,
                },
                None => Box::new(sock),
            };
            serve(w, &shared);
        });
    }
}

// ------------------------------------------------------------------------------------------ proxy

/// The request head, byte by byte so nothing past it is taken from the tunnel.
fn read_head(c: &mut TcpStream) -> Option<String> {
    let mut head = Vec::new();
    let mut b = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if head.len() > 16384 || !matches!(c.read(&mut b), Ok(1)) {
            return None;
        }
        head.push(b[0]);
    }
    Some(String::from_utf8_lossy(&head).into_owned())
}

fn tunnel(mut client: TcpStream, log: &Option<Mutex<File>>) {
    let Some(head) = read_head(&mut client) else {
        return;
    };
    let mut first = head.lines().next().unwrap_or("").split(' ');
    let (method, target) = (first.next().unwrap_or(""), first.next().unwrap_or(""));
    if method != "CONNECT" {
        log_line(log, &json!({"refused": format!("{method} {target}")}));
        let _ = client.write_all(
            b"HTTP/1.1 405 Method Not Allowed\r\nAllow: CONNECT\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
        return;
    }
    log_line(log, &json!({"connect": target}));
    let Ok(upstream) = TcpStream::connect(target) else {
        let _ = client.write_all(
            b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
        return;
    };
    if client
        .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        .is_err()
    {
        return;
    }
    let (Ok(mut client_r), Ok(mut upstream_w)) = (client.try_clone(), upstream.try_clone()) else {
        return;
    };
    let up = std::thread::spawn(move || {
        let _ = std::io::copy(&mut client_r, &mut upstream_w);
        let _ = upstream_w.shutdown(Shutdown::Write);
    });
    let (mut upstream_r, mut client_w) = (upstream, client);
    let _ = std::io::copy(&mut upstream_r, &mut client_w);
    let _ = client_w.shutdown(Shutdown::Write);
    let _ = up.join();
}

fn proxy(args: &[String]) {
    let log = Arc::new(open_log(args));
    let listener =
        TcpListener::bind("127.0.0.1:0").unwrap_or_else(|e| die(&format!("cannot listen: {e}")));
    announce("MOCK-PROXY-PORT", &listener);
    for sock in listener.incoming().flatten() {
        let log = log.clone();
        std::thread::spawn(move || tunnel(sock, &log));
    }
}
