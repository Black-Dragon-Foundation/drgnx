//! Live recordings (docs/develop/recordings.md): the format's version and manifest, the normalizers and the LLM match
//! key, the secret scrub and its lint.  Std, serde_json and sha2 only, so the std-only replayer
//! (`ratatoskr-mock llm --replay`) and the hub share one copy.
//!
//! - **Normalizers (version 1)**, in this order, over every string of a value: the run's roots ([`Roots`]) and other
//!   temp paths with a random part; the hub's own ids (session `a` + 12 hex, job `x` + 11 or more hex) as `$SID1`,
//!   `$JOB1`… and UUIDs as `$UUID1`…, numbered by first appearance in what one [`Normalizer`] sees; RFC 3339 times and
//!   dates, and every value under a time key, as `$TIME`; `127.0.0.1:PORT` and `localhost:PORT` as `$PORT`.  Git ids
//!   are left alone.  [`canonical`] then writes the value with its keys sorted and no whitespace.
//! - **The match key** of an LLM request ([`key`]): SHA-256 of the canonical, normalized, pattern-scrubbed
//!   [`keyed`] object (the route and the fields that decide an answer; `metadata` and the rest are not keyed).
//! - **The scrub** ([`Scrub`]): headers by allowlist, environment values by name, exact values it was told, and the
//!   patterns of [`find_secrets`], each replaced by `$SECRET`.
//! - **The lint** ([`lint_run`]): every file of a run, binary ones too; it names the file, the offset, the kind and the
//!   first four characters, never the value.

use std::borrow::Cow;
use std::collections::HashMap;
use std::fmt;
use std::path::Path;

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

/// The manifest's `format`.
pub const FORMAT: &str = "drgnx-recording";
/// The file format's version: a reader refuses a higher one.
pub const VERSION: u64 = 1;
/// The normalizers' version (recorded; keys are recomputed with the current ones on replay).
pub const NORMALIZE: u64 = 1;
/// The scrub's version.
pub const SCRUB: u64 = 1;
/// What a secret becomes.
pub const SECRET: &str = "$SECRET";
/// A run over this many bytes fails the lint.
pub const MAX_RUN_BYTES: u64 = 25 * 1024 * 1024;

// ------------------------------------------------------------------------------------------ the manifest

/// A new run's manifest: `status` `incomplete` until `record stop` ends it.  PROVENANCE is `mock` (made from the
/// scripted mocks; the only kind a repository fixture may be) or `live`.
pub fn manifest(
    provenance: &str,
    started: &str,
    commit: &str,
    build: &str,
    roots: &Roots,
) -> Value {
    json!({
        "format": FORMAT, "version": VERSION, "normalize": NORMALIZE, "scrub": SCRUB,
        "status": "incomplete", "provenance": provenance, "started": started, "ended": null,
        "drgnx_commit": commit, "nidhogg_version": null, "build": build,
        "adapters": [], "providers": [], "profiles": [], "worktree": null, "connections": [],
        "caps": {}, "spend": null, "lint": null, "roots": roots.to_json(),
    })
}

/// Why a reader refuses manifest M: an unknown `format`, or a `version` it does not know.
pub fn check_manifest(m: &Value) -> Result<(), String> {
    match m.get("format").and_then(Value::as_str) {
        Some(FORMAT) => {}
        Some(other) => return Err(format!("not a drgnx recording (format {other:?})")),
        None => return Err("not a drgnx recording (the manifest names no format)".into()),
    }
    match m.get("version").and_then(Value::as_u64) {
        Some(v) if v > VERSION => Err(format!(
            "the recording's version {v} is newer than this drgnx reads ({VERSION}): update drgnx"
        )),
        Some(0) | None => Err("the manifest has no version".into()),
        Some(_) => Ok(()),
    }
}

/// DIR's `manifest.json`, checked.
pub fn read_manifest(dir: &Path) -> Result<Value, String> {
    let path = dir.join("manifest.json");
    let text = std::fs::read_to_string(&path)
        .map_err(|e| format!("no recording at {}: {e}", dir.display()))?;
    let m: Value = serde_json::from_str(&text)
        .map_err(|e| format!("{} does not read: {e}", path.display()))?;
    check_manifest(&m)?;
    Ok(m)
}

// ------------------------------------------------------------------------------------------ bodies

/// Bytes as a stream stores them: text when UTF-8, else `{"b64": …}`.
pub fn body_value(bytes: &[u8]) -> Value {
    match std::str::from_utf8(bytes) {
        Ok(s) => Value::String(s.to_owned()),
        Err(_) => json!({ "b64": b64_encode(bytes) }),
    }
}

