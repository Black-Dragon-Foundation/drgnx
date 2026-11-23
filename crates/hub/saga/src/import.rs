//! The importer's half in `saga`: a parsed record file as graph operations.  Pure: the hub applies them
//! (`ratatoskr::records`, entities with `Origin::Imported`).
//!
//! A file becomes an ordered list of pieces; each piece is one entity whose `body` is the piece's raw text, so
//! concatenating the bodies in `seq` order is the file again, byte for byte ([`crate::view::render`]).  Ids are
//! stable and keyed (`<kind>:rec-<hash of the source path>-<hash of the piece's key>`): a piece's key is what it is
//! in its file (`head`, `row 12`, `task 5`, `section Done`), so importing a file twice changes nothing and a row
//! added in the middle leaves the other rows' ids alone.

use crate::board_md::{self, BoardDoc};
use crate::deferred::{self, DeferredDoc};
use crate::ledger::{self, LedgerDoc};
use crate::org::{self, OrgDoc};
use crate::plan::{self, PlanDoc};
use crate::table::Block;

/// A parsed record file of any kind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AnyDoc {
    Plan(PlanDoc),
    Ledger(LedgerDoc),
    Deferred(DeferredDoc),
    Board(BoardDoc),
    Org(OrgDoc),
    /// A spec or a decision record: one piece, the whole file.
    Spec(crate::spec::SpecDoc),
    Decision(crate::spec::SpecDoc),
}

/// One entity of an imported file.  `seq` 0 is the head piece (the entity the file is known by).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphOp {
    pub id: String,
    pub kind: &'static str,
    pub seq: u32,
    /// What the piece is in its file, unique there (`head`, `row 12`, `task 5`…): the id is made from it.
    pub key: String,
    /// What the piece is: `head`, `task`, `section`, `row`, `block`, `item` or `rest`.
    pub role: &'static str,
    pub title: Option<String>,
    pub status: Option<String>,
    /// The piece's raw text.
    pub body: String,
    /// `records:<hash>`: what every piece of the file has in common.
    pub source: String,
    /// A plan's task: what `plan_read` and `job/propose` need of it.
    pub task: Option<TaskMeta>,
    /// The seq of the piece this one is under (`parent_of`): a plan's tasks are under its head.
    pub parent: Option<u32>,
    /// The head of a plan: its `**Repo:**` line as written.
    pub repo: Option<String>,
}

/// A plan task's fields beyond its text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskMeta {
    /// `"5"`, `"22b"`.
    pub number: String,
    /// The numbers it waits on (`**Depends:** Task 3, Task 4`).
    pub deps: Vec<String>,
    pub role: Option<String>,
    pub model: Option<String>,
    pub interfaces: Option<String>,
    pub steps: Vec<(bool, String)>,
}

/// The value after LABEL on the first body line that starts with it.
fn labelled<'a>(body: &'a str, label: &str) -> Option<&'a str> {
    body.lines()
        .find_map(|l| l.strip_prefix(label))
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

/// Every `Task N` / `Task 22b` in S.
fn task_numbers(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = s;
    while let Some(at) = rest.find("Task ") {
        rest = &rest[at + 5..];
        let n: String = rest
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect();
        if n.starts_with(|c: char| c.is_ascii_digit()) {
            out.push(n);
        }
    }
    out
}

fn meta_of(t: &plan::TaskDoc) -> TaskMeta {
    TaskMeta {
        number: t.number.clone(),
        deps: labelled(&t.body, "**Depends:**")
            .map(task_numbers)
            .unwrap_or_default(),
        role: labelled(&t.body, "**Role:**").map(|r| {
            r.chars()
                .take_while(|c| c.is_ascii_lowercase() || *c == '-')
                .collect()
        }),
        model: t.model.clone(),
        interfaces: t.interfaces.clone(),
        steps: t.steps.iter().map(|s| (s.done, s.text.clone())).collect(),
    }
}

