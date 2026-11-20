//! A session's background work and its display terminals (ACP v2; `docs/develop/hub.md`, "Background work").
//!
//! Hermod turns v2's `state_update.background` into [`hermod::Event::State`], the terminals into
//! [`hermod::Event::Terminal`] and the children into [`hermod::Event::Subagent`]; this is what the hub keeps of them.
//! The list is v2's: a snapshot, replaced whole by the next one.  `None` is "the agent does not report it" (never
//! shown as nothing running), `Some(vec![])` is "nothing running".  A v1 session never gets one.

use hermod::{BackgroundRef, RunState, TerminalEv};
pub use runstav::methods::agents::{
    BackgroundEnd as End, BackgroundEndStatus as EndStatus, BackgroundItem as Item,
    BackgroundKind as ItemKind, BackgroundStatus as ItemStatus,
};
use serde_json::Value;
use std::collections::{HashMap, VecDeque};

/// The ended items kept per session (the transcript line of an end reads them).
pub const ENDED_CAP: usize = 20;
/// The bytes kept per terminal: the newest.
pub const TERMINAL_CAP: usize = 4 << 20;

#[derive(Default)]
pub struct Background {
    /// The references of the last snapshot: what runs is derived from them, as the hub knows each one now.
    refs: Option<Vec<BackgroundRef>>,
    /// What runs now: none while the agent does not report it.
    pub items: Option<Vec<Item>>,
    /// The last [`ENDED_CAP`] items that left the list, the newest last.
    pub ended: VecDeque<Item>,
    /// The agent said it cannot tell (`unknown`): nothing it listed is confirmed until its next state.
    unknown: bool,
}

impl Background {
    /// A snapshot REFS replaces the list whole.  LOOKUP gives the item for a reference as the hub knows it now: an
    /// item that left the list is looked up once more, and moves to `ended` with the end its tool call, terminal or
    /// child reported (none: it ended without saying how).
    pub fn apply_snapshot(
        &mut self,
        refs: Option<Vec<BackgroundRef>>,
        lookup: impl Fn(&BackgroundRef) -> Item,
    ) {
        self.unknown = false;
        let before = self.refs.take();
        let Some(refs) = refs else {
            // not reported: what ran before is neither running nor ended, as far as anyone knows
            self.items = None;
            return;
        };
        let now: Vec<Item> = refs.iter().map(&lookup).collect();
        for gone in before.iter().flatten() {
            let last = lookup(gone);
            if now.iter().any(|i| i.kind == last.kind && i.id == last.id) {
                continue;
            }
            self.ended.push_back(last);
            while self.ended.len() > ENDED_CAP {
                self.ended.pop_front();
            }
        }
        self.refs = Some(refs);
        self.items = Some(now);
    }

    /// The same list, its items read again (a terminal's output or a tool call's progress moved; the list did not).
    pub fn refresh(&mut self, lookup: impl Fn(&BackgroundRef) -> Item) {
        if let Some(refs) = &self.refs {
            self.items = Some(refs.iter().map(lookup).collect());
            if self.unknown {
                self.mark();
            }
        }
    }

    /// The agent cannot tell what it is doing (`unknown`): nothing it listed is confirmed.
    pub fn mark_unknown(&mut self) {
        self.unknown = true;
        self.mark();
    }

    fn mark(&mut self) {
        for i in self.items.iter_mut().flatten() {
            i.status = ItemStatus::Unknown;
        }
    }

    /// The running item with this id, when exactly one has it.
    pub fn find(&self, id: &str) -> Result<&Item, String> {
        let mut hits = self.items.iter().flatten().filter(|i| i.id == id);
        match (hits.next(), hits.next()) {
            (Some(i), None) => Ok(i),
            (Some(_), Some(_)) => Err(format!("`{id}` names more than one background item")),
            _ => Err(format!("`{id}` is not a running background item")),
        }
    }
}

