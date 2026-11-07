//! vegvisir: the Work space's map core (`docs/develop/work-space.md`).
//!
//! The hub turns each of its sources (Urdr records, sessions and their steps, the edit history, the presence model,
//! git refs, machines, cards, the clock) into a typed [`Event`] and steps a [`Core`] with it. The core keeps the
//! map's [`Model`] (items in six fixed layers, the edges between them, overlaps, needs-you) and each view's state,
//! and returns [`Effect`]s: a delta for a shown view, a stale mark for a hidden one, a relayout when the user changed
//! a view. It never does I/O and never reads a clock, so its tests run it in every order of its inputs.
//!
//! The layout ([`layout::layout`]) runs in the same crate on a [`Model`] and a view's state.

mod chain;
#[cfg(feature = "fixture")]
pub mod fixture;
pub mod layout;
pub mod model;
mod overlap;
pub mod render;
mod view;

use std::collections::BTreeMap;
use std::fmt;

use serde::{Deserialize, Serialize};

pub use chain::Chain;
pub use model::{
    CardFact, CardKind, GraphFact, Item, JobFact, MachineFact, Mode, Model, NeedsYou,
    PresenceEntry, PresenceFact, RefFact, RunnerFact, SessionFact, State, StepFact,
};
pub use overlap::Overlap;
pub use view::{Density, Filters, ViewKey, ViewOp, ViewState};

/// An item's stable id: `ask:N`, `spec:ID`, `plan:ID`, `agent:SID`, `agent:SID/TOOLID` (a subagent),
/// `branch:REPO/NAME`, `file:REPO/PATH`, `machine:NAME`. Its prefix fixes its kind, so its layer never changes.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ItemId(pub String);

impl ItemId {
    pub fn new(kind: Kind, key: &str) -> ItemId {
        ItemId(format!("{}:{key}", kind.prefix()))
    }

    /// The kind its prefix names; `None` for a string that is no item id (`task:T`, say).
    pub fn kind(&self) -> Option<Kind> {
        Kind::of(&self.0)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ItemId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::borrow::Borrow<str> for ItemId {
    fn borrow(&self) -> &str {
        &self.0
    }
}

/// What an item is. Each kind lives in exactly one layer (design §5.1).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    Ask,
    Spec,
    Plan,
    Agent,
    Subagent,
    Branch,
    File,
    Machine,
}

impl Kind {
    /// 1 you asked, 2 specs, 3 plans, 4 agents, 5 branches and worktrees, 6 files and machines.
    pub fn layer(self) -> u8 {
        match self {
            Kind::Ask => 1,
            Kind::Spec => 2,
            Kind::Plan => 3,
            Kind::Agent | Kind::Subagent => 4,
            Kind::Branch => 5,
            Kind::File | Kind::Machine => 6,
        }
    }

    fn prefix(self) -> &'static str {
        match self {
            Kind::Ask => "ask",
            Kind::Spec => "spec",
            Kind::Plan => "plan",
            Kind::Agent | Kind::Subagent => "agent",
            Kind::Branch => "branch",
            Kind::File => "file",
            Kind::Machine => "machine",
        }
    }

    /// The kind of an id string. A subagent is `agent:SID/TOOLID`: an agent id with a slash.
    pub(crate) fn of(id: &str) -> Option<Kind> {
        let (prefix, key) = id.split_once(':')?;
        Some(match prefix {
            "ask" => Kind::Ask,
            "spec" => Kind::Spec,
            "plan" => Kind::Plan,
            "agent" if key.contains('/') => Kind::Subagent,
            "agent" => Kind::Agent,
            "branch" => Kind::Branch,
            "file" => Kind::File,
            "machine" => Kind::Machine,
            _ => return None,
        })
    }
}

/// An edge's kind (design §5.2).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum EdgeKind {
    /// ask → spec, plan or agent; spec → plan; plan → agent; agent → branch; parent agent → subagent.
    CameFrom,
    /// branch → file it changes.
    Edits,
    /// agent → file it read.
    Reads,
    /// agent → machine it holds a slot on.
    RunsOn,
    /// branch → the branch it was cut from.
    BasedOn,
    /// agent ↔ agent or branch ↔ branch through a shared file, or a clash card; `from` sorts before `to`.
    Overlap,
    /// agent → a file another live agent is editing (shown in the overlaps filter only).
    ReadVsEdit,
    /// manager agent → a worker it started.
    Manages,
}

impl EdgeKind {
    /// Whether the chain follows it: "came from" up, "touches" down (design §5.4).
    pub fn on_chain(self) -> bool {
        matches!(
            self,
            EdgeKind::CameFrom | EdgeKind::Edits | EdgeKind::Reads | EdgeKind::RunsOn
        )
    }
}

/// One edge of the model.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Edge {
    pub from: ItemId,
    pub to: ItemId,
    pub kind: EdgeKind,
}

