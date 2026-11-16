//! Other agent CLIs' session files (Claude Code, Gemini CLI, Codex) read into the hub's transcript entries.
//!
//! None of these formats is a contract (Claude's own documentation says its format changes between versions), so
//! the readers are tolerant: a line they do not know is skipped and counted, never an error, and nothing here
//! panics on any input.  Reading is incremental: [`Reader::feed`] takes the bytes after the last complete line it
//! read, so an appended tail is all that gets parsed again.  No I/O: the hub reads the files (read-only) and feeds
//! the bytes.
//!
//! Entries are JSON objects shaped like the hub's transcript entries (`runstav`'s `Entry`): a `type` (`user`,
//! `agent`, `thought`, `tool`, `notice`, `error`, `compaction`) and the fields its row builder reads (`text`; a tool's
//! `title`, `status`, `content`), plus `at`, the line's time when it has one.

use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashMap};

/// Which CLI wrote a session file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Provider {
    Claude,
    Gemini,
    Codex,
}

impl Provider {
    /// The provider's name in ids and rows: `claude`, `gemini`, `codex`.
    pub fn name(self) -> &'static str {
        match self {
            Provider::Claude => "claude",
            Provider::Gemini => "gemini",
            Provider::Codex => "codex",
        }
    }

    pub fn from_name(s: &str) -> Option<Provider> {
        match s {
            "claude" => Some(Provider::Claude),
            "gemini" => Some(Provider::Gemini),
            "codex" => Some(Provider::Codex),
            _ => None,
        }
    }
}

/// What a session is, as far as its file says.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Meta {
    /// The CLI's own session id (what its resume command takes).
    pub id: Option<String>,
    /// The directory it ran in.
    pub cwd: Option<String>,
    /// Its title: the one the user gave, else the CLI's summary, else the first prompt's first line.
    pub title: Option<String>,
    pub branch: Option<String>,
    /// RFC 3339 times of its first and last line.
    pub started: Option<String>,
    pub updated: Option<String>,
    /// The user's prompts (tool results are not turns).
    pub turns: u32,
}

/// A title is at most this many characters.
const TITLE_CHARS: usize = 100;

/// One Gemini message's place among the entries, for a rewind and for a message written again.
struct Msg {
    id: String,
    start: usize,
    prompt: Option<String>,
}

/// A session file read so far.
pub struct Reader {
    provider: Provider,
    offset: u64,
    entries: Vec<Value>,
    skipped: BTreeMap<String, u64>,
    id: Option<String>,
    cwd: Option<String>,
    branch: Option<String>,
    started: Option<String>,
    updated: Option<String>,
    named: Option<String>,
    summary: Option<String>,
    first_prompt: Option<String>,
    turns: u32,
    /// A tool call's id → its entry, for the result that comes later.
    tools: HashMap<String, usize>,
    msgs: Vec<Msg>,
}

/// BYTES read whole as PROVIDER's session file (complete lines only, as [`Reader::feed`]).
pub fn parse(provider: Provider, bytes: &[u8]) -> Reader {
    let mut r = Reader::new(provider);
    r.feed(bytes);
    r
}

/// BYTES as a finished file: a last line without its newline counts too, and an old Gemini `.json` file (one JSON
/// document with a `messages` list) is read as well.
pub fn parse_whole(provider: Provider, bytes: &[u8]) -> Reader {
    let mut r = Reader::new(provider);
    if provider == Provider::Gemini
        && let Ok(Value::Object(mut doc)) = serde_json::from_slice::<Value>(bytes)
        && let Some(Value::Array(msgs)) = doc.remove("messages")
    {
        r.gemini(&Value::Object(doc));
        for m in &msgs {
            r.gemini(m);
        }
        r.offset = bytes.len() as u64;
        return r;
    }
    let used = r.feed(bytes);
    if used < bytes.len() {
        r.line(&bytes[used..]);
        r.offset = bytes.len() as u64;
    }
    r
}

fn str_at<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
    v.get(k).and_then(Value::as_str).filter(|s| !s.is_empty())
}

fn owned(v: &Value, k: &str) -> Option<String> {
    str_at(v, k).map(str::to_owned)
}

