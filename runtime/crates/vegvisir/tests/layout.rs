//! The layout's properties over generated workspaces (proptest; pure, [D]) and its golden layouts.
//!
//! Goldens live in `tests/golden/`. `UPDATE_VEGVISIR_GOLDEN=1 cargo test -p vegvisir --test layout golden` rewrites
//! them, and refuses a golden whose crossing count is above the one it replaces.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use proptest::prelude::*;
use vegvisir::layout::{Layout, layout};
use vegvisir::{
    CardFact, CardKind, Core, EdgeKind, Event, GraphFact, ItemId, Kind, MachineFact, Model,
    SessionFact, State, ViewState, fixture,
};

/// One generated agent: its plan (or none), subagents, changed files (indices into a shared pool), whether it needs
/// you, and its machine.
#[derive(Clone, Debug)]
struct Gen {
    plan: Option<u8>,
    subs: u8,
    files: Vec<u8>,
    needs_you: bool,
    machine: Option<u8>,
}

#[derive(Clone, Debug)]
struct World {
    plans: u8,
    machines: u8,
    agents: Vec<Gen>,
}

fn agent_events(i: usize, a: &Gen, plans: u8, machines: u8) -> Vec<Event> {
    let sid = format!("s{i:02}");
    let mut out = Vec::new();
    let plan = a.plan.filter(|&p| p < plans);
    if let Some(p) = plan {
        out.push(Event::Graph(GraphFact::Task {
            id: format!("t{i:02}"),
            plan: format!("p{p}"),
            title: format!("task {i}"),
            done: false,
        }));
    }
    let branch = format!("drgnx/b{i:02}");
    out.push(Event::Session(SessionFact {
        id: sid.clone(),
        name: format!("agent {i}"),
        model: "Opus".into(),
        state: State::Running,
        since: 0,
        seq: i as u64,
        task: plan.map(|_| format!("t{i:02}")),
        manager: None,
        branch: Some(branch.clone()),
        worktree: Some(format!("wt/{i}")),
        base: Some("c".into()),
        machine: a.machine.filter(|&m| m < machines).map(|m| format!("m{m}")),
        spend: None,
        context: None,
        progress: None,
    }));
    for j in 0..a.subs {
        out.push(Event::Session(SessionFact {
            id: format!("{sid}/x{j}"),
            name: format!("sub {j}"),
            model: String::new(),
            state: State::Running,
            since: 0,
            seq: 1000 + i as u64 * 10 + u64::from(j),
            task: None,
            manager: None,
            branch: None,
            worktree: None,
            base: None,
            machine: None,
            spend: None,
            context: None,
            progress: None,
        }));
    }
    if !a.files.is_empty() {
        out.push(Event::Changed {
            worktree: format!("wt/{i}"),
            base: "c".into(),
            files: a
                .files
                .iter()
                .map(|f| (format!("drgnx/f{f}.rs"), (1, 0)))
                .collect(),
        });
    }
    if a.needs_you {
        out.push(Event::Card(CardFact {
            id: format!("c{i}"),
            kind: CardKind::Question,
            about: vec![format!("agent:{sid}")],
            text: "?".into(),
            open: true,
        }));
    }
    out
}

fn world_events(w: &World) -> Vec<Event> {
    let mut out = Vec::new();
    for p in 0..w.plans {
        out.push(Event::Graph(GraphFact::Plan {
            id: format!("p{p}"),
            title: format!("plan {p}"),
            rank: u64::from(p),
            progress: None,
        }));
        out.push(Event::Graph(GraphFact::Ask {
            key: format!("{p}"),
            text: format!("ask {p}"),
        }));
        out.push(Event::Graph(GraphFact::Asked {
            ask: format!("{p}"),
            to: format!("plan:p{p}"),
        }));
    }
    if w.machines > 0 {
        out.push(Event::Machines(
            (0..w.machines)
                .map(|m| MachineFact {
                    name: format!("m{m}"),
                    slots: 4,
                    used: 1,
                    reported: false,
                })
                .collect(),
        ));
    }
    for (i, a) in w.agents.iter().enumerate() {
        out.extend(agent_events(i, a, w.plans, w.machines));
    }
    out
}