/// FNV-1a, 64 bit, as 12 hex digits (stable across runs and platforms).
fn hash(s: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{:012x}", h & 0xffff_ffff_ffff)
}

/// The `source` of every piece of the file at SOURCE.
pub fn source_key(source: &std::path::Path) -> String {
    format!("records:{}", hash(&source.to_string_lossy()))
}

fn title(s: &str) -> Option<String> {
    let t = s.trim().trim_start_matches(['#', '*', ' ']).trim();
    (!t.is_empty()).then(|| t.chars().take(200).collect())
}

struct Out {
    key: String,
    h: String,
    ops: Vec<GraphOp>,
}

/// A piece's key before it is made unique: its role, then what names it in the file (a row's id, a task's number,
/// a section's title, an item's first line).
fn piece_key(role: &str, title: Option<&str>, body: &str) -> String {
    let name = match role {
        "head" | "rest" => return role.to_string(),
        // `5 Do the thing` / `R6-KI-14 text`: the first word is the number or the id
        "task" | "row" | "entry" => title.and_then(|t| t.split_whitespace().next()),
        _ => title.or_else(|| body.lines().find(|l| !l.trim().is_empty())),
    };
    match name.map(str::trim).filter(|n| !n.is_empty()) {
        Some(n) => format!("{role} {n}"),
        None => role.to_string(),
    }
}

impl Out {
    /// KEY, or KEY with ` #2`, ` #3`… when an earlier piece of the file has it.
    fn unique(&self, key: String) -> String {
        let taken = |k: &str| self.ops.iter().any(|o| o.key == k);
        if !taken(&key) {
            return key;
        }
        (2..)
            .map(|n| format!("{key} #{n}"))
            .find(|k| !taken(k))
            .expect("unbounded")
    }

    fn push(
        &mut self,
        kind: &'static str,
        role: &'static str,
        t: Option<String>,
        status: Option<String>,
        body: String,
    ) {
        let key = piece_key(role, t.as_deref(), &body);
        self.push_keyed(kind, role, key, t, status, body);
    }

    /// As [`Out::push`], with the piece's KEY named (made unique here).
    fn push_keyed(
        &mut self,
        kind: &'static str,
        role: &'static str,
        key: String,
        t: Option<String>,
        status: Option<String>,
        body: String,
    ) {
        let seq = self.ops.len() as u32;
        let key = self.unique(key);
        self.ops.push(GraphOp {
            id: format!("{kind}:rec-{}-{}", self.h, hash(&key)),
            kind,
            seq,
            key,
            role,
            title: t,
            status,
            body,
            source: self.key.clone(),
            task: None,
            parent: None,
            repo: None,
        });
    }
}

