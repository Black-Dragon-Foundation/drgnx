//! The map's coalescing per view, in every order of its inputs (pattern A): live arrivals fade in and never relayout,
//! field deltas go out at most once per 100 ms, a quiet second reflows once unless the selection's chain would move,
//! and the user's own change relayouts at once.

use super::*;
use skuld::{Bound, Partial, every_order};
use std::collections::{BTreeMap, BTreeSet};
use vegvisir::ItemId;

/// The coalescer's input, for one scenario `S` (each declares the kinds its orders produce).
#[derive(Clone, Debug)]
struct Ev<const S: u8>(CoIn);

fn kind_of(c: &CoIn) -> &'static str {
    match c {
        CoIn::Now(_) => "Now",
        CoIn::Delta(_) => "Delta",
        CoIn::User => "User",
        CoIn::Key => "Key",
        CoIn::Held => "Held",
    }
}

/// Starts and the clock.
impl skuld::Events for Ev<1> {
    const KINDS: &'static [&'static str] = &["Now", "Delta"];
    fn kind(&self) -> &'static str {
        kind_of(&self.0)
    }
}

/// Starts, the clock and the user's filter.
impl skuld::Events for Ev<2> {
    const KINDS: &'static [&'static str] = &["Now", "Delta", "User"];
    fn kind(&self) -> &'static str {
        kind_of(&self.0)
    }
}

/// Starts and the clock, with a selection whose chain the reflow would move.
impl skuld::Events for Ev<3> {
    const KINDS: &'static [&'static str] = &["Now", "Delta", "Held"];
    fn kind(&self) -> &'static str {
        kind_of(&self.0)
    }
}

fn agent(n: u32) -> ItemId {
    ItemId(format!("agent:s{n}"))
}

/// Agent N starts: a new item, a structural change.
fn start(n: u32) -> CoIn {
    CoIn::Delta(Delta {
        changed: vec![agent(n)],
        structural: true,
        ..Delta::default()
    })
}

/// A field of agent N changes (its state, its spend).
fn field(n: u32) -> CoIn {
    CoIn::Delta(Delta {
        changed: vec![agent(n)],
        ..Delta::default()
    })
}

/// The shell, as the harness plays it: what the view shows, and what was sent when.
#[derive(Default)]
struct Harness<const S: u8> {
    co: Coalescer,
    now: u64,
    /// Every item a delta named: what a full frame shows.
    all: BTreeSet<ItemId>,
    shown: BTreeSet<ItemId>,
    fades: BTreeMap<ItemId, u32>,
    sends: Vec<u64>,
    quiet: Vec<u64>,
    user: Vec<u64>,
    /// Quiet reflows the shell held (the chain would move).
    held: u32,
    /// The first delta not yet sent, and the last change or key.
    pending_since: Option<u64>,
    last_change: Option<u64>,
    structural: bool,
    broken: Option<String>,
}

impl<const S: u8> Harness<S> {
    fn fail(&mut self, why: String) {
        if self.broken.is_none() {
            self.broken = Some(why);
        }
    }

    fn reflowed(&mut self) {
        self.shown = self.all.clone();
        self.pending_since = None;
        self.structural = false;
    }
}

impl<const S: u8> skuld::Core for Harness<S>
where
    Ev<S>: skuld::Events,
{
    type Event = Ev<S>;
    fn step(&mut self, ev: Ev<S>) -> Vec<Ev<S>> {
        let what = format!("{:?} at {}", ev.0, self.now);
        match &ev.0 {
            CoIn::Now(t) => self.now = *t,
            CoIn::Delta(d) => {
                self.all.extend(d.changed.iter().cloned());
                self.pending_since.get_or_insert(self.now);
                self.last_change = Some(self.now);
                self.structural |= d.structural;
            }
            _ => {}
        }
        let input = ev.0.clone();
        let outs = self.co.step(ev.0);
        let mut again = Vec::new();
        let mut reflowed_by_user = false;
        for o in outs {
            match o {
                CoOut::Wake(at) => {
                    if at < self.now {
                        self.fail(format!("{what}: a wake in the past, at {at}"));
                    }
                }
                CoOut::Send { delta } => {
                    if let Some(&last) = self.sends.last()
                        && self.now < last + 100
                    {
                        self.fail(format!(
                            "{what}: a delta {} ms after the last",
                            self.now - last
                        ));
                    }
                    match self.pending_since {
                        Some(p) if self.now >= p + 100 => {}
                        p => self.fail(format!("{what}: sent early, pending since {p:?}")),
                    }
                    for id in &delta.changed {
                        if self.shown.insert(id.clone()) {
                            *self.fades.entry(id.clone()).or_default() += 1;
                        }
                    }
                    self.sends.push(self.now);
                    self.pending_since = None;
                }
                CoOut::Reflow { user: true } => {
                    if input != CoIn::User {
                        self.fail(format!("{what}: a user reflow without the user"));
                    }
                    reflowed_by_user = true;
                    self.user.push(self.now);
                    self.reflowed();
                }
                CoOut::Reflow { user: false } => {
                    if !matches!(input, CoIn::Now(_)) {
                        self.fail(format!("{what}: a live event relayouts"));
                    }
                    if !self.structural {
                        self.fail(format!("{what}: a reflow with nothing to reflow"));
                    }
                    if self.last_change.is_some_and(|c| self.now < c + 1000) {
                        self.fail(format!("{what}: a reflow before a quiet second"));
                    }
                    if S == 3 {
                        self.held += 1;
                        again.push(Ev(CoIn::Held));
                    } else {
                        self.quiet.push(self.now);
                        self.reflowed();
                    }
                }
            }
        }
        if input == CoIn::User && !reflowed_by_user {
            self.fail(format!(
                "{what}: the user's change did not relayout at once"
            ));
        }
        again
    }
}

/// Five agents start while the clock runs to 2.5 s, and agent 1's fields change twice after it started.
fn partial<const S: u8>(user: bool) -> Partial<Ev<S>> {
    let mut p = Partial::new();
    let starts = p.source("starts", (1..=5).map(|n| Ev(start(n))).collect());
    let clock = p.source(
        "clock",
        [50, 150, 300, 1300, 2500]
            .into_iter()
            .map(|t| Ev(CoIn::Now(t)))
            .collect(),
    );
    let fields = p.source("fields", vec![Ev(field(1)), Ev(field(1))]);
    // agent 1's fields change once it is there; everything happens before the clock's last reading
    p.before((starts, 0), (fields, 0));
    p.before((starts, 4), (clock, 4));
    p.before((fields, 1), (clock, 4));
    if user {
        p.source("user", vec![Ev(CoIn::User)]);
    }
    p
}

fn check_common<const S: u8>(h: &Harness<S>) -> Result<(), String> {
    if let Some(b) = &h.broken {
        return Err(b.clone());
    }
    if h.shown != h.all {
        return Err(format!("not delivered: {:?}", h.all.difference(&h.shown)));
    }
    if let Some((id, n)) = h.fades.iter().find(|(_, n)| **n > 1) {
        return Err(format!("{id} faded in {n} times"));
    }
    Ok(())
}

#[test]
fn coalescing_in_every_order() {
    // five starts: no relayout of their own, five fades; then a quiet second reflows once
    let r = every_order(
        &partial::<1>(false),
        Bound::default(),
        Harness::<1>::default,
        |h, _| {
            check_common(h)?;
            if h.fades.len() != 5 {
                return Err(format!("{} fades, not 5: {:?}", h.fades.len(), h.fades));
            }
            if h.quiet.is_empty() || h.structural {
                return Err(format!("no quiet reflow at the end: {:?}", h.quiet));
            }
            Ok(())
        },
    );
    assert_eq!(r.mode, skuld::Mode::Exhaustive);

    // the user's filter relayouts at once, whatever is pending
    every_order(
        &partial::<2>(true),
        Bound::default(),
        Harness::<2>::default,
        |h, _| {
            check_common(h)?;
            if h.user.len() != 1 {
                return Err(format!("{} user reflows", h.user.len()));
            }
            Ok(())
        },
    );

    // the selection's chain would move: the quiet reflow is asked once and waits for the user; arrivals still fade
    every_order(
        &partial::<3>(false),
        Bound::default(),
        Harness::<3>::default,
        |h, _| {
            if let Some(b) = &h.broken {
                return Err(b.clone());
            }
            if h.held != 1 || !h.quiet.is_empty() {
                return Err(format!("held {}, reflowed {:?}", h.held, h.quiet));
            }
            if h.fades.len() != 5 {
                return Err(format!("{} fades, not 5", h.fades.len()));
            }
            Ok(())
        },
    );
}

/// [D] A session whose job runs on a runner is drawn running on that runner's machine: the "runs on" edge points at
/// the runner, and the agent's card carries the job; its Detail says where it runs and why there.
#[test]
fn runner_job_runs_on_edge_points_at_the_runner() {
    let row: runstav::methods::exec::ExecRow = serde_json::from_value(json!({
        "id": "x1", "session": "s1", "kind": "other", "cwd": "/w", "name": "suite", "status": "running",
        "started": 100.0, "timebox_s": 360, "machine": "desktop",
        "placed_why": "desktop: about 6 min; local: every job slot of the machine is in use"
    }))
    .expect("a job row");
    let job = job_fact(&row, vec!["token".into()]);
    assert_eq!(job.runner.as_deref(), Some("desktop"));
    assert_eq!(
        job.why.as_deref(),
        Some("desktop: about 6 min; local: every job slot of the machine is in use")
    );
    assert_eq!(
        (job.name.as_str(), job.limit_min, job.keys.as_slice()),
        ("suite", Some(6), ["token".to_string()].as_slice())
    );
    let snap: Snapshot =
        serde_json::from_value(json!({"id": "s1", "name": "A"})).expect("a snapshot");
    let sess = Sess {
        snap,
        kids: Vec::new(),
        place: None,
        seq: 1,
        state: State::Running,
        since: 0,
        job: Some(job),
    };
    let mut core = Core::new();
    let runner = vegvisir::RunnerFact {
        trust: "mine".into(),
        state: "ready".into(),
        jobs: 1,
        icon: "server".into(),
        cost: None,
        mac: false,
    };
    let desk = Machine {
        machine: "desktop".into(),
        slots: Vec::new(),
        local: false,
    };
    core.step(Event::Machines(vec![machine_fact(
        &desk,
        Some((&runner, 16)),
    )]));
    for ev in sess.facts() {
        core.step(ev);
    }
    let edge = core
        .model()
        .edges()
        .into_iter()
        .find(|e| e.kind == vegvisir::EdgeKind::RunsOn)
        .expect("a runs-on edge");
    assert_eq!(
        (edge.from.0.as_str(), edge.to.0.as_str()),
        ("agent:s1", "machine:desktop")
    );
    let items = core.model().items();
    let m = &items[&ItemId("machine:desktop".into())];
    assert_eq!(m.fields.slots, Some((1, 16)));
    assert_eq!(
        m.fields.runner.as_ref().map(|r| r.icon.as_str()),
        Some("server")
    );
    let a = &items[&ItemId("agent:s1".into())];
    assert_eq!(
        a.fields.job.as_ref().map(|j| j.name.as_str()),
        Some("suite")
    );
    let lines = detail::lines(core.model(), Some(&a.id), 0);
    assert!(
        lines.iter().any(|l| l.0 == "head"
            && l.1
                == "Runs on desktop · why: desktop: about 6 min; local: every job slot of the machine is in use"),
        "{lines:?}"
    );
}

