//! The layout (design §12.3): stable layers, agents and branches in one block per plan, lanes with a capacity, ports.
//!
//! Units are 4 px (the look's grid), never font metrics: every card and chip has a fixed width per kind and form,
//! and the editor truncates labels to it. `width_units` is the drawing width, without the layer labels' margin.
//!
//! 1. The layer is the kind's.
//! 2. Agents and branches sit in one block per plan, in plan order, the "No plan" block last; a block wraps into
//!    sub-rows inside itself (an agent sub-row, then its branches' sub-row, alternating), and whole blocks wrap into
//!    block lines. A block's agents go compact before it needs a second sub-row, except those that need you or are
//!    on the focused chain; subagents are always compact and follow their parent.
//! 3. Inside a block, agents keep the previous layout's order (new ones at the end), else start order. Other rows are
//!    ordered by their items' targets, then adjacent swaps that cut crossings by more than a stability penalty.
//! 4. A plan's target is its block's centre; a spec's, an ask's, a file's or a machine's is the mean centre of what it
//!    links to. An item keeps its previous target while it stays within the hysteresis of the new one, so a new card
//!    does not shift the others. Overlaps are resolved left to right with the look's gaps.
//! 5. An edge longer than one row takes a lane in each row it crosses, in a free slot of the nearest gap: a gap of
//!    `g` units holds `g - 1` lanes, `floor((gap - 4 px) / 4 px)`. Edges from one source (a plan to its agents) or to
//!    one target (agents to a machine, branches to a file or to their base) share a lane. The row's right end is a gap like the others,
//!    so a full row's lanes widen into its slack; a row with no free slot left bundles the edge into a port on its
//!    target.
//! 6. Bands hold the curves between consecutive rows: from a card's bottom centre to a lane, lane to lane, a lane to
//!    a card's top centre; same-row arcs in the band above the row. "Runs on" and "based on" edges are drawn on the
//!    focused chain only (machines carry their load, branches their base, the side panel says both).
//! 7. The map fits at 480 px (120 units) or wider with no lane overflow (no port) and every card inside the width;
//!    otherwise the editor shows the outline. The height is not part of the rule: the map scrolls vertically, its
//!    needs-you strip stays pinned, and the selection scrolls into view.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::model::{Model, Sym};
use crate::{Density, EdgeKind, ItemId, Kind, ViewState};

/// The narrowest drawing width the map is drawn at (480 px); below it, the outline form.
pub const MIN_WIDTH_UNITS: u32 = 120;
/// How far (units) an item's new target may move before it leaves its previous one.
const HYSTERESIS: u32 = 32;
/// An adjacent swap must cut more crossings than this.
const SWAP_PENALTY: i64 = 1;
const SWEEPS: usize = 4;
/// A collapsed layer's thin row.
const COLLAPSED_H: u32 = 5;

/// A rectangle in units: `y` from the map's top.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

/// An agent card's form.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Form {
    Rich,
    Compact,
}

/// One row of the map: a layer's line (`block_line` counts wrapped lines, and block lines for layers 4 and 5),
/// `sub` the sub-row inside a block line.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub layer: u8,
    pub block_line: u32,
    pub sub: u32,
    pub y: u32,
    pub height_units: u32,
    /// A collapsed layer's thin row.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub collapsed: bool,
}

/// An edge's pass through a row it crosses: a 2 px segment at `x`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Lane {
    pub row: u32,
    pub x: u32,
    pub from: ItemId,
    pub to: ItemId,
    pub kind: EdgeKind,
}

/// Edges bundled for want of lanes: a port marker ("↑ N") on the target's top edge; the side panel names the parents.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Port {
    pub target: ItemId,
    pub parents: Vec<ItemId>,
}

/// One curve in a band: from `x0` on the band's top to `x1` on its bottom, or an arc between two cards of the row
/// below (`arc`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Seg {
    pub from: ItemId,
    pub to: ItemId,
    pub kind: EdgeKind,
    pub x0: u32,
    pub x1: u32,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub arc: bool,
}

/// The band above row `row`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Band {
    pub row: u32,
    pub y: u32,
    pub height_units: u32,
    pub segs: Vec<Seg>,
}

/// A view's layout.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Layout {
    pub rows: Vec<Row>,
    pub at: BTreeMap<ItemId, Rect>,
    pub form: BTreeMap<ItemId, Form>,
    pub lanes: Vec<Lane>,
    pub ports: Vec<Port>,
    pub bands: Vec<Band>,
    pub fits: bool,
    pub crossings: u32,
    pub width_units: u32,
    pub height_units: u32,
    /// Each placed item's target x, before it is pulled inside the width: the next layout's hysteresis.
    #[serde(skip)]
    want: BTreeMap<ItemId, u32>,
}

/// Sizes per density, in units (comfortable: the look §14.1 on the 4 px grid; its 19 px card lines round to 20 px).
#[derive(Clone, Copy, Debug)]
pub(crate) struct Metrics {
    rich: (u32, u32),
    compact: (u32, u32),
    chip_h: u32,
    gap: u32,
    band: u32,
    /// The band between an agent sub-row and its own branches' sub-row.
    inner_band: u32,
    block_gap: u32,
    /// ask, spec, plan, branch, file, machine
    chips: [u32; 6],
}

