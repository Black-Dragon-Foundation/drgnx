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
//!   `{"closed": true}` when the client hangs up before it was answered to the end; with `--print-closed` it also
//!   prints `MOCK-LLM-CLOSED` then.
//! - `proxy [--log FILE]` prints `MOCK-PROXY-PORT N`; `CONNECT host:port` is logged (`{"connect": "host:port"}`) and
//!   tunnelled, anything else gets 405 (logged as `{"refused": "METHOD TARGET"}`).
//!
//! - `acp --as claude|codex|gemini [--script FILE] [--log FILE] [--llm URL]` is a scripted ACP agent on stdio (src/mock_acp/mod.rs).
//! - `hf --dir DIR [--log FILE] [--cut FILE BYTES] [--bad FILE] [--location URL] [--no-range]` is the model host: it prints
//!   `MOCK-HF-PORT N` and `MOCK-HF-CDN-PORT M`. `/…/resolve/REV/FILE` on N answers 302 to `FILE?sig=1` on M (or to URL, always,
//!   with `--location`), and M serves the files of DIR and honours `Range: bytes=START-` (unless `--no-range`). The first
//!   response for FILE stops after BYTES with `--cut`; a last byte is flipped with `--bad`. The log is JSONL: `{server, path,
//!   range, credentials}`.
//! - `http-serve PORT TEXT` prints `MOCK-HTTP-PORT N` and serves on 127.0.0.1:PORT (0: any free port) a page whose
//!   title and text are TEXT, for every path but `/download`, which is TEXT as an attachment (`TEXT.txt`): an agent's
//!   dev server, a site on the host.
//! - `cdp-drive URL…` is an outside agent's browser tool: it runs Playwright MCP (`node` and the test image's
//!   `/opt/pw-mcp`) over stdio with this process's environment, so it reaches the browser the session's
//!   `PLAYWRIGHT_MCP_CDP_ENDPOINT` names, and for each URL calls `browser_navigate` and `browser_snapshot` and prints
//!   `TITLE <the page's title>`, or `ERROR <url>: <why>` (exit 1 when any failed).
//!
//! - `embed [--dims N] [--log FILE] [--parent PID]` prints `MOCK-EMBED-PORT N` and serves, on 127.0.0.1 only, TEI's `POST
//!   /embed {"inputs"}` (a list of vectors) and Ollama's `POST /api/embed {"model", "input"}` (`{"model", "embeddings",
//!   "prompt_eval_count"}`, the words of the inputs). A vector is made from its text's bytes, so equal texts give equal
//!   vectors. The log is JSONL like `llm`'s.
//!
//! `llm` and `embed` end when `--parent` is gone.

#[path = "../mock_acp/mod.rs"]
mod mock_acp;