/// A spec whose comments no agent is writing it for says so in its Detail; once they are sent (none wait), it does not.
#[test]
fn a_spec_with_waiting_comments_says_no_agent_writes_it() {
    let mut core = Core::new();
    core.step(Event::Graph(vegvisir::GraphFact::Spec {
        id: "s".into(),
        title: "Comments".into(),
        updated: 0,
    }));
    let waiting = |core: &mut Core, n: u32| {
        core.step(Event::Graph(vegvisir::GraphFact::Comments {
            item: "spec:s".into(),
            waiting: n,
        }));
        detail::lines(core.model(), Some(&ItemId("spec:s".into())), 0)
            .into_iter()
            .filter(|l| l.0 == "head")
            .map(|l| l.1)
            .collect::<Vec<_>>()
    };
    let lines = waiting(&mut core, 2);
    assert!(
        lines
            .iter()
            .any(|l| l == "2 comments waiting: no agent is writing it"),
        "{lines:?}"
    );
    let lines = waiting(&mut core, 0);
    assert!(!lines.iter().any(|l| l.contains("waiting")), "{lines:?}");
}

// ---- rows views: the map's rows as patches ------------------------------------------------------------------------

use drgnx_rows::faces::FaceId;
use drgnx_rows::fit::Measure;
use drgnx_rows::{ImageId, Op, Patch, Row};
use runstav::methods::view::ViewEnv;

/// 8 px a column.
struct Cols;

impl Measure for Cols {
    fn advance(&self, _role: &str, ch: char) -> Option<f32> {
        Some(8.0 * drgnx_rows::fit_tty::char_width(ch, &[]) as f32)
    }
    fn fallback(&self, _role: &str) -> f32 {
        8.0
    }
}

/// The state of a Graph-mode view: these tests read the graph's links and rows.
fn graph_state() -> ViewState {
    ViewState {
        mode: vegvisir::MapMode::Graph,
        ..ViewState::default()
    }
}

/// Session I starts (no place: the "No plan" block).
fn add_session(core: &mut Core, i: u64) {
    let snap: Snapshot =
        serde_json::from_value(json!({"id": format!("s{i}"), "name": format!("agent {i}")}))
            .expect("a snapshot");
    let sess = Sess {
        snap,
        kids: Vec::new(),
        place: None,
        seq: i,
        state: State::Running,
        since: 0,
        job: None,
    };
    for ev in sess.facts() {
        core.step(ev);
    }
}

fn core_with(n: u64) -> Core {
    let mut core = Core::new();
    for i in 1..=n {
        add_session(&mut core, i);
    }
    core
}

/// A rows view of M laid out at WIDTH units, holding what that layout shows.
fn rows_view(m: &vegvisir::Model, width: u32) -> View {
    let state = ViewState {
        width_units: width,
        ..graph_state()
    };
    let l = layout::layout(m, &state, None);
    let sent = frame_items(m, &state, &l)
        .into_iter()
        .map(|it| it.id)
        .collect();
    View {
        space: "w".into(),
        state,
        shown: true,
        selected: None,
        version: 1,
        layout: Some(l),
        sent,
        co: Coalescer::default(),
        outline: render::Outline::Auto,
        marks: NewMarks::default(),
        new_wake: None,
    }
}

fn env() -> ViewEnv {
    serde_json::from_value(
        json!({"view": "m", "class": "gui-1", "epoch": 1, "display": "gui", "scale": 1.0,
                                  "cell": [8, 16], "width_px": 1000}),
    )
    .expect("an env")
}

/// An editor's side of one (view, class), by the rules: nothing before a reset, an older base dropped, a newer one
/// or an image it lacks asks for a resync.
#[derive(Default)]
struct Editor {
    hub: Option<u64>,
    version: u64,
    rows: Vec<Row>,
    images: BTreeSet<ImageId>,
    resync: bool,
}

impl Editor {
    fn apply(&mut self, p: &Patch) {
        let reset = matches!(p.ops.as_slice(), [Op::Reset(_)]);
        if reset {
            if self.hub == Some(p.hub) && p.version <= self.version {
                return;
            }
            self.hub = Some(p.hub);
            self.images.clear();
        } else if self.hub != Some(p.hub) || p.base < self.version {
            return;
        } else if p.base > self.version {
            self.resync = true;
            return;
        }
        self.images.extend(p.images.iter().map(|i| i.0));
        for op in &p.ops {
            match op {
                Op::Reset(rows) => self.rows = rows.clone(),
                Op::Insert { after, rows } => {
                    let at = after
                        .as_ref()
                        .and_then(|k| self.rows.iter().position(|r| &r.key == k))
                        .map_or(0, |i| i + 1);
                    for (n, r) in rows.iter().enumerate() {
                        self.rows.insert(at + n, r.clone());
                    }
                }
                Op::Replace(rows) => {
                    for r in rows {
                        if let Some(old) = self.rows.iter_mut().find(|o| o.key == r.key) {
                            *old = r.clone();
                        }
                    }
                }
                Op::Remove(keys) => self.rows.retain(|r| !keys.contains(&r.key)),
            }
        }
        self.version = p.version;
        let lacks = self
            .rows
            .iter()
            .flat_map(|r| r.images.iter())
            .any(|i| !self.images.contains(&i.1));
        self.resync |= lacks;
    }
}

/// [A] Three versions of a rows view (one agent, two, three) go out as a reset and two patches; in every order of
/// their arrival, the editor ends on the hub's rows, through one resync when it missed one.
#[test]
fn every_order_deltas_then_resync_converge() {
    let sets: Vec<_> = (1..=3)
        .map(|n| {
            let core = core_with(n);
            let v = rows_view(core.model(), 226);
            view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[])
        })
        .collect();
    assert!(
        sets.iter().all(|(r, _)| !r.is_empty()),
        "every version has rows"
    );
    assert!(
        sets[2].0.iter().any(|r| r.text.contains("agent 3")),
        "{:?}",
        sets[2].0
    );
    let key = (1, "m".to_owned(), "gui-1".to_owned());
    let orders = [
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0],
    ];
    for order in orders {
        let mut store = crate::view::Store::new(7);
        store.env(1, env());
        let patches: Vec<Patch> = sets
            .iter()
            .map(|(r, i)| store.publish(&key, r.clone(), i).expect("a patch"))
            .collect();
        let mut ed = Editor::default();
        for k in order {
            ed.apply(&patches[k]);
        }
        if ed.resync || ed.version != patches[2].version {
            ed.resync = false;
            ed.apply(&store.resync(&key, &[]).expect("a reset"));
        }
        assert_eq!(ed.rows, sets[2].0, "order {order:?}");
        assert!(!ed.resync, "order {order:?}: every image held");
    }
}

/// A map of N sessions with one rows view `m` of connection 1 on it, laid out at WIDTH.
fn rows_map(n: u64, width: u32) -> (Arc<Map>, Inner, ViewKey) {
    let mut core = core_with(n);
    let v = rows_view(core.model(), width);
    let key = ViewKey {
        conn: 1,
        view: "m".into(),
    };
    core.step(Event::View(ViewOp::Open {
        view: key.clone(),
        state: v.state.clone(),
        shown: true,
    }));
    let mut g = Inner::default();
    g.spaces.insert(
        "w".into(),
        Space {
            roots: Vec::new(),
            core,
            files: BTreeMap::new(),
        },
    );
    g.views.insert(key.clone(), v);
    (Arc::new(Map::default()), g, key)
}

fn log(map: &Map) -> Vec<&'static str> {
    map.log
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
}

/// [A] A view gets its model and rows for a relayout and a delta; hidden, it gets nothing (its editor hid it).
#[test]
fn a_hidden_view_gets_nothing() {
    let (map, mut g, key) = rows_map(2, 226);
    map.send_full(&mut g, &key);
    map.send_delta(
        &mut g,
        &key,
        Delta {
            changed: vec![ItemId("agent:s1".into())],
            ..Delta::default()
        },
    );
    assert_eq!(log(&map), ["model", "rows", "model", "rows"]);
    g.views.get_mut(&key).expect("the view").shown = false;
    map.send_full(&mut g, &key);
    map.send_delta(
        &mut g,
        &key,
        Delta {
            changed: vec![ItemId("agent:s1".into())],
            ..Delta::default()
        },
    );
    assert_eq!(log(&map), ["model", "rows", "model", "rows"]);
}

/// [D] A rows view's model goes before the rows built from it, for a full frame and for a delta.
#[test]
fn model_goes_before_its_rows() {
    let (map, mut g, key) = rows_map(3, 226);
    map.send_full(&mut g, &key);
    assert_eq!(log(&map), ["model", "rows"]);
    map.send_delta(
        &mut g,
        &key,
        Delta {
            changed: vec![ItemId("agent:s2".into())],
            ..Delta::default()
        },
    );
    assert_eq!(log(&map), ["model", "rows", "model", "rows"]);
}

/// [D] The map's model: a node per item the view shows, with its links, its card's rect and its flags; the chain
/// edges among them; the team, needs-you and outline lists.
#[test]
fn map_model_carries_links_rects_and_lists() {
    let (_map, g, key) = rows_map(3, 226);
    let v = &g.views[&key];
    let m = g.spaces["w"].core.model();
    let l = v.layout.as_ref().expect("laid out");
    let d = model::doc(m, l, &v.sent, &graph_state());
    assert_eq!(d.nodes.len(), v.sent.len());
    let a1 = &d.nodes["agent:s1"];
    let fields = a1["fields"].as_array().expect("fields");
    let rect = &l.at[&ItemId("agent:s1".into())];
    for (name, want) in [("x", rect.x), ("y", rect.y), ("w", rect.w), ("h", rect.h)] {
        assert!(
            fields.contains(&json!([name, want])),
            "{name} in {fields:?}"
        );
    }
    assert_eq!(a1["kind"], "agent");
    assert_eq!(a1["nav"]["right"], "agent:s2");
    assert_eq!(d.lists["team"], vec!["agent:s1", "agent:s2", "agent:s3"]);
    assert_eq!(d.descriptor["scheme"], "links");
}

/// [A] A rows view still holds a quiet reflow that would move its selection's chain; the user's own change draws.
#[test]
fn selected_still_holds_a_quiet_reflow() {
    let (map, mut g, key) = rows_map(8, 500);
    {
        let v = g.views.get_mut(&key).expect("the view");
        // laid out wide, now narrow: a reflow moves the cards
        v.state.width_units = 120;
        v.selected = Some(ItemId("agent:s8".into()));
    }
    assert!(map.chain_moves(&g, &key), "the reflow would move the chain");
    map.outs(&mut g, &key, vec![CoOut::Reflow { user: false }], 0);
    assert!(log(&map).is_empty(), "held: {:?}", log(&map));
    map.outs(&mut g, &key, vec![CoOut::Reflow { user: true }], 0);
    assert_eq!(log(&map), ["model", "rows"]);
}

/// [D] The Timeline's lit lanes: the sessions of the agents on the selection's chain in a shown rows view of the
/// connection; none with nothing selected, for another connection, or while the view is hidden.
#[test]
fn near_is_the_selections_agents() {
    let (_map, mut g, key) = rows_map(3, 226);
    assert!(Map::near_in(&g, 1).is_empty(), "nothing selected");
    g.views.get_mut(&key).expect("the view").selected = Some(ItemId("agent:s2".into()));
    assert_eq!(Map::near_in(&g, 1), vec!["s2"]);
    assert!(Map::near_in(&g, 2).is_empty(), "another connection");
    g.views.get_mut(&key).expect("the view").shown = false;
    assert!(Map::near_in(&g, 1).is_empty(), "hidden");
}

