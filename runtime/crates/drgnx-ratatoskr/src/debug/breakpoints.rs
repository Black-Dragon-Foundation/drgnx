//! The breakpoint store (spec §4, §11): one per project, kept in the hub's state directory.
//!
//! The editors change it by operations on a breakpoint's id (`Op`), so two editors toggling one file never undo each
//! other: adding a line that already has a breakpoint gives that one, and removing or editing one that is gone is no
//! change. Each file has a version that goes up on every change. A breakpoint's line is the saved line: the editor
//! keeps a moved line as a draft and sends `Op::Move` on save.
//!
//! Each session's adapter answers `setBreakpoints` with its own `Breakpoint`s; the store keeps what each session made
//! of each breakpoint (its adapter id, verified, message, line) and shows a breakpoint verified when any session
//! verified it. Conditions, hit counts and log messages reach an adapter only when its capabilities say it takes them
//! ([`fit`]); the store keeps them and marks them unsupported for that session. Run to Cursor's breakpoint belongs to
//! one session, is never shown or saved, and goes at that session's next stop or end.
//!
//! An inline breakpoint has a column: in characters for the editors, in UTF-16 units (1-based) for the adapters
//! ([`Col`], turned by [`col_of`] from the line's text when it is set). Breakpoints at two columns of one line, or one
//! with a column and one without, are separate breakpoints.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

/// An editor's change to the store.
#[derive(Clone, Debug, PartialEq)]
pub enum Op {
    /// A breakpoint on PATH's LINE, at COLUMN when given (the one already there, if any).
    Add {
        path: String,
        line: u32,
        column: Option<Col>,
        enabled: bool,
        condition: Option<String>,
        hit: Option<String>,
        log: Option<String>,
    },
    Remove {
        id: u64,
    },
    /// The fields given; an empty text clears that field.
    Edit {
        id: u64,
        enabled: Option<bool>,
        condition: Option<String>,
        hit: Option<String>,
        log: Option<String>,
    },
    /// The breakpoint's line after a save or a drag; its column when given, else the one it had.
    Move {
        id: u64,
        line: u32,
        column: Option<Col>,
    },
    AddFunction {
        name: String,
        condition: Option<String>,
    },
    RemoveFunction {
        name: String,
    },
    /// ID is triggered by breakpoint BY (none: a plain breakpoint again).
    Trigger {
        id: u64,
        by: Option<u64>,
    },
}

/// An inline breakpoint's column, 1-based: in characters (the editors') and in UTF-16 units (the adapters').
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Col {
    pub chars: u32,
    pub utf16: u32,
}

/// Character column CHARS of a line with TEXT (none: unknown, one unit a character), with its UTF-16 column.
pub fn col_of(text: Option<&str>, chars: u32) -> Col {
    let before = chars.saturating_sub(1) as usize;
    let mut units = 0;
    let mut seen = 0;
    for c in text.unwrap_or_default().chars().take(before) {
        units += c.len_utf16();
        seen += 1;
    }
    Col {
        chars,
        utf16: (units + (before - seen) + 1) as u32,
    }
}

/// The character column of UTF-16 column UTF16 of a line with TEXT (none: one unit a character).
pub fn chars_of(text: Option<&str>, utf16: u32) -> u32 {
    let mut left = utf16.saturating_sub(1) as usize;
    let mut chars = 0;
    for c in text.unwrap_or_default().chars() {
        if left == 0 {
            break;
        }
        left = left.saturating_sub(c.len_utf16());
        chars += 1;
    }
    (chars + left + 1) as u32
}

/// A data breakpoint (Break on Value Change): the adapter's DATA_ID for a variable, as `dataBreakpointInfo` gave it.
#[derive(Clone, Debug, PartialEq)]
pub struct DataBp {
    pub data_id: String,
    pub description: String,
    pub access_type: Option<String>,
}

/// An instruction breakpoint: the session's own, at memory reference INSTRUCTION plus OFFSET bytes, numbered N in
/// its session.
#[derive(Clone, Debug, PartialEq)]
pub struct InstrBp {
    pub n: u64,
    pub instruction: String,
    pub offset: Option<i64>,
    pub condition: Option<String>,
    pub hit: Option<String>,
    pub enabled: bool,
}