/// What [`body_value`] stored, as bytes (none: neither form).
pub fn body_bytes(v: &Value) -> Option<Vec<u8>> {
    match v {
        Value::String(s) => Some(s.as_bytes().to_vec()),
        Value::Object(o) => o.get("b64").and_then(Value::as_str).and_then(b64_decode),
        _ => None,
    }
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn b64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().fold(0u32, |n, b| (n << 8) | u32::from(*b)) << (8 * (3 - chunk.len()));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(char::from(B64[((n >> (18 - 6 * i)) & 63) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

pub fn b64_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let (mut n, mut bits) = (0u32, 0);
    for c in text.bytes().filter(|c| *c != b'=') {
        let v = B64.iter().position(|b| *b == c)? as u32;
        n = (n << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((n >> bits) as u8);
        }
    }
    Some(out)
}

// ------------------------------------------------------------------------------------------ the normalizers

/// The run's roots, as `(name, path)`, longest path first (so `$STATE` wins over a `$HOME` it lies in).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Roots(Vec<(String, String)>);

impl Roots {
    /// The roots of PAIRS; an empty path or `/` is left out, a trailing `/` dropped.
    pub fn new<N: Into<String>>(pairs: impl IntoIterator<Item = (N, String)>) -> Roots {
        let mut v: Vec<(String, String)> = pairs
            .into_iter()
            .map(|(n, p)| (n.into(), p.trim_end_matches('/').to_owned()))
            .filter(|(_, p)| !p.is_empty())
            .collect();
        v.sort_by(|a, b| {
            b.1.len()
                .cmp(&a.1.len())
                .then_with(|| a.1.cmp(&b.1))
                .then_with(|| a.0.cmp(&b.0))
        });
        v.dedup_by(|a, b| a.1 == b.1);
        Roots(v)
    }

    /// The roots a hub or a replayer with environment ENV has: its state and data dirs, home and temp dir.
    pub fn of_env(env: &crate::paths::Env) -> Roots {
        let s = |p: std::path::PathBuf| p.to_string_lossy().into_owned();
        let var = |k: &str| env.vars.get(k).filter(|v| v.starts_with('/')).cloned();
        let mut pairs = vec![
            ("$STATE", s(crate::paths::state_dir(env))),
            ("$DATA", s(crate::paths::data_dir(env))),
        ];
        if let Some(home) = var("HOME") {
            pairs.push(("$HOME", home));
        }
        pairs.push(("$TMP", var("TMPDIR").unwrap_or_else(|| "/tmp".into())));
        Roots::new(pairs)
    }

    pub fn to_json(&self) -> Value {
        Value::Object(self.0.iter().map(|(n, p)| (n.clone(), json!(p))).collect())
    }

    /// The roots a manifest's `roots` names (none: no roots).
    pub fn from_json(v: &Value) -> Roots {
        Roots::new(
            v.as_object()
                .into_iter()
                .flatten()
                .filter_map(|(n, p)| Some((n.clone(), p.as_str()?.to_owned()))),
        )
    }
}

/// The keys whose values are times.
pub const TIME_KEYS: [&str; 4] = ["ts", "created", "timestamp", "resetsAt"];

/// The normalizers over the values of one comparison: the numbering of ids and UUIDs is by first appearance in what
/// this one normalizer sees.
pub struct Normalizer<'r> {
    roots: &'r Roots,
    numbers: HashMap<(&'static str, String), usize>,
    counts: HashMap<&'static str, usize>,
}

impl<'r> Normalizer<'r> {
    pub fn new(roots: &'r Roots) -> Normalizer<'r> {
        Normalizer {
            roots,
            numbers: HashMap::new(),
            counts: HashMap::new(),
        }
    }

    /// V normalized: each string by [`Normalizer::text`], each value under a time key `$TIME`.  Object keys are
    /// visited in sorted order, so the numbering does not depend on how the sender ordered them.
    pub fn value(&mut self, v: &Value) -> Value {
        match v {
            Value::String(s) => Value::String(self.text(s)),
            Value::Array(a) => Value::Array(a.iter().map(|x| self.value(x)).collect()),
            Value::Object(o) => {
                let mut keys: Vec<&String> = o.keys().collect();
                keys.sort();
                let mut out = Map::new();
                for k in keys {
                    let x = &o[k];
                    let n = if TIME_KEYS.contains(&k.as_str()) && (x.is_number() || x.is_string()) {
                        json!("$TIME")
                    } else {
                        self.value(x)
                    };
                    out.insert(k.clone(), n);
                }
                Value::Object(out)
            }
            other => other.clone(),
        }
    }

    /// S normalized (the module's order of rules).
    pub fn text(&mut self, s: &str) -> String {
        let mut t = self.paths(s);
        t = self.ids(&t);
        t = self.uuids(&t);
        t = times(&t);
        ports(&t)
    }

    fn number(&mut self, kind: &'static str, found: &str) -> String {
        let key = (kind, found.to_owned());
        let n = match self.numbers.get(&key) {
            Some(n) => *n,
            None => {
                let c = self.counts.entry(kind).or_insert(0);
                *c += 1;
                self.numbers.insert(key, *c);
                *c
            }
        };
        format!("{kind}{n}")
    }

    fn paths(&self, s: &str) -> String {
        let mut t = s.to_owned();
        for (name, root) in &self.roots.0 {
            t = replace_bounded(&t, root, name);
        }
        // other temp paths with a random part
        let mut out = String::with_capacity(t.len());
        let mut rest = t.as_str();
        while let Some(at) = rest.find("/tmp/") {
            let before_ok = rest[..at]
                .chars()
                .next_back()
                .is_none_or(|c| !c.is_ascii_alphanumeric());
            let after = &rest[at + 5..];
            let comp_len = after
                .find(|c: char| {
                    c == '/' || c.is_whitespace() || matches!(c, '"' | '\'' | ':' | ',')
                })
                .unwrap_or(after.len());
            let comp = &after[..comp_len];
            out.push_str(&rest[..at]);
            if before_ok && comp.chars().any(|c| c.is_ascii_digit()) {
                out.push_str("$TMP/…");
                rest = &after[comp_len..];
            } else {
                out.push_str("/tmp/");
                rest = after;
            }
        }
        out.push_str(rest);
        out
    }

    fn ids(&mut self, s: &str) -> String {
        let b = s.as_bytes();
        let mut out = String::with_capacity(s.len());
        let mut i = 0;
        let mut last = 0;
        while i < b.len() {
            let start_ok = i == 0 || !id_char(b[i - 1]);
            if start_ok && (b[i] == b'a' || b[i] == b'x') {
                let hex = b[i + 1..]
                    .iter()
                    .take_while(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
                    .count();
                let end = i + 1 + hex;
                let end_ok = end == b.len() || !id_char(b[end]);
                let kind = match (b[i], hex) {
                    (b'a', 12) => Some("$SID"),
                    (b'x', 11..=20) => Some("$JOB"),
                    _ => None,
                };
                if let (Some(kind), true) = (kind, end_ok) {
                    out.push_str(&s[last..i]);
                    let id = self.number(kind, &s[i..end]);
                    out.push_str(&id);
                    i = end;
                    last = end;
                    continue;
                }
            }
            i += 1;
        }
        out.push_str(&s[last..]);
        out
    }

    fn uuids(&mut self, s: &str) -> String {
        let b = s.as_bytes();
        let mut out = String::with_capacity(s.len());
        let (mut i, mut last) = (0, 0);
        while i + 36 <= b.len() {
            if (i == 0 || !b[i - 1].is_ascii_alphanumeric())
                && is_uuid(&b[i..i + 36])
                && (i + 36 == b.len() || !b[i + 36].is_ascii_alphanumeric())
            {
                out.push_str(&s[last..i]);
                let id = self.number("$UUID", &s[i..i + 36].to_ascii_lowercase());
                out.push_str(&id);
                i += 36;
                last = i;
            } else {
                i += 1;
            }
        }
        out.push_str(&s[last..]);
        out
    }
}

fn id_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

/// S with each ROOT that ends at a path boundary replaced by NAME.
fn replace_bounded(s: &str, root: &str, name: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(at) = rest.find(root) {
        let after = &rest[at + root.len()..];
        let ends = after
            .chars()
            .next()
            .is_none_or(|c| !(c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')));
        out.push_str(&rest[..at]);
        out.push_str(if ends { name } else { root });
        rest = after;
    }
    out.push_str(rest);
    out
}

fn is_uuid(b: &[u8]) -> bool {
    b.iter().enumerate().all(|(i, c)| match i {
        8 | 13 | 18 | 23 => *c == b'-',
        _ => c.is_ascii_hexdigit(),
    })
}

fn digits(b: &[u8], at: usize, n: usize) -> bool {
    b.len() >= at + n && b[at..at + n].iter().all(u8::is_ascii_digit)
}

/// RFC 3339 times and plain dates → `$TIME`.
fn times(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let (mut i, mut last) = (0, 0);
    while i < b.len() {
        let date = (i == 0 || !b[i - 1].is_ascii_digit())
            && digits(b, i, 4)
            && b.get(i + 4) == Some(&b'-')
            && digits(b, i + 5, 2)
            && b.get(i + 7) == Some(&b'-')
            && digits(b, i + 8, 2);
        if !date {
            i += 1;
            continue;
        }
        let mut end = i + 10;
        if b.get(end) == Some(&b'T')
            && digits(b, end + 1, 2)
            && b.get(end + 3) == Some(&b':')
            && digits(b, end + 4, 2)
            && b.get(end + 6) == Some(&b':')
            && digits(b, end + 7, 2)
        {
            end += 9;
            if b.get(end) == Some(&b'.') {
                end += 1 + b[end + 1..]
                    .iter()
                    .take_while(|c| c.is_ascii_digit())
                    .count();
            }
            if b.get(end) == Some(&b'Z') {
                end += 1;
            } else if matches!(b.get(end), Some(b'+' | b'-'))
                && digits(b, end + 1, 2)
                && b.get(end + 3) == Some(&b':')
                && digits(b, end + 4, 2)
            {
                end += 6;
            }
        }
        if end < b.len() && b[end].is_ascii_digit() {
            i += 1;
            continue;
        }
        out.push_str(&s[last..i]);
        out.push_str("$TIME");
        i = end;
        last = end;
    }
    out.push_str(&s[last..]);
    out
}

/// `127.0.0.1:PORT` and `localhost:PORT` → `$PORT`.
fn ports(s: &str) -> String {
    let mut t = s.to_owned();
    for host in ["127.0.0.1:", "localhost:"] {
        let mut out = String::with_capacity(t.len());
        let mut rest = t.as_str();
        while let Some(at) = rest.find(host) {
            let after = &rest[at + host.len()..];
            let n = after.bytes().take_while(u8::is_ascii_digit).count();
            out.push_str(&rest[..at]);
            if (1..=5).contains(&n) {
                out.push_str("$PORT");
            } else {
                out.push_str(host);
            }
            rest = &after[n..];
        }
        out.push_str(rest);
        t = out;
    }
    t
}

/// V as one line: object keys sorted, no whitespace.
pub fn canonical(v: &Value) -> String {
    let mut out = String::new();
    write_canonical(v, &mut out);
    out
}

fn write_canonical(v: &Value, out: &mut String) {
    match v {
        Value::Object(o) => {
            let mut keys: Vec<&String> = o.keys().collect();
            keys.sort();
            out.push('{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(k.clone()).to_string());
                out.push(':');
                write_canonical(&o[k], out);
            }
            out.push('}');
        }
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical(x, out);
            }
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

// ------------------------------------------------------------------------------------------ the match key

/// The fields of an LLM request that decide its answer: the Messages and chat fields, and the editor's FIM and
/// embedding inputs.
pub const KEYED: [&str; 16] = [
    "model",
    "system",
    "messages",
    "tools",
    "tool_choice",
    "stream",
    "max_tokens",
    "temperature",
    "thinking",
    "prompt",
    "suffix",
    "input",
    "inputs",
    "input_prefix",
    "input_suffix",
    "input_extra",
];

/// The keyed object of a request to PROVIDER at PATH with BODY: `route` and the [`KEYED`] fields it has; a body that
/// is not a JSON object keys on its text.
pub fn keyed(provider: &str, path: &str, body: &str) -> Value {
    let mut out = Map::new();
    out.insert("route".into(), json!(format!("{provider} {path}")));
    match serde_json::from_str::<Value>(body) {
        Ok(Value::Object(o)) => {
            for k in KEYED {
                if let Some(v) = o.get(k) {
                    out.insert(k.into(), v.clone());
                }
            }
        }
        _ => {
            out.insert("raw".into(), json!(body));
        }
    }
    Value::Object(out)
}

/// [`keyed`], pattern-scrubbed and normalized (one normalizer per request: requests may interleave differently on
/// replay, so numbering across them would make one late request change every later key).
pub fn normalized_keyed(provider: &str, path: &str, body: &str, roots: &Roots) -> Value {
    let scrubbed = Scrub::default().value(&keyed(provider, path, body));
    Normalizer::new(roots).value(&scrubbed)
}

/// The match key: SHA-256 hex of the canonical [`normalized_keyed`] object.
pub fn key(provider: &str, path: &str, body: &str, roots: &Roots) -> String {
    hex(
        Sha256::digest(canonical(&normalized_keyed(provider, path, body, roots)).as_bytes())
            .as_slice(),
    )
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// The first path at which A and B differ (`messages[3].content[0].text`), none when equal.
pub fn first_diff(a: &Value, b: &Value) -> Option<String> {
    fn walk(a: &Value, b: &Value, at: &str) -> Option<String> {
        let join = |k: &str| {
            if at.is_empty() {
                k.to_owned()
            } else {
                format!("{at}.{k}")
            }
        };
        match (a, b) {
            (Value::Object(x), Value::Object(y)) => {
                let mut keys: Vec<&String> = x.keys().chain(y.keys()).collect();
                keys.sort();
                keys.dedup();
                keys.into_iter().find_map(|k| match (x.get(k), y.get(k)) {
                    (Some(p), Some(q)) => walk(p, q, &join(k)),
                    _ => Some(join(k)),
                })
            }
            (Value::Array(x), Value::Array(y)) => {
                (0..x.len().max(y.len())).find_map(|i| match (x.get(i), y.get(i)) {
                    (Some(p), Some(q)) => walk(p, q, &format!("{at}[{i}]")),
                    _ => Some(format!("{at}[{i}]")),
                })
            }
            _ if a == b => None,
            _ => Some(if at.is_empty() {
                "$".into()
            } else {
                at.to_owned()
            }),
        }
    }
    walk(a, b, "")
}

/// How many leaves of A and B differ (the nearest recorded request has the fewest).
pub fn distance(a: &Value, b: &Value) -> usize {
    match (a, b) {
        (Value::Object(x), Value::Object(y)) => {
            let mut keys: Vec<&String> = x.keys().chain(y.keys()).collect();
            keys.sort();
            keys.dedup();
            keys.into_iter()
                .map(|k| match (x.get(k), y.get(k)) {
                    (Some(p), Some(q)) => distance(p, q),
                    _ => 1,
                })
                .sum()
        }
        (Value::Array(x), Value::Array(y)) => (0..x.len().max(y.len()))
            .map(|i| match (x.get(i), y.get(i)) {
                (Some(p), Some(q)) => distance(p, q),
                _ => 1,
            })
            .sum(),
        _ => usize::from(a != b),
    }
}

// ------------------------------------------------------------------------------------------ the scrub

/// The headers a stream stores; no other is ever written (no `authorization`, `x-api-key`, cookie or proxy header).
pub const HEADERS: [&str; 7] = [
    "content-type",
    "accept",
    "anthropic-version",
    "anthropic-beta",
    "retry-after",
    "x-request-id",
    "x-generation-id",
];

/// The environment variables whose values are stored; every other value is `$SECRET`.
pub const ENV_NAMES: [&str; 22] = [
    "PATH",
    "HOME",
    "LANG",
    "LANGUAGE",
    "LC_ALL",
    "LC_CTYPE",
    "TERM",
    "COLORTERM",
    "NO_PROXY",
    "no_proxy",
    "TZ",
    "USER",
    "LOGNAME",
    "SHELL",
    "TMPDIR",
    "PWD",
    "XDG_RUNTIME_DIR",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "XDG_CACHE_HOME",
    "DRGNX_DATA_DIR",
];

/// The header names that must never be stored, for the lint.
const NEVER_HEADERS: [&str; 5] = [
    "authorization",
    "x-api-key",
    "cookie",
    "set-cookie",
    "proxy-authorization",
];

/// The secret scrub, with the exact values it was told (provider keys are scrubbed inside bifrost, `Keys::scrub`).
#[derive(Debug, Default, Clone)]
pub struct Scrub {
    exact: Vec<String>,
}

impl Scrub {
    /// Scrub SECRET wherever it appears from now on; one under 8 characters would wipe ordinary text and is ignored.
    pub fn add(&mut self, secret: &str) {
        if secret.len() >= 8 && !self.exact.iter().any(|s| s == secret) {
            self.exact.push(secret.to_owned());
            // the longest first, so one secret inside another goes whole
            self.exact.sort_by_key(|s| std::cmp::Reverse(s.len()));
        }
    }

    /// TEXT with the exact values and every pattern of [`find_secrets`] replaced by `$SECRET`.
    pub fn text<'a>(&self, text: &'a str) -> Cow<'a, str> {
        let mut t = Cow::Borrowed(text);
        for s in &self.exact {
            if t.contains(s.as_str()) {
                t = Cow::Owned(t.replace(s.as_str(), SECRET));
            }
        }
        let hits = find_secrets(t.as_bytes());
        if hits.is_empty() {
            return t;
        }
        let mut out = String::with_capacity(t.len());
        let mut last = 0;
        for h in hits {
            out.push_str(&t[last..h.start]);
            out.push_str(SECRET);
            last = h.end;
        }
        out.push_str(&t[last..]);
        Cow::Owned(out)
    }

    /// The allowlisted headers of PAIRS (names lower-case), their values scrubbed.
    pub fn headers<'a>(
        &self,
        pairs: impl IntoIterator<Item = (&'a str, &'a str)>,
    ) -> Map<String, Value> {
        pairs
            .into_iter()
            .filter_map(|(n, v)| {
                let n = n.to_ascii_lowercase();
                HEADERS
                    .contains(&n.as_str())
                    .then(|| (n, json!(self.text(v))))
            })
            .collect()
    }

    /// V with every string scrubbed and every `env` (an object of names, or ACP's list of `{name, value}`) kept by
    /// name: a value whose name is not in [`ENV_NAMES`] is `$SECRET`.
    pub fn value(&self, v: &Value) -> Value {
        match v {
            Value::String(s) => Value::String(self.text(s).into_owned()),
            Value::Array(a) => Value::Array(a.iter().map(|x| self.value(x)).collect()),
            Value::Object(o) => Value::Object(
                o.iter()
                    .map(|(k, x)| {
                        let x = if k == "env" {
                            self.env(x)
                        } else {
                            self.value(x)
                        };
                        (k.clone(), x)
                    })
                    .collect(),
            ),
            other => other.clone(),
        }
    }

    fn env(&self, v: &Value) -> Value {
        let keep = |name: &str, x: &Value| {
            if ENV_NAMES.contains(&name) {
                self.value(x)
            } else {
                json!(SECRET)
            }
        };
        match v {
            Value::Object(o) => {
                Value::Object(o.iter().map(|(k, x)| (k.clone(), keep(k, x))).collect())
            }
            Value::Array(a) => Value::Array(
                a.iter()
                    .map(
                        |e| match (e.get("name").and_then(Value::as_str), e.get("value")) {
                            (Some(name), Some(x)) => {
                                let mut e = e.clone();
                                e["value"] = keep(name, x);
                                e
                            }
                            _ => self.value(e),
                        },
                    )
                    .collect(),
            ),
            other => self.value(other),
        }
    }

    /// An argv scrubbed: a `NAME=VALUE` word keeps its value only when NAME is in [`ENV_NAMES`].
    pub fn argv(&self, argv: &[String]) -> Vec<String> {
        argv.iter()
            .map(|w| match w.split_once('=') {
                Some((n, _)) if is_env_name(n) && !ENV_NAMES.contains(&n) => {
                    format!("{n}={SECRET}")
                }
                _ => self.text(w).into_owned(),
            })
            .collect()
    }
}

fn is_env_name(n: &str) -> bool {
    let mut b = n.bytes();
    b.next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == b'_')
        && b.all(|c| c.is_ascii_alphanumeric() || c == b'_')
}

/// One secret found: its byte span and its kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Hit {
    pub start: usize,
    pub end: usize,
    pub kind: &'static str,
}

/// The key prefixes, longest first, and how many characters must follow.
const PREFIXES: [(&str, usize); 11] = [
    ("github_pat_", 16),
    ("sk-or-v1-", 16),
    ("sk-ant-", 16),
    ("ghp_", 16),
    ("gho_", 16),
    ("ghu_", 16),
    ("ghs_", 16),
    ("ghr_", 16),
    ("xoxb-", 16),
    ("xoxp-", 16),
    ("sk-", 16),
];

fn token_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'-'
}

fn b64url_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'-'
}

fn bearer_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'~' | b'+' | b'/' | b'=' | b'-')
}

