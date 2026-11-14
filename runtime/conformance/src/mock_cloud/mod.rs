//! `ratatoskr-mock cloud`: an EC2 (Query, XML) and GCE (REST, JSON) subset on one listener, the instance clocks, and
//! the knobs that inject every failure the cloud code drills.
//!
//! `cloud --listen ADDR --podman-remote SOCK|none --prefix P --run R [--hub ID] [--image IMG] [--network NET]
//! [--podman PATH] [--metadata-url URL] [--run-opt OPT]... [--log FILE] [--parent PID]` prints `MOCK-CLOUD-PORT N`
//! and serves:
//!
//! - EC2 `POST /` (form body, `Action=`), STS `GetCallerIdentity` and the Pricing `GetProducts` on the same path;
//! - GCE `/compute/v1/projects/…`, Resource Manager `/v1/projects/P:testIamPermissions`, Billing `/v1/services/…/skus`;
//! - the instance metadata, `/__metadata/<instance>/…` (IMDSv2 and GCE's metadata server);
//! - the knobs, `POST /__mock/<name>` (src/mock_cloud/knobs below), and `GET /__mock/resources`.
//!
//! The clock is virtual: it starts at 2026-11-06T00:00:00Z and moves only through `POST /__mock/clock`, so boot
//! delays, spot notices and `terminationTime` deadlines need no sleeping. A request the mock does not implement
//! answers 501, is printed on stderr and is listed under `unknown_requests` of `/__mock/resources`.
//!
//! With `--hub ID` the mock models the fixture policy (tag conditions, explicit denies); without it every call is
//! allowed. `--podman-remote SOCK` makes each instance a container `<P>-cloud-<id>` labelled `drgnx.fleet=<R>`, its
//! console that container's `/run/fleet-console` and its `dnsName` the container's name; with `--metadata-url URL` (the mock as the
//! containers reach it) each gets `DRGNX_FAKE_CLOUD_METADATA=URL/__metadata/<id>`, where the fake runner's stand-in for
//! cloud-init reads its user-data, and each `--run-opt` added to its `podman run` (one argument each, `--volume=…` with
//! a source on the podman host), so it has what the fleet's runners have. `none` keeps instances in memory only, with a console made up as cloud-init's. It
//! never touches a container whose name lacks that prefix.

mod ec2;
mod gce;
mod instances;
mod metadata;

use instances::{Instance, Podman, St};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap};
use std::fs::File;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};