/// The graph operations that make DOC (read from SOURCE) the graph's records.
pub fn ops(doc: &AnyDoc, source: &std::path::Path) -> Vec<GraphOp> {
    let h = hash(&source.to_string_lossy());
    let mut o = Out {
        key: format!("records:{h}"),
        h,
        ops: Vec::new(),
    };
    match doc {
        AnyDoc::Plan(p) => {
            let head: String = p
                .preamble
                .iter()
                .map(|s| format!("{}{}", s.heading, s.body))
                .collect();
            o.push("plan", "head", title(&p.title), None, head.clone());
            o.ops[0].repo = labelled(&head, "**Repo:**").map(str::to_owned);
            for t in &p.tasks {
                let mut raw = format!("{}{}", t.heading, t.body);
                for s in &t.after {
                    raw.push_str(&s.heading);
                    raw.push_str(&s.body);
                }
                let st = crate::status::status_of("task", "task", &raw);
                o.push(
                    "task",
                    "task",
                    title(&format!("{} {}", t.number, t.title)),
                    st,
                    raw,
                );
                let op = o.ops.last_mut().expect("just pushed");
                op.task = Some(meta_of(t));
                op.parent = Some(0);
            }
            let rest: String = p
                .rest
                .iter()
                .map(|s| format!("{}{}", s.heading, s.body))
                .collect();
            if !rest.is_empty() {
                o.push("note", "rest", None, None, rest);
            }
        }
        AnyDoc::Ledger(l) => {
            o.push("note", "head", title(&l.header), None, l.header.clone());
            for s in &l.sections {
                o.push(
                    "note",
                    "section",
                    title(&s.heading),
                    None,
                    format!("{}{}", s.heading, s.body),
                );
            }
        }
        AnyDoc::Deferred(d) => {
            for (i, p) in d.pieces.iter().enumerate() {
                match p {
                    deferred::DeferredPiece::Prose(s) if i == 0 => {
                        o.push("note", "head", title(s), None, s.clone());
                    }
                    deferred::DeferredPiece::Prose(s) => {
                        o.push("note", "rest", None, None, s.clone())
                    }
                    deferred::DeferredPiece::Row(r) => o.push(
                        "todo",
                        if r.entry { "entry" } else { "row" },
                        title(&format!("{} {}", r.id, r.text)),
                        Some(crate::status::normalize_deferred(&r.status)),
                        r.raw.clone(),
                    ),
                }
            }
        }
        AnyDoc::Board(b) => {
            o.push("note", "head", None, None, String::new());
            for blk in &b.blocks {
                match blk {
                    Block::Text(t) => o.push(
                        "note",
                        "block",
                        title(t.lines().next().unwrap_or("")),
                        None,
                        t.clone(),
                    ),
                    Block::Table(t) => o.push(
                        "note",
                        "block",
                        t.header.cells.first().cloned(),
                        None,
                        t.render(),
                    ),
                }
            }
        }
        AnyDoc::Org(g) => {
            o.push("note", "head", title(&g.preamble), None, g.preamble.clone());
            for i in &g.items {
                let st = i.keyword.as_ref().map(|k| crate::status::normalize(k));
                o.push(
                    "task",
                    "item",
                    title(&i.title),
                    st,
                    format!("{}{}", i.heading, i.body),
                );
            }
        }
        AnyDoc::Spec(d) | AnyDoc::Decision(d) => {
            let kind = if matches!(doc, AnyDoc::Spec(_)) {
                "spec"
            } else {
                "decision"
            };
            let st = d.status.as_deref().map(spec_status);
            o.push(kind, "head", d.title.clone(), st, d.head.clone());
            for (sec, key) in d
                .sections
                .iter()
                .zip(crate::spec::section_keys(&d.sections))
            {
                o.push_keyed(
                    "note",
                    "section",
                    key,
                    Some(sec.title.clone()),
                    None,
                    format!("{}{}", sec.heading, sec.body),
                );
            }
        }
    }
    o.ops
}

/// A spec's or ADR's status word as one of `status::STATUSES`: approved and accepted are done, proposed and draft
/// are open, superseded and rejected are dropped.
pub fn spec_status(raw: &str) -> String {
    let t = raw.trim().to_lowercase();
    if ["approved", "accepted", "adopted", "final"]
        .iter()
        .any(|w| t.starts_with(w))
    {
        "done".into()
    } else {
        crate::status::normalize(raw)
    }
}

/// Parse TEXT as a record file of KIND (`plan`, `ledger`, `deferred`, `board-md`, `org`, `spec`, `decision`).
pub fn parse(kind: &str, text: &str) -> Option<AnyDoc> {
    Some(match kind {
        "plan" => AnyDoc::Plan(plan::parse(text)),
        "ledger" => AnyDoc::Ledger(ledger::parse(text)),
        "deferred" => AnyDoc::Deferred(deferred::parse(text)),
        "board-md" => AnyDoc::Board(board_md::parse(text)),
        "org" => AnyDoc::Org(org::parse(text)),
        "spec" => AnyDoc::Spec(crate::spec::parse(text)),
        "decision" => AnyDoc::Decision(crate::spec::parse(text)),
        _ => return None,
    })
}
