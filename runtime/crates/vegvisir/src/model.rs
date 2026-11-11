//! The map's model: the facts the hub fed, and what they mean (items, edges, overlaps, needs-you).
//!
//! Facts are kept as the hub sent them, each source's latest value per key, so the model is the same whatever order
//! its sources' events arrive in. Everything shown is *derived* from the facts after each event: an edge exists only
//! while both of its ends do, an item's liveness and block follow from the records around it. Ids are interned to
//! numbers inside the model (the derivation runs once per event); everything public is keyed by [`ItemId`].

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::overlap::{self, OverlapD};
use crate::{Delta, Edge, EdgeKind, Event, ItemId, Kind, Overlap};

/// An Urdr record the map reads.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "record", rename_all = "kebab-case")]
pub enum GraphFact {
    /// `ask:KEY`: the user's words that started work.
    Ask { key: String, text: String },
    /// `spec:ID`.
    Spec { id: String, title: String },
    /// `plan:ID`; `rank` orders the plans (and so their blocks).
    Plan {
        id: String,
        title: String,
        rank: u64,
        #[serde(default)]
        progress: Option<(u32, u32)>,
    },
    /// A task of a plan (`parent_of` plan → task). Not an item: it folds into its agent's card.
    Task {
        id: String,
        plan: String,
        title: String,
        #[serde(default)]
        done: bool,
    },
    /// Link `asked`: ask `ask` (its key) → `to`, one of `spec:ID`, `plan:ID`, `task:ID` or `agent:SID`.
    Asked { ask: String, to: String },
    /// Link `derives`: plan → spec.
    Derives { plan: String, spec: String },
}

/// A session's live state (design §5.3).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum State {
    Queued,
    Running,
    Waiting,
    NeedsYou,
    Review,
    Paused,
    Stalled,
    /// The session ended; the agent stays on the map until its branch merges or its task is done.
    Finished,
}

/// A session's (or subagent's) snapshot. A subagent's `id` is `SID/TOOLID`: its parent is `SID`, and it shares the
/// parent's branch and worktree.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionFact {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub model: String,
    pub state: State,
    /// The minute its current state began.
    #[serde(default)]
    pub since: u64,
    /// Start order (the team order inside a block).
    #[serde(default)]
    pub seq: u64,
    /// The task it works on (`works_on`).
    #[serde(default)]
    pub task: Option<String>,
    /// The session that started it.
    #[serde(default)]
    pub manager: Option<String>,
    /// `REPO/NAME`.
    #[serde(default)]
    pub branch: Option<String>,
    #[serde(default)]
    pub worktree: Option<String>,
    /// The base commit recorded when its worktree was created (`worktree_base`).
    #[serde(default)]
    pub base: Option<String>,
    /// The machine it holds a slot on, or waits for.
    #[serde(default)]
    pub machine: Option<String>,
    /// Spend with its unit, as the card shows it (`$1.20`, `≈$1.20`, `2.1 % wk`).
    #[serde(default)]
    pub spend: Option<String>,
    /// Context use, percent.
    #[serde(default)]
    pub context: Option<u8>,
    /// Its own plan entries done/total, when its task has no plan steps.
    #[serde(default)]
    pub progress: Option<(u32, u32)>,
    /// The job it started that runs or waits now.
    #[serde(default)]
    pub job: Option<JobFact>,
}

/// A job a session started, as its card and its machine's queue show it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct JobFact {
    pub id: String,
    pub name: String,
    /// The machine it runs on; none while it waits.
    #[serde(default)]
    pub runner: Option<String>,
    /// `running` or `waiting`.
    pub state: String,
    /// When it started (seconds since the epoch), as the hub's row says; the card works the elapsed time out.
    pub started: u64,
    /// Its time box, in whole minutes.
    #[serde(default)]
    pub limit_min: Option<u32>,
    /// The names of the keys sent to it (never their values).
    #[serde(default)]
    pub keys: Vec<String>,
}

/// A closed timeline step.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StepFact {
    pub session: String,
    pub step: i64,
    /// The step's class (`edit`, `read`, `test`, …), shown as the card's activity.
    pub class: String,
    pub minute: u64,
    /// A conclusion recorded at this step (a decision or a finding), one line.
    #[serde(default)]
    pub conclusion: Option<String>,
}

/// A presence entry's mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Mode {
    Read,
    Edit,
    Listed,
    Write,
}

