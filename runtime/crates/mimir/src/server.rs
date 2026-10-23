//! One connection's loop: newline-delimited JSON-RPC 2.0, both protocol eras (docs/develop/runtime.md, "mimir").
//!
//! A reader frames lines (at most [`Limits::max_in`] bytes each; a longer one ends the connection) and queues them;
//! one worker answers them in order, one at a time, and is the only writer. Tool calls run on their own task, so a
//! panic in a tool is a `-32603` answer and the connection goes on.

use std::collections::HashMap;
use std::io::ErrorKind;
use std::sync::Arc;

use runstav::jsonrpc::{
    self, ErrorObject, INTERNAL_ERROR, INVALID_PARAMS, INVALID_REQUEST, METHOD_NOT_FOUND, Message,
    PARSE_ERROR, UNSUPPORTED_PROTOCOL_VERSION,
};
use serde_json::{Map, Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use crate::jsonrpc_glue as glue;
use crate::tool::{Tool, ToolResult, valid_name};
use crate::version;

/// This crate's version, `serverInfo.version` by default.
pub const CRATE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// The `_meta` key of an argument error in a tool result (design §4.6 item 7).
pub const ERROR_META: &str = "dev.drgnx/error";

/// How long a client may cache `server/discover` and `tools/list` (2026-07-28), in milliseconds.
pub const TTL_MS: u64 = 3_600_000;

/// Lines read but not yet answered; the reader waits when the worker is this far behind.
const QUEUE: usize = 64;

/// `serverInfo`. The name stays `drgnx`, so tool names (`mcp__drgnx__…`) and permission rules do not change
/// (design §5.8).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerInfo {
    pub name: String,
    pub version: String,
}

impl Default for ServerInfo {
    fn default() -> Self {
        ServerInfo {
            name: "drgnx".into(),
            version: CRATE_VERSION.into(),
        }
    }
}

/// The longest line read (a longer one ends the connection) and written (a longer answer becomes `-32603`), in
/// bytes without the newline.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    pub max_in: usize,
    pub max_out: usize,
}

impl Default for Limits {
    /// 1 MiB in, 16 MiB out (the hub's line limits).
    fn default() -> Self {
        Limits {
            max_in: runstav::line::MAX_CLIENT_LINE,
            max_out: runstav::line::MAX_HUB_LINE,
        }
    }
}

/// Why a connection ended. Every line read before the end has been answered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum End {
    ClientClosed,
    LineTooLong,
    Io(ErrorKind),
}

/// Serve one connection until the client closes it, sends a line over `limits.max_in`, or reading or writing fails.
pub async fn serve<Ctx, R, W>(
    ctx: Arc<Ctx>,
    tools: Arc<[Box<dyn Tool<Ctx>>]>,
    info: ServerInfo,
    r: R,
    w: W,
    limits: Limits,
) -> End
where
    Ctx: Send + Sync + 'static,
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let conn = Conn::new(ctx, tools, info);
    let (tx, rx) = mpsc::channel(QUEUE);
    let reader = read_lines(BufReader::new(r), tx, limits.max_in);
    let worker = conn.work(rx, w, limits.max_out);
    tokio::pin!(reader);
    tokio::pin!(worker);
    let first = tokio::select! {
        end = &mut reader => First::Read(end),
        done = &mut worker => First::Work(done),
    };
    match first {
        // the reader dropped its sender: the worker answers what is queued, then ends
        First::Read(end) => match worker.await {
            Ok(()) => end,
            Err(kind) => End::Io(kind),
        },
        First::Work(Err(kind)) => End::Io(kind),
        // only after the reader dropped its sender, so it is done too
        First::Work(Ok(())) => reader.await,
    }
}

enum First {
    Read(End),
    Work(Result<(), ErrorKind>),
}