/// [D] The Detail panel's rows say the selection's edges in words, both ways, and its why-chain from the ask down;
/// nothing selected is one line.
#[test]
fn detail_rows_say_the_edges() {
    let mut core = vegvisir::Core::new();
    for e in vegvisir::fixture::thirty() {
        core.step(e);
    }
    let m = core.model();
    assert_eq!(
        detail::lines(m, None, 0),
        vec![("head", "Nothing is selected.".to_string(), None)]
    );
    // an agent with a branch below it and an ask, spec or plan above it
    let edges = m.edges();
    let came = |e: &vegvisir::Edge| serde_json::to_value(e.kind).ok() == Some(json!("came-from"));
    let agent = m
        .items()
        .into_values()
        .find(|it| {
            serde_json::to_value(it.kind).ok() == Some(json!("agent"))
                && edges.iter().any(|e| came(e) && e.from == it.id)
                && edges.iter().any(|e| came(e) && e.to == it.id)
        })
        .expect("an agent with a why and a branch");
    let lines = detail::lines(m, Some(&agent.id), 0);
    let text: Vec<&str> = lines.iter().map(|(_, t, _)| t.as_str()).collect();
    assert!(text[0].contains(&agent.label), "{text:?}");
    for e in edges.iter().filter(|e| came(e) && e.from == agent.id) {
        let to = m.item(&e.to).expect("its target").label;
        assert!(
            text.iter()
                .any(|t| t.ends_with(&format!("\t{to} — came from this"))
                // an agent's branch is the Touches' first line, its name alone
                || *t == format!("branch\t{to}")
                || t.starts_with(&format!("branch\t{to} · worktree "))),
            "{to} in {text:?}"
        );
    }
    let parent = edges
        .iter()
        .filter(|e| came(e) && e.to == agent.id)
        .map(|e| e.from.clone())
        .min()
        .expect("a parent");
    let pl = m.item(&parent).expect("the parent").label;
    assert!(
        text.iter().any(|t| t.contains('\t') && t.contains(&pl)),
        "{pl} in {text:?}"
    );
    let rows = detail::rows(&lines, &kit_env(1.0), 340, &Cols);
    // the head's subtitle wraps into rows of its own
    assert!(rows.len() >= lines.len());
    assert_eq!(rows[0].key, "head/0");
    assert_eq!(detail::map_of(&detail::view_of("w-1")), Some("w-1"));
}

/// [D] The golden the editor's replica is checked against (`test/unit/view-model-chain-test.el`, in the Nidhogg
/// image; no cargo path between the repos): the map's model of the 30-agent fixture at 1600 px, as the hub sends it,
/// and `vegvisir::Model::chain` of every item it shows. `UPDATE_VEGVISIR_GOLDEN=1` writes it; otherwise a model or
/// chain that moved fails until it is written again.
#[test]
fn chain_golden_matches_vegvisir() {
    let mut core = vegvisir::Core::new();
    for e in vegvisir::fixture::thirty() {
        core.step(e);
    }
    let m = core.model();
    let state = vegvisir::ViewState {
        width_units: 376,
        ..graph_state()
    };
    let l = vegvisir::layout::layout(m, &state, None);
    let sent: BTreeSet<ItemId> = l.at.keys().cloned().collect();
    let d = model::doc(m, &l, &sent, &graph_state());
    let mut chains = serde_json::Map::new();
    for id in &sent {
        let c = m.chain(id);
        let mut on: Vec<String> =
            c.up.iter()
                .chain(c.down.iter())
                .map(|i| i.0.clone())
                .collect();
        on.sort();
        chains.insert(id.0.clone(), serde_json::json!(on));
    }
    let golden = serde_json::json!({
        "model": serde_json::json!({"ops": [d.reset()]}).to_string(),
        "chains": chains,
    });
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../test/fixtures/work-space/model-thirty.json");
    let text = serde_json::to_string_pretty(&golden).expect("json") + "\n";
    if std::env::var_os("UPDATE_VEGVISIR_GOLDEN").is_some() {
        std::fs::write(&path, &text).expect("write the golden");
    }
    let have =
        std::fs::read_to_string(&path).expect("the golden (UPDATE_VEGVISIR_GOLDEN=1 writes it)");
    assert!(
        have == text,
        "the map model or a chain moved: UPDATE_VEGVISIR_GOLDEN=1 writes the golden again"
    );
}

/// [D] The map's model carries what the editor reads on the rows path besides the cards: an agent's plan steps, edits,
/// reads, last conclusion, spend and minutes (the review panel's summary), the agents it overlaps (the huddle key),
/// and the plans as a list (the Board's scope: the plans on the selection's chain).
#[test]
fn map_model_carries_review_fields_overlaps_and_plans() {
    let f = vegvisir::model::Fields {
        progress: Some((2, 5)),
        edits: Some((3, 40, 2)),
        reads: Some(7),
        conclusion: Some("tests pass".into()),
        spend: Some("$0.40".into()),
        minutes: Some(12),
        ..vegvisir::model::Fields::default()
    };
    let got = model::card_fields(&f);
    for want in [
        json!(["done", 2]),
        json!(["steps", 5]),
        json!(["edit_files", 3]),
        json!(["edit_plus", 40]),
        json!(["edit_minus", 2]),
        json!(["reads", 7]),
        json!(["conclusion", "tests pass"]),
        json!(["spend", "$0.40"]),
        json!(["minutes", 12]),
    ] {
        assert!(got.contains(&want), "{want} in {got:?}");
    }
    let mut core = core_with(2);
    core.step(Event::Card(CardFact {
        id: "c1".into(),
        kind: CardKind::Clash,
        about: vec!["agent:s1".into(), "agent:s2".into()],
        text: "both edit a.rs".into(),
        open: true,
    }));
    let v = rows_view(core.model(), 226);
    let d = model::doc(
        core.model(),
        v.layout.as_ref().expect("laid out"),
        &v.sent,
        &graph_state(),
    );
    let fields = d.nodes["agent:s1"]["fields"].as_array().expect("fields");
    assert!(
        fields.contains(&json!(["overlaps", "agent:s2"])),
        "{fields:?}"
    );
    // the plans: those of the 30-agent fixture the view shows
    let mut core = vegvisir::Core::new();
    for e in vegvisir::fixture::thirty() {
        core.step(e);
    }
    let v = rows_view(core.model(), 376);
    let d = model::doc(
        core.model(),
        v.layout.as_ref().expect("laid out"),
        &v.sent,
        &graph_state(),
    );
    let shown: Vec<String> = v
        .sent
        .iter()
        .filter(|id| id.0.starts_with("plan:"))
        .map(|id| id.0.clone())
        .collect();
    assert!(!shown.is_empty(), "the fixture shows plans");
    let mut plans = d.lists["plans"].clone();
    plans.sort();
    assert_eq!(plans, shown);
    assert!(
        d.descriptor["lists"]
            .as_array()
            .is_some_and(|l| l.contains(&json!("plans")))
    );
}

/// The strip's chips and the needs-you list `g N` walks are one order, the editor's strip's: the cards (by id), the
/// agents that need you with no card (a huddle covers nobody), then the open huddles. An entry about nothing the view
/// shows keeps its place, its card's id standing for it (not a node: `g N` there says nothing needs you).
#[test]
fn the_strip_and_the_needs_you_list_line_up() {
    let mut core = core_with(2);
    for i in 3..=4 {
        let snap: Snapshot =
            serde_json::from_value(json!({"id": format!("s{i}"), "name": format!("agent {i}")}))
                .expect("a snapshot");
        let sess = Sess {
            snap,
            kids: Vec::new(),
            place: None,
            seq: i,
            state: State::NeedsYou,
            since: 0,
            job: None,
        };
        for ev in sess.facts() {
            core.step(ev);
        }
    }
    let who = ["s1".to_owned(), "s4".to_owned()];
    core.step(Event::Card(huddle_card(
        "h1",
        Some("both edit a.rs"),
        &who,
        true,
    )));
    for (id, about, text) in [("c1", "agent:s2", "which?"), ("c0", "agent:gone", "gone")] {
        core.step(Event::Card(CardFact {
            id: id.into(),
            kind: CardKind::Question,
            about: vec![about.into()],
            text: text.into(),
            open: true,
        }));
    }
    let v = rows_view(core.model(), 226);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    let at = |chip: &str| {
        rows[0]
            .text
            .find(chip)
            .unwrap_or_else(|| panic!("{chip} in {}", rows[0].text))
    };
    let chips = [
        at("gone"),
        at("which?"),
        // the chips share the row, so a long one is cut: its jump key is what is found
        at("g3"),
        at("g4"),
        at("g5"),
    ];
    assert!(chips.is_sorted(), "{}", rows[0].text);
    let d = model::doc(
        core.model(),
        v.layout.as_ref().expect("laid out"),
        &v.sent,
        &graph_state(),
    );
    assert_eq!(
        d.lists["needs-you"],
        vec!["c0", "agent:s2", "agent:s3", "agent:s4", "agent:s1"]
    );
}

/// [D] UX audit W3: a machine the map draws (its layer) has no second chip on the strip; one it does not draw keeps
/// its load at the strip's right.
#[test]
fn a_machine_on_the_map_is_not_repeated_on_the_strip() {
    let mut core = core_with(1);
    let local = Machine {
        machine: "local".into(),
        slots: Vec::new(),
        local: true,
    };
    core.step(Event::Machines(vec![machine_fact(&local, None)]));
    let v = rows_view(core.model(), 226);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    let drawn = v.sent.contains(&ItemId("machine:local".into()));
    let shown = rows
        .iter()
        .map(|r| r.text.matches("local").count())
        .sum::<usize>();
    assert!(drawn, "the map draws the machine");
    assert_eq!(
        shown,
        1,
        "{:?}",
        rows.iter().map(|r| &r.text).collect::<Vec<_>>()
    );
    assert!(!rows[0].text.contains("local"), "{}", rows[0].text);
}

/// [D] An open huddle is a needs-you entry of the map: the strip says "huddle: CLASH", `g N` reaches the first of its
/// agents the view shows, and its agents are not marked as needing you (a huddle that talks waits for nobody); a
/// decided or closed one leaves.
#[test]
fn open_huddle_is_on_the_strip_and_the_needs_you_list() {
    let mut core = core_with(2);
    let who = ["s1".to_owned(), "s2".to_owned()];
    core.step(Event::Card(huddle_card(
        "h1",
        Some("both edit a.rs"),
        &who,
        true,
    )));
    let v = rows_view(core.model(), 226);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    assert!(
        rows[0].text.contains("huddle: both edit a.rs"),
        "{}",
        rows[0].text
    );
    let d = model::doc(
        core.model(),
        v.layout.as_ref().expect("laid out"),
        &v.sent,
        &graph_state(),
    );
    assert_eq!(d.lists["needs-you"], vec!["agent:s1"]);
    assert!(
        core.model().items().values().all(|it| !it.needs_you),
        "a huddle marks nobody"
    );
    core.step(Event::Card(huddle_card(
        "h1",
        Some("both edit a.rs"),
        &who,
        false,
    )));
    let v = rows_view(core.model(), 226);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    assert!(!rows[0].text.contains("huddle:"), "{}", rows[0].text);
}

