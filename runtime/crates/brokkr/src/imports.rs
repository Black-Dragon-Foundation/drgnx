//! What a plugin imports: `drgnx:agent-tools/host` (HTTP to its declared hosts, its own key-value store, the log)
//! and the WASI 0.2 interfaces Rust's `wasm32-wasip2` std imports, with a context that grants nothing.
//!
//! - WASI: each interface is linked by its own generated `add_to_linker`; sockets and `wasi:http` are not linked at
//!   all, and a component importing anything outside [`PROVIDED`] fails to load, named. The `WasiCtx` has no
//!   arguments, an empty environment, stdin closed, stdout and stderr into the log, and no preopened directory.
//! - HTTP: `https` only, to a `host:port` the manifest names, none of the [`REFUSED_HEADERS`], bodies of at most
//!   [`MAX_BODY_BYTES`]; checked here before the hub's [`HostIo::http`] is called. The hub then checks the session's
//!   network cell and the proxy policy. The request runs on the caller's runtime (the hub's), not the guest's.
//! - KV: the plugin's own store, keyed by the name the host loaded it under; at most [`MAX_KV_WRITES`] writes per call.
//! - Log: `host.log`, stdout and stderr share [`MAX_LOG_BYTES`] per call, then the rest is cut.

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use wasmtime::component::{HasSelf, Linker, ResourceTable};
use wasmtime::{Engine, StoreLimits};
use wasmtime_wasi::cli::WasiCliView as _;
use wasmtime_wasi::clocks::WasiClocksView as _;
use wasmtime_wasi::filesystem::WasiFilesystemView as _;
use wasmtime_wasi::p2::bindings::{cli, clocks, filesystem, random};
use wasmtime_wasi::{WasiCtx, WasiCtxView, WasiView};

use crate::guest::AbortOnDrop;
use crate::limits::{
    MAX_BODY_BYTES, MAX_HEADER_VALUE_BYTES, MAX_HEADERS, MAX_KV_KEY_BYTES, MAX_KV_WRITES,
    MAX_LOG_BYTES, MAX_URL_BYTES,
};
use crate::manifest::HostName;

pub(crate) mod bindings {
    wasmtime::component::bindgen!({
        path: "wit",
        world: "drgnx:agent-tools/plugin",
        imports: { default: async | trappable },
        exports: { default: async },
    });
}

use bindings::drgnx::agent_tools::{host, types};

/// A boxed future, as [`HostIo::http`] returns.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What the hub gives a call: HTTP after its own checks, the plugin's key-value store, and the log. `plugin` is the
/// name the host loaded the plugin under, never one the guest chose.
pub trait HostIo: Send + Sync {
    /// A request `brokkr` has already checked (scheme, declared `host:port`, headers, body size). The hub checks the
    /// calling session's network cell and the proxy policy, connects to `req.host:req.port`, and caps the response
    /// body at [`MAX_BODY_BYTES`].
    fn http(&self, plugin: &str, req: HttpReq) -> BoxFuture<'_, Result<HttpResp, String>>;
    fn kv(&self, plugin: &str) -> &dyn Kv;
    fn log(&self, plugin: &str, level: Level, text: &str);
}

/// One plugin's key-value store. The hub caps the sum of key and value lengths at the manifest's `kv_bytes`.
pub trait Kv: Send + Sync {
    fn get(&self, key: &str) -> Option<Vec<u8>>;
    fn put(&self, key: &str, value: &[u8]) -> Result<(), String>;
    fn delete(&self, key: &str) -> Result<(), String>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
}

/// A checked request: `url` is `https://HOST[:PORT]/…`, and `host` and `port` are its parsed authority, a manifest
/// entry. Header names are lowercase.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpReq {
    pub method: Method,
    pub url: String,
    pub host: String,
    pub port: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResp {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Debug,
    Info,
    Warn,
    Error,
}

/// The headers a plugin may never send (and any `proxy-*`): they would steer the connection or the framing.
pub const REFUSED_HEADERS: &[&str] = &[
    "host",
    "connection",
    "upgrade",
    "content-length",
    "transfer-encoding",
    "te",
    "trailer",
    "expect",
    "keep-alive",
];

/// The interfaces a plugin may import, without their `@version`: the host's own and the WASI 0.2 ones Rust's
/// `wasm32-wasip2` std imports. Anything else fails to load.
pub const PROVIDED: &[&str] = &[
    "drgnx:agent-tools/types",
    "drgnx:agent-tools/host",
    "wasi:cli/environment",
    "wasi:cli/exit",
    "wasi:cli/stdin",
    "wasi:cli/stdout",
    "wasi:cli/stderr",
    "wasi:cli/terminal-input",
    "wasi:cli/terminal-output",
    "wasi:cli/terminal-stdin",
    "wasi:cli/terminal-stdout",
    "wasi:cli/terminal-stderr",
    "wasi:io/error",
    "wasi:io/poll",
    "wasi:io/streams",
    "wasi:clocks/monotonic-clock",
    "wasi:clocks/wall-clock",
    "wasi:random/random",
    "wasi:random/insecure",
    "wasi:random/insecure-seed",
    "wasi:filesystem/types",
    "wasi:filesystem/preopens",
];