fn model_of(events: Vec<Event>) -> Model {
    let mut c = Core::new();
    for e in events {
        c.step(e);
    }
    c.model().clone()
}

fn gen_agent() -> impl Strategy<Value = Gen> {
    (
        proptest::option::weighted(0.85, 0u8..4),
        prop_oneof![6 => Just(0u8), 2 => Just(1u8), 1 => Just(2u8)],
        proptest::collection::vec(0u8..24, 0..4),
        proptest::bool::weighted(0.15),
        proptest::option::weighted(0.6, 0u8..3),
    )
        .prop_map(|(plan, subs, files, needs_you, machine)| Gen {
            plan,
            subs,
            files,
            needs_you,
            machine,
        })
}

fn gen_world() -> impl Strategy<Value = World> {
    (
        0u8..=4,
        0u8..=3,
        proptest::collection::vec(gen_agent(), 0..16),
    )
        .prop_map(|(plans, machines, agents)| World {
            plans,
            machines,
            agents,
        })
}

fn view(width: u32) -> ViewState {
    ViewState {
        width_units: width,
        ..ViewState::default()
    }
}

/// Each placed item's row: (layer, block line, sub).
/// A row's (layer, block line, sub).
type RowKey = (u8, u32, u32);

fn rows_of(l: &Layout) -> BTreeMap<ItemId, RowKey> {
    l.at.iter()
        .map(|(id, r)| {
            let layer = id.kind().expect("an item id").layer();
            let row = l
                .rows
                .iter()
                .find(|row| row.y == r.y && row.layer == layer)
                .unwrap_or_else(|| panic!("{id} sits in no row of its layer"));
            (id.clone(), (row.layer, row.block_line, row.sub))
        })
        .collect()
}

fn check_overlap(l: &Layout) -> Result<(), String> {
    let v: Vec<_> = l.at.iter().collect();
    for (i, (a, ra)) in v.iter().enumerate() {
        for (b, rb) in &v[i + 1..] {
            let x = ra.x < rb.x + rb.w && rb.x < ra.x + ra.w;
            let y = ra.y < rb.y + rb.h && rb.y < ra.y + ra.h;
            if x && y {
                return Err(format!("{a} {ra:?} overlaps {b} {rb:?}"));
            }
        }
    }
    Ok(())
}

fn check_layers(l: &Layout) -> Result<(), String> {
    rows_of(l);
    // rows go 1, 2, 3, then 4 and 5 by block line, then 6
    let group = |layer: u8| if layer == 5 { 4 } else { layer };
    for w in l.rows.windows(2) {
        if group(w[1].layer) < group(w[0].layer) || w[1].y <= w[0].y {
            return Err(format!("row {:?} after {:?}", w[1], w[0]));
        }
    }
    Ok(())
}

fn check_blocks(m: &Model, l: &Layout) -> Result<(), String> {
    let items = m.items();
    let rows = rows_of(l);
    let mut by_row: BTreeMap<RowKey, Vec<(u32, &ItemId)>> = BTreeMap::new();
    for (id, r) in &l.at {
        by_row.entry(rows[id]).or_default().push((r.x, id));
    }
    for ((layer, _, _), mut list) in by_row {
        if layer != 4 && layer != 5 {
            continue;
        }
        list.sort();
        let mut seen: BTreeSet<Option<ItemId>> = BTreeSet::new();
        let mut last: Option<Option<ItemId>> = None;
        for (_, id) in list {
            let b = items[id].block.clone();
            if last.as_ref() != Some(&b) {
                if !seen.insert(b.clone()) {
                    return Err(format!("block {b:?} is split in layer {layer}: {id}"));
                }
                last = Some(b);
            }
        }
    }
    // a subagent follows its parent or a sibling, in reading order
    let mut agents: Vec<((u32, u32), &ItemId)> =
        l.at.iter()
            .filter(|(id, _)| id.kind() == Some(Kind::Agent) || id.kind() == Some(Kind::Subagent))
            .map(|(id, r)| ((r.y, r.x), id))
            .collect();
    agents.sort();
    for w in agents.windows(2) {
        let (prev, cur) = (w[0].1, w[1].1);
        if let Some(p) = items[cur]
            .parent
            .as_ref()
            .filter(|_| items[cur].kind == Kind::Subagent)
            && l.at.contains_key(p)
            && prev != p
            && items[prev].parent.as_ref() != Some(p)
        {
            return Err(format!(
                "{cur} does not follow its parent {p}: after {prev}"
            ));
        }
    }
    Ok(())
}