impl Metrics {
    pub(crate) fn of(d: Density) -> Metrics {
        match d {
            Density::Compact => Metrics {
                rich: (54, 25),
                compact: (40, 10),
                chip_h: 6,
                gap: 2,
                band: 6,
                inner_band: 2,
                block_gap: 4,
                chips: [44, 40, 40, 36, 32, 28],
            },
            Density::Comfortable => Metrics {
                rich: (58, 25),
                compact: (42, 10),
                chip_h: 7,
                gap: 3,
                band: 8,
                inner_band: 3,
                block_gap: 6,
                chips: [48, 44, 44, 40, 36, 32],
            },
            Density::Roomy => Metrics {
                rich: (62, 30),
                compact: (46, 12),
                chip_h: 8,
                gap: 4,
                band: 10,
                inner_band: 4,
                block_gap: 8,
                chips: [52, 48, 48, 44, 40, 36],
            },
        }
    }

    fn chip_w(&self, k: Kind) -> u32 {
        match k {
            Kind::Ask => self.chips[0],
            Kind::Spec => self.chips[1],
            Kind::Plan => self.chips[2],
            Kind::Branch => self.chips[3],
            Kind::File => self.chips[4],
            Kind::Machine => self.chips[5],
            Kind::Agent | Kind::Subagent => self.compact.0,
        }
    }

    fn card(&self, f: Form) -> (u32, u32) {
        match f {
            Form::Rich => self.rich,
            Form::Compact => self.compact,
        }
    }
}

/// A row being built: its items with x (set once known), widths and heights.
struct RowB {
    layer: u8,
    line: u32,
    sub: u32,
    collapsed: bool,
    items: Vec<(Sym, u32, u32, u32)>,
}

/// One block: a plan's agents in sub-rows, each followed by its branches' sub-row; x relative to the block.
struct Block {
    agents: Vec<Vec<(Sym, u32, u32, u32)>>,
    branches: Vec<Vec<(Sym, u32, u32)>>,
    width: u32,
}

/// A live arrival or departure without a relayout (design §11.3 step 5): `prev` with each of `gone` taken out (its
/// place stays empty) and each of `new` at a free place at the end of the last row of its layer, an agent compact, any
/// other item as its chip. When that row has no room inside the width, or the layer has no row, the item gets a row of
/// its own at the bottom. Nothing else moves; the next layout puts the arrivals where they belong. Items of a
/// collapsed layer, and items `prev` already places, are left as they are.
pub fn place_live(v: &ViewState, prev: &Layout, new: &[ItemId], gone: &[ItemId]) -> Layout {
    let mx = Metrics::of(v.density);
    let mut out = prev.clone();
    for id in gone {
        out.at.remove(id);
        out.form.remove(id);
        out.want.remove(id);
    }
    for id in new {
        let Some(kind) = id.kind() else { continue };
        let layer = kind.layer();
        if out.at.contains_key(id) || v.collapsed.contains(&layer) {
            continue;
        }
        let agent = matches!(kind, Kind::Agent | Kind::Subagent);
        let (w, h) = if agent {
            mx.compact
        } else {
            (mx.chip_w(kind), mx.chip_h)
        };
        let last = out
            .rows
            .iter()
            .filter(|r| r.layer == layer && !r.collapsed)
            .max_by_key(|r| r.y)
            .map(|r| (r.y, r.height_units));
        let end = |y: u32| {
            out.at
                .values()
                .filter(|r| r.y == y)
                .map(|r| r.x + r.w + mx.gap)
                .max()
                .unwrap_or(0)
        };
        let room = last.and_then(|(y, rh)| {
            let x = end(y);
            (x + w <= v.width_units && h <= rh).then_some((y, x))
        });
        let (x, y) = match room {
            Some((y, x)) => (x, y),
            None => {
                let y = out.height_units + mx.band;
                out.rows.push(Row {
                    layer,
                    block_line: 0,
                    sub: 0,
                    y,
                    height_units: h,
                    collapsed: false,
                });
                out.height_units = y + h;
                (0, y)
            }
        };
        out.at.insert(id.clone(), Rect { x, y, w, h });
        if agent {
            out.form.insert(id.clone(), Form::Compact);
        }
    }
    out
}