/// [D] The outline the user asks for (`work/map/set {outline}`): on, the map is the outline even where the layout
/// fits; off, the cards even where it does not; auto (the default) the outline only where it does not fit.
#[test]
fn outline_follows_the_users_choice() {
    let core = core_with(3);
    let mut v = rows_view(core.model(), 226);
    assert!(v.layout.as_ref().expect("laid out").fits);
    let outlined = |v: &View| {
        view_rows(core.model(), v, &env(), &Cols, 0, &BTreeSet::new(), &[])
            .0
            .iter()
            .any(|r| r.key.starts_with("outline:"))
    };
    assert!(!outlined(&v), "auto, and it fits: the cards");
    v.outline = render::Outline::On;
    assert!(outlined(&v), "on: the outline");
    let thirty = core_with(30);
    let mut narrow = rows_view(thirty.model(), 40);
    assert!(!narrow.layout.as_ref().expect("laid out").fits);
    narrow.outline = render::Outline::Off;
    assert!(
        !view_rows(
            thirty.model(),
            &narrow,
            &env(),
            &Cols,
            0,
            &BTreeSet::new(),
            &[]
        )
        .0
        .iter()
        .any(|r| r.key.starts_with("outline:")),
        "off: the cards"
    );
    assert_eq!(outline_of("on"), Some(render::Outline::On));
    assert_eq!(outline_of("off"), Some(render::Outline::Off));
    assert_eq!(outline_of("auto"), Some(render::Outline::Auto));
    assert_eq!(outline_of("sideways"), None);
}

/// [D] A conclusion that changes marks its card new for 4 s of the hub's clock, the first one an item gets too; an
/// item seen for the first time marks nothing (a view opened on old work); the mark leaves at 4 s, and the wake asked
/// for is the oldest mark's end.
#[test]
fn a_new_conclusion_is_marked_for_four_seconds() {
    let id = ItemId("agent:s1".into());
    let mut n = NewMarks::default();
    let c = |s: Option<&str>| BTreeMap::from([(id.clone(), s.map(str::to_owned))]);
    assert_eq!(
        n.note(c(Some("one")), 1_000),
        None,
        "first seen: nothing new"
    );
    assert!(n.ids().is_empty());
    assert_eq!(n.note(c(Some("one")), 2_000), None, "unchanged");
    assert_eq!(
        n.note(c(Some("two")), 3_000),
        Some(4_000),
        "changed: new until 7000"
    );
    assert!(n.ids().contains(&id));
    assert_eq!(n.note(c(Some("two")), 6_999), Some(1));
    assert!(n.ids().contains(&id));
    assert_eq!(n.note(c(Some("two")), 7_000), None, "4 s on: gone");
    assert!(n.ids().is_empty());
    let other = ItemId("agent:s2".into());
    let mut n = NewMarks::default();
    assert_eq!(n.note(BTreeMap::from([(other.clone(), None)]), 0), None);
    assert_eq!(
        n.note(BTreeMap::from([(other.clone(), Some("first".into()))]), 10),
        Some(4_000),
        "a first conclusion is new"
    );
}

/// [D] An agent on a task names itself in the Flow by its model, then its session: the map's label ("Sonnet ·
/// search-quick") gives the session alone after the model; without a model the label is the agent's name.
#[test]
fn a_task_agent_names_its_model_then_its_session() {
    let a = TaskAgent {
        label: "Sonnet · search-quick".into(),
        model: Some("Sonnet".into()),
        ..TaskAgent::default()
    };
    assert_eq!(
        a.names(),
        ("Sonnet".to_owned(), Some("search-quick".to_owned()))
    );
    let a = TaskAgent {
        label: "search-quick".into(),
        ..TaskAgent::default()
    };
    assert_eq!(a.names(), ("search-quick".to_owned(), None));
}

/// [D] A test hub's scene seeds its agent sessions into every map it opens, each in its state for the minutes the
/// scene gives it: the held task's agent of hub-orchestration.html, 41 min, ≈$0.90, ctx 88%.
#[cfg(feature = "test-hooks")]
#[test]
fn the_scenes_sessions_are_on_every_map_for_their_minutes() {
    let map = Map::default();
    map.scene(crate::orch::scene::sessions());
    let mut g = lock(&map.inner);
    let evs = Map::scene_events(&mut g, 1_000);
    let facts: Vec<&SessionFact> = evs
        .iter()
        .filter_map(|e| match e {
            Event::Session(s) => Some(s),
            _ => None,
        })
        .collect();
    assert_eq!(facts.len(), 1, "{evs:?}");
    let s = facts[0];
    assert_eq!(
        (s.name.as_str(), s.model.as_str(), s.task.as_deref()),
        ("search-quick", "Sonnet", Some("scene-run#5"))
    );
    assert_eq!(s.since, 959);
    assert_eq!(s.spend.as_deref(), Some("$0.90"));
    assert_eq!(s.context, Some(88));
    // a map opened gets the clock's minute with them, so the agent's card counts its minutes from it at once
    drop(g);
    let mut g = lock(&map.inner);
    let mut core = Core::new();
    for ev in Map::opening(&mut g, 1_000) {
        core.step(ev);
    }
    let agent = core
        .model()
        .items()
        .into_values()
        .find(|it| it.kind == Kind::Agent)
        .expect("the scene's agent");
    assert_eq!(agent.fields.minutes, Some(41));
}

/// [D] A plan run's agent is on its session's task even when the map has no plan holding that task (a run's tasks are
/// the job's, not a plan's): the Flow's detail head reads it there.
#[test]
fn a_task_agent_is_on_its_sessions_task_without_a_plan() {
    let (_map, mut g, key) = rows_map(0, 226);
    let snap: Snapshot = serde_json::from_value(
        json!({"id": "s1", "name": "search-quick", "profile": "Sonnet", "task": "J#5"}),
    )
    .expect("a snapshot");
    let sess = Sess {
        snap,
        kids: Vec::new(),
        place: None,
        seq: 1,
        state: State::Running,
        since: 0,
        job: None,
    };
    let sp = g.spaces.get_mut("w").expect("the space");
    for ev in sess.facts() {
        sp.core.step(ev);
    }
    g.sessions.insert("s1".into(), sess);
    let agents = Map::task_agents_in(&g, 1, &key.view);
    assert_eq!(agents.len(), 1, "{agents:?}");
    assert_eq!(agents[0].task, "J#5");
    assert_eq!(
        agents[0].names(),
        ("Sonnet".to_owned(), Some("search-quick".to_owned()))
    );
}

/// [D] A test hub's map scene (`RATATOSKR_SEED_SCENE=map`) puts the mockup's whole graph on every map it opens: asks,
/// specs, plans, four agents, their branches, files and machines, two open cards (a push and a
/// permission; the hub scene's held gate is the third), and an overlap between two agents on one file (work-space-dark.html).
#[cfg(feature = "test-hooks")]
#[test]
fn the_map_scene_has_every_layer_the_overlap_and_its_cards() {
    let map = Map::default();
    map.scene_graph(crate::orch::scene::map_events());
    let mut g = lock(&map.inner);
    let mut core = Core::new();
    for ev in Map::opening(&mut g, 40) {
        core.step(ev);
    }
    let items = core.model().items();
    for (kind, at_least) in [
        (Kind::Ask, 3),
        (Kind::Spec, 2),
        (Kind::Plan, 3),
        (Kind::Agent, 4),
        (Kind::Branch, 4),
        (Kind::File, 2),
        (Kind::Machine, 2),
    ] {
        let n = items.values().filter(|i| i.kind == kind).count();
        assert!(n >= at_least, "{kind:?}: {n} < {at_least}");
    }
    // the model keeps a pair of agents and a pair of their branches: one overlap on the map, session.rs of two agents
    let pairs = core.model().overlaps();
    let agents = pairs
        .iter()
        .filter(|o| o.a.as_str().starts_with("agent:"))
        .count();
    assert_eq!(agents, 1, "{pairs:?}");
    let kinds: Vec<CardKind> = core
        .model()
        .needs_you()
        .into_iter()
        .map(|n| n.kind)
        .collect();
    // the strip reads as the mockup's: the push first, then the permission
    assert_eq!(
        kinds[..2],
        [CardKind::Push, CardKind::Permission],
        "{kinds:?}"
    );
    // the first agent's branch carries the machine and slot its agent runs on, as its chip's tag
    let branch = items
        .get(&ItemId("branch:drgnx/rp-df-hub".into()))
        .expect("the first agent's branch");
    assert_eq!(branch.fields.tag.as_deref(), Some("desk 3"), "{branch:?}");
    for k in [CardKind::Push, CardKind::Permission] {
        assert_eq!(
            kinds.iter().filter(|c| **c == k).count(),
            1,
            "{k:?} in {kinds:?}"
        );
    }
}

/// [D] The map scene's agents run for the minutes the fixture gives them before its own clock (minute 40), counted
/// from the hub's clock when a map opens: "testing · 32 min", not the minutes since the epoch.
#[cfg(feature = "test-hooks")]
#[test]
fn the_map_scenes_agents_run_for_their_fixture_minutes() {
    let map = Map::default();
    map.scene_graph(crate::orch::scene::map_events());
    let mut g = lock(&map.inner);
    let mut core = Core::new();
    for ev in Map::opening(&mut g, 29_909_760) {
        core.step(ev);
    }
    let mut minutes: Vec<(String, Option<u64>)> = core
        .model()
        .items()
        .into_values()
        .filter(|it| it.kind == Kind::Agent)
        .map(|it| (it.label, it.fields.minutes))
        .collect();
    minutes.sort();
    assert_eq!(
        minutes,
        [
            ("Opus · I6".to_owned(), Some(12)),
            ("Opus · hub rows".to_owned(), Some(32)),
            ("Opus · jobq plan".to_owned(), Some(9)),
            ("Sonnet · fx-sess".to_owned(), Some(14)),
        ],
        "the minutes of the agents the mockup shows"
    );
}

/// The kit's env of a graphical display at SCALE (no glyphs of its own, no icons).
fn kit_env(scale: f32) -> drgnx_rows::kit::KitEnv<'static> {
    drgnx_rows::kit::KitEnv {
        scale,
        tty: false,
        glyphs: &[],
        ascii: false,
        density: drgnx_rows::kit::Density::Comfortable,
        icons: None,
    }
}

/// [D] The Detail's actions row is kit buttons: each button's runs carry the kit face `drgnx-kit-button-secondary` (its
/// key hint `drgnx-kit-key-hint-cap` inside it) and padding that is the kit's (pad spaces, no literal blanks round
/// the label), in device px at the scale.
#[test]
fn detail_actions_are_kit_buttons() {
    let mut core = vegvisir::Core::new();
    for e in vegvisir::fixture::scene() {
        core.step(e);
    }
    let agent = ItemId("agent:a1".into());
    let lines = detail::lines(core.model(), Some(&agent), 0);
    for scale in [1.0f32, 1.25] {
        let rows = detail::rows(&lines, &kit_env(scale), 340, &Cols);
        let open = rows
            .iter()
            .find(|r| r.key.starts_with("actions/") && r.text.contains("Open"))
            .expect("the Open action");
        let faces: Vec<&str> = open.runs.iter().map(|x| x.2.as_str()).collect();
        assert!(
            faces.contains(&FaceId::KitButtonSecondary.name()),
            "{open:?}"
        );
        assert!(faces.contains(&FaceId::KitKeyHintCap.name()), "{open:?}");
        // the sm button's 8 px each side, in device px, and its 22 px height
        let pad = (8.0 * scale + 0.5).floor() as u32;
        assert!(open.spaces.iter().any(|s| s.1 == pad), "{open:?}");
        assert_eq!(
            open.height.map(|h| h.unit),
            Some((22.0 * scale + 0.5).floor() as u32)
        );
        // the pads are the kit's spaces: button start, gap, the key hint's two and the button end
        assert!(open.spaces.len() >= 5, "{open:?}");
    }
}