/// The linker every plugin is instantiated with: [`PROVIDED`], nothing more.
pub(crate) fn linker(engine: &Engine) -> wasmtime::Result<Linker<State>> {
    let mut l = Linker::<State>::new(engine);
    wasmtime_wasi_io::add_to_linker_async(&mut l)?;
    clocks::wall_clock::add_to_linker::<State, wasmtime_wasi::clocks::WasiClocks>(
        &mut l,
        State::clocks,
    )?;
    clocks::monotonic_clock::add_to_linker::<State, wasmtime_wasi::clocks::WasiClocks>(
        &mut l,
        State::clocks,
    )?;
    random::random::add_to_linker::<State, wasmtime_wasi::random::WasiRandom>(&mut l, |s| {
        s.wasi.random()
    })?;
    random::insecure::add_to_linker::<State, wasmtime_wasi::random::WasiRandom>(&mut l, |s| {
        s.wasi.random()
    })?;
    random::insecure_seed::add_to_linker::<State, wasmtime_wasi::random::WasiRandom>(
        &mut l,
        |s| s.wasi.random(),
    )?;
    cli::exit::add_to_linker::<State, wasmtime_wasi::cli::WasiCli>(&mut l, State::cli)?;
    cli::environment::add_to_linker::<State, wasmtime_wasi::cli::WasiCli>(&mut l, State::cli)?;
    cli::stdin::add_to_linker::<State, wasmtime_wasi::cli::WasiCli>(&mut l, State::cli)?;
    cli::stdout::add_to_linker::<State, wasmtime_wasi::cli::WasiCli>(&mut l, State::cli)?;
    cli::stderr::add_to_linker::<State, wasmtime_wasi::cli::WasiCli>(&mut l, State::cli)?;
    cli::terminal_input::add_to_linker::<State, wasmtime_wasi::cli::WasiCli>(&mut l, State::cli)?;
    cli::terminal_output::add_to_linker::<State, wasmtime_wasi::cli::WasiCli>(&mut l, State::cli)?;
    cli::terminal_stdin::add_to_linker::<State, wasmtime_wasi::cli::WasiCli>(&mut l, State::cli)?;
    cli::terminal_stdout::add_to_linker::<State, wasmtime_wasi::cli::WasiCli>(&mut l, State::cli)?;
    cli::terminal_stderr::add_to_linker::<State, wasmtime_wasi::cli::WasiCli>(&mut l, State::cli)?;
    filesystem::types::add_to_linker::<State, wasmtime_wasi::filesystem::WasiFilesystem>(
        &mut l,
        State::filesystem,
    )?;
    filesystem::preopens::add_to_linker::<State, wasmtime_wasi::filesystem::WasiFilesystem>(
        &mut l,
        State::filesystem,
    )?;
    types::add_to_linker::<State, HasSelf<State>>(&mut l, |s| s)?;
    host::add_to_linker::<State, HasSelf<State>>(&mut l, |s| s)?;
    Ok(l)
}

/// The first import of `component` outside [`PROVIDED`], by its full name.
pub(crate) fn unprovided_import(
    engine: &Engine,
    component: &wasmtime::component::Component,
) -> Option<String> {
    component
        .component_type()
        .imports(engine)
        .map(|(name, _)| name)
        .find(|name| {
            let bare = name.split_once('@').map_or(*name, |(n, _)| n);
            !PROVIDED.contains(&bare)
        })
        .map(str::to_string)
}

/// What a call's log has used, and the stdout and stderr it holds until the call ends.
#[derive(Default)]
pub(crate) struct Output {
    used: usize,
    cut: bool,
    streams: [Vec<u8>; 2],
}

impl Output {
    /// What of `n` bytes still fits.
    fn take(&mut self, n: usize) -> usize {
        let fits = n.min(MAX_LOG_BYTES - self.used);
        self.used += fits;
        self.cut |= fits < n;
        fits
    }
}

/// Hands the stdout and stderr a call wrote to the log, then a note when the call's log was cut.
pub(crate) fn flush_output(out: &Mutex<Output>, io: &dyn HostIo, plugin: &str) {
    let mut o = out.lock().unwrap_or_else(|e| e.into_inner());
    for (i, level) in [(0, Level::Info), (1, Level::Warn)] {
        let bytes = std::mem::take(&mut o.streams[i]);
        if !bytes.is_empty() {
            io.log(plugin, level, &String::from_utf8_lossy(&bytes));
        }
    }
    if std::mem::take(&mut o.cut) {
        io.log(
            plugin,
            Level::Warn,
            &format!(
                "the call's log passed {} KiB and was cut",
                MAX_LOG_BYTES / 1024
            ),
        );
    }
}