fn check_width(l: &Layout) -> Result<(), String> {
    for (id, r) in &l.at {
        if r.x + r.w > l.width_units {
            return Err(format!("{id} {r:?} past {}", l.width_units));
        }
    }
    for lane in &l.lanes {
        if lane.x >= l.width_units {
            return Err(format!("lane {lane:?} past the width"));
        }
    }
    Ok(())
}

fn check_lanes(m: &Model, l: &Layout) -> Result<(), String> {
    let rows = rows_of(l);
    let row_index = |id: &ItemId| {
        let r = l.at[id];
        l.rows
            .iter()
            .position(|row| row.y == r.y && row.layer == rows[id].0)
            .expect("a row")
    };
    let mut lanes: BTreeMap<(&ItemId, &ItemId), BTreeSet<u32>> = BTreeMap::new();
    for lane in &l.lanes {
        lanes
            .entry((&lane.from, &lane.to))
            .or_default()
            .insert(lane.row);
    }
    for e in m.edges() {
        // an unfocused view draws no reads, read-versus-edit, runs-on or based-on edges
        if matches!(
            e.kind,
            EdgeKind::Reads | EdgeKind::ReadVsEdit | EdgeKind::RunsOn | EdgeKind::BasedOn
        ) || !l.at.contains_key(&e.from)
            || !l.at.contains_key(&e.to)
        {
            continue;
        }
        let (a, b) = (row_index(&e.from), row_index(&e.to));
        let (lo, hi) = (a.min(b), a.max(b));
        if hi <= lo + 1 {
            continue;
        }
        let want: BTreeSet<u32> = (lo as u32 + 1..hi as u32).collect();
        let got = lanes.get(&(&e.from, &e.to)).cloned().unwrap_or_default();
        let ported = l
            .ports
            .iter()
            .any(|p| p.target == e.to && p.parents.contains(&e.from));
        if got != want && !ported {
            return Err(format!(
                "{e:?} crosses rows {want:?} with lanes in {got:?} and no port"
            ));
        }
    }
    Ok(())
}

fn check_capacity(l: &Layout) -> Result<(), String> {
    let mut at: BTreeMap<(u32, u32), Vec<&vegvisir::layout::Lane>> = BTreeMap::new();
    for lane in &l.lanes {
        let row = &l.rows[lane.row as usize];
        // a lane sits in a gap, a unit clear of every card and chip of its row
        for (id, r) in &l.at {
            if r.y == row.y && lane.x + 1 > r.x && lane.x < r.x + r.w + 1 {
                return Err(format!("lane {lane:?} is not in a gap: {id} {r:?}"));
            }
        }
        at.entry((lane.row, lane.x)).or_default().push(lane);
    }
    // one slot, one bundle: lanes sharing a slot share their source or their target
    for (slot, list) in at {
        let first = list[0];
        if !list
            .iter()
            .all(|x| x.from == first.from || x.to == first.to)
        {
            return Err(format!("slot {slot:?} holds two bundles: {list:?}"));
        }
    }
    Ok(())
}

