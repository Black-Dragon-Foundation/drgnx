//! The map's navigation, for the editor's native view model (`docs/develop/work-space.md`, "Keys and the native view
//! model"). The editor keeps a replica of the map's model and answers every key from it; the hub sends, with each
//! item, where each arrow goes from it (its links), where the selection goes when it goes (`then`), and the orders the
//! walking keys follow (the lists). These are the rules the editor's own navigation had, over the same frame: the
//! items a view shows, their places, and the chain edges among them.

use std::collections::{BTreeMap, BTreeSet};

use crate::layout::{Layout, Rect};
use crate::model::{Model, State};
use crate::{Item, ItemId, Kind};

/// Where each key goes from one item; `None`: the key leaves the selection where it is.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Links {
    /// What it came from: the nearest of its parents on the chain above it, else (a missing level) the nearest of its
    /// ancestors on the lowest layer above.
    pub up: Option<ItemId>,
    /// What it touches: the nearest of its children on the chain below it.
    pub down: Option<ItemId>,
    /// Its neighbours along its layer, in reading order, stopping at the layer's ends.
    pub left: Option<ItemId>,
    pub right: Option<ItemId>,
    /// Where the selection goes when this item goes: the last of what it came from, by layer then id.
    pub then: Option<ItemId>,
}

/// The chain edges among the shown items: (forward, backward) adjacency.
type Adj<'a> = BTreeMap<&'a ItemId, Vec<&'a ItemId>>;

/// A card's centre's x (twice, to stay whole) and its top: the place `nearest` measures from.
fn centre(r: &Rect) -> (i64, i64) {
    (2 * i64::from(r.x) + i64::from(r.w), i64::from(r.y))
}

/// Of `ids` the one nearest to `from`: the least vertical distance, then the least horizontal, then the least id.
/// `above`/`below` keep only those above or below `from` (all of them, when none is).
fn nearest<'a>(
    at: &BTreeMap<ItemId, Rect>,
    from: &ItemId,
    ids: &[&'a ItemId],
    above: bool,
    below: bool,
) -> Option<&'a ItemId> {
    let (x0, y0) = centre(at.get(from)?);
    let with: Vec<(&ItemId, (i64, i64))> = ids
        .iter()
        .filter_map(|&i| at.get(i).map(|r| (i, centre(r))))
        .collect();
    let side: Vec<_> = with
        .iter()
        .filter(|(_, (_, y))| (!above || *y < y0) && (!below || *y > y0))
        .copied()
        .collect();
    let pool = if side.is_empty() { with } else { side };
    pool.into_iter()
        .min_by_key(|&(i, (x, y))| ((y - y0).abs(), (x - x0).abs(), i))
        .map(|(i, _)| i)
}

/// The ids reachable from `id` through `adj`, not `id` itself.
fn reach<'a>(adj: &Adj<'a>, id: &'a ItemId) -> BTreeSet<&'a ItemId> {
    let mut seen = BTreeSet::new();
    let mut stack = vec![id];
    while let Some(y) = stack.pop() {
        for &z in adj.get(y).into_iter().flatten() {
            if z != id && seen.insert(z) {
                stack.push(z);
            }
        }
    }
    seen
}

fn layer(id: &ItemId) -> u8 {
    id.kind().map_or(0, Kind::layer)
}

