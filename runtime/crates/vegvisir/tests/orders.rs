//! The map core in every order of its sources (skuld; pattern [A]), and its rules on single scenarios (pure, [D]).
//!
//! The harness plays the hub's shell: it records the core's effects and never feeds them back (an effect is a send
//! to the editor, not an event), and checks the invariants after every event.

use std::collections::{BTreeMap, BTreeSet};

use skuld::{Bound, Partial, every_order};
use vegvisir::{
    CardFact, CardKind, Core, EdgeKind, Effect, Event, GraphFact, ItemId, MachineFact, Mode, Model,
    PresenceEntry, PresenceFact, RefFact, SessionFact, State, StepFact, ViewKey, ViewOp, ViewState,
};

#[derive(Clone, Debug)]
struct Ev(Event);

impl skuld::Events for Ev {
    const KINDS: &'static [&'static str] = &[
        "Graph", "Session", "Step", "Changed", "Presence", "Machines", "Card", "Refs", "Tick",
        "View",
    ];
    fn kind(&self) -> &'static str {
        match &self.0 {
            Event::Graph(_) => "Graph",
            Event::Session(_) => "Session",
            Event::Step(_) => "Step",
            Event::Changed { .. } => "Changed",
            Event::Presence(_) => "Presence",
            Event::Machines(_) => "Machines",
            Event::Card(_) => "Card",
            Event::Refs(_) => "Refs",
            Event::Tick { .. } => "Tick",
            Event::View(_) => "View",
        }
    }
}

/// The core, what it sent, and the first broken invariant.
#[derive(Default)]
struct Harness {
    core: Core,
    layers: BTreeMap<ItemId, u8>,
    effects: Vec<Effect>,
    broken: Option<String>,
}

impl skuld::Core for Harness {
    type Event = Ev;
    fn step(&mut self, ev: Ev) -> Vec<Ev> {
        let live = !matches!(ev.0, Event::View(_));
        let what = format!("{:?}", ev.0);
        let effects = self.core.step(ev.0);
        if self.broken.is_none()
            && let Err(e) = self.check(live, &effects)
        {
            self.broken = Some(format!("after {what}: {e}"));
        }
        self.effects.extend(effects);
        Vec::new()
    }
}

impl Harness {
    fn check(&mut self, live: bool, effects: &[Effect]) -> Result<(), String> {
        let m = self.core.model();
        let items = m.items();
        // no dangling edge
        for e in m.edges() {
            if !items.contains_key(&e.from) || !items.contains_key(&e.to) {
                return Err(format!("dangling edge {e:?}"));
            }
        }
        // overlaps are symmetric: both sides flagged, and every flag has its overlap
        let overlaps = m.overlaps();
        let mut flagged = BTreeSet::new();
        for o in &overlaps {
            for side in [&o.a, &o.b] {
                if !items.get(side).is_some_and(|i| i.warn) {
                    return Err(format!("{side} is in an overlap but not flagged"));
                }
                flagged.insert(side.clone());
            }
            for f in &o.files {
                if !items.get(f).is_some_and(|i| i.shared) {
                    return Err(format!("{f} is shared but not marked"));
                }
            }
        }
        for (id, i) in &items {
            if i.warn && !flagged.contains(id) {
                return Err(format!("{id} is flagged with no overlap"));
            }
        }
        // chains are exact
        for id in items.keys() {
            let (up, down) = reference_chain(m, id);
            let c = m.chain(id);
            let got_up: BTreeSet<ItemId> = c.up.into_iter().collect();
            let got_down: BTreeSet<ItemId> = c.down.into_iter().collect();
            if got_up != up || got_down != down {
                return Err(format!(
                    "chain of {id}: {got_up:?}/{got_down:?}, expected {up:?}/{down:?}"
                ));
            }
        }
        // an item's layer never changes
        for (id, i) in &items {
            let l = *self.layers.entry(id.clone()).or_insert(i.kind.layer());
            if l != i.kind.layer() {
                return Err(format!("{id} moved from layer {l} to {}", i.kind.layer()));
            }
        }
        for e in effects {
            match e {
                // a hidden view gets no delta
                Effect::Delta { view, .. } if self.core.shown(view) != Some(true) => {
                    return Err(format!("a delta for the hidden view {view:?}"));
                }
                // live events never move an item: only the user's view changes relayout
                Effect::Relayout { view } if live => {
                    return Err(format!("a live event relaid out {view:?}"));
                }
                _ => {}
            }
        }
        Ok(())
    }
}

