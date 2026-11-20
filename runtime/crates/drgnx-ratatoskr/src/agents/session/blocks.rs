//! The conversation as blocks (docs/develop/hub.md, "Conversation blocks"): what the agent did, folded the way the
//! conversation view shows it, and the plan strip.  Pure: no lock, no I/O, no clock.
//!
//! - Consecutive read and search steps fold into one [`Block::Explored`]; any other block (or a turn's end) breaks
//!   the run.  Thoughts and usage break nothing.
//! - A `record_decision` or `note_add` call is a [`Block::Finding`] with its sources; an edit a [`Block::Edit`] with
//!   its line counts and hunks; any other tool a [`Block::Step`].
//! - A subagent's steps (their `parentToolUseId`, kept beside the entries in [`Meta::parents`]) nest in a
//!   [`Block::Subagent`] under the `Task` call that started it.
//! - [`Folder::append`] folds new entries onto the last block or adds blocks; [`Folder::update`] folds again from the
//!   block of a changed entry (a tool call's status and diff arrive after the call): both touch the tail only.
//! - [`overlay`] is what follows the transcript while it runs: the questions waiting for the user ([`Block::Ask`]),
//!   the live step or thought, and the messages queued.

use runstav::methods::agents::{Entry, EntryType};
use serde_json::Value;
use std::collections::HashMap;

/// A step of the transcript: its entry's index and its timeline step, when known.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StepRef {
    pub entry: usize,
    pub step: Option<u64>,
}

/// A hunk of an edit, in the new text's lines (1-based, inclusive).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HunkRef {
    pub start_line: usize,
    pub end_line: usize,
}

/// What a conclusion rests on.
pub type Source = norn::write::work::Source;

/// An ask's kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AskKind {
    Permission,
    Question,
}

/// A plan entry's state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlanState {
    Done,
    Doing,
    Todo,
}

/// One block of the conversation.
#[derive(Clone, Debug, PartialEq)]
pub enum Block {
    You {
        text: String,
    },
    Explored {
        reads: u32,
        searches: u32,
        secs: u32,
        steps: Vec<StepRef>,
    },
    /// An agent message: its entry (its Markdown blocks are the panel's `b:I:N` rows).
    Markdown {
        entry: usize,
    },
    /// `conclusion`: `finding` (a `note_add`) or `decision` (a `record_decision`).
    Finding {
        conclusion: String,
        text: String,
        sources: Vec<Source>,
    },
    Edit {
        path: String,
        plus: u32,
        minus: u32,
        hunks: Vec<HunkRef>,
    },
    /// Any other tool call (a shell command, a fetch, …).
    Step {
        step: StepRef,
        kind: String,
        title: String,
    },
    Ask {
        kind: AskKind,
        text: String,
        options: Vec<(String, char)>,
    },
    Subagent {
        call_id: String,
        title: String,
        blocks: Vec<Block>,
    },
    /// A notice, an error or a compaction: one line.
    Notice {
        text: String,
        error: bool,
    },
    Live {
        text: String,
    },
    Queued {
        text: String,
    },
}

/// What the blocks read beside the entries: each subagent step's parent `Task` call (tool call id → parent id), and
/// each step's seconds (timeline step → duration).
#[derive(Clone, Debug, Default)]
pub struct Meta {
    pub parents: HashMap<String, String>,
    pub secs: HashMap<u64, f64>,
}

/// What an append or update changed: from block `from` on, the blocks are new (`from` ≤ the old length; the blocks
/// before it are as they were).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Patch {
    pub from: usize,
    pub len: usize,
}

/// The blocks of a transcript, kept as it grows.
#[derive(Clone, Debug, Default)]
pub struct Folder {
    pub blocks: Vec<Block>,
    /// Each block's first entry.
    starts: Vec<usize>,
    /// The next entry to fold.
    next: usize,
    /// The last block is an Explored run a read or search may join.
    open: bool,
    /// Tool call id → its title (a subagent's head is its `Task` call).
    titles: HashMap<String, String>,
}

fn str_of<'e>(e: &'e Entry, k: &str) -> Option<&'e str> {
    e.rest.get(k).and_then(Value::as_str)
}