impl Mode {
    fn edits(self) -> bool {
        matches!(self, Mode::Edit | Mode::Write)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresenceEntry {
    pub session: String,
    pub mode: Mode,
    #[serde(default)]
    pub line: Option<u32>,
}

/// The presence model's entries for one file (`REPO/PATH`) now.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresenceFact {
    pub file: String,
    pub entries: Vec<PresenceEntry>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MachineFact {
    pub name: String,
    pub slots: u32,
    pub used: u32,
    /// Reported by `machines/report` (jobq), not the hub's own pool.
    #[serde(default)]
    pub reported: bool,
    /// What the hub knows of it when it is one of its runners.
    #[serde(default)]
    pub runner: Option<RunnerFact>,
}

/// A runner's side of a machine: trust, state (its reason when it is out of rotation), jobs, icon and, for cloud, the
/// cost text.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunnerFact {
    pub trust: String,
    pub state: String,
    pub jobs: u32,
    /// `monitor`, `laptop`, `server` or `cloud`.
    pub icon: String,
    #[serde(default)]
    pub cost: Option<String>,
    /// A Mac runner: its chip says `macOS` after its name. Absent means false, so other runners' frames are as before.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub mac: bool,
}

/// What a needs-you card is (part 1's cards).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CardKind {
    Permission,
    Push,
    SignOff,
    Question,
    Supervisor,
    Budget,
    Clash,
    Proposal,
}

/// A card. A clash card names the two agents it is about.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CardFact {
    pub id: String,
    pub kind: CardKind,
    /// The items it is about (item ids).
    #[serde(default)]
    pub about: Vec<String>,
    pub text: String,
    /// Open until settled.
    pub open: bool,
}

/// One branch's ancestry and merge state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RefFact {
    /// `REPO/NAME`.
    pub branch: String,
    /// The branch it was cut from, `REPO/NAME`.
    #[serde(default)]
    pub based_on: Option<String>,
    #[serde(default)]
    pub merged: bool,
}

/// What a card's fields show (design §5.3); only what the item's kind has is set.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Fields {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<State>,
    /// Minutes in the current state.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minutes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    /// An agent's task's id (`task:ID`), which tells two tasks of one title apart: the hub's Board puts the agent on
    /// that card only. The hub's own; the editor gets the title.
    #[serde(skip)]
    pub task_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub spend: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<(u32, u32)>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub activity: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conclusion: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manager: Option<ItemId>,
    /// A branch's repository (its caption).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    /// A branch's "edits N" chip: files, plus, minus.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edits: Option<(u32, u32, u32)>,
    /// A file's `+/−` on the branch that changes it most.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub change: Option<(u32, u32)>,
    /// An agent's reads, counted.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reads: Option<u32>,
    /// A machine's slots: used, total.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub slots: Option<(u32, u32)>,
    /// A machine that is one of the hub's runners.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runner: Option<RunnerFact>,
    /// An agent's job.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job: Option<JobFact>,
}

/// One item of the map.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub id: ItemId,
    pub kind: Kind,
    pub label: String,
    /// On the map without "show finished".
    pub live: bool,
    /// The plan whose block it sits in (agents and branches); `None`: the "No plan" block.
    pub block: Option<ItemId>,
    /// A subagent's parent agent; a branch's agent.
    pub parent: Option<ItemId>,
    /// Order inside its row: a plan's rank, an agent's start order.
    pub order: u64,
    /// Carries an overlap or a clash (the ⚠ chip).
    pub warn: bool,
    pub needs_you: bool,
    /// A file in an overlap: drawn as a node by default.
    pub shared: bool,
    pub fields: Fields,
}

/// One chip of the needs-you strip.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NeedsYou {
    pub card: String,
    pub kind: CardKind,
    pub text: String,
    pub about: Vec<ItemId>,
}

pub(crate) type Sym = u32;

/// The interner: every id string the model has seen, and its kind.
#[derive(Clone, Default)]
pub(crate) struct Names {
    names: Vec<String>,
    kinds: Vec<Option<Kind>>,
    ids: BTreeMap<String, Sym>,
}

impl Names {
    fn intern(&mut self, s: &str) -> Sym {
        if let Some(&y) = self.ids.get(s) {
            return y;
        }
        let y = Sym::try_from(self.names.len()).expect("fewer than 2^32 names");
        self.names.push(s.to_string());
        self.kinds.push(Kind::of(s));
        self.ids.insert(s.to_string(), y);
        y
    }

    fn intern_as(&mut self, prefix: &str, key: &str) -> Sym {
        self.intern(&format!("{prefix}:{key}"))
    }

    pub(crate) fn get(&self, s: &str) -> Option<Sym> {
        self.ids.get(s).copied()
    }

    pub(crate) fn name(&self, y: Sym) -> &str {
        &self.names[y as usize]
    }

    pub(crate) fn id(&self, y: Sym) -> ItemId {
        ItemId(self.names[y as usize].clone())
    }

    fn kind(&self, y: Sym) -> Option<Kind> {
        self.kinds[y as usize]
    }
}

#[derive(Clone)]
struct Sess {
    fact: SessionFact,
    /// The parent agent of a subagent.
    parent: Option<Sym>,
    task: Option<Sym>,
    manager: Option<Sym>,
    branch: Option<Sym>,
    wt: Option<Sym>,
    machine: Option<Sym>,
}

#[derive(Clone, Default, PartialEq, Eq)]
struct Steps {
    last: i64,
    class: String,
    conclusion: Option<(i64, String)>,
}