/// The text of CONTENT: a string, or the `text` of each block of a list, one per line.
fn text_in(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(a) => a
            .iter()
            .filter_map(|b| match b {
                Value::String(s) => Some(s.as_str()),
                _ => str_at(b, "text"),
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

/// TEXT's first non-blank line, cut to [`TITLE_CHARS`].
fn title_of(text: &str) -> Option<String> {
    let line = text.lines().map(str::trim).find(|l| !l.is_empty())?;
    Some(line.chars().take(TITLE_CHARS).collect())
}

impl Reader {
    pub fn new(provider: Provider) -> Self {
        Reader {
            provider,
            offset: 0,
            entries: Vec::new(),
            skipped: BTreeMap::new(),
            id: None,
            cwd: None,
            branch: None,
            started: None,
            updated: None,
            named: None,
            summary: None,
            first_prompt: None,
            turns: 0,
            tools: HashMap::new(),
            msgs: Vec::new(),
        }
    }

    /// Read the complete lines of BYTES (the file's bytes from [`Reader::offset`] on); the answer is how many bytes
    /// that was.  A last line without its newline is left for the next feed, which starts with it.
    pub fn feed(&mut self, bytes: &[u8]) -> usize {
        let mut used = 0;
        while let Some(n) = bytes[used..].iter().position(|&b| b == b'\n') {
            self.line(&bytes[used..used + n]);
            used += n + 1;
        }
        self.offset += used as u64;
        used
    }

    pub fn provider(&self) -> Provider {
        self.provider
    }

    pub fn entries(&self) -> &[Value] {
        &self.entries
    }

    /// The bytes read so far: where the next feed starts in the file.
    pub fn offset(&self) -> u64 {
        self.offset
    }

    /// The lines skipped, by their type (`unreadable` for a line that is no JSON object).
    pub fn skipped(&self) -> &BTreeMap<String, u64> {
        &self.skipped
    }

    pub fn meta(&self) -> Meta {
        let (turns, first) = if self.provider == Provider::Gemini {
            let prompts = self.msgs.iter().filter_map(|m| m.prompt.as_deref());
            (
                prompts.clone().count() as u32,
                prompts.clone().next().map(str::to_owned),
            )
        } else {
            (self.turns, self.first_prompt.clone())
        };
        Meta {
            id: self.id.clone(),
            cwd: self.cwd.clone(),
            title: self
                .named
                .clone()
                .or_else(|| self.summary.clone())
                .or(first),
            branch: self.branch.clone(),
            started: self.started.clone(),
            updated: self.updated.clone(),
            turns,
        }
    }

    fn skip(&mut self, what: &str) {
        *self.skipped.entry(what.to_owned()).or_default() += 1;
    }

    fn stamp(&mut self, at: Option<&str>) {
        if let Some(t) = at {
            if self.started.is_none() {
                self.started = Some(t.to_owned());
            }
            self.updated = Some(t.to_owned());
        }
    }

    fn push(&mut self, kind: &str, at: Option<&str>, fields: Value) -> usize {
        let mut m = match fields {
            Value::Object(m) => m,
            _ => Map::new(),
        };
        m.insert("type".into(), kind.into());
        if let Some(t) = at {
            m.insert("at".into(), t.into());
        }
        self.entries.push(Value::Object(m));
        self.entries.len() - 1
    }

    fn prompt(&mut self, text: &str, at: Option<&str>) {
        self.turns += 1;
        if self.first_prompt.is_none() {
            self.first_prompt = title_of(text);
        }
        self.push("user", at, json!({"text": text}));
    }

    fn tool(&mut self, id: Option<&str>, at: Option<&str>, fields: Value) {
        let i = self.push("tool", at, fields);
        if let Some(id) = id {
            self.tools.insert(id.to_owned(), i);
        }
    }

    fn tool_done(&mut self, id: &str, failed: bool, output: String) {
        if let Some(e) = self.tools.get(id).and_then(|&i| self.entries.get_mut(i)) {
            e["status"] = (if failed { "failed" } else { "completed" }).into();
            e["content"] = output.into();
        }
    }

    fn line(&mut self, raw: &[u8]) {
        let raw = raw.strip_suffix(b"\r").unwrap_or(raw);
        if raw.iter().all(u8::is_ascii_whitespace) {
            return;
        }
        match serde_json::from_slice::<Value>(raw) {
            Ok(v @ Value::Object(_)) => match self.provider {
                Provider::Claude => self.claude(&v),
                Provider::Gemini => self.gemini(&v),
                Provider::Codex => self.codex(&v),
            },
            _ => self.skip("unreadable"),
        }
    }

    // ---- Claude Code: one JSON object per line, `type` user / assistant / system / summary / …

    fn claude(&mut self, v: &Value) {
        let kind = str_at(v, "type").unwrap_or("unknown");
        let at = str_at(v, "timestamp");
        self.stamp(at);
        if self.id.is_none() {
            self.id = owned(v, "sessionId");
        }
        if self.cwd.is_none() {
            self.cwd = owned(v, "cwd");
        }
        if self.branch.is_none() {
            self.branch = owned(v, "gitBranch").filter(|b| b != "HEAD");
        }
        match kind {
            "summary" => self.summary = owned(v, "summary").or(self.summary.take()),
            "custom-title" => self.named = owned(v, "customTitle").or(self.named.take()),
            "ai-title" => {
                if let Some(t) = owned(v, "aiTitle").or_else(|| owned(v, "title")) {
                    self.summary = Some(t);
                }
            }
            "user" if v["isMeta"] == true => self.skip("meta"),
            "user" => self.claude_user(&v["message"]["content"], at),
            "assistant" => self.claude_assistant(&v["message"]["content"], at),
            "system" if str_at(v, "subtype") == Some("compact_boundary") => {
                self.push("compaction", at, json!({}));
            }
            other => self.skip(other),
        }
    }

    fn claude_user(&mut self, content: &Value, at: Option<&str>) {
        let mut said = Vec::new();
        match content {
            Value::String(s) => said.push(s.clone()),
            Value::Array(blocks) => {
                for b in blocks {
                    match str_at(b, "type") {
                        Some("text") => said.extend(owned(b, "text")),
                        Some("tool_result") => {
                            if let Some(id) = str_at(b, "tool_use_id") {
                                let failed = b["is_error"] == true;
                                self.tool_done(id, failed, text_in(&b["content"]));
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
        let text = said.join("\n");
        if !text.trim().is_empty() {
            self.prompt(&text, at);
        }
    }

    fn claude_assistant(&mut self, content: &Value, at: Option<&str>) {
        let Value::Array(blocks) = content else {
            let text = text_in(content);
            if !text.is_empty() {
                self.push("agent", at, json!({"text": text}));
            }
            return;
        };
        for b in blocks {
            match str_at(b, "type") {
                Some("thinking") => {
                    if let Some(t) = str_at(b, "thinking") {
                        self.push("thought", at, json!({"text": t}));
                    }
                }
                Some("text") => {
                    if let Some(t) = str_at(b, "text") {
                        self.push("agent", at, json!({"text": t}));
                    }
                }
                Some("tool_use") => {
                    let name = str_at(b, "name").unwrap_or("tool");
                    let fields =
                        json!({"title": name, "status": "pending", "rawInput": b["input"]});
                    self.tool(str_at(b, "id"), at, fields);
                }
                _ => {}
            }
        }
    }

    // ---- Gemini CLI: a metadata line, then messages by id; `$set`, `$rewindTo` and `$patch` lines change them

    fn gemini(&mut self, v: &Value) {
        if let Some(to) = str_at(v, "$rewindTo") {
            if let Some(n) = self.msgs.iter().position(|m| m.id == to) {
                let start = self.msgs[n].start;
                self.msgs.truncate(n);
                self.entries.truncate(start);
                self.tools.retain(|_, i| *i < start);
            }
            return;
        }
        if let Some(set) = v.get("$set") {
            if let Some(s) = owned(set, "summary") {
                self.summary = Some(s);
            }
            self.stamp(str_at(set, "lastUpdated"));
            return;
        }
        if v.get("$patch").is_some() {
            return self.skip("$patch");
        }
        let Some(kind) = str_at(v, "type") else {
            // the metadata line (or an old file's head)
            if str_at(v, "sessionId").is_some() {
                self.id = owned(v, "sessionId");
                self.stamp(str_at(v, "startTime"));
                self.stamp(str_at(v, "lastUpdated"));
                if let Some(s) = owned(v, "summary") {
                    self.summary = Some(s);
                }
                if let Some(d) = v["directories"].get(0).and_then(Value::as_str) {
                    self.cwd = Some(d.to_owned());
                }
            } else {
                self.skip("unknown");
            }
            return;
        };
        let at = str_at(v, "timestamp");
        self.stamp(at);
        let id = str_at(v, "id").unwrap_or("").to_owned();
        // a message written again (a tool call's status, say) replaces the one before, when it is the last
        if !id.is_empty() && self.msgs.last().is_some_and(|m| m.id == id) {
            let m = self.msgs.pop().expect("checked");
            self.entries.truncate(m.start);
            self.tools.retain(|_, i| *i < m.start);
        }
        let start = self.entries.len();
        let text = text_in(&v["content"]);
        let mut prompt = None;
        match kind {
            "user" => {
                if !text.trim().is_empty() {
                    self.push("user", at, json!({"text": text}));
                    prompt = Some(title_of(&text).unwrap_or_default());
                }
            }
            "gemini" => {
                for t in v["thoughts"].as_array().into_iter().flatten() {
                    let said = match (str_at(t, "subject"), str_at(t, "description")) {
                        (Some(s), Some(d)) => format!("{s}: {d}"),
                        (s, d) => s.or(d).unwrap_or("").to_owned(),
                    };
                    self.push("thought", at, json!({"text": said}));
                }
                if !text.is_empty() {
                    self.push("agent", at, json!({"text": text}));
                }
                for c in v["toolCalls"].as_array().into_iter().flatten() {
                    let status = match str_at(c, "status") {
                        Some("success") => "completed",
                        Some("error" | "cancelled") => "failed",
                        _ => "pending",
                    };
                    let title = str_at(c, "displayName")
                        .or_else(|| str_at(c, "name"))
                        .unwrap_or("tool");
                    let output = gemini_output(&c["result"]);
                    let fields = json!({"title": title, "status": status, "rawInput": c["args"], "content": output});
                    self.tool(str_at(c, "id"), at, fields);
                }
            }
            "info" | "warning" => {
                self.push("notice", at, json!({"text": text}));
            }
            "error" => {
                self.push("error", at, json!({"text": text}));
            }
            other => self.skip(other),
        }
        self.msgs.push(Msg { id, start, prompt });
    }

    // ---- Codex: `{timestamp, type, payload}` lines (session_meta, response_item, event_msg, compacted, …); an old
    // file has bare items after a head line

    fn codex(&mut self, v: &Value) {
        let at = str_at(v, "timestamp");
        let Some(kind) = str_at(v, "type") else {
            if str_at(v, "record_type").is_some() {
                return self.skip(str_at(v, "record_type").unwrap_or("state"));
            }
            if str_at(v, "id").is_some() {
                return self.codex_meta(v);
            }
            return self.skip("unknown");
        };
        self.stamp(at);
        let p = &v["payload"];
        match kind {
            "session_meta" => self.codex_meta(p),
            "response_item" => self.codex_item(p, at),
            "compacted" => {
                let fields = match str_at(p, "message") {
                    Some(m) => json!({"text": m}),
                    None => json!({}),
                };
                self.push("compaction", at, fields);
            }
            // an old file's bare item
            "message"
            | "reasoning"
            | "function_call"
            | "function_call_output"
            | "custom_tool_call"
            | "custom_tool_call_output"
            | "local_shell_call" => self.codex_item(v, at),
            other => self.skip(other),
        }
    }

    fn codex_meta(&mut self, p: &Value) {
        if let Some(id) = owned(p, "id") {
            self.id = Some(id);
        }
        if let Some(c) = owned(p, "cwd") {
            self.cwd = Some(c);
        }
        if let Some(b) = owned(&p["git"], "branch") {
            self.branch = Some(b);
        }
        if let Some(t) = str_at(p, "timestamp") {
            self.started = Some(t.to_owned());
            if self.updated.is_none() {
                self.updated = Some(t.to_owned());
            }
        }
    }

    fn codex_item(&mut self, p: &Value, at: Option<&str>) {
        match str_at(p, "type").unwrap_or("unknown") {
            "message" => {
                let text = text_in(&p["content"]);
                match str_at(p, "role") {
                    // what the CLI tells the model about the machine, not the user's words
                    Some("user")
                        if text.trim_start().starts_with("<environment_context>")
                            || text.trim_start().starts_with("<user_instructions>") => {}
                    Some("user") if !text.trim().is_empty() => self.prompt(&text, at),
                    Some("assistant") if !text.is_empty() => {
                        self.push("agent", at, json!({"text": text}));
                    }
                    _ => {}
                }
            }
            "reasoning" => {
                let text = text_in(&p["summary"]);
                if !text.is_empty() {
                    self.push("thought", at, json!({"text": text}));
                }
            }
            "function_call" | "custom_tool_call" | "local_shell_call" => {
                let name = str_at(p, "name").unwrap_or("shell");
                let input = p
                    .get("arguments")
                    .or_else(|| p.get("input"))
                    .or_else(|| p.get("action"));
                let fields = json!({"title": name, "status": "pending", "rawInput": input.cloned().unwrap_or(Value::Null)});
                self.tool(str_at(p, "call_id"), at, fields);
            }
            "function_call_output" | "custom_tool_call_output" => {
                if let Some(id) = str_at(p, "call_id") {
                    let output = match &p["output"] {
                        Value::String(s) => s.clone(),
                        o => str_at(o, "content")
                            .map(str::to_owned)
                            .unwrap_or_else(|| text_in(o)),
                    };
                    self.tool_done(id, false, output);
                }
            }
            other => self.skip(&format!("response_item/{other}")),
        }
    }
}

/// A Gemini tool call's output: its function responses' `output` (or `error`), one per line.
fn gemini_output(result: &Value) -> String {
    result
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| {
            let resp = &r["functionResponse"]["response"];
            str_at(resp, "output").or_else(|| str_at(resp, "error"))
        })
        .collect::<Vec<_>>()
        .join("\n")
}