/// A tool entry's diff items (`{type: diff, path, oldText, newText}`).
fn diffs(e: &Entry) -> Vec<&Value> {
    e.rest
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|c| c.get("type").and_then(Value::as_str) == Some("diff"))
        .collect()
}

/// The lines added and removed between OLD and NEW, and the hunks in NEW's lines.
fn counts(old: &str, new: &str) -> (u32, u32, Vec<HunkRef>) {
    let d = similar::TextDiff::from_lines(old, new);
    let (mut plus, mut minus) = (0, 0);
    for c in d.iter_all_changes() {
        match c.tag() {
            similar::ChangeTag::Insert => plus += 1,
            similar::ChangeTag::Delete => minus += 1,
            similar::ChangeTag::Equal => {}
        }
    }
    let hunks = d
        .grouped_ops(0)
        .iter()
        .filter_map(|g| {
            let r = g.first()?.new_range().start..g.last()?.new_range().end;
            Some(HunkRef {
                start_line: r.start + 1,
                end_line: r.end.max(r.start + 1),
            })
        })
        .collect();
    (plus, minus, hunks)
}

/// A conclusion's block from its MCP call's raw input.
fn finding(tool: &str, input: Option<&Value>) -> Block {
    let get = |k: &str| {
        input
            .and_then(|i| i.get(k))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned()
    };
    let (conclusion, text) = if tool == "record_decision" {
        let (s, r) = (get("subject"), get("reason"));
        let t = if r.is_empty() { s } else { format!("{s}: {r}") };
        ("decision", t)
    } else {
        ("finding", get("text"))
    };
    let sources = input
        .and_then(|i| i.get("sources"))
        .and_then(|s| serde_json::from_value(s.clone()).ok())
        .unwrap_or_default();
    Block::Finding {
        conclusion: conclusion.into(),
        text,
        sources,
    }
}

impl Folder {
    /// The blocks of ENTRIES.
    pub fn of(entries: &[Entry], m: &Meta) -> Folder {
        let mut f = Folder::default();
        f.append(entries, m);
        f
    }

    /// Each block's first entry, in the indexes of the entries folded.
    pub fn starts(&self) -> &[usize] {
        &self.starts
    }

    /// Fold NEW, the entries after the ones folded so far.
    pub fn append(&mut self, new: &[Entry], m: &Meta) -> Patch {
        let mut from = self.blocks.len();
        for e in new {
            let i = self.next;
            self.next += 1;
            if let Some(touched) = self.fold(i, e, m) {
                from = from.min(touched);
            }
        }
        Patch {
            from,
            len: self.blocks.len(),
        }
    }

    /// ENTRIES (the whole transcript) changed at CHANGED: the blocks from the one holding it are folded again.
    pub fn update(&mut self, entries: &[Entry], changed: usize, m: &Meta) -> Patch {
        if changed >= self.next {
            let new = &entries[self.next.min(entries.len())..];
            return self.append(new, m);
        }
        let k = self
            .starts
            .partition_point(|s| *s <= changed)
            .saturating_sub(1);
        let start = self.starts.get(k).copied().unwrap_or(0);
        self.blocks.truncate(k);
        self.starts.truncate(k);
        self.next = start;
        self.open = matches!(self.blocks.last(), Some(Block::Explored { .. }));
        // a subagent's steps were folded into the block before; fold that one again too when it is one
        let p = self.append(&entries[start..], m);
        Patch {
            from: k.min(p.from),
            len: p.len,
        }
    }

    fn push(&mut self, i: usize, b: Block) -> usize {
        self.open = matches!(b, Block::Explored { .. });
        self.blocks.push(b);
        self.starts.push(i);
        self.blocks.len() - 1
    }