/// Lays a view out. `prev` (the view's previous layout) seeds the order inside blocks and the targets.
pub fn layout(m: &Model, v: &ViewState, prev: Option<&Layout>) -> Layout {
    let mx = Metrics::of(v.density);
    let width = v.width_units;
    let d = &m.d;
    let names = &m.names;
    let kind = |y: Sym| d.items[&y].kind;
    let collapsed = |y: Sym| v.collapsed.contains(&kind(y).layer());

    // what the view shows
    let focus = v
        .filters
        .focus
        .as_ref()
        .and_then(|f| names.get(f.as_str()))
        .filter(|y| d.items.contains_key(y));
    let mut vis: BTreeSet<Sym> = d
        .items
        .iter()
        .filter(|(_, it)| it.live || v.filters.finished)
        .map(|(&y, _)| y)
        .collect();
    let mut chain = BTreeSet::new();
    if let Some(f) = focus {
        let (up, down) = m.chain_syms(f);
        chain.extend(up);
        chain.extend(down);
        chain.insert(f);
        // the bases the chain's branches were cut from, for its "based on" edges
        for &(a, b, k) in &d.edges {
            if k == EdgeKind::BasedOn && chain.contains(&a) {
                chain.insert(b);
            }
        }
        vis.retain(|y| chain.contains(y));
    }
    if v.filters.overlaps {
        let flagged: Vec<Sym> = vis
            .iter()
            .copied()
            .filter(|&y| {
                d.items[&y].warn && matches!(kind(y), Kind::Agent | Kind::Subagent | Kind::Branch)
            })
            .collect();
        let mut keep: BTreeSet<Sym> = flagged.iter().copied().collect();
        for &y in &flagged {
            keep.extend(m.chain_syms(y).0);
        }
        for &(a, b, k) in &d.edges {
            if keep.contains(&a) && matches!(k, EdgeKind::Edits | EdgeKind::RunsOn) {
                keep.insert(b);
            }
        }
        vis.retain(|y| keep.contains(y));
    } else if focus.is_none() {
        // files are counts on their branch; nodes only for a shared file
        vis.retain(|&y| kind(y) != Kind::File || d.items[&y].shared);
    }

    // the edges drawn: reads for the focused chain only, read-versus-edit in the overlaps filter only
    let shown_kind = |k: EdgeKind| match k {
        EdgeKind::Reads => focus.is_some(),
        EdgeKind::ReadVsEdit => v.filters.overlaps,
        // slots and bases: the machine's chip and the branch's caption say them; the edge only on the focused chain
        EdgeKind::RunsOn | EdgeKind::BasedOn => focus.is_some(),
        _ => true,
    };
    let mut drawn: Vec<(Sym, Sym, EdgeKind)> = d
        .edges
        .iter()
        .copied()
        .filter(|&(a, b, k)| vis.contains(&a) && vis.contains(&b) && shown_kind(k))
        .collect();
    if !v.collapsed.is_empty() {
        drawn = contract(&drawn, &collapsed);
    }
    let placed = |y: Sym| vis.contains(&y) && !collapsed(y);

    // blocks: the agents of each plan, in plan order, and their branches
    let protected = |y: Sym| d.items[&y].needs_you || chain.contains(&y);
    let prev_rank: BTreeMap<&ItemId, (u32, u32)> = prev
        .map(|p| p.at.iter().map(|(id, r)| (id, (r.y, r.x))).collect())
        .unwrap_or_default();
    let team = |y: Sym| {
        let id = names.id(y);
        (
            prev_rank.get(&id).copied().unwrap_or((u32::MAX, u32::MAX)),
            d.items[&y].order,
            names.name(y).to_string(),
        )
    };
    let mut by_block: BTreeMap<(u64, String), (Vec<Sym>, Vec<Sym>)> = BTreeMap::new();
    let block_key = |b: Option<Sym>| match b {
        Some(p) => (
            d.items.get(&p).map_or(u64::MAX - 1, |it| it.order),
            names.name(p).to_string(),
        ),
        None => (u64::MAX, String::new()),
    };
    let agents_vis: Vec<Sym> = vis
        .iter()
        .copied()
        .filter(|&y| matches!(kind(y), Kind::Agent | Kind::Subagent))
        .collect();
    let agent_set: BTreeSet<Sym> = agents_vis.iter().copied().collect();
    for &a in &agents_vis {
        let it = &d.items[&a];
        // a subagent whose parent is shown follows it
        if it.kind == Kind::Subagent && it.parent.is_some_and(|p| agent_set.contains(&p)) {
            continue;
        }
        by_block.entry(block_key(it.block)).or_default().0.push(a);
    }
    for &b in vis.iter().filter(|&&y| kind(y) == Kind::Branch) {
        let it = &d.items[&b];
        if it.parent.is_none_or(|o| !agent_set.contains(&o)) {
            by_block.entry(block_key(it.block)).or_default().1.push(b);
        }
    }
    let mut subs: BTreeMap<Sym, Vec<Sym>> = BTreeMap::new();
    for &a in &agents_vis {
        let it = &d.items[&a];
        if let (Kind::Subagent, Some(p)) = (it.kind, it.parent)
            && agent_set.contains(&p)
        {
            subs.entry(p).or_default().push(a);
        }
    }
    for list in subs.values_mut() {
        list.sort_by_cached_key(|&y| team(y));
    }
    let mut branch_of: BTreeMap<Sym, Sym> = BTreeMap::new();
    for &b in vis.iter().filter(|&&y| kind(y) == Kind::Branch) {
        if let Some(o) = d.items[&b].parent.filter(|o| agent_set.contains(o)) {
            branch_of.insert(o, b);
        }
    }

    let mut form: BTreeMap<Sym, Form> = BTreeMap::new();
    let mut blocks: Vec<(Option<Sym>, Block)> = Vec::new();
    for ((_, plan_name), (mut tops, mut lone)) in by_block {
        tops.sort_by_cached_key(|&y| team(y));
        lone.sort_by_cached_key(|&y| team(y));
        let mut seq: Vec<Sym> = Vec::new();
        for t in tops {
            seq.push(t);
            seq.extend(subs.get(&t).into_iter().flatten());
        }
        let plan = if plan_name.is_empty() {
            None
        } else {
            names.get(&plan_name)
        };
        let block = pack_block(
            &seq, &lone, &branch_of, &mx, width, v, &kind, &protected, &mut form,
        );
        blocks.push((plan, block));
    }

    // block lines
    let mut lines: Vec<Vec<(usize, u32)>> = Vec::new();
    let mut cur = 0u32;
    for (i, (_, b)) in blocks.iter().enumerate() {
        if lines.is_empty() || (cur > 0 && cur + mx.block_gap + b.width > width) {
            lines.push(Vec::new());
            cur = 0;
        }
        let x = if cur == 0 { 0 } else { cur + mx.block_gap };
        lines.last_mut().expect("a line").push((i, x));
        cur = x + b.width;
    }

    // rows of layers 4 and 5, with absolute x
    let mut block_rows: Vec<RowB> = Vec::new();
    let mut block_x: BTreeMap<Option<Sym>, (u32, u32)> = BTreeMap::new();
    for (k, line) in lines.iter().enumerate() {
        let k = k as u32;
        let depth = line
            .iter()
            .map(|&(i, _)| blocks[i].1.agents.len().max(blocks[i].1.branches.len()))
            .max()
            .unwrap_or(0);
        for s in 0..depth {
            for (layer, is_agents) in [(4u8, true), (5u8, false)] {
                let mut items = Vec::new();
                for &(i, bx) in line {
                    let b = &blocks[i].1;
                    if is_agents {
                        items.extend(
                            b.agents
                                .get(s)
                                .into_iter()
                                .flatten()
                                .map(|&(y, x, w, h)| (y, bx + x, w, h)),
                        );
                    } else {
                        items.extend(
                            b.branches
                                .get(s)
                                .into_iter()
                                .flatten()
                                .map(|&(y, x, w)| (y, bx + x, w, mx.chip_h)),
                        );
                    }
                }
                if !items.is_empty() {
                    block_rows.push(RowB {
                        layer,
                        line: k,
                        sub: s as u32,
                        collapsed: false,
                        items,
                    });
                }
            }
        }
        for &(i, bx) in line {
            block_x.insert(blocks[i].0, (bx, blocks[i].1.width));
        }
    }

    // x so far: the blocks' items
    let mut xs: BTreeMap<Sym, (u32, u32)> = BTreeMap::new();
    for r in &block_rows {
        for &(y, x, w, _) in &r.items {
            xs.insert(y, (x, w));
        }
    }
    let prev_want: BTreeMap<&ItemId, u32> = prev
        .map(|p| p.want.iter().map(|(k, &t)| (k, t)).collect())
        .unwrap_or_default();
    let mut want_out: BTreeMap<Sym, u32> = BTreeMap::new();

    // layer 3: plans in plan order, each over its block
    let mut plans: Vec<Sym> = vis
        .iter()
        .copied()
        .filter(|&y| kind(y) == Kind::Plan && placed(y))
        .collect();
    plans.sort_by_cached_key(|&y| (d.items[&y].order, names.name(y).to_string()));
    let plan_targets: Vec<(Sym, Option<u32>)> = plans
        .iter()
        .map(|&p| {
            let w = mx.chip_w(Kind::Plan);
            let t = block_x
                .get(&Some(p))
                .map(|&(bx, bw)| (bx + bw / 2).saturating_sub(w / 2));
            (p, t)
        })
        .collect();
    let upper3 = place_chips(
        &plan_targets,
        false,
        Kind::Plan,
        &mx,
        width,
        &drawn,
        &xs,
        names,
        &prev_want,
        &mut want_out,
    );

    // layers 2 and 1, then 6: targets from what they link to
    let mut upper_rows: Vec<RowB> = Vec::new();
    let mut place_layer =
        |layer: u8, kinds: &[Kind], xs: &mut BTreeMap<Sym, (u32, u32)>, out: &mut Vec<RowB>| {
            let items: Vec<Sym> = vis
                .iter()
                .copied()
                .filter(|&y| kinds.contains(&kind(y)) && placed(y))
                .collect();
            let targets: Vec<(Sym, Option<u32>)> = items
                .iter()
                .map(|&y| {
                    let w = mx.chip_w(kind(y));
                    (y, bary(y, &drawn, xs).map(|c| c.saturating_sub(w / 2)))
                })
                .collect();
            let lines = place_chips(
                &targets,
                true,
                kinds[0],
                &mx,
                width,
                &drawn,
                xs,
                names,
                &prev_want,
                &mut want_out,
            );
            for (k, line) in lines.into_iter().enumerate() {
                for &(y, x, w) in &line {
                    xs.insert(y, (x, w));
                }
                out.push(RowB {
                    layer,
                    line: k as u32,
                    sub: 0,
                    collapsed: false,
                    items: line
                        .into_iter()
                        .map(|(y, x, w)| (y, x, w, mx.chip_h))
                        .collect(),
                });
            }
        };
    let mut rows3: Vec<RowB> = Vec::new();
    for (k, line) in upper3.into_iter().enumerate() {
        for &(y, x, w) in &line {
            xs.insert(y, (x, w));
        }
        rows3.push(RowB {
            layer: 3,
            line: k as u32,
            sub: 0,
            collapsed: false,
            items: line
                .into_iter()
                .map(|(y, x, w)| (y, x, w, mx.chip_h))
                .collect(),
        });
    }
    let mut rows2 = Vec::new();
    place_layer(2, &[Kind::Spec], &mut xs, &mut rows2);
    let mut rows1 = Vec::new();
    place_layer(1, &[Kind::Ask], &mut xs, &mut rows1);
    let mut rows6 = Vec::new();
    place_layer(6, &[Kind::File, Kind::Machine], &mut xs, &mut rows6);
    upper_rows.extend(rows1);
    upper_rows.extend(rows2);
    upper_rows.extend(rows3);

    // all rows, top to bottom; a collapsed layer is one thin row in its place
    let thin = |layer: u8| RowB {
        layer,
        line: 0,
        sub: 0,
        collapsed: true,
        items: Vec::new(),
    };
    let mut all: Vec<RowB> = Vec::new();
    for layer in 1..=3u8 {
        if v.collapsed.contains(&layer) {
            all.push(thin(layer));
        }
        all.extend(upper_rows.extract_if(.., |r| r.layer == layer));
    }
    if v.collapsed.contains(&4) {
        all.push(thin(4));
    }
    all.extend(block_rows);
    if v.collapsed.contains(&5) {
        all.push(thin(5));
    }
    if v.collapsed.contains(&6) {
        all.push(thin(6));
    }
    all.extend(rows6);

    finish(m, v, &mx, all, &drawn, &form, want_out)
}