fn run(b: &[u8], at: usize, ok: fn(u8) -> bool) -> usize {
    b[at.min(b.len())..].iter().take_while(|c| ok(**c)).count()
}

/// The secrets in B by pattern, spans sorted and merged: `sk-or-v1-…`, `sk-ant-…`, `sk-…` (with a digit or a capital),
/// `ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_`/`github_pat_`, `AKIA…`, `xoxb-`/`xoxp-`, the token after `Bearer `, JWTs,
/// `-----BEGIN … PRIVATE KEY-----` blocks and the value of `CLAUDE_CODE_OAUTH_TOKEN=`.
pub fn find_secrets(b: &[u8]) -> Vec<Hit> {
    let mut hits = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let start_ok = i == 0 || !token_byte(b[i - 1]);
        if b[i..].starts_with(b"-----BEGIN ") {
            let rest = &b[i + 11..];
            let run_len = rest
                .iter()
                .take_while(|c| c.is_ascii_uppercase() || **c == b' ')
                .count();
            if rest[..run_len].ends_with(b"PRIVATE KEY") && rest[run_len..].starts_with(b"-----") {
                let from = i + 11 + run_len + 5;
                let end = find_from(b, from, b"-----END ")
                    .map(|e| {
                        let tail = &b[e + 9..];
                        let n = tail
                            .iter()
                            .take_while(|c| c.is_ascii_uppercase() || **c == b' ')
                            .count();
                        if tail[n..].starts_with(b"-----") {
                            e + 9 + n + 5
                        } else {
                            e + 9 + n
                        }
                    })
                    .unwrap_or(b.len());
                hits.push(Hit {
                    start: i,
                    end,
                    kind: "private-key",
                });
                i = end;
                continue;
            }
        }
        if start_ok && b[i..].starts_with(b"CLAUDE_CODE_OAUTH_TOKEN=") {
            let from = i + 24;
            let n = run(b, from, bearer_byte);
            if n > 0 {
                hits.push(Hit {
                    start: from,
                    end: from + n,
                    kind: "oauth-token",
                });
                i = from + n;
                continue;
            }
        }
        if start_ok && b.len() >= i + 7 && b[i..i + 7].eq_ignore_ascii_case(b"bearer ") {
            let from = i + 7;
            let n = run(b, from, bearer_byte);
            if n >= 8 {
                hits.push(Hit {
                    start: from,
                    end: from + n,
                    kind: "bearer",
                });
                i = from + n;
                continue;
            }
        }
        if start_ok && b[i..].starts_with(b"eyJ") {
            let a = run(b, i, b64url_byte);
            if b.get(i + a) == Some(&b'.') {
                let p = run(b, i + a + 1, b64url_byte);
                if p >= 4 && b.get(i + a + 1 + p) == Some(&b'.') {
                    let s = run(b, i + a + 2 + p, b64url_byte);
                    let end = i + a + 2 + p + s;
                    if a >= 10 {
                        hits.push(Hit {
                            start: i,
                            end,
                            kind: "jwt",
                        });
                        i = end;
                        continue;
                    }
                }
            }
        }
        if start_ok
            && b[i..].starts_with(b"AKIA")
            && b.len() >= i + 20
            && b[i + 4..i + 20]
                .iter()
                .all(|c| c.is_ascii_digit() || c.is_ascii_uppercase())
        {
            hits.push(Hit {
                start: i,
                end: i + 20,
                kind: "aws-key-id",
            });
            i += 20;
            continue;
        }
        if start_ok {
            let tok = run(b, i, token_byte);
            if let Some((p, min)) = PREFIXES
                .iter()
                .find(|(p, _)| b[i..i + tok].starts_with(p.as_bytes()))
            {
                let rest = &b[i + p.len()..i + tok];
                let strong = *p != "sk-"
                    || rest
                        .iter()
                        .any(|c| c.is_ascii_digit() || c.is_ascii_uppercase());
                if rest.len() >= *min && strong {
                    hits.push(Hit {
                        start: i,
                        end: i + tok,
                        kind: "key-prefix",
                    });
                    i += tok;
                    continue;
                }
            }
        }
        i += 1;
    }
    hits.sort_by_key(|h| h.start);
    let mut merged: Vec<Hit> = Vec::with_capacity(hits.len());
    for h in hits {
        match merged.last_mut() {
            Some(m) if h.start <= m.end => m.end = m.end.max(h.end),
            _ => merged.push(h),
        }
    }
    merged
}