    /// Fold entry I; the index of the block it touched, none when it made none.
    fn fold(&mut self, i: usize, e: &Entry, m: &Meta) -> Option<usize> {
        match e.kind {
            EntryType::Thought | EntryType::Usage | EntryType::Plan => None,
            EntryType::Stop => {
                self.open = false;
                None
            }
            EntryType::User => Some(self.push(
                i,
                Block::You {
                    text: str_of(e, "text").unwrap_or("").to_owned(),
                },
            )),
            EntryType::Agent => Some(self.push(i, Block::Markdown { entry: i })),
            EntryType::Notice | EntryType::Note | EntryType::Compaction | EntryType::Error => {
                let text = match e.kind {
                    EntryType::Compaction => "context compacted",
                    _ => str_of(e, "text")
                        .or_else(|| str_of(e, "title"))
                        .unwrap_or(""),
                };
                Some(self.push(
                    i,
                    Block::Notice {
                        text: text.to_owned(),
                        error: e.kind == EntryType::Error,
                    },
                ))
            }
            EntryType::Tool => self.tool(i, e, m),
        }
    }

    fn tool(&mut self, i: usize, e: &Entry, m: &Meta) -> Option<usize> {
        let id = str_of(e, "id").unwrap_or("").to_owned();
        let title = str_of(e, "title").unwrap_or("").to_owned();
        if !id.is_empty() {
            self.titles.insert(id.clone(), title.clone());
        }
        if let Some(parent) = m.parents.get(&id) {
            let last = self.blocks.len().wrapping_sub(1);
            if let Some(Block::Subagent {
                call_id, blocks, ..
            }) = self.blocks.last_mut()
                && call_id == parent
            {
                let mut inner = Folder {
                    open: matches!(blocks.last(), Some(Block::Explored { .. })),
                    blocks: std::mem::take(blocks),
                    starts: Vec::new(),
                    next: i,
                    titles: HashMap::new(),
                };
                inner.tool_here(i, e, m);
                *blocks = inner.blocks;
                return Some(last);
            }
            let mut inner = Folder::default();
            inner.tool_here(i, e, m);
            let head = self.titles.get(parent).cloned().unwrap_or_default();
            return Some(self.push(
                i,
                Block::Subagent {
                    call_id: parent.clone(),
                    title: head,
                    blocks: inner.blocks,
                },
            ));
        }
        self.tool_here(i, e, m)
    }

    /// Tool entry I as a block of this level.
    fn tool_here(&mut self, i: usize, e: &Entry, m: &Meta) -> Option<usize> {
        let kind = str_of(e, "kind").unwrap_or("other");
        let title = str_of(e, "title").unwrap_or("");
        let step = e.rest.get("step").and_then(Value::as_u64);
        let at = StepRef { entry: i, step };
        if matches!(kind, "read" | "search") {
            if self.open
                && let Some(Block::Explored {
                    reads,
                    searches,
                    secs: total,
                    steps,
                }) = self.blocks.last_mut()
            {
                if kind == "read" {
                    *reads += 1;
                } else {
                    *searches += 1;
                }
                steps.push(at);
                // the run's seconds, rounded once
                let sum: f64 = steps
                    .iter()
                    .filter_map(|s| s.step.and_then(|n| m.secs.get(&n)))
                    .sum();
                *total = sum.round() as u32;
                return Some(self.blocks.len() - 1);
            }
            return Some(
                self.push(
                    i,
                    Block::Explored {
                        reads: u32::from(kind == "read"),
                        searches: u32::from(kind == "search"),
                        secs: step
                            .and_then(|s| m.secs.get(&s))
                            .map_or(0, |s| s.round() as u32),
                        steps: vec![at],
                    },
                ),
            );
        }
        if let Some(tool) = crate::work::conclusions::mcp_tool_of(title) {
            return Some(self.push(i, finding(tool, e.rest.get("rawInput"))));
        }
        let ds = diffs(e);
        if kind == "edit" || !ds.is_empty() {
            let path = ds
                .first()
                .and_then(|d| d.get("path"))
                .or_else(|| e.rest.get("locations").and_then(|l| l.pointer("/0/path")))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned();
            let (mut plus, mut minus, mut hunks) = (0, 0, Vec::new());
            for d in &ds {
                let s = |k: &str| d.get(k).and_then(Value::as_str).unwrap_or("");
                let (p, n, h) = counts(s("oldText"), s("newText"));
                plus += p;
                minus += n;
                hunks.extend(h);
            }
            return Some(self.push(
                i,
                Block::Edit {
                    path,
                    plus,
                    minus,
                    hunks,
                },
            ));
        }
        Some(self.push(
            i,
            Block::Step {
                step: at,
                kind: kind.to_owned(),
                title: title.to_owned(),
            },
        ))
    }
}