/// Every shown item's links. `ids`: the items the view shows (the frame's items); `l`: the view's layout. Items
/// without a place have no arrows; `then` holds for all of them.
pub fn links(m: &Model, l: &Layout, ids: &BTreeSet<ItemId>) -> BTreeMap<ItemId, Links> {
    let edges = m.edges();
    let mut fwd: Adj = BTreeMap::new();
    let mut back: Adj = BTreeMap::new();
    for e in &edges {
        if e.kind.on_chain() && ids.contains(&e.from) && ids.contains(&e.to) {
            fwd.entry(&e.from).or_default().push(&e.to);
            back.entry(&e.to).or_default().push(&e.from);
        }
    }
    // each layer's placed items in reading order: by top, then left
    let mut rows: BTreeMap<u8, Vec<&ItemId>> = BTreeMap::new();
    for id in ids.iter().filter(|i| l.at.contains_key(*i)) {
        rows.entry(layer(id)).or_default().push(id);
    }
    for row in rows.values_mut() {
        row.sort_by_key(|i| {
            let r = &l.at[*i];
            (r.y, r.x, *i)
        });
    }
    let mut out = BTreeMap::new();
    for id in ids {
        let up_all = reach(&back, id);
        let mut links = Links {
            then: up_all
                .iter()
                .max_by_key(|i| (layer(i), **i))
                .map(|&i| i.clone()),
            ..Links::default()
        };
        if l.at.contains_key(id) {
            let row = &rows[&layer(id)];
            let at = row
                .iter()
                .position(|i| *i == id)
                .expect("a placed item is in its row");
            links.left = at.checked_sub(1).map(|k| row[k].clone());
            links.right = row.get(at + 1).map(|&i| i.clone());
            let parents = back.get(id).map_or(&[][..], Vec::as_slice);
            links.up = nearest(&l.at, id, parents, true, false)
                .or_else(|| {
                    // a missing level: the nearest ancestor, of those on the lowest layer above
                    let placed: Vec<&ItemId> = up_all
                        .iter()
                        .copied()
                        .filter(|i| l.at.contains_key(*i))
                        .collect();
                    let top = placed.iter().map(|i| layer(i)).max()?;
                    let lowest: Vec<&ItemId> =
                        placed.into_iter().filter(|i| layer(i) == top).collect();
                    nearest(&l.at, id, &lowest, true, false)
                })
                .cloned();
            let children = fwd.get(id).map_or(&[][..], Vec::as_slice);
            links.down = nearest(&l.at, id, children, false, true).cloned();
        }
        for link in [&mut links.up, &mut links.down] {
            if link.as_ref() == Some(id) {
                *link = None;
            }
        }
        out.insert(id.clone(), links);
    }
    out
}

/// The shown items, materialised once.
fn shown(m: &Model, ids: &BTreeSet<ItemId>) -> BTreeMap<ItemId, Item> {
    m.items()
        .into_iter()
        .filter(|(id, _)| ids.contains(id))
        .collect()
}

/// The agents the outline shows, in block order: their plan's rank (an agent with no plan last), then start order,
/// then id. Subagents are not in it.
pub fn outline(m: &Model, ids: &BTreeSet<ItemId>) -> Vec<ItemId> {
    outline_of(&shown(m, ids))
}

fn outline_of(items: &BTreeMap<ItemId, Item>) -> Vec<ItemId> {
    let rank = |it: &Item| match &it.block {
        // a plan the view doesn't show ranks first, as the editor's outline had it
        Some(b) => items.get(b).map_or(0, |p| p.order),
        None => u64::MAX,
    };
    let mut agents: Vec<&Item> = items.values().filter(|it| it.kind == Kind::Agent).collect();
    agents.sort_by_key(|it| (rank(it), it.order, &it.id));
    agents.into_iter().map(|it| it.id.clone()).collect()
}

/// The agents and subagents in team order: the outline's agents, each followed by its subagents in start order.
pub fn team(m: &Model, ids: &BTreeSet<ItemId>) -> Vec<ItemId> {
    let items = shown(m, ids);
    let mut subs: BTreeMap<&ItemId, Vec<&Item>> = BTreeMap::new();
    for it in items.values().filter(|it| it.kind == Kind::Subagent) {
        if let Some(p) = &it.parent {
            subs.entry(p).or_default().push(it);
        }
    }
    let mut out = Vec::new();
    for id in outline_of(&items) {
        let mut mine = subs.remove(&id).unwrap_or_default();
        mine.sort_by_key(|it| (it.order, &it.id));
        out.push(id);
        out.extend(mine.into_iter().map(|it| it.id.clone()));
    }
    out
}

/// What the needs-you keys walk: for each entry of the strip (its cards, then the agents that need you with no card,
/// by id) the first shown item it is about. An entry about nothing shown has no place in it.
pub fn needs_you(m: &Model, ids: &BTreeSet<ItemId>) -> Vec<ItemId> {
    let cards = m.needs_you();
    let covered: BTreeSet<&ItemId> = cards.iter().flat_map(|c| &c.about).collect();
    let mut out: Vec<ItemId> = cards
        .iter()
        .filter_map(|c| c.about.iter().find(|a| ids.contains(*a)).cloned())
        .collect();
    out.extend(
        shown(m, ids)
            .into_values()
            .filter(|it| {
                it.kind == Kind::Agent
                    && it.fields.state == Some(State::NeedsYou)
                    && !covered.contains(&it.id)
            })
            .map(|it| it.id),
    );
    out
}
