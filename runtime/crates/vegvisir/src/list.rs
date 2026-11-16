//! List mode (`docs/develop/work-space.md`): the Work map as nested rows, spec › plan › task, each task with its
//! agent and machine on the same row. Pure: the model and the view's state in, entries out; the hub draws them.

use std::collections::{BTreeMap, BTreeSet};

use crate::view::{Group, Visibility, group, shown};
use crate::{EdgeKind, Item, ItemId, Kind, Model, TaskState, ViewState};

/// One small label on a row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ListChip {
    /// An agent's branch (its short name).
    Branch(String),
    /// The files the agent's branch changes, and the lines.
    Files(u32, u32),
    /// Plan steps done of total.
    Progress(u32, u32),
    /// A task's state: a glyph and its word.
    State(TaskState),
}

/// One row of the list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ListEntry {
    /// The item the row is; a synthetic id for the "No spec" row (`spec:none`) and the closing "Completed" row
    /// (`completed:more`).
    pub item: ItemId,
    pub label: String,
    /// 0 spec, 1 plan, 2 task.
    pub depth: u8,
    /// Where it sits in Active; none in Completed and All.
    pub group: Option<Group>,
    /// A task's agent (the first of its top agents), and the machine it runs on.
    pub agent: Option<ItemId>,
    pub machine: Option<String>,
    pub chips: Vec<ListChip>,
    pub visibility: Visibility,
    /// The closing row: how many finished tasks Active leaves out.
    pub count: Option<u32>,
    /// A folded spec or plan.
    pub collapsed: bool,
}

/// The id of the row for plans no spec holds.
pub const NO_SPEC: &str = "spec:none";
/// The id of the closing row.
pub const COMPLETED_MORE: &str = "completed:more";

fn group_of(it: &Item, v: &ViewState, now: u64, forced: bool) -> Option<Group> {
    if v.filters.show != crate::Show::Active {
        return None;
    }
    group(it, &v.filters, now).or_else(|| {
        forced.then_some(if it.live || it.needs_you {
            Group::InProgress
        } else {
            Group::Ready
        })
    })
}

