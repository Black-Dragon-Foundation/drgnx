//! Overlaps (design §5.2): two live agents on different branches whose changes touch the same file, each measured
//! against its own branch's base, untracked files included; within one branch (a parent and its subagents, or two
//! siblings), two of them editing the same file. A clash card is an overlap too, with `clash` set.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::ItemId;
use crate::model::Sym;

/// One overlap: `a` sorts before `b`; both carry the ⚠ chip.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Overlap {
    pub a: ItemId,
    pub b: ItemId,
    /// The shared files (empty for a clash on decisions only).
    pub files: Vec<ItemId>,
    pub clash: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct OverlapD {
    pub(crate) files: BTreeSet<Sym>,
    pub(crate) clash: bool,
}

/// Every overlap, keyed by its pair, the name that sorts first first.
///
/// `sets`: each live branch's changed files; `owners`: each branch's live top-level agents; `on_branch`: every live
/// agent on a branch, subagents included; `edits`: each agent's own edits in flight; `clashes`: open clash cards' pairs.
pub(crate) fn compute<'a>(
    sets: &BTreeMap<Sym, &BTreeSet<Sym>>,
    owners: &BTreeMap<Sym, Vec<Sym>>,
    on_branch: &BTreeMap<Sym, Vec<Sym>>,
    edits: &BTreeMap<Sym, BTreeSet<Sym>>,
    clashes: &[(Sym, Sym)],
    name: impl Fn(Sym) -> &'a str,
) -> BTreeMap<(Sym, Sym), OverlapD> {
    let mut out: BTreeMap<(Sym, Sym), OverlapD> = BTreeMap::new();
    let key = |x: Sym, y: Sym| if name(x) <= name(y) { (x, y) } else { (y, x) };

    // across branches: file → the branches changing it
    let mut by_file: Vec<(Sym, Sym)> = sets
        .iter()
        .flat_map(|(&b, s)| s.iter().map(move |&x| (x, b)))
        .collect();
    by_file.sort_unstable();
    for group in by_file.chunk_by(|p, q| p.0 == q.0) {
        if group.len() < 2 {
            continue;
        }
        let file = group[0].0;
        for (i, &(_, b1)) in group.iter().enumerate() {
            for &(_, b2) in &group[i + 1..] {
                out.entry(key(b1, b2)).or_default().files.insert(file);
                for &a1 in owners.get(&b1).into_iter().flatten() {
                    for &a2 in owners.get(&b2).into_iter().flatten() {
                        out.entry(key(a1, a2)).or_default().files.insert(file);
                    }
                }
            }
        }
    }

    // within one branch: agents sharing its worktree that edit the same file
    for agents in on_branch.values() {
        for (i, &x) in agents.iter().enumerate() {
            let Some(ex) = edits.get(&x) else { continue };
            for &y in &agents[i + 1..] {
                let Some(ey) = edits.get(&y) else { continue };
                let shared: Vec<Sym> = ex.intersection(ey).copied().collect();
                if !shared.is_empty() {
                    out.entry(key(x, y)).or_default().files.extend(shared);
                }
            }
        }
    }

    for &(x, y) in clashes {
        out.entry(key(x, y)).or_default().clash = true;
    }
    out
}