use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use serde_json::{Value, json};
use std::fs::File;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub(crate) fn die(why: &str) -> ! {
    eprintln!("ratatoskr-mock: {why}");
    std::process::exit(1)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("llm") => llm(&args[1..]),
        Some("proxy") => proxy(&args[1..]),
        Some("acp") => mock_acp::run(&args[1..]),
        Some("hf") => hf(&args[1..]),
        Some("embed") => embed(&args[1..]),
        Some("http-serve") => http_serve(&args[1..]),
        Some("cdp-drive") => cdp_drive(&args[1..]),
        _ => die(
            "usage: ratatoskr-mock embed [--dims N] [--log FILE] [--parent PID] | llm --script FILE [--log FILE] [--tls CA_FILE] [--parent PID] | proxy [--log FILE] | acp --as claude|codex|gemini [--script FILE] [--log FILE] [--llm URL] | hf --dir DIR [--log FILE] [--cut FILE BYTES] [--bad FILE] [--location URL] [--no-range] | http-serve PORT TEXT | cdp-drive URL...",
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
    /// `--print-closed`: say `MOCK-LLM-CLOSED` on stdout (after the log line) when a client hangs up early, so a test
    /// can wait for the hang-up instead of reading the log until it shows.
    print_closed: bool,
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
        if shared.print_closed {
            // a reader that is gone is no concern of the mock
            let mut out = std::io::stdout();
            let _ = writeln!(out, "MOCK-LLM-CLOSED").and_then(|()| out.flush());
        }
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
        print_closed: args.iter().any(|a| a == "--print-closed"),
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

// ------------------------------------------------------------------------------------------ hf

struct Host {
    dir: std::path::PathBuf,
    log: Option<Mutex<File>>,
    cdn_port: u16,
    location: Option<String>,
    bad: Option<String>,
    no_range: bool,
    /// The file to cut and where, until it has been.
    cut: Mutex<Option<(String, usize)>>,
}

impl Host {
    /// The request's target and Range, logged.
    fn request(&self, c: &mut TcpStream, server: &str) -> Option<(String, Option<String>)> {
        let head = read_head(c)?;
        let path = head.lines().next()?.split(' ').nth(1)?.to_string();
        let field = |name: &str| {
            head.lines().find_map(|l| {
                let (k, v) = l.split_once(':')?;
                k.eq_ignore_ascii_case(name).then(|| v.trim().to_string())
            })
        };
        let range = field("range");
        let credentials = field("authorization").is_some() || field("cookie").is_some();
        log_line(
            &self.log,
            &json!({"server": server, "path": path, "range": range, "credentials": credentials}),
        );
        Some((path, range))
    }

    fn resolve(&self, mut c: TcpStream) {
        let Some((path, _)) = self.request(&mut c, "resolve") else {
            return;
        };
        let file = path
            .split_once("/resolve/")
            .and_then(|(_, rest)| rest.split_once('/'))
            .map_or("", |(_, file)| file);
        let target = match &self.location {
            Some(url) => url.clone(),
            None => format!("http://127.0.0.1:{}/{file}?sig=1", self.cdn_port),
        };
        let found = self.location.is_some() || self.dir.join(file).is_file();
        let head = if found {
            format!("HTTP/1.1 302 Found\r\nLocation: {target}\r\n")
        } else {
            "HTTP/1.1 404 Not Found\r\n".to_string()
        };
        let _ =
            c.write_all(format!("{head}Content-Length: 0\r\nConnection: close\r\n\r\n").as_bytes());
    }

    fn serve(&self, mut c: TcpStream) {
        let Some((path, range)) = self.request(&mut c, "cdn") else {
            return;
        };
        let file = path.trim_start_matches('/').split('?').next().unwrap_or("");
        let Ok(mut bytes) = std::fs::read(self.dir.join(file)) else {
            let _ = c.write_all(
                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
            return;
        };
        if self.bad.as_deref() == Some(file)
            && let Some(last) = bytes.last_mut()
        {
            *last ^= 1;
        }
        let size = bytes.len();
        let start = range
            .as_deref()
            .filter(|_| !self.no_range)
            .and_then(|r| r.strip_prefix("bytes=")?.strip_suffix('-')?.parse().ok());
        let head = match start {
            Some(s) if s < size => format!(
                "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {s}-{}/{size}\r\nContent-Length: {}\r\n",
                size - 1,
                size - s
            ),
            Some(_) => format!(
                "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{size}\r\nContent-Length: 0\r\n"
            ),
            None => format!("HTTP/1.1 200 OK\r\nContent-Length: {size}\r\n"),
        };
        let start = start.unwrap_or(0).min(size);
        let mut body = &bytes[start..];
        if head.contains(" 416 ") {
            body = &[];
        }
        let mut cut = self.cut.lock().unwrap();
        if cut.as_ref().is_some_and(|(name, _)| name == file) {
            let (_, at) = cut.take().unwrap();
            body = &body[..at.min(body.len())];
        }
        drop(cut);
        let _ = c.write_all(format!("{head}Connection: close\r\n\r\n").as_bytes());
        let _ = c.write_all(body);
        let _ = c.flush();
        let _ = c.shutdown(Shutdown::Both);
    }
}

// ------------------------------------------------------------------------------------------ embed

/// The vector of TEXT: DIMS numbers in 0..1 from an FNV-1a hash of its bytes, so equal texts give equal vectors and
/// different texts differ.
fn embed_vector(text: &str, dims: usize) -> Vec<f64> {
    let h = text.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
    });
    (0..dims)
        .map(|i| (h.rotate_left(i as u32 * 7) % 1000) as f64 / 1000.0)
        .collect()
}

/// One request of the embedding server: TEI's `POST /embed {"inputs": [...]}` answers a list of vectors, Ollama's
/// `POST /api/embed {"model", "input": TEXT|[TEXT...]}` answers `{"model", "embeddings", "prompt_eval_count"}` (the
/// words of the inputs, which the gateway counts as input tokens). Anything else is 404.
fn embed_serve(mut sock: TcpStream, dims: usize, log: &Option<Mutex<File>>) {
    let Some(req) = read_request(&mut sock) else {
        return;
    };
    let body = String::from_utf8_lossy(&req.body).into_owned();
    log_line(
        log,
        &json!({"request": {"method": req.method, "path": req.path, "headers": req.headers, "body": body}}),
    );
    let parsed: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
    let texts = |v: &Value| -> Vec<String> {
        match v {
            Value::String(s) => vec![s.clone()],
            Value::Array(a) => a
                .iter()
                .filter_map(|t| t.as_str().map(str::to_owned))
                .collect(),
            _ => vec![],
        }
    };
    let answer = match req.path.as_str() {
        "/embed" => {
            let inputs = texts(&parsed["inputs"]);
            Some(json!(
                inputs
                    .iter()
                    .map(|t| embed_vector(t, dims))
                    .collect::<Vec<_>>()
            ))
        }
        "/api/embed" => {
            let inputs = texts(&parsed["input"]);
            let words: usize = inputs.iter().map(|t| t.split_whitespace().count()).sum();
            Some(json!({
                "model": parsed["model"],
                "embeddings": inputs.iter().map(|t| embed_vector(t, dims)).collect::<Vec<_>>(),
                "prompt_eval_count": words,
            }))
        }
        _ => None,
    };
    let (status, text) = match answer {
        Some(v) => (200, v.to_string()),
        None => (404, "{}".to_string()),
    };
    let _ = sock
        .write_all(head(status, "application/json", Some(text.len()), &[]).as_bytes())
        .and_then(|()| sock.write_all(text.as_bytes()))
        .and_then(|()| sock.flush());
    let _ = sock.shutdown(Shutdown::Write);
}

/// `embed [--dims N] [--log FILE] [--parent PID]`: prints `MOCK-EMBED-PORT N` and serves TEI's and Ollama's embedding
/// requests on 127.0.0.1 only (a client that resolves `localhost` to `::1` first must fall back).
fn embed(args: &[String]) {
    let dims = flag(args, "--dims", 1).map_or(8, |d| {
        d[0].parse()
            .unwrap_or_else(|_| die("--dims is a number of dimensions"))
    });
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
    let log = Arc::new(open_log(args));
    let listener =
        TcpListener::bind("127.0.0.1:0").unwrap_or_else(|e| die(&format!("cannot listen: {e}")));
    announce("MOCK-EMBED-PORT", &listener);
    for sock in listener.incoming().flatten() {
        let log = log.clone();
        std::thread::spawn(move || embed_serve(sock, dims, &log));
    }
}

fn hf(args: &[String]) {
    let dir = flag(args, "--dir", 1).unwrap_or_else(|| die("hf needs --dir"));
    let listen =
        || TcpListener::bind("127.0.0.1:0").unwrap_or_else(|e| die(&format!("cannot listen: {e}")));
    let (front, cdn) = (listen(), listen());
    let cut = flag(args, "--cut", 2).map(|c| {
        let at = c[1].parse().unwrap_or_else(|_| die("--cut needs a count"));
        (c[0].clone(), at)
    });
    let host = Arc::new(Host {
        dir: dir[0].clone().into(),
        log: open_log(args),
        cdn_port: cdn.local_addr().map(|a| a.port()).unwrap_or(0),
        location: flag(args, "--location", 1).map(|l| l[0].clone()),
        bad: flag(args, "--bad", 1).map(|b| b[0].clone()),
        no_range: args.iter().any(|a| a == "--no-range"),
        cut: Mutex::new(cut),
    });
    announce("MOCK-HF-PORT", &front);
    announce("MOCK-HF-CDN-PORT", &cdn);
    let files = host.clone();
    std::thread::spawn(move || {
        for sock in cdn.incoming().flatten() {
            let host = files.clone();
            std::thread::spawn(move || host.serve(sock));
        }
    });
    for sock in front.incoming().flatten() {
        let host = host.clone();
        std::thread::spawn(move || host.resolve(sock));
    }
}

// ------------------------------------------------------------------------------------------ http-serve

fn http_serve(args: &[String]) {
    let [port, text] = args else {
        die("usage: http-serve PORT TEXT")
    };
    let port: u16 = port
        .parse()
        .unwrap_or_else(|_| die("http-serve: PORT is a number"));
    let listener = TcpListener::bind(("127.0.0.1", port))
        .unwrap_or_else(|e| die(&format!("cannot listen on 127.0.0.1:{port}: {e}")));
    announce("MOCK-HTTP-PORT", &listener);
    let text: Arc<str> = text.as_str().into();
    for sock in listener.incoming().flatten() {
        let text = text.clone();
        std::thread::spawn(move || page(sock, &text));
    }
}

/// One request: `/download` is TEXT as an attachment, any other path the page.
fn page(mut c: TcpStream, text: &str) {
    // a browser's spare connection may never send a request
    let _ = c.set_read_timeout(Some(Duration::from_secs(10)));
    let Some(head) = read_head(&mut c) else {
        return;
    };
    let path = head.split(' ').nth(1).unwrap_or("/");
    let (content_type, extra, body) = if path == "/download" {
        (
            "text/plain",
            format!("Content-Disposition: attachment; filename=\"{text}.txt\"\r\n"),
            text.to_string(),
        )
    } else {
        let t = text
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;");
        (
            "text/html; charset=utf-8",
            String::new(),
            format!("<!doctype html><html><head><title>{t}</title></head><body><p>{t}</p></body></html>"),
        )
    };
    let _ = c.write_all(
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\n{extra}Connection: close\r\n\r\n{body}",
            body.len()
        )
        .as_bytes(),
    );
}