fn find_from(b: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    b.get(from..)?
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|p| from + p)
}

// ------------------------------------------------------------------------------------------ the lint

/// One thing the lint found: where, what kind, and the first four characters of what it found (never more).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    /// The file, relative to the run.
    pub file: String,
    pub offset: usize,
    pub kind: &'static str,
    pub head: String,
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}:{}: {} ({}…)",
            self.file, self.offset, self.kind, self.head
        )
    }
}

fn head4(b: &[u8]) -> String {
    String::from_utf8_lossy(&b[..b.len().min(4)]).into_owned()
}

/// Whether a field named NAME holds a secret when its value is one: a key, token, secret or password field.
fn secret_name(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    ["key", "token", "secret", "password", "passwd", "credential"]
        .iter()
        .any(|w| n.contains(w))
}

/// A value under a secret-named field that looks like one: 16 or more key characters, two classes and 3 bits a
/// character of entropy.  `$…` placeholders are not.
fn looks_random(v: &str) -> bool {
    if v.len() < 16 || v.starts_with('$') {
        return false;
    }
    if !v
        .bytes()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'+' | b'/' | b'=' | b'_' | b'-' | b'.'))
    {
        return false;
    }
    let classes = [
        v.bytes().any(|c| c.is_ascii_lowercase()),
        v.bytes().any(|c| c.is_ascii_uppercase()),
        v.bytes().any(|c| c.is_ascii_digit()),
    ];
    if classes.iter().filter(|c| **c).count() < 2 {
        return false;
    }
    let mut counts = [0u32; 128];
    for c in v.bytes() {
        counts[usize::from(c & 0x7f)] += 1;
    }
    let n = v.len() as f64;
    let bits: f64 = counts
        .iter()
        .filter(|c| **c > 0)
        .map(|c| {
            let p = f64::from(*c) / n;
            -p * p.log2()
        })
        .sum();
    bits >= 3.0
}