/// The chain by its definition, from the edge list alone: up along on-chain edges backwards, down forwards.
fn reference_chain(m: &Model, sel: &ItemId) -> (BTreeSet<ItemId>, BTreeSet<ItemId>) {
    let edges: Vec<_> = m
        .edges()
        .into_iter()
        .filter(|e| e.kind.on_chain())
        .collect();
    let walk = |forward: bool| {
        let mut seen = BTreeSet::new();
        let mut todo = vec![sel.clone()];
        while let Some(x) = todo.pop() {
            for e in &edges {
                let (from, to) = if forward {
                    (&e.from, &e.to)
                } else {
                    (&e.to, &e.from)
                };
                if *from == x && to != sel && seen.insert(to.clone()) {
                    todo.push(to.clone());
                }
            }
        }
        seen
    };
    (walk(false), walk(true))
}

type Snapshot = (
    BTreeMap<ItemId, vegvisir::Item>,
    Vec<vegvisir::Edge>,
    Vec<vegvisir::Overlap>,
    Vec<vegvisir::NeedsYou>,
);

fn snapshot(m: &Model) -> Snapshot {
    (m.items(), m.edges(), m.overlaps(), m.needs_you())
}

fn session(id: &str, task: Option<&str>, branch: Option<&str>, base: Option<&str>) -> SessionFact {
    SessionFact {
        id: id.to_string(),
        name: format!("agent {id}"),
        model: "Opus".to_string(),
        state: State::Running,
        since: 0,
        seq: 0,
        task: task.map(str::to_string),
        manager: None,
        branch: branch.map(str::to_string),
        worktree: branch.map(|b| format!("wt/{b}")),
        base: base.map(str::to_string),
        machine: None,
        spend: None,
        context: None,
        progress: None,
    }
}

fn changed(branch: &str, base: &str, files: &[(&str, u32, u32)]) -> Event {
    Event::Changed {
        worktree: format!("wt/{branch}"),
        base: base.to_string(),
        files: files
            .iter()
            .map(|&(p, a, b)| (p.to_string(), (a, b)))
            .collect(),
    }
}

fn presence(file: &str, entries: &[(&str, Mode)]) -> Event {
    Event::Presence(PresenceFact {
        file: file.to_string(),
        entries: entries
            .iter()
            .map(|&(s, mode)| PresenceEntry {
                session: s.to_string(),
                mode,
                line: None,
            })
            .collect(),
    })
}

fn refs(list: &[(&str, &str, bool)]) -> Event {
    Event::Refs(
        list.iter()
            .map(|&(b, base, merged)| RefFact {
                branch: b.to_string(),
                based_on: Some(base.to_string()),
                merged,
            })
            .collect(),
    )
}

fn g(f: GraphFact) -> Event {
    Event::Graph(f)
}

fn plan(id: &str, rank: u64) -> Event {
    g(GraphFact::Plan {
        id: id.to_string(),
        title: format!("plan {id}"),
        rank,
        progress: None,
    })
}

fn task(id: &str, plan: &str) -> Event {
    g(GraphFact::Task {
        id: id.to_string(),
        plan: plan.to_string(),
        title: format!("task {id}"),
        done: false,
    })
}

fn view(n: &str) -> ViewKey {
    ViewKey {
        conn: 1,
        view: n.to_string(),
    }
}

fn id(s: &str) -> ItemId {
    ItemId(s.to_string())
}

fn run(events: Vec<Event>) -> Core {
    let mut c = Core::new();
    for e in events {
        c.step(e);
    }
    c
}

