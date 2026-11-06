//! The Work space's fixtures as events (feature `fixture`, for tests only).
//!
//! A fixture is one description (`test/fixtures/work-space/*.json`): asks, specs, plans and tasks, the agents with
//! their branches and changed files, machines, branch ancestry and cards. The Rust tests read it here; the perf
//! workloads build the same description into a real hub.

use std::collections::BTreeMap;

use serde::Deserialize;

use crate::Event;
use crate::model::{
    CardFact, GraphFact, MachineFact, Mode, PresenceEntry, PresenceFact, RefFact, SessionFact,
    StepFact,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Desc {
    asks: Vec<Ask>,
    specs: Vec<Spec>,
    plans: Vec<Plan>,
    tasks: Vec<Task>,
    agents: Vec<Agent>,
    #[serde(default)]
    refs: Vec<RefFact>,
    #[serde(default)]
    machines: Vec<MachineFact>,
    #[serde(default)]
    cards: Vec<CardFact>,
    #[serde(default)]
    minute: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Ask {
    key: String,
    text: String,
    /// What it led to: `spec:ID`, `plan:ID`, `task:ID`, `agent:SID`.
    #[serde(default)]
    to: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Spec {
    id: String,
    title: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Plan {
    id: String,
    title: String,
    rank: u64,
    #[serde(default)]
    spec: Option<String>,
    #[serde(default)]
    progress: Option<(u32, u32)>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Task {
    id: String,
    plan: String,
    title: String,
    #[serde(default)]
    done: bool,
}

#[derive(Deserialize)]
struct Agent {
    #[serde(flatten)]
    session: SessionFact,
    /// Its worktree's changed files against its base, `REPO/PATH` → (plus, minus).
    #[serde(default)]
    files: BTreeMap<String, (u32, u32)>,
    /// Files it is editing now (the presence model).
    #[serde(default)]
    edits: Vec<String>,
    /// Files it read.
    #[serde(default)]
    reads: Vec<String>,
    /// Its latest step's class, and a conclusion recorded there.
    #[serde(default)]
    class: Option<String>,
    #[serde(default)]
    conclusion: Option<String>,
}

/// The 30-agent fixture (`test/fixtures/work-space/thirty.json`): 4 plans, 3 specs, 6 asks, 30 agents (4 of them
/// subagents), 30 branches over 3 repos, 120 edited files, 3 machines (one reported by `machines/report`).
pub fn thirty() -> Vec<Event> {
    from_json(include_str!(
        "../../../../test/fixtures/work-space/thirty.json"
    ))
}

/// The prototype's own data (`test/fixtures/work-space/prototype.json`).
pub fn prototype() -> Vec<Event> {
    from_json(include_str!(
        "../../../../test/fixtures/work-space/prototype.json"
    ))
}

/// A fixture description as the events a hub would feed, sources in a fixed order: the graph, machines, sessions,
/// steps, changed files, presence, refs, cards, the clock.
pub fn from_json(text: &str) -> Vec<Event> {
    let d: Desc = serde_json::from_str(text).unwrap_or_else(|e| panic!("vegvisir fixture: {e}"));
    let mut out = Vec::new();
    for a in &d.asks {
        out.push(Event::Graph(GraphFact::Ask {
            key: a.key.clone(),
            text: a.text.clone(),
        }));
    }
    for s in &d.specs {
        out.push(Event::Graph(GraphFact::Spec {
            id: s.id.clone(),
            title: s.title.clone(),
        }));
    }
    for p in &d.plans {
        out.push(Event::Graph(GraphFact::Plan {
            id: p.id.clone(),
            title: p.title.clone(),
            rank: p.rank,
            progress: p.progress,
        }));
        if let Some(spec) = &p.spec {
            out.push(Event::Graph(GraphFact::Derives {
                plan: p.id.clone(),
                spec: spec.clone(),
            }));
        }
    }
    for t in &d.tasks {
        out.push(Event::Graph(GraphFact::Task {
            id: t.id.clone(),
            plan: t.plan.clone(),
            title: t.title.clone(),
            done: t.done,
        }));
    }
    for a in &d.asks {
        for to in &a.to {
            out.push(Event::Graph(GraphFact::Asked {
                ask: a.key.clone(),
                to: to.clone(),
            }));
        }
    }
    if !d.machines.is_empty() {
        out.push(Event::Machines(d.machines.clone()));
    }
    for a in &d.agents {
        out.push(Event::Session(a.session.clone()));
    }
    for a in &d.agents {
        if let Some(class) = &a.class {
            out.push(Event::Step(StepFact {
                session: a.session.id.clone(),
                step: 1,
                class: class.clone(),
                minute: d.minute,
                conclusion: a.conclusion.clone(),
            }));
        }
    }
    for a in &d.agents {
        if let (Some(wt), Some(base)) = (&a.session.worktree, &a.session.base)
            && !a.files.is_empty()
        {
            out.push(Event::Changed {
                worktree: wt.clone(),
                base: base.clone(),
                files: a.files.clone(),
            });
        }
    }
    let mut presence: BTreeMap<&str, Vec<PresenceEntry>> = BTreeMap::new();
    for a in &d.agents {
        for (list, mode) in [(&a.edits, Mode::Edit), (&a.reads, Mode::Read)] {
            for f in list {
                presence.entry(f).or_default().push(PresenceEntry {
                    session: a.session.id.clone(),
                    mode,
                    line: None,
                });
            }
        }
    }
    for (file, entries) in presence {
        out.push(Event::Presence(PresenceFact {
            file: file.to_string(),
            entries,
        }));
    }
    if !d.refs.is_empty() {
        out.push(Event::Refs(d.refs.clone()));
    }
    for c in &d.cards {
        out.push(Event::Card(c.clone()));
    }
    if d.minute > 0 {
        out.push(Event::Tick { minute: d.minute });
    }
    out
}