/// Read lines into TX until the end; `None` is a line that is not UTF-8. A `\r` before the newline is dropped, and
/// blank lines are skipped.
async fn read_lines<R: AsyncBufRead + Unpin>(
    mut r: R,
    tx: mpsc::Sender<Option<String>>,
    max: usize,
) -> End {
    let mut buf = Vec::new();
    loop {
        buf.clear();
        match read_line(&mut r, &mut buf, max).await {
            Ok(true) => {}
            Ok(false) => return End::ClientClosed,
            Err(end) => return end,
        }
        if buf.last() == Some(&b'\r') {
            buf.pop();
        }
        if buf.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let line = String::from_utf8(std::mem::take(&mut buf)).ok();
        if tx.send(line).await.is_err() {
            // the worker ended (a write failed); `serve` reports its error
            return End::ClientClosed;
        }
    }
}

/// One line into BUF, without its newline: `Ok(false)` at the end of input with nothing read. Never holds more
/// than MAX bytes of a line.
async fn read_line<R: AsyncBufRead + Unpin>(
    r: &mut R,
    buf: &mut Vec<u8>,
    max: usize,
) -> Result<bool, End> {
    loop {
        let avail = r.fill_buf().await.map_err(|e| End::Io(e.kind()))?;
        if avail.is_empty() {
            return Ok(!buf.is_empty());
        }
        let (take, newline) = match avail.iter().position(|b| *b == b'\n') {
            Some(i) => (i, true),
            None => (avail.len(), false),
        };
        if buf.len() + take > max {
            return Err(End::LineTooLong);
        }
        buf.extend_from_slice(&avail[..take]);
        r.consume(take + usize::from(newline));
        if newline {
            return Ok(true);
        }
    }
}

/// One connection's state: the tools, and whether `initialize` chose the legacy era.
struct Conn<Ctx> {
    ctx: Arc<Ctx>,
    tools: Arc<[Box<dyn Tool<Ctx>>]>,
    by_name: HashMap<&'static str, usize>,
    /// `tools/list`'s `tools`, in name order (deterministic, storage §6).
    listing: Value,
    info: ServerInfo,
    legacy: bool,
}