#[derive(Clone, PartialEq, Eq)]
struct Changed {
    base: String,
    /// (file, plus, minus), sorted by file.
    files: Vec<(Sym, u32, u32)>,
}

/// A plan's title, rank and progress.
type PlanF = (String, u64, Option<(u32, u32)>);

/// Every fact, each source's latest per key.
#[derive(Clone, Default)]
struct Facts {
    asks: BTreeMap<Sym, String>,
    specs: BTreeMap<Sym, String>,
    plans: BTreeMap<Sym, PlanF>,
    /// task → (plan, title, done)
    tasks: BTreeMap<Sym, (Sym, String, bool)>,
    asked: BTreeSet<(Sym, Sym)>,
    /// (plan, spec)
    derives: BTreeSet<(Sym, Sym)>,
    sessions: BTreeMap<Sym, Sess>,
    steps: BTreeMap<Sym, Steps>,
    changed: BTreeMap<Sym, Changed>,
    /// file → (agent, mode, line), sorted
    presence: BTreeMap<Sym, Vec<(Sym, Mode, Option<u32>)>>,
    machines: BTreeMap<Sym, MachineFact>,
    /// card → (fact, about)
    cards: BTreeMap<Sym, (CardFact, Vec<Sym>)>,
    /// branch → (based on, merged)
    refs: BTreeMap<Sym, (Option<Sym>, bool)>,
    minute: u64,
}

/// What is derived for one present item.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ItemD {
    pub(crate) kind: Kind,
    pub(crate) live: bool,
    pub(crate) block: Option<Sym>,
    pub(crate) parent: Option<Sym>,
    pub(crate) order: u64,
    pub(crate) warn: bool,
    pub(crate) needs_you: bool,
    pub(crate) shared: bool,
}

#[derive(Clone, Default)]
pub(crate) struct Derived {
    pub(crate) items: BTreeMap<Sym, ItemD>,
    /// Sorted, without duplicates.
    pub(crate) edges: Vec<(Sym, Sym, EdgeKind)>,
    /// Keyed by the pair, the first sorting first by name.
    pub(crate) overlaps: BTreeMap<(Sym, Sym), OverlapD>,
    /// Open cards, sorted by sym.
    pub(crate) needs_you: Vec<Sym>,
}

/// What one event changed: per item, before and after, and whether its fields changed.
#[derive(Default)]
pub(crate) struct Change {
    items: Vec<(Sym, Option<ItemD>, Option<ItemD>, bool)>,
    edges: bool,
    needs_you: bool,
}

impl Change {
    pub(crate) fn is_empty(&self) -> bool {
        self.items.is_empty() && !self.edges && !self.needs_you
    }
}

/// The map's model.
#[derive(Clone, Default)]
pub struct Model {
    pub(crate) names: Names,
    facts: Facts,
    pub(crate) d: Derived,
}

impl Model {
    /// Applies one fact (never a view event) and derives the model again.
    pub(crate) fn apply(&mut self, ev: Event) -> Change {
        let Some((touched, card)) = self.ingest(ev) else {
            return Change::default();
        };
        let new = self.derive();
        let old = std::mem::replace(&mut self.d, new);
        let mut change = Change {
            edges: old.edges != self.d.edges,
            needs_you: card || old.needs_you != self.d.needs_you,
            ..Change::default()
        };
        let mut syms: BTreeSet<Sym> = touched.clone();
        syms.extend(old.items.keys());
        syms.extend(self.d.items.keys());
        for y in syms {
            let a = old.items.get(&y);
            let b = self.d.items.get(&y);
            let fields = b.is_some() && touched.contains(&y);
            if a != b || fields {
                change.items.push((y, a.cloned(), b.cloned(), fields));
            }
        }
        change
    }

    /// The delta a view with (or without) "show finished" gets for a change.
    pub(crate) fn delta_for(&self, change: &Change, finished: bool) -> Delta {
        let mut delta = Delta {
            edges: change.edges,
            needs_you: change.needs_you,
            ..Delta::default()
        };
        for (y, a, b, fields) in &change.items {
            let shown = |d: &Option<ItemD>| d.as_ref().is_some_and(|d| d.live || finished);
            let (was, is) = (shown(a), shown(b));
            if is && (!was || a != b || *fields) {
                delta.changed.push(self.names.id(*y));
            }
            if was && !is {
                delta.removed.push(self.names.id(*y));
            }
            let moved = match (a, b) {
                (Some(a), Some(b)) => a.block != b.block || a.parent != b.parent,
                _ => false,
            };
            if was != is || (is && moved) {
                delta.structural = true;
            }
        }
        if !delta.changed.is_empty() || !delta.removed.is_empty() || delta.structural {
            delta.changed.sort();
            delta.removed.sort();
        } else if !(delta.edges || delta.needs_you) {
            return Delta::default();
        }
        delta
    }

    // ---- the public reads ----

    /// Every present item (live or finished).
    pub fn items(&self) -> BTreeMap<ItemId, Item> {
        self.d
            .items
            .keys()
            .map(|&y| (self.names.id(y), self.materialize(y)))
            .collect()
    }

