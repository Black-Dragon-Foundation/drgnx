//! Durability (salsa): a cell whose sources are all durable (theme, fonts, settings, scale) is durable too, and a check
//! mark reaches it only when a durable state changed; revisions are renumbered when the counter wraps.

use crate::propagate::{DURABLE, FORMULA, Graph};

/// After a run of cell I: it is durable when every source it read is (a formula that read nothing is not).
pub(crate) fn settle(g: &mut Graph, i: u32) {
    let u = i as usize;
    if g.flags[u] & FORMULA == 0 {
        return;
    }
    let n = g.src.len(i);
    let durable = n > 0 && (0..n).all(|k| g.flags[g.src.get(i, k) as usize] & DURABLE != 0);
    if durable {
        g.flags[u] |= DURABLE;
    } else {
        g.flags[u] &= !DURABLE;
    }
}

/// The revision counter is about to wrap: every revision is replaced by its rank among those in use, so their order
/// (all that propagation compares) is kept.
pub(crate) fn renumber(g: &mut Graph) {
    let mut seen: Vec<u32> = g.changed.iter().chain(g.verified.iter()).copied().collect();
    seen.push(g.durable_rev);
    seen.sort_unstable();
    seen.dedup();
    let rank = |r: u32| u32::try_from(seen.partition_point(|&x| x < r)).unwrap_or(u32::MAX - 2) + 1;
    for r in g.changed.iter_mut().chain(g.verified.iter_mut()) {
        *r = rank(*r);
    }
    g.durable_rev = rank(g.durable_rev);
    g.rev = u32::try_from(seen.len()).unwrap_or(u32::MAX - 2) + 1;
}