/// The blocks of ENTRIES.
pub fn blocks(entries: &[Entry], m: &Meta) -> Vec<Block> {
    Folder::of(entries, m).blocks
}

/// Fold NEW onto PREV.
pub fn append(prev: &mut Folder, new: &[Entry], m: &Meta) -> Patch {
    prev.append(new, m)
}

/// A request waiting for the user: a permission (its options' names and kinds) or a question.
#[derive(Clone, Debug, PartialEq)]
pub struct AskIn {
    pub kind: AskKind,
    pub text: String,
    /// `(name, kind)`, the kind ACP's (`allow_once`, `allow_always`, `reject_once`, …).
    pub options: Vec<(String, String)>,
}

/// The key of a permission option: `y` allow once, `a` always, `n` deny.
fn key_of(kind: &str) -> char {
    match kind {
        "allow_always" => 'a',
        k if k.starts_with("allow") => 'y',
        _ => 'n',
    }
}

/// What follows the transcript's blocks now: each ask (permission options keyed `y`, `a`, `n`), then, while RUNNING,
/// the live step or thought (the last entry, when it is a tool call still running or a thought), then each queued
/// message.
pub fn overlay(entries: &[Entry], asks: &[AskIn], running: bool, queued: &[String]) -> Vec<Block> {
    let mut out: Vec<Block> = asks
        .iter()
        .map(|a| Block::Ask {
            kind: a.kind,
            text: a.text.clone(),
            options: a
                .options
                .iter()
                .map(|(name, k)| (name.clone(), key_of(k)))
                .collect(),
        })
        .collect();
    let live = entries
        .iter()
        .rev()
        .find(|e| !matches!(e.kind, EntryType::Usage | EntryType::Plan));
    if running && let Some(e) = live {
        let text = match e.kind {
            EntryType::Tool
                if !matches!(str_of(e, "status"), Some("completed" | "failed" | "done")) =>
            {
                Some(
                    str_of(e, "title")
                        .or_else(|| str_of(e, "kind"))
                        .unwrap_or("tool"),
                )
            }
            EntryType::Thought => Some("thinking"),
            _ => None,
        };
        if let Some(t) = text {
            out.push(Block::Live { text: t.to_owned() });
        }
    }
    out.extend(queued.iter().map(|t| Block::Queued { text: t.clone() }));
    out
}

/// The plan strip: the latest plan entry's items and their states.
pub fn plan_strip(entries: &[Entry]) -> Vec<(String, PlanState)> {
    let Some(p) = entries.iter().rev().find(|e| e.kind == EntryType::Plan) else {
        return Vec::new();
    };
    p.rest
        .get("entries")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|i| {
            let s = |k: &str| i.get(k).and_then(Value::as_str).unwrap_or("");
            let state = match s("status") {
                "completed" => PlanState::Done,
                "in_progress" => PlanState::Doing,
                _ => PlanState::Todo,
            };
            (s("content").to_owned(), state)
        })
        .collect()
}

/// The limit the at-limit block suggests (Flow Task 23a): SPENT plus P90 (the session forecast's p90 of what remains),
/// rounded up to the unit's next step: the next dollar, the next whole percent of a window, the next 100k tokens. A
/// count has none.
pub fn at_limit_suggestion(
    unit: runstav::methods::matrix::Unit,
    spent: f64,
    p90: f64,
) -> Option<f64> {
    use runstav::methods::matrix::Unit;
    let step = match unit {
        Unit::Usd | Unit::UsdEst => 1.0,
        Unit::LimitShare => 0.01,
        Unit::Tokens => 100_000.0,
        Unit::Count => return None,
    };
    let want = spent + p90.max(0.0);
    // a hair under a step (8.000000001 from float sums) stays on it
    let n = (want / step - 1e-9).ceil();
    Some((n * step * 1e6).round() / 1e6)
}

#[cfg(test)]
mod tests;