/// Packs one block: its agents (in order, each followed by its subagents) into sub-rows of at most `width`, each
/// agent's branch under it, then the branches with no shown agent.
#[allow(clippy::too_many_arguments)]
fn pack_block(
    seq: &[Sym],
    lone: &[Sym],
    branch_of: &BTreeMap<Sym, Sym>,
    mx: &Metrics,
    width: u32,
    v: &ViewState,
    kind: &impl Fn(Sym) -> Kind,
    protected: &impl Fn(Sym) -> bool,
    form: &mut BTreeMap<Sym, Form>,
) -> Block {
    let agents_shown = !v.collapsed.contains(&4);
    let branches_shown = !v.collapsed.contains(&5);
    let pack = |forms: &BTreeMap<Sym, Form>| {
        let mut rows: Vec<Vec<(Sym, u32, u32, u32)>> = Vec::new();
        let mut x = 0u32;
        for &a in seq {
            let (w, h) = mx.card(forms[&a]);
            if rows.is_empty() || (x > 0 && x + mx.gap + w > width) {
                rows.push(Vec::new());
                x = 0;
            }
            let at = if x == 0 { 0 } else { x + mx.gap };
            rows.last_mut().expect("a row").push((a, at, w, h));
            x = at + w;
        }
        rows
    };
    let mut forms: BTreeMap<Sym, Form> = seq
        .iter()
        .map(|&a| {
            (
                a,
                if kind(a) == Kind::Subagent {
                    Form::Compact
                } else {
                    Form::Rich
                },
            )
        })
        .collect();
    let mut agents = if agents_shown {
        pack(&forms)
    } else {
        Vec::new()
    };
    // compact before a second sub-row
    if agents.len() > 1 {
        for (&a, f) in forms.iter_mut() {
            if !protected(a) {
                *f = Form::Compact;
            }
        }
        agents = pack(&forms);
    }
    let bw = mx.chip_w(Kind::Branch);
    let mut branches: Vec<Vec<(Sym, u32, u32)>> = Vec::new();
    if branches_shown {
        if agents_shown {
            for row in &agents {
                branches.push(
                    row.iter()
                        .filter_map(|&(a, x, w, _)| {
                            branch_of
                                .get(&a)
                                .map(|&b| (b, x + w.saturating_sub(bw) / 2, bw))
                        })
                        .collect(),
                );
            }
        }
        // with the agents collapsed, the branches are packed as chips in their agents' order
        let mut rest: Vec<Sym> = if agents_shown {
            Vec::new()
        } else {
            seq.iter()
                .filter_map(|a| branch_of.get(a).copied())
                .collect()
        };
        rest.extend(lone);
        for b in rest {
            let end = branches
                .last()
                .and_then(|r| r.last())
                .map(|&(_, x, w)| x + w);
            match end {
                Some(e) if e + mx.gap + bw <= width => {
                    branches
                        .last_mut()
                        .expect("a row")
                        .push((b, e + mx.gap, bw))
                }
                _ => branches.push(vec![(b, 0, bw)]),
            }
        }
        while branches.last().is_some_and(|r| r.is_empty()) {
            branches.pop();
        }
    }
    let width_of = agents
        .iter()
        .flat_map(|r| r.last().map(|&(_, x, w, _)| x + w))
        .chain(
            branches
                .iter()
                .flat_map(|r| r.last().map(|&(_, x, w)| x + w)),
        )
        .max()
        .unwrap_or(0);
    if agents_shown {
        form.extend(forms);
    }
    Block {
        agents,
        branches,
        width: width_of,
    }
}