/// [D] The Detail tile is the mockup's (work-space-dark.html `.det`): the head in the heading face, the sections' keys
/// ("you", "spec", "plan", "task") muted in a column and their values in the accent, the actions as buttons with their
/// keys, and every row in the card's UI font.
#[test]
fn detail_rows_are_the_mockups_tile() {
    let mut core = vegvisir::Core::new();
    for e in vegvisir::fixture::scene() {
        core.step(e);
    }
    let m = core.model();
    let agent = ItemId("agent:a1".into());
    let rows = detail::rows(
        &detail::lines(m, Some(&agent), 0),
        &kit_env(1.0),
        340,
        &Cols,
    );
    fn faces_of(r: &Row) -> Vec<&str> {
        r.runs.iter().map(|x| x.2.as_str()).collect()
    }
    assert!(
        faces_of(&rows[0]).contains(&FaceId::UiHeading.name()),
        "{:?}",
        rows[0]
    );
    let key = |k: &str| -> Row {
        rows.iter()
            .find(|r| r.text.trim_start().starts_with(k) && !r.stops.is_empty())
            .unwrap_or_else(|| panic!("a `{k}` row with a key column in {rows:?}"))
            .clone()
    };
    // the head: the agent's badge, its name and its state as a chip at the right; then the subtitle
    // (work-space-dark.html `.det .hd`)
    assert!(rows[0].text.contains("Opus · hub rows"), "{:?}", rows[0]);
    assert!(
        faces_of(&rows[0]).contains(&FaceId::KitChipNeutralSoft.name()),
        "{:?}",
        rows[0]
    );
    assert!(
        faces_of(&rows[0]).contains(&FaceId::KitAgentMark.name()),
        "{:?}",
        rows[0]
    );
    assert!(
        !rows[0].stops.is_empty(),
        "the chip is at the right edge: {:?}",
        rows[0]
    );
    assert!(
        rows[1].text.contains("SESSION-END-LOSES-STARTED-1"),
        "{:?}",
        rows[1]
    );
    assert!(
        faces_of(&rows[1]).contains(&FaceId::TextMuted.name()),
        "{:?}",
        rows[1]
    );
    for k in ["you", "spec", "plan", "task"] {
        let r = key(k);
        assert!(faces_of(&r).contains(&FaceId::TextMuted.name()), "{r:?}");
        assert!(faces_of(&r).contains(&FaceId::Accent.name()), "{r:?}");
    }
    let open = rows
        .iter()
        .find(|r| r.text.contains("Open"))
        .expect("the Open action");
    assert!(
        faces_of(open).contains(&FaceId::KitButtonSecondary.name()),
        "{open:?}"
    );
    assert!(
        faces_of(open).contains(&FaceId::KitKeyHintCap.name()),
        "{open:?}"
    );
    for r in &rows {
        assert!(faces_of(r).contains(&FaceId::WorkPane.name()), "{r:?}");
    }
}

/// [D] The map's text is the UI font at the caption size (`drgnx-work-card`): the card line's height and its fit are those of the
/// editor's `caption` role (the UI caption face), not of `ui` (the buffer's default, the code font) that the rows used to be
/// drawn in.
#[test]
fn the_card_line_is_measured_in_the_caption_role() {
    let env: ViewEnv = serde_json::from_value(json!({
        "view": "m", "class": "gui-1", "epoch": 1, "display": "gui", "scale": 1.0, "cell": [8, 16],
        "width_px": 1000,
        "fonts": [["ui", null, 0, 13.0, 11.0, 3.0, 8.0, 6.0],
                  ["caption", null, 0, 12.0, 12.0, 4.0, 6.5, 3.0]]
    }))
    .expect("an env");
    let palette = Palette(Vec::new());
    assert_eq!(render_env(&env, &palette).line, (16, 75));
}

/// [D] The Detail head's subtitle wraps by word at the island's width (the mockup's is two lines), each part whole: no
/// cut word and no continuation glyph.
#[test]
fn the_detail_subtitle_wraps_by_word_in_the_tile() {
    let mut core = vegvisir::Core::new();
    for e in vegvisir::fixture::scene() {
        core.step(e);
    }
    let agent = ItemId("agent:a1".into());
    let lines = detail::lines(core.model(), Some(&agent), 0);
    for width in [340u32, 260] {
        let rows = detail::rows(&lines, &kit_env(1.0), width, &Cols);
        // the subtitle is the rows keyed head/1, head/1.1, ...: each fits (8 px a column, 8 px of padding each side)
        let sub: Vec<&drgnx_rows::Row> = rows
            .iter()
            .filter(|r| r.key == "head/1" || r.key.starts_with("head/1."))
            .collect();
        assert!(sub.len() >= 2, "{width}: wraps by word, {sub:?}");
        for r in &sub {
            let px = r.text.chars().count() as u32 * 8;
            assert!(px <= width - 16, "{width}: {px} px, {:?}", r.text);
            assert!(!r.text.contains('…'), "no cut word: {:?}", r.text);
        }
        let all: Vec<&str> = sub.iter().map(|r| r.text.as_str()).collect();
        assert!(all.join(" ").contains("API prices"), "{all:?}");
    }
    // everything fits in the width, so nothing is dropped
    let roomy = detail::rows(&lines, &kit_env(1.0), 900, &Cols);
    assert!(
        roomy[1].text.contains("API prices"),
        "one row: {:?}",
        roomy[1]
    );
    assert_ne!(roomy[2].key, "head/1.1");
}

/// [D] An agent's Touches names its branch with its worktree, its machine with its slot and the file its branch
/// changed most with the change (work-space-dark.html, the Detail: `rp-df-hub · worktree rp-df-hub`, `desktop · slot 3`,
/// `session.rs +40 −3`), in that order, reads after them.
#[test]
fn an_agents_touches_are_the_mockups_lines_in_order() {
    let mut core = vegvisir::Core::new();
    for e in vegvisir::fixture::scene() {
        core.step(e);
    }
    let lines = detail::lines(core.model(), Some(&ItemId("agent:a1".into())), 0);
    let touches: Vec<&str> = lines
        .iter()
        .filter(|l| l.0 == "touches")
        .map(|l| l.1.as_str())
        .collect();
    assert_eq!(touches[0], "Touches ↓");
    assert_eq!(touches[1], "branch\trp-df-hub · worktree rp-df-hub");
    assert_eq!(touches[2], "machine\tdesktop · slot 3");
    assert_eq!(touches[3], "edits\tsession.rs +40 −3");
    assert_eq!(touches[4], "reads\t14 files ▸");
    let heads: Vec<&str> = lines
        .iter()
        .filter(|l| l.1.ends_with('↑') || l.1.ends_with('↓') || l.1 == "Conclusions")
        .map(|l| l.1.as_str())
        .collect();
    assert_eq!(heads, ["Why ↑", "Touches ↓", "Conclusions"]);
}

/// [D] The Detail head says what the agent is doing as the card does (`testing`, not the class `test`) and how long the
/// session has run (`running 47 min`, the feed's age; the card's 32 min are the minutes in its state).
#[test]
fn the_detail_head_says_testing_and_the_run_age() {
    let mut core = vegvisir::Core::new();
    for e in vegvisir::fixture::scene() {
        core.step(e);
    }
    let lines = detail::lines(core.model(), Some(&ItemId("agent:a1".into())), 0);
    assert!(lines[0].1.ends_with("\ttesting"), "{:?}", lines[0]);
    assert!(lines[1].1.contains("running 47 min"), "{:?}", lines[1]);
}

/// [D] A gate's chip on the strip says what it is first: its text is a forecast ("2 tasks, about 0.00 USD ..."), and a
/// chip cut at its width left nothing to say it was a plan to approve.
#[test]
fn a_gate_chip_on_the_strip_says_sign_off() {
    let mut core = core_with(1);
    core.step(Event::Card(CardFact {
        id: "g1".into(),
        kind: CardKind::SignOff,
        about: Vec::new(),
        text: "2 tasks, about 0.00 USD (some costs unknown): approve to start".into(),
        open: true,
    }));
    let v = rows_view(core.model(), 226);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    assert!(
        rows[0].text.contains("Sign off: 2 tasks"),
        "{}",
        rows[0].text
    );
}

#[test]
fn a_file_the_importer_holds_is_not_drawn_again_from_the_old_scanners_entity() {
    let file = "/w/docs/plans/m2-evidence.md";
    let rows = [
        ("plan:/w/docs/plans/m2-evidence.md", None),
        ("plan:rec-38377cd08b08-12cc5f9a0c03", Some(file)),
        // an old-scanner plan whose file the importer does not hold stays
        ("plan:/w/docs/plans/other.md", None),
        ("spec:/w/docs/specs/s.md", None),
        (
            "spec:rec-38377cd08b08-aaaaaaaaaaaa",
            Some("/w/docs/specs/s.md"),
        ),
    ];
    let hidden = legacy_duplicates(rows.iter().copied());
    assert_eq!(
        hidden.into_iter().collect::<Vec<_>>(),
        ["/w/docs/plans/m2-evidence.md", "/w/docs/specs/s.md"]
    );
}

#[test]
fn a_proposal_chip_says_sign_off_once_and_names_its_job() {
    let mut core = core_with(1);
    core.step(Event::Card(CardFact {
        id: "g1".into(),
        kind: CardKind::SignOff,
        about: Vec::new(),
        text: strip_text(
            "job-7",
            "2 tasks, about 0.00 USD (some unpriced), 3M tokens, 40 min: approve to start",
        ),
        open: true,
    }));
    let v = rows_view(core.model(), 226);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    assert!(
        rows[0].text.contains("Sign off (job-7): 2 tasks"),
        "{}",
        rows[0].text
    );
    assert!(
        !rows[0].text.to_lowercase().contains("sign off: sign off"),
        "{}",
        rows[0].text
    );
    assert_eq!(
        rows[0].text.matches("Sign off").count(),
        1,
        "{}",
        rows[0].text
    );
}

#[test]
fn a_proposal_on_the_strip_says_what_to_approve_and_which_job() {
    assert_eq!(
        strip_text(
            "job-7",
            "2 tasks, about 0.00 USD (some unpriced), 3M tokens, 40 min: approve to start"
        ),
        "Sign off (job-7): 2 tasks, about 0.00 USD (some unpriced), 3M tokens, 40 min"
    );
    assert_eq!(
        strip_text("job-7", "Codex asks: cargo clippy"),
        "Codex asks: cargo clippy"
    );
}

/// `work/target/set` writes a plan's or spec's `target_at` into its data, null removes it, and an id that is no
/// live entity answers false.
#[tokio::test]
async fn the_target_of_a_plan_is_written_and_null_clears_it() {
    use crate::agents::session::attach_tests::Fx;
    use runstav::methods::work::TargetSetParams;
    let fx = Fx::new();
    let db = &fx.front.writer.db;
    db.write(
        urdr::graph::TxMeta::new("user", urdr::graph::Class::User, "test"),
        |tx| {
            urdr::graph::entity::create(
                tx,
                urdr::graph::entity::EntityNew {
                    id: "plan:p1".into(),
                    kind: "plan".into(),
                    project: None,
                    title: Some("p".into()),
                    status: None,
                    body: None,
                    priority: None,
                    assignee: None,
                    data: serde_json::json!({}),
                    origin: urdr::graph::entity::Origin::Recorded,
                    source: None,
                },
            )?;
            Ok(())
        },
    )
    .await
    .unwrap();
    let caller = crate::dispatch::Caller {
        class: runstav::registry::Class::User,
        sid: None,
        job: None,
        conn_id: 1,
    };
    let set = |item: &str, at: Option<f64>| TargetSetParams {
        item: runstav::types::Bounded(item.into()),
        target_at: at,
    };
    assert!(
        super::target_set(&fx.front, &caller, set("plan:p1", Some(1.8e9)))
            .await
            .unwrap()
    );
    let read = || {
        db.read(|c| {
            Ok(c.query_row(
                "select json_extract(data, '$.target_at') from entity where id = 'plan:p1'",
                [],
                |r| r.get::<_, Option<f64>>(0),
            )?)
        })
    };
    assert_eq!(read().await.unwrap(), Some(1.8e9));
    assert!(
        super::target_set(&fx.front, &caller, set("plan:p1", None))
            .await
            .unwrap()
    );
    assert_eq!(read().await.unwrap(), None);
    assert!(
        !super::target_set(&fx.front, &caller, set("plan:nope", Some(1.0)))
            .await
            .unwrap()
    );
}
/// A session on TASK (a bare task id), in state STATE.
fn task_session(core: &mut Core, i: u64, task: &str, state: State) {
    let snap: Snapshot = serde_json::from_value(
        json!({"id": format!("s{i}"), "name": format!("agent {i}"), "task": task}),
    )
    .expect("a snapshot");
    let sess = Sess {
        snap,
        kids: Vec::new(),
        place: None,
        seq: i,
        state,
        since: 0,
        job: None,
    };
    for ev in sess.facts() {
        core.step(ev);
    }
}

