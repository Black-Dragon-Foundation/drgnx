//! The chain (design §5.4): everything reachable from the selection by following "came from" edges up and "touches"
//! edges down. The editor computes it locally from the frame for navigation; the hub uses it for the focus filter.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::model::{Model, Sym};
use crate::{Edge, ItemId};

/// The selection's chain.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Chain {
    /// What it came from (its why), sorted by layer then id.
    pub up: Vec<ItemId>,
    /// What it touches, sorted by layer then id.
    pub down: Vec<ItemId>,
    /// The edges on the chain, sorted.
    pub edges: Vec<Edge>,
    /// Layers above the selection with nothing on its chain: "no spec recorded", say.
    pub gaps: Vec<u8>,
}

impl Model {
    /// The chain of `sel`; empty for an item the model doesn't hold.
    pub fn chain(&self, sel: &ItemId) -> Chain {
        let Some(s) = self
            .names
            .get(sel.as_str())
            .filter(|y| self.d.items.contains_key(y))
        else {
            return Chain::default();
        };
        let (up, down) = self.chain_syms(s);
        let layer = |y: Sym| self.d.items[&y].kind.layer();
        let sorted = |set: &BTreeSet<Sym>| {
            let mut v: Vec<(u8, ItemId)> =
                set.iter().map(|&y| (layer(y), self.names.id(y))).collect();
            v.sort();
            v.into_iter().map(|(_, id)| id).collect::<Vec<_>>()
        };
        let mut edges: Vec<Edge> = self
            .d
            .edges
            .iter()
            .filter(|(a, b, k)| {
                k.on_chain()
                    && ((up.contains(a) && (*b == s || up.contains(b)))
                        || ((*a == s || down.contains(a)) && down.contains(b)))
            })
            .map(|&(a, b, kind)| Edge {
                from: self.names.id(a),
                to: self.names.id(b),
                kind,
            })
            .collect();
        edges.sort();
        let have: BTreeSet<u8> = up.iter().map(|&y| layer(y)).collect();
        let gaps = (1..layer(s)).filter(|l| !have.contains(l)).collect();
        Chain {
            up: sorted(&up),
            down: sorted(&down),
            edges,
            gaps,
        }
    }

    /// The chain's items above and below `s`, neither holding `s`.
    pub(crate) fn chain_syms(&self, s: Sym) -> (BTreeSet<Sym>, BTreeSet<Sym>) {
        let mut fwd: BTreeMap<Sym, Vec<Sym>> = BTreeMap::new();
        let mut back: BTreeMap<Sym, Vec<Sym>> = BTreeMap::new();
        for &(a, b, k) in &self.d.edges {
            if k.on_chain() {
                fwd.entry(a).or_default().push(b);
                back.entry(b).or_default().push(a);
            }
        }
        let reach = |adj: &BTreeMap<Sym, Vec<Sym>>| {
            let mut seen = BTreeSet::new();
            let mut stack = vec![s];
            while let Some(y) = stack.pop() {
                for &z in adj.get(&y).into_iter().flatten() {
                    if z != s && seen.insert(z) {
                        stack.push(z);
                    }
                }
            }
            seen
        };
        (reach(&back), reach(&fwd))
    }
}