/// [A] The same final model in every order: graph records (then an import again), three sessions with their steps
/// (one ends, one starts a subagent), the edit history's late changed sets, the presence model, a ref move that
/// merges the ended session's branch, machines and the clock, a card opened and settled, a shown and a hidden view.
#[test]
fn same_final_model_in_every_order() {
    let mut p = Partial::new();
    p.source(
        "graph",
        [
            g(GraphFact::Ask {
                key: "1".into(),
                text: "build the map".into(),
            }),
            g(GraphFact::Spec {
                id: "ws".into(),
                title: "the Work space".into(),
            }),
            plan("p", 1),
            g(GraphFact::Derives {
                plan: "p".into(),
                spec: "ws".into(),
            }),
            task("t1", "p"),
            task("t2", "p"),
            g(GraphFact::Asked {
                ask: "1".into(),
                to: "spec:ws".into(),
            }),
            // the import runs again
            plan("p", 1),
            task("t1", "p"),
        ]
        .map(Ev)
        .to_vec(),
    );
    let mut a = session("A", Some("t1"), Some("drgnx/a"), Some("ca"));
    a.machine = Some("desk".into());
    let mut a_end = a.clone();
    a_end.state = State::Finished;
    let mut a_steps = Vec::new();
    a_steps.push(Event::Session(a));
    for (n, conclusion) in [(1, None), (2, Some("the lanes share a slot"))] {
        a_steps.push(Event::Step(StepFact {
            session: "A".into(),
            step: n,
            class: "edit".into(),
            minute: 3,
            conclusion: conclusion.map(str::to_string),
        }));
    }
    a_steps.push(Event::Session(a_end));
    p.source("session A", a_steps.into_iter().map(Ev).collect());
    p.source(
        "session B",
        [
            Event::Session(session("B", Some("t2"), Some("drgnx/b"), Some("cb"))),
            Event::Step(StepFact {
                session: "B".into(),
                step: 1,
                class: "read".into(),
                minute: 4,
                conclusion: None,
            }),
        ]
        .map(Ev)
        .to_vec(),
    );
    p.source(
        "session C",
        [
            Event::Session(session("C", Some("t2"), Some("nidhogg/c"), Some("cc"))),
            Event::Session(session("C/tool1", None, None, None)),
        ]
        .map(Ev)
        .to_vec(),
    );
    p.source(
        "edit history",
        [
            changed(
                "drgnx/a",
                "ca",
                &[("drgnx/x.rs", 3, 1), ("drgnx/new.rs", 0, 0)],
            ),
            changed("drgnx/b", "cb", &[("drgnx/x.rs", 1, 0)]),
            changed("nidhogg/c", "cc", &[("nidhogg/y.c", 2, 2)]),
        ]
        .map(Ev)
        .to_vec(),
    );
    p.source(
        "presence",
        [
            presence("nidhogg/y.c", &[("C", Mode::Edit), ("C/tool1", Mode::Edit)]),
            presence("drgnx/x.rs", &[("B", Mode::Read)]),
        ]
        .map(Ev)
        .to_vec(),
    );
    p.source(
        "git and the registry",
        [
            refs(&[
                ("drgnx/a", "drgnx/main", false),
                ("drgnx/b", "drgnx/main", false),
            ]),
            Event::Machines(vec![MachineFact {
                name: "desk".into(),
                slots: 16,
                used: 2,
                reported: true,
            }]),
            // the ref move: A's branch merged
            refs(&[
                ("drgnx/a", "drgnx/main", true),
                ("drgnx/b", "drgnx/main", false),
            ]),
            Event::Tick { minute: 5 },
        ]
        .map(Ev)
        .to_vec(),
    );
    let card = |open| CardFact {
        id: "c1".into(),
        kind: CardKind::Push,
        about: vec!["agent:B".into()],
        text: "push b?".into(),
        open,
    };
    p.source(
        "cards",
        [Event::Card(card(true)), Event::Card(card(false))]
            .map(Ev)
            .to_vec(),
    );
    p.source(
        "views",
        [
            Event::View(ViewOp::Open {
                view: view("shown"),
                state: ViewState::default(),
                shown: true,
            }),
            Event::View(ViewOp::Open {
                view: view("hidden"),
                state: ViewState::default(),
                shown: false,
            }),
        ]
        .map(Ev)
        .to_vec(),
    );

    let mut reference: Option<Snapshot> = None;
    let report = every_order(&p, Bound::default(), Harness::default, |h, _| {
        if let Some(b) = &h.broken {
            return Err(b.clone());
        }
        let snap = snapshot(h.core.model());
        match &reference {
            None => {
                reference = Some(snap);
                Ok(())
            }
            Some(r) if *r == snap => Ok(()),
            Some(r) => Err(format!(
                "a different final model:\n{snap:#?}\nexpected\n{r:#?}"
            )),
        }
    });
    assert!(report.orders > 1, "{report:?}");
    // the final model itself: A finished and merged leaves; B and C, C's subagent and their overlap within C stay
    let r = reference.expect("one order ran");
    assert!(!r.0[&id("agent:A")].live);
    assert!(!r.0[&id("branch:drgnx/a")].live);
    assert!(r.0[&id("agent:B")].live && r.0[&id("plan:p")].live && r.0[&id("ask:1")].live);
    let pairs: Vec<(String, String)> = r.2.iter().map(|o| (o.a.0.clone(), o.b.0.clone())).collect();
    assert_eq!(
        pairs,
        vec![("agent:C".to_string(), "agent:C/tool1".to_string())]
    );
    assert!(r.3.is_empty(), "the card settled");
}