/// The mean centre of what `y` links to that is already placed.
fn bary(y: Sym, drawn: &[(Sym, Sym, EdgeKind)], xs: &BTreeMap<Sym, (u32, u32)>) -> Option<u32> {
    let mut sum = 0u64;
    let mut n = 0u64;
    for &(a, b, _) in drawn {
        let other = if a == y {
            b
        } else if b == y {
            a
        } else {
            continue;
        };
        if let Some(&(x, w)) = xs.get(&other) {
            sum += u64::from(x + w / 2);
            n += 1;
        }
    }
    (n > 0).then(|| u32::try_from(sum / n).unwrap_or(u32::MAX))
}

/// Places a layer's chips: each at its target (kept from the previous layout within the hysteresis), ordered by
/// target (`sweep`: then adjacent swaps against crossings), wrapped into lines, overlaps resolved left to right.
#[allow(clippy::too_many_arguments)]
fn place_chips(
    targets: &[(Sym, Option<u32>)],
    sweep: bool,
    k: Kind,
    mx: &Metrics,
    width: u32,
    drawn: &[(Sym, Sym, EdgeKind)],
    xs: &BTreeMap<Sym, (u32, u32)>,
    names: &crate::model::Names,
    prev_want: &BTreeMap<&ItemId, u32>,
    want_out: &mut BTreeMap<Sym, u32>,
) -> Vec<Vec<(Sym, u32, u32)>> {
    let mut items: Vec<(Sym, Option<u32>, u32, String)> = targets
        .iter()
        .map(|&(y, t)| {
            let w = mx.chip_w(Kind::of(names.name(y)).unwrap_or(k));
            let id = names.id(y);
            // the previous target holds while the new one stays near it; an item linked to nothing goes last
            let t = match (t, prev_want.get(&id)) {
                (Some(t), Some(&p)) if t.abs_diff(p) <= HYSTERESIS => Some(p),
                (t, _) => t,
            };
            // kept before it is pulled inside the width: a target held against the edge would otherwise come back
            // nearer to its old place than it went, and stay
            if let Some(t) = t {
                want_out.insert(y, t);
            }
            (
                y,
                t.map(|t| t.min(width.saturating_sub(w))),
                w,
                names.name(y).to_string(),
            )
        })
        .collect();
    if sweep {
        // targetless items go last, by id
        items.sort_by(|a, b| (a.1.is_none(), a.1, &a.3).cmp(&(b.1.is_none(), b.1, &b.3)));
        let nbrs: Vec<Vec<u32>> = items
            .iter()
            .map(|it| {
                drawn
                    .iter()
                    .filter_map(|&(a, b, _)| {
                        if a == it.0 {
                            Some(b)
                        } else if b == it.0 {
                            Some(a)
                        } else {
                            None
                        }
                    })
                    .filter_map(|o| xs.get(&o).map(|&(x, w)| x + w / 2))
                    .collect()
            })
            .collect();
        let mut order: Vec<usize> = (0..items.len()).collect();
        for _ in 0..SWEEPS {
            let mut changed = false;
            for i in 0..order.len().saturating_sub(1) {
                let (p, q) = (order[i], order[i + 1]);
                let gain =
                    crossings_between(&nbrs[p], &nbrs[q]) - crossings_between(&nbrs[q], &nbrs[p]);
                if gain > SWAP_PENALTY {
                    order.swap(i, i + 1);
                    changed = true;
                }
            }
            if !changed {
                break;
            }
        }
        items = order.into_iter().map(|i| items[i].clone()).collect();
    }
    // wrap into lines, then resolve each
    let mut lines: Vec<Vec<(Sym, Option<u32>, u32)>> = Vec::new();
    let mut used = 0u32;
    for (y, t, w, _) in items {
        if lines.is_empty() || (used > 0 && used + mx.gap + w > width) {
            lines.push(Vec::new());
            used = 0;
        }
        used += if used == 0 { w } else { mx.gap + w };
        lines.last_mut().expect("a line").push((y, t, w));
    }
    lines
        .into_iter()
        .map(|line| resolve(&line, mx.gap, width))
        .collect()
}