fn graph(core: &mut Core, f: vegvisir::GraphFact) {
    core.step(vegvisir::Event::Graph(f));
}

/// [D] A plan's task with a live agent is a task item, linked plan → task → agent, and its model node says its state.
#[test]
fn a_plan_task_with_a_live_agent_is_a_task_item_linked_both_ways() {
    let mut core = Core::new();
    graph(
        &mut core,
        vegvisir::GraphFact::Plan {
            id: "p".into(),
            title: "P".into(),
            rank: 1,
            progress: None,
            updated: 0,
        },
    );
    graph(
        &mut core,
        vegvisir::GraphFact::Task {
            id: "t".into(),
            plan: "p".into(),
            title: "do it".into(),
            done: false,
            updated: 0,
        },
    );
    task_session(&mut core, 1, "t", State::NeedsYou);
    let m = core.model();
    let item = m.item(&ItemId("task:t".into())).expect("a task item");
    assert_eq!(item.kind, Kind::Task);
    assert_eq!(item.fields.task_state, Some(vegvisir::TaskState::NeedsYou));
    let has = |a: &str, b: &str| {
        m.edges()
            .iter()
            .any(|e| e.from.as_str() == a && e.to.as_str() == b)
    };
    assert!(has("plan:p", "task:t") && has("task:t", "agent:s1"));
    let l = vegvisir::layout::layout(
        m,
        &ViewState {
            width_units: 226,
            ..graph_state()
        },
        None,
    );
    let sent: BTreeSet<ItemId> = m.items().into_keys().collect();
    let doc = model::doc(m, &l, &sent, &graph_state());
    let node = &doc.nodes["task:t"];
    assert!(
        node["fields"]
            .as_array()
            .unwrap()
            .contains(&json!(["task_state", "needs-you"])),
        "{node}"
    );
}

/// [D] The store's reader: a task with no plan sits under a "No plan" plan item instead of being skipped.
#[tokio::test(flavor = "multi_thread")]
async fn a_task_without_a_plan_sits_under_no_plan() {
    use urdr::graph::entity::{self, EntityNew, Origin};
    let dir = tempfile::tempdir().unwrap();
    let front = Front::new(
        runstav::proof::Cap::generate().unwrap(),
        dir.path().join("hub-x.sock"),
        crate::store::WorkDb::spawn(dir.path().join("work.db")).unwrap(),
        norn::store::CoordDb::spawn(dir.path().join("work.db")),
    );
    front
        .writer
        .write(&crate::runner::service(), "test", |tx| {
            let mut mk = |id: &str, kind: &str| {
                entity::create(
                    tx,
                    EntityNew {
                        id: id.into(),
                        kind: kind.into(),
                        project: None,
                        title: Some(id.into()),
                        status: None,
                        body: None,
                        priority: None,
                        assignee: None,
                        data: json!({}),
                        origin: Origin::Recorded,
                        source: None,
                    },
                )
                .map(|e| e.n)
                .map_err(|e| norn::store::CoordError::Refused(e.to_string()))
            };
            let plan = mk("plan:p1", "plan")?;
            let t1 = mk("task:t1", "task")?;
            mk("task:t2", "task")?;
            urdr::graph::link::add(tx, plan, "parent_of", t1, None, Origin::Recorded, None)
                .map_err(|e| norn::store::CoordError::Refused(e.to_string()))?;
            Ok(())
        })
        .await
        .unwrap();
    let (events, _) = read_store(&front).await;
    let task_plan = |id: &str| {
        events.iter().find_map(|e| match e {
            vegvisir::Event::Graph(vegvisir::GraphFact::Task { id: t, plan, .. }) if t == id => {
                Some(plan.clone())
            }
            _ => None,
        })
    };
    assert_eq!(task_plan("t1").as_deref(), Some("p1"));
    assert_eq!(task_plan("t2").as_deref(), Some("no-plan"));
    assert!(events.iter().any(|e| matches!(
        e,
        vegvisir::Event::Graph(vegvisir::GraphFact::Plan { id, title, .. })
            if id == "no-plan" && title == "No plan"
    )));
}

/// [D] A map opens in List mode: the model's descriptor says `list`, and the arrows walk the rows.
#[test]
fn the_list_is_the_default_mode() {
    let mut core = Core::new();
    graph_fact(&mut core, "p", "t");
    let m = core.model();
    let state = ViewState::default();
    assert_eq!(state.mode, vegvisir::MapMode::List);
    let l = vegvisir::layout::layout(m, &state, None);
    let sent: BTreeSet<ItemId> = m.items().into_keys().collect();
    let doc = model::doc(m, &l, &sent, &state);
    assert_eq!(doc.descriptor["mode"], "list");
    let graph_doc = model::doc(m, &l, &sent, &graph_state());
    assert_eq!(graph_doc.descriptor["mode"], "graph");
}

fn graph_fact(core: &mut Core, plan: &str, task: &str) {
    graph(
        core,
        vegvisir::GraphFact::Plan {
            id: plan.into(),
            title: "P".into(),
            rank: 1,
            progress: None,
            updated: 0,
        },
    );
    graph(
        core,
        vegvisir::GraphFact::Task {
            id: task.into(),
            plan: plan.into(),
            title: "T".into(),
            done: false,
            updated: 0,
        },
    );
}

fn card_about(core: &mut Core, id: &str, kind: vegvisir::CardKind, about: &str) {
    core.step(vegvisir::Event::Card(vegvisir::CardFact {
        id: id.into(),
        kind,
        about: vec![about.into()],
        text: format!("card {id}"),
        open: true,
    }));
}

/// [D] Before anything is selected the Detail shows the subject of the most urgent thing that needs you, its head
/// saying so; an empty map still says nothing is selected.
#[test]
fn detail_on_open_shows_the_most_urgent() {
    let empty = Core::new();
    assert_eq!(
        detail::lines_or_default(empty.model(), None, 0),
        vec![("head", "Nothing is selected.".to_string(), None)]
    );
    let mut core = core_with(2);
    card_about(&mut core, "7", vegvisir::CardKind::Push, "agent:s1");
    card_about(&mut core, "8", vegvisir::CardKind::Permission, "agent:s2");
    let m = core.model();
    assert_eq!(detail::default_item(m), Some(ItemId("agent:s2".into())));
    let lines = detail::lines_or_default(m, None, 0);
    assert!(
        lines
            .iter()
            .any(|l| l.0 == "head" && l.1.contains("Needs you most")),
        "{lines:?}"
    );
    assert!(lines.iter().any(|l| l.1.contains("agent 2")), "{lines:?}");
}

/// [D] Once the user selected something, the Detail follows the selection.
#[test]
fn detail_follows_the_selection_once_made() {
    let mut core = core_with(2);
    card_about(&mut core, "8", vegvisir::CardKind::Permission, "agent:s2");
    let m = core.model();
    let sel = ItemId("agent:s1".into());
    let lines = detail::lines_or_default(m, Some(&sel), 0);
    assert!(
        !lines.iter().any(|l| l.1.contains("Needs you most")),
        "{lines:?}"
    );
    assert!(lines.iter().any(|l| l.1.contains("agent 1")), "{lines:?}");
}

/// [D] A proposal's strip text keeps its whole fact (the fit cuts it at the window's edge).
#[test]
fn strip_text_is_not_truncated() {
    let long = format!(
        "{}: approve to start",
        "2 tasks, about 1–3 USD (estimate), 2M tokens, 20 min"
    );
    assert_eq!(
        strip_text("J#1", &long),
        "Sign off (J#1): 2 tasks, about 1–3 USD (estimate), 2M tokens, 20 min"
    );
    let words = "x".repeat(300);
    assert_eq!(strip_text("J#1", &words), words);
}

/// [D] A session's spend reaches the map whether its usage carries the cost as a number or as an object with an
/// `amount` (the agent's usage update): a turn's end then changes its card, and the map patches.
#[test]
fn a_cost_object_is_the_sessions_spend() {
    for cost in [json!(0.01), json!({"amount": 0.01, "currency": "USD"})] {
        let snap: Snapshot = serde_json::from_value(
            json!({"id": "s1", "name": "a", "usage": {"used": 10.0, "size": 100.0, "cost": cost}}),
        )
        .expect("a snapshot");
        let sess = Sess {
            snap,
            kids: Vec::new(),
            place: None,
            seq: 1,
            state: State::Running,
            since: 0,
            job: None,
        };
        let spend = sess.facts().into_iter().find_map(|e| match e {
            vegvisir::Event::Session(s) => s.spend,
            _ => None,
        });
        assert_eq!(spend.as_deref(), Some("$0.01"), "{cost}");
    }
}

fn week_pace(
    provider: &str,
    used: f64,
    rate: f64,
    rate_7d: Option<f64>,
    resets_at: Option<f64>,
) -> runstav::methods::timeline::Pace {
    runstav::methods::timeline::Pace {
        provider: provider.into(),
        window: "week".into(),
        used_share: used,
        rate_per_hour: rate,
        exhausted_at: None,
        resets_at,
        estimate: true,
        rate_7d_per_hour: rate_7d,
        history: Vec::new(),
    }
}

/// [D] Without a scene the strip has a chip for each weekly meter: its share and its seven-day rate, with "runs out"
/// when that rate uses the week up before it resets; a five-hour meter has none.
#[test]
fn the_strip_shows_week_pace_without_a_scene() {
    let now = 1_000_000.0;
    let hour = 3600.0;
    let mut five = week_pace("claude", 0.8, 0.1, None, None);
    five.window = "5h".into();
    let paces = [
        five,
        week_pace("claude", 0.41, 0.0, Some(0.032), Some(now + 100.0 * hour)),
        week_pace("codex", 0.1, 0.001, None, Some(now + 100.0 * hour)),
    ];
    let chips = strip_chips_of(&paces, None, now);
    assert_eq!(
        chips,
        vec![
            "Claude wk 41 % · +3.2 %/h · runs out".to_owned(),
            "Codex wk 10 % · +0.1 %/h".to_owned()
        ]
    );
    // the same pace with the reset sooner than the week runs out: no warning
    let soon = [week_pace(
        "claude",
        0.41,
        0.0,
        Some(0.032),
        Some(now + 10.0 * hour),
    )];
    assert_eq!(
        strip_chips_of(&soon, None, now),
        vec!["Claude wk 41 % · +3.2 %/h".to_owned()]
    );
}