pub(crate) struct Req {
    pub method: String,
    pub path: String,
    pub query: Vec<(String, String)>,
    /// Lower-case names.
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Req {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
    pub fn q(&self, name: &str) -> Option<&str> {
        self.query
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
    pub fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or(Value::Null)
    }
    pub fn form(&self) -> Params {
        Params(parse_query(&self.text()))
    }
}

pub(crate) struct Resp {
    pub status: u16,
    pub content_type: &'static str,
    pub body: String,
}

/// What a handler decides for the connection.
pub(crate) enum Out {
    Reply(Resp),
    /// Never answer; hold the connection until the client hangs up.
    Hang,
    /// Close at once, as a packet that crossed a hop and was dropped.
    Drop,
}

impl Out {
    pub fn json(status: u16, v: Value) -> Out {
        Out::Reply(Resp {
            status,
            content_type: "application/json",
            body: v.to_string(),
        })
    }
    pub fn xml(status: u16, body: String) -> Out {
        Out::Reply(Resp {
            status,
            content_type: "text/xml",
            body,
        })
    }
    pub fn text(status: u16, body: &str) -> Out {
        Out::Reply(Resp {
            status,
            content_type: "text/plain",
            body: body.to_string(),
        })
    }
}

#[derive(Clone, Copy, PartialEq)]
pub(crate) enum Api {
    Ec2,
    Gce,
    /// Pricing and the other AWS JSON APIs.
    AwsJson,
}

/// An API error in the provider's own format.
pub(crate) fn error(api: Api, status: u16, code: &str, msg: &str) -> Out {
    match api {
        Api::Ec2 => Out::xml(
            status,
            format!(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Response><Errors><Error><Code>{code}</Code><Message>{}</Message></Error></Errors><RequestID>mock-request</RequestID></Response>",
                esc(msg)
            ),
        ),
        Api::Gce => Out::json(
            status,
            json!({"error": {"code": status, "message": msg, "errors": [{"reason": code, "message": msg}], "status": code}}),
        ),
        Api::AwsJson => Out::json(status, json!({"__type": code, "message": msg})),
    }
}

pub(crate) fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Form or query parameters in order, with EC2's `Name.N.Sub` list syntax helpers.
pub(crate) struct Params(pub Vec<(String, String)>);

impl Params {
    pub fn get(&self, k: &str) -> Option<&str> {
        self.0.iter().find(|(a, _)| a == k).map(|(_, v)| v.as_str())
    }
    pub fn flag(&self, k: &str) -> bool {
        self.get(k) == Some("true")
    }
    /// `Prefix.1`, `Prefix.2`, … in index order.
    pub fn list(&self, prefix: &str) -> Vec<String> {
        let mut v: Vec<(u32, String)> = self
            .0
            .iter()
            .filter_map(|(k, val)| {
                let n = k.strip_prefix(prefix)?.strip_prefix('.')?;
                Some((n.parse().ok()?, val.clone()))
            })
            .collect();
        v.sort();
        v.into_iter().map(|(_, s)| s).collect()
    }
    /// The indices `Prefix.N` has any key under.
    pub fn indices(&self, prefix: &str) -> Vec<u32> {
        let mut v: Vec<u32> = self
            .0
            .iter()
            .filter_map(|(k, _)| {
                k.strip_prefix(prefix)?
                    .strip_prefix('.')?
                    .split('.')
                    .next()?
                    .parse()
                    .ok()
            })
            .collect();
        v.sort();
        v.dedup();
        v
    }
    /// `TagSpecification.N.ResourceType` with `.Tag.M.Key/Value`: (resource type, tags).
    pub fn tag_specs(&self) -> Vec<(String, BTreeMap<String, String>)> {
        self.indices("TagSpecification")
            .into_iter()
            .map(|n| {
                let p = format!("TagSpecification.{n}");
                let ty = self
                    .get(&format!("{p}.ResourceType"))
                    .unwrap_or("")
                    .to_string();
                let tags = self
                    .indices(&format!("{p}.Tag"))
                    .into_iter()
                    .filter_map(|m| {
                        let k = self.get(&format!("{p}.Tag.{m}.Key"))?;
                        Some((
                            k.to_string(),
                            self.get(&format!("{p}.Tag.{m}.Value"))
                                .unwrap_or("")
                                .to_string(),
                        ))
                    })
                    .collect();
                (ty, tags)
            })
            .collect()
    }
}

pub(crate) fn pct_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() && s.is_char_boundary(i + 3) => {
                match u8::from_str_radix(&s[i + 1..i + 3], 16) {
                    Ok(v) => {
                        out.push(v);
                        i += 2;
                    }
                    Err(_) => out.push(b'%'),
                }
            }
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub(crate) fn parse_query(s: &str) -> Vec<(String, String)> {
    s.split('&')
        .filter(|p| !p.is_empty())
        .map(|p| match p.split_once('=') {
            Some((k, v)) => (pct_decode(k), pct_decode(v)),
            None => (pct_decode(p), String::new()),
        })
        .collect()
}

pub(crate) fn b64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16
            | (*c.get(1).unwrap_or(&0) as u32) << 8
            | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 {
            T[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            T[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// Standard base64 (padding and whitespace skipped); None on any other byte.
pub(crate) fn b64_decode(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let (mut acc, mut bits) = (0u32, 0u32);
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' | b'\n' | b'\r' | b' ' => continue,
            _ => return None,
        };
        acc = (acc << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

/// A failure to inject: the next `times` calls of `op` (`*`: any) get it.
pub(crate) struct Fault {
    pub op: String,
    pub status: u16,
    pub code: String,
    pub message: String,
    pub times: u32,
    pub hang: bool,
    /// GCE reports capacity and quota in the operation, not the HTTP status.
    pub in_operation: bool,
}

pub(crate) enum Gate {
    Pass,
    Out(Out),
    OperationError(String, String),
}

/// A resource that is not an instance: an image, a snapshot, a security group, a firewall.
pub(crate) struct Res {
    pub kind: &'static str,
    pub id: String,
    pub tags: BTreeMap<String, String>,
    pub data: Value,
}

#[derive(Default)]
pub(crate) struct Next {
    pub notice_at: Option<u64>,
    pub stuck_start: bool,
    pub stuck_end: bool,
}

pub(crate) struct State {
    pub hub: Option<String>,
    pub podman: Podman,
    pub now: u64,
    pub seq: u64,
    pub instances: Vec<Instance>,
    pub res: Vec<Res>,
    /// EC2 ClientToken → instance id; GCE requestId → operation.
    pub tokens: HashMap<String, String>,
    pub operations: Vec<Value>,
    pub request_ids: HashMap<String, Value>,
    pub faults: Vec<Fault>,
    pub expired: bool,
    pub accept_token: Option<String>,
    pub boot_delay: u64,
    pub shutdown_mismatch: Option<String>,
    pub no_termination_time: bool,
    pub denied_permissions: Vec<String>,
    pub prices: BTreeMap<String, f64>,
    pub next: Next,
    pub unknown: Vec<String>,
    pub log: Option<Mutex<File>>,
}

pub(crate) const T0: &str = "2026-11-06T00:00:00Z";

impl State {
    fn new(hub: Option<String>, podman: Podman, log: Option<Mutex<File>>) -> State {
        let mut s = State {
            hub,
            podman,
            now: instances::parse_iso(T0).unwrap(),
            seq: 0,
            instances: vec![],
            res: vec![],
            tokens: HashMap::new(),
            operations: vec![],
            request_ids: HashMap::new(),
            faults: vec![],
            expired: false,
            accept_token: None,
            boot_delay: 0,
            shutdown_mismatch: None,
            no_termination_time: false,
            denied_permissions: vec![],
            prices: BTreeMap::new(),
            next: Next::default(),
            unknown: vec![],
            log,
        };
        s.reset_data();
        s
    }

    /// Everything but the clock and the configuration: the seeded base images and the default prices.
    fn reset_data(&mut self) {
        for i in self.instances.drain(..) {
            self.podman.stop(&i);
        }
        self.res.clear();
        self.tokens.clear();
        self.operations.clear();
        self.request_ids.clear();
        self.faults.clear();
        self.expired = false;
        self.accept_token = None;
        self.boot_delay = 0;
        self.shutdown_mismatch = None;
        self.no_termination_time = false;
        self.denied_permissions.clear();
        self.next = Next::default();
        self.res.push(Res {
            kind: "image",
            id: "ami-base0fedora45x86".into(),
            tags: BTreeMap::new(),
            data: json!({"name": "Fedora-Cloud-Base-45", "arch": "x86_64", "snapshot": "snap-base0fedora45x86"}),
        });
        self.res.push(Res {
            kind: "gce-image",
            id: "fedora-coreos-stable-1".into(),
            tags: BTreeMap::new(),
            data: json!({"name": "fedora-coreos-45-stable", "family": "fedora-coreos-stable", "project": "fedora-coreos-cloud"}),
        });
        self.res.push(Res {
            kind: "subnet",
            id: "subnet-0default0000001".into(),
            tags: BTreeMap::new(),
            data: json!({"vpc": "vpc-0default0000001"}),
        });
        self.prices = [
            ("aws/ondemand/m7g.large", 0.0816),
            ("aws/spot/m7g.large", 0.0306),
            ("aws/ondemand/c7g.xlarge", 0.145),
            ("aws/spot/c7g.xlarge", 0.0544),
            ("gcp/ondemand/n2-standard-4", 0.1942),
            ("gcp/spot/n2-standard-4", 0.0582),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
    }

    pub fn next_id(&mut self) -> u64 {
        self.seq += 1;
        self.seq
    }

    pub fn log(&self, v: &Value) {
        crate::log_line(&self.log, v);
    }

    /// Move every instance to where the clock says it is.
    pub fn settle(&mut self) {
        let now = self.now;
        for i in self.instances.iter_mut() {
            match i.state {
                St::Pending if now >= i.ready_at && !i.stuck_start => {
                    i.state = St::Running;
                    self.podman.start(i);
                }
                St::Running => {
                    let deadline = i.termination_at.is_some_and(|t| now >= t);
                    let preempted = i.notice_at.is_some_and(|n| now >= n + i.notice_secs);
                    if deadline || preempted {
                        // a deadline with a STOP action stops it; everything else ends it
                        let keep = deadline && !preempted && i.termination_action == "STOP";
                        i.state = if keep { St::Stopped } else { St::Gone };
                        self.podman.stop(i);
                    }
                }
                St::Ending if now >= i.end_at.unwrap_or(0) && !i.stuck_end => {
                    i.state = St::Gone;
                    self.podman.stop(i);
                }
                _ => {}
            }
        }
    }

    /// Credentials, then the faults for `op`.
    pub fn gate(&mut self, req: &Req, api: Api, op: &str) -> Gate {
        let auth = req.header("authorization");
        let token = match api {
            Api::Gce => auth.and_then(|a| a.strip_prefix("Bearer ")),
            _ => req.header("x-amz-security-token"),
        };
        let bad = auth.is_none()
            || self.expired
            || self
                .accept_token
                .as_deref()
                .is_some_and(|t| token != Some(t));
        if bad {
            let (code, msg) = match (api, self.expired || auth.is_some()) {
                (Api::Gce, _) => (
                    "UNAUTHENTICATED",
                    "Request had invalid authentication credentials.",
                ),
                (_, true) => (
                    "ExpiredToken",
                    "The security token included in the request is expired",
                ),
                _ => (
                    "MissingAuthenticationToken",
                    "Request is missing Authentication Token",
                ),
            };
            return Gate::Out(error(api, 401, code, msg));
        }
        let Some(pos) = self
            .faults
            .iter()
            .position(|f| f.times > 0 && (f.op == "*" || f.op == op))
        else {
            return Gate::Pass;
        };
        let f = &mut self.faults[pos];
        f.times -= 1;
        if f.hang {
            return Gate::Out(Out::Hang);
        }
        if f.in_operation && api == Api::Gce {
            return Gate::OperationError(f.code.clone(), f.message.clone());
        }
        Gate::Out(error(api, f.status, &f.code, &f.message))
    }
}

type Shared = Arc<Mutex<State>>;

fn read_req(s: &mut TcpStream, buf: &mut Vec<u8>) -> Option<Req> {
    let end = loop {
        if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break p;
        }
        let mut chunk = [0u8; 8192];
        let n = s.read(&mut chunk).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    let head = String::from_utf8_lossy(&buf[..end]).into_owned();
    let mut lines = head.split("\r\n");
    let mut first = lines.next()?.split_whitespace();
    let method = first.next()?.to_string();
    let target = first.next()?.to_string();
    let headers: Vec<(String, String)> = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
        .collect();
    let len: usize = headers
        .iter()
        .find(|(k, _)| k == "content-length")
        .and_then(|(_, v)| v.parse().ok())
        .unwrap_or(0);
    let start = end + 4;
    while buf.len() < start + len {
        let mut chunk = [0u8; 8192];
        let n = s.read(&mut chunk).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    let body = buf[start..start + len].to_vec();
    buf.drain(..start + len);
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (pct_decode(p), parse_query(q)),
        None => (pct_decode(&target), vec![]),
    };
    Some(Req {
        method,
        path,
        query,
        headers,
        body,
    })
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        412 => "Precondition Failed",
        501 => "Not Implemented",
        _ => "Status",
    }
}

fn serve(mut s: TcpStream, st: Shared) {
    let mut buf = Vec::new();
    while let Some(req) = read_req(&mut s, &mut buf) {
        let out = handle(&mut st.lock().unwrap(), &req);
        let close = req.header("connection") == Some("close");
        match out {
            Out::Reply(r) => {
                let head = format!(
                    "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\n\r\n",
                    r.status,
                    reason(r.status),
                    r.content_type,
                    r.body.len()
                );
                if s.write_all(head.as_bytes()).is_err() || s.write_all(r.body.as_bytes()).is_err()
                {
                    return;
                }
                if close {
                    return;
                }
            }
            Out::Hang => {
                // answer nothing; end when the client closes
                let mut sink = [0u8; 256];
                while s.read(&mut sink).is_ok_and(|n| n > 0) {}
                return;
            }
            Out::Drop => return,
        }
    }
}

pub(crate) fn unknown(st: &mut State, req: &Req, what: &str) -> Out {
    let line = format!("{} {} ({what})", req.method, req.path);
    eprintln!("ratatoskr-mock cloud: unknown request: {line}");
    st.log(&json!({"unknown": line}));
    st.unknown.push(line.clone());
    Out::json(501, json!({"mock": "unknown request", "request": line}))
}

fn handle(st: &mut State, req: &Req) -> Out {
    st.settle();
    st.log(
        &json!({"request": {"method": req.method, "path": req.path, "query": req.query,
        "action": req.form().get("Action"), "target": req.header("x-amz-target")}}),
    );
    let path = req.path.as_str();
    if let Some(rest) = path.strip_prefix("/__mock/") {
        return knobs(st, req, rest);
    }
    if let Some(rest) = path.strip_prefix("/__metadata/") {
        return metadata::handle(st, req, rest);
    }
    if path == "/" && req.method == "POST" {
        return ec2::handle(st, req);
    }
    if path.starts_with("/compute/v1/") || path.starts_with("/v1/") {
        return gce::handle(st, req);
    }
    unknown(st, req, "no such path")
}

fn ok() -> Out {
    Out::json(200, json!({"ok": true}))
}

/// `times` defaults to 1.
fn times(b: &Value) -> u32 {
    b["times"].as_u64().unwrap_or(1) as u32
}

fn knobs(st: &mut State, req: &Req, name: &str) -> Out {
    if name == "resources" && req.method == "GET" {
        return resources(st);
    }
    if req.method != "POST" {
        return unknown(st, req, "knobs are POST");
    }
    let b = req.json();
    match name {
        "clock" => {
            if let Some(t) = b["set"].as_u64() {
                st.now = t;
            }
            if let Some(d) = b["advance_s"].as_u64() {
                st.now += d;
            }
            st.settle();
            Out::json(200, json!({"now": st.now, "iso": instances::iso(st.now)}))
        }
        "boot-delay" => {
            st.boot_delay = b["seconds"].as_u64().unwrap_or(0);
            ok()
        }
        "capacity" | "quota" => {
            let (aws, gcp) = if name == "capacity" {
                (
                    ("InsufficientInstanceCapacity", 500),
                    "ZONE_RESOURCE_POOL_EXHAUSTED",
                )
            } else {
                (("VcpuLimitExceeded", 400), "QUOTA_EXCEEDED")
            };
            let which = b["provider"].as_str();
            if which != Some("gcp") {
                st.faults.push(Fault {
                    op: "RunInstances".into(),
                    status: aws.1,
                    code: aws.0.into(),
                    message: format!("mock {name}"),
                    times: times(&b),
                    hang: false,
                    in_operation: false,
                });
            }
            if which != Some("aws") {
                st.faults.push(Fault {
                    op: "instances.insert".into(),
                    status: 403,
                    code: gcp.into(),
                    message: format!("mock {name}"),
                    times: times(&b),
                    hang: false,
                    in_operation: true,
                });
            }
            ok()
        }
        "fail" | "timeout" => {
            st.faults.push(Fault {
                op: b["op"].as_str().unwrap_or("*").into(),
                status: b["status"].as_u64().unwrap_or(500) as u16,
                code: b["code"].as_str().unwrap_or("InternalError").into(),
                message: b["message"].as_str().unwrap_or("mock failure").into(),
                times: times(&b),
                hang: name == "timeout",
                in_operation: false,
            });
            ok()
        }
        "spot-notice" | "stuck" => {
            let at = b["at"].as_u64().or(b["in_s"].as_u64().map(|d| st.now + d));
            let on = b["on"].as_str().unwrap_or("start").to_string();
            let apply = |i: &mut Instance| {
                if name == "spot-notice" {
                    i.notice_at = at;
                } else if on == "end" {
                    i.stuck_end = true;
                } else {
                    i.stuck_start = true;
                }
            };
            match b["id"].as_str() {
                Some("next") => {
                    if name == "spot-notice" {
                        st.next.notice_at = at;
                    } else if on == "end" {
                        st.next.stuck_end = true;
                    } else {
                        st.next.stuck_start = true;
                    }
                    ok()
                }
                Some(id) => match st.instances.iter_mut().find(|i| i.id == id || i.name == id) {
                    Some(i) => {
                        apply(i);
                        ok()
                    }
                    None => Out::json(404, json!({"mock": "no such instance", "id": id})),
                },
                None => Out::json(400, json!({"mock": "\"id\" is an instance id or \"next\""})),
            }
        }
        "expire" => {
            st.expired = true;
            ok()
        }
        "token" => {
            st.expired = false;
            st.accept_token = b["accept"].as_str().map(str::to_string);
            ok()
        }
        "shutdown-mismatch" => {
            st.shutdown_mismatch = b["value"].as_str().map(str::to_string);
            ok()
        }
        "no-termination-time" => {
            st.no_termination_time = true;
            ok()
        }
        "deny-permissions" => {
            st.denied_permissions = b["permissions"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default();
            ok()
        }
        "prices" => {
            // {"aws": {"spot": {"TYPE": n}, "ondemand": {…}}, "gcp": {…}}
            for (prov, markets) in b.as_object().into_iter().flatten() {
                for (market, types) in markets.as_object().into_iter().flatten() {
                    for (ty, p) in types.as_object().into_iter().flatten() {
                        if let Some(p) = p.as_f64() {
                            st.prices.insert(format!("{prov}/{market}/{ty}"), p);
                        }
                    }
                }
            }
            ok()
        }
        "seed" => instances::seed(st, &b),
        "poweroff" => match b["id"]
            .as_str()
            .and_then(|id| st.instances.iter().position(|i| i.id == id))
        {
            Some(p) => {
                let now = st.now;
                let i = &mut st.instances[p];
                i.poweroff(now);
                if i.state == St::Stopped {
                    st.podman.stop(i);
                }
                st.settle();
                ok()
            }
            None => Out::json(404, json!({"mock": "no such instance"})),
        },
        "rotate-hostkey" => match b["id"]
            .as_str()
            .and_then(|id| st.instances.iter_mut().find(|i| i.key() == id))
        {
            Some(i) => {
                i.hostkey_gen += 1;
                // with containers, the machine's sshd itself gets new keys
                st.podman.rotate_hostkeys(i);
                ok()
            }
            None => Out::json(404, json!({"mock": "no such instance"})),
        },
        "reset" => {
            st.reset_data();
            ok()
        }
        _ => unknown(st, req, "no such knob"),
    }
}

fn resources(st: &State) -> Out {
    Out::json(
        200,
        json!({
            "now": st.now,
            "instances": st.instances.iter().map(|i| i.describe()).collect::<Vec<_>>(),
            "resources": st.res.iter().map(|r| json!({"kind": r.kind, "id": r.id, "tags": r.tags, "data": r.data})).collect::<Vec<_>>(),
            "prices": st.prices,
            "operations": st.operations,
            "faults_left": st.faults.iter().filter(|f| f.times > 0).count(),
            "expired": st.expired,
            "unknown_requests": st.unknown,
        }),
    )
}

/// `cloud` entry: see the module comment.
pub fn run(args: &[String]) {
    let one = |name: &str| crate::flag(args, name, 1).map(|v| v[0].clone());
    let need = |name: &str| one(name).unwrap_or_else(|| crate::die(&format!("cloud needs {name}")));
    let listen = need("--listen");
    let sock = need("--podman-remote");
    let prefix = need("--prefix");
    let run_id = need("--run");
    let podman = Podman {
        sock: (sock != "none").then_some(sock),
        bin: one("--podman").unwrap_or_else(|| "podman".into()),
        image: one("--image").unwrap_or_else(|| "localhost/drgnx-fake-runner".into()),
        network: one("--network").unwrap_or_else(|| format!("fleet-{run_id}")),
        prefix: prefix.clone(),
        run: run_id.clone(),
        metadata: one("--metadata-url"),
        run_opts: args
            .windows(2)
            .filter(|w| w[0] == "--run-opt")
            .map(|w| w[1].clone())
            .collect(),
    };
    let listener = TcpListener::bind(&listen)
        .unwrap_or_else(|e| crate::die(&format!("cannot listen on {listen}: {e}")));
    let st: Shared = Arc::new(Mutex::new(State::new(
        one("--hub"),
        podman,
        crate::open_log(args),
    )));
    if let Some(pid) = one("--parent").and_then(|p| p.parse::<i32>().ok()) {
        let st = st.clone();
        std::thread::spawn(move || {
            while !crate::parent_gone(pid) {
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
            st.lock().unwrap().reset_data();
            std::process::exit(0);
        });
    }
    crate::announce("MOCK-CLOUD-PORT", &listener);
    for c in listener.incoming().flatten() {
        let st = st.clone();
        std::thread::spawn(move || serve(c, st));
    }
}