// ------------------------------------------------------------------------------------------ cdp-drive

/// Playwright MCP in the test image (`test/container/browser/Containerfile`).
const PW_MCP: &str = "/opt/pw-mcp/node_modules/@playwright/mcp/cli.js";
/// How long one MCP call may take (a navigation through the session's proxy included).
const CALL_WITHIN: Duration = Duration::from_secs(60);

struct Mcp {
    to: std::process::ChildStdin,
    from: std::sync::mpsc::Receiver<Value>,
    next: u64,
}

impl Mcp {
    fn send(&mut self, v: &Value) {
        if writeln!(self.to, "{v}").and_then(|()| self.to.flush()).is_err() {
            die("cdp-drive: Playwright MCP closed its stdin");
        }
    }

    /// A request and its answer (the result, or the error as `Err`).
    fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        let end = std::time::Instant::now() + CALL_WITHIN;
        loop {
            let left = end.saturating_duration_since(std::time::Instant::now());
            let v = self.from.recv_timeout(left).map_err(|_| {
                format!(
                    "no answer to {method} within {} s",
                    CALL_WITHIN.as_secs()
                )
            })?;
            if v["id"] == id {
                return match v.get("error") {
                    Some(e) => Err(e.to_string()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }

    /// A tool's text, or its error text as `Err`.
    fn tool(&mut self, name: &str, arguments: Value) -> Result<String, String> {
        let r = self.call(
            "tools/call",
            json!({"name": name, "arguments": arguments}),
        )?;
        let text = r["content"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|c| c["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n");
        if r["isError"] == true {
            Err(text)
        } else {
            Ok(text)
        }
    }
}

/// The title Playwright MCP reports in a tool's text (`- Page Title: T`).
fn page_title(text: &str) -> Option<&str> {
    text.lines()
        .find_map(|l| l.trim_start_matches(['-', ' ']).strip_prefix("Page Title:"))
        .map(str::trim)
}

fn cdp_drive(urls: &[String]) {
    if urls.is_empty() {
        die("usage: cdp-drive URL...");
    }
    let mut child = std::process::Command::new("node")
        .arg(PW_MCP)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .unwrap_or_else(|e| die(&format!("cannot run node {PW_MCP}: {e}")));
    let (tx, rx) = std::sync::mpsc::channel();
    let out = child.stdout.take().expect("piped");
    std::thread::spawn(move || {
        use std::io::BufRead;
        for line in std::io::BufReader::new(out).lines().map_while(Result::ok) {
            if let Ok(v) = serde_json::from_str::<Value>(&line)
                && tx.send(v).is_err()
            {
                break;
            }
        }
    });
    let mut mcp = Mcp {
        to: child.stdin.take().expect("piped"),
        from: rx,
        next: 0,
    };
    let init = json!({"protocolVersion": "2025-06-18", "capabilities": {},
                      "clientInfo": {"name": "ratatoskr-mock cdp-drive", "version": "1"}});
    if let Err(e) = mcp.call("initialize", init) {
        let _ = child.kill();
        die(&format!("cdp-drive: initialize: {e}"));
    }
    mcp.send(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));
    let mut failed = false;
    let mut out = std::io::stdout();
    for url in urls {
        let got = mcp
            .tool("browser_navigate", json!({"url": url}))
            .and_then(|nav| {
                let snap = mcp.tool("browser_snapshot", json!({}))?;
                Ok(page_title(&snap)
                    .or_else(|| page_title(&nav))
                    .map(str::to_owned)
                    .unwrap_or_else(|| {
                        eprintln!("cdp-drive: no page title in the snapshot:\n{snap}");
                        "?".into()
                    }))
            });
        let line = match got {
            Ok(title) => format!("TITLE {title}"),
            Err(e) => {
                failed = true;
                let why = e.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
                format!("ERROR {url}: {why}")
            }
        };
        let _ = writeln!(out, "{line}").and_then(|()| out.flush());
    }
    // closing its stdin ends Playwright MCP, which disconnects from the browser
    drop(mcp);
    let end = std::time::Instant::now() + Duration::from_secs(10);
    while matches!(child.try_wait(), Ok(None)) && std::time::Instant::now() < end {
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = child.kill();
    let _ = child.wait();
    std::process::exit(i32::from(failed));
}