fn all_checks(m: &Model, l: &Layout) -> Result<(), String> {
    check_overlap(l)?;
    check_layers(l)?;
    check_blocks(m, l)?;
    check_width(l)?;
    check_lanes(m, l)?;
    check_capacity(l)
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]

    /// [D]
    #[test]
    fn no_two_cards_overlap(w in gen_world(), width in 120u32..600) {
        let m = model_of(world_events(&w));
        check_overlap(&layout(&m, &view(width), None)).map_err(TestCaseError::fail)?;
    }

    /// [D]
    #[test]
    fn layers_never_move(w in gen_world(), width in 120u32..600) {
        let m = model_of(world_events(&w));
        check_layers(&layout(&m, &view(width), None)).map_err(TestCaseError::fail)?;
    }

    /// [D]
    #[test]
    fn blocks_and_siblings_are_contiguous(w in gen_world(), width in 120u32..600) {
        let m = model_of(world_events(&w));
        check_blocks(&m, &layout(&m, &view(width), None)).map_err(TestCaseError::fail)?;
    }

    /// [D]
    #[test]
    fn same_input_same_output(w in gen_world(), width in 120u32..600) {
        let m = model_of(world_events(&w));
        let a = layout(&m, &view(width), None);
        prop_assert_eq!(&a, &layout(&m, &view(width), None));
        let b = layout(&m, &view(width), Some(&a));
        prop_assert_eq!(&b, &layout(&m, &view(width), Some(&a)));
    }

    /// [D] Adding an agent to a block, with the previous layout: the blocks before it keep their places, the blocks
    /// after it move only as a whole, and its block keeps its agents' order.
    #[test]
    fn adding_one_item_moves_only_its_block_row(w in gen_world(), extra in gen_agent(), width in 120u32..600) {
        let base = world_events(&w);
        let m0 = model_of(base.clone());
        let l0 = layout(&m0, &view(width), None);
        let mut more = base;
        more.extend(agent_events(w.agents.len(), &extra, w.plans, w.machines));
        let m1 = model_of(more);
        let l1 = layout(&m1, &view(width), Some(&l0));
        let items = m1.items();
        let new_block = items[&ItemId(format!("agent:s{:02}", w.agents.len()))].block.clone();
        let rank = |b: &Option<ItemId>| b.as_ref().map_or((u64::MAX, String::new()), |p| (items[p].order, p.0.clone()));
        let (r0, r1) = (rows_of(&l0), rows_of(&l1));
        let mut blocks: BTreeMap<Option<ItemId>, Vec<&ItemId>> = BTreeMap::new();
        for id in l0.at.keys() {
            if matches!(id.kind(), Some(Kind::Agent | Kind::Subagent | Kind::Branch)) {
                blocks.entry(items[id].block.clone()).or_default().push(id);
            }
        }
        for (b, ids) in &blocks {
            if rank(b) < rank(&new_block) {
                for id in ids {
                    prop_assert_eq!(l0.at[*id].x, l1.at[*id].x, "{} moved, in a block before the new one", id);
                    prop_assert_eq!(r0[*id], r1[*id], "{} changed rows", id);
                }
            } else if *b != new_block {
                let off = |l: &Layout, r: &BTreeMap<ItemId, RowKey>| {
                    let bx = ids.iter().map(|id| l.at[*id].x).min().unwrap_or(0);
                    let s0 = ids.iter().map(|id| r[*id].2).min().unwrap_or(0);
                    ids.iter().map(|id| (l.at[*id].x - bx, r[*id].0, r[*id].2 - s0)).collect::<Vec<_>>()
                };
                prop_assert_eq!(off(&l0, &r0), off(&l1, &r1), "block {:?} changed inside", b);
            } else {
                let order = |l: &Layout| {
                    let mut v: Vec<_> = ids.iter().filter(|id| id.kind() != Some(Kind::Branch)).map(|id| ((l.at[*id].y, l.at[*id].x), (*id).clone())).collect();
                    v.sort();
                    v.into_iter().map(|x| x.1).collect::<Vec<_>>()
                };
                prop_assert_eq!(order(&l0), order(&l1), "the block's agents changed order");
            }
        }
    }

    /// [D] Removing the agent again, with the layout that had it as the previous one, gives the first layout back.
    #[test]
    fn removing_it_restores_the_previous(w in gen_world(), extra in gen_agent(), width in 120u32..600) {
        let base = world_events(&w);
        let m0 = model_of(base.clone());
        let l0 = layout(&m0, &view(width), None);
        let mut more = base;
        more.extend(agent_events(w.agents.len(), &extra, w.plans, w.machines));
        let l1 = layout(&model_of(more), &view(width), Some(&l0));
        prop_assert_eq!(layout(&m0, &view(width), Some(&l1)), l0);
    }

    /// [D]
    #[test]
    fn width_is_respected(w in gen_world(), width in 120u32..600) {
        let m = model_of(world_events(&w));
        check_width(&layout(&m, &view(width), None)).map_err(TestCaseError::fail)?;
    }

    /// [D]
    #[test]
    fn every_long_edge_has_a_lane_or_a_port(w in gen_world(), width in 120u32..600) {
        let m = model_of(world_events(&w));
        check_lanes(&m, &layout(&m, &view(width), None)).map_err(TestCaseError::fail)?;
    }

    /// [D]
    #[test]
    fn no_gap_exceeds_its_lane_capacity(w in gen_world(), width in 120u32..600) {
        let m = model_of(world_events(&w));
        check_capacity(&layout(&m, &view(width), None)).map_err(TestCaseError::fail)?;
    }
}