/// Crossings between the edges of an item left of another: pairs whose other ends are in the opposite order.
fn crossings_between(left: &[u32], right: &[u32]) -> i64 {
    let mut n = 0i64;
    for &l in left {
        for &r in right {
            if l > r {
                n += 1;
            }
        }
    }
    n
}

/// x for a line of items in their order: each at its target or just right of the one before, then pulled back from
/// the right edge. Targetless items follow the one before.
fn resolve(line: &[(Sym, Option<u32>, u32)], gap: u32, width: u32) -> Vec<(Sym, u32, u32)> {
    let mut out: Vec<(Sym, u32, u32)> = Vec::with_capacity(line.len());
    let mut end: Option<u32> = None;
    for &(y, t, w) in line {
        let min = end.map_or(0, |e| e + gap);
        let x = t.map_or(min, |t| t.max(min));
        out.push((y, x, w));
        end = Some(x + w);
    }
    let mut limit = width;
    for e in out.iter_mut().rev() {
        if e.1 + e.2 > limit {
            e.1 = limit.saturating_sub(e.2);
        }
        limit = e.1.saturating_sub(gap);
    }
    out
}

/// Edges through collapsed layers become edges between the shown items on either side.
fn contract(
    drawn: &[(Sym, Sym, EdgeKind)],
    collapsed: &impl Fn(Sym) -> bool,
) -> Vec<(Sym, Sym, EdgeKind)> {
    let mut out: BTreeSet<(Sym, Sym, EdgeKind)> = BTreeSet::new();
    let mut fwd: BTreeMap<Sym, Vec<(Sym, EdgeKind)>> = BTreeMap::new();
    for &(a, b, k) in drawn {
        fwd.entry(a).or_default().push((b, k));
    }
    for &(a, b, k) in drawn {
        if collapsed(a) {
            continue;
        }
        if !collapsed(b) {
            out.insert((a, b, k));
            continue;
        }
        // walk through the collapsed items to the shown ones
        let mut seen = BTreeSet::new();
        let mut todo = vec![b];
        while let Some(c) = todo.pop() {
            for &(n, nk) in fwd.get(&c).into_iter().flatten() {
                if !nk.on_chain() || !seen.insert(n) {
                    continue;
                }
                if collapsed(n) {
                    todo.push(n);
                } else if n != a {
                    out.insert((a, n, nk));
                }
            }
        }
    }
    out.into_iter().collect()
}

/// A gap of a row: the free stretch `[start, end)` between two items (or an edge of the map).
struct Gap {
    start: u32,
    end: u32,
}