/// [D] The selected plan's binding budget follows the weekly chips: dollars as `$31/$40`, a share of the week as
/// `11 %/15 % wk`, the state as a word when nearing or reached.
#[test]
fn the_strip_shows_the_selected_plans_budget() {
    use runstav::methods::{matrix::Unit, timeline::BudgetState};
    let usd = PlanBudget {
        unit: Unit::Usd,
        spent: 31.0,
        limit: Some(40.0),
        state: BudgetState::Ok,
    };
    assert_eq!(
        strip_chips_of(&[], Some(&usd), 0.0),
        vec!["plan $31/$40".to_owned()]
    );
    let share = PlanBudget {
        unit: Unit::LimitShare,
        spent: 0.11,
        limit: Some(0.15),
        state: BudgetState::Nearing,
    };
    assert_eq!(
        strip_chips_of(&[], Some(&share), 0.0),
        vec!["plan 11 %/15 % wk · nearing".to_owned()]
    );
    let reached = PlanBudget {
        unit: Unit::UsdEst,
        spent: 4.0,
        limit: Some(4.0),
        state: BudgetState::Reached,
    };
    assert_eq!(
        strip_chips_of(&[], Some(&reached), 0.0),
        vec!["plan $4.00/$4.00 · reached".to_owned()]
    );
    // after the week chips, in that order
    let both = strip_chips_of(
        &[week_pace("claude", 0.5, 0.0, None, None)],
        Some(&usd),
        0.0,
    );
    assert_eq!(both.len(), 2);
    assert!(both[0].starts_with("Claude wk") && both[1].starts_with("plan"));
}

/// [D] A plan with no limit anywhere shows what it spent, alone.
#[test]
fn a_plan_with_no_limit_shows_spend_alone() {
    use runstav::methods::{matrix::Unit, timeline::BudgetState};
    let b = PlanBudget {
        unit: Unit::Usd,
        spent: 12.0,
        limit: None,
        state: BudgetState::None,
    };
    assert_eq!(
        strip_chips_of(&[], Some(&b), 0.0),
        vec!["plan $12".to_owned()]
    );
    assert!(strip_chips_of(&[], None, 0.0).is_empty());
}

// ---- Task 20: List mode on the kit ----

const LIST_DAY: u64 = 24 * 60;

fn list_session(
    id: &str,
    task: &str,
    state: vegvisir::State,
    machine: &str,
) -> vegvisir::SessionFact {
    vegvisir::SessionFact {
        id: id.into(),
        name: id.into(),
        model: "Sonnet".into(),
        state,
        since: 100 * LIST_DAY,
        age: None,
        seq: 1,
        task: Some(task.into()),
        manager: None,
        branch: Some(format!("drgnx/{id}")),
        worktree: None,
        base: None,
        machine: Some(machine.into()),
        slot: None,
        spend: None,
        context: None,
        progress: None,
        job: None,
    }
}

/// A spec with a plan (2 of 4 steps) and five tasks (not started, running with an agent on `desktop`, done, needs you,
/// one with a 200-letter title), a second spec nobody works on, all at day 100.
fn list_world() -> Core {
    use vegvisir::{Event, GraphFact, MachineFact};
    let g = |f| Event::Graph(f);
    let task = |id: &str, title: String, done: bool| {
        g(GraphFact::Task {
            id: id.into(),
            plan: "p1".into(),
            title,
            done,
            updated: 100 * LIST_DAY,
        })
    };
    let mut core = Core::new();
    for e in [
        Event::Tick {
            minute: 100 * LIST_DAY,
        },
        g(GraphFact::Spec {
            id: "s1".into(),
            title: "Title bar".into(),
            updated: 100 * LIST_DAY,
        }),
        g(GraphFact::Spec {
            id: "s2".into(),
            title: "Idle spec".into(),
            updated: 100 * LIST_DAY,
        }),
        g(GraphFact::Plan {
            id: "p1".into(),
            title: "Inbox drop-down".into(),
            rank: 1,
            progress: Some((2, 4)),
            updated: 100 * LIST_DAY,
        }),
        g(GraphFact::Derives {
            plan: "p1".into(),
            spec: "s1".into(),
        }),
        task("t1", "Count on the pill".into(), false),
        task("t2", "Anchor the card".into(), false),
        task("t3", "Footer cut off".into(), true),
        task("t4", "Allow once".into(), false),
        task("t5", "L".repeat(200), false),
        Event::Machines(vec![MachineFact {
            name: "desktop".into(),
            slots: 4,
            used: 1,
            reported: false,
            runner: None,
        }]),
        Event::Session(list_session(
            "a1",
            "t2",
            vegvisir::State::Running,
            "desktop",
        )),
        Event::Session(list_session(
            "a2",
            "t4",
            vegvisir::State::NeedsYou,
            "desktop",
        )),
    ] {
        core.step(e);
    }
    core
}

/// A List-mode view of M showing SHOW.
fn list_view(m: &vegvisir::Model, show: vegvisir::Show) -> View {
    let state = ViewState {
        mode: vegvisir::MapMode::List,
        width_units: 226,
        filters: vegvisir::Filters {
            show,
            ..vegvisir::Filters::default()
        },
        ..ViewState::default()
    };
    let mut v = rows_view(m, 226);
    v.state = state;
    v
}

fn list_row_of<'a>(rows: &'a [Row], text: &str) -> &'a Row {
    rows.iter()
        .find(|r| r.key.starts_with("list:") && r.text.contains(text))
        .unwrap_or_else(|| {
            panic!(
                "a list row with {text:?} in {:?}",
                rows.iter().map(|r| &r.text).collect::<Vec<_>>()
            )
        })
}

fn has_face(r: &Row, f: FaceId) -> bool {
    r.runs.iter().any(|x| x.2 == f.name())
}

/// [D] A task's row is the kit's pieces: its state dot in the state's face, the agent's mark and its machine; a plan's
/// row has the kit's progress bar.
#[test]
fn list_rows_are_the_kits_pieces() {
    let core = list_world();
    let v = list_view(core.model(), vegvisir::Show::All);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    let running = list_row_of(&rows, "Anchor the card");
    assert!(
        has_face(running, FaceId::KitStatusDotRunning),
        "{running:?}"
    );
    assert!(has_face(running, FaceId::KitAgentMark), "{running:?}");
    assert!(running.text.contains("desktop"), "{}", running.text);
    let plan = list_row_of(&rows, "Inbox drop-down");
    assert!(has_face(plan, FaceId::KitProgressFill), "{plan:?}");
    assert!(plan.text.contains("2/4"), "{}", plan.text);
}

/// [D] Every task state is a dot and its word (Review Focus 5: colour is never the only sign).
#[test]
fn list_states_carry_words() {
    let core = list_world();
    let v = list_view(core.model(), vegvisir::Show::All);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    for (title, word, dot) in [
        ("Count on the pill", "not started", FaceId::KitStatusDotIdle),
        ("Anchor the card", "running", FaceId::KitStatusDotRunning),
        ("Footer cut off", "done", FaceId::KitStatusDotDone),
        ("Allow once", "needs you", FaceId::KitStatusDotNeedsYou),
    ] {
        let r = list_row_of(&rows, title);
        assert!(r.text.contains(word), "{title}: {}", r.text);
        assert!(has_face(r, dot), "{title}: {r:?}");
    }
}

/// [D] A long title is cut with an ellipsis at the stop the right-hand pieces start at, so they stay whole, and the
/// row's `help-echo` has the whole title.
#[test]
fn list_a_long_title_is_cut_at_the_edge_with_a_tooltip() {
    let core = list_world();
    let v = list_view(core.model(), vegvisir::Show::All);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    let mut r = list_row_of(&rows, &"L".repeat(20)).clone();
    let full = "L".repeat(200);
    assert!(
        r.props
            .iter()
            .any(|p| p.2 == "help-echo" && p.3.as_str() == Some(full.as_str())),
        "{r:?}"
    );
    drgnx_rows::fit_row::fit_row(
        &mut r,
        &Cols,
        &drgnx_rows::fit_row::Room {
            width_px: 1000,
            tty: None,
            image_px: &|_| None,
            tail: None,
        },
    );
    assert!(r.text.contains('…'), "{}", r.text);
    assert!(
        r.text.contains("not started"),
        "the state stays: {}",
        r.text
    );
}

/// [D] Active's rows sit under section headers: In progress, Ready, and the closing Completed with its count.
#[test]
fn list_has_section_headers() {
    let core = list_world();
    let v = list_view(core.model(), vegvisir::Show::Active);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    let heads: Vec<&str> = rows
        .iter()
        .filter(|r| has_face(r, FaceId::KitSectionHeader))
        .map(|r| r.text.as_str())
        .collect();
    assert!(heads.iter().any(|h| h.contains("In progress")), "{heads:?}");
    assert!(heads.iter().any(|h| h.contains("Ready")), "{heads:?}");
}

/// [D] A workspace with nothing on it says so in one row that is no item.
#[test]
fn list_an_empty_workspace_says_so() {
    let core = Core::new();
    let v = list_view(core.model(), vegvisir::Show::Active);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    let r = rows
        .iter()
        .find(|r| r.key == "empty:list")
        .expect("the empty row");
    assert!(r.text.contains("Nothing here yet"), "{}", r.text);
    assert!(!r.props.iter().any(|p| p.2 == "drgnx-work-id"));
}

/// [D] A needs-you chip is the kit's warn chip with its jump key as a kit key hint, and shows a 40-letter fact whole (two chips share the width)
/// (the strip once cut every chip at 260 px).
#[test]
fn list_strip_chips_show_full_text() {
    let mut core = list_world();
    let fact = "which of these two files should I touch?".to_owned();
    core.step(vegvisir::Event::Card(CardFact {
        id: "c1".into(),
        kind: CardKind::Question,
        about: vec!["agent:a1".into()],
        text: fact.clone(),
        open: true,
    }));
    let v = list_view(core.model(), vegvisir::Show::All);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    let strip = &rows[0];
    assert!(strip.text.contains(&fact), "{}", strip.text);
    assert!(has_face(strip, FaceId::KitChipWarnSoft), "{strip:?}");
    assert!(has_face(strip, FaceId::KitKeyHintCap), "{strip:?}");
    assert!(strip.text.contains("g1"), "{}", strip.text);
}

// ---- Task 22: the Detail on the kit ----

/// [D] The Detail has no hand padding: an agent's head is the kit's agent mark and the kit's chip (no run in the old
/// hand chip face), and every action is a small kit button that runs its command when clicked (kind `work-command`).
#[test]
fn detail_rows_have_no_hand_padding() {
    let mut core = vegvisir::Core::new();
    for e in vegvisir::fixture::scene() {
        core.step(e);
    }
    let agent = ItemId("agent:a1".into());
    let lines = detail::lines(core.model(), Some(&agent), 0);
    let rows = detail::rows(&lines, &kit_env(1.0), 340, &Cols);
    let head = rows.iter().find(|r| r.key == "head/0").expect("the head");
    assert!(has_face(head, FaceId::KitAgentMark), "{head:?}");
    assert!(has_face(head, FaceId::KitChipNeutralSoft), "{head:?}");
    assert!(!has_face(head, FaceId::Chip), "{head:?}");
    for (label, command) in [
        ("Open", "work-open"),
        ("Trail", "work-trail"),
        ("Steer", "work-steer"),
        ("Pause", "work-pause"),
    ] {
        let r = rows
            .iter()
            .find(|r| r.key.starts_with("actions/") && r.text.contains(label))
            .unwrap_or_else(|| panic!("the {label} action"));
        assert!(
            r.props
                .iter()
                .any(|p| p.2 == "drgnx-action" && p.3 == json!(["work-command", command])),
            "{label}: {r:?}"
        );
    }
}

// ---- Task 30: accessibility and the terminal form of the List ----