/// The findings of rules 1 (stored header names) and 4 (patterns) in one file's bytes, and, in a file that is not
/// JSON, of secret-looking values under secret-named fields.
pub fn lint_bytes(file: &str, b: &[u8], json_file: bool) -> Vec<Finding> {
    let mut out: Vec<Finding> = find_secrets(b)
        .into_iter()
        .map(|h| Finding {
            file: file.into(),
            offset: h.start,
            kind: h.kind,
            head: head4(&b[h.start..h.end]),
        })
        .collect();
    let lower = b.to_ascii_lowercase();
    for name in NEVER_HEADERS {
        let quoted = format!("\"{name}\"");
        let mut from = 0;
        while let Some(at) = find_from(&lower, from, quoted.as_bytes()) {
            from = at + quoted.len();
            let rest = &b[from..];
            let sp = rest.iter().take_while(|c| **c == b' ').count();
            if rest.get(sp) == Some(&b':') {
                let v = &rest[sp + 1..];
                let v = &v[v.iter().take_while(|c| matches!(**c, b' ' | b'"')).count()..];
                out.push(Finding {
                    file: file.into(),
                    offset: at,
                    kind: "header",
                    head: head4(v),
                });
            }
        }
    }
    if !json_file {
        // `"NAME": "VALUE"` byte runs, as a JSON text inside a database or a log has them
        let mut i = 0;
        while let Some(q) = find_from(b, i, b"\"") {
            let name_end = match find_from(b, q + 1, b"\"") {
                Some(e) if e - q < 64 => e,
                Some(e) => {
                    i = e;
                    continue;
                }
                None => break,
            };
            let name = String::from_utf8_lossy(&b[q + 1..name_end]);
            i = name_end + 1;
            let rest = &b[i..];
            let sp = rest.iter().take_while(|c| **c == b' ').count();
            if rest.get(sp) != Some(&b':') || !secret_name(&name) {
                continue;
            }
            let v0 = i + sp + 1 + rest[sp + 1..].iter().take_while(|c| **c == b' ').count();
            if b.get(v0) != Some(&b'"') {
                continue;
            }
            let v_end = find_from(b, v0 + 1, b"\"").unwrap_or(b.len());
            let value = String::from_utf8_lossy(&b[v0 + 1..v_end]);
            if looks_random(&value) {
                out.push(Finding {
                    file: file.into(),
                    offset: v0 + 1,
                    kind: "high-entropy",
                    head: head4(value.as_bytes()),
                });
            }
            i = v_end;
        }
    }
    out
}

