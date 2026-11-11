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

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

/// An editor's change to the store.
#[derive(Clone, Debug, PartialEq)]
pub enum Op {
    /// A breakpoint on PATH's LINE (the one already there, if any).
    Add {
        path: String,
        line: u32,
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
    /// The breakpoint's line after a save.
    Move {
        id: u64,
        line: u32,
    },
    AddFunction {
        name: String,
        condition: Option<String>,
    },
    RemoveFunction {
        name: String,
    },
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
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    condition: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    hit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    log: Option<String>,
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
    data: Data,
    /// (session, path) → the ids last sent, in the order sent (`answer` reads the adapter's answer in that order).
    sent: BTreeMap<(String, String), Vec<u64>>,
    bound: BTreeMap<(String, u64), Bound>,
    temps: Vec<Temp>,
    caps: BTreeMap<String, Value>,
}

/// BPS (`SourceBreakpoint`s) as an adapter with CAPS takes them: without the fields it does not support.
pub fn fit(bps: &[Value], caps: &Value) -> Vec<Value> {
    let has = |k: &str| caps.get(k).and_then(Value::as_bool).unwrap_or(false);
    bps.iter()
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
            file,
            data,
            sent: BTreeMap::new(),
            bound: BTreeMap::new(),
            temps: Vec::new(),
            caps: BTreeMap::new(),
        }
    }

    fn save(&self) {
        let Some(f) = &self.file else { return };
        if let Some(dir) = f.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let text = serde_json::to_string(&self.data).unwrap_or_default();
        if let Err(e) = crate::records::write_atomic(f, &text) {
            tracing::warn!(target: "drgnx::debug", "breakpoints {}: {e}", f.display());
        }
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
                enabled,
                condition,
                hit,
                log,
            } => {
                let f = self.data.files.entry(path.clone()).or_default();
                if f.bps.iter().any(|b| b.line == line) {
                    return None;
                }
                self.data.next += 1;
                let id = self.data.next;
                let none = |t: Option<String>| t.filter(|t| !t.is_empty());
                f.bps.push(Bp {
                    id,
                    line,
                    enabled,
                    condition: none(condition),
                    hit: none(hit),
                    log: none(log),
                });
                self.bump(&path, Some(id))
            }
            Op::Remove { id } => {
                let (path, i) = self.find(id)?;
                self.data.files.get_mut(&path)?.bps.remove(i);
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
            Op::Move { id, line } => {
                let (path, i) = self.find(id)?;
                let b = &mut self.data.files.get_mut(&path)?.bps[i];
                if b.line == line {
                    return None;
                }
                b.line = line;
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

    /// The exception filters chosen for adapters of type TY.
    pub fn set_filters(&mut self, ty: &str, filters: Vec<String>) {
        self.data.filters.insert(ty.to_owned(), filters);
        self.save();
    }
}
