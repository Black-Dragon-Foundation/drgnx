//! Conclusions (docs/develop/work-space.md, "Conclusions"): the timeline step each one was recorded in, stamped by the
//! hub, and the steps it rests on.
//!
//! A conclusion is a `record_decision` decision or a `note_add` finding, never a summary. Its step is the session's
//! tool step of that MCP call, which the hub matches itself: the agent's `step` argument is ignored. The MCP call
//! reaches the hub's MCP server while its ACP `tool_call` comes on the session's stream, in either order, so
//! [`StampCore`] pairs them per session and tool, first with first, and stamps once the step is written. A call with no
//! tool step by its turn's end (an adapter that does not report MCP calls, the text fallback) is "step unknown".
//!
//! [`links`] is how a conclusion links back to the steps, computed, never inferred: each named source matches the
//! latest read (or page) of it, and the steps since the previous conclusion are the rest.

use crate::coord::Writer;
use crate::dispatch::Caller;
use crate::front::Front;
use norn::store::{CoordError, Tx};
use norn::write::work::{Source, StepDetail};
use runstav::methods::work as wire;
use serde_json::Value;
use std::collections::{BTreeMap, VecDeque};
use std::sync::{Mutex, PoisonError};

/// The drgnx MCP tools that record a conclusion.
pub const TOOLS: &[&str] = &["record_decision", "note_add"];

/// The drgnx MCP tool a provider's tool name or title names: Claude's `mcp__drgnx__note_add`, Codex's
/// `drgnx.note_add`, Gemini's `note_add (drgnx MCP Server)`, or the bare name.
pub fn mcp_tool_of(name: &str) -> Option<&'static str> {
    TOOLS.iter().copied().find(|t| {
        name == *t
            || name == format!("mcp__drgnx__{t}")
            || name == format!("drgnx.{t}")
            || name.starts_with(&format!("{t} (drgnx"))
    })
}

/// What the stamp core is told.
#[derive(Clone, Debug, PartialEq)]
pub enum StampEv {
    /// SESSION's call of the drgnx tool TOOL recorded CALL (`decision:N`, a note's id).
    McpCall {
        session: String,
        tool: String,
        call: String,
        at: f64,
    },
    /// SESSION's tool step STEP (its key in the session: the order steps began in) began, for TOOL_NAME.
    ToolStep {
        session: String,
        step: i64,
        tool_name: String,
        at: f64,
    },
    /// SESSION's step STEP was written, as timeline step ID.
    StepClosed { session: String, step: i64, id: i64 },
    /// SESSION's turn ended, its last step written.
    TurnEnd { session: String },
}

/// The step CONCLUSION was recorded in: a timeline step's id, or none ("step unknown").
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Stamp {
    pub conclusion: String,
    pub step: Option<i64>,
}

/// One session's calls and steps not yet paired.
#[derive(Debug, Default)]
struct Pending {
    /// Calls with no tool step yet, per tool.
    calls: BTreeMap<String, VecDeque<String>>,
    /// Tool steps with no call yet, per tool (open or written).
    steps: BTreeMap<String, VecDeque<i64>>,
    /// Steps written with no call yet: their ids.
    written: BTreeMap<i64, i64>,
    /// Calls paired with a step not yet written.
    paired: BTreeMap<i64, Vec<String>>,
}

/// See the module. Pure: no clock, no I/O.
#[derive(Debug, Default)]
pub struct StampCore {
    sessions: BTreeMap<String, Pending>,
}

impl StampCore {
    pub fn new() -> StampCore {
        StampCore::default()
    }