/// One of drgnx's own jobs (`exec/start`) as an item: a process the hub runs, which its Stop Job ends.
pub fn job_item(id: &str, label: &str, started_ms: u64) -> Item {
    Item {
        kind: ItemKind::Terminal,
        id: id.to_string(),
        description: label.to_string(),
        started_ms,
        progress: None,
        status: ItemStatus::Running,
        end: None,
        can_cancel: true,
    }
}

/// Where a cancel of an item goes.
#[derive(Debug, PartialEq, Eq)]
pub enum Route {
    Terminal(String),
    ToolCall(String),
    Subagent(String),
    /// One of drgnx's own jobs: the job's stop.
    Job(String),
}

#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
    NotCancellable,
}

/// The request that cancels ITEM (OWN_JOB: it is one of the hub's own jobs).  An item that does not advertise cancel,
/// or has ended, is never sent one.
pub fn route_cancel(i: &Item, own_job: bool) -> Result<Route, Refusal> {
    if !i.can_cancel || i.end.is_some() {
        return Err(Refusal::NotCancellable);
    }
    let id = i.id.clone();
    Ok(match (own_job, i.kind) {
        (true, _) => Route::Job(id),
        (false, ItemKind::Terminal) => Route::Terminal(id),
        (false, ItemKind::ToolCall) => Route::ToolCall(id),
        (false, ItemKind::Subagent) => Route::Subagent(id),
    })
}

/// What the hub knows of a tool call, a terminal or a child, to describe the items that name them.
#[derive(Default)]
pub struct Known {
    pub tools: HashMap<String, Tool>,
    pub terminals: Terminals,
    pub children: HashMap<String, Child>,
}

#[derive(Default, Clone)]
pub struct Tool {
    pub title: String,
    /// The v2 status as the agent sent it (`pending`, `in_progress`, `paused`, `completed`, `failed`, `cancelled`).
    pub status: Option<String>,
    pub can_cancel: bool,
    pub progress: Option<String>,
    pub started_ms: u64,
}

#[derive(Default, Clone)]
pub struct Child {
    pub title: String,
    pub can_cancel: bool,
    /// The child's last foreground state (`running`, `idle`, …) and its stop reason.
    pub state: Option<(String, Option<String>)>,
    pub started_ms: u64,
}

impl Known {
    /// A tool call's update as the v1 shape the hub reads has it (`_meta._hermod/*`: the real status and `cancel`).
    pub fn tool(&mut self, u: &Value, now_ms: u64) {
        let Some(id) = u.get("toolCallId").and_then(Value::as_str) else {
            return;
        };
        let t = self.tools.entry(id.to_string()).or_insert_with(|| Tool {
            started_ms: now_ms,
            ..Tool::default()
        });
        if let Some(s) = u.get("title").and_then(Value::as_str) {
            t.title = s.to_string();
        }
        if let Some(s) = u
            .get("_meta")
            .and_then(|m| m.get("_hermod/status"))
            .and_then(Value::as_str)
        {
            t.status = Some(s.to_string());
        } else if let Some(s) = u.get("status").and_then(Value::as_str) {
            t.status = Some(s.to_string());
        }
        if let Some(c) = u
            .get("_meta")
            .and_then(|m| m.get("_hermod/can_cancel"))
            .and_then(Value::as_bool)
        {
            t.can_cancel = c;
        }
        if let Some(line) = u.get("content").and_then(last_line) {
            t.progress = Some(line);
        }
    }

    /// A `subagent_update` (the raw v2 update).
    pub fn subagent(&mut self, u: &Value, now_ms: u64) {
        let Some(id) = u.get("sessionId").and_then(Value::as_str) else {
            return;
        };
        let c = self
            .children
            .entry(id.to_string())
            .or_insert_with(|| Child {
                started_ms: now_ms,
                ..Child::default()
            });
        if let Some(t) = u.get("title").and_then(Value::as_str) {
            c.title = t.to_string();
        } else if c.title.is_empty()
            && let Some(d) = u.get("description").and_then(Value::as_str)
        {
            c.title = d.to_string();
        }
        if let Some(caps) = u.get("capabilities") {
            c.can_cancel = caps.get("cancel").is_some_and(|v| !v.is_null());
        }
        if let Some(s) = u.get("state").filter(|s| s.is_object()) {
            c.state = state_of(s);
        }
    }