mod chain {
    use super::*;

    /// [D] From an agent, up reaches its ask through its plan and spec; with a level missing, the chain names the
    /// gap instead of inventing an item.
    #[test]
    fn up_reaches_the_ask_or_says_gap() {
        let c = run(vec![
            g(GraphFact::Ask {
                key: "1".into(),
                text: "do it".into(),
            }),
            g(GraphFact::Ask {
                key: "2".into(),
                text: "brainstorm".into(),
            }),
            g(GraphFact::Spec {
                id: "s".into(),
                title: "spec".into(),
            }),
            plan("p", 1),
            plan("q", 2),
            g(GraphFact::Derives {
                plan: "p".into(),
                spec: "s".into(),
            }),
            task("t", "p"),
            task("u", "q"),
            g(GraphFact::Asked {
                ask: "1".into(),
                to: "spec:s".into(),
            }),
            g(GraphFact::Asked {
                ask: "2".into(),
                to: "agent:B".into(),
            }),
            Event::Session(session("A", Some("t"), Some("drgnx/a"), None)),
            Event::Session(session("B", None, Some("org/notes"), None)),
            Event::Session(session("C", Some("u"), Some("drgnx/c"), None)),
        ]);
        let m = c.model();
        let a = m.chain(&id("agent:A"));
        assert_eq!(a.up, vec![id("ask:1"), id("spec:s"), id("plan:p")]);
        assert!(a.gaps.is_empty());
        assert_eq!(a.down, vec![id("branch:drgnx/a")]);
        let b = m.chain(&id("agent:B"));
        assert_eq!(b.up, vec![id("ask:2")]);
        assert_eq!(b.gaps, vec![2, 3], "a brainstorm has no spec and no plan");
        let c = m.chain(&id("agent:C"));
        assert_eq!(c.up, vec![id("plan:q")]);
        assert_eq!(c.gaps, vec![1, 2], "an imported plan has no ask");
        // from a branch, up goes through its agent
        let br = m.chain(&id("branch:drgnx/a"));
        assert_eq!(
            br.up,
            vec![id("ask:1"), id("spec:s"), id("plan:p"), id("agent:A")]
        );
    }
}

mod overlap {
    use super::*;

    fn pair(m: &Model) -> Vec<(String, String, Vec<String>)> {
        m.overlaps()
            .into_iter()
            .map(|o| (o.a.0, o.b.0, o.files.into_iter().map(|f| f.0).collect()))
            .collect()
    }

    /// [D] An untracked new file is a change even with no lines (+0 −0), so two branches adding it overlap.
    #[test]
    fn untracked_file_counts() {
        let c = run(vec![
            Event::Session(session("A", None, Some("drgnx/a"), Some("ca"))),
            Event::Session(session("B", None, Some("drgnx/b"), Some("cb"))),
            changed("drgnx/a", "ca", &[("drgnx/new.json", 0, 0)]),
            changed("drgnx/b", "cb", &[("drgnx/new.json", 0, 0)]),
        ]);
        let f = vec!["file:drgnx/new.json".to_string()];
        assert_eq!(
            pair(c.model()),
            vec![
                ("agent:A".into(), "agent:B".into(), f.clone()),
                ("branch:drgnx/a".into(), "branch:drgnx/b".into(), f),
            ]
        );
        let items = c.model().items();
        assert!(items[&id("agent:A")].warn && items[&id("agent:B")].warn);
        assert!(items[&id("file:drgnx/new.json")].shared);
    }

    /// [D] Each branch's changes count against the base recorded for its worktree: b, cut from a, does not overlap a
    /// on a's own change, and a measurement against another base (main) is not used.
    #[test]
    fn measured_against_each_base_not_main() {
        let mut c = run(vec![
            Event::Session(session("A", None, Some("drgnx/a"), Some("c-main"))),
            Event::Session(session("B", None, Some("drgnx/b"), Some("c-a"))),
            changed("drgnx/a", "c-main", &[("drgnx/f.rs", 5, 0)]),
            changed("drgnx/b", "c-a", &[("drgnx/g.rs", 1, 0)]),
        ]);
        assert!(pair(c.model()).is_empty());
        // a set measured against main, not against b's recorded base, is not b's
        c.step(changed(
            "drgnx/b",
            "c-main",
            &[("drgnx/f.rs", 5, 0), ("drgnx/g.rs", 1, 0)],
        ));
        assert!(pair(c.model()).is_empty());
        assert_eq!(
            c.model().item(&id("branch:drgnx/b")).unwrap().fields.edits,
            None
        );
        // b really changing f against its own base overlaps
        c.step(changed(
            "drgnx/b",
            "c-a",
            &[("drgnx/f.rs", 2, 1), ("drgnx/g.rs", 1, 0)],
        ));
        assert_eq!(pair(c.model()).len(), 2);
        assert_eq!(
            c.model().item(&id("branch:drgnx/b")).unwrap().fields.edits,
            Some((2, 3, 1))
        );
    }