/// A change to a session's instruction breakpoints: an empty text clears a condition or hit count.
#[derive(Clone, Debug, PartialEq)]
pub enum InstrOp {
    Add {
        instruction: String,
        offset: Option<i64>,
        condition: Option<String>,
        hit: Option<String>,
    },
    Remove {
        n: u64,
    },
    Edit {
        n: u64,
        enabled: Option<bool>,
        condition: Option<String>,
        hit: Option<String>,
    },
}

/// A session's instruction breakpoints: the last number given, the view's version, the list in the order sent.
#[derive(Default)]
struct Instrs {
    last: u64,
    version: u64,
    list: Vec<(InstrBp, Bound)>,
}

/// What an operation changed: PATH's new VERSION (an empty path for function breakpoints), and the breakpoint's ID
/// when it added one.
#[derive(Clone, Debug, PartialEq)]
pub struct Change {
    pub path: String,
    pub version: u64,
    pub id: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct Bp {
    id: u64,
    line: u32,
    /// An inline breakpoint's column in characters, and in UTF-16 units as the adapters get it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    column: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    column_utf16: Option<u32>,
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    condition: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    hit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    log: Option<String>,
    /// The agent session that set it (D4: the editor rings it); none for the user's own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    agent: Option<String>,
    /// A triggered breakpoint: sent to a session only once it has stopped on this breakpoint.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    triggered_by: Option<u64>,
}

fn yes() -> bool {
    true
}

fn is_true(b: &bool) -> bool {
    *b
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct File {
    version: u64,
    bps: Vec<Bp>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct FnBp {
    name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    condition: Option<String>,
}

/// What is saved.
#[derive(Debug, Default, Serialize, Deserialize)]
struct Data {
    next: u64,
    files: BTreeMap<String, File>,
    #[serde(default)]
    functions: Vec<FnBp>,
    /// The exception filters chosen, per adapter type.
    #[serde(default)]
    filters: BTreeMap<String, Vec<String>>,
    /// The Run and Debug view's watch expressions, in order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    watches: Vec<String>,
}

/// What one session's adapter made of a breakpoint.
#[derive(Clone, Debug, Default)]
struct Bound {
    adapter_id: Option<i64>,
    verified: bool,
    message: Option<String>,
    line: Option<u32>,
}

struct Temp {
    session: String,
    path: String,
    line: u32,
}

/// One project's breakpoints.
pub struct Store {
    file: Option<PathBuf>,
    /// The file's writes, in order, off the hub's workers (with a file).
    disk: Option<std::sync::Arc<crate::disk::Ordered>>,
    data: Data,
    /// (session, path) → the ids last sent, in the order sent (`answer` reads the adapter's answer in that order).
    sent: BTreeMap<(String, String), Vec<u64>>,
    bound: BTreeMap<(String, u64), Bound>,
    temps: Vec<Temp>,
    caps: BTreeMap<String, Value>,
    /// (session, triggered breakpoint) that session has stopped on the trigger of.
    armed: BTreeSet<(String, u64)>,
    /// Paths changed beyond the one an operation answers with ([`Store::drain_touched`]).
    touched: BTreeSet<String>,
    /// Each session's data breakpoints, in the order sent, with what its adapter made of them.
    datas: BTreeMap<String, Vec<(DataBp, Bound)>>,
    /// Each session's instruction breakpoints: in memory only, gone with the session.
    instrs: BTreeMap<String, Instrs>,
}

/// BPS (`SourceBreakpoint`s) as an adapter with CAPS takes them: without the fields it does not support. A probe
/// (`super::probes`) is left out where there are no logpoints: it would stop the program.
pub fn fit(bps: &[Value], caps: &Value) -> Vec<Value> {
    let has = |k: &str| caps.get(k).and_then(Value::as_bool).unwrap_or(false);
    let probe = |b: &Value| {
        b.get("logMessage")
            .and_then(Value::as_str)
            .is_some_and(|m| m.starts_with(super::probes::MARK))
    };
    bps.iter()
        .filter(|b| has("supportsLogPoints") || !probe(b))
        .map(|b| {
            let mut b = b.clone();
            if let Some(o) = b.as_object_mut() {
                for (field, cap) in FIELDS {
                    if !has(cap) {
                        o.remove(*field);
                    }
                }
            }
            b
        })
        .collect()
}

/// The exception filters an adapter with CAPS turns on by default.
pub fn default_filters(caps: &Value) -> Vec<String> {
    caps.get("exceptionBreakpointFilters")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter(|f| f.get("default").and_then(Value::as_bool).unwrap_or(false))
                .filter_map(|f| f.get("filter").and_then(Value::as_str).map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

/// The `SourceBreakpoint` fields that need a capability, and the name the editor shows for each.
const FIELDS: &[(&str, &str)] = &[
    ("condition", "supportsConditionalBreakpoints"),
    ("hitCondition", "supportsHitConditionalBreakpoints"),
    ("logMessage", "supportsLogPoints"),
];

fn shown(field: &str) -> &'static str {
    match field {
        "condition" => "condition",
        "hitCondition" => "hit",
        _ => "log",
    }
}

fn source_bp(line: u32, b: Option<&Bp>) -> Value {
    let mut o = Map::new();
    o.insert("line".into(), json!(line));
    if let Some(c) = b.and_then(|b| b.column_utf16) {
        o.insert("column".into(), json!(c));
    }
    if let Some(b) = b {
        for (k, v) in [
            ("condition", &b.condition),
            ("hitCondition", &b.hit),
            ("logMessage", &b.log),
        ] {
            if let Some(v) = v {
                o.insert(k.into(), json!(v));
            }
        }
    }
    Value::Object(o)
}

fn text(v: Option<String>) -> Option<Option<String>> {
    v.map(|t| if t.is_empty() { None } else { Some(t) })
}

impl Store {
    /// The store saved in FILE (none: kept in memory only). A file that cannot be read is moved aside to
    /// `FILE.damaged` and the store starts empty.
    pub fn open(file: Option<PathBuf>) -> Store {
        let data = match &file {
            Some(f) => match std::fs::read_to_string(f) {
                Ok(t) => serde_json::from_str(&t).unwrap_or_else(|e| {
                    tracing::warn!(target: "drgnx::debug", "breakpoints {}: {e}; kept aside", f.display());
                    let mut aside = f.as_os_str().to_owned();
                    aside.push(".damaged");
                    let _ = std::fs::rename(f, PathBuf::from(aside));
                    Data::default()
                }),
                Err(_) => Data::default(),
            },
            None => Data::default(),
        };
        Store {
            disk: file.as_ref().map(|_| {
                std::sync::Arc::new(crate::disk::Ordered::reporting(
                    "debug:breakpoints",
                    |what, e| tracing::warn!(target: "drgnx::debug", "{what}: {e}"),
                ))
            }),
            file,
            data,
            sent: BTreeMap::new(),
            bound: BTreeMap::new(),
            temps: Vec::new(),
            caps: BTreeMap::new(),
            armed: BTreeSet::new(),
            touched: BTreeSet::new(),
            datas: BTreeMap::new(),
            instrs: BTreeMap::new(),
        }
    }

    /// The store as it is now, queued for its file: written in order off the hub's workers (`crate::disk`).
    fn save(&self) {
        let (Some(f), Some(disk)) = (&self.file, &self.disk) else {
            return;
        };
        let text = serde_json::to_string(&self.data).unwrap_or_default();
        let f = f.clone();
        disk.push(format!("breakpoints {}", f.display()), move || {
            if let Some(dir) = f.parent() {
                std::fs::create_dir_all(dir)?;
            }
            crate::records::write_atomic(&f, &text)
        });
    }

    /// The file's writer: its `written` is every save so far landed (none: no file).
    pub(crate) fn disk(&self) -> Option<std::sync::Arc<crate::disk::Ordered>> {
        self.disk.clone()
    }

    /// Breakpoint ID is agent session AGENT's (D4): its path, when there is one.
    pub fn mark(&mut self, id: u64, agent: &str) -> Option<String> {
        let (path, i) = self.find(id)?;
        self.data.files.get_mut(&path)?.bps[i].agent = Some(agent.to_owned());
        self.save();
        Some(path)
    }

    /// The agent session breakpoint ID is of (none: the user's, or no such breakpoint).
    pub fn owner(&self, id: u64) -> Option<String> {
        let (path, i) = self.find(id)?;
        self.data.files.get(&path)?.bps[i].agent.clone()
    }

    /// The breakpoint at PATH's LINE and COLUMN (characters; none: the line's breakpoint without a column).
    pub fn at(&self, path: &str, line: u32, column: Option<u32>) -> Option<u64> {
        self.data
            .files
            .get(path)?
            .bps
            .iter()
            .find(|b| b.line == line && b.column == column)
            .map(|b| b.id)
    }

    /// Breakpoint ID's path.
    pub fn path_of(&self, id: u64) -> Option<String> {
        self.find(id).map(|(p, _)| p)
    }

    fn find(&self, id: u64) -> Option<(String, usize)> {
        self.data.files.iter().find_map(|(p, f)| {
            f.bps
                .iter()
                .position(|b| b.id == id)
                .map(|i| (p.clone(), i))
        })
    }

    fn bump(&mut self, path: &str, id: Option<u64>) -> Option<Change> {
        let f = self.data.files.entry(path.to_owned()).or_default();
        f.version += 1;
        let version = f.version;
        self.save();
        Some(Change {
            path: path.to_owned(),
            version,
            id,
        })
    }

    /// Apply OP; what changed, or nothing.
    pub fn apply(&mut self, op: Op) -> Option<Change> {
        match op {
            Op::Add {
                path,
                line,
                column,
                enabled,
                condition,
                hit,
                log,
            } => {
                let f = self.data.files.entry(path.clone()).or_default();
                let chars = column.map(|c| c.chars);
                if f.bps.iter().any(|b| b.line == line && b.column == chars) {
                    return None;
                }
                self.data.next += 1;
                let id = self.data.next;
                let none = |t: Option<String>| t.filter(|t| !t.is_empty());
                f.bps.push(Bp {
                    id,
                    line,
                    column: chars,
                    column_utf16: column.map(|c| c.utf16),
                    enabled,
                    condition: none(condition),
                    hit: none(hit),
                    log: none(log),
                    agent: None,
                    triggered_by: None,
                });
                self.bump(&path, Some(id))
            }
            Op::Remove { id } => {
                let (path, i) = self.find(id)?;
                self.data.files.get_mut(&path)?.bps.remove(i);
                // what it triggered waits for nothing now
                let held: Vec<String> = self
                    .data
                    .files
                    .iter_mut()
                    .filter_map(|(p, f)| {
                        let mut any = false;
                        for b in f.bps.iter_mut().filter(|b| b.triggered_by == Some(id)) {
                            b.triggered_by = None;
                            any = true;
                        }
                        any.then(|| p.clone())
                    })
                    .collect();
                self.armed.retain(|(_, b)| *b != id);
                for p in held.iter().filter(|p| **p != path) {
                    let f = self.data.files.entry(p.clone()).or_default();
                    f.version += 1;
                    self.touched.insert(p.clone());
                }
                self.touched.insert(path.clone());
                self.bump(&path, None)
            }
            Op::Edit {
                id,
                enabled,
                condition,
                hit,
                log,
            } => {
                let (path, i) = self.find(id)?;
                let b = &mut self.data.files.get_mut(&path)?.bps[i];
                let old = b.clone();
                if let Some(e) = enabled {
                    b.enabled = e;
                }
                if let Some(c) = text(condition) {
                    b.condition = c;
                }
                if let Some(h) = text(hit) {
                    b.hit = h;
                }
                if let Some(l) = text(log) {
                    b.log = l;
                }
                if *b == old {
                    return None;
                }
                self.bump(&path, None)
            }
            Op::Move { id, line, column } => {
                let (path, i) = self.find(id)?;
                let b = &mut self.data.files.get_mut(&path)?.bps[i];
                let col = column.map(|c| (Some(c.chars), Some(c.utf16)));
                if b.line == line && col.is_none_or(|c| c == (b.column, b.column_utf16)) {
                    return None;
                }
                b.line = line;
                if let Some((chars, utf16)) = col {
                    b.column = chars;
                    b.column_utf16 = utf16;
                }
                self.bump(&path, None)
            }
            Op::AddFunction { name, condition } => {
                let f = FnBp {
                    name,
                    condition: condition.filter(|c| !c.is_empty()),
                };
                if self.data.functions.contains(&f) {
                    return None;
                }
                self.data.functions.retain(|g| g.name != f.name);
                self.data.functions.push(f);
                self.save();
                Some(Change {
                    path: String::new(),
                    version: 0,
                    id: None,
                })
            }
            Op::Trigger { id, by } => {
                if let Some(t) = by
                    && (t == id || self.find(t).is_none())
                {
                    return None;
                }
                let (path, i) = self.find(id)?;
                let b = &mut self.data.files.get_mut(&path)?.bps[i];
                if b.triggered_by == by {
                    return None;
                }
                b.triggered_by = by;
                self.armed.retain(|(_, x)| *x != id);
                self.bump(&path, None)
            }
            Op::RemoveFunction { name } => {
                let before = self.data.functions.len();
                self.data.functions.retain(|g| g.name != name);
                if self.data.functions.len() == before {
                    return None;
                }
                self.save();
                Some(Change {
                    path: String::new(),
                    version: 0,
                    id: None,
                })
            }
        }
    }

    /// SESSION stopped on its adapter's breakpoints HIT (`hitBreakpointIds`): the breakpoints they trigger are armed
    /// for SESSION; the paths to send it again.
    pub fn hit(&mut self, session: &str, hit: &[i64]) -> Vec<String> {
        let ids: BTreeSet<u64> = self
            .bound
            .iter()
            .filter(|((s, _), v)| s == session && v.adapter_id.is_some_and(|a| hit.contains(&a)))
            .map(|((_, id), _)| *id)
            .collect();
        let mut paths = BTreeSet::new();
        for (p, f) in &self.data.files {
            for b in &f.bps {
                if b.triggered_by.is_some_and(|t| ids.contains(&t))
                    && self.armed.insert((session.to_owned(), b.id))
                {
                    paths.insert(p.clone());
                }
            }
        }
        paths.into_iter().collect()
    }

    /// The paths changed since the last call, beyond the one each operation answered with (a removed trigger's).
    pub fn drain_touched(&mut self) -> Vec<String> {
        std::mem::take(&mut self.touched).into_iter().collect()
    }

    /// SESSION's data breakpoint BP added (false: it has it).
    pub fn data_add(&mut self, session: &str, bp: DataBp) -> bool {
        let list = self.datas.entry(session.to_owned()).or_default();
        if list.iter().any(|(d, _)| d.data_id == bp.data_id) {
            return false;
        }
        list.push((bp, Bound::default()));
        true
    }

    /// SESSION's data breakpoint DATA_ID removed (false: it had none).
    pub fn data_remove(&mut self, session: &str, data_id: &str) -> bool {
        let Some(list) = self.datas.get_mut(session) else {
            return false;
        };
        let before = list.len();
        list.retain(|(d, _)| d.data_id != data_id);
        before != list.len()
    }

    /// OP on SESSION's instruction breakpoints; refused for a number it does not have.
    pub fn instr_op(&mut self, session: &str, op: InstrOp) -> Result<(), String> {
        let set = self.instrs.entry(session.to_owned()).or_default();
        let text = |t: Option<String>| t.filter(|t| !t.is_empty());
        match op {
            InstrOp::Add {
                instruction,
                offset,
                condition,
                hit,
            } => {
                set.last += 1;
                let bp = InstrBp {
                    n: set.last,
                    instruction,
                    offset: offset.filter(|o| *o != 0),
                    condition: text(condition),
                    hit: text(hit),
                    enabled: true,
                };
                set.list.push((bp, Bound::default()));
            }
            InstrOp::Remove { n } => {
                let before = set.list.len();
                set.list.retain(|(b, _)| b.n != n);
                if before == set.list.len() {
                    return Err(format!("no instruction breakpoint {n}"));
                }
            }
            InstrOp::Edit {
                n,
                enabled,
                condition,
                hit,
            } => {
                let (b, _) = set
                    .list
                    .iter_mut()
                    .find(|(b, _)| b.n == n)
                    .ok_or_else(|| format!("no instruction breakpoint {n}"))?;
                if let Some(e) = enabled {
                    b.enabled = e;
                }
                if condition.is_some() {
                    b.condition = text(condition);
                }
                if hit.is_some() {
                    b.hit = text(hit);
                }
            }
        }
        set.version += 1;
        Ok(())
    }

    /// What `setInstructionBreakpoints` sends SESSION (its enabled ones, in order) for an adapter with CAPS.
    pub fn instr_list(&self, session: &str, caps: &Value) -> Vec<Value> {
        let list: Vec<Value> = self
            .instrs
            .get(session)
            .into_iter()
            .flat_map(|s| &s.list)
            .filter(|(b, _)| b.enabled)
            .map(|(b, _)| {
                let mut o = json!({"instructionReference": b.instruction});
                if let Some(off) = b.offset {
                    o["offset"] = json!(off);
                }
                if let Some(c) = &b.condition {
                    o["condition"] = json!(c);
                }
                if let Some(h) = &b.hit {
                    o["hitCondition"] = json!(h);
                }
                o
            })
            .collect();
        fit(&list, caps)
    }

    /// SESSION's adapter answered `setInstructionBreakpoints` with BPS, in the order sent; a disabled one is unbound.
    pub fn instr_answer(&mut self, session: &str, bps: &[Value]) {
        let Some(set) = self.instrs.get_mut(session) else {
            return;
        };
        let mut got = bps.iter();
        for (b, bound) in &mut set.list {
            *bound = Bound::default();
            if !b.enabled {
                continue;
            }
            if let Some(a) = got.next() {
                bound.verified = a.get("verified").and_then(Value::as_bool).unwrap_or(false);
                bound.message = a.get("message").and_then(Value::as_str).map(str::to_owned);
            }
        }
        set.version += 1;
    }

    /// SESSION's instruction breakpoints as the editor shows them: `{session, version, breakpoints: [{id: "i:S:N", n,
    /// kind: "instruction", instruction, offset?, verified, enabled, condition?, hit?, message?}]}`.
    pub fn instr_view(&self, session: &str) -> Value {
        let set = self.instrs.get(session);
        let bps: Vec<Value> = set
            .into_iter()
            .flat_map(|s| &s.list)
            .map(|(b, bound)| {
                let mut o = json!({
                    "id": format!("i:{session}:{}", b.n),
                    "n": b.n,
                    "kind": "instruction",
                    "instruction": b.instruction,
                    "verified": bound.verified,
                    "enabled": b.enabled,
                });
                for (k, v) in [
                    ("condition", &b.condition),
                    ("hit", &b.hit),
                    ("message", &bound.message),
                ] {
                    if let Some(v) = v {
                        o[k] = json!(v);
                    }
                }
                if let Some(off) = b.offset {
                    o["offset"] = json!(off);
                }
                o
            })
            .collect();
        json!({
            "session": session,
            "version": set.map_or(0, |s| s.version),
            "breakpoints": bps,
        })
    }

    /// What `setDataBreakpoints` sends SESSION, in order.
    pub fn data_list(&self, session: &str) -> Vec<Value> {
        self.datas
            .get(session)
            .into_iter()
            .flatten()
            .map(|(d, _)| {
                let mut o = json!({"dataId": d.data_id});
                if let Some(a) = &d.access_type {
                    o["accessType"] = json!(a);
                }
                o
            })
            .collect()
    }

    /// SESSION's adapter answered `setDataBreakpoints` with BPS, in the order sent.
    pub fn data_answer(&mut self, session: &str, bps: &[Value]) {
        for ((_, bound), b) in self.datas.get_mut(session).into_iter().flatten().zip(bps) {
            *bound = Bound::default();
            bound.verified = b.get("verified").and_then(Value::as_bool).unwrap_or(false);
            bound.message = b.get("message").and_then(Value::as_str).map(str::to_owned);
        }
    }

    /// Every session's data breakpoints as the view shows them: (session, `{data_id, description, access_type?,
    /// verified, message?}`).
    pub fn data_view(&self) -> Vec<(String, Value)> {
        self.datas
            .iter()
            .flat_map(|(s, list)| {
                list.iter().map(move |(d, b)| {
                    let mut o = json!({
                        "data_id": d.data_id,
                        "description": d.description,
                        "verified": b.verified,
                    });
                    if let Some(a) = &d.access_type {
                        o["access_type"] = json!(a);
                    }
                    if let Some(m) = &b.message {
                        o["message"] = json!(m);
                    }
                    (s.clone(), o)
                })
            })
            .collect()
    }

    /// PATH's version (0: never had a breakpoint).
    pub fn version(&self, path: &str) -> u64 {
        self.data.files.get(path).map_or(0, |f| f.version)
    }

    /// The files that have breakpoints.
    pub fn paths(&self) -> Vec<String> {
        self.data
            .files
            .iter()
            .filter(|(_, f)| !f.bps.is_empty())
            .map(|(p, _)| p.clone())
            .collect()
    }

    /// The paths with a breakpoint for SESSION: the user's and SESSION's Run to Cursor.
    pub fn paths_for(&self, session: &str) -> Vec<String> {
        let mut out: BTreeSet<String> = self.paths().into_iter().collect();
        out.extend(
            self.temps
                .iter()
                .filter(|t| t.session == session)
                .map(|t| t.path.clone()),
        );
        out.into_iter().collect()
    }

    /// The adapter capabilities of SESSION (its `initialize` answer).
    pub fn set_caps(&mut self, session: &str, caps: Value) {
        self.caps.insert(session.to_owned(), caps);
    }

    /// What `setBreakpoints` sends SESSION for PATH, in line order: the enabled breakpoints and SESSION's Run to
    /// Cursor (all fields: [`fit`] cuts them to the adapter). Remembers the order for `answer`.
    pub fn send_list(&mut self, session: &str, path: &str) -> Vec<Value> {
        let mut rows: Vec<(u32, u64, Option<&Bp>)> = self
            .data
            .files
            .get(path)
            .map(|f| {
                f.bps
                    .iter()
                    .filter(|b| b.enabled)
                    .filter(|b| {
                        b.triggered_by.is_none() || self.armed.contains(&(session.to_owned(), b.id))
                    })
                    .map(|b| (b.line, b.id, Some(b)))
                    .collect()
            })
            .unwrap_or_default();
        for t in self
            .temps
            .iter()
            .filter(|t| t.session == session && t.path == path)
        {
            if !rows.iter().any(|r| r.0 == t.line) {
                rows.push((t.line, 0, None));
            }
        }
        rows.sort_by_key(|r| (r.0, r.1));
        let out = rows.iter().map(|r| source_bp(r.0, r.2)).collect();
        self.sent.insert(
            (session.to_owned(), path.to_owned()),
            rows.iter().map(|r| r.1).collect(),
        );
        out
    }

    fn take(&mut self, session: &str, id: u64, b: &Value) {
        if id == 0 {
            return;
        }
        let e = self.bound.entry((session.to_owned(), id)).or_default();
        if let Some(a) = b.get("id").and_then(Value::as_i64) {
            e.adapter_id = Some(a);
        }
        if let Some(v) = b.get("verified").and_then(Value::as_bool) {
            e.verified = v;
        }
        if b.get("message").is_some() {
            e.message = b.get("message").and_then(Value::as_str).map(str::to_owned);
        }
        if let Some(l) = b.get("line").and_then(Value::as_u64) {
            e.line = u32::try_from(l).ok();
        }
    }

    /// SESSION's adapter answered `setBreakpoints` for PATH with BPS, in the order `send_list` gave.
    pub fn answer(&mut self, session: &str, path: &str, bps: &[Value]) {
        let ids = self
            .sent
            .get(&(session.to_owned(), path.to_owned()))
            .cloned()
            .unwrap_or_default();
        self.bound
            .retain(|(s, id), _| s != session || !ids.contains(id));
        for (id, b) in ids.into_iter().zip(bps) {
            self.take(session, id, b);
        }
    }

    /// SESSION's `breakpoint` event (BODY); the path of the breakpoint it changed.
    pub fn event(&mut self, session: &str, body: &Value) -> Option<String> {
        let b = body.get("breakpoint")?;
        let aid = b.get("id").and_then(Value::as_i64)?;
        let id = self
            .bound
            .iter()
            .find(|((s, _), v)| s == session && v.adapter_id == Some(aid))
            .map(|((_, id), _)| *id)?;
        if body.get("reason").and_then(Value::as_str) == Some("removed") {
            self.bound.remove(&(session.to_owned(), id));
        } else {
            self.take(session, id, b);
        }
        self.find(id).map(|(p, _)| p)
    }

    /// Run to Cursor: a breakpoint on PATH's LINE for SESSION alone; the path to send again.
    pub fn add_temp(&mut self, session: &str, path: &str, line: u32) -> String {
        self.temps.push(Temp {
            session: session.to_owned(),
            path: path.to_owned(),
            line,
        });
        path.to_owned()
    }

    fn drop_temps(&mut self, session: &str) -> Vec<String> {
        let mut out = BTreeSet::new();
        self.temps.retain(|t| {
            let mine = t.session == session;
            if mine {
                out.insert(t.path.clone());
            }
            !mine
        });
        out.into_iter().collect()
    }

    /// SESSION stopped: its Run to Cursor goes; the paths to send it again.
    pub fn stopped(&mut self, session: &str) -> Vec<String> {
        self.drop_temps(session)
    }

    /// SESSION ended: what it made of the breakpoints goes; the paths whose Run to Cursor it held.
    pub fn ended(&mut self, session: &str) -> Vec<String> {
        self.bound.retain(|(s, _), _| s != session);
        self.sent.retain(|(s, _), _| s != session);
        self.caps.remove(session);
        self.armed.retain(|(s, _)| s != session);
        self.datas.remove(session);
        self.instrs.remove(session);
        self.drop_temps(session)
    }

    /// PATH's breakpoints as the editor shows them: `{path, version, breakpoints: [{id, line, enabled, condition?,
    /// hit?, log?, verified, message?, bound_line?, unsupported}]}`.
    pub fn view(&self, path: &str) -> Value {
        let Some(f) = self.data.files.get(path) else {
            return json!({"path": path, "version": 0, "breakpoints": []});
        };
        let bps: Vec<Value> = f
            .bps
            .iter()
            .map(|b| {
                let mut o = serde_json::to_value(b).unwrap_or_default();
                let bound: Vec<(&String, &Bound)> = self
                    .bound
                    .iter()
                    .filter(|((_, id), _)| *id == b.id)
                    .map(|((s, _), v)| (s, v))
                    .collect();
                let verified = bound.iter().find(|(_, v)| v.verified);
                let shown_by = verified.or(bound.first());
                let mut unsupported = BTreeSet::new();
                let sent_to = self
                    .sent
                    .iter()
                    .filter(|((_, p), ids)| p == path && ids.contains(&b.id));
                for ((s, _), _) in sent_to {
                    let caps = self.caps.get(s).cloned().unwrap_or(Value::Null);
                    let sent = source_bp(b.line, Some(b));
                    for (field, cap) in FIELDS {
                        if sent.get(*field).is_some()
                            && !caps.get(*cap).and_then(Value::as_bool).unwrap_or(false)
                        {
                            unsupported.insert(shown(field));
                        }
                    }
                }
                if let Some(m) = o.as_object_mut() {
                    m.remove("column_utf16");
                    m.insert(
                        "waiting".into(),
                        json!(
                            b.triggered_by.is_some() && !self.armed.iter().any(|(_, x)| *x == b.id)
                        ),
                    );
                    m.insert("enabled".into(), json!(b.enabled));
                    m.insert("verified".into(), json!(verified.is_some()));
                    if let Some((_, v)) = shown_by {
                        if let Some(msg) = &v.message {
                            m.insert("message".into(), json!(msg));
                        }
                        if let Some(l) = v.line.filter(|l| *l != b.line) {
                            m.insert("bound_line".into(), json!(l));
                        }
                    }
                    m.insert("unsupported".into(), json!(unsupported));
                }
                o
            })
            .collect();
        json!({"path": path, "version": f.version, "breakpoints": bps})
    }

    /// The function breakpoints, as `setFunctionBreakpoints` sends them.
    pub fn functions(&self) -> Vec<Value> {
        self.data
            .functions
            .iter()
            .map(|f| serde_json::to_value(f).unwrap_or_default())
            .collect()
    }

    /// The exception filters for an adapter of type TY with CAPS: the ones chosen for TY, else the adapter's
    /// defaults.
    pub fn filters(&self, ty: &str, caps: &Value) -> Vec<String> {
        self.chosen_filters(ty)
            .unwrap_or_else(|| default_filters(caps))
    }

    /// The exception filters chosen for adapters of type TY, if any were.
    pub fn chosen_filters(&self, ty: &str) -> Option<Vec<String>> {
        self.data.filters.get(ty).cloned()
    }

    /// The paths SESSION was sent breakpoints for.
    pub fn sent_paths(&self, session: &str) -> Vec<String> {
        self.sent
            .keys()
            .filter(|(s, _)| s == session)
            .map(|(_, p)| p.clone())
            .collect()
    }

    /// The watch expressions, in order.
    pub fn watches(&self) -> Vec<String> {
        self.data.watches.clone()
    }

    /// The watch expressions are now LIST.
    pub fn set_watches(&mut self, list: Vec<String>) {
        self.data.watches = list;
        self.save();
    }

    /// The exception filters chosen for adapters of type TY.
    pub fn set_filters(&mut self, ty: &str, filters: Vec<String>) {
        self.data.filters.insert(ty.to_owned(), filters);
        self.save();
    }
}