/// y for every row, lanes and ports, bands and crossings.
#[allow(clippy::too_many_arguments)]
fn finish(
    m: &Model,
    v: &ViewState,
    mx: &Metrics,
    rows: Vec<RowB>,
    drawn: &[(Sym, Sym, EdgeKind)],
    form: &BTreeMap<Sym, Form>,
    want: BTreeMap<Sym, u32>,
) -> Layout {
    let names = &m.names;
    let width = v.width_units;
    let mut row_of: BTreeMap<Sym, usize> = BTreeMap::new();
    let mut rect: BTreeMap<Sym, (u32, u32, u32)> = BTreeMap::new();
    for (i, r) in rows.iter().enumerate() {
        for &(y, x, w, h) in &r.items {
            row_of.insert(y, i);
            rect.insert(y, (x, w, h));
        }
    }
    let centre = |y: Sym| {
        let (x, w, _) = rect[&y];
        x + w / 2
    };
    let edges: Vec<(Sym, Sym, EdgeKind)> = drawn
        .iter()
        .copied()
        .filter(|(a, b, _)| row_of.contains_key(a) && row_of.contains_key(b))
        .collect();
    let arc_in_first = edges
        .iter()
        .any(|(a, b, _)| row_of[a] == 0 && row_of[b] == 0);

    // vertical: a band between rows (and above the first, when an arc needs it)
    let mut y = if arc_in_first { mx.band } else { 0 };
    let mut out_rows: Vec<Row> = Vec::with_capacity(rows.len());
    for (i, r) in rows.iter().enumerate() {
        if i > 0 {
            let p = &rows[i - 1];
            // an agent sub-row and its own branches' sub-row hold short straight edges only
            let inner = p.layer == 4 && r.layer == 5 && p.line == r.line && p.sub == r.sub;
            y += if inner { mx.inner_band } else { mx.band };
        }
        let h = if r.collapsed {
            COLLAPSED_H
        } else {
            r.items.iter().map(|it| it.3).max().unwrap_or(mx.chip_h)
        };
        out_rows.push(Row {
            layer: r.layer,
            block_line: r.line,
            sub: r.sub,
            y,
            height_units: h,
            collapsed: r.collapsed,
        });
        y += h;
    }
    let height = y;

    // each row's gaps and free slots
    let gaps: Vec<Vec<Gap>> = rows
        .iter()
        .map(|r| {
            let mut spans: Vec<(u32, u32)> =
                r.items.iter().map(|&(_, x, w, _)| (x, x + w)).collect();
            spans.sort_unstable();
            let mut out = Vec::new();
            let mut at = 0u32;
            for (s, e) in spans {
                if s > at {
                    out.push(Gap { start: at, end: s });
                }
                at = at.max(e);
            }
            if width > at {
                out.push(Gap {
                    start: at,
                    end: width,
                });
            }
            out
        })
        .collect();
    let mut taken: Vec<BTreeSet<u32>> = vec![BTreeSet::new(); rows.len()];

    // bundles: one lane per row for edges sharing a source (came from) or a target (runs on, edits)
    #[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
    enum Key {
        From(Sym),
        To(Sym),
        One(Sym, Sym, EdgeKind),
    }
    let key = |(a, b, k): (Sym, Sym, EdgeKind)| match k {
        EdgeKind::CameFrom | EdgeKind::Manages => Key::From(a),
        EdgeKind::RunsOn | EdgeKind::Edits | EdgeKind::BasedOn => Key::To(b),
        _ => Key::One(a, b, k),
    };
    // top endpoint first
    let span = |(a, b, _): (Sym, Sym, EdgeKind)| {
        let (ra, rb) = (row_of[&a], row_of[&b]);
        if ra <= rb {
            (a, ra, b, rb)
        } else {
            (b, rb, a, ra)
        }
    };
    let mut bundles: BTreeMap<Key, BTreeSet<usize>> = BTreeMap::new();
    for &e in &edges {
        let (_, ra, _, rb) = span(e);
        bundles.entry(key(e)).or_default().extend(ra + 1..rb);
    }
    // where a bundle's lane wants to be in row r: over its shared end, or on the straight line between the two
    let anchor = |k: Key| -> Box<dyn Fn(usize) -> u32> {
        match k {
            Key::From(a) => {
                let c = centre(a);
                Box::new(move |_| c)
            }
            Key::To(b) => {
                let c = centre(b);
                Box::new(move |_| c)
            }
            Key::One(a, b, _) => {
                let (ca, cb) = (centre(a), centre(b));
                let (ra, rb) = (row_of[&a], row_of[&b]);
                Box::new(move |r| {
                    let span = rb.abs_diff(ra).max(1) as i64;
                    let t = r.abs_diff(ra) as i64;
                    let (ca, cb) = (i64::from(ca), i64::from(cb));
                    u32::try_from(ca + (cb - ca) * t / span).unwrap_or(0)
                })
            }
        }
    };
    let mut order: Vec<(Key, usize, u32)> = bundles
        .iter()
        .filter(|(_, rs)| !rs.is_empty())
        .map(|(&k, rs)| {
            let first = *rs.iter().next().expect("a row");
            (k, first, anchor(k)(first))
        })
        .collect();
    order.sort_by(|a, b| (a.1, a.2, a.0).cmp(&(b.1, b.2, b.0)));
    let mut slot: BTreeMap<(Key, usize), Option<u32>> = BTreeMap::new();
    for (k, _, _) in order {
        let rs = &bundles[&k];
        let at = anchor(k);
        for &r in rs {
            let target = at(r);
            let mut best: Option<(u32, u32)> = None;
            for g in &gaps[r] {
                // free slots g.start+1 ..= g.end-1, nearest to the target
                let (lo, hi) = (g.start + 1, g.end.saturating_sub(1));
                if lo > hi {
                    continue;
                }
                let c = target.clamp(lo, hi);
                let mut cand = None;
                for dist in 0..=(hi - lo) {
                    for x in [c.checked_sub(dist), c.checked_add(dist)]
                        .into_iter()
                        .flatten()
                    {
                        if (lo..=hi).contains(&x) && !taken[r].contains(&x) {
                            cand = Some(x);
                            break;
                        }
                    }
                    if cand.is_some() {
                        break;
                    }
                }
                if let Some(x) = cand {
                    let dd = x.abs_diff(target);
                    if best.is_none_or(|(bd, bx)| (dd, x) < (bd, bx)) {
                        best = Some((dd, x));
                    }
                }
            }
            if let Some((_, x)) = best {
                taken[r].insert(x);
            }
            slot.insert((k, r), best.map(|b| b.1));
        }
    }

    // lanes, ports, segments
    let mut lanes = Vec::new();
    let mut ported: BTreeMap<Sym, BTreeSet<Sym>> = BTreeMap::new();
    let mut segs: Vec<Vec<Seg>> = vec![Vec::new(); rows.len()];
    for &e in &edges {
        let (top, rt, bot, rb) = span(e);
        let (from, to, kind) = (names.id(e.0), names.id(e.1), e.2);
        if rt == rb {
            let band = if rt == 0 { 0 } else { rt };
            segs[band].push(Seg {
                from,
                to,
                kind,
                x0: centre(top),
                x1: centre(bot),
                arc: true,
            });
            continue;
        }
        let k = key(e);
        let xs: Vec<Option<u32>> = (rt + 1..rb).map(|r| slot[&(k, r)]).collect();
        if xs.iter().any(Option::is_none) {
            ported.entry(e.1).or_default().insert(e.0);
            continue;
        }
        let xs: Vec<u32> = xs.into_iter().flatten().collect();
        for (i, &x) in xs.iter().enumerate() {
            lanes.push(Lane {
                row: (rt + 1 + i) as u32,
                x,
                from: from.clone(),
                to: to.clone(),
                kind,
            });
        }
        let mut pts = vec![centre(top)];
        pts.extend(&xs);
        pts.push(centre(bot));
        for (i, w) in pts.windows(2).enumerate() {
            segs[rt + 1 + i].push(Seg {
                from: from.clone(),
                to: to.clone(),
                kind,
                x0: w[0],
                x1: w[1],
                arc: false,
            });
        }
    }
    lanes.sort_by(|a, b| (a.row, a.x, &a.from, &a.to).cmp(&(b.row, b.x, &b.from, &b.to)));
    let mut ports: Vec<Port> = ported
        .into_iter()
        .map(|(t, ps)| {
            let mut parents: Vec<ItemId> = ps.into_iter().map(|p| names.id(p)).collect();
            parents.sort();
            Port {
                target: names.id(t),
                parents,
            }
        })
        .collect();
    ports.sort_by(|a, b| a.target.cmp(&b.target));

    let mut crossings = 0u32;
    let mut bands = Vec::new();
    for (r, mut list) in segs.into_iter().enumerate() {
        if r == 0 && !arc_in_first {
            continue;
        }
        list.sort_by(|a, b| {
            (a.x0, a.x1, &a.from, &a.to, a.kind).cmp(&(b.x0, b.x1, &b.from, &b.to, b.kind))
        });
        let straight: Vec<&Seg> = list.iter().filter(|s| !s.arc).collect();
        for (i, a) in straight.iter().enumerate() {
            for b in &straight[i + 1..] {
                let d0 = i64::from(a.x0) - i64::from(b.x0);
                let d1 = i64::from(a.x1) - i64::from(b.x1);
                if d0 * d1 < 0 {
                    crossings += 1;
                }
            }
        }
        let top = if r == 0 {
            0
        } else {
            out_rows[r - 1].y + out_rows[r - 1].height_units
        };
        bands.push(Band {
            row: r as u32,
            y: top,
            height_units: out_rows[r].y - top,
            segs: list,
        });
    }

    let at: BTreeMap<ItemId, Rect> = rect
        .iter()
        .map(|(&y, &(x, w, h))| {
            (
                names.id(y),
                Rect {
                    x,
                    y: out_rows[row_of[&y]].y,
                    w,
                    h,
                },
            )
        })
        .collect();
    let widest = rect.values().map(|r| r.1).max().unwrap_or(0);
    // the fit rule: wide enough, every card inside, no lane overflow; the height never counts (the map scrolls)
    let fits = width >= MIN_WIDTH_UNITS && widest <= width && ports.is_empty();
    Layout {
        rows: out_rows,
        form: form
            .iter()
            .filter(|(y, _)| rect.contains_key(*y))
            .map(|(&y, &f)| (names.id(y), f))
            .collect(),
        at,
        lanes,
        ports,
        bands,
        fits,
        crossings,
        width_units: width,
        height_units: height,
        want: want.into_iter().map(|(y, t)| (names.id(y), t)).collect(),
    }
}