    pub fn item(&self, id: &ItemId) -> Option<Item> {
        let y = self.names.get(id.as_str())?;
        self.d.items.contains_key(&y).then(|| self.materialize(y))
    }

    /// Every edge, sorted by (from, to, kind).
    pub fn edges(&self) -> Vec<Edge> {
        let mut out: Vec<Edge> = self
            .d
            .edges
            .iter()
            .map(|&(a, b, kind)| Edge {
                from: self.names.id(a),
                to: self.names.id(b),
                kind,
            })
            .collect();
        out.sort();
        out
    }

    /// Every overlap and clash, sorted by its pair.
    pub fn overlaps(&self) -> Vec<Overlap> {
        let mut out: Vec<Overlap> = self
            .d
            .overlaps
            .iter()
            .map(|(&(a, b), o)| Overlap {
                a: self.names.id(a),
                b: self.names.id(b),
                files: {
                    let mut f: Vec<ItemId> = o.files.iter().map(|&y| self.names.id(y)).collect();
                    f.sort();
                    f
                },
                clash: o.clash,
            })
            .collect();
        out.sort_by(|x, y| (&x.a, &x.b).cmp(&(&y.a, &y.b)));
        out
    }

    /// The needs-you strip: open cards, sorted by id.
    pub fn needs_you(&self) -> Vec<NeedsYou> {
        let mut out: Vec<NeedsYou> = self
            .d
            .needs_you
            .iter()
            .map(|y| {
                let (c, about) = &self.facts.cards[y];
                let mut about: Vec<ItemId> = about
                    .iter()
                    .filter(|a| self.d.items.contains_key(a))
                    .map(|&a| self.names.id(a))
                    .collect();
                about.sort();
                NeedsYou {
                    card: c.id.clone(),
                    kind: c.kind,
                    text: c.text.clone(),
                    about,
                }
            })
            .collect();
        out.sort_by(|a, b| a.card.cmp(&b.card));
        out
    }

    /// The clock's minute.
    pub fn minute(&self) -> u64 {
        self.facts.minute
    }

    fn materialize(&self, y: Sym) -> Item {
        let d = &self.d.items[&y];
        let f = &self.facts;
        let mut fields = Fields::default();
        let label = match d.kind {
            Kind::Ask => f.asks.get(&y).cloned().unwrap_or_default(),
            Kind::Spec => f.specs.get(&y).cloned().unwrap_or_default(),
            Kind::Plan => {
                let (title, _, progress) = &f.plans[&y];
                fields.progress = *progress;
                title.clone()
            }
            Kind::Agent | Kind::Subagent => {
                let s = &f.sessions[&y];
                fields.state = Some(s.fact.state);
                fields.minutes = Some(f.minute.saturating_sub(s.fact.since));
                fields.model = (!s.fact.model.is_empty()).then(|| s.fact.model.clone());
                fields.spend = s.fact.spend.clone();
                fields.job = s.fact.job.clone();
                fields.context = s.fact.context;
                let task = s.task.or_else(|| {
                    s.parent
                        .and_then(|p| f.sessions.get(&p))
                        .and_then(|p| p.task)
                });
                let task = task.filter(|t| f.tasks.contains_key(t));
                fields.task = task.map(|t| f.tasks[&t].1.clone());
                fields.task_id = task.map(|t| self.names.name(t).to_owned());
                fields.progress = s.fact.progress;
                fields.manager = s
                    .manager
                    .filter(|m| self.d.items.contains_key(m))
                    .map(|m| self.names.id(m));
                if let Some(st) = f.steps.get(&y) {
                    fields.activity = Some(st.class.clone());
                    fields.conclusion = st.conclusion.as_ref().map(|c| c.1.clone());
                }
                let reads = f
                    .presence
                    .values()
                    .filter(|es| es.iter().any(|&(a, m, _)| a == y && !m.edits()))
                    .count();
                fields.reads = Some(u32::try_from(reads).unwrap_or(u32::MAX));
                if s.fact.model.is_empty() {
                    s.fact.name.clone()
                } else {
                    format!("{} · {}", s.fact.model, s.fact.name)
                }
            }
            Kind::Branch => {
                let name = self.names.name(y).trim_start_matches("branch:");
                let (repo, short) = name.split_once('/').unwrap_or(("", name));
                fields.repo = Some(repo.to_string());
                let set = self.branch_set(y);
                if !set.is_empty() {
                    let (p, m) = set.iter().fold((0, 0), |(p, m), &(_, a, b)| (p + a, m + b));
                    fields.edits = Some((u32::try_from(set.len()).unwrap_or(u32::MAX), p, m));
                }
                short.to_string()
            }
            Kind::File => {
                let path = self.names.name(y).trim_start_matches("file:");
                fields.change = f
                    .changed
                    .values()
                    .flat_map(|c| c.files.iter().filter(|e| e.0 == y))
                    .map(|&(_, p, m)| (p, m))
                    .max();
                path.to_string()
            }
            Kind::Machine => {
                let m = &f.machines[&y];
                fields.slots = Some((m.used, m.slots));
                fields.runner = m.runner.clone();
                m.name.clone()
            }
        };
        Item {
            id: self.names.id(y),
            kind: d.kind,
            label,
            live: d.live,
            block: d.block.map(|b| self.names.id(b)),
            parent: d.parent.map(|p| self.names.id(p)),
            order: d.order,
            warn: d.warn,
            needs_you: d.needs_you,
            shared: d.shared,
            fields,
        }
    }