/// The findings of one JSON value V (rule 2, and secret-looking values under secret-named fields), V being TEXT at
/// offset AT of FILE.  V's own top-level `key` (a stream line's match key) is no secret.
fn lint_json(file: &str, text: &str, at: usize, v: &Value, out: &mut Vec<Finding>) {
    let mut found = |kind: &'static str, s: &str| {
        out.push(Finding {
            file: file.into(),
            offset: at + text.find(s).unwrap_or(0),
            kind,
            head: head4(s.as_bytes()),
        });
    };
    let mut stack: Vec<(&str, &Value)> = match v {
        Value::Object(o) => o
            .iter()
            .filter(|(k, _)| *k != "key")
            .map(|(k, x)| (k.as_str(), x))
            .collect(),
        other => vec![("", other)],
    };
    while let Some((name, x)) = stack.pop() {
        match x {
            Value::String(s) if secret_name(name) && looks_random(s) => found("high-entropy", s),
            Value::Array(a) => stack.extend(a.iter().map(|y| (name, y))),
            Value::Object(o) => {
                for (k, y) in o {
                    if k != "env" {
                        stack.push((k.as_str(), y));
                        continue;
                    }
                    let pairs: Vec<(&str, &Value)> = match y {
                        Value::Object(env) => {
                            env.iter().map(|(n, val)| (n.as_str(), val)).collect()
                        }
                        Value::Array(env) => env
                            .iter()
                            .filter_map(|e| Some((e.get("name")?.as_str()?, e.get("value")?)))
                            .collect(),
                        _ => Vec::new(),
                    };
                    for (n, val) in pairs {
                        if !ENV_NAMES.contains(&n) && val.as_str() != Some(SECRET) {
                            let s = val.as_str().map_or_else(|| val.to_string(), str::to_owned);
                            found("env", &s);
                        }
                    }
                }
            }
            _ => {}
        }
    }
}

/// Every file under DIR linted: rules 1, 2 and 4, secret-looking values under secret-named fields, the size of the
/// run, and, for a recording under a repository's `test/fixtures/recordings/`, that the mocks made it.
pub fn lint_run(dir: &Path) -> Result<Vec<Finding>, String> {
    let mut files = Vec::new();
    collect(dir, dir, &mut files).map_err(|e| format!("cannot read {}: {e}", dir.display()))?;
    files.sort();
    let mut out = Vec::new();
    let mut total = 0u64;
    for rel in &files {
        let b = std::fs::read(dir.join(rel)).map_err(|e| format!("cannot read {rel}: {e}"))?;
        total += b.len() as u64;
        let json_file = rel.ends_with(".json") || rel.ends_with(".jsonl");
        out.extend(lint_bytes(rel, &b, json_file));
        if json_file {
            let text = String::from_utf8_lossy(&b);
            // a JSON file is one value; a JSONL file one per line
            let parts: Vec<&str> = if rel.ends_with(".jsonl") {
                text.split_inclusive('\n').collect()
            } else {
                vec![&*text]
            };
            let mut at = 0;
            for part in parts {
                match serde_json::from_str::<Value>(part) {
                    Ok(v) => lint_json(rel, part, at, &v, &mut out),
                    // what does not parse is read as bytes
                    Err(_) => out.extend(
                        lint_bytes(rel, part.as_bytes(), false)
                            .into_iter()
                            .filter(|f| f.kind == "high-entropy")
                            .map(|f| Finding {
                                offset: f.offset + at,
                                ..f
                            }),
                    ),
                }
                at += part.len();
            }
        }
    }
    if total > MAX_RUN_BYTES {
        out.push(Finding {
            file: ".".into(),
            offset: 0,
            kind: "size",
            head: head4(total.to_string().as_bytes()),
        });
    }
    if under_fixtures(dir) {
        let provenance = std::fs::read_to_string(dir.join("manifest.json"))
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            .and_then(|m| {
                m.get("provenance")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            });
        if provenance.as_deref() != Some("mock") {
            let p = provenance.unwrap_or_default();
            out.push(Finding {
                file: "manifest.json".into(),
                offset: 0,
                kind: "not-mock",
                head: head4(p.as_bytes()),
            });
        }
    }
    out.sort_by(|a, b| (&a.file, a.offset, a.kind).cmp(&(&b.file, b.offset, b.kind)));
    out.dedup();
    Ok(out)
}

/// Whether DIR lies under a `test/fixtures/recordings/` directory: a repository's fixtures, which only the mocks make.
pub fn under_fixtures(dir: &Path) -> bool {
    let parts: Vec<String> = dir
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    parts
        .windows(3)
        .any(|w| w[0] == "test" && w[1] == "fixtures" && w[2] == "recordings")
}