impl<Ctx: Send + Sync + 'static> Conn<Ctx> {
    fn new(ctx: Arc<Ctx>, tools: Arc<[Box<dyn Tool<Ctx>>]>, info: ServerInfo) -> Self {
        let mut order: Vec<usize> = (0..tools.len()).collect();
        order.sort_by_key(|&i| tools[i].name());
        let mut by_name = HashMap::new();
        let mut listing = Vec::new();
        for i in order {
            let t = &tools[i];
            debug_assert!(valid_name(t.name()), "bad tool name {:?}", t.name());
            let twice = by_name.insert(t.name(), i);
            debug_assert!(twice.is_none(), "two tools named {}", t.name());
            let mut entry = json!({
                "name": t.name(),
                "description": t.description(),
                "inputSchema": t.input_schema(),
            });
            if let Some(out) = t.output_schema() {
                entry["outputSchema"] = out;
            }
            listing.push(entry);
        }
        Conn {
            ctx,
            tools,
            by_name,
            listing: Value::Array(listing),
            info,
            legacy: false,
        }
    }

    /// Answer every queued line in order, writing each answer before reading the next line.
    async fn work<W: AsyncWrite + Unpin>(
        mut self,
        mut rx: mpsc::Receiver<Option<String>>,
        mut w: W,
        max_out: usize,
    ) -> Result<(), ErrorKind> {
        while let Some(line) = rx.recv().await {
            let Some(answer) = self.answer(line).await else {
                continue;
            };
            let mut text = answer.to_string();
            if text.len() > max_out {
                text = json!({
                    "jsonrpc": "2.0",
                    "id": answer["id"],
                    "error": ErrorObject::new(INTERNAL_ERROR, "the answer is too long"),
                })
                .to_string();
            }
            text.push('\n');
            w.write_all(text.as_bytes()).await.map_err(|e| e.kind())?;
            w.flush().await.map_err(|e| e.kind())?;
        }
        Ok(())
    }

    /// The answer to one line; `None` for a notification, or a result or error (this server sends no requests).
    async fn answer(&mut self, line: Option<String>) -> Option<Value> {
        let Some(line) = line else {
            let e = ErrorObject::new(PARSE_ERROR, "invalid JSON (not UTF-8)");
            return Some(glue::error(None, &e));
        };
        match jsonrpc::parse(&line) {
            Err(e) => {
                let id = if e.code == PARSE_ERROR {
                    None
                } else {
                    glue::lenient_id(&line)
                };
                Some(glue::error(id.as_ref(), &e))
            }
            Ok(Message::Request { id, method, params }) => {
                Some(match self.request(&method, params).await {
                    Ok(result) => glue::result(&id, result),
                    Err(e) => glue::error(Some(&id), &e),
                })
            }
            Ok(Message::Notification { .. } | Message::Result { .. } | Message::Error { .. }) => {
                None
            }
        }
    }

    /// One request. A request that carries `params._meta["io.modelcontextprotocol/protocolVersion"]` is decided by
    /// the stateless rules, unless `initialize` chose the legacy era for this connection (review m7); `initialize`
    /// itself always chooses it.
    async fn request(&mut self, method: &str, params: Option<Value>) -> Result<Value, ErrorObject> {
        let version = params
            .as_ref()
            .and_then(|p| p.get("_meta"))
            .and_then(|m| m.get(version::META_PROTOCOL_VERSION))
            .cloned();
        if method != "initialize"
            && !self.legacy
            && let Some(version) = version
        {
            return self.modern(method, params, version).await;
        }
        match method {
            "initialize" => self.initialize(params.as_ref()),
            "ping" => Ok(json!({})),
            "server/discover" => Ok(self.discover()),
            // an error, never silence: a client's discovery probe falls back only after an error or a timeout
            _ if !self.legacy => Err(ErrorObject::new(INVALID_REQUEST, "initialize first")),
            "tools/list" => Ok(json!({"tools": self.listing})),
            "tools/call" => self.call(params.as_ref()).await,
            _ => Err(method_not_found(method)),
        }
    }

    fn initialize(&mut self, params: Option<&Value>) -> Result<Value, ErrorObject> {
        let requested = params
            .and_then(|p| p.get("protocolVersion"))
            .and_then(Value::as_str)
            .ok_or_else(|| {
                ErrorObject::new(INVALID_PARAMS, "initialize needs params.protocolVersion")
            })?;
        self.legacy = true;
        Ok(json!({
            "protocolVersion": version::negotiate(requested),
            "capabilities": {"tools": {"listChanged": false}},
            "serverInfo": {"name": self.info.name, "version": self.info.version},
        }))
    }

    /// A stateless (2026-07-28) request: its version must be served and its client capabilities present, and its
    /// result carries `resultType`.
    async fn modern(
        &mut self,
        method: &str,
        params: Option<Value>,
        version: Value,
    ) -> Result<Value, ErrorObject> {
        if !version.as_str().is_some_and(version::is_modern) {
            return Err(ErrorObject {
                code: UNSUPPORTED_PROTOCOL_VERSION,
                message: "unsupported protocol version".into(),
                data: Some(json!({"supported": version::supported(), "requested": version})),
            });
        }
        let capabilities = params
            .as_ref()
            .and_then(|p| p.get("_meta"))
            .and_then(|m| m.get(version::META_CLIENT_CAPABILITIES));
        if !capabilities.is_some_and(Value::is_object) {
            return Err(ErrorObject::new(
                INVALID_PARAMS,
                format!("params._meta needs {}", version::META_CLIENT_CAPABILITIES),
            ));
        }
        let mut result = match method {
            "server/discover" => self.discover(),
            "ping" => json!({}),
            "tools/list" => json!({"tools": self.listing, "ttlMs": TTL_MS, "cacheScope": "public"}),
            "tools/call" => self.call(params.as_ref()).await?,
            _ => return Err(method_not_found(method)),
        };
        if let Value::Object(m) = &mut result {
            m.insert("resultType".into(), "complete".into());
        }
        Ok(result)
    }

    /// `server/discover` (2026-07-28).
    fn discover(&self) -> Value {
        json!({
            "resultType": "complete",
            "supportedVersions": version::MODERN,
            "capabilities": {"tools": {}},
            "_meta": {(version::META_SERVER_INFO): {"name": self.info.name, "version": self.info.version}},
            "ttlMs": TTL_MS,
            "cacheScope": "public",
        })
    }

    /// `tools/call` (design §4.6 item 7): params that are not a CallToolRequest and an unknown tool are `-32602`;
    /// arguments that fail the tool's check are a tool error with their path, and the tool never runs.
    async fn call(&self, params: Option<&Value>) -> Result<Value, ErrorObject> {
        let bad = || {
            ErrorObject::new(
                INVALID_PARAMS,
                "tools/call needs params {name: string, arguments?: object}",
            )
        };
        let p = params.and_then(Value::as_object).ok_or_else(bad)?;
        let name = p.get("name").and_then(Value::as_str).ok_or_else(bad)?;
        let args = match p.get("arguments") {
            None | Some(Value::Null) => Value::Object(Map::new()),
            Some(a @ Value::Object(_)) => a.clone(),
            Some(_) => return Err(bad()),
        };
        let Some(&i) = self.by_name.get(name) else {
            return Err(ErrorObject::new(
                INVALID_PARAMS,
                format!("Unknown tool: {name}"),
            ));
        };
        let tool = &self.tools[i];
        if let Err(e) = tool.check(&args) {
            return Ok(json!({
                "content": [{"type": "text", "text": e.to_string()}],
                "isError": true,
                "_meta": {(ERROR_META): {"code": "invalid-arguments", "path": e.path}},
            }));
        }
        let structured_allowed = tool.output_schema().is_some();
        let (ctx, tools) = (self.ctx.clone(), self.tools.clone());
        let run = tokio::spawn(async move { tools[i].call(&*ctx, args).await });
        match run.await {
            Ok(ToolResult::Ok { text, structured }) => {
                let mut result = json!({"content": [{"type": "text", "text": text}]});
                if structured_allowed && let Some(s) = structured {
                    result["structuredContent"] = s;
                }
                Ok(result)
            }
            Ok(ToolResult::Err(text)) => Ok(json!({
                "content": [{"type": "text", "text": text}],
                "isError": true,
            })),
            Err(e) => {
                tracing::error!(tool = name, error = %e, "an MCP tool failed");
                Err(ErrorObject::new(
                    INTERNAL_ERROR,
                    format!("the tool {name} failed"),
                ))
            }
        }
    }
}