    /// A branch's changed files with counts, against its recorded base (for its chip).
    fn branch_set(&self, b: Sym) -> Vec<(Sym, u32, u32)> {
        let f = &self.facts;
        let owner = f
            .sessions
            .iter()
            .filter(|(_, s)| s.parent.is_none() && s.branch == Some(b))
            .min_by(|x, y| {
                (x.1.fact.seq, self.names.name(*x.0)).cmp(&(y.1.fact.seq, self.names.name(*y.0)))
            });
        let Some((_, s)) = owner else {
            return Vec::new();
        };
        match s.wt.and_then(|w| f.changed.get(&w)) {
            Some(c) if s.fact.base.as_ref().is_none_or(|base| *base == c.base) => c.files.clone(),
            _ => Vec::new(),
        }
    }

    // ---- ingest ----

    /// Stores a fact; returns the items whose fields it changed and whether it changed a card, or `None` when it
    /// changes nothing (the same record again).
    fn ingest(&mut self, ev: Event) -> Option<(BTreeSet<Sym>, bool)> {
        let mut touched = BTreeSet::new();
        let mut card = false;
        let n = &mut self.names;
        let f = &mut self.facts;
        match ev {
            Event::Graph(g) => match g {
                GraphFact::Ask { key, text } => {
                    let y = n.intern_as("ask", &key);
                    if f.asks.get(&y) == Some(&text) {
                        return None;
                    }
                    f.asks.insert(y, text);
                    touched.insert(y);
                }
                GraphFact::Spec { id, title } => {
                    let y = n.intern_as("spec", &id);
                    if f.specs.get(&y) == Some(&title) {
                        return None;
                    }
                    f.specs.insert(y, title);
                    touched.insert(y);
                }
                GraphFact::Plan {
                    id,
                    title,
                    rank,
                    progress,
                } => {
                    let y = n.intern_as("plan", &id);
                    let v = (title, rank, progress);
                    if f.plans.get(&y) == Some(&v) {
                        return None;
                    }
                    f.plans.insert(y, v);
                    touched.insert(y);
                }
                GraphFact::Task {
                    id,
                    plan,
                    title,
                    done,
                } => {
                    let t = n.intern_as("task", &id);
                    let v = (n.intern_as("plan", &plan), title, done);
                    if f.tasks.get(&t) == Some(&v) {
                        return None;
                    }
                    f.tasks.insert(t, v);
                    // the task's title is on its agents' cards
                    touched.extend(
                        f.sessions
                            .iter()
                            .filter(|(_, s)| s.task == Some(t))
                            .map(|(&a, _)| a),
                    );
                }
                GraphFact::Asked { ask, to } => {
                    let a = n.intern_as("ask", &ask);
                    let t = n.intern(&to);
                    if !f.asked.insert((a, t)) {
                        return None;
                    }
                }
                GraphFact::Derives { plan, spec } => {
                    let p = n.intern_as("plan", &plan);
                    let s = n.intern_as("spec", &spec);
                    if !f.derives.insert((p, s)) {
                        return None;
                    }
                }
            },
            Event::Session(s) => {
                let y = n.intern_as("agent", &s.id);
                let old = f.sessions.get(&y).map(|o| &o.fact);
                if old == Some(&s) {
                    return None;
                }
                // a branch's chip counts against its owner's worktree and base
                if old.is_none_or(|o| {
                    (&o.branch, &o.worktree, &o.base) != (&s.branch, &s.worktree, &s.base)
                }) {
                    touched.extend(f.sessions.get(&y).and_then(|o| o.branch));
                    touched.extend(s.branch.as_deref().map(|b| n.intern_as("branch", b)));
                }
                let parent = s.id.split_once('/').map(|(p, _)| n.intern_as("agent", p));
                let sess = Sess {
                    parent,
                    task: s.task.as_deref().map(|t| n.intern_as("task", t)),
                    manager: s.manager.as_deref().map(|m| n.intern_as("agent", m)),
                    branch: s.branch.as_deref().map(|b| n.intern_as("branch", b)),
                    wt: s.worktree.as_deref().map(|w| n.intern_as("wt", w)),
                    machine: s.machine.as_deref().map(|m| n.intern_as("machine", m)),
                    fact: s,
                };
                f.sessions.insert(y, sess);
                touched.insert(y);
            }
            Event::Step(st) => {
                let y = n.intern_as("agent", &st.session);
                let agg = f.steps.entry(y).or_default();
                let mut new = agg.clone();
                if st.step >= new.last {
                    new.last = st.step;
                    new.class = st.class;
                }
                if let Some(c) = st.conclusion
                    && new.conclusion.as_ref().is_none_or(|(at, _)| st.step >= *at)
                {
                    new.conclusion = Some((st.step, c));
                }
                if *agg == new {
                    return None;
                }
                *agg = new;
                touched.insert(y);
            }
            Event::Changed {
                worktree,
                base,
                files,
            } => {
                let w = n.intern_as("wt", &worktree);
                let mut list: Vec<(Sym, u32, u32)> = files
                    .iter()
                    .map(|(p, &(a, b))| (n.intern_as("file", p), a, b))
                    .collect();
                list.sort_unstable();
                let new = Changed { base, files: list };
                let old = f.changed.insert(w, new.clone());
                if old.as_ref() == Some(&new) {
                    return None;
                }
                touched.extend(new.files.iter().map(|e| e.0));
                touched.extend(old.iter().flat_map(|c| c.files.iter().map(|e| e.0)));
                touched.extend(
                    f.sessions
                        .values()
                        .filter(|s| s.wt == Some(w))
                        .filter_map(|s| s.branch),
                );
            }
            Event::Presence(p) => {
                let file = n.intern_as("file", &p.file);
                let mut list: Vec<(Sym, Mode, Option<u32>)> = p
                    .entries
                    .iter()
                    .map(|e| (n.intern_as("agent", &e.session), e.mode, e.line))
                    .collect();
                list.sort_unstable();
                list.dedup();
                let old = if list.is_empty() {
                    f.presence.remove(&file)
                } else {
                    f.presence.insert(file, list.clone())
                };
                if old.as_ref().unwrap_or(&Vec::new()) == &list {
                    return None;
                }
                touched.insert(file);
                touched.extend(list.iter().map(|e| e.0));
                touched.extend(old.iter().flatten().map(|e| e.0));
            }
            Event::Machines(ms) => {
                let new: BTreeMap<Sym, MachineFact> = ms
                    .into_iter()
                    .map(|m| (n.intern_as("machine", &m.name), m))
                    .collect();
                if new == f.machines {
                    return None;
                }
                touched.extend(new.keys());
                touched.extend(f.machines.keys());
                f.machines = new;
            }
            Event::Card(c) => {
                let y = n.intern_as("card", &c.id);
                if f.cards.get(&y).is_some_and(|(old, _)| *old == c) {
                    return None;
                }
                let about = c.about.iter().map(|a| n.intern(a)).collect();
                f.cards.insert(y, (c, about));
                card = true;
            }
            Event::Refs(rs) => {
                let new: BTreeMap<Sym, (Option<Sym>, bool)> = rs
                    .iter()
                    .map(|r| {
                        let b = n.intern_as("branch", &r.branch);
                        (
                            b,
                            (
                                r.based_on.as_deref().map(|x| n.intern_as("branch", x)),
                                r.merged,
                            ),
                        )
                    })
                    .collect();
                if new == f.refs {
                    return None;
                }
                f.refs = new;
            }
            Event::Tick { minute } => {
                if minute <= f.minute {
                    return None;
                }
                f.minute = minute;
                touched.extend(f.sessions.keys());
            }
            Event::View(_) => return None,
        }
        Some((touched, card))
    }