fn collect(root: &Path, dir: &Path, out: &mut Vec<String>) -> std::io::Result<()> {
    for e in std::fs::read_dir(dir)? {
        let e = e?;
        let t = e.file_type()?;
        let p = e.path();
        if t.is_dir() {
            collect(root, &p, out)?;
        } else if t.is_file() {
            let rel = p.strip_prefix(root).unwrap_or(&p);
            out.push(rel.to_string_lossy().into_owned());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// A fake key of a provider's shape, made of two parts so the repository's leak hook never sees a whole one.
    fn fake(prefix: &str, rest: &str) -> String {
        format!("{prefix}{rest}")
    }

    fn roots(run: &str) -> Roots {
        Roots::new([
            ("$STATE", format!("/tmp/rtsk-{run}/state/drgnx")),
            ("$DATA", format!("/tmp/rtsk-{run}/data")),
            ("$HOME", format!("/tmp/rtsk-{run}/home")),
            ("$TMP", format!("/tmp/rtsk-{run}/tmp")),
        ])
    }

    // Pattern D (pure): two runs' messages, which differ only in what the normalizers cover, normalize to one text.
    #[test]
    fn normalize_is_stable_over_ids_paths_and_times() {
        let run = |r: &str,
                   s1: &str,
                   s2: &str,
                   uuid: &str,
                   time: &str,
                   ts: u64,
                   port: u16,
                   tmp: &str| {
            json!({
                "b": format!("session {s1} asked {s2}, then {s1} again"),
                "a": [format!("/tmp/rtsk-{r}/home/.config/x.el"), format!("/tmp/rtsk-{r}/state/drgnx/hub/log")],
                "uuid": uuid,
                "when": format!("at {time}"),
                "ts": ts,
                "url": format!("http://127.0.0.1:{port}/v1/messages"),
                "scratch": format!("{tmp}/out.txt"),
                "commit": "0123456789abcdef0123456789abcdef01234567",
                "job": "x19a2b3c4d5e1#2",
            })
        };
        let a = run(
            "AAA111",
            "a0123456789ab",
            "a1111111111ff",
            "123e4567-e89b-12d3-a456-426614174000",
            "2026-11-06T10:11:12.345Z",
            1_762_400_000,
            41234,
            "/tmp/.tmpA1b2C3",
        );
        let b = run(
            "BBB222",
            "affedcba98765",
            "a2222222222ee",
            "9f8e7d6c-5b4a-3c2d-1e0f-a1b2c3d4e5f6",
            "2026-11-07T23:59:00+01:00",
            1_762_500_000,
            50000,
            "/tmp/.tmpZ9y8X7",
        );
        let (ra, rb) = (roots("AAA111"), roots("BBB222"));
        let na = canonical(&Normalizer::new(&ra).value(&a));
        let nb = canonical(&Normalizer::new(&rb).value(&b));
        assert_eq!(na, nb);
        for want in [
            "session $SID1 asked $SID2, then $SID1 again",
            "$HOME/.config/x.el",
            "$STATE/hub/log",
            "$UUID1",
            "at $TIME",
            "\"ts\":\"$TIME\"",
            "http://$PORT/v1/messages",
            "$TMP/…/out.txt",
            "0123456789abcdef0123456789abcdef01234567",
            "$JOB1#2",
        ] {
            assert!(na.contains(want), "{want} in {na}");
        }
        // keys sorted, no whitespace
        assert!(na.starts_with("{\"a\":["), "{na}");
        assert!(!na.contains(": "), "{na}");
        // normalizing a normalized value changes nothing
        let again: Value = serde_json::from_str(&na).unwrap();
        assert_eq!(canonical(&Normalizer::new(&ra).value(&again)), na);
    }

    // Pattern D (pure): only the keyed fields count; `metadata` (Claude's `user_id`), key order and spacing do not.
    #[test]
    fn key_ignores_metadata_user_id() {
        let r = roots("K1");
        let one = r#"{"model":"m","metadata":{"user_id":"user_abc_account_1_session_x"},"max_tokens":8,
                      "messages":[{"role":"user","content":"hi"}],"stream":true}"#;
        let two = r#"{ "stream": true, "messages": [ {"content": "hi", "role": "user"} ], "max_tokens": 8,
                      "metadata": {"user_id": "user_def_account_2_session_y"}, "model": "m" }"#;
        let k = key("a", "/v1/messages", one, &r);
        assert_eq!(k.len(), 64);
        assert_eq!(k, key("a", "/v1/messages", two, &r));
        let other = r#"{"model":"m","max_tokens":8,"messages":[{"role":"user","content":"bye"}],"stream":true}"#;
        assert_ne!(k, key("a", "/v1/messages", other, &r));
        assert_ne!(k, key("b", "/v1/messages", one, &r), "another provider");
        assert_ne!(
            k,
            key("a", "/v1/messages/count_tokens", one, &r),
            "another path"
        );
        // a body that is not JSON keys on its text
        assert_eq!(key("a", "/embed", "raw", &r), key("a", "/embed", "raw", &r));
        assert_ne!(
            key("a", "/embed", "raw", &r),
            key("a", "/embed", "raw2", &r)
        );
        // the nearest diff names the first differing path
        let (x, y) = (
            normalized_keyed("a", "/v1/messages", one, &r),
            normalized_keyed("a", "/v1/messages", other, &r),
        );
        assert_eq!(first_diff(&x, &y).as_deref(), Some("messages[0].content"));
        assert_eq!(first_diff(&x, &x), None);
    }

    // Pattern D (pure): every rule of the scrub on one message, and ordinary text kept.
    #[test]
    fn scrub_removes_keys_tokens_and_header_values() {
        let or = fake(
            "sk-or-v1-",
            "0123456789abcdef0123456789abcdef0123456789abcdef",
        );
        let ant = fake("sk-ant-", "api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcd");
        let oai = fake("sk-", "proj-AbCdEf0123456789AbCdEf0123456789");
        let gh = fake("ghp_", "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789");
        let pat = fake("github_pat_", "11ABCDEFG0123456789_abcdefghijklmnop");
        let aws = fake("AKIA", "ABCDEFGHIJKLMNOP");
        let slack = fake("xoxb-", "123456789012-1234567890123-AbCdEfGhIjKl");
        let jwt = fake(
            "eyJhbGciOiJIUzI1NiJ9.",
            "eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXZhbHVl",
        );
        let pem = format!(
            "{}\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n{}",
            fake("-----BEGIN PRIVATE ", "KEY-----"),
            fake("-----END PRIVATE ", "KEY-----")
        );
        let oauth = fake("CLAUDE_CODE_OAUTH_TOKEN=sk-ant-", "oat01-whatever-it-is");
        let token = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0";
        let mut s = Scrub::default();
        s.add(token);
        s.add("short"); // too short to scrub everywhere: ignored
        let text = format!(
            "keys {or} {ant} {oai} {gh} {pat} {aws} {slack}; auth Bearer abcdefgh12345678; jwt {jwt}; \
             {pem}; env {oauth}; token {token}; sk-learn is a library, a short word stays"
        );
        let out = s.text(&text);
        let all: [&str; 11] = [
            &or,
            &ant,
            &oai,
            &gh,
            &pat,
            &aws,
            &slack,
            &jwt,
            &oauth,
            token,
            "abcdefgh12345678",
        ];
        for secret in all {
            assert!(!out.contains(secret), "{secret} left in {out}");
        }
        assert!(!out.contains("MIIEvQIBADANBgkqhkiG9w0BAQEFAASC"), "{out}");
        assert!(out.contains("auth Bearer $SECRET;"), "{out}");
        assert!(
            out.contains("env CLAUDE_CODE_OAUTH_TOKEN=$SECRET;"),
            "{out}"
        );
        assert!(
            out.contains("sk-learn is a library, a short word stays"),
            "{out}"
        );
        assert_eq!(s.text(&out), out, "the scrub is idempotent");

        let headers = s.headers([
            ("Authorization", format!("Bearer {token}").as_str()),
            ("x-api-key", or.as_str()),
            ("cookie", "a=b"),
            ("Set-Cookie", "c=d"),
            ("proxy-authorization", "Basic eHl6"),
            ("Content-Type", "application/json"),
            ("x-request-id", "req_1"),
            ("anthropic-version", "2023-06-01"),
        ]);
        assert_eq!(
            Value::Object(headers),
            json!({"content-type": "application/json", "x-request-id": "req_1", "anthropic-version": "2023-06-01"})
        );

        let v = s.value(&json!({
            "mcpServers": [{"name": "drgnx", "env": [{"name": "PATH", "value": "/usr/bin"},
                                                    {"name": "DRGNX_TOKEN", "value": "plain-looking"}]}],
            "_meta": {"claudeCode": {"options": {"env": {"HOME": "/tmp/h", "ANTHROPIC_AUTH_TOKEN": "x"}}}},
            "note": format!("key {or}"),
        }));
        assert_eq!(v["mcpServers"][0]["env"][0]["value"], "/usr/bin");
        assert_eq!(v["mcpServers"][0]["env"][1]["value"], SECRET);
        assert_eq!(v["_meta"]["claudeCode"]["options"]["env"]["HOME"], "/tmp/h");
        assert_eq!(
            v["_meta"]["claudeCode"]["options"]["env"]["ANTHROPIC_AUTH_TOKEN"],
            SECRET
        );
        assert_eq!(v["note"], "key $SECRET");
        assert_eq!(
            s.argv(&[
                "claude".into(),
                "--env".into(),
                "OPENAI_API_KEY=abc".into(),
                "LANG=C".into()
            ]),
            vec!["claude", "--env", "OPENAI_API_KEY=$SECRET", "LANG=C"]
        );
    }

    // Pattern D (pure, on a temp dir): the lint names where and what, never the value.
    #[test]
    fn lint_names_file_and_kind_not_value() {
        let dir = tempfile::tempdir().unwrap();
        let run = dir.path().join("2026-11-06-x");
        std::fs::create_dir_all(run.join("bundle")).unwrap();
        let m = manifest("live", "2026-11-06T00:00:00Z", "abc", "test", &roots("L"));
        std::fs::write(run.join("manifest.json"), m.to_string()).unwrap();
        let key = fake(
            "sk-or-v1-",
            "fedcba9876543210fedcba9876543210fedcba9876543210",
        );
        let match_key = super::key("a", "/v1/messages", "{}", &roots("L"));
        let line = json!({"seq": 1, "key": match_key, "request": {"headers": {"authorization": "Bearer x"},
                          "body": format!("{{\"k\":\"{key}\"}}")}});
        let text = format!("{}\n{line}\n", json!({"seq": 0, "note": "clean"}));
        std::fs::write(run.join("llm.jsonl"), &text).unwrap();
        let mut db = b"SQLite format 3\0\x01\x02".to_vec();
        db.extend_from_slice(
            json!({"api_token": "Zq8RmT4vXk2PwN7sLc9H"})
                .to_string()
                .as_bytes(),
        );
        db.extend_from_slice(key.as_bytes());
        std::fs::write(run.join("bundle/work.db"), &db).unwrap();

        let found = lint_run(&run).unwrap();
        let shown: Vec<String> = found.iter().map(ToString::to_string).collect();
        let at = text.find(&key).unwrap();
        assert!(
            found.iter().any(|f| f.file == "llm.jsonl"
                && f.kind == "key-prefix"
                && f.head == "sk-o"
                && f.offset == at),
            "{shown:?}"
        );
        assert!(
            found
                .iter()
                .any(|f| f.file == "llm.jsonl" && f.kind == "header"),
            "{shown:?}"
        );
        assert!(
            found
                .iter()
                .any(|f| f.file == "bundle/work.db" && f.kind == "key-prefix"),
            "{shown:?}"
        );
        assert!(
            found
                .iter()
                .any(|f| f.file == "bundle/work.db" && f.kind == "high-entropy"),
            "{shown:?}"
        );
        assert!(
            !found
                .iter()
                .any(|f| f.kind == "high-entropy" && f.file == "llm.jsonl"),
            "the match key is no secret: {shown:?}"
        );
        for s in &shown {
            assert!(
                !s.contains(&key) && !s.contains("Zq8RmT4vXk2PwN7sLc9H"),
                "{s}"
            );
        }
        assert!(
            shown
                .iter()
                .any(|s| s == &format!("llm.jsonl:{at}: key-prefix (sk-o…)")),
            "{shown:?}"
        );

        // scrubbed, it passes
        let clean = Scrub::default();
        std::fs::write(
            run.join("llm.jsonl"),
            clean
                .text(&text.replace("authorization", "content-type"))
                .as_bytes(),
        )
        .unwrap();
        std::fs::remove_file(run.join("bundle/work.db")).unwrap();
        assert_eq!(lint_run(&run).unwrap(), vec![]);

        // under a repository's fixtures only a recording the mocks made passes
        let fixture = dir.path().join("test/fixtures/recordings/smoke");
        std::fs::create_dir_all(&fixture).unwrap();
        std::fs::write(fixture.join("manifest.json"), m.to_string()).unwrap();
        let found = lint_run(&fixture).unwrap();
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(
            (found[0].file.as_str(), found[0].kind),
            ("manifest.json", "not-mock")
        );
        let mock = manifest("mock", "2026-11-06T00:00:00Z", "abc", "test", &roots("L"));
        std::fs::write(fixture.join("manifest.json"), mock.to_string()).unwrap();
        assert_eq!(lint_run(&fixture).unwrap(), vec![]);
    }

    // Pattern D (pure): a reader refuses what it cannot read.
    #[test]
    fn manifest_refuses_a_newer_version() {
        let mut m = manifest("mock", "2026-11-06T00:00:00Z", "abc", "test", &roots("M"));
        assert_eq!(check_manifest(&m), Ok(()));
        assert_eq!(m["format"], FORMAT);
        assert_eq!(m["version"], VERSION);
        assert_eq!(m["status"], "incomplete");
        m["version"] = json!(VERSION + 1);
        let e = check_manifest(&m).unwrap_err();
        assert!(e.contains("newer"), "{e}");
        m["version"] = json!(VERSION);
        m["format"] = json!("something-else");
        assert!(
            check_manifest(&m)
                .unwrap_err()
                .contains("not a drgnx recording")
        );
        assert!(check_manifest(&json!({})).is_err());
    }
}