    /// A child's own `state_update`.
    pub fn child_state(&mut self, child: &str, state: &RunState) {
        if let Some(c) = self.children.get_mut(child) {
            c.state = Some(match state {
                RunState::Running => ("running".into(), None),
                RunState::RequiresAction => ("requires_action".into(), None),
                RunState::Idle(stop) => (
                    "idle".into(),
                    stop.and_then(|s| {
                        serde_json::to_value(s)
                            .ok()
                            .and_then(|v| v.as_str().map(String::from))
                    }),
                ),
                RunState::Unknown => ("unknown".into(), None),
            });
        }
    }

    /// Whether SID is a child session this session announced.
    pub fn is_child(&self, sid: &str) -> bool {
        self.children.contains_key(sid)
    }

    /// The item for a reference, as the hub knows it now.
    pub fn item(&self, r: &BackgroundRef) -> Item {
        match r {
            BackgroundRef::Terminal(id) => {
                let t = self.terminals.get(id);
                let end = t.and_then(|t| t.exit.as_ref()).map(|(code, signal)| End {
                    status: match (code, signal.as_deref()) {
                        (Some(0), None) => EndStatus::Completed,
                        (None, Some("SIGTERM" | "SIGINT" | "SIGKILL")) => EndStatus::Stopped,
                        _ => EndStatus::Failed,
                    },
                    summary: signal.clone(),
                    exit_code: *code,
                });
                Item {
                    kind: ItemKind::Terminal,
                    id: id.clone(),
                    description: t.and_then(|t| t.command.clone()).unwrap_or_default(),
                    started_ms: t.map_or(0, |t| t.started_ms),
                    progress: t.and_then(|t| last_line_of(&t.bytes)),
                    status: ItemStatus::Running,
                    can_cancel: end.is_none() && t.is_some_and(|t| t.can_cancel),
                    end,
                }
            }
            BackgroundRef::ToolCall(id) => {
                let known = self.tools.contains_key(id);
                let t = self.tools.get(id).cloned().unwrap_or_default();
                let (status, end) = match t.status.as_deref() {
                    Some("in_progress") => (ItemStatus::Running, None),
                    Some("paused") => (ItemStatus::Paused, None),
                    Some("pending") => (ItemStatus::Pending, None),
                    Some("completed") => (ItemStatus::Running, Some(EndStatus::Completed)),
                    Some("failed") => (ItemStatus::Running, Some(EndStatus::Failed)),
                    Some("cancelled") => (ItemStatus::Running, Some(EndStatus::Stopped)),
                    // a status this code does not know: still in progress, as the protocol says
                    Some(_) => (ItemStatus::Running, None),
                    None => (ItemStatus::Unknown, None),
                };
                Item {
                    kind: ItemKind::ToolCall,
                    id: id.clone(),
                    description: t.title,
                    started_ms: t.started_ms,
                    progress: t.progress.clone(),
                    status,
                    can_cancel: known && t.can_cancel && end.is_none(),
                    end: end.map(|status| End {
                        status,
                        summary: t.progress,
                        exit_code: None,
                    }),
                }
            }
            BackgroundRef::Subagent(id) => {
                let c = self.children.get(&*id.0).cloned();
                let known = c.is_some();
                let c = c.unwrap_or_default();
                let status = match &c.state {
                    Some((s, _)) if s == "unknown" => ItemStatus::Unknown,
                    None if !known => ItemStatus::Unknown,
                    _ => ItemStatus::Running,
                };
                let end = match &c.state {
                    Some((s, stop)) if s == "idle" => Some(match stop.as_deref() {
                        Some("cancelled") => EndStatus::Stopped,
                        Some("error" | "refusal" | "max_tokens" | "max_turn_requests") => {
                            EndStatus::Failed
                        }
                        _ => EndStatus::Completed,
                    }),
                    _ => None,
                };
                Item {
                    kind: ItemKind::Subagent,
                    id: id.0.to_string(),
                    description: c.title,
                    started_ms: c.started_ms,
                    progress: None,
                    status,
                    end: end.map(|status| End {
                        status,
                        summary: None,
                        exit_code: None,
                    }),
                    // an idle child is not stopped by a cancel: nothing of its foreground runs
                    can_cancel: c.can_cancel,
                }
            }
            BackgroundRef::Other(v) => Item {
                kind: ItemKind::ToolCall,
                id: v
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or("?")
                    .to_string(),
                description: v
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or("background work")
                    .to_string(),
                started_ms: 0,
                progress: None,
                status: ItemStatus::Unknown,
                end: None,
                can_cancel: false,
            },
        }
    }
}