fn golden_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden")
        .join(format!("{name}.json"))
}

/// The layout's counts, printed for the S3 record.
fn summary(name: &str, l: &Layout) -> String {
    let long: usize = l
        .lanes
        .iter()
        .map(|x| (&x.from, &x.to))
        .collect::<BTreeSet<_>>()
        .len();
    let ported: usize = l.ports.iter().map(|p| p.parents.len()).sum();
    let agents_rich = l
        .form
        .values()
        .filter(|f| **f == vegvisir::layout::Form::Rich)
        .count();
    format!(
        "{name}: width {} units, height {} units ({} px), rows {}, block lines {}, items placed {}, rich agents {} of {}, \
         lanes {} (edges with lanes {long}), ports {} (edges bundled {ported}), crossings {}, fits {}",
        l.width_units,
        l.height_units,
        l.height_units * 4,
        l.rows.len(),
        l.rows
            .iter()
            .filter(|r| r.layer == 4)
            .map(|r| r.block_line)
            .max()
            .map_or(0, |k| k + 1),
        l.at.len(),
        agents_rich,
        l.form.len(),
        l.lanes.len(),
        l.ports.len(),
        l.crossings,
        l.fits,
    )
}

fn golden(name: &str, events: Vec<Event>, width: u32) {
    let m = model_of(events);
    let l = layout(&m, &view(width), None);
    all_checks(&m, &l).unwrap_or_else(|e| panic!("{name}: {e}"));
    println!("{}", summary(name, &l));
    let path = golden_path(name);
    let text = serde_json::to_string_pretty(&l).expect("a layout serializes") + "\n";
    let old: Option<Layout> = std::fs::read_to_string(&path)
        .ok()
        .map(|t| serde_json::from_str(&t).expect("a golden layout"));
    if std::env::var_os("UPDATE_VEGVISIR_GOLDEN").is_some() {
        if let Some(old) = &old {
            assert!(
                l.crossings <= old.crossings,
                "{name}: {} crossings, above the golden's {}; not rewritten",
                l.crossings,
                old.crossings
            );
        }
        std::fs::create_dir_all(path.parent().expect("a directory")).expect("the golden directory");
        std::fs::write(&path, text).expect("the golden is written");
        return;
    }
    let old = old.unwrap_or_else(|| panic!("{name}: no golden at {}", path.display()));
    assert!(
        l.crossings <= old.crossings,
        "{name}: {} crossings, above the golden's {}",
        l.crossings,
        old.crossings
    );
    assert_eq!(
        serde_json::to_value(&l).unwrap(),
        serde_json::to_value(&old).unwrap(),
        "{name} differs from its golden"
    );
}

/// [D] The prototype's own data in a 1000 px tile.
#[test]
fn golden_prototype() {
    golden("prototype", fixture::prototype(), 226);
}

/// [D] The 30-agent fixture in a 1000 px tile: 1000 px less the 84 px layer labels and 12 px of padding.
#[test]
fn golden_thirty_at_1000() {
    golden("thirty-1000", fixture::thirty(), 226);
}

/// [D] The same fixture at 2400 px.
#[test]
fn golden_thirty_at_2400() {
    golden("thirty-2400", fixture::thirty(), 576);
}

/// Every edge kind a layout draws, in its bands.
fn drawn_kinds(l: &Layout) -> BTreeSet<EdgeKind> {
    l.bands
        .iter()
        .flat_map(|b| b.segs.iter().map(|s| s.kind))
        .collect()
}

fn focused(width: u32, on: &str) -> ViewState {
    let mut v = view(width);
    v.filters.focus = Some(ItemId(on.to_string()));
    v
}