fn method_not_found(method: &str) -> ErrorObject {
    ErrorObject::new(METHOD_NOT_FOUND, format!("no method {method}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tool::{ArgsError, BoxFuture, typed};
    use schemars::JsonSchema;
    use serde::Deserialize;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::AsyncReadExt;

    #[derive(Default)]
    struct Calls(AtomicUsize);

    #[derive(Deserialize, JsonSchema)]
    struct EchoArgs {
        text: String,
    }

    #[derive(Deserialize, JsonSchema)]
    struct NoArgs {}

    struct Echo;
    struct Fail;
    struct Noargs;
    struct Boom;

    impl Tool<Calls> for Echo {
        fn name(&self) -> &'static str {
            "echo"
        }
        fn description(&self) -> &'static str {
            "Say TEXT back."
        }
        fn input_schema(&self) -> Value {
            typed::<EchoArgs>().schema()
        }
        fn output_schema(&self) -> Option<Value> {
            Some(json!({"type": "object", "properties": {"text": {"type": "string"}}}))
        }
        fn check(&self, args: &Value) -> Result<(), ArgsError> {
            typed::<EchoArgs>().check(args)
        }
        fn call<'a>(&'a self, ctx: &'a Calls, args: Value) -> BoxFuture<'a, ToolResult> {
            Box::pin(async move {
                ctx.0.fetch_add(1, Ordering::SeqCst);
                match typed::<EchoArgs>().decode(&args) {
                    Ok(a) => ToolResult::Ok {
                        structured: Some(json!({"text": a.text.clone()})),
                        text: a.text,
                    },
                    Err(e) => ToolResult::Err(e.to_string()),
                }
            })
        }
    }

    impl Tool<Calls> for Fail {
        fn name(&self) -> &'static str {
            "fail"
        }
        fn description(&self) -> &'static str {
            "Always fails."
        }
        fn input_schema(&self) -> Value {
            typed::<NoArgs>().schema()
        }
        fn check(&self, args: &Value) -> Result<(), ArgsError> {
            typed::<NoArgs>().check(args)
        }
        fn call<'a>(&'a self, _: &'a Calls, _: Value) -> BoxFuture<'a, ToolResult> {
            Box::pin(async { ToolResult::Err("it failed".into()) })
        }
    }

    impl Tool<Calls> for Noargs {
        fn name(&self) -> &'static str {
            "noargs"
        }
        fn description(&self) -> &'static str {
            "Takes nothing."
        }
        fn input_schema(&self) -> Value {
            typed::<NoArgs>().schema()
        }
        fn check(&self, args: &Value) -> Result<(), ArgsError> {
            typed::<NoArgs>().check(args)
        }
        fn call<'a>(&'a self, _: &'a Calls, _: Value) -> BoxFuture<'a, ToolResult> {
            Box::pin(async {
                ToolResult::Ok {
                    text: "ok".into(),
                    structured: Some(json!({"dropped": true})),
                }
            })
        }
    }

    impl Tool<Calls> for Boom {
        fn name(&self) -> &'static str {
            "boom"
        }
        fn description(&self) -> &'static str {
            "Panics."
        }
        fn input_schema(&self) -> Value {
            typed::<NoArgs>().schema()
        }
        fn call<'a>(&'a self, _: &'a Calls, args: Value) -> BoxFuture<'a, ToolResult> {
            Box::pin(async move {
                if args.is_object() {
                    panic!("boom");
                }
                ToolResult::Err(String::new())
            })
        }
    }

    fn tools() -> Arc<[Box<dyn Tool<Calls>>]> {
        // not in name order: tools/list sorts
        let all: Vec<Box<dyn Tool<Calls>>> = vec![
            Box::new(Noargs),
            Box::new(Echo),
            Box::new(Fail),
            Box::new(Boom),
        ];
        Arc::from(all)
    }

    fn req(id: i64, method: &str, params: Value) -> String {
        json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}).to_string()
    }

    fn init(version: &str) -> String {
        req(
            0,
            "initialize",
            json!({"protocolVersion": version, "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}),
        )
    }

    fn meta() -> Value {
        json!({
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": {},
        })
    }

    fn call(id: i64, name: &str, args: Value) -> String {
        req(id, "tools/call", json!({"name": name, "arguments": args}))
    }

    /// Send LINES, close the client's side, and read every answer until the server ends.
    async fn session_with(lines: &[String], limits: Limits) -> (Vec<Value>, End, Arc<Calls>) {
        let (client, server) = tokio::io::duplex(1 << 16);
        let (sr, sw) = tokio::io::split(server);
        let (mut cr, mut cw) = tokio::io::split(client);
        let ctx = Arc::new(Calls::default());
        let mut input = lines.join("\n");
        input.push('\n');
        let serving = serve(ctx.clone(), tools(), ServerInfo::default(), sr, sw, limits);
        let feeding = async move {
            // the server may end first (a line too long): the write then fails
            let _ = cw.write_all(input.as_bytes()).await;
            let _ = cw.shutdown().await;
        };
        let reading = async move {
            let mut out = String::new();
            cr.read_to_string(&mut out)
                .await
                .expect("answers are UTF-8");
            out
        };
        let (end, (), out) = tokio::join!(serving, feeding, reading);
        let answers = out
            .lines()
            .map(|l| serde_json::from_str(l).expect("each answer is JSON"))
            .collect();
        (answers, end, ctx)
    }

    async fn session(lines: &[String]) -> Vec<Value> {
        let (answers, end, _) = session_with(lines, Limits::default()).await;
        assert_eq!(end, End::ClientClosed);
        answers
    }

    fn calls(ctx: &Calls) -> usize {
        ctx.0.load(Ordering::SeqCst)
    }

    #[tokio::test]
    async fn legacy_handshake_echoes_a_known_version_else_the_latest() {
        let a = session(&[init("2025-06-18")]).await;
        assert_eq!(
            a[0],
            json!({"jsonrpc": "2.0", "id": 0, "result": {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": "drgnx", "version": CRATE_VERSION},
            }})
        );
        let a = session(&[init("2099-01-01")]).await;
        assert_eq!(a[0]["result"]["protocolVersion"], "2025-11-25");
        let a = session(&[req(1, "initialize", json!({}))]).await;
        assert_eq!(a[0]["error"]["code"], INVALID_PARAMS);
    }

    #[tokio::test]
    async fn a_request_before_initialize_is_an_error_not_silence() {
        let a = session(&[
            req(1, "tools/list", json!({})),
            req(2, "ping", json!({})),
            call(3, "echo", json!({"text": "x"})),
        ])
        .await;
        assert_eq!(a.len(), 3);
        assert_eq!(
            a[0],
            json!({"jsonrpc": "2.0", "id": 1, "error": {"code": -32600, "message": "initialize first"}})
        );
        assert_eq!(a[1], json!({"jsonrpc": "2.0", "id": 2, "result": {}}));
        assert_eq!(a[2]["error"]["code"], INVALID_REQUEST);
    }

    #[tokio::test]
    async fn a_modern_request_needs_no_initialize() {
        let a = session(&[req(1, "tools/list", json!({"_meta": meta()}))]).await;
        let r = &a[0]["result"];
        assert_eq!(r["tools"].as_array().map(Vec::len), Some(4));
        assert_eq!(r["resultType"], "complete");
        assert_eq!(r["ttlMs"], TTL_MS);
        assert_eq!(r["cacheScope"], "public");
    }

    #[tokio::test]
    async fn modern_requests_are_stateless_and_carry_result_type() {
        let a = session(&[
            req(1, "server/discover", json!({"_meta": meta()})),
            req(
                2,
                "tools/call",
                json!({"name": "echo", "arguments": {"text": "hi"}, "_meta": meta()}),
            ),
            req(3, "ping", json!({"_meta": meta()})),
            // no handshake happened: a request without the version is still refused
            req(4, "tools/list", json!({})),
            req(5, "resources/list", json!({"_meta": meta()})),
        ])
        .await;
        assert_eq!(
            a[0]["result"],
            json!({
                "resultType": "complete",
                "supportedVersions": ["2026-07-28"],
                "capabilities": {"tools": {}},
                "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "drgnx", "version": CRATE_VERSION}},
                "ttlMs": 3_600_000,
                "cacheScope": "public",
            })
        );
        assert_eq!(a[1]["result"]["resultType"], "complete", "{}", a[1]);
        assert_eq!(a[1]["result"]["content"][0]["text"], "hi");
        assert_eq!(a[2]["result"], json!({"resultType": "complete"}));
        assert_eq!(a[3]["error"]["message"], "initialize first");
        assert_eq!(a[4]["error"]["code"], METHOD_NOT_FOUND);
        // after initialize the connection is legacy: no resultType, even with the modern _meta
        let a = session(&[
            init("2025-11-25"),
            req(1, "tools/list", json!({"_meta": meta()})),
        ])
        .await;
        assert!(a[1]["result"].get("resultType").is_none(), "{}", a[1]);
        assert!(a[1]["result"].get("ttlMs").is_none());
    }

    #[tokio::test]
    async fn unknown_version_is_32022_with_supported() {
        let mut m = meta();
        m["io.modelcontextprotocol/protocolVersion"] = json!("2099-01-01");
        let a = session(&[req(7, "server/discover", json!({"_meta": m}))]).await;
        assert_eq!(
            a[0],
            json!({"jsonrpc": "2.0", "id": 7, "error": {
                "code": -32022,
                "message": "unsupported protocol version",
                "data": {"supported": ["2026-07-28", "2025-11-25"], "requested": "2099-01-01"},
            }})
        );
    }

    #[tokio::test]
    async fn missing_client_capabilities_is_32602() {
        let m = json!({"io.modelcontextprotocol/protocolVersion": "2026-07-28"});
        let a = session(&[req(1, "tools/list", json!({"_meta": m}))]).await;
        assert_eq!(a[0]["error"]["code"], INVALID_PARAMS);
        assert_eq!(
            a[0]["error"]["message"],
            "params._meta needs io.modelcontextprotocol/clientCapabilities"
        );
    }

    #[tokio::test]
    async fn a_bad_argument_is_a_tool_error_with_its_path() {
        let (a, end, ctx) = session_with(
            &[
                init("2025-11-25"),
                call(1, "echo", json!({"text": 3})),
                call(2, "echo", json!({"text": "a", "extra": 1})),
                call(3, "echo", json!({})),
                call(4, "noargs", json!({"agent": "me"})),
            ],
            Limits::default(),
        )
        .await;
        assert_eq!(end, End::ClientClosed);
        let expect = [
            ("text", "text: invalid type: integer `3`, expected a string"),
            ("extra", "extra: unknown key"),
            ("text", "text: required, missing"),
            ("agent", "agent: unknown key"),
        ];
        for (answer, (path, text)) in a[1..].iter().zip(expect) {
            assert_eq!(
                answer["result"],
                json!({
                    "content": [{"type": "text", "text": text}],
                    "isError": true,
                    "_meta": {"dev.drgnx/error": {"code": "invalid-arguments", "path": path}},
                }),
                "{answer}"
            );
        }
        assert_eq!(calls(&ctx), 0, "the tool never ran");
        // the same in the stateless era
        let (a, _, ctx) = session_with(
            &[req(
                1,
                "tools/call",
                json!({"name": "echo", "arguments": {"text": 3}, "_meta": meta()}),
            )],
            Limits::default(),
        )
        .await;
        assert_eq!(a[0]["result"]["isError"], true);
        assert_eq!(a[0]["result"]["_meta"]["dev.drgnx/error"]["path"], "text");
        assert_eq!(calls(&ctx), 0);
    }

    #[tokio::test]
    async fn tool_results_and_tool_errors() {
        let (a, _, ctx) = session_with(
            &[
                init("2025-11-25"),
                call(1, "echo", json!({"text": "hi"})),
                call(2, "fail", json!({})),
                req(3, "tools/call", json!({"name": "noargs"})),
            ],
            Limits::default(),
        )
        .await;
        assert_eq!(
            a[1]["result"],
            json!({"content": [{"type": "text", "text": "hi"}], "structuredContent": {"text": "hi"}})
        );
        assert_eq!(
            a[2]["result"],
            json!({"content": [{"type": "text", "text": "it failed"}], "isError": true})
        );
        // no outputSchema, so no structuredContent
        assert_eq!(
            a[3]["result"],
            json!({"content": [{"type": "text", "text": "ok"}]})
        );
        assert_eq!(calls(&ctx), 1);
    }

    #[tokio::test]
    async fn an_unknown_tool_is_32602() {
        let a = session(&[
            init("2025-11-25"),
            call(1, "nope", json!({})),
            req(2, "tools/call", json!({"arguments": {}})),
            req(3, "tools/call", json!({"name": "echo", "arguments": [1]})),
        ])
        .await;
        assert_eq!(
            a[1],
            json!({"jsonrpc": "2.0", "id": 1, "error": {"code": -32602, "message": "Unknown tool: nope"}})
        );
        assert_eq!(a[2]["error"]["code"], INVALID_PARAMS);
        assert_eq!(a[3]["error"]["code"], INVALID_PARAMS);
    }

    #[tokio::test]
    async fn an_unknown_method_is_32601() {
        let a = session(&[init("2025-11-25"), req(1, "resources/list", json!({}))]).await;
        assert_eq!(a[1]["error"]["code"], METHOD_NOT_FOUND);
        assert_eq!(a[1]["id"], 1);
    }

    #[tokio::test]
    async fn a_parse_error_is_32700_with_null_id() {
        let a = session(&["{\"id\": 4, nope".to_string()]).await;
        assert_eq!(
            a[0],
            json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "invalid JSON"}})
        );
    }

    #[tokio::test]
    async fn a_batch_is_32600() {
        let a = session(&[r#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#.to_string()]).await;
        assert_eq!(
            a[0],
            json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32600, "message": "batches are not supported"}})
        );
        // an invalid request whose id can be read is answered on it
        let a = session(&[r#"{"jsonrpc":"1.0","id":9,"method":"ping"}"#.to_string()]).await;
        assert_eq!(
            (a[0]["id"].clone(), a[0]["error"]["code"].clone()),
            (json!(9), json!(-32600))
        );
    }

    #[tokio::test]
    async fn input_schema_is_the_types() {
        let a = session(&[init("2025-11-25"), req(1, "tools/list", json!({}))]).await;
        let echo = &a[1]["result"]["tools"][1];
        assert_eq!(echo["name"], "echo");
        assert_eq!(echo["description"], "Say TEXT back.");
        assert_eq!(echo["inputSchema"], typed::<EchoArgs>().schema());
        assert_eq!(
            echo["inputSchema"],
            json!({
                "type": "object",
                "properties": {"text": {"type": "string"}},
                "required": ["text"],
                "additionalProperties": false,
            })
        );
        assert_eq!(echo["outputSchema"]["type"], "object");
        assert!(a[1]["result"]["tools"][2].get("outputSchema").is_none());
    }

    #[tokio::test]
    async fn tools_list_is_sorted_and_stable() {
        let lines = [
            init("2025-11-25"),
            req(1, "tools/list", json!({})),
            req(2, "tools/list", json!({})),
        ];
        let a = session(&lines).await;
        let names: Vec<&str> = a[1]["result"]["tools"]
            .as_array()
            .expect("tools")
            .iter()
            .filter_map(|t| t["name"].as_str())
            .collect();
        assert_eq!(names, ["boom", "echo", "fail", "noargs"]);
        assert_eq!(a[1]["result"], a[2]["result"]);
        assert_eq!(session(&lines).await[1], a[1]);
    }

    #[tokio::test]
    async fn noargs_schema_is_closed() {
        let a = session(&[init("2025-11-25"), req(1, "tools/list", json!({}))]).await;
        assert_eq!(
            a[1]["result"]["tools"][3]["inputSchema"],
            json!({"type": "object", "additionalProperties": false})
        );
    }

    #[tokio::test]
    async fn a_line_over_1_mib_ends_the_connection() {
        let mib = 1 << 20;
        // exactly 1 MiB is still a line
        let mut fits = req(1, "ping", json!({}));
        fits.push_str(&" ".repeat(mib - fits.len()));
        let (a, end, _) = session_with(
            &[
                init("2025-11-25"),
                fits,
                "x".repeat(mib + 1),
                req(2, "ping", json!({})),
            ],
            Limits::default(),
        )
        .await;
        assert_eq!(end, End::LineTooLong);
        assert_eq!(a.len(), 2, "answered up to the long line, nothing after");
        assert_eq!(a[1], json!({"jsonrpc": "2.0", "id": 1, "result": {}}));
    }

    #[tokio::test]
    async fn a_panicking_tool_is_32603_and_the_connection_goes_on() {
        let a = session(&[
            init("2025-11-25"),
            call(1, "boom", json!({})),
            req(2, "ping", json!({})),
        ])
        .await;
        assert_eq!(a[1]["error"]["code"], INTERNAL_ERROR);
        assert_eq!(a[1]["id"], 1);
        assert_eq!(a[2]["result"], json!({}));
    }

    #[tokio::test]
    async fn notifications_get_no_answer_and_answers_keep_request_order() {
        let a = session(&[
            init("2025-11-25"),
            json!({"jsonrpc": "2.0", "method": "notifications/initialized"}).to_string(),
            json!({"jsonrpc": "2.0", "method": "notifications/whatever", "params": {}}).to_string(),
            json!({"jsonrpc": "2.0", "id": 99, "result": {}}).to_string(),
            String::new(),
            call(5, "echo", json!({"text": "a"})),
            req(3, "ping", json!({})),
            call(4, "echo", json!({"text": "b"})),
        ])
        .await;
        let ids: Vec<i64> = a.iter().filter_map(|x| x["id"].as_i64()).collect();
        assert_eq!(ids, [0i64, 5, 3, 4]);
    }

    #[tokio::test]
    async fn an_answer_over_the_limit_is_32603() {
        let big = "y".repeat(200);
        let (a, end, _) = session_with(
            &[init("2025-11-25"), call(1, "echo", json!({"text": big}))],
            Limits {
                max_in: 1 << 20,
                max_out: 300,
            },
        )
        .await;
        assert_eq!(end, End::ClientClosed);
        assert_eq!(a[1]["id"], 1);
        assert_eq!(a[1]["error"]["code"], INTERNAL_ERROR);
    }
}