    /// [D] A parent and its subagents share one worktree: two siblings editing the same file overlap between their
    /// cards, and the branch has no overlap with itself.
    #[test]
    fn siblings_in_one_worktree() {
        let c = run(vec![
            Event::Session(session("P", None, Some("drgnx/p"), Some("c"))),
            Event::Session(session("P/x", None, None, None)),
            Event::Session(session("P/y", None, None, None)),
            presence("drgnx/l.rs", &[("P/x", Mode::Edit), ("P/y", Mode::Write)]),
            presence("drgnx/m.rs", &[("P/x", Mode::Edit), ("P", Mode::Read)]),
        ]);
        assert_eq!(
            pair(c.model()),
            vec![(
                "agent:P/x".into(),
                "agent:P/y".into(),
                vec!["file:drgnx/l.rs".to_string()]
            )]
        );
        let items = c.model().items();
        assert_eq!(items[&id("agent:P/x")].kind, vegvisir::Kind::Subagent);
        assert_eq!(items[&id("agent:P/x")].parent, Some(id("agent:P")));
        assert!(!items[&id("agent:P")].warn);
        // the in-flight edits are the branch's
        let edits: Vec<_> = c
            .model()
            .edges()
            .into_iter()
            .filter(|e| e.kind == EdgeKind::Edits)
            .map(|e| e.to.0)
            .collect();
        assert_eq!(edits, vec!["file:drgnx/l.rs", "file:drgnx/m.rs"]);
    }
}

mod model {
    use super::*;

    /// [D] A finished agent stays on the map while its branch is unmerged; the merge takes it, its branch, and the
    /// plan and ask that had nothing else live under them, and a view without "show finished" is told they went.
    #[test]
    fn finished_agent_leaves_when_its_branch_merges() {
        let mut a = session("A", Some("t"), Some("drgnx/a"), None);
        a.state = State::Finished;
        let mut c = run(vec![
            g(GraphFact::Ask {
                key: "1".into(),
                text: "fix it".into(),
            }),
            plan("p", 1),
            task("t", "p"),
            g(GraphFact::Asked {
                ask: "1".into(),
                to: "plan:p".into(),
            }),
            Event::Session(a),
            refs(&[("drgnx/a", "drgnx/main", false)]),
            Event::View(ViewOp::Open {
                view: view("v"),
                state: ViewState::default(),
                shown: true,
            }),
        ]);
        let live = |c: &Core, s: &str| c.model().item(&id(s)).unwrap().live;
        assert!(
            live(&c, "agent:A")
                && live(&c, "branch:drgnx/a")
                && live(&c, "plan:p")
                && live(&c, "ask:1")
        );
        let effects = c.step(refs(&[("drgnx/a", "drgnx/main", true)]));
        for s in ["agent:A", "branch:drgnx/a", "plan:p", "ask:1"] {
            assert!(!live(&c, s), "{s} left");
        }
        let [Effect::Delta { delta, .. }] = effects.as_slice() else {
            panic!("{effects:?}")
        };
        assert_eq!(
            delta.removed,
            vec![
                id("agent:A"),
                id("ask:1"),
                id("branch:drgnx/a"),
                // the base goes with the last live branch cut from it
                id("branch:drgnx/main"),
                id("plan:p")
            ]
        );
        assert!(delta.structural);
        // with "show finished" they stay, in the subtle face
        let mut state = ViewState::default();
        state.filters.finished = true;
        c.step(Event::View(ViewOp::Set {
            view: view("v"),
            state,
        }));
        let mut b = session("A", Some("t"), Some("drgnx/a"), None);
        b.state = State::Finished;
        b.spend = Some("$1".into());
        let effects = c.step(Event::Session(b));
        let [Effect::Delta { delta, .. }] = effects.as_slice() else {
            panic!("{effects:?}")
        };
        assert_eq!(delta.changed, vec![id("agent:A")]);
    }
}