    pub fn step(&mut self, ev: StampEv) -> Vec<Stamp> {
        match ev {
            StampEv::McpCall {
                session,
                tool,
                call,
                ..
            } => {
                if !TOOLS.contains(&tool.as_str()) {
                    return Vec::new();
                }
                let s = self.sessions.entry(session).or_default();
                match s.steps.get_mut(&tool).and_then(VecDeque::pop_front) {
                    Some(key) => match s.written.remove(&key) {
                        Some(id) => vec![Stamp {
                            conclusion: call,
                            step: Some(id),
                        }],
                        None => {
                            s.paired.entry(key).or_default().push(call);
                            Vec::new()
                        }
                    },
                    None => {
                        s.calls.entry(tool).or_default().push_back(call);
                        Vec::new()
                    }
                }
            }
            StampEv::ToolStep {
                session,
                step,
                tool_name,
                ..
            } => {
                let Some(tool) = mcp_tool_of(&tool_name) else {
                    return Vec::new();
                };
                let s = self.sessions.entry(session).or_default();
                match s.calls.get_mut(tool).and_then(VecDeque::pop_front) {
                    Some(call) => s.paired.entry(step).or_default().push(call),
                    None => s.steps.entry(tool.to_string()).or_default().push_back(step),
                }
                Vec::new()
            }
            StampEv::StepClosed { session, step, id } => {
                let Some(s) = self.sessions.get_mut(&session) else {
                    return Vec::new();
                };
                if let Some(calls) = s.paired.remove(&step) {
                    return calls
                        .into_iter()
                        .map(|conclusion| Stamp {
                            conclusion,
                            step: Some(id),
                        })
                        .collect();
                }
                if s.steps.values().any(|q| q.contains(&step)) {
                    s.written.insert(step, id);
                }
                Vec::new()
            }
            StampEv::TurnEnd { session } => {
                let Some(s) = self.sessions.remove(&session) else {
                    return Vec::new();
                };
                // every step of the turn is written by now: what is still unpaired never had a step
                s.calls
                    .into_values()
                    .flatten()
                    .chain(s.paired.into_values().flatten())
                    .map(|conclusion| Stamp {
                        conclusion,
                        step: None,
                    })
                    .collect()
            }
        }
    }
}

/// A timeline step of the session, with what it read, searched or fetched.
#[derive(Clone, Debug, PartialEq)]
pub struct StepWithDetail {
    pub id: i64,
    /// `think`, `tool`, …
    pub class: String,
    pub start: f64,
    pub detail: Option<StepDetail>,
}

/// A conclusion as the hub reads it back.
#[derive(Clone, Debug, PartialEq)]
pub struct Conclusion {
    /// `decision:N` or the note's id.
    pub id: String,
    /// `decision` or `finding`.
    pub kind: String,
    pub text: String,
    pub sources: Vec<Source>,
    /// The step the hub stamped; none: step unknown.
    pub step: Option<i64>,
    /// When it was recorded (the transaction's time).
    pub at: f64,
    /// `own`, `from-brief`, `needs-user` (a decision's), or `from-text` (the fenced block in a message).
    pub origin: String,
}

/// How a conclusion links back to the session's steps.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Links {
    /// The steps its named sources match, in the sources' order (labelled `named`).
    pub named: Vec<i64>,
    /// The reads, searches, pages and thoughts since the previous conclusion (labelled "since the last conclusion").
    pub since_last: Vec<i64>,
    /// Named sources no step of the session matches ("named, not read in this session"), kept.
    pub unmatched: Vec<Source>,
}

/// C's links among STEPS (the session's, in order), PREV being the conclusion before it.
pub fn links(c: &Conclusion, prev: Option<&Conclusion>, steps: &[StepWithDetail]) -> Links {
    // a conclusion is placed by its step, or, unknown, by its time
    let upto = |s: &StepWithDetail| match c.step {
        Some(id) => s.id <= id,
        None => s.start <= c.at,
    };
    let after = |s: &StepWithDetail| match prev {
        None => true,
        Some(p) => match p.step {
            Some(id) => s.id > id,
            None => s.start > p.at,
        },
    };
    fn kind(s: &StepWithDetail) -> Option<&str> {
        s.detail.as_ref().and_then(|d| d.kind.as_deref())
    }
    let mut out = Links::default();
    for src in &c.sources {
        let hit = steps.iter().rev().filter(|s| upto(s)).find(|s| {
            let Some(d) = &s.detail else { return false };
            match src {
                Source::Path { path, lines } => {
                    kind(s) == Some("read")
                        && d.path.as_deref().is_some_and(|p| same_path(p, path))
                        && overlaps(*lines, d.line_start, d.line_end)
                }
                Source::Url { url } => kind(s) == Some("fetch") && d.url.as_deref() == Some(url),
            }
        });
        match hit {
            Some(s) if !out.named.contains(&s.id) => out.named.push(s.id),
            Some(_) => {}
            None => out.unmatched.push(src.clone()),
        }
    }
    out.since_last = steps
        .iter()
        .filter(|s| upto(s) && after(s) && Some(s.id) != c.step)
        .filter(|s| s.class == "think" || matches!(kind(s), Some("read" | "search" | "fetch")))
        .map(|s| s.id)
        .collect();
    out
}