/// stdout (0) or stderr (1) of a call: never fails, keeps what fits in the call's log.
#[derive(Clone)]
struct Pipe {
    out: Arc<Mutex<Output>>,
    stream: usize,
}

impl wasmtime_wasi::cli::IsTerminal for Pipe {
    fn is_terminal(&self) -> bool {
        false
    }
}

impl wasmtime_wasi::cli::StdoutStream for Pipe {
    fn p2_stream(&self) -> Box<dyn wasmtime_wasi::p2::OutputStream> {
        Box::new(self.clone())
    }
    fn async_stream(&self) -> Box<dyn tokio::io::AsyncWrite + Send + Sync> {
        // WASI 0.3 is not linked
        Box::new(tokio::io::sink())
    }
}

impl wasmtime_wasi::p2::OutputStream for Pipe {
    fn write(&mut self, bytes: bytes::Bytes) -> wasmtime_wasi::p2::StreamResult<()> {
        let mut o = self.out.lock().unwrap_or_else(|e| e.into_inner());
        let fits = o.take(bytes.len());
        o.streams[self.stream].extend_from_slice(&bytes[..fits]);
        Ok(())
    }
    fn flush(&mut self) -> wasmtime_wasi::p2::StreamResult<()> {
        Ok(())
    }
    fn check_write(&mut self) -> wasmtime_wasi::p2::StreamResult<usize> {
        Ok(MAX_LOG_BYTES)
    }
}

#[wasmtime_wasi::async_trait]
impl wasmtime_wasi::p2::Pollable for Pipe {
    async fn ready(&mut self) {}
}

/// One call's store data.
pub(crate) struct State {
    wasi: WasiCtx,
    table: ResourceTable,
    pub(crate) limits: StoreLimits,
    plugin: Arc<str>,
    hosts: Arc<[HostName]>,
    io: Arc<dyn HostIo>,
    /// The caller's runtime, where the hub's HTTP futures run.
    hub: tokio::runtime::Handle,
    kv_writes: u32,
    out: Arc<Mutex<Output>>,
}

impl State {
    pub(crate) fn new(
        limits: StoreLimits,
        plugin: Arc<str>,
        hosts: Arc<[HostName]>,
        io: Arc<dyn HostIo>,
        hub: tokio::runtime::Handle,
        out: Arc<Mutex<Output>>,
    ) -> State {
        // no args, no environment, stdin closed, no preopened directory; only stdout and stderr, into the log
        let wasi = WasiCtx::builder()
            .stdout(Pipe {
                out: out.clone(),
                stream: 0,
            })
            .stderr(Pipe {
                out: out.clone(),
                stream: 1,
            })
            .build();
        State {
            wasi,
            table: ResourceTable::new(),
            limits,
            plugin,
            hosts,
            io,
            hub,
            kv_writes: 0,
            out,
        }
    }
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.wasi,
            table: &mut self.table,
        }
    }
}

impl wasmtime_wasi_io::IoView for State {
    fn table(&mut self) -> &mut ResourceTable {
        &mut self.table
    }
}

impl types::Host for State {}

/// `https://HOST[:PORT]…`: the authority when it is a host and port the manifest names.
pub(crate) fn check_url(hosts: &[HostName], url: &str) -> Result<(String, u16), String> {
    if url.len() > MAX_URL_BYTES {
        return Err(format!("a URL is at most {} KiB", MAX_URL_BYTES / 1024));
    }
    // printable ASCII only: no space, no control character, and no `\`, which some parsers read as `/`
    if !url
        .bytes()
        .all(|b| (0x21..=0x7e).contains(&b) && b != b'\\')
    {
        return Err("a URL is printable ASCII with no space or backslash".into());
    }
    let rest = match url.get(..8) {
        Some(s) if s.eq_ignore_ascii_case("https://") => &url[8..],
        _ => return Err("only https URLs are allowed".into()),
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.contains('@') {
        return Err("a URL may not carry credentials".into());
    }
    if authority.starts_with('[') {
        return Err("an IP literal is not allowed".into());
    }
    let (host, port) = match authority.split_once(':') {
        None => (authority, 443),
        Some((h, p)) => match p.parse::<u16>() {
            Ok(n) if n != 0 && p.bytes().all(|b| b.is_ascii_digit()) => (h, n),
            _ => return Err(format!("{p:?} is not a port")),
        },
    };
    let host = host.to_ascii_lowercase();
    if hosts.iter().any(|h| h.host() == host && h.port() == port) {
        Ok((host, port))
    } else {
        Err(format!("{host}:{port} is not a host this plugin declared"))
    }
}

/// The headers, lowercased, when none is refused or malformed.
pub(crate) fn check_headers(headers: Vec<types::Header>) -> Result<Vec<(String, String)>, String> {
    if headers.len() > MAX_HEADERS {
        return Err(format!("at most {MAX_HEADERS} headers"));
    }
    let token = |b: u8| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b);
    headers
        .into_iter()
        .map(|h| {
            let name = h.name.to_ascii_lowercase();
            if name.is_empty() || name.len() > 256 || !name.bytes().all(token) {
                return Err(format!("{:?} is not a header name", h.name));
            }
            if REFUSED_HEADERS.contains(&name.as_str()) || name.starts_with("proxy-") {
                return Err(format!("the {name} header is not allowed"));
            }
            if h.value.len() > MAX_HEADER_VALUE_BYTES
                || h.value.bytes().any(|b| matches!(b, b'\r' | b'\n' | 0))
            {
                return Err(format!("the {name} header's value is not allowed"));
            }
            Ok((name, h.value))
        })
        .collect()
}