/// What the hub feeds the core: one fact from one of its sources.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "kebab-case")]
// a session's fact is the biggest by far, and an event is made, fed once and dropped: boxing it would only add a
// hop to every use
#[allow(clippy::large_enum_variant)]
pub enum Event {
    /// An Urdr record: an ask, a spec, a plan, a task, or a link between them. Idempotent: an import again changes
    /// nothing.
    Graph(GraphFact),
    /// A session's (or a subagent's) current snapshot; it replaces the previous one.
    Session(SessionFact),
    /// A closed timeline step of a session.
    Step(StepFact),
    /// The edit history's changed files of one worktree, measured against `base`, untracked files included. Keys
    /// are `REPO/PATH`, values `(plus, minus)`. It replaces the worktree's previous set.
    Changed {
        worktree: String,
        base: String,
        files: BTreeMap<String, (u32, u32)>,
    },
    /// The presence model's entries for one file now; it replaces that file's previous entries.
    Presence(PresenceFact),
    /// The machine registry, whole.
    Machines(Vec<MachineFact>),
    /// A needs-you card opened, changed or settled.
    Card(CardFact),
    /// Every branch's ancestry and merge state, whole (recomputed when refs move).
    Refs(Vec<RefFact>),
    /// The clock's minute: time fields are minutes, so it raises one delta a minute.
    Tick { minute: u64 },
    /// A view opened, changed, shown, hidden or closed.
    View(ViewOp),
}

/// What changed in the model, for one view: ids only; the hub reads the items from the model.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Delta {
    /// Items new or changed that the view shows.
    pub changed: Vec<ItemId>,
    /// Items the view showed that are gone or no longer shown (finished, without "show finished").
    pub removed: Vec<ItemId>,
    /// The edge set changed.
    pub edges: bool,
    /// An item appeared, went, or changed its layer block or parent: the hub's coalescing decides when to reflow.
    pub structural: bool,
    /// The needs-you strip changed.
    pub needs_you: bool,
}

impl Delta {
    pub fn is_empty(&self) -> bool {
        self.changed.is_empty() && self.removed.is_empty() && !self.edges && !self.needs_you
    }
}

/// What the core asks its shell to do.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Effect {
    /// Send this shown view what changed.
    Delta { view: ViewKey, delta: Delta },
    /// A hidden view's frame went stale (sent once, until it is shown again).
    Stale { view: ViewKey },
    /// Lay this view out again and send it a full frame: the user opened, changed or showed it.
    Relayout { view: ViewKey },
}

struct ViewEntry {
    state: ViewState,
    shown: bool,
    stale: bool,
}

/// The map core: the model and each view's state.
#[derive(Default)]
pub struct Core {
    model: Model,
    views: BTreeMap<ViewKey, ViewEntry>,
}

impl Core {
    pub fn new() -> Core {
        Core::default()
    }

    pub fn model(&self) -> &Model {
        &self.model
    }

    /// A view's state, while it is open.
    pub fn view(&self, key: &ViewKey) -> Option<&ViewState> {
        self.views.get(key).map(|v| &v.state)
    }

    /// Whether an open view is shown.
    pub fn shown(&self, key: &ViewKey) -> Option<bool> {
        self.views.get(key).map(|v| v.shown)
    }

    /// Feeds one event; returns what the shell must send.
    pub fn step(&mut self, ev: Event) -> Vec<Effect> {
        match ev {
            Event::View(op) => self.view_op(op),
            ev => {
                let change = self.model.apply(ev);
                if change.is_empty() {
                    return Vec::new();
                }
                let mut out = Vec::new();
                for (key, v) in &mut self.views {
                    let delta = self.model.delta_for(&change, v.state.filters.finished);
                    if delta.is_empty() {
                        continue;
                    }
                    if v.shown {
                        out.push(Effect::Delta {
                            view: key.clone(),
                            delta,
                        });
                    } else if !v.stale {
                        v.stale = true;
                        out.push(Effect::Stale { view: key.clone() });
                    }
                }
                out
            }
        }
    }

    fn view_op(&mut self, op: ViewOp) -> Vec<Effect> {
        match op {
            ViewOp::Open { view, state, shown } => {
                self.views.insert(
                    view.clone(),
                    ViewEntry {
                        state,
                        shown,
                        stale: !shown,
                    },
                );
                if shown {
                    vec![Effect::Relayout { view }]
                } else {
                    Vec::new()
                }
            }
            ViewOp::Set { view, state } => match self.views.get_mut(&view) {
                Some(v) if v.state != state => {
                    v.state = state;
                    if v.shown {
                        vec![Effect::Relayout { view }]
                    } else {
                        v.stale = true;
                        Vec::new()
                    }
                }
                _ => Vec::new(),
            },
            ViewOp::Shown { view, shown } => match self.views.get_mut(&view) {
                Some(v) if v.shown != shown => {
                    v.shown = shown;
                    if shown {
                        v.stale = false;
                        vec![Effect::Relayout { view }]
                    } else {
                        Vec::new()
                    }
                }
                _ => Vec::new(),
            },
            ViewOp::Close { view } => {
                self.views.remove(&view);
                Vec::new()
            }
        }
    }
}
