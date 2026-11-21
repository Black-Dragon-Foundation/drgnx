//! The operation log: one immutable record per action, a DAG by its parents, each with its cause, the element-id
//! spans its operations made and the view after it (every active branch head).  Typing is grouped by the settle rule:
//! one `edits` record per author per document after 30 s without a change, or at once on a save, a buffer switch, an
//! agent step boundary or a revert.  The keystroke-level operations stay in the documents; a record only groups and
//! labels them.  The settle rule takes the time as a parameter (the hub's clock), never reads one.

use crate::store::History;
pub use crate::store::{Cause, Kind, Record};
use crate::{BranchId, DocId, Frontier, OpId, PeerId, Result, Span};
use std::collections::BTreeMap;

/// Seconds without a change before typing settles into a record.
pub const SETTLE_SECS: f64 = 30.0;

/// Why the settler flushes now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FlushReason {
    Save,
    BufferSwitch,
    StepBoundary,
    Revert,
}

impl FlushReason {
    fn as_str(self) -> &'static str {
        match self {
            FlushReason::Save => "save",
            FlushReason::BufferSwitch => "buffer switch",
            FlushReason::StepBoundary => "step boundary",
            FlushReason::Revert => "revert",
        }
    }
}

impl History {
    /// Write record R; its view is every active branch head's version after the action.
    pub fn record(&mut self, r: Record) -> Result<OpId> {
        let view = self.view()?;
        self.put_op(&r, &view, &[])
    }

    /// Every active document's version, by branch.
    pub(crate) fn view(&mut self) -> Result<Vec<(DocId, BranchId, Frontier)>> {
        let mut out = Vec::new();
        for (d, b) in self.active_docs() {
            out.push((d, b, self.frontier(d, b)?));
        }
        Ok(out)
    }
}

/// Typing not yet in a record, per author, document and cause: its record's cause.
struct Pending {
    spans: Vec<Span>,
    last: f64,
    cause: Cause,
}

/// What one record groups: the author, the document and the cause's step (an agent's steps are records apart).
type Key = (PeerId, DocId, Option<String>);

/// The settle rule: changes come in as they are applied; records go out when they settle or are flushed.
#[derive(Default)]
pub struct Settler {
    pending: BTreeMap<Key, Pending>,
    /// The last record written, the next one's parent.
    last: Option<OpId>,
}

impl Settler {
    /// PEER changed DOC at NOW; SPANS are the element ids the change made.
    pub fn change(&mut self, doc: DocId, peer: PeerId, spans: &[Span], now: f64) {
        self.change_caused(doc, peer, spans, now, Cause::default());
    }

    /// [`Settler::change`] with the record's CAUSE (an agent's session and step): a change under another step waits
    /// for a record of its own.
    pub fn change_caused(
        &mut self,
        doc: DocId,
        peer: PeerId,
        spans: &[Span],
        now: f64,
        cause: Cause,
    ) {
        let p = self
            .pending
            .entry((peer, doc, cause.step.clone()))
            .or_insert(Pending {
                spans: Vec::new(),
                last: now,
                cause,
            });
        p.last = now;
        for s in spans {
            match p.spans.last_mut() {
                Some(l) if l.peer == s.peer && l.end == s.start => l.end = s.end,
                _ => p.spans.push(*s),
            }
        }
    }

    /// Whether anything waits.
    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    /// The records of typing quiet for [`SETTLE_SECS`] at NOW.
    pub fn settle_due(&mut self, h: &mut History, now: f64) -> Result<Vec<OpId>> {
        let due: Vec<Key> = self
            .pending
            .iter()
            .filter(|(_, p)| now - p.last >= SETTLE_SECS)
            .map(|(k, _)| k.clone())
            .collect();
        self.write(h, &due, "settled", now)
    }

    /// Every waiting record now, one per author per document (REASON says why).
    pub fn flush(&mut self, h: &mut History, reason: FlushReason, now: f64) -> Result<Vec<OpId>> {
        let all: Vec<Key> = self.pending.keys().cloned().collect();
        self.write(h, &all, reason.as_str(), now)
    }

    fn write(&mut self, h: &mut History, keys: &[Key], why: &str, now: f64) -> Result<Vec<OpId>> {
        let mut out = Vec::new();
        for k in keys {
            let Some(p) = self.pending.remove(k) else {
                continue;
            };
            let n: u32 = p.spans.iter().map(|s| s.end - s.start).sum();
            let path = h.path_of(k.1)?;
            let id = h.record(Record {
                kind: Kind::Edits,
                author: k.0,
                cause: p.cause,
                spans: p.spans.into_iter().map(|s| (k.1, s)).collect(),
                parents: self.last.into_iter().collect(),
                git: None,
                summary: format!("{n} operations in {path} ({why})"),
                at: now,
            })?;
            self.last = Some(id);
            out.push(id);
        }
        Ok(out)
    }
}