/// Whether A and B name one file: equal, or one is the other's tail at a `/` (a step's path may be absolute, a source's
/// relative to the worktree).
fn same_path(a: &str, b: &str) -> bool {
    let tail = |long: &str, short: &str| {
        long.len() > short.len()
            && long.ends_with(short)
            && long.as_bytes()[long.len() - short.len() - 1] == b'/'
    };
    a == b || tail(a, b) || tail(b, a)
}

/// Whether the source's LINES meet a read from START to END (a read with no start is the whole file; with no end, the
/// rest of it).
fn overlaps(lines: Option<[u32; 2]>, start: Option<i64>, end: Option<i64>) -> bool {
    let (Some([a, b]), Some(s)) = (lines, start) else {
        return true;
    };
    i64::from(a) <= end.unwrap_or(i64::MAX) && i64::from(b) >= s
}

/// A conclusion entity as the store holds it: its id and kind, title, body, `data`, and its transaction's time.
pub fn from_entity(
    id: &str,
    kind: &str,
    title: Option<&str>,
    body: Option<&str>,
    data: &Value,
    at: f64,
) -> Conclusion {
    let decision = kind == "decision";
    let text = if decision {
        title.or(body)
    } else {
        body.or(title)
    };
    Conclusion {
        id: id.to_string(),
        kind: if decision { "decision" } else { "finding" }.to_string(),
        text: text.unwrap_or_default().to_string(),
        sources: data
            .get("sources")
            .and_then(|s| serde_json::from_value(s.clone()).ok())
            .unwrap_or_default(),
        step: data.get("step").and_then(Value::as_i64),
        at,
        origin: data
            .get("origin")
            .and_then(Value::as_str)
            .unwrap_or("own")
            .to_string(),
    }
}

// ---- the shell ----

/// The hub's stamp core, shared by the sessions' readers (a tool step begins), their step writers (a step is written,
/// a turn ends) and the asks shell (a session's call recorded a conclusion: [`crate::work::asks`]).
#[derive(Debug, Default)]
pub struct Stamps(Mutex<StampCore>);

impl Stamps {
    pub fn step(&self, ev: StampEv) -> Vec<Stamp> {
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .step(ev)
    }
}

/// Write STAMPS as the hub. Best effort: a store that is not ready loses them.
pub async fn put(writer: &Writer, stamps: Vec<Stamp>) {
    for s in stamps {
        let id = s.conclusion.clone();
        if let Err(e) = writer
            .write(&crate::work::asks::hub(), "work/stamp", move |tx| {
                norn::write::work::stamp_step(tx, &s.conclusion, s.step)
            })
            .await
        {
            tracing::warn!(conclusion = id, "a conclusion's step not recorded: {e}");
        }
    }
}

