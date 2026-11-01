//! Greedy merging of adjacent units into chunks.

use super::Nws;
use std::ops::Range;

/// A stretch of the file that is not split further unless it is over the budget on its own.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Unit {
    pub start: usize,
    pub end: usize,
    /// A section starts here: the chunk before it ends.
    pub boundary: bool,
    /// Stands alone whatever its size (data-heavy forms).
    pub solo: bool,
}

/// Groups of consecutive units, each within `budget` non-whitespace characters, or a single unit that is over it or
/// stands alone. A group never crosses a `boundary`.
pub(crate) fn merge(units: &[Unit], nws: &Nws, budget: usize) -> Vec<Range<usize>> {
    let mut out: Vec<Range<usize>> = Vec::new();
    let mut open: Option<usize> = None; // first unit of the group being filled
    for (i, u) in units.iter().enumerate() {
        let alone = u.solo || nws.count(u.start, u.end) > budget;
        if alone {
            if let Some(a) = open.take() {
                out.push(a..i);
            }
            out.push(i..i + 1);
            continue;
        }
        match open {
            Some(a) if !u.boundary && nws.count(units[a].start, u.end) <= budget => {}
            Some(a) => {
                out.push(a..i);
                open = Some(i);
            }
            None => open = Some(i),
        }
    }
    if let Some(a) = open {
        out.push(a..units.len());
    }
    out
}