impl State {
    async fn http(
        &mut self,
        method: Method,
        url: String,
        headers: Vec<types::Header>,
        body: Vec<u8>,
    ) -> Result<types::Response, String> {
        let (host, port) = check_url(&self.hosts, &url)?;
        let headers = check_headers(headers)?;
        if body.len() > MAX_BODY_BYTES {
            return Err(format!(
                "a request body is at most {} MiB",
                MAX_BODY_BYTES >> 20
            ));
        }
        let req = HttpReq {
            method,
            url,
            host,
            port,
            headers,
            body,
        };
        let io = self.io.clone();
        let plugin = self.plugin.clone();
        let task = AbortOnDrop(self.hub.spawn(async move { io.http(&plugin, req).await }));
        let resp = task
            .await
            .map_err(|e| format!("the request ended: {e}"))??;
        if resp.body.len() > MAX_BODY_BYTES {
            return Err(format!(
                "a response body is at most {} MiB",
                MAX_BODY_BYTES >> 20
            ));
        }
        Ok(types::Response {
            status: resp.status,
            headers: resp
                .headers
                .into_iter()
                .map(|(name, value)| types::Header { name, value })
                .collect(),
            body: resp.body,
        })
    }

    fn kv_write(
        &mut self,
        key: &str,
        op: impl FnOnce(&dyn Kv) -> Result<(), String>,
    ) -> Result<(), String> {
        if self.kv_writes >= MAX_KV_WRITES {
            return Err(format!("at most {MAX_KV_WRITES} key-value writes per call"));
        }
        self.kv_writes += 1;
        if key.len() > MAX_KV_KEY_BYTES {
            return Err(format!("a key is at most {MAX_KV_KEY_BYTES} bytes"));
        }
        op(self.io.kv(&self.plugin))
    }
}

impl host::Host for State {
    async fn http_get(
        &mut self,
        url: String,
        headers: Vec<types::Header>,
    ) -> wasmtime::Result<Result<types::Response, String>> {
        Ok(self.http(Method::Get, url, headers, Vec::new()).await)
    }

    async fn http_post(
        &mut self,
        url: String,
        headers: Vec<types::Header>,
        body: Vec<u8>,
    ) -> wasmtime::Result<Result<types::Response, String>> {
        Ok(self.http(Method::Post, url, headers, body).await)
    }

    async fn kv_get(&mut self, key: String) -> wasmtime::Result<Option<Vec<u8>>> {
        if key.len() > MAX_KV_KEY_BYTES {
            return Ok(None);
        }
        Ok(self.io.kv(&self.plugin).get(&key))
    }

    async fn kv_put(
        &mut self,
        key: String,
        value: Vec<u8>,
    ) -> wasmtime::Result<Result<(), String>> {
        Ok(self.kv_write(&key, |kv| kv.put(&key, &value)))
    }

    async fn kv_delete(&mut self, key: String) -> wasmtime::Result<Result<(), String>> {
        Ok(self.kv_write(&key, |kv| kv.delete(&key)))
    }

    async fn log(&mut self, level: types::Level, text: String) -> wasmtime::Result<()> {
        let fits = self
            .out
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take(text.len());
        if fits > 0 {
            let mut end = fits;
            while !text.is_char_boundary(end) {
                end -= 1;
            }
            let level = match level {
                types::Level::Debug => Level::Debug,
                types::Level::Info => Level::Info,
                types::Level::Warn => Level::Warn,
                types::Level::Error => Level::Error,
            };
            self.io.log(&self.plugin, level, &text[..end]);
        }
        Ok(())
    }
}
