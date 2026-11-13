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
/// the runner, and the agent's card carries the job.
#[test]
fn runner_job_runs_on_edge_points_at_the_runner() {
    let row: runstav::methods::exec::ExecRow = serde_json::from_value(json!({
        "id": "x1", "session": "s1", "kind": "other", "cwd": "/w", "name": "suite", "status": "running",
        "started": 100.0, "timebox_s": 360, "machine": "desktop"
    }))
    .expect("a job row");
    let job = job_fact(&row, vec!["token".into()]);
    assert_eq!(job.runner.as_deref(), Some("desktop"));
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
}

// ---- rows views: the map's rows as patches ------------------------------------------------------------------------

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
        ..ViewState::default()
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
            view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new())
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
    let d = model::doc(m, l, &v.sent);
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
    assert!(
        text[0].starts_with(&format!("{} · agent", agent.label)),
        "{text:?}"
    );
    for e in edges.iter().filter(|e| came(e) && e.from == agent.id) {
        let to = m.item(&e.to).expect("its target").label;
        assert!(
            text.iter()
                .any(|t| t.ends_with(&format!("\t{to} — came from this"))),
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
    let rows = detail::rows(&lines, 1.0);
    assert_eq!(rows.len(), lines.len());
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
        ..vegvisir::ViewState::default()
    };
    let l = vegvisir::layout::layout(m, &state, None);
    let sent: BTreeSet<ItemId> = l.at.keys().cloned().collect();
    let d = model::doc(m, &l, &sent);
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
    let d = model::doc(core.model(), v.layout.as_ref().expect("laid out"), &v.sent);
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
    let d = model::doc(core.model(), v.layout.as_ref().expect("laid out"), &v.sent);
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
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new());
    let at = |chip: &str| {
        rows[0]
            .text
            .find(chip)
            .unwrap_or_else(|| panic!("{chip} in {}", rows[0].text))
    };
    let chips = [
        at("gone  g1"),
        at("which?  g2"),
        at("agent 3 needs you  g3"),
        at("agent 4 needs you  g4"),
        at("huddle: both edit a.rs  g5"),
    ];
    assert!(chips.is_sorted(), "{}", rows[0].text);
    let d = model::doc(core.model(), v.layout.as_ref().expect("laid out"), &v.sent);
    assert_eq!(
        d.lists["needs-you"],
        vec!["c0", "agent:s2", "agent:s3", "agent:s4", "agent:s1"]
    );
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
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new());
    assert!(
        rows[0].text.contains("huddle: both edit a.rs"),
        "{}",
        rows[0].text
    );
    let d = model::doc(core.model(), v.layout.as_ref().expect("laid out"), &v.sent);
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
    let (rows, _) = view_rows(core.model(), &v, &env(), &Cols, 0, &BTreeSet::new());
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
        view_rows(core.model(), v, &env(), &Cols, 0, &BTreeSet::new())
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
        !view_rows(thirty.model(), &narrow, &env(), &Cols, 0, &BTreeSet::new())
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
    let rows = detail::rows(&detail::lines(m, Some(&agent), 0), 1.0);
    fn faces_of(r: &Row) -> Vec<&str> {
        r.runs.iter().map(|x| x.2.as_str()).collect()
    }
    assert!(
        faces_of(&rows[0]).contains(&"drgnx-ui-heading"),
        "{:?}",
        rows[0]
    );
    let key = |k: &str| -> Row {
        rows.iter()
            .find(|r| r.text.trim_start().starts_with(k) && !r.stops.is_empty())
            .unwrap_or_else(|| panic!("a `{k}` row with a key column in {rows:?}"))
            .clone()
    };
    for k in ["you", "spec", "plan", "task"] {
        let r = key(k);
        assert!(faces_of(&r).contains(&"drgnx-text-muted"), "{r:?}");
        assert!(faces_of(&r).contains(&"drgnx-accent"), "{r:?}");
    }
    let open = rows
        .iter()
        .find(|r| r.text.contains("Open"))
        .expect("the Open action");
    assert!(faces_of(open).contains(&"drgnx-button"), "{open:?}");
    assert!(faces_of(open).contains(&"drgnx-keycap"), "{open:?}");
    for r in &rows {
        assert!(faces_of(r).contains(&"drgnx-work-card"), "{r:?}");
    }
}