/// [D] Runs-on edges are drawn on the focused chain only; the machine stays on the map with its load.
#[test]
fn runs_on_edges_only_on_the_focused_chain() {
    let w = World {
        plans: 1,
        machines: 1,
        agents: vec![
            Gen {
                plan: Some(0),
                subs: 0,
                files: vec![],
                needs_you: false,
                machine: Some(0),
            };
            2
        ],
    };
    let m = model_of(world_events(&w));
    assert!(m.edges().iter().any(|e| e.kind == EdgeKind::RunsOn));
    let plain = layout(&m, &view(226), None);
    assert!(plain.at.contains_key(&ItemId("machine:m0".into())));
    assert!(!drawn_kinds(&plain).contains(&EdgeKind::RunsOn));
    assert!(plain.lanes.iter().all(|x| x.kind != EdgeKind::RunsOn));
    let f = layout(&m, &focused(226, "agent:s00"), None);
    assert!(drawn_kinds(&f).contains(&EdgeKind::RunsOn));
}

/// [D] Based-on edges are drawn on the focused chain only; focusing a branch shows the branch it was cut from.
#[test]
fn based_on_edges_only_on_the_focused_chain() {
    let w = World {
        plans: 1,
        machines: 0,
        agents: vec![Gen {
            plan: Some(0),
            subs: 0,
            files: vec![],
            needs_you: false,
            machine: None,
        }],
    };
    let mut events = world_events(&w);
    events.push(Event::Refs(vec![vegvisir::RefFact {
        branch: "drgnx/b00".into(),
        based_on: Some("drgnx/main".into()),
        merged: false,
    }]));
    let m = model_of(events);
    let plain = layout(&m, &view(226), None);
    assert!(plain.at.contains_key(&ItemId("branch:drgnx/main".into())));
    assert!(!drawn_kinds(&plain).contains(&EdgeKind::BasedOn));
    let f = layout(&m, &focused(226, "branch:drgnx/b00"), None);
    assert!(
        f.at.contains_key(&ItemId("branch:drgnx/main".into())),
        "the base is shown with the focused branch"
    );
    assert!(drawn_kinds(&f).contains(&EdgeKind::BasedOn));
}

/// [D] A block goes compact rather than take a second sub-row; an agent that needs you stays rich.
#[test]
fn a_block_compacts_before_its_second_sub_row() {
    let agent = |needs_you| Gen {
        plan: Some(0),
        subs: 0,
        files: vec![],
        needs_you,
        machine: None,
    };
    // at 150 units two rich cards (58 + 3 + 58) fit a sub-row, three compact ones (3 × 42 + 2 × 3) too
    let w = World {
        plans: 1,
        machines: 0,
        agents: vec![agent(false), agent(false), agent(false)],
    };
    let m = model_of(world_events(&w));
    let l = layout(&m, &view(150), None);
    assert!(
        l.form
            .values()
            .all(|f| *f == vegvisir::layout::Form::Compact),
        "{:?}",
        l.form
    );
    assert_eq!(l.rows.iter().filter(|r| r.layer == 4).count(), 1);
    // two rich cards fit one sub-row: they stay rich
    let two = model_of(world_events(&World {
        agents: vec![agent(false), agent(false)],
        ..w.clone()
    }));
    let l = layout(&two, &view(150), None);
    assert!(
        l.form.values().all(|f| *f == vegvisir::layout::Form::Rich),
        "{:?}",
        l.form
    );
    // an agent that needs you stays rich in a compact block
    let m = model_of(world_events(&World {
        agents: vec![agent(true), agent(false), agent(false)],
        ..w
    }));
    let l = layout(&m, &view(150), None);
    assert_eq!(
        l.form[&ItemId("agent:s00".into())],
        vegvisir::layout::Form::Rich
    );
    assert_eq!(
        l.form[&ItemId("agent:s01".into())],
        vegvisir::layout::Form::Compact
    );
}

/// [D] The fit rule: at least 480 px and no lane overflow; the height never counts.
#[test]
fn fits_is_width_and_lanes_not_height() {
    let l = layout(&model_of(fixture::thirty()), &view(226), None);
    assert!(
        l.ports.is_empty() && l.fits,
        "the 30-agent fixture fits 1000 px: {:?}",
        l.ports
    );
    assert!(
        l.height_units * 4 > 900,
        "it is taller than the tile, and still fits"
    );
    assert!(!layout(&model_of(fixture::thirty()), &view(119), None).fits);
}