/// The list's rows for the view state V at minute NOW.
pub fn entries(m: &Model, v: &ViewState, now: u64) -> Vec<ListEntry> {
    let items = m.items();
    let edges = m.edges();
    let vis = |it: &Item| shown(it, &v.filters, now);
    let came = |from: Kind, to: Kind| {
        let mut out: BTreeMap<&ItemId, Vec<&ItemId>> = BTreeMap::new();
        for e in edges.iter().filter(|e| e.kind == EdgeKind::CameFrom) {
            if items.get(&e.from).is_some_and(|i| i.kind == from)
                && items.get(&e.to).is_some_and(|i| i.kind == to)
            {
                out.entry(&e.from).or_default().push(&e.to);
            }
        }
        out
    };
    let plans_of = came(Kind::Spec, Kind::Plan);
    let tasks_of = came(Kind::Plan, Kind::Task);
    let agents_of = came(Kind::Task, Kind::Agent);
    let machine_of: BTreeMap<&ItemId, &ItemId> = edges
        .iter()
        .filter(|e| e.kind == EdgeKind::RunsOn)
        .map(|e| (&e.from, &e.to))
        .collect();
    let with_spec: BTreeSet<&ItemId> = plans_of.values().flatten().copied().collect();

    // the tasks, plans and specs the filter shows (a parent of a shown child is shown)
    let shown_task = |t: &ItemId| items.get(t).is_some_and(|i| vis(i) != Visibility::Hidden);
    let plan_tasks = |p: &ItemId| -> Vec<&ItemId> {
        let mut ts: Vec<&ItemId> = tasks_of
            .get(p)
            .into_iter()
            .flatten()
            .copied()
            .filter(|t| shown_task(t))
            .collect();
        ts.sort();
        ts
    };
    let plan_shown = |p: &ItemId| {
        items.get(p).is_some_and(|i| vis(i) != Visibility::Hidden) || !plan_tasks(p).is_empty()
    };
    let spec_plans = |s: &ItemId| -> Vec<&ItemId> {
        let mut ps: Vec<&ItemId> = plans_of
            .get(s)
            .into_iter()
            .flatten()
            .copied()
            .filter(|p| plan_shown(p))
            .collect();
        ps.sort_by_key(|p| (items[*p].order, (*p).clone()));
        ps
    };

    // top-level blocks: each spec with its plans, then the plans no spec holds
    struct Block<'a> {
        spec: Option<&'a ItemId>,
        plans: Vec<&'a ItemId>,
    }
    let mut blocks: Vec<Block> = Vec::new();
    let mut spec_ids: Vec<&ItemId> = items
        .iter()
        .filter(|(_, i)| i.kind == Kind::Spec)
        .map(|(id, _)| id)
        .collect();
    spec_ids.sort();
    for s in spec_ids {
        let plans = spec_plans(s);
        if items.get(s).is_some_and(|i| vis(i) != Visibility::Hidden) || !plans.is_empty() {
            blocks.push(Block {
                spec: Some(s),
                plans,
            });
        }
    }
    let mut loose: Vec<&ItemId> = items
        .iter()
        .filter(|(id, i)| i.kind == Kind::Plan && !with_spec.contains(id) && plan_shown(id))
        .map(|(id, _)| id)
        .collect();
    loose.sort_by_key(|p| (items[*p].order, (*p).clone()));
    if !loose.is_empty() {
        blocks.push(Block {
            spec: None,
            plans: loose,
        });
    }
    // Active: what is in progress first
    let rank = |b: &Block| -> u8 {
        let live = |i: &Item| i.live || i.needs_you;
        let own = b.spec.is_some_and(|s| live(&items[s]));
        u8::from(!(own || b.plans.iter().any(|p| live(&items[*p]))))
    };
    if v.filters.show == crate::Show::Active {
        blocks.sort_by_key(rank);
    }

    let mut out = Vec::new();
    let machine_label = |a: &ItemId| {
        machine_of
            .get(a)
            .and_then(|m| items.get(*m))
            .map(|m| m.label.clone())
    };
    for b in &blocks {
        let (item, label, entry_group, visibility) = match b.spec {
            Some(s) => {
                let it = &items[s];
                (
                    s.clone(),
                    it.label.clone(),
                    group_of(it, v, now, true),
                    vis(it).max(Visibility::Normal),
                )
            }
            None => (
                ItemId(NO_SPEC.into()),
                "No spec".to_owned(),
                (v.filters.show == crate::Show::Active).then(|| {
                    if b.plans
                        .iter()
                        .any(|p| items[*p].live || items[*p].needs_you)
                    {
                        Group::InProgress
                    } else {
                        Group::Ready
                    }
                }),
                Visibility::Normal,
            ),
        };
        let collapsed = v.list_collapsed.contains(&item);
        out.push(ListEntry {
            item,
            label,
            depth: 0,
            group: entry_group,
            agent: None,
            machine: None,
            chips: Vec::new(),
            visibility,
            count: None,
            collapsed,
        });
        if collapsed {
            continue;
        }
        for p in &b.plans {
            let pit = &items[*p];
            out.push(ListEntry {
                item: (*p).clone(),
                label: pit.label.clone(),
                depth: 1,
                group: group_of(pit, v, now, true),
                agent: None,
                machine: None,
                chips: pit
                    .fields
                    .progress
                    .map(|(a, b)| ListChip::Progress(a, b))
                    .into_iter()
                    .collect(),
                visibility: vis(pit).max(Visibility::Normal),
                count: None,
                collapsed: v.list_collapsed.contains(*p),
            });
            if v.list_collapsed.contains(*p) {
                continue;
            }
            for t in plan_tasks(p) {
                let tit = &items[t];
                let agent = agents_of
                    .get(t)
                    .into_iter()
                    .flatten()
                    .copied()
                    .min_by_key(|a| (items[*a].order, (*a).clone()))
                    .cloned();
                let mut chips = Vec::new();
                if let Some(s) = tit.fields.task_state {
                    chips.push(ListChip::State(s));
                }
                if let Some(a) = agent.as_ref().and_then(|a| items.get(a)) {
                    if let Some(branch) = branch_of(&items, &edges, &a.id) {
                        chips.push(ListChip::Branch(branch));
                    }
                    if let Some((files, plus, minus)) = a.fields.edits {
                        chips.push(ListChip::Files(files, plus + minus));
                    }
                    if let Some((d, n)) = a.fields.progress {
                        chips.push(ListChip::Progress(d, n));
                    }
                }
                out.push(ListEntry {
                    item: t.clone(),
                    label: tit.label.clone(),
                    depth: 2,
                    group: group_of(tit, v, now, true),
                    machine: agent.as_ref().and_then(machine_label),
                    agent,
                    chips,
                    visibility: vis(tit),
                    count: None,
                    collapsed: false,
                });
            }
        }
    }
    if v.filters.show == crate::Show::Active {
        let hidden_done = items
            .values()
            .filter(|i| i.kind == Kind::Task && i.done && vis(i) == Visibility::Hidden)
            .count();
        if hidden_done > 0 {
            out.push(ListEntry {
                item: ItemId(COMPLETED_MORE.into()),
                label: "Completed".into(),
                depth: 0,
                group: None,
                agent: None,
                machine: None,
                chips: Vec::new(),
                visibility: Visibility::Faded,
                count: Some(u32::try_from(hidden_done).unwrap_or(u32::MAX)),
                collapsed: false,
            });
        }
    }
    out
}