fn state_of(s: &Value) -> Option<(String, Option<String>)> {
    Some((
        s.get("state")?.as_str()?.to_string(),
        s.get("stopReason")
            .and_then(Value::as_str)
            .map(String::from),
    ))
}

/// The last non-empty line of a tool call's text content.
fn last_line(content: &Value) -> Option<String> {
    let text: String = content
        .as_array()?
        .iter()
        .filter_map(|c| c.pointer("/content/text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    text.lines()
        .rev()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map(|l| l.chars().take(200).collect())
}

/// The last non-empty line of a terminal's output.
fn last_line_of(bytes: &[u8]) -> Option<String> {
    // only the tail is read: a 4 MiB terminal must not be decoded per snapshot
    let tail = &bytes[bytes.len().saturating_sub(2048)..];
    String::from_utf8_lossy(tail)
        .lines()
        .rev()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map(|l| l.chars().take(200).collect())
}

/// The display terminals of a session: their command and their output, the newest [`TERMINAL_CAP`] bytes.
#[derive(Default)]
pub struct Terminals {
    map: HashMap<String, Terminal>,
}

#[derive(Default)]
pub struct Terminal {
    pub command: Option<String>,
    pub bytes: Vec<u8>,
    /// The exit code and signal, once it exited.
    pub exit: Option<(Option<i32>, Option<String>)>,
    pub can_cancel: bool,
    pub started_ms: u64,
}

impl Terminals {
    pub fn get(&self, id: &str) -> Option<&Terminal> {
        self.map.get(id)
    }

    fn entry(&mut self, id: &str, now_ms: u64) -> &mut Terminal {
        self.map.entry(id.to_string()).or_insert_with(|| Terminal {
            started_ms: now_ms,
            ..Terminal::default()
        })
    }

    /// Output bytes appended, in the order they arrive (a chunk may end inside a UTF-8 sequence: bytes, not text).
    pub fn chunk(&mut self, id: &str, bytes: &[u8], now_ms: u64) {
        let t = self.entry(id, now_ms);
        t.bytes.extend_from_slice(bytes);
        cap(&mut t.bytes);
    }

    /// A terminal's update: a field the agent sent replaces ours; a snapshot replaces the output.
    pub fn update(&mut self, id: &str, u: TerminalEv, now_ms: u64) {
        match u {
            TerminalEv::Chunk(b) => self.chunk(id, &b, now_ms),
            TerminalEv::Update {
                command,
                cwd: _,
                snapshot,
                exit,
                can_cancel,
            } => {
                let t = self.entry(id, now_ms);
                t.command = command.or(t.command.take());
                if let Some(s) = snapshot {
                    t.bytes = s;
                    cap(&mut t.bytes);
                }
                t.exit = exit.or(t.exit.take());
                if let Some(c) = can_cancel {
                    t.can_cancel = c;
                }
            }
        }
    }
}

fn cap(bytes: &mut Vec<u8>) {
    if bytes.len() > TERMINAL_CAP {
        let over = bytes.len() - TERMINAL_CAP;
        bytes.drain(..over);
    }
}