    // ---- derive ----

    /// Everything shown, from the facts alone.
    fn derive(&self) -> Derived {
        let f = &self.facts;
        let n = &self.names;
        let mut d = Derived::default();

        // agents: a subagent takes its parent's task and branch
        struct A {
            top: bool,
            parent: Option<Sym>,
            plan: Option<Sym>,
            task: Option<Sym>,
            branch: Option<Sym>,
            live: bool,
        }
        let mut agents: BTreeMap<Sym, A> = BTreeMap::new();
        for (&a, s) in &f.sessions {
            let p = s.parent.and_then(|p| f.sessions.get(&p).map(|ps| (p, ps)));
            let task = s.task.or(p.and_then(|(_, ps)| ps.task));
            let branch = if s.parent.is_some() {
                p.and_then(|(_, ps)| ps.branch)
            } else {
                s.branch
            };
            let plan = task
                .and_then(|t| f.tasks.get(&t))
                .map(|t| t.0)
                .filter(|pl| f.plans.contains_key(pl));
            let done = task.and_then(|t| f.tasks.get(&t)).is_some_and(|t| t.2);
            let merged = branch.and_then(|b| f.refs.get(&b)).is_some_and(|r| r.1);
            let live = s.fact.state != State::Finished || !(done || merged);
            agents.insert(
                a,
                A {
                    top: s.parent.is_none(),
                    parent: p.map(|(p, _)| p),
                    plan,
                    task,
                    branch,
                    live,
                },
            );
        }
        let order = |a: Sym| (f.sessions[&a].fact.seq, n.name(a));

        // branches: an agent's branch, and the branch a present one was cut from
        struct B {
            owner: Option<Sym>,
            block: Option<Sym>,
            live: bool,
        }
        let mut branches: BTreeMap<Sym, B> = BTreeMap::new();
        for (&a, ag) in &agents {
            let Some(b) = ag.branch else { continue };
            let e = branches.entry(b).or_insert(B {
                owner: None,
                block: None,
                live: false,
            });
            e.live |= ag.live;
            if ag.top && e.owner.is_none_or(|o| order(a) < order(o)) {
                e.owner = Some(a);
                e.block = ag.plan;
            }
        }
        let mut bases: Vec<(Sym, Sym, bool, Option<Sym>)> = Vec::new();
        for (&b, br) in &branches {
            if let Some(&(Some(base), _)) = f.refs.get(&b)
                && base != b
            {
                bases.push((base, b, br.live, br.block));
            }
        }
        // the dependent branch that sorts first gives a base-only branch its block
        bases.sort_by(|x, y| (x.0, n.name(x.1)).cmp(&(y.0, n.name(y.1))));
        for (base, _, live, block) in bases {
            let e = branches.entry(base).or_insert(B {
                owner: None,
                block,
                live: false,
            });
            e.live |= live;
        }

        // each branch's changed files: the edit history against its base, plus edits in flight
        let mut sets: BTreeMap<Sym, BTreeSet<Sym>> = BTreeMap::new();
        for (&b, br) in &branches {
            let Some(o) = br.owner else { continue };
            let s = &f.sessions[&o];
            if let Some(c) = s.wt.and_then(|w| f.changed.get(&w))
                && s.fact.base.as_ref().is_none_or(|base| *base == c.base)
            {
                sets.entry(b)
                    .or_default()
                    .extend(c.files.iter().map(|e| e.0));
            }
        }
        // per agent: its edits and reads in flight (the presence model)
        let mut agent_edits: BTreeMap<Sym, BTreeSet<Sym>> = BTreeMap::new();
        let mut agent_reads: BTreeMap<Sym, BTreeSet<Sym>> = BTreeMap::new();
        for (&file, es) in &f.presence {
            for &(a, m, _) in es {
                let Some(ag) = agents.get(&a) else { continue };
                if m.edits() {
                    agent_edits.entry(a).or_default().insert(file);
                    if let Some(b) = ag.branch.filter(|b| branches.contains_key(b)) {
                        sets.entry(b).or_default().insert(file);
                    }
                } else {
                    agent_reads.entry(a).or_default().insert(file);
                }
            }
        }

        // files: changed by a present branch or touched by a present agent
        let mut files: BTreeMap<Sym, bool> = BTreeMap::new();
        for (b, set) in &sets {
            let live = branches[b].live;
            for &x in set {
                *files.entry(x).or_default() |= live;
            }
        }
        for (a, set) in agent_edits.iter().chain(&agent_reads) {
            let live = agents[a].live;
            for &x in set {
                *files.entry(x).or_default() |= live;
            }
        }

        // the layers above: live while a live agent is under them, or a live ask links them
        let live_plans: BTreeSet<Sym> = agents
            .values()
            .filter(|a| a.live)
            .filter_map(|a| a.plan)
            .collect();
        let mut live_specs: BTreeSet<Sym> = f
            .derives
            .iter()
            .filter(|(p, _)| live_plans.contains(p))
            .map(|&(_, s)| s)
            .collect();
        let target_live = |t: Sym| match n.kind(t) {
            Some(Kind::Agent | Kind::Subagent) => agents.get(&t).is_some_and(|a| a.live),
            Some(Kind::Plan) => live_plans.contains(&t),
            Some(Kind::Spec) => live_specs.contains(&t),
            _ => agents.values().any(|a| a.live && a.task == Some(t)),
        };
        let live_asks: BTreeSet<Sym> = f
            .asked
            .iter()
            .filter(|&&(a, t)| f.asks.contains_key(&a) && target_live(t))
            .map(|&(a, _)| a)
            .collect();
        let mut live_plans = live_plans;
        for &(a, t) in &f.asked {
            if live_asks.contains(&a) {
                match n.kind(t) {
                    Some(Kind::Plan) => {
                        live_plans.insert(t);
                    }
                    Some(Kind::Spec) => {
                        live_specs.insert(t);
                    }
                    _ => {}
                }
            }
        }

        // the items
        let item = |kind, live, block, parent, order| ItemD {
            kind,
            live,
            block,
            parent,
            order,
            warn: false,
            needs_you: false,
            shared: false,
        };
        for &a in f.asks.keys() {
            d.items
                .insert(a, item(Kind::Ask, live_asks.contains(&a), None, None, 0));
        }
        for &s in f.specs.keys() {
            d.items
                .insert(s, item(Kind::Spec, live_specs.contains(&s), None, None, 0));
        }
        for (&p, (_, rank, _)) in &f.plans {
            d.items.insert(
                p,
                item(Kind::Plan, live_plans.contains(&p), None, None, *rank),
            );
        }
        for (&a, ag) in &agents {
            let kind = if ag.top { Kind::Agent } else { Kind::Subagent };
            let block = if ag.top {
                ag.plan
            } else {
                ag.parent.and_then(|p| agents[&p].plan).or(ag.plan)
            };
            d.items.insert(
                a,
                item(kind, ag.live, block, ag.parent, f.sessions[&a].fact.seq),
            );
        }
        for (&b, br) in &branches {
            d.items
                .insert(b, item(Kind::Branch, br.live, br.block, br.owner, 0));
        }
        for (&x, &live) in &files {
            d.items.insert(x, item(Kind::File, live, None, None, 0));
        }
        for &m in f.machines.keys() {
            d.items.insert(m, item(Kind::Machine, true, None, None, 0));
        }

        // the edges, between present items only
        let present = |y: &Sym| d.items.contains_key(y);
        let mut edges: Vec<(Sym, Sym, EdgeKind)> = Vec::new();
        for &(a, t) in &f.asked {
            if !present(&a) {
                continue;
            }
            match n.kind(t) {
                Some(_) => edges.push((a, t, EdgeKind::CameFrom)),
                None => edges.extend(
                    agents
                        .iter()
                        .filter(|(_, ag)| ag.top && ag.task == Some(t))
                        .map(|(&g, _)| (a, g, EdgeKind::CameFrom)),
                ),
            }
        }
        edges.extend(f.derives.iter().map(|&(p, s)| (s, p, EdgeKind::CameFrom)));
        for (&a, ag) in &agents {
            let s = &f.sessions[&a];
            match ag.parent {
                Some(p) => edges.push((p, a, EdgeKind::CameFrom)),
                None => {
                    if let Some(pl) = ag.plan {
                        edges.push((pl, a, EdgeKind::CameFrom));
                    }
                    if let Some(b) = ag.branch {
                        edges.push((a, b, EdgeKind::CameFrom));
                    }
                }
            }
            if let Some(m) = s.machine {
                edges.push((a, m, EdgeKind::RunsOn));
            }
            if let Some(m) = s.manager {
                edges.push((m, a, EdgeKind::Manages));
            }
        }
        for (&a, set) in &agent_reads {
            edges.extend(set.iter().map(|&x| (a, x, EdgeKind::Reads)));
        }
        for (&b, set) in &sets {
            edges.extend(set.iter().map(|&x| (b, x, EdgeKind::Edits)));
        }
        for (&b, &(base, _)) in &f.refs {
            if let Some(base) = base
                && base != b
            {
                edges.push((b, base, EdgeKind::BasedOn));
            }
        }
        // reading a file another live branch is changing
        for (&a, set) in &agent_reads {
            let mine = agents[&a].branch;
            for &x in set {
                if sets
                    .iter()
                    .any(|(b, s)| Some(*b) != mine && branches[b].live && s.contains(&x))
                {
                    edges.push((a, x, EdgeKind::ReadVsEdit));
                }
            }
        }

        // overlaps and clashes
        let live_sets: BTreeMap<Sym, &BTreeSet<Sym>> = sets
            .iter()
            .filter(|(b, _)| branches[*b].live)
            .map(|(&b, s)| (b, s))
            .collect();
        let mut owners: BTreeMap<Sym, Vec<Sym>> = BTreeMap::new();
        let mut on_branch: BTreeMap<Sym, Vec<Sym>> = BTreeMap::new();
        for (&a, ag) in &agents {
            if let (true, Some(b)) = (ag.live, ag.branch) {
                if ag.top {
                    owners.entry(b).or_default().push(a);
                }
                on_branch.entry(b).or_default().push(a);
            }
        }
        let clashes: Vec<(Sym, Sym)> = f
            .cards
            .values()
            .filter(|(c, about)| c.open && c.kind == CardKind::Clash && about.len() == 2)
            .map(|(_, about)| (about[0], about[1]))
            .filter(|(x, y)| x != y && agents.contains_key(x) && agents.contains_key(y))
            .collect();
        d.overlaps = overlap::compute(
            &live_sets,
            &owners,
            &on_branch,
            &agent_edits,
            &clashes,
            |y| n.name(y),
        );
        for (&(a, b), o) in &d.overlaps {
            edges.push((a, b, EdgeKind::Overlap));
            for y in [a, b] {
                if let Some(it) = d.items.get_mut(&y) {
                    it.warn = true;
                }
            }
            for x in &o.files {
                if let Some(it) = d.items.get_mut(x) {
                    it.shared = true;
                }
            }
        }

        // needs you
        for (&c, (card, about)) in &f.cards {
            if card.open {
                d.needs_you.push(c);
                for y in about {
                    if let Some(it) = d.items.get_mut(y) {
                        it.needs_you = true;
                    }
                }
            }
        }

        edges.retain(|(a, b, _)| a != b && d.items.contains_key(a) && d.items.contains_key(b));
        edges.sort_unstable();
        edges.dedup();
        d.edges = edges;
        d
    }
}