/// [D] `a11y-flow/every-glyph-has-a-label`, on the List: every state dot has its word in the row, and every agent mark
/// has a `help-echo` over it (the mark is one letter on a colour).
#[test]
fn a11y_flow_list_every_glyph_has_a_label() {
    let core = list_world();
    let v = list_view(core.model(), vegvisir::Show::All);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    let mut dots = 0;
    for r in rows.iter().filter(|r| r.key.starts_with("list:")) {
        if r.runs.iter().any(|x| {
            [
                FaceId::KitStatusDotIdle,
                FaceId::KitStatusDotRunning,
                FaceId::KitStatusDotDone,
                FaceId::KitStatusDotNeedsYou,
            ]
            .iter()
            .any(|f| x.2 == f.name())
        }) {
            dots += 1;
            assert!(
                ["not started", "running", "done", "needs you"]
                    .iter()
                    .any(|w| r.text.contains(w)),
                "a dot without its word: {}",
                r.text
            );
        }
        for x in r.runs.iter().filter(|x| x.2 == FaceId::KitAgentMark.name()) {
            assert!(
                r.props
                    .iter()
                    .any(|p| p.2 == "help-echo" && p.0 <= x.0 && x.1 <= p.1),
                "an agent mark without a help-echo: {r:?}"
            );
        }
    }
    assert!(dots >= 4, "the world's tasks have dots");
}

/// [D] On a terminal the List has the kit's state dot with its word once (no second word at the right) and no stop
/// (the pieces follow the title after two spaces).
#[test]
fn list_on_a_terminal_has_one_word_and_no_stop() {
    let core = list_world();
    let v = list_view(core.model(), vegvisir::Show::All);
    let tty: ViewEnv = serde_json::from_value(
        json!({"view": "m", "class": "tty-1", "epoch": 1, "display": "tty", "scale": 1.0,
                                  "cell": [1, 1], "width_px": 100}),
    )
    .expect("a tty env");
    let (rows, _) = view_rows(core.model(), &v, &tty, &Cols, 0, &BTreeSet::new(), &[]);
    let r = list_row_of(&rows, "Anchor the card");
    assert!(has_face(r, FaceId::KitStatusDotRunning), "{r:?}");
    assert_eq!(r.text.matches("running").count(), 1, "{}", r.text);
    assert!(r.stops.is_empty(), "{r:?}");
}

// ---- Task 20a: budgets on List rows ----

/// The world of [`list_world`] with budgets: the running task at 9 of $12 (nearing), the needs-you task at its $5 limit
/// (reached), the not-started one with a spend and no limit.
fn list_budget_world() -> Core {
    use vegvisir::model::{ItemBudget, Num};
    use vegvisir::{Event, GraphFact};
    let mut core = list_world();
    for (item, spent, limit, state) in [
        ("task:t2", 9.0, Some(12.0), "nearing"),
        ("task:t4", 5.0, Some(5.0), "reached"),
        ("task:t1", 1.5, None, "none"),
    ] {
        core.step(Event::Graph(GraphFact::Budget {
            item: item.into(),
            budget: Some(ItemBudget {
                spent: Num(spent),
                limit: limit.map(Num),
                unit: "usd".into(),
                state: state.into(),
            }),
        }));
    }
    core
}

/// [D] `work-list/meter-shows-spend-and-limit` and `meter-states-carry-words`: a row's meter is the kit's `row` meter,
/// not a chip: its bar in the state's face, its text, and the state's word (a nearing one the share, a reached one "at
/// limit", one with no limit "no limit": colour is never the only sign).
#[test]
fn list_meter_is_a_kit_meter_with_its_words() {
    let core = list_budget_world();
    let v = list_view(core.model(), vegvisir::Show::All);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    let near = list_row_of(&rows, "Anchor the card");
    assert!(has_face(near, FaceId::KitProgressMeterNear), "{near:?}");
    assert!(near.text.contains("$9/$12"), "{}", near.text);
    assert!(near.text.contains("75 %"), "{}", near.text);
    let reached = list_row_of(&rows, "Allow once");
    assert!(
        has_face(reached, FaceId::KitProgressMeterReached),
        "{reached:?}"
    );
    assert!(reached.text.contains("at limit"), "{}", reached.text);
    let none = list_row_of(&rows, "Count on the pill");
    assert!(none.text.contains("no limit"), "{}", none.text);
}

/// [D] The meter names its scope for the editor: over the meter's text the row has `drgnx-work-meter` with the item,
/// the unit and the limit (none: null), which `work-budget-set` reads.
#[test]
fn list_meter_names_its_scope_and_limit_for_the_editor() {
    let core = list_budget_world();
    let v = list_view(core.model(), vegvisir::Show::All);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    let near = list_row_of(&rows, "Anchor the card");
    let p = near
        .props
        .iter()
        .find(|p| p.2 == "drgnx-work-meter")
        .unwrap_or_else(|| panic!("a meter property: {near:?}"));
    assert_eq!(p.3["item"], "task:t2");
    assert_eq!(p.3["unit"], "usd");
    assert_eq!(p.3["limit"], 12.0);
    let none = list_row_of(&rows, "Count on the pill");
    let p = none
        .props
        .iter()
        .find(|p| p.2 == "drgnx-work-meter")
        .expect("a meter property");
    assert!(p.3["limit"].is_null(), "{p:?}");
}

/// [D] `work-list/strip-shows-week-pace`: the strip's pace and plan-budget chips are kit chips (not the plain chip
/// face), neutral, and warn-toned when the week runs out before its reset or the plan's budget is nearing.
#[test]
fn list_strip_pace_and_budget_chips_are_kit_chips_warn_when_they_run_out() {
    let core = list_world();
    let v = list_view(core.model(), vegvisir::Show::All);
    let extra = vec![
        "Claude wk 41 % · +3.2 %/h".to_owned(),
        "Codex wk 80 % · +5.0 %/h · runs out".to_owned(),
        "plan $31/$40 · nearing".to_owned(),
    ];
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &extra);
    let strip = &rows[0];
    assert!(strip.text.contains("Claude wk 41 %"), "{}", strip.text);
    let warn = strip
        .runs
        .iter()
        .filter(|r| r.2 == FaceId::KitChipWarnSoft.name())
        .count();
    let neutral = strip
        .runs
        .iter()
        .filter(|r| r.2 == FaceId::KitChipNeutralSoft.name())
        .count();
    assert!(
        neutral >= 1,
        "a neutral chip for the pace that holds: {strip:?}"
    );
    // the needs-you card of the world and the two warning chips
    assert!(warn >= 3, "warn chips for runs out and nearing: {strip:?}");
}

// ---- Task 22b: Detail's Budget section ----

/// [D] `work-detail/budget-section-shows-meter-and-forecast` (the Rust half): an item with a binding budget has a Budget
/// section under its head: its unit's word, spend, limit and share, in the Detail's own rows.
#[test]
fn detail_shows_the_budget_section_for_an_item_with_a_budget() {
    let core = list_budget_world();
    let task = ItemId("task:t2".into());
    let lines = detail::lines(core.model(), Some(&task), 0);
    let at = lines
        .iter()
        .position(|l| l.0 == "budget" && l.1 == "Budget")
        .expect("a Budget heading");
    assert!(lines[at + 1].1.contains("$9 of $12"), "{:?}", lines[at + 1]);
    assert!(lines[at + 1].1.contains("75 %"), "{:?}", lines[at + 1]);
    let rows = detail::rows(&lines, &kit_env(1.0), 340, &Cols);
    assert!(
        rows.iter()
            .any(|r| r.key.starts_with("budget/") && r.text.contains("$9 of $12")),
        "{rows:?}"
    );
    // an item with no budget has no section
    let none = ItemId("task:t3".into());
    assert!(
        !detail::lines(core.model(), Some(&none), 0)
            .iter()
            .any(|l| l.0 == "budget")
    );
}

// ---- round 3: Detail with facts, the forecast words of a not-started row ----

/// [D] `work-detail/budget-section-shows-meter-and-forecast`: with the facts of `budget/get` along the chain and the
/// forecast, Detail's Budget section has a line for each unit, "Counts toward" with the binding scope and "Set to p90"
/// where p90 is over the limit; before the facts arrive it says "forecasting…" and never blocks.
#[test]
fn detail_with_facts_shows_every_unit_the_chain_and_set_to_p90() {
    use super::budget_detail::{Facts, Link, UnitLine};
    use runstav::methods::forecast::Range;
    use runstav::methods::matrix::Unit;
    let core = list_budget_world();
    let task = ItemId("task:t2".into());
    let facts = Facts {
        units: vec![
            UnitLine {
                unit: Unit::Usd,
                spent: 9.0,
                limit: Some(12.0),
                forecast: Some(Range {
                    p50: 10.0,
                    p90: 14.0,
                }),
            },
            UnitLine {
                unit: Unit::LimitShare,
                spent: 0.11,
                limit: Some(0.15),
                forecast: None,
            },
        ],
        chain: vec![
            Link {
                scope: "plan",
                unit: Unit::Usd,
                remaining: 3.0,
            },
            Link {
                scope: "spec",
                unit: Unit::Usd,
                remaining: 50.0,
            },
        ],
    };
    let lines = detail::lines_with_facts(core.model(), Some(&task), 0, Some(&facts));
    let text: Vec<&str> = lines
        .iter()
        .filter(|l| l.0 == "budget")
        .map(|l| l.1.as_str())
        .collect();
    assert!(
        text.iter().any(|l| l.contains("usd")
            && l.contains("$9 of $12")
            && l.contains("Set to p90 ($14)")),
        "{text:?}"
    );
    assert!(
        text.iter()
            .any(|l| l.contains("% wk") && l.contains("11 % of 15 %")),
        "{text:?}"
    );
    assert!(text.iter().any(|l| l.contains("Counts toward")), "{text:?}");
    assert!(
        text.iter().any(|l| l.contains("binding: plan, $3 left")),
        "{text:?}"
    );
    let pending = detail::lines_with_facts(core.model(), Some(&task), 0, None);
    assert!(
        pending
            .iter()
            .any(|l| l.0 == "budget" && l.1.contains("forecasting")),
        "{pending:?}"
    );
}

/// [D] `work-list/meter-shows-spend-and-limit`, the forecast words: a not-started row at 900 px or more shows
/// "fc $12–19 · 2–4 h" muted (the plan forecast of hub H12); narrower, or with no forecast, nothing.
#[test]
fn list_not_started_row_shows_the_forecast_words_when_wide() {
    use vegvisir::{Event, GraphFact};
    let mut core = list_world();
    core.step(Event::Graph(GraphFact::Forecast {
        item: "task:t1".into(),
        usd: Some((vegvisir::model::Num(12.0), vegvisir::model::Num(19.0))),
        hours: Some((vegvisir::model::Num(2.0), vegvisir::model::Num(4.0))),
    }));
    let v = list_view(core.model(), vegvisir::Show::All);
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new(), &[]);
    let r = list_row_of(&rows, "Count on the pill");
    assert!(r.text.contains("fc $12–19 · 2–4 h"), "{}", r.text);
    // a started task has no forecast words
    assert!(
        !list_row_of(&rows, "Anchor the card").text.contains("fc $"),
        "only a not-started row"
    );
    // narrower than 900 px: nothing
    let narrow: ViewEnv = serde_json::from_value(
        json!({"view": "m", "class": "gui-2", "epoch": 1, "display": "gui", "scale": 1.0, "cell": [8, 16], "width_px": 700}),
    )
    .expect("a narrow env");
    let (rows, _) = view_rows(core.model(), &v, &narrow, &Cols, 0, &BTreeSet::new(), &[]);
    assert!(
        !list_row_of(&rows, "Count on the pill")
            .text
            .contains("fc $"),
        "narrow: no forecast words"
    );
}
