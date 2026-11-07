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
        rows: true,
        version: 1,
        layout: Some(l),
        sent,
        co: Coalescer::default(),
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
            view_rows(core.model(), &v, &env(), &Cols, 0)
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

/// [A] A rows view gets its rows as patches for a full frame and a delta, and never a `work-map` event (a hidden one
/// gets no stale mark either: its editor hid it).
#[test]
fn rows_subscriber_gets_no_work_map_event() {
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
    map.stale(&mut g, &key);
    let sent = log(&map);
    assert!(!sent.contains(&"work-map"), "{sent:?}");
    assert_eq!(sent, ["rows", "rows"]);
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
    assert_eq!(log(&map), ["rows"]);
}