/// The short name of the branch AGENT works on: its branch's label.
fn branch_of(
    items: &BTreeMap<ItemId, Item>,
    edges: &[crate::Edge],
    agent: &ItemId,
) -> Option<String> {
    edges
        .iter()
        .find(|e| {
            e.kind == EdgeKind::CameFrom
                && &e.from == agent
                && items.get(&e.to).is_some_and(|i| i.kind == Kind::Branch)
        })
        .and_then(|e| items.get(&e.to))
        .map(|b| b.label.clone())
}

/// The row pairs (indexes into ENTRIES) joined by an edge on SEL's chain, for the gutter: only the selected chain.
pub fn chain_gutter(entries: &[ListEntry], m: &Model, sel: &ItemId) -> Vec<(usize, usize)> {
    let at: BTreeMap<&ItemId, usize> = entries
        .iter()
        .enumerate()
        .map(|(i, e)| (&e.item, i))
        .collect();
    let mut out: Vec<(usize, usize)> = m
        .chain(sel)
        .edges
        .iter()
        .filter_map(|e| Some((*at.get(&e.from)?, *at.get(&e.to)?)))
        .collect();
    out.sort_unstable();
    out.dedup();
    out
}

/// The row below ID's, if any.
pub fn list_next(entries: &[ListEntry], id: &ItemId) -> Option<ItemId> {
    let i = entries.iter().position(|e| &e.item == id)?;
    entries.get(i + 1).map(|e| e.item.clone())
}

/// The row above ID's, if any.
pub fn list_prev(entries: &[ListEntry], id: &ItemId) -> Option<ItemId> {
    let i = entries.iter().position(|e| &e.item == id)?;
    i.checked_sub(1).map(|j| entries[j].item.clone())
}

/// The nearest row above ID's with a lower depth: its spec or plan.
pub fn list_parent(entries: &[ListEntry], id: &ItemId) -> Option<ItemId> {
    let i = entries.iter().position(|e| &e.item == id)?;
    let d = entries[i].depth;
    entries[..i]
        .iter()
        .rev()
        .find(|e| e.depth < d)
        .map(|e| e.item.clone())
}