/// SESSION's conclusions and its steps, as the store holds them.
fn read_session(
    c: &Tx,
    session: &str,
) -> Result<(Vec<Conclusion>, Vec<StepWithDetail>), CoordError> {
    let mut q = c.prepare(
        "select e.id, e.kind, e.title, e.body, e.data, t.at from entity e join tx t on t.id = e.created_tx \
         where e.retired_tx is null \
         and (e.kind = 'decision' or (e.kind = 'note' and json_extract(e.data, '$.kind') = 'finding')) \
         and (json_extract(e.data, '$.session') = ?1 or t.session = ?1) order by e.created_tx, e.n",
    )?;
    let conclusions = q
        .query_map([session], |r| {
            let data: String = r.get(4)?;
            let data: Value = serde_json::from_str(&data).unwrap_or(Value::Null);
            Ok(from_entity(
                &r.get::<_, String>(0)?,
                &r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?.as_deref(),
                r.get::<_, Option<String>>(3)?.as_deref(),
                &data,
                r.get(5)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut q = c.prepare(
        "select s.id, s.class, s.start, d.origin, d.tool, d.kind, d.path, d.line_start, d.line_end, d.query, d.url, \
         d.title from step s left join step_detail d on d.step = s.id where s.session = ?1 order by s.seq",
    )?;
    let steps = q
        .query_map([format!("session:{session}")], |r| {
            let id: i64 = r.get(0)?;
            let detail = r.get::<_, Option<String>>(3)?.map(|origin| StepDetail {
                step: id,
                origin,
                tool: r.get(4).ok().flatten(),
                kind: r.get(5).ok().flatten(),
                path: r.get(6).ok().flatten(),
                line_start: r.get(7).ok().flatten(),
                line_end: r.get(8).ok().flatten(),
                query: r.get(9).ok().flatten(),
                url: r.get(10).ok().flatten(),
                title: r.get(11).ok().flatten(),
                parent_tool: None,
            });
            Ok(StepWithDetail {
                id,
                class: r.get(1)?,
                start: r.get(2)?,
                detail,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok((conclusions, steps))
}

/// A live conclusion a revert withdraws: a decision's number or a finding's note id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Concluded {
    Decision(i64),
    Finding(String),
}

/// SESSION's live conclusions recorded after its step SEQ: those whose stamped step has a `seq` above it; one with no
/// stamp counts when it was recorded after that step (a decision: its log version above the step's `log_version`; a
/// finding, which moves no version: its time after the step's start).  Withdrawn ones are left out.
pub fn after(c: &Tx, session: &str, seq: i64) -> Result<Vec<Concluded>, CoordError> {
    let key = format!("session:{session}");
    let target: Option<(Option<i64>, f64)> = c
        .query_row(
            "select log_version, start from step where session = ?1 and seq = ?2",
            (&key, seq),
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map(Some)
        .or_else(|e| match e {
            urdr::SqliteError::QueryReturnedNoRows => Ok(None),
            e => Err(e),
        })?;
    let Some((log_version, start)) = target else {
        return Ok(Vec::new());
    };
    let mut q = c.prepare(
        "select e.id, e.kind, json_extract(e.data, '$.step'), json_extract(e.data, '$.ver'), t.at, \
         (select s.seq from step s where s.id = json_extract(e.data, '$.step')) \
         from entity e join tx t on t.id = e.created_tx \
         where e.retired_tx is null and coalesce(e.status, '') != 'withdrawn' \
         and (e.kind = 'decision' or (e.kind = 'note' and json_extract(e.data, '$.kind') = 'finding')) \
         and (json_extract(e.data, '$.session') = ?1 or t.session = ?1) order by e.created_tx, e.n",
    )?;
    let rows = q
        .query_map([session], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<i64>>(2)?,
                r.get::<_, Option<i64>>(3)?,
                r.get::<_, f64>(4)?,
                r.get::<_, Option<i64>>(5)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut out = Vec::new();
    for (id, kind, stamped, ver, at, step_seq) in rows {
        let decision = kind == "decision";
        let later = match (stamped, step_seq) {
            (Some(_), Some(s)) => s > seq,
            // a stamp whose step is gone is no stamp
            _ if decision => match (ver, log_version) {
                (Some(v), Some(l)) => v > l,
                _ => false,
            },
            _ => at > start,
        };
        if !later {
            continue;
        }
        if decision {
            if let Some(n) = id.strip_prefix("decision:").and_then(|n| n.parse().ok()) {
                out.push(Concluded::Decision(n));
            }
        } else {
            out.push(Concluded::Finding(id));
        }
    }
    Ok(out)
}

fn wire_source(s: &Source) -> wire::ConclusionSource {
    match s {
        Source::Path { path, lines } => wire::ConclusionSource {
            path: Some(path.clone()),
            lines: *lines,
            url: None,
        },
        Source::Url { url } => wire::ConclusionSource {
            path: None,
            lines: None,
            url: Some(url.clone()),
        },
    }
}

/// `work/conclusions`: SESSION's decisions and findings in the order they were recorded, numbered from 1, each with
/// its step and the steps it rests on.
pub async fn get(
    f: &Front,
    _: &Caller,
    p: wire::ConclusionsParams,
) -> Result<wire::Conclusions, runstav::wire::Error> {
    let sid = p.session.clone();
    let (all, steps) = f
        .writer
        .db
        .read(move |c| read_session(c, &sid))
        .await
        .map_err(crate::coord::fail)?;
    let conclusions = all
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let l = links(c, i.checked_sub(1).map(|j| &all[j]), &steps);
            wire::Conclusion {
                n: u32::try_from(i + 1).unwrap_or(u32::MAX),
                id: c.id.clone(),
                kind: c.kind.clone(),
                text: c.text.clone(),
                sources: c.sources.iter().map(wire_source).collect(),
                step: c.step,
                at: c.at,
                origin: c.origin.clone(),
                links: wire::ConclusionLinks {
                    named: l.named,
                    since_last: l.since_last,
                    unmatched: l.unmatched.iter().map(wire_source).collect(),
                },
            }
        })
        .collect();
    Ok(wire::Conclusions { conclusions })
}

#[cfg(test)]
mod tests;
